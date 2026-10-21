import SwiftUI
import Charts
import UsageCore

enum TrendMetric: String, CaseIterable, Identifiable {
    case total = "Total tokens"
    case inputOutput = "Input vs output"
    case cache = "Cache read vs creation"
    case categories = "All token categories"
    case sessions = "Sessions"
    case requests = "Requests"
    case byModel = "By model"
    case byProject = "By project"
    case cost = "API-equivalent cost"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .total: String(localized: "Total tokens")
        case .inputOutput: String(localized: "Input vs output")
        case .cache: String(localized: "Cache read vs creation")
        case .categories: String(localized: "All token categories")
        case .sessions: String(localized: "Sessions")
        case .requests: String(localized: "Requests")
        case .byModel: String(localized: "By model")
        case .byProject: String(localized: "By project")
        case .cost: String(localized: "API-equivalent cost")
        }
    }
}

enum TrendMeasure: String, CaseIterable, Identifiable {
    case processed = "Processed tokens", fresh = "New tokens", cost = "Estimated cost"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .processed: String(localized: "Processed tokens")
        case .fresh: String(localized: "New tokens")
        case .cost: String(localized: "Estimated cost")
        }
    }
}

private struct Datum: Identifiable {
    var id: String { "\(date.timeIntervalSince1970)|\(series)" }
    var date: Date
    var series: String
    var value: Double
}

private struct SeriesStyle {
    var names: [String]
    var colors: [Color]
}

struct TrendsPage: View {
    @Environment(AppModel.self) private var model
    @State private var range = RangeSelection(preset: .last30d)
    @State private var granularity: Granularity = .day
    @State private var metric: TrendMetric = .total
    @State private var measure: TrendMeasure = .processed
    @State private var showTable = false
    @State private var selected: Date?

    @State private var points: [SeriesPoint] = []
    @State private var modelPoints: [SeriesPoint] = []
    @State private var projectPoints: [SeriesPoint] = []
    @State private var sessionCounts: [(start: Date, sessions: Int)] = []
    @State private var totals = UsageTotals()
    @State private var loading = false

    /// Hourly buckets over a long period would be unreadable, so the resolution is coarsened.
    private var effectiveGranularity: Granularity {
        guard let from = range.interval().from else { return granularity == .hour ? .day : granularity }
        let days = (range.interval().to ?? Date()).timeIntervalSince(from) / 86_400
        if granularity == .hour && days > 14 { return .day }
        return granularity
    }

    private var reloadKey: String { "\(range.preset.rawValue)|\(range.customFrom)|\(range.customTo)|\(effectiveGranularity.rawValue)|\(model.dataVersion)|\(model.scopeVersion)" }

    var body: some View {
        PageScroll {
            controls
            summary
            Card(metric.label, subtitle: subtitle) {
                if loading && points.isEmpty { ProgressView().frame(maxWidth: .infinity, minHeight: 280) }
                else if points.allSatisfy({ $0.requests == 0 }) && model.hasLoaded { NoDataNotice() }
                else if showTable { table }
                else { chart }
            }
        }
        .task(id: reloadKey) { await load() }
        .onChange(of: effectiveGranularity) { _, _ in selected = nil }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            RangePicker(selection: $range)
            Picker("Resolution", selection: $granularity) {
                ForEach(Granularity.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 260).labelsHidden()
            .help(granularity != effectiveGranularity ? String(localized: "Hourly resolution is only used for ranges up to 14 days.") : String(localized: "Bucket size"))
            Picker("Metric", selection: $metric) {
                ForEach(TrendMetric.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 210)
            if metric == .byModel || metric == .byProject {
                Picker("Measure", selection: $measure) {
                    ForEach(TrendMeasure.allCases) { Text($0.label).tag($0) }
                }.frame(width: 220)
            }
            Spacer()
            Toggle("Table", isOn: $showTable).toggleStyle(.button)
        }
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            KPITile(title: String(localized: "New tokens"), value: Fmt.tokens(totals.tokens.freshTokens), detail: String(localized: "in the selected range"))
            KPITile(title: String(localized: "Processed tokens"), value: Fmt.tokens(totals.tokens.totalProcessed), detail: String(localized: "including cache reads"))
            KPITile(title: String(localized: "Requests"), value: Fmt.grouped(Int64(totals.requests)), detail: String(localized: "\(totals.sessions) sessions"))
            if model.settings.showEstimatedCost {
                KPITile(title: String(localized: "API-equivalent cost"), value: Fmt.cost(totals.cost), detail: String(localized: "estimate, not a charge"))
            }
        }
    }

    private var subtitle: String {
        let s = String(localized: "\(effectiveGranularity.label) buckets in your local time zone.")
        guard granularity != effectiveGranularity else { return s }
        return s + " " + String(localized: "Hourly view is limited to 14 days; showing days.")
    }

    // MARK: Data shaping

    private func data() -> (data: [Datum], style: SeriesStyle, isSingle: Bool) {
        func tokenSeries(_ items: [(String, Color, (TokenCounts) -> Int64)]) -> ([Datum], SeriesStyle) {
            var out: [Datum] = []
            for p in points { for (name, _, f) in items { out.append(Datum(date: p.start, series: name, value: Double(f(p.tokens)))) } }
            return (out, SeriesStyle(names: items.map { $0.0 }, colors: items.map { $0.1 }))
        }
        switch metric {
        case .total:
            let (d, s) = tokenSeries([(String(localized: "Processed tokens"), Palette.series[0], { $0.totalProcessed })])
            return (d, s, true)
        case .inputOutput:
            let (d, s) = tokenSeries([(String(localized: "Input (all)"), Palette.uncachedInput, { $0.logicalInput }),
                                      (String(localized: "Output"), Palette.output, { $0.output })])
            return (d, s, false)
        case .cache:
            let (d, s) = tokenSeries([(String(localized: "Cache read"), Palette.cacheRead, { $0.cacheRead }),
                                      (String(localized: "Cache creation"), Palette.cacheWrite, { $0.cacheCreation })])
            return (d, s, false)
        case .categories:
            let (d, s) = tokenSeries([(String(localized: "Uncached input"), Palette.uncachedInput, { $0.uncachedInput }),
                                      (String(localized: "Output"), Palette.output, { $0.output }),
                                      (String(localized: "Cache read"), Palette.cacheRead, { $0.cacheRead }),
                                      (String(localized: "Cache creation"), Palette.cacheWrite, { $0.cacheCreation })])
            return (d, s, false)
        case .requests:
            let name = String(localized: "Requests")
            return (points.map { Datum(date: $0.start, series: name, value: Double($0.requests)) },
                    SeriesStyle(names: [name], colors: [Palette.series[0]]), true)
        case .sessions:
            let name = String(localized: "Sessions")
            return (sessionCounts.map { Datum(date: $0.start, series: name, value: Double($0.sessions)) },
                    SeriesStyle(names: [name], colors: [Palette.series[0]]), true)
        case .cost:
            let name = String(localized: "Estimated cost (USD)")
            return (points.map { Datum(date: $0.start, series: name, value: $0.cost.usdDouble) },
                    SeriesStyle(names: [name], colors: [Palette.series[0]]), true)
        case .byModel, .byProject:
            let source = metric == .byModel ? modelPoints : projectPoints
            func value(_ p: SeriesPoint) -> Double {
                switch measure {
                case .processed: Double(p.tokens.totalProcessed)
                case .fresh: Double(p.tokens.freshTokens)
                case .cost: p.cost.usdDouble
                }
            }
            // Keep the eight largest series; fold the rest into "Other" so that colors stay meaningful.
            var totalsByKey: [String: Double] = [:]
            var labels: [String: String] = [:]
            for p in source { totalsByKey[p.key, default: 0] += value(p); labels[p.key] = p.label }
            let keep = Array(totalsByKey.sorted { $0.value > $1.value }.prefix(7).map(\.key))
            var out: [Datum] = []
            var other: [Date: Double] = [:]
            for p in source {
                if keep.contains(p.key) { out.append(Datum(date: p.start, series: labels[p.key] ?? p.key, value: value(p))) }
                else { other[p.start, default: 0] += value(p) }
            }
            var names = keep.map { labels[$0] ?? $0 }
            var colors = keep.map { ChartColors.shared.color(for: ($0.isEmpty ? "none" : $0)) }
            if !other.isEmpty {
                let otherName = String(localized: "Other")
                names.append(otherName)
                colors.append(Palette.other)
                out += other.map { Datum(date: $0.key, series: otherName, value: $0.value) }
            }
            return (out, SeriesStyle(names: names, colors: colors), false)
        }
    }

    private func axisLabel(_ v: Double) -> String {
        switch metric {
        case .cost: return Fmt.cost(EstimatedCost(picoUSD: Int64(v * 1e12)))
        case .byModel, .byProject where measure == .cost: return Fmt.cost(EstimatedCost(picoUSD: Int64(v * 1e12)))
        case .sessions, .requests: return Fmt.grouped(Int64(v))
        default: return Fmt.tokens(Int64(v))
        }
    }

    private func valueText(_ v: Double) -> String {
        switch metric {
        case .cost: return Fmt.cost(EstimatedCost(picoUSD: Int64(v * 1e12)))
        case .byModel, .byProject where measure == .cost: return Fmt.cost(EstimatedCost(picoUSD: Int64(v * 1e12)))
        case .sessions, .requests: return Fmt.grouped(Int64(v))
        default: return Fmt.grouped(Int64(v))
        }
    }

    // MARK: Chart

    private var chart: some View {
        let (items, style, isSingle) = data()
        let component = effectiveGranularity.component
        let selectedDate = selected.flatMap { s in items.map(\.date).filter { $0 <= s }.max() ?? items.map(\.date).min() }
        return VStack(alignment: .leading, spacing: 10) {
            if !isSingle {
                HStack(spacing: 14) { ForEach(Array(style.names.enumerated()), id: \.offset) { LegendDot(color: style.colors[$0.offset], label: $0.element) } }
            }
            Chart {
                ForEach(items) { d in
                    BarMark(x: .value("Time", d.date, unit: component), y: .value("Value", d.value))
                        .foregroundStyle(by: .value("Series", d.series))
                        .cornerRadius(2)
                }
                if let selectedDate {
                    RuleMark(x: .value("Selected", selectedDate, unit: component))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(date: selectedDate, items: items.filter { $0.date == selectedDate }, style: style)
                        }
                }
            }
            .chartForegroundStyleScale(domain: style.names, range: style.colors)
            .chartLegend(.hidden)
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(Palette.gridLine)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(axisLabel(d)) } }
                }
            }
            .frame(height: 340)
            .accessibilityLabel("\(metric.label) chart")
            .accessibilityHint("Use the Table switch for an accessible listing of the values.")
        }
    }

    private func tooltip(date: Date, items: [Datum], style: SeriesStyle) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(effectiveGranularity == .hour ? .dateTime.month().day().hour() : .dateTime.year().month().day())).font(.caption.weight(.semibold))
            ForEach(Array(style.names.enumerated()), id: \.offset) { i, name in
                if let d = items.first(where: { $0.series == name }), d.value > 0 {
                    HStack(spacing: 6) {
                        Circle().fill(style.colors[i]).frame(width: 7, height: 7)
                        Text(name).font(.caption)
                        Spacer(minLength: 10)
                        Text(valueText(d.value)).font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .padding(8)
        .frame(minWidth: 170)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
    }

    // MARK: Table

    private var table: some View {
        let (items, style, _) = data()
        let dates = Array(Set(items.map(\.date))).sorted(by: >)
        return ScrollView(.vertical) {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("Period").gridColumnAlignment(.leading).font(.caption.weight(.semibold))
                    ForEach(style.names, id: \.self) { Text($0).font(.caption.weight(.semibold)) }
                }
                Divider()
                ForEach(dates, id: \.self) { date in
                    GridRow {
                        Text(date.formatted(effectiveGranularity == .hour ? .dateTime.month().day().hour() : .dateTime.year().month().day()))
                            .gridColumnAlignment(.leading)
                        ForEach(style.names, id: \.self) { name in
                            Text(valueText(items.first { $0.date == date && $0.series == name }?.value ?? 0)).monospacedDigit()
                        }
                    }.font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 420)
    }

    // MARK: Loading

    private func load() async {
        loading = true
        defer { loading = false }
        let filter = model.scoped(range.filter)
        let g = effectiveGranularity
        let wantsModel = metric == .byModel
        let wantsProject = metric == .byProject
        let wantsSessions = metric == .sessions
        do {
            let r = try await model.query { e in
                (try e.series(filter, granularity: g),
                 try e.totals(filter),
                 wantsModel ? try e.series(filter, granularity: g, dimension: .model) : [],
                 wantsProject ? try e.series(filter, granularity: g, dimension: .project) : [],
                 wantsSessions ? try e.sessionsOverTime(filter, granularity: g).map { SessionCount(start: $0.start, sessions: $0.sessions) } : [])
            }
            points = r.0
            totals = r.1
            modelPoints = r.2
            projectPoints = r.3
            sessionCounts = r.4.map { ($0.start, $0.sessions) }
        } catch {
            points = []
        }
    }
}

private struct SessionCount: Sendable { var start: Date; var sessions: Int }
