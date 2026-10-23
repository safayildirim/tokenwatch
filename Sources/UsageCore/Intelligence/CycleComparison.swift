import Foundation

/// Why two cycles cannot be compared directly.
///
/// A difference in tokens or in tokens per percentage point means something only when the cycles were measured under
/// the same conditions. Each reason names a condition under which the same number would mean something else.
public enum ComparabilityIssue: String, Sendable, Codable, CaseIterable {
    case differentPlan
    case planNotRecorded
    case differentModelMix
    case differentCacheBehavior
    case differentObservationCoverage
    case partialQuotaObservation
    case projectedBoundaries
}

/// The figures of one cycle that a comparison uses.
public struct CycleMetrics: Sendable, Equatable, Identifiable {
    public var id: String
    public var start: Date
    public var end: Date
    public var timing: CycleTiming
    public var planKey: String?
    public var processedTokens: Int64
    public var freshTokens: Int64
    public var requests: Int
    public var cacheReadShare: Double?
    public var averageProcessedPerRequest: Double?
    public var averageOutputPerRequest: Double?
    public var costUSD: Double
    public var activeDays: Int
    public var maximumPercent: Double?
    public var observedRisePoints: Double?
    /// The observed rise divided by the days between the first and the last reading.
    public var observedPointsPerDay: Double?
    public var reachedLimit: Bool
    public var completeness: CycleCompleteness?
    /// The fraction of the elapsed cycle in which the value is determined and supported by observations.
    public var coverageFraction: Double?
    public var isProjected: Bool
    public var modelShares: [String: Double]
    public var processedTokensPerPoint: EfficiencyRange?
    public var efficiencyQuality: EfficiencyQuality?

    public init(_ cycle: SubscriptionCycleReport) {
        let local = cycle.local
        let tokens = local.tokens
        id = cycle.id
        start = cycle.span.start
        end = cycle.span.end
        timing = cycle.timing
        planKey = cycle.plan?.key
        processedTokens = tokens.totalProcessed
        freshTokens = tokens.freshTokens
        requests = local.requests
        cacheReadShare = tokens.cacheHitRatio
        averageProcessedPerRequest = local.requests > 0 ? Double(tokens.totalProcessed) / Double(local.requests) : nil
        averageOutputPerRequest = local.requests > 0 ? Double(tokens.output) / Double(local.requests) : nil
        costUSD = local.cost.usdDouble
        activeDays = local.activeDays
        maximumPercent = cycle.quota?.maximumPercent
        observedRisePoints = cycle.quota?.observedRisePoints
        if let quota = cycle.quota, let first = quota.firstObservedAt, let last = quota.lastConfirmedAt,
           let rise = quota.observedRisePoints, last.timeIntervalSince(first) >= 3600 {
            observedPointsPerDay = rise / (last.timeIntervalSince(first) / 86_400)
        }
        reachedLimit = cycle.quota?.reachedLimit ?? false
        completeness = cycle.quota?.completeness
        coverageFraction = cycle.quota?.coverage.supportedFraction
        isProjected = cycle.span.origin == .projected
        modelShares = Dictionary(local.models.map { ($0.canonical, $0.share) }, uniquingKeysWith: { a, _ in a })
        processedTokensPerPoint = cycle.efficiency.processedTokensPerPoint
        efficiencyQuality = cycle.efficiency.quality
    }
}

/// A comparison of two cycles, which reports differences and never a verdict.
public struct CycleComparison: Sendable, Equatable {
    public var earlier: CycleMetrics
    public var later: CycleMetrics
    public var issues: [ComparabilityIssue]
    /// The relative change of the processed tokens, for example 0.28 for 28% more.
    public var processedChange: Double?
    public var freshChange: Double?
    public var costChange: Double?
    /// The relative change of the observed quota pace. It is reported only when the cycles are directly comparable.
    public var quotaPaceChange: Double?
    /// The relative change of the processed tokens per percentage point. It is reported only when the cycles are directly
    /// comparable and both ratios are reliable, and it is deliberately not called an improvement or a regression.
    public var tokensPerPointChange: Double?

    public var isDirectlyComparable: Bool { issues.isEmpty }
}

/// The cycles of a period, taken together.
public struct PeriodSummary: Sendable, Equatable {
    public var cycles: [CycleMetrics]
    public var totalProcessedTokens: Int64
    public var totalFreshTokens: Int64
    public var meanProcessedPerCycle: Double
    public var meanFreshPerCycle: Double
    public var cyclesReachingLimit: Int
    public var meanMaximumPercent: Double?
    public var cyclesWithQuota: Int
    public var completeCycles: Int
    public var totalCostUSD: Double
}

public enum CycleComparisonEngine {
    public static let modelMixThreshold = 0.25
    public static let cacheBehaviorThreshold = 0.10
    public static let coverageThreshold = 0.25

    public static func compare(_ earlier: CycleMetrics, _ later: CycleMetrics) -> CycleComparison {
        var issues: [ComparabilityIssue] = []
        if earlier.planKey != later.planKey {
            issues.append(.differentPlan)
        } else if earlier.planKey == nil {
            issues.append(.planNotRecorded)
        }
        if modelMixDistance(earlier.modelShares, later.modelShares) > modelMixThreshold { issues.append(.differentModelMix) }
        if let a = earlier.cacheReadShare, let b = later.cacheReadShare, abs(a - b) > cacheBehaviorThreshold {
            issues.append(.differentCacheBehavior)
        }
        if earlier.isProjected || later.isProjected {
            issues.append(.projectedBoundaries)
        } else {
            if earlier.completeness != .complete || later.completeness != .complete { issues.append(.partialQuotaObservation) }
            if let a = earlier.coverageFraction, let b = later.coverageFraction, abs(a - b) > coverageThreshold {
                issues.append(.differentObservationCoverage)
            }
        }

        func change(_ a: Double, _ b: Double) -> Double? { a > 0 ? b / a - 1 : nil }
        let comparable = issues.isEmpty
        var quotaPace: Double?, perPoint: Double?
        if comparable, let a = earlier.observedPointsPerDay, let b = later.observedPointsPerDay { quotaPace = change(a, b) }
        if comparable, earlier.efficiencyQuality == .reliable, later.efficiencyQuality == .reliable,
           let a = earlier.processedTokensPerPoint, let b = later.processedTokensPerPoint {
            perPoint = change(a.value, b.value)
        }
        return CycleComparison(
            earlier: earlier, later: later, issues: issues,
            processedChange: change(Double(earlier.processedTokens), Double(later.processedTokens)),
            freshChange: change(Double(earlier.freshTokens), Double(later.freshTokens)),
            costChange: change(earlier.costUSD, later.costUSD), quotaPaceChange: quotaPace, tokensPerPointChange: perPoint)
    }

    /// Half the L1 distance between two share vectors, from 0 for identical mixes to 1 for disjoint ones.
    public static func modelMixDistance(_ a: [String: Double], _ b: [String: Double]) -> Double {
        Set(a.keys).union(b.keys).reduce(0) { $0 + abs((a[$1] ?? 0) - (b[$1] ?? 0)) } / 2
    }

    /// The newest `count` cycles that have ended, optionally followed by the current one, oldest first.
    public static func recent(_ report: SubscriptionUsageReport, count: Int, includeCurrent: Bool = false) -> [CycleMetrics] {
        var cycles = report.cycles.filter { $0.timing == .past }
        cycles = Array(cycles.suffix(count))
        if includeCurrent, let current = report.currentCycle { cycles.append(current) }
        return cycles.map(CycleMetrics.init)
    }

    public static func summarize(_ cycles: [CycleMetrics]) -> PeriodSummary {
        let processed = cycles.reduce(Int64(0)) { $0 + $1.processedTokens }
        let fresh = cycles.reduce(Int64(0)) { $0 + $1.freshTokens }
        let maxima = cycles.compactMap(\.maximumPercent)
        let n = Double(max(cycles.count, 1))
        return PeriodSummary(
            cycles: cycles, totalProcessedTokens: processed, totalFreshTokens: fresh,
            meanProcessedPerCycle: Double(processed) / n, meanFreshPerCycle: Double(fresh) / n,
            cyclesReachingLimit: cycles.filter(\.reachedLimit).count,
            meanMaximumPercent: maxima.isEmpty ? nil : maxima.reduce(0, +) / Double(maxima.count),
            cyclesWithQuota: maxima.count, completeCycles: cycles.filter { $0.completeness == .complete }.count,
            totalCostUSD: cycles.reduce(0) { $0 + $1.costUSD })
    }

    /// The cycles of a report that fall in `range`, for a custom comparison.
    public static func cycles(in range: ClosedRange<Date>, of report: SubscriptionUsageReport) -> [CycleMetrics] {
        report.cycles.filter { $0.span.end > range.lowerBound && $0.span.start < range.upperBound && $0.timing != .future }
            .map(CycleMetrics.init)
    }
}
