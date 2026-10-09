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
        let hot = !showCPU && monitor.system.cpuPercent > 60
        let attention = monitor.access.attention > 0
        let art = MenuBarArt.Content(
            ring: window.map {
                MenuBarArt.Ring(fraction: $0.utilization / 100,
                                // Something to look at in the panel: the Mac held awake, Acessos waiting, a hot CPU.
                                dot: keep.active || attention || hot)
            },
            gauge: showLimit && window == nil,
            number: window.map { "\(Int($0.utilization.rounded()))" },
            // Off the head of the queue, the menu bar says which account new sessions open on.
            monogram: showLimit ? monitor.menuBarMonogram : nil,
            cpu: showCPU ? "\(Int(monitor.system.cpuPercent.rounded()))%" : nil,
            tint: Self.tint(alarmed(reading), window: window),
            muted: window != nil && !current)
        Image(nsImage: MenuBarArt.make(art))
            .help(helpText(reading, window: window, hot: hot, attention: attention))
            .accessibilityLabel(art.spoken)
    }

    /// The label is a number in a ring; the tooltip says in words what it is and what the dot stands for.
    private func helpText(_ reading: Monitor.MenuBarReading, window: LimitWindow?, hot: Bool, attention: Bool) -> String {
        var lines: [String] = []
        if let window {
            var line = "\(Int(window.utilization.rounded())) % da janela de 5h"
            if let reset = window.resetsAt { line += ", renova às \(Fmt.clock(reset))" }
            lines.append(line)
            if !reading.current { lines.append(staleHelp(reading)) }
        }
        if keep.active { lines.append(keep.stateText) }
        if attention { lines.append("Acessos precisa de você") }
        if hot { lines.append("CPU acima de 60 %") }
        return lines.joined(separator: "\n")
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
        /// A small dot at the top right: the Mac held awake, Acessos waiting, or a hot CPU.
        var dot: Bool
    }

    struct Content: Equatable {
        var ring: Ring?
        var gauge = false
        /// The share of the 5h window, drawn inside the ring.
        var number: String?
        var monogram: String?
        var cpu: String?
        var tint: NSColor?
        var muted = false

        var spoken: String {
            [number.map { "limite de 5h em \($0) por cento" }, monogram.map { "conta \($0)" },
             cpu.map { "CPU \($0)" }].compactMap { $0 }.joined(separator: ", ")
        }
    }

    static let height: CGFloat = 20
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    static let badgeFont = NSFont.systemFont(ofSize: 9, weight: .bold)
    static let ringSide: CGFloat = 20

    static func make(_ c: Content) -> NSImage {
        let ink = c.tint ?? .black
        let alpha: CGFloat = c.muted ? 0.5 : 1
        let gap: CGFloat = 4
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
        if let ring = c.ring {
            parts.append((ringSide, { x in drawRing(ring, number: c.number, at: x, ink: ink, alpha: alpha) }))
        }
        glyph(gauge)
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

    /// The share of the 5h window as a number inside a ring filled to it: the ring reads as the gauge of the number
    /// it holds, which the ring alone, beside a separate percentage, did not. The pace shows as the colour (ember),
    /// so there is no tick to compete with the digits.
    private static func drawRing(_ ring: Ring, number: String?, at x: CGFloat, ink: NSColor, alpha: CGFloat) {
        let line: CGFloat = 1.8
        let rect = NSRect(x: x + line / 2 + 0.2, y: (height - ringSide) / 2 + line / 2 + 0.2,
                          width: ringSide - line - 0.4, height: ringSide - line - 0.4)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = line
        ink.withAlphaComponent(0.3 * alpha).setStroke()
        track.stroke()
        if ring.fraction > 0.005 {
            // Clockwise from 12 o'clock. AppKit angles run counter-clockwise from 3 o'clock.
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * min(1, ring.fraction),
                          clockwise: true)
            arc.lineWidth = line
            arc.lineCapStyle = .round
            ink.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }
        if let number {
            // Two digits fit at 9 pt; "100" steps down so it stays inside the ring.
            let size: CGFloat = number.count > 2 ? 7 : 9
            let digits = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            let text = NSAttributedString(string: number, attributes: [.font: digits, .foregroundColor: ink.withAlphaComponent(alpha)])
            let w = text.size().width
            text.draw(at: NSPoint(x: center.x - w / 2, y: center.y - digits.capHeight / 2 + digits.descender))
        }
        if ring.dot {
            // Cut out of the ring first, so the dot reads apart from the arc on either menu bar.
            let spot = NSRect(x: x + ringSide - 6, y: (height + ringSide) / 2 - 6, width: 6, height: 6)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: spot.insetBy(dx: -1, dy: -1)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            ink.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: spot).fill()
        }
    }
}

