import SwiftUI
import Charts
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

struct OverviewPage: View {
    @Environment(AppModel.self) private var model
    @State private var daily: [SeriesPoint] = []
    @State private var topModels: [ModelUsageRow] = []
    @State private var topProjects: [ProjectUsageRow] = []
    @State private var loadError: String?

    var body: some View {
        let o = model.overview
        PageScroll {
            if model.menuBarIconHidden { hiddenIconNotice }
            if let banner = importBanner { banner }
            if o.allTime.requests == 0 && model.hasLoaded {
                NoDataNotice()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                    KPITile(title: "Tokens today", value: Fmt.tokens(o.today.tokens.freshTokens),
                            detail: "new · \(Fmt.tokens(o.today.tokens.totalProcessed)) processed",
                            help: "New tokens are uncached input, cache writes and output. Processed tokens also include cache reads.")
                    KPITile(title: "Tokens this week", value: Fmt.tokens(o.thisWeek.tokens.freshTokens),
                            detail: "new · \(Fmt.tokens(o.thisWeek.tokens.totalProcessed)) processed")
                    KPITile(title: "Tokens this month", value: Fmt.tokens(o.thisMonth.tokens.freshTokens),
                            detail: "new · \(Fmt.tokens(o.thisMonth.tokens.totalProcessed)) processed")
                    KPITile(title: "Active sessions", value: "\(o.activeSessions)",
                            detail: "\(o.totalSessions) sessions in total")
                    KPITile(title: "Cache hit ratio", value: Fmt.ratio(o.thisMonth.tokens.cacheHitRatio),
                            detail: "this month · cache read ÷ all input",
                            help: "Cache-read tokens divided by logical input (uncached + cache read + cache write).")
                    if model.settings.showEstimatedCost {
                        KPITile(title: "API-equivalent cost", value: Fmt.cost(o.thisMonth.cost),
                                detail: "this month · \(Fmt.cost(o.today.cost)) today",
                                help: "What this usage would cost at published API prices. This is not a subscription charge.")
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.quotaStates.filter { $0.kind != .spendLimit || $0.reading != nil }) { s in
                        Card { QuotaMeter(state: s, onSetup: { model.selection = .quota }) }
                    }
                }

                Card("Token mix this month", subtitle: "Where the tokens went. Cache reads are shown separately because they dominate long sessions.") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("All processed tokens").font(.caption.weight(.medium))
                        TokenCompositionBar(tokens: o.thisMonth.tokens, includeCacheReads: true)
                        Text("New tokens only (without cache reads)").font(.caption.weight(.medium))
                        TokenCompositionBar(tokens: o.thisMonth.tokens, includeCacheReads: false)
                    }
                }

                Card("Last 14 days", subtitle: "New tokens per day (uncached input, cache writes and output)") {
                    if daily.isEmpty { Text("No activity in this period.").foregroundStyle(.secondary) }
                    else {
                        Chart(daily) { p in
                            BarMark(x: .value("Day", p.start, unit: .day), y: .value("New tokens", p.tokens.freshTokens))
                                .foregroundStyle(Palette.series[0])
                                .cornerRadius(3)
                        }
                        .chartYAxis { AxisMarks(position: .leading) { v in
                            AxisGridLine().foregroundStyle(Palette.gridLine)
                            AxisValueLabel { if let n = v.as(Int64.self) { Text(Fmt.tokens(n)) } }
                        } }
                        .frame(height: 170)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Card("Top models this month") {
                        ForEach(topModels.prefix(5)) { m in
                            HStack {
                                Circle().fill(ChartColors.shared.color(for: m.canonical)).frame(width: 8, height: 8)
                                Text(m.displayName)
                                Spacer()
                                Text(Fmt.tokens(m.tokens.totalProcessed)).monospacedDigit().foregroundStyle(.secondary)
                                Text(Fmt.ratio(m.tokenShare)).frame(width: 56, alignment: .trailing).monospacedDigit().foregroundStyle(.secondary)
                            }.font(.callout)
                        }
                        if topModels.isEmpty { Text("—").foregroundStyle(.secondary) }
                    }
                    Card("Top projects this month") {
                        ForEach(topProjects.prefix(5)) { p in
                            Button { model.show(project: p.id) } label: {
                                HStack {
                                    Text(p.name).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.tokens(p.tokens.totalProcessed)).monospacedDigit().foregroundStyle(.secondary)
                                    Text(Fmt.ratio(p.tokenShare)).frame(width: 56, alignment: .trailing).monospacedDigit().foregroundStyle(.secondary)
                                }.font(.callout).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if topProjects.isEmpty { Text("—").foregroundStyle(.secondary) }
                    }
                }

                Text("Token counts come from local Claude Code transcripts. They do not include usage from claude.ai chat, Cowork or other devices, so they can be lower than your account's real consumption.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: model.dataVersion) { await load() }
    }

    private var hiddenIconNotice: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Label("macOS is hiding the menu bar icon", systemImage: "menubar.rectangle").font(.headline)
                Text("The menu bar has no room left, so the icon sits under the notch. The app is available from the Dock for now. To get the icon back, quit or hide a few other menu bar items, or hold ⌘ and drag icons to rearrange them.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var importBanner: (some View)? {
        let snap = model.collectorSnapshot
        return Group {
            if snap.isSyncing, let p = snap.progress, snap.isInitialImport {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Importing existing Claude history").font(.headline)
                        ProgressView(value: p)
                        Text("\(Int(p * 100))% · \(Fmt.tokens(snap.bytesDone))B of \(Fmt.tokens(snap.bytesTotal))B read. Numbers below are partial until this finishes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func load() async {
        let now = Date()
        let monthStart = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        let from = Calendar.current.date(byAdding: .day, value: -13, to: Calendar.current.startOfDay(for: now))!
        do {
            let result = try await model.query { engine in
                (try engine.series(UsageFilter(from: from), granularity: .day),
                 try engine.models(UsageFilter(from: monthStart)),
                 try engine.projects(UsageFilter(from: monthStart)))
            }
            daily = result.0
            topModels = result.1
            topProjects = result.2
        } catch { loadError = "\(error)" }
    }
}
