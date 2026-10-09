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
    /// Opens with the keep-awake card unfolded, for `--preview=awake` and `--render=awake`.
    var initialAwakeOpen = false
    @State private var previewTab: PanelTab?

    private var tab: Binding<PanelTab> {
        Binding(get: { previewTab ?? initialTab ?? PanelTab(rawValue: tabRaw) ?? .accounts },
                set: { if initialTab != nil { previewTab = $0 } else { tabRaw = $0.rawValue } })
    }

    @State private var showAwake = false
    @State private var paneNatural: CGFloat = 0
    @State private var topHeight: CGFloat = 45
    @State private var bottomHeight: CGFloat = 37
    @State private var screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800

    /// The tallest the panel gets on a big screen, where a full-height column would only be harder to read.
    static let maxHeight: CGFloat = 860

    /// The pane is as tall as what the tab shows, up to the room the screen has below the menu bar; only then
    /// it scrolls. Switching tabs resizes the panel, the way a popover follows its content.
    private var paneHeight: CGFloat {
        let room = min(screenHeight - 12, Self.maxHeight) - topHeight - bottomHeight
        return min(max(paneNatural, 60), max(180, room))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if showAwake {
                    KeepAwakeCard(keep: keep) { withAnimation(.easeOut(duration: 0.15)) { showAwake = false } }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                } else if keep.active {
                    KeepAwakeStrip(keep: keep) { withAnimation(.easeOut(duration: 0.15)) { showAwake = true } }
                }
                Hairline()
            }
            .measuringHeight { if abs(topHeight - $0) > 0.5 { topHeight = $0 } }
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
                .measuringHeight { if abs(paneNatural - $0) > 0.5 { paneNatural = $0 } }
            }
            .scrollIndicators(.automatic)
            .frame(height: paneHeight)
            VStack(spacing: 0) {
                Hairline()
                footer
            }
            .measuringHeight { if abs(bottomHeight - $0) > 0.5 { bottomHeight = $0 } }
        }
        .frame(width: 380)
        .background(WindowSizer(height: topHeight + paneHeight + bottomHeight) { visible in
            if abs(screenHeight - visible) > 1 { screenHeight = visible }
        })
        .background {
            // ⌘, opens the settings while the panel is up, like in any Mac app.
            Button("Ajustes") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear {
            if initialAwakeOpen { showAwake = true }
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
            keepAwakeButton
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

    /// The moon (or the sun, while the Mac is held awake) opens the keep-awake card under the header.
    private var keepAwakeButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showAwake.toggle() }
        } label: {
            HeaderIcon {
                Image(systemName: keep.active ? "sun.max.fill" : "moon.zzz")
                    .font(.system(size: 12.5))
                    .foregroundStyle(keep.active ? Ink.ember : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(keep.active ? "Mac desperto \(keep.untilText ?? "")" : "Manter o Mac desperto")
        .accessibilityLabel(keep.active ? "Mac desperto \(keep.untilText ?? "")" : "Manter o Mac desperto")
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

    /// When the numbers of the account in use were read, and a quiet retry. Grey while they are recent or the
    /// server only asked for a pause; red once they are half an hour old.
    private var freshness: some View {
        let queue = monitor.accountQueue
        let seen = queue.entry(queue.newSessions())?.snapshot?.fetchedAt
            ?? queue.entries.compactMap { $0.snapshot?.fetchedAt }.max() ?? monitor.liveSeenAt
        let age = seen.map { Date().timeIntervalSince($0) } ?? 0
        let current = age <= max(300, settings.usageIntervalSeconds * 2.5)
        let pause = monitor.livePauseShown.flatMap { $0 > Date() ? $0 : nil }
        return HStack(spacing: 6) {
            if let seen {
                Text(current ? "atualizado \(Fmt.ago(seen))"
                             : ["lido \(Fmt.ago(seen))", pause.map { "pausa até \(Fmt.clock($0))" }].compactMap { $0 }.joined(separator: " · "))
                    .font(Type.caption)
                    // A pause the server asked for is expected, not an alarm; old numbers without one are.
                    .foregroundStyle(age > 30 * 60 && pause == nil ? Ink.alarm : Color.secondary.opacity(0.8))
                    .help(monitor.usageError.map { "Última tentativa: \($0)" } ?? "Lido do servidor do Claude")
            }
            Button {
                Task { await monitor.readAgain() }
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
