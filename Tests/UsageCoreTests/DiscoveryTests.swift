import XCTest
@testable import UsageCore

final class AdapterPathTests: XCTestCase {
    func testMainAndSubAgentPathsAreRecognized() throws {
        let env = try TestEnv()
        let a = env.adapter
        let main = a.fileRef(forPath: env.projects.path + "/-Users-test-alpha/3f2a.jsonl")
        XCTAssertEqual(main?.projectKey, "-Users-test-alpha")
        XCTAssertEqual(main?.sessionHint, "3f2a")
        XCTAssertNil(main?.agentHint)
        let sub = a.fileRef(forPath: env.projects.path + "/-Users-test-alpha/3f2a/subagents/agent-ab12.jsonl")
        XCTAssertEqual(sub?.sessionHint, "3f2a")
        XCTAssertEqual(sub?.agentHint, "ab12")
        XCTAssertNil(a.fileRef(forPath: env.projects.path + "/-Users-test-alpha/3f2a/tool-results/x.jsonl"))
        XCTAssertNil(a.fileRef(forPath: env.projects.path + "/-Users-test-alpha/memory/notes.md"))
        XCTAssertNil(a.fileRef(forPath: "/elsewhere/x.jsonl"))
    }

    func testDiscoveryFindsEveryFileLayout() throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.user(session: "S1", at: t0)], to: try env.mainFile(session: "S1"))
        try Fixture.write([Fixture.user(session: "S1", at: t0)], to: try env.subagentFile(session: "S1", agent: "A"))
        try Fixture.write([Fixture.user(session: "S2", at: t0)], to: try env.mainFile(cwd: "/Users/test/beta", session: "S2"))
        try "notes".write(to: try env.projectDir("/Users/test/alpha").appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try env.adapter.discoverFiles().count, 3)
    }

    func testProjectKeyEncodingMatchesClaudeCodeFolderNames() {
        XCTAssertEqual(ClaudeCodeAdapter.encodeProjectKey("/Users/safayildirim/Desktop/repos/claude-usage-tracker"),
                       "-Users-safayildirim-Desktop-repos-claude-usage-tracker")
        XCTAssertEqual(ClaudeCodeAdapter.encodeProjectKey("/Users/a b/c.d_e"), "-Users-a-b-c-d-e")
    }
}

final class SessionDiscoveryTests: XCTestCase {
    func testConcurrentSessionsAreTrackedIndependently() throws {
        let env = try TestEnv()
        try Fixture.write([
            Fixture.assistant(id: "a1", session: "SA", at: t0, output: 10, cwd: "/Users/test/alpha"),
            Fixture.assistant(id: "a2", session: "SA", at: t0 + 2000, output: 20, cwd: "/Users/test/alpha"),
        ], to: try env.mainFile(session: "SA"))
        try Fixture.write([
            Fixture.assistant(id: "b1", session: "SB", at: t0 + 1000, output: 5, cwd: "/Users/test/beta", entrypoint: "claude-vscode"),
            Fixture.assistant(id: "b2", session: "SB", at: t0 + 3000, output: 7, cwd: "/Users/test/beta", entrypoint: "claude-vscode"),
        ], to: try env.mainFile(cwd: "/Users/test/beta", session: "SB"))
        try env.syncAll()

        let rows = try AnalyticsEngine(db: env.db).sessionRows()
        XCTAssertEqual(rows.count, 2)
        let a = rows.first { $0.externalID == "SA" }!, b = rows.first { $0.externalID == "SB" }!
        XCTAssertEqual(a.tokens.output, 30)
        XCTAssertEqual(b.tokens.output, 12)
        XCTAssertEqual(a.projectName, "alpha")
        XCTAssertEqual(b.projectName, "beta")
        XCTAssertEqual(a.surface, .terminal)
        XCTAssertEqual(b.surface, .vscode)
        XCTAssertEqual(a.startedAt, Clock.date(ms: t0))
        XCTAssertEqual(b.lastActivityAt, Clock.date(ms: t0 + 3000))
    }

    func testResumedSessionContinuesTheSameSession() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 10)], to: f)
        try env.syncAll()
        let firstID = try AnalyticsEngine(db: env.db).sessionRows().first!.id

        // Days later the user resumes the conversation; Claude Code appends to the same file.
        let later = t0 + 3 * 86_400_000
        try Fixture.append([Fixture.user(session: "S1", at: later),
                            Fixture.assistant(id: "m2", session: "S1", at: later + 500, output: 40)], to: f)
        try env.syncAll()

        let rows = try AnalyticsEngine(db: env.db).sessionRows()
        XCTAssertEqual(rows.count, 1, "a resumed session must not become a duplicate")
        XCTAssertEqual(rows[0].id, firstID)
        XCTAssertEqual(rows[0].tokens.output, 50)
        XCTAssertEqual(rows[0].startedAt, Clock.date(ms: t0))
        XCTAssertEqual(rows[0].lastActivityAt, Clock.date(ms: later + 500))
    }

    func testSessionIdentityAndTotalsSurviveRestart() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 10, cacheRead: 100)], to: f)
        try env.syncAll()
        let before = try AnalyticsEngine(db: env.db).sessionRows()

        try env.reopen()
        let result = try env.syncAll()
        XCTAssertEqual(result.first?.outcome, .unchanged, "the checkpoint survives the restart, so nothing is re-read")
        XCTAssertEqual(try AnalyticsEngine(db: env.db).sessionRows().map(\.id), before.map(\.id))
        XCTAssertEqual(try env.totals().tokens.output, 10)

        try Fixture.append([Fixture.assistant(id: "m2", session: "S1", at: t0 + 1000, output: 5)], to: f)
        try env.reopen()
        try env.syncAll()
        XCTAssertEqual(try env.totals().tokens.output, 15)
        XCTAssertEqual(try env.totals().sessions, 1)
    }

    func testImportingTwiceIsIdempotent() throws {
        let env = try TestEnv()
        for i in 0..<5 {
            try Fixture.write((0..<20).map { Fixture.assistant(id: "m\(i)-\($0)", session: "S\(i)", at: t0 + Int64($0) * 1000, output: $0 + 1, cacheRead: 50) },
                              to: try env.mainFile(session: "S\(i)"))
        }
        try env.syncAll()
        let first = try env.totals()
        // Force a complete re-read by discarding the checkpoints.
        try env.db.write { try $0.run("DELETE FROM source_file") }
        try env.syncAll()
        let second = try env.totals()
        XCTAssertEqual(first.tokens, second.tokens)
        XCTAssertEqual(first.requests, second.requests)
        XCTAssertEqual(first.requests, 100)
        XCTAssertEqual(first.sessions, 5)
    }

    func testReplacedFileIsReadAgainWithoutDoubleCounting() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 10),
                           Fixture.assistant(id: "m2", session: "S1", at: t0 + 1000, output: 20)], to: f)
        try env.syncAll()

        // Log rotation: the file is replaced by a new file (new inode) holding the same history plus more.
        try FileManager.default.removeItem(at: f)
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 10),
                           Fixture.assistant(id: "m2", session: "S1", at: t0 + 1000, output: 20),
                           Fixture.assistant(id: "m3", session: "S1", at: t0 + 2000, output: 30)], to: f)
        let result = try env.syncAll()
        XCTAssertEqual(result.first?.outcome, .rebuilt)
        XCTAssertEqual(try env.totals().tokens.output, 60)
        XCTAssertEqual(try env.totals().requests, 3)
    }

    func testTruncatedFileKeepsCollectedHistoryAndIsReadAgain() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        let lines = (0..<4).map { Fixture.assistant(id: "m\($0)", session: "S1", at: t0 + Int64($0) * 1000, output: 10) }
        try Fixture.write(lines, to: f)
        try env.syncAll()
        XCTAssertEqual(try env.totals().requests, 4)

        // The file is truncated to its first record, then grows again with a new record.
        try Fixture.write([lines[0]], to: f)
        var result = try env.syncAll()
        XCTAssertEqual(result.first?.outcome, .rebuilt)
        XCTAssertEqual(try env.totals().requests, 4, "history that was already collected is kept")
        XCTAssertEqual(try env.totals().tokens.output, 40, "and nothing is counted twice")

        try Fixture.append([Fixture.assistant(id: "m9", session: "S1", at: t0 + 9000, output: 7)], to: f)
        result = try env.syncAll()
        XCTAssertEqual(try env.totals().tokens.output, 47)
    }

    func testFileRewrittenInPlaceIsDetectedByItsHeader() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 10)], to: f)
        try env.syncAll()
        // Same inode, same size or larger, but different leading bytes.
        let handle = try FileHandle(forWritingTo: f)
        try handle.write(contentsOf: Data((Fixture.assistant(id: "m7", session: "S1", at: t0 + 5000, output: 99) + "\n"
            + Fixture.assistant(id: "m8", session: "S1", at: t0 + 6000, output: 1) + "\n").utf8))
        try handle.close()
        let result = try env.syncAll()
        XCTAssertEqual(result.first?.outcome, .rebuilt)
        XCTAssertEqual(try env.totals().tokens.output, 110)
    }

    func testMissingFileKeepsItsData() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 10)], to: f)
        try env.syncAll()
        try FileManager.default.removeItem(at: env.projects)
        let ref = SourceFileRef(sourceID: "claude-code", path: f.path, projectKey: "k", sessionHint: "S1")
        let result = try env.synchronizer.sync(file: ref, adapter: env.adapter)
        XCTAssertEqual(result.outcome, .missing)
        XCTAssertEqual(try env.totals().tokens.output, 10, "deleting or moving a project folder must not erase its history")
    }

    func testUnreadableFileReportsPermissionError() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 10)], to: f)
        chmod(f.path, 0o000)
        defer { chmod(f.path, 0o600) }
        let ref = try XCTUnwrap(env.adapter.discoverFiles().first)
        XCTAssertThrowsError(try env.synchronizer.sync(file: ref, adapter: env.adapter)) { error in
            XCTAssertTrue((error as? FileAccessError)?.isPermissionDenied == true)
        }
    }

    func testSessionWithoutExplicitIdFallsBackToFileName() throws {
        let env = try TestEnv()
        // A record without a sessionId (older format) is attributed to the session named by its file.
        let line = Fixture.assistant(id: "m1", session: "IGNORED", at: t0, output: 10)
            .replacingOccurrences(of: ",\"sessionId\":\"IGNORED\"", with: "")
        try Fixture.write([line], to: try env.mainFile(session: "file-session"))
        try env.syncAll()
        XCTAssertEqual(try AnalyticsEngine(db: env.db).sessionRows().first?.externalID, "file-session")
    }
}

final class CollectorLifecycleTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("condition not met within \(timeout)s")
    }

    func testHistoricalImportThenLiveUpdatesAreDetectedAutomatically() async throws {
        let env = try TestEnv()
        let existing = try env.mainFile(session: "OLD")
        try Fixture.write([Fixture.assistant(id: "old1", session: "OLD", at: t0, output: 11)], to: existing)

        let collector = UsageCollector(db: env.db, adapters: [env.adapter], reconcileInterval: 3600)
        await collector.start()
        // 1. Existing history is imported at launch without the user registering anything.
        try await waitUntil { try env.totals().tokens.output == 11 }

        // 2. A brand new session is discovered live from a file event.
        let live = try env.mainFile(cwd: "/Users/test/gamma", session: "LIVE")
        try Fixture.write([Fixture.assistant(id: "live1", session: "LIVE", at: t0 + 5000, output: 22)], to: live)
        try await waitUntil { try env.totals().tokens.output == 33 }

        // 3. New lines appended to an existing session are picked up incrementally.
        try Fixture.append([Fixture.assistant(id: "live2", session: "LIVE", at: t0 + 6000, output: 4)], to: live)
        try await waitUntil { try env.totals().tokens.output == 37 }
        XCTAssertEqual(try env.totals().sessions, 2)
        try await waitUntil { await collector.snapshot().lastLatencyMs != nil }
        let latency = await collector.snapshot().lastLatencyMs ?? .max
        XCTAssertLessThan(latency, 5000, "live changes should be ingested within seconds")
        await collector.stop()
    }

    func testReconciliationRecoversChangesWhoseEventsWereMissed() async throws {
        let env = try TestEnv()
        // A watcher that never fires models lost events (sleep, kernel overflow, a crash).
        let quietFolder = env.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: quietFolder, withIntermediateDirectories: true)
        let deaf = DeafAdapter(base: env.adapter, watchRoot: quietFolder)
        let collector = UsageCollector(db: env.db, adapters: [deaf], reconcileInterval: 3600)
        await collector.start()
        // Let any start-up event for the new watch folder settle before the file is written.
        try await Task.sleep(for: .milliseconds(2000))
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 12)], to: try env.mainFile(session: "S1"))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(try env.totals().tokens.output, 0, "no event was delivered, so nothing is imported yet")

        await collector.systemDidWake()
        try await waitUntil { try env.totals().tokens.output == 12 }
        await collector.stop()
    }

    func testOneFailingSourceDoesNotStopAnother() async throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 8)], to: try env.mainFile(session: "S1"))
        let collector = UsageCollector(db: env.db, adapters: [BrokenAdapter(), env.adapter], reconcileInterval: 3600)
        await collector.start()
        try await waitUntil { try env.totals().tokens.output == 8 }
        let snap = await collector.snapshot()
        let broken = snap.sources.first { $0.sourceID.rawValue == "broken" }
        XCTAssertNotNil(broken?.lastError)
        XCTAssertEqual(snap.sources.first { $0.sourceID == .claudeTranscripts }?.state, .ok)
        await collector.stop()
    }

    func testMissingDataFolderIsReportedAsNotInstalled() async throws {
        let env = try TestEnv()
        let adapter = ClaudeCodeAdapter(root: env.root.appendingPathComponent("no-such-dir"))
        let collector = UsageCollector(db: env.db, adapters: [adapter], reconcileInterval: 3600)
        await collector.start()
        try await waitUntil { await collector.snapshot().sources.first?.state == .notFound }
        await collector.stop()
    }

    func testUnreadableFileMarksSourceDegradedButOthersAreImported() async throws {
        let env = try TestEnv()
        let bad = try env.mainFile(session: "BAD")
        try Fixture.write([Fixture.assistant(id: "b1", session: "BAD", at: t0, output: 1)], to: bad)
        chmod(bad.path, 0o000)
        defer { chmod(bad.path, 0o600) }
        try Fixture.write([Fixture.assistant(id: "g1", session: "GOOD", at: t0, output: 9)], to: try env.mainFile(session: "GOOD"))
        let collector = UsageCollector(db: env.db, adapters: [env.adapter], reconcileInterval: 3600)
        await collector.start()
        try await waitUntil { try env.totals().tokens.output == 9 }
        try await waitUntil { await collector.snapshot().sources.first?.state == .degraded }
        let error = await collector.snapshot().sources.first?.lastError ?? ""
        XCTAssertTrue(error.contains("denied access"), error)
        await collector.stop()
    }

    func testRebuildFromSourceReproducesTheSameTotals() async throws {
        let env = try TestEnv()
        for i in 0..<3 {
            try Fixture.write((0..<10).map { Fixture.assistant(id: "m\(i)-\($0)", session: "S\(i)", at: t0 + Int64($0) * 1000, output: 3, cacheRead: 40) },
                              to: try env.mainFile(session: "S\(i)"))
        }
        let collector = UsageCollector(db: env.db, adapters: [env.adapter], reconcileInterval: 3600)
        await collector.start()
        try await waitUntil { try env.totals().requests == 30 }
        let before = try env.totals().tokens
        await collector.rebuildFromSource()
        try await Task.sleep(for: .milliseconds(300))
        try await waitUntil { try env.totals().requests == 30 }
        XCTAssertEqual(try env.totals().tokens, before)
        await collector.stop()
    }
}

/// An adapter whose file watcher watches a folder where nothing ever changes.
private struct DeafAdapter: SourceAdapter {
    let base: ClaudeCodeAdapter
    let watchRoot: URL
    var sourceID: TelemetrySourceID { base.sourceID }
    var displayName: String { base.displayName }
    var watchRoots: [URL] { [watchRoot] }
    var coverageNote: String { "" }
    func discoverFiles() throws -> [SourceFileRef] { try base.discoverFiles() }
    func fileRef(forPath path: String) -> SourceFileRef? { base.fileRef(forPath: path) }
    func makeParser(for file: SourceFileRef) -> any LineParser { base.makeParser(for: file) }
}

private struct BrokenAdapter: SourceAdapter {
    var sourceID: TelemetrySourceID { TelemetrySourceID(rawValue: "broken") }
    var displayName: String { "Broken" }
    var watchRoots: [URL] { [FileManager.default.temporaryDirectory] }
    var coverageNote: String { "" }
    struct Boom: Error, CustomStringConvertible { var description: String { "adapter exploded" } }
    func discoverFiles() throws -> [SourceFileRef] { throw Boom() }
    func fileRef(forPath path: String) -> SourceFileRef? { nil }
    func makeParser(for file: SourceFileRef) -> any LineParser { fatalError("unused") }
}
