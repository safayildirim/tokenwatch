# Usage intelligence: cycles, observed associations and forecasts

Usage intelligence correlates two independent streams that Tokenwatch already stores: the **utilization percentages the provider reported** (quota snapshots) and the **work recorded in local session files** (model requests). It does this inside the provider's own quota cycles, and it adds explainable forecasts. The code is in `Sources/UsageCore/Intelligence/` and has no UI dependency; the page is `Sources/UsageUI/Dashboard/IntelligencePage.swift`.

> **The rules.** A quota percentage is the provider's reading and is never derived from tokens. A cycle that was only calculated from a schedule never carries a percentage. A reset the provider announced is not a reset that happened. A forecast is a prediction from reported history, not a provider limit, and it is shown only when the way of forecasting has proved itself on cycles it had not seen. Account-wide quota and this-Mac tokens are different quantities, and tokens are never tied to an account by guessing.

## 1. What is stored

Everything is computed on demand from existing rows. Three additions to the schema support it (all in the initial migration; see [SCHEMA.md](SCHEMA.md)):

| Need | Where it lives |
|---|---|
| Account, pool, window, scope | `quota_pool.account_id`, `pool_key`, `quota_window.window_key` (a model-scoped window's key carries its scope) |
| The reset the provider **announced** for a cycle | `quota_cycle.resets_at`, joined within 30 s of jitter |
| When a value was first seen and last confirmed | `quota_snapshot.observed_at` and `last_confirmed_at` (never the time the file was read) |
| How often a value was actually observed | `quota_snapshot.confirmations` and `max_confirmation_gap_ms` (new) |
| Plan at observation time | `plan_assignment` (dated, half-open) |
| Who a session's activity belongs to | `session.account_id` (from the transcript's own owner record, see §5) and `account_association` (new, user-made) |
| Local requests | `model_request` with `idx_request_time` |

**What a snapshot's span means.** Within one cycle the utilization never falls. When the same value is seen at two instants, it is **known** for the whole span between them. That is a statement about the value, not about how closely anyone watched. Two readings three days apart and a hundred readings give the same `observed_at`/`last_confirmed_at`, so the span alone cannot tell a well-observed stretch from a bracketed one. That is a demonstrated loss of information, and the two new columns keep it: `confirmations` counts the observations that moved an end of the span (a reread of the same file never does, and one that falls inside the span cannot be told from a reread, so the count is a lower bound), and `max_confirmation_gap_ms` is the longest pause between two of them. The value itself stays exact because of the monotonic argument. Coverage (§3) uses both.

Two further limits of the stored data are handled in code:

* The unique key `(window, cycle, percentage, authority)` merges two sightings of the same value. If a *lower* value is stored after a higher one, the earlier value's confirmations can run past the later value's first sighting. `QuotaCurve` clips such overlaps and reports them. A lower reading in the same cycle is set aside, never treated as a reset and never as negative consumption.
* Quota history cannot be recreated from any file: Claude Code keeps only its latest snapshot, and a Codex rollout holds readings only while the file exists. See §8.

## 2. Reset semantics

`QuotaCycleCalendar` separates four things.

| Term | Meaning | How it is established |
|---|---|---|
| **Announced** reset | A time the provider reported in a reading. It can be in the future. | Every `quota_cycle.resets_at` |
| **Schedule** | A pattern in announcements | Consecutive announced resets a whole number of window lengths apart (within 90 s, tighter for short windows). A weekly window needs two announced resets, a window of a day or less three |
| **Confirmed** reset | A reset after which a reading of the *next* window was taken | The next cycle's first reading lies at or after the announced reset |
| **Exceptional** reset | The window was replaced before its announced reset | A reading of a new window **with a lower utilization** was taken before that time. A fall of less than half a point is rounding |

Consequences:

* The newest announced reset of a schedule is never confirmed, however regular the pattern. For the Claude account in this repository's development data, `2026-10-23T00:00:00Z` was announced, and a reading of the next window at 03:42 UTC confirmed it. `2026-10-30T00:00:00Z` is only announced, and is reported as `expected`, `confirmed = false`. The schedule (Fridays 00:00 UTC, Friday 03:00 in UTC+3) therefore has **two announced resets and one confirmed**, which is `provisional` confidence. Two confirmed resets make it `confirmed`.
* A window seen *before* the previous one's announced reset, without a fall in utilization, is the **same window with a changed announcement** (`announcementChanged`). The two stored cycles become one cycle and nothing is reset.
* A window seen after the announced reset whose own announced reset is **sooner than a whole window later** cannot have had its nominal length (`irregularWindow`). The transition is confirmed, its exact time is not, and the window's start is the earliest it can have begun (the previous reset).
* Readings of two windows taken **at the same time** (typical when several accounts are stored together) are `conflicting`. No transition is claimed, both cycles are marked `overlapsAnotherWindow`, and nothing is measured against them.
* **Calculated cycles.** Once a schedule is established, cycles with no readings are calculated from it: between two observed cycles, forward to the cycle that contains now, and backward to the first local session only when a confirmed reset supports it. They are `projected`, have no readings, and no utilization is ever inferred for them.
* The window length is a fact of the window. Nothing assumes calendar weeks, Monday or Sunday starts, or that five-hour windows tile the day. Windows whose resets do not repeat (five-hour windows start with a request) never form a schedule and are never filled in.
* Boundaries are UTC instants. A subscription week is 168 hours of elapsed time, also across a daylight-saving change. The display zone is a preference (`intelligence.timeZone`).

### What the Codex data showed

The development machine's Codex weekly windows were examined cycle by cycle. A window's announced reset equals its first use plus the window length (for example first seen at 05:02:58, announced for 05:02:01 seven days later), so a Codex window starts when it is first used, like a five-hour window. Two further patterns appear. First, a later window is sometimes seen *before* the previous one's announced reset with a lower utilization (20% fell to 0% three days early). That is evidence of a real transition before the announced time, and it is reported as an exceptional reset. Second, the announced reset of the same window sometimes changes by minutes or hours without any fall in utilization, which is `announcementChanged`. The earlier implementation counted both as early resets. Whether an early transition is a limit reset or a sliding window that decays cannot be told from readings that cover only hours of each week, so the cause is not claimed. The label states only what was observed.

## 3. Coverage

`CycleCoverage` describes how well a cycle was observed, in terms that do not confuse a long span with a watched one.

| Figure | Definition |
|---|---|
| First observation delay | First reading minus cycle start |
| Last observation lead | End of the cycle (or now, for a cycle in progress) minus the last confirmation |
| Observation count | Sum of the confirmations of all values, a lower bound; unknown if any value's count is unknown |
| **Largest unresolved gap** | The longest stretch in which the value is only *bracketed* between two observed values (including before the first and after the last reading). A rise could have gone unseen there |
| Longest unchanged stretch | The longest span in which the value is known not to have changed. The provider reporting no change is not a collection gap |
| Longest observation pause | The longest pause between two observations inside such a span, when known |
| **Determined fraction** | Time in which the value is exactly known (same value at both ends of a span), over the elapsed cycle |
| **Supported fraction** | The part of that time in which observations are also known to lie no more than twice a tolerance apart (four percent of the cycle, between five minutes and twelve hours). A span whose pauses are unknown counts only twice the tolerance at its ends |
| Reliable full-cycle result | The cycle has ended, its start and end were observed, and no unresolved gap exceeds twice the tolerance. Only then is the whole-cycle utilization a result and not a bound |

The old "observed fraction" (first-to-last time over the cycle) was removed because it called a 72-hour span bound by two readings continuous coverage.

### How observation coverage can still improve

Collection is event-driven: a write to the provider's cache is read within about a second (the minimum gap of 1 s is a coalescing gap, and the trailing read is never dropped), only changed readings are stored, and an unchanged or stale cache is never counted as a new observation. The development history shows a median pause of 11 minutes between observations while Claude Code was in use. The coverage that remains missing is outside Tokenwatch's reach: the cache is rewritten only when Claude Code fetches usage, nothing is read while the app is not running, and the status-line source (which could add readings during terminal sessions) was removed earlier because it required editing the user's settings and was never observed to deliver data. Tokenwatch does not launch Claude Code, does not call any endpoint, and does not read credentials to fill gaps. The honest remedy is the one the page gives: leave the app running (launch at login is available) and open `/usage` occasionally; every genuine new reading is kept with its original time.

## 4. Per-cycle analytics

`SubscriptionUsageAnalyticsEngine.analyze` streams the requests of the analysed cycles once, ordered by time, with bounded memory. Token totals use the canonical categories of [TOKEN-ACCOUNTING.md](TOKEN-ACCOUNTING.md). A request shared by a parent and a sub-agent transcript is one row and is counted once, and reasoning tokens are never added a second time.

Per cycle it reports processed, fresh, uncached input, output, cache-read, cache-creation (five-minute, one-hour and unstated), requests, sessions, sub-agent sessions and tokens, API-equivalent cost, active periods, models and projects, the plan, coverage (§3) and attribution (§5).

**Daily breakdown.** A subscription day is 24 elapsed hours from the cycle start; calendar days follow the selected zone (23 or 25 hours on a daylight-saving change, and a partial first and last day). A day's quota change is `exact` when both ends were observed, a **bracket** when an end lies between two readings, and `unavailable` outside the observed part of the cycle. Nothing is interpolated, and a day is not a limit.

### Observed associations (efficiency)

For a cycle, the work is measured between two **exact** observations: from the last moment the first value was confirmed to the first moment the last value was seen.

* processed, fresh and cache-read tokens per point, API-equivalent cost per point, and points per million tokens, each with the **rounding range** (a rise of Δ points can be a true rise of Δ ± 1, so the ratio lies between W/(Δ+1) and W/(Δ−1); it is not a confidence interval).
* **Gates.** A rise of at least 5 points, two separate rises, a million processed tokens and 30 minutes. It is `reliable` with at least 10 points, three rises and steady step ratios; otherwise `indicative`, or absent with the reasons listed.
* **Zero-delta work.** A stretch inside the interval where the value did not change is not skipped: its work is part of the measurement, because a ratio that ignored it would overstate how little a point costs. Work before the first confirmation's end and after the last value's first sighting is outside the interval.
* **Validity.** The interval must lie inside one account, pool, scope and cycle (it does by construction). It is **withheld** when a plan period begins or ends inside it, when the cycle overlaps another window's readings, and when more than 2% of the interval's local work is **not tied to the account** (§5). The interval's cache-read share and model mix are shown so that differences in caching and models are visible.
* **Caveats** always attached: the percentage is account-wide while tokens are local; plan not recorded or changed; neither side names an account (for the unassigned account); activity associated by the user; rounded percentages; unpriced models; scoped window.

These are associations measured in one cycle. They are not the provider's metering formula.

**Comparisons.** `CycleComparisonEngine` lists why two cycles are not directly comparable: different or unrecorded plan, model-mix half-distance over 0.25, cache-read share differing by more than 10 points, partial quota observation, supported coverage differing by more than 25 points, or calculated boundaries. Only comparable cycles get a pace change or a tokens-per-point change, and only when both ratios are reliable. The result is a signed relative change, never an "improvement".

## 5. Account attribution

Local activity is tied to an account only by evidence:

1. **The transcript itself.** Claude Code `bridge-session` records carry `ownerAccountUuid`, which hashes to the same reference as the account of the quota cache. On the development machine 51 of 186 sessions carried it, covering most of the activity since 16 October. A session with such a record is stored under that account; every other session stays unassigned. The raw identifier is never stored.
2. **A user association.** A time-bounded statement that the activity of sessions which name no account, within a period, belongs to one identified account. It is stored separately (`account_association`), never changes a session, can be corrected or removed, is never created automatically, and periods of one provider cannot overlap. An association to another account removes that activity from this account's view entirely.

Nothing is matched by reset times, timestamps or consumption patterns. Per cycle the report says how much is tied:

| Attribution | Meaning |
|---|---|
| `account` | Every local token of the cycle is tied to this account |
| `partlyAttributed` / `unattributed` | Some or all of the local tokens name no account and no association covers them. Only the attributed ones are counted; the rest is shown separately, and the share is stated |
| `unassignedAccount` | The analysed account is the unassigned one: readings and sessions both name no account |
| `ambiguous` | Unattributed activity exists while another identified account of the provider was active, or the unassigned readings overlap an identified account's cycle |
| `notAttributed` | A model-scoped window whose scope name matches no model |

The unassigned account's comparison uses every session of the provider, because its readings name no account. Sessions that do name an account are counted as not tied, and withhold the ratio while they matter. The unassigned pool's history is never moved into an identified pool, even when it looks like the same account.

## 6. Forecasting

`UsageForecastEngine` predicts the utilization at the end of the current cycle from the **reported utilization history only** (local tokens describe one Mac). There are three methods:

1. `cycleAveragePace`: the pace over the whole cycle so far applied to the time left.
2. `recentPace`: the pace over the last quarter of the cycle.
3. `sameStageIncrement`: the current value plus the median rise that earlier cycles of the same plan made after the same point (needs three earlier cycles).

Two further methods that existed earlier (the median of earlier final values, and the median of all methods) were removed: on the synthetic histories of the tests neither beat the same-stage increment, which holds the same information, by more than the provider's rounding, so they only added ways to overfit.

**Backtest and selection.** Every earlier cycle with a known final value is forecast at 25%, 50% and 75% of its length from the readings that existed then, using only cycles that ended before it began and are on the same plan. Cycles that were cut short, overlap another window, or whose readings may belong to several accounts are left out. The best method by mean absolute error is chosen, preferring the simplest within 5% or half a point (rounding noise).

**Held-out check.** Picking the best of several methods on the same cycles that its error is reported on makes the error look better than it is (the winner's curse). The tests demonstrate it: on a noisy history the chosen method's in-sample error is 8.9 points and its held-out error 11.4. So the choice is replayed in time order: for each cycle the method comes from earlier cycles only (the default method with fewer than two), and the error of that forecast is what is reported. Only the newest six held-out cycles count, so an old regime of use does not decide whether the current one can be forecast.

**Minimum evidence.** A forecast is shown only if, on held-out forecasts, there are at least 8 from at least 4 cycles, the typical error is at most 12 points, **and** it is at most 75% of the error of assuming no further use. Four cycles of a perfectly learnable accelerating pattern are refused (in-sample error 0, held-out error 49 points, because the method had learned nothing yet); twelve are accepted (held-out error under 1 point). A plan change during the current cycle also withholds it.

**Range, not confidence.** The range is the spread of the held-out errors (all of them while there are fewer than 20, the middle 80% after), never narrower than one point on each side because the provider reports whole percentages. It is not a confidence level, and the page reports how often the range held in a replay that used only earlier errors.

* **Exhaustion** is estimated only for an available forecast whose range reaches the limit, assuming a steady remaining pace, in day parts ("Thursday evening").
* **Remaining work** multiplies the remaining points by the median of the reliable ratios of earlier cycles on the same plan (at least two), labelled an observed relationship.
* **Warnings** are never hidden: plan not recorded, earlier cycles on another plan left out, model mix changed, earlier cycles reached the limit, other surfaces use the allowance unseen.
* The page keeps four quantities apart: *reported by the provider*, *observed so far*, *forecast at the reset*, and *estimated exhaustion*.

## 7. Insights and readiness

`UsageInsightsEngine` turns the numbers into at most five deterministic statements (token change versus the previous cycle above 20%, quota pace change for comparable cycles, busiest day, most-used model, cache-read share, front-loaded usage, cycles that reached the limit, limited observation, local usage not tied to the account, exhaustion). Cycle-to-cycle statements need a window of at least two days.

`IntelligenceLogic.readiness` writes what the page can and cannot say right now and what would change that, from the same numbers: how the schedule is supported (for example "Your next weekly reset is expected … The schedule is based on 2 provider-announced reset times and 1 confirmed reset, not on two confirmed reset events"), that usage statistics are available while quota-efficiency estimates need more observations, that local usage cannot currently be reliably assigned to the account, and why no forecast is shown.

## 8. Data preservation

| Data | Recreatable from files? | Rebuild from source | Delete all data | Retention |
|---|---|---|---|---|
| Requests, sessions, projects, models | Yes, while the files exist (Claude Code deletes transcripts after 30 days by default) | Cleared and re-imported, after a backup | Deleted | Deleted past the cutoff |
| Quota snapshots and cycles | **No** (Claude Code keeps only its latest snapshot) | **Kept** | Deleted | Deleted only when the whole span is past the cutoff |
| Plan periods, capacity measurements | No | **Kept** | Deleted | Kept |
| Account associations | No | **Kept** | Deleted | Kept |
| Derived analytics and forecast results | n/a, computed on demand | Nothing stored | Nothing stored | Nothing stored |

Audit findings: rebuild only clears the tables derived from logs and takes a full copy of the database first (`VACUUM INTO`, three newest kept); corruption recovery moves the damaged file aside and never deletes it. One genuine data-loss path was found and fixed: retention deleted quota snapshots by their **first** sighting, so a snapshot first seen before the cutoff but still being confirmed afterwards was erased. It now deletes only snapshots whose last confirmation is past the cutoff, and removes the cycles left with no snapshot. Tests cover rebuild, backup, delete-all and retention with associations, plans and coverage columns present.

## 9. Export

`ExportKind.usageIntelligence` (Settings › Export, the page's Export menu, `tw export --kind usageIntelligence`) writes `cycle`, `day` and `forecast` rows as JSON or CSV with every column defined in the metadata, including the coverage figures, attribution and the held-out forecast evidence. Empty cells mean unknown, never zero. The account label is a short hash prefix; no raw identifier or full hash is exported.

## 10. Performance

* Nothing runs unless the page is visible. A choice the user makes recomputes after 30 ms; data changes (which arrive in bursts while a tool runs) wait 3 s for the burst to settle and then compute once. A newer change cancels the wait, and a stale result is dropped.
* The computation runs on a background task. One query per subject streams requests ordered by `requested_at`, quota history is two small indexed queries, nothing is written and nothing is read from the network. The page analyses the newest 14 cycles.
* Measurements are in [PERFORMANCE.md](PERFORMANCE.md).

## 11. Known limits

* Quota is account-wide; local tokens cover only this Mac. A change in utilization can come from chat, other devices or other tools.
* History begins when Tokenwatch first read a source and cannot be reconstructed. Cycles before the first observed reset are only calculated.
* Only some sessions name their account (`bridge-session` records). The rest need a user association, and without one no ratio is shown for an identified account. Readings stored before the account was named sit in the unassigned pool, which cannot be proven to be the same account, so the history of those weeks is separate from the current account's.
* The cache that supplies Claude quota is an undocumented internal file; see [QUOTA.md](QUOTA.md).
* The provider rounds percentages; ratios from small rises are withheld and the rest carry a rounding range.
* Forecasts need about four fully observed cycles to qualify, more when the pattern is irregular, and may never qualify for an unpredictable history. That is intended.
