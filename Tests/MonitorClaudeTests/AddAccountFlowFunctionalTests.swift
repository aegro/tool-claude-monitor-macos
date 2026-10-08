import Foundation
import Testing
@testable import MonitorClaude

/// The "Adicionar conta" assistant end to end, against a stand-in `claude-accounts` on a temporary home: the same
/// commands and the same output as `claude auth login` (the manual address printed inside an OSC 8 link, the
/// automatic one handed to `BROWSER`), no network and no browser. Serialized because it points the router's
/// environment variables at its own folder.
@Suite(.serialized) @MainActor
struct AddAccountFlowFunctionalTests {
    let base: URL
    var home: URL { base.appendingPathComponent("home") }
    var config: URL { home.appendingPathComponent("config.json") }

    static let automatic = "https://claude.com/cai/oauth/authorize?code=true&client_id=fake&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=s1"
    static let manual = "https://claude.com/cai/oauth/authorize?code=true&client_id=fake&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=s1"

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-assistente-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("principal"), withIntermediateDirectories: true)
        try Data(#"""
        { "contas": { "principal": { "nome": "Thomas (Aegro)", "dir": "\#(home.path)/principal" } },
          "rota": ["principal"], "ativo": false }
        """#.utf8).write(to: config)
        try Self.write(Self.fakeAccounts, to: base.appendingPathComponent("claude-accounts"))
        try Self.write(Self.fakeLogin, to: base.appendingPathComponent("fake-login.sh"))
        setenv("CLAUDE_AUTO_HOME", home.path, 1)
        setenv("CLAUDE_ACCOUNTS_BIN", base.appendingPathComponent("claude-accounts").path, 1)
        setenv("FAKE_DIR", base.path, 1)
        unsetenv("FAKE_NO_BROWSER")
        unsetenv("FAKE_ADD_FAIL")
        AddAccountFlow.manualAfter = 5
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func newFlow(opened: Box<[(URL, Bool)]>) -> AddAccountFlow {
        let flow = AddAccountFlow(store: AccountStore(url: base.appendingPathComponent("accounts.json")), desktop: [])
        flow.openHandler = { url, incognito in opened.value.append((url, incognito)) }
        return flow
    }

    private func readConfig() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    }

    /// Waits on the main actor, letting the timers and the process callbacks run, until `done` holds.
    private func until(_ seconds: TimeInterval = 8, _ done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return done()
    }

    private func touch(_ name: String) throws {
        try Data().write(to: base.appendingPathComponent(name))
    }

    // MARK: tests

    @Test func criaAbreOEnderecoAutomaticoLeQuemEntrouEColocaNaReserva() async throws {
        let opened = Box<[(URL, Bool)]>([])
        let flow = newFlow(opened: opened)
        await flow.choose(nil)
        #expect(flow.step == .authorize)
        #expect(flow.accountId == "nova-conta")

        flow.authorize(incognito: true)
        #expect(await until { !opened.value.isEmpty })
        // The automatic address, the one that comes back by itself, never the manual one printed on the terminal.
        #expect(opened.value.map(\.0.absoluteString) == [Self.automatic])
        #expect(opened.value.first?.1 == true)
        #expect(!flow.needsCode)

        try touch("callback")
        #expect(await until { flow.step == .connected })
        #expect(flow.identity?.email == "nova@exemplo.com")
        #expect(flow.duplicateOf == nil)

        flow.confirmConnected()
        #expect(flow.step == .agents)
        flow.skipAgents()
        #expect(flow.step == .place)
        flow.name = "Squad Compare"
        flow.monogram = "sc"
        flow.reserve = true
        await flow.finish()
        #expect(flow.step == .done)

        let root = try readConfig()
        #expect(root["rota"] as? [String] == ["principal"])
        #expect(root["reserva"] as? [String] == ["nova-conta"])
        #expect(root["ativo"] as? Bool == true)
        let entry = (root["contas"] as? [String: Any])?["nova-conta"] as? [String: Any]
        #expect(entry?["nome"] as? String == "Squad Compare")
        #expect(entry?["sigla"] as? String == "SC")
    }

    @Test func semBrowserCapturadoAbreAPaginaManualEMandaOCodigo() async throws {
        setenv("FAKE_NO_BROWSER", "1", 1)
        AddAccountFlow.manualAfter = 0.3
        let opened = Box<[(URL, Bool)]>([])
        let flow = newFlow(opened: opened)
        await flow.choose(nil)
        flow.authorize(incognito: false)
        #expect(await until { flow.needsCode })
        #expect(opened.value.map(\.0.absoluteString) == [Self.manual])

        flow.code = "so-o-codigo"
        flow.sendCode()
        #expect(await until {
            if case .failed(let text) = flow.phase { return text.contains("não veio inteiro") }
            return false
        })

        flow.code = "  abc123#s1 \n"
        flow.sendCode()
        #expect(await until { flow.step == .connected })
        #expect(try String(contentsOf: base.appendingPathComponent("codigo"), encoding: .utf8) == "abc123#s1\n")
        #expect(!flow.needsCode)
    }

    @Test func cancelarEncerraOLoginInteiroEApagaAContaCriada() async throws {
        let opened = Box<[(URL, Bool)]>([])
        let flow = newFlow(opened: opened)
        await flow.choose(nil)
        let dir = home.appendingPathComponent("nova-conta")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        // A link to a folder outside the account, like the router's links to ~/.claude: it must survive.
        let shared = base.appendingPathComponent("compartilhada")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("fica".utf8).write(to: shared.appendingPathComponent("arquivo"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("projects"), withDestinationURL: shared)

        flow.authorize(incognito: false)
        let pidFile = base.appendingPathComponent("login.pid")
        #expect(await until { FileManager.default.fileExists(atPath: pidFile.path) })
        let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(pid > 0)

        flow.cancel()
        #expect(await until(4) { kill(pid, 0) != 0 })
        #expect((try readConfig()["contas"] as? [String: Any])?["nova-conta"] == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(try String(contentsOf: shared.appendingPathComponent("arquivo"), encoding: .utf8) == "fica")
        // What the stopped login reports when it exits must not land on the assistant.
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(flow.phase == .idle || flow.phase == .working("Esperando você autorizar…"))
    }

    @Test func tentarDeNovoNaoHerdaOFimDaTentativaAnterior() async throws {
        let opened = Box<[(URL, Bool)]>([])
        let flow = newFlow(opened: opened)
        await flow.choose(nil)
        flow.authorize(incognito: false)
        #expect(await until { opened.value.count == 1 })
        // A second click starts over: the first login is stopped and its exit is ignored.
        flow.authorize(incognito: false)
        #expect(await until { opened.value.count == 2 })
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(flow.phase == .working("Esperando você autorizar…"))
        try touch("callback")
        #expect(await until { flow.step == .connected })
    }

    @Test func mesmaContaDeOutraEntradaDaFilaEApontada() async throws {
        // The principal is already this account and organization.
        try Data(#"{"oauthAccount": {"accountUuid": "u-nova", "organizationUuid": "o-nova", "emailAddress": "nova@exemplo.com"}}"#.utf8)
            .write(to: home.appendingPathComponent("principal/.claude.json"))
        let opened = Box<[(URL, Bool)]>([])
        let flow = newFlow(opened: opened)
        await flow.choose(nil)
        flow.authorize(incognito: false)
        try touch("callback")
        #expect(await until { flow.step == .connected })
        #expect(flow.duplicateOf == "Thomas (Aegro)")
        flow.retryLogin()
        #expect(flow.step == .authorize && flow.identity == nil)
    }

    @Test func erroDoRoteadorApareceEmUmaLinha() async throws {
        setenv("FAKE_ADD_FAIL", "account nova-conta already exists", 1)
        let flow = newFlow(opened: Box([]))
        await flow.choose(nil)
        #expect(flow.step == .choose)
        #expect(flow.phase == .failed("account nova-conta already exists"))
    }

    // MARK: stand-ins

    /// `claude-accounts` with the commands the assistant runs. `login` runs the stand-in for `claude auth login`
    /// as its child and ignores Ctrl-C, like the router.
    static let fakeAccounts = #"""
    #!/bin/bash
    home="${CLAUDE_AUTO_HOME:?}"
    cmd="$1"; shift
    case "$cmd" in
      add)
        id="$1"; shift
        name="$id"; [ "$1" = "--name" ] && name="$2"
        if [ -n "$FAKE_ADD_FAIL" ]; then echo "claude-accounts: $FAKE_ADD_FAIL" >&2; exit 1; fi
        mkdir -p "$home/$id"
        /usr/bin/python3 -I - "$home/config.json" "$id" "$name" <<'EOF'
    import json, sys, os
    path, id, name = sys.argv[1:]
    cfg = json.load(open(path)) if os.path.exists(path) else {}
    cfg.setdefault("contas", {})[id] = {"nome": name}
    cfg["rota"] = [c for c in cfg.get("rota", []) if c != id] + [id]
    json.dump(cfg, open(path, "w"))
    EOF
        echo "added $id" ;;
      login)
        id="$1"; shift
        trap '' INT
        # `&` alone would give the child /dev/null as input; the login reads the pasted code from ours.
        /bin/bash "$FAKE_DIR/fake-login.sh" "$id" "$1" <&0 &
        wait $!
        exit $? ;;
      *) echo "claude-accounts: unknown command $cmd" >&2; exit 2 ;;
    esac
    """#

    /// `claude auth login`: prints the manual address, hands the automatic one to `BROWSER`, then waits for the
    /// callback (a file the test writes) or a `code#state` on its input, and writes the identity it logged in as.
    static let fakeLogin = #"""
    #!/bin/bash
    id="$1"
    home="${CLAUDE_AUTO_HOME:?}"
    auto='\#(automatic)'
    manual='\#(manual)'
    echo $$ > "$FAKE_DIR/login.pid"
    printf 'Opening browser to sign in\xe2\x80\xa6\n'
    printf 'If the browser didn'"'"'t open, visit: \033]8;;%s\033\\%s\033]8;;\033\\\n' "$manual" "$manual"
    printf 'Paste code here if prompted > '
    if [ -z "$FAKE_NO_BROWSER" ] && [ -n "$BROWSER" ]; then "$BROWSER" "$auto"; fi
    for i in $(seq 1 30); do
      [ -f "$FAKE_DIR/callback" ] && break
      if read -t 1 line; then
        case "$line" in
          *"#"*) printf '%s\n' "$line" > "$FAKE_DIR/codigo"; break ;;
          *) echo "Invalid code. Please make sure the full code was copied." >&2 ;;
        esac
      fi
    done
    [ -f "$FAKE_DIR/callback" ] || [ -f "$FAKE_DIR/codigo" ] || { echo "Login timed out" >&2; exit 1; }
    printf '{"oauthAccount": {"accountUuid": "u-nova", "organizationUuid": "o-nova", "emailAddress": "nova@exemplo.com", "organizationName": "Nova", "organizationType": "claude_max"}}' > "$home/$id/.claude.json"
    echo "Login successful."
    """#
}

/// A reference cell the open handler can append to from its closure.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// The integrations against real files: a `.zshrc` and a VS Code `settings.json` in a temporary folder, through
/// the same entry points the settings window calls.
@Suite(.serialized)
struct IntegrationsFunctionalTests {
    let base: URL
    var zshrc: URL { base.appendingPathComponent(".zshrc") }
    var vscode: URL { base.appendingPathComponent("Code/User/settings.json") }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-integracoes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        setenv("MONITOR_CLAUDE_ZSHRC", zshrc.path, 1)
        setenv("MONITOR_CLAUDE_VSCODE_SETTINGS", vscode.path, 1)
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func terminalLigaEDesligaNumZshrcQueNaoExistia() throws {
        try Integrations.setTerminal(true)
        #expect(Integrations.readTerminal() == .on)
        #expect(text(zshrc)?.contains("alias claude=\"$HOME/.local/bin/claude-auto\"") == true)
        try Integrations.setTerminal(true)
        #expect(text(zshrc)?.components(separatedBy: "alias claude=").count == 2)
        try Integrations.setTerminal(false)
        #expect(Integrations.readTerminal() == .off)
        #expect(text(zshrc) == "")
        #expect(text(URL(fileURLWithPath: zshrc.path + ".monitor-claude.bak"))?.contains("claude-auto") == true)
    }

    @Test func aliasAMaoNaoEDesligado() throws {
        try Data("alias claude=claude-auto\n".utf8).write(to: zshrc)
        #expect(Integrations.readTerminal() == .onByHand)
        #expect(throws: Integrations.EditedByHand.self) { try Integrations.setTerminal(false) }
        #expect(text(zshrc) == "alias claude=claude-auto\n")
    }

    @Test func vscodeGravaNoSettingsComComentariosEVolta() throws {
        try FileManager.default.createDirectory(at: vscode.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\n    // tema\n    \"workbench.colorTheme\": \"Default Dark+\",\n    \"editor.fontSize\": 13\n}"
        try Data(original.utf8).write(to: vscode)
        try Integrations.setVSCodeWrapper(true)
        #expect(Integrations.readVSCodeWrapper() == Integrations.claudeAutoPath)
        #expect(text(vscode)?.contains("// tema") == true)
        #expect(text(URL(fileURLWithPath: vscode.path + ".monitor-claude.bak")) == original)
        try Integrations.setVSCodeWrapper(false)
        #expect(text(vscode) == original)
    }

    @Test func vscodeInvalidoNaoEReescrito() throws {
        try FileManager.default.createDirectory(at: vscode.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ \"a\": ".utf8).write(to: vscode)
        #expect(throws: Integrations.UnreadableSettings.self) { try Integrations.setVSCodeWrapper(true) }
        #expect(text(vscode) == "{ \"a\": ")
        #expect(!FileManager.default.fileExists(atPath: vscode.path + ".monitor-claude.bak"))
    }

    @Test func desligarSemSettingsNaoCriaArquivo() throws {
        try Integrations.setVSCodeWrapper(false)
        #expect(!FileManager.default.fileExists(atPath: vscode.path))
    }
}
