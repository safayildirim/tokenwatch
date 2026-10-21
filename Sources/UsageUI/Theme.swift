import SwiftUI
import AppKit
import UsageCore

extension Color {
    /// This creates a color with separate values for the light and dark appearance, which the system resolves.
    init(light: UInt32, dark: UInt32) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// This is the chart palette: eight categorical slots in a fixed order, each stepped separately for light
/// and dark surfaces and checked for color-vision-deficiency separation between neighbouring slots.
/// Colors follow the entity they identify, never its rank, so filtering never repaints a series.
public enum Palette {
    public static let series: [Color] = [
        Color(light: 0x2a78d6, dark: 0x3987e5),   // blue
        Color(light: 0xeb6834, dark: 0xd95926),   // orange
        Color(light: 0x1baf7a, dark: 0x199e70),   // aqua
        Color(light: 0xeda100, dark: 0xc98500),   // yellow
        Color(light: 0xe87ba4, dark: 0xd55181),   // magenta
        Color(light: 0x008300, dark: 0x008300),   // green
        Color(light: 0x6250d6, dark: 0x9085e9),   // violet
        Color(light: 0xe34948, dark: 0xe66767),   // red
    ]
    public static let other = Color(light: 0x8a8984, dark: 0x8d8c86)

    // Token categories always use the same slots.
    public static let uncachedInput = series[0]
    public static let output = series[1]
    public static let cacheRead = series[2]
    public static let cacheWrite = series[3]

    // Status colors are reserved for state and always travel with an icon and a label.
    public static let good = Color(light: 0x0ca30c, dark: 0x0ca30c)
    public static let warning = Color(light: 0xc27f00, dark: 0xfab219)
    public static let serious = Color(light: 0xd2582d, dark: 0xec835a)
    public static let critical = Color(light: 0xd03b3b, dark: 0xe0605f)

    public static let gridLine = Color(light: 0xe4e3df, dark: 0x34342f)
    public static let track = Color(light: 0xe9e8e4, dark: 0x36362f)

    /// The ground of a panel inside a card, and of a row in a list.
    public static let inset = Color(light: 0xf5f5f4, dark: 0x262625)
    public static let insetHover = Color(light: 0xececeb, dark: 0x2f2f2e)
    /// The chosen segment of a segmented control.
    public static let segmentOn = Color(light: 0xffffff, dark: 0x5b5b5f)

    /// Providers take the slots that models and projects reach last, in the registry's order, so a provider keeps its
    /// color on every page and is rarely mistaken for the first models or projects.
    static let providerSlots = [1, 6, 2, 4, 3, 7, 5, 0]
    public static func provider(at index: Int) -> Color {
        index >= 0 && index < providerSlots.count ? series[providerSlots[index]] : other
    }

    public static func status(_ state: SessionState) -> Color {
        switch state {
        case .active: good
        case .idle: warning
        case .completed: Color.secondary
        case .unknown: Color.secondary.opacity(0.6)
        }
    }

    /// Returns the fill for a quota bar. It changes with how much of the allowance is used.
    public static func quota(_ percent: Double) -> Color {
        percent >= 90 ? critical : (percent >= 75 ? serious : series[0])
    }
}

/// Keeps a stable color for each model or project: the first one seen takes slot one, and so on.
/// The assignment is remembered, so a color never changes meaning between launches.
@MainActor
public final class ChartColors {
    public static let shared = ChartColors()
    private var slots: [String: Int]
    private let defaultsKey = "chartColorSlots.v2"

    private init() {
        slots = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int]) ?? [:]
    }

    /// Returns the color for a model, project or other entity. Each kind of entity (the part of the key before
    /// a colon, `model` when there is none) hands out the palette's slots independently, so a long
    /// list of projects can never use up the colors that models rely on.
    public func color(for key: String) -> Color {
        let namespace = key.firstIndex(of: ":").map { String(key[..<$0]) } ?? "model"
        let slot: Int
        if let existing = slots[key] { slot = existing }
        else {
            slot = slots.keys.filter { namespaceOf($0) == namespace }.count
            slots[key] = slot
            UserDefaults.standard.set(slots, forKey: defaultsKey)
        }
        return slot < Palette.series.count ? Palette.series[slot] : Self.extended(slot)
    }

    /// A color for the slots beyond the palette. Each gets its own hue, spaced by the golden angle so that neighbours
    /// stay apart however many there are, with the lightness stepped separately for light and dark surfaces. Falling
    /// back to one grey would make every entity past the eighth look the same.
    static func extended(_ slot: Int) -> Color {
        let hue = (0.07 + Double(slot - Palette.series.count) * 0.381966).truncatingRemainder(dividingBy: 1)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hue: hue, saturation: 0.62, brightness: dark ? 0.86 : 0.74, alpha: 1)
        })
    }

    private func namespaceOf(_ key: String) -> String {
        key.firstIndex(of: ":").map { String(key[..<$0]) } ?? "model"
    }
}

// MARK: Shared components

struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

struct KPITile: View {
    var title: String
    var value: String
    var detail: String?
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

struct StatusBadge: View {
    var status: SessionStatus
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(Palette.status(status.state))
            Text(status.state.label).font(.caption)
            if status.basis == .inferred && status.state != .unknown {
                Image(systemName: "questionmark.circle").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help("Inferred from how recently the session wrote to its log. No running process was observed.")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(status.state.label), \(status.basis.rawValue)")
    }

    private var icon: String {
        switch status.state {
        case .active: "circle.fill"
        case .idle: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct LegendDot: View {
    var color: Color
    var label: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding()
    }
}
