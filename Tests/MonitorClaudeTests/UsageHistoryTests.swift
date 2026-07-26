import Foundation
import Testing
@testable import MonitorClaude

/// The history used to be append-only-and-monotonic for free: every sample was stamped `Date()`
/// at the moment of a successful poll. A second feed broke both properties at once — the desktop
/// app's readings carry the *sample's* timestamp, minutes behind the poll that noticed them, and a
/// feed frozen on one reading offers that same reading on every poll. Out-of-order points fold the
/// trail back on itself and make `burnRate`'s span negative; repeats drag the least-squares fit
/// toward a slope nobody burned.
@MainActor
struct UsageHistoryTests {
    private func store() -> UsageHistory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("farol-test-\(UUID().uuidString).json")
        return UsageHistory(storedAt: url)
    }

    /// Minute 0 sits well inside the trailing hour `burnRate` looks at, because that method takes
    /// its window from the wall clock rather than from the samples.
    private let origin = Date().addingTimeInterval(-70 * 60)

    private func at(_ minute: Int) -> Date {
        origin.addingTimeInterval(Double(minute) * 60)
    }

    private func sample(_ minute: Int, _ session: Double, org: String? = "orgA") -> UsageSample {
        UsageSample(at: at(minute), session: session, weekly: nil, org: org)
    }

    @Test func amostraAtrasadaEntraNoLugarCertoENãoNoFim() {
        let h = store()
        h.append(sample(0, 50))
        h.append(sample(10, 52))
        h.append(sample(5, 51))            // o feed do app, carimbado para trás

        #expect(h.samples.map(\.at) == [at(0), at(5), at(10)])
        #expect(h.samples.map(\.session) == [50, 51, 52])
    }

    /// The case that compounded: a frozen feed re-offering one reading while the other feed keeps
    /// advancing, so the repeat is never the last element and the old guard never saw it.
    @Test func amostraCongeladaNãoSeAcumula() {
        let h = store()
        h.append(sample(0, 50))
        h.append(sample(3, 20))            // feed parado
        h.append(sample(6, 52))
        h.append(sample(3, 20))            // mesmo instante de novo
        h.append(sample(9, 54))
        h.append(sample(3, 20))

        #expect(h.samples.count == 4)
        #expect(h.samples.filter { $0.at == at(3) }.count == 1)
    }

    /// Two organizations sampled at the same instant are two observations, not a repeat.
    @Test func mesmoInstanteEmOrganizaçõesDiferentesNãoÉDuplicata() {
        let h = store()
        h.append(sample(0, 50, org: "orgA"))
        h.append(sample(0, 12, org: "orgB"))

        #expect(h.samples.count == 2)
        #expect(Set(h.samples.compactMap(\.org)) == ["orgA", "orgB"])
    }

    /// …but the repeat still has to be caught when several organizations share the instant, which
    /// pushes the earlier copy well away from where the new one would be inserted. A guard that
    /// looked at a couple of neighbours missed it and let the duplicate through.
    @Test func duplicataÉVistaMesmoComVáriasOrganizaçõesNoMesmoInstante() {
        let h = store()
        for org in ["orgA", "orgB", "orgC", "orgD"] { h.append(sample(0, 10, org: org)) }
        h.append(sample(0, 10, org: "orgA"))

        #expect(h.samples.count == 4)
        #expect(h.samples.filter { $0.org == "orgA" }.count == 1)
    }

    /// The endpoint is cached server-side, so two polls seconds apart legitimately return the same
    /// reading; that still collapses to one point.
    @Test func leiturasQuaseSimultâneasColapsam() {
        let h = store()
        h.append(sample(0, 50))
        h.append(UsageSample(at: at(0).addingTimeInterval(3), session: 50, org: "orgA"))

        #expect(h.samples.count == 1)
    }

    /// A series belongs to one organization; samples written before that was recorded carry no
    /// organization and must not be folded into a named one.
    @Test func sériePorOrganizaçãoNãoMisturaAsOutras() {
        let h = store()
        h.append(sample(0, 50, org: "orgA"))
        h.append(sample(1, 10, org: "orgB"))
        h.append(sample(2, 51, org: "orgA"))
        h.append(sample(3, 99, org: nil))

        let a = h.series(\.session, since: at(-1), org: "orgA")
        #expect(a.map(\.1) == [50, 51])
        #expect(h.series(\.session, since: at(-1), org: nil).map(\.1) == [99])
    }

    /// Ordering is what `burnRate` depends on: an out-of-order point used to make the measured span
    /// negative, which fails the minimum-span guard and silently removes the outlook.
    @Test func ritmoSobreviveAUmaAmostraAtrasada() throws {
        let h = store()
        for i in 0...6 { h.append(sample(i * 10, Double(10 + i * 5))) }
        h.append(sample(35, 27))           // chega depois, pertence ao meio

        let burn = try #require(h.burnRate(\.session, org: "orgA",
                                           window: 24 * 3600, minSpan: 15 * 60))
        #expect(burn.percentPerHour > 0)
        #expect(burn.basedOnMinutes == 60)
    }
}
