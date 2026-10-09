import Foundation
import SwiftUI
import AppKit
import Combine

/// Everything the panel renders, refreshed on three independent cadences:
/// processes fast (they change constantly), the ledger medium, the API slow (it is
/// rate-limited server-side and every extra terminal is another client hammering it).
@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var system = SystemStats()
    @Published private(set) var cpuTrail: [Double] = []
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var attribution = Attribution()

    @Published private(set) var usage: UsageSnapshot?
    @Published private(set) var usageError: String?
    @Published private(set) var loadingUsage = false
    @Published private(set) var ledger = LedgerSnapshot()

    /// What each of the two feeds is doing, drawn as the provenance bar. Kept separate from
    /// `usage` because the panel has to be able to say "these numbers are live, and by the way the
    /// terminal login is dead" — the state that used to be invisible.
    @Published private(set) var feeds = FeedState()

    /// The organization whose numbers `usage` currently holds. Not always the terminal identity:
    /// once the terminal token dies the live detail belongs to whichever organization the desktop
    /// app is driving, which can be a different one entirely.
    @Published private(set) var liveOrg: String?

    /// The health of the feed that produced the numbers currently on screen. The panel and the
    /// menu bar both read this instead of assuming "there is a snapshot, therefore it is live":
    /// that assumption is exactly what let a frozen feed keep its lit dot for twenty-one hours.
    @Published private(set) var liveHealth: FeedState.Health = .missing

    /// Whether what is on screen is current. The one question every "is this live?" decision in
    /// the UI should ask.
    var liveIsCurrent: Bool {
        if case .live = liveHealth { return true }
        return false
    }

    /// When the numbers on screen were true, for the places that must show their age.
    var liveSeenAt: Date? {
        switch liveHealth {
        case .live(let at), .stale(let at): return at
        case .broken, .missing: return usage?.fetchedAt
        }
    }

    /// The last thing the API gave us this run. Outlives a failed poll so the windows the desktop
    /// feed cannot carry can still be drawn as ghosts, and so the weekly reset keeps its anchor.
    private var apiSnapshot: UsageSnapshot?
    private var apiSnapshotOrg: String?

    /// The account Claude Code has active right now (from ~/.claude.json). Drives the multi-account
    /// view; nil means we could not read an identity, so the panel shows the single-account layout.
    @Published private(set) var activeAccount: AccountIdentity?
    /// Organizations read from the desktop app's own usage history, refreshed on the slow tick.
    @Published private(set) var desktopOrgs: [DesktopOrgUsage] = []
    @Published private(set) var router: RouterState?
    let accounts = AccountStore()

    /// What needs renewing: connectors in use asking for a login, accounts without one, versions behind, and the
    /// access checks of the readiness panel when it runs here.
    @Published private(set) var access = AccessReport()
    @Published private(set) var integrations = IntegrationsState()
    /// The add-account assistant on screen, if any (shown in the settings window).
    @Published var accountFlow: AddAccountFlow?
    @Published var settingsTab: SettingsTab = .general
    /// The router's config exists but does not read (not JSON): the queue cannot be shown until it is fixed.
    @Published private(set) var routerConfigProblem: String?
    @Published var actionError: String?
    @Published private(set) var runningAction: String?

    @Published var panelOpen = false { didSet { retime() } }

    let history = UsageHistory()

    nonisolated(unsafe) private let sysSampler = SystemSampler()
    nonisolated(unsafe) private let procSampler = ProcessSampler()
    nonisolated(unsafe) private let ledgerScanner = TokenLedger()
    private let usageScanner = MCPUsageScanner()
    private var recentConnectorUse: [String: Date] = [:]
    private var outdatedCasks: [Versions.Outdated] = []
    private var lastAccessCheck: Date?
    private var lastConnectorScan: Date?
    private var lastVersionCheck: Date?
    private var checkingAccess = false
    private var sessionDirectories: [(id: String?, directory: URL)] = []
    private let queue = DispatchQueue(label: "farol.sampler", qos: .utility)
    private let ledgerQueue = DispatchQueue(label: "farol.ledger", qos: .utility)

    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var lastUsageFetch: Date?
    private var lastAgentsWatch: Date?
    private var watchingAgents = false
    private var lastLedgerScan: Date?
    private var sampling = false
    private var cachedCreds: Keychain.Credentials?
    private var lastAccountKey: String?
    private var cancellables: Set<AnyCancellable> = []

    private var usageInterval: TimeInterval { Settings.shared.usageIntervalSeconds }
    /// Extra accounts the server asked us to stop asking about for a while (HTTP 429), and until when.
    private var probePausedUntil: [String: Date] = [:]
    /// The live read waits until then after a 429: the server's own `Retry-After`, or a wait that doubles while the
    /// 429s keep coming. Asking again inside that window only extends it.
    private(set) var livePausedUntil: Date?
    private var liveBackoff: TimeInterval = 0
    /// Until when the live read waits, whoever asked (this Monitor's 429 or the router's), for the panel to say.
    @Published private(set) var livePauseShown: Date?
    /// The whole `/usage` read on its own, for the settings: the panel's health (`feeds.terminal`) turns live with the
    /// stream's numbers, while this says when the whole read last answered, or why it does not.
    @Published private(set) var fullReadHealth: FeedState.Health = .missing
    @Published private(set) var fullReadProblem: String?
    /// When `/usage` last answered for the login in `~/.claude`, and for each extra account. The live numbers carry
    /// only the session and the weekly window, so a whole read still runs every `fullReadInterval` for the
    /// per-model windows and the extra credit.
    private var lastFullRead: Date?
    /// When a whole read was last tried, answered or not: a failing one waits the same ten minutes while live numbers
    /// arrive, instead of being retried (and spending the endpoint) on every poll.
    private var lastFullAttempt: Date?
    /// What the last whole read failed with; nil after a success, and after a 429, which the pause already says.
    private var lastFullFailure: Error?
    /// When `/usage` last answered for each extra login, by its key.
    private var lastProbe: [String: Date] = [:]
    private var fullReadInterval: TimeInterval { TerminalPlan.fullReadInterval(usageInterval) }
    /// After a Keychain read failed in a way a retry would not fix soon, that item waits until then; after the
    /// person refused the prompt or left it unanswered, until they click "Ler de novo". Asking on every poll is what
    /// turned one dialog into one every two minutes. Keyed by the item's service name.
    private var keychainRetryAt: [String: Date] = [:]
    private var keychainRefusal: [String: Keychain.Failure] = [:]
    /// The last login read for each extra account, standing in while its Keychain read waits.
    private var routerCreds: [String: Keychain.Credentials] = [:]
    /// A router edit is being written; the next one waits for it instead of racing it.
    @Published private(set) var savingRouter = false
    /// The last router edit queued, which the next one waits on, and how many are still to finish.
    private var routerSaveTail: Task<Void, Never>?
    private var pendingRouterSaves = 0
    /// What the terminal feed last failed with, typed, so the access check does not read error text.
    private var terminalFailure: Error?
    private let ledgerInterval: TimeInterval = 20

    init() {
        // AccountStore is a nested ObservableObject; SwiftUI does not observe it through Monitor
        // automatically. Forward its change notifications so the panel re-renders when an
        // account's cached usage updates, instead of relying on some other @Published property
        // happening to change in the same turn.
        accounts.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        retime()
        tickFast()
        Task {
            await refreshUsage(force: true)
            await scanLedger()
        }
    }

    // MARK: cadence

    private func retime() {
        fastTimer?.invalidate()
        slowTimer?.invalidate()

        let fast = panelOpen ? 1.5 : 5.0

        // .common, not .default: while the panel is open the main run loop switches to
        // event-tracking mode and a default-mode timer simply stops firing, freezing the
        // whole panel exactly when it is being looked at.
        let f = Timer(timeInterval: fast, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickFast() }
        }
        let s = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickSlow() }
        }
        RunLoop.main.add(f, forMode: .common)
        RunLoop.main.add(s, forMode: .common)
        fastTimer = f
        slowTimer = s
    }

    private func tickFast() {
        guard !sampling else { return }
        sampling = true

        queue.async { [weak self] in
            guard let self else { return }
            let sys = self.sysSampler.sample()
            let procs = self.procSampler.sample()
            Task { @MainActor in
                self.apply(system: sys, procs: procs)
                self.sampling = false
            }
        }
    }

    private func tickSlow() async {
        if lastLedgerScan.map({ Date().timeIntervalSince($0) >= ledgerInterval }) ?? true {
            await scanLedger()
        }
        if lastUsageFetch.map({ Date().timeIntervalSince($0) >= usageInterval }) ?? true {
            await refreshUsage(force: false)
        }
        watchAgentsIfDue()
        await refreshAccessIfDue()
        history.flush()
    }

    // MARK: access

    /// Every 15 minutes, or sooner when the panel opens on stale data. The transcript scan runs at most every
    /// 30 minutes (and only reads what the transcripts grew since), Homebrew at most every 6 hours.
    func refreshAccessIfDue(force: Bool = false) async {
        let due = force || (lastAccessCheck.map { Date().timeIntervalSince($0) >= (panelOpen ? 300 : 900) } ?? true)
        guard due, !checkingAccess else { return }
        checkingAccess = true
        defer { checkingAccess = false }
        lastAccessCheck = Date()

        let dirs = sessionDirectories.map(\.directory)
        let projects = ClaudeSessionStore.root.appendingPathComponent("projects")
        if force || (lastConnectorScan.map { Date().timeIntervalSince($0) >= 1800 } ?? true) {
            lastConnectorScan = Date()
            let scanner = usageScanner
            recentConnectorUse = await withCheckedContinuation { cont in
                ledgerQueue.async { cont.resume(returning: scanner.scan(root: projects)) }
            }
        }
        if force || (lastVersionCheck.map { Date().timeIntervalSince($0) >= 6 * 3600 } ?? true) {
            lastVersionCheck = Date()
            outdatedCasks = await Blocking.run { Versions.outdated() }
        }
        let marks = MCPAuthCache.read(directories: dirs.isEmpty ? [ClaudeSessionStore.root] : dirs)
        let readiness = Readiness.read()
        let installed = Readiness.installedScript != nil
        let bgSessions = sessions.filter(\.isBackground).count
        var accountInputs: [AccessBuilder.Account] = []
        if let router, router.config.hasExtraAccounts {
            for account in router.config.accounts {
                let isSlot = account.id == router.config.principal
                accountInputs.append(.init(
                    id: account.id, label: account.label,
                    hasLogin: router.available.contains(account.id),
                    agentsLoginWorks: (bgSessions > 0 && !isSlot) ? router.agentsLogins.contains(account.id) : nil,
                    keychainRefused: router.keychainRefused.contains(account.id)))
            }
        }
        access = AccessBuilder.build(.init(
            claudeLoginProblem: claudeLoginProblem,
            claudeLoginRetry: keychainRefusal[Keychain.service]?.waitsForPerson == true,
            routerConfigProblem: routerConfigProblem,
            accounts: accountInputs,
            marks: marks,
            recentUse: recentConnectorUse,
            outdated: outdatedCasks,
            readiness: readiness,
            readinessInstalled: installed))
        integrations = IntegrationsState.read()
    }

    /// The terminal login problem in words: the Keychain has no usable login, or the server refused the token. A
    /// prompt the person refused shows even while live numbers arrive, since only "Ler de novo" asks again.
    private var claudeLoginProblem: String? {
        if let refusal = keychainRefusal[Keychain.service], refusal.waitsForPerson { return refusal.errorDescription }
        guard case .broken = feeds.terminal, let error = terminalFailure else { return nil }
        switch error {
        case let failure as Keychain.Failure: return failure.errorDescription
        case UsageError.unauthorized: return UsageError.unauthorized.errorDescription
        default: return nil
        }
    }

    func watchAgentsNow() {
        lastAgentsWatch = nil
        watchAgentsIfDue()
    }

    /// A preview window (and a `--render` screenshot) shares the real accounts folder with the running app: it must
    /// not switch agents or publish the burn rate, or two Monitors would drive the same router.
    static let readOnly = isReadOnly(arguments: CommandLine.arguments,
                                     environment: ProcessInfo.processInfo.environment)

    nonisolated static func isReadOnly(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains { $0 == "--preview" || $0.hasPrefix("--preview=") || $0.hasPrefix("--render=") }
            || environment["MONITOR_CLAUDE_READ_ONLY"] == "1"
    }

    private func watchAgentsIfDue() {
        guard !Self.readOnly, router?.config.enabled == true, !watchingAgents,
              lastAgentsWatch.map({ Date().timeIntervalSince($0) >= 30 }) ?? true
        else { return }
        lastAgentsWatch = Date()
        watchingAgents = true
        publishSlotBurnRate()
        // On a GCD thread, not the cooperative pool: the router's check can take a while.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            AccountRouter.watchAgents()
            Task { @MainActor in self?.finishAgentsWatch() }
        }
    }

    private func publishSlotBurnRate() {
        guard liveIsCurrent, let identity = activeAccount, let snapshot = usage,
              snapshot.source == .api, liveOrg == identity.organizationUuid,
              let rate = AccountRouter.slotBurnRate(
                  account: identity.key, snapshot: snapshot,
                  session: history.burnRate(\.session, account: identity.key, org: liveOrg),
                  weekly: history.burnRate(\.weekly, account: identity.key, org: liveOrg,
                                           window: 6 * 3600, minPoints: 8, minSpan: 3600))
        else {
            AccountRouter.withdrawSlotBurnRate()
            return
        }
        try? AccountRouter.publish(rate)
    }

    private func finishAgentsWatch() {
        watchingAgents = false
        if lastAgentsWatch == nil { watchAgentsIfDue() }
    }

    var blockStart: Date {
        // Anthropic's window is rolling; resets_at is the only honest anchor we have.
        // Without it, fall back to the community convention (5h back from now).
        usage?.session?.startsAt ?? Date().addingTimeInterval(-5 * 3600)
    }

    private func scanLedger() async {
        let start = blockStart
        lastLedgerScan = Date()
        let snap: LedgerSnapshot = await withCheckedContinuation { cont in
            ledgerQueue.async { [ledgerScanner] in
                cont.resume(returning: ledgerScanner.scan(blockStart: start))
            }
        }
        ledger = snap
    }

    /// "Ler de novo" and the refresh button: asks the Keychain again even after a refused prompt, then reads.
    func readAgain() async {
        // A read already running (one waiting on a dialog, say) finishes first: clearing the refusals under it would
        // let it write its answer back, and the click would do nothing.
        for _ in 0..<400 where loadingUsage { try? await Task.sleep(nanoseconds: 200_000_000) }
        let refused = !keychainRefusal.isEmpty
        keychainRetryAt = [:]
        keychainRefusal = [:]
        await refreshUsage(force: true)
        // The refusal was on the Acesso list; it leaves now instead of at the next check.
        if refused { await refreshAccessIfDue(force: true) }
    }

    func refreshUsage(force: Bool) async {
        if !force, let last = lastUsageFetch, Date().timeIntervalSince(last) < 30 { return }
        guard !loadingUsage else { return }
        loadingUsage = true
        defer { loadingUsage = false }
        lastUsageFetch = Date()

        // Read the active identity first: if Claude Code switched accounts since our last poll
        // — including a *logout*, where the identity goes to nil — the token we cached and the
        // usage/error on screen all belong to the old account. Drop the cached token so we
        // re-read the keychain (and correctly surface `.noAccountToken` after a logout), and
        // clear the stale usage so the new account starts from a clean "loading" state instead
        // of showing the previous account's numbers under the new account's name.
        // Two small JSON files off the same cadence as the API poll, so a desktop-side switch
        // shows up on the next refresh instead of only at relaunch.
        // One read, two consumers. Reading the file twice was not just wasteful: the desktop app
        // rewrites it every five minutes, so two reads could disagree, and a miss on the first
        // left the panel labelling one organization's numbers with another account's name.
        let desktopSeries = ClaudeDesktop.samplesByOrg()
        desktopOrgs = ClaudeDesktop.summarize(desktopSeries)

        // The router's view of `~/.claude` when there is one: the file alone can name the wrong account right after
        // the agents' switch (see `slotIdentity`).
        let identity = AccountRouter.loadConfig().map { AccountRouter.slotIdentity(config: $0) } ?? ClaudeConfig.activeAccount()
        if identity?.key != lastAccountKey {
            cachedCreds = nil
            usage = nil
            usageError = nil
            apiSnapshot = nil
            apiSnapshotOrg = nil
            // The whole read was of the other login: this one gets its own now, not in ten minutes.
            lastFullRead = nil
            lastFullAttempt = nil
            lastFullFailure = nil
            lastAccountKey = identity?.key
        }
        activeAccount = identity
        if apiSnapshot == nil, let id = identity, let stored = accounts.records[id.key]?.snapshot {
            apiSnapshot = stored
            apiSnapshotOrg = id.organizationUuid
        }

        // One read of each router file per refresh, shared by both polls, so they never disagree on the numbers.
        let live = AccountRouter.liveLimits()
        let readings = AccountRouter.routerReadings()
        await pollTerminalFeed(identity: identity, live: live, readings: readings)
        applyFeeds(desktopSeries)
        await pollRouterAccounts(active: identity, live: live, readings: readings)
        sessionDirectories = (router?.config.accounts ?? []).map { (id: Optional($0.id), directory: $0.directory) }
    }

    private func pollRouterAccounts(active: AccountIdentity?, live: [String: AccountRouter.LiveLimits],
                                    readings: [String: AccountRouter.RouterReading]) async {
        guard let config = AccountRouter.loadConfig(), config.hasExtraAccounts else {
            routerConfigProblem = AccountRouter.configProblem
            router = nil
            return
        }
        routerConfigProblem = nil
        var usage: [String: UsageSnapshot] = [:]
        var available: Set<String> = []
        var logins: [String: AccountIdentity] = [:]
        var read: Set<String> = []
        var idle: Set<String> = []
        let now = Date()
        func freshest(_ candidates: UsageSnapshot?...) -> UsageSnapshot? {
            candidates.compactMap { $0 }.max { $0.fetchedAt < $1.fetchedAt }
        }
        func recent(_ date: Date?, within interval: TimeInterval) -> Bool {
            date.map { now.timeIntervalSince($0) < interval } ?? false
        }

        // Every login at once: a Keychain read waiting on a dialog holds only its own account, not the queue.
        let credsById: [String: Keychain.Credentials] = await withTaskGroup(of: (String, Keychain.Credentials?).self) { group in
            for account in config.accounts {
                group.addTask { @MainActor in (account.id, await self.routerCredentials(for: account)) }
            }
            var out: [String: Keychain.Credentials] = [:]
            for await (id, creds) in group { out[id] = creds }
            return out
        }
        var refused: Set<String> = []

        for account in config.accounts {
            let identity = AccountRouter.identity(for: account, config: config)
            logins[account.id] = identity
            let stored = identity.flatMap { accounts.records[$0.key]?.snapshot }
            let routerRead = readings[account.id]
            let liveRead = Self.liveSnapshot(live[account.id], for: identity)
            let service = AccountRouter.keychainService(for: account)
            // The terminal's own login has its line in Acessos already.
            if service != Keychain.service, keychainRefusal[service]?.waitsForPerson == true { refused.insert(account.id) }

            guard let creds = credsById[account.id] else { continue }
            available.insert(account.id)
            let probeKey = identity?.key ?? account.id

            if let identity, identity.key == active?.key {
                // The terminal poll already merged the live numbers into its own read.
                usage[account.id] = AccountRouter.combined(full: freshest(apiSnapshot ?? stored, routerRead?.snapshot),
                                                           live: liveRead)
                continue
            }

            // A whole reading (the router's or our own) a moment ago, live numbers over one from the last ten
            // minutes, or a pause the server asked for: those numbers stand, and asking again would only spend this
            // account's share of the endpoint.
            let fullAt = [routerRead?.snapshot.fetchedAt, lastProbe[probeKey]].compactMap { $0 }.max()
            let waiting = [routerRead?.waitUntil, probePausedUntil[account.id]].compactMap { $0 }.contains { $0 > now }
            let current = recent(fullAt, within: usageInterval)
                || (recent(liveRead?.fetchedAt, within: usageInterval) && recent(fullAt, within: fullReadInterval))
            if creds.isExpired { idle.insert(account.id) }
            let standing = AccountRouter.combined(full: freshest(routerRead?.snapshot, stored), live: liveRead)
            if waiting || current || creds.isExpired {
                usage[account.id] = standing
                continue
            }
            do {
                let (snap, _) = try await UsageAPI.fetch(token: creds.accessToken)
                probePausedUntil[account.id] = nil
                lastProbe[probeKey] = snap.fetchedAt
                if let identity {
                    accounts.record(uuid: identity.key, label: identity.label,
                                    plan: creds.subscriptionType ?? identity.planFallback,
                                    snapshot: snap, at: snap.fetchedAt)
                    read.insert(identity.key)
                }
                usage[account.id] = snap
            } catch {
                if case UsageError.rateLimited(let retryAfter) = error {
                    probePausedUntil[account.id] = now.addingTimeInterval(min(3600, max(300, retryAfter ?? 300)))
                }
                usage[account.id] = standing
            }
        }

        let exhausted = AccountRouter.exhausted()
        router = RouterState(
            config: config,
            pick: config.enabled
                ? AccountRouter.pick(config, headroom: usage.mapValues { AccountRouter.headroom($0) },
                                     available: available, exhausted: exhausted)
                : nil,
            usage: usage,
            lastSwitch: AccountRouter.lastSwitch(),
            logins: logins,
            read: read,
            available: available,
            exhausted: exhausted,
            agentsLogins: Set(config.accounts.map(\.id).filter(AccountRouter.hasAgentsLogin)),
            switches: AccountRouter.switches(limit: 20),
            idleLogins: idle,
            keychainRefused: refused)
    }

    /// The live numbers of one account, only when the router saved them under its current login: the slot may have
    /// been logged into a different account since, and a file whose login the router could not read proves nothing.
    /// With no login to compare to (this side cannot read it either), the numbers stand.
    nonisolated static func liveSnapshot(_ live: AccountRouter.LiveLimits?, for identity: AccountIdentity?) -> UsageSnapshot? {
        guard let live else { return nil }
        if let identity, live.key != identity.key { return nil }
        return live.snapshot
    }

    /// An extra account's login, read like the terminal's and with the same restraint after a refusal: the last
    /// login read stands in meanwhile, so the account does not drop out of the queue over a dialog.
    private func routerCredentials(for account: AccountRouter.Account) async -> Keychain.Credentials? {
        do {
            let creds = try await readKeychain(service: AccountRouter.keychainService(for: account))
            routerCreds[account.id] = creds
            return creds
        } catch let failure as Keychain.Failure where Self.keychainWait(after: failure) != nil {
            return routerCreds[account.id]
        } catch {
            routerCreds[account.id] = nil
            return nil
        }
    }

    /// One Keychain item, off the main actor (a read waiting on a dialog must not freeze the panel), and left alone
    /// for a while after a refusal instead of bringing the dialog back on every poll.
    private func readKeychain(service: String) async throws -> Keychain.Credentials {
        if let at = keychainRetryAt[service], at > Date(), let refusal = keychainRefusal[service] { throw refusal }
        do {
            let creds = try await Blocking.runThrowing { try Keychain.credentials(service: service) }
            keychainRetryAt[service] = nil
            keychainRefusal[service] = nil
            return creds
        } catch let failure as Keychain.Failure {
            if let wait = Self.keychainWait(after: failure) {
                keychainRetryAt[service] = wait
                keychainRefusal[service] = failure
            }
            throw failure
        }
    }

    /// How long the Keychain is left alone after `failure`: until "Ler de novo" after a refused or unanswered prompt,
    /// five minutes after a locked Keychain or an odd error, and not at all when the item is simply missing, since
    /// asking about that raises no dialog and a new login should show up on the next poll.
    nonisolated static func keychainWait(after failure: Keychain.Failure, now: Date = Date()) -> Date? {
        switch failure {
        case .denied, .unanswered: return .distantFuture
        case .locked, .other: return now.addingTimeInterval(300)
        case .notFound, .noAccountToken, .expired, .malformed: return nil
        }
    }

    /// The router account whose login is in `~/.claude`, the one the live read is about.
    private var liveRouterId: String { router?.config.principal ?? AccountRouter.loadConfig()?.principal ?? "principal" }

    /// The preferred feed: the live numbers a stream session received, then our own read of the API with the
    /// terminal's token. `TerminalPlan` decides which.
    private func pollTerminalFeed(identity: AccountIdentity?, live: [String: AccountRouter.LiveLimits],
                                  readings: [String: AccountRouter.RouterReading]) async {
        let now = Date()
        let liveRead = identity == nil ? nil : Self.liveSnapshot(live[liveRouterId], for: identity)
        feeds.stream = liveRead.map { now.timeIntervalSince($0.fetchedAt) < 600 ? .live(at: $0.fetchedAt) : .stale(at: $0.fetchedAt) }
            ?? .missing
        let pause = [livePausedUntil, readings[liveRouterId]?.waitUntil].compactMap { $0 }.max().flatMap { $0 > now ? $0 : nil }
        let plan = TerminalPlan.plan(live: liveRead?.fetchedAt, held: apiSnapshot?.fetchedAt, lastAttempt: lastFullAttempt,
                                     pause: pause, now: now, interval: usageInterval)
        showFullRead(pause: pause)
        let otherwise: TerminalPlan.Live
        switch plan {
        case .takeLive:
            if let liveRead { useLive(liveRead, identity: identity) }
            return
        case .wait(let until, let liveState):
            if liveState != .none, let liveRead { absorbLive(liveRead, identity: identity) }
            usageError = Self.pauseText(until)
            feeds.terminal = .broken("pausa pedida")
            livePauseShown = until
            return
        case .read(let liveState):
            otherwise = liveState
        }
        livePauseShown = nil
        lastFullAttempt = now
        do {
            let creds = try await credentials()
            // Fail on the expiry we can read rather than on the 401 it is about to earn. Same
            // outcome, but it names the problem — and this is the exact state the Monitor sat in
            // for twenty-one hours reporting nothing: the CLI owns the refresh, and if you have
            // stopped using the CLI, nobody renews it.
            guard !creds.isExpired else { throw Keychain.Failure.expired }

            let snap = try await fetchUsage(creds: creds)
            lastFullRead = snap.fetchedAt
            lastFullFailure = nil
            showFullRead(pause: nil)
            livePausedUntil = nil
            liveBackoff = 0
            apiSnapshot = snap
            apiSnapshotOrg = identity?.organizationUuid
            usageError = nil
            terminalFailure = nil
            feeds.terminal = .live(at: snap.fetchedAt)

            if let id = identity {
                accounts.record(uuid: id.key, label: id.label,
                                plan: creds.subscriptionType ?? id.planFallback,
                                snapshot: snap, at: snap.fetchedAt)
            }
        } catch {
            var pausedUntil: Date?
            if case UsageError.rateLimited(let retryAfter) = error {
                liveBackoff = min(3600, max(usageInterval, liveBackoff * 2))
                let until = now.addingTimeInterval(min(3600, max(60, retryAfter ?? liveBackoff)))
                livePausedUntil = until
                pausedUntil = until
            }
            lastFullFailure = pausedUntil == nil ? error : nil
            showFullRead(pause: pausedUntil)
            // The whole read failed, but live numbers keep arriving: they stand, and only the per-model windows wait
            // for the next whole read.
            if otherwise == .current, let liveRead {
                useLive(liveRead, identity: identity)
                return
            }
            if otherwise == .older, let liveRead { absorbLive(liveRead, identity: identity) }
            terminalFailure = error
            usageError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            feeds.terminal = .broken(FeedState.shortReason(for: error))
            if let pausedUntil {
                livePauseShown = pausedUntil
                usageError = Self.pauseText(pausedUntil)
            }
        }
    }

    private static func pauseText(_ until: Date) -> String {
        "O servidor pediu uma pausa até \(Fmt.clock(until)). Os números voltam depois disso."
    }

    /// The settings' line for the whole read: the pause while it lasts, else the last failure, else when it answered.
    private func showFullRead(pause: Date?) {
        if let pause {
            fullReadHealth = .broken("pausa pedida")
            fullReadProblem = Self.fullReadPauseText(pause)
        } else if let failure = lastFullFailure {
            fullReadHealth = .broken(FeedState.shortReason(for: failure))
            fullReadProblem = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        } else {
            fullReadHealth = lastFullRead.map { .live(at: $0) } ?? .missing
            fullReadProblem = nil
        }
    }

    /// The same pause, said of the whole read alone: live numbers may well be arriving meanwhile.
    private static func fullReadPauseText(_ until: Date) -> String {
        "O servidor pediu uma pausa até \(Fmt.clock(until)); a consulta completa volta depois disso."
    }

    /// Live numbers as the current reading: the feed is live again.
    private func useLive(_ live: UsageSnapshot, identity: AccountIdentity?) {
        absorbLive(live, identity: identity)
        livePauseShown = nil
        usageError = nil
        terminalFailure = nil
        feeds.terminal = .live(at: live.fetchedAt)
    }

    /// Live numbers merged into the last reading, without saying anything about the feed: older ones still beat
    /// what was read before them, and show with their age.
    private func absorbLive(_ live: UsageSnapshot, identity: AccountIdentity?) {
        let merged = AccountRouter.merging(live, into: apiSnapshot)
        apiSnapshot = merged
        apiSnapshotOrg = identity?.organizationUuid
        if let id = identity {
            accounts.record(uuid: id.key, label: id.label, plan: accounts.records[id.key]?.plan ?? id.planFallback,
                            snapshot: merged, at: merged.fetchedAt)
        }
    }

    /// Picks which feed the panel draws from, and records the result in the history.
    ///
    /// The API wins whenever it answered — it is the only one carrying the per-model windows, the
    /// server's own severity and the extra credit. The desktop app's file is the standby: same
    /// server numbers, five-minute cadence, no credential involved.
    private func applyFeeds(_ byOrg: [String: [DesktopSample]]) {
        let newest = FeedArbiter.newestOrg(in: byOrg)

        feeds.desktop = newest.map {
            DesktopUsage.isCurrent($0.at) ? .live(at: $0.at) : .stale(at: $0.at)
        } ?? .missing

        let desktopOffer = newest.flatMap { n in
            byOrg[n.org]
                .flatMap { DesktopUsage.snapshot(series: $0, weeklyAnchor: weeklyAnchor(forOrg: n.org)) }
                .map { FeedArbiter.Offer(snapshot: $0, org: n.org) }
        }

        let choice = FeedArbiter.choose(
            api: apiSnapshot.map { FeedArbiter.Offer(snapshot: $0, org: apiSnapshotOrg) },
            terminal: feeds.terminal,
            desktop: desktopOffer,
            desktopHealth: feeds.desktop
        )

        usage = choice.snapshot
        liveOrg = choice.org
        liveHealth = choice.snapshot == nil ? .missing : choice.health
        if let snap = choice.snapshot { record(snap, org: choice.org) }
    }

    /// Any weekly `resets_at` the API has ever reported for this organization. The weekly window
    /// is strictly periodic, so even a week-old anchor winds forward to today's reset exactly.
    private func weeklyAnchor(forOrg org: String) -> Date? {
        if apiSnapshotOrg == org, let at = apiSnapshot?.weekly?.resetsAt { return at }
        return record(forOrg: org)?.snapshot.weekly?.resetsAt
    }

    /// Who the expanded, live detail belongs to. Normally the terminal identity; once the terminal
    /// token dies it is the organization the desktop app is driving, which is not necessarily the
    /// same one — so the lead row has to be told, rather than assuming `activeAccount`.
    struct LiveAccount: Equatable {
        var label: String
        var plan: String?
        var organizationUuid: String?
    }

    var liveAccount: LiveAccount? {
        if usage?.source == .desktopApp, let org = liveOrg,
           let seen = desktopOrgs.first(where: { $0.organizationUuid == org }) {
            // The token's own subscriptionType, if we have ever held one for this organization,
            // beats the type the desktop config carries: the same organization reads "team" there
            // and "max" on the token, and the badge is about the plan, not the org kind.
            return LiveAccount(label: seen.label,
                               plan: record(forOrg: org)?.plan ?? seen.plan,
                               organizationUuid: org)
        }
        guard let id = activeAccount else { return nil }
        return LiveAccount(label: id.label, plan: activePlan, organizationUuid: id.organizationUuid)
    }

    /// The persisted entry for one organization, whichever account it was reached under.
    ///
    /// Most-recently-seen wins. One organization can hold entries for two logins, and `Dictionary`
    /// has no iteration order — picking the "first" match meant the plan badge, the weekly anchor
    /// and the ghost rows could each land on a different account between launches.
    private func record(forOrg org: String?) -> AccountRecord? {
        guard let org else { return nil }
        return accounts.records.values
            .filter { $0.organizationUuid == org }
            .max { ($0.lastSeen, $1.uuid) < ($1.lastSeen, $0.uuid) }
    }

    /// Accounts other than the one on show, most-recently-seen first — the collapsible strips
    /// beneath it. While a desktop organization holds the live slot, the terminal account is no
    /// longer "the active one": it drops down here with its last-seen numbers, like any other.
    var otherAccounts: [AccountRecord] {
        // No strips while we cannot name who is on show: we would have no way to tell which cached
        // record is the "other" one, and could end up listing the live account beside itself.
        guard liveAccount != nil else { return [] }

        // Exclude exactly the record the lead row is showing — never everything sharing its
        // organization. Two logins into one organization are two accounts with two sets of limits;
        // filtering by organization dropped the second one off the panel entirely.
        let leadKey = showingFallback ? record(forOrg: liveOrg)?.uuid : activeAccount?.key
        return accounts.others(activeUuid: leadKey)
    }

    /// Plan badge for the active account: the token's own subscriptionType (most accurate, stored
    /// on the last record) falling back to the org type from ~/.claude.json.
    var activePlan: String? {
        guard let id = activeAccount else { return nil }
        return accounts.records[id.key]?.plan ?? id.planFallback
    }

    /// True while the panel is being carried by the desktop feed, which is the only time anything
    /// is missing and therefore the only time a ghost means something. Every ghost accessor is
    /// gated on it: without the gate the extra credit would draw a second, faded copy of itself
    /// underneath the live one.
    private var showingFallback: Bool { usage?.source == .desktopApp }

    /// How often the feed currently on screen produces a new reading, in words.
    var feedCadence: String {
        showingFallback ? "5 min" : Fmt.duration(Settings.shared.usageIntervalSeconds)
    }

    /// Windows the API had that the desktop feed cannot carry — the per-model weekly caps, and the
    /// extra credit. Drawn faded, with their last value and when it was seen, so that changing
    /// feeds never makes a limit vanish without saying so.
    ///
    /// Only ever from the same organization: another organization's per-model numbers under this
    /// organization's heading would be a different account's data wearing the wrong name.
    var ghostWindows: [LimitWindow] {
        guard showingFallback, let api = carriedOverAPISnapshot else { return [] }
        // Matching on key alone is not enough: against an older payload shape the same two windows
        // come back as `five_hour`/`seven_day` instead of `session`/`weekly_all`, and every one of
        // them would ghost underneath the live row it duplicates. Match on the role instead.
        return api.windows.filter { !$0.isSession && !LimitWindow.weeklyAllKeys.contains($0.key) }
    }

    var ghostExtraCredit: Double? {
        guard showingFallback, let api = carriedOverAPISnapshot, api.extraUsageEnabled else { return nil }
        return api.extraUsageUtilization
    }

    /// When the ghosts were last true, or nil when there are none to date-stamp.
    var ghostSeenAt: Date? {
        guard showingFallback, !ghostWindows.isEmpty || ghostExtraCredit != nil else { return nil }
        return carriedOverAPISnapshot?.fetchedAt
    }

    /// The most recent API reading for the organization on show. Falls back to the one persisted in
    /// `accounts.json`, which matters more than it looks: with an expired token the app can run for
    /// hours without a single successful poll, so an in-memory-only snapshot would mean the ghosts
    /// never appear at all — exactly the case this whole fallback exists for.
    private var carriedOverAPISnapshot: UsageSnapshot? {
        guard let org = liveOrg else { return nil }
        if apiSnapshotOrg == org, let api = apiSnapshot { return api }
        guard let stored = record(forOrg: org)?.snapshot, stored.source == .api else { return nil }
        return stored
    }

    /// Organizations the desktop app has used that nothing else on the panel covers. They render
    /// as a plain strip and never expand: the desktop app records only the two headline
    /// percentages, so there is no per-model window to open into.
    var desktopOnlyOrgs: [DesktopOrgUsage] {
        var covered = Set(accounts.records.values.compactMap(\.organizationUuid))
        // Only while the terminal is actually feeding the panel does its organization have a row
        // of its own. When it is not, and no cached record exists for it either, marking it
        // "covered" removed the last place it could have appeared and the account the user is
        // logged into in the terminal vanished from the panel completely.
        if usage?.source == .api, let org = activeAccount?.organizationUuid { covered.insert(org) }
        if let org = liveOrg { covered.insert(org) }
        return desktopOrgs.filter { !covered.contains($0.organizationUuid) }
    }

    /// Cached keychain read: the item is only touched when nothing is cached yet or the cached token is about to
    /// expire.
    private func credentials(bypassingCache: Bool = false) async throws -> Keychain.Credentials {
        if !bypassingCache, let cached = cachedCreds, !cached.expiresSoon { return cached }
        let fresh = try await readKeychain(service: Keychain.service)
        cachedCreds = fresh
        return fresh
    }

    /// The Monitor is a read-only observer of the credential. Claude Code owns the token and
    /// keeps it fresh, so we never refresh here: two independent clients rotating the same
    /// refresh token trip Anthropic's reuse detection and invalidate the whole token family —
    /// which would break login for the CLI too and leave the Keychain prompting in a loop. On a
    /// 401 we re-read the keychain once (the CLI may have rotated the token since we cached it)
    /// and retry; if it is still rejected we surface the error and let the next poll try again
    /// after the CLI has renewed.
    private func fetchUsage(creds: Keychain.Credentials) async throws -> UsageSnapshot {
        do {
            return try await UsageAPI.fetch(token: creds.accessToken).0
        } catch UsageError.unauthorized {
            let fresh = try await credentials(bypassingCache: true)
            guard fresh.accessToken != creds.accessToken else { throw UsageError.unauthorized }
            return try await UsageAPI.fetch(token: fresh.accessToken).0
        }
    }

    private func record(_ snap: UsageSnapshot, org: String?) {
        history.append(UsageSample(
            at: snap.fetchedAt,
            session: snap.session?.utilization,
            sessionResetsAt: snap.session?.resetsAt,
            weekly: snap.weekly?.utilization,
            tokensCumulative: ledger.block.total,
            org: org,
            account: snap.source == .api ? activeAccount?.key : nil
        ))
        history.flush()
    }

    // MARK: derived

    var sessionBurn: BurnRate? { history.burnRate(\.session, org: liveOrg) }
    var weeklyBurn: BurnRate? {
        history.burnRate(\.weekly, org: liveOrg, window: 6 * 3600, minPoints: 8, minSpan: 3600)
    }

    /// Whichever comes first decides the story: you run out, or the window resets.
    enum Outlook {
        case idle
        case measuring
        case safe(rate: Double, reset: TimeInterval)
        case willHitCap(exhaustIn: TimeInterval, reset: TimeInterval, rate: Double, minutes: Double, aheadOfPace: Bool)
    }

    var outlook: Outlook {
        guard let w = usage?.session, let reset = w.timeToReset else { return .idle }
        guard let burn = sessionBurn else { return .measuring }
        guard let hours = burn.hoursToExhaustion(from: w.utilization) else {
            return .safe(rate: burn.percentPerHour, reset: reset)
        }
        let exhaust = hours * 3600
        guard exhaust < reset else { return .safe(rate: burn.percentPerHour, reset: reset) }
        return .willHitCap(exhaustIn: exhaust, reset: reset,
                           rate: burn.percentPerHour, minutes: burn.basedOnMinutes,
                           aheadOfPace: (w.paceRatio ?? 0) >= 1)
    }

    var blockTrail: [(Date, Double)] {
        guard let reset = usage?.session?.resetsAt else { return [] }
        return history.series(\.session, since: reset.addingTimeInterval(-5 * 3600), org: liveOrg)
    }

    var weekTrail: [(Date, Double)] {
        history.series(\.weekly, since: Date().addingTimeInterval(-7 * 24 * 3600), org: liveOrg)
    }

    func tokens(for session: ClaudeSession) -> TokenCounts {
        ledger.bySession[session.sessionId] ?? .init()
    }

    var busiestSessionTokens: Int64 {
        max(1, sessions.map { tokens(for: $0).total }.max() ?? 1)
    }

    /// The headline the whole tool exists to produce: what Claude, in total, is costing this
    /// machine right now — sessions plus everything they spawned, wherever it ended up.
    var claudeShare: (cpu: Double, rss: UInt64, procs: Int) {
        (attribution.claudeCPU, attribution.claudeRSS, attribution.claudeProcCount)
    }



    // MARK: process grouping

    private func apply(system sys: SystemStats, procs: [ProcInfo]) {
        system = sys
        cpuTrail.append(sys.cpuPercent)
        if cpuTrail.count > 60 { cpuTrail.removeFirst(cpuTrail.count - 60) }

        // A session in `~/.claude` runs on whatever login the folder holds now: after the agents' switch the open
        // Claude Code re-reads the Keychain item and spends the account that moved in, whatever account the router
        // opened it on (09/10: sessions marked Max were spending Squad Compare). So the folder decides, not the
        // router's mark on the process; the router now opens stream sessions in the account's own folder and
        // brings a stranded one back to it.
        sessions = ClaudeSessionStore.load(accounts: sessionDirectories)
        attribution = Attribution.build(procs: procs, sessions: sessions)
    }

    // MARK: actions

    func terminate(_ pids: [pid_t], force: Bool) {
        let sig = force ? SIGKILL : SIGTERM
        for pid in pids where pid > 1 { kill(pid, sig) }
        // Give them a moment to actually go before we redraw, or the row flickers back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.tickFast()
        }
    }

    func terminate(_ pid: pid_t, force: Bool) { terminate([pid], force: force) }

    // MARK: queue

    /// The accounts as the panel shows them. Without a router config it is one implicit entry, the live account.
    var accountQueue: AccountQueue {
        let now = Date()
        guard let router, router.config.hasExtraAccounts else {
            let live = liveAccount
            let entry = AccountQueue.Entry(
                id: "principal", label: live?.label ?? activeAccount?.label ?? "Claude Code",
                monogram: AccountRouter.monogram(for: live?.label ?? "CC"), role: .route,
                plan: live?.plan, email: activeAccount?.email, organization: activeAccount?.organizationDisplay,
                snapshot: usage, hasLogin: true, agentsLogin: true, exhaustedUntil: nil,
                sessions: sessions.count, runsAgents: true, isLive: true)
            return AccountQueue(entries: [entry], strategy: .order, enabled: false, configured: false)
        }
        let entries: [AccountQueue.Entry] = router.config.accounts.map { account in
            let identity = router.logins[account.id]
            // The live feed belongs to this row only while it is this account's: carried by the desktop app it can be
            // another organization's, and then the row, its detail and its forecast all use the account's own reading.
            let live = identity != nil && identity?.key == activeAccount?.key && usageIsActiveAccount
            // The freshest reading wins: with the terminal token failing, the router may have just read this
            // account with its own login while the live feed is still holding an old number.
            let candidates = [live ? usage : nil, router.usage[account.id],
                              identity.flatMap { accounts.records[$0.key]?.snapshot }].compactMap { $0 }
            let snapshot = candidates.max { $0.fetchedAt < $1.fetchedAt }
            return AccountQueue.Entry(
                id: account.id, label: account.label, monogram: account.monogram, role: account.role,
                plan: identity.flatMap { accounts.records[$0.key]?.plan ?? $0.planFallback },
                email: identity?.email, organization: identity?.organizationDisplay,
                snapshot: snapshot, hasLogin: router.available.contains(account.id),
                agentsLogin: account.id == router.config.principal || router.agentsLogins.contains(account.id),
                exhaustedUntil: router.exhausted[account.id].flatMap { $0 > now ? $0 : nil },
                sessions: sessions.filter { $0.accountId == account.id }.count,
                sessionsInFolder: sessions.filter { $0.folderAccountId == account.id }.count,
                runsAgents: account.id == router.config.principal,
                isLive: live,
                loginIdle: router.idleLogins.contains(account.id),
                loginRefused: router.keychainRefused.contains(account.id))
        }
        return AccountQueue(entries: entries, strategy: router.config.strategy, enabled: router.config.enabled,
                            reserveBelow: router.config.reserveBelow, configured: true,
                            principal: router.config.principal, pinned: router.config.pinned)
    }

    /// The 5h window the menu bar shows, and whether it is current: the account new sessions open on, which is the
    /// one its monogram names. Before, the number came from the account in `~/.claude` whatever the queue said, so
    /// after choosing another account the menu bar kept showing the old one's percentage.
    struct MenuBarReading {
        var window: LimitWindow?
        var current: Bool
        var seenAt: Date?
        /// The live account's own reading: only then does the outlook (its pace forecast) describe this number.
        var isLive: Bool
    }

    /// True while `usage` describes the terminal account. With the terminal token dead the desktop app carries the
    /// live feed, and it may be driving another organization: that reading is not the active account's.
    private var usageIsActiveAccount: Bool { liveOrg == activeAccount?.organizationUuid }

    /// A queue account's reading older than this is drawn muted in the menu bar, like a dead live feed.
    static let menuBarFreshness: TimeInterval = 15 * 60

    var menuBarSession: MenuBarReading {
        let q = accountQueue
        guard q.configured, !q.isSingle, let id = q.newSessions(), let entry = q.entry(id),
              !entry.isLive else {
            return MenuBarReading(window: usage?.session, current: liveIsCurrent, seenAt: liveSeenAt, isLive: true)
        }
        let seen = entry.snapshot?.fetchedAt
        let fresh = seen.map { Date().timeIntervalSince($0) < Self.menuBarFreshness } ?? false
        return MenuBarReading(window: entry.snapshot?.session, current: fresh, seenAt: seen, isLive: false)
    }

    /// The monogram the menu bar shows: only when new sessions are not opening on the head of the queue.
    var menuBarMonogram: String? {
        let q = accountQueue
        guard q.configured, !q.isSingle, let inUse = q.newSessions(), inUse != q.route.first?.id else { return nil }
        return q.entry(inUse)?.monogram
    }

    /// New sessions open on `id` from now on, above the rule; nil goes back to the rule.
    func pinAccount(_ id: String?) async {
        await save { try AccountRouter.setPinned(id) }
        watchAgentsNow()
    }

    /// Takes an account out of the queue (see `AccountRouter.discard`): for an entry that should not be there, such
    /// as a second login into the same account.
    func removeAccount(_ id: String) async {
        // The account's folder goes to the Trash: never under a session still running with it as its config
        // directory. Checked when the removal's turn comes, after the edits queued before it, not when the button
        // was pressed: a session opened in between counts.
        await save(unless: { [weak self] in
            AccountQueue.removalBlocked(sessions: self?.sessions.filter { $0.folderAccountId == id }.count ?? 0)
        }) { try AccountRouter.discard(id) }
        watchAgentsNow()
    }

    func moveAccount(_ id: String, to index: Int) async {
        // The move is computed inside the save, from the config on disk, so two quick moves never build on the
        // same stale order.
        await save {
            guard let config = AccountRouter.loadConfig() else { throw AccountRouter.UnreadableConfig() }
            let ids = config.route.map(\.id) + config.reserve.map(\.id)
            guard let moved = AccountQueue.moving(ids, reserveFrom: config.route.count, id: id, to: index) else {
                throw AccountRouter.EmptyRoute()
            }
            try AccountRouter.saveQueue(route: moved.route, reserve: moved.reserve, strategy: config.strategy)
        }
        // A new head of the queue is a new preferred account: the agents check it now, not in five minutes.
        watchAgentsNow()
    }

    func setStrategy(_ strategy: AccountRouter.Strategy) async {
        await save {
            guard let config = AccountRouter.loadConfig() else { throw AccountRouter.UnreadableConfig() }
            try AccountRouter.setStrategy(strategy, route: config.route.map(\.id))
        }
        watchAgentsNow()
    }

    func setSwitching(_ on: Bool) async {
        if on, !AccountRouter.commandsInstalled, let bin = AccountRouter.bundledCommands {
            try? AccountRouter.installCommands(from: bin)
        }
        await save { try AccountRouter.setEnabled(on) }
        watchAgentsNow()
    }

    func renameAccount(_ id: String, name: String, monogram: String) async {
        await save { try AccountRouter.renameAccount(id, name: name, monogram: monogram) }
    }

    /// One router edit at a time, then the config is read back into the panel right away. The usage stays as it
    /// was: an edit to the queue changes no number, and a fresh poll would only spend the endpoint.
    /// `unless`, when it returns a reason, cancels the edit at its turn and shows the reason instead.
    private func save(unless blocked: (@MainActor () -> String?)? = nil,
                      _ change: @escaping @Sendable () throws -> Void) async {
        // Edits run one after the other, in the order they were asked for: a second move made while the first is
        // still writing is applied after it, never dropped.
        pendingRouterSaves += 1
        savingRouter = true
        let previous = routerSaveTail
        let mine = Task { @MainActor in
            await previous?.value
            if let reason = blocked?() {
                actionError = reason
                return
            }
            do {
                try await Blocking.runThrowing { try change() }
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
            reloadRouterConfig()
        }
        routerSaveTail = mine
        await mine.value
        pendingRouterSaves -= 1
        if pendingRouterSaves == 0 {
            savingRouter = false
            routerSaveTail = nil
        }
    }

    private func reloadRouterConfig() {
        guard var state = router, let config = AccountRouter.loadConfig(), config.hasExtraAccounts else {
            Task { await refreshUsage(force: true) }
            return
        }
        state.config = config
        state.pick = config.enabled
            ? AccountRouter.pick(config, headroom: state.usage.mapValues { AccountRouter.headroom($0) },
                                 available: state.available, exhausted: state.exhausted)
            : nil
        state.switches = AccountRouter.switches(limit: 20)
        router = state
    }

    // MARK: assistant and actions

    func startAddAccount() {
        accountFlow?.cancel()
        let flow = AddAccountFlow(store: accounts, desktop: desktopOrgs,
                                  agentsRunning: sessions.filter(\.isBackground).count)
        flow.onFinish = { [weak self] in Task { await self?.refreshUsage(force: true); await self?.refreshAccessIfDue(force: true) } }
        accountFlow = flow
        settingsTab = .accounts
    }

    func startReauthorize(_ id: String, agents: Bool) {
        guard let account = router?.config.accounts.first(where: { $0.id == id }) else { return }
        accountFlow?.cancel()
        let flow = AddAccountFlow(reauthorize: account, agents: agents,
                                  agentsRunning: sessions.filter(\.isBackground).count)
        flow.onFinish = { [weak self] in Task { await self?.refreshUsage(force: true); await self?.refreshAccessIfDue(force: true) } }
        accountFlow = flow
        settingsTab = .accounts
    }

    func closeAccountFlow() {
        accountFlow?.cancel()
        accountFlow = nil
    }

    /// Runs what an access item offers. Returns true when the settings window should come forward (the
    /// assistant lives there).
    @discardableResult
    func perform(_ action: AccessAction) async -> Bool {
        actionError = nil
        switch action {
        case .reauthorize(let account, let agents):
            startReauthorize(account, agents: agents)
            return true
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .readinessFix(let id, let params):
            runningAction = id
            let result = await Readiness.run(Readiness.fixArguments(id, params: params))
            runningAction = nil
            if !result.ok { actionError = AddAccountFlow.firstLine(result.error) ?? "A correção não terminou." }
            await refreshAccessIfDue(force: true)
        case .upgrade(let cask):
            await upgrade(cask)
        case .readAgain:
            await readAgain()
        }
        return false
    }

    private func upgrade(_ cask: String) async {
        guard let brew = Versions.brew else { actionError = "Homebrew não encontrado"; return }
        runningAction = cask
        let result = await Blocking.run {
            AccountRouter.run(brew, ["upgrade", "--cask", cask], extra: ["HOMEBREW_NO_ENV_HINTS": "1"], timeout: 900)
        }
        runningAction = nil
        guard result.ok else {
            actionError = AddAccountFlow.firstLine(result.error) ?? "O Homebrew não conseguiu atualizar \(cask)."
            return
        }
        lastVersionCheck = nil
        if cask == "monitor-claude" {
            relaunch()
            return
        }
        await refreshAccessIfDue(force: true)
    }

    /// Opens the app bundle again and quits this copy, so a fresh `brew upgrade` takes effect.
    private func relaunch() {
        let bundle = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func setTerminalIntegration(_ on: Bool) {
        do {
            if on, !AccountRouter.commandsInstalled, let bin = AccountRouter.bundledCommands {
                try AccountRouter.installCommands(from: bin)
            }
            try Integrations.setTerminal(on)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        integrations = IntegrationsState.read()
    }

    func setVSCodeIntegration(_ on: Bool) {
        do {
            if on, !AccountRouter.commandsInstalled, let bin = AccountRouter.bundledCommands {
                try AccountRouter.installCommands(from: bin)
            }
            try Integrations.setVSCodeWrapper(on)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        integrations = IntegrationsState.read()
    }

    func refreshIntegrations() { integrations = IntegrationsState.read() }

    /// Turns on the readiness panel's watcher (start with the computer), through the panel's own script.
    func enableReadinessWatcher() async {
        runningAction = "readiness"
        let result = await Readiness.run(["--autostart", "on"], timeout: 120)
        runningAction = nil
        if !result.ok { actionError = AddAccountFlow.firstLine(result.error) ?? "Não deu para ligar o vigia." }
        await refreshAccessIfDue(force: true)
    }

    func revealInActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
