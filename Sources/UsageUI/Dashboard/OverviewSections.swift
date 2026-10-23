import SwiftUI
import UsageCore

/// A section title with an optional note beside it, which moves under the title when the window is narrow.
struct SectionHeading: View {
    var title: String
    var note: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                heading
                Spacer(minLength: 0)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            VStack(alignment: .leading, spacing: 2) {
                heading
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private var heading: some View {
        Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }
}

/// The title and subtitle at the top of a card.
struct CardHeading: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The large figure of a tile, in the rounded face with digits of equal width.
func figure(_ text: String, size: CGFloat) -> Text {
    Text(text).font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
}

// MARK: - Equal grid

/// Lays cards out in rows of equal columns, every card as tall as the tallest, so a row never has ragged edges and a
/// card left alone on the last row keeps the size of the others. Given more height than it needs, it shares the
/// extra among its rows, so a grid inside a stretched card reaches the card's bottom edge.
struct EqualGrid: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat

    private func columns(width: CGFloat, count: Int) -> Int {
        max(1, min(count, Int((width + spacing) / (minimumWidth + spacing))))
    }

    private func metrics(width: CGFloat, subviews: Subviews) -> (columns: Int, rows: Int, cell: CGSize) {
        let cols = columns(width: width, count: subviews.count)
        let rows = (subviews.count + cols - 1) / cols
        let cellWidth = max(0, (width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
        let cellHeight = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
        return (cols, rows, CGSize(width: cellWidth, height: cellHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? minimumWidth * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1)
        let m = metrics(width: width, subviews: subviews)
        let natural = m.cell.height * CGFloat(m.rows) + spacing * CGFloat(m.rows - 1)
        let offered = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return CGSize(width: width, height: max(natural, offered))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let m = metrics(width: bounds.width, subviews: subviews)
        let height = max(m.cell.height, (bounds.height - spacing * CGFloat(m.rows - 1)) / CGFloat(m.rows))
        for (i, view) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(i % m.columns) * (m.cell.width + spacing)
            let y = bounds.minY + CGFloat(i / m.columns) * (height + spacing)
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: m.cell.width, height: height))
        }
    }
}

// MARK: - Limits

/// The quota windows of every pool in scope, with what the current pace leads to.
struct OverviewLimits: View {
    @Environment(AppModel.self) private var model
    var pools: [QuotaPoolState]
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: String(localized: "Your limits right now"),
                           note: String(localized: "Limits belong to an account and run on their own clock, so the period and surface filters do not change them."))
            if pools.isEmpty {
                Text("No provider has reported a limit yet.").foregroundStyle(.secondary).overviewCard()
            } else {
                EqualGrid(minimumWidth: 420, spacing: 12) {
                    ForEach(pools) { pool in poolCard(pool) }
                }
            }
        }
    }

    private func poolCard(_ pool: QuotaPoolState) -> some View {
        let info = pool.pool
        let connected = !(model.lacksClaudeFigure(info) && pool.windows.allSatisfy { $0.reading == nil })
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.providerColor(info.key.provider)).frame(width: 10, height: 10)
                Text(info.name).font(.system(size: 13, weight: .semibold))
                if let chip = chip(info) {
                    Text(chip).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            if !info.note.isEmpty { Text(info.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if connected {
                EqualGrid(minimumWidth: 220, spacing: 10) {
                    ForEach(pool.windows) { w in WindowTile(state: w, now: now) }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Claude limits reported yet").fontWeight(.semibold)
                    Text("Tokenwatch reads Claude Code's local usage cache automatically. The snapshot appears when Claude Code next fetches usage.")
                        .foregroundStyle(.secondary).frame(maxWidth: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Button("Open Limits") { model.selection = .quota }.buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .overviewInset(padding: 14)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overviewCard()
    }

    /// The account and plan, such as "Personal · Max plan".
    private func chip(_ info: QuotaPoolInfo) -> String? {
        let account = info.accountLabel == "Unassigned" ? nil : info.accountLabel
        let plan = info.planType.map { p in String(localized: "\(p.capitalized) plan") }
        let parts = [account, plan].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One window of a pool: how much is used, whether that is a worry, and when it resets.
private struct WindowTile: View {
    @Environment(AppModel.self) private var model
    var state: QuotaWindowState
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.displayName).fontWeight(.semibold)
                Spacer(minLength: 0)
                if let pct = state.utilizationPercent {
                    figure("\(Int(pct.rounded()))%", size: 20) + Text(" used").font(.caption).foregroundColor(.secondary)
                } else {
                    figure("—", size: 20).foregroundColor(.secondary)
                }
            }
            ProgressBar(fraction: (state.utilizationPercent ?? 0) / 100, height: 8, fill: fill,
                        minimum: state.utilizationPercent == nil ? 0 : 4)
                .opacity(state.freshness == .stale ? 0.45 : 1)
                .accessibilityHidden(true)
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overviewInset()
        .accessibilityElement(children: .combine)
    }

    private var fill: Color {
        guard let pct = state.utilizationPercent else { return Palette.track }
        return state.isAuthoritative ? Palette.quota(pct) : Palette.other
    }

    @ViewBuilder private var content: some View {
        switch state.availability {
        case .available:
            if let pct = state.utilizationPercent {
                let outlook = WindowOutlook.evaluate(used: pct, resetsAt: state.resetsAt, length: state.length, now: now)
                HStack(spacing: 6) {
                    LevelIcon(level: outlook.level)
                    Text(outlook.status).fontWeight(.medium)
                }
                Text(timing(outlook)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if state.freshness == .stale || !state.isAuthoritative, let r = state.reading {
                    HStack(spacing: 4) {
                        if state.freshness == .stale {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                            Text("Stale: last reported \(Fmt.relative(r.observedAt, now: now)).")
                        }
                        if !state.isAuthoritative { Text("Unverified source.") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .windowElapsed(let at):
            Text("Reset \(Fmt.relative(at, now: now))").fontWeight(.medium)
            Text("The new figure appears after \(model.providerName(state.pool.key.provider)) next reports it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .unavailable:
            Text("No figure yet").fontWeight(.medium)
            Text("This window has not been reported yet.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func timing(_ outlook: WindowOutlook) -> String {
        guard let reset = state.resetsAt else { return String(localized: "Reset time not reported.") }
        let calendar = Calendar.current
        let at = OverviewLogic.clock(reset, now: now, calendar: calendar)
        let wait = Fmt.spokenDuration(reset.timeIntervalSince(now))
        let resetText = String(localized: "Resets \(at), in \(wait).")
        guard state.length != nil else { return resetText }
        if let out = outlook.runsOutAt {
            let outAt = OverviewLogic.clock(out, now: now, calendar: calendar)
            let early = Fmt.spokenDuration(reset.timeIntervalSince(out))
            return resetText + " " + String(localized: "At this pace it runs out \(outAt), \(early) early.")
        }
        return resetText + " " + String(localized: "At this pace it lasts until then.")
    }
}

/// The symbol that goes with every status word: a check, a warning triangle or a stop sign.
private struct LevelIcon: View {
    var level: WindowOutlook.Level

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.palette).foregroundStyle(.white, color)
            .font(.system(size: 13))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch level {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    private var color: Color {
        switch level {
        case .good: Palette.good
        case .warning: Palette.warning
        case .critical: Palette.critical
        }
    }
}

// MARK: - At a glance

/// The headline figures of the period, with an optional explanation of each term.
struct OverviewGlance: View {
    @Environment(AppModel.self) private var model
    var period: OverviewPeriod
    var data: OverviewData
    var activeNow: Int
    var showCost: Bool
    @State private var explaining = false

    private static var glossary: [(String, String)] {
        [
            (String(localized: "New tokens"), String(localized: "Text the tools sent for the first time, plus everything the model wrote. This is the number that follows real work.")),
            (String(localized: "Reused from cache"), String(localized: "Context sent again in later turns of a conversation. Providers charge far less for it, so a high share is a good sign.")),
            (String(localized: "Sessions"), String(localized: "One conversation in a coding tool. A session counts as active when it wrote something in the last few minutes.")),
            (String(localized: "Est. API cost"), String(localized: "What this usage would cost at published API prices. It is not your subscription bill.")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(period.title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { explaining.toggle() } label: {
                    Label(explaining ? String(localized: "Hide Explanations") : String(localized: "What Do These Mean?"),
                          systemImage: "questionmark.circle")
                }
            }
            if explaining {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 20, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(Self.glossary.prefix(showCost ? 4 : 3), id: \.0) { term in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(term.0).fontWeight(.semibold)
                            Text(term.1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .overviewCard()
            }
            EqualGrid(minimumWidth: 210, spacing: 12) {
                ForEach(tiles, id: \.label) { t in StatTile(tile: t) }
            }
        }
    }

    struct Tile {
        var label: String
        var value: String
        var sub: String
        var note: String
    }

    private var tiles: [Tile] {
        let cur = data.current
        let reuse: String
        if cur.coverage.requests > 0 && cur.coverage.missingCacheRead == cur.coverage.requests { reuse = "—" }
        else { reuse = cur.tokens.cacheHitRatio.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
        let processed = Fmt.tokens(cur.tokens.totalProcessed)
        var out = [
            Tile(label: String(localized: "New tokens"), value: Fmt.tokens(cur.tokens.freshTokens),
                 sub: OverviewLogic.changeText(current: cur.tokens.freshTokens, previous: data.previous.tokens.freshTokens, period: period),
                 note: String(localized: "\(processed) processed in total, counting cache reads.")),
            Tile(label: String(localized: "Reused from cache"), value: reuse, sub: String(localized: "of all input came from the cache."),
                 note: String(localized: "A higher share is cheaper and faster.")),
            Tile(label: String(localized: "Sessions"), value: "\(cur.sessions)", sub: String(localized: "\(activeNow) active right now."), note: sessionsNote),
        ]
        if showCost {
            out.append(Tile(label: String(localized: "API-equivalent cost"), value: Fmt.cost(cur.cost), sub: String(localized: "At published API prices."),
                            note: String(localized: "This is not your subscription bill.")))
        }
        return out
    }

    private var sessionsNote: String {
        let rows = data.providers.filter { $0.sessions > 0 }
        if rows.isEmpty { return period.noSessionsLine }
        if rows.count == 1 {
            let tool = model.toolName(rows[0].provider)
            return String(localized: "All in \(tool).")
        }
        let parts = rows.map { row in
            let tool = model.toolName(row.provider)
            return String(localized: "\(row.sessions) in \(tool)")
        }
        return OverviewLogic.list(parts) + "."
    }
}

struct StatTile: View {
    var tile: OverviewGlance.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.label).font(.caption).foregroundStyle(.secondary)
            figure(tile.value, size: 26).lineLimit(1).minimumScaleFactor(0.6)
            Text(tile.sub).fixedSize(horizontal: false, vertical: true)
            Text(tile.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Activity

/// New tokens per hour or day, stacked by provider. Clicking a bar shows what happened in it beside the chart.
struct OverviewActivity: View {
    @Environment(AppModel.self) private var model
    var period: OverviewPeriod
    var data: OverviewData
    var showCost: Bool
    @State private var picked: [OverviewPeriod: Int] = [:]

    private let plotHeight: CGFloat = 200

    var body: some View {
        let buckets = data.period == period ? data.buckets : []
        let selected = buckets.isEmpty ? 0 : min(picked[period] ?? OverviewLogic.defaultSelection(buckets), buckets.count - 1)
        let providers = shownProviders
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                CardHeading(title: String(localized: "Activity"), subtitle: period.chartSubtitle)
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    ForEach(providers, id: \.self) { p in LegendDot(color: model.providerColor(p), label: model.toolName(p)) }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                chart(buckets, providers: providers, selected: selected)
                    .frame(minWidth: 400)
                if buckets.indices.contains(selected) {
                    detail(buckets[selected], providers: providers)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .overviewCard()
    }

    /// The providers with usage in the period, in the registry's order so that the stacking never changes.
    private var shownProviders: [ProviderID] {
        let used = Set(data.providers.map(\.provider))
        return model.providers.map(\.id).filter(used.contains)
    }

    private var gap: CGFloat {
        switch period {
        case .today: 4
        case .week: 16
        case .month: 3
        }
    }

    private func chart(_ buckets: [OverviewBucket], providers: [ProviderID], selected: Int) -> some View {
        let top = OverviewLogic.niceCeiling(buckets.map(\.totalFresh).max() ?? 0)
        let calendar = Calendar.current
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                GeometryReader { g in
                    ForEach([1.0, 0.5, 0.0], id: \.self) { f in
                        Text(f == 0 ? "0" : Fmt.tokens(Int64((Double(top) * f).rounded())))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: g.size.width, alignment: .trailing)
                            .position(x: g.size.width / 2, y: g.size.height * (1 - f))
                    }
                }
                .frame(width: 36, height: plotHeight)
                ZStack(alignment: .bottom) {
                    GeometryReader { g in
                        ForEach([1.0, 0.5, 0.0], id: \.self) { f in
                            Rectangle().fill(Palette.gridLine).frame(height: 1)
                                .position(x: g.size.width / 2, y: g.size.height * (1 - f))
                        }
                    }
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(buckets) { b in
                            ActivityBar(bucket: b, order: providers, colors: colors(providers), top: top, height: plotHeight,
                                        selected: b.index == selected, label: barLabel(b)) {
                                picked[period] = b.index
                            }
                        }
                    }
                }
                .frame(height: plotHeight)
            }
            .padding(.top, 8)
            HStack(spacing: gap) {
                ForEach(buckets) { b in
                    let on = b.index == selected
                    Text(OverviewLogic.shortLabel(b, period: period, count: buckets.count, selected: on, calendar: calendar))
                        .font(.system(size: 11, weight: on ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                        .lineLimit(1).fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, 44)
            .accessibilityHidden(true)
            Text("Click a bar to see what happened in it.").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    private func colors(_ providers: [ProviderID]) -> [ProviderID: Color] {
        Dictionary(uniqueKeysWithValues: providers.map { ($0, model.providerColor($0)) })
    }

    private func barLabel(_ b: OverviewBucket) -> String {
        let title = OverviewLogic.title(of: b, period: period)
        let total = Fmt.tokens(b.totalFresh)
        return b.isFuture ? String(localized: "\(title): not reached yet") : String(localized: "\(title): \(total) new tokens")
    }

    private func detail(_ b: OverviewBucket, providers: [ProviderID]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            (period == .today ? Text("Selected hour") : Text("Selected day")).font(.caption).foregroundStyle(.secondary)
            Text(OverviewLogic.title(of: b, period: period)).fontWeight(.semibold)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                figure(Fmt.tokens(b.totalFresh), size: 26)
                Text("new tokens").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(providers, id: \.self) { p in
                    detailRow(model.toolName(p), Fmt.tokens(b.fresh[p] ?? 0), swatch: model.providerColor(p))
                }
                detailRow(String(localized: "Cache reads"), Fmt.tokens(b.cacheRead))
                detailRow(String(localized: "Sessions"), "\(b.sessions)")
                if showCost { detailRow(String(localized: "API-equivalent cost"), Fmt.cost(b.cost)) }
            }
        }
        .padding(14)
        .frame(width: 250, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    private func detailRow(_ label: String, _ value: String, swatch: Color = .clear) -> some View {
        HStack(spacing: 8) {
            Circle().fill(swatch).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
        }
    }
}

/// One bar of the activity chart. It is a button, so it can be chosen with the keyboard as well as the mouse.
private struct ActivityBar: View {
    var bucket: OverviewBucket
    var order: [ProviderID]
    var colors: [ProviderID: Color]
    var top: Int64
    var height: CGFloat
    var selected: Bool
    var label: String
    var action: () -> Void

    var body: some View {
        // The first provider sits at the bottom of the stack, so it lines up from bar to bar.
        let segments = order.reversed().compactMap { p -> (ProviderID, Int64)? in
            let v = bucket.fresh[p] ?? 0
            return v > 0 ? (p, v) : nil
        }
        let frame = UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5)
        Button(action: action) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if segments.isEmpty {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.track).frame(height: 3)
                } else {
                    VStack(spacing: 0) {
                        ForEach(segments, id: \.0) { s in
                            Rectangle().fill(colors[s.0] ?? Palette.other)
                                .frame(height: max(1, height * CGFloat(s.1) / CGFloat(max(1, top))))
                        }
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(frame.fill(selected ? Color.accentColor.opacity(0.12) : .clear))
            .overlay { if selected { frame.stroke(Color.accentColor, lineWidth: 2).padding(-1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(bucket.isFuture)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Token mix

/// The new tokens of the period split into their categories, optionally with the cache reads beside them.
struct OverviewTokenMix: View {
    var period: OverviewPeriod
    var tokens: TokenCounts
    @State private var includeCacheReads = false

    private struct Part: Identifiable {
        var name: String
        var value: Int64
        var color: Color
        var why: String
        var id: String { name }
    }

    private var parts: [Part] {
        var p = [
            Part(name: String(localized: "Output"), value: tokens.output, color: Palette.output,
                 why: String(localized: "What the model wrote: answers, code and tool calls.")),
            Part(name: String(localized: "Cache writes"), value: tokens.cacheCreation, color: Palette.cacheWrite,
                 why: String(localized: "Context saved the first time, so later turns can reuse it.")),
            Part(name: String(localized: "Uncached input"), value: tokens.uncachedInput, color: Palette.uncachedInput,
                 why: String(localized: "Prompt text read fresh, without the cache.")),
        ]
        if includeCacheReads {
            p.append(Part(name: String(localized: "Cache reads"), value: tokens.cacheRead, color: Palette.cacheRead,
                          why: String(localized: "Saved context read again. Each read is cheap, but they dominate long sessions.")))
        }
        return p.filter { $0.value > 0 }
    }

    var body: some View {
        let parts = self.parts
        let total = max(1, parts.reduce(Int64(0)) { $0 + $1.value })
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                CardHeading(title: String(localized: "Where the tokens went"),
                            subtitle: includeCacheReads ? period.processedTotal(Fmt.tokens(total)) : period.newTokensTotal(Fmt.tokens(total)))
                Spacer(minLength: 0)
                Toggle("Include cache reads", isOn: $includeCacheReads).toggleStyle(.switch).controlSize(.small)
            }
            GeometryReader { geo in
                let room = geo.size.width - CGFloat(max(0, parts.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(parts) { part in
                        Rectangle().fill(part.color).frame(width: max(3, room * CGFloat(part.value) / CGFloat(total)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.track)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel(parts.map { "\($0.name) \(share($0.value, of: total))" }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(parts) { part in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(part.color).frame(width: 8, height: 8).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 12) {
                                Text(part.name).fontWeight(.medium)
                                Spacer(minLength: 0)
                                Text("\(Fmt.tokens(part.value)) · \(share(part.value, of: total))")
                                    .font(.system(size: 13, design: .rounded)).monospacedDigit()
                            }
                            Text(part.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if parts.isEmpty { Text(period.noTokensLine).foregroundStyle(.secondary) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overviewCard()
    }

    private func share(_ v: Int64, of total: Int64) -> String { "\(Int((Double(v) / Double(total) * 100).rounded()))%" }
}

// MARK: - Ranking

/// The projects, models or tools that took the most new tokens in the period.
struct OverviewRanking: View {
    @Environment(AppModel.self) private var model
    var period: OverviewPeriod
    var data: OverviewData
    var showCost: Bool
    @AppStorage("overview.rankBy") private var tab: Tab = .projects
    @State private var openProject: ProjectUsageRow?

    enum Tab: String, CaseIterable, Identifiable {
        case projects = "Projects", models = "Models", tools = "Tools"
        var id: String { rawValue }

        var label: String {
            switch self {
            case .projects: String(localized: "Projects")
            case .models: String(localized: "Models")
            case .tools: String(localized: "Tools")
            }
        }
    }

    fileprivate struct Row: Identifiable {
        var id: String
        var name: String
        var fresh: Int64
        var sub: String
        var color: Color
        var project: ProjectUsageRow?
    }

    var body: some View {
        let total = max(1, data.current.tokens.freshTokens)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                CardHeading(title: String(localized: "What used the most"),
                            subtitle: tab == .projects ? period.newTokensClickProjectLine : period.newTokensLine)
                Spacer(minLength: 0)
                Segments(title: String(localized: "Group by"), selection: $tab, items: Tab.allCases.map { ($0, $0.label) })
            }
            VStack(spacing: 4) {
                ForEach(rows) { row in
                    RankRow(row: row, share: Double(row.fresh) / Double(total)) {
                        if let p = row.project { openProject = p }
                    }
                }
                if rows.isEmpty { Text(period.nothingLine).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overviewCard()
        .sheet(item: $openProject) { project in
            ProjectSheet(project: project, period: period, total: total,
                         tools: (data.projectProviders[project.id] ?? []).map(model.toolName),
                         onShowSessions: { openProject = nil; model.show(project: project.id) },
                         onClose: { openProject = nil })
        }
    }

    private var rows: [Row] {
        let rows: [Row]
        switch tab {
        case .projects:
            rows = data.projects.map { p in
                let tools = (data.projectProviders[p.id] ?? []).map(model.toolName)
                let sessions = OverviewLogic.sessionCount(p.sessions)
                return Row(id: "p\(p.id)", name: p.name, fresh: p.tokens.freshTokens,
                           sub: tools.isEmpty ? sessions : OverviewLogic.list(tools) + " · " + sessions,
                           color: ChartColors.shared.color(for: "project:\(p.id)"), project: p)
            }
        case .models:
            rows = data.models.map { m in
                let tool = model.toolName(m.provider)
                return Row(id: m.id, name: m.displayName, fresh: m.tokens.freshTokens, sub: String(localized: "In \(tool)."),
                    color: ChartColors.shared.color(for: m.canonical))
            }
        case .tools:
            rows = data.products.map { r in
                let name = r.product.map(model.productName) ?? model.toolName(r.provider)
                let sessions = OverviewLogic.sessionCount(r.sessions)
                let cost = Fmt.cost(r.cost)
                return Row(id: r.id, name: name, fresh: r.tokens.freshTokens,
                           sub: showCost ? sessions + " · " + String(localized: "\(cost) at API prices") : sessions,
                           color: model.providerColor(r.provider))
            }
        }
        return Array(rows.filter { $0.fresh > 0 }.sorted { $0.fresh > $1.fresh }.prefix(5))
    }
}

private struct RankRow: View {
    var row: OverviewRanking.Row
    var share: Double
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let clickable = row.project != nil
        let content = HStack(spacing: 12) {
            Circle().fill(row.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Text(row.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    (Text(Fmt.tokens(row.fresh)) + Text(" · \(Int((share * 100).rounded()))%").foregroundColor(.secondary))
                        .font(.system(size: 13, design: .rounded)).monospacedDigit().lineLimit(1)
                }
                ProgressBar(fraction: share, height: 4, fill: row.color).accessibilityHidden(true)
                Text(row.sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if clickable {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(clickable && hovering ? Palette.insetHover : Palette.inset))
        .contentShape(RoundedRectangle(cornerRadius: 8))

        if clickable {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityLabel("\(row.name), \(Fmt.tokens(row.fresh)) new tokens. Show details.")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

/// The details of one project in the period, with the way to its sessions.
private struct ProjectSheet: View {
    var project: ProjectUsageRow
    var period: OverviewPeriod
    var total: Int64
    var tools: [String]
    var onShowSessions: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Project · \(period.title)").font(.caption).foregroundStyle(.secondary)
                Text(project.name).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                fact(String(localized: "New tokens"), Fmt.tokens(project.tokens.freshTokens))
                fact(String(localized: "Share of all"), "\(Int((Double(project.tokens.freshTokens) / Double(max(1, total)) * 100).rounded()))%")
                fact(String(localized: "Sessions"), "\(project.sessions)")
                fact(String(localized: "Last active"), OverviewLogic.lastActive(project.lastActivity, now: Date(), calendar: .current))
            }
            if !tools.isEmpty {
                Text(period.usedWith(OverviewLogic.list(tools))).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Show Sessions", action: onShowSessions).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            figure(value, size: 20).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}
