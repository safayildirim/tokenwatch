import Foundation

/// A rate card for one model, valid from a given time and for a given prompt size and speed.
///
/// Rates are stored as whole micro-USD per million tokens. Multiplying a token count by such a rate
/// gives an exact whole number of pico-USD, which keeps sums over millions of requests free of
/// floating point error.
public struct PriceRate: Sendable, Equatable {
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

    /// Builds a rate from dollar prices per million tokens.
    public init(model: String, from: Int64 = 0, promptMin: Int64 = 0, promptMax: Int64? = nil, speed: String = "standard",
                input: Double, output: Double, cacheRead: Double, cache5m: Double? = nil, cache1h: Double? = nil,
                note: String? = nil) {
        func micros(_ usd: Double) -> Int64 { Int64((usd * 1_000_000).rounded()) }
        self.modelKey = model
        self.effectiveFromMs = from
        self.promptMin = promptMin
        self.promptMax = promptMax
        self.speed = speed
        self.inputMicrosPerMTok = micros(input)
        self.outputMicrosPerMTok = micros(output)
        self.cacheReadMicrosPerMTok = micros(cacheRead)
        // Anthropic bills 5-minute cache writes at 1.25x and 1-hour writes at 2x the input rate.
        self.cache5mMicrosPerMTok = micros(cache5m ?? input * 1.25)
        self.cache1hMicrosPerMTok = micros(cache1h ?? input * 2)
        self.note = note
    }
}

/// The built-in API list prices.
///
/// These are the published per-token API prices. They estimate what the same usage would cost on
/// the pay-as-you-go API, and say nothing about subscription billing. Prices change, so rates are
/// dated: a new price is added as a new row with a later `effectiveFromMs` instead of editing an
/// old one, which keeps estimates for past usage stable.
///
/// A model that has no rate card is reported as unpriced; no generic price is ever substituted.
public enum PricingCatalog {
    public static let asOf = "2026-10-06"

    public static let builtin: [PriceRate] = {
        let src = "Anthropic list price, checked \(asOf)."
        var rates: [PriceRate] = []
        func add(_ m: String, _ i: Double, _ o: Double, _ cr: Double, note: String? = nil) {
            rates.append(PriceRate(model: m, input: i, output: o, cacheRead: cr, note: note ?? src))
        }
        add("claude-fable-5-1", 10, 50, 0.25)
        add("claude-fable-5", 10, 50, 1.00)
        add("claude-opus-5-5", 4, 20, 0.20)
        add("claude-opus-5", 5, 25, 0.50)
        add("claude-opus-4-8", 5, 25, 0.50)
        add("claude-opus-4-7", 5, 25, 0.50)
        add("claude-opus-4-6", 5, 25, 0.50)
        add("claude-sonnet-5-5", 2, 10, 0.20)
        add("claude-sonnet-5", 2, 10, 0.20)
        add("claude-sonnet-4-6", 3, 15, 0.30)
        add("claude-haiku-4-5", 1, 5, 0.10)

        // Haiku 5.5 has two rate cards, chosen by prompt length.
        let tierNote = "Two rate cards split at a 100K-token prompt. \(src)"
        rates.append(PriceRate(model: "claude-haiku-5-5", promptMin: 0, promptMax: 100_001,
                               input: 0.10, output: 0.50, cacheRead: 0.01, note: tierNote))
        rates.append(PriceRate(model: "claude-haiku-5-5", promptMin: 100_001, promptMax: nil,
                               input: 0.50, output: 2.50, cacheRead: 0.05, note: tierNote))

        // Fast mode is billed at twice the standard rate on the models that offer it.
        let fastNote = "Fast mode, billed at 2x the standard rate. \(src)"
        rates.append(PriceRate(model: "claude-opus-5-5", speed: "fast", input: 8, output: 40, cacheRead: 0.40, note: fastNote))
        rates.append(PriceRate(model: "claude-opus-5", speed: "fast", input: 10, output: 50, cacheRead: 1.00, note: fastNote))
        return rates
    }()
}

public enum PricingStore {
    /// A fingerprint of the built-in catalog, so that a changed catalog is reinstalled on the next launch.
    static var catalogFingerprint: String {
        var text = PricingCatalog.asOf
        for r in PricingCatalog.builtin {
            text += "|\(r.modelKey),\(r.promptMin),\(r.promptMax ?? -1),\(r.speed),\(r.inputMicrosPerMTok),\(r.outputMicrosPerMTok),\(r.cacheReadMicrosPerMTok),\(r.cache5mMicrosPerMTok),\(r.cache1hMicrosPerMTok)"
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
            try c.run("DELETE FROM price_rate WHERE origin = 'builtin'")
            for r in PricingCatalog.builtin { try insert(c, r, origin: "builtin") }
        }
    }

    /// Adds or replaces a user-defined rate card.
    public static func upsertUserRate(_ db: UsageDatabase, _ rate: PriceRate) throws {
        try db.write { c in
            try c.run("""
                DELETE FROM price_rate WHERE model_key = ? AND effective_from = ? AND prompt_min = ? AND speed = ?
                """, [.text(rate.modelKey), .int(rate.effectiveFromMs), .int(rate.promptMin), .text(rate.speed)])
            try insert(c, rate, origin: "user")
        }
    }

    private static func insert(_ c: SQLiteConnection, _ r: PriceRate, origin: String) throws {
        try c.run("""
            INSERT OR REPLACE INTO price_rate(model_key, effective_from, prompt_min, prompt_max, speed,
                input_micros_per_mtok, output_micros_per_mtok, cache_read_micros_per_mtok,
                cache_5m_micros_per_mtok, cache_1h_micros_per_mtok, origin, note)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(r.modelKey), .int(r.effectiveFromMs), .int(r.promptMin), .optional(r.promptMax), .text(r.speed),
                  .int(r.inputMicrosPerMTok), .int(r.outputMicrosPerMTok), .int(r.cacheReadMicrosPerMTok),
                  .int(r.cache5mMicrosPerMTok), .int(r.cache1hMicrosPerMTok), .text(origin), .optional(r.note)])
    }
}

/// SQL fragments that price requests inside analytical queries.
///
/// Costs are computed at query time from the rate card that was in effect when each request was
/// made, rather than stored on the request. That keeps the request records immutable while letting
/// a corrected rate card repair estimates.
enum CostSQL {
    /// Joins the effective rate card onto an aliased `model_request r`. Requires the `model m` join.
    static let join = """
        LEFT JOIN price_rate p ON p.id = (
            SELECT pr.id FROM price_rate pr
            WHERE pr.model_key = m.canonical AND pr.speed = COALESCE(r.speed, 'standard')
              AND pr.effective_from <= r.requested_at
              AND r.logical_input_tokens >= pr.prompt_min
              AND (pr.prompt_max IS NULL OR r.logical_input_tokens < pr.prompt_max)
            ORDER BY pr.effective_from DESC LIMIT 1)
        """

    /// Pico-USD cost of one request row. Cache writes whose TTL the source did not state are priced
    /// at the cheaper five-minute rate, which makes the estimate a lower bound for them.
    static let picoUSD = """
        COALESCE(r.input_tokens * p.input_micros_per_mtok
               + r.output_tokens * p.output_micros_per_mtok
               + r.cache_read_tokens * p.cache_read_micros_per_mtok
               + COALESCE(r.cache_creation_5m_tokens, 0) * p.cache_5m_micros_per_mtok
               + COALESCE(r.cache_creation_1h_tokens, 0) * p.cache_1h_micros_per_mtok
               + max(0, r.cache_creation_tokens - COALESCE(r.cache_creation_5m_tokens, 0) - COALESCE(r.cache_creation_1h_tokens, 0))
                 * p.cache_5m_micros_per_mtok, 0)
        """

    static let unpricedTokens = """
        CASE WHEN p.id IS NULL THEN r.logical_input_tokens + r.output_tokens ELSE 0 END
        """

    /// Column list that yields token sums, request count and cost, in the order `readTotals` expects.
    static let aggregateColumns = """
        count(r.id),
        COALESCE(sum(r.input_tokens), 0), COALESCE(sum(r.output_tokens), 0),
        COALESCE(sum(r.cache_read_tokens), 0), COALESCE(sum(r.cache_creation_tokens), 0),
        COALESCE(sum(COALESCE(r.cache_creation_5m_tokens, 0)), 0), COALESCE(sum(COALESCE(r.cache_creation_1h_tokens, 0)), 0),
        COALESCE(sum(\(picoUSD)), 0), COALESCE(sum(\(unpricedTokens)), 0)
        """

    /// Reads the nine aggregate columns starting at `offset`.
    static func readAggregate(_ row: SQLiteRow, from offset: Int32) -> (requests: Int, tokens: TokenCounts, cost: EstimatedCost) {
        let tokens = TokenCounts(uncachedInput: row.int(offset + 1), output: row.int(offset + 2),
                                 cacheRead: row.int(offset + 3), cacheCreation: row.int(offset + 4),
                                 cacheCreation5m: row.int(offset + 5), cacheCreation1h: row.int(offset + 6))
        return (Int(row.int(offset)), tokens, EstimatedCost(picoUSD: row.int(offset + 7), unpricedTokens: row.int(offset + 8)))
    }
}
