import SwiftUI
import UsageCore

/// What each provider's data sources can and cannot report, and whether they are delivering.
struct ProvidersPage: View {
    @Environment(AppModel.self) private var model

    private static let columns: [(Capabilities, String)] = [
        (.sessions, String(localized: "Sessions")), (.requestTokens, String(localized: "Tokens")), (.cacheTokens, String(localized: "Cache")),
        (.reasoningTokens, String(localized: "Reasoning")), (.models, String(localized: "Models")), (.quotaUtilization, String(localized: "Quota %")),
        (.quotaResetTimes, String(localized: "Reset times")), (.reportedCost, String(localized: "Own cost")),
        (.liveSessionState, String(localized: "Live state")), (.accountIdentity, String(localized: "Accounts")),
    ]

    var body: some View {
        PageScroll {
            Text("Each provider is read through independent data sources. A problem with one never stops another, and a capability marked as missing is never filled in with a guess.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.providers, id: \.id) { provider in providerCard(provider) }
            Card(String(localized: "Capability matrix"),
                 subtitle: String(localized: "What each data source reports. A dash means the source does not provide it.")) { matrix }
        }
    }

    // MARK: Provider

    private func providerCard(_ provider: ProviderDefinition) -> some View {
        let registry = model.db.registry
        let sources = registry.sources.filter { $0.provider == provider.id }
        let products = registry.products(of: provider.id)
        let pools = registry.pools.filter { $0.provider == provider.id }
        let accounts = model.filterOptions.accounts.filter { $0.provider == provider.id }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(provider.name, systemImage: provider.symbol).font(.title3.weight(.semibold))
                    Spacer()
                    (accounts.isEmpty ? Text("No accounts seen yet") : accounts.count == 1 ? Text("1 account seen") : Text("\(accounts.count) accounts seen"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Products").font(.subheadline.weight(.semibold))
                    ForEach(products, id: \.id) { product in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: product.isObservable ? "checkmark.circle.fill" : "eye.slash")
                                .foregroundStyle(product.isObservable ? Palette.good : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(product.name).font(.callout.weight(.medium))
                                Text(product.observability).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Data sources").font(.subheadline.weight(.semibold))
                    ForEach(sources, id: \.id) { source in sourceRow(source) }
                }
                if !pools.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quota pools").font(.subheadline.weight(.semibold))
                        ForEach(pools, id: \.key) { pool in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(pool.name).font(.callout.weight(.medium))
                                    if !pool.isObservable { Text("not observable").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.2))) }
                                }
                                Text("Used by \(ListFormatter.localizedString(byJoining: pool.products.map(model.productName))). \(pool.note)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: TelemetrySourceDefinition) -> some View {
        let health = model.collectorSnapshot.sources.first { $0.sourceID == source.id }
        let feed = model.quotaFeeds.first { $0.id == source.id }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: health, feed: feed)).foregroundStyle(color(for: health, feed: feed))
                Text(source.name).font(.callout.weight(.medium))
                Spacer()
                Text(statusText(for: health, feed: feed)).font(.caption).foregroundStyle(.secondary)
            }
            Text(source.limitations).font(.caption).foregroundStyle(.secondary)
            if let health {
                Text("\(health.filesKnown) files · last success \(Fmt.relative(health.lastSuccessAt))").font(.caption).foregroundStyle(.secondary)
                if let error = health.lastError, health.state != .notFound { Text(error).font(.caption).foregroundStyle(Palette.warning) }
            }
        }
    }

    private func icon(for health: SourceHealth?, feed: QuotaFeedStatus?) -> String {
        if let health { return health.state == .ok ? "checkmark.circle.fill" : (health.state == .notFound ? "questionmark.folder" : "exclamationmark.triangle.fill") }
        if let feed { return feed.observationCount > 0 ? "checkmark.circle.fill" : "circle.dashed" }
        return "circle.dashed"
    }

    private func color(for health: SourceHealth?, feed: QuotaFeedStatus?) -> Color {
        if let health { return health.state == .ok ? Palette.good : (health.state == .failing ? Palette.critical : Palette.warning) }
        if let feed, feed.observationCount > 0 { return Palette.good }
        return .secondary
    }

    private func statusText(for health: SourceHealth?, feed: QuotaFeedStatus?) -> String {
        if let health {
            switch health.state {
            case .ok: return String(localized: "Healthy")
            case .notFound: return String(localized: "Not found on this Mac")
            case .degraded: return String(localized: "Some files failing")
            case .failing: return String(localized: "Failing")
            }
        }
        if let feed {
            return feed.observationCount > 0 ? String(localized: "Receiving · newest \(Fmt.relative(feed.newestObservation))") : String(localized: "No reports received")
        }
        return String(localized: "Off")
    }

    // MARK: Matrix

    private var matrix: some View {
        let registry = model.db.registry
        return Grid(alignment: .center, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Source").bold().gridColumnAlignment(.leading)
                ForEach(Self.columns, id: \.1) { Text($0.1).bold() }
            }.font(.caption)
            Divider()
            ForEach(registry.sources, id: \.id) { source in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name).font(.caption.weight(.medium))
                        Text(model.providerName(source.provider)).font(.caption2).foregroundStyle(.secondary)
                    }.gridColumnAlignment(.leading)
                    ForEach(Self.columns, id: \.1) { column in
                        let has = source.capabilities.contains(column.0)
                        Image(systemName: has ? "checkmark" : "minus")
                            .font(.caption).foregroundStyle(has ? Palette.good : Color.secondary.opacity(0.5))
                            .accessibilityLabel(has ? String(localized: "\(column.1): yes") : String(localized: "\(column.1): no"))
                    }
                }
            }
            ForEach(registry.products.filter { !$0.isObservable }, id: \.id) { product in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(product.name).font(.caption.weight(.medium))
                        Text("\(model.providerName(product.provider)) · no local source").font(.caption2).foregroundStyle(.secondary)
                    }.gridColumnAlignment(.leading)
                    ForEach(Self.columns, id: \.1) { _ in Image(systemName: "minus").font(.caption).foregroundStyle(Color.secondary.opacity(0.5)) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
