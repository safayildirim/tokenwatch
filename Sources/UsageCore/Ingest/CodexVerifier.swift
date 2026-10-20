import Foundation
import SQLite3

/// Recounts the token usage of Codex sessions directly from the original files and compares it with the database.
///
/// The recount shares no code with the importer. It decodes lines with Foundation's JSON parser instead of the
/// streaming scanner, and it does not use the figures that the importer relies on to count a response. For a
/// session written the older way it adds up the growth of the running totals between events, where the importer
/// uses the per-response figures of each event. Agreement between the two therefore verifies the importer, the
/// deduplication and the storage together.
///
/// Codex also keeps its own per-thread token count in `state_5.sqlite`. It can be compared as a second opinion. It
/// is evidence only: it is built from the same events, and it knows nothing of responses that have a usage record
/// but no event, nor of the history that a fork copied from its parent.
public struct CodexVerifier: Sendable {
    public struct Counts: Sendable, Equatable {
        public var input: Int64 = 0       // Including the cached part, as OpenAI reports it.
        public var cached: Int64 = 0
        public var output: Int64 = 0
        public var reasoning: Int64 = 0
        public var responses = 0
        public var total: Int64 { input + output }
    }

    public struct Mismatch: Sendable, Equatable {
        public var sessionID: String
        public var mode: String
        public var expected: Counts
        public var database: Counts
    }

    public struct StateComparison: Sendable, Equatable {
        public var threads = 0
        public var equal = 0
        /// Threads where the database counts more than Codex's own figure.
        public var databaseHigher = 0
        public var databaseLower = 0
        /// The surplus, in tokens, that the database has over Codex's figure for the sessions where it is higher.
        public var surplusTokens: Int64 = 0
        public var examples: [String] = []
    }

    public struct Report: Sendable, Equatable {
        public var filesChecked = 0
        public var sessionsChecked = 0
        public var expected = Counts()
        public var database = Counts()
        public var mismatches: [Mismatch] = []
        /// Sessions counted by their usage records, by their events, and the forks whose copied history is excluded.
        public var recordSessions = 0
        public var eventSessions = 0
        public var forkSessions = 0
        public var state: StateComparison?
        public var isConsistent: Bool { mismatches.isEmpty && expected.total == database.total }
    }

    let db: UsageDatabase
    let adapter: CodexAdapter

    public init(db: UsageDatabase, adapter: CodexAdapter = CodexAdapter()) {
        self.db = db
        self.adapter = adapter
    }

    private struct Totals { var c = Counts(); var mode = "events"; var fork = false }

    public func verify(stateDatabase: URL? = nil, progress: ((Int, Int) -> Void)? = nil) throws -> Report {
        var report = Report()
        let files = try adapter.discoverFiles()
        var expected: [String: Totals] = [:]
        for (index, file) in files.enumerated() {
            progress?(index, files.count)
            guard let (id, totals) = try recount(file) else { continue }
            report.filesChecked += 1
            // A session present in two copies is counted from the first copy found.
            if expected[id] == nil { expected[id] = totals }
        }

        let stored: [String: Counts] = try db.read { c in
            var out: [String: Counts] = [:]
            let rows = try c.query("""
                SELECT s.external_id, COALESCE(sum(COALESCE(r.uncached_input_tokens, 0) + COALESCE(r.cache_read_tokens, 0)), 0),
                       COALESCE(sum(COALESCE(r.cache_read_tokens, 0)), 0), COALESCE(sum(r.output_tokens), 0),
                       COALESCE(sum(COALESCE(r.reasoning_output_tokens, 0)), 0), count(r.id)
                FROM session s JOIN product p ON p.id = s.product_id LEFT JOIN model_request r ON r.session_id = s.id
                WHERE p.provider_id = ? GROUP BY s.id
                """, [.text(ProviderID.openAI.rawValue)]) { row in
                var counts = Counts()
                counts.input = row.int(1); counts.cached = row.int(2); counts.output = row.int(3)
                counts.reasoning = row.int(4); counts.responses = Int(row.int(5))
                return (row.text(0), counts)
            }
            for (id, counts) in rows { out[id] = counts }
            return out
        }

        report.sessionsChecked = expected.count
        for (id, e) in expected.sorted(by: { $0.key < $1.key }) {
            let d = stored[id] ?? Counts()
            report.expected.input += e.c.input; report.expected.cached += e.c.cached
            report.expected.output += e.c.output; report.expected.reasoning += e.c.reasoning; report.expected.responses += e.c.responses
            report.database.input += d.input; report.database.cached += d.cached
            report.database.output += d.output; report.database.reasoning += d.reasoning; report.database.responses += d.responses
            switch (e.mode, e.fork) {
            case (_, true): report.forkSessions += 1
            case ("records", _): report.recordSessions += 1
            default: report.eventSessions += 1
            }
            // The number of responses may legitimately differ, because a response that has no event of its own is stored
            // as a request of its own while the recount sees it only as growth of the totals.
            if e.c.input != d.input || e.c.cached != d.cached || e.c.output != d.output || e.c.reasoning != d.reasoning {
                report.mismatches.append(Mismatch(sessionID: id, mode: e.mode, expected: e.c, database: d))
            }
        }

        if let stateDatabase { report.state = try compareWithState(stateDatabase, stored: stored, expected: expected) }
        return report
    }

    // MARK: Recount

    private func recount(_ file: SourceFileRef) throws -> (String, Totals)? {
        let data = try Self.read(file)
        var sessionID: String?
        var forkCutoffMs: Int64?
        var totals = Totals()
        var usageRecords = Counts()
        var usageRecordSeen = false
        var previous: [String: Int64]?
        var eventCounts = Counts()

        let keys = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"]
        func ints(_ dict: [String: Any]) -> [String: Int64] {
            Dictionary(uniqueKeysWithValues: keys.map { ($0, (dict[$0] as? NSNumber)?.int64Value ?? 0) })
        }
        func ms(_ iso: String?) -> Int64? { iso.flatMap { ISO8601Fast.parse($0) } }

        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? end + 1 : end
            // Only lines that can matter are decoded.
            guard line.range(of: Data("\"session_meta\"".utf8)) != nil || line.range(of: Data("\"token_".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { continue }
            let at = ms(object["timestamp"] as? String)
            if type == "session_meta", sessionID == nil {
                sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String)
                if payload["forked_from_id"] as? String != nil, let created = ms(payload["timestamp"] as? String) {
                    forkCutoffMs = created + 1500
                    totals.fork = true
                }
            }
            let replayed = forkCutoffMs.map { cutoff in at.map { $0 <= cutoff } ?? false } ?? false
            if type == "token_usage_record", let usage = payload["usage"] as? [String: Any] {
                usageRecordSeen = true
                if !replayed {
                    let u = ints(usage)
                    usageRecords.input += u["input_tokens"]!; usageRecords.cached += u["cached_input_tokens"]!
                    usageRecords.output += u["output_tokens"]!; usageRecords.reasoning += u["reasoning_output_tokens"]!
                    usageRecords.responses += 1
                }
            } else if type == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] {
                let t = ints(total)
                if previous == t { continue }
                if !replayed {
                    // The growth of the running totals, except for the first event, which has no earlier total to subtract.
                    let growth: [String: Int64] = previous.map { prev in t.reduce(into: [:]) { $0[$1.key] = $1.value - (prev[$1.key] ?? 0) } } ?? ints(last)
                    eventCounts.input += growth["input_tokens"]!; eventCounts.cached += growth["cached_input_tokens"]!
                    eventCounts.output += growth["output_tokens"]!; eventCounts.reasoning += growth["reasoning_output_tokens"]!
                    eventCounts.responses += 1
                }
                previous = t
            }
        }
        guard let id = sessionID ?? Optional(file.sessionHint) else { return nil }
        totals.mode = usageRecordSeen ? "records" : "events"
        totals.c = usageRecordSeen ? usageRecords : eventCounts
        return (id, totals)
    }

    private static func read(_ file: SourceFileRef) throws -> Data {
        guard file.isCompressed else { return try Data(contentsOf: URL(fileURLWithPath: file.path), options: .mappedIfSafe) }
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { throw FileAccessError(path: file.path, message: String(cString: strerror(errno)), code: errno) }
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

    // MARK: Codex's own figures

    private func compareWithState(_ url: URL, stored: [String: Counts], expected: [String: Totals]) throws -> StateComparison {
        // Codex's database is in write-ahead mode and in use. A copy is read instead, so that nothing in Codex's
        // folder is ever locked or modified.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("codex-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("state.sqlite")
        try FileManager.default.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: companion.path) {
                try? FileManager.default.copyItem(at: companion, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            throw FileAccessError(path: url.path, message: "could not open Codex's state database", code: EIO)
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT id, tokens_used FROM threads", -1, &statement, nil) == SQLITE_OK else {
            throw FileAccessError(path: url.path, message: "Codex's state database has no threads table", code: EIO)
        }
        defer { sqlite3_finalize(statement) }
        var result = StateComparison()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: cString)
            let theirs = sqlite3_column_int64(statement, 1)
            guard let mine = stored[id] else { continue }
            result.threads += 1
            if mine.total == theirs { result.equal += 1 }
            else if mine.total > theirs {
                result.databaseHigher += 1
                result.surplusTokens += mine.total - theirs
                if result.examples.count < 6 { result.examples.append("\(id.prefix(8)) \(expected[id]?.mode ?? "?"): database \(mine.total), Codex \(theirs)") }
            } else {
                result.databaseLower += 1
                if result.examples.count < 6 { result.examples.append("\(id.prefix(8)) \(expected[id]?.fork == true ? "fork" : "?"): database \(mine.total), Codex \(theirs)") }
            }
        }
        return result
    }
}
