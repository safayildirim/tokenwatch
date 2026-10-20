# OpenAI: Codex, Codex Desktop and ChatGPT Work

One adapter (`CodexAdapter`) reads the session files of the Codex engine. The engine serves the Codex command line, `codex exec`, the Codex desktop app, the VS Code and JetBrains integrations, and the Work mode of the ChatGPT desktop app.

## What is read, and what never is

* Read: the session header, `turn_context` and `thread_settings_applied` (for the model and service tier), `token_usage_record`, `token_count` events (usage and `rate_limits`) and `compacted` markers.
* Skipped without being decoded: messages, reasoning, tool calls and tool output. A test plants sentinel text in them and asserts it never reaches the database.
* Never opened: `auth.json` and every other file in the folder. The account identifier from the header is hashed before it is stored (`creator_account_id` → a 16-hex-digit digest), and a test asserts the raw value, the user id and the instructions never reach the database.
* `$CODEX_HOME` is honoured, as Codex itself does. `CLAUDE_USAGE_MONITOR_CODEX_DIR` overrides it for tests. A GUI app does not inherit a shell's environment, so a non-default location is best set through that variable or `ccu --codex-home`.

## File layout

| Location | Meaning |
|---|---|
| `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl` | An active session. Appended to while it runs. |
| `…jsonl.zst` | The same after Codex compressed it. Immutable. Decoded with a bounded-memory streaming reader (`ZstdFileReader`), including multi-frame files. A truncated or damaged file keeps what was decoded before the damage, is marked `damaged`, and is not decoded again until it changes. |
| `archived_sessions/…` | Sessions the user archived, in either form. |

Because later lines depend on earlier ones (the header names the session, and the running totals tell repeats from new responses), a file that changed is **read again from its start**. Observations are idempotent, so this is safe, and the cost is negligible: the whole history, 862 MB uncompressed, imports in about 1.5 s.

## Which product, surface and account

The header's `originator` is split into words and matched word by word (so `client` is not mistaken for `cli`):

| Originator | Product | Surface |
|---|---|---|
| `codex_work_desktop` | ChatGPT Work | ChatGPT Desktop |
| `Codex Desktop` | Codex | Codex Desktop |
| `codex_exec`, `codex_cli_rs`, `codex-tui` | Codex | Terminal |
| `codex_vscode` | Codex | VS Code |
| `JetBrains.*` | Codex | JetBrains IDE |
| anything else | Codex | taken from the header's `source` (`vscode`, `exec`), otherwise unknown |

The account is `creator_account_id` when present. Older files do not carry one, and those sessions belong to the explicit **unassigned** account. A session is never attributed to an account by guessing.

A session is the **thread** (`id`). `session_id` names the conversation, which for a thread that another thread started is the root's, so using it would merge the threads. Threads started by another (`thread_spawn`, `guardian` reviewers) get a parent link and a root, and are classified as sub-agent or review sessions.

## How a request is identified (and why the totals are not the identity)

1. **Newer files** write a `token_usage_record` per response with a `response_id` and the id of the thread that made it (`thread_id`). The response id is the request key, so reading the same response twice, or from two copies of a session, counts it once. A compaction marker carries the record of the request that summarized the conversation (`latest_token_usage_record`), and that record counts too, under the same key, so it is never counted twice and is not lost when its own line is missing.
2. **A `token_count` event that matches a record is the same response.** A snapshot is explained by a record that reports the same four figures (input, cached, output, reasoning) within 24 lines of it, and each record explains at most one snapshot. The snapshot then supplies only the quota reading. This is decided once the whole file has been read, so it does not matter which of the two was written first.
3. **A `token_count` event that no record explains is a response of its own.** This is how files written by older versions are counted, and also how a response is found in a file that has records elsewhere (a session resumed under a newer version, or a record that is missing). Such an event is identified by its position in its session (`<session>:<ordinal>`), never by its running totals. The totals only decide whether an event reports a new response or repeats the previous snapshot (the same totals written again, which Codex does). In a file that has records, events that no record explains are counted and reported in Diagnostics → Accounting notes.
4. **A response without an event of its own** (only in the older part of a file). The totals can have grown by more than the event's per-response figures. The excess is real usage, so it is stored as a request of its own with `completeness = reconciledFromTotals`. An event that reports only a grand total is reconstructed from the change in the totals the same way. A running total that goes down is a counter reset (after a compaction), nothing is invented across it, and the next response is still counted.
5. **Forks.** A fork copies its parent's file line by line into its own, in the same positions and with the same figures, in one burst, stamped with the instant of the copy. The fork's header names its parent (`forked_from_id`), and the copy is recognized **by what the lines say, not by when they were written**: a `token_count` line whose running totals and per-response figures equal a line of the parent's file, and a usage record whose response id the parent has (or whose `thread_id` names another thread), is inherited and is not counted again. The parent's file is found by its thread id in the name, in any of its forms (active, archived, compressed). Lines of the fork that the parent does not have are the fork's own, however soon after the fork they were written. Copied quota snapshots are ignored, because they would pass an old figure off as a current one. If the parent's file is not on this Mac, the only evidence left is the time. Lines written within 1.5 s of the fork are then left out and the session is flagged in Diagnostics, so the assumption is visible. A line written at that instant that the parent's file does not contain is counted and flagged as well.
6. **Compaction.** The number of compactions is stored on the session. The request that summarizes the conversation is a response like any other, with its own record and no `token_count` event (see below).

Running totals are never an identity. Two unrelated `codex exec` runs on this Mac report identical figures for their first response, with identical running totals, so equal totals prove nothing. Totals are compared only between a fork and its own declared parent.

Across products: a response id is issued by OpenAI, so it is one response whichever of its products (Codex, ChatGPT Work) shows it, and a copy in a session of another product merges into the stored row.

## What the files proved about the seven discrepant threads

The independent recount agreed with the database, but both used the per-response figures, so the question was whether those assumptions were right. They were checked against a third source, **Codex's own running counter** (`thread_token_usage` in every usage record). That counter grew by exactly the usage of each record in all 680 consecutive pairs of records on this Mac, and starts at zero, so it is an exact accumulator, and the sum of a thread's records can be compared with it.

| Thread (last 6 characters) | Shape | What the unmatched record is | Evidence | Counted |
|---|---|---|---|---|
| `8641df`, `107ccc` (two) | Compaction | The request that summarizes the conversation (239,762 / 223,609 / 232,363 input tokens). Its response id equals the `compaction_response_id` of the marker that follows it | The thread counter includes it. `token_count` totals do not, because Codex emits no event for it | Yes, once. The marker repeats the same record and is the same request |
| `b0210c` | Last response of a `codex exec` run | A response at the very end of the file with a record and no event | The thread counter grew by exactly its usage | Yes |
| `f3e5bf`, `576382`, `8c96c7` | One-response `codex exec` runs | A single response with a record and no event | The thread counter equals its usage. Codex's own total for these three is zero | Yes |

The six threads add up to **780,795 tokens** that Codex's `state_5.sqlite` total (built from events) does not include. They are real usage by every test that was possible: each response id occurs once in all the files, none of them appears in another thread, and Codex's own thread counter includes them. The seventh thread, a fork (`8dc016`), is the opposite case. It is a copy of its parent up to line 45: seven events with the same ordinals, totals and per-response figures as the parent's, written within one millisecond of each other at the instant of the copy while the parent's originals are seconds apart. It has no event of its own, and its final running total equals the parent's at line 45. Counting it would count the parent's 120,963 input tokens twice, so the database counts nothing for it.

Also examined: 77 sub-agent threads that Codex uses for automatic reviews carry a `subagent_history_start_ordinal` equal to the length of their file. Their 291 token events share nothing with their parents' (no ordinal or totals in common), so they are the reviewer's own usage (6.5 M tokens) and are counted. The independent recount now measures a session by Codex's own counter instead of by adding up responses, so it no longer shares the importer's assumptions, and it reports any thread whose counter and records disagree. On this Mac all agree.

## Token normalization

OpenAI reports `input_tokens` **including** the cached part and `output_tokens` **including** reasoning. The adapter converts to the canonical categories: `uncached = input − cached − cache_write`, `cache_read = cached`, `output` as reported, `reasoning` as a subset of output. Verified on every response in the data: `total = input + output`, `cached ≤ input`, `reasoning ≤ output`. Cache writes are zero in all the data seen, and the conversion assumes they are part of input, which `normalization` records (`openai.responses.v1`).

## Quota

Each `token_count` carries `rate_limits`: `limit_id`, `plan_type`, and up to two windows with `used_percent`, `window_minutes` and `resets_at`.

* The pool is per account: `limit_id` `codex` is the shared **Codex and Work** pool, and any other `limit_id` is a pool of its own (`openai-limit:<id>`). A limit with no windows adds nothing.
* A window is keyed by its length (`300m`, `10080m`), never by "primary" or "secondary".
* A report joins the cycle whose reset time is within **30 seconds** of its own. Reports of one cycle differ by at most 13 seconds on this Mac's files, while two pools whose windows began a minute apart (53 to 74 seconds) are different cycles. Identical reports extend the snapshot's confirmation time instead of adding rows.
* Freshness is measured from the most recent confirmation, which is the timestamp of the event that carried the reading, never the time it was read. Rereading a file, copying it, archiving it or rebuilding the database does not change it. Within a cycle utilization only grows, so a lower value that arrives later is a response that started earlier, and the highest value of the open cycle is shown (see [QUOTA](QUOTA.md)).
* After a reset the window is shown as unknown, not zero.
* **Two accounts have two pools, and their percentages are never added or merged.** The menu bar's "highest utilization" is a comparison, not a sum.
* ChatGPT Chat has a pool in the registry that is marked not observable. It never receives a figure.

## Validation on this Mac's real data

`ccu verify --provider openai` recounts every session by Codex's own running counters (see above), with a different parser (Foundation JSON instead of the streaming scanner) and a different method (growth of a counter instead of per-response figures):

| | Recount | Database |
|---|---|---|
| Input including cached | 494,170,138 | 494,170,138 |
| Cached input | 473,721,088 | 473,721,088 |
| Output | 1,846,647 | 1,846,647 |
| Reasoning | 707,205 | 707,205 |
| Sessions | 232 (82 by usage record, 149 by event, 1 fork) | 232 |

The thread counter and the sum of the usage records agree for every thread that has records. Codex's own per-thread count (`state_5.sqlite`, read from a copy) is evidence only: 225 of 232 threads are equal, six are higher in the database by 780,795 tokens (the records without events, above) and one is lower (the fork, whose count in Codex includes the history it inherited).

## Pricing

Prices are the published API prices of the models seen in the files, with dates (see [TOKEN-ACCOUNTING](TOKEN-ACCOUNTING.md#openai-prices)). `codex-auto-review` is not a published model and is **unpriced**: 291 requests and 6.55 M tokens (1.3 % of the processed tokens) on this Mac.

## Limits

* **ChatGPT chat is not observable** and neither are its limits.
* Codex does not keep a live process registry, so the status of its sessions is always inferred and labelled as such.
* The snapshot format is an alpha format (`0.162.0-alpha`). The parser ignores unknown record types and fields and tolerates absent ones. A line that should report usage but does not have the expected shape (a renamed field) is counted and reported in Diagnostics instead of silently adding nothing. Fixtures for each shape are in `Tests/UsageCoreTests`.
* A response whose usage appears **only** in a `token_count` event, in a file that has usage records elsewhere, is counted from the event and reported. If Codex ever wrote a record and an event that disagree on their figures, both would be counted and the report would show the extra event. No such case exists in the data.
* **Fork lineage depends on the parent's file.** Without it a fork falls back to the instant of the fork and says so. A fork whose parent had not yet written the copied lines when the fork was made would have those lines counted as its own (they are reported as written at the instant of the fork). The report on the session is not removed when the parent turns up later, until the fork's file is read again.
* **Accounts.** Sessions written before Codex recorded an account id belong to the unassigned account. Readings of two real accounts that share it can alternate there (the history of this Mac contains such a period in July). They are kept apart as separate cycles when their reset times differ by more than 30 seconds, but nothing can tell the accounts apart.
* `$CODEX_HOME` is read when the app starts. A GUI app does not inherit a shell's environment, so a non-default location needs `launchctl setenv CODEX_HOME …` and a restart, or `ccu --codex-home` for the command line.
