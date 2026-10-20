# Subscription quota: how it works and its limits

## The rule

> A quota percentage is shown only if Claude itself reported it. It is **never** computed from token counts.

Claude's subscription metering depends on more than raw tokens, and the account figure also includes usage this application cannot see (claude.ai chat, Cowork, other devices). There is no documented conversion, so any token-based "percentage" would be a guess presented as a fact. The application does not produce one anywhere: not in the menu bar, not in the dashboard, not in alerts, not in exports. A test feeds 50 million tokens of local usage into a quota coordinator and asserts that every window is still "Unavailable".

## The authoritative source: Claude Code's status line

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

## Display model

For each window the application shows: percent consumed, percent remaining, the reset time and a live countdown, when it was last updated, where the figure came from, and its freshness.

| State | When | Shown as |
|---|---|---|
| Available, fresh | Reported within 10 minutes | Bar and numbers |
| Available, ageing | 10 to 60 minutes old | Bar and numbers, "Updated 25m ago" |
| Available, **stale** | Over an hour old | Dimmed bar, "Stale: last updated 3h ago". Menu bar shows `63%*` |
| **Window elapsed** | `resets_at` has passed | "This window reset 12m ago. The new value appears after Claude Code next reports it." The new utilization is **not** assumed to be zero |
| **Unavailable** | Never reported | "Unavailable", with a Set up button; menu bar shows a dash |
| Unverified | Only from the opt-in Desktop cache | Labelled "unverified". Never in the menu bar, never in alerts |

When several sessions report, a reading whose window is still open beats a closed one, then the most recently observed cycle wins, and within that cycle the highest reported value is shown (utilization only grows within a cycle, so a lower value that arrives later is a response that started earlier). Reset times of one cycle differ by seconds, so a report joins the cycle whose reset time is within 30 seconds of its own.

Quota events are push-driven (FSEvents on the quota folder). The coordinator also sleeps until the next moment a state could change on its own (a reset, or a reading turning stale), so countdown and stale transitions need no polling. A safety-net re-read every 60 seconds (configurable from 30 s to 1 h) covers a missed file event. No server is contacted, so there is no rate limit to hit; the `RetryPolicy` with `Retry-After` support exists for the source adapters and is where a network provider would plug in if Anthropic ever documents one.

## Installing the helper

The app does it from Settings → Quota (or the Quota page) after an explicit confirmation. It edits `~/.claude/settings.json` **surgically as text** so the rest of the file (formatting, key order, everything) is byte-for-byte preserved:

* It makes a timestamped backup next to the file first.
* If you have no `statusLine`, it inserts one. If you have one, the helper is placed in front of it as `"<helper>" --chain '<your command>'` and your other `statusLine` options (such as `padding`) are kept.
* The edited document is re-parsed; if it would not be valid JSON, nothing is written.
* Invalid existing JSON, or a non-command status line, is never modified.
* Removing the helper restores your original command.

**Rehearsal that changes nothing:** `tw statusline-check` reads your settings, installs the helper into a **copy**, shows the command that would be written, confirms the rest of the file is byte for byte the same and that uninstalling restores it exactly, then runs that command with a made-up payload and prints what the app would parse. It touches neither your settings nor your account.

The command written into `settings.json` points at the helper inside the app bundle. If the app is moved or deleted while the helper is installed, the status line command fails, so uninstall the helper (Settings → Quota) before removing the app.

Manual setup, if you prefer: add this to `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "/Applications/Tokenwatch.app/Contents/MacOS/tw-statusline" }
```

Settings in a project's `.claude/settings.json` or `settings.local.json` override the user file. A project that defines its own status line needs the same helper there.

## Known limitations

* **Terminal sessions only.** The status line renders in the Claude Code CLI. The VS Code extension and Claude Desktop's Code tab do not run it, so quota is reported only while a terminal Claude Code session is in use. Between such sessions the figure is marked stale. Token usage from VS Code and Desktop is still fully collected.
* **Subscribers only.** API-key users have no `rate_limits`, so quota is permanently "Unavailable" for them. That is the truthful answer.
* **No history before installation.** Nothing reports past utilization, so quota history begins when the helper is installed.
* **One account assumed.** Claude Code's status line input names no account, so every Claude reading belongs to one pool. After `/login` to another account the new account's readings arrive with different reset times and form their own cycles (reset times more than 30 seconds apart never merge), but the two accounts cannot be told apart.
* **Per-session quota attribution is impossible.** The session pages show three separate quantities and never merge them: (1) the session's actual tokens, (2) its share of locally observed activity in each quota window, and (3) the account-level percentage Claude reported, with its peak in that window. Quota consumed on surfaces the app cannot observe is never attributed to local sessions.

## The undocumented Desktop cache

Claude Desktop keeps `~/Library/Application Support/Claude/plan-usage-history.json`, with samples such as `{"t": 1791517962035, "u": {"fh": 4, "sd": 0}}`. The names suggest five-hour and seven-day percentages, but the file is undocumented, carries no reset times, is sparse (six samples here over ten days) and its meaning is unconfirmed. It is therefore opt-in (Settings → Quota, off by default), labelled "unverified", never shown in the menu bar, never used for alerts, and never stored as quota history.

## Freshness guarantees

A quota reading is only ever as fresh as the moment it was **taken**. Reading it again never makes it fresher. The times involved are kept apart:

| Time | Meaning | Where it lives |
|---|---|---|
| Event time | When the provider's software wrote the reading (Codex: the timestamp of the `token_count` line. Claude: the moment the helper saw the session make an API call) | `quota_snapshot.observed_at` (first) and `last_confirmed_at` (latest confirmation of the same value) |
| Source-reported time | A timestamp inside the reading itself | Neither source provides one. The documentation lists none for Claude, and Codex's `rate_limits` has none |
| Reset time | When the window resets | `resets_at`, and it identifies the cycle |
| Ingestion time | When this app read the file | **Not stored for quota at all.** Nothing in the freshness path can use it |

Consequences, each covered by a test (`QuotaFreshnessTests`):

* An old file read again (restart, touched, copied, archived, database rebuilt) gives the same readings with the same times, and the same stale state.
* An archived snapshot newer than an active one wins, whichever file was read first. Out-of-order delivery cannot replace a newer reading.
* A reading dated more than five minutes in the future (a clock that was wrong when it was written) is not recorded. A reading that is dated later than the current time (the clock was moved back) is shown as stale instead of new.
* A cycle changes only when the reset time moves by more than 30 seconds. A new cycle does not inherit the previous one's higher value, and a window whose reset time has passed is **unknown, never zero**, until the provider reports it again. A window that has no current value shows a dash in the menu bar in its own place, never the other window's figure.
* Different pools and different accounts are different rows and are never merged. Readings of one account from two sessions that run at once are combined by the in-cycle rule above.

**Claude's status line helper** applies the same rule where it needs a judgement:

* A re-render with no API call keeps the old observation time (as before).
* The first time the helper sees a session (installed while a session was already running, so the numbers can be hours old) it dates the reading with the **modification time of that session's transcript** when that is earlier than now. It looks at the file's modification time only and never opens it.
* When a window reaches its reset time, Claude Code runs the status line again with that window missing. If the session has made no API call and the remaining windows have the same values, the file is left as it is, so the remaining windows are not dated to the moment of the re-render.

**Unverified:** a conservative policy cannot fix a source that is wrong about when it measured. Codex writes the account's utilization with each response, and no case of a cached reading was found in this Mac's files, but nothing proves Codex never writes one.

## Alerts

Notifications are optional and off by default. They use only authoritative, non-stale readings of an open window.

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
| Pool | An allowance of one account. Products that share an allowance share a pool (Claude Code and Claude chat; Codex and ChatGPT Work). Two accounts never share one, and the explicit *unassigned* account is its own pool. |
| Window | One limit inside a pool, identified by its length (`300m`, `10080m`) or, when it has no fixed length, by a name (`spend_limit`). Claude's `five_hour` and `seven_day` become `300m` and `10080m`, which is what makes a Claude window and a Codex window the same vocabulary. |
| Cycle | The period between two resets. Reports of one cycle disagree on the reset time by seconds, so a report joins the cycle whose reset is within 30 seconds. Two pools whose windows began a minute apart are different cycles. |
| Snapshot | A reported utilization within a cycle. Identical reports extend one snapshot's *last confirmed* time instead of adding rows. |

Sources reach the store in two ways: a **quota feed** (`QuotaFeed`) that the coordinator reads and watches (Claude's status line helper; Claude Desktop's undocumented cache, which is opt-in, unverified and never stored), or an adapter that emits snapshots together with the usage it reads (Codex). The state shown to the user is always evaluated from the stored snapshots:

* the reading that was confirmed most recently wins, so out-of-order delivery cannot replace a newer one;
* a reading whose window is still open beats one whose window has closed;
* freshness is measured from the last confirmation (fresh 10 minutes, ageing 1 hour, then stale);
* after a reset the window is *elapsed* and shown as unknown, never as zero;
* a pool the registry knows but that has never reported is listed with its standard windows unavailable, to explain the gap. A pool that is explicitly not observable (ChatGPT Chat) never gets a figure.

Alerts are identified by **account, pool, window and cycle**, and use the same windows: a threshold is announced once per cycle, and a reset is announced once. Thresholds are configured for windows of a day or less and for longer ones.

The menu bar offers *highest utilization*, which compares the displayable windows of all pools and shows the largest. Percentages of different pools are never added.
