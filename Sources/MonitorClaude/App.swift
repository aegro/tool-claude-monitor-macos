import SwiftUI
import AppKit

struct MonitorApp: App {
    @StateObject private var monitor = Monitor()

    init() {
        // Fora do dispatch_once do singleton: lê o estado de energia do sistema e re-aplica
        // a intenção salva sem re-entrar no init de KeepAwake.shared.
        DispatchQueue.main.async { KeepAwake.shared.bootstrap() }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        SwiftUI.Settings {
            SettingsWindow(monitor: monitor)
        }
    }
}

/// Debug scaffold: renders the same panel in an ordinary window so the layout can be
/// inspected without fighting the menu bar popover.
struct PreviewApp: App {
    @StateObject private var monitor = Monitor()

    init() {
        DispatchQueue.main.async { KeepAwake.shared.bootstrap() }
    }

    /// `--preview=settings:<tab>` shows the settings window instead of the panel, `--preview=panel:<tab>` picks the
    /// panel tab, `--preview=wizard:<step>` the assistant at a step. For screenshots without clicking.
    private let target = PreviewTarget(arguments: CommandLine.arguments)

    var body: some Scene {
        Window("Monitor Claude — preview", id: "preview") {
            switch target {
            case .panel(let tab):
                PanelView(monitor: monitor, initialTab: tab)
            case .settings(let tab):
                SettingsWindow(monitor: monitor).onAppear { monitor.settingsTab = tab }
            case .wizard(let step):
                AddAccountSheet(flow: AddAccountFlow.preview(step: step, store: monitor.accounts)) {}
            }
        }
        .windowResizability(.contentSize)

        SwiftUI.Settings {
            SettingsWindow(monitor: monitor)
        }
    }
}

enum PreviewTarget {
    case panel(PanelTab?)
    case settings(SettingsTab)
    case wizard(AddAccountFlow.Step)

    init(arguments: [String]) {
        let value = arguments.first { $0.hasPrefix("--preview=") }.map { String($0.dropFirst("--preview=".count)) } ?? ""
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts.first ?? "panel"
        let detail = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "settings": self = .settings(SettingsTab(rawValue: detail) ?? .general)
        case "wizard":
            let steps: [String: AddAccountFlow.Step] = ["choose": .choose, "authorize": .authorize, "connected": .connected,
                                                        "agents": .agents, "place": .place, "done": .done]
            self = .wizard(steps[detail] ?? .choose)
        default: self = .panel(PanelTab(rawValue: detail))
        }
    }
}
