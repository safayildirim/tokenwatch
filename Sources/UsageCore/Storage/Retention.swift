import Foundation

extension UsageDatabase {
    /// Deletes usage observations older than `cutoffMs` and anything that becomes orphaned.
    ///
    /// The importer applies the same cutoff to everything it reads, so purged history is not
    /// brought back the next time a log file is scanned.
    @discardableResult
    public func purge(olderThanMs cutoffMs: Int64) throws -> Int {
        try write { c in
            let removed = try c.run("DELETE FROM model_request WHERE requested_at < ?", [.int(cutoffMs)])
            try c.run("""
                DELETE FROM session
                WHERE COALESCE(last_activity_at, 0) < ? AND id NOT IN (SELECT DISTINCT session_id FROM model_request)
                """, [.int(cutoffMs)])
            try c.run("DELETE FROM project WHERE id NOT IN (SELECT DISTINCT project_id FROM session WHERE project_id IS NOT NULL)")
            try c.run("DELETE FROM quota_snapshot WHERE observed_at < ?", [.int(cutoffMs)])
            try c.run("DELETE FROM alert_fired WHERE fired_at < ?", [.int(cutoffMs)])
            return removed
        }
    }

    /// Reads a plain string setting.
    public func setting(_ key: String) -> String? {
        (try? read { c in try c.queryOne("SELECT value FROM setting WHERE key = ?", [.text(key)]) { $0.text(0) } }) ?? nil
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try write { c in
            try c.run("""
                INSERT INTO setting(key, value, updated_at) VALUES(?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """, [.text(key), .text(value), .int(Clock.nowMs())])
        }
    }
}
