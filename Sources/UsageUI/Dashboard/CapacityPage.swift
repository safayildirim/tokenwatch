import SwiftUI
import Charts
import UsageCore

/// Subscription capacity analysis for the accounts that local telemetry can see.
///
/// This page compares plans only from stored provider readings and local work. It never computes a
/// provider percentage from tokens, never combines pools, and never compares different accounts by
/// guessing that they are the same.
struct CapacityPage: View {
    @Environment(AppModel.self) private var model
    @State private var days = 90
    @State private var report: CapacityReport?
    @State private var loading = false
    @State private var error: String?
    @State private var revision = 0
    @State private var loadGeneration = 0

    var body: some View {
        PageScroll {
            header
            if loading && report == nil {
                ProgressView("Reading quota history…").frame(maxWidth: .infinity, minHeight: 180)
            } else if let error, report == nil {
                Card(String(localized: "Capacity analysis could not be loaded")) {
                    Text(error).font(.callout).foregroundStyle(Palette.critical)
                    Button("Try again") { revision += 1 }
                }
            } else if let report {
                let accounts = visibleAccounts(report)
                if accounts.isEmpty {
                    if report.accounts.isEmpty {
                        emptyState
                    } else {
                        filteredEmptyState
                    }
                } else {
                    ForEach(accounts) { account in
                        AccountCapacitySection(account: account, range: report.range, onChanged: { revision += 1 })
                    }
                }
            } else {
                emptyState
            }
            methodology
        }
        .task(id: "\(days)|\(revision)|\(model.scopeVersion)") { await load() }
    }

    private var header: some View {
        Card(String(localized: "Capacity analysis"),
             subtitle: String(localized: "How much subscription allowance your own work consumes per plan. Percentages come from provider readings; work is normalized by API-equivalent list cost.")) {
            HStack(alignment: .center, spacing: 12) {
                Picker("Period", selection: $days) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .labelsHidden()
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button {
                    revision += 1
                } label: {
                    Label("Recompute", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
            Text("Only explicitly assigned plan periods are compared. A plan is never inferred from reset times, session identifiers, or which account was used nearby.")
                .font(.caption).foregroundStyle(.secondary)
            if let report {
                Text("Computed \(Fmt.dateTime(report.generatedAt)). New quota readings appear after Recompute.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let error, report != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.warning)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Try again") { revision += 1 }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private var emptyState: some View {
        Card {
            EmptyState(symbol: "rectangle.3.group",
                       title: String(localized: "No subscription history to compare yet"),
                       message: String(localized: "Capacity analysis needs two independent things: quota percentages reported by the provider, and local work recorded on this Mac. It also needs you to record which plan was active, because local telemetry does not prove that on its own."))
            VStack(alignment: .leading, spacing: 6) {
                Label("Make sure quota tracking is collecting readings for the subscription.", systemImage: "gauge.with.needle")
                Label("Record a plan period with its start and, when it changes, its end.", systemImage: "calendar.badge.plus")
                Label("Use the subscription normally across several separate quota cycles. One afternoon is not several experiments.", systemImage: "repeat")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var filteredEmptyState: some View {
        Card {
            EmptyState(symbol: "line.3.horizontal.decrease.circle",
                       title: String(localized: "No capacity history in this scope"),
                       message: String(localized: "Capacity history exists, but no quota pool matches the current provider, product or account filter. Clear the scope filter to see it."))
        }
    }

    private var methodology: some View {
        Card(String(localized: "How the comparison works")) {
            VStack(alignment: .leading, spacing: 7) {
                bullet("A percentage is used only as the provider reported it. Token counts never produce or adjust a quota percentage.")
                bullet("The local work between two readings is normalized by API-equivalent list cost. That is a common yardstick for model mix and cache use, not a claim about how the subscription is metered.")
                bullet("Each quota cycle is one independent observation. Many readings inside one cycle are summed, not counted as many samples.")
                bullet("The five-hour and weekly windows are analyzed separately. A five-hour multiplier never implies a weekly one.")
                bullet("A ratio is published only after at least two independent cycles per plan and either two matched comparisons or a comparable pooled comparison. Otherwise the page says the evidence is insufficient.")
                bullet("Two subscriptions are two pools. A strategy with two subscriptions aggregates their independent allowances; it is never treated as one larger pool. The comparison assumes each behaves like the measured plan.")
            }.font(.callout)
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) { Text("•"); Text(text).fixedSize(horizontal: false, vertical: true) }
    }

    private func visibleAccounts(_ report: CapacityReport) -> [CapacityAccountReport] {
        let scope = model.scope
        if scope.providers.isEmpty && scope.accounts.isEmpty && scope.products.isEmpty {
            return report.accounts
        }
        let allowed = Set(model.scopedPools.map { "\($0.pool.key.provider.rawValue)/\($0.pool.key.accountID)/\($0.pool.key.poolKey)" })
        return report.accounts.filter { allowed.contains($0.id) }
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        do {
            let end = Date()
            let range = end.addingTimeInterval(-Double(days) * 86_400)...end
            let strategies = Self.strategies(in: model.db.registry)
            let db = model.db
            let next = try await Task.detached(priority: .userInitiated) {
                try CapacityAnalyticsEngine.report(db, range: range, strategies: strategies)
            }.value
            guard generation == loadGeneration else { return }
            report = next
            error = nil
            loading = false
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription
            loading = false
        }
    }

    /// Builds a comparison from the registry, without naming a provider: two subscriptions of the
    /// smallest paid plan above baseline are compared with one subscription of the largest paid plan.
    /// For the Claude plans this is exactly two Max 5x versus one Max 20x.
    static func strategies(in registry: ProviderRegistry) -> [SubscriptionStrategy] {
        var out: [SubscriptionStrategy] = []
        for provider in registry.providers {
            let paid = registry.plans(of: provider.id)
                .filter { ($0.nominalMultiplier(minutes: 300) ?? 0) > 1 }
                .sorted { ($0.nominalMultiplier(minutes: 300) ?? 0) < ($1.nominalMultiplier(minutes: 300) ?? 0) }
            guard let small = paid.first, let large = paid.last, small.key != large.key else { continue }
            out.append(SubscriptionStrategy(id: "two-\(small.key)", name: String(localized: "Two \(small.name)"),
                                            planKey: small.key, count: 2))
            out.append(SubscriptionStrategy(id: "one-\(large.key)", name: String(localized: "One \(large.name)"),
                                            planKey: large.key, count: 1))
        }
        return out
    }
}

// MARK: - One account and pool

private struct AccountCapacitySection: View {
    @Environment(AppModel.self) private var model
    let account: CapacityAccountReport
    let range: ClosedRange<Date>
    let onChanged: () -> Void

    @State private var windowKey: String?
    @State private var planEditor: PlanEditorMode?
    @State private var deleting: PlanAssignment?
    @State private var editingPrices = false

    private var window: CapacityWindowReport? {
        if let windowKey { return account.windows.first { $0.windowKey == windowKey } }
        return account.windows.max { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(account.poolName).font(.title3.weight(.semibold))
                            ProviderChip(provider: account.provider)
                        }
                        Text(account.accountLabel).font(.caption).foregroundStyle(.secondary)
                        Label(account.identityBasis.title, systemImage: account.identityBasis == .providerVerified ? "checkmark.seal" : "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(account.identityBasis == .providerVerified ? Palette.good : Palette.warning)
                            .help(account.identityBasis.explanation)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(String(localized: "Current plan")).font(.caption).foregroundStyle(.secondary)
                        Text(account.currentPlanKey.map { account.planNames[$0] ?? $0 } ?? String(localized: "Not recorded"))
                            .font(.callout.weight(.medium))
                    }
                }
            }

            if account.planPeriods.isEmpty {
                Card(String(localized: "Plan history")) {
                    Text("No plan period is recorded for this account. Quota readings exist, but without a plan period there is nothing to attribute them to.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button { planEditor = .add } label: { Label("Add plan period", systemImage: "plus") }
                }
            } else {
                planTimelineCard
            }

            if let window {
                windowPicker
                overview(window)
                comparisonChart(window)
                if window.estimates.contains(where: { $0.ratio != nil || $0.provisionalRatio != nil }) {
                    estimateTable(window)
                } else {
                    insufficientEvidence(window)
                }
                efficiencyCard(window)
                purchasingCard(window)
            } else {
                Card(String(localized: "Quota windows")) {
                    Text("No quota window has been reported for this pool yet. Capacity is only compared within a window that the provider actually reports.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            measurementsCard
            qualityCard
            if !account.strategyComparisons.isEmpty { strategiesMethodNote }
        }
        .sheet(item: $planEditor) { mode in
            PlanPeriodEditor(account: account, assignment: mode.assignment) {
                planEditor = nil
                onChanged()
            }
        }
        .sheet(isPresented: $editingPrices) {
            PlanPriceEditor(provider: account.provider) {
                editingPrices = false
                onChanged()
            }
        }
        .confirmationDialog("Delete this plan period?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting {
                    try? PlanHistoryStore.delete(model.db, id: deleting.id)
                    self.deleting = nil
                    onChanged()
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Quota readings stay. Only the annotation that says which plan was active is removed.")
        }
    }

    private var windowPicker: some View {
        Picker("Window", selection: Binding(get: { window?.windowKey ?? "" }, set: { windowKey = $0 })) {
            ForEach(account.windows) { w in
                Text(w.windowName).tag(w.windowKey)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
        .labelsHidden()
    }

    // MARK: Overview

    private func overview(_ window: CapacityWindowReport) -> some View {
        let base = basePlan(window)
        let largest = largestPaidPlan()
        let ratio = base.flatMap { base in largest.flatMap { largest in
            window.estimates.first { $0.basePlanKey == base && $0.otherPlanKey == largest }?.ratio
        } }
        let largestName = largest.map { account.planNames[$0] ?? $0 } ?? String(localized: "Largest plan")
        let baseName = base.map { account.planNames[$0] ?? $0 } ?? String(localized: "baseline")
        return HStack(spacing: 10) {
            KPITile(title: String(localized: "Measured \(window.windowName.lowercased()) ratio"),
                    value: ratio.map { String(format: "%.2f×", $0) } ?? "—",
                    detail: String(localized: "\(largestName) against \(baseName)"),
                    help: String(localized: "Only shown when the evidence policy is met. This is relative marginal capacity under your observed workload, not a provider limit."))
            KPITile(title: String(localized: "Peak observed utilization"),
                    value: Fmt.percent(window.observedPeak),
                    detail: String(localized: "\(window.history.cycles.count) cycles · \(window.completeCycles) reached the limit"),
                    help: String(localized: "The highest value the provider reported in this window. A peak below 100% does not mean the allowance was unlimited."))
            KPITile(title: String(localized: "Usable cycles"),
                    value: "\(window.usableCycles)",
                    detail: String(localized: "\(window.samples.count) cycle samples · \(Self.money(window.usableWorkUSD)) of work"),
                    help: String(localized: "A cycle is usable when two authoritative readings bracket local work without a reset, plan change, gap, or another exclusion."))
            KPITile(title: String(localized: "Current plan"),
                    value: account.currentPlanKey.map { account.planNames[$0] ?? $0 } ?? String(localized: "Not recorded"),
                    detail: String(localized: "Recorded manually, not inferred"),
                    help: account.identityBasis.explanation)
        }
    }

    // MARK: Comparison chart

    private func comparisonChart(_ window: CapacityWindowReport) -> some View {
        let base = basePlan(window)
        let points = comparisonPoints(window, base: base)
        let references = referenceLines(base: base, window: window)
        let maxValue = max(references?.advertised ?? 0, references?.equalCost ?? 0,
                           points.map(\.ratio).max() ?? 4) + 0.6
        let subtitle: String = {
            guard let references else {
                return String(localized: "Relative capacity per plan. Bars appear only when the evidence policy is met.")
            }
            switch (references.equalCost, references.advertised) {
            case let (equal?, advertised?):
                return String(localized: "Relative capacity per plan, with a \(String(format: "%.1f", equal))× equal-cost reference and a \(String(format: "%.1f", advertised))× advertised reference. Bars appear only when the evidence policy is met.")
            case let (equal?, nil):
                return String(localized: "Relative capacity per plan, with a \(String(format: "%.1f", equal))× equal-cost reference. The provider gives no advertised multiplier for this window. Bars appear only when the evidence policy is met.")
            case let (nil, advertised?):
                return String(localized: "Relative capacity per plan, with a \(String(format: "%.1f", advertised))× advertised reference. Bars appear only when the evidence policy is met.")
            case (nil, nil):
                return String(localized: "Relative capacity per plan. Bars appear only when the evidence policy is met.")
            }
        }()
        return Card(String(localized: "Measured capacity"), subtitle: subtitle) {
            if points.isEmpty {
                Text("No plan has a measured ratio yet. The readings and plan periods are stored, but there are not enough independent, comparable cycles.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { point in
                        BarMark(x: .value("Capacity relative to baseline", point.ratio),
                                y: .value("Plan", point.name))
                            .foregroundStyle(by: .value("Plan", point.name))
                            .cornerRadius(4)
                            .annotation(position: .trailing, alignment: .leading) {
                                Text(String(format: "%.2f×", point.ratio))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                    }
                    if let equalCost = references?.equalCost {
                        RuleMark(x: .value("Reference", equalCost))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Palette.warning)
                            .annotation(position: .top, alignment: .leading) {
                                Text(String(format: String(localized: "%.1f× equal-cost reference"), equalCost))
                                    .font(.caption2).foregroundStyle(Palette.warning)
                            }
                    }
                    if let advertised = references?.advertised {
                        RuleMark(x: .value("Reference", advertised))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Palette.series[2])
                            .annotation(position: .top, alignment: .leading) {
                                Text(String(format: String(localized: "%.1f× advertised reference"), advertised))
                                    .font(.caption2).foregroundStyle(Palette.series[2])
                            }
                    }
                }
                .chartXScale(domain: 0...maxValue)
                .chartXAxis {
                    AxisMarks(values: Array(stride(from: 0.0, through: maxValue, by: maxValue > 10 ? 5 : 1))) { value in
                        AxisGridLine().foregroundStyle(Palette.gridLine)
                        AxisValueLabel { if let n = value.as(Double.self) { Text(String(format: "%.0f×", n)) } }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: CGFloat(max(90, points.count * 38 + 40)))
                Text(base.map { String(localized: "Baseline: \(account.planNames[$0] ?? $0). A ratio above 1 means more capacity than the baseline plan for the same normalized work.") }
                     ?? String(localized: "Ratios are relative to the selected baseline plan."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Reference lines derived from the registry, never hard-coded per provider. The equal-cost line
    /// is the price ratio of one large plan to one small plan; the advertised line is the ratio of
    /// their documented five-hour multipliers. For Claude's Max 5x and Max 20x both are 2.0 and 4.0.
    private func referenceLines(base: String?, window: CapacityWindowReport) -> (equalCost: Double?, advertised: Double?)? {
        guard let base, let basePlan = model.db.registry.plan(provider: account.provider, key: base),
              let largeKey = largestPaidPlan(),
              let largePlan = model.db.registry.plan(provider: account.provider, key: largeKey),
              largeKey != base
        else { return nil }
        // The advertised line is window-specific. A provider may publish a five-hour multiplier and
        // no weekly multiplier; in that case weekly shows only the price-based equal-cost reference.
        var advertised: Double?
        if let minutes = window.windowMinutes,
           let baseMultiplier = basePlan.nominalMultiplier(minutes: minutes),
           let largeMultiplier = largePlan.nominalMultiplier(minutes: minutes),
           baseMultiplier > 0 {
            let value = largeMultiplier / baseMultiplier
            if value > 1 { advertised = value }
        }
        // Prefer the quote the report used, so a user-edited price moves the equal-cost line too.
        var equalCost: Double?
        let rows = account.strategyComparisons.first { $0.windowKey == window.windowKey }?.rows
        let basePrice = rows?.first { $0.strategy.planKey == base }?.monthlyPriceMicros ?? basePlan.monthlyPriceMicros
        let largePrice = rows?.first { $0.strategy.planKey == largeKey }?.monthlyPriceMicros ?? largePlan.monthlyPriceMicros
        if basePrice > 0 {
            let value = Double(largePrice) / Double(basePrice)
            if value > 1 { equalCost = value }
        }
        guard equalCost != nil || advertised != nil else { return nil }
        return (equalCost, advertised)
    }

    private func comparisonPoints(_ window: CapacityWindowReport, base: String?) -> [PlanRatioPoint] {
        guard let base else { return [] }
        let ordered = orderedPlanKeys(account: account, window: window)
        return ordered.compactMap { key in
            let ratio: Double?
            if key == base {
                guard window.samples.contains(where: { $0.planKey == key }) else { return nil }
                ratio = 1
            } else {
                ratio = window.estimates.first { $0.basePlanKey == base && $0.otherPlanKey == key }?.ratio
            }
            guard let ratio else { return nil }
            return PlanRatioPoint(id: key, name: account.planNames[key] ?? key, ratio: ratio)
        }
    }

    private func estimateTable(_ window: CapacityWindowReport) -> some View {
        let base = basePlan(window)
        let rows = orderedPlanKeys(account: account, window: window).compactMap { key -> EstimateRow? in
            guard let base else { return nil }
            let estimate = window.estimates.first { $0.basePlanKey == base && $0.otherPlanKey == key }
            return EstimateRow(id: key, name: account.planNames[key] ?? key, estimate: estimate, isBase: key == base)
        }
        return Card(String(localized: "Plan comparison"),
                    subtitle: String(localized: "Measured ratios, sample size, and sensitivity. This is a range across independent comparisons, not a confidence interval.")) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("Plan").font(.caption).foregroundStyle(.secondary)
                    Text("Ratio").font(.caption).foregroundStyle(.secondary)
                    Text("Evidence").font(.caption).foregroundStyle(.secondary)
                    Text("Method").font(.caption).foregroundStyle(.secondary)
                    Text("Cycles (base / plan)").font(.caption).foregroundStyle(.secondary)
                    Text("Matched pairs").font(.caption).foregroundStyle(.secondary)
                    Text("Sensitivity").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name).font(.callout.weight(row.isBase ? .medium : .regular))
                        Text(row.isBase ? "1.00×"
                             : row.estimate?.ratio.map { String(format: "%.2f×", $0) }
                             ?? row.estimate?.provisionalRatio.map { String(format: "%.2f× provisional", $0) } ?? "—")
                            .monospacedDigit()
                        Text(row.isBase ? String(localized: "Baseline")
                             : row.estimate?.level.title ?? String(localized: "Insufficient evidence"))
                            .font(.caption)
                            .foregroundStyle(row.isBase ? .secondary
                                             : row.estimate?.level == .insufficient ? Palette.warning : .secondary)
                        Text(row.isBase ? "—" : row.estimate?.method?.title ?? "—").font(.caption).foregroundStyle(.secondary)
                        Text(row.isBase ? "—" : row.estimate.map { "\($0.baseCycles) / \($0.otherCycles)" } ?? "—").monospacedDigit()
                        Text(row.isBase ? "—" : row.estimate.map { "\($0.matchedPairs)" } ?? "—").monospacedDigit()
                        Text(row.isBase ? "—"
                             : row.estimate?.sensitivityRange.map { String(format: "%.2f–%.2f×", $0.lowerBound, $0.upperBound) } ?? "—")
                            .monospacedDigit()
                    }
                }
            }
            .font(.callout)
            if let base {
                Text("Each ratio is capacity relative to \(account.planNames[base] ?? base). A ratio of 2.0 means the other plan consumed half as many percentage points for the same normalized work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if rows.contains(where: { $0.estimate?.provisionalRatio != nil }) {
                Text("A provisional value comes from a single matched pair. It is shown for orientation only: it is not a published ratio and never drives the purchasing comparison.")
                    .font(.caption).foregroundStyle(Palette.warning)
            }
        }
    }

    private func insufficientEvidence(_ window: CapacityWindowReport) -> some View {
        Card(String(localized: "Not enough evidence for a ratio")) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.warning)
                VStack(alignment: .leading, spacing: 5) {
                    Text("The readings are stored, but no comparison can be published yet.")
                        .font(.callout.weight(.medium))
                    Text("At least two independent cycles per plan and either two matched comparisons or a comparable pooled comparison are required. Readings inside one cycle are not independent samples.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !window.exclusions.isEmpty {
                        Text("Reasons seen: " + window.exclusions.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key.title) (\($0.value))" }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Efficiency

    private func efficiencyCard(_ window: CapacityWindowReport) -> some View {
        let rows = orderedPlanKeys(account: account, window: window).compactMap { key -> EfficiencyRow? in
            let samples = window.samples.filter { $0.planKey == key }
            guard !samples.isEmpty else { return nil }
            let work = samples.reduce(0.0) { $0 + $1.workload.estimatedCostUSD }
            let delta = samples.reduce(0.0) { $0 + $1.deltaPercent }
            guard work > 0 else { return nil }
            return EfficiencyRow(id: key, name: account.planNames[key] ?? key, cycles: samples.count,
                                 workUSD: work, points: delta, per100: delta / work * 100)
        }
        return Card(String(localized: "Quota efficiency"),
                    subtitle: String(localized: "How many quota percentage points the plan consumed per $100 of normalized local work. Lower means more capacity for the same work.")) {
            if rows.isEmpty {
                Text("No eligible cycle has both local work and a measured quota increase.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(rows) { row in
                    BarMark(x: .value("Points per $100", row.per100), y: .value("Plan", row.name))
                        .foregroundStyle(by: .value("Plan", row.name))
                        .cornerRadius(4)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(String(format: "%.1f pts", row.per100)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                .chartLegend(.hidden)
                .frame(height: CGFloat(max(80, rows.count * 34 + 24)))
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    GridRow {
                        Text("Plan").font(.caption).foregroundStyle(.secondary)
                        Text("Cycles").font(.caption).foregroundStyle(.secondary)
                        Text("Work").font(.caption).foregroundStyle(.secondary)
                        Text("Quota consumed").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.name).font(.callout)
                            Text("\(row.cycles)").monospacedDigit()
                            Text(Self.money(row.workUSD)).monospacedDigit()
                            Text(String(format: "%.1f pts", row.points)).monospacedDigit()
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    // MARK: Purchasing

    private func purchasingCard(_ window: CapacityWindowReport) -> some View {
        let comparison = account.strategyComparisons.first { $0.windowKey == window.windowKey }
        return Card(String(localized: "Purchasing comparison"),
                    subtitle: String(localized: "Advertised reference capacity and measured capacity per dollar, using your price entries or published list prices.")) {
            if let comparison {
                if comparison.rows.isEmpty {
                    Text("No strategy can be priced from the registry for this account.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("Strategy").font(.caption).foregroundStyle(.secondary)
                            Text("Monthly").font(.caption).foregroundStyle(.secondary)
                            Text("Advertised").font(.caption).foregroundStyle(.secondary)
                            Text("Measured").font(.caption).foregroundStyle(.secondary)
                            Text("Measured per $").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        ForEach(comparison.rows) { row in
                            GridRow {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.strategy.name).font(.callout.weight(.medium))
                                    Text(row.poolsAreIndependent ? String(localized: "\(row.strategy.count) independent pools") : String(localized: "One pool"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Self.money(row.monthlyCost)).monospacedDigit()
                                    Text(row.priceOrigin == .user ? String(localized: "Your price") : String(localized: "Reference price"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(Self.relative(row.nominalCapacityByWindow[comparison.windowMinutes ?? 0]))
                                    .monospacedDigit()
                                Text(Self.relative(comparison.windowMinutes.flatMap { row.measuredCapacityByWindow[$0] }))
                                    .monospacedDigit()
                                Text(Self.relative(comparison.windowMinutes.flatMap { row.measuredCapacityPerDollar[$0] }) + (comparison.windowMinutes.flatMap { row.measuredCapacityPerDollar[$0] } == nil ? "" : " / $"))
                                    .monospacedDigit()
                            }
                        }
                    }
                    .font(.callout)
                    decision(comparison)
                    if !comparison.caveats.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(comparison.caveats, id: \.self) { caveat in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "info.circle").font(.caption)
                                    Text(caveat).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Add both an advertised plan and measured cycles to compare strategies. Nominal values are shown only as reference and never used as a measured capacity.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !model.db.registry.plans(of: account.provider).isEmpty {
                Button { editingPrices = true } label: { Label("Edit plan prices", systemImage: "dollarsign.circle") }
                    .buttonStyle(.link)
            }
        }
    }

    private func decision(_ comparison: CapacityStrategyComparison) -> some View {
        let pair = comparison.breakEvens.first { $0.numeratorStrategyID.hasPrefix("one-") && $0.denominatorStrategyID.hasPrefix("two-") }
            ?? comparison.breakEvens.first
        return VStack(alignment: .leading, spacing: 4) {
            if let pair,
               let required = pair.requiredRatio,
               let measured = pair.measuredRatio,
               let a = comparison.rows.first(where: { $0.id == pair.denominatorStrategyID }),
               let b = comparison.rows.first(where: { $0.id == pair.numeratorStrategyID }) {
                let wins = measured >= required
                let tie = abs(measured - required) < 1e-9
                Label(tie ? String(localized: "The two strategies are at the measured break-even") :
                            (wins ? String(localized: "\(b.strategy.name) has at least as much measured capacity per dollar") :
                                    String(localized: "\(a.strategy.name) has more measured capacity per dollar")),
                      systemImage: tie ? "equal.circle" : (wins ? "checkmark.seal.fill" : "equal.circle"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tie ? Palette.warning : (wins ? Palette.good : Palette.warning))
                Text(String(format: String(localized: "Break-even requires the second strategy to deliver %.2f× the first. Measured: %.2f×. Monthly cost: %@ versus %@."),
                            required, measured, Self.money(a.monthlyCost), Self.money(b.monthlyCost)))
                    .font(.caption).foregroundStyle(.secondary)
                Text("The measured ratio already includes the number of independent subscriptions in each strategy. Two subscriptions are two pools, not one larger allowance; the comparison assumes each behaves like the measured plan.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Label(String(localized: "Not enough measured cycles for a purchasing conclusion"), systemImage: "questionmark.circle")
                    .font(.callout.weight(.medium)).foregroundStyle(Palette.warning)
                Text("Advertised multipliers are reference values. They are not used to recommend a purchase when the measured evidence is missing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.inset))
    }

    private var strategiesMethodNote: some View {
        Card(String(localized: "About the strategy comparison")) {
            Text("The strategies shown here are two independent subscriptions of the smallest paid plan above baseline, compared with one subscription of the largest paid plan. Plans come from the provider registry; reference prices are not charges and can be overridden in the capacity page. When measured capacity is unavailable, the page shows the reference values but makes no purchasing recommendation.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Plan timeline

    private var planTimelineCard: some View {
        let periods = account.planPeriods.compactMap { assignment -> TimelinePeriod? in
            let start = max(assignment.effectiveFrom, range.lowerBound)
            let end = min(assignment.effectiveTo ?? range.upperBound, range.upperBound)
            guard end > start else { return nil }
            return TimelinePeriod(id: assignment.id, name: account.planNames[assignment.planKey ?? ""] ?? assignment.planKey ?? String(localized: "Unknown plan"),
                                  planKey: assignment.planKey, start: start, end: end,
                                  provenance: assignment.provenance)
        }
        let names = Array(Set(periods.map(\.name))).sorted()
        return Card(String(localized: "Plan history"),
                    subtitle: String(localized: "Half-open periods: an end is exclusive, so one plan can end exactly when the next begins. Overlaps invalidate comparisons until corrected.")) {
            if periods.isEmpty {
                Text("No plan period overlaps the selected range. All recorded periods are listed below.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(periods) { period in
                    RectangleMark(xStart: .value("From", period.start),
                                  xEnd: .value("To", period.end),
                                  y: .value("Plan", period.name))
                        .foregroundStyle(by: .value("Plan", period.name))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(domain: names, range: names.indices.map { Palette.series[$0 % Palette.series.count] })
                .chartLegend(.hidden)
                .frame(height: CGFloat(max(70, names.count * 30 + 22)))
                .chartXScale(domain: range)
            }
            ForEach(account.planPeriods) { assignment in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: assignment.isOpen ? "circle.fill" : "circle")
                        .font(.system(size: 7))
                        .foregroundStyle(assignment.isOpen ? Palette.good : Palette.other)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(account.planNames[assignment.planKey ?? ""] ?? assignment.planKey ?? String(localized: "Unknown plan"))
                                .font(.callout.weight(.medium))
                            if let label = assignment.accountLabel, !label.isEmpty {
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(assignment.provenance == .providerReported ? String(localized: "Provider reported") : String(localized: "Manual"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(Self.periodText(assignment, now: range.upperBound)).font(.caption).foregroundStyle(.secondary)
                        if !assignment.note.isEmpty { Text(assignment.note).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Edit") { planEditor = .edit(assignment) }.buttonStyle(.link)
                    Button("Delete", role: .destructive) { deleting = assignment }.buttonStyle(.link)
                }
            }
            Button { planEditor = .add } label: { Label("Add plan period", systemImage: "plus") }
        }
    }

    // MARK: Measurements

    private var measurementsCard: some View {
        MeasurementSection(account: account, selectedWindowKey: window?.windowKey, onChanged: onChanged)
    }

    // MARK: Quality

    private var qualityCard: some View {
        let window = window
        return Card(String(localized: "Evidence quality"),
                    subtitle: String(localized: "What is known, what is estimated, and what is missing. No confidence score is invented.")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: account.identityBasis == .providerVerified ? "checkmark.seal.fill" : "questionmark.circle.fill")
                        .foregroundStyle(account.identityBasis == .providerVerified ? Palette.good : Palette.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.identityBasis.title).font(.callout.weight(.medium))
                        Text(account.identityBasis.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(account.warnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.warning)
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let window {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                        GridRow { Text("Quota resolution").foregroundStyle(.secondary); Text(window.history.quotaResolution.map { String(format: "%.1f points", $0) } ?? "—") }
                        GridRow { Text("Independent cycles").foregroundStyle(.secondary); Text("\(window.history.cycles.count)") }
                        GridRow { Text("Cycles at the limit").foregroundStyle(.secondary); Text("\(window.completeCycles)") }
                        GridRow { Text("Usable cycle samples").foregroundStyle(.secondary); Text("\(window.samples.count)") }
                        GridRow { Text("Readings discarded").foregroundStyle(.secondary); Text("\(window.history.discarded.values.reduce(0, +))") }
                    }.font(.callout)
                    let outliers = Set(window.estimates.flatMap(\.outlierCycleIDs)).sorted()
                    if !outliers.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.warning)
                            Text("Outlier cycles removed: \(outliers.count) (ids \(outliers.map(String.init).joined(separator: ", "))). The raw readings stay stored.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !window.exclusions.isEmpty {
                        Text("Why observations were excluded").font(.caption.weight(.medium)).padding(.top, 3)
                        ForEach(window.exclusions.sorted { $0.value > $1.value }, id: \.key) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(item.value)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                                Text(item.key.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    /// The smallest paid plan that actually has a recorded period, by its advertised five-hour
    /// multiplier. A provider is free to define none, in which case the first plan with evidence is
    /// used. The ratio chart is always relative to this key.
    func basePlan(_ window: CapacityWindowReport) -> String? {
        let plans = model.db.registry.plans(of: account.provider)
        let paid = plans.filter { ($0.nominalMultiplier(minutes: 300) ?? 0) > 1 }
            .sorted { ($0.nominalMultiplier(minutes: 300) ?? 0) < ($1.nominalMultiplier(minutes: 300) ?? 0) }
        if let plan = paid.first(where: { window.planKeys.contains($0.key) }) { return plan.key }
        return window.planKeys.first
    }

    func largestPaidPlan() -> String? {
        let plans = model.db.registry.plans(of: account.provider)
        let paid = plans.filter { ($0.nominalMultiplier(minutes: 300) ?? 0) > 1 }
            .sorted { ($0.nominalMultiplier(minutes: 300) ?? 0) < ($1.nominalMultiplier(minutes: 300) ?? 0) }
        return paid.last(where: { plan in account.planPeriods.contains { $0.planKey == plan.key } })?.key
    }

    private func orderedPlanKeys(account: CapacityAccountReport, window: CapacityWindowReport) -> [String] {
        let registryOrder = model.db.registry.plans(of: account.provider).map(\.key)
        let assignmentOrder = account.planPeriods.compactMap(\.planKey)
        var seen = Set<String>()
        var out: [String] = []
        for key in registryOrder + assignmentOrder + window.planKeys where seen.insert(key).inserted { out.append(key) }
        return out.filter { window.planKeys.contains($0) || assignmentOrder.contains($0) }
    }

    static func periodText(_ assignment: PlanAssignment, now: Date) -> String {
        let start = assignment.effectiveFrom.formatted(date: .abbreviated, time: .omitted)
        if let end = assignment.effectiveTo {
            return String(localized: "\(start) – \(end.formatted(date: .abbreviated, time: .omitted))")
        }
        return String(localized: "\(start) – ongoing")
    }

    static func money(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    static func relative(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f×", value)
    }
}

// MARK: - Support types

private struct PlanRatioPoint: Identifiable {
    var id: String
    var name: String
    var ratio: Double
}

private struct EstimateRow: Identifiable {
    var id: String
    var name: String
    var estimate: CapacityEstimate?
    var isBase: Bool
}

private struct EfficiencyRow: Identifiable {
    var id: String
    var name: String
    var cycles: Int
    var workUSD: Double
    var points: Double
    var per100: Double
}

private struct TimelinePeriod: Identifiable {
    var id: Int64
    var name: String
    var planKey: String?
    var start: Date
    var end: Date
    var provenance: PlanAssignmentProvenance
}

private enum PlanEditorMode: Identifiable {
    case add
    case edit(PlanAssignment)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let assignment): "edit-\(assignment.id)"
        }
    }

    var assignment: PlanAssignment? {
        switch self {
        case .add: nil
        case .edit(let assignment): assignment
        }
    }
}

// MARK: - Plan prices

private struct PlanPriceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let provider: ProviderID
    let onSaved: () -> Void

    @State private var drafts: [String: String] = [:]
    @State private var originalMicros: [String: Int64] = [:]
    @State private var resetKeys: Set<String> = []
    @State private var error: String?

    private var plans: [SubscriptionPlanDefinition] { model.db.registry.plans(of: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Plan prices").font(.title3.weight(.semibold))
            Text("Monthly list prices are used only for the purchasing comparison. They never change whether a capacity ratio is published. Leave a field at its reference price to keep using the registry value.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(plans) { plan in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.name).font(.callout.weight(.medium))
                        Text(resetKeys.contains(plan.key) ? String(localized: "Reference price") :
                             (userPriceExists(plan) ? String(localized: "Your price") : String(localized: "Reference price")))
                            .font(.caption2).foregroundStyle(.secondary)
                        if let asOf = plan.priceAsOf {
                            Text("Reference as of \(asOf)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Text(plan.currency).font(.caption).foregroundStyle(.secondary)
                    TextField("Monthly price", text: Binding(
                        get: { drafts[plan.key] ?? "" },
                        set: { drafts[plan.key] = $0; resetKeys.remove(plan.key) }))
                        .textFieldStyle(.roundedBorder).frame(width: 110).monospacedDigit()
                    Button("Use reference") {
                        drafts[plan.key] = String(format: "%.2f", Double(plan.monthlyPriceMicros) / 1_000_000)
                        resetKeys.insert(plan.key)
                    }.buttonStyle(.link)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Palette.critical) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private func userPriceExists(_ plan: SubscriptionPlanDefinition) -> Bool {
        PlanPriceStore.quote(model.db, plan: plan).origin == .user
    }

    private func load() {
        for plan in plans {
            let quote = PlanPriceStore.quote(model.db, plan: plan)
            drafts[plan.key] = String(format: "%.2f", quote.monthlyPrice)
            originalMicros[plan.key] = quote.monthlyPriceMicros
        }
    }

    private func save() {
        do {
            for plan in plans {
                if resetKeys.contains(plan.key) {
                    try PlanPriceStore.removeUserPrices(model.db, provider: provider, planKey: plan.key)
                    continue
                }
                let text = (drafts[plan.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = Double(text), value >= 0, value.isFinite,
                      value <= Double(PlanPriceStore.maximumMonthlyPriceMicros) / 1_000_000 else {
                    throw PlanPriceError.invalidPrice
                }
                let micros = Int64((value * 1_000_000).rounded())
                if micros == plan.monthlyPriceMicros {
                    // Keeping the reference value should not look like a user override.
                    try PlanPriceStore.removeUserPrices(model.db, provider: provider, planKey: plan.key)
                } else if micros == originalMicros[plan.key] {
                    // Saving another row's change must not append a redundant price history row here.
                    continue
                } else {
                    try PlanPriceStore.setPrice(model.db, plan: plan, monthlyPriceMicros: micros,
                                                currency: plan.currency)
                }
            }
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Plan editor

private struct PlanPeriodEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: CapacityAccountReport
    let assignment: PlanAssignment?
    let onSaved: () -> Void

    @State private var planKey: String
    @State private var accountLabel: String
    @State private var start: Date
    @State private var hasEnd: Bool
    @State private var end: Date
    @State private var note: String
    @State private var error: String?

    init(account: CapacityAccountReport, assignment: PlanAssignment?, onSaved: @escaping () -> Void) {
        self.account = account
        self.assignment = assignment
        self.onSaved = onSaved
        _planKey = State(initialValue: assignment?.planKey ?? "")
        _accountLabel = State(initialValue: assignment?.accountLabel ?? "")
        _start = State(initialValue: assignment?.effectiveFrom ?? Date())
        _hasEnd = State(initialValue: assignment?.effectiveTo != nil)
        _end = State(initialValue: assignment?.effectiveTo ?? Date().addingTimeInterval(30 * 86_400))
        _note = State(initialValue: assignment?.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(assignment == nil ? String(localized: "Add plan period") : String(localized: "Edit plan period"))
                .font(.title3.weight(.semibold))
            Text("This is metadata about your subscription, not a provider-verified identity. Periods for one account cannot overlap.")
                .font(.caption).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("Plan").foregroundStyle(.secondary)
                    Picker("Plan", selection: $planKey) {
                        Text("Unknown").tag("")
                        ForEach(model.db.registry.plans(of: account.provider)) { plan in
                            Text(plan.name).tag(plan.key)
                        }
                    }.labelsHidden().frame(width: 260)
                }
                GridRow {
                    Text("Account label").foregroundStyle(.secondary)
                    TextField("Optional, for you only", text: $accountLabel).frame(width: 260)
                }
                GridRow {
                    Text("Starts").foregroundStyle(.secondary)
                    DatePicker("Starts", selection: $start).labelsHidden()
                }
                GridRow {
                    Text("Ends").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Toggle("Has an end", isOn: $hasEnd)
                        if hasEnd { DatePicker("Ends", selection: $end).labelsHidden() }
                    }
                }
                GridRow {
                    Text("Note").foregroundStyle(.secondary)
                    TextField("Optional", text: $note, axis: .vertical).lineLimit(1...3).frame(width: 260)
                }
            }
            .font(.callout)

            if let error {
                Text(error).font(.callout).foregroundStyle(Palette.critical).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private func save() {
        let draft = PlanAssignmentDraft(
            provider: account.provider, accountID: account.accountID,
            planKey: planKey.isEmpty ? nil : planKey,
            accountLabel: accountLabel.isEmpty ? nil : accountLabel,
            effectiveFrom: start, effectiveTo: hasEnd ? end : nil,
            provenance: assignment?.provenance ?? .manual, note: note)
        do {
            if let assignment {
                try PlanHistoryStore.update(model.db, id: assignment.id, draft)
            } else {
                try PlanHistoryStore.create(model.db, draft)
            }
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Measurements

private struct MeasurementSection: View {
    @Environment(AppModel.self) private var model
    let account: CapacityAccountReport
    let selectedWindowKey: String?
    let onChanged: () -> Void

    @State private var label = ""
    @State private var windowKey: String?
    @State private var error: String?
    @State private var deleting: CapacityMeasurement?

    private var reviews: [CapacityMeasurementReview] { account.measurements }
    private var chosenWindow: CapacityWindowReport? {
        let key = windowKey ?? selectedWindowKey
        return account.windows.first { $0.windowKey == key } ?? account.windows.first
    }
    private var open: CapacityMeasurement? {
        reviews.map(\.measurement).first { $0.state == .open && $0.windowKey == chosenWindow?.windowKey }
    }

    var body: some View {
        Card(String(localized: "Labelled measurements"),
             subtitle: String(localized: "Optional. Label a period of ordinary work; the app snaps it to the surrounding provider readings and measures the local work between those readings.")) {
            if reviews.isEmpty {
                Text("No labelled measurement yet. Ordinary history is still analyzed by plan period.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(reviews) { review in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: review.isUsable ? "checkmark.circle.fill" : (review.measurement.state == .open ? "clock" : "exclamationmark.circle"))
                            .foregroundStyle(review.isUsable ? Palette.good : (review.measurement.state == .open ? Palette.warning : Palette.other))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(review.measurement.label).font(.callout.weight(.medium))
                                Text(account.windows.first { $0.windowKey == review.measurement.windowKey }?.windowName ?? review.measurement.windowKey)
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(review.measurement.state.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text("\(Fmt.dateTime(review.measurement.startedAt)) – \(Fmt.dateTime(review.measurement.endedAt))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let baseline = review.baseline, let ending = review.ending, let delta = review.deltaPercent {
                                Text(String(format: String(localized: "%.1f points · %@ work · %d requests"), delta,
                                            Fmt.cost(review.workload.cost), review.workload.requests))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Readings: \(Fmt.dateTime(baseline.observedAt)) → \(Fmt.dateTime(ending.observedAt))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            if !review.exclusions.isEmpty {
                                Text(review.exclusions.map(\.title).joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(Palette.warning)
                            }
                        }
                        Spacer()
                        if review.measurement.state == .open {
                            Button("End now") { end(review.measurement) }.buttonStyle(.link)
                        }
                        Button("Delete", role: .destructive) { deleting = review.measurement }.buttonStyle(.link)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Picker("Window", selection: Binding(get: { chosenWindow?.windowKey ?? "" }, set: { windowKey = $0 })) {
                    ForEach(account.windows) { w in Text(w.windowName).tag(w.windowKey) }
                }.labelsHidden().frame(width: 130)
                TextField("Label, for example “Weekly normal work”", text: $label).frame(maxWidth: 300)
                Button(open == nil ? "Start measurement" : "End and start new") {
                    if let open { end(open) }
                    start()
                }
                .disabled(chosenWindow == nil)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Palette.critical) }
        }
        .confirmationDialog("Delete this measurement?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting { try? CapacityMeasurementStore.delete(model.db, id: deleting.id) }
                self.deleting = nil
                onChanged()
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Only the label and its review are deleted. Quota readings and local requests stay.")
        }
    }

    private func start() {
        guard let window = chosenWindow else { return }
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try CapacityMeasurementStore.begin(model.db, provider: account.provider, accountID: account.accountID,
                                                poolKey: account.poolKey, windowKey: window.windowKey,
                                                label: text.isEmpty ? String(localized: "Capacity check") : text)
            label = ""
            error = nil
            onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func end(_ measurement: CapacityMeasurement) {
        do {
            try CapacityMeasurementStore.close(model.db, id: measurement.id)
            error = nil
            onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
