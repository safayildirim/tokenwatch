import XCTest
@testable import UsageCore

final class CapacityEstimatorTests: XCTestCase {
    private func sample(_ plan: String, cycle: Int64, delta: Double, workUSD: Double,
                        model: String = "model-a", cacheRead: Int64 = 500,
                        output: Int64 = 500) -> CapacitySample {
        let tokens = TokenCounts(uncachedInput: 500, output: output, cacheRead: cacheRead, cacheCreation: 0)
        let pico = Int64((workUSD * 1_000_000_000_000).rounded())
        let workload = CapacityWorkload(
            requests: 10, tokens: tokens, cost: EstimatedCost(picoUSD: pico),
            modelCosts: [model: pico], modelDisplayNames: [model: model],
            coverage: UsageCoverage(), activeFiveMinuteBuckets: 2,
            firstRequestAt: Clock.date(ms: t0 + cycle * 3_600_000),
            lastRequestAt: Clock.date(ms: t0 + cycle * 3_600_000 + 300_000))
        return CapacitySample(id: "\(plan)-\(cycle)", planKey: plan, cycleID: cycle, windowKey: "10080m",
                              deltaPercent: delta, workload: workload, intervalCount: 1,
                              from: Clock.date(ms: t0 + cycle * 3_600_000),
                              to: Clock.date(ms: t0 + cycle * 3_600_000 + 600_000))
    }

    func testCapacityDirectionIsTheInverseOfQuotaConsumption() throws {
        let base = [sample("max-5x", cycle: 1, delta: 20, workUSD: 10),
                    sample("max-5x", cycle: 2, delta: 22, workUSD: 10)]
        let other = [sample("max-20x", cycle: 1, delta: 10, workUSD: 10),
                     sample("max-20x", cycle: 2, delta: 11, workUSD: 10)]
        let estimate = CapacityEstimator.estimate(basePlanKey: "max-5x", otherPlanKey: "max-20x",
                                                  windowKey: "10080m", windowMinutes: 10080,
                                                  samples: base + other, exclusions: [:])
        XCTAssertEqual(try XCTUnwrap(estimate.ratio), 2.0, accuracy: 1e-9,
                       "20% vs 10% for the same work means twice the capacity, never half")
        XCTAssertEqual(estimate.level, .limited)
        XCTAssertEqual(estimate.matchedPairs, 2)
        XCTAssertEqual(estimate.baseCycles, 2)
        XCTAssertEqual(estimate.otherCycles, 2)
        XCTAssertNotNil(estimate.sensitivityRange)

        let reverse = CapacityEstimator.estimate(basePlanKey: "max-20x", otherPlanKey: "max-5x",
                                                 windowKey: "10080m", windowMinutes: 10080,
                                                 samples: base + other, exclusions: [:])
        XCTAssertEqual(try XCTUnwrap(reverse.ratio), 0.5, accuracy: 1e-9)
    }

    func testOneCyclePerPlanIsProvisionalAndNeverPublished() throws {
        let samples = [sample("max-5x", cycle: 1, delta: 20, workUSD: 10),
                       sample("max-20x", cycle: 1, delta: 10, workUSD: 10)]
        let estimate = CapacityEstimator.estimate(basePlanKey: "max-5x", otherPlanKey: "max-20x",
                                                  windowKey: "10080m", windowMinutes: 10080,
                                                  samples: samples, exclusions: [:])
        XCTAssertNil(estimate.ratio)
        XCTAssertEqual(try XCTUnwrap(estimate.provisionalRatio), 2.0, accuracy: 1e-9)
        XCTAssertEqual(estimate.matchedPairs, 1)
        XCTAssertEqual(estimate.level, .insufficient)
        XCTAssertFalse(estimate.hasEnoughEvidence)
    }

    func testDifferentWorkloadCompositionIsNotPaired() {
        let base = [sample("max-5x", cycle: 1, delta: 20, workUSD: 10, model: "model-a"),
                    sample("max-5x", cycle: 2, delta: 20, workUSD: 10, model: "model-a")]
        let other = [sample("max-20x", cycle: 1, delta: 10, workUSD: 10, model: "model-b"),
                     sample("max-20x", cycle: 2, delta: 10, workUSD: 10, model: "model-b")]
        let estimate = CapacityEstimator.estimate(basePlanKey: "max-5x", otherPlanKey: "max-20x",
                                                  windowKey: "10080m", windowMinutes: 10080,
                                                  samples: base + other, exclusions: [:])
        XCTAssertNil(estimate.ratio)
        XCTAssertNil(estimate.provisionalRatio)
        XCTAssertEqual(estimate.level, .insufficient)
    }

    func testPooledFallbackRequiresComparableComposition() {
        // No one-to-one pair passes because the cache shares differ, but the pooled mix is the same.
        let base = [sample("max-5x", cycle: 1, delta: 20, workUSD: 10, cacheRead: 900),
                    sample("max-5x", cycle: 2, delta: 20, workUSD: 10, cacheRead: 800)]
        let other = [sample("max-20x", cycle: 1, delta: 10, workUSD: 10, cacheRead: 100),
                     sample("max-20x", cycle: 2, delta: 10, workUSD: 10, cacheRead: 100)]
        let estimate = CapacityEstimator.estimate(basePlanKey: "max-5x", otherPlanKey: "max-20x",
                                                  windowKey: "10080m", windowMinutes: 10080,
                                                  samples: base + other, exclusions: [:])
        XCTAssertNil(estimate.ratio)
        XCTAssertNil(estimate.provisionalRatio)
    }

    func testMultipleReadingsInOneCycleAreOneSample() {
        func interval(cycle: Int64, delta: Double, from: Int64, to: Int64) -> CapacityIntervalObservation {
            CapacityIntervalObservation(
                id: "\(cycle)-\(from)", accountID: 1, poolKey: "p", windowKey: "300m", windowMinutes: 300,
                cycleID: cycle, resetsAt: Clock.date(ms: t0 + 5 * 3_600_000),
                from: Clock.date(ms: from), to: Clock.date(ms: to),
                fromPercent: 0, toPercent: delta, deltaPercent: delta,
                planAssignmentID: 1, planKey: "max-5x", accountLabel: nil,
                workload: CapacityWorkload(requests: 2, tokens: .zero,
                                           cost: EstimatedCost(picoUSD: 1_000_000_000_000),
                                           modelCosts: ["m": 1_000_000_000_000],
                                           modelDisplayNames: ["m": "M"]),
                exclusions: [], quotaResolution: 1)
        }
        let samples = CapacityAnalyticsEngine.cycleSamples([
            interval(cycle: 9, delta: 5, from: t0, to: t0 + 600_000),
            interval(cycle: 9, delta: 5, from: t0 + 700_000, to: t0 + 1_200_000),
            interval(cycle: 10, delta: 8, from: t0 + 6 * 3_600_000, to: t0 + 6 * 3_600_000 + 600_000),
        ])
        XCTAssertEqual(samples.count, 2, "readings in one cycle are not independent samples")
        XCTAssertEqual(samples[0].deltaPercent, 10)
        XCTAssertEqual(samples[0].intervalCount, 2)
        XCTAssertEqual(samples[1].deltaPercent, 8)
    }

    func testOutlierIsExcludedAndReported() throws {
        let base = [sample("max-5x", cycle: 1, delta: 20, workUSD: 10),
                    sample("max-5x", cycle: 2, delta: 20, workUSD: 10),
                    sample("max-5x", cycle: 3, delta: 20, workUSD: 10),
                    sample("max-5x", cycle: 4, delta: 20, workUSD: 10),
                    sample("max-5x", cycle: 5, delta: 100, workUSD: 10)]
        let other = [sample("max-20x", cycle: 1, delta: 10, workUSD: 10),
                     sample("max-20x", cycle: 2, delta: 10, workUSD: 10)]
        let estimate = CapacityEstimator.estimate(basePlanKey: "max-5x", otherPlanKey: "max-20x",
                                                  windowKey: "10080m", windowMinutes: 10080,
                                                  samples: base + other, exclusions: [:])
        XCTAssertEqual(estimate.exclusions[.outlierConsumption], 1)
        XCTAssertEqual(try XCTUnwrap(estimate.ratio), 2.0, accuracy: 1e-9)
    }
}

final class PlanTimelineTests: XCTestCase {
    private func assignment(_ id: Int64, from: Date, to: Date?, plan: String?) -> PlanAssignment {
        PlanAssignment(id: id, provider: .anthropic, accountID: 1, planKey: plan, accountLabel: nil,
                       effectiveFrom: from, effectiveTo: to, provenance: .manual, note: "",
                       createdAt: from, updatedAt: from)
    }

    func testHalfOpenPeriodsAndAdjacentHandover() {
        let start = Clock.date(ms: t0)
        let end = start.addingTimeInterval(3600)
        let a = assignment(1, from: start, to: end, plan: "a")
        let b = assignment(2, from: end, to: end.addingTimeInterval(3600), plan: "b")
        XCTAssertTrue(a.contains(start))
        XCTAssertFalse(a.contains(end), "the end is exclusive")
        let timeline = PlanTimeline(assignments: [b, a])
        XCTAssertTrue(timeline.isUnambiguous)
        XCTAssertEqual(timeline.overlaps.count, 0)
        XCTAssertEqual(timeline.gaps.count, 0)
        XCTAssertEqual(timeline.assignment(at: end)?.id, 2)
    }

    func testGapIsReported() {
        let start = Clock.date(ms: t0)
        let a = assignment(1, from: start, to: start.addingTimeInterval(3600), plan: "a")
        let b = assignment(2, from: start.addingTimeInterval(7200), to: nil, plan: "b")
        let timeline = PlanTimeline(assignments: [a, b])
        XCTAssertEqual(timeline.gaps.count, 1)
        XCTAssertNil(timeline.assignment(at: start.addingTimeInterval(5000)))
    }

    func testSpanningOverlapIsDetectedEvenWhenNeighboursDoNotTouch() {
        let start = Clock.date(ms: t0)
        let a = assignment(1, from: start, to: start.addingTimeInterval(10_000), plan: "a")
        let b = assignment(2, from: start.addingTimeInterval(1000), to: start.addingTimeInterval(2000), plan: "b")
        let c = assignment(3, from: start.addingTimeInterval(3000), to: start.addingTimeInterval(4000), plan: "c")
        let timeline = PlanTimeline(assignments: [a, b, c])
        XCTAssertFalse(timeline.isUnambiguous)
        XCTAssertEqual(timeline.overlaps.count, 2)
        XCTAssertNil(timeline.assignment(at: start.addingTimeInterval(3500)))
    }
}

final class CapacityStorageTests: XCTestCase {
    func testPlanHistoryAndPrices() throws {
        let env = try TestEnv()
        var batch = NormalizedBatch()
        batch.add(Obs.session("S"))
        batch.add(Obs.claudeRequest("r1"))
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: env.db)
        let accountID = try XCTUnwrap(try env.db.read { c in
            try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''")
        })
        let start = Clock.date(ms: t0)
        let end = start.addingTimeInterval(86_400)
        let first = try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
            provider: .anthropic, accountID: accountID, planKey: "claude-max-5x", accountLabel: "Mine",
            effectiveFrom: start, effectiveTo: end))
        XCTAssertEqual(try PlanHistoryStore.assignments(env.db, provider: .anthropic, accountID: accountID).count, 1)
        XCTAssertThrowsError(try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
            provider: .anthropic, accountID: accountID, planKey: "claude-max-20x", accountLabel: "Mine",
            effectiveFrom: start.addingTimeInterval(100), effectiveTo: end.addingTimeInterval(100)))) { error in
            guard case PlanHistoryError.overlapsExisting = error else { return XCTFail("expected overlap, got \(error)") }
        }
        let second = try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
            provider: .anthropic, accountID: accountID, planKey: "claude-max-20x", accountLabel: "Mine",
            effectiveFrom: end, effectiveTo: nil))
        let timeline = try PlanHistoryStore.timeline(env.db, provider: .anthropic, accountID: accountID)
        XCTAssertTrue(timeline.isUnambiguous)
        XCTAssertEqual(timeline.gaps.count, 0)
        XCTAssertEqual(timeline.assignment(at: end)?.id, second.id)
        XCTAssertEqual(timeline.assignment(at: start.addingTimeInterval(10))?.id, first.id)

        let plan = try XCTUnwrap(env.db.registry.plan(provider: .anthropic, key: "claude-max-5x"))
        XCTAssertEqual(PlanPriceStore.quote(env.db, plan: plan).origin, .reference)
        try PlanPriceStore.setPrice(env.db, plan: plan, monthlyPriceMicros: 90_000_000, from: start)
        let quote = PlanPriceStore.quote(env.db, plan: plan, at: start.addingTimeInterval(1))
        XCTAssertEqual(quote.origin, .user)
        XCTAssertEqual(quote.monthlyPrice, 90)
        XCTAssertThrowsError(try PlanPriceStore.setPrice(
            env.db, plan: plan, monthlyPriceMicros: PlanPriceStore.maximumMonthlyPriceMicros + 1)) { error in
            XCTAssertEqual(error as? PlanPriceError, .invalidPrice)
        }
        XCTAssertEqual(PlanPriceStore.quote(env.db, plan: plan, at: start.addingTimeInterval(1)).monthlyPrice, 90)

        try PlanHistoryStore.delete(env.db, id: first.id)
        XCTAssertNil(try PlanHistoryStore.assignment(env.db, id: first.id))
        XCTAssertEqual(try PlanHistoryStore.assignments(env.db, provider: .anthropic, accountID: accountID).count, 1)
    }

    func testMeasurementRequiresAPlanAndClosesOnce() throws {
        let env = try TestEnv()
        var batch = NormalizedBatch()
        batch.add(Obs.session("S"))
        batch.add(Obs.claudeRequest("r1"))
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: env.db)
        let accountID = try XCTUnwrap(try env.db.read { c in
            try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''")
        })
        let start = Clock.date(ms: t0)
        XCTAssertThrowsError(try CapacityMeasurementStore.begin(
            env.db, provider: .anthropic, accountID: accountID, poolKey: "claude-subscription",
            windowKey: "300m", label: "x", at: start))
        _ = try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
            provider: .anthropic, accountID: accountID, planKey: "claude-max-5x",
            accountLabel: nil, effectiveFrom: start.addingTimeInterval(-3600), effectiveTo: nil))
        XCTAssertThrowsError(try CapacityMeasurementStore.begin(
            env.db, provider: .anthropic, accountID: accountID, poolKey: "claude-subscription",
            windowKey: "10080m", label: "wrong window", at: start))
        try env.db.write { c in
            let resolver = EntityResolver(c, registry: env.db.registry)
            try QuotaStore.record(QuotaObservation(
                provider: .anthropic, account: .unassigned(.anthropic), poolKey: "claude-subscription",
                windowKey: "300m", windowMinutes: 300, utilizationPercent: 0,
                resetsAt: start.addingTimeInterval(5 * 3600), observedAt: start,
                source: .claudeStatusLine, authority: .authoritative), originSessionID: nil, resolver: resolver)
        }
        let measurement = try CapacityMeasurementStore.begin(
            env.db, provider: .anthropic, accountID: accountID, poolKey: "claude-subscription",
            windowKey: "300m", label: "x", at: start)
        XCTAssertEqual(measurement.planKey, "claude-max-5x")
        let openReport = try CapacityAnalyticsEngine.report(
            env.db, range: start...start.addingTimeInterval(3_600), now: start.addingTimeInterval(60))
        let openReview = try XCTUnwrap(openReport.accounts.first?.measurements.first)
        XCTAssertEqual(openReview.exclusions, [.measurementStillOpen])
        XCTAssertFalse(openReview.isUsable)
        XCTAssertThrowsError(try CapacityMeasurementStore.begin(
            env.db, provider: .anthropic, accountID: accountID, poolKey: "claude-subscription",
            windowKey: "300m", label: "y", at: start.addingTimeInterval(10)))
        let closed = try CapacityMeasurementStore.close(env.db, id: measurement.id, at: start.addingTimeInterval(600))
        XCTAssertEqual(closed.state, .closed)
        XCTAssertEqual(closed.endedAt, start.addingTimeInterval(600))
    }
}

final class CapacityStrategyTests: XCTestCase {
    private func window(ratio: Double, db: UsageDatabase) throws -> CapacityWindowReport {
        let plan5 = try XCTUnwrap(db.registry.plan(provider: .anthropic, key: "claude-max-5x"))
        let plan20 = try XCTUnwrap(db.registry.plan(provider: .anthropic, key: "claude-max-20x"))
        let cost = EstimatedCost(picoUSD: 10_000_000_000_000)
        let workload = CapacityWorkload(requests: 10, tokens: TokenCounts(uncachedInput: 100, output: 1000),
                                        cost: cost, modelCosts: ["m": cost.picoUSD], modelDisplayNames: ["m": "M"])
        let sample = CapacitySample(id: "s", planKey: plan5.key, cycleID: 1, windowKey: "10080m",
                                    deltaPercent: 20, workload: workload, intervalCount: 1,
                                    from: Clock.date(ms: t0), to: Clock.date(ms: t0 + 600_000))
        let estimate = CapacityEstimate(
            basePlanKey: plan5.key, otherPlanKey: plan20.key, windowKey: "10080m", windowMinutes: 10080,
            ratio: ratio, provisionalRatio: nil, level: .moderate, method: .matchedCycles,
            matchedPairs: 4, baseCycles: 4, otherCycles: 4, baseIntervals: 4, otherIntervals: 4,
            dateRange: Clock.date(ms: t0)...Clock.date(ms: t0 + 86_400_000),
            sensitivityRange: ratio...ratio, pooledRatio: ratio,
            comparability: CapacityComparability(modelCosineSimilarity: 1, cacheReadShareBase: 0, cacheReadShareOther: 0,
                                                outputShareBase: 0.5, outputShareOther: 0.5,
                                                requestsBase: 10, requestsOther: 10,
                                                workUSDBase: 10, workUSDOther: 10),
            exclusions: [:], outlierCycleIDs: [])
        let history = QuotaHistoryAnalysis(windowKey: "10080m", windowMinutes: 10080, cycles: [], intervals: [],
                                           quotaResolution: 1, discarded: [:])
        return CapacityWindowReport(windowKey: "10080m", windowMinutes: 10080, windowName: "Weekly",
                                    currentPlanKey: plan5.key, history: history, samples: [sample],
                                    estimates: [estimate], exclusions: [:], planKeys: [plan5.key, plan20.key])
    }

    func testFourTimesMeasuredCapacityFavoursOneLargeSubscriptionAtEqualCost() throws {
        let env = try TestEnv()
        let window = try window(ratio: 4.0, db: env.db)
        let comparison = try XCTUnwrap(CapacityStrategyAnalyzer.compare(
            db: env.db, provider: .anthropic, poolKey: "claude-subscription", window: window,
            registryPlans: env.db.registry.plans(of: .anthropic),
            strategies: [SubscriptionStrategy(id: "two-5x", name: "Two 5x", planKey: "claude-max-5x", count: 2),
                         SubscriptionStrategy(id: "one-20x", name: "One 20x", planKey: "claude-max-20x", count: 1)],
            basePlanKey: "claude-max-5x"))
        let pair = try XCTUnwrap(comparison.breakEvens.first {
            $0.numeratorStrategyID == "one-20x" && $0.denominatorStrategyID == "two-5x"
        })
        XCTAssertEqual(try XCTUnwrap(pair.requiredRatio), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pair.measuredRatio), 2.0, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(pair.measuredRatio ?? 0, pair.requiredRatio ?? .infinity)
        XCTAssertEqual(comparison.measuredLeaderID, "one-20x")
    }

    func testOneAndAHalfTimesMeasuredCapacityFavoursTwoSmallSubscriptions() throws {
        let env = try TestEnv()
        let window = try window(ratio: 1.5, db: env.db)
        let comparison = try XCTUnwrap(CapacityStrategyAnalyzer.compare(
            db: env.db, provider: .anthropic, poolKey: "claude-subscription", window: window,
            registryPlans: env.db.registry.plans(of: .anthropic),
            strategies: [SubscriptionStrategy(id: "two-5x", name: "Two 5x", planKey: "claude-max-5x", count: 2),
                         SubscriptionStrategy(id: "one-20x", name: "One 20x", planKey: "claude-max-20x", count: 1)],
            basePlanKey: "claude-max-5x"))
        let pair = try XCTUnwrap(comparison.breakEvens.first {
            $0.numeratorStrategyID == "one-20x" && $0.denominatorStrategyID == "two-5x"
        })
        XCTAssertEqual(try XCTUnwrap(pair.measuredRatio), 0.75, accuracy: 1e-9)
        XCTAssertLessThan(pair.measuredRatio ?? 1, pair.requiredRatio ?? 0)
        XCTAssertEqual(comparison.measuredLeaderID, "two-5x")
        XCTAssertTrue(comparison.caveats.contains { $0.contains("separate quota pools") })
    }

    func testAdvertisedValuesUseTheSameBaselineAndTheSmallerPlanStaysTheBaseline() throws {
        let env = try TestEnv()
        let cost = EstimatedCost(picoUSD: 10_000_000_000_000)
        let workload = CapacityWorkload(requests: 10, tokens: TokenCounts(uncachedInput: 100, output: 1000),
                                        cost: cost, modelCosts: ["m": cost.picoUSD], modelDisplayNames: ["m": "M"])
        func sample(_ plan: String, cycle: Int64) -> CapacitySample {
            CapacitySample(id: "\(plan)-\(cycle)", planKey: plan, cycleID: cycle, windowKey: "300m",
                           deltaPercent: plan == "claude-max-5x" ? 20 : 10, workload: workload,
                           intervalCount: 1, from: Clock.date(ms: t0 + cycle * 3_600_000),
                           to: Clock.date(ms: t0 + cycle * 3_600_000 + 600_000))
        }
        let estimate = CapacityEstimate(
            basePlanKey: "claude-max-5x", otherPlanKey: "claude-max-20x", windowKey: "300m", windowMinutes: 300,
            ratio: 4, provisionalRatio: nil, level: .moderate, method: .matchedCycles,
            matchedPairs: 4, baseCycles: 2, otherCycles: 10, baseIntervals: 2, otherIntervals: 10,
            dateRange: Clock.date(ms: t0)...Clock.date(ms: t0 + 86_400_000),
            sensitivityRange: 4...4, pooledRatio: 4,
            comparability: CapacityComparability(modelCosineSimilarity: 1, cacheReadShareBase: 0, cacheReadShareOther: 0,
                                                outputShareBase: 0.5, outputShareOther: 0.5,
                                                requestsBase: 10, requestsOther: 10,
                                                workUSDBase: 10, workUSDOther: 10),
            exclusions: [:], outlierCycleIDs: [])
        let window = CapacityWindowReport(
            windowKey: "300m", windowMinutes: 300, windowName: "Five hours", currentPlanKey: "claude-max-5x",
            history: QuotaHistoryAnalysis(windowKey: "300m", windowMinutes: 300, cycles: [], intervals: [],
                                           quotaResolution: 1, discarded: [:]),
            samples: (0..<2).map { sample("claude-max-5x", cycle: Int64($0)) }
                + (0..<10).map { sample("claude-max-20x", cycle: Int64($0 + 2)) },
            estimates: [estimate], exclusions: [:], planKeys: ["claude-max-5x", "claude-max-20x"])
        let comparison = try XCTUnwrap(CapacityStrategyAnalyzer.compare(
            db: env.db, provider: .anthropic, poolKey: "claude-subscription", window: window,
            registryPlans: env.db.registry.plans(of: .anthropic),
            strategies: [SubscriptionStrategy(id: "two-5x", name: "Two 5x", planKey: "claude-max-5x", count: 2),
                         SubscriptionStrategy(id: "one-20x", name: "One 20x", planKey: "claude-max-20x", count: 1)],
            basePlanKey: nil))
        XCTAssertEqual(comparison.basePlanKey, "claude-max-5x")
        XCTAssertEqual(comparison.rows.first { $0.strategy.id == "two-5x" }?.nominalCapacityByWindow[300], 2)
        XCTAssertEqual(comparison.rows.first { $0.strategy.id == "one-20x" }?.nominalCapacityByWindow[300], 4)
        XCTAssertEqual(comparison.nominalLeaderID, "one-20x")
    }
}

final class CapacityQuotaAnalysisTests: XCTestCase {
    struct Fixture {
        var env: TestEnv
        var accountID: Int64
        var day0: Int64

        init() throws {
            env = try TestEnv()
            day0 = t0 - 2 * 86_400_000
            var batch = NormalizedBatch()
            batch.add(Obs.session("S"))
            for cycle in 0..<4 {
                let start = day0 + Int64(cycle / 2) * 86_400_000 + Int64(cycle % 2) * 6 * 3_600_000
                for i in 0..<20 {
                    let at = start + Int64(i + 1) * 20_000
                    batch.add(Obs.claudeRequest("r-\(cycle)-\(i)", at: at,
                                                input: 100, output: 1_000, cacheRead: 0, cacheCreation: 0))
                }
            }
            _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: env.db)
            accountID = try XCTUnwrap(try env.db.read { c in
                try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''")
            })
            let fiveStart = Clock.date(ms: day0)
            let twentyStart = fiveStart.addingTimeInterval(86_400)
            _ = try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
                provider: .anthropic, accountID: accountID, planKey: "claude-max-5x", accountLabel: nil,
                effectiveFrom: fiveStart, effectiveTo: twentyStart))
            _ = try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
                provider: .anthropic, accountID: accountID, planKey: "claude-max-20x", accountLabel: nil,
                effectiveFrom: twentyStart, effectiveTo: nil))
            for cycle in 0..<4 {
                let plan = cycle < 2 ? "5x" : "20x"
                let start = day0 + Int64(cycle / 2) * 86_400_000 + Int64(cycle % 2) * 6 * 3_600_000
                let delta = plan == "5x" ? 20.0 : 10.0
                try record(window: "300m", percent: 0, at: start, resets: start + 5 * 3_600_000)
                try record(window: "300m", percent: delta, at: start + 10 * 60_000, resets: start + 5 * 3_600_000)
            }
        }

        func record(window: String, percent: Double, at ms: Int64, resets: Int64) throws {
            try env.db.write { c in
                let resolver = EntityResolver(c, registry: env.db.registry)
                try QuotaStore.record(QuotaObservation(
                    provider: .anthropic, account: .unassigned(.anthropic), poolKey: "claude-subscription",
                    windowKey: window, windowMinutes: window == "300m" ? 300 : 10080,
                    utilizationPercent: percent, resetsAt: Clock.date(ms: resets),
                    observedAt: Clock.date(ms: ms), source: .claudeStatusLine, authority: .authoritative),
                    originSessionID: nil, resolver: resolver)
            }
        }
    }

    func testOverlappingCyclesCannotAttributeWorkTwice() throws {
        let env = try TestEnv()
        let base = t0
        var batch = NormalizedBatch()
        batch.add(Obs.session("S"))
        batch.add(Obs.claudeRequest("r-a", at: base + 60_000, input: 100, output: 1_000, cacheRead: 0, cacheCreation: 0))
        batch.add(Obs.claudeRequest("r-b", at: base + 6 * 60_000, input: 100, output: 1_000, cacheRead: 0, cacheCreation: 0))
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: env.db)
        let accountID = try XCTUnwrap(try env.db.read { c in
            try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''")
        })
        _ = try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
            provider: .anthropic, accountID: accountID, planKey: "claude-max-5x", accountLabel: nil,
            effectiveFrom: Clock.date(ms: base - 3_600_000), effectiveTo: Clock.date(ms: base + 3_600_000)))
        func record(_ percent: Double, _ offset: Int64, reset: Int64) throws {
            try env.db.write { c in
                let resolver = EntityResolver(c, registry: env.db.registry)
                try QuotaStore.record(QuotaObservation(
                    provider: .anthropic, account: .unassigned(.anthropic), poolKey: "claude-subscription",
                    windowKey: "300m", windowMinutes: 300, utilizationPercent: percent,
                    resetsAt: Clock.date(ms: reset), observedAt: Clock.date(ms: base + offset * 60_000),
                    source: .claudeStatusLine, authority: .authoritative), originSessionID: nil, resolver: resolver)
            }
        }
        try record(0, 0, reset: base + 3_600_000)
        try record(10, 10, reset: base + 3_600_000)
        try record(0, 5, reset: base + 7_200_000)
        try record(10, 15, reset: base + 7_200_000)
        let report = try CapacityAnalyticsEngine.report(
            env.db, range: Clock.date(ms: base - 3_600_000)...Clock.date(ms: base + 3_600_000),
            now: Clock.date(ms: base + 3_600_000))
        let window = try XCTUnwrap(report.accounts.first?.windows.first { $0.windowKey == "300m" })
        XCTAssertEqual(window.history.cycles.count, 2)
        XCTAssertEqual(window.history.intervals.count, 2)
        XCTAssertTrue(window.samples.isEmpty)
        XCTAssertEqual(window.exclusions[.overlappingQuotaIntervals], 2)
    }

    func testOneCycleWithTwoPlansIsNotCountedAsTwoSamples() throws {
        let env = try TestEnv()
        let base = t0
        var batch = NormalizedBatch()
        batch.add(Obs.session("S"))
        batch.add(Obs.claudeRequest("r-5x", at: base + 60_000, input: 100, output: 1_000, cacheRead: 0, cacheCreation: 0))
        batch.add(Obs.claudeRequest("r-20x", at: base + 16 * 60_000, input: 100, output: 1_000, cacheRead: 0, cacheCreation: 0))
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: env.db)
        let accountID = try XCTUnwrap(try env.db.read { c in
            try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''")
        })
        _ = try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
            provider: .anthropic, accountID: accountID, planKey: "claude-max-5x", accountLabel: nil,
            effectiveFrom: Clock.date(ms: base - 3_600_000), effectiveTo: Clock.date(ms: base + 10 * 60_000)))
        _ = try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
            provider: .anthropic, accountID: accountID, planKey: "claude-max-20x", accountLabel: nil,
            effectiveFrom: Clock.date(ms: base + 10 * 60_000), effectiveTo: Clock.date(ms: base + 3_600_000)))
        let reset = base + 5 * 3_600_000
        for (offset, percent) in [(0, 0.0), (5, 10.0), (15, 20.0), (20, 30.0)] {
            try env.db.write { c in
                let resolver = EntityResolver(c, registry: env.db.registry)
                try QuotaStore.record(QuotaObservation(
                    provider: .anthropic, account: .unassigned(.anthropic), poolKey: "claude-subscription",
                    windowKey: "300m", windowMinutes: 300, utilizationPercent: percent,
                    resetsAt: Clock.date(ms: reset), observedAt: Clock.date(ms: base + Int64(offset) * 60_000),
                    source: .claudeStatusLine, authority: .authoritative), originSessionID: nil, resolver: resolver)
            }
        }
        let report = try CapacityAnalyticsEngine.report(
            env.db, range: Clock.date(ms: base - 3_600_000)...Clock.date(ms: base + 3_600_000),
            now: Clock.date(ms: base + 3_600_000))
        let window = try XCTUnwrap(report.accounts.first?.windows.first { $0.windowKey == "300m" })
        XCTAssertEqual(window.history.intervals.count, 3)
        XCTAssertTrue(window.samples.isEmpty)
        XCTAssertEqual(window.exclusions[.cycleHasMultiplePlans], 2)
    }

    func testAnalyzerBuildsCyclesAndAttributedIntervals() throws {
        let f = try Fixture()
        let timeline = try PlanHistoryStore.timeline(f.env.db, provider: .anthropic, accountID: f.accountID)
        let analysis = try QuotaHistoryAnalyzer.analyze(
            f.env.db, provider: .anthropic, accountID: f.accountID, poolKey: "claude-subscription",
            windowKey: "300m", from: Clock.date(ms: f.day0 - 3_600_000),
            to: Clock.date(ms: t0), timeline: timeline)
        XCTAssertEqual(analysis.cycles.count, 4)
        XCTAssertEqual(analysis.intervals.count, 4)
        XCTAssertTrue(analysis.intervals.allSatisfy(\.isEligible), "\(analysis.intervals.flatMap(\.exclusions))")
        XCTAssertEqual(analysis.intervals[0].deltaPercent, 20, accuracy: 1e-9)
        XCTAssertEqual(analysis.intervals[0].planKey, "claude-max-5x")
        XCTAssertEqual(analysis.intervals[2].planKey, "claude-max-20x")
        XCTAssertGreaterThan(analysis.intervals[0].workload.estimatedCostUSD, 0.01)
        XCTAssertGreaterThan(analysis.intervals[0].workload.requests, 0)
        XCTAssertEqual(analysis.intervals[0].workload.modelShares().count, 1)
    }

    func testReportPublishesRelativeCapacityAcrossPlans() throws {
        let f = try Fixture()
        let strategies = [
            SubscriptionStrategy(id: "two-5x", name: "Two Max 5x", planKey: "claude-max-5x", count: 2),
            SubscriptionStrategy(id: "one-20x", name: "One Max 20x", planKey: "claude-max-20x", count: 1),
        ]
        let report = try CapacityAnalyticsEngine.report(
            f.env.db, range: Clock.date(ms: f.day0 - 3_600_000)...Clock.date(ms: t0),
            strategies: strategies, basePlanKey: "claude-max-5x", now: Clock.date(ms: t0))
        XCTAssertEqual(report.accounts.count, 1)
        let account = try XCTUnwrap(report.accounts.first)
        XCTAssertEqual(account.identityBasis, .unassignedAccount)
        XCTAssertTrue(account.supportsComparison)
        XCTAssertEqual(account.planPeriods.count, 2)
        XCTAssertEqual(account.windows.count, 1)
        let window = try XCTUnwrap(account.windows.first { $0.windowKey == "300m" })
        let estimate = try XCTUnwrap(window.estimates.first {
            $0.basePlanKey == "claude-max-5x" && $0.otherPlanKey == "claude-max-20x"
        })
        XCTAssertEqual(try XCTUnwrap(estimate.ratio), 2.0, accuracy: 1e-9)
        XCTAssertEqual(estimate.level, .limited)
        XCTAssertEqual(window.samples.count, 4)
        XCTAssertEqual(window.samples.filter { $0.planKey == "claude-max-5x" }.count, 2)
        let comparison = try XCTUnwrap(account.strategyComparisons.first)
        let a = try XCTUnwrap(comparison.rows.first { $0.id == "two-5x" })
        let b = try XCTUnwrap(comparison.rows.first { $0.id == "one-20x" })
        XCTAssertEqual(a.measuredCapacityByWindow[300] ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(b.measuredCapacityByWindow[300] ?? 0, 2, accuracy: 1e-9)
        let pair = try XCTUnwrap(comparison.breakEvens.first {
            $0.numeratorStrategyID == "one-20x" && $0.denominatorStrategyID == "two-5x"
        })
        XCTAssertEqual(try XCTUnwrap(pair.requiredRatio), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pair.measuredRatio), 1.0, accuracy: 1e-9)
    }

    func testPlanChangeInsideAnIntervalIsExcluded() throws {
        let f = try Fixture()
        let timeline = try PlanHistoryStore.timeline(f.env.db, provider: .anthropic, accountID: f.accountID)
        let start = f.day0
        // Move the handover into the first interval's middle, with no gap.
        let first = try XCTUnwrap(timeline.assignments.first)
        let second = try XCTUnwrap(timeline.assignments.dropFirst().first)
        try PlanHistoryStore.update(f.env.db, id: first.id, PlanAssignmentDraft(
            provider: .anthropic, accountID: f.accountID, planKey: first.planKey, accountLabel: nil,
            effectiveFrom: first.effectiveFrom, effectiveTo: Clock.date(ms: start + 5 * 60_000)))
        try PlanHistoryStore.update(f.env.db, id: second.id, PlanAssignmentDraft(
            provider: .anthropic, accountID: f.accountID, planKey: second.planKey, accountLabel: nil,
            effectiveFrom: Clock.date(ms: start + 5 * 60_000), effectiveTo: second.effectiveTo))
        let analysis = try QuotaHistoryAnalyzer.analyze(
            f.env.db, provider: .anthropic, accountID: f.accountID, poolKey: "claude-subscription",
            windowKey: "300m", from: Clock.date(ms: start - 3_600_000), to: Clock.date(ms: start + 3_600_000),
            timeline: try PlanHistoryStore.timeline(f.env.db, provider: .anthropic, accountID: f.accountID))
        let interval = try XCTUnwrap(analysis.intervals.first { $0.cycleID == analysis.cycles.first?.id })
        XCTAssertTrue(interval.exclusions.contains(.planChangedDuringInterval))
        XCTAssertFalse(interval.isEligible)
    }

    func testLowerReadingIsNotTreatedAsAReset() throws {
        let f = try Fixture()
        let start = f.day0 + 6 * 3_600_000
        try f.record(window: "300m", percent: 5, at: start + 20 * 60_000, resets: start + 5 * 3_600_000)
        try f.record(window: "300m", percent: 8, at: start + 30 * 60_000, resets: start + 5 * 3_600_000)
        let timeline = try PlanHistoryStore.timeline(f.env.db, provider: .anthropic, accountID: f.accountID)
        let analysis = try QuotaHistoryAnalyzer.analyze(
            f.env.db, provider: .anthropic, accountID: f.accountID, poolKey: "claude-subscription",
            windowKey: "300m", from: Clock.date(ms: start - 3_600_000), to: Clock.date(ms: start + 3_600_000),
            timeline: timeline)
        XCTAssertEqual(analysis.discarded[.quotaDecreased], 2)
        XCTAssertEqual(analysis.cycles.map(\.peakPercent).max(), 20)
    }

    func testMeasurementReviewSnapsToSurroundingReadings() throws {
        let f = try Fixture()
        let start = Clock.date(ms: f.day0 + 60_000)
        let end = Clock.date(ms: f.day0 + 9 * 60_000)
        let measurement = try CapacityMeasurementStore.begin(
            f.env.db, provider: .anthropic, accountID: f.accountID, poolKey: "claude-subscription",
            windowKey: "300m", label: "First cycle", at: start)
        try CapacityMeasurementStore.close(f.env.db, id: measurement.id, at: end)
        let report = try CapacityAnalyticsEngine.report(
            f.env.db, range: Clock.date(ms: f.day0 - 3_600_000)...Clock.date(ms: t0), now: Clock.date(ms: t0))
        let account = try XCTUnwrap(report.accounts.first)
        let review = try XCTUnwrap(account.measurements.first)
        XCTAssertEqual(review.measurement.id, measurement.id)
        XCTAssertTrue(review.isUsable, "\(review.exclusions)")
        XCTAssertEqual(try XCTUnwrap(review.deltaPercent), 20, accuracy: 1e-9)
        XCTAssertEqual(review.baseline?.percent, 0)
        XCTAssertEqual(review.ending?.percent, 20)
        XCTAssertGreaterThan(review.workload.requests, 0)
    }

    func testMeasurementDetectsAPlanEditedAfterCapture() throws {
        let f = try Fixture()
        let measurement = try CapacityMeasurementStore.begin(
            f.env.db, provider: .anthropic, accountID: f.accountID, poolKey: "claude-subscription",
            windowKey: "300m", label: "Captured plan", at: Clock.date(ms: f.day0 + 60_000))
        try CapacityMeasurementStore.close(f.env.db, id: measurement.id, at: Clock.date(ms: f.day0 + 9 * 60_000))
        try f.env.db.write { c in
            try c.run("UPDATE plan_assignment SET plan_key = 'claude-pro' WHERE id = ?",
                      [.int(try XCTUnwrap(measurement.planAssignmentID))])
        }
        let report = try CapacityAnalyticsEngine.report(
            f.env.db, range: Clock.date(ms: f.day0 - 3_600_000)...Clock.date(ms: t0), now: Clock.date(ms: t0))
        let review = try XCTUnwrap(report.accounts.first?.measurements.first)
        XCTAssertTrue(review.exclusions.contains(.measurementPlanChanged), "\(review.exclusions)")
        XCTAssertFalse(review.isUsable)
    }

    func testOverlappingPlanHistoryDisablesComparisons() throws {
        let f = try Fixture()
        let overlap = f.day0 + 3_600_000
        try f.env.db.write { c in
            try c.run("""
                INSERT INTO plan_assignment(provider_id, account_id, plan_key, effective_from, effective_to,
                    provenance, note, created_at, updated_at)
                VALUES('anthropic', ?, 'claude-pro', ?, ?, 'manual', '', ?, ?)
                """, [.int(f.accountID), .int(overlap), .int(overlap + 3_600_000), .int(overlap), .int(overlap)])
        }
        let report = try CapacityAnalyticsEngine.report(
            f.env.db, range: Clock.date(ms: f.day0 - 3_600_000)...Clock.date(ms: t0), now: Clock.date(ms: t0))
        let account = try XCTUnwrap(report.accounts.first)
        XCTAssertEqual(account.identityBasis, .ambiguousPlanHistory)
        XCTAssertFalse(account.supportsComparison)
        XCTAssertTrue(account.windows.flatMap(\.estimates).isEmpty)
        XCTAssertTrue(account.warnings.contains { $0.contains("overlap") })
    }

    func testRemoveAllDataRemovesAnnotationsButRebuildDoesNot() throws {
        let f = try Fixture()
        let measurement = try CapacityMeasurementStore.begin(
            f.env.db, provider: .anthropic, accountID: f.accountID, poolKey: "claude-subscription",
            windowKey: "300m", label: "Keep through rebuild",
            at: Clock.date(ms: f.day0 + 60_000))
        try CapacityMeasurementStore.close(f.env.db, id: measurement.id, at: Clock.date(ms: f.day0 + 9 * 60_000))
        try f.env.db.resetDerivedUsageData()
        XCTAssertEqual(try PlanHistoryStore.assignments(f.env.db, provider: .anthropic, accountID: f.accountID).count, 2)
        XCTAssertNotNil(try CapacityMeasurementStore.measurement(f.env.db, id: measurement.id))
        try f.env.db.eraseAllData()
        XCTAssertTrue(try PlanHistoryStore.assignments(f.env.db, provider: .anthropic, accountID: f.accountID).isEmpty)
        XCTAssertTrue(try CapacityMeasurementStore.list(f.env.db).isEmpty)
    }

    func testCapacityEvidenceExportContainsObservedAndEstimatedRows() throws {
        let f = try Fixture()
        let url = f.env.root.appendingPathComponent("capacity.csv")
        _ = try ExportService(db: f.env.db).export(
            kind: .capacityEvidence, format: .csv,
            range: Clock.date(ms: f.day0 - 3_600_000)...Clock.date(ms: t0), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("record_type,provider,account,pool"))
        XCTAssertTrue(text.contains("work_cost_usd"))
        XCTAssertTrue(text.contains("estimation"))
        XCTAssertTrue(text.contains("exclusions"))
        XCTAssertTrue(text.contains("ratio"))
        XCTAssertTrue(text.contains("plan_period"))
        XCTAssertTrue(text.contains("interval"))
        XCTAssertTrue(text.contains("estimate"))
        XCTAssertTrue(text.contains("claude-max-20x"))
        XCTAssertTrue(text.contains("matchedCycles"))
        XCTAssertTrue(text.contains("limited"))
    }
}

final class CapacityPerformanceTests: XCTestCase {
    /// A deliberately large but realistic history: 60 independent five-hour cycles, two plans, and
    /// 12,000 local requests. The capacity report is on demand; this test measures that one report
    /// remains bounded and does not depend on the number of file events.
    func testReportOnSixtyCyclesAndTwelveThousandRequestsIsBounded() throws {
        let env = try TestEnv()
        let base = t0 - 60 * 5 * 3_600_000
        var batch = NormalizedBatch()
        batch.add(Obs.session("S"))
        for cycle in 0..<60 {
            let start = base + Int64(cycle) * 5 * 3_600_000
            for i in 0..<200 {
                batch.add(Obs.claudeRequest("perf-\(cycle)-\(i)", at: start + Int64(i + 1) * 3_000,
                                            input: 100, output: 200, cacheRead: 1_000, cacheCreation: 0))
            }
        }
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: env.db)
        let accountID = try XCTUnwrap(try env.db.read { c in
            try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''")
        })
        let boundary = Clock.date(ms: base + 30 * 5 * 3_600_000)
        _ = try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
            provider: .anthropic, accountID: accountID, planKey: "claude-max-5x", accountLabel: "Perf",
            effectiveFrom: Clock.date(ms: base), effectiveTo: boundary))
        _ = try PlanHistoryStore.create(env.db, PlanAssignmentDraft(
            provider: .anthropic, accountID: accountID, planKey: "claude-max-20x", accountLabel: "Perf",
            effectiveFrom: boundary, effectiveTo: nil))
        for cycle in 0..<60 {
            let start = base + Int64(cycle) * 5 * 3_600_000
            let delta = cycle < 30 ? 20.0 : 5.0
            for (percent, offset) in [(0.0, Int64(0)), (delta, 10 * 60_000)] {
                try env.db.write { c in
                    let resolver = EntityResolver(c, registry: env.db.registry)
                    try QuotaStore.record(QuotaObservation(
                        provider: .anthropic, account: .unassigned(.anthropic), poolKey: "claude-subscription",
                        windowKey: "300m", windowMinutes: 300, utilizationPercent: percent,
                        resetsAt: Clock.date(ms: start + 5 * 3_600_000),
                        observedAt: Clock.date(ms: start + offset), source: .claudeStatusLine,
                        authority: .authoritative), originSessionID: nil, resolver: resolver)
                }
            }
        }
        let started = Date()
        let report = try CapacityAnalyticsEngine.report(
            env.db, range: Clock.date(ms: base - 3_600_000)...Clock.date(ms: t0), now: Clock.date(ms: t0))
        let seconds = Date().timeIntervalSince(started)
        let window = try XCTUnwrap(report.accounts.first?.windows.first)
        XCTAssertEqual(window.samples.count, 60)
        let estimate = try XCTUnwrap(window.estimates.first {
            $0.basePlanKey == "claude-max-5x" && $0.otherPlanKey == "claude-max-20x"
        })
        XCTAssertEqual(try XCTUnwrap(estimate.ratio), 4.0, accuracy: 1e-9)
        XCTAssertLessThan(seconds, 10, "a 12,000-request, 60-cycle report should stay bounded")
        print("CAPACITY_BENCH cycles=60 requests=12000 seconds=\(String(format: "%.3f", seconds))")
    }
}
