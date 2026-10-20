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
    /// True when the batch holds everything the file says, so that its notices replace the ones stored for the file.
    var replacesNotices = false
}

struct ApplyStats {
    var requestsTouched = 0
    var sessionsTouched = 0
    var quotaObservations = 0
}

/// Writes normalized observations and the matching file checkpoint in one transaction.
///
/// Because the observations and the byte offset that produced them commit together, a crash can
/// never leave the database ahead of or behind its checkpoint. Re-delivering any observation is
/// harmless because every statement is an idempotent upsert with commutative merge rules.
///
/// Nothing in this file knows about a particular provider. Adapters reach it only through the
/// observation types, which already use the canonical vocabulary.
enum IngestWriter {
    static func apply(batch: NormalizedBatch, checkpoint: CheckpointUpdate?, retentionFloorMs: Int64?,
                      db: UsageDatabase) throws -> ApplyStats {
        try db.write { c in
            var stats = ApplyStats()
            let now = Clock.nowMs()
            let resolver = EntityResolver(c, registry: db.registry)

            // Sessions come first, so that everything else can refer to them.
            for s in batch.sessions.values {
                if let floor = retentionFloorMs, s.lastSeenMs < floor { continue }
                let id = try upsertSession(c, s, resolver: resolver)
                resolver.remember(session: id, product: s.product, externalID: s.externalID)
                try linkRelatives(c, s, id: id)
                stats.sessionsTouched += 1
            }

            for a in batch.agents.values {
                if let floor = retentionFloorMs, a.lastSeenMs < floor { continue }
                let sid = try resolver.ensureSession(product: a.product, externalID: a.sessionExternalID,
                                                     source: placeholderSource(for: a.product, db))
                try c.run("""
                    INSERT INTO agent(session_id, external_id, first_seen_at, last_seen_at) VALUES(?, ?, ?, ?)
                    ON CONFLICT(session_id, external_id) DO UPDATE SET
                        first_seen_at = min(COALESCE(first_seen_at, excluded.first_seen_at), excluded.first_seen_at),
                        last_seen_at = max(COALESCE(last_seen_at, excluded.last_seen_at), excluded.last_seen_at)
                    """, [.int(sid), .text(a.externalID), .int(a.firstSeenMs), .int(a.lastSeenMs)])
            }

            for r in batch.requests.values {
                if let floor = retentionFloorMs, r.requestedAtMs < floor { continue }
                let provider = db.registry.providerOf(product: r.product) ?? ProviderID(rawValue: "unknown")
                let modelID = try resolver.model(provider: provider, raw: r.model)
                let request = try sameResponseOfSiblingProduct(c, r, provider: provider, registry: db.registry) ?? r
                let sid = try resolver.ensureSession(product: request.product, externalID: request.sessionExternalID, source: request.source)
                try upsertRequest(c, request, sessionID: sid, modelID: modelID, fileID: checkpoint?.fileID, now: now)
                stats.requestsTouched += 1
            }

            for report in batch.costReports.values {
                let sid = try resolver.ensureSession(product: report.product, externalID: report.sessionExternalID,
                                                     source: placeholderSource(for: report.product, db))
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

            for o in coalesce(batch.quota) {
                var originID: Int64?
                if let product = o.originProduct, let external = o.originSession {
                    originID = try resolver.ensureSession(product: product, externalID: external, source: o.source)
                }
                try QuotaStore.record(o, originSessionID: originID, resolver: resolver)
                stats.quotaObservations += 1
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
                if cp.replacesNotices {
                    try c.run("DELETE FROM ingest_issue WHERE severity = 'notice' AND (source_id, path) = (SELECT source_id, path FROM source_file WHERE id = ?)",
                              [.int(cp.fileID)])
                    for notice in batch.notices {
                        try c.run("INSERT INTO ingest_issue(source_id, path, at, severity, message) SELECT source_id, path, ?, 'notice', ? FROM source_file WHERE id = ?",
                                  [.int(now), .text(notice), .int(cp.fileID)])
                    }
                }
            }
            return stats
        }
    }

    /// A response id is issued by the provider, so it is the same response whichever of the provider's products shows it.
    /// A session that one product copied from another, such as a fork opened in a different application, repeats the
    /// responses of the original, and counting them under both products would count them twice. When a response with
    /// this id is already stored under a sibling product, the observation is merged into that row.
    private static func sameResponseOfSiblingProduct(_ c: SQLiteConnection, _ r: RequestObservation, provider: ProviderID,
                                                     registry: ProviderRegistry) throws -> RequestObservation? {
        guard let apiID = r.apiRequestID else { return nil }
        let siblings = registry.products(of: provider).map(\.id).filter { $0 != r.product }
        guard !siblings.isEmpty else { return nil }
        let marks = Array(repeating: "?", count: siblings.count).joined(separator: ",")
        let existing = try c.queryOne("""
            SELECT product_id FROM model_request WHERE api_request_id = ? AND request_key = ? AND product_id IN (\(marks)) LIMIT 1
            """, [.text(apiID), .text(r.requestKey)] + siblings.map { .text($0.rawValue) }) { $0.text(0) }
        guard let existing else { return nil }
        var merged = r
        merged.product = ProductID(rawValue: existing)
        return merged
    }

    /// Chooses the telemetry source recorded on a placeholder session, which exists only because a report
    /// mentioned a session that has no record of its own. The first session-log source of the product is
    /// the most plausible origin.
    private static func placeholderSource(for product: ProductID, _ db: UsageDatabase) -> TelemetrySourceID {
        let covering = db.registry.sources.filter { $0.products.contains(product) }
        return (covering.first { $0.kind == .sessionLogs } ?? covering.first)?.id ?? TelemetrySourceID(rawValue: "unknown")
    }

    // MARK: Quota

    /// Collapses runs of identical readings into the first and last reading of each run. A session that reports
    /// the same percentage on every request would otherwise cause thousands of identical writes.
    static func coalesce(_ observations: [QuotaObservation]) -> [QuotaObservation] {
        var out: [QuotaObservation] = []
        var open: [String: (first: QuotaObservation, last: QuotaObservation)] = [:]
        func flush(_ key: String) {
            guard let run = open.removeValue(forKey: key) else { return }
            out.append(run.first)
            if run.last != run.first { out.append(run.last) }
        }
        for o in observations.sorted(by: { $0.observedAt < $1.observedAt }) {
            let key = "\(o.provider.rawValue)|\(o.account.hash ?? "-")|\(o.poolKey)|\(o.windowKey)|\(o.authority.rawValue)"
            if let run = open[key] {
                let sameReset: Bool
                switch (run.last.resetsAt, o.resetsAt) {
                case let (a?, b?): sameReset = abs(Clock.ms(a) - Clock.ms(b)) <= QuotaStore.cycleToleranceMs
                case (nil, nil): sameReset = true
                default: sameReset = false
                }
                if run.last.utilizationPercent == o.utilizationPercent && sameReset {
                    open[key] = (run.first, o)
                    continue
                }
                flush(key)
            }
            open[key] = (o, o)
        }
        for key in Array(open.keys) { flush(key) }
        return out
    }

    // MARK: Sessions

    /// Inserts the session or fills in what is missing. An identified account replaces the unassigned one,
    /// but never overrides an assignment that the user made.
    private static func upsertSession(_ c: SQLiteConnection, _ s: SessionObservation, resolver: EntityResolver) throws -> Int64 {
        let accountID = try resolver.account(s.account)
        let projectID = try resolver.project(key: s.projectKey)
        return try c.queryOne("""
            INSERT INTO session(product_id, external_id, account_id, telemetry_source_id, project_id, surface_id, kind,
                parent_external_id, root_external_id, cwd, client_version, started_at, last_activity_at, compaction_count)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(product_id, external_id) DO UPDATE SET
                account_id = CASE
                    WHEN session.account_source = 'user' THEN session.account_id
                    WHEN (SELECT hash FROM account WHERE id = session.account_id) = '' THEN excluded.account_id
                    ELSE session.account_id END,
                project_id = CASE
                    WHEN session.project_id IS NULL THEN excluded.project_id
                    WHEN (SELECT path FROM project WHERE id = session.project_id) IS NULL
                         AND (SELECT path FROM project WHERE id = excluded.project_id) IS NOT NULL THEN excluded.project_id
                    ELSE session.project_id END,
                surface_id = COALESCE(session.surface_id, excluded.surface_id),
                kind = CASE WHEN session.kind = 'main' THEN excluded.kind ELSE session.kind END,
                parent_external_id = COALESCE(session.parent_external_id, excluded.parent_external_id),
                root_external_id = COALESCE(session.root_external_id, excluded.root_external_id),
                cwd = CASE WHEN excluded.started_at < COALESCE(session.started_at, excluded.started_at + 1)
                           THEN COALESCE(excluded.cwd, session.cwd)
                           ELSE COALESCE(session.cwd, excluded.cwd) END,
                client_version = CASE WHEN excluded.client_version IS NOT NULL
                                       AND excluded.last_activity_at >= COALESCE(session.last_activity_at, 0)
                                      THEN excluded.client_version ELSE session.client_version END,
                started_at = min(COALESCE(session.started_at, excluded.started_at), excluded.started_at),
                last_activity_at = max(COALESCE(session.last_activity_at, excluded.last_activity_at), excluded.last_activity_at),
                compaction_count = max(session.compaction_count, excluded.compaction_count)
            RETURNING id
            """, [.text(s.product.rawValue), .text(s.externalID), .int(accountID), .text(s.source.rawValue), .int(projectID),
                  .optional(s.surface?.rawValue), .text(s.kind.rawValue), .optional(s.parentExternalID),
                  .optional(s.rootExternalID), .optional(s.cwd), .optional(s.clientVersion),
                  .int(s.firstSeenMs), .int(s.lastSeenMs), .int(Int64(s.compactionCount))]) { $0.int(0) }!
    }

    /// Links a session to its parent and root, and links any sessions that were waiting for this one. A
    /// child can be read before its parent, so both directions are resolved.
    private static func linkRelatives(_ c: SQLiteConnection, _ s: SessionObservation, id: Int64) throws {
        let product = s.product.rawValue
        try c.run("""
            UPDATE session SET
                parent_session_id = COALESCE(parent_session_id, (SELECT p.id FROM session p
                    WHERE p.product_id = session.product_id AND p.external_id = session.parent_external_id)),
                root_session_id = COALESCE(root_session_id, (SELECT p.id FROM session p
                    WHERE p.product_id = session.product_id AND p.external_id = session.root_external_id))
            WHERE id = ? AND (parent_external_id IS NOT NULL OR root_external_id IS NOT NULL)
            """, [.int(id)])
        try c.run("""
            UPDATE session SET parent_session_id = ?
            WHERE product_id = ? AND parent_external_id = ? AND parent_session_id IS NULL
            """, [.int(id), .text(product), .text(s.externalID)])
        // A session that only names its parent belongs to the same root as that parent, or to the parent itself.
        try c.run("""
            UPDATE session SET root_session_id = (SELECT COALESCE(p.root_session_id, p.id) FROM session p WHERE p.id = session.parent_session_id)
            WHERE parent_session_id IS NOT NULL AND root_session_id IS NULL AND (id = ? OR parent_session_id = ?)
            """, [.int(id), .int(id)])
        try c.run("""
            UPDATE session SET root_session_id = ?
            WHERE product_id = ? AND root_external_id = ? AND root_session_id IS NULL AND id != ?
            """, [.int(id), .text(product), .text(s.externalID), .int(id)])
    }

    // MARK: Requests

    /// The upsert implements `RequestObservation.merged(with:)` in SQL.
    private static func upsertRequest(_ c: SQLiteConnection, _ r: RequestObservation, sessionID: Int64, modelID: Int64,
                                      fileID: Int64?, now: Int64) throws {
        // Keeps a present value over a missing one and takes the larger when both are present.
        func pick(_ col: String) -> String {
            "CASE WHEN model_request.\(col) IS NULL THEN excluded.\(col) WHEN excluded.\(col) IS NULL THEN model_request.\(col) ELSE max(model_request.\(col), excluded.\(col)) END"
        }
        func rank(_ expr: String) -> String {
            "CASE \(expr) WHEN 'complete' THEN 2 WHEN 'reconciledFromTotals' THEN 1 ELSE 0 END"
        }
        let u = r.usage
        var extra: String?
        if !u.extras.isEmpty, let data = try? JSONSerialization.data(withJSONObject: u.extras, options: [.sortedKeys]) {
            extra = String(data: data, encoding: .utf8)
        }
        try c.run("""
            INSERT INTO model_request(product_id, request_key, api_request_id, session_id, agent_key, model_id, requested_at,
                uncached_input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, reasoning_output_tokens,
                cache_creation_5m_tokens, cache_creation_1h_tokens, usage_extra, normalization, completeness, speed, stop_reason,
                source_cost_micros, telemetry_source_id, origin_file_id, origin_location, first_ingested_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(product_id, request_key) DO UPDATE SET
                api_request_id = \(pick("api_request_id")),
                agent_key = CASE WHEN model_request.agent_key IS NULL OR excluded.agent_key IS NULL THEN NULL
                                 ELSE min(model_request.agent_key, excluded.agent_key) END,
                model_id = CASE
                    WHEN (SELECT raw_id FROM model WHERE id = model_request.model_id) = '<synthetic>' THEN excluded.model_id
                    WHEN (SELECT raw_id FROM model WHERE id = excluded.model_id) = '<synthetic>' THEN model_request.model_id
                    WHEN (SELECT raw_id FROM model WHERE id = excluded.model_id)
                         < (SELECT raw_id FROM model WHERE id = model_request.model_id) THEN excluded.model_id
                    ELSE model_request.model_id END,
                requested_at = min(model_request.requested_at, excluded.requested_at),
                uncached_input_tokens = \(pick("uncached_input_tokens")),
                output_tokens = max(model_request.output_tokens, excluded.output_tokens),
                cache_read_tokens = \(pick("cache_read_tokens")),
                cache_creation_tokens = \(pick("cache_creation_tokens")),
                reasoning_output_tokens = \(pick("reasoning_output_tokens")),
                cache_creation_5m_tokens = \(pick("cache_creation_5m_tokens")),
                cache_creation_1h_tokens = \(pick("cache_creation_1h_tokens")),
                usage_extra = \(pick("usage_extra")),
                normalization = max(model_request.normalization, excluded.normalization),
                completeness = CASE WHEN \(rank("excluded.completeness")) > \(rank("model_request.completeness"))
                                    THEN excluded.completeness ELSE model_request.completeness END,
                speed = \(pick("speed")),
                stop_reason = \(pick("stop_reason")),
                source_cost_micros = \(pick("source_cost_micros")),
                telemetry_source_id = CASE WHEN excluded.telemetry_source_id < model_request.telemetry_source_id
                                           THEN excluded.telemetry_source_id ELSE model_request.telemetry_source_id END
            """, [.text(r.product.rawValue), .text(r.requestKey), .optional(r.apiRequestID), .int(sessionID),
                  .optional(r.agentExternalID), .int(modelID), .int(r.requestedAtMs),
                  .optional(u.uncachedInput), .int(u.output), .optional(u.cacheRead), .optional(u.cacheCreation),
                  .optional(u.reasoningOutput), .optional(u.cacheCreation5m), .optional(u.cacheCreation1h),
                  .optional(extra), .text(u.normalization), .text(u.completeness.rawValue), .optional(r.speed),
                  .optional(r.stopReason), .optional(r.sourceCostMicros), .text(r.source.rawValue),
                  .optional(fileID), .int(r.originLocation), .int(now)])
    }
}
