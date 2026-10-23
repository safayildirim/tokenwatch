import XCTest
import SQLite3
@testable import UsageCore

private typealias CF = CodexFixture

private func fixtureURL(_ name: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures/codex/\(name)")
}

/// What the adapter decides from a session header.
final class CodexClassificationTests: XCTestCase {
    func testOriginatorsMapToProductsAndSurfaces() {
        let table: [(String?, String?, ProductID, SurfaceID)] = [
            ("codex_work_desktop", "vscode", .chatGPTWork, .chatGPTDesktop),
            ("Codex Desktop", "vscode", .codex, .codexDesktop),
            ("codex_exec", "exec", .codex, .terminal),
            ("codex_vscode", "vscode", .codex, .vscode),
            ("JetBrains.WebStorm", "vscode", .codex, .jetbrains),
            ("JetBrains.JetBrains Rider", "vscode", .codex, .jetbrains),
            ("codex_cli_rs", "cli", .codex, .terminal),
            ("codex-tui", nil, .codex, .terminal),
            ("some-new-client", nil, .codex, .unknown),
            ("some-new-client", "vscode", .codex, .vscode),
            (nil, nil, .codex, .unknown),
        ]
        for (originator, source, product, surface) in table {
            let r = CodexAdapter.classify(originator: originator, source: source)
            XCTAssertEqual(r.product, product, "\(originator ?? "nil")")
            XCTAssertEqual(r.surface, surface, "\(originator ?? "nil")")
        }
    }

    func testSessionIdIsTakenFromTheFileName() {
        XCTAssertEqual(CodexAdapter.sessionID(inFileName: "rollout-2026-10-12T12-40-20-01a12f7c-0a79-7392-a898-806679989e3e.jsonl"),
                       "01a12f7c-0a79-7392-a898-806679989e3e")
        XCTAssertEqual(CodexAdapter.sessionID(inFileName: "rollout-2026-10-12T12-40-20-01a12f7c-0a79-7392-a898-806679989e3e.jsonl.zst"),
                       "01a12f7c-0a79-7392-a898-806679989e3e")
        XCTAssertEqual(CodexAdapter.sessionID(inFileName: "rollout-odd.jsonl"), "rollout-odd")
    }
}

/// Finding the files, wherever Codex keeps them.
final class CodexDiscoveryTests: XCTestCase {
    func testFindsActiveArchivedAndCompressedSessionsAndNothingElse() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 1))
        try env.codexFile(session: CF.sessionB, lines: CF.eventSession(id: CF.sessionB, count: 1), archived: true)
        let dir = env.codexHome.appendingPathComponent("sessions/2026/09/01")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("era1-token-count.jsonl.zst"),
                                         to: dir.appendingPathComponent("rollout-2026-09-01T10-00-00-\(CF.sessionC).jsonl.zst"))
        // Files that are not session files must be ignored, and in particular the credentials file is never listed.
        try "{\"OPENAI_API_KEY\":\"sk-SENTINEL\"}".write(to: env.codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "x".write(to: env.codexHome.appendingPathComponent("sessions/notes.txt"), atomically: true, encoding: .utf8)
        try "{}".write(to: env.codexHome.appendingPathComponent("sessions/2026/10/12/history.jsonl"), atomically: true, encoding: .utf8)

        let files = try env.codexAdapter.discoverFiles()
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.filter { $0.hints["archived"] == "1" }.count, 1)
        XCTAssertEqual(files.filter(\.isCompressed).count, 1)
        XCTAssertFalse(files.contains { $0.path.hasSuffix("auth.json") })
    }

    func testFileEventsAreRoutedByLocation() throws {
        let env = try TestEnv()
        let a = env.codexAdapter
        let sessions = env.codexHome.appendingPathComponent("sessions/2026/10/12/rollout-x-\(CF.sessionA).jsonl").path
        XCTAssertNotNil(a.fileRef(forPath: sessions))
        XCTAssertNotNil(a.fileRef(forPath: env.codexHome.appendingPathComponent("archived_sessions/rollout-x-\(CF.sessionA).jsonl.zst").path))
        XCTAssertNil(a.fileRef(forPath: env.codexHome.appendingPathComponent("auth.json").path))
        XCTAssertNil(a.fileRef(forPath: env.codexHome.appendingPathComponent("sessions/2026/10/12/other.json").path))
        XCTAssertNil(a.fileRef(forPath: "/somewhere/else/rollout-x-\(CF.sessionA).jsonl"))
    }

    func testCodexHomeIsTakenFromTheEnvironmentVariable() {
        // The default follows CODEX_HOME exactly as Codex itself does, unless a more specific override is present.
        let home = CodexAdapter.defaultHome
        let env = ProcessInfo.processInfo.environment
        if let override = env["TOKENWATCH_CODEX_DIR"] ?? env["CODEX_HOME"], !override.isEmpty {
            XCTAssertEqual(home.path, URL(fileURLWithPath: (override as NSString).expandingTildeInPath).path)
        } else {
            XCTAssertEqual(home.lastPathComponent, ".codex")
        }
    }

    func testMissingFolderIsReportedAsNotInstalledWithoutError() async throws {
        let env = try TestEnv()
        let collector = UsageCollector(db: env.db, adapters: [CodexAdapter(home: env.root.appendingPathComponent("nope"))], reconcileInterval: 3600)
        await collector.start()
        try await Task.sleep(for: .milliseconds(300))
        let snap = await collector.snapshot()
        XCTAssertEqual(snap.sources.first?.state, .notFound)
        await collector.stop()
    }
}

/// How tokens are read, normalized and counted.
final class CodexAccountingTests: XCTestCase {
    private func stored(_ env: TestEnv) throws -> [(String, Int64?, Int64?, Int64?, Int64?, Int64?, String)] {
        try env.db.read { c in
            try c.query("""
                SELECT request_key, uncached_input_tokens, cache_read_tokens, cache_creation_tokens, output_tokens,
                       reasoning_output_tokens, completeness FROM model_request ORDER BY requested_at, request_key
                """) { ($0.text(0), $0.intOrNil(1), $0.intOrNil(2), $0.intOrNil(3), $0.intOrNil(4), $0.intOrNil(5), $0.text(6)) }
        }
    }

    func testOpenAIInputIncludesCachedTokensAndReasoningIsPartOfOutput() throws {
        let env = try TestEnv()
        // 1000 input tokens of which 600 were served from the cache; 50 output tokens of which 20 were reasoning.
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(count: 1))
        try env.syncCodex()
        let rows = try stored(env)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].1, 400, "uncached input is input minus cached input")
        XCTAssertEqual(rows[0].2, 600)
        XCTAssertEqual(rows[0].3, 0, "the file reports cache writes as zero, and that is stored as a known zero")
        XCTAssertEqual(rows[0].4, 50, "reasoning is not added to output")
        XCTAssertEqual(rows[0].5, 20)
        let t = try env.totals().tokens
        XCTAssertEqual(t.logicalInput, 1000, "uncached + cached is exactly what OpenAI calls input")
        XCTAssertEqual(t.totalProcessed, 1050)
        XCTAssertEqual(t.reasoningOutput, 20)
    }

    func testARepeatedSnapshotIsNotAnotherResponse() throws {
        let env = try TestEnv()
        let u = CF.Usage(input: 1000, cached: 600, output: 50, reasoning: 20)
        var lines = [CF.header(id: CF.sessionA, at: t0), CF.turnContext(ordinal: 1, at: t0 + 100)]
        lines.append(CF.tokenCount(ordinal: 2, at: t0 + 1000, last: u, total: u))
        // The same snapshot written again, and once more with a different shape of "last" (only a grand total).
        lines.append(CF.tokenCount(ordinal: 3, at: t0 + 1500, last: u, total: u))
        lines.append(CF.tokenCount(ordinal: 4, at: t0 + 2000, last: CF.Usage(input: 0, output: 0), total: u))
        try env.codexFile(session: CF.sessionA, lines: lines)
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 1)
        XCTAssertEqual(try env.totals().tokens.output, 50)
    }

    func testRunningTotalsAreNotTheIdentity() throws {
        // Two different responses with identical figures are two requests, because only a change of the totals,
        // and not their value, separates a new response from a repeat.
        let env = try TestEnv()
        let u = CF.Usage(input: 500, cached: 100, output: 10)
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0),
            CF.tokenCount(ordinal: 1, at: t0 + 1000, last: u, total: u),
            CF.tokenCount(ordinal: 2, at: t0 + 2000, last: u, total: u + u),
            CF.tokenCount(ordinal: 3, at: t0 + 3000, last: u, total: u + u + u),
        ])
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 3)
        XCTAssertEqual(try env.totals().tokens.output, 30)
    }

    func testUsageRecordsIdentifyRequestsByResponseId() throws {
        let env = try TestEnv()
        try FileManager.default.createDirectory(at: env.codexHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("era2-usage-record.jsonl"),
                                         to: env.codexHome.appendingPathComponent("sessions/rollout-2026-10-12T12-00-00-01a00000-0000-7000-8000-0000000000f2.jsonl"))
        try env.syncCodex()
        let rows = try stored(env)
        XCTAssertEqual(rows.map(\.0), ["resp_fixture_0", "resp_fixture_1"])
        XCTAssertEqual(try env.totals().requests, 2, "the token_count events that follow each record are not counted again")
        let t = try env.totals().tokens
        XCTAssertEqual(t.logicalInput, 9000)
        XCTAssertEqual(t.cacheRead, 7500)
        XCTAssertEqual(t.output, 160)
        XCTAssertEqual(t.reasoningOutput, 50)
    }

    func testTheSameResponseInTwoCopiesOfASessionIsCountedOnce() throws {
        let env = try TestEnv()
        let source = fixtureURL("era2-usage-record.jsonl")
        let name = "rollout-2026-10-12T12-00-00-01a00000-0000-7000-8000-0000000000f2.jsonl"
        try FileManager.default.createDirectory(at: env.codexHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: env.codexHome.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: env.codexHome.appendingPathComponent("sessions/" + name))
        try FileManager.default.copyItem(at: source, to: env.codexHome.appendingPathComponent("archived_sessions/" + name))
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 2)
        XCTAssertEqual(try env.totals().sessions, 1)
    }

    func testAResponseWithoutAnEventOfItsOwnIsReconstructedFromTheTotals() throws {
        let env = try TestEnv()
        let a = CF.Usage(input: 1000, cached: 500, output: 40, reasoning: 10)
        let b = CF.Usage(input: 2000, cached: 1500, output: 60, reasoning: 5)
        let missing = CF.Usage(input: 1200, cached: 1000, output: 30, reasoning: 8)
        // The second event's totals include a response that never produced an event.
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0),
            CF.tokenCount(ordinal: 1, at: t0 + 1000, last: a, total: a),
            CF.tokenCount(ordinal: 2, at: t0 + 2000, last: b, total: a + missing + b),
        ])
        try env.syncCodex()
        let t = try env.totals()
        XCTAssertEqual(t.requests, 3)
        XCTAssertEqual(t.tokens.logicalInput, 1000 + 1200 + 2000)
        XCTAssertEqual(t.tokens.output, 40 + 30 + 60, "the counted usage equals the growth of the running totals")
        XCTAssertEqual(t.coverage.reconciledRequests, 1, "the reconstructed request is flagged")
        let flagged = try stored(env).filter { $0.6 == "reconciledFromTotals" }
        XCTAssertEqual(flagged.count, 1)
        XCTAssertTrue(flagged[0].0.hasSuffix(":gap"))
    }

    func testAnEventThatReportsOnlyAGrandTotalIsReconstructedFromTheTotalsWithoutDoubleCounting() throws {
        let env = try TestEnv()
        let a = CF.Usage(input: 1000, cached: 500, output: 40)
        let b = CF.Usage(input: 2000, cached: 1500, output: 60)
        let totalOnly = "{\"input_tokens\":0,\"cached_input_tokens\":0,\"cache_write_input_tokens\":0,\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":\(b.total)}"
        let info = "{\"total_token_usage\":\((a + b).json),\"last_token_usage\":\(totalOnly),\"model_context_window\":1}"
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0),
            CF.tokenCount(ordinal: 1, at: t0 + 1000, last: a, total: a),
            CF.line("event_msg", ordinal: 2, at: t0 + 2000, payload: "{\"type\":\"token_count\",\"info\":\(info),\"rate_limits\":\(CF.rateLimits())}"),
        ])
        try env.syncCodex()
        let t = try env.totals()
        XCTAssertEqual(t.requests, 2)
        XCTAssertEqual(t.tokens.logicalInput, 3000)
        XCTAssertEqual(t.tokens.output, 100)
        XCTAssertEqual(t.coverage.reconciledRequests, 1)
    }

    func testCompactionsAreCountedOnTheSession() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(count: 2) + [CF.compacted(ordinal: 90, at: t0 + 50_000), CF.compacted(ordinal: 91, at: t0 + 60_000)])
        try env.syncCodex()
        let count = try env.db.read { try $0.scalarInt("SELECT compaction_count FROM session") }
        XCTAssertEqual(count, 2)
    }

    func testModelIsTheOneInEffectWhenTheResponseWasMade() throws {
        let env = try TestEnv()
        let u = CF.Usage(input: 100, cached: 0, output: 10)
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0),
            CF.turnContext(ordinal: 1, at: t0 + 10, model: "gpt-5.6-terra"),
            CF.tokenCount(ordinal: 2, at: t0 + 1000, last: u, total: u),
            CF.turnContext(ordinal: 3, at: t0 + 2000, model: "gpt-5.6-sol"),
            CF.tokenCount(ordinal: 4, at: t0 + 3000, last: u, total: u + u),
        ])
        try env.syncCodex()
        let models = try AnalyticsEngine(db: env.db).models()
        XCTAssertEqual(Set(models.map(\.canonical)), ["gpt-5.6-terra", "gpt-5.6-sol"])
        XCTAssertTrue(models.allSatisfy { $0.provider == .openAI })
    }

    func testUnknownModelIsKeptHonestlyAndIsNotPriced() throws {
        let env = try TestEnv()
        // The default fixture model has a published price. This one is not on OpenAI's list.
        var lines = CF.eventSession(count: 2)
        lines[1] = CF.turnContext(ordinal: 1, at: t0 + 100, model: "gpt-9-not-on-any-list")
        try env.codexFile(session: CF.sessionA, lines: lines)
        try env.syncCodex()
        let t = try env.totals()
        XCTAssertEqual(t.cost.picoUSD, 0)
        XCTAssertEqual(t.cost.unpricedTokens, t.tokens.logicalInput + t.tokens.output, "no price is invented for a model without a rate card")
    }
}

/// Which session a request belongs to, and how sessions relate.
final class CodexSessionTests: XCTestCase {
    func testHeaderDecidesProductSurfaceAndAccount() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 1, originator: "codex_work_desktop", account: "acct-one"))
        try env.codexFile(session: CF.sessionB, lines: CF.eventSession(id: CF.sessionB, count: 1, originator: "codex_exec", account: "acct-one"))
        try env.codexFile(session: CF.sessionC, lines: CF.eventSession(id: CF.sessionC, count: 1, originator: "codex_exec", account: nil))
        try env.syncCodex()
        let rows = try AnalyticsEngine(db: env.db).sessionRows()
        let work = try XCTUnwrap(rows.first { $0.externalID == CF.sessionA })
        let exec = try XCTUnwrap(rows.first { $0.externalID == CF.sessionB })
        let anonymous = try XCTUnwrap(rows.first { $0.externalID == CF.sessionC })
        XCTAssertEqual(work.productID, .chatGPTWork)
        XCTAssertEqual(work.surface, .chatGPTDesktop)
        XCTAssertEqual(exec.productID, .codex)
        XCTAssertEqual(exec.surface, .terminal)
        XCTAssertEqual(work.provider, .openAI)
        XCTAssertEqual(work.accountID, exec.accountID, "one account across two products")
        XCTAssertNotEqual(anonymous.accountID, exec.accountID)
        XCTAssertEqual(anonymous.accountLabel, "Unassigned", "a session that does not say which account it belongs to is not guessed")
    }

    func testRawAccountIdentifiersAndConversationTextAreNeverStored() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 2, account: "acct-SENTINEL-12345"))
        try "{\"OPENAI_API_KEY\":\"sk-SENTINEL-KEY\"}".write(to: env.codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try env.syncCodex()
        env.db.markCleanShutdown()
        var bytes = Data()
        for suffix in ["", "-wal"] { bytes.append((try? Data(contentsOf: URL(fileURLWithPath: env.dbURL.path + suffix))) ?? Data()) }
        for needle in ["acct-SENTINEL", "sk-SENTINEL", "REDACTED REPLY", "REDACTED INSTRUCTIONS", "user-REDACTED"] {
            XCTAssertNil(bytes.range(of: Data(needle.utf8)), "\(needle) must not reach the database")
        }
    }

    func testSubAgentAndReviewThreadsAreLinkedToTheirParent() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 1))
        // A thread another thread started carries the conversation id of its root in `session_id`.
        let child = CF.header(id: CF.sessionB, at: t0 + 500, source: "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(CF.sessionA)\",\"depth\":1}}}",
                              threadSource: "subagent", parent: CF.sessionA, root: CF.sessionA)
        let u = CF.Usage(input: 300, cached: 100, output: 20)
        try env.codexFile(session: CF.sessionB, lines: [child, CF.tokenCount(ordinal: 1, at: t0 + 3000, last: u, total: u)])
        let review = CF.header(id: CF.sessionC, at: t0 + 700, source: "{\"subagent\":{\"other\":\"guardian\"}}",
                               threadSource: "subagent", parent: CF.sessionA, root: CF.sessionA)
        try env.codexFile(session: CF.sessionC, lines: [review, CF.tokenCount(ordinal: 1, at: t0 + 4000, last: u, total: u)])
        try env.syncCodex()

        let rows = try AnalyticsEngine(db: env.db).sessionRows()
        XCTAssertEqual(rows.count, 3, "each thread is a session of its own, even though they share a conversation id")
        XCTAssertEqual(rows.first { $0.externalID == CF.sessionB }?.kind, .subagent)
        XCTAssertEqual(rows.first { $0.externalID == CF.sessionC }?.kind, .review)
        XCTAssertEqual(rows.first { $0.externalID == CF.sessionA }?.kind, .main)
        let links = try env.db.read { c in
            try c.query("SELECT external_id, parent_session_id, root_session_id FROM session WHERE external_id != ?", [.text(CF.sessionA)]) {
                ($0.text(0), $0.intOrNil(1), $0.intOrNil(2))
            }
        }
        let parentID = rows.first { $0.externalID == CF.sessionA }!.id
        XCTAssertEqual(links.count, 2)
        for link in links {
            XCTAssertEqual(link.1, parentID)
            XCTAssertEqual(link.2, parentID)
        }
        // The usage of the child threads is their own, and is counted once.
        XCTAssertEqual(try env.totals().tokens.output, 50 + 20 + 20)
    }

    func testAParentThatArrivesAfterItsChildIsLinkedWhenItAppears() throws {
        let env = try TestEnv()
        let u = CF.Usage(input: 300, cached: 100, output: 20)
        let child = CF.header(id: CF.sessionB, at: t0 + 500, source: "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(CF.sessionA)\"}}}",
                              threadSource: "subagent", parent: CF.sessionA, root: CF.sessionA)
        try env.codexFile(session: CF.sessionB, lines: [child, CF.tokenCount(ordinal: 1, at: t0 + 3000, last: u, total: u)])
        try env.syncCodex()
        XCTAssertNil(try env.db.read { try $0.scalarInt("SELECT parent_session_id FROM session WHERE external_id = ?", [.text(CF.sessionB)]) })
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 1))
        try env.syncCodex()
        let linked = try env.db.read { try $0.scalarInt("SELECT count(*) FROM session WHERE parent_session_id IS NOT NULL AND root_session_id IS NOT NULL") }
        XCTAssertEqual(linked, 1)
    }

    func testAForkDoesNotRecountItsParentsHistory() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 3))
        // The fork repeats the parent's events in a burst at the instant it was created, with that instant as the
        // timestamp, and then continues with one response of its own.
        let forkAt = t0 + 600_000
        let own = CF.Usage(input: 700, cached: 100, output: 30)
        try env.codexFile(session: CF.sessionB, lines: CF.forkOfEventSession(
            id: CF.sessionB, parent: CF.sessionA, parentCount: 3, at: forkAt, own: [own],
            rate: CF.rateLimits(primary: (99, 300, 1_790_010_000), secondary: (99, 10080, 1_790_500_000))))
        try env.syncCodex()
        let fork = try XCTUnwrap(AnalyticsEngine(db: env.db).sessionRows().first { $0.externalID == CF.sessionB })
        XCTAssertEqual(fork.requests, 1, "only the fork's own response is counted")
        XCTAssertEqual(fork.tokens.output, 30)
        XCTAssertEqual(try env.totals().requests, 4)
        XCTAssertEqual(fork.compactionCount(in: env.db), 0)
        // The copied snapshots carried 99% with the time of the copy. That must not be taken for a current reading.
        let copies = try env.db.read { try $0.scalarInt("SELECT count(*) FROM quota_snapshot WHERE utilization_pct >= 99 AND last_confirmed_at < ?", [.int(forkAt + 10_000)]) }
        XCTAssertEqual(copies, 0)
    }
}

private extension SessionRow {
    func compactionCount(in db: UsageDatabase) -> Int64 {
        (try? db.read { try $0.scalarInt("SELECT compaction_count FROM session WHERE id = ?", [.int(id)]) }) ?? -1
    }
}

/// Reading, rereading and compressed files.
final class CodexIngestTests: XCTestCase {
    func testCompressedAndPlainFilesGiveTheSameResult() throws {
        let plain = try TestEnv(), packed = try TestEnv()
        for (env, name) in [(plain, "era1-token-count.jsonl"), (packed, "era1-token-count.jsonl.zst")] {
            let dir = env.codexHome.appendingPathComponent("sessions/2026/10/12")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtureURL(name), to: dir.appendingPathComponent("rollout-2026-10-12T12-00-00-\(CF.sessionA)." + name.components(separatedBy: ".").dropFirst().joined(separator: ".")))
            try env.syncCodex()
        }
        let a = try plain.totals(), b = try packed.totals()
        XCTAssertEqual(a.tokens, b.tokens)
        XCTAssertEqual(a.requests, 3)
        XCTAssertEqual(a.tokens.uncachedInput, 1100)
        XCTAssertEqual(a.tokens.cacheRead, 4900)
        XCTAssertEqual(a.tokens.output, 250)
        XCTAssertEqual(a.tokens.reasoningOutput, 90)
        // The fixture's session header names Codex Desktop, so the session is Codex on the desktop app.
        let session = try XCTUnwrap(AnalyticsEngine(db: packed.db).sessionRows().first)
        XCTAssertEqual(session.productID, .codex)
        XCTAssertEqual(session.surface, .codexDesktop)
        XCTAssertEqual(session.projectPath, "/Users/test/fixture-project")
    }

    func testACompressedFileIsReadOnceAndLeftAloneAfterwards() throws {
        let env = try TestEnv()
        let dir = env.codexHome.appendingPathComponent("sessions/2026/10/12")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("era1-token-count.jsonl.zst"), to: dir.appendingPathComponent("rollout-2026-10-12T12-00-00-\(CF.sessionA).jsonl.zst"))
        XCTAssertEqual(try env.syncCodex().first?.outcome, .appended)
        XCTAssertEqual(try env.syncCodex().first?.outcome, .unchanged)
        XCTAssertEqual(try env.totals().requests, 3)
        // The checkpoint counts decompressed bytes, so it exceeds the size of the compressed file.
        let cp = try XCTUnwrap(env.synchronizer.loadCheckpoint(sourceID: .codexRollouts, path: dir.appendingPathComponent("rollout-2026-10-12T12-00-00-\(CF.sessionA).jsonl.zst").path))
        XCTAssertGreaterThan(cp.consumedOffset, cp.size)
    }

    func testACompressedFileThatIsDamagedKeepsWhatWasDecodedAndIsNotRetriedUntilItChanges() throws {
        let env = try TestEnv()
        let dir = env.codexHome.appendingPathComponent("sessions/2026/10/12")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Data(contentsOf: fixtureURL("era1-token-count.jsonl.zst"))
        let target = dir.appendingPathComponent("rollout-2026-10-12T12-00-00-\(CF.sessionA).jsonl.zst")
        try data.prefix(data.count - 12).write(to: target)       // The file ends in the middle of a frame.
        XCTAssertThrowsError(try env.syncCodex())
        let status = try env.db.read { try $0.queryOne("SELECT status FROM source_file") { $0.text(0) } }
        XCTAssertEqual(status, "damaged")
        // Unchanged damage is not decoded again.
        XCTAssertEqual(try env.synchronizer.sync(file: try XCTUnwrap(env.codexAdapter.discoverFiles().first), adapter: env.codexAdapter).outcome, .unchanged)
        // Replacing it with an intact file repairs the import.
        try data.write(to: target)
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 3)
    }

    func testAGrowingFileIsReadAgainFromTheTopWithoutDoubleCounting() throws {
        let env = try TestEnv()
        let lines = CF.eventSession(count: 3)
        let url = try env.codexFile(session: CF.sessionA, lines: Array(lines.prefix(4)))     // header, context, message, first event
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 1)
        try Fixture.append(Array(lines.dropFirst(4)), to: url)
        let result = try env.syncCodex()
        XCTAssertEqual(result.first?.outcome, .appended)
        XCTAssertEqual(try env.totals().requests, 3)
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 3)
        // The line counter describes the file as it is, and is not inflated by the repeated reads.
        let counted = try env.db.read { try $0.scalarInt("SELECT line_count FROM source_file") }
        XCTAssertEqual(counted, Int64(lines.count))
    }

    func testAnUnfinishedLastLineIsPickedUpLater() throws {
        let env = try TestEnv()
        let lines = CF.eventSession(count: 2)
        let url = try env.codexFile(session: CF.sessionA, lines: Array(lines.dropLast()))
        let last = lines.last!
        try Fixture.append([String(last.prefix(last.count / 2))], to: url, terminate: false)
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 1)
        try Fixture.append([String(last.dropFirst(last.count / 2))], to: url)
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 2)
    }

    func testUnknownLinesNewFieldsAndDamagedLinesAreTolerated() throws {
        let env = try TestEnv()
        let u = CF.Usage(input: 500, cached: 100, output: 10)
        var lines = [CF.header(id: CF.sessionA, at: t0)]
        lines.append(CF.line("brand_new_record_type", ordinal: 1, at: t0 + 10, payload: "{\"anything\":[1,2,{\"x\":null}],\"nested\":{\"a\":\"b\"}}"))
        lines.append("{ this is not json")
        lines.append("[1,2,3]")
        lines.append(CF.line("event_msg", ordinal: 2, at: t0 + 20, payload: "{\"type\":\"event_from_the_future\",\"info\":\"surprise\"}"))
        // A token event with extra fields, a null rate limit and a null info.
        lines.append("{\"timestamp\":\"\(Fixture.ts(t0 + 30))\",\"ordinal\":3,\"type\":\"event_msg\",\"extra\":true,\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":null}}")
        lines.append("{\"timestamp\":\"\(Fixture.ts(t0 + 40))\",\"ordinal\":4,\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(u.json),\"last_token_usage\":\(u.json),\"new_field\":{\"deep\":1}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":null,\"secondary\":null,\"future\":1}}}")
        try env.codexFile(session: CF.sessionA, lines: lines)
        let result = try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 1)
        XCTAssertGreaterThanOrEqual(result.first!.malformedLines, 2)
    }

    func testRetentionFloorAppliesToOpenAIAsWell() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(count: 4))
        let sync = FileSynchronizer(db: env.db, retentionFloorMs: { t0 + 10_000 })
        let adapter = env.codexAdapter
        _ = try adapter.discoverFiles().map { try sync.sync(file: $0, adapter: adapter) }
        XCTAssertEqual(try env.totals().requests, 2, "responses before the floor are dropped")
    }

    func testClaudeAndCodexLiveSideBySideWithoutInterference() throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.assistant(id: "m1", session: "CLAUDE", at: t0, input: 7, output: 11, cacheRead: 13)], to: try env.mainFile(session: "CLAUDE"))
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(count: 2))
        try env.syncAll()
        try env.syncCodex()
        let engine = AnalyticsEngine(db: env.db)
        var claude = UsageFilter(); claude.providers = [.anthropic]
        var openai = UsageFilter(); openai.providers = [.openAI]
        XCTAssertEqual(try engine.totals(claude).tokens.output, 11)
        XCTAssertEqual(try engine.totals(claude).requests, 1)
        XCTAssertEqual(try engine.totals(openai).requests, 2)
        XCTAssertEqual(try engine.totals(openai).tokens.output, 100)
        XCTAssertEqual(try env.totals().requests, 3)
        // Separate counts per provider add up to the whole, because nothing is shared between them.
        XCTAssertEqual(try engine.totals(claude).tokens + engine.totals(openai).tokens, try env.totals().tokens)
        // Rerunning both changes nothing.
        try env.syncAll(); try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 3)
    }
}

// MARK: - Quota

/// The allowance snapshots that Codex writes with every response.
final class OpenAIQuotaTests: XCTestCase {
    /// An instant a few seconds after the fixtures' last event.
    private let now = Date(timeIntervalSince1970: Double(t0) / 1000 + 60)

    private func coordinator(_ env: TestEnv, now: Date? = nil) -> QuotaCoordinator {
        let at = now ?? self.now
        return QuotaCoordinator(db: env.db, settings: SettingsStore(db: env.db),
                                feeds: .claude(desktopCache: env.root.appendingPathComponent("none.json"),
                                               cache: env.root.appendingPathComponent("claude/.claude.json")), clock: { at })
    }

    private func openAIPools(_ env: TestEnv, now: Date? = nil) async -> [QuotaPoolState] {
        await coordinator(env, now: now).pools().filter { $0.pool.key.provider == .openAI }
    }

    /// The first pool that belongs to a named account.
    private func namedPool(_ env: TestEnv, now: Date? = nil) async throws -> QuotaPoolState {
        let pools = await openAIPools(env, now: now)
        return try XCTUnwrap(pools.first { $0.pool.accountLabel != "Unassigned" })
    }

    private func event(_ ordinal: Int, at ms: Int64, rate: String) -> String {
        let u = CF.Usage(input: 100 * Int64(ordinal), cached: 0, output: 10)
        return CF.tokenCount(ordinal: ordinal, at: ms, last: CF.Usage(input: 100, output: 10), total: u, rate: rate)
    }

    func testSnapshotsBecomeAWindowedPoolOnTheSessionsAccount() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 3, account: "acct-one"))
        try env.syncCodex()
        let pools = await openAIPools(env)
        let pool = try XCTUnwrap(pools.first { $0.pool.key.poolKey == "codex" && $0.pool.accountLabel != "Unassigned" })
        XCTAssertEqual(pool.windows.map(\.windowKey), ["300m", "10080m"])
        XCTAssertEqual(pool.windows.map(\.windowMinutes), [300, 10080])
        XCTAssertEqual(pool.pool.planType, "plus")
        XCTAssertEqual(pool.pool.name, "Codex and Work")
        XCTAssertEqual(Set(pool.pool.products), [.codex, .chatGPTWork])
        let short = pool.windows[0]
        XCTAssertEqual(short.utilizationPercent, 10)
        XCTAssertEqual(short.resetsAt, Date(timeIntervalSince1970: 1_790_010_000))
        XCTAssertEqual(short.displayName, "5-hour window")
        XCTAssertEqual(short.freshness, .fresh)
        XCTAssertTrue(short.isAuthoritative)
        XCTAssertEqual(pool.windows[1].displayName, "Weekly window")
    }

    func testAWindowIsIdentifiedByItsLengthNotByWhichSlotCarriesIt() async throws {
        // A plan that has only a weekly allowance reports it in the "primary" slot.
        let env = try TestEnv()
        let rate = CF.rateLimits(plan: nil, primary: (18, 10080, 1_790_500_000), secondary: nil)
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"), event(1, at: t0 + 1000, rate: rate)])
        try env.syncCodex()
        let pool = try await namedPool(env)
        XCTAssertEqual(pool.windows.map(\.windowKey), ["10080m"], "no 5-hour window is invented, and the weekly one is not called 5-hour")
        XCTAssertEqual(pool.windows[0].utilizationPercent, 18)
        XCTAssertNil(pool.pool.planType)
    }

    func testCodexAndWorkShareOnePoolPerAccount() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, originator: "codex_exec", account: "acct-one"),
                                                          event(1, at: t0 + 1000, rate: CF.rateLimits(primary: (10, 300, 1_790_010_000), secondary: (20, 10080, 1_790_500_000)))])
        try env.codexFile(session: CF.sessionB, lines: [CF.header(id: CF.sessionB, at: t0 + 30_000, originator: "codex_work_desktop", account: "acct-one"),
                                                          event(1, at: t0 + 31_000, rate: CF.rateLimits(primary: (12, 300, 1_790_010_000), secondary: (21, 10080, 1_790_500_000)))])
        try env.syncCodex()
        let pools = await openAIPools(env).filter { $0.pool.accountLabel != "Unassigned" }
        XCTAssertEqual(pools.count, 1, "both products draw on one allowance, so there is one pool")
        // The later report, from the Work session, is the current state of the shared pool.
        XCTAssertEqual(pools[0].windows[0].utilizationPercent, 12)
        let origins = try env.db.read { try $0.query("SELECT DISTINCT p.id FROM quota_snapshot q JOIN session s ON s.id = q.origin_session_id JOIN product p ON p.id = s.product_id") { $0.text(0) } }
        XCTAssertEqual(Set(origins), ["codex", "chatgpt-work"], "the snapshots remember which product reported them")
    }

    func testTwoAccountsHaveTwoPoolsAndAreNeverSummed() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"),
                                                          event(1, at: t0 + 1000, rate: CF.rateLimits(primary: (40, 300, 1_790_010_000), secondary: (55, 10080, 1_790_500_000)))])
        try env.codexFile(session: CF.sessionB, lines: [CF.header(id: CF.sessionB, at: t0 + 5000, account: "acct-two"),
                                                          event(1, at: t0 + 6000, rate: CF.rateLimits(primary: (30, 300, 1_790_010_100), secondary: (35, 10080, 1_790_500_100)))])
        try env.codexFile(session: CF.sessionC, lines: [CF.header(id: CF.sessionC, at: t0 + 9000, account: nil),
                                                          event(1, at: t0 + 10_000, rate: CF.rateLimits(primary: (5, 300, 1_790_010_200), secondary: (6, 10080, 1_790_500_200)))])
        try env.syncCodex()
        let pools = await openAIPools(env)
        XCTAssertEqual(pools.count, 3, "two named accounts and the explicit unassigned account")
        XCTAssertEqual(Set(pools.map(\.pool.key.accountID)).count, 3)
        let percentages = Set(pools.compactMap { $0.windows.first?.utilizationPercent })
        XCTAssertEqual(percentages, [40, 30, 5], "each pool keeps its own figure")
        XCTAssertEqual(pools.first { $0.pool.accountLabel == "Unassigned" }?.windows.first?.utilizationPercent, 5)
    }

    func testChatGPTChatIsExplicitlyUnobservableAndNeverShowsAFigure() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(count: 2, account: "acct-one"))
        try env.syncCodex()
        let registry = env.db.registry
        let chat = try XCTUnwrap(registry.pool(provider: .openAI, key: "chatgpt-chat"))
        XCTAssertFalse(chat.isObservable)
        XCTAssertEqual(chat.products, [.chatGPTChat])
        XCTAssertFalse(registry.pools(of: .codex).contains { $0.key == "chatgpt-chat" }, "chat limits are separate from Codex")
        XCTAssertFalse(registry.pools(of: .chatGPTWork).contains { $0.key == "chatgpt-chat" })
        XCTAssertFalse(registry.sources.contains { $0.products.contains(.chatGPTChat) }, "no telemetry source claims to observe chat")
        let pools = await openAIPools(env)
        XCTAssertFalse(pools.contains { $0.pool.key.poolKey == "chatgpt-chat" })
        let rows = try env.db.read { try $0.scalarInt("SELECT count(*) FROM quota_pool WHERE pool_key = 'chatgpt-chat'") }
        XCTAssertEqual(rows, 0)
    }

    func testAPoolThatNeverReportedIsListedWithItsWindowsUnavailable() async throws {
        let env = try TestEnv()
        let pools = await openAIPools(env)
        let codex = try XCTUnwrap(pools.first { $0.pool.key.poolKey == "codex" })
        XCTAssertEqual(codex.windows.map(\.windowKey), ["300m", "10080m"])
        for w in codex.windows {
            XCTAssertEqual(w.availability, .unavailable(.noData))
            XCTAssertNil(w.utilizationPercent, "nothing is assumed to be zero")
        }
    }

    func testOutOfOrderDeliveryNeverReplacesANewerSnapshot() async throws {
        let env = try TestEnv()
        let newer = event(1, at: t0 + 100_000, rate: CF.rateLimits(primary: (70, 300, 1_790_010_000), secondary: (60, 10080, 1_790_500_000)))
        let older = event(1, at: t0 + 1_000, rate: CF.rateLimits(primary: (20, 300, 1_790_010_000), secondary: (30, 10080, 1_790_500_000)))
        // A file that was written long ago is read after one that was written recently.
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0 + 90_000, account: "acct-one"), newer])
        try env.syncCodex()
        try env.codexFile(session: CF.sessionB, lines: [CF.header(id: CF.sessionB, at: t0, account: "acct-one"), older])
        try env.syncCodex()
        let pool = try await namedPool(env)
        XCTAssertEqual(pool.windows[0].utilizationPercent, 70)
        XCTAssertEqual(pool.windows[1].utilizationPercent, 60)
        // Both are in the history, in the order they happened.
        let history = await coordinator(env).history(pool: pool.pool.key, windowKey: "300m", since: .distantPast)
        XCTAssertEqual(history.map(\.utilizationPercent), [20, 70])
    }

    func testResetsOfOneCycleCollapseAndANewCycleIsRecognized() async throws {
        let env = try TestEnv()
        func rate(_ p: Double, reset: Double) -> String { CF.rateLimits(primary: (p, 300, reset), secondary: nil) }
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0, account: "acct-one"),
            event(1, at: t0 + 1_000, rate: rate(10, reset: 1_790_010_000)),
            event(2, at: t0 + 2_000, rate: rate(12, reset: 1_790_010_003)),      // The same cycle, reset time off by seconds.
            event(3, at: t0 + 3_000, rate: rate(12, reset: 1_790_010_001)),      // The same value again: only confirmed.
            event(4, at: t0 + 4_000, rate: rate(2, reset: 1_790_028_000)),       // Five hours later: a new cycle.
        ])
        try env.syncCodex()
        let cycles = try env.db.read { try $0.scalarInt("SELECT count(*) FROM quota_cycle") }
        let snapshots = try env.db.read { try $0.scalarInt("SELECT count(*) FROM quota_snapshot") }
        XCTAssertEqual(cycles, 2)
        XCTAssertEqual(snapshots, 3, "10 and 12 in the first cycle, 2 in the second")
        let confirmed = try env.db.read { try $0.queryOne("SELECT observed_at, last_confirmed_at FROM quota_snapshot WHERE utilization_pct = 12") { ($0.int(0), $0.int(1)) } }
        XCTAssertEqual(confirmed?.0, t0 + 2_000)
        XCTAssertEqual(confirmed?.1, t0 + 3_000, "a repeated value moves the confirmation time, not the first-seen time")
        // Reading everything again changes nothing.
        try env.syncCodex()
        XCTAssertEqual(try env.db.read { try $0.scalarInt("SELECT count(*) FROM quota_snapshot") }, 3)
    }

    func testFreshnessAgesAndAnElapsedWindowIsNotAssumedToBeZero() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"),
                                                          event(1, at: t0 + 1_000, rate: CF.rateLimits(primary: (64, 300, 1_790_010_000), secondary: (30, 10080, 1_790_500_000)))])
        try env.syncCodex()
        let base = Double(t0) / 1000
        let aging = try await namedPool(env, now: Date(timeIntervalSince1970: base + 30 * 60))
        XCTAssertEqual(aging.windows[0].freshness, .aging)
        let stale = try await namedPool(env, now: Date(timeIntervalSince1970: base + 2 * 3600))
        XCTAssertEqual(stale.windows[0].freshness, .stale)
        XCTAssertEqual(stale.windows[0].utilizationPercent, 64, "the last known value stays visible, marked stale")
        XCTAssertFalse(stale.windows[0].isAlertEligible)
        // After the five-hour window's reset the weekly one is still open and the short one is unknown.
        let afterReset = try await namedPool(env, now: Date(timeIntervalSince1970: 1_790_010_000 + 60))
        if case .windowElapsed = afterReset.windows[0].availability {} else { XCTFail("expected an elapsed window") }
        XCTAssertNil(afterReset.windows[0].utilizationPercent)
        XCTAssertEqual(afterReset.windows[1].utilizationPercent, 30)
    }

    func testAnotherLimitIdIsAnotherPool() async throws {
        let env = try TestEnv()
        let rate = CF.rateLimits(limitID: "codex_spark", plan: "pro", primary: (7, 300, 1_790_010_000), secondary: nil)
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"), event(1, at: t0 + 1_000, rate: rate),
                                                          event(2, at: t0 + 2_000, rate: CF.rateLimits(primary: (9, 300, 1_790_010_000), secondary: nil))])
        try env.syncCodex()
        let pools = await openAIPools(env).filter { $0.pool.accountLabel != "Unassigned" }
        XCTAssertEqual(Set(pools.map(\.pool.key.poolKey)), ["codex", "openai-limit:codex_spark"])
        XCTAssertEqual(pools.first { $0.pool.key.poolKey == "codex" }?.windows.first?.utilizationPercent, 9)
        XCTAssertEqual(pools.first { $0.pool.key.poolKey == "openai-limit:codex_spark" }?.windows.first?.utilizationPercent, 7)
    }

    func testSnapshotsWithoutWindowsAndImplausibleValuesAddNothing() async throws {
        let env = try TestEnv()
        let empty = CF.rateLimits(limitID: "premium", primary: nil, secondary: nil)
        let negative = CF.rateLimits(primary: (-5, 300, 1_790_010_000), secondary: nil)
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"),
                                                          event(1, at: t0 + 1_000, rate: empty), event(2, at: t0 + 2_000, rate: negative)])
        try env.syncCodex()
        XCTAssertEqual(try env.db.read { try $0.scalarInt("SELECT count(*) FROM quota_snapshot") }, 0)
    }

    func testPoolsAreComparedNeverAdded() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"),
                                                          event(1, at: t0 + 1_000, rate: CF.rateLimits(primary: (40, 300, 1_790_010_000), secondary: (80, 10080, 1_790_500_000)))])
        try env.syncCodex()
        let pools = await openAIPools(env)
        let pool = try XCTUnwrap(pools.first { $0.pool.accountLabel != "Unassigned" })
        XCTAssertEqual(pool.highestUtilization, 80, "the highest window, not 120")
    }

    func testClaudeAndOpenAIPoolsStaySeparateInTheSameDatabase() async throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0, account: "acct-one"), event(1, at: t0 + 1_000, rate: CF.rateLimits())])
        try env.syncCodex()
        let c = coordinator(env)
        let observed = Date(timeIntervalSince1970: Double(t0) / 1000)
        try ClaudeCacheFixture.write(to: env.root.appendingPathComponent("claude/.claude.json"), fetchedAt: observed, five: 77, week: 12,
                                     fiveReset: observed.addingTimeInterval(3600), weekReset: observed.addingTimeInterval(86400))
        await c.refresh(force: true)
        let all = await c.pools()
        let claude = try XCTUnwrap(all.first { $0.pool.key.provider == .anthropic })
        let openai = try XCTUnwrap(all.first { $0.pool.key.provider == .openAI && $0.pool.accountLabel != "Unassigned" })
        XCTAssertEqual(claude.windows.first?.utilizationPercent, 77)
        XCTAssertEqual(openai.windows.first?.utilizationPercent, 10)
        XCTAssertEqual(claude.windows.first?.windowKey, openai.windows.first?.windowKey, "both use the same window vocabulary")
        XCTAssertNotEqual(claude.pool.key, openai.pool.key)
    }
}

// MARK: - Verification and analytics

final class CodexVerifierTests: XCTestCase {
    /// A mixed history: an older session, a newer one with usage records, a fork, and one with a missing event.
    private func populate(_ env: TestEnv) throws {
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 3, account: "acct-one"))
        try FileManager.default.createDirectory(at: env.codexHome.appendingPathComponent("sessions/2026/10/13"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("era2-usage-record.jsonl"),
                                         to: env.codexHome.appendingPathComponent("sessions/2026/10/13/rollout-2026-10-13T09-00-00-01a00000-0000-7000-8000-0000000000f2.jsonl"))
        let forkAt = t0 + 600_000
        let own = CF.Usage(input: 700, cached: 100, output: 30)
        try env.codexFile(session: CF.sessionB, lines: CF.forkOfEventSession(id: CF.sessionB, parent: CF.sessionA, parentCount: 3, at: forkAt, own: [own]))
        let a = CF.Usage(input: 1000, cached: 500, output: 40, reasoning: 10)
        let b = CF.Usage(input: 2000, cached: 1500, output: 60, reasoning: 5)
        let missing = CF.Usage(input: 1200, cached: 1000, output: 30, reasoning: 8)
        try env.codexFile(session: CF.sessionC, lines: [CF.header(id: CF.sessionC, at: t0 + 900_000),
                                                          CF.tokenCount(ordinal: 1, at: t0 + 901_000, last: a, total: a),
                                                          CF.tokenCount(ordinal: 2, at: t0 + 902_000, last: b, total: a + missing + b)])
        try env.syncCodex()
    }

    func testTheIndependentRecountAgreesWithTheDatabase() throws {
        let env = try TestEnv()
        try populate(env)
        let report = try CodexVerifier(db: env.db, adapter: env.codexAdapter).verify()
        XCTAssertTrue(report.isConsistent, "\(report.mismatches)")
        XCTAssertEqual(report.sessionsChecked, 4)
        XCTAssertEqual(report.recordSessions, 1)
        XCTAssertEqual(report.forkSessions, 1)
        XCTAssertEqual(report.eventSessions, 2)
        XCTAssertEqual(report.expected.input, report.database.input)
        XCTAssertEqual(report.expected.output, report.database.output)
        XCTAssertEqual(report.expected.reasoning, report.database.reasoning)
        XCTAssertEqual(report.database.responses, report.expected.responses + 1, "the missing response is stored as a request of its own")
    }

    func testTheRecountDetectsAlteredData() throws {
        let env = try TestEnv()
        try populate(env)
        try env.db.write { c in try c.run("UPDATE model_request SET output_tokens = output_tokens + 1 WHERE request_key LIKE 'resp_fixture_0'") }
        let report = try CodexVerifier(db: env.db, adapter: env.codexAdapter).verify()
        XCTAssertFalse(report.isConsistent)
        XCTAssertEqual(report.mismatches.count, 1)
        XCTAssertEqual(report.mismatches.first?.mode, "records")
        // Removing a whole session is noticed as well.
        try env.db.write { c in try c.run("DELETE FROM model_request WHERE session_id IN (SELECT id FROM session WHERE external_id = ?)", [.text(CF.sessionA)]) }
        XCTAssertGreaterThanOrEqual(try CodexVerifier(db: env.db, adapter: env.codexAdapter).verify().mismatches.count, 2)
    }

    func testCodexsOwnCountIsComparedAsEvidenceOnly() throws {
        let env = try TestEnv()
        try populate(env)
        // A stand-in for Codex's state database, with the figures Codex would hold for the sessions.
        let url = env.root.appendingPathComponent("state_5.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let figures: [(String, Int64)] = [(CF.sessionA, 3 * 1050), (CF.sessionB, 123_456), (CF.sessionC, 1040 + 2060)]
        sqlite3_exec(handle, "CREATE TABLE threads (id TEXT PRIMARY KEY, tokens_used INTEGER NOT NULL)", nil, nil, nil)
        for (id, tokens) in figures { sqlite3_exec(handle, "INSERT INTO threads VALUES('\(id)', \(tokens))", nil, nil, nil) }
        let state = try XCTUnwrap(CodexVerifier(db: env.db, adapter: env.codexAdapter).verify(stateDatabase: url).state)
        XCTAssertEqual(state.threads, 3)
        XCTAssertEqual(state.equal, 1, "the plain session agrees with Codex")
        XCTAssertEqual(state.databaseHigher, 1, "the session with a missing event has more usage than Codex counted")
        XCTAssertEqual(state.databaseLower, 1, "a fork's own count includes the history it inherited")
    }
}

final class OpenAIAnalyticsTests: XCTestCase {
    private func populate(_ env: TestEnv) throws {
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 2, originator: "codex_work_desktop", account: "acct-one"))
        try env.codexFile(session: CF.sessionB, lines: CF.eventSession(id: CF.sessionB, at: t0 + 100_000, count: 3, originator: "codex_exec", account: "acct-one"))
        try env.codexFile(session: CF.sessionC, lines: CF.eventSession(id: CF.sessionC, at: t0 + 200_000, count: 1, originator: "Codex Desktop", account: "acct-two"))
        try Fixture.write([Fixture.assistant(id: "c1", session: "CLAUDE", at: t0, input: 7, output: 11, cacheRead: 13)], to: try env.mainFile(session: "CLAUDE"))
        try env.syncAll()
        try env.syncCodex()
    }

    func testFiltersByProductSurfaceAndAccount() throws {
        let env = try TestEnv()
        try populate(env)
        let engine = AnalyticsEngine(db: env.db)
        func requests(_ build: (inout UsageFilter) -> Void) throws -> Int {
            var f = UsageFilter(); build(&f); return try engine.totals(f).requests
        }
        XCTAssertEqual(try requests { $0.products = [.chatGPTWork] }, 2)
        XCTAssertEqual(try requests { $0.products = [.codex] }, 4)
        XCTAssertEqual(try requests { $0.surfaces = [.terminal] }, 4, "the command line, whichever provider's it is")
        XCTAssertEqual(try requests { $0.surfaces = [.terminal]; $0.providers = [.openAI] }, 3)
        XCTAssertEqual(try requests { $0.surfaces = [.codexDesktop] }, 1)
        XCTAssertEqual(try requests { $0.providers = [.openAI] }, 6)
        XCTAssertEqual(try requests { $0.providers = [.anthropic] }, 1)
        let accounts = try engine.filterOptions().accounts.filter { $0.provider == .openAI }
        XCTAssertEqual(accounts.count, 2)
        let one = try XCTUnwrap(accounts.first { $0.id == (try? env.db.read { try $0.scalarInt("SELECT account_id FROM session WHERE external_id = ?", [.text(CF.sessionA)]) }) ?? -1 })
        XCTAssertEqual(try requests { $0.accounts = [one.id] }, 5, "one account spans Work and the command line")
        XCTAssertEqual(try requests { $0.products = [.codex]; $0.accounts = [one.id] }, 3)
        XCTAssertEqual(try requests { $0.telemetrySources = [.codexRollouts] }, 6)
        XCTAssertEqual(try requests { $0.telemetrySources = [.claudeTranscripts] }, 1)
    }

    func testCoverageSaysWhichCategoriesWereNotReported() throws {
        let env = try TestEnv()
        try populate(env)
        let engine = AnalyticsEngine(db: env.db)
        var openai = UsageFilter(); openai.providers = [.openAI]
        let o = try engine.totals(openai).coverage
        XCTAssertEqual(o.requests, 6)
        XCTAssertEqual(o.missingReasoning, 0)
        XCTAssertTrue(o.reasoningKnown)
        var claude = UsageFilter(); claude.providers = [.anthropic]
        let c = try engine.totals(claude).coverage
        XCTAssertEqual(c.missingReasoning, 1, "Claude Code's log does not break out thinking tokens")
        XCTAssertFalse(c.reasoningKnown)
        let all = try engine.totals().coverage
        XCTAssertEqual(all.requests, 7)
        XCTAssertEqual(all.missingReasoning, 1)
    }

    func testTotalsNeverCountAnythingTwice() throws {
        let env = try TestEnv()
        try populate(env)
        let engine = AnalyticsEngine(db: env.db)
        let all = try engine.totals()
        // The sum over the models, the sessions and the days all equal the whole.
        XCTAssertEqual(try engine.models().reduce(TokenCounts()) { $0 + $1.tokens }, all.tokens)
        XCTAssertEqual(try engine.sessionRows().reduce(TokenCounts()) { $0 + $1.tokens }, all.tokens)
        XCTAssertEqual(try engine.projects().reduce(TokenCounts()) { $0 + $1.tokens }, all.tokens)
        XCTAssertEqual(try engine.series(UsageFilter(), granularity: .day).reduce(TokenCounts()) { $0 + $1.tokens }, all.tokens)
        // Reasoning is inside output: 6 OpenAI requests of 20 reasoning tokens in 50 output tokens each.
        var openai = UsageFilter(); openai.providers = [.openAI]
        let t = try engine.totals(openai).tokens
        XCTAssertEqual(t.reasoningOutput, 120)
        XCTAssertEqual(t.output, 300)
        XCTAssertEqual(t.totalProcessed, 6 * 1050)
    }

    func testModelRowsKeepProvidersApart() throws {
        let env = try TestEnv()
        try populate(env)
        let rows = try AnalyticsEngine(db: env.db).models()
        XCTAssertEqual(Set(rows.map(\.provider)), [.anthropic, .openAI])
        XCTAssertEqual(rows.first { $0.provider == .openAI }?.canonical, "gpt-5.6-terra")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testSessionDetailPutsTheOwnAccountsWindowNextToLocalShares() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 2, originator: "codex_work_desktop", account: "acct-one"))
        try env.codexFile(session: CF.sessionB, lines: CF.eventSession(id: CF.sessionB, at: t0 + 3000, count: 1, originator: "codex_exec", account: "acct-one"))
        try env.codexFile(session: CF.sessionC, lines: CF.eventSession(id: CF.sessionC, at: t0 + 4000, count: 5, originator: "codex_exec", account: "acct-two"))
        try env.syncCodex()
        let engine = AnalyticsEngine(db: env.db)
        let work = try XCTUnwrap(engine.sessionRows().first { $0.externalID == CF.sessionA })
        let detail = try XCTUnwrap(engine.sessionDetail(id: work.id))
        let window = try XCTUnwrap(detail.windows.first { $0.windowKey == "300m" })
        XCTAssertEqual(window.poolKey, "codex")
        // The window covers the account's two sessions (the Work one and the command line one), 3 requests of 5, and
        // the other account's requests are not part of the share.
        XCTAssertEqual(window.sessionTokens.output, 100)
        XCTAssertEqual(window.localWindowTokens.output, 150)
        XCTAssertEqual(window.shareOfObservedFreshTokens ?? 0, 2.0 / 3.0, accuracy: 1e-9)
    }
}

// MARK: - Both providers running together

final class ConcurrentProvidersTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("condition not met within \(timeout)s")
    }

    func testBothProvidersAreCollectedLiveAndSurviveARestartWithoutDuplicates() async throws {
        let env = try TestEnv()
        try FileManager.default.createDirectory(at: env.codexHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let collector = UsageCollector(db: env.db, adapters: [env.adapter, env.codexAdapter], reconcileInterval: 3600)
        await collector.start()

        // Both tools write at the same time, and the Codex file keeps growing.
        let claude = try env.mainFile(session: "CL")
        let codexLines = CF.eventSession(id: CF.sessionA, count: 6, account: "acct-one")
        let codex = try env.codexFile(session: CF.sessionA, lines: Array(codexLines.prefix(4)))
        try Fixture.write((0..<5).map { Fixture.assistant(id: "c\($0)", session: "CL", at: t0 + Int64($0) * 1000, output: 10) }, to: claude)
        try await waitUntil { try env.totals().requests == 5 + 1 }
        try Fixture.append(Array(codexLines.dropFirst(4)), to: codex)
        try Fixture.append([Fixture.assistant(id: "c5", session: "CL", at: t0 + 6000, output: 10)], to: claude)
        try await waitUntil { try env.totals().requests == 6 + 6 }
        await collector.stop()

        // Restarting on the same database, and on a reopened one, changes nothing.
        let before = try env.totals()
        try env.reopen()
        let again = UsageCollector(db: env.db, adapters: [env.adapter, env.codexAdapter], reconcileInterval: 3600)
        await again.start()
        try await Task.sleep(for: .seconds(1))
        await again.stop()
        let after = try env.totals()
        XCTAssertEqual(after.tokens, before.tokens)
        XCTAssertEqual(after.requests, 12)
        let duplicates = try env.db.read { try $0.scalarInt("SELECT count(*) FROM (SELECT product_id, request_key FROM model_request GROUP BY 1, 2 HAVING count(*) > 1)") }
        XCTAssertEqual(duplicates, 0)
        let report = try CodexVerifier(db: env.db, adapter: env.codexAdapter).verify()
        XCTAssertTrue(report.isConsistent)
    }

    func testACorruptCodexFileDoesNotStopClaudeCollection() async throws {
        let env = try TestEnv()
        let dir = env.codexHome.appendingPathComponent("sessions/2026/10/12")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not zstd at all".utf8).write(to: dir.appendingPathComponent("rollout-2026-10-12T12-00-00-\(CF.sessionA).jsonl.zst"))
        try Fixture.write([Fixture.assistant(id: "m1", session: "CL", at: t0, output: 7)], to: try env.mainFile(session: "CL"))
        let collector = UsageCollector(db: env.db, adapters: [env.codexAdapter, env.adapter], reconcileInterval: 3600)
        await collector.start()
        try await waitUntil { try env.totals().tokens.output == 7 }
        let snap = await collector.snapshot()
        XCTAssertEqual(snap.sources.first { $0.sourceID == .claudeTranscripts }?.state, .ok)
        await collector.stop()
    }
}
