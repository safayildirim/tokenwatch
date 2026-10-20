import XCTest
@testable import UsageCore

final class ExportTests: XCTestCase {
    private func populate(_ env: TestEnv) throws {
        try Fixture.write([
            Fixture.assistant(id: "a1", session: "SA", at: t0, input: 3, output: 120, cacheRead: 1000, cacheCreation: 200, fiveMinute: 50, oneHour: 150, cwd: "/Users/test/=cmd,x"),
            Fixture.assistant(id: "a2", model: "claude-sonnet-5-5", session: "SA", at: t0 + 90_000_000, output: 40, cacheRead: 500, cwd: "/Users/test/=cmd,x"),
        ], to: try env.mainFile(cwd: "/Users/test/=cmd,x", session: "SA"))
        try env.syncAll()
    }

    private func export(_ env: TestEnv, _ kind: ExportKind, _ format: ExportFormat, range: ClosedRange<Date>? = nil) throws -> (URL, ExportResult) {
        let url = env.root.appendingPathComponent("out/\(kind.rawValue).\(format.rawValue)")
        return (url, try ExportService(db: env.db).export(kind: kind, format: format, range: range, to: url))
    }

    func testRequestLevelCSVHasOneRowPerRequestAndExactNumbers() throws {
        let env = try TestEnv()
        try populate(env)
        let (url, result) = try export(env, .requests, .csv)
        XCTAssertEqual(result.rows, 2)
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)
        let header = lines[0].components(separatedBy: ",")
        let row = lines[1].components(separatedBy: ",")
        func value(_ col: String) -> String { row[header.firstIndex(of: col)!] }
        XCTAssertEqual(value("uncached_input_tokens"), "3")
        XCTAssertEqual(value("output_tokens"), "120")
        XCTAssertEqual(value("cache_read_tokens"), "1000")
        XCTAssertEqual(value("cache_creation_tokens"), "200")
        XCTAssertEqual(value("cache_creation_5m_tokens"), "50")
        XCTAssertEqual(value("cache_creation_1h_tokens"), "150")
        XCTAssertEqual(value("logical_input_tokens"), "1203")
        XCTAssertEqual(value("total_processed_tokens"), "1323")
        // The expected cost is 3 input tokens at $4, 120 output at $20, 1000 cache reads at $0.20, 50 at $5 and 150 at $8 per million, as an exact decimal.
        let picos = 3 * 4_000_000 + 120 * 20_000_000 + 1000 * 200_000 + 50 * 5_000_000 + 150 * 8_000_000
        XCTAssertEqual(value("estimated_cost_pico_usd"), String(picos))
        XCTAssertEqual(value("estimated_cost_usd"), "0.004062", "exact decimal dollars, no rounding")
    }

    func testCompanionMetadataDefinesEveryColumn() throws {
        let env = try TestEnv()
        try populate(env)
        let (url, _) = try export(env, .sessions, .csv)
        let meta = url.deletingPathExtension().appendingPathExtension("metadata.json")
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: meta)) as! [String: Any]
        let columns = m["columns"] as! [[String: String]]
        let header = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\r\n")[0].components(separatedBy: ",")
        XCTAssertEqual(columns.map { $0["name"]! }, header, "the metadata documents exactly the exported columns")
        XCTAssertTrue(columns.allSatisfy { !($0["definition"] ?? "").isEmpty })
        XCTAssertTrue((m["pricing_note"] as! String).contains("not subscription"))
        XCTAssertTrue((m["quota_note"] as! String).contains("never computed from token counts"))
    }

    func testJSONExportIsValidAndSelfDescribing() throws {
        let env = try TestEnv()
        try populate(env)
        for kind in ExportKind.allCases {
            let (url, result) = try export(env, kind, .json)
            let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            XCTAssertEqual((doc["rows"] as! [Any]).count, result.rows, "\(kind)")
            XCTAssertNotNil(doc["metadata"], "\(kind)")
        }
    }

    func testTextCellsAreEscapedAndCannotBecomeSpreadsheetFormulas() throws {
        let env = try TestEnv()
        try populate(env)
        let (url, _) = try export(env, .projects, .csv)
        let text = try String(contentsOf: url, encoding: .utf8)
        // The project folder is named =cmd,x: the comma forces quoting, and the leading '=' is neutralized.
        XCTAssertTrue(text.contains("\"'=cmd,x\""), text)
        XCTAssertEqual(TableSink.csvEscape("say \"hi\", ok"), "\"say \"\"hi\"\", ok\"")
        XCTAssertEqual(TableSink.neutralizeFormula("+1+1"), "'+1+1")
        XCTAssertEqual(TableSink.neutralizeFormula("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(TableSink.neutralizeFormula("plain"), "plain")
    }

    func testDateRangeSelectsRequests() throws {
        let env = try TestEnv()
        try populate(env)
        let range = Clock.date(ms: t0 + 80_000_000)...Clock.date(ms: t0 + 100_000_000)
        let (_, r) = try export(env, .requests, .json, range: range)
        XCTAssertEqual(r.rows, 1)
        let (_, none) = try export(env, .requests, .csv, range: Clock.date(ms: t0 - 10_000)...Clock.date(ms: t0 - 5_000))
        XCTAssertEqual(none.rows, 0)
    }

    func testDailyTotalsExportMatchesTheTotal() throws {
        let env = try TestEnv()
        try populate(env)
        let (url, r) = try export(env, .daily, .json)
        XCTAssertEqual(r.rows, 2, "the two requests are more than a day apart")
        let rows = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["rows"] as! [[String: Any]]
        XCTAssertEqual(rows.reduce(0) { $0 + ($1["output_tokens"] as! Int) }, 160)
    }

    func testLargeRequestExportStreamsEveryRow() throws {
        let env = try TestEnv()
        try Fixture.write((0..<5000).map { Fixture.assistant(id: "m\($0)", session: "S", at: t0 + Int64($0), output: 1) }, to: try env.mainFile(session: "S"))
        try env.syncAll()
        let (url, r) = try export(env, .requests, .csv)
        XCTAssertEqual(r.rows, 5000)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\r\n").count, 5002)
    }

    func testExactDecimalDollarFormatting() {
        XCTAssertEqual(ExportService.usd(0), "0.00")
        XCTAssertEqual(ExportService.usd(1), "0.000000000001")
        XCTAssertEqual(ExportService.usd(37_200_000_000_000), "37.20")
        XCTAssertEqual(ExportService.usd(1_234_567_890_123_456), "1234.567890123456")
    }
}

/// Usage monitoring must never keep what users typed or what Claude answered.
final class PrivacyTests: XCTestCase {
    func testNoConversationContentReachesTheDatabaseOrExports() throws {
        let env = try TestEnv()
        let secrets = ["SUPER-SECRET-PROMPT-TEXT", "api_key=sk-ant-TOPSECRET", "/Users/test/private/file.swift", "def leaked_source_code"]
        let leakyUser = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(secrets[0])\"},\"toolUseResult\":{\"stdout\":\"\(secrets[1])\",\"filePath\":\"\(secrets[2])\"},\"timestamp\":\"\(Fixture.ts(t0))\",\"sessionId\":\"S1\",\"cwd\":\"/Users/test/alpha\",\"version\":\"2.1.296\",\"entrypoint\":\"cli\"}"
        let leakyAssistant = Fixture.assistant(id: "m1", session: "S1", at: t0 + 10, output: 5)
            .replacingOccurrences(of: "\"REDACTED\"", with: "\"\(secrets[3])\"")
        let aiTitle = "{\"type\":\"ai-title\",\"sessionId\":\"S1\",\"aiTitle\":\"Rewrite the payment service\"}"
        let lastPrompt = "{\"type\":\"last-prompt\",\"lastPrompt\":\"\(secrets[0])\",\"sessionId\":\"S1\"}"
        try Fixture.write([leakyUser, leakyAssistant, aiTitle, lastPrompt], to: try env.mainFile(session: "S1"))
        try env.syncAll()

        env.db.markCleanShutdown()
        var haystacks: [Data] = []
        for suffix in ["", "-wal", "-shm"] {
            if let d = FileManager.default.contents(atPath: env.dbURL.path + suffix) { haystacks.append(d) }
        }
        for kind in ExportKind.allCases {
            for format in ExportFormat.allCases {
                let url = env.root.appendingPathComponent("exp/\(kind.rawValue).\(format.rawValue)")
                _ = try ExportService(db: env.db).export(kind: kind, format: format, to: url)
                haystacks.append(try Data(contentsOf: url))
            }
        }
        for needle in secrets + ["Rewrite the payment service", "REDACTED"] {
            for h in haystacks {
                XCTAssertNil(h.range(of: Data(needle.utf8)), "'\(needle)' must never be stored or exported")
            }
        }
        // The metadata that is needed is still there.
        XCTAssertEqual(try env.totals().tokens.output, 5)
    }

    func testStatusLineBridgeDoesNotCopyUnrelatedInput() throws {
        // Covered end to end in BridgeBinaryTests.testWritesOnlyTheRateLimitsAndPrintsASummary; this
        // test documents that the stored file type cannot even represent anything else.
        let mirror = Mirror(reflecting: QuotaBridgeFile(sessionId: "s", observedAt: 0, capturedAt: 0, fingerprint: "", rateLimits: [:]))
        XCTAssertEqual(Set(mirror.children.compactMap(\.label)), ["schema", "sessionId", "observedAt", "capturedAt", "fingerprint", "rateLimits"])
    }
}

final class SourceVerifierTests: XCTestCase {
    func testIndependentRecountAgreesWithTheDatabase() throws {
        let env = try TestEnv()
        try Fixture.write([
            Fixture.assistant(id: "m1", session: "S1", at: t0, output: 8, cacheRead: 1000, cacheCreation: 10),
            Fixture.assistant(id: "m1", session: "S1", at: t0 + 100, output: 90, cacheRead: 1000, cacheCreation: 10),
            Fixture.assistant(id: "m1", session: "S1", at: t0 + 900, input: 0, output: 0, cacheRead: 0, cacheCreation: 0),
            Fixture.assistant(id: "m2", session: "S1", at: t0 + 1000, output: 33, cacheRead: 2000),
        ], to: try env.mainFile(session: "S1"))
        try Fixture.write([Fixture.assistant(id: "s1", session: "S1", at: t0 + 2000, output: 7, agent: "A")], to: try env.subagentFile(session: "S1", agent: "A"))
        try env.syncAll()
        let report = try SourceVerifier(db: env.db, adapter: env.adapter).verify()
        XCTAssertTrue(report.isConsistent, "\(report.mismatches)")
        XCTAssertEqual(report.requestsInSource, 3)
        XCTAssertEqual(report.sourceTotals.output, 130)
        XCTAssertEqual(report.sourceTotals, report.databaseTotals)
        XCTAssertGreaterThan(report.naiveSumOfAllLines.output, report.sourceTotals.output, "summing every line would have overcounted")
    }

    func testVerifierDetectsTampering() throws {
        let env = try TestEnv()
        try Fixture.write([Fixture.assistant(id: "m1", session: "S1", at: t0, output: 50)], to: try env.mainFile(session: "S1"))
        try env.syncAll()
        try env.db.write { try $0.run("UPDATE model_request SET output_tokens = 51") }
        let report = try SourceVerifier(db: env.db, adapter: env.adapter).verify()
        XCTAssertFalse(report.isConsistent)
        XCTAssertEqual(report.mismatches.first?.field, "output")
        XCTAssertEqual(report.mismatches.first?.database, 51)
        XCTAssertEqual(report.mismatches.first?.source, 50)
    }
}
