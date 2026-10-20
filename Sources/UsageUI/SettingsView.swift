import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import UsageCore

public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            QuotaSettings().tabItem { Label("Quota", systemImage: "hourglass") }
            NotificationSettingsView().tabItem { Label("Notifications", systemImage: "bell") }
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }
            ExportSettings().tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            CostSettings().tabItem { Label("Cost", systemImage: "dollarsign.circle") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 520)
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .onAppear { DockPresence.windowAppeared() }
        .onDisappear { DockPresence.windowDisappeared() }
    }
}

public extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var m = model
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: { setLogin($0) }))
                Text(LoginItem.statusDescription).font(.caption).foregroundStyle(.secondary)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(Palette.critical) }
                Text("The app keeps collecting usage in the menu bar even when no window is open.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Picker("Show", selection: Binding(get: { model.settings.menuBarMode }, set: { v in model.updateSettings { $0.menuBarMode = v } })) {
                    ForEach(MenuBarDisplayMode.allCases) { Text($0.label).tag($0) }
                }
                Text("Percentages are real quota values reported by Claude. When none is available the menu bar shows only the icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { model.settings.appearance }, set: { v in model.updateSettings { $0.appearance = v } })) {
                    Text("Match system").tag(AppearanceMode.system); Text("Light").tag(AppearanceMode.light); Text("Dark").tag(AppearanceMode.dark)
                }.pickerStyle(.segmented)
            }
            Section("Session status") {
                Stepper("Active if seen within \(model.settings.activeWithinSeconds) seconds",
                        value: Binding(get: { model.settings.activeWithinSeconds }, set: { v in model.updateSettings { $0.activeWithinSeconds = v } }), in: 15...3600, step: 15)
                Stepper("Idle until \(model.settings.idleWithinMinutes) minutes without activity",
                        value: Binding(get: { model.settings.idleWithinMinutes }, set: { v in model.updateSettings { $0.idleWithinMinutes = v } }), in: 1...1440, step: 5)
                Text("These only affect sessions without a running process to observe. A session whose process is running is shown as active or idle exactly as Claude Code reports.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLogin(_ on: Bool) {
        do { try LoginItem.set(on); loginError = nil } catch { loginError = "\(error.localizedDescription)" }
        loginEnabled = LoginItem.isEnabled
    }
}

private struct QuotaSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                QuotaSetupCard()
                Card("Refresh") {
                    Stepper("Re-read quota files at least every \(model.settings.quotaRefreshSeconds) seconds",
                            value: Binding(get: { model.settings.quotaRefreshSeconds }, set: { v in model.updateSettings { $0.quotaRefreshSeconds = v } }),
                            in: AppSettings.quotaRefreshRange, step: 30)
                    Text("Updates normally arrive instantly through file events. This is only a safety net, limited to 30 seconds to 1 hour. The monitor never contacts any server to get quota figures, so there is nothing to rate-limit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Card("Undocumented source") {
                    Toggle("Show plan-usage samples cached by Claude Desktop", isOn: Binding(get: { model.settings.showDesktopPlanUsageHint }, set: { v in model.updateSettings { $0.showDesktopPlanUsageHint = v } }))
                    Text("Claude Desktop keeps a small local file with percentages. Its format is not documented and has no reset times, so values from it are labelled unverified, never reach the menu bar, and never trigger alerts. Off by default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding()
        }
    }
}

private struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var five = ""
    @State private var week = ""

    var body: some View {
        let n = model.settings.notifications
        Form {
            Section {
                Toggle("Enable notifications", isOn: bind(\.enabled))
                Text("Alerts use only quota values reported by Claude. They are never based on token counts, and each threshold is announced once per window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quota thresholds (percent)") {
                TextField("Five-hour window", text: $five, onCommit: { commit(five, five: true) }).disabled(!n.enabled)
                TextField("Weekly window", text: $week, onCommit: { commit(week, five: false) }).disabled(!n.enabled)
                Text("Comma-separated, for example 50, 75, 90.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Also notify when") {
                Toggle("A window resets after heavy use", isOn: bind(\.notifyOnReset)).disabled(!n.enabled)
                Toggle("Quota data becomes stale while Claude Code is in use", isOn: bind(\.notifyOnStaleData)).disabled(!n.enabled)
                Toggle("Usage collection keeps failing", isOn: bind(\.notifyOnCollectionFailure)).disabled(!n.enabled)
            }
            Section {
                Button("Send a test notification") {
                    NotificationDelivery.requestAuthorization()
                    NotificationDelivery.deliver([AlertNotification(key: "test-\(UUID().uuidString)", kind: .threshold, title: "Claude Usage", body: "Notifications are working.")])
                }.disabled(!n.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            five = n.fiveHourThresholds.map(String.init).joined(separator: ", ")
            week = n.weeklyThresholds.map(String.init).joined(separator: ", ")
        }
    }

    private func bind(_ key: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings.notifications[keyPath: key] }, set: { v in model.updateSettings { $0.notifications[keyPath: key] = v } })
    }

    private func commit(_ text: String, five isFive: Bool) {
        let values = text.split(whereSeparator: { ", ;".contains($0) }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        model.updateSettings { if isFive { $0.notifications.fiveHourThresholds = values } else { $0.notifications.weeklyThresholds = values } }
    }
}

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmErase = false

    private func sourceBinding(_ id: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { !model.settings.disabledSources.contains(id) },
            set: { enabled in
                model.updateSettings { s in
                    if enabled { s.disabledSources.remove(id) } else { s.disabledSources.insert(id) }
                }
            })
    }

    var body: some View {
        Form {
            Section("Sources") {
                ForEach(model.collectorSnapshot.sources) { s in
                    Toggle(s.displayName, isOn: sourceBinding(s.sourceID))
                    Text(s.coverageNote).font(.caption).foregroundStyle(.secondary)
                }
                Text("Sessions are discovered automatically. There is nothing to register.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Retention") {
                Picker("Keep history", selection: Binding(get: { model.settings.retentionDays }, set: { v in model.updateSettings { $0.retentionDays = v } })) {
                    Text("Forever").tag(0); Text("90 days").tag(90); Text("180 days").tag(180); Text("1 year").tag(365); Text("2 years").tag(730)
                }
                Text("Older records are deleted from this app's database and are not imported again. Your original Claude Code files are never touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Only usage metadata is stored: token counts, model names, timestamps, project folder names and session ids. Prompts, replies, file contents, environment variables and credentials are never read into the database. Nothing is sent over the network.")
                    .font(.callout)
            }
            Section("Local data") {
                Button("Reveal database in Finder") { NSWorkspace.shared.activateFileViewerSelecting([QuotaPaths.databaseURL]) }
                Button("Delete all collected data…", role: .destructive) { confirmErase = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all collected usage data?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Delete and re-import", role: .destructive) { model.eraseAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Claude Code files are not touched. The history is imported from them again, unless it is outside the retention period. Quota history cannot be recovered.")
        }
    }
}

private struct ExportSettings: View {
    @Environment(AppModel.self) private var model
    @State private var kind: ExportKind = .sessions
    @State private var format: ExportFormat = .csv
    @State private var range = RangeSelection(preset: .all)
    @State private var status: String?
    @State private var running = false
    @State private var lastURL: URL?

    var body: some View {
        Form {
            Section("What to export") {
                Picker("Data", selection: $kind) { ForEach(ExportKind.allCases) { Text($0.label).tag($0) } }
                Picker("Format", selection: $format) { Text("CSV").tag(ExportFormat.csv); Text("JSON").tag(ExportFormat.json) }.pickerStyle(.segmented)
                LabeledContent("Period") { RangePicker(selection: $range) }
                Text("Exports contain usage metadata only, with the definition and unit of every column. CSV files get a companion .metadata.json. Costs are exact decimal estimates, not charges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Export…") { export() }.disabled(running)
                    if running { ProgressView().controlSize(.small) }
                    if let lastURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([lastURL]) } }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "claude-usage-\(kind.rawValue).\(format.rawValue)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        if !model.settings.exportDirectory.isEmpty { panel.directoryURL = URL(fileURLWithPath: model.settings.exportDirectory) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateSettings { $0.exportDirectory = url.deletingLastPathComponent().path }
        running = true
        status = nil
        let db = model.db
        let interval = range.interval()
        let k = kind, f = format
        Task.detached {
            let message: String
            var written: URL?
            do {
                let lower = interval.from, upper = interval.to.map { $0.addingTimeInterval(-0.001) }
                let r: ClosedRange<Date>? = (lower != nil || upper != nil) ? (lower ?? Date(timeIntervalSince1970: 0))...(upper ?? Date()) : nil
                let result = try ExportService(db: db).export(kind: k, format: f, range: r, to: url)
                message = "Exported \(Fmt.grouped(Int64(result.rows))) rows."
                written = result.url
            } catch { message = "Export failed: \(error)" }
            await MainActor.run { status = message; lastURL = written; running = false }
        }
    }
}

private struct CostSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rates: [(String, String, String, String, String, String)] = []

    var body: some View {
        Form {
            Section {
                Toggle("Show API-equivalent cost estimates", isOn: Binding(get: { model.settings.showEstimatedCost }, set: { v in model.updateSettings { $0.showEstimatedCost = v } }))
                Text("These estimate what the same tokens would cost on the pay-as-you-go API at published list prices. They are not your subscription charge. Models without a price card are shown as unpriced instead of being guessed, and prices are dated so earlier estimates do not change when prices do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Built-in price cards (US$ per million tokens, as of \(PricingCatalog.asOf))") {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow { Text("Model").gridColumnAlignment(.leading); Text("Input"); Text("Output"); Text("Cache read"); Text("Write 5m"); Text("Write 1h") }.font(.caption.bold())
                    ForEach(Array(rates.enumerated()), id: \.offset) { _, r in
                        GridRow { Text(r.0).gridColumnAlignment(.leading); Text(r.1); Text(r.2); Text(r.3); Text(r.4); Text(r.5) }.font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let db = model.db
            rates = (try? await Task.detached {
                try db.read { c in
                    try c.query("""
                        SELECT model_key, speed, prompt_min, prompt_max, input_micros_per_mtok, output_micros_per_mtok,
                               cache_read_micros_per_mtok, cache_5m_micros_per_mtok, cache_1h_micros_per_mtok
                        FROM price_rate ORDER BY model_key, speed, prompt_min
                        """) { r in
                        func usd(_ i: Int32) -> String { String(format: "%g", Double(r.int(i)) / 1_000_000) }
                        var name = r.text(0)
                        if r.text(1) != "standard" { name += " (\(r.text(1)))" }
                        if r.int(2) > 0 || r.intOrNil(3) != nil { name += r.intOrNil(3) == nil ? " (> \(Fmt.tokens(r.int(2) - 1)))" : " (≤ \(Fmt.tokens(r.int(3) - 1)))" }
                        return (name, usd(4), usd(5), usd(6), usd(7), usd(8))
                    }
                }
            }.value) ?? []
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle").font(.system(size: 40)).foregroundStyle(Palette.series[1])
            Text("Claude Usage Monitor").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")").foregroundStyle(.secondary)
            Text("A local-first monitor for Claude Code usage. All data stays on this Mac.").multilineTextAlignment(.center).frame(maxWidth: 380)
            Divider().frame(width: 300)
            VStack(alignment: .leading, spacing: 4) {
                Text("Data folder: ~/Library/Application Support/ClaudeUsageMonitor").font(.caption)
                Text("Reads: ~/.claude/projects (transcripts), ~/.claude/sessions (live processes)").font(.caption)
                Text("Network: none").font(.caption)
            }.foregroundStyle(.secondary)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
