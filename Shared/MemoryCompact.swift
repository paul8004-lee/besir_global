import Foundation

// @MX:NOTE: [AUTO] The one reader of the count-line grammar that MemoryCounts writes (SPEC-MEMORY-004). It splits by code point, never by Character, holds no list of kinds, keys or values, and reads a text back to exactly the same code points or refuses it.
extension MemoryCountLine {
    /// The most a count line can say it counted: its numbers have at most four digits.
    static let maxDigits = 4
    static let maxTotal = 9999

    private static let itemPrefix = "- "
    private static let separator = " | "
    private static let countWord = "count"
    private static let rangeMark = ".."
    private static let ofMark = " of "
    /// The context names of the grammar, the key of the place, and the marker of a line with no context.
    private static let weekdayContext = "weekday"
    private static let partContext = "part"
    private static let placeContext = "place"
    private static let noContext = "-"
    private static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    /// The parts of the day the counting names, found by asking it about each whole hour.
    private static let partNames: Set<String> = Set(["AM", "PM"].flatMap { half in
        (1...12).compactMap { MemoryCounts.part(of: "\($0):00 \(half)") }
    })

    /// Reads one count line, or nil when the text is not exactly the grammar: `- count | <from>..<to> | <kind> | <key>=<value> |
    /// <context> | <n> of <N>` with real dates (from not after to), a token kind and key, clean text, a context of `-`, a weekday,
    /// a part of the day or a place other than the key, and 2 <= n <= N of at most four digits (N at least 3 with a context).
    init?(text: String) {
        let scalars = text.unicodeScalars
        guard scalars.count <= MemoryLine.maxLineScalars, scalars.starts(with: Self.itemPrefix.unicodeScalars) else { return nil }
        let parts = Self.pieces(scalars.dropFirst(Self.itemPrefix.unicodeScalars.count), by: Self.separator)
        guard parts.count == 6, parts[0] == Self.countWord else { return nil }

        let days = Self.pieces(parts[1].unicodeScalars[...], by: Self.rangeMark)
        guard days.count == 2, Self.isDay(days[0]), Self.isDay(days[1]), days[0] <= days[1] else { return nil }
        guard Self.isToken(parts[2]) else { return nil }

        guard let (key, value) = Self.split(parts[3]), Self.isToken(key), Self.isClean(value),
              key != Self.placeContext || value != Self.noContext else { return nil }

        var context: MemoryField?
        if parts[4] != Self.noContext {
            guard let (name, contextValue) = Self.split(parts[4]), name != key else { return nil }
            if name == Self.weekdayContext {
                guard Self.weekdayNames.contains(contextValue) else { return nil }
            } else if name == Self.partContext {
                guard Self.partNames.contains(contextValue) else { return nil }
            } else if name == Self.placeContext {
                guard Self.isClean(contextValue), contextValue != Self.noContext else { return nil }
            } else {
                return nil
            }
            context = MemoryField(key: name, value: contextValue)
        }

        let numbers = Self.pieces(parts[5].unicodeScalars[...], by: Self.ofMark)
        guard numbers.count == 2, let n = Self.number(numbers[0]), let total = Self.number(numbers[1]),
              n >= 2, n <= total, context == nil || total >= 3 else { return nil }

        let line = MemoryCountLine(from: days[0], to: days[1], kind: parts[2], field: MemoryField(key: key, value: value),
                                   context: context, n: n, total: total)
        guard Array(line.text.unicodeScalars) == Array(scalars) else { return nil }
        self = line
    }

    // MARK: Reading helpers

    /// The texts between the `mark`s, found by code point: a text that begins with a combining mark or ends with a prepended
    /// mark would otherwise join the space of the separator into one Character.
    private static func pieces(_ scalars: Substring.UnicodeScalarView, by mark: String) -> [String] {
        let marker = Array(mark.unicodeScalars)
        var result: [String] = []
        var rest = scalars
        while let range = rest.firstRange(of: marker) {
            result.append(String(rest[..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }
        result.append(String(rest))
        return result
    }

    /// The text before the first `=` and the text after it, split by code point.
    private static func split(_ text: String) -> (String, String)? {
        let scalars = text.unicodeScalars
        guard let equals = scalars.firstIndex(of: "=") else { return nil }
        return (String(scalars[..<equals]), String(scalars[scalars.index(after: equals)...]))
    }

    /// A token: `[a-z][a-z0-9_]{0,19}`.
    private static func isToken(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard (1...20).contains(scalars.count), ("a"..."z").contains(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// Text the memory line writer would store as it is: cleaning it changes no code point, and it is not empty.
    private static func isClean(_ text: String) -> Bool {
        MemoryLine.clean(text).map { Array($0.unicodeScalars) == Array(text.unicodeScalars) } ?? false
    }

    /// A strict Gregorian `yyyy-MM-dd` day: the shape is checked on the text first, then the calendar must give the day back.
    private static func isDay(_ text: String) -> Bool {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].unicodeScalars.count == 4, pieces[1].unicodeScalars.count == 2,
              pieces[2].unicodeScalars.count == 2,
              pieces.allSatisfy({ $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    /// A whole number of one to `maxDigits` ASCII digits with no leading zero, checked on the text before any conversion.
    private static func number(_ text: String) -> Int? {
        let scalars = Array(text.unicodeScalars)
        guard (1...maxDigits).contains(scalars.count), scalars[0] != "0",
              scalars.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(text)
    }
}

/// The compaction of the item lines of `memory.md` that one append makes (SPEC-MEMORY-004): the newest `keepRaw` raw lines stay
/// when more than `maxRaw` are there, the older ones fold into the counts the counting itself makes of them, count lines whose
/// last date has left the window go, and at most `maxCounts` count lines stay.
struct MemoryCompaction {
    static let keepRaw = 30
    static let maxRaw = 60
    static let maxCounts = 40

    let now: Date
    let zone: TimeZone

    // @MX:NOTE: [AUTO] Pure and append-only: the item lines in, the item lines out, no clock but `now`, no file, no reading of the count lines already in the file by the fold; an earlier count line is never reopened or merged. Every rule comes from MemoryCounts.
    /// The item lines after one append: the count lines in the counting's order, then the raw lines as written. A line that is
    /// neither a raw line nor a count line the reader accepts is not carried on.
    func compact(_ lines: [String]) -> [String] {
        let window = MemoryCounts.window(now: now, timeZone: zone)
        var raws: [String] = []
        var counted: [MemoryCountLine] = []
        for line in lines {
            if MemoryLine(text: line) != nil {
                raws.append(line)
            } else if let count = MemoryCountLine(text: line) {
                counted.append(count)
            }
        }
        if raws.count > Self.maxRaw {
            let folded = Array(raws.dropLast(Self.keepRaw))
            raws = Array(raws.suffix(Self.keepRaw))
            counted += MemoryCounts.candidates(from: folded, now: now, timeZone: zone)
                .filter { $0.total <= MemoryCountLine.maxTotal }
                .map { Self.clamped($0, to: window.today) }
        }
        let inWindow = counted.filter { $0.to >= window.start }
        return MemoryCounts.ranked(inWindow).prefix(Self.maxCounts).map(\.text) + raws
    }

    /// The line with a date after `today` written as `today`, so a booking does not keep a count line in the window.
    private static func clamped(_ line: MemoryCountLine, to today: String) -> MemoryCountLine {
        MemoryCountLine(from: min(line.from, today), to: min(line.to, today), kind: line.kind, field: line.field,
                        context: line.context, n: line.n, total: line.total)
    }
}
