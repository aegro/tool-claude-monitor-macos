import Foundation

/// One persisted observation of the server-reported limits.
struct UsageSample: Codable, Equatable {
    var at: Date
    var session: Double?           // 5h window utilization, 0...100
    var sessionResetsAt: Date?
    var weekly: Double?
    var tokensCumulative: Int64?   // local ledger, for the token trend line
    /// Which organization these percentages belong to. Two feeds can be watching two different
    /// organizations at once, and a trend line drawn across both would be a line through two
    /// unrelated series. Nil on samples written before this was recorded.
    var org: String?
}

/// Hand-decoded so that a history written before `org` existed still loads — the file holds up to
/// thirty days of samples and a synthesized decoder would throw the lot away on upgrade.
extension UsageSample {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Date.self, forKey: .at)
        session = try c.decodeIfPresent(Double.self, forKey: .session)
        sessionResetsAt = try c.decodeIfPresent(Date.self, forKey: .sessionResetsAt)
        weekly = try c.decodeIfPresent(Double.self, forKey: .weekly)
        tokensCumulative = try c.decodeIfPresent(Int64.self, forKey: .tokensCumulative)
        org = try c.decodeIfPresent(String.self, forKey: .org)
    }
}

/// A derived rate of change: how fast a limit window is filling.
struct BurnRate {
    var percentPerHour: Double     // utilization points per hour
    var basedOnMinutes: Double

    /// Hours until utilization would reach 100 at this rate.
    func hoursToExhaustion(from utilization: Double) -> Double? {
        guard percentPerHour > 0.05 else { return nil }
        let remaining = 100 - utilization
        guard remaining > 0 else { return 0 }
        return remaining / percentPerHour
    }
}

/// Rolling store of limit observations. This is what makes "evolução" possible:
/// the API only ever tells us the current number, so the trend has to be built locally.
@MainActor
final class UsageHistory {
    private(set) var samples: [UsageSample] = []
    private let url: URL
    private let retention: TimeInterval = 30 * 24 * 3600
    private var dirty = false

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Farol", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("usage-history.json")
        load()
    }

    func append(_ s: UsageSample) {
        // The endpoint is cached server-side; identical consecutive reads are common.
        if let last = samples.last, abs(last.at.timeIntervalSince(s.at)) < 5 { return }
        samples.append(s)
        let cutoff = Date().addingTimeInterval(-retention)
        if samples.first.map({ $0.at < cutoff }) == true {
            samples.removeAll { $0.at < cutoff }
        }
        dirty = true
    }

    /// Samples for one organization only. Matching on equality means samples from before `org`
    /// was recorded (nil) are used only while we cannot name the current organization either —
    /// unattributed numbers are never mixed into a named organization's line.
    func series(_ pick: (UsageSample) -> Double?, since: Date, org: String?) -> [(Date, Double)] {
        samples.compactMap { s in
            guard s.at >= since, s.org == org, let v = pick(s) else { return nil }
            return (s.at, v)
        }
    }

    /// Least-squares slope of utilization over the trailing `window`, in points/hour.
    /// Regression rather than a two-point delta because utilization advances in steps.
    /// Refuses to answer from a thin sample. A slope fitted to three points ten minutes apart
    /// will happily predict that you run out of quota before lunch; better to say "still measuring".
    func burnRate(_ pick: (UsageSample) -> Double?, org: String?,
                  window: TimeInterval = 60 * 60,
                  minPoints: Int = 5, minSpan: TimeInterval = 15 * 60) -> BurnRate? {
        let since = Date().addingTimeInterval(-window)
        let pts = series(pick, since: since, org: org)
        guard pts.count >= minPoints else { return nil }

        let spanMinutes = pts.last!.0.timeIntervalSince(pts.first!.0) / 60
        guard spanMinutes >= minSpan / 60 else { return nil }

        // Reject the segment if the window reset inside it (utilization fell off a cliff).
        for i in 1..<pts.count where pts[i].1 < pts[i - 1].1 - 15 { return nil }

        let t0 = pts.first!.0.timeIntervalSince1970
        let xs = pts.map { ($0.0.timeIntervalSince1970 - t0) / 3600 }
        let ys = pts.map { $0.1 }
        let n = Double(pts.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var num = 0.0, den = 0.0
        for i in 0..<pts.count {
            num += (xs[i] - meanX) * (ys[i] - meanY)
            den += (xs[i] - meanX) * (xs[i] - meanX)
        }
        guard den > 0 else { return nil }
        return BurnRate(percentPerHour: max(0, num / den), basedOnMinutes: spanMinutes)
    }

    // MARK: persistence

    func flush() {
        guard dirty else { return }
        dirty = false
        let snapshot = samples
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
        samples = (try? dec.decode([UsageSample].self, from: data)) ?? []
    }
}
