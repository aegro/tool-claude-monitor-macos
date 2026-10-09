import SwiftUI

/// "Manter o Mac desperto", inline under the panel's header: the state in words, one row of choices (off, 1 h …
/// for good) and the lid-closed switch with what it means. Folded while on, a slim strip keeps it in sight on every
/// tab, so a Mac held awake is never a surprise.
struct KeepAwakeCard: View {
    @ObservedObject var keep: KeepAwake
    var close: () -> Void

    private var selection: KeepAwake.Duration? { keep.awake ? keep.duration : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: keep.active ? "sun.max.fill" : "moon.zzz")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(keep.active ? Ink.ember : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(keep.active ? "Mac desperto" : "O Mac dorme normalmente").font(Type.strong)
                    Text(subtitle).font(Type.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Recolher")
            }

            HStack(spacing: 4) {
                choice(nil, "Desligado").frame(width: 72)
                ForEach(KeepAwake.Duration.allCases) { choice($0, $0.short) }
            }
            .disabled(keep.busy)

            Divider().opacity(0.6)

            Toggle(isOn: Binding(get: { keep.lidClosed }, set: { keep.setLidClosed($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Também com a tampa fechada").font(Type.bodyMedium)
                        if keep.busy { ProgressView().controlSize(.mini) }
                    }
                    Text(lidDetail).font(Type.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Ink.ember)
            .disabled(keep.busy)

            if keep.lidClosed, KeepAwake.onBattery {
                NoteBox(text: "Na bateria: fechado na mochila, o Mac esquenta e a carga acaba. Use com o carregador.",
                        tone: Ink.alarm, icon: "battery.25")
            }
            if let error = keep.lastError {
                NoteBox(text: error, tone: Ink.alarm, icon: "exclamationmark.triangle")
            }
        }
        .padding(12)
        .background(Ink.track.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var subtitle: String {
        if keep.busy { return "Aplicando…" }
        guard let until = keep.untilText else { return "Escolha por quanto tempo ele fica acordado." }
        return keep.lidClosed ? "\(until.capitalizingFirst) · também com a tampa fechada" : until.capitalizingFirst
    }

    private var lidDetail: String {
        keep.lidClosed
            ? "Fechar o notebook não põe o Mac para dormir: os agentes seguem rodando."
            : "Para os agentes seguirem com o notebook fechado. Pede a senha de administrador na primeira vez."
    }

    private func choice(_ value: KeepAwake.Duration?, _ label: String) -> some View {
        let on = selection == value
        return Button { keep.choose(value) } label: {
            Text(label)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(on ? (value == nil ? Color.primary : Ink.ember) : Color.secondary)
                .background(on ? Color(nsColor: .controlBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(on ? 0.14 : 0.08), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(value == nil ? "Deixar o Mac dormir" : "Manter desperto: \(value!.label)")
    }
}

/// The folded state while the Mac is held awake: one line, the whole of it a button that opens the card.
struct KeepAwakeStrip: View {
    @ObservedObject var keep: KeepAwake
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.ember)
                Text(["Mac desperto \(keep.untilText ?? "")", keep.lidClosed ? "tampa fechada" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Ajustar").font(Type.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Ink.ember.opacity(0.07))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Manter o Mac desperto")
    }
}

extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
