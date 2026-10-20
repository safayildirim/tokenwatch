import SwiftUI
import AppKit
import UsageCore

/// Renders the app's own windows to PNG files. This is used to check the real interface against real
/// data without needing screen-recording permission, because the app draws its own views.
@MainActor
public enum SnapshotRenderer {
    public static func run(model: AppModel, directory: URL, dark: Bool = false) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = dark ? "-dark" : ""
        model.uiVisibilityOverride = true
        model.requestRefresh()
        // Let the first load finish.
        try? await Task.sleep(for: .seconds(4))

        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for section in DashboardSection.allCases {
            model.selection = section
            model.openSessionID = nil
            await snapshot(DashboardView().environment(model), size: CGSize(width: 1240, height: 820), appearance: appearance,
                           to: directory.appendingPathComponent("dashboard-\(section.rawValue)\(suffix).png"))
        }
        if let biggest = model.recentSessions.max(by: { $0.requests < $1.requests }) {
            model.selection = .sessions
            model.openSessionID = biggest.id
            await snapshot(DashboardView().environment(model), size: CGSize(width: 1240, height: 1500), appearance: appearance, wait: 3.5,
                           to: directory.appendingPathComponent("session-detail\(suffix).png"))
            model.openSessionID = nil
        }
        // The popover is drawn without a window. A window of this size made AppKit loop in its constraint pass when
        // the popover was hosted offscreen, and the popover's content is plain enough to draw directly.
        renderDirectly(MenuBarContentView().environment(model).background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 380, height: 860), dark: dark,
                       to: directory.appendingPathComponent("menubar-popover\(suffix).png"))
    }

    private static func renderDirectly<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height, alignment: .top).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private static func snapshot<V: View>(_ view: V, size: CGSize, appearance: NSAppearance?, wait: Double = 2.5, to url: URL) async {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.setContentSize(size)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(wait))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        window.orderOut(nil)
        window.contentView = nil
    }
}
