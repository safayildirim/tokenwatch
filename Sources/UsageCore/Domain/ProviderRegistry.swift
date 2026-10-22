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

/// A subscription plan that a provider sells.
///
/// Plan definitions are registry data, never conditions in shared services. A provider that has no
/// subscription plans simply supplies none; its quota pools still work as before.
///
/// `nominalMultipliers` are the provider's *advertised* capacity relative to that provider's
/// baseline plan, keyed by window length in minutes. They are reference values for charts and are
/// never treated as measurements. A window with no entry is unknown; it is not inferred from
/// another window. For example, a four-times larger five-hour allowance does not imply anything
/// about the weekly allowance.
public struct SubscriptionPlanDefinition: Sendable, Equatable, Identifiable {
    public var key: String
    public var provider: ProviderID
    public var name: String
    /// The provider's published monthly list price in micro-USD, kept as a reference value.
    public var monthlyPriceMicros: Int64
    public var currency: String
    /// When the reference price was read, as an ISO 8601 date.
    public var priceAsOf: String?
    public var nominalMultipliers: [Int: Double]
    public var note: String

    public var id: String { provider.rawValue + "/" + key }

    public init(key: String, provider: ProviderID, name: String, monthlyPriceMicros: Int64, currency: String = "USD",
                priceAsOf: String? = nil, nominalMultipliers: [Int: Double] = [:], note: String = "") {
        self.key = key
        self.provider = provider
        self.name = name
        self.monthlyPriceMicros = monthlyPriceMicros
        self.currency = currency
        self.priceAsOf = priceAsOf
        self.nominalMultipliers = nominalMultipliers
        self.note = note
    }

    public func nominalMultiplier(minutes: Int?) -> Double? {
        guard let minutes else { return nil }
        return nominalMultipliers[minutes]
    }
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
    public var plans: [SubscriptionPlanDefinition]

    public init(providers: [ProviderDefinition] = [], products: [ProductDefinition] = [], surfaces: [SurfaceDefinition] = [],
                pools: [QuotaPoolDefinition] = [], sources: [TelemetrySourceDefinition] = [],
                plans: [SubscriptionPlanDefinition] = []) {
        self.providers = providers
        self.products = products
        self.surfaces = surfaces
        self.pools = pools
        self.sources = sources
        self.plans = plans
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
            sources: merged(sources, other.sources) { $0.id },
            plans: merged(plans, other.plans) { $0.id })
    }

    public func provider(_ id: ProviderID) -> ProviderDefinition? { providers.first { $0.id == id } }
    public func plan(provider: ProviderID, key: String) -> SubscriptionPlanDefinition? {
        plans.first { $0.provider == provider && $0.key == key }
    }
    public func plans(of provider: ProviderID) -> [SubscriptionPlanDefinition] { plans.filter { $0.provider == provider } }
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

    /// A window that is one of several limits of the same length, such as a weekly limit for one model.
    ///
    /// A duration alone cannot identify such a window: two weekly limits have the same length and different
    /// allowances. The key carries both a stable identity and the provider's display label, so the display label
    /// survives a database round trip without a new column. Neither part is a credential.
    public static func scopedKey(minutes: Int, identity: String, label: String) -> String {
        "scoped:\(minutes):\(base64URL(identity)):\(base64URL(label))"
    }

    /// The provider's label for a scoped window, or nil for an ordinary one.
    public static func scopedLabel(fallbackKey: String) -> String? {
        let parts = fallbackKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "scoped", Int(parts[1]) != nil,
              base64URLDecode(String(parts[2])) != nil,
              let data = base64URLDecode(String(parts[3])),
              let label = String(data: data, encoding: .utf8), !label.isEmpty else { return nil }
        return label
    }

    public static func displayName(minutes: Int?, fallbackKey: String) -> String {
        if let label = scopedLabel(fallbackKey: fallbackKey) {
            return String(localized: "\(label) weekly")
        }
        guard let m = minutes else {
            return fallbackKey.replacingOccurrences(of: "_", with: " ").capitalized
        }
        switch m {
        case 60: return String(localized: "Hourly")
        case 300: return String(localized: "5-hour")
        case 1440: return String(localized: "Daily")
        case 10080: return String(localized: "Weekly")
        case 43200, 43800, 44640: return String(localized: "Monthly")
        default:
            if m % 1440 == 0 { return String(localized: "\(m / 1440)-day") }
            if m % 60 == 0 { return String(localized: "\(m / 60)-hour") }
            return String(localized: "\(m)-minute")
        }
    }

    /// A compact label for the menu bar.
    public static func shortName(minutes: Int?, fallbackKey: String) -> String {
        if let label = scopedLabel(fallbackKey: fallbackKey) {
            return label.count <= 18 ? label : String(label.prefix(17)) + "…"
        }
        guard let m = minutes else { return fallbackKey.replacingOccurrences(of: "_", with: " ").capitalized }
        switch m {
        case 10080: return String(localized: "Week")
        case 1440: return String(localized: "Day")
        case 43200, 43800, 44640: return String(localized: "Month")
        default:
            if m % 1440 == 0 { return String(localized: "\(m / 1440)d") }
            if m % 60 == 0 { return String(localized: "\(m / 60)h") }
            return String(localized: "\(m)m")
        }
    }

    /// Windows of a day or less are treated as short, because users react to them differently from weekly limits.
    public static func isShort(minutes: Int?) -> Bool { (minutes ?? Int.max) <= 1440 }

    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
