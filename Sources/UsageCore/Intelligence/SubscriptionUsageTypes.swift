import Foundation

/// One quota window of one account, which is the unit that usage intelligence analyzes.
///
/// Two windows of the same length keep separate identities: the key of a model-scoped window carries its scope, so the
/// general weekly allowance and a model's weekly allowance are never merged.
public struct IntelligenceSubject: Sendable, Hashable, Identifiable, Codable {
    public static func == (a: IntelligenceSubject, b: IntelligenceSubject) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var provider: ProviderID
    public var accountID: Int64
    public var accountLabel: String
    /// False for the explicit unassigned account, which holds readings whose source names no account.
    public var accountIsIdentified: Bool
    public var poolKey: String
    public var windowKey: String
    public var windowMinutes: Int?
    /// The provider's name for the scope of a model-scoped window, or nil for an ordinary window.
    public var scopeLabel: String?
    /// When the provider's newest reading of this window was last confirmed, which orders the windows by how current they are.
    /// It is not part of the window's identity.
    public var lastReadingAt: Date?

    public var id: String { "\(provider.rawValue)/\(accountID)/\(poolKey)/\(windowKey)" }

    public init(provider: ProviderID, accountID: Int64, accountLabel: String, accountIsIdentified: Bool, poolKey: String,
                windowKey: String, windowMinutes: Int?, scopeLabel: String? = nil, lastReadingAt: Date? = nil) {
        self.provider = provider
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.accountIsIdentified = accountIsIdentified
        self.poolKey = poolKey
        self.windowKey = windowKey
        self.windowMinutes = windowMinutes
        self.scopeLabel = scopeLabel
        self.lastReadingAt = lastReadingAt
    }
}

/// How completely the local sessions of a cycle are tied to the account whose quota is analyzed.
///
/// A session is tied to an account by its own files (a transcript that names its owner) or by an association the user made.
/// Nothing is tied by guessing, so the sessions that name no account and that no association covers are kept apart as
/// unattributed, and a ratio is withheld while they matter.
public enum LocalAttribution: String, Sendable, Codable {
    /// Every local token of the cycle is attributed to this account.
    case account
    /// Some local tokens are attributed and some name no account. Only the attributed ones are counted.
    case partlyAttributed
    /// The local activity names no account and no association covers it.
    case unattributed
    /// The analyzed account is the unassigned one: its readings and its sessions both name no account, so they are the same
    /// unlabeled pair, which can include more than one account.
    case unassignedAccount
    /// Activity that names no account exists while another identified account of the provider was active.
    case ambiguous
    /// The window is limited to one model, and no model with that name was found.
    case notAttributed
    /// There was no local activity.
    case noLocalActivity
}

/// Local activity of a cycle that is not tied to the analyzed account.
public struct UnattributedUsage: Sendable, Equatable {
    public var processedTokens: Int64 = 0
    public var requests = 0
    public init(processedTokens: Int64 = 0, requests: Int = 0) {
        self.processedTokens = processedTokens
        self.requests = requests
    }
}

public struct ModelUsage: Sendable, Equatable, Identifiable, Codable {
    public var canonical: String
    public var displayName: String
    public var tokens: TokenCounts
    public var requests: Int
    public var cost: EstimatedCost
    /// The model's share of the processed tokens of the period it belongs to.
    public var share: Double
    public var id: String { canonical }
}

public struct ProjectUsage: Sendable, Equatable, Identifiable, Codable {
    public var id: Int64
    public var name: String
    public var tokens: TokenCounts
    public var requests: Int
    public var cost: EstimatedCost
    public var share: Double
}

/// A run of requests with no pause longer than the activity gap between them.
public struct ActivePeriod: Sendable, Equatable, Codable {
    public var start: Date
    public var end: Date
}

/// Everything the local session files say about the work done in one period.
///
/// Token totals use the canonical definitions. A request shared by a parent and a sub-agent transcript is stored once, so
/// it is counted once, and reasoning tokens are part of output tokens and are never added again.
public struct LocalUsageSummary: Sendable, Equatable, Codable {
    public var tokens = TokenCounts()
    public var requests = 0
    /// Conversations started by a person, plus automatic reviewer threads.
    public var sessions = 0
    public var subagentSessions = 0
    public var subagentTokens = TokenCounts()
    public var cost = EstimatedCost()
    public var coverage = UsageCoverage()
    public var models: [ModelUsage] = []
    public var projects: [ProjectUsage] = []
    public var activePeriodCount = 0
    public var activeDuration: TimeInterval = 0
    /// The first periods, capped, for display.
    public var activePeriods: [ActivePeriod] = []
    public var activeDays = 0
    public var firstRequestAt: Date?
    public var lastRequestAt: Date?

    public init() {}

    public var isEmpty: Bool { requests == 0 }
    public var processedTokens: Int64 { tokens.totalProcessed }
}

/// How completely the provider's utilization was observed inside a cycle.
public enum CycleCompleteness: String, Sendable, Codable {
    /// The start and the end of the cycle were both observed and no long stretch is missing between readings.
    case complete
    /// Some readings exist, but the start, the end or a middle stretch was not observed.
    case partial
    /// One reading, or readings that are all in one place. Nothing can be said about change.
    case insufficient
    /// No reading exists for this cycle.
    case unobserved
}

/// What the provider reported about one cycle.
public struct CycleQuotaSummary: Sendable, Equatable {
    public var curve: QuotaCurve
    /// The number of distinct values that were reported.
    public var readingCount: Int
    public var firstPercent: Double?
    public var lastPercent: Double?
    public var maximumPercent: Double?
    /// When the first value was first seen and when the last value was last confirmed.
    public var firstObservedAt: Date?
    public var lastConfirmedAt: Date?
    /// The rise between the first and the last reading. It is the observed rise, not the whole cycle's consumption,
    /// unless the start and the end were both observed.
    public var observedRisePoints: Double?
    public var startObserved: Bool
    public var endObserved: Bool
    public var reachedLimit: Bool
    /// The utilization at the end of the cycle, known only when the end was observed or the limit was reached.
    public var finalPercent: Double?
    public var coverage: CycleCoverage
    public var completeness: CycleCompleteness
    public var sources: [String]
    public var issues: [QuotaCurveIssue]
}

/// The plan an account was recorded as having during a cycle.
public struct CyclePlan: Sendable, Equatable, Codable {
    public var key: String?
    public var name: String?
    /// True when more than one plan was in effect during the cycle.
    public var changedDuringCycle: Bool
    public var recorded: Bool { key != nil }
}

public enum CycleTiming: String, Sendable, Codable {
    case past, current, future
}

/// How the days of a cycle are cut.
public enum DayGrouping: Sendable, Equatable {
    /// Consecutive periods of twenty-four hours counted from the start of the cycle.
    case subscriptionDay
    /// Calendar days of a time zone, with a shorter first and last day when the cycle does not start at midnight.
    case calendarDay(TimeZone)
}

/// One day of a cycle.
public struct DayUsage: Sendable, Equatable, Identifiable {
    public var index: Int
    public var start: Date
    public var end: Date
    public var local: LocalUsageSummary
    /// The share of the cycle's processed tokens that fell on this day.
    public var shareOfCycleProcessed: Double
    /// How much the utilization rose during the day. This is a subdivision of a longer allowance, not a daily limit.
    public var quotaChange: QuotaChange
    public var id: Int { index }
}

/// The analysis of one cycle.
public struct SubscriptionCycleReport: Sendable, Equatable, Identifiable {
    public var span: QuotaCycleSpan
    public var timing: CycleTiming
    public var plan: CyclePlan?
    public var attribution: LocalAttribution
    /// The share of the cycle's local processed tokens that is attributed to the analyzed account, or nil without local activity.
    public var attributedShare: Double? = nil
    public var unattributed = UnattributedUsage()
    /// True when the analyzed account is the unassigned one and another identified account's readings overlap the cycle, so the
    /// unassigned readings may belong to either.
    public var quotaIdentityAmbiguous = false
    public var local: LocalUsageSummary
    public var quota: CycleQuotaSummary?
    public var days: [DayUsage]
    public var efficiency: CycleEfficiency
    /// The reset time the previous observed cycle implies, which is its reported reset plus the window length. The span's
    /// own end is the time the provider actually reported, so a difference means the schedule moved.
    public var expectedReset: Date?

    public var id: String { span.id }

    /// A cycle whose quota was fully observed and whose boundaries come from provider readings.
    public var isComplete: Bool { span.origin == .observed && quota?.completeness == .complete }
}

public struct AnalysisOptions: Sendable, Equatable {
    /// The most cycles analyzed, newest first, which bounds memory and query time.
    public var maxCycles = 26
    public var dayGrouping: DayGrouping = .subscriptionDay
    public var topModels = 8
    public var topProjects = 8
    /// A pause longer than this ends an active period.
    public var activityGap: TimeInterval = 15 * 60
    public var efficiency = EfficiencyPolicy()
    /// Only cycles that end after this date are analyzed.
    public var from: Date?
    public var to: Date?

    public init() {}
}

/// The result for one subject: its reset schedule, its cycles and what happened in each.
public struct SubscriptionUsageReport: Sendable, Equatable {
    public var subject: IntelligenceSubject
    public var generatedAt: Date
    public var schedule: ResetSchedule
    public var resetEvents: [QuotaResetEvent]
    /// Oldest first.
    public var cycles: [SubscriptionCycleReport]
    /// Facts about the data that apply to the whole report.
    public var notes: [ReportNote]
    public var dayGrouping: DayGrouping

    public var currentCycle: SubscriptionCycleReport? { cycles.last { $0.timing == .current } }
    public var pastCycles: [SubscriptionCycleReport] { cycles.filter { $0.timing == .past } }
}

public enum ReportNote: String, Sendable, Codable {
    /// Quota covers the whole account. Local tokens cover only the activity on this Mac.
    case quotaIsAccountWide
    case unassignedHistoryExists
    case scheduleNotEstablished
    case projectedCyclesPresent
    case noQuotaHistory
}
