import Foundation
import XCTest
@testable import UsageCore

/// The Claude Code local cache is not a documented interface. These tests pin down the exact shapes observed in a real
/// installation, the malformed shapes that must be rejected, and the privacy and freshness guarantees around them.
final class ClaudeCodeCacheTests: XCTestCase {
    private let account = "A1B2C3D4-E5F6-4789-8ABC-DEF012345678"
    private let weeklyReset = "2026-10-23T00:00:00.119287+00:00"
    private let scopedReset = "2026-10-29T00:00:00.000000+00:00"
    private let now = Date(timeIntervalSince1970: 1_792_650_000)

    private var fetchedMs: Int64 { Clock.ms(now.addingTimeInterval(-10 * 60)) }

    private func document(account: String? = nil,
                          fetchedAtMs: Int64? = nil,
                          utilization: String) -> Data {
        var fields = ["\"utilization\":\(utilization)"]
        if let account { fields.append("\"accountUuid\":\"\(account)\"") }
        if let fetchedAtMs { fields.append("\"fetchedAtMs\":\(fetchedAtMs)") }
        let json = "{\"numStartups\":12,\"projects\":{\"secret\":\"not for the parser\"},\"cachedUsageUtilization\":{\(fields.joined(separator: ","))},\"oauthAccount\":{\"token\":\"not for the parser\"}}"
        return Data(json.utf8)
    }

    private func parse(_ data: Data, now: Date? = nil) -> ClaudeCodeCacheReading {
        ClaudeCodeCacheSource.parse(data, now: now ?? self.now)
    }

    private func iso(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value)
    }

    private var realShape: Data {
        let utilization = """
        {
          "five_hour": {"utilization": 0, "resets_at": null, "limit_dollars": null},
          "seven_day": {"utilization": 99, "resets_at": "\(weeklyReset)", "limit_dollars": null},
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "limits": [
            {"kind":"session","group":"session","percent":0,"severity":"normal","resets_at":null,"scope":null,"is_active":false},
            {"kind":"weekly_all","group":"weekly","percent":99,"severity":"critical","resets_at":"\(weeklyReset)","scope":null,"is_active":false},
            {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"\(scopedReset)","scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":false}
          ],
          "weekly_scoped_shares": {"fable": 0},
          "extra_usage": 0,
          "member_dashboard_available": true
        }
        """
        return document(account: account, fetchedAtMs: fetchedMs, utilization: utilization)
    }

    func testTheRealCacheShapeProducesSharedAndNamedScopedWindows() throws {
        let reading = parse(realShape)
        XCTAssertNil(reading.issue)
        XCTAssertEqual(reading.sourceExists, true)
        XCTAssertEqual(reading.skippedWindowCount, 0)
        XCTAssertEqual(reading.observations.count, 3)
        XCTAssertNotNil(reading.accountFingerprint)
        XCTAssertEqual(reading.accountFingerprint?.count, 16)
        XCTAssertEqual(reading.fetchedAt, Clock.date(ms: fetchedMs))

        let byKey = Dictionary(uniqueKeysWithValues: reading.observations.map { ($0.windowKey, $0) })
        let five = try XCTUnwrap(byKey["300m"])
        XCTAssertEqual(five.utilizationPercent, 0)
        XCTAssertNil(five.resetsAt)
        XCTAssertEqual(five.windowMinutes, 300)
        XCTAssertEqual(five.source, .claudeCodeCache)
        XCTAssertEqual(five.authority, .authoritative)
        XCTAssertEqual(five.observedAt, Clock.date(ms: fetchedMs))

        let week = try XCTUnwrap(byKey["10080m"])
        XCTAssertEqual(week.utilizationPercent, 99)
        XCTAssertEqual(week.resetsAt, iso(weeklyReset))
        XCTAssertEqual(week.source, .claudeCodeCache)

        let scoped = try XCTUnwrap(reading.observations.first {
            WindowNaming.scopedLabel(fallbackKey: $0.windowKey) == "Fable"
        })
        XCTAssertEqual(scoped.windowMinutes, 10080)
        XCTAssertEqual(scoped.utilizationPercent, 0)
        XCTAssertEqual(scoped.resetsAt, iso(scopedReset))
        XCTAssertNotEqual(scoped.windowKey, week.windowKey)
        XCTAssertEqual(scoped.observedAt, week.observedAt, "all windows share the snapshot's fetch time")
    }

    func testStructuredLimitsFillWindowsWhenTheLegacyFieldsAreAbsent() throws {
        let utilization = """
        {"limits":[
          {"kind":"session","percent":12,"resets_at":"\(weeklyReset)"},
          {"kind":"weekly_all","percent":34,"resets_at":"\(weeklyReset)"},
          {"kind":"weekly_scoped","percent":56,"resets_at":"\(scopedReset)","scope":{"model":{"id":"model-123","display_name":"Model 123"}}}
        ]}
        """
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertNil(reading.issue)
        XCTAssertEqual(reading.observations.count, 3)
        let byKey = Dictionary(uniqueKeysWithValues: reading.observations.map { ($0.windowKey, $0) })
        XCTAssertEqual(byKey["300m"]?.utilizationPercent, 12)
        XCTAssertEqual(byKey["10080m"]?.utilizationPercent, 34)
        XCTAssertEqual(WindowNaming.scopedLabel(fallbackKey: reading.observations[2].windowKey), "Model 123")
    }

    func testLegacyModelWindowsAreAcceptedOnlyWhenStructuredOnesDoNotDescribeThem() throws {
        let utilization = """
        {
          "five_hour": {"utilization": 5, "resets_at": null},
          "seven_day": {"utilization": 50, "resets_at": "\(weeklyReset)"},
          "seven_day_opus": {"utilization": 10, "resets_at": "\(weeklyReset)"},
          "seven_day_sonnet": {"utilization": 20, "resets_at": "\(weeklyReset)"},
          "limits": [
            {"kind":"weekly_scoped","percent":0,"resets_at":"\(scopedReset)","scope":{"model":{"id":null,"display_name":"Fable"}}}
          ]
        }
        """
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertNil(reading.issue)
        let labels = reading.observations.compactMap { WindowNaming.scopedLabel(fallbackKey: $0.windowKey) }.sorted()
        XCTAssertEqual(labels, ["Fable", "Opus", "Sonnet"])
        XCTAssertEqual(Set(reading.observations.map(\.windowKey)).count, reading.observations.count)
    }

    func testALegacyFieldDoesNotDuplicateAStructuredWindowWithTheSameModelName() throws {
        let utilization = """
        {
          "five_hour": {"utilization": 5, "resets_at": null},
          "seven_day": {"utilization": 50, "resets_at": "\(weeklyReset)"},
          "seven_day_opus": {"utilization": 10, "resets_at": "\(weeklyReset)"},
          "limits": [
            {"kind":"weekly_scoped","percent":30,"resets_at":"\(scopedReset)","scope":{"model":{"id":"claude-opus-4","display_name":"Opus"}}}
          ]
        }
        """
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertNil(reading.issue)
        let opus = reading.observations.filter { WindowNaming.scopedLabel(fallbackKey: $0.windowKey) == "Opus" }
        XCTAssertEqual(opus.count, 1)
        XCTAssertEqual(opus.first?.utilizationPercent, 30)
    }

    func testTwoModelScopesWithTheSameDurationStayDistinct() throws {
        let utilization = """
        {"limits":[
          {"kind":"weekly_all","percent":40,"resets_at":"\(weeklyReset)"},
          {"kind":"weekly_scoped","percent":10,"resets_at":"\(weeklyReset)","scope":{"model":{"id":null,"display_name":"Alpha"}}},
          {"kind":"weekly_scoped","percent":20,"resets_at":"\(weeklyReset)","scope":{"model":{"id":null,"display_name":"Beta"}}}
        ]}
        """
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertNil(reading.issue)
        let scoped = reading.observations.filter { $0.windowKey.hasPrefix("scoped:") }
        XCTAssertEqual(scoped.count, 2)
        XCTAssertEqual(Set(scoped.map(\.windowKey)).count, 2)
        XCTAssertEqual(scoped.map { WindowNaming.scopedLabel(fallbackKey: $0.windowKey) }.compactMap { $0 }.sorted(),
                       ["Alpha", "Beta"])
        XCTAssertTrue(scoped.allSatisfy { $0.windowMinutes == 10080 })
    }

    func testAMalformedWindowDoesNotDiscardTheOthers() throws {
        let utilization = """
        {
          "five_hour": {"utilization": 101, "resets_at": null},
          "seven_day": {"utilization": 50, "resets_at": "\(weeklyReset)"}
        }
        """
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertEqual(reading.issue, .malformedWindow)
        XCTAssertEqual(reading.observations.count, 1)
        XCTAssertEqual(reading.observations.first?.windowKey, "10080m")
        XCTAssertEqual(reading.skippedWindowCount, 1)
    }

    func testADuplicateWindowNameKeepsTheFirstAndReportsTheSkip() throws {
        let utilization = """
        {
          "five_hour": {"utilization": 5, "resets_at": null},
          "five_hour": {"utilization": 6, "resets_at": null},
          "seven_day": {"utilization": 50, "resets_at": "\(weeklyReset)"}
        }
        """
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertEqual(reading.issue, .malformedWindow)
        XCTAssertEqual(reading.skippedWindowCount, 1)
        let byKey = Dictionary(uniqueKeysWithValues: reading.observations.map { ($0.windowKey, $0) })
        XCTAssertEqual(byKey["300m"]?.utilizationPercent, 5)
        XCTAssertEqual(byKey["10080m"]?.utilizationPercent, 50)
    }

    func testAWindowWithoutAPercentageFallsBackToTheStructuredLimitInTheSameSnapshot() throws {
        let utilization = """
        {
          "five_hour": {"resets_at": null},
          "limits": [{"kind":"session","percent":12,"resets_at":null}]
        }
        """
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertNil(reading.issue)
        XCTAssertEqual(reading.observations.count, 1)
        XCTAssertEqual(reading.observations.first?.windowKey, "300m")
        XCTAssertEqual(reading.observations.first?.utilizationPercent, 12)
    }

    func testAModelIdentifierCanNameAScopedWindowWhenTheDisplayNameIsMissing() throws {
        let utilization = """
        {"limits":[{"kind":"weekly_scoped","percent":7,"resets_at":"\(scopedReset)",
          "scope":{"model":{"id":"claude-fable-1","display_name":null}}}]}
        """
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertNil(reading.issue)
        let scoped = try XCTUnwrap(reading.observations.first)
        XCTAssertEqual(WindowNaming.scopedLabel(fallbackKey: scoped.windowKey), "claude-fable-1")
        XCTAssertEqual(scoped.utilizationPercent, 7)
    }

    func testAnInvalidResetDropsThatWindowRatherThanInventingOne() throws {
        let utilization = """
        {
          "five_hour": {"utilization": 5, "resets_at": "not a timestamp"},
          "seven_day": {"utilization": 50, "resets_at": "\(weeklyReset)"}
        }
        """
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertEqual(reading.issue, .malformedWindow)
        XCTAssertEqual(reading.observations.map(\.windowKey), ["10080m"])
        XCTAssertEqual(reading.skippedWindowCount, 1)
    }

    func testUnknownLimitKindsAreIgnoredNotTreatedAsQuota() throws {
        let utilization = """
        {"limits":[
          {"kind":"some_future_limit","percent":88,"resets_at":"\(weeklyReset)"}
        ]}
        """
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertEqual(reading.issue, .noUsageData)
        XCTAssertTrue(reading.observations.isEmpty)
    }

    func testNoUsageObjectMeansNoData() {
        XCTAssertEqual(parse(Data("{}".utf8)).issue, .noUsageData)
        XCTAssertEqual(parse(document(account: account, fetchedAtMs: fetchedMs, utilization: "null")).issue, .noUsageData)
        XCTAssertEqual(parse(Data("{\"cachedUsageUtilization\":null}".utf8)).issue, .noUsageData)
    }

    func testTruncatedOrAmbiguousJSONIsRejected() {
        let valid = String(data: realShape, encoding: .utf8)!
        XCTAssertEqual(parse(Data(valid.dropLast(20).utf8)).issue, .invalidJSON)
        XCTAssertEqual(parse(Data("{\"cachedUsageUtilization\":{},\"cachedUsageUtilization\":{}}".utf8)).issue, .invalidJSON)
        XCTAssertEqual(parse(Data("[]".utf8)).issue, .invalidJSON)
    }

    func testTimestampsMustBePlausibleAndComeFromTheSnapshot() {
        let utilization = "{\"five_hour\":{\"utilization\":5,\"resets_at\":null}}"
        XCTAssertEqual(parse(document(account: account, fetchedAtMs: nil, utilization: utilization)).issue, .invalidTimestamp)
        XCTAssertEqual(parse(document(account: account, fetchedAtMs: 0, utilization: utilization)).issue, .invalidTimestamp)
        XCTAssertEqual(parse(document(account: account, fetchedAtMs: 1_500_000_000_000, utilization: utilization)).issue, .invalidTimestamp)
        XCTAssertEqual(parse(document(account: account, fetchedAtMs: Clock.ms(now) + 6 * 60_000, utilization: utilization)).issue,
                       .invalidTimestamp)
    }

    func testTheFileTimestampIsNeverUsedAsTheObservationTime() throws {
        let oldFetch = Clock.ms(now.addingTimeInterval(-3 * 3_600))
        let utilization = "{\"five_hour\":{\"utilization\":5,\"resets_at\":null}}"
        let reading = parse(document(account: account, fetchedAtMs: oldFetch, utilization: utilization))
        XCTAssertEqual(reading.fetchedAt, Clock.date(ms: oldFetch))
        XCTAssertEqual(reading.observations.first?.observedAt, Clock.date(ms: oldFetch))
        XCTAssertEqual(reading.observations.first?.observedAt.timeIntervalSince(now), -3 * 3_600)
    }

    func testAnInvalidOrMissingAccountIsNotGuessed() {
        let utilization = "{\"five_hour\":{\"utilization\":5,\"resets_at\":null}}"
        XCTAssertEqual(parse(document(account: nil, fetchedAtMs: fetchedMs, utilization: utilization)).issue, .invalidAccount)
        XCTAssertEqual(parse(document(account: "not-a-uuid", fetchedAtMs: fetchedMs, utilization: utilization)).issue, .invalidAccount)
    }

    func testTheRawAccountIdentifierIsNeverExposedAndCacheReadingsCarryItsReference() throws {
        let reading = parse(realShape)
        let dump = String(describing: reading)
        XCTAssertFalse(dump.contains(account))
        XCTAssertFalse(dump.contains(account.lowercased()))
        let fingerprint = try XCTUnwrap(reading.accountFingerprint)
        XCTAssertNotEqual(fingerprint, account)
        for observation in reading.observations {
            XCTAssertFalse(String(describing: observation).contains(account))
            XCTAssertFalse(observation.account.isUnassigned,
                           "the cache names its account, so its readings must not share the status line's unassigned pool")
            XCTAssertEqual(observation.account.hash, fingerprint)
            XCTAssertEqual(observation.account.provider, .anthropic)
        }
    }

    func testTheCacheAccountReferenceIsStableAndCaseInsensitive() throws {
        let expected = ClaudeCodeCacheSource.accountFingerprint(account)
        XCTAssertEqual(expected, ClaudeCodeCacheSource.accountFingerprint(account.lowercased()))
        XCTAssertNotEqual(expected, ClaudeCodeCacheSource.accountFingerprint("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        XCTAssertNil(ClaudeCodeCacheSource.accountFingerprint("not-a-uuid"))
        XCTAssertEqual(parse(realShape).observations.first?.account.hash, expected)
    }

    func testASnapshotWithoutAnyUsableWindowReportsNoUsage() {
        let utilization = "{\"five_hour\":null,\"seven_day\":null,\"seven_day_opus\":null}"
        let reading = parse(document(account: account, fetchedAtMs: fetchedMs, utilization: utilization))
        XCTAssertEqual(reading.issue, .noUsageData)
        XCTAssertTrue(reading.observations.isEmpty)
    }

    func testParsingATypicalSnapshotIsCheapEnoughForFileEvents() {
        let data = realShape
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<500 {
            _ = parse(data)
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        // This is a generous ceiling for a CI machine, not a benchmark target. A refresh happens on file events and
        // at most once a minute, so even a few milliseconds are negligible.
        XCTAssertLessThan(milliseconds, 5_000, "500 parses took \(milliseconds) ms")
    }

    // MARK: Safe file access

    private func temporaryFile(_ data: Data, name: String = "claude.json") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    func testAReadOnlyRegularFileOwnedByTheUserIsRead() throws {
        let url = try temporaryFile(realShape)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let reading = ClaudeCodeCacheSource.read(at: url, now: now)
        XCTAssertTrue(reading.sourceExists)
        XCTAssertNil(reading.issue)
        XCTAssertEqual(reading.observations.count, 3)
    }

    func testMissingFileIsAbsentRatherThanAnError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-cache-\(UUID().uuidString)")
        let reading = ClaudeCodeCacheSource.read(at: dir.appendingPathComponent("missing.json"), now: now)
        XCTAssertFalse(reading.sourceExists)
        XCTAssertNil(reading.issue)
        XCTAssertTrue(reading.observations.isEmpty)
    }

    func testAFileThatOtherUsersCanReadOrWriteIsRejected() throws {
        let url = try temporaryFile(realShape)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let reading = ClaudeCodeCacheSource.read(at: url, now: now)
        XCTAssertEqual(reading.issue, .unreadable)
        XCTAssertTrue(reading.observations.isEmpty)
    }

    func testAHardLinkIsRejected() throws {
        let target = try temporaryFile(realShape)
        let hard = target.deletingLastPathComponent().appendingPathComponent("hard.json")
        XCTAssertEqual(Darwin.link(target.path, hard.path), 0)
        let reading = ClaudeCodeCacheSource.read(at: hard, now: now)
        XCTAssertEqual(reading.issue, .unreadable)
    }

    func testASymbolicLinkIsNotFollowed() throws {
        let target = try temporaryFile(realShape)
        let link = target.deletingLastPathComponent().appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let reading = ClaudeCodeCacheSource.read(at: link, now: now)
        XCTAssertTrue(reading.sourceExists)
        XCTAssertEqual(reading.issue, .unreadable)
        XCTAssertTrue(reading.observations.isEmpty)
    }

    func testAnUnreadableFileIsRejected() throws {
        let url = try temporaryFile(realShape)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let reading = ClaudeCodeCacheSource.read(at: url, now: now)
        XCTAssertEqual(reading.issue, .unreadable)
        XCTAssertTrue(reading.observations.isEmpty)
    }

    func testADirectoryIsNotAFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let reading = ClaudeCodeCacheSource.read(at: dir, now: now)
        XCTAssertEqual(reading.issue, .unreadable)
    }

    func testAFIFOIsRejectedWithoutBlockingTheReader() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("cache.json")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        let reading = ClaudeCodeCacheSource.read(at: fifo, now: now)
        XCTAssertTrue(reading.sourceExists)
        XCTAssertEqual(reading.issue, .unreadable)
        XCTAssertTrue(reading.observations.isEmpty)
    }

    func testAnOversizedFileIsRejectedBeforeItIsRead() throws {
        let url = try temporaryFile(Data("{}".utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ClaudeCodeCacheSource.maximumBytes + 1))
        try handle.close()
        let reading = ClaudeCodeCacheSource.read(at: url, now: now)
        XCTAssertEqual(reading.issue, .fileTooLarge)
        XCTAssertTrue(reading.observations.isEmpty)
    }

    func testTheParserDoesNotReadUnrelatedValues() throws {
        // The document deliberately contains values that would be invalid JSON if the parser tried to materialize them
        // as strings, but they are inside skipped containers. Only the usage object may be decoded.
        let json = """
        {"projects":{"a":{"history":[{"text":"unterminated? no, this is valid but irrelevant"}]}},
         "cachedUsageUtilization":{"accountUuid":"\(account)","fetchedAtMs":\(fetchedMs),
         "utilization":{"five_hour":{"utilization":5,"resets_at":null}}}}
        """
        let reading = parse(Data(json.utf8))
        XCTAssertNil(reading.issue)
        XCTAssertEqual(reading.observations.count, 1)
    }

    // MARK: Real installation, read-only

    /// Set `TOKENWATCH_REAL_CLAUDE_CACHE` to run a read-only check against the actual file. Nothing is printed from the
    /// file, and the test verifies that its bytes and modification time did not change.
    func testTheDefaultPathHonorsAnAbsoluteClaudeConfigDirAndIgnoresARelativeOne() {
        func value(_ name: String) -> String? {
            guard let raw = getenv(name) else { return nil }
            return String(cString: raw)
        }
        let oldConfig = value("CLAUDE_CONFIG_DIR")
        let oldOverride = value("TOKENWATCH_CLAUDE_CACHE")
        func restore(_ name: String, _ old: String?) {
            if let old { setenv(name, old, 1) } else { unsetenv(name) }
        }
        defer {
            restore("CLAUDE_CONFIG_DIR", oldConfig)
            restore("TOKENWATCH_CLAUDE_CACHE", oldOverride)
        }
        unsetenv("TOKENWATCH_CLAUDE_CACHE")
        setenv("CLAUDE_CONFIG_DIR", "/tmp/tokenwatch-config-dir", 1)
        XCTAssertEqual(QuotaPaths.claudeCodeCache.path, "/tmp/tokenwatch-config-dir/.claude.json")
        setenv("CLAUDE_CONFIG_DIR", "relative/config", 1)
        XCTAssertEqual(QuotaPaths.claudeCodeCache.deletingLastPathComponent().standardizedFileURL,
                       FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
                       "a relative CLAUDE_CONFIG_DIR is not a usable Claude Code config path")
    }

    func testTheRealInstallationCanBeReadWithoutModifyingIt() throws {
        guard let path = ProcessInfo.processInfo.environment["TOKENWATCH_REAL_CLAUDE_CACHE"], !path.isEmpty else {
            throw XCTSkip("set TOKENWATCH_REAL_CLAUDE_CACHE to validate the real installation read-only")
        }
        let url = URL(fileURLWithPath: path)
        let before = try Data(contentsOf: url)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: url.path)
        let reading = ClaudeCodeCacheSource.read(at: url, now: Date())
        let after = try Data(contentsOf: url)
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(before, after)
        XCTAssertEqual(attributesBefore[.modificationDate] as? Date, attributesAfter[.modificationDate] as? Date)
        XCTAssertTrue(reading.sourceExists)
        if reading.issue == .noUsageData || reading.issue == .invalidAccount {
            throw XCTSkip("this installation has no subscription usage snapshot: \(reading.issue!)")
        }
        XCTAssertNil(reading.issue)
        XCTAssertNotNil(reading.fetchedAt)
        XCTAssertFalse(reading.observations.isEmpty)
        XCTAssertTrue(reading.observations.allSatisfy { $0.source == .claudeCodeCache && $0.authority == .authoritative })
        XCTAssertTrue(reading.observations.allSatisfy { !String(describing: $0).contains("accountUuid") })
    }
}
