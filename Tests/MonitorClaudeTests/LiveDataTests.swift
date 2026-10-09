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
        let snap = try #require(AccountRouter.parseLiveLimits(data))
        #expect(snap.fetchedAt == Date(timeIntervalSince1970: 1_791_500_000))
        #expect(snap.windows.map(\.key) == ["session", "weekly_all"])
        #expect(snap.session?.utilization == 41.2)
        #expect(snap.session?.resetsAt == Date(timeIntervalSince1970: 1_791_514_800))
        #expect(snap.weekly?.title == "Semana")
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
        #expect(all["principal"]?.session?.utilization == 10)
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
        #expect(merged.session?.resetsAt == reset && merged.session?.resetIsExact == true)
        #expect(merged.windows.first { $0.key == "weekly_scoped:Opus" }?.utilization == 50)
        #expect(merged.weekly?.utilization == 70)
        #expect(merged.extraUsageEnabled)
        #expect(AccountRouter.merging(live, into: nil).windows.count == 2)
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
        #expect(Keychain.failure(forSecurityExit: 51) == .denied)
        #expect(Keychain.failure(forSecurityExit: 36) == .denied)
        #expect(Keychain.failure(forSecurityExit: 1) == .other(1))
    }
}
