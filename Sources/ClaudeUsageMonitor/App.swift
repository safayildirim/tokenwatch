import SwiftUI
import AppKit
import UsageUI

@main
struct ClaudeUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var model: AppModel? = try? AppModel.bootstrap()
    @State private var startupError: String?

    init() {
        if CommandLineActions.handle() { exit(0) }
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

        Window("AI Usage", id: "dashboard") {
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
