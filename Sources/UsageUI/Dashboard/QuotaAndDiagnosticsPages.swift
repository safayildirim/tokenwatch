import SwiftUI
import Charts
import AppKit
import UsageCore

struct QuotaPage: View {
    @Environment(AppModel.self) private var model
    @State private var history: [HistorySeries] = []
    @State private var days = 7

    struct HistorySeries: Identifiable {
        var id: String
        var name: String
        var readings: [QuotaReading]
    }

    var body: some View {
        PageScroll {
            let pools = model.scopedPools
            ForEach(model.providers, id: \.id) { provider in
                let own = pools.filter { $0.pool.key.provider == provider.id }
                // A provider with nothing to show and nothing found on this Mac is explained once, further down.
                if !own.isEmpty && (own.contains { $0.windows.contains { $0.reading != nil } } || model.collectionState(of: provider.id) != .notFound) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(provider.name, systemImage: provider.symbol).font(.title3.weight(.semibold))
                        ForEach(own) { pool in
                            Card { QuotaPoolCard(pool: pool, onSetup: { model.selection = .quota }) }
                        }
                    }
                }
            }
            if model.providers.contains(where: { $0.id == .anthropic }), scopeIncludesAnthropic { QuotaSetupCard() }
            unobservableCard
            historyCard
            Card("What these numbers mean") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Percentages and reset times come only from the provider's own software. They are never calculated from token counts, because a subscription meter depends on more than raw tokens.")
                    bullet("Each percentage belongs to one pool of one account. Pools are listed separately and are never added together, and two accounts of the same provider never share a figure.")
                    bullet("Products that share an allowance share a pool. A figure reported by one of them is the state of the pool for all of them.")
                    bullet("A figure is a snapshot taken when the provider last reported it. It is marked stale when it is old, and after a reset it is shown as unknown rather than zero.")
                    bullet("Usage from apps and devices that leave no record on this Mac still counts toward the real figure. Local sessions can explain only part of it.")
                }.font(.callout)
            }
        }
        .task(id: "\(days)|\(model.dataVersion)|\(model.scopeVersion)") { await loadHistory() }
    }

    private var scopeIncludesAnthropic: Bool { model.scope.providers.isEmpty || model.scope.providers.contains(.anthropic) }

    /// Allowances and products that exist but cannot be seen from this Mac.
    private var unobservableCard: some View {
        let registry = model.db.registry
        let hidden = registry.products.filter { !$0.isObservable && (model.scope.providers.isEmpty || model.scope.providers.contains($0.provider)) }
        return Group {
            if !hidden.isEmpty {
                Card("Not observable on this Mac", subtitle: "These count toward real limits but leave no record here, so no figure is shown for them and none is guessed.") {
                    ForEach(hidden, id: \.id) { product in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label(product.name, systemImage: "eye.slash").font(.callout.weight(.medium))
                                ProviderChip(provider: product.provider)
                            }
                            Text(product.observability).font(.caption).foregroundStyle(.secondary)
                            if let pool = registry.pools(of: product.id).first, pool.products.count > 1 || !pool.isObservable {
                                Text(pool.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var historyCard: some View {
        Card("Utilization history", subtitle: "Account-level percentages as reported by each provider, from the moments this Mac observed them.") {
            Picker("Period", selection: $days) {
                Text("24 hours").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
            }.pickerStyle(.segmented).frame(width: 260).labelsHidden()
            if history.allSatisfy({ $0.readings.isEmpty }) {
                Text("No history yet. Points are recorded whenever a provider reports a new value.").font(.callout).foregroundStyle(.secondary)
            } else {
                let colors = Dictionary(uniqueKeysWithValues: history.enumerated().map { ($0.element.name, Palette.series[$0.offset % Palette.series.count]) })
                HStack(spacing: 14) {
                    ForEach(history.filter { !$0.readings.isEmpty }) { LegendDot(color: colors[$0.name] ?? Palette.other, label: $0.name) }
                }
                Chart {
                    ForEach(history) { series in
                        ForEach(series.readings, id: \.observedAt) { r in
                            LineMark(x: .value("Time", r.observedAt), y: .value("Used", r.utilizationPercent), series: .value("Window", series.name))
                                .foregroundStyle(by: .value("Window", series.name))
                                .interpolationMethod(.stepEnd)
                        }
                    }
                }
                .chartForegroundStyleScale(domain: history.map(\.name), range: history.map { colors[$0.name] ?? Palette.other })
                .chartLegend(.hidden)
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine().foregroundStyle(Palette.gridLine)
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%") } }
                } }
                .frame(height: 220)
            }
        }
    }

    private func loadHistory() async {
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        var out: [HistorySeries] = []
        for pool in model.scopedPools {
            for w in pool.windows where w.reading != nil {
                let readings = await model.quota.history(pool: pool.pool.key, windowKey: w.windowKey, since: since).filter { $0.authority == .authoritative }
                let account = pool.pool.accountLabel == "Unassigned" ? "" : " (\(pool.pool.accountLabel))"
                out.append(HistorySeries(id: "\(pool.id)/\(w.windowKey)", name: "\(pool.pool.name)\(account), \(w.displayName.lowercased())", readings: readings))
            }
        }
        history = out
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
        Card("Claude quota tracking", subtitle: "Claude subscription usage is only available through Claude Code's documented status line feature. Codex needs no setup, because it records its own quota snapshots.") {
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
                let feed = model.quotaFeeds.first { $0.id == .claudeStatusLine }
                Text((feed?.originCount ?? 0) > 0
                     ? "Receiving data from \(feed!.originCount) Claude Code session\(feed!.originCount == 1 ? "" : "s"); newest report \(Fmt.relative(feed?.newestObservation))."
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

    struct DBCounts: Sendable { var requests: Int64; var sessions: Int64; var files: Int64; var malformed: Int64; var issues: [IssueRow]; var notices: [IssueRow]; var sizeMB: Double }
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

            if let c = counts, !c.notices.isEmpty {
                Card("Accounting notes", subtitle: "Places where the files could not settle exactly what was used. The figures are still counted, as described.") {
                    ForEach(c.notices) { i in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.message).font(.caption)
                            if let p = i.path { Text((p as NSString).lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        }
                    }
                }
            }

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
        let enabled = model.collectorSnapshot.sources.filter { $0.state != .notFound }.map(\.sourceID)
        Task.detached {
            var lines: [String] = []
            if enabled.contains(.claudeTranscripts) {
                do {
                    let r = try SourceVerifier(db: db).verify()
                    lines.append(r.isConsistent
                        ? "Claude Code: \(r.sessionsChecked) sessions and \(Fmt.grouped(Int64(r.requestsInSource))) requests recounted independently match the database exactly. (Adding up every log line instead would have overstated cache reads by \(String(format: "%.1f", Double(r.naiveSumOfAllLines.cacheRead) / Double(max(1, r.sourceTotals.cacheRead))))×.)"
                        : "Claude Code: mismatch in \(r.mismatches.count) places. Use \"Rebuild from source\" to repair, and please report it.")
                } catch { lines.append("Claude Code: verification failed: \(error)") }
            }
            if enabled.contains(.codexRollouts) {
                do {
                    let r = try CodexVerifier(db: db).verify()
                    lines.append(r.isConsistent
                        ? "Codex: \(r.sessionsChecked) sessions (\(r.recordSessions) by usage record, \(r.eventSessions) by event, \(r.forkSessions) fork) recounted independently match the database exactly."
                        : "Codex: mismatch in \(r.mismatches.count) sessions. Use \"Rebuild from source\" to repair, and please report it.")
                } catch { lines.append("Codex: verification failed: \(error)") }
            }
            let text = lines.isEmpty ? "No source with data to verify." : lines.joined(separator: "\n")
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
                         issues: try c.query("SELECT id, at, path, message FROM ingest_issue WHERE severity != 'notice' ORDER BY id DESC LIMIT 8") {
                             IssueRow(id: $0.int(0), at: Clock.date(ms: $0.int(1)), path: $0.textOrNil(2), message: $0.text(3))
                         },
                         notices: try c.query("SELECT id, at, path, message FROM ingest_issue WHERE severity = 'notice' ORDER BY id DESC LIMIT 20") {
                             IssueRow(id: $0.int(0), at: Clock.date(ms: $0.int(1)), path: $0.textOrNil(2), message: $0.text(3))
                         },
                         sizeMB: Double(db.diskUsageBytes()) / 1_048_576)
            }
        }.value
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
