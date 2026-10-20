import Foundation

/// Raw token categories for one request, or the sum over many requests.
///
/// The categories follow the Anthropic usage object, where `input_tokens` counts only the input
/// that was neither read from nor written to the prompt cache. The metrics derived from them are
/// therefore defined as follows.
///
/// - `logicalInput = uncachedInput + cacheRead + cacheCreation`. This is every token the model read,
///   whether or not caching was involved.
/// - `totalProcessed = logicalInput + output`.
/// - `freshTokens = uncachedInput + cacheCreation + output`. This is everything except tokens served
///   from the cache, which is the closest measure of "new work" and is far smaller than
///   `totalProcessed` in long agentic sessions.
/// - `cacheHitRatio = cacheRead / logicalInput`.
/// - `outputToInputRatio = output / logicalInput`.
///
/// `reasoningOutput` is the part of `output` that was spent on reasoning. It is already included in `output`
/// and is never added to any total.
///
/// These definitions describe the application's canonical categories. Each provider's adapter converts what
/// its source reports into them (OpenAI's input includes cached tokens, Anthropic's does not), so the
/// formulas here hold for every provider. Tokenizers differ between providers, so totals compared across
/// providers show volume, not equal computational effort or equal cost.
public struct TokenCounts: Sendable, Equatable, Codable, Hashable {
    public var uncachedInput: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheCreation: Int64
    /// The portion of `cacheCreation` that the source reported as five-minute writes. For a sum
    /// this only covers requests whose source exposed the split.
    public var cacheCreation5m: Int64
    /// The portion of `cacheCreation` that the source reported as one-hour writes.
    public var cacheCreation1h: Int64
    /// The part of `output` spent on reasoning, where the source reports it.
    public var reasoningOutput: Int64

    public init(uncachedInput: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0,
                cacheCreation: Int64 = 0, cacheCreation5m: Int64 = 0, cacheCreation1h: Int64 = 0, reasoningOutput: Int64 = 0) {
        self.uncachedInput = uncachedInput
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.cacheCreation5m = cacheCreation5m
        self.cacheCreation1h = cacheCreation1h
        self.reasoningOutput = reasoningOutput
    }

    public static let zero = TokenCounts()

    public var logicalInput: Int64 { uncachedInput + cacheRead + cacheCreation }
    public var totalProcessed: Int64 { logicalInput + output }
    public var freshTokens: Int64 { uncachedInput + cacheCreation + output }

    /// Cache-creation tokens whose TTL the source did not state.
    public var cacheCreationUnsplit: Int64 { max(0, cacheCreation - cacheCreation5m - cacheCreation1h) }

    public var cacheHitRatio: Double? {
        logicalInput > 0 ? Double(cacheRead) / Double(logicalInput) : nil
    }

    public var outputToInputRatio: Double? {
        logicalInput > 0 ? Double(output) / Double(logicalInput) : nil
    }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(uncachedInput: a.uncachedInput + b.uncachedInput, output: a.output + b.output,
                    cacheRead: a.cacheRead + b.cacheRead, cacheCreation: a.cacheCreation + b.cacheCreation,
                    cacheCreation5m: a.cacheCreation5m + b.cacheCreation5m,
                    cacheCreation1h: a.cacheCreation1h + b.cacheCreation1h, reasoningOutput: a.reasoningOutput + b.reasoningOutput)
    }

    public static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

/// An estimated API-equivalent cost. The value is an exact integer count of pico-USD (10^-12 USD)
/// so that sums across millions of requests never accumulate floating point error.
public struct EstimatedCost: Sendable, Equatable, Codable, Hashable {
    public var picoUSD: Int64
    /// Tokens (logical input plus output) that could not be priced because no rate card exists for
    /// their model. A non-zero value means `picoUSD` is a lower bound.
    public var unpricedTokens: Int64

    public init(picoUSD: Int64 = 0, unpricedTokens: Int64 = 0) {
        self.picoUSD = picoUSD
        self.unpricedTokens = unpricedTokens
    }

    public static let zero = EstimatedCost()

    public var usd: Decimal { Decimal(picoUSD) / Decimal(1_000_000_000_000) }
    public var usdDouble: Double { Double(picoUSD) / 1e12 }
    public var isPartial: Bool { unpricedTokens > 0 }

    public static func + (a: EstimatedCost, b: EstimatedCost) -> EstimatedCost {
        EstimatedCost(picoUSD: a.picoUSD + b.picoUSD, unpricedTokens: a.unpricedTokens + b.unpricedTokens)
    }
}

/// How many of the requests behind an aggregate lacked each category.
///
/// Sums treat a missing category as zero, which would hide the gap. This type keeps it visible, so the
/// interface can show a dash instead of a misleading "0" for a ratio that cannot be computed.
public struct UsageCoverage: Sendable, Equatable, Codable {
    public var requests = 0
    public var missingUncachedInput = 0
    public var missingCacheRead = 0
    public var missingCacheCreation = 0
    public var missingReasoning = 0
    /// Requests whose usage was derived from cumulative counters instead of taken from a per-request report.
    public var reconciledRequests = 0
    /// Requests that are known to lack some categories.
    public var partialRequests = 0

    public init() {}

    public var cacheReadKnown: Bool { requests > 0 && missingCacheRead < requests }
    public var reasoningKnown: Bool { requests > 0 && missingReasoning < requests }
    /// True when every request reported every cache category.
    public var isComplete: Bool { missingCacheRead == 0 && missingCacheCreation == 0 && partialRequests == 0 }

    public static func + (a: UsageCoverage, b: UsageCoverage) -> UsageCoverage {
        var r = UsageCoverage()
        r.requests = a.requests + b.requests
        r.missingUncachedInput = a.missingUncachedInput + b.missingUncachedInput
        r.missingCacheRead = a.missingCacheRead + b.missingCacheRead
        r.missingCacheCreation = a.missingCacheCreation + b.missingCacheCreation
        r.missingReasoning = a.missingReasoning + b.missingReasoning
        r.reconciledRequests = a.reconciledRequests + b.reconciledRequests
        r.partialRequests = a.partialRequests + b.partialRequests
        return r
    }
}
