import SwiftUI
import AppKit

/// Farol: a lighthouse beam is warm against a cold sea. One accent (ember) carries every
/// data mark; one alarm is held in reserve for >=90% so that seeing red actually means
/// something. Everything else is system neutral, because a menu bar panel is furniture.
enum Ink {
    static let ember = Color(nsColor: dynamic(
        light: NSColor(srgbRed: 0.85, green: 0.53, blue: 0.13, alpha: 1),
        dark:  NSColor(srgbRed: 0.98, green: 0.70, blue: 0.29, alpha: 1)
    ))

    static let alarm = Color(nsColor: dynamic(
        light: NSColor(srgbRed: 0.79, green: 0.26, blue: 0.20, alpha: 1),
        dark:  NSColor(srgbRed: 0.95, green: 0.44, blue: 0.36, alpha: 1)
    ))

    static let track = Color(nsColor: dynamic(
        light: NSColor(srgbRed: 0.09, green: 0.08, blue: 0.06, alpha: 0.09),
        dark:  NSColor(srgbRed: 1.00, green: 0.96, blue: 0.90, alpha: 0.11)
    ))

    static let idle = Color.secondary.opacity(0.42)
    static let hairline = Color.primary.opacity(0.07)

    /// A load fraction (0...1) reads neutral when idle, ember while working, alarm when critical.
    static func load(_ f: Double) -> Color {
        if f >= 0.90 { return alarm }
        if f < 0.02 { return idle }
        return ember
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

enum Type {
    static let label = Font.system(size: 11, weight: .medium)
    static let labelTiny = Font.system(size: 10, weight: .medium)
    static let value = Font.system(size: 11, weight: .semibold).monospacedDigit()
    static let valueBig = Font.system(size: 19, weight: .semibold).monospacedDigit()
    static let section = Font.system(size: 10, weight: .semibold)
    static let mono = Font.system(size: 10, weight: .regular).monospaced()
}

enum Fmt {
    static let br = Locale(identifier: "pt_BR")

    static func pct(_ v: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", locale: br, v)
    }

    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", locale: br, gb) }
        if gb >= 1 { return String(format: "%.1f GB", locale: br, gb) }
        return String(format: "%.0f MB", locale: br, Double(b) / 1_048_576)
    }

    /// "13 / 36 GB" — one unit, stated once.
    static func memPair(_ used: UInt64, _ total: UInt64) -> String {
        let u = Double(used) / 1_073_741_824
        let t = Double(total) / 1_073_741_824
        return String(format: "%.0f / %.0f GB", locale: br, u, t)
    }

    static func tokens(_ t: Int64) -> String {
        let d = Double(t)
        if d >= 1_000_000 { return String(format: "%.1f M", locale: br, d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.0f k", locale: br, d / 1_000) }
        return "\(t)"
    }

    static func rate(_ perMinute: Double) -> String {
        "\(tokens(Int64(perMinute))) tok/min"
    }

    /// 3h05 · 42 min · 40 s
    static func duration(_ s: TimeInterval) -> String {
        let total = Int(max(0, s))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return String(format: "%dh%02d", h, m) }
        if m > 0 { return "\(m) min" }
        return "\(total) s"
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = br
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// A wall-clock time that stays honest as it ages: bare "14:32" while it is still today,
    /// "24/07 14:32" once it is not. A time alone is unambiguous for an hour and quietly
    /// misleading for a week, and some of what the panel stamps is days old.
    static func stamp(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = br
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "dd/MM HH:mm"
        return f.string(from: d)
    }

    /// "há 3h05" — the one phrasing for a relative age, so the several places that show one all
    /// read the same.
    static func ago(_ d: Date, now: Date = Date()) -> String {
        "há \(duration(now.timeIntervalSince(d)))"
    }

    static func cpu(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f%%", locale: br, v)
                 : String(format: "%.1f%%", locale: br, v)
    }
}
