import SwiftUI

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var settings = Settings.shared
    @State private var expanded: Set<pid_t> = []
    @State private var showLedgerNote = false
    @State private var showSettings = false
    /// Which inactive account is open, if any. nil = the active account is shown in full (default).
    @State private var expandedAccount: String?

    /// MenuBarExtra sizes its window to the content's ideal height, and a ScrollView has none.
    /// The machine strip and footer are fixed chrome, so the scroll area gets whatever the
    /// chosen panel height leaves over.
    private var scrollHeight: CGFloat { settings.panelSize.height - 96 }

    var body: some View {
        Group {
            if showSettings {
                SettingsView(monitor: monitor) {
                    withAnimation(.easeOut(duration: 0.18)) { showSettings = false }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                panel
            }
        }
        .onAppear { monitor.panelOpen = true }
        .onDisappear { monitor.panelOpen = false }
        // A switch makes the newly-active account the one shown in full; don't leave a
        // previously-opened inactive account expanded across the change.
        .onChange(of: monitor.activeAccount?.key) { _, _ in expandedAccount = nil }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            machineStrip
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    KeepAwakeSection()
                    Hairline()
                    limitsSection
                    Hairline()
                    tokensSection
                    Hairline()
                    sessionsSection
                    if !monitor.attribution.chromeRoots.isEmpty {
                        Hairline()
                        chromeSection
                    }
                    if settings.showOtherProcesses {
                        Hairline()
                        othersSection
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.automatic)
            .frame(height: scrollHeight)

            Hairline()
            footer
        }
        .frame(width: 396)
    }

    // MARK: machine

    private var machineStrip: some View {
        HStack(spacing: 10) {
            Sparkline(values: monitor.cpuTrail)
                .frame(width: 54)

            VStack(alignment: .leading, spacing: 1) {
                Text("CPU").font(Type.labelTiny).foregroundStyle(.tertiary)
                Text(Fmt.cpu(monitor.system.cpuPercent))
                    .font(Type.value)
                    .foregroundStyle(Ink.load(monitor.system.cpuPercent / 100))
                    .contentTransition(.numericText())
            }

            Divider().frame(height: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("MEM").font(Type.labelTiny).foregroundStyle(.tertiary)
                    Text(Fmt.memPair(monitor.system.memUsedBytes, monitor.system.memTotalBytes))
                        .font(Type.value)
                        .foregroundStyle(Ink.load(monitor.system.memFraction))
                }
                MiniBar(fraction: monitor.system.memFraction, width: 96)
            }

            Spacer()

            if monitor.system.swapUsedBytes > 512 * 1_048_576 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("SWAP").font(Type.labelTiny).foregroundStyle(.tertiary)
                    Text(Fmt.bytes(monitor.system.swapUsedBytes))
                        .font(Type.value)
                        .foregroundStyle(Ink.alarm)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: limits

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(title: "Limites do Claude",
                        trailing: monitor.usage.map { "há \(Fmt.duration(Date().timeIntervalSince($0.fetchedAt)))" })

            FeedBar(feeds: monitor.feeds,
                    feeding: monitor.usage?.source,
                    detail: monitor.usageError) {
                Task { await monitor.refreshUsage(force: true) }
            }

            if let usage = monitor.usage {
                accountLimits(usage)
                // A broken terminal feed while another one carries the panel is not an alarm — the
                // numbers above are real and current. It is still stated in full, in words, once:
                // the whole point of this rework is that a dead feed can never again be silent.
                if let err = monitor.usageError, !monitor.feeds.allDown {
                    pill(icon: "terminal", text: err, tone: .secondary)
                }
            } else if let err = monitor.usageError {
                errorCard(err)
            } else {
                Text("Lendo o login do terminal…")
                    .font(Type.label)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// One account → exactly today's layout. Two or more → the active account keeps its full live
    /// detail with a lead row, and the others sit below as clickable strips; opening one swaps it
    /// into a last-seen detail and collapses the active account to a strip. One open at a time.
    @ViewBuilder
    private func accountLimits(_ usage: UsageSnapshot) -> some View {
        let others = monitor.otherAccounts
        let desktop = monitor.desktopOnlyOrgs
        let live = monitor.liveAccount
        if others.isEmpty && desktop.isEmpty {
            activeDetail(usage)
            if live != nil {
                Text("Outras contas aparecem aqui quando você as usa no `claude`.")
                    .font(Type.labelTiny)
                    .foregroundStyle(.tertiary)
            }
        } else {
            let activeExpanded = expandedAccount == nil
                || !others.contains { $0.uuid == expandedAccount }

            if activeExpanded {
                if let live {
                    AccountLead(label: live.label, plan: live.plan, marker: .live)
                }
                activeDetail(usage)
            } else if let live {
                AccountStrip(label: live.label, plan: live.plan,
                             summary: accountSummary(usage), live: true, seenAt: nil) {
                    withAnimation(.easeOut(duration: 0.18)) { expandedAccount = nil }
                }
            }

            ForEach(others) { rec in
                if expandedAccount == rec.uuid {
                    AccountLead(label: rec.label, plan: rec.plan, marker: .lastSeen(rec.lastSeen))
                    staleDetail(rec)
                    pill(icon: "arrow.clockwise",
                         text: "abra a \(rec.label) no `claude` pra atualizar ao vivo",
                         tone: .secondary)
                } else {
                    AccountStrip(label: rec.label, plan: rec.plan,
                                 summary: accountSummary(rec.snapshot), live: false,
                                 seenAt: rec.lastSeen) {
                        withAnimation(.easeOut(duration: 0.18)) { expandedAccount = rec.uuid }
                    }
                }
            }

            // Last: organizations we only know from the desktop app. They come after the terminal
            // ones because they carry less, and they never expand.
            ForEach(desktop) { DesktopOrgStrip(org: $0) }
        }
    }

    /// The active account's full, live detail — session gauge with the rate graph and outlook,
    /// every weekly window, and any extra credit. Identical to what the panel showed before
    /// multi-account existed.
    @ViewBuilder
    private func activeDetail(_ usage: UsageSnapshot) -> some View {
        if let session = usage.session {
            LimitGauge(window: session, burn: monitor.sessionBurn)
            trailOrHint(session)
            outlookLine
        }

        ForEach(usage.windows.filter { !$0.isSession }) { w in
            LimitGauge(window: w, dense: true)
        }

        if usage.extraUsageEnabled, let u = usage.extraUsageUtilization {
            extraCredit(u)
        }

        ghostDetail
    }

    /// Limits the *current* feed cannot carry, held on screen with their last value and the date
    /// they were true. Switching feeds must never make a limit disappear without saying so — a row
    /// that vanishes silently reads as "you no longer have this cap", which is the opposite of what
    /// happened. Faded, and never counted as live.
    @ViewBuilder
    private var ghostDetail: some View {
        if let seenAt = monitor.ghostSeenAt {
            ForEach(monitor.ghostWindows) { w in
                StaleLimitRow(window: w, seenAt: seenAt,
                              note: w.key.hasPrefix("weekly_scoped")
                                  ? "o app não publica por modelo"
                                  : "o app não publica esta janela")
                    .opacity(0.55)
            }
            if let extra = monitor.ghostExtraCredit {
                extraCredit(extra).opacity(0.55)
            }
        }
    }

    /// An inactive account rendered from its last-seen snapshot: plain bars, no live rate graph.
    @ViewBuilder
    private func staleDetail(_ rec: AccountRecord) -> some View {
        let snap = rec.snapshot
        if let session = snap.session {
            StaleLimitRow(window: session, seenAt: rec.lastSeen,
                          note: "sem gráfico de ritmo ao vivo")
        }
        ForEach(snap.windows.filter { !$0.isSession }) { w in
            StaleLimitRow(window: w, seenAt: rec.lastSeen)
        }
        if snap.extraUsageEnabled, let u = snap.extraUsageUtilization {
            extraCredit(u)
        }
    }

    private func extraCredit(_ u: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard").font(.system(size: 9))
            Text("Crédito extra").font(Type.labelTiny)
            Spacer()
            Text(Fmt.pct(u)).font(Type.value)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func trailOrHint(_ five: LimitWindow) -> some View {
        let pts = monitor.blockTrail
        if pts.count >= 2, let start = five.startsAt, let end = five.resetsAt {
            VStack(alignment: .leading, spacing: 2) {
                Trail(points: pts, span: start...end)
                Text("linha tracejada = ritmo que a janela sustenta")
                    .font(Type.labelTiny)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        } else {
            let cadence = monitor.usage?.source == .desktopApp ? "5 min" : "2 min"
            Text("Traçando a evolução desta janela — uma amostra a cada \(cadence).")
                .font(Type.labelTiny)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var outlookLine: some View {
        switch monitor.outlook {
        case .idle:
            EmptyView()

        case .measuring:
            pill(icon: "hourglass",
                 text: "medindo o ritmo — precisa de ~15 min de amostras",
                 tone: .secondary)

        case .safe(let rate, _):
            if rate > 0.5 {
                pill(icon: "checkmark.circle",
                     text: String(format: "queimando %.0f%%/h — dá pra ir até o reset", locale: Fmt.br, rate),
                     tone: .secondary)
            }

        case .willHitCap(let exhaust, let reset, let rate, let minutes, let ahead):
            if settings.warnAtPace || !ahead {
            pill(icon: ahead ? "flame.fill" : "exclamationmark.triangle.fill",
                 text: String(format: "%.0f%%/h nos últimos %.0f min — bate o teto em %@, e o reset só vem em %@",
                              locale: Fmt.br, rate, minutes,
                              Fmt.duration(exhaust), Fmt.duration(reset)),
                 tone: ahead ? Ink.alarm : .orange)
            }
        }
    }

    private func pill(icon: String, text: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(Type.labelTiny).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone)
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
    }

    private func errorCard(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "lock.slash").font(.system(size: 10))
                Text("Sem acesso aos limites").font(Type.label)
            }
            .foregroundStyle(Ink.alarm)

            Text(err).font(Type.labelTiny).foregroundStyle(.secondary)

            Button("Tentar de novo") {
                Task { await monitor.refreshUsage(force: true) }
            }
            .buttonStyle(.link)
            .font(Type.labelTiny)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.alarm.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: tokens

    private var tokensSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHead(title: "Tokens nesta janela",
                        trailing: monitor.ledger.tokensPerMinute > 1 ? Fmt.rate(monitor.ledger.tokensPerMinute) : nil)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.tokens(monitor.ledger.block.total))
                    .font(Type.valueBig)
                    .contentTransition(.numericText())
                Text("processados")
                    .font(Type.labelTiny)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button { showLedgerNote.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }

            // Same x-axis as the trail above: the whole 5h window. Stacking two charts with
            // different time axes would invite exactly the wrong comparison.
            if !monitor.ledger.buckets.isEmpty,
               let end = monitor.usage?.session?.resetsAt {
                TokenBars(buckets: monitor.ledger.buckets, span: monitor.blockStart...end)
            } else if !monitor.ledger.buckets.isEmpty {
                TokenBars(buckets: monitor.ledger.buckets,
                          span: monitor.blockStart...Date().addingTimeInterval(300))
            }

            HStack(spacing: 10) {
                legend("cache lido", monitor.ledger.block.cacheRead)
                legend("cache escrito", monitor.ledger.block.cacheCreate)
                legend("saída", monitor.ledger.block.output)
            }

            if showLedgerNote {
                Text("Contagem local, lida dos transcripts. A Anthropic grava input e output a partir de eventos de streaming e nunca os finaliza, então esses dois vêm subcontados (o cache é exato). Use isto para comparar sessões entre si; para o número que vale, olhe a barra de limite acima, que vem do servidor.")
                    .font(Type.labelTiny)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Ink.track, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func legend(_ name: String, _ v: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(Type.labelTiny).foregroundStyle(.tertiary)
            Text(Fmt.tokens(v)).font(Type.value).foregroundStyle(.secondary)
        }
    }

    // MARK: claude

    private var sessionsSection: some View {
        let share = monitor.claudeShare
        let buckets = monitor.attribution.sessionBuckets.sorted { a, b in
            if a.session.isBusy != b.session.isBusy { return a.session.isBusy }
            return monitor.tokens(for: a.session).total > monitor.tokens(for: b.session).total
        }
        let ghosts = monitor.attribution.ghostBuckets

        return VStack(alignment: .leading, spacing: 6) {
            SectionHead(
                title: "Claude na máquina",
                trailing: share.procs > 0
                    ? "\(share.procs) proc · \(Fmt.cpu(share.cpu)) · \(Fmt.bytes(share.rss))"
                    : nil
            )

            if buckets.isEmpty && ghosts.isEmpty {
                Text("Nenhuma sessão rodando.")
                    .font(Type.label)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            }

            ForEach(buckets) { bucket in
                SessionRow(bucket: bucket,
                           tokens: monitor.tokens(for: bucket.session),
                           peak: monitor.busiestSessionTokens,
                           monitor: monitor,
                           expanded: $expanded)
            }

            if monitor.attribution.infraCount > 0 {
                DisclosureRow(title: "infraestrutura",
                              subtitle: "daemon + pool · \(monitor.attribution.infraCount)",
                              cpu: monitor.attribution.infraCPU,
                              rss: monitor.attribution.infraRSS,
                              id: -1, expanded: $expanded,
                              kill: Kill.Target(
                                  title: "a infraestrutura do Claude",
                                  pids: monitor.attribution.infraRoots.flatMap(Kill.subtree),
                                  detail: monitor.attribution.infraRoots.flatMap { Kill.names($0, limit: 4) }),
                              monitor: monitor) {
                    ProcTree(nodes: monitor.attribution.infraRoots, monitor: monitor,
                             expanded: $expanded, depth: 1, roleFor: Classify.role)
                }
            }

            ForEach(ghosts) { ghost in
                DisclosureRow(title: "sessão encerrada",
                              subtitle: "\(ghost.procCount) órfãos · \(String(ghost.sessionId.prefix(8)))",
                              cpu: ghost.cpu, rss: ghost.rss,
                              id: pid_t(bitPattern: UInt32(truncatingIfNeeded: ghost.sessionId.hashValue)),
                              expanded: $expanded,
                              kill: Kill.Target(
                                  title: "os órfãos desta sessão encerrada",
                                  pids: ghost.roots.flatMap(Kill.subtree),
                                  detail: ghost.roots.flatMap { Kill.names($0, limit: 4) }),
                              monitor: monitor) {
                    ProcTree(nodes: ghost.roots, monitor: monitor, expanded: $expanded, depth: 1,
                             roleFor: Classify.role)
                }
            }
        }
    }

    // MARK: chrome / others

    private var chromeSection: some View {
        let roots = monitor.attribution.chromeRoots
        let cpu = roots.reduce(0) { $0 + $1.subtreeCPU }
        let rss = roots.reduce(UInt64(0)) { $0 + $1.subtreeRSS }

        return VStack(alignment: .leading, spacing: 6) {
            SectionHead(title: "Chrome seu", trailing: "\(Fmt.cpu(cpu)) · \(Fmt.bytes(rss))")
            Text("Os Chrome abertos pelo Claude aparecem dentro da sessão que os abriu.")
                .font(Type.labelTiny)
                .foregroundStyle(.tertiary)
            ProcTree(nodes: roots, monitor: monitor, expanded: $expanded, roleFor: Classify.role)
        }
    }

    private var othersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHead(title: "Outros processos", trailing: "por CPU")
            ProcTree(nodes: Array(monitor.attribution.otherRoots.prefix(12)),
                     monitor: monitor, expanded: $expanded, roleFor: Classify.role)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                Task { await monitor.refreshUsage(force: true) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(monitor.loadingUsage ? 360 : 0))
                        .animation(monitor.loadingUsage
                                   ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                   : .default, value: monitor.loadingUsage)
                    Text("Atualizar")
                }
                .font(Type.labelTiny)
            }
            .buttonStyle(.plain)

            Button("Monitor de Atividade") { monitor.revealInActivityMonitor() }
                .buttonStyle(.plain)
                .font(Type.labelTiny)

            Button {
                withAnimation(.easeOut(duration: 0.18)) { showSettings = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text("Configurações")
                }
                .font(Type.labelTiny)
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Sair") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(Type.labelTiny)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Rows

struct SessionRow: View {
    let bucket: SessionBucket
    let tokens: TokenCounts
    let peak: Int64
    let monitor: Monitor
    @Binding var expanded: Set<pid_t>

    @State private var hovering = false

    private var session: ClaudeSession { bucket.session }
    private var isOpen: Bool { expanded.contains(session.pid) }
    private var detached: Int { bucket.roots.filter(\.detached).count }

    /// Just the Claude process. The session dies, whatever it spawned keeps running.
    private var claudeOnly: Kill.Target {
        Kill.Target(title: "o Claude de “\(session.displayName)”",
                    pids: [session.pid],
                    detail: ["claude · \(session.pid)"])
    }

    /// The session and everything it spawned, wherever it ended up — which is the only way to
    /// actually reclaim the Docker stack or the stray JVM it left behind.
    private var everything: Kill.Target {
        Kill.Target(title: "“\(session.displayName)” e tudo que ela abriu",
                    pids: bucket.roots.flatMap(Kill.subtree),
                    detail: bucket.roots.flatMap { Kill.names($0, limit: 4) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                StatusDot(busy: session.isBusy)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(Type.label)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 3) {
                        Text(session.project)
                        if session.isBackground {
                            Text("bg")
                                .padding(.horizontal, 3)
                                .background(Ink.track, in: RoundedRectangle(cornerRadius: 3))
                        }
                        Text("·")
                        Text("\(bucket.procCount) proc")
                        if bucket.chromeCount > 0 {
                            Text("·")
                            HStack(spacing: 2) {
                                Image(systemName: "globe")
                                Text("\(bucket.chromeCount)")
                            }
                            .foregroundStyle(Ink.ember)
                        }
                        if detached > 0 {
                            Image(systemName: "link").foregroundStyle(Ink.ember)
                        }
                        Text("·")
                        Text(tokens.total > 0 ? Fmt.tokens(tokens.total) : "—")
                    }
                    .font(Type.labelTiny)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                if hovering {
                    KillButton(target: everything, monitor: monitor)
                }

                MiniBar(fraction: Double(tokens.total) / Double(peak),
                        tint: Ink.ember.opacity(0.8), width: 30)

                Text(Fmt.cpu(bucket.cpu))
                    .font(Type.value)
                    .foregroundStyle(bucket.cpu > 40 ? Ink.ember : .secondary)
                    .frame(width: 44, alignment: .trailing)

                Text(Fmt.bytes(bucket.rss))
                    .font(Type.value)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(hovering ? Ink.track.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isOpen { expanded.remove(session.pid) } else { expanded.insert(session.pid) }
                }
            }
            .contextMenu { menu }
            .help(helpText)

            if isOpen {
                if detached > 0 {
                    Text("\(detached) processo(s) foram reparentados e religados a esta sessão pelo ambiente, não pelo pai.")
                        .font(Type.labelTiny)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                        .padding(.bottom, 2)
                }
                if !bucket.chromeNames.isEmpty {
                    Text("Chrome: \(bucket.chromeNames.joined(separator: ", "))")
                        .font(Type.labelTiny)
                        .foregroundStyle(Ink.ember)
                        .padding(.leading, 16)
                        .padding(.bottom, 2)
                }
                ProcTree(nodes: bucket.roots, monitor: monitor,
                         expanded: $expanded, depth: 1, roleFor: Classify.role)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Text("\(session.cwd) · PID \(session.pid)")
        Button("Copiar id da sessão") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.sessionId, forType: .string)
        }
        Button("Copiar caminho") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.cwd, forType: .string)
        }
        Divider()
        Button("Encerrar só o Claude (1 proc)") {
            Kill.confirm(claudeOnly, force: false, monitor: monitor)
        }
        Button("Encerrar a sessão e tudo que ela abriu (\(everything.pids.count) proc)") {
            Kill.confirm(everything, force: false, monitor: monitor)
        }
        Divider()
        Button("Forçar encerramento de tudo (\(everything.pids.count) proc)") {
            Kill.confirm(everything, force: true, monitor: monitor)
        }
    }

    private var helpText: String {
        var lines = [session.cwd, "PID \(session.pid) · \(session.sessionId)"]
        if bucket.chromeCount > 0 {
            lines.append("\(bucket.chromeCount) processos do Chrome abertos por esta sessão")
        }
        lines.append("Clique com o botão direito para encerrar.")
        return lines.joined(separator: "\n")
    }
}

struct DisclosureRow<Content: View>: View {
    let title: String
    let subtitle: String
    let cpu: Double
    let rss: UInt64
    let id: pid_t
    @Binding var expanded: Set<pid_t>
    var kill: Kill.Target? = nil
    var monitor: Monitor? = nil
    @ViewBuilder var content: () -> Content

    @State private var hovering = false
    private var isOpen: Bool { expanded.contains(id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 9)
                Text(title).font(Type.label).foregroundStyle(.secondary)
                Text(subtitle).font(Type.labelTiny).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                if hovering, let kill, let monitor {
                    KillButton(target: kill, monitor: monitor)
                }
                Text(Fmt.cpu(cpu)).font(Type.value).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Text(Fmt.bytes(rss)).font(Type.value).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(hovering ? Ink.track.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isOpen { expanded.remove(id) } else { expanded.insert(id) }
                }
            }
            .contextMenu {
                if let kill, let monitor {
                    Button("Encerrar \(kill.title) (\(kill.pids.count) proc)") {
                        Kill.confirm(kill, force: false, monitor: monitor)
                    }
                    Button("Forçar encerramento") {
                        Kill.confirm(kill, force: true, monitor: monitor)
                    }
                }
            }

            if isOpen { content() }
        }
    }
}
