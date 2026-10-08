import SwiftUI
import AppKit

/// "Sessões": the Mac at a glance, then every Claude session with everything it opened, tagged with the account it
/// runs on, and what closed sessions left behind.
struct SessionsPane: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var settings = Settings.shared
    @State private var expanded: Set<pid_t> = []

    var body: some View {
        let buckets = monitor.attribution.sessionBuckets.sorted { a, b in
            if a.session.isBusy != b.session.isBusy { return a.session.isBusy }
            return monitor.tokens(for: a.session).total > monitor.tokens(for: b.session).total
        }
        let ghosts = monitor.attribution.ghostBuckets
        let share = monitor.claudeShare
        let monograms = Dictionary(uniqueKeysWithValues: monitor.accountQueue.entries.map { ($0.id, $0.monogram) })
        let showTags = monitor.accountQueue.configured && !monitor.accountQueue.isSingle

        VStack(alignment: .leading, spacing: 12) {
            machine

            Hairline()

            GroupTitle(title: "Claude",
                       trailing: share.procs > 0 ? "\(buckets.count) sessões · \(share.procs) proc · \(Fmt.bytes(share.rss))" : nil)

            if buckets.isEmpty && ghosts.isEmpty {
                Text("Nenhuma sessão rodando.").font(Type.body).foregroundStyle(.tertiary)
            }

            VStack(spacing: 2) {
                ForEach(buckets) { bucket in
                    SessionRow(bucket: bucket,
                               tokens: monitor.tokens(for: bucket.session),
                               peak: monitor.busiestSessionTokens,
                               account: showTags ? bucket.session.accountId.flatMap { monograms[$0] } : nil,
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
            }

            if !ghosts.isEmpty { leftovers(ghosts) }

            if !monitor.attribution.chromeRoots.isEmpty { chrome }

            if settings.showOtherProcesses {
                GroupTitle(title: "Outros processos", trailing: "por CPU")
                ProcTree(nodes: Array(monitor.attribution.otherRoots.prefix(12)),
                         monitor: monitor, expanded: $expanded, roleFor: Classify.role)
            }
        }
    }

    private var machine: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CPU").font(Type.mini).foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    Sparkline(values: monitor.cpuTrail).frame(width: 46)
                    Text(Fmt.cpu(monitor.system.cpuPercent))
                        .font(Type.strong).monospacedDigit()
                        .foregroundStyle(Ink.load(monitor.system.cpuPercent / 100))
                        .contentTransition(.numericText())
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Memória · \(Fmt.memPair(monitor.system.memUsedBytes, monitor.system.memTotalBytes))")
                    .font(Type.mini).foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
                MiniBar(fraction: monitor.system.memFraction, width: 120)
            }
            Spacer()
            if monitor.system.swapUsedBytes > 512 * 1_048_576 {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Swap").font(Type.mini).foregroundStyle(.tertiary)
                    Text(Fmt.bytes(monitor.system.swapUsedBytes)).font(Type.strong).foregroundStyle(Ink.alarm)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func leftovers(_ ghosts: [GhostBucket]) -> some View {
        let procs = ghosts.reduce(0) { $0 + $1.procCount }
        let rss = ghosts.reduce(UInt64(0)) { $0 + $1.rss }
        let all = Kill.Target(title: "o que \(ghosts.count) sessões encerradas deixaram",
                              pids: ghosts.flatMap { $0.roots.flatMap(Kill.subtree) },
                              detail: ghosts.flatMap { $0.roots.flatMap { Kill.names($0, limit: 3) } })
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sobras de \(ghosts.count == 1 ? "1 sessão encerrada" : "\(ghosts.count) sessões encerradas")")
                        .font(Type.bodyMedium)
                    Text("\(procs) processos · \(Fmt.bytes(rss))").font(Type.mini).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Encerrar") { Kill.confirm(all, force: false, monitor: monitor) }
                    .controlSize(.small)
            }
            ForEach(ghosts) { ghost in
                DisclosureRow(title: "sessão encerrada",
                              subtitle: "\(ghost.procCount) proc · \(String(ghost.sessionId.prefix(8)))",
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
        .padding(10)
        .background(Ink.track, in: RoundedRectangle(cornerRadius: 9))
    }

    private var chrome: some View {
        let roots = monitor.attribution.chromeRoots
        let cpu = roots.reduce(0) { $0 + $1.subtreeCPU }
        let rss = roots.reduce(UInt64(0)) { $0 + $1.subtreeRSS }
        return VStack(alignment: .leading, spacing: 6) {
            GroupTitle(title: "Chrome seu", trailing: "\(Fmt.cpu(cpu)) · \(Fmt.bytes(rss))")
            ProcTree(nodes: roots, monitor: monitor, expanded: $expanded, roleFor: Classify.role)
        }
    }
}

// MARK: - Rows

struct SessionRow: View {
    let bucket: SessionBucket
    let tokens: TokenCounts
    let peak: Int64
    var account: String?
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
            HStack(spacing: 8) {
                StatusDot(busy: session.isBusy)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(Type.bodyMedium)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 4) {
                        if let account {
                            Text(account)
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Ink.track, in: RoundedRectangle(cornerRadius: 3))
                                .help("Conta desta sessão")
                        }
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
                        if tokens.total > 0 {
                            Text("·")
                            Text("\(Fmt.tokens(tokens.total)) tokens")
                        }
                    }
                    .font(Type.mini)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                if hovering {
                    KillButton(target: everything, monitor: monitor)
                }

                Text(Fmt.cpu(bucket.cpu))
                    .font(Type.captionStrong)
                    .foregroundStyle(bucket.cpu > 40 ? Ink.ember : .secondary)
                    .frame(width: 42, alignment: .trailing)

                Text(Fmt.bytes(bucket.rss))
                    .font(Type.captionStrong)
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .background(hovering ? Ink.track.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
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
                        .font(Type.mini)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                        .padding(.bottom, 2)
                }
                if !bucket.chromeNames.isEmpty {
                    Text("Chrome: \(bucket.chromeNames.joined(separator: ", "))")
                        .font(Type.mini)
                        .foregroundStyle(Ink.ember)
                        .padding(.leading, 16)
                        .padding(.bottom, 2)
                }
                if tokens.total > 0 {
                    Text("Tokens nesta janela (estimativa local): \(Fmt.tokens(tokens.cacheRead)) de cache lido, \(Fmt.tokens(tokens.cacheCreate)) de cache escrito, \(Fmt.tokens(tokens.output)) de saída.")
                        .font(Type.mini)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
        Button("Copiar id da sessão") { Clipboard.copy(session.sessionId) }
        Button("Copiar caminho") { Clipboard.copy(session.cwd) }
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
                Text(title).font(Type.body).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Text(subtitle).font(Type.mini).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                Spacer()
                if hovering, let kill, let monitor {
                    KillButton(target: kill, monitor: monitor)
                }
                Text(Fmt.cpu(cpu)).font(Type.captionStrong).foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
                Text(Fmt.bytes(rss)).font(Type.captionStrong).foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
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
