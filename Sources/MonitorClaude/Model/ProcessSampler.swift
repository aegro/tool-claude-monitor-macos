import Foundation
import Darwin

/// What a process's environment says about who spawned it.
///
/// This is the load-bearing idea of the whole tool. Parent pids lie: anything reparented to
/// launchd (a daemonised worker, an app opened through LaunchServices) loses its lineage and
/// surfaces as a stray process under the shell. The environment does not lie, because it is
/// copied at exec and survives the parent's death. Claude Code stamps every process it spawns
/// with CLAUDE_CODE_SESSION_ID, which is the same UUID as ~/.claude/sessions/<pid>.json and
/// the transcript filename, so a single env read gives exact attribution.
struct ClaudeEnv: Hashable {
    var sessionId: String?      // CLAUDE_CODE_SESSION_ID
    var jobId: String?          // basename of CLAUDE_JOB_DIR
    var spawnedByClaude = false // CLAUDECODE=1
    var isEmpty: Bool { sessionId == nil && jobId == nil && !spawnedByClaude }
}

struct ProcInfo: Identifiable, Hashable {
    var pid: pid_t
    var ppid: pid_t
    var name: String          // short exec name
    var command: String       // full argv, best effort
    var execPath: String
    var rss: UInt64           // resident bytes
    var cpuPercent: Double    // instantaneous, 0...100*ncpu
    var threads: Int
    var started: Date
    var claude = ClaudeEnv()
    var responsiblePID: pid_t = 0   // LaunchServices attribution, for `open -a` style launches

    var id: pid_t { pid }

    /// The claude binary lives at ~/.local/share/claude/versions/<version>, so its process name
    /// is a version string. Nobody wants to read "2.1.209" in a process list.
    var display: String {
        Classify.kind(self) == .claudeCode ? "claude" : name
    }
}

/// A process plus its descendants, with subtree totals.
final class ProcNode: Identifiable {
    let proc: ProcInfo
    var children: [ProcNode] = []
    var subtreeCPU: Double = 0
    var subtreeRSS: UInt64 = 0

    /// True when this node's real parent is outside the bucket it was placed in — i.e. the
    /// process was reparented away (usually to launchd) and we pulled it back to its owner
    /// through the environment instead of through ppid. Worth showing: it is the case that
    /// every other monitor gets wrong.
    var detached = false

    var id: pid_t { proc.pid }

    init(_ proc: ProcInfo) {
        self.proc = proc
        self.subtreeCPU = proc.cpuPercent
        self.subtreeRSS = proc.rss
    }
}

/// Samples every visible process with libproc and derives instantaneous CPU% from
/// deltas of cumulative CPU time. The first sample has no baseline, so CPU reads 0.
final class ProcessSampler {
    private struct Prev {
        var cpuNanos: UInt64
        var started: Date
    }

    private var prev: [pid_t: Prev] = [:]
    private var lastSampleAt: Date?
    private var argvCache: [pid_t: (started: Date, argv: String, claude: ClaudeEnv)] = [:]

    let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)

    func sample() -> [ProcInfo] {
        let now = Date()
        let elapsed = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        defer { lastSampleAt = now }

        let pids = listPIDs()
        var out: [ProcInfo] = []
        out.reserveCapacity(pids.count)
        var nextPrev: [pid_t: Prev] = [:]
        nextPrev.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let all = taskAllInfo(pid) else { continue }

            let started = Date(timeIntervalSince1970: Double(all.pbsd.pbi_start_tvsec))
            let cpuNanos = all.ptinfo.pti_total_user &+ all.ptinfo.pti_total_system
            nextPrev[pid] = Prev(cpuNanos: cpuNanos, started: started)

            var cpu = 0.0
            if elapsed > 0.05, let p = prev[pid], p.started == started, cpuNanos >= p.cpuNanos {
                let deltaSeconds = Double(cpuNanos - p.cpuNanos) / 1_000_000_000
                cpu = deltaSeconds / elapsed * 100
            }

            let name = withUnsafeBytes(of: all.pbsd.pbi_name) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                let s = String(cString: bytes.baseAddress!)
                return s.isEmpty ? shortComm(all.pbsd.pbi_comm) : s
            }

            let (argv, claudeEnv) = cachedArgs(pid: pid, started: started)
            let path = execPath(pid)

            out.append(ProcInfo(
                pid: pid,
                ppid: pid_t(all.pbsd.pbi_ppid),
                name: name,
                command: argv ?? name,
                execPath: path ?? "",
                rss: all.ptinfo.pti_resident_size,
                cpuPercent: min(cpu, coreCount * 100),
                threads: Int(all.ptinfo.pti_threadnum),
                started: started,
                claude: claudeEnv,
                responsiblePID: Responsibility.responsible(for: pid)
            ))
        }

        prev = nextPrev
        argvCache = argvCache.filter { nextPrev[$0.key] != nil }
        return out
    }

    // MARK: tree

    /// Builds the forest for one bucket of pids. A pid whose parent is outside the bucket
    /// becomes a root of that bucket and is flagged `detached`, which is how a reparented
    /// worker gets shown under the Claude session that actually spawned it.
    static func subForest(of pids: Set<pid_t>, from index: [pid_t: ProcInfo],
                          markDetached: Bool = false) -> [ProcNode] {
        var nodes: [pid_t: ProcNode] = [:]
        for pid in pids {
            guard let p = index[pid] else { continue }
            nodes[pid] = ProcNode(p)
        }

        var roots: [ProcNode] = []
        for (pid, node) in nodes {
            let ppid = node.proc.ppid
            if let parent = nodes[ppid], parent !== node {
                parent.children.append(node)
            } else {
                // Flag only true orphans: the parent is gone or is launchd, so ppid told us
                // nothing and the environment is what linked this process to its owner.
                node.detached = markDetached && (ppid <= 1 || index[ppid] == nil)
                roots.append(node)
            }
            _ = pid
        }

        func accumulate(_ n: ProcNode) {
            for c in n.children { accumulate(c) }
            n.subtreeCPU = n.proc.cpuPercent + n.children.reduce(0) { $0 + $1.subtreeCPU }
            n.subtreeRSS = n.proc.rss + n.children.reduce(0) { $0 + $1.subtreeRSS }
            n.children.sort { $0.subtreeCPU > $1.subtreeCPU }
        }
        for r in roots { accumulate(r) }
        roots.sort { $0.subtreeCPU > $1.subtreeCPU }
        return roots
    }

    // MARK: libproc plumbing

    private func listPIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                    Int32(capacity * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        let n = Int(written) / MemoryLayout<pid_t>.size
        return Array(pids[0..<n])
    }

    private func taskAllInfo(_ pid: pid_t) -> proc_taskallinfo? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        return r == size ? info : nil
    }

    private func execPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        let r = proc_pidpath(pid, &buf, UInt32(buf.count))
        return r > 0 ? String(cString: buf) : nil
    }

    private func shortComm(_ comm: Any) -> String {
        withUnsafeBytes(of: comm) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
    }

    /// argv and env are fixed for the life of a pid, so cache them keyed by (pid, start time).
    private func cachedArgs(pid: pid_t, started: Date) -> (String?, ClaudeEnv) {
        if let hit = argvCache[pid], hit.started == started { return (hit.argv, hit.claude) }
        guard let parsed = Self.argsAndEnv(pid: pid) else { return (nil, ClaudeEnv()) }
        argvCache[pid] = (started, parsed.argv, parsed.claude)
        return (parsed.argv, parsed.claude)
    }

    /// KERN_PROCARGS2 layout:
    ///   [argc: Int32][exec path \0][alignment \0s][argv[0] \0]…[argv[argc-1] \0][env entries \0]…
    /// Everything after the argv run is the environment, which is where the Claude markers are.
    /// Only readable for our own uid, which is exactly the set we care about.
    static func argsAndEnv(pid: pid_t) -> (argv: String, claude: ClaudeEnv)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<4]) }
        guard argc > 0 else { return nil }

        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }

        var args: [String] = []
        var claude = ClaudeEnv()
        var current: [UInt8] = []

        func take() -> String {
            defer { current.removeAll(keepingCapacity: true) }
            return String(decoding: current, as: UTF8.self)
        }

        while i < size {
            if buf[i] == 0 {
                let s = take()
                if args.count < Int(argc) {
                    args.append(s)
                } else if !s.isEmpty {
                    absorb(env: s, into: &claude)
                }
            } else {
                current.append(buf[i])
            }
            i += 1
        }

        let joined = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (joined, claude)
    }

    private static func absorb(env: String, into claude: inout ClaudeEnv) {
        guard env.hasPrefix("CLAUDE") else { return }
        guard let eq = env.firstIndex(of: "=") else { return }
        let key = String(env[..<eq])
        let value = String(env[env.index(after: eq)...])

        switch key {
        case "CLAUDE_CODE_SESSION_ID":
            claude.sessionId = value
        case "CLAUDE_JOB_DIR":
            claude.jobId = (value as NSString).lastPathComponent
        case "CLAUDECODE":
            claude.spawnedByClaude = value == "1"
        default:
            break
        }
    }
}

/// macOS tracks a "responsible process" for privacy attribution. It is the only thread back to
/// the launcher when an app is started through LaunchServices (`open -a Chrome`), because that
/// path gives the child neither the caller's ppid nor the caller's environment.
enum Responsibility {
    private typealias Fn = @convention(c) (pid_t) -> pid_t

    private static let fn: Fn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func responsible(for pid: pid_t) -> pid_t {
        guard let fn else { return 0 }
        let r = fn(pid)
        return (r > 0 && r != pid) ? r : 0
    }
}


enum ProcKind { case claudeCode, claudeApp, chrome, other }

/// Classification is pure and runs on the sampling queue, so it must not be actor-isolated.
enum Classify {
    static func kind(_ p: ProcInfo) -> ProcKind {
        let path = p.execPath
        if path.contains("/Applications/Claude.app") { return .claudeApp }
        if path.contains("/.local/share/claude/") || path.contains("/.local/bin/claude")
            || p.name == "claude" || p.command.hasPrefix("claude ") { return .claudeCode }
        if path.contains("Google Chrome") || path.contains("Chromium")
            || p.name.contains("Google Chrome") || p.name.contains("Chromium") { return .chrome }
        return .other
    }

    static func role(_ p: ProcInfo) -> String? {
        switch kind(p) {
        case .claudeCode: return claudeRole(p)
        case .claudeApp: return "app Claude"
        case .chrome: return chromeRole(p)
        case .other: return nil
        }
    }

    static func claudeRole(_ p: ProcInfo) -> String {
        if p.command.contains("daemon run") { return "daemon" }
        if p.command.contains("bg-pty-host") { return "pty host" }
        if p.command.contains("bg-spare") { return "sessão" }
        return "cli"
    }

    /// Chrome helpers announce their job in --type=.
    static func chromeRole(_ p: ProcInfo) -> String {
        guard let r = p.command.range(of: "--type=") else { return "navegador" }
        let type = p.command[r.upperBound...].prefix { !$0.isWhitespace }
        switch type {
        case "renderer": return p.command.contains("--extension-process") ? "extensão" : "aba"
        case "gpu-process": return "GPU"
        case "utility": return "utilitário"
        case "": return "navegador"
        default: return String(type)
        }
    }
}
