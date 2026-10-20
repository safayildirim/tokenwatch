import Foundation

/// The token counters as Codex writes them. A category that is absent stays nil.
struct CodexRawUsage: Equatable, Hashable {
    var input: Int64?
    var cached: Int64?
    var cacheWrite: Int64?
    var output: Int64?
    var reasoning: Int64?
    var total: Int64?

    var isAllZeroCategories: Bool { (input ?? 0) == 0 && (output ?? 0) == 0 && (cached ?? 0) == 0 }

    /// The four figures that identify what one response used. Two records of one response agree on them.
    var signature: CodexUsageSignature {
        CodexUsageSignature(input: input ?? 0, cached: cached ?? 0, output: output ?? 0, reasoning: reasoning ?? 0)
    }
}

struct CodexUsageSignature: Hashable {
    var input: Int64
    var cached: Int64
    var output: Int64
    var reasoning: Int64
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

    /// The reported figures in a form that can be compared, so that a copy of a snapshot can be recognized.
    var signature: [Int64] {
        windows.flatMap { [Int64($0.minutes ?? -1), Int64(($0.usedPercent * 100).rounded()), Int64($0.resetsAt ?? -1)] }
    }
}

/// Identifies one `token_count` line by what it says. A line that reports usage is identified by its figures alone. A
/// line that reports only the rate limits has nothing else to go by, so those are part of its key.
///
/// A fork copies the lines of its parent unchanged, so a copied
/// line has the same key as the line it was copied from, whatever time it was written.
///
/// The running totals are part of the key because they only grow, so within one thread's history two different lines
/// cannot share them. They are compared only between a fork and its own parent. Across unrelated threads two
/// different responses can have the same figures (two runs of the same command do), which is why the totals are
/// never used as a request's identity.
struct CodexSnapshotKey: Hashable {
    var ordinal: Int64?
    var total: CodexRawUsage?
    var last: CodexRawUsage?
    var rate: [Int64]
}

/// What a thread's file recorded, as far as a fork of it can have copied.
struct CodexInheritedHistory {
    var responseIDs: Set<String> = []
    var snapshots: Set<CodexSnapshotKey> = []
}

/// Reads a whole session file, decompressing it when necessary.
enum CodexFileContents {
    static func read(path: String) throws -> Data {
        guard path.hasSuffix(".zst") else { return try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw FileAccessError(path: path, message: String(cString: strerror(errno)), code: errno) }
        defer { close(fd) }
        let reader = try ZstdFileReader(fd: fd)
        var out = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
        defer { buffer.deallocate() }
        while true {
            let n = try reader.read(into: buffer, capacity: 1 << 20)
            if n == 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }
}

/// Parses Codex session lines.
///
/// The parser reads the whole file in order, because later lines depend on earlier ones, and it keeps all of
/// that state itself. Nothing is decided until `flush`, because whether an event is a response of its own depends
/// on the records around it. See `CodexAdapter` for how requests are identified.
final class CodexLineParser: LineParser {
    private let file: SourceFileRef
    private let source: TelemetrySourceID = .codexRollouts
    private let lookupParent: ((String) -> CodexInheritedHistory?)?
    private let collecting: Bool

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
    private var lineNumber = 0

    // Model and usage state.
    private var model = "unknown"
    private var serviceTier: String?
    private var previousTotal: CodexRawUsage?

    /// A response that has a `token_usage_record` of its own.
    private struct PendingResponse {
        var key: String
        /// True when the key is the response id Codex wrote, and false when it was made from the line's position.
        var isResponseID: Bool
        /// The thread that made the response, when it is not the thread this file belongs to.
        var threadID: String?
        var ts: Int64
        var ordinal: Int64
        var lineNumber: Int
        var usage: CodexRawUsage
        var model: String
        var tier: String?
    }

    /// A `token_count` event that reports a response not seen before.
    private struct PendingSnapshot {
        var ts: Int64
        var ordinal: Int64
        var lineNumber: Int
        var total: CodexRawUsage
        var last: CodexRawUsage
        var previous: CodexRawUsage?
        var model: String
        var tier: String?
    }

    private var responses: [PendingResponse] = []
    private var responseIndex: [String: Int] = [:]
    private var snapshots: [PendingSnapshot] = []

    /// The sum of every distinct record, and how many records the thread's own running counter grew by more than.
    private var counterShortfallRecords = 0
    private var counterShortfallTokens: Int64 = 0
    private var previousThreadCounter: Int64?

    // Lineage of a fork.
    private var parentHistory: CodexInheritedHistory?
    private var parentMissing = false
    private var forkCutoffMs: Int64?
    private var withheldEvents = 0
    /// Lines of a kind this parser counts usage from, whose usage could not be read. A new version of Codex that renames
    /// a field would otherwise make usage disappear without a sign.
    private var unreadableUsageLines = 0
    private var unverifiedEvents = 0

    private(set) var collectedHistory = CodexInheritedHistory()

    private static let minPlausibleMs: Int64 = 1_577_836_800_000 // 2020-01-01
    /// A quota reading dated further than this into the future is a clock error, not an observation.
    private static let futureSkewMs: Int64 = 5 * 60_000
    /// Lines written within this long after a fork was created might be the parent's history copied into the fork. It
    /// is used only when the parent's own file is not available to compare with.
    static let forkCopyBurstMs: Int64 = 1500
    /// A snapshot and the record of the same response are written within a few lines of each other.
    private static let matchingDistanceInLines = 24

    init(file: SourceFileRef, parentHistory: ((String) -> CodexInheritedHistory?)?, collectsHistory: Bool = false) {
        self.file = file
        self.sessionID = file.sessionHint
        self.lookupParent = parentHistory
        self.collecting = collectsHistory
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
        var threadID: String?
        var usage: CodexRawUsage?
        var threadUsage: CodexRawUsage?
        /// The usage record that a compaction marker carries for the compaction request itself.
        var compactionResponseID: String?
        var compactionThreadID: String?
        var compactionUsage: CodexRawUsage?
    }

    func parse(line: UnsafeBufferPointer<UInt8>, offset: Int64, into batch: inout NormalizedBatch) {
        batch.lineCount += 1
        lineNumber += 1
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

        let position = ordinal
        switch outer! {
        case "session_meta": absorbHeader(payload, ts: ts)
        case "turn_context": if let m = payload.model, !m.isEmpty { model = m }
        case "compacted":
            compactions += 1
            if let id = payload.compactionResponseID, let usage = payload.compactionUsage {
                usageRecord(responseID: id, threadID: payload.compactionThreadID, usage: usage, threadUsage: nil,
                            ts: ts, ordinal: position ?? offset, hasExplicitOrdinal: position != nil)
            }
        case "event_msg":
            switch payload.type {
            case "token_count": tokenCount(payload, ts: ts, ordinal: position ?? offset, explicit: position != nil)
            case "thread_settings_applied":
                if let m = payload.model, !m.isEmpty { model = m }
                if let tier = payload.serviceTier { serviceTier = Self.priceTier(of: tier) }
            default: break
            }
        case "token_usage_record":
            usageRecord(responseID: payload.responseID, threadID: payload.threadID, usage: payload.usage,
                        threadUsage: payload.threadUsage, ts: ts, ordinal: position ?? offset, hasExplicitOrdinal: position != nil)
        default: break
        }
    }

    /// The tier a session asked for, in the names the price cards use. The default tier is no tier at all. `priority` is
    /// the old name of Fast mode. A name that is not recognized is kept, so that no standard price is applied to it.
    static func priceTier(of raw: String) -> String? {
        switch raw.lowercased() {
        case "default", "auto", "standard", "": return nil
        case "priority", "fast": return "fast"
        default: return raw.lowercased()
        }
    }

    private static let handled: Set<String> = ["session_meta", "turn_context", "event_msg", "token_usage_record", "compacted"]

    // MARK: Output

    /// Decides what the file reported, once all of it has been read. Quota readings were already handed over
    /// while reading, because they do not depend on the lines around them.
    func flush(into batch: inout NormalizedBatch) {
        guard lastMs != Int64.min, !collecting else { return }
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
        emitRequests(product: product, into: &batch)
        batch.notices.append(contentsOf: notices())
        for pending in pendingQuota { batch.add(pending) }
        pendingQuota.removeAll()
    }

    private var pendingQuota: [QuotaObservation] = []

    private func emitRequests(product: ProductID, into batch: inout NormalizedBatch) {
        // Every usage record is a response, identified by its response id.
        for r in responses {
            guard let m = measurement(r.usage) , !m.isEmpty || m.extras["total_tokens_only"] != nil else { continue }
            batch.add(RequestObservation(
                product: product, source: source, requestKey: r.key, apiRequestID: r.isResponseID ? r.key : nil,
                sessionExternalID: r.threadID ?? sessionID, model: r.model, requestedAtMs: r.ts, usage: m, speed: r.tier,
                originLocation: r.ordinal))
        }

        // A snapshot is the same response as a record when it reports the same figures close to it. Each record
        // explains at most one snapshot.
        var candidates: [CodexUsageSignature: [Int]] = [:]
        for (index, r) in responses.enumerated() { candidates[r.usage.signature, default: []].append(index) }
        var claimed = Set<Int>()
        var unexplained: [PendingSnapshot] = []
        for s in snapshots {
            let nearest = (candidates[s.last.signature] ?? [])
                .filter { !claimed.contains($0) && abs(responses[$0].lineNumber - s.lineNumber) <= Self.matchingDistanceInLines }
                .min { abs(responses[$0].lineNumber - s.lineNumber) < abs(responses[$1].lineNumber - s.lineNumber) }
            if let nearest { claimed.insert(nearest) } else { unexplained.append(s) }
        }

        // The part of the file before the first record was written the older way, where a response that has no event
        // of its own can only be found through the running totals. Once records exist, a response without an event is
        // a record, so the totals are not consulted again.
        let firstRecordLine = responses.map(\.lineNumber).min() ?? Int.max
        eventRequestsFromUnexplained(unexplained, firstRecordLine: firstRecordLine, product: product, into: &batch)
        unexplainedAfterRecords = unexplained.filter { $0.lineNumber > firstRecordLine }.count
    }

    private var unexplainedAfterRecords = 0

    /// Responses that only a `token_count` event reports.
    private func eventRequestsFromUnexplained(_ events: [PendingSnapshot], firstRecordLine: Int, product: ProductID,
                                              into batch: inout NormalizedBatch) {
        for s in events {
            let key = "\(sessionID):\(s.ordinal)"
            func add(_ usage: UsageMeasurement, suffix: String = "") {
                batch.add(RequestObservation(
                    product: product, source: source, requestKey: key + suffix, sessionExternalID: sessionID,
                    model: s.model, requestedAtMs: s.ts, usage: usage, speed: s.tier, originLocation: s.ordinal))
            }
            // An event that reports only a grand total has no categories of its own. The change in the running totals
            // does have them, so the response is reconstructed from that change.
            if s.last.isAllZeroCategories, (s.last.total ?? 0) > 0 {
                let before = s.previous ?? CodexRawUsage(input: 0, cached: 0, cacheWrite: 0, output: 0, reasoning: 0, total: 0)
                if let change = Self.difference(s.total, before), !change.isAllZeroCategories, var m = measurement(change) {
                    m.completeness = .reconciledFromTotals
                    m.normalization = "openai.responses.v1+totals"
                    add(m)
                    continue
                }
            }
            if let m = measurement(s.last), !m.isEmpty || m.extras["total_tokens_only"] != nil { add(m) }

            // The running totals can have advanced further than this response explains. That happens when a response
            // never produced an event of its own. The difference is real usage, so it is recorded as a request of its
            // own and marked as reconstructed from the totals.
            guard s.lineNumber < firstRecordLine, let previous = s.previous else { continue }
            func gap(_ a: Int64?, _ b: Int64?, _ l: Int64?) -> Int64? {
                guard let a, let b else { return nil }
                return (a - b) - (l ?? 0)
            }
            let gaps = [gap(s.total.input, previous.input, s.last.input), gap(s.total.cached, previous.cached, s.last.cached),
                        gap(s.total.output, previous.output, s.last.output), gap(s.total.reasoning, previous.reasoning, s.last.reasoning)]
            // Only a clean excess is reconstructed. A shortfall means the counters were reset, and then nothing is added.
            guard gaps.allSatisfy({ ($0 ?? 0) >= 0 }), (gaps[0] ?? 0) > 0 || (gaps[2] ?? 0) > 0 else { continue }
            let missing = CodexRawUsage(input: gaps[0], cached: gaps[1], cacheWrite: nil, output: gaps[2], reasoning: gaps[3], total: nil)
            if var gm = measurement(missing, completeness: .reconciledFromTotals) {
                gm.completeness = .reconciledFromTotals
                gm.normalization = "openai.responses.v1+totals"
                add(gm, suffix: ":gap")
            }
        }
    }

    /// Statements about this file that the reader of the diagnostics should know, because something in it could not be
    /// established exactly. They are replaced every time the file is read.
    private func notices() -> [String] {
        var out: [String] = []
        if withheldEvents > 0 {
            out.append("This fork's parent session is not on this Mac, so \(withheldEvents) usage lines written at the instant the fork was created were assumed to be copied history and left out. If any of them was real activity, it is missing.")
        }
        if unverifiedEvents > 0 {
            out.append("\(unverifiedEvents) usage lines written when this fork was created are not in its parent's file, so they were counted as this session's own usage. They may be history the parent had not yet written.")
        }
        if unexplainedAfterRecords > 0 {
            out.append("\(unexplainedAfterRecords) token_count events have no matching usage record in a session that otherwise has them. They were counted from the events.")
        }
        if unreadableUsageLines > 0 {
            out.append("\(unreadableUsageLines) lines that should report token usage did not have the expected shape, so their usage is missing. A newer version of Codex may have changed its file format.")
        }
        if counterShortfallRecords > 0 {
            out.append("The thread's own token counter grew by \(counterShortfallTokens) tokens more than \(counterShortfallRecords) of its usage records report, so some usage may be missing.")
        }
        return out
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
        if let parent = forkedFromID, let lookupParent, !collecting {
            parentHistory = lookupParent(parent)
            parentMissing = parentHistory == nil
            forkCutoffMs = (startMs ?? ts) + Self.forkCopyBurstMs
        }
    }

    private var product: ProductID { CodexAdapter.classify(originator: originator, source: sourceHint).product }

    // MARK: Lineage

    private enum Origin { case own, inherited, withheld }

    /// Decides whether a line belongs to this session or was copied into it from the parent.
    ///
    /// When the parent's file is available the decision is made by comparing what the lines say. Without it the only
    /// evidence is the time: a fork writes the copied history in one burst at the instant it is created. That is a
    /// weaker kind of evidence, so lines it excludes are counted and reported.
    private func origin(ofSnapshot key: CodexSnapshotKey, responseID: String? = nil, ts: Int64, countsAsEvent: Bool) -> Origin {
        guard forkedFromID != nil, !collecting else { return .own }
        if let history = parentHistory {
            let known = responseID.map { history.responseIDs.contains($0) } ?? history.snapshots.contains(key)
            if known { return .inherited }
            if countsAsEvent, let cutoff = forkCutoffMs, ts <= cutoff { unverifiedEvents += 1 }
            return .own
        }
        if parentMissing, let cutoff = forkCutoffMs, ts <= cutoff {
            if countsAsEvent { withheldEvents += 1 }
            return .withheld
        }
        return .own
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

    /// Takes in one response that has a record of its own, either a `token_usage_record` line or the record that a
    /// compaction marker carries. The response id is the identity, so a response that appears twice is one request.
    private func usageRecord(responseID: String?, threadID: String?, usage: CodexRawUsage?, threadUsage: CodexRawUsage?,
                             ts: Int64, ordinal: Int64, hasExplicitOrdinal: Bool) {
        guard let usage else { unreadableUsageLines += 1; return }
        if collecting {
            if let responseID { collectedHistory.responseIDs.insert(responseID) }
            return
        }
        // The thread keeps its own running counter. Each record should grow it by exactly its own usage. When the counter
        // grew by more, a response was counted by Codex but not recorded, and that usage cannot be recovered here.
        if let counter = threadUsage?.total ?? threadUsage.flatMap({ ($0.input ?? 0) + ($0.output ?? 0) }) {
            let own = usage.total ?? ((usage.input ?? 0) + (usage.output ?? 0))
            if let previous = previousThreadCounter, counter - previous > own {
                counterShortfallRecords += 1
                counterShortfallTokens += counter - previous - own
            }
            previousThreadCounter = counter
        }
        let key = responseID ?? "\(sessionID):\(ordinal)"
        // A record that names another thread as its maker was copied into this file. That is established by what the
        // record says, so the response is attributed to the thread that made it, with no need to look at the time.
        let maker = threadID.flatMap { $0 == sessionID ? nil : $0 }
        let placeholder = CodexSnapshotKey(ordinal: nil, total: nil, last: nil, rate: [])
        let owner = maker != nil && !(parentHistory?.responseIDs.contains(key) ?? false)
            ? Origin.own : origin(ofSnapshot: placeholder, responseID: responseID, ts: ts, countsAsEvent: true)
        guard owner == .own, responseIndex[key] == nil else { return }
        responseIndex[key] = responses.count
        responses.append(PendingResponse(
            key: key, isResponseID: responseID != nil, threadID: maker, ts: ts, ordinal: ordinal,
            lineNumber: lineNumber, usage: usage, model: model, tier: serviceTier))
    }

    private func tokenCount(_ p: Payload, ts: Int64, ordinal: Int64, explicit: Bool) {
        let key = CodexSnapshotKey(ordinal: explicit ? ordinal : nil, total: p.hasInfo ? p.total : nil,
                                   last: p.hasInfo ? p.last : nil, rate: p.hasInfo ? [] : (p.rate?.signature ?? []))
        if collecting { collectedHistory.snapshots.insert(key); return }

        let repeated = p.hasInfo && p.total != nil && previousTotal == p.total
        let owner = origin(ofSnapshot: key, ts: ts, countsAsEvent: p.hasInfo && !repeated)

        // The quota snapshot is the account's state at the moment the event was written. A copied line carries the
        // time of the copy instead, so it would pass off an old figure as a current one and is ignored. A reading
        // dated in the future cannot be a real observation either.
        if let rate = p.rate, owner == .own, ts <= Clock.nowMs() + Self.futureSkewMs { quota(rate, ts: ts) }
        if p.hasInfo, p.total == nil || p.last == nil { unreadableUsageLines += 1 }
        guard p.hasInfo, let total = p.total, let last = p.last else { return }
        defer { previousTotal = total }

        // A repeated snapshot carries the same running totals as the one before it. It reports no new response.
        if repeated || owner != .own { return }
        snapshots.append(PendingSnapshot(ts: ts, ordinal: ordinal, lineNumber: lineNumber, total: total, last: last,
                                         previous: previousTotal, model: model, tier: serviceTier))
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
    private func quota(_ rate: CodexRateLimits, ts: Int64) {
        let limit = rate.limitID ?? "codex"
        let poolKey = limit == "codex" ? "codex" : "openai-limit:" + limit
        let account = AccountRef.identified(provider: .openAI, rawIdentifier: accountRaw)
        for w in rate.windows where w.usedPercent.isFinite && w.usedPercent >= 0 {
            let key = w.minutes.map { WindowNaming.key(minutes: $0) } ?? w.slot
            pendingQuota.append(QuotaObservation(
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
            if c.equals(key, "thread_id") { if let v = Self.readText(&c) { p.threadID = v; return true }; return false }
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
            if c.equals(key, "compaction_response_id") { if let v = Self.readText(&c) { p.compactionResponseID = v; return true }; return false }
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
            if c.equals(key, "thread_token_usage") { return parseUsage(&c, into: &p.threadUsage) }
            if c.equals(key, "latest_token_usage_record") {
                c.skipWhitespace()
                guard c.peek == 0x7B else { return false }
                return c.forEachMember { c, k in
                    if c.equals(k, "response_id") { if let v = Self.readText(&c) { p.compactionResponseID = v; return true }; return false }
                    if c.equals(k, "thread_id") { if let v = Self.readText(&c) { p.compactionThreadID = v; return true }; return false }
                    if c.equals(k, "usage") { return parseUsage(&c, into: &p.compactionUsage) }
                    return false
                }
            }
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
