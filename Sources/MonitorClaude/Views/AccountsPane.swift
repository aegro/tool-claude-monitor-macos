import SwiftUI
import UniformTypeIdentifiers

/// "Contas": where new sessions open, in words and with the time it buys, and the queue that decides who takes
/// over. Drag a row to change the priority; below the divider is the reserve.
struct AccountsPane: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var settings = Settings.shared
    var openSettings: () -> Void

    @State private var expanded: String?
    @State private var dragging: String?
    /// The row (or the divider, as "divider") a dragged account would land on, for the insertion line.
    @State private var dropTarget: String?
    /// The account whose removal waits for a confirmation under its row.
    @State private var confirmingRemoval: String?

    var body: some View {
        let queue = monitor.accountQueue
        let inUse = queue.newSessions()
        let next = queue.next(after: inUse)

        VStack(alignment: .leading, spacing: 12) {
            status(queue: queue, inUse: inUse)

            if let error = monitor.actionError {
                NoteBox(text: error, tone: Ink.alarm, icon: "exclamationmark.triangle")
            }
            if let problem = monitor.routerConfigProblem {
                NoteBox(text: "\(problem). Corrija o arquivo para a fila voltar a aparecer.", tone: Ink.alarm,
                        icon: "exclamationmark.triangle")
            }

            if queue.isSingle {
                if let entry = queue.entries.first {
                    row(entry, index: 0, inUse: inUse, next: nil, queue: queue)
                }
                // Adding an account rewrites the config: not while it does not read.
                if monitor.routerConfigProblem == nil { invite }
            } else {
                HStack {
                    Text("Fila").font(Type.groupTitle).foregroundStyle(.secondary)
                    Spacer()
                    strategyMenu(queue)
                }
                VStack(spacing: 3) {
                    ForEach(Array(queue.route.enumerated()), id: \.element.id) { i, entry in
                        row(entry, index: i, inUse: inUse, next: next, queue: queue)
                    }
                    divider(index: queue.route.count, queue: queue)
                    ForEach(Array(queue.reserve.enumerated()), id: \.element.id) { i, entry in
                        row(entry, index: queue.route.count + 1 + i, inUse: inUse, next: next, queue: queue)
                    }
                }
                // A drag dropped outside the list never reaches `performDrop`: the first move of the mouse with the
                // button up ends it, so the row does not stay faded.
                .onContinuousHover { _ in
                    guard dragging != nil, NSEvent.pressedMouseButtons == 0 else { return }
                    dragging = nil
                    dropTarget = nil
                }
                addButton
            }
        }
    }

    // MARK: status

    @ViewBuilder
    private func status(queue: AccountQueue, inUse: String?) -> some View {
        let entry = queue.entry(inUse)
        let byHand = queue.enabled && queue.pinned != nil && queue.pinned == inUse
        VStack(alignment: .leading, spacing: 6) {
            StatusBlock(
                caption: queue.isSingle || !queue.enabled ? "As sessões abrem na" : (byHand ? "Você escolheu: sessões novas abrem na" : "Sessões novas abrem na"),
                headline: entry?.label ?? "nenhuma conta com folga",
                line: AccountQueue.statusLine(queue: queue, inUse: inUse, outlook: monitor.outlook),
                tone: entry == nil ? Ink.alarm : .primary)
            if queue.enabled, let pinned = queue.pinned {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Ink.ember)
                    Text(pinnedNote(queue: queue, pinned: pinned, inUse: inUse))
                        .font(Type.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Voltar à regra") { Task { await monitor.pinAccount(nil) } }
                        .controlSize(.small)
                }
            }
        }
    }

    /// Why the hand-picked account is not the one in use: a lost login asks for authorization, not for waiting.
    private func pinnedNote(queue: AccountQueue, pinned: String, inUse: String?) -> String {
        if pinned == inUse { return "Fora da regra da fila, até você voltar." }
        let entry = queue.entry(pinned)
        let name = entry?.label ?? pinned
        if entry?.hasLogin == false {
            return "\(name) está sem login: a regra da fila decide até você autorizá-la de novo."
        }
        return "\(name) está sem folga: a regra da fila decide até ela voltar."
    }

    private func strategyMenu(_ queue: AccountQueue) -> some View {
        Menu {
            ForEach(AccountRouter.Strategy.allCases) { strategy in
                Button {
                    Task { await monitor.setStrategy(strategy) }
                } label: {
                    if queue.strategy == strategy { Label(strategy.label, systemImage: "checkmark") } else { Text(strategy.label) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(queue.strategy.label).font(Type.caption)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5))
            }
            .foregroundStyle(Ink.ember)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!queue.enabled)
        .help(queue.enabled ? "Como a conta das sessões novas é escolhida" : "Ligue a troca automática para escolher a regra")
    }

    // MARK: rows

    private func row(_ entry: AccountQueue.Entry, index: Int, inUse: String?, next: String?, queue: AccountQueue) -> some View {
        AccountRow(entry: entry, inUse: entry.id == inUse, next: entry.id == next && !queue.isSingle,
                   draggable: !queue.isSingle, expanded: expanded == entry.id,
                   pinned: queue.enabled && queue.pinned == entry.id,
                   bgAgents: monitor.sessions.contains(where: \.isBackground),
                   monitor: monitor) {
            withAnimation(.easeOut(duration: 0.15)) { expanded = expanded == entry.id ? nil : entry.id }
        }
        .opacity(dragging == entry.id ? 0.45 : 1)
        .overlay(alignment: landingEdge(index, queue: queue) == .top ? .top : .bottom) {
            insertionLine(visible: dropTarget == entry.id, edge: landingEdge(index, queue: queue))
        }
        .onDrag {
            dragging = entry.id
            return NSItemProvider(object: entry.id as NSString)
        }
        .onDrop(of: [UTType.text], delegate: QueueDrop(targetIndex: index, targetId: entry.id, monitor: monitor,
                                                       allowed: moves(to: index, queue: queue),
                                                       dragging: $dragging, dropTarget: $dropTarget))
        .contextMenu { menu(entry, index: index, queue: queue) }
        .safeAreaInset(edge: .bottom, spacing: 4) {
            if confirmingRemoval == entry.id {
                removalConfirmation(entry)
            } else if expanded == entry.id, queue.configured, !queue.isSingle {
                actions(entry, queue: queue)
            }
        }
    }

    /// What can be done with an account, under its open detail: where the click already led.
    private func actions(_ entry: AccountQueue.Entry, queue: AccountQueue) -> some View {
        HStack(spacing: 8) {
            if queue.enabled {
                if queue.pinned == entry.id {
                    Button("Voltar à regra") { Task { await monitor.pinAccount(nil) } }
                } else {
                    Button("Usar esta agora") { Task { await monitor.pinAccount(entry.id) } }
                        .buttonStyle(.borderedProminent).tint(Ink.ember)
                        .disabled(!entry.hasLogin)
                        .help("Sessões novas abrem nesta conta, fora da regra da fila, até você voltar ou ela ficar sem folga")
                }
            }
            Spacer()
            if entry.id != queue.principal {
                Button("Remover da fila…") { withAnimation(.easeOut(duration: 0.15)) { confirmingRemoval = entry.id } }
                    .buttonStyle(.plain).font(Type.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.leading, 47)
        .padding(.trailing, 9)
        .padding(.bottom, 6)
    }

    /// Asked under the row, not in a dialog, which would close the menu bar panel.
    private func removalConfirmation(_ entry: AccountQueue.Entry) -> some View {
        let blocked = AccountQueue.removalBlocked(sessions: entry.sessionsInFolder)
        return VStack(alignment: .leading, spacing: 8) {
            Text(blocked ?? "Tirar \(entry.label) da fila? A pasta da conta vai para o Lixo e o login fica no Keychain: trazer a pasta de volta traz a conta.")
                .font(Type.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancelar") { confirmingRemoval = nil }.controlSize(.small)
                Button("Remover") {
                    confirmingRemoval = nil
                    Task { await monitor.removeAccount(entry.id) }
                }
                .controlSize(.small).buttonStyle(.borderedProminent).tint(Ink.alarm)
                .disabled(blocked != nil)
            }
        }
        .padding(10)
        .background(Ink.track, in: RoundedRectangle(cornerRadius: 9))
        .padding(.leading, 30)
    }

    @ViewBuilder
    private func menu(_ entry: AccountQueue.Entry, index: Int, queue: AccountQueue) -> some View {
        if !queue.isSingle, queue.enabled {
            if queue.pinned == entry.id {
                Button("Voltar à regra da fila") { Task { await monitor.pinAccount(nil) } }
            } else {
                Button("Usar esta agora") { Task { await monitor.pinAccount(entry.id) } }.disabled(!entry.hasLogin)
            }
            Divider()
        }
        if !queue.isSingle {
            Button("Subir") { Task { await monitor.moveAccount(entry.id, to: max(0, index - 1)) } }
                .disabled(index == 0)
            Button("Descer") { Task { await monitor.moveAccount(entry.id, to: index + 1) } }
            if entry.role == .route {
                Button("Mover para a reserva") { Task { await monitor.moveAccount(entry.id, to: queue.entries.count) } }
                    .disabled(queue.route.count <= 1)
            } else {
                Button("Mover para a rota") { Task { await monitor.moveAccount(entry.id, to: queue.route.count) } }
            }
            Divider()
        }
        if queue.configured {
            if !entry.hasLogin, entry.loginRefused {
                Button("Ler de novo") { Task { await monitor.readAgain() } }
            } else if !entry.hasLogin {
                Button("Autorizar de novo…") { monitor.startReauthorize(entry.id, agents: false); openSettings() }
            }
            if entry.hasLogin, !entry.agentsLogin {
                Button("Autorizar os agentes…") { monitor.startReauthorize(entry.id, agents: true); openSettings() }
            }
            Button("Renomear…") { monitor.settingsTab = .accounts; openSettings() }
            if entry.id != queue.principal {
                Divider()
                Button("Remover da fila…") { withAnimation(.easeOut(duration: 0.15)) { confirmingRemoval = entry.id } }
            }
        }
    }

    private func divider(index: Int, queue: AccountQueue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Reserva").font(Type.captionMedium).foregroundStyle(.secondary)
            Text("só quando as outras acabarem").font(Type.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.leading, 30)
        .padding(.top, 9)
        .padding(.bottom, queue.reserve.isEmpty ? 10 : 3)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                .mask(HStack(spacing: 3) { ForEach(0..<80, id: \.self) { _ in Rectangle().frame(width: 3) } })
        }
        .contentShape(Rectangle())
        .overlay(alignment: landingEdge(index, queue: queue) == .top ? .top : .bottom) {
            insertionLine(visible: dropTarget == "divider", edge: landingEdge(index, queue: queue))
        }
        .onDrop(of: [UTType.text], delegate: QueueDrop(targetIndex: index, targetId: "divider", monitor: monitor,
                                                       allowed: moves(to: index, queue: queue),
                                                       dragging: $dragging, dropTarget: $dropTarget))
        .accessibilityElement(children: .combine)
    }

    private func insertionLine(visible: Bool, edge: VerticalEdge) -> some View {
        Capsule().fill(Ink.ember).frame(height: 2).padding(.horizontal, 4).offset(y: edge == .top ? -2 : 2)
            .opacity(visible ? 1 : 0).allowsHitTesting(false)
    }

    /// Where the dragged account would land if dropped on `index`, and whether that changes the queue.
    private func landing(_ index: Int, queue: AccountQueue) -> AccountQueue.Landing? {
        guard let id = dragging else { return nil }
        let route = queue.route.map(\.id)
        return AccountQueue.landing(route + queue.reserve.map(\.id), reserveFrom: route.count, id: id, on: index)
    }

    private func landingEdge(_ index: Int, queue: AccountQueue) -> VerticalEdge {
        landing(index, queue: queue)?.below == true ? .bottom : .top
    }

    private func moves(to index: Int, queue: AccountQueue) -> Bool {
        landing(index, queue: queue)?.changes == true
    }

    private var addButton: some View {
        Button {
            monitor.startAddAccount()
            openSettings()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("Adicionar conta").font(Type.body)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var invite: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Tem outra conta do Claude? Adicione aqui e o Monitor troca sozinho quando o limite bater, sem você parar a sessão.")
                .font(Type.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Adicionar conta") {
                monitor.startAddAccount()
                openSettings()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(Ink.ember)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.track, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Drops a dragged account at `targetIndex` of the combined list (route, divider, reserve), drawing the
/// insertion line where it would land while the drag hovers the target. A drop that would change nothing, or
/// empty the route, is refused instead of failing after the fact.
private struct QueueDrop: DropDelegate {
    let targetIndex: Int
    let targetId: String
    let monitor: Monitor
    let allowed: Bool
    @Binding var dragging: String?
    @Binding var dropTarget: String?

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        let id = dragging
        dragging = nil
        guard let id, allowed else { return false }
        Task { @MainActor in await monitor.moveAccount(id, to: targetIndex) }
        return true
    }

    func dropEntered(info: DropInfo) {
        guard allowed else { return }
        withAnimation(.easeOut(duration: 0.1)) { dropTarget = targetId }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: allowed ? .move : .forbidden) }

    func dropExited(info: DropInfo) {
        if dropTarget == targetId { withAnimation(.easeOut(duration: 0.1)) { dropTarget = nil } }
    }
}

/// One account in the queue: who it is, its state, the two windows, and a line of context. Clicking opens the
/// full detail (the live gauge and graph for the account the Monitor reads live, the last reading otherwise).
struct AccountRow: View {
    let entry: AccountQueue.Entry
    let inUse: Bool
    let next: Bool
    let draggable: Bool
    let expanded: Bool
    let pinned: Bool
    let bgAgents: Bool
    let monitor: Monitor
    var toggle: () -> Void

    @State private var hovering = false

    private var exhausted: Bool { entry.exhaustedUntil.map { $0 > Date() } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 26)
                    .contentShape(Rectangle())
                    .overlay { if draggable { CursorRegion(cursor: .openHand) } }
                    .opacity(draggable ? (hovering ? 1 : 0.55) : 0)
                    .help(draggable ? "Arraste para mudar a ordem" : "")
                Avatar(monogram: entry.monogram, active: inUse)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(entry.label).font(Type.strong).lineLimit(1).truncationMode(.tail)
                        if let plan = entry.plan { PlanTag(plan: plan) }
                        if pinned {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Ink.ember)
                                .help("Escolhida por você para as sessões novas")
                        }
                        Spacer(minLength: 4)
                        chip
                        // Says the row opens: without it, the detail under a click was a secret.
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(hovering || expanded ? Color.secondary : Color.secondary.opacity(0.45))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .animation(.easeOut(duration: 0.15), value: expanded)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: 14) {
                        MiniLimit(label: "5h", window: entry.snapshot?.session)
                        MiniLimit(label: "Semana", window: entry.snapshot?.weekly)
                    }
                    Text(subline)
                        .font(Type.mini)
                        .foregroundStyle(exhausted || !entry.hasLogin ? Ink.alarm : Color.secondary.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 9)
            .padding(.leading, 3)
            .padding(.trailing, 9)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(inUse ? Color(nsColor: .controlBackgroundColor).opacity(0.9) : (hovering ? Ink.track.opacity(0.6) : .clear))
                    .shadow(color: .black.opacity(inUse ? 0.06 : 0), radius: 1, y: 0.5)
            }
            .overlay {
                if inUse { RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08), lineWidth: 1) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: toggle)
            .help(expanded ? "Clique para fechar o detalhe" : "Clique para ver o detalhe dos limites")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Abre o detalhe dos limites")

            if expanded {
                AccountDetail(entry: entry, monitor: monitor)
                    .padding(.leading, 47)
                    .padding(.trailing, 9)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var chip: some View {
        if exhausted {
            StateChip(text: "esgotada", tone: .gone)
        } else if !entry.hasLogin {
            StateChip(text: entry.loginRefused ? "sem acesso" : "sem login", tone: .gone)
        } else if inUse {
            // Where new sessions open, which is not where every open session runs ("N sessões aqui" says that).
            StateChip(text: "sessões novas", tone: .inUse)
        } else if next {
            StateChip(text: "próxima", tone: .next)
        }
    }

    private var subline: String {
        if let until = entry.exhaustedUntil, until > Date() {
            return "volta às \(Fmt.stamp(until)) · " + renewals
        }
        if !entry.hasLogin, entry.loginRefused { return "o macOS não liberou o login: Ler de novo em Acessos" }
        if !entry.hasLogin { return "sem login: autorize de novo nos Ajustes" }
        var parts = [renewals]
        // Numbers this old say so, and why when the reason is known.
        if let at = entry.snapshot?.fetchedAt, Date().timeIntervalSince(at) > 15 * 60 {
            parts.append(entry.loginIdle ? "lido \(Fmt.ago(at)), volta na próxima sessão nela" : "lido \(Fmt.ago(at))")
        }
        if entry.sessions > 0 { parts.append(entry.sessions == 1 ? "1 sessão aqui" : "\(entry.sessions) sessões aqui") }
        if entry.runsAgents, bgAgents { parts.append("agentes aqui") }
        if !entry.agentsLogin, bgAgents { parts.append("agentes sem login nesta conta") }
        return parts.joined(separator: " · ")
    }

    private var renewals: String {
        var parts: [String] = []
        if let s = entry.snapshot?.session, let at = s.resetsAt, !s.hasReset() {
            parts.append("5h renova \(Fmt.clock(at))")
        } else {
            parts.append("5h livre")
        }
        if let w = entry.snapshot?.weekly, let at = w.resetsAt, !w.hasReset() {
            parts.append("semana renova \(Fmt.weekday(at))")
        }
        if entry.snapshot == nil { return "sem leitura ainda" }
        return parts.joined(separator: " · ")
    }
}

/// The full limits of one account, opened from its row.
struct AccountDetail: View {
    let entry: AccountQueue.Entry
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.isLive, let usage = monitor.usage {
                if let session = usage.session {
                    LimitGauge(window: session, burn: monitor.sessionBurn)
                    if monitor.blockTrail.count >= 2, let start = session.startsAt, let end = session.resetsAt {
                        Trail(points: monitor.blockTrail, span: start...end)
                            .accessibilityLabel("Evolução da janela de 5h")
                    }
                }
                ForEach(usage.windows.filter { !$0.isSession }) { LimitGauge(window: $0, dense: true) }
                if usage.extraUsageEnabled, let extra = usage.extraUsageUtilization {
                    HStack {
                        Text("Crédito extra").font(Type.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.pct(extra)).font(Type.captionStrong)
                    }
                }
                Text(monitor.liveIsCurrent ? "Lido agora, com o login do terminal." : "Última leitura \(Fmt.ago(monitor.liveSeenAt ?? usage.fetchedAt)).")
                    .font(Type.mini).foregroundStyle(.tertiary)
            } else if let snap = entry.snapshot {
                if let session = snap.session { StaleLimitRow(window: session, seenAt: snap.fetchedAt) }
                ForEach(snap.windows.filter { !$0.isSession }) { StaleLimitRow(window: $0, seenAt: snap.fetchedAt) }
            } else {
                Text("Sem leitura desta conta ainda. Ela aparece aqui quando o Monitor conseguir ler o login dela.")
                    .font(Type.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let email = entry.email {
                Text([email, entry.organization].compactMap { $0 }.joined(separator: " · "))
                    .font(Type.mini).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
