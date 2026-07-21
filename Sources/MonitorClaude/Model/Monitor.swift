import Foundation
import SwiftUI
import AppKit

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

    private var usageInterval: TimeInterval { Settings.shared.usageIntervalSeconds }
    private let ledgerInterval: TimeInterval = 20

    init() {
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

        do {
            let creds = try credentials()
            let snap = try await fetchUsage(creds: creds)
            usage = snap
            usageError = nil
            record(snap)
        } catch {
            usageError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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

    /// Fetches usage, renewing the OAuth token when it is about to expire (proactive) or when
    /// the server rejects it (reactive). On a 401 the keychain is re-read before renewing: the
    /// CLI may have rotated the credential since we cached it, and renewing from a retired
    /// refresh token trips the server's reuse detection. Renewal happens at most once per
    /// call, so a bad refresh token surfaces as a normal error instead of a loop.
    ///
    /// The proactive renewal above is best-effort (`try?`): if it fails partway — the exchange
    /// succeeded server-side (rotating the refresh token) but our local write or response
    /// handling then failed — `current` stays on the old, now-retired refresh token. Retrying
    /// blindly on the 401 below would resubmit that retired token and trip reuse detection for
    /// real. So the reactive path only retries when the keychain reread shows the refresh token
    /// actually changed; otherwise it surfaces the original renewal failure instead of guessing.
    private func fetchUsage(creds: Keychain.Credentials) async throws -> UsageSnapshot {
        var current = creds
        var attemptedRefreshToken: String?
        var renewalError: Error?

        if current.expiresSoon, current.refreshToken != nil {
            attemptedRefreshToken = current.refreshToken
            do {
                current = try await renew(current)
            } catch {
                renewalError = error
            }
        }

        do {
            return try await UsageAPI.fetch(token: current.accessToken).0
        } catch UsageError.unauthorized {
            let fresh = try credentials(bypassingCache: true)
            if fresh.accessToken != current.accessToken {
                return try await UsageAPI.fetch(token: fresh.accessToken).0
            }
            if let renewalError, fresh.refreshToken == attemptedRefreshToken {
                throw renewalError
            }
            let renewed = try await renew(fresh)
            return try await UsageAPI.fetch(token: renewed.accessToken).0
        }
    }

    /// Renews via the refresh token, persists through Keychain.update, and keeps the cache
    /// coherent so the next poll neither re-reads the keychain nor renews from stale state.
    private func renew(_ creds: Keychain.Credentials) async throws -> Keychain.Credentials {
        let renewed = try await OAuthRefresh.renewAndStore(using: creds)
        var next = creds
        next.accessToken = renewed.accessToken
        next.refreshToken = renewed.refreshToken ?? creds.refreshToken
        next.expiresAt = renewed.expiresAt
        cachedCreds = next
        return next
    }

    private func record(_ snap: UsageSnapshot) {
        history.append(UsageSample(
            at: snap.fetchedAt,
            session: snap.session?.utilization,
            sessionResetsAt: snap.session?.resetsAt,
            weekly: snap.weekly?.utilization,
            tokensCumulative: ledger.block.total
        ))
        history.flush()
    }

    // MARK: derived

    var sessionBurn: BurnRate? { history.burnRate(\.session) }
    var weeklyBurn: BurnRate? { history.burnRate(\.weekly, window: 6 * 3600, minPoints: 8, minSpan: 3600) }

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
        return history.series(\.session, since: reset.addingTimeInterval(-5 * 3600))
    }

    var weekTrail: [(Date, Double)] {
        history.series(\.weekly, since: Date().addingTimeInterval(-7 * 24 * 3600))
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
