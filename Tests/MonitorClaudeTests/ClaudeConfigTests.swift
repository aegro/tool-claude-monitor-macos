import Foundation
import Testing
@testable import MonitorClaude

struct ClaudeConfigTests {
    /// Representative shape of `~/.claude.json`'s `oauthAccount` (synthetic data — see PR review).
    @Test func lêAContaAtivaDoOauthAccount() throws {
        let json = """
        { "penguinModeOrgEnabled": false,
          "oauthAccount": {
            "accountUuid": "11111111-2222-3333-4444-555555555555",
            "emailAddress": "person@example.test",
            "organizationName": "person@example.test's Organization",
            "displayName": "Example User",
            "organizationType": "claude_max" } }
        """
        let id = try #require(ClaudeConfig.parseActiveAccount(Data(json.utf8)))
        #expect(id.uuid == "11111111-2222-3333-4444-555555555555")
        #expect(id.email == "person@example.test")
        #expect(id.planFallback == "max")
    }

    @Test func semOauthAccountRetornaNil() {
        #expect(ClaudeConfig.parseActiveAccount(Data("{}".utf8)) == nil)
        #expect(ClaudeConfig.parseActiveAccount(Data("{\"oauthAccount\":{}}".utf8)) == nil)
        #expect(ClaudeConfig.parseActiveAccount(Data("não é json".utf8)) == nil)
    }

    /// Claude auto-names a solo org "<email>'s Organization" — too long/redundant for a chip, so
    /// the label collapses to the person. A real org name is shown as-is.
    @Test func orgPessoalViraNomeDaPessoa() {
        let pessoal = AccountIdentity(
            uuid: "u", email: "person@example.test",
            organizationName: "person@example.test's Organization",
            displayName: "Example User", organizationType: "claude_max")
        #expect(pessoal.label == "Example User")

        let curlyApostrophe = AccountIdentity(
            uuid: "u", email: "x@y.com",
            organizationName: "x@y.com’s Organization",
            displayName: nil, organizationType: nil)
        #expect(curlyApostrophe.label == "X")   // sem displayName, cai no local-part capitalizado
    }

    @Test func orgRealÉUsadaComoRótulo() {
        let empresa = AccountIdentity(
            uuid: "u", email: "person@example.test",
            organizationName: "Acme", displayName: "Example User",
            organizationType: "claude_max")
        #expect(empresa.label == "Acme")
    }

    @Test func rótuloNuncaFicaVazio() {
        let semNada = AccountIdentity(uuid: "abc1234567", email: nil,
                                      organizationName: nil, displayName: nil,
                                      organizationType: nil)
        #expect(semNada.label == "abc12345")   // prefixo (8) do uuid como último recurso

        let sóEmail = AccountIdentity(uuid: "u", email: "maria@exemplo.com",
                                      organizationName: "  ", displayName: nil,
                                      organizationType: nil)
        #expect(sóEmail.label == "Maria")
    }
}
