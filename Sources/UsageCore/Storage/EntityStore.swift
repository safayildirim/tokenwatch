import Foundation

/// Writes the provider registry into the database, so that queries can join against providers, products,
/// surfaces, telemetry sources and quota pools without knowing about the registry type.
enum RegistrySeeder {
    static func seed(_ r: ProviderRegistry, into c: SQLiteConnection) throws {
        for p in r.providers {
            try c.run("INSERT INTO provider(id, name) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name",
                      [.text(p.id.rawValue), .text(p.name)])
            // Every provider has the explicit unassigned account, which receives activity whose account is unknown.
            try c.run("INSERT OR IGNORE INTO account(provider_id, hash, label) VALUES(?, '', 'Unassigned')", [.text(p.id.rawValue)])
        }
        for p in r.products {
            try c.run("""
                INSERT INTO product(id, provider_id, name, observability) VALUES(?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET provider_id = excluded.provider_id, name = excluded.name, observability = excluded.observability
                """, [.text(p.id.rawValue), .text(p.provider.rawValue), .text(p.name), .text(p.observability)])
        }
        for s in r.surfaces {
            try c.run("INSERT INTO surface(id, name, symbol) VALUES(?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, symbol = excluded.symbol",
                      [.text(s.id.rawValue), .text(s.name), .text(s.symbol)])
        }
        for s in r.sources {
            try c.run("""
                INSERT INTO telemetry_source(id, provider_id, kind, name, capabilities, limitations) VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET provider_id = excluded.provider_id, kind = excluded.kind, name = excluded.name,
                    capabilities = excluded.capabilities, limitations = excluded.limitations
                """, [.text(s.id.rawValue), .text(s.provider.rawValue), .text(s.kind.rawValue), .text(s.name),
                      .int(Int64(s.capabilities.rawValue)), .text(s.limitations)])
            try c.run("DELETE FROM telemetry_source_product WHERE source_id = ?", [.text(s.id.rawValue)])
            for product in s.products {
                try c.run("INSERT OR IGNORE INTO telemetry_source_product(source_id, product_id) VALUES(?, ?)",
                          [.text(s.id.rawValue), .text(product.rawValue)])
            }
        }
        for pool in r.pools {
            try c.run("""
                INSERT INTO pool_definition(provider_id, pool_key, name, note) VALUES(?, ?, ?, ?)
                ON CONFLICT(provider_id, pool_key) DO UPDATE SET name = excluded.name, note = excluded.note
                """, [.text(pool.provider.rawValue), .text(pool.key), .text(pool.name), .text(pool.note)])
            try c.run("DELETE FROM pool_membership WHERE provider_id = ? AND pool_key = ?", [.text(pool.provider.rawValue), .text(pool.key)])
            for product in pool.products {
                try c.run("INSERT OR IGNORE INTO pool_membership(provider_id, pool_key, product_id) VALUES(?, ?, ?)",
                          [.text(pool.provider.rawValue), .text(pool.key), .text(product.rawValue)])
            }
        }
    }
}

/// Resolves the entities that observations refer to (accounts, models, projects, sessions) to row ids,
/// creating them on first use. One resolver lives for the length of a transaction, so each distinct entity
/// costs one lookup however many observations mention it.
final class EntityResolver {
    let c: SQLiteConnection
    let registry: ProviderRegistry
    private var accounts: [AccountRef: Int64] = [:]
    private var models: [String: Int64] = [:]
    private var projects: [String: Int64] = [:]
    private var sessions: [String: Int64] = [:]

    init(_ c: SQLiteConnection, registry: ProviderRegistry) {
        self.c = c
        self.registry = registry
    }

    func account(_ ref: AccountRef) throws -> Int64 {
        if let id = accounts[ref] { return id }
        let hash = ref.hash ?? ""
        try c.run("INSERT OR IGNORE INTO account(provider_id, hash, label) VALUES(?, ?, ?)",
                  [.text(ref.provider.rawValue), .text(hash), .text(hash.isEmpty ? "Unassigned" : "Account " + hash.prefix(6))])
        let id = try c.scalarInt("SELECT id FROM account WHERE provider_id = ? AND hash = ?",
                                 [.text(ref.provider.rawValue), .text(hash)])!
        accounts[ref] = id
        return id
    }

    func model(provider: ProviderID, raw: String) throws -> Int64 {
        let key = provider.rawValue + "\u{1F}" + raw
        if let id = models[key] { return id }
        let d = ModelCatalog.describe(raw, provider: provider)
        let id = try c.queryOne("""
            INSERT INTO model(provider_id, raw_id, canonical, family, display_name) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(provider_id, raw_id) DO UPDATE SET canonical = excluded.canonical, family = excluded.family,
                display_name = excluded.display_name
            RETURNING id
            """, [.text(provider.rawValue), .text(raw), .text(d.canonical), .text(d.family), .text(d.displayName)]) { $0.int(0) }!
        models[key] = id
        return id
    }

    /// The key is a working directory path when one is known, which lets sessions from different providers
    /// that ran in the same folder belong to the same project.
    func project(key: String) throws -> Int64 {
        if let id = projects[key] { return id }
        let isPath = key.hasPrefix("/")
        let name: String
        if isPath {
            let last = (key as NSString).lastPathComponent
            name = last.isEmpty ? key : last
        } else if let colon = key.firstIndex(of: ":") {
            name = String(key[key.index(after: colon)...])
        } else { name = key }
        let id = try c.queryOne("""
            INSERT INTO project(key, path, name) VALUES(?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET path = COALESCE(project.path, excluded.path)
            RETURNING id
            """, [.text(key), .optional(isPath ? key : nil), .text(name)]) { $0.int(0) }!
        projects[key] = id
        return id
    }

    func session(product: ProductID, externalID: String) -> Int64? { sessions[product.rawValue + "\u{1F}" + externalID] }
    func remember(session id: Int64, product: ProductID, externalID: String) { sessions[product.rawValue + "\u{1F}" + externalID] = id }

    /// Returns the row id of a session, creating a placeholder when the source mentioned a session that has
    /// no record of its own (a request, or a quota report, that arrived before the session's first line).
    func ensureSession(product: ProductID, externalID: String, source: TelemetrySourceID) throws -> Int64 {
        if let id = session(product: product, externalID: externalID) { return id }
        let provider = registry.providerOf(product: product) ?? ProviderID(rawValue: "unknown")
        let accountID = try account(.unassigned(provider))
        try c.run("INSERT OR IGNORE INTO session(product_id, external_id, account_id, telemetry_source_id) VALUES(?, ?, ?, ?)",
                  [.text(product.rawValue), .text(externalID), .int(accountID), .text(source.rawValue)])
        let id = try c.scalarInt("SELECT id FROM session WHERE product_id = ? AND external_id = ?",
                                 [.text(product.rawValue), .text(externalID)])!
        remember(session: id, product: product, externalID: externalID)
        return id
    }
}

/// Maintains quota pools, windows, reset cycles and snapshots.
///
/// - A **pool** belongs to one account, so two accounts of the same provider never share a figure.
/// - A **window** belongs to a pool and is identified by a key such as `300m`.
/// - A **cycle** is one period between resets. Reports of the same window disagree on the reset time by a few
///   seconds, so a report joins the cycle whose reset time is within five minutes of its own.
/// - A **snapshot** is a reported utilization within a cycle. Identical reports extend one snapshot's
///   confirmation time instead of adding rows, which keeps the history small and makes "when was this last
///   confirmed" the measure of freshness.
enum QuotaStore {
    /// Reports whose reset times differ by less than this belong to the same cycle.
    ///
    /// The reset time of one cycle is reported with a jitter of a few seconds, because the provider fixes it when the
    /// window's first request arrives and rounds it to whole seconds. On this Mac's Codex history, the reports of
    /// one cycle never differed by more than 13 seconds, while two different pools whose windows began a minute apart
    /// (readings of an account that older files do not name) differed by 53 to 74 seconds. A tolerance of five
    /// minutes merged such pools into one cycle and made their readings alternate. Half a minute keeps the jitter
    /// together and the pools apart.
    static let cycleToleranceMs: Int64 = 30_000

    static func record(_ o: QuotaObservation, originSessionID: Int64?, resolver: EntityResolver) throws {
        let c = resolver.c
        let accountID = try resolver.account(o.account)
        try c.run("INSERT OR IGNORE INTO quota_pool(provider_id, account_id, pool_key, plan_type) VALUES(?, ?, ?, ?)",
                  [.text(o.provider.rawValue), .int(accountID), .text(o.poolKey), .optional(o.planType)])
        let poolID = try c.scalarInt("SELECT id FROM quota_pool WHERE account_id = ? AND pool_key = ?", [.int(accountID), .text(o.poolKey)])!
        if let plan = o.planType {
            try c.run("UPDATE quota_pool SET plan_type = ? WHERE id = ?", [.text(plan), .int(poolID)])
        }
        try c.run("INSERT OR IGNORE INTO quota_window(pool_id, window_key, duration_minutes) VALUES(?, ?, ?)",
                  [.int(poolID), .text(o.windowKey), .optional(o.windowMinutes.map(Int64.init))])
        let windowID = try c.scalarInt("SELECT id FROM quota_window WHERE pool_id = ? AND window_key = ?", [.int(poolID), .text(o.windowKey)])!

        let observedMs = Clock.ms(o.observedAt)
        let resetsMs = o.resetsAt.map(Clock.ms)

        // Find or create the cycle.
        let cycleID: Int64
        if let resetsMs {
            let existing = try c.queryOne("""
                SELECT id FROM quota_cycle WHERE window_id = ? AND resets_at BETWEEN ? AND ?
                ORDER BY abs(resets_at - ?) LIMIT 1
                """, [.int(windowID), .int(resetsMs - cycleToleranceMs), .int(resetsMs + cycleToleranceMs), .int(resetsMs)]) { $0.int(0) }
            if let existing { cycleID = existing } else {
                try c.run("INSERT INTO quota_cycle(window_id, resets_at, first_observed_at, last_observed_at) VALUES(?, ?, ?, ?)",
                          [.int(windowID), .int(resetsMs), .int(observedMs), .int(observedMs)])
                cycleID = c.lastInsertRowID
            }
        } else {
            let existing = try c.scalarInt("SELECT id FROM quota_cycle WHERE window_id = ? AND resets_at IS NULL", [.int(windowID)])
            if let existing { cycleID = existing } else {
                try c.run("INSERT INTO quota_cycle(window_id, resets_at, first_observed_at, last_observed_at) VALUES(?, NULL, ?, ?)",
                          [.int(windowID), .int(observedMs), .int(observedMs)])
                cycleID = c.lastInsertRowID
            }
        }
        try c.run("""
            UPDATE quota_cycle SET first_observed_at = min(first_observed_at, ?), last_observed_at = max(last_observed_at, ?) WHERE id = ?
            """, [.int(observedMs), .int(observedMs), .int(cycleID)])

        try c.run("""
            INSERT INTO quota_snapshot(window_id, cycle_id, utilization_pct, resets_at, observed_at, last_confirmed_at,
                telemetry_source_id, origin_session_id, authority)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(window_id, cycle_id, utilization_pct, authority) DO UPDATE SET
                observed_at = min(quota_snapshot.observed_at, excluded.observed_at),
                last_confirmed_at = max(quota_snapshot.last_confirmed_at, excluded.last_confirmed_at),
                resets_at = CASE WHEN excluded.last_confirmed_at >= quota_snapshot.last_confirmed_at
                                 THEN COALESCE(excluded.resets_at, quota_snapshot.resets_at) ELSE quota_snapshot.resets_at END,
                -- The percentage is the same, but the provenance of the latest confirmation is not. Keeping the
                -- most recent source makes the source label of a collapsed snapshot truthful instead of depending on
                -- which feed happened to run first.
                telemetry_source_id = CASE WHEN excluded.last_confirmed_at >= quota_snapshot.last_confirmed_at
                                           THEN excluded.telemetry_source_id ELSE quota_snapshot.telemetry_source_id END,
                origin_session_id = CASE WHEN excluded.last_confirmed_at >= quota_snapshot.last_confirmed_at
                                         THEN excluded.origin_session_id ELSE quota_snapshot.origin_session_id END
            """, [.int(windowID), .int(cycleID), .real(o.utilizationPercent), .optional(resetsMs), .int(observedMs), .int(observedMs),
                  .text(o.source.rawValue), .optional(originSessionID), .text(o.authority.rawValue)])
    }
}
