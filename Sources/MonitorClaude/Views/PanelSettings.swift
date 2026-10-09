import SwiftUI

/// The settings that live in the panel: Geral, Integrações and Avançado, one page at a time under a segmented
/// picker. They are toggles and choices, done in a second, so they no longer open a window in the middle of the
/// screen. Contas stays in the window: adding or authorizing an account opens the browser, which takes the focus and
/// would close the panel under the assistant.
struct PanelSettings: View {
    @ObservedObject var monitor: Monitor
    @Binding var page: SettingsTab

    static let pages: [SettingsTab] = [.general, .integrations, .advanced]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                ForEach(Self.pages) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
            Group {
                switch page {
                case .integrations: IntegrationsSettings(monitor: monitor)
                case .advanced: AdvancedSettings(monitor: monitor)
                default: GeneralSettings()
                }
            }
            .tint(Ink.ember)
        }
        .onAppear {
            if !Self.pages.contains(page) { page = .general }
            if page == .integrations { monitor.refreshIntegrations() }
        }
        .onChange(of: page) { _, now in if now == .integrations { monitor.refreshIntegrations() } }
    }
}
