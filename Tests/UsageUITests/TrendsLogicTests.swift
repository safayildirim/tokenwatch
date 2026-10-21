import XCTest
@testable import UsageCore
@testable import UsageUI

final class TrendsLogicTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Tuesday 20 October 2026, 16:17 UTC.
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 16, minute: 17))! }
    private func day(_ d: Int, _ h: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }

    private func point(_ start: Date, _ key: String, output: Int64, cacheRead: Int64 = 0, requests: Int = 1) -> SeriesPoint {
        SeriesPoint(start: start, key: key, label: key.uppercased(), tokens: TokenCounts(output: output, cacheRead: cacheRead),
                    requests: requests, cost: .zero)
    }

    func testTotalsPerDay() {
        let points = [point(day(19, 3), "", output: 10, cacheRead: 100), point(day(19, 9), "", output: 5), point(day(20, 1), "", output: 7)]
        let r = TrendsLogic.build(period: .week, now: now, calendar: cal, measure: .fresh, split: .total, points: points, sessions: [])
        XCTAssertEqual(r.series.map(\.id), ["total"])
        XCTAssertEqual(r.buckets.count, 7)
        XCTAssertEqual(r.buckets[5].values["total"], 15, "points of one day add up, and cache reads are not new tokens")
        XCTAssertEqual(r.buckets[6].values["total"], 7)
        let processed = TrendsLogic.build(period: .week, now: now, calendar: cal, measure: .processed, split: .total, points: points, sessions: [])
        XCTAssertEqual(processed.buckets[5].values["total"], 115)
    }

    func testSplitKeepsTheLargestSeriesAndFoldsTheRest() {
        let points = (0..<9).map { point(day(20, 9), "m\($0)", output: Int64(100 - $0)) }
        let r = TrendsLogic.build(period: .today, now: now, calendar: cal, measure: .fresh, split: .model, points: points, sessions: [])
        XCTAssertEqual(r.series.count, TrendsLogic.maxSeries)
        XCTAssertEqual(r.series.first?.id, "m0", "the largest series comes first, at the bottom of the stack")
        XCTAssertEqual(r.series.last?.id, "other")
        XCTAssertEqual(r.series.first?.name, "M0")
        XCTAssertEqual(r.buckets[9].values["other"], Double(94 + 93 + 92), "the three smallest models are folded")
        XCTAssertEqual(r.buckets[9].total, Double((92...100).reduce(0, +)), "folding loses nothing")
    }

    func testSessionsAreNeverSplit() {
        let r = TrendsLogic.build(period: .today, now: now, calendar: cal, measure: .sessions, split: .model,
                                  points: [point(day(20, 9), "m", output: 5)], sessions: [(day(20, 9), 3)])
        XCTAssertEqual(r.series.map(\.id), ["total"])
        XCTAssertEqual(r.buckets[9].values["total"], 3)
        XCTAssertEqual(TrendSplit.choices(for: .sessions), [.total])
        XCTAssertFalse(TrendSplit.choices(for: .cost).contains(.category), "token types only split token measures")
    }

    func testTokenTypesIncludeCacheReadsOnlyWhenProcessed() {
        let points = [point(day(20, 9), "", output: 5, cacheRead: 50)]
        let fresh = TrendsLogic.build(period: .today, now: now, calendar: cal, measure: .fresh, split: .category, points: points, sessions: [])
        XCTAssertFalse(fresh.series.contains { $0.id == "cacheRead" })
        let processed = TrendsLogic.build(period: .today, now: now, calendar: cal, measure: .processed, split: .category, points: points, sessions: [])
        XCTAssertEqual(processed.buckets[9].values["cacheRead"], 50)
        XCTAssertEqual(processed.buckets[9].total, 55)
    }

    func testChangesAgainstThePreviousPeriod() {
        let current = [TrendRow(id: "a", name: "Alpha", color: .project("1"), value: 300),
                       TrendRow(id: "b", name: "Beta", color: .project("2"), value: 50),
                       TrendRow(id: "c", name: "Gamma", color: .project("3"), value: 10)]
        let previous = [TrendRow(id: "a", name: "Alpha", color: .project("1"), value: 100),
                        TrendRow(id: "b", name: "Beta", color: .project("2"), value: 50),
                        TrendRow(id: "d", name: "Delta", color: .project("4"), value: 80)]
        let changes = TrendsLogic.changes(current: current, previous: previous)
        XCTAssertEqual(changes.map(\.id), ["a", "d", "c"], "largest move first; an unchanged row is left out")
        XCTAssertEqual(TrendsLogic.changeLabel(changes[0]), "↑ 200%")
        XCTAssertEqual(TrendsLogic.changeLabel(changes[1]), "None now")
        XCTAssertEqual(TrendsLogic.changeLabel(changes[2]), "New")
    }

    func testFormatsAndScale() {
        XCTAssertEqual(TrendMeasure.fresh.format(1_234_567), "1.23M")
        XCTAssertEqual(TrendMeasure.requests.format(1_234), Fmt.grouped(1_234))
        XCTAssertEqual(TrendMeasure.cost.format(133.97), "$133.97")
        XCTAssertEqual(TrendsLogic.niceCeiling(0), 1)
        XCTAssertEqual(TrendsLogic.niceCeiling(3.2), 5)
        XCTAssertEqual(TrendsLogic.niceCeiling(1_700_000), 2_000_000)
    }
}
