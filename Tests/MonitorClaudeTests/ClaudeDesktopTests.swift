import Foundation
import Testing
@testable import MonitorClaude

/// The desktop app's `plan-usage-history.json` is a private, undocumented file. These lock the
/// shape this reader was written against, and — more importantly — lock the failure behaviour:
/// anything unexpected must yield no organizations rather than wrong numbers.
struct ClaudeDesktopTests {
    private let names: [String: (name: String?, type: String?)] = [
        "94aaa71e-org": (name: "Acme", type: "claude_team"),
        "c21c03a1-org": (name: "person@example.test's Organization", type: "claude_max"),
    ]

    private func history(_ samples: String, version: Int = 2) -> Data {
        Data("{\"version\": \(version), \"samples\": [\(samples)]}".utf8)
    }

    @Test func pegaAAmostraMaisRecenteDeCadaOrganização() {
        let data = history("""
        {"t": 1784900000000, "org": "94aaa71e-org", "u": {"fh": 9, "sd": 20}},
        {"t": 1784931561009, "org": "94aaa71e-org", "u": {"fh": 1, "sd": 34}},
        {"t": 1784931500000, "org": "c21c03a1-org", "u": {"fh": 2, "sd": 35}}
        """)
        let orgs = ClaudeDesktop.parseUsage(data, names: names)

        #expect(orgs.count == 2)
        let acme = orgs.first { $0.organizationUuid == "94aaa71e-org" }
        #expect(acme?.fiveHour == 1)      // a mais nova, não a de 9%
        #expect(acme?.weekly == 34)
        #expect(acme?.label == "Acme")
        #expect(acme?.plan == "team")
        // mais recente primeiro
        #expect(orgs.first?.organizationUuid == "94aaa71e-org")
    }

    /// A version bump means the shape may have changed under us. Showing nothing beats showing
    /// numbers we can no longer vouch for.
    @Test func versãoDesconhecidaNãoRendeNada() {
        let data = history("{\"t\": 1784931561009, \"org\": \"o\", \"u\": {\"fh\": 1, \"sd\": 2}}",
                           version: 3)
        #expect(ClaudeDesktop.parseUsage(data, names: [:]).isEmpty)
    }

    @Test func amostrasIncompletasSãoPuladasSemDerrubarAsOutras() {
        let data = history("""
        {"t": 1784931561009, "org": "94aaa71e-org"},
        {"org": "94aaa71e-org", "u": {"fh": 1, "sd": 2}},
        {"t": 1784931561009, "u": {"fh": 1, "sd": 2}},
        {"t": 1784931561009, "org": "c21c03a1-org", "u": {"fh": 2, "sd": 35}}
        """)
        let orgs = ClaudeDesktop.parseUsage(data, names: names)
        #expect(orgs.count == 1)
        #expect(orgs.first?.organizationUuid == "c21c03a1-org")
    }

    @Test func lixoNãoViraOrganização() {
        #expect(ClaudeDesktop.parseUsage(Data("não é json".utf8), names: [:]).isEmpty)
        #expect(ClaudeDesktop.parseUsage(Data("{}".utf8), names: [:]).isEmpty)
        #expect(ClaudeDesktop.parseUsage(history(""), names: [:]).isEmpty)
    }

    /// Same rule as the terminal side: the auto-named solo org collapses instead of showing a
    /// long redundant string, and an organization we cannot name falls back to its uuid.
    @Test func rótuloSegueAMesmaRegraDoTerminal() {
        #expect(ClaudeDesktop.label(forOrg: "94aaa71e-org", name: "Acme") == "Acme")
        #expect(ClaudeDesktop.label(forOrg: "c21c03a1-org",
                                    name: "person@example.test's Organization") == "Pessoal")
        #expect(ClaudeDesktop.label(forOrg: "abcdefgh-0000", name: nil) == "abcdefgh")
    }

    /// A percentage the desktop app could not compute is dropped, not squashed to zero.
    ///
    /// Zero is not a neutral value in a series: the reset derivation reads a fall to zero as a
    /// window turning over, so a clamped garbage row would date a reset off a boundary that never
    /// happened — and, if the bracket happened to hold a single grid mark, would present it as
    /// exact. The endpoint really does leak an epoch timestamp into this field.
    @Test func porcentagemForaDeFaixaDescartaAAmostra() {
        let data = history("{\"t\": 1784931561009, \"org\": \"o\", \"u\": {\"fh\": 1784931561009, \"sd\": -3}}")
        #expect(ClaudeDesktop.parseUsage(data, names: [:]).isEmpty)
        #expect(ClaudeDesktop.parseSamples(data).isEmpty)
    }

    /// A row whose own good neighbours survive it: one bad sample must not cost the series.
    @Test func amostraRuimNoMeioNãoDerrubaAsBoas() {
        let data = history("""
        {"t": 1784931561009, "org": "o", "u": {"fh": 30, "sd": 10}},
        {"t": 1784931861009, "org": "o", "u": {"fh": 999, "sd": 10}},
        {"t": 1784932161009, "org": "o", "u": {"fh": 32, "sd": 11}}
        """)
        let series = ClaudeDesktop.parseSamples(data)["o"]
        #expect(series?.count == 2)
        #expect(series?.map(\.fiveHour) == [30, 32])
    }

    /// A unit-slipped timestamp (µs where ms was meant) describes a date tens of thousands of years
    /// out. Left in, it becomes an interval the reset derivation would try to walk ten minutes at a
    /// time — gigabytes of allocation on the main actor, at launch.
    @Test func timestampForaDeÉpocaPlausívelÉDescartado() {
        let data = history("""
        {"t": 1784931561009000, "org": "o", "u": {"fh": 5, "sd": 10}},
        {"t": 1784931561, "org": "o", "u": {"fh": 6, "sd": 10}},
        {"t": 1784931561009, "org": "o", "u": {"fh": 7, "sd": 10}}
        """)
        let series = ClaudeDesktop.parseSamples(data)["o"]
        #expect(series?.count == 1)
        #expect(series?.first?.fiveHour == 7)
    }
}
