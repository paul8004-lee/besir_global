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

    /// `- count | <from>..<to> | <kind> | <key>=<value> | <context> | <n> of <total>`, the context `-` for an overall line.
    var text: String {
        "- count | \(from)..\(to) | \(kind) | \(field.key)=\(field.value) | \(context.map { "\($0.key)=\($0.value)" } ?? "-") | \(n) of \(total)"
    }
}

// @MX:NOTE: [AUTO] One generic rule over the fields of the raw memory lines: no list of kinds, keys or partners, and every raw line is read through MemoryLine(text:). The count lines MemoryCountLine(text:) accepts are read too (SPEC-MEMORY-004). The window (42 calendar days in the request's zone), the thresholds (leader 2, slice 3) and the limits (16 lines, 1600 code points) are the named constants below.
/// The counts the app makes from the raw lines of `memory.md` for the chat request.
enum MemoryCounts {
    static let windowDays = 42
    static let leaderMinimum = 2
    static let sliceMinimum = 3
    static let maxLines = 16
    static let maxScalars = 1600

    /// The common fact names; every other name comes from the lines themselves.
    private static let placeName = "place"
    private static let weekdayName = "weekday"
    private static let partName = "part"
    /// The place of a line that has none.
    private static let noPlace = "-"

    /// The part of the day of an `h:mm AM` or `h:mm PM` time: morning 5:00 AM-11:59 AM, afternoon 12:00 PM-4:59 PM, evening
    /// 5:00 PM-9:59 PM, night 10:00 PM-4:59 AM. Nil for any other text.
    static func part(of time: String) -> String? {
        let halves = time.split(separator: " ", omittingEmptySubsequences: false)
        guard halves.count == 2, halves[1] == "AM" || halves[1] == "PM" else { return nil }
        let clock = halves[0].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 2, (1...2).contains(clock[0].count), clock[1].count == 2,
              clock.allSatisfy({ $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
              let hour = Int(clock[0]), let minute = Int(clock[1]),
              (1...12).contains(hour), (0...59).contains(minute) else { return nil }
        let minutes = (hour % 12) * 60 + minute + (halves[1] == "PM" ? 720 : 0)
        switch minutes {
        case 300..<720: return "morning"
        case 720..<1020: return "afternoon"
        case 1020..<1320: return "evening"
        default: return "night"
        }
    }

    /// Today and the first day of the window as `yyyy-MM-dd` texts, both taken in `timeZone`: the window is the last 42 calendar
    /// days, with no upper bound.
    static func window(now: Date, timeZone: TimeZone) -> (today: String, start: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        guard let startDay = calendar.date(byAdding: .day, value: -windowDays, to: calendar.startOfDay(for: now)) else {
            return (today, today)
        }
        return (today, formatter.string(from: startDay))
    }

    /// Every count line the raw lines dated on or after today minus 42 calendar days support (today and the window start taken
    /// in `timeZone`, with no upper bound). For each kind and each subject key (the place, and each field not named `place`):
    /// an overall line when the leader was chosen at least twice, and a slice line for each context fact (weekday, part of the
    /// day, place) of another name whose slice holds at least three lines, whose leader was chosen at least twice and differs
    /// from the overall leader. A line's dates are the first and last date of its leader's lines in its group.
    static func candidates(from lines: [String], now: Date, timeZone: TimeZone) -> [MemoryCountLine] {
        let start = window(now: now, timeZone: timeZone).start

        let counted = lines.compactMap(MemoryLine.init(text:)).filter { $0.date >= start }.map(Counted.init)
        var result: [MemoryCountLine] = []
        for kind in firstAppearances(counted.map(\.line.kind)) {
            let ofKind = counted.filter { $0.line.kind == kind }
            for key in firstAppearances(ofKind.flatMap { $0.subjects.map(\.key) }) {
                let group = ofKind.compactMap { entry in entry.value(for: key).map { (value: $0, entry: entry) } }
                guard let overall = leader(of: group) else { continue }
                if overall.n >= leaderMinimum {
                    result.append(MemoryCountLine(from: overall.from, to: overall.to, kind: kind,
                                                  field: MemoryField(key: key, value: overall.value), context: nil,
                                                  n: overall.n, total: group.count))
                }
                let contexts = firstAppearances(group.flatMap { $0.entry.contexts }.filter { $0.key != key })
                for context in contexts {
                    let slice = group.filter { $0.entry.contexts.contains(context) }
                    guard slice.count >= sliceMinimum, let top = leader(of: slice),
                          top.n >= leaderMinimum, top.value != overall.value else { continue }
                    result.append(MemoryCountLine(from: top.from, to: top.to, kind: kind,
                                                  field: MemoryField(key: key, value: top.value), context: context,
                                                  n: top.n, total: slice.count))
                }
            }
        }
        return result
    }

    /// The candidates by strength n*n/N (compared by cross-multiplication), then the later `to` date, then the text in code-point
    /// order; taken in that order until the first line that would make more than 16 lines or more than 1600 code points, each
    /// line counted with one line feed.
    static func select(_ candidates: [MemoryCountLine]) -> [MemoryCountLine] {
        let ordered = ranked(candidates)
        var taken: [MemoryCountLine] = []
        var used = 0
        for line in ordered {
            let size = line.text.unicodeScalars.count + 1
            guard taken.count + 1 <= maxLines, used + size <= maxScalars else { break }
            taken.append(line)
            used += size
        }
        return taken
    }

    /// The count lines by strength n*n/N (compared by cross-multiplication), then the later `to` date, then the text in code-point
    /// order: the order `select` takes them in, with no limit.
    static func ranked(_ candidates: [MemoryCountLine]) -> [MemoryCountLine] {
        candidates.sorted { a, b in
            let left = a.n * a.n * b.total
            let right = b.n * b.n * a.total
            if left != right { return left > right }
            if a.to != b.to { return a.to > b.to }
            return a.text.unicodeScalars.lexicographicallyPrecedes(b.text.unicodeScalars)
        }
    }

    /// The texts of the selected count lines of `lines` at `now` in `timeZone`.
    static func summary(lines: [String], now: Date, timeZone: TimeZone) -> [String] {
        select(candidates(from: lines, now: now, timeZone: timeZone)).map(\.text)
    }

    // MARK: Helpers

    /// One counted raw line with its subject facts and its context facts.
    private struct Counted {
        let line: MemoryLine
        let subjects: [MemoryField]
        let contexts: [MemoryField]

        init(_ line: MemoryLine) {
            self.line = line
            let place = line.place == MemoryCounts.noPlace ? [] : [MemoryField(key: MemoryCounts.placeName, value: line.place)]
            subjects = place + line.fields.filter { $0.key != MemoryCounts.placeName }
            let part = MemoryCounts.part(of: line.time).map { [MemoryField(key: MemoryCounts.partName, value: $0)] } ?? []
            contexts = [MemoryField(key: MemoryCounts.weekdayName, value: line.weekday)] + part + place
        }

        func value(for key: String) -> String? {
            subjects.first { $0.key == key }?.value
        }
    }

    /// The value chosen most often (a tie goes to the value first in code-point order), how often, and the first and last date
    /// of its lines; nil for an empty group.
    private static func leader(of group: [(value: String, entry: Counted)]) -> (value: String, n: Int, from: String, to: String)? {
        var counts: [String: Int] = [:]
        for item in group { counts[item.value, default: 0] += 1 }
        guard let best = counts.max(by: { a, b in
            a.value != b.value ? a.value < b.value : b.key.unicodeScalars.lexicographicallyPrecedes(a.key.unicodeScalars)
        }) else { return nil }
        let dates = group.filter { $0.value == best.key }.map(\.entry.line.date)
        guard let from = dates.min(), let to = dates.max() else { return nil }
        return (best.key, best.value, from, to)
    }

    /// The distinct elements in the order they first appear.
    private static func firstAppearances<T: Equatable>(_ items: [T]) -> [T] {
        var seen: [T] = []
        for item in items where !seen.contains(item) { seen.append(item) }
        return seen
    }
}
