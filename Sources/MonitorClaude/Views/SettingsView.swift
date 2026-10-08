import SwiftUI

/// A slide-over inside the panel rather than a separate window, so it inherits the panel's
/// width and dismisses without leaving a stray window behind on the menu bar.
struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var monitor: Monitor
    @ObservedObject var keep = KeepAwake.shared
    var onClose: () -> Void

    @State private var routerOn = AccountRouter.loadConfig()?.enabled ?? true
    @State private var preferred = AccountRouter.loadConfig()?.preferred
    @State private var commandsInstalled = AccountRouter.commandsInstalled
    @State private var routerError: String?
    @State private var savingRouterConfig = false

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

                    group("Troca de conta") {
                        toggle("Trocar de conta sozinho quando o limite bater", isOn: Binding(
                            get: { routerOn }, set: { setRouter($0) }))
                        routerStatus
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

    // MARK: router

    @ViewBuilder
    private var routerStatus: some View {
        if let state = monitor.router {
            preferredPicker(state.config.accounts)
            if preferred != nil {
                note("Sessões novas abrem nela quando tem folga. claude agents e o T3 (entre turnos) voltam para ela quando o limite renova; terminal já aberto fica onde está.")
            }
            ForEach(state.config.accounts, id: \.id) { account in
                let login = state.loginLabel(for: account.id)
                let reading = state.usage[account.id].map {
                    "sessão \(Fmt.pct(AccountRouter.used($0.session))) · semana \(Fmt.pct(AccountRouter.used($0.weekly)))"
                } ?? "sem leitura"
                note("\(account.label) (\(login)): \(reading)\(account.role == .reserve ? " · reserva" : "")")
            }
            ForEach(state.sharedLogins, id: \.self) { ids in
                Text("\(ids.joined(separator: " e ")) estão logadas na mesma conta (\(state.logins[ids[0]]?.email ?? "?")), então trocar entre elas não muda nada. Rode claude-accounts login <nome> com a outra conta; se o navegador já estiver logado, termine o login numa janela anônima.")
                    .font(Type.labelTiny)
                    .foregroundStyle(Ink.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.config.enabled {
                note(state.pick.map { "Usaria agora: \($0)" } ?? "Nenhuma conta disponível agora")
                let semLogin = state.config.accounts
                    .filter { $0.id != state.config.principal && !AccountRouter.hasAgentsLogin($0.id) }
                    .map(\.id)
                if !semLogin.isEmpty {
                    note("claude agents roda na \(state.config.principal) e só troca para contas com login de agentes. Falta em: \(semLogin.joined(separator: ", ")) (claude-accounts login <nome> --agents).")
                }
            }
            if let last = state.lastSwitch {
                note("Última troca \(Fmt.stamp(last.at)): \(last.from) → \(last.to) · \(last.reason)")
            }
        } else {
            note("Nenhuma conta extra ainda. No terminal: claude-accounts add <nome> e claude-accounts login <nome>.")
        }

        if !commandsInstalled {
            if let bin = AccountRouter.bundledCommands {
                Button("Instalar claude-auto e claude-accounts em ~/.local/bin") {
                    installBundledCommands(from: bin)
                }
                .buttonStyle(.plain)
                .font(Type.labelTiny)
                .foregroundStyle(Ink.ember)
            } else {
                note("Comandos não instalados: rode router/install.sh a partir do repositório.")
            }
        }

        if let routerError {
            Text(routerError)
                .font(Type.labelTiny)
                .foregroundStyle(Ink.ember)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setRouter(_ on: Bool) {
        guard !savingRouterConfig else { return }
        if on, !commandsInstalled, let bin = AccountRouter.bundledCommands {
            guard installBundledCommands(from: bin) else { return }
        }
        savingRouterConfig = true
        Task {
            guard await saveRouterConfig({ try AccountRouter.setEnabled(on) }) else { return }
            routerOn = on
            await monitor.refreshUsage(force: true)
        }
    }

    /// Callers set `savingRouterConfig` synchronously, before creating the Task, so a second tap that lands
    /// before the Task starts is already turned away by their guard.
    private func saveRouterConfig(_ save: @escaping @Sendable () throws -> Void) async -> Bool {
        defer { savingRouterConfig = false }
        do {
            try await Task.detached(priority: .userInitiated) { try save() }.value
            routerError = nil
            return true
        } catch {
            routerError = "Não deu para salvar \(AccountRouter.configURL.path): \(error.localizedDescription)"
            return false
        }
    }

    private func preferredPicker(_ accounts: [AccountRouter.Account]) -> some View {
        HStack {
            Text("Conta preferida").font(Type.label)
            Spacer()
            Menu {
                preferredOption(nil, label: "Nenhuma")
                ForEach(accounts, id: \.id) { preferredOption($0.id, label: $0.label) }
            } label: {
                HStack(spacing: 3) {
                    Text(accounts.first { $0.id == preferred }?.label ?? "Nenhuma").font(Type.label)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }
                .foregroundStyle(Ink.ember)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!routerOn)
            .opacity(routerOn ? 1 : 0.4)
        }
    }

    private func preferredOption(_ id: String?, label: String) -> some View {
        Button {
            setPreferred(id)
        } label: {
            if preferred == id {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private func setPreferred(_ id: String?) {
        guard !savingRouterConfig else { return }
        savingRouterConfig = true
        Task {
            guard await saveRouterConfig({ try AccountRouter.setPreferred(id) }) else { return }
            preferred = id
            monitor.watchAgentsNow()
            await monitor.refreshUsage(force: true)
        }
    }

    @discardableResult
    private func installBundledCommands(from bin: URL) -> Bool {
        do {
            try AccountRouter.installCommands(from: bin)
            routerError = nil
        } catch {
            routerError = "Não deu para instalar os comandos em ~/.local/bin: \(error.localizedDescription)"
        }
        commandsInstalled = AccountRouter.commandsInstalled
        return routerError == nil
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Type.labelTiny)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
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
