import SwiftUI
import UsageCore

enum RangePreset: String, CaseIterable, Identifiable {
    case last24h = "24 hours", last7d = "7 days", last30d = "30 days", last90d = "90 days", all = "All time", custom = "Custom"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .last24h: String(localized: "24 hours")
        case .last7d: String(localized: "7 days")
        case .last30d: String(localized: "30 days")
        case .last90d: String(localized: "90 days")
        case .all: String(localized: "All time")
        case .custom: String(localized: "Custom")
        }
    }
}

/// This is a calendar period chosen by the user, and the pages that offer date filtering share it.
struct RangeSelection: Equatable {
    var preset: RangePreset = .last30d
    var customFrom: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    var customTo: Date = Date()

    /// Returns the half-open interval to query. Nil bounds mean unbounded.
    func interval(now: Date = Date(), calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        switch preset {
        case .last24h: return (now.addingTimeInterval(-86_400), nil)
        case .last7d: return (calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)), nil)
        case .last30d: return (calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now)), nil)
        case .last90d: return (calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: now)), nil)
        case .all: return (nil, nil)
        case .custom:
            // A custom range includes the whole of the last chosen day.
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customTo))
            return (calendar.startOfDay(for: customFrom), end)
        }
    }

    var filter: UsageFilter {
        let i = interval()
        return UsageFilter(from: i.from, to: i.to)
    }
}

struct RangePicker: View {
    @Binding var selection: RangeSelection

    var body: some View {
        HStack(spacing: 8) {
            Picker("Range", selection: $selection.preset) {
                ForEach(RangePreset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 120)
            if selection.preset == .custom {
                DatePicker("From", selection: $selection.customFrom, in: ...selection.customTo, displayedComponents: .date)
                    .labelsHidden().frame(width: 120)
                Text("to").foregroundStyle(.secondary)
                DatePicker("To", selection: $selection.customTo, in: selection.customFrom..., displayedComponents: .date)
                    .labelsHidden().frame(width: 120)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Date range")
    }
}
