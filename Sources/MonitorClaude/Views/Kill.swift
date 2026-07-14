import SwiftUI
import AppKit

/// Killing things is the one destructive act this tool performs, so it is always explicit:
/// every menu says exactly how many processes will die, and nothing dies without a confirmation
/// that names them.
enum Kill {
    struct Target {
        var title: String          // "a sessão Animação IA"
        var pids: [pid_t]
        var detail: [String]       // names, for the confirmation
    }

    /// Every pid in a subtree, deepest first, so parents cannot orphan their children mid-kill.
    static func subtree(_ node: ProcNode) -> [pid_t] {
        var out: [pid_t] = []
        func walk(_ n: ProcNode) {
            for c in n.children { walk(c) }
            out.append(n.proc.pid)
        }
        walk(node)
        return out
    }

    static func names(_ node: ProcNode, limit: Int = 8) -> [String] {
        var out: [String] = []
        func walk(_ n: ProcNode) {
            out.append("\(n.proc.display) · \(n.proc.pid)")
            for c in n.children { walk(c) }
        }
        walk(node)
        return Array(out.prefix(limit)) + (out.count > limit ? ["e mais \(out.count - limit)…"] : [])
    }

    @MainActor
    static func confirm(_ target: Target, force: Bool, monitor: Monitor) {
        guard !target.pids.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = force ? .critical : .warning
        alert.messageText = force
            ? "Forçar o encerramento de \(target.title)?"
            : "Encerrar \(target.title)?"

        var info = target.pids.count == 1
            ? "1 processo."
            : "\(target.pids.count) processos."
        if force {
            info += " SIGKILL não deixa nada salvar nem limpar."
        } else {
            info += " SIGTERM: cada um decide como sair."
        }
        if !target.detail.isEmpty {
            info += "\n\n" + target.detail.joined(separator: "\n")
        }
        alert.informativeText = info

        alert.addButton(withTitle: force ? "Forçar" : "Encerrar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            monitor.terminate(target.pids, force: force)
        }
    }
}

/// The kill entries shared by every row, so the vocabulary never drifts between them.
struct KillMenu: View {
    let target: Kill.Target
    let monitor: Monitor
    var extra: (() -> AnyView)? = nil

    var body: some View {
        Button("Encerrar \(target.title)") {
            Kill.confirm(target, force: false, monitor: monitor)
        }
        Button("Forçar encerramento") {
            Kill.confirm(target, force: true, monitor: monitor)
        }
    }
}

/// A hover-revealed ✕. Right-click menus are fine, but a kill switch nobody can find is not
/// a kill switch.
struct KillButton: View {
    let target: Kill.Target
    let monitor: Monitor
    @State private var hot = false

    var body: some View {
        Button {
            Kill.confirm(target, force: NSEvent.modifierFlags.contains(.option), monitor: monitor)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(hot ? Ink.alarm : Color.secondary.opacity(0.55))
        }
        .buttonStyle(.plain)
        .onHover { hot = $0 }
        .help("Encerrar \(target.title) (\(target.pids.count) proc). Segure ⌥ para forçar.")
    }
}
