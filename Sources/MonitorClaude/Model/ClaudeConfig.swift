import Foundation

/// Who Claude Code has logged in *right now*, read from `~/.claude.json`. Claude Code rewrites
/// this file and the Keychain token together when you switch accounts, so the account named
/// here is the one the current token belongs to — which is exactly what lets the Monitor tell
/// two accounts apart and notice a switch. Read-only, like everything else here: we never write
/// this file.
struct AccountIdentity: Equatable {
    var uuid: String
    var email: String?
    var organizationName: String?
    var displayName: String?
    /// e.g. "claude_max" → shown as "max". The token's own subscriptionType wins when present.
    var organizationType: String?

    /// The name shown on the account's row. The two accounts differ by organization, so that is
    /// the field that identifies them — except Claude auto-names a solo org "<email>'s
    /// Organization", which is long and redundant, so we collapse that to the person instead.
    var label: String {
        let org = (organizationName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isPersonalOrgName(org) {
            if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
            return Self.localPart(of: email) ?? "Pessoal"
        }
        if !org.isEmpty { return org }
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return Self.localPart(of: email) ?? String(uuid.prefix(8))
    }

    /// Plan badge, best-effort. "claude_max" → "max"; nil when we have nothing honest to show.
    var planFallback: String? {
        guard let t = organizationType, !t.isEmpty else { return nil }
        return t.replacingOccurrences(of: "claude_", with: "")
    }

    static func isPersonalOrgName(_ org: String) -> Bool {
        // Straight and curly apostrophes both show up depending on where the name was minted.
        org.hasSuffix("'s Organization") || org.hasSuffix("’s Organization")
    }

    static func localPart(of email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@"), at > email.startIndex else {
            return email?.isEmpty == false ? email : nil
        }
        let local = String(email[email.startIndex..<at])
        return local.isEmpty ? nil : local.prefix(1).uppercased() + local.dropFirst()
    }
}

enum ClaudeConfig {
    /// `~/.claude.json`. Resolved from the real home even under a sandbox container path, to
    /// match where Claude Code actually writes it.
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    /// The active account, or nil if the file is missing/unreadable or has no `oauthAccount`
    /// (an older CLI, or one that never logged in). Nil simply means "single-account view":
    /// without an identity we cannot key the cache or say which account is active.
    static func activeAccount() -> AccountIdentity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseActiveAccount(data)
    }

    static func parseActiveAccount(_ data: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any],
              let uuid = oauth["accountUuid"] as? String, !uuid.isEmpty
        else { return nil }

        return AccountIdentity(
            uuid: uuid,
            email: oauth["emailAddress"] as? String,
            organizationName: oauth["organizationName"] as? String,
            displayName: oauth["displayName"] as? String,
            organizationType: oauth["organizationType"] as? String
        )
    }
}
