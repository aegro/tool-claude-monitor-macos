import Foundation
import SwiftUI
import AppKit
import ServiceManagement

/// User-tunable behaviour. Small on purpose: a monitor with a sprawling settings screen has
/// lost the plot. Persisted in UserDefaults; the panel height and what the menu bar shows are
/// the two things people actually want to change.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    enum PanelSize: String, CaseIterable, Identifiable {
        case compact, tall, huge
        var id: String { rawValue }
        var preferred: CGFloat {
            switch self {
            case .compact: return 480
            case .tall: return 660
            case .huge: return 840
            }
        }

        /// Never taller than the screen can show below the menu bar.
        var height: CGFloat {
            let ceiling = (NSScreen.main?.visibleFrame.height ?? 900) - 24
            return min(preferred, max(360, ceiling))
        }
        var label: String {
            switch self {
            case .compact: return "Compacta"
            case .tall: return "Alta"
            case .huge: return "Máxima"
            }
        }
    }

    enum MenuBarStyle: String, CaseIterable, Identifiable {
        case sessionLimit, cpu, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sessionLimit: return "Limite 5h"
            case .cpu: return "CPU"
            case .both: return "Ambos"
            }
        }
    }

    @AppStorage("panelSize") var panelSizeRaw = PanelSize.tall.rawValue
    @AppStorage("menuBarStyle") var menuBarStyleRaw = MenuBarStyle.sessionLimit.rawValue
    @AppStorage("showOtherProcesses") var showOtherProcesses = true
    @AppStorage("warnAtPace") var warnAtPace = true
    @AppStorage("usageIntervalSeconds") var usageIntervalSeconds = 120.0
    @AppStorage("launchAtLogin") var launchAtLogin = false

    var panelSize: PanelSize { PanelSize(rawValue: panelSizeRaw) ?? .tall }
    var menuBarStyle: MenuBarStyle { MenuBarStyle(rawValue: menuBarStyleRaw) ?? .sessionLimit }

    func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Non-fatal: the toggle just won't stick. Unsigned dev builds can't register.
        }
    }
}
