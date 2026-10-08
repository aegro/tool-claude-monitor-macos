import SwiftUI
import AppKit

/// Pieces the three panes share: the tab control, the account avatar and chips, the compact limit bar, the status
/// block at the top of a pane, and a wrapping row for the "em dia" chips.

enum PanelTab: String, CaseIterable, Identifiable {
    case accounts, sessions, access
    var id: String { rawValue }
    var label: String {
        switch self {
        case .accounts: return "Contas"
        case .sessions: return "Sessões"
        case .access: return "Acessos"
        }
    }
}

struct PanelTabs: View {
    @Binding var selection: PanelTab
    var dot: Set<PanelTab> = []

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = tab }
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.label).font(.system(size: 12, weight: .medium))
                        if dot.contains(tab) {
                            Circle().fill(Ink.ember).frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 3.5)
                    .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.12), radius: 0.8, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dot.contains(tab) ? "\(tab.label), pede atenção" : tab.label)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Ink.track, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Avatar: View {
    let monogram: String
    var active = false
    var size: CGFloat = 24

    var body: some View {
        Text(monogram)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(active ? Ink.ember : Color.secondary)
            .frame(width: size, height: size)
            .background(active ? Ink.ember.opacity(0.18) : Ink.track, in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

/// The plan, quiet: the accent is for data, so the badge no longer competes with the bars.
struct PlanTag: View {
    let plan: String
    var body: some View {
        Text(plan.uppercased())
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
    }
}

struct StateChip: View {
    enum Tone { case inUse, next, gone, quiet }
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay {
                if tone == .next || tone == .quiet {
                    Capsule().strokeBorder(Color.primary.opacity(tone == .next ? 0.18 : 0.1), lineWidth: 1)
                }
            }
    }

    private var foreground: Color {
        switch tone {
        case .inUse: return Ink.ember
        case .next: return .secondary
        case .gone: return Ink.alarm
        case .quiet: return Color.secondary.opacity(0.8)
        }
    }

    private var background: Color {
        switch tone {
        case .inUse: return Ink.ember.opacity(0.16)
        case .gone: return Ink.alarm.opacity(0.12)
        case .next, .quiet: return .clear
        }
    }
}

/// The limit bar without labels: the part spent within the pace at half strength, the part ahead of the pace at
/// full strength, and a notch where the pace is now. The same reading as `LimitGauge`, small enough for a row.
struct PaceBar: View {
    var used: Double
    var pace: Double
    var critical = false
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let usedX = w * min(1, max(0, used) / 100)
            let paceX = w * min(1, max(0, pace) / 100)
            let tint = critical ? Ink.alarm : Ink.ember
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.track)
                Capsule().fill(tint.opacity(0.5)).frame(width: min(usedX, paceX))
                if usedX > paceX {
                    Capsule().fill(tint).frame(width: usedX)
                        .mask(alignment: .leading) {
                            HStack(spacing: 0) { Color.clear.frame(width: paceX); Color.black }
                        }
                }
                if pace > 0.5, pace < 99.5 {
                    Rectangle().fill(Color.primary.opacity(0.42))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: max(0, paceX - 0.75))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// "5h ▓▓░ 33%" — one window in a queue row.
struct MiniLimit: View {
    let label: String
    let window: LimitWindow?

    private var used: Double { window.map { $0.hasReset() ? 0 : $0.utilization } ?? 0 }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            PaceBar(used: used, pace: window.map { $0.hasReset() ? 0 : $0.paceTarget } ?? 0,
                    critical: window?.isCritical == true && !(window?.hasReset() ?? false))
            Text(window == nil ? "—" : Fmt.pct(used))
                .font(Type.captionStrong)
                .foregroundStyle(window?.isCritical == true && !(window?.hasReset() ?? false) ? Ink.alarm : Color.primary)
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(window == nil ? "sem leitura" : Fmt.pct(used))")
    }
}

/// The block at the top of a pane: a small caption, the answer in big type, one line of context.
struct StatusBlock: View {
    let caption: String
    let headline: String
    var line: String?
    var tone: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(Type.caption).foregroundStyle(.secondary)
            Text(headline).font(Type.headline).foregroundStyle(tone)
                .lineLimit(1).minimumScaleFactor(0.8)
            if let line, !line.isEmpty {
                Text(line).font(Type.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct GroupTitle: View {
    let title: String
    var trailing: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Type.groupTitle).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(Type.caption).foregroundStyle(.tertiary) }
        }
    }
}

/// A plain message in a soft box, for errors and notes that are not a limit alarm.
struct NoteBox: View {
    let text: String
    var tone: Color = .secondary
    var icon = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(Type.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(tone.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Lays chips out in lines, wrapping when a line is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 340
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

struct OkChip: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Ink.ember)
            Text(text).font(Type.mini).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
    }
}

/// A borderless icon that reads as a button (hover fill), for the panel header.
struct HeaderIcon<Label: View>: View {
    @ViewBuilder var label: () -> Label
    @State private var hovering = false

    var body: some View {
        label()
            .frame(width: 26, height: 24)
            .background(hovering ? Ink.track : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
