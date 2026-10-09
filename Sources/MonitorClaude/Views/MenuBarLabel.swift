import SwiftUI
import AppKit

/// The menu bar is not a dashboard, it is an ambient alarm. It shows the one number with
/// consequences (how much of the 5h window is gone) plus a notch at the pace you could
/// sustain, and marks the machine only when it is actually hot. Everything else waits
/// for a click.
///
/// MenuBarExtra renders only Text and Image in its label, so the ring is drawn into an
/// NSImage rather than a Canvas, which silently draws nothing up there.
struct MenuBarLabel: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var keep = KeepAwake.shared

    private var showLimit: Bool { settings.menuBarStyle != .cpu }
    private var showCPU: Bool { settings.menuBarStyle != .sessionLimit }

    /// The panel can explain itself; the menu bar has about twelve points of width. So a number
    /// that is no longer current is drawn muted and suffixed with "·" rather than pretending —
    /// this is the surface that sat for twenty-one hours reporting a dead feed's percentage in
    /// exactly the same ink as a live one.
    private func staleHelp(_ reading: Monitor.MenuBarReading) -> String {
        let age = reading.seenAt.map { " (\(Fmt.ago($0)))" } ?? ""
        return "Número parado\(age) — abra o painel para ver qual fonte caiu."
    }

    /// Alarm only from what describes the number shown: its own window, and the pace forecast only when that
    /// forecast is about this account (the live one).
    private func alarmed(_ reading: Monitor.MenuBarReading) -> Bool? {
        guard let session = reading.window, reading.current else { return nil }
        if session.isCritical { return true }
        if reading.isLive, case .willHitCap(_, _, _, _, true) = monitor.outlook { return true }
        return false
    }

    var body: some View {
        let reading = monitor.menuBarSession
        let current = reading.current
        let window = showLimit ? reading.window : nil
        let art = MenuBarArt.Content(
            sun: keep.active ? (keep.lidClosed ? "sun.max.fill" : "sun.max") : nil,
            ring: window.map {
                // No pace notch on a stale number: the notch advances with the clock while the percentage stands
                // still, so it would keep drawing a verdict about a reading that stopped moving hours ago.
                MenuBarArt.Ring(fraction: $0.utilization / 100, pace: current ? $0.paceTarget / 100 : 0,
                                hot: showCPU ? false : monitor.system.cpuPercent > 60,
                                alert: monitor.access.attention > 0)
            },
            gauge: showLimit && window == nil,
            percent: window.map { "\(Int($0.utilization.rounded()))%" },
            // Off the head of the queue, the menu bar says which account new sessions open on.
            monogram: showLimit ? monitor.menuBarMonogram : nil,
            cpu: showCPU ? "\(Int(monitor.system.cpuPercent.rounded()))%" : nil,
            tint: Self.tint(alarmed(reading), window: window),
            muted: window != nil && !current)
        Image(nsImage: MenuBarArt.make(art))
            .modifier(StaleHint(text: window != nil && !current ? staleHelp(reading)
                                                                  : (keep.active ? keep.stateText : nil)))
            .accessibilityLabel(art.spoken)
    }

    /// nil draws the label as a template, in the menu bar's own ink like the system items; a color only for the
    /// states that must stand out (the limit about to hit, a pace above the sustainable).
    private static func tint(_ alarm: Bool?, window: LimitWindow?) -> NSColor? {
        guard let alarm, let window else { return nil }
        if alarm { return NSColor(Ink.alarm) }
        if (window.paceRatio ?? 0) >= 1.15 { return NSColor(Ink.ember) }
        return nil
    }
}

/// The whole menu bar label drawn as one image: SwiftUI lays a `Text` next to an `Image` in the status bar on its
/// own baseline, a point or two off the icon's centre, and an image drawn with `labelColor` resolves to the app's
/// appearance, not the menu bar's, so the ring could vanish on a dark menu bar. One template image (black, with
/// alpha) takes the menu bar's ink exactly like the system items, and every piece is centred on the same line.
enum MenuBarArt {
    struct Ring: Equatable {
        var fraction: Double
        var pace: Double
        var hot: Bool
        var alert: Bool
    }

    struct Content: Equatable {
        var sun: String?
        var ring: Ring?
        var gauge = false
        var percent: String?
        var monogram: String?
        var cpu: String?
        var tint: NSColor?
        var muted = false

        var spoken: String {
            [sun != nil ? "Mac desperto" : nil, percent.map { "limite de 5h em \($0)" }, monogram.map { "conta \($0)" },
             cpu.map { "CPU \($0)" }].compactMap { $0 }.joined(separator: ", ")
        }
    }

    static let height: CGFloat = 18
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    static let badgeFont = NSFont.systemFont(ofSize: 9, weight: .bold)

    static func make(_ c: Content) -> NSImage {
        let ink = c.tint ?? .black
        let alpha: CGFloat = c.muted ? 0.5 : 1
        let gap: CGFloat = 4
        let ringSide: CGFloat = 16
        let text: (String) -> NSAttributedString = {
            NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(alpha)])
        }
        let badge = c.monogram.map {
            NSAttributedString(string: $0, attributes: [.font: badgeFont, .foregroundColor: ink.withAlphaComponent(alpha)])
        }
        func symbol(_ name: String, size: CGFloat) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        }
        let sun = c.sun.flatMap { symbol($0, size: 12) }
        let gauge = c.gauge ? symbol("gauge.with.dots.needle.33percent", size: 13) : nil
        let chip = c.cpu != nil ? symbol("cpu", size: 12) : nil

        // Lay out first, then draw at the measured widths.
        var parts: [(width: CGFloat, draw: (CGFloat) -> Void)] = []
        func glyph(_ image: NSImage?) {
            guard let image else { return }
            parts.append((image.size.width, { x in
                let r = NSRect(x: x, y: (height - image.size.height) / 2, width: image.size.width, height: image.size.height)
                tinted(image, ink.withAlphaComponent(alpha)).draw(in: r)
            }))
        }
        func label(_ string: NSAttributedString) {
            let size = string.size()
            parts.append((ceil(size.width), { x in
                // Centred on the cap height, the way the clock and the battery percentage sit.
                let baseline = (height - font.capHeight) / 2
                string.draw(at: NSPoint(x: x, y: baseline + font.descender))
            }))
        }
        glyph(sun)
        if let ring = c.ring {
            parts.append((ring.hot ? ringSide + 5 : ringSide, { x in drawRing(ring, at: x, side: ringSide, ink: ink, alpha: alpha) }))
        }
        glyph(gauge)
        if let percent = c.percent { label(text(percent)) }
        if let badge {
            let size = badge.size()
            let w = ceil(size.width) + 6
            parts.append((w, { x in
                let r = NSRect(x: x, y: (height - 13) / 2, width: w, height: 13)
                let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
                ink.withAlphaComponent(alpha * 0.8).setStroke()
                box.lineWidth = 1
                box.stroke()
                badge.draw(at: NSPoint(x: r.minX + 3, y: r.midY - badgeFont.capHeight / 2 + badgeFont.descender))
            }))
        }
        if let cpu = c.cpu {
            glyph(chip)
            label(text(cpu))
        }

        let width = max(1, parts.map(\.width).reduce(0, +) + gap * CGFloat(max(0, parts.count - 1)))
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                part.draw(x)
                x += part.width + gap
            }
            return true
        }
        image.isTemplate = c.tint == nil
        return image
    }

    private static func tinted(_ symbol: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// A ring filled to the limit used, a notch at the sustainable pace, an ember dot when the machine is loaded
    /// and a small dot at the top right when something in Acessos needs the person.
    private static func drawRing(_ ring: Ring, at x: CGFloat, side: CGFloat, ink: NSColor, alpha: CGFloat) {
        let rect = NSRect(x: x + 1.5, y: (height - side) / 2 + 1.5, width: side - 3, height: side - 3)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2
        ink.withAlphaComponent(0.35 * alpha).setStroke()
        track.stroke()
        if ring.fraction > 0.005 {
            // Clockwise from 12 o'clock. AppKit angles run counter-clockwise from 3 o'clock.
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * min(1, ring.fraction),
                          clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            ink.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }
        if ring.pace > 0.02, ring.pace < 0.99 {
            let a = (90 - 360 * ring.pace) * .pi / 180
            let notch = NSBezierPath()
            // A short tick inside the ring, like a clock hand's tip: crossing the stroke outwards it read as a "Q".
            notch.move(to: NSPoint(x: center.x + cos(a) * (radius - 4), y: center.y + sin(a) * (radius - 4)))
            notch.line(to: NSPoint(x: center.x + cos(a) * (radius - 1), y: center.y + sin(a) * (radius - 1)))
            notch.lineWidth = 1.5
            notch.lineCapStyle = .round
            ink.withAlphaComponent(0.9 * alpha).setStroke()
            notch.stroke()
        }
        if ring.hot {
            ink.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x + side + 1, y: height / 2 - 1.75, width: 3.5, height: 3.5)).fill()
        }
        if ring.alert {
            ink.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x + side - 5, y: (height + side) / 2 - 5, width: 5, height: 5)).fill()
        }
    }
}

/// Attaches a tooltip only when there is something to say — `.help("")` still arms a tooltip, and
/// an empty one that appears on hover over a perfectly healthy number is its own small lie.
private struct StaleHint: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text).accessibilityHint(text)
        } else {
            content
        }
    }
}

