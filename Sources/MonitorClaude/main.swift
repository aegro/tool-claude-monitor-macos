import Foundation
import AppKit

// Debug hatch: prints the raw /api/oauth/usage payload so the parser can be checked
// against the real shape rather than a guess.
if CommandLine.arguments.contains("--dump-usage") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let creds = try Keychain.claudeCredentials()
            print("scopes: \(creds.scopes.joined(separator: ", "))")
            print("plan: \(creds.subscriptionType ?? "?")  expired: \(creds.isExpired)")
            let (snap, raw) = try await UsageAPI.fetch(token: creds.accessToken)
            print("\n--- raw ---")
            print(String(data: raw, encoding: .utf8) ?? "<binário>")
            print("\n--- parsed ---")
            for w in snap.windows {
                let reset = w.resetsAt.map(ISO8601DateFormatter().string(from:)) ?? "?"
                print(String(format: "%-26@ %6.2f%%  pace %5.1f%%  reset %@",
                             w.key as NSString, w.utilization, w.paceTarget, reset))
            }
        } catch {
            print("erro: \(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

if CommandLine.arguments.contains("--dump-ledger") {
    let ledger = TokenLedger()
    let start = Date().addingTimeInterval(-5 * 3600)
    let t0 = Date()
    let snap = ledger.scan(blockStart: start)
    print("varredura em \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    print("entradas: \(snap.entryCount)")
    print("bloco:   total \(snap.block.total)  in \(snap.block.input)  out \(snap.block.output)  cw \(snap.block.cacheCreate)  cr \(snap.block.cacheRead)")
    print("1h:      \(snap.lastHour.total)")
    print("15min:   \(snap.last15min.total)  -> \(Int(snap.tokensPerMinute)) tok/min")
    print("sessões: \(snap.bySession.count)")
    for (k, v) in snap.bySession.sorted(by: { $0.value.total > $1.value.total }).prefix(6) {
        print("  \(k.prefix(8))  \(v.total)")
    }
    print("modelos: \(snap.byModel.mapValues { $0.total })")
    print("buckets: \(snap.buckets.count)")
    exit(0)
}

if CommandLine.arguments.contains("--dump-tree") {
    let sampler = ProcessSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1.0)
    let procs = sampler.sample()
    let sessions = ClaudeSessionStore.load()
    let a = Attribution.build(procs: procs, sessions: sessions)

    print("processos amostrados: \(procs.count)")
    print("atribuídos:           \(a.accountedPIDs)")
    print(procs.count == a.accountedPIDs
          ? "OK — partição exata, nada duplicado e nada perdido"
          : "FALHA — \(procs.count - a.accountedPIDs) processos fora das listas")
    print("")
    print("CLAUDE TOTAL: \(a.claudeProcCount) processos · \(String(format: "%.1f", a.claudeCPU))% CPU · \(Fmt.bytes(a.claudeRSS))")
    print("")

    func show(_ n: ProcNode, _ d: Int) {
        let pad = String(repeating: "  ", count: d)
        let mark = n.detached ? " ⟲religado(ppid=\(n.proc.ppid))" : ""
        let role = Classify.role(n.proc).map { " [\($0)]" } ?? ""
        print(String(format: "%@%-28@ %6.1f%% %8@  pid=%-6d%@%@",
                     pad, n.proc.display as NSString, n.subtreeCPU,
                     Fmt.bytes(n.subtreeRSS) as NSString, n.proc.pid, role as NSString, mark as NSString))
        for c in n.children.prefix(6) { show(c, d + 1) }
    }

    for b in a.sessionBuckets {
        print("▸ SESSÃO \(b.session.displayName)  [\(b.session.status ?? "?")]")
        print("   \(b.procCount) proc · \(String(format: "%.1f", b.cpu))% · \(Fmt.bytes(b.rss))"
              + (b.chromeCount > 0 ? " · CHROME ×\(b.chromeCount) \(b.chromeNames.joined(separator: ","))" : ""))
        for r in b.roots.prefix(8) { show(r, 1) }
        print("")
    }
    for g in a.ghostBuckets {
        print("▸ ÓRFÃOS de sessão encerrada \(g.sessionId.prefix(8)) — \(g.procCount) proc · \(String(format: "%.1f", g.cpu))%")
        for r in g.roots.prefix(8) { show(r, 1) }
        print("")
    }
    print("▸ INFRA DO CLAUDE (daemon + pool): \(a.infraCount) proc · \(String(format: "%.1f", a.infraCPU))% · \(Fmt.bytes(a.infraRSS))")
    for r in a.infraRoots.prefix(3) { show(r, 1) }
    print("")
    print("▸ CHROME SEU: \(a.chromeRoots.count) instâncias")
    for r in a.chromeRoots.prefix(3) { show(r, 1) }
    print("")
    print("▸ OUTROS (top 8)")
    for r in a.otherRoots.prefix(8) { show(r, 1) }
    exit(0)
}

if CommandLine.arguments.contains("--preview") {
    NSApplication.shared.setActivationPolicy(.regular)
    PreviewApp.main()
} else {
    NSApplication.shared.setActivationPolicy(.accessory)
    MonitorApp.main()
}
