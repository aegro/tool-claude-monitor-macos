import Foundation
import Testing
@testable import MonitorClaude

/// An account the router set aside says why: a limit comes back at a time, a refused login does not.
struct AsideReasonTests {
    private func entry(reason: String?, until: Date) -> AccountQueue.Entry {
        var e = AccountQueue.Entry(id: "compare", label: "Squad Compare", monogram: "SC", role: .reserve, plan: "ultra",
                                   email: nil, organization: nil, snapshot: nil, hasLogin: false, agentsLogin: true,
                                   exhaustedUntil: until)
        e.exhaustedReason = reason
        return e
    }

    @Test func leOMotivoSoDasContasAindaDeLado() {
        let now = Date(timeIntervalSince1970: 1_794_180_000)
        let reasons = AccountRouter.parseExhaustedReasons(Data("""
        { "thomas-max": { "ate": 1794322800000, "motivo": "seven_day", "em": 1794179394355 },
          "compare": { "ate": 1794201034240, "motivo": "auth", "em": 1794179434241 },
          "principal": { "ate": 1794100000000, "motivo": "five_hour" },
          "squad": { "ate": 1794322800000, "motivo": "agents cobranca" } }
        """.utf8), now: now)
        #expect(reasons == ["thomas-max": "seven_day", "compare": "auth", "squad": "cobranca"])
    }

    @Test func loginRecusadoNaoViraEsgotadaNemHora() {
        let until = Date(timeIntervalSince1970: 1_794_201_034)
        let auth = entry(reason: "auth", until: until)
        #expect(auth.asideChip == "pediu login")
        #expect(auth.asideLine(until: until) == "o servidor recusou o login: autorize de novo em Contas e logins")

        let limit = entry(reason: "seven_day", until: until)
        #expect(limit.asideChip == "esgotada")
        #expect(limit.asideLine(until: until) == "volta \(Fmt.at(until))")
        // Only the time it comes back: the renewal that frees it is that same time.
        #expect(!limit.asideLine(until: until).contains("renova"))

        #expect(entry(reason: nil, until: until).asideChip == "esgotada")
        #expect(entry(reason: "conta_suspensa", until: until).asideChip == "suspensa")
    }

    /// Coming back on another day names the weekday and the date; today, only the time.
    @Test func voltaDizODiaDaSemana() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 21, minute: 50))!
        let tuesday = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let tonight = cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 23, minute: 5))!
        let limit = entry(reason: "seven_day", until: tuesday)
        #expect(limit.asideLine(until: tuesday, now: now) == "volta ter 10/11 às 12:00")
        #expect(limit.asideLine(until: tonight, now: now) == "volta às 23:05")
        #expect(entry(reason: "cobranca", until: tuesday).asideLine(until: tuesday, now: now)
                == "erro de cobrança nesta conta · tenta de novo ter 10/11 às 12:00")
        #expect(Fmt.weekday(cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))!, now: now)
                == "sex 20/11 12:00")
    }

    @Test func linhaDeStatusDaContaEmUsoDizOMotivo() {
        let now = Date()
        var e = entry(reason: "auth", until: now.addingTimeInterval(3600))
        e.role = .route
        let q = AccountQueue(entries: [e], strategy: .order, enabled: true, configured: true)
        let line = AccountQueue.statusLine(queue: q, inUse: "compare", outlook: nil, now: now)
        #expect(line.contains("recusou o login"))
        #expect(!line.contains("Esgotada"))
    }
}
