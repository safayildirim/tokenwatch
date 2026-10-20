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

/// Reads quota readings from the status line bridge's files.
public enum StatusLineQuotaSource {
    public static let providerID = "claude-code-statusline"

    public static func readings(in directory: URL, now: Date = Date()) -> [QuotaReading] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [QuotaReading] = []
        for name in names where name.hasPrefix("statusline-") && name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = fm.contents(atPath: url.path),
                  let file = try? JSONDecoder().decode(QuotaBridgeFile.self, from: data), file.schema == 1 else { continue }
            let observed = Clock.date(ms: file.observedAt)
            // Files from long-dead sessions are cleaned up so that the folder does not grow forever.
            if now.timeIntervalSince(observed) > 14 * 86400 { try? fm.removeItem(at: url); continue }
            for (key, window) in file.rateLimits {
                guard let kind = QuotaWindowKind(rawValue: key), window.usedPercentage.isFinite, window.usedPercentage >= 0 else { continue }
                out.append(QuotaReading(kind: kind, utilizationPercent: window.usedPercentage,
                                        resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
                                        observedAt: observed, provider: providerID, authority: .authoritative,
                                        origin: file.sessionId))
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
    public static let providerID = "claude-desktop-cache"

    public static func readings(at url: URL = QuotaPaths.desktopPlanUsageCache) -> [QuotaReading] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = object["samples"] as? [[String: Any]] else { return [] }
        guard let latest = samples.max(by: { (($0["t"] as? NSNumber)?.int64Value ?? 0) < (($1["t"] as? NSNumber)?.int64Value ?? 0) }),
              let t = (latest["t"] as? NSNumber)?.int64Value,
              let usage = latest["u"] as? [String: Any] else { return [] }
        let observed = Clock.date(ms: t)
        var out: [QuotaReading] = []
        if let fh = (usage["fh"] as? NSNumber)?.doubleValue {
            out.append(QuotaReading(kind: .fiveHour, utilizationPercent: fh, resetsAt: nil, observedAt: observed,
                                    provider: providerID, authority: .unverified))
        }
        if let sd = (usage["sd"] as? NSNumber)?.doubleValue {
            out.append(QuotaReading(kind: .sevenDay, utilizationPercent: sd, resetsAt: nil, observedAt: observed,
                                    provider: providerID, authority: .unverified))
        }
        return out
    }
}
