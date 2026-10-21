import XCTest
@testable import UsageCore
@testable import UsageUI

final class OverviewLogicTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Tuesday 20 October 2026, 16:17 UTC.
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 16, minute: 17))! }
    private func day(_ d: Int, _ h: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }

    func testPeriodsAndWhatTheyAreComparedWith() {
        XCTAssertEqual(OverviewPeriod.today.current(now: now, calendar: cal).from, day(20))
        XCTAssertNil(OverviewPeriod.today.current(now: now, calendar: cal).to)
        let yesterday = OverviewPeriod.today.previous(now: now, calendar: cal)
        XCTAssertEqual(yesterday.from, day(19))
        XCTAssertEqual(yesterday.to, now.addingTimeInterval(-86_400), "today is compared with yesterday up to the same time")

        XCTAssertEqual(OverviewPeriod.week.current(now: now, calendar: cal).from, day(14))
        let before = OverviewPeriod.week.previous(now: now, calendar: cal)
        XCTAssertEqual(before.from, day(7))
        XCTAssertEqual(before.to, day(14))

        XCTAssertEqual(OverviewPeriod.month.current(now: now, calendar: cal).from, cal.date(byAdding: .day, value: -29, to: day(20)))
        XCTAssertEqual(OverviewPeriod.month.bucketStarts(now: now, calendar: cal).count, 30)
        XCTAssertEqual(OverviewPeriod.week.bucketStarts(now: now, calendar: cal).last, day(20))
    }

    func testBucketsSplitByProviderAndMarkTheFuture() {
        let points = [
            SeriesPoint(start: day(20, 9), key: "anthropic", label: "", tokens: TokenCounts(uncachedInput: 10, output: 5, cacheRead: 100), requests: 1, cost: .zero),
            SeriesPoint(start: day(20, 9), key: "openai", label: "", tokens: TokenCounts(uncachedInput: 7), requests: 1, cost: .zero),
            SeriesPoint(start: day(20, 16), key: "anthropic", label: "", tokens: TokenCounts(output: 3), requests: 1, cost: .zero),
            SeriesPoint(start: day(19, 23), key: "anthropic", label: "", tokens: TokenCounts(output: 99), requests: 1, cost: .zero),
        ]
        let b = OverviewLogic.buckets(period: .today, now: now, calendar: cal, points: points, sessions: [(day(20, 9), 2)])
        XCTAssertEqual(b.count, 24)
        XCTAssertEqual(b[9].fresh[ProviderID(rawValue: "anthropic")], 15, "cache reads are not new tokens")
        XCTAssertEqual(b[9].fresh[ProviderID(rawValue: "openai")], 7)
        XCTAssertEqual(b[9].totalFresh, 22)
        XCTAssertEqual(b[9].cacheRead, 100)
        XCTAssertEqual(b[9].sessions, 2)
        XCTAssertTrue(b[16].isCurrent)
        XCTAssertFalse(b[16].isFuture)
        XCTAssertTrue(b[17].isFuture)
        XCTAssertEqual(b.reduce(0) { $0 + $1.totalFresh }, 25, "a point from yesterday is dropped")
        XCTAssertEqual(OverviewLogic.defaultSelection(b), 16, "the current hour is selected first")
    }

    func testChartScaleAndLabels() {
        XCTAssertEqual(OverviewLogic.niceCeiling(0), 1)
        XCTAssertEqual(OverviewLogic.niceCeiling(830_000), 1_000_000)
        XCTAssertEqual(OverviewLogic.niceCeiling(1_700_000), 2_000_000)
        XCTAssertEqual(OverviewLogic.niceCeiling(2_300_000), 2_500_000)
        XCTAssertEqual(OverviewLogic.niceCeiling(4_100), 5_000)
        let b = OverviewLogic.buckets(period: .month, now: now, calendar: cal, points: [], sessions: [])
        XCTAssertEqual(OverviewLogic.shortLabel(b[29], period: .month, count: 30, selected: false, calendar: cal), "20")
        XCTAssertEqual(OverviewLogic.shortLabel(b[28], period: .month, count: 30, selected: false, calendar: cal), "")
        XCTAssertEqual(OverviewLogic.shortLabel(b[28], period: .month, count: 30, selected: true, calendar: cal), "19")
        XCTAssertEqual(OverviewLogic.shortLabel(b[24], period: .month, count: 30, selected: false, calendar: cal), "15")
    }

    func testChangeAgainstThePreviousPeriod() {
        XCTAssertEqual(OverviewLogic.changeText(current: 123, previous: 100, period: .today), "↑ 23% more than yesterday by this time.")
        XCTAssertEqual(OverviewLogic.changeText(current: 60, previous: 100, period: .week), "↓ 40% less than the 7 days before.")
        XCTAssertEqual(OverviewLogic.changeText(current: 103, previous: 100, period: .month), "About the same as the 30 days before.")
        XCTAssertEqual(OverviewLogic.changeText(current: 5, previous: 0, period: .today), "Nothing yesterday by this time to compare with.")
    }

    func testWindowOutlook() {
        let length: TimeInterval = 5 * 3600
        // 64% used with 102 minutes left: 198 minutes in, so the rest lasts another 111 minutes.
        let calm = WindowOutlook.evaluate(used: 64, resetsAt: now.addingTimeInterval(102 * 60), length: length, now: now)
        XCTAssertEqual(calm.level, .good)
        XCTAssertEqual(calm.status, "Plenty left")
        XCTAssertNil(calm.runsOutAt)

        // 91% used with 102 minutes left runs out about 20 minutes from now.
        let hot = WindowOutlook.evaluate(used: 91, resetsAt: now.addingTimeInterval(102 * 60), length: length, now: now)
        XCTAssertEqual(hot.level, .critical)
        XCTAssertEqual(hot.status, "Will run out before it resets")
        XCTAssertEqual(hot.runsOutAt!.timeIntervalSince(now) / 60, 19.6, accuracy: 0.1)

        XCTAssertEqual(WindowOutlook.evaluate(used: 80, resetsAt: nil, length: nil, now: now).status, "Getting close")
        XCTAssertEqual(WindowOutlook.evaluate(used: 100, resetsAt: nil, length: nil, now: now).status, "Limit reached")
        let early = WindowOutlook.evaluate(used: 5, resetsAt: now.addingTimeInterval(length - 60), length: length, now: now)
        XCTAssertNil(early.runsOutAt, "no projection is made in the first minutes of a window")
    }

    func testTimesInWords() {
        XCTAssertEqual(Fmt.spokenDuration(102 * 60), "1 h 42 min")
        XCTAssertEqual(Fmt.spokenDuration(45 * 60), "45 min")
        XCTAssertEqual(Fmt.spokenDuration(2 * 3600), "2 h")
        XCTAssertEqual(Fmt.spokenDuration(40 * 3600 + 43 * 60), "1 d 16 h")
        XCTAssertTrue(OverviewLogic.clock(day(20, 18), now: now, calendar: cal).hasPrefix("at "))
        XCTAssertTrue(OverviewLogic.clock(day(21, 9), now: now, calendar: cal).hasPrefix("tomorrow at "))
        XCTAssertTrue(OverviewLogic.clock(day(23, 9), now: now, calendar: cal).hasPrefix("on "))
        XCTAssertEqual(OverviewLogic.lastActive(day(19, 10), now: now, calendar: cal), "Yesterday")
        XCTAssertEqual(OverviewLogic.lastActive(nil, now: now, calendar: cal), "Unknown")
    }
}
