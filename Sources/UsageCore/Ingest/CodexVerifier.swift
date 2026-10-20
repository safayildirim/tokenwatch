import Foundation
import SQLite3

/// Recounts the token usage of Codex sessions directly from the original files and compares it with the database.
///
/// The recount shares no code with the importer and uses a different method. It decodes lines with Foundation's JSON
/// parser instead of the streaming scanner. It does not add up the figures of individual responses, which is what the
/// importer does. It reads the running counters that Codex keeps itself, and counts how far they grew:
///
/// - A session with usage records is measured by the `thread_token_usage` counter of its records, which Codex grows by
///   the usage of every response it records, including the ones that never produce a `token_count` event, such as
///   the request that summarizes a conversation when it is compacted.
/// - A session written the older way is measured by the growth of the running totals of its `token_count` events.
///   A counter that goes down was reset, and counting starts again from its new value.
/// - A fork copies its parent's history, counter included. Its own usage is how far the counter grew beyond the point
///   up to which the fork repeats its parent line by line.
///
/// Agreement therefore verifies the importer, the deduplication and the storage together, and a disagreement between a
/// session's counter and the sum of its records is reported as well.
///
/// Codex also keeps its own per-thread token count in `state_5.sqlite`. It can be compared as a second opinion. It
/// is evidence only: it is built from the `token_count` events, so it knows nothing of responses that have a usage
/// record but no event, nor of the history that a fork copied from its parent.
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
        /// Sessions where the thread's own counter and the sum of its records disagree. That means usage the records do not show.
        public var counterDisagreements: [String] = []
        public var state: StateComparison?
        public var isConsistent: Bool { mismatches.isEmpty && expected.total == database.total }
    }

    let db: UsageDatabase
    let adapter: CodexAdapter

    public init(db: UsageDatabase, adapter: CodexAdapter = CodexAdapter()) {
        self.db = db
        self.adapter = adapter
    }

    private struct Totals { var c = Counts(); var mode = "events"; var fork = false; var counterAgreesWithRecords = true }

    /// The four figures that are compared, in the order input, cached, output, reasoning.
    private typealias Figures = [Int64]

    /// What one file says, reduced to what the recount needs.
    private struct Recording {
        var id: String
        var forkedFrom: String?
        /// Distinct records in file order: response id, the response's own usage, and the thread counter after it.
        var records: [(id: String, usage: Figures, counter: Figures?)] = []
        /// The running totals of the `token_count` events, with repeated snapshots removed.
        var totals: [Figures] = []
    }

    public func verify(stateDatabase: URL? = nil, progress: ((Int, Int) -> Void)? = nil) throws -> Report {
        var report = Report()
        let files = try adapter.discoverFiles()
        var recordings: [String: Recording] = [:]
        for (index, file) in files.enumerated() {
            progress?(index, files.count)
            guard let recording = try recount(file) else { continue }
            report.filesChecked += 1
            // A session present in two copies is counted from the first copy found.
            if recordings[recording.id] == nil { recordings[recording.id] = recording }
        }
        var expected: [String: Totals] = [:]
        for (id, recording) in recordings { expected[id] = Self.expectedTotals(recording, parent: recording.forkedFrom.flatMap { recordings[$0] }) }

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
            if !e.counterAgreesWithRecords { report.counterDisagreements.append(id) }
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

    private func recount(_ file: SourceFileRef) throws -> Recording? {
        let data = try CodexFileContents.read(path: file.path)
        var recording = Recording(id: file.sessionHint)
        var sawHeader = false
        var seenResponses = Set<String>()
        var previousTotal: Figures?

        func figures(_ dict: [String: Any]?) -> Figures? {
            guard let dict else { return nil }
            return ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"].map { (dict[$0] as? NSNumber)?.int64Value ?? 0 }
        }
        func record(id: String?, usage: [String: Any]?, counter: [String: Any]?) {
            guard let id, let u = figures(usage), seenResponses.insert(id).inserted else { return }
            recording.records.append((id, u, figures(counter)))
        }

        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? end + 1 : end
            // Only lines that can matter are decoded.
            guard line.range(of: Data("\"session_meta\"".utf8)) != nil || line.range(of: Data("\"token_".utf8)) != nil
                    || line.range(of: Data("\"latest_token_usage_record\"".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { continue }
            if type == "session_meta", !sawHeader {
                sawHeader = true
                recording.id = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? recording.id
                recording.forkedFrom = payload["forked_from_id"] as? String
            } else if type == "token_usage_record" {
                record(id: payload["response_id"] as? String, usage: payload["usage"] as? [String: Any],
                       counter: payload["thread_token_usage"] as? [String: Any])
            } else if type == "compacted", let latest = payload["latest_token_usage_record"] as? [String: Any] {
                record(id: latest["response_id"] as? String, usage: latest["usage"] as? [String: Any], counter: nil)
            } else if type == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any], let total = figures(info["total_token_usage"] as? [String: Any]) {
                if previousTotal == total { continue }
                previousTotal = total
                recording.totals.append(total)
            }
        }
        return recording
    }

    /// How far a series of cumulative figures grew. A figure that goes down means the counter was reset, and counting
    /// starts again from the new value.
    private static func growth(_ series: [Figures], from base: Figures? = nil) -> Figures {
        var sum: Figures = [0, 0, 0, 0]
        var previous = base ?? [0, 0, 0, 0]
        for value in series {
            let reset = zip(value, previous).contains { $0 < $1 }
            for i in 0..<4 { sum[i] += reset ? value[i] : value[i] - previous[i] }
            previous = value
        }
        return sum
    }

    private static func expectedTotals(_ r: Recording, parent: Recording?) -> Totals {
        var totals = Totals()
        totals.fork = r.forkedFrom != nil
        var figures: Figures
        var responses = r.records.count
        if !r.records.isEmpty {
            totals.mode = "records"
            // What the fork repeats from its parent: the records whose response the parent also has.
            let inheritedIDs = Set(parent?.records.map(\.id) ?? [])
            let own = r.records.filter { !inheritedIDs.contains($0.id) }
            let inheritedCounter = r.records.last(where: { inheritedIDs.contains($0.id) })?.counter
            let counters = own.compactMap(\.counter)
            // The counter of the thread's own records, from the point the fork diverges from its parent.
            figures = counters.count == own.count && !counters.isEmpty
                ? growth(counters, from: inheritedCounter) : growth(own.map(\.usage))
            let summed = own.reduce(into: [Int64](repeating: 0, count: 4)) { acc, record in for i in 0..<4 { acc[i] += record.usage[i] } }
            totals.counterAgreesWithRecords = (counters.count != own.count || counters.isEmpty) ? true : summed == figures
        } else {
            // The events of a fork that are also the parent's, in the same order, are its inherited history.
            var skip = 0
            if let parent { while skip < r.totals.count, skip < parent.totals.count, r.totals[skip] == parent.totals[skip] { skip += 1 } }
            figures = growth(Array(r.totals.dropFirst(skip)), from: skip > 0 ? r.totals[skip - 1] : nil)
            responses = r.totals.count - skip
        }
        totals.c.input = figures[0]; totals.c.cached = figures[1]; totals.c.output = figures[2]; totals.c.reasoning = figures[3]
        totals.c.responses = responses
        return totals
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
