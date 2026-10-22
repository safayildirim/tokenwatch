import Foundation

// MARK: - Plan history

/// Where a plan assignment came from.
///
/// The distinction is deliberately visible everywhere. A plan reported by a provider's own telemetry
/// is evidence; a plan a person typed in is metadata. Neither is a measurement of capacity.
public enum PlanAssignmentProvenance: String, Codable, Sendable, CaseIterable {
    case manual
    case providerReported
}

/// A half-open period `[effectiveFrom, effectiveTo)` during which one account was on one plan.
///
/// `planKey == nil` means the plan is unknown. That is a valid, honest state. Assignments for one
/// account may not overlap; an adjacent pair (one ends exactly when the next begins) is allowed.
/// The label is a person's own name for the subscription, not a provider account identifier.
public struct PlanAssignment: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var provider: ProviderID
    public var accountID: Int64
    public var planKey: String?
    public var accountLabel: String?
    public var effectiveFrom: Date
    /// Exclusive. Nil means the assignment is still open.
    public var effectiveTo: Date?
    public var provenance: PlanAssignmentProvenance
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64, provider: ProviderID, accountID: Int64, planKey: String?, accountLabel: String?,
                effectiveFrom: Date, effectiveTo: Date?, provenance: PlanAssignmentProvenance, note: String,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.provider = provider
        self.accountID = accountID
        self.planKey = planKey
        self.accountLabel = accountLabel
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.provenance = provenance
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func contains(_ date: Date) -> Bool {
        date >= effectiveFrom && (effectiveTo.map { date < $0 } ?? true)
    }

    public var isOpen: Bool { effectiveTo == nil }
}

public struct PlanAssignmentDraft: Sendable, Equatable {
    public var provider: ProviderID
    public var accountID: Int64
    public var planKey: String?
    public var accountLabel: String?
    public var effectiveFrom: Date
    public var effectiveTo: Date?
    public var provenance: PlanAssignmentProvenance
    public var note: String

    public init(provider: ProviderID, accountID: Int64, planKey: String?, accountLabel: String?,
                effectiveFrom: Date, effectiveTo: Date?, provenance: PlanAssignmentProvenance = .manual,
                note: String = "") {
        self.provider = provider
        self.accountID = accountID
        self.planKey = planKey
        self.accountLabel = accountLabel
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.provenance = provenance
        self.note = note
    }
}

public enum PlanHistoryError: Error, LocalizedError, Equatable {
    case unknownAccount
    case accountBelongsToAnotherProvider
    case endNotAfterStart
    case overlapsExisting(id: Int64)
    case assignmentNotFound

    public var errorDescription: String? {
        switch self {
        case .unknownAccount:
            String(localized: "That account does not exist.")
        case .accountBelongsToAnotherProvider:
            String(localized: "The account belongs to a different provider.")
        case .endNotAfterStart:
            String(localized: "The end of a plan period must be after its start.")
        case .overlapsExisting(let id):
            String(localized: "This period overlaps plan period \(id). Plan periods for one account must not overlap.")
        case .assignmentNotFound:
            String(localized: "That plan period no longer exists.")
        }
    }
}

/// Records which plan an account used, without touching any raw observation.
public enum PlanHistoryStore {
    /// Reads every assignment of one account, oldest first.
    public static func assignments(_ db: UsageDatabase, provider: ProviderID, accountID: Int64) throws -> [PlanAssignment] {
        try db.read { c in
            try c.query("""
                SELECT id, provider_id, account_id, plan_key, account_label, effective_from, effective_to,
                       provenance, note, created_at, updated_at
                FROM plan_assignment
                WHERE provider_id = ? AND account_id = ?
                ORDER BY effective_from, id
                """, [.text(provider.rawValue), .int(accountID)]) { r in
                PlanAssignment(
                    id: r.int(0), provider: ProviderID(rawValue: r.text(1)), accountID: r.int(2),
                    planKey: r.textOrNil(3), accountLabel: r.textOrNil(4),
                    effectiveFrom: Clock.date(ms: r.int(5)), effectiveTo: r.intOrNil(6).map(Clock.date(ms:)),
                    provenance: PlanAssignmentProvenance(rawValue: r.text(7)) ?? .manual,
                    note: r.text(8), createdAt: Clock.date(ms: r.int(9)), updatedAt: Clock.date(ms: r.int(10)))
            }
        }
    }

    @discardableResult
    public static func create(_ db: UsageDatabase, _ draft: PlanAssignmentDraft) throws -> PlanAssignment {
        let now = Clock.nowMs()
        let inserted: Int64 = try db.write { c in
            // The overlap check and the insert share one serialized write transaction, so two
            // concurrent writers cannot both pass the check and create an ambiguous history.
            try validate(draft, excluding: nil, in: c)
            try c.run("""
                INSERT INTO plan_assignment(provider_id, account_id, plan_key, account_label, effective_from,
                    effective_to, provenance, note, created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(draft.provider.rawValue), .int(draft.accountID), .optional(draft.planKey),
                      .optional(draft.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty),
                      .int(Clock.ms(draft.effectiveFrom)), .optional(draft.effectiveTo.map(Clock.ms)),
                      .text(draft.provenance.rawValue), .text(draft.note), .int(now), .int(now)])
            return c.lastInsertRowID
        }
        guard let assignment = try assignment(db, id: inserted) else { throw PlanHistoryError.assignmentNotFound }
        return assignment
    }

    @discardableResult
    public static func update(_ db: UsageDatabase, id: Int64, _ draft: PlanAssignmentDraft) throws -> PlanAssignment {
        guard let existing = try assignment(db, id: id) else { throw PlanHistoryError.assignmentNotFound }
        guard existing.provider == draft.provider, existing.accountID == draft.accountID else {
            throw PlanHistoryError.accountBelongsToAnotherProvider
        }
        try db.write { c in
            try validate(draft, excluding: id, in: c)
            try c.run("""
                UPDATE plan_assignment SET plan_key = ?, account_label = ?, effective_from = ?, effective_to = ?,
                    provenance = ?, note = ?, updated_at = ?
                WHERE id = ?
                """, [.optional(draft.planKey),
                      .optional(draft.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty),
                      .int(Clock.ms(draft.effectiveFrom)), .optional(draft.effectiveTo.map(Clock.ms)),
                      .text(draft.provenance.rawValue), .text(draft.note), .int(Clock.nowMs()), .int(id)])
        }
        guard let updated = try assignment(db, id: id) else { throw PlanHistoryError.assignmentNotFound }
        return updated
    }

    /// Removes the annotation. Measurements that referred to it keep the plan key they captured, so
    /// their historical interpretation does not silently change.
    public static func delete(_ db: UsageDatabase, id: Int64) throws {
        let changed = try db.write { c in
            try c.run("DELETE FROM plan_assignment WHERE id = ?", [.int(id)])
        }
        guard changed > 0 else { throw PlanHistoryError.assignmentNotFound }
    }

    public static func assignment(_ db: UsageDatabase, id: Int64) throws -> PlanAssignment? {
        try db.read { c in
            try c.queryOne("""
                SELECT id, provider_id, account_id, plan_key, account_label, effective_from, effective_to,
                       provenance, note, created_at, updated_at
                FROM plan_assignment WHERE id = ?
                """, [.int(id)]) { r in
                PlanAssignment(id: r.int(0), provider: ProviderID(rawValue: r.text(1)), accountID: r.int(2),
                               planKey: r.textOrNil(3), accountLabel: r.textOrNil(4),
                               effectiveFrom: Clock.date(ms: r.int(5)), effectiveTo: r.intOrNil(6).map(Clock.date(ms:)),
                               provenance: PlanAssignmentProvenance(rawValue: r.text(7)) ?? .manual, note: r.text(8),
                               createdAt: Clock.date(ms: r.int(9)), updatedAt: Clock.date(ms: r.int(10)))
            }
        } ?? nil
    }

    /// Returns the assignments reshaped into an unambiguous timeline.
    public static func timeline(_ db: UsageDatabase, provider: ProviderID, accountID: Int64) throws -> PlanTimeline {
        PlanTimeline(assignments: try assignments(db, provider: provider, accountID: accountID))
    }

    private static func validate(_ draft: PlanAssignmentDraft, excluding id: Int64?, in c: SQLiteConnection) throws {
        if let end = draft.effectiveTo, end <= draft.effectiveFrom { throw PlanHistoryError.endNotAfterStart }
        guard let provider = try c.queryOne("SELECT provider_id FROM account WHERE id = ?", [.int(draft.accountID)], { $0.text(0) }) else {
            throw PlanHistoryError.unknownAccount
        }
        guard provider == draft.provider.rawValue else { throw PlanHistoryError.accountBelongsToAnotherProvider }
        let start = Clock.ms(draft.effectiveFrom)
        let end = draft.effectiveTo.map(Clock.ms) ?? Int64.max
        let overlap = try c.queryOne("""
            SELECT id FROM plan_assignment
            WHERE provider_id = ? AND account_id = ? AND id != ?
              AND effective_from < ? AND COALESCE(effective_to, 9223372036854775807) > ?
            ORDER BY effective_from LIMIT 1
            """, [.text(draft.provider.rawValue), .int(draft.accountID), .int(id ?? -1), .int(end), .int(start)]) { $0.int(0) }
        if let overlap { throw PlanHistoryError.overlapsExisting(id: overlap) }
    }
}

/// The interpreted plan history of one account, with ambiguity made explicit.
public struct PlanTimeline: Sendable, Equatable {
    public var assignments: [PlanAssignment]
    public var overlaps: [PlanTimelineOverlap]
    public var gaps: [Range<Date>]

    public init(assignments: [PlanAssignment]) {
        let sorted = assignments.sorted { ($0.effectiveFrom, $0.id) < ($1.effectiveFrom, $1.id) }
        self.assignments = sorted
        var overlaps: [PlanTimelineOverlap] = []
        var gaps: [Range<Date>] = []
        var active: PlanAssignment?
        for next in sorted {
            if let current = active, next.effectiveFrom < (current.effectiveTo ?? .distantFuture) {
                overlaps.append(PlanTimelineOverlap(firstID: current.id, secondID: next.id,
                                                    from: next.effectiveFrom,
                                                    to: min(current.effectiveTo ?? .distantFuture,
                                                           next.effectiveTo ?? .distantFuture)))
            }
            if active == nil || (next.effectiveTo ?? .distantFuture) > (active?.effectiveTo ?? .distantPast) {
                active = next
            }
        }
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            if overlaps.isEmpty, let end = previous.effectiveTo, end < next.effectiveFrom {
                gaps.append(end..<next.effectiveFrom)
            }
        }
        self.overlaps = overlaps
        self.gaps = gaps
    }

    public var isUnambiguous: Bool { overlaps.isEmpty }

    /// The assignment in effect at `date`, or nil when the plan is unspecified.
    public func assignment(at date: Date) -> PlanAssignment? {
        guard isUnambiguous else { return nil }
        var low = 0, high = assignments.count
        while low < high {
            let mid = (low + high) / 2
            if assignments[mid].effectiveFrom <= date { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let candidate = assignments[low - 1]
        return candidate.contains(date) ? candidate : nil
    }
}

public struct PlanTimelineOverlap: Sendable, Equatable, Identifiable {
    public var firstID: Int64
    public var secondID: Int64
    public var from: Date
    public var to: Date
    public var id: String { "\(firstID)-\(secondID)-\(from.timeIntervalSince1970)" }
}

// MARK: - Plan prices

public struct PlanPriceQuote: Sendable, Equatable {
    public enum Origin: String, Sendable { case reference, user }
    public var plan: SubscriptionPlanDefinition
    public var monthlyPriceMicros: Int64
    public var currency: String
    public var origin: Origin
    public var effectiveFrom: Date
    public var note: String?

    public var monthlyPrice: Double { Double(monthlyPriceMicros) / 1_000_000 }
}

public enum PlanPriceStore {
    /// A sanity bound, not a policy. It keeps a typo from overflowing later multi-subscription math.
    public static let maximumMonthlyPriceMicros: Int64 = 1_000_000_000_000 // $1,000,000

    /// Returns the user's price in effect at `date`, or the registry's reference price.
    public static func quote(_ db: UsageDatabase, plan: SubscriptionPlanDefinition, at date: Date = Date()) -> PlanPriceQuote {
        let row = (try? db.read { c in
            try c.queryOne("""
                SELECT monthly_price_micros, currency, effective_from, note
                FROM plan_price
                WHERE provider_id = ? AND plan_key = ? AND effective_from <= ?
                ORDER BY effective_from DESC LIMIT 1
                """, [.text(plan.provider.rawValue), .text(plan.key), .int(Clock.ms(date))]) { r in
                (r.int(0), r.text(1), Clock.date(ms: r.int(2)), r.textOrNil(3))
            }
        }) ?? nil
        if let row {
            return PlanPriceQuote(plan: plan, monthlyPriceMicros: row.0, currency: row.1, origin: .user,
                                  effectiveFrom: row.2, note: row.3)
        }
        return PlanPriceQuote(plan: plan, monthlyPriceMicros: plan.monthlyPriceMicros, currency: plan.currency,
                              origin: .reference, effectiveFrom: .distantPast,
                              note: plan.priceAsOf.map { String(localized: "Reference price as of \($0)") } ?? plan.note)
    }

    /// Adds a user price from `date` onward. Earlier rows stay, so a cost analysis of an older month
    /// can use the price that was in effect then.
    public static func setPrice(_ db: UsageDatabase, plan: SubscriptionPlanDefinition, monthlyPriceMicros: Int64,
                                currency: String = "USD", from date: Date = Date(), note: String? = nil) throws {
        guard monthlyPriceMicros >= 0 else { throw PlanPriceError.negativePrice }
        guard monthlyPriceMicros <= maximumMonthlyPriceMicros else { throw PlanPriceError.invalidPrice }
        try db.write { c in
            try c.run("""
                INSERT INTO plan_price(provider_id, plan_key, monthly_price_micros, currency, effective_from, origin, note)
                VALUES(?, ?, ?, ?, ?, 'user', ?)
                ON CONFLICT(provider_id, plan_key, effective_from) DO UPDATE SET
                    monthly_price_micros = excluded.monthly_price_micros,
                    currency = excluded.currency, origin = 'user', note = excluded.note
                """, [.text(plan.provider.rawValue), .text(plan.key), .int(monthlyPriceMicros),
                      .text(currency), .int(Clock.ms(date)), .optional(note)])
        }
    }

    public static func removeUserPrices(_ db: UsageDatabase, provider: ProviderID, planKey: String) throws {
        try db.write { c in
            try c.run("DELETE FROM plan_price WHERE provider_id = ? AND plan_key = ? AND origin = 'user'",
                      [.text(provider.rawValue), .text(planKey)])
        }
    }
}

public enum PlanPriceError: Error, LocalizedError, Equatable {
    case negativePrice
    case invalidPrice
    public var errorDescription: String? {
        switch self {
        case .negativePrice: String(localized: "A monthly price cannot be negative.")
        case .invalidPrice: String(localized: "Enter a finite monthly price in the plan's currency.")
        }
    }
}

// MARK: - Controlled measurement intervals

public enum CapacityMeasurementState: String, Codable, Sendable {
    case open, closed, abandoned
}

/// An explicitly labelled period in which a person performed ordinary work while capacity evidence
/// was being collected. It contains no requests of its own; it only points at a time range.
public struct CapacityMeasurement: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var provider: ProviderID
    public var accountID: Int64
    public var poolKey: String
    public var windowKey: String
    public var windowMinutes: Int?
    public var planAssignmentID: Int64?
    public var planKey: String?
    public var accountLabel: String?
    public var label: String
    public var note: String
    public var startedAt: Date
    public var endedAt: Date?
    public var state: CapacityMeasurementState
    public var createdAt: Date
    public var updatedAt: Date

    public var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

public enum CapacityMeasurementError: Error, LocalizedError, Equatable {
    case noPlanAssignment(at: Date)
    case alreadyOpen(id: Int64)
    case measurementNotFound
    case endNotAfterStart
    case measurementNotOpen
    case unknownWindow

    public var errorDescription: String? {
        switch self {
        case .noPlanAssignment(let date):
            String(localized: "No plan period covers \(date.formatted(date: .abbreviated, time: .shortened)). Add the plan you were on first.")
        case .alreadyOpen(let id):
            String(localized: "Measurement \(id) is already running for this window. End it before starting another.")
        case .measurementNotFound:
            String(localized: "That measurement no longer exists.")
        case .endNotAfterStart:
            String(localized: "The end of a measurement must be after its start.")
        case .measurementNotOpen:
            String(localized: "That measurement has already ended.")
        case .unknownWindow:
            String(localized: "That quota window is not known for this account.")
        }
    }
}

public enum CapacityMeasurementStore {
    @discardableResult
    public static func begin(_ db: UsageDatabase, provider: ProviderID, accountID: Int64, poolKey: String,
                             windowKey: String, label: String, note: String = "",
                             at date: Date = Date()) throws -> CapacityMeasurement {
        let timeline = try PlanHistoryStore.timeline(db, provider: provider, accountID: accountID)
        guard let assignment = timeline.assignment(at: date) else {
            throw CapacityMeasurementError.noPlanAssignment(at: date)
        }
        let inserted: Int64 = try db.write { c in
            guard let storedMinutes = try c.queryOne("""
                SELECT w.duration_minutes FROM quota_window w
                JOIN quota_pool p ON p.id = w.pool_id
                WHERE p.account_id = ? AND p.pool_key = ? AND w.window_key = ?
                """, [.int(accountID), .text(poolKey), .text(windowKey)], { $0.intOrNil(0) }) else {
                throw CapacityMeasurementError.unknownWindow
            }
            if let open = try c.queryOne("""
                SELECT id FROM capacity_measurement
                WHERE account_id = ? AND pool_key = ? AND window_key = ? AND ended_at IS NULL
                """, [.int(accountID), .text(poolKey), .text(windowKey)], { $0.int(0) }) {
                throw CapacityMeasurementError.alreadyOpen(id: open)
            }
            let now = Clock.nowMs()
            try c.run("""
                INSERT INTO capacity_measurement(provider_id, account_id, pool_key, window_key, window_minutes,
                    plan_assignment_id, plan_key, account_label, label, note, started_at, ended_at, state,
                    created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'open', ?, ?)
                """, [.text(provider.rawValue), .int(accountID), .text(poolKey), .text(windowKey),
                      .optional(storedMinutes), .int(assignment.id), .optional(assignment.planKey),
                      .optional(assignment.accountLabel), .text(label), .text(note), .int(Clock.ms(date)), .int(now), .int(now)])
            return c.lastInsertRowID
        }
        guard let measurement = try measurement(db, id: inserted) else {
            throw CapacityMeasurementError.measurementNotFound
        }
        return measurement
    }

    @discardableResult
    public static func close(_ db: UsageDatabase, id: Int64, at date: Date = Date()) throws -> CapacityMeasurement {
        guard let existing = try measurement(db, id: id) else { throw CapacityMeasurementError.measurementNotFound }
        guard existing.state == .open else { throw CapacityMeasurementError.measurementNotOpen }
        guard date > existing.startedAt else { throw CapacityMeasurementError.endNotAfterStart }
        try db.write { c in
            try c.run("UPDATE capacity_measurement SET ended_at = ?, state = 'closed', updated_at = ? WHERE id = ?",
                      [.int(Clock.ms(date)), .int(Clock.nowMs()), .int(id)])
        }
        guard let updated = try measurement(db, id: id) else { throw CapacityMeasurementError.measurementNotFound }
        return updated
    }

    public static func abandon(_ db: UsageDatabase, id: Int64, at date: Date = Date()) throws {
        guard let existing = try measurement(db, id: id) else { throw CapacityMeasurementError.measurementNotFound }
        guard existing.state == .open else { throw CapacityMeasurementError.measurementNotOpen }
        let end = max(date, existing.startedAt.addingTimeInterval(0.001))
        try db.write { c in
            try c.run("UPDATE capacity_measurement SET ended_at = ?, state = 'abandoned', updated_at = ? WHERE id = ?",
                      [.int(Clock.ms(end)), .int(Clock.nowMs()), .int(id)])
        }
    }

    public static func delete(_ db: UsageDatabase, id: Int64) throws {
        try db.write { c in
            try c.run("DELETE FROM capacity_measurement WHERE id = ?", [.int(id)])
        }
    }

    public static func measurement(_ db: UsageDatabase, id: Int64) throws -> CapacityMeasurement? {
        try db.read { c in
            try c.queryOne("""
                SELECT id, provider_id, account_id, pool_key, window_key, window_minutes, plan_assignment_id,
                       plan_key, account_label, label, note, started_at, ended_at, state, created_at, updated_at
                FROM capacity_measurement WHERE id = ?
                """, [.int(id)]) { read($0) }
        } ?? nil
    }

    /// Lists measurements, newest first. Closed measurements are included unless `includeClosed` is false.
    public static func list(_ db: UsageDatabase, provider: ProviderID? = nil, accountID: Int64? = nil,
                           poolKey: String? = nil, windowKey: String? = nil,
                           includeClosed: Bool = true) throws -> [CapacityMeasurement] {
        var whereSQL: [String] = []
        var params: [SQLValue] = []
        if let provider { whereSQL.append("provider_id = ?"); params.append(.text(provider.rawValue)) }
        if let accountID { whereSQL.append("account_id = ?"); params.append(.int(accountID)) }
        if let poolKey { whereSQL.append("pool_key = ?"); params.append(.text(poolKey)) }
        if let windowKey { whereSQL.append("window_key = ?"); params.append(.text(windowKey)) }
        if !includeClosed { whereSQL.append("ended_at IS NULL") }
        let clause = whereSQL.isEmpty ? "" : "WHERE " + whereSQL.joined(separator: " AND ")
        return try db.read { c in
            try c.query("""
                SELECT id, provider_id, account_id, pool_key, window_key, window_minutes, plan_assignment_id,
                       plan_key, account_label, label, note, started_at, ended_at, state, created_at, updated_at
                FROM capacity_measurement \(clause)
                ORDER BY started_at DESC, id DESC
                """, params) { read($0) }
        }
    }

    private static func read(_ r: SQLiteRow) -> CapacityMeasurement {
        CapacityMeasurement(
            id: r.int(0), provider: ProviderID(rawValue: r.text(1)), accountID: r.int(2), poolKey: r.text(3),
            windowKey: r.text(4), windowMinutes: r.intOrNil(5).map { Int($0) }, planAssignmentID: r.intOrNil(6),
            planKey: r.textOrNil(7), accountLabel: r.textOrNil(8), label: r.text(9), note: r.text(10),
            startedAt: Clock.date(ms: r.int(11)), endedAt: r.intOrNil(12).map(Clock.date(ms:)),
            state: CapacityMeasurementState(rawValue: r.text(13)) ?? .closed,
            createdAt: Clock.date(ms: r.int(14)), updatedAt: Clock.date(ms: r.int(15)))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
