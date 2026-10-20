import Foundation

/// Normalizes the model identifiers that appear in session logs.
///
/// Logs contain forms such as `claude-opus-5-5`, `claude-opus-5-5[1m]` (a context-window variant),
/// `claude-haiku-4-5-20251001` (a dated snapshot) or provider-prefixed names. Prices, charts and
/// filters all work on the canonical form, while the raw identifier is preserved on every request.
public enum ModelCatalog {
    public struct Description: Sendable, Equatable {
        public var canonical: String
        public var family: String
        public var displayName: String
    }

    public static func describe(_ raw: String) -> Description {
        var s = raw.lowercased()
        if let bracket = s.firstIndex(of: "[") { s = String(s[..<bracket]) }
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }
        for prefix in ["us.anthropic.", "eu.anthropic.", "global.anthropic.", "anthropic."] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        // Strip a trailing snapshot date such as -20251001 and a Bedrock style version suffix.
        if let range = s.range(of: #"-\d{8}(-v\d+:\d+)?$"#, options: .regularExpression) { s.removeSubrange(range) }

        let families = ["opus", "sonnet", "haiku", "fable", "mythos"]
        let family = families.first { s.contains($0) } ?? "other"

        var display = raw
        if family != "other" {
            let parts = s.split(separator: "-").map(String.init)
            if let idx = parts.firstIndex(of: family) {
                let version = parts[(idx + 1)...].prefix { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
                let leadingVersion = parts[..<idx].filter { $0 != "claude" }.joined(separator: ".")
                let ver = version.isEmpty ? leadingVersion : version
                display = family.capitalized + (ver.isEmpty ? "" : " " + ver)
            }
        }
        return Description(canonical: s, family: family, displayName: display)
    }
}
