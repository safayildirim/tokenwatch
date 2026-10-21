import SwiftUI
import UsageCore

/// This view draws a single horizontal bar split into the four token categories.
struct TokenCompositionBar: View {
    var tokens: TokenCounts
    var includeCacheReads: Bool

    private var parts: [(String, Int64, Color)] {
        var p: [(String, Int64, Color)] = [("Uncached input", tokens.uncachedInput, Palette.uncachedInput),
                                           ("Output", tokens.output, Palette.output)]
        if includeCacheReads { p.append(("Cache read", tokens.cacheRead, Palette.cacheRead)) }
        p.append(("Cache write", tokens.cacheCreation, Palette.cacheWrite))
        return p
    }

    var body: some View {
        let total = max(1, parts.reduce(Int64(0)) { $0 + $1.1 })
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        if part.1 > 0 {
                            Rectangle().fill(part.2)
                                .frame(width: max(2, geo.size.width * CGFloat(part.1) / CGFloat(total) - 2))
                                .help("\(part.0): \(Fmt.grouped(part.1)) (\(Fmt.ratio(Double(part.1) / Double(total))))")
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.2).frame(width: 8, height: 8)
                        Text("\(part.0) \(Fmt.tokens(part.1)) · \(Fmt.ratio(Double(part.1) / Double(total)))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map { "\($0.0) \(Fmt.tokens($0.1))" }.joined(separator: ", "))
    }
}

/// Everything the overview shows for one period, loaded in one pass.
struct OverviewData: Sendable {
    var period: OverviewPeriod = .today
    var current = UsageTotals()
    var previous = UsageTotals()
    var providers: [ProviderUsageRow] = []
    var products: [ProviderUsageRow] = []
    var buckets: [OverviewBucket] = []
    var models: [ModelUsageRow] = []
    var projects: [ProjectUsageRow] = []
    /// The providers whose sessions worked in each project during the period.
    var projectProviders: [Int64: [ProviderID]] = [:]
}

/// The first page of the dashboard: the limits as they stand, the chosen period at a glance, when the work happened,
/// what kind of tokens it took and what used the most.
struct OverviewPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("overview.period") private var period: OverviewPeriod = .today
    @State private var data = OverviewData()
    @State private var loadError: String?
    @State private var sawImport = false
    @State private var importHidden = false
    @State private var iconCheck = IconCheck.idle

    private enum IconCheck { case idle, checking, back }

    var body: some View {
        let o = model.scopedOverview
        let isEmpty = model.hasLoaded && o.allTime.requests == 0 && !isImporting
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let warning = limitWarning { warningBanner(warning, proxy: proxy) }
                    importCard
                    menuBarNotice
                    if isEmpty {
                        if model.scope.isActive { noMatchNotice } else { noUsageNotice }
                    } else {
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            OverviewLimits(pools: visiblePools, now: ctx.date)
                        }
                        .id("limits")
                        OverviewGlance(period: period, data: data, activeNow: o.activeSessions,
                                       showCost: model.settings.showEstimatedCost)
                        OverviewActivity(period: period, data: data, showCost: model.settings.showEstimatedCost)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                OverviewTokenMix(period: period, tokens: data.current.tokens).frame(minWidth: 440)
                                OverviewRanking(period: period, data: data, showCost: model.settings.showEstimatedCost).frame(minWidth: 440)
                            }
                            // Both cards take the height of the taller one.
                            .fixedSize(horizontal: false, vertical: true)
                            VStack(spacing: 12) {
                                OverviewTokenMix(period: period, tokens: data.current.tokens)
                                OverviewRanking(period: period, data: data, showCost: model.settings.showEstimatedCost)
                            }
                        }
                        Text("Counts come from the local files that \(toolList(conjunction: .and)) write on this Mac. Chat apps and other devices leave no record here, so these totals can be lower than what your accounts really used. Limits are the exception: they come from the providers and include everything.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 820, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let loadError {
                            Text("Some figures could not be loaded: \(loadError)").font(.caption).foregroundStyle(Palette.warning)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 40)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !(isEmpty && !model.scope.isActive) {
                VStack(spacing: 0) { OverviewScopeBar(period: $period); Divider() }.background(.bar)
            }
        }
        .onChange(of: isImporting, initial: true) { _, importing in if importing { sawImport = true } }
        .task(id: "\(model.dataVersion)|\(model.scopeVersion)|\(period.rawValue)") { await load() }
    }

    // MARK: Loading

    private func load() async {
        let period = self.period
        let now = Date()
        let calendar = Calendar.current
        let current = model.scoped(period.current(now: now, calendar: calendar))
        let previous = model.scoped(period.previous(now: now, calendar: calendar))
        do {
            data = try await model.query { engine in
                var d = OverviewData(period: period)
                d.current = try engine.totals(current)
                d.previous = try engine.totals(previous)
                d.providers = try engine.providers(current)
                d.products = try engine.providers(current, byProduct: true)
                let points = try engine.series(current, granularity: period.granularity, dimension: .provider, calendar: calendar)
                let sessions = try engine.sessionsOverTime(current, granularity: period.granularity, calendar: calendar)
                d.buckets = OverviewLogic.buckets(period: period, now: now, calendar: calendar, points: points, sessions: sessions)
                d.models = try engine.models(current)
                d.projects = try engine.projects(current)
                for row in d.providers {
                    var f = current
                    f.providers = [row.provider]
                    for p in try engine.projects(f) { d.projectProviders[p.id, default: []].append(row.provider) }
                }
                return d
            }
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: Limits

    /// Pools with a figure, plus the pools of providers that are installed but have not reported yet.
    private var visiblePools: [QuotaPoolState] {
        model.scopedPools.filter { pool in
            pool.windows.contains { $0.reading != nil } || model.collectionState(of: pool.pool.key.provider).map { $0 != .notFound } ?? false
        }
    }

    private struct LimitWarning {
        var key: String
        var title: String
        var detail: String
    }

    /// The first window that will run out before it resets at the pace of its cycle so far.
    private var limitWarning: LimitWarning? {
        let now = Date()
        let calendar = Calendar.current
        for pool in visiblePools {
            for w in pool.windows where w.isAlertEligible {
                guard let used = w.utilizationPercent, let reset = w.resetsAt else { continue }
                let outlook = WindowOutlook.evaluate(used: used, resetsAt: reset, length: w.length, now: now)
                guard let out = outlook.runsOutAt else { continue }
                let key = w.id + "|\(reset.timeIntervalSince1970)"
                guard model.dismissedLimitWarning != key else { continue }
                let window = WindowNaming.displayName(minutes: w.windowMinutes, fallbackKey: w.windowKey).lowercased()
                let name = pool.pool.name
                let account = pool.pool.accountLabel
                let outAt = OverviewLogic.clock(out, now: now, calendar: calendar)
                let resetAt = OverviewLogic.clock(reset, now: now, calendar: calendar)
                let pct = Int(used.rounded())
                return LimitWarning(
                    key: key,
                    title: account == "Unassigned" ? String(localized: "\(name) will reach its \(window) limit \(outAt)")
                        : String(localized: "\(name) (\(account)) will reach its \(window) limit \(outAt)"),
                    detail: String(localized: "\(pct)% of the \(window) allowance is used, and it resets \(resetAt). Moving to a lighter model or to another tool for a while keeps you working."))
            }
        }
        return nil
    }

    private func warningBanner(_ warning: LimitWarning, proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.palette).foregroundStyle(.white, Palette.critical)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title).fontWeight(.semibold)
                Text(warning.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Dismiss") { model.dismissedLimitWarning = warning.key }
                Button("Show Limits") { withAnimation { proxy.scrollTo("limits", anchor: .top) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.critical.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.critical.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }

    // MARK: Import

    private var isImporting: Bool {
        let snap = model.collectorSnapshot
        return snap.isSyncing && snap.isInitialImport && snap.progress != nil
    }

    @ViewBuilder private var importCard: some View {
        let snap = model.collectorSnapshot
        if isImporting, let p = snap.progress {
            let pct = Int(p * 100)
            let done = bytes(snap.bytesDone)
            let total = bytes(snap.bytesTotal)
            importPanel(title: String(localized: "Importing your history"), progress: p,
                        text: String(localized: "\(pct)% done. \(done) of \(total) read. The numbers below are partial until this finishes."),
                        done: false)
        } else if sawImport && !importHidden {
            importPanel(title: String(localized: "History import finished"), progress: 1,
                        text: String(localized: "Every number on this page is now complete."), done: true)
        }
    }

    private func importPanel(title: String, progress: Double, text: String, done: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                if done { Button("Hide") { importHidden = true } }
            }
            .frame(minHeight: 28)
            ProgressBar(fraction: progress, height: 6, fill: Color.accentColor)
                .accessibilityLabel("Import progress")
                .accessibilityValue("\(Int(progress * 100)) percent")
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .overviewCard()
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    // MARK: Menu bar icon

    @ViewBuilder private var menuBarNotice: some View {
        if iconCheck == .back {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette).foregroundStyle(.white, Palette.good).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text("The menu bar icon is back").fontWeight(.semibold)
                    Text("You can open Tokenwatch from the menu bar again.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Done") { iconCheck = .idle }
            }
            .padding(.horizontal, 2)
            .overviewCard()
        } else if model.menuBarIconHidden && !model.menuBarNoticeDismissed {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 16)).foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The menu bar icon is hidden").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                        Text("Your menu bar is full, so macOS placed the icon behind the camera notch. Until there is room, open Tokenwatch from the Dock.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        step(1, Text("Quit or hide a few menu bar apps that you rarely use."))
                        step(2, Text("Or hold ") + Text("⌘").fontWeight(.medium) + Text(" and drag menu bar icons to move this one out from behind the notch."))
                    }
                    HStack(spacing: 12) {
                        Button(iconCheck == .checking ? String(localized: "Checking…") : String(localized: "Check Again")) { checkIcon() }
                            .buttonStyle(.borderedProminent)
                            .disabled(iconCheck == .checking)
                        Button("Hide Notice") { model.menuBarNoticeDismissed = true }
                        Text("This notice also goes away by itself once the icon has room.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                NotchFigure().accessibilityHidden(true)
            }
            .padding(.horizontal, 2)
            .overviewCard()
        }
    }

    private func step(_ n: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            text.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkIcon() {
        iconCheck = .checking
        Task {
            // A short pause, so that a click right after moving icons sees where macOS put them.
            try? await Task.sleep(for: .seconds(1))
            iconCheck = model.recheckMenuBarIcon() ? .back : .idle
        }
    }

    // MARK: Empty states

    private var noUsageNotice: some View {
        let tools = toolList(conjunction: .or)
        return emptyPanel(symbol: "tray", title: String(localized: "No usage yet"),
                          message: String(localized: "Usage appears here as soon as \(tools) writes a session on this Mac. There is nothing to set up.")) {
            Button("Check Again") { model.refreshNow() }.disabled(model.isCheckingNow)
        }
    }

    private var noMatchNotice: some View {
        let summary = model.scope.summary(registry: model.db.registry, options: model.filterOptions)
        return emptyPanel(symbol: "line.3.horizontal.decrease.circle", title: String(localized: "Nothing matches these filters"),
                          message: String(localized: "There is no usage for \(summary). Pick another combination or clear the filters.")) {
            Button("Clear Filters") { model.scope = DashboardScope() }
        }
    }

    private func emptyPanel<B: View>(symbol: String, title: String, message: String, @ViewBuilder button: () -> B) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            button().padding(.top, 8)
        }
        .padding(.vertical, 56).padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    private enum Conjunction { case and, or }

    /// The tools that write the session files this app reads, such as "Claude Code and Codex".
    private func toolList(conjunction: Conjunction) -> String {
        let registry = model.db.registry
        var names: [String] = []
        for source in registry.sources where source.kind == .sessionLogs {
            for product in source.products where !names.contains(model.productName(product)) { names.append(model.productName(product)) }
        }
        guard let last = names.popLast() else { return String(localized: "your coding tools") }
        if names.isEmpty { return last }
        let head = names.joined(separator: ", ")
        switch conjunction {
        case .and: return String(localized: "\(head) and \(last)")
        case .or: return String(localized: "\(head) or \(last)")
        }
    }
}

// MARK: - Filters

/// The overview's bar: the period, then the provider, account and surface filters that every page shares.
struct OverviewScopeBar: View {
    @Environment(AppModel.self) private var model
    @Binding var period: OverviewPeriod

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                periodControl
                providerControl
                menus
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) { periodControl; providerControl }
                menus
            }
            VStack(alignment: .leading, spacing: 10) {
                periodControl
                providerControl
                menus
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Overview filters")
    }

    private var periodControl: some View {
        HStack(spacing: 8) {
            Text("Period").font(.caption).foregroundStyle(.secondary)
            Segments(title: String(localized: "Period"), selection: $period, items: OverviewPeriod.allCases.map { ($0, $0.label) })
        }
    }

    private var providerControl: some View {
        let selection = Binding<String>(
            get: {
                let p = model.scope.providers
                return p.isEmpty ? "all" : (p.count == 1 ? p.first!.rawValue : "several")
            },
            set: { value in model.scope.providers = value == "all" ? [] : [ProviderID(rawValue: value)] })
        return HStack(spacing: 8) {
            Text("Provider").font(.caption).foregroundStyle(.secondary)
            Segments(title: String(localized: "Provider"), selection: selection,
                     items: [("all", String(localized: "All"))] + model.filterOptions.providers.map { ($0.rawValue, model.toolName($0)) })
        }
    }

    private var menus: some View {
        @Bindable var model = model
        let options = model.filterOptions
        let providers = model.scope.providers
        return HStack(spacing: 8) {
            FilterMenu(title: String(localized: "Account"), selection: $model.scope.accounts,
                       items: options.accounts.filter { providers.isEmpty || providers.contains($0.provider) }
                           .map { ($0.id, "\(model.providerName($0.provider)) · \(DisplayText.localized($0.label))") })
            FilterMenu(title: String(localized: "Surface"), selection: $model.scope.surfaces,
                       items: options.surfaces.map { ($0, model.surfaceName($0)) })
            if model.scope.isActive {
                Button("Clear Filters") { model.scope = DashboardScope() }
                Text("Showing \(model.scope.summary(registry: model.db.registry, options: options))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Shared pieces

/// A segmented control whose segments are as wide as their labels. The system's segmented picker makes every
/// segment as wide as the longest one, which leaves a short label like "All" floating in a wide button.
struct Segments<T: Hashable>: View {
    var title: String
    @Binding var selection: T
    var items: [(T, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                let on = item.0 == selection
                Button { selection = item.0 } label: {
                    Text(item.1).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6).fill(Palette.segmentOn)
                                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// The card that every section of the overview sits on.
    func overviewCard(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    /// A panel inside a card.
    func overviewInset(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.inset))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}

/// A rounded bar that fills a part of its track.
struct ProgressBar: View {
    var fraction: Double
    var height: CGFloat
    var fill: Color
    var minimum: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(fill).frame(width: max(minimum, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: height)
    }
}

/// A small drawing of a menu bar whose icon sits behind the camera notch.
struct NotchFigure: View {
    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, _ in
                let dim = GraphicsContext.Shading.color(Color.secondary.opacity(0.55))
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 4, width: 220, height: 22), cornerRadius: 5), with: .color(Color.primary.opacity(0.06)))
                for (x, w) in [(10.0, 14.0), (30, 20), (56, 14)] {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: 12, width: w, height: 6), cornerRadius: 3), with: dim)
                }
                for x in stride(from: 152.0, through: 208, by: 14) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: 11, width: 8, height: 8)), with: dim)
                }
                var notch = Path()
                notch.move(to: CGPoint(x: 80, y: 4))
                notch.addLine(to: CGPoint(x: 140, y: 4))
                notch.addLine(to: CGPoint(x: 140, y: 20))
                notch.addQuadCurve(to: CGPoint(x: 134, y: 26), control: CGPoint(x: 140, y: 26))
                notch.addLine(to: CGPoint(x: 86, y: 26))
                notch.addQuadCurve(to: CGPoint(x: 80, y: 20), control: CGPoint(x: 80, y: 26))
                notch.closeSubpath()
                ctx.fill(notch, with: .color(.black))
                let accent = GraphicsContext.Shading.color(.accentColor)
                ctx.stroke(Path(ellipseIn: CGRect(x: 104, y: 8, width: 12, height: 12)), with: accent,
                           style: StrokeStyle(lineWidth: 1.6, dash: [2.5, 2]))
                var line = Path()
                line.move(to: CGPoint(x: 110, y: 22))
                line.addLine(to: CGPoint(x: 110, y: 34))
                ctx.stroke(line, with: accent, style: StrokeStyle(lineWidth: 1.4, dash: [2, 2]))
                ctx.fill(Path(ellipseIn: CGRect(x: 107.5, y: 35.5, width: 5, height: 5)), with: accent)
            }
            .frame(width: 220, height: 44)
            Text("The icon is behind the notch").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}
