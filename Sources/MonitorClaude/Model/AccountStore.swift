import Foundation

/// The last usage we saw for one account, kept so an *inactive* account can still show
/// something. Only percentages/resets/label/timestamp — never a token. Contas são solo, so an
/// account nobody is driving does not burn quota, and "last-seen when I used it" is as good as
/// live for the one that is parked.
struct AccountRecord: Codable, Equatable, Identifiable {
    var uuid: String
    var label: String
    var plan: String?
    var snapshot: UsageSnapshot
    var lastSeen: Date

    var id: String { uuid }
}

/// Learn-as-you-go registry of accounts, persisted next to the usage history. An account shows
/// up only after it has been active at least once; switching to it in `claude` is what teaches
/// the Monitor it exists. Read-only w.r.t. the credential — this file holds no secrets.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var records: [String: AccountRecord] = [:]
    private let url: URL
    private var dirty = false

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Farol", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("accounts.json")
        load()
    }

    /// Overwrite (or create) the active account's entry with what we just fetched.
    func record(uuid: String, label: String, plan: String?, snapshot: UsageSnapshot, at: Date) {
        records[uuid] = AccountRecord(uuid: uuid, label: label, plan: plan,
                                      snapshot: snapshot, lastSeen: at)
        dirty = true
        flush()
    }

    /// Every account except the one currently active, most-recently-seen first — the strips the
    /// panel draws below the active account.
    func others(activeUuid: String?) -> [AccountRecord] {
        records.values
            .filter { $0.uuid != activeUuid }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: persistence

    func flush() {
        guard dirty else { return }
        dirty = false
        let snapshot = records
        let target = url
        Task.detached(priority: .utility) {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(snapshot) {
                try? data.write(to: target, options: .atomic)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        records = (try? dec.decode([String: AccountRecord].self, from: data)) ?? [:]
    }
}
