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

    /// The one or two words the provenance bar shows next to a failing feed. Deliberately terse:
    /// the bar is one line, and the sentence explaining what to do is stated in full below it.
    ///
    /// Each error type answers for itself through `ShortFailure`, so adding a case fails the build
    /// in the file where the case was added. A `switch` over `Error` here instead would need a
    /// `default:`, and a new failure would silently degrade to "falhou" — under-reporting a state
    /// the model can already name precisely.
    static func shortReason(for error: Error) -> String {
        (error as? ShortFailure)?.shortReason ?? "falhou"
    }
}

/// A failure that can name itself in one or two words, for the provenance bar.
protocol ShortFailure {
    var shortReason: String { get }
}

extension Keychain.Failure: ShortFailure {
    var shortReason: String {
        switch self {
        case .expired: return "vencido"
        case .notFound, .noAccountToken: return "sem login"
        case .denied: return "sem acesso"
        case .malformed: return "ilegível"
        case .other(let status): return "erro \(status)"
        }
    }
}

extension UsageError: ShortFailure {
    var shortReason: String {
        switch self {
        case .unauthorized: return "recusado"
        case .forbidden: return "sem escopo"
        case .decode: return "resposta estranha"
        case .transport: return "sem rede"
        case .http(let code): return "erro \(code)"
        }
    }
}
