import Foundation

/// A user's statement that the activity of sessions which name no account, during a period, belongs to one account.
///
/// The sessions keep the attribution their files gave them. The association is separate metadata that analyses may use, and it
/// can be corrected or removed at any time. Nothing creates one automatically.
public struct AccountAssociation: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var provider: ProviderID
    public var accountID: Int64
    public var effectiveFrom: Date
    /// Exclusive. Nil means the association is still open.
    public var effectiveTo: Date?
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date

    public func contains(_ date: Date) -> Bool { date >= effectiveFrom && date < (effectiveTo ?? .distantFuture) }
}

public enum AccountAssociationError: Error, LocalizedError, Equatable {
    case unknownAccount
    case accountNeedsToBeIdentified
    case accountBelongsToAnotherProvider
    case endNotAfterStart
    case overlapsExisting(id: Int64)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .unknownAccount: String(localized: "That account does not exist.")
        case .accountNeedsToBeIdentified: String(localized: "Only an account that the provider identified can be associated with activity.")
        case .accountBelongsToAnotherProvider: String(localized: "The account belongs to a different provider.")
        case .endNotAfterStart: String(localized: "The end of a period must be after its start.")
        case .overlapsExisting(let id): String(localized: "This period overlaps association \(id). Activity can belong to one account at a time.")
        case .notFound: String(localized: "That association no longer exists.")
        }
    }
}

/// Stores account associations. Periods of one provider never overlap, because the same activity cannot belong to two accounts.
public enum AccountAssociationStore {
    private static let columns = "id, provider_id, account_id, effective_from, effective_to, note, created_at, updated_at"

    private static func map(_ r: SQLiteRow) -> AccountAssociation {
        AccountAssociation(id: r.int(0), provider: ProviderID(rawValue: r.text(1)), accountID: r.int(2),
                           effectiveFrom: Clock.date(ms: r.int(3)), effectiveTo: r.intOrNil(4).map(Clock.date(ms:)),
                           note: r.text(5), createdAt: Clock.date(ms: r.int(6)), updatedAt: Clock.date(ms: r.int(7)))
    }

    public static func all(_ db: UsageDatabase, provider: ProviderID) throws -> [AccountAssociation] {
        try db.read { c in
            try c.query("SELECT \(columns) FROM account_association WHERE provider_id = ? ORDER BY effective_from, id",
                        [.text(provider.rawValue)], map)
        }
    }

    @discardableResult
    public static func create(_ db: UsageDatabase, provider: ProviderID, accountID: Int64, from: Date, to: Date?,
                              note: String = "") throws -> AccountAssociation {
        let now = Clock.nowMs()
        let id: Int64 = try db.write { c in
            try validate(c, provider: provider, accountID: accountID, from: from, to: to, excluding: nil)
            try c.run("""
                INSERT INTO account_association(provider_id, account_id, effective_from, effective_to, note, created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                """, [.text(provider.rawValue), .int(accountID), .int(Clock.ms(from)), .optional(to.map(Clock.ms)), .text(note), .int(now), .int(now)])
            return c.lastInsertRowID
        }
        guard let created = try association(db, id: id) else { throw AccountAssociationError.notFound }
        return created
    }

    @discardableResult
    public static func update(_ db: UsageDatabase, id: Int64, accountID: Int64, from: Date, to: Date?, note: String = "") throws -> AccountAssociation {
        guard let existing = try association(db, id: id) else { throw AccountAssociationError.notFound }
        try db.write { c in
            try validate(c, provider: existing.provider, accountID: accountID, from: from, to: to, excluding: id)
            try c.run("""
                UPDATE account_association SET account_id = ?, effective_from = ?, effective_to = ?, note = ?, updated_at = ? WHERE id = ?
                """, [.int(accountID), .int(Clock.ms(from)), .optional(to.map(Clock.ms)), .text(note), .int(Clock.nowMs()), .int(id)])
        }
        guard let updated = try association(db, id: id) else { throw AccountAssociationError.notFound }
        return updated
    }

    public static func delete(_ db: UsageDatabase, id: Int64) throws {
        let changed = try db.write { c in try c.run("DELETE FROM account_association WHERE id = ?", [.int(id)]) }
        guard changed > 0 else { throw AccountAssociationError.notFound }
    }

    public static func association(_ db: UsageDatabase, id: Int64) throws -> AccountAssociation? {
        try db.read { c in try c.queryOne("SELECT \(columns) FROM account_association WHERE id = ?", [.int(id)], map) } ?? nil
    }

    private static func validate(_ c: SQLiteConnection, provider: ProviderID, accountID: Int64, from: Date, to: Date?, excluding id: Int64?) throws {
        if let to, to <= from { throw AccountAssociationError.endNotAfterStart }
        guard let row = try c.queryOne("SELECT provider_id, hash FROM account WHERE id = ?", [.int(accountID)], { ($0.text(0), $0.text(1)) }) else {
            throw AccountAssociationError.unknownAccount
        }
        guard row.0 == provider.rawValue else { throw AccountAssociationError.accountBelongsToAnotherProvider }
        guard !row.1.isEmpty else { throw AccountAssociationError.accountNeedsToBeIdentified }
        let start = Clock.ms(from), end = to.map(Clock.ms) ?? Int64.max
        let overlap = try c.queryOne("""
            SELECT id FROM account_association
            WHERE provider_id = ? AND id != ? AND effective_from < ? AND COALESCE(effective_to, 9223372036854775807) > ?
            ORDER BY effective_from LIMIT 1
            """, [.text(provider.rawValue), .int(id ?? -1), .int(end), .int(start)]) { $0.int(0) }
        if let overlap { throw AccountAssociationError.overlapsExisting(id: overlap) }
    }
}
