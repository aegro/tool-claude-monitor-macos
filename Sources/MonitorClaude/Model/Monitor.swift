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
            let creds = try Keychain.claudeCredentials()
            let (snap, _) = try await UsageAPI.fetch(token: creds.accessToken)
            usage = snap
            usageError = nil
            record(snap)
        } catch {
            usageError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
