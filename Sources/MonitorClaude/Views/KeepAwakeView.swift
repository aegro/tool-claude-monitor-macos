import SwiftUI

/// Versão minimalista: duas linhas finas no topo do painel, sem card nem cabeçalho. O estado é
/// lido pela cor do sol e pelos switches; a configuração detalhada mora em Configurações.
struct KeepAwakeSection: View {
    @ObservedObject var keep = KeepAwake.shared

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: keep.active ? "sun.max.fill" : "moon.zzz")
                    .font(.system(size: 12))
                    .foregroundStyle(keep.active ? Ink.ember : .secondary)
                    .frame(width: 15)

                Text("Manter desperto").font(Type.label)

                if keep.awake, keep.duration != .indefinite, let e = keep.expiresAt {
                    Text(Fmt.duration(e.timeIntervalSinceNow))
                        .font(Type.labelTiny).foregroundStyle(Ink.ember)
                        .monospacedDigit()
                }

                Spacer(minLength: 4)

                if keep.awake {
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
                        HStack(spacing: 2) {
                            Text(keep.duration.label)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
                        }
                        .font(Type.labelTiny)
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Toggle("", isOn: Binding(get: { keep.awake }, set: { keep.setAwake($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(Ink.ember).controlSize(.mini)
            }

            HStack(spacing: 8) {
                Color.clear.frame(width: 15)
                Text("Tampa fechada")
                    .font(Type.labelTiny)
                    .foregroundStyle(keep.awake ? .secondary : .tertiary)
                if keep.busy {
                    ProgressView().controlSize(.mini).scaleEffect(0.55)
                }
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { keep.lidClosed }, set: { keep.setLidClosed($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(Ink.ember).controlSize(.mini)
                    .disabled(keep.busy)
            }
        }
    }
}
