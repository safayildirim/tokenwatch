import Foundation

/// This policy implements exponential backoff with jitter, with support for a server-provided `Retry-After` delay.
///
/// The delay never decreases while failures continue and never exceeds `maxDelay`. A server's
/// explicit `Retry-After` always wins over the computed delay, because retrying earlier than the
/// server allows only prolongs the rate limit.
public struct RetryPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var multiplier: Double
    /// Fraction of the delay that may be randomly added, from 0 (none) to 1 (up to double).
    public var jitter: Double

    public init(baseDelay: TimeInterval = 5, maxDelay: TimeInterval = 15 * 60, multiplier: Double = 2, jitter: Double = 0.2) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitter = jitter
    }

    /// Returns the delay before attempt number `failures + 1`, given `failures` consecutive failures so far.
    public func delay(afterFailures failures: Int, retryAfter: TimeInterval? = nil,
                      randomUnit: Double = Double.random(in: 0..<1)) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, 24 * 3600) }
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 30))
        let raw = min(maxDelay, baseDelay * pow(multiplier, exponent))
        return min(maxDelay, raw * (1 + jitter * randomUnit))
    }

    /// Parses an HTTP `Retry-After` header, which is either a number of seconds or an HTTP date.
    public static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }
}
