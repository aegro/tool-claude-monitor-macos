import SwiftUI

// MARK: - Limit gauge

/// The hero widget. A plain "47%" tells you nothing: 47% is fine four hours into a window
/// and a disaster twenty minutes in. So the bar carries a pace marker at the utilization you
/// *could* be at right now and still land exactly on 100% at reset. Everything past that
/// marker is drawn hot: it is the part of your budget you are spending ahead of schedule.
struct LimitGauge: View {
    let window: LimitWindow
    var burn: BurnRate?
    var trail: [(Date, Double)] = []
    var dense = false

    private var target: Double { window.paceTarget }
    private var used: Double { window.utilization }
    private var critical: Bool { window.isCritical }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title)
                    .font(Type.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(Fmt.pct(used, decimals: used < 10 ? 1 : 0))
                    .font(dense ? Type.value : Type.valueBig)
                    .foregroundStyle(critical ? Ink.alarm : .primary)
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                let w = geo.size.width
                let usedX = w * min(1, used / 100)
                let targetX = w * min(1, target / 100)
                let paced = min(usedX, targetX)

                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.track)

                    // Within budget for how far into the window we are.
                    Capsule()
                        .fill(critical ? Ink.alarm.opacity(0.5) : Ink.ember.opacity(0.5))
                        .frame(width: paced)

                    // Ahead of schedule: the overshoot, at full strength.
                    if usedX > targetX {
                        Capsule()
                            .fill(critical ? Ink.alarm : Ink.ember)
                            .frame(width: usedX)
                            .mask(alignment: .leading) {
                                HStack(spacing: 0) {
                                    Color.clear.frame(width: targetX)
                                    Color.black
                                }
                            }
                    }

                    // Sustainable-pace marker.
                    if target > 0.5 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 1.5, height: 9)
                            .offset(x: max(0, targetX - 0.75))
                    }
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.22), value: used)

            HStack(spacing: 5) {
                if let reset = window.timeToReset, let at = window.resetsAt {
                    // "≈" whenever the reset was reconstructed rather than reported. It is a small
                    // mark for a real distinction: an inferred boundary can be one grid step out,
                    // and the pace marker sitting above is drawn off exactly this number.
                    Text("reseta \(window.resetIsExact ? "" : "≈")\(Fmt.clock(at)) · em \(Fmt.duration(reset))")
                        .font(Type.labelTiny)
                        .foregroundStyle(.tertiary)
                        .help(window.resetIsExact
                              ? "Horário informado pelo servidor."
                              : "Deduzido da série do app do Claude — pode variar em até 10 min.")
                }
                Spacer(minLength: 2)
                paceVerdict
            }
        }
    }

    @ViewBuilder
    private var paceVerdict: some View {
        if let ratio = window.paceRatio {
            let hot = ratio >= 1.15
            HStack(spacing: 3) {
                Image(systemName: hot ? "flame.fill" : (ratio < 0.9 ? "arrow.down.right" : "equal"))
                    .font(.system(size: 8, weight: .bold))
                Text(hot
                     ? String(format: "%.1f× o ritmo", locale: Fmt.br, ratio)
                     : (ratio < 0.9 ? "abaixo do ritmo" : "no ritmo"))
                    .font(Type.labelTiny)
            }
            .foregroundStyle(hot ? Ink.alarm : Color.secondary)
        } else {
            Text("início da janela")
                .font(Type.labelTiny)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Trails

/// Utilization over the window, drawn against the diagonal you would trace if you spent the
/// window at exactly the rate it refills. Below the line is sustainable; above it is borrowing
/// from the end of the window. That comparison is the whole point, and a bare curve cannot make it.
struct Trail: View {
    let points: [(Date, Double)]
    var span: ClosedRange<Date>?
    var height: CGFloat = 30
    var maxValue: Double = 100
    var showPaceLine = true

    var body: some View {
        Canvas { ctx, size in
            if showPaceLine, span != nil {
                var pace = Path()
                pace.move(to: CGPoint(x: 0, y: size.height))
                pace.addLine(to: CGPoint(x: size.width, y: 0))
                ctx.stroke(pace, with: .color(.secondary.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            guard points.count >= 2 else { return }
            let t0 = span?.lowerBound.timeIntervalSince1970 ?? points.first!.0.timeIntervalSince1970
            let t1 = span?.upperBound.timeIntervalSince1970 ?? points.last!.0.timeIntervalSince1970
            let dt = max(1, t1 - t0)

            func x(_ d: Date) -> CGFloat {
                CGFloat((d.timeIntervalSince1970 - t0) / dt) * size.width
            }
            func y(_ v: Double) -> CGFloat {
                size.height - CGFloat(min(1, max(0, v / maxValue))) * (size.height - 1) - 0.5
            }

            var line = Path()
            line.move(to: CGPoint(x: x(points[0].0), y: y(points[0].1)))
            for p in points.dropFirst() {
                line.addLine(to: CGPoint(x: x(p.0), y: y(p.1)))
            }

            var area = line
            area.addLine(to: CGPoint(x: x(points.last!.0), y: size.height))
            area.addLine(to: CGPoint(x: x(points[0].0), y: size.height))
            area.closeSubpath()

            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [Ink.ember.opacity(0.28), Ink.ember.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(Ink.ember), lineWidth: 1.4)

            // Where you are right now.
            let last = points.last!
            ctx.fill(Path(ellipseIn: CGRect(x: x(last.0) - 2, y: y(last.1) - 2, width: 4, height: 4)),
                     with: .color(Ink.ember))
        }
        .frame(height: height)
    }
}

/// Token volume per 5-minute slot. Bars, not a line: tokens arrive in bursts, and a line
/// would imply a continuum that is not there.
struct TokenBars: View {
    let buckets: [(Date, Int64)]
    var span: ClosedRange<Date>
    var height: CGFloat = 24

    var body: some View {
        Canvas { ctx, size in
            guard !buckets.isEmpty else { return }
            let peak = Double(buckets.map(\.1).max() ?? 1)
            guard peak > 0 else { return }
            let t0 = span.lowerBound.timeIntervalSince1970
            let dt = max(1, span.upperBound.timeIntervalSince1970 - t0)
            let slot = size.width / CGFloat(max(1, dt / 300))
            let barW = max(1.5, min(5, slot - 1))

            for (at, v) in buckets {
                let x = CGFloat((at.timeIntervalSince1970 - t0) / dt) * size.width
                let h = max(1, CGFloat(Double(v) / peak) * size.height)
                let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(Ink.ember.opacity(0.8)))
            }
        }
        .frame(height: height)
    }
}

/// Machine CPU over the last minute or so.
struct Sparkline: View {
    let values: [Double]
    var height: CGFloat = 16

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let peak = max(20, values.max() ?? 1)
            let step = size.width / CGFloat(values.count - 1)
            var p = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: CGFloat(i) * step,
                                 y: size.height - CGFloat(v / peak) * (size.height - 1) - 0.5)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            ctx.stroke(p, with: .color(Ink.load((values.last ?? 0) / 100)), lineWidth: 1.2)
        }
        .frame(height: height)
    }
}

// MARK: - Small parts

struct MiniBar: View {
    var fraction: Double
    var tint: Color?
    var width: CGFloat = 44

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Ink.track)
            Capsule()
                .fill(tint ?? Ink.load(fraction))
                .frame(width: width * min(1, max(0.02, fraction)))
        }
        .frame(width: width, height: 3)
    }
}

struct StatusDot: View {
    var busy: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(busy ? Ink.ember : Ink.idle)
            .frame(width: 5, height: 5)
            .overlay {
                if busy {
                    Circle()
                        .stroke(Ink.ember, lineWidth: 1)
                        .scaleEffect(pulse ? 2.4 : 1)
                        .opacity(pulse ? 0 : 0.55)
                }
            }
            .onAppear {
                guard busy else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}

struct SectionHead: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(Type.section)
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Type.labelTiny)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Ink.hairline).frame(height: 1)
    }
}
