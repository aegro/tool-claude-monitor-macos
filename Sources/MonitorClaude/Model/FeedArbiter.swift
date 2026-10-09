import Foundation

/// Which feed the panel draws from, as a pure function of what each one is offering.
///
/// Pulled out of `Monitor` deliberately. This is the most consequential decision in the app — it
/// picks the numbers the user acts on — and every serious defect this feature shipped with lived
/// right here: adopting a days-old reading over a two-minute-old one, marking a frozen feed live,
/// leaving a branch unreachable. None of it was catchable by a test, because the logic sat on a
/// `@MainActor` class fed by the Keychain, the network and another application's files.
///
/// The rules, in order:
///
/// 1. **The API when it is current.** It is the only feed carrying the per-model windows, the
///    server's own severity and the extra credit.
/// 2. **The desktop app when *it* is current.** Same server numbers, five-minute cadence, no
///    credential involved.
/// 3. **Otherwise the freshest thing held**, carrying the health that goes with it — an old number
///    wearing its age beats a blank panel, but it must never be dressed as live.
enum FeedArbiter {
    struct Offer: Equatable {
        var snapshot: UsageSnapshot
        var org: String?
    }

    struct Choice: Equatable {
        var snapshot: UsageSnapshot?
        var org: String?
        var health: FeedState.Health

        static let nothing = Choice(snapshot: nil, org: nil, health: .missing)
    }

    static func choose(api: Offer?, terminal: FeedState.Health,
                       desktop: Offer?, desktopHealth: FeedState.Health) -> Choice {
        if case .live = terminal, let api {
            return Choice(snapshot: api.snapshot, org: api.org, health: terminal)
        }
        if case .live = desktopHealth, let desktop {
            return Choice(snapshot: desktop.snapshot, org: desktop.org, health: desktopHealth)
        }

        let held = [api.map { ($0, terminal) }, desktop.map { ($0, desktopHealth) }].compactMap { $0 }
        guard let best = held.max(by: { $0.0.snapshot.fetchedAt < $1.0.snapshot.fetchedAt }) else {
            return .nothing
        }
        return Choice(snapshot: best.0.snapshot, org: best.0.org, health: best.1)
    }

    /// The organization the desktop app is currently driving: the one it sampled most recently.
    /// Ties break on the uuid, because `Dictionary` has no iteration order and the alternative is
    /// the whole panel swapping to a different organization between launches.
    static func newestOrg(in byOrg: [String: [DesktopSample]]) -> (org: String, at: Date)? {
        byOrg
            .compactMap { org, series in series.last.map { (org: org, at: $0.at) } }
            .max { ($0.at, $1.org) < ($1.at, $0.org) }
    }
}

/// What the terminal poll does on one round, as a pure function of what it holds: the live numbers a stream session
/// received, the last numbers read, when `/usage` last answered, and any pause the server asked for.
///
/// The rules, in order:
///
/// 1. **Fresh live numbers, and no whole read due (or a pause asked for):** take them, no request. They are seconds
///    old while a session works, and they spend nothing of the endpoint's tight limit.
/// 2. **A pause asked for:** no request. Live numbers newer than the last read still go in, wearing their age.
/// 3. **Otherwise ask `/usage`.** If that fails, the live numbers stand in the same way.
enum TerminalPlan: Equatable {
    /// What to do with the live numbers when no whole read lands this round.
    enum Live: Equatable {
        /// Newer than anything held and recent: shown as live.
        case current
        /// Newer than anything held but not recent: shown with their age, the feed still not live.
        case older
        /// Nothing newer than what is held.
        case none
    }

    case takeLive
    case wait(until: Date, live: Live)
    case read(otherwise: Live)

    static func plan(live: Date?, held: Date?, lastFullRead: Date?, pause: Date?, now: Date,
                     interval: TimeInterval) -> TerminalPlan {
        let liveState: Live
        if let live, live > (held ?? .distantPast) {
            liveState = now.timeIntervalSince(live) < max(60, interval) ? .current : .older
        } else {
            liveState = .none
        }
        let fullDue = lastFullRead.map { now.timeIntervalSince($0) >= fullReadInterval(interval) } ?? true
        let paused = pause.flatMap { $0 > now ? $0 : nil }
        if liveState == .current, !fullDue || paused != nil { return .takeLive }
        if let paused { return .wait(until: paused, live: liveState) }
        return .read(otherwise: liveState)
    }

    /// How often a whole `/usage` read runs while live numbers keep arriving: those carry only the session and the
    /// weekly window, and this read brings the per-model windows and the extra credit.
    static func fullReadInterval(_ interval: TimeInterval) -> TimeInterval { max(600, interval) }
}
