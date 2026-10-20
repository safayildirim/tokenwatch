import XCTest
@testable import UsageCore
@testable import UsageUI

final class FormatterTests: XCTestCase {
    func testCompactTokenCounts() {
        XCTAssertEqual(Fmt.tokens(0), "0")
        XCTAssertEqual(Fmt.tokens(999), "999")
        XCTAssertEqual(Fmt.tokens(12_345), "12.3K")
        XCTAssertEqual(Fmt.tokens(1_234_567), "1.23M")
        XCTAssertEqual(Fmt.tokens(26_300_000_000), "26.3B")
        XCTAssertEqual(Fmt.tokens(4_200_000_000_000), "4.20T")
    }

    func testCostIsNeverAmbiguousAcrossLocales() {
        // "$5.586" would mean five dollars in one locale and five thousand in another.
        XCTAssertEqual(Fmt.cost(EstimatedCost(picoUSD: 5_586_000_000_000_000)), "$5.59K")
        XCTAssertEqual(Fmt.cost(EstimatedCost(picoUSD: 133_970_000_000_000)), "$133.97")
        XCTAssertEqual(Fmt.cost(EstimatedCost(picoUSD: 2_500_000_000_000)), "$2.500")
        XCTAssertEqual(Fmt.cost(EstimatedCost(picoUSD: 0)), "$0")
        XCTAssertEqual(Fmt.cost(EstimatedCost(picoUSD: 4_000_000_000_000, unpricedTokens: 5)), "$4.000+", "a lower bound is marked")
        XCTAssertEqual(Fmt.cost(EstimatedCost(picoUSD: 0, unpricedTokens: 5)), "unpriced")
        XCTAssertEqual(Fmt.cost(EstimatedCost(picoUSD: 2_500_000_000_000_000_000)), "$2.50M")
    }

    func testDurationsAndRelativeTimes() {
        XCTAssertEqual(Fmt.duration(45), "45s")
        XCTAssertEqual(Fmt.duration(125), "2m")
        XCTAssertEqual(Fmt.duration(3 * 3600 + 14 * 60), "3h 14m")
        XCTAssertEqual(Fmt.duration(2 * 86400 + 5 * 3600), "2d 5h")
        let now = Date()
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-7200), now: now), "2h ago")
        XCTAssertEqual(Fmt.relative(nil), "—")
    }

    func testPercentsAndRatios() {
        XCTAssertEqual(Fmt.percent(63.4), "63%")
        XCTAssertEqual(Fmt.percent(nil), "—")
        XCTAssertEqual(Fmt.ratio(0.984), "98.4%")
        XCTAssertEqual(Fmt.ratio(nil), "—")
    }

    func testApplicationNames() {
        XCTAssertEqual(Fmt.applicationName("cli"), "Terminal")
        XCTAssertEqual(Fmt.applicationName("claude-vscode"), "VS Code")
        XCTAssertEqual(Fmt.applicationName("claude-desktop"), "Claude Desktop")
    }
}

final class RangeAndFilterTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testPresetRanges() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var r = RangeSelection(preset: .last24h)
        XCTAssertEqual(r.interval(now: now, calendar: cal).from, now.addingTimeInterval(-86_400))
        r.preset = .all
        XCTAssertNil(r.interval(now: now, calendar: cal).from)
        XCTAssertNil(r.interval(now: now, calendar: cal).to)
        r.preset = .last7d
        XCTAssertEqual(r.interval(now: now, calendar: cal).from, cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now)))
    }

    func testCustomRangeIncludesTheWholeLastDay() {
        var r = RangeSelection(preset: .custom)
        r.customFrom = Date(timeIntervalSince1970: 1_790_000_000)
        r.customTo = Date(timeIntervalSince1970: 1_790_100_000)
        let i = r.interval(calendar: cal)
        XCTAssertEqual(i.from, cal.startOfDay(for: r.customFrom))
        XCTAssertEqual(i.to, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: r.customTo)))
    }

    private func row(_ state: SessionState) -> SessionRow {
        SessionRow(id: Int64(state.hashValue & 0xFFFF), externalID: "x", sourceID: "s", projectID: nil, projectName: "p", projectPath: nil,
                   application: "cli", clientVersion: nil, cwd: nil, startedAt: nil, lastActivityAt: nil, observedEndedAt: nil,
                   tokens: .zero, requests: 0, agentRequests: 0, agentCount: 0, cost: .zero, reportedCostUSD: nil, models: [],
                   status: SessionStatus(state, .inferred))
    }

    func testStatusFilter() {
        let rows = SessionState.allCases.map(row)
        var f = SessionFilterState()
        XCTAssertEqual(f.apply(to: rows).count, 4)
        f.statuses = [.active, .idle]
        XCTAssertEqual(Set(f.apply(to: rows).map(\.status.state)), [.active, .idle])
    }

    func testFilterStateMapsToTheQuery() {
        var f = SessionFilterState()
        XCTAssertFalse(f.isFiltering)
        f.search = "alpha"
        f.projectIDs = [3]
        f.models = ["claude-opus-5-5"]
        f.applications = ["cli"]
        XCTAssertTrue(f.isFiltering)
        let q = f.usageFilter
        XCTAssertEqual(q.search, "alpha")
        XCTAssertEqual(q.projectIDs, [3])
        XCTAssertEqual(q.models, ["claude-opus-5-5"])
        XCTAssertEqual(q.applications, ["cli"])
    }
}
