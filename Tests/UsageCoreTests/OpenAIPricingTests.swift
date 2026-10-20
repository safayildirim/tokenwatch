import XCTest
@testable import UsageCore

private typealias CF = CodexFixture

/// The built-in OpenAI prices, and what they do and do not cover.
final class OpenAIPricingTests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Int64 {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return Int64(c.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!.timeIntervalSince1970 * 1000)
    }

    /// Prices one response of a model at a time, in a session that asked for `tier`.
    private func price(model: String, at ms: Int64, tier: String? = nil, input: Int64 = 200_000, cached: Int64 = 80_000,
                       output: Int64 = 20_000, reasoning: Int64 = 6_000) throws -> EstimatedCost {
        let env = try TestEnv()
        let u = CF.Usage(input: input, cached: cached, output: output, reasoning: reasoning)
        try env.codexFile(session: CF.sessionA, lines: [
            CF.header(id: CF.sessionA, at: ms - 5000), CF.settings(ordinal: 1, at: ms - 4000, model: model, tier: tier),
            CF.tokenCount(ordinal: 2, at: ms, last: u, total: u),
        ])
        try env.syncCodex()
        return try env.totals().cost
    }

    /// Dollars, from the exact picodollar figure.
    private func usd(_ c: EstimatedCost) -> Decimal { c.usd }

    func testPublishedStandardPriceIsAppliedToEachCategory() throws {
        // 120,000 uncached input at 2.00, 80,000 cached at 0.20, 20,000 output at 12.00 (reasoning is inside output).
        let cost = try price(model: "gpt-5.6-terra", at: day(2026, 10, 1))
        XCTAssertEqual(usd(cost), Decimal(string: "0.24")! + Decimal(string: "0.016")! + Decimal(string: "0.24")!)
        XCTAssertEqual(cost.unpricedTokens, 0)
        XCTAssertEqual(cost.derivedTokens, 0)
    }

    func testReasoningTokensAreNotPricedASecondTime() throws {
        let withReasoning = try price(model: "gpt-6.1-sol", at: day(2026, 10, 10), reasoning: 90_000)
        let without = try price(model: "gpt-6.1-sol", at: day(2026, 10, 10), reasoning: 0)
        XCTAssertEqual(withReasoning.picoUSD, without.picoUSD)
    }

    func testAPriceChangeAppliesFromItsDayAndEarlierUsageKeepsTheEarlierPrice() throws {
        // Terra was cut by 20% on 2026-07-30: 2.50 / 0.25 / 15 before, 2.00 / 0.20 / 12 after.
        let before = try price(model: "gpt-5.6-terra", at: day(2026, 7, 20))
        let after = try price(model: "gpt-5.6-terra", at: day(2026, 8, 1))
        XCTAssertEqual(usd(before), Decimal(string: "0.30")! + Decimal(string: "0.02")! + Decimal(string: "0.30")!)
        XCTAssertEqual(usd(after), Decimal(string: "0.24")! + Decimal(string: "0.016")! + Decimal(string: "0.24")!)
        // The estimate for the same request is the same whenever it is computed.
        XCTAssertEqual(try price(model: "gpt-5.6-terra", at: day(2026, 7, 20)), before)
    }

    func testPricesWorkedOutFromAnnouncedCutsAreLabelledAsDerived() throws {
        let before = try price(model: "gpt-5.6-luna", at: day(2026, 7, 25))
        XCTAssertEqual(before.derivedTokens, 220_000, "the tokens priced with a derived card are counted")
        let after = try price(model: "gpt-5.6-luna", at: day(2026, 9, 1))
        XCTAssertEqual(after.derivedTokens, 0)
        let env = try TestEnv()
        let derived = try env.db.read { try $0.scalarInt("SELECT count(*) FROM price_rate WHERE origin = 'derived'") }
        XCTAssertEqual(derived, 3, "one derived card each for Luna, Terra and Sol")
    }

    func testPromptsAbove272KTokensUseTheLongContextPrice() throws {
        let short = try price(model: "gpt-6.1-sol", at: day(2026, 10, 10), input: 272_000, cached: 0, output: 0, reasoning: 0)
        let long = try price(model: "gpt-6.1-sol", at: day(2026, 10, 10), input: 272_001, cached: 0, output: 0, reasoning: 0)
        XCTAssertEqual(usd(short), Decimal(272_000) * 2 / 1_000_000)
        XCTAssertEqual(usd(long), Decimal(272_001) * 4 / 1_000_000, "the whole request is billed at the long-context price")
    }

    func testTheFastTierHasItsOwnPriceAndAnUnknownTierIsNotPricedAsStandard() throws {
        let standard = try price(model: "gpt-6.1-sol", at: day(2026, 10, 10))
        let fast = try price(model: "gpt-6.1-sol", at: day(2026, 10, 10), tier: "fast")
        XCTAssertEqual(fast.picoUSD, standard.picoUSD * 2, "Fast mode is billed at twice the standard rate for this model")
        XCTAssertEqual(try price(model: "gpt-6.1-sol", at: day(2026, 10, 10), tier: "priority"), fast, "priority is the old name of fast")
        let unknown = try price(model: "gpt-6.1-sol", at: day(2026, 10, 10), tier: "turbo")
        XCTAssertEqual(unknown.picoUSD, 0)
        XCTAssertEqual(unknown.unpricedTokens, 220_000)
        XCTAssertEqual(try price(model: "gpt-6.1-sol", at: day(2026, 10, 10), tier: "auto"), standard)
    }

    func testAModelBeforeItsLaunchOrOutsideTheListIsUnpriced() throws {
        XCTAssertEqual(try price(model: "gpt-6.1-sol", at: day(2026, 9, 1)).picoUSD, 0, "not launched yet")
        for name in ["codex-auto-review", "gpt-5.6-sol-high", "gpt-6", "GPT-ASTRA", "gpt-5.5-2026-04-24"] {
            let cost = try price(model: name, at: day(2026, 10, 10))
            XCTAssertEqual(cost.picoUSD, 0, name)
            XCTAssertEqual(cost.unpricedTokens, 220_000, name)
        }
    }

    func testAPriceTheUserEntersWinsAndIsLabelled() throws {
        let env = try TestEnv()
        try PricingStore.upsertUserRate(env.db, PriceRate(provider: .openAI, model: "codex-auto-review", input: 1, output: 4, cacheRead: 0.1, note: "mine"))
        let u = CF.Usage(input: 1_000_000, cached: 0, output: 0)
        try env.codexFile(session: CF.sessionA, lines: [CF.header(id: CF.sessionA, at: t0), CF.settings(ordinal: 1, at: t0 + 10, model: "codex-auto-review", tier: nil),
                                                          CF.tokenCount(ordinal: 2, at: t0 + 1000, last: u, total: u)])
        try env.syncCodex()
        let cost = try env.totals().cost
        XCTAssertEqual(cost.usd, 1)
        XCTAssertEqual(cost.userPricedTokens, 1_000_000)
        XCTAssertEqual(cost.unpricedTokens, 0)
    }

    func testCatalogIsConsistent() {
        let cards = PricingCatalog.openAI
        let keys = cards.map { "\($0.modelKey)|\($0.speed)|\($0.promptMin)|\($0.effectiveFromMs)" }
        XCTAssertEqual(keys.count, Set(keys).count, "no two cards for the same model, tier, size and day")
        for card in cards {
            XCTAssertEqual(card.provider, .openAI)
            XCTAssertGreaterThan(card.inputMicrosPerMTok, 0)
            XCTAssertGreaterThanOrEqual(card.inputMicrosPerMTok, card.cacheReadMicrosPerMTok, card.modelKey)
            if card.speed == "fast" { XCTAssertGreaterThanOrEqual(card.effectiveFromMs, day(2026, 7, 30, hour: 0), "Fast mode took over from Priority on 2026-07-30") }
        }
        XCTAssertFalse(cards.contains { $0.modelKey.contains("auto-review") })
    }
}
