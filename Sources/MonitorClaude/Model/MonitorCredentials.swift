import Foundation

/// The monitor's *own* copy of the OAuth credential, kept in a file it alone owns so a token
/// refresh never has to write the shared `Claude Code-credentials` Keychain entry.
///
/// Why not write back to the Keychain (as an earlier version did): Anthropic rotates the
/// refresh token on every use, and the Keychain entry is shared with the Claude Code CLI.
/// Two independent writers rotating the same lineage race each other — whoever refreshes
/// second with a now-retired token gets rejected. Keeping our copy separate means we never
/// corrupt the CLI's credential; we only ever *read* the Keychain, to seed and to piggyback
/// on refreshes the CLI already did.
struct StoredCredentials: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    var expiresSoon: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date().addingTimeInterval(5 * 60)
    }
}

enum MonitorCredentials {
    private static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MonitorClaude", isDirectory: true)
        return dir.appendingPathComponent("credentials.json")
    }

    static func load() -> StoredCredentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    /// Writes atomically and clamps the file to owner-only (0600) — it holds a live token.
    static func save(_ creds: StoredCredentials) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(creds) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The freshest access token available, preferring whichever source expires latest so we
    /// ride the CLI's own refreshes for free and only self-refresh when both are stale.
    /// Falls back to the one that has a token when only one is present.
    static func freshest(keychain: Keychain.Credentials?) -> StoredCredentials? {
        let own = load()
        let kc = keychain.map {
            StoredCredentials(accessToken: $0.accessToken, refreshToken: $0.refreshToken, expiresAt: $0.expiresAt)
        }
        switch (own, kc) {
        case let (o?, k?):
            // A nil expiry is treated as "unknown, assume oldest" so a dated-but-known token wins.
            return (o.expiresAt ?? .distantPast) >= (k.expiresAt ?? .distantPast) ? o : k
        case let (o?, nil): return o
        case let (nil, k?): return k
        case (nil, nil): return nil
        }
    }
}
