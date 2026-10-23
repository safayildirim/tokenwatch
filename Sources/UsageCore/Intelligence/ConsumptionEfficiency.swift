import Foundation

/// Locally observed work in time order, with running totals so that the work between any two instants is one lookup.
///
/// Only the totals the efficiency calculation needs are kept, so a long history stays small.
public struct WorkTimeline: Sendable, Equatable {
    public struct Total: Sendable, Equatable {
        public var requests = 0
        public var processedTokens: Int64 = 0
        public var freshTokens: Int64 = 0
        public var costPicoUSD: Int64 = 0
        public var unpricedTokens: Int64 = 0
        public var cacheReadTokens: Int64 = 0
    }

    private var times: [Int64] = []
    private var cumulative: [Total] = []
    private var modelIndex: [UInt16] = []
    private var processedEach: [Int64] = []
    private var modelNames: [String] = []

    public init() {}

    public var isEmpty: Bool { times.isEmpty }

    /// Adds one request. Requests must be appended in time order.
    public mutating func append(at timeMs: Int64, processed: Int64, fresh: Int64, costPicoUSD: Int64, unpricedTokens: Int64,
                                cacheRead: Int64 = 0, model: String = "") {
        var total = cumulative.last ?? Total()
        total.requests += 1
        total.processedTokens += processed
        total.freshTokens += fresh
        total.costPicoUSD += costPicoUSD
        total.unpricedTokens += unpricedTokens
        total.cacheReadTokens += cacheRead
        times.append(timeMs)
        cumulative.append(total)
        let index: Int
        if let found = modelNames.firstIndex(of: model) { index = found } else { modelNames.append(model); index = modelNames.count - 1 }
        modelIndex.append(UInt16(min(index, Int(UInt16.max))))
        processedEach.append(processed)
    }

    /// The share of the processed tokens of `[from, to)` that each model carried.
    public func modelShares(from: Date, to: Date) -> [String: Double] {
        guard to > from else { return [:] }
        let lower = lowerBound(Clock.ms(from)), upper = lowerBound(Clock.ms(to))
        var sums: [Int: Int64] = [:]
        var total: Int64 = 0
        for i in lower..<max(lower, upper) {
            sums[Int(modelIndex[i]), default: 0] += processedEach[i]
            total += processedEach[i]
        }
        guard total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: sums.map { (modelNames[$0.key], Double($0.value) / Double(total)) })
    }

    private func lowerBound(_ ms: Int64) -> Int {
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < ms { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The work of the requests in `[from, to)`.
    public func total(from: Date, to: Date) -> Total {
        guard to > from else { return Total() }
        let a = prefix(before: Clock.ms(from)), b = prefix(before: Clock.ms(to))
        var out = Total()
        out.requests = b.requests - a.requests
        out.processedTokens = b.processedTokens - a.processedTokens
        out.freshTokens = b.freshTokens - a.freshTokens
        out.costPicoUSD = b.costPicoUSD - a.costPicoUSD
        out.unpricedTokens = b.unpricedTokens - a.unpricedTokens
        out.cacheReadTokens = b.cacheReadTokens - a.cacheReadTokens
        return out
    }

    /// The running total of the requests strictly before `ms`.
    private func prefix(before ms: Int64) -> Total {
        let low = lowerBound(ms)
        return low == 0 ? Total() : cumulative[low - 1]
    }
}

/// Thresholds that keep a ratio from being published when the evidence behind it is thin.
public struct EfficiencyPolicy: Sendable, Equatable {
    /// The smallest rise, in percentage points, from which any ratio is calculated. Provider percentages are rounded, so
    /// a rise of a few points can be off by a large fraction.
    public var minimumRisePoints = 5.0
    /// The rise from which a ratio is called reliable instead of indicative.
    public var reliableRisePoints = 10.0
    /// The fewest distinct rises inside the interval.
    public var minimumSteps = 2
    public var reliableSteps = 3
    /// The smallest amount of local work, in processed tokens, between the two readings.
    public var minimumProcessedTokens: Int64 = 1_000_000
    public var minimumSpan: TimeInterval = 30 * 60
    /// The step ratios are called widely spread when their interquartile range exceeds this multiple of their median.
    public var highSpreadRatio = 1.0
    /// The largest share of the local work between the two readings that may name no account. A larger share means that the work
    /// of the account is not what was measured.
    public var maximumUnattributedShare = 0.02

    public init() {}
}

public enum EfficiencyQuality: String, Sendable, Codable {
    /// A large rise over several steps with enough local work.
    case reliable
    /// A usable ratio from less evidence. It is shown with its range and is not used to compare cycles.
    case indicative
}

public enum EfficiencyUnavailableReason: String, Sendable, Codable {
    case noReadings
    case singleReading
    case riseTooSmall
    case tooFewSteps
    case tooLittleLocalWork
    case intervalTooShort
    case localActivityNotAttributed
    /// A plan period began or ended between the two readings, so the interval mixes two plans.
    case planChangedWithinInterval
    /// The cycle's readings overlap those of another window, so they cannot be told apart from another account's.
    case cycleOverlapsAnotherWindow
}

/// A fact that limits what an efficiency ratio means. They are shown next to the ratio, never hidden.
public enum EfficiencyCaveat: String, Sendable, Codable {
    /// The provider percentage covers the whole account, while local tokens cover only what this Mac observed.
    case accountWideQuotaVersusLocalTokens
    case planNotRecorded
    case planChangedDuringCycle
    case highStepVariability
    case roundedPercentages
    case costPartiallyUnpriced
    case scopedWindow
    /// Neither the readings nor the sessions name an account, so both are the unassigned activity and unassigned readings
    /// of this Mac, which can include more than one account.
    case neitherSideNamesAnAccount
    /// Part of the local activity was tied to this account by an association the user made, not by the sessions' own files.
    case activityAssociatedByUser
}

/// A measured ratio with the range that rounding of the provider's percentages allows.
public struct EfficiencyRange: Sendable, Equatable, Codable {
    public var value: Double
    public var low: Double
    public var high: Double
}

/// What local work was observed per percentage point of provider quota inside one cycle.
///
/// These are observed associations. They do not describe how the provider meters usage, and they do not predict that the
/// next amount of work will consume the same share. The workload mix, caching, other surfaces of the account and the
/// plan all change the relationship.
public struct CycleEfficiency: Sendable, Equatable {
    public var quality: EfficiencyQuality?
    public var unavailable: [EfficiencyUnavailableReason]
    public var caveats: [EfficiencyCaveat]
    /// The two instants at which the utilization was observed exactly, first at the end of the first value's
    /// confirmations and last at the first observation of the final value.
    public var from: Date?
    public var to: Date?
    public var risePoints: Double
    public var steps: Int
    public var requests: Int
    public var processedTokens: Int64
    public var freshTokens: Int64
    public var costUSD: Double
    public var cacheReadTokens: Int64 = 0
    /// The share of the interval's processed tokens that were cache reads, and the share of its processed tokens each model carried.
    /// They show what kind of work the ratio describes.
    public var cacheReadShare: Double?
    public var modelShares: [String: Double] = [:]
    public var processedTokensPerPoint: EfficiencyRange?
    public var cacheReadTokensPerPoint: EfficiencyRange?
    public var freshTokensPerPoint: EfficiencyRange?
    public var costUSDPerPoint: EfficiencyRange?
    public var pointsPerMillionProcessed: EfficiencyRange?
    public var pointsPerMillionFresh: EfficiencyRange?
    /// The median of the processed tokens per point of each single rise, and how widely those are spread.
    public var stepMedianProcessedPerPoint: Double?
    public var stepSpread: Double?

    public var isAvailable: Bool { quality != nil }

    public static func unavailable(_ reasons: [EfficiencyUnavailableReason], caveats: [EfficiencyCaveat] = []) -> CycleEfficiency {
        CycleEfficiency(quality: nil, unavailable: reasons, caveats: caveats, from: nil, to: nil, risePoints: 0, steps: 0,
                        requests: 0, processedTokens: 0, freshTokens: 0, costUSD: 0)
    }
}

public enum ConsumptionEfficiency {
    /// The smallest step between readings, capped at one point. It bounds how coarsely the provider rounds.
    public static func resolution(of curve: QuotaCurve) -> Double {
        let steps = zip(curve.points, curve.points.dropFirst()).map { $1.percent - $0.percent }.filter { $0 > 0 }
        let integral = curve.points.allSatisfy { $0.percent == $0.percent.rounded() }
        if integral { return 1 }
        return min(1, steps.min() ?? 1)
    }

    /// Compares the rise in `curve` with the work in `work` between the first and the last exactly observed value.
    ///
    /// The rise is measured from the last moment the first value was confirmed to the first moment the last value was
    /// seen. Both moments are observations, so the work between them is work that happened while the utilization rose by
    /// exactly that many points, apart from the rounding of the provider's percentages.
    public static func evaluate(curve: QuotaCurve, work: WorkTimeline, policy: EfficiencyPolicy = EfficiencyPolicy(),
                                caveats inherited: [EfficiencyCaveat] = []) -> CycleEfficiency {
        guard let first = curve.first, let last = curve.last else { return .unavailable([.noReadings], caveats: inherited) }
        guard curve.points.count >= 2 else { return .unavailable([.singleReading], caveats: inherited) }
        let from = first.lastConfirmedAt, to = last.firstObservedAt
        let rise = last.percent - first.percent
        let steps = curve.points.count - 1
        let total = work.total(from: from, to: to)
        let resolution = resolution(of: curve)

        var reasons: [EfficiencyUnavailableReason] = []
        if rise < policy.minimumRisePoints { reasons.append(.riseTooSmall) }
        if steps < policy.minimumSteps { reasons.append(.tooFewSteps) }
        if to.timeIntervalSince(from) < policy.minimumSpan { reasons.append(.intervalTooShort) }
        if total.processedTokens < policy.minimumProcessedTokens { reasons.append(.tooLittleLocalWork) }
        var caveats = inherited
        caveats.append(.accountWideQuotaVersusLocalTokens)
        caveats.append(.roundedPercentages)
        if total.unpricedTokens > 0 { caveats.append(.costPartiallyUnpriced) }
        guard reasons.isEmpty else { return .unavailable(reasons, caveats: caveats) }

        // Each single rise gives its own ratio. Their spread says whether the aggregate describes a steady relationship.
        var stepRatios: [Double] = []
        for (a, b) in zip(curve.points, curve.points.dropFirst()) {
            let delta = b.percent - a.percent
            guard delta >= 2 else { continue }
            let w = work.total(from: a.lastConfirmedAt, to: b.firstObservedAt)
            if w.processedTokens > 0 { stepRatios.append(Double(w.processedTokens) / delta) }
        }
        stepRatios.sort()
        let median = percentile(stepRatios, 0.5)
        var spread: Double?
        if stepRatios.count >= 3, let median, median > 0 {
            spread = (percentile(stepRatios, 0.75)! - percentile(stepRatios, 0.25)!) / median
            if spread! > policy.highSpreadRatio { caveats.append(.highStepVariability) }
        }

        let processed = Double(total.processedTokens), fresh = Double(total.freshTokens)
        let costUSD = Double(total.costPicoUSD) / 1e12
        func perPoint(_ amount: Double) -> EfficiencyRange {
            EfficiencyRange(value: amount / rise, low: amount / (rise + resolution), high: amount / (rise - resolution))
        }
        func pointsPerMillion(_ amount: Double) -> EfficiencyRange? {
            guard amount > 0 else { return nil }
            let millions = amount / 1e6
            return EfficiencyRange(value: rise / millions, low: (rise - resolution) / millions, high: (rise + resolution) / millions)
        }
        let reliable = rise >= policy.reliableRisePoints && steps >= policy.reliableSteps && !caveats.contains(.highStepVariability)
        let cacheRead = Double(total.cacheReadTokens)
        var result = CycleEfficiency(quality: reliable ? .reliable : .indicative, unavailable: [], caveats: caveats, from: from, to: to,
                               risePoints: rise, steps: steps, requests: total.requests,
                               processedTokens: total.processedTokens, freshTokens: total.freshTokens, costUSD: costUSD,
                               processedTokensPerPoint: perPoint(processed),
                               freshTokensPerPoint: fresh > 0 ? perPoint(fresh) : nil,
                               costUSDPerPoint: costUSD > 0 ? perPoint(costUSD) : nil,
                               pointsPerMillionProcessed: pointsPerMillion(processed),
                               pointsPerMillionFresh: pointsPerMillion(fresh),
                               stepMedianProcessedPerPoint: median, stepSpread: spread)
        result.cacheReadTokens = total.cacheReadTokens
        result.cacheReadTokensPerPoint = cacheRead > 0 ? perPoint(cacheRead) : nil
        result.cacheReadShare = total.processedTokens > 0 ? cacheRead / processed : nil
        result.modelShares = work.modelShares(from: from, to: to)
        return result
    }

    /// A percentile by linear interpolation between order statistics, for a sorted sample.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        if sorted.count == 1 { return sorted[0] }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
