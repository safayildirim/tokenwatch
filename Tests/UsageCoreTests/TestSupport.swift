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

    deinit { try? FileManager.default.removeItem(at: root) }

    var adapter: ClaudeCodeAdapter { ClaudeCodeAdapter(root: projects) }
    var synchronizer: FileSynchronizer { FileSynchronizer(db: db) }

    /// Simulates quitting and relaunching the app.
    func reopen() throws {
        db.markCleanShutdown()
        db = try UsageDatabase.open(at: dbURL)
    }

    func projectDir(_ cwd: String) throws -> URL {
        let dir = projects.appendingPathComponent(IngestWriter.encodeProjectKey(cwd))
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
