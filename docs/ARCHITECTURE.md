# Architecture and source audit

This document records what the research found, which data sources are used, and how the application is built around them.

## 1. Source audit and capability matrix

Findings come from inspecting this machine's real Claude installation (792 session files, 4.7 GB), the Claude Code documentation (status line and monitoring pages), and Claude Desktop's local files. Nothing below is assumed: every "available" entry was observed in real data or is documented.

| Source | Session id | Project | Model | Per-request tokens | Cache read / write (5m / 1h) | Timestamps | Quota % | Quota reset time | Cost |
|---|---|---|---|---|---|---|---|---|---|
| **Claude Code transcripts** (`~/.claude/projects/**.jsonl`): terminal, VS Code extension, Claude Desktop "Code" tab | Yes | Yes (working directory, from the folder name and `cwd`) | Yes | **Yes**, on every assistant message | **Yes**, including the 5 m / 1 h split | Yes, per record | No | No | Only Claude Code's own per-session summary (`cost-state`), kept separate |
| **Claude Code live process registry** (`~/.claude/sessions/*.json`) | Yes | Working directory | No | No | No | Start and update times | No | No | No |
| **Claude Code status line input** (documented) | Yes | Yes | Yes | Context-window snapshot only, not per request | No | n/a | **Yes**: `rate_limits.five_hour` / `seven_day` / `spend_limit` `.used_percentage` | **Yes**: `.resets_at` | Session cost estimate |
| **Claude Code OpenTelemetry** (documented) | Yes | Via attributes | Yes | Yes (`api_request` events) | Yes, in totals | Yes | **No** (not exposed) | No | `cost_usd` (an estimate) |
| **Claude Desktop: Code sessions** (`~/Library/Application Support/Claude/claude-code-sessions`) | Yes (metadata) | Yes | Yes | No (the usage is in the transcripts above) | No | Yes | No | No | No |
| **Claude Desktop: Chat and Cowork** | Not exposed | Not exposed | Not exposed | **Not exposed** | **Not exposed** | Not exposed | No documented interface | No | No |
| **Claude Desktop `plan-usage-history.json`** (undocumented) | No | No | No | No | No | Yes | Fields `fh` / `sd` that look like five-hour / weekly percent, unconfirmed | **No** | No |
| **claude.ai in a browser, other devices** | No | No | No | No | No | No | Counted in the account quota, but not observable here | No | No |
| **Anthropic Admin / usage APIs** | n/a | n/a | Yes | API keys only | Yes | Yes | **No**: they describe API usage, not subscriptions | No | API cost |

### Conclusions drawn from the audit

1. **Token usage** is available completely and locally for everything that runs through Claude Code. The transcripts are the single richest source, and they are the only one that exposes the cache write lifetime split.
2. **Subscription quota** has exactly one documented, authoritative source: the `rate_limits` object that Claude Code passes to a configured status line command. Nothing else documented reports subscription utilization. The application therefore ships a tiny status line helper (`ccu-statusline`) as its authoritative quota source.
3. **Quota is not derivable from tokens.** Anthropic does not document a conversion, and the account figure also includes usage the application cannot see. The application never computes a quota percentage from tokens. See [QUOTA.md](QUOTA.md).
4. **OpenTelemetry** adds nothing that the transcripts do not already contain, but it needs a collector process to receive data. It is deliberately not implemented. The identity model (request keyed by the API message id, with the server `request_id` stored alongside) is compatible with it, so adding it later would not double count.
5. **Claude Desktop Chat, Cowork, claude.ai and other devices cannot be monitored.** Their usage counts toward the account quota but leaves no local trace. This is shown in the interface and never hidden.
6. **Undocumented interfaces are not relied on.** `plan-usage-history.json` is available as an opt-in, clearly labelled "unverified" hint that never reaches the menu bar or alerts. The private OAuth usage endpoint that some community tools call was not used: it depends on reusing Claude Code's credentials, which the requirements exclude.

## 2. Logical architecture

Everything lives in one process. The boundaries are logical, enforced by module and type boundaries rather than by processes or services.

```
                        ┌───────────────────────────── UsageUI (SwiftUI) ───────────────────────────┐
                        │ MenuBarExtra · Dashboard · Settings · AppModel (@Observable)              │
                        └───────────────▲──────────────────────────────▲────────────────────────────┘
                                        │ reads                        │ commands
┌──────────────────────────────────────── UsageCore (no UI dependency) ──────────────────────────────────────────┐
│                                                                                                               │
│  Background lifecycle      UsageCollector (actor) ── FSEvents + reconcile ── retry / backoff / health          │
│                                │                                                                              │
│  Source adapters           ClaudeCodeAdapter ──►  LineParser (streaming byte scanner)                          │
│                                │  NormalizedBatch (pre-merged observations)                                    │
│  Persistence               FileSynchronizer (checkpoints) ──► IngestWriter ──► SQLite (WAL)                    │
│                                                                      │                                         │
│  Analytics                 AnalyticsEngine · CostSQL/Pricing · ExportService · SourceVerifier                   │
│                                                                                                               │
│  Quota                     QuotaCoordinator ◄── StatusLineQuotaSource ◄── ccu-statusline (separate tiny binary) │
│                            QuotaEvaluator (pure) · AlertEngine (dedup)                                         │
│  Live state                SessionRegistryMonitor (observed session lifecycle)                                 │
└───────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Responsibility | Where it lives |
|---|---|
| Usage Collector | `UsageCollector`, `FileSynchronizer`, `FSEventsWatcher` |
| Source Adapters | `SourceAdapter` protocol, `ClaudeCodeAdapter` + `ClaudeCodeLineParser` |
| Normalization | `RequestObservation`, `SessionObservation`, `NormalizedBatch` (with the merge rules) |
| Persistence | `UsageDatabase`, `Schema`, `IngestWriter`, `Retention` |
| Analytics | `AnalyticsEngine`, `PricingCatalog`, `CostSQL`, `ExportService` |
| Quota Provider | `QuotaCoordinator`, `QuotaEvaluator`, `StatusLineQuotaSource`, `StatusLineInstaller`, helper `ccu-statusline` |
| Lifecycle Manager | `UsageCollector` (events, reconcile, wake), `SessionRegistryMonitor`, `AppModel` (start, sleep/wake, retention), `LoginItem` |
| Presentation | `UsageUI` |

### Targets

| Target | Purpose |
|---|---|
| `UsageCore` | All collection, storage, accounting, quota and analytics logic. Imports no UI framework. |
| `UsageUI` | SwiftUI views and the observable `AppModel`. Kept separate from the executable so it can be tested and rendered headlessly. |
| `ClaudeUsageMonitor` | The `@main` app: a `MenuBarExtra` plus the dashboard and settings windows. |
| `ccu` | Command line front end using the same core: import, verify, cost check, export, benchmark. |
| `ccu-statusline` | Status line helper Claude Code runs. Depends on nothing but Foundation, so it starts in milliseconds. |

## 3. Why these choices

* **Native Swift and SwiftUI with Swift Charts**, as preferred. The core is plain Swift with SQLite through the system C library. There are **no third-party dependencies**.
* **A custom streaming JSON scanner** instead of `JSONDecoder`. Transcript lines can be megabytes (tool output, file contents, model replies). The scanner walks only the handful of fields needed and skips everything else without allocating it. That is what keeps a 4.7 GB import at about 5 seconds and 50 MB of memory, and it also means prompt and response text is never decoded, let alone stored.
* **SQLite with WAL** and a single serialized writer plus a small pool of read-only connections. Readers never block the writer.
* **FSEvents plus a low-frequency reconciliation pass.** FSEvents is kernel driven, so an idle watcher costs no wake-ups. Reconciliation compares file size, modification time and inode against the stored checkpoints (no content reads) every ten minutes, after wake, and after any `MustScanSubDirs` or dropped-event flag, so lost events are always recovered.
* **Observed beats inferred** for session lifecycle: the live process registry is used when it exists, and inference from recent activity is always labelled as inference.
* **One process.** No daemon, no XPC service, no login helper. The menu bar app is the long-running component, started at login through `SMAppService` (or an optional LaunchAgent).

## 4. Background lifecycle

* **Start:** the collector reconciles (import on first run, catch-up afterwards), starts FSEvents watchers for the transcript folder, the process registry and the quota folder, and the quota coordinator reads existing quota files.
* **Running:** file events are coalesced for 250 ms, then only the appended bytes are parsed. Quota changes are applied immediately. The user interface is refreshed at most once every two seconds, and only while a window is showing. With every window closed, only cheap state is kept current.
* **Sleep and wake:** `NSWorkspace.didWakeNotification` triggers a reconciliation and a quota re-read. Time-zone, clock and calendar-day changes trigger a refresh, since bucketing is always computed at query time.
* **Crash or reboot:** all state is on disk. The next launch resumes from durable checkpoints, runs an integrity check if the previous shutdown was not clean, and replays anything missed. A crash cannot lose or duplicate usage because observations and their checkpoint commit in one transaction and every observation is idempotent.
* **Failure containment:** each source adapter and each file has its own error boundary. A failure is recorded with a message, retried with exponential backoff (5 s doubling to 15 min, with jitter), and surfaced in Diagnostics. Other sources continue.
