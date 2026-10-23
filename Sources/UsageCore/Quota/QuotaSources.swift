import Foundation

/// The locations of the files that Tokenwatch and Claude Code keep their quota data in.
public enum QuotaPaths {
    /// This enum names where the database and quota files live. The environment variable lets tests and
    /// experiments run against a scratch folder without touching the real data.
    public static var applicationSupport: URL {
        if let override = ProcessInfo.processInfo.environment["TOKENWATCH_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tokenwatch")
    }
    public static var databaseURL: URL { applicationSupport.appendingPathComponent("usage.sqlite") }
    /// This is Claude Code's data folder (`~/.claude`). The environment variable points experiments and load
    /// tests at a scratch copy.
    public static var claudeHome: URL {
        if let override = ProcessInfo.processInfo.environment["TOKENWATCH_CLAUDE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    /// The directory that holds Claude Code's `.claude.json` state file. The documented `CLAUDE_CONFIG_DIR` variable
    /// moves that file; a relative or tilde-prefixed value is ignored because Claude Code requires an absolute path.
    public static var claudeConfigDirectory: URL {
        if let raw = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    /// Claude Code's local state file, which contains the last usage snapshot inside `cachedUsageUtilization`.
    ///
    /// This is not the same file as Claude Desktop's plan-usage cache. A GUI app launched from Finder does not inherit
    /// a shell-only `CLAUDE_CONFIG_DIR`; the diagnostics screen names the path that was actually used.
    public static var claudeCodeCache: URL {
        if let override = ProcessInfo.processInfo.environment["TOKENWATCH_CLAUDE_CACHE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return claudeConfigDirectory.appendingPathComponent(".claude.json")
    }
    public static var desktopPlanUsageCache: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }
}

/// How far into the future a quota reading may be dated before it is rejected as a clock error.
enum QuotaStaleness {
    static let futureSkew: TimeInterval = 5 * 60
}

/// How a source's readings age and how much its observation is trusted when several sources report the same moment.
///
/// This is provider knowledge, so it lives with the provider's quota sources rather than in the shared evaluator.
public enum QuotaSourcePolicy {
    public static func thresholds(for source: TelemetrySourceID,
                                  defaults: (fresh: TimeInterval, aging: TimeInterval)) -> (fresh: TimeInterval, aging: TimeInterval) {
        if source == .claudeCodeCache { return (60 * 60, 2 * 60 * 60) }
        return defaults
    }

    public static func priority(for source: TelemetrySourceID) -> Int {
        switch source {
        case .claudeCodeCache: 2
        case .claudeDesktopCache: 1
        default: 2
        }
    }
}

/// Which local Claude source is supplying the figure that the interface is currently showing.
public enum ClaudeQuotaConnection: Sendable, Equatable {
    case localCache(observedAt: Date, freshness: QuotaFreshness)
    case stale(source: TelemetrySourceID, observedAt: Date)
    case noData
    case collectionError(QuotaFeedIssue)

    /// Chooses the connection state from the already-evaluated Anthropic pools. It never infers a percentage: an
    /// absent reading stays absent, and a source error is reported only when no reading is available.
    public static func evaluate(pools: [QuotaPoolState], feeds: [QuotaFeedStatus]) -> ClaudeQuotaConnection {
        let allReadings = pools.filter { $0.pool.key.provider == .anthropic }
            .flatMap(\.windows)
            .compactMap { window -> (QuotaWindowState, QuotaReading)? in
                // Only the local cache describes this connection. The opt-in Desktop hint is unverified and must not be
                // reported as if it were the local cache.
                guard let reading = window.reading, reading.authority == .authoritative, reading.source == .claudeCodeCache else { return nil }
                return (window, reading)
            }
        // The shared five-hour and weekly windows describe the subscription as a whole. A model-scoped window can
        // have a different age, so it must not decide which source the diagnostics screen names.
        let sharedReadings = allReadings.filter {
            $0.0.windowMinutes != nil && WindowNaming.scopedLabel(fallbackKey: $0.0.windowKey) == nil
        }
        let readings = sharedReadings.isEmpty ? allReadings : sharedReadings
        if let newest = readings.max(by: { $0.1.observedAt < $1.1.observedAt }) {
            let (window, reading) = newest
            if window.freshness == .stale {
                return .stale(source: reading.source, observedAt: reading.observedAt)
            }
            return .localCache(observedAt: reading.observedAt, freshness: window.freshness ?? .fresh)
        }
        if let cache = feeds.first(where: { $0.id == .claudeCodeCache }), let issue = cache.issue {
            return .collectionError(issue)
        }
        return .noData
    }

}


/// The quota pool that Claude Code's rate limits belong to.
public enum ClaudeQuota {
    public static let poolKey = "claude-subscription"

    /// Translates the window names that Claude uses (`five_hour`, `seven_day`) into window keys. A window with a fixed length is keyed by its length in minutes, like every other provider's.
    static func window(named name: String) -> (key: String, minutes: Int?)? {
        switch name {
        case "five_hour": (WindowNaming.key(minutes: 300), 300)
        case "seven_day": (WindowNaming.key(minutes: 10080), 10080)
        default: nil
        }
    }

    static func observation(window: (key: String, minutes: Int?), percent: Double, resetsAt: Date?, observedAt: Date,
                            account: AccountRef = .unassigned(.anthropic), source: TelemetrySourceID,
                            authority: QuotaAuthority, originSession: String?) -> QuotaObservation {
        QuotaObservation(provider: .anthropic, account: account, poolKey: poolKey, windowKey: window.key,
                         windowMinutes: window.minutes, utilizationPercent: percent, resetsAt: resetsAt, observedAt: observedAt,
                         source: source, authority: authority,
                         originProduct: originSession == nil ? nil : .claudeCode, originSession: originSession)
    }
}

/// Reads the plan-usage samples that Claude Desktop caches locally.
///
/// This file is not a documented interface. Its field names suggest that `fh` and `sd` are the
/// five-hour and seven-day percentages, but nothing confirms the meaning, and it carries no reset
/// times. Readings from it are therefore marked unverified, are only shown when the user opts in,
/// and are never used for alerts.
public enum DesktopPlanUsageSource {
    public static func observations(at url: URL = QuotaPaths.desktopPlanUsageCache) -> [QuotaObservation] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = object["samples"] as? [[String: Any]] else { return [] }
        guard let latest = samples.max(by: { (($0["t"] as? NSNumber)?.int64Value ?? 0) < (($1["t"] as? NSNumber)?.int64Value ?? 0) }),
              let t = (latest["t"] as? NSNumber)?.int64Value,
              let usage = latest["u"] as? [String: Any] else { return [] }
        let observed = Clock.date(ms: t)
        if observed.timeIntervalSinceNow > QuotaStaleness.futureSkew { return [] }
        var out: [QuotaObservation] = []
        for (field, name) in [("fh", "five_hour"), ("sd", "seven_day")] {
            if let value = (usage[field] as? NSNumber)?.doubleValue, value.isFinite, value >= 0, let mapped = ClaudeQuota.window(named: name) {
                out.append(ClaudeQuota.observation(window: mapped, percent: value, resetsAt: nil, observedAt: observed,
                                                   source: .claudeDesktopCache, authority: .unverified, originSession: nil))
            }
        }
        return out
    }
}


/// Claude Desktop's undocumented plan-usage cache, read as a quota feed that the user has to switch on.
public struct ClaudeDesktopCacheFeed: QuotaFeed {
    public var url: URL
    public init(url: URL = QuotaPaths.desktopPlanUsageCache) { self.url = url }
    public var id: TelemetrySourceID { .claudeDesktopCache }
    public var watchRoots: [URL] { [] }
    public var requiresOptIn: Bool { true }
    public func observations(now: Date) -> [QuotaObservation] { DesktopPlanUsageSource.observations(at: url) }
}

public extension Array where Element == any QuotaFeed {
    /// The feeds that Claude provides, in the places they normally live. The local cache needs no setup; the Desktop
    /// hint is read only when the user opts in.
    static func claude(desktopCache: URL = QuotaPaths.desktopPlanUsageCache,
                       cache: URL = QuotaPaths.claudeCodeCache) -> [any QuotaFeed] {
        [ClaudeCodeCacheFeed(url: cache), ClaudeDesktopCacheFeed(url: desktopCache)]
    }
}
