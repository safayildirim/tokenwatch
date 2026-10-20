import Foundation

/// This is the normalized form of one model request as seen by one source.
///
/// A single request can be observed many times. Claude Code, for example, writes one log line per
/// content block of a streamed response, repeating the usage object on each line while the output
/// token count grows. After a context compaction or a resume the same request may be replayed
/// with its usage zeroed. `merged(with:)` combines any two observations of the same request so that
/// the result does not depend on how many times, or in which order, the observations arrive.
public struct RequestObservation: Sendable, Equatable {
    public var sourceID: String
    /// This is the stable identity of the request. For Claude Code this is the API message id.
    public var requestKey: String
    /// The server-assigned request id, when the source records one. It is the join key for
    /// correlating the same request across sources.
    public var apiRequestID: String?
    public var sessionExternalID: String
    public var agentExternalID: String?
    public var modelID: String
    public var requestedAtMs: Int64
    public var uncachedInput: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheCreation: Int64
    /// Nil when the source does not state the cache write TTL split.
    public var cacheCreation5m: Int64?
    public var cacheCreation1h: Int64?
    public var speed: String?
    public var stopReason: String?
    /// This is a cost computed by the source itself, in micro-USD. Preserved separately from estimates.
    public var sourceCostMicros: Int64?
    /// This is the byte offset of the first line that mentioned this request, for provenance.
    public var originOffset: Int64

    public init(sourceID: String, requestKey: String, apiRequestID: String? = nil,
                sessionExternalID: String, agentExternalID: String? = nil, modelID: String,
                requestedAtMs: Int64, uncachedInput: Int64, output: Int64, cacheRead: Int64,
                cacheCreation: Int64, cacheCreation5m: Int64? = nil, cacheCreation1h: Int64? = nil,
                speed: String? = nil, stopReason: String? = nil, sourceCostMicros: Int64? = nil,
                originOffset: Int64 = 0) {
        self.sourceID = sourceID
        self.requestKey = requestKey
        self.apiRequestID = apiRequestID
        self.sessionExternalID = sessionExternalID
        self.agentExternalID = agentExternalID
        self.modelID = modelID
        self.requestedAtMs = requestedAtMs
        self.uncachedInput = uncachedInput
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.cacheCreation5m = cacheCreation5m
        self.cacheCreation1h = cacheCreation1h
        self.speed = speed
        self.stopReason = stopReason
        self.sourceCostMicros = sourceCostMicros
        self.originOffset = originOffset
    }

    public var tokens: TokenCounts {
        TokenCounts(uncachedInput: uncachedInput, output: output, cacheRead: cacheRead,
                    cacheCreation: cacheCreation, cacheCreation5m: cacheCreation5m ?? 0,
                    cacheCreation1h: cacheCreation1h ?? 0)
    }

    /// True when every token category is zero. Such observations are replays or placeholders and
    /// carry no usage, so they are ignored rather than stored.
    public var isEmpty: Bool { uncachedInput == 0 && output == 0 && cacheRead == 0 && cacheCreation == 0 }

    /// Combines two observations of the same request.
    ///
    /// Every token category takes the maximum. Usage within one request only ever grows while it
    /// streams, and replays are zeroed, so the maximum is the finalized value. Taking the maximum
    /// per category (rather than choosing one whole snapshot) also yields the right answer if two
    /// partial observations each carry a different complete field.
    ///
    /// The operation is commutative, associative and idempotent. The SQL upsert in `IngestWriter`
    /// implements exactly the same rules, and a test asserts that the two agree.
    public func merged(with other: RequestObservation) -> RequestObservation {
        var r = self
        r.uncachedInput = max(uncachedInput, other.uncachedInput)
        r.output = max(output, other.output)
        r.cacheRead = max(cacheRead, other.cacheRead)
        r.cacheCreation = max(cacheCreation, other.cacheCreation)
        r.cacheCreation5m = Self.maxOptional(cacheCreation5m, other.cacheCreation5m)
        r.cacheCreation1h = Self.maxOptional(cacheCreation1h, other.cacheCreation1h)
        r.requestedAtMs = min(requestedAtMs, other.requestedAtMs)
        r.sourceCostMicros = Self.maxOptional(sourceCostMicros, other.sourceCostMicros)
        r.apiRequestID = Self.pickString(apiRequestID, other.apiRequestID)
        r.speed = Self.pickString(speed, other.speed)
        r.stopReason = Self.pickString(stopReason, other.stopReason)
        // Work done by a sub-agent is attributed to the main thread when any observation says so,
        // because a forked agent replays its parent's messages in its own log file.
        switch (agentExternalID, other.agentExternalID) {
        case (nil, _), (_, nil): r.agentExternalID = nil
        case let (a?, b?): r.agentExternalID = min(a, b)
        }
        if modelID == Self.syntheticModel { r.modelID = other.modelID }
        else if other.modelID == Self.syntheticModel { r.modelID = modelID }
        else { r.modelID = min(modelID, other.modelID) }
        r.originOffset = min(originOffset, other.originOffset)
        return r
    }

    public static let syntheticModel = "<synthetic>"

    private static func maxOptional(_ a: Int64?, _ b: Int64?) -> Int64? {
        switch (a, b) {
        case let (x?, y?): max(x, y)
        case let (x?, nil): x
        case let (nil, y?): y
        case (nil, nil): nil
        }
    }

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

/// These are facts about a session gathered from the lines of one or more log files.
public struct SessionObservation: Sendable, Equatable {
    public var sourceID: String
    public var externalID: String
    public var projectKey: String
    public var cwd: String?
    public var application: String?
    public var clientVersion: String?
    public var firstSeenMs: Int64
    public var lastSeenMs: Int64
    /// This is the timestamp of the line that supplied `clientVersion`, so that the newest value wins.
    public var versionSeenMs: Int64

    public mutating func absorb(_ other: SessionObservation) {
        if other.firstSeenMs < firstSeenMs {
            firstSeenMs = other.firstSeenMs
            if let c = other.cwd { cwd = c }
        } else if cwd == nil {
            cwd = other.cwd
        }
        lastSeenMs = max(lastSeenMs, other.lastSeenMs)
        if application == nil { application = other.application }
        if other.clientVersion != nil, other.versionSeenMs >= versionSeenMs {
            clientVersion = other.clientVersion
            versionSeenMs = other.versionSeenMs
        }
    }
}

public struct AgentObservation: Sendable, Equatable {
    public var sourceID: String
    public var sessionExternalID: String
    public var externalID: String
    public var firstSeenMs: Int64
    public var lastSeenMs: Int64
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
    }
    public var sourceID: String
    public var sessionExternalID: String
    public var totalCostMicros: Int64
    public var models: [ModelLine]
}

/// This holds everything extracted from one chunk of a file. Observations are pre-merged here so that the
/// database sees one upsert per distinct request instead of one per log line.
public struct NormalizedBatch: Sendable {
    public var requests: [String: RequestObservation] = [:]
    public var sessions: [String: SessionObservation] = [:]
    public var agents: [String: AgentObservation] = [:]
    public var costReports: [String: CostReportObservation] = [:]
    public var lineCount = 0
    public var malformedLineCount = 0
    public var oversizedLineCount = 0

    public init() {}

    public mutating func add(_ request: RequestObservation) {
        let key = request.sourceID + "\u{1F}" + request.requestKey
        if let existing = requests[key] { requests[key] = existing.merged(with: request) }
        else { requests[key] = request }
    }

    public mutating func add(_ session: SessionObservation) {
        let key = session.sourceID + "\u{1F}" + session.externalID
        if var existing = sessions[key] { existing.absorb(session); sessions[key] = existing }
        else { sessions[key] = session }
    }

    public mutating func add(_ agent: AgentObservation) {
        let key = agent.sourceID + "\u{1F}" + agent.sessionExternalID + "\u{1F}" + agent.externalID
        if var existing = agents[key] {
            existing.firstSeenMs = min(existing.firstSeenMs, agent.firstSeenMs)
            existing.lastSeenMs = max(existing.lastSeenMs, agent.lastSeenMs)
            agents[key] = existing
        } else { agents[key] = agent }
    }

    public mutating func add(_ report: CostReportObservation) {
        let key = report.sourceID + "\u{1F}" + report.sessionExternalID
        if let existing = costReports[key], existing.totalCostMicros >= report.totalCostMicros { return }
        costReports[key] = report
    }

    public var isEmpty: Bool { requests.isEmpty && sessions.isEmpty && costReports.isEmpty && agents.isEmpty }
}
