import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import UsageCore

public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.general
    public init() {}

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General", quota = "Quota", notifications = "Notifications", data = "Data", export = "Export", cost = "Cost", about = "About"
        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: String(localized: "General")
            case .quota: String(localized: "Quota")
            case .notifications: String(localized: "Notifications")
            case .data: String(localized: "Data")
            case .export: String(localized: "Export")
            case .cost: String(localized: "Cost")
            case .about: String(localized: "About")
            }
        }
    }

    /// The pages are chosen with a segmented control instead of a tab view. A tab view puts its tabs into the window's
    /// toolbar, and at this window's width macOS folded all seven into an overflow menu that is easy to miss.
    public var body: some View {
        VStack(spacing: 0) {
            Picker("Settings page", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            Group {
                switch tab {
                case .general: GeneralSettings()
                case .quota: QuotaSettings()
                case .notifications: NotificationSettingsView()
                case .data: DataSettings()
                case .export: ExportSettings()
                case .cost: CostSettings()
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 560)
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
            Section("Dock") {
                Toggle("Show in the Dock", isOn: Binding(get: { model.settings.showDockIcon }, set: { v in model.updateSettings { $0.showDockIcon = v } }))
                if model.menuBarIconHidden {
                    Label("macOS is hiding the menu bar icon because the menu bar is full, so the app is shown in the Dock for now.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Palette.warning)
                }
                Text("Normally the app lives only in the menu bar. A Dock icon gives you another way in, and clicking it opens the dashboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Picker("Show", selection: Binding(get: { model.settings.menuBarMode }, set: { v in model.updateSettings { $0.menuBarMode = v } })) {
                    ForEach(MenuBarDisplayMode.choices(for: model.providers)) { Text($0.label(providers: model.providers)).tag($0) }
                }
                Text("Percentages are real quota values reported by each provider's own software. Different pools are shown side by side or compared, never added. When no value is available the menu bar shows only the icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { model.settings.appearance }, set: { v in model.updateSettings { $0.appearance = v } })) {
                    Text("Match system").tag(AppearanceMode.system); Text("Light").tag(AppearanceMode.light); Text("Dark").tag(AppearanceMode.dark)
                }.pickerStyle(.segmented)
                LanguagePicker()
            }
            Section("Session status") {
                Stepper("Active if seen within \(model.settings.activeWithinSeconds) seconds",
                        value: Binding(get: { model.settings.activeWithinSeconds }, set: { v in model.updateSettings { $0.activeWithinSeconds = v } }), in: 15...3600, step: 15)
                Stepper("Idle until \(model.settings.idleWithinMinutes) minutes without activity",
                        value: Binding(get: { model.settings.idleWithinMinutes }, set: { v in model.updateSettings { $0.idleWithinMinutes = v } }), in: 1...1440, step: 5)
                Text("These only affect sessions without a running process to observe. A session whose process is running is shown as active or idle exactly as its tool reports (only Claude Code keeps a process registry).")
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
                Card("Undocumented sources") {
                    Toggle("Show plan-usage figures from undocumented caches", isOn: Binding(get: { model.settings.showUnverifiedQuota }, set: { v in model.updateSettings { $0.showUnverifiedQuota = v } }))
                    Text("Claude Desktop keeps a small local file with percentages. Its format is not documented and has no reset times, so values from it are labelled unverified, never reach the menu bar, never trigger alerts and are not stored. Off by default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding()
        }
    }
}

private struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var short = ""
    @State private var long = ""

    var body: some View {
        let n = model.settings.notifications
        Form {
            Section {
                Toggle("Enable notifications", isOn: bind(\.enabled))
                Text("Alerts use only quota values reported by the provider. They are never based on token counts. Each threshold is announced once per window cycle, separately for every account and pool.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quota thresholds (percent)") {
                TextField("Windows of a day or less (such as 5 hours)", text: $short, onCommit: { commit(short, isShort: true) }).disabled(!n.enabled)
                TextField("Longer windows (such as a week)", text: $long, onCommit: { commit(long, isShort: false) }).disabled(!n.enabled)
                Text("Comma-separated, for example 50, 75, 90.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Also notify when") {
                Toggle("A window resets after heavy use", isOn: bind(\.notifyOnReset)).disabled(!n.enabled)
                Toggle("Quota data becomes stale while its provider's tools are in use", isOn: bind(\.notifyOnStaleData)).disabled(!n.enabled)
                Toggle("Usage collection keeps failing", isOn: bind(\.notifyOnCollectionFailure)).disabled(!n.enabled)
            }
            Section("Delivery") {
                LabeledContent("macOS permission", value: model.notificationPermission.description)
                HStack {
                    Button("Send a test notification") { Task { await model.sendTestNotification() } }
                    if model.notificationPermission == .denied {
                        Button("Open Notification Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                if let problem = model.notificationProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else if model.notificationPermission == .allowed {
                    Text("The test is not tied to any quota. It only checks that macOS shows the app's notifications.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshNotificationPermission() }
        .onAppear {
            short = n.shortWindowThresholds.map(String.init).joined(separator: ", ")
            long = n.longWindowThresholds.map(String.init).joined(separator: ", ")
        }
    }

    private func bind(_ key: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings.notifications[keyPath: key] }, set: { v in model.updateSettings { $0.notifications[keyPath: key] = v } })
    }

    private func commit(_ text: String, isShort: Bool) {
        let values = text.split(whereSeparator: { ", ;".contains($0) }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        model.updateSettings { if isShort { $0.notifications.shortWindowThresholds = values } else { $0.notifications.longWindowThresholds = values } }
    }
}

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmErase = false
    @State private var eraseRisk: UsageDatabase.RetainedHistory?

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
                    Toggle(s.displayName, isOn: sourceBinding(s.sourceID.rawValue))
                    Text(s.coverageNote).font(.caption).foregroundStyle(.secondary)
                }
                Text("Sessions are discovered automatically. There is nothing to register.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Retention") {
                Picker("Keep history", selection: Binding(get: { model.settings.retentionDays }, set: { v in model.updateSettings { $0.retentionDays = v } })) {
                    Text("Forever").tag(0); Text("90 days").tag(90); Text("180 days").tag(180); Text("1 year").tag(365); Text("2 years").tag(730)
                }
                Text("Older records are deleted from this app's database and are not imported again. Your original session files are never touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Only usage metadata is stored: token counts, model names, timestamps, project folder names and session ids. Prompts, replies, file contents, environment variables and credentials are never read into the database. Nothing is sent over the network.")
                    .font(.callout)
            }
            Section("Local data") {
                Button("Reveal database in Finder") { NSWorkspace.shared.activateFileViewerSelecting([QuotaPaths.databaseURL]) }
                Button("Delete all collected data…", role: .destructive) {
                    Task {
                        eraseRisk = await model.retainedOnlyHistory()
                        confirmErase = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all collected usage data?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Delete and re-import", role: .destructive) { model.eraseAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(eraseMessage)
        }
    }
}

extension DataSettings {
    /// The erase warning. Erasing is meant to remove the data, so no copy is made, and the warning says plainly what
    /// cannot be imported again.
    fileprivate var eraseMessage: String {
        let lost = eraseRisk.map(\.requests) ?? 0
        guard lost > 0, let files = eraseRisk?.files else {
            return String(localized: "Your session files are not touched, and usage is imported from them again unless it is outside the retention period. No copy is kept. Quota history cannot be recovered, because the quota sources keep only their latest reading.")
        }
        let requests = Fmt.grouped(Int64(lost))
        return String(localized: "Your session files are not touched, and usage is imported from them again unless it is outside the retention period. \(requests) stored requests come from \(files) session files that no longer exist; they are deleted permanently. No copy is kept. Quota history cannot be recovered, because the quota sources keep only their latest reading.")
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
                Text("Exports contain usage metadata only, with the definition and unit of every column. CSV files get a companion .metadata.json. Costs are exact decimal estimates, not charges. The dashboard's provider, product, account and surface filters apply.")
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
        panel.nameFieldStringValue = "ai-usage-\(kind.rawValue).\(format.rawValue)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        if !model.settings.exportDirectory.isEmpty { panel.directoryURL = URL(fileURLWithPath: model.settings.exportDirectory) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateSettings { $0.exportDirectory = url.deletingLastPathComponent().path }
        running = true
        status = nil
        let db = model.db
        let interval = range.interval()
        let scope = model.scope.usageFilter
        let k = kind, f = format
        Task.detached {
            let message: String
            var written: URL?
            do {
                let lower = interval.from, upper = interval.to.map { $0.addingTimeInterval(-0.001) }
                let r: ClosedRange<Date>? = (lower != nil || upper != nil) ? (lower ?? Date(timeIntervalSince1970: 0))...(upper ?? Date()) : nil
                let result = try ExportService(db: db).export(kind: k, format: f, range: r, to: url, filter: scope)
                message = String(localized: "Exported \(Fmt.grouped(Int64(result.rows))) rows.")
                written = result.url
            } catch {
                let reason = String(describing: error)
                message = String(localized: "Export failed: \(reason)")
            }
            await MainActor.run { status = message; lastURL = written; running = false }
        }
    }
}

private struct CostSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rates: [(String, String, String, String, String, String, String)] = []
    @State private var unpriced: [(ProviderID, String)] = []
    @State private var provider: ProviderID = .anthropic
    @State private var modelKey = ""
    @State private var input = ""
    @State private var cachedInput = ""
    @State private var output = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show API-equivalent cost estimates", isOn: Binding(get: { model.settings.showEstimatedCost }, set: { v in model.updateSettings { $0.showEstimatedCost = v } }))
                Text("These estimate what the same tokens would cost on the pay-as-you-go API at published list prices. They are not your subscription charge. Models without a price card are shown as unpriced instead of being guessed, and prices are dated so earlier estimates do not change when prices do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add a price") {
                Picker("Provider", selection: $provider) { ForEach(model.providers, id: \.id) { Text($0.name).tag($0.id) } }
                Picker("Model", selection: $modelKey) {
                    Text("Type a model name below").tag("")
                    ForEach(unpriced.filter { $0.0 == provider }, id: \.1) { Text("\($0.1) (no price yet)").tag($0.1) }
                }
                TextField("Model key", text: $modelKey)
                TextField("Input, US$ per million tokens", text: $input)
                TextField("Cached input, US$ per million", text: $cachedInput)
                TextField("Output, US$ per million", text: $output)
                HStack {
                    Button("Save price") { save() }.disabled(modelKey.isEmpty || Double(input) == nil || Double(output) == nil)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Use the published price of the model. Reasoning tokens are part of output and are priced as output. A price you add applies to all usage of that model, past and future, and replaces any built-in price with the same date.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Price cards (US$ per million tokens; \(PricingCatalog.asOfSummary))") {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow { Text("Model").gridColumnAlignment(.leading); Text("Provider").gridColumnAlignment(.leading); Text("Input"); Text("Output"); Text("Cache read"); Text("Write 5m"); Text("Write 1h") }.font(.caption.bold())
                    ForEach(Array(rates.enumerated()), id: \.offset) { _, r in
                        GridRow { Text(r.0).gridColumnAlignment(.leading); Text(r.1).gridColumnAlignment(.leading); Text(r.2); Text(r.3); Text(r.4); Text(r.5); Text(r.6) }.font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model.dataVersion) { await load() }
    }

    private static func day(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func save() {
        guard let i = Double(input), let o = Double(output) else { return }
        let cached = Double(cachedInput) ?? i
        let rate = PriceRate(provider: provider, model: modelKey.trimmingCharacters(in: .whitespaces).lowercased(), input: i, output: o,
                             cacheRead: cached, cache5m: i, cache1h: i, note: "Added by you.")
        do {
            try PricingStore.upsertUserRate(model.db, rate)
            message = String(localized: "Saved.")
            input = ""; cachedInput = ""; output = ""; modelKey = ""
            model.requestRefresh()
        } catch {
            let reason = String(describing: error)
            message = String(localized: "Could not save: \(reason)")
        }
        Task { await load() }
    }

    private func load() async {
        let db = model.db
        let result = try? await Task.detached {
            try db.read { c in
                let cards = try c.query("""
                    SELECT model_key, provider_id, speed, prompt_min, prompt_max, input_micros_per_mtok, output_micros_per_mtok,
                           cache_read_micros_per_mtok, cache_5m_micros_per_mtok, cache_1h_micros_per_mtok, effective_from, origin
                    FROM price_rate ORDER BY provider_id, model_key, speed, prompt_min, effective_from
                    """) { r -> (String, String, String, String, String, String, String) in
                    func usd(_ i: Int32) -> String { String(format: "%g", Double(r.int(i)) / 1_000_000) }
                    var name = r.text(0)
                    if r.text(2) != "standard" { name += " (\(r.text(2)))" }
                    if r.int(3) > 0 || r.intOrNil(4) != nil { name += r.intOrNil(4) == nil ? " (> \(Fmt.tokens(r.int(3) - 1)))" : " (≤ \(Fmt.tokens(r.int(4) - 1)))" }
                    // A card that starts later than the epoch says from when it applies, and where its price comes from.
                    if r.int(10) > 0 {
                        let day = Self.day(r.int(10))
                        name += " " + String(localized: "from \(day)")
                    }
                    switch r.text(11) {
                    case "derived": name += " · " + String(localized: "derived")
                    case "user": name += " · " + String(localized: "yours")
                    default: break
                    }
                    return (name, r.text(1), usd(5), usd(6), usd(7), usd(8), usd(9))
                }
                let missing = try c.query("""
                    SELECT DISTINCT m.provider_id, m.canonical FROM model m
                    JOIN model_request r ON r.model_id = m.id
                    WHERE NOT EXISTS (SELECT 1 FROM price_rate p WHERE p.provider_id = m.provider_id AND p.model_key = m.canonical)
                    ORDER BY m.provider_id, m.canonical
                    """) { (ProviderID(rawValue: $0.text(0)), $0.text(1)) }
                return (cards, missing)
            }
        }.value
        rates = result?.0 ?? []
        unpriced = result?.1 ?? []
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(Palette.series[1])
            Text("Tokenwatch").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")").foregroundStyle(.secondary)
            Text("A local-first monitor for the usage of AI coding tools: Claude Code, and the Codex engine behind the Codex apps and ChatGPT Work. All data stays on this Mac.").multilineTextAlignment(.center).frame(maxWidth: 380)
            Divider().frame(width: 300)
            VStack(alignment: .leading, spacing: 4) {
                Text("Data folder: ~/Library/Application Support/Tokenwatch").font(.caption)
                Text("Reads: ~/.claude/projects and ~/.claude/sessions (Claude Code), ~/.codex/sessions and archived_sessions (Codex)").font(.caption)
                Text("Never reads: credentials, message text, tool output").font(.caption)
                Text("Network: none").font(.caption)
            }.foregroundStyle(.secondary)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Chooses the language of the interface. A change is saved at once and shown after a restart, which the picker offers.
struct LanguagePicker: View {
    @Environment(AppModel.self) private var model
    @State private var choice = AppLanguage.saved
    @State private var restarting = false

    var body: some View {
        Picker("Language", selection: $choice) {
            ForEach(AppLanguage.allCases) { language in
                Text(language == .system ? "\(language.label) (\(AppLanguage.systemChoice.label))" : language.label).tag(language)
            }
        }
        .onChange(of: choice) { _, new in new.save() }
        if choice.resolved != AppLanguage.current {
            HStack(spacing: 8) {
                Text("Tokenwatch shows the new language after it restarts.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    restarting = true
                    AppLanguage.relaunch(model: model)
                } label: {
                    restarting ? Text("Restarting…") : Text("Restart Now")
                }
                .disabled(restarting)
            }
        }
    }
}
