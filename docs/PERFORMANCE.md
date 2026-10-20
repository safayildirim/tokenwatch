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

### Import (`ccu bench`, scratch database)

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

Memory behaviour during the app's own sampling shows no growth trend; run `ccu bench` and the Diagnostics page's resource panel to reproduce the numbers on your machine.


## Multi-provider measurements

Same machine, release build, real history of both providers: Claude (793 files, 4.8 GB) and Codex (232 files, 862 MB uncompressed, 212 of them zstd-compressed).

```
-- initial import (ccu bench)
claude-code-transcripts: files=793 changed=793 bytes_read=4.827.545.587 lines=655.596 seconds=5.77 peak_rss_mb=31.5
codex-rollouts:          files=232 changed=232 bytes_read=862.131.548   lines=31.481  seconds=1.44 peak_rss_mb=48.3
-- second pass (nothing changed)
claude-code-transcripts: seconds=0.06      codex-rollouts: seconds=0.01
database_size_mb=36.7
```

* The Codex import includes decompressing 212 files. Compressed files are immutable and read once. Plain files that grow are read again from their start, which is cheap at these sizes (the largest active session is a few megabytes).
* Installed app, steady state (menu bar only, both providers, database already imported): about **78 MB resident and 0 % CPU**, no network sockets. Immediately after the very first import the process can hold about 180 MB until it settles, because the allocator keeps freed pages.
* Query latency on the combined database: overview, session table, series and breakdowns each about 100 to 170 ms.
