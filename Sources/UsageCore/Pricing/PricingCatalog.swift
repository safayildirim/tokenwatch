import Foundation

/// A rate card for one model, valid from a given time and for a given prompt size and speed.
///
/// Rates are stored as whole micro-USD per million tokens. Multiplying a token count by such a rate
/// gives an exact whole number of pico-USD, which keeps sums over millions of requests free of
/// floating point error.
public struct PriceRate: Sendable, Equatable {
    public var provider: ProviderID
    public var modelKey: String
    public var effectiveFromMs: Int64
    /// The rate applies when the request's logical input is at least this many tokens.
    public var promptMin: Int64
    /// ... and below this many tokens. Nil means no upper bound.
    public var promptMax: Int64?
    public var speed: String
    public var inputMicrosPerMTok: Int64
    public var outputMicrosPerMTok: Int64
    public var cacheReadMicrosPerMTok: Int64
    public var cache5mMicrosPerMTok: Int64
    public var cache1hMicrosPerMTok: Int64
    public var note: String?
    /// Whether the price was published, or worked out from other published facts. See `PriceBasis`.
    public var basis: PriceBasis

    /// Builds a rate from dollar prices per million tokens.
    public init(provider: ProviderID, model: String, from: Int64 = 0, promptMin: Int64 = 0, promptMax: Int64? = nil, speed: String = "standard",
                input: Double, output: Double, cacheRead: Double, cache5m: Double? = nil, cache1h: Double? = nil,
                basis: PriceBasis = .published, note: String? = nil) {
        func micros(_ usd: Double) -> Int64 { Int64((usd * 1_000_000).rounded()) }
        self.provider = provider
        self.modelKey = model
        self.effectiveFromMs = from
        self.promptMin = promptMin
        self.promptMax = promptMax
        self.speed = speed
        self.inputMicrosPerMTok = micros(input)
        self.outputMicrosPerMTok = micros(output)
        self.cacheReadMicrosPerMTok = micros(cacheRead)
        // Cache writes default to the premium that some providers charge (1.25x for a short lifetime, 2x for a long one).
        // A provider that does not charge extra for cache writes supplies explicit rates equal to its input rate.
        self.cache5mMicrosPerMTok = micros(cache5m ?? input * 1.25)
        self.cache1hMicrosPerMTok = micros(cache1h ?? input * 2)
        self.note = note
        self.basis = basis
    }
}

/// Where a built-in price comes from. A price the user typed in is a third kind, stored with the origin `user`.
public enum PriceBasis: String, Sendable, Equatable {
    /// The provider published this price for the period the card covers.
    case published = "builtin"
    /// The provider published a price cut as a percentage, not as a new price, so the price before the cut is worked
    /// out from the price after it. The estimate is labelled accordingly wherever it uses such a card.
    case derived = "derived"
}

public enum PricingStore {
    /// A fingerprint of the built-in catalog, so that a changed catalog is reinstalled on the next launch.
    static var catalogFingerprint: String {
        var text = PricingCatalog.asOfSummary
        for r in PricingCatalog.builtin {
            text += "|\(r.basis.rawValue),\(r.effectiveFromMs),\(r.provider.rawValue),\(r.modelKey),\(r.promptMin),\(r.promptMax ?? -1),\(r.speed),\(r.inputMicrosPerMTok),\(r.outputMicrosPerMTok),\(r.cacheReadMicrosPerMTok),\(r.cache5mMicrosPerMTok),\(r.cache1hMicrosPerMTok)"
        }
        return FNV.hash(Array(text.utf8), count: text.utf8.count)
    }

    /// Installs the built-in rate cards when the stored copy is out of date.
    static func seedIfNeeded(_ db: UsageDatabase) throws {
        if db.setting("pricing_catalog_fingerprint") == catalogFingerprint { return }
        try seedBuiltin(db)
        try db.setSetting("pricing_catalog_fingerprint", catalogFingerprint)
    }

    /// Installs the built-in rate cards, replacing earlier built-in rows and leaving user-defined
    /// rows untouched.
    public static func seedBuiltin(_ db: UsageDatabase) throws {
        try db.write { c in
            try c.run("DELETE FROM price_rate WHERE origin IN ('builtin', 'derived')")
            for r in PricingCatalog.builtin { try insert(c, r, origin: r.basis.rawValue) }
        }
    }

    /// Adds or replaces a user-defined rate card.
    public static func upsertUserRate(_ db: UsageDatabase, _ rate: PriceRate) throws {
        try db.write { c in
            try c.run("""
                DELETE FROM price_rate WHERE provider_id = ? AND model_key = ? AND effective_from = ? AND prompt_min = ? AND speed = ?
                """, [.text(rate.provider.rawValue), .text(rate.modelKey), .int(rate.effectiveFromMs), .int(rate.promptMin), .text(rate.speed)])
            try insert(c, rate, origin: "user")
        }
    }

    private static func insert(_ c: SQLiteConnection, _ r: PriceRate, origin: String) throws {
        try c.run("""
            INSERT OR REPLACE INTO price_rate(provider_id, model_key, effective_from, prompt_min, prompt_max, speed,
                input_micros_per_mtok, output_micros_per_mtok, cache_read_micros_per_mtok,
                cache_5m_micros_per_mtok, cache_1h_micros_per_mtok, origin, note)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(r.provider.rawValue), .text(r.modelKey), .int(r.effectiveFromMs), .int(r.promptMin), .optional(r.promptMax), .text(r.speed),
                  .int(r.inputMicrosPerMTok), .int(r.outputMicrosPerMTok), .int(r.cacheReadMicrosPerMTok),
                  .int(r.cache5mMicrosPerMTok), .int(r.cache1hMicrosPerMTok), .text(origin), .optional(r.note)])
    }
}

/// SQL fragments that price requests inside analytical queries.
///
/// Costs are computed at query time from the rate card that was in effect when each request was
/// made, rather than stored on the request. That keeps the request records immutable while letting
/// a corrected rate card repair estimates.
///
/// A token category that the source did not report is treated as zero for pricing, and the coverage
/// columns say how many requests that affected.
enum CostSQL {
    /// Joins the effective rate card onto an aliased `model_request r`. Requires the `model m` join.
    static let join = """
        LEFT JOIN price_rate p ON p.id = (
            SELECT pr.id FROM price_rate pr
            WHERE pr.provider_id = m.provider_id AND pr.model_key = m.canonical
              AND pr.speed = COALESCE(r.speed, 'standard')
              AND pr.effective_from <= r.requested_at
              AND r.logical_input_tokens >= pr.prompt_min
              AND (pr.prompt_max IS NULL OR r.logical_input_tokens < pr.prompt_max)
            ORDER BY pr.effective_from DESC LIMIT 1)
        """

    /// Pico-USD cost of one request row. Cache writes whose TTL the source did not state are priced
    /// at the cheaper five-minute rate, which makes the estimate a lower bound for them. Reasoning tokens
    /// are part of the output tokens and are therefore not priced a second time.
    static let picoUSD = """
        COALESCE(COALESCE(r.uncached_input_tokens, 0) * p.input_micros_per_mtok
               + r.output_tokens * p.output_micros_per_mtok
               + COALESCE(r.cache_read_tokens, 0) * p.cache_read_micros_per_mtok
               + COALESCE(r.cache_creation_5m_tokens, 0) * p.cache_5m_micros_per_mtok
               + COALESCE(r.cache_creation_1h_tokens, 0) * p.cache_1h_micros_per_mtok
               + max(0, COALESCE(r.cache_creation_tokens, 0) - COALESCE(r.cache_creation_5m_tokens, 0) - COALESCE(r.cache_creation_1h_tokens, 0))
                 * p.cache_5m_micros_per_mtok, 0)
        """

    static let unpricedTokens = """
        CASE WHEN p.id IS NULL THEN r.logical_input_tokens + r.output_tokens ELSE 0 END
        """

    /// The number of columns that `aggregateColumns` yields.
    static let aggregateWidth: Int32 = 18

    /// Column list that yields request count, token sums, cost and coverage, in the order `readAggregate` expects.
    static let aggregateColumns = """
        count(r.id),
        COALESCE(sum(r.uncached_input_tokens), 0), COALESCE(sum(r.output_tokens), 0),
        COALESCE(sum(r.cache_read_tokens), 0), COALESCE(sum(r.cache_creation_tokens), 0),
        COALESCE(sum(COALESCE(r.cache_creation_5m_tokens, 0)), 0), COALESCE(sum(COALESCE(r.cache_creation_1h_tokens, 0)), 0),
        COALESCE(sum(r.reasoning_output_tokens), 0),
        COALESCE(sum(\(picoUSD)), 0), COALESCE(sum(\(unpricedTokens)), 0),
        COALESCE(sum(r.uncached_input_tokens IS NULL), 0), COALESCE(sum(r.cache_read_tokens IS NULL), 0),
        COALESCE(sum(r.cache_creation_tokens IS NULL), 0), COALESCE(sum(r.reasoning_output_tokens IS NULL), 0),
        COALESCE(sum(r.completeness = 'reconciledFromTotals'), 0), COALESCE(sum(r.completeness = 'partial'), 0),
        COALESCE(sum(CASE WHEN p.origin = 'derived' THEN r.logical_input_tokens + r.output_tokens ELSE 0 END), 0),
        COALESCE(sum(CASE WHEN p.origin = 'user' THEN r.logical_input_tokens + r.output_tokens ELSE 0 END), 0)
        """

    struct Aggregate {
        var requests: Int
        var tokens: TokenCounts
        var cost: EstimatedCost
        var coverage: UsageCoverage
    }

    /// Reads the `aggregateWidth` aggregate columns starting at `offset`.
    static func readAggregate(_ row: SQLiteRow, from offset: Int32) -> Aggregate {
        let tokens = TokenCounts(uncachedInput: row.int(offset + 1), output: row.int(offset + 2),
                                 cacheRead: row.int(offset + 3), cacheCreation: row.int(offset + 4),
                                 cacheCreation5m: row.int(offset + 5), cacheCreation1h: row.int(offset + 6),
                                 reasoningOutput: row.int(offset + 7))
        var coverage = UsageCoverage()
        coverage.requests = Int(row.int(offset))
        coverage.missingUncachedInput = Int(row.int(offset + 10))
        coverage.missingCacheRead = Int(row.int(offset + 11))
        coverage.missingCacheCreation = Int(row.int(offset + 12))
        coverage.missingReasoning = Int(row.int(offset + 13))
        coverage.reconciledRequests = Int(row.int(offset + 14))
        coverage.partialRequests = Int(row.int(offset + 15))
        return Aggregate(requests: Int(row.int(offset)), tokens: tokens,
                         cost: EstimatedCost(picoUSD: row.int(offset + 8), unpricedTokens: row.int(offset + 9),
                             derivedTokens: row.int(offset + 16), userPricedTokens: row.int(offset + 17)),
                         coverage: coverage)
    }
}
