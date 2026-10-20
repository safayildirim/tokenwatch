import XCTest
@testable import UsageCore

final class CostEstimationTests: XCTestCase {
    private func cost(_ env: TestEnv) throws -> EstimatedCost { try env.totals().cost }

    func testEveryTokenCategoryIsPricedAtItsOwnRate() throws {
        let env = try TestEnv()
        // Opus 5.5 costs $4 per million input tokens, $20 output, $0.20 cache read, $5 five-minute write and $8 one-hour write.
        try Fixture.write([Fixture.assistant(id: "m", session: "S", at: t0, input: 1_000_000, output: 1_000_000,
                                             cacheRead: 1_000_000, cacheCreation: 2_000_000, fiveMinute: 1_000_000, oneHour: 1_000_000)],
                          to: try env.mainFile(session: "S"))
        try env.syncAll()
        let c = try cost(env)
        XCTAssertEqual(c.picoUSD, 4_000_000_000_000 + 20_000_000_000_000 + 200_000_000_000 + 5_000_000_000_000 + 8_000_000_000_000)
        XCTAssertEqual(c.unpricedTokens, 0)
        XCTAssertEqual(c.usd, Decimal(string: "37.2")!)
    }

    func testCacheWritesWithoutAKnownLifetimeAreAPricedAtTheFiveMinuteRate() throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.assistant(id: "m", session: "S", at: t0, input: 0, output: 0, cacheCreation: 1_000_000)],
                          to: try env.mainFile(session: "S"))
        try env.syncAll()
        XCTAssertEqual(try cost(env).picoUSD, 5_000_000_000_000)
    }

    func testEachModelUsesItsOwnPrice() throws {
        let env = try TestEnv()
        try Fixture.write([
            Fixture.assistant(id: "a", model: "claude-opus-5-5", session: "S", at: t0, input: 1_000_000, output: 0),
            Fixture.assistant(id: "b", model: "claude-sonnet-5-5", session: "S", at: t0 + 1, input: 1_000_000, output: 0),
            Fixture.assistant(id: "c", model: "claude-fable-5-1", session: "S", at: t0 + 2, input: 1_000_000, output: 0),
        ], to: try env.mainFile(session: "S"))
        try env.syncAll()
        let byModel = Dictionary(uniqueKeysWithValues: try AnalyticsEngine(db: env.db).models().map { ($0.canonical, $0.cost.picoUSD) })
        XCTAssertEqual(byModel["claude-opus-5-5"], 4_000_000_000_000)
        XCTAssertEqual(byModel["claude-sonnet-5-5"], 2_000_000_000_000)
        XCTAssertEqual(byModel["claude-fable-5-1"], 10_000_000_000_000)
    }

    func testPromptSizeTiersSwitchAtTheBoundary() throws {
        let env = try TestEnv()
        // Haiku 5.5 uses the low card for 100,000 tokens or fewer and the high card from 100,001 tokens.
        try Fixture.write([
            Fixture.assistant(id: "low", model: "claude-haiku-5-5", session: "S", at: t0, input: 100_000, output: 0),
            Fixture.assistant(id: "high", model: "claude-haiku-5-5", session: "S", at: t0 + 1, input: 100_001, output: 0),
        ], to: try env.mainFile(session: "S"))
        try env.syncAll()
        XCTAssertEqual(try cost(env).picoUSD, 100_000 * 100_000 + 100_001 * 500_000)
    }

    func testUnknownModelsAreReportedAsUnpricedInsteadOfGuessed() throws {
        let env = try TestEnv()
        try Fixture.write([
            Fixture.assistant(id: "known", session: "S", at: t0, input: 1_000_000, output: 0),
            Fixture.assistant(id: "mystery", model: "claude-future-9", session: "S", at: t0 + 1, input: 500, output: 250, cacheRead: 250),
        ], to: try env.mainFile(session: "S"))
        try env.syncAll()
        let c = try cost(env)
        XCTAssertEqual(c.picoUSD, 4_000_000_000_000, "no generic price is applied to the unknown model")
        XCTAssertEqual(c.unpricedTokens, 500 + 250 + 250)
        XCTAssertTrue(c.isPartial)
    }

    func testFastModeUsesItsOwnRateAndIsUnpricedWhereNoneExists() throws {
        let env = try TestEnv()
        try Fixture.write([
            Fixture.assistant(id: "fast", session: "S", at: t0, input: 1_000_000, output: 0, speed: "fast"),
            Fixture.assistant(id: "fast48", model: "claude-opus-4-8", session: "S", at: t0 + 1, input: 1_000_000, output: 0, speed: "fast"),
        ], to: try env.mainFile(session: "S"))
        try env.syncAll()
        let c = try cost(env)
        XCTAssertEqual(c.picoUSD, 8_000_000_000_000)
        XCTAssertEqual(c.unpricedTokens, 1_000_000)
    }

    func testPriceChangesApplyOnlyFromTheirEffectiveDate() throws {
        let env = try TestEnv()
        let change = t0 + 10 * 86_400_000
        try PricingStore.upsertUserRate(env.db, PriceRate(provider: .anthropic, model: "claude-opus-5-5", from: change, input: 1, output: 5, cacheRead: 0.1))
        try Fixture.write([
            Fixture.assistant(id: "before", session: "S", at: change - 2 * 86_400_000, input: 1_000_000, output: 0),
            Fixture.assistant(id: "after", session: "S", at: change + 2 * 86_400_000, input: 1_000_000, output: 0),
        ], to: try env.mainFile(session: "S"))
        try env.syncAll()
        let points = try AnalyticsEngine(db: env.db).series(UsageFilter(), granularity: .day).filter { $0.requests > 0 }
        XCTAssertEqual(points.map(\.cost.picoUSD).sorted(), [1_000_000_000_000, 4_000_000_000_000])
        // The earlier estimate is unchanged by the later price.
        XCTAssertEqual(try cost(env).picoUSD, 5_000_000_000_000)
    }

    func testBuiltinRatesAreReseededWithoutTouchingUserRates() throws {
        let env = try TestEnv()
        try PricingStore.upsertUserRate(env.db, PriceRate(provider: .anthropic, model: "my-model", input: 1, output: 2, cacheRead: 0.5))
        try PricingStore.seedBuiltin(env.db)
        XCTAssertEqual(try env.db.read { try $0.scalarInt("SELECT count(*) FROM price_rate WHERE origin = 'user'") }, 1)
    }
}

final class CalendarBoundaryTests: XCTestCase {
    private func calendar(_ zone: String, firstWeekday: Int = 2) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.firstWeekday = firstWeekday
        c.minimumDaysInFirstWeek = 4
        return c
    }

    private func ms(_ iso: String) -> Int64 {
        Int64(ISO8601Fast.parse(iso.contains(".") ? iso : iso.replacingOccurrences(of: "Z", with: ".000Z"))!)
    }

    private func env(requestsAt times: [String]) throws -> TestEnv {
        let env = try TestEnv()
        try Fixture.write(times.enumerated().map { Fixture.assistant(id: "m\($0.offset)", session: "S", at: ms($0.element), output: 10) },
                          to: try env.mainFile(session: "S"))
        try env.syncAll()
        return env
    }

    func testRequestsAroundLocalMidnightFallOnTheCorrectDay() throws {
        // These two requests fall at 23:59:59.9 and 00:00:00.1, on either side of local midnight in Los Angeles (PDT, UTC-7).
        let env = try env(requestsAt: ["2026-10-20T06:59:59.900Z", "2026-10-20T07:00:00.100Z"])
        let days = try AnalyticsEngine(db: env.db).series(UsageFilter(), granularity: .day, calendar: calendar("America/Los_Angeles"))
            .filter { $0.requests > 0 }
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.map(\.requests), [1, 1])
    }

    func testDaylightSavingDayHasTwentyFiveHoursAndIsNotSplit() throws {
        // Los Angeles fell back on 2025-11-02, so that local day ran from 07:00Z to 08:00Z the next day.
        let env = try env(requestsAt: ["2025-11-02T06:59:59.900Z", "2025-11-02T07:00:00.100Z", "2025-11-03T07:59:59.000Z", "2025-11-03T08:00:00.500Z"])
        let cal = calendar("America/Los_Angeles")
        let days = try AnalyticsEngine(db: env.db).series(UsageFilter(), granularity: .day, calendar: cal).filter { $0.requests > 0 }
        XCTAssertEqual(days.map(\.requests), [1, 2, 1])
        let hours = try AnalyticsEngine(db: env.db).series(UsageFilter(), granularity: .hour, calendar: cal).filter { $0.requests > 0 }
        XCTAssertEqual(hours.count, 4)
    }

    func testHalfHourTimeZoneBucketsAreExact() throws {
        // India is UTC+5:30; 18:29:59.9Z is 23:59:59.9 local and 18:30:00.1Z is just past midnight.
        let env = try env(requestsAt: ["2026-10-20T18:29:59.900Z", "2026-10-20T18:30:00.100Z"])
        let days = try AnalyticsEngine(db: env.db).series(UsageFilter(), granularity: .day, calendar: calendar("Asia/Kolkata")).filter { $0.requests > 0 }
        XCTAssertEqual(days.map(\.requests), [1, 1])
    }

    func testChangingTimeZoneRegroupsTheSameData() throws {
        let env = try env(requestsAt: ["2026-10-20T03:00:00Z"])
        let utc = try AnalyticsEngine(db: env.db).series(UsageFilter(), granularity: .day, calendar: calendar("UTC")).filter { $0.requests > 0 }
        let la = try AnalyticsEngine(db: env.db).series(UsageFilter(), granularity: .day, calendar: calendar("America/Los_Angeles")).filter { $0.requests > 0 }
        XCTAssertNotEqual(utc[0].start, la[0].start, "the same instant belongs to different calendar days in different zones")
        XCTAssertEqual(try env.totals().tokens.output, 10, "and the stored data never changes")
    }

    func testPeriodBoundariesAreHalfOpen() throws {
        let env = try env(requestsAt: ["2026-10-20T00:00:00.000Z", "2026-10-20T00:00:00.001Z", "2026-10-19T23:59:59.999Z"])
        let from = Date(timeIntervalSince1970: Double(ms("2026-10-20T00:00:00.000Z")) / 1000)
        let engine = AnalyticsEngine(db: env.db)
        XCTAssertEqual(try engine.totals(UsageFilter(from: from)).requests, 2, "the start is inclusive")
        XCTAssertEqual(try engine.totals(UsageFilter(from: nil, to: from)).requests, 1, "the end is exclusive")
    }

    func testOverviewPeriodsUseTheCallersCalendar() throws {
        let env = try env(requestsAt: ["2026-10-20T10:00:00Z", "2026-10-19T10:00:00Z", "2026-10-12T10:00:00Z", "2026-09-30T10:00:00Z"])
        let cal = calendar("UTC")
        let now = Date(timeIntervalSince1970: Double(ms("2026-10-20T12:00:00Z")) / 1000)   // A Tuesday.
        let o = try AnalyticsEngine(db: env.db).overview(now: now, calendar: cal)
        XCTAssertEqual(o.today.requests, 1)
        XCTAssertEqual(o.thisWeek.requests, 2, "the week began on Monday 2026-10-19")
        XCTAssertEqual(o.thisMonth.requests, 3)
        XCTAssertEqual(o.allTime.requests, 4)
    }

    func testQuietDaysAppearAsZeroInDailySeries() throws {
        let env = try env(requestsAt: ["2026-10-15T10:00:00Z", "2026-10-18T10:00:00Z"])
        let upTo = Date(timeIntervalSince1970: Double(ms("2026-10-19T00:00:00Z")) / 1000)
        let days = try AnalyticsEngine(db: env.db).series(UsageFilter(from: nil, to: upTo), granularity: .day, calendar: calendar("UTC"))
        XCTAssertEqual(days.map(\.requests), [1, 0, 0, 1])
    }
}

final class AnalyticsQueryTests: XCTestCase {
    private func populated() throws -> TestEnv {
        let env = try TestEnv()
        try Fixture.write([
            Fixture.assistant(id: "a1", model: "claude-opus-5-5", session: "SA", at: t0, output: 100, cacheRead: 900, cwd: "/Users/test/alpha"),
            Fixture.assistant(id: "a2", model: "claude-sonnet-5-5", session: "SA", at: t0 + 60_000, output: 50, cacheRead: 450, cwd: "/Users/test/alpha"),
        ], to: try env.mainFile(session: "SA"))
        try Fixture.write([
            Fixture.assistant(id: "b1", model: "claude-opus-5-5", session: "SB", at: t0 + 86_400_000, output: 300, cacheRead: 100, cwd: "/Users/test/beta", entrypoint: "claude-vscode"),
        ], to: try env.mainFile(cwd: "/Users/test/beta", session: "SB"))
        try env.syncAll()
        return env
    }

    func testBreakdownsAddUpToTheTotal() throws {
        let env = try populated()
        let engine = AnalyticsEngine(db: env.db)
        let total = try engine.totals().tokens.totalProcessed
        XCTAssertEqual(try engine.models().reduce(Int64(0)) { $0 + $1.tokens.totalProcessed }, total)
        XCTAssertEqual(try engine.projects().reduce(Int64(0)) { $0 + $1.tokens.totalProcessed }, total)
        XCTAssertEqual(try engine.sessionRows().reduce(Int64(0)) { $0 + $1.tokens.totalProcessed }, total)
        XCTAssertEqual(try engine.series(UsageFilter(), granularity: .day).reduce(Int64(0)) { $0 + $1.tokens.totalProcessed }, total)
        XCTAssertEqual(try engine.models().reduce(0.0) { $0 + $1.tokenShare }, 1.0, accuracy: 1e-9)
    }

    func testFiltersByModelProjectSurfaceAndSearch() throws {
        let env = try populated()
        let engine = AnalyticsEngine(db: env.db)

        var f = UsageFilter()
        f.models = ["claude-sonnet-5-5"]
        XCTAssertEqual(try engine.totals(f).tokens.output, 50)
        XCTAssertEqual(try engine.sessionRows(f).count, 1, "a model filter keeps only sessions that used the model")

        f = UsageFilter()
        f.surfaces = [.vscode]
        XCTAssertEqual(try engine.totals(f).tokens.output, 300)

        f = UsageFilter()
        f.projectIDs = [try XCTUnwrap(engine.filterOptions().projects.first { $0.name == "alpha" }?.id)]
        XCTAssertEqual(try engine.totals(f).tokens.output, 150)

        f = UsageFilter()
        f.search = "BET"
        XCTAssertEqual(try engine.sessionRows(f).map(\.projectName), ["beta"])
        f.search = "no-such-thing"
        XCTAssertEqual(try engine.sessionRows(f).count, 0)
        f.search = "100%_"
        XCTAssertEqual(try engine.sessionRows(f).count, 0, "LIKE wildcards in the search box are treated literally")
    }

    func testSeriesCanBeSplitByModelAndProject() throws {
        let env = try populated()
        let engine = AnalyticsEngine(db: env.db)
        let byModel = try engine.series(UsageFilter(), granularity: .day, dimension: .model).filter { $0.requests > 0 }
        XCTAssertEqual(Set(byModel.map(\.key)), ["claude-opus-5-5", "claude-sonnet-5-5"])
        let byProject = try engine.series(UsageFilter(), granularity: .day, dimension: .project).filter { $0.requests > 0 }
        XCTAssertEqual(Set(byProject.map(\.label)), ["alpha", "beta"])
    }

    func testSessionsOverTimeCountsDistinctSessions() throws {
        let env = try populated()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let counts = try AnalyticsEngine(db: env.db).sessionsOverTime(UsageFilter(), granularity: .day, calendar: cal)
        XCTAssertEqual(counts.map(\.sessions), [1, 1])
    }

    func testSessionStatusUsesTheLiveRegistryBeforeInference() throws {
        let env = try populated()
        let engine = AnalyticsEngine(db: env.db)
        let now = Clock.date(ms: t0 + 86_400_000 + 5_000)
        let live = ["SB": LiveProcess(sessionExternalID: "SB", pid: 1, activity: .busy, entrypoint: nil, updatedAt: nil)]
        let rows = try engine.sessionRows(now: now, live: live)
        let a = rows.first { $0.externalID == "SA" }!, b = rows.first { $0.externalID == "SB" }!
        XCTAssertEqual(b.status, SessionStatus(.active, .observed))
        XCTAssertEqual(a.status.basis, .inferred)
        XCTAssertEqual(a.status.state, .completed, "a day-old session with no live process is only inferred to be done")
        XCTAssertEqual(try engine.overview(now: now, live: live).activeSessions, 1)
    }

    func testRequestTimelineIsBucketedWhenTooLargeToPlot() throws {
        let env = try TestEnv()
        try Fixture.write((0..<2000).map { Fixture.assistant(id: "m\($0)", session: "S", at: t0 + Int64($0) * 1000, output: 1) },
                          to: try env.mainFile(session: "S"))
        try env.syncAll()
        let engine = AnalyticsEngine(db: env.db)
        let id = try engine.sessionRows().first!.id
        let detail = try XCTUnwrap(engine.sessionDetail(id: id))
        XCTAssertTrue(detail.timelineIsBucketed)
        XCTAssertLessThanOrEqual(detail.timeline.count, 1600)
        XCTAssertEqual(detail.timeline.reduce(0) { $0 + $1.requests }, 2000, "bucketing keeps every request")
        XCTAssertEqual(detail.timeline.reduce(Int64(0)) { $0 + $1.tokens.output }, 2000)
    }

    func testSessionDetailPutsAccountLevelUtilizationNextToLocalShares() throws {
        let env = try TestEnv()
        // Two sessions inside one five-hour window; the account reports 90% used although the local
        // sessions together account for only a tiny number of tokens.
        try Fixture.write([Fixture.assistant(id: "big", session: "BIG", at: t0, input: 0, output: 900, cwd: "/Users/test/a")], to: try env.mainFile(cwd: "/Users/test/a", session: "BIG"))
        try Fixture.write([Fixture.assistant(id: "small", session: "SMALL", at: t0 + 60_000, input: 0, output: 100, cwd: "/Users/test/b")], to: try env.mainFile(cwd: "/Users/test/b", session: "SMALL"))
        try env.syncAll()
        let windowEnd = t0 + 3 * 3_600_000
        try env.db.write { c in
            let resolver = EntityResolver(c, registry: env.db.registry)
            for (pct, at) in [(40.0, t0 + 1000), (90.0, t0 + 120_000)] {
                try QuotaStore.record(QuotaObservation(provider: .anthropic, account: .unassigned(.anthropic), poolKey: "claude-subscription",
                                                       windowKey: "300m", windowMinutes: 300, utilizationPercent: pct,
                                                       resetsAt: Clock.date(ms: windowEnd), observedAt: Clock.date(ms: at),
                                                       source: .claudeStatusLine),
                                      originSessionID: nil, resolver: resolver)
            }
        }
        let engine = AnalyticsEngine(db: env.db)
        let small = try engine.sessionRows().first { $0.externalID == "SMALL" }!
        let detail = try XCTUnwrap(engine.sessionDetail(id: small.id))
        let window = try XCTUnwrap(detail.windows.first { $0.windowKey == "300m" })
        XCTAssertEqual(window.reportedPeakUtilization, 90)
        XCTAssertEqual(window.shareOfObservedFreshTokens!, 0.1, accuracy: 1e-9, "10% of the locally observed tokens")
        // The share of observed activity is a separate quantity from the account percentage and is never merged with it.
        XCTAssertNotEqual(window.shareOfObservedFreshTokens!, window.reportedPeakUtilization! / 100)
    }
}

final class SessionStatusTests: XCTestCase {
    func testObservedStateBeatsInference() {
        let now = Date()
        let last = Clock.ms(now) - 10 * 3_600_000
        let busy = LiveProcess(sessionExternalID: "s", pid: 1, activity: .busy, entrypoint: nil, updatedAt: nil)
        let idle = LiveProcess(sessionExternalID: "s", pid: 1, activity: .idle, entrypoint: nil, updatedAt: nil)
        XCTAssertEqual(SessionStatusResolver.resolve(now: now, lastActivityMs: last, observedEndedAtMs: nil, live: busy), SessionStatus(.active, .observed))
        XCTAssertEqual(SessionStatusResolver.resolve(now: now, lastActivityMs: last, observedEndedAtMs: nil, live: idle), SessionStatus(.idle, .observed))
    }

    func testProcessExitAfterLastActivityIsObservedCompletion() {
        let now = Date()
        let last = Clock.ms(now) - 60_000
        XCTAssertEqual(SessionStatusResolver.resolve(now: now, lastActivityMs: last, observedEndedAtMs: last + 5_000, live: nil),
                       SessionStatus(.completed, .observed))
    }

    func testActivityAfterRecordedExitMeansTheSessionWasResumed() {
        let now = Date()
        let ended = Clock.ms(now) - 3_600_000
        // The session wrote again after its process was seen exiting (for example it was resumed elsewhere).
        let status = SessionStatusResolver.resolve(now: now, lastActivityMs: Clock.ms(now) - 30_000, observedEndedAtMs: ended, live: nil)
        XCTAssertEqual(status, SessionStatus(.active, .inferred))
    }

    func testInferenceThresholdsAreConfigurable() {
        let now = Date()
        var policy = StatusPolicy()
        policy.activeWithin = 60
        policy.idleWithin = 600
        func state(_ ageSeconds: Double) -> SessionState {
            SessionStatusResolver.resolve(now: now, lastActivityMs: Clock.ms(now) - Int64(ageSeconds * 1000), observedEndedAtMs: nil, live: nil, policy: policy).state
        }
        XCTAssertEqual(state(30), .active)
        XCTAssertEqual(state(300), .idle)
        XCTAssertEqual(state(7200), .completed)
        XCTAssertEqual(SessionStatusResolver.resolve(now: now, lastActivityMs: nil, observedEndedAtMs: nil, live: nil).state, .unknown)
    }

    func testRegistryEntriesWithoutALiveProcessAreIgnored() {
        let alive = #"{"sessionId":"s1","pid":\#(getpid()),"status":"busy","entrypoint":"cli"}"#
        XCTAssertEqual(SessionRegistryMonitor.parse(Data(alive.utf8))?.activity, .busy)
        let dead = #"{"sessionId":"s2","pid":99999999,"status":"idle"}"#
        XCTAssertNil(SessionRegistryMonitor.parse(Data(dead.utf8)))
        XCTAssertNil(SessionRegistryMonitor.parse(Data("not json".utf8)))
        // A recycled process id with a different start time is not the original process.
        let recycled = #"{"sessionId":"s3","pid":\#(getpid()),"status":"busy","procStart":"Mon Jan  1 00:00:00 2001"}"#
        XCTAssertNil(SessionRegistryMonitor.parse(Data(recycled.utf8)))
    }

    func testRegistryMonitorRecordsObservedExit() async throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Fixture.write([Fixture.assistant(id: "m", session: "S1", at: t0, output: 1)], to: try env.mainFile(session: "S1"))
        try env.syncAll()

        let monitor = SessionRegistryMonitor(directory: dir, db: env.db)
        let file = dir.appendingPathComponent("\(getpid()).json")
        try #"{"sessionId":"S1","pid":\#(getpid()),"status":"busy"}"#.write(to: file, atomically: true, encoding: .utf8)
        await monitor.start()
        try await Task.sleep(for: .milliseconds(300))
        await monitor.rescan()
        let live = await monitor.liveSessions()
        XCTAssertEqual(live["S1"]?.activity, .busy)

        try FileManager.default.removeItem(at: file)
        await monitor.rescan()
        let ended = try env.db.read { try $0.queryOne("SELECT observed_ended_at FROM session WHERE external_id = 'S1'") { $0.intOrNil(0) } }
        XCTAssertNotNil(ended ?? nil, "the process disappearing is recorded as an observed end")
        await monitor.stop()
    }
}
