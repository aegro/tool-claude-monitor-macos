import Foundation
import Testing
@testable import MonitorClaude

/// The shapes the `Claude Code-credentials` item actually shows up in. The distinction that
/// matters is "no account logged in" versus "this file is broken": both used to surface as
/// "formato inesperado", which is a lie for the first one and sends you looking for a corrupt
/// file that is not there.
struct KeychainParseTests {
    @Test func lêASessãoDaContaAninhadaEmClaudeAiOauth() throws {
        let creds = try Keychain.parse([
            "claudeAiOauth": [
                "accessToken": "sk-ant-oat01-exemplo",
                "expiresAt": 1_784_918_018_681 as Double,
                "subscriptionType": "max",
                "scopes": ["user:inference", "user:profile"],
            ],
        ])

        #expect(creds.accessToken == "sk-ant-oat01-exemplo")
        #expect(creds.subscriptionType == "max")
        #expect(creds.scopes == ["user:inference", "user:profile"])
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_784_918_018.681))
    }

    /// The bug this whole taxonomy exists for: the item survives with only the MCP tokens in it.
    @Test func itemSóComMcpOAuthNãoÉCorrupção() {
        let root: [String: Any] = ["mcpOAuth": ["algum-servidor": ["accessToken": "mcp-token"]]]
        #expect(throws: Keychain.Failure.noAccountToken) { try Keychain.parse(root) }
    }

    @Test func sessãoDeContaSemTokenTambémÉAusência() {
        #expect(throws: Keychain.Failure.noAccountToken) {
            try Keychain.parse(["claudeAiOauth": ["subscriptionType": "max"]])
        }
        #expect(throws: Keychain.Failure.noAccountToken) {
            try Keychain.parse(["claudeAiOauth": ["accessToken": ""]])
        }
        #expect(throws: Keychain.Failure.noAccountToken) { try Keychain.parse([:]) }
    }

    /// Only a shape that cannot be read at all earns "formato inesperado".
    @Test func claudeAiOauthComTipoErradoÉFormatoInesperado() {
        #expect(throws: Keychain.Failure.malformed) {
            try Keychain.parse(["claudeAiOauth": "isto-deveria-ser-um-objeto"])
        }
    }

    @Test func aindaAceitaOFormatoAntigoSemAninhamento() throws {
        let creds = try Keychain.parse(["accessToken": "token-plano"])
        #expect(creds.accessToken == "token-plano")
        #expect(creds.expiresAt == nil)
        #expect(creds.scopes.isEmpty)
    }

    @Test func expiraçãoAusenteNãoContaComoVencida() {
        let creds = Keychain.Credentials(accessToken: "t", expiresAt: nil,
                                         subscriptionType: nil, scopes: [])
        #expect(!creds.isExpired)
        #expect(!creds.expiresSoon)
    }

    /// The five-minute skew is what makes the Monitor pick up the CLI's fresh token *before*
    /// the server starts rejecting the cached one.
    @Test func tokenPertoDeVencerPedeReleituraAntesDeVencer() {
        let emQuatroMinutos = Keychain.Credentials(
            accessToken: "t", expiresAt: Date().addingTimeInterval(4 * 60),
            subscriptionType: nil, scopes: [])
        #expect(!emQuatroMinutos.isExpired)
        #expect(emQuatroMinutos.expiresSoon)

        let vencido = Keychain.Credentials(
            accessToken: "t", expiresAt: Date().addingTimeInterval(-60),
            subscriptionType: nil, scopes: [])
        #expect(vencido.isExpired)
    }
}
