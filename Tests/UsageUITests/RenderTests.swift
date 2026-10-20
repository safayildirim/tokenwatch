import XCTest
import SwiftUI
import AppKit
import CryptoKit
@testable import UsageCore
@testable import UsageUI

/// Draws the real views offscreen and inspects the pixels. This catches crashes, blank pages and
/// states that were forgotten, which view-model tests cannot.
@MainActor
final class RenderTests: XCTestCase {
    private func render<V: View>(_ view: V, size: CGSize, wait: Double = 0.4, scheme: NSAppearance.Name = .aqua) async -> NSBitmapImageRep? {
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

    private func renderOrFail<V: View>(_ view: V, size: CGSize, wait: Double = 0.4, scheme: NSAppearance.Name = .aqua) async throws -> NSBitmapImageRep {
        guard let rep = await render(view, size: size, wait: wait, scheme: scheme) else {
            XCTFail("could not render the view")
            throw CancellationError()
        }
        return rep
    }

    /// The share of pixels that differ from the background colour in the top-left corner.
    private func inkRatio(_ rep: NSBitmapImageRep) -> Double {
        guard let data = rep.bitmapData else { return 0 }
        let bytesPerPixel = rep.bitsPerPixel / 8
        let total = rep.pixelsWide * rep.pixelsHigh
        let bg = (data[0], data[1], data[2])
        var different = 0
        var i = 0
        while i < total {
            let p = data + i * bytesPerPixel
            if p[0] != bg.0 || p[1] != bg.1 || p[2] != bg.2 { different += 1 }
            i += 1
        }
        return Double(different) / Double(max(1, total))
    }

    private func digest(_ rep: NSBitmapImageRep) -> String {
        guard let data = rep.representation(using: .png, properties: [:]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Quota meter states

    func testEveryQuotaStateRendersDistinctly() async throws {
        let now = Date()
        func reading(_ pct: Double, resets: TimeInterval?, ago: TimeInterval, authority: QuotaAuthority = .authoritative) -> QuotaReading {
            QuotaReading(kind: .fiveHour, utilizationPercent: pct, resetsAt: resets.map { now.addingTimeInterval($0) },
                         observedAt: now.addingTimeInterval(-ago), provider: StatusLineQuotaSource.providerID, authority: authority)
        }
        let states: [(String, QuotaWindowState)] = [
            ("low", QuotaEvaluator.evaluate(kind: .fiveHour, readings: [reading(20, resets: 7200, ago: 30)], now: now, allowUnverified: false)),
            ("high", QuotaEvaluator.evaluate(kind: .fiveHour, readings: [reading(93, resets: 1800, ago: 30)], now: now, allowUnverified: false)),
            ("stale", QuotaEvaluator.evaluate(kind: .fiveHour, readings: [reading(63, resets: 7200, ago: 4 * 3600)], now: now, allowUnverified: false)),
            ("elapsed", QuotaEvaluator.evaluate(kind: .fiveHour, readings: [reading(80, resets: -600, ago: 3600)], now: now, allowUnverified: false)),
            ("unavailable", QuotaEvaluator.evaluate(kind: .fiveHour, readings: [], now: now, allowUnverified: false)),
            ("unverified", QuotaEvaluator.evaluate(kind: .fiveHour, readings: [reading(40, resets: nil, ago: 30, authority: .unverified)], now: now, allowUnverified: true)),
        ]
        var digests: [String: String] = [:]
        for (name, state) in states {
            let rep = try await renderOrFail(QuotaMeter(state: state, onSetup: {}).padding().frame(width: 400).background(Color.white), size: CGSize(width: 400, height: 130))
            XCTAssertGreaterThan(inkRatio(rep), 0.02, "\(name) should draw something")
            digests[name] = digest(rep)
        }
        XCTAssertEqual(Set(digests.values).count, states.count, "each state must look different: \(digests.keys.sorted())")
    }

    func testCompositionBarsRenderForEveryCategoryMix() async throws {
        let mixes = [TokenCounts(uncachedInput: 5, output: 10, cacheRead: 1000, cacheCreation: 50), TokenCounts(output: 5), .zero]
        for t in mixes {
            let rep = try await renderOrFail(TokenCompositionBar(tokens: t, includeCacheReads: true).padding().frame(width: 600).background(Color.white), size: CGSize(width: 600, height: 80))
            XCTAssertNotNil(rep)
        }
    }

    // MARK: Pages with real data

    private func populatedEnv() async throws -> UIEnv {
        let env = try UIEnv()
        let now = Clock.nowMs()
        try env.writeSession("S1", cwd: "/Users/test/alpha", lines: 40, at: now - 3 * 3_600_000)
        try env.writeSession("S2", cwd: "/Users/test/beta", lines: 25, at: now - 2 * 86_400_000, model: "claude-sonnet-5-5")
        try env.writeQuota(five: 63, week: 81)
        await env.model.start()
        await env.waitUntil { env.model.overview.allTime.requests == 65 && env.model.quotaState(.fiveHour)?.utilizationPercent == 63 }
        return env
    }

    func testEveryDashboardPageRendersContentWithRealData() async throws {
        let env = try await populatedEnv()
        for section in DashboardSection.allCases {
            env.model.selection = section
            let rep = try await renderOrFail(DashboardView().environment(env.model), size: CGSize(width: 1240, height: 800), wait: 1.6)
            XCTAssertGreaterThan(inkRatio(rep), 0.01, "\(section) rendered blank")
        }
        await env.cleanup()
    }

    func testSessionDetailAndMenuBarRenderInLightAndDark() async throws {
        let env = try await populatedEnv()
        let id = try XCTUnwrap(env.model.recentSessions.first?.id)
        env.model.show(session: id)
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let detail = try await renderOrFail(DashboardView().environment(env.model), size: CGSize(width: 1240, height: 1200), wait: 2, scheme: scheme)
            XCTAssertGreaterThan(inkRatio(detail), 0.01)
            let popover = try await renderOrFail(MenuBarContentView().environment(env.model), size: CGSize(width: 380, height: 600), wait: 0.8, scheme: scheme)
            XCTAssertGreaterThan(inkRatio(popover), 0.02)
        }
        await env.cleanup()
    }

    func testEmptyDatabaseRendersHelpfulEmptyStates() async throws {
        let env = try UIEnv()
        await env.model.start()
        await env.waitUntil { env.model.hasLoaded }
        for section in [DashboardSection.overview, .trends, .sessions, .projects, .models] {
            env.model.selection = section
            let rep = try await renderOrFail(DashboardView().environment(env.model), size: CGSize(width: 1240, height: 800), wait: 1)
            XCTAssertGreaterThan(inkRatio(rep), 0.003, "\(section) should explain that there is no data")
        }
        await env.cleanup()
    }

    func testSettingsWindowRenders() async throws {
        let env = try UIEnv()
        await env.model.start()
        let rep = try await renderOrFail(SettingsView().environment(env.model), size: CGSize(width: 600, height: 520), wait: 0.8)
        XCTAssertGreaterThan(inkRatio(rep), 0.02)
        await env.cleanup()
    }
}
