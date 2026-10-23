import Darwin
import Foundation

/// Delivers a notification when one file changes, without watching its parent directory.
///
/// FSEvents on a home directory would deliver every unrelated write on the Mac to the quota coordinator. A dispatch
/// source on an open file descriptor watches only the file's own inode. When an atomic replacement renames a new file
/// over the old one, the descriptor sees `.rename`/`.delete`; the watcher closes it and opens the path again so the
/// next write is seen. A missing file is not polled here; the coordinator's slow safety refresh arms the watcher when
/// the file appears.
final class FileEventWatcher: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "tokenwatch.file-events", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let continuation: AsyncStream<Void>.Continuation
    let events: AsyncStream<Void>
    private var source: DispatchSourceFileSystemObject?
    private var stopped = false
    private var rearmScheduled = false

    init(url: URL) {
        self.url = url
        var cont: AsyncStream<Void>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont
        queue.setSpecific(key: queueKey, value: ())
        queue.sync { arm() }
    }

    func stop() {
        let work = {
            self.stopped = true
            self.closeSource()
            self.continuation.finish()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    /// Whether the descriptor is currently open. A file that was deleted has no descriptor until it is recreated.
    var isWatching: Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return source != nil }
        return queue.sync { source != nil }
    }

    deinit { stop() }

    private func arm() {
        guard !stopped, source == nil else { return }
        // O_NONBLOCK prevents a file replaced by a FIFO from blocking this queue during open. Only regular files are
        // watched; the cache reader independently rejects anything else.
        let fd = url.path.withCString { open($0, O_EVTONLY | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { return }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            _ = close(fd)
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .link, .revoke],
                                                          queue: queue)
        source = s
        s.setEventHandler { [weak self] in
            guard let self, let event = self.source?.data else { return }
            self.continuation.yield(())
            if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
                // An atomic write replaces the inode. Watch the path again so the replacement's next write is seen.
                self.closeSource()
                self.scheduleRearm()
            }
        }
        // The cancel handler owns the descriptor, not `self`: a watcher can be deallocated on its own queue, and the
        // handler must still close the descriptor exactly once.
        s.setCancelHandler { _ = close(fd) }
        s.resume()
    }

    private func scheduleRearm() {
        guard !rearmScheduled, !stopped else { return }
        rearmScheduled = true
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.rearmScheduled = false
            self.arm()
        }
    }

    private func closeSource() {
        guard let s = source else { return }
        source = nil
        s.cancel()
    }
}
