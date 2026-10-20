import Foundation
import UsageCore

// Command line front end for the Claude usage monitor. It uses exactly the same core as the menu
// bar app, which makes it suitable for headless imports, verification and performance measurement.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: ccu <command> [options]

    commands:
      import      Import Claude Code and Codex history (incrementally; safe to repeat)
      totals      Print token totals
      verify      Recount tokens from the original files and compare with the database (--provider claude|openai)
      cost-check  Compare estimated API-equivalent cost with the cost Claude Code recorded
      sessions    List the most recent sessions
      quota       Show quota windows and how quota data is arriving
      export      Export data: --kind sessions|requests|projects|models|daily|weekly|quotaHistory --format csv|json --out PATH
      bench       Import into a fresh database and report time and memory
      statusline-check  Rehearse installing the status line helper on a copy of Claude Code's settings (changes nothing)

    options:
      --db PATH         database file (default: the app's database)
      --root PATH       Claude Code projects folder (default: ~/.claude/projects)
      --codex-home PATH Codex data folder (default: $CODEX_HOME or ~/.codex)
      --provider NAME   limit import and verify to claude or openai

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
let codexHome = option("--codex-home").map { URL(fileURLWithPath: $0) } ?? CodexAdapter.defaultHome
let providerFilter = option("--provider")

/// The adapters selected by `--provider`, or all of them.
func selectedAdapters() -> [any SourceAdapter] {
    var out: [any SourceAdapter] = []
    if providerFilter == nil || providerFilter == "claude" { out.append(ClaudeCodeAdapter(root: rootURL)) }
    if providerFilter == nil || providerFilter == "openai" { out.append(CodexAdapter(home: codexHome)) }
    return out
}

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
    let sync = FileSynchronizer(db: db)
    for adapter in selectedAdapters() {
        let start = Date()
        let files = try adapter.discoverFiles()
        var bytes: Int64 = 0, lines = 0, malformed = 0, changed = 0, failed = 0
        for f in files {
            do {
                let r = try sync.sync(file: f, adapter: adapter)
                bytes += r.bytesRead; lines += r.lines; malformed += r.malformedLines
                if r.bytesRead > 0 { changed += 1 }
            } catch {
                failed += 1
                FileHandle.standardError.write(Data("warning: \(f.path): \(error)\n".utf8))
            }
        }
        let dt = Date().timeIntervalSince(start)
        print("\(adapter.sourceID.rawValue): files=\(files.count) changed=\(changed) failed=\(failed) bytes_read=\(formatted(bytes)) lines=\(formatted(Int64(lines))) malformed=\(malformed) seconds=\(String(format: "%.2f", dt)) peak_rss_mb=\(String(format: "%.1f", peakMemoryMB()))")
    }
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
        var consistent = true
        func formattedLine(_ name: String, _ s: Int64, _ d: Int64) {
            print("\(name.padding(toLength: 16, withPad: " ", startingAt: 0)) source=\(formatted(s).padding(toLength: 18, withPad: " ", startingAt: 0)) database=\(formatted(d).padding(toLength: 18, withPad: " ", startingAt: 0)) \(s == d ? "OK" : "MISMATCH")")
        }
        if providerFilter == nil || providerFilter == "claude" {
            print("== Anthropic (Claude Code)")
            let report = try SourceVerifier(db: db, adapter: ClaudeCodeAdapter(root: rootURL)).verify()
            print("files_checked=\(report.filesChecked) sessions_checked=\(report.sessionsChecked)")
            print("requests: source=\(formatted(Int64(report.requestsInSource))) database=\(formatted(Int64(report.requestsInDatabase)))")
            formattedLine("uncached_input", report.sourceTotals.uncachedInput, report.databaseTotals.uncachedInput)
            formattedLine("output", report.sourceTotals.output, report.databaseTotals.output)
            formattedLine("cache_read", report.sourceTotals.cacheRead, report.databaseTotals.cacheRead)
            formattedLine("cache_creation", report.sourceTotals.cacheCreation, report.databaseTotals.cacheCreation)
            print("naive sum of every line (the wrong way): output=\(formatted(report.naiveSumOfAllLines.output)) cache_read=\(formatted(report.naiveSumOfAllLines.cacheRead))")
            for m in report.mismatches.prefix(10) { print("mismatch \(m.sessionID) \(m.field): database=\(m.database) source=\(m.source)") }
            print(report.isConsistent ? "RESULT: consistent" : "RESULT: INCONSISTENT (\(report.mismatches.count) mismatches)")
            consistent = consistent && report.isConsistent
        }
        if providerFilter == nil || providerFilter == "openai" {
            print("== OpenAI (Codex, Codex Desktop, ChatGPT Work)")
            let stateURL = option("--codex-state").map { URL(fileURLWithPath: $0) }
                ?? (FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("state_5.sqlite").path) ? codexHome.appendingPathComponent("state_5.sqlite") : nil)
            let report = try CodexVerifier(db: db, adapter: CodexAdapter(home: codexHome)).verify(stateDatabase: stateURL)
            print("files_checked=\(report.filesChecked) sessions_checked=\(report.sessionsChecked) (by usage record: \(report.recordSessions), by event: \(report.eventSessions), forks: \(report.forkSessions))")
            formattedLine("input (+cached)", report.expected.input, report.database.input)
            formattedLine("cached", report.expected.cached, report.database.cached)
            formattedLine("output", report.expected.output, report.database.output)
            formattedLine("reasoning", report.expected.reasoning, report.database.reasoning)
            print("responses: recount=\(formatted(Int64(report.expected.responses))) database=\(formatted(Int64(report.database.responses))) (a response without an event of its own is stored as one request and counted by the recount only as growth)")
            for m in report.mismatches.prefix(10) {
                print("mismatch \(m.sessionID.prefix(8)) \(m.mode): expected input=\(m.expected.input) output=\(m.expected.output), database input=\(m.database.input) output=\(m.database.output)")
            }
            print("thread counters versus sum of usage records: \(report.counterDisagreements.isEmpty ? "all agree" : "\(report.counterDisagreements.count) disagree: " + report.counterDisagreements.prefix(5).map { String($0.prefix(8)) }.joined(separator: ", "))")
            if let st = report.state {
                print("Codex's own per-thread count (state_5.sqlite): threads=\(st.threads) equal=\(st.equal) database_higher=\(st.databaseHigher) (surplus \(formatted(st.surplusTokens)) tokens) database_lower=\(st.databaseLower)")
                for e in st.examples { print("  \(e)") }
            }
            print(report.isConsistent ? "RESULT: consistent" : "RESULT: INCONSISTENT (\(report.mismatches.count) mismatches)")
            consistent = consistent && report.isConsistent
        }
        exit(consistent ? 0 : 1)

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
            print("\(r.shortID)  \(r.projectName.padding(toLength: 24, withPad: " ", startingAt: 0)) \(r.status.label.padding(toLength: 20, withPad: " ", startingAt: 0)) \(r.productID.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \((r.surface?.rawValue ?? "-").padding(toLength: 14, withPad: " ", startingAt: 0)) requests=\(r.requests) tokens=\(formatted(r.tokens.totalProcessed)) agents=\(r.agentCount) models=\(r.models.joined(separator: ","))")
        }

    case "quota":
        let db = try UsageDatabase.open(at: dbURL)
        let coordinator = QuotaCoordinator(db: db, settings: SettingsStore(db: db), feeds: .claude())
        await coordinator.refresh(force: true)
        for pool in await coordinator.pools() {
            print("\(pool.pool.name) [\(pool.pool.accountLabel)\(pool.pool.planType.map { ", plan \($0)" } ?? "")]")
            for s in pool.windows {
                switch s.availability {
                case .available:
                    let r = s.reading!
                    print("  \(s.displayName): \(String(format: "%.1f", r.utilizationPercent))% consumed, \(String(format: "%.1f", 100 - r.utilizationPercent))% remaining, resets \(r.resetsAt.map { "\($0)" } ?? "unknown"), \(s.freshness?.rawValue ?? "?"), source \(r.source)")
                case .windowElapsed(let at):
                    print("  \(s.displayName): window reset at \(at); new utilization unknown until a source reports it")
                case .unavailable:
                    print("  \(s.displayName): Unavailable (no source has reported this window)")
                }
            }
        }
        for feed in await coordinator.feedStatus() {
            print("feed \(feed.id.rawValue): folder exists=\(feed.rootsExist) observations=\(feed.observationCount) sources=\(feed.originCount)")
        }
        print("status line helper installed in Claude Code settings: \(StatusLineInstaller.inspect().isInstalled)")

    case "statusline-check":
        // Rehearses the whole path of the Claude quota integration without touching the real settings or sending a
        // request: the settings are only read, the install is done on a copy, and the helper is fed a made-up payload.
        let fm = FileManager.default
        let settings = QuotaPaths.claudeSettings
        let before = StatusLineInstaller.inspect(settingsURL: settings)
        print("settings file: \(settings.path) exists=\(before.settingsExists) valid_json=\(before.settingsIsValidJSON)")
        print("status line configured today: \(before.command != nil ? "yes" : "no") helper_installed=\(before.isInstalled) non_command_status_line=\(before.usesNonCommandStatusLine)")
        guard let helper = option("--bridge").map({ URL(fileURLWithPath: $0) }) ?? StatusLineInstaller.locateBridge() else {
            print("helper binary: NOT FOUND (pass --bridge PATH)"); exit(1)
        }
        print("helper binary: \(helper.path)")
        let scratch = fm.temporaryDirectory.appendingPathComponent("ccu-statusline-check-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("settings.json")
        if before.settingsExists { try fm.copyItem(at: settings, to: copy) }
        let originalBytes = fm.contents(atPath: copy.path)
        _ = try StatusLineInstaller.install(settingsURL: copy, bridge: helper)
        let after = StatusLineInstaller.inspect(settingsURL: copy)
        print("on the copy: helper_installed=\(after.isInstalled) chains_existing_command=\(after.chainedCommand != nil)")
        print("on the copy: statusLine command would be: \(after.command ?? "-")")
        if let originalBytes, let edited = fm.contents(atPath: copy.path) {
            let a = String(decoding: originalBytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let b = String(decoding: edited, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let changedLines = Set(b).subtracting(Set(a)).count + Set(a).subtracting(Set(b)).count
            print("on the copy: lines that differ from the original: \(changedLines) (the rest of the file is byte for byte the same)")
            try StatusLineInstaller.uninstall(settingsURL: copy)
            let restored = fm.contents(atPath: copy.path) == originalBytes
            print("on the copy: uninstall restores the original file exactly: \(restored)")
        }
        // Run the exact command that would be installed, with a made-up Claude Code payload.
        let quotaDir = scratch.appendingPathComponent("quota")
        let payload = #"{"session_id":"check-1","cost":{"total_api_duration_ms":1000,"total_cost_usd":0.1},"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":\#(Int(Date().timeIntervalSince1970) + 7200)},"seven_day":{"used_percentage":40,"resets_at":\#(Int(Date().timeIntervalSince1970) + 86400 * 3)}}}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", after.command ?? ShellQuote.quote(helper.path)]
        process.environment = ["CLAUDE_USAGE_MONITOR_QUOTA_DIR": quotaDir.path, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        print("helper run: exit=\(process.terminationStatus) printed: \(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))")
        let readings = StatusLineQuotaSource.observations(in: quotaDir)
        for r in readings.sorted(by: { $0.windowKey < $1.windowKey }) {
            print("parsed \(r.windowKey): \(r.utilizationPercent)% resets \(r.resetsAt.map { "\($0)" } ?? "?") observed \(r.observedAt) authority=\(r.authority.rawValue)")
        }
        print(readings.count == 2 ? "RESULT: the path works with the documented payload; a real subscription event has still to be observed" : "RESULT: PROBLEM (expected two windows)")
        exit(readings.count == 2 ? 0 : 1)

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
