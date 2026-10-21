import SwiftUI
import UsageCore

/// Everything the trends page shows for one period and one choice of measure and split.
struct TrendsData: Sendable {
    var period: OverviewPeriod = .today
    var measure: TrendMeasure = .fresh
    var split: TrendSplit = .total
    var current = UsageTotals()
    var previous = UsageTotals()
    var buckets: [TrendBucket] = []
    var series: [TrendSeries] = []
    var changes: [TrendChange] = []
    /// What the changes are grouped by.
    var changeSplit: TrendSplit = .project
}

/// How usage moves over the chosen period: the headline figures against the period before, the chosen measure over
/// time split by provider, model, project or token type, and what grew or shrank the most.
struct TrendsPage: View {
    @Environment(AppModel.self) private var model
    /// The period is shared with the overview, so that moving between the two pages keeps it.
    @AppStorage("overview.period") private var period: OverviewPeriod = .today
    @AppStorage("trends.measure") private var measure: TrendMeasure = .fresh
    @AppStorage("trends.split") private var split: TrendSplit = .total
    @State private var showTable = false
    @State private var picked: [OverviewPeriod: Int] = [:]
    @State private var data = TrendsData()
    @State private var loadError: String?

    private var showCost: Bool { model.settings.showEstimatedCost }

    /// The split in effect: a split that does not fit the measure falls back to the total.
    private var effectiveSplit: TrendSplit { TrendSplit.choices(for: measure).contains(split) ? split : .total }

    var body: some View {
        let isEmpty = model.hasLoaded && model.scopedOverview.allTime.requests == 0
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isEmpty {
                    UsageEmptyState()
                } else {
                    summary
                    overTime
                    changes
                    Text("Times are in your local time zone. Providers count tokens in their own ways, so their figures are shown side by side and never treated as equal work.")
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if !(isEmpty && !model.scope.isActive) {
                VStack(spacing: 0) { OverviewScopeBar(period: $period); Divider() }.background(.bar)
            }
        }
        .task(id: "\(model.dataVersion)|\(model.scopeVersion)|\(period.rawValue)|\(measure.rawValue)|\(effectiveSplit.rawValue)") { await load() }
    }

    // MARK: Summary

    private var summary: some View {
        let cur = data.current
        let prev = data.previous
        let p = data.period
        var tiles = [
            OverviewGlance.Tile(label: String(localized: "New tokens"), value: Fmt.tokens(cur.tokens.freshTokens),
                                sub: OverviewLogic.changeText(current: cur.tokens.freshTokens, previous: prev.tokens.freshTokens, period: p),
                                note: String(localized: "Uncached input, cache writes and output.")),
            OverviewGlance.Tile(label: String(localized: "Processed tokens"), value: Fmt.tokens(cur.tokens.totalProcessed),
                                sub: OverviewLogic.changeText(current: cur.tokens.totalProcessed, previous: prev.tokens.totalProcessed, period: p),
                                note: String(localized: "Everything the models read and wrote, cache reads included.")),
            OverviewGlance.Tile(label: String(localized: "Requests"), value: Fmt.grouped(Int64(cur.requests)),
                                sub: OverviewLogic.changeText(current: Int64(cur.requests), previous: Int64(prev.requests), period: p),
                                note: cur.sessions == 1 ? String(localized: "In 1 session.") : String(localized: "In \(cur.sessions) sessions.")),
        ]
        if showCost {
            tiles.append(OverviewGlance.Tile(label: String(localized: "API-equivalent cost"), value: Fmt.cost(cur.cost),
                                             sub: OverviewLogic.changeText(current: cur.cost.picoUSD, previous: prev.cost.picoUSD, period: p),
                                             note: String(localized: "This is not your subscription bill.")))
        }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: period.title, note: period.comparedLine)
            EqualGrid(minimumWidth: 210, spacing: 12) {
                ForEach(tiles, id: \.label) { t in StatTile(tile: t) }
            }
        }
    }

    // MARK: Over time

    private var measures: [TrendMeasure] { TrendMeasure.allCases.filter { $0 != .cost || showCost } }

    private var overTime: some View {
        let ready = data.period == period && data.measure == measure && data.split == effectiveSplit
        let buckets = ready ? data.buckets : []
        let selected = buckets.isEmpty ? 0 : min(picked[period] ?? OverviewLogic.defaultSelection(buckets.map(\.overviewBucket)), buckets.count - 1)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                CardHeading(title: String(localized: "Over time"), subtitle: chartSubtitle)
                Spacer(minLength: 0)
                Segments(title: String(localized: "View"), selection: $showTable,
                         items: [(false, String(localized: "Chart")), (true, String(localized: "Table"))])
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { measureControl; splitControl; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 10) { measureControl; splitControl }
            }
            if ready && data.series.count > 1 {
                HStack(spacing: 14) {
                    ForEach(data.series) { s in LegendDot(color: color(s.color), label: name(s)) }
                }
            }
            if showTable {
                table(buckets)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    TrendChart(buckets: buckets, series: ready ? data.series : [], colors: colors, period: period,
                               measure: measure, selected: selected, label: { barLabel($0) }) { picked[period] = $0 }
                        .frame(minWidth: 400)
                    if buckets.indices.contains(selected) { detail(buckets[selected]) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .overviewCard()
    }

    private var chartSubtitle: String {
        switch period {
        case .today: String(localized: "\(measure.label) per hour, today.")
        case .week: String(localized: "\(measure.label) per day, last 7 days.")
        case .month: String(localized: "\(measure.label) per day, last 30 days.")
        }
    }

    private var measureControl: some View {
        HStack(spacing: 8) {
            Text("Show").font(.caption).foregroundStyle(.secondary)
            Segments(title: String(localized: "Show"), selection: $measure, items: measures.map { ($0, $0.label) })
        }
    }

    private var splitControl: some View {
        let choices = TrendSplit.choices(for: measure)
        let selection = Binding<TrendSplit>(get: { effectiveSplit }, set: { split = $0 })
        return HStack(spacing: 8) {
            Text("Split by").font(.caption).foregroundStyle(.secondary)
            Segments(title: String(localized: "Split by"), selection: selection, items: choices.map { ($0, $0.label) })
        }
        .opacity(choices.count > 1 ? 1 : 0.5)
        .disabled(choices.count == 1)
        .help(choices.count == 1 ? String(localized: "Sessions are counted per hour or day, so they cannot be split.") : "")
    }

    private func barLabel(_ b: TrendBucket) -> String {
        let title = OverviewLogic.title(of: b.overviewBucket, period: period)
        return b.isFuture ? String(localized: "\(title): not reached yet") : "\(title): \(measure.format(b.total))"
    }

    private func detail(_ b: TrendBucket) -> some View {
        let rows = data.series.filter { (b.values[$0.id] ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            (period == .today ? Text("Selected hour") : Text("Selected day")).font(.caption).foregroundStyle(.secondary)
            Text(OverviewLogic.title(of: b.overviewBucket, period: period)).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 0) {
                figure(measure.format(b.total), size: 26)
                Text(measure.label).font(.caption).foregroundStyle(.secondary)
            }
            if data.series.count > 1 {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { s in
                        HStack(spacing: 8) {
                            Circle().fill(color(s.color)).frame(width: 8, height: 8)
                            Text(name(s)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(measure.format(b.values[s.id] ?? 0)).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                        }
                    }
                    if rows.isEmpty { (b.isFuture ? Text("Not reached yet.") : Text("Nothing in this period.")).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(14)
        .frame(width: 250, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    /// The same figures as a table, for reading exact values and for VoiceOver.
    private func table(_ buckets: [TrendBucket]) -> some View {
        let shown = buckets.filter { !$0.isFuture }.reversed()
        let series = data.series
        return ScrollView(.vertical) {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    (period == .today ? Text("Hour") : Text("Day")).gridColumnAlignment(.leading)
                    if series.count > 1 { ForEach(series) { Text(name($0)).lineLimit(1) } }
                    Text(measure.label)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(Array(shown)) { b in
                    GridRow {
                        Text(OverviewLogic.title(of: b.overviewBucket, period: period)).gridColumnAlignment(.leading)
                        if series.count > 1 { ForEach(series) { s in Text(measure.format(b.values[s.id] ?? 0)) } }
                        Text(measure.format(b.total)).fontWeight(.medium)
                    }
                    .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overviewInset()
        }
        .frame(maxHeight: 420)
    }

    // MARK: Changes

    private var changes: some View {
        let ready = data.period == period && data.measure == measure
        let rows = ready ? data.changes : []
        let largest = rows.map { max($0.current, $0.previous) }.max() ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            CardHeading(title: changesTitle, subtitle: "\(measure.label) · \(period.comparedLine)")
            VStack(spacing: 4) {
                ForEach(rows) { c in ChangeRow(change: c, name: name(c), color: color(c.color), largest: largest, measure: measure) }
                if rows.isEmpty {
                    Text(period.unchangedLine).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .overviewCard()
    }

    private var changesTitle: String {
        switch data.changeSplit {
        case .provider: String(localized: "Biggest changes by provider")
        case .model: String(localized: "Biggest changes by model")
        default: String(localized: "Biggest changes by project")
        }
    }

    // MARK: Names and colors

    private var colors: [TrendColor: Color] {
        Dictionary(uniqueKeysWithValues: data.series.map { ($0.color, color($0.color)) })
    }

    private func color(_ c: TrendColor) -> Color {
        switch c {
        case .total: Palette.series[0]
        case .provider(let id): model.providerColor(id)
        case .model(let canonical): ChartColors.shared.color(for: canonical)
        case .project(let id): ChartColors.shared.color(for: "project:\(id)")
        case .category(let slot): Palette.series[slot]
        case .other: Palette.other
        }
    }

    private func name(_ s: TrendSeries) -> String {
        if case .provider(let id) = s.color { return model.toolName(id) }
        return s.name
    }

    private func name(_ c: TrendChange) -> String {
        if case .provider(let id) = c.color { return model.toolName(id) }
        return c.name
    }

    // MARK: Loading

    private func load() async {
        let period = self.period
        let measure = self.measure
        let split = effectiveSplit
        let now = Date()
        let calendar = Calendar.current
        let current = model.scoped(period.current(now: now, calendar: calendar))
        let previous = model.scoped(period.previous(now: now, calendar: calendar))
        // The comparison groups by the chart's split when it names entities, and by project otherwise. Models have no
        // session count, so sessions are compared by project.
        let changeSplit: TrendSplit = (split == .provider || split == .model) ? split : .project
        do {
            data = try await model.query { engine in
                var d = TrendsData(period: period, measure: measure, split: split, changeSplit: changeSplit)
                d.current = try engine.totals(current)
                d.previous = try engine.totals(previous)
                var points: [SeriesPoint] = []
                var sessions: [(start: Date, sessions: Int)] = []
                if measure == .sessions {
                    sessions = try engine.sessionsOverTime(current, granularity: period.granularity, calendar: calendar)
                } else {
                    points = try engine.series(current, granularity: period.granularity, dimension: split.dimension, calendar: calendar)
                }
                (d.buckets, d.series) = TrendsLogic.build(period: period, now: now, calendar: calendar, measure: measure, split: split,
                                                          points: points, sessions: sessions)
                func rows(_ filter: UsageFilter) throws -> [TrendRow] {
                    switch changeSplit {
                    case .provider:
                        return try engine.providers(filter).map { r in
                            TrendRow(id: r.provider.rawValue, name: "", color: .provider(r.provider),
                                     value: measure.value(tokens: r.tokens, requests: r.requests, cost: r.cost) ?? Double(r.sessions))
                        }
                    case .model:
                        return try engine.models(filter).map { r in
                            TrendRow(id: r.id, name: r.displayName, color: .model(r.canonical),
                                     value: measure.value(tokens: r.tokens, requests: r.requests, cost: r.cost) ?? 0)
                        }
                    default:
                        return try engine.projects(filter).map { r in
                            TrendRow(id: "\(r.id)", name: r.name, color: .project("\(r.id)"),
                                     value: measure.value(tokens: r.tokens, requests: r.requests, cost: r.cost) ?? Double(r.sessions))
                        }
                    }
                }
                d.changes = TrendsLogic.changes(current: try rows(current), previous: try rows(previous))
                return d
            }
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }
}

// MARK: - Chart

/// The trend chart: one clickable bar per hour or day, stacked by series, drawn like the overview's activity chart.
private struct TrendChart: View {
    var buckets: [TrendBucket]
    var series: [TrendSeries]
    var colors: [TrendColor: Color]
    var period: OverviewPeriod
    var measure: TrendMeasure
    var selected: Int
    var label: (TrendBucket) -> String
    var onSelect: (Int) -> Void

    private let plotHeight: CGFloat = 220

    private var gap: CGFloat {
        switch period {
        case .today: 4
        case .week: 16
        case .month: 3
        }
    }

    var body: some View {
        let top = TrendsLogic.niceCeiling(buckets.map(\.total).max() ?? 0)
        let calendar = Calendar.current
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                GeometryReader { g in
                    ForEach([1.0, 0.5, 0.0], id: \.self) { f in
                        Text(f == 0 ? "0" : measure.format(top * f))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(width: g.size.width, alignment: .trailing)
                            .position(x: g.size.width / 2, y: g.size.height * (1 - f))
                    }
                }
                .frame(width: 44, height: plotHeight)
                ZStack(alignment: .bottom) {
                    GeometryReader { g in
                        ForEach([1.0, 0.5, 0.0], id: \.self) { f in
                            Rectangle().fill(Palette.gridLine).frame(height: 1)
                                .position(x: g.size.width / 2, y: g.size.height * (1 - f))
                        }
                    }
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(buckets) { b in bar(b, top: top) }
                    }
                }
                .frame(height: plotHeight)
            }
            .padding(.top, 8)
            HStack(spacing: gap) {
                ForEach(buckets) { b in
                    let on = b.index == selected
                    Text(OverviewLogic.shortLabel(b.overviewBucket, period: period, count: buckets.count, selected: on, calendar: calendar))
                        .font(.system(size: 11, weight: on ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                        .lineLimit(1).fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, 52)
            .accessibilityHidden(true)
            Text("Click a bar to see what happened in it.").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    private func bar(_ b: TrendBucket, top: Double) -> some View {
        let on = b.index == selected
        // The first series sits at the bottom of the stack, so it lines up from bar to bar.
        let segments = series.reversed().compactMap { s -> (TrendSeries, Double)? in
            let v = b.values[s.id] ?? 0
            return v > 0 ? (s, v) : nil
        }
        let frame = UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5)
        return Button { onSelect(b.index) } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if segments.isEmpty {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.track).frame(height: 3)
                } else {
                    VStack(spacing: 0) {
                        ForEach(segments, id: \.0.id) { s in
                            Rectangle().fill(colors[s.0.color] ?? Palette.other)
                                .frame(height: max(1, plotHeight * CGFloat(s.1 / max(top, .leastNonzeroMagnitude))))
                        }
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(frame.fill(on ? Color.accentColor.opacity(0.12) : .clear))
            .overlay { if on { frame.stroke(Color.accentColor, lineWidth: 2).padding(-1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(b.isFuture)
        .accessibilityLabel(label(b))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Changes

/// One entity's figure now and in the previous period, with bars that compare the two.
private struct ChangeRow: View {
    var change: TrendChange
    var name: String
    var color: Color
    var largest: Double
    var measure: TrendMeasure

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(TrendsLogic.changeLabel(change))
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                VStack(alignment: .leading, spacing: 3) {
                    ProgressBar(fraction: largest > 0 ? change.current / largest : 0, height: 4, fill: color)
                    ProgressBar(fraction: largest > 0 ? change.previous / largest : 0, height: 4, fill: color.opacity(0.35))
                }
                .accessibilityHidden(true)
                Text("\(measure.format(change.current)) now · \(measure.format(change.previous)) before")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.inset))
        .accessibilityElement(children: .combine)
    }
}
