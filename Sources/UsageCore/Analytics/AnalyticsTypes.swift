import Foundation

/// Selects which requests an analytical query covers.
public struct UsageFilter: Sendable, Equatable {
    /// Inclusive start of the covered period.
    public var from: Date?
    /// Exclusive end of the covered period.
    public var to: Date?
    public var projectIDs: Set<Int64> = []
    /// Canonical model keys, for example `claude-opus-5-5`.
    public var models: Set<String> = []
    public var providers: Set<ProviderID> = []
    public var products: Set<ProductID> = []
    /// Row ids of accounts, as listed by `AnalyticsEngine.filterOptions()`.
    public var accounts: Set<Int64> = []
    public var surfaces: Set<SurfaceID> = []
    public var telemetrySources: Set<TelemetrySourceID> = []
    public var sessionIDs: Set<Int64> = []
    /// Free text matched against project name, working directory and session id.
    public var search = ""

    public init(from: Date? = nil, to: Date? = nil) {
        self.from = from
        self.to = to
    }

    /// True when the filter removes individual requests, as opposed to whole sessions.
    var restrictsRequests: Bool { from != nil || to != nil || !models.isEmpty }

    /// Conditions on the request row (`r`).
    func requestConditions() -> (sql: [String], params: [SQLValue]) {
        var sql: [String] = []
        var params: [SQLValue] = []
        if let from { sql.append("r.requested_at >= ?"); params.append(.int(Clock.ms(from))) }
        if let to { sql.append("r.requested_at < ?"); params.append(.int(Clock.ms(to))) }
        if !models.isEmpty {
            let marks = models.map { _ in "?" }.joined(separator: ",")
            sql.append("r.model_id IN (SELECT id FROM model WHERE canonical IN (\(marks)))")
            params.append(contentsOf: models.sorted().map { .text($0) })
        }
        return (sql, params)
    }

    /// Conditions on the session row (`s`) and its project (`pj`).
    func sessionConditions() -> (sql: [String], params: [SQLValue]) {
        var sql: [String] = []
        var params: [SQLValue] = []
        if !projectIDs.isEmpty {
            sql.append("s.project_id IN (\(projectIDs.map { _ in "?" }.joined(separator: ",")))")
            params.append(contentsOf: projectIDs.sorted().map { .int($0) })
        }
        if !providers.isEmpty {
            sql.append("s.product_id IN (SELECT id FROM product WHERE provider_id IN (\(providers.map { _ in "?" }.joined(separator: ","))))")
            params.append(contentsOf: providers.map(\.rawValue).sorted().map { .text($0) })
        }
        if !products.isEmpty {
            sql.append("s.product_id IN (\(products.map { _ in "?" }.joined(separator: ",")))")
            params.append(contentsOf: products.map(\.rawValue).sorted().map { .text($0) })
        }
        if !accounts.isEmpty {
            sql.append("s.account_id IN (\(accounts.map { _ in "?" }.joined(separator: ",")))")
            params.append(contentsOf: accounts.sorted().map { .int($0) })
        }
        if !surfaces.isEmpty {
            sql.append("s.surface_id IN (\(surfaces.map { _ in "?" }.joined(separator: ",")))")
            params.append(contentsOf: surfaces.map(\.rawValue).sorted().map { .text($0) })
        }
        if !telemetrySources.isEmpty {
            sql.append("s.telemetry_source_id IN (\(telemetrySources.map { _ in "?" }.joined(separator: ",")))")
            params.append(contentsOf: telemetrySources.map(\.rawValue).sorted().map { .text($0) })
        }
        if !sessionIDs.isEmpty {
            sql.append("s.id IN (\(sessionIDs.map { _ in "?" }.joined(separator: ",")))")
            params.append(contentsOf: sessionIDs.sorted().map { .int($0) })
        }
        let term = search.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            let like = "%" + term.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            sql.append("(pj.name LIKE ? ESCAPE '\\' OR s.cwd LIKE ? ESCAPE '\\' OR s.external_id LIKE ? ESCAPE '\\')")
            params.append(contentsOf: [.text(like), .text(like), .text(like)])
        }
        return (sql, params)
    }

    func whereClause() -> (sql: String, params: [SQLValue]) {
        let r = requestConditions()
        let s = sessionConditions()
        let all = r.sql + s.sql
        return (all.isEmpty ? "" : "WHERE " + all.joined(separator: " AND "), r.params + s.params)
    }
}

public struct UsageTotals: Sendable, Equatable {
    public var tokens = TokenCounts()
    public var requests = 0
    public var sessions = 0
    public var cost = EstimatedCost()
    /// How many of the requests lacked each token category, so that a missing figure is not shown as zero.
    public var coverage = UsageCoverage()
    public init() {}
}

public enum Granularity: String, CaseIterable, Sendable, Identifiable {
    case hour, day, week, month
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

public enum SeriesDimension: Sendable {
    case none, model, project, provider
}

public struct SeriesPoint: Sendable, Identifiable, Equatable {
    public var start: Date
    /// The model or project this point belongs to, when the series is split by a dimension.
    public var key: String
    public var label: String
    public var tokens: TokenCounts
    public var requests: Int
    public var cost: EstimatedCost
    public var id: String { "\(start.timeIntervalSince1970)|\(key)" }
}

public struct ModelUsageRow: Sendable, Identifiable, Equatable {
    public var id: String { provider.rawValue + "/" + canonical }
    public var provider: ProviderID
    public var canonical: String
    public var displayName: String
    public var family: String
    public var tokens: TokenCounts
    public var requests: Int
    public var cost: EstimatedCost
    public var coverage = UsageCoverage()
    /// Share of all processed tokens in the covered period.
    public var tokenShare: Double
}

/// Usage of one provider, or of one of its products.
public struct ProviderUsageRow: Sendable, Identifiable, Equatable {
    public var id: String { provider.rawValue + "/" + (product?.rawValue ?? "") }
    public var provider: ProviderID
    /// Nil when the row covers every product of the provider.
    public var product: ProductID?
    public var tokens: TokenCounts
    public var requests: Int
    public var sessions: Int
    public var cost: EstimatedCost
    public var coverage: UsageCoverage
    public var lastActivity: Date?

    public init(provider: ProviderID, product: ProductID?, tokens: TokenCounts, requests: Int, sessions: Int,
                cost: EstimatedCost, coverage: UsageCoverage, lastActivity: Date?) {
        self.provider = provider
        self.product = product
        self.tokens = tokens
        self.requests = requests
        self.sessions = sessions
        self.cost = cost
        self.coverage = coverage
        self.lastActivity = lastActivity
    }
}

public struct ProjectUsageRow: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var path: String?
    public var tokens: TokenCounts
    public var requests: Int
    public var sessions: Int
    public var cost: EstimatedCost
    public var lastActivity: Date?
    public var tokenShare: Double
}

public struct SessionRow: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var externalID: String
    public var productID: ProductID
    public var provider: ProviderID
    public var sourceID: TelemetrySourceID
    public var accountID: Int64
    public var accountLabel: String
    public var surface: SurfaceID?
    public var kind: SessionKind
    public var projectID: Int64?
    public var projectName: String
    public var projectPath: String?
    public var clientVersion: String?
    public var cwd: String?
    public var startedAt: Date?
    public var lastActivityAt: Date?
    public var observedEndedAt: Date?
    public var tokens: TokenCounts
    public var requests: Int
    public var agentRequests: Int
    public var agentCount: Int
    public var cost: EstimatedCost
    public var coverage = UsageCoverage()
    /// The cost summary that the source computed for the session, kept separate from the estimate.
    public var reportedCostUSD: Double?
    /// Display names of the models used, most-used first.
    public var models: [String]
    public var status: SessionStatus

    public var duration: TimeInterval? {
        guard let s = startedAt, let e = lastActivityAt else { return nil }
        return max(0, e.timeIntervalSince(s))
    }

    public var shortID: String { String(externalID.prefix(8)) }
}

public struct RequestPoint: Sendable, Identifiable, Equatable {
    public var id: Int
    public var time: Date
    public var tokens: TokenCounts
    public var requests: Int
    public var modelName: String
    public var isChildAgent: Bool
}

public struct AgentUsage: Sendable, Identifiable, Equatable {
    public var id: String { key ?? "main" }
    /// Nil for the main conversation.
    public var key: String?
    public var tokens: TokenCounts
    public var requests: Int
    public var firstSeen: Date?
    public var lastSeen: Date?
    public var cost: EstimatedCost
    public var topModel: String
}

/// How a session relates to one cycle of a quota window.
///
/// The percentages here are shares of locally observed activity. They are not shares of the
/// subscription allowance, which depends on factors that local logs cannot show.
public struct QuotaWindowContext: Sendable, Identifiable, Equatable {
    public var id: String { "\(poolKey)-\(windowKey)-\(windowEnd.timeIntervalSince1970)" }
    public var poolKey: String
    public var windowKey: String
    public var windowMinutes: Int?
    public var windowStart: Date
    public var windowEnd: Date
    /// The highest account-level utilization reported during the window by an authoritative source.
    public var reportedPeakUtilization: Double?
    public var sessionTokens: TokenCounts
    public var localWindowTokens: TokenCounts
    public var sessionCost: EstimatedCost
    public var localWindowCost: EstimatedCost

    public var shareOfObservedFreshTokens: Double? {
        localWindowTokens.freshTokens > 0 ? Double(sessionTokens.freshTokens) / Double(localWindowTokens.freshTokens) : nil
    }
    public var shareOfObservedCost: Double? {
        localWindowCost.picoUSD > 0 ? Double(sessionCost.picoUSD) / Double(localWindowCost.picoUSD) : nil
    }
}

public struct SessionDetail: Sendable, Equatable {
    public var row: SessionRow
    public var byModel: [ModelUsageRow]
    public var timeline: [RequestPoint]
    /// True when the timeline was bucketed because the session has too many requests to plot.
    public var timelineIsBucketed: Bool
    public var agents: [AgentUsage]
    public var windows: [QuotaWindowContext]
}

public struct OverviewSnapshot: Sendable, Equatable {
    public var today = UsageTotals()
    public var thisWeek = UsageTotals()
    public var thisMonth = UsageTotals()
    public var allTime = UsageTotals()
    public var totalSessions = 0
    public var activeSessions = 0
    /// The number of sessions in the active state for each provider.
    public var activeSessionsByProvider: [ProviderID: Int] = [:]
    public var computedAt = Date()
    public init() {}
}
