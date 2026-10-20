# Token accounting rules

## Token categories

Each model request stores the raw categories. They are never collapsed into one total.

| Category | Meaning | Source field (Claude Code) |
|---|---|---|
| Uncached input | Input that was neither read from nor written to the prompt cache | `usage.input_tokens` |
| Output | Tokens the model generated | `usage.output_tokens` |
| Cache read | Input served from the prompt cache | `usage.cache_read_input_tokens` |
| Cache creation | Input written to the prompt cache | `usage.cache_creation_input_tokens` |
| Cache creation, 5-minute | Portion written with a five-minute lifetime | `usage.cache_creation.ephemeral_5m_input_tokens` |
| Cache creation, 1-hour | Portion written with a one-hour lifetime | `usage.cache_creation.ephemeral_1h_input_tokens` |

The 5-minute and 1-hour values are stored as null when a source does not state them. They are never guessed.

## Derived metrics (exact definitions)

For the Anthropic usage format, `input_tokens` **excludes** cache activity, so:

```
logicalInput      = uncachedInput + cacheRead + cacheCreation
totalProcessed    = logicalInput + output
freshTokens       = uncachedInput + cacheCreation + output      (everything except cache reads)
cacheHitRatio     = cacheRead / logicalInput
outputToInputRatio= output / logicalInput
```

`freshTokens` exists because in long agentic sessions more than 97 % of processed tokens are cache reads. "Processed" answers "how much did the model read and write", while "new" answers "how much new work was sent". Both are always labelled, and the dashboard never shows an unlabelled "tokens" figure.

Semantics are normalized **per source**. If another source reported input that already included cache tokens, its adapter would convert it to the categories above before storing; the formulas are never applied blindly to foreign semantics.

## One request, many log lines

Claude Code writes a response as several JSONL lines, one per content block, repeating the `usage` object on each. The measured data shows:

* Across 199,480 assistant lines there are only 85,843 distinct message ids. **Adding every line overstates output 2.85× and cache reads 2.44×** (65.9 B vs 27.0 B cache-read tokens on this machine).
* While a response streams, only `output_tokens` grows; the other fields repeat.
* After a context compaction or a resume, the same message can be written again with all usage zeroed.
* A forked sub-agent writes its parent's earlier messages into its own file, so the same message id appears in more than one file.

### Identity

A request is identified by `(product, request_key)`, with the rule below for products of one provider. For Claude Code, `request_key` is the API **message id** (`msg_…`). The server `request_id` (`req_…`) is stored beside it and indexed, which is the key for correlating the same request from a second source such as OpenTelemetry.

### Finalizing a request: the merge rule

Observations of the same request are merged **per field**:

| Field | Rule |
|---|---|
| each token category | maximum |
| cache 5 m / 1 h split | maximum of the values present; null only if no observation has it |
| request time | minimum (the earliest record) |
| agent attribution | main conversation wins; otherwise the lexicographically smallest agent id |
| model | any real model beats `<synthetic>`; otherwise smallest |
| other labels (stop reason, speed, request id) | a present value beats absent; otherwise the greater |

This operation is **commutative, associative and idempotent**. Therefore the result does not depend on delivery order, on how many times an observation is delivered, or on which file it came from, which is exactly-once aggregation without needing exactly-once delivery. The same rules are implemented twice, in Swift (`RequestObservation.merged`) and in SQL (`ON CONFLICT … DO UPDATE` in `IngestWriter`), and a randomized test asserts that they agree for arbitrary orderings with duplicates.

Taking the maximum per field also handles reordered and delayed observations: an early partial snapshot and a late final one merge to the final values whichever arrives first.

An observation whose four token fields are all zero is discarded. It is a replay or a placeholder, and storing it could create a phantom request. `<synthetic>` model messages (client-generated) are ignored.

### What an identity is, and what it is not

An identity has to be exactly as wide as the guarantee the telemetry gives, so each dimension was checked against the data:

| Dimension | In the identity? | Why |
|---|---|---|
| Session | No | A fork or a sub-agent file repeats its parent's requests, and the same request must stay one request. The session is where the request is attributed, and for a copied Codex record that is the thread that made it (`thread_id`), whichever file is read first. |
| Account | No | An API message or response id is unique across accounts. |
| Product | Yes, widened to the provider for responses | Claude message ids and OpenAI response ids are issued by the provider. A response copied into a session of another product of the same provider (a fork opened in another app) merges into the stored row. Request keys that are made from a position (`<session>:<ordinal>`) contain the session id and cannot collide. |
| File or copy | No | The same response read from an active, archived or compressed copy of a session is one request. |
| Cumulative totals | **Never** | Two unrelated Codex runs report identical running totals for their first response. Totals decide only whether an event repeats the previous snapshot, and they are compared with a fork's own parent to recognize copied history (see [OPENAI-CODEX](OPENAI-CODEX.md)). |
| Resumption | No | A resumed session continues in its file and its keys do not change. |

### Sub-agents

Sub-agent transcripts live in `<session>/subagents/agent-<id>.jsonl` and carry the **parent's** `sessionId`. Their requests belong to the parent session, with `agent_key` recording which agent made them. Because deduplication is global (by message id), a request replayed into a fork file is counted once, and attributed to the main conversation.

Session totals include all child agents. The session page also shows the main conversation and each agent separately, and "child agents combined".

## Time semantics

* All timestamps are stored as UTC milliseconds. "Today", "this week", hourly and monthly buckets are computed **at query time** using the user's current calendar and time zone. The underlying resolution is 15 minutes, which divides every real UTC offset (including +5:30 and +5:45), so regrouping is exact. DST days (23 or 25 hours) are handled by the calendar.
* A request is placed at the time of its **first** record. A request is a point event: it belongs wholly to one day or quota window. Sessions that cross midnight are split naturally across their requests.
* Period boundaries are half-open: `[from, to)`.

## Cost estimates

Costs are API-equivalent estimates at published list prices, kept strictly apart from anything charged. They are **not** what a Claude or ChatGPT subscription costs, and the cost page says so at the top:

* Prices are integers in micro-USD per million tokens, so `tokens × rate` is an exact whole number of pico-USD. Sums over millions of requests carry no floating point error. Exports write the exact decimal.
* Rate cards are **dated and append-only**. A new price is a new row effective from a later instant; older requests keep their older price, so an estimate for past usage is the same whenever it is computed.
* Rate cards carry a **prompt-size tier** (Haiku 5.5 has one card up to 100,000 prompt tokens and another above; OpenAI bills the whole request at the long-context price above 272,000 input tokens) and a **speed or tier** (Claude's fast mode, OpenAI's `fast` and `flex`). A tier with no card leaves the request unpriced instead of being priced as standard.
* Cache writes are priced at the 5-minute or 1-hour rate according to the stored split; writes of unstated lifetime are priced at the 5-minute rate (a lower bound).
* A model with no rate card is **unpriced**: its tokens are excluded and counted in `unpricedTokens`, and the figure is shown as a lower bound ("$12.34+"). No generic fallback price is used, and a model is never priced as a similarly named one.
* Every card is **published**, **derived** or **yours**, and the cost page says how many of the priced tokens used each. A derived price is the price before a cut that the provider announced as a percentage, worked out from the published price after it.
* If a source reports its own cost (Claude Code's per-session `cost-state`), it is stored in separate columns and displayed next to, never merged with, the estimate.

Validated against Claude Code's own recorded session costs on this machine (164 sessions): median per-session deviation 0.4 %, total within 7.4 %. Differences come from mid-session snapshots in Claude Code's record and from price assumptions made by Claude Code itself.

### OpenAI prices

Read on 2026-10-20 from OpenAI's pricing page and changelog (developers.openai.com/api/docs/pricing and /changelog). Prices are US$ per million tokens for prompts up to 272,000 tokens; reasoning tokens are part of output and are priced once.

| Model | Card from | Input | Cached | Output | Basis |
|---|---|---|---|---|---|
| `gpt-5.5` | 2026-04-24 | 5.00 | 0.50 | 30.00 | published |
| `gpt-5.6-sol` | 2026-08-21 | 4.00 | 0.40 | 20.00 | published (promotional, announced through 2026-11-21) |
| `gpt-5.6-sol` | 2026-07-09 | 5.00 | 0.50 | 30.00 | **derived** from the 2026-08-21 cut |
| `gpt-5.6-terra` | 2026-07-30 | 2.00 | 0.20 | 12.00 | published |
| `gpt-5.6-terra` | 2026-07-09 | 2.50 | 0.25 | 15.00 | **derived** (20 % cut on 2026-07-30) |
| `gpt-5.6-luna` | 2026-07-30 | 0.20 | 0.02 | 1.20 | published |
| `gpt-5.6-luna` | 2026-07-09 | 1.00 | 0.10 | 6.00 | **derived** (80 % cut on 2026-07-30) |
| `gpt-6-astra` | 2026-09-03 | 10.00 | 1.00 | 50.00 | published |
| `gpt-6-sol` | 2026-09-22 | 2.00 | 0.20 | 10.00 | published |
| `gpt-6-luna` | 2026-09-22 | 0.10 | 0.01 | 0.50 | published |
| `gpt-6.1-sol` | 2026-09-29 | 2.00 | 0.10 | 10.00 | published, cache write 2.50 |

Long-context prices (above 272,000 prompt tokens), the `fast` tier and the `flex` tier are in `Sources/UsageCore/Pricing/OpenAIPricing.swift`. The derived cards have no long-context tier. The changelog gives days, not hours, so a request within a day of a change can be priced by the neighbouring card. **Not priced:** `codex-auto-review` (not a published model; 291 requests, 6.55 M tokens on this Mac), a model name with a dated suffix such as `gpt-5.5-2026-04-24` (OpenAI prices some snapshots differently from their alias, so the exact name is the key), and any name not in the table. Coverage on this Mac's history: 6 of 7 observed model names priced, 98.7 % of OpenAI tokens, about US$186 API-equivalent in total.

## Canonical measurement and per-provider normalization

Providers report usage differently, so each adapter converts what its source says into one canonical measurement before anything is stored. After that, no other code needs to know where a number came from.

| Canonical field | Meaning |
|---|---|
| `uncached_input` | Input that was neither read from nor written to a prompt cache |
| `cache_read` | Input served from a prompt cache |
| `cache_creation` (with a 5-minute / 1-hour split where stated) | Input written to a prompt cache |
| `output` | All generated tokens |
| `reasoning_output` | The part of `output` spent on reasoning. **Already included in `output`**, stored as a subset and never added to it. |
| `extras` | Provider-specific counters with no canonical column |
| `normalization`, `completeness` | The conversion rule used, and whether the figures were taken from a per-request report, derived from totals, or known to be partial |

A category that a source does not report is **null, meaning unknown**, not zero. Aggregates sum unknown as zero and also report how many requests lacked each category, so the interface shows a dash for a ratio it cannot compute instead of a misleading figure.

| Provider | Conversion |
|---|---|
| Anthropic | `input_tokens` already excludes cached tokens, so it is `uncached_input`. Cache read and creation are reported separately. Thinking tokens are not broken out in Claude Code's log, so `reasoning_output` is unknown. |
| OpenAI | `input_tokens` **includes** cached tokens, so `uncached_input = input − cached − cache_write`. `output_tokens` includes reasoning, which is stored as the subset. Verified on every response: `total = input + output`. |
| Any other | An adapter supplies its own conversion (a test provider reports thinking tokens beside the answer and adds them to `output` exactly once). |

`logical_input = uncached + cache_read + cache_creation` and `total_processed = logical_input + output` therefore mean the same for every provider. Tokenizers differ between providers, so totals compared across providers show volume, not equal effort or equal cost, and the dashboard shows providers side by side instead of adding them.

Merging two observations of one request takes, per category, the larger value that is present, and an unknown category stays unknown unless another observation knows it. The SQL upsert implements exactly the same rule, and a randomized test asserts the two agree. See [OPENAI-CODEX](OPENAI-CODEX.md) for how Codex requests are identified.
