import XCTest
@testable import UsageCore

private typealias CF = CodexFixture

/// How long a new log line takes to reach the database while several sessions of both providers are active.
final class LiveLatencyTests: XCTestCase {
    func testManyActiveSessionsOfBothProvidersReachTheDatabaseWithinTwoSeconds() async throws {
        let env = try TestEnv()
        try FileManager.default.createDirectory(at: env.codexHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let collector = UsageCollector(db: env.db, adapters: [env.adapter, env.codexAdapter], reconcileInterval: 3600)
        await collector.start()
        try await Task.sleep(for: .milliseconds(500))

        // Six Claude sessions and three Codex sessions write at once for ten seconds.
        let base = Clock.nowMs() - 3_600_000
        var claudeFiles: [URL] = [], codexFiles: [(URL, Int)] = []
        for i in 0..<6 { claudeFiles.append(try env.mainFile(session: "LIVE\(i)")) }
        var expectedClaude = 0, expectedCodex = 0
        var codexTotals = [CF.Usage](repeating: CF.Usage(input: 0, output: 0), count: 3)
        let ids = (0..<3).map { String(format: "01a00000-0000-7000-8000-%012d", 900 + $0) }
        for (i, id) in ids.enumerated() { codexFiles.append((try env.codexFile(session: id, lines: [CF.header(id: id, at: base)]), i)) }

        let rounds = 25
        var lastWrite = Date()
        for round in 0..<rounds {
            for (i, file) in claudeFiles.enumerated() {
                let line = Fixture.assistant(id: "live-\(i)-\(round)", session: "LIVE\(i)", at: base + Int64(round) * 1000 + Int64(i), output: 20)
                if FileManager.default.fileExists(atPath: file.path) { try Fixture.append([line], to: file) } else { try Fixture.write([line], to: file) }
                expectedClaude += 1
            }
            for (file, i) in codexFiles {
                let each = CF.Usage(input: 900, cached: 300, output: 15)
                codexTotals[i] = codexTotals[i] + each
                try Fixture.append([CF.tokenCount(ordinal: 1 + round, at: base + Int64(round) * 1000 + 500 + Int64(i), last: each, total: codexTotals[i])], to: file)
                expectedCodex += 1
            }
            lastWrite = Date()
            if round < rounds - 1 { try await Task.sleep(for: .milliseconds(400)) }
        }
        let deadline = lastWrite.addingTimeInterval(15)
        var reached = false
        while Date() < deadline {
            if try env.totals().requests == expectedClaude + expectedCodex { reached = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let latency = Date().timeIntervalSince(lastWrite)
        await collector.stop()
        print(String(format: "LIVE LATENCY: %d requests from 9 concurrent sessions, last write visible in the database after %.2f s", expectedClaude + expectedCodex, latency))
        XCTAssertTrue(reached)
        XCTAssertLessThan(latency, 2.0)
        XCTAssertEqual(try env.totals().tokens.output, Int64(expectedClaude * 20 + expectedCodex * 15))
    }
}
