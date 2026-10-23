import Foundation

/// Correlates the work observed in local session files with the quota the provider reported, cycle by cycle.
///
/// The engine is provider-agnostic. It works on providers, accounts, quota windows, cycles, readings and requests, and it
/// reads only what the database already holds: the stored quota snapshots and the stored requests. It never rescans a
/// transcript, never touches the network, and never writes. Everything it returns can be recomputed from the same rows.
///
/// Two quantities are always kept apart. The provider's utilization describes the whole account, including surfaces this
/// application cannot see. Local tokens describe only the activity on this Mac. The engine reports both for each cycle and
/// does not attribute the account's quota change to local tokens unless a ratio's own evidence allows that.
public enum SubscriptionUsageAnalyticsEngine {
    // MARK: Subjects

    /// Every quota window that has at least one authoritative reading, one subject per window.
    public static func subjects(_ db: UsageDatabase) throws -> [IntelligenceSubject] {
        try db.read { c in
            try c.query("""
                SELECT p.provider_id, p.account_id, COALESCE(a.label, 'Unassigned'), a.hash, p.pool_key, w.window_key, w.duration_minutes,
                       (SELECT max(q.last_confirmed_at) FROM quota_snapshot q WHERE q.window_id = w.id AND q.authority = 'authoritative')
                FROM quota_window w
                JOIN quota_pool p ON p.id = w.pool_id
                JOIN account a ON a.id = p.account_id
                WHERE EXISTS (SELECT 1 FROM quota_snapshot q WHERE q.window_id = w.id AND q.authority = 'authoritative')
                ORDER BY p.provider_id, p.account_id, COALESCE(w.duration_minutes, 0) DESC, w.window_key
                """) { r in
                IntelligenceSubject(provider: ProviderID(rawValue: r.text(0)), accountID: r.int(1), accountLabel: r.text(2),
                                    accountIsIdentified: !r.text(3).isEmpty, poolKey: r.text(4), windowKey: r.text(5),
                                    windowMinutes: r.intOrNil(6).map { Int($0) },
                                    scopeLabel: WindowNaming.scopedLabel(fallbackKey: r.text(5)),
                                    lastReadingAt: r.intOrNil(7).map(Clock.date(ms:)))
            }
        }
    }

    // MARK: Analysis

    public static func analyze(_ db: UsageDatabase, subject: IntelligenceSubject, now: Date = Date(),
                               options: AnalysisOptions = AnalysisOptions()) throws -> SubscriptionUsageReport {
        let history = try loadHistory(db, subject: subject)
        let scope = try localScope(db, subject: subject)
        let associations = subject.accountIsIdentified ? try AccountAssociationStore.all(db, provider: subject.provider)
            : []
        // Calculated cycles reach back no further than the first local session of the accounts in scope, because earlier
        // cycles could not contain any local work.
        let earliestRequest = try db.read { c in
            try c.scalarInt("""
                SELECT min(started_at) FROM session WHERE account_id IN (\(scope.accountIDs.map { _ in "?" }.joined(separator: ",")))
                """, scope.accountIDs.map { .int($0) }).map(Clock.date(ms:))
        }
        let timeline = QuotaCycleCalendar.build(observed: history.cycles, windowMinutes: subject.windowMinutes, now: now,
                                                projectBackTo: earliestRequest)

        var spans = timeline.spans.filter { $0.start < now }
        if let from = options.from { spans = spans.filter { $0.end > from } }
        if let to = options.to { spans = spans.filter { $0.start < to } }
        if spans.count > options.maxCycles { spans = Array(spans.suffix(options.maxCycles)) }

        let curves: [QuotaCurve] = spans.map { span in
            QuotaCurve(readings: span.storedCycleIDs.flatMap { history.points[$0] ?? [] })
        }
        let usage = try collectLocalUsage(db, subject: subject, scope: scope, associations: associations, spans: spans,
                                          needsWork: curves.map { $0.points.count >= 2 }, options: options)

        let registry = db.registry
        let timelinePlans = try PlanHistoryStore.timeline(db, provider: subject.provider, accountID: subject.accountID)
        let planNames = Dictionary(registry.plans(of: subject.provider).map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        let planBoundaries = timelinePlans.isUnambiguous
            ? timelinePlans.assignments.flatMap { [$0.effectiveFrom] + ($0.effectiveTo.map { [$0] } ?? []) } : []
        let otherAccounts = try otherIdentifiedActivity(db, subject: subject)
        let period = subject.windowMinutes.map { TimeInterval($0) * 60 }

        var reports: [SubscriptionCycleReport] = []
        for (index, span) in spans.enumerated() {
            let curve = curves[index]
            let timing: CycleTiming = span.contains(now) ? .current : (span.end <= now ? .past : .future)
            let plan = cyclePlan(timelinePlans, span: span, names: planNames)
            let otherActive = otherAccounts.contains { $0.start < span.end && $0.end > span.start }
            let quotaIdentityAmbiguous = !subject.accountIsIdentified && otherActive && !curve.isEmpty

            let attributed = usage.attributed[index]
            let unattributed = usage.unattributed[index]
            let attributedTokens = attributed.tokens.totalProcessed
            var attribution: LocalAttribution
            if scope.mode == .unmapped {
                attribution = .notAttributed
            } else if quotaIdentityAmbiguous {
                attribution = .ambiguous
            } else if attributed.requests == 0 && unattributed.requests == 0 {
                attribution = .noLocalActivity
            } else if unattributed.requests == 0 {
                attribution = subject.accountIsIdentified ? .account : .unassignedAccount
            } else if subject.accountIsIdentified && otherActive {
                attribution = .ambiguous
            } else {
                attribution = attributed.requests > 0 ? .partlyAttributed : .unattributed
            }
            let totalTokens = attributedTokens + unattributed.processedTokens
            let share: Double? = totalTokens > 0 ? Double(attributedTokens) / Double(totalTokens) : nil

            let local = attributed.summary(options: options, days: usage.days[index].values.filter { $0.requests > 0 }.count)
            let quota = quotaSummary(curve: curve, span: span, now: now)

            var efficiency: CycleEfficiency
            if attribution == .ambiguous || attribution == .notAttributed {
                efficiency = .unavailable([.localActivityNotAttributed])
            } else if span.overlapsAnotherWindow {
                efficiency = .unavailable([.cycleOverlapsAnotherWindow])
            } else {
                var caveats: [EfficiencyCaveat] = []
                if !subject.accountIsIdentified { caveats.append(.neitherSideNamesAnAccount) }
                if usage.associatedRequests[index] > 0 { caveats.append(.activityAssociatedByUser) }
                if plan?.recorded != true { caveats.append(.planNotRecorded) }
                if plan?.changedDuringCycle == true { caveats.append(.planChangedDuringCycle) }
                if subject.scopeLabel != nil { caveats.append(.scopedWindow) }
                // The two readings that bound the measurement, and what happened between them, decide whether the work in that
                // stretch is the account's: a plan that changed, or work that names no account, makes the ratio about something else.
                var blocker: EfficiencyUnavailableReason?
                if curve.points.count >= 2, let from = curve.first?.lastConfirmedAt, let to = curve.last?.firstObservedAt, to > from {
                    if planBoundaries.contains(where: { $0 > from && $0 < to }) {
                        blocker = .planChangedWithinInterval
                    } else {
                        let attributedWork = usage.work[index].total(from: from, to: to).processedTokens
                        let unattributedWork = usage.unattributedWork[index].total(from: from, to: to).processedTokens
                        let all = attributedWork + unattributedWork
                        if all > 0, Double(unattributedWork) / Double(all) > options.efficiency.maximumUnattributedShare {
                            blocker = .localActivityNotAttributed
                        }
                    }
                }
                if let blocker {
                    efficiency = .unavailable([blocker], caveats: caveats)
                } else {
                    efficiency = ConsumptionEfficiency.evaluate(curve: curve, work: usage.work[index], policy: options.efficiency, caveats: caveats)
                }
            }

            let days = dayBreakdown(span: span, curve: curve, buckets: usage.days[index], boundaries: usage.boundaries[index],
                                    options: options, cycleProcessed: local.processedTokens)
            reports.append(SubscriptionCycleReport(
                span: span, timing: timing, plan: plan, attribution: attribution, attributedShare: share,
                unattributed: UnattributedUsage(processedTokens: unattributed.processedTokens, requests: unattributed.requests),
                quotaIdentityAmbiguous: quotaIdentityAmbiguous, local: local, quota: quota, days: days, efficiency: efficiency,
                expectedReset: expectedReset(previous: index > 0 ? spans[index - 1] : nil, period: period)))
        }

        var notes: [ReportNote] = [.quotaIsAccountWide]
        if history.points.isEmpty { notes.append(.noQuotaHistory) }
        if timeline.schedule.state != .established { notes.append(.scheduleNotEstablished) }
        if reports.contains(where: { $0.span.origin == .projected }) { notes.append(.projectedCyclesPresent) }
        if subject.accountIsIdentified, scope.hasUnassignedHistory { notes.append(.unassignedHistoryExists) }

        return SubscriptionUsageReport(subject: subject, generatedAt: now, schedule: timeline.schedule,
                                       resetEvents: timeline.events, cycles: reports, notes: notes,
                                       dayGrouping: options.dayGrouping)
    }

    // MARK: Quota history

    private struct History {
        var cycles: [ObservedQuotaCycle]
        var points: [Int64: [QuotaReadingPoint]]
    }

    private static func loadHistory(_ db: UsageDatabase, subject: IntelligenceSubject) throws -> History {
        try db.read { c in
            guard let windowID = try c.scalarInt("""
                SELECT w.id FROM quota_window w JOIN quota_pool p ON p.id = w.pool_id
                WHERE p.account_id = ? AND p.pool_key = ? AND w.window_key = ?
                """, [.int(subject.accountID), .text(subject.poolKey), .text(subject.windowKey)]) else {
                return History(cycles: [], points: [:])
            }
            let cycles: [ObservedQuotaCycle] = try c.query("""
                SELECT id, resets_at, first_observed_at, last_observed_at FROM quota_cycle
                WHERE window_id = ? AND resets_at IS NOT NULL ORDER BY resets_at
                """, [.int(windowID)]) { r in
                ObservedQuotaCycle(id: r.int(0), resetsAt: r.intOrNil(1).map(Clock.date(ms:)),
                                   firstObservedAt: Clock.date(ms: r.int(2)), lastObservedAt: Clock.date(ms: r.int(3)))
            }
            var points: [Int64: [QuotaReadingPoint]] = [:]
            let rows: [(Int64, QuotaReadingPoint)] = try c.query("""
                SELECT cycle_id, utilization_pct, observed_at, last_confirmed_at, telemetry_source_id, confirmations, max_confirmation_gap_ms
                FROM quota_snapshot WHERE window_id = ? AND authority = 'authoritative'
                ORDER BY cycle_id, observed_at
                """, [.int(windowID)]) { r in
                (r.int(0), QuotaReadingPoint(percent: r.double(1), firstObservedAt: Clock.date(ms: r.int(2)),
                                             lastConfirmedAt: Clock.date(ms: r.int(3)), source: r.text(4),
                                             confirmations: Int(r.int(5)), longestPause: Double(r.int(6)) / 1000))
            }
            for (cycleID, point) in rows { points[cycleID, default: []].append(point) }
            let enriched = cycles.map { cycle -> ObservedQuotaCycle in
                var copy = cycle
                copy.firstPercent = points[cycle.id]?.first?.percent
                copy.lastPercent = points[cycle.id]?.last?.percent
                return copy
            }
            return History(cycles: enriched, points: points)
        }
    }

    /// The intervals in which other identified accounts of the same provider reported quota. Local sessions that name no account
    /// cannot be tied to one account in those intervals.
    private static func otherIdentifiedActivity(_ db: UsageDatabase, subject: IntelligenceSubject) throws -> [DateInterval] {
        try db.read { c in
            try c.query("""
                SELECT min(cy.first_observed_at), max(cy.last_observed_at)
                FROM quota_cycle cy
                JOIN quota_window w ON w.id = cy.window_id
                JOIN quota_pool p ON p.id = w.pool_id
                JOIN account a ON a.id = p.account_id
                WHERE p.provider_id = ? AND a.hash <> '' AND p.account_id <> ?
                GROUP BY p.account_id, w.window_key, cy.id
                """, [.text(subject.provider.rawValue), .int(subject.accountID)]) { r in
                DateInterval(start: Clock.date(ms: r.int(0)), end: Clock.date(ms: r.int(1)))
            }
        }
    }

    // MARK: Plans

    private static func cyclePlan(_ timeline: PlanTimeline, span: QuotaCycleSpan, names: [String: String]) -> CyclePlan? {
        guard timeline.isUnambiguous else { return nil }
        let overlapping = timeline.assignments.filter {
            $0.effectiveFrom < span.end && ($0.effectiveTo ?? .distantFuture) > span.start
        }
        guard !overlapping.isEmpty else { return nil }
        let keys = Set(overlapping.compactMap(\.planKey))
        let hasUnknown = overlapping.contains { $0.planKey == nil }
        let key = keys.count == 1 ? keys.first : nil
        return CyclePlan(key: key, name: key.flatMap { names[$0] ?? $0 }, changedDuringCycle: keys.count > 1 || (hasUnknown && !keys.isEmpty))
    }

    // MARK: Quota summary

    private static func quotaSummary(curve: QuotaCurve, span: QuotaCycleSpan, now: Date) -> CycleQuotaSummary? {
        guard let first = curve.first, let last = curve.last else { return nil }
        let coverage = CycleCoverage.compute(curve: curve, span: span, now: now)
        let tolerance = CycleCoverage.tolerance(forCycleLength: max(span.length, 1))
        let startObserved = (coverage.firstObservationDelay ?? .infinity) <= tolerance
        let reached = last.percent >= curve.ceiling
        let ended = span.end <= now
        let endObserved = reached || (ended && (coverage.lastObservationLead ?? .infinity) <= tolerance)
        let completeness: CycleCompleteness
        if coverage.hasReliableFullCycleResult {
            completeness = .complete
        } else if curve.points.count >= 2 {
            completeness = .partial
        } else {
            completeness = .insufficient
        }
        return CycleQuotaSummary(
            curve: curve, readingCount: curve.points.count, firstPercent: first.percent, lastPercent: last.percent,
            maximumPercent: curve.maximum, firstObservedAt: first.firstObservedAt, lastConfirmedAt: last.lastConfirmedAt,
            observedRisePoints: last.percent - first.percent, startObserved: startObserved, endObserved: endObserved,
            reachedLimit: reached, finalPercent: endObserved ? (reached ? curve.ceiling : last.percent) : nil,
            coverage: coverage, completeness: completeness,
            sources: Array(Set(curve.points.compactMap(\.source))).sorted(), issues: curve.issues)
    }

    private static func expectedReset(previous: QuotaCycleSpan?, period: TimeInterval?) -> Date? {
        guard let previous, let period, previous.origin == .observed, let reported = previous.reportedReset else { return nil }
        return reported.addingTimeInterval(period)
    }

    // MARK: Days

    private static func boundaries(for span: QuotaCycleSpan, grouping: DayGrouping) -> [Date] {
        guard span.length >= 2 * 86_400 else { return [] }
        var edges = [span.start]
        switch grouping {
        case .subscriptionDay:
            var t = span.start.addingTimeInterval(86_400)
            while t < span.end {
                edges.append(t)
                t = t.addingTimeInterval(86_400)
            }
        case .calendarDay(let zone):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            var next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: span.start))!
            while next < span.end {
                edges.append(next)
                next = calendar.date(byAdding: .day, value: 1, to: next)!
            }
        }
        edges.append(span.end)
        return edges.count > 70 ? [] : edges
    }

    private static func dayBreakdown(span: QuotaCycleSpan, curve: QuotaCurve, buckets: [Int: UsageAccumulator],
                                     boundaries: [Date], options: AnalysisOptions, cycleProcessed: Int64) -> [DayUsage] {
        guard boundaries.count >= 2 else { return [] }
        return (0..<(boundaries.count - 1)).map { index in
            let accumulator = buckets[index] ?? UsageAccumulator()
            let local = accumulator.summary(options: options, days: accumulator.requests > 0 ? 1 : 0)
            let share = cycleProcessed > 0 ? Double(local.processedTokens) / Double(cycleProcessed) : 0
            return DayUsage(index: index, start: boundaries[index], end: boundaries[index + 1], local: local,
                            shareOfCycleProcessed: share,
                            quotaChange: curve.change(from: boundaries[index], to: boundaries[index + 1]))
        }
    }

    // MARK: Local usage

    private struct LocalScope {
        enum Mode { case active, unmapped }
        var mode: Mode
        var accountIDs: [Int64]
        var unassignedAccountID: Int64?
        var modelFilter: String?
        var hasUnassignedHistory: Bool
    }

    private static func localScope(_ db: UsageDatabase, subject: IntelligenceSubject) throws -> LocalScope {
        let unassigned = try db.read { c in
            try c.scalarInt("SELECT id FROM account WHERE provider_id = ? AND hash = ''", [.text(subject.provider.rawValue)])
        }
        // An identified account is compared with its own sessions and with the sessions that name no account. The unassigned account is
        // compared with every session of the provider, because its readings name no account, and the sessions that do name one are
        // exactly the work that may or may not be in them.
        var ids = [subject.accountID]
        if subject.accountIsIdentified {
            if let unassigned { ids.append(unassigned) }
        } else {
            ids = try db.read { c in
                try c.query("SELECT id FROM account WHERE provider_id = ?", [.text(subject.provider.rawValue)]) { $0.int(0) }
            }
        }
        var filter: String?
        var mode = LocalScope.Mode.active
        if let label = subject.scopeLabel {
            let pattern = "%" + label.lowercased().replacingOccurrences(of: "%", with: "") + "%"
            let matches = try db.read { c in
                try c.scalarInt("""
                    SELECT count(*) FROM model WHERE provider_id = ? AND (lower(display_name) LIKE ? OR lower(canonical) LIKE ?)
                    """, [.text(subject.provider.rawValue), .text(pattern), .text(pattern)]) ?? 0
            }
            if matches == 0 { mode = .unmapped } else { filter = pattern }
        }
        var hasUnassignedHistory = false
        if subject.accountIsIdentified, let unassigned {
            hasUnassignedHistory = try db.read { c in
                try c.scalarInt("SELECT count(*) FROM quota_pool WHERE account_id = ?", [.int(unassigned)]) ?? 0
            } > 0
        }
        return LocalScope(mode: mode, accountIDs: ids, unassignedAccountID: subject.accountIsIdentified ? unassigned : nil,
                          modelFilter: filter, hasUnassignedHistory: hasUnassignedHistory)
    }

    private struct UnattributedTotals {
        var processedTokens: Int64 = 0
        var requests = 0
    }

    private struct CollectedUsage {
        /// Activity tied to the analyzed account: its own sessions, and unassigned sessions that the user associated with it.
        var attributed: [UsageAccumulator]
        /// Activity that names no account and that no association covers.
        var unattributed: [UnattributedTotals]
        var associatedRequests: [Int]
        var days: [[Int: UsageAccumulator]]
        var work: [WorkTimeline]
        var unattributedWork: [WorkTimeline]
        var boundaries: [[Date]]
    }

    private static func collectLocalUsage(_ db: UsageDatabase, subject: IntelligenceSubject, scope: LocalScope,
                                          associations: [AccountAssociation], spans: [QuotaCycleSpan], needsWork: [Bool],
                                          options: AnalysisOptions) throws -> CollectedUsage {
        var collected = CollectedUsage(
            attributed: Array(repeating: UsageAccumulator(), count: spans.count),
            unattributed: Array(repeating: UnattributedTotals(), count: spans.count),
            associatedRequests: Array(repeating: 0, count: spans.count),
            days: Array(repeating: [:], count: spans.count),
            work: Array(repeating: WorkTimeline(), count: spans.count),
            unattributedWork: Array(repeating: WorkTimeline(), count: spans.count),
            boundaries: spans.map { boundaries(for: $0, grouping: options.dayGrouping) })
        guard scope.mode == .active, let first = spans.first, let last = spans.last else { return collected }

        let marks = scope.accountIDs.map { _ in "?" }.joined(separator: ",")
        var sql = """
            SELECT r.requested_at, r.session_id, s.kind, s.account_id, m.canonical, m.display_name,
                   COALESCE(s.project_id, 0), COALESCE(pj.name, ''),
                   r.uncached_input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_creation_tokens,
                   r.cache_creation_5m_tokens, r.cache_creation_1h_tokens, r.reasoning_output_tokens,
                   \(CostSQL.picoUSD), \(CostSQL.unpricedTokens), r.completeness
            FROM model_request r
            JOIN session s ON s.id = r.session_id
            JOIN model m ON m.id = r.model_id
            LEFT JOIN project pj ON pj.id = s.project_id
            \(CostSQL.join)
            WHERE r.requested_at >= ? AND r.requested_at < ? AND m.provider_id = ? AND s.account_id IN (\(marks))
            """
        var params: [SQLValue] = [.int(Clock.ms(first.start)), .int(Clock.ms(last.end)), .text(subject.provider.rawValue)]
        params.append(contentsOf: scope.accountIDs.map { .int($0) })
        if let pattern = scope.modelFilter {
            sql += " AND (lower(m.display_name) LIKE ? OR lower(m.canonical) LIKE ?)"
            params.append(contentsOf: [.text(pattern), .text(pattern)])
        }
        sql += " ORDER BY r.requested_at, r.id"

        let starts = spans.map(\.start)
        func cycleIndex(_ date: Date) -> Int? {
            var low = 0, high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] <= date { low = mid + 1 } else { high = mid }
            }
            guard low > 0, spans[low - 1].contains(date) else { return nil }
            return low - 1
        }

        try db.read { c in
            let stmt = try c.prepare(sql)
            try stmt.bind(params)
            defer { stmt.reset() }
            while try stmt.step() {
                let row = SQLiteRow(stmt: stmt)
                let at = Clock.date(ms: row.int(0))
                guard let index = cycleIndex(at) else { continue }
                let request = UsageRequest(row)

                // A session of the account itself is attributed. One that names no account is attributed only when the user
                // associated that period with this account, and it is left out entirely when the user associated it with another.
                var isAttributed = true
                var associated = false
                if request.accountID != subject.accountID {
                    if let association = associations.first(where: { $0.contains(at) }) {
                        guard association.accountID == subject.accountID else { continue }
                        associated = true
                    } else {
                        isAttributed = false
                    }
                }
                if isAttributed {
                    collected.attributed[index].add(request, activityGap: options.activityGap)
                    if associated { collected.associatedRequests[index] += 1 }
                    let edges = collected.boundaries[index]
                    if edges.count >= 2 {
                        var low = 0, high = edges.count
                        while low < high {
                            let mid = (low + high) / 2
                            if edges[mid] <= at { low = mid + 1 } else { high = mid }
                        }
                        let day = min(max(low - 1, 0), edges.count - 2)
                        collected.days[index][day, default: UsageAccumulator()].add(request, activityGap: options.activityGap)
                    }
                } else {
                    collected.unattributed[index].processedTokens += request.tokens.totalProcessed
                    collected.unattributed[index].requests += 1
                }
                if needsWork[index] {
                    if isAttributed {
                        collected.work[index].append(at: request.requestedAtMs, processed: request.tokens.totalProcessed,
                                                     fresh: request.tokens.freshTokens, costPicoUSD: request.picoUSD,
                                                     unpricedTokens: request.unpricedTokens, cacheRead: request.tokens.cacheRead,
                                                     model: request.model)
                    } else {
                        collected.unattributedWork[index].append(at: request.requestedAtMs, processed: request.tokens.totalProcessed,
                                                                 fresh: request.tokens.freshTokens, costPicoUSD: request.picoUSD,
                                                                 unpricedTokens: request.unpricedTokens)
                    }
                }
            }
        }
        return collected
    }
}

// MARK: - Accumulation

/// One request read from the database, with the columns the intelligence calculations need.
struct UsageRequest {
    var requestedAtMs: Int64
    var sessionID: Int64
    var isSubagent: Bool
    var accountID: Int64
    var model: String
    var modelName: String
    var projectID: Int64
    var projectName: String
    var tokens: TokenCounts
    var picoUSD: Int64
    var unpricedTokens: Int64
    var missingUncached: Bool
    var missingCacheRead: Bool
    var missingCacheCreation: Bool
    var missingReasoning: Bool
    var completeness: String

    init(_ row: SQLiteRow) {
        requestedAtMs = row.int(0)
        sessionID = row.int(1)
        isSubagent = row.text(2) == SessionKind.subagent.rawValue
        accountID = row.int(3)
        model = row.text(4)
        modelName = row.text(5)
        projectID = row.int(6)
        projectName = row.text(7)
        let uncached = row.intOrNil(8), cacheRead = row.intOrNil(10), cacheCreation = row.intOrNil(11), reasoning = row.intOrNil(14)
        tokens = TokenCounts(uncachedInput: uncached ?? 0, output: row.int(9), cacheRead: cacheRead ?? 0,
                             cacheCreation: cacheCreation ?? 0, cacheCreation5m: row.intOrNil(12) ?? 0,
                             cacheCreation1h: row.intOrNil(13) ?? 0, reasoningOutput: reasoning ?? 0)
        picoUSD = row.intOrNil(15) ?? 0
        unpricedTokens = row.intOrNil(16) ?? 0
        missingUncached = uncached == nil
        missingCacheRead = cacheRead == nil
        missingCacheCreation = cacheCreation == nil
        missingReasoning = reasoning == nil
        completeness = row.text(17)
    }
}

/// Sums the requests of one period while a query streams, keeping memory proportional to the number of models,
/// projects and sessions instead of the number of requests.
struct UsageAccumulator {
    private(set) var tokens = TokenCounts()
    private(set) var requests = 0
    private var cost = EstimatedCost()
    private var coverage = UsageCoverage()
    private var sessions = Set<Int64>()
    private var subagentSessions = Set<Int64>()
    private var subagentTokens = TokenCounts()
    private var models: [String: (name: String, tokens: TokenCounts, requests: Int, cost: EstimatedCost)] = [:]
    private var projects: [Int64: (name: String, tokens: TokenCounts, requests: Int, cost: EstimatedCost)] = [:]
    private var firstMs: Int64?
    private var lastMs: Int64?
    private var periodStartMs: Int64?
    private var periods: [ActivePeriod] = []
    private var periodCount = 0
    private var activeDuration: TimeInterval = 0

    private static let maxStoredPeriods = 400

    mutating func add(_ request: UsageRequest, activityGap: TimeInterval) {
        requests += 1
        tokens += request.tokens
        let requestCost = EstimatedCost(picoUSD: request.picoUSD, unpricedTokens: request.unpricedTokens)
        cost = cost + requestCost
        coverage.requests += 1
        if request.missingUncached { coverage.missingUncachedInput += 1 }
        if request.missingCacheRead { coverage.missingCacheRead += 1 }
        if request.missingCacheCreation { coverage.missingCacheCreation += 1 }
        if request.missingReasoning { coverage.missingReasoning += 1 }
        if request.completeness == "partial" { coverage.partialRequests += 1 }
        if request.completeness == "reconciledFromTotals" { coverage.reconciledRequests += 1 }
        if request.isSubagent {
            subagentSessions.insert(request.sessionID)
            subagentTokens += request.tokens
        } else {
            sessions.insert(request.sessionID)
        }
        var model = models[request.model] ?? (request.modelName, TokenCounts(), 0, EstimatedCost())
        model.tokens += request.tokens
        model.requests += 1
        model.cost = model.cost + requestCost
        models[request.model] = model
        var project = projects[request.projectID] ?? (request.projectName, TokenCounts(), 0, EstimatedCost())
        project.tokens += request.tokens
        project.requests += 1
        project.cost = project.cost + requestCost
        projects[request.projectID] = project

        if firstMs == nil { firstMs = request.requestedAtMs }
        if let previous = lastMs, Double(request.requestedAtMs - previous) / 1000 > activityGap {
            closePeriod(endMs: previous)
            periodStartMs = request.requestedAtMs
        } else if periodStartMs == nil {
            periodStartMs = request.requestedAtMs
        }
        lastMs = request.requestedAtMs
    }

    private mutating func closePeriod(endMs: Int64) {
        guard let startMs = periodStartMs else { return }
        periodCount += 1
        activeDuration += Double(endMs - startMs) / 1000
        if periods.count < Self.maxStoredPeriods {
            periods.append(ActivePeriod(start: Clock.date(ms: startMs), end: Clock.date(ms: endMs)))
        }
        periodStartMs = nil
    }

    func summary(options: AnalysisOptions, days: Int) -> LocalUsageSummary {
        var closed = self
        if let last = lastMs { closed.closePeriod(endMs: last) }
        var out = LocalUsageSummary()
        out.tokens = tokens
        out.requests = requests
        out.sessions = sessions.count
        out.subagentSessions = subagentSessions.count
        out.subagentTokens = subagentTokens
        out.cost = cost
        var covered = coverage
        covered.requests = requests
        out.coverage = covered
        let total = Double(max(tokens.totalProcessed, 1))
        out.models = models.map { key, value in
            ModelUsage(canonical: key, displayName: value.name, tokens: value.tokens, requests: value.requests, cost: value.cost,
                       share: Double(value.tokens.totalProcessed) / total)
        }
        .sorted { ($1.tokens.totalProcessed, $0.canonical) < ($0.tokens.totalProcessed, $1.canonical) }
        .prefix(options.topModels).map { $0 }
        out.projects = projects.map { key, value in
            ProjectUsage(id: key, name: value.name, tokens: value.tokens, requests: value.requests, cost: value.cost,
                         share: Double(value.tokens.totalProcessed) / total)
        }
        .sorted { ($1.tokens.totalProcessed, $0.id) < ($0.tokens.totalProcessed, $1.id) }
        .prefix(options.topProjects).map { $0 }
        out.activePeriodCount = closed.periodCount
        out.activeDuration = closed.activeDuration
        out.activePeriods = closed.periods
        out.activeDays = days
        out.firstRequestAt = firstMs.map(Clock.date(ms:))
        out.lastRequestAt = lastMs.map(Clock.date(ms:))
        return out
    }
}
