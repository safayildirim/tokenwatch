import XCTest
@testable import UsageCore

private typealias CF = CodexFixture

/// A compressed run of weeks of use against the real collector, database and adapters.
///
/// Each loop iteration stands for a day. Sessions of both providers grow, forks are made, files are compressed and
/// archived the way Codex does it, the application is restarted without a clean shutdown, the Codex folder
/// disappears and comes back, and damaged lines are written. At the end every total must equal what was generated, and
/// both independent recounts must agree.
///
/// This is an accelerated test. It exercises the sequences that a long run produces, in seconds. It is not a substitute
/// for running the application for days, which is a separate validation item.
final class AcceleratedSoakTests: XCTestCase {
    /// A small deterministic random number generator, so that a failure can be reproduced.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 29)
        }
    }

    private final class CodexSession {
        let id: String
        let records: Bool
        var ordinal = 2
        var total = CF.Usage(input: 0, output: 0)
        var responses = 0
        var url: URL
        var active = true
        init(id: String, records: Bool, url: URL) { self.id = id; self.records = records; self.url = url }
    }

    private func settle(_ collector: UsageCollector) async throws {
        let before = await collector.snapshot().lastReconcileAt
        await collector.reconcileNow()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let s = await collector.snapshot()
            if s.lastReconcileAt != before, !s.isSyncing { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the collector did not settle")
    }

    private func zstd() throws -> String {
        let path = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first { FileManager.default.isExecutableFile(atPath: $0) }
        return try XCTUnwrap(path, "the zstd tool is needed to compress sessions the way Codex does")
    }

    private func compress(_ url: URL) throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try zstd())
        p.arguments = ["-q", "--rm", url.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return url.appendingPathExtension("zst")
    }

    func testWeeksOfUseWithRestartsRotationsAndOutagesStayExact() async throws {
        _ = try zstd()
        let env = try TestEnv()
        var rng = Generator(state: 20261020)
        var collector = UsageCollector(db: env.db, adapters: [env.adapter, env.codexAdapter], reconcileInterval: 3600)
        await collector.start()

        var sessions: [CodexSession] = []
        var expectedCodexOutput: Int64 = 0, expectedCodexResponses = 0
        var expectedClaudeOutput: Int64 = 0, expectedClaudeRequests = 0
        var claudeCounter = 0
        var lastQuotaEvent: Int64 = 0
        let outageName = env.root.appendingPathComponent("codex-home-away")

        func addResponse(to s: CodexSession, at ms: Int64, writing lines: inout [String]) {
            let usage = CF.Usage(input: Int64.random(in: 800...5000, using: &rng), cached: Int64.random(in: 0...700, using: &rng),
                                 output: Int64.random(in: 10...300, using: &rng), reasoning: 5)
            s.total = s.total + usage
            s.responses += 1
            lines.append(CF.message(ordinal: s.ordinal, at: ms - 500))
            s.ordinal += 1
            if s.records {
                lines.append(CF.tokenUsageRecord(ordinal: s.ordinal, at: ms, response: "resp_\(s.id.suffix(4))_\(s.responses)", usage: usage, total: s.total,
                                                 session: s.id))
                s.ordinal += 1
            }
            lastQuotaEvent = ms
            lines.append(CF.tokenCount(ordinal: s.ordinal, at: ms + 1, last: usage, total: s.total,
                                       rate: CF.rateLimits(primary: (Double(min(99, s.responses)), 300, 1_790_010_000 + Double((ms - t0) / 86_400_000) * 18_000), secondary: nil)))
            s.ordinal += 1
            expectedCodexOutput += usage.output
            expectedCodexResponses += 1
        }

        let days = 45
        for day in 0..<days {
            // The days lie in the past, because a record dated in the future is rejected as a clock error.
            let dayStart = t0 - 60 * 86_400_000 + Int64(day) * 86_400_000

            // New Codex sessions appear, in either file format.
            if day % 3 == 0 {
                let id = String(format: "01a00000-0000-7000-8000-%012d", day + 100)
                let url = try env.codexFile(session: id, lines: [CF.header(id: id, at: dayStart, account: "soak-account"), CF.turnContext(ordinal: 1, at: dayStart + 100)])
                sessions.append(CodexSession(id: id, records: day % 2 == 0, url: url))
            }
            // Active sessions grow.
            for s in sessions where s.active && Int.random(in: 0..<3, using: &rng) > 0 {
                var lines: [String] = []
                for k in 0..<Int.random(in: 1...3, using: &rng) { addResponse(to: s, at: dayStart + 3_600_000 + Int64(k) * 20_000, writing: &lines) }
                try Fixture.append(lines, to: s.url)
            }
            // A fork copies an event session's history and adds one response of its own.
            if day % 7 == 3, let parent = sessions.first(where: { $0.active && !$0.records && $0.responses > 0 }) {
                let id = String(format: "01a00000-0000-7000-8000-%012d", day + 500)
                let own = CF.Usage(input: 700, cached: 100, output: 30)
                let forkAt = dayStart + 7_200_000
                // The fork repeats the parent's file line by line, stamped with the instant of the copy.
                let parentLines = try String(contentsOf: parent.url, encoding: .utf8).split(separator: "\n").map(String.init)
                var fork = [CF.header(id: id, at: forkAt, account: "soak-account", forkedFrom: parent.id)]
                fork.append(contentsOf: parentLines.dropFirst().map { Self.restamp($0, at: forkAt + 2) })
                var total = parent.total
                total = total + own
                fork.append(CF.tokenCount(ordinal: parent.ordinal, at: forkAt + 40_000, last: own, total: total))
                let url = try env.codexFile(session: id, lines: fork)
                let child = CodexSession(id: id, records: false, url: url)
                child.active = false
                sessions.append(child)
                expectedCodexOutput += own.output
                expectedCodexResponses += 1
            }
            // Claude Code writes streaming lines, several per message.
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                claudeCounter += 1
                let id = "m\(claudeCounter)"
                let out = Int.random(in: 5...200, using: &rng)
                let file = try env.mainFile(session: "CL\(day / 10)")
                let streamed = [Fixture.assistant(id: id, session: "CL\(day / 10)", at: dayStart + Int64(claudeCounter) * 1000, output: out / 2),
                                Fixture.assistant(id: id, session: "CL\(day / 10)", at: dayStart + Int64(claudeCounter) * 1000 + 5, output: out)]
                if FileManager.default.fileExists(atPath: file.path) { try Fixture.append(streamed, to: file) } else { try Fixture.write(streamed, to: file) }
                expectedClaudeOutput += Int64(out)
                expectedClaudeRequests += 1
            }
            // Codex compresses a session that has gone quiet, and the user archives another.
            if day % 5 == 4, let s = sessions.first(where: { $0.active && $0.responses > 0 }) {
                s.url = try compress(s.url)
                s.active = false
            }
            if day % 8 == 7, let s = sessions.first(where: { !$0.active && !$0.url.path.contains("archived_sessions") && $0.url.pathExtension == "zst" }) {
                let archived = env.codexHome.appendingPathComponent("archived_sessions")
                try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
                let target = archived.appendingPathComponent(s.url.lastPathComponent)
                try FileManager.default.moveItem(at: s.url, to: target)
                s.url = target
            }
            // A line is damaged.
            if day % 13 == 12, let s = sessions.first(where: { $0.active }) { try Fixture.append(["{ broken line \(day)"], to: s.url) }

            // The Codex folder is unavailable for a day, while Claude Code keeps working.
            if day % 11 == 10 {
                try FileManager.default.moveItem(at: env.codexHome, to: outageName)
                try await settle(collector)
                let snapshot = await collector.snapshot()
                XCTAssertEqual(snapshot.sources.first { $0.sourceID == .codexRollouts }?.state, .notFound)
                XCTAssertEqual(snapshot.sources.first { $0.sourceID == .claudeTranscripts }?.state, .ok, "an outage of one provider does not affect the other")
                try FileManager.default.moveItem(at: outageName, to: env.codexHome)
            }
            // The application is killed without a clean shutdown and started again.
            if day % 9 == 8 {
                await collector.stop()
                try env.reopen()
                collector = UsageCollector(db: env.db, adapters: [env.adapter, env.codexAdapter], reconcileInterval: 3600)
                await collector.start()
            }
            try await settle(collector)
        }
        await collector.stop()

        // Every total equals what was generated.
        let claude = try env.db.read { try $0.queryOne("SELECT COALESCE(sum(r.output_tokens), 0), count(*) FROM model_request r JOIN product p ON p.id = r.product_id WHERE p.provider_id = 'anthropic'") { ($0.int(0), $0.int(1)) } }
        let codex = try env.db.read { try $0.queryOne("SELECT COALESCE(sum(r.output_tokens), 0), count(*) FROM model_request r JOIN product p ON p.id = r.product_id WHERE p.provider_id = 'openai'") { ($0.int(0), $0.int(1)) } }
        XCTAssertEqual(claude?.0, expectedClaudeOutput)
        XCTAssertEqual(claude?.1, Int64(expectedClaudeRequests))
        XCTAssertEqual(codex?.0, expectedCodexOutput)
        XCTAssertEqual(codex?.1, Int64(expectedCodexResponses))

        // The scenario really contained what it is meant to test.
        func count(_ sql: String) throws -> Int64 { try env.db.read { try $0.scalarInt(sql) } ?? 0 }
        XCTAssertGreaterThan(try count("SELECT count(*) FROM source_file WHERE path LIKE '%.zst' AND status = 'ok'"), 2, "compressed sessions")
        XCTAssertGreaterThan(try count("SELECT count(*) FROM source_file WHERE path LIKE '%archived_sessions%'"), 0, "archived sessions")
        XCTAssertGreaterThan(try count("SELECT count(*) FROM source_file WHERE status = 'missing'"), 0, "files that were compressed or moved away")
        XCTAssertGreaterThan(try count("SELECT sum(malformed_lines) FROM source_file"), 0, "damaged lines")
        XCTAssertGreaterThan(try count("SELECT count(*) FROM session WHERE parent_external_id IS NOT NULL"), 2, "forks")
        XCTAssertGreaterThan(sessions.filter { $0.records }.count, 2)

        // Nothing is stored twice, and the database is sound.
        let duplicates = try env.db.read { try $0.scalarInt("SELECT count(*) FROM (SELECT product_id, request_key FROM model_request GROUP BY 1, 2 HAVING count(*) > 1)") }
        XCTAssertEqual(duplicates, 0)
        XCTAssertEqual(try env.db.integrityCheck(), ["ok"])
        XCTAssertEqual(try env.db.foreignKeyViolations(), 0)
        XCTAssertTrue(try CodexVerifier(db: env.db, adapter: env.codexAdapter).verify().isConsistent)
        let claudeReport = try SourceVerifier(db: env.db, adapter: env.adapter).verify()
        XCTAssertTrue(claudeReport.isConsistent, "\(claudeReport.mismatches)")

        // The quota reading is as old as the last event that carried it, however often the files were read.
        let confirmed = try env.db.read { try $0.scalarInt("SELECT max(last_confirmed_at) FROM quota_snapshot") }
        XCTAssertLessThanOrEqual(confirmed ?? 0, lastQuotaEvent + 1)
    }

    /// Rewrites the timestamp of a copied line to the instant of the copy.
    private static func restamp(_ line: String, at ms: Int64) -> String {
        guard let range = line.range(of: #""timestamp":"[^"]+""#, options: .regularExpression) else { return line }
        return line.replacingCharacters(in: range, with: "\"timestamp\":\"\(Fixture.ts(ms))\"")
    }
}
