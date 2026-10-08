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
    }

    struct Config: Equatable {
        var enabled: Bool
        var principal: String
        var accounts: [Account]
        var reserveBelow: Double
        var preferred: String?

        var hasExtraAccounts: Bool { accounts.contains { !$0.usesDefaultDirectory } }
    }

    struct Switch: Equatable {
        var at: Date
        var from: String
        var to: String
        var reason: String
    }

    static let commandNames = ["claude-auto", "claude-accounts"]

    static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-accounts")
    }
    static var configURL: URL { home.appendingPathComponent("config.json") }
    static var switchesURL: URL { home.appendingPathComponent(".estado/trocas.jsonl") }
    static var exhaustedURL: URL { home.appendingPathComponent(".estado/esgotadas.json") }
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

    static func parseConfig(_ data: Data, home: URL, defaultDirectory: URL) -> Config? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let principal = root["principal"] as? String ?? "principal"
        let entries = root["contas"] as? [String: Any] ?? [:]
        let known = Set(entries.keys).union([principal])
        let listedRoute = ((root["rota"] as? [String]) ?? []).filter(known.contains)
        let route = listedRoute.isEmpty ? [principal] : listedRoute
        let reserve = ((root["reserva"] as? [String]) ?? []).filter { known.contains($0) && !route.contains($0) }
        let reserveBelow = ((root["limites"] as? [String: Any])?["reserva"] as? NSNumber)?.doubleValue ?? 3

        func account(_ id: String, _ role: Account.Role) -> Account {
            let entry = entries[id] as? [String: Any] ?? [:]
            let custom = (entry["dir"] as? String).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            let usesDefault = id == principal && custom == nil
            return Account(
                id: id,
                label: entry["nome"] as? String ?? id,
                directory: custom ?? (usesDefault ? defaultDirectory : home.appendingPathComponent(id)),
                usesDefaultDirectory: usesDefault,
                role: role)
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
            "o arquivo não é um JSON válido; corrija ou apague antes de mudar a troca de conta"
        }
    }

    static func setEnabled(_ enabled: Bool, at url: URL = configURL) throws {
        try updateConfig(at: url) { $0["ativo"] = enabled }
    }

    static func setPreferred(_ id: String?, at url: URL = configURL) throws {
        try updateConfig(at: url) { $0["preferida"] = id }
    }

    struct ConfigBusy: LocalizedError {
        var errorDescription: String? {
            "outro processo está mudando a config agora; tente de novo"
        }
    }

    private static func updateConfig(at url: URL, _ change: (inout [String: Any]) -> Void) throws {
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
        defer { releaseFileLock(lock, owner: owner) }
        return try body()
    }

    private static func releaseFileLock(_ lock: String, owner: UInt64?) {
        guard inode(of: lock) == owner else { return }
        if rmdir(lock) == 0 { return }
        guard errno == ENOTEMPTY || errno == EEXIST else { return }
        rmdir(lock + "/tomada")
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService(for: account), "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        stop.cancel()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return try? Keychain.parse(root)
    }

    // MARK: state

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

    static func parseSwitch(_ line: Data) -> Switch? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ms = (root["em"] as? NSNumber)?.doubleValue,
              let from = root["de"] as? String,
              let to = root["para"] as? String
        else { return nil }
        return Switch(at: Date(timeIntervalSince1970: ms / 1000), from: from, to: to,
                      reason: root["motivo"] as? String ?? "")
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

struct RouterState: Equatable {
    var config: AccountRouter.Config
    var pick: String?
    var usage: [String: UsageSnapshot]
    var lastSwitch: AccountRouter.Switch?
    var logins: [String: AccountIdentity] = [:]
    var read: Set<String> = []
    var available: Set<String> = []

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
