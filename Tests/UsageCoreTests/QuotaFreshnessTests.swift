import XCTest
@testable import UsageCore

private typealias CF = CodexFixture

/// The guarantee that a quota reading is as fresh as the moment it was taken, and never fresher because the
/// application read it again.
final class QuotaFreshnessTests: XCTestCase {
    private func claudeCache(_ env: TestEnv) -> URL { env.root.appendingPathComponent("claude/.claude.json") }

    private func coordinator(_ env: TestEnv, now: Date) -> QuotaCoordinator {
        QuotaCoordinator(db: env.db, settings: SettingsStore(db: env.db),
                         feeds: .claude(desktopCache: env.root.appendingPathComponent("none.json"),
                                        cache: claudeCache(env)), clock: { now })
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

    // MARK: Claude's local cache

    private func writeClaudeCache(_ env: TestEnv, observedMs: Int64, percent: Double) throws {
        let observed = Clock.date(ms: observedMs)
        try ClaudeCacheFixture.write(to: claudeCache(env), fetchedAt: observed, five: percent, week: nil,
                                     fiveReset: observed.addingTimeInterval(3600 * 4), weekReset: nil)
    }

    func testClaudeReadingsSurviveARestartAndARewriteOfTheFileWithoutBecomingFresh() async throws {
        let env = try TestEnv()
        let observed = t0
        try writeClaudeCache(env, observedMs: observed, percent: 41)
        let now = at(observed + 3 * 3_600_000)
        let first = coordinator(env, now: now)
        await first.refresh(force: true)
        let before = await first.window("300m")
        XCTAssertEqual(before?.freshness, .stale)

        // The application restarts, and the file is written again with the same content.
        try writeClaudeCache(env, observedMs: observed, percent: 41)
        let second = coordinator(env, now: now)
        await second.refresh(force: true)
        let after = await second.window("300m")
        XCTAssertEqual(after?.reading?.observedAt, before?.reading?.observedAt)
        XCTAssertEqual(after?.freshness, .stale)
    }

    func testAClaudeReadingDatedInTheFutureIsIgnored() async throws {
        let env = try TestEnv()
        try writeClaudeCache(env, observedMs: Clock.nowMs() + 2 * 3_600_000, percent: 99)
        let c = QuotaCoordinator(db: env.db, settings: SettingsStore(db: env.db),
                                 feeds: .claude(desktopCache: env.root.appendingPathComponent("none.json"),
                                                cache: claudeCache(env)))
        await c.refresh(force: true)
        let state = await c.window("300m")
        XCTAssertNil(state?.utilizationPercent)
    }
}
