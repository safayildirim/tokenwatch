import Foundation

/// How much a quota reading can be trusted.
public enum QuotaAuthority: String, Codable, Sendable {
    /// This reading was reported by the provider's own software through a documented or first-party interface.
    case authoritative
    /// Read from a source whose meaning is undocumented. Shown only when explicitly enabled, always
    /// labelled, and never used for alerts or the menu bar.
    case unverified
}

/// Identifies one allowance of one account.
///
/// Two accounts of the same provider have different pools even when they have the same plan, and the
/// utilization of different pools is never added together.
public struct QuotaPoolKey: Hashable, Sendable, Identifiable {
    public var provider: ProviderID
    /// The row id of the account in the database.
    public var accountID: Int64
    public var poolKey: String
    public var id: String { "\(provider.rawValue)/\(accountID)/\(poolKey)" }

    public init(provider: ProviderID, accountID: Int64, poolKey: String) {
        self.provider = provider
        self.accountID = accountID
        self.poolKey = poolKey
    }
}

/// Descriptive facts about a pool, for display.
public struct QuotaPoolInfo: Sendable, Equatable {
    public var key: QuotaPoolKey
    public var accountLabel: String
    public var name: String
    public var planType: String?
    /// The products that draw on this pool.
    public var products: [ProductID]
    public var note: String

    public init(key: QuotaPoolKey, accountLabel: String, name: String, planType: String? = nil,
                products: [ProductID] = [], note: String = "") {
        self.key = key
        self.accountLabel = accountLabel
        self.name = name
        self.planType = planType
        self.products = products
        self.note = note
    }
}

/// One stored reading of how much of a window has been used.
public struct QuotaReading: Sendable, Equatable {
    /// The percentage of the allowance consumed, as reported by the source.
    public var utilizationPercent: Double
    public var resetsAt: Date?
    /// When the source most recently reported this value. Freshness is measured from here.
    public var observedAt: Date
    /// When the source first reported this value.
    public var firstObservedAt: Date
    public var source: TelemetrySourceID
    public var authority: QuotaAuthority
    /// The reset cycle that this reading belongs to.
    public var cycleID: Int64?

    public init(utilizationPercent: Double, resetsAt: Date?, observedAt: Date, firstObservedAt: Date? = nil,
                source: TelemetrySourceID, authority: QuotaAuthority, cycleID: Int64? = nil) {
        self.utilizationPercent = utilizationPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.firstObservedAt = firstObservedAt ?? observedAt
        self.source = source
        self.authority = authority
        self.cycleID = cycleID
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

/// The presentable state of one window of one pool.
public struct QuotaWindowState: Sendable, Identifiable, Equatable {
    public var id: String { pool.key.id + "/" + windowKey }
    public var pool: QuotaPoolInfo
    /// The key that identifies the window within the pool, usually its length in minutes such as `300m`.
    public var windowKey: String
    public var windowMinutes: Int?
    public var reading: QuotaReading?
    public var availability: QuotaAvailability
    public var freshness: QuotaFreshness?
    public var evaluatedAt: Date

    public init(pool: QuotaPoolInfo, windowKey: String, windowMinutes: Int?, reading: QuotaReading?,
                availability: QuotaAvailability, freshness: QuotaFreshness?, evaluatedAt: Date) {
        self.pool = pool
        self.windowKey = windowKey
        self.windowMinutes = windowMinutes
        self.reading = reading
        self.availability = availability
        self.freshness = freshness
        self.evaluatedAt = evaluatedAt
    }

    /// A long form such as "Weekly window", for headings.
    public var displayName: String {
        let base = WindowNaming.displayName(minutes: windowMinutes, fallbackKey: windowKey)
        return windowMinutes == nil ? base : base + " window"
    }

    /// A compact form such as "5h" or "Week", for the menu bar.
    public var shortName: String { WindowNaming.shortName(minutes: windowMinutes, fallbackKey: windowKey) }

    /// Windows of a day or less are short ones.
    public var isShort: Bool { WindowNaming.isShort(minutes: windowMinutes) }

    /// The length of the window, when it is fixed.
    public var length: TimeInterval? { windowMinutes.map { TimeInterval($0) * 60 } }

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

/// All known windows of one pool.
public struct QuotaPoolState: Sendable, Identifiable, Equatable {
    public var id: String { pool.key.id }
    public var pool: QuotaPoolInfo
    /// Shortest window first.
    public var windows: [QuotaWindowState]

    public init(pool: QuotaPoolInfo, windows: [QuotaWindowState]) {
        self.pool = pool
        self.windows = windows
    }

    /// The highest utilization among the displayable windows of this pool.
    ///
    /// This is a comparison between windows of one pool, to answer "how close am I to a limit in this pool". It is
    /// never a sum, and it never mixes pools.
    public var highestUtilization: Double? { windows.compactMap { $0.isDisplayable ? $0.utilizationPercent : nil }.max() }
}

/// Chooses the reading to display for each window. This logic never derives a percentage from
/// token counts; a window without a reported value is simply unavailable.
public enum QuotaEvaluator {
    /// Evaluates the stored readings of one window of one pool.
    ///
    /// The result does not depend on the order of `readings`, so a report that is delivered late cannot
    /// replace a newer one: the reading that was confirmed most recently wins.
    public static func evaluate(pool: QuotaPoolInfo, windowKey: String, windowMinutes: Int?, readings: [QuotaReading], now: Date,
                                allowUnverified: Bool, policy: QuotaFreshnessPolicy = QuotaFreshnessPolicy()) -> QuotaWindowState {
        func state(_ reading: QuotaReading?, _ availability: QuotaAvailability, _ freshness: QuotaFreshness?) -> QuotaWindowState {
            QuotaWindowState(pool: pool, windowKey: windowKey, windowMinutes: windowMinutes, reading: reading,
                             availability: availability, freshness: freshness, evaluatedAt: now)
        }
        let candidates = readings.filter { allowUnverified || $0.authority == .authoritative }
        // Authoritative readings always outrank unverified ones.
        let authoritative = candidates.filter { $0.authority == .authoritative }
        let eligible = authoritative.isEmpty ? candidates : authoritative
        guard !eligible.isEmpty else { return state(nil, .unavailable(.noData), nil) }
        // A reading whose window is still open beats any whose window has closed, because a newer
        // window's report must not be hidden behind an older one that happens to be more recent.
        let open = eligible.filter { ($0.resetsAt ?? .distantFuture) > now }
        let chosen = (open.isEmpty ? eligible : open).max {
            ($0.observedAt, $0.utilizationPercent) < ($1.observedAt, $1.utilizationPercent)
        }!
        let freshness = policy.freshness(age: max(0, now.timeIntervalSince(chosen.observedAt)))
        if let reset = chosen.resetsAt, reset <= now {
            return state(chosen, .windowElapsed(resetAt: reset), freshness)
        }
        return state(chosen, .available, freshness)
    }
}
