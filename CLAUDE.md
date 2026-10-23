# Tokenwatch

Tokenwatch is a native macOS menu bar app that monitors AI coding usage across providers, currently Claude Code and OpenAI's Codex engine, from the local files those tools write. It is a Swift package. `UsageCore` holds all collection, storage, accounting, quota and analytics logic with no UI dependency. `UsageUI` holds the SwiftUI views and the observable model behind them, and the menu bar app, the `tw` command line tool and the `tw-statusline` helper sit on top of both.

## Non-negotiable invariants

These are architectural and product constraints. If a task conflicts with one, explain the conflict before making changes.

- **Honest quota:** A quota percentage is shown only when the provider itself reported it. It is never computed from token counts, and the UI never fills a gap with an estimate. See `docs/QUOTA.md`.
- **Canonical rules:** Pricing, token accounting, and quota rules are defined once, in `UsageCore`. `docs/TOKEN-ACCOUNTING.md` is the reference for them. The UI may contain presentation metadata, such as labels and colors, but never a competing formula.
- **Thin UI:** `UsageCore` has no UI dependency, so the menu bar app, the `tw` tool, and the tests all run the same code. Views present values that `UsageCore` computes and never recompute costs, token totals, quota, or capacity themselves.
- **One store:** Each provider is an adapter over one schema and one database, so every account's usage lives in one place. Totals never depend on which tool produced a record. Provider separation must not split the usage history.
- **Dependencies:** Prefer the Swift standard library, Foundation, and the platform frameworks already in use. Vendor code only when macOS lacks it, as with `CZstd`, and record its provenance. Add any other dependency only with a concrete or measured reason.
- **Domain ownership:** Each area owns its data and rules: adapters in `Ingest`, the schema in `Storage`, and `Pricing`, `Quota`, `Analytics`, `Capacity`, `Alerts`, and `Export`. Cross-area changes use explicit APIs, never direct writes to another area's tables or duplicated business logic. `ArchitectureIsolationTests` enforces where provider names may appear.
- **Consistency:** Ingested requests and their deduplication state must commit in one transaction, so a crash never leaves a request half-recorded. Dashboards and capacity figures are queries over stored requests, so they cannot drift from the data they summarize.
- **Idempotency:** Re-reading a file, replaying a session after compaction, or receiving a streaming snapshot must never count the same request twice. A restart or rescan must produce the same totals as before.
- **Incremental ingest:** Prefer incremental, event-driven ingest from file-system events over periodic full rescans. Measure before adding any scheduled full scan. See `docs/PERFORMANCE.md`.
- **Background collection:** Collection continues while the dashboard window is closed, because the menu bar process keeps ingesting. Closing a window must never stop recording.
- **Explainability:** Every stored request keeps its source and the normalization rule used to store it. Every derived number is labelled with what it measures, such as processed or fresh tokens, so a reader can see what produced it.
- **Auditability:** Requests are immutable observations. Aggregation reads them and never edits them, and every figure can be traced back to the stored requests it came from.
- **Database safety:** Never reset, recreate, or migrate the user's real usage database unless it is positively identified as a development or test database. Before the first release, a schema change may edit the existing migration in place, as `docs/SCHEMA.md` describes. After the first release, schema changes are appended as new migrations, and existing user data is preserved.
- **Helper compatibility:** `tw-statusline` runs as Claude Code's status line command and deliberately does not depend on `UsageCore`, so its start-up cost stays minimal. Changes to its output or behavior must keep already-installed status line entries working.
- **Price catalog:** Built-in prices are reinstalled when the catalog fingerprint changes, and user-defined price rows are never overwritten.

Prefer the smallest correct change. Preserve domain boundaries and deterministic behavior. Do not refactor unrelated code or modify generated, vendor, or lock files unless required.

**Engineering priority:** correctness > domain boundaries > simplicity > determinism/debuggability > operational reliability > measured performance > future extensibility.

## Essential commands

Run all commands from the repository root. The Makefile targets are short names for the scripts in `scripts/`, which hold the real build and install logic.

- Focused test: `swift test --filter <TestClassName>`
- Full test suite: `make test`
- Build the app without installing it: `make build`
- Universal build (Apple silicon and Intel): `make universal`
- Build and install: `make install` (this replaces the app the user runs, so run it only when asked)
- Start at login: `make launchagent` (same caution as `make install`)
- Build/typecheck/lint: inspect the `Makefile`, `Package.swift`, or `scripts/`; do not invent targets.

**Testing reference:** `docs/VALIDATION.md` records what the tests prove and the checks against real data. Read its relevant section before changing tests, test helpers, or fixtures.

Critical testing constraints:

- Build test data with the helpers in `Tests/UsageCoreTests/TestSupport.swift` and `Tests/UsageUITests/UITestSupport.swift`, and reuse the recorded files in `Tests/UsageCoreTests/Fixtures` before adding new ones.
- No test may read or write the user's real usage database, `~/.claude`, or `~/.codex`.
- Use the fixed instant `t0` from `TestSupport.swift` rather than the current date, so results do not depend on when a test runs.
- Tests must be deterministic: no real-time sleeps for synchronization or unbounded polling.
- Test meaningful behavior, invariants, contracts, and plausible failures—not coverage for its own sake.
- Do not run full suites repeatedly or concurrently. Long runs should execute in the background when supported.
- For performance claims, compare identical workloads and state whether each result is cold or warm.

Do not run the full suite when a narrower relevant test can answer the question. Escalate only when necessary. For Swift changes, run the affected test classes, then `make test`, before reporting completion. Run `make build` when a change touches the app bundle, scripts, or resources. Run performance measurements only when relevant or requested; see `docs/PERFORMANCE.md`.

## Context budget

Treat context as scarce. Optimize total task cost without compromising correctness.

- Start with the minimum evidence needed to solve the task.
- Do not explore unrelated directories for completeness.
- Do not read large logs, generated files, snapshots, lockfiles, or vendor files whole unless necessary.
- Do not re-read content already present in context unless it may have changed.
- Do not load reference documentation speculatively.
- Expand context when required for correctness; limits are defaults, not reasons to ignore dependencies.
- For materially unrelated work, prefer a fresh session over carrying stale exploration forward.

## Code discovery

Prefer this order:

1. Known symbol: use code intelligence/LSP definitions, references, implementations, or workspace-symbol search when available.
2. Unknown location: discover candidate file paths before searching content.
3. Narrow by directory, file type/glob, or exact identifier.
4. Request matching lines only after narrowing candidates.
5. Read the smallest coherent region needed to understand the behavior.

Never start with unbounded repository-wide content search when scoped discovery can answer the question.

For search tools:

- Prefer filenames (`files_with_matches`), counts, or equivalent modes before content.
- Start with no more than approximately 25 content matches.
- Narrow scope before raising output limits.
- Use equivalent constraints with shell `rg`, `grep`, and `git grep`.
- `rg --max-count` limits matches per file, not total output; apply a separate global output bound.
- Never interpret truncated results as proof that additional matches do not exist.

Examples:

- `rg --files server -g '*.go' | head -50`
- `rg -l -F -- 'SymbolName' server/internal | head -25`
- `rg -n -F -- 'SymbolName' server/internal/specific-package | head -25`

Avoid repeating searches whose results are already known.

## File reads

- Reading a small, clearly relevant file in full is acceptable.
- For medium/large files, locate the symbol or relevant line first.
- Start with one coherent window, normally 80–160 lines.
- Expand when control flow, interfaces, dependencies, or nearby logic require it.
- Prefer the available Read tool with offset/limit, or equivalent bounded reading.
- Do not sequentially page through large files merely to discover their contents; navigate or search first.
- Do not enable unrestricted large-file reads unless genuinely necessary.
- Prefer symbol/reference navigation over reading multiple candidate files.

## Command and log output

Keep high-volume raw output out of the model context.

- Save verbose test/build output to a temporary log when practical.
- Return the actual exit status, relevant failures, and short diagnostic context.
- Start with at most approximately 80 diagnostic lines; expand only if needed.
- Use filters or bounded output for noisy commands without hiding failures.
- Never treat filtered, truncated, or incomplete output as a successful command result.
- Prefer `git status --short`, `git diff --stat`, and scoped `git diff -- <paths>` over large unfiltered diffs.
- Avoid recursive directory listings, dependency dumps, and repeated benchmark runs without a specific diagnostic purpose.

## Editing

- Inspect the relevant code and contracts before editing.
- Make the smallest coherent patch.
- Do not rewrite a large file for a localized change.
- Preserve existing style and established architecture.
- Avoid drive-by cleanup and unrelated refactoring.
- Do not modify unrelated pre-existing working-tree changes.
- After editing, inspect only the relevant diff and affected dependencies.
- Update tests or contracts only when behavior actually requires it.

## Verification

Use the cheapest verification that can falsify the change:

1. Relevant unit/file test.
2. Relevant static checks, typecheck, or lint when available.
3. Affected test classes in `UsageCoreTests` or `UsageUITests`.
4. Required full suite: `make test`.
5. Build only when justified by the change's scope: `make build` when the change affects the app bundle, scripts, or resources.

On failure, inspect the smallest useful diagnostic excerpt before requesting more output.

Before reporting completion, check the applicable invariants above, especially local-first privacy, quota provenance, idempotent ingest, domain ownership, database safety, helper compatibility, and price correctness.

State what passed, what failed, what was not run, and why. Never claim verification that did not occur.

## Delegation budget

Default to the main context.

Use a subagent only when at least one applies:

- The investigation will generate substantial disposable search, log, or documentation output worth isolating.
- The task is genuinely independent and parallel execution provides concrete value.
- A cheaper model can complete a bounded lookup or classification without changing the main session's model.

Do not delegate trivial edits, single-symbol lookups, focused tests, or routine work merely because it is described as complex.

Prefer one subagent at a time unless parallelism has a clear benefit. Give each subagent a narrow objective, bounded scope, and a concise deliverable with relevant `file:line` evidence—not raw logs.

When available:

- **Haiku:** bounded location, extraction, and classification.
- **Sonnet:** ordinary isolated coding and review.
- **Opus:** genuinely difficult architectural or reasoning problems.

Delegation has its own token cost; do not assume it saves tokens automatically.

## Model and cache hygiene

- Do not switch the main-session model just to handle a small cheap task.
- Adjust reasoning effort when available before changing models solely for cost.
- Avoid changing MCP/plugin/tool configuration in the middle of a long active task unless required.
- Keep shared project instructions stable to avoid unnecessary prompt-prefix changes.
- Do not store current-task status, timestamps, branch status, temporary discoveries, or changing TODOs here.
- Do not assume this file controls prompt-cache TTL or guarantees cache hits.
- Prefer concise final reports over repeated summaries of tool output.

## Conditional instructions

Keep this file focused on rules needed across the project.

- Use `.claude/rules/` with `paths:` for detailed file/domain-specific instructions when those rule files are actually created and maintained.
- Use skills for specialized multi-step workflows and substantial reference material.
- Use ordinary project documentation for information needed only during relevant tasks.
- Read `docs/VALIDATION.md` for test-specific details and the relevant page in `docs/` (such as `docs/SCHEMA.md` or `docs/QUOTA.md`) for architectural decisions.
- Do not use `@imports` merely to conceal a large always-loaded instruction set.
- Do not duplicate this file into multiple always-loaded prompt files.

The root `CLAUDE.md` may import `@AGENTS.md` as the single source of shared project instructions.

## Project map

High-value orientation only:

- `Sources/UsageCore/`: all collection, storage, accounting, quota, and analytics logic, grouped by area (`Ingest`, `Storage`, `Pricing`, `Quota`, `Analytics`, `Capacity`, `Alerts`, `Export`, `Domain`).
- `Sources/UsageUI/`: SwiftUI views and the observable model behind them.
- `Sources/Tokenwatch/`: the menu bar app entry point.
- `Sources/tw/`: command line tool for headless imports, verification, and benchmarks.
- `Sources/tw-statusline/`: the status line helper that Claude Code runs.
- `Sources/CZstd/`: vendored Zstandard decompression; see its `README.md` for provenance.
- `Tests/UsageCoreTests/` and `Tests/UsageUITests/`: test targets. `Fixtures/` holds recorded provider files.
- `Package.swift`: targets and products.
- `Makefile` and `scripts/`: build, bundle, install, and LaunchAgent logic.
- `docs/`: `ARCHITECTURE.md` (overall design), `TOKEN-ACCOUNTING.md`, `QUOTA.md`, `SCHEMA.md`, `SOURCE-ADAPTERS.md`, `CAPACITY.md`, `OPENAI-CODEX.md`, `PERFORMANCE.md`, and `VALIDATION.md` (tests and checks against real data).
- `Localization/`: `en.lproj` and `tr.lproj` strings.

Discover other paths when needed; do not maintain a full repository inventory here.

## Compact

When compacting context, preserve:

- The user's current objective and acceptance criteria.
- Architectural decisions and constraints already established.
- Files changed and the reasons for those changes.
- Unresolved errors, questions, and blockers.
- Tests and verification already completed, including failures.
- The smallest set of relevant file paths needed to continue.

Discard:

- Superseded hypotheses and abandoned approaches.
- Verbose search results and raw build/test logs.
- Temporary exploration details.
- Repeated explanations and information trivially recoverable from a known path.
