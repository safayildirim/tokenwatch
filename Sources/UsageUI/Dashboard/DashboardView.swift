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
            List(DashboardSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
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
                case .providers: ProvidersPage()
                case .diagnostics: DiagnosticsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.selection.followsScope && model.openSessionID == nil {
                    VStack(spacing: 0) { ScopeBar(); Divider() }.background(.bar)
                }
            }
            .navigationTitle(model.selection.title)
        }
        .frame(minWidth: 980, minHeight: 640)
        .toolbar {
            ToolbarItem {
                Button { openWindow(id: "settings") } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Open Settings (⌘,)")
            }
            ToolbarItem {
                Button { model.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Check for new usage now").keyboardShortcut("r")
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
                HStack(spacing: 5) {
                    Image(systemName: snap.sources.contains { $0.state == .failing } ? "xmark.octagon.fill"
                          : (snap.sources.contains { $0.state != .ok } ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                        .foregroundStyle(snap.sources.contains { $0.state != .ok } ? Palette.warning : Palette.good)
                    Text(snap.sources.contains { $0.state != .ok } ? "Collection issue" : "Collecting").font(.caption)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            EmptyState(symbol: "questionmark.folder", title: "No supported tool was found",
                       message: "None of the data folders exist yet (" + snap.sources.map(\.displayName).joined(separator: "; ") + "). Usage appears here automatically once you use one of them.")
        } else if snap.isSyncing {
            EmptyState(symbol: "arrow.down.circle", title: "Importing your history",
                       message: "Existing sessions are being read. This page fills in as the import progresses.")
        } else {
            EmptyState(symbol: "tray", title: "No usage recorded in this period",
                       message: "Nothing matches the current filters. Widen the date range or clear the filters.")
        }
    }
}
