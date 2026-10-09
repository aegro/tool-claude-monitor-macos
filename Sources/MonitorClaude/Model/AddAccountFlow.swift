import Foundation
import AppKit

/// The "Adicionar conta" assistant: what used to be `claude-accounts add`, `login` and `login --agents` in a
/// terminal. The router stays the owner of every change; the assistant only runs its commands, captures the login
/// address so the person can choose the browser, and reads back who logged in before saving anything else.
@MainActor
final class AddAccountFlow: ObservableObject, Identifiable {
    enum Step: Equatable { case choose, authorize, connected, agents, place, done }

    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    struct Suggestion: Identifiable, Equatable {
        var id: String
        var label: String
        var plan: String?
        var detail: String
    }

    let id = UUID()
    @Published var step: Step = .choose
    @Published var phase: Phase = .idle
    @Published var suggestions: [Suggestion] = []
    @Published var name = ""
    @Published var monogram = ""
    @Published private(set) var accountId: String?
    @Published private(set) var identity: AccountIdentity?
    @Published private(set) var duplicateOf: String?
    @Published private(set) var loginURL: URL?
    /// The page that opened ends on a code to paste here (the manual sign-in): the automatic one never arrived.
    @Published private(set) var needsCode = false
    @Published var code = ""
    @Published private(set) var agentsAuthorized = false
    @Published var reserve = false
    @Published var enableSwitching = true
    @Published var incognito = false

    /// True when the flow re-authorizes an account that already exists: nothing is created or discarded.
    let existing: Bool
    let agentsRunning: Int
    private var created = false
    /// Set by `cancel()`; an `add` still running when the sheet closes removes its account when it returns.
    private var cancelled = false
    private var login: Process?
    private var input: FileHandle?
    private var urlFile: URL?
    private var manualURL: URL?
    private var startedAt = Date()
    private var poll: Timer?
    /// Bumped by every start and stop, so whatever a stopped login reports when it finally exits is ignored
    /// instead of landing on the attempt that replaced it.
    private var attempt = 0
    var onFinish: (() -> Void)?
    /// Replaces the browser, for tests: receives the address and whether a private window was asked for.
    var openHandler: ((URL, Bool) -> Void)?

    /// How long the assistant waits for the browser address (`BROWSER`) before it opens the manual page instead.
    static var manualAfter: TimeInterval = 5

    init(store: AccountStore, desktop: [DesktopOrgUsage], agentsRunning: Int = 0) {
        existing = false
        self.agentsRunning = agentsRunning
        suggestions = Self.suggestions(store: store, desktop: desktop, config: AccountRouter.loadConfig())
    }

    /// Re-authorizes `account` (its terminal login, or the agents login when `agents`).
    init(reauthorize account: AccountRouter.Account, agents: Bool, agentsRunning: Int = 0) {
        existing = true
        self.agentsRunning = agentsRunning
        accountId = account.id
        name = account.label
        monogram = account.monogram
        step = agents ? .agents : .authorize
    }

    // MARK: suggestions

    static func suggestions(store: AccountStore, desktop: [DesktopOrgUsage], config: AccountRouter.Config?) -> [Suggestion] {
        let known = Set((config?.accounts ?? []).compactMap { AccountRouter.identity(for: $0)?.key })
        let knownOrgs = Set((config?.accounts ?? []).compactMap { AccountRouter.identity(for: $0)?.organizationUuid })
        var out: [Suggestion] = []
        for record in store.records.values.sorted(by: { $0.lastSeen > $1.lastSeen }) where !known.contains(record.uuid) {
            out.append(Suggestion(id: record.uuid, label: record.label, plan: record.plan,
                                  detail: [record.plan?.capitalized, "usada neste Mac \(Fmt.ago(record.lastSeen))"]
                                    .compactMap { $0 }.joined(separator: " · ")))
        }
        for org in desktop where !knownOrgs.contains(org.organizationUuid)
            && !out.contains(where: { $0.id.hasSuffix(":" + org.organizationUuid) }) {
            out.append(Suggestion(id: "desktop:" + org.organizationUuid, label: org.label, plan: org.plan,
                                  detail: [org.plan?.capitalized, "vista no app do Claude"].compactMap { $0 }.joined(separator: " · ")))
        }
        return out
    }

    /// "Thomas" becomes "Thomas (Max)" when another account already starts with "Thomas".
    static func defaultName(label: String, plan: String?, taken: [String]) -> String {
        let clash = taken.contains { $0 == label || $0.hasPrefix(label + " ") || $0.hasPrefix(label + "(") }
        guard clash, let plan, !plan.isEmpty else { return label }
        return "\(label) (\(plan.prefix(1).uppercased())\(plan.dropFirst()))"
    }

    // MARK: steps

    func choose(_ suggestion: Suggestion?) async {
        // A double-click or a repeated Enter can call this again before the sheet disables its buttons; a second
        // `add` with the same id would fail and overwrite the phase of the one that worked.
        if case .working = phase { return }
        guard accountId == nil, !cancelled else { return }
        let config = AccountRouter.loadConfig()
        let taken = config?.accounts.map(\.label) ?? []
        let base = suggestion.map { Self.defaultName(label: $0.label, plan: $0.plan, taken: taken) } ?? "Nova conta"
        name = base
        monogram = AccountRouter.monogram(for: base)
        let id = AccountRouter.slug(for: base, taken: Set(config?.accounts.map(\.id) ?? []))
        phase = .working("Preparando a conta…")
        let result = await AccountRouter.runAccounts(["add", id, "--name", base])
        if cancelled {
            // The sheet closed while `add` ran: nobody will finish this account, so it does not stay behind.
            if result.ok { try? AccountRouter.discard(id) }
            return
        }
        guard result.ok else {
            phase = .failed(Self.firstLine(result.error) ?? "Não deu para criar a conta.")
            return
        }
        accountId = id
        created = true
        phase = .idle
        step = .authorize
    }

    func authorize(incognito: Bool) {
        self.incognito = incognito
        startLogin(agents: false)
    }

    func authorizeAgents(incognito: Bool) {
        self.incognito = incognito
        startLogin(agents: true)
    }

    func skipAgents() {
        agentsAuthorized = false
        step = existing ? .done : .place
        if existing { onFinish?() }
    }

    func confirmConnected() {
        step = agentsRunning > 0 || AccountRouter.loadConfig()?.hasExtraAccounts == true ? .agents : .place
    }

    func retryLogin() {
        duplicateOf = nil
        identity = nil
        step = .authorize
        phase = .idle
    }

    func finish() async {
        guard let id = accountId else { return }
        phase = .working("Salvando…")
        do {
            try AccountRouter.renameAccount(id, name: name, monogram: monogram)
            if let config = AccountRouter.loadConfig() {
                var route = config.route.map(\.id).filter { $0 != id }
                var reserveIds = config.reserve.map(\.id).filter { $0 != id }
                if reserve { reserveIds.append(id) } else { route.append(id) }
                if route.isEmpty, let first = reserveIds.first { route = [first]; reserveIds.removeFirst() }
                try AccountRouter.saveQueue(route: route, reserve: reserveIds, strategy: config.strategy)
            }
            if enableSwitching {
                if !AccountRouter.commandsInstalled, let bin = AccountRouter.bundledCommands {
                    try? AccountRouter.installCommands(from: bin)
                }
                try AccountRouter.setEnabled(true)
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        created = false
        phase = .idle
        step = .done
        onFinish?()
    }

    /// Stops a login in flight and, for an account this assistant created and never finished, removes it again:
    /// logged in or not, it is not in the queue the person asked for (a duplicate organization, say).
    func cancel() {
        cancelled = true
        stopLogin()
        if created, let id = accountId {
            try? AccountRouter.discard(id)
        }
        created = false
    }

    // MARK: login

    /// `claude auth login` makes two addresses. The one it hands to `BROWSER` returns to the login by itself (a
    /// local callback); the one it prints is the manual sign-in, whose page ends on a code to paste back. So the
    /// assistant opens the first, and falls back to the printed one, with a field for the code, only when the
    /// first never arrives.
    private func startLogin(agents: Bool) {
        guard let id = accountId, let command = AccountRouter.accountsCommand else {
            phase = .failed("claude-accounts não encontrado")
            return
        }
        stopLogin()
        let current = attempt
        loginURL = nil
        manualURL = nil
        needsCode = false
        code = ""
        duplicateOf = nil
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-claude-login-\(UUID().uuidString).txt")
        urlFile = file
        let process = Process()
        process.executableURL = command
        process.arguments = agents ? ["login", id, "--agents"] : ["login", id]
        var env = ProcessInfo.processInfo.environment
        if let opener = Self.browserCapture() {
            env["BROWSER"] = opener.path
            env["MONITOR_CLAUDE_URL_FILE"] = file.path
        }
        process.environment = env
        let stdin = Pipe()
        // A code typed after the login already ended must fail the write, not kill the Monitor with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = stdin
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let transcript = Transcript()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            let text = transcript.append(chunk)
            Task { @MainActor in self?.output(text, chunk: chunk, attempt: current) }
        }
        process.terminationHandler = { [weak self] p in
            output.fileHandleForReading.readabilityHandler = nil
            // The last lines, usually the reason it stopped, may still be in the pipe: read what is there now,
            // without waiting on a pipe something else might hold open.
            let fd = output.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let n = read(fd, &buffer, buffer.count)
                guard n > 0 else { break }
                _ = transcript.append(String(decoding: buffer[0..<n], as: UTF8.self))
            }
            let status = p.terminationStatus
            let text = transcript.text
            Task { @MainActor in self?.loginEnded(attempt: current, status: status, agents: agents, transcript: text) }
        }
        do {
            try process.run()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        login = process
        input = stdin.fileHandleForWriting
        startedAt = Date()
        phase = .working(agents ? "Esperando você autorizar os agentes…" : "Esperando você autorizar…")
        poll = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(attempt: current) }
        }
    }

    private func output(_ text: String, chunk: String, attempt current: Int) {
        guard current == attempt else { return }
        if manualURL == nil { manualURL = Self.loginURL(in: text) }
        if needsCode, chunk.contains("Invalid code") {
            phase = .failed("O código não veio inteiro. Copie de novo o código todo da página e cole aqui.")
        }
    }

    private func tick(attempt current: Int) {
        guard current == attempt, loginURL == nil else { return }
        if let file = urlFile, let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n"),
           let url = Self.loginURL(in: text) {
            open(url)
        } else if let manual = manualURL, Date().timeIntervalSince(startedAt) >= Self.manualAfter {
            needsCode = true
            open(manual)
        }
    }

    /// Sends the code the manual sign-in page shows (`code#state`) to the login waiting for it.
    func sendCode() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let input, login?.isRunning == true else { return }
        do {
            try input.write(contentsOf: Data((value + "\n").utf8))
            phase = .working("Conferindo o código…")
        } catch {
            phase = .failed("O login já tinha terminado. Comece de novo.")
        }
    }

    private func open(_ url: URL) {
        guard loginURL == nil else { return }
        loginURL = url
        if let openHandler {
            openHandler(url, incognito)
        } else if incognito, let chrome = Self.privateBrowser {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", chrome.app, "--args", chrome.flag, url.absoluteString]
            try? p.run()
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func reopenLogin() {
        guard let url = loginURL else { return }
        loginURL = nil
        open(url)
    }

    private func loginEnded(attempt ended: Int, status: Int32, agents: Bool, transcript: String) {
        guard ended == attempt else { return }
        poll?.invalidate()
        poll = nil
        login = nil
        input = nil
        needsCode = false
        if let file = urlFile { try? FileManager.default.removeItem(at: file) }
        urlFile = nil
        guard status == 0 else {
            if status == 15 || status == 143 { phase = .idle; return }
            phase = .failed(Self.failureLine(transcript).map { "O login não terminou: \($0)" } ?? "O login não terminou.")
            return
        }
        phase = .idle
        guard let id = accountId, let account = AccountRouter.loadConfig()?.accounts.first(where: { $0.id == id }) else {
            phase = .failed("A conta sumiu da config durante o login.")
            return
        }
        if agents {
            agentsAuthorized = AccountRouter.hasAgentsLogin(id)
            guard agentsAuthorized else {
                phase = .failed("O login dos agentes não ficou guardado. Tente de novo.")
                return
            }
            step = existing ? .done : .place
            if existing { onFinish?() }
            return
        }
        guard let who = AccountRouter.identity(for: account) else {
            phase = .failed("O login terminou, mas a conta não apareceu. Tente de novo.")
            return
        }
        identity = who
        let others = AccountRouter.loadConfig()?.accounts.filter { $0.id != id } ?? []
        duplicateOf = others.first { AccountRouter.identity(for: $0)?.key == who.key }?.label
        step = existing && duplicateOf == nil ? .done : .connected
        if existing && duplicateOf == nil { onFinish?() }
    }

    /// The router ignores Ctrl-C and runs `claude auth login` as its child: ending only the router would leave the
    /// login, and its local callback, running. So the login goes first, which lets the router clean up and exit on
    /// its own; the router is ended too if it is still there a moment later.
    private func stopLogin() {
        attempt += 1
        poll?.invalidate()
        poll = nil
        if let login, login.isRunning {
            AccountRouter.terminateDescendants(of: login.processIdentifier)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if login.isRunning { login.terminate() } }
        }
        login = nil
        input = nil
        if let file = urlFile { try? FileManager.default.removeItem(at: file) }
        urlFile = nil
    }

    // MARK: helpers

    /// The first sign-in address in `text`, only on Anthropic's hosts (`claude.com`, `claude.ai`, `anthropic.com`).
    static func loginURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https://[^\s"'<>\x{1b}\x{07}]+"#, options: .regularExpression) else { return nil }
        var raw = String(text[range])
        while let last = raw.last, ".,;)]".contains(last) { raw.removeLast() }
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(),
              ["claude.com", "claude.ai", "anthropic.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }
        return url
    }

    /// The line that says why the login stopped: escapes and the login's own prompts left out.
    static func failureLine(_ transcript: String) -> String? {
        let clean = transcript
            .replacingOccurrences(of: #"\x{1b}\][^\x{07}\x{1b}]*(\x{07}|\x{1b}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1b}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "Paste code here if prompted >", with: "")
        return clean.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Opening browser") && !$0.hasPrefix("If the browser didn't open") }
            .last
            .map { $0.replacingOccurrences(of: "claude-accounts: ", with: "") }
    }

    static var privateBrowser: (app: String, flag: String)? {
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Applications/Google Chrome.app") { return ("Google Chrome", "--incognito") }
        if fm.fileExists(atPath: "/Applications/Firefox.app") { return ("Firefox", "--private-window") }
        if fm.fileExists(atPath: "/Applications/Brave Browser.app") { return ("Brave Browser", "--incognito") }
        return nil
    }

    /// A tiny `BROWSER` that writes the address to a file instead of opening it, so the person picks the window.
    /// It lives in the per-user temporary folder, which only this user can read.
    static func browserCapture() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-claude", isDirectory: true)
        let script = dir.appendingPathComponent("capturar-login.sh")
        // Written aside and renamed into place, so the assistant never reads half an address.
        let body = """
        #!/bin/sh
        [ -n "$MONITOR_CLAUDE_URL_FILE" ] || exit 0
        printf '%s\\n' "$1" > "$MONITOR_CLAUDE_URL_FILE.tmp" && /bin/mv -f "$MONITOR_CLAUDE_URL_FILE.tmp" "$MONITOR_CLAUDE_URL_FILE"
        exit 0

        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: script, encoding: .utf8)) != body {
                try Data(body.utf8).write(to: script, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            return script
        } catch {
            return nil
        }
    }

    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "claude-accounts: ", with: "") }
    }
}

/// What the login command printed so far, shared between the pipe's reader and the end of the process.
final class Transcript: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        buffer += chunk
        if buffer.count > 64_000 { buffer = String(buffer.suffix(32_000)) }
        return buffer
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

extension AccountRouter {
    /// Removes an account from the queue: its config entry and its folder. A folder that never got a login holds
    /// only the router's links, so it goes; one with a login goes to the Trash instead, and its Keychain item stays
    /// (the Monitor never writes the Keychain), so putting the folder back brings the account back. The account in
    /// `~/.claude` is not removed, and the route never ends up empty: the first reserve account moves up.
    static func discard(_ id: String) throws {
        guard let config = loadConfig(), let account = config.accounts.first(where: { $0.id == id }),
              !account.usesDefaultDirectory, id != config.principal
        else { return }
        try updateConfig(at: configURL) { root in
            var contas = root["contas"] as? [String: Any] ?? [:]
            contas.removeValue(forKey: id)
            root["contas"] = contas
            var route = (root["rota"] as? [String] ?? []).filter { $0 != id }
            var reserve = (root["reserva"] as? [String] ?? []).filter { $0 != id }
            if route.isEmpty, !reserve.isEmpty { route = [reserve.removeFirst()] }
            root["rota"] = route
            root["reserva"] = reserve
            if root["preferida"] as? String == id { root["preferida"] = nil }
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: account.directory.path) else { return }
        if identity(for: account) == nil {
            try? fm.removeItem(at: account.directory)
        } else {
            try? fm.trashItem(at: account.directory, resultingItemURL: nil)
        }
    }
}

extension AddAccountFlow {
    /// The assistant at `step` with a sample account, for `--preview=wizard:<step>` screenshots. Nothing runs.
    static func preview(step: Step, store: AccountStore) -> AddAccountFlow {
        let flow = AddAccountFlow(store: store, desktop: [], agentsRunning: 7)
        if flow.suggestions.isEmpty {
            flow.suggestions = [
                Suggestion(id: "exemplo:max", label: "Thomas", plan: "max", detail: "Max · usada neste Mac há 2h"),
                Suggestion(id: "exemplo:sc", label: "Squad Compare", plan: "max", detail: "Max · vista no app do Claude"),
            ]
        }
        flow.name = "Thomas (Max)"
        flow.monogram = "MA"
        flow.accountId = "exemplo"
        flow.step = step
        if step == .authorize { flow.phase = .working("Esperando você autorizar…") }
        if step == .connected || step == .agents || step == .place || step == .done {
            flow.identity = AccountIdentity(accountUuid: "exemplo", organizationUuid: "org",
                                            email: "thomas@aegro.com.br",
                                            organizationName: "thomas@aegro.com.br's Organization",
                                            displayName: "Thomas", organizationType: "claude_max")
        }
        return flow
    }
}
