import Foundation

/// Estimates relative subscription capacity from cycle-level, normalized quota observations.
///
/// ## What is measured
///
/// For one quota cycle and one plan:
///
///     rate = observed quota percentage points / API-equivalent USD of local work
///
/// A plan that consumes fewer percentage points for the same normalized work has more capacity:
///
///     capacity(other) / capacity(base) = rate(base) / rate(other)
///
/// With matched work, this reduces to `delta(base) / delta(other)`. A workload that consumes 20%
/// of one plan and 10% of another therefore yields 2.0, never 0.5.
///
/// ## Why cycles, not readings
///
/// Several readings inside one cycle are not independent observations. They are summed into a
/// single cycle sample first. Pairing is one-to-one, so the estimator never pretends that twenty
/// readings in one afternoon are twenty experiments.
///
/// ## What this is not
///
/// The result is an estimate of *relative marginal* consumption under the observed workload. It is
/// not the provider's internal allowance, not an absolute token limit, and not proof of a policy.
/// The estimator refuses to publish a ratio when the evidence policy is not met.
public enum CapacityEstimator {
    public static func estimate(basePlanKey: String, otherPlanKey: String, windowKey: String, windowMinutes: Int?,
                                samples: [CapacitySample], exclusions: [CapacityExclusion: Int],
                                policy: CapacityEstimationPolicy = CapacityEstimationPolicy()) -> CapacityEstimate {
        var exclusions = exclusions
        let baseAll = samples.filter { $0.planKey == basePlanKey && $0.windowKey == windowKey }
        let otherAll = samples.filter { $0.planKey == otherPlanKey && $0.windowKey == windowKey }

        // A cycle with too little work is noise, not evidence. Apply this before the outlier rule so
        // a tiny cycle cannot influence the median that decides which real cycles are outliers.
        let minWork = policy.minimumCycleWorkPicoUSD
        let smallBase = baseAll.filter { $0.workload.cost.picoUSD < minWork }
        let smallOther = otherAll.filter { $0.workload.cost.picoUSD < minWork }
        if !smallBase.isEmpty || !smallOther.isEmpty {
            exclusions[.workloadTooSmall, default: 0] += smallBase.count + smallOther.count
        }
        let (base, baseOutlierIDs) = filteredOutliers(baseAll.filter { $0.workload.cost.picoUSD >= minWork }, policy: policy)
        let (other, otherOutlierIDs) = filteredOutliers(otherAll.filter { $0.workload.cost.picoUSD >= minWork }, policy: policy)
        let outlierIDs = (baseOutlierIDs + otherOutlierIDs).sorted()
        exclusions[.outlierConsumption, default: 0] += outlierIDs.count

        let comparability = compare(base, other)
        let dateRange = dateRange(base, other)
        let baseIntervals = base.reduce(0) { $0 + $1.intervalCount }
        let otherIntervals = other.reduce(0) { $0 + $1.intervalCount }

        func result(ratio: Double?, provisional: Double?, level: CapacityEvidenceLevel,
                    method: CapacityEstimationMethod?, pairs: Int, sensitivity: ClosedRange<Double>?,
                    pooled: Double?) -> CapacityEstimate {
            CapacityEstimate(basePlanKey: basePlanKey, otherPlanKey: otherPlanKey, windowKey: windowKey,
                             windowMinutes: windowMinutes, ratio: ratio, provisionalRatio: provisional,
                             level: level, method: method, matchedPairs: pairs, baseCycles: base.count,
                             otherCycles: other.count, baseIntervals: baseIntervals, otherIntervals: otherIntervals,
                             dateRange: dateRange, sensitivityRange: sensitivity, pooledRatio: pooled,
                             comparability: comparability, exclusions: exclusions,
                             outlierCycleIDs: outlierIDs)
        }

        guard !base.isEmpty, !other.isEmpty else {
            return result(ratio: nil, provisional: nil, level: .insufficient, method: nil, pairs: 0,
                          sensitivity: nil, pooled: nil)
        }
        guard base.count >= policy.minimumCyclesPerPlan, other.count >= policy.minimumCyclesPerPlan else {
            // One cycle per plan may already contain a useful, clearly provisional comparison. It is
            // not published as an estimate and can never drive a purchase recommendation.
            let preliminaryPairs = matchedPairDetails(base, other, policy: policy)
            let provisional = median(preliminaryPairs.compactMap { ratio(base: $0.base, other: $0.other) })
            return result(ratio: nil, provisional: provisional, level: .insufficient, method: nil,
                          pairs: preliminaryPairs.count, sensitivity: nil, pooled: nil)
        }

        let pairs = matchedPairs(base, other, policy: policy)
        let pairRatios: [Double] = pairs.compactMap { ratio(base: $0.0, other: $0.1) }
        let pooled = pooledRatio(base, other)
        let pooledCompositionOK = pooledIsComparable(base, other, policy: policy)

        var publishedRatio: Double?
        var method: CapacityEstimationMethod?
        var sensitivityValues: [Double] = pairRatios

        if pairs.count >= policy.minimumMatchedPairs, let medianRatio = median(pairRatios) {
            publishedRatio = medianRatio
            method = .matchedCycles
            if pooledCompositionOK, let pooled { sensitivityValues.append(pooled) }
        } else if pooledCompositionOK, let pooled {
            // Not enough one-to-one matched pairs, but the pooled workload distributions are similar.
            publishedRatio = pooled
            method = .pooledStandardizedWork
            sensitivityValues = [pooled]
        } else if let medianRatio = median(pairRatios) {
            return result(ratio: nil, provisional: medianRatio, level: .insufficient, method: nil,
                          pairs: pairs.count, sensitivity: nil, pooled: pooled)
        }

        guard let publishedRatio else {
            return result(ratio: nil, provisional: nil, level: .insufficient, method: nil,
                          pairs: pairs.count, sensitivity: nil, pooled: pooled)
        }

        let sensitivity: ClosedRange<Double>? = sensitivityValues.count >= 2
            ? (sensitivityValues.min()!...sensitivityValues.max()!) : nil

        let level = evidenceLevel(base: base, other: other, pairs: pairs.count, ratio: publishedRatio,
                                  pooled: pooledCompositionOK ? pooled : nil, dateRange: dateRange, policy: policy)

        return result(ratio: publishedRatio, provisional: nil, level: level, method: method, pairs: pairs.count,
                      sensitivity: sensitivity, pooled: pooled)
    }

    // MARK: Cycle rates

    static func rate(_ sample: CapacitySample) -> Double? {
        let cost = sample.workload.estimatedCostUSD
        guard cost > 0, sample.deltaPercent > 0 else { return nil }
        return sample.deltaPercent / cost
    }

    static func ratio(base: CapacitySample, other: CapacitySample) -> Double? {
        guard let baseRate = rate(base), let otherRate = rate(other), otherRate > 0 else { return nil }
        return baseRate / otherRate
    }

    static func pooledRatio(_ base: [CapacitySample], _ other: [CapacitySample]) -> Double? {
        let baseDelta = base.reduce(0.0) { $0 + $1.deltaPercent }
        let baseWork = base.reduce(0.0) { $0 + $1.workload.estimatedCostUSD }
        let otherDelta = other.reduce(0.0) { $0 + $1.deltaPercent }
        let otherWork = other.reduce(0.0) { $0 + $1.workload.estimatedCostUSD }
        guard baseWork > 0, otherWork > 0, otherDelta > 0 else { return nil }
        return (baseDelta / baseWork) / (otherDelta / otherWork)
    }

    // MARK: Matching

    struct Pair {
        var base: CapacitySample
        var other: CapacitySample
        var distance: Double
    }

    static func matchedPairs(_ base: [CapacitySample], _ other: [CapacitySample],
                             policy: CapacityEstimationPolicy) -> [(CapacitySample, CapacitySample)] {
        matchedPairDetails(base, other, policy: policy).map { ($0.base, $0.other) }
    }

    static func matchedPairDetails(_ base: [CapacitySample], _ other: [CapacitySample],
                                   policy: CapacityEstimationPolicy) -> [Pair] {
        var candidates: [Pair] = []
        for a in base {
            for b in other {
                guard let distance = compatibilityDistance(a, b, policy: policy) else { continue }
                candidates.append(Pair(base: a, other: b, distance: distance))
            }
        }
        candidates.sort { ($0.distance, $0.base.id, $0.other.id) < ($1.distance, $1.base.id, $1.other.id) }
        var usedBase = Set<String>()
        var usedOther = Set<String>()
        var chosen: [Pair] = []
        for candidate in candidates {
            guard !usedBase.contains(candidate.base.id), !usedOther.contains(candidate.other.id) else { continue }
            usedBase.insert(candidate.base.id)
            usedOther.insert(candidate.other.id)
            chosen.append(candidate)
        }
        return chosen
    }

    /// Zero means identical composition. Nil means the workload is not comparable at all.
    static func compatibilityDistance(_ base: CapacitySample, _ other: CapacitySample,
                                      policy: CapacityEstimationPolicy) -> Double? {
        guard let cosine = modelCosine(base.workload, other.workload),
              cosine >= policy.minimumModelCosineSimilarity,
              let baseCache = base.workload.cacheReadShare,
              let otherCache = other.workload.cacheReadShare,
              abs(baseCache - otherCache) <= policy.maximumCacheShareDifference,
              let baseOutput = base.workload.outputShare,
              let otherOutput = other.workload.outputShare,
              abs(baseOutput - otherOutput) <= policy.maximumOutputShareDifference,
              let _ = rate(base), let _ = rate(other)
        else { return nil }
        let cacheDistance = abs(baseCache - otherCache) / max(0.0001, policy.maximumCacheShareDifference)
        let outputDistance = abs(baseOutput - otherOutput) / max(0.0001, policy.maximumOutputShareDifference)
        let costBase = max(1, base.workload.cost.picoUSD)
        let costOther = max(1, other.workload.cost.picoUSD)
        let sizeDistance = abs(log(Double(costBase) / Double(costOther))) * 0.02
        return (1 - cosine) + cacheDistance * 0.5 + outputDistance * 0.5 + sizeDistance
    }

    static func modelCosine(_ a: CapacityWorkload, _ b: CapacityWorkload) -> Double? {
        let x = a.modelShares()
        let y = b.modelShares()
        guard !x.isEmpty, !y.isEmpty else { return nil }
        let dot = x.reduce(0.0) { $0 + $1.value * (y[$1.key] ?? 0) }
        let nx = sqrt(x.values.reduce(0.0) { $0 + $1 * $1 })
        let ny = sqrt(y.values.reduce(0.0) { $0 + $1 * $1 })
        guard nx > 0, ny > 0 else { return nil }
        return dot / (nx * ny)
    }

    static func pooledIsComparable(_ base: [CapacitySample], _ other: [CapacitySample],
                                   policy: CapacityEstimationPolicy) -> Bool {
        let a = mergedWorkload(base)
        let b = mergedWorkload(other)
        guard let cosine = modelCosine(a, b), cosine >= policy.pooledMinimumModelCosineSimilarity,
              let ac = a.cacheReadShare, let bc = b.cacheReadShare,
              abs(ac - bc) <= policy.maximumCacheShareDifference,
              let ao = a.outputShare, let bo = b.outputShare,
              abs(ao - bo) <= policy.maximumOutputShareDifference
        else { return false }
        return true
    }

    static func mergedWorkload(_ samples: [CapacitySample]) -> CapacityWorkload {
        samples.reduce(CapacityWorkload()) { $0.merged(with: $1.workload) }
    }

    // MARK: Evidence and outliers

    static func filteredOutliers(_ samples: [CapacitySample],
                                 policy: CapacityEstimationPolicy) -> ([CapacitySample], [Int64]) {
        guard samples.count >= 5 else { return (samples, []) }
        let rates = samples.compactMap(rate).sorted()
        guard rates.count == samples.count, rates.count >= 5 else { return (samples, []) }
        let center = median(rates) ?? 0
        guard center > 0 else { return (samples, []) }
        let kept = samples.filter {
            guard let r = rate($0) else { return false }
            return r >= center / policy.outlierRateMultiple && r <= center * policy.outlierRateMultiple
        }
        // Never let the outlier rule reduce a plan below the minimum evidence it already had.
        guard kept.count >= policy.minimumCyclesPerPlan else { return (samples, []) }
        let keptIDs = Set(kept.map(\.id))
        return (kept, samples.filter { !keptIDs.contains($0.id) }.map(\.cycleID))
    }

    static func evidenceLevel(base: [CapacitySample], other: [CapacitySample], pairs: Int, ratio: Double,
                              pooled: Double?, dateRange: ClosedRange<Date>?, policy: CapacityEstimationPolicy) -> CapacityEvidenceLevel {
        if base.count >= policy.strongCycles, other.count >= policy.strongCycles,
           pairs >= policy.strongPairs,
           let dateRange,
           dateRange.upperBound.timeIntervalSince(dateRange.lowerBound) >= policy.strongSpanDays * 86_400 {
            if let pooled {
                let disagreement = abs(pooled - ratio) / max(0.0001, ratio)
                if disagreement <= 0.25 { return .strong }
            }
        }
        if base.count >= policy.moderateCycles, other.count >= policy.moderateCycles,
           pairs >= policy.moderatePairs { return .moderate }
        return .limited
    }

    static func compare(_ base: [CapacitySample], _ other: [CapacitySample]) -> CapacityComparability {
        let a = mergedWorkload(base)
        let b = mergedWorkload(other)
        return CapacityComparability(
            modelCosineSimilarity: modelCosine(a, b),
            cacheReadShareBase: a.cacheReadShare, cacheReadShareOther: b.cacheReadShare,
            outputShareBase: a.outputShare, outputShareOther: b.outputShare,
            requestsBase: a.requests, requestsOther: b.requests,
            workUSDBase: a.estimatedCostUSD, workUSDOther: b.estimatedCostUSD)
    }

    static func dateRange(_ base: [CapacitySample], _ other: [CapacitySample]) -> ClosedRange<Date>? {
        let all = base + other
        guard let start = all.map(\.from).min(), let end = all.map(\.to).max(), start <= end else { return nil }
        return start...end
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
