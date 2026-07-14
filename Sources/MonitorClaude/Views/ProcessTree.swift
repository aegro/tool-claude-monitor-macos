import SwiftUI
import AppKit

struct ProcTree: View {
    let nodes: [ProcNode]
    let monitor: Monitor
    @Binding var expanded: Set<pid_t>
    var depth: Int = 0
    var roleFor: ((ProcInfo) -> String?)? = nil

    var body: some View {
        ForEach(nodes, id: \.id) { node in
            ProcRow(node: node, monitor: monitor, expanded: $expanded,
                    depth: depth, role: roleFor?(node.proc))

            if expanded.contains(node.id), !node.children.isEmpty {
                ProcTree(nodes: node.children, monitor: monitor,
                         expanded: $expanded, depth: depth + 1, roleFor: roleFor)
            }
        }
    }
}

struct ProcRow: View {
    let node: ProcNode
    let monitor: Monitor
    @Binding var expanded: Set<pid_t>
    var depth: Int
    var role: String?

    @State private var hovering = false

    private var isOpen: Bool { expanded.contains(node.id) }
    private var hasKids: Bool { !node.children.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if hasKids {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.tertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 9)

            if node.detached {
                Image(systemName: "link")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Ink.ember)
                    .help("Reparentado (pai virou o launchd). Religado ao dono pelo ambiente.")
            }

            Text(node.proc.display)
                .font(Type.label)
                .lineLimit(1)
                .truncationMode(.middle)

            if let role {
                Text(role)
                    .font(Type.labelTiny)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if hasKids {
                Text("\(node.children.count)")
                    .font(Type.labelTiny)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 3)
                    .background(Ink.track, in: RoundedRectangle(cornerRadius: 3))
            }

            Spacer(minLength: 6)

            if hovering {
                KillButton(target: selfTarget, monitor: monitor)
            }

            Text(Fmt.cpu(node.subtreeCPU))
                .font(Type.value)
                .foregroundStyle(node.subtreeCPU > 40 ? Ink.ember : .secondary)
                .frame(width: 44, alignment: .trailing)

            Text(Fmt.bytes(node.subtreeRSS))
                .font(Type.value)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(hovering ? Ink.track.opacity(0.7) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard hasKids else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                if isOpen { expanded.remove(node.id) } else { expanded.insert(node.id) }
            }
        }
        .contextMenu { menu }
        .help(node.proc.command)
    }

    private var selfTarget: Kill.Target {
        Kill.Target(title: node.proc.display,
                    pids: [node.proc.pid],
                    detail: ["\(node.proc.display) · \(node.proc.pid)"])
    }

    private var subtreeTarget: Kill.Target {
        Kill.Target(title: "\(node.proc.display) e os filhos",
                    pids: Kill.subtree(node),
                    detail: Kill.names(node))
    }

    @ViewBuilder
    private var menu: some View {
        Text("PID \(node.proc.pid) · \(node.proc.threads) threads")
        Button("Copiar comando") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.proc.command, forType: .string)
        }
        Divider()
        Button("Encerrar \(node.proc.display)") { Kill.confirm(selfTarget, force: false, monitor: monitor) }
        if hasKids {
            Button("Encerrar com os \(Kill.subtree(node).count - 1) filhos") {
                Kill.confirm(subtreeTarget, force: false, monitor: monitor)
            }
        }
        Divider()
        Button("Forçar encerramento") { Kill.confirm(selfTarget, force: true, monitor: monitor) }
        if hasKids {
            Button("Forçar com os filhos") { Kill.confirm(subtreeTarget, force: true, monitor: monitor) }
        }
    }
}
