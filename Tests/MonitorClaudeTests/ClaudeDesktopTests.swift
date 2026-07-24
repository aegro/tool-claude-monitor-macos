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

    /// A percentage the desktop app could not compute must not paint a full bar.
    @Test func porcentagemForaDeFaixaÉNeutralizada() {
        let data = history("{\"t\": 1784931561009, \"org\": \"o\", \"u\": {\"fh\": 1784931561009, \"sd\": -3}}")
        let org = ClaudeDesktop.parseUsage(data, names: [:]).first
        #expect(org?.fiveHour == 0)
        #expect(org?.weekly == 0)
    }
}
