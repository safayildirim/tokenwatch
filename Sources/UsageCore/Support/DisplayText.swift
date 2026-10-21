import Foundation

/// Looks up the translation of English text that is kept as data, such as the names and notes in the provider
/// registry. Those values are also written to the database and to exports, so they stay in English at the source and
/// are translated only where they are shown. Text with no translation, and every lookup in the command line tool and
/// the tests, returns the English text unchanged.
public enum DisplayText {
    public static func localized(_ english: String) -> String {
        english.isEmpty ? english : String(localized: String.LocalizationValue(english))
    }
}
