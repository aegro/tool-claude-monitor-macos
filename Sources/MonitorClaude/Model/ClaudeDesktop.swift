import Foundation

/// One reading the desktop app wrote down: the two headline percentages and when it took them.
/// The app polls the same endpoint the Monitor does, every five minutes, so a run of these is a
/// usable substitute for our own polling when the terminal token is gone.
struct DesktopSample: Equatable {
    var at: Date
    var fiveHour: Double
    var weekly: Double
}

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

    private static var historyURL: URL {
        supportDir.appendingPathComponent("plan-usage-history.json")
    }

    static func organizationUsage() -> [DesktopOrgUsage] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return parseUsage(data, names: organizationNames())
    }

    /// Every reading the app kept, per organization, oldest first — the raw material for both the
    /// summary strips and the live fallback. Reading the whole file each poll is fine: it is a few
    /// hundred samples and the app prunes it itself.
    static func samplesByOrg() -> [String: [DesktopSample]] {
        guard let data = try? Data(contentsOf: historyURL) else { return [:] }
        return parseSamples(data)
    }

    /// Samples look like `{"t": <epoch ms>, "org": "<uuid>", "u": {"fh": <5h %>, "sd": <7d %>}}`.
    /// Anything that does not match is skipped rather than failing the whole read: this is another
    /// app's private file and one odd row must not cost us the other three hundred.
    static func parseSamples(_ data: Data) -> [String: [DesktopSample]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["version"] as? Int) == supportedVersion,
              let samples = root["samples"] as? [[String: Any]]
        else { return [:] }

        var byOrg: [String: [DesktopSample]] = [:]
        for s in samples {
            guard let org = s["org"] as? String, !org.isEmpty,
                  let millis = numeric(s["t"]), plausibleEpochMillis(millis),
                  let u = s["u"] as? [String: Any],
                  let fh = numeric(u["fh"]), let sd = numeric(u["sd"]),
                  // Skipped, not clamped. `UsageAPI.clamp` maps a nonsense percentage to 0, which
                  // is fine for a single displayed reading but poisonous in a series: a fabricated
                  // zero reads to the reset derivation as a window turning over, and it will date
                  // a reset off a boundary that never happened. Known live source of nonsense —
                  // the endpoint leaks an epoch timestamp into the field (claude-code#52326).
                  inRange(fh), inRange(sd)
            else { continue }

            byOrg[org, default: []].append(DesktopSample(
                at: Date(timeIntervalSince1970: millis / 1000),
                fiveHour: fh,
                weekly: sd
            ))
        }
        // Total ordering, not just by time: `sort` is not stable, so two samples sharing a
        // timestamp would otherwise resolve differently between runs — and whichever lands last
        // becomes "the current reading" for that organization.
        for org in byOrg.keys {
            byOrg[org]?.sort {
                ($0.at, $0.fiveHour, $0.weekly) < ($1.at, $1.fiveHour, $1.weekly)
            }
        }
        return byOrg
    }

    private static func inRange(_ percent: Double) -> Bool { percent >= 0 && percent <= 100 }

    /// Guards against a unit-slipped timestamp (seconds or microseconds where milliseconds were
    /// meant). One such row describes a date tens of thousands of years out, which downstream
    /// becomes an interval nothing can sensibly walk. 2020-01-01 through 2100-01-01, in ms.
    private static func plausibleEpochMillis(_ ms: Double) -> Bool {
        ms >= 1_577_836_800_000 && ms <= 4_102_444_800_000
    }

    /// Latest sample per organization, named and labelled for the strips. Takes an already-parsed
    /// series so a caller that also needs the raw samples parses the file once.
    static func summarize(_ byOrg: [String: [DesktopSample]],
                          names: [String: (name: String?, type: String?)]? = nil) -> [DesktopOrgUsage] {
        let names = names ?? organizationNames(needing: Set(byOrg.keys))
        return byOrg.compactMap { org, series -> DesktopOrgUsage? in
            guard let last = series.last else { return nil }
            let known = names[org]
            return DesktopOrgUsage(
                organizationUuid: org,
                label: label(forOrg: org, name: known?.name),
                plan: known?.type.map { $0.replacingOccurrences(of: "claude_", with: "") },
                fiveHour: last.fiveHour,
                weekly: last.weekly,
                seenAt: last.at
            )
        }
        // Tie broken on the uuid: `sorted` is not stable, and two organizations sampled in the
        // same second must not reorder the strips between renders.
        .sorted { ($1.seenAt, $1.organizationUuid) < ($0.seenAt, $0.organizationUuid) }
    }

    static func parseUsage(_ data: Data,
                           names: [String: (name: String?, type: String?)]) -> [DesktopOrgUsage] {
        summarize(parseSamples(data), names: names)
    }

    /// The desktop app writes a Claude Code config per organization under
    /// `local-agent-mode-sessions/<account>/<organization>/…/.claude/.claude.json`, which is where
    /// the organization's name can be recovered. Without it we would be showing a bare uuid.
    /// Memoized: the walk below opens every session directory the desktop app has ever created and
    /// parses a config to pull two strings, while the answer only changes when you join or leave an
    /// organization. `known` lets a caller say which organizations it needs — seeing an unfamiliar
    /// one is the signal to walk again, and it is also why a miss is not cached as an answer.
    static func organizationNames(needing known: Set<String> = []) -> [String: (name: String?, type: String?)] {
        namesLock.lock()
        defer { namesLock.unlock() }
        if let cached = namesCache, known.isSubset(of: Set(cached.keys)) { return cached }
        let fresh = scanOrganizationNames()
        namesCache = fresh
        return fresh
    }

    nonisolated(unsafe) private static var namesCache: [String: (name: String?, type: String?)]?
    private static let namesLock = NSLock()

    private static func scanOrganizationNames() -> [String: (name: String?, type: String?)] {
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
