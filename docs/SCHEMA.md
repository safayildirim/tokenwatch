# Database schema and migrations

The database is `~/Library/Application Support/ClaudeUsageMonitor/usage.sqlite` (SQLite, WAL mode, `STRICT` tables, foreign keys on). The authoritative definition is `Sources/UsageCore/Storage/Schema.swift`.

## Conventions

* Every timestamp is **UTC milliseconds** (`INTEGER`). Nothing calendar-based is stored.
* Token counts are integers; categories are never merged.
* Money: source-reported costs in micro-USD; price rates in micro-USD per million tokens, so `tokens × rate` is an exact count of pico-USD.
* Identities are stable and natural: `(source_id, external_id)` for sessions, `(source_id, request_key)` for requests.

## Tables

| Table | Purpose | Key constraints |
|---|---|---|
| `usage_source` | One row per source adapter | PK `id` |
| `project` | Project (working directory) per source | `UNIQUE(source_id, key)`; `key` is Claude Code's encoded folder name |
| `model` | Raw model id → canonical key, family, display name | PK `id` (raw) |
| `session` | Session metadata: project, application, working directory, client version, first and last activity, **observed** end time, Claude Code's own reported cost | `UNIQUE(source_id, external_id)`; `parent_session_id` reserved for sources that expose lineage |
| `agent` | Sub-agents seen within a session (first/last seen) | `UNIQUE(session_id, external_id)`, cascades with the session |
| `model_request` | **The source of truth**: one row per distinct model request with the raw token categories | `UNIQUE(source_id, request_key)`; FK to session and model; generated column `logical_input_tokens` |
| `session_reported_model_cost` | Per-model lines of the source's own cost summary | PK `(session_id, model_raw)` |
| `source_file` | **Durable checkpoints** per log file: device, inode, size, mtime, consumed byte offset (always a line boundary), hash of the first ≤4 KB, counters, status, last error | `UNIQUE(source_id, path)` |
| `quota_snapshot` | Authoritative quota history | `UNIQUE(provider, window_kind, observed_at)` |
| `price_rate` | Dated rate cards: model, effective-from, prompt-size tier, speed, five rates, origin (`builtin` or `user`) | `UNIQUE(model_key, effective_from, prompt_min, speed)` |
| `setting` | Preferences (one JSON document) and small state values | PK `key` |
| `alert_fired` | Alerts already delivered, for deduplication | PK `key` |
| `ingest_issue` | Capped ring (500) of collection problems for the Diagnostics page | |

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

`PRAGMA user_version` holds the schema version. `Schema.migrations` is an ordered, **append-only** list; each migration runs in its own transaction at launch for every version above the stored one. To change the schema, append a new migration; never edit an old one. The project does not need backward compatibility, but databases created by older builds still migrate forward. Built-in prices are reinstalled automatically when the catalog's fingerprint changes, leaving user-defined rows alone.

## Retention and deletion

* `purge(olderThan:)` removes old requests, then orphaned sessions and projects, old quota snapshots and old alert records. It runs daily when a retention period is set.
* The importer applies the same cutoff to everything it reads, so purged history does not return when a log file is scanned again.
* "Delete all collected data" empties every table (price cards excepted, since they are not user data) and `VACUUM`s. The original Claude Code files are never touched.
