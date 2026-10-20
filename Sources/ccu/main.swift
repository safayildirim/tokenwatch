import Foundation
import UsageCore

// Command line front end for the Claude usage monitor. It uses exactly the same core as the menu
// bar app, which makes it suitable for headless imports, verification and performance measurement.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: ccu <command> [options]

    commands:
      import      Import Claude Code history (incrementally; safe to repeat)
      totals      Print token totals
      verify      Recount tokens from the original files and compare with the database
      cost-check  Compare estimated API-equivalent cost with the cost Claude Code recorded
      sessions    List the most recent sessions
      quota       Show quota windows and how quota data is arriving
      export      Export data: --kind sessions|requests|projects|models|daily|weekly|quotaHistory --format csv|json --out PATH
      bench       Import into a fresh database and report time and memory

    options:
      --db PATH     database file (default: the app's database)
      --root PATH   Claude Code projects folder (default: ~/.claude/projects)

    """.utf8))
    exit(2)
}

let allArgs = Array(CommandLine.arguments.dropFirst())
guard let command = allArgs.first else { usage() }
let args = Array(allArgs.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let dbURL = option("--db").map { URL(fileURLWithPath: $0) } ?? QuotaPaths.databaseURL
let rootURL = option("--root").map { URL(fileURLWithPath: $0) } ?? ClaudeCodeAdapter.defaultRoot

func formatted(_ n: Int64) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? String(n)
}

func peakMemoryMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

func runImport(db: UsageDatabase) throws {
    let adapter = ClaudeCodeAdapter(root: rootURL)
    let sync = FileSynchronizer(db: db)
    let start = Date()
    let files = try adapter.discoverFiles()
    var bytes: Int64 = 0, lines = 0, malformed = 0, changed = 0
    for f in files {
        let r = try sync.sync(file: f, adapter: adapter)
        bytes += r.bytesRead; lines += r.lines; malformed += r.malformedLines
        if r.bytesRead > 0 { changed += 1 }
    }
    let dt = Date().timeIntervalSince(start)
    print("files=\(files.count) changed=\(changed) bytes_read=\(formatted(bytes)) lines=\(formatted(Int64(lines))) malformed=\(malformed) seconds=\(String(format: "%.2f", dt)) peak_rss_mb=\(String(format: "%.1f", peakMemoryMB()))")
}

func printTotals(db: UsageDatabase) throws {
    let t = try AnalyticsEngine(db: db).totals()
    print("requests=\(formatted(Int64(t.requests))) sessions=\(t.sessions)")
    print("uncached_input=\(formatted(t.tokens.uncachedInput)) output=\(formatted(t.tokens.output)) cache_read=\(formatted(t.tokens.cacheRead)) cache_creation=\(formatted(t.tokens.cacheCreation))")
    print("logical_input=\(formatted(t.tokens.logicalInput)) total_processed=\(formatted(t.tokens.totalProcessed)) fresh=\(formatted(t.tokens.freshTokens))")
    if let r = t.tokens.cacheHitRatio { print(String(format: "cache_hit_ratio=%.4f", r)) }
    print("estimated_api_cost_usd=\(String(format: "%.2f", t.cost.usdDouble))\(t.cost.isPartial ? " (partial: \(formatted(t.cost.unpricedTokens)) unpriced tokens)" : "")")
}

do {
    switch command {
    case "import":
        let db = try UsageDatabase.open(at: dbURL)
        try runImport(db: db)
        try printTotals(db: db)
        db.markCleanShutdown()

    case "totals":
        let db = try UsageDatabase.open(at: dbURL)
        try printTotals(db: db)

    case "bench":
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ccu-bench-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path.path + s) } }
        let db = try UsageDatabase.open(at: path)
        print("-- initial import")
        try runImport(db: db)
        print("-- second pass (nothing changed)")
        try runImport(db: db)
        let engine = AnalyticsEngine(db: db)
        func time(_ label: String, _ body: () throws -> Void) rethrows {
            let t = Date()
            try body()
            print(String(format: "%-34@ %6.1f ms", label as NSString, Date().timeIntervalSince(t) * 1000))
        }
        print("-- query latency")
        try time("overview (4 totals + sessions)") { _ = try engine.overview() }
        try time("sessions table (all)") { _ = try engine.sessionRows() }
        try time("daily series by model") { _ = try engine.series(UsageFilter(), granularity: .day, dimension: .model) }
        try time("hourly series") { _ = try engine.series(UsageFilter(), granularity: .hour) }
        try time("models") { _ = try engine.models() }
        try time("projects") { _ = try engine.projects() }
        if let first = try engine.sessionRows().max(by: { $0.requests < $1.requests }) {
            try time("session detail (largest session)") { _ = try engine.sessionDetail(id: first.id) }
        }
        let size = db.diskUsageBytes()
        print("database_size_mb=\(String(format: "%.1f", Double(size) / 1_048_576))")

    case "verify":
        let db = try UsageDatabase.open(at: dbURL)
        try runImport(db: db)
        let report = try SourceVerifier(db: db, adapter: ClaudeCodeAdapter(root: rootURL)).verify()
        print("files_checked=\(report.filesChecked) sessions_checked=\(report.sessionsChecked)")
        print("requests: source=\(formatted(Int64(report.requestsInSource))) database=\(formatted(Int64(report.requestsInDatabase)))")
        func line(_ name: String, _ s: Int64, _ d: Int64) {
            print("\(name.padding(toLength: 16, withPad: " ", startingAt: 0)) source=\(formatted(s).padding(toLength: 18, withPad: " ", startingAt: 0)) database=\(formatted(d).padding(toLength: 18, withPad: " ", startingAt: 0)) \(s == d ? "OK" : "MISMATCH")")
        }
        line("uncached_input", report.sourceTotals.uncachedInput, report.databaseTotals.uncachedInput)
        line("output", report.sourceTotals.output, report.databaseTotals.output)
        line("cache_read", report.sourceTotals.cacheRead, report.databaseTotals.cacheRead)
        line("cache_creation", report.sourceTotals.cacheCreation, report.databaseTotals.cacheCreation)
        print("naive sum of every line (the wrong way): output=\(formatted(report.naiveSumOfAllLines.output)) cache_read=\(formatted(report.naiveSumOfAllLines.cacheRead))")
        for m in report.mismatches.prefix(10) { print("mismatch \(m.sessionID) \(m.field): database=\(m.database) source=\(m.source)") }
        print(report.isConsistent ? "RESULT: consistent" : "RESULT: INCONSISTENT (\(report.mismatches.count) mismatches)")
        exit(report.isConsistent ? 0 : 1)

    case "cost-check":
        let db = try UsageDatabase.open(at: dbURL)
        try runImport(db: db)
        // Compare the sessions for which Claude Code recorded its own cost with the estimate computed from list prices.
        let engine = AnalyticsEngine(db: db)
        let rows = try engine.sessionRows().filter { $0.reportedCostUSD != nil && $0.cost.picoUSD > 0 }
        var reported = 0.0, estimated = 0.0
        var worst: [(String, Double, Double)] = []
        for r in rows {
            let rep = r.reportedCostUSD!, est = r.cost.usdDouble
            reported += rep; estimated += est
            worst.append((r.shortID + " " + r.projectName, rep, est))
        }
        print("sessions compared: \(rows.count)")
        print(String(format: "Claude Code reported total: $%.2f", reported))
        print(String(format: "Estimated from list prices: $%.2f   (ratio %.3f)", estimated, estimated / max(reported, 0.0001)))
        let deviations = worst.map { abs($0.2 - $0.1) / max($0.1, 0.01) }.sorted()
        if !deviations.isEmpty {
            print(String(format: "per-session relative deviation: median %.1f%%, p90 %.1f%%", deviations[deviations.count / 2] * 100, deviations[Int(Double(deviations.count) * 0.9)] * 100))
        }
        for w in worst.sorted(by: { abs($0.2 - $0.1) > abs($1.2 - $1.1) }).prefix(5) {
            print(String(format: "  %@  reported $%.2f  estimated $%.2f", w.0, w.1, w.2))
        }
        print("Note: Claude Code's figure is its own estimate; neither is a subscription charge.")

    case "sessions":
        let db = try UsageDatabase.open(at: dbURL)
        let rows = try AnalyticsEngine(db: db).sessionRows().sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
        for r in rows.prefix(Int(option("--limit") ?? "15") ?? 15) {
            print("\(r.shortID)  \(r.projectName.padding(toLength: 24, withPad: " ", startingAt: 0)) \(r.status.label.padding(toLength: 20, withPad: " ", startingAt: 0)) \((r.application ?? "-").padding(toLength: 14, withPad: " ", startingAt: 0)) requests=\(r.requests) tokens=\(formatted(r.tokens.totalProcessed)) agents=\(r.agentCount) models=\(r.models.joined(separator: ","))")
        }

    case "quota":
        let db = try UsageDatabase.open(at: dbURL)
        let coordinator = QuotaCoordinator(db: db, settings: SettingsStore(db: db))
        await coordinator.refresh(force: true)
        for s in await coordinator.states() {
            switch s.availability {
            case .available:
                let r = s.reading!
                print("\(s.kind.displayName): \(String(format: "%.1f", r.utilizationPercent))% consumed, \(String(format: "%.1f", 100 - r.utilizationPercent))% remaining, resets \(r.resetsAt.map { "\($0)" } ?? "unknown"), \(s.freshness?.rawValue ?? "?"), source \(r.provider)")
            case .windowElapsed(let at):
                print("\(s.kind.displayName): window reset at \(at); new utilization unknown until a source reports it")
            case .unavailable:
                print("\(s.kind.displayName): Unavailable (no source has reported this window)")
            }
        }
        let status = await coordinator.sourceStatus()
        print("status line bridge installed in Claude Code settings: \(status.bridgeInstalledInClaudeSettings), session files: \(status.bridgeFileCount)")

    case "export":
        guard let kindName = option("--kind"), let kind = ExportKind(rawValue: kindName),
              let formatName = option("--format"), let format = ExportFormat(rawValue: formatName),
              let out = option("--out") else { usage() }
        let db = try UsageDatabase.open(at: dbURL)
        let result = try ExportService(db: db).export(kind: kind, format: format, to: URL(fileURLWithPath: out))
        print("wrote \(result.rows) rows to \(result.url.path)")

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
