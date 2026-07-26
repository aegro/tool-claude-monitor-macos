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

    /// The fall is the better witness, so it wins even when a rise came later. Taken from the real
    /// series of 24/07, where the API's own `resets_at` was 00:00 — the fall gives exactly that,
    /// while the later rise at 19:08→19:18 would have said 00:10.
    @Test func quedaTemPrecedênciaSobreSubidaPosterior() {
        let s = series([
            (t(21, 58), 32), (t(22, 3), 0), (t(22, 8), 0), (t(22, 18), 2),
        ])
        let r = DesktopUsage.sessionReset(series: s, now: t(23, 0))
        #expect(r?.at == t(3, 0, day: 25))
        #expect(r?.exact == true)
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
        // Periódica: o âncora rolado cai no instante real, então não é aproximação.
        #expect(weekly.resetIsExact)

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
