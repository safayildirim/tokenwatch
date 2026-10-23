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

    /// The local cache is a snapshot that Claude Code refreshes only when it fetches usage. It is still a provider
    /// observation, but a ten-minute boundary would mark almost every normal cache reading stale. One hour is a
    /// deliberately generous "recent" boundary for this kind of snapshot; two hours separates "aging" from clearly
    /// stale. These are presentation boundaries, not claims about how often Claude Code writes the file.
    public func thresholds(for source: TelemetrySourceID) -> (fresh: TimeInterval, aging: TimeInterval) {
        QuotaSourcePolicy.thresholds(for: source, defaults: (freshWithin, agingWithin))
    }

    public func freshness(age: TimeInterval, source: TelemetrySourceID) -> QuotaFreshness {
        let t = thresholds(for: source)
        return age <= t.fresh ? .fresh : (age <= t.aging ? .aging : .stale)
    }
}

/// Two sources reported different values for the same reset cycle and approximately the same moment.
///
/// The values are deliberately not averaged. The selected observation is identified, and every alternative remains
/// visible so that the interface can explain the choice and a person can judge the source.
public struct QuotaReadingAlternative: Sendable, Equatable {
    public var utilizationPercent: Double
    public var observedAt: Date
    public var source: TelemetrySourceID

    public init(utilizationPercent: Double, observedAt: Date, source: TelemetrySourceID) {
        self.utilizationPercent = utilizationPercent
        self.observedAt = observedAt
        self.source = source
    }
}

public struct QuotaSourceConflict: Sendable, Equatable {
    public var selected: QuotaReadingAlternative
    public var alternatives: [QuotaReadingAlternative]

    public init(selected: QuotaReadingAlternative, alternatives: [QuotaReadingAlternative]) {
        self.selected = selected
        self.alternatives = alternatives
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
        /// No reading has ever been received, for example because Claude Code has not written a usage snapshot yet.
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
    /// Present only when another source reported a different value for the same cycle within a short window. The
    /// selected reading is still the one in `reading`; this is an explanation, not a second percentage.
    public var sourceConflict: QuotaSourceConflict?

    public init(pool: QuotaPoolInfo, windowKey: String, windowMinutes: Int?, reading: QuotaReading?,
                availability: QuotaAvailability, freshness: QuotaFreshness?, evaluatedAt: Date,
                sourceConflict: QuotaSourceConflict? = nil) {
        self.pool = pool
        self.windowKey = windowKey
        self.windowMinutes = windowMinutes
        self.reading = reading
        self.availability = availability
        self.freshness = freshness
        self.evaluatedAt = evaluatedAt
        self.sourceConflict = sourceConflict
    }

    /// A long form such as "Weekly window", for headings.
    public var displayName: String {
        let base = WindowNaming.displayName(minutes: windowMinutes, fallbackKey: windowKey)
        return windowMinutes == nil ? base : String(localized: "\(base) window")
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
        func state(_ reading: QuotaReading?, _ availability: QuotaAvailability, _ freshness: QuotaFreshness?,
                   conflict: QuotaSourceConflict? = nil) -> QuotaWindowState {
            QuotaWindowState(pool: pool, windowKey: windowKey, windowMinutes: windowMinutes, reading: reading,
                             availability: availability, freshness: freshness, evaluatedAt: now, sourceConflict: conflict)
        }
        let candidates = readings.filter { allowUnverified || $0.authority == .authoritative }
        // Authoritative readings always outrank unverified ones.
        let authoritative = candidates.filter { $0.authority == .authoritative }
        let eligible = authoritative.isEmpty ? candidates : authoritative
        guard !eligible.isEmpty else { return state(nil, .unavailable(.noData), nil) }
        // A reading whose window is still open beats any whose window has closed, because a newer
        // window's report must not be hidden behind an older one that happens to be more recent.
        let open = eligible.filter { ($0.resetsAt ?? .distantFuture) > now }
        // The latest provider observation wins. When two sources carry exactly the same timestamp, the local cache
        // is preferred over the undocumented Desktop hint. The
        // percentage is considered only after those, so no source can win merely by reporting a larger number.
        var chosen = (open.isEmpty ? eligible : open).max {
            (observationRank($0, now: now), QuotaSourcePolicy.priority(for: $0.source), $0.utilizationPercent)
                < (observationRank($1, now: now), QuotaSourcePolicy.priority(for: $1.source), $1.utilizationPercent)
        }!
        // Within one cycle the utilization only grows. Two sessions of the same source can deliver their readings out
        // of order, so a lower value that arrives a few seconds later belongs to a response that started earlier. The
        // rule is deliberately limited to the selected source: two sources that disagree are not reconciled by taking
        // the larger percentage.
        if let cycle = chosen.cycleID {
            let sameCycle = eligible.filter {
                $0.cycleID == cycle && $0.authority == chosen.authority && $0.source == chosen.source
            }
            if let highest = sameCycle.max(by: { ($0.utilizationPercent, $0.observedAt) < ($1.utilizationPercent, $1.observedAt) }),
               highest.utilizationPercent > chosen.utilizationPercent {
                chosen = highest
            }
        }
        // A reading that is dated later than the current time means that the clock was moved back since it was taken. How
        // old it really is cannot be known, so it is treated as stale instead of as brand new.
        let age = now.timeIntervalSince(chosen.observedAt)
        let freshness = age < -QuotaStaleness.futureSkew ? QuotaFreshness.stale
            : policy.freshness(age: max(0, age), source: chosen.source)
        let conflict = sourceConflict(chosen: chosen, eligible: eligible)
        if let reset = chosen.resetsAt, reset <= now {
            return state(chosen, .windowElapsed(resetAt: reset), freshness, conflict: conflict)
        }
        return state(chosen, .available, freshness, conflict: conflict)
    }

    private static func observationRank(_ r: QuotaReading, now: Date) -> Date {
        // A reading dated far in the future is a clock problem. It was already rejected by the feeds, but a stored
        // reading can still have been recorded before the clock moved; treat it as old rather than as the newest.
        r.observedAt.timeIntervalSince(now) > QuotaStaleness.futureSkew ? .distantPast : r.observedAt
    }

    /// A disagreement is only interesting when two sources describe the same cycle at about the same time. A cache
    /// fetched twenty minutes before another source normally holds an older percentage; that is elapsed usage, not a
    /// conflict. The values are compared, never averaged.
    private static func sourceConflict(chosen: QuotaReading, eligible: [QuotaReading]) -> QuotaSourceConflict? {
        guard let cycle = chosen.cycleID else { return nil }
        let selected = QuotaReadingAlternative(utilizationPercent: chosen.utilizationPercent,
                                               observedAt: chosen.observedAt, source: chosen.source)
        var alternatives: [QuotaReadingAlternative] = []
        for r in eligible where r.source != chosen.source && r.cycleID == cycle {
            guard abs(r.observedAt.timeIntervalSince(chosen.observedAt)) <= 15 * 60,
                  abs(r.utilizationPercent - chosen.utilizationPercent) >= 1 else { continue }
            let candidate = QuotaReadingAlternative(utilizationPercent: r.utilizationPercent,
                                                    observedAt: r.observedAt, source: r.source)
            if !alternatives.contains(where: { $0.source == candidate.source && $0.utilizationPercent == candidate.utilizationPercent }) {
                alternatives.append(candidate)
            }
        }
        guard !alternatives.isEmpty else { return nil }
        alternatives.sort { ($0.source.rawValue, $0.utilizationPercent) < ($1.source.rawValue, $1.utilizationPercent) }
        return QuotaSourceConflict(selected: selected, alternatives: alternatives)
    }
}
