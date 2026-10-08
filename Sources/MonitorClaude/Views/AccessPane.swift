import SwiftUI
import AppKit

/// "Acessos": what needs renewing before it gets in the way. Connectors in use asking for a login, accounts without
/// one, versions behind, and the readiness panel's access checks when it runs on this Mac.
struct AccessPane: View {
    @ObservedObject var monitor: Monitor
    var openSettings: () -> Void
    @State private var showQuiet = false

    var body: some View {
        let report = monitor.access
        VStack(alignment: .leading, spacing: 12) {
            StatusBlock(
                caption: report.attention > 0 ? "Precisam de você" : "Tudo em dia",
                headline: report.attention == 0 ? "Nada para renovar" : (report.attention == 1 ? "1 acesso" : "\(report.attention) acessos"),
                line: summary(report))

            if let error = monitor.actionError {
                NoteBox(text: error, tone: Ink.alarm, icon: "exclamationmark.triangle")
            }

            if !report.needsYou.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    GroupTitle(title: "Precisam de você", trailing: "conferido às \(Fmt.clock(report.checkedAt))")
                    ForEach(report.needsYou) { item in AccessRow(item: item, monitor: monitor, openSettings: openSettings) }
                }
            }
            if !report.notConnecting.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    GroupTitle(title: "Não conectam")
                    ForEach(report.notConnecting) { item in AccessRow(item: item, monitor: monitor, openSettings: openSettings) }
                }
            }
            if !report.quiet.isEmpty { quiet(report) }
            if !report.healthy.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    GroupTitle(title: "Em dia")
                    FlowRow { ForEach(report.healthy, id: \.self) { OkChip(text: $0) } }
                }
            }
            readiness(report)
        }
    }

    private func summary(_ report: AccessReport) -> String {
        var parts: [String] = []
        if report.attention == 0 {
            parts.append("Os logins e as versões que o Monitor confere estão em dia.")
        }
        if !report.quiet.isEmpty {
            parts.append(report.quiet.count == 1
                         ? "Um conector pede login, mas não foi usado nos últimos 7 dias."
                         : "\(report.quiet.count) conectores pedem login, mas nenhum foi usado nos últimos 7 dias.")
        }
        return parts.joined(separator: " ")
    }

    private func quiet(_ report: AccessReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showQuiet.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.quiet.count == 1 ? "1 conector pede login" : "\(report.quiet.count) conectores pedem login")
                            .font(Type.bodyMedium).foregroundStyle(.primary)
                        Text(quietLine(report)).font(Type.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showQuiet ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showQuiet {
                FlowRow {
                    ForEach(report.quiet, id: \.self) { name in
                        Text(name).font(Type.mini).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Ink.track, in: Capsule())
                    }
                }
                Button("Reconectar no claude.ai") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/connectors")!) }
                    .buttonStyle(.link).font(Type.caption)
            }
        }
        .padding(10)
        .background(Ink.track, in: RoundedRectangle(cornerRadius: 9))
    }

    private func quietLine(_ report: AccessReport) -> String {
        var line = "Ficam quietos porque você não usou nenhum deles nos últimos 7 dias."
        if !report.quietRecent.isEmpty {
            line += " \(Fmt.list(report.quietRecent)) pediram nas últimas 24 h."
        }
        return line
    }

    @ViewBuilder
    private func readiness(_ report: AccessReport) -> some View {
        switch report.readiness {
        case .present(let at):
            HStack(spacing: 6) {
                Text("Painel de prontidão" + (at.map { ": conferido \(Fmt.ago($0))" } ?? ""))
                    .font(Type.mini).foregroundStyle(.tertiary)
                Spacer()
                Button("Abrir o painel completo") { NSWorkspace.shared.open(Readiness.panelURL) }
                    .buttonStyle(.link).font(Type.caption)
            }
        case .absent(let installed):
            VStack(alignment: .leading, spacing: 8) {
                Text("gcloud, AWS, GitHub e Docker vêm do painel de prontidão do workspace, que ainda não roda neste Mac.")
                    .font(Type.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if installed {
                    Button(monitor.runningAction == "readiness" ? "Ligando…" : "Ligar o vigia") {
                        Task { await monitor.enableReadinessWatcher() }
                    }
                    .controlSize(.small)
                    .disabled(monitor.runningAction == "readiness")
                } else {
                    HStack(spacing: 6) {
                        Text(Readiness.installCommand).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Copiar") { Clipboard.copy(Readiness.installCommand) }.controlSize(.small)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }
}

struct AccessRow: View {
    let item: AccessItem
    let monitor: Monitor
    var openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.badge)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(item.kind == .notConnecting ? Ink.alarm : Ink.ember)
                .frame(width: 28, height: 28)
                .background((item.kind == .notConnecting ? Ink.alarm : Ink.ember).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Type.strong).lineLimit(1).truncationMode(.tail)
                Text(item.detail).font(Type.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let action = item.action, let label = item.actionLabel {
                Button(running ? "…" : label) {
                    Task {
                        if await monitor.perform(action) { openSettings() }
                    }
                }
                .controlSize(.small)
                .disabled(running)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var running: Bool {
        guard let action = item.action, let running = monitor.runningAction else { return false }
        switch action {
        case .upgrade(let cask): return running == cask
        case .readinessFix(let id, _): return running == id
        default: return false
        }
    }
}
