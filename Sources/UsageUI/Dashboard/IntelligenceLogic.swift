import Foundation
import UsageCore

/// Wording and chart data for the usage intelligence page.
///
/// Everything here turns numbers that `UsageCore` computed into text or plot points. Nothing recomputes a cost, a token
/// total, a quota figure or a forecast, so the page cannot disagree with the core.
enum IntelligenceLogic {
    /// The unscoped window with the longest length, for the account whose quota was read most recently.
    static func defaultSubject(_ subjects: [IntelligenceSubject]) -> IntelligenceSubject? {
        guard let newest = subjects.filter({ $0.scopeLabel == nil }).max(by: { ($0.lastReadingAt ?? .distantPast) < ($1.lastReadingAt ?? .distantPast) }) else {
            return subjects.first
        }
        return subjects.filter { $0.scopeLabel == nil && $0.accountID == newest.accountID && $0.poolKey == newest.poolKey }
            .max(by: { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }) ?? newest
    }

    // MARK: Time

    /// The time zone the page shows times in, from the stored identifier. An empty or unknown identifier means the
    /// current system time zone.
    static func zone(for identifier: String) -> TimeZone {
        identifier.isEmpty ? .current : (TimeZone(identifier: identifier) ?? .current)
    }

    /// A short offset label such as `UTC+3` or `UTC-7` or `UTC+5:30`, at the given moment.
    static func offsetLabel(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        if seconds == 0 { return "UTC" }
        let sign = seconds > 0 ? "+" : "-"
        let hours = abs(seconds) / 3600, minutes = (abs(seconds) % 3600) / 60
        return "UTC" + sign + String(hours) + (minutes > 0 ? ":" + String(format: "%02d", minutes) : "")
    }

    static func format(_ date: Date, zone: TimeZone, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date, zone: TimeZone) -> String { format(date, zone: zone, "EEE d MMM HH:mm") }
    static func shortDate(_ date: Date, zone: TimeZone) -> String { format(date, zone: zone, "d MMM") }
    static func weekdayTime(_ date: Date, zone: TimeZone) -> String { format(date, zone: zone, "EEE HH:mm") }
    static func weekday(_ date: Date, zone: TimeZone) -> String { format(date, zone: zone, "EEEE") }

    /// A cycle as a range, for example `Fri 16 Oct 03:00 → Fri 23 Oct 03:00`.
    static func range(_ span: QuotaCycleSpan, zone: TimeZone) -> String {
        "\(format(span.start, zone: zone, "EEE d MMM HH:mm")) → \(format(span.end, zone: zone, "EEE d MMM HH:mm"))"
    }

    /// The same moment in UTC, which is the canonical time stored for every boundary.
    static func utc(_ date: Date) -> String {
        format(date, zone: TimeZone(identifier: "UTC")!, "EEE d MMM HH:mm") + " UTC"
    }

    /// Words for the part of the day, so that an estimate can say "Thursday evening" instead of a false minute.
    static func dayPart(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        let name = weekday(date, zone: zone)
        switch hour {
        case 5..<12: return String(localized: "\(name) morning")
        case 12..<17: return String(localized: "\(name) afternoon")
        case 17..<22: return String(localized: "\(name) evening")
        default: return String(localized: "\(name) night")
        }
    }

    /// The reset schedule as a sentence, for example `Fridays at 03:00 (UTC+3)`.
    static func scheduleDescription(_ schedule: ResetSchedule, zone: TimeZone, now: Date) -> String? {
        guard schedule.state == .established, let clock = schedule.wallClock(in: zone) else { return nil }
        let time = String(format: "%02d:%02d", clock.hour, clock.minute)
        let offset = offsetLabel(zone, at: now)
        if let weekdayIndex = clock.weekday {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale.current
            let name = calendar.weekdaySymbols[weekdayIndex - 1]
            return String(localized: "Every \(name) at \(time) (\(offset))")
        }
        return String(localized: "Every day at \(time) (\(offset))")
    }

    // MARK: Cycle labels

    enum CycleStatus: String {
        case complete, partial, insufficient, unobserved, projected, current
    }

    static func status(_ cycle: SubscriptionCycleReport) -> CycleStatus {
        if cycle.span.origin == .projected { return .projected }
        switch cycle.quota?.completeness {
        case .complete: return cycle.timing == .current ? .current : .complete
        case .partial: return cycle.timing == .current ? .current : .partial
        case .insufficient: return cycle.timing == .current ? .current : .insufficient
        case .unobserved, .none: return .unobserved
        }
    }

    static func statusLabel(_ status: CycleStatus) -> String {
        switch status {
        case .complete: String(localized: "Fully observed")
        case .partial: String(localized: "Partly observed")
        case .insufficient: String(localized: "Barely observed")
        case .unobserved: String(localized: "No quota readings")
        case .projected: String(localized: "Calculated boundaries")
        case .current: String(localized: "In progress")
        }
    }

    static func statusHelp(_ status: CycleStatus) -> String {
        switch status {
        case .complete: String(localized: "The start and the end of the cycle were observed and no long stretch is missing between readings.")
        case .partial: String(localized: "Quota readings exist, but the start, the end or a middle stretch of the cycle was not observed. The highest reading is a lower bound of the cycle's consumption.")
        case .insufficient: String(localized: "Too few readings to say how the utilization changed.")
        case .unobserved: String(localized: "The provider reported no utilization for this cycle. Local usage is still shown.")
        case .projected: String(localized: "This cycle's boundaries were calculated from an established reset schedule. It has no quota readings, and no utilization is inferred for it.")
        case .current: String(localized: "This cycle has not ended yet.")
        }
    }

    // MARK: Weekly history

    struct HistoryRow: Identifiable, Equatable {
        var id: String
        var start: Date
        var label: String
        var processedTokens: Int64
        /// Processed tokens of activity that is not tied to the analyzed account, drawn as a second, lighter part of the bar.
        var unattributedTokens: Int64
        var freshTokens: Int64
        var maximumPercent: Double?
        var status: CycleStatus
        var reachedLimit: Bool
        var isCurrent: Bool
    }

    static func historyRows(_ cycles: [SubscriptionCycleReport], zone: TimeZone) -> [HistoryRow] {
        cycles.map { cycle in
            HistoryRow(id: cycle.id, start: cycle.span.start, label: shortDate(cycle.span.start, zone: zone),
                       processedTokens: cycle.local.tokens.totalProcessed, unattributedTokens: cycle.unattributed.processedTokens,
                       freshTokens: cycle.local.tokens.freshTokens,
                       maximumPercent: cycle.quota?.maximumPercent, status: status(cycle),
                       reachedLimit: cycle.quota?.reachedLimit ?? false, isCurrent: cycle.timing == .current)
        }
    }

    // MARK: Cumulative quota chart

    struct CurveSegment: Identifiable, Equatable {
        enum Kind { case observed, bracketed }
        var id: String
        var cycleID: String
        var kind: Kind
        /// Hours since the start of the cycle.
        var fromHour: Double
        var toHour: Double
        var fromPercent: Double
        var toPercent: Double
    }

    /// The step curve of one cycle. Solid segments are spans in which the value was observed. Dashed segments join two
    /// observed values, because the moment of the rise between them was not observed and is not drawn as a smooth line.
    static func segments(for cycle: SubscriptionCycleReport) -> [CurveSegment] {
        guard let curve = cycle.quota?.curve else { return [] }
        var out: [CurveSegment] = []
        func hours(_ date: Date) -> Double { date.timeIntervalSince(cycle.span.start) / 3600 }
        for (index, point) in curve.points.enumerated() {
            out.append(CurveSegment(id: "\(cycle.id)-o\(index)", cycleID: cycle.id, kind: .observed, fromHour: hours(point.firstObservedAt),
                                    toHour: max(hours(point.lastConfirmedAt), hours(point.firstObservedAt) + 0.05),
                                    fromPercent: point.percent, toPercent: point.percent))
            if index + 1 < curve.points.count {
                let next = curve.points[index + 1]
                out.append(CurveSegment(id: "\(cycle.id)-b\(index)", cycleID: cycle.id, kind: .bracketed,
                                        fromHour: hours(point.lastConfirmedAt), toHour: hours(next.firstObservedAt),
                                        fromPercent: point.percent, toPercent: next.percent))
            }
        }
        return out
    }

    /// The earlier cycles that may be drawn next to `selected` without implying a comparison that does not hold.
    static func comparableCycles(to selected: SubscriptionCycleReport, in report: SubscriptionUsageReport) -> (shown: [SubscriptionCycleReport], hidden: Int) {
        let others = report.cycles.filter { $0.id != selected.id && $0.quota != nil && $0.span.start < selected.span.start }
        let target = CycleMetrics(selected)
        let shown = others.filter { CycleComparisonEngine.compare(CycleMetrics($0), target).isDirectlyComparable }
        return (Array(shown.suffix(4)), others.count - shown.count)
    }

    // MARK: Token categories

    struct TokenPart: Identifiable, Equatable {
        var id: String
        var label: String
        var tokens: Int64
    }

    static func tokenParts(_ tokens: TokenCounts) -> [TokenPart] {
        [TokenPart(id: "uncached", label: String(localized: "Uncached input"), tokens: tokens.uncachedInput),
         TokenPart(id: "output", label: String(localized: "Output"), tokens: tokens.output),
         TokenPart(id: "cacheRead", label: String(localized: "Cache reads"), tokens: tokens.cacheRead),
         TokenPart(id: "cache5m", label: String(localized: "Cache writes (5 min)"), tokens: tokens.cacheCreation5m),
         TokenPart(id: "cache1h", label: String(localized: "Cache writes (1 h)"), tokens: tokens.cacheCreation1h),
         TokenPart(id: "cacheOther", label: String(localized: "Cache writes (TTL not stated)"), tokens: tokens.cacheCreationUnsplit)]
            .filter { $0.tokens > 0 }
    }

    // MARK: Quota text

    static func coverageLines(_ coverage: CycleCoverage) -> [String] {
        var lines: [String] = []
        if let delay = coverage.firstObservationDelay {
            lines.append(delay < 60 ? String(localized: "The first reading came at the start of the cycle.") : String(localized: "The first reading came \(Fmt.duration(delay)) after the cycle began."))
        }
        if let lead = coverage.lastObservationLead {
            lines.append(String(localized: "The last reading was confirmed \(Fmt.duration(lead)) before the end of the observed part of the cycle."))
        }
        if let count = coverage.observationCount {
            lines.append(String(localized: "At least \(count) observations of \(coverage.distinctValues) different values."))
        } else {
            lines.append(String(localized: "\(coverage.distinctValues) different values; how often each was seen is not known for readings stored earlier."))
        }
        lines.append(String(localized: "The longest stretch in which a rise could have gone unseen: \(Fmt.duration(coverage.largestUnresolvedGap))."))
        if coverage.longestUnchangedStretch >= 3600 {
            lines.append(String(localized: "The longest stretch in which the value is known not to have changed: \(Fmt.duration(coverage.longestUnchangedStretch)). That is the provider reporting no change, not a gap."))
        }
        return lines
    }

    static func quotaChangeText(_ change: QuotaChange) -> String {
        switch change {
        case .exact(let value):
            let points = Int(value.rounded())
            return String(localized: "+\(points) pts")
        case .between(let low, let high):
            let l = Int(low.rounded()), h = Int(high.rounded())
            return String(localized: "between +\(l) and +\(h) pts")
        case .unavailable: return String(localized: "not observed")
        }
    }

    static func duration(_ interval: TimeInterval) -> String { Fmt.duration(interval) }

    // MARK: Forecast text

    static func rangeText(_ forecast: UsageForecast) -> String? {
        guard let low = forecast.low, let high = forecast.high, let point = forecast.point else { return nil }
        let l = Int(low.rounded()), h = Int(high.rounded())
        if l == h { return String(localized: "about \(Int(point.rounded()))%") }
        return String(localized: "\(l)–\(h)%")
    }

    static func methodName(_ method: ForecastMethod) -> String {
        switch method {
        case .cycleAveragePace: String(localized: "pace over the whole cycle so far")
        case .recentPace: String(localized: "pace over the most recent part of the cycle")
        case .sameStageIncrement: String(localized: "what earlier cycles added after the same point")
        }
    }

    static func unavailableText(_ reason: ForecastUnavailableReason) -> String {
        switch reason {
        case .noCurrentCycle: String(localized: "No cycle is in progress.")
        case .noReadings: String(localized: "The provider has not reported utilization in this cycle.")
        case .tooFewReadings: String(localized: "Fewer than two different utilization values were reported in this cycle, so there is no pace to project.")
        case .readingsStale(let age): String(localized: "The newest reading is \(Fmt.duration(age)) old, which is too old to forecast from.")
        case .cycleEnded: String(localized: "The cycle has ended; the new one has not been observed yet.")
        case .notEnoughCompletedCycles(let have, let need): String(localized: "\(have) of the \(need) fully observed earlier cycles needed to check a forecast are available.")
        case .planChangedDuringCycle: String(localized: "The plan changed during this cycle, so the pace so far and the history describe different allowances.")
        case .errorTooLarge(let error, let limit):
            String(localized: "Forecasts of earlier cycles were off by about \(Int(error.rounded())) points, which is more than the \(Int(limit.rounded())) points a forecast may be off by to be shown.")
        case .noBetterThanNoGrowth(let error, let naive):
            String(localized: "Forecasts of earlier cycles were off by about \(Int(error.rounded())) points, hardly better than assuming no more use (\(Int(naive.rounded())) points), so they carry no information.")
        }
    }

    static func warningText(_ warning: ForecastWarning) -> String {
        switch warning {
        case .earlierCyclesOnAnotherPlanExcluded: String(localized: "Earlier cycles on a different plan were left out.")
        case .planNotRecorded: String(localized: "No plan is recorded, so cycles on different plans cannot be told apart.")
        case .modelMixChanged: String(localized: "The mix of models in this cycle differs a lot from earlier cycles.")
        case .earlierCyclesLimitBound: String(localized: "Some earlier cycles reached the limit, so they may understate how much work you wanted to do.")
        case .unobservedActivityPossible: String(localized: "Other surfaces of the account, such as chat or other devices, can use the same allowance without being seen here.")
        }
    }

    static func attributionText(_ attribution: LocalAttribution, identified: Bool, share: Double? = nil) -> String? {
        switch attribution {
        case .account, .noLocalActivity: nil
        case .partlyAttributed where !identified:
            String(localized: "Only \(Int(((share ?? 0) * 100).rounded()))% of this Mac's local tokens come from sessions that, like these readings, name no account. The rest comes from sessions that name an account, and these readings may or may not include it, so no ratio is shown while that work matters.")
        case .unattributed where !identified:
            String(localized: "All of this Mac's local activity in this period names an account, while these readings name none. They cannot be paired.")
        case .partlyAttributed:
            String(localized: "Only \(Int(((share ?? 0) * 100).rounded()))% of the local tokens can be tied to this account. The rest comes from sessions that name no account and is left out, so no ratio is shown unless the work between two readings is fully attributed.")
        case .unattributed:
            String(localized: "Local usage cannot currently be reliably assigned to this subscription account: the sessions name no account. You can tell Tokenwatch which account used this Mac during a period.")
        case .unassignedAccount:
            String(localized: "Neither the readings nor the sessions name an account, so they are paired as the unlabeled activity and readings of this Mac. That can include more than one account.")
        case .ambiguous:
            String(localized: "Another account was active in the same period, so local usage cannot be tied to this one. No ratios are shown.")
        case .notAttributed: String(localized: "No local model matches this limit's scope, so no local usage is attributed to it.")
        }
    }

    static func efficiencyCaveat(_ caveat: EfficiencyCaveat) -> String {
        switch caveat {
        case .accountWideQuotaVersusLocalTokens: String(localized: "The percentage covers the whole account; the tokens are only what this Mac recorded.")
        case .planNotRecorded: String(localized: "No plan is recorded.")
        case .planChangedDuringCycle: String(localized: "The plan changed during this cycle.")
        case .neitherSideNamesAnAccount: String(localized: "Neither the readings nor the sessions name an account, so this pairs unlabeled readings with unlabeled activity.")
        case .activityAssociatedByUser: String(localized: "Part of the local activity is tied to this account by an association you made, not by the sessions' own files.")
        case .highStepVariability: String(localized: "The ratio differs a lot between the individual rises, so it is not steady.")
        case .roundedPercentages: String(localized: "The provider rounds percentages; the range shows what that rounding allows.")
        case .costPartiallyUnpriced: String(localized: "Some models have no price, so the cost is a lower bound.")
        case .scopedWindow: String(localized: "This limit applies to one model only.")
        }
    }

    static func efficiencyUnavailable(_ reason: EfficiencyUnavailableReason) -> String {
        switch reason {
        case .noReadings: String(localized: "No quota readings.")
        case .singleReading: String(localized: "Only one value was reported.")
        case .riseTooSmall: String(localized: "The utilization rose too little for a ratio to survive rounding.")
        case .tooFewSteps: String(localized: "Too few separate rises.")
        case .tooLittleLocalWork: String(localized: "Too little local work between the readings.")
        case .intervalTooShort: String(localized: "The readings are too close together.")
        case .localActivityNotAttributed: String(localized: "The local work between the readings is not fully tied to this account.")
        case .planChangedWithinInterval: String(localized: "A plan change falls between the readings, so the interval mixes two plans.")
        case .cycleOverlapsAnotherWindow: String(localized: "Readings of another window overlap this cycle, so they cannot be told apart.")
        }
    }

    static func comparabilityText(_ issue: ComparabilityIssue) -> String {
        switch issue {
        case .differentPlan: String(localized: "different plan")
        case .planNotRecorded: String(localized: "plan not recorded")
        case .differentModelMix: String(localized: "different model mix")
        case .differentCacheBehavior: String(localized: "different cache behaviour")
        case .differentObservationCoverage: String(localized: "different observation coverage")
        case .partialQuotaObservation: String(localized: "partly observed quota")
        case .projectedBoundaries: String(localized: "calculated boundaries")
        }
    }

    // MARK: Readiness

    /// One statement about what the page can and cannot say right now, and what would change that.
    struct ReadinessNote: Identifiable, Equatable {
        enum Level { case available, limited }
        var id: String
        var level: Level
        var text: String
    }

    /// Says, in plain words and from the numbers `UsageCore` computed, what is available, what is not, and why.
    static func readiness(_ report: SubscriptionUsageReport, forecast: UsageForecast, zone: TimeZone, now: Date) -> [ReadinessNote] {
        var notes: [ReadinessNote] = []
        let window = WindowNaming.displayName(minutes: report.subject.windowMinutes, fallbackKey: report.subject.windowKey).lowercased()
        let current = report.currentCycle ?? report.cycles.last
        let schedule = report.schedule

        // The schedule, with how much it has been checked.
        if schedule.state == .established, let when = scheduleDescription(schedule, zone: zone, now: now) {
            let announced = schedule.announcedResets, confirmed = schedule.confirmedResets
            let next = schedule.nextReset(after: now).map { dateTime($0, zone: zone) } ?? ""
            let text = schedule.confidence == .confirmed
                ? String(localized: "The \(window) reset schedule is confirmed: \(when). \(confirmed) resets were each followed by a new window. The next one is expected \(next).")
                : String(localized: "Your next \(window) reset is expected \(next). The schedule (\(when)) is based on \(announced) provider-announced reset times and \(confirmed) confirmed reset, not on two confirmed reset events. A reset counts as confirmed only once a new window is seen after it.")
            notes.append(ReadinessNote(id: "schedule", level: schedule.confidence == .confirmed ? .available : .limited, text: text))
        } else if schedule.announcedResets < 2 {
            notes.append(ReadinessNote(id: "schedule", level: .limited, text: String(localized: "Only \(schedule.announcedResets) reset has been announced for this window so far. A repeating schedule needs at least two, and until then no earlier or later cycle is calculated.")))
        } else {
            notes.append(ReadinessNote(id: "schedule", level: .limited, text: String(localized: "The announced reset times do not repeat at the window length, so no fixed schedule is established. Windows that start with a request, such as five-hour limits, never get one.")))
        }

        // Local usage.
        if let current, !current.local.isEmpty {
            notes.append(ReadinessNote(id: "usage", level: .available, text: String(localized: "\(window.capitalized) usage statistics are available from this Mac's session files.")))
        }
        if let current, let text = attributionText(current.attribution, identified: report.subject.accountIsIdentified, share: current.attributedShare) {
            notes.append(ReadinessNote(id: "attribution", level: .limited, text: text))
        }

        // Quota observation and the ratios that depend on it.
        if let current, let quota = current.quota {
            if current.efficiency.isAvailable {
                notes.append(ReadinessNote(id: "efficiency", level: .available, text: String(localized: "A quota-to-token relationship could be measured in this cycle, with the caveats listed under it.")))
            } else if let reason = current.efficiency.unavailable.first, current.attribution != .unattributed, current.attribution != .ambiguous {
                notes.append(ReadinessNote(id: "efficiency", level: .limited, text: String(localized: "Usage statistics are available, but quota-efficiency estimates need more quota observations: \(efficiencyUnavailable(reason).lowercased())")))
            }
            if !quota.coverage.hasReliableFullCycleResult && current.timing == .past {
                notes.append(ReadinessNote(id: "coverage", level: .limited, text: String(localized: "This cycle's whole-cycle utilization is a lower bound: the longest stretch in which a rise could have gone unseen was \(Fmt.duration(quota.coverage.largestUnresolvedGap)).")))
            }
        } else if current != nil {
            notes.append(ReadinessNote(id: "quota", level: .limited, text: String(localized: "The provider has reported no utilization for this cycle yet, so only local usage is shown.")))
        }

        // The forecast.
        switch forecast.availability {
        case .forecast:
            let e = forecast.evidence
            if let error = e.meanAbsoluteError {
                let cases = e.heldOutCases, cycles = e.heldOutCycles
                notes.append(ReadinessNote(id: "forecast", level: .available, text: String(localized: "The forecast is supported: on \(cases) earlier forecasts from \(cycles) cycles, made without knowing their outcome, it was typically off by \(Int(error.rounded())) points.")))
            }
        case .unavailable(let reasons):
            if let first = reasons.first {
                notes.append(ReadinessNote(id: "forecast", level: .limited, text: String(localized: "No forecast is shown. ") + unavailableText(first)))
            }
        case .limitReached:
            break
        }
        return notes
    }

    // MARK: Insights

    static func text(for insight: UsageInsight, window: String, zone: TimeZone) -> String {
        let v = insight.values
        func pct(_ key: String) -> Int { Int(((v[key] ?? 0) * 100).rounded()) }
        func signed(_ key: String) -> (Int, Bool) {
            let value = Int((abs(v[key] ?? 0) * 100).rounded())
            return (value, (v[key] ?? 0) >= 0)
        }
        switch insight.kind {
        case .mayExhaustAllowance:
            let earliest = Date(timeIntervalSince1970: v["earliest"] ?? 0)
            if (v["likely"] ?? 0) > 0, let latest = v["latest"], latest > 0 {
                let a = dateTime(earliest, zone: zone), b = dateTime(Date(timeIntervalSince1970: latest), zone: zone)
                return String(localized: "At your recent pace your \(window) allowance may run out between \(a) and \(b), before the reset.")
            }
            let part = dayPart(earliest, zone: zone)
            return String(localized: "Your \(window) allowance could run out as early as \(part) if the pace holds. The forecast range also includes reaching the reset first.")
        case .forecastNearLimit:
            let low = Int((v["low"] ?? 0).rounded()), high = Int((v["high"] ?? 0).rounded())
            return String(localized: "Your \(window) utilization is forecast to end at \(low)–\(high)%, close to the limit.")
        case .tokensChangedVersusPreviousCycle:
            let (value, up) = signed("change")
            let base = up
                ? String(localized: "Local processed tokens were \(value)% higher than in the cycle before.")
                : String(localized: "Local processed tokens were \(value)% lower than in the cycle before.")
            return (v["comparable"] ?? 0) > 0 ? base : base + " " + String(localized: "The two cycles are not directly comparable.")
        case .tokensChangedSameDays:
            let (value, up) = signed("change")
            let days = Int(v["days"] ?? 0)
            return up
                ? String(localized: "In the first \(days) days of this cycle, local processed tokens are \(value)% higher than in the same days of the previous cycle.")
                : String(localized: "In the first \(days) days of this cycle, local processed tokens are \(value)% lower than in the same days of the previous cycle.")
        case .quotaPaceChanged:
            let (value, up) = signed("change")
            return up
                ? String(localized: "Observed quota consumption per day was \(value)% faster than in the previous comparable cycle.")
                : String(localized: "Observed quota consumption per day was \(value)% slower than in the previous comparable cycle.")
        case .busiestDay:
            let day = insight.date.map { weekday($0, zone: zone) } ?? ""
            let share = pct("share")
            return String(localized: "Your busiest subscription day was \(day), with \(share)% of the cycle's local tokens.")
        case .topModel:
            let model = insight.names["model"] ?? ""
            let share = pct("share")
            return String(localized: "\(model) accounted for \(share)% of local processed tokens.")
        case .cacheReadShare:
            let share = pct("share")
            return String(localized: "Cache reads were \(share)% of the input tokens processed.")
        case .frontLoadedUsage:
            let share = pct("share"), cycles = Int(v["cycles"] ?? 0)
            return String(localized: "In the last \(cycles) cycles, a typical \(share)% of local usage happened in the first three subscription days.")
        case .paceVersusHistory:
            let (value, up) = signed("change")
            return up
                ? String(localized: "Local usage per day is \(value)% higher than your recent average.")
                : String(localized: "Local usage per day is \(value)% lower than your recent average.")
        case .quotaObservationLimited:
            let coverage = pct("coverage")
            return String(localized: "Quota readings cover only \(coverage)% of the last cycle, so its utilization is a lower bound.")
        case .localUsagePartlyUnattributed:
            let share = pct("share")
            return String(localized: "Only \(share)% of the local tokens in this cycle can be tied to this subscription account, so quota-efficiency estimates are withheld.")
        case .limitReachedBefore:
            let n = Int(v["cycles"] ?? 0), of = Int(v["of"] ?? 0)
            return String(localized: "\(n) of the last \(of) cycles reached the limit.")
        }
    }
}
