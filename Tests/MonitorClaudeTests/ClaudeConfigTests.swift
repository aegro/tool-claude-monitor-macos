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
        #expect(id.accountUuid == "11111111-2222-3333-4444-555555555555")
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
            accountUuid: "u", organizationUuid: "org-1", email: "person@example.test",
            organizationName: "person@example.test's Organization",
            displayName: "Example User", organizationType: "claude_max")
        #expect(pessoal.label == "Example User")

        let curlyApostrophe = AccountIdentity(
            accountUuid: "u", organizationUuid: "org-1", email: "x@y.com",
            organizationName: "x@y.com’s Organization",
            displayName: nil, organizationType: nil)
        #expect(curlyApostrophe.label == "X")   // sem displayName, cai no local-part capitalizado
    }

    @Test func orgRealÉUsadaComoRótulo() {
        let empresa = AccountIdentity(
            accountUuid: "u", organizationUuid: "org-1", email: "person@example.test",
            organizationName: "Acme", displayName: "Example User",
            organizationType: "claude_max")
        #expect(empresa.label == "Acme")
    }

    @Test func rótuloNuncaFicaVazio() {
        let semNada = AccountIdentity(accountUuid: "abc1234567", organizationUuid: nil, email: nil,
                                      organizationName: nil, displayName: nil,
                                      organizationType: nil)
        #expect(semNada.label == "abc12345")   // prefixo (8) do uuid como último recurso

        let sóEmail = AccountIdentity(accountUuid: "u", organizationUuid: "org-1", email: "maria@exemplo.com",
                                      organizationName: "  ", displayName: nil,
                                      organizationType: nil)
        #expect(sóEmail.label == "Maria")
    }
}

/// One login can belong to several organizations. Switching between them keeps `accountUuid`
/// fixed and changes only the organization, so keying anything on the account alone made the
/// second organization overwrite the first instead of showing up beside it.
struct AccountKeyTests {
    private func identity(org: String?, orgName: String?) -> AccountIdentity {
        AccountIdentity(accountUuid: "34f33866-0000-0000-0000-000000000000",
                        organizationUuid: org, email: "person@example.test",
                        organizationName: orgName, displayName: "Example User",
                        organizationType: "claude_max")
    }

    @Test func mesmaContaEmOrgsDiferentesSãoEntradasDistintas() {
        let pessoal = identity(org: "c21c03a1-aaaa", orgName: "person@example.test's Organization")
        let empresa = identity(org: "f0f0f0f0-bbbb", orgName: "Acme")

        #expect(pessoal.accountUuid == empresa.accountUuid)   // é o mesmo login
        #expect(pessoal.key != empresa.key)                   // mas não a mesma entrada
        #expect(pessoal.label == "Example User")
        #expect(empresa.label == "Acme")
    }

    @Test func aMesmaOrgSempreDáAMesmaChave() {
        #expect(identity(org: "c21c03a1", orgName: "Acme").key
                == identity(org: "c21c03a1", orgName: "Acme").key)
    }

    /// Older CLIs may not expose the organization; the account alone still has to key something.
    @Test func semOrganizaçãoCaiNaContaSozinha() {
        let semOrg = identity(org: nil, orgName: nil)
        #expect(semOrg.key == "34f33866-0000-0000-0000-000000000000")
        #expect(!semOrg.key.contains(":"))
    }

    @Test func aChaveVemDoJsonReal() throws {
        let json = """
        { "oauthAccount": {
            "accountUuid": "34f33866-0000-0000-0000-000000000000",
            "organizationUuid": "c21c03a1-0000-0000-0000-000000000000",
            "emailAddress": "person@example.test",
            "organizationName": "Acme", "organizationType": "claude_max" } }
        """
        let id = try #require(ClaudeConfig.parseActiveAccount(Data(json.utf8)))
        #expect(id.key == "34f33866-0000-0000-0000-000000000000:c21c03a1-0000-0000-0000-000000000000")
    }
}
