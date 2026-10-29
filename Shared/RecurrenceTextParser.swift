import Foundation

/// Reads the common English repeat phrases a user types in the Repeat row (`every Monday for 4 weeks`,
/// `daily until Nov 30`, `every 2 weeks`) by fixed rules, with no network and no AI. The result is the same
/// argument dictionary the AI tool uses, so `RecurrenceRule.from(arguments:)` stays the one function that builds a rule.
enum RecurrenceTextParser {
    struct Result {
        /// Keys of `RecurrenceRule.Arg` only.
        let arguments: [String: Any]
        /// The last day, included, at 00:00 in the calendar; nil when the text has no end clause.
        let endDate: Date?
        /// True only for a `for N units` end, which is counted from the start and moves with it.
        let endFollowsStart: Bool
    }

    // Shared with `RecurrenceLine.text` so the summary and the reader cannot drift apart.
    static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let weekdayAbbreviations: [Int: String] = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
    static let nthNames: [Int: String] = [1: "first", 2: "second", 3: "third", 4: "fourth", -1: "last"]

    /// @MX:NOTE: The whole text must be read and nothing may be invented (L3, L5): an unread token, a second end
    /// clause, a count of 0 or above 1000, or a missing detail returns nil or leaves the detail out, so the card's
    /// existing notes ("Enter weekdays", "Couldn't interpret the repeat", ...) stay in force.
    static func parse(_ text: String, start: Date, calendar: Calendar = .current) -> Result? {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }

        guard let split = tokens.firstIndex(where: { endKeywords.contains($0) || $0 == "for" }) else {
            guard let arguments = frequency(tokens) else { return nil }
            return Result(arguments: arguments, endDate: nil, endFollowsStart: false)
        }
        guard split > 0, let arguments = frequency(Array(tokens[..<split])) else { return nil }
        let clause = Array(tokens[split...])

        if clause[0] == "for" {
            guard clause.count == 3, let count = number(clause[1]), let unit = relativeUnits[clause[2]] else { return nil }
            let startDay = calendar.startOfDay(for: start)
            guard let after = calendar.date(byAdding: unit, value: count, to: startDay),
                  let last = calendar.date(byAdding: .day, value: -1, to: after) else { return nil }
            return Result(arguments: arguments, endDate: calendar.startOfDay(for: last), endFollowsStart: true)
        }
        guard let parts = dateParts(Array(clause.dropFirst())),
              let end = resolve(parts, start: start, calendar: calendar) else { return nil }
        return Result(arguments: arguments, endDate: end, endFollowsStart: false)
    }

    // MARK: Tokens

    private static let endKeywords: Set<String> = ["until", "through", "till", "thru"]
    private static let relativeUnits: [String: Calendar.Component] = [
        "day": .day, "days": .day, "week": .weekOfYear, "weeks": .weekOfYear,
        "month": .month, "months": .month, "year": .year, "years": .year,
    ]

    /// Lower-case words; every comma is its own token, `&` is `and`, and `,` followed by `and` is one `and`.
    private static func tokenize(_ text: String) -> [String] {
        let spaced = text.lowercased()
            .replacingOccurrences(of: ",", with: " , ")
            .replacingOccurrences(of: "&", with: " and ")
        var out: [String] = []
        for word in spaced.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if word == "and", out.last == "," { out[out.count - 1] = "and" } else { out.append(word) }
        }
        return out
    }

    private static func isDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    /// A count `N`: digits (1 to 1000, at most four characters) or `one` to `twelve`. 0 and above 1000 are not clamped.
    private static func number(_ token: String) -> Int? {
        if let word = numberWords[token] { return word }
        guard isDigits(token), token.count <= 4, let n = Int(token), (1...RecurrenceRule.maxInterval).contains(n) else { return nil }
        return n
    }

    // MARK: Weekdays and dates

    private static let weekdayOrder = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private static let fullDayNames: [String: String] = [
        "monday": "mon", "tuesday": "tue", "wednesday": "wed", "thursday": "thu",
        "friday": "fri", "saturday": "sat", "sunday": "sun",
    ]
    private static let dayNames: [String: String] = fullDayNames.merging([
        "mon": "mon", "tue": "tue", "tues": "tue", "wed": "wed", "thu": "thu", "thur": "thu",
        "thurs": "thu", "fri": "fri", "sat": "sat", "sun": "sun",
    ]) { a, _ in a }

    private static func weekday(_ token: String) -> String? { dayNames[token] }

    /// The whole token list as weekdays joined by `,` or `and`, in Monday-to-Sunday order; nil on a repeat or a leftover.
    /// With `plural`, every item is a full name plus `s` (`mondays and fridays`).
    private static func weekdayList(_ t: [String], plural: Bool = false) -> [String]? {
        var found: [String] = []
        var i = 0
        while i < t.count {
            let name: String?
            if plural {
                name = t[i].hasSuffix("s") ? fullDayNames[String(t[i].dropLast())] : nil
            } else {
                name = weekday(t[i])
            }
            guard let day = name else { return nil }
            found.append(day)
            i += 1
            if i == t.count { break }
            guard t[i] == "," || t[i] == "and", i + 1 < t.count else { return nil }
            i += 1
        }
        guard !found.isEmpty, Set(found).count == found.count else { return nil }
        return weekdayOrder.filter(found.contains)
    }

    private static let monthNames: [String: Int] = {
        let full = ["january", "february", "march", "april", "may", "june", "july", "august",
                    "september", "october", "november", "december"]
        var map: [String: Int] = ["sept": 9]
        for (i, name) in full.enumerated() {
            map[name] = i + 1
            map[String(name.prefix(3))] = i + 1
        }
        return map
    }()

    private static let ordinalSuffixes: Set<String> = ["st", "nd", "rd", "th"]

    /// A day number with an optional ordinal suffix that is not checked against the number (`30`, `30th`, `1th`).
    private static func dayNumber(_ token: String, suffixRequired: Bool = false) -> Int? {
        let digits = String(token.prefix(while: { $0.isASCII && $0.isNumber }))
        let suffix = String(token.dropFirst(digits.count))
        guard (1...2).contains(digits.count), let day = Int(digits), day >= 1 else { return nil }
        if suffix.isEmpty { return suffixRequired ? nil : day }
        return ordinalSuffixes.contains(suffix) ? day : nil
    }

    private struct DateParts {
        let month: Int
        let day: Int
        let year: Int?
    }

    /// `Mon D`, `Month D`, with an optional `, YYYY` or ` YYYY`; `M/D`, `M/D/YYYY`, `M/D/YY`; `YYYY-MM-DD`.
    private static func dateParts(_ t: [String]) -> DateParts? {
        guard !t.isEmpty else { return nil }
        if t.count == 1 { return numericDate(t[0]) }
        guard let month = monthNames[t[0]], let day = dayNumber(t[1]) else { return nil }
        var rest = Array(t.dropFirst(2))
        if rest.isEmpty { return DateParts(month: month, day: day, year: nil) }
        if rest.first == "," { rest.removeFirst() }
        guard rest.count == 1, isDigits(rest[0]), rest[0].count == 4, let year = Int(rest[0]) else { return nil }
        return DateParts(month: month, day: day, year: year)
    }

    private static func numericDate(_ token: String) -> DateParts? {
        if token.contains("/") {
            let p = token.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard (2...3).contains(p.count), p.allSatisfy(isDigits), p[0].count <= 2, p[1].count <= 2,
                  let m = Int(p[0]), let d = Int(p[1]) else { return nil }
            if p.count == 2 { return DateParts(month: m, day: d, year: nil) }
            guard p[2].count == 4 || p[2].count == 2, let y = Int(p[2]) else { return nil }
            return DateParts(month: m, day: d, year: p[2].count == 2 ? 2000 + y : y)
        }
        let p = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3, p.allSatisfy(isDigits), p[0].count == 4, p[1].count <= 2, p[2].count <= 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return DateParts(month: m, day: d, year: y)
    }

    /// Validates by reading the components back (`Feb 30` does not exist). Without a year: the start's year if the day
    /// exists there and is not before the start day, else the next year, and no further.
    private static func resolve(_ p: DateParts, start: Date, calendar: Calendar) -> Date? {
        func make(_ year: Int) -> Date? {
            var c = DateComponents()
            c.year = year; c.month = p.month; c.day = p.day
            guard let date = calendar.date(from: c) else { return nil }
            let back = calendar.dateComponents([.year, .month, .day], from: date)
            guard back.year == year, back.month == p.month, back.day == p.day else { return nil }
            return calendar.startOfDay(for: date)
        }
        if let year = p.year { return make(year) }
        let startDay = calendar.startOfDay(for: start)
        let startYear = calendar.component(.year, from: startDay)
        if let day = make(startYear), day >= startDay { return day }
        return make(startYear + 1)
    }

    // MARK: Frequency (table G1)

    private typealias Arguments = [String: Any]

    private static func args(_ unit: String, interval: Int? = nil, weeks: Int? = nil, weekdays: [String]? = nil) -> Arguments {
        var a: Arguments = [RecurrenceRule.Arg.unit: unit]
        if let interval { a[RecurrenceRule.Arg.interval] = interval }
        if let weeks { a[RecurrenceRule.Arg.everyNWeeks] = weeks }
        if let weekdays { a[RecurrenceRule.Arg.weekdays] = weekdays }
        return a
    }

    private enum Cadence { case day, week, month, year }

    /// The leading words that name a cadence and its count, and how many tokens they take.
    private static func cadence(_ f: [String]) -> (cadence: Cadence, n: Int, used: Int)? {
        switch f[0] {
        case "daily", "everyday": return (.day, 1, 1)
        case "weekly": return (.week, 1, 1)
        case "monthly": return (.month, 1, 1)
        case "yearly", "annually": return (.year, 1, 1)
        case "every":
            guard f.count >= 2 else { return nil }
            switch f[1] {
            case "day": return (.day, 1, 2)
            case "week": return (.week, 1, 2)
            case "month": return (.month, 1, 2)
            case "year": return (.year, 1, 2)
            case "other":
                guard f.count >= 3 else { return nil }
                switch f[2] {
                case "day": return (.day, 2, 3)
                case "week": return (.week, 2, 3)
                case "month": return (.month, 2, 3)
                default: return nil
                }
            default:
                guard f.count >= 3, let n = number(f[1]) else { return nil }
                switch f[2] {
                case "days": return (.day, n, 3)
                case "weeks": return (.week, n, 3)
                case "months": return (.month, n, 3)
                case "years": return (.year, n, 3)
                default: return nil
                }
            }
        default: return nil
        }
    }

    private static func frequency(_ f: [String]) -> Arguments? {
        guard !f.isEmpty else { return nil }
        switch f {
        case ["every", "weekday"], ["every", "weekdays"], ["weekdays"]:
            return args("week", weeks: 1, weekdays: ["mon", "tue", "wed", "thu", "fri"])
        case ["every", "weekend"], ["every", "weekends"], ["weekends"]:
            return args("week", weeks: 1, weekdays: ["sat", "sun"])
        default: break
        }
        if let lead = cadence(f) { return withCadence(lead, rest: Array(f[lead.used...]), full: f) }
        return withoutCadence(f)
    }

    /// A cadence word plus its optional ` on ...` tail.
    private static func withCadence(_ lead: (cadence: Cadence, n: Int, used: Int), rest: [String], full f: [String]) -> Arguments? {
        switch lead.cadence {
        case .day:
            return rest.isEmpty ? args("day", interval: lead.n) : nil
        case .week:
            if rest.isEmpty { return args("week", weeks: lead.n, weekdays: []) }
            guard rest[0] == "on", let days = weekdayList(Array(rest.dropFirst())) else { return nil }
            return args("week", weeks: lead.n, weekdays: days)
        case .month:
            if rest.isEmpty { return args("month", interval: lead.n) }
            guard rest[0] == "on" else { return nil }
            var tail = Array(rest.dropFirst())
            let hadThe = tail.first == "the"
            if hadThe { tail.removeFirst() }
            if hadThe, f.starts(with: ["every", "month"]), lead.used == 2, tail.count == 2,
               let nth = nthValue(tail[0]), let day = weekday(tail[1]) {
                var a = args("month", interval: 1, weekdays: [day])
                a[RecurrenceRule.Arg.nthWeek] = nth
                return a
            }
            guard let days = ordinalList(tail) else { return nil }
            var a = args("month", interval: lead.n)
            a[RecurrenceRule.Arg.monthDays] = days
            return a
        case .year:
            if rest.isEmpty { return args("year", interval: lead.n) }
            guard rest.count == 3, rest[0] == "on", let month = monthNames[rest[1]], let day = dayNumber(rest[2]),
                  validInLeapYear(month: month, day: day) else { return nil }
            var a = args("year", interval: lead.n)
            a[RecurrenceRule.Arg.month] = month
            a[RecurrenceRule.Arg.day] = day
            return a
        }
    }

    /// Forms with no cadence word: a weekday list, `every other D`, and the nth weekday of a month.
    private static func withoutCadence(_ f: [String]) -> Arguments? {
        if f[0] == "every" {
            if f.count == 3, f[1] == "other", let day = weekday(f[2]) { return args("week", weeks: 2, weekdays: [day]) }
            if f.count == 3, let nth = nthValue(f[1]), let day = weekday(f[2]) {
                var a = args("month", interval: 1, weekdays: [day])
                a[RecurrenceRule.Arg.nthWeek] = nth
                return a
            }
            guard let days = weekdayList(Array(f.dropFirst())) else { return nil }
            return args("week", weeks: 1, weekdays: days)
        }
        if f.count == 5, f[2] == "of", f[3] == "every", f[4] == "month",
           let nth = nthValue(f[0]), let day = weekday(f[1]) {
            var a = args("month", interval: 1, weekdays: [day])
            a[RecurrenceRule.Arg.nthWeek] = nth
            return a
        }
        guard let days = weekdayList(f, plural: true) else { return nil }
        return args("week", weeks: 1, weekdays: days)
    }

    private static func nthValue(_ token: String) -> Int? {
        switch token {
        case "first", "1st": return 1
        case "second", "2nd": return 2
        case "third", "3rd": return 3
        case "fourth", "4th": return 4
        case "last": return -1
        default: return nil
        }
    }

    /// Days of the month joined by `,` or `and` (`5th, 20th and last day`): ascending, `-1` for the last day at the end.
    private static func ordinalList(_ t: [String]) -> [Int]? {
        var found: [Int] = []
        var i = 0
        while i < t.count {
            if t[i] == "last", i + 1 < t.count, t[i + 1] == "day" {
                found.append(-1)
                i += 2
            } else if let day = dayNumber(t[i], suffixRequired: true), day <= 31 {
                found.append(day)
                i += 1
            } else {
                return nil
            }
            if i == t.count { break }
            guard t[i] == "," || t[i] == "and", i + 1 < t.count else { return nil }
            i += 1
        }
        guard !found.isEmpty, Set(found).count == found.count else { return nil }
        return found.filter { $0 > 0 }.sorted() + (found.contains(-1) ? [-1] : [])
    }

    /// The month and day of a yearly rule: checked against 2000, a leap year, so `Feb 29` is allowed.
    private static func validInLeapYear(month: Int, day: Int) -> Bool {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? .current
        var c = DateComponents()
        c.year = 2000; c.month = month; c.day = day
        guard let date = gregorian.date(from: c) else { return false }
        let back = gregorian.dateComponents([.month, .day], from: date)
        return back.month == month && back.day == day
    }
}
