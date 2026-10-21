import AppKit
import Foundation
import UsageCore

/// Makes sure that only one copy of the application collects into the database.
///
/// Two copies would read the same files twice and compete for the database. The copy that gets the lock is the
/// collector for as long as it runs. The lock belongs to the process, so macOS releases it when the process exits or
/// crashes, and a stale lock can never keep a later launch out.
public final class SingleInstanceLock {
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// The lock this process holds, so that a restart can hand it to the new copy before quitting.
    nonisolated(unsafe) public static var held: SingleInstanceLock?

    deinit { release() }

    /// Takes the lock, or returns nil when another process holds it.
    public static func acquire(at url: URL = QuotaPaths.applicationSupport.appendingPathComponent("app.lock")) -> SingleInstanceLock? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        // A lock file that cannot be opened is no reason to refuse to start. The database itself stays safe.
        guard fd >= 0 else { return SingleInstanceLock(descriptor: -1) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return SingleInstanceLock(descriptor: fd)
    }

    /// Takes the lock, trying again for up to `seconds` while another process holds it. A copy that a restart started
    /// uses this, because the copy it replaces may still be letting go of the lock.
    public static func acquire(retryingFor seconds: TimeInterval) -> SingleInstanceLock? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let lock = acquire() { return lock }
            if Date() >= deadline { return nil }
            usleep(100_000)
        }
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    /// Brings the copy that is already running to the front, so that opening the app a second time does something
    /// visible.
    @MainActor
    public static func activateRunningCopy() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me }?
            .activate()
    }
}
