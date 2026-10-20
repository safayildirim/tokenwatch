import Foundation
import CoreServices

/// This is a change notification from the file system.
public enum WatchEvent: Sendable {
    /// Files or directories under a watched root changed.
    case paths([String])
    /// The kernel or FSEvents could not guarantee a complete event history, so the root must be
    /// rescanned. This is how missed events are recovered.
    case rescan(root: String)
}

/// Delivers file system events for a set of directories using FSEvents.
///
/// FSEvents is kernel driven, so an idle watcher costs no CPU wake-ups. Events are coalesced by the
/// system over a short latency window before they are delivered.
public final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "usage-monitor.fsevents", qos: .utility)
    private let continuation: AsyncStream<WatchEvent>.Continuation
    public let events: AsyncStream<WatchEvent>
    private let roots: [String]

    /// - Parameter roots: Directories to watch. A directory that does not exist yet is represented
    ///   by its nearest existing ancestor, so creation of the directory is still noticed.
    public init(roots: [URL], latency: TimeInterval = 0.5) {
        var cont: AsyncStream<WatchEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        self.roots = roots.map { Self.nearestExistingAncestor($0).path }
        self.latency = latency
    }

    private let latency: TimeInterval

    private static func nearestExistingAncestor(_ url: URL) -> URL {
        var u = CanonicalPath.resolve(url)
        let fm = FileManager.default
        while !fm.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        return u
    }

    public func start() {
        guard stream == nil, !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            var changed: [String] = []
            for i in 0..<count {
                let flag = eventFlags[i]
                let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                                                   | kFSEventStreamEventFlagUserDropped
                                                   | kFSEventStreamEventFlagKernelDropped
                                                   | kFSEventStreamEventFlagRootChanged)
                if flag & lost != 0 {
                    watcher.continuation.yield(.rescan(root: paths[i]))
                } else {
                    changed.append(paths[i])
                }
            }
            if !changed.isEmpty { watcher.continuation.yield(.paths(changed)) }
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    public func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        continuation.finish()
    }

    deinit { stop() }
}
