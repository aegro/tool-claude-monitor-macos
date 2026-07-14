import Foundation

struct TokenCounts: Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheCreate: Int64 = 0
    var cacheRead: Int64 = 0

    /// Everything the model had to process. cache_read dominates this sum and is the one
    /// field Claude Code records accurately, so the total is directionally sound even
    /// though input/output are known to be undercounted (anthropics/claude-code#28197).
    var total: Int64 { input + output + cacheCreate + cacheRead }

    /// Tokens that were actually computed rather than replayed from cache.
    var fresh: Int64 { input + output + cacheCreate }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input,
                    output: a.output + b.output,
                    cacheCreate: a.cacheCreate + b.cacheCreate,
                    cacheRead: a.cacheRead + b.cacheRead)
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

struct TokenEntry {
    var at: Date
    var sessionId: String
    var model: String
    var counts: TokenCounts
}

struct LedgerSnapshot: Equatable {
    var bySession: [String: TokenCounts] = [:]     // within the current block
    var byModel: [String: TokenCounts] = [:]       // within the current block
    var block: TokenCounts = .init()
    var lastHour: TokenCounts = .init()
    var last15min: TokenCounts = .init()
    var buckets: [(Date, Int64)] = []              // 5-min totals across the block
    var scannedAt = Date()
    var entryCount = 0

    /// Tokens/minute over the trailing 15 minutes.
    var tokensPerMinute: Double { Double(last15min.total) / 15 }

    static func == (a: LedgerSnapshot, b: LedgerSnapshot) -> Bool {
        a.scannedAt == b.scannedAt && a.entryCount == b.entryCount
    }
}

/// Incrementally tails ~/.claude/projects/**/*.jsonl.
///
/// Deliberately NOT the source of truth for limits: those come from the server. This exists
/// to answer "which session is burning" and to draw the token trend inside the current block.
final class TokenLedger {
    private var offsets: [String: UInt64] = [:]      // path -> bytes consumed
    private var seen: Set<String> = []               // messageId:requestId
    private var entries: [TokenEntry] = []

    /// We only ever display the current 5h window plus the trailing hour, so nothing older is
    /// worth holding. Keeping this tight is what makes the cold scan cheap.
    private let retention: TimeInterval = 8 * 3600

    private var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    func scan(blockStart: Date) -> LedgerSnapshot {
        let now = Date()
        let horizon = min(blockStart, now.addingTimeInterval(-3600))
            .addingTimeInterval(-600)   // margin, so a slow first line is not clipped

        ingest(since: horizon)
        entries.removeAll { $0.at < now.addingTimeInterval(-retention) }

        var snap = LedgerSnapshot()
        snap.entryCount = entries.count

        let hourAgo = now.addingTimeInterval(-3600)
        let quarterAgo = now.addingTimeInterval(-900)
        var bucketMap: [Date: Int64] = [:]

        for e in entries {
            if e.at >= hourAgo { snap.lastHour += e.counts }
            if e.at >= quarterAgo { snap.last15min += e.counts }
            guard e.at >= blockStart else { continue }

            snap.block += e.counts
            snap.bySession[e.sessionId, default: .init()] += e.counts
            snap.byModel[shortModel(e.model), default: .init()] += e.counts

            let slot = Date(timeIntervalSince1970:
                (e.at.timeIntervalSince1970 / 300).rounded(.down) * 300)
            bucketMap[slot, default: 0] += e.counts.total
        }

        snap.buckets = bucketMap.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return snap
    }

    // MARK: ingest

    private func ingest(since horizon: Date) {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: projectsDir,
                                                         includingPropertiesForKeys: nil) else { return }

        for project in projects {
            guard let files = try? fm.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let path = file.path
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate ?? .distantPast
                let size = UInt64(values?.fileSize ?? 0)
                guard size > 0 else { continue }

                if let known = offsets[path] {
                    guard size > known else { continue }
                    // Warm path: everything before `known` was already ingested.
                    if let consumed = readForward(path: path, from: known, to: size) {
                        offsets[path] = consumed
                    }
                } else {
                    guard mtime >= horizon else { continue }
                    // Cold path: a transcript can be hundreds of megabytes, and every line we
                    // care about is at the end of it. Walk backwards from EOF instead of
                    // reading the whole thing.
                    readBackward(path: path, size: size, horizon: horizon)
                    offsets[path] = size
                }
            }
        }
    }

    private func readForward(path: String, from start: UInt64, to size: UInt64) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return start }
            let sessionId = Self.sessionId(of: path)

            var consumed = start
            var lineStart = data.startIndex
            while let nl = data[lineStart...].firstIndex(of: 0x0A) {
                let line = data[lineStart..<nl]
                consumed += UInt64(line.count + 1)
                lineStart = data.index(after: nl)
                absorb(line: Data(line), sessionId: sessionId)
            }
            return consumed
        } catch {
            return nil
        }
    }

    /// Reads growing chunks off the tail until the oldest line in the chunk predates the horizon
    /// (or we reach the start of the file).
    private func readBackward(path: String, size: UInt64, horizon: Date) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let sessionId = Self.sessionId(of: path)

        var chunk: UInt64 = 512 * 1024
        while true {
            let start = size > chunk ? size - chunk : 0
            guard let data = try? { () -> Data? in
                try handle.seek(toOffset: start)
                return try handle.readToEnd()
            }(), !data.isEmpty else { return }

            // A mid-file offset almost certainly lands inside a line; drop that fragment.
            var lineStart = data.startIndex
            if start > 0 {
                guard let nl = data.firstIndex(of: 0x0A) else {
                    if start == 0 { return }
                    chunk *= 4
                    continue
                }
                lineStart = data.index(after: nl)
            }

            var oldest: Date?
            var lines: [Data] = []
            var i = lineStart
            while let nl = data[i...].firstIndex(of: 0x0A) {
                lines.append(Data(data[i..<nl]))
                i = data.index(after: nl)
            }
            if i < data.endIndex { lines.append(Data(data[i...])) }

            for line in lines {
                if let at = absorb(line: line, sessionId: sessionId) {
                    if oldest == nil || at < oldest! { oldest = at }
                }
            }

            // Covered the horizon, or ran out of file: done.
            if start == 0 { return }
            if let oldest, oldest <= horizon { return }
            if chunk >= 64 * 1024 * 1024 { return }   // pathological file; stop digging
            chunk *= 4
        }
    }

    private static func sessionId(of path: String) -> String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
    }

    @discardableResult
    private func absorb(line: Data, sessionId: String) -> Date? {
        guard line.count > 40 else { return nil }
        guard line.range(of: Data("\"usage\"".utf8)) != nil else { return nil }

        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        guard let ts = obj["timestamp"] as? String,
              let at = UsageAPI.parseDate(ts) else { return nil }

        let messageId = (message["id"] as? String) ?? ""
        let requestId = (obj["requestId"] as? String) ?? ""
        let isSidechain = (obj["isSidechain"] as? Bool) ?? false

        // The same assistant message is written to more than one transcript, and sidechain logs
        // replay parent messages under fresh request ids — so a (messageId, requestId) pair is
        // not enough on its own to keep subagent-heavy sessions from double counting.
        if !messageId.isEmpty {
            let strict = "\(messageId):\(requestId)"
            if seen.contains(strict) { return at }
            if isSidechain, seen.contains("m:\(messageId)") { return at }
            seen.insert(strict)
            seen.insert("m:\(messageId)")
        }

        let cacheCreation = usage["cache_creation"] as? [String: Any]
        let create5m = (cacheCreation?["ephemeral_5m_input_tokens"] as? Int) ?? 0
        let create1h = (cacheCreation?["ephemeral_1h_input_tokens"] as? Int) ?? 0
        let createTotal = (usage["cache_creation_input_tokens"] as? Int) ?? (create5m + create1h)

        let counts = TokenCounts(
            input: Int64((usage["input_tokens"] as? Int) ?? 0),
            output: Int64((usage["output_tokens"] as? Int) ?? 0),
            cacheCreate: Int64(createTotal),
            cacheRead: Int64((usage["cache_read_input_tokens"] as? Int) ?? 0)
        )
        guard counts.total > 0 else { return at }

        entries.append(TokenEntry(
            at: at,
            sessionId: sessionId,
            model: (message["model"] as? String) ?? "?",
            counts: counts
        ))
        return at
    }

    private func shortModel(_ m: String) -> String {
        let base = m.replacingOccurrences(of: "claude-", with: "")
        if let bracket = base.firstIndex(of: "[") { return String(base[..<bracket]) }
        return base
    }
}
