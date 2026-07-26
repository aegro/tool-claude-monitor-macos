import Foundation

/// What the two feeds are doing right now.
///
/// This exists because the panel used to have nowhere to say it. An error could only be shown when
/// there was no snapshot at all, so the first successful read made every later failure invisible:
/// the numbers froze, the "ao vivo" dot stayed lit, and the only tell was a timestamp quietly
/// counting upwards. Feed health is now its own published state, drawn whether or not there is
/// data, and independently of whose data it is.
struct FeedState: Equatable {
    enum Health: Equatable {
        /// Answered, and the answer is current.
        case live(at: Date)
        /// Answered once, but not lately — the desktop app was quit, say.
        case stale(at: Date)
        /// Refused. Carries the short word for the bar; the full sentence lives in `usageError`.
        case broken(String)
        /// Nothing to read: no login, or the app has never written a sample.
        case missing
    }

    var terminal: Health = .missing
    var desktop: Health = .missing

    /// True when nothing anywhere is feeding the panel.
    var allDown: Bool {
        if case .live = terminal { return false }
        if case .live = desktop { return false }
        return true
    }

    /// The one or two words the provenance bar shows next to a failing terminal feed. Deliberately
    /// terse: the bar is one line, and the sentence explaining what to do is in the error card.
    static func shortReason(for error: Error) -> String {
        switch error {
        case Keychain.Failure.expired: return "vencido"
        case Keychain.Failure.notFound, Keychain.Failure.noAccountToken: return "sem login"
        case Keychain.Failure.denied: return "sem acesso"
        case Keychain.Failure.malformed: return "ilegível"
        case UsageError.unauthorized: return "recusado"
        case UsageError.forbidden: return "sem escopo"
        case UsageError.transport: return "sem rede"
        case UsageError.http(let code): return "erro \(code)"
        default: return "falhou"
        }
    }
}
