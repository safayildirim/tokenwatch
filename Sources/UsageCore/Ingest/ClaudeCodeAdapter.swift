import Foundation

/// Reads the session transcripts that Claude Code writes under `~/.claude/projects`.
///
/// The same directory is used by the terminal CLI, by the VS Code extension and by the Code tab of
/// Claude Desktop (the `entrypoint` field of each record says which one), so a single adapter
/// covers all three.
///
/// File layout:
/// - `<project>/<session-id>.jsonl` holds the main conversation.
/// - `<project>/<session-id>/subagents/agent-<agent-id>.jsonl` holds the conversation of a sub-agent
///   that the session spawned.
///
/// Only a few small fields are read from each record. Message content, tool input and tool output
/// are skipped without being decoded, and nothing from them is stored.
public struct ClaudeCodeAdapter: SourceAdapter {
    public var sourceID: TelemetrySourceID { .claudeTranscripts }
    public var displayName: String { "Claude Code (CLI, VS Code, Desktop Code)" }
    public let root: URL

    public init(root: URL = ClaudeCodeAdapter.defaultRoot) { self.root = CanonicalPath.resolve(root) }

    public static var defaultRoot: URL { QuotaPaths.claudeHome.appendingPathComponent("projects") }

    public var watchRoots: [URL] { [root] }

    public var coverageNote: String {
        "Reads local transcripts only. Usage from claude.ai chat, Cowork and other devices is not recorded in these files and is not included."
    }

    public func discoverFiles() throws -> [SourceFileRef] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var out: [SourceFileRef] = []
        let projects = try fm.contentsOfDirectory(atPath: root.path)
        for project in projects where !project.hasPrefix(".") {
            let projectDir = root.appendingPathComponent(project).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: projectDir) else { continue }
            for entry in entries {
                let full = projectDir + "/" + entry
                if entry.hasSuffix(".jsonl") {
                    out.append(SourceFileRef(sourceID: sourceID, path: full, projectKey: project,
                                             sessionHint: String(entry.dropLast(6))))
                } else if let subs = try? fm.contentsOfDirectory(atPath: full + "/subagents") {
                    for sub in subs where sub.hasPrefix("agent-") && sub.hasSuffix(".jsonl") {
                        out.append(SourceFileRef(sourceID: sourceID, path: full + "/subagents/" + sub,
                                                 projectKey: project, sessionHint: entry,
                                                 agentHint: String(sub.dropFirst(6).dropLast(6))))
                    }
                }
            }
        }
        return out
    }

    public func fileRef(forPath path: String) -> SourceFileRef? {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard path.hasPrefix(prefix), path.hasSuffix(".jsonl") else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch parts.count {
        case 2:
            return SourceFileRef(sourceID: sourceID, path: path, projectKey: parts[0],
                                 sessionHint: String(parts[1].dropLast(6)))
        case 4 where parts[2] == "subagents" && parts[3].hasPrefix("agent-"):
            return SourceFileRef(sourceID: sourceID, path: path, projectKey: parts[0], sessionHint: parts[1],
                                 agentHint: String(parts[3].dropFirst(6).dropLast(6)))
        default:
            return nil
        }
    }

    public func makeParser(for file: SourceFileRef) -> any LineParser {
        ClaudeCodeLineParser(file: file)
    }

    // MARK: Identity

    /// Mirrors Claude Code's rule for turning a directory into a project folder name.
    public static func encodeProjectKey(_ path: String) -> String {
        String(path.unicodeScalars.map { s in
            (s.isASCII && (s.properties.isAlphabetic || (s.value >= 0x30 && s.value <= 0x39))) ? Character(s) : "-"
        })
    }

    /// The working directory is trusted as the project root only when it maps back to the project folder
    /// name. Otherwise the session started in a sub-directory or elsewhere, and the folder stands in for
    /// the project. A trusted root is a real path, so Claude and Codex sessions of one directory share a project.
    static func projectKey(folder: String, cwd: String?) -> String {
        if let cwd, !cwd.isEmpty, encodeProjectKey(cwd) == folder { return cwd }
        return "claude-folder:" + folder
    }

    /// Maps the `entrypoint` field of a record to where the session ran.
    static func surface(forEntrypoint entrypoint: String?) -> SurfaceID? {
        guard let e = entrypoint?.lowercased(), !e.isEmpty else { return nil }
        if e.contains("vscode") { return .vscode }
        if e.contains("jetbrains") { return .jetbrains }
        if e.contains("desktop") { return .claudeDesktop }
        if e == "cli" || e.hasSuffix("-cli") || e == "sdk-cli" { return .terminal }
        return .unknown
    }
}

/// Parses Claude Code transcript lines.
///
/// Three kinds of records matter.
/// - `assistant` records carry the API `message` with its `usage` object. These are the request
///   observations.
/// - `cost-state` records carry the cost summary that Claude Code computed for the session.
/// - Every other record with a timestamp only contributes to the session's activity window.
final class ClaudeCodeLineParser: LineParser {
    private let file: SourceFileRef
    private let sourceID: TelemetrySourceID
    private var sessions: [String: SessionObservation] = [:]
    private var agents: [String: AgentObservation] = [:]

    /// Timestamps outside this range are treated as clock noise and do not extend a session.
    private static let minPlausibleMs: Int64 = 1_577_836_800_000 // 2020-01-01

    init(file: SourceFileRef) {
        self.file = file
        self.sourceID = file.sourceID
    }

    private struct MessageFields {
        var id: String?
        var model: String?
        var stopReason: String?
        var hasUsage = false
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64?
        var cacheCreation: Int64?
        var cache5m: Int64?
        var cache1h: Int64?
        var speed: String?
    }

    func parse(line: UnsafeBufferPointer<UInt8>, offset: Int64, into batch: inout NormalizedBatch) {
        batch.lineCount += 1
        var c = JSONCursor(line)
        c.skipWhitespace()
        guard c.peek == 0x7B else { batch.malformedLineCount += 1; return }

        var type: String?
        var timestampMs: Int64?
        var sessionID: String?
        var cwdRaw: JSONCursor.RawString?
        var entrypoint: String?
        var version: String?
        var requestID: String?
        var agentID: String?
        var msg = MessageFields()
        var costTotal: Double?
        var costModels: [CostReportObservation.ModelLine] = []

        let ok = c.forEachMember { c, key in
            if c.equals(key, "type") {
                guard let s = c.readRawString() else { return false }
                type = c.string(s); return true
            } else if c.equals(key, "timestamp") {
                guard let s = c.readRawString() else { return false }
                timestampMs = ISO8601Fast.parse(UnsafeBufferPointer(start: c.base + s.start, count: s.end - s.start))
                return true
            } else if c.equals(key, "sessionId") {
                guard let s = c.readRawString() else { return false }
                sessionID = c.string(s); return true
            } else if c.equals(key, "cwd") {
                guard let s = c.readRawString() else { return false }
                cwdRaw = s; return true
            } else if c.equals(key, "entrypoint") {
                guard let s = c.readRawString() else { return false }
                entrypoint = c.string(s); return true
            } else if c.equals(key, "version") {
                guard let s = c.readRawString() else { return false }
                version = c.string(s); return true
            } else if c.equals(key, "requestId") {
                guard let s = c.readRawString() else { return false }
                requestID = c.string(s); return true
            } else if c.equals(key, "agentId") {
                guard let s = c.readRawString() else { return false }
                agentID = c.string(s); return true
            } else if c.equals(key, "message") {
                c.skipWhitespace()
                guard c.peek == 0x7B else { return false }
                return Self.parseMessage(&c, into: &msg)
            } else if c.equals(key, "totalCostUSD") {
                guard let d = c.readDouble() else { return false }
                costTotal = d; return true
            } else if c.equals(key, "modelUsage") {
                return Self.parseModelUsage(&c, into: &costModels)
            }
            return false
        }
        guard ok else { batch.malformedLineCount += 1; return }

        let effectiveSession = sessionID ?? file.sessionHint
        let effectiveAgent = agentID ?? file.agentHint

        if type == "cost-state", let total = costTotal {
            batch.add(CostReportObservation(product: .claudeCode, sessionExternalID: effectiveSession,
                                            totalCostMicros: Int64((total * 1_000_000).rounded()),
                                            models: costModels))
            return
        }

        guard let ts = timestampMs, ts >= Self.minPlausibleMs, ts < Clock.nowMs() + 86_400_000 else { return }

        // Record the activity window of the session and of the agent.
        if var s = sessions[effectiveSession] {
            s.firstSeenMs = min(s.firstSeenMs, ts)
            s.lastSeenMs = max(s.lastSeenMs, ts)
            if s.cwd == nil, let r = cwdRaw { s.cwd = c.string(r) }
            if s.surface == nil { s.surface = ClaudeCodeAdapter.surface(forEntrypoint: entrypoint) }
            if let v = version, v != s.clientVersion, ts >= s.versionSeenMs { s.clientVersion = v; s.versionSeenMs = ts }
            sessions[effectiveSession] = s
        } else {
            sessions[effectiveSession] = SessionObservation(
                product: .claudeCode, source: sourceID, externalID: effectiveSession, projectKey: file.projectKey,
                cwd: cwdRaw.map { c.string($0) }, surface: ClaudeCodeAdapter.surface(forEntrypoint: entrypoint),
                account: .unassigned(.anthropic), clientVersion: version,
                firstSeenMs: ts, lastSeenMs: ts, versionSeenMs: version == nil ? 0 : ts)
        }
        if let a = effectiveAgent {
            let key = effectiveSession + "\u{1F}" + a
            if var existing = agents[key] {
                existing.firstSeenMs = min(existing.firstSeenMs, ts)
                existing.lastSeenMs = max(existing.lastSeenMs, ts)
                agents[key] = existing
            } else {
                agents[key] = AgentObservation(product: .claudeCode, sessionExternalID: effectiveSession,
                                               externalID: a, firstSeenMs: ts, lastSeenMs: ts)
            }
        }

        // Build a request observation from the assistant message when it carries usage.
        guard type == "assistant", msg.hasUsage, let model = msg.model, model != RequestObservation.syntheticModel else { return }
        let key = msg.id ?? requestID ?? "\(file.path)@\(offset)"
        var cacheCreation = msg.cacheCreation
        if cacheCreation == nil, msg.cache5m != nil || msg.cache1h != nil {
            cacheCreation = (msg.cache5m ?? 0) + (msg.cache1h ?? 0)
        }
        let usage = UsageNormalizer.anthropic(
            inputTokens: msg.input, outputTokens: msg.output, cacheRead: msg.cacheRead, cacheCreation: cacheCreation,
            cacheCreation5m: msg.cache5m, cacheCreation1h: msg.cache1h, thinkingTokens: nil)
        let obs = RequestObservation(
            product: .claudeCode, source: sourceID, requestKey: key, apiRequestID: requestID,
            sessionExternalID: effectiveSession, agentExternalID: effectiveAgent, model: model,
            requestedAtMs: ts, usage: usage, speed: msg.speed, stopReason: msg.stopReason, originLocation: offset)
        if !obs.isEmpty { batch.add(obs) }
    }

    func flush(into batch: inout NormalizedBatch) {
        for var s in sessions.values {
            s.projectKey = ClaudeCodeAdapter.projectKey(folder: file.projectKey, cwd: s.cwd)
            batch.add(s)
        }
        for a in agents.values { batch.add(a) }
        sessions.removeAll(keepingCapacity: true)
        agents.removeAll(keepingCapacity: true)
    }

    // MARK: Nested objects

    private static func parseMessage(_ c: inout JSONCursor, into m: inout MessageFields) -> Bool {
        c.forEachMember { c, key in
            if c.equals(key, "id") {
                guard let s = c.readRawString() else { return false }
                m.id = c.string(s); return true
            } else if c.equals(key, "model") {
                guard let s = c.readRawString() else { return false }
                m.model = c.string(s); return true
            } else if c.equals(key, "stop_reason") {
                c.skipWhitespace()
                if c.peek == 0x6E { return false }
                guard let s = c.readRawString() else { return false }
                m.stopReason = c.string(s); return true
            } else if c.equals(key, "usage") {
                c.skipWhitespace()
                guard c.peek == 0x7B else { return false }
                m.hasUsage = true
                return parseUsage(&c, into: &m)
            }
            return false
        }
    }

    private static func parseUsage(_ c: inout JSONCursor, into m: inout MessageFields) -> Bool {
        c.forEachMember { c, key in
            if c.equals(key, "input_tokens") {
                guard let v = c.readInt() else { return false }
                m.input = max(0, v); return true
            } else if c.equals(key, "output_tokens") {
                guard let v = c.readInt() else { return false }
                m.output = max(0, v); return true
            } else if c.equals(key, "cache_read_input_tokens") {
                guard let v = c.readInt() else { return false }
                m.cacheRead = max(0, v); return true
            } else if c.equals(key, "cache_creation_input_tokens") {
                guard let v = c.readInt() else { return false }
                m.cacheCreation = max(0, v); return true
            } else if c.equals(key, "speed") {
                c.skipWhitespace()
                if c.peek == 0x6E { return false }
                guard let s = c.readRawString() else { return false }
                m.speed = c.string(s); return true
            } else if c.equals(key, "cache_creation") {
                c.skipWhitespace()
                guard c.peek == 0x7B else { return false }
                var five: Int64 = 0, hour: Int64 = 0
                let ok = c.forEachMember { c, k in
                    if c.equals(k, "ephemeral_5m_input_tokens") {
                        guard let v = c.readInt() else { return false }
                        five = max(0, v); return true
                    } else if c.equals(k, "ephemeral_1h_input_tokens") {
                        guard let v = c.readInt() else { return false }
                        hour = max(0, v); return true
                    }
                    return false
                }
                if ok { m.cache5m = five; m.cache1h = hour }
                return ok
            }
            return false
        }
    }

    private static func parseModelUsage(_ c: inout JSONCursor, into out: inout [CostReportObservation.ModelLine]) -> Bool {
        c.skipWhitespace()
        guard c.peek == 0x7B else { return false }
        var lines: [CostReportObservation.ModelLine] = []
        let ok = c.forEachMember { c, modelKey in
            let name = c.string(modelKey)
            var line = CostReportObservation.ModelLine(modelRaw: name, uncachedInput: 0, output: 0,
                                                        cacheRead: 0, cacheCreation: 0, costMicros: 0)
            c.skipWhitespace()
            guard c.peek == 0x7B else { return false }
            let inner = c.forEachMember { c, k in
                if c.equals(k, "inputTokens") { guard let v = c.readInt() else { return false }; line.uncachedInput = v; return true }
                if c.equals(k, "outputTokens") { guard let v = c.readInt() else { return false }; line.output = v; return true }
                if c.equals(k, "cacheReadInputTokens") { guard let v = c.readInt() else { return false }; line.cacheRead = v; return true }
                if c.equals(k, "cacheCreationInputTokens") { guard let v = c.readInt() else { return false }; line.cacheCreation = v; return true }
                if c.equals(k, "costUSD") { guard let d = c.readDouble() else { return false }; line.costMicros = Int64((d * 1_000_000).rounded()); return true }
                return false
            }
            if inner { lines.append(line) }
            return inner
        }
        if ok { out = lines }
        return ok
    }
}


extension UsageNormalizer {
    /// Anthropic Messages API usage. `input_tokens` already excludes cached tokens.
    public static func anthropic(inputTokens: Int64, outputTokens: Int64, cacheRead: Int64?, cacheCreation: Int64?,
                                 cacheCreation5m: Int64?, cacheCreation1h: Int64?, thinkingTokens: Int64?) -> UsageMeasurement {
        UsageMeasurement(uncachedInput: inputTokens, cacheRead: cacheRead, cacheCreation: cacheCreation, output: outputTokens,
                         reasoningOutput: thinkingTokens, cacheCreation5m: cacheCreation5m, cacheCreation1h: cacheCreation1h,
                         normalization: "anthropic.messages.v1")
    }
}
