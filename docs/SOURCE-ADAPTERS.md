# Source adapters

A source adapter turns one kind of local usage record into the application's normalized observations. Adapters are independent: the collector gives each its own error boundary, so one failing source never stops another.

## The contract

```swift
public protocol SourceAdapter: Sendable {
    var sourceID: String { get }
    var displayName: String { get }
    var watchRoots: [URL] { get }                          // directories to watch with FSEvents
    func discoverFiles() throws -> [SourceFileRef]         // cheap enumeration for scans and reconciliation
    func fileRef(forPath path: String) -> SourceFileRef?   // classifies a path reported by FSEvents
    func makeParser(for file: SourceFileRef) -> any LineParser
    var coverageNote: String { get }                       // shown in Diagnostics: what is NOT covered
}

public protocol LineParser: AnyObject {
    func parse(line: UnsafeBufferPointer<UInt8>, offset: Int64, into batch: inout NormalizedBatch)
    func flush(into batch: inout NormalizedBatch)
}
```

The generic machinery does everything else: durable checkpoints, resuming at a line boundary, rotation/truncation/replacement detection, bounded-memory streaming, atomic commits, retries, health reporting and file watching. An adapter only needs to say where its files are and how to read a line.

A parser must be tolerant: a malformed line increments `batch.malformedLineCount` and never prevents the following lines from being processed. A parser must produce observations whose identity is stable (`requestKey`), so that re-delivery merges instead of duplicating.

Adding a source takes three steps: implement the protocol, give it a unique `sourceID`, and register it in `AppModel` / `ccu`. Add fixtures and tests in the style of `Tests/UsageCoreTests/AccountingTests.swift`.

## The Claude Code adapter

`ClaudeCodeAdapter` reads `~/.claude/projects`. One adapter covers the terminal CLI, the VS Code extension and Claude Desktop's Code tab, because they share this folder (the `entrypoint` field of each record, `cli`, `claude-vscode` or `claude-desktop`, becomes the session's "source application").

### File layout

| Path | Meaning |
|---|---|
| `<project>/<session-id>.jsonl` | The main conversation |
| `<project>/<session-id>/subagents/agent-<agent-id>.jsonl` | A sub-agent of that session (records carry the parent `sessionId` and an `agentId`) |
| anything else (`tool-results/`, `memory/`) | Ignored |

`<project>` is the working directory with every non-alphanumeric character replaced by `-`. This mapping was verified against the first `cwd` of every session on this machine (169 of 169). It is lossy, so the real path is taken from the record's `cwd`, and trusted as the project root only when it re-encodes to the folder name.

### Records read

Only these top-level members are decoded. Everything else is skipped without allocation.

| Record | Fields used | Becomes |
|---|---|---|
| `assistant` | `message.id`, `message.model`, `message.stop_reason`, `message.usage.*` (including `cache_creation.*` and `speed`), `requestId`, `agentId`, `timestamp`, `sessionId` | a `RequestObservation` |
| any record with a timestamp | `timestamp`, `sessionId`, `cwd`, `entrypoint`, `version`, `agentId` | session and agent activity (first and last seen) |
| `cost-state` | `totalCostUSD`, `modelUsage.*` | Claude Code's own cost summary, stored separately |

**Never read into memory as values or stored:** `message.content`, `toolUseResult`, prompts, `last-prompt`, `ai-title`, tool input and output, and file contents. The privacy test writes distinctive secrets into every such field and asserts they do not appear in the database file, its WAL, or any export.

### Lifecycle signals

* **Observed:** `~/.claude/sessions/<pid>.json` is written by each running Claude Code process (session id, pid, busy or idle, entrypoint) and removed on exit. `SessionRegistryMonitor` watches it. A process id is accepted only if the process exists **and** its start time matches the registry's `procStart`, so a recycled pid is not mistaken for a session. A session that disappears from the registry gets an observed end time. A session that reappears (resumed) has it cleared. The neighbouring `.key` files hold a peer token and are never opened.
* **Inferred:** with no registry entry, a session is Active within 2 minutes of its last record, Idle within 60 minutes, otherwise Completed. These thresholds are settings. Inferred states are always labelled "(inferred)"; an unchanged file never produces an unqualified "Completed".

### Version and format changes

The parser is deliberately tolerant. Unknown fields are skipped; missing optional fields (for example the 5 m / 1 h cache split in older versions) become null; a record that cannot be parsed is counted in the file's `malformed_lines` and shown in Diagnostics. Nothing in the parser depends on a particular Claude Code version.

## Sources not implemented, and why

| Source | Status |
|---|---|
| Claude Code OpenTelemetry | Not implemented. It needs a local OTLP receiver, a configuration change in the user's shell, and adds no field the transcripts lack. The `api_request` event carries `request_id`, which is stored on every request, so an OTel adapter could be added later and would merge with the transcripts instead of double counting. |
| Claude Desktop Chat / Cowork | No local record of tokens or sessions exists to read. |
| Anthropic Admin API | Describes API-key usage, not subscription usage. |
