import Foundation

/// What a telemetry source can report. The interface uses this to say honestly what is and is not observable.
public struct Capabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let sessions = Capabilities(rawValue: 1 << 0)
    public static let requestTokens = Capabilities(rawValue: 1 << 1)
    public static let cacheTokens = Capabilities(rawValue: 1 << 2)
    public static let reasoningTokens = Capabilities(rawValue: 1 << 3)
    public static let models = Capabilities(rawValue: 1 << 4)
    public static let quotaUtilization = Capabilities(rawValue: 1 << 5)
    public static let quotaResetTimes = Capabilities(rawValue: 1 << 6)
    public static let reportedCost = Capabilities(rawValue: 1 << 7)
    public static let liveSessionState = Capabilities(rawValue: 1 << 8)
    public static let accountIdentity = Capabilities(rawValue: 1 << 9)
}

public struct ProviderDefinition: Sendable, Equatable {
    public var id: ProviderID
    public var name: String
    /// The name people use for the provider's assistant in short labels, such as "Claude" for Anthropic.
    public var shortName: String
    /// A symbol for the provider's section headings.
    public var symbol: String

    public init(id: ProviderID, name: String, shortName: String? = nil, symbol: String = "sparkles") {
        self.id = id
        self.name = name
        self.shortName = shortName ?? name
        self.symbol = symbol
    }
}

public struct ProductDefinition: Sendable, Equatable {
    public var id: ProductID
    public var provider: ProviderID
    public var name: String
    /// A short sentence on how much of this product can be observed locally.
    public var observability: String
    /// False for a product that leaves no usage records on this Mac. It is listed so that the interface can say so.
    public var isObservable = true
}

public struct SurfaceDefinition: Sendable, Equatable {
    public var id: SurfaceID
    public var name: String
    public var symbol: String
}

/// An allowance that a provider enforces against an account, such as a subscription's usage limits.
///
/// One pool can be shared by several products (Codex and ChatGPT Work share one allowance on the plans
/// that include both), and one product can belong to several pools. The relationship is data, so a change
/// in a provider's plan rules is a change here and nowhere else.
public struct QuotaPoolDefinition: Sendable, Equatable {
    public var key: String
    public var provider: ProviderID
    public var name: String
    public var products: [ProductID]
    public var note: String
    /// False for allowances that exist but leave no record on this Mac. They are listed so that the
    /// interface can say so, and they never show a figure.
    public var isObservable = true
    /// The windows that the provider is known to enforce, by length. They are listed even before any
    /// figure has been reported, so that the interface can explain why a figure is missing.
    public var standardWindowMinutes: [Int] = []
}

public enum TelemetryKind: String, Sendable {
    case sessionLogs, quotaFeed, openTelemetry, officialAPI
}

public struct TelemetrySourceDefinition: Sendable, Equatable {
    public var id: TelemetrySourceID
    public var provider: ProviderID
    public var products: [ProductID]
    public var kind: TelemetryKind
    public var name: String
    public var capabilities: Capabilities
    /// What this source cannot report, stated plainly for the diagnostics view.
    public var limitations: String
}

/// All providers, products, surfaces, quota pools and telemetry sources known to the application.
///
/// The built-in registry covers Anthropic and OpenAI. A provider is added by supplying another registry
/// value (see `adding(_:)`) together with an adapter that implements `SourceAdapter`. Nothing else in the
/// core mentions a provider by name.
public struct ProviderRegistry: Sendable {
    public var providers: [ProviderDefinition]
    public var products: [ProductDefinition]
    public var surfaces: [SurfaceDefinition]
    public var pools: [QuotaPoolDefinition]
    public var sources: [TelemetrySourceDefinition]

    public init(providers: [ProviderDefinition] = [], products: [ProductDefinition] = [], surfaces: [SurfaceDefinition] = [],
                pools: [QuotaPoolDefinition] = [], sources: [TelemetrySourceDefinition] = []) {
        self.providers = providers
        self.products = products
        self.surfaces = surfaces
        self.pools = pools
        self.sources = sources
    }

    /// Returns this registry extended with the definitions of another one.
    public func adding(_ other: ProviderRegistry) -> ProviderRegistry {
        func merged<T, K: Hashable>(_ a: [T], _ b: [T], key: (T) -> K) -> [T] {
            var seen = Set(a.map(key))
            return a + b.filter { seen.insert(key($0)).inserted }
        }
        return ProviderRegistry(
            providers: merged(providers, other.providers) { $0.id },
            products: merged(products, other.products) { $0.id },
            surfaces: merged(surfaces, other.surfaces) { $0.id },
            pools: merged(pools, other.pools) { "\($0.provider.rawValue)/\($0.key)" },
            sources: merged(sources, other.sources) { $0.id })
    }

    public func provider(_ id: ProviderID) -> ProviderDefinition? { providers.first { $0.id == id } }
    public func product(_ id: ProductID) -> ProductDefinition? { products.first { $0.id == id } }
    public func surface(_ id: SurfaceID) -> SurfaceDefinition? { surfaces.first { $0.id == id } }
    public func source(_ id: TelemetrySourceID) -> TelemetrySourceDefinition? { sources.first { $0.id == id } }
    public func pool(provider: ProviderID, key: String) -> QuotaPoolDefinition? {
        pools.first { $0.provider == provider && $0.key == key }
    }
    public func providerOf(product id: ProductID) -> ProviderID? { product(id)?.provider }
    public func products(of provider: ProviderID) -> [ProductDefinition] { products.filter { $0.provider == provider } }
    /// The pools that observations from a product can belong to.
    public func pools(of product: ProductID) -> [QuotaPoolDefinition] { pools.filter { $0.products.contains(product) } }
}

/// A short, readable name for a quota window, derived from its length.
public enum WindowNaming {
    /// The stable key of a window of a known length, for example `300m`.
    public static func key(minutes: Int) -> String { "\(minutes)m" }

    public static func displayName(minutes: Int?, fallbackKey: String) -> String {
        guard let m = minutes else {
            return fallbackKey.replacingOccurrences(of: "_", with: " ").capitalized
        }
        switch m {
        case 60: return "Hourly"
        case 300: return "5-hour"
        case 1440: return "Daily"
        case 10080: return "Weekly"
        case 43200, 43800, 44640: return "Monthly"
        default:
            if m % 1440 == 0 { return "\(m / 1440)-day" }
            if m % 60 == 0 { return "\(m / 60)-hour" }
            return "\(m)-minute"
        }
    }

    /// A compact label for the menu bar.
    public static func shortName(minutes: Int?, fallbackKey: String) -> String {
        guard let m = minutes else { return fallbackKey.replacingOccurrences(of: "_", with: " ").capitalized }
        switch m {
        case 10080: return "Week"
        case 1440: return "Day"
        case 43200, 43800, 44640: return "Month"
        default:
            if m % 1440 == 0 { return "\(m / 1440)d" }
            if m % 60 == 0 { return "\(m / 60)h" }
            return "\(m)m"
        }
    }

    /// Windows of a day or less are treated as short, because users react to them differently from weekly limits.
    public static func isShort(minutes: Int?) -> Bool { (minutes ?? Int.max) <= 1440 }
}
