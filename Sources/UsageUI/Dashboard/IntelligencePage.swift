import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import UsageCore

/// Everything the page shows for one quota window, computed together off the main thread.
struct IntelligenceBundle: Sendable {
    var report: SubscriptionUsageReport
    var forecast: UsageForecast
    var insights: [UsageInsight]
    var now: Date
}

/// Usage intelligence: how local usage relates to the quota that the provider reports, cycle by cycle.
///
/// The page presents what `UsageCore` computed. Quota percentages are the provider's own readings and are never derived
/// from tokens. Calculated cycles, partial observations, estimates and forecasts are each labelled as what they are.
struct IntelligencePage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("intelligence.timeZone") private var zoneID = ""
    @AppStorage("intelligence.subject") private var storedSubject = ""
    @AppStorage("intelligence.cycles") private var cycleCount = 8
    @AppStorage("intelligence.calendarDays") private var calendarDays = false
    @State private var subjects: [IntelligenceSubject] = []
    @State private var bundle: IntelligenceBundle?
    @State private var selectedCycleID: String?
    @State private var loading = false
    @State private var error: String?
    @State private var revision = 0
    @State private var generation = 0
    @State private var hasLoaded = false
    @State private var overlayComparable = true
    @State private var exportStatus: String?
    @State private var associations: [AccountAssociation] = []
    @State private var associateFrom = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var associateTo = Date()
    @State private var associateOpenEnded = false
    @State private var associationError: String?
    @State private var showingZonePicker = false

    private var zone: TimeZone { IntelligenceLogic.zone(for: zoneID) }

    var body: some View {
        PageScroll {
            header
            if let bundle {
                let selected = bundle.report.cycles.first { $0.id == selectedCycleID }
                    ?? bundle.report.currentCycle ?? bundle.report.cycles.last
                overview(bundle)
                associationCard(bundle)
                forecastCard(bundle)
                insightsCard(bundle)
                historyCard(bundle)
                if let selected {
                    detailCard(selected, bundle: bundle)
                    cumulativeCard(selected, bundle: bundle)
                    if !selected.days.isEmpty { dailyCard(selected) }
                }
            } else if loading {
                ProgressView("Reading quota history…").frame(maxWidth: .infinity, minHeight: 180)
            } else if let error {
                Card(String(localized: "Usage intelligence could not be loaded")) {
                    Text(error).font(.callout).foregroundStyle(Palette.critical)
                    Button("Try again") { revision += 1 }
                }
            } else {
                emptyState
            }
            methodology
        }
        .sheet(isPresented: $showingZonePicker) { ZonePickerSheet(selection: $zoneID) }
        // A choice the user just made is answered at once. New data arrives in bursts while a tool is running, so it waits long
        // enough for a burst to settle, and a newer change cancels the wait.
        .task(id: "\(storedSubject)|\(cycleCount)|\(calendarDays)|\(revision)|\(zoneID)") { await load(settle: .milliseconds(30)) }
        .task(id: model.dataVersion) { if hasLoaded { await load(settle: .seconds(3)) } }
    }

    // MARK: Header

    private var header: some View {
        Card(String(localized: "Usage intelligence"),
             subtitle: String(localized: "How your local usage relates to the allowance your provider reports. Percentages are the provider's readings; tokens are what this Mac recorded.")) {
            HStack(alignment: .center, spacing: 12) {
                Picker("Quota window", selection: Binding(get: { currentSubject?.id ?? "" }, set: { storedSubject = $0 })) {
                    ForEach(subjects) { Text(label(for: $0)).tag($0.id) }
                }
                .frame(maxWidth: 420)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { revision += 1 } label: { Label("Recompute", systemImage: "arrow.clockwise") }.disabled(loading)
            }
            HStack(alignment: .center, spacing: 12) {
                Picker("Cycles", selection: $cycleCount) {
                    Text("4").tag(4); Text("8").tag(8); Text("12").tag(12)
                }
                .pickerStyle(.segmented).frame(maxWidth: 200)
                Picker("Days", selection: $calendarDays) {
                    Text("Subscription days").tag(false)
                    Text("Calendar days").tag(true)
                }
                .pickerStyle(.segmented).frame(maxWidth: 300).labelsHidden()
                Menu {
                    ForEach(zoneChoices, id: \.self) { identifier in
                        Button { zoneID = identifier } label: {
                            if identifier == zoneID { Label(zoneTitle(identifier), systemImage: "checkmark") } else { Text(zoneTitle(identifier)) }
                        }
                    }
                    Divider()
                    Button("Other time zone…") { showingZonePicker = true }
                } label: {
                    Label(String(localized: "Time zone: \(zoneTitle(zoneID))"), systemImage: "globe")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Menu {
                    Button("Export as JSON…") { export(.json) }
                    Button("Export as CSV…") { export(.csv) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if let exportStatus { Text(exportStatus).font(.caption).foregroundStyle(.secondary) }
            if let bundle {
                Text("Computed \(Fmt.dateTime(bundle.now)). Times are shown in \(IntelligenceLogic.offsetLabel(zone, at: bundle.now)); stored boundaries are in UTC.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// A short list of zones in a menu. Every zone the system knows is offered in a sheet whose list is built lazily: a menu or a picker
    /// of all of them is built eagerly and cost about 70 MB while the page was open.
    private var zoneChoices: [String] {
        var out = ["", "UTC", "Europe/Istanbul", "Europe/London", "Europe/Berlin", "America/New_York", "America/Chicago", "America/Los_Angeles",
                   "Asia/Dubai", "Asia/Kolkata", "Asia/Tokyo", "Australia/Sydney"]
        if !out.contains(zoneID) { out.insert(zoneID, at: 2) }
        return out
    }

    private func zoneTitle(_ identifier: String) -> String {
        identifier.isEmpty ? String(localized: "Current (\(IntelligenceLogic.offsetLabel(.current, at: Date())))") : identifier
    }

    private var currentSubject: IntelligenceSubject? {
        subjects.first { $0.id == storedSubject } ?? IntelligenceLogic.defaultSubject(subjects)
    }

    private func label(for subject: IntelligenceSubject) -> String {
        let window = WindowNaming.displayName(minutes: subject.windowMinutes, fallbackKey: subject.windowKey)
        return "\(model.providerName(subject.provider)) · \(subject.accountLabel) · \(window)"
    }

    private func windowName(_ subject: IntelligenceSubject) -> String {
        WindowNaming.displayName(minutes: subject.windowMinutes, fallbackKey: subject.windowKey).lowercased()
    }

    // MARK: Overview

    private func overview(_ b: IntelligenceBundle) -> some View {
        let report = b.report
        let current = report.currentCycle
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                KPITile(title: String(localized: "Subscription plan"),
                        value: current?.plan?.name ?? String(localized: "Not recorded"),
                        detail: current?.plan == nil || current?.plan?.recorded == false
                            ? String(localized: "Record one under Capacity to compare plans.")
                            : (current?.plan?.changedDuringCycle == true ? String(localized: "The plan changed during this cycle.") : nil))
                if let current {
                    KPITile(title: String(localized: "Current cycle"),
                            value: IntelligenceLogic.shortDate(current.span.start, zone: zone) + " → " + IntelligenceLogic.shortDate(current.span.end, zone: zone),
                            detail: current.span.origin == .observed ? String(localized: "Ends at a reset time the provider reported.")
                                                                     : String(localized: "Calculated from the reset schedule."))
                    KPITile(title: current.span.origin == .observed ? String(localized: "Next reset") : String(localized: "Next reset (expected)"),
                            value: IntelligenceLogic.dateTime(current.span.end, zone: zone),
                            detail: IntelligenceLogic.utc(current.span.end))
                    KPITile(title: String(localized: "Reported utilization"),
                            value: Fmt.percent(current.quota?.lastPercent),
                            detail: utilizationDetail(current, now: b.now))
                    if current.local.isEmpty, current.unattributed.requests > 0 {
                        KPITile(title: String(localized: "Local tokens this cycle"), value: "—",
                                detail: String(localized: "\(Fmt.tokens(current.unattributed.processedTokens)) tokens are not tied to this account"))
                    } else {
                        KPITile(title: String(localized: "Local tokens this cycle"), value: Fmt.tokens(current.local.processedTokens),
                                detail: String(localized: "\(Fmt.tokens(current.local.tokens.freshTokens)) fresh · \(Fmt.grouped(Int64(current.local.requests))) requests"))
                    }
                    KPITile(title: String(localized: "Forecast at the reset"), value: IntelligenceLogic.rangeText(b.forecast) ?? "—",
                            detail: b.forecast.isAvailable ? String(localized: "Estimated, not a provider limit.")
                                                           : String(localized: "Not enough reliable quota history to forecast usage."))
                } else {
                    KPITile(title: String(localized: "Current cycle"), value: "—",
                            detail: String(localized: "No cycle is in progress. The provider has not reported a new window yet."))
                }
            }
            readinessCard(b)
        }
    }

    /// Says what this page can and cannot tell right now, and what would change that.
    private func readinessCard(_ b: IntelligenceBundle) -> some View {
        let notes = IntelligenceLogic.readiness(b.report, forecast: b.forecast, zone: zone, now: b.now)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(notes) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: note.level == .available ? "checkmark.circle" : "info.circle")
                        .foregroundStyle(note.level == .available ? Palette.good : Color.secondary)
                    Text(note.text).font(.callout).foregroundStyle(note.level == .available ? Color.primary : Color.secondary)
                }
            }
            if b.report.notes.contains(.unassignedHistoryExists) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "tray.2").foregroundStyle(.secondary)
                    Text("Earlier readings without an account exist for this provider. They are kept apart because their account cannot be proven to be this one. Choose the unassigned window above to see them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.inset))
    }

    private func utilizationDetail(_ cycle: SubscriptionCycleReport, now: Date) -> String {
        guard let quota = cycle.quota, let at = quota.lastConfirmedAt else { return String(localized: "No reading in this cycle yet.") }
        let age = Fmt.duration(now.timeIntervalSince(at))
        return String(localized: "Last confirmed \(age) ago")
    }

    // MARK: Account association

    /// Lets the user say which account used this Mac during a period, for sessions whose files name no account. Nothing is
    /// associated until the user does it here, and each association can be removed again.
    @ViewBuilder
    private func associationCard(_ b: IntelligenceBundle) -> some View {
        let needed = b.report.cycles.contains { $0.unattributed.requests > 0 }
        if b.report.subject.accountIsIdentified, needed || !associations.isEmpty {
            Card(String(localized: "Which sessions were this account's?"),
                 subtitle: String(localized: "Some sessions name no account, so Tokenwatch cannot tell whose quota they used. You can say which account used this Mac during a period. The sessions themselves are not changed, and you can remove the statement at any time.")) {
                ForEach(associations) { item in
                    HStack {
                        Text("\(Fmt.dateTime(item.effectiveFrom)) → \(item.effectiveTo.map(Fmt.dateTime) ?? String(localized: "until changed"))")
                            .font(.callout)
                        if item.accountID == b.report.subject.accountID {
                            Text("this account").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("another account").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { removeAssociation(item.id) }.buttonStyle(.link)
                    }
                }
                HStack(spacing: 10) {
                    DatePicker("From", selection: $associateFrom).labelsHidden().fixedSize()
                    Text("to")
                    if associateOpenEnded {
                        Text("until changed").foregroundStyle(.secondary)
                    } else {
                        DatePicker("To", selection: $associateTo).labelsHidden().fixedSize()
                    }
                    Toggle("Open-ended", isOn: $associateOpenEnded).toggleStyle(.checkbox)
                    Spacer()
                    Button("These sessions were this account's") { addAssociation(b.report.subject) }
                        .disabled(!associateOpenEnded && associateTo <= associateFrom)
                }
                if let associationError { Text(associationError).font(.caption).foregroundStyle(Palette.critical) }
                Text("Use this only for periods when you are sure that one account was in use. While two accounts were active, leave it alone: the activity stays excluded from ratios.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func addAssociation(_ subject: IntelligenceSubject) {
        let db = model.db
        let from = associateFrom, to = associateOpenEnded ? nil : associateTo
        Task.detached {
            do {
                _ = try AccountAssociationStore.create(db, provider: subject.provider, accountID: subject.accountID, from: from, to: to)
                await MainActor.run { associationError = nil; revision += 1 }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { associationError = message }
            }
        }
    }

    private func removeAssociation(_ id: Int64) {
        let db = model.db
        Task.detached {
            try? AccountAssociationStore.delete(db, id: id)
            await MainActor.run { revision += 1 }
        }
    }

    // MARK: Forecast

    /// Keeps four different things apart: what the provider reported, what was observed so far, what is forecast, and how sure the
    /// forecast is.
    private func forecastCard(_ b: IntelligenceBundle) -> some View {
        let forecast = b.forecast
        let window = windowName(b.report.subject)
        return Card(String(localized: "Forecast"),
                    subtitle: String(localized: "Will the allowance last until the reset? An estimate from reported utilization, never a provider limit.")) {
            switch forecast.availability {
            case .limitReached:
                Label("The reported utilization has reached the limit. There is nothing left to forecast until the reset.", systemImage: "exclamationmark.octagon")
                    .foregroundStyle(Palette.critical)
            case .unavailable(let reasons):
                VStack(alignment: .leading, spacing: 8) {
                    reportedNow(forecast)
                    Text("Not enough reliable quota history to forecast usage.").font(.headline)
                    ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                        Label(IntelligenceLogic.unavailableText(reason), systemImage: "minus.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    observedSoFar(forecast)
                }
            case .forecast:
                forecastBody(forecast, window: window, b: b)
            }
        }
    }

    @ViewBuilder
    private func reportedNow(_ forecast: UsageForecast) -> some View {
        if let current = forecast.currentPercent, let asOf = forecast.asOf {
            VStack(alignment: .leading, spacing: 3) {
                Text("Reported by the provider").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(current.rounded()))%").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("as of \(IntelligenceLogic.dateTime(asOf, zone: zone))").font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: min(current, 100), total: 100).tint(Palette.quota(current))
            }
        }
    }

    @ViewBuilder
    private func observedSoFar(_ forecast: UsageForecast) -> some View {
        if let pace = forecast.observedPacePointsPerDay {
            Text("Observed so far in this cycle: about \(String(format: "%.1f", pace)) points per day. This is a measurement, not a projection.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func forecastBody(_ forecast: UsageForecast, window: String, b: IntelligenceBundle) -> some View {
        let range = IntelligenceLogic.rangeText(forecast) ?? "—"
        let end = forecast.cycleEnd.map { IntelligenceLogic.dateTime($0, zone: zone) } ?? ""
        VStack(alignment: .leading, spacing: 10) {
            reportedNow(forecast)
            observedSoFar(forecast)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("Forecast at the reset (\(end))").font(.caption).foregroundStyle(.secondary)
                Text(range).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("The range is how far off earlier forecasts of this kind were on cycles they had not seen (all of them while there are few, the middle 80% once there are many). It is not a confidence level.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let exhaustion = forecast.exhaustion {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Estimated exhaustion").font(.caption).foregroundStyle(.secondary)
                    Label(exhaustionText(exhaustion, window: window), systemImage: "hourglass.bottomhalf.filled").font(.callout).foregroundStyle(Palette.warning)
                }
            } else {
                Label("At this pace the allowance should last until the reset.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            }
            if let work = forecast.remainingWork {
                let processed = Fmt.tokens(Int64(work.processedTokens.low)) + "–" + Fmt.tokens(Int64(work.processedTokens.high))
                Text("The rest of the allowance may hold roughly \(processed) more processed tokens of comparable work, based on \(work.basedOnCycles) earlier cycles. This is an observed relationship, not a token allowance.")
                    .font(.callout)
            }
            evidenceLine(forecast)
            ForEach(forecast.warnings, id: \.self) { warning in
                Label(IntelligenceLogic.warningText(warning), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func exhaustionText(_ e: ExhaustionEstimate, window: String) -> String {
        let earliest = IntelligenceLogic.dayPart(e.earliest, zone: zone)
        switch (e.confidence, e.latest) {
        case (.likely, let latest?):
            let a = IntelligenceLogic.dateTime(e.earliest, zone: zone), c = IntelligenceLogic.dateTime(latest, zone: zone)
            return String(localized: "At your recent pace your \(window) allowance may run out around \(earliest), between \(a) and \(c).")
        default:
            return String(localized: "Your \(window) allowance could run out as early as \(earliest) if the pace holds. The forecast range also includes reaching the reset first.")
        }
    }

    @ViewBuilder
    private func evidenceLine(_ forecast: UsageForecast) -> some View {
        let evidence = forecast.evidence
        VStack(alignment: .leading, spacing: 2) {
            if let method = forecast.method, let error = evidence.meanAbsoluteError, let bias = evidence.bias {
                let name = IntelligenceLogic.methodName(method)
                let direction = bias > 0.5 ? String(localized: "tends to underestimate")
                              : (bias < -0.5 ? String(localized: "tends to overestimate") : String(localized: "shows no consistent bias"))
                Text("Method: \(name). Checked on \(evidence.heldOutCases) earlier forecasts from \(evidence.heldOutCycles) cycles, each made with a method chosen without knowing its outcome: typically off by \(String(format: "%.1f", error)) points, and it \(direction).")
                    .font(.caption).foregroundStyle(.secondary)
                if let coverage = evidence.rollingCoverage {
                    Text("The range held the real outcome in \(coverage.hits) of \(coverage.total) cases that could be checked this way.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Insights

    private func insightsCard(_ b: IntelligenceBundle) -> some View {
        Card(String(localized: "What stands out"), subtitle: String(localized: "Statements generated directly from the recorded numbers. Nothing here is written by a language model.")) {
            if b.insights.isEmpty {
                Text("Nothing stands out yet. Insights appear once there are enough cycles to compare.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(b.insights) { insight in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: insight.priority >= 90 ? "exclamationmark.triangle.fill" : "lightbulb")
                            .foregroundStyle(insight.priority >= 90 ? Palette.warning : Color.secondary)
                        Text(IntelligenceLogic.text(for: insight, window: windowName(b.report.subject), zone: zone)).font(.callout)
                    }
                }
            }
        }
    }

    // MARK: History

    private func historyCard(_ b: IntelligenceBundle) -> some View {
        let cycles = Array(b.report.cycles.filter { $0.timing != .future }.suffix(cycleCount))
        let rows = IntelligenceLogic.historyRows(cycles, zone: zone)
        return Card(String(localized: "History by cycle"),
                    subtitle: String(localized: "Local processed tokens above, the highest utilization the provider reported below. They are different quantities on different scales.")) {
            if rows.isEmpty {
                Text("No cycles to show yet.").foregroundStyle(.secondary)
            } else {
                Text("Local processed tokens (this Mac)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                tokensChart(rows)
                Text("Highest utilization reported by the provider (account-wide)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                utilizationChart(rows)
                historyLegend
                historyTable(cycles)
            }
        }
    }

    private var percentTicks: [Double] { [0, 25, 50, 75, 100] }

    private func cycleAxis(_ rows: [IntelligenceLogic.HistoryRow]) -> some AxisContent {
        AxisMarks(values: rows.map(\.id)) { v in
            AxisValueLabel { if let id = v.as(String.self), let row = rows.first(where: { $0.id == id }) { Text(row.label) } }
        }
    }

    private func tokensChart(_ rows: [IntelligenceLogic.HistoryRow]) -> some View {
        Chart {
            ForEach(rows) { row in
                tokenBars(row)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Palette.gridLine)
                AxisValueLabel { if let d = v.as(Int64.self) { Text(Fmt.tokens(d)) } }
            }
        }
        .chartXScale(domain: rows.map(\.id))
        .chartXAxis { cycleAxis(rows) }
        .frame(height: 170)
    }

    @ChartContentBuilder
    private func tokenBars(_ row: IntelligenceLogic.HistoryRow) -> some ChartContent {
        BarMark(x: .value("Cycle", row.id), y: .value("Tokens", row.processedTokens), width: .ratio(0.6))
            .foregroundStyle(color(for: row.status))
        if row.unattributedTokens > 0 {
            BarMark(x: .value("Cycle", row.id), y: .value("Tokens", row.unattributedTokens), width: .ratio(0.6))
                .foregroundStyle(Palette.other.opacity(0.3))
        }
    }

    private func utilizationChart(_ rows: [IntelligenceLogic.HistoryRow]) -> some View {
        let observed = rows.filter { $0.maximumPercent != nil }
        return Chart {
            RuleMark(y: .value("Limit", 100)).foregroundStyle(Palette.critical.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(observed) { row in
                utilizationMark(row)
            }
        }
        .chartYScale(domain: 0...105)
        .chartYAxis {
            AxisMarks(position: .leading, values: percentTicks) { v in
                AxisGridLine().foregroundStyle(Palette.gridLine)
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } }
            }
        }
        .chartXScale(domain: rows.map(\.id))
        .chartXAxis { cycleAxis(rows) }
        .frame(height: 130)
    }

    @ChartContentBuilder
    private func utilizationMark(_ row: IntelligenceLogic.HistoryRow) -> some ChartContent {
        let value: Double = row.maximumPercent ?? 0
        if row.status == .complete || row.status == .current {
            PointMark(x: .value("Cycle", row.id), y: .value("Utilization", value))
                .symbol(.circle).symbolSize(110).foregroundStyle(Palette.series[1])
        } else {
            PointMark(x: .value("Cycle", row.id), y: .value("Utilization", value))
                .symbol(.circle.strokeBorder(lineWidth: 2)).symbolSize(110).foregroundStyle(Palette.series[1])
        }
    }

    private var historyLegend: some View {
        HStack(spacing: 14) {
            LegendDot(color: Palette.series[0], label: String(localized: "Observed cycle"))
            LegendDot(color: Palette.series[0].opacity(0.45), label: String(localized: "Partly observed"))
            LegendDot(color: Palette.other.opacity(0.5), label: String(localized: "Calculated boundaries, no readings"))
            LegendDot(color: Palette.other.opacity(0.3), label: String(localized: "Tokens not tied to this account (stacked)"))
            Label("Hollow marker: at least this value", systemImage: "circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func color(for status: IntelligenceLogic.CycleStatus) -> Color {
        switch status {
        case .complete, .current: Palette.series[0]
        case .partial, .insufficient: Palette.series[0].opacity(0.45)
        case .unobserved, .projected: Palette.other.opacity(0.5)
        }
    }

    private func historyTable(_ cycles: [SubscriptionCycleReport]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Cycle").gridColumnAlignment(.leading)
                Text("Processed"); Text("Fresh"); Text("Cache reads"); Text("Highest reported"); Text("Observed rise")
                Text("Status").gridColumnAlignment(.leading)
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider()
            ForEach(cycles.reversed()) { cycle in
                let status = IntelligenceLogic.status(cycle)
                GridRow {
                    Button {
                        selectedCycleID = cycle.id
                    } label: {
                        Text(IntelligenceLogic.shortDate(cycle.span.start, zone: zone) + " → " + IntelligenceLogic.shortDate(cycle.span.end, zone: zone))
                            .fontWeight(cycle.id == selectedCycleID ? .semibold : .regular)
                    }
                    .buttonStyle(.link).gridColumnAlignment(.leading)
                    Text(Fmt.tokens(cycle.local.tokens.totalProcessed)).monospacedDigit()
                    Text(Fmt.tokens(cycle.local.tokens.freshTokens)).monospacedDigit()
                    Text(Fmt.ratio(cycle.local.tokens.cacheHitRatio)).monospacedDigit()
                    Text(cycle.quota.map { (cycle.quota?.completeness == .complete ? "" : "≥ ") + Fmt.percent($0.maximumPercent) } ?? "—").monospacedDigit()
                    Text(cycle.quota?.observedRisePoints.map { "+\(Int($0.rounded())) pts" } ?? "—").monospacedDigit()
                    Text(IntelligenceLogic.statusLabel(status)).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        .help(IntelligenceLogic.statusHelp(status))
                }
                .font(.callout)
                .background(cycle.id == selectedCycleID ? Color.accentColor.opacity(0.08) : .clear)
            }
        }
    }

    // MARK: Detail

    private func detailCard(_ cycle: SubscriptionCycleReport, bundle b: IntelligenceBundle) -> some View {
        let status = IntelligenceLogic.status(cycle)
        return Card(String(localized: "Cycle detail"), subtitle: IntelligenceLogic.range(cycle.span, zone: zone)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    badge(IntelligenceLogic.statusLabel(status), help: IntelligenceLogic.statusHelp(status))
                    if cycle.span.endedEarly { badge(String(localized: "Ended early (exceptional reset)"), help: String(localized: "The provider replaced this window before the reset time it had announced. This is not counted as negative consumption.")) }
                    if cycle.span.startedAfterIdleGap { badge(String(localized: "Began after an idle gap"), help: String(localized: "Windows that start with a request begin when the previous one is over and you start working again.")) }
                    if let plan = cycle.plan?.name { badge(plan, help: String(localized: "The plan recorded for this account.")) }
                    Spacer()
                }
                Text("Starts \(IntelligenceLogic.dateTime(cycle.span.start, zone: zone)) (\(IntelligenceLogic.utc(cycle.span.start))) · ends \(IntelligenceLogic.dateTime(cycle.span.end, zone: zone)) (\(IntelligenceLogic.utc(cycle.span.end)))")
                    .font(.caption).foregroundStyle(.secondary)
                if let reported = cycle.span.reportedReset, cycle.span.endedEarly {
                    Text("The provider had announced a reset at \(IntelligenceLogic.dateTime(reported, zone: zone)).").font(.caption).foregroundStyle(.secondary)
                }
                if let expected = cycle.expectedReset, abs(expected.timeIntervalSince(cycle.span.end)) > 120 {
                    Text("The previous cycle implied a reset at \(IntelligenceLogic.dateTime(expected, zone: zone)); the provider reported \(IntelligenceLogic.dateTime(cycle.span.end, zone: zone)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let text = IntelligenceLogic.attributionText(cycle.attribution, identified: b.report.subject.accountIsIdentified, share: cycle.attributedShare) {
                    Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if cycle.unattributed.requests > 0 {
                    Text("Not tied to this account and not counted below: \(Fmt.tokens(cycle.unattributed.processedTokens)) processed tokens in \(Fmt.grouped(Int64(cycle.unattributed.requests))) requests.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                localUsage(cycle)
                Divider()
                quotaObservations(cycle)
                Divider()
                efficiency(cycle)
            }
        }
    }

    private func badge(_ text: String, help: String) -> some View {
        Text(text).font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Palette.inset))
            .help(help)
    }

    private func localUsage(_ cycle: SubscriptionCycleReport) -> some View {
        let local = cycle.local
        return VStack(alignment: .leading, spacing: 8) {
            Text("Local usage").font(.subheadline.weight(.semibold))
            if local.isEmpty {
                Text("No local requests were recorded in this cycle.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    stat(String(localized: "Processed"), Fmt.tokens(local.tokens.totalProcessed))
                    stat(String(localized: "Fresh"), Fmt.tokens(local.tokens.freshTokens))
                    stat(String(localized: "Requests"), Fmt.grouped(Int64(local.requests)))
                    stat(String(localized: "Sessions"), "\(local.sessions)" + (local.subagentSessions > 0 ? " + \(local.subagentSessions) sub-agent" : ""))
                    stat(String(localized: "API-equivalent cost"), Fmt.cost(local.cost))
                    stat(String(localized: "Active time"), Fmt.duration(local.activeDuration))
                }
                let parts = IntelligenceLogic.tokenParts(local.tokens)
                Chart(parts) { part in
                    BarMark(x: .value("Tokens", part.tokens), y: .value("Cycle", ""))
                        .foregroundStyle(by: .value("Category", part.label))
                }
                .chartForegroundStyleScale(domain: parts.map(\.label), range: parts.indices.map { Palette.series[$0 % Palette.series.count] })
                .chartXAxis { AxisMarks { v in AxisValueLabel { if let d = v.as(Int64.self) { Text(Fmt.tokens(d)) } } } }
                .chartYAxis(.hidden)
                .frame(height: 56)
                HStack(alignment: .top, spacing: 24) {
                    shareList(String(localized: "By model"), local.models.map { ($0.displayName, $0.share, $0.tokens.totalProcessed) })
                    shareList(String(localized: "By project"), local.projects.map { ($0.name.isEmpty ? String(localized: "No project") : $0.name, $0.share, $0.tokens.totalProcessed) })
                }
                if local.coverage.partialRequests > 0 || !local.coverage.isComplete {
                    Text("Some requests did not report every token category; those categories count as zero.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }

    private func shareList(_ title: String, _ rows: [(String, Double, Int64)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(rows.prefix(5).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.0).lineLimit(1).frame(width: 150, alignment: .leading)
                    ProgressView(value: min(max(row.1, 0), 1)).frame(width: 90)
                    Text(Fmt.ratio(row.1)).monospacedDigit().foregroundStyle(.secondary)
                    Text(Fmt.tokens(row.2)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaObservations(_ cycle: SubscriptionCycleReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reported quota").font(.subheadline.weight(.semibold))
            if let quota = cycle.quota {
                HStack(alignment: .top, spacing: 24) {
                    stat(String(localized: "First reading"), Fmt.percent(quota.firstPercent))
                    stat(String(localized: "Last reading"), Fmt.percent(quota.lastPercent))
                    stat(String(localized: "Highest"), (quota.endObserved ? "" : "≥ ") + Fmt.percent(quota.maximumPercent))
                    stat(String(localized: "Rise between readings"), quota.observedRisePoints.map { "+\(Int($0.rounded())) pts" } ?? "—")
                    stat(String(localized: "Distinct readings"), "\(quota.readingCount)")
                    stat(String(localized: "Supported"), Fmt.ratio(quota.coverage.supportedFraction))
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(IntelligenceLogic.coverageLines(quota.coverage), id: \.self) { line in
                        Label(line, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }
                    Label(quota.coverage.hasReliableFullCycleResult
                          ? String(localized: "Start and end were observed and no rise could have gone unseen for long, so the whole-cycle utilization is a result.")
                          : (quota.endObserved ? String(localized: "The end of the cycle was observed, but the whole-cycle utilization is still a lower bound because the start or a middle stretch was not.")
                                               : String(localized: "The end of the cycle was not observed, so the final utilization is unknown. The highest reading is a lower bound.")),
                          systemImage: quota.coverage.hasReliableFullCycleResult ? "checkmark.circle" : "questionmark.circle")
                    if quota.reachedLimit { Label("The limit was reached in this cycle.", systemImage: "exclamationmark.triangle") }
                    if !quota.issues.isEmpty { Label("\(quota.issues.count) reading(s) that contradicted earlier ones were set aside.", systemImage: "exclamationmark.circle") }
                    Text("Determined \(Fmt.ratio(quota.coverage.determinedFraction)) and supported \(Fmt.ratio(quota.coverage.supportedFraction)) of the elapsed cycle. Determined means the same value was seen at both ends of a stretch. Supported means observations are also known to lie close together there.")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(cycle.span.origin == .projected ? IntelligenceLogic.statusHelp(.projected) : IntelligenceLogic.statusHelp(.unobserved))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func efficiency(_ cycle: SubscriptionCycleReport) -> some View {
        let e = cycle.efficiency
        return VStack(alignment: .leading, spacing: 6) {
            Text("Observed association").font(.subheadline.weight(.semibold))
            if let ratio = e.processedTokensPerPoint, let quality = e.quality {
                let value = Fmt.tokens(Int64(ratio.value)), low = Fmt.tokens(Int64(ratio.low)), high = Fmt.tokens(Int64(ratio.high))
                Text("Between two exact readings the utilization rose \(Int(e.risePoints.rounded())) points while this Mac processed \(Fmt.tokens(e.processedTokens)) tokens: about \(value) processed tokens per point (\(low)–\(high) allowing for rounding).")
                    .font(.callout)
                HStack(alignment: .top, spacing: 24) {
                    if let fresh = e.freshTokensPerPoint { stat(String(localized: "Fresh tokens per point"), Fmt.tokens(Int64(fresh.value))) }
                    if let cost = e.costUSDPerPoint { stat(String(localized: "API-equivalent cost per point"), String(format: "$%.3f", cost.value)) }
                    if let cache = e.cacheReadTokensPerPoint { stat(String(localized: "Cache-read tokens per point"), Fmt.tokens(Int64(cache.value))) }
                    if let p = e.pointsPerMillionProcessed { stat(String(localized: "Points per million processed"), String(format: "%.2f", p.value)) }
                    stat(String(localized: "Quality"), quality == .reliable ? String(localized: "Reliable") : String(localized: "Indicative"))
                }
                if let share = e.cacheReadShare {
                    let mix = e.modelShares.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(Int(($0.value * 100).rounded()))%" }.joined(separator: ", ")
                    Text("The measured work was \(Int((share * 100).rounded()))% cache reads, and by model: \(mix).").font(.caption).foregroundStyle(.secondary)
                }
                Text("This is an association measured in this cycle, not the provider's formula. It can change with the model mix, caching, the kind of work and use on other surfaces.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(e.caveats, id: \.self) { caveat in
                    Label(IntelligenceLogic.efficiencyCaveat(caveat), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No ratio is shown for this cycle.").font(.callout).foregroundStyle(.secondary)
                ForEach(e.unavailable, id: \.self) { reason in
                    Label(IntelligenceLogic.efficiencyUnavailable(reason), systemImage: "minus.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Cumulative chart

    private func cumulativeCard(_ cycle: SubscriptionCycleReport, bundle b: IntelligenceBundle) -> some View {
        let overlay = overlayComparable ? IntelligenceLogic.comparableCycles(to: cycle, in: b.report) : (shown: [], hidden: 0)
        let length = cycle.span.length / 3600
        return Card(String(localized: "Utilization through the cycle"),
                    subtitle: String(localized: "Solid lines are observed values. A dashed line joins two observed values when the moment of the rise was not seen. The dotted vertical line is now.")) {
            let own = IntelligenceLogic.segments(for: cycle)
            if own.isEmpty {
                Text(cycle.span.origin == .projected ? IntelligenceLogic.statusHelp(.projected) : IntelligenceLogic.statusHelp(.unobserved))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    RuleMark(y: .value("Limit", 100)).foregroundStyle(Palette.critical.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    ForEach(overlay.shown) { other in
                        ForEach(IntelligenceLogic.segments(for: other)) { segment in
                            lineMarks(segment, color: Color.secondary.opacity(0.35), width: 1.2)
                        }
                    }
                    ForEach(own) { segment in lineMarks(segment, color: Palette.series[0], width: 2.4) }
                    if cycle.timing == .current {
                        RuleMark(x: .value("Now", b.now.timeIntervalSince(cycle.span.start) / 3600))
                            .foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                }
                .chartXScale(domain: 0...length)
                .chartYScale(domain: 0...105)
                .chartYAxis { AxisMarks(position: .leading, values: percentTicks) { v in
                    AxisGridLine().foregroundStyle(Palette.gridLine)
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } }
                } }
                .chartXAxis { AxisMarks(values: .stride(by: 24)) { v in
                    AxisGridLine().foregroundStyle(Palette.gridLine)
                    AxisValueLabel { if let h = v.as(Double.self) { Text("day \(Int(h / 24) + 1)") } }
                } }
                .frame(height: 220)
                HStack {
                    Toggle("Show earlier cycles that can be compared", isOn: $overlayComparable).toggleStyle(.switch).controlSize(.small)
                    Spacer()
                    if overlayComparable {
                        Text(overlay.shown.isEmpty ? String(localized: "No earlier cycle is directly comparable.")
                                                   : String(localized: "\(overlay.shown.count) comparable cycle(s) in grey; \(overlay.hidden) hidden because they differ in plan, model mix, cache behaviour or observation."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ChartContentBuilder
    private func lineMarks(_ segment: IntelligenceLogic.CurveSegment, color: Color, width: Double) -> some ChartContent {
        LineMark(x: .value("Hour", segment.fromHour), y: .value("Utilization", segment.fromPercent), series: .value("Segment", segment.id))
            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: width, dash: segment.kind == .bracketed ? [4, 3] : []))
        LineMark(x: .value("Hour", segment.toHour), y: .value("Utilization", segment.toPercent), series: .value("Segment", segment.id))
            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: width, dash: segment.kind == .bracketed ? [4, 3] : []))
    }

    // MARK: Daily

    private func dailyCard(_ cycle: SubscriptionCycleReport) -> some View {
        Card(calendarDays ? String(localized: "Calendar days") : String(localized: "Subscription days"),
             subtitle: String(localized: "A day is a slice of the longer allowance, not a limit of its own. A day's quota change is shown only where readings bound it.")) {
            Chart(cycle.days) { day in
                BarMark(x: .value("Day", day.start, unit: .day), y: .value("Tokens", day.local.tokens.totalProcessed), width: .ratio(0.7))
                    .foregroundStyle(Palette.series[0])
            }
            .chartYAxis { AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Palette.gridLine)
                AxisValueLabel { if let d = v.as(Int64.self) { Text(Fmt.tokens(d)) } }
            } }
            .chartXAxis { AxisMarks(values: cycle.days.map(\.start)) { v in
                AxisValueLabel { if let d = v.as(Date.self) { Text(IntelligenceLogic.format(d, zone: zone, "EEE")) } }
            } }
            .frame(height: 150)
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Day").gridColumnAlignment(.leading)
                    Text("Processed"); Text("Share of cycle"); Text("Requests"); Text("Sessions")
                    Text("Top model").gridColumnAlignment(.leading)
                    Text("Top project").gridColumnAlignment(.leading)
                    Text("Reported change").gridColumnAlignment(.leading)
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(cycle.days) { day in
                    GridRow {
                        Text(IntelligenceLogic.format(day.start, zone: zone, "EEE d MMM")).gridColumnAlignment(.leading)
                        Text(Fmt.tokens(day.local.tokens.totalProcessed)).monospacedDigit()
                        Text(Fmt.ratio(day.shareOfCycleProcessed)).monospacedDigit()
                        Text(Fmt.grouped(Int64(day.local.requests))).monospacedDigit()
                        Text("\(day.local.sessions)").monospacedDigit()
                        Text(day.local.models.first?.displayName ?? "—").lineLimit(1).gridColumnAlignment(.leading)
                        Text(day.local.projects.first?.name ?? "—").lineLimit(1).gridColumnAlignment(.leading)
                        Text(IntelligenceLogic.quotaChangeText(day.quotaChange)).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                    }.font(.callout)
                }
            }
        }
    }

    // MARK: States and notes

    private var emptyState: some View {
        Card {
            EmptyState(symbol: "chart.xyaxis.line", title: String(localized: "No quota history yet"),
                       message: String(localized: "Usage intelligence needs readings that your provider reports about its limits. They are collected while the app runs and a supported tool is in use. History starts when the first reading arrives; nothing before that can be reconstructed."))
        }
    }

    private var methodology: some View {
        DisclosureGroup("How to read this page") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Utilization percentages are the provider's own readings for the whole account. Tokens are what this Mac recorded, so chat, other devices and other tools can move the percentage without appearing in the tokens.")
                Text("A cycle is the period between two resets. Its boundaries come from reset times the provider reported. When reset times repeat at exactly the window length, the schedule is established, and cycles for periods without readings are calculated from it; those are labelled and never carry a percentage.")
                Text("An exceptional reset, where the provider replaced a window early, is shown as such and is never counted as negative consumption.")
                Text("Ratios compare the local tokens with the rise between two exactly observed values. They are observed associations, shown with the range that rounding of the provider's whole percentages allows.")
                Text("A forecast uses only the reported utilization of earlier cycles. It is shown only when the method has been checked against earlier forecasts made with the information available at the time, and its range comes from the errors it actually made.")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
        .font(.callout)
    }

    // MARK: Loading and export

    private func load(settle: Duration) async {
        try? await Task.sleep(for: settle)
        guard !Task.isCancelled else { return }
        generation &+= 1
        let mine = generation
        loading = true
        let db = model.db
        let grouping: DayGrouping = calendarDays ? .calendarDay(zone) : .subscriptionDay
        let preferred = storedSubject
        do {
            let result: (subjects: [IntelligenceSubject], bundle: IntelligenceBundle?, associations: [AccountAssociation]) = try await Task.detached(priority: .userInitiated) {
                let all = try SubscriptionUsageAnalyticsEngine.subjects(db)
                let chosen = all.first { $0.id == preferred } ?? IntelligenceLogic.defaultSubject(all)
                guard let chosen else { return (all, nil, []) }
                var options = AnalysisOptions()
                options.maxCycles = 14
                options.dayGrouping = grouping
                let now = Date()
                let report = try SubscriptionUsageAnalyticsEngine.analyze(db, subject: chosen, now: now, options: options)
                let forecast = UsageForecastEngine.forecast(for: report, now: now)
                let insights = UsageInsightsEngine.insights(report: report, forecast: forecast, now: now)
                let saved = chosen.accountIsIdentified ? try AccountAssociationStore.all(db, provider: chosen.provider) : []
                return (all, IntelligenceBundle(report: report, forecast: forecast, insights: insights, now: now), saved)
            }.value
            guard mine == generation else { return }
            subjects = result.subjects
            bundle = result.bundle
            associations = result.associations
            hasLoaded = true
            error = nil
            if let report = result.bundle?.report, !report.cycles.contains(where: { $0.id == selectedCycleID }) {
                selectedCycleID = (report.currentCycle ?? report.cycles.last(where: { $0.timing == .past }))?.id
            }
            loading = false
        } catch {
            guard mine == generation else { return }
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "usage-intelligence.\(format.rawValue)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let db = model.db
        let calendar = { () -> Calendar in var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }()
        exportStatus = String(localized: "Exporting…")
        Task.detached {
            let message: String
            do {
                let result = try ExportService(db: db).export(kind: .usageIntelligence, format: format, to: url, calendar: calendar)
                message = String(localized: "Exported \(Fmt.grouped(Int64(result.rows))) rows.")
            } catch {
                let reason = String(describing: error)
                message = String(localized: "Export failed: \(reason)")
            }
            await MainActor.run { exportStatus = message }
        }
    }
}


/// Every time zone the system knows, in a lazily built list with a filter.
private struct ZonePickerSheet: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var identifiers: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.sorted()
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return term.isEmpty ? all : all.filter { $0.lowercased().contains(term) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Time zone").font(.headline)
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
            List(identifiers, id: \.self) { identifier in
                Button {
                    selection = identifier
                    dismiss()
                } label: {
                    HStack {
                        Text(identifier)
                        Spacer()
                        if identifier == selection { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
