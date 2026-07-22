import Foundation
import Security

/// Reads (and, after a refresh, writes back) the OAuth token Claude Code stores in the
/// login keychain. macOS prompts once per signed binary; "Always Allow" persists the ACL.
enum Keychain {
    static let service = "Claude Code-credentials"

    struct Credentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var subscriptionType: String?
        var scopes: [String]

        /// A small skew so we renew *before* the server would start rejecting, rather than
        /// after the first 401. Claude Code uses the same idea.
        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date()
        }

        var expiresSoon: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date().addingTimeInterval(5 * 60)
        }
    }

    enum Failure: Error, LocalizedError {
        case notFound
        case denied
        case malformed
        case other(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound: return "Login do terminal não encontrado no Keychain."
            case .denied: return "Acesso ao Keychain negado."
            case .malformed: return "Credencial do Keychain em formato inesperado."
            case .other(let s): return "Keychain falhou (\(s))."
            }
        }
    }

    /// Read-only, by design. We never write this entry back: it is shared with the Claude Code
    /// CLI and Anthropic rotates the refresh token on use, so a second writer would race the
    /// CLI and force one side to re-login. Renewed tokens live in `MonitorCredentials` instead.
    static func claudeCredentials() throws -> Credentials {
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

        return try parse(root)
    }

    private static func parse(_ root: [String: Any]) throws -> Credentials {
        // Claude Code nests under `claudeAiOauth`, but tolerate a flat shape too.
        let node = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = node["accessToken"] as? String, !token.isEmpty else {
            throw Failure.malformed
        }

        var expires: Date?
        if let ms = node["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }

        return Credentials(
            accessToken: token,
            refreshToken: node["refreshToken"] as? String,
            expiresAt: expires,
            subscriptionType: node["subscriptionType"] as? String,
            scopes: (node["scopes"] as? [String]) ?? []
        )
    }
}
