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

    private func writeStatusLine(_ directory: URL, five: Double, week: Double, observed: Date, reset: Date,
                                 weekReset: Date? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = QuotaBridgeFile(sessionId: "s1", observedAt: Clock.ms(observed), capturedAt: Clock.ms(observed),
                                   fingerprint: "\(five)-\(observed.timeIntervalSince1970)",
                                   rateLimits: ["five_hour": .init(usedPercentage: five, resetsAt: reset.timeIntervalSince1970),
                                                "seven_day": .init(usedPercentage: week, resetsAt: (weekReset ?? reset.addingTimeInterval(86_400)).timeIntervalSince1970)])
        try JSONEncoder().encode(file).write(to: directory.appendingPathComponent("statusline-s1.json"))
    }

    private func coordinator(_ env: TestEnv, cache: URL, bridge: URL? = nil, now: Date? = nil) -> QuotaCoordinator {
        var feeds: [any QuotaFeed] = [ClaudeCodeCacheFeed(url: cache)]
        if let bridge { feeds.append(ClaudeStatusLineFeed(directory: bridge)) }
        let at = now ?? self.now
        return QuotaCoordinator(db: env.db, settings: SettingsStore(db: env.db), feeds: feeds, clock: { at })
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

    func testCacheIsIngestedWithoutTheStatusLineAndSurvivesARestart() async throws {
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

    func testCacheAndStatusLineReadingsStayInSeparatePoolsAndAreNotReconciled() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        let bridge = env.root.appendingPathComponent("quota")
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-5 * 60),
                                            five: 40, week: 50, reset: reset, fiveReset: reset))
        try writeStatusLine(bridge, five: 60, week: 80, observed: now.addingTimeInterval(-4 * 60), reset: reset)
        let c = coordinator(env, cache: cache, bridge: bridge)
        await c.refresh(force: true)
        let cacheID = try cacheAccountID(env, accountA)
        let statusID = try accountID(env, hash: nil)
        let cacheState = try await windowState(c, "300m", accountID: cacheID)
        let statusState = try await windowState(c, "300m", accountID: statusID)
        XCTAssertEqual(cacheState.utilizationPercent, 40)
        XCTAssertEqual(cacheState.reading?.source, .claudeCodeCache)
        XCTAssertNil(cacheState.sourceConflict, "the status line has no account identity, so it is not a conflict for this account")
        XCTAssertEqual(statusState.utilizationPercent, 60)
        XCTAssertEqual(statusState.reading?.source, .claudeStatusLine)
        XCTAssertNil(statusState.sourceConflict)
        XCTAssertEqual(try snapshotCount(env), 4, "two identified windows and two unassigned windows, never a combined percentage")
        await c.stop()
    }

    func testIdenticalCacheAndStatusLineValuesAreNotCollapsedAcrossAccountPools() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        let bridge = env.root.appendingPathComponent("quota")
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-5 * 60),
                                            five: 50, week: 50, reset: reset, fiveReset: reset))
        let c = coordinator(env, cache: cache, bridge: bridge)
        await c.refresh(force: true)
        try writeStatusLine(bridge, five: 50, week: 50, observed: now.addingTimeInterval(-60), reset: reset, weekReset: reset)
        await c.refresh(force: true)
        let cacheID = try cacheAccountID(env, accountA)
        let statusID = try accountID(env, hash: nil)
        let cacheState = try await windowState(c, "300m", accountID: cacheID)
        let statusState = try await windowState(c, "300m", accountID: statusID)
        XCTAssertEqual(cacheState.reading?.source, .claudeCodeCache)
        XCTAssertEqual(statusState.reading?.source, .claudeStatusLine)
        XCTAssertEqual(try snapshotCount(env), 4, "identical numbers from different identity states stay separate")
        let sources = try env.db.read { c in
            try c.query("SELECT telemetry_source_id FROM quota_snapshot") { $0.text(0) }
        }
        XCTAssertEqual(Set(sources), [TelemetrySourceID.claudeStatusLine.rawValue, TelemetrySourceID.claudeCodeCache.rawValue])
        await c.stop()
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


    func testANewerLowerStatusLineReadingDoesNotReplaceAnIdentifiedCacheReading() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        let bridge = env.root.appendingPathComponent("quota")
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-10 * 60),
                                            five: 80, week: 80, reset: reset, fiveReset: reset))
        try writeStatusLine(bridge, five: 60, week: 60, observed: now.addingTimeInterval(-2 * 60), reset: reset, weekReset: reset)
        let c = coordinator(env, cache: cache, bridge: bridge)
        await c.refresh(force: true)
        let cacheID = try cacheAccountID(env, accountA)
        let statusID = try accountID(env, hash: nil)
        let cacheState = try await windowState(c, "300m", accountID: cacheID)
        let statusState = try await windowState(c, "300m", accountID: statusID)
        XCTAssertEqual(cacheState.utilizationPercent, 80, "a newer unattributed reading cannot replace an identified account's reading")
        XCTAssertEqual(statusState.utilizationPercent, 60, "the status line still keeps its own unassigned observation")
        XCTAssertNil(cacheState.sourceConflict)
        XCTAssertNil(statusState.sourceConflict)
        await c.stop()
    }

    func testStatusLineDoesNotBorrowTheCachedAccountIdentityEvenAtTheSameInstant() async throws {
        let env = try TestEnv()
        let cache = env.root.appendingPathComponent("claude/.claude.json")
        let bridge = env.root.appendingPathComponent("quota")
        try writeCache(cache, cacheDocument(account: accountA, fetchedAt: now.addingTimeInterval(-5 * 60),
                                            five: 80, week: 80, reset: reset, fiveReset: reset))
        try writeStatusLine(bridge, five: 60, week: 60, observed: now.addingTimeInterval(-5 * 60), reset: reset, weekReset: reset)
        let c = coordinator(env, cache: cache, bridge: bridge)
        await c.refresh(force: true)
        let cacheID = try cacheAccountID(env, accountA)
        let statusID = try accountID(env, hash: nil)
        let cacheState = try await windowState(c, "300m", accountID: cacheID)
        let statusState = try await windowState(c, "300m", accountID: statusID)
        XCTAssertEqual(cacheState.utilizationPercent, 80)
        XCTAssertEqual(cacheState.reading?.source, .claudeCodeCache)
        XCTAssertEqual(statusState.utilizationPercent, 60)
        XCTAssertEqual(statusState.reading?.source, .claudeStatusLine)
        XCTAssertTrue(statusState.pool.accountLabel == "Unassigned")
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
}
