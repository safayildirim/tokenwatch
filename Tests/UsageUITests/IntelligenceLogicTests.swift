import XCTest
@testable import UsageCore
@testable import UsageUI

final class IntelligenceLogicTests: XCTestCase {
    private let friday = Date(timeIntervalSince1970: 1_792_713_600)     // Friday 2026-10-23 00:00 UTC.
    private let utcPlusThree = TimeZone(secondsFromGMT: 3 * 3600)!

    func testOffsetLabelsNameTheZoneRelativeToUTC() {
        XCTAssertEqual(IntelligenceLogic.offsetLabel(utcPlusThree, at: friday), "UTC+3")
        XCTAssertEqual(IntelligenceLogic.offsetLabel(TimeZone(secondsFromGMT: 0)!, at: friday), "UTC")
        XCTAssertEqual(IntelligenceLogic.offsetLabel(TimeZone(secondsFromGMT: -7 * 3600)!, at: friday), "UTC-7")
        XCTAssertEqual(IntelligenceLogic.offsetLabel(TimeZone(secondsFromGMT: 5 * 3600 + 1800)!, at: friday), "UTC+5:30")
    }

    func testAnEstablishedFridaySchedulePrintsAsFridayAtThreeInUTCPlusThree() throws {
        let schedule = ResetSchedule(state: .established, period: 7 * 86_400, anchor: friday + 7 * 86_400, supportingResets: 2)
        let text = try XCTUnwrap(IntelligenceLogic.scheduleDescription(schedule, zone: utcPlusThree, now: friday))
        XCTAssertTrue(text.contains("03:00"), text)
        XCTAssertTrue(text.contains("UTC+3"), text)
        XCTAssertTrue(text.contains("Friday") || text.contains("Cuma"), text)
        XCTAssertNil(IntelligenceLogic.scheduleDescription(.none, zone: utcPlusThree, now: friday), "nothing is said about an unestablished schedule")
    }

    func testTheStoredIdentifierSelectsTheZoneAndAnEmptyOneMeansTheSystemZone() {
        XCTAssertEqual(IntelligenceLogic.zone(for: "Europe/Istanbul").identifier, "Europe/Istanbul")
        XCTAssertEqual(IntelligenceLogic.zone(for: ""), TimeZone.current)
        XCTAssertEqual(IntelligenceLogic.zone(for: "Not/AZone"), TimeZone.current)
    }

    func testDayPartsGiveEstimatesWithoutAFalseMinute() {
        let evening = friday - 3 * 3600 + 24 * 3600 * 0      // Thursday 21:00 UTC.
        XCTAssertTrue(IntelligenceLogic.dayPart(evening, zone: TimeZone(secondsFromGMT: 0)!).lowercased().contains("evening") ||
                      IntelligenceLogic.dayPart(evening, zone: TimeZone(secondsFromGMT: 0)!).contains("akşam"))
    }

    private func report(points: [(Double, TimeInterval, TimeInterval)]) throws -> SubscriptionCycleReport {
        let curve = QuotaCurve(readings: points.map { QuotaReadingPoint(percent: $0.0, firstObservedAt: friday + $0.1 * 3600, lastConfirmedAt: friday + $0.2 * 3600) })
        let span = QuotaCycleSpan(start: friday, end: friday + 7 * 86_400, origin: .observed)
        let quota = CycleQuotaSummary(curve: curve, readingCount: curve.points.count, firstPercent: curve.first?.percent, lastPercent: curve.last?.percent,
                                      maximumPercent: curve.maximum, firstObservedAt: curve.first?.firstObservedAt, lastConfirmedAt: curve.last?.lastConfirmedAt,
                                      observedRisePoints: 0, startObserved: true, endObserved: false, reachedLimit: false, finalPercent: nil,
                                      coverage: .empty, completeness: .partial, sources: [], issues: [])
        return SubscriptionCycleReport(span: span, timing: .current, plan: nil, attribution: .account, local: LocalUsageSummary(), quota: quota,
                                       days: [], efficiency: .unavailable([]))
    }

    func testTheCurveIsDrawnSolidWhereObservedAndDashedWhereTheRiseWasNotSeen() throws {
        let cycle = try report(points: [(10, 1, 4), (25, 10, 12)])
        let segments = IntelligenceLogic.segments(for: cycle)
        XCTAssertEqual(segments.map(\.kind), [.observed, .bracketed, .observed])
        XCTAssertEqual(segments[0].fromHour, 1)
        XCTAssertEqual(segments[0].toHour, 4)
        XCTAssertEqual(segments[1].fromPercent, 10)
        XCTAssertEqual(segments[1].toPercent, 25)
        XCTAssertEqual(segments[1].fromHour, 4)
        XCTAssertEqual(segments[1].toHour, 10)
    }

    func testAnUnobservedCycleHasNothingToDraw() throws {
        var cycle = try report(points: [(10, 1, 4)])
        cycle.quota = nil
        XCTAssertTrue(IntelligenceLogic.segments(for: cycle).isEmpty)
        XCTAssertEqual(IntelligenceLogic.status(cycle), .unobserved)
        cycle.span.origin = .projected
        XCTAssertEqual(IntelligenceLogic.status(cycle), .projected)
    }

    func testTheDefaultWindowIsTheLongestUnscopedOneOfTheAccountReadMostRecently() {
        func subject(_ account: Int64, _ minutes: Int, scope: String? = nil, read: TimeInterval) -> IntelligenceSubject {
            IntelligenceSubject(provider: "p", accountID: account, accountLabel: "A\(account)", accountIsIdentified: true, poolKey: "pool",
                                windowKey: scope ?? "\(minutes)m", windowMinutes: minutes, scopeLabel: scope, lastReadingAt: Date(timeIntervalSince1970: read))
        }
        let subjects = [subject(1, 10_080, read: 100), subject(1, 300, read: 100), subject(2, 300, read: 500),
                        subject(2, 10_080, read: 400), subject(2, 10_080, scope: "scoped:x", read: 900)]
        let chosen = IntelligenceLogic.defaultSubject(subjects)
        XCTAssertEqual(chosen?.accountID, 2)
        XCTAssertEqual(chosen?.windowMinutes, 10_080)
        XCTAssertNil(chosen?.scopeLabel)
        XCTAssertNil(IntelligenceLogic.defaultSubject([]))
    }

    func testInsightsAreWordedFromTheirNumbersOnly() {
        let insight = UsageInsight(kind: .tokensChangedVersusPreviousCycle, priority: 70, values: ["change": 0.28, "comparable": 1], names: [:], date: nil)
        let text = IntelligenceLogic.text(for: insight, window: "weekly", zone: .current)
        XCTAssertTrue(text.contains("28"), text)
        let lower = UsageInsight(kind: .paceVersusHistory, priority: 60, values: ["change": -0.4], names: [:], date: nil)
        XCTAssertTrue(IntelligenceLogic.text(for: lower, window: "weekly", zone: .current).contains("40"))
    }

    func testEveryForecastReasonAndWarningHasText() {
        let reasons: [ForecastUnavailableReason] = [.noCurrentCycle, .noReadings, .tooFewReadings, .readingsStale(age: 7200), .cycleEnded,
                                                    .notEnoughCompletedCycles(have: 1, need: 3), .planChangedDuringCycle, .errorTooLarge(error: 15, limit: 12), .noBetterThanNoGrowth(error: 9, noGrowthError: 10)]
        for reason in reasons { XCTAssertFalse(IntelligenceLogic.unavailableText(reason).isEmpty) }
        for warning in [ForecastWarning.earlierCyclesOnAnotherPlanExcluded, .planNotRecorded, .modelMixChanged, .earlierCyclesLimitBound, .unobservedActivityPossible] {
            XCTAssertFalse(IntelligenceLogic.warningText(warning).isEmpty)
        }
        for issue in ComparabilityIssue.allCases { XCTAssertFalse(IntelligenceLogic.comparabilityText(issue).isEmpty) }
    }

    func testQuotaChangesAreNeverRenderedAsANumberWhenTheyAreUnavailable() {
        XCTAssertTrue(IntelligenceLogic.quotaChangeText(.exact(12)).contains("12"))
        XCTAssertTrue(IntelligenceLogic.quotaChangeText(.between(2, 9)).contains("2") && IntelligenceLogic.quotaChangeText(.between(2, 9)).contains("9"))
        XCTAssertFalse(IntelligenceLogic.quotaChangeText(.unavailable).contains(where: \.isNumber))
    }

    // MARK: Readiness

    private func readinessReport(schedule: ResetSchedule, attribution: LocalAttribution = .account, share: Double? = nil,
                                 efficiency: CycleEfficiency = .unavailable([.riseTooSmall])) throws -> SubscriptionUsageReport {
        var cycle = try report(points: [(0, 1, 4), (3, 10, 12)])
        cycle.attribution = attribution
        cycle.attributedShare = share
        cycle.efficiency = efficiency
        var local = LocalUsageSummary()
        local.requests = 10
        local.tokens = TokenCounts(uncachedInput: 1, output: 1, cacheRead: 100, cacheCreation: 0)
        cycle.local = local
        let subject = IntelligenceSubject(provider: "p", accountID: 1, accountLabel: "A", accountIsIdentified: true, poolKey: "pool",
                                          windowKey: "10080m", windowMinutes: 10_080)
        return SubscriptionUsageReport(subject: subject, generatedAt: friday, schedule: schedule, resetEvents: [], cycles: [cycle],
                                       notes: [], dayGrouping: .subscriptionDay)
    }

    private func noForecast(_ reasons: [ForecastUnavailableReason]) -> UsageForecast {
        UsageForecast(availability: .unavailable(reasons), asOf: nil, currentPercent: nil, cycleEnd: nil, method: nil, point: nil, low: nil, high: nil,
                      exhaustion: nil, remainingWork: nil, observedPacePointsPerDay: nil,
                      evidence: ForecastEvidence(historyCycles: 0, heldOutCases: 0, heldOutCycles: 0), evaluation: UsageForecastEngine.backtest(cycles: []),
                      warnings: [])
    }

    func testAProvisionalScheduleIsDescribedAsAnnouncedAndNotAsTwoConfirmedResets() throws {
        let schedule = ResetSchedule(state: .established, period: 7 * 86_400, anchor: friday + 7 * 86_400, supportingResets: 2, announcedResets: 2, confirmedResets: 1)
        XCTAssertEqual(schedule.confidence, .provisional)
        let notes = IntelligenceLogic.readiness(try readinessReport(schedule: schedule), forecast: noForecast([.noCurrentCycle]), zone: utcPlusThree, now: friday + 86_400)
        let text = try XCTUnwrap(notes.first { $0.id == "schedule" }).text
        XCTAssertTrue(text.contains("03:00"), text)
        XCTAssertTrue(text.contains("announced"), text)
        XCTAssertTrue(text.contains("not on two confirmed reset events"), text)
        XCTAssertEqual(try XCTUnwrap(notes.first { $0.id == "schedule" }).level, .limited)
    }

    func testAConfirmedScheduleIsStatedAsConfirmed() throws {
        let schedule = ResetSchedule(state: .established, period: 7 * 86_400, anchor: friday + 14 * 86_400, supportingResets: 3, announcedResets: 3, confirmedResets: 2)
        let notes = IntelligenceLogic.readiness(try readinessReport(schedule: schedule), forecast: noForecast([]), zone: utcPlusThree, now: friday + 86_400)
        let note = try XCTUnwrap(notes.first { $0.id == "schedule" })
        XCTAssertEqual(note.level, .available)
        XCTAssertTrue(note.text.contains("confirmed"))
    }

    func testWithoutAScheduleTheReasonIsGiven() throws {
        var one = ResetSchedule.none
        one.announcedResets = 1
        let a = IntelligenceLogic.readiness(try readinessReport(schedule: one), forecast: noForecast([]), zone: .current, now: friday)
        XCTAssertTrue(try XCTUnwrap(a.first { $0.id == "schedule" }).text.contains("needs at least two"))
        var irregular = ResetSchedule.none
        irregular.announcedResets = 5
        let b = IntelligenceLogic.readiness(try readinessReport(schedule: irregular), forecast: noForecast([]), zone: .current, now: friday)
        XCTAssertTrue(try XCTUnwrap(b.first { $0.id == "schedule" }).text.contains("do not repeat"))
    }

    func testUsageIsAvailableWhileEfficiencyAndForecastExplainWhatTheyNeed() throws {
        let notes = IntelligenceLogic.readiness(try readinessReport(schedule: .none), forecast: noForecast([.notEnoughCompletedCycles(have: 1, need: 4)]),
                                                zone: .current, now: friday)
        XCTAssertEqual(try XCTUnwrap(notes.first { $0.id == "usage" }).level, .available)
        let efficiency = try XCTUnwrap(notes.first { $0.id == "efficiency" }).text
        XCTAssertTrue(efficiency.contains("need more quota observations"), efficiency)
        let forecast = try XCTUnwrap(notes.first { $0.id == "forecast" }).text
        XCTAssertTrue(forecast.contains("1 of the 4"), forecast)
    }

    func testUnattributedLocalUsageIsSaidPlainlyAndNoEfficiencyHintIsGiven() throws {
        let notes = IntelligenceLogic.readiness(try readinessReport(schedule: .none, attribution: .unattributed, share: 0), forecast: noForecast([]),
                                                zone: .current, now: friday)
        let text = try XCTUnwrap(notes.first { $0.id == "attribution" }).text
        XCTAssertTrue(text.contains("cannot currently be reliably assigned to this subscription account"), text)
        XCTAssertNil(notes.first { $0.id == "efficiency" }, "the reason is the attribution, not a lack of readings")
    }

    func testAPartlyAttributedShareIsStated() throws {
        let notes = IntelligenceLogic.readiness(try readinessReport(schedule: .none, attribution: .partlyAttributed, share: 0.12), forecast: noForecast([]),
                                                zone: .current, now: friday)
        XCTAssertTrue(try XCTUnwrap(notes.first { $0.id == "attribution" }).text.contains("12%"))
    }

    func testCoverageLinesNeverCallALongSpanWatched() {
        let coverage = CycleCoverage(firstObservationDelay: 4 * 3600, lastObservationLead: 3600, observationCount: nil, distinctValues: 3,
                                     largestUnresolvedGap: 6 * 3600, longestUnchangedStretch: 40 * 3600, longestObservationPause: nil,
                                     determinedFraction: 0.4, supportedFraction: 0.1, hasReliableFullCycleResult: false)
        let lines = IntelligenceLogic.coverageLines(coverage).joined(separator: "\n")
        XCTAssertTrue(lines.contains("not known for readings stored earlier"), lines)
        XCTAssertTrue(lines.contains("not a gap"), lines)
        XCTAssertTrue(lines.contains("could have gone unseen"), lines)
    }
}
