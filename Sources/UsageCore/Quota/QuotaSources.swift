import Foundation

/// The location of the files that the status line bridge writes.
public enum QuotaPaths {
    /// This enum names where the database and quota files live. The environment variable lets tests and
    /// experiments run against a scratch folder without touching the real data.
    public static var applicationSupport: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_USAGE_MONITOR_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClaudeUsageMonitor")
    }
    public static var bridgeDirectory: URL { applicationSupport.appendingPathComponent("quota") }
    public static var databaseURL: URL { applicationSupport.appendingPathComponent("usage.sqlite") }
    /// This is Claude Code's data folder (`~/.claude`). The environment variable points experiments and load
    /// tests at a scratch copy.
    public static var claudeHome: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_USAGE_MONITOR_CLAUDE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    public static var claudeSettings: URL { claudeHome.appendingPathComponent("settings.json") }
    public static var desktopPlanUsageCache: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }
}

/// The JSON file the status line bridge writes for each Claude Code session.
///
/// Claude Code passes a JSON document to its status line command on every refresh. The documented
/// `rate_limits` object in that document is the authoritative source of subscription utilization:
/// it carries the percentage consumed and the reset time of the five-hour and seven-day windows.
/// The bridge copies only that object, plus a fingerprint used to tell whether the session has made
/// an API call since the previous refresh. No prompt, response or credential is ever present in the
/// input that the bridge keeps.
public struct QuotaBridgeFile: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public var usedPercentage: Double
        /// The value is in Unix epoch seconds.
        public var resetsAt: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    public var schema = 1
    public var sessionId: String
    /// This is the time, in milliseconds since the epoch, at which the session's API activity last changed. This is what
    /// freshness is measured from, not the time the status line merely re-rendered.
    public var observedAt: Int64
    public var capturedAt: Int64
    public var fingerprint: String
    public var rateLimits: [String: Window]

    public init(sessionId: String, observedAt: Int64, capturedAt: Int64, fingerprint: String, rateLimits: [String: Window]) {
        self.sessionId = sessionId
        self.observedAt = observedAt
        self.capturedAt = capturedAt
        self.fingerprint = fingerprint
        self.rateLimits = rateLimits
    }
}

/// How far into the future a quota reading may be dated before it is rejected as a clock error.
enum QuotaStaleness {
    static let futureSkew: TimeInterval = 5 * 60
}

/// The quota pool that Claude Code's rate limits belong to.
public enum ClaudeQuota {
    public static let poolKey = "claude-subscription"

    /// Translates the window names that Claude uses (`five_hour`, `seven_day`, `spend_limit`) into
    /// window keys. A window with a fixed length is keyed by its length in minutes, like every other provider's.
    static func window(named name: String) -> (key: String, minutes: Int?)? {
        switch name {
        case "five_hour": (WindowNaming.key(minutes: 300), 300)
        case "seven_day": (WindowNaming.key(minutes: 10080), 10080)
        case "spend_limit": ("spend_limit", nil)
        default: nil
        }
    }

    static func observation(window: (key: String, minutes: Int?), percent: Double, resetsAt: Date?, observedAt: Date,
                            source: TelemetrySourceID, authority: QuotaAuthority, originSession: String?) -> QuotaObservation {
        QuotaObservation(provider: .anthropic, account: .unassigned(.anthropic), poolKey: poolKey, windowKey: window.key,
                         windowMinutes: window.minutes, utilizationPercent: percent, resetsAt: resetsAt, observedAt: observedAt,
                         source: source, authority: authority,
                         originProduct: originSession == nil ? nil : .claudeCode, originSession: originSession)
    }
}

/// Reads quota readings from the status line bridge's files.
public enum StatusLineQuotaSource {
    public static func observations(in directory: URL, now: Date = Date()) -> [QuotaObservation] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [QuotaObservation] = []
        for name in names where name.hasPrefix("statusline-") && name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = fm.contents(atPath: url.path),
                  let file = try? JSONDecoder().decode(QuotaBridgeFile.self, from: data), file.schema == 1 else { continue }
            let observed = Clock.date(ms: file.observedAt)
            // Files from long-dead sessions are cleaned up so that the folder does not grow forever.
            if now.timeIntervalSince(observed) > 14 * 86400 { try? fm.removeItem(at: url); continue }
            // A reading dated in the future comes from a clock that was wrong when it was written. It would look fresh
            // for as long as the clock stays ahead, so it is not an observation.
            if observed.timeIntervalSince(now) > QuotaStaleness.futureSkew { continue }
            for (key, window) in file.rateLimits {
                guard let mapped = ClaudeQuota.window(named: key), window.usedPercentage.isFinite, window.usedPercentage >= 0 else { continue }
                out.append(ClaudeQuota.observation(
                    window: mapped, percent: window.usedPercentage, resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
                    observedAt: observed, source: .claudeStatusLine, authority: .authoritative, originSession: file.sessionId))
            }
        }
        return out
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


/// The status line helper's folder, read as a quota feed.
public struct ClaudeStatusLineFeed: QuotaFeed {
    public var directory: URL
    public init(directory: URL = QuotaPaths.bridgeDirectory) { self.directory = directory }
    public var id: TelemetrySourceID { .claudeStatusLine }
    public var watchRoots: [URL] { [directory] }
    public var requiresOptIn: Bool { false }
    public func observations(now: Date) -> [QuotaObservation] { StatusLineQuotaSource.observations(in: directory, now: now) }
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
    /// The feeds that Claude provides, in the places they normally live.
    static func claude(bridgeDirectory: URL = QuotaPaths.bridgeDirectory,
                       desktopCache: URL = QuotaPaths.desktopPlanUsageCache) -> [any QuotaFeed] {
        [ClaudeStatusLineFeed(directory: bridgeDirectory), ClaudeDesktopCacheFeed(url: desktopCache)]
    }
}
