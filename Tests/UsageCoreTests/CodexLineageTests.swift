import XCTest
@testable import UsageCore

private typealias CF = CodexFixture

/// How Codex sessions that copy history, mix record formats or lose records are counted.
///
/// These tests are modelled on shapes found in real session files: a fork repeats its parent's lines in the same
/// positions, a response can have a usage record and no `token_count` event, a compaction is a request of its own,
/// and two unrelated runs of the same command can report identical figures.
final class CodexLineageTests: XCTestCase {
    private let each = CF.Usage(input: 1000, cached: 600, output: 50, reasoning: 20)

    private func notices(_ env: TestEnv) throws -> [String] {
        try env.db.read { try $0.query("SELECT message FROM ingest_issue WHERE severity = 'notice' ORDER BY id") { $0.text(0) } }
    }

    private func requestCount(_ env: TestEnv, session: String) throws -> Int {
        try XCTUnwrap(AnalyticsEngine(db: env.db).sessionRows().first { $0.externalID == session }).requests
    }

    // MARK: Forks

    func testAForkIsRecognizedByWhatItSaysAndLegitimateActivityRightAfterItIsCounted() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 3))
        let forkAt = t0 + 600_000
        // The fork's own response is written 900 ms after the fork was created, inside the old 1.5 second window.
        let own = CF.Usage(input: 700, cached: 100, output: 30)
        try env.codexFile(session: CF.sessionB, lines: CF.forkOfEventSession(
            id: CF.sessionB, parent: CF.sessionA, parentCount: 3, at: forkAt, own: [own], ownAt: [forkAt + 900]))
        try env.syncCodex()
        XCTAssertEqual(try requestCount(env, session: CF.sessionB), 1, "immediate activity of the child is not mistaken for copied history")
        XCTAssertEqual(try env.totals().requests, 4)
        XCTAssertTrue(try notices(env).contains { $0.contains("not in its parent's file") },
                      "a line written at the instant of the fork that the parent does not have is reported as uncertain")
    }

    func testACopyThatTakesLongerThanTheBurstWindowIsStillRecognized() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 3))
        // A long history takes seconds to copy. The last copied lines are written 3 seconds after the fork was created.
        try env.codexFile(session: CF.sessionB, lines: CF.forkOfEventSession(
            id: CF.sessionB, parent: CF.sessionA, parentCount: 3, at: t0 + 600_000, copySpreadMs: 1500))
        try env.syncCodex()
        XCTAssertEqual(try requestCount(env, session: CF.sessionB), 0)
        XCTAssertEqual(try env.totals().requests, 3)
        XCTAssertEqual(try notices(env), [])
    }

    func testWithoutTheParentTheInstantOfTheForkIsTheFallbackAndTheSessionSaysSo() throws {
        let env = try TestEnv()
        let forkAt = t0 + 600_000
        let own = CF.Usage(input: 700, cached: 100, output: 30)
        // Only the fork is on this Mac.
        try env.codexFile(session: CF.sessionB, lines: CF.forkOfEventSession(
            id: CF.sessionB, parent: CF.sessionA, parentCount: 3, at: forkAt, own: [own], ownAt: [forkAt + 20_000]))
        try env.syncCodex()
        XCTAssertEqual(try requestCount(env, session: CF.sessionB), 1)
        XCTAssertEqual(try env.totals().tokens.output, 30)
        let list = try notices(env)
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].contains("3 usage lines"), list[0])
        XCTAssertTrue(list[0].contains("not on this Mac"), list[0])
    }

    func testTheNoticeOfAFileIsReplacedWhenItIsReadAgain() throws {
        let env = try TestEnv()
        let forkAt = t0 + 600_000
        let url = try env.codexFile(session: CF.sessionB, lines: CF.forkOfEventSession(id: CF.sessionB, parent: CF.sessionA, parentCount: 3, at: forkAt))
        try env.syncCodex()
        XCTAssertEqual(try notices(env).count, 1)
        // The parent turns up, so the fork can be checked against it and nothing is uncertain any longer.
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 3))
        try Fixture.write(CF.forkOfEventSession(id: CF.sessionB, parent: CF.sessionA, parentCount: 3, at: forkAt,
                                                own: [CF.Usage(input: 5, output: 5)]), to: url)
        try env.syncCodex()
        XCTAssertEqual(try notices(env), [])
        XCTAssertEqual(try requestCount(env, session: CF.sessionB), 1)
    }

    func testAForkOfARecordSessionRepeatsResponseIdsAndAttributesThemToTheirMaker() throws {
        let env = try TestEnv()
        let forkAt = t0 + 600_000
        let u1 = CF.Usage(input: 900, cached: 500, output: 40, reasoning: 10), u2 = CF.Usage(input: 1100, cached: 800, output: 60, reasoning: 20)
        let parent = [CF.header(id: CF.sessionA, at: t0), CF.turnContext(ordinal: 1, at: t0 + 100),
                      CF.tokenUsageRecord(ordinal: 2, at: t0 + 1000, response: "resp_a1", usage: u1, total: u1),
                      CF.tokenUsageRecord(ordinal: 3, at: t0 + 2000, response: "resp_a2", usage: u2, total: u1 + u2)]
        let fork = [CF.header(id: CF.sessionB, at: forkAt, forkedFrom: CF.sessionA), CF.turnContext(ordinal: 1, at: forkAt + 1),
                    CF.tokenUsageRecord(ordinal: 2, at: forkAt + 2, response: "resp_a1", usage: u1, total: u1, session: CF.sessionB, thread: CF.sessionA),
                    CF.tokenUsageRecord(ordinal: 3, at: forkAt + 3, response: "resp_a2", usage: u2, total: u1 + u2, session: CF.sessionB, thread: CF.sessionA),
                    CF.tokenUsageRecord(ordinal: 4, at: forkAt + 30_000, response: "resp_b1", usage: u1, total: u1 + u2 + u1, session: CF.sessionB)]
        // The fork is read first, and the parent only later. The result must not depend on the order.
        try env.codexFile(session: CF.sessionB, lines: fork)
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 3)
        try env.codexFile(session: CF.sessionA, lines: parent)
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 3, "the parent's responses are the same requests")
        XCTAssertEqual(try requestCount(env, session: CF.sessionA), 2)
        XCTAssertEqual(try requestCount(env, session: CF.sessionB), 1)
    }

    // MARK: Mixed and incomplete telemetry

    func testAFileWithBothKindsOfRecordCountsEveryResponseOnce() throws {
        let env = try TestEnv()
        let u1 = CF.Usage(input: 1000, cached: 600, output: 50), u2 = CF.Usage(input: 1500, cached: 900, output: 70)
        let u3 = CF.Usage(input: 2000, cached: 1200, output: 90)
        // The first response is reported by an event only (an older version), the second by a record and an event, and
        // the third by an event whose record is missing.
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0), CF.turnContext(ordinal: 1, at: t0 + 100),
            CF.tokenCount(ordinal: 2, at: t0 + 1000, last: u1, total: u1),
            CF.tokenUsageRecord(ordinal: 3, at: t0 + 2000, response: "resp_2", usage: u2, total: u1 + u2),
            CF.tokenCount(ordinal: 4, at: t0 + 2001, last: u2, total: u1 + u2),
            CF.tokenCount(ordinal: 5, at: t0 + 3000, last: u3, total: u1 + u2 + u3),
        ])
        try env.syncCodex()
        let t = try env.totals()
        XCTAssertEqual(t.requests, 3)
        XCTAssertEqual(t.tokens.output, 50 + 70 + 90, "nothing is missing and nothing is counted twice")
        XCTAssertTrue(try notices(env).contains { $0.contains("1 token_count events have no matching usage record") })
    }

    func testTheEventOfARecordedResponseIsFoundWhicheverComesFirst() throws {
        let env = try TestEnv()
        let u = CF.Usage(input: 1000, cached: 600, output: 50)
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0),
            CF.tokenCount(ordinal: 1, at: t0 + 1000, last: u, total: u),
            CF.tokenUsageRecord(ordinal: 2, at: t0 + 1001, response: "resp_1", usage: u, total: u),
        ])
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 1, "an event written before its record is still the same response")
    }

    func testACompactionRequestWithoutAnEventIsCountedOnce() throws {
        let env = try TestEnv()
        let u = CF.Usage(input: 1000, cached: 600, output: 50), summary = CF.Usage(input: 9000, cached: 8000, output: 400)
        // The summarizing request has a record, and the compaction marker repeats it. It has no `token_count` event.
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0),
            CF.tokenUsageRecord(ordinal: 1, at: t0 + 1000, response: "resp_1", usage: u, total: u),
            CF.tokenCount(ordinal: 2, at: t0 + 1001, last: u, total: u),
            CF.tokenUsageRecord(ordinal: 3, at: t0 + 2000, response: "resp_compaction", usage: summary, total: u + summary),
            CF.compacted(ordinal: 4, at: t0 + 2001, response: "resp_compaction", usage: summary),
        ])
        try env.syncCodex()
        let t = try env.totals()
        XCTAssertEqual(t.requests, 2)
        XCTAssertEqual(t.tokens.output, 450)
    }

    func testACompactionRecordIsCountedEvenWhenItsOwnLineIsMissing() throws {
        let env = try TestEnv()
        let summary = CF.Usage(input: 9000, cached: 8000, output: 400)
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0),
            CF.compacted(ordinal: 1, at: t0 + 2000, response: "resp_compaction", usage: summary),
        ])
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 1)
        XCTAssertEqual(try env.totals().tokens.logicalInput, 9000)
    }

    func testARecordWhoseThreadCounterGrewByMoreIsReported() throws {
        let env = try TestEnv()
        let u = CF.Usage(input: 1000, cached: 600, output: 50)
        // Between the two records Codex's own counter grew by 500 tokens that no record explains.
        let hidden = CF.Usage(input: 450, output: 50)
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0),
            CF.tokenUsageRecord(ordinal: 1, at: t0 + 1000, response: "resp_1", usage: u, total: u),
            CF.tokenUsageRecord(ordinal: 2, at: t0 + 2000, response: "resp_2", usage: u, total: u + hidden + u),
        ])
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 2, "the missing usage is not invented")
        let list = try notices(env)
        XCTAssertTrue(list.contains { $0.contains("500 tokens more") }, "\(list)")
    }

    func testACounterThatIsResetDoesNotInventUsageAndTheNextResponseIsStillCounted() throws {
        let env = try TestEnv()
        let u = CF.Usage(input: 1000, cached: 600, output: 50)
        // After a compaction the running totals start again from the next response.
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0),
            CF.tokenCount(ordinal: 1, at: t0 + 1000, last: u, total: u),
            CF.tokenCount(ordinal: 2, at: t0 + 2000, last: u, total: u + u),
            CF.compacted(ordinal: 3, at: t0 + 2500),
            CF.tokenCount(ordinal: 4, at: t0 + 3000, last: u, total: u),
            CF.tokenCount(ordinal: 5, at: t0 + 4000, last: u, total: u + u),
        ])
        try env.syncCodex()
        let t = try env.totals()
        XCTAssertEqual(t.requests, 4)
        XCTAssertEqual(t.tokens.output, 200)
    }

    // MARK: Identity

    func testTwoUnrelatedRunsWithIdenticalFiguresAreTwoRequests() throws {
        let env = try TestEnv()
        // Two runs of the same command report the same figures. This happens in real files, so the figures cannot
        // be what identifies a response.
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 1))
        try env.codexFile(session: CF.sessionB, lines: CF.eventSession(id: CF.sessionB, count: 1))
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 2)
        XCTAssertEqual(try env.totals().tokens.output, 100)
    }

    func testAResponseSeenByTwoProductsOfOneProviderIsOneRequest() throws {
        let env = try TestEnv()
        let u = CF.Usage(input: 1000, cached: 600, output: 50)
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0, originator: "codex_exec"),
            CF.tokenUsageRecord(ordinal: 1, at: t0 + 1000, response: "resp_shared", usage: u, total: u),
        ])
        // The same response in a session of the ChatGPT desktop app, which names the original thread as its maker.
        try env.codexFile(session: CF.sessionB, lines: [
            CF.header(id: CF.sessionB, at: t0 + 5000, originator: "codex_work_desktop", source: "\"vscode\""),
            CF.tokenUsageRecord(ordinal: 1, at: t0 + 5001, response: "resp_shared", usage: u, total: u, session: CF.sessionB, thread: CF.sessionA),
        ])
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 1)
        XCTAssertEqual(try env.totals().tokens.output, 50)
    }

    func testTheSameSessionInItsActiveAndArchivedCopyIsCountedOnce() throws {
        let env = try TestEnv()
        let lines = CF.eventSession(id: CF.sessionA, count: 4)
        try env.codexFile(session: CF.sessionA, lines: lines)
        try env.codexFile(session: CF.sessionA, lines: lines, archived: true)
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 4)
        XCTAssertEqual(try env.totals().sessions, 1)
    }

    func testRereadingAFileAfterARestartChangesNothing() throws {
        let env = try TestEnv()
        try env.codexFile(session: CF.sessionA, lines: CF.eventSession(id: CF.sessionA, count: 3))
        try env.codexFile(session: CF.sessionB, lines: CF.forkOfEventSession(
            id: CF.sessionB, parent: CF.sessionA, parentCount: 3, at: t0 + 600_000, own: [CF.Usage(input: 700, cached: 100, output: 30)]))
        try env.syncCodex()
        let before = try env.totals()
        // A new synchronizer on the same database stands for a restart. The files are read again from their start.
        try env.db.write { try $0.run("UPDATE source_file SET size = 0, mtime_ms = 0") }
        try env.syncCodex()
        let after = try env.totals()
        XCTAssertEqual(before.requests, after.requests)
        XCTAssertEqual(before.tokens, after.tokens)
    }

    func testAChangedFileFormatIsReportedInsteadOfCountingAsNothing() throws {
        let env = try TestEnv()
        let u = CF.Usage(input: 1000, cached: 600, output: 50)
        // A newer Codex renames the usage field of its records and the total of its events.
        let renamedRecord = CF.line("token_usage_record", ordinal: 2, at: t0 + 2000,
                                    payload: "{\"thread_id\":\"\(CF.sessionA)\",\"response_id\":\"resp_x\",\"tokens_used\":{\"input\":1}}")
        let renamedEvent = CF.line("event_msg", ordinal: 3, at: t0 + 3000,
                                   payload: "{\"type\":\"token_count\",\"info\":{\"cumulative\":{\"input\":1}},\"rate_limits\":null}")
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: t0),
            CF.tokenCount(ordinal: 1, at: t0 + 1000, last: u, total: u),
            renamedRecord, renamedEvent,
        ])
        try env.syncCodex()
        XCTAssertEqual(try env.totals().requests, 1, "what could be read is counted")
        XCTAssertTrue(try notices(env).contains { $0.contains("2 lines that should report token usage") && $0.contains("file format") })
    }
}
