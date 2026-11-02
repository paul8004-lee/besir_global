import Foundation

// @MX:NOTE: [AUTO] The one place the app's rules live: besir.md in the app bundle, read for every chat request. With no readable file or an empty Always section no request is built; there is no built-in copy to fall back to.
/// The app's rules document `besir.md`, shipped in the app bundle: the `## Always` lines go into every chat request, the
/// `## Memory` lines go in only together with count lines.
struct BesirRules: Equatable {
    static let resourceName = "besir"
    static let resourceExtension = "md"

    let always: [String]
    let memory: [String]
    /// The `## Rules` lines (SPEC-MEMORY-003): they go in only together with at least one of the user's standing rules.
    let rules: [String]

    /// `rules` defaults to no lines, so a value built from the Always and Memory lists alone has no Rules lines.
    init(always: [String], memory: [String], rules: [String] = []) {
        self.always = always
        self.memory = memory
        self.rules = rules
    }

    /// Reads the text by one rule: lines before the first `## ` heading are skipped; a heading's name is the rest of its line;
    /// inside a section a line that is empty, only spaces and tabs, or begins with `#` is skipped, and any other line is taken as
    /// written (one trailing carriage return removed) into `always`, `memory` or `rules` when the section is named exactly
    /// `Always`, `Memory` or `Rules`. A name that heads two sections gives the lines of both in file order. No escaping, no
    /// front matter.
    static func parse(_ text: String) -> BesirRules {
        var always: [String] = []
        var memory: [String] = []
        var rules: [String] = []
        var section: String?
        for raw in lines(of: text) {
            var scalars = raw.unicodeScalars[...]
            if scalars.last == "\r" { scalars = scalars.dropLast() }
            if scalars.starts(with: "## ".unicodeScalars) {
                section = String(scalars.dropFirst(3))
                continue
            }
            let line = String(scalars)
            guard let section, !scalars.allSatisfy({ $0 == " " || $0 == "\t" }), scalars.first != "#" else { continue }
            switch section {
            case "Always": always.append(line)
            case "Memory": memory.append(line)
            case "Rules": rules.append(line)
            default: break
            }
        }
        return BesirRules(always: always, memory: memory, rules: rules)
    }

    /// The rules in a UTF-8 file, or nil when the file cannot be read or is not valid UTF-8 (never a lossy decode).
    static func read(fileAt url: URL) -> BesirRules? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// The rules of `besir.md` in `bundle`, read afresh on every call; nil when the bundle has no such file or it cannot be read.
    static func bundled(in bundle: Bundle = Bundle(for: BesirRulesBundleToken.self)) -> BesirRules? {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else { return nil }
        return read(fileAt: url)
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

/// A class declared in the app, so `Bundle(for:)` finds the app bundle.
final class BesirRulesBundleToken {}
