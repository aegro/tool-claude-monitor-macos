import SwiftUI
import AppKit

/// The assistant's steps. Each one says what is about to happen in one sentence; the commands it runs are the
/// router's own (`claude-accounts add`, `login`, `login --agents`).
struct AddAccountSheet: View {
    @ObservedObject var flow: AddAccountFlow
    var close: () -> Void

    private var steps: [AddAccountFlow.Step] {
        flow.existing ? [.authorize, .connected, .agents] : [.choose, .authorize, .connected, .agents, .place]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(flow.existing ? "Autorizar \(flow.name)" : "Adicionar conta").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let i = steps.firstIndex(of: flow.step) {
                    Text("\(i + 1) de \(steps.count)").font(Type.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)

            Group {
                switch flow.step {
                case .choose: choose
                case .authorize: authorize
                case .connected: connected
                case .agents: agents
                case .place: place
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .failed(let message) = flow.phase {
                NoteBox(text: message, tone: Ink.alarm, icon: "exclamationmark.triangle").padding(.top, 12)
            }

            Spacer(minLength: 12)

            HStack {
                if flow.step != .done {
                    Button("Cancelar") { flow.cancel(); close() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                primary
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
        .tint(Ink.ember)
    }

    // MARK: steps

    private var choose: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(flow.suggestions.isEmpty
                 ? "Escolha a conta no próximo passo, no navegador."
                 : "Contas que você já usou neste Mac e que ainda não estão na fila:")
                .font(Type.body).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(flow.suggestions) { s in
                        HStack(spacing: 10) {
                            Avatar(monogram: AccountRouter.monogram(for: s.label), size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.label).font(Type.strong)
                                Text(s.detail).font(Type.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Adicionar") { Task { await flow.choose(s) } }
                                .disabled(isWorking)
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    }
                }
            }
            .frame(maxHeight: 210)
            Button("Outra conta…") { Task { await flow.choose(nil) } }
                .buttonStyle(.link)
                .disabled(isWorking)
            working
        }
    }

    private var authorize: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Autorize no navegador").font(Type.strong)
            Text("A página de login do Claude abre no navegador. Se ele já estiver logado em outra conta, use a janela anônima e entre com a conta certa.")
                .font(Type.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Abrir no navegador") { flow.authorize(incognito: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                if let browser = AddAccountFlow.privateBrowser {
                    Button("Janela anônima do \(browser.app.replacingOccurrences(of: "Google ", with: ""))") { flow.authorize(incognito: true) }
                        .disabled(isWorking)
                }
            }
            working
            if flow.needsCode {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No fim, a página mostra um código. Copie e cole aqui:")
                        .font(Type.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("Código", text: $flow.code)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { flow.sendCode() }
                        Button("Enviar") { flow.sendCode() }
                            .disabled(flow.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if flow.loginURL != nil {
                HStack(spacing: 12) {
                    Button("Abrir de novo") { flow.reopenLogin() }.buttonStyle(.link)
                    Button("Copiar o link") { if let url = flow.loginURL { Clipboard.copy(url.absoluteString) } }.buttonStyle(.link)
                }
                .font(Type.caption)
            }
            Text("Mesmo e-mail em duas organizações? Escolha a organização na tela de autorização.")
                .font(Type.caption).foregroundStyle(.tertiary)
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: flow.duplicateOf == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(flow.duplicateOf == nil ? Ink.ember : Ink.alarm)
                Text(flow.duplicateOf == nil ? "Conectado" : "Esta organização já está na fila").font(Type.strong)
            }
            if let who = flow.identity {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { Text("E-mail").foregroundStyle(.secondary); Text(who.email ?? "—") }
                    GridRow { Text("Organização").foregroundStyle(.secondary); Text(who.organizationDisplay ?? "—") }
                    GridRow { Text("Plano").foregroundStyle(.secondary); Text(who.planFallback?.capitalized ?? "—") }
                }
                .font(Type.body)
            }
            if let other = flow.duplicateOf {
                Text("É a mesma conta e organização da \(other), então trocar entre as duas não muda nada. Autorize de novo e escolha a outra organização.")
                    .font(Type.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !flow.existing {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nome").font(Type.caption).foregroundStyle(.secondary)
                        TextField("Nome", text: $flow.name).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sigla").font(Type.caption).foregroundStyle(.secondary)
                        TextField("", text: $flow.monogram).textFieldStyle(.roundedBorder).frame(width: 56)
                    }
                }
                Text("A sigla aparece na barra de menu quando esta conta assume.").font(Type.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agentes em segundo plano").font(Type.strong)
            Text(flow.agentsRunning > 0
                 ? "Você tem \(flow.agentsRunning == 1 ? "1 agente" : "\(flow.agentsRunning) agentes") do claude agents. Para eles também passarem para esta conta, o Claude pede uma segunda autorização, da mesma conta."
                 : "Se você usa o claude agents, os agentes só passam para esta conta com uma segunda autorização, da mesma conta.")
                .font(Type.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Autorizar os agentes") { flow.authorizeAgents(incognito: flow.incognito) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                Button("Agora não") { flow.skipAgents() }
                    .disabled(isWorking)
            }
            working
        }
    }

    private var place: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lugar na fila").font(Type.strong)
            Picker("", selection: $flow.reserve) {
                Text("Na rota: assume quando chegar a vez dela").tag(false)
                Text("Reserva: só quando as outras acabarem").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if AccountRouter.loadConfig()?.enabled != true {
                Toggle("Ligar a troca automática", isOn: $flow.enableSwitching)
            }
            if !flow.agentsAuthorized {
                Text("Os agentes ainda não passam para esta conta. Dá para autorizar depois, em Contas e logins.")
                    .font(Type.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.ember)
                Text(flow.existing ? "\(flow.name) autorizada" : "\(flow.name) entrou na fila").font(Type.strong)
            }
            Text(flow.existing ? "O Monitor volta a usar esta conta na troca." : (flow.reserve
                 ? "Na reserva: só assume quando as outras acabarem."
                 : "Na rota, depois das contas que já estavam lá. Arraste no painel para mudar a ordem."))
                .font(Type.body).foregroundStyle(.secondary)
        }
    }

    // MARK: parts

    private var isWorking: Bool {
        if case .working = flow.phase { return true }
        return false
    }

    @ViewBuilder
    private var working: some View {
        if case .working(let text) = flow.phase {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(Type.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var primary: some View {
        switch flow.step {
        case .connected:
            if flow.duplicateOf != nil {
                Button("Autorizar de novo") { flow.retryLogin() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Continuar") { flow.confirmConnected() }.keyboardShortcut(.defaultAction)
            }
        case .place:
            Button("Concluir") { Task { await flow.finish() } }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
        case .done:
            Button("Fechar") { close() }.keyboardShortcut(.defaultAction)
        default:
            EmptyView()
        }
    }
}
