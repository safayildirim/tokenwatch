import XCTest
@testable import UsageCore

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400
private let week: TimeInterval = 7 * day

/// Friday 2026-10-23 00:00:00 UTC (Friday 03:00 in UTC+3), the start of the second of two weekly cycles in these tests.
let intelligenceFriday = Date(timeIntervalSince1970: 1_792_713_600)
private let friday = intelligenceFriday
private func ms(_ date: Date) -> Int64 { Clock.ms(date) }

/// A database holding quota readings and requests that the tests place exactly where their expected answers need them.
final class IntelligenceWorld {
    let env: TestEnv
    var db: UsageDatabase { env.db }
    private var batch = NormalizedBatch()
    private var sessions: Set<String> = []
    private var counter = 0

    init() throws { env = try TestEnv() }

    static let identified = AccountRef.identified(provider: .anthropic, rawIdentifier: "11111111-2222-3333-4444-555555555555")
    static let otherIdentified = AccountRef.identified(provider: .anthropic, rawIdentifier: "99999999-2222-3333-4444-555555555555")

    func quota(_ percent: Double, at observed: Date, resets: Date?, minutes: Int = 10_080, scope: (id: String, label: String)? = nil,
               account: AccountRef = .unassigned(.anthropic), authority: QuotaAuthority = .authoritative) throws {
        let key = scope.map { WindowNaming.scopedKey(minutes: minutes, identity: $0.id, label: $0.label) } ?? WindowNaming.key(minutes: minutes)
        try db.write { c in
            let resolver = EntityResolver(c, registry: db.registry)
            try QuotaStore.record(QuotaObservation(provider: .anthropic, account: account, poolKey: "claude-subscription", windowKey: key,
                                                   windowMinutes: minutes, utilizationPercent: percent, resetsAt: resets,
                                                   observedAt: observed, source: .claudeCodeCache, authority: authority),
                                  originSessionID: nil, resolver: resolver)
        }
    }

    /// Queues one request. `tokens` follows the provider's convention, where input excludes cached tokens.
    func request(at date: Date, session: String = "S", project: String = "claude-folder:-p", model: String = "claude-opus-5-5",
                 account: AccountRef = .unassigned(.anthropic), key: String? = nil, agent: String? = nil,
                 input: Int64 = 100, output: Int64 = 50, cacheRead: Int64 = 1_000, cacheCreation: Int64 = 200,
                 cache5m: Int64? = nil, cache1h: Int64? = nil) {
        counter += 1
        let sessionKey = session + "|" + (account.hash ?? "")
        if sessions.insert(sessionKey).inserted { batch.add(Obs.session(session, project: project, at: ms(date), account: account)) }
        batch.add(Obs.claudeRequest(key ?? "r\(counter)", session: session, model: model, at: ms(date), input: input, output: output,
                                    cacheRead: cacheRead, cacheCreation: cacheCreation, cacheCreation5m: cache5m,
                                    cacheCreation1h: cache1h, agent: agent))
    }

    func commit() throws {
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: db)
        batch = NormalizedBatch()
    }

    func subject(window: String = "10080m", identified: Bool = false, label: String? = nil) throws -> IntelligenceSubject {
        try XCTUnwrap(try SubscriptionUsageAnalyticsEngine.subjects(db).first {
            $0.windowKey == window && $0.accountIsIdentified == identified && (label == nil || $0.accountLabel == label)
        })
    }

    func report(window: String = "10080m", identified: Bool = false, now: Date, grouping: DayGrouping = .subscriptionDay) throws -> SubscriptionUsageReport {
        var options = AnalysisOptions()
        options.dayGrouping = grouping
        return try SubscriptionUsageAnalyticsEngine.analyze(db, subject: try subject(window: window, identified: identified), now: now, options: options)
    }

    /// Two weekly cycles that reset on Fridays at 00:00 UTC, with readings that start and end near their boundaries.
    /// Makes sure that the accounts exist, which a quota reading creates.
    func accountsForAssociation() throws {
        try quota(1, at: friday, resets: friday + week, account: IntelligenceWorld.identified)
    }

    func twoWeeks(account: AccountRef = .unassigned(.anthropic)) throws {
        try quota(5, at: friday - week + hour, resets: friday, account: account)
        try quota(60, at: friday - 2 * hour, resets: friday, account: account)
        try quota(2, at: friday + hour, resets: friday + week, account: account)
    }
}

final class SubscriptionUsageAggregationTests: XCTestCase {
    func testTokensAreGroupedByCycleAndARequestOnTheBoundaryBelongsToTheNewCycle() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday - day, cache5m: 150, cache1h: 50)
        w.request(at: friday.addingTimeInterval(-0.001))
        w.request(at: friday)
        w.request(at: friday + day)
        try w.commit()

        let report = try w.report(now: friday + 2 * day)
        let previous = try XCTUnwrap(report.cycles.first { $0.span.end == friday })
        let current = try XCTUnwrap(report.currentCycle)
        XCTAssertEqual(previous.local.requests, 2)
        XCTAssertEqual(current.local.requests, 2, "the request at the reset instant counts in the new cycle")
        // Each request: 100 uncached + 1000 cache read + 200 cache creation + 50 output.
        XCTAssertEqual(previous.local.tokens.totalProcessed, 2 * 1_350)
        XCTAssertEqual(previous.local.tokens.freshTokens, 2 * 350)
        XCTAssertEqual(previous.local.tokens.cacheCreation5m, 150, "the split is kept where the source reported it")
        XCTAssertEqual(previous.local.tokens.cacheCreation1h, 50)
        XCTAssertEqual(previous.local.tokens.cacheRead, 2_000)
        XCTAssertEqual(previous.local.tokens.uncachedInput, 200)
        XCTAssertEqual(previous.local.tokens.output, 100)
    }

    func testASessionAcrossTheBoundaryCountsInBothCyclesButItsTokensOnlyWhereTheyHappened() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday - hour, session: "long")
        w.request(at: friday + hour, session: "long")
        w.request(at: friday + 2 * hour, session: "long")
        try w.commit()
        let report = try w.report(now: friday + day)
        let previous = try XCTUnwrap(report.cycles.first { $0.span.end == friday })
        XCTAssertEqual(previous.local.sessions, 1)
        XCTAssertEqual(report.currentCycle?.local.sessions, 1)
        XCTAssertEqual(previous.local.requests, 1)
        XCTAssertEqual(report.currentCycle?.local.requests, 2)
    }

    func testARequestSharedByAParentAndASubagentTranscriptIsCountedOnce() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday + hour, key: "shared")
        w.request(at: friday + hour, key: "shared", agent: "sub-1")
        try w.commit()
        let current = try XCTUnwrap(try w.report(now: friday + day).currentCycle)
        XCTAssertEqual(current.local.requests, 1)
        XCTAssertEqual(current.local.tokens.totalProcessed, 1_350, "reasoning and shared requests are never added twice")
    }

    func testModelsAndProjectsAreBrokenDownWithSharesOfProcessedTokens() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday + hour, session: "a", project: "claude-folder:-alpha", model: "claude-opus-5-5", cacheRead: 3_000)
        w.request(at: friday + 2 * hour, session: "b", project: "claude-folder:-beta", model: "claude-sonnet-5-5", cacheRead: 0, cacheCreation: 0)
        try w.commit()
        let local = try XCTUnwrap(try w.report(now: friday + day).currentCycle).local
        XCTAssertEqual(local.models.map(\.canonical), ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(local.models[0].share + local.models[1].share, 1, accuracy: 1e-12)
        XCTAssertEqual(local.models[0].tokens.totalProcessed, 100 + 3_000 + 200 + 50)
        XCTAssertEqual(local.projects.count, 2)
        XCTAssertEqual(local.projects.reduce(0) { $0 + $1.requests }, 2)
    }

    func testACycleWithoutLocalActivityStillReportsItsQuota() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday + hour)
        try w.commit()
        let previous = try XCTUnwrap(try w.report(now: friday + day).cycles.first { $0.span.end == friday })
        XCTAssertTrue(previous.local.isEmpty)
        XCTAssertEqual(previous.quota?.maximumPercent, 60)
    }

    func testSubscriptionDaysStartAtTheResetAndCalendarDaysFollowTheSelectedTimeZone() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday + day - 1)       // The last second of subscription day 1.
        w.request(at: friday + day)           // The first instant of subscription day 2.
        try w.commit()

        let subscription = try XCTUnwrap(try w.report(now: friday + 3 * day).currentCycle)
        XCTAssertEqual(subscription.days.count, 7)
        XCTAssertTrue(subscription.days.allSatisfy { $0.end.timeIntervalSince($0.start) == day })
        XCTAssertEqual(subscription.days[0].local.requests, 1)
        XCTAssertEqual(subscription.days[1].local.requests, 1)
        XCTAssertEqual(subscription.days[0].shareOfCycleProcessed + subscription.days[1].shareOfCycleProcessed, 1, accuracy: 1e-12)

        let istanbul = TimeZone(identifier: "Europe/Istanbul")!
        let calendarDays = try XCTUnwrap(try w.report(now: friday + 3 * day, grouping: .calendarDay(istanbul)).currentCycle).days
        XCTAssertEqual(calendarDays.count, 8, "the reset is at 03:00 local, so the first and the last calendar day are partial")
        XCTAssertEqual(calendarDays[0].end.timeIntervalSince(calendarDays[0].start), 21 * hour)
        XCTAssertEqual(calendarDays[7].end.timeIntervalSince(calendarDays[7].start), 3 * hour)
    }

    func testACalendarDayCanBeTwentyFiveHoursLongWhileASubscriptionDayIsAlwaysTwentyFour() throws {
        // The cycle contains the end of daylight saving time in New York (2026-11-01 06:00 UTC).
        let start = friday + 9 * day              // Sunday 2026-11-01 00:00 UTC.
        let w = try IntelligenceWorld()
        try w.quota(1, at: start + hour, resets: start + week)
        try w.quota(2, at: start + 2 * hour, resets: start + week)
        try w.quota(1, at: start - week + hour, resets: start)
        w.request(at: start + 5 * hour)
        try w.commit()
        let newYork = TimeZone(identifier: "America/New_York")!
        let days = try XCTUnwrap(try w.report(now: start + 3 * day, grouping: .calendarDay(newYork)).currentCycle).days
        XCTAssertTrue(days.contains { $0.end.timeIntervalSince($0.start) == 25 * hour }, "the day the clocks go back has 25 hours")
        let fixed = try XCTUnwrap(try w.report(now: start + 3 * day).currentCycle).days
        XCTAssertTrue(fixed.allSatisfy { $0.end.timeIntervalSince($0.start) == day })
    }

    func testActivePeriodsGroupRequestsSeparatedByLessThanTheActivityGap() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        for minute in [0.0, 5, 10] { w.request(at: friday + hour + minute * 60) }
        w.request(at: friday + 3 * hour)
        try w.commit()
        let local = try XCTUnwrap(try w.report(now: friday + day).currentCycle).local
        XCTAssertEqual(local.activePeriodCount, 2)
        XCTAssertEqual(local.activeDuration, 10 * 60, accuracy: 0.001)
        XCTAssertEqual(local.activeDays, 1)
    }

    func testOnlyTheProvidersOwnSessionsAreCounted() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday + hour)
        try w.commit()
        // A request of another provider in the same period must not appear in this provider's cycle.
        var batch = NormalizedBatch()
        batch.add(SessionObservation(product: .codex, source: .codexRollouts, externalID: "X", projectKey: "p", surface: nil,
                                     account: .unassigned(.openAI), firstSeenMs: ms(friday + hour), lastSeenMs: ms(friday + hour)))
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: w.db)
        let current = try XCTUnwrap(try w.report(now: friday + day).currentCycle)
        XCTAssertEqual(current.local.requests, 1)
    }
}

final class AnnouncedVersusConfirmedResetsTests: XCTestCase {
    func testTheResetAnnouncedForNextFridayIsExpectedNotConfirmedAndTheScheduleIsProvisional() throws {
        // The development situation: the reset of 23 October was announced and then followed by a reading of the new window; the
        // reset of 30 October is announced only.
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        let report = try w.report(now: friday + 2 * day)
        XCTAssertEqual(report.schedule.state, .established)
        XCTAssertEqual(report.schedule.announcedResets, 2)
        XCTAssertEqual(report.schedule.confirmedResets, 1)
        XCTAssertEqual(report.schedule.confidence, .provisional)
        let announced = try XCTUnwrap(report.resetEvents.first { $0.at == friday + week })
        XCTAssertEqual(announced.kind, .expected)
        XCTAssertFalse(announced.confirmed)
        XCTAssertEqual(report.resetEvents.filter(\.confirmed).map(\.at), [friday])
        XCTAssertEqual(try XCTUnwrap(report.schedule.wallClock(in: TimeZone(secondsFromGMT: 3 * 3600)!)).hour, 3)
    }

    func testAnAnnouncedResetInTheFutureEstablishesNothingBeforeAnythingFollowsIt() throws {
        let w = try IntelligenceWorld()
        try w.quota(5, at: friday - week + hour, resets: friday)
        try w.quota(50, at: friday - 3 * hour, resets: friday)
        let report = try w.report(now: friday - hour)
        XCTAssertEqual(report.schedule.state, .notEstablished)
        XCTAssertEqual(report.schedule.confirmedResets, 0)
        XCTAssertTrue(report.resetEvents.allSatisfy { !$0.confirmed })
    }

    func testAChangedAnnouncementDoesNotCreateASecondCycleOrAReset() throws {
        let w = try IntelligenceWorld()
        try w.quota(20, at: friday - week + hour, resets: friday)
        try w.quota(40, at: friday - 2 * day, resets: friday)
        try w.quota(41, at: friday - 2 * day + hour, resets: friday + 3 * hour)
        try w.quota(55, at: friday - hour, resets: friday + 3 * hour)
        let report = try w.report(now: friday - 30 * 60)
        XCTAssertEqual(report.cycles.filter { $0.span.origin == .observed }.count, 1)
        XCTAssertTrue(report.resetEvents.contains { $0.kind == .announcementChanged })
        XCTAssertFalse(report.resetEvents.contains { $0.kind == .exceptional })
        XCTAssertEqual(report.currentCycle?.quota?.maximumPercent, 55, "the readings of both announcements are one curve")
    }

    func testAFallInUtilizationBeforeTheAnnouncedResetIsAnExceptionalResetAndNeverNegativeConsumption() throws {
        let w = try IntelligenceWorld()
        try w.quota(20, at: friday - week + hour, resets: friday)
        try w.quota(70, at: friday - 3 * day, resets: friday)
        try w.quota(2, at: friday - 3 * day + 2 * hour, resets: friday - 3 * day + 2 * hour + week)
        try w.quota(6, at: friday - 2 * day, resets: friday - 3 * day + 2 * hour + week)
        let report = try w.report(now: friday - day)
        XCTAssertTrue(report.resetEvents.contains { $0.kind == .exceptional && $0.confirmed })
        let early = try XCTUnwrap(report.cycles.first { $0.span.endedEarly })
        XCTAssertEqual(early.quota?.maximumPercent, 70, "the earlier window's own maximum stands")
        XCTAssertEqual(report.currentCycle?.quota?.firstPercent, 2)
        let forecast = UsageForecastEngine.forecast(for: report, now: friday - day)
        XCTAssertFalse(forecast.isAvailable)
    }
}

final class SubscriptionQuotaAnalysisTests: XCTestCase {
    func testAPartialWeekReportsTheObservedRiseAndNeverTheWeeksTotal() throws {
        // The example of the specification: 150 million processed and 7 million fresh local tokens, quota seen from 2% to 84%.
        let w = try IntelligenceWorld()
        try w.quota(1, at: friday - week + hour, resets: friday)
        try w.quota(2, at: friday + 3 * day, resets: friday + week)
        try w.quota(84, at: friday + 6 * day, resets: friday + week)
        w.request(at: friday + 4 * day, input: 2_000_000, output: 3_000_000, cacheRead: 143_000_000, cacheCreation: 2_000_000)
        try w.commit()

        let current = try XCTUnwrap(try w.report(now: friday + 6 * day + hour).currentCycle)
        XCTAssertEqual(current.local.tokens.totalProcessed, 150_000_000)
        XCTAssertEqual(current.local.tokens.freshTokens, 7_000_000)
        let quota = try XCTUnwrap(current.quota)
        XCTAssertEqual(quota.firstPercent, 2)
        XCTAssertEqual(quota.lastPercent, 84)
        XCTAssertEqual(quota.observedRisePoints, 82)
        XCTAssertEqual(quota.maximumPercent, 84, "at least 84%")
        XCTAssertFalse(quota.startObserved, "the first reading came three days into the cycle")
        XCTAssertFalse(quota.endObserved)
        XCTAssertNil(quota.finalPercent, "the exact final utilization is unknown")
        XCTAssertEqual(quota.completeness, .partial)
        XCTAssertFalse(quota.reachedLimit)
    }

    func testAFullyObservedCycleIsCompleteAndItsFinalValueIsKnown() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        let previous = try XCTUnwrap(try w.report(now: friday + day).cycles.first { $0.span.end == friday }?.quota)
        // The first reading is within the tolerance of the start, but 60% was last confirmed two hours before the end.
        XCTAssertTrue(previous.startObserved)
        XCTAssertTrue(previous.endObserved)
        XCTAssertEqual(previous.finalPercent, 60)
        XCTAssertEqual(previous.readingCount, 2)
        XCTAssertEqual(previous.completeness, .partial, "a week with only two readings leaves a very long unobserved stretch")
    }

    func testACycleIsCompleteWhenReadingsAreNeverFarApart() throws {
        let w = try IntelligenceWorld()
        for step in 0..<28 {
            try w.quota(Double(step * 3), at: friday - week + hour + Double(step) * 6 * hour, resets: friday)
        }
        try w.quota(88, at: friday - hour, resets: friday)
        try w.quota(1, at: friday + hour, resets: friday + week)
        let previous = try XCTUnwrap(try w.report(now: friday + day).cycles.first { $0.span.end == friday }?.quota)
        XCTAssertEqual(previous.completeness, .complete)
        XCTAssertTrue(previous.coverage.hasReliableFullCycleResult)
        XCTAssertLessThan(previous.coverage.determinedFraction, 0.05, "every value was seen once, so the values are bracketed, not determined")
    }

    func testReachingTheLimitMakesTheFinalValueKnownEvenWithoutAReadingNearTheEnd() throws {
        let w = try IntelligenceWorld()
        try w.quota(40, at: friday - week + hour, resets: friday)
        try w.quota(100, at: friday - 3 * day, resets: friday)
        try w.quota(1, at: friday + hour, resets: friday + week)
        let quota = try XCTUnwrap(try w.report(now: friday + day).cycles.first { $0.span.end == friday }?.quota)
        XCTAssertTrue(quota.reachedLimit)
        XCTAssertTrue(quota.endObserved)
        XCTAssertEqual(quota.finalPercent, 100)
    }

    func testNoUtilizationIsEverInventedForACycleThatWasCalculatedFromTheSchedule() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday - 10 * day)
        try w.commit()
        let report = try w.report(now: friday + day)
        let projected = report.cycles.filter { $0.span.origin == .projected }
        XCTAssertFalse(projected.isEmpty)
        for cycle in projected {
            XCTAssertNil(cycle.quota, "no reading, no percentage")
            XCTAssertFalse(cycle.efficiency.isAvailable)
        }
        XCTAssertTrue(report.notes.contains(.projectedCyclesPresent))
        XCTAssertEqual(projected.last?.local.requests, 1, "local work is still reported for a calculated cycle")
    }

    func testRereadingTheSameReadingNeverMovesItsConfirmationButANewConfirmationDoes() throws {
        let w = try IntelligenceWorld()
        let at = friday + hour
        try w.quota(7, at: at, resets: friday + week)
        try w.quota(7, at: at, resets: friday + week)
        try w.quota(7, at: at, resets: friday + week)
        var rows = try w.db.read { c in try c.query("SELECT observed_at, last_confirmed_at FROM quota_snapshot") { ($0.int(0), $0.int(1)) } }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].0, rows[0].1, "rereading a file cannot make the reading newer")

        try w.quota(7, at: at + 5 * hour, resets: friday + week)
        rows = try w.db.read { c in try c.query("SELECT observed_at, last_confirmed_at FROM quota_snapshot") { ($0.int(0), $0.int(1)) } }
        XCTAssertEqual(rows.count, 1, "no new row for an unchanged value")
        XCTAssertEqual(rows[0].1 - rows[0].0, Int64(5 * hour * 1000), "a genuinely later confirmation extends the span")
        let curve = try XCTUnwrap(try w.report(now: friday + day).currentCycle?.quota?.curve)
        XCTAssertEqual(curve.bounds(at: at + 3 * hour)?.basis, .exact, "the value is known between the two confirmations")
    }

    func testReadingsDeliveredOutOfOrderGiveTheSameCurve() throws {
        let inOrder = try IntelligenceWorld(), shuffled = try IntelligenceWorld()
        let readings: [(Double, TimeInterval)] = [(10, 1), (20, 5), (35, 9), (50, 20)]
        for (percent, at) in readings { try inOrder.quota(percent, at: friday + at * hour, resets: friday + week) }
        for (percent, at) in readings.reversed() { try shuffled.quota(percent, at: friday + at * hour, resets: friday + week) }
        let a = try XCTUnwrap(try inOrder.report(now: friday + day).currentCycle?.quota?.curve)
        let b = try XCTUnwrap(try shuffled.report(now: friday + day).currentCycle?.quota?.curve)
        XCTAssertEqual(a, b)
    }

    func testALowerLaterReadingInTheSameCycleIsKeptOutOfTheCurveAndReported() throws {
        let w = try IntelligenceWorld()
        try w.quota(30, at: friday + hour, resets: friday + week)
        try w.quota(50, at: friday + 5 * hour, resets: friday + week)
        try w.quota(20, at: friday + 8 * hour, resets: friday + week)
        let quota = try XCTUnwrap(try w.report(now: friday + day).currentCycle?.quota)
        XCTAssertEqual(quota.maximumPercent, 50)
        XCTAssertEqual(quota.lastPercent, 50, "a lower reading is not a reset and not negative consumption")
        XCTAssertEqual(quota.issues.count, 1)
    }

    func testUnverifiedReadingsAreNotPartOfTheHistory() throws {
        let w = try IntelligenceWorld()
        try w.quota(10, at: friday + hour, resets: friday + week)
        try w.quota(90, at: friday + 2 * hour, resets: friday + week, authority: .unverified)
        let quota = try XCTUnwrap(try w.report(now: friday + day).currentCycle?.quota)
        XCTAssertEqual(quota.maximumPercent, 10)
    }

    func testTheDailyQuotaChangeIsExactBracketedOrUnavailableAndNeverInterpolated() throws {
        let w = try IntelligenceWorld()
        try w.quota(10, at: friday + 1 * day + hour, resets: friday + week)
        try w.quota(10, at: friday + 1 * day + 5 * hour, resets: friday + week)
        try w.quota(25, at: friday + 2 * day + hour, resets: friday + week)
        try w.quota(25, at: friday + 4 * day, resets: friday + week)
        try w.quota(60, at: friday + 5 * day + 2 * hour, resets: friday + week)
        let days = try XCTUnwrap(try w.report(now: friday + 6 * day).currentCycle?.days)
        XCTAssertEqual(days[0].quotaChange, .unavailable, "nothing was observed before the first reading")
        XCTAssertEqual(days[1].quotaChange, .unavailable, "the day starts before 10% was first seen")
        // Day 2 runs from friday + 2 d (between the readings 10 and 25) to friday + 3 d (exactly 25).
        XCTAssertEqual(days[2].quotaChange, .between(0, 15))
        XCTAssertEqual(days[3].quotaChange, .exact(0), "25% was seen at both ends of day 3")
        XCTAssertEqual(days[5].quotaChange, .unavailable, "the end of day 5 is after the last reading")
    }

    func testTwoAccountsKeepSeparatePoolsAndNeverShareReadings() throws {
        let w = try IntelligenceWorld()
        try w.quota(10, at: friday + hour, resets: friday + week, account: IntelligenceWorld.identified)
        try w.quota(80, at: friday + 2 * hour, resets: friday + week, account: IntelligenceWorld.otherIdentified)
        let subjects = try SubscriptionUsageAnalyticsEngine.subjects(w.db).filter { $0.windowKey == "10080m" }
        XCTAssertEqual(subjects.count, 2)
        for subject in subjects {
            let report = try SubscriptionUsageAnalyticsEngine.analyze(w.db, subject: subject, now: friday + day)
            XCTAssertEqual(report.currentCycle?.quota?.readingCount, 1)
        }
        let maxima = try subjects.map { try XCTUnwrap(SubscriptionUsageAnalyticsEngine.analyze(w.db, subject: $0, now: friday + day).currentCycle?.quota?.maximumPercent) }
        XCTAssertEqual(Set(maxima), [10, 80])
    }

    func testScopedAndGeneralWeeklyWindowsOfTheSameLengthStaySeparate() throws {
        let w = try IntelligenceWorld()
        try w.quota(30, at: friday + hour, resets: friday + week)
        try w.quota(5, at: friday + hour, resets: friday + week, scope: (id: "name:opus", label: "Opus"))
        let subjects = try SubscriptionUsageAnalyticsEngine.subjects(w.db)
        XCTAssertEqual(subjects.count, 2)
        XCTAssertEqual(Set(subjects.map(\.windowMinutes)), [10_080])
        XCTAssertEqual(subjects.compactMap(\.scopeLabel), ["Opus"])
        w.request(at: friday + 2 * hour, model: "claude-opus-5-5")
        w.request(at: friday + 3 * hour, model: "claude-sonnet-5-5")
        try w.commit()
        let general = try SubscriptionUsageAnalyticsEngine.analyze(w.db, subject: try XCTUnwrap(subjects.first { $0.scopeLabel == nil }), now: friday + day)
        let scoped = try SubscriptionUsageAnalyticsEngine.analyze(w.db, subject: try XCTUnwrap(subjects.first { $0.scopeLabel != nil }), now: friday + day)
        XCTAssertEqual(general.currentCycle?.quota?.maximumPercent, 30)
        XCTAssertEqual(scoped.currentCycle?.quota?.maximumPercent, 5)
        XCTAssertEqual(general.currentCycle?.local.requests, 2)
        XCTAssertEqual(scoped.currentCycle?.local.requests, 1, "a model-scoped window counts only that model's work")
    }

    func testAScopedWindowWhoseModelIsUnknownIsNotAttributedToLocalWork() throws {
        let w = try IntelligenceWorld()
        try w.quota(5, at: friday + hour, resets: friday + week, scope: (id: "name:zeta", label: "Zeta"))
        w.request(at: friday + 2 * hour)
        try w.commit()
        let subject = try XCTUnwrap(try SubscriptionUsageAnalyticsEngine.subjects(w.db).first)
        let current = try XCTUnwrap(try SubscriptionUsageAnalyticsEngine.analyze(w.db, subject: subject, now: friday + day).currentCycle)
        XCTAssertEqual(current.attribution, .notAttributed)
        XCTAssertTrue(current.local.isEmpty)
        XCTAssertEqual(current.efficiency.unavailable, [.localActivityNotAttributed])
    }

    func testPlanRecordedForTheAccountLabelsTheCycleAndAChangeIsFlagged() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday + hour)
        try w.commit()
        let accountID = try XCTUnwrap(try w.db.read { c in try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''") })
        _ = try PlanHistoryStore.create(w.db, PlanAssignmentDraft(provider: .anthropic, accountID: accountID, planKey: "claude-max-5x", accountLabel: nil,
                                                                  effectiveFrom: friday - 2 * week, effectiveTo: friday + 2 * day))
        _ = try PlanHistoryStore.create(w.db, PlanAssignmentDraft(provider: .anthropic, accountID: accountID, planKey: "claude-max-20x", accountLabel: nil,
                                                                  effectiveFrom: friday + 2 * day, effectiveTo: nil))
        let report = try w.report(now: friday + 3 * day)
        let previous = try XCTUnwrap(report.cycles.first { $0.span.end == friday })
        XCTAssertEqual(previous.plan?.key, "claude-max-5x")
        XCTAssertEqual(previous.plan?.changedDuringCycle, false)
        let current = try XCTUnwrap(report.currentCycle)
        XCTAssertNil(current.plan?.key, "two plans in one cycle: neither names the cycle")
        XCTAssertEqual(current.plan?.changedDuringCycle, true)
    }

    func testAnalysisOnlyReadsAndIsRepeatable() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday + hour)
        try w.commit()
        func counts() throws -> [Int64] {
            try w.db.read { c in
                try ["quota_snapshot", "quota_cycle", "model_request", "session", "setting"].map { try XCTUnwrap(c.scalarInt("SELECT count(*) FROM \($0)")) }
            }
        }
        let before = try counts()
        let first = try w.report(now: friday + day), second = try w.report(now: friday + day)
        XCTAssertEqual(first, second, "the same rows always give the same report")
        XCTAssertEqual(try counts(), before)
    }
}

final class SubscriptionAttributionTests: XCTestCase {
    private func identifiedAccountID(_ w: IntelligenceWorld) throws -> Int64 {
        try XCTUnwrap(try w.db.read { c in try c.scalarInt("SELECT id FROM account WHERE hash = ?", [.text(IntelligenceWorld.identified.hash!)]) })
    }

    func testSessionsThatNameNoAccountAreNotAttributedToAnIdentifiedAccount() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks(account: IntelligenceWorld.identified)
        w.request(at: friday + hour)
        try w.commit()
        let current = try XCTUnwrap(try w.report(identified: true, now: friday + day).currentCycle)
        XCTAssertEqual(current.attribution, .unattributed, "nothing ties these sessions to the account")
        XCTAssertTrue(current.local.isEmpty, "the account's own local usage is empty")
        XCTAssertEqual(current.unattributed.requests, 1, "the activity is kept apart, not discarded")
        XCTAssertEqual(current.attributedShare, 0)
    }

    func testSessionsRecordedForTheAccountItselfAreAttributedAndUnassignedOnesAreKeptApart() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks(account: IntelligenceWorld.identified)
        w.request(at: friday + hour, session: "own", account: IntelligenceWorld.identified)
        w.request(at: friday + 2 * hour, session: "anonymous")
        try w.commit()
        let current = try XCTUnwrap(try w.report(identified: true, now: friday + day).currentCycle)
        XCTAssertEqual(current.attribution, .partlyAttributed)
        XCTAssertEqual(current.local.requests, 1)
        XCTAssertEqual(current.unattributed.requests, 1)
        XCTAssertEqual(try XCTUnwrap(current.attributedShare), 0.5, accuracy: 1e-9)
    }

    func testWhenEverySessionNamesTheAccountTheCycleIsFullyAttributed() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks(account: IntelligenceWorld.identified)
        w.request(at: friday + hour, session: "own", account: IntelligenceWorld.identified)
        try w.commit()
        let current = try XCTUnwrap(try w.report(identified: true, now: friday + day).currentCycle)
        XCTAssertEqual(current.attribution, .account)
        XCTAssertEqual(current.attributedShare, 1)
    }

    func testAUserAssociationAttributesUnassignedActivityOnlyInsideItsPeriodAndOnlyToItsAccount() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks(account: IntelligenceWorld.identified)
        w.request(at: friday + hour, session: "a")
        w.request(at: friday + 2 * hour, session: "b")
        w.request(at: friday + 3 * hour, session: "c")
        try w.commit()
        let id = try identifiedAccountID(w)
        // The user says that the first two hours of activity were this account's, and that the third hour was another one's.
        _ = try w.accountsForAssociation()
        _ = try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: id, from: friday, to: friday + 2 * hour + 1)
        try w.quota(1, at: friday, resets: friday + week, account: IntelligenceWorld.otherIdentified)
        let other = try XCTUnwrap(try w.db.read { c in try c.scalarInt("SELECT id FROM account WHERE hash = ?", [.text(IntelligenceWorld.otherIdentified.hash!)]) })
        _ = try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: other, from: friday + 2 * hour + 1, to: friday + 4 * hour)
        let current = try XCTUnwrap(try w.report(identified: true, now: friday + day).currentCycle)
        XCTAssertEqual(current.local.requests, 2, "the two requests inside the association")
        XCTAssertEqual(current.unattributed.requests, 0, "the third request was associated with another account and belongs to neither side here")
        XCTAssertEqual(current.attribution, .account)
    }

    func testAnotherIdentifiedAccountInTheSamePeriodMakesUnattributedActivityAmbiguous() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks(account: IntelligenceWorld.identified)
        try w.quota(40, at: friday + hour, resets: friday + week, account: IntelligenceWorld.otherIdentified)
        w.request(at: friday + 2 * hour)
        try w.commit()
        let subject = try w.subject(identified: true, label: "Account " + String(IntelligenceWorld.identified.hash!.prefix(6)))
        let current = try XCTUnwrap(try SubscriptionUsageAnalyticsEngine.analyze(w.db, subject: subject, now: friday + day).currentCycle)
        XCTAssertEqual(current.attribution, .ambiguous)
        XCTAssertEqual(current.efficiency.unavailable, [.localActivityNotAttributed])
    }

    func testTheUnassignedAccountPairsItsOwnReadingsWithItsOwnSessionsAndSaysSo() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday + 2 * hour)
        try w.commit()
        let current = try XCTUnwrap(try w.report(now: friday + day).currentCycle)
        XCTAssertEqual(current.attribution, .unassignedAccount)
        XCTAssertFalse(current.quotaIdentityAmbiguous)
    }

    func testActivityThatNamesAnAccountIsNotSilentlyDroppedFromTheUnassignedReadingsComparison() throws {
        let w = try IntelligenceWorld()
        for (percent, at) in [(10.0, 1.0), (20, 30), (30, 60), (40, 90)] { try w.quota(percent, at: friday + at * hour, resets: friday + week) }
        w.request(at: friday + 50 * hour, input: 0, output: 0, cacheRead: 30_000_000, cacheCreation: 0)
        w.request(at: friday + 52 * hour, session: "named", account: IntelligenceWorld.identified, input: 0, output: 0, cacheRead: 30_000_000, cacheCreation: 0)
        try w.commit()
        let current = try XCTUnwrap(try w.report(now: friday + 5 * day).currentCycle)
        XCTAssertEqual(current.attribution, .partlyAttributed)
        XCTAssertEqual(try XCTUnwrap(current.attributedShare), 0.5, accuracy: 1e-9)
        XCTAssertEqual(current.efficiency.unavailable, [.localActivityNotAttributed], "half of the work between the readings may belong to another account")
    }

    func testUnassignedReadingsOverlappingAnIdentifiedAccountCannotBeTiedToEither() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        try w.quota(40, at: friday + hour, resets: friday + week, account: IntelligenceWorld.identified)
        w.request(at: friday + 2 * hour)
        try w.commit()
        let current = try XCTUnwrap(try w.report(now: friday + day).currentCycle)
        XCTAssertTrue(current.quotaIdentityAmbiguous, "the unlabeled readings may be the identified account's")
        XCTAssertEqual(current.attribution, .ambiguous)
        XCTAssertFalse(current.efficiency.isAvailable)
        let previous = try XCTUnwrap(try w.report(now: friday + day).cycles.first { $0.span.end == friday })
        XCTAssertFalse(previous.quotaIdentityAmbiguous, "the identified account did not exist yet")
    }

    func testAnIdentifiedPoolSaysThatUnassignedQuotaHistoryExistsWithoutMergingIt() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        try w.twoWeeks(account: IntelligenceWorld.identified)
        let report = try w.report(identified: true, now: friday + day)
        XCTAssertTrue(report.notes.contains(.unassignedHistoryExists))
        XCTAssertEqual(report.cycles.filter { $0.quota != nil }.count, 2)
    }
}

final class ConsumptionEfficiencyTests: XCTestCase {
    private func world(readings: [(Double, TimeInterval)], work: [(TimeInterval, Int64)]) throws -> IntelligenceWorld {
        let w = try IntelligenceWorld()
        for (percent, at) in readings { try w.quota(percent, at: friday + at * hour, resets: friday + week) }
        for (at, tokens) in work { w.request(at: friday + at * hour, input: 0, output: 0, cacheRead: tokens, cacheCreation: 0) }
        try w.commit()
        return w
    }

    func testTheRatioIsTheWorkBetweenTheTwoExactObservationsOverTheRiseAndCarriesARoundingRange() throws {
        // 10% is confirmed until hour 24, and 40% first appears at hour 100. Work outside that interval is not counted.
        let w = try world(readings: [(10, 1), (10, 24), (20, 50), (30, 70), (40, 100)],
                          work: [(0, 7_000_000_000), (30, 10_000_000), (60, 10_000_000), (90, 10_000_000), (110, 9_000_000_000)])
        let efficiency = try XCTUnwrap(try w.report(now: friday + 5 * day).currentCycle).efficiency
        XCTAssertEqual(efficiency.quality, .reliable)
        XCTAssertEqual(efficiency.risePoints, 30)
        XCTAssertEqual(efficiency.steps, 3)
        XCTAssertEqual(efficiency.processedTokens, 30_000_000)
        let ratio = try XCTUnwrap(efficiency.processedTokensPerPoint)
        XCTAssertEqual(ratio.value, 1_000_000, accuracy: 1e-6)
        XCTAssertEqual(ratio.low, 30_000_000 / 31, accuracy: 1e-6, "the true rise may have been one point more")
        XCTAssertEqual(ratio.high, 30_000_000 / 29, accuracy: 1e-6, "or one point less")
        let perMillion = try XCTUnwrap(efficiency.pointsPerMillionProcessed)
        XCTAssertEqual(perMillion.value, 1.0, accuracy: 1e-9)
        XCTAssertTrue(efficiency.caveats.contains(.accountWideQuotaVersusLocalTokens))
        XCTAssertTrue(efficiency.caveats.contains(.roundedPercentages))
    }

    func testATinyRiseIsNotTurnedIntoARatio() throws {
        let w = try world(readings: [(10, 1), (11, 30), (12, 60)], work: [(40, 50_000_000)])
        let efficiency = try XCTUnwrap(try w.report(now: friday + 5 * day).currentCycle).efficiency
        XCTAssertFalse(efficiency.isAvailable)
        XCTAssertTrue(efficiency.unavailable.contains(.riseTooSmall))
        XCTAssertNil(efficiency.processedTokensPerPoint)
    }

    func testASingleReadingGivesNoRatio() throws {
        let w = try world(readings: [(10, 1)], work: [(40, 50_000_000)])
        XCTAssertEqual(try XCTUnwrap(try w.report(now: friday + day).currentCycle).efficiency.unavailable, [.singleReading])
    }

    func testTooLittleLocalWorkOrTooShortAnIntervalGivesNoRatio() throws {
        let little = try world(readings: [(10, 1), (20, 30), (30, 60)], work: [(40, 10_000)])
        XCTAssertTrue(try XCTUnwrap(try little.report(now: friday + 5 * day).currentCycle).efficiency.unavailable.contains(.tooLittleLocalWork))
        let brief = try world(readings: [(10, 0.01), (20, 0.1), (30, 0.2)], work: [(0.1, 50_000_000)])
        XCTAssertTrue(try XCTUnwrap(try brief.report(now: friday + 5 * day).currentCycle).efficiency.unavailable.contains(.intervalTooShort))
    }

    func testTwoStepsMakeTheRatioIndicativeAndAnUnevenWorkloadIsFlaggedAsSpread() throws {
        let w = try world(readings: [(10, 1), (20, 20), (30, 40)], work: [(10, 20_000_000)])
        let efficiency = try XCTUnwrap(try w.report(now: friday + 5 * day).currentCycle).efficiency
        XCTAssertEqual(efficiency.quality, .indicative, "two rises are less than the three a reliable ratio needs")

        let uneven = try world(readings: [(10, 1), (20, 20), (30, 40), (40, 60), (50, 80)],
                               work: [(10, 100_000_000), (30, 1_000_000), (50, 1_000_000), (70, 1_000_000)])
        let spread = try XCTUnwrap(try uneven.report(now: friday + 5 * day).currentCycle).efficiency
        XCTAssertTrue(spread.caveats.contains(.highStepVariability))
        XCTAssertEqual(spread.quality, .indicative, "a widely spread relationship is never called reliable")
    }

    private func identifiedReadings(_ w: IntelligenceWorld) throws {
        for (percent, at) in [(10.0, 1.0), (20, 30), (30, 60), (40, 90)] {
            try w.quota(percent, at: friday + at * hour, resets: friday + week, account: IntelligenceWorld.identified)
        }
    }

    func testNoRatioIsDerivedFromSessionsThatNameNoAccountForAnIdentifiedAccount() throws {
        let w = try IntelligenceWorld()
        try identifiedReadings(w)
        w.request(at: friday + 50 * hour, input: 0, output: 0, cacheRead: 30_000_000, cacheCreation: 0)
        try w.commit()
        let efficiency = try XCTUnwrap(try w.report(identified: true, now: friday + 5 * day).currentCycle).efficiency
        XCTAssertFalse(efficiency.isAvailable)
        XCTAssertEqual(efficiency.unavailable, [.localActivityNotAttributed])
        XCTAssertNil(efficiency.processedTokensPerPoint)
    }

    func testARatioFromSessionsThatNameTheAccountNeedsNoDisclosureOfGuessing() throws {
        let w = try IntelligenceWorld()
        try identifiedReadings(w)
        w.request(at: friday + 50 * hour, account: IntelligenceWorld.identified, input: 0, output: 0, cacheRead: 30_000_000, cacheCreation: 0)
        try w.commit()
        let efficiency = try XCTUnwrap(try w.report(identified: true, now: friday + 5 * day).currentCycle).efficiency
        XCTAssertTrue(efficiency.isAvailable)
        XCTAssertFalse(efficiency.caveats.contains(.activityAssociatedByUser))
        XCTAssertFalse(efficiency.caveats.contains(.neitherSideNamesAnAccount))
        XCTAssertEqual(efficiency.risePoints, 30)
    }

    func testAUserAssociationMakesTheRatioAvailableAndDisclosesIt() throws {
        let w = try IntelligenceWorld()
        try identifiedReadings(w)
        w.request(at: friday + 50 * hour, input: 0, output: 0, cacheRead: 30_000_000, cacheCreation: 0)
        try w.commit()
        let id = try XCTUnwrap(try w.db.read { c in try c.scalarInt("SELECT id FROM account WHERE hash = ?", [.text(IntelligenceWorld.identified.hash!)]) })
        _ = try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: id, from: friday, to: friday + week)
        let efficiency = try XCTUnwrap(try w.report(identified: true, now: friday + 5 * day).currentCycle).efficiency
        XCTAssertTrue(efficiency.isAvailable)
        XCTAssertTrue(efficiency.caveats.contains(.activityAssociatedByUser))
        XCTAssertEqual(try XCTUnwrap(efficiency.processedTokensPerPoint).value, 1_000_000, accuracy: 1e-6)
    }

    func testUnattributedWorkOutsideTheMeasuredIntervalDoesNotBlockTheRatio() throws {
        let w = try IntelligenceWorld()
        try identifiedReadings(w)
        w.request(at: friday + 50 * hour, account: IntelligenceWorld.identified, input: 0, output: 0, cacheRead: 30_000_000, cacheCreation: 0)
        w.request(at: friday + 0.5 * hour, session: "before", input: 0, output: 0, cacheRead: 900_000_000, cacheCreation: 0)
        try w.commit()
        let current = try XCTUnwrap(try w.report(identified: true, now: friday + 5 * day).currentCycle)
        XCTAssertTrue(current.efficiency.isAvailable, "the unattributed work happened before the first reading's last confirmation")
        XCTAssertEqual(current.attribution, .partlyAttributed, "it still lowers the attributed share of the cycle")
    }

    func testAPlanChangeBetweenTheReadingsWithholdsTheRatio() throws {
        let w = try world(readings: [(10, 1), (20, 30), (30, 60), (40, 90)], work: [(50, 30_000_000)])
        let accountID = try XCTUnwrap(try w.db.read { c in try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''") })
        _ = try PlanHistoryStore.create(w.db, PlanAssignmentDraft(provider: .anthropic, accountID: accountID, planKey: "claude-pro", accountLabel: nil,
                                                                  effectiveFrom: friday - 4 * week, effectiveTo: friday + 45 * hour))
        _ = try PlanHistoryStore.create(w.db, PlanAssignmentDraft(provider: .anthropic, accountID: accountID, planKey: "claude-max-5x", accountLabel: nil,
                                                                  effectiveFrom: friday + 45 * hour, effectiveTo: nil))
        let efficiency = try XCTUnwrap(try w.report(now: friday + 5 * day).currentCycle).efficiency
        XCTAssertEqual(efficiency.unavailable, [.planChangedWithinInterval], "an interval that straddles two plans measures neither")

        // The same readings on one plan are fine.
        let single = try world(readings: [(10, 1), (20, 30), (30, 60), (40, 90)], work: [(50, 30_000_000)])
        let id = try XCTUnwrap(try single.db.read { c in try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''") })
        _ = try PlanHistoryStore.create(single.db, PlanAssignmentDraft(provider: .anthropic, accountID: id, planKey: "claude-pro", accountLabel: nil,
                                                                       effectiveFrom: friday - 4 * week, effectiveTo: nil))
        XCTAssertTrue(try XCTUnwrap(try single.report(now: friday + 5 * day).currentCycle).efficiency.isAvailable)
    }

    func testAnUnassignedAccountsRatioSaysThatNeitherSideNamesAnAccount() throws {
        let w = try world(readings: [(10, 1), (20, 30), (30, 60), (40, 90)], work: [(50, 30_000_000)])
        let efficiency = try XCTUnwrap(try w.report(now: friday + 5 * day).currentCycle).efficiency
        XCTAssertTrue(efficiency.caveats.contains(.neitherSideNamesAnAccount))
        XCTAssertTrue(efficiency.caveats.contains(.planNotRecorded))
    }

    func testWorkDuringAStretchWhereTheValueDidNotChangeIsPartOfTheMeasurement() throws {
        // 20% is confirmed for two days with a large amount of work inside that stretch, and the rise to 30% comes later. The work
        // that moved nothing is not hidden, because a ratio that ignored it would overstate how little a point costs.
        let w = try world(readings: [(10, 1), (20, 5), (20, 53), (30, 60), (40, 90)],
                          work: [(10, 10_000_000), (30, 40_000_000), (70, 10_000_000)])
        let efficiency = try XCTUnwrap(try w.report(now: friday + 5 * day).currentCycle).efficiency
        XCTAssertEqual(efficiency.processedTokens, 60_000_000)
        XCTAssertEqual(efficiency.risePoints, 30)
        XCTAssertEqual(try XCTUnwrap(efficiency.processedTokensPerPoint).value, 2_000_000, accuracy: 1e-6)
    }

    func testTheCacheReadRatioAndTheModelMixOfTheMeasuredWorkAreVisible() throws {
        let w = try IntelligenceWorld()
        for (percent, at) in [(10.0, 1.0), (20, 30), (30, 60), (40, 90)] { try w.quota(percent, at: friday + at * hour, resets: friday + week) }
        w.request(at: friday + 40 * hour, model: "claude-opus-5-5", input: 0, output: 0, cacheRead: 20_000_000, cacheCreation: 0)
        w.request(at: friday + 70 * hour, model: "claude-sonnet-5-5", input: 5_000_000, output: 5_000_000, cacheRead: 0, cacheCreation: 0)
        try w.commit()
        let efficiency = try XCTUnwrap(try w.report(now: friday + 5 * day).currentCycle).efficiency
        XCTAssertEqual(efficiency.cacheReadTokens, 20_000_000)
        XCTAssertEqual(try XCTUnwrap(efficiency.cacheReadTokensPerPoint).value, 20_000_000 / 30, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(efficiency.cacheReadShare), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(efficiency.modelShares["claude-opus-5-5"]), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(efficiency.modelShares["claude-sonnet-5-5"]), 1.0 / 3.0, accuracy: 1e-9)
    }

    func testARatioFromSmallRoundedRisesIsNeverMoreStableThanTheRoundingAllows() throws {
        // A rise of 5 points can be a true rise of 4 to 6, so the ratio may differ by a fifth either way.
        let w = try world(readings: [(10, 1), (12, 10), (15, 30)], work: [(5, 30_000_000)])
        let ratio = try XCTUnwrap(try w.report(now: friday + 5 * day).currentCycle.map(\.efficiency).flatMap(\.processedTokensPerPoint))
        XCTAssertEqual(ratio.value, 6_000_000, accuracy: 1e-6)
        XCTAssertEqual(ratio.low, 5_000_000, accuracy: 1e-6)
        XCTAssertEqual(ratio.high, 7_500_000, accuracy: 1e-6)
        XCTAssertGreaterThan(ratio.high / ratio.low, 1.4, "the published range reflects how coarse the percentages are")
    }

    func testWorkTimelineAnswersRangeQueriesWithHalfOpenIntervals() throws {
        var timeline = WorkTimeline()
        for index in 0..<5 {
            timeline.append(at: Int64(index) * 1000, processed: 10, fresh: 4, costPicoUSD: 100, unpricedTokens: 0)
        }
        XCTAssertEqual(timeline.total(from: Date(timeIntervalSince1970: 1), to: Date(timeIntervalSince1970: 3)).processedTokens, 20,
                       "the requests at 1 s and 2 s, but not the one at 3 s")
        XCTAssertEqual(timeline.total(from: Date(timeIntervalSince1970: 3), to: Date(timeIntervalSince1970: 1)).requests, 0)
        XCTAssertEqual(timeline.total(from: Date(timeIntervalSince1970: -5), to: Date(timeIntervalSince1970: 99)).requests, 5)
    }
}

final class SubscriptionIntelligencePersistenceTests: XCTestCase {
    func testRebuildFromSourceKeepsQuotaAndPlanHistoryAndTheCycleStructureIsUnchanged() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        let accountID = try XCTUnwrap(try w.db.read { c in try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ''") })
        _ = try PlanHistoryStore.create(w.db, PlanAssignmentDraft(provider: .anthropic, accountID: accountID, planKey: "claude-max-5x", accountLabel: nil,
                                                                  effectiveFrom: friday - 4 * week, effectiveTo: nil))
        let before = try w.report(now: friday + day)
        try w.db.resetDerivedUsageData()
        let after = try w.report(now: friday + day)
        XCTAssertEqual(after.cycles.map(\.span), before.cycles.map(\.span))
        XCTAssertEqual(after.cycles.map(\.quota), before.cycles.map(\.quota), "the readings cannot be rebuilt from transcripts, so a rebuild must keep them")
        XCTAssertEqual(after.cycles.last?.plan?.key, "claude-max-5x")
        XCTAssertEqual(after.schedule, before.schedule)
    }

    func testTheReportIsTheSameAfterReopeningTheDatabase() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        w.request(at: friday + hour)
        try w.commit()
        let before = try w.report(now: friday + day)
        try w.env.reopen()
        XCTAssertEqual(try w.report(now: friday + day), before, "a restart changes no figure")
    }

    func testRetentionRemovesOldReadingsAndTheAnalysisSimplyHasLessHistory() throws {
        let w = try IntelligenceWorld()
        try w.twoWeeks()
        let cutoff = friday - day
        try w.db.purge(olderThanMs: Clock.ms(cutoff))
        let report = try w.report(now: friday + day)
        XCTAssertNotNil(report.currentCycle?.quota)
        let previous = try XCTUnwrap(report.cycles.first { $0.span.end == friday }?.quota)
        XCTAssertEqual(previous.readingCount, 1, "the reading older than the retention period is gone")
        XCTAssertEqual(previous.firstPercent, 60, "and nothing is invented in its place")
        XCTAssertFalse(previous.startObserved)
    }

    func testAnalysisOfAnEmptyDatabaseIsEmptyAndHasNoSubjects() throws {
        let w = try IntelligenceWorld()
        XCTAssertTrue(try SubscriptionUsageAnalyticsEngine.subjects(w.db).isEmpty)
    }
}
