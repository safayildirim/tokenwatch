import XCTest
import SQLite3
@testable import UsageCore

final class PersistenceTests: XCTestCase {
    func testSchemaIsMigratedAndPragmasAreApplied() throws {
        let env = try TestEnv()
        XCTAssertEqual(try env.db.read { try $0.scalarInt("PRAGMA user_version") }, Int64(Schema.latestVersion))
        XCTAssertEqual(try env.db.read { try $0.queryOne("PRAGMA journal_mode") { $0.text(0) } }, "wal")
        XCTAssertEqual(try env.db.integrityCheck(), ["ok"])
        XCTAssertEqual(try env.db.foreignKeyViolations(), 0)
        // Reopening does not re-run migrations.
        try env.reopen()
        XCTAssertEqual(env.db.openReport.migratedFrom, Schema.latestVersion)
    }

    func testForeignKeysAreEnforced() throws {
        let env = try TestEnv()
        XCTAssertThrowsError(try env.db.write { c in
            try c.run("INSERT INTO usage_source(id, display_name) VALUES('s','s')")
            try c.run("""
                INSERT INTO model_request(source_id, request_key, session_id, model_id, requested_at, input_tokens,
                    output_tokens, cache_read_tokens, cache_creation_tokens, first_ingested_at)
                VALUES('s', 'k', 9999, 'nope', 1, 1, 1, 1, 1, 1)
                """)
        })
        // The failed statement rolled back the whole transaction, including the source row.
        XCTAssertEqual(try env.db.read { try $0.scalarInt("SELECT count(*) FROM usage_source") }, 0)
    }

    func testRequestIdentityIsUnique() throws {
        let env = try TestEnv()
        try env.db.write { c in
            try c.run("INSERT INTO usage_source(id, display_name) VALUES('s','s')")
            try c.run("INSERT INTO session(source_id, external_id) VALUES('s','x')")
            try c.run("INSERT INTO model(id, canonical, family, display_name) VALUES('m','m','other','m')")
        }
        func insert() throws {
            try env.db.write { c in
                try c.run("""
                    INSERT INTO model_request(source_id, request_key, session_id, model_id, requested_at, input_tokens,
                        output_tokens, cache_read_tokens, cache_creation_tokens, first_ingested_at)
                    VALUES('s', 'dup', 1, 'm', 1, 1, 1, 1, 1, 1)
                    """)
            }
        }
        try insert()
        XCTAssertThrowsError(try insert())
    }

    func testStrictTablesRejectWrongTypes() throws {
        let env = try TestEnv()
        XCTAssertThrowsError(try env.db.write { c in
            try c.run("INSERT INTO setting(key, value, updated_at) VALUES('k', 'v', 'not-a-number')")
        })
    }

    func testTransactionRollsBackEverythingOnFailure() throws {
        let env = try TestEnv()
        var batch = NormalizedBatch()
        let session = SessionObservation(sourceID: "claude-code", externalID: "S", projectKey: "-p", cwd: nil, application: nil,
                                         clientVersion: nil, firstSeenMs: t0, lastSeenMs: t0, versionSeenMs: 0)
        batch.add(session)
        batch.add(RequestObservation(sourceID: "claude-code", requestKey: "m1", sessionExternalID: "S", modelID: "claude-opus-5-5",
                                     requestedAtMs: t0, uncachedInput: 1, output: 1, cacheRead: 0, cacheCreation: 0))
        // The checkpoint references a file row that does not exist, which is allowed (UPDATE affects zero rows)...
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: env.db)
        // ...so force a failure inside the transaction instead.
        struct Boom: Error {}
        XCTAssertThrowsError(try env.db.write { c in
            try c.run("DELETE FROM model_request")
            throw Boom()
        })
        XCTAssertEqual(try env.totals().requests, 1, "the aborted delete must not have been applied")
    }

    func testObservationsAndCheckpointCommitTogether() throws {
        let env = try TestEnv()
        let f = try env.mainFile(session: "S1")
        try Fixture.write((0..<50).map { Fixture.assistant(id: "m\($0)", session: "S1", at: t0 + Int64($0), output: 1) }, to: f)
        try env.syncAll()
        let (requests, offset, size): (Int64, Int64, Int64) = try env.db.read { c in
            (try c.scalarInt("SELECT count(*) FROM model_request")!,
             try c.scalarInt("SELECT consumed_offset FROM source_file")!,
             try c.scalarInt("SELECT size FROM source_file")!)
        }
        XCTAssertEqual(requests, 50)
        XCTAssertEqual(offset, size, "the checkpoint covers exactly the data that was committed")
        XCTAssertEqual(offset, Int64(try Data(contentsOf: f).count))
    }

    func testReadersAndWriterRunConcurrentlyWithoutErrors() throws {
        let env = try TestEnv()
        let db = env.db
        let stop = ManagedAtomicFlag()
        let readerErrors = ManagedCounter()
        let monotonicViolations = ManagedCounter()

        let readers = (0..<3).map { _ in
            Thread {
                var last: Int64 = 0
                while !stop.isSet {
                    do {
                        let n = try db.read { try $0.scalarInt("SELECT count(*) FROM model_request") ?? 0 }
                        if n < last { monotonicViolations.increment() }
                        last = n
                    } catch { readerErrors.increment() }
                }
            }
        }
        readers.forEach { $0.start() }

        // The writer commits many small batches.
        for batchIndex in 0..<60 {
            var batch = NormalizedBatch()
            batch.add(SessionObservation(sourceID: "claude-code", externalID: "S", projectKey: "-p", cwd: nil, application: nil,
                                         clientVersion: nil, firstSeenMs: t0, lastSeenMs: t0, versionSeenMs: 0))
            for i in 0..<40 {
                batch.add(RequestObservation(sourceID: "claude-code", requestKey: "m\(batchIndex)-\(i)", sessionExternalID: "S",
                                             modelID: "claude-opus-5-5", requestedAtMs: t0 + Int64(i), uncachedInput: 1, output: 1,
                                             cacheRead: 0, cacheCreation: 0))
            }
            _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: db)
        }
        stop.set()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(readerErrors.value, 0, "readers must never be blocked or fail while the writer commits")
        XCTAssertEqual(monotonicViolations.value, 0, "readers see consistent, never-shrinking snapshots")
        XCTAssertEqual(try env.totals().requests, 2400)
    }

    func testCorruptDatabaseIsQuarantinedAndReplaced() throws {
        let env = try TestEnv()
        env.db.markCleanShutdown()
        let url = env.dbURL
        // Overwrite the database file with garbage while no connection is open for it.
        let path = url.path
        env.db = try UsageDatabase.open(at: url.deletingLastPathComponent().appendingPathComponent("other.sqlite"))
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        try Data(repeating: 0x41, count: 8192).write(to: url)

        let recovered = try UsageDatabase.open(at: url)
        XCTAssertTrue(recovered.openReport.recoveredFromCorruption)
        let aside = try XCTUnwrap(recovered.openReport.quarantinedTo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path), "the damaged file is kept for inspection")
        XCTAssertEqual(try recovered.integrityCheck(), ["ok"])
        // The fresh database works and can be repopulated from the source logs.
        let f = try env.mainFile(session: "S1")
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 5)], to: f)
        _ = try FileSynchronizer(db: recovered).sync(file: try XCTUnwrap(env.adapter.discoverFiles().first), adapter: env.adapter)
        XCTAssertEqual(try AnalyticsEngine(db: recovered).totals().tokens.output, 5)
    }

    func testUncleanShutdownTriggersIntegrityCheck() throws {
        let env = try TestEnv()
        // The first launch ends without markCleanShutdown().
        let again = try UsageDatabase.open(at: env.dbURL)
        XCTAssertTrue(again.openReport.integrityCheckRan)
        again.markCleanShutdown()
        let third = try UsageDatabase.open(at: env.dbURL)
        XCTAssertFalse(third.openReport.integrityCheckRan, "a clean shutdown skips the slow check")
    }

    func testSettingsPersistAndAreClamped() throws {
        let env = try TestEnv()
        let store = SettingsStore(db: env.db)
        store.update {
            $0.quotaRefreshSeconds = 1          // below the safe minimum
            $0.retentionDays = -5
            $0.notifications.fiveHourThresholds = [90, 50, 50, 150]
            $0.menuBarMode = .fiveHour
        }
        XCTAssertEqual(store.value.quotaRefreshSeconds, 30)
        XCTAssertEqual(store.value.retentionDays, 0)
        XCTAssertEqual(store.value.notifications.fiveHourThresholds, [50, 90, 100])
        try env.reopen()
        let reloaded = SettingsStore(db: env.db)
        XCTAssertEqual(reloaded.value.menuBarMode, .fiveHour)
        XCTAssertEqual(reloaded.value.quotaRefreshSeconds, 30)
    }

    func testPurgeRemovesOldDataAndOrphans() throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.assistant(id: "old", session: "OLD", at: t0, output: 1)], to: try env.mainFile(cwd: "/Users/test/old", session: "OLD"))
        try Fixture.write([Fixture.assistant(id: "new", session: "NEW", at: t0 + 20 * 86_400_000, output: 2)], to: try env.mainFile(cwd: "/Users/test/new", session: "NEW"))
        try env.syncAll()
        XCTAssertEqual(try env.db.purge(olderThanMs: t0 + 10 * 86_400_000), 1)
        let t = try env.totals()
        XCTAssertEqual(t.requests, 1)
        XCTAssertEqual(try env.db.read { try $0.scalarInt("SELECT count(*) FROM session") }, 1)
        XCTAssertEqual(try env.db.read { try $0.scalarInt("SELECT count(*) FROM project") }, 1)
    }

    func testEraseAllDataEmptiesEverythingButKeepsTheSchema() throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.assistant(id: "m", session: "S", at: t0, output: 1)], to: try env.mainFile(session: "S"))
        try env.syncAll()
        try env.db.eraseAllData()
        XCTAssertEqual(try env.totals().requests, 0)
        XCTAssertEqual(try env.db.read { try $0.scalarInt("SELECT count(*) FROM price_rate") ?? 0 } > 0, true, "price cards are not user data")
    }

    func testMergeRulesInSQLAgreeWithTheInMemoryMerge() throws {
        // The same observations, delivered in arbitrary orders and repeatedly, converge to what the
        // in-memory merge computes.
        var rng = SystemRandomNumberGenerator()
        for round in 0..<25 {
            let env = try TestEnv()
            let observations = (0..<6).map { i in
                RequestObservation(sourceID: "claude-code", requestKey: "m", apiRequestID: [nil, "req_a", "req_b"].randomElement(using: &rng)!,
                                   sessionExternalID: "S", agentExternalID: [nil, "A", "B"].randomElement(using: &rng)!,
                                   modelID: "claude-opus-5-5", requestedAtMs: t0 + Int64.random(in: 0...50_000, using: &rng),
                                   uncachedInput: Int64.random(in: 0...5, using: &rng), output: Int64.random(in: 0...1000, using: &rng),
                                   cacheRead: Int64.random(in: 0...90_000, using: &rng), cacheCreation: Int64.random(in: 0...500, using: &rng),
                                   cacheCreation5m: [nil, 0, 100].randomElement(using: &rng)!, cacheCreation1h: [nil, 0, 50].randomElement(using: &rng)!,
                                   speed: [nil, "standard"].randomElement(using: &rng)!, stopReason: [nil, "end_turn"].randomElement(using: &rng)!)
                    .self
            }
            let expected = observations.dropFirst().reduce(observations[0]) { $0.merged(with: $1) }
            let session = SessionObservation(sourceID: "claude-code", externalID: "S", projectKey: "-p", cwd: nil, application: nil,
                                             clientVersion: nil, firstSeenMs: t0, lastSeenMs: t0, versionSeenMs: 0)
            // Deliver each observation in its own batch, in random order, some twice.
            for o in (observations + observations.prefix(3)).shuffled() {
                var batch = NormalizedBatch()
                batch.add(session)
                batch.add(o)
                _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: env.db)
            }
            let stored = try env.db.read { c in
                try c.queryOne("""
                    SELECT input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cache_creation_5m_tokens,
                           cache_creation_1h_tokens, requested_at, agent_key, api_request_id, speed, stop_reason FROM model_request
                    """) { r in (r.int(0), r.int(1), r.int(2), r.int(3), r.intOrNil(4), r.intOrNil(5), r.int(6), r.textOrNil(7), r.textOrNil(8), r.textOrNil(9), r.textOrNil(10)) }
            }!
            XCTAssertEqual(stored.0, expected.uncachedInput, "round \(round)")
            XCTAssertEqual(stored.1, expected.output)
            XCTAssertEqual(stored.2, expected.cacheRead)
            XCTAssertEqual(stored.3, expected.cacheCreation)
            XCTAssertEqual(stored.4, expected.cacheCreation5m)
            XCTAssertEqual(stored.5, expected.cacheCreation1h)
            XCTAssertEqual(stored.6, expected.requestedAtMs)
            XCTAssertEqual(stored.7, expected.agentExternalID)
            XCTAssertEqual(stored.8, expected.apiRequestID)
            XCTAssertEqual(stored.9, expected.speed)
            XCTAssertEqual(stored.10, expected.stopReason)
        }
    }
}

final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
