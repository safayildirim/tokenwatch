import Foundation
import Darwin

/// Watches the registry of running Claude Code processes to observe which sessions are live.
///
/// Claude Code writes `~/.claude/sessions/<pid>.json` for each running session, with the session
/// id, the process id and a coarse busy or idle status, and removes it when the process exits.
/// This gives a directly observed lifecycle for sessions that run while the monitor is active, which
/// is more trustworthy than guessing from how recently a transcript changed.
///
/// Only the `.json` files are read. The neighbouring `.key` files hold a peer authentication token
/// and are never opened.
public actor SessionRegistryMonitor {
    private let directory: URL
    private let db: UsageDatabase?
    public nonisolated let product: ProductID
    private var table: [String: LiveProcess] = [:]
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var watcher: FSEventsWatcher?
    private var tasks: [Task<Void, Never>] = []
    private var livenessTask: Task<Void, Never>?

    public init(directory: URL = QuotaPaths.claudeHome.appendingPathComponent("sessions"),
                db: UsageDatabase?, product: ProductID = .claudeCode) {
        self.directory = directory
        self.db = db
        self.product = product
    }

    /// Returns the live processes keyed by session id.
    public func liveSessions() -> [String: LiveProcess] { table }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
            subscribers[id] = c
            c.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    public func start() {
        guard watcher == nil else { return }
        let w = FSEventsWatcher(roots: [directory], latency: 0.3)
        watcher = w
        w.start()
        tasks.append(Task { [weak self] in
            for await _ in w.events { await self?.rescan() }
        })
        rescan()
    }

    public func stop() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        livenessTask?.cancel()
        watcher?.stop()
        watcher = nil
        for c in subscribers.values { c.finish() }
        subscribers.removeAll()
    }

    /// Reads the registry again.
    public func rescan() {
        let previous = table
        var next: [String: LiveProcess] = [:]
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasSuffix(".json") {
                guard let data = fm.contents(atPath: directory.appendingPathComponent(name).path),
                      let live = Self.parse(data) else { continue }
                next[live.sessionExternalID] = live
            }
        }
        table = next
        recordTransitions(previous: previous, current: next)
        updateLivenessPolling()
        for c in subscribers.values { c.yield(()) }
    }

    static func parse(_ data: Data) -> LiveProcess? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = object["sessionId"] as? String,
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              ProcessLiveness.isRunning(pid: pid, startedAt: object["procStart"] as? String)
        else { return nil }
        let activity: LiveProcess.Activity
        switch object["status"] as? String {
        case "busy": activity = .busy
        case "idle": activity = .idle
        default: activity = .other
        }
        return LiveProcess(sessionExternalID: sessionID, pid: pid, activity: activity,
                           entrypoint: object["entrypoint"] as? String,
                           updatedAt: (object["updatedAt"] as? NSNumber)?.int64Value)
    }

    private func recordTransitions(previous: [String: LiveProcess], current: [String: LiveProcess]) {
        guard let db else { return }
        let ended = Set(previous.keys).subtracting(current.keys)
        let resumed = Set(current.keys).subtracting(previous.keys)
        guard !ended.isEmpty || !resumed.isEmpty else { return }
        let now = Clock.nowMs()
        let product = self.product.rawValue
        _ = try? db.write { c in
            for id in ended {
                try c.run("UPDATE session SET observed_ended_at = ? WHERE product_id = ? AND external_id = ?",
                          [.int(now), .text(product), .text(id)])
            }
            for id in resumed {
                try c.run("UPDATE session SET observed_ended_at = NULL WHERE product_id = ? AND external_id = ?",
                          [.text(product), .text(id)])
            }
        }
    }

    /// A process can exit without removing its registry file (a crash or a kill), so while any
    /// session is believed live the table is re-validated at a relaxed interval. With no live
    /// sessions there is nothing to poll, and the timer stops.
    private func updateLivenessPolling() {
        if table.isEmpty { livenessTask?.cancel(); livenessTask = nil; return }
        guard livenessTask == nil else { return }
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(10))
                if Task.isCancelled { break }
                await self?.rescan()
            }
        }
    }
}

enum ProcessLiveness {
    /// True if `pid` is a running process. When the registry recorded the process start time, it
    /// must also match, so that a recycled process id is not mistaken for the original session.
    static func isRunning(pid: Int32, startedAt: String?) -> Bool {
        if kill(pid, 0) != 0 && errno != EPERM { return false }
        guard let startedAt, let expected = parseStart(startedAt), let actual = startTime(pid: pid) else { return true }
        return abs(actual.timeIntervalSince(expected)) <= 3
    }

    static func parseStart(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    static func startTime(pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }
}
