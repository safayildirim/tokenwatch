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
                t.coverage = agg.coverage
                t.sessions = Int(row.int(CostSQL.aggregateWidth))
                return t
            } ?? UsageTotals()
        }
    }

    /// Summaries for the overview. `scope` narrows every figure to a provider, product, account or surface, and
    /// carries no period, since the periods are the point of the overview.
    public func overview(now: Date = Date(), calendar: Calendar = .current, live: [String: LiveProcess] = [:],
                         policy: StatusPolicy = StatusPolicy(), scope: UsageFilter = UsageFilter()) throws -> OverviewSnapshot {
        var o = OverviewSnapshot()
        o.computedAt = now
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? dayStart
        func within(_ from: Date) -> UsageFilter { var f = scope; f.from = from; f.to = nil; return f }
        o.today = try totals(within(dayStart))
        o.thisWeek = try totals(within(weekStart))
        o.thisMonth = try totals(within(monthStart))
        // All-time figures are only counts. Summing every token with prices attached would scan the
        // whole history on each refresh, and no screen needs those sums.
        let w = scope.sessionConditions()
        let counts = try db.read { c in
            let join = "FROM model_request r JOIN session s ON s.id = r.session_id LEFT JOIN project pj ON pj.id = s.project_id"
            let clause = w.sql.isEmpty ? "" : "WHERE " + w.sql.joined(separator: " AND ")
            return (try c.scalarInt("SELECT count(*) \(join) \(clause)", w.params) ?? 0,
                    try c.scalarInt("SELECT count(*) FROM session s LEFT JOIN project pj ON pj.id = s.project_id \(clause)", w.params) ?? 0)
        }
        o.allTime.requests = Int(counts.0)
        o.allTime.sessions = Int(counts.1)
        o.totalSessions = Int(counts.1)
        var recent = scope
        recent.from = Calendar.current.date(byAdding: .day, value: -2, to: now)
        let sessions = try sessionRows(recent, now: now, live: live, policy: policy)
        let active = sessions.filter { $0.status.state == .active }
        o.activeSessions = active.count
        for session in active { o.activeSessionsByProvider[session.provider, default: 0] += 1 }
        return o
    }

    /// The number of sessions currently in the active state. This is cheap enough to run on every
    /// change, because it only looks at sessions that wrote recently plus the live process table.
    public func activeSessionCount(now: Date = Date(), live: [String: LiveProcess] = [:], policy: StatusPolicy = StatusPolicy(),
                                   provider: ProviderID? = nil) throws -> Int {
        let floor = Clock.ms(now.addingTimeInterval(-policy.activeWithin))
        let rows: [(String, Int64?, Int64?, String)] = try db.read { c in
            try c.query("""
                SELECT s.external_id, s.last_activity_at, s.observed_ended_at, p.provider_id
                FROM session s JOIN product p ON p.id = s.product_id WHERE s.last_activity_at >= ?
                """, [.int(floor)]) { ($0.text(0), $0.intOrNil(1), $0.intOrNil(2), $0.text(3)) }
        }
        var active = Set<String>()
        for (id, last, ended, owner) in rows where provider == nil || provider!.rawValue == owner {
            let status = SessionStatusResolver.resolve(now: now, lastActivityMs: last, observedEndedAtMs: ended, live: live[id], policy: policy)
            if status.state == .active { active.insert(id) }
        }
        // A live process is only counted for a provider once its session is known to the database.
        if provider == nil {
            for (id, process) in live where process.activity == .busy { active.insert(id) }
        } else {
            let known: Set<String> = try db.read { c in
                Set(try c.query("SELECT s.external_id FROM session s JOIN product p ON p.id = s.product_id WHERE p.provider_id = ?",
                                [.text(provider!.rawValue)]) { $0.text(0) })
            }
            for (id, process) in live where process.activity == .busy && known.contains(id) { active.insert(id) }
        }
        return active.count
    }

    /// The providers that have written a session record since `date`. A provider that is being used is expected to
    /// keep its quota figures fresh, which is what makes a silent feed worth a warning.
    public func activeProviders(since date: Date) throws -> Set<ProviderID> {
        try db.read { c in
            Set(try c.query("""
                SELECT DISTINCT p.provider_id FROM session s JOIN product p ON p.id = s.product_id WHERE s.last_activity_at >= ?
                """, [.int(Clock.ms(date))]) { ProviderID(rawValue: $0.text(0)) })
        }
    }

    /// The number of active sessions of each provider, counted cheaply from recent records and the live process table.
    ///
    /// A live process counts for the provider that owns its session. A process whose session has no record yet
    /// is counted for `liveProvider`, the provider whose process registry it came from.
    public func activeSessionCounts(now: Date = Date(), live: [String: LiveProcess] = [:], liveProvider: ProviderID? = nil,
                                    policy: StatusPolicy = StatusPolicy()) throws -> [ProviderID: Int] {
        let floor = Clock.ms(now.addingTimeInterval(-policy.activeWithin))
        let rows: [(String, Int64?, Int64?, String)] = try db.read { c in
            try c.query("""
                SELECT s.external_id, s.last_activity_at, s.observed_ended_at, p.provider_id
                FROM session s JOIN product p ON p.id = s.product_id
                WHERE s.last_activity_at >= ? OR s.external_id IN (\(live.keys.isEmpty ? "''" : live.keys.map { _ in "?" }.joined(separator: ",")))
                """, [.int(floor)] + live.keys.map { .text($0) }) { ($0.text(0), $0.intOrNil(1), $0.intOrNil(2), $0.text(3)) }
        }
        var counted = Set<String>()
        var out: [ProviderID: Int] = [:]
        for (id, last, ended, owner) in rows {
            let status = SessionStatusResolver.resolve(now: now, lastActivityMs: last, observedEndedAtMs: ended, live: live[id], policy: policy)
            if status.state == .active, counted.insert(id).inserted { out[ProviderID(rawValue: owner), default: 0] += 1 }
        }
        if let liveProvider {
            for (id, process) in live where process.activity == .busy && counted.insert(id).inserted { out[liveProvider, default: 0] += 1 }
        }
        return out
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
        case .provider: dimKey = "m.provider_id"; dimLabel = "m.provider_id"
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
                SELECT m.canonical, m.display_name, m.family, m.provider_id, \(CostSQL.aggregateColumns)
                \(Self.from) \(w.sql)
                GROUP BY m.provider_id, m.canonical
                """, w.params) { row in
                let agg = CostSQL.readAggregate(row, from: 4)
                return ModelUsageRow(provider: ProviderID(rawValue: row.text(3)), canonical: row.text(0),
                                     displayName: row.text(1), family: row.text(2), tokens: agg.tokens,
                                     requests: agg.requests, cost: agg.cost, coverage: agg.coverage, tokenShare: 0)
            }
        }
        let total = rows.reduce(Int64(0)) { $0 + $1.tokens.totalProcessed }
        for i in rows.indices where total > 0 { rows[i].tokenShare = Double(rows[i].tokens.totalProcessed) / Double(total) }
        return rows.sorted { $0.tokens.totalProcessed > $1.tokens.totalProcessed }
    }

    /// Usage per provider, or per product when `byProduct` is set. Providers are never merged into one figure by this
    /// query, because their token counts come from different tokenizers.
    public func providers(_ filter: UsageFilter = UsageFilter(), byProduct: Bool = false) throws -> [ProviderUsageRow] {
        let w = filter.whereClause()
        let group = byProduct ? "s.product_id" : "pd.provider_id"
        return try db.read { c in
            try c.query("""
                SELECT pd.provider_id, \(byProduct ? "s.product_id" : "NULL"), \(CostSQL.aggregateColumns),
                       count(DISTINCT r.session_id), max(r.requested_at)
                FROM model_request r
                JOIN session s ON s.id = r.session_id
                JOIN product pd ON pd.id = s.product_id
                JOIN model m ON m.id = r.model_id
                LEFT JOIN project pj ON pj.id = s.project_id
                \(CostSQL.join) \(w.sql)
                GROUP BY \(group)
                """, w.params) { row in
                let agg = CostSQL.readAggregate(row, from: 2)
                let after = 2 + CostSQL.aggregateWidth
                return ProviderUsageRow(provider: ProviderID(rawValue: row.text(0)), product: row.textOrNil(1).map { ProductID(rawValue: $0) },
                                        tokens: agg.tokens, requests: agg.requests, sessions: Int(row.int(after)), cost: agg.cost,
                                        coverage: agg.coverage, lastActivity: row.intOrNil(after + 1).map { Clock.date(ms: $0) })
            }.sorted { $0.tokens.totalProcessed > $1.tokens.totalProcessed }
        }
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
                let after = 3 + CostSQL.aggregateWidth
                return ProjectUsageRow(id: row.int(0), name: row.text(1), path: row.textOrNil(2), tokens: agg.tokens,
                                       requests: agg.requests, sessions: Int(row.int(after)), cost: agg.cost,
                                       lastActivity: row.intOrNil(after + 1).map { Clock.date(ms: $0) }, tokenShare: 0)
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
                SELECT s.id, s.external_id, s.product_id, pd.provider_id, s.telemetry_source_id, s.account_id,
                       COALESCE(ac.label, 'Unassigned'), s.surface_id, s.kind,
                       pj.id, COALESCE(pj.name, 'No project'), pj.path,
                       s.client_version, s.cwd, s.started_at, s.last_activity_at,
                       s.observed_ended_at, s.reported_cost_micros,
                       \(CostSQL.aggregateColumns),
                       COALESCE(sum(CASE WHEN r.agent_key IS NOT NULL THEN 1 ELSE 0 END), 0),
                       count(DISTINCT r.agent_key)
                FROM session s
                JOIN product pd ON pd.id = s.product_id
                JOIN account ac ON ac.id = s.account_id
                LEFT JOIN project pj ON pj.id = s.project_id
                LEFT JOIN model_request r ON \(joinCond)
                LEFT JOIN model m ON m.id = r.model_id
                \(CostSQL.join)
                \(whereSQL)
                GROUP BY s.id
                \(having)
                """, req.params + ses.params) { row in
                let agg = CostSQL.readAggregate(row, from: 18)
                let after = 18 + CostSQL.aggregateWidth
                let started = row.intOrNil(14)
                let last = row.intOrNil(15)
                let ended = row.intOrNil(16)
                let externalID = row.text(1)
                let status = SessionStatusResolver.resolve(now: now, lastActivityMs: last, observedEndedAtMs: ended,
                                                           live: live[externalID], policy: policy)
                return SessionRow(
                    id: row.int(0), externalID: externalID, productID: ProductID(rawValue: row.text(2)),
                    provider: ProviderID(rawValue: row.text(3)), sourceID: TelemetrySourceID(rawValue: row.text(4)),
                    accountID: row.int(5), accountLabel: row.text(6), surface: row.textOrNil(7).map { SurfaceID(rawValue: $0) },
                    kind: SessionKind(rawValue: row.text(8)) ?? .main, projectID: row.intOrNil(9),
                    projectName: row.text(10), projectPath: row.textOrNil(11),
                    clientVersion: row.textOrNil(12), cwd: row.textOrNil(13),
                    startedAt: started.map { Clock.date(ms: $0) }, lastActivityAt: last.map { Clock.date(ms: $0) },
                    observedEndedAt: ended.map { Clock.date(ms: $0) }, tokens: agg.tokens, requests: agg.requests,
                    agentRequests: Int(row.int(after)), agentCount: Int(row.int(after + 1)), cost: agg.cost,
                    coverage: agg.coverage,
                    reportedCostUSD: row.intOrNil(17).map { Double($0) / 1_000_000 }, models: [], status: status)
            }
        }
        // Collect the model names of each session, ordered by how much each model was used.
        let modelNames: [Int64: [String]] = try db.read { c in
            let mr = req
            let cond = (["1 = 1"] + mr.sql).joined(separator: " AND ")
            let pairs = try c.query("""
                SELECT r.session_id, m.display_name, sum(r.output_tokens + COALESCE(r.uncached_input_tokens, 0) + COALESCE(r.cache_creation_tokens, 0)) AS w
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
                    SELECT r.id, r.requested_at, COALESCE(r.uncached_input_tokens, 0), r.output_tokens,
                           COALESCE(r.cache_read_tokens, 0), COALESCE(r.cache_creation_tokens, 0),
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
                SELECT r.requested_at / ? AS b, min(r.requested_at), sum(COALESCE(r.uncached_input_tokens, 0)), sum(r.output_tokens),
                       sum(COALESCE(r.cache_read_tokens, 0)), sum(COALESCE(r.cache_creation_tokens, 0)), count(*), 'Multiple'
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
                                  firstSeen: row.intOrNil(1 + CostSQL.aggregateWidth).map { Clock.date(ms: $0) },
                                  lastSeen: row.intOrNil(2 + CostSQL.aggregateWidth).map { Clock.date(ms: $0) }, cost: agg.cost, topModel: "")
            }
            let top = try c.query("""
                SELECT r.agent_key, m.display_name, sum(COALESCE(r.uncached_input_tokens, 0) + r.output_tokens + COALESCE(r.cache_creation_tokens, 0)) AS w
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

    /// The quota windows, as delimited by authoritative quota snapshots, that overlap a session, together
    /// with how much of the locally observed activity in each window belongs to the session.
    ///
    /// Only windows of the session's own account are considered, and only pools that its product draws on.
    /// The locally observed activity in a window is that of the same account and of every product in the pool.
    private func windowContexts(for session: SessionRow) throws -> [QuotaWindowContext] {
        guard let start = session.startedAt, let end = session.lastActivityAt else { return [] }
        struct Cycle { var poolKey: String; var windowKey: String; var minutes: Int; var resetsMs: Int64; var peak: Double? }
        let cycles: [Cycle] = try db.read { c in
            try c.query("""
                SELECT p.pool_key, w.window_key, w.duration_minutes, cy.resets_at, max(sn.utilization_pct)
                FROM quota_cycle cy
                JOIN quota_window w ON w.id = cy.window_id
                JOIN quota_pool p ON p.id = w.pool_id
                JOIN pool_membership pm ON pm.provider_id = p.provider_id AND pm.pool_key = p.pool_key AND pm.product_id = ?
                LEFT JOIN quota_snapshot sn ON sn.cycle_id = cy.id AND sn.authority = 'authoritative'
                WHERE p.account_id = ? AND w.duration_minutes IS NOT NULL AND cy.resets_at IS NOT NULL
                GROUP BY cy.id
                """, [.text(session.productID.rawValue), .int(session.accountID)]) { row in
                Cycle(poolKey: row.text(0), windowKey: row.text(1), minutes: Int(row.int(2)), resetsMs: row.int(3), peak: row.doubleOrNil(4))
            }
        }
        var out: [QuotaWindowContext] = []
        for cycle in cycles {
            let wEnd = Clock.date(ms: cycle.resetsMs)
            let wStart = wEnd.addingTimeInterval(-Double(cycle.minutes) * 60)
            guard wEnd > start, wStart < end else { continue }
            var windowFilter = UsageFilter(from: wStart, to: wEnd)
            windowFilter.accounts = [session.accountID]
            windowFilter.products = Set(db.registry.pool(provider: session.provider, key: cycle.poolKey)?.products ?? [session.productID])
            let local = try totals(windowFilter)
            windowFilter.sessionIDs = [session.id]
            let mine = try totals(windowFilter)
            out.append(QuotaWindowContext(poolKey: cycle.poolKey, windowKey: cycle.windowKey, windowMinutes: cycle.minutes,
                                          windowStart: wStart, windowEnd: wEnd, reportedPeakUtilization: cycle.peak,
                                          sessionTokens: mine.tokens, localWindowTokens: local.tokens,
                                          sessionCost: mine.cost, localWindowCost: local.cost))
        }
        return out.sorted { $0.windowEnd > $1.windowEnd }.prefix(6).map { $0 }
    }

    // MARK: Filter pickers

    public struct FilterOptions: Sendable, Equatable {
        public struct AccountOption: Sendable, Equatable, Identifiable {
            public var id: Int64
            public var provider: ProviderID
            public var label: String
        }
        public var projects: [(id: Int64, name: String)] = []
        public var models: [(canonical: String, displayName: String)] = []
        public var providers: [ProviderID] = []
        public var products: [ProductID] = []
        public var accounts: [AccountOption] = []
        public var surfaces: [SurfaceID] = []
        public var sources: [TelemetrySourceID] = []
        public init() {}

        public static func == (a: FilterOptions, b: FilterOptions) -> Bool {
            a.projects.map(\.id) == b.projects.map(\.id) && a.models.map(\.canonical) == b.models.map(\.canonical)
                && a.providers == b.providers && a.products == b.products && a.accounts == b.accounts
                && a.surfaces == b.surfaces && a.sources == b.sources
        }
    }

    /// Lists the values that exist in the stored data, so that a filter never offers a choice with no results.
    public func filterOptions() throws -> FilterOptions {
        try db.read { c in
            var o = FilterOptions()
            o.projects = try c.query("SELECT id, name FROM project ORDER BY name COLLATE NOCASE") { ($0.int(0), $0.text(1)) }
            o.models = try c.query("SELECT canonical, min(display_name) FROM model GROUP BY canonical ORDER BY canonical") { ($0.text(0), $0.text(1)) }
            o.products = try c.query("SELECT DISTINCT product_id FROM session ORDER BY product_id") { ProductID(rawValue: $0.text(0)) }
            o.providers = try c.query("""
                SELECT DISTINCT p.provider_id FROM session s JOIN product p ON p.id = s.product_id ORDER BY p.provider_id
                """) { ProviderID(rawValue: $0.text(0)) }
            o.accounts = try c.query("""
                SELECT DISTINCT a.id, a.provider_id, COALESCE(a.label, 'Unassigned') FROM session s JOIN account a ON a.id = s.account_id
                ORDER BY a.provider_id, a.label
                """) { FilterOptions.AccountOption(id: $0.int(0), provider: ProviderID(rawValue: $0.text(1)), label: $0.text(2)) }
            o.surfaces = try c.query("SELECT DISTINCT surface_id FROM session WHERE surface_id IS NOT NULL ORDER BY surface_id") { SurfaceID(rawValue: $0.text(0)) }
            o.sources = try c.query("SELECT DISTINCT telemetry_source_id FROM session ORDER BY telemetry_source_id") { TelemetrySourceID(rawValue: $0.text(0)) }
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
