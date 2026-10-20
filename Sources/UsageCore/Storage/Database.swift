import Foundation
import SQLite3

/// What happened when the database was opened. The app surfaces `recoveredFromCorruption` in its
/// diagnostics, and starts a full re-import because the request tables are rebuildable from the
/// original session logs.
public struct DatabaseOpenReport: Sendable {
    public var recoveredFromCorruption = false
    public var quarantinedTo: URL?
    public var integrityCheckRan = false
    public var migratedFrom = 0
    public var migratedTo = 0
}

/// This class is the local SQLite database.
///
/// The database uses write-ahead logging, so readers never block the writer and the writer never
/// blocks readers. All mutations go through one serialized writer connection, and queries are
/// served by a small pool of read-only connections.
public final class UsageDatabase: @unchecked Sendable {
    public let url: URL
    public private(set) var openReport = DatabaseOpenReport()

    private let writer: SQLiteConnection
    private let writerLock = NSLock()

    private var idleReaders: [SQLiteConnection] = []
    private let readerCondition = NSCondition()
    private var readersCreated = 0
    private let maxReaders = 4

    /// Opens (creating if necessary) the database at `url`.
    ///
    /// If the previous run did not shut down cleanly, a quick integrity check runs first. A
    /// database that is damaged beyond use is moved aside and replaced with an empty one.
    public static func open(at url: URL) throws -> UsageDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var report = DatabaseOpenReport()
        do {
            return try attemptOpen(at: url, report: &report)
        } catch let error as SQLiteError where error.isCorruption {
            let aside = try quarantine(url)
            report = DatabaseOpenReport()
            report.recoveredFromCorruption = true
            report.quarantinedTo = aside
            return try attemptOpen(at: url, report: &report)
        }
    }

    private static func attemptOpen(at url: URL, report: inout DatabaseOpenReport) throws -> UsageDatabase {
        let db = try UsageDatabase(url: url)
        var working = report
        do {
            try db.configureAndMigrate(report: &working)
        } catch let error as SQLiteError where error.isCorruption {
            throw error
        }
        db.openReport = working
        return db
    }

    private static func quarantine(_ url: URL) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".corrupt-\(stamp)")
        let fm = FileManager.default
        try? fm.removeItem(at: aside)
        try fm.moveItem(at: url, to: aside)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try? fm.moveItem(at: sidecar, to: URL(fileURLWithPath: aside.path + suffix))
            }
        }
        return aside
    }

    private init(url: URL) throws {
        self.url = url
        writer = try SQLiteConnection(path: url.path)
    }

    private func configureAndMigrate(report: inout DatabaseOpenReport) throws {
        try writer.exec("PRAGMA journal_mode = WAL")
        try writer.exec("PRAGMA synchronous = NORMAL")
        try writer.exec("PRAGMA foreign_keys = ON")
        try writer.exec("PRAGMA temp_store = MEMORY")
        try writer.exec("PRAGMA cache_size = -8192")
        try writer.exec("PRAGMA journal_size_limit = 67108864")

        // An unclean previous shutdown is the only situation where on-disk damage is plausible, so
        // the (comparatively slow) integrity check is limited to that case.
        let hadSettingsTable = try writer.scalarInt(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='setting'") ?? 0
        if hadSettingsTable > 0 {
            let clean = try writer.queryOne("SELECT value FROM setting WHERE key = 'clean_shutdown'") { $0.text(0) }
            if clean != "1" {
                report.integrityCheckRan = true
                let result = try writer.queryOne("PRAGMA quick_check(1)") { $0.text(0) } ?? "ok"
                if result != "ok" {
                    throw SQLiteError(code: SQLITE_CORRUPT, message: "quick_check failed: \(result)", sql: nil)
                }
            }
        }

        let current = Int(try writer.scalarInt("PRAGMA user_version") ?? 0)
        report.migratedFrom = current
        for migration in Schema.migrations where migration.version > current {
            try writer.transaction {
                try writer.exec(migration.sql)
                try writer.exec("PRAGMA user_version = \(migration.version)")
            }
        }
        report.migratedTo = Schema.latestVersion
        try PricingStore.seedIfNeeded(self)
        try writer.run("INSERT INTO setting(key, value, updated_at) VALUES('clean_shutdown', '0', ?) "
                       + "ON CONFLICT(key) DO UPDATE SET value = '0', updated_at = excluded.updated_at",
                       [.int(Clock.nowMs())])
    }

    /// Marks the shutdown as clean, so that the next launch can skip the integrity check.
    public func markCleanShutdown() {
        try? write { c in
            try c.run("INSERT INTO setting(key, value, updated_at) VALUES('clean_shutdown', '1', ?) "
                      + "ON CONFLICT(key) DO UPDATE SET value = '1', updated_at = excluded.updated_at",
                      [.int(Clock.nowMs())])
        }
        writerLock.lock()
        _ = try? writer.query("PRAGMA wal_checkpoint(PASSIVE)") { _ in 0 }
        writerLock.unlock()
    }

    // MARK: Access

    /// Runs `body` in a write transaction on the single writer connection.
    @discardableResult
    public func write<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        writerLock.lock()
        defer { writerLock.unlock() }
        return try writer.transaction { try body(writer) }
    }

    /// Runs `body` on a read-only connection from the pool. WAL guarantees the reader sees a
    /// consistent snapshot even while the writer is committing.
    public func read<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        let conn = try checkoutReader()
        defer { returnReader(conn) }
        return try body(conn)
    }

    private func checkoutReader() throws -> SQLiteConnection {
        readerCondition.lock()
        defer { readerCondition.unlock() }
        while true {
            if let c = idleReaders.popLast() { return c }
            if readersCreated < maxReaders {
                readersCreated += 1
                do {
                    let c = try SQLiteConnection(path: url.path, readOnly: true)
                    try c.exec("PRAGMA query_only = ON")
                    try c.exec("PRAGMA cache_size = -8192")
                    try c.exec("PRAGMA mmap_size = 0")
                    return c
                } catch {
                    readersCreated -= 1
                    throw error
                }
            }
            readerCondition.wait()
        }
    }

    private func returnReader(_ c: SQLiteConnection) {
        readerCondition.lock()
        idleReaders.append(c)
        readerCondition.signal()
        readerCondition.unlock()
    }

    // MARK: Maintenance

    /// Runs a full integrity check. This can take a while on a large database.
    public func integrityCheck() throws -> [String] {
        try read { c in try c.query("PRAGMA integrity_check") { $0.text(0) } }
    }

    public func foreignKeyViolations() throws -> Int {
        try read { c in try c.query("PRAGMA foreign_key_check") { _ in 1 }.count }
    }

    /// Size on disk of the database and its write-ahead log.
    public func diskUsageBytes() -> Int64 {
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path + suffix),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    /// Removes every observation derived from usage logs, keeping settings, quota history and
    /// price rates. Used by "rebuild from source" and by the local-data deletion action.
    public func resetDerivedUsageData() throws {
        try write { c in
            for table in ["model_request", "session_reported_model_cost", "agent", "session",
                          "project", "model", "source_file", "ingest_issue"] {
                try c.run("DELETE FROM \(table)")
            }
        }
    }

    /// Deletes everything the app has stored, except the schema.
    public func eraseAllData() throws {
        try write { c in
            for table in ["model_request", "session_reported_model_cost", "agent", "session",
                          "project", "model", "source_file", "ingest_issue", "quota_snapshot",
                          "alert_fired"] {
                try c.run("DELETE FROM \(table)")
            }
        }
        writerLock.lock()
        _ = try? writer.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in 0 }
        try? writer.exec("VACUUM")
        writerLock.unlock()
    }
}

/// These time helpers are shared across the core. A single place makes it easy to substitute a fixed clock
/// in tests.
public enum Clock {
    public static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
    public static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    public static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
