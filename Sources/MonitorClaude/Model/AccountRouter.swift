import Foundation
import CryptoKit

enum AccountRouter {
    struct Account: Equatable {
        /// `pending`: created by the "Adicionar conta" assistant and not finished yet (`pendente` in the config).
        /// It stays out of the queue, so no session opens there and the panel does not list it.
        enum Role: String { case route, reserve, pending }

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
        /// `limites.voltar`: from this much room up an account is comfortable, and comfortable accounts compete by
        /// room per hour until the week renews (see `AccountRouter.pick`).
        var comfortableFrom: Double = 20
        /// The account the person chose by hand (`fixada`): new sessions open there whatever the rule, while it has
        /// room; out of room, the rule decides again.
        var pinned: String? = nil
        /// Whether the principal lives in `~/.claude` (no `dir` of its own). Only then is `~/.claude` the router's
        /// slot, and only then does `slotIdentity` apply its rule.
        var principalUsesDefaultDirectory: Bool = true
        /// Accounts the assistant created and has not finished: in `contas`, out of the queue.
        var pending: [Account] = []

        var hasExtraAccounts: Bool { accounts.contains { !$0.usesDefaultDirectory } }
        var route: [Account] { accounts.filter { $0.role == .route } }
        var reserve: [Account] { accounts.filter { $0.role == .reserve } }

        /// "A do topo primeiro" while a preferred account is set, "a de mais folga" otherwise: the queue in the
        /// panel writes the preferred account as the head of the route, so this is the only reading needed.
        var strategy: Strategy { preferred == nil ? .headroom : .order }

        /// Where each account's sessions write their files. The account in `~/.claude` has two folders: the router
        /// opens its stream sessions in its own folder (`<home>/<id>`) whenever there is a login there, so the
        /// agents' switch does not carry them along, and its other sessions still write in `~/.claude`.
        func sessionDirectories(home: URL = AccountRouter.home) -> [(id: String?, directory: URL)] {
            accounts.flatMap { account -> [(id: String?, directory: URL)] in
                let own: [(id: String?, directory: URL)] = account.usesDefaultDirectory
                    ? [(id: account.id, directory: home.appendingPathComponent(account.id))] : []
                return [(id: account.id, directory: account.directory)] + own
            }
        }
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

    /// One task run with `claude-accounts as` (a line of `.estado/acessos.jsonl`): asked from a session on `from` (nil
    /// when from a plain terminal), run on `account` with that login and org.
    struct OneShotTask: Equatable, Identifiable {
        /// The router's `<pid>-<start ms>`, unique per task; the pid tells a running task from one whose parent died.
        var id: String
        var at: Date
        var from: String?
        var account: String
        var login: String?
        var organization: String?
        var tools: [String]
        var request: String
        /// nil while it runs, or when the process that asked died before writing the end.
        var exitCode: Int?

        /// The `claude-accounts` process that ran it, from `id`.
        var pid: pid_t? { id.split(separator: "-").first.flatMap { pid_t($0) } }

        /// Whether the process that asked was still alive when the list was read (`AccountRouter.oneShotTasks`).
        /// Resolved there, not in the view, so a parent that dies changes the published state on the next refresh.
        var parentAlive = false

        /// No exit code and no live parent: the parent died (a session's Bash timed out, a closed terminal) before
        /// recording the end, and the task may have half-run.
        var abandoned: Bool { exitCode == nil && !parentAlive }

        /// How the row reads. Exit 0 says the process ended, not that the request worked: a delete the child could
        /// not confirm also ends with 0. Without an exit code, the process decides between running and abandoned; a
        /// task can run for as long as it needs, so there is no time cutoff.
        var outcome: String {
            switch exitCode {
            case 0: return "terminou"
            case let code?: return "saída \(code)"
            case nil: return abandoned ? "sem fim registrado" : "rodando"
            }
        }
    }

    /// Whether a process exists (`kill(pid, 0)`; EPERM still means it exists, under another user).
    static func processAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Whether `pid` is a process of this user that was already running at `startedBy`: the parent of a task, not a
    /// newer process that got the same pid. `claude-accounts` always runs as this user, so a pid owned by anyone else
    /// is a reuse. Read with `sysctl`, which sees every user's processes; if it fails, only a live process of this
    /// user counts (`kill` without EPERM).
    static func processAlive(_ pid: pid_t, startedBy: Date) -> Bool {
        guard pid > 0 else { return false }
        guard let info = processInfo(pid) else { return kill(pid, 0) == 0 }
        guard let info else { return false }
        // One second of slack: the router stamps the task with `Date.now()` right after it starts, in ms.
        return info.uid == getuid() && info.started <= startedBy.addingTimeInterval(1)
    }

    /// Owner and start time of `pid` from `sysctl(KERN_PROC_PID)`: `.some(nil)` when there is no such process (or only
    /// its zombie), nil
    /// when the call itself failed.
    static func processInfo(_ pid: pid_t) -> (uid: uid_t, started: Date)?? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        guard size > 0 else { return .some(nil) }
        // A zombie exited and only waits for its parent to reap it: no process, for the task.
        guard Int32(info.kp_proc.p_stat) != SZOMB else { return .some(nil) }
        let start = info.kp_proc.p_un.__p_starttime
        return .some((info.kp_eproc.e_ucred.cr_uid,
                      Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)))
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
    static var oneShotTasksURL: URL { home.appendingPathComponent(".estado/acessos.jsonl") }
    static var exhaustedURL: URL { home.appendingPathComponent(".estado/esgotadas.json") }
    static var slotBurnRateURL: URL { home.appendingPathComponent(".estado/ritmo.json") }
    static var refreshesURL: URL { home.appendingPathComponent(".estado/renovacoes.json") }
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
        let limits = root["limites"] as? [String: Any]
        let reserveBelow = (limits?["reserva"] as? NSNumber)?.doubleValue ?? 3
        let comfortableFrom = (limits?["voltar"] as? NSNumber)?.doubleValue ?? 20

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
                monogram: given.isEmpty ? monogram(for: label) : String(given.prefix(3)).uppercased())
        }

        let pending = entries.keys.sorted().filter { id in
            !route.contains(id) && !reserve.contains(id) && (entries[id] as? [String: Any])?["pendente"] as? Bool == true
        }
        let preferred = (root["preferida"] as? String).flatMap { route.contains($0) || reserve.contains($0) ? $0 : nil }
        let pinned = (root["fixada"] as? String).flatMap { route.contains($0) || reserve.contains($0) ? $0 : nil }

        return Config(
            enabled: root["ativo"] as? Bool ?? true,
            principal: principal,
            accounts: route.map { account($0, .route) } + reserve.map { account($0, .reserve) },
            reserveBelow: reserveBelow,
            preferred: preferred,
            comfortableFrom: comfortableFrom,
            pinned: pinned,
            principalUsesDefaultDirectory: ((entries[principal] as? [String: Any])?["dir"] as? String) == nil,
            pending: pending.filter { $0 != principal }.map { account($0, .pending) })
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
    /// `admitting` is a pending account entering the queue in this same write: it loses its `pendente` mark here, so
    /// it is never in the queue and still pending, nor out of it and no longer pending.
    static func saveQueue(route: [String], reserve: [String], strategy: Strategy, admitting: String? = nil,
                          at url: URL = configURL) throws {
        guard !route.isEmpty else { throw EmptyRoute() }
        try updateConfig(at: url) { root in
            root["rota"] = route
            root["reserva"] = reserve
            root["preferida"] = strategy == .order ? route[0] : nil
            if let admitting, var contas = root["contas"] as? [String: Any],
               var entry = contas[admitting] as? [String: Any] {
                entry.removeValue(forKey: "pendente")
                contas[admitting] = entry
                root["contas"] = contas
            }
        }
    }

    /// Chooses by hand where new sessions open (`fixada`), above the rule; nil goes back to the rule.
    static func setPinned(_ id: String?, at url: URL = configURL) throws {
        try updateConfig(at: url) { root in root["fixada"] = id }
    }

    static func setStrategy(_ strategy: Strategy, route: [String], at url: URL = configURL) throws {
        try updateConfig(at: url) { root in
            root["preferida"] = strategy == .order ? route.first : nil
        }
    }

    /// `onlyIfListed` leaves the config alone when `id` is no longer in it (not in `contas` and not the principal):
    /// a rename queued behind the account's removal must not bring back an orphan entry.
    static func renameAccount(_ id: String, name: String, monogram: String, onlyIfListed: Bool = false,
                              at url: URL = configURL) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sigla = String(monogram.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3)).uppercased()
        try updateConfig(at: url) { root in
            var contas = root["contas"] as? [String: Any] ?? [:]
            if onlyIfListed, contas[id] == nil, id != (root["principal"] as? String ?? "principal") { return }
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
    /// letters otherwise, and the part in parentheses when there is one ("Thomas (Max)" is "MA"). A number glued to the
    /// end of the name stays, so numbered twins differ ("squad.financeiro2" is "SF2").
    static func monogram(for label: String) -> String {
        let digits = String(label.reversed().prefix { $0.isNumber }.reversed())
        let stem = label.dropLast(digits.count)
        if !digits.isEmpty, let glued = stem.last, glued.isLetter {
            let letters = monogram(for: String(stem))
            return String(((digits.count > 1 ? String(letters.prefix(1)) : letters) + digits).prefix(3))
        }
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

    static func identity(for account: Account, config: Config? = nil) -> AccountIdentity? {
        guard !account.usesDefaultDirectory else {
            return (config ?? loadConfig()).map { slotIdentity(config: $0) } ?? ClaudeConfig.activeAccount()
        }
        return folderIdentity(account)
    }

    private static func folderIdentity(_ account: Account) -> AccountIdentity? {
        guard let data = try? Data(contentsOf: account.directory.appendingPathComponent(".claude.json")) else { return nil }
        return ClaudeConfig.parseActiveAccount(data)
    }

    static var savedLoginsDirectory: URL { home.appendingPathComponent(".estado/agentes") }

    /// The login the router saved for `id` when it moved that account in or out of `~/.claude`; nil when there is
    /// none, or the router marked it as no longer working.
    static func savedLogin(_ id: String, in dir: URL = savedLoginsDirectory) -> AccountIdentity? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["invalidoEm"] == nil
        else { return nil }
        return ClaudeConfig.parseActiveAccount(data)
    }

    /// Who is logged into `~/.claude`, the router's slot. `~/.claude.json` says it, but after the router moves
    /// another account into the slot (the agents' switch), a Claude Code session still open rewrites that file with
    /// the login it started with. The file then names an account that lives elsewhere in the queue, and the slot
    /// account showed up as a copy of it: "Thomas (Max)" read as "Thomas (Aegro)". When the file names another
    /// queue account and the router saved this slot account's own login, that saved login wins.
    /// With the principal in a folder of its own, `~/.claude` is nobody's slot and the file is taken as it is.
    static func slotIdentity(config: Config) -> AccountIdentity? {
        guard config.principalUsesDefaultDirectory else { return ClaudeConfig.activeAccount() }
        let others = config.accounts.filter { $0.id != config.principal }
        var otherKeys = Set(others.compactMap { folderIdentity($0)?.key })
        otherKeys.formUnion(others.compactMap { savedLogin($0.id)?.key })
        return resolveSlotIdentity(declared: ClaudeConfig.activeAccount(), saved: savedLogin(config.principal),
                                   otherKeys: otherKeys)
    }

    static func resolveSlotIdentity(declared: AccountIdentity?, saved: AccountIdentity?,
                                    otherKeys: Set<String>) -> AccountIdentity? {
        guard let declared, let saved, declared.key != saved.key, otherKeys.contains(declared.key) else { return declared }
        return saved
    }

    /// The queue account the agents of `claude agents` run on, read like the router's `contaNoSlot`: the login in
    /// `~/.claude.json` matched against the login the router saved for each account, then against each account's own
    /// folder. With no match, the principal while the router never saved its login, since it never left the slot.
    static func agentsAccount(config: Config, in dir: URL = savedLoginsDirectory) -> String? {
        let ids = config.accounts.map(\.id)
        return resolveAgentsAccount(
            declared: ClaudeConfig.activeAccount()?.key,
            accounts: ids,
            saved: Dictionary(uniqueKeysWithValues: ids.compactMap { id in savedLoginKey(id, in: dir).map { (id, $0) } }),
            folders: Dictionary(uniqueKeysWithValues: config.accounts.filter { !$0.usesDefaultDirectory }
                .compactMap { a in folderIdentity(a).map { (a.id, $0.key) } }),
            principal: config.principal)
    }

    static func resolveAgentsAccount(declared: String?, accounts: [String], saved: [String: String],
                                     folders: [String: String], principal: String) -> String? {
        if let declared {
            if let id = accounts.first(where: { saved[$0] == declared }) { return id }
            if let id = accounts.first(where: { folders[$0] == declared }) { return id }
        }
        return saved[principal] == nil && accounts.contains(principal) ? principal : nil
    }

    /// The `chave` the router saved for `id`, even on a login it marked as no longer working: it still names the account.
    static func savedLoginKey(_ id: String, in dir: URL = savedLoginsDirectory) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = root["chave"] as? String, !key.isEmpty
        else { return nil }
        return key
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

    /// The router's last renewal of an expired login, per account (`claude-accounts refresh`, also run by `_vigiar`).
    struct LoginRefresh: Equatable {
        enum Outcome: Equatable {
            case renewed
            /// A `claude` process runs with the account's folder: the CLI there renews it, and a second client is
            /// never started on the same login.
            case inUse
            case failed(String)
        }
        var at: Date
        var outcome: Outcome
    }

    static func refreshes() -> [String: LoginRefresh] {
        guard let data = try? Data(contentsOf: refreshesURL) else { return [:] }
        return parseRefreshes(data)
    }

    static func parseRefreshes(_ data: Data) -> [String: LoginRefresh] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: LoginRefresh] = [:]
        for (id, value) in root {
            guard let entry = value as? [String: Any], let ms = (entry["em"] as? NSNumber)?.doubleValue,
                  let kind = entry["resultado"] as? String
            else { continue }
            let outcome: LoginRefresh.Outcome
            switch kind {
            case "renovado": outcome = .renewed
            case "em-uso": outcome = .inUse
            default: outcome = .failed((entry["erro"] as? String) ?? kind)
            }
            result[id] = LoginRefresh(at: Date(timeIntervalSince1970: ms / 1000), outcome: outcome)
        }
        return result
    }

    static func exhausted(now: Date = Date()) -> [String: Date] {
        guard let data = try? Data(contentsOf: exhaustedURL) else { return [:] }
        return parseExhausted(data, now: now)
    }

    /// Why the router set each account aside (`motivo`), for the ones still set aside at `now`. A limit is not the only
    /// reason: the server refusing the login (`auth`), a billing error or a suspended account also set it aside for a
    /// while, and those do not come back at that time by themselves.
    static func exhaustedReasons(now: Date = Date()) -> [String: String] {
        guard let data = try? Data(contentsOf: exhaustedURL) else { return [:] }
        return parseExhaustedReasons(data, now: now)
    }

    /// The `motivo` of each entry of `esgotadas.json` whose `ate` is still after `now`, without the `agents ` prefix
    /// (as in `reasonText`), so a reason reads the same whoever set the account aside. Unreadable data is no reason.
    static func parseExhaustedReasons(_ data: Data, now: Date) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (id, value) in root {
            guard let entry = value as? [String: Any], let ms = (entry["ate"] as? NSNumber)?.doubleValue,
                  Date(timeIntervalSince1970: ms / 1000) > now, let reason = entry["motivo"] as? String
            else { continue }
            result[id] = reason.hasPrefix("agents ") ? String(reason.dropFirst("agents ".count)) : reason
        }
        return result
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

    /// The last `limit` readable lines of a JSONL file, newest first. A broken line is skipped without costing a
    /// slot, so a torn write at the end does not shorten the list.
    static func tail<T>(_ url: URL, limit: Int, _ parse: (Data) -> T?) -> [T] {
        guard limit > 0, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var found: [T] = []
        for line in text.split(separator: "\n").reversed() {
            guard let item = parse(Data(line.utf8)) else { continue }
            found.append(item)
            if found.count == limit { break }
        }
        return found
    }

    /// The latest switches, newest first.
    static func switches(limit: Int = 30) -> [Switch] {
        tail(switchesURL, limit: limit, parseSwitch)
    }

    /// The latest tasks run with `claude-accounts as`, newest first,
    /// with whether each unfinished one's parent is alive.
    static func oneShotTasks(limit: Int = 8, url: URL = oneShotTasksURL,
                             isAlive: (pid_t, Date) -> Bool = processAlive) -> [OneShotTask] {
        tail(url, limit: limit, parseOneShotTask).map { task in
            var task = task
            if task.exitCode == nil { task.parentAlive = task.pid.map { isAlive($0, task.at) } ?? false }
            return task
        }
    }

    /// One line of `.estado/acessos.jsonl` as a task; nil for a line without a time or an account (torn or foreign).
    static func parseOneShotTask(_ line: Data) -> OneShotTask? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ms = (root["em"] as? NSNumber)?.doubleValue,
              let account = root["conta"] as? String, !account.isEmpty
        else { return nil }
        return OneShotTask(id: root["id"] as? String ?? "\(Int64(ms))-\(account)",
                           at: Date(timeIntervalSince1970: ms / 1000),
                           from: root["de"] as? String,
                           account: account,
                           login: root["login"] as? String,
                           organization: root["organizacao"] as? String,
                           tools: root["ferramentas"] as? [String] ?? [],
                           request: (root["pedido"] as? String ?? "")
                               .split(whereSeparator: \.isWhitespace).joined(separator: " "),
                           exitCode: (root["codigo"] as? NSNumber)?.intValue)
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
        case "equilibrio": text = "pouca folga até renovar"
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
        /// Stopped by the time limit, or ended by a signal, rather than exiting on its own.
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
        // The time limit is kept by this thread, waiting for the exit with a deadline, not by a timer on a global
        // queue: on a busy machine (the 3-core CI runner) that timer fired seconds late and the command outlived
        // its limit.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return CommandResult(status: 127, output: "", error: error.localizedDescription)
        }
        let pid = process.processIdentifier
        // Set when the limit stops the command, whatever its exit looks like: one that catches SIGTERM and exits 0
        // still ran out of time, and its output is not an answer.
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // `isRunning` comes from the same exit notice as the handler, so it lags just as much: a command that
            // exited in time, with its notice still on the way, is not one that ran out of time.
            timedOut = process.isRunning && !hasExited(pid)
            if !timedOut {
                // Exited in time, with only the notice late: there is nothing to stop, and the kernel has already
                // sent the exit, so the notice comes. Bounded all the same, like every wait here; past it the
                // status is unknown and the command reads as stopped.
                if exited.wait(timeout: .now() + 30) == .timedOut {
                    let deadline = DispatchTime.now() + 2
                    return CommandResult(status: -1,
                                         output: String(decoding: output.finish(by: deadline), as: UTF8.self),
                                         error: String(decoding: errors.finish(by: deadline), as: UTF8.self),
                                         interrupted: true)
                }
            }
        }
        if timedOut {
            // Remembered, because once `pid` exits its children belong to launchd and can no longer be found
            // under it; whatever ignored SIGTERM gets SIGKILL with the parent.
            let children = terminateDescendants(of: pid)
            if process.isRunning { process.terminate() }
            let finish = {
                let late = process.isRunning ? terminateDescendants(of: pid, signal: SIGKILL) : []
                for child in children where !late.contains(child) && kill(child, 0) == 0 { kill(child, SIGKILL) }
                if process.isRunning { kill(pid, SIGKILL) }
            }
            if exited.wait(timeout: .now() + 2) == .timedOut {
                finish()
                // Not even SIGKILL ends a process stuck in uninterruptible I/O (a network volume), and its exit
                // notice may never come: the wait is bounded too, so the caller is not held for good. Past it the
                // command reads as stopped by the limit, without its status: read while Foundation believes the
                // process still runs, it raises an Objective-C exception, which Swift cannot catch and which
                // crashes the app.
                if exited.wait(timeout: .now() + 5) == .timedOut {
                    // It still holds both pipes, so no end of output is coming: only what is already on its way.
                    let deadline = DispatchTime.now() + 0.2
                    return CommandResult(status: -1,
                                         output: String(decoding: output.finish(by: deadline), as: UTF8.self),
                                         error: String(decoding: errors.finish(by: deadline), as: UTF8.self),
                                         interrupted: true)
                }
            } else if !children.isEmpty {
                reaper.asyncAfter(deadline: .now() + 2, execute: finish)
            }
        }
        // A helper the command left behind can keep the pipes open after it exits: the output gets a moment to
        // end, one moment for both pipes, and then it is whatever arrived.
        let deadline = DispatchTime.now() + 2
        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: output.finish(by: deadline), as: UTF8.self),
                             error: String(decoding: errors.finish(by: deadline), as: UTF8.self),
                             interrupted: timedOut || process.terminationReason == .uncaughtSignal)
    }

    /// Kills, two seconds on, the children of a timed-out command that ignored SIGTERM after the command itself
    /// exited. A serial queue of its own, which gets a thread even while the global queues are busy.
    private static let reaper = DispatchQueue(label: "monitor-claude.reaper", qos: .userInitiated)

    /// Whether `pid` has exited, reaped or not. Read from the kernel, not from Foundation's exit notice: an exited
    /// child no one has reaped yet is a zombie, which `proc_pidinfo` no longer finds (ESRCH) while `kill(pid, 0)`
    /// still does. Only for a child of this process, whose pid cannot be reused before it is reaped.
    static func hasExited(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == 0 && errno == ESRCH
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
        let fiveHour = snapshot.fiveHour
        let weeklyBinds = fiveHour == nil || used(snapshot.weekly, now: now) > used(fiveHour, now: now)
        guard let window = weeklyBinds ? snapshot.weekly : fiveHour,
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
        window?.asOf(now).utilization ?? 0
    }

    static func headroom(_ snapshot: UsageSnapshot, now: Date = Date()) -> Double {
        max(0, min(100, (100 - max(used(snapshot.session, now: now), used(snapshot.weekly, now: now))).rounded()))
    }

    static let hoursInWeek = 168.0

    /// How much of the week the account can spend per hour until it renews, in points per hour: what is left of the
    /// 7-day window over the hours until it resets (the router's `folgaPorHora`). 8% with two days to go is worth less
    /// than 90% with five (0.19 against 0.75 per hour), and 40% that renews in 10 h is worth more than 90% that renews
    /// in five days, since what is not spent by the reset is lost. A window already past its reset, or without a reset
    /// time, counts as a whole week; without a weekly window, the headroom spread over the week.
    static func perHour(_ snapshot: UsageSnapshot, now: Date = Date()) -> Double {
        guard let weekly = snapshot.weekly else { return headroom(snapshot, now: now) / hoursInWeek }
        let left = max(0, 100 - used(weekly, now: now))
        let hours = weekly.resetsAt.map { $0 > now ? $0.timeIntervalSince(now) / 3600 : hoursInWeek } ?? hoursInWeek
        return left / max(1, min(hoursInWeek, hours))
    }

    static func pick(_ config: Config, usage: [String: UsageSnapshot], available: Set<String>,
                     exhausted: [String: Date], now: Date = Date()) -> String? {
        pick(config, headroom: usage.mapValues { headroom($0, now: now) }, perHour: usage.mapValues { perHour($0, now: now) },
             available: available, exhausted: exhausted)
    }

    /// The router's `decidir`: the pinned account, then the preferred one, then the best of the route, and the reserve
    /// only when the route is out. Between two accounts, the comfortable one (headroom from `comfortableFrom`) comes
    /// first; comfortable ones compete by room per hour until the week renews, the others by headroom now, since they
    /// are close to a limit. Ties keep the queue order.
    /// The app calls `pick(_:usage:...)`; this form, with the numbers already worked out, is what the tests drive.
    static func pick(_ config: Config, headroom: [String: Double], perHour: [String: Double] = [:],
                     available: Set<String>, exhausted: [String: Date]) -> String? {
        let order = config.accounts.map(\.id)
        func score(_ id: String) -> Double { headroom[id] ?? 1 }
        func comfortable(_ id: String) -> Bool { headroom[id].map { $0 >= config.comfortableFrom } ?? false }
        func rate(_ id: String) -> Double { perHour[id] ?? score(id) / hoursInWeek }
        func before(_ a: (offset: Int, element: String), _ b: (offset: Int, element: String)) -> Bool {
            let (x, y) = (a.element, b.element)
            if comfortable(x) != comfortable(y) { return comfortable(x) }
            let difference = comfortable(x) ? rate(x) - rate(y) : score(x) - score(y)
            if abs(difference) > 1e-9 { return difference > 0 }
            return a.offset < b.offset
        }
        if let pinned = config.pinned, available.contains(pinned), exhausted[pinned] == nil, score(pinned) > 0 {
            return pinned
        }
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
                .min(by: before)?
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
    /// Why each of `exhausted` was set aside (`AccountRouter.exhaustedReasons`).
    var exhaustedReasons: [String: String] = [:]
    var agentsLogins: Set<String> = []
    /// The account the agents of `claude agents` run on now (`AccountRouter.agentsAccount`).
    var agentsAccount: String?
    var switches: [AccountRouter.Switch] = []
    /// The latest tasks run with `claude-accounts as` (`AccountRouter.oneShotTasks`).
    var oneShotTasks: [AccountRouter.OneShotTask] = []
    /// Accounts whose login exists but whose token expired: nobody ran a session on them for a while. The Monitor never
    /// renews a token itself; the router has the official CLI do it (`refreshes`). Their numbers stay as last read
    /// until then.
    var idleLogins: Set<String> = []
    var refreshes: [String: AccountRouter.LoginRefresh] = [:]
    /// Each account's plan from its own login (`Keychain.Credentials.plan`).
    var plans: [String: String] = [:]
    /// Accounts whose Keychain read waits for "Ler de novo": macOS asked to let it through and got no, or no answer.
    var keychainRefused: Set<String> = []

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

/// Collects what arrives on a pipe as it arrives. `finish(by:)` waits until that deadline for the end of the
/// output and returns what came, so a pipe someone else still holds open never blocks the caller for good. A
/// deadline rather than a duration, so the two pipes of one command share it instead of adding up.
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

    func finish(by deadline: DispatchTime) -> Data {
        _ = ended.wait(timeout: deadline)
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
