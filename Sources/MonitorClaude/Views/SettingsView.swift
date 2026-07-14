import SwiftUI

/// A slide-over inside the panel rather than a separate window, so it inherits the panel's
/// width and dismisses without leaving a stray window behind on the menu bar.
struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var monitor: Monitor
    @ObservedObject var keep = KeepAwake.shared
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("Voltar").font(Type.label)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.ember)
                Spacer()
                Text("Configurações").font(Type.section).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("Manter desperto") {
                        toggle("Manter o Mac desperto", isOn: Binding(
                            get: { keep.awake }, set: { keep.setAwake($0) }))

                        HStack {
                            Text("Duração").font(Type.label)
                            Spacer()
                            Menu {
                                ForEach(KeepAwake.Duration.allCases) { d in
                                    Button {
                                        keep.duration = d
                                    } label: {
                                        if keep.duration == d {
                                            Label(d.label, systemImage: "checkmark")
                                        } else {
                                            Text(d.label)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(keep.duration.label).font(Type.label)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                                }
                                .foregroundStyle(Ink.ember)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(!keep.awake)
                            .opacity(keep.awake ? 1 : 0.4)
                        }

                        toggle("Continuar com a tampa fechada", isOn: Binding(
                            get: { keep.lidClosed }, set: { keep.setLidClosed($0) }))
                            .disabled(keep.busy)

                        Text("A tampa fechada usa uma regra sudoers restrita (só pmset disablesleep), instalada com um único pedido de senha. Remover: sudo rm /etc/sudoers.d/monitor-claude-clamshell")
                            .font(Type.labelTiny).foregroundStyle(.tertiary)
                    }

                    group("Painel") {
                        picker("Altura", selection: $settings.panelSizeRaw,
                               options: Settings.PanelSize.allCases.map { ($0.rawValue, $0.label) })
                    }

                    group("Barra de menu") {
                        picker("Mostrar", selection: $settings.menuBarStyleRaw,
                               options: Settings.MenuBarStyle.allCases.map { ($0.rawValue, $0.label) })
                    }

                    group("Listas") {
                        toggle("Mostrar processos não relacionados ao Claude",
                               isOn: $settings.showOtherProcesses)
                        toggle("Avisar quando o ritmo passar do sustentável",
                               isOn: $settings.warnAtPace)
                    }

                    group("Limites") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Consultar o servidor a cada").font(Type.label)
                                Spacer()
                                Text("\(Int(settings.usageIntervalSeconds))s")
                                    .font(Type.value).foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.usageIntervalSeconds, in: 60...600, step: 30)
                                .tint(Ink.ember)
                            Text("O endpoint é limitado no servidor. Cada terminal aberto também consulta; abaixo de 60s há risco de estrangular.")
                                .font(Type.labelTiny).foregroundStyle(.tertiary)
                        }
                    }

                    group("Sistema") {
                        toggle("Abrir ao iniciar a sessão", isOn: $settings.launchAtLogin)
                            .onChange(of: settings.launchAtLogin) { _, _ in
                                settings.applyLaunchAtLogin()
                            }
                    }

                    HStack {
                        Spacer()
                        Text("Monitor Claude · lê o login do terminal, nada sai da máquina")
                            .font(Type.labelTiny).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
                .padding(12)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 396)
        .frame(height: settings.panelSize.height)
    }

    // MARK: parts

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHead(title: title)
            content()
        }
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).font(Type.label)
        }
        .toggleStyle(.switch)
        .tint(Ink.ember)
        .controlSize(.mini)
    }

    private func picker(_ label: String, selection: Binding<String>,
                        options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Type.label)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }
}
