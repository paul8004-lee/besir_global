import XCTest
@testable import besir

/// SPEC-RECURTEXT-001 (card t8): the rule-based reader of English repeat phrases (`RecurrenceTextParser`).
/// Pure tests: the calendar is fixed (Gregorian, America/Los_Angeles, first weekday Sunday) and nothing reads the clock.
@MainActor
final class RecurrenceTextParserTests: XCTestCase {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = 1
        return c
    }()
    private var C: Calendar { Self.calendar }

    /// A wall-clock moment in `C`.
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 18) -> Date {
        C.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Start `S`: Monday 2026-11-02 18:00.
    private var S: Date { at(2026, 11, 2) }

    private func parts(_ date: Date?) -> [Int]? {
        guard let date else { return nil }
        let c = C.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!]
    }

    // MARK: AC-002

    /// One row of table G1: the rule fields read back through `RecurrenceRule.from`, the key set, and no end.
    private func row(_ text: String, _ unit: RecurrenceRule.Unit, d: Int = 1, n: Int = 1,
                     weekdays: Set<Int> = [], days: [Int] = [], last: Bool = false, nth: Int? = nil,
                     month: Int? = nil, day: Int? = nil, line: UInt = #line) {
        guard let result = RecurrenceTextParser.parse(text, start: S, calendar: C) else {
            return XCTFail("`\(text)` was not read", line: line)
        }
        XCTAssertNil(result.endDate, text, line: line)
        XCTAssertFalse(result.endFollowsStart, text, line: line)
        guard let rule = RecurrenceRule.from(arguments: result.arguments) else {
            return XCTFail("`\(text)` made no rule", line: line)
        }
        XCTAssertEqual(rule.unit, unit, text, line: line)
        XCTAssertEqual(rule.interval, d, text, line: line)
        XCTAssertEqual(rule.everyNWeeks, n, text, line: line)
        XCTAssertEqual(rule.weekdays, weekdays, text, line: line)
        XCTAssertEqual(rule.monthDays, days, text, line: line)
        XCTAssertEqual(rule.lastDayOfMonth, last, text, line: line)
        XCTAssertEqual(rule.nthWeekOfMonth, nth, text, line: line)
        XCTAssertEqual(rule.month, month, text, line: line)
        XCTAssertEqual(rule.day, day, text, line: line)

        var keys: Set<String> = [RecurrenceRule.Arg.unit]
        switch unit {
        case .daily: keys.insert(RecurrenceRule.Arg.interval)
        case .weekly: keys.formUnion([RecurrenceRule.Arg.everyNWeeks, RecurrenceRule.Arg.weekdays])
        case .monthly:
            keys.insert(RecurrenceRule.Arg.interval)
            if !days.isEmpty || last { keys.insert(RecurrenceRule.Arg.monthDays) }
            if nth != nil { keys.formUnion([RecurrenceRule.Arg.weekdays, RecurrenceRule.Arg.nthWeek]) }
        case .yearly:
            keys.insert(RecurrenceRule.Arg.interval)
            if month != nil { keys.formUnion([RecurrenceRule.Arg.month, RecurrenceRule.Arg.day]) }
        default: break
        }
        XCTAssertEqual(Set(result.arguments.keys), keys, text, line: line)
    }

    func testRECURTEXT_FrequencyTable() {
        let mon: Set<Int> = [2], weekdays: Set<Int> = [2, 3, 4, 5, 6], weekend: Set<Int> = [7, 1]
        row("daily", .daily)
        row("Everyday", .daily)
        row("every day", .daily)
        row("every 3 days", .daily, d: 3)
        row("every three days", .daily, d: 3)
        row("every other day", .daily, d: 2)
        row("every weekday", .weekly, weekdays: weekdays)
        row("every weekdays", .weekly, weekdays: weekdays)
        row("Weekdays", .weekly, weekdays: weekdays)
        row("every weekend", .weekly, weekdays: weekend)
        row("weekends", .weekly, weekdays: weekend)
        row("weekly", .weekly)
        row("every week", .weekly)
        row("every 2 weeks", .weekly, n: 2)
        row("every two weeks", .weekly, n: 2)
        row("every other week", .weekly, n: 2)
        row("every Monday", .weekly, weekdays: mon)
        row("EVERY  mon", .weekly, weekdays: mon)
        row("every Mon,Wed and Fri", .weekly, weekdays: [2, 4, 6])
        row("every tues & thurs", .weekly, weekdays: [3, 5])
        row("mondays and fridays", .weekly, weekdays: [2, 6])
        row("weekly on Sunday", .weekly, weekdays: [1])
        row("every week on sat", .weekly, weekdays: [7])
        row("every 2 weeks on Monday", .weekly, n: 2, weekdays: mon)
        row("every other week on Mon, Wed", .weekly, n: 2, weekdays: [2, 4])
        row("every other Friday", .weekly, n: 2, weekdays: [6])
        row("monthly", .monthly)
        row("every month", .monthly)
        row("every 2 months", .monthly, d: 2)
        row("every other month", .monthly, d: 2)
        row("monthly on the 15th", .monthly, days: [15])
        row("every month on the 1st and 15th", .monthly, days: [1, 15])
        row("every 2 months on the 5th, 20th and last day", .monthly, d: 2, days: [5, 20], last: true)
        row("every month on the last day", .monthly, last: true)
        row("every first Monday", .monthly, weekdays: mon, nth: 1)
        row("every month on the last Friday", .monthly, weekdays: [6], nth: -1)
        row("third Tuesday of every month", .monthly, weekdays: [3], nth: 3)
        row("every 2nd thu", .monthly, weekdays: [5], nth: 2)
        row("yearly", .yearly)
        row("annually", .yearly)
        row("every year", .yearly)
        row("every 2 years", .yearly, d: 2)
        row("every year on March 5", .yearly, month: 3, day: 5)
        row("yearly on mar 5th", .yearly, month: 3, day: 5)
        row("every 2 years on Dec 25", .yearly, d: 2, month: 12, day: 25)

        func exact(_ text: String, _ expected: [String: Any], line: UInt = #line) {
            let got = RecurrenceTextParser.parse(text, start: S, calendar: C)?.arguments ?? [:]
            XCTAssertTrue(NSDictionary(dictionary: got).isEqual(to: expected), "\(text): \(got)", line: line)
        }
        exact("every Monday", ["repeat_unit": "week", "weekdays": ["mon"], "every_n_weeks": 1])
        exact("every 2 months on the 5th, 20th and last day",
              ["repeat_unit": "month", "repeat_interval": 2, "month_days": [5, 20, -1]])
        exact("every month on the last Friday",
              ["repeat_unit": "month", "repeat_interval": 1, "weekdays": ["fri"], "nth_week_of_month": -1])
        exact("every year on March 5", ["repeat_unit": "year", "repeat_interval": 1, "repeat_month": 3, "repeat_day": 5])
    }

    // MARK: AC-003

    func testRECURTEXT_AbsoluteEndDates() {
        let cases: [(String, [Int])] = [
            ("until Nov 30", [2026, 11, 30]), ("until nov 30th", [2026, 11, 30]),
            ("through November 30, 2026", [2026, 11, 30]), ("till Nov 30 2026", [2026, 11, 30]),
            ("thru 11/30", [2026, 11, 30]), ("until 11/30/2026", [2026, 11, 30]), ("until 11/30/26", [2026, 11, 30]),
            ("until 2026-11-30", [2026, 11, 30]), ("until Nov 2", [2026, 11, 2]), ("until Nov 1", [2027, 11, 1]),
            ("until Oct 31", [2027, 10, 31]), ("until 2/29/2028", [2028, 2, 29]), ("until Dec 5, 2026", [2026, 12, 5]),
        ]
        for (end, day) in cases {
            let text = "every Monday \(end)"
            guard let result = RecurrenceTextParser.parse(text, start: S, calendar: C) else {
                XCTFail("`\(text)` was not read"); continue
            }
            XCTAssertFalse(result.endFollowsStart, text)
            XCTAssertEqual(parts(result.endDate), day + [0, 0], text)
        }
        for end in ["until Feb 30", "until 2/29/2027", "until 13/1", "until Smarch 3", "until Feb 29"] {
            XCTAssertNil(RecurrenceTextParser.parse("every Monday \(end)", start: S, calendar: C), end)
        }
        let nextLeap = RecurrenceTextParser.parse("daily until Feb 29", start: at(2027, 12, 1), calendar: C)
        XCTAssertEqual(parts(nextLeap?.endDate), [2028, 2, 29, 0, 0])
        XCTAssertEqual(parts(RecurrenceTextParser.parse("every Monday until nov 1th", start: S, calendar: C)?.endDate),
                       [2027, 11, 1, 0, 0])
        let december = RecurrenceTextParser.parse("every Monday until Nov 30", start: at(2026, 12, 5), calendar: C)
        XCTAssertEqual(parts(december?.endDate), [2027, 11, 30, 0, 0])
    }

    // MARK: AC-004

    func testRECURTEXT_RelativeEndDates() {
        let cases: [(String, Date, [Int])] = [
            ("every Monday for 4 weeks", S, [2026, 11, 29]),
            ("daily for 14 days", S, [2026, 11, 15]),
            ("daily for 1 day", S, [2026, 11, 2]),
            ("every weekday for two weeks", S, [2026, 11, 15]),
            ("every month on the 15th for 3 months", S, [2027, 2, 1]),
            ("daily for 1 year", S, [2027, 11, 1]),
            ("every Monday for 2 weeks", at(2026, 10, 26), [2026, 11, 8]),
        ]
        for (text, start, day) in cases {
            guard let result = RecurrenceTextParser.parse(text, start: start, calendar: C) else {
                XCTFail("`\(text)` was not read"); continue
            }
            XCTAssertTrue(result.endFollowsStart, text)
            XCTAssertEqual(parts(result.endDate), day + [0, 0], text)
        }
        let startDay = C.startOfDay(for: S)
        let thousand = RecurrenceTextParser.parse("daily for 1000 days", start: S, calendar: C)
        XCTAssertEqual(thousand?.endDate, C.date(byAdding: .day, value: 999, to: startDay))
        XCTAssertEqual(thousand?.endFollowsStart, true)

        let monday = RecurrenceTextParser.parse("every Monday for 4 weeks", start: S, calendar: C)!
        let rule = RecurrenceRule.from(arguments: monday.arguments)!
        let dates = rule.dates(from: startDay, through: monday.endDate!, calendar: C)
        XCTAssertEqual(dates.map { C.component(.day, from: $0) }, [2, 9, 16, 23])
    }

    // MARK: AC-005

    func testRECURTEXT_RejectsWhatItCannotRead() {
        let texts = [
            "", "   ", "every", "every monday please", "every monday every friday",
            "every monday until nov 30 until dec 31", "every monday for 4 weeks until dec 1", "every monday and monday",
            "every 0 days", "every 1001 days", "every monday for 0 weeks", "every monday for 1001 weeks",
            "until nov 30", "for 4 weeks", "biweekly", "every monday for 5 times", "every on monday",
            "every 2 weeks monday", "every month on the 32nd", "every month on the 0th", "every month on the 15th and 15th",
            "monday and friday", "every first monday and tuesday", "every year on feb 30", "evry monday",
            "매주 화요일 4주",
        ]
        for text in texts {
            XCTAssertNil(RecurrenceTextParser.parse(text, start: S, calendar: C), "`\(text)` must not be read")
        }
    }

    // MARK: AC-008

    private func rule(_ unit: RecurrenceRule.Unit, interval: Int = 1, weeks: Int = 1, weekdays: Set<Int> = [],
                      days: [Int] = [], last: Bool = false, nth: Int? = nil, month: Int? = nil, day: Int? = nil,
                      leap: Bool = false, dates: [Date] = [], skipHolidays: Bool = false) -> RecurrenceRule {
        var r = RecurrenceRule()
        r.unit = unit; r.interval = interval; r.everyNWeeks = weeks; r.weekdays = weekdays
        r.monthDays = days; r.lastDayOfMonth = last; r.nthWeekOfMonth = nth; r.month = month; r.day = day
        r.isLeapMonth = leap; r.explicitDates = dates; r.skipHolidays = skipHolidays
        return r
    }

    func testRECURTEXT_SummaryWording() {
        let rows: [(RecurrenceRule, Date?, String)] = [
            (rule(.daily), nil, "every day"),
            (rule(.daily, interval: 3), at(2026, 12, 1, 0), "every 3 days until Dec 1"),
            (rule(.weekly, weekdays: [2, 3, 4, 5, 6]), nil, "every weekday"),
            (rule(.weekly, weekdays: [7, 1]), nil, "every weekend"),
            (rule(.weekly, weekdays: [2]), at(2026, 11, 30, 0), "every Mon until Nov 30"),
            (rule(.weekly, weekdays: [2, 4, 6]), nil, "every Mon, Wed and Fri"),
            (rule(.weekly), nil, "every week"),
            (rule(.weekly, weeks: 2), nil, "every 2 weeks"),
            (rule(.weekly, weeks: 2, weekdays: [2, 4]), at(2027, 1, 15, 0), "every 2 weeks on Mon and Wed until Jan 15, 2027"),
            (rule(.monthly), nil, "every month"),
            (rule(.monthly, interval: 2, days: [5, 20], last: true), nil, "every 2 months on the 5th, 20th and last day"),
            (rule(.monthly, weekdays: [6], nth: -1), nil, "every month on the last Fri"),
            (rule(.weekly, weekdays: [2], nth: 1), nil, "every month on the first Mon"),
            (rule(.yearly, month: 3, day: 5), nil, "every year on Mar 5"),
            (rule(.yearly, interval: 2), nil, "every 2 years"),
            (rule(.lunar, month: 3, day: 5), nil, "every year by the Korean lunar calendar on month 3 day 5"),
            (rule(.lunar, month: 3, day: 5, leap: true), nil,
             "every year by the Korean lunar calendar on leap month 3 day 5"),
            (rule(.dateList, dates: [at(2026, 11, 3, 0), at(2026, 11, 10, 0), at(2027, 1, 5, 0)]), at(2030, 1, 1, 0),
             "Nov 3 · Nov 10 · Jan 5, 2027"),
            (rule(.daily, skipHolidays: true), nil, "every day except Korean holidays"),
        ]
        for (r, end, expected) in rows {
            XCTAssertEqual(RecurrenceLine.text(rule: r, start: S, endDate: end, calendar: C), expected)
        }
    }

    // MARK: AC-009

    /// The 45 inputs of table G1 (the rows of `testRECURTEXT_FrequencyTable`).
    private let frequencyInputs = [
        "daily", "Everyday", "every day", "every 3 days", "every three days", "every other day",
        "every weekday", "every weekdays", "Weekdays", "every weekend", "weekends", "weekly", "every week",
        "every 2 weeks", "every two weeks", "every other week", "every Monday", "EVERY  mon",
        "every Mon,Wed and Fri", "every tues & thurs", "mondays and fridays", "weekly on Sunday",
        "every week on sat", "every 2 weeks on Monday", "every other week on Mon, Wed", "every other Friday",
        "monthly", "every month", "every 2 months", "every other month", "monthly on the 15th",
        "every month on the 1st and 15th", "every 2 months on the 5th, 20th and last day",
        "every month on the last day", "every first Monday", "every month on the last Friday",
        "third Tuesday of every month", "every 2nd thu", "yearly", "annually", "every year", "every 2 years",
        "every year on March 5", "yearly on mar 5th", "every 2 years on Dec 25",
    ]

    /// Parse, build the rule, write the summary, parse the summary: the same arguments and the same end.
    private func roundTrip(_ text: String, start: Date, relative: Bool = false) {
        guard let p1 = RecurrenceTextParser.parse(text, start: start, calendar: C),
              let rule = RecurrenceRule.from(arguments: p1.arguments) else { return XCTFail("`\(text)` was not read") }
        let summary = RecurrenceLine.text(rule: rule, start: start, endDate: p1.endDate, calendar: C)
        guard let p2 = RecurrenceTextParser.parse(summary, start: start, calendar: C) else {
            return XCTFail("`\(text)` wrote `\(summary)`, which was not read back")
        }
        XCTAssertTrue(NSDictionary(dictionary: p1.arguments).isEqual(to: p2.arguments), "`\(text)` -> `\(summary)`")
        XCTAssertEqual(p1.endDate, p2.endDate, "`\(text)` -> `\(summary)`")
        if relative { XCTAssertFalse(p2.endFollowsStart, summary) }
    }

    func testRECURTEXT_SummaryRoundTrip() {
        XCTAssertEqual(frequencyInputs.count, 45)
        var cases = 0
        for input in frequencyInputs {
            for tail in ["", " until Nov 30", " until Dec 5, 2027"] {
                roundTrip(input + tail, start: S)
                cases += 1
            }
        }
        XCTAssertEqual(cases, 135)
        roundTrip("every Monday for 4 weeks", start: S, relative: true)
        roundTrip("daily for 14 days", start: S, relative: true)
        roundTrip("daily for 1 day", start: S, relative: true)
        roundTrip("every weekday for two weeks", start: S, relative: true)
        roundTrip("every month on the 15th for 3 months", start: S, relative: true)
        roundTrip("daily for 1 year", start: S, relative: true)
        roundTrip("every Monday for 2 weeks", start: at(2026, 10, 26), relative: true)
    }
}
