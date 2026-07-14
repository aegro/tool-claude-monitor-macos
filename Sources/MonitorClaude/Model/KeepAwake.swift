import Foundation
import SwiftUI
import IOKit.pwr_mgt

/// Copia as duas funções do Vorssaint (estilo Amphetamine), exatamente:
///
///  - **Manter desperto** — power assertion do IOKit (`PreventUserIdleSystemSleep`), o mesmo
///    que o Vorssaint segura. Sem senha. Com uma **duração** opcional (1h/2h/4h/8h/indefinido):
///    ao esgotar, desliga sozinho.
///  - **Continuar com a tampa fechada** — `pmset disablesleep`, que exige root. Em vez de pedir
///    a senha toda vez, instala **uma regra sudoers restrita** (só `pmset disablesleep 0|1`) com
///    UM prompt de admin; depois disso alterna com `sudo -n`, sem senha — idêntico ao Vorssaint.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    enum Duration: String, CaseIterable, Identifiable {
        case h1, h2, h4, h8, indefinite
        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .h1: return 3600
            case .h2: return 7200
            case .h4: return 14400
            case .h8: return 28800
            case .indefinite: return nil
            }
        }
        var label: String {
            switch self {
            case .h1: return "1 hora"
            case .h2: return "2 horas"
            case .h4: return "4 horas"
            case .h8: return "8 horas"
            case .indefinite: return "Indefinido"
            }
        }
    }

    @Published private(set) var awake = false
    @Published private(set) var lidClosed = false
    @Published private(set) var expiresAt: Date?
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?
    @Published var duration: Duration = .indefinite {
        didSet {
            UserDefaults.standard.set(duration.rawValue, forKey: "awakeDuration")
            if awake { armTimer() }
        }
    }

    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private let user = NSUserName()
    private let sudoersPath = "/etc/sudoers.d/monitor-claude-clamshell"
    private let assertionName = "Monitor Claude: manter o Mac desperto" as CFString

    private init() {
        if let d = UserDefaults.standard.string(forKey: "awakeDuration"),
           let parsed = Duration(rawValue: d) { duration = parsed }

        lidClosed = Self.systemSleepDisabled()
        if lidClosed { setAwake(true) }
        else if UserDefaults.standard.bool(forKey: "keepAwake") { setAwake(true) }
    }

    /// Texto de estado no cabeçalho, como o "Normal sleep / Mac awake" do Vorssaint.
    var stateText: String {
        if lidClosed { return "Desperto, tampa fechada" }
        if awake {
            if let e = expiresAt {
                return "Desperto por mais \(Fmt.duration(e.timeIntervalSinceNow))"
            }
            return "Mac desperto"
        }
        return "Sono normal"
    }
    var active: Bool { awake || lidClosed }

    // MARK: manter desperto (IOKit)

    func setAwake(_ on: Bool) {
        if on {
            startAssertion()
            armTimer()
        } else {
            stopAssertion()
            timer?.invalidate(); timer = nil
            expiresAt = nil
            if lidClosed { setLidClosed(false) }   // sem sentido segurar a tampa com sono ligado
        }
        awake = on
        UserDefaults.standard.set(on, forKey: "keepAwake")
        lastError = nil
    }

    func toggleAwake() { setAwake(!awake) }

    private func startAssertion() {
        guard assertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            assertionName, &id)
        if r == kIOReturnSuccess { assertionID = id }
        else { lastError = "IOKit recusou a assertion (\(r))." }
    }

    private func stopAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    private func armTimer() {
        timer?.invalidate(); timer = nil
        guard let secs = duration.seconds else { expiresAt = nil; return }
        let end = Date().addingTimeInterval(secs)
        expiresAt = end
        let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.setAwake(false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: tampa fechada (pmset via sudoers restrito)

    func setLidClosed(_ on: Bool) {
        guard on != lidClosed, !busy else { return }
        busy = true
        lastError = nil
        Task {
            let ok = await applyLidClosed(on)
            if ok {
                lidClosed = on
                if on, !awake { setAwake(true) }
            }
            busy = false
        }
    }

    func toggleLidClosed() { setLidClosed(!lidClosed) }

    private func applyLidClosed(_ on: Bool) async -> Bool {
        let value = on ? "1" : "0"

        // Caminho rápido: a regra já existe, então nada de senha.
        if await run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", value]) {
            return true
        }
        // Instala a regra restrita com UM prompt de admin, depois tenta de novo.
        guard await installSudoersRule() else { return false }
        return await run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", value])
    }

    /// Cria /etc/sudoers.d/monitor-claude-clamshell permitindo ao usuário rodar SOMENTE
    /// `pmset disablesleep 0|1` sem senha. Valida com `visudo -c` antes de instalar. Mesmo
    /// mecanismo e mesmo escopo do Vorssaint — nenhum outro comando é liberado.
    private func installSudoersRule() async -> Bool {
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\n"
        let tmp = NSTemporaryDirectory() + "mc-clamshell.\(ProcessInfo.processInfo.processIdentifier)"
        do { try rule.write(toFile: tmp, atomically: true, encoding: .utf8) }
        catch { lastError = "Não consegui preparar a regra sudoers."; return false }

        // Uma passada de admin: valida a sintaxe, instala com dono root e modo 0440, remove o
        // temporário. Se o visudo reprovar, aborta antes de tocar em /etc/sudoers.d.
        let sh = """
        /usr/sbin/visudo -c -f '\(tmp)' >/dev/null 2>&1 || exit 3; \
        /usr/sbin/chown root:wheel '\(tmp)'; \
        /bin/chmod 440 '\(tmp)'; \
        /bin/mv -f '\(tmp)' '\(sudoersPath)'
        """
        let ok = await runAdmin(sh)
        try? FileManager.default.removeItem(atPath: tmp)
        return ok
    }

    // MARK: shell

    @discardableResult
    private func run(_ path: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit(); cont.resume(returning: p.terminationStatus == 0) }
                catch { cont.resume(returning: false) }
            }
        }
    }

    private func runAdmin(_ shell: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
                                   .replacingOccurrences(of: "\"", with: "\\\"")
                let src = "do shell script \"\(escaped)\" with administrator privileges"
                var err: NSDictionary?
                _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
                let ok = err == nil
                Task { @MainActor in
                    // -128 = usuário cancelou o diálogo de senha; não é erro a exibir.
                    if !ok, (err?["NSAppleScriptErrorNumber"] as? Int) != -128 {
                        KeepAwake.shared.lastError = "Falha ao instalar a regra de admin."
                    }
                    cont.resume(returning: ok)
                }
            }
        }
    }

    static func systemSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(separator: " ").last.map { $0 == "1" } ?? false
        }
        return false
    }
}
