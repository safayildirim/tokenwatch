import XCTest
import SwiftUI
import AppKit
@testable import UsageCore
@testable import UsageUI

/// Draws the usage intelligence page offscreen for the situations a person can meet, and checks that the main thread stays free
/// while the analysis runs.
@MainActor
final class IntelligenceRenderTests: XCTestCase {
    private let week: TimeInterval = 7 * 86_400

    private enum Account {
        case unassigned, identified, other
        var ref: AccountRef {
            switch self {
            case .unassigned: .unassigned(.anthropic)
            case .identified: .identified(provider: .anthropic, rawIdentifier: "11111111-2222-3333-4444-555555555555")
            case .other: .identified(provider: .anthropic, rawIdentifier: "99999999-2222-3333-4444-555555555555")
            }
        }
    }

    /// Weekly cycles on a schedule aligned to the Unix epoch's weeks, with a reading every six hours and a request after each.
    private func seed(_ env: UIEnv, now: Date, pastCycles: Int = 8, currentFraction: Double? = nil, account: Account = .identified,
                      sessionsAccount: Account = .identified, requestsPerReading: Int = 1, stale: Bool = false) throws {
        let currentStart = floor(now.timeIntervalSince1970 / week) * week
        var batch = NormalizedBatch()
        let first = Clock.ms(Date(timeIntervalSince1970: currentStart - Double(pastCycles + 1) * week))
        batch.add(SessionObservation(product: .claudeCode, source: .claudeTranscripts, externalID: "S", projectKey: "claude-folder:-alpha", surface: nil,
                                     account: sessionsAccount.ref, firstSeenMs: first, lastSeenMs: first))
        for index in (-pastCycles)...0 {
            let start = currentStart + Double(index) * week
            let fraction = index == 0 ? (currentFraction ?? min(1, (now.timeIntervalSince1970 - start) / week)) : 1
            var reading = min(start + week * fraction, now.timeIntervalSince1970) - 3600
            if stale && index == 0 { reading -= 20 * 3600 }
            var time = start + 3600
            while time < reading {
                let percent = (Double(40 + (index + pastCycles) * 4) * (time - start) / week).rounded()
                try env.db.write { c in
                    try QuotaStore.record(QuotaObservation(provider: .anthropic, account: account.ref, poolKey: "claude-subscription",
                                                           windowKey: "10080m", windowMinutes: 10_080, utilizationPercent: percent,
                                                           resetsAt: Date(timeIntervalSince1970: start + week), observedAt: Date(timeIntervalSince1970: time),
                                                           source: .claudeCodeCache), originSessionID: nil,
                                          resolver: EntityResolver(c, registry: env.db.registry))
                }
                for k in 0..<requestsPerReading {
                    batch.add(RequestObservation(
                        product: .claudeCode, source: .claudeTranscripts, requestKey: "r-\(index)-\(Int(time))-\(k)", sessionExternalID: "S",
                        model: (index + k) % 3 == 0 ? "claude-sonnet-5-5" : "claude-opus-5-5",
                        requestedAtMs: Clock.ms(Date(timeIntervalSince1970: time + 1800 + Double(k))),
                        usage: UsageNormalizer.anthropic(inputTokens: 20_000, outputTokens: 8_000, cacheRead: 1_500_000, cacheCreation: 60_000,
                                                         cacheCreation5m: nil, cacheCreation1h: nil, thinkingTokens: nil)))
                }
                time += 6 * 3600
            }
        }
        _ = try IngestWriter.apply(batch: batch, checkpoint: nil, retentionFloorMs: nil, db: env.db)
    }

    private func render<V: View>(_ view: V, size: CGSize, wait: Double, scheme: NSAppearance.Name) async -> NSBitmapImageRep? {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -5000, y: -5000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme)
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(wait))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil
        return rep
    }

    private func inkRatio(_ rep: NSBitmapImageRep) -> Double {
        guard let data = rep.bitmapData else { return 0 }
        let bytes = rep.bitsPerPixel / 8
        var different = 0
        let total = rep.pixelsWide * rep.pixelsHigh
        for i in stride(from: 0, to: total, by: 7) {
            let p = data + i * bytes
            if p[0] != data[0] || p[1] != data[1] || p[2] != data[2] { different += 1 }
        }
        return Double(different) / Double(max(1, total / 7))
    }

    private func capture(_ name: String, env: UIEnv, width: CGFloat = 1100, height: CGFloat = 2600, scheme: NSAppearance.Name = .aqua,
                         minimumInk: Double = 0.02, wait: Double = 3.5) async throws {
        env.model.selection = .intelligence
        let page = IntelligencePage().environment(env.model).frame(width: width)
        let drawn = await render(page, size: CGSize(width: width, height: height), wait: wait, scheme: scheme)
        let rep = try XCTUnwrap(drawn)
        if let directory = ProcessInfo.processInfo.environment["TOKENWATCH_RENDER_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            let suffix = scheme == .aqua ? "light" : "dark"
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("intelligence-\(name)-\(Int(width))-\(suffix).png"))
        }
        XCTAssertGreaterThan(inkRatio(rep), minimumInk, "\(name) rendered blank")
    }

    func testTheEstablishedHistoryRendersInLightAndDarkAndAtNarrowWidths() async throws {
        let env = try UIEnv()
        try seed(env, now: Date())
        await env.model.start()
        try await capture("history", env: env, scheme: .aqua)
        try await capture("history", env: env, scheme: .darkAqua)
        try await capture("history", env: env, width: 760, height: 3200, scheme: .aqua)
        await env.cleanup()
    }

    func testAnEmptyDatabaseExplainsWhatIsNeeded() async throws {
        let env = try UIEnv()
        await env.model.start()
        try await capture("empty", env: env, height: 700, minimumInk: 0.005, wait: 1.5)
        await env.cleanup()
    }

    func testPartialHistoryWithOneCycleAndStaleReadings() async throws {
        let env = try UIEnv()
        try seed(env, now: Date(), pastCycles: 0, currentFraction: 0.4, stale: true)
        await env.model.start()
        try await capture("partial-stale", env: env, height: 2400)
        await env.cleanup()
    }

    func testSessionsThatNameNoAccountOfferAnAssociationAndExplainWhyNoRatioIsShown() async throws {
        let env = try UIEnv()
        try seed(env, now: Date(), pastCycles: 4, account: .identified, sessionsAccount: .unassigned)
        await env.model.start()
        try await capture("unattributed", env: env)
        await env.cleanup()
    }

    func testTwoAccountsAreOfferedSeparatelyAndTheUnassignedOneKeepsItsOwnHistory() async throws {
        let env = try UIEnv()
        try seed(env, now: Date(), pastCycles: 3, account: .unassigned, sessionsAccount: .unassigned)
        try env.db.write { c in
            try QuotaStore.record(QuotaObservation(provider: .anthropic, account: Account.other.ref, poolKey: "claude-subscription", windowKey: "10080m",
                                                   windowMinutes: 10_080, utilizationPercent: 30, resetsAt: Date().addingTimeInterval(3 * 86_400),
                                                   observedAt: Date().addingTimeInterval(-3600), source: .claudeCodeCache), originSessionID: nil,
                                  resolver: EntityResolver(c, registry: env.db.registry))
        }
        await env.model.start()
        try await capture("two-accounts", env: env)
        await env.cleanup()
    }

    func testTheMainThreadStaysFreeWhileALargeHistoryIsAnalyzed() async throws {
        let env = try UIEnv()
        try seed(env, now: Date(), pastCycles: 20, requestsPerReading: 12)
        await env.model.start()
        env.model.selection = .intelligence

        var longest: TimeInterval = 0
        var last = Date()
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let now = Date()
            longest = max(longest, now.timeIntervalSince(last))
            last = now
        }
        let page = IntelligencePage().environment(env.model).frame(width: 1100)
        let rep = await render(page, size: CGSize(width: 1100, height: 2600), wait: 4, scheme: .aqua)
        heartbeat.invalidate()
        XCTAssertNotNil(rep)
        let requests = try env.db.read { try $0.scalarInt("SELECT count(*) FROM model_request") ?? 0 }
        // The same analysis, timed on its own, shows how much of the gap the query can account for.
        let subject = try XCTUnwrap(SubscriptionUsageAnalyticsEngine.subjects(env.db).first)
        let started = Date()
        _ = try SubscriptionUsageAnalyticsEngine.analyze(env.db, subject: subject)
        let analysis = Date().timeIntervalSince(started)
        print("INTELLIGENCE-UI-STALL longestMainThreadGap=\(String(format: "%.3f", longest))s analysisAlone=\(String(format: "%.3f", analysis))s requests=\(requests)")
        XCTAssertLessThan(longest, 0.6, "the page must not block the main thread while it computes")
        await env.cleanup()
    }
}
