import Foundation

/// The fallback feed: a `UsageSnapshot` built from what the Claude desktop app already wrote to
/// disk, for when the terminal token is expired or absent and the API is closed to us.
///
/// It is the same server numbers — the app polls the same endpoint — so this is not an estimate of
/// usage. What *is* reconstructed here are the two reset times the app does not record, and each
/// is reconstructed differently: the weekly window is strictly periodic, so an anchor the API gave
/// us once winds forward exactly; the session window is rolling, so its start has to be read off
/// the moment the percentage fell, and that can only be pinned to within one sampling gap.
///
/// Everything here refuses rather than guesses. A window with no reset draws without a countdown;
/// a window with a wrong reset would poison the pace line, the outlook, and the trail's x-axis.
enum DesktopUsage {
    /// Observed in the wild: every `resets_at` the API has ever handed us lands on a ten-minute
    /// mark (56 distinct values, no exception). That grid is what turns "somewhere in these five
    /// minutes" into an exact answer whenever only one mark falls inside the gap.
    static let resetGrid: TimeInterval = 10 * 60

    /// Percentages arrive as integers, so ±1 is rounding. A fall of three points is a new window.
    static let minimumDrop: Double = 3

    /// How tight the bracket around a boundary has to be before the weaker anchor is trusted. One
    /// cadence plus slack: any wider and the transition tells us too little about where inside it
    /// the window actually opened.
    static let tightBracket: TimeInterval = 7.5 * 60

    /// The app polls every five minutes; two missed polls and we stop calling it current.
    static let staleAfter: TimeInterval = 15 * 60

    static func isCurrent(_ at: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(at) <= staleAfter
    }

    /// Builds the snapshot, or nil when there is nothing to build it from.
    ///
    /// - Parameter weeklyAnchor: any `resets_at` the API previously reported for the weekly
    ///   window, however old. Nil leaves the weekly window without a countdown.
    static func snapshot(series: [DesktopSample],
                         weeklyAnchor: Date?,
                         now: Date = Date()) -> UsageSnapshot? {
        guard let last = series.last else { return nil }

        let session = sessionReset(series: series, now: now)

        var snap = UsageSnapshot()
        snap.source = .desktopApp
        snap.fetchedAt = last.at
        snap.windows = [
            LimitWindow(
                key: "session",
                title: "Sessão · 5h",
                utilization: last.fiveHour,
                resetsAt: session?.at,
                // The app records no severity. "normal" is not a claim: `isCritical` still fires
                // off the percentage alone, which is the only input we honestly have.
                severity: "normal",
                isSession: true,
                isActive: true,
                resetIsExact: session?.exact ?? true
            ),
            LimitWindow(
                key: "weekly_all",
                title: "Semana",
                utilization: last.weekly,
                // Exact whenever it exists: the weekly window is strictly periodic, so winding a
                // reported anchor forward lands on the real moment, however old the anchor.
                resetsAt: weeklyAnchor.map { rollForward($0, step: 7 * 24 * 3600, to: now) },
                severity: "normal",
                isSession: false,
                isActive: true
            ),
        ]
        return snap
    }

    /// When the current 5h window ends, and whether we can say so exactly.
    ///
    /// Two anchors, in strict order of trust:
    ///
    /// 1. **The fall.** A window turning over drops the percentage to zero, and the sample pair
    ///    straddling that fall brackets the boundary. This is the reliable one — checked against
    ///    the API's own `resets_at` it lands on the exact minute.
    /// 2. **The rise from zero.** Windows that turn over while you are barely using anything never
    ///    produce a visible fall: the number was already zero. But the *first* usage after a
    ///    stretch of zero opens a window, so a `0 → n` transition brackets a boundary too. Weaker,
    ///    because a window can sit at zero for a while before rounding up, so it is only trusted
    ///    when the two samples are one cadence apart and only when the fall gave us nothing usable.
    ///
    /// Returns nil when neither anchor yields a reset still in the future — the app was closed
    /// across the real boundary, and the window running now started somewhere we never saw.
    /// Inventing a reset here would poison the pace marker, the outlook and the trail's axis.
    static func sessionReset(series: [DesktopSample], now: Date = Date()) -> (at: Date, exact: Bool)? {
        if let i = lastTransition(in: series, { prev, cur in cur <= prev - minimumDrop }) {
            let (start, exact) = anchor(between: series[i - 1], and: series[i])
            let reset = start.addingTimeInterval(5 * 3600)
            if reset > now { return (reset, exact) }
        }

        if let i = lastTransition(in: series, { prev, cur in prev == 0 && cur > 0 }),
           series[i].at.timeIntervalSince(series[i - 1].at) <= tightBracket {
            let (start, _) = anchor(between: series[i - 1], and: series[i])
            let reset = start.addingTimeInterval(5 * 3600)
            // Never "exact": the rise only proves the window was open by then, not that it opened
            // in this bracket rather than a little earlier under the rounding.
            if reset > now { return (reset, false) }
        }

        return nil
    }

    /// Index of the newest sample whose value relates to its predecessor's as `match` describes.
    private static func lastTransition(in series: [DesktopSample],
                                       _ match: (Double, Double) -> Bool) -> Int? {
        guard series.count >= 2 else { return nil }
        for i in stride(from: series.count - 1, through: 1, by: -1)
        where match(series[i - 1].fiveHour, series[i].fiveHour) {
            return i
        }
        return nil
    }

    private static func anchor(between before: DesktopSample,
                               and after: DesktopSample) -> (Date, exact: Bool) {
        let marks = gridMarks(after: before.at, notAfter: after.at)
        if marks.count == 1 { return (marks[0], true) }
        return (boundary(after: before.at, notAfter: after.at), false)
    }

    /// The window boundary known to lie in `(lo, hi]`, snapped to the ten-minute grid.
    ///
    /// One mark in the interval means there is nothing to choose between — that is the boundary,
    /// exactly. Otherwise (a missed poll widened the gap) the midpoint is the best estimate, taken
    /// to the nearest mark when that still lands inside the interval.
    static func boundary(after lo: Date, notAfter hi: Date) -> Date {
        let marks = gridMarks(after: lo, notAfter: hi)
        if marks.count == 1 { return marks[0] }

        let l = lo.timeIntervalSince1970, h = hi.timeIntervalSince1970
        let mid = (l + h) / 2
        let snapped = (mid / resetGrid).rounded() * resetGrid
        return Date(timeIntervalSince1970: snapped > l && snapped <= h ? snapped : mid)
    }

    /// Ten-minute marks lying in `(lo, hi]`. Exactly one means the boundary is pinned.
    static func gridMarks(after lo: Date, notAfter hi: Date) -> [Date] {
        let l = lo.timeIntervalSince1970, h = hi.timeIntervalSince1970
        var marks: [Date] = []
        var m = (floor(l / resetGrid) + 1) * resetGrid     // first mark strictly after `lo`
        while m <= h {
            marks.append(Date(timeIntervalSince1970: m))
            m += resetGrid
        }
        return marks
    }

    /// Winds a periodic anchor forward in whole steps until it is in the future. Exact for the
    /// weekly window, which resets at the same moment every seven days.
    static func rollForward(_ anchor: Date, step: TimeInterval, to now: Date) -> Date {
        guard step > 0, anchor <= now else { return anchor }
        let steps = (now.timeIntervalSince(anchor) / step).rounded(.down) + 1
        return anchor.addingTimeInterval(steps * step)
    }
}
