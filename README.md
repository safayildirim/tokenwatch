# AI Usage Monitor

A native macOS menu bar app that watches your AI coding usage in the background, across providers: **Claude Code** (terminal, VS Code, Claude Desktop's Code tab) and **OpenAI's Codex engine** (Codex CLI, Codex Desktop, the IDE plugins and the Work mode of the ChatGPT desktop app). It gives exact token accounting, an analytics dashboard, and your **real** subscription quota when the provider reports it. Other providers plug in through a registry and an adapter (see [SOURCE-ADAPTERS](docs/SOURCE-ADAPTERS.md)).

* **Local-first.** No network access. Only usage metadata is stored: token counts, model names, timestamps, project folder names, session ids. Never prompts, replies, file contents, environment variables or credentials.
* **Exact.** Token totals match an independent recount of the original files to the token (see [VALIDATION](docs/VALIDATION.md)). Streaming snapshots, replays after compaction and forked sub-agents are deduplicated, so cache tokens are not counted two to three times over.
* **Honest about quota.** Percentages come only from the provider's own reports (Claude's `rate_limits`, Codex's `rate_limits` snapshots). They are never derived from token counts, they belong to one pool of one account, and pools are never added together. When nothing has been reported, the app says "Unavailable". ChatGPT Chat and Claude chat cannot be observed, and the app says that too.
* **Light.** About 66 MB resident and effectively 0 % CPU when idle. A 5.7 GB history (Claude and Codex) imports in about 7 seconds.

| Menu bar popover | Dashboard overview |
|---|---|
| <img src="docs/images/menubar-popover.png" width="300"> | <img src="docs/images/dashboard-overview.png" width="640"> |

More views: [usage trends](docs/images/dashboard-trends.png), [session explorer](docs/images/dashboard-sessions.png), [session detail](docs/images/session-detail.png), [models](docs/images/dashboard-models.png), [dark mode](docs/images/dashboard-overview-dark.png).

*The screenshots in `docs/images` predate the multi-provider interface and show Claude only; they use synthetic demo data (`scripts/make-demo-data.py`), including an illustrative quota reading, so nothing in them is anyone's real usage.*

## Requirements

* macOS 15 or later (built and tested on macOS 26)
* Xcode 26 / Swift 6.2 to build. No third-party dependencies.

## Build and install

```bash
scripts/build-app.sh        # builds build/AI Usage Monitor.app (optimized, ad-hoc signed)
scripts/install.sh          # copies it to /Applications (or ~/Applications) and starts it
```

`scripts/build-app.sh --universal` builds for Apple silicon and Intel.

This is a menu bar app with no Dock icon, so look for the ✦ icon at the top right of the screen. If your menu bar is full, macOS hides new icons under the notch; the app detects that and shows a Dock icon instead (or turn on Settings → General → *Show in the Dock*). Opening the app from Applications opens the dashboard (as does the very first launch). The first launch imports your existing Claude Code history automatically. Watch the progress in the menu bar popover. Nothing needs to be registered: new sessions, projects and IDEs are discovered on their own.

### Launch at login

Pick one:

1. **In the app:** Settings → General → *Launch at login* (uses `SMAppService`). macOS may ask you to approve it in System Settings → General → Login Items. The app should be installed in `/Applications` or `~/Applications`.
2. **From a terminal:** `"/Applications/AI Usage Monitor.app/Contents/MacOS/ClaudeUsageMonitor" --login-item enable` (also `disable` and `status`).
3. **LaunchAgent**, which also restarts the app if it ever crashes: `scripts/install-launchagent.sh` (remove with `--remove`).

The app needs no terminal and no open window to keep collecting.

## Using it

### Menu bar

Click the icon for a section per provider (its quota pools with countdowns, and active sessions), new tokens per provider today and this week, recent sessions across providers (click one to open its details), and quick actions (Open Dashboard ⌘D, Refresh ⌘R, Settings ⌘,, Quit ⌘Q).

Settings → General chooses what the menu bar shows next to the icon: icon only, **Claude quota** (`63% · 81%`), **OpenAI quota**, the short window of **every provider** (`C 63% · O 12%`), the **highest utilization** among all pools (a comparison, never a sum), or the active session count. Nothing is shown for a provider that has no figure, and `63%*` means the last known value, over an hour old.

### Dashboard

| Page | What it answers |
|---|---|
| Overview | Tokens today / week / month, active and total sessions, quota pools, cache hit ratio, reasoning tokens, token mix, a by-provider card, 14-day activity, top models and projects |
| Usage Trends | Hourly, daily, weekly, monthly or custom ranges. Total tokens, input vs output, cache read vs creation, all categories, sessions, requests, by model, by project, cost. Hover for exact values; the Table switch gives an accessible listing |
| Sessions | Searchable, sortable table with filters for project, model, status and date range, and the product, surface and account of every session. Open any session for its full breakdown |
| Session detail | Token breakdown (every category, 5 m / 1 h split), models, sub-agents and their combined usage, request timeline, cache efficiency, cost (estimate and Claude Code's own figure side by side), quota-window context |
| Projects / Models | Aggregates with trends. Double-click a project to see its sessions |
| Cost | API-equivalent estimates per provider and model, with unpriced usage called out |
| Quota | Every pool by provider and account, with each window, history, the products that are not observable, setup, and what the numbers mean |
| Providers | Per provider: products, data sources and their health, quota pools, and a **capability matrix** of what each source reports |
| Diagnostics | Database checks, **independent verification against the source files** (both providers), rebuild, resource use, recent problems |

A **scope bar** above every page filters by provider, product, account and surface. The date range, model, project and search filters belong to the pages that offer them.

"**New** tokens" means uncached input + cache writes + output. "**Processed**" also includes cache reads. Both are always labelled. Definitions: [TOKEN-ACCOUNTING](docs/TOKEN-ACCOUNTING.md).

### Quota setup

**Codex needs none**: it writes its own quota snapshots into its session files, so they appear as soon as you use it.

**Claude (one minute).** Claude Code reports subscription usage only to a configured status line. Open **Settings → Quota → Install helper…** (or the Quota page). The app shows exactly what it will change, makes a backup of `~/.claude/settings.json`, adds a `statusLine` entry without disturbing anything else, and keeps any status line you already have working. Then start a new terminal Claude Code session and send a message; quota appears.

Details, limits and manual setup: [QUOTA](docs/QUOTA.md). Quota can only be reported while a terminal Claude Code session is in use, and only for subscribers.

### Notifications

Optional, off by default (Settings → Notifications). Thresholds for each window, reset, stale-data and collection-failure alerts. Each is delivered once; none ever uses a token-based estimate.

### Export

Settings → Export, or `ccu export`. Session history, request-level usage, project and model summaries, daily and weekly totals, quota history, as CSV or JSON, for any date range. Every column's definition and unit is included (in the JSON, or a companion `.metadata.json` next to a CSV). Costs are exact decimals. Text cells that could be read as spreadsheet formulas are neutralized.

### Data retention and deletion

Settings → Data: keep history forever or for 90 days to 2 years, and delete everything the app has collected. Your original Claude Code files are never modified.

## Command line tool

`build/AI Usage Monitor.app/Contents/MacOS/ccu` uses the same core as the app.

```bash
ccu import                 # Claude and Codex; incremental and idempotent (--provider claude|openai)
ccu totals
ccu verify                 # recount every token from the original files with different code, and compare
ccu cost-check             # estimated cost vs the cost Claude Code recorded
ccu sessions --limit 10
ccu quota
ccu export --kind requests --format csv --out requests.csv
ccu bench                  # import into a scratch database and time it
```

Use `--db PATH`, `--root PATH` (Claude) and `--codex-home PATH` (Codex) to work on other locations, or set `CLAUDE_USAGE_MONITOR_DATA_DIR` to run against a scratch data folder.

## Tests

```bash
swift test
```

254 tests: token accounting and deduplication for both providers, Codex file shapes (event, usage-record, fork, compacted, compressed, damaged, archived), OpenAI quota (pools, windows, cycles, freshness, out-of-order, shared pool), alert identity, provider isolation and a made-up third provider through the whole pipeline, session discovery (including real FSEvents), persistence and concurrency, calendar and DST boundaries, cost, export, privacy, the app's state machine, and offscreen rendering of every page in light and dark. Results and what each group proves: [VALIDATION](docs/VALIDATION.md).

## Privacy and security

* No outbound network connections, no analytics, no telemetry. (Check with `lsof -i -a -p $(pgrep ClaudeUsageMonitor)`.)
* The line parser skips message content without decoding it. A test plants secrets in prompts, replies, tool output and titles and asserts they never reach the database, its WAL, or any export.
* The status line helper stores only the rate-limit figures and session id, with `0600` permissions, and never exits non-zero.
* The Claude Code `.key` files (peer tokens) and Codex's `auth.json` are never opened. No credentials are read, stored or transmitted. Account identifiers are stored only as one-way hashes.
* The app is not sandboxed because it must read `~/.claude`. It does not weaken any macOS protection and asks for no special permission.

## Documentation

* [Architecture and source audit (capability matrix)](docs/ARCHITECTURE.md)
* [Token accounting rules](docs/TOKEN-ACCOUNTING.md)
* [Quota integration and limitations](docs/QUOTA.md)
* [Database schema, integrity and migrations](docs/SCHEMA.md)
* [OpenAI: Codex, Codex Desktop and ChatGPT Work](docs/OPENAI-CODEX.md)
* [Source adapters and adding a provider](docs/SOURCE-ADAPTERS.md)
* [Performance measurements](docs/PERFORMANCE.md)
* [Validation and test results](docs/VALIDATION.md)

## Known limitations

* **Only coding tools are observable.** claude.ai chat, Cowork, Claude Desktop chat, ChatGPT Chat and other devices consume quota but leave no local record. Local token totals can therefore be lower than your real consumption, and the dashboard says so.
* **Quota needs the status line helper, and a terminal session.** VS Code and Desktop Code sessions do not run the status line, so quota refreshes only while the terminal CLI is in use; otherwise the last value is shown as stale.
* **The quota feed has not been exercised against a live subscription session in this build.** The helper, the evaluator and the coordinator are tested end to end with realistic documented input, but the live `rate_limits` payload from your account is unverified until you install the helper and run a terminal session.
* **Session status is inferred** for sessions with no running process (finished ones, and history). It is labelled as such.
* **No per-session quota attribution.** It is not possible, and the app does not fake it.
* **Costs are list-price estimates**, not charges. Only Anthropic prices ship. OpenAI usage is shown as unpriced until you add a published price under Settings → Cost, because those prices could not be verified from this Mac.
* **Codex's snapshot format is alpha** (`0.162.0-alpha`). The parser is tolerant, but a future change of shape could need an update.
* **Codex sessions without an account id** (older files) belong to an explicit "unassigned" account and are not guessed into another.
* **Cost and token volume are not comparable across providers.** Tokenizers differ, so the dashboard shows providers side by side and never adds them.
* **A file rewritten in place in the middle** (not its first 4 KB, not appended, same inode, not shorter) is not detected until rebuilt. Claude Code only appends, so this is not expected.
* **Ad-hoc signing.** The app runs locally; to distribute it, sign with a Developer ID and notarize.
* **Parent/child session lineage across resumed sessions** is not recorded by Claude Code in a way the app can read, so sessions have no parent link. Sub-agents are attributed to their parent session.

## Possible future enhancements

* A Claude Code OpenTelemetry source (identity-compatible; would add a local OTLP receiver).
* Developer ID signing, notarization and a Sparkle-style updater.
* A Gemini adapter (a compile-time fixture in the tests already shows the pipeline accepts one without core changes).
* Optional session titles, stored only on opt-in.
* A WidgetKit widget for quota.
