import Foundation

/// The accounts as one ordered queue: the route above the divider, the reserve below it, and the rule that picks
/// where new sessions open. Pure, so the panel, the settings window and the tests read the same answers.
struct AccountQueue: Equatable {
    struct Entry: Identifiable, Equatable {
        var id: String
        var label: String
        var monogram: String
        var role: AccountRouter.Account.Role
        var plan: String?
        var email: String?
        var organization: String?
        var snapshot: UsageSnapshot?
        var hasLogin: Bool
        var agentsLogin: Bool
        var exhaustedUntil: Date?
        var sessions: Int = 0
        /// Whether the agents of `claude agents` run on this account now (its login is in `~/.claude`).
        var runsAgents = false
        /// This entry is the account whose numbers the Monitor reads live.
        var isLive = false
        /// Its token expired for lack of use: the numbers wait for the next session on it.
        var loginIdle = false
        /// macOS was asked to let its login be read and refused (or nobody answered): "Ler de novo" asks again.
        var loginRefused = false

        var headroom: Double? { snapshot.map { AccountRouter.headroom($0) } }
    }

    var entries: [Entry]
    var strategy: AccountRouter.Strategy
    var enabled: Bool
    var reserveBelow: Double = 3
    /// The queue comes from the router's config; without one there is a single, implicit entry.
    var configured: Bool
    /// The account in `~/.claude`: with switching off, the router hands everything to plain `claude`, which opens
    /// there whatever the order of the queue.
    var principal: String?

    var route: [Entry] { entries.filter { $0.role == .route } }
    var reserve: [Entry] { entries.filter { $0.role == .reserve } }
    var isSingle: Bool { entries.count <= 1 }

    private var config: AccountRouter.Config {
        AccountRouter.Config(
            enabled: enabled,
            principal: entries.first?.id ?? "principal",
            accounts: entries.map {
                AccountRouter.Account(id: $0.id, label: $0.label, directory: URL(fileURLWithPath: "/"),
                                      usesDefaultDirectory: false, role: $0.role, monogram: $0.monogram)
            },
            reserveBelow: reserveBelow,
            preferred: strategy == .order ? route.first?.id : nil)
    }

    private func pick(excluding: Set<String>, now: Date) -> String? {
        var exhausted: [String: Date] = [:]
        for e in entries {
            if let until = e.exhaustedUntil, until > now { exhausted[e.id] = until }
            if excluding.contains(e.id) { exhausted[e.id] = .distantFuture }
        }
        return AccountRouter.pick(config,
                                  headroom: Dictionary(uniqueKeysWithValues: entries.compactMap { e in e.headroom.map { (e.id, $0) } }),
                                  available: Set(entries.filter(\.hasLogin).map(\.id)),
                                  exhausted: exhausted)
    }

    /// Where a session opened now lands. With switching off, always the principal (`~/.claude`).
    func newSessions(now: Date = Date()) -> String? {
        guard enabled, configured, !isSingle else {
            return principal.flatMap { id in entries.contains { $0.id == id } ? id : nil } ?? entries.first?.id
        }
        return pick(excluding: [], now: now)
    }

    /// Who takes over if `id` hits its limit, or nil when nobody can.
    func next(after id: String?, now: Date = Date()) -> String? {
        guard enabled, configured, let id else { return nil }
        return pick(excluding: [id], now: now)
    }

    func entry(_ id: String?) -> Entry? { entries.first { $0.id == id } }

    // MARK: editing

    /// The queue with `id` moved to `index` in the combined list, where `dividerIndex` marks where the reserve
    /// starts. Returns nil when the move would leave the route empty.
    static func moving(_ ids: [String], reserveFrom divider: Int, id: String, to index: Int) -> (route: [String], reserve: [String])? {
        guard let from = ids.firstIndex(of: id) else { return nil }
        var list = ids.map { Optional($0) }
        list.insert(nil, at: min(max(divider, 0), list.count))
        let fromSlot = from >= divider ? from + 1 : from
        let item = list.remove(at: fromSlot)
        let target = min(max(index, 0), list.count)
        list.insert(item, at: target)
        guard let split = list.firstIndex(where: { $0 == nil }) else { return nil }
        let route = list[..<split].compactMap { $0 }
        let reserve = list[list.index(after: split)...].compactMap { $0 }
        guard !route.isEmpty else { return nil }
        return (route, reserve)
    }

    /// Dropping `id` on the row (or the divider) at `index` of the combined list: on which edge of the target it
    /// lands, and whether the drop changes anything. Coming from above, `moving` puts the account after the target
    /// (at the head of the reserve, for the divider); from below, before it. A drop that keeps the order, or would
    /// leave the route empty, changes nothing and is refused.
    struct Landing: Equatable {
        var below: Bool
        var changes: Bool
    }

    static func landing(_ ids: [String], reserveFrom divider: Int, id: String, on index: Int) -> Landing? {
        guard let from = ids.firstIndex(of: id) else { return nil }
        let slot = from >= divider ? from + 1 : from
        let split = min(max(divider, 0), ids.count)
        let changes = moving(ids, reserveFrom: divider, id: id, to: index).map {
            $0.route != Array(ids[..<split]) || $0.reserve != Array(ids[split...])
        } ?? false
        return Landing(below: slot < index, changes: changes)
    }

    // MARK: words

    /// The sentence under the account name: time first (from the live outlook), then who comes next.
    static func statusLine(queue: AccountQueue, inUse: String?, outlook: Monitor.Outlook?, now: Date = Date()) -> String {
        var parts: [String] = []
        if let entry = queue.entry(inUse) {
            if let until = entry.exhaustedUntil, until > now {
                parts.append("Esgotada até \(Fmt.clock(until)).")
            } else if entry.isLive, let outlook {
                switch outlook {
                case .safe(_, let reset):
                    parts.append("Dá para ir até o reset das \(Fmt.clock(now.addingTimeInterval(reset))).")
                case .willHitCap(let exhaust, let reset, _, _, _):
                    parts.append("No ritmo atual, acaba às \(Fmt.clock(now.addingTimeInterval(exhaust))); renova às \(Fmt.clock(now.addingTimeInterval(reset))).")
                case .measuring:
                    parts.append("Medindo o ritmo desta janela.")
                case .idle:
                    break
                }
            } else if queue.strategy == .headroom, queue.enabled, let room = entry.headroom, !queue.isSingle {
                parts.append("É a que tem mais folga agora (\(Fmt.pct(room))).")
            }
        }
        guard queue.configured, !queue.isSingle else { return parts.joined(separator: " ") }
        guard queue.enabled else {
            parts.append("A troca automática está desligada: as sessões ficam nesta conta.")
            return parts.joined(separator: " ")
        }
        if let next = queue.entry(queue.next(after: inUse, now: now)) {
            let fromReserve = next.role == .reserve ? ", da reserva" : ""
            parts.append("Se bater o limite, segue na \(next.label)\(fromReserve).")
        } else {
            parts.append("Se bater o limite, não há outra conta com folga.")
        }
        return parts.joined(separator: " ")
    }
}
