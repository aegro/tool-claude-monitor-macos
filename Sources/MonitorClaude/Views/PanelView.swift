import SwiftUI
import AppKit

/// The menu bar panel: three tabs that answer, in this order, where the sessions open and who takes over
/// (Contas), what Claude is doing on the Mac (Sessões), and what needs renewing (Acessos).
struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var keep = KeepAwake.shared
    @AppStorage("panelTab") private var tabRaw = PanelTab.accounts.rawValue
    @Environment(\.openSettings) private var openSettingsAction

    /// Set only by `--preview` and `--render`. It stays in the view: a screenshot run does not change the tab the
    /// menu bar app opens on.
    var initialTab: PanelTab?
    @State private var previewTab: PanelTab?

    private var tab: Binding<PanelTab> {
        Binding(get: { previewTab ?? initialTab ?? PanelTab(rawValue: tabRaw) ?? .accounts },
                set: { if initialTab != nil { previewTab = $0 } else { tabRaw = $0.rawValue } })
    }

    /// The panel keeps the height picked in the settings; the header and footer are fixed, the pane scrolls.
    private var scrollHeight: CGFloat { settings.panelSize.height - 92 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                Group {
                    switch tab.wrappedValue {
                    case .accounts: AccountsPane(monitor: monitor, openSettings: openSettings)
                    case .sessions: SessionsPane(monitor: monitor)
                    case .access: AccessPane(monitor: monitor, openSettings: openSettings)
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
        .frame(width: 380)
        .background {
            // ⌘, opens the settings while the panel is up, like in any Mac app.
            Button("Ajustes") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear {
            monitor.panelOpen = true
            Task { await monitor.refreshAccessIfDue() }
        }
        .onDisappear { monitor.panelOpen = false }
    }

    private func openSettings() {
        openSettingsAction()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 4) {
            PanelTabs(selection: tab, dot: monitor.access.attention > 0 ? [.access] : [])
            Spacer(minLength: 6)
            keepAwakeMenu
            Menu {
                Button("Ajustes…") { openSettings() }.keyboardShortcut(",", modifiers: .command)
                Button("Monitor de Atividade") { monitor.revealInActivityMonitor() }
                Divider()
                Button("Sair do Monitor Claude") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 24)
            .help("Ajustes e sair")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    private var keepAwakeMenu: some View {
        Menu {
            Toggle("Manter o Mac desperto", isOn: Binding(get: { keep.awake }, set: { keep.setAwake($0) }))
            Menu("Duração") {
                ForEach(KeepAwake.Duration.allCases) { d in
                    Button {
                        keep.duration = d
                    } label: {
                        if keep.duration == d { Label(d.label, systemImage: "checkmark") } else { Text(d.label) }
                    }
                }
            }
            .disabled(!keep.awake)
            Toggle("Continuar com a tampa fechada", isOn: Binding(get: { keep.lidClosed }, set: { keep.setLidClosed($0) }))
                .disabled(keep.busy)
        } label: {
            Image(systemName: keep.active ? "sun.max.fill" : "moon.zzz")
                .font(.system(size: 12.5))
                .foregroundStyle(keep.active ? Ink.ember : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 24)
        .help(keep.active ? "Mantendo o Mac desperto · \(keep.stateText)" : "Manter o Mac desperto")
    }

    // MARK: footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch tab.wrappedValue {
            case .accounts:
                let queue = monitor.accountQueue
                if queue.configured, !queue.isSingle {
                    Toggle(isOn: Binding(get: { queue.enabled }, set: { on in Task { await monitor.setSwitching(on) } })) {
                        Text("Troca automática").font(Type.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Ink.ember)
                }
                Spacer()
                freshness
            case .sessions:
                Button("Monitor de Atividade") { monitor.revealInActivityMonitor() }
                    .buttonStyle(.plain).font(Type.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.cpu(monitor.claudeShare.cpu)) de CPU no Claude").font(Type.caption).foregroundStyle(.tertiary)
            case .access:
                Text("vigia a cada 15 min, sem tokens").font(Type.caption).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await monitor.refreshAccessIfDue(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Conferir agora")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// When the numbers of the account in use were read, and a quiet retry. A failure only turns red when those
    /// numbers are no longer current; a passing 429 stays grey.
    private var freshness: some View {
        let queue = monitor.accountQueue
        let seen = queue.entry(queue.newSessions())?.snapshot?.fetchedAt
            ?? queue.entries.compactMap { $0.snapshot?.fetchedAt }.max() ?? monitor.liveSeenAt
        let current = seen.map { Date().timeIntervalSince($0) <= max(300, settings.usageIntervalSeconds * 2.5) } ?? false
        return HStack(spacing: 6) {
            if let seen {
                Text(current ? "atualizado \(Fmt.ago(seen))" : "números de \(Fmt.stamp(seen))")
                    .font(Type.caption)
                    .foregroundStyle(current ? Color.secondary.opacity(0.8) : Ink.alarm)
                    .help(monitor.usageError.map { "Última tentativa: \($0)" } ?? "Lido do servidor do Claude")
            }
            Button {
                Task { await monitor.refreshUsage(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(monitor.loadingUsage ? 360 : 0))
                    .animation(monitor.loadingUsage ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: monitor.loadingUsage)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Atualizar os limites agora")
        }
    }
}
