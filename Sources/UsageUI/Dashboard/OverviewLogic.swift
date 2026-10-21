import Foundation
import UsageCore

/// The periods that the overview can show. Each one is compared with the period of the same length just before it.
enum OverviewPeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week = "7d", month = "30d"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: String(localized: "Today")
        case .week: String(localized: "7 Days")
        case .month: String(localized: "30 Days")
        }
    }

    /// The heading of the summary tiles, and the period line of the project details.
    var title: String {
        switch self {
        case .today: String(localized: "Today so far")
        case .week: String(localized: "Last 7 days")
        case .month: String(localized: "Last 30 days")
        }
    }

    // The sentences that mention the period are written out whole for each period, because the period's place in the
    // sentence differs between languages.

    var chartSubtitle: String {
        switch self {
        case .today: String(localized: "New tokens per hour, today.")
        case .week: String(localized: "New tokens per day, last 7 days.")
        case .month: String(localized: "New tokens per day, last 30 days.")
        }
    }

    /// The subtitle of a list of new tokens, such as "New tokens today so far."
    var newTokensLine: String {
        switch self {
        case .today: String(localized: "New tokens today so far.")
        case .week: String(localized: "New tokens in the last 7 days.")
        case .month: String(localized: "New tokens in the last 30 days.")
        }
    }

    var newTokensClickProjectLine: String {
        switch self {
        case .today: String(localized: "New tokens today so far. Click a project for details.")
        case .week: String(localized: "New tokens in the last 7 days. Click a project for details.")
        case .month: String(localized: "New tokens in the last 30 days. Click a project for details.")
        }
    }

    /// A count of new tokens in the period, such as "2.4M new tokens today so far."
    func newTokensTotal(_ total: String) -> String {
        switch self {
        case .today: String(localized: "\(total) new tokens today so far.")
        case .week: String(localized: "\(total) new tokens in the last 7 days.")
        case .month: String(localized: "\(total) new tokens in the last 30 days.")
        }
    }

    /// A count of all processed tokens in the period, cache reads included.
    func processedTotal(_ total: String) -> String {
        switch self {
        case .today: String(localized: "\(total) tokens processed today so far, cache reads included.")
        case .week: String(localized: "\(total) tokens processed in the last 7 days, cache reads included.")
        case .month: String(localized: "\(total) tokens processed in the last 30 days, cache reads included.")
        }
    }

    var noTokensLine: String {
        switch self {
        case .today: String(localized: "No tokens today so far.")
        case .week: String(localized: "No tokens in the last 7 days.")
        case .month: String(localized: "No tokens in the last 30 days.")
        }
    }

    var nothingLine: String {
        switch self {
        case .today: String(localized: "Nothing today so far.")
        case .week: String(localized: "Nothing in the last 7 days.")
        case .month: String(localized: "Nothing in the last 30 days.")
        }
    }

    var noSessionsLine: String {
        switch self {
        case .today: String(localized: "No sessions today so far.")
        case .week: String(localized: "No sessions in the last 7 days.")
        case .month: String(localized: "No sessions in the last 30 days.")
        }
    }

    /// Which tools worked on a project in the period, such as "Used with Claude Code and Codex today so far."
    func usedWith(_ tools: String) -> String {
        switch self {
        case .today: String(localized: "Used with \(tools) today so far.")
        case .week: String(localized: "Used with \(tools) in the last 7 days.")
        case .month: String(localized: "Used with \(tools) in the last 30 days.")
        }
    }

    var granularity: Granularity { self == .today ? .hour : .day }

    /// The number of whole days the period covers, today included.
    private var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    /// The covered interval. The end is open, so the period runs up to now.
    func current(now: Date, calendar: Calendar) -> UsageFilter {
        let today = calendar.startOfDay(for: now)
        return UsageFilter(from: calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today)
    }

    /// The interval just before the current one. Today is compared with yesterday up to the same time of day, because
    /// a whole yesterday would make every morning look quiet.
    func previous(now: Date, calendar: Calendar) -> UsageFilter {
        let today = calendar.startOfDay(for: now)
        if self == .today {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return UsageFilter(from: yesterday, to: calendar.date(byAdding: .day, value: -1, to: now) ?? yesterday)
        }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return UsageFilter(from: calendar.date(byAdding: .day, value: -days, to: start) ?? start, to: start)
    }

    /// The start of every bar of the activity chart: the hours of today, or the days of the period.
    func bucketStarts(now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        if self == .today {
            return (0..<24).compactMap { calendar.date(byAdding: .hour, value: $0, to: today) }
        }
        return (0..<days).compactMap { calendar.date(byAdding: .day, value: $0 - (days - 1), to: today) }
    }
}

/// One bar of the activity chart.
struct OverviewBucket: Identifiable, Equatable, Sendable {
    var index: Int
    var start: Date
    var end: Date
    /// New tokens per provider.
    var fresh: [ProviderID: Int64] = [:]
    var cacheRead: Int64 = 0
    var cost = EstimatedCost()
    var sessions = 0
    /// True for an hour of today that has not begun.
    var isFuture = false
    /// True for the hour or day that contains now, whose figures are still growing.
    var isCurrent = false
    var id: Int { index }

    var totalFresh: Int64 { fresh.values.reduce(0, +) }
}

enum OverviewLogic {
    /// Spreads the points of a series split by provider over the bars of a period. Points that fall outside every bar
    /// are dropped.
    static func buckets(period: OverviewPeriod, now: Date, calendar: Calendar, points: [SeriesPoint],
                        sessions: [(start: Date, sessions: Int)]) -> [OverviewBucket] {
        let starts = period.bucketStarts(now: now, calendar: calendar)
        var out = starts.enumerated().map { i, start in
            let end = calendar.date(byAdding: period.granularity.component, value: 1, to: start) ?? start
            return OverviewBucket(index: i, start: start, end: end, isFuture: start > now, isCurrent: start <= now && now < end)
        }
        func index(of date: Date) -> Int? { out.firstIndex { $0.start <= date && date < $0.end } }
        for p in points {
            guard let i = index(of: p.start) else { continue }
            if !p.key.isEmpty { out[i].fresh[ProviderID(rawValue: p.key), default: 0] += p.tokens.freshTokens }
            out[i].cacheRead += p.tokens.cacheRead
            out[i].cost = out[i].cost + p.cost
        }
        for s in sessions {
            guard let i = index(of: s.start) else { continue }
            out[i].sessions += s.sessions
        }
        return out
    }

    /// Names joined into one phrase, such as "Claude Code and Codex".
    static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        let head = names.dropLast().joined(separator: ", ")
        return String(localized: "\(head) and \(last)")
    }

    /// A number of sessions, such as "1 session" or "12 sessions".
    static func sessionCount(_ n: Int) -> String {
        n == 1 ? String(localized: "\(n) session") : String(localized: "\(n) sessions")
    }

    /// The bar that is selected when the user has not picked one: the current hour or day.
    static func defaultSelection(_ buckets: [OverviewBucket]) -> Int {
        buckets.lastIndex { !$0.isFuture } ?? max(0, buckets.count - 1)
    }

    /// The top of the chart's scale: the largest bar rounded up to 1, 2, 2.5 or 5 times a power of ten.
    static func niceCeiling(_ v: Int64) -> Int64 {
        guard v > 0 else { return 1 }
        let e = pow(10, floor(log10(Double(v))))
        let m = Double(v) / e
        let step: Double = m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10
        return Int64((step * e).rounded())
    }

    /// How the new tokens of the period compare with the period before.
    static func changeText(current: Int64, previous: Int64, period: OverviewPeriod) -> String {
        guard previous > 0 else {
            switch (period, current > 0) {
            case (.today, true): return String(localized: "Nothing yesterday by this time to compare with.")
            case (.week, true): return String(localized: "Nothing the 7 days before to compare with.")
            case (.month, true): return String(localized: "Nothing the 30 days before to compare with.")
            case (.today, false): return String(localized: "No usage yesterday by this time either.")
            case (.week, false): return String(localized: "No usage the 7 days before either.")
            case (.month, false): return String(localized: "No usage the 30 days before either.")
            }
        }
        let change = Double(current) / Double(previous) - 1
        if abs(change) < 0.05 {
            switch period {
            case .today: return String(localized: "About the same as yesterday by this time.")
            case .week: return String(localized: "About the same as the 7 days before.")
            case .month: return String(localized: "About the same as the 30 days before.")
            }
        }
        let pct = Int((abs(change) * 100).rounded())
        switch (period, change > 0) {
        case (.today, true): return String(localized: "↑ \(pct)% more than yesterday by this time.")
        case (.week, true): return String(localized: "↑ \(pct)% more than the 7 days before.")
        case (.month, true): return String(localized: "↑ \(pct)% more than the 30 days before.")
        case (.today, false): return String(localized: "↓ \(pct)% less than yesterday by this time.")
        case (.week, false): return String(localized: "↓ \(pct)% less than the 7 days before.")
        case (.month, false): return String(localized: "↓ \(pct)% less than the 30 days before.")
        }
    }

    /// The label under a bar. Today labels every third hour, 7 days label every day, and 30 days every fifth day
    /// counted back from today. The selected bar is always labelled.
    static func shortLabel(_ b: OverviewBucket, period: OverviewPeriod, count: Int, selected: Bool, calendar: Calendar) -> String {
        switch period {
        case .today:
            let h = calendar.component(.hour, from: b.start)
            return selected || h % 3 == 0 ? String(format: "%02d", h) : ""
        case .week:
            return b.start.formatted(.dateTime.weekday(.abbreviated).day())
        case .month:
            return selected || (count - 1 - b.index) % 5 == 0 ? "\(calendar.component(.day, from: b.start))" : ""
        }
    }

    /// The heading of the selected bar, such as "16:00–17:00, so far" or "Tuesday, 20 October".
    static func title(of b: OverviewBucket, period: OverviewPeriod) -> String {
        let text: String
        if period == .today {
            text = b.start.formatted(date: .omitted, time: .shortened) + "–" + b.end.formatted(date: .omitted, time: .shortened)
        } else {
            text = b.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return b.isCurrent ? String(localized: "\(text), so far") : text
    }

    /// When something last happened, in words: "Today 16:12", "Yesterday", "Friday" or a date.
    static func lastActive(_ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return String(localized: "Unknown") }
        if calendar.isDate(date, inSameDayAs: now) {
            let time = date.formatted(date: .omitted, time: .shortened)
            return String(localized: "Today \(time)")
        }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return String(localized: "Yesterday") }
        if now.timeIntervalSince(date) < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide)) }
        if now.timeIntervalSince(date) < 13 * 86_400 { return String(localized: "Last week") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// A moment as it reads after "Resets": "at 18:00", "tomorrow at 09:10" or "on Friday at 12:00".
    static func clock(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "at \(time)") }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) { return String(localized: "tomorrow at \(time)") }
        let day = date.timeIntervalSince(now) < 6 * 86_400 ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "on \(day) at \(time)")
    }
}

/// What a quota window is heading for at the rate it has been used so far in its cycle.
struct WindowOutlook: Equatable {
    enum Level: Equatable { case good, warning, critical }
    var level: Level
    var status: String
    /// When the allowance runs out at the current pace, if that comes before the reset.
    var runsOutAt: Date?

    /// Works out the outlook from the reported percentage. The pace is the use per second since the window began,
    /// which needs both the reset time and the window's length; without them only the level is known.
    static func evaluate(used: Double, resetsAt: Date?, length: TimeInterval?, now: Date) -> WindowOutlook {
        var runsOutAt: Date?
        if let resetsAt, let length, used > 0, used < 100 {
            let remaining = resetsAt.timeIntervalSince(now)
            let elapsed = length - remaining
            // In the first minutes of a window a single request makes the pace look enormous, so no projection is made yet.
            if remaining > 0, elapsed >= 10 * 60 {
                let toFull = (100 - used) / (used / elapsed)
                if toFull < remaining { runsOutAt = now.addingTimeInterval(toFull) }
            }
        }
        if used >= 100 { return WindowOutlook(level: .critical, status: String(localized: "Limit reached"), runsOutAt: nil) }
        if runsOutAt != nil { return WindowOutlook(level: .critical, status: String(localized: "Will run out before it resets"), runsOutAt: runsOutAt) }
        if used >= 90 { return WindowOutlook(level: .critical, status: String(localized: "Near the limit"), runsOutAt: nil) }
        if used >= 75 { return WindowOutlook(level: .warning, status: String(localized: "Getting close"), runsOutAt: nil) }
        return WindowOutlook(level: .good, status: String(localized: "Plenty left"), runsOutAt: nil)
    }
}

extension Fmt {
    /// A duration as it reads in a sentence, such as "1 h 42 min" or "3 d 5 h".
    static func spokenDuration(_ t: TimeInterval) -> String {
        let min = Int((max(0, t) / 60).rounded())
        if min < 60 { return String(localized: "\(min) min") }
        if min < 1440 {
            let h = min / 60, m = min % 60
            return m > 0 ? String(localized: "\(h) h \(m) min") : String(localized: "\(h) h")
        }
        let d = min / 1440, h = (min % 1440) / 60
        return h > 0 ? String(localized: "\(d) d \(h) h") : String(localized: "\(d) d")
    }
}
