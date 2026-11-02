import Foundation

/// One count line: how often the leading value of one field was chosen among the recent matching choices of one kind.
struct MemoryCountLine: Equatable {
    let from: String
    let to: String
    let kind: String
    let field: MemoryField
    let context: MemoryField?
    let n: Int
    let total: Int

    var text: String {
        ""
    }
}

/// The counts the app makes from the raw lines of `memory.md` for the chat request.
enum MemoryCounts {
    static let windowDays = 42
    static let leaderMinimum = 2
    static let sliceMinimum = 3
    static let maxLines = 16
    static let maxScalars = 1600

    static func part(of time: String) -> String? {
        nil
    }

    static func candidates(from lines: [String], now: Date, timeZone: TimeZone) -> [MemoryCountLine] {
        []
    }

    static func select(_ candidates: [MemoryCountLine]) -> [MemoryCountLine] {
        []
    }

    static func summary(lines: [String], now: Date, timeZone: TimeZone) -> [String] {
        []
    }
}
