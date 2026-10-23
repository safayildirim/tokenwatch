import Foundation
import UsageCore

/// Prints the usage intelligence report for every quota window that has readings, for checks against real data.
func printIntelligence(db: UsageDatabase, zoneName: String?, now: Date) throws {
    let zone = zoneName.flatMap { TimeZone(identifier: $0) } ?? TimeZone(secondsFromGMT: 3 * 3600)!
    let stamp = DateFormatter()
    stamp.timeZone = zone
    stamp.dateFormat = "EEE yyyy-MM-dd HH:mm"
    func when(_ date: Date) -> String { stamp.string(from: date) }
    func millions(_ value: Int64) -> String { String(format: "%.1fM", Double(value) / 1e6) }

    print("Times are shown in \(zone.identifier) (UTC offset \(zone.secondsFromGMT(for: now) / 3600) h); canonical times are UTC.")
    for subject in try SubscriptionUsageAnalyticsEngine.subjects(db) {
        let report = try SubscriptionUsageAnalyticsEngine.analyze(db, subject: subject, now: now)
        print("\n== \(subject.provider.rawValue) / \(subject.accountLabel) / \(subject.poolKey) / \(subject.windowKey)")
        if report.schedule.state == .established, let clock = report.schedule.wallClock(in: zone) {
            let weekday = clock.weekday.map { Calendar(identifier: .gregorian).weekdaySymbols[$0 - 1] + " " } ?? ""
            print("schedule: \(weekday)\(String(format: "%02d:%02d", clock.hour, clock.minute)) local; announced=\(report.schedule.announcedResets) onSchedule=\(report.schedule.supportingResets) confirmed=\(report.schedule.confirmedResets) confidence=\(report.schedule.confidence.rawValue)")
        } else {
            print("schedule: not established")
        }
        for event in report.resetEvents.suffix(6) {
            print("  reset \(event.kind.rawValue) \(when(event.at)) confirmed=\(event.confirmed)")
        }
        let forecast = UsageForecastEngine.forecast(for: report, now: now)
        switch forecast.availability {
        case .forecast:
            print("forecast: \(forecast.low ?? 0)–\(forecast.high ?? 0)% (point \(forecast.point ?? 0)) by \(forecast.method?.rawValue ?? "?"); exhaustion \(forecast.exhaustion.map { "\($0.confidence.rawValue) \(when($0.earliest))" } ?? "none")")
        case .limitReached: print("forecast: limit reached")
        case .unavailable(let reasons): print("forecast: unavailable \(reasons)")
        }
        print("backtest: cycles=\(forecast.evaluation.evaluatedCycles) qualification=\(forecast.evaluation.qualification) heldOut=\(forecast.evaluation.heldOutScore.map { "n=\($0.cases) mae=\(String(format: "%.1f", $0.meanAbsoluteError)) noGrowth=\(String(format: "%.1f", $0.noGrowthMeanAbsoluteError))" } ?? "none") " + forecast.evaluation.scores.map { "\($0.method.rawValue)(n=\($0.cases), mae=\(String(format: "%.1f", $0.meanAbsoluteError)), bias=\(String(format: "%.1f", $0.bias)))" }.joined(separator: " "))
        for insight in UsageInsightsEngine.insights(report: report, forecast: forecast, now: now) { print("insight: \(insight.kind.rawValue) \(insight.values)") }
        for cycle in report.cycles {
            let q = cycle.quota
            let quota = q.map { "readings=\($0.readingCount) first=\($0.firstPercent!)% last=\($0.lastPercent!)% max=\($0.maximumPercent!)% start=\($0.startObserved) end=\($0.endObserved) \($0.completeness.rawValue)" } ?? "no readings"
            print("  \(when(cycle.span.start)) -> \(when(cycle.span.end)) [\(cycle.span.origin.rawValue)\(cycle.span.endedEarly ? ", ended early" : "")] \(cycle.timing.rawValue) requests=\(cycle.local.requests) processed=\(millions(cycle.local.processedTokens)) fresh=\(millions(cycle.local.tokens.freshTokens)) | \(quota) | attribution=\(cycle.attribution.rawValue) share=\(cycle.attributedShare.map { String(format: "%.2f", $0) } ?? "-")")
            if let q = cycle.quota {
                let c = q.coverage
                print("      coverage: firstDelay=\(c.firstObservationDelay.map { String(format: "%.1fh", $0 / 3600) } ?? "-") lastLead=\(c.lastObservationLead.map { String(format: "%.1fh", $0 / 3600) } ?? "-") count=\(c.observationCount.map(String.init) ?? "?") unresolved=\(String(format: "%.1fh", c.largestUnresolvedGap / 3600)) unchanged=\(String(format: "%.1fh", c.longestUnchangedStretch / 3600)) determined=\(String(format: "%.2f", c.determinedFraction)) supported=\(String(format: "%.2f", c.supportedFraction)) reliableFullCycle=\(c.hasReliableFullCycleResult)")
            }
            if !cycle.efficiency.isAvailable { print("      efficiency withheld: \(cycle.efficiency.unavailable.map(\.rawValue))") }
            if let quota = cycle.quota, cycle.timing != .future {
                let days = cycle.days.map { day -> String in
                    switch day.quotaChange {
                    case .exact(let v): return "+\(Int(v))"
                    case .between(let lo, let hi): return "\(Int(lo))…\(Int(hi))"
                    case .unavailable: return "–"
                    }
                }
                if !days.isEmpty { print("      daily quota change (pts): \(days.joined(separator: " "))  unresolved gap=\(Int(quota.coverage.largestUnresolvedGap / 3600)) h") }
            }
            if let ratio = cycle.efficiency.processedTokensPerPoint {
                print("      efficiency \(cycle.efficiency.quality!.rawValue): \(String(format: "%.2f", ratio.value / 1e6))M processed per point (\(String(format: "%.2f", ratio.low / 1e6))–\(String(format: "%.2f", ratio.high / 1e6))), rise \(cycle.efficiency.risePoints) pts")
            }
        }
    }
}
