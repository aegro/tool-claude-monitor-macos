import Foundation
import Security

/// Reads (read-only) the OAuth token Claude Code stores in the login keychain. The Monitor
/// never writes this item: Claude Code owns it and keeps it fresh, and a second writer here
/// would race the CLI's refresh-token rotation, trip the server's reuse detection, and break
/// login for both. macOS prompts once per signed binary; "Always Allow" persists the ACL.
enum Keychain {
    static let service = "Claude Code-credentials"

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
        var scopes: [String]

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date()
        }

        /// A small skew so we re-read the keychain *before* the token would start being
        /// rejected — the CLI refreshes it there and we just pick up its fresh copy.
        var expiresSoon: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date().addingTimeInterval(5 * 60)
        }
    }

    /// Each case is a different thing for the user to *do*, which is the only reason to keep
    /// them apart: "não logado" and "credencial corrompida" look identical from here but send
    /// you looking in completely different places.
    enum Failure: Error, LocalizedError, Equatable {
        case notFound
        case noAccountToken
        case denied
        case malformed
        case other(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Claude Code não está logado neste Mac — rode `claude /login` no terminal."
            case .noAccountToken:
                return "O Keychain só tem tokens de MCP, sem sessão de conta — rode `claude /login` no terminal."
            case .denied:
                return "Acesso ao Keychain negado — clique “Sempre Permitir” quando o macOS perguntar."
            case .malformed:
                return "Credencial do Keychain em formato inesperado."
            case .other(let s):
                return "Keychain falhou (\(s))."
            }
        }
    }

    static func claudeCredentials() throws -> Credentials {
        try parse(readItem())
    }

    /// The decoded top-level object of the `Claude Code-credentials` item. Read-only: we ask
    /// for the data, decode it, and never write it back.
    private static func readItem() throws -> [String: Any] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: throw Failure.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed: throw Failure.denied
        default: throw Failure.other(status)
        }

        guard let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.malformed }

        return root
    }

    /// The item holds the account session under `claudeAiOauth` and, side by side with it, the
    /// per-MCP tokens under `mcpOAuth`. Those are independent: log out (or have the item
    /// rewritten by something else) and `mcpOAuth` can be the only thing left. An item in that
    /// state is perfectly well-formed — it just has nobody logged in — so it must not be
    /// reported as corrupt, which sends you hunting for a broken file that does not exist.
    static func parse(_ root: [String: Any]) throws -> Credentials {
        let node: [String: Any]
        if let nested = root["claudeAiOauth"] {
            guard let dict = nested as? [String: Any] else { throw Failure.malformed }
            node = dict
        } else {
            // Older shapes kept the token flat. This also covers the mcpOAuth-only item, where
            // the lookup below simply finds no account token.
            node = root
        }

        guard let token = node["accessToken"] as? String, !token.isEmpty else {
            throw Failure.noAccountToken
        }

        var expires: Date?
        if let ms = node["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }

        return Credentials(
            accessToken: token,
            expiresAt: expires,
            subscriptionType: node["subscriptionType"] as? String,
            scopes: (node["scopes"] as? [String]) ?? []
        )
    }
}
