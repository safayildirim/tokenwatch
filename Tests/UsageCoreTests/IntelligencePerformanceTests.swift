import XCTest
@testable import UsageCore

/// Times the analysis on a large synthetic history with two providers, so that a regression in the queries shows up as a failure
/// instead of as a slow dashboard. The bounds are generous because the suite runs unoptimized code.
final class IntelligencePerformanceTests: XCTestCase {
    private let week: TimeInterval = 7 * 86_400
    private let hour: TimeInterval = 3600

    private func peakMemoryMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    func testAnalysisOfHalfAYearOfTwoProvidersStaysWithinBudget() throws {
        let w = try IntelligenceWorld()
        let now = Date(timeIntervalSince1970: 1_792_713_600 + 3 * 86_400)
        let first = Date(timeIntervalSince1970: 1_792_713_600).addingTimeInterval(-26 * week)
        let codexAccount = AccountRef.identified(provider: .openAI, rawIdentifier: "codex-account-1")

        // 26 weeks of weekly readings every six hours for both providers.
        for cycle in 0..<27 {
            let start = first.addingTimeInterval(Double(cycle) * week)
            var time = start.addingTimeInterval(hour)
            while time < min(start.addingTimeInterval(week), now) {
                let percent = (80 * time.timeIntervalSince(start) / week).rounded()
                try w.quota(percent, at: time, resets: start.addingTimeInterval(week))
                try w.db.write { c in
                    try QuotaStore.record(QuotaObservation(provider: .openAI, account: codexAccount, poolKey: "codex", windowKey: "10080m",
                                                           windowMinutes: 10_080, utilizationPercent: percent, resetsAt: start.addingTimeInterval(week),
                                                           observedAt: time, source: .codexRollouts), originSessionID: nil,
                                          resolver: EntityResolver(c, registry: w.db.registry))
                }
                time = time.addingTimeInterval(6 * hour)
            }
        }

        // About 180,000 requests: one every 1.5 minutes around the clock for the whole span.
        var batch = NormalizedBatch()
        var count = 0
        var time = first
        batch.add(Obs.session("S", at: Clock.ms(first)))
        while time < now {
            batch.add(Obs.claudeRequest("r\(count)", model: count % 5 == 0 ? "claude-sonnet-5-5" : "claude-opus-5-5", at: Clock.ms(time),
                                        input: 1_000, output: 400, cacheRead: 90_000, cacheCreation: 2_000))
            count += 1
            if count % 20_000 == 0 {
                _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: w.db)
                batch = NormalizedBatch()
                batch.add(Obs.session("S", at: Clock.ms(first)))
            }
            time = time.addingTimeInterval(90)
        }
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: w.db)
        XCTAssertGreaterThan(count, 150_000)

        let subjects = try SubscriptionUsageAnalyticsEngine.subjects(w.db)
        XCTAssertEqual(subjects.filter { $0.windowKey == "10080m" }.count, 2)
        let claude = try XCTUnwrap(subjects.first { $0.provider == .anthropic && $0.windowKey == "10080m" })
        var options = AnalysisOptions()
        options.maxCycles = 14

        let started = Date()
        let report = try SubscriptionUsageAnalyticsEngine.analyze(w.db, subject: claude, now: now, options: options)
        let analysis = Date().timeIntervalSince(started)
        let forecastStarted = Date()
        let forecast = UsageForecastEngine.forecast(for: report, now: now)
        let insights = UsageInsightsEngine.insights(report: report, forecast: forecast, now: now)
        let forecasting = Date().timeIntervalSince(forecastStarted)
        print("INTELLIGENCE-BENCH requests=\(count) analysis=\(String(format: "%.3f", analysis))s forecast+insights=\(String(format: "%.4f", forecasting))s peakRSS=\(String(format: "%.0f", peakMemoryMB()))MB cycles=\(report.cycles.count) insights=\(insights.count)")

        XCTAssertEqual(report.cycles.count, 14)
        XCTAssertLessThan(analysis, 12, "a dashboard query over a half year must stay interactive")
        XCTAssertLessThan(forecasting, 1)
        XCTAssertEqual(report.cycles.reduce(0) { $0 + $1.local.requests } > 0, true)

        // The other provider's windows are analyzed from their own rows only.
        let other = try XCTUnwrap(subjects.first { $0.provider == .openAI && $0.windowKey == "10080m" })
        let otherReport = try SubscriptionUsageAnalyticsEngine.analyze(w.db, subject: other, now: now, options: options)
        XCTAssertEqual(otherReport.cycles.reduce(0) { $0 + $1.local.requests }, 0)
    }
}
