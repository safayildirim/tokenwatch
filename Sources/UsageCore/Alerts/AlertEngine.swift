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
/// - An alert is tied to one cycle of one window of one pool of one account. Two accounts, two pools
///   or two products that share a pool therefore never raise each other's alerts or hide them.
/// - A threshold alert is raised once per crossing. Re-reading the same value, or reading it again after
///   the data went stale and was refreshed, raises nothing.
/// - If usage jumps over several thresholds at once, only the highest is announced.
/// - Stale-data and failure alerts fire once per episode.
public final class AlertEngine: @unchecked Sendable {
    private let db: UsageDatabase
    private let lock = NSLock()
    private var fired: Set<String>
    private var lastCycle: [String: (cycleID: Int64, percent: Double)] = [:]
    private var loadedWindows: Set<String> = []
    private var previousFreshness: [String: QuotaFreshness] = [:]

    public init(db: UsageDatabase) {
        self.db = db
        fired = Set((try? db.read { c in try c.query("SELECT key FROM alert_fired") { $0.text(0) } }) ?? [])
    }

    /// Names a window for the person reading the notification.
    static func label(_ state: QuotaWindowState) -> String {
        var text = "\(state.pool.name) \(state.displayName.lowercased())"
        if state.pool.accountLabel != "Unassigned" { text += " (\(state.pool.accountLabel))" }
        return text
    }

    private func recall(_ id: String) {
        guard loadedWindows.insert(id).inserted, let raw = db.setting("alert_last_cycle:" + id) else { return }
        let parts = raw.split(separator: "|")
        if parts.count == 2, let cycle = Int64(parts[0]), let pct = Double(parts[1]) { lastCycle[id] = (cycle, pct) }
    }

    /// Evaluates the current window states. `activeProviders` names the providers whose products were used
    /// recently, which turns a silent quota feed into a worthwhile warning.
    public func evaluate(states: [QuotaWindowState], sources: [SourceHealth], activeProviders: Set<ProviderID>,
                         settings: NotificationSettings, now: Date = Date()) -> [AlertNotification] {
        lock.lock(); defer { lock.unlock() }
        var out: [AlertNotification] = []

        for state in states where state.windowMinutes != nil {
            guard let reading = state.reading, reading.authority == .authoritative, let cycle = reading.cycleID else { continue }
            let id = state.id
            recall(id)
            let thresholds = state.isShort ? settings.shortWindowThresholds : settings.longWindowThresholds
            let label = Self.label(state)

            switch state.availability {
            case .available:
                if let reset = reading.resetsAt {
                    // A new cycle following an old one whose end has passed is a reset.
                    if let last = lastCycle[id], last.cycleID != cycle, last.percent >= 50 {
                        let key = "reset:\(id):\(last.cycleID)"
                        if settings.notifyOnReset, markFired(key, kind: .reset, detail: nil) {
                            out.append(AlertNotification(key: key, kind: .reset, title: "\(label.capitalizedFirst) reset",
                                                         body: "Your \(label) allowance has reset."))
                        }
                    }
                    remember(id, cycle, reading.utilizationPercent)

                    if state.isAlertEligible {
                        let crossed = thresholds.filter { Double($0) <= reading.utilizationPercent }.sorted()
                        let unannounced = crossed.filter { !fired.contains("thr:\(id):\(cycle):\($0)") }
                        if let highest = unannounced.last {
                            for t in unannounced { _ = markFired("thr:\(id):\(cycle):\(t)", kind: .threshold, detail: nil) }
                            if settings.enabled {
                                out.append(AlertNotification(
                                    key: "thr:\(id):\(cycle):\(highest)", kind: .threshold,
                                    title: "\(label.capitalizedFirst) at \(Int(reading.utilizationPercent.rounded()))%",
                                    body: "You have used \(Int(reading.utilizationPercent.rounded()))% of your \(label) allowance."
                                        + " It resets \(Self.relative(reset, now: now))."))
                            }
                        }
                    }
                }
            case .windowElapsed:
                if let last = lastCycle[id], last.cycleID == cycle, last.percent >= 50 {
                    let key = "reset:\(id):\(cycle)"
                    if settings.notifyOnReset, markFired(key, kind: .reset, detail: nil) {
                        out.append(AlertNotification(key: key, kind: .reset, title: "\(label.capitalizedFirst) reset",
                                                     body: "Your \(label) allowance has reset."))
                    }
                }
            case .unavailable:
                break
            }

            // Stale data while the user is demonstrably working means the quota feed stopped.
            if let freshness = state.freshness {
                let was = previousFreshness[id]
                previousFreshness[id] = freshness
                if freshness == .stale, was != nil, was != .stale, activeProviders.contains(state.pool.key.provider),
                   settings.notifyOnStaleData, case .available = state.availability {
                    let key = "stale:\(id):\(Clock.ms(reading.observedAt))"
                    if markFired(key, kind: .staleData, detail: nil) {
                        out.append(AlertNotification(key: key, kind: .staleData, title: "Quota data is out of date",
                                                     body: "The \(label) figure has not updated for over an hour, although you are using \(state.pool.name). Quota figures only update while a supported app is making requests."))
                    }
                }
            }
        }

        for source in sources {
            let prefix = "fail:\(source.sourceID.rawValue):"
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

    private func remember(_ id: String, _ cycle: Int64, _ percent: Double) {
        lastCycle[id] = (cycle, percent)
        _ = try? db.setSetting("alert_last_cycle:" + id, "\(cycle)|\(percent)")
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

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
