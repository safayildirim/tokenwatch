import Foundation
import XCTest
@testable import UsageCore
@testable import UsageUI

let t0: Int64 = 1_790_000_000_000

/// A scratch environment with its own database, fake Claude Code and Codex folders and quota folder.
@MainActor
final class UIEnv {
    let root: URL
    let projects: URL
    let codexHome: URL
    let quotaDir: URL
    let registryDir: URL
    let db: UsageDatabase
    let model: AppModel

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-ui-\(UUID().uuidString)")
        projects = root.appendingPathComponent("projects")
        codexHome = root.appendingPathComponent("codex-home")
        quotaDir = root.appendingPathComponent("quota")
        registryDir = root.appendingPathComponent("sessions")
        for d in [projects, quotaDir, registryDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        db = try UsageDatabase.open(at: root.appendingPathComponent("db/usage.sqlite"))
        model = AppModel(db: db, adapters: [ClaudeCodeAdapter(root: projects), CodexAdapter(home: codexHome)], bridgeDirectory: quotaDir,
                         registryDirectory: registryDir, desktopCache: root.appendingPathComponent("none.json"),
                         claudeCache: root.appendingPathComponent("none-cache.json"))
        model.uiVisibilityOverride = true
    }

    func cleanup() async {
        await model.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func writeSession(_ id: String, cwd: String = "/Users/test/alpha", lines: Int = 5, at start: Int64 = t0,
                      model modelName: String = "claude-opus-5-5") throws {
        let key = String(cwd.unicodeScalars.map { ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0))) ? Character($0) : "-" })
        let dir = projects.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = ""
        for i in 0..<lines {
            text += assistantLine(id: "\(id)-\(i)", session: id, at: start + Int64(i) * 1000, cwd: cwd, model: modelName) + "\n"
        }
        try text.write(to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    /// Writes a Codex session of `lines` responses. Every response reports the given quota snapshot.
    func writeCodexSession(_ id: String, originator: String = "codex_exec", account: String? = "acct-ui", lines: Int = 4, at start: Int64 = t0,
                           primary: Double = 12, secondary: Double = 34, plan: String = "plus") throws {
        let dir = codexHome.appendingPathComponent("sessions/2026/10/12")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func ts(_ ms: Int64) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        let accountField = account.map { ",\"creator_account_id\":\"\($0)\"" } ?? ""
        var out = ["{\"timestamp\":\"\(ts(start))\",\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"session_id\":\"\(id)\",\"timestamp\":\"\(ts(start))\",\"cwd\":\"/Users/test/codex-project\",\"originator\":\"\(originator)\",\"cli_version\":\"0.1.0\",\"source\":\"exec\"\(accountField)}}",
                   "{\"timestamp\":\"\(ts(start + 10))\",\"ordinal\":1,\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-test\"}}"]
        let resets = Double(start) / 1000 + 3 * 3600
        for i in 0..<lines {
            let total = (i + 1) * 1000
            let usage = "{\"input_tokens\":1000,\"cached_input_tokens\":600,\"cache_write_input_tokens\":0,\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":1000}"
            let totals = "{\"input_tokens\":\(total),\"cached_input_tokens\":\(i * 600 + 600),\"cache_write_input_tokens\":0,\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":\(total)}"
            out.append("{\"timestamp\":\"\(ts(start + 1000 + Int64(i) * 1000))\",\"ordinal\":\(2 + i),\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(totals),\"last_token_usage\":\(usage)},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":\(primary),\"window_minutes\":300,\"resets_at\":\(Int64(resets))},\"secondary\":{\"used_percent\":\(secondary),\"window_minutes\":10080,\"resets_at\":\(Int64(resets) + 400000)},\"plan_type\":\"\(plan)\"}}}")
        }
        try (out.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("rollout-2026-10-12T12-00-00-\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    func writeQuota(five: Double?, week: Double?, observed: Date = Date(), resetsIn: TimeInterval = 3600) throws {
        var limits: [String: QuotaBridgeFile.Window] = [:]
        if let five { limits["five_hour"] = .init(usedPercentage: five, resetsAt: observed.addingTimeInterval(resetsIn).timeIntervalSince1970) }
        if let week { limits["seven_day"] = .init(usedPercentage: week, resetsAt: observed.addingTimeInterval(resetsIn * 40).timeIntervalSince1970) }
        let f = QuotaBridgeFile(sessionId: "s1", observedAt: Clock.ms(observed), capturedAt: Clock.ms(observed), fingerprint: UUID().uuidString, rateLimits: limits)
        try JSONEncoder().encode(f).write(to: quotaDir.appendingPathComponent("statusline-s1.json"))
    }

    func waitUntil(_ timeout: TimeInterval = 15, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("condition not met within \(timeout)s")
    }
}

func assistantLine(id: String, session: String, at ms: Int64, cwd: String, model: String = "claude-opus-5-5",
                   output: Int = 100, cacheRead: Int = 5000) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    let ts = f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    return "{\"message\":{\"model\":\"\(model)\",\"id\":\"\(id)\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":3,\"cache_creation_input_tokens\":200,\"cache_read_input_tokens\":\(cacheRead),\"output_tokens\":\(output),\"cache_creation\":{\"ephemeral_5m_input_tokens\":0,\"ephemeral_1h_input_tokens\":200},\"speed\":\"standard\"}},\"requestId\":\"req_\(id)\",\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"sessionId\":\"\(session)\",\"cwd\":\"\(cwd)\",\"version\":\"2.1.296\",\"entrypoint\":\"cli\"}"
}


extension AppModel {
    /// The state of one window (by its length key, such as `300m`) of the first pool of a provider that has it.
    func quotaState(_ windowKey: String, _ provider: ProviderID = .anthropic) -> QuotaWindowState? {
        quotaStates.first { $0.pool.key.provider == provider && $0.windowKey == windowKey }
    }
}
