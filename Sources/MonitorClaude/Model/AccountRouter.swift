import Foundation
import CryptoKit

enum AccountRouter {
    struct Account: Equatable {
        enum Role: String { case route, reserve }

        var id: String
        var label: String
        var directory: URL
        var usesDefaultDirectory: Bool
        var role: Role
        var monogram: String = ""
    }

    struct Config: Equatable {
        var enabled: Bool
        var principal: String
        var accounts: [Account]
        var reserveBelow: Double
        var preferred: String?

        var hasExtraAccounts: Bool { accounts.contains { !$0.usesDefaultDirectory } }
        var route: [Account] { accounts.filter { $0.role == .route } }
        var reserve: [Account] { accounts.filter { $0.role == .reserve } }

        /// "A do topo primeiro" while a preferred account is set, "a de mais folga" otherwise: the queue in the
        /// panel writes the preferred account as the head of the route, so this is the only reading needed.
        var strategy: Strategy { preferred == nil ? .headroom : .order }
    }

    /// The router's own rule, named for what it does: with a preferred account (the head of the route) sessions
    /// open there while it has room, and otherwise, or once it runs out, on the account with the most room. The
    /// order below the head only breaks ties.
    enum Strategy: String, CaseIterable, Identifiable {
        case order, headroom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .order: return "A do topo primeiro"
            case .headroom: return "A de mais folga"
            }
        }
    }

    struct Switch: Equatable {
        var at: Date
        var from: String
        var to: String
        var reason: String
    }

    static let commandNames = ["claude-auto", "claude-accounts"]

    /// `CLAUDE_AUTO_HOME` wins, like in the router, so a test or a second setup never touches the real accounts.
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_AUTO_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-accounts")
    }
    static var configURL: URL { home.appendingPathComponent("config.json") }
    static var switchesURL: URL { home.appendingPathComponent(".estado/trocas.jsonl") }
    static var exhaustedURL: URL { home.appendingPathComponent(".estado/esgotadas.json") }
    static var slotBurnRateURL: URL { home.appendingPathComponent(".estado/ritmo.json") }
    static var defaultConfigDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }
    static var commandsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
    }

    static var bundledCommands: URL? {
        guard let bin = Bundle.main.resourceURL?.appendingPathComponent("router/bin"),
              FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("claude-auto").path)
        else { return nil }
        return bin
    }

    static var agentsLoginsDirectory: URL { home.appendingPathComponent(".estado/agentes") }

    static func hasAgentsLogin(_ id: String) -> Bool {
        guard let data = try? Data(contentsOf: agentsLoginsDirectory.appendingPathComponent("\(id).json")) else { return false }
        return isUsableAgentsLogin(data)
    }

    static func isUsableAgentsLogin(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root["invalidoEm"] == nil
    }

    static var accountsCommand: URL? {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_BIN"], !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        let installed = commandsDirectory.appendingPathComponent("claude-accounts")
        if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        return bundledCommands?.appendingPathComponent("claude-accounts")
    }

    static func watchAgents() {
        guard let command = accountsCommand else { return }
        let process = Process()
        process.executableURL = command
        process.arguments = ["_vigiar"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    static var commandsInstalled: Bool {
        FileManager.default.fileExists(atPath: commandsDirectory.appendingPathComponent("claude-auto").path)
    }

    // MARK: config

    static func loadConfig() -> Config? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return parseConfig(data, home: home, defaultDirectory: defaultConfigDirectory)
    }

    /// Why a config that exists cannot be read, in words; nil when it reads, or when there is none.
    static var configProblem: String? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        let shown = configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        guard let data = try? Data(contentsOf: configURL) else { return "O Monitor não consegue ler \(shown)" }
        return parseConfig(data, home: home, defaultDirectory: defaultConfigDirectory) == nil ? "\(shown) não é um JSON válido" : nil
    }

    static func parseConfig(_ data: Data, home: URL, defaultDirectory: URL) -> Config? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let principal = root["principal"] as? String ?? "principal"
        let entries = root["contas"] as? [String: Any] ?? [:]
        let known = Set(entries.keys).union([principal])
        // A hand-edited config can list an account twice; keep the first, since every view keys accounts by id.
        var seen = Set<String>()
        let listedRoute = ((root["rota"] as? [String]) ?? []).filter { known.contains($0) && seen.insert($0).inserted }
        let route = listedRoute.isEmpty ? [principal] : listedRoute
        let reserve = ((root["reserva"] as? [String]) ?? []).filter {
            known.contains($0) && !route.contains($0) && seen.insert($0).inserted
        }
        let reserveBelow = ((root["limites"] as? [String: Any])?["reserva"] as? NSNumber)?.doubleValue ?? 3

        func account(_ id: String, _ role: Account.Role) -> Account {
            let entry = entries[id] as? [String: Any] ?? [:]
            let custom = (entry["dir"] as? String).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            let usesDefault = id == principal && custom == nil
            let label = entry["nome"] as? String ?? id
            let given = (entry["sigla"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Account(
                id: id,
                label: label,
                directory: custom ?? (usesDefault ? defaultDirectory : home.appendingPathComponent(id)),
                usesDefaultDirectory: usesDefault,
                role: role,
                monogram: given.isEmpty ? monogram(for: label) : String(given.prefix(2)).uppercased())
        }

        let preferred = (root["preferida"] as? String).flatMap { route.contains($0) || reserve.contains($0) ? $0 : nil }

        return Config(
            enabled: root["ativo"] as? Bool ?? true,
            principal: principal,
            accounts: route.map { account($0, .route) } + reserve.map { account($0, .reserve) },
            reserveBelow: reserveBelow,
            preferred: preferred)
    }

    struct UnreadableConfig: LocalizedError {
        var errorDescription: String? {
            "O config.json do roteador não é um JSON válido. Corrija ou apague o arquivo antes de mudar a troca de conta."
        }
    }

    static func setEnabled(_ enabled: Bool, at url: URL = configURL) throws {
        try updateConfig(at: url) { $0["ativo"] = enabled }
    }

    static func setPreferred(_ id: String?, at url: URL = configURL) throws {
        try updateConfig(at: url) { $0["preferida"] = id }
    }

    /// Writes the queue the way the router reads it: `rota` above the divider, `reserva` below it, and the
    /// head of the route as `preferida` when the rule is to follow the order.
    static func saveQueue(route: [String], reserve: [String], strategy: Strategy, at url: URL = configURL) throws {
        guard !route.isEmpty else { throw EmptyRoute() }
        try updateConfig(at: url) { root in
            root["rota"] = route
            root["reserva"] = reserve
            root["preferida"] = strategy == .order ? route[0] : nil
        }
    }

    static func setStrategy(_ strategy: Strategy, route: [String], at url: URL = configURL) throws {
        try updateConfig(at: url) { root in
            root["preferida"] = strategy == .order ? route.first : nil
        }
    }

    static func renameAccount(_ id: String, name: String, monogram: String, at url: URL = configURL) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sigla = String(monogram.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).uppercased()
        try updateConfig(at: url) { root in
            var contas = root["contas"] as? [String: Any] ?? [:]
            var entry = contas[id] as? [String: Any] ?? [:]
            if !name.isEmpty { entry["nome"] = name }
            if sigla.isEmpty { entry.removeValue(forKey: "sigla") } else { entry["sigla"] = sigla }
            contas[id] = entry
            root["contas"] = contas
        }
    }

    struct EmptyRoute: LocalizedError {
        var errorDescription: String? { "A fila precisa de pelo menos uma conta fora da reserva." }
    }

    /// Two letters for the menu bar and the avatar: the initials of a name with two words or more, the first two
    /// letters otherwise, and the part in parentheses when there is one ("Thomas (Max)" is "MA").
    static func monogram(for label: String) -> String {
        var base = label
        if let open = label.lastIndex(of: "("), let close = label.lastIndex(of: ")"), open < close {
            let inner = label[label.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { base = inner }
        }
        let words = base
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard let first = words.first else { return "?" }
        if words.count >= 2, let second = words.dropFirst().first?.first {
            return (String(first.prefix(1)) + String(second)).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }

    /// A router id for a new account: lowercase, no accents, dashes for anything else, unique among `taken`.
    static func slug(for name: String, taken: Set<String>) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
        var out = ""
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch), ch.isASCII { out.unicodeScalars.append(ch) }
            else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = trimmed.isEmpty ? "conta" : String(trimmed.prefix(32))
        var candidate = base
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    struct ConfigBusy: LocalizedError {
        var errorDescription: String? {
            "Outro processo está mudando a config do roteador agora. Tente de novo."
        }
    }

    static func updateConfig(at url: URL, _ change: (inout [String: Any]) -> Void) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withFileLock(for: url) {
            var root: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { throw UnreadableConfig() }
                root = existing
            }
            change(&root)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        }
    }

    static func withFileLock<T>(for url: URL, timeout: TimeInterval = 2, staleAfter: TimeInterval = 10,
                                _ body: () throws -> T) throws -> T {
        let lock = url.path + ".lock"
        let deadline = Date().addingTimeInterval(timeout)
        var owner = takeFileLock(lock, staleAfter: staleAfter)
        while owner == nil {
            guard Date() < deadline else { throw ConfigBusy() }
            usleep(50_000)
            owner = takeFileLock(lock, staleAfter: staleAfter)
        }
        defer { releaseFileLock(lock, owner: owner, staleAfter: staleAfter) }
        return try body()
    }

    private static func releaseFileLock(_ lock: String, owner: UInt64?, staleAfter: TimeInterval) {
        guard inode(of: lock) == owner else { return }
        if rmdir(lock) == 0 { return }
        guard errno == ENOTEMPTY || errno == EEXIST else { return }
        // A fresh claim marker belongs to a live claimer that already checked this lock's inode: leave the
        // lock for it to finish the takeover, or a third process could take a new lock it would then move.
        let claim = lock + "/tomada"
        guard staleInode(of: claim, after: staleAfter) != nil else { return }
        rmdir(claim)
        rmdir(lock)
    }

    private static func takeFileLock(_ lock: String, staleAfter: TimeInterval) -> UInt64? {
        if mkdir(lock, 0o755) == 0 { return inode(of: lock) }
        guard errno == EEXIST, let stale = staleInode(of: lock, after: staleAfter) else { return nil }
        let claim = lock + "/tomada"
        guard markClaim(claim, staleAfter: staleAfter) else { return nil }
        guard inode(of: lock) == stale else {
            rmdir(claim)
            return nil
        }
        let aside = "\(lock).\(getpid()).\(UUID().uuidString)"
        guard rename(lock, aside) == 0 else { return nil }
        try? FileManager.default.removeItem(atPath: aside)
        return nil
    }

    /// Clears a claim marker left behind by a claimer that died and tries again in the same call: removing it
    /// refreshes the lock's mtime, so returning here would make everyone wait for the lock to go stale twice.
    private static func markClaim(_ claim: String, staleAfter: TimeInterval) -> Bool {
        for _ in 0..<2 {
            if mkdir(claim, 0o755) == 0 { return true }
            guard errno == EEXIST, staleInode(of: claim, after: staleAfter) != nil else { return false }
            rmdir(claim)
        }
        return false
    }

    /// The inode of `path` when it is older than `interval`, from a single lstat, so the age and the inode
    /// always describe the same directory (the router's `inodeDaTravaVelha` does the same).
    private static func staleInode(of path: String, after interval: TimeInterval) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date().timeIntervalSince1970 - modified > interval ? UInt64(info.st_ino) : nil
    }

    private static func inode(of path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    static func installCommands(from bin: URL, into directory: URL = commandsDirectory) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in commandNames {
            let link = directory.appendingPathComponent(name)
            let target = bin.appendingPathComponent(name)
            if let current = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if current == target.path { continue }
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                continue
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        }
    }

    // MARK: accounts

    static func keychainService(for account: Account) -> String {
        guard !account.usesDefaultDirectory else { return Keychain.service }
        let digest = SHA256.hash(data: Data(account.directory.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(Keychain.service)-\(hex.prefix(8))"
    }

    static func identity(for account: Account) -> AccountIdentity? {
        let file = account.usesDefaultDirectory
            ? ClaudeConfig.url
            : account.directory.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return ClaudeConfig.parseActiveAccount(data)
    }

    static func credentials(for account: Account, timeout: TimeInterval = 8) -> Keychain.Credentials? {
        try? Keychain.credentials(service: keychainService(for: account), timeout: timeout)
    }

    // MARK: state

    static var usageCacheURL: URL { home.appendingPathComponent(".estado/uso.json") }

    /// What the router last read for one account, from its own cache.
    struct RouterReading: Equatable {
        var snapshot: UsageSnapshot
        /// The server asked for a pause (HTTP 429) until then: nobody should ask about this account before it.
        var waitUntil: Date?
    }

    /// The router's cache (`uso.json`, read-only here): the same server numbers the Monitor reads, stamped with
    /// when they were read (`usoDe` when the last try failed and kept the previous numbers). The freshest reading
    /// wins on the panel, and an account the router just asked about is not asked about again.
    static func routerReadings(at url: URL = usageCacheURL) -> [String: RouterReading] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return parseRouterReadings(data)
    }

    static func parseRouterReadings(_ data: Data) -> [String: RouterReading] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        func date(_ any: Any?) -> Date? {
            (any as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        var out: [String: RouterReading] = [:]
        for (id, value) in root {
            guard let entry = value as? [String: Any],
                  let windows = (entry["uso"] as? [String: Any])?["janelas"] as? [[String: Any]],
                  let readAt = date(entry["usoDe"]) ?? ((entry["ok"] as? Bool) == true ? date(entry["verificadoEm"]) : nil)
            else { continue }
            var snap = UsageSnapshot()
            snap.fetchedAt = readAt
            for w in windows {
                guard let kind = w["chave"] as? String, let used = (w["usado"] as? NSNumber)?.doubleValue else { continue }
                // The router keeps the server's label ("Weekly Fable"); the model is what follows "Weekly".
                let model = kind == "weekly_scoped"
                    ? (w["rotulo"] as? String).map { $0.replacingOccurrences(of: "Weekly ", with: "") } : nil
                snap.windows.append(UsageAPI.window(kind: kind, model: model, percent: used, resetsAt: date(w["renovaEm"]),
                                                    severity: w["severidade"] as? String ?? "normal",
                                                    isActive: kind == "session"))
            }
            guard !snap.windows.isEmpty else { continue }
            UsageAPI.sortWindows(&snap)
            out[id] = RouterReading(snapshot: snap, waitUntil: date(entry["esperarAte"]))
        }
        return out
    }

    static var liveLimitsDirectory: URL { home.appendingPathComponent(".estado/ao-vivo") }

    /// What a stream session last received for one account, and for which login (`conta`, the account and
    /// organization pair), so numbers from a login that has since changed are never shown under the new one.
    struct LiveLimits: Equatable {
        var snapshot: UsageSnapshot
        var key: String?
    }

    /// The limits a stream session (the VS Code extension or T3 through the router) last received for each account,
    /// saved by the router as the response headers arrive: no `/usage` call spent, and seconds old while a session
    /// is working.
    static func liveLimits(in dir: URL = liveLimitsDirectory) -> [String: LiveLimits] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [String: LiveLimits] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let live = parseLiveLimits(data) else { continue }
            out[file.deletingPathExtension().lastPathComponent] = live
        }
        return out
    }

    static func parseLiveLimits(_ data: Data) -> LiveLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = (root["em"] as? NSNumber)?.doubleValue,
              let windows = root["janelas"] as? [String: Any]
        else { return nil }
        var snap = UsageSnapshot()
        snap.fetchedAt = Date(timeIntervalSince1970: at / 1000)
        for (key, kind) in [("five_hour", "session"), ("seven_day", "weekly_all")] {
            guard let w = windows[key] as? [String: Any], let used = (w["usado"] as? NSNumber)?.doubleValue else { continue }
            let resets = (w["renovaEm"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            snap.windows.append(UsageAPI.window(kind: kind, model: nil, percent: used, resetsAt: resets,
                                                severity: "normal", isActive: kind == "session"))
        }
        guard !snap.windows.isEmpty else { return nil }
        UsageAPI.sortWindows(&snap)
        return LiveLimits(snapshot: snap, key: root["conta"] as? String)
    }

    /// `base` with the session and weekly windows replaced by the live numbers, matched by what the window is (an
    /// older stored snapshot names them `five_hour` and `seven_day`). The server's severity of an older read does
    /// not carry over to new numbers, and a reset that already passed is dropped rather than kept. The per-model
    /// windows and the extra credit stay as the last full read left them.
    static func merging(_ live: UsageSnapshot, into base: UsageSnapshot?, now: Date = Date()) -> UsageSnapshot {
        var out = base ?? UsageSnapshot()
        for window in live.windows {
            let same: (LimitWindow) -> Bool = window.isSession
                ? { $0.isSession }
                : { LimitWindow.weeklyAllKeys.contains($0.key) }
            if let i = out.windows.firstIndex(where: same) {
                out.windows[i].utilization = window.utilization
                out.windows[i].severity = window.severity
                if let resets = window.resetsAt {
                    out.windows[i].resetsAt = resets
                    out.windows[i].resetIsExact = true
                } else if let old = out.windows[i].resetsAt, old <= now {
                    out.windows[i].resetsAt = nil
                }
            } else {
                out.windows.append(window)
            }
        }
        out.fetchedAt = live.fetchedAt
        out.source = .api
        UsageAPI.sortWindows(&out)
        return out
    }

    /// The freshest whole reading, with live numbers merged in when they are newer still.
    static func combined(full: UsageSnapshot?, live: UsageSnapshot?) -> UsageSnapshot? {
        guard let live, live.fetchedAt > (full?.fetchedAt ?? .distantPast) else { return full }
        return merging(live, into: full)
    }

    static func exhausted(now: Date = Date()) -> [String: Date] {
        guard let data = try? Data(contentsOf: exhaustedURL) else { return [:] }
        return parseExhausted(data, now: now)
    }

    static func parseExhausted(_ data: Data, now: Date) -> [String: Date] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: Date] = [:]
        for (id, value) in root {
            guard let ms = ((value as? [String: Any])?["ate"] as? NSNumber)?.doubleValue else { continue }
            let until = Date(timeIntervalSince1970: ms / 1000)
            if until > now { result[id] = until }
        }
        return result
    }

    static func lastSwitch() -> Switch? {
        guard let text = try? String(contentsOf: switchesURL, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.flatMap { parseSwitch(Data($0.utf8)) }
    }

    /// The latest switches, newest first.
    static func switches(limit: Int = 30) -> [Switch] {
        guard let text = try? String(contentsOf: switchesURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(limit).reversed().compactMap { parseSwitch(Data($0.utf8)) }
    }

    /// The reason the router recorded, in words.
    static func reasonText(_ reason: String) -> String {
        let base = reason.hasPrefix("agents ") ? String(reason.dropFirst("agents ".count)) : reason
        let agents = reason.hasPrefix("agents ")
        let text: String
        switch base {
        case "five_hour": text = "limite de 5h"
        case let r where r.hasPrefix("seven_day"): text = "limite da semana"
        case "limite", "rate_limit": text = "limite"
        case "auth": text = "pediu login de novo"
        case "preventiva": text = "quase no limite"
        case "preferida": text = "volta para a preferida"
        case "ao abrir": text = "sem folga ao abrir"
        case "manual": text = "troca manual"
        case "teste": text = "teste"
        default: text = base
        }
        return agents ? "\(text), agentes" : text
    }

    // MARK: commands

    struct CommandResult: Equatable {
        var status: Int32
        var output: String
        var error: String
        /// Ended by a signal (the time limit, typically) rather than exiting on its own.
        var interrupted = false
        var ok: Bool { status == 0 && !interrupted }
    }

    /// Runs `claude-accounts` with `arguments` and waits, off the main actor. The environment is the app's plus
    /// `extra`, so `CLAUDE_AUTO_HOME` and friends pass through.
    static func runAccounts(_ arguments: [String], extra: [String: String] = [:],
                            timeout: TimeInterval = 60) async -> CommandResult {
        guard let command = accountsCommand else {
            return CommandResult(status: 127, output: "", error: "claude-accounts não encontrado")
        }
        return await Blocking.run { run(command, arguments, extra: extra, timeout: timeout) }
    }

    static func run(_ command: URL, _ arguments: [String], extra: [String: String] = [:],
                                timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = command
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // Both pipes drain as the command writes, so one that fills stderr never blocks on it.
        let output = PipeCollector(out.fileHandleForReading)
        let errors = PipeCollector(err.fileHandleForReading)
        do { try process.run() } catch {
            return CommandResult(status: 127, output: "", error: error.localizedDescription)
        }
        let pid = process.processIdentifier
        let stop = DispatchWorkItem {
            // Remembered, because once `pid` exits its children belong to launchd and can no longer be found
            // under it; whatever ignored SIGTERM gets SIGKILL with the parent.
            let children = terminateDescendants(of: pid)
            guard process.isRunning || !children.isEmpty else { return }
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                let late = process.isRunning ? terminateDescendants(of: pid, signal: SIGKILL) : []
                for child in children where !late.contains(child) && kill(child, 0) == 0 { kill(child, SIGKILL) }
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
        process.waitUntilExit()
        stop.cancel()
        // A helper the command left behind can keep the pipes open after it exits: the output gets a moment to
        // end, and then it is whatever arrived.
        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: output.finish(waiting: 2), as: UTF8.self),
                             error: String(decoding: errors.finish(waiting: 2), as: UTF8.self),
                             interrupted: process.terminationReason == .uncaughtSignal)
    }

    /// Sends `signal` (SIGTERM by default) to everything under `pid`, deepest first, and leaves `pid` itself
    /// alone. Returns the processes it signalled.
    @discardableResult
    static func terminateDescendants(of pid: pid_t, signal: Int32 = SIGTERM) -> [pid_t] {
        guard pid > 1 else { return [] }
        var pids = [pid_t](repeating: 0, count: 128)
        let written = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        var signalled: [pid_t] = []
        for child in pids.prefix(Int(written) / MemoryLayout<pid_t>.size) where child > 1 && child != pid {
            signalled += terminateDescendants(of: child, signal: signal)
            kill(child, signal)
            signalled.append(child)
        }
        return signalled
    }

    static func parseSwitch(_ line: Data) -> Switch? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ms = (root["em"] as? NSNumber)?.doubleValue,
              let from = root["de"] as? String,
              let to = root["para"] as? String
        else { return nil }
        return Switch(at: Date(timeIntervalSince1970: ms / 1000), from: from, to: to,
                      reason: root["motivo"] as? String ?? "")
    }

    static func slotBurnRate(account: String, snapshot: UsageSnapshot, session: BurnRate?, weekly: BurnRate?,
                             now: Date = Date()) -> SlotBurnRate? {
        let weeklyBinds = used(snapshot.weekly, now: now) > used(snapshot.session, now: now)
        guard let window = weeklyBinds ? snapshot.weekly : snapshot.session,
              let burn = weeklyBinds ? weekly : session,
              burn.percentPerHour.isFinite
        else { return nil }
        return SlotBurnRate(account: account, window: weeklyBinds ? "sete" : "cinco",
                            pointsPerMinute: burn.percentPerHour / 60, used: used(window, now: now),
                            usedAt: snapshot.fetchedAt, at: now)
    }

    static func publish(_ rate: SlotBurnRate, to url: URL = slotBurnRateURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(rate)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = "\(url.path).\(getpid()).\(UUID().uuidString).tmp"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    static func withdrawSlotBurnRate(at url: URL = slotBurnRateURL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: choice

    static func used(_ window: LimitWindow?, now: Date = Date()) -> Double {
        guard let window else { return 0 }
        if let reset = window.resetsAt, reset <= now { return 0 }
        return window.utilization
    }

    static func headroom(_ snapshot: UsageSnapshot, now: Date = Date()) -> Double {
        max(0, min(100, (100 - max(used(snapshot.session, now: now), used(snapshot.weekly, now: now))).rounded()))
    }

    static func pick(_ config: Config, headroom: [String: Double], available: Set<String>,
                     exhausted: [String: Date]) -> String? {
        let order = config.accounts.map(\.id)
        func score(_ id: String) -> Double { headroom[id] ?? 1 }
        if let preferred = config.preferred, available.contains(preferred), exhausted[preferred] == nil,
           score(preferred) > 0, score(preferred) >= config.reserveBelow {
            return preferred
        }
        func best(_ role: Account.Role) -> String? {
            order
                .filter { id in
                    config.accounts.first { $0.id == id }?.role == role
                        && available.contains(id) && exhausted[id] == nil && score(id) > 0
                }
                .enumerated()
                .max { a, b in (score(a.element), -a.offset) < (score(b.element), -b.offset) }?
                .element
        }
        let route = best(.route)
        if let reserve = best(.reserve), route.map({ score($0) < config.reserveBelow && score(reserve) > score($0) }) ?? true {
            return reserve
        }
        return route
    }
}

struct SlotBurnRate: Equatable, Encodable {
    var account: String
    var window: String
    var pointsPerMinute: Double
    var used: Double
    var usedAt: Date
    var at: Date

    enum CodingKeys: String, CodingKey {
        case account = "conta"
        case window = "janela"
        case pointsPerMinute = "ppPorMinuto"
        case used = "usado"
        case usedAt = "usadoEm"
        case at = "em"
    }
}

struct RouterState: Equatable {
    var config: AccountRouter.Config
    var pick: String?
    var usage: [String: UsageSnapshot]
    var lastSwitch: AccountRouter.Switch?
    var logins: [String: AccountIdentity] = [:]
    var read: Set<String> = []
    var available: Set<String> = []
    var exhausted: [String: Date] = [:]
    var agentsLogins: Set<String> = []
    var switches: [AccountRouter.Switch] = []
    /// Accounts whose login exists but whose token expired: nobody ran a session on them for a while, and only a
    /// session renews it (the Monitor never does). Their numbers stay as last read until then.
    var idleLogins: Set<String> = []

    func loginLabel(for id: String) -> String {
        guard available.contains(id) else { return "sem login: claude-accounts login \(id)" }
        return logins[id]?.email ?? "logada"
    }

    var sharedLogins: [[String]] {
        let ids = config.accounts.map(\.id).filter { logins[$0] != nil }
        return Dictionary(grouping: ids) { logins[$0]!.key }
            .values.filter { $0.count > 1 }
            .sorted { $0[0] < $1[0] }
    }

    var pickKey: String? { pick.flatMap { logins[$0]?.key } }

    func freshSnapshot(forKey key: String) -> UsageSnapshot? {
        guard read.contains(key),
              let id = logins.first(where: { $0.value.key == key })?.key
        else { return nil }
        return usage[id]
    }

    func isRouted(_ key: String?) -> Bool { key != nil && key == pickKey }}

/// Blocking work (a command waiting on a login in the browser, a brew upgrade, a config write) runs on a GCD queue,
/// and the caller awaits it without holding a thread of Swift's cooperative pool. That pool has one thread per
/// core, so a few commands blocked for minutes would stall every other task of the app.
enum Blocking {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    static func runThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Collects what arrives on a pipe as it arrives. `finish(waiting:)` waits up to that long for the end of the
/// output and returns what came, so a pipe someone else still holds open never blocks the caller for good.
final class PipeCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let ended = DispatchSemaphore(value: 0)
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { return }
            guard !chunk.isEmpty else {
                h.readabilityHandler = nil
                self.ended.signal()
                return
            }
            self.lock.lock()
            self.data.append(chunk)
            self.lock.unlock()
        }
    }

    func finish(waiting seconds: TimeInterval) -> Data {
        _ = ended.wait(timeout: .now() + seconds)
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
