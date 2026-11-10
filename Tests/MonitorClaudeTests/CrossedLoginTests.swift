import Foundation
import Testing
@testable import MonitorClaude

/// An account folder signed in to another queue account (10/11/2026: the Aegro and Squad Compare folders with the Max
/// login, tagged Ultra and showing the Max's numbers under their names).
struct CrossedLoginTests {
    /// Each folder holds the login of `folders[id]`; each account has its own login saved by the router.
    private func scene(_ folders: [String: String]) throws -> (AccountRouter.Config, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cruzado-\(UUID().uuidString)")
        let saved = root.appendingPathComponent(".estado/agentes")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        func login(_ id: String) -> String {
            let account = id == "compare" ? "u-squad" : "u-thomas"
            return #"{"oauthAccount":{"accountUuid":"\#(account)","organizationUuid":"o-\#(id)","emailAddress":"\#(id)@exemplo"}}"#
        }
        for id in ["aegro", "max", "compare"] {
            let dir = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(login(folders[id] ?? id).utf8).write(to: dir.appendingPathComponent(".claude.json"))
            try Data(login(id).utf8).write(to: saved.appendingPathComponent("\(id).json"))
        }
        // The Max has a folder of its own: no account of the test lives in the ~/.claude of whoever runs it.
        let json = """
        { "principal": "max", "contas": { "aegro": {}, "max": { "dir": "\(root.appendingPathComponent("max").path)" }, "compare": {} },
          "rota": ["aegro", "max"], "reserva": ["compare"] }
        """
        let config = try #require(AccountRouter.parseConfig(Data(json.utf8), home: root,
                                                            defaultDirectory: root.appendingPathComponent(".claude")))
        return (config, saved)
    }

    private func crossed(_ id: String, _ config: AccountRouter.Config, _ saved: URL) throws -> AccountRouter.CrossedLogin? {
        AccountRouter.crossedLogin(for: try #require(config.accounts.first { $0.id == id }), config: config, in: saved)
    }

    @Test func pastasQueTrocaramDeLoginApontamADonaDele() throws {
        // 16:47: the Aegro folder already had the Max login, so the Aegro login in the Compare folder was known only
        // by the login the router saved for the Aegro.
        let (config, saved) = try scene(["aegro": "max", "max": "aegro", "compare": "aegro"])
        #expect(try crossed("aegro", config, saved)?.owner == "max")
        #expect(try crossed("max", config, saved)?.owner == "aegro")
        #expect(try crossed("compare", config, saved)?.owner == "aegro")
        #expect(try crossed("compare", config, saved)?.found.key == "u-thomas:o-aegro")
    }

    @Test func pastaComOPróprioLoginNãoÉCruzada() throws {
        let (config, saved) = try scene([:])
        for id in ["aegro", "max", "compare"] { #expect(try crossed(id, config, saved) == nil) }
    }

    @Test func loginQueNãoÉDeNinguémDaFilaNãoProvaNada() {
        #expect(AccountRouter.resolveCrossedLogin(found: "u:novo", own: "u:velho", saved: [("b", "u:b")], current: [("b", "u:b")]) == nil)
        // Without a saved login of its own, the account has nothing to be compared to.
        #expect(AccountRouter.resolveCrossedLogin(found: "u:b", own: nil, saved: [("b", "u:b")], current: []) == nil)
        // The saved login names the owner before the login another folder holds now.
        #expect(AccountRouter.resolveCrossedLogin(found: "u:b", own: "u:a", saved: [("b", "u:b")], current: [("c", "u:b")]) == "b")
        #expect(AccountRouter.resolveCrossedLogin(found: "u:c", own: "u:a", saved: [("b", "u:b")], current: [("c", "u:c")]) == "c")
    }

    @Test func acessoPedeOLoginCertoEmVezDeSemLogin() throws {
        var inputs = AccessBuilder.Inputs()
        inputs.accounts = [
            .init(id: "aegro", label: "Thomas (Aegro)", hasLogin: false, agentsLoginWorks: nil, loginOf: "Thomas (Ultra)"),
            .init(id: "max", label: "Thomas (Ultra)", hasLogin: true, agentsLoginWorks: nil),
        ]
        let items = AccessBuilder.build(inputs).items
        #expect(items.map(\.id) == ["conta.aegro.trocado"])
        let item = try #require(items.first)
        #expect(item.title == "Thomas (Aegro): login de outra conta")
        #expect(item.detail.contains("login da Thomas (Ultra)"))
        #expect(item.action == .reauthorize(account: "aegro", agents: false))
    }
}
