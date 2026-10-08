import Foundation
import Testing
@testable import MonitorClaude

struct IntegrationsTests {
    private let block = Integrations.terminalBlock.joined(separator: "\n")

    // MARK: terminal

    @Test func blocoDoTerminalEntraESaiSemSobrarNada() throws {
        let on = Integrations.enablingTerminal("")
        #expect(on == block + "\n")
        #expect(Integrations.terminalState(on) == .on)
        #expect(Integrations.disablingTerminal(on) == "")

        let rc = "export PATH=\"$HOME/.local/bin:$PATH\"\n"
        let withBlock = Integrations.enablingTerminal(rc)
        #expect(withBlock == rc + "\n" + block + "\n")
        #expect(Integrations.enablingTerminal(withBlock) == withBlock)
        #expect(Integrations.disablingTerminal(withBlock) == rc)

        let noNewline = Integrations.enablingTerminal("alias ll='ls -l'")
        #expect(noNewline.hasPrefix("alias ll='ls -l'\n\n# Monitor Claude"))
    }

    @Test func aliasEscritoAMaoNaoEMexido() {
        for line in ["alias claude=claude-auto", "alias claude='claude-auto'",
                     "alias claude=\"$HOME/.local/bin/claude-auto\"", "  alias claude=/Users/x/.claude-accounts/bin/claude-auto # meu"] {
            let rc = "export A=1\n\(line)\n"
            #expect(Integrations.terminalState(rc) == .onByHand, "\(line)")
            #expect(Integrations.enablingTerminal(rc) == rc)
            #expect(Integrations.disablingTerminal(rc) == nil)
        }
        #expect(Integrations.terminalState("# alias claude=claude-auto\n") == .off)
        #expect(Integrations.terminalState("alias claude=claude-automatico\n") == .off)
        #expect(Integrations.terminalState("alias claudex=claude-auto\n") == .off)
    }

    @Test func blocoDaVersaoAnteriorAindaEDoMonitor() {
        let legacy = Integrations.legacyTerminalBlocks[0].joined(separator: "\n")
        let rc = "export A=1\n\n" + legacy + "\n"
        #expect(Integrations.terminalState(rc) == .on)
        #expect(Integrations.enablingTerminal(rc) == rc)
        #expect(Integrations.disablingTerminal(rc) == "export A=1\n")
        #expect(block.contains("$HOME/.local/bin/claude-auto"))
    }

    @Test func blocoIndentadoAindaEReconhecido() {
        let indented = "if true; then\n" + Integrations.terminalBlock.map { "  " + $0 }.joined(separator: "\n") + "\nfi\n"
        #expect(Integrations.terminalState(indented) == .on)
        #expect(Integrations.disablingTerminal(indented) == "if true; then\nfi\n")
    }

    // MARK: VS Code

    private func wrapper(_ text: String) -> String? { Integrations.wrapper(in: text) }

    @Test func ligarNumSettingsVazioOuInexistente() throws {
        let out = try Integrations.settingWrapper("", to: "/x/claude-auto")
        #expect(out == "{\n  \"claudeCode.claudeProcessWrapper\": \"/x/claude-auto\"\n}\n")
        #expect(wrapper(out) == "/x/claude-auto")
        // Turning it off where there was nothing writes nothing.
        #expect(try Integrations.settingWrapper("", to: nil) == "")
        #expect(try Integrations.settingWrapper("{}", to: nil) == "{}")
    }

    @Test func comentariosEVirgulaFinalSobrevivem() throws {
        let text = """
        {
          // Editor
          "editor.fontSize": 13, // tamanho
          "files.autoSave": "afterDelay",
          "url": "https://exemplo.com/a//b",
        }
        """
        let out = try Integrations.settingWrapper(text, to: "/x/claude-auto")
        #expect(wrapper(out) == "/x/claude-auto")
        #expect(out.contains("// Editor") && out.contains("// tamanho") && out.contains("https://exemplo.com/a//b"))
        let off = try Integrations.settingWrapper(out, to: nil)
        #expect(wrapper(off) == nil)
        #expect(!off.contains("claudeProcessWrapper"))
        #expect(off.contains("// Editor") && off.contains("// tamanho") && wrapper(off) == nil)
        #expect(Integrations.wrapper(in: off) == nil && (try? Integrations.settingWrapper(off, to: nil)) == off)
    }

    @Test func ligarEDesligarVoltaAoArquivoQueOVSCodeEscreve() throws {
        let text = "{\n    \"editor.fontSize\": 13,\n    \"files.autoSave\": \"afterDelay\"\n}"
        let on = try Integrations.settingWrapper(text, to: "/x/claude-auto")
        #expect(on.contains("\n    \"claudeCode.claudeProcessWrapper\""))
        #expect(try Integrations.settingWrapper(on, to: nil) == text)
    }

    @Test func virgulaVaiAntesDoComentarioDaUltimaLinha() throws {
        let text = "{\n  \"editor.fontSize\": 13 // tamanho\n}\n"
        let out = try Integrations.settingWrapper(text, to: "/x/claude-auto")
        #expect(out == "{\n  \"editor.fontSize\": 13, // tamanho\n  \"claudeCode.claudeProcessWrapper\": \"/x/claude-auto\"\n}\n")
    }

    @Test func trocaOValorExistenteSemDuplicarAChave() throws {
        for current in [#""/velho/claude-auto""#, "null", "false", "42"] {
            let text = "{\n  \"a\": 1,\n  \"claudeCode.claudeProcessWrapper\": \(current),\n  \"b\": 2\n}\n"
            let out = try Integrations.settingWrapper(text, to: "/novo/claude-auto")
            #expect(wrapper(out) == "/novo/claude-auto", "\(current)")
            #expect(out.components(separatedBy: "claudeCode.claudeProcessWrapper").count == 2, "\(current)")
            #expect(out.contains("\"b\": 2"))
        }
    }

    @Test func chaveComentadaNaoEOSetting() throws {
        let text = "{\n  // \"claudeCode.claudeProcessWrapper\": \"/velho\",\n  \"a\": 1\n}\n"
        #expect(wrapper(text) == nil)
        let out = try Integrations.settingWrapper(text, to: "/novo")
        #expect(wrapper(out) == "/novo")
        #expect(out.contains("// \"claudeCode.claudeProcessWrapper\": \"/velho\","))
        #expect(try Integrations.settingWrapper(text, to: nil) == text)
    }

    @Test func desligarTiraAChaveEAVirgulaCertaELinha() throws {
        let last = "{\n  \"a\": 1,\n  \"claudeCode.claudeProcessWrapper\": \"/x\"\n}\n"
        #expect(try Integrations.settingWrapper(last, to: nil) == "{\n  \"a\": 1\n}\n")
        let first = "{\n  \"claudeCode.claudeProcessWrapper\": \"/x\",\n  \"a\": 1\n}\n"
        #expect(try Integrations.settingWrapper(first, to: nil) == "{\n  \"a\": 1\n}\n")
        let only = "{\"claudeCode.claudeProcessWrapper\": \"/x\"}"
        #expect(try Integrations.settingWrapper(only, to: nil) == "{}")
        let crlf = "{\r\n  \"a\": 1,\r\n  \"claudeCode.claudeProcessWrapper\": \"/x\"\r\n}\r\n"
        let crlfOff = try Integrations.settingWrapper(crlf, to: nil)
        #expect(wrapper(crlfOff) == nil)
        #expect(!crlfOff.contains("claudeProcessWrapper"))
    }

    @Test func caminhoComEspacoEAspasViraJSONValido() throws {
        let path = "/Users/x/Application Support/claude \"auto\""
        let out = try Integrations.settingWrapper("{}", to: path)
        #expect(wrapper(out) == path)
        #expect(!out.contains("\\/"))
    }

    @Test func settingsInvalidoNaoEReescrito() {
        for bad in ["{ \"a\": }", "[]", "\"texto\"", "{ \"a\": 1 "] {
            #expect(throws: Integrations.UnreadableSettings.self, "\(bad)") {
                try Integrations.settingWrapper(bad, to: "/x")
            }
        }
    }

    @Test func jsoncSemComentarioNemVirgulaFinalMasComAsStringsIntactas() {
        #expect(Integrations.stripJSONC(#"{"a": "x,}", "b": [1,2,], /* c */ "d": "//",}"#)
                == #"{"a": "x,}", "b": [1,2],"# + String(repeating: " ", count: 9) + #""d": "//"}"#)
        let masked = Integrations.maskingComments("{ \"a\": 1 /* é */ } // fim")
        #expect(masked.utf16.count == "{ \"a\": 1 /* é */ } // fim".utf16.count)
        #expect(!masked.contains("fim") && !masked.contains("é"))
    }

    // MARK: files

    @Test func gravacaoSegueOLinkGuardaCopiaEMantemPermissoes() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("monitor-integracoes-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("zshrc-real")
        let link = dir.appendingPathComponent(".zshrc")
        try Data("export A=1\n".utf8).write(to: real)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        try Integrations.write("export A=2\n", to: link)

        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8) == "export A=2\n")
        #expect(try String(contentsOf: URL(fileURLWithPath: real.path + ".monitor-claude.bak"), encoding: .utf8) == "export A=1\n")
        let perms = try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }
}

struct AccessTests {
    // MARK: connectors

    @Test func registroDeLoginDosConectores() throws {
        let data = Data(#"""
        { "claude.ai Slack": { "timestamp": 1791000000000 }, "plugin:atlassian:atlassian": { "timestamp": 0 }, "estranho": "x" }
        """#.utf8)
        let marks = MCPAuthCache.parse(data).sorted { $0.name < $1.name }
        #expect(marks.map(\.name) == ["claude.ai Slack", "estranho", "plugin:atlassian:atlassian"])
        #expect(marks[0].since == Date(timeIntervalSince1970: 1_791_000_000))
        #expect(marks[1].since == nil && marks[2].since == nil)
        #expect(MCPAuthCache.parse(Data("[]".utf8)).isEmpty)
        #expect(MCPAuthCache.parse(Data("lixo".utf8)).isEmpty)
    }

    @Test func registroMaisNovoVenceEntreAsPastas() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("monitor-mcp-\(UUID().uuidString)")
        let a = base.appendingPathComponent("a"), b = base.appendingPathComponent("b")
        for d in [a, b] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(#"{"claude.ai Slack": {"timestamp": 1000}}"#.utf8).write(to: a.appendingPathComponent(MCPAuthCache.fileName))
        try Data(#"{"claude.ai Slack": {"timestamp": 5000}, "claude.ai Figma": {"timestamp": 1}}"#.utf8)
            .write(to: b.appendingPathComponent(MCPAuthCache.fileName))
        let marks = MCPAuthCache.read(directories: [a, b, base.appendingPathComponent("nao-existe")])
        #expect(marks.map(\.name) == ["claude.ai Figma", "claude.ai Slack"])
        #expect(marks.last?.since == Date(timeIntervalSince1970: 5))
    }

    @Test func nomeDaFerramentaENomeDeGente() {
        #expect(MCPAuthCache.toolKey(for: "claude.ai Slack") == "claude_ai_Slack")
        #expect(MCPAuthCache.toolKey(for: "claude.ai Plataforma - Aegro") == "claude_ai_Plataforma_-_Aegro")
        #expect(MCPAuthCache.toolKey(for: "plugin:atlassian:atlassian") == "plugin_atlassian_atlassian")
        #expect(MCPAuthCache.displayName("claude.ai Slack") == "Slack")
        #expect(MCPAuthCache.displayName("plugin:atlassian:atlassian") == "Atlassian (plugin)")
        #expect(MCPAuthCache.displayName("gdrive") == "gdrive")
    }

    @Test func conectoresUsadosNasConversas() {
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__claude_ai_Slack__slack_send_message","input":{}}]}}"#,
            #"{"type":"tool_use","name":"mcp__plugin_github_github__get_pr"}"#,
            #"{"type":"tool_use","name":"mcp__claude_ai_Plataforma_-_Aegro__ai_tools"}"#,
            #"{"name":"mcp__"}"#,
            #"{"type":"tool_use","name":"Bash"}"#,
        ].joined(separator: "\n")
        #expect(MCPUsageScanner.servers(in: Data(lines.utf8))
                == ["claude_ai_Slack", "plugin_github_github", "claude_ai_Plataforma_-_Aegro"])
    }

    @Test func nomeCortadoNoFimDoBlocoNaoConta() {
        #expect(MCPUsageScanner.servers(in: Data(#"{"name":"mcp__claude_ai_Slack__x"} {"name":"mcp__claude_ai_Sl"#.utf8))
                == ["claude_ai_Slack"])
    }

    @Test func horaDoUsoVemDaLinhaENaoDoArquivo() throws {
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__claude_ai_Slack__send"}]},"timestamp":"2026-10-01T12:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__claude_ai_Slack__read"}]},"timestamp":"2026-10-03T08:30:00.500Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__claude_ai_Gmail__x"}]}}"#,
        ].joined(separator: "\n")
        let uses = MCPUsageScanner.uses(in: Data(lines.utf8))
        #expect(uses["claude_ai_Slack"] == ISO8601DateFormatter().date(from: "2026-10-03T08:30:00Z")?.addingTimeInterval(0.5))
        #expect(uses["claude_ai_Gmail"] == .distantPast)

        // A transcript still being written today does not make a connector used weeks ago look recent.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("monitor-transcripts-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let old = #"{"name":"mcp__claude_ai_Figma__x","timestamp":"2026-09-01T10:00:00.000Z"}"#
        let recent = #"{"name":"mcp__claude_ai_Slack__x","timestamp":"\#(ISO8601DateFormatter().string(from: Date()))"}"#
        try Data((old + "\n" + recent + "\n").utf8).write(to: root.appendingPathComponent("s.jsonl"))
        #expect(Set(MCPUsageScanner().scan(root: root).keys) == ["claude_ai_Slack"])
    }

    @Test func varreduraLeSoOQueCresceuEIgnoraOAntigo() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("monitor-transcripts-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-x-Code-y")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s1.jsonl")
        try Data((#"{"name":"mcp__claude_ai_Slack__x"}"# + "\n").utf8).write(to: file)
        let old = project.appendingPathComponent("s0.jsonl")
        try Data((#"{"name":"mcp__claude_ai_Figma__x"}"# + "\n").utf8).write(to: old)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86_400)], ofItemAtPath: old.path)

        let scanner = MCPUsageScanner()
        #expect(Set(scanner.scan(root: root).keys) == ["claude_ai_Slack"])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"name":"mcp__claude_ai_Gmail__y"}"# + "\n").utf8))
        try handle.close()
        #expect(Set(scanner.scan(root: root).keys) == ["claude_ai_Slack", "claude_ai_Gmail"])

        // A week later nothing was used.
        #expect(scanner.scan(root: root, now: Date().addingTimeInterval(8 * 86_400)).isEmpty)
    }

    // MARK: readiness panel

    private let report = Data(#"""
    { "schema": 1, "generatedAt": "2026-10-08T20:30:00-03:00",
      "results": [
        { "id": "cloud.aws.sso.dev", "title": "AWS SSO (dev)", "status": "warn", "summary": "A sessão venceu.",
          "actions": [ { "label": "Entrar de novo", "fix_id": "aws.sso.login", "fix_params": { "profile": "dev", "n": 2, "x": null } } ] },
        { "id": "data.gcloud.auth", "title": "gcloud", "status": "ok", "summary": "ok", "actions": [] },
        { "id": "docker.running", "title": "Docker", "status": "fail", "summary": "O Docker não está rodando.",
          "actions": [ { "label": "Abrir o guia", "url": "https://docs.docker.com/desktop/" } ] },
        { "id": "data.bq.billing", "title": "BigQuery billing", "status": "fail", "summary": "sem acesso", "actions": [] },
        { "id": "claude.mcp.slack", "title": "Slack", "status": "warn", "summary": "x", "actions": [] },
        { "title": "sem id" }
      ] }
    """#.utf8)

    @Test func relatorioDoPainelDeProntidao() throws {
        let parsed = try #require(Readiness.parse(report))
        #expect(parsed.items.count == 5)
        #expect(parsed.generatedAt == ISO8601DateFormatter().date(from: "2026-10-08T23:30:00Z"))
        let aws = try #require(parsed.items.first)
        #expect(aws.fixId == "aws.sso.login" && aws.fixLabel == "Entrar de novo")
        #expect(aws.fixParams == ["profile": "dev", "n": "2"])
        #expect(parsed.items[2].url?.host == "docs.docker.com")
        #expect(Readiness.parse(Data(#"{"schema": 2, "results": []}"#.utf8)) == nil)
        #expect(Readiness.fixArguments("aws.sso.login", params: ["profile": "dev", "n": "2"])
                == ["--fix", "aws.sso.login", "--fix-param", "n=2", "--fix-param", "profile=dev"])
    }

    @Test func soOsAcessosQueCaem() {
        #expect(Readiness.isAccess("cloud.aws.sso.staging"))
        #expect(Readiness.isAccess("data.gcloud.adc"))
        #expect(Readiness.isAccess("github.env.token"))
        #expect(!Readiness.isAccess("data.bq.billing"))
        #expect(!Readiness.isAccess("claude.mcp.slack"))
        #expect(!Readiness.isAccess("docker.compose"))
    }

    // MARK: versions

    @Test func versoesSoDosCasksDoClaude() {
        let data = Data(#"""
        { "formulae": [], "casks": [
          { "name": "claude-code@latest", "installed_versions": ["2.1.270"], "current_version": "2.1.294" },
          { "name": "monitor-claude", "installed_versions": ["0.4.0", "0.4.1"], "current_version": "0.5.0" },
          { "name": "firefox", "installed_versions": ["1"], "current_version": "2" },
          { "name": "claude-code", "current_version": "2.31226.0,eb794d" }
        ] }
        """#.utf8)
        let out = Versions.parse(data)
        #expect(out == [
            Versions.Outdated(cask: "claude-code@latest", installed: "2.1.270", latest: "2.1.294"),
            Versions.Outdated(cask: "monitor-claude", installed: "0.4.1", latest: "0.5.0"),
            Versions.Outdated(cask: "claude-code", installed: "?", latest: "2.31226.0"),
        ])
        #expect(Versions.parse(Data("{}".utf8)).isEmpty)
    }

    // MARK: report

    @Test func oQuePedeVoceOQueNaoConectaEOQueFicaQuieto() throws {
        let now = Date()
        var inputs = AccessBuilder.Inputs()
        inputs.accounts = [
            .init(id: "principal", label: "Thomas (Aegro)", hasLogin: true, agentsLoginWorks: nil),
            .init(id: "max", label: "Thomas (Max)", hasLogin: false, agentsLoginWorks: nil),
            .init(id: "compare", label: "Squad Compare", hasLogin: true, agentsLoginWorks: false),
        ]
        inputs.marks = [
            ConnectorAuthMark(name: "claude.ai Slack", since: now.addingTimeInterval(-3 * 3600)),
            ConnectorAuthMark(name: "claude.ai Notion", since: now.addingTimeInterval(-2 * 3600)),
            ConnectorAuthMark(name: "claude.ai Figma", since: now.addingTimeInterval(-10 * 86_400)),
        ]
        inputs.recentUse = ["claude_ai_Slack": now.addingTimeInterval(-86_400), "claude_ai_Gmail": now]
        inputs.outdated = [Versions.Outdated(cask: "claude-code@latest", installed: "2.1.270", latest: "2.1.294")]
        inputs.readiness = Readiness.parse(report)

        let out = AccessBuilder.build(inputs, now: now)
        #expect(out.items.map(\.id) == ["conta.max", "agentes.compare", "mcp.claude.ai Slack",
                                        "versao.claude-code@latest", "pronto.cloud.aws.sso.dev", "pronto.docker.running"])
        #expect(out.needsYou.count == 5 && out.notConnecting.map(\.id) == ["pronto.docker.running"])
        #expect(out.quiet == ["Figma", "Notion"])
        #expect(out.quietRecent == ["Notion"])
        #expect(out.healthy == ["Claude Code e 2 contas", "1 conector em uso", "gcloud"])

        let slack = try #require(out.items.first { $0.id == "mcp.claude.ai Slack" })
        #expect(slack.action == .openURL(URL(string: "https://claude.ai/settings/connectors")!))
        let aws = try #require(out.items.first { $0.id == "pronto.cloud.aws.sso.dev" })
        #expect(aws.action == .readinessFix(id: "aws.sso.login", params: ["profile": "dev", "n": "2"]))
        #expect(aws.actionLabel == "Entrar de novo")
        let docker = try #require(out.items.first { $0.id == "pronto.docker.running" })
        #expect(docker.action == .openURL(URL(string: "https://docs.docker.com/desktop/")!))
        #expect(out.items.first { $0.id == "conta.max" }?.action == .reauthorize(account: "max", agents: false))
        #expect(out.items.first { $0.id == "agentes.compare" }?.action == .reauthorize(account: "compare", agents: true))
    }

    @Test func configDoRoteadorIlegivelPedeVoce() {
        var inputs = AccessBuilder.Inputs()
        inputs.routerConfigProblem = "~/.claude-accounts/config.json não é um JSON válido"
        inputs.routerConfigURL = URL(fileURLWithPath: "/tmp/config.json")
        let item = AccessBuilder.build(inputs).items.first
        #expect(item?.id == "roteador.config")
        #expect(item?.action == .openURL(URL(fileURLWithPath: "/tmp/config.json")))
    }

    @Test func loginDoClaudeQuebradoVemPrimeiroESemPainel() {
        var inputs = AccessBuilder.Inputs()
        inputs.claudeLoginProblem = "O login do terminal venceu."
        inputs.readinessInstalled = true
        let out = AccessBuilder.build(inputs)
        #expect(out.items.first?.id == "claude.login")
        #expect(out.healthy.isEmpty)
        #expect(out.readiness == .absent(installed: true))
    }
}
