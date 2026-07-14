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

    static func load() -> [ClaudeSession] {
        let dir = root.appendingPathComponent("sessions")
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
                updatedAt: (d["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            ))
        }
        return out.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }
}
