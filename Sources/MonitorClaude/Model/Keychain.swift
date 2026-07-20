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

    static func claudeCredentials() throws -> Credentials {
        try parse(rawData().1)
    }

    /// The raw bytes plus the decoded top-level object, so a write-back can preserve every
    /// field the CLI cares about instead of reconstructing the shape from scratch.
    private static func rawData() throws -> (Data, [String: Any]) {
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

        return (data, root)
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

    /// Merges a renewed token back into the exact object Claude Code stored, touching only the
    /// three fields the refresh produces. Everything else (subscriptionType, scopes, any key we
    /// do not model) is written back byte-for-byte so the CLI keeps reading its own credential.
    static func update(accessToken: String, refreshToken: String?, expiresAt: Date?) throws {
        var (_, root) = try rawData()

        let nested = root["claudeAiOauth"] is [String: Any]
        var node = (root["claudeAiOauth"] as? [String: Any]) ?? root

        node["accessToken"] = accessToken
        if let refreshToken { node["refreshToken"] = refreshToken }
        if let expiresAt { node["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000 }

        if nested { root["claudeAiOauth"] = node } else { root = node }

        let data = try JSONSerialization.data(withJSONObject: root, options: [])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw Failure.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed: throw Failure.denied
        default: throw Failure.other(status)
        }
    }
}
