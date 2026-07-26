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

/// A collapsed account: one strip. The active account gets a live dot; an inactive one gets the
/// age of its last-seen data. Clicking swaps which account is expanded — except for a strip with
/// no `onTap`, which is all there is to show (see `DesktopOrgStrip`).
struct AccountStrip: View {
    let label: String
    var plan: String?
    let summary: String
    var live: Bool
    var seenAt: Date?
    var trailingIcon = "chevron.right"
    var onTap: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        if let onTap {
            Button(action: onTap) { strip }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
        } else {
            strip
        }
    }

    private var strip: some View {
        Group {
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
                Image(systemName: trailingIcon)
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
    }
}

/// An organization the Monitor only knows about through the desktop app. It cannot expand: the
/// desktop app records the two headline percentages and nothing else, so the strip already shows
/// everything there is. The window icon says where the number came from, and the tooltip says why
/// it stops there.
struct DesktopOrgStrip: View {
    let org: DesktopOrgUsage

    var body: some View {
        AccountStrip(
            label: org.label,
            plan: org.plan,
            summary: "5h \(Fmt.pct(org.fiveHour)) · sem \(Fmt.pct(org.weekly))",
            live: false,
            seenAt: org.seenAt,
            trailingIcon: "macwindow"
        )
        .help("""
              Organização vista no app do Claude, não no terminal. \
              O app registra só estas duas porcentagens, então não há detalhe para abrir. \
              Entre nela pelo `claude` no terminal para acompanhá-la ao vivo.
              """)
    }
}

/// Which feeds are answering, how fresh each one is, and — when one is not — the one control that
/// might fix it.
///
/// Drawn always, healthy or not. The failure it replaces was a feed that died silently behind a
/// cached snapshot: the numbers froze, the live dot stayed lit, and the only tell was a timestamp
/// creeping upwards. A bar that appears only in trouble is a bar nobody learns to read, so this
/// one is permanent and the reading is always the same: filled dot = these are the numbers above.
struct FeedBar: View {
    let feeds: FeedState
    /// Which feed the panel is currently drawing from, if any.
    let feeding: UsageSource?
    var detail: String?
    var onRetry: () -> Void

    private var anythingBroken: Bool {
        if case .broken = feeds.terminal { return true }
        if case .broken = feeds.desktop { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            chip("terminal", feeds.terminal, feeding: feeding == .api)
            chip("app", feeds.desktop, feeding: feeding == .desktopApp)
            Spacer(minLength: 4)
            if anythingBroken {
                Button("tentar de novo", action: onRetry)
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Ink.ember)
                    .help(detail ?? "Relê a credencial e consulta a API de novo.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Ink.track, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func chip(_ name: String, _ health: FeedState.Health, feeding: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone(health))
                .opacity(feeding ? 1 : 0.35)
                .frame(width: 5, height: 5)
            Text(name)
                .font(.system(size: 9.5, weight: .medium).monospaced())
                .foregroundStyle(.tertiary)
            Text(caption(health))
                .font(Type.labelTiny)
                .foregroundStyle(isBroken(health) ? AnyShapeStyle(Ink.alarm) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fonte \(name): \(caption(health))\(feeding ? ", é a que está alimentando o painel" : "")")
    }

    private func isBroken(_ h: FeedState.Health) -> Bool {
        if case .broken = h { return true }
        return false
    }

    private func tone(_ h: FeedState.Health) -> Color {
        switch h {
        case .live: return Ink.ember
        case .stale: return Ink.idle
        case .broken: return Ink.alarm
        case .missing: return Ink.idle
        }
    }

    private func caption(_ h: FeedState.Health) -> String {
        switch h {
        case .live(let at), .stale(let at): return "há \(Fmt.duration(Date().timeIntervalSince(at)))"
        case .broken(let why): return why
        case .missing: return "—"
        }
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
