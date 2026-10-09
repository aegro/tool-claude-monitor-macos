import Foundation
import Testing
@testable import MonitorClaude

struct QueueAndAccountsTests {
    let home = URL(fileURLWithPath: "/Users/exemplo/.claude-accounts")
    let defaultDirectory = URL(fileURLWithPath: "/Users/exemplo/.claude")

    private func tempConfig(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: names

    @Test func siglaUsaOParentesesAsIniciaisOuAsDuasPrimeirasLetras() {
        #expect(AccountRouter.monogram(for: "Thomas (Aegro)") == "AE")
        #expect(AccountRouter.monogram(for: "Thomas (Max)") == "MA")
        #expect(AccountRouter.monogram(for: "Squad Compare") == "SC")
        #expect(AccountRouter.monogram(for: "pessoal") == "PE")
        #expect(AccountRouter.monogram(for: "Ação Única") == "AU")
        #expect(AccountRouter.monogram(for: "") == "?")
        #expect(AccountRouter.monogram(for: "Conta (Time de Dados)") == "TD")
    }

    @Test func slugSemAcentoUnicoEComTamanhoLimitado() {
        #expect(AccountRouter.slug(for: "Thomas (Max)", taken: []) == "thomas-max")
        #expect(AccountRouter.slug(for: "Ação Única", taken: []) == "acao-unica")
        #expect(AccountRouter.slug(for: "Thomas (Max)", taken: ["thomas-max"]) == "thomas-max-2")
        #expect(AccountRouter.slug(for: "Thomas (Max)", taken: ["thomas-max", "thomas-max-2"]) == "thomas-max-3")
        #expect(AccountRouter.slug(for: "!!!", taken: []) == "conta")
        #expect(AccountRouter.slug(for: String(repeating: "a", count: 80), taken: []).count == 32)
    }

    @Test func siglaDaConfigVenceADerivada() throws {
        let cfg = try #require(AccountRouter.parseConfig(Data(#"""
        { "contas": { "principal": { "nome": "Thomas (Aegro)" }, "max": { "nome": "Thomas (Max)", "sigla": "mx" } },
          "rota": ["principal", "max"] }
        """#.utf8), home: home, defaultDirectory: defaultDirectory))
        #expect(cfg.accounts.map(\.monogram) == ["AE", "MX"])
    }

    @Test func contaRepetidaNaRotaOuNaReservaViraUmaSo() throws {
        let cfg = try #require(AccountRouter.parseConfig(Data(#"""
        { "contas": { "principal": {}, "max": {}, "extra": {} },
          "rota": ["max", "principal", "max"], "reserva": ["extra", "extra", "max"] }
        """#.utf8), home: home, defaultDirectory: defaultDirectory))
        #expect(cfg.accounts.map(\.id) == ["max", "principal", "extra"])
    }

    // MARK: config writes

    @Test func salvarAFilaEscreveRotaReservaEPreferida() throws {
        let url = try tempConfig(#"{ "contas": { "principal": {}, "max": {}, "compare": {} }, "rota": ["principal"], "outra": 1 }"#)
        try AccountRouter.saveQueue(route: ["max", "principal"], reserve: ["compare"], strategy: .order, at: url)
        var root = try read(url)
        #expect(root["rota"] as? [String] == ["max", "principal"])
        #expect(root["reserva"] as? [String] == ["compare"])
        #expect(root["preferida"] as? String == "max")
        #expect(root["outra"] as? Int == 1)

        try AccountRouter.saveQueue(route: ["max", "principal"], reserve: ["compare"], strategy: .headroom, at: url)
        root = try read(url)
        #expect(root["preferida"] == nil)
        let cfg = try #require(AccountRouter.parseConfig(Data(contentsOf: url), home: home, defaultDirectory: defaultDirectory))
        #expect(cfg.strategy == .headroom)
    }

    @Test func filaSemNinguemNaRotaERecusada() throws {
        let url = try tempConfig(#"{ "contas": { "principal": {} } }"#)
        #expect(throws: AccountRouter.EmptyRoute.self) {
            try AccountRouter.saveQueue(route: [], reserve: ["principal"], strategy: .order, at: url)
        }
    }

    @Test func renomearGuardaNomeESiglaEApagaASiglaVazia() throws {
        let url = try tempConfig(#"{ "contas": { "max": { "nome": "max", "dir": "~/x" } } }"#)
        try AccountRouter.renameAccount("max", name: "  Thomas (Max) ", monogram: "mxz", at: url)
        var entry = try #require((try read(url)["contas"] as? [String: Any])?["max"] as? [String: Any])
        #expect(entry["nome"] as? String == "Thomas (Max)")
        #expect(entry["sigla"] as? String == "MX")
        #expect(entry["dir"] as? String == "~/x")
        try AccountRouter.renameAccount("max", name: "", monogram: " ", at: url)
        entry = try #require((try read(url)["contas"] as? [String: Any])?["max"] as? [String: Any])
        #expect(entry["nome"] as? String == "Thomas (Max)")
        #expect(entry["sigla"] == nil)
    }

    @Test func configIlegivelNaoESobrescrita() throws {
        let url = try tempConfig("{ quebrado")
        #expect(throws: AccountRouter.UnreadableConfig.self) {
            try AccountRouter.saveQueue(route: ["a"], reserve: [], strategy: .order, at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ quebrado")
    }

    @Test func leituraDoRoteadorComAHoraDeQuandoFoiLida() throws {
        let data = Data(#"""
        { "principal": { "plano": "team", "ok": false, "erro": "HTTP 429", "limitada": true, "esperarAte": 1791502673220,
                         "verificadoEm": 1791502553000, "usoDe": 1791502028000,
                         "uso": { "cinco": { "usado": 33 }, "janelas": [
                           { "chave": "weekly_all", "rotulo": "Weekly (7d)", "usado": 71, "renovaEm": 1791630000164, "severidade": "normal" },
                           { "chave": "session", "rotulo": "Session (5h)", "usado": 33, "renovaEm": 1791514800164, "severidade": "normal" },
                           { "chave": "weekly_scoped", "rotulo": "Weekly Fable", "usado": 0, "renovaEm": 1791630000000 } ] } },
          "max": { "ok": true, "verificadoEm": 1791502589000,
                   "uso": { "janelas": [ { "chave": "session", "usado": 0, "renovaEm": null } ] } },
          "sem-leitura": { "ok": false, "erro": "HTTP 401", "verificadoEm": 1791502589000 },
          "falhou-sem-data": { "ok": false, "verificadoEm": 1, "uso": { "janelas": [ { "chave": "session", "usado": 5 } ] } }
        }
        """#.utf8)
        let readings = AccountRouter.parseRouterReadings(data)
        #expect(Set(readings.keys) == ["principal", "max"])
        let principal = try #require(readings["principal"])
        #expect(principal.snapshot.fetchedAt == Date(timeIntervalSince1970: 1_791_502_028))
        #expect(abs((principal.waitUntil?.timeIntervalSince1970 ?? 0) - 1_791_502_673.22) < 0.01)
        #expect(principal.snapshot.windows.map(\.key) == ["session", "weekly_all", "weekly_scoped:Fable"])
        #expect(principal.snapshot.session?.utilization == 33)
        #expect(principal.snapshot.windows.last?.title == "Semana · Fable")
        #expect(readings["max"]?.snapshot.fetchedAt == Date(timeIntervalSince1970: 1_791_502_589))
        #expect(readings["max"]?.snapshot.session?.resetsAt == nil)
        #expect(AccountRouter.parseRouterReadings(Data("[]".utf8)).isEmpty)
    }

    @Test func motivoDaTrocaEmPalavras() {
        #expect(AccountRouter.reasonText("five_hour") == "limite de 5h")
        #expect(AccountRouter.reasonText("seven_day_opus") == "limite da semana")
        #expect(AccountRouter.reasonText("agents preventiva") == "quase no limite, agentes")
        #expect(AccountRouter.reasonText("algo") == "algo")
    }

    // MARK: queue

    private func snapshot(session: Double, weekly: Double, sessionReset: TimeInterval = 3600) -> UsageSnapshot {
        var s = UsageSnapshot()
        s.windows = [
            LimitWindow(key: "session", title: "Sessão · 5h", utilization: session, resetsAt: Date().addingTimeInterval(sessionReset),
                        severity: "normal", isSession: true, isActive: true),
            LimitWindow(key: "weekly_all", title: "Semana", utilization: weekly, resetsAt: Date().addingTimeInterval(86_400),
                        severity: "normal", isSession: false, isActive: true),
        ]
        return s
    }

    private func entry(_ id: String, _ role: AccountRouter.Account.Role = .route, used: Double, login: Bool = true,
                       exhausted: Date? = nil, live: Bool = false) -> AccountQueue.Entry {
        AccountQueue.Entry(id: id, label: id.capitalized, monogram: id.prefix(2).uppercased(), role: role, plan: nil,
                           email: nil, organization: nil, snapshot: snapshot(session: used, weekly: used),
                           hasLogin: login, agentsLogin: true, exhaustedUntil: exhausted, isLive: live)
    }

    @Test func seguirAOrdemAbreNaPrimeiraComFolgaEAProximaEADaFila() {
        let q = AccountQueue(entries: [entry("aegro", used: 40), entry("max", used: 0), entry("compare", .reserve, used: 46)],
                             strategy: .order, enabled: true, configured: true)
        #expect(q.newSessions() == "aegro")
        #expect(q.next(after: "aegro") == "max")
        #expect(q.next(after: "max") == "aegro")
    }

    @Test func maisFolgaAbreNaQueTemMaisFolga() {
        let q = AccountQueue(entries: [entry("aegro", used: 40), entry("max", used: 0), entry("compare", .reserve, used: 0)],
                             strategy: .headroom, enabled: true, configured: true)
        #expect(q.newSessions() == "max")
        #expect(q.next(after: "max") == "aegro")
    }

    @Test func esgotadaESemLoginSaemDaEscolhaEAReservaEntra() {
        let soon = Date().addingTimeInterval(1800)
        let q = AccountQueue(entries: [entry("aegro", used: 100, exhausted: soon), entry("max", used: 10, login: false),
                                       entry("compare", .reserve, used: 46)],
                             strategy: .order, enabled: true, configured: true)
        #expect(q.newSessions() == "compare")
        #expect(q.next(after: "compare") == nil)
    }

    @Test func trocaDesligadaAbreNaPrincipalSemProxima() {
        let q = AccountQueue(entries: [entry("aegro", used: 100), entry("max", used: 0)],
                             strategy: .order, enabled: false, configured: true)
        #expect(q.newSessions() == "aegro")
        #expect(q.next(after: "aegro") == nil)
        // Plain claude opens on ~/.claude, whatever the order of the queue.
        let moved = AccountQueue(entries: [entry("max", used: 0), entry("aegro", used: 10)],
                                 strategy: .order, enabled: false, configured: true, principal: "aegro")
        #expect(moved.newSessions() == "aegro")
        let gone = AccountQueue(entries: [entry("max", used: 0)], strategy: .order, enabled: false, configured: true,
                                principal: "sumiu")
        #expect(gone.newSessions() == "max")
    }

    // MARK: commands

    @Test func comandoNaoEsperaUmAjudanteQueFicouComOPipe() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-ajudante-\(UUID().uuidString)")
        let started = Date()
        let result = AccountRouter.run(URL(fileURLWithPath: "/bin/sh"),
                                       ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; echo pronto"], timeout: 20)
        #expect(Date().timeIntervalSince(started) < 6)
        #expect(result.ok && result.output.contains("pronto"))
        if let pid = pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            kill(pid, SIGKILL)
        }
    }

    @Test func comandoQuePassaDoPrazoEEncerrado() {
        let started = Date()
        let result = AccountRouter.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo antes; exec sleep 30"], timeout: 1)
        #expect(Date().timeIntervalSince(started) < 6)
        #expect(!result.ok)
        #expect(result.output.contains("antes"))
    }

    @Test func moverDentroDaRotaParaAReservaEDeVolta() throws {
        let ids = ["aegro", "max", "compare"]
        // Combined list: aegro(0) max(1) [divider](2) compare(3)
        let up = try #require(AccountQueue.moving(ids, reserveFrom: 2, id: "max", to: 0))
        #expect(up.route == ["max", "aegro"] && up.reserve == ["compare"])
        // Dropped on a row, the account takes that row's place; dropped on the divider, it crosses it.
        let onRow = try #require(AccountQueue.moving(ids, reserveFrom: 2, id: "max", to: 3))
        #expect(onRow.route == ["aegro"] && onRow.reserve == ["compare", "max"])
        let onDivider = try #require(AccountQueue.moving(ids, reserveFrom: 2, id: "max", to: 2))
        #expect(onDivider.route == ["aegro"] && onDivider.reserve == ["max", "compare"])
        let toEnd = try #require(AccountQueue.moving(ids, reserveFrom: 2, id: "aegro", to: ids.count))
        #expect(toEnd.route == ["max"] && toEnd.reserve == ["compare", "aegro"])
        let back = try #require(AccountQueue.moving(ids, reserveFrom: 2, id: "compare", to: 2))
        #expect(back.route == ["aegro", "max", "compare"] && back.reserve.isEmpty)
        #expect(AccountQueue.moving(["aegro", "max"], reserveFrom: 1, id: "aegro", to: 2) == nil)
        #expect(AccountQueue.moving(ids, reserveFrom: 2, id: "sumiu", to: 0) == nil)
    }

    @Test func fraseDeStatusFalaEmTempoEDizQuemVemDepois() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let q = AccountQueue(entries: [entry("aegro", used: 33, live: true), entry("max", used: 0),
                                       entry("compare", .reserve, used: 46)],
                             strategy: .order, enabled: true, configured: true)
        let safe = AccountQueue.statusLine(queue: q, inUse: "aegro", outlook: .safe(rate: 17, reset: 2 * 3600), now: now)
        #expect(safe.hasPrefix("Dá para ir até o reset das \(Fmt.clock(now.addingTimeInterval(7200)))."))
        #expect(safe.hasSuffix("Se bater o limite, segue na Max."))
        let cap = AccountQueue.statusLine(queue: q, inUse: "aegro",
                                          outlook: .willHitCap(exhaustIn: 1800, reset: 7200, rate: 45, minutes: 30, aheadOfPace: true),
                                          now: now)
        #expect(cap.hasPrefix("No ritmo atual, acaba às \(Fmt.clock(now.addingTimeInterval(1800)))"))

        let off = AccountQueue(entries: q.entries, strategy: .order, enabled: false, configured: true)
        #expect(AccountQueue.statusLine(queue: off, inUse: "aegro", outlook: nil, now: now)
                == "A troca automática está desligada: as sessões ficam nesta conta.")

        let single = AccountQueue(entries: [entry("aegro", used: 33, live: true)], strategy: .order, enabled: false, configured: false)
        #expect(AccountQueue.statusLine(queue: single, inUse: "aegro", outlook: .measuring, now: now)
                == "Medindo o ritmo desta janela.")

        let lastOne = AccountQueue(entries: [entry("aegro", used: 33, live: true), entry("compare", .reserve, used: 46)],
                                   strategy: .order, enabled: true, configured: true)
        #expect(AccountQueue.statusLine(queue: lastOne, inUse: "aegro", outlook: nil, now: now)
                == "Se bater o limite, segue na Compare, da reserva.")
    }

    // MARK: assistant

    @MainActor @Test func enderecoDoLoginSoDosHostsDaAnthropicSemPontuacaoNoFim() {
        // What `claude auth login` prints today: the address inside an OSC 8 hyperlink, on claude.com.
        let printed = "Opening browser to sign in…\nIf the browser didn't open, visit: "
            + "\u{1b}]8;;https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=y\u{1b}\\"
            + "https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=y\u{1b}]8;;\u{1b}\\\nPaste code here if prompted > "
        #expect(AddAccountFlow.loginURL(in: printed)?.absoluteString
                == "https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=y")
        #expect(AddAccountFlow.loginURL(in: "https://platform.claude.com/oauth/authorize?x=1.")?.absoluteString
                == "https://platform.claude.com/oauth/authorize?x=1")
        #expect(AddAccountFlow.loginURL(in: "https://claude.ai/oauth/authorize?x=1")?.host == "claude.ai")
        #expect(AddAccountFlow.loginURL(in: "\u{1b}[1mhttps://console.anthropic.com/oauth/x\u{1b}[0m")?.host == "console.anthropic.com")
        #expect(AddAccountFlow.loginURL(in: "veja https://evil.example.com/claude.com") == nil)
        #expect(AddAccountFlow.loginURL(in: "https://claude.com.evil.io/oauth") == nil)
        #expect(AddAccountFlow.loginURL(in: "https://evilclaude.com/oauth") == nil)
        #expect(AddAccountFlow.loginURL(in: "http://claude.com/oauth") == nil)
        #expect(AddAccountFlow.loginURL(in: "sem link") == nil)
    }

    @MainActor @Test func motivoDaFalhaSemEscapesNemOsAvisosDoLogin() {
        let transcript = "Opening browser to sign in…\nIf the browser didn't open, visit: \u{1b}]8;;https://claude.com/x\u{1b}\\https://claude.com/x\u{1b}]8;;\u{1b}\\\n"
            + "Paste code here if prompted > \u{1b}[31mOAuth error: timeout\u{1b}[39m\n"
        #expect(AddAccountFlow.failureLine(transcript) == "OAuth error: timeout")
        #expect(AddAccountFlow.failureLine("claude-accounts: login cancelled\n") == "login cancelled")
        #expect(AddAccountFlow.failureLine("Opening browser to sign in…\nPaste code here if prompted > ") == nil)
    }

    @MainActor @Test func nomePadraoGanhaOPlanoQuandoBateComOutraConta() {
        #expect(AddAccountFlow.defaultName(label: "Thomas", plan: "max", taken: ["Thomas (Aegro)"]) == "Thomas (Max)")
        #expect(AddAccountFlow.defaultName(label: "Squad Compare", plan: "max", taken: ["Thomas (Aegro)"]) == "Squad Compare")
        #expect(AddAccountFlow.defaultName(label: "Thomas", plan: nil, taken: ["Thomas"]) == "Thomas")
    }

    @MainActor @Test func primeiraLinhaUtilDoErro() {
        #expect(AddAccountFlow.firstLine("\n  claude-accounts: unknown account: x\nmais") == "unknown account: x")
        #expect(AddAccountFlow.firstLine("   \n") == nil)
    }

    // MARK: sessions

    @Test func sessoesDeTodasAsPastasComAContaEUmaVezSo() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("monitor-sessions-\(UUID().uuidString)")
        let a = base.appendingPathComponent("a"), b = base.appendingPathComponent("b")
        for dir in [a, b] { try fm.createDirectory(at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true) }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        func write(_ dir: URL, _ name: String, pid: Int, sid: String) throws {
            try Data(#"{ "pid": \#(pid), "sessionId": "\#(sid)", "cwd": "/tmp/x", "startedAt": 1000 }"#.utf8)
                .write(to: dir.appendingPathComponent("sessions/\(name).json"))
        }
        try write(a, "1", pid: pid, sid: "s-a")
        try write(b, "2", pid: pid, sid: "s-b")
        try write(b, "3", pid: 999_999, sid: "morta")
        let sessions = ClaudeSessionStore.load(accounts: [(id: "max", directory: b), (id: "principal", directory: a)],
                                               defaultDirectory: base.appendingPathComponent("vazia"))
        #expect(sessions.count == 1)
        #expect(sessions.first?.accountId == "max")
        #expect(ClaudeSessionStore.load(directory: a.appendingPathComponent("sessions"), accountId: "principal").first?.accountId == "principal")
    }

    // MARK: format

    @Test func listaEmPortugues() {
        #expect(Fmt.list([]) == "")
        #expect(Fmt.list(["Stripe"]) == "Stripe")
        #expect(Fmt.list(["Magnific", "NetSuite", "Stripe"]) == "Magnific, NetSuite e Stripe")
    }

    @Test func diaDaSemanaSoNaSemanaQueVem() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(Fmt.weekday(now.addingTimeInterval(10 * 86_400), now: now).contains("/"))
        #expect(!Fmt.weekday(now.addingTimeInterval(2 * 86_400), now: now).contains("/"))
    }
}
