# Subscription quota: how it works and its limits

## The rule

> A quota percentage is shown only if Claude itself reported it. It is **never** computed from token counts.

Claude's subscription metering depends on more than raw tokens, and the account figure also includes usage this application cannot see (claude.ai chat, Cowork, other devices). There is no documented conversion, so any token-based "percentage" would be a guess presented as a fact. The application does not produce one anywhere: not in the menu bar, not in the dashboard, not in alerts, not in exports. A test feeds 50 million tokens of local usage into a quota coordinator and asserts that every window is still "Unavailable".

## Where Claude quota comes from

Claude Code now keeps a local usage snapshot. Tokenwatch reads that snapshot automatically, without a helper and without an account sign-in. The status line helper remains available as an optional, complementary source.

| Source | Setup | What it provides | Freshness |
|---|---|---|---|
| **Claude Code local cache** (`~/.claude.json`) | None; discovered automatically | The last `cachedUsageUtilization` snapshot written by Claude Code: five-hour, weekly, and model-scoped windows | Measured from `cachedUsageUtilization.fetchedAtMs`; fresh for 1 hour, ageing to 2 hours, then stale |
| **Status line helper** (`tw-statusline`) | Optional; install from Settings → Quota | Documented `rate_limits` from a terminal Claude Code session, including reset times | Measured from the session's last API activity; fresh for 10 minutes, ageing to 1 hour, then stale |
| **Claude Desktop plan-history hint** | Opt-in, off by default | Two undocumented fields that look like five-hour and weekly percentages | Not authoritative; labelled unverified and never used for alerts |
| **Codex session files** | None | OpenAI's own quota snapshots, including reset times | Read by the OpenAI adapter |

The cache is the primary source because it needs no configuration. The status line is not required and does not replace the cache: it is a second provider observation that can be newer, carry reset times, or fill a gap when the cache is absent. Both go through the same pool, snapshot and evaluator model. There is no separate quota system.

## The primary source: Claude Code's local usage cache

Claude Code writes a `cachedUsageUtilization` object inside its configuration file. Tokenwatch reads:

* `$CLAUDE_CONFIG_DIR/.claude.json` when `CLAUDE_CONFIG_DIR` is an absolute path, and
* `~/.claude.json` otherwise.

The path that was actually used is shown in **Settings → Quota → Claude quota diagnostics**. A GUI app launched from Finder does not inherit a shell-only `CLAUDE_CONFIG_DIR`; the diagnostics screen makes that difference visible instead of silently reading the wrong file.

The cache is **not a documented integration contract**. Its layout is written by Claude Code and can change between versions. Tokenwatch validates the shape it knows and reports anything it cannot use; it does not guess.

### What is read

The cache carries one snapshot, for example (values are illustrative, not copied from an account):

```json
"cachedUsageUtilization": {
  "fetchedAtMs": 1792648229071,
  "accountUuid": "…",
  "utilization": {
    "five_hour":   { "utilization": 23, "resets_at": "2026-10-22T12:00:00+00:00" },
    "seven_day":   { "utilization": 41, "resets_at": "2026-10-23T00:00:00+00:00" },
    "limits": [
      { "kind": "session",       "percent": 23 },
      { "kind": "weekly_all",    "percent": 41 },
      { "kind": "weekly_scoped", "percent": 7,
        "scope": { "model": { "id": null, "display_name": "Fable" } } }
    ],
    "seven_day_opus": null,
    "seven_day_sonnet": null
  }
}
```

The adapter supports:

* `five_hour` and `seven_day`, the shared subscription windows;
* `limits` entries of kind `session` and `weekly_all` as a fallback when the corresponding top-level window has no percentage;
* `weekly_scoped` limits, with a model display name and/or model identifier;
* the older flat `seven_day_opus` and `seven_day_sonnet` fields, only when the structured list does not already describe the same scope.

**Scoped windows are not identified by duration alone.** Two weekly limits have the same length and different allowances, so a scoped window's key carries its identity (model id or normalized display name) as well as its 10,080 minutes. A `Fable` scoped limit therefore remains a separate row from the weekly all-model window, and is never presented as `seven_day_opus`, `seven_day_sonnet`, or as part of the weekly percentage. A null model id with a display name is valid; a null name with a model id uses the id as a technical label; a scoped entry with neither is skipped rather than merged into another window.

`spend_limit` is deliberately not synthesized from cache fields whose meaning is not established. The status line's documented `spend_limit` window is handled separately when present.

### What is ignored

`utilization` also contains fields for spend, extra usage, named variants and scoped shares (`weekly_scoped_shares`). Tokenwatch ignores them unless they are one of the windows above. They do not become percentages, and they cannot change a reported percentage. Unknown fields and unknown limit kinds are skipped; a malformed known window invalidates only that window and is reported as a collection issue. If the snapshot has no trustworthy `fetchedAtMs`, account identifier, or `utilization` object, none of it is used and the reason is reported.

### Observation time is not file time

`cachedUsageUtilization.fetchedAtMs` is the observation time. **The file's modification time is never used.** Claude Code writes unrelated settings to `.claude.json`, and those writes move the modification time without refreshing quota. On the machine used for development, the file was modified at `11:42 +03:00` while the usage snapshot said `05:50 UTC`; using the mtime would have shown a three-hour-old figure as current.

The cache does not say when Claude Code will fetch usage again. It appears to be written when Claude Code fetches usage (opening `/usage` is the practical way to ask for a refresh), but that relationship is **not documented and was not verified** against a live interactive `/usage` screen. A cache reading is always presented as a snapshot, never as a live meter.

### Safe, read-only file access

The cache is opened `O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK`, and must be:

* a regular file,
* owned by the current user,
* not a symlink and not a hard link (`st_nlink == 1`),
* private to the owner (no group or other permission bits), and
* at most 16 MiB.

The parser walks the JSON and materializes only `cachedUsageUtilization`. It does not inspect, retain, log or transmit credentials, cookies, project paths, settings or conversation data, and it never writes to the file. No network request is made, no OAuth token is refreshed, and no credential store is opened.

The account identifier is reduced to a short one-way hash. The raw identifier is not stored or displayed. The hash identifies the account that owns the cache's readings, so cache readings are stored in that account's pool (shown as, for example, "Account 1a2b3c"), and a change of the hash is reported as an account change.

### Atomic replacement and missed writes

Claude Code may replace `.claude.json` atomically. Tokenwatch watches the file's inode rather than the whole home directory, sees the rename/delete, and re-arms the watch on the path. A read that catches a half-written or replaced file produces a reported parse issue, never a partial snapshot; the previous snapshots remain in history. A safety-net refresh covers a missed file event.

## The optional status line

Claude Code documents a `statusLine` setting. The configured command receives a JSON document on standard input that, for Claude.ai Pro and Max subscribers, includes:

```json
"rate_limits": {
  "five_hour":  { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day":  { "used_percentage": 41.2, "resets_at": 1738857600 },
  "spend_limit": { "used_percentage": 62.8, "resets_at": 1740787200 }   // only behind a Claude apps gateway
}
```

`resets_at` is Unix epoch seconds. Each window can be absent. The field appears only after the session's first API response, only for subscribers (not API-key users), and Claude Code drops a window once its reset time passes.

The application ships a helper, `tw-statusline`, that Claude Code runs as that command.

### What the helper does

1. Reads the JSON from standard input (bounded to 4 MB).
2. Copies **only** the `rate_limits` windows, the session id, and a fingerprint into `~/Library/Application Support/Tokenwatch/quota/statusline-<session>.json` (mode 0600, written atomically). The model, working directory, transcript path and cost are never stored.
3. If the user already had a status line, runs it (`--chain`) with the identical input and passes its output through, so their existing status line looks and behaves the same. Otherwise it prints `5h 24% · 7d 41%`.
4. Always exits 0, so it can never break the status line, even on garbage input.

### Freshness, honestly

Claude Code re-runs the status line when it re-renders, not only when something new happened. A session that has been idle for hours would therefore keep reporting its last known numbers. The helper includes a fingerprint of the session's API activity (`total_api_duration_ms`, `total_cost_usd`) and the rate-limit values; the "observed at" time is **updated only when the fingerprint changes**, so a re-render never makes stale numbers look fresh. An identical re-render leaves the file untouched.

The status line source is optional. If it is not installed, the cache still works. If both report, their values are kept as separate observations with separate timestamps and provenance.

## How a displayed figure is chosen

The cache and status line are not averaged, added, or treated as one value. Each observation is stored in the existing provider/account/pool/window/cycle/snapshot model. A snapshot is identified by `(window, cycle, percentage, authority)`; a later confirmation of the same percentage updates `last_confirmed_at` and provenance instead of creating a duplicate row.

For each window, the evaluator:

1. Drops unverified observations unless the user opted in.
2. Prefers an authoritative observation.
3. Prefers a reading whose reset time is still in the future. A closed window must not hide a newer open one.
4. Chooses the newest provider observation. A report delivered late therefore cannot replace a newer one.
5. If observations carry exactly the same timestamp, prefers the documented status line over the local cache, and the cache over the undocumented Desktop hint. A source never wins merely by reporting a larger percentage.
6. Only after those rules may the same source's earlier reading in the same cycle raise the chosen value (utilization only grows within a cycle; a lower value that arrives later may be a response that started earlier). This growth rule is deliberately limited to the selected source. Two different sources that disagree are **not** reconciled by taking the larger number.

When two sources describe the same cycle within 15 minutes and differ by at least one percentage point, the difference is surfaced as a disagreement: the selected reading is shown and the alternatives are named, with their source and time. They are never averaged. A cache fetched twenty minutes before a status-line reading normally has a lower percentage because usage has grown; that is not labelled a conflict.

These rules apply to the sources that report into the same pool. Cache readings belong to the hashed account and status-line readings to the unassigned pool (see [Account changes](#account-changes)), so the cache and the status line are no longer compared with each other: each pool shows its own newest reading.

A missing reading is not zero. A window whose reset time has passed is **elapsed and unknown** until a source reports the new window. A malformed window is skipped individually; it is not converted into 0%.

### Account changes

The cache contains an account identifier; the status line contains none. Tokenwatch hashes the cache identifier and stores each cache reading in the pool of that account. When the hash changes, the app warns that the account changed, and the readings of the new account start a pool of their own. The history of the earlier account stays in its own pool and is never averaged with, overwritten by, or merged into the new one.

Status-line readings name no account, so they stay in the explicit **unassigned** Anthropic pool. They are never matched to the cache's account by timestamp, reset time or percentage, because that would be a guess. The consequence is a stated limitation: when the optional status line is installed, one subscription appears twice, once as the identified account (from the cache) and once as *unassigned* (from the status line). The two pools are evaluated, displayed and alerted on independently, so a threshold that both sources see can be announced twice. The menu bar shows whichever pool reported most recently.

Cache readings stored by versions before this change sit in the unassigned pool. They are kept as history and are not moved, and they become stale like any other reading.

## Display model and freshness

Each window shows percent consumed, percent remaining, reset time and countdown, when it was last updated, where it came from, and its freshness.

| State | When | Shown as |
|---|---|---|
| Available, fresh | Cache ≤ 1 hour old; status line ≤ 10 minutes old | Bar and numbers |
| Available, ageing | Cache 1–2 hours old; status line 10–60 minutes old | Bar and numbers, with age and source |
| Available, **stale** | Cache over 2 hours old; status line over 1 hour old | Dimmed bar, "Stale: last updated …". The menu bar adds `*` to the last known value |
| **Window elapsed** | `resets_at` has passed | "This window reset … ago. The new value appears after Claude Code next reports it." The new utilization is **not** assumed to be zero |
| **Unavailable** | Never reported | "Unavailable", with an Open Limits button; the menu bar shows a dash |
| Unverified | Only from the opt-in Desktop cache | Labelled "unverified". Never in the menu bar, never in alerts |
| Source disagreement | Two sources report the same cycle within 15 minutes and differ | The selected value plus the alternatives, never an average |

The cache's one-hour/two-hour boundaries are deliberately wider than the status line's ten-minute/one-hour boundaries: a cache is a snapshot Claude Code refreshes only when it fetches usage, while the status line can update during a live session. Neither boundary makes old data fresh. The UI shows the source on every window.

### Scoped windows

The five-hour window (`300m`), the weekly all-model window (`10080m`), and each model-scoped weekly limit are distinct rows. They are never combined. A scoped window's label is the provider's display name (`Fable` in the observed cache); if only a model id exists, the id is used as a technical label. A scoped window is not a claim that the model id is known, and a scoped share (`allowance_percent_of_weekly` or `weekly_scoped_shares`) is not converted into a new percentage.

This matters when the numbers appear contradictory: a weekly all-model figure can be near its limit while a model-scoped window is at 0% of a *different* allowance. Showing one as the other would be a fabricated reading.

## Installing the optional status line helper

The app does it from Settings → Quota (or the Quota page) after an explicit confirmation. It edits `~/.claude/settings.json` **surgically as text** so the rest of the file (formatting, key order, everything) is byte-for-byte preserved:

* It makes a timestamped backup next to the file first.
* If you have no `statusLine`, it inserts one. If you have one, the helper is placed in front of it as `"<helper>" --chain '<your command>'` and your other `statusLine` options (such as `padding`) are kept.
* The edited document is re-parsed; if it would not be valid JSON, nothing is written.
* Invalid existing JSON, or a non-command status line, is never modified.
* Removing the helper restores your original command.

**Rehearsal that changes nothing:** `tw statusline-check` reads your settings, installs the helper into a **copy**, shows the command that would be written, confirms the rest of the file is byte for byte the same and that uninstalling restores it exactly, then runs that command with a made-up payload and prints what the app would parse. It touches neither your settings nor your account.

Manual setup, if you prefer: add this to `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "/Applications/Tokenwatch.app/Contents/MacOS/tw-statusline" }
```

Settings in a project's `.claude/settings.json` or `settings.local.json` override the user file. A project that defines its own status line needs the same helper there. The command points at the helper inside the app bundle; if the app is moved or deleted while the helper is installed, uninstall the helper first.

## Freshness guarantees

A quota reading is only ever as fresh as the moment it was **taken**. Reading it again never makes it fresher. The times involved are kept apart:

| Time | Meaning | Where it lives |
|---|---|---|
| Event time | When the provider's software wrote the reading (cache: `fetchedAtMs`; status line: the moment the helper saw the session make an API call) | `quota_snapshot.observed_at` (first) and `last_confirmed_at` (latest confirmation of the same value) |
| Source-reported time | A timestamp inside the reading itself | The cache supplies `fetchedAtMs`; the status line supplies its own fingerprint/observed time. The documentation supplies no separate quota timestamp for Codex |
| Reset time | When the window resets | `resets_at`, and it identifies the cycle |
| Ingestion time | When this app read the file | **Not stored for quota at all.** Nothing in the freshness path can use it |

Consequences, each covered by a test:

* An old cache read again (restart, touched, copied, archived, database rebuilt) gives the same readings with the same times, and the same stale state.
* A rewritten cache with the same `fetchedAtMs` and values does not create a new snapshot.
* An archived snapshot newer than an active one wins, whichever file was read first. Out-of-order delivery cannot replace a newer reading.
* A reading dated more than five minutes in the future (a clock that was wrong when it was written) is not recorded. A reading dated more than five minutes later than the current time (the clock was moved back) is shown as stale instead of new.
* A cycle changes only when the reset time moves by more than 30 seconds. A new cycle does not inherit the previous one's higher value, and a window whose reset time has passed is **unknown, never zero**, until the provider reports it again.
* A window with no current value shows a dash in the menu bar in its own place, never the other window's figure.
* Different named pools and different named accounts are different rows and are never merged. Cache readings belong to the hashed account; status-line readings, which carry no identity, share the explicit unassigned pool; readings of one account from two sessions that run at once are combined by the in-cycle rule above.

The cache's `fetchedAtMs` is the only observation time used. The file's modification time, the app's start time, and the time the app read the file are not substitutes.

## Alerts

Notifications are optional and off by default. They use only authoritative readings of an open window that are not stale. That means cache readings remain eligible for up to two hours, and status-line readings for up to one hour; the freshness boundary is shown in the UI.

* Thresholds are configurable per window (default 50/75/90 five-hour, 75/90 weekly).
* A threshold is announced **once per window instance**. A window instance is identified by its reset time, and fired thresholds are stored durably, so restarts and refreshes of stale data never repeat an alert.
* Jumping over several thresholds announces only the highest; the lower ones are consumed.
* Reset notifications fire once, only after the window had passed 50 %.
* A stale-data alert fires once per stale episode, only while Claude Code is demonstrably in use.
* A collection-failure alert fires once per distinct persistent failure and re-arms after recovery.

## Multi-provider quota model

Quota is stored and evaluated the same way for every provider.

| Level | Meaning |
|---|---|
| Pool | An allowance of one account. Products that share an allowance share a pool (Claude Code and Claude chat; Codex and ChatGPT Work). A named account is never merged with another; the explicit *unassigned* pool holds readings whose source names no account, and can therefore contain readings from more than one physical Claude account, as a stated limitation. |
| Window | One limit inside a pool, identified by its length (`300m`, `10080m`) or, when it has no fixed length, by a name (`spend_limit`). A model-scoped weekly limit has a key that also carries its scope identity, so two limits of the same duration never collapse. |
| Cycle | The period between two resets. Reports of one cycle disagree on the reset time by seconds, so a report joins the cycle whose reset is within 30 seconds. Two pools whose windows began a minute apart are different cycles. |
| Snapshot | A reported utilization within a cycle. Identical reports extend one snapshot's *last confirmed* time instead of adding rows. |

Sources reach the store in two ways: a **quota feed** (`QuotaFeed`) that the coordinator reads and watches (Claude's local cache and optional status line; Claude Desktop's undocumented cache, which is opt-in, unverified and never stored), or an adapter that emits snapshots together with the usage it reads (Codex). The state shown to the user is always evaluated from the stored snapshots:

* the reading that was confirmed most recently wins, so out-of-order delivery cannot replace a newer one;
* a reading whose window is still open beats one whose window has closed;
* freshness is measured from the provider's observation time, with source-specific boundaries (cache 1 hour/2 hours; status line 10 minutes/1 hour; then stale);
* after a reset the window is *elapsed* and shown as unknown, never as zero;
* a pool the registry knows but that has never reported is listed with its standard windows unavailable, to explain the gap. A pool that is explicitly not observable (ChatGPT Chat) never gets a figure.

Alerts are identified by **account, pool, window and cycle**, and use the same windows: a threshold is announced once per cycle, and a reset is announced once. Thresholds are configured for windows of a day or less and for longer ones.

The menu bar offers *highest utilization*, which compares the displayable windows of all pools and shows the largest. Percentages of different pools are never added.

## From quota history to capacity

Quota history says what the provider reported. Capacity analysis compares **how much quota percentage different plans spent on the same normalized local work**. It is a separate, on-demand read path over the same snapshots; it does not change what the menu bar, alerts, or quota pages show.

* Only **authoritative** snapshots become capacity intervals. Cache readings are authoritative provider observations; status-line readings are authoritative; the unverified Desktop hint never is.
* The five-hour (`300m`) and weekly (`10080m`) windows are analyzed independently. A cycle is never merged across a reset, and a lower reading inside one cycle is skipped, never treated as a new cycle.
* Local work is normalized by API-equivalent list cost, not by tokens and not by the provider's undocumented metering. The provider percentage remains the only quota quantity.
* A plan period is a half-open manual (or provider-reported) annotation. Cache readings belong to the hashed account that the cache names, and status-line readings belong to the unassigned account. The app never attributes a status-line reading to an account from timing, reset times, or the cache hash, so a plan period applies to the account it was recorded for.
* A ratio is published only when at least two independent cycles per plan and two matched pairs are available, or a comparable pooled fallback exists. Otherwise the result is **unknown**, not a number derived from advertised multipliers.
* The advertised five-hour multipliers (Pro 1×, Max 5x 5×, Max 20x 20×) are shown as references only. Weekly multipliers are not advertised and are not invented.

The method, evidence levels, matching rules, purchasing arithmetic and limitations are in [CAPACITY.md](CAPACITY.md).

## Known limitations

* **The cache schema is provider-written and undocumented.** It can change without notice. The adapter validates known shapes, skips unknown fields and malformed windows, and reports why a snapshot was not used; it cannot promise that a future Claude Code version will keep the same keys.
* **Cache refresh timing is undocumented.** The snapshot is refreshed when Claude Code fetches usage. On 2026-10-23, during an active Claude Code session, `fetchedAtMs` advanced four times within half an hour (06:42, 06:50, 06:51 and 07:03 local time), but whether `/usage` was opened in another terminal was not controlled, and the trigger is not documented. A reading may be hours old even though `.claude.json` was written seconds ago, and the app judges freshness only by `fetchedAtMs`.
* **No live `/usage` comparison was performed.** `/usage` is an interactive terminal screen and no supported non-interactive structured interface was found. The cache was validated read-only against the installed Claude Code, but the app does not claim that its display was compared side by side with `/usage`.
* **The cache does not report a subscription tier**, and the observed scoped `Fable` entry had a null model id. The app names the scope from the provider's label or id, but it cannot map a scoped window to a guaranteed model identity or plan.
* **The status line has no account identity.** Cache readings are stored per hashed account, but status-line readings stay unassigned. With the status line installed, one subscription is shown as two pools, and a threshold can be announced once for each. Cache history recorded before account attribution existed stays in the unassigned pool.
* **Status-line quota is terminal-only and subscriber-only.** The VS Code extension and Claude Desktop's Code tab do not run the status line. API-key users have no subscription windows. The local cache is read independently, so the status line is not required.
* **No history before Tokenwatch first reads a source.** Nothing reports past utilization to the app. Stored cache history begins at Tokenwatch's first usable read; status-line history begins when the helper is installed.
* **No per-session quota attribution.** The session pages show three separate quantities and never merge them: (1) the session's actual tokens, (2) its share of locally observed activity in each quota window, and (3) the account-level percentage Claude reported, with its peak in that window. Quota consumed on surfaces the app cannot observe is never attributed to local sessions.
* **The Desktop hint is unverified.** `plan-usage-history.json` has no confirmed meaning and no reset times. It is opt-in, labelled unverified, never shown in the menu bar, never used for alerts, and never treated as capacity evidence.
* **No credentials are used.** The app does not read OAuth tokens, cookies, Keychain records or Claude Code's `.key` files, does not refresh authentication, and makes no network request for quota. The cache is read locally and only its usage object is retained.

## How this was verified

Synthetic fixtures cover the real cache shape, structured-limit fallback, legacy and scoped windows, null model ids, malformed and unknown schemas, invalid timestamps and accounts, duplicate and atomic writes, permissions, symlinks and hard links, oversized files, stale readings, reset boundaries, conflicting sources, restart recovery, privacy and no-network behavior. The cache reader and coordinator are exercised end to end; the real installation was read with a read-only test that checks the file's bytes and modification time are unchanged.

On the development machine (Claude Code 2.1.305), the cache file was 119,704 bytes, mode `0600`, and the parser read it without error. Its `fetchedAtMs` was about 3.2 hours before the validation time while the file mtime was later, confirming that file time cannot be used as freshness. The observed snapshot contained a five-hour window at 0 %, a weekly all-model window at 99 %, and a model-scoped `Fable` window at 0 %; all were presented as stale, not as current. The account identifier was hashed and never printed.

No claim of a live `/usage` comparison is made. The interactive screen was not used as a source, and the cache refresh trigger remains documented here as unverified.
