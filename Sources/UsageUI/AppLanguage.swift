import AppKit
import Foundation

/// The language of the interface. By default the app follows the system; a user can pin it to one of the languages it
/// ships in.
///
/// The choice is the app's own `AppleLanguages` preference, the same one that System Settings › Language & Region ›
/// Applications writes. macOS reads it once, when the app starts, so a change takes effect after a restart: switching
/// in place would leave the text that is already on screen, and every string built in code, in the old language.
public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", turkish = "tr"
    public var id: String { rawValue }

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

    /// The argument that marks a copy started by `relaunch(model:)`.
    static let relaunchArgument = "--relaunched"

    /// True in a copy that `relaunch(model:)` started.
    public static var isRelaunch: Bool { CommandLine.arguments.contains(relaunchArgument) }

    /// Quits and opens the app again, as Apple recommends: ask Launch Services for a new instance of the app, then
    /// quit. A helper process started from here would not do, because it belongs to this app and is ended with it.
    ///
    /// The order matters because only one copy may collect. This copy first stops collecting and lets go of the
    /// single-instance lock, and only then starts the new copy, which takes the lock at once. If the new copy had to
    /// wait for this one to quit instead, it would stall its own launch, and this copy, waiting for that launch to
    /// finish before quitting, would never quit: the new copy would give up and leave.
    @MainActor
    static func relaunch(model: AppModel) {
        Task { @MainActor in
            await model.shutdown()
            SingleInstanceLock.held?.release()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            configuration.arguments = [relaunchArgument]
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error {
                        // This copy no longer collects, so it cannot carry on. It says why and quits.
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Tokenwatch could not restart")
                        alert.informativeText = String(localized: "Open Tokenwatch again to use the new language. (\(error.localizedDescription))")
                        alert.runModal()
                    }
                    NSApplication.shared.terminate(nil)
                }
            }
            // Quits even if Launch Services never answers, so the user is not left with a copy that does not collect.
            try? await Task.sleep(for: .seconds(10))
            NSApplication.shared.terminate(nil)
        }
    }
}
