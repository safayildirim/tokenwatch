import Foundation
import UserNotifications
import UsageCore

/// Whether macOS lets this application show notifications.
public enum NotificationPermission: Equatable, Sendable {
    /// The user has not been asked yet.
    case notDetermined
    case allowed
    /// The user turned notifications off for this application in System Settings.
    case denied
    /// This process cannot show notifications at all, for example because it is not running as an application bundle.
    case unavailable

    public var description: String {
        switch self {
        case .notDetermined: "Not asked yet"
        case .allowed: "Allowed"
        case .denied: "Turned off in System Settings > Notifications"
        case .unavailable: "Not available in this process"
        }
    }
}

/// What happened to a group of notifications.
public struct NotificationReport: Equatable, Sendable {
    public var delivered = 0
    /// Why the rest was not shown, in words that tell the user what to do.
    public var problem: String?
}

/// The part of the macOS notification center that the application uses, so that the permission and failure paths can be
/// exercised without a real notification center.
public protocol NotificationSink: Sendable {
    func permission() async -> NotificationPermission
    func requestAuthorization() async throws -> Bool
    func add(identifier: String, title: String, body: String, thread: String) async throws
}

/// The real notification center.
public struct SystemNotificationSink: NotificationSink {
    public init() {}

    /// Notifications need an application bundle. A bare command line process has none, and asking the notification
    /// center for one there would crash.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    public func permission() async -> NotificationPermission {
        guard isAvailable else { return .unavailable }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .allowed
        @unknown default: return .notDetermined
        }
    }

    public func requestAuthorization() async throws -> Bool {
        guard isAvailable else { return false }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func add(identifier: String, title: String, body: String, thread: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

/// Shows notifications, and says plainly when it cannot.
///
/// An alert that macOS refuses to show is not an alert the user will ever see, so every refusal is reported instead of
/// being dropped. The user is asked for permission once, when it is first needed.
public struct NotificationService: Sendable {
    let sink: any NotificationSink

    public init(sink: any NotificationSink = SystemNotificationSink()) { self.sink = sink }

    public func permission() async -> NotificationPermission { await sink.permission() }

    /// Asks for permission if it has not been asked for, and returns the answer.
    @discardableResult
    public func requestPermission() async -> NotificationPermission {
        if await sink.permission() == .notDetermined { _ = try? await sink.requestAuthorization() }
        return await sink.permission()
    }

    /// Shows the notifications, asking for permission first if that is needed.
    public func deliver(_ notes: [AlertNotification]) async -> NotificationReport {
        var report = NotificationReport()
        guard !notes.isEmpty else { return report }
        switch await requestPermission() {
        case .allowed: break
        case .denied:
            report.problem = "Notifications are turned off for this app. Turn them on in System Settings > Notifications."
            return report
        case .notDetermined:
            report.problem = "macOS has not given this app permission to show notifications."
            return report
        case .unavailable:
            report.problem = "Notifications can only be shown by the installed app."
            return report
        }
        for note in notes {
            do {
                try await sink.add(identifier: note.key, title: note.title, body: note.body, thread: note.kind.rawValue)
                report.delivered += 1
            } catch {
                report.problem = "macOS refused a notification: \(error.localizedDescription)"
            }
        }
        return report
    }

    /// A notification that has nothing to do with any quota, to check that delivery works.
    public func sendTest() async -> NotificationReport {
        await deliver([AlertNotification(key: "test-\(UUID().uuidString)", kind: .threshold, title: "Tokenwatch",
                                         body: "This is a test. Notifications are working.")])
    }
}
