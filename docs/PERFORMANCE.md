# Performance

Measured on an Apple M1 Max (32 GB), macOS 26.5, release build, against the real Claude history on that machine: **793 session files, 4.75 GB, 648,714 lines, 86,000+ requests, 170 sessions**.

## Targets, set after the first baseline

The first measurements of an unoptimized build showed what mattered (see "What the measurements changed"). The targets below were set from them and are met.

| Metric | Target | Measured |
|---|---|---|
| Idle memory (menu bar only, no window) | under 100 MB resident | **52 to 66 MB** |
| Idle CPU, with a session streaming output all day | under 0.5 % average | **≈ 0.25 %** (1.2 s of CPU in 8 minutes, including events from this very session) |
| Initial import of a ~5 GB history | under 15 s, under 100 MB | **5.9 s, 28 MB peak** (≈ 800 MB/s) |
| Re-scan with nothing changed | under 0.5 s | **0.06 s** (793 files, metadata only) |
| Live ingestion latency (last write to visible in the database) | under 2 s | **0.88 s** with 6 concurrent sessions |
| Dashboard query latency | under 250 ms | **100 to 195 ms** |
| Network connections | none | **none** (`lsof -i` shows no sockets) |

## Measurements

### Import (`tw bench`, scratch database)

```
-- initial import
files=793 changed=793 bytes_read=4.748.545.383 lines=648.714 malformed=0 seconds=5.93 peak_rss_mb=27.9
-- second pass (nothing changed)
files=793 changed=0 bytes_read=0 lines=0 malformed=0 seconds=0.06 peak_rss_mb=29.1
database_size_mb=31.9
```

The database is 32 MB for 4.75 GB of logs, because only usage metadata is kept. A repeated import reads nothing: every file's checkpoint (size, modification time, inode) matches.

### Query latency (all 86 K requests, price join included)

| Query | Time |
|---|---|
| Overview (today, week, month totals plus counts) | 121 ms |
| Sessions table, all sessions | 159 ms |
| Daily series split by model | 146 ms |
| Hourly series | 118 ms |
| Models | 130 ms |
| Projects | 194 ms |
| Session detail (largest session, 8 K requests) | 100 ms |

Queries run on background threads, so the interface never waits on them.

### Live load (6 concurrent simulated sessions, sub-agents, streaming duplicates)

A generator appended 4,173 log lines (1,391 distinct requests, 18 sub-agents) over 30 seconds, about 46 requests per second, to a scratch Claude folder while the app collected.

* **Exact result:** requests, uncached input, output, cache read and cache creation in the database equal the generated totals to the token.
* **Latency:** the last line written was fully visible in the database 0.88 s later.
* **Cost:** 75 MB resident, about 0.007 CPU-seconds per second (0.7 %) during the burst.

### Idle, 10 minutes, menu bar only

Sampled every 30 seconds while this session wrote to its transcript continuously.

```
13:08:00  84.5 MB  cpu 0:00.27        13:12:00  66.4 MB  cpu 0:00.60
13:09:30  66.5 MB  cpu 0:00.32        13:13:30  58.3 MB  cpu 0:00.76
13:11:00  65.0 MB  cpu 0:00.41        13:16:00  59.6 MB  cpu 0:01.43
```

Memory is flat to slightly falling (no leak). CPU grew by 1.16 s over 8 minutes, about 2.4 ms per wall-clock second (0.24 %). This sample was taken on an earlier build (heavy reload throttle of 2 s instead of the final 4 s), so it is, if anything, conservative.

## What the measurements changed

The first always-on build recomputed the full dashboard summaries on every file event. With a session streaming output, that meant a multi-hundred-millisecond query every second, and the app sat at roughly **4 % CPU and 137 MB** before any window was opened. Three changes fixed it:

1. **Visibility-aware refresh.** Heavy analytics run only while a window is showing. With none open, only cheap state is kept current: quota readings, the live process table, collector health and the active session count (one indexed query). When a window opens, a refresh is triggered at once.
2. **Throttling.** Heavy reloads are spaced at least 4 seconds apart however fast data arrives, and coalesced after a 0.7 s settle.
3. **Cheaper overview and smaller caches.** All-time figures are plain counts instead of a priced scan of the whole history, and the SQLite page caches were reduced from 32 MB (writer) and 16 MB × 4 (readers) to 8 MB each, with memory-mapping off.

## Why it is cheap

* **Event driven.** FSEvents, with no polling timers. The only recurring wake-ups are the ten-minute reconciliation, a 30-second liveness check that runs only while a Claude process is registered, and the quota coordinator's sleep until its next possible state change.
* **Incremental.** Only newly appended bytes are read, from a durable offset. A request already seen is never re-parsed from a different part of the file.
* **Streaming and bounded.** Files are read in 4 MB chunks; a line is decoded in place and its large content is skipped without allocation. Memory does not grow with file size. Up to three files are parsed in parallel at utility priority, so an import does not compete with foreground work.
* **Cheap checkpoints.** Reconciliation compares file metadata only.

Memory behaviour during the app's own sampling shows no growth trend; run `tw bench` and the Diagnostics page's resource panel to reproduce the numbers on your machine.


## Multi-provider measurements

Same machine, release build, real history of both providers: Claude (793 files, 4.8 GB) and Codex (232 files, 862 MB uncompressed, 212 of them zstd-compressed).

```
-- initial import (tw bench)
claude-code-transcripts: files=793 changed=793 bytes_read=4.827.545.587 lines=655.596 seconds=5.77 peak_rss_mb=31.5
codex-rollouts:          files=232 changed=232 bytes_read=862.131.548   lines=31.481  seconds=1.44 peak_rss_mb=48.3
-- second pass (nothing changed)
claude-code-transcripts: seconds=0.06      codex-rollouts: seconds=0.01
database_size_mb=36.7
```

* The Codex import includes decompressing 212 files. Compressed files are immutable and read once. Plain files that grow are read again from their start, which is cheap at these sizes (the largest active session is a few megabytes).
* Installed app, steady state (menu bar only, both providers, database already imported): about **78 MB resident and 0 % CPU**, no network sockets. Immediately after the very first import the process can hold about 180 MB until it settles, because the allocator keeps freed pages.
* Query latency on the combined database: overview, session table, series and breakdowns each about 100 to 170 ms.


## Stabilization check (2026-10-20)

Same machine and release build, measured against the same baseline. **The machine was heavily loaded by other applications throughout** (load average 10 to 32 on 10 cores, which a quiet measurement session would not have), so times are pessimistic and the comparison is a regression check, not a new benchmark. History: Claude 795 files (4.93 GB), Codex 232 files (862 MB), 92,000 requests.

| Metric | Baseline above | Measured now | Verdict |
|---|---|---|---|
| Import, Claude | 5.8 to 5.9 s, 4.83 GB | 6.4 s and 7.2 s, 4.93 GB (about 690 to 770 MB/s, was 820 to 840) | Within the noise of the load. Not investigated |
| Import, Codex | 1.44 s | 1.55 s and 1.64 s | Same |
| Peak memory of an import | 28 to 31 MB (Claude), 48 MB (Codex) | 29.5 to 30 MB, 44.6 to 49.4 MB | Same |
| No-change reconcile | 0.06 s and 0.01 s | 0.07 to 0.08 s and 0.01 s | Same |
| Query latency | 100 to 195 ms | 186 to 227 ms, session detail 107 ms | About 20 to 40 % slower under a load average of 12. Not investigated |
| Live ingestion latency | 0.88 s with 6 sessions | **0.31 s with 9 concurrent sessions** (6 Claude, 3 Codex, 225 requests) | Better |
| Idle memory, menu bar only | about 78 MB | **73 to 79 MB** after a fresh start, no window ever opened | Same |
| Idle CPU, menu bar only, while two sessions of this very machine were writing | about 0.25 % | 0.06 % and 0.7 % in two samples | Same order of magnitude |
| Network sockets | none | none | Same |

### One regression found and fixed: the dashboard window left open

The baseline measured the app with no window. With the dashboard open beside a streaming session, the installed app used **12 % of a core on average and up to 38 %** (sampled for 60 s, 147 MB). Each heavy reload takes about a second on this history, and it ran every four seconds. A heavy reload is now followed by a pause of eight times its own duration, with the old four seconds as the minimum, so the cost can no longer exceed about a tenth of the processor however large the history grows. Measured again with the dashboard open and data still arriving: **1.0 % and 1.5 %** (90 s and 120 s). Memory with the window open is 190 to 210 MB (charts), and it falls back when the window is closed.

### Accelerated reliability run

`AcceleratedSoakTests` runs 45 simulated days in under three seconds through the real collector, database and both adapters: sessions of both formats grow, forks are made, files are compressed with `zstd` and archived the way Codex does, the app is stopped without a clean shutdown and reopened, the Codex folder disappears for a day while Claude Code keeps working, and damaged lines are written. Every total equals what was generated, nothing is stored twice, the integrity check passes and both independent recounts agree. **This is not equivalent to running for days.** A real multi-day soak is a separate pending item.

## Capacity analytics

Capacity analysis is an **on-demand read path**. It adds no timer, no FSEvents observer and no
per-event work. The Capacity Analysis page loads a report when it is first shown, when the selected
range or scope changes, or when the user explicitly recomputes. A file event updates quota and usage
as before; it does not run the estimator.

Measured with `CapacityPerformanceTests` on a deterministic fixture:

```
cycles=60  requests=12,000  plans=2  seconds=0.046   (debug test build)
```

The fixture contains 60 independent five-hour cycles (30 per plan), two authoritative snapshots per
cycle, 200 local requests per cycle and enough priced work to satisfy the evidence policy. The report
returns 60 cycle samples and a 4.0× matched estimate.

What bounds the cost:

* snapshots are selected by `observed_at` (indexed) for the requested range;
* local requests are selected once per window by `requested_at` (indexed), not once per interval;
* interval construction and work distribution are a single ordered pass; requests are never copied
  into per-interval arrays;
* a cycle sample is one aggregate, not one row per reading;
* estimates are O(samples × plans²) with samples bounded by the cycles in the range;
* the report stores only the requested range's snapshots, aggregates and measurements, plus the
  account's plan history and the current price quotes used for the strategy comparison. It creates
  no table, trigger or cache.

The UI runs the report on a background task. A range or scope change starts a new generation and
discards any older report that arrives late, so the page cannot show a stale result. With the page
closed there is no capacity work at all, and idle CPU/memory are unchanged from the measurements
above.

## Usage intelligence

Usage intelligence ([INTELLIGENCE.md](INTELLIGENCE.md)) is an **on-demand read path** like capacity analysis. It adds no timer, no file-system observer and no per-event work. With the page closed nothing runs. A choice the user makes recomputes after 30 ms; data changes, which arrive in bursts while a tool is running, wait 3 s for the burst to settle and then compute once on a background task. A newer change cancels the wait and a stale result is dropped.

**Idle cost, measured** (2026-10-23, an isolated copy of the application with its own data folder and no source folders; the production application was not touched). CPU is the instantaneous figure of `top` averaged over its last three samples, taken at least 45 s after the window was opened. An earlier measurement with `ps` was discarded, because `ps` reports the average over the process's whole life and so mostly shows start-up:

```
                         CPU        footprint
dashboard closed         0.17%      18 MB
Overview page open       0.00%      63 MB
Trends page open         0.00%      67 MB
Capacity page open       0.00%      116 MB
Intelligence page open   0.00%      192–198 MB   (first build, with a picker of all 420 time zones)
```

Nothing of the feature runs while the page is closed, and an open page sat at 0.00% CPU. The page was the heaviest in memory, and a bisection pointed at one control: with the time-zone picker reduced to a single entry the footprint was 122 MB, because a picker of every zone is built eagerly. The page now offers a short menu of common zones and a lazily built, filterable list in a sheet for the rest. One measurement of that build gave 178 MB and 1.2% CPU in a single three-sample window. It was not repeated, because the measurements were stopped at that point, so **the memory saving of the final control is not confirmed**, and the one 1.2% reading is unexplained. A baseline of the previous build was not re-measured with the corrected method.

**Real history, release build** (`tw intelligence`, a read-only copy of this Mac's database: 97,486 requests, 1,019 quota snapshots, 10 quota windows of 2 providers; warm file cache):

```
tw intelligence (all 10 windows: cycles, coverage, forecast, held-out check, insights)   0.4–0.6 s wall, process start included
tw export --kind usageIntelligence --format json (292 rows)                              0.6 s wall
tw export --kind capacityEvidence --format json (existing baseline)                      0.66 s wall
tw totals (existing baseline)                                                            0.19 s wall
```

One window costs roughly a tenth of that, and the page analyses one window at a time.

**Synthetic history, debug test build** (`IntelligencePerformanceTests`): 177,600 requests over 26 weeks, two providers. Analysing one provider's newest 14 weekly cycles (about 70,000 requests streamed): analysis 0.45–0.48 s, forecast with the held-out check and insights 0.003 s. The test bounds the analysis at 12 s and the forecast at 1 s.

**Main thread** (`IntelligenceRenderTests`): while the page loads a 20-cycle history with 6,780 requests and draws, a 10 ms main-thread heartbeat saw a longest gap of 0.17–0.39 s across runs in the unoptimized test build. The query runs in a detached task and the same analysis takes 0.04 s when timed alone (the test prints both figures), so the gap is SwiftUI laying out and drawing the page; the test fails above 0.6 s. Nothing in the analysis was changed for speed, because no measurement justified it.
