import Foundation

/// Claude Code writes ~/.claude/sessions/<pid>.json for every live session,
/// which is what lets us name a process instead of showing "claude bg-spare".
struct ClaudeSession: Identifiable, Equatable {
    var pid: pid_t
    var sessionId: String
    var cwd: String
    var name: String?
    var status: String?        // busy | idle | ...
    var kind: String?          // bg | interactive
    var agent: String?
    var jobId: String?
    var startedAt: Date?
    var updatedAt: Date?
    /// The router account the session was opened on. In `~/.claude` that is the router's `CLAUDE_AUTO_CONTA` mark on
    /// the process, when it names a queue account; otherwise, and without a mark, the account whose config directory
    /// holds the session file. nil for `~/.claude` when no router is set up.
    var accountId: String?

    var id: pid_t { pid }
    var isBusy: Bool { status == "busy" }
    var isBackground: Bool { kind == "bg" }

    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? sessionId.prefix(8).description : base
    }

    var project: String {
        (cwd as NSString).lastPathComponent
    }
}

enum ClaudeSessionStore {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// What the sampler read from a live process: the router account it was opened on (`CLAUDE_AUTO_CONTA`) and
    /// when it started.
    typealias ProcessMark = (account: String, started: Date)

    /// Sessions from `~/.claude` plus every router account directory: a session opened on an extra account writes
    /// its file under that account's own `sessions/`, which is not linked to `~/.claude`. `openedOn` answers from
    /// what the process sampler already read, so a tick never re-reads a process's environment.
    static func load(accounts: [(id: String?, directory: URL)] = [], defaultDirectory: URL = root,
                     openedOn: (pid_t) -> ProcessMark? = { _ in nil }) -> [ClaudeSession] {
        let known = Set(accounts.compactMap(\.id))
        var seen = Set<pid_t>()
        var out: [ClaudeSession] = []
        var dirs: [(String?, URL)] = accounts.map { ($0.id, $0.directory) }
        // Resolve symlinks first: an account `dir` that aliases `~/.claude` is the same folder, and scanning it
        // as the nil account first would win the pid dedup and drop the account marker.
        func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
        let defaultCanonical = canonical(defaultDirectory)
        if !dirs.contains(where: { canonical($0.1) == defaultCanonical }) {
            dirs.insert((nil, defaultDirectory), at: 0)
        }
        for (id, dir) in dirs {
            let isDefault = canonical(dir) == defaultCanonical
            for var session in load(directory: dir.appendingPathComponent("sessions"), accountId: id)
            where !seen.contains(session.pid) {
                seen.insert(session.pid)
                // The folder says where the session lives; the router's mark on the process says which account it
                // was opened on. They differ only in `~/.claude`, after the agents' switch moves another account
                // in: a session opened there before the switch still runs on the account that left. Elsewhere the
                // folder is the account. The mark counts only for the process that wrote the file: one that
                // started after the session did is a reused pid behind a stale file.
                if isDefault, let mark = openedOn(session.pid), known.contains(mark.account),
                   let startedAt = session.startedAt, mark.started <= startedAt.addingTimeInterval(1) {
                    session.accountId = mark.account
                }
                out.append(session)
            }
        }
        return out.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    static func load(directory dir: URL, accountId: String?) -> [ClaudeSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }

        var out: [ClaudeSession] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = d["pid"] as? Int,
                  let sid = d["sessionId"] as? String
            else { continue }

            // Stale files linger after a crash; drop anything whose pid is gone.
            guard kill(pid_t(pid), 0) == 0 || errno == EPERM else { continue }

            out.append(ClaudeSession(
                pid: pid_t(pid),
                sessionId: sid,
                cwd: (d["cwd"] as? String) ?? "",
                name: d["name"] as? String,
                status: d["status"] as? String,
                kind: d["kind"] as? String,
                agent: d["agent"] as? String,
                jobId: d["jobId"] as? String,
                startedAt: (d["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                updatedAt: (d["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                accountId: accountId
            ))
        }
        return out
    }
}
