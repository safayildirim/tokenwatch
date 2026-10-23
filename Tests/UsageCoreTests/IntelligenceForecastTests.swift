import XCTest
@testable import UsageCore

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400
private let week: TimeInterval = 7 * day
private let friday = intelligenceFriday

/// A deterministic pseudo-random sequence, so that the "irregular" tests are the same on every run.
private struct Sequence: IteratorProtocol {
    var state: UInt64
    mutating func next() -> Double? {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 33) / Double(1 << 31)
    }
}

/// A completed cycle whose utilization follows `profile` (the cumulative percentage at a fraction of the cycle), read every six hours.
private func syntheticCycle(_ index: Int, planKey: String? = nil, readEvery: TimeInterval = 6 * hour,
                            profile: (Double) -> Double) -> ForecastCycle {
    let start = friday + Double(index) * week
    var readings: [QuotaReadingPoint] = []
    var time = start + hour
    while time < start + week - hour {
        let percent = min(100, profile(time.timeIntervalSince(start) / week).rounded())
        if let last = readings.last, last.percent == percent {
            readings[readings.count - 1].lastConfirmedAt = time
        } else {
            readings.append(QuotaReadingPoint(percent: percent, firstObservedAt: time, lastConfirmedAt: time))
        }
        time += readEvery
    }
    let final = min(100, profile(1).rounded())
    readings.append(QuotaReadingPoint(percent: final, firstObservedAt: start + week - hour, lastConfirmedAt: start + week - 60))
    return ForecastCycle(start: start, end: start + week, curve: QuotaCurve(readings: readings), finalPercent: final, planKey: planKey)
}

private func noiseProfile(_ shape: (Double, Double, Double)) -> (Double) -> Double {
    { x in
        let burst = 1 / (1 + exp(-30 * (x - (0.2 + 0.6 * shape.0))))
        return shape.2 * (0.2 * x + 0.8 * (shape.1 * x + (1 - shape.1) * burst))
    }
}

private let steadyFinals: [Double] = [40, 75, 55, 90, 45, 70, 60, 85, 50, 65, 80, 55]

private func noiseCycles(_ count: Int) -> [ForecastCycle] {
    var random = Sequence(state: 11)
    let shapes: [(Double, Double, Double)] = (0..<count).map { _ in (random.next()!, random.next()!, 20 + 70 * random.next()!) }
    return (0..<count).map { syntheticCycle($0, profile: noiseProfile(shapes[$0])) }
}

final class ForecastBacktestTests: XCTestCase {
    func testASteadyPaceWithVaryingTotalsIsForecastFromThePaceAndTheEvidenceIsHeldOut() throws {
        let cycles = (0..<8).map { index in syntheticCycle(index) { steadyFinals[index] * $0 } }
        let evaluation = UsageForecastEngine.backtest(cycles: cycles)
        XCTAssertEqual(evaluation.qualification, .qualified)
        XCTAssertEqual(evaluation.selected, .cycleAveragePace)
        let held = try XCTUnwrap(evaluation.heldOutScore)
        XCTAssertLessThan(held.meanAbsoluteError, 2)
        XCTAssertGreaterThan(held.noGrowthMeanAbsoluteError, 10 * held.meanAbsoluteError, "far better than assuming no more use")
        XCTAssertGreaterThan(try XCTUnwrap(evaluation.score(of: .sameStageIncrement)).meanAbsoluteError, 5, "history is no help when totals vary")
    }

    func testFewCompletedCyclesAreNotEnoughEvenWhenOneMethodLooksPerfectOnThem() throws {
        // The accelerating shape is forecast perfectly by the same-stage increment once it has history. With four cycles that
        // history does not exist yet, and what was actually held out was forecast with a method that had learned nothing.
        let four = UsageForecastEngine.backtest(cycles: (0..<4).map { syntheticCycle($0) { 70 * $0 * $0 * $0 } })
        XCTAssertEqual(try XCTUnwrap(four.score(of: .sameStageIncrement)).meanAbsoluteError, 0, accuracy: 1e-9, "in-sample it looks perfect")
        guard case .errorTooLarge = four.qualification else { return XCTFail("held-out error must decide, got \(four.qualification)") }
        let twelve = UsageForecastEngine.backtest(cycles: (0..<12).map { syntheticCycle($0) { 70 * $0 * $0 * $0 } })
        XCTAssertEqual(twelve.qualification, .qualified, "after enough cycles the held-out forecasts are accurate too")
        XCTAssertEqual(twelve.selected, .sameStageIncrement)
        XCTAssertLessThan(try XCTUnwrap(twelve.heldOutScore).meanAbsoluteError, 1)
    }

    func testTooFewCyclesGiveNoQualificationAtAll() throws {
        let evaluation = UsageForecastEngine.backtest(cycles: (0..<2).map { syntheticCycle($0) { 70 * $0 } })
        XCTAssertEqual(evaluation.qualification, .tooFewCycles(have: 2, need: 4))
        XCTAssertNil(evaluation.rollingCoverage)
    }

    func testChoosingTheBestOfSeveralMethodsOnANoisyHistoryIsOptimisticAndTheHeldOutErrorSaysSo() throws {
        let evaluation = UsageForecastEngine.backtest(cycles: noiseCycles(12))
        let inSample = try XCTUnwrap(evaluation.score(of: evaluation.selected)).meanAbsoluteError
        let held = try XCTUnwrap(evaluation.heldOutScore).meanAbsoluteError
        XCTAssertGreaterThan(held, inSample, "the error of the chosen method on the cycles it was chosen on understates its real error")
        XCTAssertGreaterThan(held, 5, "an unpredictable history is not forecast to within a few points")
    }

    func testAForecastThatDoesNotBeatAssumingNoMoreUseIsNotShown() throws {
        // All the use happens in the first tenth of the cycle, so assuming that nothing more will be used is almost exact and a
        // pace extrapolated from a quarter of the way in overshoots by a factor of four.
        let cycles = (0..<8).map { syntheticCycle($0) { min(60, 600 * $0) } }
        let evaluation = UsageForecastEngine.backtest(cycles: cycles)
        XCTAssertNotEqual(evaluation.qualification, .qualified)
    }

    func testAForecastNeverUsesInformationFromAfterItsCheckpointOrFromLaterCycles() throws {
        let base = (0..<8).map { index in syntheticCycle(index) { steadyFinals[index] * $0 } }
        var altered = base
        altered[7] = syntheticCycle(7) { 100 * $0 * $0 }                // A very different last cycle.
        let a = UsageForecastEngine.backtest(cycles: base)
        let b = UsageForecastEngine.backtest(cycles: altered)
        XCTAssertEqual(a.cases.filter { $0.cycleIndex < 7 }, b.cases.filter { $0.cycleIndex < 7 }, "changing the future changes no earlier forecast")
        XCTAssertEqual(a.heldOut.filter { $0.cycleIndex < 7 }, b.heldOut.filter { $0.cycleIndex < 7 },
                       "nor does it change the method that earlier held-out forecasts were made with")

        // Within one cycle, a checkpoint sees only the readings made before it.
        let cycle = base[3]
        let early = cycle.curve.truncated(at: cycle.start + 0.25 * week)
        XCTAssertLessThanOrEqual(try XCTUnwrap(early.last).lastConfirmedAt, cycle.start + 0.25 * week)
        let direct = UsageForecastEngine.predict(.cycleAveragePace, curve: early, start: cycle.start, end: cycle.end, history: [], policy: ForecastPolicy())
        var tampered = cycle.curve.points
        tampered[tampered.count - 1].percent = 100
        let sameEarly = QuotaCurve(readings: tampered).truncated(at: cycle.start + 0.25 * week)
        XCTAssertEqual(UsageForecastEngine.predict(.cycleAveragePace, curve: sameEarly, start: cycle.start, end: cycle.end, history: [], policy: ForecastPolicy()), direct)
    }

    func testHistoryOnAnotherPlanIsNeverUsedAsEvidence() throws {
        var cycles = (0..<4).map { syntheticCycle($0, planKey: "small") { 90 * $0 } }
        cycles += (4..<10).map { syntheticCycle($0, planKey: "large") { 30 * $0 } }
        let evaluation = UsageForecastEngine.backtest(cycles: cycles)
        let stage = evaluation.cases.filter { $0.method == .sameStageIncrement && $0.cycleIndex >= 4 }
        for case_ in stage { XCTAssertEqual(case_.predicted, 30, accuracy: 3, "large-plan cycles are forecast from large-plan cycles only") }
        XCTAssertTrue(stage.allSatisfy { $0.cycleIndex >= 7 }, "three same-plan cycles must exist before the history method starts")
    }

    func testTheScoresAreConsistentWithTheCasesTheyAreMadeOf() throws {
        let evaluation = UsageForecastEngine.backtest(cycles: noiseCycles(8))
        for score in evaluation.scores {
            let own = evaluation.cases.filter { $0.method == score.method }
            XCTAssertEqual(score.cases, own.count)
            XCTAssertEqual(score.meanAbsoluteError, own.map { abs($0.actual - $0.predicted) }.reduce(0, +) / Double(own.count), accuracy: 1e-9)
            XCTAssertEqual(score.bias, own.map { $0.actual - $0.predicted }.reduce(0, +) / Double(own.count), accuracy: 1e-9)
        }
        let held = try XCTUnwrap(evaluation.heldOutScore)
        let recent = Set(Set(evaluation.heldOut.map(\.cycleIndex)).sorted().suffix(ForecastPolicy().heldOutWindowCycles))
        let scored = evaluation.heldOut.filter { recent.contains($0.cycleIndex) }
        XCTAssertEqual(held.cases, scored.count)
        XCTAssertEqual(held.meanAbsoluteError, scored.map { abs($0.residual) }.reduce(0, +) / Double(scored.count), accuracy: 1e-9)
        if let coverage = evaluation.rollingCoverage { XCTAssertLessThanOrEqual(coverage.hits, coverage.total) }
    }

    func testTheRangeIsTheSpreadOfHeldOutErrorsAndItsCoverageIsReportedNotAssumed() throws {
        let evaluation = UsageForecastEngine.backtest(cycles: noiseCycles(12))
        let held = try XCTUnwrap(evaluation.heldOutScore)
        XCTAssertLessThan(held.lowResidual, held.highResidual)
        let coverage = try XCTUnwrap(evaluation.rollingCoverage)
        XCTAssertGreaterThan(coverage.total, 0)
        XCTAssertLessThanOrEqual(coverage.hits, coverage.total, "the page states how often the range held, and does not call it a confidence level")
    }

    func testAnOldRegimeDoesNotDecideWhetherTheCurrentOneCanBeForecast() throws {
        // Six erratic cycles followed by eight steady ones: the newest held-out cycles are what count.
        let erratic = noiseCycles(6)
        let steady = (0..<8).map { index in syntheticCycle(6 + index) { steadyFinals[index] * $0 } }
        let evaluation = UsageForecastEngine.backtest(cycles: erratic + steady)
        XCTAssertEqual(evaluation.qualification, .qualified)
        XCTAssertLessThan(try XCTUnwrap(evaluation.heldOutScore).meanAbsoluteError, 8, "scored on the newest six cycles only")
    }

    func testAStaleCheckpointReadingIsNotForecastFrom() throws {
        // Readings only every two days: at most checkpoints the newest one is older than a tenth of the week allows.
        let cycles = (0..<6).map { syntheticCycle($0, readEvery: 2 * day) { 60 * $0 } }
        let cases = UsageForecastEngine.backtest(cycles: cycles).cases
        let policy = ForecastPolicy()
        for case_ in cases {
            let cycle = cycles[case_.cycleIndex]
            let at = cycle.start + case_.checkpoint * week
            let curve = cycle.curve.truncated(at: at)
            XCTAssertLessThanOrEqual(at.timeIntervalSince(try XCTUnwrap(curve.last).lastConfirmedAt), policy.staleness(cycleLength: week))
        }
    }
}

/// Builds a database with several finished weekly cycles and a current one, for forecasts from stored data.
private func forecastWorld(pastCycles: Int, currentFraction: Double, finalOfPast: Double = 70, currentFinal: Double = 70,
                           requestsPerPoint: Int64 = 0, models: (past: String, current: String) = ("claude-opus-5-5", "claude-opus-5-5"),
                           account: AccountRef = .unassigned(.anthropic)) throws -> (IntelligenceWorld, now: Date) {
    let w = try IntelligenceWorld()
    func seed(cycle index: Int, final: Double, fraction: Double, model: String) throws {
        let start = friday + Double(index) * week
        var time = start + hour
        var step = 0
        while time < start + week * fraction {
            let percent = (final * (time.timeIntervalSince(start) / week)).rounded()
            try w.quota(percent, at: time, resets: start + week, account: account)
            if requestsPerPoint > 0 {
                w.request(at: time + 3 * hour, session: "s\(index)", model: model, account: account,
                          input: 0, output: 0, cacheRead: requestsPerPoint * 2, cacheCreation: 0)
            }
            time += 6 * hour
            step += 1
        }
        if fraction >= 1 { try w.quota(final.rounded(), at: start + week - hour, resets: start + week, account: account) }
    }
    for index in (-pastCycles)..<0 { try seed(cycle: index, final: finalOfPast, fraction: 1, model: models.past) }
    try seed(cycle: 0, final: currentFinal, fraction: currentFraction, model: models.current)
    try w.commit()
    return (w, friday + week * currentFraction + 30 * 60)
}

final class UsageForecastTests: XCTestCase {
    private func forecast(_ w: IntelligenceWorld, now: Date, identified: Bool = false) throws -> (SubscriptionUsageReport, UsageForecast) {
        let report = try w.report(identified: identified, now: now)
        return (report, UsageForecastEngine.forecast(for: report, now: now))
    }

    func testNoForecastIsMadeFromTooLittleHistoryAndTheReasonIsGiven() throws {
        let (w, now) = try forecastWorld(pastCycles: 2, currentFraction: 0.5)
        let (_, forecast) = try forecast(w, now: now)
        guard case .unavailable(let reasons) = forecast.availability else { return XCTFail("a forecast from two cycles would be a guess") }
        XCTAssertTrue(reasons.contains { if case .notEnoughCompletedCycles = $0 { true } else { false } }, "\(reasons)")
        XCTAssertNil(forecast.point)
        XCTAssertNil(forecast.low)
        XCTAssertNil(forecast.exhaustion)
        XCTAssertNotNil(forecast.observedPacePointsPerDay, "the pace so far is an observation, so it may still be shown")
    }

    func testAForecastWithEnoughHistoryComesWithARangeAndTheEvidenceBehindIt() throws {
        let (w, now) = try forecastWorld(pastCycles: 8, currentFraction: 0.5)
        let (_, forecast) = try forecast(w, now: now)
        XCTAssertEqual(forecast.availability, .forecast)
        let point = try XCTUnwrap(forecast.point), low = try XCTUnwrap(forecast.low), high = try XCTUnwrap(forecast.high)
        XCTAssertEqual(point, 70, accuracy: 4)
        XCTAssertLessThanOrEqual(low, point)
        XCTAssertGreaterThanOrEqual(high, point)
        XCTAssertNil(forecast.exhaustion, "70% at the reset does not exhaust the allowance")
        XCTAssertGreaterThanOrEqual(forecast.evidence.heldOutCases, 8)
        XCTAssertGreaterThanOrEqual(forecast.evidence.heldOutCycles, 3)
        XCTAssertNotNil(forecast.evidence.meanAbsoluteError)
        XCTAssertTrue(forecast.warnings.contains(.unobservedActivityPossible))
        XCTAssertTrue(forecast.warnings.contains(.planNotRecorded))
    }

    func testAPaceThatWouldPassTheLimitGivesAnExhaustionTimeInsideTheRemainingTime() throws {
        let (w, now) = try forecastWorld(pastCycles: 8, currentFraction: 0.6, finalOfPast: 115, currentFinal: 115)
        let (report, forecast) = try forecast(w, now: now)
        XCTAssertEqual(forecast.availability, .forecast)
        let exhaustion = try XCTUnwrap(forecast.exhaustion)
        let asOf = try XCTUnwrap(forecast.asOf), end = try XCTUnwrap(forecast.cycleEnd)
        XCTAssertGreaterThan(exhaustion.earliest, asOf)
        XCTAssertLessThan(exhaustion.earliest, end)
        XCTAssertEqual(forecast.high, 100, "the displayed range never passes the limit")
        XCTAssertNotNil(report.currentCycle)
    }

    func testAStaleLastReadingBlocksTheForecastBecauseItIsNotAPredictionFromCurrentData() throws {
        let (w, now) = try forecastWorld(pastCycles: 8, currentFraction: 0.5)
        let (_, forecast) = try forecast(w, now: now + 2 * day)
        guard case .unavailable(let reasons) = forecast.availability else { return XCTFail("a two-day-old reading must not be forecast from") }
        XCTAssertTrue(reasons.contains { if case .readingsStale = $0 { true } else { false } })
        XCTAssertNil(forecast.exhaustion)
    }

    func testASingleReadingInTheCurrentCycleIsTooSparseToForecast() throws {
        let (w, _) = try forecastWorld(pastCycles: 8, currentFraction: 0.02)
        let (_, forecast) = try forecast(w, now: friday + 4 * hour)
        guard case .unavailable(let reasons) = forecast.availability else { return XCTFail("one reading says nothing about pace") }
        XCTAssertTrue(reasons.contains(.tooFewReadings))
    }

    func testAnAccountAtTheLimitHasNothingLeftToForecast() throws {
        let w = try IntelligenceWorld()
        try w.quota(40, at: friday + hour, resets: friday + week)
        try w.quota(100, at: friday + 2 * day, resets: friday + week)
        let report = try w.report(now: friday + 3 * day)
        XCTAssertEqual(UsageForecastEngine.forecast(for: report, now: friday + 3 * day).availability, .limitReached)
    }

    func testAChangedModelMixIsReportedAsAWarningNotHidden() throws {
        let (w, now) = try forecastWorld(pastCycles: 8, currentFraction: 0.5, requestsPerPoint: 100_000,
                                         models: (past: "claude-opus-5-5", current: "claude-sonnet-5-5"))
        let (_, forecast) = try forecast(w, now: now)
        XCTAssertEqual(forecast.availability, .forecast)
        XCTAssertTrue(forecast.warnings.contains(.modelMixChanged))
    }

    func testCyclesOnAnotherPlanAreLeftOutAndTheWarningSaysSo() throws {
        let (w, now) = try forecastWorld(pastCycles: 8, currentFraction: 0.5)
        let accountID = try XCTUnwrap(try w.db.read { c in try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''") })
        _ = try PlanHistoryStore.create(w.db, PlanAssignmentDraft(provider: .anthropic, accountID: accountID, planKey: "claude-pro", accountLabel: nil,
                                                                  effectiveFrom: friday - 20 * week, effectiveTo: friday - 3 * week))
        _ = try PlanHistoryStore.create(w.db, PlanAssignmentDraft(provider: .anthropic, accountID: accountID, planKey: "claude-max-5x", accountLabel: nil,
                                                                  effectiveFrom: friday - 3 * week, effectiveTo: nil))
        let (_, forecast) = try forecast(w, now: now)
        // Only three finished cycles are on the current plan, which is too few evaluation cases for a trusted method.
        if forecast.isAvailable {
            XCTAssertTrue(forecast.warnings.contains(.earlierCyclesOnAnotherPlanExcluded))
            XCTAssertFalse(forecast.warnings.contains(.planNotRecorded))
        } else {
            XCTAssertNil(forecast.point)
        }
        XCTAssertLessThanOrEqual(forecast.evidence.historyCycles, 3)
    }

    func testTheRemainingWorkEstimateComesFromReliableRatiosOfEarlierCycles() throws {
        // One million processed tokens per percentage point in every cycle.
        let (w, now) = try forecastWorld(pastCycles: 6, currentFraction: 0.5, finalOfPast: 56, currentFinal: 56, requestsPerPoint: 1_000_000)
        let (report, forecast) = try forecast(w, now: now)
        let past = report.cycles.filter { $0.timing == .past && $0.efficiency.quality == .reliable }
        XCTAssertGreaterThanOrEqual(past.count, 2)
        let work = try XCTUnwrap(forecast.remainingWork)
        let remaining = 100 - (try XCTUnwrap(forecast.currentPercent))
        XCTAssertEqual(work.remainingPoints, remaining, accuracy: 1e-9)
        XCTAssertEqual(work.processedTokens.value / remaining, 1_000_000, accuracy: 120_000, "about a million tokens per point")
        XCTAssertLessThanOrEqual(work.processedTokens.low, work.processedTokens.value)
        XCTAssertGreaterThanOrEqual(work.processedTokens.high, work.processedTokens.value)
    }

    func testNoRemainingWorkEstimateWithoutReliableRatios() throws {
        let (w, now) = try forecastWorld(pastCycles: 8, currentFraction: 0.5)
        let (_, forecast) = try forecast(w, now: now)
        XCTAssertNil(forecast.remainingWork, "no local work was recorded, so no ratio can be reliable")
    }
}

final class CycleComparisonTests: XCTestCase {
    private func metrics(plan: String? = "p", processed: Int64 = 100_000_000, cacheShare: Double = 0.9, shares: [String: Double] = ["m": 1],
                         completeness: CycleCompleteness = .complete, coverage: Double = 0.95, rise: Double = 40, perPoint: Double = 2_000_000,
                         quality: EfficiencyQuality? = .reliable, projected: Bool = false) -> CycleMetrics {
        let span = QuotaCycleSpan(start: friday, end: friday + week, origin: projected ? .projected : .observed)
        let logical = processed - 1_000_000
        let uncached = Int64(Double(logical) * (1 - cacheShare))
        let tokens = TokenCounts(uncachedInput: uncached, output: 1_000_000, cacheRead: logical - uncached, cacheCreation: 0)
        var local = LocalUsageSummary()
        local.tokens = tokens
        local.requests = 1_000
        local.models = shares.map { ModelUsage(canonical: $0.key, displayName: $0.key, tokens: tokens, requests: 1, cost: EstimatedCost(), share: $0.value) }
        var efficiency = CycleEfficiency.unavailable([])
        efficiency.quality = quality
        efficiency.processedTokensPerPoint = EfficiencyRange(value: perPoint, low: perPoint * 0.9, high: perPoint * 1.1)
        let curve = QuotaCurve(readings: [QuotaReadingPoint(percent: 5, firstObservedAt: friday + hour, lastConfirmedAt: friday + 2 * hour),
                                          QuotaReadingPoint(percent: 5 + rise, firstObservedAt: friday + 6 * day, lastConfirmedAt: friday + 6 * day + hour)])
        let quota = CycleQuotaSummary(curve: curve, readingCount: 2, firstPercent: 5, lastPercent: 5 + rise, maximumPercent: 5 + rise,
                                      firstObservedAt: friday + hour, lastConfirmedAt: friday + 6 * day + hour, observedRisePoints: rise,
                                      startObserved: true, endObserved: true, reachedLimit: false, finalPercent: 5 + rise,
                                      coverage: CycleCoverage(firstObservationDelay: 3600, lastObservationLead: 3600, observationCount: 10, distinctValues: 2,
                                                              largestUnresolvedGap: day, longestUnchangedStretch: 3600, longestObservationPause: 600,
                                                              determinedFraction: 0.1, supportedFraction: coverage, hasReliableFullCycleResult: completeness == .complete),
                                      completeness: completeness, sources: [], issues: [])
        let cycle = SubscriptionCycleReport(span: span, timing: .past, plan: CyclePlan(key: plan, name: plan, changedDuringCycle: false),
                                            attribution: .account, local: local, quota: projected ? nil : quota, days: [], efficiency: efficiency)
        return CycleMetrics(cycle)
    }

    func testIdenticalConditionsAreDirectlyComparableAndReportRelativeChanges() throws {
        let comparison = CycleComparisonEngine.compare(metrics(processed: 100_000_000, perPoint: 2_000_000),
                                                       metrics(processed: 128_000_000, perPoint: 2_500_000))
        XCTAssertTrue(comparison.isDirectlyComparable)
        XCTAssertEqual(try XCTUnwrap(comparison.processedChange), 0.28, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(comparison.tokensPerPointChange), 0.25, accuracy: 1e-9)
    }

    func testDifferentPlansModelMixesCacheBehaviourAndCoverageAreNamedAndSuppressTheEfficiencyChange() throws {
        let base = metrics()
        XCTAssertEqual(CycleComparisonEngine.compare(base, metrics(plan: "other")).issues, [.differentPlan])
        XCTAssertTrue(CycleComparisonEngine.compare(base, metrics(shares: ["a": 0.5, "b": 0.5])).issues.contains(.differentModelMix))
        XCTAssertTrue(CycleComparisonEngine.compare(base, metrics(cacheShare: 0.6)).issues.contains(.differentCacheBehavior))
        XCTAssertTrue(CycleComparisonEngine.compare(base, metrics(completeness: .partial)).issues.contains(.partialQuotaObservation))
        XCTAssertTrue(CycleComparisonEngine.compare(base, metrics(coverage: 0.3)).issues.contains(.differentObservationCoverage))
        XCTAssertTrue(CycleComparisonEngine.compare(base, metrics(projected: true)).issues.contains(.projectedBoundaries))
        XCTAssertTrue(CycleComparisonEngine.compare(metrics(plan: nil), metrics(plan: nil)).issues.contains(.planNotRecorded))
        let confounded = CycleComparisonEngine.compare(base, metrics(plan: "other", perPoint: 4_000_000))
        XCTAssertNil(confounded.tokensPerPointChange, "a higher ratio is not called better when the plans differ")
        XCTAssertNil(confounded.quotaPaceChange)
        XCTAssertNotNil(confounded.processedChange, "the plain token change is still a fact")
    }

    func testIndicativeRatiosAreNotComparedAcrossCycles() throws {
        let comparison = CycleComparisonEngine.compare(metrics(), metrics(perPoint: 3_000_000, quality: .indicative))
        XCTAssertTrue(comparison.isDirectlyComparable)
        XCTAssertNil(comparison.tokensPerPointChange)
    }

    func testPeriodSummariesCountCyclesThatReachedTheLimit() throws {
        var limited = metrics()
        limited.reachedLimit = true
        let summary = CycleComparisonEngine.summarize([metrics(), limited, metrics(processed: 200_000_000)])
        XCTAssertEqual(summary.cyclesReachingLimit, 1)
        XCTAssertEqual(summary.cyclesWithQuota, 3)
        XCTAssertEqual(summary.completeCycles, 3)
        XCTAssertEqual(summary.meanMaximumPercent ?? 0, 45, accuracy: 1e-9)
    }
}
