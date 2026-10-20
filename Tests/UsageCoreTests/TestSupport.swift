import Foundation
import XCTest
@testable import UsageCore

/// A scratch directory containing a database and a fake `~/.claude/projects` tree.
final class TestEnv {
    let root: URL
    let projects: URL
    let dbURL: URL
    var db: UsageDatabase

    init(file: StaticString = #filePath) throws {
        // The temporary directory is resolved so that paths match what FSEvents reports.
        root = CanonicalPath.resolve(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ccu-test-\(UUID().uuidString)"))
        projects = root.appendingPathComponent("projects")
        dbURL = root.appendingPathComponent("db/usage.sqlite")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        db = try UsageDatabase.open(at: dbURL)
    }

    /// A second environment with an empty database and a copy of another environment's Codex files, which stands for
    /// deleting the application's data and importing the same history again.
    convenience init(copyingCodexFilesFrom other: TestEnv) throws {
        try self.init()
        try FileManager.default.copyItem(at: other.codexHome, to: codexHome)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var adapter: ClaudeCodeAdapter { ClaudeCodeAdapter(root: projects) }

    /// A fake Codex data folder (`$CODEX_HOME`) beside the fake Claude folder.
    var codexHome: URL { root.appendingPathComponent("codex-home") }
    var codexAdapter: CodexAdapter { CodexAdapter(home: codexHome) }

    /// Synchronizes every file of the fake Codex folder.
    @discardableResult
    func syncCodex() throws -> [SyncResult] {
        let adapter = codexAdapter
        return try adapter.discoverFiles().map { try synchronizer.sync(file: $0, adapter: adapter) }
    }

    /// Writes a Codex session file under `sessions/2026/10/12/` (or `archived_sessions/`) and returns its URL.
    @discardableResult
    func codexFile(session: String, lines: [String], archived: Bool = false, compressedWith zstd: Bool = false) throws -> URL {
        let dir = archived ? codexHome.appendingPathComponent("archived_sessions")
                           : codexHome.appendingPathComponent("sessions/2026/10/12")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-2026-10-12T12-00-00-\(session).jsonl")
        try Fixture.write(lines, to: url)
        return url
    }
    var synchronizer: FileSynchronizer { FileSynchronizer(db: db) }

    /// Simulates quitting and relaunching the app.
    func reopen() throws {
        db.markCleanShutdown()
        db = try UsageDatabase.open(at: dbURL)
    }

    func projectDir(_ cwd: String) throws -> URL {
        let dir = projects.appendingPathComponent(ClaudeCodeAdapter.encodeProjectKey(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func mainFile(cwd: String = "/Users/test/alpha", session: String) throws -> URL {
        try projectDir(cwd).appendingPathComponent("\(session).jsonl")
    }

    func subagentFile(cwd: String = "/Users/test/alpha", session: String, agent: String) throws -> URL {
        let dir = try projectDir(cwd).appendingPathComponent("\(session)/subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent-\(agent).jsonl")
    }

    /// Synchronizes every file under the fake root, as the initial scan would.
    @discardableResult
    func syncAll() throws -> [SyncResult] {
        try adapter.discoverFiles().map { try synchronizer.sync(file: $0, adapter: adapter) }
    }

    func totals() throws -> UsageTotals { try AnalyticsEngine(db: db).totals() }
}

/// Builds records in the same shape Claude Code writes, with all conversation text replaced by a placeholder.
enum Fixture {
    static func ts(_ epochMs: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000))
    }

    static func assistant(id: String, model: String = "claude-opus-5-5", session: String, at ms: Int64,
                          input: Int = 2, output: Int = 100, cacheRead: Int = 0, cacheCreation: Int = 0,
                          fiveMinute: Int? = nil, oneHour: Int? = nil, agent: String? = nil, cwd: String = "/Users/test/alpha",
                          stop: String? = nil, speed: String = "standard", requestID: String? = nil,
                          entrypoint: String = "cli", version: String = "2.1.296", padding: Int = 0) -> String {
        let split = (fiveMinute != nil || oneHour != nil)
            ? ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":\(fiveMinute ?? 0),\"ephemeral_1h_input_tokens\":\(oneHour ?? 0)}" : ""
        let stopJSON = stop.map { "\"\($0)\"" } ?? "null"
        let agentJSON = agent.map { ",\"agentId\":\"\($0)\"" } ?? ""
        let pad = padding > 0 ? "\"" + String(repeating: "x", count: padding) + "\"" : "\"REDACTED\""
        return "{\"parentUuid\":\"p-\(id)\",\"isSidechain\":\(agent != nil),\"message\":{\"model\":\"\(model)\",\"id\":\"\(id)\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\(pad)}],\"stop_reason\":\(stopJSON),\"usage\":{\"input_tokens\":\(input),\"cache_creation_input_tokens\":\(cacheCreation),\"cache_read_input_tokens\":\(cacheRead),\"output_tokens\":\(output)\(split),\"server_tool_use\":{\"web_search_requests\":0},\"service_tier\":\"standard\",\"speed\":\"\(speed)\"}},\"requestId\":\"\(requestID ?? "req_" + id)\",\"type\":\"assistant\",\"uuid\":\"u-\(id)-\(output)\",\"timestamp\":\"\(ts(ms))\",\"sessionId\":\"\(session)\"\(agentJSON),\"userType\":\"external\",\"entrypoint\":\"\(entrypoint)\",\"cwd\":\"\(cwd)\",\"version\":\"\(version)\"}"
    }

    static func user(session: String, at ms: Int64, cwd: String = "/Users/test/alpha") -> String {
        "{\"parentUuid\":null,\"isSidechain\":false,\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"REDACTED PROMPT\"},\"uuid\":\"uu-\(ms)\",\"timestamp\":\"\(ts(ms))\",\"sessionId\":\"\(session)\",\"cwd\":\"\(cwd)\",\"version\":\"2.1.296\",\"entrypoint\":\"cli\"}"
    }

    static func costState(session: String, totalUSD: Double, models: [String: (Int, Int, Int, Int, Double)]) -> String {
        let m = models.map { k, v in
            "\"\(k)\":{\"inputTokens\":\(v.0),\"outputTokens\":\(v.1),\"thinkingTokens\":0,\"cacheReadInputTokens\":\(v.2),\"cacheCreationInputTokens\":\(v.3),\"webSearchRequests\":0,\"costUSD\":\(v.4)}"
        }.joined(separator: ",")
        return "{\"type\":\"cost-state\",\"sessionId\":\"\(session)\",\"totalCostUSD\":\(totalUSD),\"totalAPIDuration\":1000,\"modelUsage\":{\(m)},\"hasUnknownModelCost\":false}"
    }

    @discardableResult
    static func write(_ lines: [String], to url: URL, terminate: Bool = true) throws -> URL {
        let text = lines.joined(separator: "\n") + (terminate ? "\n" : "")
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    static func append(_ lines: [String], to url: URL, terminate: Bool = true) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + (terminate ? "\n" : "")).utf8))
    }
}

let t0: Int64 = 1_790_000_000_000   // A fixed instant in October 2026.


extension QuotaCoordinator {
    /// The state of one window of one provider's primary pool, for tests that only use one account.
    func window(_ key: String, provider: ProviderID = .anthropic) -> QuotaWindowState? {
        states().first { $0.pool.key.provider == provider && $0.windowKey == key }
    }
}


/// Builds normalized observations directly, for tests that exercise the writer without going through a file.
enum Obs {
    static func session(_ id: String = "S", project: String = "claude-folder:-p", at ms: Int64 = t0, product: ProductID = .claudeCode,
                        source: TelemetrySourceID = .claudeTranscripts, account: AccountRef = .unassigned(.anthropic),
                        surface: SurfaceID? = nil) -> SessionObservation {
        SessionObservation(product: product, source: source, externalID: id, projectKey: project, surface: surface, account: account,
                           firstSeenMs: ms, lastSeenMs: ms)
    }

    /// A Claude request, whose input excludes the cached tokens as Anthropic reports it.
    static func claudeRequest(_ key: String, session: String = "S", model: String = "claude-opus-5-5", at ms: Int64 = t0,
                              input: Int64 = 1, output: Int64 = 1, cacheRead: Int64? = 0, cacheCreation: Int64? = 0,
                              cacheCreation5m: Int64? = nil, cacheCreation1h: Int64? = nil, apiRequestID: String? = nil,
                              agent: String? = nil, speed: String? = nil, stop: String? = nil) -> RequestObservation {
        RequestObservation(product: .claudeCode, source: .claudeTranscripts, requestKey: key, apiRequestID: apiRequestID,
                           sessionExternalID: session, agentExternalID: agent, model: model, requestedAtMs: ms,
                           usage: UsageNormalizer.anthropic(inputTokens: input, outputTokens: output, cacheRead: cacheRead,
                                                            cacheCreation: cacheCreation, cacheCreation5m: cacheCreation5m,
                                                            cacheCreation1h: cacheCreation1h, thinkingTokens: nil),
                           speed: speed, stopReason: stop)
    }
}


/// Builds Codex session lines in the shapes real files use, with all conversation text replaced by a placeholder.
enum CodexFixture {
    static let sessionA = "01a00000-0000-7000-8000-00000000000a"
    static let sessionB = "01a00000-0000-7000-8000-00000000000b"
    static let sessionC = "01a00000-0000-7000-8000-00000000000c"

    struct Usage {
        var input: Int64, cached: Int64 = 0, output: Int64, reasoning: Int64 = 0
        var total: Int64 { input + output }
        var json: String {
            "{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"cache_write_input_tokens\":0,\"output_tokens\":\(output),\"reasoning_output_tokens\":\(reasoning),\"total_tokens\":\(total)}"
        }
        static func + (a: Usage, b: Usage) -> Usage {
            Usage(input: a.input + b.input, cached: a.cached + b.cached, output: a.output + b.output, reasoning: a.reasoning + b.reasoning)
        }
    }

    static func line(_ type: String, ordinal: Int, at ms: Int64, payload: String) -> String {
        "{\"timestamp\":\"\(Fixture.ts(ms))\",\"ordinal\":\(ordinal),\"type\":\"\(type)\",\"payload\":\(payload)}"
    }

    /// The first line of a session file.
    static func header(id: String, at ms: Int64, originator: String = "codex_exec", source: String = "\"exec\"", cwd: String = "/Users/test/alpha",
                       account: String? = nil, threadSource: String? = "user", parent: String? = nil, root: String? = nil,
                       forkedFrom: String? = nil, version: String = "0.162.0-alpha.17.2") -> String {
        var fields = ["\"id\":\"\(id)\"", "\"session_id\":\"\(root ?? id)\"", "\"timestamp\":\"\(Fixture.ts(ms))\"", "\"cwd\":\"\(cwd)\"",
                      "\"originator\":\"\(originator)\"", "\"cli_version\":\"\(version)\"", "\"source\":\(source)",
                      "\"model_provider\":\"openai\"", "\"history_mode\":\"paginated\"", "\"base_instructions\":{\"text\":\"REDACTED INSTRUCTIONS\"}"]
        if let account { fields.append("\"creator_account_id\":\"\(account)\""); fields.append("\"creator_user_id\":\"user-REDACTED\"") }
        if let threadSource { fields.append("\"thread_source\":\"\(threadSource)\"") }
        if let parent { fields.append("\"parent_thread_id\":\"\(parent)\"") }
        if let forkedFrom { fields.append("\"forked_from_id\":\"\(forkedFrom)\"") }
        return line("session_meta", ordinal: 0, at: ms, payload: "{" + fields.joined(separator: ",") + "}")
    }

    static func turnContext(ordinal: Int, at ms: Int64, model: String = "gpt-5.6-terra") -> String {
        line("turn_context", ordinal: ordinal, at: ms, payload: "{\"turn_id\":\"t\(ordinal)\",\"cwd\":\"/Users/test/alpha\",\"model\":\"\(model)\",\"effort\":\"medium\"}")
    }

    static func message(ordinal: Int, at ms: Int64) -> String {
        line("response_item", ordinal: ordinal, at: ms, payload: "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"REDACTED REPLY\"}]}")
    }

    /// The rate limits of a snapshot. A window is given as `(percent, minutes, resetsAtSeconds)`.
    static func rateLimits(limitID: String = "codex", plan: String? = "plus", primary: (Double, Int, Double)? = (10, 300, 1_790_010_000),
                           secondary: (Double, Int, Double)? = (20, 10080, 1_790_500_000)) -> String {
        func w(_ x: (Double, Int, Double)?) -> String {
            x.map { "{\"used_percent\":\($0.0),\"window_minutes\":\($0.1),\"resets_at\":\(Int64($0.2))}" } ?? "null"
        }
        let planJSON = plan.map { "\"\($0)\"" } ?? "null"
        return "{\"limit_id\":\"\(limitID)\",\"limit_name\":null,\"primary\":\(w(primary)),\"secondary\":\(w(secondary)),\"credits\":null,\"plan_type\":\(planJSON)}"
    }

    static func tokenCount(ordinal: Int, at ms: Int64, last: Usage, total: Usage, rate: String? = nil) -> String {
        let info = "{\"total_token_usage\":\(total.json),\"last_token_usage\":\(last.json),\"model_context_window\":258400}"
        return line("event_msg", ordinal: ordinal, at: ms,
                    payload: "{\"type\":\"token_count\",\"info\":\(info),\"rate_limits\":\(rate ?? rateLimits())}")
    }

    /// A usage record. `thread` is the thread that made the response, which differs from the file's own thread in a
    /// record that a fork copied from its parent. `counter` is the thread's running counter after the response.
    static func tokenUsageRecord(ordinal: Int, at ms: Int64, response: String, usage: Usage, total: Usage, session: String = sessionA,
                                 thread: String? = nil) -> String {
        line("token_usage_record", ordinal: ordinal, at: ms,
             payload: "{\"thread_id\":\"\(thread ?? session)\",\"turn_id\":\"t1\",\"session_id\":\"\(thread ?? session)\",\"response_id\":\"\(response)\",\"usage\":\(usage.json),\"turn_token_usage\":\(total.json),\"thread_token_usage\":\(total.json)}")
    }

    static func compacted(ordinal: Int, at ms: Int64) -> String {
        line("compacted", ordinal: ordinal, at: ms, payload: "{\"window_number\":1,\"window_id\":\"w1\",\"message\":\"REDACTED\",\"replacement_history\":[],\"latest_token_usage_record\":null}")
    }

    /// A compaction marker that carries the usage record of the request that summarized the conversation.
    static func compacted(ordinal: Int, at ms: Int64, response: String, usage: Usage, session: String = sessionA) -> String {
        line("compacted", ordinal: ordinal, at: ms,
             payload: "{\"window_number\":1,\"window_id\":\"w1\",\"message\":\"REDACTED\",\"replacement_history\":[],\"compaction_response_id\":\"\(response)\",\"latest_token_usage_record\":{\"response_id\":\"\(response)\",\"thread_id\":\"\(session)\",\"usage\":\(usage.json)}}")
    }

    /// A fork of a session written the older way. As Codex does, it repeats the parent's lines unchanged, in the same
    /// positions and with the same figures, in a burst at the instant of the fork, and then continues with `own`
    /// responses written at `ownAt`.
    static func forkOfEventSession(id: String, parent: String, parentCount: Int, at forkAt: Int64, own: [Usage] = [],
                                   ownAt: [Int64] = [], copySpreadMs: Int64 = 1, account: String? = nil,
                                   originator: String = "codex_exec", each: Usage = Usage(input: 1000, cached: 600, output: 50, reasoning: 20),
                                   rate: String? = nil) -> [String] {
        var out = [header(id: id, at: forkAt, originator: originator, account: account, forkedFrom: parent), turnContext(ordinal: 1, at: forkAt + 1)]
        var total = Usage(input: 0, output: 0)
        for i in 0..<parentCount {
            total = total + each
            out.append(message(ordinal: 2 + i * 2, at: forkAt + 2 + Int64(i) * copySpreadMs))
            out.append(tokenCount(ordinal: 3 + i * 2, at: forkAt + 3 + Int64(i) * copySpreadMs, last: each, total: total, rate: rate))
        }
        var ordinal = 2 + parentCount * 2
        for (i, usage) in own.enumerated() {
            total = total + usage
            out.append(tokenCount(ordinal: ordinal, at: i < ownAt.count ? ownAt[i] : forkAt + 20_000 + Int64(i) * 5000, last: usage, total: total, rate: rate))
            ordinal += 2
        }
        return out
    }

    /// A session of `count` responses, written the older way (one `token_count` event per response).
    static func eventSession(id: String = sessionA, at ms: Int64 = t0, count: Int, originator: String = "codex_exec", account: String? = nil,
                             each: Usage = Usage(input: 1000, cached: 600, output: 50, reasoning: 20)) -> [String] {
        var out = [header(id: id, at: ms, originator: originator, account: account), turnContext(ordinal: 1, at: ms + 100)]
        var total = Usage(input: 0, output: 0)
        for i in 0..<count {
            total = total + each
            out.append(message(ordinal: 2 + i * 2, at: ms + 1000 + Int64(i) * 5000))
            out.append(tokenCount(ordinal: 3 + i * 2, at: ms + 2000 + Int64(i) * 5000, last: each, total: total))
        }
        return out
    }
}

extension CodexFixture {
    /// The line Codex writes when the model or the service tier of a thread is set.
    static func settings(ordinal: Int, at ms: Int64, model: String, tier: String?) -> String {
        let tierJSON = tier.map { "\"\($0)\"" } ?? "null"
        return line("event_msg", ordinal: ordinal, at: ms,
                    payload: "{\"type\":\"thread_settings_applied\",\"thread_settings\":{\"model\":\"\(model)\",\"service_tier\":\(tierJSON)}}")
    }
}
