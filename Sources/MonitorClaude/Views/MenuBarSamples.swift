import SwiftUI
import AppKit

/// The menu bar label's states drawn on a light and a dark menu bar strip, next to text set like the clock, for
/// `--render=menubar`: the place to check that the ring, the number and the badge sit on one line.
struct MenuBarSamples: View {
    private let samples: [(String, MenuBarArt.Content)] = [
        ("normal", .init(ring: .init(fraction: 0.24, dot: false), number: "24")),
        ("desperto + outra conta", .init(ring: .init(fraction: 0.62, dot: true), number: "62", monogram: "SC")),
        ("ritmo alto", .init(ring: .init(fraction: 0.71, dot: false), number: "71", tint: NSColor(Ink.ember))),
        ("parado", .init(ring: .init(fraction: 0.4, dot: false), number: "40", muted: true)),
        ("perto do limite", .init(ring: .init(fraction: 0.97, dot: false), number: "97", tint: NSColor(Ink.alarm))),
        ("esgotada", .init(ring: .init(fraction: 1, dot: false), number: "100", tint: NSColor(Ink.alarm))),
        ("com CPU", .init(ring: .init(fraction: 0.24, dot: false), number: "24", cpu: "35%")),
        ("só CPU, desperto", .init(cpu: "35%", loneDot: true)),
    ]

    var body: some View {
        VStack(spacing: 10) {
            strip(dark: false)
            strip(dark: true)
        }
        .padding(12)
    }

    private func strip(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                HStack(spacing: 14) {
                    Image(nsImage: MenuBarArt.make(sample.1))
                        .renderingMode(sample.1.tint == nil ? .template : .original)
                        .foregroundStyle(dark ? .white : .black)
                    Text("Fri 9 Oct 18:14").font(.system(size: 13))
                        .foregroundStyle(dark ? .white : .black)
                    Spacer()
                    Text(sample.0).font(.caption).foregroundStyle(.gray)
                }
                .frame(height: 24)
            }
        }
        .padding(.horizontal, 10)
        .background(dark ? Color(white: 0.16) : Color(white: 0.93), in: RoundedRectangle(cornerRadius: 6))
    }
}
