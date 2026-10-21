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
            Image(systemName: "sparkles")
            if !title.text.isEmpty { Text(title.text).monospacedDigit() }
        }
        .help(title.tooltip)
        .accessibilityLabel("Tokenwatch \(title.text)")
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

/// The popover that opens from the menu bar.
public struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let banner = statusBanner { banner }
            providerSections
            Divider()
            usageSection
            Divider()
            recentSection
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 400)
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
            Text("Tokenwatch").font(.headline)
            Spacer()
            if model.collectorSnapshot.isSyncing {
                ProgressView().controlSize(.small)
                    .help(model.collectorSnapshot.progress.map { String(localized: "Importing history: \(Int($0 * 100))%") } ?? String(localized: "Updating"))
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
                Text("Importing your history…").font(.caption.weight(.medium))
                ProgressView(value: p)
                Text("Totals will keep growing until the import finishes.").font(.caption2).foregroundStyle(.secondary)
            }
        } else if let source = snap.sources.first(where: { $0.state == .failing || $0.state == .degraded }) {
            Label(source.lastError ?? String(localized: "Collection problem in \(source.displayName)"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(Palette.warning)
        }
    }

    /// The providers worth a section: those that have reported a figure, and those whose data folder exists.
    private var shownProviders: [ProviderDefinition] {
        model.providers.filter { provider in
            model.quotaPools.contains { $0.pool.key.provider == provider.id && $0.windows.contains { $0.reading != nil } }
                || (model.collectionState(of: provider.id).map { $0 != .notFound } ?? false)
                || (model.activeByProvider[provider.id] ?? 0) > 0
        }
    }

    @ViewBuilder private var providerSections: some View {
        let shown = shownProviders
        if shown.isEmpty {
            (model.hasLoaded ? Text("No supported tool was found on this Mac. Usage appears here once you use Claude Code or Codex.") : Text("Loading…"))
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(shown, id: \.id) { provider in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(provider.shortName, systemImage: provider.symbol).font(.subheadline.weight(.semibold))
                    Spacer()
                    let active = model.activeByProvider[provider.id] ?? 0
                    Label("\(active) active", systemImage: "bolt.fill")
                        .font(.caption).foregroundStyle(active > 0 ? Palette.good : .secondary)
                }
                let pools = model.quotaPools.filter { $0.pool.key.provider == provider.id }
                // A pool that never reported is listed only when nothing of the provider has, to explain the gap once.
                // Older pools of the same provider (an account no longer in use) stay on the dashboard and out of the popover.
                let reported = currentPools(pools)
                ForEach(reported.isEmpty ? Array(pools.prefix(1)) : reported) { pool in
                    QuotaPoolCard(pool: pool, compact: true, onSetup: openSettings)
                }
                if pools.isEmpty { Text("No quota figure is available for \(provider.shortName).").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    /// The pools of one provider that have data, newest first, without the ones that stopped reporting over a day ago
    /// (unless nothing newer exists).
    private func currentPools(_ pools: [QuotaPoolState]) -> [QuotaPoolState] {
        func newest(_ p: QuotaPoolState) -> Date { p.windows.compactMap { $0.reading?.observedAt }.max() ?? .distantPast }
        let withData = pools.filter { $0.windows.contains { $0.reading != nil } }.sorted { newest($0) > newest($1) }
        return withData.enumerated().filter { $0.offset == 0 || Date().timeIntervalSince(newest($0.element)) < 86_400 }.map(\.element)
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New tokens").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                GridRow {
                    Text("").frame(width: 70, alignment: .leading)
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    Text("This week").font(.caption).foregroundStyle(.secondary)
                    if model.settings.showEstimatedCost { Text("Cost this week").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(model.providerUsage) { row in
                    GridRow {
                        Text(model.providerName(row.provider)).font(.subheadline.weight(.medium))
                        Text(Fmt.tokens(row.today.tokens.freshTokens)).monospacedDigit()
                        Text(Fmt.tokens(row.week.tokens.freshTokens)).monospacedDigit()
                        if model.settings.showEstimatedCost { Text(Fmt.cost(row.week.cost)).monospacedDigit().foregroundStyle(.secondary) }
                    }.font(.subheadline)
                }
            }
            if model.providerUsage.isEmpty { (model.hasLoaded ? Text("No usage recorded yet.") : Text("Loading…")).font(.caption).foregroundStyle(.secondary) }
            Text("Token counts differ between providers and are shown side by side, not added up. Estimated cost is API-equivalent, not a subscription charge.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .help("New tokens exclude cache reads. Each provider counts tokens its own way, so the rows are not comparable like for like.")
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent sessions").font(.caption).foregroundStyle(.secondary)
            if model.recentSessions.isEmpty {
                (model.hasLoaded ? Text("No sessions yet. They appear here automatically.") : Text("Loading…"))
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
    @Environment(AppModel.self) private var model
    var session: SessionRow
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.surfaceSymbol(session.surface)).frame(width: 16).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.projectName).font(.subheadline.weight(.medium)).lineLimit(1)
                    StatusBadge(status: session.status)
                }
                Text("\(model.productName(session.productID)) · \(session.models.first ?? "—")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
