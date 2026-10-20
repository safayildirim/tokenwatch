import Foundation

/// What a synchronization pass found out about a file.
public enum SyncOutcome: String, Sendable {
    /// The file has not changed since the last checkpoint.
    case unchanged
    /// New complete lines were appended and processed.
    case appended
    /// The file was replaced, truncated or rewritten, so it was read again from the start. This is
    /// safe because every observation is idempotent.
    case rebuilt
    /// The file no longer exists. Previously collected data is kept.
    case missing
}

public struct SyncResult: Sendable {
    public var outcome: SyncOutcome
    public var bytesRead: Int64 = 0
    public var lines = 0
    public var malformedLines = 0
    public var requestsTouched = 0
    public var reason: String?
}

/// A saved synchronization checkpoint, as read back from `source_file`.
struct FileCheckpoint {
    var id: Int64
    var device: Int64
    var inode: Int64
    var size: Int64
    var mtimeMs: Int64
    var consumedOffset: Int64
    var headLen: Int
    var headHash: String?
    var status: String
}

/// Reads new complete lines from a log file and stores the resulting observations.
///
/// The synchronizer is responsible for the hard parts of incremental ingestion.
/// - It resumes from a durable byte offset that always sits on a line boundary, so a line that is
///   still being written is picked up on the next pass instead of being parsed half-finished.
/// - It detects replacement (different inode), truncation (smaller than the checkpoint) and in-place
///   rewrites (changed leading bytes), and re-reads the file from the start in those cases.
/// - It streams through the file in fixed-size chunks, so memory use is bounded no matter how
///   large the file is.
/// - It reads Zstandard-compressed files (`.zst`) through a streaming decoder. A compressed file is
///   immutable, so it is never resumed: whenever it is new or has changed, it is decoded from its start.
///   For such files the checkpoint offset counts decompressed bytes.
public struct FileSynchronizer: Sendable {
    public static let chunkBytes = 4 << 20
    /// A single line larger than this is skipped instead of buffered.
    public static let maxLineBytes = 128 << 20
    /// Observations are committed after this many bytes so that very large files make steady,
    /// durable progress.
    public static let commitBytes = 24 << 20
    static let headBytes = 4096

    let db: UsageDatabase
    let retentionFloorMs: @Sendable () -> Int64?

    public init(db: UsageDatabase, retentionFloorMs: @escaping @Sendable () -> Int64? = { nil }) {
        self.db = db
        self.retentionFloorMs = retentionFloorMs
    }

    // MARK: Checkpoint access

    func loadCheckpoint(sourceID: TelemetrySourceID, path: String) throws -> FileCheckpoint? {
        try db.read { c in
            try c.queryOne("""
                SELECT id, COALESCE(device, 0), COALESCE(inode, 0), size, mtime_ms, consumed_offset,
                       head_len, head_hash, status
                FROM source_file WHERE source_id = ? AND path = ?
                """, [.text(sourceID.rawValue), .text(path)]) { r in
                FileCheckpoint(id: r.int(0), device: r.int(1), inode: r.int(2), size: r.int(3), mtimeMs: r.int(4),
                               consumedOffset: r.int(5), headLen: Int(r.int(6)), headHash: r.textOrNil(7),
                               status: r.text(8))
            }
        }
    }

    /// All checkpoints of a source keyed by path, used by reconciliation to decide cheaply which
    /// files need attention.
    func loadAllCheckpoints(sourceID: TelemetrySourceID) throws -> [String: FileCheckpoint] {
        try db.read { c in
            let rows = try c.query("""
                SELECT path, id, COALESCE(device, 0), COALESCE(inode, 0), size, mtime_ms, consumed_offset,
                       head_len, head_hash, status
                FROM source_file WHERE source_id = ?
                """, [.text(sourceID.rawValue)]) { r in
                (r.text(0), FileCheckpoint(id: r.int(1), device: r.int(2), inode: r.int(3), size: r.int(4),
                                           mtimeMs: r.int(5), consumedOffset: r.int(6), headLen: Int(r.int(7)),
                                           headHash: r.textOrNil(8), status: r.text(9)))
            }
            return Dictionary(rows, uniquingKeysWith: { a, _ in a })
        }
    }

    private func ensureCheckpointRow(sourceID: TelemetrySourceID, path: String) throws -> Int64 {
        try db.write { c in
            try c.run("INSERT OR IGNORE INTO source_file(source_id, path) VALUES(?, ?)", [.text(sourceID.rawValue), .text(path)])
            return try c.scalarInt("SELECT id FROM source_file WHERE source_id = ? AND path = ?",
                                   [.text(sourceID.rawValue), .text(path)])!
        }
    }

    private func setStatus(sourceID: TelemetrySourceID, path: String, status: String, error: String?) {
        _ = try? db.write { c in
            try c.run("UPDATE source_file SET status = ?, last_error = ?, last_synced_at = ? WHERE source_id = ? AND path = ?",
                      [.text(status), .optional(error), .int(Clock.nowMs()), .text(sourceID.rawValue), .text(path)])
        }
    }

    /// Records that a previously known file no longer exists. Its data stays in the database.
    func markMissing(sourceID: TelemetrySourceID, path: String) {
        setStatus(sourceID: sourceID, path: path, status: "missing", error: nil)
    }

    // MARK: Synchronization

    /// Brings the database up to date with the current contents of `file`.
    public func sync(file: SourceFileRef, adapter: any SourceAdapter,
                     progress: (@Sendable (Int64) -> Void)? = nil) throws -> SyncResult {
        var st = stat()
        if stat(file.path, &st) != 0 {
            if errno == ENOENT {
                setStatus(sourceID: file.sourceID, path: file.path, status: "missing", error: nil)
                return SyncResult(outcome: .missing)
            }
            let message = String(cString: strerror(errno))
            setStatus(sourceID: file.sourceID, path: file.path, status: "error", error: message)
            throw FileAccessError(path: file.path, message: message, code: errno)
        }
        let size = Int64(st.st_size)
        let mtimeMs = Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
        let device = Int64(st.st_dev)
        let inode = Int64(st.st_ino)

        let existing = try loadCheckpoint(sourceID: file.sourceID, path: file.path)
        let fileID = try existing?.id ?? ensureCheckpointRow(sourceID: file.sourceID, path: file.path)

        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else {
            let message = String(cString: strerror(errno))
            setStatus(sourceID: file.sourceID, path: file.path, status: "error", error: message)
            throw FileAccessError(path: file.path, message: message, code: errno)
        }
        defer { close(fd) }

        // Read the leading bytes once, for both validating the old checkpoint and storing the new one.
        let headLen = Int(min(Int64(Self.headBytes), size))
        var head = [UInt8](repeating: 0, count: headLen)
        if headLen > 0 {
            let got = head.withUnsafeMutableBytes { pread(fd, $0.baseAddress, headLen, 0) }
            if got != headLen {
                throw FileAccessError(path: file.path, message: "short read of file header", code: EIO)
            }
        }
        let newHeadHash = FNV.hash(head, count: headLen)

        let compressed = file.isCompressed
        // A compressed file cannot be resumed, and neither can a file whose adapter needs to see it from the top.
        let readsWholeFile = compressed || !adapter.resumesFromCheckpoint
        var startOffset: Int64 = 0
        var reason: String?
        if let cp = existing {
            // A file that could not be decoded stays marked as damaged until it changes, so that it is
            // not decoded again on every pass.
            let settled = cp.status == "ok" || (compressed && cp.status == "damaged")
            if cp.status == "pending" && cp.consumedOffset == 0 {
                startOffset = 0
            } else if cp.inode != inode || cp.device != device {
                reason = "replaced"
            } else if !compressed && size < cp.consumedOffset {
                reason = "truncated"
            } else if cp.headLen > 0, cp.headHash != FNV.hash(head, count: min(cp.headLen, headLen)) || cp.headLen > headLen {
                reason = "rewritten"
            } else if size == cp.size && mtimeMs == cp.mtimeMs && settled {
                return SyncResult(outcome: .unchanged)
            } else if readsWholeFile {
                startOffset = 0
            } else {
                startOffset = cp.consumedOffset
            }
        }
        let rebuilt = reason != nil

        let parser = adapter.makeParser(for: file)
        var result = SyncResult(outcome: rebuilt ? .rebuilt : .appended, reason: reason)

        var capacity = Self.chunkBytes * 2
        var buf = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buf.deallocate() }
        var fill = 0
        var bufOffset = startOffset                // Absolute file offset of buf[0].
        var committedOffset = startOffset          // Offset covered by the last commit.
        var discardingOversizedLine = false
        var batch = NormalizedBatch()
        var linesSinceCommit = 0
        var malformedSinceCommit = 0

        if lseek(fd, off_t(compressed ? 0 : startOffset), SEEK_SET) < 0 {
            throw FileAccessError(path: file.path, message: String(cString: strerror(errno)), code: errno)
        }
        let zstd: ZstdFileReader? = try compressed ? ZstdFileReader(fd: fd) : nil
        // The next chunk of file content, decoded when the file is compressed.
        func readChunk(into dst: UnsafeMutablePointer<UInt8>) throws -> Int {
            if let zstd { return try zstd.read(into: dst, capacity: Self.chunkBytes) }
            while true {
                let n = read(fd, dst, Self.chunkBytes)
                if n < 0 && errno == EINTR { continue }
                if n < 0 { throw FileAccessError(path: file.path, message: String(cString: strerror(errno)), code: errno) }
                return n
            }
        }

        func commit(final: Bool) throws {
            parser.flush(into: &batch)
            malformedSinceCommit += batch.malformedLineCount + batch.oversizedLineCount
            let update = CheckpointUpdate(
                fileID: fileID, device: device, inode: inode, size: compressed ? size : max(size, bufOffset), mtimeMs: mtimeMs,
                consumedOffset: bufOffset, headLen: headLen, headHash: newHeadHash,
                addedLines: batch.lineCount, addedMalformed: malformedSinceCommit,
                status: "ok", lastError: nil, replacesNotices: readsWholeFile)
            let stats = try IngestWriter.apply(batch: batch, checkpoint: update,
                                               retentionFloorMs: retentionFloorMs(), db: db)
            result.requestsTouched += stats.requestsTouched
            result.lines += batch.lineCount
            result.malformedLines += malformedSinceCommit
            batch = NormalizedBatch()
            malformedSinceCommit = 0
            committedOffset = bufOffset
            linesSinceCommit = 0
        }

        // A file that is read again from its start keeps its counters from the previous read; reset them so that
        // the line count reflects the file as it is now.
        if rebuilt || (readsWholeFile && existing != nil) {
            try db.write { c in try c.run("UPDATE source_file SET line_count = 0, malformed_lines = 0 WHERE id = ?", [.int(fileID)]) }
        }

        while true {
            if fill + Self.chunkBytes > capacity {
                let newCapacity = min(max(capacity * 2, fill + Self.chunkBytes), Self.maxLineBytes + Self.chunkBytes * 2)
                let grown = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
                grown.update(from: buf, count: fill)
                buf.deallocate()
                buf = grown
                capacity = newCapacity
            }
            let n: Int
            do {
                n = try readChunk(into: buf + fill)
            } catch let error as ZstdFileReader.DecodeError {
                // Everything decoded before the damage is valid, so keep it and then report the file.
                try commit(final: true)
                setStatus(sourceID: file.sourceID, path: file.path, status: "damaged", error: error.message)
                throw FileAccessError(path: file.path, message: error.message, code: EILSEQ)
            }
            if n == 0 { break }
            fill += n
            result.bytesRead += Int64(n)

            var lineStart = 0
            while lineStart < fill {
                guard let hit = memchr(buf + lineStart, 0x0A, fill - lineStart) else { break }
                let nl = buf.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                if discardingOversizedLine {
                    discardingOversizedLine = false
                    batch.oversizedLineCount += 1
                } else {
                    var end = nl
                    if end > lineStart, buf[end - 1] == 0x0D { end -= 1 }
                    if end > lineStart {
                        let line = UnsafeBufferPointer(start: buf + lineStart, count: end - lineStart)
                        parser.parse(line: line, offset: bufOffset + Int64(lineStart), into: &batch)
                        linesSinceCommit += 1
                    }
                }
                lineStart = nl + 1
            }
            if lineStart > 0 {
                let remaining = fill - lineStart
                if remaining > 0 { memmove(buf, buf + lineStart, remaining) }
                fill = remaining
                bufOffset += Int64(lineStart)
            }
            // A partial line that keeps growing past the limit is dropped; the rest of it is
            // discarded when its newline finally arrives.
            if fill > Self.maxLineBytes {
                bufOffset += Int64(fill)
                fill = 0
                discardingOversizedLine = true
            }
            progress?(result.bytesRead)
            // A file that is always read from its start has no durable progress to save along the way, and what it
            // reports is only complete once all of it has been read, so it is committed once, at the end.
            if !readsWholeFile, bufOffset - committedOffset >= Int64(Self.commitBytes) { try commit(final: false) }
        }
        try commit(final: true)
        if result.bytesRead == 0 && !rebuilt && existing != nil { result.outcome = .unchanged }
        return result
    }
}

public struct FileAccessError: Error, CustomStringConvertible, Sendable {
    public let path: String
    public let message: String
    public let code: Int32
    public var description: String { "\(path): \(message)" }
    public var isPermissionDenied: Bool { code == EACCES || code == EPERM }
}

/// This is a small, fast, non-cryptographic hash that recognizes a file by its first bytes.
enum FNV {
    static func hash(_ bytes: [UInt8], count: Int) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for i in 0..<min(count, bytes.count) {
            h ^= UInt64(bytes[i])
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}
