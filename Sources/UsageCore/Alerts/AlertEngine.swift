import Foundation

public enum AlertKind: String, Sendable {
    case threshold, reset, staleData, collectionFailure
}

/// A notification that should be shown to the user.
public struct AlertNotification: Sendable, Equatable, Identifiable {
    public var id: String { key }
    /// Identifies the event. An alert with a given key is delivered at most once.
    public var key: String
    public var kind: AlertKind
    public var title: String
    public var body: String

    public init(key: String, kind: AlertKind, title: String, body: String) {
        self.key = key
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// Decides which notifications to raise, and remembers which have been raised.
///
/// Rules that keep alerts trustworthy:
/// - Quota alerts use only authoritative readings of a window that is still open. A token-based
///   estimate can never trigger one, because none is ever computed.
/// - A threshold alert is tied to one instance of a window (identified by its reset time), so it is
///   raised once per crossing. Re-reading the same value, or reading it again after the data went
///   stale and was refreshed, raises nothing.
/// - If usage jumps over several thresholds at once, only the highest is announced.
/// - Stale-data and failure alerts fire once per episode.
public final class AlertEngine: @unchecked Sendable {
    private let db: UsageDatabase
    private let lock = NSLock()
    private var fired: Set<String>
    private var lastWindow: [QuotaWindowKind: (windowID: Int64, percent: Double)] = [:]
    private var previousFreshness: [QuotaWindowKind: QuotaFreshness] = [:]

    public init(db: UsageDatabase) {
        self.db = db
        fired = Set((try? db.read { c in try c.query("SELECT key FROM alert_fired") { $0.text(0) } }) ?? [])
        for kind in [QuotaWindowKind.fiveHour, .sevenDay] {
            if let raw = db.setting("alert_last_window_\(kind.rawValue)") {
                let parts = raw.split(separator: "|")
                if parts.count == 2, let id = Int64(parts[0]), let pct = Double(parts[1]) { lastWindow[kind] = (id, pct) }
            }
        }
    }

    /// Identifies a window instance. Reset times of the same window can differ by a few seconds
    /// between reports, so they are rounded to the nearest hour.
    static func windowID(_ reset: Date) -> Int64 { Int64((reset.timeIntervalSince1970 / 3600).rounded()) }

    public func evaluate(states: [QuotaWindowState], sources: [SourceHealth], recentLocalActivity: Bool,
                         settings: NotificationSettings, now: Date = Date()) -> [AlertNotification] {
        lock.lock(); defer { lock.unlock() }
        var out: [AlertNotification] = []

        for state in states where state.kind == .fiveHour || state.kind == .sevenDay {
            guard let reading = state.reading, reading.authority == .authoritative else { continue }
            let thresholds = state.kind == .fiveHour ? settings.fiveHourThresholds : settings.weeklyThresholds

            switch state.availability {
            case .available:
                if let reset = reading.resetsAt {
                    let window = Self.windowID(reset)
                    // A new window instance following an old one whose end has passed is a reset.
                    if let last = lastWindow[state.kind], last.windowID != window, last.percent >= 50 {
                        let key = "reset:\(state.kind.rawValue):\(last.windowID)"
                        if settings.notifyOnReset, markFired(key, kind: .reset, detail: nil) {
                            out.append(AlertNotification(key: key, kind: .reset, title: "\(state.kind.displayName) reset",
                                                         body: "Your \(state.kind.displayName.lowercased()) allowance has reset."))
                        }
                    }
                    rememberWindow(state.kind, window, reading.utilizationPercent)

                    if state.isAlertEligible {
                        let crossed = thresholds.filter { Double($0) <= reading.utilizationPercent }.sorted()
                        let unannounced = crossed.filter { !fired.contains("thr:\(state.kind.rawValue):\(window):\($0)") }
                        if let highest = unannounced.last {
                            for t in unannounced { _ = markFired("thr:\(state.kind.rawValue):\(window):\(t)", kind: .threshold, detail: nil) }
                            if settings.enabled {
                                out.append(AlertNotification(
                                    key: "thr:\(state.kind.rawValue):\(window):\(highest)", kind: .threshold,
                                    title: "\(state.kind.displayName) at \(Int(reading.utilizationPercent.rounded()))%",
                                    body: "You have used \(Int(reading.utilizationPercent.rounded()))% of your \(state.kind.displayName.lowercased()) allowance."
                                        + (reading.resetsAt.map { " It resets \(Self.relative($0, now: now))." } ?? "")))
                            }
                        }
                    }
                }
            case .windowElapsed(let resetAt):
                let window = Self.windowID(resetAt)
                if let last = lastWindow[state.kind], last.windowID == window, last.percent >= 50 {
                    let key = "reset:\(state.kind.rawValue):\(window)"
                    if settings.notifyOnReset, markFired(key, kind: .reset, detail: nil) {
                        out.append(AlertNotification(key: key, kind: .reset, title: "\(state.kind.displayName) reset",
                                                     body: "Your \(state.kind.displayName.lowercased()) allowance has reset."))
                    }
                }
            case .unavailable:
                break
            }

            // Stale data while the user is demonstrably working means the quota feed stopped.
            if let freshness = state.freshness {
                let was = previousFreshness[state.kind]
                previousFreshness[state.kind] = freshness
                if freshness == .stale, was != nil, was != .stale, recentLocalActivity, settings.notifyOnStaleData,
                   case .available = state.availability {
                    let key = "stale:\(state.kind.rawValue):\(Clock.ms(reading.observedAt))"
                    if markFired(key, kind: .staleData, detail: nil) {
                        out.append(AlertNotification(key: key, kind: .staleData, title: "Quota data is out of date",
                                                     body: "The \(state.kind.displayName.lowercased()) figure has not updated for over an hour, although Claude Code is being used. Check that the status line helper is still installed."))
                    }
                }
            }
        }

        for source in sources {
            let prefix = "fail:\(source.sourceID):"
            if source.hasPersistentFailure, let error = source.lastError {
                let key = prefix + String(error.hashValue)
                if settings.notifyOnCollectionFailure, markFired(key, kind: .collectionFailure, detail: error) {
                    out.append(AlertNotification(key: key, kind: .collectionFailure,
                                                 title: "Usage collection is failing", body: error))
                }
            } else if source.state == .ok {
                // The source has recovered, so forget the old failure to let a later one be announced again.
                for key in fired where key.hasPrefix(prefix) { forget(key) }
            }
        }
        return settings.enabled ? out : []
    }

    private func rememberWindow(_ kind: QuotaWindowKind, _ window: Int64, _ percent: Double) {
        lastWindow[kind] = (window, percent)
        _ = try? db.setSetting("alert_last_window_\(kind.rawValue)", "\(window)|\(percent)")
    }

    @discardableResult
    private func markFired(_ key: String, kind: AlertKind, detail: String?) -> Bool {
        guard fired.insert(key).inserted else { return false }
        _ = try? db.write { c in
            try c.run("INSERT OR IGNORE INTO alert_fired(key, kind, fired_at, detail) VALUES(?, ?, ?, ?)",
                      [.text(key), .text(kind.rawValue), .int(Clock.nowMs()), .optional(detail)])
        }
        return true
    }

    private func forget(_ key: String) {
        fired.remove(key)
        _ = try? db.write { c in try c.run("DELETE FROM alert_fired WHERE key = ?", [.text(key)]) }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}
