import Foundation

/// One rate-limit window as the server reports it.
struct LimitWindow: Equatable, Identifiable, Codable {
    var key: String              // session | weekly_all | weekly_scoped:<model>
    var title: String
    var utilization: Double      // 0...100, as the server sends it
    var resetsAt: Date?
    var severity: String         // normal | warning | ... (server's own judgement)
    var isSession: Bool
    var isActive: Bool
    /// False when `resetsAt` was reconstructed rather than reported, so the panel can show it as
    /// approximate instead of passing an inference off as the server's word.
    var resetIsExact = true

    var id: String { key }

    /// The server never states the window length, so it is implied by the kind. These two are the
    /// canonical lengths — the reset derivation and the trail axis both read them from here, so
    /// there is one place to change if Anthropic ever moves a window.
    static let sessionLength: TimeInterval = 5 * 3600
    static let weeklyLength: TimeInterval = 7 * 24 * 3600

    /// Every key the account-wide weekly window has gone by: the current payload calls it
    /// `weekly_all`, the older flat shape `seven_day`. Anything asking "is this *the* weekly
    /// window?" must ask here — one place that answered only `weekly_all` while another answered
    /// both meant the weekly reset was dropped from the live row and from the ghosts at once.
    static let weeklyAllKeys: Set<String> = ["weekly_all", "seven_day"]

    var duration: TimeInterval { isSession ? Self.sessionLength : Self.weeklyLength }

    var startsAt: Date? { resetsAt.map { $0.addingTimeInterval(-duration) } }

    /// How much of the window has already gone by, 0...1.
    var elapsedFraction: Double {
        guard let start = startsAt, let end = resetsAt else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(start) / total))
    }

    /// The utilization you could be at right now and still land exactly on 100% at reset.
    /// This is the number that turns a bare percentage into a decision.
    var paceTarget: Double { elapsedFraction * 100 }

    /// >1 means you are spending the window faster than it refills.
    var paceRatio: Double? {
        let target = paceTarget
        guard target > 1, utilization > 0.5 else { return nil }
        return utilization / target
    }

    var timeToReset: TimeInterval? { resetsAt.map { max(0, $0.timeIntervalSinceNow) } }
    var isCritical: Bool { utilization >= 90 || severity == "critical" }
}

/// Hand-decoded for the same reason as `UsageSnapshot`: windows are persisted inside
/// `accounts.json`, and records written before `resetIsExact` existed came from the API, where
/// every reset is the server's own.
extension LimitWindow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = try c.decode(String.self, forKey: .title)
        utilization = try c.decode(Double.self, forKey: .utilization)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? "normal"
        isSession = try c.decodeIfPresent(Bool.self, forKey: .isSession) ?? false
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        resetIsExact = try c.decodeIfPresent(Bool.self, forKey: .resetIsExact) ?? true
    }
}

/// Where a snapshot's numbers came from. The percentages are the server's either way — the desktop
/// app polls the same endpoint — but the two feeds carry different amounts of it, so the panel has
/// to know which one it is drawing.
enum UsageSource: String, Codable {
    /// Our own read of `/api/oauth/usage`, with the terminal's token. Everything is present.
    case api
    /// The Claude desktop app's `plan-usage-history.json`: the two headline percentages only.
    case desktopApp
}

struct UsageSnapshot: Equatable, Codable {
    var windows: [LimitWindow] = []
    var extraUsageEnabled = false
    var extraUsageUtilization: Double?
    var fetchedAt = Date()
    var source: UsageSource = .api

    var session: LimitWindow? { windows.first(where: \.isSession) }
    var weekly: LimitWindow? { windows.first { LimitWindow.weeklyAllKeys.contains($0.key) } }
    var scoped: [LimitWindow] { windows.filter { $0.key.hasPrefix("weekly_scoped") } }
}

/// Decoded by hand, and from an extension so the memberwise initialiser survives: `accounts.json`
/// was already on disk in the field before `source` existed, and a synthesized decoder would
/// reject every one of those records — silently emptying the account list on upgrade.
extension UsageSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = try c.decodeIfPresent([LimitWindow].self, forKey: .windows) ?? []
        extraUsageEnabled = try c.decodeIfPresent(Bool.self, forKey: .extraUsageEnabled) ?? false
        extraUsageUtilization = try c.decodeIfPresent(Double.self, forKey: .extraUsageUtilization)
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
        // Records written before the field existed were all API reads, because that is all there was.
        source = try c.decodeIfPresent(UsageSource.self, forKey: .source) ?? .api
    }
}

enum UsageError: Error, LocalizedError {
    case unauthorized, forbidden, decode
    case http(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Token recusado. Rode o claude no terminal pra renovar o login."
        case .forbidden: return "Token sem o escopo user:profile."
        case .decode: return "Resposta da API em formato inesperado."
        case .http(let c): return "A API respondeu \(c)."
        case .transport(let m): return m
        }
    }
}

/// GET https://api.anthropic.com/api/oauth/usage — the endpoint /usage itself calls.
/// Server-side rate-limited, so we poll every 2 minutes and never on a keystroke.
enum UsageAPI {
    static func fetch(token: String) async throws -> (UsageSnapshot, Data) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw UsageError.decode }
        switch http.statusCode {
        case 200: break
        case 401: throw UsageError.unauthorized
        case 403: throw UsageError.forbidden
        default: throw UsageError.http(http.statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decode
        }
        return (parse(root), data)
    }

    /// Prefer the `limits` array: it is what /usage renders, it carries the server's own
    /// severity, and it is the only place the per-model weekly caps show up (the flat
    /// seven_day_opus / seven_day_sonnet keys come back null even when a scoped limit exists).
    static func parse(_ root: [String: Any]) -> UsageSnapshot {
        var snap = UsageSnapshot()

        if let extra = root["extra_usage"] as? [String: Any] {
            snap.extraUsageEnabled = (extra["is_enabled"] as? Bool) ?? false
            snap.extraUsageUtilization = (extra["utilization"] as? Double).map(clamp)
        }

        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            for l in limits {
                guard let kind = l["kind"] as? String,
                      let percent = numeric(l["percent"]) else { continue }

                let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let isSession = kind == "session"

                let title: String
                switch kind {
                case "session": title = "Sessão · 5h"
                case "weekly_all": title = "Semana"
                case "weekly_scoped": title = model.map { "Semana · \($0)" } ?? "Semana · modelo"
                default: title = kind.replacingOccurrences(of: "_", with: " ").capitalized
                }

                snap.windows.append(LimitWindow(
                    key: kind == "weekly_scoped" ? "weekly_scoped:\(model ?? "?")" : kind,
                    title: title,
                    utilization: clamp(percent),
                    resetsAt: parseDate(l["resets_at"]),
                    severity: (l["severity"] as? String) ?? "normal",
                    isSession: isSession,
                    isActive: (l["is_active"] as? Bool) ?? false
                ))
            }
        } else {
            // Fallback for older payload shapes that only expose the flat keys.
            let flat: [(String, String, Bool)] = [
                ("five_hour", "Sessão · 5h", true),
                ("seven_day", "Semana", false),
                ("seven_day_opus", "Semana · Opus", false),
                ("seven_day_sonnet", "Semana · Sonnet", false),
            ]
            for (key, title, isSession) in flat {
                guard let d = root[key] as? [String: Any],
                      let u = numeric(d["utilization"]) else { continue }
                snap.windows.append(LimitWindow(
                    key: key, title: title, utilization: clamp(u),
                    resetsAt: parseDate(d["resets_at"]),
                    severity: "normal", isSession: isSession, isActive: isSession
                ))
            }
        }

        // Session first, then the weekly caps, biggest first.
        snap.windows.sort { a, b in
            if a.isSession != b.isSession { return a.isSession }
            return a.utilization > b.utilization
        }
        return snap
    }

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    /// Percentages are 0...100. A known Claude Code bug leaks an epoch timestamp into the
    /// field when a window has no data yet (anthropics/claude-code#52326).
    static func clamp(_ raw: Double) -> Double {
        raw > 100 || raw < 0 ? 0 : raw
    }

    static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = numeric(any), n > 1_000_000_000 {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        return nil
    }
}
