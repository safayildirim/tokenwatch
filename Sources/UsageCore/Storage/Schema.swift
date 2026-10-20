import Foundation

/// This is one forward-only schema migration. The database records the highest applied version in
/// `PRAGMA user_version`, and each migration runs inside its own transaction.
struct Migration {
    let version: Int
    let name: String
    let sql: String
}

enum Schema {
    /// This is the ordered list of migrations. New schema changes are appended here and never edited, so
    /// that a database created by an older build can always be brought forward.
    static let migrations: [Migration] = [
        Migration(version: 1, name: "initial", sql: v1)
    ]

    static var latestVersion: Int { migrations.last?.version ?? 0 }

    /// This is version 1 of the schema.
    ///
    /// Conventions used throughout:
    /// - Every timestamp is an integer count of milliseconds since the Unix epoch in UTC.
    ///   Calendar concepts such as "today" are always computed at query time in the user's
    ///   current time zone, never stored.
    /// - Token counts are integers and are never reduced to a single total.
    /// - Money is stored as integers: source-reported costs in micro-USD, and price rates in
    ///   micro-USD per million tokens, so that `tokens * rate` is an exact count of pico-USD.
    private static let v1 = """
    CREATE TABLE usage_source (
        id           TEXT PRIMARY KEY,
        display_name TEXT NOT NULL
    ) STRICT;

    CREATE TABLE project (
        id        INTEGER PRIMARY KEY,
        source_id TEXT NOT NULL REFERENCES usage_source(id),
        key       TEXT NOT NULL,
        path      TEXT,
        name      TEXT NOT NULL,
        UNIQUE (source_id, key)
    ) STRICT;

    CREATE TABLE model (
        id           TEXT PRIMARY KEY,
        canonical    TEXT NOT NULL,
        family       TEXT NOT NULL,
        display_name TEXT NOT NULL
    ) STRICT;

    CREATE TABLE session (
        id                INTEGER PRIMARY KEY,
        source_id         TEXT NOT NULL REFERENCES usage_source(id),
        external_id       TEXT NOT NULL,
        project_id        INTEGER REFERENCES project(id),
        parent_session_id INTEGER REFERENCES session(id),
        application       TEXT,
        cwd               TEXT,
        client_version    TEXT,
        started_at        INTEGER,
        last_activity_at  INTEGER,
        observed_ended_at INTEGER,
        reported_cost_micros INTEGER,
        UNIQUE (source_id, external_id)
    ) STRICT;
    CREATE INDEX session_project ON session(project_id);
    CREATE INDEX session_activity ON session(last_activity_at);
    CREATE INDEX session_started ON session(started_at);

    CREATE TABLE agent (
        id            INTEGER PRIMARY KEY,
        session_id    INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
        external_id   TEXT NOT NULL,
        agent_type    TEXT,
        first_seen_at INTEGER,
        last_seen_at  INTEGER,
        UNIQUE (session_id, external_id)
    ) STRICT;

    CREATE TABLE model_request (
        id                       INTEGER PRIMARY KEY,
        source_id                TEXT NOT NULL REFERENCES usage_source(id),
        request_key              TEXT NOT NULL,
        api_request_id           TEXT,
        session_id               INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
        agent_key                TEXT,
        model_id                 TEXT NOT NULL REFERENCES model(id),
        requested_at             INTEGER NOT NULL,
        input_tokens             INTEGER NOT NULL,
        output_tokens            INTEGER NOT NULL,
        cache_read_tokens        INTEGER NOT NULL,
        cache_creation_tokens    INTEGER NOT NULL,
        cache_creation_5m_tokens INTEGER,
        cache_creation_1h_tokens INTEGER,
        logical_input_tokens     INTEGER GENERATED ALWAYS AS
            (input_tokens + cache_read_tokens + cache_creation_tokens) VIRTUAL,
        speed                    TEXT,
        stop_reason              TEXT,
        source_cost_micros       INTEGER,
        origin_file_id           INTEGER,
        origin_offset            INTEGER,
        first_ingested_at        INTEGER NOT NULL,
        UNIQUE (source_id, request_key)
    ) STRICT;
    CREATE INDEX request_time ON model_request(requested_at);
    CREATE INDEX request_session_time ON model_request(session_id, requested_at);
    CREATE INDEX request_model_time ON model_request(model_id, requested_at);
    CREATE INDEX request_api_id ON model_request(api_request_id) WHERE api_request_id IS NOT NULL;

    CREATE TABLE session_reported_model_cost (
        session_id            INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
        model_raw             TEXT NOT NULL,
        input_tokens          INTEGER NOT NULL,
        output_tokens         INTEGER NOT NULL,
        cache_read_tokens     INTEGER NOT NULL,
        cache_creation_tokens INTEGER NOT NULL,
        cost_micros           INTEGER NOT NULL,
        PRIMARY KEY (session_id, model_raw)
    ) STRICT;

    CREATE TABLE source_file (
        id               INTEGER PRIMARY KEY,
        source_id        TEXT NOT NULL REFERENCES usage_source(id),
        path             TEXT NOT NULL,
        device           INTEGER,
        inode            INTEGER,
        size             INTEGER NOT NULL DEFAULT 0,
        mtime_ms         INTEGER NOT NULL DEFAULT 0,
        consumed_offset  INTEGER NOT NULL DEFAULT 0,
        head_len         INTEGER NOT NULL DEFAULT 0,
        head_hash        TEXT,
        line_count       INTEGER NOT NULL DEFAULT 0,
        malformed_lines  INTEGER NOT NULL DEFAULT 0,
        status           TEXT NOT NULL DEFAULT 'pending',
        last_error       TEXT,
        last_synced_at   INTEGER,
        UNIQUE (source_id, path)
    ) STRICT;

    CREATE TABLE quota_snapshot (
        id              INTEGER PRIMARY KEY,
        provider        TEXT NOT NULL,
        window_kind     TEXT NOT NULL,
        utilization_pct REAL NOT NULL,
        resets_at       INTEGER,
        observed_at     INTEGER NOT NULL,
        authority       TEXT NOT NULL,
        origin          TEXT,
        UNIQUE (provider, window_kind, observed_at)
    ) STRICT;
    CREATE INDEX quota_time ON quota_snapshot(window_kind, observed_at);

    CREATE TABLE price_rate (
        id                         INTEGER PRIMARY KEY,
        model_key                  TEXT NOT NULL,
        effective_from             INTEGER NOT NULL,
        prompt_min                 INTEGER NOT NULL DEFAULT 0,
        prompt_max                 INTEGER,
        speed                      TEXT NOT NULL DEFAULT 'standard',
        input_micros_per_mtok      INTEGER NOT NULL,
        output_micros_per_mtok     INTEGER NOT NULL,
        cache_read_micros_per_mtok INTEGER NOT NULL,
        cache_5m_micros_per_mtok   INTEGER NOT NULL,
        cache_1h_micros_per_mtok   INTEGER NOT NULL,
        origin                     TEXT NOT NULL DEFAULT 'builtin',
        note                       TEXT,
        UNIQUE (model_key, effective_from, prompt_min, speed)
    ) STRICT;
    CREATE INDEX price_lookup ON price_rate(model_key, speed, effective_from);

    CREATE TABLE setting (
        key        TEXT PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE alert_fired (
        key      TEXT PRIMARY KEY,
        kind     TEXT NOT NULL,
        fired_at INTEGER NOT NULL,
        detail   TEXT
    ) STRICT;

    CREATE TABLE ingest_issue (
        id        INTEGER PRIMARY KEY,
        source_id TEXT,
        path      TEXT,
        at        INTEGER NOT NULL,
        severity  TEXT NOT NULL,
        message   TEXT NOT NULL
    ) STRICT;
    CREATE INDEX issue_time ON ingest_issue(at);
    """
}
