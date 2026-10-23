import XCTest

/// Checks the Turkish table. The app shows the English key whenever a translation is missing, so these tests guard
/// against the mistakes that do reach the screen: a table that does not parse, and a translation whose placeholders
/// no longer match its key, which would print the wrong value or crash the formatter.
final class LocalizationTests: XCTestCase {
    private var localizationDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Localization")
    }

    private func table(_ language: String) throws -> [String: String] {
        let url = localizationDirectory.appendingPathComponent("\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(language) table is not a list of strings")
    }

    /// The placeholders of a format string, in the order of the arguments they consume.
    static func placeholders(_ format: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(@|lld|ld|lf|d|f)|%%")
        var sequential: [String] = []
        var positional: [Int: String] = [:]
        for match in regex.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
            guard match.range(at: 2).location != NSNotFound, let type = Range(match.range(at: 2), in: format).map({ String(format[$0]) }) else { continue }
            if let r = Range(match.range(at: 1), in: format), let position = Int(format[r]) { positional[position] = type }
            else { sequential.append(type) }
        }
        return positional.isEmpty ? sequential : positional.keys.sorted().map { positional[$0]! }
    }

    func testPlaceholderParsing() {
        XCTAssertEqual(Self.placeholders("%@ of %lld at 100%%"), ["@", "lld"])
        XCTAssertEqual(Self.placeholders("%2$lld içinde %1$@"), ["@", "lld"])
    }

    func testTheTablesParse() throws {
        XCTAssertTrue(try table("en").isEmpty, "English text is the key, so the English table stays empty")
        XCTAssertGreaterThan(try table("tr").count, 300)
    }

    func testEveryTranslationKeepsItsPlaceholders() throws {
        var problems: [String] = []
        for (key, value) in try table("tr") {
            if value.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("empty: \(key)") }
            if Self.placeholders(key) != Self.placeholders(value) { problems.append("\(key) → \(value)") }
        }
        XCTAssertEqual(problems.sorted(), [])
    }

    /// Strings that explain a limitation to the person must not silently fall back to English. This lists the ones whose absence
    /// would leave the most important explanations untranslated.
    func testTheExplanationsOfLimitationsAreTranslated() throws {
        let turkish = try table("tr")
        let keys = [
            "Not enough reliable quota history to forecast usage.",
            "Which sessions were this account's?",
            "Reported by the provider",
            "Estimated exhaustion",
            "Local usage cannot currently be reliably assigned to this subscription account: the sessions name no account. You can tell Tokenwatch which account used this Mac during a period.",
            "Only %lld reset has been announced for this window so far. A repeating schedule needs at least two, and until then no earlier or later cycle is calculated.",
            "Your next %@ reset is expected %@. The schedule (%@) is based on %lld provider-announced reset times and %lld confirmed reset, not on two confirmed reset events. A reset counts as confirmed only once a new window is seen after it.",
            "The longest stretch in which a rise could have gone unseen: %@.",
            "Tokens not tied to this account (stacked)",
        ]
        for key in keys { XCTAssertNotNil(turkish[key], "missing Turkish text: \(key)") }
    }
}
