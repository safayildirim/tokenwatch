# Subscription capacity: observed quota, normalized work, and the limits of comparison

> Capacity compares *plans*. For how your own usage and the quota the provider reports move together over subscription cycles, and for forecasts, see [INTELLIGENCE.md](INTELLIGENCE.md). Capacity's work lookup uses the quota account's own sessions only; usage intelligence also handles sessions that name no account.

This document describes the capacity analysis in detail. It is deliberately narrower than a
subscription-value calculator: it compares how many **provider-reported quota percentage points**
different plans consumed for the **same normalized local work**, and it refuses to answer when the
evidence does not support a ratio.

> **The rule.** A quota percentage is never derived from tokens. A capacity ratio is never derived
> from advertised multipliers alone. Observed usage, estimated capacity and unknown/insufficient
> evidence are three different things, and the interface labels them separately.

## 1. What is observed, what is estimated, and what is unknown

| Quantity | Source | Status |
|---|---|---|
| Quota utilization percentage | The provider's local cache or session telemetry | **Observed** |
| Reset time / cycle identity | The provider's telemetry | **Observed** |
| Local requests and token categories | Claude Code or Codex session files on this Mac | **Observed**, limited to this Mac |
| API-equivalent list cost of local work | Built-in or user price cards | **Estimated** normalization proxy |
| Relative capacity of one plan against another | Quota intervals plus normalized work | **Estimated**, with an explicit evidence level |
| Absolute token allowance, weekly multiplier, or provider policy | Not reported | **Unknown** |

The capacity estimate is a **relative marginal** estimate under the workload that was actually
observed. It is not the provider's internal allowance, not a token limit, and not a prediction of
what a different workload would consume.

## 2. Stored data

Capacity analysis adds three tables to the existing provider/account/pool/window/cycle/snapshot
model. It does not replace or rewrite raw observations.

### `plan_assignment`

A half-open period `[effective_from, effective_to)` during which one provider account was on one
plan. `effective_to = NULL` means the period is still open. `plan_key = NULL` means **unknown**;
that is a valid state and it never produces a comparison.

* Periods for one account may not overlap. Adjacent periods are allowed: one may end exactly when
  the next begins.
* `provenance` is `manual` or `providerReported`. A provider-reported plan is evidence; a manual one
  is metadata. Neither is a capacity measurement.
* `account_label` is a person's own label. It is **not** a provider account identifier and is never
  used to infer identity from reset times, session ids, or temporal proximity.
* The store rejects overlaps transactionally. The timeline also re-checks stored rows and marks an
  ambiguous history if an external edit created one.

### `plan_price`

Dated monthly reference prices. A user price from a date onward takes precedence over the registry
reference price for that plan. Prices are only used to compare purchasing strategies; they are never
used to infer capacity.

### `capacity_measurement`

An explicitly labelled period in which a person did ordinary work. It stores which plan assignment
was in force when it began, and its state (`open`, `closed`, `abandoned`). It contains no requests;
it is a review annotation over existing quota readings and local work.

Only one measurement may be open for an account, pool and window at a time. Measurements survive a
transcript rebuild because they are annotations, not transcript-derived data. Deleting a plan
assignment sets the measurement's foreign key to `NULL` but keeps its captured `plan_key`, so its
historical interpretation does not silently change.

## 3. Account identity

Claude Code's local cache names the signed-in account, and the application stores its readings in
that account, identified by a one-way hash. A reading from a source that names no account is stored
in the explicit **unassigned** account of its provider. The application never moves a reading between
accounts by reset time, session id, percentage, or which session happened to be nearby.

For a pool, the report distinguishes:

| Basis | Meaning | Capacity comparison |
|---|---|---|
| Provider-identified | The provider telemetry carries an account identifier (hashed) | Allowed within that account |
| Unassigned account | No provider identity; no manual label | Allowed within the one unassigned account, with a visible caveat |
| Manual label | At least one period carries a label, and no two labels conflict | Allowed, with the caveat that the label is not proof and unlabelled periods still belong to the unassigned account |
| Conflicting manual labels | Different labels on the same unassigned provider account | **Not supported**: the app cannot tell whether they are the same subscription |
| Overlapping plan periods | The timeline is ambiguous | **Not supported** until corrected |

The comparison is always within one stored account row. Provider-identified accounts are never
combined, even when their reset times look similar. Model-scoped weekly limits are kept separate in
the quota views but are not used for plan-wide capacity ratios: their allowance is only a share of
the weekly limit, so a plan's all-model multiplier does not apply to them. For Claude, the cache's readings are
provider-identified and are compared within that account. Readings from a source that names no account share the unassigned account, so
readings from more than one physical subscription can land there. The app
keeps cycles with different reset times apart, but that is not proof of identity. A plan period applies
to the account it was recorded for, so a plan recorded on the unassigned account does not cover an
identified account, and the other way round.

## 4. Building quota intervals

For one provider, account, pool and window, the analyzer reads only **authoritative** snapshots in
the requested range. It groups them by the stored quota cycle.

Between consecutive snapshots in one cycle, it forms an interval:

```
from       = the observation time of the earlier snapshot
to         = the observation time of the later snapshot
fromPercent= the earlier reported percentage
toPercent  = the later reported percentage
delta      = toPercent - fromPercent
```

The earlier observation time is used because it is the moment the value was first seen. A later
re-confirmation of the same value does not move the interval start; otherwise a repeated reading
could reorder or erase a real later increase.

Each interval is checked, and every rejection carries a reason:

| Exclusion | Rule |
|---|---|
| No plan | No plan assignment covers the interval |
| Plan changed | Different assignment ids at the two ends |
| Multiple plans in one cycle | A cycle produced eligible intervals for more than one plan; it is not counted as two independent cycles |
| Overlapping cycles | Two cycles' intervals overlap in time, so local work cannot be attributed cleanly |
| Ambiguous history | The timeline overlaps, or the account identity is unsupported |
| No reset identity | The cycle has no reset time |
| Quota decreased | A reading lower than the running maximum in the same cycle (skipped, never treated as a reset) |
| Zero change | No increase |
| Small change | `delta < max(2 points, 3 × observed resolution)` |
| Gap too long | More than 1 h for a window ≤ 6 h, 3 h for ≤ 24 h, 24 h for weekly |
| No local usage | No request from this account falls inside `[from, to)` |
| Unpriced workload | Less than 95 % of processed tokens have a price, or cost is zero |
| Incomplete coverage | A required token category was not reported, or the record is partial |

The observed resolution is the smallest positive step between consecutive percentages in the
window, capped at one point. It is an upper bound used to avoid treating display rounding as signal.

Multiple eligible intervals for the same plan in one cycle are **summed into one cycle sample**. Twenty readings in one
afternoon are one experiment, not twenty. This is what prevents pseudoreplication.

The five-hour (`300m`) and weekly (`10080m`) windows are analyzed separately. A reading is never
moved from one window to another, and a cycle is never merged across a reset.

## 5. Normalized local work

The local side of an interval is described by:

* request count;
* all token categories, never collapsed;
* API-equivalent list cost, in exact pico-USD;
* cost by canonical model;
* cache-read and output shares;
* the number of active five-minute buckets;
* coverage flags and the first/last request times.

API-equivalent cost is a **common yardstick** for model mix, cache use and token volume. It is not
how a subscription is necessarily metered. The provider percentage is the only quota quantity; the
cost only answers "how much work was this percentage spent on?"

If part of the work has no price, the interval is excluded rather than normalized by a guess. If the
record is partial or a required category is missing, it is excluded.

## 6. Estimator

For each plan and cycle sample:

```
rate = quota percentage points / API-equivalent USD of local work
capacity(other) / capacity(base) = rate(base) / rate(other)
```

With identical work, this reduces to `delta(base) / delta(other)`. If the base plan consumes 20 % and
the other plan consumes 10 % for the same work, the other plan has **2.0×** the base capacity. A
larger percentage always means **less** capacity, so the direction is never inverted.

### Matched cycles

The estimator first pairs one base cycle with one other cycle. A pair is allowed only when the
workloads are comparable:

* model-cost cosine similarity ≥ 0.85;
* cache-read shares differ by ≤ 0.15;
* output shares differ by ≤ 0.10;
* both cycles have a positive consumption rate.

Pairs are chosen greedily by smallest composition distance, one-to-one. The published ratio is the
**median** of the pair ratios. This prevents one unusual cycle from dominating.

### Pooled fallback

If there are too few one-to-one pairs, the estimator may use pooled standardized work:

```
pooled ratio = (sum of base percentage points / sum of base work)
             / (sum of other percentage points / sum of other work)
```

This is allowed only when the whole-period compositions are similar: model cosine ≥ 0.90 and the
same cache/output share limits. A pooled ratio is labelled with its method, never presented as a
matched-cycle result.

### Outliers

When a plan has at least five cycles, its own median consumption rate defines an outlier band of
4× in either direction. Cycles outside it are removed, but only if at least two cycles remain. The
removed cycle ids are recorded in the estimate and in the capacity export; the raw history is never
changed.

### Minimum work

A cycle with less than $0.01 of API-equivalent work is not evidence. The check is applied to the
**whole cycle sample**, not to each interval, so a cycle made of several small but real intervals is
not discarded.

### Evidence policy

| Level | Minimum independent evidence | Meaning |
|---|---|---|
| Insufficient | Fewer than 2 cycles per plan, or fewer than 2 matched pairs and no comparable pooled fallback | No ratio is published |
| Limited | 2 cycles per plan and 2 matched pairs (or an allowed pooled fallback) | Minimal published evidence |
| Moderate | 4 cycles per plan and 4 matched pairs | Useful, still workload-specific |
| Strong | 8 cycles per plan, 8 matched pairs, at least 14 days, and the pooled method within 25 % of the matched ratio | Strongest label this app gives |

The **sensitivity range** is the minimum and maximum of the matched-pair ratios and the pooled ratio
when available. It is a sensitivity check, **not a confidence interval**, and the UI says so. No
confidence score, p-value, or fake interval is invented.

A single pair may be shown as **provisional** when both plans have at least one cycle, but it is
never published as a ratio and never drives a purchase recommendation.

## 7. Advertised multipliers and purchasing strategies

The registry contains subscription plan definitions. For Claude, the registry records reference
prices read on 2026-10-22 and the advertised **five-hour** multipliers:

| Plan | Reference monthly price | Advertised five-hour multiplier |
|---|---|---|
| Claude Pro | $20 | 1× |
| Claude Max 5x | $100 | 5× |
| Claude Max 20x | $200 | 20× |

The weekly multipliers are deliberately absent. The provider does not state them, and the analysis
does not invent them. A five-hour multiplier is never used as if it were a weekly one.

A **strategy** is a number of independent subscriptions of one plan:

```
strategy capacity = measured relative capacity of the plan × count
```

Two subscriptions mean two independent quota pools. Their allowances are aggregated for a cost
comparison, but they are never merged into one larger pool.

For two strategies A and B, B is at least as good per dollar when:

```
measured capacity(B) / measured capacity(A) >= monthly cost(B) / monthly cost(A)
```

The right side is the **required ratio**. For the default Max 5x/Max 20x prices, comparing two Max
5x subscriptions at $200 with one Max 20x at $200 requires a measured capacity ratio of 1.0 after the
counts are included. Equivalently, the single 20x must deliver at least 2.0× a single 5x.

* If the measured 20x/5x ratio is about 4.0, one 20x wins at equal cost.
* If it is about 1.5, two 5x subscriptions win.
* If it is about 2.0, the strategies are at break-even within the measurement.

The UI shows advertised reference values and measured values. Advertised values are normalized
to the same baseline as the measured values, so the two columns are comparable. An advertised line
is drawn only where the provider publishes a multiplier for the selected window; the price-based
equal-cost line can appear on its own (for example on the weekly window). Prices can be edited in the
capacity page; a user price replaces the registry reference from its effective date. When measured
capacity is missing, it makes no recommendation instead of substituting the advertised multiplier.

## 8. Controlled measurements

A labelled measurement is optional. It records a start and end, the plan in force, and a label. The
review then:

1. finds the latest authoritative reading at or before the start, within 15 minutes;
2. finds the earliest authoritative reading at or after the end, within 15 minutes;
3. requires both readings to belong to the same cycle;
4. requires the same plan assignment (and the captured plan key) at both ends;
5. measures local work from the **baseline reading time to the ending reading time**, not from the
   labelled wall-clock times.

Using the reading-to-reading span pairs the observed percentage change and the observed work over the
same interval. The labelled times only choose which readings bracket the measurement. A measurement
that crosses a reset, changes plan, loses a reading, has no local work, has too little work, or has
unpriced/incomplete work is shown with its exclusion and is not used. An open measurement is shown
as still open; it is reviewed after it ends.

## 9. Determinism, time and storage

* All timestamps are UTC milliseconds. Periods are half-open, and the UI edits them in the user's
  local calendar but stores absolute instants.
* The snapshot and local-work queries are bounded by the requested range. The analyzer fetches
  snapshots once and local requests once per window, then distributes requests to intervals in a
  streaming pass. Plan history and prices are small configuration tables. Nothing runs per file event.
* Quota snapshots and manual capacity annotations are **not** derived from transcripts.
  "Rebuild from source" preserves them. "Delete all collected data" removes measurements and plan
  assignments (prices remain configuration).
* Capacity evidence is exportable as CSV or JSON with one row per overlapping plan period, quota
  cycle, interval, estimate and measurement. The export metadata defines every column's unit and
  definition, and each row carries its method, evidence level and exclusions where they apply.

## 10. What the analysis does not claim

* It does not know the provider's absolute token capacity or its weekly multiplier.
* It does not attribute quota consumed on other devices, claude.ai, Cowork, or unobserved surfaces.
* It does not infer account identity from reset times, session ids, or timing.
* It does not treat a lower reading in one cycle as a reset, or a new cycle as zero.
* It does not compare across overlapping or ambiguous plan periods.
* It does not call API-equivalent cost the subscription price, or the reference price the amount
  charged.
* It does not turn a single busy afternoon into several independent observations.
* It does not publish a ratio merely because two plans have advertised multipliers.
* It does not verify that two subscriptions of one plan behave identically. The two-subscription
  strategy scales the measured single-subscription capacity by its count and is labelled as an
  assumption, not a second measurement.
* It cannot separate two concurrently active subscriptions in readings from a source that names no
  account. Those readings share the unassigned account; differing reset times keep cycles apart but
  do not prove which subscription produced a reading. Claude cache readings are separated by the
  account the cache names.
