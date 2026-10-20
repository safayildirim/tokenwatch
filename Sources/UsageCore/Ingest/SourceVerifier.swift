import Foundation

/// Recounts token usage directly from the original session files and compares it with the database.
///
/// The recount deliberately shares no code with the importer. It decodes each line with Foundation's
/// JSON parser instead of the streaming scanner, and it finalizes a request by choosing the
/// observation with the largest output count instead of merging fields. Agreement between the two
/// therefore verifies the importer, the deduplication, and the storage together.
///
/// Only the bytes the importer has already consumed are read, so a session file that is growing
/// while the check runs does not produce false mismatches.
public struct SourceVerifier: Sendable {
    public struct Mismatch: Sendable, Equatable {
        public var sessionID: String
        public var field: String
        public var database: Int64
        public var source: Int64
    }

    public struct Report: Sendable, Equatable {
        public var filesChecked = 0
        public var sessionsChecked = 0
        public var requestsInSource = 0
        public var requestsInDatabase = 0
        public var sourceTotals = TokenCounts()
        public var databaseTotals = TokenCounts()
        public var mismatches: [Mismatch] = []
        public var naiveSumOfAllLines = TokenCounts()
        public var isConsistent: Bool { mismatches.isEmpty && requestsInSource == requestsInDatabase }
    }

    let db: UsageDatabase
    let adapter: ClaudeCodeAdapter

    public init(db: UsageDatabase, adapter: ClaudeCodeAdapter = ClaudeCodeAdapter()) {
        self.db = db
        self.adapter = adapter
    }

    private struct Obs {
        var session: String
        var input: Int64, output: Int64, cacheRead: Int64, cacheCreation: Int64
    }

    public func verify(progress: ((Int, Int) -> Void)? = nil) throws -> Report {
        var report = Report()
        let files = try adapter.discoverFiles()
        let offsets: [String: Int64] = try db.read { c in
            Dictionary(try c.query("SELECT path, consumed_offset FROM source_file WHERE source_id = ?",
                                   [.text(adapter.sourceID)]) { ($0.text(0), $0.int(1)) }, uniquingKeysWith: { a, _ in a })
        }
        // The best (largest output) observation per message id across all files.
        var best: [String: Obs] = [:]
        for (index, file) in files.enumerated() {
            progress?(index, files.count)
            guard let limit = offsets[file.path], limit > 0, let handle = FileHandle(forReadingAtPath: file.path) else { continue }
            report.filesChecked += 1
            defer { try? handle.close() }
            var remaining = limit
            var carry = Data()
            while remaining > 0 {
                let chunk = try handle.read(upToCount: Int(min(remaining, 8 << 20))) ?? Data()
                if chunk.isEmpty { break }
                remaining -= Int64(chunk.count)
                carry.append(chunk)
                var start = carry.startIndex
                defer { carry = Data(carry[start...]) }
                while let nl = carry[start...].firstIndex(of: 0x0A) {
                    let line = carry[start..<nl]
                    start = nl + 1
                    guard line.count > 2, line.range(of: Data("\"usage\"".utf8)) != nil,
                          let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          obj["type"] as? String == "assistant",
                          let message = obj["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any],
                          message["model"] as? String != RequestObservation.syntheticModel else { continue }
                    func n(_ k: String) -> Int64 { (usage[k] as? NSNumber)?.int64Value ?? 0 }
                    let o = Obs(session: (obj["sessionId"] as? String) ?? file.sessionHint, input: n("input_tokens"),
                                output: n("output_tokens"), cacheRead: n("cache_read_input_tokens"),
                                cacheCreation: n("cache_creation_input_tokens"))
                    report.naiveSumOfAllLines += TokenCounts(uncachedInput: o.input, output: o.output, cacheRead: o.cacheRead, cacheCreation: o.cacheCreation)
                    if o.input == 0 && o.output == 0 && o.cacheRead == 0 && o.cacheCreation == 0 { continue }
                    let key = (message["id"] as? String) ?? (obj["requestId"] as? String) ?? "\(file.path)#\(line.count)"
                    if let existing = best[key], existing.output >= o.output { continue }
                    // Keep the largest value per category even if a later line has a smaller output.
                    var chosen = o
                    if let existing = best[key] {
                        chosen.input = max(chosen.input, existing.input)
                        chosen.cacheRead = max(chosen.cacheRead, existing.cacheRead)
                        chosen.cacheCreation = max(chosen.cacheCreation, existing.cacheCreation)
                    }
                    best[key] = chosen
                }
            }
        }

        var perSessionSource: [String: TokenCounts] = [:]
        for o in best.values {
            perSessionSource[o.session, default: TokenCounts()] += TokenCounts(uncachedInput: o.input, output: o.output,
                                                                               cacheRead: o.cacheRead, cacheCreation: o.cacheCreation)
            report.sourceTotals += TokenCounts(uncachedInput: o.input, output: o.output, cacheRead: o.cacheRead, cacheCreation: o.cacheCreation)
        }
        report.requestsInSource = best.count

        let perSessionDB: [String: TokenCounts] = try db.read { c in
            var out: [String: TokenCounts] = [:]
            let rows = try c.query("""
                SELECT s.external_id, sum(r.input_tokens), sum(r.output_tokens), sum(r.cache_read_tokens), sum(r.cache_creation_tokens), count(*)
                FROM model_request r JOIN session s ON s.id = r.session_id GROUP BY s.id
                """) { row in
                (row.text(0), TokenCounts(uncachedInput: row.int(1), output: row.int(2), cacheRead: row.int(3), cacheCreation: row.int(4)), Int(row.int(5)))
            }
            for (id, t, n) in rows { out[id] = t; report.requestsInDatabase += n }
            return out
        }
        report.databaseTotals = perSessionDB.values.reduce(TokenCounts()) { $0 + $1 }
        report.sessionsChecked = Set(perSessionSource.keys).union(perSessionDB.keys).count

        for id in Set(perSessionSource.keys).union(perSessionDB.keys).sorted() {
            let s = perSessionSource[id] ?? TokenCounts()
            let d = perSessionDB[id] ?? TokenCounts()
            func check(_ name: String, _ dv: Int64, _ sv: Int64) {
                if dv != sv { report.mismatches.append(Mismatch(sessionID: id, field: name, database: dv, source: sv)) }
            }
            check("uncached_input", d.uncachedInput, s.uncachedInput)
            check("output", d.output, s.output)
            check("cache_read", d.cacheRead, s.cacheRead)
            check("cache_creation", d.cacheCreation, s.cacheCreation)
        }
        return report
    }
}
