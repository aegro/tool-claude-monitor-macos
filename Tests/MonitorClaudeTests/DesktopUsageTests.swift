import Foundation
import Testing
@testable import MonitorClaude

/// Turning the desktop app's five-minute samples into something the panel can draw. The two
/// things worth pinning down are the derived resets: the session one is *inferred* from where the
/// percentage fell off, and the weekly one is *rolled forward* from an anchor the API gave us
/// once. Both must refuse to answer rather than invent a reset.
struct DesktopUsageTests {
    /// 2026-07-24 in UTC, so the numbers below read like the real file does.
    private func t(_ hour: Int, _ minute: Int, day: Int = 24) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = day; c.hour = hour; c.minute = minute
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func series(_ pairs: [(Date, Double)]) -> [DesktopSample] {
        pairs.map { DesktopSample(at: $0.0, fiveHour: $0.1, weekly: 30) }
    }

    // MARK: reset da sessão

    /// The real case from 24/07: samples at 21:58 and 22:03 straddle the drop, and exactly one
    /// ten-minute mark sits in between — so the boundary is 22:00 and the reset is 03:00, which is
    /// precisely what the API had been reporting. One candidate means we are not guessing.
    @Test func quedaComUmaÚnicaMarcaNaGradeDáResetExato() {
        let s = series([
            (t(21, 48), 30), (t(21, 53), 32), (t(21, 58), 32),
            (t(22, 3), 0), (t(22, 8), 0), (t(22, 13), 2),
        ])
        let r = DesktopUsage.sessionReset(series: s, now: t(23, 0))
        #expect(r?.at == t(3, 0, day: 25))
        #expect(r?.exact == true)
    }

    /// Two marks inside the gap — the app missed a poll, say — and we can no longer single one
    /// out. The midpoint keeps the answer within five minutes, but it stops being exact.
    @Test func gapMaiorCaiNoPontoMédioENãoÉExato() {
        let s = series([(t(21, 45), 40), (t(22, 7), 1)])
        // meio = 21:56 → marca mais próxima = 22:00 → reset 03:00
        let r = DesktopUsage.sessionReset(series: s, now: t(23, 0))
        #expect(r?.at == t(3, 0, day: 25))
        #expect(r?.exact == false)
    }

    /// A run that only ever climbs, with no zero to rise from, crossed no boundary we can see.
    @Test func sérieSemQuedaNemSubidaDoZeroNãoInventaReset() {
        let s = series([(t(20, 0), 4), (t(20, 5), 7), (t(20, 10), 9)])
        #expect(DesktopUsage.sessionReset(series: s, now: t(20, 15)) == nil)
    }

    /// A dip of a point or two is the server rounding, not a new window.
    @Test func oscilaçãoPequenaNãoContaComoReset() {
        let s = series([(t(20, 0), 31), (t(20, 5), 30), (t(20, 10), 31)])
        #expect(DesktopUsage.sessionReset(series: s, now: t(20, 15)) == nil)
    }

    /// The drop we can see is older than five hours: that window has already closed and the next
    /// one started somewhere we never observed (the app was shut). Silence beats a stale reset.
    @Test func quedaVelhaDemaisNãoServeDeÂncora() {
        let s = series([(t(5, 58), 30), (t(6, 3), 0)])
        #expect(DesktopUsage.sessionReset(series: s, now: t(20, 0)) == nil)
    }

    // MARK: âncora secundária — a subida a partir do zero

    /// The common case, and the reason the second anchor exists: light usage means the window
    /// turns over while the number is already zero, so there is never a fall to catch. The first
    /// non-zero reading after a zero opens a window, and that brackets a boundary just as well —
    /// only less certainly, so it never claims to be exact.
    @Test func subidaDoZeroAncoraQuandoNãoHouveQueda() {
        let s = series([(t(19, 57), 0), (t(20, 2), 2), (t(20, 7), 3)])
        let r = DesktopUsage.sessionReset(series: s, now: t(21, 0))
        #expect(r?.at == t(1, 0, day: 25))   // fronteira 20:00 + 5h
        #expect(r?.exact == false)
    }

    /// The fall is the better witness, so it wins even when a *viable* rise came later.
    ///
    /// The rise here is deliberately eligible — a five-minute bracket, well inside `tightBracket`,
    /// which on its own would anchor at 22:10 and answer 03:10 inexactly. Only because the fall
    /// takes precedence does this come back as 03:00 exact. An earlier version of this test used a
    /// ten-minute rise bracket, which `tightBracket` rejected before precedence was ever consulted
    /// — so it passed whether or not the precedence existed, and proved nothing.
    @Test func quedaTemPrecedênciaSobreSubidaViável() {
        let s = series([
            (t(21, 58), 32), (t(22, 3), 0), (t(22, 8), 0), (t(22, 13), 2),
        ])
        let r = DesktopUsage.sessionReset(series: s, now: t(23, 0))
        #expect(r?.at == t(3, 0, day: 25))
        #expect(r?.exact == true)

        // A prova de que a subida sozinha teria respondido outra coisa: sem a queda na série,
        // o mesmo par 22:08→22:13 ancora em 22:10 e responde 03:10, aproximado.
        let semQueda = series([(t(22, 8), 0), (t(22, 13), 2)])
        let alt = DesktopUsage.sessionReset(series: semQueda, now: t(23, 0))
        #expect(alt?.at == t(3, 10, day: 25))
        #expect(alt?.exact == false)
    }

    /// A fall straddling a hole in the series says almost nothing about where the boundary sits.
    /// The real file has gaps of 12, 22, 44 and 595 minutes; answering across one of those put the
    /// reset hours out, and the number feeds the pace marker, the outlook and the trail's axis.
    @Test func quedaComGapAcimaDoTetoÉRecusada() {
        let s = series([(t(10, 0), 80), (t(16, 0), 5)])
        #expect(DesktopUsage.sessionReset(series: s, now: t(16, 30)) == nil)

        // No teto exato (30 min) ainda responde, aproximado.
        let noLimite = series([(t(21, 40), 80), (t(22, 10), 5)])
        #expect(DesktopUsage.sessionReset(series: noLimite, now: t(23, 0))?.at == t(3, 0, day: 25))
    }

    /// Half of all five-minute brackets contain no ten-minute mark at all. Answering those with the
    /// raw midpoint put the reset at a time the grid says cannot exist — "reseta ≈17:02".
    @Test func resetDeduzidoSempreCaiNaGrade() {
        for minute in 0..<60 {
            let s = series([(t(12, minute), 40), (t(12, minute).addingTimeInterval(300), 1)])
            guard let r = DesktopUsage.sessionReset(series: s, now: t(14, 0)) else { continue }
            let secondsIntoGrid = r.at.timeIntervalSince1970
                .truncatingRemainder(dividingBy: DesktopUsage.resetGrid)
            #expect(secondsIntoGrid == 0, "reset fora da grade para o minuto \(minute)")
        }
    }

    /// A rise straddling a gap wider than one cadence is refused, but the *fall* must still be able
    /// to answer across a bracket that wide — the two limits are different on purpose.
    @Test func subidaEQuedaTêmTetosDiferentes() {
        let bracket = series([(t(21, 48), 0), (t(22, 3), 2)])       // 15 min, subida
        #expect(DesktopUsage.sessionReset(series: bracket, now: t(23, 0)) == nil)

        let queda = series([(t(21, 48), 40), (t(22, 3), 0)])         // 15 min, queda
        #expect(DesktopUsage.sessionReset(series: queda, now: t(23, 0)) != nil)
    }

    /// A percentage that rounds to zero is still zero for the rise anchor's purposes. Testing
    /// `prev == 0` on a Double meant the anchor would quietly stop working the day the desktop app
    /// started writing fractions.
    @Test func subidaReconheceZeroFracionário() {
        let s = [
            DesktopSample(at: t(19, 57), fiveHour: 0.4, weekly: 3),
            DesktopSample(at: t(20, 2), fiveHour: 1.2, weekly: 3),
        ]
        #expect(DesktopUsage.sessionReset(series: s, now: t(21, 0))?.at == t(1, 0, day: 25))
    }

    /// An anchor at most one week old is still the server's word; older than that we are
    /// extrapolating across a period in which a plan change could have moved the boundary.
    @Test func âncoraSemanalRecenteÉExataEAntigaNão() {
        #expect(DesktopUsage.weeklyReset(anchor: t(15, 0, day: 31), now: t(20, 0)).exact)
        #expect(DesktopUsage.weeklyReset(anchor: t(15, 0, day: 20), now: t(20, 0)).exact)
        #expect(!DesktopUsage.weeklyReset(anchor: t(15, 0, day: 10), now: t(20, 0)).exact)
    }

    /// `gridMarks` walks an interval that comes from another application's file. A hard cap is what
    /// stands between a unit-slipped timestamp there and gigabytes of Dates on the main actor.
    @Test func gradeRecusaIntervaloAbsurdo() {
        let sane = DesktopUsage.gridMarks(after: t(12, 0), notAfter: t(12, 30))
        #expect(sane.count == 3)
        #expect(DesktopUsage.gridMarks(after: t(12, 0),
                                       notAfter: Date(timeIntervalSince1970: 1_784_931_561_009)).isEmpty)
        #expect(DesktopUsage.gridMarks(after: t(12, 30), notAfter: t(12, 0)).isEmpty)
    }

    /// A rise straddling a gap wider than one cadence says too little about where inside it the
    /// window opened, so it is refused rather than answered loosely.
    @Test func subidaComGapLargoNãoÉAceita() {
        let s = series([(t(19, 40), 0), (t(20, 2), 2)])
        #expect(DesktopUsage.sessionReset(series: s, now: t(21, 0)) == nil)
    }

    /// The fall is preferred, but only while it still describes a live window. Once its reset is
    /// in the past the rise takes over — this is precisely the state a lightly-used account sits
    /// in all day, and the state that would otherwise leave the panel with no countdown at all.
    @Test func subidaAssumeQuandoAQuedaJáExpirou() {
        let s = series([
            (t(5, 58), 30), (t(6, 3), 0),          // janela que já fechou às 11:00
            (t(19, 57), 0), (t(20, 2), 2),         // a de agora abriu às 20:00
        ])
        let r = DesktopUsage.sessionReset(series: s, now: t(20, 30))
        #expect(r?.at == t(1, 0, day: 25))
        #expect(r?.exact == false)
    }

    // MARK: reset semanal

    /// Weekly windows are strictly periodic, so an anchor the API gave us days ago is still exact
    /// — it only needs winding forward in whole weeks until it lands in the future.
    @Test func âncoraSemanalAvançaEmSemanasInteiras() {
        let anchor = t(15, 0, day: 10)
        #expect(DesktopUsage.rollForward(anchor, step: 7 * 24 * 3600, to: t(20, 0, day: 24))
                == t(15, 0, day: 31))
    }

    @Test func âncoraNoFuturoFicaComoEstá() {
        let anchor = t(15, 0, day: 31)
        #expect(DesktopUsage.rollForward(anchor, step: 7 * 24 * 3600, to: t(20, 0, day: 24)) == anchor)
    }

    // MARK: snapshot

    @Test func montaAsDuasJanelasComAProcedênciaDoApp() throws {
        let s = [
            DesktopSample(at: t(21, 58), fiveHour: 32, weekly: 35),
            DesktopSample(at: t(22, 3), fiveHour: 0, weekly: 35),
            DesktopSample(at: t(22, 8), fiveHour: 3, weekly: 36),
        ]
        let snap = try #require(DesktopUsage.snapshot(series: s,
                                                     weeklyAnchor: t(15, 0, day: 17),
                                                     now: t(23, 0)))

        #expect(snap.source == .desktopApp)
        #expect(snap.fetchedAt == t(22, 8))

        let session = try #require(snap.session)
        #expect(session.utilization == 3)
        #expect(session.isSession)
        #expect(session.resetsAt == t(3, 0, day: 25))
        #expect(session.resetIsExact)

        let weekly = try #require(snap.weekly)
        #expect(weekly.utilization == 36)
        #expect(weekly.resetsAt == t(15, 0, day: 31))
        // Âncora de duas semanas atrás: a aritmética é exata, a premissa é que ninguém re-ancorou
        // a semana no servidor nesse meio-tempo. Dois passos de projeção já pedem o "≈".
        #expect(!weekly.resetIsExact)

        // O app não publica janela por modelo nem crédito extra; nada deve ser fabricado.
        #expect(snap.scoped.isEmpty)
        #expect(!snap.extraUsageEnabled)
    }

    /// Without an anchor the weekly window still shows its percentage — it just cannot say when it
    /// turns over, and must not pretend otherwise.
    @Test func semÂncoraSemanalAJanelaFicaSemReset() throws {
        let s = [DesktopSample(at: t(22, 8), fiveHour: 3, weekly: 36)]
        let snap = try #require(DesktopUsage.snapshot(series: s, weeklyAnchor: nil, now: t(23, 0)))
        #expect(snap.weekly?.utilization == 36)
        #expect(snap.weekly?.resetsAt == nil)
    }

    @Test func sérieVaziaNãoViraSnapshot() {
        #expect(DesktopUsage.snapshot(series: [], weeklyAnchor: nil, now: t(23, 0)) == nil)
    }

    /// The app stopped writing hours ago — it was quit. The snapshot still builds (the panel wants
    /// to show the numbers and their age), but callers can tell it is not current.
    @Test func amostraVelhaAindaMontaMasCarregaAIdade() throws {
        let s = [DesktopSample(at: t(8, 0), fiveHour: 12, weekly: 20)]
        let snap = try #require(DesktopUsage.snapshot(series: s, weeklyAnchor: nil, now: t(20, 0)))
        #expect(snap.fetchedAt == t(8, 0))
        #expect(!DesktopUsage.isCurrent(snap.fetchedAt, now: t(20, 0)))
        #expect(DesktopUsage.isCurrent(t(19, 57), now: t(20, 0)))
    }
}

/// `source` was added after `accounts.json` had already been written in the field. A record from
/// before it existed must still load — and must read as an API reading, which is what it was.
struct UsageSnapshotSourceTests {
    @Test func snapshotAntigoSemSourceDecodificaComoApi() throws {
        let json = """
        {"windows": [], "extraUsageEnabled": false, "fetchedAt": 774547200}
        """
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        #expect(snap.source == .api)
    }

    @Test func sourceSobreviveAoIdaEVolta() throws {
        var snap = UsageSnapshot()
        snap.source = .desktopApp
        let data = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(UsageSnapshot.self, from: data).source == .desktopApp)
    }
}
