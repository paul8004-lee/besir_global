import Foundation

// SPEC-MEMORY-003 (card t74): the user's standing rules in rules.md. M1 skeleton: declarations only, neutral bodies.

/// The cleaning and the display of one rule line of `rules.md`.
enum RuleLine {
    static let maxScalars = 100
    static let maxRules = 20

    /// The rule text of `text`, or nil when nothing is left.
    static func clean(_ text: String, limit: Int = maxScalars) -> String? {
        nil
    }

    /// A Settings row: the stored line without its leading `- `.
    static func display(_ line: String) -> String {
        line
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
        nil
    }
}

/// The file `rules.md` in the app's support folder.
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
        []
    }

    /// The refusal an add of `text` would meet now, or nil when it would be added.
    func refusal(of text: String) -> RuleAdd? {
        .failed
    }

    /// Adds one rule, or names the refusal.
    func appending(_ text: String) -> RuleAdd {
        .failed
    }

    /// Removes the one rule line at `index`; nil when the write failed or the file cannot be read.
    func removing(at index: Int) -> [String]? {
        nil
    }

    /// Empties the file; nil when the write failed.
    func removingAll() -> [String]? {
        nil
    }
}
