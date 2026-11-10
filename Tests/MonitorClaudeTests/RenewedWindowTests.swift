import Foundation
import Testing
@testable import MonitorClaude

/// A window whose reset already passed, with no read since, is drawn as renewed on every surface (10/11/2026: the
/// account row read 0 % while its detail, right under it, kept 100 %, "em 0 s" and "no ritmo").
struct RenewedWindowTests {
    private let now = Date(timeIntervalSince1970: 1_794_326_400)

    private func weekly(_ used: Double, resetIn seconds: TimeInterval, severity: String = "critical") -> LimitWindow {
        LimitWindow(key: "weekly_all", title: "Semana", utilization: used, resetsAt: now.addingTimeInterval(seconds),
                    severity: severity, isSession: false, isActive: true)
    }

    @Test func janelaQueJáRenovouValeZeroESemAlarme() {
        let shown = weekly(100, resetIn: -3600).asOf(now)
        #expect(shown.utilization == 0)
        #expect(!shown.isCritical)
        #expect(shown.paceRatio == nil)
        #expect(shown.resetsAt == now.addingTimeInterval(-3600))
    }

    @Test func janelaAindaAbertaFicaComoVeio() {
        let window = weekly(100, resetIn: 60)
        #expect(window.asOf(now) == window)
    }

    @Test func oRoteadorContaPelaMesmaRegra() {
        #expect(AccountRouter.used(weekly(100, resetIn: 0), now: now) == 0)
        #expect(AccountRouter.used(weekly(40, resetIn: 1), now: now) == 40)
    }
}
