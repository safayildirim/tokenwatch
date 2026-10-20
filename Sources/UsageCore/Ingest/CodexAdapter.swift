import Foundation

/// Reads the session files that the Codex engine writes under `~/.codex` (or `$CODEX_HOME`).
///
/// One engine serves several applications: the Codex command line, the Codex desktop app, the IDE plugins and
/// the Work mode of the ChatGPT desktop app. Every session file begins with a header that names the application
/// (`originator`), so a single adapter covers all of them and the header decides which product a session
/// belongs to.
///
/// File layout:
/// - `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl` holds one session while it is active.
/// - `….jsonl.zst` is the same file after Codex has compressed it. A compressed file never changes again.
/// - `archived_sessions/` holds sessions that the user archived, in the same two forms.
///
/// What is read: the session header, the model in use, the token usage records, the quota snapshots and the
/// compaction markers. Message text, tool input and tool output are skipped without being decoded, and nothing
/// from them is stored. `auth.json` and the other files in the folder are never opened.
///
/// How a request is identified:
/// - Newer versions write a `token_usage_record` line for each model response, which carries the response id.
///   That id identifies the request, so reading the same response twice, or once from each of two copies of a
///   session, counts it once.
/// - Older versions only write a `token_count` event after each response. Such an event is identified by its
///   position in its session. The running totals in the event are not used as an identity. They only decide
///   whether an event reports a new response or repeats the previous snapshot, and they are compared with the
///   response's own figures so that a response with no event of its own is noticed and accounted for.
public struct CodexAdapter: SourceAdapter {
    public var sourceID: TelemetrySourceID { .codexRollouts }
    public var displayName: String { "Codex (CLI, Desktop, IDE and ChatGPT Work)" }
    public let home: URL

    public init(home: URL = CodexAdapter.defaultHome) { self.home = CanonicalPath.resolve(home) }

    /// The folder Codex keeps its data in. The tests and experiments can redirect it with
    /// `CLAUDE_USAGE_MONITOR_CODEX_DIR`. Otherwise `CODEX_HOME` applies, as it does for Codex itself.
    public static var defaultHome: URL {
        let env = ProcessInfo.processInfo.environment
        for name in ["CLAUDE_USAGE_MONITOR_CODEX_DIR", "CODEX_HOME"] {
            if let value = env[name], !value.isEmpty { return URL(fileURLWithPath: (value as NSString).expandingTildeInPath) }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public var sessionsDirectory: URL { home.appendingPathComponent("sessions") }
    public var archivedDirectory: URL { home.appendingPathComponent("archived_sessions") }

    public var watchRoots: [URL] { [sessionsDirectory, archivedDirectory] }

    public var coverageNote: String {
        "Reads local Codex session files only. ChatGPT chat conversations leave no usage records on this Mac, so they are not included."
    }

    /// Lines refer to earlier lines (the header names the session, and the running totals tell snapshots from new
    /// responses), so a changed file is always read from the top.
    public var resumesFromCheckpoint: Bool { false }

    public func discoverFiles() throws -> [SourceFileRef] {
        var out: [SourceFileRef] = []
        for (directory, archived) in [(sessionsDirectory, false), (archivedDirectory, true)] {
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if let ref = reference(path: url.path, archived: archived) { out.append(ref) }
            }
        }
        return out
    }

    public func fileRef(forPath path: String) -> SourceFileRef? {
        let sessions = sessionsDirectory.path + "/", archived = archivedDirectory.path + "/"
        if path.hasPrefix(sessions) { return reference(path: path, archived: false) }
        if path.hasPrefix(archived) { return reference(path: path, archived: true) }
        return nil
    }

    private func reference(path: String, archived: Bool) -> SourceFileRef? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") else { return nil }
        return SourceFileRef(sourceID: sourceID, path: path, sessionHint: Self.sessionID(inFileName: name),
                             hints: archived ? ["archived": "1"] : [:])
    }

    /// The session id that a file name ends with, for example `rollout-2026-10-12T12-40-20-<uuid>.jsonl`.
    static func sessionID(inFileName name: String) -> String {
        var stem = name
        for suffix in [".zst", ".jsonl"] where stem.hasSuffix(suffix) { stem = String(stem.dropLast(suffix.count)) }
        // The identifier is the trailing canonical UUID (36 characters). Anything else is returned as it is.
        if stem.count >= 36 {
            let tail = String(stem.suffix(36))
            if tail.filter({ $0 == "-" }).count == 4 { return tail }
        }
        return stem
    }

    public func makeParser(for file: SourceFileRef) -> any LineParser { CodexLineParser(file: file) }

    // MARK: Mapping from the header

    /// Which product and surface an `originator` value identifies. A value that is not recognized is Codex on
    /// an unknown surface, and the `source` field of the header is used as a hint.
    static func classify(originator: String?, source: String?) -> (product: ProductID, surface: SurfaceID) {
        // Originators are words joined by punctuation, such as `codex_work_desktop` or `JetBrains.WebStorm`. They are
        // compared word by word, so that a name merely containing letters of a keyword (`client`) is not mistaken for it.
        let words = Set((originator ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if words.contains("work") { return (.chatGPTWork, .chatGPTDesktop) }
        if words.contains("jetbrains") { return (.codex, .jetbrains) }
        if words.contains("vscode") { return (.codex, .vscode) }
        if words.contains("desktop") { return (.codex, .codexDesktop) }
        if !words.isDisjoint(with: ["exec", "cli", "tui"]) { return (.codex, .terminal) }
        switch (source ?? "").lowercased() {
        case "vscode": return (.codex, .vscode)
        case "exec", "cli": return (.codex, .terminal)
        default: return (.codex, .unknown)
        }
    }
}

/// The token counters as Codex writes them. A category that is absent stays nil.
struct CodexRawUsage: Equatable {
    var input: Int64?
    var cached: Int64?
    var cacheWrite: Int64?
    var output: Int64?
    var reasoning: Int64?
    var total: Int64?

    var isAllZeroCategories: Bool { (input ?? 0) == 0 && (output ?? 0) == 0 && (cached ?? 0) == 0 }
}

struct CodexRateWindow {
    var slot: String
    var usedPercent: Double
    var minutes: Int?
    var resetsAt: Double?
}

struct CodexRateLimits {
    var limitID: String?
    var planType: String?
    var windows: [CodexRateWindow] = []
}

/// Parses Codex session lines.
///
/// The parser reads the whole file in order, because later lines depend on earlier ones, and it keeps all of
/// that state itself. See `CodexAdapter` for how requests are identified.
final class CodexLineParser: LineParser {
    private let file: SourceFileRef
    private let source: TelemetrySourceID = .codexRollouts

    // The session header.
    private var sessionID: String
    private var originator: String?
    private var sourceHint: String?
    private var cwd: String?
    private var cliVersion: String?
    private var accountRaw: String?
    private var threadSource: String?
    private var subagentKind: String?
    private var parentID: String?
    private var forkedFromID: String?
    private var rootID: String?
    private var startMs: Int64?
    private var sawHeader = false

    // The activity window and per-session facts gathered from every line.
    private var firstMs = Int64.max
    private var lastMs = Int64.min
    private var compactions = 0

    // Model and usage state.
    private var model = "unknown"
    private var serviceTier: String?
    private var usageRecordsSeen = false
    private var previousTotal: CodexRawUsage?
    private var replayCutoffMs: Int64?

    private static let minPlausibleMs: Int64 = 1_577_836_800_000 // 2020-01-01
    /// Lines written within this long after a fork was created are the parent's history, copied into the fork.
    private static let forkReplayWindowMs: Int64 = 1500

    init(file: SourceFileRef) {
        self.file = file
        self.sessionID = file.sessionHint
    }

    /// Everything read from one `payload` object that matters here.
    private struct Payload {
        var type: String?
        // Header.
        var id: String?
        var sessionID: String?
        var timestamp: String?
        var cwd: String?
        var originator: String?
        var cliVersion: String?
        var source: String?
        var subagentKind: String?
        var threadSource: String?
        var parentThreadID: String?
        var forkedFromID: String?
        var accountID: String?
        // Model.
        var model: String?
        var serviceTier: String?
        // Token events.
        var hasInfo = false
        var total: CodexRawUsage?
        var last: CodexRawUsage?
        var rate: CodexRateLimits?
        var responseID: String?
        var usage: CodexRawUsage?
    }

    func parse(line: UnsafeBufferPointer<UInt8>, offset: Int64, into batch: inout NormalizedBatch) {
        batch.lineCount += 1
        var c = JSONCursor(line)
        c.skipWhitespace()
        guard c.peek == 0x7B else { batch.malformedLineCount += 1; return }

        var outer: String?
        var timestampMs: Int64?
        var ordinal: Int64?
        var payload = Payload()

        let ok = c.forEachMember { c, key in
            if c.equals(key, "type") {
                guard let s = c.readRawString() else { return false }
                outer = c.string(s); return true
            } else if c.equals(key, "timestamp") {
                guard let s = c.readRawString() else { return false }
                timestampMs = ISO8601Fast.parse(UnsafeBufferPointer(start: c.base + s.start, count: s.end - s.start))
                return true
            } else if c.equals(key, "ordinal") {
                guard let v = c.readInt() else { return false }
                ordinal = v; return true
            } else if c.equals(key, "payload") {
                c.skipWhitespace()
                guard c.peek == 0x7B else { return false }
                // Payloads of lines this parser has no use for (messages, tool calls) are skipped unread.
                if let t = outer, !Self.handled.contains(t) { return false }
                return Self.parsePayload(&c, into: &payload)
            }
            return false
        }
        guard ok, outer != nil else { batch.malformedLineCount += 1; return }

        guard let ts = timestampMs, ts >= Self.minPlausibleMs, ts < Clock.nowMs() + 86_400_000 else { return }
        firstMs = min(firstMs, ts)
        lastMs = max(lastMs, ts)

        switch outer! {
        case "session_meta": absorbHeader(payload, ts: ts)
        case "turn_context": if let m = payload.model, !m.isEmpty { model = m }
        case "compacted": compactions += 1
        case "event_msg":
            switch payload.type {
            case "token_count": tokenCount(payload, ts: ts, ordinal: ordinal ?? offset, into: &batch)
            case "thread_settings_applied":
                if let m = payload.model, !m.isEmpty { model = m }
                if let tier = payload.serviceTier { serviceTier = tier == "default" ? nil : tier }
            default: break
            }
        case "token_usage_record": usageRecord(payload, ts: ts, ordinal: ordinal ?? offset, into: &batch)
        default: break
        }
    }

    private static let handled: Set<String> = ["session_meta", "turn_context", "event_msg", "token_usage_record", "compacted"]

    func flush(into batch: inout NormalizedBatch) {
        guard lastMs != Int64.min else { return }
        let (product, surface) = CodexAdapter.classify(originator: originator, source: sourceHint)
        var kind = SessionKind.main
        if threadSource == "subagent" || subagentKind != nil { kind = .subagent }
        if threadSource == "guardian_review" || subagentKind == "guardian" { kind = .review }
        let account = AccountRef.identified(provider: .openAI, rawIdentifier: accountRaw)
        batch.add(SessionObservation(
            product: product, source: source, externalID: sessionID, projectKey: cwd ?? "codex:unknown-project", cwd: cwd,
            surface: surface, account: account, clientVersion: cliVersion, kind: kind,
            parentExternalID: parentID ?? forkedFromID, rootExternalID: rootID, firstSeenMs: min(firstMs, startMs ?? firstMs), lastSeenMs: lastMs,
            versionSeenMs: firstMs, compactionCount: compactions))
    }

    // MARK: Header

    private func absorbHeader(_ p: Payload, ts: Int64) {
        guard !sawHeader else { return }
        sawHeader = true
        // `id` names this thread. `session_id` names the conversation it belongs to, which for a thread that another
        // thread started is the conversation of its root, so using it would merge the two threads into one.
        if let id = p.id ?? p.sessionID, !id.isEmpty { sessionID = id }
        if let root = p.sessionID, root != sessionID { rootID = root }
        originator = p.originator
        sourceHint = p.source
        cwd = p.cwd
        cliVersion = p.cliVersion
        accountRaw = p.accountID
        threadSource = p.threadSource
        subagentKind = p.subagentKind
        parentID = p.parentThreadID
        forkedFromID = p.forkedFromID
        startMs = p.timestamp.flatMap { ISO8601Fast.parse($0) } ?? ts
        if forkedFromID != nil, let start = startMs { replayCutoffMs = start + Self.forkReplayWindowMs }
    }

    private var product: ProductID { CodexAdapter.classify(originator: originator, source: sourceHint).product }

    /// True for a line that a fork copied from its parent. Its counters were already counted in the parent.
    private func isForkReplay(_ ts: Int64) -> Bool {
        if let cutoff = replayCutoffMs { return ts <= cutoff }
        return false
    }

    // MARK: Usage

    private func measurement(_ u: CodexRawUsage, completeness: UsageMeasurement.Completeness = .complete) -> UsageMeasurement? {
        let input = max(0, u.input ?? 0), output = max(0, u.output ?? 0)
        if input == 0, output == 0, (u.total ?? 0) > 0 {
            // Only the grand total is known. The categories stay unknown, and the total is kept so that it is not lost.
            return UsageMeasurement(output: 0, extras: ["total_tokens_only": u.total ?? 0],
                                    normalization: "openai.responses.v1", completeness: .partial)
        }
        var m = UsageNormalizer.openAI(inputTokens: input, cachedInputTokens: u.cached.map { max(0, $0) },
                                       cacheWriteInputTokens: u.cacheWrite.map { max(0, $0) },
                                       outputTokens: output, reasoningOutputTokens: u.reasoning.map { max(0, $0) })
        if completeness != .complete { m.completeness = min(m.completeness, completeness) }
        return m
    }

    private func usageRecord(_ p: Payload, ts: Int64, ordinal: Int64, into batch: inout NormalizedBatch) {
        usageRecordsSeen = true
        guard let usage = p.usage, let m = measurement(usage), !m.isEmpty || m.extras["total_tokens_only"] != nil else { return }
        if isForkReplay(ts) { return }
        let key = p.responseID ?? "\(sessionID):\(ordinal)"
        batch.add(RequestObservation(
            product: product, source: source, requestKey: key, apiRequestID: p.responseID, sessionExternalID: sessionID,
            model: model, requestedAtMs: ts, usage: m, speed: serviceTier, originLocation: ordinal))
    }

    private func tokenCount(_ p: Payload, ts: Int64, ordinal: Int64, into batch: inout NormalizedBatch) {
        let replay = isForkReplay(ts)
        // The quota snapshot is the account's state at the moment the event was written. A copied line carries the
        // time of the copy instead, so it would pass off an old figure as a current one and is ignored.
        if let rate = p.rate, !replay { quota(rate, ts: ts, into: &batch) }
        guard p.hasInfo, let total = p.total, let last = p.last else { return }
        defer { previousTotal = total }

        // A repeated snapshot carries the same running totals as the one before it. It reports no new response.
        if let previous = previousTotal, previous == total { return }
        // When responses have their own records, those are the requests. The events then only supply quota.
        if usageRecordsSeen || replay { return }

        // An event that reports only a grand total has no categories of its own. The change in the running totals
        // does have them, so the response is reconstructed from that change.
        if last.isAllZeroCategories, (last.total ?? 0) > 0 {
            let before = previousTotal ?? CodexRawUsage(input: 0, cached: 0, cacheWrite: 0, output: 0, reasoning: 0, total: 0)
            if let change = Self.difference(total, before), !change.isAllZeroCategories, var m = measurement(change) {
                m.completeness = .reconciledFromTotals
                m.normalization = "openai.responses.v1+totals"
                batch.add(RequestObservation(
                    product: product, source: source, requestKey: "\(sessionID):\(ordinal)", sessionExternalID: sessionID,
                    model: model, requestedAtMs: ts, usage: m, speed: serviceTier, originLocation: ordinal))
                return
            }
        }

        guard let m = measurement(last) else { return }
        if !m.isEmpty || m.extras["total_tokens_only"] != nil {
            batch.add(RequestObservation(
                product: product, source: source, requestKey: "\(sessionID):\(ordinal)", sessionExternalID: sessionID,
                model: model, requestedAtMs: ts, usage: m, speed: serviceTier, originLocation: ordinal))
        }

        // The running totals can have advanced further than this response explains. That happens when a response
        // never produced an event of its own. The difference is real usage, so it is recorded as a request of its
        // own and marked as reconstructed from the totals.
        guard let previous = previousTotal else { return }
        func gap(_ a: Int64?, _ b: Int64?, _ l: Int64?) -> Int64? {
            guard let a, let b else { return nil }
            return (a - b) - (l ?? 0)
        }
        let gaps = [gap(total.input, previous.input, last.input), gap(total.cached, previous.cached, last.cached),
                    gap(total.output, previous.output, last.output), gap(total.reasoning, previous.reasoning, last.reasoning)]
        // Only a clean excess is reconstructed. A shortfall means the counters were reset, and then nothing is added.
        guard gaps.allSatisfy({ ($0 ?? 0) >= 0 }), (gaps[0] ?? 0) > 0 || (gaps[2] ?? 0) > 0 else { return }
        let missing = CodexRawUsage(input: gaps[0], cached: gaps[1], cacheWrite: nil, output: gaps[2], reasoning: gaps[3], total: nil)
        if let gm = measurement(missing, completeness: .reconciledFromTotals) {
            var reconstructed = gm
            reconstructed.completeness = .reconciledFromTotals
            reconstructed.normalization = "openai.responses.v1+totals"
            batch.add(RequestObservation(
                product: product, source: source, requestKey: "\(sessionID):\(ordinal):gap", sessionExternalID: sessionID,
                model: model, requestedAtMs: ts, usage: reconstructed, speed: serviceTier, originLocation: ordinal))
        }
    }

    /// The change from one running total to the next, or nil when any category went down (the counters were reset).
    private static func difference(_ a: CodexRawUsage, _ b: CodexRawUsage) -> CodexRawUsage? {
        func d(_ x: Int64?, _ y: Int64?) -> Int64? { x.map { $0 - (y ?? 0) } }
        let r = CodexRawUsage(input: d(a.input, b.input), cached: d(a.cached, b.cached), cacheWrite: d(a.cacheWrite, b.cacheWrite),
                              output: d(a.output, b.output), reasoning: d(a.reasoning, b.reasoning), total: d(a.total, b.total))
        let all = [r.input, r.cached, r.cacheWrite, r.output, r.reasoning, r.total].compactMap { $0 }
        return all.allSatisfy { $0 >= 0 } ? r : nil
    }

    // MARK: Quota

    /// Turns a `rate_limits` snapshot into one observation per window. A window is identified by its length, never
    /// by whether Codex calls it primary or secondary, because a plan can have only a weekly window.
    private func quota(_ rate: CodexRateLimits, ts: Int64, into batch: inout NormalizedBatch) {
        let limit = rate.limitID ?? "codex"
        let poolKey = limit == "codex" ? "codex" : "openai-limit:" + limit
        let account = AccountRef.identified(provider: .openAI, rawIdentifier: accountRaw)
        for w in rate.windows where w.usedPercent.isFinite && w.usedPercent >= 0 {
            let key = w.minutes.map { WindowNaming.key(minutes: $0) } ?? w.slot
            batch.add(QuotaObservation(
                provider: .openAI, account: account, poolKey: poolKey, windowKey: key, windowMinutes: w.minutes,
                utilizationPercent: w.usedPercent, resetsAt: w.resetsAt.map { Date(timeIntervalSince1970: $0) },
                observedAt: Clock.date(ms: ts), source: source, authority: .authoritative,
                originProduct: product, originSession: sessionID, planType: rate.planType))
        }
    }

    // MARK: Payload parsing

    private static func parsePayload(_ c: inout JSONCursor, into p: inout Payload) -> Bool {
        c.forEachMember { c, key in
            if c.equals(key, "type") { if let v = Self.readText(&c) { p.type = v; return true }; return false }
            if c.equals(key, "id") { if let v = Self.readText(&c) { p.id = v; return true }; return false }
            if c.equals(key, "session_id") { if let v = Self.readText(&c) { p.sessionID = v; return true }; return false }
            if c.equals(key, "timestamp") { if let v = Self.readText(&c) { p.timestamp = v; return true }; return false }
            if c.equals(key, "cwd") { if let v = Self.readText(&c) { p.cwd = v; return true }; return false }
            if c.equals(key, "originator") { if let v = Self.readText(&c) { p.originator = v; return true }; return false }
            if c.equals(key, "cli_version") { if let v = Self.readText(&c) { p.cliVersion = v; return true }; return false }
            if c.equals(key, "thread_source") { if let v = Self.readText(&c) { p.threadSource = v; return true }; return false }
            if c.equals(key, "parent_thread_id") { if let v = Self.readText(&c) { p.parentThreadID = v; return true }; return false }
            if c.equals(key, "forked_from_id") { if let v = Self.readText(&c) { p.forkedFromID = v; return true }; return false }
            if c.equals(key, "creator_account_id") { if let v = Self.readText(&c) { p.accountID = v; return true }; return false }
            if c.equals(key, "model") { if let v = Self.readText(&c) { p.model = v; return true }; return false }
            if c.equals(key, "response_id") { if let v = Self.readText(&c) { p.responseID = v; return true }; return false }
            if c.equals(key, "source") {
                c.skipWhitespace()
                if c.peek == 0x22 { if let v = Self.readText(&c) { p.source = v; return true }; return false }
                return parseSourceObject(&c, into: &p)
            }
            if c.equals(key, "thread_settings") {
                c.skipWhitespace()
                guard c.peek == 0x7B else { return false }
                return c.forEachMember { c, k in
                    if c.equals(k, "model") { if let v = Self.readText(&c) { p.model = v; return true }; return false }
                    if c.equals(k, "service_tier") { if let v = Self.readText(&c) { p.serviceTier = v; return true }; return false }
                    return false
                }
            }
            if c.equals(key, "info") {
                c.skipWhitespace()
                guard c.peek == 0x7B else { return false }
                p.hasInfo = true
                return c.forEachMember { c, k in
                    if c.equals(k, "total_token_usage") { return parseUsage(&c, into: &p.total) }
                    if c.equals(k, "last_token_usage") { return parseUsage(&c, into: &p.last) }
                    return false
                }
            }
            if c.equals(key, "usage") { return parseUsage(&c, into: &p.usage) }
            if c.equals(key, "rate_limits") {
                c.skipWhitespace()
                guard c.peek == 0x7B else { return false }
                var rate = CodexRateLimits()
                let ok = c.forEachMember { c, k in
                    if c.equals(k, "limit_id") { if let v = Self.readText(&c) { rate.limitID = v; return true }; return false }
                    if c.equals(k, "plan_type") { if let v = Self.readText(&c) { rate.planType = v; return true }; return false }
                    if c.equals(k, "primary") { return parseWindow(&c, slot: "primary", into: &rate) }
                    if c.equals(k, "secondary") { return parseWindow(&c, slot: "secondary", into: &rate) }
                    return false
                }
                if ok { p.rate = rate }
                return ok
            }
            return false
        }
    }

    /// Reads a string value, or nothing when the value is null or not a string.
    private static func readText(_ c: inout JSONCursor) -> String? {
        c.skipWhitespace()
        if c.peek == 0x6E { return nil }
        guard let s = c.readRawString() else { return nil }
        return c.string(s)
    }

    /// The `source` member is either a name such as `vscode`, or an object that says the session was started by
    /// another session: `{"subagent": {"thread_spawn": {"parent_thread_id": …}}}` or `{"subagent": {"other": "guardian"}}`.
    private static func parseSourceObject(_ c: inout JSONCursor, into p: inout Payload) -> Bool {
        c.skipWhitespace()
        guard c.peek == 0x7B else { return false }
        return c.forEachMember { c, key in
            guard c.equals(key, "subagent") else { return false }
            p.subagentKind = "subagent"
            c.skipWhitespace()
            guard c.peek == 0x7B else { return false }
            return c.forEachMember { c, k in
                if c.equals(k, "other") {
                    guard let s = c.readRawString() else { return false }
                    p.subagentKind = c.string(s); return true
                }
                if c.equals(k, "thread_spawn") {
                    c.skipWhitespace()
                    guard c.peek == 0x7B else { return false }
                    return c.forEachMember { c, kk in
                        if c.equals(kk, "parent_thread_id") {
                            guard let s = c.readRawString() else { return false }
                            p.parentThreadID = c.string(s); return true
                        }
                        return false
                    }
                }
                return false
            }
        }
    }

    private static func parseUsage(_ c: inout JSONCursor, into out: inout CodexRawUsage?) -> Bool {
        c.skipWhitespace()
        guard c.peek == 0x7B else { return false }
        var u = CodexRawUsage()
        let ok = c.forEachMember { c, k in
            func int(_ assign: (Int64) -> Void) -> Bool {
                guard let v = c.readInt() else { return false }
                assign(v); return true
            }
            if c.equals(k, "input_tokens") { return int { u.input = $0 } }
            if c.equals(k, "cached_input_tokens") { return int { u.cached = $0 } }
            if c.equals(k, "cache_write_input_tokens") { return int { u.cacheWrite = $0 } }
            if c.equals(k, "output_tokens") { return int { u.output = $0 } }
            if c.equals(k, "reasoning_output_tokens") { return int { u.reasoning = $0 } }
            if c.equals(k, "total_tokens") { return int { u.total = $0 } }
            return false
        }
        if ok { out = u }
        return ok
    }

    private static func parseWindow(_ c: inout JSONCursor, slot: String, into rate: inout CodexRateLimits) -> Bool {
        c.skipWhitespace()
        guard c.peek == 0x7B else { return false }
        var used: Double?
        var minutes: Int?
        var resets: Double?
        let ok = c.forEachMember { c, k in
            if c.equals(k, "used_percent") { guard let d = c.readDouble() else { return false }; used = d; return true }
            if c.equals(k, "window_minutes") { guard let v = c.readInt() else { return false }; minutes = Int(v); return true }
            if c.equals(k, "resets_at") { guard let d = c.readDouble() else { return false }; resets = d; return true }
            return false
        }
        if ok, let used { rate.windows.append(CodexRateWindow(slot: slot, usedPercent: used, minutes: minutes, resetsAt: resets)) }
        return ok
    }
}


extension UsageNormalizer {
    /// OpenAI Responses usage as written by Codex. `input_tokens` includes the cached tokens, and
    /// `output_tokens` includes the reasoning tokens. This was verified on real session files, where
    /// `total_tokens` equals `input_tokens + output_tokens` for every request.
    ///
    /// Whether cache-write tokens are included in `input_tokens` has not been observed, because the field is
    /// always zero in the files inspected. The conversion assumes they are, in line with the rest of the
    /// report, and `normalization` records that assumption.
    public static func openAI(inputTokens: Int64, cachedInputTokens: Int64?, cacheWriteInputTokens: Int64?,
                              outputTokens: Int64, reasoningOutputTokens: Int64?) -> UsageMeasurement {
        let cached = cachedInputTokens ?? 0
        let written = cacheWriteInputTokens ?? 0
        let uncached = max(0, inputTokens - cached - written)
        return UsageMeasurement(
            uncachedInput: uncached, cacheRead: cachedInputTokens, cacheCreation: cacheWriteInputTokens, output: outputTokens,
            reasoningOutput: reasoningOutputTokens, normalization: "openai.responses.v1",
            completeness: cachedInputTokens == nil ? .partial : .complete)
    }
}
