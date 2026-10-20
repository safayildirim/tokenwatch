import XCTest
@testable import UsageCore

/// Proves that provider knowledge stays where it belongs.
final class ArchitectureIsolationTests: XCTestCase {
    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UsageCore")
    }

    /// The files that are allowed to name a provider. Each one either describes a provider (identifiers, the built-in
    /// registry, prices, model names), reads a provider's files, or belongs to a provider's own tooling.
    private let providerSpecific: Set<String> = [
        "Domain/BuiltinProviders.swift",
        "Domain/ModelCatalog.swift",
        "Pricing/BuiltinPricing.swift",
        "Pricing/OpenAIPricing.swift",
        "Ingest/ClaudeCodeAdapter.swift",
        "Ingest/CodexAdapter.swift",
        "Ingest/CodexLineParser.swift",
        "Ingest/CodexVerifier.swift",
        "Ingest/SourceVerifier.swift",
        "Ingest/SessionRegistryMonitor.swift",
        "Quota/QuotaSources.swift",
        "Quota/StatusLineInstaller.swift",
    ]

    private let providerWords = try! NSRegularExpression(pattern: "claude|anthropic|codex|openai|chatgpt|gemini|gpt-", options: .caseInsensitive)

    private func swiftFiles() throws -> [String] {
        let base = sourcesDirectory.path + "/"
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: sourcesDirectory.path))
        return (walker.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }.map { String($0.hasPrefix(base) ? $0.dropFirst(base.count) : Substring($0)) }.sorted()
    }

    /// Code with its comments removed. Comments may explain with examples, but code and text strings may not.
    private func code(_ relativePath: String) throws -> [(line: Int, text: String)] {
        let text = try String(contentsOf: sourcesDirectory.appendingPathComponent(relativePath), encoding: .utf8)
        return text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let stripped = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
            return stripped.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (index + 1, stripped)
        }
    }

    func testOnlyDesignatedFilesNameAProvider() throws {
        var violations: [String] = []
        for file in try swiftFiles() where !providerSpecific.contains(file) {
            for (number, text) in try code(file) {
                let range = NSRange(text.startIndex..., in: text)
                if providerWords.firstMatch(in: text, range: range) != nil {
                    violations.append("\(file):\(number): \(text.trimmingCharacters(in: .whitespaces).prefix(100))")
                }
            }
        }
        XCTAssertEqual(violations, [], "provider names belong in the designated files only")
    }

    func testEveryDesignatedFileExists() throws {
        let files = Set(try swiftFiles())
        for name in providerSpecific { XCTAssertTrue(files.contains(name), "\(name) is listed but missing") }
    }

    func testTheSharedCoreNeverReachesForAProvidersAdapter() throws {
        // The collector, writer, analytics and quota code work through protocols. They must not name an adapter type.
        let adapters = ["ClaudeCodeAdapter", "CodexAdapter", "ClaudeCodeLineParser", "CodexLineParser", "StatusLineQuotaSource", "StatusLineInstaller"]
        for file in ["Ingest/UsageCollector.swift", "Ingest/FileSynchronizer.swift", "Storage/IngestWriter.swift", "Storage/EntityStore.swift",
                     "Analytics/AnalyticsEngine.swift", "Quota/QuotaCoordinator.swift", "Alerts/AlertEngine.swift", "Export/ExportService.swift"] {
            let all = try code(file).map(\.text).joined(separator: "\n")
            for name in adapters { XCTAssertFalse(all.contains(name), "\(file) names \(name)") }
        }
    }

    func testTheSchemaHoldsNoProviderSpecificColumns() throws {
        let env = try TestEnv()
        let columns: [String] = try env.db.read { c in
            try c.query("SELECT m.name || '.' || p.name FROM sqlite_master m, pragma_table_info(m.name) p WHERE m.type = 'table'") { $0.text(0) }
        }
        for column in columns {
            let range = NSRange(column.startIndex..., in: column)
            XCTAssertNil(providerWords.firstMatch(in: column, range: range), column)
        }
        // The entities that make the model first-class each have a table.
        let tables = Set(try env.db.read { try $0.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) } })
        for needed in ["provider", "product", "surface", "telemetry_source", "account", "pool_definition", "pool_membership",
                       "quota_pool", "quota_window", "quota_cycle", "quota_snapshot", "model", "session", "model_request"] {
            XCTAssertTrue(tables.contains(needed), needed)
        }
    }

    func testTheRegistryDescribesTheBuiltInProvidersAsData() {
        let r = ProviderRegistry.builtin
        XCTAssertEqual(Set(r.providers.map(\.id)), [.anthropic, .openAI])
        // Every product belongs to a known provider, every pool member to a known product, every source to both.
        for product in r.products { XCTAssertNotNil(r.provider(product.provider), product.id.rawValue) }
        for pool in r.pools {
            XCTAssertNotNil(r.provider(pool.provider))
            for member in pool.products { XCTAssertEqual(r.providerOf(product: member), pool.provider, "a pool never spans providers") }
        }
        for source in r.sources {
            XCTAssertNotNil(r.provider(source.provider))
            for product in source.products { XCTAssertEqual(r.providerOf(product: product), source.provider) }
        }
        // ChatGPT Chat is a product with a pool of its own and no source.
        XCTAssertNotNil(r.product(.chatGPTChat))
        XCTAssertTrue(r.sources.allSatisfy { !$0.products.contains(.chatGPTChat) })
        // Codex and Work share a pool. Chat does not.
        XCTAssertEqual(r.pools(of: .codex).map(\.key), r.pools(of: .chatGPTWork).map(\.key))
        XCTAssertFalse(r.pools(of: .chatGPTChat).contains { $0.key == "codex" })
    }
}

// MARK: - A provider that does not exist yet

/// A made-up provider, supplied only by a registry and an adapter that live in this test target.
///
/// Nothing in the application's sources mentions it. That the following tests pass, using the real collector,
/// writer, analytics, pricing, export, quota and alert code, shows what adding a provider takes.
private enum Gemini {
    static let provider: ProviderID = "gemini"
    static let product: ProductID = "gemini-cli"
    static let source: TelemetrySourceID = "gemini-sessions"

    static let registry = ProviderRegistry.builtin.adding(ProviderRegistry(
        providers: [ProviderDefinition(id: provider, name: "Google Gemini", shortName: "Gemini", symbol: "star")],
        products: [ProductDefinition(id: product, provider: provider, name: "Gemini CLI", observability: "Session files are observed.")],
        surfaces: [SurfaceDefinition(id: "gemini-terminal", name: "Gemini terminal", symbol: "terminal")],
        pools: [QuotaPoolDefinition(key: "gemini-daily", provider: provider, name: "Gemini daily requests", products: [product],
                                    note: "A daily allowance.", standardWindowMinutes: [1440])],
        sources: [TelemetrySourceDefinition(id: source, provider: provider, products: [product], kind: .sessionLogs,
                                            name: "Gemini session files", capabilities: [.sessions, .requestTokens, .quotaUtilization],
                                            limitations: "Test fixture.")]))
}

/// Reads `*.gemini.jsonl` files whose lines look nothing like the built-in providers'. In this format the prompt
/// count includes cached tokens, as OpenAI's does, but thinking tokens are reported beside the answer instead of
/// inside it, so the adapter has to add them to get the canonical output.
private struct GeminiAdapter: SourceAdapter {
    let directory: URL
    var sourceID: TelemetrySourceID { Gemini.source }
    var displayName: String { "Gemini" }
    var watchRoots: [URL] { [directory] }
    var coverageNote: String { "Test fixture." }

    func discoverFiles() throws -> [SourceFileRef] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".gemini.jsonl") }
            .map { SourceFileRef(sourceID: sourceID, path: directory.appendingPathComponent($0).path) }
    }
    func fileRef(forPath path: String) -> SourceFileRef? {
        path.hasSuffix(".gemini.jsonl") ? SourceFileRef(sourceID: sourceID, path: path) : nil
    }
    func makeParser(for file: SourceFileRef) -> any LineParser { Parser(source: sourceID) }

    final class Parser: LineParser {
        let source: TelemetrySourceID
        var sessions: [String: SessionObservation] = [:]
        init(source: TelemetrySourceID) { self.source = source }

        func parse(line: UnsafeBufferPointer<UInt8>, offset: Int64, into batch: inout NormalizedBatch) {
            batch.lineCount += 1
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let t = (o["t"] as? NSNumber)?.int64Value, let session = o["session"] as? String else {
                batch.malformedLineCount += 1; return
            }
            let prompt = (o["prompt"] as? NSNumber)?.int64Value ?? 0, cached = (o["cached"] as? NSNumber)?.int64Value ?? 0
            let answer = (o["answer"] as? NSNumber)?.int64Value ?? 0, thinking = (o["thinking"] as? NSNumber)?.int64Value ?? 0
            let usage = UsageMeasurement(uncachedInput: prompt - cached, cacheRead: cached, output: answer + thinking,
                                         reasoningOutput: thinking, normalization: "gemini.test.v1")
            batch.add(RequestObservation(product: Gemini.product, source: source, requestKey: "\(session):\(offset)", sessionExternalID: session,
                                         model: (o["model"] as? String) ?? "gemini-test", requestedAtMs: t, usage: usage))
            batch.add(SessionObservation(product: Gemini.product, source: source, externalID: session, projectKey: "/work/gemini-project",
                                         cwd: "/work/gemini-project", surface: "gemini-terminal", account: .identified(provider: Gemini.provider, rawIdentifier: "me@example.test"),
                                         firstSeenMs: t, lastSeenMs: t))
            if let used = (o["daily_used"] as? NSNumber)?.doubleValue, let reset = (o["daily_resets"] as? NSNumber)?.doubleValue {
                batch.add(QuotaObservation(provider: Gemini.provider, account: .identified(provider: Gemini.provider, rawIdentifier: "me@example.test"),
                                           poolKey: "gemini-daily", windowKey: WindowNaming.key(minutes: 1440), windowMinutes: 1440,
                                           utilizationPercent: used, resetsAt: Date(timeIntervalSince1970: reset), observedAt: Clock.date(ms: t),
                                           source: source, originProduct: Gemini.product, originSession: session))
            }
        }
        func flush(into batch: inout NormalizedBatch) {}
    }
}

final class FutureProviderTests: XCTestCase {
    private func environment() throws -> (TestEnv, UsageDatabase, GeminiAdapter) {
        let env = try TestEnv()
        let db = try UsageDatabase.open(at: env.root.appendingPathComponent("gemini/usage.sqlite"), registry: Gemini.registry)
        let dir = env.root.appendingPathComponent("gemini-files")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = (0..<4).map { i in
            "{\"t\":\(t0 + Int64(i) * 1000),\"session\":\"G1\",\"model\":\"gemini-test\",\"prompt\":1000,\"cached\":400,\"answer\":80,\"thinking\":20,\"daily_used\":\(10 + i * 5),\"daily_resets\":\(Double(t0) / 1000 + 80_000)}"
        }
        try Fixture.write(lines, to: dir.appendingPathComponent("a.gemini.jsonl"))
        return (env, db, GeminiAdapter(directory: dir))
    }

    func testANewProviderFlowsThroughTheWholePipeline() async throws {
        let (env, db, adapter) = try environment()
        let sync = FileSynchronizer(db: db)
        for file in try adapter.discoverFiles() { _ = try sync.sync(file: file, adapter: adapter) }

        let engine = AnalyticsEngine(db: db)
        var filter = UsageFilter(); filter.providers = [Gemini.provider]
        let totals = try engine.totals(filter)
        XCTAssertEqual(totals.requests, 4)
        XCTAssertEqual(totals.tokens.uncachedInput, 4 * 600)
        XCTAssertEqual(totals.tokens.cacheRead, 4 * 400)
        XCTAssertEqual(totals.tokens.output, 4 * 100, "thinking tokens were added to the answer once, by this provider's normalization")
        XCTAssertEqual(totals.tokens.reasoningOutput, 4 * 20, "and reasoning is a part of output, never added to it")
        XCTAssertEqual(totals.tokens.totalProcessed, 4 * 1100)

        let options = try engine.filterOptions()
        XCTAssertTrue(options.providers.contains(Gemini.provider))
        XCTAssertEqual(options.surfaces, ["gemini-terminal"])
        let session = try XCTUnwrap(engine.sessionRows(filter).first)
        XCTAssertEqual(session.provider, Gemini.provider)
        XCTAssertEqual(session.productID, Gemini.product)
        XCTAssertFalse(session.accountLabel.contains("example"), "the account identifier is hashed")

        // Pricing is a rate card for the provider, supplied as data.
        XCTAssertEqual(try engine.totals(filter).cost.unpricedTokens, 4 * 1100)
        try PricingStore.upsertUserRate(db, PriceRate(provider: Gemini.provider, model: "gemini-test", input: 1, output: 2, cacheRead: 0.5, cache5m: 1, cache1h: 1))
        let priced = try engine.totals(filter).cost
        XCTAssertEqual(priced.unpricedTokens, 0)
        // Per request: 600 uncached tokens at 1 USD, 400 cached at 0.5 USD and 100 output tokens at 2 USD per million.
        let perRequest: Int64 = 1_000_000_000
        XCTAssertEqual(priced.picoUSD, 4 * perRequest, "the reasoning tokens are priced once, as part of output")
        _ = env
    }

    func testANewProvidersQuotaPoolIsEvaluatedAndAlertedLikeAnyOther() async throws {
        let (env, db, adapter) = try environment()
        defer { withExtendedLifetime(env) {} }
        let sync = FileSynchronizer(db: db)
        for file in try adapter.discoverFiles() { _ = try sync.sync(file: file, adapter: adapter) }
        let now = Date(timeIntervalSince1970: Double(t0) / 1000 + 30)
        let coordinator = QuotaCoordinator(db: db, settings: SettingsStore(db: db), feeds: [], clock: { now })
        let pools = await coordinator.pools()
        let pool = try XCTUnwrap(pools.first { $0.pool.key.provider == Gemini.provider })
        XCTAssertEqual(pool.pool.name, "Gemini daily requests")
        XCTAssertEqual(pool.windows.map(\.windowKey), ["1440m"])
        XCTAssertEqual(pool.windows.first?.displayName, "Daily window")
        XCTAssertEqual(pool.windows.first?.utilizationPercent, 25)
        XCTAssertTrue(pool.windows[0].isShort, "a window of a day or less is a short one")

        var settings = NotificationSettings(); settings.enabled = true
        let engine = AlertEngine(db: db)
        XCTAssertTrue(engine.evaluate(states: pool.windows, sources: [], activeProviders: [Gemini.provider], settings: settings, now: now).isEmpty,
                      "25% crosses no threshold")
        // The same window at 80% raises exactly one alert, through the same rules as every other provider's.
        var high = pool.windows[0]
        high.reading?.utilizationPercent = 80
        let alerts = engine.evaluate(states: [high], sources: [], activeProviders: [Gemini.provider], settings: settings, now: now)
        XCTAssertEqual(alerts.filter { $0.kind == .threshold }.count, 1)
        XCTAssertTrue(alerts[0].title.contains("Gemini daily requests"))
    }

    func testANewProviderCanBeExportedAndFiltered() throws {
        let (env, db, adapter) = try environment()
        let sync = FileSynchronizer(db: db)
        for file in try adapter.discoverFiles() { _ = try sync.sync(file: file, adapter: adapter) }
        let out = env.root.appendingPathComponent("requests.csv")
        var filter = UsageFilter(); filter.providers = [Gemini.provider]
        let result = try ExportService(db: db).export(kind: .requests, format: .csv, to: out, filter: filter)
        XCTAssertEqual(result.rows, 4)
        let csv = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(csv.contains("gemini,gemini-cli"))
        XCTAssertTrue(csv.contains("reasoning_output_tokens"))
    }

    func testBuiltInProvidersAreUnaffectedByAnAddedOne() throws {
        let (env, db, adapter) = try environment()
        let sync = FileSynchronizer(db: db)
        for file in try adapter.discoverFiles() { _ = try sync.sync(file: file, adapter: adapter) }
        let a = ClaudeCodeAdapter(root: env.projects)
        try Fixture.write([Fixture.assistant(id: "m1", session: "S", at: t0, input: 3, output: 4, cacheRead: 5)], to: try env.mainFile(session: "S"))
        for file in try a.discoverFiles() { _ = try sync.sync(file: file, adapter: a) }
        let engine = AnalyticsEngine(db: db)
        var claude = UsageFilter(); claude.providers = [.anthropic]
        XCTAssertEqual(try engine.totals(claude).tokens.output, 4)
        XCTAssertEqual(try engine.totals().requests, 5)
    }
}
