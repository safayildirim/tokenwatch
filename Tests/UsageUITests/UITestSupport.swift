import Foundation
import XCTest
@testable import UsageCore
@testable import UsageUI

let t0: Int64 = 1_790_000_000_000

/// A scratch environment with its own database, fake Claude Code folder and quota folder.
@MainActor
final class UIEnv {
    let root: URL
    let projects: URL
    let quotaDir: URL
    let registryDir: URL
    let db: UsageDatabase
    let model: AppModel

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ccu-ui-\(UUID().uuidString)")
        projects = root.appendingPathComponent("projects")
        quotaDir = root.appendingPathComponent("quota")
        registryDir = root.appendingPathComponent("sessions")
        for d in [projects, quotaDir, registryDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        db = try UsageDatabase.open(at: root.appendingPathComponent("db/usage.sqlite"))
        model = AppModel(db: db, adapters: [ClaudeCodeAdapter(root: projects)], bridgeDirectory: quotaDir,
                         registryDirectory: registryDir, desktopCache: root.appendingPathComponent("none.json"))
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
