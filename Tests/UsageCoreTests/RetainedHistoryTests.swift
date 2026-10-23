import XCTest
@testable import UsageCore

/// Claude Code deletes old transcripts, and the database then holds the only copy of their usage. These tests follow
/// that history through every path that can rebuild, erase or recover the database, and check that it is never lost
/// without the loss being disclosed and a copy being kept.
final class RetainedHistoryTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("condition not met within \(timeout)s")
    }

    private func requestCount(_ db: UsageDatabase) throws -> Int64 {
        try db.read { try $0.scalarInt("SELECT count(*) FROM model_request") } ?? 0
    }

    /// Two sessions are imported: one keeps its transcript (two requests) and one has its transcript deleted later
    /// (three requests).
    private func importTwoSessions(_ env: TestEnv) throws -> (kept: URL, deleted: URL) {
        let kept = try env.mainFile(session: "KEPT")
        let deleted = try env.mainFile(session: "GONE")
        try Fixture.write((0..<2).map { Fixture.assistant(id: "k\($0)", session: "KEPT", at: t0 + Int64($0) * 1000, output: 10) }, to: kept)
        try Fixture.write((0..<3).map { Fixture.assistant(id: "g\($0)", session: "GONE", at: t0 + Int64($0) * 1000, output: 100) }, to: deleted)
        _ = try env.syncAll()
        return (kept, deleted)
    }

    func testDeletedTranscriptHistorySurvivesReconcileAndRestartAndIsCopiedBeforeARebuild() async throws {
        let env = try TestEnv()
        let files = try importTwoSessions(env)
        XCTAssertEqual(try requestCount(env.db), 5)
        try FileManager.default.removeItem(at: files.deleted)

        // Reconciliation notices that the file is gone and keeps its requests.
        let collector = UsageCollector(db: env.db, adapters: [env.adapter], reconcileInterval: 3600)
        await collector.start()
        await collector.reconcileNow(reason: "test")
        try await waitUntil {
            try env.db.read { try $0.scalarInt("SELECT count(*) FROM source_file WHERE status = 'missing'") } == 1
        }
        XCTAssertEqual(try requestCount(env.db), 5, "a vanished file must not take its requests with it")
        await collector.stop()

        // A restart keeps them too, and the history that only the database holds is counted for the warning.
        try env.reopen()
        XCTAssertEqual(try requestCount(env.db), 5)
        XCTAssertEqual(try env.db.retainedOnlyHistory(), UsageDatabase.RetainedHistory(files: 1, requests: 3))
        XCTAssertEqual(try env.totals().tokens.output, 320)

        // A rebuild writes a complete copy first, then imports only what still exists.
        let restarted = UsageCollector(db: env.db, adapters: [env.adapter], reconcileInterval: 3600)
        await restarted.start()
        await restarted.rebuildFromSource()
        try await waitUntil { try env.db.backups().count == 1 && self.requestCount(env.db) == 2 }
        await restarted.stop()
        XCTAssertEqual(try env.totals().tokens.output, 20, "the rebuild reproduces exactly what the remaining files contain")
        XCTAssertEqual(try env.db.retainedOnlyHistory(), UsageDatabase.RetainedHistory(files: 0, requests: 0))

        // The copy is a complete, self-contained database that still holds all five requests.
        let backup = try XCTUnwrap(env.db.backups().first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-wal"), "the copy must not depend on a write-ahead log")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let copy = try SQLiteConnection(path: backup.path, readOnly: true)
        XCTAssertEqual(try copy.scalarInt("SELECT count(*) FROM model_request"), 5)
        XCTAssertEqual(try copy.scalarInt("SELECT sum(output_tokens) FROM model_request"), 320)
        XCTAssertEqual(try copy.queryOne("PRAGMA integrity_check") { $0.text(0) }, "ok")
    }

    func testOnlyTheNewestBackupsAreKeptInAPrivateFolder() throws {
        let env = try TestEnv()
        _ = try importTwoSessions(env)
        var made: [URL] = []
        for _ in 0..<(UsageDatabase.backupsKept + 2) { made.append(try env.db.backUpBeforeRebuild()) }
        XCTAssertEqual(env.db.backups(), Array(made.suffix(UsageDatabase.backupsKept).reversed()), "the newest copies are kept, newest first")
        for old in made.prefix(2) { XCTAssertFalse(FileManager.default.fileExists(atPath: old.path)) }
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: env.db.backupDirectory.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o700)
    }

    /// Erasing is a request to remove the data, so it must not leave a copy behind, even though the rebuild that
    /// follows it uses the same path as a user-initiated rebuild.
    func testErasingAllDataLeavesNoCopy() async throws {
        let env = try TestEnv()
        _ = try importTwoSessions(env)
        let collector = UsageCollector(db: env.db, adapters: [env.adapter], reconcileInterval: 3600)
        await collector.start()
        try await waitUntil { try self.requestCount(env.db) == 5 }
        // This is what the app does: the erase, then a rebuild that must not copy what a file event re-imported.
        try env.db.eraseAllData()
        await collector.rebuildFromSource(keepingCopy: false)
        await collector.reconcileNow(reason: "test")
        try await waitUntil { try self.requestCount(env.db) == 5 }
        await collector.stop()
        XCTAssertEqual(env.db.backups(), [])
    }

    /// A database that cannot be opened is moved aside, never deleted, because it may hold the only copy of usage whose
    /// transcripts are gone. The new database is marked as recovered so that the app can say where the old one is.
    func testCorruptionRecoveryKeepsTheDamagedFileWithItsHistory() throws {
        let env = try TestEnv()
        let files = try importTwoSessions(env)
        try FileManager.default.removeItem(at: files.deleted)
        env.db.markCleanShutdown()
        // The write-ahead log can hold its own copy of the first page, which would repair the damage below, so the
        // log is folded into the main file first, as it is when the app closes the database.
        env.db = try UsageDatabase.open(at: env.root.appendingPathComponent("other/usage.sqlite"))
        let checkpoint = try SQLiteConnection(path: env.dbURL.path)
        _ = try checkpoint.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in 0 }
        try checkpoint.exec("PRAGMA journal_mode = DELETE")

        var bytes = try Data(contentsOf: env.dbURL)
        let header = bytes.prefix(16)
        bytes.replaceSubrange(0..<16, with: Data(repeating: 0x58, count: 16))
        try bytes.write(to: env.dbURL)

        let recovered = try UsageDatabase.open(at: env.dbURL)
        XCTAssertTrue(recovered.openReport.recoveredFromCorruption)
        XCTAssertEqual(try requestCount(recovered), 0)
        let aside = try XCTUnwrap(recovered.openReport.quarantinedTo)
        var kept = try Data(contentsOf: aside)
        XCTAssertEqual(kept, bytes, "the damaged file is kept exactly as it was found")

        // Repairing the damaged header shows that the moved file still holds every request, including the three
        // whose transcript no longer exists.
        kept.replaceSubrange(0..<16, with: header)
        let repaired = env.root.appendingPathComponent("repaired.sqlite")
        try kept.write(to: repaired)
        let old = try SQLiteConnection(path: repaired.path, readOnly: true)
        XCTAssertEqual(try old.scalarInt("SELECT count(*) FROM model_request"), 5)
    }
}
