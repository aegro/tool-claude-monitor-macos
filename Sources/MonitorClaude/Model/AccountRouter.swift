import Foundation
import CryptoKit

/// Read side of the claude-auto account router bundled in `Contents/Resources/router`. The router
/// owns `~/.claude-accounts`; the Monitor reads it and flips one key, `ativo`, in its config.
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
        let route = ((root["rota"] as? [String]) ?? [principal]).filter(known.contains)
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

        return Config(
            enabled: root["ativo"] as? Bool ?? true,
            principal: principal,
            accounts: (route.isEmpty ? [principal] : route).map { account($0, .route) } + reserve.map { account($0, .reserve) },
            reserveBelow: reserveBelow)
    }

    static func setEnabled(_ enabled: Bool, at url: URL = configURL) throws {
        var root = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        root["ativo"] = enabled
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
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

    /// Through `/usr/bin/security`, the reader the CLI's own keychain items already trust, so an
    /// extra account never raises a new keychain prompt for the Monitor.
    static func credentials(for account: Account) -> Keychain.Credentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService(for: account), "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
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

    static func headroom(_ snapshot: UsageSnapshot, now: Date = Date()) -> Double {
        func used(_ window: LimitWindow?) -> Double {
            guard let window else { return 0 }
            if let reset = window.resetsAt, reset <= now { return 0 }
            return window.utilization
        }
        return max(0, min(100, (100 - max(used(snapshot.session), used(snapshot.weekly))).rounded()))
    }

    /// Mirrors `decidir` in router/lib/contas.js: most headroom on the route wins, the reserve
    /// only when every route account is below `reserveBelow`, ties go to config order.
    static func pick(_ config: Config, headroom: [String: Double], available: Set<String>,
                     exhausted: [String: Date]) -> String? {
        let order = config.accounts.map(\.id)
        func score(_ id: String) -> Double { headroom[id] ?? 1 }
        func best(_ role: Account.Role) -> String? {
            order
                .filter { id in
                    config.accounts.first { $0.id == id }?.role == role
                        && available.contains(id) && exhausted[id] == nil
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

/// What the panel and the settings need from the router after each poll.
struct RouterState: Equatable {
    var config: AccountRouter.Config
    var pick: String?
    /// `AccountIdentity.key` of each router account that has one, so a panel row can be matched.
    var keys: [String: String]
    var headroom: [String: Double]
    var lastSwitch: AccountRouter.Switch?
    var logins: [String: AccountIdentity] = [:]

    /// Router entries logged into the same account, which makes switching between them a no-op.
    var sharedLogins: [[String]] {
        let ids = config.accounts.map(\.id).filter { logins[$0] != nil }
        return Dictionary(grouping: ids) { logins[$0]!.key }
            .values.filter { $0.count > 1 }
            .sorted { $0[0] < $1[0] }
    }

    var pickKey: String? {
        guard let pick else { return nil }
        return keys.first { $0.value == pick }?.key
    }

    func isRouted(_ key: String?) -> Bool { key != nil && key == pickKey }
    func isRouterAccount(_ key: String) -> Bool { keys[key] != nil }
}
