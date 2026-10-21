import AppKit
import Foundation

/// The language of the interface. By default the app follows the system; a user can pin it to one of the languages it
/// ships in.
///
/// The choice is the app's own `AppleLanguages` preference, the same one that System Settings › Language & Region ›
/// Applications writes. macOS reads it once, when the app starts, so a change takes effect after a restart: switching
/// in place would leave the text that is already on screen, and every string built in code, in the old language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", turkish = "tr"
    var id: String { rawValue }

    private static let key = "AppleLanguages"

    /// The languages are named in their own language, so that someone who cannot read the current one can find theirs.
    var label: String {
        switch self {
        case .system: String(localized: "System Default")
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }

    /// The choice that is saved now, which is the one the next launch will use.
    static var saved: AppLanguage {
        guard let first = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String])?.first
        else { return .system }
        return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
    }

    /// The language the system would pick for the app: the first of the user's preferred languages that the app
    /// ships in. This reads the global list, because the app's own list is the choice made here.
    static var systemChoice: AppLanguage {
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        for language in global {
            if let match = allCases.first(where: { $0 != .system && language.hasPrefix($0.rawValue) }) { return match }
        }
        return .english
    }

    /// The language a launch with this choice shows.
    var resolved: AppLanguage { self == .system ? Self.systemChoice : self }

    /// The language the running app is showing.
    static var current: AppLanguage {
        let shown = Bundle.main.preferredLocalizations.first ?? "en"
        return allCases.first { $0 != .system && shown.hasPrefix($0.rawValue) } ?? .english
    }

    /// Saves the choice for the next launch.
    func save() {
        if self == .system { UserDefaults.standard.removeObject(forKey: Self.key) }
        else { UserDefaults.standard.set([rawValue], forKey: Self.key) }
    }

    /// Quits and opens the app again. The new copy is started only once this one has exited, because a copy that
    /// starts while another holds the collector lock hands over to it and quits.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}
