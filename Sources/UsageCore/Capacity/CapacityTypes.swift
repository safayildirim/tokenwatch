import Foundation

// MARK: - Workloads

/// Locally observed work during one quota interval.
///
/// This is *not* subscription consumption. It is the application's best normalized description of
/// what happened locally: exact token categories, request count, model mix and API-equivalent cost.
/// API-equivalent cost is a normalization proxy only; it is not how a subscription quota is
/// necessarily enforced.
public struct CapacityWorkload: Sendable, Equatable {
    public var requests: Int
    public var tokens: TokenCounts
    public var cost: EstimatedCost
    /// API-equivalent cost per canonical model, in pico-USD.
    public var modelCosts: [String: Int64]
    public var modelDisplayNames: [String: String]
    public var coverage: UsageCoverage
    /// Number of distinct five-minute buckets in which requests occurred.
    public var activeFiveMinuteBuckets: Int
    public var firstRequestAt: Date?
    public var lastRequestAt: Date?

    public init(requests: Int = 0, tokens: TokenCounts = .zero, cost: EstimatedCost = .zero,
                modelCosts: [String: Int64] = [:], modelDisplayNames: [String: String] = [:],
                coverage: UsageCoverage = UsageCoverage(), activeFiveMinuteBuckets: Int = 0,
                firstRequestAt: Date? = nil, lastRequestAt: Date? = nil) {
        self.requests = requests
        self.tokens = tokens
        self.cost = cost
        self.modelCosts = modelCosts
        self.modelDisplayNames = modelDisplayNames
        self.coverage = coverage
        self.activeFiveMinuteBuckets = activeFiveMinuteBuckets
        self.firstRequestAt = firstRequestAt
        self.lastRequestAt = lastRequestAt
    }

    public var estimatedCostUSD: Double { cost.usdDouble }

    /// The share of processed tokens that could be priced. Nil when there was no work.
    public var pricedFraction: Double? {
        let total = tokens.totalProcessed
        guard total > 0 else { return nil }
        return Double(max(0, total - cost.unpricedTokens)) / Double(total)
    }

    /// Model shares by API-equivalent cost. Empty when nothing was priced.
    public func modelShares() -> [String: Double] {
        let total = modelCosts.values.reduce(Int64(0), +)
        guard total > 0 else { return [:] }
        return modelCosts.mapValues { Double($0) / Double(total) }
    }

    public var cacheReadShare: Double? { tokens.cacheHitRatio }
    public var outputShare: Double? {
        tokens.totalProcessed > 0 ? Double(tokens.output) / Double(tokens.totalProcessed) : nil
    }

    public func merged(with other: CapacityWorkload) -> CapacityWorkload {
        var costs = modelCosts
        for (key, value) in other.modelCosts { costs[key, default: 0] += value }
        var names = modelDisplayNames
        for (key, value) in other.modelDisplayNames where names[key] == nil { names[key] = value }
        let first = [firstRequestAt, other.firstRequestAt].compactMap { $0 }.min()
        let last = [lastRequestAt, other.lastRequestAt].compactMap { $0 }.max()
        return CapacityWorkload(requests: requests + other.requests, tokens: tokens + other.tokens,
                                cost: cost + other.cost, modelCosts: costs, modelDisplayNames: names,
                                coverage: coverage + other.coverage,
                                activeFiveMinuteBuckets: activeFiveMinuteBuckets + other.activeFiveMinuteBuckets,
                                firstRequestAt: first, lastRequestAt: last)
    }
}

// MARK: - Exclusion reasons

/// Why an interval cannot support a capacity comparison.
///
/// These are shown to the user. Nothing is silently discarded: every rejected interval carries at
/// least one reason.
public enum CapacityExclusion: String, Codable, Sendable, CaseIterable, Hashable {
    case planUnknown
    case planChangedDuringInterval
    case cycleHasMultiplePlans
    case overlappingQuotaIntervals
    case ambiguousAccountHistory
    case noResetIdentity
    case quotaDecreased
    case zeroQuotaChange
    case smallQuotaChange
    case gapTooLong
    case noLocalUsage
    case unpricedWorkload
    case incompleteCoverage
    case workloadTooSmall
    case measurementSpansCycles
    case measurementMissingReading
    case measurementStillOpen
    case measurementPlanChanged
    case duplicateOrOutOfOrder
    case outlierConsumption

    /// True when the interval must not enter the estimator. `duplicateOrOutOfOrder` is used while
    /// assembling the sequence and never labels a finished interval; it remains here for auditability.
    public var isBlocking: Bool {
        switch self {
        case .planUnknown, .planChangedDuringInterval, .cycleHasMultiplePlans, .overlappingQuotaIntervals,
             .ambiguousAccountHistory, .noResetIdentity,
             .quotaDecreased, .zeroQuotaChange, .smallQuotaChange, .gapTooLong,
             .noLocalUsage, .unpricedWorkload, .incompleteCoverage, .workloadTooSmall,
             .measurementSpansCycles, .measurementMissingReading, .measurementStillOpen, .measurementPlanChanged,
             .duplicateOrOutOfOrder, .outlierConsumption:
            true
        }
    }

    public var title: String {
        switch self {
        case .planUnknown:
            String(localized: "No plan was recorded for this period")
        case .planChangedDuringInterval:
            String(localized: "The plan changed inside the interval")
        case .cycleHasMultiplePlans:
            String(localized: "One quota cycle contributed eligible intervals for more than one plan")
        case .overlappingQuotaIntervals:
            String(localized: "Two quota cycles overlap in time, so local work cannot be attributed cleanly")
        case .ambiguousAccountHistory:
            String(localized: "The account history is ambiguous")
        case .noResetIdentity:
            String(localized: "The quota reset identity is missing")
        case .quotaDecreased:
            String(localized: "Quota utilization decreased inside one cycle")
        case .zeroQuotaChange:
            String(localized: "Quota utilization did not change")
        case .smallQuotaChange:
            String(localized: "The quota change is too small relative to its rounding")
        case .gapTooLong:
            String(localized: "Too much time passed between quota readings")
        case .noLocalUsage:
            String(localized: "No local usage was observed in the interval")
        case .unpricedWorkload:
            String(localized: "Part of the workload has no price, so it cannot be normalized")
        case .incompleteCoverage:
            String(localized: "The local usage record is incomplete")
        case .workloadTooSmall:
            String(localized: "The observed workload is too small to compare")
        case .measurementSpansCycles:
            String(localized: "The measurement crosses a quota reset")
        case .measurementMissingReading:
            String(localized: "The measurement ended without a fresh quota reading")
        case .measurementStillOpen:
            String(localized: "The measurement is still open")
        case .measurementPlanChanged:
            String(localized: "The plan changed during the measurement")
        case .duplicateOrOutOfOrder:
            String(localized: "Duplicate or out-of-order reading")
        case .outlierConsumption:
            String(localized: "Quota consumption per unit of work is an outlier")
        }
    }
}

// MARK: - Quota interval observations

/// One trustworthy-looking step between two authoritative readings of the same quota cycle.
///
/// The percentage change is observed. The local workload is observed. Their ratio is an estimate of
/// marginal quota consumption, never a provider-reported capacity.
public struct CapacityIntervalObservation: Sendable, Equatable, Identifiable {
    public var id: String
    public var accountID: Int64
    public var poolKey: String
    public var windowKey: String
    public var windowMinutes: Int?
    public var cycleID: Int64
    public var resetsAt: Date?
    public var from: Date
    public var to: Date
    public var fromPercent: Double
    public var toPercent: Double
    public var deltaPercent: Double
    public var planAssignmentID: Int64?
    public var planKey: String?
    public var accountLabel: String?
    public var workload: CapacityWorkload
    public var exclusions: [CapacityExclusion]
    public var quotaResolution: Double?

    public var isEligible: Bool { exclusions.isEmpty }
    public var duration: TimeInterval { max(0, to.timeIntervalSince(from)) }
}

public struct QuotaCycleHistory: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var windowKey: String
    public var windowMinutes: Int?
    public var resetsAt: Date?
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var peakPercent: Double
    public var readings: [QuotaHistoryPoint]

    public var isCompleteWindow: Bool {
        // A window is complete only if it has a reset time and the peak reached 100%, which is the
        // only point at which the provider has told us the allowance was exhausted.
        resetsAt != nil && peakPercent >= 99.999
    }
}

public struct QuotaHistoryPoint: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var percent: Double
    public var observedAt: Date
    public var lastConfirmedAt: Date
    public var resetsAt: Date?
}

// MARK: - Estimation input

/// A cycle-level sample. Multiple eligible intervals inside one cycle are summed, so a busy cycle
/// contributes one independent observation rather than many pseudo-replicates.
public struct CapacitySample: Sendable, Equatable, Identifiable {
    public var id: String
    public var planKey: String
    public var cycleID: Int64
    public var windowKey: String
    public var deltaPercent: Double
    public var workload: CapacityWorkload
    public var intervalCount: Int
    public var from: Date
    public var to: Date

    public var quotaPercentPerUSD: Double? {
        guard workload.estimatedCostUSD > 0 else { return nil }
        return deltaPercent / workload.estimatedCostUSD
    }
}

public enum CapacityEstimationMethod: String, Sendable, Equatable {
    case matchedCycles
    case pooledStandardizedWork

    public var title: String {
        switch self {
        case .matchedCycles: String(localized: "Matched cycles")
        case .pooledStandardizedWork: String(localized: "Pooled standardized work")
        }
    }
}

public enum CapacityEvidenceLevel: String, Sendable, Equatable, CaseIterable {
    case insufficient
    case limited
    case moderate
    case strong

    public var title: String {
        switch self {
        case .insufficient: String(localized: "Insufficient evidence")
        case .limited: String(localized: "Limited evidence")
        case .moderate: String(localized: "Moderate evidence")
        case .strong: String(localized: "Strong evidence")
        }
    }

    /// This is a policy label, not a confidence score. It says how much independent, comparable
    /// evidence exists.
    public var explanation: String {
        switch self {
        case .insufficient:
            String(localized: "There are too few independent quota cycles with comparable work. No ratio is shown.")
        case .limited:
            String(localized: "At least two independent cycles per plan and two matched comparisons exist. Treat the ratio as provisional.")
        case .moderate:
            String(localized: "At least four independent cycles per plan and four matched comparisons exist.")
        case .strong:
            String(localized: "At least eight independent cycles per plan, eight matched comparisons, a fortnight of history, and agreement between methods.")
        }
    }
}

public struct CapacityComparability: Sendable, Equatable {
    public var modelCosineSimilarity: Double?
    public var cacheReadShareBase: Double?
    public var cacheReadShareOther: Double?
    public var outputShareBase: Double?
    public var outputShareOther: Double?
    public var requestsBase: Int
    public var requestsOther: Int
    public var workUSDBase: Double
    public var workUSDOther: Double
}

public struct CapacityEstimate: Sendable, Equatable, Identifiable {
    /// The plan used as the denominator.
    public var basePlanKey: String
    /// The plan whose capacity is being estimated.
    public var otherPlanKey: String
    public var windowKey: String
    public var windowMinutes: Int?
    /// Capacity(other) / capacity(base). Nil when evidence is insufficient.
    public var ratio: Double?
    /// A ratio from at least one matched pair, shown only as provisional when `ratio` is nil.
    public var provisionalRatio: Double?
    public var level: CapacityEvidenceLevel
    public var method: CapacityEstimationMethod?
    public var matchedPairs: Int
    public var baseCycles: Int
    public var otherCycles: Int
    public var baseIntervals: Int
    public var otherIntervals: Int
    public var dateRange: ClosedRange<Date>?
    /// Spread across matched pairs and the pooled method. This is a sensitivity range, not a
    /// confidence interval.
    public var sensitivityRange: ClosedRange<Double>?
    public var pooledRatio: Double?
    public var comparability: CapacityComparability
    public var exclusions: [CapacityExclusion: Int]
    /// Cycles removed by the explicit outlier rule. They remain in the stored history.
    public var outlierCycleIDs: [Int64]

    public var id: String { "\(basePlanKey)->\(otherPlanKey)/\(windowKey)" }

    public var hasEnoughEvidence: Bool { ratio != nil && level != .insufficient }
}

public struct CapacityEstimationPolicy: Sendable, Equatable {
    /// Independent cycles required in each plan before a ratio is published.
    public var minimumCyclesPerPlan = 2
    /// Matched cycle pairs required before a ratio is published.
    public var minimumMatchedPairs = 2
    /// Workloads whose model-cost distributions are less similar than this are not paired.
    public var minimumModelCosineSimilarity = 0.85
    /// Workloads whose cache-read shares differ by more than this are not paired.
    public var maximumCacheShareDifference = 0.15
    public var maximumOutputShareDifference = 0.10
    /// Pooled comparison requires a stricter whole-period composition match.
    public var pooledMinimumModelCosineSimilarity = 0.90
    /// A cycle must contain at least this much API-equivalent work to be usable.
    public var minimumCycleWorkPicoUSD: Int64 = 10_000_000_000 // $0.01
    /// Outlier rule: above this multiple of the plan's median consumption rate, a cycle is excluded.
    public var outlierRateMultiple = 4.0
    public var moderateCycles = 4
    public var moderatePairs = 4
    public var strongCycles = 8
    public var strongPairs = 8
    public var strongSpanDays = 14.0

    public init() {}
}

// MARK: - Purchasing strategies

/// A purchasing strategy: `count` independent subscriptions of one plan.
///
/// Independent subscriptions have independent quota pools. A count greater than one is an aggregate
/// across pools, never one larger pool.
public struct SubscriptionStrategy: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var planKey: String
    public var count: Int

    public init(id: String, name: String, planKey: String, count: Int) {
        self.id = id
        self.name = name
        self.planKey = planKey
        self.count = max(1, count)
    }
}

public struct StrategyCostRow: Sendable, Equatable, Identifiable {
    public var id: String { strategy.id }
    public var strategy: SubscriptionStrategy
    public var plan: SubscriptionPlanDefinition
    public var monthlyPriceMicros: Int64
    public var monthlyCostMicros: Int64
    public var priceOrigin: PlanPriceQuote.Origin
    public var nominalCapacityByWindow: [Int: Double]
    public var measuredCapacityByWindow: [Int: Double]
    public var measuredCapacityPerDollar: [Int: Double]

    public var monthlyCost: Double { Double(monthlyCostMicros) / 1_000_000 }
    public var poolsAreIndependent: Bool { strategy.count > 1 }
}

public struct StrategyBreakEven: Sendable, Equatable {
    public var numeratorStrategyID: String
    public var denominatorStrategyID: String
    public var windowKey: String
    public var windowMinutes: Int?
    /// The measured capacity ratio B/A at which the two strategies have equal capacity per dollar.
    public var requiredRatio: Double?
    public var measuredRatio: Double?
    public var estimatedMonthlyCostMicros1: Int64
    public var estimatedMonthlyCostMicros2: Int64
}

public struct CapacityStrategyComparison: Sendable, Equatable {
    public var provider: ProviderID
    public var poolKey: String
    public var windowKey: String
    public var windowMinutes: Int?
    public var basePlanKey: String
    public var rows: [StrategyCostRow]
    public var breakEvens: [StrategyBreakEven]
    /// The strategy with the highest measured capacity per dollar, if every row has a measurement.
    public var measuredLeaderID: String?
    public var nominalLeaderID: String?
    public var caveats: [String]
}
