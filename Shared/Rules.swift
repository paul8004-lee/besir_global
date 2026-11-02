import Foundation

// SPEC-MEMORY-003 (card t74): the user's standing rules in rules.md.

/// The cleaning and the display of one rule line of `rules.md`. A rule line is `- ` followed by a text equal to its own
/// cleaning, compared code point for code point.
enum RuleLine {
    static let maxScalars = 100
    static let maxRules = 20

    /// Cleans one rule text with the steps of `MemoryLine.clean`, in the same order: each hidden character (general category
    /// Cc, Cf, Zl or Zp) and each `|` becomes a space, each run of white space (the Unicode `White_Space` property) becomes one
    /// U+0020 space, the text is trimmed, cut at `limit` code points (never by character) and trimmed again. Nil when nothing
    /// is left. Written here, not shared, so `Memory.swift` stays as it is.
    static func clean(_ text: String, limit: Int = maxScalars) -> String? {
        let hidden: [Unicode.GeneralCategory] = [.control, .format, .lineSeparator, .paragraphSeparator]
        var scalars: [Unicode.Scalar] = []
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let mapped: Unicode.Scalar = hidden.contains(scalar.properties.generalCategory) || scalar == "|" ? " " : scalar
            if mapped.properties.isWhitespace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(mapped)
                lastWasSpace = false
            }
        }
        var cut = Array(trimmed(scalars).prefix(max(limit, 0)))
        cut = trimmed(cut)
        guard !cut.isEmpty else { return nil }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: cut)
        return String(result)
    }

    /// True when `line` is `- ` followed by a text equal to its own cleaning (code point for code point).
    static func isRuleLine(_ line: String) -> Bool {
        guard let rest = text(of: line) else { return false }
        guard let cleaned = clean(rest) else { return false }
        return Array(cleaned.unicodeScalars) == Array(rest.unicodeScalars)
    }

    /// A Settings row: the stored line without its leading `- `.
    static func display(_ line: String) -> String {
        text(of: line) ?? line
    }

    /// The text after a leading `- `, found by code point; nil when the line does not begin with `- `.
    private static func text(of line: String) -> String? {
        let scalars = line.unicodeScalars
        guard scalars.starts(with: "- ".unicodeScalars) else { return nil }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: scalars.dropFirst(2))
        return String(rest)
    }

    private static func trimmed(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var slice = scalars[...]
        while slice.first == " " { slice = slice.dropFirst() }
        while slice.last == " " { slice = slice.dropLast() }
        return Array(slice)
    }
}

/// The outcome of one add to `rules.md`.
enum RuleAdd: Equatable {
    case added([String])
    case empty
    case duplicate
    case full
    case failed

    /// The short text the Settings tab and the chat notice show for a refusal; nil when there is nothing to show.
    var errorText: String? {
        switch self {
        case .full: return "Rules are full."
        case .duplicate: return "This rule is already saved."
        case .failed: return "Could not save the rule."
        case .empty, .added: return nil
        }
    }
}

// @MX:NOTE: [AUTO] The one file object of rules.md: it reads the file afresh on every call (no copy is kept between chat requests) and refuses an add (empty, already saved, full, unreadable) instead of dropping an old rule.
/// The file `rules.md` in the app's support folder: plain UTF-8, rule lines (`- ` and a clean text) each ended by one line
/// feed. Only rule lines are read, at most the first 20; a missing file reads as no rules; a file that exists but cannot be
/// read as UTF-8 text shows no rules and is never overwritten by an add or a single delete (only `removingAll` replaces it).
/// Every write rewrites the file from the rule lines read and returns the new list, or nil when it failed; the default writer
/// is atomic, so a failed write leaves the file as it was.
struct RuleBook {
    static let fileName = "rules.md"

    let fileURL: URL
    private let write: @Sendable (Data, URL) throws -> Void

    init(fileURL: URL, write: @escaping @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite) {
        self.fileURL = fileURL
        self.write = write
    }

    /// The file the app uses. Under tests `AppConfig.supportDirectory` is a throw-away folder.
    static func app() -> RuleBook {
        RuleBook(fileURL: AppConfig.supportDirectory.appendingPathComponent(fileName))
    }

    /// The rule lines in file order.
    func lines() -> [String] {
        read() ?? []
    }

    /// The refusal an add of `text` would meet now, or nil when it would be added.
    func refusal(of text: String) -> RuleAdd? {
        if case .refused(let refusal) = admission(of: text) { return refusal }
        return nil
    }

    /// Adds one rule, or names the refusal. A refusal writes nothing.
    func appending(_ text: String) -> RuleAdd {
        switch admission(of: text) {
        case .refused(let refusal): return refusal
        case .admitted(let items): return store(items) ? .added(items) : .failed
        }
    }

    /// Removes the one rule line at `index` (never by value); nil when the write failed or the file cannot be read. An index
    /// out of range changes nothing and writes nothing.
    func removing(at index: Int) -> [String]? {
        guard var items = read() else { return nil }
        guard items.indices.contains(index) else { return items }
        items.remove(at: index)
        return store(items) ? items : nil
    }

    /// Empties the file, whatever it held; nil when the write failed.
    func removingAll() -> [String]? {
        store([]) ? [] : nil
    }

    // MARK: Private

    private enum Admission {
        case refused(RuleAdd)
        case admitted([String])
    }

    /// The checks of an add, in order: no rule text, an unreadable file, the same rule (code point for code point), a full file.
    private func admission(of text: String) -> Admission {
        guard let cleaned = RuleLine.clean(text) else { return .refused(.empty) }
        guard var items = read() else { return .refused(.failed) }
        let line = "- " + cleaned
        let lineScalars = Array(line.unicodeScalars)
        if items.contains(where: { Array($0.unicodeScalars) == lineScalars }) { return .refused(.duplicate) }
        if items.count >= RuleLine.maxRules { return .refused(.full) }
        items.append(line)
        return .admitted(items)
    }

    /// The rule lines, `[]` for a missing file, nil for a file that exists but cannot be read as UTF-8 text.
    private func read() -> [String]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard Data(text.utf8) == data else { return nil }
        return Array(Self.lines(of: text).filter(RuleLine.isRuleLine).prefix(RuleLine.maxRules))
    }

    private func store(_ items: [String]) -> Bool {
        do {
            try write(Data(items.map { $0 + "\n" }.joined().utf8), fileURL)
            return true
        } catch {
            return false
        }
    }

    /// The text cut at each line feed, by code point (a carriage return before a line feed stays with its line).
    private static func lines(of text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                result.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        result.append(String(current))
        return result
    }
}
