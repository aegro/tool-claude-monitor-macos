import Foundation
import Testing
@testable import MonitorClaude

/// The settings window lists the latest `claude-accounts as` tasks from `.estado/acessos.jsonl`, the file the router
/// writes before the child runs (`codigo: null`) and completes after.
struct OneShotTasksTests {
    @Test func lêUmaTarefaComoORoteadorGrava() throws {
        let line = #"{"id":"1-1","em":1793891061844,"de":"thomas-max","conta":"principal","login":"voce@aegro.com.br","organizacao":"Aegro","ferramentas":["Artifact","Read"],"modelo":"haiku","cwd":"/tmp/x","pedido":"Publique  /x/relatorio.html\ncomo artefato","codigo":0,"ms":6000}"#
        let task = try #require(AccountRouter.parseOneShotTask(Data(line.utf8)))
        #expect(task.from == "thomas-max")
        #expect(task.account == "principal")
        #expect(task.login == "voce@aegro.com.br")
        #expect(task.organization == "Aegro")
        #expect(task.tools == ["Artifact", "Read"])
        // Line breaks and doubled spaces of the request fold into one line for the row.
        #expect(task.request == "Publique /x/relatorio.html como artefato")
        #expect(task.exitCode == 0)
        #expect(task.at == Date(timeIntervalSince1970: 1_793_891_061.844))
        #expect(task.id == "1-1")
        #expect(task.pid == 1)
    }

    @Test func pedidoDoTerminalEInacabadoTambémEntram() throws {
        let line = #"{"em":1793891061844,"de":null,"conta":"principal","codigo":null}"#
        let task = try #require(AccountRouter.parseOneShotTask(Data(line.utf8)))
        #expect(task.from == nil)
        #expect(task.exitCode == nil)
        #expect(task.tools.isEmpty)
        #expect(task.request.isEmpty)
        // Without the router's id (an older line), one is made from the time and the account.
        #expect(task.id == "1793891061844-principal")
        // Without an account or a time, the line is not a task.
        #expect(AccountRouter.parseOneShotTask(Data(#"{"em":1,"conta":""}"#.utf8)) == nil)
        #expect(AccountRouter.parseOneShotTask(Data(#"{"conta":"principal"}"#.utf8)) == nil)
        #expect(AccountRouter.parseOneShotTask(Data("not json".utf8)) == nil)
    }

    @Test func comoATarefaTerminou() {
        let at = Date(timeIntervalSince1970: 1_793_891_061)
        var task = AccountRouter.OneShotTask(id: "4242-1793891061000", at: at, from: nil, account: "principal", login: nil,
                                             organization: nil, tools: [], request: "", exitCode: 0)
        // Exit 0 is the process ending, not the request working (a delete the child could not confirm also gives 0).
        #expect(task.outcome == "terminou")
        #expect(!task.abandoned)
        task.exitCode = 2
        #expect(task.outcome == "saída 2")
        // No exit code: the parent decides, however long the task has been running.
        task.exitCode = nil
        task.parentAlive = true
        #expect(task.outcome == "rodando")
        #expect(!task.abandoned)
        task.parentAlive = false
        #expect(task.outcome == "sem fim registrado")
        #expect(task.abandoned)
    }

    @Test func oPaiÉDesteUsuárioEJáRodavaNaHoraDaTarefa() {
        // This test process: alive, this user's, started before now and after 1970.
        #expect(AccountRouter.processAlive(getpid(), startedBy: Date()))
        #expect(!AccountRouter.processAlive(getpid(), startedBy: Date(timeIntervalSince1970: 1)))
        // launchd is alive and started long ago, but it is root's: a reused pid, never the task's parent.
        #expect(!AccountRouter.processAlive(1, startedBy: Date()))
        #expect(!AccountRouter.processAlive(0, startedBy: Date()))
        #expect(AccountRouter.processAlive(getpid()))
        #expect(!AccountRouter.processAlive(0))
    }

    @Test func zumbiNãoContaComoVivo() throws {
        // A child that exited and was not reaped yet: still in the process table, same owner and start time.
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, environ) == 0)
        defer { var status: Int32 = 0; waitpid(pid, &status, 0) }
        var zombie = false
        for _ in 0..<200 where !zombie {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            zombie = sysctl(&mib, 4, &info, &size, nil, 0) == 0 && size > 0 && Int32(info.kp_proc.p_stat) == SZOMB
            if !zombie { usleep(10_000) }
        }
        try #require(zombie)
        #expect(!AccountRouter.processAlive(pid, startedBy: Date()))
    }

    @Test func aListaResolveSeOPaiAindaVive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acessos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("acessos.jsonl")
        try [#"{"id":"4242-1000","em":1000,"conta":"viva","codigo":null}"#,
             #"{"id":"4343-2000","em":2000,"conta":"morta","codigo":null}"#,
             #"{"id":"4444-3000","em":3000,"conta":"feita","codigo":0}"#,
             #"{"em":1793891061844,"conta":"sem-pid","codigo":null}"#]
            .joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        var asked: [pid_t] = []
        let tasks = AccountRouter.oneShotTasks(url: url) { pid, at in
            asked.append(pid)
            return pid == 4242 && at == Date(timeIntervalSince1970: 1)
        }
        #expect(tasks.map(\.outcome) == ["sem fim registrado", "terminou", "sem fim registrado", "rodando"])
        // Only unfinished tasks with a pid ask the kernel (an older line's made-up id, `<ms>-<account>`, has none).
        #expect(asked.sorted() == [4242, 4343])
    }

    @Test func listaAsMaisNovasPrimeiroEIgnoraLinhaQuebrada() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acessos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("acessos.jsonl")
        let lines = (1...5).map { #"{"em":\#($0)000,"conta":"c\#($0)","codigo":0}"# } + ["quebrada"]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        // A broken last line (a torn write) is skipped without costing a slot.
        #expect(AccountRouter.oneShotTasks(limit: 3, url: url).map(\.account) == ["c5", "c4", "c3"])
        #expect(AccountRouter.oneShotTasks(limit: 20, url: url).map(\.account) == ["c5", "c4", "c3", "c2", "c1"])
        #expect(AccountRouter.oneShotTasks(url: dir.appendingPathComponent("nao-existe.jsonl")).isEmpty)
    }
}
