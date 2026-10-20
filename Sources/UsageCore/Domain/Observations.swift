import Foundation

// MARK: - Canonical usage

/// The token usage of one request in the application's canonical categories.
///
/// Providers report usage in different ways. Anthropic's `input_tokens` excludes cache activity, while
/// OpenAI's includes cached tokens, so each adapter converts what its source reports into these categories
/// before anything is stored. After that, no other code needs to know where a number came from.
///
/// A category that a source does not report is `nil`, meaning unknown. It is not treated as zero, because
/// "not measured" and "measured as none" are different facts. Categories that a provider defines as a part
/// of another (reasoning tokens are a part of output tokens for both OpenAI and Claude) are stored as such and
/// never added to their parent.
public struct UsageMeasurement: Sendable, Equatable {
    /// How complete the measurement is.
    public enum Completeness: String, Sendable, Comparable {
        /// Taken directly from a per-request report.
        case complete
        /// Derived from the difference between cumulative counters, because the per-request report was missing or inconsistent.
        case reconciledFromTotals
        /// Some categories are known to be missing.
        case partial

        private var rank: Int {
            switch self { case .complete: 2; case .reconciledFromTotals: 1; case .partial: 0 }
        }
        public static func < (a: Completeness, b: Completeness) -> Bool { a.rank < b.rank }
    }

    /// Input that was neither read from nor written to a prompt cache.
    public var uncachedInput: Int64?
    /// Input served from a prompt cache.
    public var cacheRead: Int64?
    /// Input written to a prompt cache.
    public var cacheCreation: Int64?
    public var output: Int64
    /// The part of `output` that was spent on reasoning. It is already included in `output`.
    public var reasoningOutput: Int64?
    /// The part of `cacheCreation` written with a five-minute lifetime, when the source states it.
    public var cacheCreation5m: Int64?
    public var cacheCreation1h: Int64?
    /// Provider-specific categories that have no canonical column, such as web search request counts.
    public var extras: [String: Int64]
    /// A short statement of the rules used to convert the source's numbers, for example `anthropic.messages.v1`.
    public var normalization: String
    public var completeness: Completeness

    public init(uncachedInput: Int64? = nil, cacheRead: Int64? = nil, cacheCreation: Int64? = nil, output: Int64,
                reasoningOutput: Int64? = nil, cacheCreation5m: Int64? = nil, cacheCreation1h: Int64? = nil,
                extras: [String: Int64] = [:], normalization: String, completeness: Completeness = .complete) {
        self.uncachedInput = uncachedInput
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.output = output
        self.reasoningOutput = reasoningOutput
        self.cacheCreation5m = cacheCreation5m
        self.cacheCreation1h = cacheCreation1h
        self.extras = extras
        self.normalization = normalization
        self.completeness = completeness
    }

    /// True when every token category that exists is zero or missing. Such a measurement carries no usage.
    public var isEmpty: Bool {
        (uncachedInput ?? 0) == 0 && (cacheRead ?? 0) == 0 && (cacheCreation ?? 0) == 0 && output == 0
    }

    /// Combines two measurements of the same request: every category takes the larger value that is present.
    /// See `RequestObservation.merged(with:)` for why this is correct.
    func merged(with other: UsageMeasurement) -> UsageMeasurement {
        var r = self
        r.uncachedInput = Self.maxOptional(uncachedInput, other.uncachedInput)
        r.cacheRead = Self.maxOptional(cacheRead, other.cacheRead)
        r.cacheCreation = Self.maxOptional(cacheCreation, other.cacheCreation)
        r.output = max(output, other.output)
        r.reasoningOutput = Self.maxOptional(reasoningOutput, other.reasoningOutput)
        r.cacheCreation5m = Self.maxOptional(cacheCreation5m, other.cacheCreation5m)
        r.cacheCreation1h = Self.maxOptional(cacheCreation1h, other.cacheCreation1h)
        r.extras = extras.merging(other.extras) { max($0, $1) }
        r.normalization = max(normalization, other.normalization)
        r.completeness = max(completeness, other.completeness)
        return r
    }

    static func maxOptional(_ a: Int64?, _ b: Int64?) -> Int64? {
        switch (a, b) {
        case let (x?, y?): max(x, y)
        case let (x?, nil): x
        case let (nil, y?): y
        case (nil, nil): nil
        }
    }

    /// The same measurement viewed as aggregate counts. Unknown categories contribute zero here, which is
    /// why aggregate queries also report how many requests were missing each category.
    public var counts: TokenCounts {
        TokenCounts(uncachedInput: uncachedInput ?? 0, output: output, cacheRead: cacheRead ?? 0,
                    cacheCreation: cacheCreation ?? 0, cacheCreation5m: cacheCreation5m ?? 0,
                    cacheCreation1h: cacheCreation1h ?? 0, reasoningOutput: reasoningOutput ?? 0)
    }
}

/// Conversions from a provider's reported usage into the canonical categories.
///
/// Each provider's conversion is an extension that lives beside the adapter that uses it, so that this file knows
/// nothing about any provider.
public enum UsageNormalizer {}

// MARK: - Observations

/// The normalized form of one model request as seen by one telemetry source.
///
/// A single request can be observed many times. Claude Code, for example, writes one log line per content
/// block of a streamed response, repeating the usage object on each line while the output token count grows,
/// and replays requests with zeroed usage after a compaction. `merged(with:)` combines any two observations
/// of the same request so that the result does not depend on how many times, or in which order, the
/// observations arrive.
public struct RequestObservation: Sendable, Equatable {
    public var product: ProductID
    public var source: TelemetrySourceID
    /// The stable identity of the request within its product. The key must be derived from something that
    /// every source describing the request agrees on, so that two sources never count it twice.
    public var requestKey: String
    /// The server-assigned request id, when the source records one. It is the join key for correlating the
    /// same request across sources.
    public var apiRequestID: String?
    public var sessionExternalID: String
    public var agentExternalID: String?
    public var model: String
    public var requestedAtMs: Int64
    public var usage: UsageMeasurement
    /// A service tier or speed that can change the price, for example `fast`.
    public var speed: String?
    public var stopReason: String?
    /// A cost computed by the source itself, in micro-USD. It is kept apart from any estimate.
    public var sourceCostMicros: Int64?
    /// Where in the source this request was first seen, for provenance (a byte offset or a record ordinal).
    public var originLocation: Int64

    public init(product: ProductID, source: TelemetrySourceID, requestKey: String, apiRequestID: String? = nil,
                sessionExternalID: String, agentExternalID: String? = nil, model: String, requestedAtMs: Int64,
                usage: UsageMeasurement, speed: String? = nil, stopReason: String? = nil,
                sourceCostMicros: Int64? = nil, originLocation: Int64 = 0) {
        self.product = product
        self.source = source
        self.requestKey = requestKey
        self.apiRequestID = apiRequestID
        self.sessionExternalID = sessionExternalID
        self.agentExternalID = agentExternalID
        self.model = model
        self.requestedAtMs = requestedAtMs
        self.usage = usage
        self.speed = speed
        self.stopReason = stopReason
        self.sourceCostMicros = sourceCostMicros
        self.originLocation = originLocation
    }

    public var tokens: TokenCounts { usage.counts }

    /// True when the request carries no usage. Such observations are replays or placeholders, so they are ignored.
    public var isEmpty: Bool { usage.isEmpty }

    /// Combines two observations of the same request.
    ///
    /// Every token category takes the larger value that is present. Usage within one request only ever grows
    /// while it streams, and replays are zeroed, so the maximum is the finalized value. Taking the maximum per
    /// category (rather than choosing one whole snapshot) also yields the right answer if two partial
    /// observations each carry a different complete field.
    ///
    /// The operation is commutative, associative and idempotent. The SQL upsert in `IngestWriter` implements
    /// exactly the same rules, and a test asserts that the two agree.
    public func merged(with other: RequestObservation) -> RequestObservation {
        var r = self
        r.usage = usage.merged(with: other.usage)
        r.requestedAtMs = min(requestedAtMs, other.requestedAtMs)
        r.sourceCostMicros = UsageMeasurement.maxOptional(sourceCostMicros, other.sourceCostMicros)
        r.apiRequestID = Self.pickString(apiRequestID, other.apiRequestID)
        r.speed = Self.pickString(speed, other.speed)
        r.stopReason = Self.pickString(stopReason, other.stopReason)
        // Work done by a sub-agent is attributed to the main thread when any observation says so,
        // because a forked agent replays its parent's messages in its own log file.
        switch (agentExternalID, other.agentExternalID) {
        case (nil, _), (_, nil): r.agentExternalID = nil
        case let (a?, b?): r.agentExternalID = min(a, b)
        }
        if model == Self.syntheticModel { r.model = other.model }
        else if other.model == Self.syntheticModel { r.model = model }
        else { r.model = min(model, other.model) }
        r.originLocation = min(originLocation, other.originLocation)
        // The telemetry source that sorts first stays, which makes the choice independent of arrival order.
        r.source = source.rawValue <= other.source.rawValue ? source : other.source
        return r
    }

    public static let syntheticModel = "<synthetic>"

    /// Chooses deterministically between two optional strings, preferring a present value.
    private static func pickString(_ a: String?, _ b: String?) -> String? {
        switch (a, b) {
        case let (x?, y?): max(x, y)
        case let (x?, nil): x
        case let (nil, y?): y
        case (nil, nil): nil
        }
    }
}

/// How a session relates to others, as far as the source can tell.
public enum SessionKind: String, Sendable {
    /// A conversation started by a person.
    case main
    /// A thread started by another session to do part of its work.
    case subagent
    /// An automatic reviewer thread attached to another session.
    case review
}

/// Facts about a session gathered from the lines of one or more log files.
public struct SessionObservation: Sendable, Equatable {
    public var product: ProductID
    public var source: TelemetrySourceID
    public var externalID: String
    /// Identifies the project. A working directory path when one is known, otherwise a source-specific token.
    public var projectKey: String
    public var cwd: String?
    public var surface: SurfaceID?
    public var account: AccountRef
    public var clientVersion: String?
    public var kind: SessionKind
    /// The session that started this one, when the source says so.
    public var parentExternalID: String?
    /// The top-level session this one belongs to, when the source says so.
    public var rootExternalID: String?
    public var firstSeenMs: Int64
    public var lastSeenMs: Int64
    /// The timestamp of the line that supplied `clientVersion`, so that the newest value wins.
    public var versionSeenMs: Int64
    /// How many times the product compacted the conversation's context. A compaction can change what the
    /// following token counts mean, so sessions that have one are flagged.
    public var compactionCount: Int

    public init(product: ProductID, source: TelemetrySourceID, externalID: String, projectKey: String, cwd: String? = nil,
                surface: SurfaceID? = nil, account: AccountRef, clientVersion: String? = nil, kind: SessionKind = .main,
                parentExternalID: String? = nil, rootExternalID: String? = nil, firstSeenMs: Int64, lastSeenMs: Int64,
                versionSeenMs: Int64 = 0, compactionCount: Int = 0) {
        self.product = product
        self.source = source
        self.externalID = externalID
        self.projectKey = projectKey
        self.cwd = cwd
        self.surface = surface
        self.account = account
        self.clientVersion = clientVersion
        self.kind = kind
        self.parentExternalID = parentExternalID
        self.rootExternalID = rootExternalID
        self.firstSeenMs = firstSeenMs
        self.lastSeenMs = lastSeenMs
        self.versionSeenMs = versionSeenMs
        self.compactionCount = compactionCount
    }

    public mutating func absorb(_ other: SessionObservation) {
        if other.firstSeenMs < firstSeenMs {
            firstSeenMs = other.firstSeenMs
            if let c = other.cwd { cwd = c }
        } else if cwd == nil {
            cwd = other.cwd
        }
        lastSeenMs = max(lastSeenMs, other.lastSeenMs)
        compactionCount = max(compactionCount, other.compactionCount)
        if surface == nil { surface = other.surface }
        // An identified account replaces an unassigned one, but never the other way round.
        if account.isUnassigned && !other.account.isUnassigned { account = other.account }
        if parentExternalID == nil { parentExternalID = other.parentExternalID }
        if rootExternalID == nil { rootExternalID = other.rootExternalID }
        if kind == .main && other.kind != .main { kind = other.kind }
        if other.clientVersion != nil, other.versionSeenMs >= versionSeenMs {
            clientVersion = other.clientVersion
            versionSeenMs = other.versionSeenMs
        }
    }
}

public struct AgentObservation: Sendable, Equatable {
    public var product: ProductID
    public var sessionExternalID: String
    public var externalID: String
    public var firstSeenMs: Int64
    public var lastSeenMs: Int64

    public init(product: ProductID, sessionExternalID: String, externalID: String, firstSeenMs: Int64, lastSeenMs: Int64) {
        self.product = product
        self.sessionExternalID = sessionExternalID
        self.externalID = externalID
        self.firstSeenMs = firstSeenMs
        self.lastSeenMs = lastSeenMs
    }
}

/// A cost summary that the source computed itself (Claude Code's `cost-state` records).
public struct CostReportObservation: Sendable, Equatable {
    public struct ModelLine: Sendable, Equatable {
        public var modelRaw: String
        public var uncachedInput: Int64
        public var output: Int64
        public var cacheRead: Int64
        public var cacheCreation: Int64
        public var costMicros: Int64

        public init(modelRaw: String, uncachedInput: Int64, output: Int64, cacheRead: Int64, cacheCreation: Int64, costMicros: Int64) {
            self.modelRaw = modelRaw
            self.uncachedInput = uncachedInput
            self.output = output
            self.cacheRead = cacheRead
            self.cacheCreation = cacheCreation
            self.costMicros = costMicros
        }
    }
    public var product: ProductID
    public var sessionExternalID: String
    public var totalCostMicros: Int64
    public var models: [ModelLine]

    public init(product: ProductID, sessionExternalID: String, totalCostMicros: Int64, models: [ModelLine]) {
        self.product = product
        self.sessionExternalID = sessionExternalID
        self.totalCostMicros = totalCostMicros
        self.models = models
    }
}

/// One report of how much of an allowance has been used.
///
/// It describes a window of a quota pool belonging to one account. The window is identified by a key that
/// the provider's adapter chooses (usually its length in minutes), so providers with different window
/// shapes need no special cases anywhere else.
public struct QuotaObservation: Sendable, Equatable {
    public var provider: ProviderID
    public var account: AccountRef
    /// Identifies the pool within the provider, for example `codex` or `claude-subscription`.
    public var poolKey: String
    public var windowKey: String
    /// The length of the window, when it has a fixed length.
    public var windowMinutes: Int?
    public var utilizationPercent: Double
    public var resetsAt: Date?
    /// When the source observed the value. It is never the time the observation was read from disk.
    public var observedAt: Date
    public var source: TelemetrySourceID
    public var authority: QuotaAuthority
    /// The session whose log carried the observation, when applicable.
    public var originProduct: ProductID?
    public var originSession: String?
    /// The plan the account is on, when reported.
    public var planType: String?

    public init(provider: ProviderID, account: AccountRef, poolKey: String, windowKey: String, windowMinutes: Int?,
                utilizationPercent: Double, resetsAt: Date?, observedAt: Date, source: TelemetrySourceID,
                authority: QuotaAuthority = .authoritative, originProduct: ProductID? = nil, originSession: String? = nil,
                planType: String? = nil) {
        self.provider = provider
        self.account = account
        self.poolKey = poolKey
        self.windowKey = windowKey
        self.windowMinutes = windowMinutes
        self.utilizationPercent = utilizationPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.source = source
        self.authority = authority
        self.originProduct = originProduct
        self.originSession = originSession
        self.planType = planType
    }
}

/// Everything extracted from one chunk of a file. Observations are pre-merged here so that the
/// database sees one upsert per distinct request instead of one per log line.
public struct NormalizedBatch: Sendable {
    public var requests: [String: RequestObservation] = [:]
    public var sessions: [String: SessionObservation] = [:]
    public var agents: [String: AgentObservation] = [:]
    public var costReports: [String: CostReportObservation] = [:]
    public var quota: [QuotaObservation] = []
    public var lineCount = 0
    public var malformedLineCount = 0
    public var oversizedLineCount = 0

    public init() {}

    public mutating func add(_ request: RequestObservation) {
        let key = request.product.rawValue + "\u{1F}" + request.requestKey
        if let existing = requests[key] { requests[key] = existing.merged(with: request) }
        else { requests[key] = request }
    }

    public mutating func add(_ session: SessionObservation) {
        let key = session.product.rawValue + "\u{1F}" + session.externalID
        if var existing = sessions[key] { existing.absorb(session); sessions[key] = existing }
        else { sessions[key] = session }
    }

    public mutating func add(_ agent: AgentObservation) {
        let key = agent.product.rawValue + "\u{1F}" + agent.sessionExternalID + "\u{1F}" + agent.externalID
        if var existing = agents[key] {
            existing.firstSeenMs = min(existing.firstSeenMs, agent.firstSeenMs)
            existing.lastSeenMs = max(existing.lastSeenMs, agent.lastSeenMs)
            agents[key] = existing
        } else { agents[key] = agent }
    }

    public mutating func add(_ report: CostReportObservation) {
        let key = report.product.rawValue + "\u{1F}" + report.sessionExternalID
        if let existing = costReports[key], existing.totalCostMicros >= report.totalCostMicros { return }
        costReports[key] = report
    }

    public mutating func add(_ observation: QuotaObservation) { quota.append(observation) }

    public var isEmpty: Bool { requests.isEmpty && sessions.isEmpty && costReports.isEmpty && agents.isEmpty && quota.isEmpty }
}
