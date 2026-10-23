import Foundation

/// The kinds of statement the insights layer can make. Each one is produced by a fixed rule from stored numbers, so the same
/// data always gives the same statements.
public enum InsightKind: String, Sendable, Codable {
    /// The allowance may run out before the reset.
    case mayExhaustAllowance
    /// The forecast ends close to the limit without reaching it.
    case forecastNearLimit
    /// The latest finished cycle used more or fewer local tokens than the one before.
    case tokensChangedVersusPreviousCycle
    /// The first days of this cycle used more or fewer local tokens than the same days of the previous cycle.
    case tokensChangedSameDays
    /// The observed quota pace differs from the previous cycle, and the two cycles are directly comparable.
    case quotaPaceChanged
    /// One day carried a large share of a cycle's local tokens.
    case busiestDay
    /// One model carried most of a cycle's local tokens.
    case topModel
    /// Cache reads were most of the processed tokens.
    case cacheReadShare
    /// Earlier cycles used most of their local tokens in the first days.
    case frontLoadedUsage
    /// The current pace differs from the historical average.
    case paceVersusHistory
    /// The previous cycle's quota was observed only in part.
    case quotaObservationLimited
    /// Earlier cycles reached the limit.
    case limitReachedBefore
    /// Part of the local activity names no account, so a ratio cannot be measured for this account.
    case localUsagePartlyUnattributed
}

public struct UsageInsight: Sendable, Equatable, Identifiable {
    public var kind: InsightKind
    /// Higher means more useful for a decision. Insights are shown in this order.
    public var priority: Int
    /// The numbers behind the statement, so that it can be checked against the data.
    public var values: [String: Double]
    public var names: [String: String]
    public var date: Date?
    public var id: String { kind.rawValue }
}

public enum UsageInsightsEngine {
    public static let maximumInsights = 5

    /// The few statements that the data supports and that help with a decision. Small fluctuations produce nothing.
    public static func insights(report: SubscriptionUsageReport, forecast: UsageForecast, now: Date = Date()) -> [UsageInsight] {
        var out: [UsageInsight] = []
        let past = report.cycles.filter { $0.timing == .past && !$0.local.isEmpty }
        if let cycle = report.currentCycle ?? report.cycles.last(where: { $0.timing == .past }),
           [.partlyAttributed, .unattributed].contains(cycle.attribution), let share = cycle.attributedShare {
            out.append(UsageInsight(kind: .localUsagePartlyUnattributed, priority: 65, values: ["share": share,
                                    "tokens": Double(cycle.unattributed.processedTokens)], names: [:], date: cycle.span.start))
        }
        let current = report.currentCycle
        // Statements that compare one cycle with another say little when a cycle lasts hours, so they need a window of days.
        let longWindow = (report.subject.windowMinutes ?? 0) >= 2 * 1440

        if forecast.isAvailable {
            if let exhaustion = forecast.exhaustion {
                out.append(UsageInsight(kind: .mayExhaustAllowance, priority: 100,
                                        values: ["likely": exhaustion.confidence == .likely ? 1 : 0,
                                                 "earliest": exhaustion.earliest.timeIntervalSince1970,
                                                 "latest": exhaustion.latest?.timeIntervalSince1970 ?? 0,
                                                 "cycleEnd": forecast.cycleEnd?.timeIntervalSince1970 ?? 0],
                                        names: [:], date: exhaustion.earliest))
            } else if let high = forecast.high, high >= 90 {
                out.append(UsageInsight(kind: .forecastNearLimit, priority: 90,
                                        values: ["low": forecast.low ?? 0, "high": high], names: [:], date: forecast.cycleEnd))
            }
        }

        if longWindow, let last = past.last, let before = past.dropLast().last {
            let comparison = CycleComparisonEngine.compare(CycleMetrics(before), CycleMetrics(last))
            if let change = comparison.processedChange, abs(change) >= 0.20, before.local.processedTokens >= 1_000_000 {
                out.append(UsageInsight(kind: .tokensChangedVersusPreviousCycle, priority: 70,
                                        values: ["change": change, "comparable": comparison.isDirectlyComparable ? 1 : 0],
                                        names: [:], date: last.span.start))
            }
            if let change = comparison.quotaPaceChange, abs(change) >= 0.25 {
                out.append(UsageInsight(kind: .quotaPaceChanged, priority: 75, values: ["change": change], names: [:], date: last.span.start))
            }
        }

        if longWindow, let current, let previous = past.last, current.span.length >= 2 * 86_400 {
            let elapsedDays = min(Int(now.timeIntervalSince(current.span.start) / 86_400), current.days.count, previous.days.count)
            if elapsedDays >= 2 {
                let currentSum = current.days.prefix(elapsedDays).reduce(Int64(0)) { $0 + $1.local.processedTokens }
                let previousSum = previous.days.prefix(elapsedDays).reduce(Int64(0)) { $0 + $1.local.processedTokens }
                if previousSum >= 1_000_000, abs(Double(currentSum) / Double(previousSum) - 1) >= 0.20 {
                    out.append(UsageInsight(kind: .tokensChangedSameDays, priority: 80,
                                            values: ["change": Double(currentSum) / Double(previousSum) - 1, "days": Double(elapsedDays)],
                                            names: [:], date: current.span.start))
                }
            }
            if past.count >= 3 {
                let perDay = past.suffix(4).compactMap { cycle -> Double? in
                    cycle.span.length > 0 ? Double(cycle.local.processedTokens) / (cycle.span.length / 86_400) : nil
                }
                let elapsed = max(now.timeIntervalSince(current.span.start), 86_400) / 86_400
                let currentPerDay = Double(current.local.processedTokens) / elapsed
                if elapsed >= 2, !perDay.isEmpty {
                    let average = perDay.reduce(0, +) / Double(perDay.count)
                    if average > 0, abs(currentPerDay / average - 1) >= 0.25 {
                        out.append(UsageInsight(kind: .paceVersusHistory, priority: 60,
                                                values: ["change": currentPerDay / average - 1], names: [:], date: nil))
                    }
                }
            }
        }

        let latestWithDays = (current.map { [$0] } ?? []) + past.reversed()
        if let cycle = latestWithDays.first(where: { $0.days.filter { $0.local.requests > 0 }.count >= 3 }),
           let busiest = cycle.days.max(by: { $0.local.processedTokens < $1.local.processedTokens }),
           busiest.shareOfCycleProcessed >= 0.25 {
            out.append(UsageInsight(kind: .busiestDay, priority: 40,
                                    values: ["share": busiest.shareOfCycleProcessed, "index": Double(busiest.index)],
                                    names: [:], date: busiest.start))
        }
        if let cycle = current ?? past.last, let top = cycle.local.models.first, top.share >= 0.40 {
            out.append(UsageInsight(kind: .topModel, priority: 35, values: ["share": top.share], names: ["model": top.displayName], date: nil))
        }
        if let cycle = current ?? past.last, !cycle.local.isEmpty, let share = cycle.local.tokens.cacheHitRatio, share >= 0.90 {
            out.append(UsageInsight(kind: .cacheReadShare, priority: 30, values: ["share": share], names: [:], date: nil))
        }

        let frontShares = past.suffix(6).compactMap { cycle -> Double? in
            guard cycle.days.count >= 7, cycle.local.processedTokens > 0 else { return nil }
            return cycle.days.prefix(3).reduce(0) { $0 + $1.shareOfCycleProcessed }
        }
        if longWindow, frontShares.count >= 3, let median = ConsumptionEfficiency.percentile(frontShares.sorted(), 0.5), median >= 0.55 {
            out.append(UsageInsight(kind: .frontLoadedUsage, priority: 45, values: ["share": median, "cycles": Double(frontShares.count)],
                                    names: [:], date: nil))
        }

        let limitCycles = past.filter { $0.quota?.reachedLimit == true }.count
        if limitCycles > 0 {
            out.append(UsageInsight(kind: .limitReachedBefore, priority: 50,
                                    values: ["cycles": Double(limitCycles), "of": Double(past.count)], names: [:], date: nil))
        }
        if let last = report.cycles.last(where: { $0.timing == .past }), let quota = last.quota, quota.completeness != .complete {
            out.append(UsageInsight(kind: .quotaObservationLimited, priority: 20,
                                    values: ["startObserved": quota.startObserved ? 1 : 0, "endObserved": quota.endObserved ? 1 : 0,
                                             "coverage": quota.coverage.supportedFraction], names: [:], date: last.span.start))
        }

        return Array(out.sorted { ($1.priority, $0.id) < ($0.priority, $1.id) }.prefix(maximumInsights))
    }
}
