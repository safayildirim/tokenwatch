import Foundation

// MARK: - Report shape

/// How the identity of an account is known.
///
/// A subscription's capacity comparison is only meaningful within one account. A provider-verified
/// account identifier is evidence. A manual label is metadata, and a missing identifier is a fact.
public enum CapacityIdentityBasis: String, Sendable, Equatable {
    case providerVerified
    case unassignedAccount
    case manualLabel
    case conflictingManualLabels
    case ambiguousPlanHistory

    public var title: String {
        switch self {
        case .providerVerified: String(localized: "Provider-identified account")
        case .unassignedAccount: String(localized: "Account identity not reported")
        case .manualLabel: String(localized: "Manually labelled account")
        case .conflictingManualLabels: String(localized: "Conflicting manual account labels")
        case .ambiguousPlanHistory: String(localized: "Overlapping plan periods")
        }
    }

    public var explanation: String {
        switch self {
        case .providerVerified:
            String(localized: "The provider's telemetry identifies this account. Plan periods still come from your own annotations.")
        case .unassignedAccount:
            String(localized: "The provider's local telemetry does not identify which subscription account produced these readings. Comparisons are within this unassigned account only; no identity is inferred from timing or reset values.")
        case .manualLabel:
            String(localized: "The account is not provider-identified, and the plan periods that carry a label use the same one. A label is metadata, not proof of identity; unlabelled periods still belong to this unassigned account.")
        case .conflictingManualLabels:
            String(localized: "The account is not provider-identified, and plan periods carry different manual labels. The app cannot tell whether those periods belong to the same subscription, so it will not compare them.")
        case .ambiguousPlanHistory:
            String(localized: "Plan periods for this account overlap. Until the overlap is corrected, capacity comparisons are not supported.")
        }
    }

    public var supportsComparison: Bool {
        self != .conflictingManualLabels && self != .ambiguousPlanHistory
    }
}

public struct CapacityReport: Sendable, Equatable {
    public var generatedAt: Date
    public var range: ClosedRange<Date>
    public var accounts: [CapacityAccountReport]

    public init(generatedAt: Date, range: ClosedRange<Date>, accounts: [CapacityAccountReport]) {
        self.generatedAt = generatedAt
        self.range = range
        self.accounts = accounts
    }
}

public struct CapacityAccountReport: Sendable, Equatable, Identifiable {
    public var provider: ProviderID
    public var accountID: Int64
    public var accountLabel: String
    public var accountHash: String?
    public var poolKey: String
    public var poolName: String
    public var identityBasis: CapacityIdentityBasis
    public var planPeriods: [PlanAssignment]
    public var currentPlanKey: String?
    public var planNames: [String: String]
    public var windows: [CapacityWindowReport]
    public var measurements: [CapacityMeasurementReview]
    public var strategyComparisons: [CapacityStrategyComparison]
    public var warnings: [String]

    public var id: String { "\(provider.rawValue)/\(accountID)/\(poolKey)" }
    public var isVerified: Bool { identityBasis == .providerVerified }
    public var supportsComparison: Bool { identityBasis.supportsComparison }
}

public struct CapacityWindowReport: Sendable, Equatable, Identifiable {
    public var windowKey: String
    public var windowMinutes: Int?
    public var windowName: String
    public var currentPlanKey: String?
    public var history: QuotaHistoryAnalysis
    public var samples: [CapacitySample]
    public var estimates: [CapacityEstimate]
    public var exclusions: [CapacityExclusion: Int]
    public var planKeys: [String]

    public var id: String { windowKey }
    public var observedPeak: Double? { history.peakUtilization }
    public var completeCycles: Int { history.completeCycles }
    public var usableCycles: Int { Set(samples.map(\.cycleID)).count }
    public var usableWorkUSD: Double { samples.reduce(0) { $0 + $1.workload.estimatedCostUSD } }
}

/// A review of an explicitly labelled measurement interval, snapped to the quota readings that
/// bracket it. The label is the person's annotation; the readings are the observations.
public struct CapacityMeasurementReview: Sendable, Equatable, Identifiable {
    public var measurement: CapacityMeasurement
    public var baseline: CapacityReadingPoint?
    public var ending: CapacityReadingPoint?
    public var deltaPercent: Double?
    public var workload: CapacityWorkload
    public var cycleID: Int64?
    public var exclusions: [CapacityExclusion]

    public var id: Int64 { measurement.id }
    public var isUsable: Bool { exclusions.isEmpty && (deltaPercent ?? 0) > 0 }
}

public struct CapacityReadingPoint: Sendable, Equatable {
    public var id: Int64
    public var percent: Double
    public var observedAt: Date
    public var resetsAt: Date?
    public var cycleID: Int64
}

// MARK: - Engine

/// Builds capacity reports from stored quota snapshots and local request history.
///
/// The engine is provider-agnostic. Plans and nominal multipliers come from the registry; the
/// purchasing strategies are supplied by the caller. Nothing here names a provider, and no
/// percentage is ever computed from tokens.
public enum CapacityAnalyticsEngine {
    public static func report(_ db: UsageDatabase, range: ClosedRange<Date>,
                              strategies: [SubscriptionStrategy] = [], basePlanKey: String? = nil,
                              now: Date = Date(),
                              policy: CapacityEstimationPolicy = CapacityEstimationPolicy()) throws -> CapacityReport {
        let registry = db.registry
        let accounts: [(provider: ProviderID, accountID: Int64, label: String, hash: String, poolKey: String, poolName: String)] =
            try db.read { c in
                try c.query("""
                    SELECT p.provider_id, p.account_id, COALESCE(a.label, 'Unassigned'), a.hash, p.pool_key
                    FROM quota_pool p
                    JOIN account a ON a.id = p.account_id
                    ORDER BY p.provider_id, p.account_id, p.pool_key
                    """) { r in
                    (ProviderID(rawValue: r.text(0)), r.int(1), r.text(2), r.text(3), r.text(4), "")
                }
            }

        var out: [CapacityAccountReport] = []
        for account in accounts {
            let registryPlans = registry.plans(of: account.provider)
            let timeline = try PlanHistoryStore.timeline(db, provider: account.provider, accountID: account.accountID)

            let assignments = timeline.assignments
            let planKeys = Array(Set(assignments.compactMap(\.planKey))).sorted()
            var planNames: [String: String] = [:]
            for plan in registryPlans { planNames[plan.key] = plan.name }
            for key in planKeys where planNames[key] == nil { planNames[key] = key }

            let labels = Array(Set(assignments.compactMap { $0.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            let identity: CapacityIdentityBasis
            if !account.hash.isEmpty {
                identity = .providerVerified
            } else if !timeline.isUnambiguous {
                identity = .ambiguousPlanHistory
            } else if labels.count > 1 {
                identity = .conflictingManualLabels
            } else if labels.count == 1 {
                identity = .manualLabel
            } else {
                identity = .unassignedAccount
            }

            let windows = try windowReports(db, account: account, timeline: timeline, registryPlans: registryPlans,
                                            planKeys: planKeys, planNames: planNames, range: range,
                                            policy: policy, supportsComparison: identity.supportsComparison, now: now)
            let measurements = try measurementReviews(db, account: account, timeline: timeline, windows: windows,
                                                      range: range, policy: policy)
            let support = identity.supportsComparison && timeline.isUnambiguous
            let comparisons: [CapacityStrategyComparison]
            if support, !strategies.isEmpty {
                comparisons = windows.compactMap { window in
                    CapacityStrategyAnalyzer.compare(db: db, provider: account.provider, poolKey: account.poolKey,
                                                     window: window, registryPlans: registryPlans,
                                                     strategies: strategies, basePlanKey: basePlanKey)
                }
            } else {
                comparisons = []
            }

            var warnings: [String] = []
            if identity == .unassignedAccount || identity == .manualLabel {
                warnings.append(String(localized: "The provider does not identify the account locally. The comparison holds only for this unassigned account; it is never combined with another account."))
            }
            if identity == .conflictingManualLabels {
                warnings.append(String(localized: "Different manual labels describe the same unassigned provider account. Because identity across labels is not proven, no comparison is produced."))
            }
            if !timeline.isUnambiguous {
                warnings.append(String(localized: "Plan periods overlap. Correct the plan history before using capacity estimates."))
            }
            if timeline.assignments.isEmpty {
                warnings.append(String(localized: "No plan periods are recorded. Add the plan you used, and when, to make any comparison possible."))
            } else if !timeline.gaps.isEmpty {
                warnings.append(String(localized: "Some periods have no plan recorded. Quota consumed in those gaps is not attributed to any plan."))
            }
            if !measurements.isEmpty && measurements.contains(where: { $0.measurement.state == .open }) {
                warnings.append(String(localized: "A measurement is still open. It will be reviewed after it ends."))
            }

            out.append(CapacityAccountReport(
                provider: account.provider, accountID: account.accountID, accountLabel: account.label,
                accountHash: account.hash.isEmpty ? nil : account.hash, poolKey: account.poolKey,
                poolName: registry.pools.first(where: { $0.provider == account.provider && $0.key == account.poolKey })?.name ?? account.poolName,
                identityBasis: identity, planPeriods: assignments,
                currentPlanKey: timeline.assignment(at: now)?.planKey,
                planNames: planNames, windows: windows, measurements: measurements,
                strategyComparisons: comparisons, warnings: warnings))
        }
        return CapacityReport(generatedAt: now, range: range, accounts: out)
    }

    // MARK: Windows

    private static func windowReports(_ db: UsageDatabase,
                                      account: (provider: ProviderID, accountID: Int64, label: String, hash: String, poolKey: String, poolName: String),
                                      timeline: PlanTimeline, registryPlans: [SubscriptionPlanDefinition],
                                      planKeys: [String], planNames: [String: String],
                                      range: ClosedRange<Date>, policy: CapacityEstimationPolicy,
                                      supportsComparison: Bool, now: Date) throws -> [CapacityWindowReport] {
        let windows: [(key: String, minutes: Int?)] = try db.read { c in
            try c.query("""
                SELECT w.window_key, w.duration_minutes
                FROM quota_window w JOIN quota_pool p ON p.id = w.pool_id
                WHERE p.account_id = ? AND p.pool_key = ?
                ORDER BY COALESCE(w.duration_minutes, 9223372036854775807), w.window_key
                """, [.int(account.accountID), .text(account.poolKey)]) { r in
                (r.text(0), r.intOrNil(1).map { Int($0) })
            }
        }

        // A model-scoped limit has only a share of the plan's allowance, so a plan-wide nominal multiplier does not
        // apply to it. It remains visible in the quota views, but it must not produce a capacity ratio for the plan.
        return try windows.filter { WindowNaming.scopedLabel(fallbackKey: $0.key) == nil }.map { window in
            let history = try QuotaHistoryAnalyzer.analyze(
                db, provider: account.provider, accountID: account.accountID, poolKey: account.poolKey,
                windowKey: window.key, from: range.lowerBound, to: range.upperBound, timeline: timeline, policy: policy)
            var exclusions = history.discarded
            for interval in history.intervals {
                for exclusion in interval.exclusions { exclusions[exclusion, default: 0] += 1 }
            }
            // A cycle that produced eligible intervals on more than one plan is not two
            // independent observations. Drop both sides rather than double-counting one cycle.
            var plansByCycle: [Int64: Set<String>] = [:]
            for interval in history.intervals where interval.isEligible {
                if let plan = interval.planKey { plansByCycle[interval.cycleID, default: []].insert(plan) }
            }
            let splitCycles = Set(plansByCycle.filter { $0.value.count > 1 }.keys)
            var usableIntervals = history.intervals
            if !splitCycles.isEmpty {
                let dropped = usableIntervals.filter { $0.isEligible && splitCycles.contains($0.cycleID) }.count
                exclusions[.cycleHasMultiplePlans, default: 0] += dropped
                usableIntervals.removeAll { $0.isEligible && splitCycles.contains($0.cycleID) }
            }
            let samples = cycleSamples(usableIntervals)
            let keys = Array(Set(planKeys + samples.map(\.planKey))).sorted()
            var estimates: [CapacityEstimate] = []
            if supportsComparison && timeline.isUnambiguous {
                for base in keys {
                    for other in keys where other != base {
                        estimates.append(CapacityEstimator.estimate(
                            basePlanKey: base, otherPlanKey: other, windowKey: window.key,
                            windowMinutes: window.minutes, samples: samples, exclusions: exclusions, policy: policy))
                    }
                }
            }
            return CapacityWindowReport(
                windowKey: window.key, windowMinutes: window.minutes,
                windowName: WindowNaming.displayName(minutes: window.minutes, fallbackKey: window.key),
                currentPlanKey: timeline.assignment(at: now)?.planKey,
                history: history, samples: samples, estimates: estimates,
                exclusions: exclusions, planKeys: keys)
        }
    }

    static func cycleSamples(_ intervals: [CapacityIntervalObservation]) -> [CapacitySample] {
        struct Key: Hashable { var plan: String; var cycle: Int64 }
        var grouped: [Key: [CapacityIntervalObservation]] = [:]
        var order: [Key] = []
        for interval in intervals where interval.isEligible {
            guard let plan = interval.planKey else { continue }
            let key = Key(plan: plan, cycle: interval.cycleID)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(interval)
        }
        return order.compactMap { key in
            guard let group = grouped[key], let first = group.map(\.from).min(), let last = group.map(\.to).max() else { return nil }
            let delta = group.reduce(0.0) { $0 + $1.deltaPercent }
            let workload = group.reduce(CapacityWorkload()) { $0.merged(with: $1.workload) }
            return CapacitySample(id: "\(key.cycle)-\(key.plan)", planKey: key.plan, cycleID: key.cycle,
                                  windowKey: group[0].windowKey, deltaPercent: delta, workload: workload,
                                  intervalCount: group.count, from: first, to: last)
        }.sorted { ($0.from, $0.id) < ($1.from, $1.id) }
    }

    // MARK: Controlled measurements

    private static func measurementReviews(_ db: UsageDatabase,
                                           account: (provider: ProviderID, accountID: Int64, label: String, hash: String, poolKey: String, poolName: String),
                                           timeline: PlanTimeline, windows: [CapacityWindowReport],
                                           range: ClosedRange<Date>,
                                           policy: CapacityEstimationPolicy) throws -> [CapacityMeasurementReview] {
        let measurements = try CapacityMeasurementStore.list(db, provider: account.provider, accountID: account.accountID,
                                                              poolKey: account.poolKey, includeClosed: true)
            .filter { $0.startedAt <= range.upperBound && ($0.endedAt ?? .distantFuture) >= range.lowerBound }
        let byWindow = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowKey, $0) })
        return try measurements.map { measurement in
            guard let window = byWindow[measurement.windowKey] else {
                return CapacityMeasurementReview(measurement: measurement, baseline: nil, ending: nil, deltaPercent: nil,
                                                 workload: CapacityWorkload(), cycleID: nil,
                                                 exclusions: [.measurementMissingReading])
            }
            return try review(db, measurement: measurement, window: window, timeline: timeline, policy: policy)
        }
    }

    private static func review(_ db: UsageDatabase, measurement: CapacityMeasurement, window: CapacityWindowReport,
                               timeline: PlanTimeline, policy: CapacityEstimationPolicy) throws -> CapacityMeasurementReview {
        var exclusions: [CapacityExclusion] = []
        guard measurement.state == .closed, let endedAt = measurement.endedAt else {
            let reason: CapacityExclusion = measurement.state == .open ? .measurementStillOpen : .measurementMissingReading
            return CapacityMeasurementReview(measurement: measurement, baseline: nil, ending: nil, deltaPercent: nil,
                                             workload: CapacityWorkload(), cycleID: nil, exclusions: [reason])
        }
        let baseline = try reading(db, measurement: measurement, at: measurement.startedAt, before: true)
        let ending = try reading(db, measurement: measurement, at: endedAt, before: false)
        guard let baseline, let ending else {
            return CapacityMeasurementReview(measurement: measurement, baseline: baseline, ending: ending, deltaPercent: nil,
                                             workload: CapacityWorkload(), cycleID: nil,
                                             exclusions: [.measurementMissingReading])
        }
        if baseline.cycleID != ending.cycleID { exclusions.append(.measurementSpansCycles) }
        if ending.percent < baseline.percent { exclusions.append(.quotaDecreased) }
        let delta = ending.percent - baseline.percent
        if delta <= 0 { exclusions.append(.zeroQuotaChange) }
        if let resolution = window.history.quotaResolution, delta < max(2.0, 3 * resolution) {
            exclusions.append(.smallQuotaChange)
        }
        if !timeline.isUnambiguous {
            exclusions.append(.ambiguousAccountHistory)
        } else {
            let startAssignment = timeline.assignment(at: baseline.observedAt)
            let endAssignment = timeline.assignment(at: ending.observedAt)
            if startAssignment?.id != endAssignment?.id {
                exclusions.append(.measurementPlanChanged)
            } else if startAssignment?.planKey == nil {
                exclusions.append(.planUnknown)
            } else if let captured = measurement.planAssignmentID, startAssignment?.id != captured {
                exclusions.append(.measurementPlanChanged)
            } else if let capturedPlan = measurement.planKey, startAssignment?.planKey != capturedPlan {
                exclusions.append(.measurementPlanChanged)
            }
        }
        // Work is measured from reading to reading, so the numerator and denominator describe the
        // same interval. The labelled start and end merely choose which readings bracket it.
        let workload = try QuotaHistoryAnalyzer.workload(db, provider: measurement.provider, accountID: measurement.accountID,
                                                         from: baseline.observedAt, to: ending.observedAt)
        if workload.requests == 0 {
            exclusions.append(.noLocalUsage)
        } else {
            if workload.cost.picoUSD <= 0 || (workload.pricedFraction ?? 0) < 0.95 {
                exclusions.append(.unpricedWorkload)
            }
            if workload.coverage.partialRequests > 0 || workload.coverage.missingUncachedInput > 0
                || workload.coverage.missingCacheRead > 0 || workload.coverage.missingCacheCreation > 0 {
                exclusions.append(.incompleteCoverage)
            }
            if workload.cost.picoUSD < policy.minimumCycleWorkPicoUSD { exclusions.append(.workloadTooSmall) }
        }
        return CapacityMeasurementReview(measurement: measurement, baseline: baseline, ending: ending,
                                         deltaPercent: max(0, delta), workload: workload,
                                         cycleID: baseline.cycleID, exclusions: unique(exclusions))
    }

    private static func reading(_ db: UsageDatabase, measurement: CapacityMeasurement, at date: Date,
                                before: Bool) throws -> CapacityReadingPoint? {
        let tolerance: Int64 = (before ? 15 : 15) * 60 * 1000
        let sql: String
        let params: [SQLValue]
        if before {
            sql = """
                SELECT q.id, q.utilization_pct, q.observed_at, q.resets_at, q.cycle_id
                FROM quota_snapshot q
                JOIN quota_window w ON w.id = q.window_id
                JOIN quota_pool p ON p.id = w.pool_id
                WHERE p.account_id = ? AND p.pool_key = ? AND w.window_key = ?
                  AND q.authority = 'authoritative'
                  AND q.observed_at <= ? AND q.observed_at >= ?
                ORDER BY q.observed_at DESC, q.id DESC LIMIT 1
                """
            params = [.int(measurement.accountID), .text(measurement.poolKey), .text(measurement.windowKey),
                      .int(Clock.ms(date)), .int(Clock.ms(date) - tolerance)]
        } else {
            sql = """
                SELECT q.id, q.utilization_pct, q.observed_at, q.resets_at, q.cycle_id
                FROM quota_snapshot q
                JOIN quota_window w ON w.id = q.window_id
                JOIN quota_pool p ON p.id = w.pool_id
                WHERE p.account_id = ? AND p.pool_key = ? AND w.window_key = ?
                  AND q.authority = 'authoritative'
                  AND q.observed_at >= ? AND q.observed_at <= ?
                ORDER BY q.observed_at ASC, q.id ASC LIMIT 1
                """
            params = [.int(measurement.accountID), .text(measurement.poolKey), .text(measurement.windowKey),
                      .int(Clock.ms(date)), .int(Clock.ms(date) + tolerance)]
        }
        return try db.read { c in
            try c.queryOne(sql, params) { r in
                CapacityReadingPoint(id: r.int(0), percent: r.double(1), observedAt: Clock.date(ms: r.int(2)),
                                     resetsAt: r.intOrNil(3).map(Clock.date(ms:)), cycleID: r.int(4))
            }
        } ?? nil
    }

    private static func unique(_ values: [CapacityExclusion]) -> [CapacityExclusion] {
        var seen = Set<CapacityExclusion>()
        return values.filter { seen.insert($0).inserted }
    }
}
