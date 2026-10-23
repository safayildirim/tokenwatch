# Validation and test results

## 1. Automated tests: 413 tests (`make test`, 2026-10-23: 412 passed, 0 failures, 1 opt-in test skipped)

`swift test --skip UsageUITests` runs **338 core tests in about 37 seconds, with 0 failures and 1 skipped** (the opt-in real-installation check). The UI target compiles all 64 `UsageUITests`; the full UI suite was not rerun for this change. Fixtures use the real transcript format with every piece of conversation text replaced by a placeholder.

| Area | Suite (tests) | What it proves |
|---|---|---|
| Token accounting | `TokenMathTests` (4), `ObservationMergeTests` (5), `ModelCatalogTests` (1), `IngestAccountingTests` (15) | Every category is stored, including the 5 m / 1 h split. Derived metrics have exact definitions. Streaming snapshots, zero-usage replays after compaction, duplicate ids in main and sub-agent files, and duplicate observations from two sources each count once. Delivery order does not matter. Multi-model sessions stay separate. Child-agent usage rolls up without double counting. Half-written lines are deferred and never lost. Malformed lines are skipped. A 9 MB line crossing read chunks works. JSON escapes decode. Retention cuts off imports. The merge is verified **commutative, associative and idempotent** over random inputs |
| Session discovery and lifecycle | `AdapterPathTests` (3), `SessionDiscoveryTests` (10), `CollectorLifecycleTests` (6) | Path classification. Concurrent sessions are independent. A resumed session stays one session. Identity and totals survive restarts. Re-import is idempotent. Replaced, truncated and rewritten-in-place files are detected, and history is kept without double counting. A deleted file keeps its data. Unreadable files report a permission error. **Real FSEvents**: history imported at launch, new sessions found live, appends picked up incrementally, ingestion latency under 5 s. Missed events are recovered by reconciliation. One failing source does not stop another. A missing folder is "not found", not an error. A rebuild reproduces identical totals |
| Session status | `SessionStatusTests` (6) | Observed state beats inference. Process exit is an observed end. Activity after an exit means resumed. Thresholds are configurable. A recycled pid is not accepted as a session. The registry monitor records exits |
| Quota | `QuotaEvaluatorTests` (9), `StatusLineSourceTests` (3), `BridgeBinaryTests` (6), `QuotaCoordinatorTests` (6), `RetryPolicyTests` (4) | Authoritative values, remaining, countdown. Unavailable is never zero. Freshness ageing. A reset window is "unknown", not zero. A newer window outranks an older closed one. Unverified values are excluded unless enabled and never authoritative. The **real `tw-statusline` binary**: stores only rate limits (secrets in the input are never written), keeps the old observation time on re-render, writes nothing without `rate_limits`, survives garbage input and still runs the chained command with the original input, and cannot escape its folder. 50 M tokens of local usage never produce a percentage. Account usage can far exceed local activity. Backoff growth, cap, jitter and `Retry-After` |
| Claude local cache | `ClaudeCodeCacheTests` (31), `ClaudeCodeCacheCoordinatorTests` (10), `ClaudeQuotaConnectionTests` (10) | Real cache shape, strict JSON and timestamp/account validation, shared, structured and legacy windows, model scopes with null ids, malformed and unknown fields, duplicate keys, malformed-window skipping, read-only and owner-only file access, symlink/hard-link/directory/FIFO/size rejection, `CLAUDE_CONFIG_DIR` path handling, privacy (no raw account in observations), atomic replacement and re-arming, mtime-only rewrite deduplication, restart recovery, stale readings, reset boundaries, source priority and conflicts without averaging, account-change warning, and source selection for the UI. An architecture guard verifies that the cache reader has no network path. The real installation was read without changing its bytes or modification time |
| Persistence | `PersistenceTests` (13) | Migrations, WAL, foreign keys, uniqueness, STRICT types, transaction rollback, observations and checkpoint committing together, **concurrent readers and writer** with no errors, **corruption quarantine and recovery**, integrity check after an unclean shutdown, settings clamping, purge, erase, and **randomized equivalence of the SQL merge and the Swift merge** |
| Analytics and cost | `CostEstimationTests` (8), `CalendarBoundaryTests` (7), `AnalyticsQueryTests` (7) | Each category priced at its own exact rate. Prompt-size tier boundary. Unknown models unpriced, never guessed. Fast mode. Price changes apply only from their date. **Local midnight, DST (25-hour day), +5:30 zones**, half-open periods, week and month boundaries. Breakdowns sum to the total. Filters. Timeline bucketing. **Account utilization shown next to, never merged with, local shares** |
| Alerts and installer | `AlertEngineTests` (12), `StatusLineInstallerTests` (8) | Threshold once per window, highest only when several are skipped, dedup survives restart, stale or unverified never alert, refreshing stale data is silent, reset once, stale-feed alert once, failure alert once per episode. The installer preserves the rest of `settings.json` byte for byte, chains and restores an existing status line, is idempotent, never touches invalid JSON, and is not fooled by `"statusLine"` inside a string |
| Export and privacy | `ExportTests` (8), `PrivacyTests` (2), `SourceVerifierTests` (2) | Exact numbers and decimals, metadata for every column, valid JSON, CSV escaping and formula neutralization, ranges, streaming 5,000 rows. **Secrets planted in prompts, replies, tool output and titles never appear in the database file, its WAL, or any export.** The independent recount agrees, and detects tampering |
| UI state and flows | `AppModelTests` (22), `FormatterTests` (4), `RangeAndFilterTests` (6) | Empty database and missing Claude folder states. History import and live sessions appear. Menu bar text in every display mode, dashes for unknown windows, a stale marker, no percentage from tokens. Navigation. Refresh coalescing. Settings persistence and retention. Disabling a source. **A hidden app skips heavy queries but keeps the menu bar accurate; showing a window brings summaries up to date** |
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

### Added by the stabilization phase (53 tests)

| Area | Suite | What it proves |
|---|---|---|
| Codex lineage and mixed formats | `CodexLineageTests` (16) | A fork is recognized by what its lines say, so a response the child makes 900 ms after the fork is counted and a slow copy (3 s) is not. Without the parent's file the fork falls back to its time and says so, and the notice is replaced when the file is read again. A fork of a record session repeats response ids and is attributed to the thread that made them, in either read order. A file that mixes event-only and record parts counts every response once, whichever of event and record comes first. A compaction request without an event is counted once, and also when only the marker has it. A thread counter that grew more than its records is reported and not invented. A counter reset invents nothing. Unrelated runs with identical figures are two requests. A response seen by two products of one provider is one request. An active and an archived copy are one session. A changed file format is reported. |
| Quota freshness | `QuotaFreshnessTests` (11), `StatusLineFirstSightTests` (3) | Reading an old file again, touching it, copying it and rebuilding the database never make a reading fresh. Cycles 53 s apart are not merged. A lower reading that arrives later does not replace the higher one of its cycle, and a new cycle does not inherit the old value. Account switches keep both accounts. Future-dated readings are not recorded and a clock moved back gives stale, not new. Claude readings survive restart and rewrite unchanged. The real helper dates a first sight with the transcript's modification time, and does not re-date remaining windows when one drops out at its reset. |
| OpenAI prices | `OpenAIPricingTests` (9) | Published prices applied per category. Reasoning priced once. A price change applies from its day and earlier usage keeps the earlier price. Derived cards are labelled and counted. The 272,000-token boundary. Fast, priority and flex tiers, and an unknown tier is unpriced. A model before its launch, an unlisted name, `codex-auto-review` and a dated snapshot are unpriced. A user price wins and is labelled. The catalog has no duplicates. |
| Reliability | `AcceleratedSoakTests` (1), `LiveLatencyTests` (1) | 45 simulated days with restarts, compression, archiving, a folder outage, forks and damaged lines stay exact. Nine concurrent sessions reached the database in about 0.35 s on the final run. |
| Delivery and start-up | `NotificationServiceTests` (8), `SingleInstanceTests` (3) | Notifications are shown when allowed, permission is asked once, a denial, an app without a bundle and a refusal by macOS are each reported in words. A second copy cannot take the lock, and a crashed holder never keeps a later launch out. |
| Menu bar | `AppModelTests` (+1) | A window that has just reset shows a dash and never the weekly figure in its place. |

### Added by subscription capacity analytics (26 tests)

| Area | Suite | What it proves |
|---|---|---|
| Quota arithmetic and direction | `CapacityTests` | A plan that spends 10 % where the base spends 20 % has 2.0× capacity, never 0.5×. Equal work and equal ratios are stable. Matched cycles are one-to-one. A single pair is provisional and publishes no ratio. Evidence levels require independent cycles, not readings. Outliers are excluded only with enough remaining cycles, and their ids are recorded. |
| Plan attribution and history | `CapacityTests` | Half-open periods, adjacent plans, gaps, spanning overlaps and provider/account isolation. Unknown plans are valid but produce no comparison. A correction changes the period without changing raw snapshots. Identical start times are rejected. Ambiguous histories disable comparisons rather than guessing identity; conflicting labels are a separate explicit identity state. |
| Quota analysis | `CapacityTests` | Five-hour and weekly windows are analyzed separately. A lower reading inside a cycle is skipped, never treated as a reset. A cycle change starts a new sample. A plan change inside an interval, an overlapping pair of cycles, and a cycle that produced eligible intervals for two plans are excluded with explicit reasons. Multiple intervals in one cycle become one sample. |
| Measurements | `CapacityTests` | A measurement uses the reading-to-reading span, not the labelled wall-clock times. It snaps to the surrounding readings, detects a plan edited after capture, and excludes an open measurement as still open. The store requires a plan and a known window, and allows one open measurement per account/pool/window. |
| Rebuild, erase and export | `CapacityTests`, `ExportTests` | A transcript rebuild preserves quota history, plan periods, prices and measurements. Erasing collected data removes measurements and plan assignments but keeps price configuration. Capacity evidence exports with units, methods, exclusions and outlier ids, and carries no conversation text. |
| Determinism and performance | `CapacityPerformanceTests` | A deterministic fixture of 60 independent five-hour cycles, 12,000 requests and two plans produces a 4.0× estimate. One on-demand report takes **0.046 s** in a debug build; the report is bounded by the requested range and does not run on file events. |
| UI | `RenderTests` | The real Capacity Analysis page is included in the all-pages render pass and the empty-state pass. It uses the same scope bar, Swift Charts reference lines and quality labels as the rest of the dashboard. |

Fixtures that no longer represented correct behavior were corrected and no assertion was weakened. The fork fixtures now repeat the parent's lines in the same positions, as real files do, where they used different positions and relied on the time window; the "model without a price" fixture uses a model that is really unlisted, since the former default model is now priced; the helper test evaluates a reading at the current time, because the helper dates readings with the real clock and a reading dated after the evaluation time is rejected on purpose.

## 2. Validation against the real installation

The Claude figures below were measured on the previous, Claude-only build and **re-run on the multi-provider build**: `tw verify --provider claude` is consistent, and was run again on the final stabilization build (795 files, 87,593 requests, 172 sessions; uncached input 179,064, output 60,820,786, cache read 27,503,585,054, cache creation 389,356,354, all equal to the independent recount).

### OpenAI (Codex) on the real data

`tw verify --provider openai`: 232 sessions, input 494,170,138, cached 473,721,088, output 1,846,647, reasoning 707,205, **all equal to the independent recount**, which now measures each thread by Codex's own running counter and agrees with the sum of every thread's records. 225 of Codex's own 232 thread totals agree exactly. Every difference from Codex's own figure is explained (usage records without events, and one fork). See [OPENAI-CODEX](OPENAI-CODEX.md).

### Original Claude validation

All performed on the real Claude history of the machine (793 files, 4.75 GB).

All performed on the real Claude history of the machine (793 files, 4.75 GB).

### Token totals agree with the original records

`tw verify` decodes each source file again with a **different parser** (Foundation's JSON decoder) and a **different finalization rule** (the observation with the largest output per message id) up to the exact byte the importer consumed, and compares per session.

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

Verified on the installed app. `--login-item enable` registers it through `SMAppService` without needing approval, `status` reports Enabled, the registration is still Enabled after the app is quit, reinstalled and started again, and there is no LaunchAgent, so there is a single registration. A second copy started by hand exits at once (see below). **Not verified:** that macOS actually starts the app at the next login or reboot, which needs a logout.

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
| 2 | Starts at login, monitors without a terminal | Registered and enabled through `SMAppService`. An actual start at login is not verified |
| 3 | Existing local sessions are imported | Met. 170 sessions, 86 K requests on first launch |
| 4 | New sessions detected automatically | Met. FSEvents, plus reconciliation |
| 5 | Concurrent sessions tracked independently | Met. Load test and unit tests |
| 6 | Input, output, cache-read, cache-creation accurately recorded | Met. Exact against an independent recount |
| 7 | Deduplicated across restarts and sources | Met. Crash test, idempotent re-import, source-merge test |
| 8 | Totals verifiable against original records | Met. `tw verify` and Diagnostics → Verify |
| 9 | Five-hour and weekly quota shown when authoritative data is available | Codex: shown, from the real files. Claude: shown from the real local cache (stale at validation); the optional status line is implemented and rehearsed with the documented payload, but its live payload was not seen |
| 10 | Missing quota identified, not fabricated | Met. "Unavailable", dashes, no token-based percentage anywhere |
| 11 | Menu bar shows activity and usage | Met |
| 12 | Dashboard supports session, model and project analysis | Met |
| 13 | History survives restarts | Met |
| 14 | Imports and live updates do not noticeably impact macOS | Met. 5.9 s and 28 MB for 4.75 GB; about 0.05 to 0.25 % CPU idle |
| 15 | Tests cover critical accounting and lifecycle | Met. 402 tests (338 core executed, 64 UI compiled) |
| 16 | Long runs without leaks or duplicates | Flat memory over minutes, an accelerated 45-day run, idempotence tests. A multi-day soak was not run |
| 17 | Documented install and build | Met. README |
| 18 | Subscription capacity analysis is observed, bounded and evidence-gated | Met in the core and offscreen UI. 26 capacity tests, a 0.046 s report over 60 cycles / 12,000 requests, and no computation on file events. A real multi-week plan history was not available to produce a live 20x-versus-5x result |
| 19 | Plan history survives upgrades, downgrades, corrections and unknown plans; ambiguous identity is unsupported | Met by store and engine tests. Overlaps, conflicting labels and edited captured plans disable the comparison instead of guessing |

## 4. Live validation of the installed app (2026-10-20)

Done with the real installed app, driven through the macOS accessibility interface (reading and clicking the real windows), because this session has no permission to capture the screen. Nothing below was inferred from offscreen rendering.

**Verified**

* **Single instance.** A second copy of the binary exits within three seconds and the first keeps running.
* **Menu bar.** The status item exists and its popover opens (a click through accessibility) and shows both providers with the right state: Claude "unavailable", two OpenAI pools (a named account and the unassigned one), the five-hour window as "reset 3d 17h ago, the new value appears after OpenAI next reports it" and the weekly window as 3 % and stale. **Defect found and fixed:** the menu bar title said "O 3%*", which was the weekly figure shown as if it were the short window. It now says "O –".
* **The icon is not visible on this Mac's menu bar.** The item sits inside the notch (its position is x 829 to 908 on a screen whose notch covers 771 to 956), the app detects this and says so in a banner. This cannot be fixed by the app. Free some menu bar space.
* **Dashboard.** The window opens from the Applications folder, its sidebar lists every page (ten now, including Capacity), and Overview, Cost, Quota, Providers and Diagnostics show the real figures (Cost with the new "not a subscription charge" notice and a "Prices" column). The provider scope filter changes the Overview from 369 M to 3.01 M tokens and back. The minimum window size is enforced. Two accounts of one provider appear as two pools.
* **Settings.** The theme choice is stored (the database holds `"appearance":"dark"`) and restored. **Defect found and fixed:** the seven tabs were folded into an overflow menu at the window's width, so they are now a segmented control.
* **Notification permission.** The flow was exercised for real: macOS answered the first request with a denial, the settings tab showed "Turned off in System Settings > Notifications", the test button reported "Notifications are turned off for this app", and an "Open Notification Settings" button appeared.
* **Launch at login.** Enabled and verified (above).
* **Restart and crash.** Quit with ⌘Q (clean-shutdown marker 1), relaunch (one instance, 91,866 requests). `kill -9`, relaunch: integrity check ok, no foreign-key violations, no duplicate requests, collection continued.
* **No network sockets**, again.
* **Claude local cache path, read-only.** The installed Claude Code 2.1.305 cache at `~/.claude.json` was read with the opt-in real-installation test. The file was 119,704 bytes, mode `0600`, and its bytes and modification time were identical before and after. Its `fetchedAtMs` was about 3.2 hours before validation while the file mtime was later, so the quota evaluation correctly showed the 5-hour, weekly and scoped `Fable` windows as stale. The raw account identifier was neither printed nor stored.
* **Claude status-line path, without touching your settings.** `tw statusline-check` installed the helper into a copy of the real `settings.json` (no status line is configured today): one line differs, uninstalling restores the file byte for byte, the exact command ran with a made-up payload, and the output and the parsed values were correct. The payload layout was checked against Claude Code's current documentation (`rate_limits.five_hour` and `seven_day`, `used_percentage`, `resets_at` in epoch seconds, absent before the first response, a window dropped once its reset passes, the status line run again when a window reaches its reset time).

**Not verified, and why**

* **A delivered notification.** macOS recorded a denial for the app. The app should not change your privacy settings. To finish this, turn on System Settings → Notifications → Tokenwatch, then press "Send a test notification" in Settings → Notifications.
* **A live `rate_limits` payload from the optional helper.** The helper is not installed in your Claude Code settings, and installing it changes your configuration. The automatic cache path is verified; the helper's live payload is not. To finish this, use Settings → Quota → Install helper…, start a new terminal Claude Code session and send one message. **The optional status line is therefore not verified live.**
* **A side-by-side `/usage` comparison and the cache refresh trigger.** `/usage` is an interactive terminal screen, and no supported non-interactive structured interface was found. The cache's `fetchedAtMs` and file mtime were observed to differ, but the exact event that refreshes the cache is not documented or verified.
* **Sleep and wake, a reboot, and an actual login start.** The wake path (reconcile on `didWakeNotification`) is covered by the missed-events test, but a real sleep was not performed.
* **Light and dark appearance of the real window, and real screenshots.** The theme setting works, but without permission to capture the screen the appearance could not be looked at. The README images are rendered by the app's own offscreen renderer from synthetic demo data. Offscreen rendering draws the sidebar of the dashboard as an empty panel; the real window shows it.
* **Empty, loading and error states in the real window.** Covered by the state tests and the offscreen renders only.
* **A multi-day soak.** The accelerated run is not one.

## 5. Manual acceptance procedure

These checks need a person at the Mac, because they log out, sleep, restart or change macOS privacy settings. Each step names what success looks like. The terminal commands only read; none of them changes the database.

Useful read-only commands:

```sh
pgrep -lx Tokenwatch                                                          # Which copies are running.
"/Applications/Tokenwatch.app/Contents/MacOS/Tokenwatch" --login-item status  # Whether macOS starts it at login.
sqlite3 -readonly ~/Library/Application\ Support/Tokenwatch/usage.sqlite "select count(*) from model_request"
sqlite3 -readonly ~/Library/Application\ Support/Tokenwatch/usage.sqlite "PRAGMA integrity_check"
```

1. **Notifications.** Open System Settings → Notifications → Tokenwatch and turn on *Allow notifications*. In Tokenwatch, open Settings → Notifications, turn notifications on, and press *Send a test notification*. Success: a banner titled "Tokenwatch" saying "This is a test. Notifications are working." appears, and the settings page shows the permission as allowed. Then turn *Allow notifications* off in System Settings and press the test button again. Success: no banner, and the page says that notifications are turned off for the app instead of failing silently. Turn it back on, quit and reopen Tokenwatch, and check that your notification settings are unchanged.
2. **Log out and back in.** Note the request count, then log out and log in. Success: Tokenwatch's menu bar item appears without opening anything, `pgrep -lx Tokenwatch` lists exactly one process, and the request count has not gone down. Within a minute of using Claude Code, the count goes up while no Tokenwatch window is open.
3. **Second copy.** Open `/Applications/Tokenwatch.app` again from Finder. Success: the running copy comes forward and `pgrep` still lists one process.
4. **Sleep and wake.** Put the Mac to sleep for at least five minutes while a Claude Code or Codex session is idle, then wake it and send one message. Success: the new request appears in the dashboard without restarting the app, and quota readings older than their freshness limit are marked stale rather than current.
5. **Restart the Mac.** Note the request count and run the integrity check, then restart. Success after login: one Tokenwatch process, the request count equal or higher, `PRAGMA integrity_check` prints `ok`, and Diagnostics shows every source as synchronized.
6. **Quota freshness across the restart.** Success: the menu bar figures after the restart are the same readings as before, with their original "updated … ago" times, never shown as newer than they are.

## 6. Final acceptance checks (2026-10-23)

These were run against the installed app and the real data on this Mac. Recounts ran against a snapshot copy of the database, so the real database was only read.

* **Independent recounts.** Claude: 90,737 requests, with uncached input, output, cache reads and cache writes matching exactly. A further 1,122 stored requests come from 16 transcripts that Claude Code has since deleted (its 30-day cleanup). They are reported as retained history, and their totals equal the earlier difference between the database and the files exactly. Before this release `tw verify` and the Diagnostics page reported them as a mismatch and suggested *Rebuild from source*, which would have discarded that history. OpenAI: input, cached, output and reasoning tokens match exactly across 241 sessions.
* **Database.** `PRAGMA integrity_check` is `ok`, there are no foreign-key violations and no duplicate request keys. Request, session and quota counts and the output-token sum were identical before and after a clean quit, and grew only by new requests after the relaunch.
* **Claude quota, live.** Each new snapshot in `~/.claude.json` was stored with its own `fetchedAtMs` as the observation time, with the same percentages and reset times, and shown in the menu bar (`C 3%`, then `C 4%`). A snapshot whose numbers had not changed only extended `last_confirmed_at`. Readings are stored in the hashed account's pool; the earlier unassigned cache history is kept and is shown as older readings. The status line helper was not installed, at the user's choice.
* **OpenAI quota.** The latest weekly reading (42 %) is shown as stale after 13 hours, and the five-hour window, whose reset time has passed, is shown as unavailable and as a dash in the menu bar, never as 0 %.
* **Single instance and login item.** A second copy started by hand exited at once, leaving one process. After the app was replaced, `--login-item status` still reported *Enabled*.
* **Idle cost.** Menu bar only, after a fresh start: 79.5 MB resident and 0.05 % CPU over two minutes, within the earlier baseline. With the dashboard open beside a streaming Claude Code session, the app used 12 to 16 % CPU, which is the bounded heavy-reload behaviour described in `AppModel`; after the window was closed it fell to 0.28 %.
* **Prices.** The Anthropic and OpenAI cards were compared with the providers' pricing pages. Sonnet 5.5's cache-hit price was corrected from 0.20 to 0.10 US$ per million tokens (0.05× input), which lowered the estimate for this Mac's history by US$982.44. The estimate is now within 4.1 % of Claude Code's own recorded session costs.

Not performed: notification delivery, logging out, sleep and wake, and a reboot, which are in section 5; the live status-line payload; screenshots and the appearance of the real window, because screen capture is not available to the tooling.

## 7. Release-safety audit (2026-10-23)

**Retained history.** Claude Code deletes transcripts after 30 days by default; on this Mac 1,122 stored requests came from 16 deleted transcripts. Every path that can remove stored usage was checked:

| Path | Before | Now |
|---|---|---|
| Restart, reconciliation, a file replaced or truncated | Requests kept; a vanished file is only marked `missing` | Unchanged, now covered end to end |
| Rebuild from source | Deleted retained-only requests without warning or copy; no confirmation at all | Confirmation names the requests that cannot be imported again; a `VACUUM INTO` copy is written first (three newest kept, `0700` folder, `0600` files); nothing is deleted if the copy fails |
| Corruption recovery | Damaged file moved aside, but Diagnostics claimed the history was re-imported | Damaged file still never deleted; Diagnostics names its path and says which usage is only there |
| Delete all collected data | Claimed history is imported again | No copy, by design; the confirmation names what is lost permanently |

`RetainedHistoryTests` (4) imports two sessions, deletes one transcript, reconciles, restarts and rebuilds, and checks that the requests survive until the rebuild, that the copy is self-contained, private and complete, that only three copies are kept, that erasing leaves no copy even when a file event re-imports in between, and that a damaged database keeps every request in the moved-aside file.

**Claude cache freshness.** The observation time is the snapshot's `fetchedAtMs`, never the file's modification time or the time of reading, and `last_confirmed_at` only moves forward. Four tests were added to `ClaudeCodeCacheCoordinatorTests`: re-reading the same snapshot after a rewrite and a restart three hours later leaves it stale and not alert-eligible; a newer fetch with identical percentages makes it fresh again without adding a row, and an older snapshot read afterwards cannot move it back; an expired window is unknown, not zero, and not alerted on; a clock moved forward ages a reading, a clock moved back makes it stale, and a future-dated fetch is not stored. The account and two-source cases were already covered. No defect was found.

**Post-release work, by severity.** None of these is a confirmed high-severity correctness, privacy or data-loss defect, so none was changed in this release.

* **Medium: duplicate pools and alerts with the optional status line.** Installing the status line shows one Claude subscription as an identified pool (cache) and an unassigned pool (status line), and a threshold can be announced once for each. The helper is not installed. Pools are not merged, because the status line carries no account identity.
* **Medium: Codex's alpha file format.** A change of shape can stop collection; unrecognized usage lines are reported in Diagnostics rather than counted as nothing.
* **Medium: real sleep, reboot, login and notification delivery** are unverified until the manual procedure in section 5 is carried out.
* **Low: unassigned historical accounts.** Older Codex files and pre-attribution Claude cache readings stay in unassigned pools as history.
* **Low: menu bar icon under the notch.** Detected, with a Dock icon offered; the app cannot move the icon.
* **Low: dashboard CPU while open beside a busy session** (12 to 16 %). It is bounded by design and falls to the idle baseline when the window closes; collection itself is unaffected.
* **Low: `scripts/install.sh` replaces the app in place without keeping a copy.** The README says so and how to keep one.
* **Low: backup pruning.** After three further rebuilds, history held only in the oldest copy is gone; the confirmation states that three copies are kept.
