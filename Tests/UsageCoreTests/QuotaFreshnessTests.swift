import XCTest
@testable import UsageCore

private typealias CF = CodexFixture

/// The guarantee that a quota reading is as fresh as the moment it was taken, and never fresher because the
/// application read it again.
final class QuotaFreshnessTests: XCTestCase {
    private func coordinator(_ env: TestEnv, now: Date) -> QuotaCoordinator {
        QuotaCoordinator(db: env.db, settings: SettingsStore(db: env.db),
                         feeds: .claude(bridgeDirectory: env.root.appendingPathComponent("quota"),
                                        desktopCache: env.root.appendingPathComponent("none.json")), clock: { now })
    }

    private func window(_ env: TestEnv, now: Date, key: String = "300m", provider: ProviderID = .openAI) async throws -> QuotaWindowState {
        let pools = await coordinator(env, now: now).pools()
        let pool = try XCTUnwrap(pools.first { $0.pool.key.provider == provider && $0.pool.accountLabel != "Unassigned" })
        return try XCTUnwrap(pool.windows.first { $0.windowKey == key })
    }

    private func reading(_ ordinal: Int, at ms: Int64, _ percent: Double, reset: Double = 1_790_010_000, weekly: Double = 20) -> String {
        let u = CF.Usage(input: 100 * Int64(ordinal), output: 10)
        return CF.tokenCount(ordinal: ordinal, at: ms, last: CF.Usage(input: 100, output: 10), total: u,
                             rate: CF.rateLimits(primary: (percent, 300, reset), secondary: (weekly, 10080, 1_790_500_000)))
    }

    private func at(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    // MARK: Replay

    func testReadingAnOldFileAgainDoesNotMakeItsReadingFresh() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"), reading(1, at: t0 + 1000, 64)])
        try env.syncCodex()
        let later = at(t0 + 3 * 3_600_000)
        let first = try await window(env, now: later)
        XCTAssertEqual(first.freshness, .stale)

        // The file is touched, copied and read again, several times, three hours later.
        let url = env.codexHome.appendingPathComponent("sessions/2026/10/12/rollout-2026-10-12T12-00-00-\(CF.sessionA).jsonl")
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        try env.db.write { try $0.run("UPDATE source_file SET size = 0, mtime_ms = 0") }
        try env.syncCodex()
        try env.codexFile(session: CF.sessionB, lines: [CF.header(id: CF.sessionB, at: t0, account: "acct-one"), reading(1, at: t0 + 1000, 64)], archived: true)
        try env.syncCodex()

        let second = try await window(env, now: later)
        XCTAssertEqual(second.freshness, .stale, "reading the same event again is not a new observation")
        XCTAssertEqual(second.reading?.observedAt, at(t0 + 1000))
        XCTAssertEqual(second.reading?.observedAt, first.reading?.observedAt)
    }

    func testRebuildingTheDatabaseFromTheSameFilesGivesTheSameFreshness() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"),
                                                          reading(1, at: t0 + 1000, 40), reading(2, at: t0 + 600_000, 45)])
        try env.syncCodex()
        let now = at(t0 + 2 * 3_600_000)
        let before = try await window(env, now: now)

        // A new database stands for deleting the application's data, and the same files are imported again.
        let rebuilt = try TestEnv(copyingCodexFilesFrom: env)
        try rebuilt.syncCodex()
        let after = try await window(rebuilt, now: now)
        XCTAssertEqual(after.reading?.observedAt, before.reading?.observedAt)
        XCTAssertEqual(after.reading?.utilizationPercent, 45)
        XCTAssertEqual(after.freshness, before.freshness)
        XCTAssertEqual(after.freshness, .stale)
    }

    func testAnArchivedSnapshotNewerThanAnActiveOneWins() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"), reading(1, at: t0 + 1000, 20)])
        try env.codexFile(session: CF.sessionB, lines: [CF.header(id: CF.sessionB, at: t0, account: "acct-one"), reading(1, at: t0 + 500_000, 33)], archived: true)
        try env.syncCodex()
        let state = try await window(env, now: at(t0 + 510_000))
        XCTAssertEqual(state.utilizationPercent, 33)
        XCTAssertEqual(state.freshness, .fresh)
    }

    // MARK: Cycles

    func testCyclesThatBeginAMinuteApartAreNotMerged() async throws {
        let env = try TestEnv()
        // Reset times 53 seconds apart were found in real files of an account that was not named. They are two pools,
        // and a tolerance of five minutes would have made them one cycle.
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0, account: "acct-one"),
            reading(1, at: t0 + 1000, 16, reset: 1_790_010_000),
            reading(2, at: t0 + 2000, 4, reset: 1_790_010_053),
            reading(3, at: t0 + 3000, 17, reset: 1_790_010_002),     // Jitter of the first cycle.
        ])
        try env.syncCodex()
        XCTAssertEqual(try env.db.read { try $0.scalarInt("SELECT count(*) FROM quota_cycle WHERE window_id IN (SELECT id FROM quota_window WHERE window_key = '300m')") }, 2)
    }

    func testALowerValueThatArrivesLaterInTheSameCycleDoesNotReplaceTheHigherOne() async throws {
        let env = try TestEnv()
        // Two sessions of one account run at once and deliver their readings out of order. Within a cycle the utilization
        // only grows, so 17 after 18 belongs to a response that started earlier.
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"), reading(1, at: t0 + 1000, 18)])
        try env.codexFile(session: CF.sessionB, lines: [CF.header(id: CF.sessionB, at: t0, account: "acct-one"), reading(1, at: t0 + 6000, 17)])
        try env.syncCodex()
        let state = try await window(env, now: at(t0 + 7000))
        XCTAssertEqual(state.utilizationPercent, 18)
        XCTAssertEqual(state.reading?.observedAt, at(t0 + 1000), "freshness is that of the reading shown")
    }

    func testANewCycleAfterAResetDoesNotInheritTheOldHigherValue() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0, account: "acct-one"),
            reading(1, at: t0 + 1000, 90, reset: 1_790_010_000),
            reading(2, at: t0 + 20_000_000, 3, reset: 1_790_028_000),
        ])
        try env.syncCodex()
        let state = try await window(env, now: at(t0 + 20_001_000))
        XCTAssertEqual(state.utilizationPercent, 3)
    }

    func testAnAccountSwitchKeepsBothAccountsAndNeverShowsOneInTheOther() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"), reading(1, at: t0 + 1000, 60)])
        try env.codexFile(session: CF.sessionB, lines: [CF.header(id: CF.sessionB, at: t0 + 5000, account: "acct-two"), reading(1, at: t0 + 6000, 5)])
        try env.syncCodex()
        let pools = await coordinator(env, now: at(t0 + 10_000)).pools().filter { $0.pool.key.provider == .openAI && $0.pool.accountLabel != "Unassigned" }
        XCTAssertEqual(pools.count, 2)
        XCTAssertEqual(Set(pools.compactMap { $0.windows.first?.utilizationPercent }), [60, 5])
    }

    // MARK: Clocks

    func testAReadingDatedInTheFutureIsNotRecorded() async throws {
        let env = try TestEnv()
        let future = Clock.nowMs() + 3_600_000
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"), reading(1, at: future, 99)])
        try env.syncCodex()
        XCTAssertEqual(try env.db.read { try $0.scalarInt("SELECT count(*) FROM quota_snapshot") }, 0, "a wrong clock must not make a reading look current")
        XCTAssertEqual(try env.totals().requests, 1, "the usage itself is still counted")
    }

    func testAClockMovedBackMakesAReadingStaleInsteadOfNew() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"), reading(1, at: t0 + 1000, 50)])
        try env.syncCodex()
        let state = try await window(env, now: at(t0 - 3 * 3_600_000))
        XCTAssertEqual(state.freshness, .stale)
    }

    // MARK: Claude's status line

    private func writeBridge(_ env: TestEnv, observedMs: Int64, percent: Double, fingerprint: String = "f") throws {
        let dir = env.root.appendingPathComponent("quota")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = QuotaBridgeFile(sessionId: "s", observedAt: observedMs, capturedAt: observedMs, fingerprint: fingerprint,
                                   rateLimits: ["five_hour": .init(usedPercentage: percent, resetsAt: Double(observedMs) / 1000 + 3600 * 4)])
        try JSONEncoder().encode(file).write(to: dir.appendingPathComponent("statusline-s.json"))
    }

    func testClaudeReadingsSurviveARestartAndARewriteOfTheFileWithoutBecomingFresh() async throws {
        let env = try TestEnv()
        let observed = t0
        try writeBridge(env, observedMs: observed, percent: 41)
        let now = at(observed + 2 * 3_600_000)
        let first = coordinator(env, now: now)
        await first.refresh(force: true)
        let before = await first.window("300m")
        XCTAssertEqual(before?.freshness, .stale)

        // The application restarts, and the file is written again with the same content.
        try writeBridge(env, observedMs: observed, percent: 41)
        let second = coordinator(env, now: now)
        await second.refresh(force: true)
        let after = await second.window("300m")
        XCTAssertEqual(after?.reading?.observedAt, before?.reading?.observedAt)
        XCTAssertEqual(after?.freshness, .stale)
    }

    func testAClaudeReadingDatedInTheFutureIsIgnored() async throws {
        let env = try TestEnv()
        try writeBridge(env, observedMs: Clock.nowMs() + 2 * 3_600_000, percent: 99)
        let c = QuotaCoordinator(db: env.db, settings: SettingsStore(db: env.db),
                                 feeds: .claude(bridgeDirectory: env.root.appendingPathComponent("quota"),
                                                desktopCache: env.root.appendingPathComponent("none.json")))
        await c.refresh(force: true)
        let state = await c.window("300m")
        XCTAssertNil(state?.utilizationPercent)
    }
}

/// What the status line helper claims about the age of a reading it sees for the first time.
final class StatusLineFirstSightTests: XCTestCase {
    private var helper: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ccu-statusline")
    }

    private func run(_ input: String, quotaDir: URL) throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "helper binary not built")
        let p = Process()
        p.executableURL = helper
        p.environment = ["CLAUDE_USAGE_MONITOR_QUOTA_DIR": quotaDir.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
    }

    private func json(transcript: String, apiMs: Int) -> String {
        #"{"session_id":"first-sight","transcript_path":"\#(transcript)","cost":{"total_cost_usd":1.5,"total_api_duration_ms":\#(apiMs)},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1893456000}}}"#
    }

    func testTheFirstSightOfARunningSessionIsNotDatedNow() throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        // The session has been quiet for three hours. Its transcript was last written then.
        let transcript = env.root.appendingPathComponent("session.jsonl")
        try "{}".write(to: transcript, atomically: true, encoding: .utf8)
        let threeHoursAgo = Date().addingTimeInterval(-3 * 3600)
        try FileManager.default.setAttributes([.modificationDate: threeHoursAgo], ofItemAtPath: transcript.path)
        try run(json(transcript: transcript.path, apiMs: 1000), quotaDir: dir)

        let file = dir.appendingPathComponent("statusline-first-sight.json")
        let first = try JSONDecoder().decode(QuotaBridgeFile.self, from: Data(contentsOf: file))
        XCTAssertEqual(Double(first.observedAt) / 1000, threeHoursAgo.timeIntervalSince1970, accuracy: 2)
        XCTAssertGreaterThan(first.capturedAt, first.observedAt + 3 * 3_600_000 - 5000, "the capture time is still recorded separately")

        // A later API call changes the fingerprint, and then the reading really is from this moment.
        try run(json(transcript: transcript.path, apiMs: 2500), quotaDir: dir)
        let second = try JSONDecoder().decode(QuotaBridgeFile.self, from: Data(contentsOf: file))
        XCTAssertGreaterThan(second.observedAt, first.observedAt + 3 * 3_600_000 - 5000)
    }

    func testWithoutATranscriptTheCaptureTimeIsUsed() throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        try run(json(transcript: "/nonexistent/transcript.jsonl", apiMs: 1000), quotaDir: dir)
        let file = try JSONDecoder().decode(QuotaBridgeFile.self, from: Data(contentsOf: dir.appendingPathComponent("statusline-first-sight.json")))
        XCTAssertEqual(file.observedAt, file.capturedAt)
    }

    func testAWindowThatDropsOutAtItsResetDoesNotMakeTheRemainingOnesLookNew() throws {
        let env = try TestEnv()
        let dir = env.root.appendingPathComponent("quota")
        func payload(apiMs: Int, windows: String) -> String {
            #"{"session_id":"drop","cost":{"total_cost_usd":1.5,"total_api_duration_ms":\#(apiMs)},"rate_limits":{\#(windows)}}"#
        }
        let five = #""five_hour":{"used_percentage":30,"resets_at":1893456000}"#
        let week = #""seven_day":{"used_percentage":41,"resets_at":1893999999}"#
        try run(payload(apiMs: 1000, windows: five + "," + week), quotaDir: dir)
        let file = dir.appendingPathComponent("statusline-drop.json")
        let first = try JSONDecoder().decode(QuotaBridgeFile.self, from: Data(contentsOf: file))
        Thread.sleep(forTimeInterval: 0.05)
        // The five-hour window reached its reset time and is gone, and nothing else has happened.
        try run(payload(apiMs: 1000, windows: week), quotaDir: dir)
        let second = try JSONDecoder().decode(QuotaBridgeFile.self, from: Data(contentsOf: file))
        XCTAssertEqual(second.observedAt, first.observedAt)
        XCTAssertEqual(second.rateLimits["seven_day"]?.usedPercentage, 41)
        // After a real API call the remaining window is observed again.
        Thread.sleep(forTimeInterval: 0.05)
        try run(payload(apiMs: 2000, windows: #""seven_day":{"used_percentage":42,"resets_at":1893999999}"#), quotaDir: dir)
        let third = try JSONDecoder().decode(QuotaBridgeFile.self, from: Data(contentsOf: file))
        XCTAssertGreaterThan(third.observedAt, first.observedAt)
        XCTAssertEqual(third.rateLimits["seven_day"]?.usedPercentage, 42)
    }
}
