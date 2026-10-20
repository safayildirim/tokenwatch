import Foundation

/// These are the checkpoint columns that are written together with each batch.
struct CheckpointUpdate {
    var fileID: Int64
    var device: Int64
    var inode: Int64
    var size: Int64
    var mtimeMs: Int64
    var consumedOffset: Int64
    var headLen: Int
    var headHash: String
    var addedLines: Int
    var addedMalformed: Int
    var status: String
    var lastError: String?
}

struct ApplyStats {
    var requestsTouched = 0
    var sessionsTouched = 0
}

/// Writes normalized observations and the matching file checkpoint in one transaction.
///
/// Because the observations and the byte offset that produced them commit together, a crash can
/// never leave the database ahead of or behind its checkpoint. Re-delivering any observation is
/// harmless because every statement is an idempotent upsert with commutative merge rules.
enum IngestWriter {
    static func apply(batch: NormalizedBatch, checkpoint: CheckpointUpdate?, retentionFloorMs: Int64?,
                      db: UsageDatabase) throws -> ApplyStats {
        try db.write { c in
            var stats = ApplyStats()
            let now = Clock.nowMs()
            var sourceIDs = Set<String>()
            for r in batch.requests.values { sourceIDs.insert(r.sourceID) }
            for s in batch.sessions.values { sourceIDs.insert(s.sourceID) }
            for r in batch.costReports.values { sourceIDs.insert(r.sourceID) }
            for id in sourceIDs { try ensureSource(c, id) }

            // Create or update the projects and sessions that the batch mentions.
            var projectIDs: [String: Int64] = [:]
            var sessionIDs: [String: Int64] = [:]
            for s in batch.sessions.values {
                if let floor = retentionFloorMs, s.lastSeenMs < floor { continue }
                let pkey = s.sourceID + "\u{1F}" + s.projectKey
                let projectID: Int64
                if let cached = projectIDs[pkey] { projectID = cached }
                else {
                    projectID = try upsertProject(c, sourceID: s.sourceID, key: s.projectKey, cwd: s.cwd)
                    projectIDs[pkey] = projectID
                }
                let id = try upsertSession(c, s, projectID: projectID)
                sessionIDs[s.sourceID + "\u{1F}" + s.externalID] = id
                stats.sessionsTouched += 1
            }

            func sessionID(source: String, external: String) throws -> Int64 {
                let key = source + "\u{1F}" + external
                if let id = sessionIDs[key] { return id }
                // Create a placeholder session for a request or report whose session had no timestamped record of its own.
                try c.run("INSERT OR IGNORE INTO session(source_id, external_id) VALUES(?, ?)",
                          [.text(source), .text(external)])
                let id = try c.scalarInt("SELECT id FROM session WHERE source_id = ? AND external_id = ?",
                                         [.text(source), .text(external)])!
                sessionIDs[key] = id
                return id
            }

            for a in batch.agents.values {
                if let floor = retentionFloorMs, a.lastSeenMs < floor { continue }
                let sid = try sessionID(source: a.sourceID, external: a.sessionExternalID)
                try c.run("""
                    INSERT INTO agent(session_id, external_id, first_seen_at, last_seen_at) VALUES(?, ?, ?, ?)
                    ON CONFLICT(session_id, external_id) DO UPDATE SET
                        first_seen_at = min(COALESCE(first_seen_at, excluded.first_seen_at), excluded.first_seen_at),
                        last_seen_at = max(COALESCE(last_seen_at, excluded.last_seen_at), excluded.last_seen_at)
                    """, [.int(sid), .text(a.externalID), .int(a.firstSeenMs), .int(a.lastSeenMs)])
            }

            var knownModels = Set<String>()
            for r in batch.requests.values {
                if let floor = retentionFloorMs, r.requestedAtMs < floor { continue }
                if knownModels.insert(r.modelID).inserted {
                    let d = ModelCatalog.describe(r.modelID)
                    try c.run("""
                        INSERT INTO model(id, canonical, family, display_name) VALUES(?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET canonical = excluded.canonical,
                            family = excluded.family, display_name = excluded.display_name
                        """, [.text(r.modelID), .text(d.canonical), .text(d.family), .text(d.displayName)])
                }
                let sid = try sessionID(source: r.sourceID, external: r.sessionExternalID)
                try upsertRequest(c, r, sessionID: sid, fileID: checkpoint?.fileID, now: now)
                stats.requestsTouched += 1
            }

            for report in batch.costReports.values {
                let sid = try sessionID(source: report.sourceID, external: report.sessionExternalID)
                let existing = try c.scalarInt("SELECT reported_cost_micros FROM session WHERE id = ?", [.int(sid)])
                guard existing == nil || report.totalCostMicros > existing! else { continue }
                try c.run("UPDATE session SET reported_cost_micros = ? WHERE id = ?",
                          [.int(report.totalCostMicros), .int(sid)])
                try c.run("DELETE FROM session_reported_model_cost WHERE session_id = ?", [.int(sid)])
                for m in report.models {
                    try c.run("""
                        INSERT INTO session_reported_model_cost(session_id, model_raw, input_tokens,
                            output_tokens, cache_read_tokens, cache_creation_tokens, cost_micros)
                        VALUES(?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(session_id, model_raw) DO UPDATE SET
                            input_tokens = excluded.input_tokens, output_tokens = excluded.output_tokens,
                            cache_read_tokens = excluded.cache_read_tokens,
                            cache_creation_tokens = excluded.cache_creation_tokens,
                            cost_micros = excluded.cost_micros
                        """, [.int(sid), .text(m.modelRaw), .int(m.uncachedInput), .int(m.output),
                              .int(m.cacheRead), .int(m.cacheCreation), .int(m.costMicros)])
                }
            }

            if let cp = checkpoint {
                try c.run("""
                    UPDATE source_file SET device = ?, inode = ?, size = ?, mtime_ms = ?, consumed_offset = ?,
                        head_len = ?, head_hash = ?, line_count = line_count + ?, malformed_lines = malformed_lines + ?,
                        status = ?, last_error = ?, last_synced_at = ?
                    WHERE id = ?
                    """, [.int(cp.device), .int(cp.inode), .int(cp.size), .int(cp.mtimeMs), .int(cp.consumedOffset),
                          .int(Int64(cp.headLen)), .text(cp.headHash), .int(Int64(cp.addedLines)),
                          .int(Int64(cp.addedMalformed)), .text(cp.status), .optional(cp.lastError), .int(now),
                          .int(cp.fileID)])
            }
            return stats
        }
    }

    // MARK: Statements

    private static func ensureSource(_ c: SQLiteConnection, _ id: String) throws {
        try c.run("INSERT OR IGNORE INTO usage_source(id, display_name) VALUES(?, ?)", [.text(id), .text(id)])
    }

    static func projectName(cwd: String?, key: String) -> String {
        if let cwd, !cwd.isEmpty {
            let last = (cwd as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        return key
    }

    /// Mirrors Claude Code's rule for turning a directory into a project folder name.
    static func encodeProjectKey(_ path: String) -> String {
        String(path.unicodeScalars.map { s in
            (s.isASCII && (s.properties.isAlphabetic || (s.value >= 0x30 && s.value <= 0x39))) ? Character(s) : "-"
        })
    }

    private static func upsertProject(_ c: SQLiteConnection, sourceID: String, key: String, cwd: String?) throws -> Int64 {
        // The working directory is trusted as the project root only when it maps back to the
        // project folder name; otherwise the session started in a sub-directory or elsewhere.
        let root = (cwd != nil && encodeProjectKey(cwd!) == key) ? cwd : nil
        let name = projectName(cwd: root, key: key)
        return try c.queryOne("""
            INSERT INTO project(source_id, key, path, name) VALUES(?, ?, ?, ?)
            ON CONFLICT(source_id, key) DO UPDATE SET
                name = CASE WHEN project.path IS NULL AND excluded.path IS NOT NULL THEN excluded.name ELSE project.name END,
                path = COALESCE(project.path, excluded.path)
            RETURNING id
            """, [.text(sourceID), .text(key), .optional(root), .text(name)]) { $0.int(0) }!
    }

    private static func upsertSession(_ c: SQLiteConnection, _ s: SessionObservation, projectID: Int64) throws -> Int64 {
        try c.queryOne("""
            INSERT INTO session(source_id, external_id, project_id, application, cwd, client_version, started_at, last_activity_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id, external_id) DO UPDATE SET
                project_id = COALESCE(session.project_id, excluded.project_id),
                application = COALESCE(session.application, excluded.application),
                cwd = CASE WHEN excluded.started_at < COALESCE(session.started_at, excluded.started_at + 1)
                           THEN COALESCE(excluded.cwd, session.cwd)
                           ELSE COALESCE(session.cwd, excluded.cwd) END,
                client_version = CASE WHEN excluded.client_version IS NOT NULL
                                       AND excluded.last_activity_at >= COALESCE(session.last_activity_at, 0)
                                      THEN excluded.client_version ELSE session.client_version END,
                started_at = min(COALESCE(session.started_at, excluded.started_at), excluded.started_at),
                last_activity_at = max(COALESCE(session.last_activity_at, excluded.last_activity_at), excluded.last_activity_at)
            RETURNING id
            """, [.text(s.sourceID), .text(s.externalID), .int(projectID), .optional(s.application),
                  .optional(s.cwd), .optional(s.clientVersion), .int(s.firstSeenMs), .int(s.lastSeenMs)]) { $0.int(0) }!
    }

    /// The upsert implements `RequestObservation.merged(with:)` in SQL.
    private static func upsertRequest(_ c: SQLiteConnection, _ r: RequestObservation, sessionID: Int64,
                                      fileID: Int64?, now: Int64) throws {
        // Keeps a present value over a missing one and takes the larger when both are present.
        func pick(_ col: String) -> String {
            "CASE WHEN model_request.\(col) IS NULL THEN excluded.\(col) WHEN excluded.\(col) IS NULL THEN model_request.\(col) ELSE max(model_request.\(col), excluded.\(col)) END"
        }
        try c.run("""
            INSERT INTO model_request(source_id, request_key, api_request_id, session_id, agent_key, model_id,
                requested_at, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
                cache_creation_5m_tokens, cache_creation_1h_tokens, speed, stop_reason, source_cost_micros,
                origin_file_id, origin_offset, first_ingested_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id, request_key) DO UPDATE SET
                api_request_id = \(pick("api_request_id")),
                agent_key = CASE WHEN model_request.agent_key IS NULL OR excluded.agent_key IS NULL THEN NULL
                                 ELSE min(model_request.agent_key, excluded.agent_key) END,
                model_id = CASE WHEN model_request.model_id = '<synthetic>' THEN excluded.model_id
                                WHEN excluded.model_id = '<synthetic>' THEN model_request.model_id
                                ELSE min(model_request.model_id, excluded.model_id) END,
                requested_at = min(model_request.requested_at, excluded.requested_at),
                input_tokens = max(model_request.input_tokens, excluded.input_tokens),
                output_tokens = max(model_request.output_tokens, excluded.output_tokens),
                cache_read_tokens = max(model_request.cache_read_tokens, excluded.cache_read_tokens),
                cache_creation_tokens = max(model_request.cache_creation_tokens, excluded.cache_creation_tokens),
                cache_creation_5m_tokens = \(pick("cache_creation_5m_tokens")),
                cache_creation_1h_tokens = \(pick("cache_creation_1h_tokens")),
                speed = \(pick("speed")),
                stop_reason = \(pick("stop_reason")),
                source_cost_micros = \(pick("source_cost_micros"))
            """, [.text(r.sourceID), .text(r.requestKey), .optional(r.apiRequestID), .int(sessionID),
                  .optional(r.agentExternalID), .text(r.modelID), .int(r.requestedAtMs), .int(r.uncachedInput),
                  .int(r.output), .int(r.cacheRead), .int(r.cacheCreation), .optional(r.cacheCreation5m),
                  .optional(r.cacheCreation1h), .optional(r.speed), .optional(r.stopReason),
                  .optional(r.sourceCostMicros), .optional(fileID), .int(r.originOffset), .int(now)])
    }
}
