import SwiftUI
import Charts
import AppKit
import UsageCore

struct QuotaPage: View {
    @Environment(AppModel.self) private var model
    @State private var history: [QuotaKind: [QuotaReading]] = [:]
    @State private var days = 7

    typealias QuotaKind = QuotaWindowKind

    var body: some View {
        PageScroll {
            ForEach(model.quotaStates.filter { $0.kind != .spendLimit || $0.reading != nil }) { s in
                Card { QuotaMeter(state: s, onSetup: nil) }
            }
            QuotaSetupCard()
            Card("Utilization history", subtitle: "Account-level percentages as reported by Claude Code, from the moments this Mac observed them.") {
                Picker("Period", selection: $days) {
                    Text("24 hours").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                }.pickerStyle(.segmented).frame(width: 260).labelsHidden()
                let all = history.values.flatMap { $0 }
                if all.isEmpty {
                    Text("No history yet. Points are recorded whenever Claude Code reports a new value.").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 14) {
                        LegendDot(color: Palette.series[0], label: "Five-hour window"); LegendDot(color: Palette.series[1], label: "Weekly window")
                    }
                    Chart(all, id: \.observedAt) { r in
                        LineMark(x: .value("Time", r.observedAt), y: .value("Used", r.utilizationPercent), series: .value("Window", r.kind.displayName))
                            .foregroundStyle(by: .value("Window", r.kind.displayName))
                            .interpolationMethod(.stepEnd)
                    }
                    .chartForegroundStyleScale(["Five-hour window": Palette.series[0], "Weekly window": Palette.series[1], "Spend limit": Palette.series[2]])
                    .chartLegend(.hidden)
                    .chartYScale(domain: 0...100)
                    .chartYAxis { AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine().foregroundStyle(Palette.gridLine)
                        AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%") } }
                    } }
                    .frame(height: 220)
                }
            }
            Card("What these numbers mean") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Percentages and reset times come only from Claude itself. They are never calculated from token counts, because the subscription meter depends on more than raw tokens.")
                    bullet("Claude Code reports them to its status line. The helper installed above copies just that figure to a local file.")
                    bullet("The figure covers your whole account, including claude.ai chat, Cowork and other devices. Local sessions can explain only part of it.")
                    bullet("The value updates while a Claude Code terminal session is in use. Between sessions it is marked stale, and after a reset it is shown as unknown rather than zero.")
                }.font(.callout)
            }
        }
        .task(id: "\(days)|\(model.dataVersion)") {
            var out: [QuotaKind: [QuotaReading]] = [:]
            for kind in [QuotaWindowKind.fiveHour, .sevenDay] {
                out[kind] = await model.quota.history(kind: kind, since: Date().addingTimeInterval(-Double(days) * 86_400))
            }
            history = out
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) { Text("•"); Text(text).fixedSize(horizontal: false, vertical: true) }
    }
}

/// Shows whether the status line helper is installed, and installs or removes it on request.
struct QuotaSetupCard: View {
    @Environment(AppModel.self) private var model
    @State private var inspection = StatusLineInstaller.inspect()
    @State private var message: String?
    @State private var confirming = false

    var body: some View {
        Card("Quota tracking", subtitle: "Subscription usage is only available through Claude Code's documented status line feature.") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: inspection.isInstalled ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(inspection.isInstalled ? Palette.good : Palette.warning)
                    Text(inspection.isInstalled ? "Status line helper is installed in Claude Code's settings." : "Status line helper is not installed.")
                        .font(.callout.weight(.medium))
                }
                if inspection.isInstalled, let chained = inspection.chainedCommand {
                    Text("Your own status line is kept and still runs: \(chained)").font(.caption).foregroundStyle(.secondary)
                }
                if !inspection.isInstalled && inspection.command != nil {
                    Text("You already have a status line command. It will keep working: the helper runs it and shows its output.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if inspection.usesNonCommandStatusLine {
                    Text("Your settings define a status line that is not a command, so it was left alone. Set it up manually (see the README).")
                        .font(.caption).foregroundStyle(Palette.warning)
                }
                if !inspection.settingsIsValidJSON {
                    Text("~/.claude/settings.json is not valid JSON, so it will not be modified.").font(.caption).foregroundStyle(Palette.critical)
                }
                let status = model.quotaSource
                Text(status.bridgeFileCount > 0
                     ? "Receiving data from \(status.bridgeFileCount) Claude Code session\(status.bridgeFileCount == 1 ? "" : "s"); newest report \(Fmt.relative(status.newestBridgeObservation))."
                     : "No report received yet. Quota appears after you send a message in a new Claude Code terminal session.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if inspection.isInstalled {
                        Button("Remove helper") { run { try StatusLineInstaller.uninstall() } }
                    } else {
                        Button("Install helper…") { confirming = true }
                            .disabled(StatusLineInstaller.locateBridge() == nil || !inspection.settingsIsValidJSON || inspection.usesNonCommandStatusLine)
                    }
                    Button("Reveal settings.json") { NSWorkspace.shared.activateFileViewerSelecting([QuotaPaths.claudeSettings]) }
                    Button("Check again") { inspection = StatusLineInstaller.inspect(); Task { await model.quota.refresh(force: true) } }
                }
                if StatusLineInstaller.locateBridge() == nil {
                    Text("The helper binary was not found next to this app, so it cannot be installed from here.").font(.caption).foregroundStyle(Palette.warning)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .confirmationDialog("Add the status line helper to Claude Code?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Install") { run { try StatusLineInstaller.install() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This adds a statusLine entry to ~/.claude/settings.json. A backup of the file is saved next to it first, any existing status line keeps working, and nothing else in the file is changed. Takes effect in new Claude Code sessions.")
        }
    }

    private func run(_ action: () throws -> Any?) {
        do {
            let result = try action()
            if let url = result as? URL { message = "Done. A backup was saved to \(url.lastPathComponent)." } else { message = "Done." }
        } catch { message = "\(error)" }
        inspection = StatusLineInstaller.inspect()
        model.requestRefresh()
    }
}

struct DiagnosticsPage: View {
    @Environment(AppModel.self) private var model
    @State private var integrity: String?
    @State private var verification: String?
    @State private var running = false
    @State private var stats = ProcessStats.sample()
    @State private var counts: DBCounts?

    struct DBCounts: Sendable { var requests: Int64; var sessions: Int64; var files: Int64; var malformed: Int64; var issues: [IssueRow]; var sizeMB: Double }
    struct IssueRow: Identifiable, Sendable { var id: Int64; var at: Date; var path: String?; var message: String }

    var body: some View {
        PageScroll {
            Card("Collection", subtitle: "Each usage source is collected independently. A problem with one never stops another.") {
                let snap = model.collectorSnapshot
                ForEach(snap.sources) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: s.state == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(s.state == .ok ? Palette.good : (s.state == .failing ? Palette.critical : Palette.warning))
                            Text(s.displayName).font(.callout.weight(.medium))
                            Spacer()
                            Text(stateText(s)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(s.coverageNote).font(.caption).foregroundStyle(.secondary)
                        if let e = s.lastError { Text(e).font(.caption).foregroundStyle(Palette.warning) }
                        Text("\(s.filesKnown) files · last success \(Fmt.relative(s.lastSuccessAt))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 3) {
                    GridRow { Text("Last reconciliation").foregroundStyle(.secondary); Text(Fmt.relative(snap.lastReconcileAt)) }
                    GridRow { Text("Latest ingestion latency").foregroundStyle(.secondary); Text(snap.lastLatencyMs.map { "\($0) ms" } ?? "—") }
                    GridRow { Text("Requests processed this run").foregroundStyle(.secondary); Text(Fmt.grouped(Int64(snap.requestsTouchedThisRun))) }
                    GridRow { Text("Running since").foregroundStyle(.secondary); Text(Fmt.dateTime(snap.startedAt)) }
                }.font(.callout)
            }

            Card("Database") {
                if let c = counts {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 3) {
                        GridRow { Text("Location").foregroundStyle(.secondary); Text(QuotaPaths.databaseURL.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                        GridRow { Text("Size").foregroundStyle(.secondary); Text(String(format: "%.1f MB", c.sizeMB)) }
                        GridRow { Text("Requests stored").foregroundStyle(.secondary); Text(Fmt.grouped(c.requests)) }
                        GridRow { Text("Sessions").foregroundStyle(.secondary); Text(Fmt.grouped(c.sessions)) }
                        GridRow { Text("Log files tracked").foregroundStyle(.secondary); Text(Fmt.grouped(c.files)) }
                        GridRow { Text("Malformed log lines skipped").foregroundStyle(.secondary); Text(Fmt.grouped(c.malformed)) }
                        if model.openReport.recoveredFromCorruption {
                            GridRow { Text("Recovery").foregroundStyle(.secondary); Text("A damaged database was replaced and history re-imported.").foregroundStyle(Palette.warning) }
                        }
                    }.font(.callout)
                }
                HStack {
                    Button("Check integrity") { run { integrity = (try? model.db.integrityCheck().joined(separator: ", ")) ?? "failed" } }
                    Button("Verify against source files") { verify() }
                    Button("Rebuild from source…") { model.rebuildFromSource() }
                        .help("Deletes usage records and imports them again from the original files.")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([QuotaPaths.databaseURL]) }
                    if running { ProgressView().controlSize(.small) }
                }
                if let integrity { Text("Integrity check: \(integrity)").font(.caption).foregroundStyle(.secondary) }
                if let verification { Text(verification).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }

            Card("This app's resource use", subtitle: "The monitor should stay unnoticeable.") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 3) {
                    GridRow { Text("Memory (resident)").foregroundStyle(.secondary); Text(String(format: "%.0f MB", stats.residentMB)) }
                    GridRow { Text("CPU time used").foregroundStyle(.secondary); Text(String(format: "%.1f s since launch", stats.cpuSeconds)) }
                    GridRow { Text("Threads").foregroundStyle(.secondary); Text("\(stats.threads)") }
                }.font(.callout)
            }

            Card("What can and cannot be observed") { CapabilityMatrix() }

            if let c = counts, !c.issues.isEmpty {
                Card("Recent problems") {
                    ForEach(c.issues) { i in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Fmt.dateTime(i.at)) · \(i.message)").font(.caption)
                            if let p = i.path { Text(p).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        }
                    }
                }
            }
        }
        .task(id: model.dataVersion) { await load() }
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(5)); stats = ProcessStats.sample() } }
    }

    private func stateText(_ s: SourceHealth) -> String {
        switch s.state {
        case .ok: "Healthy"
        case .notFound: "Not found"
        case .degraded: "Some files failing"
        case .failing: "Failing"
        }
    }

    private func run(_ work: @escaping @Sendable () -> Void) {
        running = true
        Task.detached { work(); await MainActor.run { running = false } }
    }

    private func verify() {
        running = true
        verification = "Recounting every token from the original files…"
        let db = model.db
        Task.detached {
            let text: String
            do {
                let r = try SourceVerifier(db: db).verify()
                text = r.isConsistent
                    ? "Verified: \(r.sessionsChecked) sessions and \(Fmt.grouped(Int64(r.requestsInSource))) requests recounted independently from the source files match the database exactly. (Adding up every log line instead would have overstated cache reads by \(String(format: "%.1f", Double(r.naiveSumOfAllLines.cacheRead) / Double(max(1, r.sourceTotals.cacheRead))))×.)"
                    : "Mismatch in \(r.mismatches.count) places. Use \"Rebuild from source\" to repair, and please report it."
            } catch { text = "Verification failed: \(error)" }
            await MainActor.run { verification = text; running = false }
        }
    }

    private func load() async {
        let db = model.db
        counts = try? await Task.detached {
            try db.read { c in
                DBCounts(requests: try c.scalarInt("SELECT count(*) FROM model_request") ?? 0,
                         sessions: try c.scalarInt("SELECT count(*) FROM session") ?? 0,
                         files: try c.scalarInt("SELECT count(*) FROM source_file") ?? 0,
                         malformed: try c.scalarInt("SELECT COALESCE(sum(malformed_lines),0) FROM source_file") ?? 0,
                         issues: try c.query("SELECT id, at, path, message FROM ingest_issue ORDER BY id DESC LIMIT 8") {
                             IssueRow(id: $0.int(0), at: Clock.date(ms: $0.int(1)), path: $0.textOrNil(2), message: $0.text(3))
                         },
                         sizeMB: Double(db.diskUsageBytes()) / 1_048_576)
            }
        }.value
    }
}

/// The documented capability matrix: what each Claude surface exposes locally.
struct CapabilityMatrix: View {
    private struct Row: Identifiable { var id: String { source }; var source, tokens, sessions, quota, note: String }
    private let rows = [
        Row(source: "Claude Code: terminal, VS Code, Desktop Code", tokens: "Full (per request, with cache split)", sessions: "Full", quota: "Via status line helper (terminal only)", note: "Transcripts under ~/.claude/projects, plus the live process registry."),
        Row(source: "Claude Code OpenTelemetry", tokens: "Full, but needs a collector", sessions: "Full", quota: "No", note: "Identity-compatible with the transcripts; not enabled, to avoid extra processes."),
        Row(source: "Claude Desktop: Chat and Cowork", tokens: "Not exposed", sessions: "Not exposed", quota: "No documented interface", note: "Counted in the account quota but invisible locally."),
        Row(source: "claude.ai in a browser, other devices", tokens: "Not exposed", sessions: "Not exposed", quota: "Counted in the account quota", note: "Cannot be attributed to local sessions."),
        Row(source: "Anthropic API usage reports", tokens: "API keys only", sessions: "No", quota: "No (not subscriptions)", note: "Does not describe subscription usage."),
    ]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow { Text("Source").bold(); Text("Tokens").bold(); Text("Sessions").bold(); Text("Quota %").bold() }.font(.caption)
            Divider()
            ForEach(rows) { r in
                GridRow(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) { Text(r.source).font(.caption.weight(.medium)); Text(r.note).font(.caption2).foregroundStyle(.secondary) }
                    Text(r.tokens).font(.caption); Text(r.sessions).font(.caption); Text(r.quota).font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProcessStats {
    var residentMB: Double
    var cpuSeconds: Double
    var threads: Int

    static func sample() -> ProcessStats {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        task_threads(mach_task_self_, &threadList, &threadCount)
        if let list = threadList { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size)) }
        return ProcessStats(residentMB: kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0, cpuSeconds: cpu, threads: Int(threadCount))
    }
}
