import Foundation
import XCTest
@testable import UsageCore

final class ClaudeQuotaConnectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_650_000)

    private func pool(_ windows: [QuotaWindowState]) -> QuotaPoolState {
        let key = QuotaPoolKey(provider: .anthropic, accountID: 1, poolKey: ClaudeQuota.poolKey)
        return QuotaPoolState(pool: QuotaPoolInfo(key: key, accountLabel: "Unassigned", name: "Claude subscription"),
                              windows: windows)
    }

    private func window(_ key: String, _ minutes: Int?, _ reading: QuotaReading?, freshness: QuotaFreshness = .fresh) -> QuotaWindowState {
        let info = QuotaPoolInfo(key: QuotaPoolKey(provider: .anthropic, accountID: 1, poolKey: ClaudeQuota.poolKey),
                                 accountLabel: "Unassigned", name: "Claude subscription")
        return QuotaWindowState(pool: info, windowKey: key, windowMinutes: minutes, reading: reading,
                                availability: reading == nil ? .unavailable(.noData) : .available, freshness: reading == nil ? nil : freshness,
                                evaluatedAt: now)
    }

    private func reading(_ percent: Double, source: TelemetrySourceID, age: TimeInterval) -> QuotaReading {
        QuotaReading(utilizationPercent: percent, resetsAt: now.addingTimeInterval(3_600),
                     observedAt: now.addingTimeInterval(-age), source: source, authority: .authoritative)
    }

    private func feed(_ id: TelemetrySourceID, issue: QuotaFeedIssue? = nil) -> QuotaFeedStatus {
        QuotaFeedStatus(id: id, rootsExist: true, observationCount: 1, originCount: 0, newestObservation: now,
                        lastRead: now, lastSuccess: issue == nil ? now : nil, sourceExists: true,
                        sourcePath: "/tmp/cache", issue: issue)
    }

    func testNoReadingIsNoDataAndNeverAnInferredPercentage() {
        XCTAssertEqual(ClaudeQuotaConnection.evaluate(pools: [pool([window("300m", 300, nil)])], feeds: []), .noData)
    }

    func testAFeedErrorIsReportedWhenNoReadingIsAvailable() {
        XCTAssertEqual(ClaudeQuotaConnection.evaluate(pools: [], feeds: [feed(.claudeCodeCache, issue: .invalidJSON)]),
                       .collectionError(.invalidJSON))
    }

    func testAFreshCacheReadingIsNamed() {
        let r = reading(42, source: .claudeCodeCache, age: 20 * 60)
        XCTAssertEqual(ClaudeQuotaConnection.evaluate(pools: [pool([window("300m", 300, r)])], feeds: [feed(.claudeCodeCache)]),
                       .localCache(observedAt: r.observedAt, freshness: .fresh))
    }

    func testAnOldReadingIsStaleInsteadOfBeingPresentedAsCurrent() {
        let old = reading(99, source: .claudeCodeCache, age: 4 * 3_600)
        XCTAssertEqual(ClaudeQuotaConnection.evaluate(pools: [pool([window("10080m", 10080, old, freshness: .stale)])],
                                                      feeds: [feed(.claudeCodeCache)]),
                       .stale(source: .claudeCodeCache, observedAt: old.observedAt))
    }

    func testAQuotaWindowWhoseResetPassedIsNotTreatedAsZero() {
        let r = QuotaReading(utilizationPercent: 99, resetsAt: now.addingTimeInterval(-60),
                             observedAt: now.addingTimeInterval(-120), source: .claudeCodeCache, authority: .authoritative)
        let info = QuotaPoolInfo(key: QuotaPoolKey(provider: .anthropic, accountID: 1, poolKey: ClaudeQuota.poolKey),
                                 accountLabel: "Unassigned", name: "Claude subscription")
        let w = QuotaWindowState(pool: info, windowKey: "10080m", windowMinutes: 10080, reading: r,
                                 availability: .windowElapsed(resetAt: now.addingTimeInterval(-60)),
                                 freshness: .fresh, evaluatedAt: now)
        XCTAssertEqual(ClaudeQuotaConnection.evaluate(pools: [QuotaPoolState(pool: info, windows: [w])], feeds: []),
                       .localCache(observedAt: r.observedAt, freshness: .fresh))
    }

    func testAnUnverifiedDesktopHintIsNotReportedAsTheLocalCache() {
        let hint = QuotaReading(utilizationPercent: 42, resetsAt: nil, observedAt: now,
                                source: .claudeDesktopCache, authority: .unverified)
        XCTAssertEqual(ClaudeQuotaConnection.evaluate(pools: [pool([window("10080m", 10080, hint)])],
                                                      feeds: [feed(.claudeDesktopCache)]),
                       .noData)
    }

    func testAScopedWindowDoesNotDecideWhichSourceTheWholeSubscriptionUses() {
        let shared = reading(50, source: .claudeCodeCache, age: 20 * 60)
        let scoped = QuotaReading(utilizationPercent: 10, resetsAt: now.addingTimeInterval(3_600),
                                  observedAt: now.addingTimeInterval(-60), source: .claudeCodeCache, authority: .authoritative)
        let scopedKey = WindowNaming.scopedKey(minutes: 10080, identity: "name:fable", label: "Fable")
        XCTAssertEqual(ClaudeQuotaConnection.evaluate(pools: [pool([window("10080m", 10080, shared),
                                                                    window(scopedKey, 10080, scoped)])],
                                                      feeds: [feed(.claudeCodeCache)]),
                       .localCache(observedAt: shared.observedAt, freshness: .fresh))
    }

    func testModelScopedWindowsHaveTheirOwnKeyNameAndDuration() {
        let alpha = WindowNaming.scopedKey(minutes: 10080, identity: "name:alpha", label: "Alpha")
        let alphaByID = WindowNaming.scopedKey(minutes: 10080, identity: "id:model-alpha", label: "Alpha")
        XCTAssertNotEqual(alpha, alphaByID)
        XCTAssertEqual(WindowNaming.scopedLabel(fallbackKey: alpha), "Alpha")
        XCTAssertEqual(WindowNaming.displayName(minutes: 10080, fallbackKey: alpha), "Alpha weekly")
        XCTAssertEqual(WindowNaming.shortName(minutes: 10080, fallbackKey: alpha), "Alpha")
        XCTAssertFalse(WindowNaming.isShort(minutes: 10080))
        XCTAssertNil(WindowNaming.scopedLabel(fallbackKey: "10080m"))
    }
}
