import SwiftUI
import Charts
import UsageCore

/// API-equivalent cost estimates, per provider and model. These say what the same tokens would cost at published pay-as-you-go
/// prices. They are not a subscription charge, and a model without a rate card is shown as unpriced.
struct CostPage: View {
    @Environment(AppModel.self) private var model
    @State private var range = RangeSelection(preset: .last30d)
    @State private var providers: [ProviderUsageRow] = []
    @State private var models: [ModelUsageRow] = []
    @State private var daily: [SeriesPoint] = []

    var body: some View {
        PageScroll {
            HStack { RangePicker(selection: $range); Spacer() }
            if !model.settings.showEstimatedCost {
                Card { Text("Cost estimates are switched off in Settings.").foregroundStyle(.secondary) }
            } else if providers.isEmpty {
                NoDataNotice()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(providers) { row in
                        KPITile(title: model.providerName(row.provider), value: Fmt.cost(row.cost),
                                detail: row.cost.isPartial ? "\(Fmt.tokens(row.cost.unpricedTokens)) tokens have no price" : "\(Fmt.tokens(row.tokens.totalProcessed)) processed",
                                help: "API-equivalent estimate for this provider only. Providers are not added together, because they price tokens differently.")
                    }
                }
                ForEach(providers.filter { $0.cost.picoUSD == 0 && $0.cost.unpricedTokens > 0 }) { row in
                    Card {
                        Label("\(model.providerName(row.provider)) usage is unpriced", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text("No rate card is installed for \(model.providerName(row.provider))'s models, and a price is never guessed. Add the published prices for your models under Settings → Pricing and the estimate fills in for past and future usage.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Card("Cost per day", subtitle: "Estimated, by provider. Days with unpriced usage are lower bounds.") {
                    if daily.isEmpty { Text("No priced usage in this period.").foregroundStyle(.secondary) }
                    else {
                        let ids = Array(Set(daily.map(\.key))).sorted()
                        Chart(daily.filter { !$0.key.isEmpty }) { p in
                            BarMark(x: .value("Day", p.start, unit: .day), y: .value("Cost", p.cost.usdDouble))
                                .foregroundStyle(by: .value("Provider", model.providerName(ProviderID(rawValue: p.key))))
                        }
                        .chartForegroundStyleScale(domain: ids.map { model.providerName(ProviderID(rawValue: $0)) },
                                                   range: ids.indices.map { Palette.series[$0 % Palette.series.count] })
                        .chartYAxis { AxisMarks(position: .leading) { v in
                            AxisGridLine().foregroundStyle(Palette.gridLine)
                            AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "$%.0f", d)) } }
                        } }
                        .frame(height: 200)
                    }
                }
                Card("By model") {
                    Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 5) {
                        GridRow {
                            Text("Model").gridColumnAlignment(.leading)
                            Text("Provider").gridColumnAlignment(.leading)
                            Text("Requests"); Text("Processed"); Text("Estimated cost")
                        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Divider()
                        ForEach(models) { m in
                            GridRow {
                                Text(m.displayName).gridColumnAlignment(.leading)
                                Text(model.providerName(m.provider)).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                                Text(Fmt.grouped(Int64(m.requests))).monospacedDigit()
                                Text(Fmt.tokens(m.tokens.totalProcessed)).monospacedDigit()
                                Text(Fmt.cost(m.cost)).monospacedDigit()
                            }.font(.callout)
                        }
                    }
                }
            }
            Text("Estimated cost applies published pay-as-you-go prices to the tokens in each category. Reasoning tokens are part of output and are priced once. A subscription is billed differently, so these figures say nothing about what you pay.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: "\(range.preset.rawValue)|\(range.customFrom)|\(range.customTo)|\(model.dataVersion)|\(model.scopeVersion)") { await load() }
    }

    private func load() async {
        let f = model.scoped(range.filter)
        if let r = try? await model.query({ e in (try e.providers(f), try e.models(f), try e.series(f, granularity: .day, dimension: .provider)) }) {
            providers = r.0
            models = r.1.sorted { $0.cost.picoUSD > $1.cost.picoUSD }
            daily = r.2
        }
    }
}
