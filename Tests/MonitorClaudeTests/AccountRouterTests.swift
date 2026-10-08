import Foundation
import Testing
@testable import MonitorClaude

struct AccountRouterTests {
    let home = URL(fileURLWithPath: "/Users/exemplo/.claude-accounts")
    let defaultDirectory = URL(fileURLWithPath: "/Users/exemplo/.claude")

    private func config(_ json: String) throws -> AccountRouter.Config {
        try #require(AccountRouter.parseConfig(Data(json.utf8), home: home, defaultDirectory: defaultDirectory))
    }

    @Test func lêRotaReservaEPrincipal() throws {
        let cfg = try config("""
        { "principal": "pessoal", "ativo": false,
          "contas": { "pessoal": {}, "squad": { "nome": "Squad" }, "extra": {} },
          "rota": ["pessoal", "squad"], "reserva": ["extra"], "limites": { "reserva": 5 } }
        """)
        #expect(cfg.enabled == false)
        #expect(cfg.accounts.map(\.id) == ["pessoal", "squad", "extra"])
        #expect(cfg.accounts.map(\.role) == [.route, .route, .reserve])
        #expect(cfg.accounts[0].usesDefaultDirectory)
        #expect(cfg.accounts[0].directory == defaultDirectory)
        #expect(cfg.accounts[1].directory == home.appendingPathComponent("squad"))
        #expect(cfg.accounts[1].label == "Squad")
        #expect(cfg.reserveBelow == 5)
        #expect(cfg.hasExtraAccounts)
    }

    @Test func semAtivoNaConfigOContaComoLigado() throws {
        let cfg = try config(#"{ "contas": { "principal": {} } }"#)
        #expect(cfg.enabled)
        #expect(cfg.accounts.map(\.id) == ["principal"])
        #expect(!cfg.hasExtraAccounts)
    }

    @Test func contaFantasmaNaRotaÉIgnorada() throws {
        let cfg = try config(#"{ "contas": { "principal": {} }, "rota": ["principal", "sumiu"] }"#)
        #expect(cfg.accounts.map(\.id) == ["principal"])
    }

    @Test func rotaVaziaNãoDuplicaAPrincipalNaReserva() throws {
        let cfg = try config(#"{ "contas": { "principal": {}, "squad": {} }, "rota": [], "reserva": ["principal", "squad"] }"#)
        #expect(cfg.accounts.map(\.id) == ["principal", "squad"])
        #expect(cfg.accounts.map(\.role) == [.route, .reserve])
    }

    @Test func serviçoDoKeychainSegueOClaudeCode() throws {
        let cfg = try config(#"{ "contas": { "principal": {}, "squad": {} }, "rota": ["principal", "squad"] }"#)
        #expect(AccountRouter.keychainService(for: cfg.accounts[0]) == "Claude Code-credentials")
        #expect(AccountRouter.keychainService(for: cfg.accounts[1]) == "Claude Code-credentials-e04c6421")
    }

    @Test func folgaÉCemMenosOMaiorUsoEntre5hESemana() {
        let now = Date()
        var snap = UsageSnapshot()
        snap.windows = [
            LimitWindow(key: "session", title: "", utilization: 40, resetsAt: now.addingTimeInterval(3600),
                        severity: "normal", isSession: true, isActive: true),
            LimitWindow(key: "weekly_all", title: "", utilization: 97, resetsAt: now.addingTimeInterval(86400),
                        severity: "critical", isSession: false, isActive: true),
        ]
        #expect(AccountRouter.headroom(snap, now: now) == 3)

        snap.windows[1].resetsAt = now.addingTimeInterval(-60)
        #expect(AccountRouter.headroom(snap, now: now) == 60)
    }

    @Test func escolheAMaiorFolgaDaRotaEUsaReservaSóAbaixoDoLimite() throws {
        let cfg = try config("""
        { "contas": { "principal": {}, "squad": {}, "extra": {} },
          "rota": ["principal", "squad"], "reserva": ["extra"] }
        """)
        let all: Set<String> = ["principal", "squad", "extra"]

        #expect(AccountRouter.pick(cfg, headroom: ["principal": 10, "squad": 52, "extra": 90],
                                   available: all, exhausted: [:]) == "squad")
        #expect(AccountRouter.pick(cfg, headroom: ["principal": 2, "squad": 1, "extra": 90],
                                   available: all, exhausted: [:]) == "extra")
        #expect(AccountRouter.pick(cfg, headroom: ["principal": 30, "squad": 30],
                                   available: all, exhausted: [:]) == "principal")
        #expect(AccountRouter.pick(cfg, headroom: ["principal": 10, "squad": 52],
                                   available: all, exhausted: ["squad": Date().addingTimeInterval(600)]) == "principal")
        #expect(AccountRouter.pick(cfg, headroom: ["principal": 10, "squad": 52],
                                   available: ["principal"], exhausted: [:]) == "principal")
        #expect(AccountRouter.pick(cfg, headroom: ["principal": 0, "squad": 0, "extra": 0],
                                   available: all, exhausted: [:]) == nil)
    }

    @Test func lêAÚltimaTrocaEAsEsgotadasVigentes() throws {
        let line = #"{"em":1791398700000,"de":"principal","para":"squad","motivo":"five_hour","sessao":"abc"}"#
        let last = try #require(AccountRouter.parseSwitch(Data(line.utf8)))
        #expect(last.from == "principal")
        #expect(last.to == "squad")
        #expect(last.reason == "five_hour")
        #expect(last.at == Date(timeIntervalSince1970: 1_791_398_700))

        let now = Date(timeIntervalSince1970: 1_791_400_000)
        let exhausted = AccountRouter.parseExhausted(Data("""
        { "principal": { "ate": 1791403600000, "motivo": "five_hour" },
          "squad": { "ate": 1791390000000, "motivo": "seven_day" } }
        """.utf8), now: now)
        #expect(exhausted.keys.sorted() == ["principal"])
    }

    @Test func apontaContasLogadasNaMesmaConta() throws {
        let cfg = try config(#"{ "principal": "pessoal", "contas": { "pessoal": {}, "squad": {}, "extra": {} }, "rota": ["pessoal", "squad", "extra"] }"#)
        let mesma = AccountIdentity(accountUuid: "a", organizationUuid: "o", email: "squad@exemplo.com")
        let outra = AccountIdentity(accountUuid: "b", organizationUuid: "o", email: "pessoal@exemplo.com")
        var state = RouterState(config: cfg, pick: "squad", usage: [:], lastSwitch: nil,
                                logins: ["pessoal": mesma, "squad": mesma, "extra": outra])
        #expect(state.sharedLogins == [["pessoal", "squad"]])
        #expect(state.isRouted(mesma.key))

        state.logins["pessoal"] = AccountIdentity(accountUuid: "c", organizationUuid: "o")
        #expect(state.sharedLogins.isEmpty)
    }

    @Test func leituraFrescaSoParaContaLidaPeloRoteador() throws {
        let cfg = try config(#"{ "principal": "pessoal", "contas": { "pessoal": {}, "squad": {} }, "rota": ["pessoal", "squad"] }"#)
        let squad = AccountIdentity(accountUuid: "a", organizationUuid: "o", email: "squad@exemplo.com")
        let snapshot = UsageSnapshot(windows: [
            LimitWindow(key: "session", title: "Sessão", utilization: 40, resetsAt: Date(timeIntervalSince1970: 100),
                        severity: "normal", isSession: true, isActive: true)])
        var state = RouterState(config: cfg, pick: nil, usage: ["squad": snapshot], lastSwitch: nil,
                                logins: ["squad": squad])
        #expect(state.freshSnapshot(forKey: squad.key) == nil)
        state.read = [squad.key]
        #expect(state.freshSnapshot(forKey: squad.key) == snapshot)
        #expect(state.freshSnapshot(forKey: "outra:o") == nil)
    }

    @Test func janelaRenovadaQuandoOResetJaPassou() {
        let now = Date(timeIntervalSince1970: 1_000)
        func window(_ reset: Date?) -> LimitWindow {
            LimitWindow(key: "session", title: "Sessão", utilization: 40, resetsAt: reset,
                        severity: "normal", isSession: true, isActive: true)
        }
        #expect(window(now.addingTimeInterval(-1)).hasReset(at: now))
        #expect(window(now).hasReset(at: now))
        #expect(!window(now.addingTimeInterval(60)).hasReset(at: now))
        #expect(!window(nil).hasReset(at: now))
    }

    @Test func contaSemLoginNoTerminalMostraOComandoDeLogin() throws {
        let cfg = try config(#"{ "principal": "squad", "contas": { "pessoal": {}, "squad": {} }, "rota": ["squad", "pessoal"] }"#)
        let squad = AccountIdentity(accountUuid: "a", organizationUuid: "o", email: "squad@exemplo.com")
        let state = RouterState(config: cfg, pick: "squad", usage: [:], lastSwitch: nil,
                                logins: ["squad": squad], available: ["squad"])
        #expect(state.loginLabel(for: "squad") == "squad@exemplo.com")
        #expect(state.loginLabel(for: "pessoal") == "sem login: claude-accounts login pessoal")
    }

    @Test func ligarEDesligarPreservaORestoDaConfig() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"principal":"pessoal","rota":["pessoal","squad"],"contas":{"pessoal":{},"squad":{}}}"#.utf8).write(to: url)

        try AccountRouter.setEnabled(false, at: url)
        let off = try config(String(decoding: try Data(contentsOf: url), as: UTF8.self))
        #expect(off.enabled == false)
        #expect(off.principal == "pessoal")
        #expect(off.accounts.map(\.id) == ["pessoal", "squad"])

        try AccountRouter.setEnabled(true, at: url)
        #expect(try config(String(decoding: try Data(contentsOf: url), as: UTF8.self)).enabled)
    }

    @Test func lêAContaPreferidaSóSeElaEstiverNaRotaOuReserva() throws {
        #expect(try config(#"{ "contas": { "principal": {}, "squad": {} }, "rota": ["principal", "squad"], "preferida": "squad" }"#).preferred == "squad")
        #expect(try config(#"{ "contas": { "principal": {}, "squad": {} }, "rota": ["principal", "squad"], "preferida": "sumiu" }"#).preferred == nil)
        #expect(try config(#"{ "contas": { "principal": {} } }"#).preferred == nil)
    }

    @Test func salvarAPreferidaPreservaORestoDaConfigENenhumaRemoveAChave() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"principal":"pessoal","ativo":false,"limites":{"reserva":5,"voltar":30},"rota":["pessoal","squad"],"contas":{"pessoal":{},"squad":{}}}"#.utf8).write(to: url)

        try AccountRouter.setPreferred("squad", at: url)
        let set = try config(String(decoding: try Data(contentsOf: url), as: UTF8.self))
        #expect(set.preferred == "squad")
        #expect(set.enabled == false)
        #expect(set.reserveBelow == 5)
        #expect(set.accounts.map(\.id) == ["pessoal", "squad"])
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((root["limites"] as? [String: Any])?["voltar"] as? Int == 30)

        try AccountRouter.setPreferred(nil, at: url)
        let cleared = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(cleared["preferida"] == nil)
        #expect(cleared["principal"] as? String == "pessoal")
    }

    @Test func preferidaComFolgaGanhaDaMaiorFolga() throws {
        let cfg = try config("""
        { "contas": { "principal": {}, "squad": {}, "extra": {} },
          "rota": ["principal", "squad"], "reserva": ["extra"], "preferida": "principal" }
        """)
        let all: Set<String> = ["principal", "squad", "extra"]

        #expect(AccountRouter.pick(cfg, headroom: ["principal": 10, "squad": 52, "extra": 90],
                                   available: all, exhausted: [:]) == "principal")
        #expect(AccountRouter.pick(cfg, headroom: ["principal": 2, "squad": 52, "extra": 90],
                                   available: all, exhausted: [:]) == "squad")
        #expect(AccountRouter.pick(cfg, headroom: ["principal": 10, "squad": 52],
                                   available: all, exhausted: ["principal": Date().addingTimeInterval(600)]) == "squad")
        #expect(AccountRouter.pick(cfg, headroom: ["principal": 10, "squad": 52],
                                   available: ["squad"], exhausted: [:]) == "squad")
    }

    @Test func salvarAConfigRespeitaATravaDoRoteador() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let lock = dir.appendingPathComponent("config.json.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try Data(#"{"ativo":true}"#.utf8).write(to: url)

        #expect(throws: AccountRouter.ConfigBusy.self) {
            try AccountRouter.withFileLock(for: url, timeout: 0.2) {}
        }
        #expect(FileManager.default.fileExists(atPath: lock.path))

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { try? FileManager.default.removeItem(at: lock) }
        try AccountRouter.setEnabled(false, at: url)
        #expect(try config(String(decoding: try Data(contentsOf: url), as: UTF8.self)).enabled == false)
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func travaVelhaDaConfigÉTomada() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let lock = dir.appendingPathComponent("config.json.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: lock.path)

        try AccountRouter.setPreferred("squad", at: url)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["preferida"] as? String == "squad")
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func travaVelhaSendoTomadaPorOutroFicaComEle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let lock = dir.appendingPathComponent("config.json.lock")
        let claim = lock.appendingPathComponent("tomada")
        try FileManager.default.createDirectory(at: claim, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: lock.path)

        #expect(throws: AccountRouter.ConfigBusy.self) {
            try AccountRouter.withFileLock(for: url, timeout: 0.2) {}
        }
        #expect(FileManager.default.fileExists(atPath: claim.path))
    }

    @Test func tomadaAbandonadaNaTravaVelhaNãoAtrasaATomada() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let lock = dir.appendingPathComponent("config.json.lock")
        let claim = lock.appendingPathComponent("tomada")
        try FileManager.default.createDirectory(at: claim, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: claim.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lock.path)

        try AccountRouter.withFileLock(for: url, timeout: 0.5) {}
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func donoSoltaATravaComTomadaAbandonadaDentro() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let lock = dir.appendingPathComponent("config.json.lock")
        let claim = lock.appendingPathComponent("tomada")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try AccountRouter.withFileLock(for: url) {
            try FileManager.default.createDirectory(at: claim, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: claim.path)
        }
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func donoDeixaATravaParaQuemEstáTomando() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let claim = dir.appendingPathComponent("config.json.lock/tomada")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try AccountRouter.withFileLock(for: url) {
            try FileManager.default.createDirectory(at: claim, withIntermediateDirectories: false)
        }
        #expect(FileManager.default.fileExists(atPath: claim.path))
    }

    @Test func ritmoDoSlotUsaAJanelaQueLimitaEmPontosPorMinuto() throws {
        let now = Date(timeIntervalSince1970: 1_791_400_000)
        var snap = UsageSnapshot(windows: [
            LimitWindow(key: "session", title: "", utilization: 40, resetsAt: now.addingTimeInterval(3600),
                        severity: "normal", isSession: true, isActive: true),
            LimitWindow(key: "weekly_all", title: "", utilization: 97, resetsAt: now.addingTimeInterval(86400),
                        severity: "critical", isSession: false, isActive: true),
        ], fetchedAt: now.addingTimeInterval(-60))
        let session = BurnRate(percentPerHour: 60, basedOnMinutes: 30)
        let weekly = BurnRate(percentPerHour: 3, basedOnMinutes: 120)

        let semanal = try #require(AccountRouter.slotBurnRate(account: "u:o", snapshot: snap, session: session,
                                                              weekly: weekly, now: now))
        #expect(semanal.account == "u:o")
        #expect(semanal.window == "sete")
        #expect(abs(semanal.pointsPerMinute - 0.05) < 1e-12)
        #expect(semanal.used == 97)
        #expect(semanal.usedAt == now.addingTimeInterval(-60))
        #expect(semanal.at == now)
        #expect(AccountRouter.slotBurnRate(account: "u:o", snapshot: snap, session: session, weekly: nil, now: now) == nil)

        snap.windows[1].resetsAt = now.addingTimeInterval(-60)
        let daSessão = try #require(AccountRouter.slotBurnRate(account: "u:o", snapshot: snap, session: session,
                                                               weekly: weekly, now: now))
        #expect(daSessão.window == "cinco")
        #expect(daSessão.pointsPerMinute == 1)
        #expect(daSessão.used == 40)
        #expect(AccountRouter.slotBurnRate(account: "u:o", snapshot: snap, session: nil, weekly: weekly, now: now) == nil)
        #expect(AccountRouter.slotBurnRate(account: "u:o", snapshot: UsageSnapshot(), session: session,
                                           weekly: weekly, now: now) == nil)
    }

    @Test func ritmoPublicadoTemOsCamposQueORoteadorLê() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".estado/ritmo.json")
        let rate = SlotBurnRate(account: "u:o", window: "cinco", pointsPerMinute: 1.5, used: 92,
                                usedAt: Date(timeIntervalSince1970: 1_791_399_940), at: Date(timeIntervalSince1970: 1_791_400_000))

        try AccountRouter.publish(rate, to: url)
        try AccountRouter.publish(rate, to: url)

        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(root.keys) == ["conta", "janela", "ppPorMinuto", "usado", "usadoEm", "em"])
        #expect(root["conta"] as? String == "u:o")
        #expect(root["janela"] as? String == "cinco")
        #expect((root["ppPorMinuto"] as? NSNumber)?.doubleValue == 1.5)
        #expect((root["usado"] as? NSNumber)?.doubleValue == 92)
        #expect((root["usadoEm"] as? NSNumber)?.doubleValue == 1_791_399_940_000)
        #expect((root["em"] as? NSNumber)?.doubleValue == 1_791_400_000_000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["ritmo.json"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func loginDeAgentesMarcadoComoInválidoNãoContaComoPronto() {
        #expect(AccountRouter.isUsableAgentsLogin(Data(#"{"chave":"u:o","guardadoEm":1}"#.utf8)))
        #expect(!AccountRouter.isUsableAgentsLogin(Data(#"{"chave":"u:o","invalidoEm":2,"motivoInvalido":"HTTP 401"}"#.utf8)))
        #expect(!AccountRouter.isUsableAgentsLogin(Data("{".utf8)))
    }

    @Test func ligarComConfigIlegívelNãoApagaOArquivo() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data(#"{"principal":"pessoal","rota":["pessoal","squad"],"#.utf8)
        try broken.write(to: url)

        #expect(throws: AccountRouter.UnreadableConfig.self) { try AccountRouter.setEnabled(false, at: url) }
        #expect(try Data(contentsOf: url) == broken)
    }

    @Test func instalarComandosCriaLinksSemSobrescreverArquivoDeVerdade() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bundle/bin")
        let target = root.appendingPathComponent("local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("own".utf8).write(to: target.appendingPathComponent("claude-accounts"))

        try AccountRouter.installCommands(from: bin, into: target)

        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: target.appendingPathComponent("claude-auto").path) == bin.appendingPathComponent("claude-auto").path)
        #expect(try String(contentsOf: target.appendingPathComponent("claude-accounts"), encoding: .utf8) == "own")
    }
}
