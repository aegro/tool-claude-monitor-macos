import Foundation
import Testing
@testable import MonitorClaude

/// Where the numbers come from when the `/usage` endpoint is rate-limited: the limits a stream session received
/// (saved by the router), the server's own pause, and the Keychain read that never prompts.
struct LiveDataTests {
    @Test func limitesAoVivoDoRoteadorViramJanelasDoPainel() throws {
        let data = Data(#"""
        { "em": 1791500000000, "status": "allowed",
          "janelas": { "five_hour": { "usado": 41.2, "renovaEm": 1791514800000 },
                       "seven_day": { "usado": 76, "renovaEm": 1791630000000 },
                       "seven_day_overage_included": { "usado": 3, "renovaEm": null } } }
        """#.utf8)
        let live = try #require(AccountRouter.parseLiveLimits(data))
        let snap = live.snapshot
        #expect(live.key == nil)
        #expect(snap.fetchedAt == Date(timeIntervalSince1970: 1_791_500_000))
        #expect(snap.windows.map(\.key) == ["session", "weekly_all"])
        #expect(snap.session?.utilization == 41.2)
        #expect(snap.session?.resetsAt == Date(timeIntervalSince1970: 1_791_514_800))
        #expect(snap.weekly?.title == "Semana")
        let comConta = Data(#"{"em": 1, "conta": "conta-a:org-1", "janelas": {"five_hour": {"usado": 5}}}"#.utf8)
        #expect(AccountRouter.parseLiveLimits(comConta)?.key == "conta-a:org-1")
        #expect(AccountRouter.parseLiveLimits(Data(#"{"em": 1, "janelas": {}}"#.utf8)) == nil)
        #expect(AccountRouter.parseLiveLimits(Data("lixo".utf8)) == nil)
    }

    @Test func pastaDoRoteadorDaUmaLeituraPorConta() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-ao-vivo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"em": 1791500000000, "janelas": {"five_hour": {"usado": 10, "renovaEm": null}}}"#.utf8)
            .write(to: dir.appendingPathComponent("principal.json"))
        try Data("quebrado".utf8).write(to: dir.appendingPathComponent("max.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("principal.json.123.tmp"))
        let all = AccountRouter.liveLimits(in: dir)
        #expect(Set(all.keys) == ["principal"])
        #expect(all["principal"]?.snapshot.session?.utilization == 10)
        #expect(AccountRouter.liveLimits(in: dir.appendingPathComponent("nao-existe")).isEmpty)
    }

    @Test func leituraAoVivoAtualizaSoAsJanelasQueEstaTraz() {
        var base = UsageSnapshot()
        base.windows = [
            LimitWindow(key: "session", title: "Sessão · 5h", utilization: 20, resetsAt: nil, severity: "warning",
                        isSession: true, isActive: true, resetIsExact: false),
            LimitWindow(key: "weekly_scoped:Opus", title: "Semana · Opus", utilization: 50, resetsAt: nil,
                        severity: "normal", isSession: false, isActive: false),
        ]
        base.extraUsageEnabled = true
        base.fetchedAt = Date(timeIntervalSince1970: 1_000)
        var live = UsageSnapshot()
        let reset = Date(timeIntervalSince1970: 9_000)
        live.windows = [
            LimitWindow(key: "session", title: "Sessão · 5h", utilization: 33, resetsAt: reset, severity: "normal",
                        isSession: true, isActive: true),
            LimitWindow(key: "weekly_all", title: "Semana", utilization: 70, resetsAt: nil, severity: "normal",
                        isSession: false, isActive: false),
        ]
        live.fetchedAt = Date(timeIntervalSince1970: 5_000)
        let merged = AccountRouter.merging(live, into: base)
        #expect(merged.fetchedAt == live.fetchedAt)
        #expect(merged.session?.utilization == 33)
        // The server's "warning" was about the old 20 %, not about the new number.
        #expect(merged.session?.severity == "normal")
        #expect(merged.session?.resetsAt == reset && merged.session?.resetIsExact == true)
        #expect(merged.windows.first { $0.key == "weekly_scoped:Opus" }?.utilization == 50)
        #expect(merged.weekly?.utilization == 70)
        #expect(merged.extraUsageEnabled)
        #expect(AccountRouter.merging(live, into: nil).windows.count == 2)
    }

    @Test func leituraAoVivoCasaAsJanelasPeloTipoMesmoComAsChavesAntigas() {
        let now = Date(timeIntervalSince1970: 10_000)
        var base = UsageSnapshot()
        base.windows = [
            LimitWindow(key: "five_hour", title: "Sessão · 5h", utilization: 20, resetsAt: Date(timeIntervalSince1970: 20_000),
                        severity: "normal", isSession: true, isActive: true),
            LimitWindow(key: "seven_day", title: "Semana", utilization: 60, resetsAt: Date(timeIntervalSince1970: 9_000),
                        severity: "normal", isSession: false, isActive: false),
        ]
        base.fetchedAt = Date(timeIntervalSince1970: 1_000)
        var live = UsageSnapshot()
        live.windows = [
            LimitWindow(key: "session", title: "Sessão · 5h", utilization: 30, resetsAt: nil, severity: "normal",
                        isSession: true, isActive: true),
            LimitWindow(key: "weekly_all", title: "Semana", utilization: 65, resetsAt: nil, severity: "normal",
                        isSession: false, isActive: false),
        ]
        live.fetchedAt = Date(timeIntervalSince1970: 5_000)
        let merged = AccountRouter.merging(live, into: base, now: now)
        #expect(merged.windows.count == 2)
        #expect(merged.session?.utilization == 30)
        #expect(merged.weekly?.utilization == 65)
        // A reset still ahead stays; one that already passed is not shown as the next one.
        #expect(merged.session?.resetsAt == Date(timeIntervalSince1970: 20_000))
        #expect(merged.weekly?.resetsAt == nil)
    }

    @Test func leituraCompletaSoRecebeOAoVivoQuandoEleEMaisNovo() {
        var full = UsageSnapshot()
        full.windows = [UsageAPI.window(kind: "session", model: nil, percent: 50, resetsAt: nil, severity: "normal", isActive: true),
                        UsageAPI.window(kind: "weekly_scoped", model: "Opus", percent: 10, resetsAt: nil, severity: "normal", isActive: false)]
        full.fetchedAt = Date(timeIntervalSince1970: 2_000)
        var live = UsageSnapshot()
        live.windows = [UsageAPI.window(kind: "session", model: nil, percent: 55, resetsAt: nil, severity: "normal", isActive: true)]
        live.fetchedAt = Date(timeIntervalSince1970: 1_000)
        #expect(AccountRouter.combined(full: full, live: live) == full)
        #expect(AccountRouter.combined(full: full, live: nil) == full)
        live.fetchedAt = Date(timeIntervalSince1970: 3_000)
        let combined = AccountRouter.combined(full: full, live: live)
        #expect(combined?.session?.utilization == 55)
        #expect(combined?.scoped.first?.utilization == 10)
        #expect(AccountRouter.combined(full: nil, live: live)?.windows.count == 1)
        #expect(AccountRouter.combined(full: nil, live: nil) == nil)
    }

    @Test func numerosAoVivoDeOutroLoginNaoAparecemNestaConta() {
        var snap = UsageSnapshot()
        snap.windows = [UsageAPI.window(kind: "session", model: nil, percent: 40, resetsAt: nil, severity: "normal", isActive: true)]
        let atual = AccountIdentity(accountUuid: "conta-b", organizationUuid: "org-1")
        #expect(Monitor.liveSnapshot(.init(snapshot: snap, key: "conta-a:org-1"), for: atual) == nil)
        #expect(Monitor.liveSnapshot(.init(snapshot: snap, key: "conta-b:org-1"), for: atual) == snap)
        // A file without the login, or a slot whose login cannot be read: nothing to compare, the numbers stand.
        #expect(Monitor.liveSnapshot(.init(snapshot: snap, key: nil), for: atual) == snap)
        #expect(Monitor.liveSnapshot(.init(snapshot: snap, key: "conta-a:org-1"), for: nil) == snap)
        #expect(Monitor.liveSnapshot(nil, for: atual) == nil)
    }

    /// The terminal poll's choice, for the states the panel actually meets: a VS Code session streaming, one that
    /// stopped twenty minutes ago, the server's pause, and the ten-minute whole read for the per-model windows.
    @Test func planoDoTerminalPrefereOAoVivoSemPerderALeituraCompleta() {
        let now = Date(timeIntervalSince1970: 100_000)
        func plan(live: TimeInterval?, held: TimeInterval?, full: TimeInterval?, pause: TimeInterval? = nil) -> TerminalPlan {
            TerminalPlan.plan(live: live.map { now.addingTimeInterval(-$0) }, held: held.map { now.addingTimeInterval(-$0) },
                              lastFullRead: full.map { now.addingTimeInterval(-$0) },
                              pause: pause.map { now.addingTimeInterval($0) }, now: now, interval: 120)
        }
        // Streaming, whole read five minutes ago: the live numbers, no request.
        #expect(plan(live: 5, held: 60, full: 300) == .takeLive)
        // Streaming, but the whole read is ten minutes old: read, and keep the live numbers if that fails.
        #expect(plan(live: 5, held: 60, full: 600) == .read(otherwise: .current))
        // At launch nothing was read yet: a whole read first.
        #expect(plan(live: 5, held: nil, full: nil) == .read(otherwise: .current))
        // Streaming during a pause: the live numbers, never a request.
        #expect(plan(live: 5, held: 60, full: 900, pause: 600) == .takeLive)
        // The session stopped twenty minutes ago, pause on: wait, the old live numbers still go in.
        #expect(plan(live: 1_200, held: 3_600, full: 3_600, pause: 600) == .wait(until: now.addingTimeInterval(600), live: .older))
        // Nothing newer than what is held: just the pause.
        #expect(plan(live: 3_600, held: 1_200, full: 1_200, pause: 600) == .wait(until: now.addingTimeInterval(600), live: .none))
        // A pause that already ended is no pause.
        #expect(plan(live: nil, held: 1_200, full: 1_200, pause: -1) == .read(otherwise: .none))
        // Same live file as last round (already merged): nothing new, so a read.
        #expect(plan(live: 30, held: 30, full: 300) == .read(otherwise: .none))
        #expect(TerminalPlan.fullReadInterval(120) == 600)
        #expect(TerminalPlan.fullReadInterval(900) == 900)
    }

    @Test func pausaPedidaPeloServidorEmSegundosOuData() {
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        #expect(UsageError.retryAfter("120", now: now) == 120)
        #expect(UsageError.retryAfter(" 3600 ", now: now) == 3600)
        #expect(UsageError.retryAfter("-5", now: now) == 0)
        let date = "Thu, 08 Oct 2026 22:54:20 GMT"   // 1791500000 + 60
        #expect(UsageError.retryAfter(date, now: now) == 60)
        #expect(UsageError.retryAfter(nil, now: now) == nil)
        #expect(UsageError.retryAfter("logo", now: now) == nil)
        #expect(UsageError.rateLimited(retryAfter: 60).errorDescription?.contains("429") == true)
        #expect(FeedState.shortReason(for: UsageError.rateLimited(retryAfter: nil)) == "pausa pedida")
    }

    @Test func saidaDoSecurityViraOMotivoCerto() {
        #expect(Keychain.failure(forSecurityExit: 44) == .notFound)
        #expect(Keychain.failure(forSecurityExit: 36) == .locked)
        #expect(Keychain.failure(forSecurityExit: 51) == .denied)
        #expect(Keychain.failure(forSecurityExit: 128) == .denied)
        #expect(Keychain.failure(forSecurityExit: 1) == .other(1))
        #expect(FeedState.shortReason(for: Keychain.Failure.unanswered) == "sem resposta")
        #expect(FeedState.shortReason(for: Keychain.Failure.locked) == "bloqueado")
    }

    /// One prompt, then quiet: a refused or unanswered dialog waits for "Ler de novo"; a locked Keychain or an odd
    /// error waits five minutes; a missing login is asked about on every poll, since that raises no dialog.
    @Test func keychainNaoPerguntaDeNovoSozinhoDepoisDeUmaRecusa() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(Monitor.keychainWait(after: .denied, now: now) == .distantFuture)
        #expect(Monitor.keychainWait(after: .unanswered, now: now) == .distantFuture)
        #expect(Monitor.keychainWait(after: .locked, now: now) == now.addingTimeInterval(300))
        #expect(Monitor.keychainWait(after: .other(1), now: now) == now.addingTimeInterval(300))
        for failure: Keychain.Failure in [.notFound, .noAccountToken, .expired, .malformed] {
            #expect(Monitor.keychainWait(after: failure, now: now) == nil)
        }
        #expect(Keychain.Failure.denied.waitsForPerson && Keychain.Failure.unanswered.waitsForPerson)
        #expect(!Keychain.Failure.locked.waitsForPerson)
    }

    @Test func recusaDoKeychainPedeLerDeNovoNaoLogin() {
        var inputs = AccessBuilder.Inputs()
        inputs.claudeLoginProblem = Keychain.Failure.denied.errorDescription
        inputs.claudeLoginRetry = true
        let item = AccessBuilder.build(inputs).items.first { $0.id == "claude.login" }
        #expect(item?.action == .readAgain)
        #expect(item?.actionLabel == "Ler de novo")
        inputs.claudeLoginRetry = false
        #expect(AccessBuilder.build(inputs).items.first { $0.id == "claude.login" }?.action == .copy("claude"))
    }

    /// A read killed at its time limit (a dialog nobody answered) is told apart from one that failed on its own.
    @Test func comandoMortoPeloLimiteDeTempoFicaMarcado() {
        let slow = AccountRouter.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.3)
        #expect(slow.interrupted)
        #expect(!slow.ok)
        let quick = AccountRouter.run(URL(fileURLWithPath: "/usr/bin/false"), [], timeout: 5)
        #expect(!quick.interrupted)
        #expect(quick.status == 1)
    }
}
