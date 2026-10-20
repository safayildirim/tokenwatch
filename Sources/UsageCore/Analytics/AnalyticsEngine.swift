import Foundation

/// Read-only analytical queries over the request records.
///
/// Every number comes from the immutable request rows through a single query, so totals shown on
/// different screens always agree. Calendar concepts (today, this week, hourly buckets) are
/// resolved here using the calendar that the caller supplies, never stored in the database.
public struct AnalyticsEngine: Sendable {
    let db: UsageDatabase

    public init(db: UsageDatabase) { self.db = db }

    private static let from = """
        FROM model_request r
        JOIN session s ON s.id = r.session_id
        JOIN model m ON m.id = r.model_id
        LEFT JOIN project pj ON pj.id = s.project_id
        \(CostSQL.join)
        """

    /// The underlying resolution for time series. Fifteen minutes divides every real-world time
    /// zone offset, so regrouping into local hours, days or months is always exact.
    static let quantumMs: Int64 = 15 * 60 * 1000

    // MARK: Totals

    public func totals(_ filter: UsageFilter = UsageFilter()) throws -> UsageTotals {
        let w = filter.whereClause()
        return try db.read { c in
            try c.queryOne("""
                SELECT \(CostSQL.aggregateColumns), count(DISTINCT r.session_id)
                \(Self.from) \(w.sql)
                """, w.params) { row in
                var t = UsageTotals()
                let agg = CostSQL.readAggregate(row, from: 0)
                t.requests = agg.requests
                t.tokens = agg.tokens
                t.cost = agg.cost
                t.sessions = Int(row.int(9))
                return t
            } ?? UsageTotals()
        }
    }

    public func overview(now: Date = Date(), calendar: Calendar = .current, live: [String: LiveProcess] = [:],
                         policy: StatusPolicy = StatusPolicy()) throws -> OverviewSnapshot {
        var o = OverviewSnapshot()
        o.computedAt = now
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? dayStart
        o.today = try totals(UsageFilter(from: dayStart))
        o.thisWeek = try totals(UsageFilter(from: weekStart))
        o.thisMonth = try totals(UsageFilter(from: monthStart))
        // All-time figures are only counts. Summing every token with prices attached would scan the
        // whole history on each refresh, and no screen needs those sums.
        let counts = try db.read { c in
            (try c.scalarInt("SELECT count(*) FROM model_request") ?? 0, try c.scalarInt("SELECT count(*) FROM session") ?? 0)
        }
        o.allTime.requests = Int(counts.0)
        o.allTime.sessions = Int(counts.1)
        o.totalSessions = Int(counts.1)
        let sessions = try sessionRows(UsageFilter(from: Calendar.current.date(byAdding: .day, value: -2, to: now)),
                                       now: now, live: live, policy: policy)
        o.activeSessions = sessions.filter { $0.status.state == .active }.count
        return o
    }

    /// The number of sessions currently in the active state. This is cheap enough to run on every
    /// change, because it only looks at sessions that wrote recently plus the live process table.
    public func activeSessionCount(now: Date = Date(), live: [String: LiveProcess] = [:], policy: StatusPolicy = StatusPolicy()) throws -> Int {
        let floor = Clock.ms(now.addingTimeInterval(-policy.activeWithin))
        let rows: [(String, Int64?, Int64?)] = try db.read { c in
            try c.query("SELECT external_id, last_activity_at, observed_ended_at FROM session WHERE last_activity_at >= ?", [.int(floor)]) {
                ($0.text(0), $0.intOrNil(1), $0.intOrNil(2))
            }
        }
        var active = Set<String>()
        for (id, last, ended) in rows
        where SessionStatusResolver.resolve(now: now, lastActivityMs: last, observedEndedAtMs: ended, live: live[id], policy: policy).state == .active {
            active.insert(id)
        }
        for (id, process) in live where process.activity == .busy { active.insert(id) }
        return active.count
    }

    /// When the most recent session record was written, across all sessions.
    public func latestActivity() throws -> Date? {
        try db.read { c in try c.scalarInt("SELECT max(last_activity_at) FROM session") }.map { Clock.date(ms: $0) }
    }

    // MARK: Time series

    /// Token usage over time, bucketed in the calendar's time zone.
    public func series(_ filter: UsageFilter, granularity: Granularity, dimension: SeriesDimension = .none,
                       calendar: Calendar = .current) throws -> [SeriesPoint] {
        let w = filter.whereClause()
        let dimKey: String
        let dimLabel: String
        switch dimension {
        case .none: dimKey = "''"; dimLabel = "''"
        case .model: dimKey = "m.canonical"; dimLabel = "m.display_name"
        case .project: dimKey = "CAST(COALESCE(pj.id, 0) AS TEXT)"; dimLabel = "COALESCE(pj.name, 'No project')"
        }
        struct Raw { var bucket: Int64; var key: String; var label: String; var tokens: TokenCounts; var requests: Int; var cost: EstimatedCost }
        let rows: [Raw] = try db.read { c in
            try c.query("""
                SELECT r.requested_at / \(Self.quantumMs) AS b, \(dimKey), \(dimLabel), \(CostSQL.aggregateColumns)
                \(Self.from) \(w.sql)
                GROUP BY b, \(dimKey)
                ORDER BY b
                """, w.params) { row in
                let agg = CostSQL.readAggregate(row, from: 3)
                return Raw(bucket: row.int(0), key: row.text(1), label: row.text(2), tokens: agg.tokens,
                           requests: agg.requests, cost: agg.cost)
            }
        }
        var startCache: [Int64: Date] = [:]
        var merged: [String: SeriesPoint] = [:]
        for r in rows {
            let start: Date
            if let cached = startCache[r.bucket] { start = cached }
            else {
                let date = Date(timeIntervalSince1970: Double(r.bucket * Self.quantumMs) / 1000)
                start = calendar.dateInterval(of: granularity.component, for: date)?.start ?? date
                startCache[r.bucket] = start
            }
            let id = "\(start.timeIntervalSince1970)|\(r.key)"
            if var p = merged[id] {
                p.tokens += r.tokens
                p.requests += r.requests
                p.cost = p.cost + r.cost
                merged[id] = p
            } else {
                merged[id] = SeriesPoint(start: start, key: r.key, label: r.label, tokens: r.tokens, requests: r.requests, cost: r.cost)
            }
        }
        var points = Array(merged.values)
        if dimension == .none, granularity != .hour || true {
            points = fillGaps(points, filter: filter, granularity: granularity, calendar: calendar)
        }
        return points.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
    }

    /// Inserts empty points so that charts show quiet periods as zero rather than skipping them.
    private func fillGaps(_ points: [SeriesPoint], filter: UsageFilter, granularity: Granularity, calendar: Calendar) -> [SeriesPoint] {
        guard let first = points.map(\.start).min(), let last = points.map(\.start).max() else { return points }
        let lower = filter.from.map { calendar.dateInterval(of: granularity.component, for: $0)?.start ?? $0 } ?? first
        let upperBound = filter.to ?? Date()
        let upper = max(last, calendar.dateInterval(of: granularity.component, for: upperBound.addingTimeInterval(-1))?.start ?? last)
        var existing = Set(points.map(\.start))
        var out = points
        var cursor = min(lower, first)
        var guardCount = 0
        while cursor <= upper, guardCount < 5000 {
            if !existing.contains(cursor) {
                out.append(SeriesPoint(start: cursor, key: "", label: "", tokens: .zero, requests: 0, cost: .zero))
                existing.insert(cursor)
            }
            guard let next = calendar.date(byAdding: granularity.component, value: 1, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        return out
    }

    /// The number of distinct sessions that made requests in each bucket.
    public func sessionsOverTime(_ filter: UsageFilter, granularity: Granularity,
                                 calendar: Calendar = .current) throws -> [(start: Date, sessions: Int)] {
        let w = filter.whereClause()
        let pairs: [(Int64, Int64)] = try db.read { c in
            try c.query("""
                SELECT DISTINCT r.requested_at / \(Self.quantumMs), r.session_id
                FROM model_request r JOIN session s ON s.id = r.session_id LEFT JOIN project pj ON pj.id = s.project_id
                \(w.sql)
                """, w.params) { ($0.int(0), $0.int(1)) }
        }
        var perBucket: [Date: Set<Int64>] = [:]
        for (b, sid) in pairs {
            let date = Date(timeIntervalSince1970: Double(b * Self.quantumMs) / 1000)
            let start = calendar.dateInterval(of: granularity.component, for: date)?.start ?? date
            perBucket[start, default: []].insert(sid)
        }
        return perBucket.map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }
    }

    // MARK: Breakdowns

    public func models(_ filter: UsageFilter = UsageFilter()) throws -> [ModelUsageRow] {
        let w = filter.whereClause()
        var rows: [ModelUsageRow] = try db.read { c in
            try c.query("""
                SELECT m.canonical, m.display_name, m.family, \(CostSQL.aggregateColumns)
                \(Self.from) \(w.sql)
                GROUP BY m.canonical
                """, w.params) { row in
                let agg = CostSQL.readAggregate(row, from: 3)
                return ModelUsageRow(canonical: row.text(0), displayName: row.text(1), family: row.text(2),
                                     tokens: agg.tokens, requests: agg.requests, cost: agg.cost, tokenShare: 0)
            }
        }
        let total = rows.reduce(Int64(0)) { $0 + $1.tokens.totalProcessed }
        for i in rows.indices where total > 0 { rows[i].tokenShare = Double(rows[i].tokens.totalProcessed) / Double(total) }
        return rows.sorted { $0.tokens.totalProcessed > $1.tokens.totalProcessed }
    }

    public func projects(_ filter: UsageFilter = UsageFilter()) throws -> [ProjectUsageRow] {
        let w = filter.whereClause()
        var rows: [ProjectUsageRow] = try db.read { c in
            try c.query("""
                SELECT COALESCE(pj.id, 0), COALESCE(pj.name, 'No project'), pj.path, \(CostSQL.aggregateColumns),
                       count(DISTINCT r.session_id), max(r.requested_at)
                \(Self.from) \(w.sql)
                GROUP BY COALESCE(pj.id, 0)
                """, w.params) { row in
                let agg = CostSQL.readAggregate(row, from: 3)
                return ProjectUsageRow(id: row.int(0), name: row.text(1), path: row.textOrNil(2), tokens: agg.tokens,
                                       requests: agg.requests, sessions: Int(row.int(12)), cost: agg.cost,
                                       lastActivity: row.intOrNil(13).map { Clock.date(ms: $0) }, tokenShare: 0)
            }
        }
        let total = rows.reduce(Int64(0)) { $0 + $1.tokens.totalProcessed }
        for i in rows.indices where total > 0 { rows[i].tokenShare = Double(rows[i].tokens.totalProcessed) / Double(total) }
        return rows.sorted { $0.tokens.totalProcessed > $1.tokens.totalProcessed }
    }

    // MARK: Sessions

    public func sessionRows(_ filter: UsageFilter = UsageFilter(), now: Date = Date(), live: [String: LiveProcess] = [:],
                            policy: StatusPolicy = StatusPolicy()) throws -> [SessionRow] {
        let req = filter.requestConditions()
        let ses = filter.sessionConditions()
        let joinCond = (["r.session_id = s.id"] + req.sql).joined(separator: " AND ")
        let whereSQL = ses.sql.isEmpty ? "" : "WHERE " + ses.sql.joined(separator: " AND ")
        let having = filter.restrictsRequests ? "HAVING count(r.id) > 0" : ""

        let rows: [SessionRow] = try db.read { c in
            try c.query("""
                SELECT s.id, s.external_id, s.source_id, pj.id, COALESCE(pj.name, 'No project'), pj.path,
                       s.application, s.client_version, s.cwd, s.started_at, s.last_activity_at,
                       s.observed_ended_at, s.reported_cost_micros,
                       \(CostSQL.aggregateColumns),
                       COALESCE(sum(CASE WHEN r.agent_key IS NOT NULL THEN 1 ELSE 0 END), 0),
                       count(DISTINCT r.agent_key)
                FROM session s
                LEFT JOIN project pj ON pj.id = s.project_id
                LEFT JOIN model_request r ON \(joinCond)
                LEFT JOIN model m ON m.id = r.model_id
                \(CostSQL.join)
                \(whereSQL)
                GROUP BY s.id
                \(having)
                """, req.params + ses.params) { row in
                let agg = CostSQL.readAggregate(row, from: 13)
                let started = row.intOrNil(9)
                let last = row.intOrNil(10)
                let ended = row.intOrNil(11)
                let externalID = row.text(1)
                let status = SessionStatusResolver.resolve(now: now, lastActivityMs: last, observedEndedAtMs: ended,
                                                           live: live[externalID], policy: policy)
                return SessionRow(
                    id: row.int(0), externalID: externalID, sourceID: row.text(2), projectID: row.intOrNil(3),
                    projectName: row.text(4), projectPath: row.textOrNil(5), application: row.textOrNil(6),
                    clientVersion: row.textOrNil(7), cwd: row.textOrNil(8),
                    startedAt: started.map { Clock.date(ms: $0) }, lastActivityAt: last.map { Clock.date(ms: $0) },
                    observedEndedAt: ended.map { Clock.date(ms: $0) }, tokens: agg.tokens, requests: agg.requests,
                    agentRequests: Int(row.int(22)), agentCount: Int(row.int(23)), cost: agg.cost,
                    reportedCostUSD: row.intOrNil(12).map { Double($0) / 1_000_000 }, models: [], status: status)
            }
        }
        // Collect the model names of each session, ordered by how much each model was used.
        let modelNames: [Int64: [String]] = try db.read { c in
            let mr = req
            let cond = (["1 = 1"] + mr.sql).joined(separator: " AND ")
            let pairs = try c.query("""
                SELECT r.session_id, m.display_name, sum(r.output_tokens + r.input_tokens + r.cache_creation_tokens) AS w
                FROM model_request r JOIN model m ON m.id = r.model_id
                WHERE \(cond)
                GROUP BY r.session_id, m.id
                ORDER BY r.session_id, w DESC
                """, mr.params) { ($0.int(0), $0.text(1)) }
            var out: [Int64: [String]] = [:]
            for (sid, name) in pairs where !(out[sid]?.contains(name) ?? false) { out[sid, default: []].append(name) }
            return out
        }
        return rows.map { var r = $0; r.models = modelNames[r.id] ?? []; return r }
    }

    public func sessionDetail(id: Int64, now: Date = Date(), live: [String: LiveProcess] = [:],
                              policy: StatusPolicy = StatusPolicy()) throws -> SessionDetail? {
        var filter = UsageFilter()
        filter.sessionIDs = [id]
        guard let row = try sessionRows(filter, now: now, live: live, policy: policy).first else { return nil }
        let byModel = try models(filter)
        let (timeline, bucketed) = try requestTimeline(sessionID: id)
        let agents = try agentUsage(sessionID: id)
        let windows = try windowContexts(for: row)
        return SessionDetail(row: row, byModel: byModel, timeline: timeline, timelineIsBucketed: bucketed,
                             agents: agents, windows: windows)
    }

    private static let maxTimelinePoints = 1500

    private func requestTimeline(sessionID: Int64) throws -> ([RequestPoint], Bool) {
        let count = try db.read { try $0.scalarInt("SELECT count(*) FROM model_request WHERE session_id = ?", [.int(sessionID)]) ?? 0 }
        if count <= Int64(Self.maxTimelinePoints) {
            let points: [RequestPoint] = try db.read { c in
                try c.query("""
                    SELECT r.id, r.requested_at, r.input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_creation_tokens,
                           m.display_name, r.agent_key IS NOT NULL
                    FROM model_request r JOIN model m ON m.id = r.model_id
                    WHERE r.session_id = ? ORDER BY r.requested_at, r.id
                    """, [.int(sessionID)]) { row in
                    RequestPoint(id: Int(row.int(0)), time: Clock.date(ms: row.int(1)),
                                 tokens: TokenCounts(uncachedInput: row.int(2), output: row.int(3), cacheRead: row.int(4), cacheCreation: row.int(5)),
                                 requests: 1, modelName: row.text(6), isChildAgent: row.int(7) != 0)
                }
            }
            return (points, false)
        }
        let span = try db.read { c in
            try c.queryOne("SELECT max(requested_at) - min(requested_at) FROM model_request WHERE session_id = ?", [.int(sessionID)]) { $0.int(0) } ?? 0
        }
        let bucket = max(1000, span / Int64(Self.maxTimelinePoints))
        let points: [RequestPoint] = try db.read { c in
            try c.query("""
                SELECT r.requested_at / ? AS b, min(r.requested_at), sum(r.input_tokens), sum(r.output_tokens),
                       sum(r.cache_read_tokens), sum(r.cache_creation_tokens), count(*), 'Multiple'
                FROM model_request r WHERE r.session_id = ? GROUP BY b ORDER BY b
                """, [.int(bucket), .int(sessionID)]) { row in
                RequestPoint(id: Int(row.int(0)), time: Clock.date(ms: row.int(1)),
                             tokens: TokenCounts(uncachedInput: row.int(2), output: row.int(3), cacheRead: row.int(4), cacheCreation: row.int(5)),
                             requests: Int(row.int(6)), modelName: row.text(7), isChildAgent: false)
            }
        }
        return (points, true)
    }

    private func agentUsage(sessionID: Int64) throws -> [AgentUsage] {
        try db.read { c in
            let rows = try c.query("""
                SELECT r.agent_key, \(CostSQL.aggregateColumns), min(r.requested_at), max(r.requested_at)
                FROM model_request r JOIN model m ON m.id = r.model_id \(CostSQL.join)
                WHERE r.session_id = ?
                GROUP BY r.agent_key
                """, [.int(sessionID)]) { row -> AgentUsage in
                let agg = CostSQL.readAggregate(row, from: 1)
                return AgentUsage(key: row.textOrNil(0), tokens: agg.tokens, requests: agg.requests,
                                  firstSeen: row.intOrNil(10).map { Clock.date(ms: $0) },
                                  lastSeen: row.intOrNil(11).map { Clock.date(ms: $0) }, cost: agg.cost, topModel: "")
            }
            let top = try c.query("""
                SELECT r.agent_key, m.display_name, sum(r.input_tokens + r.output_tokens + r.cache_creation_tokens) AS w
                FROM model_request r JOIN model m ON m.id = r.model_id WHERE r.session_id = ?
                GROUP BY r.agent_key, m.id ORDER BY w DESC
                """, [.int(sessionID)]) { ($0.textOrNil(0), $0.text(1)) }
            var best: [String: String] = [:]
            for (k, name) in top where best[k ?? ""] == nil { best[k ?? ""] = name }
            return rows.map { var a = $0; a.topModel = best[a.key ?? ""] ?? ""; return a }
                .sorted { ($0.key == nil ? 0 : 1, -$0.tokens.totalProcessed) < ($1.key == nil ? 0 : 1, -$1.tokens.totalProcessed) }
        }
    }

    // MARK: Quota window context

    /// The five-hour and seven-day windows, as delimited by authoritative quota snapshots, that
    /// overlap a session, together with how much of the locally observed activity in each window
    /// belongs to the session.
    private func windowContexts(for session: SessionRow) throws -> [QuotaWindowContext] {
        guard let start = session.startedAt, let end = session.lastActivityAt else { return [] }
        let durations: [(String, TimeInterval)] = [("five_hour", 5 * 3600), ("seven_day", 7 * 86400)]
        var out: [QuotaWindowContext] = []
        for (kind, length) in durations {
            let resets: [Int64] = try db.read { c in
                try c.query("""
                    SELECT DISTINCT resets_at FROM quota_snapshot
                    WHERE window_kind = ? AND authority = 'authoritative' AND resets_at IS NOT NULL
                    ORDER BY resets_at
                    """, [.text(kind)]) { $0.int(0) }
            }
            // Snapshots of the same window report resets that differ by a few seconds.
            var windowEnds: [Int64] = []
            for r in resets where windowEnds.last.map({ r - $0 > 10 * 60_000 }) ?? true { windowEnds.append(r) }
            for endMs in windowEnds {
                let wEnd = Clock.date(ms: endMs)
                let wStart = wEnd.addingTimeInterval(-length)
                guard wEnd > start, wStart < end else { continue }
                let peak = try db.read { c in
                    try c.queryOne("""
                        SELECT max(utilization_pct) FROM quota_snapshot
                        WHERE window_kind = ? AND authority = 'authoritative' AND resets_at BETWEEN ? AND ?
                        """, [.text(kind), .int(endMs - 10 * 60_000), .int(endMs + 10 * 60_000)]) { $0.doubleOrNil(0) } ?? nil
                }
                var windowFilter = UsageFilter(from: wStart, to: wEnd)
                let local = try totals(windowFilter)
                windowFilter.sessionIDs = [session.id]
                let mine = try totals(windowFilter)
                out.append(QuotaWindowContext(kind: kind, windowStart: wStart, windowEnd: wEnd,
                                              reportedPeakUtilization: peak, sessionTokens: mine.tokens,
                                              localWindowTokens: local.tokens, sessionCost: mine.cost,
                                              localWindowCost: local.cost))
            }
        }
        return out.sorted { $0.windowEnd > $1.windowEnd }.prefix(6).map { $0 }
    }

    // MARK: Filter pickers

    public struct FilterOptions: Sendable, Equatable {
        public var projects: [(id: Int64, name: String)] = []
        public var models: [(canonical: String, displayName: String)] = []
        public var sources: [String] = []
        public var applications: [String] = []
        public init() {}

        public static func == (a: FilterOptions, b: FilterOptions) -> Bool {
            a.projects.map(\.id) == b.projects.map(\.id) && a.models.map(\.canonical) == b.models.map(\.canonical)
                && a.sources == b.sources && a.applications == b.applications
        }
    }

    public func filterOptions() throws -> FilterOptions {
        try db.read { c in
            var o = FilterOptions()
            o.projects = try c.query("SELECT id, name FROM project ORDER BY name COLLATE NOCASE") { ($0.int(0), $0.text(1)) }
            o.models = try c.query("SELECT canonical, min(display_name) FROM model GROUP BY canonical ORDER BY canonical") { ($0.text(0), $0.text(1)) }
            o.sources = try c.query("SELECT id FROM usage_source ORDER BY id") { $0.text(0) }
            o.applications = try c.query("SELECT DISTINCT application FROM session WHERE application IS NOT NULL ORDER BY application") { $0.text(0) }
            return o
        }
    }

    /// Returns the times of the earliest and latest stored request, or nil when no request is stored.
    public func earliestAndLatestRequest() throws -> (Date, Date)? {
        try db.read { c in
            try c.queryOne("SELECT min(requested_at), max(requested_at) FROM model_request") { row in
                guard let a = row.intOrNil(0), let b = row.intOrNil(1) else { return nil }
                return (Clock.date(ms: a), Clock.date(ms: b))
            } ?? nil
        }
    }
}

private extension Optional where Wrapped == Int64 {
    var asInt: Int { Int(self ?? 0) }
}
