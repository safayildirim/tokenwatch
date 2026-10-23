import SwiftUI
import AppKit
import UsageCore

/// This is the analytics window, which shows a sidebar of pages and the selected page.
public struct DashboardView: View {
    @Environment(AppModel.self) private var model

    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Usage") {
                    ForEach(DashboardSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            Group {
                switch model.selection {
                case .overview: OverviewPage()
                case .trends: TrendsPage()
                case .sessions: SessionsPage()
                case .projects: ProjectsPage()
                case .models: ModelsPage()
                case .cost: CostPage()
                case .quota: QuotaPage()
                case .intelligence: IntelligencePage()
                case .capacity: CapacityPage()
                case .providers: ProvidersPage()
                case .diagnostics: DiagnosticsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                // The overview and the trends page have their own bar, which adds the period to the same filters.
                if model.selection.followsScope && model.selection != .overview && model.selection != .trends && model.openSessionID == nil {
                    VStack(spacing: 0) { ScopeBar(); Divider() }.background(.bar)
                }
            }
            .navigationTitle(model.selection.title)
        }
        .frame(minWidth: 980, minHeight: 640)
        .toolbar {
            ToolbarItem {
                UpdatedLabel()
            }
            ToolbarItem {
                Button { model.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Check for new usage now (⌘R)").keyboardShortcut("r")
                    .disabled(model.isCheckingNow)
            }
            ToolbarItem {
                Button { openWindow(id: "settings") } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Open Settings (⌘,)")
            }
        }
        .onAppear { DockPresence.windowAppeared() }
        .onDisappear { DockPresence.windowDisappeared() }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            let snap = model.collectorSnapshot
            if snap.isSyncing, let p = snap.progress {
                ProgressView(value: p) { Text("Importing…").font(.caption) }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: snap.sources.contains { $0.state == .failing } ? "xmark.octagon.fill"
                          : (snap.sources.contains { $0.state != .ok } ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                        .foregroundStyle(snap.sources.contains { $0.state != .ok } ? Palette.warning : Palette.good)
                    Text(collectingText(snap)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collectingText(_ snap: CollectorSnapshot) -> String {
        if snap.sources.contains(where: { $0.state != .ok }) { return String(localized: "Collection issue") }
        guard let last = model.latestActivity else { return String(localized: "Collecting") }
        let time = Calendar.current.isDateInToday(last) ? last.formatted(date: .omitted, time: .shortened)
            : last.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Collecting · last file read at \(time)")
    }
}

/// Says how fresh the figures are, or that a refresh the user asked for is still checking.
struct UpdatedLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            Text(text(now: ctx.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func text(now: Date) -> String {
        if model.isCheckingNow { return String(localized: "Checking for new usage…") }
        guard let at = model.lastUpdatedAt else { return "" }
        let age = now.timeIntervalSince(at)
        if age < 60 { return String(localized: "Updated just now") }
        if age < 3600 {
            let minutes = Int(age / 60)
            return String(localized: "Updated \(minutes) min ago")
        }
        let ago = Fmt.relative(at, now: now)
        return String(localized: "Updated \(ago)")
    }
}

/// This view is a scrolling page with consistent padding.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(20)
                .frame(maxWidth: 1400, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Explains why a page is empty and what to do about it.
struct NoDataNotice: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let snap = model.collectorSnapshot
        if !snap.sources.isEmpty, snap.sources.allSatisfy({ $0.state == .notFound }) {
            let folders = snap.sources.map(\.displayName).joined(separator: "; ")
            EmptyState(symbol: "questionmark.folder", title: String(localized: "No supported tool was found"),
                       message: String(localized: "None of the data folders exist yet (\(folders)). Usage appears here automatically once you use one of them."))
        } else if snap.isSyncing {
            EmptyState(symbol: "arrow.down.circle", title: String(localized: "Importing your history"),
                       message: String(localized: "Existing sessions are being read. This page fills in as the import progresses."))
        } else {
            EmptyState(symbol: "tray", title: String(localized: "No usage recorded in this period"),
                       message: String(localized: "Nothing matches the current filters. Widen the date range or clear the filters."))
        }
    }
}
