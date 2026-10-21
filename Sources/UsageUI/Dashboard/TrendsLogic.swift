import Foundation
import UsageCore

/// What the trend chart counts.
enum TrendMeasure: String, CaseIterable, Identifiable, Sendable {
    case fresh, processed, requests, sessions, cost
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fresh: String(localized: "New tokens")
        case .processed: String(localized: "Processed tokens")
        case .requests: String(localized: "Requests")
        case .sessions: String(localized: "Sessions")
        case .cost: String(localized: "Cost")
        }
    }

    var isTokens: Bool { self == .fresh || self == .processed }

    /// The figure of one aggregate. Sessions cannot be added up from buckets or rows that overlap, so their figure
    /// comes from a separate count and this returns nil.
    func value(tokens: TokenCounts, requests: Int, cost: EstimatedCost) -> Double? {
        switch self {
        case .fresh: Double(tokens.freshTokens)
        case .processed: Double(tokens.totalProcessed)
        case .requests: Double(requests)
        case .cost: cost.usdDouble
        case .sessions: nil
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .fresh, .processed: Fmt.tokens(Int64(v.rounded()))
        case .requests, .sessions: Fmt.grouped(Int64(v.rounded()))
        case .cost: Fmt.cost(EstimatedCost(picoUSD: Int64((v * 1e12).rounded())))
        }
    }
}

/// How the chart's bars are split into stacked parts.
enum TrendSplit: String, CaseIterable, Identifiable, Sendable {
    case total, provider, model, project, category
    var id: String { rawValue }

    var label: String {
        switch self {
        case .total: String(localized: "Total")
        case .provider: String(localized: "Provider")
        case .model: String(localized: "Model")
        case .project: String(localized: "Project")
        case .category: String(localized: "Token type")
        }
    }

    /// The splits that make sense for a measure. Sessions are counted per bucket only, and token types exist only for
    /// token measures.
    static func choices(for measure: TrendMeasure) -> [TrendSplit] {
        switch measure {
        case .sessions: [.total]
        case .fresh, .processed: allCases
        case .requests, .cost: [.total, .provider, .model, .project]
        }
    }

    var dimension: SeriesDimension {
        switch self {
        case .total, .category: .none
        case .provider: .provider
        case .model: .model
        case .project: .project
        }
    }
}

/// Where the color of a series comes from. The view resolves it, because entity colors are kept on the main actor.
enum TrendColor: Hashable, Sendable {
    case total
    case provider(ProviderID)
    case model(String)
    case project(String)
    case category(Int)
    case other
}

/// One stacked part of the chart, such as one model.
struct TrendSeries: Identifiable, Hashable, Sendable {
    var id: String
    /// The display name. Empty for a provider, whose name the view looks up.
    var name: String
    var color: TrendColor
}

/// One bar of the trend chart.
struct TrendBucket: Identifiable, Equatable, Sendable {
    var index: Int
    var start: Date
    var end: Date
    var values: [String: Double] = [:]
    var isFuture = false
    var isCurrent = false
    var id: Int { index }

    var total: Double { values.values.reduce(0, +) }

    /// The same bar in the form the overview's label helpers take.
    var overviewBucket: OverviewBucket {
        OverviewBucket(index: index, start: start, end: end, isFuture: isFuture, isCurrent: isCurrent)
    }
}

/// One row of the comparison with the previous period.
struct TrendChange: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var color: TrendColor
    var current: Double
    var previous: Double

    /// The relative change, or nil when there was nothing before.
    var ratio: Double? { previous > 0 ? current / previous - 1 : nil }
}

/// A figure of one entity in one period, for the comparison.
struct TrendRow: Sendable {
    var id: String
    var name: String
    var color: TrendColor
    var value: Double
}

enum TrendsLogic {
    /// The most series the chart stacks. The rest are folded into "Other", so that every color stays meaningful.
    static let maxSeries = 7

    /// Builds the chart's bars and the series stacked in them, bottom first.
    static func build(period: OverviewPeriod, now: Date, calendar: Calendar, measure: TrendMeasure, split: TrendSplit,
                      points: [SeriesPoint], sessions: [(start: Date, sessions: Int)]) -> (buckets: [TrendBucket], series: [TrendSeries]) {
        let starts = period.bucketStarts(now: now, calendar: calendar)
        var buckets = starts.enumerated().map { i, start in
            let end = calendar.date(byAdding: period.granularity.component, value: 1, to: start) ?? start
            return TrendBucket(index: i, start: start, end: end, isFuture: start > now, isCurrent: start <= now && now < end)
        }
        func index(of date: Date) -> Int? { buckets.firstIndex { $0.start <= date && date < $0.end } }

        let total = TrendSeries(id: "total", name: measure.label, color: .total)
        if measure == .sessions {
            for s in sessions { if let i = index(of: s.start) { buckets[i].values[total.id, default: 0] += Double(s.sessions) } }
            return (buckets, [total])
        }
        let split = TrendSplit.choices(for: measure).contains(split) ? split : .total

        switch split {
        case .total:
            for p in points {
                guard let i = index(of: p.start), let v = measure.value(tokens: p.tokens, requests: p.requests, cost: p.cost) else { continue }
                buckets[i].values[total.id, default: 0] += v
            }
            return (buckets, [total])
        case .category:
            var parts: [(TrendSeries, (TokenCounts) -> Int64)] = [
                (TrendSeries(id: "uncached", name: String(localized: "Uncached input"), color: .category(0)), { $0.uncachedInput }),
                (TrendSeries(id: "cacheWrite", name: String(localized: "Cache writes"), color: .category(3)), { $0.cacheCreation }),
                (TrendSeries(id: "output", name: String(localized: "Output"), color: .category(1)), { $0.output }),
            ]
            if measure == .processed {
                parts.append((TrendSeries(id: "cacheRead", name: String(localized: "Cache reads"), color: .category(2)), { $0.cacheRead }))
            }
            for p in points {
                guard let i = index(of: p.start) else { continue }
                for (series, f) in parts { buckets[i].values[series.id, default: 0] += Double(f(p.tokens)) }
            }
            return (buckets, parts.map(\.0))
        case .provider, .model, .project:
            var sums: [String: Double] = [:]
            var labels: [String: String] = [:]
            for p in points {
                guard index(of: p.start) != nil, let v = measure.value(tokens: p.tokens, requests: p.requests, cost: p.cost) else { continue }
                sums[p.key, default: 0] += v
                labels[p.key] = p.label
            }
            let ranked = sums.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
            let kept = Array(ranked.prefix(ranked.count > maxSeries ? maxSeries - 1 : maxSeries))
            let keptSet = Set(kept)
            var series = kept.map { key in
                TrendSeries(id: key, name: split == .provider ? "" : (labels[key] ?? key), color: color(of: key, split: split))
            }
            let other = TrendSeries(id: "other", name: String(localized: "Other"), color: .other)
            if kept.count < ranked.count { series.append(other) }
            for p in points {
                guard let i = index(of: p.start), let v = measure.value(tokens: p.tokens, requests: p.requests, cost: p.cost), v > 0 else { continue }
                buckets[i].values[keptSet.contains(p.key) ? p.key : other.id, default: 0] += v
            }
            return (buckets, series)
        }
    }

    static func color(of key: String, split: TrendSplit) -> TrendColor {
        switch split {
        case .provider: .provider(ProviderID(rawValue: key))
        case .model: .model(key)
        case .project: .project(key)
        default: .total
        }
    }

    /// The entities whose figure moved most since the previous period, largest move first.
    static func changes(current: [TrendRow], previous: [TrendRow], limit: Int = 6) -> [TrendChange] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, b in TrendRow(id: a.id, name: a.name, color: a.color, value: a.value + b.value) })
        var out = current.map { row in
            TrendChange(id: row.id, name: row.name, color: row.color, current: row.value, previous: before[row.id]?.value ?? 0)
        }
        let seen = Set(current.map(\.id))
        out += previous.filter { !seen.contains($0.id) }.map { TrendChange(id: $0.id, name: $0.name, color: $0.color, current: 0, previous: $0.value) }
        return Array(out.filter { $0.current != $0.previous }
            .sorted { (abs($0.current - $0.previous), $1.name) > (abs($1.current - $1.previous), $0.name) }
            .prefix(limit))
    }

    /// The change of one row in words: "↑ 23%", "↓ 40%", "New" or "None now".
    static func changeLabel(_ c: TrendChange) -> String {
        guard let ratio = c.ratio else { return String(localized: "New") }
        if c.current == 0 { return String(localized: "None now") }
        let pct = Int((abs(ratio) * 100).rounded())
        return ratio >= 0 ? "↑ \(pct)%" : "↓ \(pct)%"
    }

    /// The top of a scale: the value rounded up to 1, 2, 2.5 or 5 times a power of ten.
    static func niceCeiling(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let e = pow(10, floor(log10(v)))
        let m = v / e
        return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10) * e
    }
}

extension OverviewPeriod {
    /// What the trends page compares the period with, as a whole sentence.
    var comparedLine: String {
        switch self {
        case .today: String(localized: "Compared with yesterday by this time.")
        case .week: String(localized: "Compared with the 7 days before.")
        case .month: String(localized: "Compared with the 30 days before.")
        }
    }

    var unchangedLine: String {
        switch self {
        case .today: String(localized: "Nothing changed against yesterday by this time.")
        case .week: String(localized: "Nothing changed against the 7 days before.")
        case .month: String(localized: "Nothing changed against the 30 days before.")
        }
    }
}
