import Foundation

// The status line helper that Claude Code runs on every refresh.
//
// Claude Code writes a JSON document to this process's standard input. Only one part of it is kept:
// the documented `rate_limits` object, which holds the subscription utilization and reset time of
// the five-hour and seven-day windows. Everything else in the input (the model, the working
// directory, the transcript path, the cost) is discarded without being stored.
//
// The helper must never break the user's status line, so every failure path still exits with
// status 0, and any status line command given with `--chain` is run and its output passed through.

func readAllStandardInput(limit: Int = 4 << 20) -> Data {
    var data = Data()
    while data.count < limit {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return data
}

func number(_ any: Any?) -> Double? {
    (any as? NSNumber)?.doubleValue
}

/// Returns the rate-limit windows found in the input, keyed by window name.
func rateLimitWindows(in root: [String: Any]) -> [String: [String: Double]] {
    guard let limits = root["rate_limits"] as? [String: Any] else { return [:] }
    var windows: [String: [String: Double]] = [:]
    for (kind, value) in limits {
        guard let w = value as? [String: Any], let used = number(w["used_percentage"]), used.isFinite else { continue }
        var entry: [String: Double] = ["used_percentage": used]
        if let r = number(w["resets_at"]) { entry["resets_at"] = r }
        windows[kind] = entry
    }
    return windows
}

func summaryLine(_ windows: [String: [String: Double]]) -> String {
    var bits: [String] = []
    if let five = windows["five_hour"]?["used_percentage"] { bits.append("5h \(Int(five.rounded()))%") }
    if let week = windows["seven_day"]?["used_percentage"] { bits.append("7d \(Int(week.rounded()))%") }
    return bits.joined(separator: " · ")
}

/// Stores the rate limits for the session. Returns the one-line summary to show, or an empty string.
func record(_ input: Data) -> String {
    guard let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return "" }
    let windows = rateLimitWindows(in: root)
    guard !windows.isEmpty else { return "" }
    let summary = summaryLine(windows)

    let sessionID = (root["session_id"] as? String) ?? "unknown"
    // Keep only characters that are safe in a file name.
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let safeID = String(sessionID.unicodeScalars.filter { allowed.contains($0) })
    guard !safeID.isEmpty else { return summary }

    // The fingerprint changes whenever the session makes an API call, which is what makes the
    // rate-limit numbers newly informative. A status line that merely re-renders keeps the old
    // observation time, so stale numbers are never mistaken for fresh ones.
    let cost = root["cost"] as? [String: Any]
    var parts: [String] = [
        String(number(cost?["total_api_duration_ms"]) ?? -1),
        String(number(cost?["total_cost_usd"]) ?? -1),
    ]
    for kind in windows.keys.sorted() {
        parts.append("\(kind)=\(windows[kind]?["used_percentage"] ?? -1)@\(windows[kind]?["resets_at"] ?? -1)")
    }
    let fingerprint = parts.joined(separator: "|")

    // Tests point the helper at a scratch folder through this variable.
    let directory = ProcessInfo.processInfo.environment["CLAUDE_USAGE_MONITOR_QUOTA_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeUsageMonitor/quota")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let file = directory.appendingPathComponent("statusline-\(safeID).json")

    if let existing = FileManager.default.contents(atPath: file.path),
       let old = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
       old["fingerprint"] as? String == fingerprint {
        // Nothing changed since the last write, so the file is already correct.
        return summary
    }

    let nowMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
    let document: [String: Any] = [
        "schema": 1,
        "sessionId": sessionID,
        "observedAt": nowMs,
        "capturedAt": nowMs,
        "fingerprint": fingerprint,
        "rateLimits": windows,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) {
        let temp = directory.appendingPathComponent(".tmp-\(safeID)-\(getpid())")
        if (try? data.write(to: temp)) != nil {
            chmod(temp.path, 0o600)
            if rename(temp.path, file.path) != 0 { try? FileManager.default.removeItem(at: temp) }
        }
    }
    return summary
}

let arguments = Array(CommandLine.arguments.dropFirst())
var chain: String?
if let i = arguments.firstIndex(of: "--chain"), i + 1 < arguments.count { chain = arguments[i + 1] }

let input = readAllStandardInput()
let summary = record(input)

if let chain, !chain.isEmpty {
    // Run the user's own status line command with the same input, and pass its output through.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", chain]
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.standardError
    do {
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        FileHandle.standardOutput.write(output)
    } catch {
        print(summary)
    }
} else if !summary.isEmpty {
    print(summary)
}
exit(0)
