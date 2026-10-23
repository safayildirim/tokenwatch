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
    /// The providers, products, surfaces, quota pools and telemetry sources this database was opened for.
    public let registry: ProviderRegistry

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
    public static func open(at url: URL, registry: ProviderRegistry = .builtin) throws -> UsageDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var report = DatabaseOpenReport()
        do {
            return try attemptOpen(at: url, registry: registry, report: &report)
        } catch let error as SQLiteError where error.isCorruption {
            let aside = try quarantine(url)
            report = DatabaseOpenReport()
            report.recoveredFromCorruption = true
            report.quarantinedTo = aside
            return try attemptOpen(at: url, registry: registry, report: &report)
        }
    }

    private static func attemptOpen(at url: URL, registry: ProviderRegistry, report: inout DatabaseOpenReport) throws -> UsageDatabase {
        let db = try UsageDatabase(url: url, registry: registry)
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

    private init(url: URL, registry: ProviderRegistry) throws {
        self.url = url
        self.registry = registry
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
        try writer.transaction { try RegistrySeeder.seed(registry, into: writer) }
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

    /// This is the stored usage whose source file no longer exists on disk, so the database holds its only copy.
    ///
    /// Claude Code deletes old transcripts on its own schedule, and the database keeps their requests. A rebuild
    /// imports only the files that still exist, so these requests are exactly what a rebuild would lose.
    public struct RetainedHistory: Sendable, Equatable {
        public var files = 0
        public var requests = 0
    }

    public func retainedOnlyHistory() throws -> RetainedHistory {
        let rows = try read { c in
            try c.query("""
                SELECT f.path, count(*) FROM model_request r JOIN source_file f ON f.id = r.origin_file_id GROUP BY f.id
                """) { ($0.text(0), Int($0.int(1))) }
        }
        var result = RetainedHistory()
        for (path, count) in rows where !FileManager.default.fileExists(atPath: path) {
            result.files += 1
            result.requests += count
        }
        return result
    }

    /// The folder that holds the copies made before a rebuild. It sits next to the database, so a test database
    /// keeps its backups in its own scratch folder.
    public var backupDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("backups") }

    /// This many backups are kept. Each one is a complete copy of the usage history, so the limit bounds both the
    /// disk space used and the number of copies of the metadata that exist.
    public static let backupsKept = 3

    /// Writes a consistent copy of the whole database into `backupDirectory`, before a rebuild, and returns its location.
    ///
    /// `VACUUM INTO` copies the committed state as one transaction, including whatever is still only in the
    /// write-ahead log, so the copy is a complete database file that opens without its `-wal` and `-shm` files. The
    /// folder is private to the user and the file is readable only by the user. After writing, only the newest
    /// `backupsKept` backups are kept.
    @discardableResult
    public func backUpBeforeRebuild() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var target = backupDirectory.appendingPathComponent("usage-before-rebuild-\(formatter.string(from: Date())).sqlite")
        var attempt = 1
        while fm.fileExists(atPath: target.path) {
            attempt += 1
            target = backupDirectory.appendingPathComponent("usage-before-rebuild-\(formatter.string(from: Date()))-\(attempt).sqlite")
        }
        writerLock.lock()
        defer { writerLock.unlock() }
        try writer.run("VACUUM INTO ?", [.text(target.path)])
        chmod(target.path, 0o600)
        try pruneBackups()
        return target
    }

    /// The backups that exist, newest first.
    public func backups() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
        // The names carry a sortable UTC time stamp, so sorting them by name sorts them by age.
        return names.filter { $0.hasPrefix("usage-before-rebuild-") && $0.hasSuffix(".sqlite") }.sorted(by: >)
            .map { backupDirectory.appendingPathComponent($0) }
    }

    private func pruneBackups() throws {
        for old in backups().dropFirst(Self.backupsKept) { try FileManager.default.removeItem(at: old) }
    }

    /// Removes every observation derived from usage logs, keeping settings, quota history and
    /// price rates. Used by "rebuild from source" and by the local-data deletion action.
    public func resetDerivedUsageData() throws {
        try write { c in
            for table in ["model_request", "session_reported_model_cost", "agent", "session",
                          "project", "model", "source_file", "ingest_issue"] {
                try c.run("DELETE FROM \(table)")
            }
            // Accounts, quota history, plan periods, capacity measurements and account associations stay: they are what providers
            // reported or what the user said, and none of it can be recreated from the logs.
        }
    }

    /// Deletes everything the app has stored, except the schema.
    public func eraseAllData() throws {
        try write { c in
            for table in ["capacity_measurement", "plan_assignment", "account_association", "model_request", "session_reported_model_cost",
                          "agent", "session", "project", "model", "source_file", "ingest_issue", "quota_snapshot",
                          "quota_cycle", "quota_window", "quota_pool", "alert_fired"] {
                try c.run("DELETE FROM \(table)")
            }
            try c.run("DELETE FROM account WHERE hash != ''")
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
