# Architecture and source audit

The application monitors the usage of several AI products through one provider-agnostic core. This document records the architecture audit that led to the design, what each provider's data sources can and cannot report, and how the code is organized around them.

## 1. Architecture audit: what the Claude-only design assumed

The first version modelled Claude Code directly. Auditing it before adding OpenAI found these hard-wired assumptions, and what replaced each:

| Assumption in the Claude-only code | Why it breaks for a second provider | Replacement |
|---|---|---|
| One `usage_source` row per adapter, used as the identity of sessions and requests | A product and the mechanism that observed it are different things. Codex and ChatGPT Work are two products read from one set of files. | **Provider, product, surface and telemetry source** are separate first-class entities (tables `provider`, `product`, `surface`, `telemetry_source`). A session belongs to a product and was observed by a source. |
| `session.application` held Claude's `entrypoint` string | Where a session ran (terminal, VS Code, JetBrains, a desktop app) is not a product and is not provider-specific. | `surface_id` on the session, mapped by each adapter. |
| No account at all | One person can have two OpenAI accounts, and quota belongs to an account. | `account` table. The raw identifier is never stored, only a one-way hash. An explicit **unassigned** account exists per provider for activity that does not say whose it is, and it is never guessed. |
| Tokens as four non-null integers (`input` excluded cache, `output`) | OpenAI's input *includes* cached tokens, reasoning tokens are a part of output, and some sources do not report some categories. A missing category stored as zero is a false statement. | **Canonical measurement**: `uncached_input`, `cache_read`, `cache_creation` and `reasoning_output` are nullable. Each provider's adapter normalizes into it and records the rule used (`normalization`) and how complete the figures are (`completeness`). Reasoning is stored as a subset of output and is never added to it. |
| Quota windows were an enum (`five_hour`, `seven_day`, `spend_limit`), keyed by provider only | A different provider has different windows (a daily one, a monthly one, a plan with only a weekly window). Two accounts of one provider would collide. | **Quota pool** (per account) → **window** (identified by its length, such as `300m`) → **cycle** (one period between resets) → **snapshot**. Windows are dynamic. |
| Quota percentages came from one hard-coded reader | The OpenAI percentages arrive inside session files, not from a helper. | Observations are stored through one path regardless of origin. Two entry points: a `QuotaFeed` (files a helper writes) or an adapter that emits snapshots with the usage it reads. |
| Alerts were keyed by window kind and reset time | Two accounts, two pools or two products sharing a pool must not share or hide alerts. | Alert identity is **account, pool, window and cycle**. |
| Prices were keyed by model only | The same model id can exist for two providers. | Rate cards are per provider and dated. Anthropic and OpenAI prices ship (see [TOKEN-ACCOUNTING](TOKEN-ACCOUNTING.md#openai-prices)). A model with no card stays unpriced. |
| Menu bar modes were Claude-specific | Needs a per-provider choice. | `MenuBarDisplayMode.quota(provider)`, plus all providers, highest utilization, active sessions, icon only. |
| Analytics could not filter by provider, product, account or surface | | `UsageFilter` has all four, and the dashboard has a scope bar that applies to every page. |

The smallest refactor that makes these first-class was a **redesign of the single schema in place** (there is no data to preserve in this version, so no migration was added), a typed identifier layer, a **provider registry expressed as data**, and a set of normalized observation types that the writer consumes. Nothing in the shared core names a provider. This is enforced by a test (`ArchitectureIsolationTests`) that scans the sources and fails if a provider name appears outside the files designated for it, and it is demonstrated by a third, invented provider (`FutureProviderTests`) that flows through the real collector, writer, analytics, pricing, export, quota and alert code using only a registry value and an adapter defined in the test target.

## 2. Entities

| Entity | Meaning | Examples |
|---|---|---|
| Provider | The company or platform that delivers the models | Anthropic, OpenAI |
| Product | A product of a provider that produces usage | Claude Code, Codex, ChatGPT Work, ChatGPT Chat (not observable) |
| Surface | Where a session ran | terminal, VS Code, JetBrains, Codex Desktop, ChatGPT Desktop |
| Telemetry source | The mechanism through which data is collected | Claude transcripts, the Claude status line, Codex session files |
| Account | An identity at a provider that owns an allowance | a hashed account, or the explicit "unassigned" |
| Quota pool | An allowance enforced against an account, possibly shared by several products | Claude subscription; Codex and Work |
| Quota window | One limit inside a pool, identified by length | `300m`, `10080m`, `1440m` |
| Cycle | The period between two resets of a window | |
| Quota snapshot | A reported utilization inside a cycle | 63 % at 14:02 |

Quota pools are shared across products and per account: ChatGPT Work and Codex draw on one pool, Claude Code and Claude chat on one pool, and ChatGPT Chat has a different pool that is explicitly not observable. The relationships are registry data (`pool_membership`), not code.

## 3. Anthropic source audit (Claude)

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

### Conclusions drawn from the Claude audit

1. **Token usage** is available completely and locally for everything that runs through Claude Code. The transcripts are the single richest source, and they are the only one that exposes the cache write lifetime split.
2. **Subscription quota** has exactly one documented, authoritative source: the `rate_limits` object that Claude Code passes to a configured status line command. Nothing else documented reports subscription utilization. The application therefore ships a tiny status line helper (`ccu-statusline`) as its authoritative quota source.
3. **Quota is not derivable from tokens.** Anthropic does not document a conversion, and the account figure also includes usage the application cannot see. The application never computes a quota percentage from tokens. See [QUOTA.md](QUOTA.md).
4. **OpenTelemetry** adds nothing that the transcripts do not already contain, but it needs a collector process to receive data. It is deliberately not implemented. The identity model (request keyed by the API message id, with the server `request_id` stored alongside) is compatible with it, so adding it later would not double count.
5. **Claude Desktop Chat, Cowork, claude.ai and other devices cannot be monitored.** Their usage counts toward the account quota but leaves no local trace. This is shown in the interface and never hidden.
6. **Undocumented interfaces are not relied on.** `plan-usage-history.json` is available as an opt-in, clearly labelled "unverified" hint that never reaches the menu bar or alerts. The private OAuth usage endpoint that some community tools call was not used: it depends on reusing Claude Code's credentials, which the requirements exclude.

## 4. OpenAI source audit (Codex, Codex Desktop, ChatGPT Work, ChatGPT Chat)

Findings come from this Mac's real data (232 Codex session files, 862 MB uncompressed, of which 212 are zstd-compressed) and from the fields the files themselves carry. Details, identity rules and validation are in [OPENAI-CODEX.md](OPENAI-CODEX.md).

| Source | Session | Account | Project | Model | Per-request tokens | Cache / reasoning | Quota % | Reset times | Cost |
|---|---|---|---|---|---|---|---|---|---|
| **Codex session files** (`~/.codex/sessions/**/rollout-*.jsonl[.zst]`, `archived_sessions/`) written by the Codex CLI, `codex exec`, the Codex desktop app, VS Code and JetBrains plugins, and the **Work mode of the ChatGPT desktop app** | Yes, with parent and fork lineage | Yes, `creator_account_id` on newer files (older ones carry none) | Yes (working directory) | Yes | **Yes**, one record per response | Cached input and reasoning, yes. Cache writes always zero. | **Yes**, `rate_limits` snapshot with every response | **Yes** | No |
| `state_5.sqlite` (`threads.tokens_used`) | Yes | Yes | Yes | Yes | No, one total per thread | No | No | No | No. Used **only** as a cross-check. |
| **ChatGPT Chat** (conversations in the ChatGPT app) | Not exposed | Not exposed | n/a | Not exposed | **Not exposed** | Not exposed | **Not exposed**, and its limits are separate from Codex | | |
| `auth.json` | | | | | | | | | **Never read.** It holds credentials. |

Conclusions:

1. **Codex and Work are one engine.** The header's `originator` names the application (`codex_work_desktop`, `Codex Desktop`, `codex_exec`, `codex_vscode`, `JetBrains.*`), and that decides the product (Codex or ChatGPT Work) and the surface. Both products read from the same files and draw on one allowance, so they share one quota pool per account.
2. **Quota is in the log.** Each response carries the account's `rate_limits`, so no helper needs installing. The figures are snapshots written when a response completes, so they are marked stale between responses.
3. **A window is identified by its length**, never by whether Codex calls it primary or secondary, because a plan may have only a weekly window.
4. **ChatGPT Chat is not observable** and is shown as such, with its own pool that never receives a figure.
5. **OpenAI prices are built in for the models whose prices OpenAI publishes** (read 2026-10-20). A model OpenAI does not list, such as `codex-auto-review`, is unpriced until the user adds a price (Settings → Cost → Add a price).

## 5. Logical architecture

Everything lives in one process. The boundaries are logical, enforced by module and type boundaries rather than by processes or services.

```
                        ┌───────────────────────────── UsageUI (SwiftUI) ───────────────────────────┐
                        │ MenuBarExtra · Dashboard (scope bar) · Settings · AppModel (@Observable)  │
                        └───────────────▲──────────────────────────────▲────────────────────────────┘
                                        │ reads                        │ commands
┌──────────────────────────────────────── UsageCore (names no provider) ─────────────────────────────────────────┐
│  Registry (data)           ProviderRegistry: providers · products · surfaces · pools · sources                 │
│  Collection                UsageCollector (actor) ── FSEvents + reconcile ── retry / backoff / per-source health│
│  Source adapters (plug in) SourceAdapter ──► LineParser ──► NormalizedBatch                                    │
│                            (ClaudeCodeAdapter, CodexAdapter, …)        Observation types: Request · Session ·  │
│                                                                         Quota · CostReport · Agent             │
│  Persistence               FileSynchronizer (checkpoints, zstd) ──► IngestWriter + EntityResolver ──► SQLite   │
│  Analytics                 AnalyticsEngine · CostSQL/Pricing · ExportService                                    │
│  Quota                     QuotaStore (pool/window/cycle/snapshot) · QuotaCoordinator(QuotaFeed) · QuotaEvaluator│
│                            AlertEngine (account · pool · window · cycle)                                       │
│  Verification              SourceVerifier (Claude) · CodexVerifier — independent recounts                       │
└───────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Responsibility | Where it lives |
|---|---|
| Registry of providers, products, surfaces, pools and sources | `ProviderRegistry` (types), `BuiltinProviders.swift` (the data) |
| Usage collector | `UsageCollector`, `FileSynchronizer`, `FSEventsWatcher`, `ZstdFileReader` |
| Source adapters | `SourceAdapter`, `ClaudeCodeAdapter`, `CodexAdapter` |
| Normalization | `UsageMeasurement`, `RequestObservation`, `SessionObservation`, `QuotaObservation`, `NormalizedBatch` |
| Persistence | `UsageDatabase`, `Schema`, `IngestWriter`, `EntityResolver`, `QuotaStore` |
| Analytics | `AnalyticsEngine`, `PricingCatalog`, `CostSQL`, `ExportService` |
| Quota | `QuotaCoordinator`, `QuotaFeed`, `QuotaEvaluator`, `QuotaStateReader`, `AlertEngine` |
| Presentation | `UsageUI` |

### Targets

| Target | Purpose |
|---|---|
| `UsageCore` | All collection, storage, accounting, quota and analytics logic. Imports no UI framework and names no provider outside the designated files. |
| `CZstd` | The decompression half of Zstandard, vendored (Codex compresses older sessions and macOS has no usable `libzstd`). Provenance and checksum in `Sources/CZstd/README.md`. |
| `UsageUI` | SwiftUI views and the observable `AppModel`. |
| `ClaudeUsageMonitor` | The `@main` app, shown to users as **AI Usage Monitor**. |
| `ccu` | Command line front end: import, verify, cost check, export, benchmark, for both providers. |
| `ccu-statusline` | Status line helper that Claude Code runs. |

## 6. Why these choices

* **Native Swift and SwiftUI with Swift Charts**, as preferred. The core is plain Swift with SQLite through the system C library. There are **no third-party dependencies**.
* **A custom streaming JSON scanner** instead of `JSONDecoder`. Transcript lines can be megabytes (tool output, file contents, model replies). The scanner walks only the handful of fields needed and skips everything else without allocating it. That is what keeps a 4.7 GB import at about 5 seconds and 50 MB of memory, and it also means prompt and response text is never decoded, let alone stored.
* **SQLite with WAL** and a single serialized writer plus a small pool of read-only connections. Readers never block the writer.
* **FSEvents plus a low-frequency reconciliation pass.** FSEvents is kernel driven, so an idle watcher costs no wake-ups. Reconciliation compares file size, modification time and inode against the stored checkpoints (no content reads) every ten minutes, after wake, and after any `MustScanSubDirs` or dropped-event flag, so lost events are always recovered.
* **Observed beats inferred** for session lifecycle: the live process registry is used when it exists, and inference from recent activity is always labelled as inference.
* **One process.** No daemon, no XPC service, no login helper. The menu bar app is the long-running component, started at login through `SMAppService` (or an optional LaunchAgent).

## 7. Background lifecycle

* **Start:** the collector reconciles (import on first run, catch-up afterwards), starts FSEvents watchers for every adapter's folders (Claude transcripts, Codex `sessions` and `archived_sessions`), the process registry and the quota feed folder, and the quota coordinator reads existing quota files.
* **Running:** file events are coalesced for 250 ms, then only the appended bytes are parsed. Quota changes are applied immediately. The user interface is refreshed at most once every two seconds, and only while a window is showing. With every window closed, only cheap state is kept current.
* **Sleep and wake:** `NSWorkspace.didWakeNotification` triggers a reconciliation and a quota re-read. Time-zone, clock and calendar-day changes trigger a refresh, since bucketing is always computed at query time.
* **Crash or reboot:** all state is on disk. The next launch resumes from durable checkpoints, runs an integrity check if the previous shutdown was not clean, and replays anything missed. A crash cannot lose or duplicate usage because observations and their checkpoint commit in one transaction and every observation is idempotent.
* **One collector:** the first copy takes a lock in the data folder, a second copy brings the first forward and exits, and the lock is released by the system when the process ends, however it ends.
* **Whole-file sources:** a source that must read a file from the top (Codex) commits one file at a time, so an interruption leaves nothing half-counted. What it could not settle exactly is saved as accounting notes that replace the file's previous ones.
* **Failure containment:** each source adapter and each file has its own error boundary. A failure is recorded with a message, retried with exponential backoff (5 s doubling to 15 min, with jitter), and surfaced in Diagnostics. Other sources continue.
