import Foundation

// MARK: - connectors

/// One MCP server Claude Code marked as needing a new login, from `mcp-needs-auth-cache.json`.
struct ConnectorAuthMark: Equatable {
    var name: String
    var since: Date?
}

/// Claude Code keeps a small registry of the MCP servers whose login it saw fail. Reading it costs no tokens and
/// starts no server, which is why the readiness panel's watcher reads it too.
enum MCPAuthCache {
    static let fileName = "mcp-needs-auth-cache.json"

    static func read(directories: [URL]) -> [ConnectorAuthMark] {
        var newest: [String: ConnectorAuthMark] = [:]
        for dir in directories {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { continue }
            for mark in parse(data) {
                if let current = newest[mark.name], (current.since ?? .distantPast) >= (mark.since ?? .distantPast) { continue }
                newest[mark.name] = mark
            }
        }
        return newest.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parse(_ data: Data) -> [ConnectorAuthMark] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root.map { name, value in
            let ms = ((value as? [String: Any])?["timestamp"] as? NSNumber)?.doubleValue
            return ConnectorAuthMark(name: name, since: ms.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil })
        }
    }

    /// The prefix the server's tools carry in a transcript: `claude.ai Slack` is `mcp__claude_ai_Slack__…`.
    static func toolKey(for name: String) -> String {
        String(name.unicodeScalars.map { ch -> Character in
            let ok = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_" || ch == "-"
            return ok ? Character(ch) : "_"
        })
    }

    /// The name people know: `claude.ai Slack` is "Slack", `plugin:atlassian:atlassian` is "Atlassian (plugin)".
    static func displayName(_ name: String) -> String {
        if name.hasPrefix("claude.ai ") { return String(name.dropFirst("claude.ai ".count)) }
        if name.hasPrefix("plugin:") {
            let last = name.split(separator: ":").last.map(String.init) ?? name
            return "\(last.prefix(1).uppercased())\(last.dropFirst()) (plugin)"
        }
        return name
    }

    static func isClaudeAI(_ name: String) -> Bool { name.hasPrefix("claude.ai ") }
}

/// Which MCP servers the transcripts show in use. Transcripts only grow, so each file is read once and then only
/// from where the last scan stopped; a file that shrank is read again from the start.
final class MCPUsageScanner: @unchecked Sendable {
    private var progress: [String: UInt64] = [:]
    private var lastUse: [String: Date] = [:]
    private let lock = NSLock()
    private static let needle = Data(#""name":"mcp__"#.utf8)
    private static let chunk = 4 * 1024 * 1024

    /// Server key → when a transcript last called it, within `window`: the line's own `timestamp`, or the file's
    /// modification time when the line has none.
    func scan(root: URL, window: TimeInterval = 7 * 86_400, now: Date = Date()) -> [String: Date] {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return lastUse
        }
        let cutoff = now.addingTimeInterval(-window)
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= cutoff
            else { continue }
            let size = UInt64(values.fileSize ?? 0)
            let path = url.path
            var from = progress[path] ?? 0
            if size < from { from = 0 }
            guard size > from else { continue }
            let read = Self.uses(in: url, from: from)
            for (key, at) in read.uses {
                let used = at == .distantPast ? modified : min(at, modified)
                if (lastUse[key] ?? .distantPast) < used { lastUse[key] = used }
            }
            progress[path] = read.through
        }
        lastUse = lastUse.filter { $0.value >= cutoff }
        return lastUse
    }

    /// The uses in `url` from `offset` on, and the offset just past the last newline read. The next scan starts
    /// there, so a line Claude Code was still writing is read again, whole, once it is complete.
    static func uses(in url: URL, from offset: UInt64) -> (uses: [String: Date], through: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([:], offset) }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return ([:], offset) }
        var found: [String: Date] = [:]
        var carry = Data()
        var read = offset
        var through = offset
        while let block = try? handle.read(upToCount: chunk), !block.isEmpty {
            if let newline = block.lastIndex(of: UInt8(ascii: "\n")) {
                through = read + UInt64(block.distance(from: block.startIndex, to: newline) + 1)
            }
            read += UInt64(block.count)
            var data = carry
            data.append(block)
            found.merge(uses(in: data)) { max($0, $1) }
            carry = data.count > 256 ? data.suffix(256) : data
        }
        return (found, through)
    }

    static func servers(in data: Data) -> Set<String> { Set(uses(in: data).keys) }

    /// Server key → the newest `timestamp` of a line in `data` that called it; `.distantPast` when the line has none.
    static func uses(in data: Data) -> [String: Date] {
        var found: [String: Date] = [:]
        var start = data.startIndex
        while let hit = data.range(of: needle, in: start..<data.endIndex) {
            start = hit.upperBound
            var i = hit.upperBound
            var name = [UInt8]()
            var terminated = false
            while i < data.endIndex, name.count < 120 {
                let b = data[i]
                if b == UInt8(ascii: "_"), i + 1 < data.endIndex, data[i + 1] == UInt8(ascii: "_") { terminated = true; break }
                if b == UInt8(ascii: "\"") { break }
                name.append(b)
                i += 1
            }
            // A name the end of the block cut short is read again, whole, with the next block.
            guard terminated, !name.isEmpty else { continue }
            let key = String(decoding: name, as: UTF8.self)
            let at = timestamp(around: hit.lowerBound, in: data) ?? .distantPast
            if (found[key] ?? .distantPast) <= at { found[key] = at }
        }
        return found
    }

    private static let stamp = Data(#""timestamp":""#.utf8)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The `timestamp` of the transcript line that holds `index`.
    static func timestamp(around index: Data.Index, in data: Data) -> Date? {
        let newline = UInt8(ascii: "\n")
        let lineStart = data[..<index].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
        let lineEnd = data[index...].firstIndex(of: newline) ?? data.endIndex
        guard let field = data.range(of: stamp, in: lineStart..<lineEnd),
              let quote = data[field.upperBound..<lineEnd].firstIndex(of: UInt8(ascii: "\""))
        else { return nil }
        let text = String(decoding: data[field.upperBound..<quote], as: UTF8.self)
        return iso.date(from: text) ?? ISO8601DateFormatter.flexible.date(from: text)
    }
}

// MARK: - readiness panel

/// What the readiness panel (`aeg-validate-dev-readiness`) last found, read from its `report.json`. The panel owns
/// the checks and the fixes; the Monitor only shows the ones about access that can drop.
struct ReadinessReport: Equatable {
    struct Item: Equatable {
        var id: String
        var title: String
        var status: String
        var summary: String
        var fixId: String?
        var fixParams: [String: String] = [:]
        var fixLabel: String?
        var url: URL?
        /// A command the person runs (`gh auth refresh …`), when the panel has no fix for it.
        var command: String?
    }
    var generatedAt: Date?
    var items: [Item]
}

enum Readiness {
    static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["MONITOR_CLAUDE_READINESS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".aeg/dev-readiness")
    }
    static var reportURL: URL { directory.appendingPathComponent("report.json") }
    static var launcherURL: URL { directory.appendingPathComponent("devready-launch.py") }
    static let panelURL = URL(string: "http://127.0.0.1:8790/")!
    static let installCommand = "claude plugin install aeg-validate-dev-readiness@aegro-workspace"

    /// The checks about logins and tokens that expire or drop: the part of the panel that changes from one day to
    /// the next. BigQuery datasets stay out (one expired ADC fails them all, and `data.gcloud.adc` already says
    /// so), and so do connectors: the Monitor reads the same registry and weighs it by what the transcripts use.
    static let accessPrefixes = [
        "data.gcloud.auth", "data.gcloud.adc", "cloud.aws.sso", "cloud.aws.ecr",
        "github.gh.auth", "github.ssh", "github.org.access", "github.packages", "github.env.token",
        "docker.running", "data.newrelic", "data.metabase", "data.mixpanel",
    ]

    static func isAccess(_ id: String) -> Bool { accessPrefixes.contains { id.hasPrefix($0) } }

    static func read() -> ReadinessReport? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> ReadinessReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["schema"] as? NSNumber)?.intValue == 1,
              let results = root["results"] as? [[String: Any]]
        else { return nil }
        let items: [ReadinessReport.Item] = results.compactMap { r in
            guard let id = r["id"] as? String, !id.isEmpty else { return nil }
            let actions = r["actions"] as? [[String: Any]] ?? []
            let fix = actions.first { ($0["fix_id"] as? String)?.isEmpty == false }
            let link = actions.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }.first
            let command = actions.compactMap { $0["command"] as? String }.first { !$0.isEmpty }
            return ReadinessReport.Item(
                id: id,
                title: r["title"] as? String ?? id,
                status: r["status"] as? String ?? "unknown",
                summary: r["summary"] as? String ?? "",
                fixId: fix?["fix_id"] as? String,
                fixParams: ((fix?["fix_params"] as? [String: Any]) ?? [:]).compactMapValues { value in
                    value is NSNull ? nil : (value as? String ?? "\(value)")
                },
                fixLabel: fix?["label"] as? String,
                url: link,
                command: command)
        }
        let at = (root["generatedAt"] as? String).flatMap { ISO8601DateFormatter.flexible.date(from: $0) }
        return ReadinessReport(generatedAt: at, items: items)
    }

    /// The panel's script inside the installed plugin, newest version first.
    static var installedScript: URL? {
        let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/plugins/cache")
        let fm = FileManager.default
        var found: [URL] = []
        for market in (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
            let plugin = market.appendingPathComponent("aeg-validate-dev-readiness")
            for version in (try? fm.contentsOfDirectory(at: plugin, includingPropertiesForKeys: nil)) ?? [] {
                let script = version.appendingPathComponent("skills/aeg-validate-dev-readiness/scripts/devready.py")
                if fm.fileExists(atPath: script.path) { found.append(script) }
            }
        }
        return found.sorted { $0.path.compare($1.path, options: .numeric) == .orderedDescending }.first
    }

    /// The fixed launcher the panel writes for autostart, or the plugin's script.
    static var entryPoint: URL? {
        FileManager.default.fileExists(atPath: launcherURL.path) ? launcherURL : installedScript
    }

    /// `--fix <id>` with the parameters the report attached to the action, as `--fix-param chave=valor`.
    static func fixArguments(_ id: String, params: [String: String]) -> [String] {
        ["--fix", id] + params.sorted { $0.key < $1.key }.flatMap { ["--fix-param", "\($0.key)=\($0.value)"] }
    }

    static func run(_ arguments: [String], timeout: TimeInterval = 600) async -> AccountRouter.CommandResult {
        guard let entry = entryPoint else {
            return .init(status: 127, output: "", error: "o painel de prontidão não está instalado")
        }
        return await Blocking.run {
            AccountRouter.run(URL(fileURLWithPath: "/usr/bin/python3"), [entry.path] + arguments, timeout: timeout)
        }
    }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - versions

/// Homebrew casks with a newer version, from the local metadata only (`HOMEBREW_NO_AUTO_UPDATE`).
enum Versions {
    struct Outdated: Equatable {
        var cask: String
        var installed: String
        var latest: String
    }

    static let watched: Set<String> = ["claude-code", "claude-code@latest", "monitor-claude"]

    static var brew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func outdated() -> [Outdated] {
        guard let brew else { return [] }
        let result = AccountRouter.run(brew, ["outdated", "--cask", "--greedy", "--json=v2"],
                                       extra: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"],
                                       timeout: 60)
        guard result.ok else { return [] }
        return parse(Data(result.output.utf8))
    }

    static func parse(_ data: Data) -> [Outdated] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]]
        else { return [] }
        return casks.compactMap { c in
            guard let name = c["name"] as? String, watched.contains(name),
                  let latest = c["current_version"] as? String
            else { return nil }
            let installed = (c["installed_versions"] as? [String])?.last ?? "?"
            return Outdated(cask: name, installed: Self.short(installed), latest: Self.short(latest))
        }
    }

    /// `2.31226.0,eb794d…` is `2.31226.0`.
    static func short(_ version: String) -> String {
        String(version.split(separator: ",").first ?? Substring(version))
    }
}

// MARK: - report

enum AccessAction: Equatable {
    case reauthorize(account: String, agents: Bool)
    case openURL(URL)
    case upgrade(cask: String)
    case readinessFix(id: String, params: [String: String])
    case copy(String)
    case readAgain
}

struct AccessItem: Identifiable, Equatable {
    enum Kind: Equatable { case needsYou, notConnecting }
    var id: String
    var badge: String
    var title: String
    var detail: String
    var kind: Kind
    var action: AccessAction?
    var actionLabel: String?
}

struct AccessReport: Equatable {
    enum ReadinessState: Equatable {
        case absent(installed: Bool)
        case present(generatedAt: Date?)
    }

    var items: [AccessItem] = []
    /// Connectors asking for a login that no transcript used in the last seven days.
    var quiet: [String] = []
    var quietRecent: [String] = []
    var healthy: [String] = []
    var checkedAt: Date = Date()
    var readiness: ReadinessState = .absent(installed: false)

    var needsYou: [AccessItem] { items.filter { $0.kind == .needsYou } }
    var notConnecting: [AccessItem] { items.filter { $0.kind == .notConnecting } }
    var attention: Int { items.count }
}

enum AccessBuilder {
    struct Account: Equatable {
        var id: String
        var label: String
        var hasLogin: Bool
        /// nil when the agents never needed a login for this account (it is where the agents run, or no agents).
        var agentsLoginWorks: Bool?
    }

    struct Inputs {
        var claudeLoginProblem: String?
        /// The problem is a Keychain prompt that was refused: the way out is to read again, not to log in.
        var claudeLoginRetry = false
        var routerConfigProblem: String?
        var routerConfigURL: URL = AccountRouter.configURL
        var accounts: [Account] = []
        var marks: [ConnectorAuthMark] = []
        var recentUse: [String: Date] = [:]
        var outdated: [Versions.Outdated] = []
        var readiness: ReadinessReport?
        var readinessInstalled = false
    }

    static func build(_ inputs: Inputs, now: Date = Date()) -> AccessReport {
        var report = AccessReport(checkedAt: now)
        var items: [AccessItem] = []

        if let problem = inputs.claudeLoginProblem {
            items.append(AccessItem(id: "claude.login", badge: "CC", title: "Login do Claude Code",
                                    detail: problem, kind: .needsYou,
                                    action: inputs.claudeLoginRetry ? .readAgain : .copy("claude"),
                                    actionLabel: inputs.claudeLoginRetry ? "Ler de novo" : "Copiar comando"))
        }
        if let problem = inputs.routerConfigProblem {
            items.append(AccessItem(id: "roteador.config", badge: "CA", title: "Config da troca de conta",
                                    detail: "\(problem). Até corrigir, a fila não aparece no Monitor.",
                                    kind: .needsYou, action: .openURL(inputs.routerConfigURL), actionLabel: "Abrir"))
        }
        for account in inputs.accounts where !account.hasLogin {
            items.append(AccessItem(id: "conta.\(account.id)", badge: AccountRouter.monogram(for: account.label),
                                    title: "\(account.label) sem login",
                                    detail: "A troca não usa esta conta até você autorizar de novo.",
                                    kind: .needsYou, action: .reauthorize(account: account.id, agents: false),
                                    actionLabel: "Autorizar"))
        }
        for account in inputs.accounts where account.hasLogin && account.agentsLoginWorks == false {
            items.append(AccessItem(id: "agentes.\(account.id)", badge: AccountRouter.monogram(for: account.label),
                                    title: "\(account.label): login dos agentes",
                                    detail: "Os agentes do claude agents não passam para esta conta até você autorizar.",
                                    kind: .needsYou, action: .reauthorize(account: account.id, agents: true),
                                    actionLabel: "Autorizar"))
        }

        // Connectors: a marked one that a transcript used in the last week needs you; the rest stay quiet.
        var quiet: [(String, Date?)] = []
        let marked = Set(inputs.marks.map { MCPAuthCache.toolKey(for: $0.name) })
        for mark in inputs.marks {
            let used = inputs.recentUse[MCPAuthCache.toolKey(for: mark.name)]
            let name = MCPAuthCache.displayName(mark.name)
            guard let used else {
                quiet.append((name, mark.since))
                continue
            }
            let age = mark.since.map { "Pediu login \(Fmt.ago($0, now: now)); " } ?? ""
            items.append(AccessItem(
                id: "mcp.\(mark.name)", badge: String(name.prefix(2)).uppercased(),
                title: "Conector \(name)",
                detail: "\(age)usado pela última vez \(Fmt.ago(used, now: now)).",
                kind: .needsYou,
                action: MCPAuthCache.isClaudeAI(mark.name) ? .openURL(URL(string: "https://claude.ai/settings/connectors")!) : .copy("/mcp"),
                actionLabel: MCPAuthCache.isClaudeAI(mark.name) ? "Reconectar" : "Copiar /mcp"))
        }
        report.quiet = quiet.map(\.0).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        report.quietRecent = quiet.filter { ($0.1.map { now.timeIntervalSince($0) } ?? .infinity) < 86_400 }.map(\.0)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        for o in inputs.outdated {
            let name = o.cask == "monitor-claude" ? "Monitor Claude" : "Claude Code"
            items.append(AccessItem(id: "versao.\(o.cask)", badge: o.cask == "monitor-claude" ? "MC" : "CC",
                                    title: "\(name) \(o.installed)",
                                    detail: "A \(o.latest) está no Homebrew.",
                                    kind: .needsYou, action: .upgrade(cask: o.cask), actionLabel: "Atualizar"))
        }

        if let readiness = inputs.readiness {
            report.readiness = .present(generatedAt: readiness.generatedAt)
            var fixed: [(action: AccessAction, index: Int)] = []
            for item in readiness.items where Readiness.isAccess(item.id) && (item.status == "warn" || item.status == "fail") {
                let action: AccessAction?
                let label: String?
                if let fix = item.fixId {
                    action = .readinessFix(id: fix, params: item.fixParams)
                    label = item.fixLabel.map(shortLabel) ?? "Resolver"
                } else if let url = item.url {
                    action = .openURL(url)
                    label = "Abrir"
                } else if let command = item.command {
                    action = .copy(command)
                    label = "Copiar comando"
                } else {
                    action = nil
                    label = nil
                }
                // One fix that unlocks several checks (the AWS staging login and the ECR image behind it) shows
                // once, saying what else it unlocks.
                if let action, case .readinessFix = action, let first = fixed.first(where: { $0.action == action }) {
                    let joined = items[first.index].detail.hasSuffix(".") ? "" : "."
                    items[first.index].detail += "\(joined) Também libera: \(item.title)."
                    continue
                }
                if let action, case .readinessFix = action { fixed.append((action, items.count)) }
                items.append(AccessItem(id: "pronto.\(item.id)", badge: badge(forReadiness: item.id), title: item.title,
                                        detail: item.summary, kind: item.status == "fail" ? .notConnecting : .needsYou,
                                        action: action, actionLabel: label))
            }
        } else {
            report.readiness = .absent(installed: inputs.readinessInstalled)
        }

        // What is fine, in a few words.
        var healthy: [String] = []
        if inputs.claudeLoginProblem == nil {
            let extra = inputs.accounts.filter(\.hasLogin).count
            healthy.append(extra > 1 ? "Claude Code e \(extra) contas" : "Claude Code")
        }
        let used = inputs.recentUse.keys.filter { !marked.contains($0) }.count
        if used > 0 { healthy.append(used == 1 ? "1 conector em uso" : "\(used) conectores em uso") }
        if let readiness = inputs.readiness {
            let ok = Set(readiness.items.filter { $0.status == "ok" && Readiness.isAccess($0.id) }.map { shortName(forReadiness: $0.id) })
            healthy.append(contentsOf: ok.sorted())
        }
        report.healthy = healthy
        report.items = items
        return report
    }

    private static func badge(forReadiness id: String) -> String {
        if id.hasPrefix("cloud.aws") { return "AWS" }
        if id.hasPrefix("data.gcloud") { return "GC" }
        if id.hasPrefix("github") { return "GH" }
        if id.hasPrefix("docker") { return "DK" }
        if id.hasPrefix("data.newrelic") { return "NR" }
        if id.hasPrefix("data.metabase") { return "MB" }
        if id.hasPrefix("data.mixpanel") { return "MX" }
        return "?"
    }

    private static func shortName(forReadiness id: String) -> String {
        if id.hasPrefix("cloud.aws") { return "AWS" }
        if id.hasPrefix("data.gcloud.adc") { return "ADC" }
        if id.hasPrefix("data.gcloud") { return "gcloud" }
        if id.hasPrefix("github") { return "GitHub" }
        if id.hasPrefix("docker") { return "Docker" }
        if id.hasPrefix("data.newrelic") { return "New Relic" }
        if id.hasPrefix("data.metabase") { return "Metabase" }
        if id.hasPrefix("data.mixpanel") { return "Mixpanel" }
        return id
    }

    private static func shortLabel(_ label: String) -> String {
        label.count <= 18 ? label : "Resolver"
    }
}
