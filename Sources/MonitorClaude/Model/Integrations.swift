import Foundation

/// Where the account switch reaches: the terminal (an alias in `~/.zshrc`), the VS Code extension (its process
/// wrapper setting) and T3 Code (a binary path the person pastes). Every edit keeps a backup next to the file and
/// writes atomically; the text transformations are pure so they can be tested without touching a real file.
enum Integrations {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    static var claudeAutoPath: String {
        AccountRouter.commandsDirectory.appendingPathComponent("claude-auto").path
    }

    // MARK: terminal

    static var zshrcURL: URL {
        if let custom = ProcessInfo.processInfo.environment["MONITOR_CLAUDE_ZSHRC"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return home.appendingPathComponent(".zshrc")
    }

    /// The block the Monitor writes, guarded so a Mac without the app keeps a plain `claude`. The full path keeps it
    /// working when `~/.local/bin` is not on the PATH.
    static let terminalBlock = [
        "# Monitor Claude: troca de conta do Claude Code quando o limite bate (claude-auto, ~/.claude-accounts).",
        "# Só aponta o claude pro roteador se o app instalou o comando; sem ele, o claude segue puro.",
        "if [ -x \"$HOME/.local/bin/claude-auto\" ]; then",
        "  alias claude=\"$HOME/.local/bin/claude-auto\"",
        "fi",
    ]

    /// Earlier versions of the block, still the Monitor's to remove.
    static let legacyTerminalBlocks = [[
        "# Monitor Claude: troca de conta do Claude Code quando o limite bate (claude-auto, ~/.claude-accounts).",
        "# Só aponta o claude pro roteador se o app instalou o comando; sem ele, o claude segue puro.",
        "if command -v claude-auto >/dev/null 2>&1; then",
        "  alias claude=claude-auto",
        "fi",
    ]]

    enum TerminalState: Equatable {
        /// The Monitor's block is there and can be removed by the Monitor.
        case on
        /// An alias to claude-auto exists, written by hand; the Monitor will not edit it.
        case onByHand
        case off
    }

    static func terminalState(_ text: String) -> TerminalState {
        if blockRange(in: text) != nil { return .on }
        let byHand = text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#") else { return false }
            return t.range(of: #"^alias\s+claude=['"]?([^'"\s]*/)?claude-auto['"]?(\s|$)"#, options: .regularExpression) != nil
        }
        return byHand ? .onByHand : .off
    }

    static func enablingTerminal(_ text: String) -> String {
        guard terminalState(text) == .off else { return text }
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        return out + terminalBlock.joined(separator: "\n") + "\n"
    }

    /// The text without the Monitor's block, or nil when the alias was written by hand (left for the person).
    static func disablingTerminal(_ text: String) -> String? {
        guard let range = blockRange(in: text) else {
            return terminalState(text) == .onByHand ? nil : text
        }
        var lines = text.components(separatedBy: "\n")
        lines.removeSubrange(range)
        // One blank line used to separate the block from what came before it.
        if range.lowerBound > 0, range.lowerBound <= lines.count, lines[range.lowerBound - 1].isEmpty,
           range.lowerBound == lines.count || lines[range.lowerBound].isEmpty {
            lines.remove(at: range.lowerBound - 1)
        }
        return lines.joined(separator: "\n")
    }

    private static func blockRange(in text: String) -> Range<Int>? {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for block in [terminalBlock] + legacyTerminalBlocks where lines.count >= block.count {
            let wanted = block.map { $0.trimmingCharacters(in: .whitespaces) }
            for start in 0...(lines.count - block.count) where Array(lines[start..<(start + block.count)]) == wanted {
                return start..<(start + block.count)
            }
        }
        return nil
    }

    static func readTerminal() -> TerminalState {
        terminalState((try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? "")
    }

    static func setTerminal(_ on: Bool) throws {
        let current = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        let next: String
        if on {
            next = enablingTerminal(current)
        } else {
            guard let removed = disablingTerminal(current) else { throw EditedByHand(file: "~/.zshrc") }
            next = removed
        }
        guard next != current else { return }
        try write(next, to: zshrcURL)
    }

    // MARK: VS Code

    static var vscodeSettingsURL: URL {
        if let custom = ProcessInfo.processInfo.environment["MONITOR_CLAUDE_VSCODE_SETTINGS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return home.appendingPathComponent("Library/Application Support/Code/User/settings.json")
    }

    static let wrapperKey = "claudeCode.claudeProcessWrapper"

    static var vscodeExtensionInstalled: Bool {
        let dir = home.appendingPathComponent(".vscode/extensions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { $0.hasPrefix("anthropic.claude-code-") }
    }

    static func wrapper(in jsonc: String) -> String? {
        guard let data = stripJSONC(jsonc).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root[wrapperKey] as? String
    }

    /// Sets (or removes, with nil) the wrapper key, editing the text in place so comments and the person's
    /// formatting survive. Throws when the file is not valid JSONC before or after the edit.
    static func settingWrapper(_ jsonc: String, to value: String?) throws -> String {
        let text = jsonc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}\n" : jsonc
        guard isObject(text) else { throw UnreadableSettings() }
        let ns = text as NSString
        let masked = maskingComments(text) as NSString
        let out: String
        if let match = keyPattern.firstMatch(in: masked as String, range: NSRange(location: 0, length: masked.length)) {
            out = value.map { ns.replacingCharacters(in: match.range(at: 1), with: jsonString($0)) }
                ?? removingEntry(ns, masked: masked, at: match.range)
        } else if let value {
            out = insertingEntry(ns, masked: masked, "\"\(wrapperKey)\": \(jsonString(value))")
        } else {
            return jsonc
        }
        guard isObject(out) else { throw UnreadableSettings() }
        return out
    }

    /// The key with any JSON value, found where comments are blanked out, so a commented-out copy is never taken
    /// for the setting.
    private static let keyPattern = try! NSRegularExpression(
        pattern: #""claudeCode\.claudeProcessWrapper"\s*:\s*("(?:[^"\\]|\\.)*"|null|true|false|-?[0-9][0-9.eE+-]*)"#)

    static func readVSCodeWrapper() -> String? {
        guard let text = try? String(contentsOf: vscodeSettingsURL, encoding: .utf8) else { return nil }
        return wrapper(in: text)
    }

    static func setVSCodeWrapper(_ on: Bool) throws {
        let current = (try? String(contentsOf: vscodeSettingsURL, encoding: .utf8)) ?? ""
        let next = try settingWrapper(current, to: on ? claudeAutoPath : nil)
        guard next != current else { return }
        try write(next, to: vscodeSettingsURL)
    }

    private static func isObject(_ text: String) -> Bool {
        guard let data = stripJSONC(text).data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Adds the entry before the root's closing brace. The comma goes right after the last value, ahead of any
    /// comment that follows it, so `"a": 1 // nota` becomes `"a": 1, // nota` and not a comma inside the comment.
    private static func insertingEntry(_ ns: NSString, masked: NSString, _ entry: String) -> String {
        let close = masked.range(of: "}", options: .backwards).location
        guard close != NSNotFound else { return ns as String }
        var last = close - 1
        while last >= 0, isSpace(masked.character(at: last)) { last -= 1 }
        guard last >= 0 else { return ns as String }
        let needsComma = masked.character(at: last) != 0x7B && masked.character(at: last) != 0x2C   // { ,
        var between = ns.substring(with: NSRange(location: last + 1, length: close - last - 1))
        while let c = between.last, c.isWhitespace { between.removeLast() }
        // Indent like the file's first entry, or two spaces.
        let text = ns as String
        let indent = text.range(of: #"\n([ \t]+)""#, options: .regularExpression)
            .map { String(text[$0].dropFirst().prefix { $0 == " " || $0 == "\t" }) } ?? "  "
        return ns.substring(to: last + 1) + (needsComma ? "," : "") + between + "\n" + indent + entry + "\n"
            + ns.substring(from: close)
    }

    /// Removes the entry with the comma that separated it from the next one, or else the one before it, and the
    /// line it lived on when nothing else is on it.
    private static func removingEntry(_ ns: NSString, masked: NSString, at found: NSRange) -> String {
        func isBlank(_ i: Int) -> Bool { [0x20, 0x09, 0x0D].contains(masked.character(at: i)) }
        var start = found.location
        var end = NSMaxRange(found)
        var commaBefore: Int?
        var after = end
        while after < masked.length, isBlank(after) { after += 1 }
        if after < masked.length, masked.character(at: after) == 0x2C {
            end = after + 1
        } else {
            var before = start - 1
            while before >= 0, isSpace(masked.character(at: before)) { before -= 1 }
            if before >= 0, masked.character(at: before) == 0x2C { commaBefore = before }
        }
        var lineStart = start
        while lineStart > 0, isBlank(lineStart - 1) { lineStart -= 1 }
        var lineEnd = end
        while lineEnd < masked.length, isBlank(lineEnd) { lineEnd += 1 }
        if lineStart == 0 || masked.character(at: lineStart - 1) == 0x0A, lineEnd < masked.length, masked.character(at: lineEnd) == 0x0A {
            start = lineStart
            end = lineEnd + 1
        }
        let out = NSMutableString(string: ns)
        out.deleteCharacters(in: NSRange(location: start, length: end - start))
        if let comma = commaBefore { out.deleteCharacters(in: NSRange(location: comma, length: 1)) }
        return out as String
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }

    /// The text with every comment turned into spaces of the same UTF-16 length: offsets found in it hold for the
    /// original, and nothing inside a comment is read as code. Strings are kept as they are.
    static func maskingComments(_ text: String) -> String {
        func blank(_ ch: Character) -> String { String(repeating: " ", count: ch.utf16.count) }
        let chars = Array(text)
        var out = ""
        var i = 0
        var inString = false
        while i < chars.count {
            let ch = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if inString {
                out.append(ch)
                if ch == "\\", let next { out.append(next); i += 2; continue }
                if ch == "\"" { inString = false }
                i += 1
                continue
            }
            if ch == "\"" { inString = true; out.append(ch); i += 1; continue }
            if ch == "/", next == "/" {
                while i < chars.count, !chars[i].isNewline { out += blank(chars[i]); i += 1 }
                continue
            }
            if ch == "/", next == "*" {
                out += "  "
                i += 2
                while i < chars.count {
                    if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" { out += "  "; i += 2; break }
                    out += chars[i].isNewline ? String(chars[i]) : blank(chars[i])
                    i += 1
                }
                continue
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    /// JSONC to JSON: comments out, trailing commas out, strings untouched.
    static func stripJSONC(_ text: String) -> String {
        let chars = Array(maskingComments(text))
        var out = ""
        var i = 0
        var inString = false
        while i < chars.count {
            let ch = chars[i]
            if inString {
                out.append(ch)
                if ch == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if ch == "\"" { inString = false }
                i += 1
                continue
            }
            if ch == "\"" { inString = true }
            if ch == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    // MARK: T3

    static var t3Installed: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: home.appendingPathComponent(".t3").path)
            || fm.fileExists(atPath: "/Applications/T3 Code.app")
    }

    // MARK: files

    struct EditedByHand: LocalizedError {
        var file: String
        var errorDescription: String? { "O alias está no \(file), escrito à mão. O Monitor não mexe nele." }
    }

    struct UnreadableSettings: LocalizedError {
        var errorDescription: String? { "O settings.json do VS Code não é um JSON válido. Corrija o arquivo antes de ligar." }
    }

    /// Keeps the previous version as `<file>.monitor-claude.bak` and writes the new one atomically.
    static func write(_ text: String, to link: URL) throws {
        let fm = FileManager.default
        // A dotfile that is a symlink into a repository stays one: the edit lands on the file it points to.
        let url = link.resolvingSymlinksInPath()
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        if fm.fileExists(atPath: url.path) {
            let backup = URL(fileURLWithPath: url.path + ".monitor-claude.bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        try Data(text.utf8).write(to: url, options: .atomic)
        // The atomic write is a new file; it keeps the old one's permissions, not the default ones.
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }
}

/// A snapshot of every integration for the settings window, read in one go.
struct IntegrationsState: Equatable {
    var terminal: Integrations.TerminalState = .off
    var vscodeInstalled = false
    var vscodeOn = false
    var vscodeOtherWrapper: String?
    var t3Installed = false
    var commandsInstalled = false

    static func read() -> IntegrationsState {
        let wrapper = Integrations.readVSCodeWrapper()
        return IntegrationsState(
            terminal: Integrations.readTerminal(),
            vscodeInstalled: Integrations.vscodeExtensionInstalled,
            vscodeOn: wrapper == Integrations.claudeAutoPath,
            vscodeOtherWrapper: wrapper.flatMap { $0 == Integrations.claudeAutoPath ? nil : $0 },
            t3Installed: Integrations.t3Installed,
            commandsInstalled: AccountRouter.commandsInstalled)
    }
}

/// The tabs of the settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, accounts, integrations, advanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "Geral"
        case .accounts: return "Contas"
        case .integrations: return "Integrações"
        case .advanced: return "Avançado"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.2"
        case .integrations: return "link"
        case .advanced: return "slider.horizontal.3"
        }
    }
}
