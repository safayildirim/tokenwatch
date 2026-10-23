import Foundation

/// This is one forward-only schema migration. The database records the highest applied version in
/// `PRAGMA user_version`, and each migration runs inside its own transaction.
struct Migration {
    let version: Int
    let name: String
    let sql: String
}

enum Schema {
    /// The ordered list of migrations. The application is still in development, so the first migration is
    /// edited in place instead of being followed by a second one. Once the schema is released, changes are
    /// appended here and an earlier migration is never edited again.
    static let migrations: [Migration] = [
        Migration(version: 1, name: "initial", sql: v1)
    ]

    static var latestVersion: Int { migrations.last?.version ?? 0 }

    /// Version 1 of the schema.
    ///
    /// The model separates the concepts whose semantics differ between providers.
    ///
    /// - A **provider** (Anthropic, OpenAI) offers **products** (Claude Code, Codex, ChatGPT Work). Products run
    ///   on **surfaces** (a terminal, an IDE, a desktop app). **Telemetry sources** are how data is collected.
    /// - An **account** belongs to one provider. An account with an empty hash is the explicit "unassigned"
    ///   account, used when the telemetry does not say which account an activity belongs to.
    /// - A **session** belongs to a product and an account. A **model request** belongs to a session and
    ///   stores usage in the canonical categories, with unknown categories left null.
    /// - A **quota pool** is an allowance enforced against one account. A pool has **windows**, each window
    ///   moves through **cycles** (one per reset), and **snapshots** record what a source reported.
    ///
    /// Conventions used throughout:
    /// - Every timestamp is an integer count of milliseconds since the Unix epoch in UTC.
    ///   Calendar concepts such as "today" are always computed at query time in the user's
    ///   current time zone, never stored.
    /// - Token counts are integers. Unknown categories are null, never zero.
    /// - Money is stored as integers: source-reported costs in micro-USD, and price rates in
    ///   micro-USD per million tokens, so that `tokens * rate` is an exact count of pico-USD.
    private static let v1 = """
    CREATE TABLE provider (
        id   TEXT PRIMARY KEY,
        name TEXT NOT NULL
    ) STRICT;

    CREATE TABLE product (
        id            TEXT PRIMARY KEY,
        provider_id   TEXT NOT NULL REFERENCES provider(id),
        name          TEXT NOT NULL,
        observability TEXT NOT NULL DEFAULT ''
    ) STRICT;

    CREATE TABLE surface (
        id     TEXT PRIMARY KEY,
        name   TEXT NOT NULL,
        symbol TEXT NOT NULL DEFAULT ''
    ) STRICT;

    CREATE TABLE telemetry_source (
        id           TEXT PRIMARY KEY,
        provider_id  TEXT NOT NULL REFERENCES provider(id),
        kind         TEXT NOT NULL,
        name         TEXT NOT NULL,
        capabilities INTEGER NOT NULL DEFAULT 0,
        limitations  TEXT NOT NULL DEFAULT ''
    ) STRICT;

    CREATE TABLE telemetry_source_product (
        source_id  TEXT NOT NULL REFERENCES telemetry_source(id),
        product_id TEXT NOT NULL REFERENCES product(id),
        PRIMARY KEY (source_id, product_id)
    ) STRICT;

    CREATE TABLE pool_definition (
        provider_id TEXT NOT NULL REFERENCES provider(id),
        pool_key    TEXT NOT NULL,
        name        TEXT NOT NULL,
        note        TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (provider_id, pool_key)
    ) STRICT;

    CREATE TABLE pool_membership (
        provider_id TEXT NOT NULL,
        pool_key    TEXT NOT NULL,
        product_id  TEXT NOT NULL REFERENCES product(id),
        PRIMARY KEY (provider_id, pool_key, product_id),
        FOREIGN KEY (provider_id, pool_key) REFERENCES pool_definition(provider_id, pool_key)
    ) STRICT;

    CREATE TABLE account (
        id          INTEGER PRIMARY KEY,
        provider_id TEXT NOT NULL REFERENCES provider(id),
        hash        TEXT NOT NULL DEFAULT '',
        label       TEXT,
        UNIQUE (provider_id, hash)
    ) STRICT;

    CREATE TABLE project (
        id   INTEGER PRIMARY KEY,
        key  TEXT NOT NULL UNIQUE,
        path TEXT,
        name TEXT NOT NULL
    ) STRICT;

    CREATE TABLE model (
        id           INTEGER PRIMARY KEY,
        provider_id  TEXT NOT NULL REFERENCES provider(id),
        raw_id       TEXT NOT NULL,
        canonical    TEXT NOT NULL,
        family       TEXT NOT NULL,
        display_name TEXT NOT NULL,
        UNIQUE (provider_id, raw_id)
    ) STRICT;

    CREATE TABLE session (
        id                   INTEGER PRIMARY KEY,
        product_id           TEXT NOT NULL REFERENCES product(id),
        external_id          TEXT NOT NULL,
        account_id           INTEGER NOT NULL REFERENCES account(id),
        account_source       TEXT NOT NULL DEFAULT 'telemetry',
        telemetry_source_id  TEXT NOT NULL REFERENCES telemetry_source(id),
        project_id           INTEGER REFERENCES project(id),
        surface_id           TEXT REFERENCES surface(id),
        kind                 TEXT NOT NULL DEFAULT 'main',
        parent_external_id   TEXT,
        root_external_id     TEXT,
        parent_session_id    INTEGER REFERENCES session(id) ON DELETE SET NULL,
        root_session_id      INTEGER REFERENCES session(id) ON DELETE SET NULL,
        cwd                  TEXT,
        client_version       TEXT,
        started_at           INTEGER,
        last_activity_at     INTEGER,
        observed_ended_at    INTEGER,
        reported_cost_micros INTEGER,
        compaction_count     INTEGER NOT NULL DEFAULT 0,
        UNIQUE (product_id, external_id)
    ) STRICT;
    CREATE INDEX idx_session_project ON session(project_id);
    CREATE INDEX idx_session_account ON session(account_id);
    CREATE INDEX idx_session_activity ON session(last_activity_at);
    CREATE INDEX idx_session_started ON session(started_at);
    CREATE INDEX idx_session_parent ON session(parent_session_id);
    CREATE INDEX idx_session_unresolved_parent ON session(parent_external_id)
        WHERE parent_session_id IS NULL AND parent_external_id IS NOT NULL;

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
        product_id               TEXT NOT NULL REFERENCES product(id),
        request_key              TEXT NOT NULL,
        api_request_id           TEXT,
        session_id               INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
        agent_key                TEXT,
        model_id                 INTEGER NOT NULL REFERENCES model(id),
        requested_at             INTEGER NOT NULL,
        uncached_input_tokens    INTEGER,
        output_tokens            INTEGER NOT NULL,
        cache_read_tokens        INTEGER,
        cache_creation_tokens    INTEGER,
        reasoning_output_tokens  INTEGER,
        cache_creation_5m_tokens INTEGER,
        cache_creation_1h_tokens INTEGER,
        logical_input_tokens     INTEGER GENERATED ALWAYS AS
            (COALESCE(uncached_input_tokens, 0) + COALESCE(cache_read_tokens, 0) + COALESCE(cache_creation_tokens, 0)) VIRTUAL,
        usage_extra              TEXT,
        normalization            TEXT NOT NULL,
        completeness             TEXT NOT NULL DEFAULT 'complete',
        speed                    TEXT,
        stop_reason              TEXT,
        source_cost_micros       INTEGER,
        telemetry_source_id      TEXT NOT NULL REFERENCES telemetry_source(id),
        origin_file_id           INTEGER,
        origin_location          INTEGER,
        first_ingested_at        INTEGER NOT NULL,
        UNIQUE (product_id, request_key)
    ) STRICT;
    CREATE INDEX idx_request_time ON model_request(requested_at);
    CREATE INDEX idx_request_session_time ON model_request(session_id, requested_at);
    CREATE INDEX idx_request_model_time ON model_request(model_id, requested_at);
    CREATE INDEX idx_request_api_id ON model_request(api_request_id) WHERE api_request_id IS NOT NULL;

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
        source_id        TEXT NOT NULL REFERENCES telemetry_source(id),
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

    CREATE TABLE quota_pool (
        id          INTEGER PRIMARY KEY,
        provider_id TEXT NOT NULL REFERENCES provider(id),
        account_id  INTEGER NOT NULL REFERENCES account(id),
        pool_key    TEXT NOT NULL,
        plan_type   TEXT,
        UNIQUE (account_id, pool_key)
    ) STRICT;

    CREATE TABLE quota_window (
        id               INTEGER PRIMARY KEY,
        pool_id          INTEGER NOT NULL REFERENCES quota_pool(id) ON DELETE CASCADE,
        window_key       TEXT NOT NULL,
        duration_minutes INTEGER,
        UNIQUE (pool_id, window_key)
    ) STRICT;

    CREATE TABLE quota_cycle (
        id                INTEGER PRIMARY KEY,
        window_id         INTEGER NOT NULL REFERENCES quota_window(id) ON DELETE CASCADE,
        resets_at         INTEGER,
        first_observed_at INTEGER NOT NULL,
        last_observed_at  INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX idx_cycle_window ON quota_cycle(window_id, resets_at);

    CREATE TABLE quota_snapshot (
        id                  INTEGER PRIMARY KEY,
        window_id           INTEGER NOT NULL REFERENCES quota_window(id) ON DELETE CASCADE,
        cycle_id            INTEGER NOT NULL REFERENCES quota_cycle(id) ON DELETE CASCADE,
        utilization_pct     REAL NOT NULL,
        resets_at           INTEGER,
        observed_at         INTEGER NOT NULL,
        last_confirmed_at   INTEGER NOT NULL,
        telemetry_source_id TEXT NOT NULL REFERENCES telemetry_source(id),
        origin_session_id   INTEGER REFERENCES session(id) ON DELETE SET NULL,
        authority           TEXT NOT NULL,
        -- How many confirmations extended the span in which this value was known, and the longest pause between two of them.
        -- The span alone is enough to know the value, because a utilization never falls inside a cycle, but it does not say how
        -- often the value was actually observed. Both are lower-bound style records: a confirmation that falls inside the span
        -- cannot be told from a reread and is not counted.
        confirmations           INTEGER NOT NULL DEFAULT 1,
        max_confirmation_gap_ms INTEGER NOT NULL DEFAULT 0,
        UNIQUE (window_id, cycle_id, utilization_pct, authority)
    ) STRICT;
    CREATE INDEX idx_snapshot_window_time ON quota_snapshot(window_id, last_confirmed_at);
    CREATE INDEX idx_snapshot_cycle ON quota_snapshot(cycle_id, observed_at);

    -- A user's statement that the activity of a provider's sessions which name no account, within a period, belongs to one
    -- account. It is metadata beside the sessions and never changes them. Periods of one provider never overlap, which
    -- AccountAssociationStore enforces transactionally.
    CREATE TABLE account_association (
        id             INTEGER PRIMARY KEY,
        provider_id    TEXT NOT NULL REFERENCES provider(id),
        account_id     INTEGER NOT NULL REFERENCES account(id),
        effective_from INTEGER NOT NULL,
        effective_to   INTEGER,
        note           TEXT NOT NULL DEFAULT '',
        created_at     INTEGER NOT NULL,
        updated_at     INTEGER NOT NULL,
        CHECK (effective_to IS NULL OR effective_to > effective_from)
    ) STRICT;
    CREATE INDEX idx_account_association_time ON account_association(provider_id, effective_from, effective_to);

    CREATE TABLE price_rate (
        id                         INTEGER PRIMARY KEY,
        provider_id                TEXT NOT NULL REFERENCES provider(id),
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
        UNIQUE (provider_id, model_key, effective_from, prompt_min, speed)
    ) STRICT;
    CREATE INDEX idx_price_lookup ON price_rate(provider_id, model_key, speed, effective_from);

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
    CREATE INDEX idx_issue_time ON ingest_issue(at);

    -- Subscription-capacity metadata that is not derived from transcript logs.
    --
    -- Raw telemetry stays where it is. These tables describe what a person says about their own
    -- subscriptions, and which explicitly labelled measurement intervals they ran. Keeping the
    -- manual annotations separate from provider observations is what allows "observed" and
    -- "estimated" to remain distinguishable, and lets a rebuild of transcript-derived tables leave
    -- the annotations and quota history intact.
    --
    -- A plan assignment covers the half-open interval [effective_from, effective_to). Overlaps for
    -- one account are rejected by PlanHistoryStore; the unique index makes an exact-start duplicate
    -- impossible even if two writers race. SQLite has no built-in range-exclusion constraint, so the
    -- remaining overlap rule is enforced transactionally in Swift.
    --
    -- A plan key of NULL means "unknown or unspecified". It is a fact, not a guess, and no capacity
    -- comparison is ever produced for it.
    CREATE TABLE plan_assignment (
        id             INTEGER PRIMARY KEY,
        provider_id    TEXT NOT NULL REFERENCES provider(id),
        account_id     INTEGER NOT NULL REFERENCES account(id),
        plan_key       TEXT,
        account_label  TEXT,
        effective_from INTEGER NOT NULL,
        effective_to   INTEGER,
        provenance     TEXT NOT NULL DEFAULT 'manual',
        note           TEXT NOT NULL DEFAULT '',
        created_at     INTEGER NOT NULL,
        updated_at     INTEGER NOT NULL,
        CHECK (effective_to IS NULL OR effective_to > effective_from)
    ) STRICT;
    CREATE INDEX idx_plan_assignment_account_time
        ON plan_assignment(account_id, effective_from, effective_to);
    CREATE UNIQUE INDEX idx_plan_assignment_start
        ON plan_assignment(provider_id, account_id, effective_from);

    CREATE TABLE plan_price (
        provider_id         TEXT NOT NULL REFERENCES provider(id),
        plan_key            TEXT NOT NULL,
        monthly_price_micros INTEGER NOT NULL,
        currency            TEXT NOT NULL DEFAULT 'USD',
        effective_from      INTEGER NOT NULL,
        origin              TEXT NOT NULL DEFAULT 'user',
        note                TEXT,
        PRIMARY KEY (provider_id, plan_key, effective_from)
    ) STRICT;

    CREATE TABLE capacity_measurement (
        id                  INTEGER PRIMARY KEY,
        provider_id         TEXT NOT NULL REFERENCES provider(id),
        account_id          INTEGER NOT NULL REFERENCES account(id),
        pool_key            TEXT NOT NULL,
        window_key          TEXT NOT NULL,
        window_minutes      INTEGER,
        plan_assignment_id  INTEGER REFERENCES plan_assignment(id) ON DELETE SET NULL,
        plan_key            TEXT,
        account_label       TEXT,
        label               TEXT NOT NULL,
        note                TEXT NOT NULL DEFAULT '',
        started_at          INTEGER NOT NULL,
        ended_at            INTEGER,
        state               TEXT NOT NULL DEFAULT 'open',
        created_at          INTEGER NOT NULL,
        updated_at          INTEGER NOT NULL,
        CHECK (ended_at IS NULL OR ended_at > started_at)
    ) STRICT;
    CREATE INDEX idx_capacity_measurement_window_time
        ON capacity_measurement(account_id, pool_key, window_key, started_at);
    CREATE UNIQUE INDEX idx_capacity_measurement_open
        ON capacity_measurement(account_id, pool_key, window_key)
        WHERE ended_at IS NULL;

    CREATE INDEX idx_snapshot_observed ON quota_snapshot(observed_at);
    """
}
