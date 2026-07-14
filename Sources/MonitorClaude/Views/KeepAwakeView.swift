import SwiftUI

/// Réplica do card do Vorssaint: um cabeçalho com o estado atual do sono, o toggle "Manter
/// desperto" com um menu de duração, e o toggle "Continuar com a tampa fechada". Fica no topo
/// do painel porque é o controle que se mexe com mais frequência.
struct KeepAwakeSection: View {
    @ObservedObject var keep = KeepAwake.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 0) {
                awakeRow
                Hairline().padding(.leading, 2)
                lidRow
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Ink.track.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if let err = keep.lastError {
                Text(err).font(Type.labelTiny).foregroundStyle(Ink.alarm)
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(keep.active ? Ink.ember.opacity(0.18) : Ink.track)
                Image(systemName: keep.active ? "sun.max.fill" : "moon.zzz.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(keep.active ? Ink.ember : Color.secondary)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Manter o Mac desperto").font(Type.label)
                Text(keep.stateText)
                    .font(Type.labelTiny)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if keep.active {
                Text("ATIVO")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Ink.ember)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Ink.ember.opacity(0.14), in: Capsule())
            }
        }
    }

    // MARK: rows

    private var awakeRow: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Manter desperto").font(Type.label)
                    Text(keep.awake ? "Ativo até você desligar" : "O Mac segue a energia normal")
                        .font(Type.labelTiny).foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { keep.awake }, set: { keep.setAwake($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(Ink.ember).controlSize(.small)
            }
            .padding(.vertical, 5)

            if keep.awake {
                HStack {
                    Text("Duração").font(Type.labelTiny).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(KeepAwake.Duration.allCases) { d in
                            Button {
                                keep.duration = d
                            } label: {
                                if keep.duration == d { Label(d.label, systemImage: "checkmark") }
                                else { Text(d.label) }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(keep.duration.label).font(Type.labelTiny)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                        }
                        .foregroundStyle(Ink.ember)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: keep.awake)
    }

    private var lidRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Continuar com a tampa fechada").font(Type.label)
                Text(keep.busy
                     ? "Aplicando…"
                     : "Aplicado sempre que “Manter desperto” estiver ativo")
                    .font(Type.labelTiny).foregroundStyle(.tertiary)
            }
            Spacer()
            if keep.busy {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Toggle("", isOn: Binding(get: { keep.lidClosed }, set: { keep.setLidClosed($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(Ink.ember).controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }
}
