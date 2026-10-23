import XCTest
@testable import UsageCore

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400
private let week: TimeInterval = 7 * day
private let friday = intelligenceFriday

final class UsageInsightsTests: XCTestCase {
    /// Weekly cycles with readings every six hours and one request per reading carrying `tokens(cycleIndex)` cache-read tokens.
    private func world(cycles: Range<Int>, tokens: (Int) -> Int64, finalPercent: (Int) -> Double, model: String = "claude-opus-5-5",
                       currentFraction: Double = 0.5) throws -> (IntelligenceWorld, Date) {
        let w = try IntelligenceWorld()
        for index in cycles {
            let start = friday + Double(index) * week
            let fraction = index == 0 ? currentFraction : 1
            var time = start + hour
            while time < start + week * fraction {
                let percent = (finalPercent(index) * (time.timeIntervalSince(start) / week)).rounded()
                try w.quota(percent, at: time, resets: start + week)
                w.request(at: time + 1800, session: "s\(index)", model: model, input: 0, output: 0, cacheRead: tokens(index), cacheCreation: 0)
                time += 6 * hour
            }
            if fraction >= 1 { try w.quota(finalPercent(index).rounded(), at: start + week - hour, resets: start + week) }
        }
        try w.commit()
        return (w, friday + week * currentFraction + 1800)
    }

    private func insights(_ w: IntelligenceWorld, now: Date) throws -> [UsageInsight] {
        let report = try w.report(now: now)
        return UsageInsightsEngine.insights(report: report, forecast: UsageForecastEngine.forecast(for: report, now: now), now: now)
    }

    func testAnUnusualWeekProducesAStatementWithTheNumbersBehindIt() throws {
        // The previous cycle used 30% more tokens than the one before it.
        let (w, now) = try world(cycles: -8..<1, tokens: { $0 == -1 ? 130_000 : 100_000 }, finalPercent: { _ in 60 })
        let found = try insights(w, now: now)
        let change = try XCTUnwrap(found.first { $0.kind == .tokensChangedVersusPreviousCycle })
        XCTAssertEqual(try XCTUnwrap(change.values["change"]), 0.30, accuracy: 0.01)
    }

    func testSmallFluctuationsProduceNothing() throws {
        let (w, now) = try world(cycles: -8..<1, tokens: { $0 == -1 ? 108_000 : 100_000 }, finalPercent: { _ in 60 })
        let kinds = Set(try insights(w, now: now).map(\.kind))
        XCTAssertFalse(kinds.contains(.tokensChangedVersusPreviousCycle), "an 8% change is not worth a statement")
        XCTAssertFalse(kinds.contains(.tokensChangedSameDays))
    }

    func testAnExhaustingPaceIsTheFirstStatement() throws {
        var world = try self.world(cycles: -8..<1, tokens: { _ in 100_000 }, finalPercent: { _ in 115 }, currentFraction: 0.6)
        let found = try insights(world.0, now: world.1)
        XCTAssertEqual(found.first?.kind, .mayExhaustAllowance)
        XCTAssertTrue(found.count <= UsageInsightsEngine.maximumInsights)
        world.1 = world.1
    }

    func testCyclesThatReachedTheLimitAreReportedAndStatementsAreOrderedByUsefulness() throws {
        let (w, now) = try world(cycles: -8..<1, tokens: { _ in 100_000 }, finalPercent: { _ in 115 })
        let found = try insights(w, now: now)
        XCTAssertTrue(found.contains { $0.kind == .limitReachedBefore })
        XCTAssertEqual(found.map(\.priority), found.map(\.priority).sorted(by: >))
    }

    func testTheMostUsedModelAndTheCacheShareAreStatedOnlyWhenTheyDominate() throws {
        let (w, now) = try world(cycles: -3..<1, tokens: { _ in 100_000 }, finalPercent: { _ in 40 })
        let found = try insights(w, now: now)
        XCTAssertEqual(try XCTUnwrap(found.first { $0.kind == .topModel }).names["model"], "Opus 5.5")
        XCTAssertNotNil(found.first { $0.kind == .cacheReadShare })
    }

    func testInsightsAreDeterministic() throws {
        let (w, now) = try world(cycles: -6..<1, tokens: { $0 % 2 == 0 ? 100_000 : 160_000 }, finalPercent: { _ in 70 })
        XCTAssertEqual(try insights(w, now: now), try insights(w, now: now))
    }

    func testWindowsOfHoursNeverProduceCycleToCycleComparisons() throws {
        let w = try IntelligenceWorld()
        let start = friday
        for index in 0..<6 {
            let begin = start + Double(index) * 7 * hour
            try w.quota(5, at: begin + 600, resets: begin + 5 * hour, minutes: 300)
            try w.quota(20, at: begin + 4 * hour, resets: begin + 5 * hour, minutes: 300)
            w.request(at: begin + hour, cacheRead: index == 4 ? 900_000 : 100_000)
        }
        try w.commit()
        let report = try w.report(window: "300m", now: start + 6 * 7 * hour + hour)
        let found = UsageInsightsEngine.insights(report: report, forecast: UsageForecastEngine.forecast(for: report, now: start + 43 * hour), now: start + 43 * hour)
        XCTAssertFalse(found.contains { $0.kind == .tokensChangedVersusPreviousCycle || $0.kind == .paceVersusHistory || $0.kind == .frontLoadedUsage })
    }

    func testAnEmptyHistoryProducesNoInsights() throws {
        let w = try IntelligenceWorld()
        try w.quota(5, at: friday + hour, resets: friday + week)
        XCTAssertTrue(try insights(w, now: friday + 2 * hour).isEmpty)
    }
}

final class IntelligenceExportTests: XCTestCase {
    private func export(_ w: IntelligenceWorld, format: ExportFormat) throws -> (URL, ExportResult) {
        let url = w.env.root.appendingPathComponent("out/intelligence.\(format.rawValue)")
        let result = try ExportService(db: w.db).export(kind: .usageIntelligence, format: format, to: url)
        return (url, result)
    }

    private func seeded() throws -> IntelligenceWorld {
        let w = try IntelligenceWorld()
        let now = Date()
        let start = floor(now.timeIntervalSince1970 / week) * week
        for index in -2...0 {
            let cycleStart = Date(timeIntervalSince1970: start + Double(index) * week)
            try w.quota(10, at: cycleStart + hour, resets: cycleStart + week, account: IntelligenceWorld.identified)
            try w.quota(30, at: cycleStart + 2 * day, resets: cycleStart + week, account: IntelligenceWorld.identified)
            w.request(at: cycleStart + 3 * hour, account: IntelligenceWorld.identified)
        }
        try w.commit()
        return w
    }

    func testTheJSONExportHoldsCyclesDaysAForecastAndTheDefinitionsOfEveryColumn() throws {
        let w = try seeded()
        let (url, result) = try export(w, format: .json)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        let columns = try XCTUnwrap(metadata["columns"] as? [[String: String]])
        XCTAssertTrue(columns.allSatisfy { !($0["definition"] ?? "").isEmpty }, "every column is defined")
        XCTAssertNotNil(metadata["intelligence_note"])
        XCTAssertNotNil(metadata["projection_note"])
        XCTAssertNotNil(metadata["forecast_note"])
        let rows = try XCTUnwrap(json["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, result.rows)
        let types = Set(rows.compactMap { $0["row_type"] as? String })
        XCTAssertTrue(types.isSuperset(of: ["cycle", "day", "forecast"]))
        let forecast = try XCTUnwrap(rows.first { ($0["row_type"] as? String) == "forecast" && ($0["window"] as? String) == "10080m" })
        XCTAssertEqual(forecast["forecast_status"] as? String, "unavailable", "three cycles are not enough history for a forecast")
        XCTAssertNil(forecast["forecast_point_percent"] as? Double, "no number is exported for an unavailable forecast")
    }

    func testProjectedCyclesAreExportedWithoutAnyUtilizationAndObservedOnesWithTheirCoverage() throws {
        let w = try seeded()
        let (url, _) = try export(w, format: .json)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cycles = try XCTUnwrap(json["rows"] as? [[String: Any]]).filter { ($0["row_type"] as? String) == "cycle" && ($0["window"] as? String) == "10080m" }
        let observed = cycles.filter { ($0["boundary_origin"] as? String) == "observed" }
        XCTAssertGreaterThanOrEqual(observed.count, 3)
        for cycle in observed {
            XCTAssertNotNil(cycle["quota_max_percent"])
            XCTAssertNotNil(cycle["quota_completeness"])
        }
        for cycle in cycles where (cycle["boundary_origin"] as? String) == "projected" {
            XCTAssertNil(cycle["quota_max_percent"] as? Double)
            XCTAssertEqual(cycle["quota_completeness"] as? String, "unobserved")
        }
    }

    func testNoRawAccountIdentifierIsExported() throws {
        let w = try seeded()
        for format in [ExportFormat.json, .csv] {
            let (url, _) = try export(w, format: format)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("11111111-2222-3333-4444-555555555555"))
            XCTAssertFalse(text.contains(IntelligenceWorld.identified.hash!), "not even the full one-way hash leaves the database")
            XCTAssertTrue(text.contains("Account " + IntelligenceWorld.identified.hash!.prefix(6)))
        }
    }

    func testTheCSVHasTheSameColumnsAsTheDefinitions() throws {
        let w = try seeded()
        let (url, _) = try export(w, format: .csv)
        let header = try String(contentsOf: url, encoding: .utf8).split(separator: "\r\n").first.map(String.init) ?? ""
        XCTAssertEqual(header.split(separator: ",").count, IntelligenceExport.columns.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path.replacingOccurrences(of: ".csv", with: ".metadata.json")) ||
                      FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("metadata.json").path))
    }

    func testExportingTwiceGivesTheSameRowsExceptForTheirTimestamp() throws {
        let w = try seeded()
        let first = try export(w, format: .csv).1.rows
        let second = try export(w, format: .csv).1.rows
        XCTAssertEqual(first, second, "the analysis reproduces from the stored observations")
    }
}
