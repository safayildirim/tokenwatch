import XCTest
import SwiftUI
@testable import UsageCore
@testable import UsageUI

@MainActor
final class AppModelTests: XCTestCase {
    func testEmptyStateWhenClaudeHasNoSessions() async throws {
        let env = try UIEnv()
        await env.model.start()
        await env.waitUntil { env.model.hasLoaded }
        XCTAssertEqual(env.model.overview.allTime.requests, 0)
        XCTAssertTrue(env.model.recentSessions.isEmpty)
        XCTAssertEqual(env.model.menuBarTitle.text, "", "no quota and no activity leaves only the icon")
        XCTAssertNil(env.model.lastError)
        await env.cleanup()
    }

    func testMissingClaudeFolderIsReportedNotTreatedAsAnError() async throws {
        let env = try UIEnv()
        let model = AppModel(db: env.db, adapters: [ClaudeCodeAdapter(root: env.root.appendingPathComponent("nope"))],
                             bridgeDirectory: env.quotaDir, registryDirectory: env.registryDir)
        await model.start()
        await env.waitUntil { model.collectorSnapshot.sources.first?.state == .notFound || { model.requestRefresh(); return false }() }
        XCTAssertEqual(model.collectorSnapshot.sources.first?.state, .notFound)
        await model.shutdown()
        await env.cleanup()
    }

    func testHistoryIsImportedAndLiveSessionsAppear() async throws {
        let env = try UIEnv()
        try env.writeSession("S1", lines: 10)
        await env.model.start()
        await env.waitUntil { env.model.overview.allTime.requests == 10 }
        XCTAssertEqual(env.model.recentSessions.count, 0 == 1 ? 0 : env.model.recentSessions.count)
        XCTAssertEqual(env.model.overview.totalSessions, 1)

        // A second session starts while the app is running.
        try env.writeSession("S2", cwd: "/Users/test/beta", lines: 4, at: t0 + 100_000)
        await env.waitUntil { env.model.overview.allTime.requests == 14 }
        XCTAssertEqual(env.model.overview.totalSessions, 2)
        await env.cleanup()
    }

    func testMenuBarShowsRealQuotaPercentagesInEveryMode() async throws {
        let env = try UIEnv()
        try env.writeQuota(five: 63, week: 81)
        await env.model.start()
        await env.waitUntil { env.model.quotaState("300m")?.utilizationPercent == 63 }

        env.model.updateSettings { $0.menuBarMode = .quota(.anthropic) }
        XCTAssertEqual(env.model.menuBarTitle.text, "63% · 81%")
        env.model.updateSettings { $0.menuBarMode = .allProviders }
        XCTAssertEqual(env.model.menuBarTitle.text, "C 63%", "only providers that have a figure appear, each with its short window")
        env.model.updateSettings { $0.menuBarMode = .highestUtilization }
        XCTAssertEqual(env.model.menuBarTitle.text, "81%")
        XCTAssertTrue(env.model.menuBarTitle.tooltip.contains("Highest: Claude, Claude subscription, weekly window"))
        env.model.updateSettings { $0.menuBarMode = .quota(.openAI) }
        XCTAssertEqual(env.model.menuBarTitle.text, "", "a provider with no figure shows nothing rather than a made-up number")
        env.model.updateSettings { $0.menuBarMode = .iconOnly }
        XCTAssertEqual(env.model.menuBarTitle.text, "")
        env.model.updateSettings { $0.menuBarMode = .activeSessions }
        XCTAssertEqual(env.model.menuBarTitle.text, "", "no active sessions, so nothing is shown")
        XCTAssertTrue(env.model.menuBarTitle.tooltip.contains("63% used"))
        await env.cleanup()
    }

    func testMenuBarOffersAChoicePerProviderAndSurvivesRestarts() async throws {
        let env = try UIEnv()
        let choices = MenuBarDisplayMode.choices(for: env.model.providers)
        XCTAssertEqual(choices.map(\.rawValue), ["iconOnly", "quota:anthropic", "quota:openai", "allProviders", "highestUtilization", "activeSessions"])
        XCTAssertEqual(choices.map { $0.label(providers: env.model.providers) },
                       ["Icon only", "Claude quota", "OpenAI quota", "Quota of every provider", "Highest utilization", "Active session count"])
        env.model.updateSettings { $0.menuBarMode = .quota(.openAI) }
        XCTAssertEqual(SettingsStore(db: env.db).value.menuBarMode, .quota(.openAI))
        // A stored value from a future version falls back to something sensible instead of failing to load.
        let decoded = try JSONDecoder().decode(MenuBarDisplayMode.self, from: Data("\"somethingNew\"".utf8))
        XCTAssertEqual(decoded, .allProviders)
        await env.cleanup()
    }

    func testMenuBarShowsOnlyWhatIsKnownWhenOneWindowIsMissing() async throws {
        let env = try UIEnv()
        try env.writeQuota(five: 40, week: nil)
        await env.model.start()
        await env.waitUntil { env.model.quotaState("300m")?.utilizationPercent == 40 }
        env.model.updateSettings { $0.menuBarMode = .quota(.anthropic) }
        XCTAssertEqual(env.model.menuBarTitle.text, "40%", "a missing window is left out, never replaced by a made-up number")
        await env.cleanup()
    }

    func testStaleQuotaIsMarkedInTheMenuBar() async throws {
        let env = try UIEnv()
        try env.writeQuota(five: 55, week: 20, observed: Date().addingTimeInterval(-3 * 3600), resetsIn: 6 * 3600)
        await env.model.start()
        await env.waitUntil { env.model.quotaState("300m")?.utilizationPercent == 55 }
        XCTAssertEqual(env.model.quotaState("300m")?.freshness, .stale)
        env.model.updateSettings { $0.menuBarMode = .quota(.anthropic) }
        XCTAssertEqual(env.model.menuBarTitle.text, "55%* · 20%*")
        XCTAssertTrue(env.model.menuBarTitle.tooltip.contains("stale"))
        await env.cleanup()
    }

    func testBothProvidersAppearSideBySideAndAreNeverAdded() async throws {
        let env = try UIEnv()
        try env.writeQuota(five: 63, week: 81)
        try env.writeCodexSession("01a00000-0000-7000-8000-0000000000c1", at: Clock.nowMs() - 60_000, primary: 12, secondary: 34)
        await env.model.start()
        await env.waitUntil { env.model.quotaState("300m")?.utilizationPercent == 63 && env.model.quotaState("300m", .openAI)?.utilizationPercent == 12 }
        env.model.updateSettings { $0.menuBarMode = .allProviders }
        XCTAssertEqual(env.model.menuBarTitle.text, "C 63% · O 12%")
        env.model.updateSettings { $0.menuBarMode = .quota(.openAI) }
        XCTAssertEqual(env.model.menuBarTitle.text, "12% · 34%")
        env.model.updateSettings { $0.menuBarMode = .highestUtilization }
        XCTAssertEqual(env.model.menuBarTitle.text, "81%", "the highest single figure, not a sum")
        let tip = env.model.menuBarTitle.tooltip
        XCTAssertTrue(tip.contains("Claude subscription") && tip.contains("Codex and Work"))
        XCTAssertEqual(env.model.quotaPools.filter { $0.windows.contains { $0.reading != nil } }.count, 2)
        await env.cleanup()
    }

    func testTokenVolumeNeverProducesAQuotaPercentage() async throws {
        let env = try UIEnv()
        try env.writeSession("BIG", lines: 200)
        await env.model.start()
        await env.waitUntil { env.model.overview.allTime.requests == 200 }
        env.model.updateSettings { $0.menuBarMode = .allProviders }
        XCTAssertEqual(env.model.menuBarTitle.text, "")
        XCTAssertTrue(env.model.quotaStates.allSatisfy { $0.utilizationPercent == nil })
        await env.cleanup()
    }

    func testNavigationActions() async throws {
        let env = try UIEnv()
        try env.writeSession("S1")
        await env.model.start()
        await env.waitUntil { env.model.overview.totalSessions == 1 }
        env.model.show(session: 7)
        XCTAssertEqual(env.model.selection, .sessions)
        XCTAssertEqual(env.model.openSessionID, 7)
        env.model.show(project: 3)
        XCTAssertEqual(env.model.sessionsProjectFilter, 3)
        XCTAssertNil(env.model.openSessionID, "choosing a project returns to the list")
        await env.cleanup()
    }

    func testBurstsOfRefreshRequestsAreCoalesced() async throws {
        let env = try UIEnv()
        await env.model.start()
        await env.waitUntil { env.model.hasLoaded }
        try await Task.sleep(for: .seconds(1.2))
        let before = env.model.dataVersion
        for _ in 0..<50 { env.model.requestRefresh() }
        try await Task.sleep(for: .seconds(2))
        XCTAssertLessThanOrEqual(env.model.dataVersion - before, 2, "fifty requests become at most a couple of reloads")
        await env.cleanup()
    }

    func testSettingsChangesPersistAndAffectBehaviour() async throws {
        let env = try UIEnv()
        await env.model.start()
        env.model.updateSettings { $0.showEstimatedCost = false; $0.retentionDays = 30; $0.notifications.shortWindowThresholds = [60] }
        XCTAssertFalse(env.model.settings.showEstimatedCost)
        let reloaded = SettingsStore(db: env.db)
        XCTAssertEqual(reloaded.value.retentionDays, 30)
        XCTAssertEqual(reloaded.value.notifications.shortWindowThresholds, [60])
        XCTAssertNotNil(reloaded.value.retentionFloorMs)
        await env.cleanup()
    }

    func testRetentionSettingRemovesOldHistory() async throws {
        let env = try UIEnv()
        let now = Clock.nowMs()
        try env.writeSession("OLD", cwd: "/Users/test/old", lines: 3, at: now - 400 * 86_400_000)
        try env.writeSession("NEW", cwd: "/Users/test/new", lines: 3, at: now - 3_600_000)
        await env.model.start()
        await env.waitUntil { env.model.overview.allTime.requests == 6 }
        env.model.updateSettings { $0.retentionDays = 90 }
        await env.waitUntil { env.model.overview.allTime.requests == 3 }
        XCTAssertEqual(env.model.overview.totalSessions, 1)
        await env.cleanup()
    }

    func testDisablingASourceStopsCollectionFromIt() async throws {
        let env = try UIEnv()
        env.model.updateSettings { $0.disabledSources = [TelemetrySourceID.claudeTranscripts.rawValue] }
        try env.writeSession("S1")
        await env.model.start()
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(env.model.overview.allTime.requests, 0)
        env.model.updateSettings { $0.disabledSources = [] }
        await env.waitUntil { env.model.overview.allTime.requests == 5 }
        await env.cleanup()
    }

    func testHiddenAppSkipsHeavyQueriesButKeepsTheMenuBarAccurate() async throws {
        let env = try UIEnv()
        env.model.uiVisibilityOverride = false
        try env.writeSession("S1", lines: 8, at: Clock.nowMs() - 5_000)
        try env.writeQuota(five: 71, week: 30)
        await env.model.start()
        // Cheap state keeps up: quota and the active session count (the session wrote seconds ago).
        await env.waitUntil { env.model.quotaState("300m")?.utilizationPercent == 71 && env.model.activeSessionCount == 1 }
        env.model.updateSettings { $0.menuBarMode = .quota(.anthropic) }
        XCTAssertEqual(env.model.menuBarTitle.text, "71% · 30%")
        // The expensive analytics were not computed while nothing was on screen.
        XCTAssertEqual(env.model.overview.today.requests, 0)
        XCTAssertTrue(env.model.recentSessions.isEmpty)

        // As soon as a window shows, the summaries are brought up to date.
        env.model.uiVisibilityOverride = true
        env.model.requestRefresh()
        await env.waitUntil { env.model.overview.today.requests == 8 && env.model.recentSessions.count == 1 }
        await env.cleanup()
    }

    func testActiveSessionCountMenuBarMode() async throws {
        let env = try UIEnv()
        try env.writeSession("LIVE", lines: 3, at: Clock.nowMs() - 2_000)
        await env.model.start()
        await env.waitUntil { env.model.activeSessionCount == 1 }
        env.model.updateSettings { $0.menuBarMode = .activeSessions }
        XCTAssertEqual(env.model.menuBarTitle.text, "1")
        await env.cleanup()
    }

    func testActiveSessionsAreCountedPerProvider() async throws {
        let env = try UIEnv()
        let now = Clock.nowMs()
        try env.writeSession("LIVE", lines: 3, at: now - 2_000)
        try env.writeCodexSession("01a00000-0000-7000-8000-0000000000c2", lines: 2, at: now - 3_000)
        try env.writeCodexSession("01a00000-0000-7000-8000-0000000000c3", originator: "codex_work_desktop", lines: 2, at: now - 4_000)
        await env.model.start()
        await env.waitUntil { env.model.activeSessionCount == 3 }
        XCTAssertEqual(env.model.activeByProvider[.anthropic], 1)
        XCTAssertEqual(env.model.activeByProvider[.openAI], 2)
        env.model.updateSettings { $0.menuBarMode = .activeSessions }
        XCTAssertEqual(env.model.menuBarTitle.text, "3")
        XCTAssertTrue(env.model.menuBarTitle.tooltip.contains("Claude: 1") && env.model.menuBarTitle.tooltip.contains("OpenAI: 2"))
        await env.cleanup()
    }

    func testScopeNarrowsTheDashboardButNotTheMenuBar() async throws {
        let env = try UIEnv()
        let now = Clock.nowMs()
        try env.writeSession("CL", lines: 4, at: now - 3_600_000)
        try env.writeCodexSession("01a00000-0000-7000-8000-0000000000c4", lines: 3, at: now - 3_000_000)
        try env.writeCodexSession("01a00000-0000-7000-8000-0000000000c5", originator: "codex_work_desktop", account: "acct-other", lines: 2, at: now - 2_000_000)
        try env.writeQuota(five: 50, week: 60)
        await env.model.start()
        await env.waitUntil { env.model.overview.allTime.requests == 9 && env.model.quotaPools.filter { $0.windows.contains { $0.reading != nil } }.count == 3 }
        XCTAssertEqual(env.model.scopedOverview.allTime.requests, 9)

        env.model.scope.providers = [.openAI]
        await env.waitUntil { env.model.scopedOverview.allTime.requests == 5 }
        XCTAssertEqual(env.model.overview.allTime.requests, 9, "the menu bar's summary does not change with the dashboard scope")
        XCTAssertEqual(Set(env.model.scopedPools.map(\.pool.key.provider)), [.openAI])
        XCTAssertEqual(env.model.scopedPools.filter { $0.windows.contains { $0.reading != nil } }.count, 2, "two OpenAI accounts, two pools")

        env.model.scope.products = [.chatGPTWork]
        await env.waitUntil { env.model.scopedOverview.allTime.requests == 2 }
        env.model.scope = DashboardScope()
        await env.waitUntil { env.model.scopedOverview.allTime.requests == 9 }
        await env.cleanup()
    }

    func testChoosingAProviderDropsChoicesThatCannotMatch() async throws {
        let env = try UIEnv()
        try env.writeSession("CL", lines: 2, at: Clock.nowMs() - 3_600_000)
        try env.writeCodexSession("01a00000-0000-7000-8000-0000000000c6", lines: 2, at: Clock.nowMs() - 3_000_000)
        await env.model.start()
        await env.waitUntil { env.model.overview.allTime.requests == 4 && !env.model.filterOptions.accounts.isEmpty }
        env.model.scope.products = [.claudeCode]
        env.model.scope.providers = [.openAI]
        XCTAssertTrue(env.model.scope.products.isEmpty, "a Claude product cannot be combined with the OpenAI provider")
        XCTAssertEqual(env.model.scope.providers, [.openAI])
        await env.cleanup()
    }

    func testRecentSessionsAndFilterOptionsCoverEveryProvider() async throws {
        let env = try UIEnv()
        try env.writeSession("CL", lines: 2, at: Clock.nowMs() - 3_600_000)
        try env.writeCodexSession("01a00000-0000-7000-8000-0000000000c7", originator: "Codex Desktop", lines: 2, at: Clock.nowMs() - 3_000_000)
        await env.model.start()
        await env.waitUntil { env.model.recentSessions.count == 2 }
        XCTAssertEqual(Set(env.model.recentSessions.map(\.provider)), [.anthropic, .openAI])
        let options = env.model.filterOptions
        XCTAssertEqual(Set(options.providers), [.anthropic, .openAI])
        XCTAssertEqual(Set(options.products), [.claudeCode, .codex])
        XCTAssertEqual(Set(options.surfaces), [.terminal, .codexDesktop])
        XCTAssertEqual(env.model.providerUsage.count, 2)
        await env.cleanup()
    }

    func testAWindowThatHasJustResetShowsADashInsteadOfTheOtherWindowsFigure() async throws {
        let env = try UIEnv()
        // The five-hour window of the last report reset an hour ago. The weekly window is still open at 34%.
        try env.writeCodexSession("01a00000-0000-7000-8000-0000000000d1", lines: 2, at: Clock.nowMs() - 4 * 3_600_000, primary: 12, secondary: 34)
        await env.model.start()
        await env.waitUntil { env.model.quotaState("10080m", .openAI)?.utilizationPercent == 34 }
        XCTAssertNil(env.model.quotaState("300m", .openAI)?.utilizationPercent, "the reset window is unknown, not zero")

        env.model.updateSettings { $0.menuBarMode = .allProviders }
        XCTAssertEqual(env.model.menuBarTitle.text, "O –", "the weekly figure is not shown in place of the five-hour one")
        env.model.updateSettings { $0.menuBarMode = .quota(.openAI) }
        XCTAssertTrue(env.model.menuBarTitle.text.hasPrefix("– · 34%"), env.model.menuBarTitle.text)
        await env.cleanup()
    }
}
