import SwiftUI
import Charts
import UsageCore

/// This page shows everything about one session: token breakdown, models, request timeline, cache efficiency,
/// sub-agents, cost, and how it sits inside the quota windows it overlapped.
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    var sessionID: Int64
    var onBack: () -> Void

    @State private var detail: SessionDetail?
    @State private var loaded = false
    @State private var includeCacheReads = false
    @State private var selected: Date?

    var body: some View {
        PageScroll {
            Button { onBack() } label: { Label("All sessions", systemImage: "chevron.left") }
                .buttonStyle(.link).keyboardShortcut(.escape, modifiers: [])
            if let d = detail {
                header(d.row)
                kpis(d.row)
                breakdown(d.row.tokens)
                HStack(alignment: .top, spacing: 12) {
                    modelsCard(d)
                    agentsCard(d)
                }
                timelineCard(d)
                cacheCard(d)
                windowsCard(d)
            } else if loaded {
                EmptyState(symbol: "questionmark.folder", title: "Session not found",
                           message: "This session is no longer in the database, for example because of the retention setting.")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .task(id: "\(sessionID)|\(model.dataVersion)") { await load() }
    }

    // MARK: Sections

    private func header(_ r: SessionRow) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.projectName).font(.title2.weight(.semibold))
                    StatusBadge(status: r.status)
                    Spacer()
                    Button("Show project sessions") { if let p = r.projectID { model.show(project: p) } }.disabled(r.projectID == nil)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.externalID, forType: .string) } label: {
                        Label("Copy ID", systemImage: "doc.on.doc")
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 3) {
                    GridRow { Text("Session").foregroundStyle(.secondary); Text(r.externalID).monospaced().textSelection(.enabled) }
                    GridRow { Text("Product").foregroundStyle(.secondary); HStack { Text(model.productName(r.productID)); ProviderChip(provider: r.provider) } }
                    GridRow { Text("Where it ran").foregroundStyle(.secondary); Label(model.surfaceName(r.surface), systemImage: model.surfaceSymbol(r.surface)) }
                    GridRow { Text("Account").foregroundStyle(.secondary); Text(r.accountLabel == "Unassigned" ? "Not identified by the source" : r.accountLabel) }
                    if r.kind != .main { GridRow { Text("Kind").foregroundStyle(.secondary); Text(r.kind == .review ? "Automatic review thread" : "Started by another session") } }
                    GridRow { Text("Started").foregroundStyle(.secondary); Text(Fmt.dateTime(r.startedAt)) }
                    GridRow { Text("Last activity").foregroundStyle(.secondary); Text("\(Fmt.dateTime(r.lastActivityAt)) (\(Fmt.relative(r.lastActivityAt)))") }
                    GridRow { Text("Duration").foregroundStyle(.secondary); Text(r.duration.map(Fmt.duration) ?? "—") }
                    if let cwd = r.cwd { GridRow { Text("Folder").foregroundStyle(.secondary); Text(cwd).textSelection(.enabled).lineLimit(1).truncationMode(.middle) } }
                    if let v = r.clientVersion { GridRow { Text("Version").foregroundStyle(.secondary); Text(v) } }
                }
                .font(.callout)
                if r.status.basis == .inferred {
                    Text("Status is inferred from how recently this session wrote to its log. It is not confirmed by a running process.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func kpis(_ r: SessionRow) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            KPITile(title: "Requests", value: Fmt.grouped(Int64(r.requests)), detail: r.agentRequests > 0 ? "\(r.agentRequests) by sub-agents" : nil)
            KPITile(title: "Processed tokens", value: Fmt.tokens(r.tokens.totalProcessed), detail: "\(Fmt.tokens(r.tokens.freshTokens)) new")
            KPITile(title: "Cache hit ratio", value: Fmt.ratio(r.tokens.cacheHitRatio), detail: "cache read ÷ all input")
            KPITile(title: "Output ÷ input", value: r.tokens.outputToInputRatio.map { String(format: "%.2f%%", $0 * 100) } ?? "—", detail: "output ÷ all input")
            if model.settings.showEstimatedCost {
                KPITile(title: "API-equivalent cost", value: Fmt.cost(r.cost), detail: "estimate from list prices")
                if let reported = r.reportedCostUSD {
                    KPITile(title: "The tool's own estimate", value: String(format: "$%.2f", reported),
                            detail: "recorded by \(model.productName(r.productID)), kept separate",
                            help: "Some tools write their own cost summary into the session. It is shown next to, never mixed with, the estimate above.")
                }
            }
        }
    }

    private func breakdown(_ t: TokenCounts) -> some View {
        Card("Token breakdown", subtitle: "Exact counts for each category, with the derived totals defined below.") {
            VStack(alignment: .leading, spacing: 12) {
                TokenCompositionBar(tokens: t, includeCacheReads: true)
                Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 4) {
                    row("Uncached input", t.uncachedInput, "Input that was neither read from nor written to the cache")
                    row("Cache read", t.cacheRead, "Input served from the prompt cache")
                    row("Cache creation", t.cacheCreation, "Input written to the prompt cache")
                    if t.cacheCreation5m + t.cacheCreation1h > 0 {
                        row("   of which 5-minute", t.cacheCreation5m, nil)
                        row("   of which 1-hour", t.cacheCreation1h, nil)
                        if t.cacheCreationUnsplit > 0 { row("   lifetime not stated", t.cacheCreationUnsplit, nil) }
                    }
                    Divider()
                    row("Total logical input", t.logicalInput, "Uncached input + cache read + cache creation")
                    row("Output", t.output, "Tokens generated by the model")
                    Divider()
                    row("Total processed", t.totalProcessed, "Logical input + output")
                }
            }
        }
    }

    private func row(_ name: String, _ value: Int64, _ help: String?) -> some View {
        GridRow {
            Text(name).gridColumnAlignment(.leading).help(help ?? "")
            Text(Fmt.grouped(value)).monospacedDigit()
        }.font(.callout)
    }

    private func modelsCard(_ d: SessionDetail) -> some View {
        Card("Models", subtitle: "Share of processed tokens") {
            if d.byModel.isEmpty { Text("—").foregroundStyle(.secondary) }
            ForEach(d.byModel) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Circle().fill(ChartColors.shared.color(for: m.canonical)).frame(width: 8, height: 8)
                        Text(m.displayName).font(.callout.weight(.medium))
                        Spacer()
                        Text(Fmt.ratio(m.tokenShare)).font(.callout.monospacedDigit())
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.track)
                            Capsule().fill(ChartColors.shared.color(for: m.canonical)).frame(width: max(4, geo.size.width * m.tokenShare))
                        }
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                    Text("\(m.requests) requests · \(Fmt.tokens(m.tokens.output)) output · \(Fmt.tokens(m.tokens.totalProcessed)) processed"
                         + (model.settings.showEstimatedCost ? " · \(Fmt.cost(m.cost))" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func agentsCard(_ d: SessionDetail) -> some View {
        let children = d.agents.filter { $0.key != nil }
        let childTotal = children.reduce(TokenCounts()) { $0 + $1.tokens }
        return Card("Agents", subtitle: children.isEmpty ? "This session did not start any sub-agents." : "Sub-agent usage is part of the session total; it is counted once.") {
            ForEach(d.agents) { a in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: a.key == nil ? "person.fill" : "arrow.turn.down.right").foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.key == nil ? "Main conversation" : "Agent \(String(a.key!.prefix(8)))").font(.callout.weight(.medium))
                        Text("\(a.requests) requests · \(a.topModel)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.tokens(a.tokens.totalProcessed)).font(.callout.monospacedDigit())
                }
            }
            if !children.isEmpty {
                Divider()
                HStack {
                    Text("Child agents combined (\(children.count))").font(.callout.weight(.medium))
                    Spacer()
                    Text("\(Fmt.tokens(childTotal.totalProcessed)) processed · \(Fmt.tokens(childTotal.freshTokens)) new").font(.callout.monospacedDigit())
                }
            }
        }
    }

    private func timelineCard(_ d: SessionDetail) -> some View {
        let points = d.timeline
        return Card("Request timeline",
                    subtitle: d.timelineIsBucketed ? "This session has many requests, so they are grouped into time buckets." : "One bar per model request.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 14) {
                        LegendDot(color: Palette.uncachedInput, label: "Uncached input")
                        LegendDot(color: Palette.output, label: "Output")
                        LegendDot(color: Palette.cacheWrite, label: "Cache write")
                        if includeCacheReads { LegendDot(color: Palette.cacheRead, label: "Cache read") }
                    }
                    Spacer()
                    Toggle("Include cache reads", isOn: $includeCacheReads).toggleStyle(.switch).controlSize(.small)
                }
                if points.isEmpty { Text("No requests.").foregroundStyle(.secondary) }
                else {
                    let nearest = selected.flatMap { s in points.min { abs($0.time.timeIntervalSince(s)) < abs($1.time.timeIntervalSince(s)) } }
                    Chart {
                        ForEach(points) { p in
                            BarMark(x: .value("Time", p.time), y: .value("Tokens", p.tokens.uncachedInput)).foregroundStyle(by: .value("Category", "Uncached input"))
                            BarMark(x: .value("Time", p.time), y: .value("Tokens", p.tokens.output)).foregroundStyle(by: .value("Category", "Output"))
                            BarMark(x: .value("Time", p.time), y: .value("Tokens", p.tokens.cacheCreation)).foregroundStyle(by: .value("Category", "Cache write"))
                            if includeCacheReads {
                                BarMark(x: .value("Time", p.time), y: .value("Tokens", p.tokens.cacheRead)).foregroundStyle(by: .value("Category", "Cache read"))
                            }
                        }
                        if let n = nearest {
                            RuleMark(x: .value("Selected", n.time)).foregroundStyle(Color.secondary.opacity(0.5))
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(n.time.formatted(date: .abbreviated, time: .standard)).font(.caption.weight(.semibold))
                                        Text("\(n.modelName)\(n.isChildAgent ? " · sub-agent" : "")\(n.requests > 1 ? " · \(n.requests) requests" : "")").font(.caption2)
                                        Text("in \(Fmt.grouped(n.tokens.uncachedInput)) · out \(Fmt.grouped(n.tokens.output))").font(.caption2).monospacedDigit()
                                        Text("cache read \(Fmt.grouped(n.tokens.cacheRead)) · write \(Fmt.grouped(n.tokens.cacheCreation))").font(.caption2).monospacedDigit()
                                    }
                                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                                }
                        }
                    }
                    .chartForegroundStyleScale(["Uncached input": Palette.uncachedInput, "Output": Palette.output,
                                                "Cache write": Palette.cacheWrite, "Cache read": Palette.cacheRead])
                    .chartLegend(.hidden)
                    .chartXSelection(value: $selected)
                    .chartYAxis { AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(Palette.gridLine)
                        AxisValueLabel { if let n = v.as(Int64.self) { Text(Fmt.tokens(n)) } }
                    } }
                    .frame(height: 230)
                }
            }
        }
    }

    private func cacheCard(_ d: SessionDetail) -> some View {
        let points = d.timeline.filter { $0.tokens.logicalInput > 0 }
        return Card("Cache efficiency", subtitle: "Share of each request's input that came from the prompt cache. Overall: \(Fmt.ratio(d.row.tokens.cacheHitRatio)).") {
            if points.count < 2 { Text("Not enough requests to chart.").foregroundStyle(.secondary) }
            else {
                Chart(points) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Cache hit", (p.tokens.cacheHitRatio ?? 0) * 100))
                        .foregroundStyle(Palette.cacheRead).lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine().foregroundStyle(Palette.gridLine)
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%") } }
                } }
                .frame(height: 140)
            }
        }
    }

    private func windowsCard(_ d: SessionDetail) -> some View {
        Card("Quota window context",
             subtitle: "Which windows of this account's allowance this session overlapped. Shares below describe locally observed activity only.") {
            if d.windows.isEmpty {
                Text("No authoritative quota history covers this session.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(d.windows) { w in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(WindowNaming.displayName(minutes: w.windowMinutes, fallbackKey: w.windowKey)) window ending \(Fmt.dateTime(w.windowEnd))").font(.callout.weight(.medium))
                    HStack(spacing: 18) {
                        if let peak = w.reportedPeakUtilization {
                            Label("Account reached \(Int(peak.rounded()))% (reported by \(model.providerName(d.row.provider)))", systemImage: "checkmark.seal")
                        }
                        if let share = w.shareOfObservedFreshTokens {
                            Label("\(Fmt.ratio(share)) of the new tokens observed on this Mac in that window", systemImage: "chart.pie")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
            if !d.windows.isEmpty {
                Text("A session's share of observed tokens is not the share of your allowance it used. Usage from other devices and apps also counts toward the account figure, and a provider's metering is not a simple token count.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Loading

    private func load() async {
        let id = sessionID
        let policy = model.policy
        let live = model.live
        detail = try? await model.query { try $0.sessionDetail(id: id, now: Date(), live: live, policy: policy) }
        loaded = true
    }
}
