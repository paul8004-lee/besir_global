import XCTest
@testable import besir

/// SPEC-RECURTEXT-001 (card t8): the manual New Activity card reads the Repeat row by rule. These tests build the
/// form the way the app does and use `Calendar.current`, as the card does; nothing here uses the network.
@MainActor
final class RecurrenceTextFormTests: XCTestCase {
    private let cal = Calendar.current

    /// A wall-clock moment in `Calendar.current`.
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 18) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func rowId(_ f: LegCardForm, _ key: String) -> UUID {
        f.card.fields.first { $0.key == key }!.id
    }

    private func note(_ f: LegCardForm) -> String? {
        f.card.fields.first { $0.key == RecurrenceLine.key }?.note
    }

    /// Title `Gym`, place `No place`, the given start and an end one hour later the same day; the Repeat row empty.
    private func makeForm(start: Date) -> LegCardForm {
        let rows = LegCardForm.manualNewActivityRows(favorites: [], defaultDay: start, now: start,
                                                     presetStart: nil, calendarDefaultOn: nil)
        var f = LegCardForm(card: EditCard(fields: rows), favoriteOptions: [])
        f.setTitleText(field: rowId(f, "title"), text: "Gym")
        f.choose(field: rowId(f, "location_query"), value: PlaceTokens.noPlace)
        f.choosePlainTime(field: rowId(f, "start_iso"), date: start)
        f.choosePlainTime(field: rowId(f, "end_iso"), date: cal.date(byAdding: .hour, value: 1, to: start)!)
        return f
    }

    /// Types the Repeat text and commits the row (the step the screen runs when the row loses focus).
    private func commit(_ f: inout LegCardForm, _ text: String) {
        f.setTitleText(field: rowId(f, RecurrenceLine.key), text: text)
        f.commitRecurrenceByRules()
    }

    // MARK: AC-001

    func testRECURTEXT_CommitStepMakesActiveRecurrence() {
        var f = makeForm(start: at(2026, 11, 2))
        commit(&f, "every Monday until Nov 30")
        guard let active = f.activeRecurrence else { return XCTFail("no active recurrence") }
        XCTAssertEqual(active.rule.unit, .weekly)
        XCTAssertEqual(active.rule.weekdays, [2])
        XCTAssertEqual(active.endDate, cal.startOfDay(for: at(2026, 11, 30)))
        XCTAssertNil(note(f))
        XCTAssertTrue(f.card.isReady)

        var bad = makeForm(start: at(2026, 11, 2))
        commit(&bad, "every Monday please")
        XCTAssertNil(bad.activeRecurrence)
        XCTAssertEqual(note(bad), "Couldn't interpret the repeat")
    }

    // MARK: AC-007

    func testRECURTEXT_NotesForMissingDetails() {
        let rows: [(String, String?, Bool)] = [
            ("weekly until Nov 30", "Enter weekdays", false),
            ("every month until Jan 31", "Enter days of the month", false),
            ("yearly until Nov 30, 2030", "Enter date", false),
            ("every Monday until 11/1/2026", "No matching dates", false),
            ("daily until 12/31/2027", "End date is too far away", false),
            ("every Monday until Nov 30", nil, true),
            ("evry monday", "Couldn't interpret the repeat", false),
            ("매주 화요일 4주", "Couldn't interpret the repeat", false),
        ]
        for (text, expectedNote, active) in rows {
            var f = makeForm(start: at(2026, 11, 2))
            commit(&f, text)
            XCTAssertEqual(note(f), expectedNote, text)
            XCTAssertEqual(f.activeRecurrence != nil, active, text)
        }

        // The reader alone never supplies an end or a weekday.
        let start = at(2026, 11, 2)
        let monday = RecurrenceTextParser.parse("every Monday", start: start, calendar: cal)
        XCTAssertNotNil(monday)
        XCTAssertNil(monday?.endDate)
        let weekly = RecurrenceTextParser.parse("weekly", start: start, calendar: cal)
        XCTAssertNotNil(weekly)
        XCTAssertNil(weekly?.endDate)
        XCTAssertEqual(weekly?.arguments[RecurrenceRule.Arg.weekdays] as? [String], [])
    }

    // MARK: AC-006

    func testRECURTEXT_StartMoveFollowsRelativeEnd() {
        var f = makeForm(start: at(2026, 11, 2))
        commit(&f, "every Monday for 4 weeks")
        XCTAssertEqual(f.recurrence.endDate, cal.startOfDay(for: at(2026, 11, 29)))
        f.choosePlainTime(field: rowId(f, "start_iso"), date: at(2026, 11, 9))
        XCTAssertEqual(f.recurrence.endDate, cal.startOfDay(for: at(2026, 12, 6)))
        let rule = f.recurrence.rule!
        let days = rule.dates(from: cal.startOfDay(for: at(2026, 11, 9)), through: f.recurrence.endDate!, calendar: cal)
        XCTAssertEqual(days.map { cal.dateComponents([.month, .day], from: $0) },
                       [DateComponents(month: 11, day: 9), DateComponents(month: 11, day: 16),
                        DateComponents(month: 11, day: 23), DateComponents(month: 11, day: 30)])

        var absolute = makeForm(start: at(2026, 11, 2))
        commit(&absolute, "every Monday until Nov 5")
        absolute.choosePlainTime(field: rowId(absolute, "start_iso"), date: at(2026, 11, 9))
        XCTAssertEqual(absolute.recurrence.endDate, cal.startOfDay(for: at(2026, 11, 5)))
        XCTAssertEqual(note(absolute), "No matching dates")

        var none = makeForm(start: at(2026, 11, 2))
        none.choosePlainTime(field: rowId(none, "start_iso"), date: at(2026, 11, 9))
        XCTAssertNil(none.recurrence.interpretedText)
        XCTAssertNil(none.recurrence.rule)
        XCTAssertNil(none.recurrence.endDate)
    }

    // MARK: AC-011

    func testRECURTEXT_SaveMakesTheSeries() async {
        let store = EmptyStore.make()
        var day = cal.startOfDay(for: cal.date(byAdding: .day, value: 7, to: Date())!)
        while cal.component(.weekday, from: day) != 2 { day = cal.date(byAdding: .day, value: 1, to: day)! }
        let start = cal.date(bySettingHour: 18, minute: 0, second: 0, of: day)!
        var f = makeForm(start: start)
        commit(&f, "every Monday for 4 weeks")
        let saved = await store.saveManualActivity(f, calendarDefault: false)
        XCTAssertTrue(saved)
        let made = store.activities.filter { $0.title == "Gym" }.sorted { $0.startDate < $1.startDate }
        XCTAssertEqual(made.count, 4)
        for (i, activity) in made.enumerated() {
            let expectedStart = cal.date(byAdding: .day, value: 7 * i, to: start)!
            XCTAssertEqual(activity.startDate, expectedStart)
            XCTAssertEqual(activity.endDate, cal.date(byAdding: .hour, value: 1, to: expectedStart)!)
            XCTAssertNotNil(activity.recurrenceId)
            XCTAssertEqual(activity.recurrenceId, made.first?.recurrenceId)
        }
    }
}
