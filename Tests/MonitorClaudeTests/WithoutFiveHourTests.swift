import Foundation
import Testing
@testable import MonitorClaude

/// A verified Ultra account has no 5h window: `/api/oauth/usage` sends `five_hour: null` and only the weekly limits.
/// Everything that read the 5h window falls back to the week on such an account and stays as before on one that has it.
struct WithoutFiveHourTests {
    private let now = Date(timeIntervalSince1970: 1_793_700_000)

    private func window(_ key: String, _ used: Double, resetsIn: TimeInterval?) -> LimitWindow {
        LimitWindow(key: key, title: key, utilization: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                    severity: "normal", isSession: key == "session", isActive: true)
    }

    @Test func respostaSemFiveHourNãoTemJanelaDe5hEOTítuloÉASemana() {
        let root: [String: Any] = [
            "five_hour": NSNull(),
            "seven_day": ["utilization": 9, "resets_at": "2026-11-09T08:00:00.352607+00:00"],
            "limits": [
                ["kind": "weekly_all", "percent": 9, "severity": "normal", "resets_at": "2026-11-09T08:00:00.352607+00:00",
                 "is_active": true],
                ["kind": "weekly_scoped", "percent": 0, "severity": "normal", "resets_at": "2026-11-09T08:00:00+00:00",
                 "scope": ["model": ["display_name": "Fable"]], "is_active": false],
            ],
        ]
        let snap = UsageAPI.parse(root)
        #expect(snap.session == nil)
        #expect(snap.fiveHour == nil)
        #expect(snap.headline?.key == "weekly_all")
        #expect(snap.headline?.utilization == 9)
    }

    @Test func comJanelaDe5hOTítuloContinuaSendoEla() {
        let snap = UsageSnapshot(windows: [window("session", 12, resetsIn: 3600), window("weekly_all", 98, resetsIn: 86_400)],
                                 fetchedAt: now)
        #expect(snap.headline?.isSession == true)
        #expect(snap.headline?.utilization == 12)
        let idle = UsageSnapshot(windows: [window("session", 0, resetsIn: nil), window("weekly_all", 98, resetsIn: 86_400)],
                                 fetchedAt: now)
        #expect(idle.headline?.isSession == true)
    }

    /// The last 5h window an account had before it lost the limit stays in its stored reading; live numbers without a
    /// 5h window merged into it must not bring it back.
    @Test func janelaDe5hVelhaDeLeituraGuardadaNãoVoltaAoTítulo() {
        let stored = UsageSnapshot(windows: [window("session", 64, resetsIn: -3 * 86_400), window("weekly_all", 40, resetsIn: 86_400)],
                                   fetchedAt: now.addingTimeInterval(-3 * 86_400 - 3600))
        let live = UsageSnapshot(windows: [window("weekly_all", 49, resetsIn: 86_400)], fetchedAt: now)
        let merged = AccountRouter.merging(live, into: stored, now: now)
        #expect(merged.fiveHour == nil)
        #expect(merged.headline?.key == "weekly_all")
        #expect(merged.headline?.utilization == 49)
    }

    /// A Max account read at 14:00 with its 5h window resetting at 16:00, not read again: at 16:30 it still has the
    /// 5h limit, just free.
    @Test func contaComCincoHorasLidaAntesDoResetContinuaComCincoHoras() throws {
        let snap = UsageSnapshot(windows: [window("session", 40, resetsIn: -1800), window("weekly_all", 30, resetsIn: 86_400)],
                                 fetchedAt: now.addingTimeInterval(-9000))
        let fiveHour = try #require(snap.fiveHour)
        #expect(fiveHour.hasReset(at: now))
        #expect(AccountRouter.used(fiveHour, now: now) == 0)
    }

    @Test func ritmoDoSlotSemJanelaDe5hUsaASemanaMesmoZerada() throws {
        let snap = UsageSnapshot(windows: [window("weekly_all", 0, resetsIn: 86_400)], fetchedAt: now)
        let rate = try #require(AccountRouter.slotBurnRate(account: "u:o", snapshot: snap, session: nil,
                                                           weekly: BurnRate(percentPerHour: 1.2, basedOnMinutes: 90), now: now))
        #expect(rate.window == "sete")
        #expect(rate.used == 0)
    }

    @Test func amostraDoAppDesktopSemFhValeSóPelaSemana() throws {
        let data = Data("""
        {"version": 2, "samples": [
          {"t": 1793600000000, "org": "o", "u": {"fh": null, "sd": 40}},
          {"t": 1793600300000, "org": "o", "u": {"sd": 41}}
        ]}
        """.utf8)
        let series = try #require(ClaudeDesktop.parseSamples(data)["o"])
        #expect(series.count == 2)
        #expect(series.allSatisfy { $0.fiveHour == nil })
        let snap = try #require(DesktopUsage.snapshot(series: series, weeklyAnchor: nil, now: now))
        #expect(snap.session == nil)
        #expect(snap.headline?.utilization == 41)
    }

    @Test func fraseDeStatusDaSemanaFalaODiaDoReset() {
        let weekly = window("weekly_all", 30, resetsIn: 3 * 86_400)
        let entry = AccountQueue.Entry(id: "sf2", label: "SF2", monogram: "SF", role: .route, plan: nil, email: nil,
                                       organization: nil, snapshot: UsageSnapshot(windows: [weekly]), hasLogin: true,
                                       agentsLogin: true, exhaustedUntil: nil, isLive: true)
        let q = AccountQueue(entries: [entry], strategy: .order, enabled: false, configured: false)
        let safe = AccountQueue.statusLine(queue: q, inUse: "sf2",
                                           outlook: .safe(rate: 1, reset: 3 * 86_400, window: weekly), now: now)
        #expect(safe == "Dá para ir até o reset da semana, \(Fmt.weekday(now.addingTimeInterval(3 * 86_400), now: now)).")
        let cap = AccountQueue.statusLine(queue: q, inUse: "sf2",
                                          outlook: .willHitCap(exhaustIn: 2 * 86_400, reset: 3 * 86_400, rate: 2, minutes: 120,
                                                               aheadOfPace: true, window: weekly), now: now)
        #expect(cap.hasPrefix("No ritmo atual, a semana acaba \(Fmt.weekday(now.addingTimeInterval(2 * 86_400), now: now));"))
    }
}

/// The widget is about the account in use: the agents' while a background agent runs, else where the sessions run;
/// the other accounts at work are the second line.
struct FocusAndRefreshTests {
    private func entry(_ id: String) -> AccountQueue.Entry {
        AccountQueue.Entry(id: id, label: id.capitalized, monogram: String(id.prefix(2)).uppercased(), role: .route, plan: nil,
                           email: nil, organization: nil, snapshot: nil, hasLogin: true, agentsLogin: true, exhaustedUntil: nil)
    }

    @Test func topoDizOndeOsAgentesRodamEOTerminalVemEmSegundo() {
        let q = AccountQueue(entries: [entry("financeiro"), entry("financeiro2")], strategy: .order, enabled: true,
                             configured: true, agents: "financeiro2", agentsRunning: true)
        #expect(q.newSessions() == "financeiro")
        #expect(q.focus() == "financeiro2")
        #expect(AccountQueue.focusCaption(queue: q, focus: q.focus()) == "Agentes e sessões em segundo plano rodam na")
        #expect(AccountQueue.terminalNote(queue: q, focus: q.focus(), terminal: q.newSessions())
                == "Cada claude novo no terminal abre na Financeiro, a primeira da fila com folga. Os agentes ficam na Financeiro2 até ela chegar no limite e só então trocam.")
    }

    @Test func juntosNãoHáSegundaLinha() {
        let q = AccountQueue(entries: [entry("financeiro"), entry("financeiro2")], strategy: .order, enabled: true,
                             configured: true, agents: "financeiro")
        #expect(AccountQueue.terminalNote(queue: q, focus: q.focus(), terminal: q.newSessions()) == nil)
    }

    @Test func contaEscolhidaNoTopoDizOndeOsAgentesSeguem() {
        let q = AccountQueue(entries: [entry("financeiro"), entry("financeiro2")], strategy: .order, enabled: true,
                             configured: true, pinned: "financeiro", agents: "financeiro2")
        #expect(q.focus() == "financeiro")
        #expect(AccountQueue.focusCaption(queue: q, focus: q.focus()) == "Você escolheu: sessões novas abrem na")
        #expect(AccountQueue.terminalNote(queue: q, focus: q.focus(), terminal: q.newSessions()) == "Os agentes ficam na Financeiro2 até ela chegar no limite e só então trocam.")
    }

    /// 11/11/2026: the agents' account showed "em uso" with no session on it, while the 6 sessions open ran on the
    /// terminal's account.
    @Test func semAgenteRodandoOTopoÉOndeAsSessõesRodam() {
        var compare = entry("compare")
        compare.sessions = 6
        let q = AccountQueue(entries: [entry("ultra"), compare], strategy: .headroom, enabled: true,
                             configured: true, agents: "ultra")
        #expect(q.focus() == "compare")
        #expect(AccountQueue.focusCaption(queue: q, focus: q.focus()) == "Suas sessões rodam na")
        #expect(AccountQueue.terminalNote(queue: q, focus: q.focus(), terminal: q.newSessions())
                == "Cada claude novo no terminal abre na Ultra, a de mais folga até renovar. Os agentes ficam na Ultra até ela chegar perto do limite ou outra conta da rota, com folga de sobra, render pelo menos o dobro até renovar.")

        // A background agent running takes the top back to the agents' account.
        var running = q
        running.agentsRunning = true
        #expect(running.focus() == "ultra")
        #expect(AccountQueue.focusCaption(queue: running, focus: running.focus()) == "Agentes e sessões em segundo plano rodam na")
    }

    @Test func sessõesNaContaDasNovasDizemAsDuasCoisas() {
        var aberta = entry("financeiro")
        aberta.sessions = 2
        let q = AccountQueue(entries: [aberta, entry("financeiro2")], strategy: .order, enabled: true,
                             configured: true, agents: "financeiro2")
        #expect(q.focus() == "financeiro")
        #expect(AccountQueue.focusCaption(queue: q, focus: q.focus()) == "Suas sessões rodam e as novas abrem na")
        #expect(AccountQueue.terminalNote(queue: q, focus: q.focus(), terminal: q.newSessions())
                == "Os agentes ficam na Financeiro2 até ela chegar no limite e só então trocam.")
    }

    @Test func trocaDesligadaNãoPrometeQueOsAgentesTrocam() {
        var aberta = entry("financeiro")
        aberta.sessions = 2
        let q = AccountQueue(entries: [aberta, entry("financeiro2")], strategy: .order, enabled: false,
                             configured: true, agents: "financeiro2")
        #expect(q.focus() == "financeiro")
        #expect(AccountQueue.terminalNote(queue: q, focus: q.focus(), terminal: q.newSessions())
                == "Os agentes rodam na Financeiro2; com a troca automática desligada, ficam nela.")
    }

    @Test func empateDeSessõesFicaComAContaDasNovas() {
        var a = entry("financeiro"), b = entry("financeiro2")
        a.sessions = 1
        b.sessions = 1
        let q = AccountQueue(entries: [b, a], strategy: .order, enabled: true, configured: true, pinned: nil)
        #expect(q.newSessions() == "financeiro2")
        #expect(q.focus() == "financeiro2")
        let other = AccountQueue(entries: [a, b], strategy: .order, enabled: true, configured: true)
        #expect(other.focus() == "financeiro")
    }

    @Test func nadaRodandoOTopoÉOndeAPróximaSessãoAbre() {
        let q = AccountQueue(entries: [entry("financeiro"), entry("financeiro2")], strategy: .order, enabled: true,
                             configured: true, agents: "financeiro2")
        #expect(q.focus() == "financeiro")
        #expect(AccountQueue.focusCaption(queue: q, focus: q.focus()) == "Sessões novas abrem na")
    }

    @Test func próximaDosAgentesSóEntreContasComLoginDeAgentes() {
        var semAgentes = entry("financeiro")
        semAgentes.agentsLogin = false
        let q = AccountQueue(entries: [semAgentes, entry("financeiro2"), entry("gabriel")], strategy: .order, enabled: true,
                             configured: true, agents: "financeiro2")
        #expect(q.next(after: "financeiro2") == "gabriel")
        #expect(q.next(after: "gabriel") == "financeiro")
    }

    @Test func fraseDeMaisFolgaSóParaAContaDasSessõesNovas() {
        var agentes = entry("financeiro2")
        agentes.snapshot = UsageSnapshot(windows: [LimitWindow(key: "weekly_all", title: "Semana", utilization: 50,
                                                               resetsAt: Date().addingTimeInterval(86_400), severity: "normal",
                                                               isSession: false, isActive: true)])
        var terminal = entry("financeiro")
        terminal.snapshot = UsageSnapshot(windows: [LimitWindow(key: "weekly_all", title: "Semana", utilization: 9,
                                                                resetsAt: Date().addingTimeInterval(86_400), severity: "normal",
                                                                isSession: false, isActive: true)])
        let q = AccountQueue(entries: [terminal, agentes], strategy: .headroom, enabled: true, configured: true,
                             agents: "financeiro2")
        #expect(q.newSessions() == "financeiro")
        let line = AccountQueue.statusLine(queue: q, inUse: "financeiro2", outlook: nil)
        #expect(!line.contains("mais folga"))
        #expect(AccountQueue.statusLine(queue: q, inUse: "financeiro", outlook: nil).contains("mais folga"))
    }

    @Test func contaDoSlotParadaNãoPrometeRenovação() {
        #expect(AccountQueue.idleReason(nil, id: "principal", renewable: false) == "login vencido, volta na próxima sessão nela")
    }

    @Test func renovaçõesDoRoteadorViramMotivoLegível() {
        let data = Data("""
        {"parada": {"em": 1793700000000, "resultado": "renovado", "ate": 1793728800000},
         "viva": {"em": 1793700000000, "resultado": "em-uso", "processos": 2},
         "ruim": {"em": 1793700000000, "resultado": "falhou", "erro": "the CLI took too long"},
         "torta": {"resultado": "renovado"}}
        """.utf8)
        let refreshes = AccountRouter.parseRefreshes(data)
        #expect(refreshes.count == 3)
        #expect(refreshes["parada"]?.outcome == .renewed)
        #expect(refreshes["viva"]?.outcome == .inUse)
        #expect(refreshes["ruim"]?.outcome == .failed("the CLI took too long"))
        #expect(AccountQueue.idleReason(refreshes["ruim"], id: "ruim")
                == "o login venceu e não renovou (the CLI took too long): rode claude-accounts login ruim")
        #expect(AccountQueue.idleReason(nil, id: "x") == "login vencido, o roteador renova em instantes")
    }
}
