import XCTest
@testable import UsageCore

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400
private let week: TimeInterval = 7 * day
private let friday = intelligenceFriday

final class QuotaObservationRecordTests: XCTestCase {
    private func snapshot(_ w: IntelligenceWorld) throws -> (confirmations: Int64?, gap: Int64?, first: Int64, last: Int64) {
        try XCTUnwrap(try w.db.read { c in
            try c.queryOne("SELECT confirmations, max_confirmation_gap_ms, observed_at, last_confirmed_at FROM quota_snapshot") {
                ($0.intOrNil(0), $0.intOrNil(1), $0.int(2), $0.int(3))
            }
        })
    }

    func testOnlyAConfirmationThatMovesTheSpanIsCountedAndARereadNeverIs() throws {
        let w = try IntelligenceWorld()
        let at = friday + hour
        try w.quota(7, at: at, resets: friday + week)
        try w.quota(7, at: at, resets: friday + week)
        try w.quota(7, at: at, resets: friday + week)
        var row = try snapshot(w)
        XCTAssertEqual(row.confirmations, 1, "reading the same file again is not a new observation")
        XCTAssertEqual(row.gap, 0)

        try w.quota(7, at: at + 2 * hour, resets: friday + week)
        try w.quota(7, at: at + 2 * hour, resets: friday + week)
        row = try snapshot(w)
        XCTAssertEqual(row.confirmations, 2)
        XCTAssertEqual(row.gap, Int64(2 * hour * 1000))

        try w.quota(7, at: at + 9 * hour, resets: friday + week)
        row = try snapshot(w)
        XCTAssertEqual(row.confirmations, 3)
        XCTAssertEqual(row.gap, Int64(7 * hour * 1000), "the longest pause between two confirmations is kept")

        try w.quota(7, at: at - 3 * hour, resets: friday + week)
        row = try snapshot(w)
        XCTAssertEqual(row.confirmations, 4, "an earlier confirmation extends the span at its start")
        XCTAssertEqual(row.first, Clock.ms(at - 3 * hour))
        XCTAssertEqual(row.gap, Int64(7 * hour * 1000))
    }

    func testADifferentValueIsAnotherSnapshotWithItsOwnCount() throws {
        let w = try IntelligenceWorld()
        try w.quota(7, at: friday + hour, resets: friday + week)
        try w.quota(8, at: friday + 2 * hour, resets: friday + week)
        let counts = try w.db.read { c in try c.query("SELECT utilization_pct, confirmations FROM quota_snapshot ORDER BY utilization_pct") { ($0.double(0), $0.intOrNil(1)) } }
        XCTAssertEqual(counts.map(\.0), [7, 8])
        XCTAssertEqual(counts.map { $0.1 ?? -1 }, [1, 1])
    }

    func testTheSchemaCarriesTheCoverageColumnsAndTheAssociationTable() throws {
        let w = try IntelligenceWorld()
        let columns = try w.db.read { c in try c.query("PRAGMA table_info(quota_snapshot)") { $0.text(1) } }
        XCTAssertTrue(columns.contains("confirmations") && columns.contains("max_confirmation_gap_ms"))
        XCTAssertEqual(try w.db.read { c in try c.scalarInt("SELECT count(*) FROM account_association") }, 0)
        XCTAssertEqual(Schema.latestVersion, 1)
    }
}

final class AccountAssociationStoreTests: XCTestCase {
    private func accounts(_ w: IntelligenceWorld) throws -> (unassigned: Int64, a: Int64, b: Int64) {
        try w.quota(1, at: friday, resets: friday + week, account: IntelligenceWorld.identified)
        try w.quota(1, at: friday, resets: friday + week, account: IntelligenceWorld.otherIdentified)
        try w.quota(1, at: friday, resets: friday + week)
        func id(_ hash: String) throws -> Int64 { try XCTUnwrap(try w.db.read { c in try c.scalarInt("SELECT id FROM account WHERE provider_id = 'anthropic' AND hash = ?", [.text(hash)]) }) }
        return (try id(""), try id(IntelligenceWorld.identified.hash!), try id(IntelligenceWorld.otherIdentified.hash!))
    }

    func testAnAssociationNamesAnIdentifiedAccountOfTheSameProviderOnly() throws {
        let w = try IntelligenceWorld()
        let ids = try accounts(w)
        XCTAssertThrowsError(try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: ids.unassigned, from: friday, to: nil)) {
            XCTAssertEqual($0 as? AccountAssociationError, .accountNeedsToBeIdentified)
        }
        XCTAssertThrowsError(try AccountAssociationStore.create(w.db, provider: .openAI, accountID: ids.a, from: friday, to: nil)) {
            XCTAssertEqual($0 as? AccountAssociationError, .accountBelongsToAnotherProvider)
        }
        XCTAssertThrowsError(try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: 9_999, from: friday, to: nil)) {
            XCTAssertEqual($0 as? AccountAssociationError, .unknownAccount)
        }
        XCTAssertThrowsError(try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: ids.a, from: friday, to: friday)) {
            XCTAssertEqual($0 as? AccountAssociationError, .endNotAfterStart)
        }
    }

    func testPeriodsNeverOverlapBecauseActivityBelongsToOneAccountAtATime() throws {
        let w = try IntelligenceWorld()
        let ids = try accounts(w)
        let first = try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: ids.a, from: friday, to: friday + week)
        XCTAssertThrowsError(try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: ids.b, from: friday + day, to: friday + 2 * day)) {
            XCTAssertEqual($0 as? AccountAssociationError, .overlapsExisting(id: first.id))
        }
        // Adjacent periods are fine, and so is an open period after the first ends.
        _ = try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: ids.b, from: friday + week, to: nil)
        XCTAssertEqual(try AccountAssociationStore.all(w.db, provider: .anthropic).count, 2)
    }

    func testAnAssociationCanBeCorrectedAndRemovedAndNeverTouchesTheSessions() throws {
        let w = try IntelligenceWorld()
        let ids = try accounts(w)
        w.request(at: friday + hour)
        try w.commit()
        func sessionAccount() throws -> Int64 { try XCTUnwrap(try w.db.read { c in try c.scalarInt("SELECT account_id FROM session LIMIT 1") }) }
        let before = try sessionAccount()
        let made = try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: ids.a, from: friday, to: friday + week, note: "work laptop")
        XCTAssertEqual(try sessionAccount(), before, "the original attribution is unchanged")
        let moved = try AccountAssociationStore.update(w.db, id: made.id, accountID: ids.b, from: friday, to: friday + 2 * day)
        XCTAssertEqual(moved.accountID, ids.b)
        XCTAssertEqual(moved.effectiveTo, friday + 2 * day)
        try AccountAssociationStore.delete(w.db, id: made.id)
        XCTAssertTrue(try AccountAssociationStore.all(w.db, provider: .anthropic).isEmpty)
        XCTAssertThrowsError(try AccountAssociationStore.delete(w.db, id: made.id))
        XCTAssertEqual(try sessionAccount(), before)
    }
}

final class IntelligenceDataPreservationTests: XCTestCase {
    private func counts(_ w: IntelligenceWorld) throws -> [String: Int64] {
        try w.db.read { c in
            var out: [String: Int64] = [:]
            for table in ["quota_snapshot", "quota_cycle", "plan_assignment", "account_association", "model_request", "session"] {
                out[table] = try c.scalarInt("SELECT count(*) FROM \(table)") ?? -1
            }
            return out
        }
    }

    private func seeded() throws -> IntelligenceWorld {
        let w = try IntelligenceWorld()
        try w.twoWeeks(account: IntelligenceWorld.identified)
        w.request(at: friday + hour)
        try w.commit()
        let accountID = try XCTUnwrap(try w.db.read { c in try c.scalarInt("SELECT id FROM account WHERE hash <> ''") })
        _ = try PlanHistoryStore.create(w.db, PlanAssignmentDraft(provider: .anthropic, accountID: accountID, planKey: "claude-pro", accountLabel: nil, effectiveFrom: friday - week, effectiveTo: nil))
        _ = try AccountAssociationStore.create(w.db, provider: .anthropic, accountID: accountID, from: friday - week, to: nil)
        return w
    }

    func testRebuildFromSourceRemovesOnlyWhatTheTranscriptsCanRecreate() throws {
        let w = try seeded()
        let before = try counts(w)
        try w.db.resetDerivedUsageData()
        let after = try counts(w)
        XCTAssertEqual(after["model_request"], 0)
        XCTAssertEqual(after["session"], 0)
        for kept in ["quota_snapshot", "quota_cycle", "plan_assignment", "account_association"] {
            XCTAssertEqual(after[kept], before[kept], "\(kept) cannot be recreated from transcripts, so a rebuild must keep it")
        }
    }

    func testBackupBeforeARebuildHoldsEverythingIncludingAssociationsAndCoverage() throws {
        let w = try seeded()
        let backup = try w.db.backUpBeforeRebuild()
        let copy = try UsageDatabase.open(at: backup)
        XCTAssertEqual(try copy.read { c in try c.scalarInt("SELECT count(*) FROM account_association") }, 1)
        XCTAssertEqual(try copy.read { c in try c.scalarInt("SELECT sum(confirmations) FROM quota_snapshot") },
                       try w.db.read { c in try c.scalarInt("SELECT sum(confirmations) FROM quota_snapshot") })
    }

    func testDeleteAllDataRemovesTheUsersAssociationsAndPlansWithTheAccountsTheyPointAt() throws {
        let w = try seeded()
        try w.db.eraseAllData()
        let after = try counts(w)
        XCTAssertEqual(after["account_association"], 0)
        XCTAssertEqual(after["plan_assignment"], 0)
        XCTAssertEqual(after["quota_snapshot"], 0)
        let violations = try w.db.read { c in try c.query("PRAGMA foreign_key_check") { $0.text(0) } }
        XCTAssertTrue(violations.isEmpty, "no association may be left pointing at a deleted account")
    }

    func testRetentionKeepsASnapshotWhoseConfirmationsReachPastTheCutoff() throws {
        let w = try IntelligenceWorld()
        try w.quota(40, at: friday + hour, resets: friday + week)          // First seen before the cutoff.
        try w.quota(40, at: friday + 3 * day, resets: friday + week)       // Confirmed after it.
        try w.quota(10, at: friday + hour, resets: friday + 2 * week)      // Entirely before the cutoff, in another cycle.
        try w.db.purge(olderThanMs: Clock.ms(friday + day))
        let left = try w.db.read { c in try c.query("SELECT utilization_pct FROM quota_snapshot") { $0.double(0) } }
        XCTAssertEqual(left, [40], "a snapshot still being confirmed inside the retained period is not erased")
        XCTAssertEqual(try w.db.read { c in try c.scalarInt("SELECT count(*) FROM quota_cycle") }, 1, "a cycle left with no reading is removed too")
    }

    func testIntelligenceNeverWritesAnythingOfItsOwn() throws {
        let w = try seeded()
        let before = try counts(w)
        _ = try w.report(identified: true, now: friday + day)
        XCTAssertEqual(try counts(w), before)
    }
}

final class TranscriptAccountIdentificationTests: XCTestCase {
    private func bridge(_ session: String, owner: String) -> String {
        "{\"type\":\"bridge-session\",\"sessionId\":\"\(session)\",\"bridgeSessionId\":\"b-1\",\"lastSequenceNum\":3,\"ownerAccountUuid\":\"\(owner)\"}"
    }

    private func account(of session: String, _ env: TestEnv) throws -> String {
        try XCTUnwrap(try env.db.read { c in
            try c.queryOne("SELECT a.hash FROM session s JOIN account a ON a.id = s.account_id WHERE s.external_id = ?", [.text(session)]) { $0.text(0) }
        })
    }

    func testASessionWhoseTranscriptNamesItsOwnerIsAttributedToThatAccountAndOthersStayUnassigned() throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.user(session: "named", at: t0), bridge("named", owner: "11111111-2222-3333-4444-555555555555"),
                           Fixture.assistant(id: "a1", session: "named", at: t0 + 1000)], to: try env.mainFile(session: "named"))
        try Fixture.write([Fixture.user(session: "plain", at: t0), Fixture.assistant(id: "a2", session: "plain", at: t0 + 1000)],
                          to: try env.mainFile(session: "plain"))
        try Fixture.write([Fixture.user(session: "bad", at: t0), bridge("bad", owner: "not-a-uuid"),
                           Fixture.assistant(id: "a3", session: "bad", at: t0 + 1000)], to: try env.mainFile(session: "bad"))
        try env.syncAll()
        XCTAssertEqual(try account(of: "named", env), IntelligenceWorld.identified.hash, "the same account reference the quota cache produces")
        XCTAssertEqual(try account(of: "plain", env), "")
        XCTAssertEqual(try account(of: "bad", env), "", "a malformed identifier names nothing")
    }

    func testTheRawAccountIdentifierIsNeverStored() throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.user(session: "named", at: t0), bridge("named", owner: "11111111-2222-3333-4444-555555555555"),
                           Fixture.assistant(id: "a1", session: "named", at: t0 + 1000)], to: try env.mainFile(session: "named"))
        try env.syncAll()
        let data = try Data(contentsOf: env.dbURL)
        XCTAssertNil(data.range(of: Data("11111111-2222-3333-4444-555555555555".utf8)))
    }
}
