import XCTest
@testable import UsageCore

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400
private let week: TimeInterval = 7 * day

/// Friday 2026-10-23 00:00:00 UTC, which is Friday 03:00 in UTC+3. Every date in these tests is an offset from it, so the
/// results do not depend on when the tests run.
private let friday = Date(timeIntervalSince1970: 1_792_713_600)
private let utcPlusThree = TimeZone(secondsFromGMT: 3 * 3600)!

private func cycle(_ id: Int64, reset: Date?, first: Date, last: Date, from firstPercent: Double? = nil, to lastPercent: Double? = nil) -> ObservedQuotaCycle {
    ObservedQuotaCycle(id: id, resetsAt: reset, firstObservedAt: first, lastObservedAt: last, firstPercent: firstPercent, lastPercent: lastPercent)
}

/// Two consecutive weekly cycles of a window that resets on Fridays at 00:00 UTC.
private func fridayCycles() -> [ObservedQuotaCycle] {
    [cycle(1, reset: friday, first: friday - week + 6 * hour, last: friday - hour),
     cycle(2, reset: friday + week, first: friday + hour, last: friday + 2 * day)]
}

final class QuotaCycleCalendarTests: XCTestCase {
    func testWeeklyResetOnFridayAtThreeInUTCPlusThreeIsRecognisedFromTwoObservedResets() throws {
        let now = friday + 2 * day
        let timeline = QuotaCycleCalendar.build(observed: fridayCycles(), windowMinutes: 10_080, now: now,
                                                projectBackTo: friday - 3 * week)
        XCTAssertEqual(timeline.schedule.state, .established)
        XCTAssertEqual(timeline.schedule.supportingResets, 2)
        XCTAssertEqual(timeline.schedule.period, week)
        XCTAssertEqual(timeline.schedule.anchor, friday + week)

        let local = try XCTUnwrap(timeline.schedule.wallClock(in: utcPlusThree))
        XCTAssertEqual(local.weekday, 6, "Friday")
        XCTAssertEqual(local.hour, 3)
        XCTAssertEqual(local.minute, 0)
        let utc = try XCTUnwrap(timeline.schedule.wallClock(in: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(utc.weekday, 6)
        XCTAssertEqual(utc.hour, 0, "the canonical time is Friday 00:00 UTC")

        // The week of the example in the specification: Friday 16 October 03:00 to Friday 23 October 03:00 in UTC+3.
        let previous = try XCTUnwrap(timeline.span(containing: friday - hour))
        XCTAssertEqual(previous.start, friday - week)
        XCTAssertEqual(previous.end, friday)
        XCTAssertEqual(previous.origin, .observed)
        XCTAssertEqual(timeline.nextExpectedReset(after: now), friday + week)
    }

    func testObservedAndProjectedCyclesAreDistinguishedAndProjectionsNeverCarryReadings() throws {
        let now = friday + 3 * week + 2 * day
        let timeline = QuotaCycleCalendar.build(observed: fridayCycles(), windowMinutes: 10_080, now: now,
                                                projectBackTo: friday - 3 * week)
        let observed = timeline.spans.filter { $0.origin == .observed }
        let projected = timeline.spans.filter { $0.origin == .projected }
        XCTAssertEqual(observed.count, 2)
        XCTAssertTrue(projected.allSatisfy { $0.storedCycleIDs.isEmpty }, "a calculated cycle has no stored readings")
        XCTAssertEqual(projected.count, 2 + 3, "two before the first observed cycle (back to the requested date), three after the last, the last containing now")
        XCTAssertEqual(try XCTUnwrap(timeline.span(containing: now)).origin, .projected)
        for (a, b) in zip(timeline.spans, timeline.spans.dropFirst()) {
            XCTAssertEqual(a.end, b.start, "the calculated cycles continue the observed ones without gaps or overlaps")
        }
        XCTAssertFalse(try XCTUnwrap(timeline.events.last).confirmed, "a calculated reset is never confirmed")
        XCTAssertTrue(timeline.events.contains { $0.kind == .scheduled && $0.confirmed && $0.at == friday })
    }

    func testAResetReportedOneSecondEarlyIsTheSameBoundaryAsTheWholeMinute() throws {
        let observed = [cycle(1, reset: friday.addingTimeInterval(-1), first: friday - week, last: friday - hour),
                        cycle(2, reset: friday + week - 1, first: friday + hour, last: friday + day)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: friday + day, projectBackTo: nil)
        XCTAssertEqual(timeline.spans.map(\.end), [friday, friday + week])
        XCTAssertEqual(timeline.schedule.state, .established, "23:59:59 and 00:00:00 are one schedule")
    }

    func testStoredCyclesWithResetsSecondsApartDescribeOneCycle() throws {
        let observed = [cycle(1, reset: friday, first: friday - week, last: friday - day),
                        cycle(2, reset: friday + 20, first: friday - day, last: friday - hour)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: friday - hour, projectBackTo: nil)
        XCTAssertEqual(timeline.spans.count, 1)
        XCTAssertEqual(Set(timeline.spans[0].storedCycleIDs), [1, 2])
    }

    func testOneObservedResetDoesNotEstablishAScheduleAndNothingIsProjected() throws {
        let observed = [cycle(1, reset: friday + week, first: friday + hour, last: friday + day)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: friday + 3 * week,
                                                projectBackTo: friday - 5 * week)
        XCTAssertEqual(timeline.schedule.state, .notEstablished)
        XCTAssertEqual(timeline.schedule.announcedResets, 1, "the interface can say that a second reset is still needed")
        XCTAssertNil(timeline.schedule.nextReset(after: friday))
        XCTAssertEqual(timeline.spans.count, 1)
        XCTAssertTrue(timeline.events.allSatisfy { !$0.confirmed })
    }

    func testAnotherAccountsResetTimeIsTakenFromItsOwnReadings() throws {
        let tuesdayEvening = friday + 4 * day + 14 * hour + 35 * 60
        let observed = [cycle(1, reset: tuesdayEvening, first: tuesdayEvening - week, last: tuesdayEvening - hour),
                        cycle(2, reset: tuesdayEvening + week, first: tuesdayEvening + hour, last: tuesdayEvening + day)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: tuesdayEvening + day, projectBackTo: nil)
        let clock = try XCTUnwrap(timeline.schedule.wallClock(in: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(clock.weekday, 3, "Tuesday")
        XCTAssertEqual(clock.hour, 14)
        XCTAssertEqual(clock.minute, 35)
    }

    func testChangingTheDisplayTimeZoneMovesNoBoundary() throws {
        let timeline = QuotaCycleCalendar.build(observed: fridayCycles(), windowMinutes: 10_080, now: friday + day, projectBackTo: nil)
        let losAngeles = try XCTUnwrap(timeline.schedule.wallClock(in: TimeZone(identifier: "America/Los_Angeles")!))
        XCTAssertEqual(losAngeles.weekday, 5, "Thursday evening there")
        XCTAssertEqual(losAngeles.hour, 17)
        XCTAssertEqual(timeline.spans.map(\.end), [friday, friday + week], "canonical boundaries stay in UTC")
    }

    func testCyclesStayExactlyOneWeekLongAcrossADaylightSavingChange() throws {
        // New York leaves daylight saving time on 2026-11-01, between the resets of 30 October and 6 November.
        let october30 = friday + week
        let observed = [cycle(1, reset: october30, first: october30 - week, last: october30 - hour),
                        cycle(2, reset: october30 + week, first: october30 + hour, last: october30 + day),
                        cycle(3, reset: october30 + 2 * week, first: october30 + week + hour, last: october30 + week + day)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: october30 + week + day,
                                                projectBackTo: nil)
        XCTAssertTrue(timeline.spans.allSatisfy { $0.length == week }, "a subscription week is 168 hours of elapsed time")
        let newYork = TimeZone(identifier: "America/New_York")!
        let before = ResetSchedule(state: .established, period: week, anchor: october30, supportingResets: 2)
        let after = ResetSchedule(state: .established, period: week, anchor: october30 + week, supportingResets: 2)
        XCTAssertEqual(before.wallClock(in: newYork)?.hour, 20, "Thursday 20:00 EDT")
        XCTAssertEqual(after.wallClock(in: newYork)?.hour, 19, "the same UTC schedule reads 19:00 EST after the change")
    }

    func testAScheduleThatMovesIsReportedAsAChangeAndThenReestablished() throws {
        let observed = [cycle(1, reset: friday - 2 * week, first: friday - 3 * week, last: friday - 2 * week - hour),
                        cycle(2, reset: friday - week, first: friday - 2 * week + hour, last: friday - week - hour),
                        cycle(3, reset: friday, first: friday - week + hour, last: friday - hour),
                        // The next window ends three hours later than a weekly schedule would put it, with a gap before it.
                        cycle(4, reset: friday + week + 3 * hour, first: friday + 3 * hour + 600, last: friday + 2 * day),
                        cycle(5, reset: friday + 2 * week + 3 * hour, first: friday + week + 4 * hour, last: friday + week + day)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: friday + week + day, projectBackTo: nil)
        let change = try XCTUnwrap(timeline.events.first { $0.kind == .scheduleChange })
        XCTAssertEqual(change.at, friday + 3 * hour, "the new window began three hours after the old one ended")
        XCTAssertTrue(change.confirmed)
        XCTAssertEqual(timeline.schedule.anchor, friday + 2 * week + 3 * hour)
        XCTAssertEqual(timeline.schedule.wallClock(in: TimeZone(identifier: "UTC")!)?.hour, 3)
        XCTAssertFalse(timeline.events.contains { $0.kind == .exceptional })
    }

    func testAnEarlyResetIsExceptionalAndNeverBecomesNegativeConsumption() throws {
        // The first cycle was last seen on Tuesday and was due to reset on Friday. The next window was seen two hours later
        // with a reset a week after its own start.
        let tuesday = friday - 3 * day
        let observed = [cycle(1, reset: friday, first: friday - week + hour, last: tuesday, from: 1, to: 60),
                        cycle(2, reset: tuesday + 2 * hour + week, first: tuesday + 2 * hour, last: tuesday + day, from: 2, to: 5)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: tuesday + day, projectBackTo: nil)
        XCTAssertEqual(timeline.spans.count, 2)
        let first = timeline.spans[0], second = timeline.spans[1]
        XCTAssertTrue(first.endedEarly)
        XCTAssertEqual(first.reportedReset, friday, "the reset it announced is kept for comparison")
        XCTAssertEqual(first.earlyResetBounds, tuesday...(tuesday + 2 * hour))
        XCTAssertEqual(first.end, second.start, "the cycles never overlap")
        let event = try XCTUnwrap(timeline.events.first { $0.kind == .exceptional })
        XCTAssertTrue(event.confirmed)
        XCTAssertEqual(event.earliest, tuesday)
        XCTAssertEqual(event.latest, tuesday + 2 * hour)
        XCTAssertFalse(timeline.events.contains { $0.kind == .scheduled && $0.at == friday }, "the due reset never happened")
    }

    func testAnAnnouncedFutureResetIsNotAConfirmedReset() throws {
        // On Friday morning the provider has announced the reset of the next Friday. Nothing has happened at that time yet.
        let now = friday + 2 * day
        let timeline = QuotaCycleCalendar.build(observed: fridayCycles(), windowMinutes: 10_080, now: now, projectBackTo: nil)
        XCTAssertEqual(timeline.schedule.state, .established)
        XCTAssertEqual(timeline.schedule.announcedResets, 2)
        XCTAssertEqual(timeline.schedule.confirmedResets, 1, "only the reset after which the next window was seen is confirmed")
        XCTAssertEqual(timeline.schedule.confidence, .provisional)
        let announced = try XCTUnwrap(timeline.events.first { $0.at == friday + week })
        XCTAssertEqual(announced.kind, .expected)
        XCTAssertFalse(announced.confirmed, "a reset in the future cannot have been confirmed")
        XCTAssertEqual(timeline.events.filter(\.confirmed).map(\.at), [friday])
    }

    func testAWindowObservedOnlyBeforeItsAnnouncedResetHasNoConfirmedReset() throws {
        let observed = [cycle(1, reset: friday + week, first: friday + hour, last: friday + 3 * day)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: friday + 3 * day, projectBackTo: friday - 4 * week)
        XCTAssertEqual(timeline.schedule.confidence, .none)
        XCTAssertEqual(timeline.schedule.announcedResets, 1)
        XCTAssertEqual(timeline.schedule.confirmedResets, 0)
        XCTAssertTrue(timeline.events.allSatisfy { !$0.confirmed })
        XCTAssertEqual(timeline.spans.count, 1, "a single announcement calculates no other cycle")
    }

    func testTwoConfirmedResetsRaiseTheConfidenceOfTheSchedule() throws {
        let observed = fridayCycles() + [cycle(3, reset: friday + 2 * week, first: friday + week + 2 * hour, last: friday + week + day)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: friday + week + day, projectBackTo: nil)
        XCTAssertEqual(timeline.schedule.confirmedResets, 2)
        XCTAssertEqual(timeline.schedule.confidence, .confirmed)
        XCTAssertEqual(timeline.schedule.announcedResets, 3)
    }

    func testAChangedAnnouncementForTheSameWindowIsNotAResetAndNotExceptional() throws {
        // The provider announced Friday, and later, while the utilization kept rising, announced three hours after that.
        let observed = [cycle(1, reset: friday, first: friday - week + hour, last: friday - 2 * day, from: 20, to: 40),
                        cycle(2, reset: friday + 3 * hour, first: friday - 2 * day + hour, last: friday - hour, from: 41, to: 55)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: friday - hour, projectBackTo: nil)
        XCTAssertEqual(timeline.spans.count, 1, "one window, announced twice")
        XCTAssertEqual(Set(timeline.spans[0].storedCycleIDs), [1, 2])
        XCTAssertTrue(timeline.spans[0].resetAnnouncementChanged)
        XCTAssertFalse(timeline.spans[0].endedEarly)
        XCTAssertEqual(timeline.spans[0].end, friday + 3 * hour, "the newest announcement wins")
        XCTAssertTrue(timeline.events.contains { $0.kind == .announcementChanged })
        XCTAssertFalse(timeline.events.contains { $0.kind == .exceptional })
    }

    func testAnEarlyResetNeedsALowerUtilizationAndRoundingIsNotEnough() throws {
        let tuesday = friday - 3 * day
        func early(afterPercent: Double) -> QuotaCycleTimeline {
            QuotaCycleCalendar.build(observed: [cycle(1, reset: friday, first: friday - week + hour, last: tuesday, from: 1, to: 60),
                                                cycle(2, reset: tuesday + 2 * hour + week, first: tuesday + 2 * hour, last: tuesday + day, from: afterPercent, to: afterPercent + 3)],
                                     windowMinutes: 10_080, now: tuesday + day, projectBackTo: nil)
        }
        XCTAssertTrue(early(afterPercent: 2).events.contains { $0.kind == .exceptional }, "60% fell to 2%")
        XCTAssertFalse(early(afterPercent: 60).events.contains { $0.kind == .exceptional }, "no fall, so no reset")
        XCTAssertFalse(early(afterPercent: 59.7).events.contains { $0.kind == .exceptional }, "a fall of less than half a point is rounding")
    }

    func testReadingsOfTwoWindowsTakenAtTheSameTimeAreConflictingNotASequence() throws {
        let observed = [cycle(1, reset: friday, first: friday - week + hour, last: friday - hour, from: 10, to: 50),
                        cycle(2, reset: friday + week, first: friday - 3 * hour, last: friday + day, from: 5, to: 8)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: friday + day, projectBackTo: nil)
        XCTAssertTrue(timeline.events.contains { $0.kind == .conflicting })
        XCTAssertTrue(timeline.spans.allSatisfy(\.overlapsAnotherWindow))
        XCTAssertFalse(timeline.events.contains { $0.kind == .exceptional || $0.kind == .scheduled })
        XCTAssertEqual(timeline.schedule.state, .notEstablished)
        for (a, b) in zip(timeline.spans, timeline.spans.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
    }

    func testAWindowSeenAfterTheResetWithAShorterAnnouncedLengthIsIrregularNotAnEarlyReset() throws {
        // The next window was first seen two hours after the announced reset, and announces a reset five days later.
        let reset = friday
        let observed = [cycle(1, reset: reset, first: reset - week + hour, last: reset - 3 * day, from: 10, to: 30),
                        cycle(2, reset: reset + 5 * day, first: reset + 2 * hour, last: reset + 2 * day, from: 0, to: 12)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: reset + 2 * day, projectBackTo: nil)
        let event = try XCTUnwrap(timeline.events.first { $0.kind == .irregularWindow })
        XCTAssertTrue(event.confirmed, "a new window was seen after the announced reset")
        XCTAssertFalse(timeline.events.contains { $0.kind == .exceptional })
        XCTAssertFalse(timeline.spans.contains(where: \.endedEarly))
        XCTAssertEqual(timeline.spans[1].start, reset, "the window cannot have begun before the previous one's announced reset")
        XCTAssertTrue(timeline.spans[1].startIsEarliestPossible)
        XCTAssertEqual(timeline.schedule.state, .notEstablished)
    }

    func testCyclesWithoutAResetTimeProduceNoBoundary() throws {
        let observed = [cycle(1, reset: nil, first: friday, last: friday + hour)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 300, now: friday + 2 * hour, projectBackTo: nil)
        XCTAssertTrue(timeline.spans.isEmpty)
        XCTAssertEqual(timeline.schedule.state, .notEstablished)
    }

    func testFiveHourWindowsKeepTheirReportedBoundariesAndAreNeverFilledIn() throws {
        // The resets are not a multiple of five hours apart, which is what windows that start with a first request look like.
        let first = friday + 5 * hour + 9 * 60
        let second = first + 6 * hour + 40 * 60
        let third = second + 5 * hour + 3 * 60
        let observed = [cycle(1, reset: first, first: first - 4 * hour, last: first - 600),
                        cycle(2, reset: second, first: second - 4 * hour, last: second - 600),
                        cycle(3, reset: third, first: third - 4 * hour, last: third - 600)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 300, now: third + hour, projectBackTo: friday - day)
        XCTAssertEqual(timeline.schedule.state, .notEstablished)
        XCTAssertEqual(timeline.spans.count, 3, "no cycles are calculated for the idle stretches between sessions")
        XCTAssertTrue(timeline.spans.allSatisfy { $0.length == 5 * hour && $0.origin == .observed })
        XCTAssertTrue(timeline.spans.dropFirst().allSatisfy(\.startedAfterIdleGap))
        XCTAssertTrue(timeline.events.contains { $0.kind == .reanchored })
        XCTAssertNil(timeline.span(containing: second - 5 * hour - 3600), "the idle time before a window belongs to no window")
    }

    func testShortWindowsNeedTwoMatchingPairsBeforeTheyCountAsAScheduleAndOnePairIsCoincidence() throws {
        let a = friday + 2 * hour
        let twoResets = [cycle(1, reset: a, first: a - 4 * hour, last: a - 600), cycle(2, reset: a + 5 * hour, first: a + 3600, last: a + 4 * hour)]
        XCTAssertEqual(QuotaCycleCalendar.build(observed: twoResets, windowMinutes: 300, now: a + 6 * hour, projectBackTo: nil).schedule.state,
                       .notEstablished)
        let threeResets = twoResets + [cycle(3, reset: a + 10 * hour, first: a + 5 * hour + 3600, last: a + 9 * hour)]
        XCTAssertEqual(QuotaCycleCalendar.build(observed: threeResets, windowMinutes: 300, now: a + 11 * hour, projectBackTo: nil).schedule.state,
                       .established)
    }

    func testHalfOpenBoundariesAssignTheInstantOfAResetToTheNewCycle() throws {
        let timeline = QuotaCycleCalendar.build(observed: fridayCycles(), windowMinutes: 10_080, now: friday + day, projectBackTo: nil)
        XCTAssertEqual(timeline.span(containing: friday)?.start, friday, "the reset instant belongs to the new cycle")
        XCTAssertEqual(timeline.span(containing: friday - 0.001)?.end, friday)
        XCTAssertTrue(timeline.spans[0].contains(friday - week))
        XCTAssertFalse(timeline.spans[0].contains(friday))
    }

    func testMissingCyclesBetweenTwoObservedOnesAreCalculatedOnlyOnAnEstablishedSchedule() throws {
        let observed = [cycle(1, reset: friday, first: friday - week, last: friday - hour),
                        cycle(2, reset: friday + 3 * week, first: friday + 2 * week + hour, last: friday + 3 * week - hour)]
        let timeline = QuotaCycleCalendar.build(observed: observed, windowMinutes: 10_080, now: friday + 3 * week - day, projectBackTo: nil)
        XCTAssertEqual(timeline.spans.map(\.origin), [.observed, .projected, .projected, .observed])
        XCTAssertEqual(timeline.spans.map(\.start), [friday - week, friday, friday + week, friday + 2 * week])
    }
}

final class QuotaCurveTests: XCTestCase {
    private func point(_ percent: Double, _ first: TimeInterval, _ last: TimeInterval) -> QuotaReadingPoint {
        QuotaReadingPoint(percent: percent, firstObservedAt: friday + first * hour, lastConfirmedAt: friday + last * hour)
    }

    private var curve: QuotaCurve { QuotaCurve(readings: [point(10, 2, 4), point(20, 10, 12)]) }

    func testAValueIsExactInsideItsConfirmedSpanAndBracketedBetweenSpans() throws {
        XCTAssertEqual(curve.bounds(at: friday + 3 * hour), QuotaBounds(lower: 10, upper: 10, basis: .exact))
        XCTAssertEqual(curve.bounds(at: friday + 4 * hour)?.basis, .exact, "the last confirmation is inclusive")
        XCTAssertEqual(curve.bounds(at: friday + 7 * hour), QuotaBounds(lower: 10, upper: 20, basis: .bracketed))
        XCTAssertEqual(curve.bounds(at: friday + 1 * hour), QuotaBounds(lower: 0, upper: 10, basis: .beforeFirstObservation))
        XCTAssertEqual(curve.bounds(at: friday + 30 * hour), QuotaBounds(lower: 20, upper: 100, basis: .afterLastObservation))
    }

    func testAChangeIsExactOnlyWhenBothEndsWereObservedAndNeverInterpolated() throws {
        XCTAssertEqual(curve.change(from: friday + 3 * hour, to: friday + 11 * hour), .exact(10))
        XCTAssertEqual(curve.change(from: friday + 3 * hour, to: friday + 7 * hour), .between(0, 10),
                       "the rise happened somewhere after the first span; its size is bracketed, not guessed")
        XCTAssertEqual(curve.change(from: friday + 1 * hour, to: friday + 11 * hour), .unavailable, "the start is before any reading")
        XCTAssertEqual(curve.change(from: friday + 3 * hour, to: friday + 40 * hour), .unavailable, "the end is after the last reading")
    }

    func testACycleThatReachedTheLimitStaysAtTheLimit() throws {
        let capped = QuotaCurve(readings: [point(90, 0, 5), point(100, 6, 8)])
        XCTAssertEqual(capped.bounds(at: friday + 40 * hour), QuotaBounds(lower: 100, upper: 100, basis: .exact))
        XCTAssertEqual(capped.change(from: friday + 2 * hour, to: friday + 40 * hour), .exact(10))
    }

    func testALowerReadingInTheSameCycleIsIgnoredNotTreatedAsAReset() throws {
        let curve = QuotaCurve(readings: [point(30, 0, 2), point(50, 5, 6), point(40, 8, 9)])
        XCTAssertEqual(curve.points.map(\.percent), [30, 50])
        XCTAssertEqual(curve.issues, [.decreasedReadingIgnored(percent: 40, at: friday + 8 * hour)])
        XCTAssertEqual(curve.maximum, 50)
    }

    func testConfirmationsOfAnEarlierValueAreClippedWhereAHigherValueBegins() throws {
        // The same value was stored as confirmed after a higher value had been seen, as a late report could do.
        let curve = QuotaCurve(readings: [point(30, 0, 9), point(50, 5, 6)])
        XCTAssertEqual(curve.points[0].lastConfirmedAt, friday + 5 * hour)
        XCTAssertEqual(curve.issues, [.overlappingConfirmationClipped(percent: 30)])
        XCTAssertEqual(curve.bounds(at: friday + 7 * hour)?.lower, 50)
    }

    func testReadingsAreOrderedByObservationTimeWhateverTheStorageOrder() throws {
        let shuffled = QuotaCurve(readings: [point(20, 10, 12), point(10, 2, 4)])
        XCTAssertEqual(shuffled, curve)
    }

    func testATruncatedCurveForgetsEverythingObservedLater() throws {
        let early = curve.truncated(at: friday + 3 * hour)
        XCTAssertEqual(early.points.count, 1)
        XCTAssertEqual(early.points[0].lastConfirmedAt, friday + 3 * hour, "a confirmation after the cut did not exist yet")
        XCTAssertEqual(early.bounds(at: friday + 11 * hour)?.basis, .afterLastObservation)
    }

    func testGapAndExactDurationDescribeHowMuchWasObserved() throws {
        XCTAssertEqual(curve.largestGap, 6 * hour)
        XCTAssertEqual(curve.exactDuration, 4 * hour)
    }
}

final class CycleCoverageTests: XCTestCase {
    private let span = QuotaCycleSpan(start: friday, end: friday + week, origin: .observed)
    private func point(_ percent: Double, _ first: TimeInterval, _ last: TimeInterval, count: Int? = nil, pause: TimeInterval? = nil) -> QuotaReadingPoint {
        QuotaReadingPoint(percent: percent, firstObservedAt: friday + first * hour, lastConfirmedAt: friday + last * hour,
                          confirmations: count, longestPause: pause.map { $0 * hour })
    }

    func testALongSpanThatOnlyTwoObservationsBoundIsDeterminedButNotSupported() throws {
        // 3% was seen at hour 1 and again at hour 73. The value is known for those three days, but nothing says that anyone looked.
        let curve = QuotaCurve(readings: [point(3, 1, 73, count: 2, pause: 72)])
        let coverage = CycleCoverage.compute(curve: curve, span: span, now: friday + week)
        XCTAssertEqual(coverage.determinedFraction, 72.0 / 168, accuracy: 1e-9)
        XCTAssertLessThan(coverage.supportedFraction, coverage.determinedFraction / 2, "a span with a 72 h pause is not supported by observations")
        XCTAssertEqual(coverage.longestUnchangedStretch, 72 * hour)
        XCTAssertEqual(coverage.longestObservationPause, 72 * hour)
        XCTAssertEqual(coverage.observationCount, 2)
    }

    func testTheSameSpanSupportedByManyCloseObservationsIsFullySupported() throws {
        let curve = QuotaCurve(readings: [point(3, 1, 73, count: 40, pause: 3)])
        let coverage = CycleCoverage.compute(curve: curve, span: span, now: friday + week)
        XCTAssertEqual(coverage.supportedFraction, coverage.determinedFraction, accuracy: 1e-9)
        XCTAssertEqual(coverage.observationCount, 40)
    }

    func testAnUnchangedStretchIsNotACollectionGapAndAnUnseenRiseIs() throws {
        // 3% for three days, then 30% three days later: the first stretch is quiet, the second may hide a rise.
        let curve = QuotaCurve(readings: [point(3, 1, 73, count: 40, pause: 3), point(30, 150, 160, count: 5, pause: 3)])
        let coverage = CycleCoverage.compute(curve: curve, span: span, now: friday + week)
        XCTAssertEqual(coverage.longestUnchangedStretch, 72 * hour)
        XCTAssertEqual(coverage.largestUnresolvedGap, 77 * hour, "between 73 h and 150 h the value rose and the rise was not seen")
        XCTAssertFalse(coverage.hasReliableFullCycleResult)
    }

    func testTimeBeforeTheFirstAndAfterTheLastReadingIsUnresolved() throws {
        let curve = QuotaCurve(readings: [point(10, 50, 60, count: 10, pause: 2), point(20, 61, 100, count: 20, pause: 2)])
        let coverage = CycleCoverage.compute(curve: curve, span: span, now: friday + week)
        XCTAssertEqual(coverage.firstObservationDelay, 50 * hour)
        XCTAssertEqual(coverage.lastObservationLead, 68 * hour)
        XCTAssertEqual(coverage.largestUnresolvedGap, 68 * hour)
        XCTAssertFalse(coverage.hasReliableFullCycleResult)
    }

    func testAnUnknownCountMakesTheTotalUnknownInsteadOfAnInvention() throws {
        let curve = QuotaCurve(readings: [point(3, 1, 10, count: 4, pause: 1), point(5, 12, 20)])
        let coverage = CycleCoverage.compute(curve: curve, span: span, now: friday + week)
        XCTAssertNil(coverage.observationCount)
        XCTAssertNil(coverage.longestObservationPause)
    }

    func testAFullyObservedEndedCycleHasAReliableResultAndACycleInProgressNever() throws {
        var readings: [QuotaReadingPoint] = [point(0, 0.5, 6, count: 10, pause: 1)]
        for step in 1..<27 { readings.append(point(Double(step), Double(step) * 6 + 0.5, Double(step) * 6 + 5.5, count: 10, pause: 1)) }
        readings.append(point(30, 166, 167.9, count: 5, pause: 1))
        let curve = QuotaCurve(readings: readings)
        XCTAssertTrue(CycleCoverage.compute(curve: curve, span: span, now: friday + week + hour).hasReliableFullCycleResult)
        XCTAssertFalse(CycleCoverage.compute(curve: curve, span: span, now: friday + 100 * hour).hasReliableFullCycleResult, "the cycle has not ended")
    }

    func testMergingTwoSightingsOfOneValueAddsTheirCountsAndKeepsTheLongestPause() throws {
        let merged = QuotaCurve(readings: [point(3, 1, 5, count: 3, pause: 2), point(3, 20, 22, count: 2, pause: 1)])
        XCTAssertEqual(merged.points.count, 1)
        XCTAssertEqual(merged.points[0].confirmations, 5)
        XCTAssertEqual(merged.points[0].longestPause, 15 * hour, "the pause between the two sightings counts")
    }
}
