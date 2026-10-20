import Foundation

/// Quotes and unquotes strings for a POSIX shell using single quotes.
public enum ShellQuote {
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Reverses `quote` for a string that consists of a single quoted word, or returns the input
    /// unchanged if it is not in that form.
    public static func unquote(_ s: String) -> String {
        guard s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 else { return s }
        return String(s.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }
}

/// Splices values into the top level of a JSON document without re-serializing the rest of it, so
/// that the user's formatting, key order and anything else in the file are left exactly as they were.
struct TopLevelJSONEditor {
    struct Member {
        var keyStart: Int
        var valueStart: Int
        var valueEnd: Int
    }

    var bytes: [UInt8]

    init(data: Data) { bytes = Array(data) }

    var text: Data { Data(bytes) }

    /// Locates the top-level members of the document, or returns nil if it is not a JSON object.
    func members() -> (open: Int, members: [(key: String, member: Member)], close: Int)? {
        bytes.withUnsafeBufferPointer { buf -> (Int, [(String, Member)], Int)? in
            var c = JSONCursor(buf)
            c.skipWhitespace()
            let open = c.i
            guard c.consume(0x7B) else { return nil }
            var out: [(String, Member)] = []
            c.skipWhitespace()
            if c.peek == 0x7D { return (open, out, c.i) }
            while true {
                c.skipWhitespace()
                let keyStart = c.i
                guard let key = c.readRawString() else { return nil }
                let name = c.string(key)
                guard c.consume(0x3A) else { return nil }
                c.skipWhitespace()
                let valueStart = c.i
                guard c.skipValue() else { return nil }
                out.append((name, Member(keyStart: keyStart, valueStart: valueStart, valueEnd: c.i)))
                c.skipWhitespace()
                if c.peek == 0x2C { c.i += 1; continue }
                if c.peek == 0x7D { return (open, out, c.i) }
                return nil
            }
        }
    }

    func valueData(forKey key: String) -> Data? {
        guard let m = members()?.members.first(where: { $0.key == key })?.member else { return nil }
        return Data(bytes[m.valueStart..<m.valueEnd])
    }

    mutating func replaceValue(forKey key: String, with json: String) -> Bool {
        guard let m = members()?.members.first(where: { $0.key == key })?.member else { return false }
        bytes.replaceSubrange(m.valueStart..<m.valueEnd, with: Array(json.utf8))
        return true
    }

    mutating func insertMember(key: String, json: String) -> Bool {
        guard let info = members() else { return false }
        let keyJSON = "\"\(key)\""
        let insertion: String
        if info.members.isEmpty {
            insertion = "\n  \(keyJSON): \(json)\n"
            bytes.insert(contentsOf: Array(insertion.utf8), at: info.open + 1)
        } else {
            insertion = "\n  \(keyJSON): \(json),"
            bytes.insert(contentsOf: Array(insertion.utf8), at: info.open + 1)
        }
        return true
    }

    mutating func removeMember(forKey key: String) -> Bool {
        guard let info = members(), let idx = info.members.firstIndex(where: { $0.key == key }) else { return false }
        let m = info.members[idx].member
        var start = m.keyStart
        var end = m.valueEnd
        // Remove a following comma if there is one, otherwise the preceding comma.
        var k = end
        while k < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[k]) { k += 1 }
        if k < bytes.count, bytes[k] == 0x2C {
            end = k + 1
            while end < bytes.count, [0x20, 0x09].contains(bytes[end]) { end += 1 }
            if end < bytes.count, bytes[end] == 0x0A { end += 1 }
            // Also remove the leading indentation of the removed line.
            while start > 0, [0x20, 0x09].contains(bytes[start - 1]) { start -= 1 }
        } else if idx > 0 {
            var p = start
            while p > 0, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[p - 1]) { p -= 1 }
            if p > 0, bytes[p - 1] == 0x2C { start = p - 1 }
        }
        bytes.removeSubrange(start..<end)
        return true
    }
}

/// Installs the status line bridge into Claude Code's user settings.
///
/// Claude Code only reports subscription rate limits to a configured status line command, so the
/// bridge has to be that command. If the user already has a status line, the bridge runs it too and
/// passes its output through, so nothing about their existing setup changes.
public enum StatusLineInstaller {
    public struct Inspection: Equatable, Sendable {
        public var settingsExists = false
        public var settingsIsValidJSON = true
        /// This is the command currently configured as the status line, if any.
        public var command: String?
        public var isInstalled = false
        /// The user's own status line command that the bridge is running on their behalf.
        public var chainedCommand: String?
        public var usesNonCommandStatusLine = false
    }

    public enum InstallError: Error, CustomStringConvertible {
        case settingsNotValidJSON
        case bridgeNotFound
        case writeFailed(String)
        public var description: String {
            switch self {
            case .settingsNotValidJSON: "Claude Code's settings.json is not valid JSON, so it was left untouched."
            case .bridgeNotFound: "The status line helper could not be found next to the app."
            case .writeFailed(let m): "Could not update settings.json: \(m)"
            }
        }
    }

    public static let helperName = "ccu-statusline"

    /// Finds the helper binary shipped inside the app bundle (or next to the running executable during development).
    public static func locateBridge() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let exec = Bundle.main.executableURL { candidates.append(exec.deletingLastPathComponent().appendingPathComponent(helperName)) }
        if let arg0 = CommandLine.arguments.first {
            candidates.append(URL(fileURLWithPath: arg0).deletingLastPathComponent().appendingPathComponent(helperName))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    public static func command(bridgePath: String, chaining original: String?) -> String {
        var cmd = ShellQuote.quote(bridgePath)
        if let original, !original.isEmpty { cmd += " --chain " + ShellQuote.quote(original) }
        return cmd
    }

    public static func inspect(settingsURL: URL = QuotaPaths.claudeSettings) -> Inspection {
        var result = Inspection()
        guard let data = FileManager.default.contents(atPath: settingsURL.path) else { return result }
        result.settingsExists = true
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            result.settingsIsValidJSON = false
            return result
        }
        let editor = TopLevelJSONEditor(data: data)
        guard let valueData = editor.valueData(forKey: "statusLine"),
              let object = try? JSONSerialization.jsonObject(with: valueData) as? [String: Any] else { return result }
        guard object["type"] as? String == "command", let command = object["command"] as? String else {
            result.usesNonCommandStatusLine = true
            return result
        }
        result.command = command
        if command.contains(helperName) {
            result.isInstalled = true
            if let r = command.range(of: " --chain ") {
                result.chainedCommand = ShellQuote.unquote(String(command[r.upperBound...]))
            }
        }
        return result
    }

    /// Adds the bridge as the status line, chaining any existing status line command. Returns the
    /// location of the backup that was made.
    @discardableResult
    public static func install(settingsURL: URL = QuotaPaths.claudeSettings, bridge: URL? = nil) throws -> URL? {
        guard let bridge = bridge ?? locateBridge() else { throw InstallError.bridgeNotFound }
        let fm = FileManager.default
        let existing = fm.contents(atPath: settingsURL.path)
        var statusObject: [String: Any] = ["type": "command"]
        var backup: URL?

        if let existing {
            guard (try? JSONSerialization.jsonObject(with: existing)) is [String: Any] else { throw InstallError.settingsNotValidJSON }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let b = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.usage-monitor-backup-\(stamp)")
            do { try existing.write(to: b); backup = b } catch { throw InstallError.writeFailed("\(error)") }
        }

        var editor = TopLevelJSONEditor(data: existing ?? Data("{\n}\n".utf8))
        var chained: String?
        if let valueData = editor.valueData(forKey: "statusLine"),
           let old = try? JSONSerialization.jsonObject(with: valueData) as? [String: Any] {
            statusObject = old
            if let oldCommand = old["command"] as? String {
                chained = oldCommand.contains(helperName)
                    ? inspect(settingsURL: settingsURL).chainedCommand
                    : oldCommand
            }
        }
        statusObject["type"] = "command"
        statusObject["command"] = command(bridgePath: bridge.path, chaining: chained)
        let valueJSON = try serialize(statusObject)

        let changed = editor.valueData(forKey: "statusLine") != nil
            ? editor.replaceValue(forKey: "statusLine", with: valueJSON)
            : editor.insertMember(key: "statusLine", json: valueJSON)
        guard changed, (try? JSONSerialization.jsonObject(with: editor.text)) is [String: Any] else {
            throw InstallError.writeFailed("the edited document would not be valid JSON")
        }
        do {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try editor.text.write(to: settingsURL, options: .atomic)
        } catch { throw InstallError.writeFailed("\(error)") }
        return backup
    }

    /// Removes the bridge. A status line that the bridge was chaining is restored.
    public static func uninstall(settingsURL: URL = QuotaPaths.claudeSettings) throws {
        guard let data = FileManager.default.contents(atPath: settingsURL.path) else { return }
        let info = inspect(settingsURL: settingsURL)
        guard info.isInstalled else { return }
        var editor = TopLevelJSONEditor(data: data)
        if let chained = info.chainedCommand, let valueData = editor.valueData(forKey: "statusLine"),
           var object = try? JSONSerialization.jsonObject(with: valueData) as? [String: Any] {
            object["command"] = chained
            _ = editor.replaceValue(forKey: "statusLine", with: try serialize(object))
        } else {
            _ = editor.removeMember(forKey: "statusLine")
        }
        guard (try? JSONSerialization.jsonObject(with: editor.text)) is [String: Any] else {
            throw InstallError.writeFailed("the edited document would not be valid JSON")
        }
        try editor.text.write(to: settingsURL, options: .atomic)
    }

    private static func serialize(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
