import Foundation

public enum ExportKind: String, CaseIterable, Sendable, Identifiable {
    case sessions, requests, projects, models, daily, weekly, quotaHistory
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .sessions: "Session history"
        case .requests: "Request-level token usage"
        case .projects: "Project summary"
        case .models: "Model summary"
        case .daily: "Daily totals"
        case .weekly: "Weekly totals"
        case .quotaHistory: "Quota history"
        }
    }
}

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case csv, json
    public var id: String { rawValue }
}

public struct ExportResult: Sendable {
    public var url: URL
    public var rows: Int
}

/// This is one cell of an exported table.
enum Cell {
    case int(Int64)
    case real(Double)
    case text(String)
    case null
}

/// Writes tables as CSV or JSON.
///
/// Exports hold usage metadata only. They never include prompts, responses, file contents, or
/// credentials, because none of those are ever stored. Every export carries the definitions of its
/// metrics and the units of its columns, in the JSON document itself or in a companion
/// `.metadata.json` file next to a CSV.
public struct ExportService: Sendable {
    let db: UsageDatabase
    let analytics: AnalyticsEngine

    public init(db: UsageDatabase) {
        self.db = db
        self.analytics = AnalyticsEngine(db: db)
    }

    struct Column {
        var name: String
        var unit: String
        var definition: String
    }

    // MARK: Entry point

    public func export(kind: ExportKind, format: ExportFormat, range: ClosedRange<Date>? = nil, to url: URL,
                       calendar: Calendar = .current, filter base: UsageFilter = UsageFilter()) throws -> ExportResult {
        var filter = base
        if let range { filter.from = range.lowerBound; filter.to = range.upperBound.addingTimeInterval(0.001) }

        let columns: [Column]
        var rows = 0
        let sink = try TableSink(url: url, format: format)
        switch kind {
        case .sessions:
            columns = Self.sessionColumns
            try sink.begin(columns)
            for s in try analytics.sessionRows(filter) {
                try sink.write([
                    .text(s.externalID), .text(s.provider.rawValue), .text(s.productID.rawValue), .text(s.accountLabel),
                    .text(s.surface?.rawValue ?? ""), .text(s.kind.rawValue),
                    .text(s.projectName), .text(s.projectPath ?? ""),
                    .text(s.models.joined(separator: "; ")), .text(s.status.label),
                    .text(s.startedAt.map(Self.iso) ?? ""), .text(s.lastActivityAt.map(Self.iso) ?? ""),
                    s.duration.map { .real($0) } ?? .null, .int(Int64(s.requests)),
                    .int(s.tokens.uncachedInput), .int(s.tokens.output), .int(s.tokens.cacheRead),
                    .int(s.tokens.cacheCreation), .int(s.tokens.logicalInput), .int(s.tokens.totalProcessed),
                    s.tokens.cacheHitRatio.map { .real($0) } ?? .null,
                    .int(s.cost.picoUSD), .text(Self.usd(s.cost.picoUSD)), .int(s.cost.unpricedTokens),
                    s.reportedCostUSD.map { .real($0) } ?? .null,
                ])
                rows += 1
            }
        case .requests:
            columns = Self.requestColumns
            try sink.begin(columns)
            rows = try streamRequests(filter, sink: sink)
        case .projects:
            columns = Self.projectColumns
            try sink.begin(columns)
            for p in try analytics.projects(filter) {
                try sink.write([.text(p.name), .text(p.path ?? ""), .int(Int64(p.sessions)), .int(Int64(p.requests)),
                                .int(p.tokens.uncachedInput), .int(p.tokens.output), .int(p.tokens.cacheRead),
                                .int(p.tokens.cacheCreation), .int(p.tokens.totalProcessed), .real(p.tokenShare),
                                .int(p.cost.picoUSD), .text(Self.usd(p.cost.picoUSD)), .int(p.cost.unpricedTokens)])
                rows += 1
            }
        case .models:
            columns = Self.modelColumns
            try sink.begin(columns)
            for m in try analytics.models(filter) {
                try sink.write([.text(m.provider.rawValue), .text(m.canonical), .text(m.displayName), .int(Int64(m.requests)),
                                .int(m.tokens.uncachedInput), .int(m.tokens.output), .int(m.tokens.cacheRead),
                                .int(m.tokens.cacheCreation), .int(m.tokens.totalProcessed), .real(m.tokenShare),
                                m.tokens.cacheHitRatio.map { .real($0) } ?? .null,
                                .int(m.cost.picoUSD), .text(Self.usd(m.cost.picoUSD)), .int(m.cost.unpricedTokens)])
                rows += 1
            }
        case .daily, .weekly:
            columns = Self.periodColumns
            try sink.begin(columns)
            let granularity: Granularity = kind == .daily ? .day : .week
            for p in try analytics.series(filter, granularity: granularity, calendar: calendar) where p.requests > 0 {
                try sink.write([.text(Self.localDate(p.start, calendar)), .text(Self.iso(p.start)), .int(Int64(p.requests)),
                                .int(p.tokens.uncachedInput), .int(p.tokens.output), .int(p.tokens.cacheRead),
                                .int(p.tokens.cacheCreation), .int(p.tokens.totalProcessed),
                                .int(p.cost.picoUSD), .text(Self.usd(p.cost.picoUSD)), .int(p.cost.unpricedTokens)])
                rows += 1
            }
        case .quotaHistory:
            columns = Self.quotaColumns
            try sink.begin(columns)
            let from = filter.from.map(Clock.ms) ?? 0
            let to = filter.to.map(Clock.ms) ?? Int64.max
            let snapshots: [[Cell]] = try db.read { c in
                try c.query("""
                    SELECT p.provider_id, a.label, p.pool_key, w.window_key, w.duration_minutes, sn.utilization_pct,
                           sn.resets_at, sn.observed_at, sn.last_confirmed_at, sn.telemetry_source_id, sn.authority
                    FROM quota_snapshot sn
                    JOIN quota_window w ON w.id = sn.window_id
                    JOIN quota_pool p ON p.id = w.pool_id
                    JOIN account a ON a.id = p.account_id
                    WHERE sn.observed_at >= ? AND sn.observed_at < ? ORDER BY sn.observed_at
                    """, [.int(from), .int(to)]) { r in
                    [.text(r.text(0)), .text(r.text(1)), .text(r.text(2)), .text(r.text(3)),
                     r.intOrNil(4).map { .int($0) } ?? .null, .real(r.double(5)),
                     .text(r.intOrNil(6).map { Self.iso(Clock.date(ms: $0)) } ?? ""),
                     .text(Self.iso(Clock.date(ms: r.int(7)))), .text(Self.iso(Clock.date(ms: r.int(8)))),
                     .text(r.text(9)), .text(r.text(10))]
                }
            }
            for s in snapshots { try sink.write(s); rows += 1 }
        }
        try sink.finish(metadata: Self.metadata(kind: kind, columns: columns, range: range, rows: rows, calendar: calendar))
        return ExportResult(url: url, rows: rows)
    }

    /// Streams request rows straight from the database so that a very large history never has to fit in memory.
    private func streamRequests(_ filter: UsageFilter, sink: TableSink) throws -> Int {
        let w = filter.whereClause()
        var count = 0
        try db.read { c in
            let stmt = try c.prepare("""
                SELECT r.request_key, r.api_request_id, s.external_id, r.agent_key, m.raw_id, r.requested_at,
                       r.uncached_input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_creation_tokens,
                       r.cache_creation_5m_tokens, r.cache_creation_1h_tokens, r.reasoning_output_tokens,
                       r.speed, r.stop_reason, r.completeness, r.normalization,
                       \(CostSQL.picoUSD), p.id IS NULL, r.product_id, m.provider_id
                FROM model_request r JOIN session s ON s.id = r.session_id JOIN model m ON m.id = r.model_id
                LEFT JOIN project pj ON pj.id = s.project_id \(CostSQL.join)
                \(w.sql) ORDER BY r.requested_at, r.id
                """)
            try stmt.bind(w.params)
            defer { stmt.reset() }
            func optional(_ row: SQLiteRow, _ i: Int32) -> Cell { row.intOrNil(i).map { .int($0) } ?? .null }
            while try stmt.step() {
                let row = SQLiteRow(stmt: stmt)
                let pico = row.int(17)
                let unpriced = row.int(18) != 0
                let uncached = row.intOrNil(6) ?? 0, out = row.int(7), cr = row.intOrNil(8) ?? 0, cc = row.intOrNil(9) ?? 0
                try sink.write([
                    .text(row.text(0)), .text(row.textOrNil(1) ?? ""), .text(row.text(2)), .text(row.textOrNil(3) ?? ""),
                    .text(row.text(20)), .text(row.text(19)),
                    .text(row.text(4)), .text(Self.iso(Clock.date(ms: row.int(5)))), .int(row.int(5)),
                    optional(row, 6), .int(out), optional(row, 8), optional(row, 9),
                    optional(row, 10), optional(row, 11), optional(row, 12),
                    .int(uncached + cr + cc), .int(uncached + cr + cc + out),
                    .text(row.textOrNil(13) ?? ""), .text(row.textOrNil(14) ?? ""),
                    .text(row.text(15)), .text(row.text(16)),
                    unpriced ? .null : .int(pico), unpriced ? .text("") : .text(Self.usd(pico)),
                ])
                count += 1
            }
        }
        return count
    }

    // MARK: Formatting helpers

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func localDate(_ d: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Formats pico-USD as an exact decimal dollar amount.
    static func usd(_ pico: Int64) -> String {
        let whole = pico / 1_000_000_000_000
        let frac = pico % 1_000_000_000_000
        var fraction = String(format: "%012lld", frac)
        while fraction.hasSuffix("0") && fraction.count > 2 { fraction.removeLast() }
        return "\(whole).\(fraction)"
    }

    // MARK: Column definitions

    private static let tokenDefs: [(String, String)] = [
        ("uncached_input_tokens", "Input tokens that were neither read from nor written to the prompt cache."),
        ("output_tokens", "Tokens generated by the model."),
        ("cache_read_tokens", "Input tokens served from the prompt cache."),
        ("cache_creation_tokens", "Input tokens written to the prompt cache."),
    ]

    private static func tokenColumns() -> [Column] {
        tokenDefs.map { Column(name: $0.0, unit: "tokens", definition: $0.1) }
    }

    private static let costColumns: [Column] = [
        Column(name: "estimated_cost_pico_usd", unit: "pico-USD (1e-12 USD)", definition: "API-equivalent cost estimate as an exact integer. It is not a subscription charge. Empty when the model has no rate card."),
        Column(name: "estimated_cost_usd", unit: "USD", definition: "The same estimate as an exact decimal number of US dollars."),
        Column(name: "unpriced_tokens", unit: "tokens", definition: "Logical input plus output tokens that could not be priced. When above zero, the cost is a lower bound."),
    ]

    static let sessionColumns: [Column] = [
        Column(name: "session_id", unit: "", definition: "The session identifier assigned by the product."),
        Column(name: "provider", unit: "", definition: "The provider that delivered the model."),
        Column(name: "product", unit: "", definition: "The product that produced the session."),
        Column(name: "account", unit: "", definition: "A short label of the account. It is derived from a one-way hash, and Unassigned means the source did not say."),
        Column(name: "surface", unit: "", definition: "Where the session ran, for example a terminal, an editor or a desktop application."),
        Column(name: "kind", unit: "", definition: "main, subagent or review."),
        Column(name: "project", unit: "", definition: "Project name derived from the working directory."),
        Column(name: "project_path", unit: "", definition: "Project root directory, when known."),
        Column(name: "models", unit: "", definition: "Models used, most-used first."),
        Column(name: "status", unit: "", definition: "Active, Idle, Completed or Unknown. A status marked (inferred) is guessed from recent activity rather than observed."),
        Column(name: "started_at", unit: "ISO 8601 UTC", definition: "Time of the first record of the session."),
        Column(name: "last_activity_at", unit: "ISO 8601 UTC", definition: "Time of the latest record of the session."),
        Column(name: "duration_seconds", unit: "seconds", definition: "Time between the first and latest record."),
        Column(name: "requests", unit: "count", definition: "Distinct model requests, including those made by sub-agents."),
    ] + tokenColumns() + [
        Column(name: "logical_input_tokens", unit: "tokens", definition: "uncached_input + cache_read + cache_creation."),
        Column(name: "total_processed_tokens", unit: "tokens", definition: "logical_input + output."),
        Column(name: "cache_hit_ratio", unit: "ratio 0-1", definition: "cache_read / logical_input."),
    ] + costColumns + [
        Column(name: "source_reported_cost_usd", unit: "USD", definition: "The cost summary that the source itself recorded for the session, for the sources that do. Kept separate from the estimate."),
    ]

    static let requestColumns: [Column] = [
        Column(name: "request_key", unit: "", definition: "Stable request identity within the product (the API message id or response id when the source records one)."),
        Column(name: "api_request_id", unit: "", definition: "Server-assigned request id, when recorded."),
        Column(name: "session_id", unit: "", definition: "Owning session."),
        Column(name: "agent_id", unit: "", definition: "Sub-agent that made the request. Empty for the main conversation."),
        Column(name: "provider", unit: "", definition: "The provider that delivered the model."),
        Column(name: "product", unit: "", definition: "The product that made the request."),
        Column(name: "model", unit: "", definition: "Model identifier as reported."),
        Column(name: "requested_at", unit: "ISO 8601 UTC", definition: "Time of the first record of the request."),
        Column(name: "requested_at_epoch_ms", unit: "milliseconds", definition: "Same instant as milliseconds since 1970-01-01 UTC."),
    ] + tokenColumns() + [
        Column(name: "cache_creation_5m_tokens", unit: "tokens", definition: "Portion of cache_creation written with a five-minute lifetime, when the source states it."),
        Column(name: "cache_creation_1h_tokens", unit: "tokens", definition: "Portion of cache_creation written with a one-hour lifetime, when the source states it."),
        Column(name: "reasoning_output_tokens", unit: "tokens", definition: "The part of output_tokens spent on reasoning. It is already included in output_tokens and is never added to it. Empty when the source does not report it."),
        Column(name: "logical_input_tokens", unit: "tokens", definition: "uncached_input + cache_read + cache_creation. A category the source did not report counts as zero here."),
        Column(name: "total_processed_tokens", unit: "tokens", definition: "logical_input + output."),
        Column(name: "speed", unit: "", definition: "Service speed reported with the request."),
        Column(name: "stop_reason", unit: "", definition: "Why the model stopped."),
        Column(name: "completeness", unit: "", definition: "complete, reconciledFromTotals (derived from cumulative counters) or partial."),
        Column(name: "normalization", unit: "", definition: "The rule used to convert the source's token counts into these categories."),
    ] + Array(costColumns.prefix(2))

    static let projectColumns: [Column] = [
        Column(name: "project", unit: "", definition: "Project name."),
        Column(name: "project_path", unit: "", definition: "Project root directory, when known."),
        Column(name: "sessions", unit: "count", definition: "Sessions with requests in the period."),
        Column(name: "requests", unit: "count", definition: "Distinct model requests."),
    ] + tokenColumns() + [
        Column(name: "total_processed_tokens", unit: "tokens", definition: "logical_input + output."),
        Column(name: "token_share", unit: "ratio 0-1", definition: "Share of all processed tokens in the period."),
    ] + costColumns

    static let modelColumns: [Column] = [
        Column(name: "provider", unit: "", definition: "The provider that delivered the model."),
        Column(name: "model", unit: "", definition: "Canonical model key."),
        Column(name: "display_name", unit: "", definition: "Readable model name."),
        Column(name: "requests", unit: "count", definition: "Distinct model requests."),
    ] + tokenColumns() + [
        Column(name: "total_processed_tokens", unit: "tokens", definition: "logical_input + output."),
        Column(name: "token_share", unit: "ratio 0-1", definition: "Share of all processed tokens in the period."),
        Column(name: "cache_hit_ratio", unit: "ratio 0-1", definition: "cache_read / logical_input."),
    ] + costColumns

    static let periodColumns: [Column] = [
        Column(name: "period_start_local", unit: "date, local time zone", definition: "First day of the period in the exporting machine's time zone."),
        Column(name: "period_start_utc", unit: "ISO 8601 UTC", definition: "The same instant in UTC."),
        Column(name: "requests", unit: "count", definition: "Distinct model requests that started in the period."),
    ] + tokenColumns() + [
        Column(name: "total_processed_tokens", unit: "tokens", definition: "logical_input + output."),
    ] + costColumns

    static let quotaColumns: [Column] = [
        Column(name: "provider", unit: "", definition: "The provider that enforces the allowance."),
        Column(name: "account", unit: "", definition: "A short label of the account that owns the pool."),
        Column(name: "pool", unit: "", definition: "The quota pool that the window belongs to. Pools are never added together."),
        Column(name: "window", unit: "", definition: "The window key, which is its length in minutes for fixed windows, such as 300m or 10080m."),
        Column(name: "window_minutes", unit: "minutes", definition: "The length of the window, when it has a fixed length."),
        Column(name: "utilization_percent", unit: "percent", definition: "Percentage of the allowance consumed, as reported by the provider. Never derived from token counts."),
        Column(name: "resets_at", unit: "ISO 8601 UTC", definition: "When the window resets."),
        Column(name: "observed_at", unit: "ISO 8601 UTC", definition: "When the value was first reported."),
        Column(name: "last_confirmed_at", unit: "ISO 8601 UTC", definition: "When the same value was most recently reported again."),
        Column(name: "telemetry_source", unit: "", definition: "Where the value came from."),
        Column(name: "authority", unit: "", definition: "authoritative or unverified."),
    ]

    private static func metadata(kind: ExportKind, columns: [Column], range: ClosedRange<Date>?, rows: Int, calendar: Calendar) -> [String: Any] {
        var m: [String: Any] = [
            "export": kind.rawValue,
            "generated_at": iso(Date()),
            "time_zone": calendar.timeZone.identifier,
            "rows": rows,
            "pricing_note": "Cost columns are API-equivalent estimates from published list prices (as of \(PricingCatalog.asOf)). They are not subscription charges.",
            "quota_note": "Subscription utilization is only ever taken from values reported by the provider. It is never computed from token counts, and the utilization of different pools is never added together.",
            "privacy_note": "Contains usage metadata only. No prompts, responses, source code or credentials.",
            "columns": columns.map { ["name": $0.name, "unit": $0.unit, "definition": $0.definition] },
        ]
        if let range { m["range"] = ["from": iso(range.lowerBound), "to": iso(range.upperBound)] }
        return m
    }
}

/// Writes rows to a file as they are produced.
final class TableSink {
    private let handle: FileHandle
    private let url: URL
    private let format: ExportFormat
    private var columns: [ExportService.Column] = []
    private var wroteFirstRow = false
    private var buffer = Data()

    init(url: URL, format: ExportFormat) throws {
        self.url = url
        self.format = format
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func begin(_ columns: [ExportService.Column]) throws {
        self.columns = columns
        switch format {
        case .csv:
            append(columns.map { Self.csvEscape($0.name) }.joined(separator: ",") + "\r\n")
        case .json:
            append("{\"rows\":[")
        }
    }

    func write(_ cells: [Cell]) throws {
        switch format {
        case .csv:
            append(cells.map { cell in
                switch cell {
                case .int(let v): String(v)
                case .real(let v): Self.number(v)
                case .text(let s): Self.csvEscape(Self.neutralizeFormula(s))
                case .null: ""
                }
            }.joined(separator: ",") + "\r\n")
        case .json:
            var object = ""
            for (i, cell) in cells.enumerated() where i < columns.count {
                let value: String
                switch cell {
                case .int(let v): value = String(v)
                case .real(let v): value = Self.number(v)
                case .text(let s): value = Self.jsonString(s)
                case .null: value = "null"
                }
                object += (object.isEmpty ? "" : ",") + Self.jsonString(columns[i].name) + ":" + value
            }
            append((wroteFirstRow ? ",\n" : "\n") + "{" + object + "}")
            wroteFirstRow = true
        }
        if buffer.count > 1 << 20 { flush() }
    }

    func finish(metadata: [String: Any]) throws {
        switch format {
        case .csv:
            flush()
            let metaURL = url.deletingPathExtension().appendingPathExtension("metadata.json")
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metaURL)
        case .json:
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            append("\n],\"metadata\":" + String(decoding: data, as: UTF8.self) + "}\n")
            flush()
        }
        try handle.close()
    }

    private func append(_ s: String) { buffer.append(Data(s.utf8)) }
    private func flush() {
        _ = try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    static func number(_ v: Double) -> String {
        v.isFinite ? String(format: "%.12g", v) : ""
    }

    static func csvEscape(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// Prevents spreadsheet applications from interpreting a text cell as a formula. Project names
    /// come from directory names, which can begin with characters such as `=`.
    static func neutralizeFormula(_ s: String) -> String {
        guard let first = s.first, "=+-@\t\r".contains(first) else { return s }
        return "'" + s
    }

    static func jsonString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}
