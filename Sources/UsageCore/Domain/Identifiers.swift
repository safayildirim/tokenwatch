import Foundation
import CryptoKit

/// A string identifier that is typed, so that a provider id cannot be passed where a product id is expected.
public protocol StringIdentifier: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

public extension StringIdentifier {
    init(stringLiteral value: String) { self.init(rawValue: value) }
    var description: String { rawValue }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// The company or platform that delivers AI capabilities, for example Anthropic or OpenAI.
public struct ProviderID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A product that a provider offers, for example Claude Code, Codex or ChatGPT Work.
public struct ProductID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Where a session ran: a terminal, an IDE, a desktop application.
public struct SurfaceID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// The mechanism through which data is collected, for example a folder of session logs.
public struct TelemetrySourceID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A reference to an account or workspace of a provider, as reported by the telemetry itself.
///
/// The raw identifier is never stored. Only a one-way hash is kept, which is enough to tell accounts apart
/// and to show a short label, and which cannot be used to sign in anywhere. A nil hash means that the
/// source did not say which account the activity belongs to, which is a legitimate, explicit state called
/// the unassigned account.
public struct AccountRef: Hashable, Sendable {
    public var provider: ProviderID
    public var hash: String?

    public init(provider: ProviderID, hash: String?) {
        self.provider = provider
        self.hash = hash
    }

    public static func unassigned(_ provider: ProviderID) -> AccountRef { AccountRef(provider: provider, hash: nil) }

    /// Builds a reference from the identifier found in the telemetry. An empty identifier is unassigned.
    public static func identified(provider: ProviderID, rawIdentifier: String?) -> AccountRef {
        guard let raw = rawIdentifier, !raw.isEmpty else { return .unassigned(provider) }
        return AccountRef(provider: provider, hash: Hashing.shortHash("\(provider.rawValue):\(raw)"))
    }

    public var isUnassigned: Bool { hash == nil }
}

enum Hashing {
    /// A 16-character hexadecimal digest (the first eight bytes of SHA-256), used to name accounts without
    /// keeping their real identifiers.
    static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
