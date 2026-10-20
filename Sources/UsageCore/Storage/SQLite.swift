import Foundation
import SQLite3

/// An error raised by the SQLite layer, carrying the primary result code so that callers can react
/// to lock contention or a full disk differently from a logic error.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        "SQLite error \(code): \(message)" + (sql.map { " [\($0.prefix(120))]" } ?? "")
    }

    /// True when another connection holds a lock for longer than the busy timeout.
    public var isBusy: Bool { code == SQLITE_BUSY || code == SQLITE_LOCKED }
    /// True when the disk (or the quota for the database volume) is exhausted.
    public var isDiskFull: Bool { code == SQLITE_FULL }
    /// True when the file is not a database, or its structure is damaged.
    public var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}

/// This is a bindable SQL value. Integers, reals, text and null cover everything the schema stores.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    public static func int(_ v: Int) -> SQLValue { .int(Int64(v)) }
    public static func optional(_ v: Int64?) -> SQLValue { v.map { .int($0) } ?? .null }
    public static func optional(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
    public static func optional(_ v: Double?) -> SQLValue { v.map { .real($0) } ?? .null }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// This is a prepared statement owned by a single connection. It is reset automatically after each use.
public final class SQLiteStatement {
    fileprivate let stmt: OpaquePointer
    fileprivate let db: OpaquePointer
    let sql: String

    fileprivate init(stmt: OpaquePointer, db: OpaquePointer, sql: String) {
        self.stmt = stmt
        self.db = db
        self.sql = sql
    }

    deinit { sqlite3_finalize(stmt) }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let n): rc = sqlite3_bind_int64(stmt, idx, n)
            case .real(let d): rc = sqlite3_bind_double(stmt, idx, d)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            if rc != SQLITE_OK { throw error(rc) }
        }
    }

    /// Advances to the next row. Returns false once the statement is exhausted.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error(rc)
        }
    }

    func reset() { sqlite3_reset(stmt) }

    fileprivate func error(_ rc: Int32) -> SQLiteError {
        // Extended result codes carry the primary code in their low byte.
        SQLiteError(code: rc & 0xFF, message: String(cString: sqlite3_errmsg(db)), sql: sql)
    }

    // MARK: Column access

    func int(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
    func intOrNil(_ col: Int32) -> Int64? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, col)
    }
    func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
    func doubleOrNil(_ col: Int32) -> Double? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
    }
    func text(_ col: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: p)
    }
    func textOrNil(_ col: Int32) -> String? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : text(col)
    }
}

/// This is a single SQLite connection. Connections are not thread safe by themselves; `UsageDatabase`
/// serializes access to each one.
public final class SQLiteConnection {
    let handle: OpaquePointer
    private var cache: [String: SQLiteStatement] = [:]
    public let path: String
    public let isReadOnly: Bool

    public init(path: String, readOnly: Bool = false, busyTimeoutMs: Int32 = 8000) throws {
        self.path = path
        self.isReadOnly = readOnly
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: msg, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, busyTimeoutMs)
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        if let s = cache[sql] { return s }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        let s = SQLiteStatement(stmt: stmt, db: handle, sql: sql)
        if cache.count > 200 { cache.removeAll() }
        cache[sql] = s
        return s
    }

    /// Runs one or more statements that return no rows, without parameters.
    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc & 0xFF, message: msg, sql: sql)
        }
    }

    /// Runs a parameterized statement and discards any rows.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        let s = try prepare(sql)
        try s.bind(params)
        defer { s.reset() }
        while try s.step() {}
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ params: [SQLValue] = [], _ map: (SQLiteRow) throws -> T) throws -> [T] {
        let s = try prepare(sql)
        try s.bind(params)
        defer { s.reset() }
        var out: [T] = []
        while try s.step() { out.append(try map(SQLiteRow(stmt: s))) }
        return out
    }

    /// Runs a query and maps the first row, if any.
    public func queryOne<T>(_ sql: String, _ params: [SQLValue] = [], _ map: (SQLiteRow) throws -> T) throws -> T? {
        let s = try prepare(sql)
        try s.bind(params)
        defer { s.reset() }
        guard try s.step() else { return nil }
        return try map(SQLiteRow(stmt: s))
    }

    public func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int64? {
        try queryOne(sql, params) { $0.intOrNil(0) } ?? nil
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Runs `body` inside `BEGIN IMMEDIATE ... COMMIT`, rolling back if it throws. Because the
    /// transaction takes the write lock up front, a busy database fails fast at the start rather
    /// than half way through the work.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

/// This is a lightweight view of the current row of a statement.
public struct SQLiteRow {
    let stmt: SQLiteStatement
    public func int(_ c: Int32) -> Int64 { stmt.int(c) }
    public func intOrNil(_ c: Int32) -> Int64? { stmt.intOrNil(c) }
    public func double(_ c: Int32) -> Double { stmt.double(c) }
    public func doubleOrNil(_ c: Int32) -> Double? { stmt.doubleOrNil(c) }
    public func text(_ c: Int32) -> String { stmt.text(c) }
    public func textOrNil(_ c: Int32) -> String? { stmt.textOrNil(c) }
}
