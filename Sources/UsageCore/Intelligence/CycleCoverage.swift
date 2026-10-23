import Foundation

/// How well the provider's utilization was observed inside one cycle, in terms that do not mistake a long span for a watched one.
///
/// Three different things are measured. The value is **determined** where the same value was seen at both ends of a span, because a
/// utilization never falls inside a cycle. A rise is **unresolved** in a stretch that lies between two observed values, because
/// the moment of the rise was not seen. A span is **supported** where the value is determined and observations are known to lie
/// close together, which excludes a long span that only two observations bound.
public struct CycleCoverage: Sendable, Equatable {
    /// How long after the start of the cycle the first reading was taken.
    public var firstObservationDelay: TimeInterval?
    /// How long before the end of the cycle (or before now, for a cycle in progress) the last reading was confirmed.
    public var lastObservationLead: TimeInterval?
    /// The number of observations that moved an end of a value's span. It is a lower bound, and nil when any value's count is unknown.
    public var observationCount: Int?
    public var distinctValues: Int
    /// The longest stretch in which the value is only bracketed, so a rise could have happened without being seen. It includes the
    /// time before the first reading and after the last.
    public var largestUnresolvedGap: TimeInterval
    /// The longest span in which the value is determined to have stayed the same. A provider that reported no change is a
    /// legitimate reason for a long span, and it is not a collection gap.
    public var longestUnchangedStretch: TimeInterval
    /// The longest pause between two observations inside a span of unchanged value, or nil when it is not known for every span.
    public var longestObservationPause: TimeInterval?
    /// The fraction of the elapsed cycle in which the value is determined.
    public var determinedFraction: Double
    /// The fraction of the elapsed cycle that is determined and supported by observations no more than twice the closeness
    /// tolerance apart. A span whose pauses are unknown counts only for that much at each end.
    public var supportedFraction: Double
    /// True when the cycle has ended, its start and its end were observed, and no rise could have gone unseen for long. Only then
    /// is the cycle's whole-cycle utilization a result and not a bound.
    public var hasReliableFullCycleResult: Bool

    public static let empty = CycleCoverage(firstObservationDelay: nil, lastObservationLead: nil, observationCount: nil, distinctValues: 0,
                                            largestUnresolvedGap: 0, longestUnchangedStretch: 0, longestObservationPause: nil,
                                            determinedFraction: 0, supportedFraction: 0, hasReliableFullCycleResult: false)

    /// The closeness tolerance of a cycle: a few percent of its length, between five minutes and twelve hours.
    public static func tolerance(forCycleLength length: TimeInterval) -> TimeInterval { min(max(length * 0.04, 5 * 60), 12 * 3600) }

    public static func compute(curve: QuotaCurve, span: QuotaCycleSpan, now: Date) -> CycleCoverage {
        guard let first = curve.first, let last = curve.last else { return .empty }
        let tolerance = tolerance(forCycleLength: max(span.length, 1))
        let elapsedEnd = min(span.end, now)
        let elapsed = max(elapsedEnd.timeIntervalSince(span.start), 1)

        let leading = max(0, first.firstObservedAt.timeIntervalSince(span.start))
        let trailing = max(0, elapsedEnd.timeIntervalSince(last.lastConfirmedAt))
        var unresolved = max(leading, trailing)
        var longestUnchanged: TimeInterval = 0
        var determined: TimeInterval = 0
        var supported: TimeInterval = 0
        var count: Int? = 0
        var pause: TimeInterval? = 0
        for (index, point) in curve.points.enumerated() {
            let length = max(0, point.lastConfirmedAt.timeIntervalSince(point.firstObservedAt))
            longestUnchanged = max(longestUnchanged, length)
            determined += length
            if let p = point.longestPause, p <= 2 * tolerance {
                supported += length
            } else {
                supported += min(length, 2 * tolerance)
            }
            if let c = point.confirmations, let current = count { count = current + c } else { count = nil }
            if let p = point.longestPause, let current = pause { pause = max(current, p) } else { pause = nil }
            if index + 1 < curve.points.count {
                unresolved = max(unresolved, curve.points[index + 1].firstObservedAt.timeIntervalSince(point.lastConfirmedAt))
            }
        }
        let ended = span.end <= now
        let startObserved = leading <= tolerance
        let endKnown = last.percent >= curve.ceiling || trailing <= tolerance
        let reliable = ended && startObserved && endKnown && unresolved <= max(2 * tolerance, 30 * 60)
        return CycleCoverage(firstObservationDelay: leading, lastObservationLead: trailing, observationCount: count,
                             distinctValues: curve.points.count, largestUnresolvedGap: unresolved,
                             longestUnchangedStretch: longestUnchanged, longestObservationPause: pause,
                             determinedFraction: min(1, determined / elapsed), supportedFraction: min(1, supported / elapsed),
                             hasReliableFullCycleResult: reliable)
    }
}
