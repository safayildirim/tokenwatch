import Foundation

/// A subscription usage window that a quota source can report.
public enum QuotaWindowKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    /// A spend limit that an organization's gateway applies. Only some accounts have one.
    case spendLimit = "spend_limit"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fiveHour: "Five-hour window"
        case .sevenDay: "Weekly window"
        case .spendLimit: "Spend limit"
        }
    }

    public var shortName: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "Week"
        case .spendLimit: "Spend"
        }
    }

    /// The length of the window, when it is fixed.
    public var length: TimeInterval? {
        switch self {
        case .fiveHour: 5 * 3600
        case .sevenDay: 7 * 86400
        case .spendLimit: nil
        }
    }
}

/// How much a quota reading can be trusted.
public enum QuotaAuthority: String, Codable, Sendable {
    /// This reading was reported by Claude itself through a documented interface.
    case authoritative
    /// Read from a source whose meaning is undocumented. Shown only when explicitly enabled, always
    /// labelled, and never used for alerts or the menu bar.
    case unverified
}

/// This is one observation of a quota window's utilization.
public struct QuotaReading: Codable, Sendable, Equatable {
    public var kind: QuotaWindowKind
    /// This is the percentage of the allowance consumed, as reported by the source.
    public var utilizationPercent: Double
    public var resetsAt: Date?
    /// When the underlying account state was last known to be current.
    public var observedAt: Date
    public var provider: String
    public var authority: QuotaAuthority
    /// This is the session that supplied the reading, when applicable.
    public var origin: String?

    public init(kind: QuotaWindowKind, utilizationPercent: Double, resetsAt: Date?, observedAt: Date,
                provider: String, authority: QuotaAuthority, origin: String? = nil) {
        self.kind = kind
        self.utilizationPercent = utilizationPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.provider = provider
        self.authority = authority
        self.origin = origin
    }
}

public enum QuotaFreshness: String, Sendable, Equatable {
    case fresh, aging, stale
}

public struct QuotaFreshnessPolicy: Sendable, Equatable {
    /// A reading newer than this is shown as current.
    public var freshWithin: TimeInterval = 10 * 60
    /// A reading older than `freshWithin` but newer than this is shown as ageing; beyond it, stale.
    public var agingWithin: TimeInterval = 60 * 60
    public init() {}

    public func freshness(age: TimeInterval) -> QuotaFreshness {
        age <= freshWithin ? .fresh : (age <= agingWithin ? .aging : .stale)
    }
}

public enum QuotaAvailability: Sendable, Equatable {
    /// A reading exists and its window has not yet reset.
    case available
    /// The window described by the last reading has reset since. The new window's utilization is
    /// unknown until a source reports it, and it is deliberately not assumed to be zero.
    case windowElapsed(resetAt: Date)
    case unavailable(UnavailableReason)

    public enum UnavailableReason: String, Sendable, Equatable {
        /// No reading has ever been received, for example because the status line bridge is not installed.
        case noData
    }
}

/// This is the presentable state of one quota window.
public struct QuotaWindowState: Sendable, Identifiable, Equatable {
    public var id: String { kind.rawValue }
    public var kind: QuotaWindowKind
    public var reading: QuotaReading?
    public var availability: QuotaAvailability
    public var freshness: QuotaFreshness?
    public var evaluatedAt: Date

    /// Percentage consumed, present only while the reading's window is still open.
    public var utilizationPercent: Double? {
        guard case .available = availability, let r = reading else { return nil }
        return r.utilizationPercent
    }

    public var remainingPercent: Double? { utilizationPercent.map { max(0, 100 - $0) } }

    public var resetsAt: Date? { reading?.resetsAt }

    public func countdown(now: Date = Date()) -> TimeInterval? {
        guard case .available = availability, let r = reading?.resetsAt else { return nil }
        return max(0, r.timeIntervalSince(now))
    }

    public var lastRefresh: Date? { reading?.observedAt }

    public var isAuthoritative: Bool { reading?.authority == .authoritative }

    /// True when the value may be shown in the menu bar and used for alerts: it must be authoritative
    /// and its window must still be open. Stale readings are still real, so they remain eligible for
    /// display with a stale marker, but alerts additionally require freshness.
    public var isDisplayable: Bool { utilizationPercent != nil && isAuthoritative }

    public var isAlertEligible: Bool { isDisplayable && freshness != .stale }
}

/// Chooses the reading to display for each window. This logic never derives a percentage from
/// token counts; a window without a reported value is simply unavailable.
public enum QuotaEvaluator {
    public static func evaluate(kind: QuotaWindowKind, readings: [QuotaReading], now: Date,
                                allowUnverified: Bool, policy: QuotaFreshnessPolicy = QuotaFreshnessPolicy()) -> QuotaWindowState {
        let candidates = readings.filter { $0.kind == kind && (allowUnverified || $0.authority == .authoritative) }
        // Authoritative readings always outrank unverified ones.
        let authoritative = candidates.filter { $0.authority == .authoritative }
        let pool = authoritative.isEmpty ? candidates : authoritative
        guard !pool.isEmpty else {
            return QuotaWindowState(kind: kind, reading: nil, availability: .unavailable(.noData), freshness: nil, evaluatedAt: now)
        }
        // A reading whose window is still open beats any whose window has closed, because a newer
        // window's report must not be hidden behind an older one that happens to be more recent.
        let open = pool.filter { ($0.resetsAt ?? .distantFuture) > now }
        let chosen = (open.isEmpty ? pool : open).max { $0.observedAt < $1.observedAt }!
        let freshness = policy.freshness(age: max(0, now.timeIntervalSince(chosen.observedAt)))
        if let reset = chosen.resetsAt, reset <= now {
            return QuotaWindowState(kind: kind, reading: chosen, availability: .windowElapsed(resetAt: reset),
                                    freshness: freshness, evaluatedAt: now)
        }
        return QuotaWindowState(kind: kind, reading: chosen, availability: .available, freshness: freshness, evaluatedAt: now)
    }
}
