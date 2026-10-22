import SwiftUI
import UsageCore

// MARK: - Names from the registry

extension AppModel {
    /// The registry is the single source of names, so a provider added later is labelled without changing any view.
    func surfaceName(_ id: SurfaceID?) -> String { id.flatMap { db.registry.surface($0)?.name }.map(DisplayText.localized) ?? "—" }
    func surfaceSymbol(_ id: SurfaceID?) -> String { id.flatMap { db.registry.surface($0)?.symbol } ?? "questionmark.app" }
    func productName(_ id: ProductID) -> String { db.registry.product(id).map { DisplayText.localized($0.name) } ?? id.rawValue }
    func providerName(_ id: ProviderID) -> String { db.registry.provider(id)?.shortName ?? id.rawValue }
    func providerSymbol(_ id: ProviderID) -> String { db.registry.provider(id)?.symbol ?? "sparkles" }
    func sourceName(_ id: TelemetrySourceID) -> String { db.registry.source(id).map { DisplayText.localized($0.name) } ?? id.rawValue }

    /// The color that stands for a provider in every chart and legend.
    func providerColor(_ id: ProviderID) -> Color {
        Palette.provider(at: db.registry.providers.firstIndex { $0.id == id } ?? -1)
    }

    /// The name of the tool through which a provider's usage reaches this Mac, such as a coding agent's name: the
    /// provider's first product, in the registry's order, that has recorded anything. Only one name is used, so that
    /// a label stays short when a provider's sessions carry several products. It falls back to the provider's own
    /// name before any of its products has recorded anything.
    func toolName(_ id: ProviderID) -> String {
        let recorded = Set(filterOptions.products)
        let first = db.registry.products.first { $0.provider == id && recorded.contains($0.id) }
        return first.map { DisplayText.localized($0.name) } ?? providerName(id)
    }

    /// True when a pool has no figure yet because there is neither a local cache nor the optional status-line helper.
    ///
    /// The cache needs no setup: Claude Code writes it itself. Treating the status-line helper as the only possible
    /// source is what made a working local cache look disconnected.
    func needsSetup(_ pool: QuotaPoolInfo) -> Bool {
        guard pool.key.provider == .anthropic else { return false }
        if claudeHelperInstalled { return false }
        switch claudeQuotaConnection {
        case .noData, .collectionError: return true
        case .localCache, .statusLine, .stale: return false
        }
    }

    /// The state of the data source of a provider's session files, for explaining an empty page.
    func collectionState(of provider: ProviderID) -> SourceHealth.State? {
        let ids = Set(db.registry.sources.filter { $0.provider == provider && $0.kind == .sessionLogs }.map(\.id))
        let states = collectorSnapshot.sources.filter { ids.contains($0.sourceID) }.map(\.state)
        return states.isEmpty ? nil : (states.contains { $0 != .notFound } ? states.first { $0 != .notFound } : .notFound)
    }
}

// MARK: - Filters

/// A menu that lets the user tick any number of choices.
struct FilterMenu<T: Hashable>: View {
    var title: String
    @Binding var selection: Set<T>
    var items: [(T, String)]

    /// The title, then the one chosen item by name, or how many are chosen. Callers pass the English title, which is
    /// looked up here, so every caller's title is translated the same way.
    private var label: String {
        let title = NSLocalizedString(self.title, comment: "")
        if selection.isEmpty { return title }
        if selection.count == 1, let name = items.first(where: { selection.contains($0.0) })?.1 { return "\(title): \(name)" }
        return "\(title): \(selection.count)"
    }

    var body: some View {
        Menu {
            ForEach(items, id: \.0) { item in
                Toggle(item.1, isOn: Binding(get: { selection.contains(item.0) },
                                             set: { on in if on { selection.insert(item.0) } else { selection.remove(item.0) } }))
            }
            if !selection.isEmpty { Divider(); Button("Clear") { selection = [] } }
        } label: {
            Text(label)
        }
        .menuStyle(.button).fixedSize()
        .disabled(items.isEmpty)
    }
}

/// The filters that apply to every page of the dashboard: provider, product, account and surface.
struct ScopeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let options = model.filterOptions
        let registry = model.db.registry
        let providers = model.scope.providers
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            FilterMenu(title: "Provider", selection: $model.scope.providers,
                       items: options.providers.map { ($0, model.providerName($0)) })
            FilterMenu(title: "Product", selection: $model.scope.products,
                       items: options.products.filter { providers.isEmpty || (registry.providerOf(product: $0).map(providers.contains) ?? false) }
                           .map { ($0, model.productName($0)) })
            FilterMenu(title: "Account", selection: $model.scope.accounts,
                       items: options.accounts.filter { providers.isEmpty || providers.contains($0.provider) }
                           .map { ($0.id, "\(model.providerName($0.provider)) · \(DisplayText.localized($0.label))") })
            FilterMenu(title: "Surface", selection: $model.scope.surfaces,
                       items: options.surfaces.map { ($0, model.surfaceName($0)) })
            if model.scope.isActive {
                Button("Clear") { model.scope = DashboardScope() }
                Text("Showing \(model.scope.summary(registry: registry, options: options))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard filters")
    }
}

/// A small label naming the provider that a row belongs to.
struct ProviderChip: View {
    @Environment(AppModel.self) private var model
    var provider: ProviderID
    var body: some View {
        Label(model.providerName(provider), systemImage: model.providerSymbol(provider))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - Quota meter

/// One quota window as a bar, with the numbers, countdown, freshness and source stated explicitly.
struct QuotaMeter: View {
    @Environment(AppModel.self) private var model
    var state: QuotaWindowState
    var compact = false
    /// Called by the "Set up" button when the window has no data and a helper has to be installed first.
    var onSetup: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.displayName).font(compact ? .subheadline.weight(.medium) : .headline)
                Spacer()
                headline
            }
            bar
            details
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var headline: some View {
        switch state.availability {
        case .available where state.reading != nil:
            let pct = state.reading!.utilizationPercent
            HStack(spacing: 4) {
                if !state.isAuthoritative { Text("unverified").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.secondary.opacity(0.2))) }
                Text("\(Int(pct.rounded()))% used").font(compact ? .subheadline : .title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(state.freshness == .stale ? .secondary : .primary)
            }
        case .windowElapsed:
            Label("Reset", systemImage: "arrow.counterclockwise").font(.subheadline).foregroundStyle(.secondary)
        default:
            Text("Unavailable").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                if let pct = state.utilizationPercent {
                    Capsule()
                        .fill(state.isAuthoritative ? Palette.quota(pct) : Palette.other)
                        .opacity(state.freshness == .stale ? 0.45 : 1)
                        .frame(width: max(4, geo.size.width * min(1, pct / 100)))
                }
            }
        }
        .frame(height: compact ? 6 : 8)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var details: some View {
        switch state.availability {
        case .available:
            if let r = state.reading {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(Int(max(0, 100 - r.utilizationPercent).rounded()))% remaining")
                        Spacer()
                        if let resets = r.resetsAt {
                            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                                Text("Resets in \(Fmt.duration(max(0, resets.timeIntervalSince(ctx.date))))")
                            }
                        } else {
                            Text("Reset time not reported")
                        }
                    }
                    freshnessLine(r)
                    if !compact, let conflict = state.sourceConflict { conflictLine(conflict) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        case .windowElapsed(let at):
            Text("This window reset \(Fmt.relative(at)). The new value appears after \(model.providerName(state.pool.key.provider)) next reports it.")
                .font(.caption).foregroundStyle(.secondary)
        case .unavailable:
            HStack {
                Text("No authoritative quota data yet.").font(.caption).foregroundStyle(.secondary)
                if let onSetup { Button("Set up", action: onSetup).controlSize(.mini) }
            }
        }
    }

    @ViewBuilder private func conflictLine(_ conflict: QuotaSourceConflict) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let alternatives = conflict.alternatives.prefix(2).map {
                "\(model.sourceName($0.source)) \(Int($0.utilizationPercent.rounded()))%"
            }.joined(separator: ", ")
            Text("Another source reported \(alternatives). The newest observation is shown; percentages from different sources are never averaged.")
                .fixedSize(horizontal: false, vertical: true)
            let selected = conflict.selected
            Text("Selected: \(model.sourceName(selected.source)), \(Fmt.relative(selected.observedAt)).")
                .font(.caption2)
        }
        .foregroundStyle(Palette.warning)
    }

    private func freshnessLine(_ r: QuotaReading) -> some View {
        HStack(spacing: 4) {
            if state.freshness == .stale {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                Text("Stale: last updated \(Fmt.relative(r.observedAt))")
            } else {
                Text("Updated \(Fmt.relative(r.observedAt))")
            }
            Text("·")
            Text(model.sourceName(r.source)).lineLimit(1)
        }
    }
}

/// A pool with its title and all of its windows: the unit that a quota percentage belongs to.
struct QuotaPoolCard: View {
    @Environment(AppModel.self) private var model
    var pool: QuotaPoolState
    var compact = false
    var onSetup: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pool.pool.name).font(compact ? .subheadline.weight(.semibold) : .headline)
                if pool.pool.accountLabel != "Unassigned" {
                    Text(pool.pool.accountLabel).font(.caption).foregroundStyle(.secondary)
                } else if pool.windows.contains(where: { $0.reading != nil }) {
                    Text("account not identified").font(.caption).foregroundStyle(.secondary)
                }
                if let plan = pool.pool.planType { Text(plan.capitalized).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.secondary.opacity(0.15))) }
                Spacer()
            }
            if !compact, !pool.pool.products.isEmpty {
                Text("Shared by \(ListFormatter.localizedString(byJoining: pool.pool.products.map(model.productName))).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(pool.windows) { w in
                QuotaMeter(state: w, compact: compact, onSetup: model.needsSetup(pool.pool) ? onSetup : nil)
            }
        }
    }
}
