import XCTest
@testable import UsageCore
@testable import UsageUI

/// A notification center that answers as the test says.
private final class FakeSink: NotificationSink, @unchecked Sendable {
    private let lock = NSLock()
    private var current: NotificationPermission
    private let grants: Bool
    private let failure: (any Error)?
    private(set) var shown: [String] = []
    private(set) var asked = 0

    init(_ permission: NotificationPermission, grants: Bool = true, failure: (any Error)? = nil) {
        current = permission
        self.grants = grants
        self.failure = failure
    }

    func permission() async -> NotificationPermission { lock.withLock { current } }

    func requestAuthorization() async throws -> Bool {
        lock.withLock {
            asked += 1
            if current == .notDetermined { current = grants ? .allowed : .denied }
            return grants
        }
    }

    func add(identifier: String, title: String, body: String, thread: String) async throws {
        if let failure { throw failure }
        lock.withLock { shown.append(identifier) }
    }
}

private struct Refused: LocalizedError { var errorDescription: String? { "the notification center is full" } }

final class NotificationServiceTests: XCTestCase {
    private let note = AlertNotification(key: "k1", kind: .threshold, title: "t", body: "b")

    func testNotificationsAreShownWhenAllowed() async {
        let sink = FakeSink(.allowed)
        let report = await NotificationService(sink: sink).deliver([note])
        XCTAssertEqual(report.delivered, 1)
        XCTAssertNil(report.problem)
        XCTAssertEqual(sink.shown, ["k1"])
        XCTAssertEqual(sink.asked, 0, "permission that was already given is not asked for again")
    }

    func testPermissionIsAskedForOnceAndTheAnswerDecides() async {
        let granted = FakeSink(.notDetermined, grants: true)
        let a = await NotificationService(sink: granted).deliver([note])
        XCTAssertEqual(a.delivered, 1)
        XCTAssertEqual(granted.asked, 1)

        let refused = FakeSink(.notDetermined, grants: false)
        let b = await NotificationService(sink: refused).deliver([note])
        XCTAssertEqual(b.delivered, 0)
        XCTAssertTrue(b.problem?.contains("System Settings") == true, "the user is told where to turn them on: \(b.problem ?? "")")
        XCTAssertTrue(refused.shown.isEmpty)
    }

    func testDeniedPermissionIsReportedNotSilentlyDropped() async {
        let sink = FakeSink(.denied)
        let report = await NotificationService(sink: sink).deliver([note, note])
        XCTAssertEqual(report.delivered, 0)
        XCTAssertNotNil(report.problem)
        XCTAssertEqual(sink.asked, 0, "a denied permission cannot be changed by asking again")
    }

    func testAProcessWithoutAnAppBundleSaysSo() async {
        let report = await NotificationService(sink: FakeSink(.unavailable)).deliver([note])
        XCTAssertEqual(report.delivered, 0)
        XCTAssertTrue(report.problem?.contains("installed app") == true)
    }

    func testARefusalByTheNotificationCenterIsReported() async {
        let report = await NotificationService(sink: FakeSink(.allowed, failure: Refused())).deliver([note])
        XCTAssertEqual(report.delivered, 0)
        XCTAssertTrue(report.problem?.contains("the notification center is full") == true)
    }

    func testTheTestNotificationHasNothingToDoWithQuota() async {
        let sink = FakeSink(.allowed)
        let report = await NotificationService(sink: sink).sendTest()
        XCTAssertEqual(report.delivered, 1)
        XCTAssertTrue(sink.shown[0].hasPrefix("test-"))
    }

    func testEmptyDeliveryNeverAsksForPermission() async {
        let sink = FakeSink(.notDetermined)
        _ = await NotificationService(sink: sink).deliver([])
        XCTAssertEqual(sink.asked, 0)
    }

    @MainActor
    func testTheModelShowsWhyTheTestFailed() async throws {
        let env = try UIEnv()
        let model = AppModel(db: env.db, adapters: [], bridgeDirectory: env.quotaDir, registryDirectory: env.registryDir,
                             desktopCache: env.root.appendingPathComponent("none.json"), notificationSink: FakeSink(.denied))
        await model.sendTestNotification()
        XCTAssertEqual(model.notificationPermission, .denied)
        XCTAssertNotNil(model.notificationProblem)
        await env.cleanup()
    }
}

final class SingleInstanceTests: XCTestCase {
    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ccu-lock-\(UUID().uuidString)/app.lock")
    }

    func testOnlyOneHolderAtATimeAndTheLockIsFreeAgainAfterRelease() throws {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
        XCTAssertNil(SingleInstanceLock.acquire(at: url), "a second copy cannot take over while the first is running")
        first.release()
        let second = SingleInstanceLock.acquire(at: url)
        XCTAssertNotNil(second, "a lock that was let go can be taken again")
        second?.release()
    }

    func testTheLockIsReleasedWhenTheHolderGoesAway() throws {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var holder: SingleInstanceLock? = SingleInstanceLock.acquire(at: url)
        XCTAssertNotNil(holder)
        holder = nil
        XCTAssertNotNil(SingleInstanceLock.acquire(at: url), "a crashed or exited copy never keeps a later launch out")
    }

    func testAnotherProcessIsKeptOut() throws {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let held = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
        defer { held.release() }
        // The same question asked by a separate process gets the same answer.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import fcntl,sys\nf=open(sys.argv[1],'a')\ntry:\n fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)\n sys.exit(0)\nexcept OSError:\n sys.exit(7)", url.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 7)
    }
}
