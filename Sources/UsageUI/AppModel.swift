import Foundation
import SwiftUI
import AppKit
import Observation
import ServiceManagement
import UserNotifications
import UsageCore

public enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview, trends, sessions, projects, models, cost, quota, providers, diagnostics
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .trends: "Usage Trends"
        case .sessions: "Sessions"
        case .projects: "Projects"
        case .models: "Models"
        case .cost: "Cost"
        case .quota: "Quota"
        case .providers: "Providers"
        case .diagnostics: "Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .trends: "chart.xyaxis.line"
        case .sessions: "list.bullet.rectangle"
        case .projects: "folder"
        case .models: "cpu"
        case .cost: "dollarsign.circle"
        case .quota: "hourglass"
        case .providers: "square.stack.3d.up"
        case .diagnostics: "stethoscope"
        }
    }
    /// Pages whose figures follow the dashboard scope.
    var followsScope: Bool {
        switch self {
        case .overview, .trends, .sessions, .projects, .models, .cost, .quota: true
        case .providers, .diagnostics: false
        }
    }
}

/// What one provider used today and this week.
public struct ProviderPeriodUsage: Identifiable, Equatable, Sendable {
    public var provider: ProviderID
    public var today: ProviderUsageRow
    public var week: ProviderUsageRow
    public var id: String { provider.rawValue }
}

/// This is the text shown next to the icon in the menu bar.
public struct MenuBarTitle: Equatable {
    public var text: String
    public var tooltip: String
}

/// Owns the services and the state that the menu bar and the dashboard display.
///
/// The model contains no business logic. Collection, accounting, quota evaluation and analytics all
/// live in `UsageCore`, so this layer only wires them together and publishes their latest results.
@MainActor
@Observable
public final class AppModel {
    // MARK: Services

    public let db: UsageDatabase
    public let settingsStore: SettingsStore
    public let analytics: AnalyticsEngine
    public let collector: UsageCollector
    /// Watches the process registry of the one product that keeps one, so that its sessions are known to be live.
    public let liveness: SessionRegistryMonitor
    public let quota: QuotaCoordinator
    @ObservationIgnored private let alerts: AlertEngine

    // MARK: Published state

    public private(set) var settings: AppSettings
    /// Summaries over all providers, for the menu bar and its popover.
    public private(set) var overview = OverviewSnapshot()
    /// Summaries for the dashboard. They equal `overview` unless the scope narrows them.
    public private(set) var scopedOverview = OverviewSnapshot()
    public private(set) var quotaPools: [QuotaPoolState] = []
    public private(set) var quotaStates: [QuotaWindowState] = []
    public private(set) var quotaFeeds: [QuotaFeedStatus] = []
    public private(set) var activeByProvider: [ProviderID: Int] = [:]
    /// Whether Claude Code's settings point at the status line helper that supplies its quota.
    public private(set) var claudeHelperInstalled = false
    public private(set) var filterOptions = AnalyticsEngine.FilterOptions()
    /// Usage of each provider today and this week, for the menu bar popover.
    public private(set) var providerUsage: [ProviderPeriodUsage] = []
    public private(set) var recentSessions: [SessionRow] = []
    public private(set) var latestActivity: Date?
    public private(set) var live: [String: LiveProcess] = [:]
    public private(set) var collectorSnapshot = CollectorSnapshot()
    public private(set) var hasLoaded = false
    /// True when macOS is not showing the menu bar icon, so the app offers a Dock icon instead.
    public private(set) var menuBarIconHidden = false
    public private(set) var lastError: String?
    /// Whether macOS lets the application show notifications, as last checked.
    public private(set) var notificationPermission: NotificationPermission = .notDetermined
    /// Why the last notification could not be shown, or nil when it could.
    public private(set) var notificationProblem: String?
    @ObservationIgnored let notifications: NotificationService
    public private(set) var openReport: DatabaseOpenReport
    /// Increases whenever stored data may have changed, so that open pages know to reload.
    public private(set) var dataVersion = 0

    // MARK: Navigation

    public var selection: DashboardSection = .overview
    /// Which providers, products, accounts and surfaces the dashboard pages show.
    public var scope = DashboardScope() {
        didSet { if scope != oldValue { scope = scope.normalized(registry: db.registry, options: filterOptions); scopeVersion &+= 1; requestRefresh() } }
    }
    /// Increases whenever the scope changes, so that open pages reload.
    public private(set) var scopeVersion = 0
    public var openSessionID: Int64?
    public var sessionsProjectFilter: Int64?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var signalSources: [DispatchSourceSignal] = []

    // MARK: Creation

    public static func bootstrap() throws -> AppModel {
        let db = try UsageDatabase.open(at: QuotaPaths.databaseURL)
        return AppModel(db: db)
    }

    public init(db: UsageDatabase, adapters: [any SourceAdapter]? = nil, quotaFeeds: [any QuotaFeed]? = nil,
                bridgeDirectory: URL = QuotaPaths.bridgeDirectory, registryDirectory: URL? = nil,
                desktopCache: URL = QuotaPaths.desktopPlanUsageCache, notificationSink: (any NotificationSink)? = nil) {
        self.db = db
        notifications = NotificationService(sink: notificationSink ?? SystemNotificationSink())
        let store = SettingsStore(db: db)
        settingsStore = store
        settings = store.value
        openReport = db.openReport
        analytics = AnalyticsEngine(db: db)
        let resolvedAdapters = adapters ?? [ClaudeCodeAdapter(), CodexAdapter()]
        collector = UsageCollector(db: db, adapters: resolvedAdapters, retentionFloorMs: { store.value.retentionFloorMs },
                                   isSourceEnabled: { !store.value.disabledSources.contains($0.rawValue) })
        liveness = registryDirectory.map { SessionRegistryMonitor(directory: $0, db: db) } ?? SessionRegistryMonitor(db: db)
        quota = QuotaCoordinator(db: db, settings: store, feeds: quotaFeeds ?? .claude(bridgeDirectory: bridgeDirectory, desktopCache: desktopCache))
        alerts = AlertEngine(db: db)
    }

    // MARK: Lifecycle

    /// Starts background collection. Safe to call repeatedly.
    public func start() async {
        guard !started else { return }
        started = true
        await collector.start()
        await liveness.start()
        await quota.start()
        if db.openReport.recoveredFromCorruption { await collector.rebuildFromSource() }

        let collectorEvents = await collector.events()
        let collectorEvents2 = await collector.events()
        tasks.append(Task { [weak self] in
            for await _ in collectorEvents { self?.requestRefresh() }
        })
        let registryChanges = await liveness.changes()
        tasks.append(Task { [weak self] in
            for await _ in registryChanges { self?.requestRefresh() }
        })
        let quotaChanges = await quota.changes()
        tasks.append(Task { [weak self] in
            for await _ in quotaChanges { self?.requestRefresh() }
        })
        // Snapshots that arrive with the usage records change the quota state too.
        tasks.append(Task { [weak self] in
            for await event in collectorEvents2 {
                if case .dataChanged = event { await self?.quota.dataDidChange() }
            }
        })

        installTerminationHandlers()

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.systemDidWake() }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windowBecameVisible() }
        })
        for name in [NSNotification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange, .NSCalendarDayChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.requestRefresh() }
            })
        }
        // Data retention runs once a day.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.applyRetention()
                try? await Task.sleep(for: .seconds(24 * 3600), tolerance: .seconds(3600))
            }
        })
        DockPresence.persistent = settings.showDockIcon
        tasks.append(Task { [weak self] in
            // Give macOS time to place the status item, then check periodically, because the menu bar's
            // free space changes as other apps come and go.
            try? await Task.sleep(for: .seconds(3))
            var previousHidden = false
            while !Task.isCancelled {
                if let hidden = StatusItemProbe.isHidden(), let self {
                    // The icon counts as hidden only after two readings in a row, so that a brief
                    // occlusion (a screen waking up, say) does not flip the Dock icon on and off.
                    let confirmedHidden = hidden && previousHidden
                    previousHidden = hidden
                    if (!hidden || confirmedHidden), self.menuBarIconHidden != confirmedHidden {
                        self.menuBarIconHidden = confirmedHidden
                        DockPresence.persistent = self.settings.showDockIcon || confirmedHidden
                    }
                }
                // Check again soon while the icon looks hidden, and rarely once it is visible.
                try? await Task.sleep(for: .seconds(previousHidden ? 5 : 300), tolerance: .seconds(2))
            }
        })
        requestRefresh()
    }

    /// Marks the database as cleanly closed however the app is asked to end: Quit from the menu, the
    /// system quit event at logout or restart, or a termination signal. Without this, the next launch
    /// would run a full integrity check as if the app had crashed.
    private func installTerminationHandlers() {
        let db = self.db
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            db.markCleanShutdown()
        })
        // Signals only matter for the real app. Test processes must not swallow them.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { db.markCleanShutdown(); exit(0) }
            source.resume()
            signalSources.append(source)
        }
    }

    public func shutdown() async {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o); NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        await collector.stop()
        await liveness.stop()
        await quota.stop()
        db.markCleanShutdown()
    }

    private func systemDidWake() async {
        await collector.systemDidWake()
        await quota.refresh(force: true)
        await liveness.rescan()
        requestRefresh()
    }

    private func applyRetention() async {
        guard let floor = settings.retentionFloorMs else { return }
        _ = try? db.purge(olderThanMs: floor)
        requestRefresh()
    }

    // MARK: Refresh

    /// Heavy reloads are spaced at least this far apart, however often data changes.
    private static let minHeavyInterval: TimeInterval = 4
    /// A heavy reload that took a long time is followed by a proportionally long pause, so that the dashboard never keeps
    /// the processor busy for more than about a tenth of the time, however large the history has grown. Left open beside
    /// a streaming session on this Mac's 92,000 requests, a fixed four second spacing used 12 to 38 percent.
    private static let heavyPauseFactor: Double = 8
    @ObservationIgnored private var lastHeavyDuration: TimeInterval = 0

    /// Tests and the snapshot tool set this to force the visible or hidden behaviour.
    @ObservationIgnored public var uiVisibilityOverride: Bool?

    @ObservationIgnored private var heavyStale = true
    @ObservationIgnored private var lastHeavyReload = Date.distantPast

    /// True while any window of this app (the menu bar popover, the dashboard or settings) is showing.
    private var uiIsVisible: Bool {
        if let override = uiVisibilityOverride { return override }
        return NSApplication.shared.windows.contains { $0.isVisible && $0.canBecomeKey }
    }

    /// Asks for the summaries to be recomputed. Bursts of requests are coalesced into one reload.
    public func requestRefresh() {
        refreshRequested = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            // A short pause lets a burst of writes settle before anything is recomputed.
            try? await Task.sleep(for: .milliseconds(700))
            while let self, self.refreshRequested {
                self.refreshRequested = false
                await self.reload()
            }
            self?.refreshTask = nil
        }
    }

    /// User-initiated refresh: re-checks files, quota sources and the registry, then recomputes.
    public func refreshNow() {
        Task {
            await collector.reconcileNow(reason: "manual")
            await quota.refresh(force: true)
            await liveness.rescan()
            heavyStale = true
            requestRefresh()
        }
    }

    /// Every change updates the cheap state (quota, live sessions, collector health), which keeps the
    /// menu bar accurate. The expensive analytics queries run only while a window is showing, and are
    /// spaced out, so an idle monitor stays idle even while a session streams output all day.
    private func reload() async {
        await reloadLight()
        if uiIsVisible {
            let spacing = max(Self.minHeavyInterval, lastHeavyDuration * Self.heavyPauseFactor)
            let wait = spacing - Date().timeIntervalSince(lastHeavyReload)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let started = Date()
            await reloadHeavy()
            lastHeavyReload = Date()
            lastHeavyDuration = lastHeavyReload.timeIntervalSince(started)
            heavyStale = false
        } else {
            heavyStale = true
        }
        hasLoaded = true
        dataVersion &+= 1
        evaluateAlerts()
    }

    private func reloadLight() async {
        let engine = analytics
        let policy = settings.statusPolicy
        let liveNow = await liveness.liveSessions()
        let liveProvider = db.registry.providerOf(product: liveness.product)
        let now = Date()
        let result = try? await Task.detached(priority: .utility) {
            (try engine.activeSessionCounts(now: now, live: liveNow, liveProvider: liveProvider, policy: policy), try engine.latestActivity())
        }.value
        live = liveNow
        activeByProvider = result?.0 ?? [:]
        overview.activeSessions = activeByProvider.values.reduce(0, +)
        latestActivity = result?.1
        quotaPools = await quota.pools()
        quotaStates = quotaPools.flatMap(\.windows)
        collectorSnapshot = await collector.snapshot()
    }

    private func reloadHeavy() async {
        let engine = analytics
        let policy = settings.statusPolicy
        let liveNow = live
        let now = Date()
        let scopeFilter = scope.usageFilter
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> (OverviewSnapshot, OverviewSnapshot, [SessionRow], AnalyticsEngine.FilterOptions, [ProviderPeriodUsage]) in
                let overview = try engine.overview(now: now, live: liveNow, policy: policy)
                let calendar = Calendar.current
                let dayStart = calendar.startOfDay(for: now)
                let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
                let today = Dictionary(uniqueKeysWithValues: try engine.providers(UsageFilter(from: dayStart)).map { ($0.provider, $0) })
                let week = try engine.providers(UsageFilter(from: weekStart))
                let usage = week.map { row in
                    ProviderPeriodUsage(provider: row.provider,
                                        today: today[row.provider] ?? ProviderUsageRow(provider: row.provider, product: nil, tokens: .zero, requests: 0, sessions: 0, cost: .zero, coverage: UsageCoverage(), lastActivity: nil),
                                        week: row)
                }
                let scoped = scopeFilter == UsageFilter() ? overview : try engine.overview(now: now, live: liveNow, policy: policy, scope: scopeFilter)
                var filter = UsageFilter()
                filter.from = now.addingTimeInterval(-30 * 86_400)
                let rows = try engine.sessionRows(filter, now: now, live: liveNow, policy: policy)
                let recent = rows.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
                return (overview, scoped, Array(recent.prefix(40)), try engine.filterOptions(), usage)
            }.value
            overview = result.0
            overview.activeSessions = activeByProvider.values.reduce(0, +)
            scopedOverview = result.1
            scopedOverview.activeSessions = scope.isActive ? result.1.activeSessions : overview.activeSessions
            recentSessions = result.2
            filterOptions = result.3
            providerUsage = result.4
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        quotaFeeds = await quota.feedStatus()
        claudeHelperInstalled = StatusLineInstaller.inspect().isInstalled
    }

    /// Called when a window becomes visible, so that it never shows numbers that were skipped while hidden.
    private func windowBecameVisible() {
        if heavyStale { requestRefresh() }
    }

    // MARK: Alerts

    private func evaluateAlerts() {
        let active = (try? analytics.activeProviders(since: Date().addingTimeInterval(-600))) ?? []
        let notes = alerts.evaluate(states: quotaStates, sources: collectorSnapshot.sources,
                                    activeProviders: active, settings: settings.notifications)
        guard !notes.isEmpty else { return }
        Task { [weak self, notifications] in
            let report = await notifications.deliver(notes)
            await MainActor.run { self?.notificationProblem = report.problem }
        }
    }

    // MARK: Settings

    public func updateSettings(_ change: (inout AppSettings) -> Void) {
        let before = settings
        settingsStore.update(change)
        settings = settingsStore.value
        if before.notifications.enabled == false, settings.notifications.enabled {
            Task { [weak self, notifications] in
                let permission = await notifications.requestPermission()
                await MainActor.run { self?.notificationPermission = permission }
            }
        }
        if before.showUnverifiedQuota != settings.showUnverifiedQuota || before.quotaRefreshSeconds != settings.quotaRefreshSeconds {
            Task { await quota.refresh(force: true) }
        }
        if before.retentionDays != settings.retentionDays { Task { await applyRetention() } }
        if before.showDockIcon != settings.showDockIcon { DockPresence.persistent = settings.showDockIcon || menuBarIconHidden }
        if before.disabledSources != settings.disabledSources { Task { await collector.reconcileNow(reason: "sources-changed") } }
        requestRefresh()
    }

    public func rebuildFromSource() { Task { await collector.rebuildFromSource() } }

    public func eraseAllData() {
        Task {
            try? db.eraseAllData()
            await collector.rebuildFromSource()
            requestRefresh()
        }
    }

    /// Returns true exactly once, on the first launch ever, so that a new user sees the dashboard
    /// instead of an app that appears to do nothing.
    public func consumeFirstLaunch() -> Bool {
        guard !CommandLine.arguments.contains("--snapshots"), db.setting("first_launch_shown") == nil else { return false }
        try? db.setSetting("first_launch_shown", "1")
        return true
    }

    // MARK: Derived values

    public var providers: [ProviderDefinition] { db.registry.providers }

    /// Applies the dashboard scope to a filter that a page built from its own controls.
    public func scoped(_ filter: UsageFilter) -> UsageFilter {
        var f = filter
        scope.apply(to: &f)
        return f
    }

    /// The pools that belong to the current scope: the provider and account must match, and when products are chosen
    /// the pool must serve at least one of them.
    public var scopedPools: [QuotaPoolState] {
        quotaPools.filter { state in
            (scope.providers.isEmpty || scope.providers.contains(state.pool.key.provider))
                && (scope.accounts.isEmpty || scope.accounts.contains(state.pool.key.accountID))
                && (scope.products.isEmpty || !scope.products.isDisjoint(with: state.pool.products))
        }
    }

    public var activeSessionCount: Int { overview.activeSessions }

    /// The pool whose figures stand for a provider in the menu bar: among the provider's pools that have a
    /// displayable window, the one that reported most recently.
    func primaryPool(of provider: ProviderID) -> QuotaPoolState? {
        quotaPools.filter { $0.pool.key.provider == provider && $0.windows.contains { $0.isDisplayable } }
            .max { ($0.windows.compactMap { $0.reading?.observedAt }.max() ?? .distantPast) < ($1.windows.compactMap { $0.reading?.observedAt }.max() ?? .distantPast) }
    }

    private static func percentText(_ w: QuotaWindowState) -> String {
        "\(Int((w.utilizationPercent ?? 0).rounded()))%" + (w.freshness == .stale ? "*" : "")
    }

    /// The figures of a pool for the menu bar: its shortest and its longest window. A window that has no current value,
    /// such as one that has just reset, shows a dash in its own place. Showing the other window's figure there would
    /// pass a weekly percentage off as a five-hour one.
    private func figures(of pool: QuotaPoolState, onlyShortest: Bool = false) -> String? {
        guard pool.windows.contains(where: \.isDisplayable), let first = pool.windows.first, let last = pool.windows.last else { return nil }
        func text(_ w: QuotaWindowState) -> String { w.isDisplayable ? Self.percentText(w) : "–" }
        if onlyShortest || pool.windows.count == 1 { return text(first) }
        return text(first) + " · " + text(last)
    }

    /// One line per displayable window, grouped by provider, for the menu bar tooltip.
    private var quotaTooltip: String {
        var lines = ["AI usage"]
        for provider in providers {
            let pools = quotaPools.filter { $0.pool.key.provider == provider.id }
            guard !pools.isEmpty else { continue }
            lines.append(provider.shortName)
            for pool in pools {
                let account = pool.pool.accountLabel == "Unassigned" ? "" : " (\(pool.pool.accountLabel))"
                let shown = pool.windows.filter { $0.reading != nil }
                if shown.isEmpty { lines.append("  \(pool.pool.name)\(account): no data yet"); continue }
                for w in shown {
                    if w.isDisplayable, let r = w.reading {
                        lines.append("  \(pool.pool.name)\(account), \(w.displayName.lowercased()): \(Int((w.utilizationPercent ?? 0).rounded()))% used, updated \(Fmt.relative(r.observedAt))" + (w.freshness == .stale ? " (stale)" : ""))
                    } else {
                        lines.append("  \(pool.pool.name)\(account), \(w.displayName.lowercased()): unavailable")
                    }
                }
            }
        }
        if lines.count == 1 { lines.append("No quota figures reported yet") }
        return lines.joined(separator: "\n")
    }

    /// What the menu bar shows. Percentages are always real quota values reported by a provider; when no value is
    /// available, nothing is shown in place of a number. The figures of different pools are compared or listed side by
    /// side, and never added.
    public var menuBarTitle: MenuBarTitle {
        let tip = quotaTooltip
        switch settings.menuBarMode {
        case .iconOnly:
            return MenuBarTitle(text: "", tooltip: tip)
        case .quota(let provider):
            let text = primaryPool(of: provider).flatMap { figures(of: $0) } ?? ""
            return MenuBarTitle(text: text, tooltip: tip)
        case .allProviders:
            let parts: [String] = providers.compactMap { provider in
                guard let pool = primaryPool(of: provider.id), let text = figures(of: pool, onlyShortest: true) else { return nil }
                return "\(provider.shortName.prefix(1).uppercased()) \(text)"
            }
            return MenuBarTitle(text: parts.joined(separator: " · "), tooltip: tip)
        case .highestUtilization:
            let shown = quotaStates.filter(\.isDisplayable)
            guard let top = shown.max(by: { ($0.utilizationPercent ?? 0) < ($1.utilizationPercent ?? 0) }) else { return MenuBarTitle(text: "", tooltip: tip) }
            let name = providers.first { $0.id == top.pool.key.provider }?.shortName ?? top.pool.key.provider.rawValue
            return MenuBarTitle(text: Self.percentText(top),
                                tooltip: tip + "\nHighest: \(name), \(top.pool.name), \(top.displayName.lowercased())")
        case .activeSessions:
            let lines = providers.compactMap { p in activeByProvider[p.id].map { "  \(p.shortName): \($0)" } }
            return MenuBarTitle(text: activeSessionCount > 0 ? "\(activeSessionCount)" : "",
                                tooltip: tip + "\nActive sessions: \(activeSessionCount)" + (lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")))
        }
    }

    // MARK: Queries for the dashboard

    /// Runs a database query off the main thread.
    public func query<T: Sendable>(_ work: @escaping @Sendable (AnalyticsEngine) throws -> T) async throws -> T {
        let engine = analytics
        return try await Task.detached(priority: .userInitiated) { try work(engine) }.value
    }

    public var policy: StatusPolicy { settings.statusPolicy }

    // MARK: Notifications

    /// Looks up whether macOS lets the application show notifications.
    public func refreshNotificationPermission() async {
        notificationPermission = await notifications.permission()
    }

    /// Shows a notification that has nothing to do with any quota, and records what happened to it.
    public func sendTestNotification() async {
        let report = await notifications.sendTest()
        notificationProblem = report.problem
        notificationPermission = await notifications.permission()
    }

    // MARK: Navigation helpers

    public func show(session id: Int64) {
        selection = .sessions
        openSessionID = id
    }

    public func show(project id: Int64) {
        sessionsProjectFilter = id
        openSessionID = nil
        selection = .sessions
    }
}

// MARK: - Launch at login

@MainActor
public enum LoginItem {
    public static var status: SMAppService.Status { SMAppService.mainApp.status }
    public static var isEnabled: Bool { status == .enabled }

    public static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    public static var statusDescription: String {
        switch status {
        case .enabled: "Enabled"
        case .notRegistered, .notFound: "Not enabled"
        case .requiresApproval: "Waiting for approval in System Settings > General > Login Items"
        @unknown default: "Unknown"
        }
    }
}

// MARK: - Opening from Finder

public extension Notification.Name {
    /// Posted when the user opens the app again while it is already running.
    static let openDashboardRequested = Notification.Name("dev.claudeusage.monitor.openDashboardRequested")
}

/// Turns the system's "reopen" request into a request to show the dashboard.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openDashboardRequested, object: nil)
        return true
    }
}

// MARK: - Dock presence

/// The app lives in the menu bar and has no Dock icon, except in two situations. While one of its windows
/// is open it behaves like an ordinary app, so that the window can take focus. It also keeps a Dock icon
/// when the user asks for one, or when macOS has hidden its menu bar icon (which happens when the menu
/// bar is full and the new item lands under the notch), because the app would otherwise be unreachable.
@MainActor
enum DockPresence {
    /// True when the Dock icon should stay regardless of windows.
    static var persistent = false {
        didSet { if persistent != oldValue { apply() } }
    }

    static func windowAppeared() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func windowDisappeared() { apply() }

    /// Chooses the activation policy from the current windows and the persistent flag.
    static func apply() {
        // The window that is closing is already hidden by the time this runs.
        let hasWindow = NSApplication.shared.windows.contains { $0.isVisible && $0.canBecomeMain }
        NSApplication.shared.setActivationPolicy(persistent || hasWindow ? .regular : .accessory)
    }
}

/// Works out whether macOS is actually showing the app's menu bar icon.
@MainActor
enum StatusItemProbe {
    /// Returns nil when the status item window does not exist yet, true when it exists but no part of it is
    /// visible (for example because it sits under the notch), and false when it is visible.
    static func isHidden() -> Bool? {
        let windows = NSApplication.shared.windows.filter { NSStringFromClass(type(of: $0)).contains("StatusBar") }
        guard !windows.isEmpty else { return nil }
        return windows.allSatisfy { !$0.occlusionState.contains(.visible) }
    }
}

// MARK: - Command line actions

/// Small headless actions that the app binary can perform before any interface starts. They make the
/// launch-at-login mechanism checkable from a terminal or a script.
@MainActor
public enum CommandLineActions {
    /// Handles `--login-item status|enable|disable`. Returns true if the process should exit.
    public static func handle(_ args: [String] = CommandLine.arguments) -> Bool {
        guard let i = args.firstIndex(of: "--login-item"), i + 1 < args.count else { return false }
        switch args[i + 1] {
        case "enable": do { try LoginItem.set(true) } catch { print("error: \(error.localizedDescription)") }
        case "disable": do { try LoginItem.set(false) } catch { print("error: \(error.localizedDescription)") }
        default: break
        }
        print("login item: \(LoginItem.statusDescription)")
        return true
    }
}
