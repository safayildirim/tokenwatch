# Database schema and migrations

The database is `~/Library/Application Support/Tokenwatch/usage.sqlite` (SQLite, WAL mode, `STRICT` tables, foreign keys on). The authoritative definition is `Sources/UsageCore/Storage/Schema.swift`.

## Conventions

* Every timestamp is **UTC milliseconds** (`INTEGER`). Nothing calendar-based is stored.
* Token counts are integers; categories are never merged.
* Money: source-reported costs in micro-USD; price rates in micro-USD per million tokens, so `tokens × rate` is an exact count of pico-USD.
* Identities are stable and natural: `(product_id, external_id)` for sessions, `(product_id, request_key)` for requests. Two sources that describe one request share its key, so it is counted once.

## Tables

| Table | Purpose | Key constraints |
|---|---|---|
| `provider`, `product`, `surface` | The registry, seeded from `ProviderRegistry` on every launch | PK `id` |
| `telemetry_source`, `telemetry_source_product` | Collection mechanisms and the products each covers, with capability flags and stated limitations | PK `id` |
| `pool_definition`, `pool_membership` | Quota pools and the products that draw on each | PK `(provider_id, pool_key)` |
| `account` | An identity at a provider. `hash` is a one-way digest (never the raw identifier); `''` is the explicit *unassigned* account | `UNIQUE(provider_id, hash)` |
| `project` | A project. The key is a working-directory path when known, so Claude and Codex sessions of one folder share it | `UNIQUE(key)` |
| `model` | Raw model id → canonical key, family, display name, per provider | `UNIQUE(provider_id, raw_id)` |
| `session` | Product, account, surface, kind (main / sub-agent / review), parent and root, working directory, client version, first and last activity, observed end, source-reported cost, compaction count | `UNIQUE(product_id, external_id)` |
| `agent` | Sub-agents seen within a session | `UNIQUE(session_id, external_id)` |
| `model_request` | **The source of truth**: one row per distinct request with nullable token categories, `reasoning_output_tokens`, `usage_extra`, `normalization`, `completeness` | `UNIQUE(product_id, request_key)`; generated column `logical_input_tokens` |
| `session_reported_model_cost` | Per-model lines of a source's own cost summary | PK `(session_id, model_raw)` |
| `source_file` | **Durable checkpoints** per file (inode, size, mtime, consumed offset in decompressed bytes for compressed files, head hash, counters, status) | `UNIQUE(source_id, path)` |
| `quota_pool` | An allowance of one account | `UNIQUE(account_id, pool_key)` |
| `quota_window` | A window of a pool, keyed by length | `UNIQUE(pool_id, window_key)` |
| `quota_cycle` | One period between resets | |
| `quota_snapshot` | A reported utilization in a cycle, with first-observed and last-confirmed times, source, originating session and authority | `UNIQUE(window_id, cycle_id, utilization_pct, authority)` |
| `price_rate` | Dated rate cards per provider and model | `UNIQUE(provider_id, model_key, effective_from, prompt_min, speed)` |
| `setting`, `alert_fired`, `ingest_issue` | Preferences, delivered alerts, a capped ring of collection problems | |

Indexes cover the analytical paths: `model_request(requested_at)`, `(session_id, requested_at)`, `(model_id, requested_at)`, `(api_request_id)`, and the session indexes on project, activity and start.

## Integrity guarantees

* **Atomic ingestion.** A batch of observations and the checkpoint offset that produced them commit in one `BEGIN IMMEDIATE` transaction. A crash leaves the database exactly at a checkpoint.
* **Idempotent operations.** Every write is an upsert with the commutative merge rules described in [TOKEN-ACCOUNTING.md](TOKEN-ACCOUNTING.md). Re-reading a file, replaying events, or restarting changes nothing.
* **Immutable observations.** Request rows are only ever merged upward by those rules; they are never edited by aggregation. There are no stored aggregates: every total is a query over `model_request`, so nothing can drift.
* **Reconstructable.** Everything except quota history, settings and alert state is derived from the original log files. "Rebuild from source" (Diagnostics) clears the derived tables and re-imports; a corrupted database is handled the same way automatically.
* **Foreign keys** are enforced; `PRAGMA foreign_key_check` is part of the tests.
* **Concurrency.** One serialized writer connection plus four read-only connections. WAL means readers never block, and a test runs three readers against a writer committing 60 batches and asserts no reader error and a never-shrinking count.

## Recovery

* A `clean_shutdown` marker is cleared on launch and set on a graceful quit. If it is missing at launch (crash, power loss, force quit), `PRAGMA quick_check` runs before the database is used.
* If the file is not a database or fails the check, it is **moved aside** as `usage.sqlite.corrupt-<epoch>` (with its `-wal` and `-shm`), a fresh database is created, and the history is re-imported automatically. Diagnostics reports the recovery.
* Lock contention is absorbed by an 8 s busy timeout and by the retry policy. A full disk is detected (`SQLITE_FULL`) and retried on a five-minute backoff with a clear message.

## Migration strategy

`PRAGMA user_version` holds the schema version. `Schema.migrations` is an ordered, **append-only** list; each migration runs in its own transaction at launch for every version above the stored one. The multi-provider redesign edited the single initial migration in place, because the application was still in development and had no data to preserve (a database from the Claude-only build must be deleted). From the first release on, a schema change is a new appended migration. Built-in prices are reinstalled automatically when the catalog's fingerprint changes, leaving user-defined rows alone.

## Retention and deletion

* `purge(olderThan:)` removes old requests, then orphaned sessions and projects, old quota snapshots and old alert records. It runs daily when a retention period is set.
* The importer applies the same cutoff to everything it reads, so purged history does not return when a log file is scanned again.
* "Delete all collected data" empties every table (price cards excepted, since they are not user data) and `VACUUM`s. The original Claude Code files are never touched.
