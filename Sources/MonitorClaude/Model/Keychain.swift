import Foundation
import Security

/// Reads the OAuth token Claude Code stores in the login keychain.
/// macOS prompts once per signed binary; "Always Allow" persists the ACL.
enum Keychain {
    struct Credentials {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
        var scopes: [String]

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date()
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
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
