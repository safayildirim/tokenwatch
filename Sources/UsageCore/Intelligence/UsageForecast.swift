import Foundation

/// The ways of predicting the utilization a cycle will have when it resets.
///
/// All of them use only the provider-reported utilization history. Local token counts are not an input, because they
/// describe one Mac while the utilization describes the account.
///
/// Two further methods, the median final utilization of earlier cycles and the median of all the methods, were removed. On the
/// synthetic histories of the tests neither beat the same-stage increment, which contains the same information, by more than
/// the rounding of the provider's whole percentages, so they only added ways to overfit a short history.
public enum ForecastMethod: String, CaseIterable, Sendable, Codable {
    /// The pace over the whole cycle so far, applied to the time that is left.
    case cycleAveragePace
    /// The pace over the most recent part of the cycle, applied to the time that is left.
    case recentPace
    /// The current utilization plus the median rise that earlier cycles made after the same point of their cycle.
    case sameStageIncrement

    /// Simpler methods come first. When two methods perform about equally, the simpler one is chosen.
    var simplicityRank: Int {
        switch self {
        case .cycleAveragePace: 0
        case .recentPace: 1
        case .sameStageIncrement: 2
        }
    }
}

public struct ForecastPolicy: Sendable, Equatable {
    /// The points of a cycle, as fractions of its length, at which a backtest pretends to forecast.
    public var checkpoints: [Double] = [0.25, 0.5, 0.75]
    /// The part of the cycle that the recent pace looks back over.
    public var lookbackFraction = 0.25
    /// The shortest stretch that a pace may be measured over, as a fraction of the cycle.
    public var minimumLookbackFraction = 0.05
    /// A reading older than this fraction of the cycle is too old to forecast from.
    public var stalenessFraction = 0.1
    public var minimumStaleness: TimeInterval = 30 * 60
    public var maximumStaleness: TimeInterval = 24 * 3600
    /// The fewest earlier cycles that the history-based methods need.
    public var minimumHistoryCycles = 3
    /// The most earlier cycles used, newest first.
    public var maximumHistoryCycles = 12
    /// A forecast is shown only when the way it is made was checked on at least this many forecasts from at least this many cycles
    /// whose outcome was not used to choose the method.
    public var minimumHeldOutCases = 8
    public var minimumHeldOutCycles = 4
    /// Only the newest held-out cycles are scored. The first forecasts are made before the choice of method has anything to learn
    /// from, and an old regime of use should not decide whether the current one can be forecast.
    public var heldOutWindowCycles = 6
    /// Choosing a method needs at least this many earlier cycles with results. With fewer, the default method is used.
    public var minimumSelectionCycles = 2
    public var defaultMethod = ForecastMethod.cycleAveragePace
    /// The largest typical error, in percentage points, of forecasts that were checked on held-out cycles.
    public var maximumAcceptableError = 12.0
    /// The typical held-out error must be at most this fraction of the error of assuming that no more would be used. A forecast
    /// that does not beat that assumption by a margin has no skill.
    public var requiredSkill = 0.75
    /// With fewer held-out errors than this, the range is their full spread, because a 10th and 90th percentile of a handful of numbers
    /// is little more than the extremes with false precision on top. With at least this many, it is the middle 80%.
    public var fullSpreadBelowCases = 20
    /// A forecast range is never narrower than this many points on each side, because the provider reports whole percentages.
    public var rangeFloorPoints = 1.0
    /// The range of a forecast spans these quantiles of the method's past errors.
    public var lowerQuantile = 0.10
    public var upperQuantile = 0.90
    /// A simpler method is preferred when its mean error is within this factor of the best one's.
    public var simplicityTolerance = 1.05
    /// Differences in mean error below this many percentage points are not told apart, because the provider reports
    /// whole percentages and rounding alone causes errors of this size.
    public var negligibleErrorPoints = 0.5
    /// A change of model mix above this half-distance between share vectors is reported as a warning.
    public var modelMixDriftThreshold = 0.30

    public init() {}

    func staleness(cycleLength: TimeInterval) -> TimeInterval {
        min(max(cycleLength * stalenessFraction, minimumStaleness), maximumStaleness)
    }
}

/// A completed cycle as the forecast sees it.
public struct ForecastCycle: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var curve: QuotaCurve
    /// The utilization at the end of the cycle, known only when the end was observed or the limit was reached.
    public var finalPercent: Double?
    public var planKey: String?

    public init(start: Date, end: Date, curve: QuotaCurve, finalPercent: Double?, planKey: String? = nil) {
        self.start = start
        self.end = end
        self.curve = curve
        self.finalPercent = finalPercent
        self.planKey = planKey
    }

    var length: TimeInterval { end.timeIntervalSince(start) }
}

/// How one method performed when it forecast cycles whose outcome is known.
public struct ForecastMethodScore: Sendable, Equatable, Codable {
    public var method: ForecastMethod
    public var cases: Int
    public var cycles: Int
    /// The mean absolute error, in percentage points.
    public var meanAbsoluteError: Double
    public var rootMeanSquareError: Double
    /// The mean of actual minus predicted. A positive value means the method tends to underestimate.
    public var bias: Double
}

/// A forecast that was made from the information available at its time and then compared with what happened.
public struct ForecastBacktestCase: Sendable, Equatable {
    public var cycleIndex: Int
    public var checkpoint: Double
    public var method: ForecastMethod
    public var predicted: Double
    public var actual: Double
    /// The utilization at the checkpoint, which is what "no more use from now on" would have predicted.
    public var current: Double
    public var residual: Double { actual - predicted }
}

/// A forecast made with a method that was chosen using only cycles that ended before it, then compared with what happened.
///
/// Choosing the best of several methods on the same cycles that the error is reported on makes the error look better than it is.
/// These cases keep the choice and the check apart.
public struct HeldOutForecast: Sendable, Equatable {
    public var cycleIndex: Int
    public var checkpoint: Double
    public var method: ForecastMethod
    public var predicted: Double
    public var actual: Double
    public var current: Double
    public var residual: Double { actual - predicted }
}

public struct HeldOutScore: Sendable, Equatable {
    public var cases: Int
    public var cycles: Int
    public var meanAbsoluteError: Double
    public var bias: Double
    /// The mean absolute error of assuming that nothing more would be used after the checkpoint.
    public var noGrowthMeanAbsoluteError: Double
    /// The 10th and 90th percentile of the held-out errors, which become the forecast range.
    public var lowResidual: Double
    public var highResidual: Double
}

/// Whether the way of forecasting has earned the right to produce a number.
public enum ForecastQualification: Sendable, Equatable {
    case qualified
    case tooFewCycles(have: Int, need: Int)
    case errorTooLarge(error: Double, limit: Double)
    case noBetterThanNoGrowth(error: Double, noGrowthError: Double)
}

public struct ForecastEvaluation: Sendable, Equatable {
    /// The in-sample scores of every method on all cases. They describe the methods, and they are optimistic for the one that was
    /// picked because it scored best.
    public var scores: [ForecastMethodScore]
    public var cases: [ForecastBacktestCase]
    public var evaluatedCycles: Int
    /// The method with the best error among those with enough cases, or the default method when none has.
    public var selected: ForecastMethod
    public var heldOut: [HeldOutForecast]
    public var heldOutScore: HeldOutScore?
    public var qualification: ForecastQualification
    /// How often the actual outcome fell inside the range that earlier held-out cases alone would have given.
    public var rollingCoverage: (hits: Int, total: Int)?

    public static func == (a: ForecastEvaluation, b: ForecastEvaluation) -> Bool {
        a.scores == b.scores && a.cases == b.cases && a.evaluatedCycles == b.evaluatedCycles && a.selected == b.selected
            && a.heldOut == b.heldOut && a.heldOutScore == b.heldOutScore && a.qualification == b.qualification
            && a.rollingCoverage?.hits == b.rollingCoverage?.hits && a.rollingCoverage?.total == b.rollingCoverage?.total
    }

    public func score(of method: ForecastMethod) -> ForecastMethodScore? { scores.first { $0.method == method } }
}

public enum ForecastUnavailableReason: Sendable, Equatable {
    case noCurrentCycle
    case noReadings
    case tooFewReadings
    case readingsStale(age: TimeInterval)
    case cycleEnded
    /// The plan changed during this cycle, so the pace so far and the history describe different allowances.
    case planChangedDuringCycle
    case notEnoughCompletedCycles(have: Int, need: Int)
    /// The way of forecasting made errors that are too large on cycles whose outcome it had not seen.
    case errorTooLarge(error: Double, limit: Double)
    /// The way of forecasting did no better, on held-out cycles, than assuming that no more would be used.
    case noBetterThanNoGrowth(error: Double, noGrowthError: Double)
}

public enum ForecastWarning: String, Sendable, Codable {
    /// The plan of the current cycle differs from the plan of some earlier cycles, which were left out.
    case earlierCyclesOnAnotherPlanExcluded
    case planNotRecorded
    /// The mix of models in this cycle differs a lot from earlier cycles.
    case modelMixChanged
    /// Some earlier cycles reached the limit, so they may understate how much work was wanted.
    case earlierCyclesLimitBound
    /// The account's other surfaces can consume the same allowance without being observed.
    case unobservedActivityPossible
}

/// The time at which the allowance may run out, if the pace holds.
public struct ExhaustionEstimate: Sendable, Equatable {
    public enum Confidence: String, Sendable, Codable {
        /// Even the low end of the forecast range reaches the limit.
        case likely
        /// Only the high end of the forecast range reaches the limit.
        case possible
    }

    public var confidence: Confidence
    public var earliest: Date
    /// The latest time, or nil when only the high end of the range exhausts the allowance before the reset.
    public var latest: Date?
}

/// How much more comparable work the rest of the allowance may hold, from the observed ratio of earlier cycles.
public struct RemainingWorkEstimate: Sendable, Equatable {
    public var remainingPoints: Double
    public var processedTokens: EfficiencyRange
    public var freshTokens: EfficiencyRange?
    public var costUSD: EfficiencyRange?
    /// The cycles whose ratios were used.
    public var basedOnCycles: Int
}

public struct ForecastEvidence: Sendable, Equatable {
    public var historyCycles: Int
    /// The forecasts whose method was chosen without their own outcome, and how many cycles they come from.
    public var heldOutCases: Int
    public var heldOutCycles: Int
    public var meanAbsoluteError: Double?
    public var noGrowthMeanAbsoluteError: Double?
    public var bias: Double?
    public var rollingCoverage: (hits: Int, total: Int)?

    public static func == (a: ForecastEvidence, b: ForecastEvidence) -> Bool {
        a.historyCycles == b.historyCycles && a.heldOutCases == b.heldOutCases && a.heldOutCycles == b.heldOutCycles
            && a.meanAbsoluteError == b.meanAbsoluteError && a.noGrowthMeanAbsoluteError == b.noGrowthMeanAbsoluteError
            && a.bias == b.bias && a.rollingCoverage?.hits == b.rollingCoverage?.hits && a.rollingCoverage?.total == b.rollingCoverage?.total
    }
}

/// The outlook for the utilization of the current cycle.
public struct UsageForecast: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        case forecast
        /// The utilization already stands at the limit, so there is nothing left to forecast.
        case limitReached
        case unavailable([ForecastUnavailableReason])
    }

    public var availability: Availability
    /// The time of the last observation the forecast starts from.
    public var asOf: Date?
    public var currentPercent: Double?
    public var cycleEnd: Date?
    public var method: ForecastMethod?
    /// The expected utilization at the reset, limited to the limit.
    public var point: Double?
    public var low: Double?
    public var high: Double?
    public var exhaustion: ExhaustionEstimate?
    public var remainingWork: RemainingWorkEstimate?
    /// The utilization gained per day so far in the cycle. It is an observation, not a prediction.
    public var observedPacePointsPerDay: Double?
    public var evidence: ForecastEvidence
    public var evaluation: ForecastEvaluation
    public var warnings: [ForecastWarning]

    public var isAvailable: Bool { availability == .forecast }
}

public enum UsageForecastEngine {
    // MARK: Prediction

    /// The prediction of one method for the cycle that `curve` describes, from the information in `curve` and `history`.
    ///
    /// The result is not limited to the ceiling, so that a pace which would overshoot the limit can be seen as such.
    static func predict(_ method: ForecastMethod, curve: QuotaCurve, start: Date, end: Date, history: [ForecastCycle],
                        policy: ForecastPolicy) -> Double? {
        guard let last = curve.last else { return nil }
        let t0 = last.lastConfirmedAt, u0 = last.percent
        let length = end.timeIntervalSince(start)
        let remaining = end.timeIntervalSince(t0)
        guard length > 0, remaining > 0 else { return nil }
        let minimumLookback = policy.minimumLookbackFraction * length

        switch method {
        case .cycleAveragePace:
            let elapsed = t0.timeIntervalSince(start)
            guard elapsed >= minimumLookback else { return nil }
            return u0 + u0 / elapsed * remaining
        case .recentPace:
            let target = t0.addingTimeInterval(-policy.lookbackFraction * length)
            var anchorTime = start, anchorPercent = 0.0
            if let anchor = curve.points.last(where: { $0.lastConfirmedAt <= target }) {
                anchorTime = anchor.lastConfirmedAt
                anchorPercent = anchor.percent
            }
            let span = t0.timeIntervalSince(anchorTime)
            guard span >= minimumLookback else { return nil }
            return u0 + (u0 - anchorPercent) / span * remaining
        case .sameStageIncrement:
            let stage = t0.timeIntervalSince(start) / length
            var increments: [Double] = []
            for cycle in history {
                guard let final = cycle.finalPercent,
                      let bounds = cycle.curve.bounds(at: cycle.start.addingTimeInterval(stage * cycle.length)),
                      bounds.basis == .exact || bounds.basis == .bracketed, bounds.upper - bounds.lower <= 3 else { continue }
                increments.append(max(0, final - (bounds.lower + bounds.upper) / 2))
            }
            guard increments.count >= policy.minimumHistoryCycles else { return nil }
            return u0 + ConsumptionEfficiency.percentile(increments.sorted(), 0.5)!
        }
    }

    /// Whether the last reading of `curve` is recent enough, at time `date`, to forecast from.
    static func isFresh(_ curve: QuotaCurve, length: TimeInterval, at date: Date, policy: ForecastPolicy) -> Bool {
        guard let last = curve.last else { return false }
        return date.timeIntervalSince(last.lastConfirmedAt) <= policy.staleness(cycleLength: length)
    }

    // MARK: Backtest

    /// Forecasts every cycle with a known outcome from the information that existed at each checkpoint, scores the methods, and then
    /// checks the way of choosing a method on cycles whose outcome it had not seen.
    ///
    /// The history that a forecast may use contains only cycles that ended before the forecast cycle began, and the forecast cycle's own
    /// curve is cut at the checkpoint, so no later information leaks into an earlier forecast. The choice of method is replayed in
    /// time order as well: for each cycle it is made from the cases of earlier cycles only, so the reported error includes the cost
    /// of choosing.
    public static func backtest(cycles: [ForecastCycle], policy: ForecastPolicy = ForecastPolicy()) -> ForecastEvaluation {
        let ordered = cycles.sorted { $0.start < $1.start }
        var cases: [ForecastBacktestCase] = []
        var evaluated = Set<Int>()
        for (index, target) in ordered.enumerated() {
            guard let actual = target.finalPercent else { continue }
            let history = ordered[..<index].filter { $0.end <= target.start && $0.planKey == target.planKey && $0.finalPercent != nil }
                .suffix(policy.maximumHistoryCycles).map { $0 }
            for checkpoint in policy.checkpoints {
                let at = target.start.addingTimeInterval(checkpoint * target.length)
                let curve = target.curve.truncated(at: at)
                guard curve.points.count >= 2, isFresh(curve, length: target.length, at: at, policy: policy),
                      let floor = curve.last?.percent else { continue }
                for method in ForecastMethod.allCases {
                    guard let raw = predict(method, curve: curve, start: target.start, end: target.end, history: history, policy: policy)
                    else { continue }
                    let predicted = min(max(raw, floor), target.curve.ceiling)
                    cases.append(ForecastBacktestCase(cycleIndex: index, checkpoint: checkpoint, method: method, predicted: predicted,
                                                      actual: actual, current: floor))
                    evaluated.insert(index)
                }
            }
        }

        let scores = scores(of: cases)
        let selected = choose(from: scores, cases: cases, policy: policy)

        // Replay the choice in time order. For each cycle the method comes from earlier cycles only.
        var heldOut: [HeldOutForecast] = []
        for index in Set(cases.map(\.cycleIndex)).sorted() {
            let earlier = cases.filter { $0.cycleIndex < index }
            let method = choose(from: Self.scores(of: earlier), cases: earlier, policy: policy)
            for case_ in cases where case_.cycleIndex == index && case_.method == method {
                heldOut.append(HeldOutForecast(cycleIndex: index, checkpoint: case_.checkpoint, method: method, predicted: case_.predicted,
                                               actual: case_.actual, current: case_.current))
            }
        }

        var score: HeldOutScore?
        var qualification = ForecastQualification.tooFewCycles(have: 0, need: policy.minimumHeldOutCycles)
        let recentCycles = Set(Set(heldOut.map(\.cycleIndex)).sorted().suffix(policy.heldOutWindowCycles))
        let recent = heldOut.filter { recentCycles.contains($0.cycleIndex) }
        if !recent.isEmpty {
            let n = Double(recent.count)
            let residuals = recent.map(\.residual).sorted()
            let heldOutCycles = recentCycles.count
            let mae = recent.reduce(0) { $0 + abs($1.residual) } / n
            let naive = recent.reduce(0) { $0 + abs($1.actual - $1.current) } / n
            score = HeldOutScore(cases: recent.count, cycles: heldOutCycles, meanAbsoluteError: mae,
                                 bias: recent.reduce(0) { $0 + $1.residual } / n, noGrowthMeanAbsoluteError: naive,
                                 lowResidual: residualRange(residuals, policy).low, highResidual: residualRange(residuals, policy).high)
            if recent.count < policy.minimumHeldOutCases || heldOutCycles < policy.minimumHeldOutCycles {
                qualification = .tooFewCycles(have: heldOutCycles, need: policy.minimumHeldOutCycles)
            } else if mae > policy.maximumAcceptableError {
                qualification = .errorTooLarge(error: mae, limit: policy.maximumAcceptableError)
            } else if mae > policy.requiredSkill * naive {
                qualification = .noBetterThanNoGrowth(error: mae, noGrowthError: naive)
            } else {
                qualification = .qualified
            }
        }
        return ForecastEvaluation(scores: scores, cases: cases, evaluatedCycles: evaluated.count, selected: selected, heldOut: heldOut,
                                  heldOutScore: score, qualification: qualification,
                                  rollingCoverage: rollingCoverage(heldOut: heldOut, policy: policy))
    }

    /// The range that the held-out errors give: all of them when there are few, the middle 80% when there are many.
    static func residualRange(_ sorted: [Double], _ policy: ForecastPolicy) -> (low: Double, high: Double) {
        guard let first = sorted.first, let last = sorted.last else { return (0, 0) }
        if sorted.count < policy.fullSpreadBelowCases { return (first, last) }
        return (ConsumptionEfficiency.percentile(sorted, policy.lowerQuantile) ?? first, ConsumptionEfficiency.percentile(sorted, policy.upperQuantile) ?? last)
    }

    private static func scores(of cases: [ForecastBacktestCase]) -> [ForecastMethodScore] {
        var out: [ForecastMethodScore] = []
        for method in ForecastMethod.allCases {
            let own = cases.filter { $0.method == method }
            guard !own.isEmpty else { continue }
            let n = Double(own.count)
            out.append(ForecastMethodScore(
                method: method, cases: own.count, cycles: Set(own.map(\.cycleIndex)).count,
                meanAbsoluteError: own.reduce(0) { $0 + abs($1.residual) } / n,
                rootMeanSquareError: (own.reduce(0) { $0 + $1.residual * $1.residual } / n).squareRoot(),
                bias: own.reduce(0) { $0 + $1.residual } / n))
        }
        return out
    }

    /// The method with the lowest error among those checked on enough cycles, preferring the simplest of those that are about as good.
    /// Without enough earlier cycles the default method is used, because a choice made on one or two cycles is noise.
    private static func choose(from scores: [ForecastMethodScore], cases: [ForecastBacktestCase], policy: ForecastPolicy) -> ForecastMethod {
        let eligible = scores.filter { $0.cycles >= policy.minimumSelectionCycles }
        guard let best = eligible.map(\.meanAbsoluteError).min() else { return policy.defaultMethod }
        let threshold = max(best * policy.simplicityTolerance, best + policy.negligibleErrorPoints)
        return eligible.filter { $0.meanAbsoluteError <= threshold + 1e-9 }
            .min { $0.method.simplicityRank < $1.method.simplicityRank }?.method ?? policy.defaultMethod
    }

    /// Replays the held-out forecasts in time order and counts how often the outcome fell inside the range that only earlier
    /// held-out errors would have produced.
    private static func rollingCoverage(heldOut: [HeldOutForecast], policy: ForecastPolicy) -> (hits: Int, total: Int)? {
        let ordered = heldOut.sorted { ($0.cycleIndex, $0.checkpoint) < ($1.cycleIndex, $1.checkpoint) }
        var hits = 0, total = 0
        for case_ in ordered {
            let earlier = ordered.filter { $0.cycleIndex < case_.cycleIndex }.map(\.residual).sorted()
            guard earlier.count >= policy.minimumHeldOutCases else { continue }
            let (low, high) = residualRange(earlier, policy)
            total += 1
            if case_.residual >= low && case_.residual <= high { hits += 1 }
        }
        return total > 0 ? (hits, total) : nil
    }

    // MARK: Forecast

    public static func forecast(for report: SubscriptionUsageReport, now: Date = Date(),
                                policy: ForecastPolicy = ForecastPolicy()) -> UsageForecast {
        // Only cycles that ended at their announced reset and whose readings belong to one account can say how a cycle ends.
        let past = report.cycles.filter {
            $0.timing == .past && $0.span.origin == .observed && !$0.span.endedEarly && !$0.span.overlapsAnotherWindow && !$0.quotaIdentityAmbiguous
        }
        let completed: [ForecastCycle] = past.compactMap { cycle in
            guard let quota = cycle.quota else { return nil }
            return ForecastCycle(start: cycle.span.start, end: cycle.span.end, curve: quota.curve,
                                 finalPercent: quota.finalPercent, planKey: cycle.plan?.key)
        }
        let evaluation = backtest(cycles: completed, policy: policy)

        func unavailable(_ reasons: [ForecastUnavailableReason], current: SubscriptionCycleReport? = nil,
                         history: Int = 0) -> UsageForecast {
            UsageForecast(availability: .unavailable(reasons), asOf: current?.quota?.curve.last?.lastConfirmedAt,
                          currentPercent: current?.quota?.lastPercent, cycleEnd: current?.span.end, method: nil, point: nil,
                          low: nil, high: nil, exhaustion: nil, remainingWork: nil,
                          observedPacePointsPerDay: pace(current), evidence: evidence(history, evaluation),
                          evaluation: evaluation, warnings: [.unobservedActivityPossible])
        }

        guard let current = report.currentCycle else { return unavailable([.noCurrentCycle]) }
        guard let quota = current.quota, let last = quota.curve.last else { return unavailable([.noReadings], current: current) }
        if last.percent >= quota.curve.ceiling {
            var out = unavailable([], current: current)
            out.availability = .limitReached
            return out
        }
        let length = current.span.length
        let sameHistory = completed.filter { $0.planKey == current.plan?.key }
        var reasons: [ForecastUnavailableReason] = []
        if quota.curve.points.count < 2 { reasons.append(.tooFewReadings) }
        let age = now.timeIntervalSince(last.lastConfirmedAt)
        if age > policy.staleness(cycleLength: length) { reasons.append(.readingsStale(age: age)) }
        if now >= current.span.end { reasons.append(.cycleEnded) }
        if current.plan?.changedDuringCycle == true { reasons.append(.planChangedDuringCycle) }
        guard reasons.isEmpty else { return unavailable(reasons, current: current, history: sameHistory.count) }

        switch evaluation.qualification {
        case .qualified: break
        case .tooFewCycles(let have, let need):
            return unavailable([.notEnoughCompletedCycles(have: have, need: need)], current: current, history: sameHistory.count)
        case .errorTooLarge(let error, let limit):
            return unavailable([.errorTooLarge(error: error, limit: limit)], current: current, history: sameHistory.count)
        case .noBetterThanNoGrowth(let error, let naive):
            return unavailable([.noBetterThanNoGrowth(error: error, noGrowthError: naive)], current: current, history: sameHistory.count)
        }
        let method = evaluation.selected
        let history = Array(sameHistory.suffix(policy.maximumHistoryCycles))
        guard let raw = predict(method, curve: quota.curve, start: current.span.start, end: current.span.end,
                                history: history, policy: policy), let held = evaluation.heldOutScore else {
            return unavailable([.notEnoughCompletedCycles(have: evaluation.evaluatedCycles, need: policy.minimumHeldOutCycles)],
                               current: current, history: sameHistory.count)
        }
        let floor = last.percent, ceiling = quota.curve.ceiling
        func limited(_ value: Double) -> Double { min(max(value, floor), ceiling) }
        // The range comes from the errors that the way of forecasting made on held-out cycles, and is never narrower than the
        // provider's own rounding.
        let rawLow = raw + min(held.lowResidual, -policy.rangeFloorPoints)
        let rawHigh = raw + max(held.highResidual, policy.rangeFloorPoints)

        var warnings: [ForecastWarning] = [.unobservedActivityPossible]
        if current.plan?.recorded != true { warnings.append(.planNotRecorded) }
        if completed.count > sameHistory.count { warnings.append(.earlierCyclesOnAnotherPlanExcluded) }
        if history.contains(where: { ($0.finalPercent ?? 0) >= $0.curve.ceiling }) { warnings.append(.earlierCyclesLimitBound) }
        if modelMixDrift(current: current, past: past) > policy.modelMixDriftThreshold { warnings.append(.modelMixChanged) }

        let exhaustion = exhaustionEstimate(asOf: last.lastConfirmedAt, end: current.span.end, current: last.percent,
                                            rawLow: rawLow, rawHigh: rawHigh, ceiling: ceiling)
        return UsageForecast(
            availability: .forecast, asOf: last.lastConfirmedAt, currentPercent: last.percent, cycleEnd: current.span.end,
            method: method, point: limited(raw), low: limited(rawLow), high: limited(rawHigh), exhaustion: exhaustion,
            remainingWork: remainingWork(current: current, past: past, percent: last.percent, ceiling: ceiling),
            observedPacePointsPerDay: pace(current), evidence: evidence(history.count, evaluation),
            evaluation: evaluation, warnings: warnings)
    }

    // MARK: Pieces

    private static func evidence(_ history: Int, _ evaluation: ForecastEvaluation) -> ForecastEvidence {
        let held = evaluation.heldOutScore
        return ForecastEvidence(historyCycles: history, heldOutCases: held?.cases ?? 0, heldOutCycles: held?.cycles ?? 0,
                                meanAbsoluteError: held?.meanAbsoluteError, noGrowthMeanAbsoluteError: held?.noGrowthMeanAbsoluteError,
                                bias: held?.bias, rollingCoverage: evaluation.rollingCoverage)
    }

    private static func pace(_ cycle: SubscriptionCycleReport?) -> Double? {
        guard let cycle, let last = cycle.quota?.curve.last else { return nil }
        let elapsed = last.lastConfirmedAt.timeIntervalSince(cycle.span.start)
        guard elapsed >= 3600 else { return nil }
        return last.percent / (elapsed / 86_400)
    }

    /// Assumes that the remaining rise happens at a steady pace, which is the simplest reading of a range of end values.
    private static func exhaustionEstimate(asOf: Date, end: Date, current: Double, rawLow: Double, rawHigh: Double,
                                           ceiling: Double) -> ExhaustionEstimate? {
        guard rawHigh >= ceiling, current < ceiling else { return nil }
        let remaining = end.timeIntervalSince(asOf)
        func time(reaching final: Double) -> Date {
            asOf.addingTimeInterval((ceiling - current) / (final - current) * remaining)
        }
        if rawLow >= ceiling { return ExhaustionEstimate(confidence: .likely, earliest: time(reaching: rawHigh), latest: time(reaching: rawLow)) }
        return ExhaustionEstimate(confidence: .possible, earliest: time(reaching: rawHigh), latest: nil)
    }

    /// The remaining allowance times the median observed ratio of earlier cycles whose ratio was reliable.
    private static func remainingWork(current: SubscriptionCycleReport, past: [SubscriptionCycleReport], percent: Double,
                                      ceiling: Double) -> RemainingWorkEstimate? {
        let remainingPoints = ceiling - percent
        guard remainingPoints > 0 else { return nil }
        let reliable = (past + [current]).filter {
            $0.efficiency.quality == .reliable && $0.plan?.key == current.plan?.key && $0.attribution != .ambiguous
        }
        let recent = Array(reliable.suffix(4))
        guard recent.count >= 2 else { return nil }
        func combine(_ ranges: [EfficiencyRange]) -> EfficiencyRange? {
            guard ranges.count == recent.count else { return nil }
            let values = ranges.map(\.value).sorted()
            let median = ConsumptionEfficiency.percentile(values, 0.5)!
            return EfficiencyRange(value: median * remainingPoints, low: ranges.map(\.low).min()! * remainingPoints,
                                   high: ranges.map(\.high).max()! * remainingPoints)
        }
        guard let processed = combine(recent.compactMap(\.efficiency.processedTokensPerPoint)) else { return nil }
        return RemainingWorkEstimate(remainingPoints: remainingPoints, processedTokens: processed,
                                     freshTokens: combine(recent.compactMap(\.efficiency.freshTokensPerPoint)),
                                     costUSD: combine(recent.compactMap(\.efficiency.costUSDPerPoint)), basedOnCycles: recent.count)
    }

    /// Half the L1 distance between the model shares of the current cycle and the average of the recent past cycles.
    static func modelMixDrift(current: SubscriptionCycleReport, past: [SubscriptionCycleReport]) -> Double {
        let recent = past.suffix(4).filter { !$0.local.isEmpty }
        guard !current.local.isEmpty, !recent.isEmpty else { return 0 }
        func shares(_ cycles: [SubscriptionCycleReport]) -> [String: Double] {
            var out: [String: Double] = [:]
            for cycle in cycles {
                for model in cycle.local.models { out[model.canonical, default: 0] += model.share / Double(cycles.count) }
            }
            return out
        }
        let a = shares([current]), b = shares(Array(recent))
        return Set(a.keys).union(b.keys).reduce(0) { $0 + abs((a[$1] ?? 0) - (b[$1] ?? 0)) } / 2
    }
}
