import Foundation

/// What is known about a quota utilization at one instant of a cycle.
public struct QuotaBounds: Sendable, Equatable, Codable {
    /// How well the instant is covered by provider observations.
    public enum Basis: String, Sendable, Codable {
        /// The instant lies inside a span in which the same value was observed at both ends.
        case exact
        /// The instant lies between two observations, so the value is known to lie between their values.
        case bracketed
        /// The instant is before the first observation of the cycle, so only an upper bound is known.
        case beforeFirstObservation
        /// The instant is after the last observation of the cycle, so only a lower bound is known.
        case afterLastObservation
    }

    public var lower: Double
    public var upper: Double
    public var basis: Basis

    public init(lower: Double, upper: Double, basis: Basis) {
        self.lower = lower
        self.upper = upper
        self.basis = basis
    }

    public var isExact: Bool { basis == .exact }
}

/// How much the utilization rose between two instants of one cycle.
public enum QuotaChange: Sendable, Equatable, Codable {
    /// Both instants were observed, so the rise is an observation, not an estimate.
    case exact(Double)
    /// At least one instant lies between observations, so only a range is known.
    case between(Double, Double)
    /// An instant lies outside the observed part of the cycle. No number is reported, and none is interpolated.
    case unavailable

    public var exactValue: Double? {
        if case .exact(let value) = self { return value }
        return nil
    }
}

/// One distinct utilization value of a cycle with the span in which the provider reported it.
public struct QuotaReadingPoint: Sendable, Equatable, Codable {
    public var percent: Double
    public var firstObservedAt: Date
    public var lastConfirmedAt: Date
    public var source: String?
    /// How many observations moved an end of the span, which is a lower bound of how often the value was seen. Nil when the
    /// count is not known, as it is for a point made up in a test.
    public var confirmations: Int?
    /// The longest pause between two of those observations. A span that two observations a day apart support has the same
    /// first and last time as one that a hundred observations support, and this is what tells them apart.
    public var longestPause: TimeInterval?

    public init(percent: Double, firstObservedAt: Date, lastConfirmedAt: Date, source: String? = nil,
                confirmations: Int? = nil, longestPause: TimeInterval? = nil) {
        self.percent = percent
        self.firstObservedAt = firstObservedAt
        self.lastConfirmedAt = lastConfirmedAt
        self.source = source
        self.confirmations = confirmations
        self.longestPause = longestPause
    }
}

/// A reading that could not be used as stored, kept so that the interface can say what was set aside.
public enum QuotaCurveIssue: Sendable, Equatable, Codable {
    /// A reading was lower than an earlier one of the same cycle. Utilization only grows inside a cycle, so the
    /// lower reading is ignored instead of being treated as a reset.
    case decreasedReadingIgnored(percent: Double, at: Date)
    /// The confirmations of an earlier value ran past the first observation of a higher value, so they were cut off
    /// where the higher value begins.
    case overlappingConfirmationClipped(percent: Double)
}

/// The step function that the provider-reported utilization of one cycle draws.
///
/// Inside a cycle the utilization never falls, so when the same value is seen at two instants it is known for the
/// whole span between them. That gives the curve two kinds of knowledge. Inside a stored span the value is exact.
/// Between two spans the value is only known to lie between the two neighbours, because the moment of the rise was
/// not observed. The curve never interpolates a value between those neighbours.
public struct QuotaCurve: Sendable, Equatable {
    /// The usable points, strictly increasing in time and in value.
    public let points: [QuotaReadingPoint]
    public let issues: [QuotaCurveIssue]
    /// The highest value a reading can have. A cycle that reached it is complete from that moment on.
    public let ceiling: Double

    public init(readings: [QuotaReadingPoint], ceiling: Double = 100) {
        self.ceiling = ceiling
        let sorted = readings.sorted {
            ($0.firstObservedAt, $0.lastConfirmedAt, $0.percent) < ($1.firstObservedAt, $1.lastConfirmedAt, $1.percent)
        }
        var kept: [QuotaReadingPoint] = []
        var issues: [QuotaCurveIssue] = []
        for reading in sorted {
            guard let previous = kept.last else {
                kept.append(reading)
                continue
            }
            if reading.percent < previous.percent {
                issues.append(.decreasedReadingIgnored(percent: reading.percent, at: reading.firstObservedAt))
                continue
            }
            if reading.percent == previous.percent {
                var merged = previous
                merged.lastConfirmedAt = max(previous.lastConfirmedAt, reading.lastConfirmedAt)
                if let a = previous.confirmations, let b = reading.confirmations {
                    merged.confirmations = a + b
                    let between = max(0, reading.firstObservedAt.timeIntervalSince(previous.lastConfirmedAt))
                    merged.longestPause = max(previous.longestPause ?? 0, reading.longestPause ?? 0, between)
                } else {
                    merged.confirmations = nil
                    merged.longestPause = nil
                }
                kept[kept.count - 1] = merged
                continue
            }
            if previous.lastConfirmedAt > reading.firstObservedAt {
                kept[kept.count - 1].lastConfirmedAt = reading.firstObservedAt
                issues.append(.overlappingConfirmationClipped(percent: previous.percent))
            }
            kept.append(reading)
        }
        self.points = kept
        self.issues = issues
    }

    public var isEmpty: Bool { points.isEmpty }
    public var first: QuotaReadingPoint? { points.first }
    public var last: QuotaReadingPoint? { points.last }
    public var maximum: Double? { points.last?.percent }

    /// The curve limited to what had been observed by `date`, as if the later readings did not exist yet.
    ///
    /// A backtest uses this to forecast from the information that was available at the time.
    public func truncated(at date: Date) -> QuotaCurve {
        var kept: [QuotaReadingPoint] = []
        for point in points where point.firstObservedAt <= date {
            var copy = point
            if point.lastConfirmedAt > date {
                // Confirmations made after the cut did not exist yet, and how many of them did is not known.
                copy.lastConfirmedAt = date
                copy.confirmations = nil
                copy.longestPause = nil
            }
            kept.append(copy)
        }
        return QuotaCurve(readings: kept, ceiling: ceiling)
    }

    /// What is known about the utilization at `date`, or nil when the cycle has no reading.
    public func bounds(at date: Date) -> QuotaBounds? {
        guard let first, let last else { return nil }
        if date < first.firstObservedAt {
            return QuotaBounds(lower: 0, upper: first.percent, basis: .beforeFirstObservation)
        }
        var low = 0, high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].firstObservedAt <= date { low = mid + 1 } else { high = mid }
        }
        let point = points[low - 1]
        if date <= point.lastConfirmedAt {
            return QuotaBounds(lower: point.percent, upper: point.percent, basis: .exact)
        }
        if low < points.count {
            return QuotaBounds(lower: point.percent, upper: points[low].percent, basis: .bracketed)
        }
        if last.percent >= ceiling {
            return QuotaBounds(lower: last.percent, upper: last.percent, basis: .exact)
        }
        return QuotaBounds(lower: last.percent, upper: ceiling, basis: .afterLastObservation)
    }

    /// The rise between two instants, or `.unavailable` when either lies outside the observed part of the cycle.
    public func change(from start: Date, to end: Date) -> QuotaChange {
        guard end >= start, let a = bounds(at: start), let b = bounds(at: end) else { return .unavailable }
        let open: Set<QuotaBounds.Basis> = [.beforeFirstObservation, .afterLastObservation]
        if open.contains(a.basis) || open.contains(b.basis) { return .unavailable }
        if a.isExact && b.isExact { return .exact(b.lower - a.lower) }
        return .between(max(0, b.lower - a.upper), max(0, b.upper - a.lower))
    }

    /// The largest stretch between two consecutive observation spans, which is where a rise may have happened
    /// without being seen.
    public var largestGap: TimeInterval {
        var largest: TimeInterval = 0
        for (a, b) in zip(points, points.dropFirst()) {
            largest = max(largest, b.firstObservedAt.timeIntervalSince(a.lastConfirmedAt))
        }
        return largest
    }

    /// The time covered by spans in which the value is exact.
    public var exactDuration: TimeInterval {
        points.reduce(0) { $0 + $1.lastConfirmedAt.timeIntervalSince($1.firstObservedAt) }
    }
}
