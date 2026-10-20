import Foundation

/// What the menu bar item shows next to its icon.
///
/// A provider's quota is chosen by naming the provider, so that adding a provider adds a choice without changing this
/// type. The value is stored as a short string, for example `quota:anthropic`.
public enum MenuBarDisplayMode: Hashable, Sendable, Codable, Identifiable {
    case iconOnly
    /// The short and the long window of one provider's primary pool.
    case quota(ProviderID)
    /// The short window of each provider, side by side.
    case allProviders
    /// The single highest utilization among all pools that have a displayable reading. This is a comparison
    /// between pools, not a sum.
    case highestUtilization
    case activeSessions

    public var id: String { rawValue }

    public var rawValue: String {
        switch self {
        case .iconOnly: "iconOnly"
        case .quota(let provider): "quota:" + provider.rawValue
        case .allProviders: "allProviders"
        case .highestUtilization: "highestUtilization"
        case .activeSessions: "activeSessions"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "iconOnly": self = .iconOnly
        case "allProviders": self = .allProviders
        case "highestUtilization": self = .highestUtilization
        case "activeSessions": self = .activeSessions
        default:
            guard rawValue.hasPrefix("quota:"), rawValue.count > 6 else { return nil }
            self = .quota(ProviderID(rawValue: String(rawValue.dropFirst(6))))
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // A value this version does not know falls back to showing both providers rather than failing to load.
        self = Self(rawValue: raw) ?? .allProviders
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Every choice for the given providers, in the order a picker lists them.
    public static func choices(for providers: [ProviderDefinition]) -> [MenuBarDisplayMode] {
        [.iconOnly] + providers.map { .quota($0.id) } + [.allProviders, .highestUtilization, .activeSessions]
    }

    public func label(providers: [ProviderDefinition]) -> String {
        switch self {
        case .iconOnly: "Icon only"
        case .quota(let id): (providers.first { $0.id == id }?.shortName ?? id.rawValue) + " quota"
        case .allProviders: "Quota of every provider"
        case .highestUtilization: "Highest utilization"
        case .activeSessions: "Active session count"
        }
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
}

public struct NotificationSettings: Codable, Equatable, Sendable {
    /// Notifications are opt-in.
    public var enabled = false
    /// Utilization levels that raise an alert for a window of a day or less.
    public var shortWindowThresholds: [Int] = [50, 75, 90]
    /// Utilization levels that raise an alert for a longer window.
    public var longWindowThresholds: [Int] = [75, 90]
    public var notifyOnReset = true
    public var notifyOnStaleData = true
    public var notifyOnCollectionFailure = true
    public init() {}
}

/// These are the user preferences, stored as one JSON document in the `setting` table.
public struct AppSettings: Codable, Equatable, Sendable {
    public var menuBarMode: MenuBarDisplayMode = .allProviders
    public var appearance: AppearanceMode = .system
    public var showEstimatedCost = true
    /// Whether the app keeps a Dock icon even when its menu bar icon is visible.
    public var showDockIcon = false
    /// Days of history to keep. Zero keeps everything.
    public var retentionDays = 0
    public var notifications = NotificationSettings()
    /// How often the quota files are re-read as a safety net when no file event arrives.
    public var quotaRefreshSeconds = 60
    /// Whether to show quota figures from sources whose meaning is undocumented. They are always labelled as
    /// unverified and are never used for alerts or the menu bar. Off by default.
    public var showUnverifiedQuota = false
    public var activeWithinSeconds = 120
    public var idleWithinMinutes = 60
    public var disabledSources: Set<String> = []
    /// Directory exports are saved to by default. Empty means ask each time.
    public var exportDirectory = ""

    public init() {}

    public static let quotaRefreshRange = 30...3600

    public var statusPolicy: StatusPolicy {
        var p = StatusPolicy()
        p.activeWithin = TimeInterval(activeWithinSeconds)
        p.idleWithin = TimeInterval(idleWithinMinutes * 60)
        return p
    }

    public var retentionFloorMs: Int64? {
        retentionDays > 0 ? Clock.nowMs() - Int64(retentionDays) * 86_400_000 : nil
    }

    /// Clamps values into their supported ranges.
    public func normalized() -> AppSettings {
        var s = self
        s.quotaRefreshSeconds = min(max(s.quotaRefreshSeconds, Self.quotaRefreshRange.lowerBound), Self.quotaRefreshRange.upperBound)
        s.retentionDays = max(0, s.retentionDays)
        s.activeWithinSeconds = min(max(s.activeWithinSeconds, 15), 3600)
        s.idleWithinMinutes = min(max(s.idleWithinMinutes, 1), 24 * 60)
        s.notifications.shortWindowThresholds = Array(Set(s.notifications.shortWindowThresholds.map { min(max($0, 1), 100) })).sorted()
        s.notifications.longWindowThresholds = Array(Set(s.notifications.longWindowThresholds.map { min(max($0, 1), 100) })).sorted()
        return s
    }
}

/// Loads and saves `AppSettings`, and holds the current value for synchronous readers such as the
/// retention filter used while importing.
public final class SettingsStore: @unchecked Sendable {
    private let db: UsageDatabase
    private let lock = NSLock()
    private var current: AppSettings

    static let key = "app_settings"

    public init(db: UsageDatabase) {
        self.db = db
        let stored = try? db.read { c in
            try c.queryOne("SELECT value FROM setting WHERE key = ?", [.text(Self.key)]) { $0.text(0) }
        }
        if let json = stored ?? nil, let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            current = decoded.normalized()
        } else {
            current = AppSettings()
        }
    }

    public var value: AppSettings {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func update(_ change: (inout AppSettings) -> Void) {
        lock.lock()
        var next = current
        change(&next)
        next = next.normalized()
        current = next
        lock.unlock()
        if let data = try? JSONEncoder().encode(next), let json = String(data: data, encoding: .utf8) {
            _ = try? db.write { c in
                try c.run("""
                    INSERT INTO setting(key, value, updated_at) VALUES(?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                    """, [.text(Self.key), .text(json), .int(Clock.nowMs())])
            }
        }
    }
}
