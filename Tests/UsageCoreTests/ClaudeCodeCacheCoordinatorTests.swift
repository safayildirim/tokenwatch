import Foundation
import XCTest
@testable import UsageCore

/// End-to-end tests for the local cache through the same coordinator, store and evaluator that production uses.
final class ClaudeCodeCacheCoordinatorTests: XCTestCase {
    private let accountA = "11111111-2222-4333-8444-555555555555"
    private let accountB = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    private let now = Date(timeIntervalSince1970: 1_792_650_000)
    private let reset = Date(timeIntervalSince1970: 1_792_653_600)

    private func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private func cacheDocument(account: String,
                               fetchedAt: Date,
                               five: Double?,
                               week: Double?,
                               reset: Date,
                               fiveReset: Date? = nil,
                               scoped: [(String, Double)] = []) -> Data {
        var shared: [String] = []
        if let five {
            let fiveResetField = fiveReset.map { "\"\(timestamp($0))\"" } ?? "null"
            shared.append("\"five_hour\":{\"utilization\":\(five),\"resets_at\":\(fiveResetField)}")
        }
        if let week {
            shared.append("\"seven_day\":{\"utilization\":\(week),\"resets_at\":\"\(timestamp(reset))\"}")
        }
        let limits = scoped.map { name, percent in
            "{\"kind\":\"weekly_scoped\",\"percent\":\(percent),\"resets_at\":\"\(timestamp(reset))\",\"scope\":{\"model\":{\"id\":null,\"display_name\":\"\(name)\"}}}"
        }
        var fields = shared
        if !limits.isEmpty { fields.append("\"limits\":[\(limits.joined(separator: ","))]") }
        if fields.isEmpty { fields.append("\"five_hour\":null") }
        let json = "{\"cachedUsageUtilization\":{\"accountUuid\":\"\(account)\",\"fetchedAtMs\":\(Clock.ms(fetchedAt)),\"utilization\":{\(fields.joined(separator: ","))}}}"
        return Data(json.utf8)
    }

    private func writeCache(_ url: URL, _ data: Data, atomic: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: atomic ? .atomic : [])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func coordinator(_ env: TestEnv, cache: URL, now: Date? = nil) -> QuotaCoordinator {
        let at = now ?? self.now
        return QuotaCoordinator(db: env.db, settings: SettingsStore(db: env.db), feeds: [ClaudeCodeCacheFeed(url: cache)], clock: { at })
    }

    private func snapshotCount(_ env: TestEnv) throws -> Int {
        try env.db.read { try Int($0.scalarInt("SELECT count(*) FROM quota_snapshot") ?? 0) }
    }

    private func accountID(_ env: TestEnv, hash: String?) throws -> Int64 {
        try env.db.read {
            try XCTUnwrap($0.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ?",
                                        [.text(hash ?? "")]))
        }
    }

    private func cacheAccountID(_ env: TestEnv, _ raw: String) throws -> Int64 {
        try accountID(env, hash: ClaudeCodeCacheSource.accountFingerprint(raw))
    }

    private func windowState(_ coordinator: QuotaCoordinator, _ key: String, accountID: Int64? = nil) async throws -> QuotaWindowState {
        let states = await coordinator.states()
        return try XCTUnwrap(states.first {
            $0.windowKey == key && (accountID == nil || $0.pool.key.accountID == accountID)
        })
    }

    private func poolWindows(_ coordinator: QuotaCoordinator, accountID: Int64) async -> [QuotaWindowState] {
        await coordinator.states().filter { $0.pool.key.accountID == accountID }
    }

    func testCacheIsIngestedAndSurvivesARestart() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        let fetched = now.addingTimeInterval(-3 * 3_600)
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: fetched, five: 20, week: 40, reset: reset))
        let first = coordinator(env, cache: cache)
        await first.refresh(force: true)

        let states = await first.states()
        let five = try XCTUnwrap(states.first { $0.windowKey == "300m" })
        let week = try XCTUnwrap(states.first { $0.windowKey == "10080m" })
        XCTAssertEqual(five.utilizationPercent, 20)
        XCTAssertEqual(week.utilizationPercent, 40)
        XCTAssertEqual(five.freshness, .stale, "the cache is already three hours old")
        XCTAssertEqual(five.reading?.observedAt, fetched)
        XCTAssertEqual(five.reading?.source, .claudeCodeCache)
        XCTAssertTrue(five.reading?.authority == .authoritative)
        XCTAssertEqual(five.pool.key.accountID, try cacheAccountID(env, accountA))
        XCTAssertFalse(five.pool.accountLabel == "Unassigned", "the cache account is identified, not the unassigned pool")
        XCTAssertEqual(try snapshotCount(env), 2)
        let feed = await first.feedStatus().first { $0.id == .claudeCodeCache }
        XCTAssertEqual(feed?.sourceExists, true)
        XCTAssertEqual(feed?.issue, nil)
        XCTAssertNotNil(feed?.lastSuccess)
        await first.stop()

        // Restarting must neither lose the reading nor make it look newer.
        try env.reopen()
        let second = coordinator(env, cache: cache, now: now.addingTimeInterval(60))
        await second.refresh(force: true)
        let again = try await windowState(second, "300m")
        XCTAssertEqual(again.reading?.observedAt, fetched)
        XCTAssertEqual(again.freshness, .stale)
        XCTAssertEqual(try snapshotCount(env), 2, "identical cache content must not add snapshots")
        await second.stop()
    }

    func testRewritingTheCacheWithoutANewFetchDoesNotCreateHistory() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        let data = cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-60), five: 20, week: 40, reset: reset)
        try writeCache(cache, data)
        let c = coordinator(env, cache: cache)
        await c.refresh(force: true)
        XCTAssertEqual(try snapshotCount(env), 2)
        // A changed file modification time is not a new observation: only `fetchedAtMs` is.
        try writeCache(cache, data, atomic: false)
        await c.refresh(force: true)
        await c.refresh(force: true)
        XCTAssertEqual(try snapshotCount(env), 2)
        await c.stop()
    }

    func testAnAccountChangeKeepsBothAccountsInSeparateHistoricalPools() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        let firstFetch = now.addingTimeInterval(-20 * 60)
        let secondFetch = now.addingTimeInterval(-5 * 60)
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: firstFetch, five: 10, week: 20, reset: reset))
        let c = coordinator(env, cache: cache)
        await c.refresh(force: true)
        let a = try cacheAccountID(env, accountA)
        let first = try await windowState(c, "10080m", accountID: a)
        XCTAssertEqual(first.utilizationPercent, 20)

        try writeCache(cache, cacheDocument(account: accountB, fetchedAt: secondFetch, five: 60, week: 70, reset: reset))
        await c.refresh(force: true)
        let b = try cacheAccountID(env, accountB)
        XCTAssertNotEqual(a, b)
        let oldAccount = try await windowState(c, "10080m", accountID: a)
        let newAccount = try await windowState(c, "10080m", accountID: b)
        XCTAssertEqual(oldAccount.utilizationPercent, 20, "the first account's history is preserved, not overwritten")
        XCTAssertEqual(oldAccount.reading?.observedAt, firstFetch)
        XCTAssertEqual(newAccount.utilizationPercent, 70)
        XCTAssertEqual(newAccount.reading?.observedAt, secondFetch)
        XCTAssertEqual(try snapshotCount(env), 4, "two weeks and two five-hour windows, never a combined value")
        let aWindows = await poolWindows(c, accountID: a)
        let bWindows = await poolWindows(c, accountID: b)
        XCTAssertEqual(aWindows.count, 2)
        XCTAssertEqual(bWindows.count, 2)
        let feed = await c.feedStatus().first { $0.id == .claudeCodeCache }
        XCTAssertEqual(feed?.issue, .accountChanged)
        await c.stop()

        // A restart must preserve both account pools and keep them distinct.
        try env.reopen()
        let restarted = coordinator(env, cache: cache, now: now.addingTimeInterval(60))
        await restarted.refresh(force: true)
        let oldAfterRestart = try await windowState(restarted, "10080m", accountID: a)
        let newAfterRestart = try await windowState(restarted, "10080m", accountID: b)
        XCTAssertEqual(oldAfterRestart.utilizationPercent, 20)
        XCTAssertEqual(newAfterRestart.utilizationPercent, 70)
        XCTAssertEqual(try snapshotCount(env), 4)
        await restarted.stop()
    }

    func testAtomicReplacementOfTheCacheArmsAgainAndUpdatesTheState() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-60),
                                            five: 10, week: 20, reset: reset))
        let c = coordinator(env, cache: cache)
        await c.start()
        var state = try await windowState(c, "300m")
        XCTAssertEqual(state.utilizationPercent, 10)

        // An atomic write replaces the inode. The file watcher must notice, re-arm on the new inode, and the
        // coordinator must read the new snapshot without waiting for the slow safety refresh.
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-10),
                                            five: 25, week: 35, reset: reset))
        for _ in 0..<60 {
            state = try await windowState(c, "300m")
            if state.utilizationPercent == 25 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(state.utilizationPercent, 25)
        XCTAssertEqual(state.reading?.observedAt, now.addingTimeInterval(-10))
        await c.stop()
    }

    func testCachedModelScopesStayInTheirOwnWindowsAndPool() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-60),
                                            five: 10, week: 20, reset: reset,
                                            scoped: [("Alpha", 30), ("Beta", 40)]))
        let c = coordinator(env, cache: cache)
        await c.refresh(force: true)
        let windows = await c.states().filter { $0.pool.key.provider == .anthropic }
        XCTAssertEqual(windows.count, 4)
        XCTAssertEqual(Set(windows.map(\.windowKey)).count, 4)
        XCTAssertEqual(windows.compactMap { WindowNaming.scopedLabel(fallbackKey: $0.windowKey) }.sorted(), ["Alpha", "Beta"])
        XCTAssertEqual(windows.filter { $0.windowKey.hasPrefix("scoped:") }.map(\.utilizationPercent).compactMap { $0 }.sorted(),
                       [30, 40])
        XCTAssertEqual(try snapshotCount(env), 4)
        await c.stop()
    }


    func testAStaleCacheStillShowsItsLastKnownValueAndSource() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-4 * 3_600),
                                            five: 0, week: 99, reset: reset))
        let c = coordinator(env, cache: cache)
        await c.refresh(force: true)
        let state = try await windowState(c, "10080m")
        XCTAssertEqual(state.utilizationPercent, 99, "an old reading is shown, not turned into zero")
        XCTAssertEqual(state.freshness, .stale)
        XCTAssertEqual(state.reading?.source, .claudeCodeCache)
        await c.stop()
    }

    // MARK: Freshness comes from the source's fetch time

    private func lastConfirmed(_ env: TestEnv, _ key: String) throws -> Int64? {
        try env.db.read {
            try $0.scalarInt("""
                SELECT max(q.last_confirmed_at) FROM quota_snapshot q JOIN quota_window w ON w.id = q.window_id
                WHERE w.window_key = ? AND q.telemetry_source_id = ?
                """, [.text(key), .text(TelemetrySourceID.claudeCodeCache.rawValue)])
        }
    }

    /// Re-reading a snapshot that Claude Code has not fetched again, whether the file was rewritten or the app was
    /// restarted, must never make it look newly confirmed, however much later the read happens.
    func testReReadingTheSameSnapshotLaterNeverMakesItFresher() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        let fetched = now.addingTimeInterval(-5 * 60)
        let data = cacheDocument(account: accountA, fetchedAt: fetched, five: 20, week: 40, reset: reset)
        try writeCache(cache, data)
        let first = coordinator(env, cache: cache)
        await first.refresh(force: true)
        let beforeRestart = try await windowState(first, "300m")
        XCTAssertEqual(beforeRestart.freshness, .fresh)
        await first.stop()

        // Three hours later the whole file is rewritten with the same snapshot, then the app restarts and reads it.
        let later = now.addingTimeInterval(3 * 3_600)
        try writeCache(cache, data, atomic: false)
        try env.reopen()
        let second = coordinator(env, cache: cache, now: later)
        await second.refresh(force: true)
        await second.refresh(force: true)
        let state = try await windowState(second, "300m")
        XCTAssertEqual(state.reading?.observedAt, fetched, "the reading is as old as Claude Code's fetch, not as the read")
        XCTAssertEqual(state.freshness, .stale)
        XCTAssertFalse(state.isAlertEligible, "a stale reading must not drive an alert")
        XCTAssertEqual(try lastConfirmed(env, "300m"), Clock.ms(fetched))
        XCTAssertEqual(try snapshotCount(env), 2)
        await second.stop()
    }

    /// A genuinely newer fetch confirms the reading again even when the percentages have not moved, and it does so
    /// without adding a second snapshot of the same value.
    func testANewerFetchWithTheSamePercentagesRefreshesTheReading() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        let oldFetch = now.addingTimeInterval(-3 * 3_600)
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: oldFetch, five: 20, week: 40, reset: reset))
        let c = coordinator(env, cache: cache)
        await c.refresh(force: true)
        let beforeNewFetch = try await windowState(c, "300m")
        XCTAssertEqual(beforeNewFetch.freshness, .stale)

        let newFetch = now.addingTimeInterval(-60)
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: newFetch, five: 20, week: 40, reset: reset))
        await c.refresh(force: true)
        let state = try await windowState(c, "300m")
        XCTAssertEqual(state.utilizationPercent, 20)
        XCTAssertEqual(state.reading?.observedAt, newFetch)
        XCTAssertEqual(state.freshness, .fresh)
        XCTAssertTrue(state.isAlertEligible)
        XCTAssertEqual(try lastConfirmed(env, "300m"), Clock.ms(newFetch))
        XCTAssertEqual(try snapshotCount(env), 2, "the same value is confirmed again, not stored twice")

        // An older snapshot that appears afterwards, for example from a restored file, does not move it back.
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: oldFetch, five: 20, week: 40, reset: reset))
        await c.refresh(force: true)
        XCTAssertEqual(try lastConfirmed(env, "300m"), Clock.ms(newFetch))
        await c.stop()
    }

    /// A window whose reset time has passed is unknown until Claude Code fetches again. It is never shown as zero
    /// and it is never alerted on.
    func testAnExpiredWindowIsUnknownNotZero() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        let fiveReset = now.addingTimeInterval(-60)
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-30 * 60),
                                            five: 85, week: 40, reset: reset, fiveReset: fiveReset))
        let c = coordinator(env, cache: cache)
        await c.refresh(force: true)
        let state = try await windowState(c, "300m")
        XCTAssertEqual(state.availability, .windowElapsed(resetAt: fiveReset))
        XCTAssertFalse(state.isDisplayable)
        XCTAssertFalse(state.isAlertEligible)
        let weekly = try await windowState(c, "10080m")
        XCTAssertEqual(weekly.utilizationPercent, 40, "the weekly window is still open")
        await c.stop()
    }

    /// The clock moving forward ages a reading normally. The clock moving back leaves a stored reading dated in the
    /// future; how old it really is cannot be known, so it is stale rather than new. A snapshot that claims to have
    /// been fetched in the future is not recorded at all.
    func testClockChangesNeverMakeAReadingLookNewer() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-60), five: 20, week: 40, reset: reset))
        let c = coordinator(env, cache: cache)
        await c.refresh(force: true)
        let beforeClockChange = try await windowState(c, "300m")
        XCTAssertEqual(beforeClockChange.freshness, .fresh)
        await c.stop()

        let forward = coordinator(env, cache: cache, now: now.addingTimeInterval(3 * 3_600))
        await forward.refresh(force: true)
        let afterClockForward = try await windowState(forward, "300m")
        XCTAssertEqual(afterClockForward.freshness, .stale)
        await forward.stop()

        let back = coordinator(env, cache: cache, now: now.addingTimeInterval(-2 * 3_600))
        await back.refresh(force: true)
        let state = try await windowState(back, "300m")
        XCTAssertEqual(state.freshness, .stale)
        XCTAssertFalse(state.isAlertEligible)
        await back.stop()

        let future = env.root.appendingPathComponent("claude-future/.claude.json")
        try writeCache(future, cacheDocument(account: accountB, fetchedAt: now.addingTimeInterval(3_600), five: 99, week: 99, reset: reset))
        let ahead = coordinator(env, cache: future)
        await ahead.refresh(force: true)
        XCTAssertNil(try lastConfirmed(env, "300m").flatMap { $0 > Clock.ms(now) ? $0 : nil }, "a future-dated fetch is not stored")
        await ahead.stop()
    }

    func testRepeatedCacheWritesRaiseEachAlertOnlyOnce() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        var notifications = NotificationSettings()
        notifications.enabled = true
        let engine = AlertEngine(db: env.db)
        func alerts(_ c: QuotaCoordinator, engine: AlertEngine) async -> [QuotaAlertSummary] {
            let states = await c.states()
            return engine.evaluate(states: states, sources: [], activeProviders: [.anthropic], settings: notifications, now: now)
                .map { QuotaAlertSummary(key: $0.key) }
        }

        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-300), five: 80, week: nil, reset: reset, fiveReset: reset))
        let c = coordinator(env, cache: cache)
        await c.refresh(force: true)
        let first = await alerts(c, engine: engine)
        XCTAssertEqual(first.count, 1, "crossing a threshold is announced")

        // The same snapshot written again, and the same percentage fetched again later, are not new events.
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-300), five: 80, week: nil, reset: reset, fiveReset: reset))
        await c.refresh(force: true)
        let rewritten = await alerts(c, engine: engine)
        XCTAssertEqual(rewritten, [])
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-60), five: 80, week: nil, reset: reset, fiveReset: reset))
        await c.refresh(force: true)
        let refetched = await alerts(c, engine: engine)
        XCTAssertEqual(refetched, [])
        await c.stop()

        // A restart restores both the readings and the record of what was already announced.
        let restarted = coordinator(env, cache: cache)
        await restarted.refresh(force: true)
        let afterRestart = await alerts(restarted, engine: AlertEngine(db: env.db))
        XCTAssertEqual(afterRestart, [])
        await restarted.stop()
    }
}

private struct QuotaAlertSummary: Equatable {
    var key: String
}
