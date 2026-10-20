import SwiftUI
import AppKit
import UsageUI

@main
struct TokenwatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var model: AppModel?

    /// Held for as long as the process runs. Releasing it would let a second copy start collecting.
    private static var instanceLock: SingleInstanceLock?

    init() {
        if CommandLineActions.handle() { exit(0) }
        // Opening the app a second time brings the running copy forward instead of starting a second collector.
        guard let lock = SingleInstanceLock.acquire() else {
            SingleInstanceLock.activateRunningCopy()
            exit(0)
        }
        Self.instanceLock = lock
        _model = State(initialValue: try? AppModel.bootstrap())
    }

    var body: some Scene {
        MenuBarExtra {
            if let model {
                MenuBarContentView().environment(model)
            } else {
                Text("The usage database could not be opened.").padding()
            }
        } label: {
            if let model { MenuBarLabel().environment(model) } else { Image(systemName: "exclamationmark.triangle") }
        }
        .menuBarExtraStyle(.window)

        Window("Tokenwatch", id: "dashboard") {
            if let model {
                DashboardView().environment(model).preferredColorScheme(model.settings.appearance.colorScheme)
            }
        }
        .defaultSize(width: 1240, height: 800)

        Window("Settings", id: "settings") {
            if let model { SettingsView().environment(model) }
        }
        .windowResizability(.contentSize)
        .commands {
            // Gives the Settings window its usual place in the app menu and its standard shortcut.
            CommandGroup(replacing: .appSettings) { SettingsCommand() }
        }
    }
}

/// The "Settings…" menu item.
struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") { openWindow(id: "settings") }.keyboardShortcut(",")
    }
}
