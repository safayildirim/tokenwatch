import SwiftUI
import UsageCore

/// These are the filters of the session explorer. The pure parts are separated so that they can be tested.
struct SessionFilterState: Equatable {
    var search = ""
    var projectIDs: Set<Int64> = []
    var models: Set<String> = []
    var statuses: Set<SessionState> = []
    var range = RangeSelection(preset: .all)

    var usageFilter: UsageFilter {
        var f = range.filter
        f.search = search
        f.projectIDs = projectIDs
        f.models = models
        return f
    }

    /// Status is derived from live information, so it is applied after the query.
    func apply(to rows: [SessionRow]) -> [SessionRow] {
        statuses.isEmpty ? rows : rows.filter { statuses.contains($0.status.state) }
    }

    var isFiltering: Bool {
        !search.isEmpty || !projectIDs.isEmpty || !models.isEmpty || !statuses.isEmpty || range.preset != .all
    }
}

struct SessionsPage: View {
    @Environment(AppModel.self) private var model
    @State private var filter = SessionFilterState()
    @State private var rows: [SessionRow] = []
    @State private var options = AnalyticsEngine.FilterOptions()
    @State private var sortOrder = [KeyPathComparator(\SessionRow.sortLastActivity, order: .reverse)]
    @State private var selection: Set<Int64> = []
    @State private var loading = false

    var body: some View {
        Group {
            if let id = model.openSessionID {
                SessionDetailView(sessionID: id) { model.openSessionID = nil }
            } else {
                explorer
            }
        }
        .task(id: "\(model.dataVersion)") { await loadOptions() }
        .task(id: reloadKey) { await load() }
        .onAppear {
            if let project = model.sessionsProjectFilter {
                filter.projectIDs = [project]
                model.sessionsProjectFilter = nil
            }
        }
        .onChange(of: model.sessionsProjectFilter) { _, new in
            if let new { filter.projectIDs = [new]; model.sessionsProjectFilter = nil }
        }
    }

    private var reloadKey: String { "\(filter.usageFilter.hashValueDescription)|\(model.dataVersion)|\(model.scopeVersion)" }

    private var visible: [SessionRow] { filter.apply(to: rows).sorted(using: sortOrder) }

    private var explorer: some View {
        VStack(spacing: 0) {
            filterBar.padding([.horizontal, .top], 16).padding(.bottom, 10)
            Divider()
            if visible.isEmpty && !loading {
                if filter.isFiltering {
                    EmptyState(symbol: "line.3.horizontal.decrease.circle", title: String(localized: "No sessions match"),
                               message: String(localized: "Try removing a filter or widening the date range."))
                        .overlay(alignment: .bottom) { Button("Clear filters") { filter = SessionFilterState() }.padding(.bottom, 20) }
                } else {
                    NoDataNotice()
                }
            } else {
                table
                Divider()
                footer
            }
        }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search project, folder or session id", text: $filter.search).textFieldStyle(.plain)
                if !filter.search.isEmpty {
                    Button { filter.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            .frame(minWidth: 220, maxWidth: 320)

            multiMenu(String(localized: "Project"), selection: $filter.projectIDs, items: options.projects.map { ($0.id, $0.name) })
            multiMenu(String(localized: "Model"), selection: $filter.models, items: options.models.map { ($0.canonical, $0.displayName) })
            multiMenu(String(localized: "Status"), selection: $filter.statuses, items: SessionState.allCases.map { ($0, $0.label) })
            RangePicker(selection: $filter.range)
            Spacer()
            if filter.isFiltering { Button("Clear") { filter = SessionFilterState() } }
        }
    }

    private func multiMenu<T: Hashable>(_ title: String, selection: Binding<Set<T>>, items: [(T, String)]) -> some View {
        Menu {
            ForEach(items, id: \.0) { item in
                Toggle(item.1, isOn: Binding(get: { selection.wrappedValue.contains(item.0) },
                                             set: { on in if on { selection.wrappedValue.insert(item.0) } else { selection.wrappedValue.remove(item.0) } }))
            }
            if !selection.wrappedValue.isEmpty { Divider(); Button("Clear") { selection.wrappedValue = [] } }
        } label: {
            Text(selection.wrappedValue.isEmpty ? title : String(localized: "\(title): \(selection.wrappedValue.count)"))
        }
        .menuStyle(.button).fixedSize()
    }

    // MARK: Table

    @TableColumnBuilder<SessionRow, KeyPathComparator<SessionRow>>
    private var identityColumns: some TableColumnContent<SessionRow, KeyPathComparator<SessionRow>> {
        TableColumn("Session", value: \.sortProject) { (s: SessionRow) in
            HStack(spacing: 6) {
                Image(systemName: model.surfaceSymbol(s.surface)).foregroundStyle(.secondary).frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.projectName).lineLimit(1)
                    Text(s.shortID).font(.caption2).foregroundStyle(.secondary).monospaced()
                }
            }
        }.width(min: 130, ideal: 160)
        TableColumn("Product", value: \.sortProduct) { (s: SessionRow) in
            VStack(alignment: .leading, spacing: 0) {
                Text(model.productName(s.productID)).lineLimit(1)
                Text(s.accountLabel == "Unassigned" ? model.surfaceName(s.surface) : "\(model.surfaceName(s.surface)) · \(s.accountLabel)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }.width(min: 110, ideal: 140)
        TableColumn("Model", value: \.sortModel) { (s: SessionRow) in
            Text(modelLabel(s))
        }.width(min: 80, ideal: 100)
        TableColumn("Started", value: \.sortStarted) { (s: SessionRow) in
            Text(Fmt.dateTime(s.startedAt)).foregroundStyle(.secondary)
        }.width(min: 100, ideal: 118)
        TableColumn("Duration", value: \.sortDuration) { (s: SessionRow) in
            Text(s.duration.map(Fmt.duration) ?? "—").monospacedDigit()
        }.width(min: 60, ideal: 70)
        TableColumn("Status", value: \.sortStatus) { (s: SessionRow) in StatusBadge(status: s.status) }.width(min: 90, ideal: 100)
    }

    @TableColumnBuilder<SessionRow, KeyPathComparator<SessionRow>>
    private var tokenColumns: some TableColumnContent<SessionRow, KeyPathComparator<SessionRow>> {
        TableColumn("Input", value: \.sortInput) { (s: SessionRow) in num(s.tokens.uncachedInput) }.width(min: 56, ideal: 64)
        TableColumn("Output", value: \.sortOutput) { (s: SessionRow) in num(s.tokens.output) }.width(min: 56, ideal: 64)
        TableColumn("Cache read", value: \.sortCacheRead) { (s: SessionRow) in num(s.tokens.cacheRead) }.width(min: 64, ideal: 76)
        TableColumn("Cache write", value: \.sortCacheWrite) { (s: SessionRow) in num(s.tokens.cacheCreation) }.width(min: 64, ideal: 76)
        TableColumn("Total", value: \.sortTotal) { (s: SessionRow) in num(s.tokens.totalProcessed).fontWeight(.medium) }.width(min: 60, ideal: 72)
    }

    @TableColumnBuilder<SessionRow, KeyPathComparator<SessionRow>>
    private var costColumn: some TableColumnContent<SessionRow, KeyPathComparator<SessionRow>> {
        TableColumn("Est. cost", value: \.sortCost) { (s: SessionRow) in
            Text(Fmt.cost(s.cost)).monospacedDigit().foregroundStyle(.secondary)
        }.width(min: 60, ideal: 70)
    }

    private func modelLabel(_ s: SessionRow) -> String {
        guard let first = s.models.first else { return "—" }
        return s.models.count > 1 ? "\(first) +\(s.models.count - 1)" : first
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            identityColumns
            tokenColumns
            if model.settings.showEstimatedCost { costColumn }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first {
                Button("Open details") { model.openSessionID = id }
                if let s = rows.first(where: { $0.id == id }) {
                    Button("Copy session id") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.externalID, forType: .string) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.openSessionID = id }
        }
        .onKeyPress(.return) {
            if let id = selection.first { model.openSessionID = id; return .handled }
            return .ignored
        }
    }

    private func num(_ n: Int64) -> Text { Text(Fmt.tokens(n)).monospacedDigit() }

    private var footer: some View {
        let t = visible.reduce(TokenCounts()) { $0 + $1.tokens }
        return HStack {
            Text("\(visible.count) sessions").foregroundStyle(.secondary)
            Spacer()
            Text("Input = uncached input. Total = everything processed, including cache reads. Double-click a row, or press Return, to open it.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("\(Fmt.tokens(t.totalProcessed)) processed · \(Fmt.tokens(t.freshTokens)) new").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout).padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Loading

    private func load() async {
        loading = true
        defer { loading = false }
        let f = model.scoped(filter.usageFilter)
        let policy = model.policy
        let live = model.live
        do {
            rows = try await model.query { try $0.sessionRows(f, now: Date(), live: live, policy: policy) }
        } catch { rows = [] }
    }

    private func loadOptions() async {
        if let o = try? await model.query({ try $0.filterOptions() }) { options = o }
    }
}

extension UsageFilter {
    /// A string that changes whenever the filter changes, for use as a task identity.
    var hashValueDescription: String {
        "\(from?.timeIntervalSince1970 ?? 0)|\(to?.timeIntervalSince1970 ?? 0)|\(projectIDs.sorted())|\(models.sorted())|\(search)"
    }
}

// These sort keys for the table are kept next to the view that uses them.
extension SessionRow {
    var sortProject: String { projectName.lowercased() }
    var sortProduct: String { productID.rawValue }
    var sortModel: String { models.first ?? "" }
    var sortStarted: Date { startedAt ?? .distantPast }
    var sortLastActivity: Date { lastActivityAt ?? .distantPast }
    var sortDuration: TimeInterval { duration ?? 0 }
    var sortStatus: String { status.state.rawValue }
    var sortInput: Int64 { tokens.uncachedInput }
    var sortOutput: Int64 { tokens.output }
    var sortCacheRead: Int64 { tokens.cacheRead }
    var sortCacheWrite: Int64 { tokens.cacheCreation }
    var sortTotal: Int64 { tokens.totalProcessed }
    var sortCost: Int64 { cost.picoUSD }
}
