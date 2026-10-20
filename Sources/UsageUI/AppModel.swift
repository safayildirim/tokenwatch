import Foundation
import SwiftUI
import AppKit
import Observation
import ServiceManagement
import UserNotifications
import UsageCore

public enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview, trends, sessions, projects, models, quota, diagnostics
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .trends: "Usage Trends"
        case .sessions: "Sessions"
        case .projects: "Projects"
        case .models: "Models"
        case .quota: "Quota"
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
        case .quota: "hourglass"
        case .diagnostics: "stethoscope"
        }
    }
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
    public let registry: SessionRegistryMonitor
    public let quota: QuotaCoordinator
    @ObservationIgnored private let alerts: AlertEngine

    // MARK: Published state

    public private(set) var settings: AppSettings
    public private(set) var overview = OverviewSnapshot()
    public private(set) var quotaStates: [QuotaWindowState] = []
    public private(set) var quotaSource = QuotaSourceStatus()
    public private(set) var recentSessions: [SessionRow] = []
    public private(set) var latestActivity: Date?
    public private(set) var live: [String: LiveProcess] = [:]
    public private(set) var collectorSnapshot = CollectorSnapshot()
    public private(set) var hasLoaded = false
    public private(set) var lastError: String?
    public private(set) var openReport: DatabaseOpenReport
    /// Increases whenever stored data may have changed, so that open pages know to reload.
    public private(set) var dataVersion = 0

    // MARK: Navigation

    public var selection: DashboardSection = .overview
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

    public init(db: UsageDatabase, adapters: [any SourceAdapter]? = nil, bridgeDirectory: URL = QuotaPaths.bridgeDirectory,
                registryDirectory: URL? = nil, desktopCache: URL = QuotaPaths.desktopPlanUsageCache) {
        self.db = db
        let store = SettingsStore(db: db)
        settingsStore = store
        settings = store.value
        openReport = db.openReport
        analytics = AnalyticsEngine(db: db)
        let resolvedAdapters = adapters ?? [ClaudeCodeAdapter()]
        collector = UsageCollector(db: db, adapters: resolvedAdapters, retentionFloorMs: { store.value.retentionFloorMs },
                                   isSourceEnabled: { !store.value.disabledSources.contains($0) })
        registry = registryDirectory.map { SessionRegistryMonitor(directory: $0, db: db) } ?? SessionRegistryMonitor(db: db)
        quota = QuotaCoordinator(db: db, settings: store, bridgeDirectory: bridgeDirectory, desktopCacheURL: desktopCache)
        alerts = AlertEngine(db: db)
    }

    // MARK: Lifecycle

    /// Starts background collection. Safe to call repeatedly.
    public func start() async {
        guard !started else { return }
        started = true
        await collector.start()
        await registry.start()
        await quota.start()
        if db.openReport.recoveredFromCorruption { await collector.rebuildFromSource() }

        let collectorEvents = await collector.events()
        tasks.append(Task { [weak self] in
            for await _ in collectorEvents { self?.requestRefresh() }
        })
        let registryChanges = await registry.changes()
        tasks.append(Task { [weak self] in
            for await _ in registryChanges { self?.requestRefresh() }
        })
        let quotaChanges = await quota.changes()
        tasks.append(Task { [weak self] in
            for await _ in quotaChanges { self?.requestRefresh() }
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
        await registry.stop()
        await quota.stop()
        db.markCleanShutdown()
    }

    private func systemDidWake() async {
        await collector.systemDidWake()
        await quota.refresh(force: true)
        await registry.rescan()
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
            await registry.rescan()
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
            let wait = Self.minHeavyInterval - Date().timeIntervalSince(lastHeavyReload)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            await reloadHeavy()
            lastHeavyReload = Date()
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
        let liveNow = await registry.liveSessions()
        let now = Date()
        let result = try? await Task.detached(priority: .utility) {
            (try engine.activeSessionCount(now: now, live: liveNow, policy: policy), try engine.latestActivity())
        }.value
        live = liveNow
        overview.activeSessions = result?.0 ?? 0
        latestActivity = result?.1
        quotaStates = await quota.states()
        collectorSnapshot = await collector.snapshot()
    }

    private func reloadHeavy() async {
        let engine = analytics
        let policy = settings.statusPolicy
        let liveNow = live
        let now = Date()
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> (OverviewSnapshot, [SessionRow]) in
                let overview = try engine.overview(now: now, live: liveNow, policy: policy)
                var filter = UsageFilter()
                filter.from = now.addingTimeInterval(-30 * 86_400)
                let rows = try engine.sessionRows(filter, now: now, live: liveNow, policy: policy)
                let recent = rows.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
                return (overview, Array(recent.prefix(40)))
            }.value
            overview = result.0
            recentSessions = result.1
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        quotaSource = await quota.sourceStatus()
    }

    /// Called when a window becomes visible, so that it never shows numbers that were skipped while hidden.
    private func windowBecameVisible() {
        if heavyStale { requestRefresh() }
    }

    // MARK: Alerts

    private func evaluateAlerts() {
        let recentActivity = latestActivity.map { Date().timeIntervalSince($0) < 600 } ?? false
        let notes = alerts.evaluate(states: quotaStates, sources: collectorSnapshot.sources,
                                    recentLocalActivity: recentActivity, settings: settings.notifications)
        guard !notes.isEmpty else { return }
        NotificationDelivery.deliver(notes)
    }

    // MARK: Settings

    public func updateSettings(_ change: (inout AppSettings) -> Void) {
        let before = settings
        settingsStore.update(change)
        settings = settingsStore.value
        if before.notifications.enabled == false, settings.notifications.enabled { NotificationDelivery.requestAuthorization() }
        if before.showDesktopPlanUsageHint != settings.showDesktopPlanUsageHint || before.quotaRefreshSeconds != settings.quotaRefreshSeconds {
            Task { await quota.refresh(force: true) }
        }
        if before.retentionDays != settings.retentionDays { Task { await applyRetention() } }
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

    public func quotaState(_ kind: QuotaWindowKind) -> QuotaWindowState? { quotaStates.first { $0.kind == kind } }

    public var activeSessionCount: Int { overview.activeSessions }

    /// What the menu bar shows. Percentages are always real quota values; when a window has no
    /// authoritative value, a dash is shown instead of a number.
    public var menuBarTitle: MenuBarTitle {
        func part(_ kind: QuotaWindowKind) -> String {
            guard let s = quotaState(kind), s.isDisplayable, let pct = s.utilizationPercent else { return "–" }
            return "\(Int(pct.rounded()))%" + (s.freshness == .stale ? "*" : "")
        }
        let five = part(.fiveHour), week = part(.sevenDay)
        var tip = "Claude usage"
        for kind in [QuotaWindowKind.fiveHour, .sevenDay] {
            if let s = quotaState(kind), let r = s.reading, s.isDisplayable {
                tip += "\n\(kind.displayName): \(Int((s.utilizationPercent ?? 0).rounded()))% used, updated \(Fmt.relative(r.observedAt))"
                    + (s.freshness == .stale ? " (stale)" : "")
            } else {
                tip += "\n\(kind.displayName): unavailable"
            }
        }
        switch settings.menuBarMode {
        case .iconOnly: return MenuBarTitle(text: "", tooltip: tip)
        case .fiveHour: return MenuBarTitle(text: five == "–" ? "" : five, tooltip: tip)
        case .weekly: return MenuBarTitle(text: week == "–" ? "" : week, tooltip: tip)
        case .both: return MenuBarTitle(text: five == "–" && week == "–" ? "" : "\(five) · \(week)", tooltip: tip)
        case .activeSessions:
            return MenuBarTitle(text: activeSessionCount > 0 ? "\(activeSessionCount)" : "", tooltip: tip + "\nActive sessions: \(activeSessionCount)")
        }
    }

    // MARK: Queries for the dashboard

    /// Runs a database query off the main thread.
    public func query<T: Sendable>(_ work: @escaping @Sendable (AnalyticsEngine) throws -> T) async throws -> T {
        let engine = analytics
        return try await Task.detached(priority: .userInitiated) { try work(engine) }.value
    }

    public var policy: StatusPolicy { settings.statusPolicy }

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

/// The app lives in the menu bar and has no Dock icon, except while one of its windows is open, when it
/// behaves like an ordinary app so that the window can take focus and appear in the app switcher.
@MainActor
enum DockPresence {
    static func windowAppeared() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func windowDisappeared() {
        // The window that is closing is already hidden by the time this runs.
        let hasWindow = NSApplication.shared.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !hasWindow { NSApplication.shared.setActivationPolicy(.accessory) }
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

// MARK: - Notifications

enum NotificationDelivery {
    /// Notifications need an app bundle. A bare command line process has none, and asking for the
    /// notification center there would crash.
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func deliver(_ notes: [AlertNotification]) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        for note in notes {
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = note.body
            content.sound = .default
            content.threadIdentifier = note.kind.rawValue
            center.add(UNNotificationRequest(identifier: note.key, content: content, trigger: nil))
        }
    }
}
