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

    /// The last thing the API gave us this run. Outlives a failed poll so the windows the desktop
    /// feed cannot carry can still be drawn as ghosts, and so the weekly reset keeps its anchor.
    private var apiSnapshot: UsageSnapshot?
    private var apiSnapshotOrg: String?

    /// The account Claude Code has active right now (from ~/.claude.json). Drives the multi-account
    /// view; nil means we could not read an identity, so the panel shows the single-account layout.
    @Published private(set) var activeAccount: AccountIdentity?
    /// Organizations read from the desktop app's own usage history, refreshed on the slow tick.
    @Published private(set) var desktopOrgs: [DesktopOrgUsage] = []
    let accounts = AccountStore()

    @Published var panelOpen = false { didSet { retime() } }

    let history = UsageHistory()

    nonisolated(unsafe) private let sysSampler = SystemSampler()
    nonisolated(unsafe) private let procSampler = ProcessSampler()
    nonisolated(unsafe) private let ledgerScanner = TokenLedger()
    private let queue = DispatchQueue(label: "farol.sampler", qos: .utility)
    private let ledgerQueue = DispatchQueue(label: "farol.ledger", qos: .utility)

    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var lastUsageFetch: Date?
    private var lastLedgerScan: Date?
    private var sampling = false
    private var cachedCreds: Keychain.Credentials?
    private var lastAccountKey: String?
    private var cancellables: Set<AnyCancellable> = []

    private var usageInterval: TimeInterval { Settings.shared.usageIntervalSeconds }
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
        history.flush()
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
        desktopOrgs = ClaudeDesktop.organizationUsage()
        let desktopSeries = ClaudeDesktop.samplesByOrg()

        let identity = ClaudeConfig.activeAccount()
        if identity?.key != lastAccountKey {
            cachedCreds = nil
            usage = nil
            usageError = nil
            apiSnapshot = nil
            apiSnapshotOrg = nil
            lastAccountKey = identity?.key
        }
        activeAccount = identity

        await pollTerminalFeed(identity: identity)
        applyFeeds(desktopSeries)
    }

    /// The preferred feed: our own read of the API, with the terminal's token.
    private func pollTerminalFeed(identity: AccountIdentity?) async {
        do {
            let creds = try credentials()
            // Fail on the expiry we can read rather than on the 401 it is about to earn. Same
            // outcome, but it names the problem — and this is the exact state the Monitor sat in
            // for twenty-one hours reporting nothing: the CLI owns the refresh, and if you have
            // stopped using the CLI, nobody renews it.
            guard !creds.isExpired else { throw Keychain.Failure.expired }

            let snap = try await fetchUsage(creds: creds)
            apiSnapshot = snap
            apiSnapshotOrg = identity?.organizationUuid
            usageError = nil
            feeds.terminal = .live(at: snap.fetchedAt)

            if let id = identity {
                accounts.record(uuid: id.key, label: id.label,
                                plan: creds.subscriptionType ?? id.planFallback,
                                snapshot: snap, at: snap.fetchedAt)
            }
        } catch {
            usageError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            feeds.terminal = .broken(FeedState.shortReason(for: error))
        }
    }

    /// Picks which feed the panel draws from, and records the result in the history.
    ///
    /// The API wins whenever it answered — it is the only one carrying the per-model windows, the
    /// server's own severity and the extra credit. The desktop app's file is the standby: same
    /// server numbers, five-minute cadence, no credential involved.
    private func applyFeeds(_ byOrg: [String: [DesktopSample]]) {
        // Whichever organization was sampled most recently is the one the desktop app is driving.
        let newest = byOrg
            .compactMap { org, series in series.last.map { (org: org, at: $0.at) } }
            .max { $0.at < $1.at }

        feeds.desktop = newest.map {
            DesktopUsage.isCurrent($0.at) ? .live(at: $0.at) : .stale(at: $0.at)
        } ?? .missing

        if case .live = feeds.terminal, let api = apiSnapshot {
            adopt(api, org: apiSnapshotOrg)
            return
        }

        if let newest, let series = byOrg[newest.org],
           let snap = DesktopUsage.snapshot(series: series,
                                            weeklyAnchor: weeklyAnchor(forOrg: newest.org)) {
            adopt(snap, org: newest.org)
            return
        }

        // Neither feed answered. Hold on to the last API reading rather than blanking the panel:
        // an old number with its age on it still beats nothing, and the provenance bar says why.
        adopt(apiSnapshot, org: apiSnapshotOrg)
    }

    private func adopt(_ snap: UsageSnapshot?, org: String?) {
        usage = snap
        liveOrg = org
        if let snap { record(snap, org: org) }
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
    private func record(forOrg org: String) -> AccountRecord? {
        accounts.records.first { $0.key.hasSuffix(":\(org)") }?.value
    }

    /// Accounts other than the one on show, most-recently-seen first — the collapsible strips
    /// beneath it. While a desktop organization holds the live slot, the terminal account is no
    /// longer "the active one": it drops down here with its last-seen numbers, like any other.
    var otherAccounts: [AccountRecord] {
        // No strips while we cannot name who is on show: we would have no way to tell which cached
        // record is the "other" one, and could end up listing the live account beside itself.
        guard liveAccount != nil else { return [] }
        let activeKey = usage?.source == .api ? activeAccount?.key : nil
        let liveSuffix = liveOrg.map { ":\($0)" }
        return accounts.others(activeUuid: activeKey).filter { rec in
            guard let liveSuffix else { return true }
            return !rec.uuid.hasSuffix(liveSuffix)
        }
    }

    /// Plan badge for the active account: the token's own subscriptionType (most accurate, stored
    /// on the last record) falling back to the org type from ~/.claude.json.
    var activePlan: String? {
        guard let id = activeAccount else { return nil }
        return accounts.records[id.key]?.plan ?? id.planFallback
    }

    /// Windows the API had that the desktop feed cannot carry — the per-model weekly caps, and the
    /// extra credit. Drawn faded, with their last value and when it was seen, so that changing
    /// feeds never makes a limit vanish without saying so.
    ///
    /// Only ever from the same organization: another organization's per-model numbers under this
    /// organization's heading would be a different account's data wearing the wrong name.
    /// True while the panel is being carried by the desktop feed, which is the only time anything
    /// is missing and therefore the only time a ghost means something. Every ghost accessor is
    /// gated on it: without the gate the extra credit would draw a second, faded copy of itself
    /// underneath the live one.
    private var showingFallback: Bool { usage?.source == .desktopApp }

    var ghostWindows: [LimitWindow] {
        guard showingFallback, let api = carriedOverAPISnapshot else { return [] }
        // Matching on key alone is not enough: against an older payload shape the same two windows
        // come back as `five_hour`/`seven_day` instead of `session`/`weekly_all`, and every one of
        // them would ghost underneath the live row it duplicates. Match on the role instead.
        return api.windows.filter { !$0.isSession && !Self.weeklyAllKeys.contains($0.key) }
    }

    /// The keys the two windows the desktop feed already carries have gone by.
    private static let weeklyAllKeys: Set<String> = ["weekly_all", "seven_day"]

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
        var covered = Set(accounts.records.keys.compactMap { $0.split(separator: ":").last.map(String.init) })
        if let org = activeAccount?.organizationUuid { covered.insert(org) }
        if let org = liveOrg { covered.insert(org) }
        return desktopOrgs.filter { !covered.contains($0.organizationUuid) }
    }

    /// Cached keychain read. Every SecItemCopyMatching is a potential user-facing prompt (one
    /// per poll adds up fast), so the item is only touched when nothing is cached yet or the
    /// cached token is about to expire.
    private func credentials(bypassingCache: Bool = false) throws -> Keychain.Credentials {
        if !bypassingCache, let cached = cachedCreds, !cached.expiresSoon { return cached }
        let fresh = try Keychain.claudeCredentials()
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
            let fresh = try credentials(bypassingCache: true)
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
            org: org
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

        sessions = ClaudeSessionStore.load()
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

    func revealInActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
