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
        let vivo: (pid_t, Date) -> Bool = { pid, _ in pid == 4242 }
        let morto: (pid_t, Date) -> Bool = { _, _ in false }
        // Exit 0 is the process ending, not the request working (a delete the child could not confirm also gives 0).
        #expect(task.outcome(isAlive: morto) == "terminou")
        #expect(!task.abandoned(isAlive: morto))
        task.exitCode = 2
        #expect(task.outcome(isAlive: morto) == "saída 2")
        // No exit code: the process decides, however long the task has been running.
        task.exitCode = nil
        #expect(task.outcome(isAlive: vivo) == "rodando")
        #expect(!task.abandoned(isAlive: vivo))
        #expect(task.outcome(isAlive: morto) == "sem fim registrado")
        #expect(task.abandoned(isAlive: morto))
        // An id without a pid cannot be checked, so it is not counted as running.
        task.id = "sem-pid"
        #expect(task.abandoned(isAlive: { _, _ in true }))
        // The real check: this test process is alive, pid 0 never counts.
        #expect(AccountRouter.processAlive(getpid()))
        #expect(!AccountRouter.processAlive(0))
        // A pid reused by a newer process is not the task's parent: this process started before now, not before 1970.
        #expect(AccountRouter.processAlive(getpid(), startedBy: Date()))
        #expect(!AccountRouter.processAlive(getpid(), startedBy: Date(timeIntervalSince1970: 1)))
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
