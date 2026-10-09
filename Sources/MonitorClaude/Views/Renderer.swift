import SwiftUI
import AppKit

/// Draws one screen of the app into a PNG without showing it: an off-screen window hosts the view, the run loop
/// turns for a few seconds so the Monitor reads its data, and the layer tree is rendered into a bitmap.
@MainActor
enum Renderer {
    static func render(_ target: PreviewTarget, to url: URL, dark: Bool, wait: TimeInterval) {
        let monitor = Monitor()
        let view: AnyView
        let size: NSSize
        switch target {
        case .panel(let tab):
            view = AnyView(PanelView(monitor: monitor, initialTab: tab))
            size = NSSize(width: 380, height: Settings.shared.panelSize.height)
        case .settings(let tab):
            monitor.settingsTab = tab
            view = AnyView(SettingsWindow(monitor: monitor))
            size = NSSize(width: 640, height: 540)
        case .wizard(let step):
            view = AnyView(AddAccountSheet(flow: AddAccountFlow.preview(step: step, store: monitor.accounts)) {})
            size = NSSize(width: 460, height: 420)
        }
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)

        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
        }
        let fitting = host.fittingSize
        let final = NSSize(width: size.width,
                           height: max(120, min(size.height, fitting.height > 0 ? fitting.height : size.height)))
        host.setFrameSize(final)
        window.setContentSize(final)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.display()

        let scale: CGFloat = 2
        let width = Int(final.width * scale), height = Int(final.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = final
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("ok \(url.path)")
        }
    }
}
