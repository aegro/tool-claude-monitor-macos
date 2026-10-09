import SwiftUI

/// A limit row from last-seen data: label, percentage, and a plain bar — no pace marker, no
/// verdict, no rate graph, because those need the live token this account does not have. The
/// first row carries the "why it is frozen" note; every row is stamped with when it was seen.
struct StaleLimitRow: View {
    let window: LimitWindow
    let seenAt: Date
    var note: String?

    private var renewed: Bool { window.hasReset() }

    /// The left caption only carries "visto" when there is no reset time, so with one the stamp moves here,
    /// next to the note, and every row keeps saying when it was seen.
    private var trailingCaption: String? {
        guard window.resetsAt != nil else { return note }
        return [note, "visto \(Fmt.stamp(seenAt))"].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title).font(Type.label).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(renewed ? "—" : Fmt.pct(window.utilization, decimals: window.utilization < 10 ? 1 : 0))
                    .font(Type.value)
                    .foregroundStyle(renewed ? AnyShapeStyle(.tertiary)
                                             : AnyShapeStyle(window.isCritical ? Ink.alarm : Color.primary))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.track)
                    Capsule()
                        .fill((window.isCritical ? Ink.alarm : Ink.ember).opacity(0.55))
                        .frame(width: renewed ? 0 : geo.size.width * min(1, window.utilization / 100))
                }
            }
            .frame(height: 5)

            HStack(spacing: 5) {
                if renewed, let at = window.resetsAt {
                    Text("renovou às \(Fmt.clock(at))").font(Type.labelTiny).foregroundStyle(.tertiary)
                } else if window.resetsAt != nil {
                    ResetCaption(window: window)
                } else {
                    Text("visto \(Fmt.stamp(seenAt))").font(Type.labelTiny).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 2)
                if let trailing = trailingCaption {
                    Text(trailing).font(Type.labelTiny).foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
    }
}
