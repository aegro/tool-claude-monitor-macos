import Foundation
import Testing
@testable import MonitorClaude

/// The pick weighs the room left in the week against the hours until it renews (the router's `folgaPorHora`): an
/// account near its weekly limit with days to go no longer wins over one with the week almost untouched, and room that
/// renews soon is spent before room that renews in days.
struct RoomUntilResetTests {
    private let now = Date(timeIntervalSince1970: 1_793_700_000)

    private func snapshot(week used: Double, renewsIn hours: Double?, session: Double? = nil) -> UsageSnapshot {
        var windows = [LimitWindow(key: "weekly_all", title: "", utilization: used,
                                   resetsAt: hours.map { now.addingTimeInterval($0 * 3600) },
                                   severity: "normal", isSession: false, isActive: true)]
        if let session {
            windows.insert(LimitWindow(key: "session", title: "", utilization: session, resetsAt: now.addingTimeInterval(7200),
                                       severity: "normal", isSession: true, isActive: true), at: 0)
        }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }

    private func config(_ json: String) throws -> AccountRouter.Config {
        try #require(AccountRouter.parseConfig(Data(json.utf8), home: URL(fileURLWithPath: "/tmp/contas"),
                                               defaultDirectory: URL(fileURLWithPath: "/tmp/.claude")))
    }

    private let queue = """
    { "contas": { "principal": {}, "squad": {}, "extra": {} }, "rota": ["principal", "squad"], "reserva": ["extra"] }
    """

    @Test func folgaPorHoraÉOQueSobraDaSemanaPelasHorasAtéRenovar() {
        #expect(String(format: "%.2f", AccountRouter.perHour(snapshot(week: 92, renewsIn: 43, session: 2), now: now)) == "0.19")
        #expect(String(format: "%.2f", AccountRouter.perHour(snapshot(week: 10, renewsIn: 115), now: now)) == "0.78")
        // Past its reset, a whole free week; minutes from the reset, at most one hour of divisor.
        #expect(AccountRouter.perHour(snapshot(week: 97, renewsIn: -1), now: now) == 100.0 / 168)
        #expect(AccountRouter.perHour(snapshot(week: 70, renewsIn: 0.02), now: now) == 30)
        #expect(AccountRouter.perHour(snapshot(week: 40, renewsIn: nil), now: now) == 60.0 / 168)
    }

    @Test func passaLongeDaContaQuaseNoLimiteDaSemana() throws {
        let cfg = try config(queue)
        let usage = ["principal": snapshot(week: 92, renewsIn: 43, session: 2), "squad": snapshot(week: 10, renewsIn: 115),
                     "extra": snapshot(week: 0, renewsIn: 160)]
        #expect(AccountRouter.pick(cfg, usage: usage, available: Set(usage.keys), exhausted: [:], now: now) == "squad")
    }

    @Test func gastaPrimeiroAFolgaQueRenovaAntes() throws {
        let cfg = try config(queue)
        let all: Set<String> = ["principal", "squad", "extra"]
        let soon = ["principal": snapshot(week: 40, renewsIn: 10), "squad": snapshot(week: 10, renewsIn: 120)]
        #expect(AccountRouter.pick(cfg, usage: soon, available: all, exhausted: [:], now: now) == "principal")
        let far = ["principal": snapshot(week: 40, renewsIn: 100), "squad": snapshot(week: 10, renewsIn: 120)]
        #expect(AccountRouter.pick(cfg, usage: far, available: all, exhausted: [:], now: now) == "squad")
        // Below `limites.voltar` an account is close to a limit: a near reset does not put it first.
        let tight = ["principal": snapshot(week: 85, renewsIn: 3), "squad": snapshot(week: 10, renewsIn: 120)]
        #expect(AccountRouter.pick(cfg, usage: tight, available: all, exhausted: [:], now: now) == "squad")
        // Nor does a nearly full 5h window, however much of the week is left.
        let session = ["principal": snapshot(week: 10, renewsIn: 20, session: 90), "squad": snapshot(week: 30, renewsIn: 120)]
        #expect(AccountRouter.pick(cfg, usage: session, available: all, exhausted: [:], now: now) == "squad")
    }

    @Test func aReservaSóEntraQuandoARotaAcaba() throws {
        let cfg = try config(queue)
        let all: Set<String> = ["principal", "squad", "extra"]
        let usage = ["principal": snapshot(week: 60, renewsIn: 150), "squad": snapshot(week: 70, renewsIn: 150),
                     "extra": snapshot(week: 0, renewsIn: 5)]
        #expect(AccountRouter.pick(cfg, usage: usage, available: all, exhausted: [:], now: now) == "principal")
    }

    @Test func limiteDeConfortoVemDeLimitesVoltar() throws {
        #expect(try config(queue).comfortableFrom == 20)
        let custom = try config("""
        { "contas": { "principal": {} }, "limites": { "voltar": 35 } }
        """)
        #expect(custom.comfortableFrom == 35)
    }
}
