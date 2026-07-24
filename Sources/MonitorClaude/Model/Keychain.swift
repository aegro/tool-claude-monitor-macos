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
            expiresAt: expires,
            subscriptionType: node["subscriptionType"] as? String,
            scopes: (node["scopes"] as? [String]) ?? []
        )
    }
}
