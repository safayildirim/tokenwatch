import XCTest
@testable import UsageCore

final class TokenMathTests: XCTestCase {
    func testDerivedMetricDefinitions() {
        let t = TokenCounts(uncachedInput: 10, output: 40, cacheRead: 800, cacheCreation: 190)
        XCTAssertEqual(t.logicalInput, 1000)              // uncached + cacheRead + cacheCreation
        XCTAssertEqual(t.totalProcessed, 1040)            // logical input + output
        XCTAssertEqual(t.freshTokens, 240)                // everything except cache reads
        XCTAssertEqual(t.cacheHitRatio!, 0.8, accuracy: 1e-12)
        XCTAssertEqual(t.outputToInputRatio!, 0.04, accuracy: 1e-12)
    }

    func testRatiosAreNilWithoutInput() {
        let t = TokenCounts(output: 5)
        XCTAssertNil(t.cacheHitRatio)
        XCTAssertNil(t.outputToInputRatio)
    }

    func testCacheCreationSplitIsReportedSeparately() {
        let t = TokenCounts(cacheCreation: 100, cacheCreation5m: 30, cacheCreation1h: 50)
        XCTAssertEqual(t.cacheCreationUnsplit, 20)
    }

    func testAdditionKeepsEveryCategory() {
        let a = TokenCounts(uncachedInput: 1, output: 2, cacheRead: 3, cacheCreation: 4, cacheCreation5m: 1, cacheCreation1h: 2)
        let b = TokenCounts(uncachedInput: 10, output: 20, cacheRead: 30, cacheCreation: 40, cacheCreation5m: 10, cacheCreation1h: 20)
        XCTAssertEqual(a + b, TokenCounts(uncachedInput: 11, output: 22, cacheRead: 33, cacheCreation: 44, cacheCreation5m: 11, cacheCreation1h: 22))
    }
}

final class ObservationMergeTests: XCTestCase {
    private func obs(output: Int, input: Int = 2, cacheRead: Int = 500, cacheCreation: Int = 100, at: Int64 = t0,
                     agent: String? = nil, model: String = "claude-opus-5-5", stop: String? = nil) -> RequestObservation {
        RequestObservation(sourceID: "s", requestKey: "msg_1", apiRequestID: "req_1", sessionExternalID: "S",
                           agentExternalID: agent, modelID: model, requestedAtMs: at, uncachedInput: Int64(input),
                           output: Int64(output), cacheRead: Int64(cacheRead), cacheCreation: Int64(cacheCreation),
                           cacheCreation5m: 0, cacheCreation1h: Int64(cacheCreation), stopReason: stop)
    }

    func testStreamingSnapshotsTakeTheFinalOutput() {
        let result = [obs(output: 8), obs(output: 8), obs(output: 649, stop: "tool_use")].reduce(nil as RequestObservation?) { $0?.merged(with: $1) ?? $1 }!
        XCTAssertEqual(result.output, 649)
        XCTAssertEqual(result.cacheRead, 500)
        XCTAssertEqual(result.stopReason, "tool_use")
    }

    func testZeroedReplayNeverReducesUsage() {
        let real = obs(output: 300)
        let replay = obs(output: 0, input: 0, cacheRead: 0, cacheCreation: 0, at: t0 + 60_000)
        XCTAssertEqual(real.merged(with: replay).tokens.totalProcessed, real.tokens.totalProcessed)
        XCTAssertEqual(replay.merged(with: real).tokens.totalProcessed, real.tokens.totalProcessed)
        XCTAssertEqual(real.merged(with: replay).requestedAtMs, t0, "the earliest timestamp is kept")
    }

    func testMergeIsIdempotentCommutativeAndAssociative() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let items = (0..<5).map { _ in
                obs(output: Int.random(in: 0...900, using: &rng), input: Int.random(in: 0...4, using: &rng),
                    cacheRead: Int.random(in: 0...2000, using: &rng), cacheCreation: Int.random(in: 0...300, using: &rng),
                    at: t0 + Int64.random(in: 0...100_000, using: &rng),
                    agent: [nil, "a1", "a2"].randomElement(using: &rng)!, stop: [nil, "end_turn", "tool_use"].randomElement(using: &rng)!)
            }
            let forward = items.dropFirst().reduce(items[0]) { $0.merged(with: $1) }
            let backward = items.reversed().dropFirst().reduce(items.last!) { $0.merged(with: $1) }
            let shuffled = items.shuffled().dropFirst().reduce(items.shuffled()[0]) { $0.merged(with: $1) }
            _ = shuffled
            XCTAssertEqual(forward.tokens, backward.tokens)
            XCTAssertEqual(forward.requestedAtMs, backward.requestedAtMs)
            XCTAssertEqual(forward.agentExternalID, backward.agentExternalID)
            XCTAssertEqual(forward.stopReason, backward.stopReason)
            // Merging a result with itself, or with any of its inputs again, changes nothing, which is idempotence.
            XCTAssertEqual(forward.merged(with: forward), forward)
            for item in items { XCTAssertEqual(forward.merged(with: item), forward) }
            // Grouping does not matter, which is associativity.
            XCTAssertEqual(items[0].merged(with: items[1]).merged(with: items[2]),
                           items[0].merged(with: items[1].merged(with: items[2])))
        }
    }

    func testMainConversationWinsOverSubAgentReplay() {
        XCTAssertNil(obs(output: 5, agent: nil).merged(with: obs(output: 5, agent: "a1")).agentExternalID)
        XCTAssertNil(obs(output: 5, agent: "a1").merged(with: obs(output: 5, agent: nil)).agentExternalID)
        XCTAssertEqual(obs(output: 5, agent: "b").merged(with: obs(output: 5, agent: "a")).agentExternalID, "a")
    }

    func testBatchPremergesObservationsOfOneRequest() {
        var batch = NormalizedBatch()
        for o in [8, 8, 649] { batch.add(obs(output: o)) }
        XCTAssertEqual(batch.requests.count, 1)
        XCTAssertEqual(batch.requests.values.first?.output, 649)
    }
}

final class ModelCatalogTests: XCTestCase {
    func testCanonicalization() {
        XCTAssertEqual(ModelCatalog.describe("claude-opus-5-5[1m]").canonical, "claude-opus-5-5")
        XCTAssertEqual(ModelCatalog.describe("claude-haiku-4-5-20251001").canonical, "claude-haiku-4-5")
        XCTAssertEqual(ModelCatalog.describe("us.anthropic.claude-sonnet-4-6").canonical, "claude-sonnet-4-6")
        XCTAssertEqual(ModelCatalog.describe("claude-opus-5-5").displayName, "Opus 5.5")
        XCTAssertEqual(ModelCatalog.describe("claude-fable-5-1").family, "fable")
        XCTAssertEqual(ModelCatalog.describe("mystery-model").family, "other")
    }
}

/// End-to-end token accounting through the real importer and database.
final class IngestAccountingTests: XCTestCase {
    func testEveryTokenCategoryIsStored() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        try Fixture.write([Fixture.assistant(id: "msg_1", session: "S1", at: t0, input: 7, output: 321, cacheRead: 4000,
                                             cacheCreation: 900, fiveMinute: 300, oneHour: 600)], to: f)
        try env.syncAll()
        let t = try env.totals()
        XCTAssertEqual(t.tokens.uncachedInput, 7)
        XCTAssertEqual(t.tokens.output, 321)
        XCTAssertEqual(t.tokens.cacheRead, 4000)
        XCTAssertEqual(t.tokens.cacheCreation, 900)
        XCTAssertEqual(t.tokens.cacheCreation5m, 300)
        XCTAssertEqual(t.tokens.cacheCreation1h, 600)
        XCTAssertEqual(t.tokens.logicalInput, 4907)
        XCTAssertEqual(t.requests, 1)
    }

    func testRepeatedStreamingUpdatesAreCountedOnce() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        // This is one response streamed as four lines, and only the output count grows.
        try Fixture.write([
            Fixture.assistant(id: "msg_1", session: "S1", at: t0, output: 8, cacheRead: 1000, cacheCreation: 50),
            Fixture.assistant(id: "msg_1", session: "S1", at: t0 + 400, output: 8, cacheRead: 1000, cacheCreation: 50),
            Fixture.assistant(id: "msg_1", session: "S1", at: t0 + 900, output: 120, cacheRead: 1000, cacheCreation: 50),
            Fixture.assistant(id: "msg_1", session: "S1", at: t0 + 1500, output: 649, cacheRead: 1000, cacheCreation: 50, stop: "end_turn"),
        ], to: f)
        try env.syncAll()
        let t = try env.totals()
        XCTAssertEqual(t.requests, 1)
        XCTAssertEqual(t.tokens.output, 649)
        XCTAssertEqual(t.tokens.cacheRead, 1000, "cached input must not be multiplied by the number of lines")
        XCTAssertEqual(t.tokens.cacheCreation, 50)
    }

    func testDeliveryOrderDoesNotMatter() throws {
        let lines = [
            Fixture.assistant(id: "msg_1", session: "S1", at: t0, output: 649, cacheRead: 1000, stop: "end_turn"),
            Fixture.assistant(id: "msg_1", session: "S1", at: t0 + 400, output: 8, cacheRead: 1000),
            Fixture.assistant(id: "msg_1", session: "S1", at: t0 + 800, input: 0, output: 0, cacheRead: 0),
        ]
        var results: [TokenCounts] = []
        for ordering in [lines, lines.reversed(), [lines[1], lines[2], lines[0]]] {
            let env = try TestEnv()
            try Fixture.write(Array(ordering), to: try env.mainFile(session: "S1"))
            try env.syncAll()
            results.append(try env.totals().tokens)
        }
        XCTAssertEqual(Set(results).count, 1)
        XCTAssertEqual(results[0].output, 649)
    }

    func testZeroUsageReplayAfterCompactionDoesNotCreateOrChangeRequests() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        try Fixture.write([
            Fixture.assistant(id: "msg_1", session: "S1", at: t0, output: 300, cacheRead: 5000),
            Fixture.assistant(id: "msg_1", session: "S1", at: t0 + 60_000, input: 0, output: 0, cacheRead: 0),
            Fixture.assistant(id: "msg_ghost", session: "S1", at: t0 + 61_000, input: 0, output: 0, cacheRead: 0),
        ], to: f)
        try env.syncAll()
        let t = try env.totals()
        XCTAssertEqual(t.requests, 1, "a replay with zero usage is not a request")
        XCTAssertEqual(t.tokens.output, 300)
    }

    func testSyntheticMessagesAreIgnored() throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.assistant(id: "msg_s", model: "<synthetic>", session: "S1", at: t0, input: 0, output: 0)],
                          to: try env.mainFile(session: "S1"))
        try env.syncAll()
        XCTAssertEqual(try env.totals().requests, 0)
    }

    func testSameRequestInMainFileAndSubAgentFileIsCountedOnce() throws {
        let env = try TestEnv()
        // A forked sub-agent replays its parent's message in its own log file.
        try Fixture.write([Fixture.assistant(id: "msg_shared", session: "S1", at: t0, output: 3404, cacheRead: 287_821, cacheCreation: 1220)],
                          to: try env.mainFile(session: "S1"))
        try Fixture.write([Fixture.assistant(id: "msg_shared", session: "S1", at: t0, output: 3404, cacheRead: 287_821, cacheCreation: 1220, agent: "A1")],
                          to: try env.subagentFile(session: "S1", agent: "A1"))
        try env.syncAll()
        let t = try env.totals()
        XCTAssertEqual(t.requests, 1)
        XCTAssertEqual(t.tokens.cacheRead, 287_821)
        let agentKey = try env.db.read { try $0.queryOne("SELECT agent_key FROM model_request") { $0.textOrNil(0) } }
        XCTAssertEqual(agentKey ?? "x", nil, "the request belongs to the main conversation")
    }

    func testSameRequestObservedByTwoSourcesIsCountedOnce() throws {
        // Two sources reporting one request share a request key, so the second observation merges into the first.
        let env = try TestEnv()
        var batch = NormalizedBatch()
        let a = RequestObservation(sourceID: "claude-code", requestKey: "msg_x", apiRequestID: "req_x", sessionExternalID: "S",
                                   modelID: "claude-opus-5-5", requestedAtMs: t0, uncachedInput: 2, output: 50, cacheRead: 10, cacheCreation: 5)
        var b = a
        b.output = 60
        batch.add(a)
        batch.add(SessionObservation(sourceID: "claude-code", externalID: "S", projectKey: "-p", cwd: nil, application: nil,
                                     clientVersion: nil, firstSeenMs: t0, lastSeenMs: t0, versionSeenMs: 0))
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: env.db)
        var second = NormalizedBatch()
        second.add(b)
        _ = try IngestWriter.apply(batch: second, checkpoint: nil, retentionFloorMs: nil, db: env.db)
        let t = try env.totals()
        XCTAssertEqual(t.requests, 1)
        XCTAssertEqual(t.tokens.output, 60)
    }

    func testMultiModelSessionKeepsModelsApart() throws {
        let env = try TestEnv()
        try Fixture.write([
            Fixture.assistant(id: "m1", model: "claude-opus-5-5", session: "S1", at: t0, output: 100),
            Fixture.assistant(id: "m2", model: "claude-sonnet-5-5", session: "S1", at: t0 + 1000, output: 200),
            Fixture.assistant(id: "m3", model: "claude-opus-5-5", session: "S1", at: t0 + 2000, output: 300),
        ], to: try env.mainFile(session: "S1"))
        try env.syncAll()
        let models = try AnalyticsEngine(db: env.db).models()
        XCTAssertEqual(Set(models.map(\.canonical)), ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(models.first { $0.canonical == "claude-opus-5-5" }?.tokens.output, 400)
        XCTAssertEqual(models.first { $0.canonical == "claude-sonnet-5-5" }?.tokens.output, 200)
        let session = try AnalyticsEngine(db: env.db).sessionRows().first!
        XCTAssertEqual(Set(session.models), ["Opus 5.5", "Sonnet 5.5"])
    }

    func testChildAgentUsageRollsUpIntoItsParentWithoutDoubleCounting() throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.assistant(id: "main1", session: "S1", at: t0, output: 100)], to: try env.mainFile(session: "S1"))
        try Fixture.write([
            Fixture.assistant(id: "sub1", session: "S1", at: t0 + 1000, output: 40, agent: "A1"),
            Fixture.assistant(id: "sub2", session: "S1", at: t0 + 2000, output: 60, agent: "A1"),
        ], to: try env.subagentFile(session: "S1", agent: "A1"))
        try Fixture.write([Fixture.assistant(id: "sub3", session: "S1", at: t0 + 3000, output: 25, agent: "A2")],
                          to: try env.subagentFile(session: "S1", agent: "A2"))
        try env.syncAll()

        let engine = AnalyticsEngine(db: env.db)
        XCTAssertEqual(try env.totals().tokens.output, 225, "the account total includes every agent exactly once")
        let sessions = try engine.sessionRows()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].tokens.output, 225)
        XCTAssertEqual(sessions[0].agentCount, 2)
        XCTAssertEqual(sessions[0].agentRequests, 3)

        let detail = try engine.sessionDetail(id: sessions[0].id)!
        XCTAssertEqual(detail.agents.first?.key, nil, "the main conversation is listed first")
        XCTAssertEqual(detail.agents.first(where: { $0.key == "A1" })?.tokens.output, 100)
        XCTAssertEqual(detail.agents.first(where: { $0.key == "A2" })?.tokens.output, 25)
        XCTAssertEqual(detail.agents.reduce(Int64(0)) { $0 + $1.tokens.output }, 225)
    }

    func testIncompleteAndDelayedWritesAreNotLost() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        let first = Fixture.assistant(id: "m1", session: "S1", at: t0, output: 10)
        let second = Fixture.assistant(id: "m2", session: "S1", at: t0 + 1000, output: 20)
        // The second record is cut off in the middle of a write.
        let cut = String(second.prefix(second.count / 2))
        try Fixture.write([first, cut], to: f, terminate: false)
        try env.syncAll()
        XCTAssertEqual(try env.totals().requests, 1, "the half-written line must not be parsed")
        let cp = try env.synchronizer.loadCheckpoint(sourceID: "claude-code", path: f.path)!
        XCTAssertEqual(cp.consumedOffset, Int64(first.utf8.count + 1), "the checkpoint stops at the last complete line")

        // The rest of the line arrives later.
        try Fixture.append([String(second.dropFirst(second.count / 2))], to: f)
        try env.syncAll()
        XCTAssertEqual(try env.totals().requests, 2)
        XCTAssertEqual(try env.totals().tokens.output, 30)

        // And re-reading changes nothing.
        try env.syncAll()
        XCTAssertEqual(try env.totals().tokens.output, 30)
    }

    func testMalformedLinesAreSkippedAndCounted() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        try Fixture.write([
            Fixture.assistant(id: "m1", session: "S1", at: t0, output: 10),
            "{ this is not json",
            "[1,2,3]",
            "{\"type\":\"assistant\",\"message\":{\"usage\":{\"output_tokens\":",
            Fixture.assistant(id: "m2", session: "S1", at: t0 + 1000, output: 20),
        ], to: f)
        let result = try env.syncAll()
        XCTAssertEqual(try env.totals().tokens.output, 30)
        XCTAssertGreaterThanOrEqual(result.first!.malformedLines, 3)
    }

    func testVeryLongLineSpanningChunksIsHandled() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        // A 9 MB line (a large tool result) between two normal records crosses several read chunks.
        try Fixture.write([
            Fixture.assistant(id: "m1", session: "S1", at: t0, output: 10),
            Fixture.assistant(id: "mbig", session: "S1", at: t0 + 1000, output: 500, padding: 9 << 20),
            Fixture.assistant(id: "m2", session: "S1", at: t0 + 2000, output: 20),
        ], to: f)
        try env.syncAll()
        XCTAssertEqual(try env.totals().requests, 3)
        XCTAssertEqual(try env.totals().tokens.output, 530)
    }

    func testEscapedCharactersInPathsAndStringsAreDecoded() throws {
        let env = try TestEnv()
        let cwd = "/Users/test/with \\\"quote\\\" and \\u00e9"
        let line = Fixture.assistant(id: "m1", session: "S1", at: t0, output: 1).replacingOccurrences(of: "/Users/test/alpha", with: cwd)
        try Fixture.write([line], to: try env.mainFile(session: "S1"))
        try env.syncAll()
        let stored = try env.db.read { try $0.queryOne("SELECT cwd FROM session") { $0.text(0) } }
        XCTAssertEqual(stored, "/Users/test/with \"quote\" and é")
    }

    func testSourceCostReportIsStoredSeparatelyFromEstimates() throws {
        let env = try TestEnv()
        try Fixture.write([
            Fixture.assistant(id: "m1", session: "S1", at: t0, input: 1000, output: 1000),
            Fixture.costState(session: "S1", totalUSD: 0.0123, models: ["claude-opus-5-5": (1000, 1000, 0, 0, 0.0123)]),
        ], to: try env.mainFile(session: "S1"))
        try env.syncAll()
        let row = try AnalyticsEngine(db: env.db).sessionRows().first!
        XCTAssertEqual(row.reportedCostUSD!, 0.0123, accuracy: 1e-9)
        // The expected cost is 1000 input tokens at $4 per million plus 1000 output tokens at $20 per million.
        XCTAssertEqual(row.cost.picoUSD, 1000 * 4_000_000 + 1000 * 20_000_000)
    }

    func testRetentionFloorDropsOldObservationsOnImport() throws {
        let env = try TestEnv()
        try Fixture.write([
            Fixture.assistant(id: "old", session: "S1", at: t0, output: 10),
            Fixture.assistant(id: "new", session: "S1", at: t0 + 10 * 86_400_000, output: 20),
        ], to: try env.mainFile(session: "S1"))
        let sync = FileSynchronizer(db: env.db, retentionFloorMs: { t0 + 5 * 86_400_000 })
        _ = try env.adapter.discoverFiles().map { try sync.sync(file: $0, adapter: env.adapter) }
        XCTAssertEqual(try env.totals().tokens.output, 20)
    }
}
