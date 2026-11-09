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
        /// Why the router set it aside until `exhaustedUntil` (`esgotadas.json`): a limit, or `auth`, `cobranca`,
        /// `conta_suspensa`.
        var exhaustedReason: String? = nil
        var sessions: Int = 0
        /// Sessions running with this account's folder as their config directory, whatever account they were opened
        /// on: the account cannot leave the queue while they run, since its folder would go to the Trash under them.
        var sessionsInFolder: Int = 0
        /// Whether the agents of `claude agents` run on this account now (its login is in `~/.claude`).
        var runsAgents = false
        /// This entry is the account whose numbers the Monitor reads live.
        var isLive = false
        /// Its token expired for lack of use: the numbers wait for the router to renew it (`refresh` says how that went).
        var loginIdle = false
        /// The router's last renewal of this account's expired login, if any.
        var refresh: AccountRouter.LoginRefresh?
        /// The router renews this account's login when it expires (`claude-accounts refresh`): not the one in
        /// `~/.claude`, whose own sessions renew it.
        var renewable = true
        /// macOS was asked to let its login be read and refused (or nobody answered): "Ler de novo" asks again.
        var loginRefused = false

        var headroom: Double? { snapshot.map { AccountRouter.headroom($0) } }

        /// Set aside until `exhaustedUntil`, as of `now`.
        func isExhausted(at now: Date = Date()) -> Bool { exhaustedUntil.map { $0 > now } ?? false }

        /// What set it aside, in a word for the state chip: a limit is "esgotada", but a login the server refused is
        /// not a limit and does not come back at `exhaustedUntil` by itself (07/11/2026: "esgotada, volta às 02:10"
        /// on an account that had lost its login).
        var asideChip: String {
            switch exhaustedReason {
            case "auth": "pediu login"
            case "cobranca": "cobrança"
            case "conta_suspensa": "suspensa"
            default: "esgotada"
            }
        }

        /// The line under a set-aside account: when it comes back, or what to do when a time is not the answer.
        func asideLine(until: Date) -> String {
            switch exhaustedReason {
            case "auth": "o servidor recusou o login: autorize de novo em Contas e logins"
            case "cobranca": "erro de cobrança nesta conta · tenta de novo às \(Fmt.stamp(until))"
            case "conta_suspensa": "conta suspensa · tenta de novo às \(Fmt.stamp(until))"
            default: "volta às \(Fmt.stamp(until))"
            }
        }
    }

    var entries: [Entry]
    var strategy: AccountRouter.Strategy
    var enabled: Bool
    var reserveBelow: Double = 3
    /// `limites.voltar` (see `AccountRouter.Config.comfortableFrom`).
    var comfortableFrom: Double = 20
    /// The queue comes from the router's config; without one there is a single, implicit entry.
    var configured: Bool
    /// The account in `~/.claude`: with switching off, the router hands everything to plain `claude`, which opens
    /// there whatever the order of the queue.
    var principal: String?
    /// Chosen by hand to take new sessions, above the rule (see `AccountRouter.Config.pinned`).
    var pinned: String?
    /// The account the agents of `claude agents` run on now (see `AccountRouter.agentsAccount`).
    var agents: String?

    /// Why an account cannot leave the queue now, or nil when it can: its folder would go to the Trash under
    /// sessions still running with it.
    static func removalBlocked(sessions: Int) -> String? {
        switch sessions {
        case 0: nil
        case 1: "1 sessão ainda roda com a pasta desta conta. Feche-a antes de tirar a conta da fila: a pasta iria para o Lixo com ela aberta."
        default: "\(sessions) sessões ainda rodam com a pasta desta conta. Feche-as antes de tirar a conta da fila: a pasta iria para o Lixo com elas abertas."
        }
    }

    /// What a settings row sends to `renameAccount` when it leaves editing, or nil when there is nothing to save.
    /// Only an edit by the person saves (`edited`): a row nobody touched never writes, whatever another account's
    /// save did to what it shows, and an edit always does, even one that goes back to the saved pair before an
    /// earlier save of it has landed. The name is trimmed, and an empty one stays empty, which `renameAccount` reads
    /// as "keep the saved name" (so a stale copy of it is never written back); the monogram is trimmed, cut to three
    /// characters and put in capitals, as `renameAccount` stores it (empty = derived from the name).
    static func renameToSave(name: String, monogram: String, edited: Bool) -> (name: String, monogram: String)? {
        guard edited else { return nil }
        let sigla = String(monogram.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3)).uppercased()
        return (name.trimmingCharacters(in: .whitespacesAndNewlines), sigla)
    }

    /// What removing an account does, said the same way wherever the removal is confirmed.
    static let removalConsequence = "A pasta da conta vai para o Lixo e o login fica no Keychain: trazer a pasta de volta traz a conta."

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
            preferred: strategy == .order ? route.first?.id : nil,
            comfortableFrom: comfortableFrom,
            pinned: pinned)
    }

    private func pick(excluding: Set<String>, now: Date) -> String? {
        var exhausted: [String: Date] = [:]
        for e in entries {
            if let until = e.exhaustedUntil, until > now { exhausted[e.id] = until }
            if excluding.contains(e.id) { exhausted[e.id] = .distantFuture }
        }
        return AccountRouter.pick(config,
                                  usage: Dictionary(uniqueKeysWithValues: entries.compactMap { e in e.snapshot.map { (e.id, $0) } }),
                                  available: Set(entries.filter(\.hasLogin).map(\.id)),
                                  exhausted: exhausted, now: now)
    }

    /// Where a session opened now lands. With switching off, always the principal (`~/.claude`).
    func newSessions(now: Date = Date()) -> String? {
        guard enabled, configured, !isSingle else {
            return principal.flatMap { id in entries.contains { $0.id == id } ? id : nil } ?? entries.first?.id
        }
        return pick(excluding: [], now: now)
    }

    /// The account the widget is about (menu bar, top of the Contas tab, highlighted row, freshness footer): the one
    /// chosen by hand while new sessions still open there, else the one the agents run on.
    func focus(now: Date = Date()) -> String? {
        let opens = newSessions(now: now)
        if let pinned, opens == pinned { return pinned }
        return agents.flatMap { id in entries.contains { $0.id == id } ? id : nil } ?? opens
    }

    /// Who takes over if `id` hits its limit, or nil when nobody can. The agents only move to an account with an agents
    /// login, so after theirs only those count.
    func next(after id: String?, now: Date = Date()) -> String? {
        guard enabled, configured, let id else { return nil }
        let noAgentsLogin = id == agents ? entries.filter { !$0.agentsLogin }.map(\.id) : []
        return pick(excluding: Set([id] + noAgentsLogin), now: now)
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

    /// The caption over the account the widget is about.
    static func focusCaption(queue: AccountQueue, focus: String?) -> String {
        guard queue.configured, !queue.isSingle else { return "As sessões abrem na" }
        if queue.enabled, let pinned = queue.pinned, pinned == focus { return "Você escolheu: sessões novas abrem na" }
        if let agents = queue.agents, agents == focus { return "Agentes e sessões em segundo plano rodam na" }
        return queue.enabled ? "Sessões novas abrem na" : "As sessões abrem na"
    }

    /// The other account in use, when there is one: the terminal's new sessions, or the agents while a hand-picked
    /// account takes the headline. `claude agents` does not follow the terminal's rule, so the two can differ.
    static func terminalNote(queue: AccountQueue, focus: String?, terminal: String?) -> String? {
        guard queue.configured, !queue.isSingle else { return nil }
        if let terminal, terminal != focus, let entry = queue.entry(terminal) {
            let rule = queue.strategy == .headroom ? "a de mais folga até renovar" : "a primeira da fila com folga"
            let stay = focus.flatMap { queue.entry($0) }.map { agents in
                queue.strategy == .headroom && queue.pinned == nil
                    ? "Os agentes ficam na \(agents.label) até ela chegar perto do limite ou outra conta da rota, com folga de sobra, render pelo menos o dobro até renovar."
                    : "Os agentes ficam na \(agents.label) até ela chegar no limite e só então trocam."
            }
            return (["Cada claude novo no terminal abre na \(entry.label), \(rule)."] + [stay].compactMap { $0 }).joined(separator: " ")
        }
        if let agents = queue.agents, agents != focus, let entry = queue.entry(agents) {
            return "Os agentes continuam na \(entry.label) até ela chegar no limite."
        }
        return nil
    }

    /// Why an account with an expired login has no fresh numbers, and what to do about it.
    static func idleReason(_ refresh: AccountRouter.LoginRefresh?, id: String, renewable: Bool = true) -> String {
        guard renewable else { return "login vencido, volta na próxima sessão nela" }
        switch refresh?.outcome {
        case nil: return "login vencido, o roteador renova em instantes"
        case .renewed: return "login renovado, lendo de novo"
        case .inUse: return "login vencido, renova na próxima resposta da sessão aberta nela"
        case .failed(let why): return "o login venceu e não renovou (\(why)): rode claude-accounts login \(id)"
        }
    }

    /// The sentence under the account name: time first (from the live outlook), then who comes next.
    static func statusLine(queue: AccountQueue, inUse: String?, outlook: Monitor.Outlook?, now: Date = Date()) -> String {
        var parts: [String] = []
        if let entry = queue.entry(inUse) {
            if let until = entry.exhaustedUntil, until > now {
                switch entry.exhaustedReason {
                case "auth": parts.append("O servidor recusou o login desta conta.")
                case "cobranca": parts.append("Erro de cobrança até \(Fmt.clock(until)).")
                case "conta_suspensa": parts.append("Conta suspensa até \(Fmt.clock(until)).")
                default: parts.append("Esgotada até \(Fmt.clock(until)).")
                }
            } else if entry.isLive, let outlook {
                switch outlook {
                case .safe(_, let reset, let window):
                    let at = now.addingTimeInterval(reset)
                    parts.append(window.isSession ? "Dá para ir até o reset das \(Fmt.clock(at))."
                                                  : "Dá para ir até o reset da semana, \(Fmt.weekday(at, now: now)).")
                case .willHitCap(let exhaust, let reset, _, _, _, let window):
                    let ends = now.addingTimeInterval(exhaust), renews = now.addingTimeInterval(reset)
                    if window.isSession {
                        parts.append("No ritmo atual, acaba às \(Fmt.clock(ends)); renova às \(Fmt.clock(renews)).")
                    } else {
                        let endsText = Calendar.current.isDate(ends, inSameDayAs: now) ? "às \(Fmt.clock(ends))" : Fmt.weekday(ends, now: now)
                        parts.append("No ritmo atual, a semana acaba \(endsText); renova \(Fmt.weekday(renews, now: now)).")
                    }
                case .measuring:
                    parts.append("Medindo o ritmo desta janela.")
                case .idle:
                    break
                }
            } else if queue.strategy == .headroom, queue.enabled, inUse == queue.newSessions(now: now),
                      let room = entry.headroom, !queue.isSingle {
                parts.append(room >= queue.comfortableFrom ? "É a que tem mais folga por hora até a semana renovar."
                                                           : "É a que tem mais folga agora (\(Fmt.pct(room))).")
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
