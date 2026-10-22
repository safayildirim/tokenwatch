import Foundation

/// Compares purchasing strategies, not just plans.
///
/// A strategy may contain more than one independent subscription. That is an aggregate across
/// separate quota pools: two 5x subscriptions do not make one 10x pool, and the interface must say
/// so. The comparison is done in relative capacity units, using a chosen base plan for nominal and
/// measured capacity.
public enum CapacityStrategyAnalyzer {
    public static func compare(db: UsageDatabase, provider: ProviderID, poolKey: String,
                               window: CapacityWindowReport,
                               registryPlans: [SubscriptionPlanDefinition],
                               strategies: [SubscriptionStrategy],
                               basePlanKey: String?) -> CapacityStrategyComparison? {
        var plans: [String: SubscriptionPlanDefinition] = [:]
        for plan in registryPlans { plans[plan.key] = plan }
        let usable = strategies.filter { plans[$0.planKey] != nil }
        guard !usable.isEmpty else { return nil }
        let base = basePlanKey.flatMap { plans[$0] != nil ? $0 : nil }
            ?? advertisedBaseline(window: window, strategies: usable, plans: plans)
            ?? mostObservedPlan(window: window, strategies: usable)
            ?? usable[0].planKey
        var quotes: [String: PlanPriceQuote] = [:]
        for plan in registryPlans { quotes[plan.key] = PlanPriceStore.quote(db, plan: plan) }

        var rows: [StrategyCostRow] = []
        var measuredMissing: [String] = []
        for strategy in usable {
            guard let plan = plans[strategy.planKey], let quote = quotes[strategy.planKey] else { continue }
            let monthlyPrice = quote.monthlyPriceMicros
            let monthlyCost = monthlyPrice.multipliedReportingOverflow(by: Int64(strategy.count))
            let totalCost = monthlyCost.overflow ? Int64.max : monthlyCost.partialValue
            let relative = measuredRelative(planKey: strategy.planKey, basePlanKey: base, window: window)
            if relative == nil { measuredMissing.append(strategy.name) }
            let measured = relative.map { $0 * Double(strategy.count) }
            var nominal: Double?
            if let minutes = window.windowMinutes, let multiplier = plan.nominalMultiplier(minutes: minutes),
               let baseMultiplier = plans[base]?.nominalMultiplier(minutes: minutes), baseMultiplier > 0 {
                // Normalize to the chosen baseline so the advertised and measured columns use the
                // same unit: a multiple of one baseline plan's capacity, including subscription count.
                nominal = multiplier / baseMultiplier * Double(strategy.count)
            }
            let costDollars = Double(totalCost) / 1_000_000
            var measuredPerDollar: Double?
            if let measured, costDollars > 0 { measuredPerDollar = measured / costDollars }
            rows.append(StrategyCostRow(
                strategy: strategy, plan: plan, monthlyPriceMicros: monthlyPrice, monthlyCostMicros: totalCost,
                priceOrigin: quote.origin,
                nominalCapacityByWindow: [:], measuredCapacityByWindow: [:],
                measuredCapacityPerDollar: [:]))
            // The dictionaries are keyed by window length; a missing measurement stays absent.
            if let minutes = window.windowMinutes {
                if let measured { rows[rows.count - 1].measuredCapacityByWindow[minutes] = measured }
                if let nominal { rows[rows.count - 1].nominalCapacityByWindow[minutes] = nominal }
                if let measuredPerDollar { rows[rows.count - 1].measuredCapacityPerDollar[minutes] = measuredPerDollar }
            }
        }

        var breakEvens: [StrategyBreakEven] = []
        for a in rows {
            for b in rows where a.id != b.id {
                let required = a.monthlyCostMicros > 0 ? Double(b.monthlyCostMicros) / Double(a.monthlyCostMicros) : nil
                let ca = measured(a, window: window)
                let cb = measured(b, window: window)
                let measuredRatio = ca.flatMap { ca in cb.map { $0 / ca } }
                breakEvens.append(StrategyBreakEven(
                    numeratorStrategyID: b.id, denominatorStrategyID: a.id,
                    windowKey: window.windowKey, windowMinutes: window.windowMinutes,
                    requiredRatio: required, measuredRatio: measuredRatio,
                    estimatedMonthlyCostMicros1: a.monthlyCostMicros,
                    estimatedMonthlyCostMicros2: b.monthlyCostMicros))
            }
        }

        let nominalComplete = rows.allSatisfy { row in
            guard let minutes = window.windowMinutes else { return false }
            return row.nominalCapacityByWindow[minutes] != nil
        }
        let measuredComplete = measuredMissing.isEmpty && window.windowMinutes != nil
        let nominalLeader = window.windowMinutes != nil && nominalComplete ? rows.max { lhs, rhs in
            (lhs.nominalCapacityByWindow[window.windowMinutes ?? 0] ?? 0) / max(1, Double(lhs.monthlyCostMicros))
                < (rhs.nominalCapacityByWindow[window.windowMinutes ?? 0] ?? 0) / max(1, Double(rhs.monthlyCostMicros))
        }?.id : nil
        let measuredLeader = measuredComplete ? rows.max { lhs, rhs in
            (lhs.measuredCapacityPerDollar[window.windowMinutes ?? 0] ?? 0)
                < (rhs.measuredCapacityPerDollar[window.windowMinutes ?? 0] ?? 0)
        }?.id : nil

        var caveats: [String] = []
        if usable.contains(where: { $0.count > 1 }) {
            caveats.append(String(localized: "A strategy with more than one subscription means separate quota pools. Their allowances are aggregated for this comparison, never merged into one pool."))
        }
        if !measuredMissing.isEmpty {
            caveats.append(String(localized: "No measured capacity is available for: \(measuredMissing.joined(separator: ", ")). The purchasing decision uses only complete strategies."))
        }
        if window.samples.isEmpty {
            caveats.append(String(localized: "This window has no usable measurement cycles yet, so only advertised reference values are shown."))
        }
        return CapacityStrategyComparison(provider: provider, poolKey: poolKey, windowKey: window.windowKey,
                                          windowMinutes: window.windowMinutes, basePlanKey: base,
                                          rows: rows, breakEvens: breakEvens,
                                          measuredLeaderID: measuredLeader, nominalLeaderID: nominalLeader,
                                          caveats: caveats)
    }

    /// Capacity of `planKey` relative to `basePlanKey` in this window.
    public static func measuredRelative(planKey: String, basePlanKey: String,
                                        window: CapacityWindowReport) -> Double? {
        if planKey == basePlanKey {
            // The identity is only a measured unit if the baseline plan itself has usable cycles.
            return window.samples.contains { $0.planKey == planKey } ? 1 : nil
        }
        guard let estimate = window.estimates.first(where: {
            $0.basePlanKey == basePlanKey && $0.otherPlanKey == planKey && $0.windowKey == window.windowKey
        }) else { return nil }
        return estimate.ratio
    }

    public static func measured(_ row: StrategyCostRow, window: CapacityWindowReport) -> Double? {
        guard let minutes = window.windowMinutes else { return nil }
        return row.measuredCapacityByWindow[minutes]
    }

    /// The smallest advertised plan among the strategies that actually occur in this window. Using
    /// the same baseline as the ratio chart keeps the buying comparison and the chart comparable;
    /// "most observed" would silently flip the baseline when the larger plan had more cycles.
    private static func advertisedBaseline(window: CapacityWindowReport,
                                           strategies: [SubscriptionStrategy],
                                           plans: [String: SubscriptionPlanDefinition]) -> String? {
        let candidates = Set(strategies.map(\.planKey)).filter {
            window.planKeys.contains($0) && plans[$0]?.nominalMultiplier(minutes: 300) != nil
        }
        return candidates.min {
            (plans[$0]?.nominalMultiplier(minutes: 300) ?? 0, $0)
                < (plans[$1]?.nominalMultiplier(minutes: 300) ?? 0, $1)
        }
    }

    private static func mostObservedPlan(window: CapacityWindowReport, strategies: [SubscriptionStrategy]) -> String? {
        let counts = Dictionary(grouping: window.samples, by: \.planKey).mapValues(\.count)
        let candidates = Set(strategies.map(\.planKey))
        return counts.filter { candidates.contains($0.key) }
            .max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key
    }
}
