import Foundation
import Security

/// Reads (read-only) the OAuth token Claude Code stores in the login keychain. The Monitor
/// never writes this item: Claude Code owns it and keeps it fresh, and a second writer here
/// would race the CLI's refresh-token rotation, trip the server's reuse detection, and break
/// login for both. The read goes through `/usr/bin/security`, so it never prompts.
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
        case expired
        case denied
        case malformed
        case other(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Claude Code não está logado neste Mac — rode `claude /login` no terminal."
            case .noAccountToken:
                return "O Keychain só tem tokens de MCP, sem sessão de conta — rode `claude /login` no terminal."
            case .expired:
                return "O login do terminal venceu. Só o `claude` no terminal o renova — rode-o uma vez para o Monitor voltar a ler a API."
            case .denied:
                return "O Keychain está bloqueado. Desbloqueie a sessão do Mac e o Monitor lê de novo."
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

    /// The decoded top-level object of the `Claude Code-credentials` item. Read-only, and read through
    /// `/usr/bin/security`, the same way Claude Code reads it. The item is written by `security` (Claude Code calls
    /// `security add-generic-password -U` on every refresh), so `security` is always in its access list and the read
    /// never raises a prompt. Reading it as the Monitor instead put the Monitor's own entry in that list, and a
    /// refresh could drop it again: the "type your password" prompt that kept coming back.
    private static func readItem() throws -> [String: Any] {
        let security = URL(fileURLWithPath: "/usr/bin/security")
        // Claude Code files the item under the login name; an odd name falls back to an item without one.
        var result = AccountRouter.run(security, ["find-generic-password", "-a", NSUserName(), "-s", service, "-w"], timeout: 8)
        if result.status == 44 { result = AccountRouter.run(security, ["find-generic-password", "-s", service, "-w"], timeout: 8) }
        guard result.ok else { throw failure(forSecurityExit: result.status) }
        guard let root = try? JSONSerialization.jsonObject(
            with: Data(result.output.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String: Any]
        else { throw Failure.malformed }
        return root
    }

    /// `security` reports the Keychain status as its exit code: 44 is "not found" (errSecItemNotFound), 36 and 51 a
    /// locked Keychain or a read it may not do without asking.
    static func failure(forSecurityExit code: Int32) -> Failure {
        switch code {
        case 44: return .notFound
        case 36, 51, 128: return .denied
        default: return .other(OSStatus(code))
        }
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
