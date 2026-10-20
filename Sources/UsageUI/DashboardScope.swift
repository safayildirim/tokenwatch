import Foundation
import UsageCore

/// The slice of usage that the dashboard shows: which providers, products, accounts and surfaces count.
///
/// An empty set means "all". The scope applies to every page of the dashboard, while the date range, model,
/// project and search filters belong to the page that offers them.
public struct DashboardScope: Equatable, Sendable {
    public var providers: Set<ProviderID> = []
    public var products: Set<ProductID> = []
    /// Row ids of accounts, as listed by `AnalyticsEngine.filterOptions()`.
    public var accounts: Set<Int64> = []
    public var surfaces: Set<SurfaceID> = []

    public init() {}

    public var isActive: Bool { !providers.isEmpty || !products.isEmpty || !accounts.isEmpty || !surfaces.isEmpty }

    /// The filter that selects exactly this scope.
    public var usageFilter: UsageFilter {
        var f = UsageFilter()
        apply(to: &f)
        return f
    }

    public func apply(to filter: inout UsageFilter) {
        filter.providers = providers
        filter.products = products
        filter.accounts = accounts
        filter.surfaces = surfaces
    }

    /// Drops choices that cannot match once the providers have been narrowed, so that the scope never selects nothing
    /// because of a stale choice. Returns the cleaned scope.
    public func normalized(registry: ProviderRegistry, options: AnalyticsEngine.FilterOptions) -> DashboardScope {
        var s = self
        if !s.providers.isEmpty {
            s.products = s.products.filter { id in registry.providerOf(product: id).map { s.providers.contains($0) } ?? false }
            let allowed = Set(options.accounts.filter { s.providers.contains($0.provider) }.map(\.id))
            s.accounts = s.accounts.intersection(allowed)
        }
        return s
    }

    /// A short phrase for a heading, such as "Claude · terminal".
    public func summary(registry: ProviderRegistry, options: AnalyticsEngine.FilterOptions) -> String {
        var parts: [String] = []
        parts += providers.compactMap { registry.provider($0)?.shortName }.sorted()
        parts += products.compactMap { registry.product($0)?.name }.sorted()
        parts += accounts.compactMap { id in options.accounts.first { $0.id == id }?.label }.sorted()
        parts += surfaces.compactMap { registry.surface($0)?.name }.sorted()
        return parts.isEmpty ? "All providers" : parts.joined(separator: " · ")
    }
}
