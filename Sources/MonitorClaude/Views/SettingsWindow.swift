import SwiftUI
import AppKit

/// The settings window: Geral, Contas, Integrações and Avançado. The add-account assistant opens here as a sheet,
/// so the browser it opens never closes the panel under it.
struct SettingsWindow: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        TabView(selection: $monitor.settingsTab) {
            GeneralSettings()
                .tabItem { Label(SettingsTab.general.label, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)
            AccountsSettings(monitor: monitor)
                .tabItem { Label(SettingsTab.accounts.label, systemImage: SettingsTab.accounts.symbol) }
                .tag(SettingsTab.accounts)
            IntegrationsSettings(monitor: monitor)
                .tabItem { Label(SettingsTab.integrations.label, systemImage: SettingsTab.integrations.symbol) }
                .tag(SettingsTab.integrations)
            AdvancedSettings(monitor: monitor)
                .tabItem { Label(SettingsTab.advanced.label, systemImage: SettingsTab.advanced.symbol) }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 640, height: 540)
        .tint(Ink.ember)
        .sheet(item: $monitor.accountFlow, onDismiss: { monitor.closeAccountFlow() }) { flow in
            AddAccountSheet(flow: flow) { monitor.closeAccountFlow() }
        }
        .onAppear { monitor.refreshIntegrations() }
    }
}

// MARK: - Geral

struct GeneralSettings: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Abrir ao iniciar a sessão", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, _ in settings.applyLaunchAtLogin() }
                Picker("A barra de menu mostra", selection: $settings.menuBarStyleRaw) {
                    ForEach(Settings.MenuBarStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("O painel fica da altura do que cada aba mostra, até o espaço que a tela tem abaixo da barra de menu.")
                    .font(Type.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Avisar quando o ritmo passar do sustentável", isOn: $settings.warnAtPace)
                Toggle("Mostrar processos que não são do Claude", isOn: $settings.showOtherProcesses)
            } footer: {
                Text("Manter o Mac desperto, inclusive com a tampa fechada, fica no ícone da lua no topo do painel (vira um sol enquanto está ligado).")
                    .font(Type.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Contas

struct AccountsSettings: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        let queue = monitor.accountQueue
        Form {
            if let error = monitor.actionError {
                Section { Text(error).foregroundStyle(Ink.alarm).font(Type.caption) }
            }
            Section {
                Toggle(isOn: Binding(get: { queue.enabled }, set: { on in Task { await monitor.setSwitching(on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Troca automática")
                        Text("Quando a conta em uso bate o limite, a próxima da fila assume e a sessão continua de onde parou.")
                            .font(Type.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!queue.configured || queue.isSingle)
                Picker("Sessões novas abrem", selection: Binding(
                    get: { queue.strategy },
                    set: { s in Task { await monitor.setStrategy(s) } })) {
                    Text("Na do topo da fila, enquanto tiver folga").tag(AccountRouter.Strategy.order)
                    Text("Na que tiver mais folga").tag(AccountRouter.Strategy.headroom)
                }
                .disabled(!queue.enabled || queue.isSingle)
            }

            Section {
                ForEach(Array(queue.route.enumerated()), id: \.element.id) { i, entry in
                    AccountSettingsRow(entry: entry, index: i, queue: queue, monitor: monitor)
                }
            } header: {
                Text("Fila")
            } footer: {
                Text("Quando a conta em uso acaba, assume a da rota com mais folga; a reserva só entra quando a rota inteira acabar. No painel, arraste as contas para mudar a ordem.")
                    .font(Type.caption).foregroundStyle(.secondary)
            }

            if !queue.reserve.isEmpty {
                Section("Reserva · só quando as outras acabarem") {
                    ForEach(Array(queue.reserve.enumerated()), id: \.element.id) { i, entry in
                        AccountSettingsRow(entry: entry, index: queue.route.count + 1 + i, queue: queue, monitor: monitor)
                    }
                }
            }

            Section {
                HStack {
                    Button("Adicionar conta…") { monitor.startAddAccount() }
                        .buttonStyle(.borderedProminent)
                        .disabled(monitor.routerConfigProblem != nil)
                    Spacer()
                }
            } footer: {
                if let problem = monitor.routerConfigProblem {
                    Text("\(problem). Corrija o arquivo antes de adicionar uma conta.")
                        .font(Type.caption).foregroundStyle(Ink.alarm)
                }
            }

            if let switches = monitor.router?.switches, !switches.isEmpty {
                Section("Trocas recentes") {
                    ForEach(Array(switches.prefix(8).enumerated()), id: \.offset) { _, s in
                        HStack {
                            Text(Fmt.stamp(s.at)).font(Type.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .leading)
                            Text("\(name(s.from, queue)) → \(name(s.to, queue))").font(Type.body)
                            Spacer()
                            Text(AccountRouter.reasonText(s.reason)).font(Type.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func name(_ id: String, _ queue: AccountQueue) -> String { queue.entry(id)?.label ?? id }
}

struct AccountSettingsRow: View {
    let entry: AccountQueue.Entry
    let index: Int
    let queue: AccountQueue
    @ObservedObject var monitor: Monitor
    @State private var name = ""
    @State private var monogram = ""

    var body: some View {
        HStack(spacing: 10) {
            Avatar(monogram: monogram.isEmpty ? entry.monogram : monogram.uppercased(), active: entry.isLive, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    TextField("", text: $name, prompt: Text("Nome"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(Type.strong)
                        .onSubmit(save)
                        .disabled(!queue.configured)
                    TextField("", text: $monogram, prompt: Text("Sigla"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .onSubmit(save)
                        .disabled(!queue.configured)
                        .help("Duas letras para a barra de menu")
                }
                Text([entry.email, entry.organization, entry.plan?.capitalized].compactMap { $0 }.joined(separator: " · "))
                    .font(Type.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    status(entry.hasLogin ? "login ok" : "sem login", ok: entry.hasLogin)
                    status(entry.runsAgents ? "agentes rodam aqui" : (entry.agentsLogin ? "pronta para agentes" : "agentes sem login"),
                           ok: entry.agentsLogin)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if !entry.hasLogin {
                    Button("Autorizar…") { monitor.startReauthorize(entry.id, agents: false) }
                } else if !entry.agentsLogin {
                    Button("Agentes…") { monitor.startReauthorize(entry.id, agents: true) }
                }
                if queue.configured, !queue.isSingle {
                    HStack(spacing: 2) {
                        Button { Task { await monitor.moveAccount(entry.id, to: max(0, index - 1)) } } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .help("Subir")
                        Button { Task { await monitor.moveAccount(entry.id, to: index + 1) } } label: {
                            Image(systemName: "chevron.down")
                        }
                        .help("Descer")
                        Button {
                            Task { await monitor.moveAccount(entry.id, to: entry.role == .route ? queue.entries.count : queue.route.count) }
                        } label: {
                            Image(systemName: entry.role == .route ? "tray.and.arrow.down" : "tray.and.arrow.up")
                        }
                        .help(entry.role == .route ? "Mover para a reserva" : "Mover para a rota")
                        .disabled(entry.role == .route && queue.route.count <= 1)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            name = entry.label
            monogram = entry.monogram
        }
        .onChange(of: entry.label) { _, v in name = v }
        .onChange(of: entry.monogram) { _, v in monogram = v }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != entry.label || monogram.uppercased() != entry.monogram else { return }
        Task { await monitor.renameAccount(entry.id, name: n, monogram: monogram) }
    }

    private func status(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Ink.ember : Ink.alarm)
            Text(text)
        }
        .font(Type.mini)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Integrações

struct IntegrationsSettings: View {
    @ObservedObject var monitor: Monitor
    @State private var copied = false

    var body: some View {
        let state = monitor.integrations
        Form {
            if let error = monitor.actionError {
                Section { Text(error).foregroundStyle(Ink.alarm).font(Type.caption) }
            }
            Section {
                Toggle(isOn: Binding(get: { state.terminal != .off }, set: { monitor.setTerminalIntegration($0) })) {
                    row("Terminal", symbol: "terminal",
                        detail: state.terminal == .onByHand
                            ? "O alias para o claude-auto está no ~/.zshrc, escrito à mão. O Monitor não mexe nele."
                            : "O comando claude passa pelo Monitor. Vale para terminais abertos depois de ligar.")
                }
                .disabled(state.terminal == .onByHand)

                Toggle(isOn: Binding(get: { state.vscodeOn }, set: { monitor.setVSCodeIntegration($0) })) {
                    row("VS Code", symbol: "chevron.left.forwardslash.chevron.right",
                        detail: vscodeDetail(state))
                }
                .disabled(!state.vscodeInstalled || state.vscodeOtherWrapper != nil)

                HStack {
                    row("T3 Code", symbol: "rectangle.3.group",
                        detail: state.t3Installed
                            ? "No binário de cada instância Claude, use o caminho do claude-auto."
                            : "Quando usar o T3, aponte o binário da instância Claude para o claude-auto.")
                    Spacer()
                    Button(copied ? "Copiado" : "Copiar caminho") {
                        Clipboard.copy(Integrations.claudeAutoPath)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
                    }
                }

                HStack {
                    row("claude agents", symbol: "square.on.square", detail: agentsDetail)
                    Spacer()
                }
            } header: {
                Text("Onde a troca de conta vale")
            }

            Section("Comandos") {
                HStack {
                    row("claude-auto e claude-accounts", symbol: "shippingbox",
                        detail: state.commandsInstalled
                            ? "Instalados em ~/.local/bin, apontando para dentro do app. O brew upgrade atualiza os dois."
                            : "Ainda não instalados. Ligar a troca automática ou uma integração instala.")
                    Spacer()
                    Button(state.commandsInstalled ? "Reinstalar" : "Instalar") {
                        if let bin = AccountRouter.bundledCommands {
                            do { try AccountRouter.installCommands(from: bin); monitor.actionError = nil }
                            catch { monitor.actionError = error.localizedDescription }
                        }
                        monitor.refreshIntegrations()
                    }
                    .disabled(AccountRouter.bundledCommands == nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { monitor.refreshIntegrations() }
    }

    private func vscodeDetail(_ state: IntegrationsState) -> String {
        if !state.vscodeInstalled { return "A extensão do Claude Code não está instalada no VS Code." }
        if let other = state.vscodeOtherWrapper { return "O ajuste claudeCode.claudeProcessWrapper já aponta para \(other)." }
        return "Grava claudeCode.claudeProcessWrapper no settings.json do VS Code. Vale para conversas novas."
    }

    private var agentsDetail: String {
        let q = monitor.accountQueue
        guard q.configured, !q.isSingle else { return "Com mais de uma conta, os agentes também trocam de conta." }
        let ready = q.entries.filter(\.agentsLogin).count
        return "\(ready) de \(q.entries.count) contas prontas para os agentes. Falta autorizar? Use o botão na aba Contas."
    }

    private func row(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .background(Ink.track, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(Type.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Avançado

struct AdvancedSettings: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Consultar o servidor a cada")
                        Spacer()
                        Text(Fmt.duration(settings.usageIntervalSeconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.usageIntervalSeconds, in: 60...600, step: 30)
                    Text("O servidor limita as consultas, e cada terminal aberto também consulta. Abaixo de 60 s há risco de ele pedir uma pausa.")
                        .font(Type.caption).foregroundStyle(.secondary)
                }
            }

            Section("De onde vêm os números") {
                source("Login do terminal", health: monitor.feeds.terminal,
                       note: monitor.usageError ?? "A fonte preferida: traz as janelas por modelo e o crédito extra.")
                source("App do Claude", health: monitor.feeds.desktop,
                       note: "Entra quando o login do terminal não responde. Grava a cada 5 min.")
                HStack {
                    Spacer()
                    Button("Ler de novo") { Task { await monitor.refreshUsage(force: true) } }
                }
            }

            Section("Painel de prontidão") {
                switch monitor.access.readiness {
                case .present(let at):
                    HStack {
                        Text("Rodando" + (at.map { ", última conferência \(Fmt.ago($0))" } ?? ""))
                        Spacer()
                        Button("Abrir") { NSWorkspace.shared.open(Readiness.panelURL) }
                    }
                case .absent(let installed):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(installed
                             ? "Instalado, mas o vigia não está ligado. Ligar faz ele abrir com o computador."
                             : "Não instalado. Ele confere gcloud, AWS, GitHub e Docker para a aba Acessos.")
                            .font(Type.caption).foregroundStyle(.secondary)
                        HStack {
                            if installed {
                                Button("Ligar o vigia") { Task { await monitor.enableReadinessWatcher() } }
                            } else {
                                Text(Readiness.installCommand).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button("Copiar") { Clipboard.copy(Readiness.installCommand) }
                            }
                        }
                    }
                }
            }

            Section("Pastas") {
                HStack {
                    Text("Contas do roteador")
                    Spacer()
                    Text(AccountRouter.home.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([AccountRouter.home]) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func source(_ title: String, health: FeedState.Health, note: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note).font(Type.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(caption(health)).font(Type.caption).foregroundStyle(isBroken(health) ? Ink.alarm : .secondary)
        }
    }

    private func caption(_ h: FeedState.Health) -> String {
        switch h {
        case .live(let at): return "ok, \(Fmt.ago(at))"
        case .stale(let at): return "parado desde \(Fmt.stamp(at))"
        case .broken(let why): return why
        case .missing: return "sem dados"
        }
    }

    /// A pause the server asked for is not a failure worth red.
    private func isBroken(_ h: FeedState.Health) -> Bool {
        if case .broken(let why) = h { return why != "pausa pedida" }
        return false
    }
}
