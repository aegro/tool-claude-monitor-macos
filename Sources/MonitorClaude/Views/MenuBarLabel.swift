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

    private var session: LimitWindow? { monitor.usage?.session }
    private var showLimit: Bool { settings.menuBarStyle != .cpu }
    private var showCPU: Bool { settings.menuBarStyle != .sessionLimit }

    private var tone: Color {
        guard let session else { return .secondary }
        if session.isCritical { return Ink.alarm }
        if case .willHitCap(_, _, _, _, true) = monitor.outlook { return Ink.alarm }
        if (session.paceRatio ?? 0) >= 1.15 { return Ink.ember }
        return .primary
    }

    private var nsTone: NSColor {
        guard let session else { return .secondaryLabelColor }
        if session.isCritical { return NSColor(Ink.alarm) }
        if case .willHitCap(_, _, _, _, true) = monitor.outlook { return NSColor(Ink.alarm) }
        if (session.paceRatio ?? 0) >= 1.15 { return NSColor(Ink.ember) }
        return .labelColor
    }

    var body: some View {
        HStack(spacing: 4) {
            if showLimit, let session {
                Image(nsImage: RingIcon.make(
                    fraction: session.utilization / 100,
                    pace: session.paceTarget / 100,
                    tint: nsTone,
                    hot: showCPU ? false : monitor.system.cpuPercent > 60
                ))
                Text("\(Int(session.utilization.rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(tone)
            } else if showLimit {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }

            if showCPU {
                if showLimit { Text("·").foregroundStyle(.tertiary) }
                Image(systemName: "cpu").font(.system(size: 10))
                Text("\(Int(monitor.system.cpuPercent.rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(monitor.system.cpuPercent > 80 ? tone : .primary)
            }
        }
    }
}

enum RingIcon {
    /// A ring filled to the limit used, with a notch at the sustainable pace and, when the
    /// machine is loaded, an ember dot at the corner.
    static func make(fraction: Double, pace: Double, tint: NSColor, hot: Bool) -> NSImage {
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

        return image
    }
}
