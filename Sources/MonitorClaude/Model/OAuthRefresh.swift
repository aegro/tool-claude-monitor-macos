import Foundation

/// Renews the Claude Code OAuth access token from the refresh token, so the panel keeps
/// working even when the CLI has not been run in days. Same grant the CLI itself performs;
/// the renewed credential is written straight back to the keychain entry both share.
///
/// Nothing here leaves the machine except the refresh grant to Anthropic's own token
/// endpoint — the same host the usage call already talks to.
enum OAuthRefresh {
    /// Public OAuth client id Claude Code registers for its PKCE login. Not a secret: it
    /// identifies the app, never authenticates it (the refresh token is the credential).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    enum Failure: Error, LocalizedError {
        case noRefreshToken
        case http(Int)
        case transport(String)
        case decode

        var errorDescription: String? {
            switch self {
            case .noRefreshToken: return "Sem refresh token no Keychain — faça login pelo terminal uma vez."
            case .http(let c): return "Renovação do token falhou (HTTP \(c))."
            case .transport(let m): return "Renovação do token falhou: \(m)."
            case .decode: return "Resposta de renovação em formato inesperado."
            }
        }
    }

    struct Renewed {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    /// Exchanges the current refresh token for a fresh access token and persists the result.
    /// Returns the renewed set so the caller can keep an in-memory copy coherent without a
    /// second keychain read.
    @discardableResult
    static func renewAndStore(using creds: Keychain.Credentials) async throws -> Renewed {
        guard let refresh = creds.refreshToken, !refresh.isEmpty else {
            throw Failure.noRefreshToken
        }
        let renewed = try await exchange(refreshToken: refresh)
        try Keychain.update(
            accessToken: renewed.accessToken,
            refreshToken: renewed.refreshToken,
            expiresAt: renewed.expiresAt
        )
        return renewed
    }

    static func exchange(refreshToken: String) async throws -> Renewed {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.decode }
        guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty
        else { throw Failure.decode }

        var expiresAt: Date?
        if let secs = numeric(root["expires_in"]) {
            expiresAt = Date().addingTimeInterval(secs)
        }

        return Renewed(
            accessToken: access,
            // Anthropic rotates the refresh token on every use; keep the new one or we would
            // be renewing against a token the server has already retired.
            refreshToken: (root["refresh_token"] as? String) ?? refreshToken,
            expiresAt: expiresAt
        )
    }

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}
