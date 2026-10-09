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

    private func tone(_ reading: Monitor.MenuBarReading) -> Color {
        guard let alarm = alarmed(reading), let session = reading.window else { return .secondary }
        if alarm { return Ink.alarm }
        if (session.paceRatio ?? 0) >= 1.15 { return Ink.ember }
        return .primary
    }

    private func nsTone(_ reading: Monitor.MenuBarReading) -> NSColor {
        guard let alarm = alarmed(reading), let session = reading.window else { return .secondaryLabelColor }
        if alarm { return NSColor(Ink.alarm) }
        if (session.paceRatio ?? 0) >= 1.15 { return NSColor(Ink.ember) }
        return .labelColor
    }

    var body: some View {
        let reading = monitor.menuBarSession
        let current = reading.current
        HStack(spacing: 4) {
            if keep.active {
                Image(systemName: keep.lidClosed ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.ember)
                    .help(keep.stateText)
            }

            if showLimit, let session = reading.window {
                Image(nsImage: RingIcon.make(
                    fraction: session.utilization / 100,
                    // No pace notch on a stale number: the notch advances with the clock while the
                    // percentage stands still, so it would keep drawing a verdict about a reading
                    // that stopped moving hours ago.
                    pace: current ? session.paceTarget / 100 : 0,
                    tint: nsTone(reading),
                    hot: showCPU ? false : monitor.system.cpuPercent > 60,
                    alert: monitor.access.attention > 0
                ))
                Text("\(Int(session.utilization.rounded()))%\(current ? "" : "·")")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(tone(reading))
                    .modifier(StaleHint(text: current ? nil : staleHelp(reading)))
                // Off the head of the queue, the menu bar says which account new sessions open on.
                if let monogram = monitor.menuBarMonogram {
                    Text(monogram)
                        .font(.system(size: 9.5, weight: .bold))
                        .help("Sessões novas abrem nesta conta")
                }
            } else if showLimit {
                Image(systemName: "gauge.with.dots.needle.33percent")
                if let monogram = monitor.menuBarMonogram {
                    Text(monogram).font(.system(size: 9.5, weight: .bold)).help("Sessões novas abrem nesta conta")
                }
            }

            if showCPU {
                if showLimit { Text("·").foregroundStyle(.tertiary) }
                Image(systemName: "cpu").font(.system(size: 10))
                Text("\(Int(monitor.system.cpuPercent.rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    // The machine's own heat, in the ember the ring uses for a loaded machine: the limit reading's
                    // tone says nothing about the CPU, and muted it would hide the load at its peak.
                    .foregroundStyle(monitor.system.cpuPercent > 80 ? Ink.ember : .primary)
            }
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

enum RingIcon {
    /// A ring filled to the limit used, with a notch at the sustainable pace and, when the
    /// machine is loaded, an ember dot at the corner.
    static func make(fraction: Double, pace: Double, tint: NSColor, hot: Bool, alert: Bool = false) -> NSImage {
        let side: CGFloat = 15
        let image = NSImage(size: NSSize(width: hot ? side + 5 : side, height: side))

        image.lockFocus()
        defer { image.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high

        let inset: CGFloat = 2
        let rect = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 1.8
        tint.withAlphaComponent(0.25).setStroke()
        track.stroke()

        if fraction > 0.005 {
            // Clockwise from 12 o'clock. AppKit angles run counter-clockwise from 3 o'clock.
            let sweep = 360 * min(1, fraction)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            arc.lineWidth = 1.8
            arc.lineCapStyle = .round
            tint.setStroke()
            arc.stroke()
        }

        if pace > 0.02, pace < 0.99 {
            let a = (90 - 360 * pace) * .pi / 180
            let notch = NSBezierPath()
            notch.move(to: NSPoint(x: center.x + cos(a) * (radius - 2),
                                   y: center.y + sin(a) * (radius - 2)))
            notch.line(to: NSPoint(x: center.x + cos(a) * (radius + 2),
                                   y: center.y + sin(a) * (radius + 2)))
            notch.lineWidth = 1
            tint.withAlphaComponent(0.85).setStroke()
            notch.stroke()
        }

        if hot {
            let dot = NSBezierPath(ovalIn: NSRect(x: side + 0.5, y: side / 2 - 1.75,
                                                  width: 3.5, height: 3.5))
            NSColor(Ink.ember).setFill()
            dot.fill()
        }

        // Something in Acessos needs the person: a small dot at the ring's top right.
        if alert {
            let dot = NSBezierPath(ovalIn: NSRect(x: side - 5, y: side - 5, width: 5, height: 5))
            NSColor(Ink.ember).setFill()
            dot.fill()
        }

        return image
    }
}
