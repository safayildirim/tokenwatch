import Foundation
import UsageCore

/// This type formats numbers, durations and dates for every screen.
public enum Fmt {
    /// A compact token count such as 1.2B, 34.5M, 6.7K or 890.
    public static func tokens(_ n: Int64) -> String {
        let v = Double(abs(n))
        let sign = n < 0 ? "-" : ""
        switch v {
        case 1e12...: return sign + trim(v / 1e12) + "T"
        case 1e9...: return sign + trim(v / 1e9) + "B"
        case 1e6...: return sign + trim(v / 1e6) + "M"
        case 1e4...: return sign + trim(v / 1e3) + "K"
        default: return sign + grouped(abs(n))
        }
    }

    private static func trim(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f", v) : (v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v))
    }

    public static func grouped(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    public static func percent(_ v: Double?, digits: Int = 0) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f%%", v)
    }

    public static func ratio(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f%%", v * 100)
    }

    /// Formats an API-equivalent cost. A trailing "+" marks a lower bound caused by unpriced models.
    public static func cost(_ c: EstimatedCost, showPartial: Bool = true) -> String {
        if c.picoUSD == 0 && c.unpricedTokens > 0 { return "unpriced" }
        let usd = c.usdDouble
        let text: String
        switch usd {
        // Large amounts use a K or M suffix rather than a grouping separator, because "$5.586" would be
        // read as five dollars in locales that use a comma for grouping, and as five thousand in others.
        case 1_000_000...: text = String(format: "$%.2fM", usd / 1_000_000)
        case 1000...: text = String(format: "$%.2fK", usd / 1000)
        case 10...: text = String(format: "$%.2f", usd)
        case 0.01...: text = String(format: "$%.3f", usd)
        case 0: text = "$0"
        default: text = String(format: "$%.4f", usd)
        }
        return c.isPartial && showPartial ? text + "+" : text
    }

    public static func duration(_ t: TimeInterval) -> String {
        let s = Int(max(0, t).rounded())
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    public static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let age = now.timeIntervalSince(date)
        if age < 45 { return "just now" }
        if age < 0 { return "in " + duration(-age) }
        return duration(age) + " ago"
    }

    public static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    public static func applicationName(_ raw: String?) -> String {
        switch raw {
        case "cli": "Terminal"
        case "claude-vscode": "VS Code"
        case "claude-desktop": "Claude Desktop"
        case let other?: other
        case nil: "—"
        }
    }

    public static func applicationSymbol(_ raw: String?) -> String {
        switch raw {
        case "cli": "terminal"
        case "claude-vscode": "chevron.left.forwardslash.chevron.right"
        case "claude-desktop": "macwindow"
        default: "questionmark.app"
        }
    }
}
