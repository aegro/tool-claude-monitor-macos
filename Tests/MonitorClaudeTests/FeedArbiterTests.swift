import Foundation
import Testing
@testable import MonitorClaude

/// The arbitration between the two feeds. Every serious defect this feature shipped with was in
/// here, and none of it was reachable by a test while the logic lived on `Monitor` — so these
/// cases are written against the states that actually broke, not against the happy path.
struct FeedArbiterTests {
    private func snap(_ source: UsageSource, at: Date, session: Double = 10) -> UsageSnapshot {
        var s = UsageSnapshot()
        s.source = source
        s.fetchedAt = at
        s.windows = [LimitWindow(key: "session", title: "Sessão · 5h", utilization: session,
                                 resetsAt: nil, severity: "normal", isSession: true, isActive: true)]
        return s
    }

    private let now = Date()
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    // MARK: quem ganha

    @Test func apiVivaGanhaDeTudo() {
        let api = FeedArbiter.Offer(snapshot: snap(.api, at: ago(1), session: 62), org: "orgA")
        let desk = FeedArbiter.Offer(snapshot: snap(.desktopApp, at: ago(2), session: 4), org: "orgB")

        let c = FeedArbiter.choose(api: api, terminal: .live(at: ago(1)),
                                   desktop: desk, desktopHealth: .live(at: ago(2)))
        #expect(c.snapshot?.source == .api)
        #expect(c.org == "orgA")
        #expect(c.health == .live(at: ago(1)))
    }

    @Test func appAssumeQuandoOTerminalCai() {
        let api = FeedArbiter.Offer(snapshot: snap(.api, at: ago(200), session: 62), org: "orgA")
        let desk = FeedArbiter.Offer(snapshot: snap(.desktopApp, at: ago(2), session: 4), org: "orgB")

        let c = FeedArbiter.choose(api: api, terminal: .broken("vencido"),
                                   desktop: desk, desktopHealth: .live(at: ago(2)))
        #expect(c.snapshot?.source == .desktopApp)
        #expect(c.org == "orgB")
    }

    /// The defect this rule exists for: a desktop reading from days ago used to displace an API
    /// snapshot from two minutes ago, purely because it *existed*. The panel jumped backwards in
    /// time and presented the older number as live.
    @Test func appParadoNãoDerrubaSnapshotDaApiMaisNovo() {
        let api = FeedArbiter.Offer(snapshot: snap(.api, at: ago(2), session: 62), org: "orgA")
        let desk = FeedArbiter.Offer(snapshot: snap(.desktopApp, at: ago(4320), session: 4), org: "orgB")

        let c = FeedArbiter.choose(api: api, terminal: .broken("vencido"),
                                   desktop: desk, desktopHealth: .stale(at: ago(4320)))
        #expect(c.snapshot?.session?.utilization == 62)
        #expect(c.org == "orgA")
    }

    /// …and the mirror case, which is the one the last branch was written for and never reached:
    /// nothing is current, but the desktop reading is the fresher of the two.
    @Test func semNadaAtualVenceOMaisFresco() {
        let api = FeedArbiter.Offer(snapshot: snap(.api, at: ago(600), session: 62), org: "orgA")
        let desk = FeedArbiter.Offer(snapshot: snap(.desktopApp, at: ago(40), session: 4), org: "orgB")

        let c = FeedArbiter.choose(api: api, terminal: .broken("vencido"),
                                   desktop: desk, desktopHealth: .stale(at: ago(40)))
        #expect(c.snapshot?.session?.utilization == 4)
        #expect(c.org == "orgB")
    }

    // MARK: o que a escolha declara sobre si

    /// Nothing current must never come back wearing `.live`: the lead row, the menu bar and the
    /// pace notch all key off this, and a lie here is the twenty-one-hour bug reappearing.
    @Test func escolhaNãoAtualCarregaASaúdeQueACondena() {
        let api = FeedArbiter.Offer(snapshot: snap(.api, at: ago(600)), org: "orgA")
        let c = FeedArbiter.choose(api: api, terminal: .broken("vencido"),
                                   desktop: nil, desktopHealth: .missing)

        #expect(c.snapshot != nil)
        #expect(c.health == .broken("vencido"))
        if case .live = c.health { Issue.record("saúde não pode ser .live sem fonte atual") }
    }

    @Test func appParadoSozinhoAindaAparece_masComoParado() {
        let desk = FeedArbiter.Offer(snapshot: snap(.desktopApp, at: ago(90)), org: "orgB")
        let c = FeedArbiter.choose(api: nil, terminal: .broken("sem login"),
                                   desktop: desk, desktopHealth: .stale(at: ago(90)))
        #expect(c.snapshot?.source == .desktopApp)
        #expect(c.health == .stale(at: ago(90)))
    }

    @Test func semFonteAlgumaNãoHáEscolha() {
        #expect(FeedArbiter.choose(api: nil, terminal: .missing,
                                   desktop: nil, desktopHealth: .missing) == .nothing)
    }

    /// A live health with no snapshot behind it is not an offer. Guarding on the health alone
    /// would have adopted nil and blanked the panel.
    @Test func saúdeVivaSemSnapshotNãoÉOferta() {
        let desk = FeedArbiter.Offer(snapshot: snap(.desktopApp, at: ago(2)), org: "orgB")
        let c = FeedArbiter.choose(api: nil, terminal: .live(at: ago(1)),
                                   desktop: desk, desktopHealth: .live(at: ago(2)))
        #expect(c.snapshot?.source == .desktopApp)
    }

    // MARK: qual organização o app está tocando

    @Test func organizaçãoMaisRecenteÉAQueOAppEstáTocando() {
        let byOrg = [
            "orgA": [DesktopSample(at: ago(300), fiveHour: 5, weekly: 30)],
            "orgB": [DesktopSample(at: ago(2), fiveHour: 3, weekly: 1)],
        ]
        #expect(FeedArbiter.newestOrg(in: byOrg)?.org == "orgB")
    }

    /// `Dictionary` has no iteration order, so a tie resolved by "whichever came first" flipped the
    /// entire panel to a different organization between launches.
    @Test func empateResolveSempreParaOMesmoLado() {
        let t = ago(5)
        let byOrg = [
            "orgB": [DesktopSample(at: t, fiveHour: 3, weekly: 1)],
            "orgA": [DesktopSample(at: t, fiveHour: 9, weekly: 2)],
            "orgC": [DesktopSample(at: t, fiveHour: 7, weekly: 4)],
        ]
        let picks = (0..<20).map { _ in FeedArbiter.newestOrg(in: byOrg)?.org }
        #expect(Set(picks).count == 1)
        #expect(picks.first == "orgA")
    }

    @Test func organizaçãoSemAmostraNãoConcorre() {
        let byOrg: [String: [DesktopSample]] = ["orgA": []]
        #expect(FeedArbiter.newestOrg(in: byOrg) == nil)
        #expect(FeedArbiter.newestOrg(in: [:]) == nil)
    }
}
