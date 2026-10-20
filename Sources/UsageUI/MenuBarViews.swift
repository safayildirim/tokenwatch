import SwiftUI
import AppKit
import UsageCore

/// This is the status item content, which is an icon plus quota percentages when configured and available.
public struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    public init() {}

    public var body: some View {
        let title = model.menuBarTitle
        HStack(spacing: 4) {
            Image(systemName: "sparkle")
            if !title.text.isEmpty { Text(title.text).monospacedDigit() }
        }
        .help(title.tooltip)
        .accessibilityLabel("Claude usage \(title.text)")
        // Opening the app again from Finder or the Applications folder asks for the dashboard, because a
        // menu bar app has no other visible response to that action.
        .onReceive(NotificationCenter.default.publisher(for: .openDashboardRequested)) { _ in
            openWindow(id: "dashboard")
        }
        // The label exists from launch, which makes it the right place to start background collection.
        .task {
            await model.start()
            if model.consumeFirstLaunch() { openWindow(id: "dashboard") }
            // Launch arguments let the app open straight to a window, which is also how the UI is tested.
            let args = CommandLine.arguments
            if args.contains("--show-dashboard") { openWindow(id: "dashboard") }
            if args.contains("--show-settings") { openWindow(id: "settings") }
            if let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count {
                await SnapshotRenderer.run(model: model, directory: URL(fileURLWithPath: args[i + 1]), dark: args.contains("--dark"))
                NSApp.terminate(nil)
            }
            if let i = args.firstIndex(of: "--section"), i + 1 < args.count, let s = DashboardSection(rawValue: args[i + 1]) {
                model.selection = s
            }
        }
    }
}

/// This view shows one quota window as a bar, with the numbers, countdown, freshness and source stated explicitly.
struct QuotaMeter: View {
    var state: QuotaWindowState
    var compact = false
    var onSetup: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.kind.displayName).font(compact ? .subheadline.weight(.medium) : .headline)
                Spacer()
                headline
            }
            bar
            details
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var headline: some View {
        switch state.availability {
        case .available where state.reading != nil:
            let pct = state.reading!.utilizationPercent
            HStack(spacing: 4) {
                if !state.isAuthoritative { Text("unverified").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.secondary.opacity(0.2))) }
                Text("\(Int(pct.rounded()))% used").font(compact ? .subheadline : .title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(state.freshness == .stale ? .secondary : .primary)
            }
        case .windowElapsed:
            Label("Reset", systemImage: "arrow.counterclockwise").font(.subheadline).foregroundStyle(.secondary)
        default:
            Text("Unavailable").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                if let pct = state.utilizationPercent {
                    Capsule()
                        .fill(state.isAuthoritative ? Palette.quota(pct) : Palette.other)
                        .opacity(state.freshness == .stale ? 0.45 : 1)
                        .frame(width: max(4, geo.size.width * min(1, pct / 100)))
                }
            }
        }
        .frame(height: compact ? 6 : 8)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var details: some View {
        switch state.availability {
        case .available:
            if let r = state.reading {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(Int(max(0, 100 - r.utilizationPercent).rounded()))% remaining")
                        Spacer()
                        if let resets = r.resetsAt {
                            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                                Text("Resets in \(Fmt.duration(max(0, resets.timeIntervalSince(ctx.date))))")
                            }
                        } else {
                            Text("Reset time not reported")
                        }
                    }
                    freshnessLine(r)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        case .windowElapsed(let at):
            Text("This window reset \(Fmt.relative(at)). The new value appears after Claude Code next reports it.")
                .font(.caption).foregroundStyle(.secondary)
        case .unavailable:
            HStack {
                Text("No authoritative quota data yet.").font(.caption).foregroundStyle(.secondary)
                if let onSetup { Button("Set up", action: onSetup).controlSize(.mini) }
            }
        }
    }

    private func freshnessLine(_ r: QuotaReading) -> some View {
        HStack(spacing: 4) {
            if state.freshness == .stale {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                Text("Stale: last updated \(Fmt.relative(r.observedAt))")
            } else {
                Text("Updated \(Fmt.relative(r.observedAt))")
            }
            Text("·")
            Text(source(r)).lineLimit(1)
        }
    }

    private func source(_ r: QuotaReading) -> String {
        switch r.provider {
        case StatusLineQuotaSource.providerID: "Claude Code status line"
        case DesktopPlanUsageSource.providerID: "Claude Desktop cache (undocumented)"
        default: r.provider
        }
    }
}

/// The popover that opens from the menu bar.
public struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let banner = statusBanner { banner }
            quotaSection
            Divider()
            activitySection
            Divider()
            recentSection
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 380)
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: "sparkle")
            Text("Claude Usage").font(.headline)
            Spacer()
            if model.collectorSnapshot.isSyncing {
                ProgressView().controlSize(.small)
                    .help(model.collectorSnapshot.progress.map { "Importing history: \(Int($0 * 100))%" } ?? "Updating")
            }
            Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh usage (⌘R)").keyboardShortcut("r")
                .accessibilityLabel("Refresh usage")
        }
    }

    @ViewBuilder private var statusBanner: (some View)? {
        let snap = model.collectorSnapshot
        if snap.isInitialImport, let p = snap.progress {
            VStack(alignment: .leading, spacing: 4) {
                Text("Importing your Claude history…").font(.caption.weight(.medium))
                ProgressView(value: p)
                Text("Totals will keep growing until the import finishes.").font(.caption2).foregroundStyle(.secondary)
            }
        } else if let source = snap.sources.first(where: { $0.state != .ok }) {
            Label(source.state == .notFound ? "Claude Code data folder not found" : (source.lastError ?? "Collection problem"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(Palette.warning)
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.quotaStates.filter { $0.kind != .spendLimit || $0.reading != nil }) { state in
                QuotaMeter(state: state, compact: true, onSetup: openSettings)
            }
        }
    }

    private var activitySection: some View {
        let o = model.overview
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(o.activeSessions) active session\(o.activeSessions == 1 ? "" : "s")", systemImage: "bolt.fill")
                    .foregroundStyle(o.activeSessions > 0 ? Palette.good : .secondary)
                Spacer()
                Text("\(o.totalSessions) total").foregroundStyle(.secondary)
            }
            .font(.subheadline)
            HStack(alignment: .top, spacing: 16) {
                usageColumn("Today", o.today)
                usageColumn("This week", o.thisWeek)
            }
        }
    }

    private func usageColumn(_ title: String, _ t: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(Fmt.tokens(t.tokens.freshTokens)) new").font(.subheadline.weight(.semibold)).monospacedDigit()
            Text("\(Fmt.tokens(t.tokens.totalProcessed)) processed").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if model.settings.showEstimatedCost {
                Text("≈ \(Fmt.cost(t.cost)) API-equivalent").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("New tokens exclude cache reads. Processed tokens include everything the model read and wrote.")
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent sessions").font(.caption).foregroundStyle(.secondary)
            if model.recentSessions.isEmpty {
                Text(model.hasLoaded ? "No sessions yet. Start Claude Code and they appear here automatically." : "Loading…")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(model.recentSessions.prefix(5)) { s in
                Button { open(session: s.id) } label: { SessionMenuRow(session: s) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button { openDashboard() } label: { Label("Open Dashboard", systemImage: "chart.bar.xaxis") }
                .keyboardShortcut("d")
            Spacer()
            Button("Settings…", action: openSettings).keyboardShortcut(",")
            Button("Quit") { Task { await model.shutdown(); NSApp.terminate(nil) } }.keyboardShortcut("q")
        }
        .controlSize(.small)
    }

    // MARK: Actions

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func open(session id: Int64) {
        model.show(session: id)
        openDashboard()
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SessionMenuRow: View {
    var session: SessionRow
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Fmt.applicationSymbol(session.application)).frame(width: 16).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.projectName).font(.subheadline.weight(.medium)).lineLimit(1)
                    StatusBadge(status: session.status)
                }
                Text(session.models.first ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.tokens(session.tokens.totalProcessed)).font(.caption.monospacedDigit())
                Text(Fmt.relative(session.lastActivityAt)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.projectName), \(session.status.label), \(Fmt.tokens(session.tokens.totalProcessed)) tokens")
        .accessibilityHint("Opens session details")
    }
}
