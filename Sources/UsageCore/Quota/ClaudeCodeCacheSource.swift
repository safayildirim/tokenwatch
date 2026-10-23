import Darwin
import Foundation

/// The result of one careful read of Claude Code's local usage cache.
public struct ClaudeCodeCacheReading: Sendable, Equatable {
    public var observations: [QuotaObservation]
    public var sourceExists: Bool
    public var issue: QuotaFeedIssue?
    /// The time Claude Code says it fetched the usage. This is the observation time; the file's modification time is
    /// never used, because unrelated settings writes also touch the file.
    public var fetchedAt: Date?
    /// A one-way hash of the account identifier, used only to notice a change. The raw identifier is not retained.
    public var accountFingerprint: String?
    /// Number of windows that were present but could not be used. They are skipped individually.
    public var skippedWindowCount: Int
}

/// Reads the usage snapshot that Claude Code keeps in its configuration file.
///
/// Claude Code writes `cachedUsageUtilization` inside `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`). The
/// cache is not a documented integration contract: its layout can change without notice, and it is refreshed when
/// Claude Code fetches usage rather than continuously. The adapter therefore reads only that one object, never
/// credentials or conversation data, and reports its source and timestamp explicitly.
///
/// The file can be large and contains unrelated account and project settings. The cursor walks the top-level object
/// and skips everything except `cachedUsageUtilization`, so no unrelated value is materialized. The file is opened
/// read-only with `O_NOFOLLOW`, must be a regular file owned by the current user, and is limited to 16 MiB.
public enum ClaudeCodeCacheSource {
    public static let maximumBytes = 16 * 1024 * 1024
    private static let minimumPlausible = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
    private static let maximumModelLimits = 16
    private static let maximumModelLabelLength = 64
    private static let maximumModelIdentifierLength = 256

    private enum ReadFailure: Error {
        case absent
        case unreadable
        case tooLarge
    }

    public static func read(at url: URL = QuotaPaths.claudeCodeCache, now: Date = Date()) -> ClaudeCodeCacheReading {
        let data: Data
        do {
            data = try readSafely(url)
        } catch ReadFailure.absent {
            return ClaudeCodeCacheReading(observations: [], sourceExists: false, issue: nil, fetchedAt: nil,
                                          accountFingerprint: nil, skippedWindowCount: 0)
        } catch ReadFailure.tooLarge {
            return ClaudeCodeCacheReading(observations: [], sourceExists: true, issue: .fileTooLarge, fetchedAt: nil,
                                          accountFingerprint: nil, skippedWindowCount: 0)
        } catch {
            return ClaudeCodeCacheReading(observations: [], sourceExists: true, issue: .unreadable, fetchedAt: nil,
                                          accountFingerprint: nil, skippedWindowCount: 0)
        }
        return parse(data, now: now, sourceExists: true)
    }

    /// Parses bytes already read from the cache. Kept separate so tests can exercise every malformed shape without
    /// creating a privileged file.
    public static func parse(_ data: Data, now: Date, sourceExists: Bool = true) -> ClaudeCodeCacheReading {
        func failure(_ issue: QuotaFeedIssue, skipped: Int = 0) -> ClaudeCodeCacheReading {
            ClaudeCodeCacheReading(observations: [], sourceExists: sourceExists, issue: issue, fetchedAt: nil,
                                   accountFingerprint: nil, skippedWindowCount: skipped)
        }
        guard !data.isEmpty else { return failure(.invalidJSON) }
        return data.withUnsafeBytes { bytes -> ClaudeCodeCacheReading in
            var root = JSONCursor(UnsafeBufferPointer(start: bytes.bindMemory(to: UInt8.self).baseAddress,
                                                      count: bytes.count))
            var raw: RawCache?
            var seenUsage = false
            var duplicateUsage = false
            var malformedUsageObject = false

            let validObject = root.forEachMember { cursor, key in
                guard cursor.equals(key, "cachedUsageUtilization") else { return false }
                guard !seenUsage else { duplicateUsage = true; return false }
                seenUsage = true
                if cursor.readNull() { return true }
                guard cursor.peek == 0x7B else { malformedUsageObject = true; return false }
                var parsed = RawCache()
                guard parseCacheObject(&cursor, into: &parsed) else { malformedUsageObject = true; return false }
                raw = parsed
                return true
            }
            root.skipWhitespace()
            guard validObject, !duplicateUsage, !malformedUsageObject, root.i == root.end else {
                return failure(.invalidJSON)
            }
            guard seenUsage, let raw else { return failure(.noUsageData) }

            guard let fetchedMs = raw.fetchedAtMs else { return failure(.invalidTimestamp) }
            let fetchedAt = Clock.date(ms: fetchedMs)
            guard fetchedMs > 0, fetchedAt >= minimumPlausible,
                  fetchedAt.timeIntervalSince(now) <= QuotaStaleness.futureSkew else {
                return failure(.invalidTimestamp)
            }
            guard let rawAccount = raw.accountUuid,
                  let account = accountReference(rawAccount),
                  let accountHash = account.hash else {
                return failure(.invalidAccount)
            }
            guard let utilization = raw.utilization else { return failure(.noUsageData) }

            var observations: [QuotaObservation] = []
            var skipped = utilization.malformedWindowCount

            func addShared(_ named: String, fallback: RawWindow?) {
                guard let mapped = ClaudeQuota.window(named: named) else { return }
                let candidate: RawWindow?
                if let direct = utilization.shared[named] {
                    // An object that is present but has no percentage is incomplete. The structured limit of the same
                    // snapshot is a legitimate fallback; an invalid percentage is not, because it may be ambiguous.
                    if case .missing = direct.percent { candidate = fallback ?? direct }
                    else { candidate = direct }
                } else {
                    candidate = fallback
                }
                guard let window = candidate else { return }
                switch window.percent {
                case .valid(let value):
                    guard window.resetInvalid == false else { skipped += 1; return }
                    observations.append(ClaudeQuota.observation(
                        window: mapped, percent: value, resetsAt: window.reset, observedAt: fetchedAt,
                        account: account, source: .claudeCodeCache, authority: .authoritative, originSession: nil))
                case .invalid:
                    skipped += 1
                case .missing:
                    break
                }
            }

            let sessionFallback = utilization.limits.first { $0.kind == "session" }?.window
            let weeklyFallback = utilization.limits.first { $0.kind == "weekly_all" }?.window
            addShared("five_hour", fallback: sessionFallback)
            addShared("seven_day", fallback: weeklyFallback)
            // A spend limit is a different kind of allowance; it is not a subscription percentage and is deliberately
            // not synthesized from cache fields whose meaning is not established.

            var usedScopedKeys: Set<String> = []
            var usedScopedLabels: Set<String> = []
            var usedScopedLimits = 0
            for limit in utilization.limits where limit.kind == "weekly_scoped" {
                guard usedScopedLimits < maximumModelLimits else { skipped += 1; continue }
                guard let window = limit.window, let percent = window.percent.value else {
                    skipped += 1
                    continue
                }
                guard window.resetInvalid == false else { skipped += 1; continue }
                let identity = limit.identity ?? limit.label.map { "name:\($0.lowercased())" }
                // The displayed name is optional in the source. A model identifier is a safe, if technical, fallback;
                // without either, the limit cannot be told apart from another scoped window and is skipped.
                let label = limit.label ?? limit.identity.map { raw in
                    let value = raw.hasPrefix("id:") ? String(raw.dropFirst(3)) : raw
                    return String(value.prefix(maximumModelLabelLength))
                }
                guard let identity, let label else {
                    skipped += 1
                    continue
                }
                let key = WindowNaming.scopedKey(minutes: 10080, identity: identity, label: label)
                guard usedScopedKeys.insert(key).inserted, observations.count < 128 else { skipped += 1; continue }
                usedScopedLimits += 1
                usedScopedLabels.insert(label.lowercased())
                observations.append(ClaudeQuota.observation(
                    window: (key, 10080), percent: percent, resetsAt: window.reset, observedAt: fetchedAt,
                    account: account, source: .claudeCodeCache, authority: .authoritative, originSession: nil))
            }
            // Older caches used these two flat fields. They are accepted only for models that the structured list did
            // not already describe, so a cache that has both shapes never produces a duplicate window.
            for (field, label) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                guard let window = utilization.legacy[field], let percent = window.percent.value else { continue }
                guard window.resetInvalid == false else { skipped += 1; continue }
                // The structured list may already describe this model with an identifier but the same display name.
                // In that case the legacy field is the same window under an older schema, not a second window.
                guard !usedScopedLabels.contains(label.lowercased()) else { continue }
                guard usedScopedLimits < maximumModelLimits, observations.count < 128 else { skipped += 1; continue }
                let key = WindowNaming.scopedKey(minutes: 10080, identity: "name:\(label.lowercased())", label: label)
                guard usedScopedKeys.insert(key).inserted else { continue }
                usedScopedLimits += 1
                usedScopedLabels.insert(label.lowercased())
                observations.append(ClaudeQuota.observation(
                    window: (key, 10080), percent: percent, resetsAt: window.reset, observedAt: fetchedAt,
                    account: account, source: .claudeCodeCache, authority: .authoritative, originSession: nil))
            }

            // Keep the ordering deterministic: the shared windows first, then scoped windows by key.
            if observations.isEmpty {
                return ClaudeCodeCacheReading(observations: [], sourceExists: sourceExists,
                                              issue: skipped > 0 ? .malformedWindow : .noUsageData, fetchedAt: fetchedAt,
                                              accountFingerprint: accountHash, skippedWindowCount: skipped)
            }
            let shared = observations.filter { WindowNaming.scopedLabel(fallbackKey: $0.windowKey) == nil }
            let scoped = observations.filter { WindowNaming.scopedLabel(fallbackKey: $0.windowKey) != nil }
                .sorted { $0.windowKey < $1.windowKey }
            return ClaudeCodeCacheReading(observations: Array(shared) + scoped, sourceExists: sourceExists,
                                          issue: skipped > 0 ? .malformedWindow : nil, fetchedAt: fetchedAt,
                                          accountFingerprint: accountHash, skippedWindowCount: skipped)
        }
    }

    /// The stable, non-reversible account reference for a cache snapshot. Cache observations use it, so two accounts
    /// never share a quota pool. Readings from sources that name no account stay unassigned; matching them to this
    /// account by timestamp or percentage would be a guess.
    ///
    /// Only the short hash leaves the parser; the UUID is not stored anywhere.
    public static func accountReference(_ raw: String) -> AccountRef? {
        guard uuidIsWellFormed(raw) else { return nil }
        return .identified(provider: .anthropic, rawIdentifier: raw.lowercased())
    }

    /// The one-way account fingerprint used only to notice that the signed-in account changed.
    public static func accountFingerprint(_ raw: String) -> String? {
        accountReference(raw)?.hash
    }

    private static func uuidIsWellFormed(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (i, b) in bytes.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                guard b == 0x2D else { return false }
            } else {
                guard (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66) else { return false }
            }
        }
        return true
    }

    // MARK: Safe file reading

    private static func readSafely(_ url: URL) throws -> Data {
        let path = url.path
        // `O_NONBLOCK` keeps a FIFO or another non-regular file from blocking this actor while it is being opened.
        // The file-type check below still rejects it; regular files are unaffected.
        let fd = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else {
            if errno == ENOENT { throw ReadFailure.absent }
            throw ReadFailure.unreadable
        }
        defer { _ = close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ReadFailure.unreadable }
        let fileType = st.st_mode & S_IFMT
        let permissions = st.st_mode & 0o777
        guard fileType == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1 else { throw ReadFailure.unreadable }
        // The file contains the user's account state. Refuse a copy that other users can read or modify, rather than
        // silently accepting a source whose provenance is no longer private.
        guard permissions & 0o077 == 0 else { throw ReadFailure.unreadable }
        guard st.st_size >= 0 else { throw ReadFailure.unreadable }
        guard st.st_size <= maximumBytes else { throw ReadFailure.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(st.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ReadFailure.unreadable
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.count > maximumBytes { throw ReadFailure.tooLarge }
        }
        return data
    }

    // MARK: Cursor parsing

    private struct RawCache {
        var fetchedAtMs: Int64?
        var accountUuid: String?
        var utilization: RawUtilization?
    }

    private struct RawUtilization {
        var shared: [String: RawWindow] = [:]
        var limits: [RawLimit] = []
        var legacy: [String: RawWindow] = [:]
        var malformedWindowCount = 0
    }

    private struct RawLimit {
        var kind: String
        var window: RawWindow?
        var label: String?
        var identity: String?
    }

    private struct RawWindow {
        enum Percent {
            case missing
            case valid(Double)
            case invalid
            var value: Double? { if case .valid(let v) = self { return v }; return nil }
        }
        var percent: Percent = .missing
        var reset: Date?
        /// A reset was present but was not a valid ISO 8601 timestamp. The window is skipped rather than shown with
        /// an invented reset boundary.
        var resetInvalid = false
    }

    private static func parseCacheObject(_ c: inout JSONCursor, into raw: inout RawCache) -> Bool {
        var seenFetched = false, seenAccount = false, seenUtilization = false
        var duplicate = false
        let ok = c.forEachMember { cursor, key in
            if cursor.equals(key, "fetchedAtMs") {
                guard !seenFetched else { duplicate = true; return false }
                seenFetched = true
                guard let value = cursor.readExactInt() else { return false }
                raw.fetchedAtMs = value
                return true
            }
            if cursor.equals(key, "accountUuid") {
                guard !seenAccount else { duplicate = true; return false }
                seenAccount = true
                guard let s = cursor.readRawString() else { return false }
                raw.accountUuid = cursor.string(s)
                return true
            }
            if cursor.equals(key, "utilization") {
                guard !seenUtilization else { duplicate = true; return false }
                seenUtilization = true
                if cursor.readNull() { return true }
                guard cursor.peek == 0x7B else { return false }
                var parsed = RawUtilization()
                guard parseUtilization(&cursor, into: &parsed) else { return false }
                raw.utilization = parsed
                return true
            }
            return false
        }
        return ok && !duplicate
    }

    private static func parseUtilization(_ c: inout JSONCursor, into raw: inout RawUtilization) -> Bool {
        var seenNames: Set<String> = []
        let ok = c.forEachMember { cursor, key in
            if cursor.equals(key, "five_hour") || cursor.equals(key, "seven_day") {
                let name = cursor.equals(key, "five_hour") ? "five_hour" : "seven_day"
                guard seenNames.insert(name).inserted else { raw.malformedWindowCount += 1; return false }
                if cursor.readNull() { return true }
                guard cursor.peek == 0x7B else { raw.malformedWindowCount += 1; return false }
                var window = RawWindow()
                guard parseWindow(&cursor, into: &window) else { raw.malformedWindowCount += 1; return false }
                raw.shared[name] = window
                return true
            }
            if cursor.equals(key, "seven_day_opus") || cursor.equals(key, "seven_day_sonnet") {
                let name = cursor.equals(key, "seven_day_opus") ? "seven_day_opus" : "seven_day_sonnet"
                guard seenNames.insert(name).inserted else { raw.malformedWindowCount += 1; return false }
                if cursor.readNull() { return true }
                guard cursor.peek == 0x7B else { raw.malformedWindowCount += 1; return false }
                var window = RawWindow()
                guard parseWindow(&cursor, into: &window) else { raw.malformedWindowCount += 1; return false }
                raw.legacy[name] = window
                return true
            }
            if cursor.equals(key, "limits") {
                guard seenNames.insert("limits").inserted else { raw.malformedWindowCount += 1; return false }
                if cursor.readNull() { return true }
                guard cursor.peek == 0x5B else { raw.malformedWindowCount += 1; return false }
                var limits: [RawLimit] = []
                let arrayOK = cursor.forEachElement { element in
                    guard element.peek == 0x7B else { raw.malformedWindowCount += 1; return false }
                    var limit = RawLimit(kind: "")
                    guard parseLimit(&element, into: &limit) else { raw.malformedWindowCount += 1; return false }
                    if limit.kind.isEmpty {
                        raw.malformedWindowCount += 1
                    } else {
                        limits.append(limit)
                    }
                    return true
                }
                guard arrayOK else { raw.malformedWindowCount += 1; return false }
                raw.limits = limits
                return true
            }
            return false
        }
        return ok
    }

    private static func parseWindow(_ c: inout JSONCursor, into raw: inout RawWindow) -> Bool {
        var seenPercent = false, seenReset = false
        var bad = false
        let ok = c.forEachMember { cursor, key in
            if cursor.equals(key, "utilization") || cursor.equals(key, "percent") {
                guard !seenPercent else { bad = true; return false }
                seenPercent = true
                if cursor.readNull() { raw.percent = .invalid; return true }
                guard let value = cursor.readExactDouble(), value.isFinite, value >= 0, value <= 100 else {
                    raw.percent = .invalid
                    bad = true
                    return false
                }
                raw.percent = .valid(value)
                return true
            }
            if cursor.equals(key, "resets_at") {
                guard !seenReset else { bad = true; return false }
                seenReset = true
                if cursor.readNull() { raw.reset = nil; return true }
                guard let s = cursor.readRawString() else { bad = true; return false }
                if let date = parseTimestamp(cursor.string(s)) {
                    raw.reset = date
                } else {
                    raw.resetInvalid = true
                }
                return true
            }
            return false
        }
        if !ok || bad { return false }
        if !seenPercent { raw.percent = .missing }
        return true
    }

    private static func parseLimit(_ c: inout JSONCursor, into raw: inout RawLimit) -> Bool {
        var version = RawWindow()
        var seenKind = false, seenPercent = false, seenReset = false, seenScope = false
        var label: String?
        var identity: String?
        var bad = false
        let ok = c.forEachMember { cursor, key in
            if cursor.equals(key, "kind") {
                guard !seenKind else { bad = true; return false }
                seenKind = true
                guard let s = cursor.readRawString() else { bad = true; return false }
                raw.kind = cursor.string(s)
                return true
            }
            if cursor.equals(key, "percent") {
                guard !seenPercent else { bad = true; return false }
                seenPercent = true
                if cursor.readNull() { version.percent = .invalid; return true }
                guard let value = cursor.readExactDouble(), value.isFinite, value >= 0, value <= 100 else {
                    version.percent = .invalid
                    bad = true
                    return false
                }
                version.percent = .valid(value)
                return true
            }
            if cursor.equals(key, "resets_at") {
                guard !seenReset else { bad = true; return false }
                seenReset = true
                if cursor.readNull() { version.reset = nil; return true }
                guard let s = cursor.readRawString() else { bad = true; return false }
                if let date = parseTimestamp(cursor.string(s)) { version.reset = date }
                else { version.resetInvalid = true }
                return true
            }
            if cursor.equals(key, "scope") {
                guard !seenScope else { bad = true; return false }
                seenScope = true
                if cursor.readNull() { return true }
                guard cursor.peek == 0x7B else { bad = true; return false }
                var scope = RawScope()
                guard parseScope(&cursor, into: &scope) else { bad = true; return false }
                label = scope.label
                identity = scope.identity
                return true
            }
            return false
        }
        guard ok, !bad else { return false }
        raw.window = version
        raw.label = label
        raw.identity = identity
        return true
    }

    private struct RawScope {
        var label: String?
        var identity: String?
    }

    private static func parseScope(_ c: inout JSONCursor, into raw: inout RawScope) -> Bool {
        var bad = false
        var seenModel = false
        let ok = c.forEachMember { cursor, key in
            guard cursor.equals(key, "model") else { return false }
            guard !seenModel else { bad = true; return false }
            seenModel = true
            if cursor.readNull() { return true }
            guard cursor.peek == 0x7B else { bad = true; return false }
            var label: String?
            var identity: String?
            var seenModelID = false
            var seenDisplayName = false
            let modelOK = cursor.forEachMember { model, modelKey in
                if model.equals(modelKey, "id") {
                    guard !seenModelID else { bad = true; return false }
                    seenModelID = true
                    if model.readNull() { return true }
                    guard let s = model.readRawString() else { bad = true; return false }
                    let value = model.string(s).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty, value.count <= maximumModelIdentifierLength,
                          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        bad = true
                        return false
                    }
                    identity = "id:\(value)"
                    return true
                }
                if model.equals(modelKey, "display_name") {
                    guard !seenDisplayName else { bad = true; return false }
                    seenDisplayName = true
                    if model.readNull() { return true }
                    guard let s = model.readRawString() else { bad = true; return false }
                    let value = model.string(s).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty, value.count <= maximumModelLabelLength,
                          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        bad = true
                        return false
                    }
                    label = value
                    return true
                }
                return false
            }
            guard modelOK, !bad else { bad = true; return false }
            raw.label = label
            raw.identity = identity
            return true
        }
        return ok && !bad
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        // ISO8601DateFormatter rejects impossible calendar dates and out-of-range zones, while accepting the
        // fractional and non-fractional forms Claude Code uses. It is created only when a snapshot is parsed, which is
        // at most once per new fetch rather than on every file event.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

/// Claude Code's local cache, read as a quota feed.
public struct ClaudeCodeCacheFeed: QuotaFeed {
    public var url: URL
    public init(url: URL = QuotaPaths.claudeCodeCache) { self.url = url }
    public var id: TelemetrySourceID { .claudeCodeCache }
    public var watchRoots: [URL] { [] }
    /// Watching the file itself avoids subscribing to every event in the user's home directory.
    public var watchFiles: [URL] { [url] }
    public var requiresOptIn: Bool { false }

    public func observations(now: Date) -> [QuotaObservation] {
        ClaudeCodeCacheSource.read(at: url, now: now).observations
    }

    public func read(now: Date) -> QuotaFeedOutput {
        let reading = ClaudeCodeCacheSource.read(at: url, now: now)
        return QuotaFeedOutput(observations: reading.observations, sourcePath: url, sourceExists: reading.sourceExists,
                               issue: reading.issue, accountFingerprint: reading.accountFingerprint)
    }
}
