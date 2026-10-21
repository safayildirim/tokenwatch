import Foundation

/// Reads the session files that the Codex engine writes under `~/.codex` (or `$CODEX_HOME`).
///
/// One engine serves several applications: the Codex command line, the Codex desktop app, the IDE plugins and
/// the Work mode of the ChatGPT desktop app. Every session file begins with a header that names the application
/// (`originator`), so a single adapter covers all of them and the header decides which product a session
/// belongs to.
///
/// File layout:
/// - `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl` holds one session while it is active.
/// - `….jsonl.zst` is the same file after Codex has compressed it. A compressed file never changes again.
/// - `archived_sessions/` holds sessions that the user archived, in the same two forms.
///
/// What is read: the session header, the model in use, the token usage records, the quota snapshots and the
/// compaction markers. Message text, tool input and tool output are skipped without being decoded, and nothing
/// from them is stored. `auth.json` and the other files in the folder are never opened.
///
/// How a request is identified:
/// - Newer versions write a `token_usage_record` line for each model response, which carries the response id.
///   That id identifies the request, so reading the same response twice, or once from each of two copies of a
///   session, counts it once. A `token_count` event that reports the same figures as a nearby record is the same
///   response and is not counted again.
/// - Older versions only write a `token_count` event after each response. Such an event is identified by its
///   position in its session. The running totals in the event are not used as an identity. They only decide
///   whether an event reports a new response or repeats the previous snapshot, and they are compared with the
///   response's own figures so that a response with no event of its own is noticed and accounted for.
/// - A file can contain both kinds, for example when a session was resumed under a newer version. Records are
///   counted by response id, and an event that no record explains is counted as a response of its own.
/// - A fork copies its parent's history into its own file. The parent's file is found through the fork's header and
///   the copied lines are recognized by what they say, which is the same figures as the parent's own lines, and
///   not by when they were written. Only when the parent's file is not available does the instant of the fork serve
///   as a fallback, and the session is then reported as uncertain.
public struct CodexAdapter: SourceAdapter {
    public var sourceID: TelemetrySourceID { .codexRollouts }
    public var displayName: String { String(localized: "Codex (CLI, Desktop, IDE and ChatGPT Work)") }
    public let home: URL

    public init(home: URL = CodexAdapter.defaultHome) { self.home = CanonicalPath.resolve(home) }

    /// The folder Codex keeps its data in. The tests and experiments can redirect it with
    /// `TOKENWATCH_CODEX_DIR`. Otherwise `CODEX_HOME` applies, as it does for Codex itself.
    public static var defaultHome: URL {
        let env = ProcessInfo.processInfo.environment
        for name in ["TOKENWATCH_CODEX_DIR", "CODEX_HOME"] {
            if let value = env[name], !value.isEmpty { return URL(fileURLWithPath: (value as NSString).expandingTildeInPath) }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public var sessionsDirectory: URL { home.appendingPathComponent("sessions") }
    public var archivedDirectory: URL { home.appendingPathComponent("archived_sessions") }

    public var watchRoots: [URL] { [sessionsDirectory, archivedDirectory] }

    public var coverageNote: String {
        String(localized: "Reads local Codex session files only. ChatGPT chat conversations leave no usage records on this Mac, so they are not included.")
    }

    /// Lines refer to earlier lines (the header names the session, and the running totals tell snapshots from new
    /// responses), so a changed file is always read from the top.
    public var resumesFromCheckpoint: Bool { false }

    public func discoverFiles() throws -> [SourceFileRef] {
        var out: [SourceFileRef] = []
        for (directory, archived) in [(sessionsDirectory, false), (archivedDirectory, true)] {
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if let ref = reference(path: url.path, archived: archived) { out.append(ref) }
            }
        }
        return out
    }

    public func fileRef(forPath path: String) -> SourceFileRef? {
        let sessions = sessionsDirectory.path + "/", archived = archivedDirectory.path + "/"
        if path.hasPrefix(sessions) { return reference(path: path, archived: false) }
        if path.hasPrefix(archived) { return reference(path: path, archived: true) }
        return nil
    }

    private func reference(path: String, archived: Bool) -> SourceFileRef? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") else { return nil }
        return SourceFileRef(sourceID: sourceID, path: path, sessionHint: Self.sessionID(inFileName: name),
                             hints: archived ? ["archived": "1"] : [:])
    }

    /// The session id that a file name ends with, for example `rollout-2026-10-12T12-40-20-<uuid>.jsonl`.
    static func sessionID(inFileName name: String) -> String {
        var stem = name
        for suffix in [".zst", ".jsonl"] where stem.hasSuffix(suffix) { stem = String(stem.dropLast(suffix.count)) }
        // The identifier is the trailing canonical UUID (36 characters). Anything else is returned as it is.
        if stem.count >= 36 {
            let tail = String(stem.suffix(36))
            if tail.filter({ $0 == "-" }).count == 4 { return tail }
        }
        return stem
    }

    public func makeParser(for file: SourceFileRef) -> any LineParser {
        CodexLineParser(file: file, parentHistory: { id in self.history(ofThread: id) })
    }

    // MARK: Lineage

    /// The files that hold a thread, found by the thread id in their name. A thread can exist in several copies
    /// (active, archived, compressed), and each of them contains the same history.
    func files(ofThread id: String) -> [SourceFileRef] {
        guard let all = try? discoverFiles() else { return [] }
        return all.filter { $0.sessionHint == id }
    }

    /// What the thread's file says about the usage it recorded, or nil when the thread is not on this Mac. A fork uses
    /// this to tell the lines it copied from the lines it wrote itself.
    func history(ofThread id: String) -> CodexInheritedHistory? {
        var merged: CodexInheritedHistory?
        for ref in files(ofThread: id) {
            guard let data = try? CodexFileContents.read(path: ref.path) else { continue }
            let parser = CodexLineParser(file: ref, parentHistory: nil, collectsHistory: true)
            var scratch = NormalizedBatch()
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var start = 0
                while start < data.count {
                    let end = memchr(base + start, 0x0A, data.count - start).map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? data.count
                    if end > start {
                        parser.parse(line: UnsafeBufferPointer(start: base + start, count: end - start), offset: Int64(start), into: &scratch)
                    }
                    start = end + 1
                }
            }
            let found = parser.collectedHistory
            if merged == nil { merged = found } else {
                merged!.responseIDs.formUnion(found.responseIDs)
                merged!.snapshots.formUnion(found.snapshots)
            }
        }
        return merged
    }

    // MARK: Mapping from the header

    /// Which product and surface an `originator` value identifies. A value that is not recognized is Codex on
    /// an unknown surface, and the `source` field of the header is used as a hint.
    static func classify(originator: String?, source: String?) -> (product: ProductID, surface: SurfaceID) {
        // Originators are words joined by punctuation, such as `codex_work_desktop` or `JetBrains.WebStorm`. They are
        // compared word by word, so that a name merely containing letters of a keyword (`client`) is not mistaken for it.
        let words = Set((originator ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if words.contains("work") { return (.chatGPTWork, .chatGPTDesktop) }
        if words.contains("jetbrains") { return (.codex, .jetbrains) }
        if words.contains("vscode") { return (.codex, .vscode) }
        if words.contains("desktop") { return (.codex, .codexDesktop) }
        if !words.isDisjoint(with: ["exec", "cli", "tui"]) { return (.codex, .terminal) }
        switch (source ?? "").lowercased() {
        case "vscode": return (.codex, .vscode)
        case "exec", "cli": return (.codex, .terminal)
        default: return (.codex, .unknown)
        }
    }
}


extension UsageNormalizer {
    /// OpenAI Responses usage as written by Codex. `input_tokens` includes the cached tokens, and
    /// `output_tokens` includes the reasoning tokens. This was verified on real session files, where
    /// `total_tokens` equals `input_tokens + output_tokens` for every request.
    ///
    /// Whether cache-write tokens are included in `input_tokens` has not been observed, because the field is
    /// always zero in the files inspected. The conversion assumes they are, in line with the rest of the
    /// report, and `normalization` records that assumption.
    public static func openAI(inputTokens: Int64, cachedInputTokens: Int64?, cacheWriteInputTokens: Int64?,
                              outputTokens: Int64, reasoningOutputTokens: Int64?) -> UsageMeasurement {
        let cached = cachedInputTokens ?? 0
        let written = cacheWriteInputTokens ?? 0
        let uncached = max(0, inputTokens - cached - written)
        return UsageMeasurement(
            uncachedInput: uncached, cacheRead: cachedInputTokens, cacheCreation: cacheWriteInputTokens, output: outputTokens,
            reasoningOutput: reasoningOutputTokens, normalization: "openai.responses.v1",
            completeness: cachedInputTokens == nil ? .partial : .complete)
    }
}
