import Foundation

/// A stored quota cycle as the calendar sees it: the reset time the provider announced, when the cycle was observed, and the
/// utilization at its first and last observation.
public struct ObservedQuotaCycle: Sendable, Equatable {
    public var id: Int64
    /// The reset time that the provider announced for this cycle. An announcement can lie in the future, so it is not
    /// evidence that the reset has happened.
    public var resetsAt: Date?
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    /// The utilization of the earliest and of the latest reading of the cycle. They let the calendar tell a real reset, where
    /// the utilization fell, from a changed announcement for the same window.
    public var firstPercent: Double?
    public var lastPercent: Double?

    public init(id: Int64, resetsAt: Date?, firstObservedAt: Date, lastObservedAt: Date,
                firstPercent: Double? = nil, lastPercent: Double? = nil) {
        self.id = id
        self.resetsAt = resetsAt
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.firstPercent = firstPercent
        self.lastPercent = lastPercent
    }
}

/// Whether a cycle boundary was reported by the provider or calculated from a reset schedule.
public enum CycleOrigin: String, Sendable, Codable {
    /// The end of the cycle is a reset time that the provider announced in a reading.
    case observed
    /// The cycle was calculated from a schedule that earlier observations established. It has no readings of its own.
    case projected
}

/// One period between two resets of a quota window, as the half-open interval `[start, end)`.
public struct QuotaCycleSpan: Sendable, Equatable, Identifiable, Codable {
    public var start: Date
    public var end: Date
    public var origin: CycleOrigin
    /// The stored cycles that describe this period. Several rows can describe one period when the reset time was
    /// announced with a few seconds of difference, or announced again at a different time.
    public var storedCycleIDs: [Int64]
    /// The reset time that the provider last announced for this period. It differs from `end` when the period was cut short.
    public var reportedReset: Date?
    /// True when a reading of the next window, with a lower utilization, was taken before the announced reset. This is the
    /// only evidence that is accepted for an early reset.
    public var endedEarly: Bool
    /// The interval in which an early reset happened, between the last reading of this period and the first reading
    /// of the next. The `end` of an early period is an estimate inside it.
    public var earlyResetBounds: ClosedRange<Date>?
    /// True when this window began after a gap in which the provider announced no window, which is normal for
    /// windows that start with the first request of a session.
    public var startedAfterIdleGap: Bool
    /// True when the provider announced a different reset time for what the utilization shows to be the same window.
    public var resetAnnouncementChanged: Bool
    /// True when the window's announced reset is sooner than a whole window after the previous reset, so the window cannot have
    /// had its nominal length. Its start is then the previous reset, which is the earliest it can have begun.
    public var startIsEarliestPossible: Bool
    /// True when readings of this window and of a neighbouring window were taken at the same time, as happens when readings
    /// of more than one account are stored together. Nothing is measured against such a cycle.
    public var overlapsAnotherWindow: Bool

    public var id: String { String(Int64(start.timeIntervalSince1970)) }
    public var length: TimeInterval { end.timeIntervalSince(start) }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    public init(start: Date, end: Date, origin: CycleOrigin, storedCycleIDs: [Int64] = [], reportedReset: Date? = nil,
                endedEarly: Bool = false, earlyResetBounds: ClosedRange<Date>? = nil, startedAfterIdleGap: Bool = false,
                resetAnnouncementChanged: Bool = false, startIsEarliestPossible: Bool = false, overlapsAnotherWindow: Bool = false) {
        self.start = start
        self.end = end
        self.origin = origin
        self.storedCycleIDs = storedCycleIDs
        self.reportedReset = reportedReset
        self.endedEarly = endedEarly
        self.earlyResetBounds = earlyResetBounds
        self.startedAfterIdleGap = startedAfterIdleGap
        self.resetAnnouncementChanged = resetAnnouncementChanged
        self.startIsEarliestPossible = startIsEarliestPossible
        self.overlapsAnotherWindow = overlapsAnotherWindow
    }
}

/// What kind of boundary separates two cycles, or lies ahead.
public enum ResetEventKind: String, Sendable, Codable {
    /// The next window was first seen after the announced reset, and it begins when the schedule says it should.
    case scheduled
    /// The next window was first seen after an idle gap. Windows that start with the first request of a session behave this way.
    case reanchored
    /// The next window was first seen after the announced reset, but its own announced reset is sooner than a whole window
    /// later. The transition is confirmed and its exact time is not.
    case irregularWindow
    /// A window with a lower utilization was seen before the previous window's announced reset. This is a manual or special reset.
    case exceptional
    /// The provider announced a different reset time for what the utilization shows to be the same window. Nothing was reset.
    case announcementChanged
    /// A stable schedule moved to a different time.
    case scheduleChange
    /// Readings of two windows overlap in time, so no transition can be established between them.
    case conflicting
    /// A reset that the provider announced, or that a schedule implies, and that no later reading has confirmed.
    case expected
}

/// A moment at which a quota window reset, or is expected to.
public struct QuotaResetEvent: Sendable, Equatable, Codable, Identifiable {
    public var at: Date
    /// The earliest and latest moment the reset can have happened. They equal `at` for a reset that is due by schedule.
    public var earliest: Date
    public var latest: Date
    public var kind: ResetEventKind
    public var origin: CycleOrigin
    /// True when a reading of the next window was taken after the reset. An announced or calculated reset is never confirmed.
    public var confirmed: Bool

    public var id: String { "\(kind.rawValue)-\(Int64(at.timeIntervalSince1970))" }
}

/// A reset schedule that announced reset times have established.
///
/// A schedule is a pattern in what the provider announced. A reset counts as confirmed only when a reading of the next window
/// was taken after it, so the newest announced reset of a schedule is, by definition, not yet confirmed.
public struct ResetSchedule: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        /// Consecutive announced reset times are whole multiples of the window length apart.
        case established
        /// The announced reset times do not repeat at the window length. Windows start when they are used.
        case notEstablished
    }

    /// How much the schedule has been checked against what happened.
    public enum Confidence: String, Sendable, Codable {
        case none
        /// One reset on the schedule was confirmed, and the next one is only announced.
        case provisional
        /// At least two resets on the schedule were confirmed.
        case confirmed
    }

    public var state: State
    public var period: TimeInterval?
    /// The newest announced reset time that lies on the schedule.
    public var anchor: Date?
    /// How many consecutive announced reset times lie on the schedule.
    public var supportingResets: Int
    /// How many distinct reset times the provider announced in all, on or off the schedule. A schedule needs at least two.
    public var announcedResets: Int = 0
    /// How many of the resets on the schedule were confirmed by a reading of the next window taken after them.
    public var confirmedResets: Int = 0

    public static let none = ResetSchedule(state: .notEstablished, period: nil, anchor: nil, supportingResets: 0)

    public var confidence: Confidence {
        guard state == .established else { return .none }
        return confirmedResets >= 2 ? .confirmed : .provisional
    }

    /// The first scheduled reset after `date`.
    public func nextReset(after date: Date) -> Date? {
        guard state == .established, let period, let anchor, period > 0 else { return nil }
        let steps = floor(date.timeIntervalSince(anchor) / period) + 1
        return anchor.addingTimeInterval(steps * period)
    }

    /// The weekday and clock time of the schedule in a time zone, for example Friday at 03:00 in UTC+3.
    public func wallClock(in zone: TimeZone) -> (weekday: Int?, hour: Int, minute: Int)? {
        guard state == .established, let period, let anchor else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: anchor)
        let weekly = abs(period - 7 * 86_400) < 1
        return (weekly ? parts.weekday : nil, parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// The cycles of one quota window, with the resets between them.
public struct QuotaCycleTimeline: Sendable, Equatable {
    public var windowMinutes: Int?
    /// Sorted and disjoint.
    public var spans: [QuotaCycleSpan]
    public var events: [QuotaResetEvent]
    public var schedule: ResetSchedule

    public func span(containing date: Date) -> QuotaCycleSpan? {
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].start <= date { low = mid + 1 } else { high = mid }
        }
        guard low > 0, spans[low - 1].contains(date) else { return nil }
        return spans[low - 1]
    }

    /// The reset that ends the cycle containing `date`, or the next scheduled one when none contains it.
    public func nextExpectedReset(after date: Date) -> Date? {
        span(containing: date)?.end ?? schedule.nextReset(after: date)
    }
}

/// Builds the cycles of a quota window from the reset times a provider announced and the readings that followed them.
///
/// Four things are kept apart. A reset the provider **announced** is a claim about the future. A **schedule** is a pattern in
/// announcements. A **confirmed** reset is one after which a reading of the next window was taken. An **exceptional** reset is a
/// window that was replaced before its announced reset, which is accepted only when a reading of the new window with a lower
/// utilization was taken before that time.
///
/// Nothing assumes calendar weeks, a start on Monday or Sunday, or that five-hour windows tile the day.
public enum QuotaCycleCalendar {
    /// Stored cycles whose announced resets are this close describe one reset.
    public static let mergeTolerance: TimeInterval = 90
    /// A reset time within this distance of a whole minute is shown on the minute. The provider rounds some resets
    /// down by one second, so that `23:59:59` and `00:00:00` mean the same instant.
    public static let snapTolerance: TimeInterval = 2
    /// The most cycles calculated before the first observed one or after the last observed one.
    public static let maxProjectedCycles = 60
    /// A utilization that fell by at least this many points between two readings is a reset, not rounding.
    public static let dropThreshold = 0.5

    private enum Link: Equatable {
        case continuous
        case skipped(Int)
        case idleGap
        case irregularWindow
        case early
        case announcementChanged
        case conflicting
        case unknownPeriod

        /// A link after which the next window was first seen, and that sits on the schedule.
        var isPeriodic: Bool {
            switch self {
            case .continuous, .skipped: true
            default: false
            }
        }
    }

    private struct Reset {
        var cycles: [ObservedQuotaCycle]
        var at: Date
        var announcementChanges = 0
        var firstObservedAt: Date { cycles.map(\.firstObservedAt).min()! }
        var lastObservedAt: Date { cycles.map(\.lastObservedAt).max()! }
        var firstPercent: Double? { cycles.min { $0.firstObservedAt < $1.firstObservedAt }?.firstPercent }
        var lastPercent: Double? { cycles.max { $0.lastObservedAt < $1.lastObservedAt }?.lastPercent }
    }

    public static func snap(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        let nearest = (seconds / 60).rounded() * 60
        return abs(nearest - seconds) <= snapTolerance ? Date(timeIntervalSince1970: nearest) : date
    }

    public static func build(observed: [ObservedQuotaCycle], windowMinutes: Int?, now: Date,
                             projectBackTo: Date? = nil) -> QuotaCycleTimeline {
        let period = windowMinutes.map { TimeInterval($0) * 60 }
        let groups = group(observed)
        guard !groups.isEmpty else {
            return QuotaCycleTimeline(windowMinutes: windowMinutes, spans: [], events: [], schedule: .none)
        }
        // The tolerance for "a whole number of windows apart" shrinks for short windows, because a short window
        // would otherwise find a coincidence among its many resets.
        let tolerance = period.map { min(mergeTolerance, $0 * 0.002) } ?? mergeTolerance
        let requiredPairs = (period ?? .infinity) <= 86_400 ? 2 : 1

        // Walk the announcements in order. A window whose announced reset changed without its utilization falling is the same
        // window, so the two stored cycles become one.
        var resets: [Reset] = []
        var links: [Link?] = []
        for next in groups {
            guard var previous = resets.last else {
                resets.append(next)
                links.append(nil)
                continue
            }
            let link = classify(previous, next, period: period, tolerance: tolerance)
            if link == .announcementChanged {
                previous.cycles += next.cycles
                previous.at = next.at
                previous.announcementChanges += 1
                resets[resets.count - 1] = previous
                links[links.count - 1] = resets.count >= 2
                    ? classify(resets[resets.count - 2], previous, period: period, tolerance: tolerance) : nil
                continue
            }
            resets.append(next)
            links.append(link)
        }

        var chain = 0
        for link in links.reversed().compactMap({ $0 }) {
            if link.isPeriodic { chain += 1 } else { break }
        }
        let established = period != nil && chain >= requiredPairs
        let schedule = established
            ? ResetSchedule(state: .established, period: period, anchor: resets.last!.at, supportingResets: chain + 1,
                            announcedResets: resets.count, confirmedResets: chain)
            : ResetSchedule(state: .notEstablished, period: nil, anchor: nil, supportingResets: 0, announcedResets: resets.count)

        var spans: [QuotaCycleSpan] = []
        var events: [QuotaResetEvent] = []
        for (index, reset) in resets.enumerated() {
            let start = period.map { reset.at.addingTimeInterval(-$0) } ?? (index > 0 ? resets[index - 1].at : reset.firstObservedAt)
            var span = QuotaCycleSpan(start: start, end: reset.at, origin: .observed, storedCycleIDs: reset.cycles.map(\.id),
                                      reportedReset: reset.at, resetAnnouncementChanged: reset.announcementChanges > 0)
            if reset.announcementChanges > 0 {
                events.append(QuotaResetEvent(at: reset.at, earliest: reset.at, latest: reset.at, kind: .announcementChanged,
                                              origin: .observed, confirmed: false))
            }
            if index > 0, let link = links[index] {
                let previous = resets[index - 1]
                switch link {
                case .continuous, .unknownPeriod:
                    events.append(event(.scheduled, at: previous.at, confirmed: true))
                case .skipped(let missing):
                    for step in 0..<missing {
                        let from = previous.at.addingTimeInterval(Double(step) * period!)
                        spans.append(QuotaCycleSpan(start: from, end: from.addingTimeInterval(period!), origin: .projected))
                    }
                    events.append(event(.scheduled, at: previous.at, confirmed: true))
                case .idleGap:
                    span.startedAfterIdleGap = true
                    // A window that lies off a schedule that had been stable is a schedule change. Otherwise it is an
                    // ordinary window that started with a request.
                    let wasStable = chainBefore(links, index) >= requiredPairs && period != nil
                    events.append(event(wasStable ? .scheduleChange : .reanchored, at: start, confirmed: true))
                case .irregularWindow:
                    span.start = previous.at
                    span.startIsEarliestPossible = true
                    let earliest = min(previous.lastObservedAt, reset.firstObservedAt)
                    let latest = max(previous.lastObservedAt, reset.firstObservedAt)
                    let at = min(max(previous.at, earliest), latest)
                    events.append(QuotaResetEvent(at: at, earliest: earliest, latest: latest, kind: .irregularWindow,
                                                  origin: .observed, confirmed: true))
                case .early:
                    let earliest = min(previous.lastObservedAt, reset.firstObservedAt)
                    let latest = max(previous.lastObservedAt, reset.firstObservedAt)
                    let estimate = min(max(start, earliest), latest)
                    spans[spans.count - 1].end = estimate
                    spans[spans.count - 1].endedEarly = true
                    spans[spans.count - 1].earlyResetBounds = earliest...latest
                    events.append(QuotaResetEvent(at: estimate, earliest: earliest, latest: latest, kind: .exceptional,
                                                  origin: .observed, confirmed: true))
                    span.start = estimate
                case .conflicting:
                    let cut = max(spans[spans.count - 1].start.addingTimeInterval(1), min(previous.at, start))
                    spans[spans.count - 1].end = cut
                    spans[spans.count - 1].overlapsAnotherWindow = true
                    span.start = cut
                    span.overlapsAnotherWindow = true
                    events.append(QuotaResetEvent(at: cut, earliest: min(reset.firstObservedAt, previous.lastObservedAt),
                                                  latest: max(reset.firstObservedAt, previous.lastObservedAt),
                                                  kind: .conflicting, origin: .observed, confirmed: false))
                case .announcementChanged:
                    break
                }
            }
            spans.append(span)
        }

        var headChain = 0
        for link in links.dropFirst() {
            guard let link, link.isPeriodic else { break }
            headChain += 1
        }
        if let period {
            // Cycles before the first observed one are calculated only when the observed resets repeat from the very first one
            // and at least one of them was confirmed.
            if headChain >= requiredPairs, let target = projectBackTo {
                var end = spans.first!.start
                var projected: [QuotaCycleSpan] = []
                while end > target, projected.count < maxProjectedCycles {
                    let start = end.addingTimeInterval(-period)
                    projected.append(QuotaCycleSpan(start: start, end: end, origin: .projected))
                    end = start
                }
                spans.insert(contentsOf: projected.reversed(), at: 0)
            }
            // Cycles after the last observed one, up to the one that contains `now`.
            if established {
                var end = spans.last!.end
                var forward = 0
                while end <= now, forward < maxProjectedCycles {
                    events.append(event(.expected, at: end, confirmed: false))
                    spans.append(QuotaCycleSpan(start: end, end: end.addingTimeInterval(period), origin: .projected))
                    end = end.addingTimeInterval(period)
                    forward += 1
                }
            }
        }

        // The reset that ends the newest cycle is announced or expected, not confirmed. When it is already past and no newer
        // reading exists, it is still reported as unconfirmed.
        if let last = spans.last {
            events.append(event(.expected, at: last.end, confirmed: false))
        }
        events = deduplicated(events)
        return QuotaCycleTimeline(windowMinutes: windowMinutes, spans: spans, events: events, schedule: schedule)
    }

    // MARK: Helpers

    private static func group(_ observed: [ObservedQuotaCycle]) -> [Reset] {
        let sorted = observed.filter { $0.resetsAt != nil }.sorted { $0.resetsAt! < $1.resetsAt! }
        var groups: [[ObservedQuotaCycle]] = []
        for cycle in sorted {
            if let lastReset = groups.last?.last?.resetsAt, cycle.resetsAt!.timeIntervalSince(lastReset) <= mergeTolerance {
                groups[groups.count - 1].append(cycle)
            } else {
                groups.append([cycle])
            }
        }
        return groups.map { cycles in
            let middle = cycles[cycles.count / 2].resetsAt!
            return Reset(cycles: cycles, at: snap(middle))
        }
    }

    /// Decides what separates two consecutive announcements from the readings that were taken, not from the announced times alone.
    private static func classify(_ a: Reset, _ b: Reset, period: TimeInterval?, tolerance: TimeInterval) -> Link {
        // Readings of both windows taken at the same time cannot belong to one account's consecutive windows.
        if b.firstObservedAt.addingTimeInterval(mergeTolerance) < a.lastObservedAt { return .conflicting }
        let seenAfterAnnouncedReset = b.firstObservedAt >= a.at.addingTimeInterval(-tolerance)
        guard seenAfterAnnouncedReset else {
            // The next window was seen before the previous window's announced reset. Only a utilization that fell proves that
            // the window was replaced. Otherwise the provider has announced a different time for the same window.
            if let before = a.lastPercent, let after = b.firstPercent, after < before - dropThreshold { return .early }
            return .announcementChanged
        }
        guard let period else { return .unknownPeriod }
        let gap = b.at.addingTimeInterval(-period).timeIntervalSince(a.at)
        if abs(gap) <= tolerance { return .continuous }
        if gap < 0 { return .irregularWindow }
        let windows = (gap / period).rounded()
        if windows >= 1, abs(gap - windows * period) <= tolerance { return .skipped(Int(windows)) }
        return .idleGap
    }

    private static func chainBefore(_ links: [Link?], _ index: Int) -> Int {
        var count = 0
        var cursor = index - 1
        while cursor >= 1, let link = links[cursor], link.isPeriodic {
            count += 1
            cursor -= 1
        }
        return count
    }

    private static func event(_ kind: ResetEventKind, at date: Date, confirmed: Bool) -> QuotaResetEvent {
        QuotaResetEvent(at: date, earliest: date, latest: date, kind: kind,
                        origin: confirmed ? .observed : .projected, confirmed: confirmed)
    }

    private static func deduplicated(_ events: [QuotaResetEvent]) -> [QuotaResetEvent] {
        var seen: Set<String> = []
        return events.filter { seen.insert($0.id).inserted }.sorted { $0.at < $1.at }
    }
}
