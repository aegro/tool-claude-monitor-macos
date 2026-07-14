import SwiftUI
import AppKit

struct MonitorApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Debug scaffold: renders the same panel in an ordinary window so the layout can be
/// inspected without fighting the menu bar popover.
struct PreviewApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        Window("Monitor Claude — preview", id: "preview") {
            PanelView(monitor: monitor)
        }
        .windowResizability(.contentSize)
    }
}
