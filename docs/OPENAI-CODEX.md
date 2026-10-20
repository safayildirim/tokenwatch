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

1. **Newer files** write a `token_usage_record` per response with a `response_id`. That id is the request key, so reading the same response twice, or from two copies of a session, counts it once. When a file has such records, they are the requests, and the `token_count` events supply only the quota snapshot.
2. **Older files** have only `token_count` events. Such an event is identified by its position in its session (`<session>:<ordinal>`). The cumulative totals inside the event are **not** the identity. They only decide whether an event reports a new response or repeats the previous snapshot (the same totals written again), which Codex does.
3. **A response without an event of its own.** The totals can have grown by more than the event's per-response figures. The excess is real usage, so it is stored as a request of its own with `completeness = reconciledFromTotals` and counted in the coverage figures. An event that reports only a grand total is reconstructed from the change in the totals the same way, without being counted twice.
4. **Forks.** A forked session copies its parent's events into itself at the instant of the fork, stamped with that instant. Events within 1.5 s of a fork's creation are the parent's history and are not counted again, and their copied quota snapshots are ignored, since they would pass an old figure off as a current one.
5. **Compaction.** The number of compactions is stored on the session. Compaction does not change how responses are counted, but it can change what the following totals mean, so sessions that have one are flagged.

## Token normalization

OpenAI reports `input_tokens` **including** the cached part and `output_tokens` **including** reasoning. The adapter converts to the canonical categories: `uncached = input − cached − cache_write`, `cache_read = cached`, `output` as reported, `reasoning` as a subset of output. Verified on every response in the data: `total = input + output`, `cached ≤ input`, `reasoning ≤ output`. Cache writes are zero in all the data seen, and the conversion assumes they are part of input, which `normalization` records (`openai.responses.v1`).

## Quota

Each `token_count` carries `rate_limits`: `limit_id`, `plan_type`, and up to two windows with `used_percent`, `window_minutes` and `resets_at`.

* The pool is per account: `limit_id` `codex` is the shared **Codex and Work** pool, and any other `limit_id` is a pool of its own (`openai-limit:<id>`). A limit with no windows adds nothing.
* A window is keyed by its length (`300m`, `10080m`), never by "primary" or "secondary".
* A report joins the cycle whose reset time is within five minutes of its own (reports of one cycle disagree by seconds). Identical reports extend the snapshot's confirmation time instead of adding rows.
* Freshness is measured from the most recent confirmation. Out-of-order delivery never replaces a newer snapshot with an older one, because the state is evaluated from the stored snapshots by observation time, not by arrival.
* After a reset the window is shown as unknown, not zero.
* **Two accounts have two pools, and their percentages are never added or merged.** The menu bar's "highest utilization" is a comparison, not a sum.
* ChatGPT Chat has a pool in the registry that is marked not observable. It never receives a figure.

## Validation on this Mac's real data

`ccu verify --provider openai` recounts every session with a different parser (Foundation JSON instead of the streaming scanner) and a different rule (growth of the running totals instead of per-response figures):

| | Recount | Database |
|---|---|---|
| Input including cached | 494,170,138 | 494,170,138 |
| Cached input | 473,721,088 | 473,721,088 |
| Output | 1,846,647 | 1,846,647 |
| Reasoning | 707,205 | 707,205 |
| Sessions | 232 (82 by usage record, 149 by event, 1 fork) | 232 |

Responses: 4,450 recounted, 4,451 stored. The extra one is the response that had no event of its own, stored as its own request.

Codex's own per-thread count (`state_5.sqlite`, read from a copy) is compared as a second opinion, and is evidence only: 225 of 232 threads are equal. Six threads are higher in the database, by 780,795 tokens in total, and each is a thread with responses that have a usage record but no `token_count` event, which Codex's own total misses (three of them show zero in Codex's database). One is lower: the fork, whose count in Codex includes the history it inherited.

The same command against the Claude history stays consistent too (86,614 requests, 170 sessions).

## Limits

* **ChatGPT chat is not observable** and neither are its limits.
* Codex does not keep a live process registry, so the status of its sessions is always inferred and labelled as such.
* The snapshot format is an alpha format (`0.162.0-alpha`). The parser ignores unknown record types and fields, and tolerates absent ones. Fixtures for each shape are in `Tests/UsageCoreTests`.
* A response that appears in a `token_count` event but is missing from a file that has usage records elsewhere would not be counted, because events do not count requests in such files. No such case exists in the data, and the independent recount would reveal one.
* Prices: none are shipped for OpenAI (see [ARCHITECTURE](ARCHITECTURE.md)).
