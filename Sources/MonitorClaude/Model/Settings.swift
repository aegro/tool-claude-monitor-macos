import Foundation
import SwiftUI
import AppKit
import ServiceManagement

/// User-tunable behaviour. Small on purpose: a monitor with a sprawling settings screen has
/// lost the plot. Persisted in UserDefaults. The panel height is not one of them any more: it follows
/// what each tab shows.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

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

    @AppStorage("menuBarStyle") var menuBarStyleRaw = MenuBarStyle.sessionLimit.rawValue
    @AppStorage("showOtherProcesses") var showOtherProcesses = true
    @AppStorage("warnAtPace") var warnAtPace = true
    @AppStorage("usageIntervalSeconds") var usageIntervalSeconds = 120.0
    @AppStorage("launchAtLogin") var launchAtLogin = false

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
