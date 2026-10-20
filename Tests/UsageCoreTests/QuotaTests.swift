import XCTest
@testable import UsageCore

final class QuotaEvaluatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private let pool = QuotaPoolInfo(key: QuotaPoolKey(provider: .anthropic, accountID: 1, poolKey: "claude-subscription"),
                                     accountLabel: "Unassigned", name: "Claude subscription")

    private func reading(_ pct: Double, resets: TimeInterval?, observedAgo: TimeInterval = 30,
                         authority: QuotaAuthority = .authoritative, source: TelemetrySourceID = .claudeStatusLine) -> QuotaReading {
        QuotaReading(utilizationPercent: pct, resetsAt: resets.map { now.addingTimeInterval($0) },
                     observedAt: now.addingTimeInterval(-observedAgo), source: source, authority: authority)
    }

    private func evaluate(_ readings: [QuotaReading], allowUnverified: Bool = false) -> QuotaWindowState {
        QuotaEvaluator.evaluate(pool: pool, windowKey: "300m", windowMinutes: 300, readings: readings, now: now,
                                allowUnverified: allowUnverified)
    }

    func testAuthoritativeReadingShowsConsumedRemainingAndCountdown() {
        let s = evaluate([reading(63, resets: 2 * 3600)])
        XCTAssertEqual(s.availability, .available)
        XCTAssertEqual(s.utilizationPercent, 63)
        XCTAssertEqual(s.remainingPercent, 37)
        XCTAssertEqual(s.countdown(now: now)!, 7200, accuracy: 0.001)
        XCTAssertEqual(s.freshness, .fresh)
        XCTAssertTrue(s.isDisplayable)
        XCTAssertTrue(s.isAlertEligible)
        XCTAssertEqual(s.lastRefresh, now.addingTimeInterval(-30))
    }

    func testNoDataIsUnavailableNotZero() {
        let s = evaluate([])
        XCTAssertEqual(s.availability, .unavailable(.noData))
        XCTAssertNil(s.utilizationPercent)
        XCTAssertNil(s.remainingPercent)
        XCTAssertFalse(s.isDisplayable)
    }

    func testEvaluationDoesNotDependOnTheOrderOfReadings() {
        let readings = [reading(40, resets: 3600, observedAgo: 600), reading(55, resets: 3600, observedAgo: 20),
                        reading(97, resets: -600, observedAgo: 5), reading(30, resets: 3600, observedAgo: 3000)]
        for ordering in [readings, readings.reversed(), readings.shuffled(), readings.shuffled()] {
            XCTAssertEqual(evaluate(Array(ordering)).utilizationPercent, 55)
        }
    }

    func testALateDeliveredOlderReadingNeverReplacesANewerOne() {
        // An older observation that reaches the database after a newer one is simply the older of the two.
        let newer = reading(70, resets: 3600, observedAgo: 10)
        let older = reading(20, resets: 3600, observedAgo: 900)
        XCTAssertEqual(evaluate([newer, older]).utilizationPercent, 70)
        XCTAssertEqual(evaluate([older, newer]).utilizationPercent, 70)
    }

    func testWindowNamesComeFromTheirLength() {
        XCTAssertEqual(evaluate([]).displayName, "5-hour window")
        XCTAssertEqual(evaluate([]).shortName, "5h")
        XCTAssertTrue(evaluate([]).isShort)
        let weekly = QuotaEvaluator.evaluate(pool: pool, windowKey: "10080m", windowMinutes: 10080, readings: [], now: now, allowUnverified: false)
        XCTAssertEqual(weekly.displayName, "Weekly window")
        XCTAssertEqual(weekly.shortName, "Week")
        XCTAssertFalse(weekly.isShort)
        let odd = QuotaEvaluator.evaluate(pool: pool, windowKey: "90m", windowMinutes: 90, readings: [], now: now, allowUnverified: false)
        XCTAssertEqual(odd.displayName, "90-minute window", "a window length that nobody planned for still gets a sensible name")
    }

    func testFreshnessAgesWithTheReading() {
        XCTAssertEqual(evaluate([reading(10, resets: 3600, observedAgo: 5 * 60)]).freshness, .fresh)
        XCTAssertEqual(evaluate([reading(10, resets: 3600, observedAgo: 30 * 60)]).freshness, .aging)
        let stale = evaluate([reading(10, resets: 3600, observedAgo: 3 * 3600)])
        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertEqual(stale.utilizationPercent, 10, "the last known value is still shown, marked stale")
        XCTAssertTrue(stale.isDisplayable)
        XCTAssertFalse(stale.isAlertEligible, "stale values never trigger alerts")
    }

    func testElapsedWindowDoesNotAssumeZero() {
        let s = evaluate([reading(97, resets: -60)])
        XCTAssertEqual(s.availability, .windowElapsed(resetAt: now.addingTimeInterval(-60)))
        XCTAssertNil(s.utilizationPercent, "after the reset the new utilization is unknown, not zero")
        XCTAssertNil(s.countdown(now: now))
        XCTAssertFalse(s.isDisplayable)
    }

    func testNewWindowBeatsAnOlderMoreRecentlyObservedClosedOne() {
        let closed = reading(97, resets: -600, observedAgo: 10)
        let open = reading(2, resets: 4 * 3600, observedAgo: 120)
        let s = evaluate([closed, open])
        XCTAssertEqual(s.utilizationPercent, 2)
    }

    func testNewestOpenReadingWins() {
        let s = evaluate([reading(40, resets: 3600, observedAgo: 600), reading(55, resets: 3600, observedAgo: 20)])
        XCTAssertEqual(s.utilizationPercent, 55)
    }

    func testUnverifiedReadingsAreIgnoredByDefaultAndNeverAuthoritative() {
        let hint = reading(77, resets: nil, authority: .unverified, source: .claudeDesktopCache)
        XCTAssertEqual(evaluate([hint]).availability, .unavailable(.noData))
        let shown = evaluate([hint], allowUnverified: true)
        XCTAssertEqual(shown.utilizationPercent, 77)
        XCTAssertFalse(shown.isAuthoritative)
        XCTAssertFalse(shown.isDisplayable, "an unverified value is never used for the menu bar")
        XCTAssertFalse(shown.isAlertEligible)
    }

    func testAuthoritativeOutranksUnverifiedEvenWhenOlder() {
        let hint = reading(77, resets: nil, observedAgo: 1, authority: .unverified)
        let real = reading(12, resets: 3600, observedAgo: 3000)
        XCTAssertEqual(evaluate([hint, real], allowUnverified: true).utilizationPercent, 12)
    }
}

final class RetryPolicyTests: XCTestCase {
    func testBackoffGrowsExponentiallyAndIsCapped() {
        let p = RetryPolicy(baseDelay: 5, maxDelay: 300, multiplier: 2, jitter: 0)
        let delays = (1...10).map { p.delay(afterFailures: $0, randomUnit: 0) }
        XCTAssertEqual(delays.prefix(5), [5, 10, 20, 40, 80])
        XCTAssertEqual(delays.last, 300)
        XCTAssertEqual(delays, delays.sorted(), "the delay never shrinks while failures continue")
        XCTAssertEqual(p.delay(afterFailures: 0, randomUnit: 0), 0)
    }

    func testJitterStaysWithinItsBound() {
        let p = RetryPolicy(baseDelay: 10, maxDelay: 1000, multiplier: 2, jitter: 0.2)
        for _ in 0..<100 {
            let d = p.delay(afterFailures: 3)
            XCTAssertGreaterThanOrEqual(d, 40)
            XCTAssertLessThanOrEqual(d, 48)
        }
    }

    func testRetryAfterOverridesTheComputedDelay() {
        let p = RetryPolicy(baseDelay: 5, maxDelay: 60, multiplier: 2, jitter: 0)
        XCTAssertEqual(p.delay(afterFailures: 1, retryAfter: 900), 900, "a server's Retry-After may exceed the usual cap")
    }

    func testRetryAfterHeaderParsing() {
        XCTAssertEqual(RetryPolicy.parseRetryAfter("120"), 120)
        XCTAssertNil(RetryPolicy.parseRetryAfter("soon"))
        XCTAssertNil(RetryPolicy.parseRetryAfter(nil))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let date = now.addingTimeInterval(90)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(RetryPolicy.parseRetryAfter(f.string(from: date), now: now)!, 90, accuracy: 1)
    }
}

final class StatusLineSourceTests: XCTestCase {
    private func write(_ file: QuotaBridgeFile, name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: dir.appendingPathComponent(name))
    }

    func testBridgeFilesBecomeAuthoritativeReadings() throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        let now = Date()
        try write(QuotaBridgeFile(sessionId: "s1", observedAt: Clock.ms(now), capturedAt: Clock.ms(now), fingerprint: "f", rateLimits: [
            "five_hour": .init(usedPercentage: 63, resetsAt: now.timeIntervalSince1970 + 7200),
            "seven_day": .init(usedPercentage: 81.5, resetsAt: now.timeIntervalSince1970 + 86400),
            "mystery": .init(usedPercentage: 5, resetsAt: nil),
        ]), name: "statusline-s1.json", in: dir)
        let readings = StatusLineQuotaSource.observations(in: dir, now: now)
        XCTAssertEqual(readings.count, 2, "unknown window names are ignored")
        XCTAssertTrue(readings.allSatisfy { $0.authority == .authoritative && $0.originSession == "s1" && $0.poolKey == "claude-subscription" })
        XCTAssertTrue(readings.allSatisfy { $0.provider == .anthropic && $0.account.isUnassigned })
        XCTAssertEqual(readings.first { $0.windowKey == "10080m" }?.utilizationPercent, 81.5)
        XCTAssertEqual(readings.first { $0.windowKey == "300m" }?.windowMinutes, 300)
    }

    func testCorruptAndForeignFilesAreIgnoredAndOldOnesPruned() throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: dir.appendingPathComponent("statusline-bad.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("other.json"), atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-20 * 86400)
        try write(QuotaBridgeFile(sessionId: "old", observedAt: Clock.ms(old), capturedAt: Clock.ms(old), fingerprint: "f",
                                  rateLimits: ["five_hour": .init(usedPercentage: 1, resetsAt: nil)]), name: "statusline-old.json", in: dir)
        XCTAssertTrue(StatusLineQuotaSource.observations(in: dir).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("statusline-old.json").path))
    }

    func testDesktopCacheIsAlwaysUnverifiedAndHasNoResetTime() throws {
        let env = try TestEnv()
        let url = env.root.appendingPathComponent("plan-usage-history.json")
        try #"{"version":2,"samples":[{"t":1790000000000,"org":"o","u":{"fh":4,"sd":0}},{"t":1790000900000,"org":"o","u":{"fh":19,"sd":41}}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let r = DesktopPlanUsageSource.observations(at: url)
        XCTAssertEqual(r.count, 2)
        XCTAssertTrue(r.allSatisfy { $0.authority == .unverified && $0.resetsAt == nil })
        XCTAssertEqual(r.first { $0.windowKey == "300m" }?.utilizationPercent, 19, "the newest sample is used")
        XCTAssertTrue(DesktopPlanUsageSource.observations(at: env.root.appendingPathComponent("missing.json")).isEmpty)
    }
}

/// Runs the real `ccu-statusline` helper binary.
final class BridgeBinaryTests: XCTestCase {
    private var helper: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ccu-statusline")
    }

    private func run(_ input: String, quotaDir: URL, arguments: [String] = []) throws -> (stdout: String, status: Int32) {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "helper binary not built")
        let p = Process()
        p.executableURL = helper
        p.arguments = arguments
        p.environment = ["CLAUDE_USAGE_MONITOR_QUOTA_DIR": quotaDir.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: out, as: UTF8.self), p.terminationStatus)
    }

    private func statusJSON(session: String = "sess-1", five: Double = 23.5, apiMs: Int = 4000) -> String {
        #"{"session_id":"\#(session)","model":{"id":"claude-opus-5-5"},"cwd":"/Users/test/secret-project","transcript_path":"/Users/test/.claude/x.jsonl","cost":{"total_cost_usd":1.5,"total_api_duration_ms":\#(apiMs)},"rate_limits":{"five_hour":{"used_percentage":\#(five),"resets_at":1893456000},"seven_day":{"used_percentage":41.2,"resets_at":1893999999}}}"#
    }

    func testWritesOnlyTheRateLimitsAndPrintsASummary() throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        let (out, status) = try run(statusJSON(), quotaDir: dir)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "5h 24% · 7d 41%")
        let text = try String(contentsOf: dir.appendingPathComponent("statusline-sess-1.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("secret-project"), "the working directory is never stored")
        XCTAssertFalse(text.contains("transcript"), "the transcript path is never stored")
        XCTAssertFalse(text.contains("claude-opus"), "the model is not stored")
        let readings = StatusLineQuotaSource.observations(in: dir, now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(readings.first { $0.windowKey == "300m" }?.utilizationPercent, 23.5)
        XCTAssertEqual(readings.first { $0.windowKey == "300m" }?.resetsAt, Date(timeIntervalSince1970: 1_893_456_000))
        // Files are private to the user.
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("statusline-sess-1.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRerenderWithoutNewApiActivityKeepsTheOriginalObservationTime() throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        _ = try run(statusJSON(), quotaDir: dir)
        let file = dir.appendingPathComponent("statusline-sess-1.json")
        let first = try JSONDecoder().decode(QuotaBridgeFile.self, from: Data(contentsOf: file))
        Thread.sleep(forTimeInterval: 0.05)
        _ = try run(statusJSON(), quotaDir: dir)        // Identical: the status line merely re-rendered.
        XCTAssertEqual(try JSONDecoder().decode(QuotaBridgeFile.self, from: Data(contentsOf: file)).observedAt, first.observedAt)
        Thread.sleep(forTimeInterval: 0.05)
        _ = try run(statusJSON(apiMs: 9000), quotaDir: dir)    // The session made another API call.
        XCTAssertGreaterThan(try JSONDecoder().decode(QuotaBridgeFile.self, from: Data(contentsOf: file)).observedAt, first.observedAt)
    }

    func testNoRateLimitsMeansNothingIsWritten() throws {
        // API-key users and brand new sessions have no rate_limits object.
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        let (out, status) = try run(#"{"session_id":"s","model":{"id":"x"}}"#, quotaDir: dir)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, "")
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
    }

    func testGarbageInputNeverFailsAndStillRunsTheChainedCommand() throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        let (out, status) = try run("<<< not json >>>", quotaDir: dir, arguments: ["--chain", "echo my-own-statusline"])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "my-own-statusline")
    }

    func testChainedCommandReceivesTheOriginalInput() throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        let (out, _) = try run(statusJSON(), quotaDir: dir, arguments: ["--chain", "cat"])
        XCTAssertEqual(out, statusJSON(), "the user's own status line sees exactly what Claude Code sent")
    }

    func testSessionIdCannotEscapeTheQuotaFolder() throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        _ = try run(statusJSON(session: "../../evil"), quotaDir: dir)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.allSatisfy { !$0.contains("/") && $0.hasPrefix("statusline-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent("evil.json").path))
    }
}

final class QuotaCoordinatorTests: XCTestCase {
    private func makeCoordinator(_ env: TestEnv, clock: @escaping @Sendable () -> Date = { Date() },
                                 hint: Bool = false) -> (QuotaCoordinator, URL, URL) {
        let dir = env.root.appendingPathComponent("quota")
        let desktop = env.root.appendingPathComponent("plan-usage-history.json")
        let settings = SettingsStore(db: env.db)
        settings.update { $0.showUnverifiedQuota = hint }
        return (QuotaCoordinator(db: env.db, settings: settings, feeds: .claude(bridgeDirectory: dir, desktopCache: desktop), clock: clock), dir, desktop)
    }

    private func writeBridge(_ dir: URL, session: String = "s1", five: Double, observed: Date, resets: Date) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = QuotaBridgeFile(sessionId: session, observedAt: Clock.ms(observed), capturedAt: Clock.ms(observed), fingerprint: "\(five)",
                                   rateLimits: ["five_hour": .init(usedPercentage: five, resetsAt: resets.timeIntervalSince1970),
                                                "seven_day": .init(usedPercentage: 81, resetsAt: resets.timeIntervalSince1970 + 86400)])
        try JSONEncoder().encode(file).write(to: dir.appendingPathComponent("statusline-\(session).json"))
    }

    func testStatesStartUnavailableAndTokenVolumeNeverCreatesAPercentage() async throws {
        let env = try TestEnv()
        // A huge amount of local token usage exists, but no quota source has reported anything.
        try Fixture.write((0..<50).map { Fixture.assistant(id: "m\($0)", session: "S", at: t0 + Int64($0), input: 1_000_000, output: 1_000_000, cacheRead: 50_000_000) },
                          to: try env.mainFile(session: "S"))
        try env.syncAll()
        let (coordinator, _, _) = makeCoordinator(env)
        await coordinator.start()
        let states = await coordinator.states().filter { $0.pool.key.provider == .anthropic }
        XCTAssertEqual(states.map(\.windowKey), ["300m", "10080m"])
        for s in states {
            XCTAssertEqual(s.availability, .unavailable(.noData))
            XCTAssertNil(s.utilizationPercent, "no percentage may be inferred from token counts")
        }
        await coordinator.stop()
    }

    func testBridgeFileUpdatesStateAndIsRecordedOnceInHistory() async throws {
        let env = try TestEnv()
        let (coordinator, dir, _) = makeCoordinator(env)
        await coordinator.start()
        let stream = await coordinator.changes()
        var iterator = stream.makeAsyncIterator()

        let now = Date()
        try writeBridge(dir, five: 63, observed: now, resets: now.addingTimeInterval(7200))
        // Wait for the file event to reach the coordinator.
        _ = await iterator.next()
        var state = await coordinator.window("300m")!
        for _ in 0..<30 where state.utilizationPercent == nil {
            try await Task.sleep(for: .milliseconds(100))
            state = await coordinator.window("300m")!
        }
        XCTAssertEqual(state.utilizationPercent, 63)
        XCTAssertEqual(state.remainingPercent, 37)

        // Refreshing again with the same data adds nothing to the history.
        await coordinator.refresh(force: true)
        await coordinator.refresh(force: true)
        let rows = try env.db.read { try $0.scalarInt("SELECT count(*) FROM quota_snapshot q JOIN quota_window w ON w.id = q.window_id WHERE w.window_key = '300m'") }
        XCTAssertEqual(rows, 1)

        // A genuinely new value is appended.
        try writeBridge(dir, five: 70, observed: now.addingTimeInterval(60), resets: now.addingTimeInterval(7200))
        await coordinator.refresh(force: true)
        let after = try env.db.read { try $0.scalarInt("SELECT count(*) FROM quota_snapshot q JOIN quota_window w ON w.id = q.window_id WHERE w.window_key = '300m'") }
        XCTAssertEqual(after, 2)
        await coordinator.stop()
    }

    func testAccountUsageCanFarExceedWhatLocalSessionsExplain() async throws {
        // The account is at 90% although local logs show almost nothing: the percentage is shown as reported.
        let env = try TestEnv()
        try Fixture.write([Fixture.assistant(id: "tiny", session: "S", at: t0, input: 1, output: 1)], to: try env.mainFile(session: "S"))
        try env.syncAll()
        let (coordinator, dir, _) = makeCoordinator(env)
        let now = Date()
        try writeBridge(dir, five: 90, observed: now, resets: now.addingTimeInterval(3600))
        await coordinator.start()
        try await Task.sleep(for: .milliseconds(300))
        let s = await coordinator.window("300m")!
        XCTAssertEqual(s.utilizationPercent, 90)
        XCTAssertTrue(s.isAuthoritative)
        await coordinator.stop()
    }

    func testReadingBecomesStaleAndWindowElapsesAsTimePasses() async throws {
        let env = try TestEnv()
        let base = Date()
        let box = ClockBox(base)
        let (coordinator, dir, _) = makeCoordinator(env, clock: { box.now })
        try writeBridge(dir, five: 55, observed: base, resets: base.addingTimeInterval(2 * 3600))
        await coordinator.start()
        try await Task.sleep(for: .milliseconds(300))
        var s = await coordinator.window("300m")!
        XCTAssertEqual(s.freshness, .fresh)

        box.now = base.addingTimeInterval(90 * 60)
        s = await coordinator.window("300m")!
        XCTAssertEqual(s.freshness, .stale)
        XCTAssertEqual(s.utilizationPercent, 55)

        box.now = base.addingTimeInterval(3 * 3600)
        s = await coordinator.window("300m")!
        if case .windowElapsed = s.availability {} else { XCTFail("expected an elapsed window, got \(s.availability)") }
        XCTAssertNil(s.utilizationPercent)
        await coordinator.stop()
    }

    func testDesktopHintOnlyAppearsWhenEnabledAndIsNeverAuthoritative() async throws {
        let env = try TestEnv()
        let (off, _, desktop) = makeCoordinator(env, hint: false)
        try #"{"version":2,"samples":[{"t":\#(Clock.nowMs()),"org":"o","u":{"fh":19,"sd":41}}]}"#.write(to: desktop, atomically: true, encoding: .utf8)
        await off.start()
        try await Task.sleep(for: .milliseconds(200))
        let offStates = await off.states().filter { $0.pool.key.provider == .anthropic }
        XCTAssertEqual(offStates.first?.availability, .unavailable(.noData))
        await off.stop()

        let env2 = try TestEnv()
        let (on, _, desktop2) = makeCoordinator(env2, hint: true)
        try #"{"version":2,"samples":[{"t":\#(Clock.nowMs()),"org":"o","u":{"fh":19,"sd":41}}]}"#.write(to: desktop2, atomically: true, encoding: .utf8)
        await on.start()
        try await Task.sleep(for: .milliseconds(200))
        let s = await on.window("300m")!
        XCTAssertEqual(s.utilizationPercent, 19)
        XCTAssertFalse(s.isAuthoritative)
        XCTAssertFalse(s.isDisplayable)
        let history = try env2.db.read { try $0.scalarInt("SELECT count(*) FROM quota_snapshot") }
        XCTAssertEqual(history, 0, "unverified values are not recorded as quota history")
        await on.stop()
    }

    func testSpendLimitWindowAppearsWhenReported() async throws {
        let env = try TestEnv()
        let (coordinator, dir, _) = makeCoordinator(env)
        let now = Date()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = QuotaBridgeFile(sessionId: "g", observedAt: Clock.ms(now), capturedAt: Clock.ms(now), fingerprint: "x",
                                rateLimits: ["spend_limit": .init(usedPercentage: 62.8, resetsAt: now.timeIntervalSince1970 + 86400)])
        try JSONEncoder().encode(f).write(to: dir.appendingPathComponent("statusline-g.json"))
        await coordinator.start()
        try await Task.sleep(for: .milliseconds(300))
        let keys = await coordinator.states().filter { $0.pool.key.provider == .anthropic }.map(\.windowKey)
        XCTAssertEqual(Set(keys), ["300m", "10080m", "spend_limit"])
        let spend = await coordinator.window("spend_limit")!
        XCTAssertNil(spend.windowMinutes, "a spend limit has no fixed length")
        XCTAssertEqual(spend.utilizationPercent, 62.8)
        await coordinator.stop()
    }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ d: Date) { value = d }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
