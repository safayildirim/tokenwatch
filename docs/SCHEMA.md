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
| `quota_window` | A window of a pool, keyed by length or by a model-scoped identity and length | `UNIQUE(pool_id, window_key)` |
| `quota_cycle` | One period between resets | |
| `quota_snapshot` | A reported utilization in a cycle, with first-observed and last-confirmed times, source, originating session and authority | `UNIQUE(window_id, cycle_id, utilization_pct, authority)` |
| `plan_assignment` | A half-open period `[effective_from, effective_to)` in which one account was on one subscription plan. `plan_key` may be `NULL` (unknown) and `effective_to` may be `NULL` (open) | FK to `account`; no overlapping periods per account (enforced transactionally); `UNIQUE(provider_id, account_id, effective_from)` |
| `plan_price` | Dated monthly **user** prices per plan. A user price at or before a date overrides the registry reference; the registry supplies the reference value itself | PK `(provider_id, plan_key, effective_from)` |
| `capacity_measurement` | An optional labelled measurement period over existing quota readings and local work. Stores the plan captured at start and an `open` / `closed` / `abandoned` state | `plan_assignment_id` FK with `ON DELETE SET NULL`; at most one open period per `(account, pool, window)` |
| `price_rate` | Dated rate cards per provider and model | `UNIQUE(provider_id, model_key, effective_from, prompt_min, speed)` |
| `setting`, `alert_fired`, `ingest_issue` | Preferences, delivered alerts, a capped ring of collection problems | |

Indexes cover the analytical paths: `model_request(requested_at)`, `(session_id, requested_at)`, `(model_id, requested_at)`, `(api_request_id)`, the session indexes on project, activity and start, `quota_snapshot(observed_at)`, and the capacity timeline and measurement indexes.

`plan_assignment`, `plan_price` and `capacity_measurement` are **manual annotations over observations**, not observations themselves. They never feed token totals or provider quota percentages. See [CAPACITY.md](CAPACITY.md).

## Integrity guarantees

* **Atomic ingestion.** A batch of observations and the checkpoint offset that produced them commit in one `BEGIN IMMEDIATE` transaction. A crash leaves the database exactly at a checkpoint.
* **Idempotent operations.** Every write is an upsert with the commutative merge rules described in [TOKEN-ACCOUNTING.md](TOKEN-ACCOUNTING.md). Re-reading a file, replaying events, or restarting changes nothing.
* **Immutable observations.** Request rows are only ever merged upward by those rules; they are never edited by aggregation. There are no stored aggregates: every total is a query over `model_request`, so nothing can drift.
* **Reconstructable, as far as the files still exist.** Token usage, sessions, projects and models are derived from the original log files. Claude Code deletes transcripts after 30 days by default, and the database keeps the requests it stored from them: a file that disappears is marked `missing` and its requests stay, across reconciliation and restarts. "Rebuild from source" (Diagnostics) clears the derived tables and re-imports the files that still exist, so it cannot bring back usage whose files are gone; see [Recovery](#recovery). Quota history and manual capacity annotations are **not** transcript-derived, so they are preserved.
* **Foreign keys** are enforced; `PRAGMA foreign_key_check` is part of the tests.
* **Concurrency.** One serialized writer connection plus four read-only connections. WAL means readers never block, and a test runs three readers against a writer committing 60 batches and asserts no reader error and a never-shrinking count.

## Recovery

* A `clean_shutdown` marker is cleared on launch and set on a graceful quit. If it is missing at launch (crash, power loss, force quit), `PRAGMA quick_check` runs before the database is used.
* If the file is not a database or fails the check, it is **moved aside** as `usage.sqlite.corrupt-<epoch>` (with its `-wal` and `-shm`), a fresh database is created, and the files that still exist are re-imported automatically. The moved file is **never deleted** by the app, because it may be the only copy of usage whose transcripts are gone. Diagnostics shows its path and says that such usage is only there. It can often be salvaged with `sqlite3 usage.sqlite.corrupt-<epoch> .recover > recovered.sql`.
* **Before "Rebuild from source"**, the app counts the stored requests whose source file no longer exists and names that number in the confirmation, then writes a complete copy of the database with `VACUUM INTO` to `backups/usage-before-rebuild-<UTC time>.sqlite` next to the database. `VACUUM INTO` copies the committed state in one transaction, including what is still only in the write-ahead log, so the copy opens on its own. The folder is mode `0700` and each copy `0600`, and only the **three newest** copies are kept, which bounds the disk space and the number of copies of the metadata. If the copy cannot be written, nothing is deleted. To restore one, quit the app, move `usage.sqlite`, `usage.sqlite-wal` and `usage.sqlite-shm` aside, and copy the backup to `usage.sqlite`.
* **"Delete all collected data"** makes no copy, because it is a request to remove the data. Its confirmation names the requests that cannot be imported again. Corruption recovery also makes no copy, because the fresh database holds only what the files contain and the old one is kept as described above.
* Lock contention is absorbed by an 8 s busy timeout and by the retry policy. A full disk is detected (`SQLITE_FULL`) and retried on a five-minute backoff with a clear message.

## Migration strategy

`PRAGMA user_version` holds the schema version. `Schema.migrations` is an ordered, **append-only** list; each migration runs in its own transaction at launch for every version above the stored one. The multi-provider redesign and the subscription-capacity tables were folded into the single initial migration in place, because the application was still in development and had no data to preserve (a database from an earlier build must be deleted). From the first release on, a schema change is a new appended migration. Built-in prices are reinstalled automatically when the catalog's fingerprint changes, leaving user-defined rows alone.

## Retention and deletion

* `purge(olderThan:)` removes old requests, then orphaned sessions and projects, old quota snapshots and old alert records. It runs daily when a retention period is set.
* The importer applies the same cutoff to everything it reads, so purged history does not return when a log file is scanned again.
* "Delete all collected data" empties every observation table, capacity measurements and plan assignments, then `VACUUM`s. Price cards and plan price overrides remain because they are configuration, not user data. The original Claude Code and Codex files are never touched.
