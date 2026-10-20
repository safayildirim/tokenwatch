import SwiftUI
import Charts
import UsageCore

struct ProjectsPage: View {
    @Environment(AppModel.self) private var model
    @State private var range = RangeSelection(preset: .last30d)
    @State private var rows: [ProjectUsageRow] = []
    @State private var trend: [SeriesPoint] = []
    @State private var sortOrder = [KeyPathComparator(\ProjectUsageRow.processed, order: .reverse)]
    @State private var selection: Set<Int64> = []

    var body: some View {
        PageScroll {
            HStack { RangePicker(selection: $range); Spacer() }
            if rows.isEmpty && model.hasLoaded { NoDataNotice() }
            else {
                Card("Top projects", subtitle: "Processed tokens in the selected range") {
                    Chart(rows.prefix(10)) { p in
                        BarMark(x: .value("Tokens", p.tokens.totalProcessed), y: .value("Project", p.name))
                            .foregroundStyle(ChartColors.shared.color(for: "project:\(p.id)"))
                            .cornerRadius(3)
                            .annotation(position: .trailing) { Text(Fmt.tokens(p.tokens.totalProcessed)).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .chartYAxis { AxisMarks { AxisValueLabel().font(.caption) } }
                    .chartXAxis { AxisMarks { v in
                        AxisGridLine().foregroundStyle(Palette.gridLine)
                        AxisValueLabel { if let n = v.as(Int64.self) { Text(Fmt.tokens(n)) } }
                    } }
                    .frame(height: CGFloat(min(rows.count, 10)) * 30 + 30)
                }
                Card("How usage changes over time", subtitle: "Daily processed tokens for the busiest projects") {
                    let top = rows.prefix(6).map(\.id)
                    let names = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.name) })
                    Chart(trend.filter { top.contains(Int64($0.key) ?? -1) }) { p in
                        BarMark(x: .value("Day", p.start, unit: .day), y: .value("Tokens", p.tokens.totalProcessed))
                            .foregroundStyle(by: .value("Project", names[Int64(p.key) ?? 0] ?? p.label))
                    }
                    .chartForegroundStyleScale(domain: top.map { names[$0] ?? "" }, range: top.map { ChartColors.shared.color(for: "project:\($0)") })
                    .chartYAxis { AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(Palette.gridLine)
                        AxisValueLabel { if let n = v.as(Int64.self) { Text(Fmt.tokens(n)) } }
                    } }
                    .frame(height: 220)
                }
                Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Project", value: \.name) { p in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.name)
                            if let path = p.path { Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        }
                    }
                    TableColumn("Sessions", value: \.sessions) { Text("\($0.sessions)").monospacedDigit() }.width(70)
                    TableColumn("Requests", value: \.requests) { Text(Fmt.grouped(Int64($0.requests))).monospacedDigit() }.width(80)
                    TableColumn("New tokens", value: \.fresh) { Text(Fmt.tokens($0.tokens.freshTokens)).monospacedDigit() }.width(90)
                    TableColumn("Processed", value: \.processed) { Text(Fmt.tokens($0.tokens.totalProcessed)).monospacedDigit() }.width(90)
                    TableColumn("Share", value: \.tokenShare) { Text(Fmt.ratio($0.tokenShare)).monospacedDigit() }.width(64)
                    if model.settings.showEstimatedCost {
                        TableColumn("Est. cost", value: \.cost.picoUSD) { Text(Fmt.cost($0.cost)).monospacedDigit() }.width(80)
                    }
                    TableColumn("Last activity", value: \.lastActivityKey) { Text(Fmt.relative($0.lastActivity)).foregroundStyle(.secondary) }.width(100)
                }
                .contextMenu(forSelectionType: Int64.self) { _ in } primaryAction: { ids in
                    if let id = ids.first { model.show(project: id) }
                }
                .frame(height: min(CGFloat(rows.count) * 28 + 60, 460))
                Text("Double-click a project to see its individual sessions.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(range.preset.rawValue)|\(range.customFrom)|\(range.customTo)|\(model.dataVersion)|\(model.scopeVersion)") { await load() }
    }

    private func load() async {
        let f = model.scoped(range.filter)
        if let r = try? await model.query({ e in (try e.projects(f), try e.series(f, granularity: .day, dimension: .project)) }) {
            rows = r.0
            trend = r.1
        }
    }
}

extension ProjectUsageRow {
    var processed: Int64 { tokens.totalProcessed }
    var fresh: Int64 { tokens.freshTokens }
    var lastActivityKey: Date { lastActivity ?? .distantPast }
}

struct ModelsPage: View {
    @Environment(AppModel.self) private var model
    @State private var range = RangeSelection(preset: .last30d)
    @State private var rows: [ModelUsageRow] = []
    @State private var sortOrder = [KeyPathComparator(\ModelUsageRow.processed, order: .reverse)]

    var body: some View {
        PageScroll {
            HStack { RangePicker(selection: $range); Spacer() }
            if rows.isEmpty && model.hasLoaded { NoDataNotice() }
            else {
                HStack(alignment: .top, spacing: 12) {
                    Card("Token share", subtitle: "Share of all processed tokens") {
                        Chart(rows) { m in
                            SectorMark(angle: .value("Tokens", m.tokens.totalProcessed), innerRadius: .ratio(0.62), angularInset: 1.5)
                                .foregroundStyle(ChartColors.shared.color(for: m.canonical))
                                .cornerRadius(3)
                        }
                        .frame(height: 200)
                        .accessibilityLabel("Token share by model")
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(rows) { m in
                                HStack {
                                    LegendDot(color: ChartColors.shared.color(for: m.canonical), label: m.displayName)
                                    Spacer()
                                    Text(Fmt.ratio(m.tokenShare)).font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }
                    Card("Request volume") {
                        Chart(rows) { m in
                            BarMark(x: .value("Requests", m.requests), y: .value("Model", m.displayName))
                                .foregroundStyle(ChartColors.shared.color(for: m.canonical)).cornerRadius(3)
                                .annotation(position: .trailing) { Text(Fmt.grouped(Int64(m.requests))).font(.caption2).foregroundStyle(.secondary) }
                        }
                        .chartXAxis(.hidden)
                        .frame(height: CGFloat(rows.count) * 36 + 30)
                    }
                }
                Card("Input, output and cache mix per model", subtitle: "Each bar shows how that model's processed tokens divide between the four categories.") {
                    HStack(spacing: 14) {
                        LegendDot(color: Palette.uncachedInput, label: "Uncached input"); LegendDot(color: Palette.output, label: "Output")
                        LegendDot(color: Palette.cacheRead, label: "Cache read"); LegendDot(color: Palette.cacheWrite, label: "Cache write")
                    }
                    Chart {
                        ForEach(rows) { m in
                            let total = Double(max(1, m.tokens.totalProcessed))
                            BarMark(x: .value("Share", Double(m.tokens.uncachedInput) / total * 100), y: .value("Model", m.displayName)).foregroundStyle(by: .value("Category", "Uncached input"))
                            BarMark(x: .value("Share", Double(m.tokens.output) / total * 100), y: .value("Model", m.displayName)).foregroundStyle(by: .value("Category", "Output"))
                            BarMark(x: .value("Share", Double(m.tokens.cacheRead) / total * 100), y: .value("Model", m.displayName)).foregroundStyle(by: .value("Category", "Cache read"))
                            BarMark(x: .value("Share", Double(m.tokens.cacheCreation) / total * 100), y: .value("Model", m.displayName)).foregroundStyle(by: .value("Category", "Cache write"))
                        }
                    }
                    .chartForegroundStyleScale(["Uncached input": Palette.uncachedInput, "Output": Palette.output, "Cache read": Palette.cacheRead, "Cache write": Palette.cacheWrite])
                    .chartLegend(.hidden)
                    .chartXScale(domain: 0...100)
                    .chartXAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine().foregroundStyle(Palette.gridLine)
                        AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%") } }
                    } }
                    .frame(height: CGFloat(rows.count) * 36 + 40)
                }
                Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
                    TableColumn("Model", value: \.displayName) { m in
                        HStack { Circle().fill(ChartColors.shared.color(for: m.canonical)).frame(width: 8, height: 8); Text(m.displayName) }
                    }
                    TableColumn("Requests", value: \.requests) { Text(Fmt.grouped(Int64($0.requests))).monospacedDigit() }.width(80)
                    TableColumn("Input", value: \.tokens.uncachedInput) { Text(Fmt.tokens($0.tokens.uncachedInput)).monospacedDigit() }.width(70)
                    TableColumn("Output", value: \.tokens.output) { Text(Fmt.tokens($0.tokens.output)).monospacedDigit() }.width(70)
                    TableColumn("Cache read", value: \.tokens.cacheRead) { Text(Fmt.tokens($0.tokens.cacheRead)).monospacedDigit() }.width(80)
                    TableColumn("Cache write", value: \.tokens.cacheCreation) { Text(Fmt.tokens($0.tokens.cacheCreation)).monospacedDigit() }.width(80)
                    TableColumn("Hit ratio", value: \.hitRatio) { Text(Fmt.ratio($0.tokens.cacheHitRatio)).monospacedDigit() }.width(70)
                    TableColumn("Share", value: \.tokenShare) { Text(Fmt.ratio($0.tokenShare)).monospacedDigit() }.width(64)
                    if model.settings.showEstimatedCost {
                        TableColumn("Est. cost", value: \.cost.picoUSD) { m in
                            Text(Fmt.cost(m.cost)).monospacedDigit()
                                .help(m.cost.isPartial ? "No price card exists for this model, so its tokens are not included." : "")
                        }.width(80)
                    }
                }
                .frame(height: CGFloat(rows.count) * 28 + 60)
                if model.settings.showEstimatedCost {
                    Text("Costs are estimates at published API list prices (as of \(PricingCatalog.asOf)). A model without a price card is shown as unpriced instead of being guessed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(range.preset.rawValue)|\(range.customFrom)|\(range.customTo)|\(model.dataVersion)|\(model.scopeVersion)") {
            let f = model.scoped(range.filter)
            if let r = try? await model.query({ try $0.models(f) }) { rows = r }
        }
    }
}

extension ModelUsageRow {
    var processed: Int64 { tokens.totalProcessed }
    var hitRatio: Double { tokens.cacheHitRatio ?? 0 }
}
