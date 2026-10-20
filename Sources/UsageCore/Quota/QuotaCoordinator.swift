import Foundation

/// Diagnostic information about how quota data is arriving.
public struct QuotaSourceStatus: Sendable, Equatable {
    public var bridgeDirectoryExists = false
    public var bridgeFileCount = 0
    public var newestBridgeObservation: Date?
    public var bridgeInstalledInClaudeSettings = false
    public var lastRefresh: Date?
    public init() {}
}

/// Combines the quota sources, remembers what they report, and tells the rest of the app when a
/// window's state changes.
///
/// The only authoritative source is the documented `rate_limits` field that Claude Code passes to
/// its status line command, collected by the bridge. No usage percentage is ever computed from token
/// counts: when no source has reported a window, that window is shown as unavailable.
///
/// The coordinator does no polling of its own for new data. It reacts to file events from the
/// bridge directory, and sleeps until the next moment at which a state could change by itself (a
/// window reset or a reading going stale). A slow safety-net refresh, configurable within safe
/// limits, covers a missed file event.
public actor QuotaCoordinator {
    private let db: UsageDatabase
    private let settings: SettingsStore
    private let bridgeDirectory: URL
    private let desktopCacheURL: URL
    private let freshnessPolicy: QuotaFreshnessPolicy
    private let clock: @Sendable () -> Date

    private var readings: [QuotaReading] = []
    private var lastPersisted: [String: (percent: Double, resetsAt: Date?, at: Date)] = [:]
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var watcher: FSEventsWatcher?
    private var tasks: [Task<Void, Never>] = []
    private var timerTask: Task<Void, Never>?
    private var lastRefresh: Date?
    private var lastRefreshAttempt = Date.distantPast
    private var trailingRefresh: Task<Void, Never>?

    /// Refreshes closer together than this are coalesced, which keeps a burst of file events (one per
    /// status line render) from causing a burst of reads.
    private let minimumRefreshGap: TimeInterval = 1.0

    public init(db: UsageDatabase, settings: SettingsStore,
                bridgeDirectory: URL = QuotaPaths.bridgeDirectory,
                desktopCacheURL: URL = QuotaPaths.desktopPlanUsageCache,
                freshnessPolicy: QuotaFreshnessPolicy = QuotaFreshnessPolicy(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.settings = settings
        self.bridgeDirectory = bridgeDirectory
        self.desktopCacheURL = desktopCacheURL
        self.freshnessPolicy = freshnessPolicy
        self.clock = clock
    }

    // MARK: Lifecycle

    public func start() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let w = FSEventsWatcher(roots: [bridgeDirectory], latency: 0.3)
        watcher = w
        w.start()
        tasks.append(Task { [weak self] in
            for await _ in w.events { await self?.refresh() }
        })
        refresh(force: true)
    }

    public func stop() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        timerTask?.cancel()
        watcher?.stop()
        watcher = nil
        for c in subscribers.values { c.finish() }
        subscribers.removeAll()
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
            subscribers[id] = c
            c.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    // MARK: State

    /// The current state of every window that has ever been reported, plus the two standard
    /// windows, which are always listed so that the interface can explain why they are missing.
    public func states(now: Date? = nil) -> [QuotaWindowState] {
        let now = now ?? clock()
        let allowUnverified = settings.value.showDesktopPlanUsageHint
        var kinds: [QuotaWindowKind] = [.fiveHour, .sevenDay]
        if readings.contains(where: { $0.kind == .spendLimit }) { kinds.append(.spendLimit) }
        return kinds.map { QuotaEvaluator.evaluate(kind: $0, readings: readings, now: now,
                                                   allowUnverified: allowUnverified, policy: freshnessPolicy) }
    }

    public func sourceStatus(inspectSettings: Bool = true) -> QuotaSourceStatus {
        var s = QuotaSourceStatus()
        var isDir: ObjCBool = false
        s.bridgeDirectoryExists = FileManager.default.fileExists(atPath: bridgeDirectory.path, isDirectory: &isDir) && isDir.boolValue
        let bridgeReadings = readings.filter { $0.provider == StatusLineQuotaSource.providerID }
        s.bridgeFileCount = Set(bridgeReadings.compactMap(\.origin)).count
        s.newestBridgeObservation = bridgeReadings.map(\.observedAt).max()
        if inspectSettings { s.bridgeInstalledInClaudeSettings = StatusLineInstaller.inspect().isInstalled }
        s.lastRefresh = lastRefresh
        return s
    }

    // MARK: Refresh

    /// Re-reads the quota files. Safe to call often: calls closer together than the minimum gap
    /// are ignored unless `force` is set.
    public func refresh(force: Bool = false) {
        let now = clock()
        let sinceLast = Date().timeIntervalSince(lastRefreshAttempt)
        if !force, sinceLast < minimumRefreshGap {
            // Coalesce a burst of events into one read, but never drop the last one: a refresh is
            // scheduled for the end of the gap so that the final state is always picked up.
            if trailingRefresh == nil {
                let wait = minimumRefreshGap - sinceLast
                trailingRefresh = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    if Task.isCancelled { return }
                    await self?.runTrailingRefresh()
                }
            }
            return
        }
        trailingRefresh?.cancel()
        trailingRefresh = nil
        lastRefreshAttempt = Date()

        var fresh = StatusLineQuotaSource.readings(in: bridgeDirectory, now: now)
        if settings.value.showDesktopPlanUsageHint {
            fresh += DesktopPlanUsageSource.readings(at: desktopCacheURL)
        }
        let changed = fresh != readings
        readings = fresh
        lastRefresh = now
        persistChanges(fresh, now: now)
        if changed || force { notify() }
        scheduleNextWake(now: now)
    }

    private func runTrailingRefresh() {
        trailingRefresh = nil
        refresh(force: true)
    }

    private func notify() { for c in subscribers.values { c.yield(()) } }

    /// Stores authoritative readings in the quota history. A reading is stored when its value or
    /// window changed, or when five minutes have passed since the last stored reading of the same
    /// kind, so that the history is detailed without growing with every status line render.
    private func persistChanges(_ readings: [QuotaReading], now: Date) {
        var toWrite: [QuotaReading] = []
        // Persist the newest reading per kind and provider.
        var newest: [String: QuotaReading] = [:]
        for r in readings where r.authority == .authoritative {
            let key = "\(r.provider)|\(r.kind.rawValue)"
            if let existing = newest[key], existing.observedAt >= r.observedAt { continue }
            newest[key] = r
        }
        for (key, r) in newest {
            if let last = lastPersisted[key] {
                let same = last.percent == r.utilizationPercent && last.resetsAt == r.resetsAt
                if same && r.observedAt.timeIntervalSince(last.at) < 5 * 60 { continue }
                if r.observedAt <= last.at && same { continue }
            }
            toWrite.append(r)
            lastPersisted[key] = (r.utilizationPercent, r.resetsAt, r.observedAt)
        }
        guard !toWrite.isEmpty else { return }
        _ = try? db.write { c in
            for r in toWrite {
                try c.run("""
                    INSERT OR IGNORE INTO quota_snapshot(provider, window_kind, utilization_pct, resets_at, observed_at, authority, origin)
                    VALUES(?, ?, ?, ?, ?, ?, ?)
                    """, [.text(r.provider), .text(r.kind.rawValue), .real(r.utilizationPercent),
                          .optional(r.resetsAt.map(Clock.ms)), .int(Clock.ms(r.observedAt)),
                          .text(r.authority.rawValue), .optional(r.origin)])
            }
        }
    }

    /// Sleeps until the next time a window's state could change without any new data: a reset, or a
    /// reading passing from fresh to ageing to stale. The safety-net interval bounds the wait.
    private func scheduleNextWake(now: Date) {
        timerTask?.cancel()
        var next = now.addingTimeInterval(TimeInterval(settings.value.quotaRefreshSeconds))
        for r in readings where r.authority == .authoritative || settings.value.showDesktopPlanUsageHint {
            if let reset = r.resetsAt, reset > now { next = min(next, reset.addingTimeInterval(1)) }
            for threshold in [freshnessPolicy.freshWithin, freshnessPolicy.agingWithin] {
                let t = r.observedAt.addingTimeInterval(threshold + 1)
                if t > now { next = min(next, t) }
            }
        }
        let delay = max(1, next.timeIntervalSince(now))
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(min(5, delay / 10)))
            if Task.isCancelled { return }
            await self?.refresh(force: true)
        }
    }

    // MARK: History

    /// Returns the authoritative utilization history for charts.
    public func history(kind: QuotaWindowKind, since: Date) -> [QuotaReading] {
        (try? db.read { c in
            try c.query("""
                SELECT utilization_pct, resets_at, observed_at, provider, authority, origin
                FROM quota_snapshot WHERE window_kind = ? AND observed_at >= ? ORDER BY observed_at
                """, [.text(kind.rawValue), .int(Clock.ms(since))]) { row in
                QuotaReading(kind: kind, utilizationPercent: row.double(0),
                             resetsAt: row.intOrNil(1).map { Clock.date(ms: $0) }, observedAt: Clock.date(ms: row.int(2)),
                             provider: row.text(3), authority: QuotaAuthority(rawValue: row.text(4)) ?? .unverified,
                             origin: row.textOrNil(5))
            }
        }) ?? []
    }
}
