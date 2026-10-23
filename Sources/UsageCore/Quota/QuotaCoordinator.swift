import Foundation

/// Combines the quota sources, remembers what they report, and tells the rest of the app when a
/// window's state changes.
///
/// Quota figures reach the database in two ways. A `QuotaFeed` supplies observations that this coordinator reads and
/// stores (Claude Code's local usage cache is one). A session-log adapter can instead emit its provider's snapshots
/// together with the usage it reads (the OpenAI adapter does). Either way the state shown to the user is evaluated
/// from the stored snapshots, so every provider is handled by the same code.
///
/// No usage percentage is ever computed from token counts: when no source has reported a window, that
/// window is shown as unavailable.
///
/// The coordinator does no polling of its own for new data. It reacts to file events from the
/// bridge directory and to `dataDidChange()`, and it sleeps until the next moment at which a state could
/// change by itself (a window reset or a reading going stale). A slow safety-net refresh, configurable
/// within safe limits, covers a missed file event.
public actor QuotaCoordinator {
    private let db: UsageDatabase
    private let settings: SettingsStore
    private let feeds: [any QuotaFeed]
    private let freshnessPolicy: QuotaFreshnessPolicy
    private let clock: @Sendable () -> Date

    private var feedObservations: [QuotaObservation] = []
    private var feedStatuses: [TelemetrySourceID: QuotaFeedStatus] = [:]
    private var recorded: [String: QuotaObservation] = [:]
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var watcher: FSEventsWatcher?
    private var fileWatchers: [URL: FileEventWatcher] = [:]
    private var fileWatcherTasks: [URL: Task<Void, Never>] = [:]
    private var accountFingerprints: [TelemetrySourceID: String] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var timerTask: Task<Void, Never>?
    private var started = false
    private var lastRefresh: Date?
    private var lastRefreshAttempt = Date.distantPast
    private var trailingRefresh: Task<Void, Never>?

    /// Refreshes closer together than this are coalesced, which keeps a burst of file events (Claude Code
    /// rewrites its state file often) from causing a burst of reads.
    private let minimumRefreshGap: TimeInterval = 1.0

    public init(db: UsageDatabase, settings: SettingsStore, feeds: [any QuotaFeed],
                freshnessPolicy: QuotaFreshnessPolicy = QuotaFreshnessPolicy(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.settings = settings
        self.feeds = feeds
        self.freshnessPolicy = freshnessPolicy
        self.clock = clock
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        let roots = feeds.flatMap(\.watchRoots)
        // The folders feeds write into are created for them, private to the user, so that watching can begin.
        for root in roots {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !roots.isEmpty {
            let w = FSEventsWatcher(roots: roots, latency: 0.3)
            watcher = w
            w.start()
            tasks.append(Task { [weak self] in
                for await _ in w.events { await self?.refresh() }
            })
        }
        armFileWatchers()
        refresh(force: true)
    }

    public func stop() {
        started = false
        for t in tasks { t.cancel() }
        tasks.removeAll()
        timerTask?.cancel()
        timerTask = nil
        trailingRefresh?.cancel()
        trailingRefresh = nil
        watcher?.stop()
        watcher = nil
        for w in fileWatchers.values { w.stop() }
        fileWatchers.removeAll()
        for t in fileWatcherTasks.values { t.cancel() }
        fileWatcherTasks.removeAll()
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

    /// The state of every pool that has reported, grouped by pool.
    ///
    /// A pool that the registry says exists but that has never reported is listed on the unassigned
    /// account with its standard windows marked unavailable, so that the interface can explain the gap.
    public func pools(now: Date? = nil) -> [QuotaPoolState] {
        let now = now ?? clock()
        let allowUnverified = settings.value.showUnverifiedQuota
        // Readings from undocumented sources are never stored, so they are added here, and only when allowed.
        let extra = allowUnverified ? feedObservations.filter { $0.authority == .unverified } : []
        return QuotaStateReader.pools(db: db, now: now, allowUnverified: allowUnverified, policy: freshnessPolicy, extra: extra)
    }

    /// Every window of every pool, flattened.
    public func states(now: Date? = nil) -> [QuotaWindowState] { pools(now: now).flatMap(\.windows) }

    /// How each feed is delivering, for the diagnostics view.
    public func feedStatus() -> [QuotaFeedStatus] {
        feeds.map {
            feedStatuses[$0.id] ?? QuotaFeedStatus(id: $0.id, rootsExist: rootsExist(for: $0),
                                                   observationCount: 0, originCount: 0, newestObservation: nil, lastRead: nil)
        }
    }

    /// An empty watch-root list has no folder to report. Treating it as vacuously present hid the absence of a file
    /// source (the Desktop plan cache) in diagnostics.
    private func rootsExist(for feed: any QuotaFeed) -> Bool {
        !feed.watchRoots.isEmpty && feed.watchRoots.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Refresh

    /// Opens one descriptor per watched file. The cache lives in the home directory, so watching it through FSEvents
    /// would subscribe the coordinator to every unrelated write in the home tree.
    private func armFileWatchers() {
        guard started else { return }
        let files = Set(feeds.flatMap(\.watchFiles).map { $0.standardizedFileURL })
        // Collect before mutating: Swift dictionaries must not be changed while they are being iterated.
        let stale = fileWatchers.filter { !$0.value.isWatching }.map(\.key)
        for file in stale {
            fileWatchers[file]?.stop()
            fileWatchers[file] = nil
            fileWatcherTasks[file]?.cancel()
            fileWatcherTasks[file] = nil
        }
        for file in files where fileWatchers[file] == nil {
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let watcher = FileEventWatcher(url: file)
            fileWatchers[file] = watcher
            fileWatcherTasks[file] = Task { [weak self] in
                for await _ in watcher.events { await self?.refresh() }
            }
        }
    }

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

        var fresh: [QuotaObservation] = []
        let enabledSources = settings.value
        for feed in feeds where !enabledSources.disabledSources.contains(feed.id.rawValue) && (!feed.requiresOptIn || enabledSources.showUnverifiedQuota) {
            let output = feed.read(now: now)
            var issue = output.issue
            if let current = output.accountFingerprint {
                if let previous = accountFingerprints[feed.id], previous != current {
                    issue = .accountChanged
                }
                accountFingerprints[feed.id] = current
            }
            fresh += output.observations
            let previous = feedStatuses[feed.id]
            feedStatuses[feed.id] = QuotaFeedStatus(
                id: feed.id, rootsExist: rootsExist(for: feed),
                observationCount: output.observations.count,
                originCount: Set(output.observations.compactMap(\.originSession)).count,
                newestObservation: output.observations.map(\.observedAt).max(), lastRead: now,
                // A partial read still produced usable observations. Only a read with no observations leaves the last
                // success where it was, so a malformed snapshot cannot make an earlier successful read disappear.
                lastSuccess: !output.observations.isEmpty ? now : previous?.lastSuccess,
                sourceExists: output.sourceExists, sourcePath: output.sourcePath?.path, issue: issue)
        }
        let changed = fresh != feedObservations
        feedObservations = fresh
        lastRefresh = now
        persistChanges(fresh)
        armFileWatchers()
        if changed || force { notify() }
        scheduleNextWake(now: now)
    }

    /// Tells the coordinator that the importer stored new data, which may include quota snapshots.
    public func dataDidChange() {
        notify()
        scheduleNextWake(now: clock())
    }

    private func runTrailingRefresh() {
        trailingRefresh = nil
        refresh(force: true)
    }

    private func notify() { for c in subscribers.values { c.yield(()) } }

    /// Stores the authoritative readings that differ from what was stored before. The store collapses
    /// identical values into one snapshot whose confirmation time moves forward, so the history stays small
    /// however often a source is rewritten. Unverified readings are never stored.
    private func persistChanges(_ observations: [QuotaObservation]) {
        var toWrite: [(key: String, observation: QuotaObservation)] = []
        for o in observations where o.authority == .authoritative {
            let key = "\(o.provider.rawValue)|\(o.account.hash ?? "-")|\(o.source.rawValue)|\(o.originSession ?? "-")|\(o.poolKey)|\(o.windowKey)"
            if recorded[key] == o { continue }
            toWrite.append((key, o))
        }
        guard !toWrite.isEmpty else { return }
        let batch = IngestWriter.coalesce(toWrite.map(\.observation))
        do {
            try db.write { c in
                let resolver = EntityResolver(c, registry: db.registry)
                for o in batch {
                    var originID: Int64?
                    if let product = o.originProduct, let session = o.originSession {
                        originID = try? resolver.ensureSession(product: product, externalID: session, source: o.source)
                    }
                    try QuotaStore.record(o, originSessionID: originID, resolver: resolver)
                }
            }
            // Do not claim an observation as recorded until the transaction committed. A transient database error must
            // leave it eligible for the next refresh instead of losing it permanently.
            for item in toWrite { recorded[item.key] = item.observation }
        } catch {
            // The feed status still carries the source error, and the next refresh will retry.
        }
    }

    /// Sleeps until the next time a window's state could change without any new data: a reset, or a
    /// reading passing from fresh to ageing to stale. The safety-net interval bounds the wait.
    private func scheduleNextWake(now: Date) {
        // An explicit refresh can be used before start (tests and diagnostics do so). It must not create a wake task
        // for a coordinator that is stopped.
        guard started else { return }
        timerTask?.cancel()
        var next = now.addingTimeInterval(TimeInterval(settings.value.quotaRefreshSeconds))
        for state in states(now: now) {
            guard let r = state.reading else { continue }
            if let reset = r.resetsAt, reset > now { next = min(next, reset.addingTimeInterval(1)) }
            let thresholds = freshnessPolicy.thresholds(for: r.source)
            for threshold in [thresholds.fresh, thresholds.aging] {
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

    /// Returns the stored utilization history of one window, oldest first, for charts.
    public func history(pool: QuotaPoolKey, windowKey: String, since: Date) -> [QuotaReading] {
        QuotaStateReader.history(db: db, pool: pool, windowKey: windowKey, since: since)
    }
}

/// Reads the stored quota snapshots and evaluates them.
enum QuotaStateReader {
    /// How many of the newest snapshots per window and authority are considered. A window's current
    /// state never depends on older ones.
    private static let snapshotsPerWindow = 40

    private struct Row {
        var poolID: String
        var provider: ProviderID
        var accountID: Int64
        var accountLabel: String
        var poolKey: String
        var planType: String?
        var windowKey: String
        var minutes: Int?
        var reading: QuotaReading
    }

    static func pools(db: UsageDatabase, now: Date, allowUnverified: Bool, policy: QuotaFreshnessPolicy,
                      extra: [QuotaObservation] = []) -> [QuotaPoolState] {
        var rows: [Row] = (try? db.read { c in
            try c.query("""
                SELECT p.id, p.provider_id, p.account_id, COALESCE(a.label, 'Unassigned'), p.pool_key, p.plan_type,
                       w.window_key, w.duration_minutes,
                       q.utilization_pct, q.resets_at, q.observed_at, q.last_confirmed_at, q.telemetry_source_id, q.authority, q.cycle_id
                FROM (SELECT *, row_number() OVER (PARTITION BY window_id, authority ORDER BY last_confirmed_at DESC, id DESC) AS rn
                      FROM quota_snapshot) q
                JOIN quota_window w ON w.id = q.window_id
                JOIN quota_pool p ON p.id = w.pool_id
                JOIN account a ON a.id = p.account_id
                WHERE q.rn <= \(snapshotsPerWindow)
                """) { r in
                Row(poolID: "\(r.int(2))/\(r.text(4))", provider: ProviderID(rawValue: r.text(1)), accountID: r.int(2), accountLabel: r.text(3),
                    poolKey: r.text(4), planType: r.textOrNil(5), windowKey: r.text(6), minutes: r.intOrNil(7).map { Int($0) },
                    reading: QuotaReading(utilizationPercent: r.double(8), resetsAt: r.intOrNil(9).map { Clock.date(ms: $0) },
                                          observedAt: Clock.date(ms: r.int(11)), firstObservedAt: Clock.date(ms: r.int(10)),
                                          source: TelemetrySourceID(rawValue: r.text(12)),
                                          authority: QuotaAuthority(rawValue: r.text(13)) ?? .unverified, cycleID: r.int(14)))
            }
        }) ?? []

        // Readings that are not stored are attached to the account they name.
        for o in extra {
            let account: (id: Int64, label: String)? = try? db.read { c in
                try c.queryOne("SELECT id, COALESCE(label, 'Unassigned') FROM account WHERE provider_id = ? AND hash = ?",
                               [.text(o.provider.rawValue), .text(o.account.hash ?? "")]) { ($0.int(0), $0.text(1)) }
            } ?? nil
            guard let account else { continue }
            rows.append(Row(poolID: "\(account.id)/\(o.poolKey)", provider: o.provider, accountID: account.id,
                            accountLabel: account.label, poolKey: o.poolKey, planType: o.planType, windowKey: o.windowKey,
                            minutes: o.windowMinutes,
                            reading: QuotaReading(utilizationPercent: o.utilizationPercent, resetsAt: o.resetsAt, observedAt: o.observedAt,
                                                  source: o.source, authority: o.authority)))
        }

        struct WindowID: Hashable { var pool: String; var key: String }
        var byWindow: [WindowID: [Row]] = [:]
        var poolOrder: [String] = []
        for row in rows {
            byWindow[WindowID(pool: row.poolID, key: row.windowKey), default: []].append(row)
            if !poolOrder.contains(row.poolID) { poolOrder.append(row.poolID) }
        }
        var windowsByPool: [String: [WindowID]] = [:]
        for id in byWindow.keys { windowsByPool[id.pool, default: []].append(id) }

        func info(_ row: Row) -> QuotaPoolInfo {
            let definition = db.registry.pool(provider: row.provider, key: row.poolKey)
            return QuotaPoolInfo(key: QuotaPoolKey(provider: row.provider, accountID: row.accountID, poolKey: row.poolKey),
                                 accountLabel: row.accountLabel, name: definition.map { DisplayText.localized($0.name) } ?? row.poolKey, planType: row.planType,
                                 products: definition?.products ?? [], note: DisplayText.localized(definition?.note ?? ""))
        }

        var out: [QuotaPoolState] = []
        for poolID in poolOrder {
            let ids = windowsByPool[poolID] ?? []
            guard let sample = byWindow[ids[0]]?.first else { continue }
            let poolInfo = info(sample)
            var windows: [QuotaWindowState] = []
            for id in ids {
                let group = byWindow[id]!
                // A window whose length was reported is displayed with that length.
                let minutes = group.compactMap(\.minutes).first
                windows.append(QuotaEvaluator.evaluate(pool: poolInfo, windowKey: id.key, windowMinutes: minutes,
                                                       readings: group.map(\.reading), now: now,
                                                       allowUnverified: allowUnverified, policy: policy))
            }
            // Windows with no unverified-allowed reading are dropped, since there is nothing to show for them.
            windows = windows.filter { $0.reading != nil }
            if windows.isEmpty { continue }
            // A pool that has reported no window of a fixed length (only a spend limit, for example) still lists
            // the windows that the provider is known to enforce, so that the interface can say they are missing.
            if !windows.contains(where: { $0.windowMinutes != nil }),
               let definition = db.registry.pool(provider: sample.provider, key: sample.poolKey) {
                for minutes in definition.standardWindowMinutes {
                    windows.append(QuotaWindowState(pool: poolInfo, windowKey: WindowNaming.key(minutes: minutes), windowMinutes: minutes,
                                                    reading: nil, availability: .unavailable(.noData), freshness: nil, evaluatedAt: now))
                }
            }
            windows.sort { ($0.windowMinutes ?? Int.max, $0.windowKey) < ($1.windowMinutes ?? Int.max, $1.windowKey) }
            out.append(QuotaPoolState(pool: poolInfo, windows: windows))
        }

        // Pools that never reported are listed on the unassigned account with their standard windows.
        let reported = Set(out.map { "\($0.pool.key.provider.rawValue)/\($0.pool.key.poolKey)" })
        let unassigned: [ProviderID: Int64] = (try? db.read { c in
            Dictionary(uniqueKeysWithValues: try c.query("SELECT provider_id, id FROM account WHERE hash = ''") {
                (ProviderID(rawValue: $0.text(0)), $0.int(1))
            })
        }) ?? [:]
        for definition in db.registry.pools where definition.isObservable
            && !reported.contains("\(definition.provider.rawValue)/\(definition.key)") {
            guard let accountID = unassigned[definition.provider] else { continue }
            let key = QuotaPoolKey(provider: definition.provider, accountID: accountID, poolKey: definition.key)
            let poolInfo = QuotaPoolInfo(key: key, accountLabel: "Unassigned", name: DisplayText.localized(definition.name),
                                         products: definition.products, note: DisplayText.localized(definition.note))
            let windows = definition.standardWindowMinutes.map {
                QuotaWindowState(pool: poolInfo, windowKey: WindowNaming.key(minutes: $0), windowMinutes: $0, reading: nil,
                                 availability: .unavailable(.noData), freshness: nil, evaluatedAt: now)
            }
            out.append(QuotaPoolState(pool: poolInfo, windows: windows))
        }
        return out.sorted { ($0.pool.key.provider.rawValue, $0.pool.name, $0.pool.accountLabel) < ($1.pool.key.provider.rawValue, $1.pool.name, $1.pool.accountLabel) }
    }

    static func history(db: UsageDatabase, pool: QuotaPoolKey, windowKey: String, since: Date) -> [QuotaReading] {
        (try? db.read { c in
            try c.query("""
                SELECT q.utilization_pct, q.resets_at, q.observed_at, q.last_confirmed_at, q.telemetry_source_id, q.authority, q.cycle_id
                FROM quota_snapshot q
                JOIN quota_window w ON w.id = q.window_id
                JOIN quota_pool p ON p.id = w.pool_id
                WHERE p.account_id = ? AND p.pool_key = ? AND w.window_key = ? AND q.last_confirmed_at >= ?
                ORDER BY q.observed_at
                """, [.int(pool.accountID), .text(pool.poolKey), .text(windowKey), .int(Clock.ms(since))]) { r in
                QuotaReading(utilizationPercent: r.double(0), resetsAt: r.intOrNil(1).map { Clock.date(ms: $0) },
                             observedAt: Clock.date(ms: r.int(3)), firstObservedAt: Clock.date(ms: r.int(2)),
                             source: TelemetrySourceID(rawValue: r.text(4)),
                             authority: QuotaAuthority(rawValue: r.text(5)) ?? .unverified, cycleID: r.int(6))
            }
        }) ?? []
    }
}
