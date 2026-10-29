import XCTest
@testable import besir

/// SPEC-RECURRULE-001 (card t60): a repeat rule is stored as the rule and expanded inside a window. These tests read
/// `RecurrenceRule` only; nothing here uses the network or the real clock.
final class RepeatSeriesWindowTests: XCTestCase {
    private var savedZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Seoul")!
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
        super.tearDown()
    }

    /// Read per use, not stored: `Calendar.current` follows the zone `setUp` sets.
    private var cal: Calendar { Calendar.current }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func adding(_ value: Int, _ unit: Calendar.Component, to date: Date) -> Date {
        cal.date(byAdding: unit, value: value, to: date)!
    }

    /// The lunar calendar the app uses on this OS, written once so the tests do not guard `.dangi` themselves.
    private var lunarID: Calendar.Identifier { RecurrenceRule.lunarIdentifier(osMajorVersion: 26) }

    // MARK: Rules used by more than one test

    private var weeklyBiweekly: RecurrenceRule {
        RecurrenceRule(weekdays: [2, 4], everyNWeeks: 2, unit: .weekly)
    }

    private var dailyEveryThree: RecurrenceRule { RecurrenceRule(unit: .daily, interval: 3) }

    private var monthlyDays: RecurrenceRule {
        RecurrenceRule(unit: .monthly, monthDays: [5, 20], lastDayOfMonth: true)
    }

    private var monthlyNthWeekday: RecurrenceRule {
        RecurrenceRule(weekdays: [2], nthWeekOfMonth: 2, unit: .monthly)
    }

    private var yearlyLeapDay: RecurrenceRule { RecurrenceRule(unit: .yearly, month: 2, day: 29) }

    private var lunarLeap: RecurrenceRule { RecurrenceRule(unit: .lunar, month: 5, day: 10, isLeapMonth: true) }

    private func dateList(_ a: Date, _ b: Date) -> RecurrenceRule {
        RecurrenceRule(unit: .dateList, explicitDates: [a, b])
    }

    // MARK: AC-003.1

    private func assertSame(_ a: RecurrenceRule, _ b: RecurrenceRule, _ label: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.weekdays, b.weekdays, "\(label) weekdays", file: file, line: line)
        XCTAssertEqual(a.everyNWeeks, b.everyNWeeks, "\(label) everyNWeeks", file: file, line: line)
        XCTAssertEqual(a.nthWeekOfMonth, b.nthWeekOfMonth, "\(label) nthWeekOfMonth", file: file, line: line)
        XCTAssertEqual(a.skipHolidays, b.skipHolidays, "\(label) skipHolidays", file: file, line: line)
        XCTAssertEqual(a.unit, b.unit, "\(label) unit", file: file, line: line)
        XCTAssertEqual(a.interval, b.interval, "\(label) interval", file: file, line: line)
        XCTAssertEqual(a.monthDays, b.monthDays, "\(label) monthDays", file: file, line: line)
        XCTAssertEqual(a.lastDayOfMonth, b.lastDayOfMonth, "\(label) lastDayOfMonth", file: file, line: line)
        XCTAssertEqual(a.month, b.month, "\(label) month", file: file, line: line)
        XCTAssertEqual(a.day, b.day, "\(label) day", file: file, line: line)
        XCTAssertEqual(a.isLeapMonth, b.isLeapMonth, "\(label) isLeapMonth", file: file, line: line)
        XCTAssertEqual(a.explicitDates, b.explicitDates, "\(label) explicitDates", file: file, line: line)
    }

    func testRECURRULE_RuleCodableRoundTripsAllSixUnits() throws {
        var holidays = weeklyBiweekly
        holidays.skipHolidays = true
        let rows: [(String, RecurrenceRule)] = [
            ("weekly biweekly", holidays),
            ("daily every 3", dailyEveryThree),
            ("monthly days and last day", monthlyDays),
            ("monthly nth weekday", monthlyNthWeekday),
            ("yearly Feb 29", yearlyLeapDay),
            ("lunar leap month", lunarLeap),
            ("date list", dateList(at(2026, 11, 2), at(2026, 12, 25))),
        ]
        for (label, rule) in rows {
            let data = try JSONEncoder().encode(rule)
            let back = try JSONDecoder().decode(RecurrenceRule.self, from: data)
            assertSame(rule, back, label)
        }
        let units = Set(rows.map { $0.1.unit })
        XCTAssertEqual(units, [.weekly, .daily, .monthly, .yearly, .lunar, .dateList])
    }

    // MARK: AC-003.2 (a)

    func testRECURRULE_LunarRuleKeepsTheDatesAfterRoundTrip() throws {
        let rule = RecurrenceRule(unit: .lunar, month: 8, day: 15)
        let back = try JSONDecoder().decode(RecurrenceRule.self, from: JSONEncoder().encode(rule))
        let from = at(2027, 1, 1, 0)
        let through = at(2027, 12, 31, 0)
        let before = rule.dates(from: from, through: through, calendar: cal, lunarCalendar: lunarID)
        let after = back.dates(from: from, through: through, calendar: cal, lunarCalendar: lunarID)
        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(before, after)

        // The leap month 5 of 2028 is the one leap month near these years, so the leap rule gets its own range.
        let leapFrom = at(2028, 1, 1, 0)
        let leapThrough = at(2028, 12, 31, 0)
        let leap = try JSONDecoder().decode(RecurrenceRule.self, from: JSONEncoder().encode(lunarLeap))
        XCTAssertTrue(leap.isLeapMonth)
        let leapBefore = lunarLeap.dates(from: leapFrom, through: leapThrough, calendar: cal, lunarCalendar: lunarID)
        XCTAssertFalse(leapBefore.isEmpty)
        XCTAssertEqual(leap.dates(from: leapFrom, through: leapThrough, calendar: cal, lunarCalendar: lunarID),
                       leapBefore)
    }

    // MARK: AC-005.1

    private struct Row {
        let name: String
        let rule: RecurrenceRule
        let first: Date
        /// True when every 400-day window of the row holds at least one date, so an empty answer is a failure.
        let alwaysHits: Bool
    }

    func testRECURRULE_WindowEqualsFilteredFullExpansion() {
        let rows: [Row] = [
            Row(name: "weekly biweekly Mon and Wed", rule: weeklyBiweekly, first: at(2026, 11, 2), alwaysHits: true),
            Row(name: "weekly biweekly starting on a Wednesday",
                rule: RecurrenceRule(weekdays: [4], everyNWeeks: 2, unit: .weekly),
                first: at(2026, 11, 4), alwaysHits: true),
            Row(name: "daily every 3", rule: dailyEveryThree, first: at(2026, 11, 2), alwaysHits: true),
            Row(name: "monthly days 5, 20 and last", rule: monthlyDays, first: at(2026, 11, 2), alwaysHits: true),
            Row(name: "monthly nth weekday", rule: monthlyNthWeekday, first: at(2026, 11, 2), alwaysHits: true),
            Row(name: "monthly every 3 months from Jan 31",
                rule: RecurrenceRule(unit: .monthly, interval: 3, monthDays: [31]),
                first: at(2027, 1, 31), alwaysHits: false),
            Row(name: "yearly Feb 29", rule: yearlyLeapDay, first: at(2028, 2, 29), alwaysHits: false),
            Row(name: "yearly every 2 years from Feb 29 2028",
                rule: RecurrenceRule(unit: .yearly, interval: 2, month: 2, day: 29),
                first: at(2028, 2, 29), alwaysHits: false),
            Row(name: "yearly every 2 years Mar 10",
                rule: RecurrenceRule(unit: .yearly, interval: 2, month: 3, day: 10),
                first: at(2027, 3, 10), alwaysHits: false),
            Row(name: "lunar 8/15", rule: RecurrenceRule(unit: .lunar, month: 8, day: 15),
                first: at(2026, 11, 2), alwaysHits: false),
            Row(name: "lunar leap 5/10", rule: lunarLeap, first: at(2028, 1, 1), alwaysHits: false),
            Row(name: "date list", rule: dateList(at(2026, 11, 2), adding(200, .day, to: at(2026, 11, 2))),
                first: at(2026, 11, 2), alwaysHits: false),
        ]
        var checked = 0
        for row in rows {
            let starts = [row.first, adding(90, .day, to: row.first), adding(5, .year, to: row.first),
                          adding(50, .year, to: row.first)]
            for (index, windowStart) in starts.enumerated() {
                let windowEnd = adding(400, .day, to: windowStart)
                let windowed = row.rule.dates(from: row.first, through: windowEnd, startingAt: windowStart,
                                              calendar: cal, lunarCalendar: lunarID)
                let wanted = row.rule.dates(from: row.first, through: windowEnd, calendar: cal, lunarCalendar: lunarID)
                    .filter { $0 >= cal.startOfDay(for: windowStart) }
                XCTAssertEqual(windowed, wanted, "\(row.name), window \(index)")
                if row.alwaysHits || index == 0 {
                    XCTAssertFalse(wanted.isEmpty, "\(row.name), window \(index) should hold a date")
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, rows.count * 4)
    }

    // MARK: AC-005.2

    func testRECURRULE_WalkStepsDoNotGrowWithDistance() {
        let first = at(2026, 11, 2)
        let rows: [(name: String, rule: RecurrenceRule, bound: Int)] = [
            ("weekly every Monday", RecurrenceRule(weekdays: [2], unit: .weekly), 40),
            ("daily every 3", dailyEveryThree, 15),
            ("monthly day 5", RecurrenceRule(unit: .monthly, monthDays: [5]), 6),
            ("yearly every year", RecurrenceRule(unit: .yearly, month: 6, day: 15), 4),
            ("lunar 8/15", RecurrenceRule(unit: .lunar, month: 8, day: 15), 4),
        ]
        for row in rows {
            func steps(startingAt windowStart: Date) -> Int {
                RecurrenceRule.drvWalkSteps = 0
                _ = row.rule.dates(from: first, through: adding(30, .day, to: windowStart), startingAt: windowStart,
                                   calendar: cal, lunarCalendar: lunarID)
                return RecurrenceRule.drvWalkSteps
            }
            let near = steps(startingAt: first)
            let far = steps(startingAt: adding(100, .year, to: first))
            XCTAssertGreaterThan(near, 0, "\(row.name) near: the counter must move")
            XCTAssertGreaterThan(far, 0, "\(row.name) far: the counter must move")
            XCTAssertLessThanOrEqual(near, row.bound, "\(row.name) near")
            XCTAssertLessThanOrEqual(far, row.bound, "\(row.name) far")
            XCTAssertLessThanOrEqual(far, near + 7, "\(row.name) far against near")
        }
    }

    // MARK: AC-005.3

    func testRECURRULE_WindowedEntryPointIsCounted() {
        let rule = RecurrenceRule(weekdays: [2], unit: .weekly)
        let first = at(2026, 11, 2)
        let before = RecurrenceRule.drvExpansionCount
        _ = rule.dates(from: first, through: adding(30, .day, to: first), startingAt: first, calendar: cal)
        XCTAssertEqual(RecurrenceRule.drvExpansionCount, before + 1)
        _ = rule.dates(from: first, through: adding(30, .day, to: first), calendar: cal)
        XCTAssertEqual(RecurrenceRule.drvExpansionCount, before + 2)
    }
}
