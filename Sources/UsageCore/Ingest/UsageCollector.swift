import Foundation

/// This type describes the health of one usage source, as shown in the diagnostics view.
public struct SourceHealth: Sendable, Identifiable, Equatable {
    public enum State: String, Sendable {
        /// The source's data directory does not exist, for example because Claude Code is not installed.
        case notFound
        case ok
        /// Some files could not be read, but others are collected normally.
        case degraded
        /// Every recent attempt to collect from the source has failed.
        case failing
    }

    public var id: String { sourceID.rawValue }
    public var sourceID: TelemetrySourceID
    public var displayName: String
    public var coverageNote: String
    public var state: State = .ok
    public var filesKnown = 0
    public var filesFailed = 0
    public var lastSuccessAt: Date?
    public var lastError: String?
    public var consecutiveFailures = 0
    public var nextRetryAt: Date?

    public init(sourceID: TelemetrySourceID, displayName: String, coverageNote: String) {
        self.sourceID = sourceID
        self.displayName = displayName
        self.coverageNote = coverageNote
    }

    /// True once failures have persisted long enough to be worth telling the user about.
    public var hasPersistentFailure: Bool { consecutiveFailures >= 3 }
}

public struct CollectorSnapshot: Sendable, Equatable {
    public var isSyncing = false
    public var isInitialImport = false
    public var bytesTotal: Int64 = 0
    public var bytesDone: Int64 = 0
    public var sources: [SourceHealth] = []
    public var lastReconcileAt: Date?
    public var lastLatencyMs: Int?
    public var requestsTouchedThisRun = 0
    public var startedAt = Date()
    public init() {}

    public var progress: Double? {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : nil
    }
}

public enum CollectorEvent: Sendable {
    /// New usage data was committed to the database.
    case dataChanged
    /// The collector's status (progress or source health) changed.
    case statusChanged
}

/// Keeps the database up to date with every registered source.
///
/// Updates are event driven. FSEvents reports file changes, which are coalesced and applied
/// incrementally from the saved checkpoints. A low-frequency reconciliation pass (and one after
/// every wake from sleep) compares file metadata against the checkpoints, so that events lost to
/// sleep, a crash, or a kernel overflow are always caught up without rescanning contents.
///
/// All ingestion runs on one serialized work queue. Failures are contained per file and per
/// source, so one unreadable file or broken adapter never prevents the rest from being collected.
public actor UsageCollector {
    private enum Work {
        case drainPaths
        case reconcile(String)
        case rebuild
    }

    private let db: UsageDatabase
    private let adapters: [any SourceAdapter]
    private let synchronizer: FileSynchronizer
    private let retry: RetryPolicy
    private let reconcileInterval: TimeInterval
    private let concurrency: Int
    private let isSourceEnabled: @Sendable (TelemetrySourceID) -> Bool

    private var snapshotValue = CollectorSnapshot()
    private var healthBySource: [TelemetrySourceID: SourceHealth] = [:]
    private var pendingPaths: [String: Date] = [:]
    private var drainScheduled = false
    private var failedFiles: [String: (source: TelemetrySourceID, failures: Int, nextAttempt: Date)] = [:]

    private var work: AsyncStream<Work>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var watchers: [FSEventsWatcher] = []
    private var subscribers: [UUID: AsyncStream<CollectorEvent>.Continuation] = [:]
    private var retryTask: Task<Void, Never>?
    private var started = false

    public init(db: UsageDatabase, adapters: [any SourceAdapter],
                retentionFloorMs: @escaping @Sendable () -> Int64? = { nil },
                retry: RetryPolicy = RetryPolicy(), reconcileInterval: TimeInterval = 10 * 60,
                concurrency: Int = 3, isSourceEnabled: @escaping @Sendable (TelemetrySourceID) -> Bool = { _ in true }) {
        self.isSourceEnabled = isSourceEnabled
        self.db = db
        self.adapters = adapters
        self.synchronizer = FileSynchronizer(db: db, retentionFloorMs: retentionFloorMs)
        self.retry = retry
        self.reconcileInterval = reconcileInterval
        self.concurrency = max(1, concurrency)
        for a in adapters {
            healthBySource[a.sourceID] = SourceHealth(sourceID: a.sourceID, displayName: a.displayName,
                                                      coverageNote: a.coverageNote)
        }
    }

    // MARK: Public API

    public func snapshot() -> CollectorSnapshot {
        var s = snapshotValue
        s.sources = adapters.compactMap { healthBySource[$0.sourceID] }
        return s
    }

    /// Returns a stream of change notifications. Bursts are coalesced, so a consumer sees at most one
    /// pending event of each kind.
    public func events() -> AsyncStream<CollectorEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func emit(_ event: CollectorEvent) {
        for c in subscribers.values { c.yield(event) }
    }

    public func start() {
        guard !started else { return }
        started = true
        snapshotValue.startedAt = Date()
        var continuation: AsyncStream<Work>.Continuation!
        let stream = AsyncStream<Work>(bufferingPolicy: .unbounded) { continuation = $0 }
        work = continuation

        tasks.append(Task { [weak self] in
            for await item in stream {
                if Task.isCancelled { break }
                await self?.process(item)
            }
        })

        for adapter in adapters {
            let watcher = FSEventsWatcher(roots: adapter.watchRoots)
            watchers.append(watcher)
            watcher.start()
            tasks.append(Task { [weak self] in
                for await event in watcher.events {
                    await self?.receive(event)
                }
            })
        }

        tasks.append(Task { [weak self, reconcileInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(reconcileInterval), tolerance: .seconds(reconcileInterval / 5))
                if Task.isCancelled { break }
                await self?.enqueue(.reconcile("periodic"))
            }
        })

        enqueue(.reconcile("launch"))
    }

    public func stop() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        retryTask?.cancel()
        for w in watchers { w.stop() }
        watchers.removeAll()
        work?.finish()
        work = nil
        started = false
        for c in subscribers.values { c.finish() }
        subscribers.removeAll()
    }

    /// Runs a reconciliation pass now, for example because the user pressed Refresh.
    public func reconcileNow(reason: String = "manual") {
        enqueue(.reconcile(reason))
    }

    /// Call after the system wakes from sleep. File events delivered while asleep may have been
    /// coalesced or dropped, so the checkpoints are compared against the files again.
    public func systemDidWake() {
        enqueue(.reconcile("wake"))
    }

    /// Discards everything derived from source logs and imports it again.
    public func rebuildFromSource() {
        enqueue(.rebuild)
    }

    // MARK: Queue

    private func enqueue(_ item: Work) { work?.yield(item) }

    private func receive(_ event: WatchEvent) {
        switch event {
        case .paths(let paths):
            let now = Date()
            for p in paths where pendingPaths[p] == nil { pendingPaths[p] = now }
            if !drainScheduled {
                drainScheduled = true
                enqueue(.drainPaths)
            }
        case .rescan:
            enqueue(.reconcile("rescan"))
        }
    }

    private func process(_ item: Work) async {
        switch item {
        case .drainPaths:
            // Give a burst of writes a moment to finish, so that one pass handles all of it.
            try? await Task.sleep(for: .milliseconds(250))
            drainScheduled = false
            let batch = pendingPaths
            pendingPaths.removeAll()
            await syncChangedPaths(batch)
        case .reconcile(let reason):
            await reconcile(reason: reason)
        case .rebuild:
            await rebuild()
        }
    }

    // MARK: Path events

    private func syncChangedPaths(_ paths: [String: Date]) async {
        var planned: [(SourceFileRef, any SourceAdapter, Date)] = []
        var needsReconcile = false
        var seen = Set<String>()
        for (path, receivedAt) in paths {
            var matched = false
            for adapter in adapters where isSourceEnabled(adapter.sourceID) {
                if let ref = adapter.fileRef(forPath: path) {
                    matched = true
                    if seen.insert(path).inserted { planned.append((ref, adapter, receivedAt)) }
                }
            }
            if !matched {
                // A directory event (a new project folder, a moved tree) is cheaper to handle with a
                // metadata comparison than by guessing which files are affected.
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: path) || (FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue) {
                    needsReconcile = true
                }
            }
        }
        if !planned.isEmpty {
            let earliest = planned.map(\.2).min() ?? Date()
            await run(planned.map { ($0.0, $0.1) }, initial: false)
            snapshotValue.lastLatencyMs = Int(Date().timeIntervalSince(earliest) * 1000)
            emit(.statusChanged)
        }
        if needsReconcile { await reconcile(reason: "directory-event") }
    }

    // MARK: Reconciliation

    private func reconcile(reason: String) async {
        var plan: [(ref: SourceFileRef, adapter: any SourceAdapter, bytes: Int64, mtime: Double)] = []
        var anyCheckpoints = false
        let now = Date()

        for adapter in adapters where isSourceEnabled(adapter.sourceID) {
            var health = healthBySource[adapter.sourceID] ?? SourceHealth(sourceID: adapter.sourceID, displayName: adapter.displayName, coverageNote: adapter.coverageNote)
            if !adapter.watchRoots.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                health.state = .notFound
                health.filesKnown = 0
                health.lastError = "Data folder not found: \(adapter.watchRoots.first?.path ?? "?")"
                healthBySource[adapter.sourceID] = health
                continue
            }
            do {
                let refs = try adapter.discoverFiles()
                let checkpoints = try synchronizer.loadAllCheckpoints(sourceID: adapter.sourceID)
                anyCheckpoints = anyCheckpoints || !checkpoints.isEmpty
                health.filesKnown = refs.count
                var present = Set<String>()
                for ref in refs {
                    present.insert(ref.path)
                    var st = stat()
                    guard stat(ref.path, &st) == 0 else { continue }
                    let size = Int64(st.st_size)
                    let mtime = Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
                    let retryDue = failedFiles[ref.path].map { $0.nextAttempt <= now } ?? true
                    if let cp = checkpoints[ref.path] {
                        // A file that could not be decoded stays as it is until it changes.
                        let settled = cp.status == "ok" || cp.status == "damaged"
                        let changed = cp.size != size || cp.mtimeMs != mtime || cp.inode != Int64(st.st_ino) || !settled
                        if changed && retryDue {
                            let readsWholeFile = ref.isCompressed || !adapter.resumesFromCheckpoint
                            plan.append((ref, adapter, readsWholeFile ? size : max(0, size - cp.consumedOffset), Double(mtime)))
                        }
                    } else if retryDue {
                        plan.append((ref, adapter, size, Double(mtime)))
                    }
                }
                // Files that disappeared keep their data; only the checkpoint status changes.
                for (path, cp) in checkpoints where !present.contains(path) && cp.status != "missing" {
                    synchronizer.markMissing(sourceID: adapter.sourceID, path: path)
                }
                if health.state == .notFound { health.state = .ok; health.lastError = nil }
            } catch {
                recordSourceFailure(adapter.sourceID, error: error, filePath: nil)
                continue
            }
            healthBySource[adapter.sourceID] = health
        }

        snapshotValue.lastReconcileAt = Date()
        // Recently modified files first, so the dashboard shows current activity while a large
        // history is still being imported.
        plan.sort { $0.mtime > $1.mtime }
        if !plan.isEmpty {
            let initial = !anyCheckpoints
            snapshotValue.isInitialImport = initial
            snapshotValue.bytesTotal = plan.reduce(0) { $0 + $1.bytes }
            snapshotValue.bytesDone = 0
            await run(plan.map { ($0.ref, $0.adapter) }, initial: initial)
        }
        updateOverallStates()
        emit(.statusChanged)
        scheduleRetryIfNeeded()
    }

    private func rebuild() async {
        failedFiles.removeAll()
        do { try db.resetDerivedUsageData() } catch {
            for a in adapters { recordSourceFailure(a.sourceID, error: error, filePath: nil) }
            return
        }
        emit(.dataChanged)
        await reconcile(reason: "rebuild")
    }

    // MARK: Running synchronizations

    private struct FileOutcome: Sendable {
        var ref: SourceFileRef
        var result: SyncResult?
        var errorMessage: String?
        var error: (any Error)?
    }

    private func run(_ files: [(SourceFileRef, any SourceAdapter)], initial: Bool) async {
        guard !files.isEmpty else { return }
        snapshotValue.isSyncing = true
        if initial { snapshotValue.isInitialImport = true }
        emit(.statusChanged)

        let synchronizer = self.synchronizer
        var index = 0
        var committedAny = false
        await withTaskGroup(of: FileOutcome.self) { group in
            func addNext() {
                guard index < files.count else { return }
                let (ref, adapter) = files[index]
                index += 1
                group.addTask(priority: .utility) {
                    do {
                        let result = try synchronizer.sync(file: ref, adapter: adapter)
                        return FileOutcome(ref: ref, result: result)
                    } catch {
                        return FileOutcome(ref: ref, result: nil, errorMessage: "\(error)", error: error)
                    }
                }
            }
            for _ in 0..<min(concurrency, files.count) { addNext() }
            var sinceEmit = Date()
            while let outcome = await group.next() {
                if let result = outcome.result {
                    snapshotValue.bytesDone += result.bytesRead
                    snapshotValue.requestsTouchedThisRun += result.requestsTouched
                    failedFiles[outcome.ref.path] = nil
                    if result.bytesRead > 0 { committedAny = true }
                    markSuccess(outcome.ref.sourceID)
                } else if let error = outcome.error {
                    recordSourceFailure(outcome.ref.sourceID, error: error, filePath: outcome.ref.path)
                }
                if Date().timeIntervalSince(sinceEmit) > 0.5 {
                    sinceEmit = Date()
                    emit(.statusChanged)
                    if committedAny { emit(.dataChanged); committedAny = false }
                }
                addNext()
            }
        }
        snapshotValue.isSyncing = false
        snapshotValue.isInitialImport = false
        if committedAny { emit(.dataChanged) }
        emit(.statusChanged)
    }

    // MARK: Health bookkeeping

    private func markSuccess(_ sourceID: TelemetrySourceID) {
        guard var h = healthBySource[sourceID] else { return }
        h.lastSuccessAt = Date()
        healthBySource[sourceID] = h
    }

    private func recordSourceFailure(_ sourceID: TelemetrySourceID, error: any Error, filePath: String?) {
        let message = Self.describe(error)
        if let filePath {
            let previous = failedFiles[filePath]?.failures ?? 0
            let failures = previous + 1
            var retryAfter: TimeInterval?
            if let sql = error as? SQLiteError, sql.isDiskFull { retryAfter = 5 * 60 }
            failedFiles[filePath] = (sourceID, failures, Date().addingTimeInterval(retry.delay(afterFailures: failures, retryAfter: retryAfter)))
        }
        if var h = healthBySource[sourceID] {
            h.lastError = message
            h.consecutiveFailures += 1
            h.filesFailed = failedFiles.values.filter { $0.source == sourceID }.count
            healthBySource[sourceID] = h
        }
        _ = try? db.write { c in
            try c.run("INSERT INTO ingest_issue(source_id, path, at, severity, message) VALUES(?, ?, ?, 'error', ?)",
                      [.text(sourceID.rawValue), .optional(filePath), .int(Clock.nowMs()), .text(message)])
            try c.run("DELETE FROM ingest_issue WHERE id NOT IN (SELECT id FROM ingest_issue ORDER BY id DESC LIMIT 500)")
        }
    }

    private func updateOverallStates() {
        for (id, var h) in healthBySource where h.state != .notFound {
            // A failure belongs to the source that owns the file, so one source's trouble never marks another unhealthy.
            let own = failedFiles.values.filter { $0.source == id }
            h.filesFailed = own.count
            if own.isEmpty {
                h.state = .ok
                h.consecutiveFailures = 0
                h.nextRetryAt = nil
                if h.lastError != nil && h.lastSuccessAt != nil { h.lastError = nil }
            } else {
                h.state = h.consecutiveFailures >= h.filesKnown && h.filesKnown > 0 ? .failing : .degraded
                h.nextRetryAt = own.map(\.nextAttempt).min()
            }
            healthBySource[id] = h
        }
    }

    private func scheduleRetryIfNeeded() {
        retryTask?.cancel()
        guard let next = failedFiles.values.map(\.nextAttempt).min() else { return }
        let delay = max(1, next.timeIntervalSinceNow)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            await self?.enqueue(.reconcile("retry"))
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let e = error as? FileAccessError {
            return e.isPermissionDenied
                ? "macOS denied access to \(e.path). Grant the app access in System Settings > Privacy & Security."
                : e.description
        }
        if let e = error as? SQLiteError {
            if e.isDiskFull { return "The disk is full, so usage data cannot be saved. Free up space to resume." }
            if e.isBusy { return "The database stayed locked by another process." }
            return e.description
        }
        return "\(error)"
    }
}
