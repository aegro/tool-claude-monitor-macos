import Foundation

/// An organization the Claude desktop app has usage for. Thinner than a `AccountRecord` on
/// purpose: the desktop app records only the two headline percentages, so these render as a
/// summary strip and never expand.
struct DesktopOrgUsage: Equatable, Identifiable {
    var organizationUuid: String
    var label: String
    var plan: String?
    var fiveHour: Double
    var weekly: Double
    var seenAt: Date

    var id: String { organizationUuid }
}

/// Reads what the Claude desktop app leaves on disk about organizations *other* than the one the
/// terminal is logged into. The desktop app keeps its own login, in its own keychain items, so
/// switching organizations there is invisible to everything the Monitor reads from Claude Code.
/// Its usage history, though, is plain JSON and covers every organization you have opened.
///
/// This reads a private, undocumented file of another app: treat every field as optional and every
/// shape as provisional. `version` is checked so that a future format change makes the desktop
/// organizations quietly disappear instead of rendering nonsense. Read-only, and no credential is
/// touched: the desktop token is encrypted with Electron's safeStorage and we deliberately stay
/// away from it.
enum ClaudeDesktop {
    /// The format this reader was written against.
    static let supportedVersion = 2

    static var supportDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    static func organizationUsage() -> [DesktopOrgUsage] {
        let url = supportDir.appendingPathComponent("plan-usage-history.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parseUsage(data, names: organizationNames())
    }

    /// Latest sample per organization. Samples look like
    /// `{"t": <epoch ms>, "org": "<uuid>", "u": {"fh": <5h %>, "sd": <7d %>}}`.
    static func parseUsage(_ data: Data,
                           names: [String: (name: String?, type: String?)]) -> [DesktopOrgUsage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["version"] as? Int) == supportedVersion,
              let samples = root["samples"] as? [[String: Any]]
        else { return [] }

        var latest: [String: DesktopOrgUsage] = [:]
        for s in samples {
            guard let org = s["org"] as? String, !org.isEmpty,
                  let millis = numeric(s["t"]),
                  let u = s["u"] as? [String: Any],
                  let fh = numeric(u["fh"]), let sd = numeric(u["sd"])
            else { continue }

            let at = Date(timeIntervalSince1970: millis / 1000)
            if let seen = latest[org], seen.seenAt >= at { continue }

            let known = names[org]
            latest[org] = DesktopOrgUsage(
                organizationUuid: org,
                label: label(forOrg: org, name: known?.name),
                plan: known?.type.map { $0.replacingOccurrences(of: "claude_", with: "") },
                fiveHour: UsageAPI.clamp(fh),
                weekly: UsageAPI.clamp(sd),
                seenAt: at
            )
        }
        return latest.values.sorted { $0.seenAt > $1.seenAt }
    }

    /// The desktop app writes a Claude Code config per organization under
    /// `local-agent-mode-sessions/<account>/<organization>/…/.claude/.claude.json`, which is where
    /// the organization's name can be recovered. Without it we would be showing a bare uuid.
    static func organizationNames() -> [String: (name: String?, type: String?)] {
        let root = supportDir.appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [:] }

        var found: [String: (name: String?, type: String?)] = [:]
        for account in accounts {
            guard let orgs = try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)
            else { continue }
            for org in orgs {
                let uuid = org.lastPathComponent
                guard uuid.count == 36, found[uuid] == nil else { continue }
                if let identity = firstConfig(under: org) {
                    found[uuid] = (identity.organizationName, identity.organizationType)
                }
            }
        }
        return found
    }

    /// The per-organization config sits a couple of levels down, under a session directory whose
    /// name we cannot predict, so we look for the first one that actually names the organization.
    private static func firstConfig(under org: URL) -> AccountIdentity? {
        let fm = FileManager.default
        guard let sessions = try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)
        else { return nil }

        for session in sessions {
            let config = session.appendingPathComponent(".claude/.claude.json")
            guard let data = try? Data(contentsOf: config),
                  let identity = ClaudeConfig.parseActiveAccount(data),
                  identity.organizationName?.isEmpty == false
            else { continue }
            return identity
        }
        return nil
    }

    static func label(forOrg uuid: String, name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !AccountIdentity.isPersonalOrgName(trimmed) else {
            return trimmed.isEmpty ? String(uuid.prefix(8)) : "Pessoal"
        }
        return trimmed
    }

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}
