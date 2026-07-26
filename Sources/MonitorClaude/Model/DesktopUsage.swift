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

    /// The widest gap the *strong* anchor will still answer across. Half of it is the worst-case
    /// error, so three grid steps caps us at ±15 min. Beyond that the app was closed across the
    /// boundary and the honest answer is silence — the real series here has gaps of 12, 22, 44 and
    /// 595 minutes, so without this the fall anchor will confidently miss by hours.
    static let maxBracket: TimeInterval = 3 * resetGrid

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
        let weekly = weeklyAnchor.map { weeklyReset(anchor: $0, now: now) }

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
                resetsAt: weekly?.at,
                severity: "normal",
                isSession: false,
                isActive: true,
                resetIsExact: weekly?.exact ?? true
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
    /// Both anchors refuse a bracket wider than they can speak for, so a gap in the series yields
    /// nil rather than a confident answer that is hours out. Returns nil, too, when neither anchor
    /// lands a reset still in the future — the app was closed across the real boundary, and the
    /// window running now started somewhere we never saw. Inventing a reset here would poison the
    /// pace marker, the outlook and the trail's axis.
    static func sessionReset(series: [DesktopSample], now: Date = Date()) -> (at: Date, exact: Bool)? {
        if let hit = reset(from: lastTransition(in: series, { cur, prev in cur <= prev - minimumDrop }),
                           in: series, within: maxBracket, now: now) {
            return hit
        }

        // Never "exact": the rise only proves the window was open by then, not that it opened in
        // this bracket rather than a little earlier under the rounding.
        if let hit = reset(from: lastTransition(in: series, { cur, prev in prev < 0.5 && cur >= 0.5 }),
                           in: series, within: tightBracket, now: now) {
            return (hit.at, false)
        }

        return nil
    }

    /// Turns a bracketing sample pair into a reset, or nil if the bracket is too wide to speak for
    /// or the window it describes has already closed.
    private static func reset(from index: Int?, in series: [DesktopSample],
                              within limit: TimeInterval, now: Date) -> (at: Date, exact: Bool)? {
        guard let i = index else { return nil }
        let before = series[i - 1].at, after = series[i].at
        guard after.timeIntervalSince(before) <= limit else { return nil }

        let (start, exact) = anchor(after: before, notAfter: after)
        let reset = start.addingTimeInterval(sessionWindow)
        return reset > now ? (reset, exact) : nil
    }

    /// Index of the newest sample whose value relates to its predecessor's as `match` describes.
    /// `match` receives `(current, previous)`.
    private static func lastTransition(in series: [DesktopSample],
                                       _ match: (Double, Double) -> Bool) -> Int? {
        guard series.count >= 2 else { return nil }
        for i in stride(from: series.count - 1, through: 1, by: -1)
        where match(series[i].fiveHour, series[i - 1].fiveHour) {
            return i
        }
        return nil
    }

    /// The window boundary known to lie in `(lo, hi]`, always on the ten-minute grid.
    ///
    /// Exactly one mark in the interval means there is nothing to choose between — that is the
    /// boundary, and we can say so. Otherwise we take the mark nearest the midpoint. It may sit
    /// just outside the bracket, and that is the right trade: with a five-minute cadence on a
    /// ten-minute grid, half of all brackets contain no mark at all, and answering with the raw
    /// midpoint would put every one of those resets at a time the grid says cannot exist.
    ///
    /// Callers must bound `(lo, hi]` before calling — see `maxBracket`.
    static func anchor(after lo: Date, notAfter hi: Date) -> (Date, exact: Bool) {
        let marks = gridMarks(after: lo, notAfter: hi)
        if marks.count == 1 { return (marks[0], true) }

        let mid = (lo.timeIntervalSince1970 + hi.timeIntervalSince1970) / 2
        return (Date(timeIntervalSince1970: (mid / resetGrid).rounded() * resetGrid), false)
    }

    /// Ten-minute marks lying in `(lo, hi]`. Exactly one means the boundary is pinned.
    ///
    /// Hard-capped: the interval comes from timestamps in another application's file, and a single
    /// unit-slipped value there (µs where ms was meant) describes an interval tens of thousands of
    /// years wide. Materialising a mark every ten minutes across it would allocate gigabytes on the
    /// main actor at launch. Past the cap we return nothing, which reads as "no single mark" and
    /// sends the caller down the inexact path — where the bracket limit rejects it anyway.
    static func gridMarks(after lo: Date, notAfter hi: Date) -> [Date] {
        let l = lo.timeIntervalSince1970, h = hi.timeIntervalSince1970
        guard h > l, h - l <= maxSpan else { return [] }

        var marks: [Date] = []
        var m = (floor(l / resetGrid) + 1) * resetGrid     // first mark strictly after `lo`
        while m <= h {
            marks.append(Date(timeIntervalSince1970: m))
            m += resetGrid
        }
        return marks
    }

    /// The widest interval `gridMarks` will walk. A day is far beyond any bracket a caller may
    /// legitimately present and keeps the worst case at 144 marks.
    static let maxSpan: TimeInterval = 24 * 3600

    private static var sessionWindow: TimeInterval { LimitWindow.sessionLength }
    private static var weeklyWindow: TimeInterval { LimitWindow.weeklyLength }

    /// The weekly reset, wound forward from an anchor the API reported at some point.
    ///
    /// The window is strictly periodic, so the arithmetic is exact — but the *premise* decays: a
    /// plan change or an organization move re-anchors the week on the server without telling us.
    /// An anchor still in the future, or one week stale, is reported as exact; older than that we
    /// are extrapolating across a period where the anchor could have moved, and the panel says so
    /// with a "≈" rather than passing a projection off as the server's word.
    static func weeklyReset(anchor: Date, now: Date = Date()) -> (at: Date, exact: Bool) {
        let steps = rollSteps(anchor, step: weeklyWindow, to: now)
        return (anchor.addingTimeInterval(Double(steps) * weeklyWindow), steps <= 1)
    }

    /// Winds a periodic anchor forward in whole steps until it is in the future.
    static func rollForward(_ anchor: Date, step: TimeInterval, to now: Date) -> Date {
        anchor.addingTimeInterval(Double(rollSteps(anchor, step: step, to: now)) * step)
    }

    /// How many whole periods the anchor has to advance to land in the future. Zero when it is
    /// already there.
    private static func rollSteps(_ anchor: Date, step: TimeInterval, to now: Date) -> Int {
        guard step > 0, anchor <= now else { return 0 }
        return Int((now.timeIntervalSince(anchor) / step).rounded(.down)) + 1
    }
}
