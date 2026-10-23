import Foundation

/// The OpenAI API list prices that the application ships with.
///
/// Every figure comes from OpenAI's own pricing page and changelog, fetched on `openAIAsOf`
/// (developers.openai.com/api/docs/pricing and developers.openai.com/api/docs/changelog). They are the pay-as-you-go
/// API prices, used to estimate what the same tokens would cost. They are not what a ChatGPT subscription charges.
///
/// How the cards are built:
///
/// - **Dates.** The pricing page shows only today's prices, and the changelog dates the changes. A card starts on the
///   day the model launched or the day its price last changed. The changelog gives days and not hours, so a request
///   within a day of a change can be priced by the neighbouring card.
/// - **Prompt size.** Prompts longer than 272,000 input tokens are billed at the long-context prices, for the whole
///   request. Input includes the cached part, which matches the way the application stores OpenAI's input.
/// - **Tiers.** `standard` is the default. `fast` is the tier that was called Priority until July 30, 2026, and `flex`
///   is billed at the same rates as the Batch API. Codex records which tier a session asked for, and a tier with no
///   card leaves the request unpriced instead of being priced as standard.
/// - **Reasoning** tokens are part of output and are priced once, as output.
/// - **Cache writes.** OpenAI's pricing page lists 30-minute and 12-hour cache-write prices for the GPT-5.6 and GPT-6
///   models (read 2026-10-23). Codex
///   has never reported a cache write in the data seen, and it would not say which of the two durations a write used,
///   so only GPT-6.1 Sol's 30-minute write price is carried. Every other card prices a write at its input price, which
///   is an approximation that has priced no token so far. If Codex ever reports writes, these cards need the real
///   write prices before the estimate can be trusted.
/// - **Derived cards.** OpenAI announced the cuts to GPT-5.6 Luna, Terra and Sol as percentages. The price before
///   each cut is the published price after it, divided by the announced reduction. Those cards are marked
///   `derived` and shown as such, and they have no long-context tier.
///
/// A model that is not in this list stays unpriced. In particular `codex-auto-review` is a name that Codex gives
/// to its automatic reviewer, OpenAI does not list it, and it is not assumed to be any model that is listed.
extension PricingCatalog {
    /// The day the OpenAI prices were read from OpenAI's pages.
    public static let openAIAsOf = "2026-10-23"

    /// Midnight UTC of a day, in milliseconds since the epoch.
    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Prompts longer than this many input tokens use the long-context prices.
    static let openAILongContextTokens: Int64 = 272_000

    static let openAI: [PriceRate] = {
        var rates: [PriceRate] = []
        let source = "OpenAI pricing page, read \(openAIAsOf)."

        /// One model, one tier, from one day. `long` is nil when the page shows no long-context price.
        func add(_ model: String, from: Int64, tier: String = "standard", basis: PriceBasis = .published,
                 short: (input: Double, cached: Double, output: Double), long: (input: Double, cached: Double, output: Double)? = nil,
                 write: Double? = nil, longWrite: Double? = nil, note: String? = nil) {
            let text = note.map { "\($0) \(source)" } ?? source
            func rate(_ p: (input: Double, cached: Double, output: Double), min: Int64, max: Int64?, writePrice: Double?) -> PriceRate {
                PriceRate(provider: .openAI, model: model, from: from, promptMin: min, promptMax: max, speed: tier,
                          input: p.input, output: p.output, cacheRead: p.cached, cache5m: writePrice ?? p.input, cache1h: writePrice ?? p.input,
                          basis: basis, note: text)
            }
            let boundary = openAILongContextTokens + 1
            rates.append(rate(short, min: 0, max: long == nil ? nil : boundary, writePrice: write))
            if let long { rates.append(rate(long, min: boundary, max: nil, writePrice: longWrite)) }
        }

        let gpt55Launch = day(2026, 4, 24), gpt56Launch = day(2026, 7, 9), cutJuly30 = day(2026, 7, 30)
        let solCut = day(2026, 8, 21), astra = day(2026, 9, 3), gpt6Sol = day(2026, 9, 22), gpt61Sol = day(2026, 9, 29)

        // Standard processing.
        add("gpt-5.5", from: gpt55Launch, short: (5, 0.50, 30), long: (10, 1, 45))
        add("gpt-5.6-sol", from: solCut, short: (4, 0.40, 20), long: (8, 0.80, 30),
            note: "Promotional price, announced as available at least through 2026-11-21.")
        add("gpt-5.6-terra", from: cutJuly30, short: (2, 0.20, 12), long: (4, 0.40, 18))
        add("gpt-5.6-luna", from: cutJuly30, short: (0.20, 0.02, 1.20), long: (0.40, 0.04, 1.80))
        add("gpt-6-astra", from: astra, short: (10, 1, 50), long: (20, 2, 75))
        add("gpt-6-sol", from: gpt6Sol, short: (2, 0.20, 10), long: (4, 0.40, 15))
        add("gpt-6-luna", from: gpt6Sol, short: (0.10, 0.01, 0.50), long: (0.20, 0.02, 0.75))
        add("gpt-6.1-sol", from: gpt61Sol, short: (2, 0.10, 10), long: (4, 0.20, 15), write: 2.50, longWrite: 5,
            note: "Cache writes use the published 30-minute write price: 2.50 up to 272,000 tokens and 5.00 above.")

        // Before the July 30 and August 21 cuts. These are derived from the announced percentages.
        let derived = "Derived: the price before the announced cut, worked out from the published price after it."
        add("gpt-5.6-luna", from: gpt56Launch, basis: .derived, short: (1, 0.10, 6), note: "\(derived) Luna was cut by 80% on 2026-07-30.")
        add("gpt-5.6-terra", from: gpt56Launch, basis: .derived, short: (2.50, 0.25, 15), note: "\(derived) Terra was cut by 20% on 2026-07-30.")
        add("gpt-5.6-sol", from: gpt56Launch, basis: .derived, short: (5, 0.50, 30), note: "\(derived) Sol was cut on 2026-08-21 to 4 and 20, announced as 20% lower input and 33% lower output. The output price of 30 assumes the 33% was one third; read literally it would be 29.85.")

        // Fast mode (named Priority before 2026-07-30).
        add("gpt-5.5", from: cutJuly30, tier: "fast", short: (12.50, 1.25, 75))
        add("gpt-5.6-sol", from: solCut, tier: "fast", short: (8, 0.80, 40), long: (16, 1.60, 60))
        add("gpt-5.6-terra", from: cutJuly30, tier: "fast", short: (4, 0.40, 24), long: (8, 0.80, 36))
        add("gpt-5.6-luna", from: cutJuly30, tier: "fast", short: (0.40, 0.04, 2.40), long: (0.80, 0.08, 3.60))
        add("gpt-6-astra", from: astra, tier: "fast", short: (20, 2, 100), long: (40, 4, 150))
        add("gpt-6-sol", from: gpt6Sol, tier: "fast", short: (4, 0.40, 20), long: (8, 0.80, 30))
        add("gpt-6-luna", from: gpt6Sol, tier: "fast", short: (0.20, 0.02, 1.00), long: (0.40, 0.04, 1.50))
        add("gpt-6.1-sol", from: gpt61Sol, tier: "fast", short: (4, 0.20, 20), long: (8, 0.40, 30))

        // Flex processing, billed at the Batch rates.
        add("gpt-5.5", from: gpt55Launch, tier: "flex", short: (2.50, 0.25, 15), long: (5, 0.50, 22.50))
        add("gpt-5.6-sol", from: solCut, tier: "flex", short: (2, 0.20, 10), long: (4, 0.40, 15))
        add("gpt-5.6-terra", from: cutJuly30, tier: "flex", short: (1, 0.10, 6), long: (2, 0.20, 9))
        add("gpt-5.6-luna", from: cutJuly30, tier: "flex", short: (0.10, 0.01, 0.60), long: (0.20, 0.02, 0.90))
        add("gpt-6-astra", from: astra, tier: "flex", short: (5, 0.50, 25), long: (10, 1, 37.50))
        add("gpt-6-sol", from: gpt6Sol, tier: "flex", short: (1, 0.10, 5), long: (2, 0.20, 7.50))
        add("gpt-6-luna", from: gpt6Sol, tier: "flex", short: (0.05, 0.005, 0.25), long: (0.10, 0.01, 0.375))
        add("gpt-6.1-sol", from: gpt61Sol, tier: "flex", short: (1, 0.05, 5), long: (2, 0.10, 7.50))
        return rates
    }()
}
