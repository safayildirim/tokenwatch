# Validation and test results

## 1. Automated tests: 254 tests, 0 failures

`swift test` (about 100 seconds). Fixtures use the real transcript format with every piece of conversation text replaced by a placeholder.

| Area | Suite (tests) | What it proves |
|---|---|---|
| Token accounting | `TokenMathTests` (4), `ObservationMergeTests` (5), `ModelCatalogTests` (1), `IngestAccountingTests` (15) | Every category is stored, including the 5 m / 1 h split. Derived metrics have exact definitions. Streaming snapshots, zero-usage replays after compaction, duplicate ids in main and sub-agent files, and duplicate observations from two sources each count once. Delivery order does not matter. Multi-model sessions stay separate. Child-agent usage rolls up without double counting. Half-written lines are deferred and never lost. Malformed lines are skipped. A 9 MB line crossing read chunks works. JSON escapes decode. Retention cuts off imports. The merge is verified **commutative, associative and idempotent** over random inputs |
| Session discovery and lifecycle | `AdapterPathTests` (3), `SessionDiscoveryTests` (10), `CollectorLifecycleTests` (6) | Path classification. Concurrent sessions are independent. A resumed session stays one session. Identity and totals survive restarts. Re-import is idempotent. Replaced, truncated and rewritten-in-place files are detected, and history is kept without double counting. A deleted file keeps its data. Unreadable files report a permission error. **Real FSEvents**: history imported at launch, new sessions found live, appends picked up incrementally, ingestion latency under 5 s. Missed events are recovered by reconciliation. One failing source does not stop another. A missing folder is "not found", not an error. A rebuild reproduces identical totals |
| Session status | `SessionStatusTests` (6) | Observed state beats inference. Process exit is an observed end. Activity after an exit means resumed. Thresholds are configurable. A recycled pid is not accepted as a session. The registry monitor records exits |
| Quota | `QuotaEvaluatorTests` (9), `StatusLineSourceTests` (3), `BridgeBinaryTests` (6), `QuotaCoordinatorTests` (6), `RetryPolicyTests` (4) | Authoritative values, remaining, countdown. Unavailable is never zero. Freshness ageing. A reset window is "unknown", not zero. A newer window outranks an older closed one. Unverified values are excluded unless enabled and never authoritative. The **real `ccu-statusline` binary**: stores only rate limits (secrets in the input are never written), keeps the old observation time on re-render, writes nothing without `rate_limits`, survives garbage input and still runs the chained command with the original input, and cannot escape its folder. 50 M tokens of local usage never produce a percentage. Account usage can far exceed local activity. Backoff growth, cap, jitter and `Retry-After` |
| Persistence | `PersistenceTests` (13) | Migrations, WAL, foreign keys, uniqueness, STRICT types, transaction rollback, observations and checkpoint committing together, **concurrent readers and writer** with no errors, **corruption quarantine and recovery**, integrity check after an unclean shutdown, settings clamping, purge, erase, and **randomized equivalence of the SQL merge and the Swift merge** |
| Analytics and cost | `CostEstimationTests` (8), `CalendarBoundaryTests` (7), `AnalyticsQueryTests` (7) | Each category priced at its own exact rate. Prompt-size tier boundary. Unknown models unpriced, never guessed. Fast mode. Price changes apply only from their date. **Local midnight, DST (25-hour day), +5:30 zones**, half-open periods, week and month boundaries. Breakdowns sum to the total. Filters. Timeline bucketing. **Account utilization shown next to, never merged with, local shares** |
| Alerts and installer | `AlertEngineTests` (12), `StatusLineInstallerTests` (8) | Threshold once per window, highest only when several are skipped, dedup survives restart, stale or unverified never alert, refreshing stale data is silent, reset once, stale-feed alert once, failure alert once per episode. The installer preserves the rest of `settings.json` byte for byte, chains and restores an existing status line, is idempotent, never touches invalid JSON, and is not fooled by `"statusLine"` inside a string |
| Export and privacy | `ExportTests` (8), `PrivacyTests` (2), `SourceVerifierTests` (2) | Exact numbers and decimals, metadata for every column, valid JSON, CSV escaping and formula neutralization, ranges, streaming 5,000 rows. **Secrets planted in prompts, replies, tool output and titles never appear in the database file, its WAL, or any export.** The independent recount agrees, and detects tampering |
| UI state and flows | `AppModelTests` (14), `FormatterTests` (5), `RangeAndFilterTests` (4) | Empty database and missing Claude folder states. History import and live sessions appear. Menu bar text in every display mode, dashes for unknown windows, a stale marker, no percentage from tokens. Navigation. Refresh coalescing. Settings persistence and retention. Disabling a source. **A hidden app skips heavy queries but keeps the menu bar accurate; showing a window brings summaries up to date** |
| UI rendering | `RenderTests` (6) | The real views are drawn offscreen and the pixels inspected. All six quota states render and **look different from each other**. Every dashboard page renders with real data, the session page and the menu bar popover in light and dark, empty states and settings render |

### Added by the multi-provider refactor (80 tests)

| Area | Suite | What it proves |
|---|---|---|
| Codex classification and discovery | `CodexClassificationTests`, `CodexDiscoveryTests` | Every `originator` maps to the right product and surface, matched word by word. Active, archived and compressed files are found, `auth.json` and other files never are. File events are routed by location. `$CODEX_HOME` is honoured. A missing folder is "not found". |
| Codex accounting | `CodexAccountingTests`, `CodexSessionTests` | OpenAI's input includes cached tokens and reasoning is part of output. A repeated snapshot is not a response, and two equal responses are two. Usage records are keyed by response id and the same response in two copies counts once. A response without an event is reconstructed from the totals and flagged. A grand-total-only event is reconstructed without double counting. Compactions are counted. The model in effect is used. Unknown models are unpriced. Product, surface and account come from the header, an unidentified account is not guessed, and the **raw account id, user id, instructions and message text never reach the database**. Sub-agent and review threads are linked to parent and root, including when the parent arrives later. **A fork does not recount its parent's history, and its copied quota snapshots are ignored.** |
| Codex ingestion | `CodexIngestTests`, `ZstdReaderTests` (5) | Compressed and plain files give the same result, a compressed file is read once, a damaged one keeps what was decoded and is not retried until it changes. A growing file is read again from the top without double counting. An unfinished last line is picked up later. Unknown record types, extra fields, null `info` and damaged lines are tolerated. The retention floor applies. Claude and Codex coexist and filter apart. The decoder is checked against the reference `zstd` tool (including a multi-frame file, small buffers, a truncated and a corrupt file). |
| OpenAI quota | `OpenAIQuotaTests` | Pools per account with windows identified by length. A weekly-only plan gets no invented 5-hour window. Codex and Work share one pool, two accounts and the unassigned account are three pools and are never summed. ChatGPT Chat is unobservable and never shows a figure. Out-of-order delivery cannot replace a newer snapshot. Cycles tolerate reset jitter and a new cycle is recognized. Freshness ages, a reset window is unknown rather than zero. Another `limit_id` is another pool. Claude and OpenAI pools stay separate in one database. |
| Alerts | `AlertEngineTests` (+5) | Two accounts alert independently, different pools do not share identity, a shared pool alerts once however many products use it, a new cycle alerts again, a stale feed only alerts for a provider in use. |
| Verification | `CodexVerifierTests` | The independent recount agrees on a mixed history (usage records, events, a fork, a missing event), detects altered and deleted data, and compares Codex's own figures as evidence only. |
| Analytics | `OpenAIAnalyticsTests` | Filters by product, surface, account, source and provider. Coverage says which categories were not reported. Sums over models, sessions, projects and days all equal the total, and reasoning is never added to output. Model rows keep providers apart. A session's quota-window context uses only its own account's windows. |
| Architecture | `ArchitectureIsolationTests`, `FutureProviderTests` | **No provider name appears in the shared core** outside designated files. The schema has no provider-specific columns. The registry is consistent. **An invented provider with a different token format flows through the real collector, writer, analytics, pricing, export, quota and alert code.** |
| Concurrency | `ConcurrentProvidersTests` | Both providers are collected live while files grow, restarts and a reopened database change nothing, there are no duplicate requests, and a corrupt Codex file does not degrade Claude's health (this test found and fixed a bug where one source's failing file marked every source degraded). |
| UI | `AppModelTests` (+7), `ViewLogicTests` | Menu bar modes per provider, side by side, highest utilization (a comparison, not a sum), the choice survives a restart, stale marks. Active sessions per provider. The dashboard scope narrows dashboard figures but not the menu bar and drops incompatible choices. |

## 2. Validation against the real installation

The Claude figures below were measured on the previous, Claude-only build and **re-run on the multi-provider build**: `ccu verify --provider claude` is consistent (793 files, 86,614 requests, 170 sessions; uncached input 177,106, output 59,815,391, cache read 27,231,882,256, cache creation 386,054,348, all equal to the independent recount).

### OpenAI (Codex) on the real data

`ccu verify --provider openai`: 232 sessions, input 494,170,138, cached 473,721,088, output 1,846,647, reasoning 707,205, **all equal to the independent recount**, and 225 of Codex's own 232 thread totals agree exactly. Every difference from Codex's own figure is explained (usage records without events, and one fork). See [OPENAI-CODEX](OPENAI-CODEX.md).

### Original Claude validation

All performed on the real Claude history of the machine (793 files, 4.75 GB).

All performed on the real Claude history of the machine (793 files, 4.75 GB).

### Token totals agree with the original records

`ccu verify` decodes each source file again with a **different parser** (Foundation's JSON decoder) and a **different finalization rule** (the observation with the largest output per message id) up to the exact byte the importer consumed, and compares per session.

```
files_checked=792 sessions_checked=169
requests: source=86.107 database=86.107
uncached_input   source=176.092            database=176.092            OK
output           source=59.012.426         database=59.012.426         OK
cache_read       source=27.039.289.760     database=27.039.289.760     OK
cache_creation   source=384.368.878        database=384.368.878        OK
naive sum of every line (the wrong way): output=168.248.860 cache_read=65.963.276.600
RESULT: consistent
```

An earlier, fully independent check (a separate Python script) also matched on all four categories. Adding up every log line would have overstated output **2.85×** and cache reads **2.44×**.

### Against Claude's own statistics

Claude Code records a cost summary per session. Compared with the estimate from published list prices for 164 sessions: **median deviation 0.4 %**, total within 7.4 % ($8,479 estimated vs $7,895 recorded). The difference comes from Claude Code's summary being a snapshot taken mid-session in some sessions, and from price assumptions inside Claude Code. The estimate is labelled as an estimate everywhere.

### Restart and crash recovery

The app was killed with `kill -9` **mid-import** (52,796 of ~86,000 requests committed, 532 of 793 files done, clean-shutdown marker still 0), relaunched, killed again, and relaunched. Result: all 793 files complete, `integrity_check` ok, 0 foreign-key violations, and the independent recount **consistent**, with 86,233 requests in both the source and the database. No duplicates, no gaps.

### Concurrent sessions and live collection

Six simultaneous simulated sessions with sub-agents and streaming duplicates wrote 4,173 lines (1,391 requests) in 30 s. The database matched the generated totals exactly on all four categories, with 6 sessions, 18 agents and 276 child-agent requests, 0.88 s after the last write. See [PERFORMANCE](PERFORMANCE.md).

### Launch at login

`SMAppService` registration was exercised on the built app: `--login-item enable` registered it with the correct bundle identifier and path (visible in the background-task-management database), `disable` unregistered it. It was left **disabled**; turn it on from Settings → General. The optional LaunchAgent script is the alternative.

### Privacy and network

* `lsof -i` for the running process: no network sockets.
* The privacy test described above.
* No file the app writes contains conversation text (checked against the database, WAL and exports).

### The interface

Every page, the popover, session details and settings were rendered by the real app against real data in light and dark and reviewed. Defects found and fixed this way: an ambiguous cost format (`$5.586` in a locale that groups thousands with a dot), model colors falling back to gray because project colors had consumed the palette, and a Dock icon lingering after the Settings window closed.

## 3. Acceptance criteria

| # | Criterion | Status |
|---|---|---|
| 1 | Builds and runs as a native macOS application | Met. `scripts/build-app.sh`, signed `.app`, installed and running |
| 2 | Starts at login, monitors without a terminal | Met. Login item registration verified; also a LaunchAgent. Left disabled for you to choose |
| 3 | Existing local sessions are imported | Met. 170 sessions, 86 K requests on first launch |
| 4 | New sessions detected automatically | Met. FSEvents, plus reconciliation |
| 5 | Concurrent sessions tracked independently | Met. Load test and unit tests |
| 6 | Input, output, cache-read, cache-creation accurately recorded | Met. Exact against an independent recount |
| 7 | Deduplicated across restarts and sources | Met. Crash test, idempotent re-import, source-merge test |
| 8 | Totals verifiable against original records | Met. `ccu verify` and Diagnostics → Verify |
| 9 | Five-hour and weekly quota shown when authoritative data is available | **Implemented and tested with the documented payload; not yet seen with your live account.** It needs the helper installed (one click) and a terminal Claude Code session |
| 10 | Missing quota identified, not fabricated | Met. "Unavailable", dashes, no token-based percentage anywhere |
| 11 | Menu bar shows activity and usage | Met |
| 12 | Dashboard supports session, model and project analysis | Met |
| 13 | History survives restarts | Met |
| 14 | Imports and live updates do not noticeably impact macOS | Met. 5.9 s and 28 MB for 4.75 GB; about 0.05 to 0.25 % CPU idle |
| 15 | Tests cover critical accounting and lifecycle | Met. 254 tests |
| 16 | Long runs without leaks or duplicates | Evidence over 10 minutes (flat memory) and idempotence tests; a multi-day soak was not run |
| 17 | Documented install and build | Met. README |

## 4. Not verified, stated plainly

* **A live `rate_limits` payload from your subscription.** The helper, evaluator, coordinator and alerts are verified end to end against the documented JSON, but I did not install the helper into your Claude Code settings or send a real message to produce one, since that would change your configuration and use your account.
* **Multi-day soak and sleep/wake on hardware.** The wake path (`NSWorkspace.didWakeNotification` triggering reconciliation) is covered by the missed-events test, which exercises the same reconciliation, but a real laptop sleep was not performed.
* **User-notification delivery.** The alert logic is tested; delivery through `UNUserNotificationCenter` needs permission granted in System Settings the first time it is enabled, and was not exercised.
* **The sidebar of the dashboard window** renders as an empty panel in the offscreen snapshots (an artefact of rendering the system sidebar material outside a screen); its structure and navigation are covered by the state tests.
