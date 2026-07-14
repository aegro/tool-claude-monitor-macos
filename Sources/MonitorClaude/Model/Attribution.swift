import Foundation

/// Who a process really belongs to.
///
/// Parent pids are not enough. Claude spawns work that outlives its shell, gets reparented to
/// launchd, and then looks like a stray `java` or `node` sitting under nothing. So ownership is
/// resolved in order of how much each signal can be trusted:
///
///   1. the process IS a Claude session (we have its pid from ~/.claude/sessions)
///   2. its environment names a session (CLAUDE_CODE_SESSION_ID) — survives reparenting
///   3. its environment names a job (CLAUDE_JOB_DIR) — same, one level coarser
///   4. its nearest ancestor resolves to one of the above
///   5. its LaunchServices "responsible process" resolves to one of the above — the only thread
///      back to the launcher for `open -a`, which passes neither ppid nor environment
///
/// Every process lands in exactly one bucket. Nothing is counted twice, and nothing is dropped.
enum Owner: Hashable {
    case session(String)        // sessionId of a session that is still running
    case ghost(String)          // spawned by Claude, but that session is gone
    case unowned
}

struct SessionBucket: Identifiable {
    var session: ClaudeSession
    var roots: [ProcNode]
    var cpu: Double
    var rss: UInt64
    var procCount: Int
    var chromeCount: Int
    var chromeNames: [String]
    var id: pid_t { session.pid }
}

struct GhostBucket: Identifiable {
    var sessionId: String
    var roots: [ProcNode]
    var cpu: Double
    var rss: UInt64
    var procCount: Int
    var id: String { sessionId }
}

struct Attribution {
    var owner: [pid_t: Owner] = [:]
    var sessionBuckets: [SessionBucket] = []
    var ghostBuckets: [GhostBucket] = []
    var chromeRoots: [ProcNode] = []     // Chrome NOT attributable to any Claude
    var infraRoots: [ProcNode] = []      // the Claude daemon and its spare pool
    var infraCPU: Double = 0
    var infraRSS: UInt64 = 0
    var infraCount = 0
    var otherRoots: [ProcNode] = []
    var claudeCPU: Double = 0
    var claudeRSS: UInt64 = 0
    var claudeProcCount = 0
    var accountedPIDs = 0                // must equal the sampled process count

    static func build(procs: [ProcInfo], sessions: [ClaudeSession]) -> Attribution {
        var a = Attribution()

        let index = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        let sessionByPID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0) })
        let sessionByID = Dictionary(sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let sessionByJob = Dictionary(sessions.compactMap { s in s.jobId.map { ($0, s) } },
                                      uniquingKeysWith: { a, _ in a })

        // Memoised, cycle-safe resolution.
        var memo: [pid_t: Owner] = [:]
        var visiting: Set<pid_t> = []

        func resolve(_ pid: pid_t) -> Owner {
            if let hit = memo[pid] { return hit }
            guard let p = index[pid], pid > 1 else { return .unowned }
            if visiting.contains(pid) { return .unowned }   // defensive: ppid loops do happen
            visiting.insert(pid)
            defer { visiting.remove(pid) }

            var result: Owner = .unowned

            if let s = sessionByPID[pid] {
                result = .session(s.sessionId)
            } else if let sid = p.claude.sessionId {
                result = sessionByID[sid] != nil ? .session(sid) : .ghost(sid)
            } else if let job = p.claude.jobId, let s = sessionByJob[job] {
                result = .session(s.sessionId)
            } else {
                let up = resolve(p.ppid)
                if up != .unowned {
                    result = up
                } else if p.responsiblePID > 0, p.responsiblePID != p.ppid {
                    let r = resolve(p.responsiblePID)
                    if r != .unowned { result = r }
                }
                if result == .unowned, p.claude.spawnedByClaude {
                    result = .ghost("desconhecida")   // marked by CLAUDECODE=1, lineage lost
                }
            }

            memo[pid] = result
            return result
        }

        for p in procs { a.owner[p.pid] = resolve(p.pid) }

        // A background session is spawned as: daemon -> pty-host -> session. The pty-host is
        // dedicated 1:1 to that session, but carries no session id of its own, so resolve()
        // leaves it unowned. Claim it explicitly, or it lands in "other" and the session's
        // own root looks like an orphan.
        for s in sessions {
            var pid = index[s.pid]?.ppid ?? 0
            var hops = 0
            while hops < 2, let p = index[pid],
                  Classify.kind(p) == .claudeCode,
                  !p.command.contains("daemon run"),
                  memo[pid] == .unowned || memo[pid] == nil {
                memo[pid] = .session(s.sessionId)
                a.owner[pid] = .session(s.sessionId)
                pid = p.ppid
                hops += 1
            }
        }

        // Partition. A pid appears in exactly one of these sets, by construction.
        var bySession: [String: Set<pid_t>] = [:]
        var byGhost: [String: Set<pid_t>] = [:]
        var chromePIDs: Set<pid_t> = []
        var infraPIDs: Set<pid_t> = []
        var otherPIDs: Set<pid_t> = []

        for p in procs {
            switch a.owner[p.pid] ?? .unowned {
            case .session(let sid):
                bySession[sid, default: []].insert(p.pid)
                a.claudeCPU += p.cpuPercent
                a.claudeRSS += p.rss
                a.claudeProcCount += 1
            case .ghost(let sid):
                byGhost[sid, default: []].insert(p.pid)
                a.claudeCPU += p.cpuPercent
                a.claudeRSS += p.rss
                a.claudeProcCount += 1
            case .unowned:
                switch Classify.kind(p) {
                case .chrome:
                    chromePIDs.insert(p.pid)
                case .claudeCode:
                    infraPIDs.insert(p.pid)          // daemon, idle spares, pty hosts
                    a.claudeCPU += p.cpuPercent
                    a.claudeRSS += p.rss
                    a.claudeProcCount += 1
                    a.infraCPU += p.cpuPercent
                    a.infraRSS += p.rss
                    a.infraCount += 1
                default:
                    otherPIDs.insert(p.pid)
                }
            }
        }

        a.accountedPIDs = bySession.values.reduce(0) { $0 + $1.count }
            + byGhost.values.reduce(0) { $0 + $1.count }
            + chromePIDs.count + infraPIDs.count + otherPIDs.count

        for (sid, pids) in bySession {
            guard let session = sessionByID[sid] else { continue }
            let roots = ProcessSampler.subForest(of: pids, from: index, markDetached: true)
            let chrome = pids.compactMap { index[$0] }.filter { Classify.kind($0) == .chrome }
            a.sessionBuckets.append(SessionBucket(
                session: session,
                roots: roots,
                cpu: roots.reduce(0) { $0 + $1.subtreeCPU },
                rss: roots.reduce(UInt64(0)) { $0 + $1.subtreeRSS },
                procCount: pids.count,
                chromeCount: chrome.count,
                chromeNames: Array(Set(chrome.compactMap(Self.chromeProfile))).sorted()
            ))
        }

        for (sid, pids) in byGhost {
            let roots = ProcessSampler.subForest(of: pids, from: index, markDetached: true)
            a.ghostBuckets.append(GhostBucket(
                sessionId: sid,
                roots: roots,
                cpu: roots.reduce(0) { $0 + $1.subtreeCPU },
                rss: roots.reduce(UInt64(0)) { $0 + $1.subtreeRSS },
                procCount: pids.count
            ))
        }

        a.chromeRoots = ProcessSampler.subForest(of: chromePIDs, from: index)
        a.infraRoots = ProcessSampler.subForest(of: infraPIDs, from: index)
        a.otherRoots = ProcessSampler.subForest(of: otherPIDs, from: index)

        a.sessionBuckets.sort { $0.cpu > $1.cpu }
        a.ghostBuckets.sort { $0.cpu > $1.cpu }
        return a
    }

    /// A Chrome launched by an agent almost always carries its own profile directory.
    /// That name is the most human-readable way to say *which* browser this is.
    static func chromeProfile(_ p: ProcInfo) -> String? {
        guard let r = p.command.range(of: "--user-data-dir=") else { return nil }
        let rest = p.command[r.upperBound...]
        let path = rest.prefix { !$0.isWhitespace }
        return (String(path) as NSString).lastPathComponent
    }
}
