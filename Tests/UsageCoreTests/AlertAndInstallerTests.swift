import XCTest
@testable import UsageCore

final class AlertEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var settings: NotificationSettings {
        var s = NotificationSettings()
        s.enabled = true
        return s
    }

    private func state(_ minutes: Int = 300, pct: Double, resetsIn: TimeInterval = 7200, observedAgo: TimeInterval = 20,
                       authority: QuotaAuthority = .authoritative, at: Date? = nil, provider: ProviderID = .anthropic,
                       account: Int64 = 1, pool: String = "claude-subscription") -> QuotaWindowState {
        let n = at ?? now
        let resets = n.addingTimeInterval(resetsIn)
        // Each distinct reset time is its own cycle, like the database's cycles are.
        let reading = QuotaReading(utilizationPercent: pct, resetsAt: resets, observedAt: n.addingTimeInterval(-observedAgo),
                                   source: .claudeStatusLine, authority: authority, cycleID: Int64(resets.timeIntervalSince1970 / 3600))
        let info = QuotaPoolInfo(key: QuotaPoolKey(provider: provider, accountID: account, poolKey: pool),
                                 accountLabel: account == 1 ? "Unassigned" : "Account \(account)", name: pool == "codex" ? "Codex and Work" : "Claude subscription")
        return QuotaEvaluator.evaluate(pool: info, windowKey: WindowNaming.key(minutes: minutes), windowMinutes: minutes,
                                       readings: [reading], now: n, allowUnverified: true)
    }

    private func engine() throws -> (AlertEngine, TestEnv) {
        let env = try TestEnv()
        return (AlertEngine(db: env.db), env)
    }

    func testCrossingAThresholdNotifiesOnce() throws {
        let (e, _) = try engine()
        XCTAssertTrue(e.evaluate(states: [state(pct: 30)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty)
        let first = e.evaluate(states: [state(pct: 52)], sources: [], activeProviders: [.anthropic], settings: settings, now: now)
        XCTAssertEqual(first.map(\.kind), [.threshold])
        XCTAssertTrue(first[0].title.contains("52%"))
        // The same crossing, observed again and again, is silent.
        for pct in [52, 53, 60, 74.9] {
            XCTAssertTrue(e.evaluate(states: [state(pct: pct)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty, "\(pct)")
        }
        // The next threshold is a new event.
        XCTAssertEqual(e.evaluate(states: [state(pct: 76)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).count, 1)
    }

    func testJumpingOverSeveralThresholdsAnnouncesOnlyTheHighest() throws {
        let (e, _) = try engine()
        let alerts = e.evaluate(states: [state(pct: 93)], sources: [], activeProviders: [.anthropic], settings: settings, now: now)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(alerts[0].key.hasSuffix(":90"))
        XCTAssertTrue(e.evaluate(states: [state(pct: 94)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty,
                      "the lower thresholds were consumed by the same jump")
    }

    func testDedupSurvivesRestart() throws {
        let (e, env) = try engine()
        _ = e.evaluate(states: [state(pct: 80)], sources: [], activeProviders: [.anthropic], settings: settings, now: now)
        let reopened = AlertEngine(db: env.db)
        XCTAssertTrue(reopened.evaluate(states: [state(pct: 80)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty)
    }

    func testANewWindowStartsFresh() throws {
        let (e, _) = try engine()
        XCTAssertEqual(e.evaluate(states: [state(pct: 80)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).count, 1)
        // Five hours later the same percentage in a new window is a new crossing.
        let later = now.addingTimeInterval(6 * 3600)
        let alerts = e.evaluate(states: [state(pct: 80, at: later)], sources: [], activeProviders: [.anthropic], settings: settings, now: later)
        XCTAssertTrue(alerts.contains { $0.kind == .threshold })
    }

    func testStaleOrUnverifiedValuesNeverTriggerQuotaAlerts() throws {
        let (e, _) = try engine()
        XCTAssertTrue(e.evaluate(states: [state(pct: 99, observedAgo: 5 * 3600)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty)
        XCTAssertTrue(e.evaluate(states: [state(pct: 99, authority: .unverified)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty)
    }

    func testRefreshingStaleDataWithoutAStateChangeStaysSilent() throws {
        let (e, _) = try engine()
        _ = e.evaluate(states: [state(pct: 80)], sources: [], activeProviders: [.anthropic], settings: settings, now: now)
        // The data goes stale, then is refreshed with the identical value.
        _ = e.evaluate(states: [state(pct: 80, observedAgo: 4 * 3600)], sources: [], activeProviders: [], settings: settings, now: now)
        XCTAssertTrue(e.evaluate(states: [state(pct: 80, observedAgo: 1)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty)
    }

    func testNothingIsDeliveredWhenNotificationsAreOff() throws {
        let (e, _) = try engine()
        var off = settings
        off.enabled = false
        XCTAssertTrue(e.evaluate(states: [state(pct: 95)], sources: [], activeProviders: [.anthropic], settings: off, now: now).isEmpty)
        // Turning them on later does not replay the crossing that already happened.
        XCTAssertTrue(e.evaluate(states: [state(pct: 95)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty)
    }

    func testCustomThresholdsAreHonoured() throws {
        let (e, _) = try engine()
        var s = settings
        s.shortWindowThresholds = [10]
        XCTAssertEqual(e.evaluate(states: [state(pct: 11)], sources: [], activeProviders: [.anthropic], settings: s, now: now).count, 1)
    }

    func testWeeklyUsesItsOwnThresholds() throws {
        let (e, _) = try engine()
        // 60% passes the five-hour 50% threshold but no weekly threshold (75, 90).
        XCTAssertTrue(e.evaluate(states: [state(10080, pct: 60, resetsIn: 86400)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty)
        XCTAssertEqual(e.evaluate(states: [state(10080, pct: 76, resetsIn: 86400)], sources: [], activeProviders: [.anthropic], settings: settings, now: now).count, 1)
    }

    func testResetIsAnnouncedOnceAfterSignificantUsage() throws {
        let (e, _) = try engine()
        _ = e.evaluate(states: [state(pct: 88)], sources: [], activeProviders: [.anthropic], settings: settings, now: now)
        // After the window's end the evaluator reports an elapsed window.
        let after = now.addingTimeInterval(7200 + 60)
        let resets = now.addingTimeInterval(7200)
        let reading = QuotaReading(utilizationPercent: 88, resetsAt: resets, observedAt: now, source: .claudeStatusLine,
                                   authority: .authoritative, cycleID: Int64(resets.timeIntervalSince1970 / 3600))
        let pool = QuotaPoolInfo(key: QuotaPoolKey(provider: .anthropic, accountID: 1, poolKey: "claude-subscription"),
                                 accountLabel: "Unassigned", name: "Claude subscription")
        let elapsedState = QuotaEvaluator.evaluate(pool: pool, windowKey: "300m", windowMinutes: 300, readings: [reading], now: after, allowUnverified: false)
        let first = e.evaluate(states: [elapsedState], sources: [], activeProviders: [], settings: settings, now: after)
        XCTAssertEqual(first.filter { $0.kind == .reset }.count, 1)
        let second = e.evaluate(states: [elapsedState], sources: [], activeProviders: [], settings: settings, now: after)
        XCTAssertTrue(second.filter { $0.kind == .reset }.isEmpty)
    }

    func testStaleFeedWhileWorkingRaisesOneAlert() throws {
        let (e, _) = try engine()
        _ = e.evaluate(states: [state(pct: 20, observedAgo: 30)], sources: [], activeProviders: [.anthropic], settings: settings, now: now)
        let stale = state(pct: 20, observedAgo: 2 * 3600)
        let alerts = e.evaluate(states: [stale], sources: [], activeProviders: [.anthropic], settings: settings, now: now)
        XCTAssertEqual(alerts.filter { $0.kind == .staleData }.count, 1)
        XCTAssertTrue(e.evaluate(states: [stale], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty)
    }

    // MARK: Pools, accounts and shared allowances

    func testTwoAccountsOfOneProviderAlertIndependently() throws {
        let (e, _) = try engine()
        let a = state(10080, pct: 80, provider: .openAI, account: 2, pool: "codex")
        let b = state(10080, pct: 80, provider: .openAI, account: 3, pool: "codex")
        let first = e.evaluate(states: [a], sources: [], activeProviders: [.openAI], settings: settings, now: now)
        XCTAssertEqual(first.count, 1)
        // The second account is at the same level in the same pool, and is still its own event.
        let second = e.evaluate(states: [a, b], sources: [], activeProviders: [.openAI], settings: settings, now: now)
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(first[0].key, second[0].key)
        XCTAssertTrue(second[0].title.contains("Account 3"), "the notification says which account it is about")
    }

    func testDifferentPoolsOfOneAccountDoNotShareAlertIdentity() throws {
        let (e, _) = try engine()
        let claude = state(300, pct: 80, provider: .anthropic, account: 1, pool: "claude-subscription")
        let codex = state(300, pct: 80, provider: .openAI, account: 1, pool: "codex")
        let alerts = e.evaluate(states: [claude, codex], sources: [], activeProviders: [], settings: settings, now: now)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.key)).count, 2)
    }

    func testAWindowIsAlertedOnceNoMatterHowManyProductsDrawOnItsPool() throws {
        // Codex and ChatGPT Work share one pool, so there is one window state and one alert for it.
        let (e, _) = try engine()
        let shared = state(300, pct: 92, provider: .openAI, account: 2, pool: "codex")
        XCTAssertEqual(e.evaluate(states: [shared], sources: [], activeProviders: [.openAI], settings: settings, now: now).count, 1)
        XCTAssertTrue(e.evaluate(states: [shared, shared], sources: [], activeProviders: [.openAI], settings: settings, now: now).isEmpty)
    }

    func testAlertIdentityIncludesTheCycleSoANewCycleAlertsAgain() throws {
        let (e, _) = try engine()
        let first = e.evaluate(states: [state(300, pct: 80)], sources: [], activeProviders: [], settings: settings, now: now)
        let later = now.addingTimeInterval(6 * 3600)
        let second = e.evaluate(states: [state(300, pct: 80, at: later)], sources: [], activeProviders: [], settings: settings, now: later)
        let thresholds = [first, second].map { $0.filter { $0.kind == .threshold } }
        XCTAssertEqual(thresholds.map(\.count), [1, 1])
        XCTAssertNotEqual(thresholds[0][0].key, thresholds[1][0].key)
    }

    func testStaleAlertOnlyFiresForProvidersThatAreInUse() throws {
        let (e, _) = try engine()
        let fresh = state(300, pct: 20, observedAgo: 30, provider: .openAI, account: 2, pool: "codex")
        _ = e.evaluate(states: [fresh], sources: [], activeProviders: [.anthropic], settings: settings, now: now)
        let stale = state(300, pct: 20, observedAgo: 2 * 3600, provider: .openAI, account: 2, pool: "codex")
        XCTAssertTrue(e.evaluate(states: [stale], sources: [], activeProviders: [.anthropic], settings: settings, now: now).isEmpty,
                      "using Claude says nothing about whether the OpenAI feed should be updating")
    }

    func testPersistentCollectionFailureAlertsOncePerEpisode() throws {
        let (e, _) = try engine()
        var health = SourceHealth(sourceID: .claudeTranscripts, displayName: "Claude Code", coverageNote: "")
        health.state = .failing
        health.consecutiveFailures = 3
        health.lastError = "The disk is full"
        XCTAssertEqual(e.evaluate(states: [], sources: [health], activeProviders: [], settings: settings, now: now).count, 1)
        XCTAssertTrue(e.evaluate(states: [], sources: [health], activeProviders: [], settings: settings, now: now).isEmpty)
        // A transient failure does not alert.
        health.consecutiveFailures = 1
        health.lastError = "other"
        XCTAssertTrue(e.evaluate(states: [], sources: [health], activeProviders: [], settings: settings, now: now).isEmpty)
        // After recovery a later failure can alert again.
        health.state = .ok
        health.consecutiveFailures = 0
        _ = e.evaluate(states: [], sources: [health], activeProviders: [], settings: settings, now: now)
        health.state = .failing
        health.consecutiveFailures = 5
        health.lastError = "The disk is full"
        XCTAssertEqual(e.evaluate(states: [], sources: [health], activeProviders: [], settings: settings, now: now).count, 1)
    }
}

final class StatusLineInstallerTests: XCTestCase {
    private let bridge = URL(fileURLWithPath: "/Applications/Tokenwatch.app/Contents/MacOS/tw-statusline")

    private func settingsFile(_ env: TestEnv, _ contents: String?) throws -> URL {
        let url = env.root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func testShellQuotingRoundTrips() {
        for s in ["simple", "with space", "it's", "a'b'c", "$(rm -rf /)", "x; y", "\"q\""] {
            XCTAssertEqual(ShellQuote.unquote(ShellQuote.quote(s)), s)
        }
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
    }

    func testInstallAddsTheStatusLineAndLeavesTheRestOfTheFileUntouched() throws {
        let env = try TestEnv()
        let original = """
        {
          "env": { "A": "1" },
          "permissions": {
            "allow": ["Bash(ls:*)"]
          },
          "model":   "opus"
        }
        """
        let url = try settingsFile(env, original)
        let backup = try StatusLineInstaller.install(settingsURL: url, bridge: bridge)
        let now = try json(url)
        XCTAssertEqual((now["statusLine"] as? [String: Any])?["type"] as? String, "command")
        let command = (now["statusLine"] as! [String: Any])["command"] as! String
        XCTAssertTrue(command.contains("tw-statusline"))
        XCTAssertFalse(command.contains("--chain"))
        // Every other setting is preserved, including its original text.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"model\":   \"opus\""), "formatting of untouched settings is preserved")
        XCTAssertTrue(text.contains("\"allow\": [\"Bash(ls:*)\"]"))
        XCTAssertEqual((now["env"] as? [String: String]), ["A": "1"])
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backup), encoding: .utf8), original, "a backup of the original is made")
        XCTAssertTrue(StatusLineInstaller.inspect(settingsURL: url).isInstalled)
    }

    func testInstallChainsAnExistingStatusLineAndUninstallRestoresIt() throws {
        let env = try TestEnv()
        let url = try settingsFile(env, #"{"statusLine":{"type":"command","command":"~/bin/my line.sh --flag 'x'","padding":2},"other":true}"#)
        try StatusLineInstaller.install(settingsURL: url, bridge: bridge)
        var info = StatusLineInstaller.inspect(settingsURL: url)
        XCTAssertTrue(info.isInstalled)
        XCTAssertEqual(info.chainedCommand, "~/bin/my line.sh --flag 'x'")
        XCTAssertEqual((try json(url)["statusLine"] as? [String: Any])?["padding"] as? Int, 2, "other statusLine options are kept")

        // Installing again must not nest the chain.
        try StatusLineInstaller.install(settingsURL: url, bridge: bridge)
        info = StatusLineInstaller.inspect(settingsURL: url)
        XCTAssertEqual(info.chainedCommand, "~/bin/my line.sh --flag 'x'")
        XCTAssertEqual(((try json(url)["statusLine"] as! [String: Any])["command"] as! String).components(separatedBy: "--chain").count, 2)

        try StatusLineInstaller.uninstall(settingsURL: url)
        info = StatusLineInstaller.inspect(settingsURL: url)
        XCTAssertFalse(info.isInstalled)
        XCTAssertEqual(info.command, "~/bin/my line.sh --flag 'x'", "the user's own status line is back")
        XCTAssertEqual(try json(url)["other"] as? Bool, true)
    }

    func testUninstallWithoutChainRemovesTheMemberCleanly() throws {
        let env = try TestEnv()
        let url = try settingsFile(env, "{\n  \"a\": 1,\n  \"b\": 2\n}\n")
        try StatusLineInstaller.install(settingsURL: url, bridge: bridge)
        XCTAssertTrue(StatusLineInstaller.inspect(settingsURL: url).isInstalled)
        try StatusLineInstaller.uninstall(settingsURL: url)
        let after = try json(url)
        XCTAssertNil(after["statusLine"])
        XCTAssertEqual(after["a"] as? Int, 1)
        XCTAssertEqual(after["b"] as? Int, 2)
    }

    func testInstallIntoMissingOrEmptyObjectWorks() throws {
        let env = try TestEnv()
        let missing = try settingsFile(env, nil)
        XCTAssertNil(try StatusLineInstaller.install(settingsURL: missing, bridge: bridge))
        XCTAssertTrue(StatusLineInstaller.inspect(settingsURL: missing).isInstalled)
        let empty = env.root.appendingPathComponent("claude/empty.json")
        try "{}".write(to: empty, atomically: true, encoding: .utf8)
        try StatusLineInstaller.install(settingsURL: empty, bridge: bridge)
        XCTAssertTrue(StatusLineInstaller.inspect(settingsURL: empty).isInstalled)
    }

    func testInvalidSettingsAreNeverModified() throws {
        let env = try TestEnv()
        let broken = "{ \"a\": 1, oops"
        let url = try settingsFile(env, broken)
        XCTAssertThrowsError(try StatusLineInstaller.install(settingsURL: url, bridge: bridge))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken)
        XCTAssertFalse(StatusLineInstaller.inspect(settingsURL: url).settingsIsValidJSON)
    }

    func testStatusLineKeyInsideAStringIsNotMistakenForTheRealOne() throws {
        let env = try TestEnv()
        let url = try settingsFile(env, #"{"note":"set \"statusLine\": here","x":{"statusLine":"nested"}}"#)
        XCTAssertFalse(StatusLineInstaller.inspect(settingsURL: url).isInstalled)
        try StatusLineInstaller.install(settingsURL: url, bridge: bridge)
        let parsed = try json(url)
        XCTAssertEqual(parsed["note"] as? String, #"set "statusLine": here"#)
        XCTAssertEqual(((parsed["x"] as? [String: Any])?["statusLine"]) as? String, "nested")
        XCTAssertTrue(StatusLineInstaller.inspect(settingsURL: url).isInstalled)
    }

    func testNonCommandStatusLineIsReportedNotOverwrittenSilently() throws {
        let env = try TestEnv()
        let url = try settingsFile(env, #"{"statusLine":{"type":"text","text":"hello"}}"#)
        XCTAssertTrue(StatusLineInstaller.inspect(settingsURL: url).usesNonCommandStatusLine)
    }
}
