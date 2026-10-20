import Foundation

/// The built-in API list prices.
///
/// These are the published per-token API prices. They estimate what the same usage would cost on
/// the pay-as-you-go API, and say nothing about subscription billing. Prices change, so rates are
/// dated: a new price is added as a new row with a later `effectiveFromMs` instead of editing an
/// old one, which keeps estimates for past usage stable.
///
/// A model that has no rate card is reported as unpriced; no generic price is ever substituted. Only
/// Anthropic list prices are built in. No OpenAI rate card ships with the application, because its prices
/// could not be verified from this Mac, so OpenAI usage is shown as unpriced until the user adds a card.
public enum PricingCatalog {
    public static let asOf = "2026-10-06"

    public static let builtin: [PriceRate] = {
        let src = "Anthropic list price, checked \(asOf)."
        var rates: [PriceRate] = []
        func add(_ m: String, _ i: Double, _ o: Double, _ cr: Double, note: String? = nil) {
            rates.append(PriceRate(provider: .anthropic, model: m, input: i, output: o, cacheRead: cr, note: note ?? src))
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
        rates.append(PriceRate(provider: .anthropic, model: "claude-haiku-5-5", promptMin: 0, promptMax: 100_001,
                               input: 0.10, output: 0.50, cacheRead: 0.01, note: tierNote))
        rates.append(PriceRate(provider: .anthropic, model: "claude-haiku-5-5", promptMin: 100_001, promptMax: nil,
                               input: 0.50, output: 2.50, cacheRead: 0.05, note: tierNote))

        // Fast mode is billed at twice the standard rate on the models that offer it.
        let fastNote = "Fast mode, billed at 2x the standard rate. \(src)"
        rates.append(PriceRate(provider: .anthropic, model: "claude-opus-5-5", speed: "fast", input: 8, output: 40, cacheRead: 0.40, note: fastNote))
        rates.append(PriceRate(provider: .anthropic, model: "claude-opus-5", speed: "fast", input: 10, output: 50, cacheRead: 1.00, note: fastNote))
        return rates
    }()
}

