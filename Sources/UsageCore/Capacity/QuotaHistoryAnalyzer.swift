import Foundation

/// The stored quota history of one window, reshaped into cycles and usable intervals.
public struct QuotaHistoryAnalysis: Sendable, Equatable {
    public var windowKey: String
    public var windowMinutes: Int?
    public var cycles: [QuotaCycleHistory]
    public var intervals: [CapacityIntervalObservation]
    /// The smallest observed utilization step, capped at one percentage point. Used to reject
    /// intervals whose change is too small to survive provider rounding.
    public var quotaResolution: Double?
    /// Readings that could not become intervals, with the reason.
    public var discarded: [CapacityExclusion: Int]

    public init(windowKey: String, windowMinutes: Int?, cycles: [QuotaCycleHistory],
                intervals: [CapacityIntervalObservation], quotaResolution: Double?,
                discarded: [CapacityExclusion: Int]) {
        self.windowKey = windowKey
        self.windowMinutes = windowMinutes
        self.cycles = cycles
        self.intervals = intervals
        self.quotaResolution = quotaResolution
        self.discarded = discarded
    }

    public var peakUtilization: Double? { cycles.map(\.peakPercent).max() }
    public var completeCycles: Int { cycles.filter(\.isCompleteWindow).count }
}

/// Turns stored snapshots into cycle-level observations.
///
/// The analyzer never invents a reading. It only pairs two authoritative readings of the same
/// cycle and looks up the local requests that happened between the observation of the first value
/// and the observation of the second. Anything that does not satisfy the rules is still returned,
/// with an explicit exclusion reason, so the interface can explain what is missing.
public enum QuotaHistoryAnalyzer {
    /// The per-request columns used to describe local work. Kept in one place so the quota analysis
    /// and a controlled measurement cannot drift apart.
    static let requestSelect = """
        SELECT r.requested_at, m.canonical, m.display_name,
               r.uncached_input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_creation_tokens,
               r.cache_creation_5m_tokens, r.cache_creation_1h_tokens, r.reasoning_output_tokens,
               \(CostSQL.picoUSD), \(CostSQL.unpricedTokens), r.completeness
        FROM model_request r
        JOIN session s ON s.id = r.session_id
        JOIN model m ON m.id = r.model_id
        \(CostSQL.join)
        """

    /// Reads the normalized local work in `[from, to)` for one provider account.
    static func workload(_ db: UsageDatabase, provider: ProviderID, accountID: Int64,
                         from: Date, to: Date) throws -> CapacityWorkload {
        guard to > from else { return CapacityWorkload() }
        var accumulator = WorkAccumulator()
        try db.read { c in
            let stmt = try c.prepare("""
                \(requestSelect)
                WHERE m.provider_id = ? AND s.account_id = ?
                  AND r.requested_at >= ? AND r.requested_at < ?
                ORDER BY r.requested_at, r.id
                """)
            try stmt.bind([.text(provider.rawValue), .int(accountID), .int(Clock.ms(from)), .int(Clock.ms(to))])
            defer { stmt.reset() }
            while try stmt.step() {
                let row = SQLiteRow(stmt: stmt)
                accumulator.add(row: row, requestedAtMs: row.int(0))
            }
        }
        return accumulator.finish()
    }

    public static func analyze(_ db: UsageDatabase, provider: ProviderID, accountID: Int64, poolKey: String,
                               windowKey: String, from: Date, to: Date, timeline: PlanTimeline,
                               policy: CapacityEstimationPolicy = CapacityEstimationPolicy()) throws -> QuotaHistoryAnalysis {
        struct Snapshot {
            var id: Int64
            var cycleID: Int64
            var resetsAt: Date?
            var percent: Double
            var observedAt: Date
            var lastConfirmedAt: Date
        }
        let rows: (minutes: Int?, snapshots: [Snapshot]) = try db.read { c in
            let minutes = try c.queryOne("""
                SELECT w.duration_minutes FROM quota_window w
                JOIN quota_pool p ON p.id = w.pool_id
                WHERE p.account_id = ? AND p.pool_key = ? AND w.window_key = ?
                """, [.int(accountID), .text(poolKey), .text(windowKey)]) { $0.intOrNil(0).map { Int($0) } } ?? nil
            let snapshots = try c.query("""
                SELECT q.id, q.cycle_id, cy.resets_at, q.utilization_pct, q.observed_at, q.last_confirmed_at
                FROM quota_snapshot q
                JOIN quota_cycle cy ON cy.id = q.cycle_id
                JOIN quota_window w ON w.id = q.window_id
                JOIN quota_pool p ON p.id = w.pool_id
                WHERE p.account_id = ? AND p.pool_key = ? AND w.window_key = ?
                  AND q.authority = 'authoritative'
                  AND q.observed_at >= ? AND q.observed_at < ?
                ORDER BY q.cycle_id, q.observed_at, q.last_confirmed_at, q.id
                """, [.int(accountID), .text(poolKey), .text(windowKey), .int(Clock.ms(from)), .int(Clock.ms(to))]) { r in
                Snapshot(id: r.int(0), cycleID: r.int(1), resetsAt: r.intOrNil(2).map(Clock.date(ms:)),
                         percent: r.double(3), observedAt: Clock.date(ms: r.int(4)),
                         lastConfirmedAt: Clock.date(ms: r.int(5)))
            }
            return (minutes, snapshots)
        }
        let windowMinutes = rows.minutes
        guard !rows.snapshots.isEmpty else {
            return QuotaHistoryAnalysis(windowKey: windowKey, windowMinutes: windowMinutes, cycles: [],
                                        intervals: [], quotaResolution: nil, discarded: [:])
        }

        // Group into cycles.
        var byCycle: [Int64: [Snapshot]] = [:]
        var cycleOrder: [Int64] = []
        for snapshot in rows.snapshots {
            if byCycle[snapshot.cycleID] == nil { cycleOrder.append(snapshot.cycleID) }
            byCycle[snapshot.cycleID, default: []].append(snapshot)
        }

        // The smallest positive step between consecutive values is an upper bound on the
        // provider's display resolution. Cap it at one point: a jump of 20 points in a sparse
        // cycle must not make a 15-point jump look precise.
        var steps: [Double] = []
        for id in cycleOrder {
            guard let points = byCycle[id], points.count >= 2 else { continue }
            for (a, b) in zip(points, points.dropFirst()) where b.percent > a.percent {
                steps.append(b.percent - a.percent)
            }
        }
        let resolution = steps.min().map { min(1.0, $0) }

        var cycles: [QuotaCycleHistory] = []
        var intervals: [CapacityIntervalObservation] = []
        var discarded: [CapacityExclusion: Int] = [:]

        func discard(_ reason: CapacityExclusion) { discarded[reason, default: 0] += 1 }
        func maxGap() -> TimeInterval {
            guard let minutes = windowMinutes else { return 24 * 3600 }
            if minutes <= 360 { return 3600 }
            if minutes <= 1440 { return 3 * 3600 }
            return 24 * 3600
        }

        for cycleID in cycleOrder {
            guard let points = byCycle[cycleID], let first = points.first else { continue }
            let peak = points.map(\.percent).max() ?? first.percent
            let historyPoints = points.map {
                QuotaHistoryPoint(id: $0.id, percent: $0.percent, observedAt: $0.observedAt,
                                  lastConfirmedAt: $0.lastConfirmedAt, resetsAt: $0.resetsAt)
            }
            cycles.append(QuotaCycleHistory(
                id: cycleID, windowKey: windowKey, windowMinutes: windowMinutes,
                resetsAt: points.first?.resetsAt,
                firstObservedAt: points.map(\.observedAt).min() ?? first.observedAt,
                lastObservedAt: points.map(\.lastConfirmedAt).max() ?? first.lastConfirmedAt,
                peakPercent: peak, readings: historyPoints))

            guard points.count >= 2 else { continue }

            // A lower value inside one cycle is not a decrease in consumption. It is a response
            // that started earlier, or an account switch. It is skipped, never treated as a reset.
            var anchor = first
            var maxPercent = first.percent
            for point in points.dropFirst() {
                if point.percent < maxPercent { discard(.quotaDecreased); continue }
                if point.percent == maxPercent { continue }
                let fromDate = anchor.observedAt
                let toDate = point.observedAt
                guard toDate > fromDate else { discard(.duplicateOrOutOfOrder); continue }

                var exclusions: [CapacityExclusion] = []
                if points.first?.resetsAt == nil { exclusions.append(.noResetIdentity) }
                let plan: (id: Int64?, key: String?, label: String?)
                if !timeline.isUnambiguous {
                    plan = (nil, nil, nil)
                    exclusions.append(.ambiguousAccountHistory)
                } else if let startAssignment = timeline.assignment(at: fromDate),
                          let endAssignment = timeline.assignment(at: toDate) {
                    if startAssignment.id != endAssignment.id {
                        plan = (endAssignment.id, endAssignment.planKey, endAssignment.accountLabel)
                        exclusions.append(.planChangedDuringInterval)
                    } else if let key = startAssignment.planKey {
                        plan = (startAssignment.id, key, startAssignment.accountLabel)
                    } else {
                        plan = (startAssignment.id, nil, startAssignment.accountLabel)
                        exclusions.append(.planUnknown)
                    }
                } else {
                    plan = (nil, nil, nil)
                    exclusions.append(.planUnknown)
                }

                let delta = point.percent - maxPercent
                if delta <= 0 { exclusions.append(.zeroQuotaChange) }
                let minimumDelta = max(2.0, 3 * (resolution ?? 1.0))
                if delta < minimumDelta { exclusions.append(.smallQuotaChange) }
                if toDate.timeIntervalSince(fromDate) > maxGap() { exclusions.append(.gapTooLong) }

                intervals.append(CapacityIntervalObservation(
                    id: "\(cycleID)-\(point.id)", accountID: accountID, poolKey: poolKey, windowKey: windowKey,
                    windowMinutes: windowMinutes, cycleID: cycleID, resetsAt: points.first?.resetsAt,
                    from: fromDate, to: toDate, fromPercent: maxPercent, toPercent: point.percent,
                    deltaPercent: delta, planAssignmentID: plan.id, planKey: plan.key, accountLabel: plan.label,
                    workload: CapacityWorkload(), exclusions: unique(exclusions), quotaResolution: resolution))

                anchor = point
                maxPercent = point.percent
            }
        }

        // Intervals from different cycles must not overlap in time: if they do, a request cannot be
        // attributed to one of them without guessing which subscription produced the reading. Mark
        // every interval in an overlapping cluster and keep it out of the estimator.
        let ordered = intervals.indices.sorted { (intervals[$0].from, intervals[$0].id) < (intervals[$1].from, intervals[$1].id) }
        var active: Int?
        var overlapping = Set<Int>()
        for i in ordered {
            if let a = active, intervals[i].from < intervals[a].to {
                overlapping.insert(a)
                overlapping.insert(i)
                if intervals[i].to > intervals[a].to { active = i }
            } else {
                active = i
            }
        }
        if !overlapping.isEmpty {
            for i in overlapping {
                intervals[i].exclusions = unique(intervals[i].exclusions + [.overlappingQuotaIntervals])
            }
        }

        // Load local work once and distribute it across the intervals.
        if let first = intervals.map(\.from).min(), let last = intervals.map(\.to).max(), last > first {
            var workloads = [CapacityWorkload](repeating: CapacityWorkload(), count: intervals.count)
            let order = intervals.indices.sorted { intervals[$0].from < intervals[$1].from }
            var current = 0
            var accumulator = WorkAccumulator()
            var accumulatorIndex: Int?
            func flush() {
                if let index = accumulatorIndex { workloads[index] = accumulator.finish() }
                accumulator = WorkAccumulator()
                accumulatorIndex = nil
            }
            try db.read { c in
                let stmt = try c.prepare("""
                    \(Self.requestSelect)
                    WHERE m.provider_id = ? AND s.account_id = ?
                      AND r.requested_at >= ? AND r.requested_at < ?
                    ORDER BY r.requested_at, r.id
                    """)
                try stmt.bind([.text(provider.rawValue), .int(accountID), .int(Clock.ms(first)), .int(Clock.ms(last))])
                defer { stmt.reset() }
                while try stmt.step() {
                    let row = SQLiteRow(stmt: stmt)
                    let t = row.int(0)
                    while current < order.count && Clock.ms(intervals[order[current]].to) <= t { current += 1 }
                    guard current < order.count else { break }
                    let index = order[current]
                    let interval = intervals[index]
                    guard t >= Clock.ms(interval.from), t < Clock.ms(interval.to) else { continue }
                    if accumulatorIndex != index {
                        flush()
                        accumulatorIndex = index
                    }
                    accumulator.add(row: row, requestedAtMs: t)
                }
                flush()
            }
            for i in intervals.indices {
                var observation = intervals[i]
                observation.workload = workloads[i]
                var exclusions = observation.exclusions
                if observation.workload.requests == 0 {
                    exclusions.append(.noLocalUsage)
                } else {
                    if observation.workload.cost.picoUSD <= 0
                        || (observation.workload.pricedFraction ?? 0) < 0.95 {
                        exclusions.append(.unpricedWorkload)
                    }
                    if observation.workload.coverage.partialRequests > 0
                        || observation.workload.coverage.missingUncachedInput > 0
                        || observation.workload.coverage.missingCacheRead > 0
                        || observation.workload.coverage.missingCacheCreation > 0 {
                        exclusions.append(.incompleteCoverage)
                    }
                    // The minimum-work rule is applied to a whole cycle in the estimator. An
                    // individual interval can be small while its cycle is large; rejecting it here
                    // would silently shrink the exactly observed quota change.
                }
                observation.exclusions = unique(exclusions)
                intervals[i] = observation
            }
        } else {
            // No intervals means nothing can be attributed, but the cycles still explain why.
            intervals = []
        }

        intervals.sort { ($0.from, $0.id) < ($1.from, $1.id) }
        cycles.sort { ($0.firstObservedAt, $0.id) < ($1.firstObservedAt, $1.id) }
        return QuotaHistoryAnalysis(windowKey: windowKey, windowMinutes: windowMinutes, cycles: cycles,
                                    intervals: intervals, quotaResolution: resolution, discarded: discarded)
    }

    private static func unique(_ values: [CapacityExclusion]) -> [CapacityExclusion] {
        var seen = Set<CapacityExclusion>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Accumulates one interval's local requests while the query streams.
struct WorkAccumulator {
    private var requests = 0
    private var tokens = TokenCounts.zero
    private var cost = EstimatedCost.zero
    private var modelCosts: [String: Int64] = [:]
    private var names: [String: String] = [:]
    private var coverage = UsageCoverage()
    private var buckets = 0
    private var lastBucket: Int64?
    private var first: Date?
    private var last: Date?

    mutating func add(row: SQLiteRow, requestedAtMs: Int64) {
        requests += 1
        let uncached = row.intOrNil(3), output = row.int(4), cacheRead = row.intOrNil(5), cacheCreation = row.intOrNil(6)
        let cache5m = row.intOrNil(7), cache1h = row.intOrNil(8), reasoning = row.intOrNil(9)
        tokens += TokenCounts(uncachedInput: uncached ?? 0, output: output, cacheRead: cacheRead ?? 0,
                              cacheCreation: cacheCreation ?? 0, cacheCreation5m: cache5m ?? 0,
                              cacheCreation1h: cache1h ?? 0, reasoningOutput: reasoning ?? 0)
        if uncached == nil { coverage.missingUncachedInput += 1 }
        if cacheRead == nil { coverage.missingCacheRead += 1 }
        if cacheCreation == nil { coverage.missingCacheCreation += 1 }
        if reasoning == nil { coverage.missingReasoning += 1 }
        let completeness = row.text(12)
        if completeness == "partial" { coverage.partialRequests += 1 }
        if completeness == "reconciledFromTotals" { coverage.reconciledRequests += 1 }
        let pico = row.intOrNil(10) ?? 0
        let unpriced = row.intOrNil(11) ?? 0
        cost = cost + EstimatedCost(picoUSD: pico, unpricedTokens: unpriced)
        let canonical = row.text(1)
        if pico > 0 { modelCosts[canonical, default: 0] += pico }
        if names[canonical] == nil { names[canonical] = row.text(2) }
        let bucket = requestedAtMs / 300_000
        if bucket != lastBucket {
            buckets += 1
            lastBucket = bucket
        }
        let date = Clock.date(ms: requestedAtMs)
        if first == nil || date < first! { first = date }
        if last == nil || date > last! { last = date }
    }

    mutating func finish() -> CapacityWorkload {
        coverage.requests = requests
        return CapacityWorkload(requests: requests, tokens: tokens, cost: cost, modelCosts: modelCosts,
                                modelDisplayNames: names, coverage: coverage,
                                activeFiveMinuteBuckets: buckets, firstRequestAt: first, lastRequestAt: last)
    }
}
