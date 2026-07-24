import SwiftUI

/// Multi-account chrome for the LIMITES section. The *active* account keeps the full live detail
/// (drawn in PanelView, since it needs the live burn/trail/outlook). These are the parts an
/// inactive account needs: a compact strip to stand in for it, and a last-seen detail when you
/// open it — no live rate graph, because we hold no token for an account that is parked.

/// One line summarizing a snapshot for a collapsed strip: "5h 42% · sem 63%".
func accountSummary(_ snap: UsageSnapshot) -> String {
    var parts: [String] = []
    if let s = snap.session { parts.append("5h \(Fmt.pct(s.utilization))") }
    if let w = snap.weekly { parts.append("sem \(Fmt.pct(w.utilization))") }
    return parts.joined(separator: " · ")
}

/// The tinted initial that stands in for an account avatar.
struct AccountInitial: View {
    let label: String
    var body: some View {
        Text(label.prefix(1).uppercased())
            .font(.system(size: 8.5, weight: .heavy))
            .foregroundStyle(Ink.ember)
            .frame(width: 16, height: 16)
            .background(Ink.ember.opacity(0.20), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Small plan badge ("max"), outlined in the accent.
struct PlanBadge: View {
    let plan: String
    var body: some View {
        Text(plan.uppercased())
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Ink.ember)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Ink.ember.opacity(0.45), lineWidth: 1))
    }
}

/// The lead row above an expanded account: avatar · label · plan · marker (live dot, or the age
/// of the last-seen data on the right).
struct AccountLead: View {
    let label: String
    var plan: String?
    var marker: Marker

    enum Marker { case live, lastSeen(Date) }

    var body: some View {
        HStack(spacing: 7) {
            AccountInitial(label: label)
            Text(label).font(Type.label)
            if let plan { PlanBadge(plan: plan) }
            Spacer(minLength: 4)
            switch marker {
            case .live:
                LiveDot()
            case .lastSeen(let at):
                Text("última-vista · há \(Fmt.duration(Date().timeIntervalSince(at)))")
                    .font(Type.labelTiny)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// The "● ao vivo" marker for the account whose token we actually hold.
struct LiveDot: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Ink.ember).frame(width: 5, height: 5)
            Text("ao vivo").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Ink.ember)
        }
    }
}

/// A collapsed account: one clickable strip. The active account gets a live dot; an inactive one
/// gets the age of its last-seen data. Clicking swaps which account is expanded.
struct AccountStrip: View {
    let label: String
    var plan: String?
    let summary: String
    var live: Bool
    var seenAt: Date?
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                AccountInitial(label: label)
                Text(label).font(Type.label)
                if let plan { PlanBadge(plan: plan) }
                Text(summary).font(Type.labelTiny).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if live {
                    LiveDot()
                } else if let seenAt {
                    Text("há \(Fmt.duration(Date().timeIntervalSince(seenAt)))")
                        .font(Type.labelTiny).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(hovering ? Ink.track.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A limit row from last-seen data: label, percentage, and a plain bar — no pace marker, no
/// verdict, no rate graph, because those need the live token this account does not have. The
/// first row carries the "why it is frozen" note; every row is stamped with when it was seen.
struct StaleLimitRow: View {
    let window: LimitWindow
    let seenAt: Date
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title).font(Type.label).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(Fmt.pct(window.utilization, decimals: window.utilization < 10 ? 1 : 0))
                    .font(Type.value)
                    .foregroundStyle(window.isCritical ? Ink.alarm : .primary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.track)
                    Capsule()
                        .fill((window.isCritical ? Ink.alarm : Ink.ember).opacity(0.55))
                        .frame(width: geo.size.width * min(1, window.utilization / 100))
                }
            }
            .frame(height: 5)

            HStack(spacing: 5) {
                Text("visto \(Fmt.clock(seenAt))").font(Type.labelTiny).foregroundStyle(.tertiary)
                Spacer(minLength: 2)
                if let note { Text(note).font(Type.labelTiny).foregroundStyle(.tertiary) }
            }
        }
    }
}
