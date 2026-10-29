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

        // Add tapped with the bad text still uncommitted: the card is only waiting for the reading, the commit step
        // fails it, and after that the card stays locked (the save step runs the same commit and re-checks isReady).
        var bad = makeForm(start: at(2026, 11, 2))
        bad.setTitleText(field: rowId(bad, RecurrenceLine.key), text: "every Monday please")
        XCTAssertFalse(bad.card.isReady)
        XCTAssertTrue(bad.card.isReadyAfterRecurrenceCommit)
        bad.commitRecurrenceByRules()
        XCTAssertNil(bad.activeRecurrence)
        XCTAssertEqual(note(bad), "Couldn't interpret the repeat")
        XCTAssertFalse(bad.card.isReady)
        XCTAssertFalse(bad.card.isReadyAfterRecurrenceCommit)
    }

    // MARK: AC-007

    func testRECURTEXT_NotesForMissingDetails() {
        let rows: [(String, String?, Bool)] = [
            ("weekly until Nov 30", "Enter weekdays", false),
            ("every month until Jan 31", "Enter days of the month", false),
            ("yearly until Nov 30, 2030", "Enter date", false),
            ("every Monday until 11/1/2026", "No matching dates", false),
            ("daily until 12/31/2027", nil, true),
            ("every Monday until 1/1/9999", "End date is too far away", false),
            ("every Monday until Nov 30", nil, true),
            ("evry monday", "Couldn't interpret the repeat", false),
            ("\u{B9E4}\u{C8FC} \u{D654}\u{C694}\u{C77C} 4\u{C8FC}", "Couldn't interpret the repeat", false),  // Korean, escaped
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
        guard let rule = f.recurrence.rule, let end = f.recurrence.endDate else { return XCTFail("no rule or end date") }
        let days = rule.dates(from: cal.startOfDay(for: at(2026, 11, 9)), through: end, calendar: cal)
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

    // MARK: AC-013

    func testRECURTEXT_ScreenTextConstantsUnchanged() {
        XCTAssertEqual(RecurrenceLine.label, "Repeat")
        XCTAssertEqual(RecurrenceLine.placeholder, "Repeat")
        XCTAssertEqual(RecurrenceLine.missingWeekdays, "Enter weekdays")
        XCTAssertEqual(RecurrenceLine.missingMonthDays, "Enter days of the month")
        XCTAssertEqual(RecurrenceLine.missingLunarDate, "Enter lunar date")
        XCTAssertEqual(RecurrenceLine.missingDate, "Enter date")
        XCTAssertEqual(RecurrenceLine.interpretFailed, "Couldn't interpret the repeat")
        XCTAssertEqual(RecurrenceLine.tooFar, "End date is too far away")
        XCTAssertEqual(RecurrenceLine.noOccurrence, "No matching dates")
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
        // One stored series and no stored copy; the occurrences are computed when they are read.
        XCTAssertEqual(store.series.count, 1)
        XCTAssertEqual(store.activities.filter { $0.title == "Gym" }.count, 0)
        XCTAssertEqual(store.events.count, 0)
        let window = DateInterval(start: day, end: cal.date(byAdding: .day, value: 35, to: day)!)
        let made = store.activities(in: window).filter { $0.title == "Gym" }.sorted { $0.startDate < $1.startDate }
        XCTAssertEqual(made.count, 4)
        for (i, activity) in made.enumerated() {
            let expectedStart = cal.date(byAdding: .day, value: 7 * i, to: start)!
            XCTAssertEqual(activity.startDate, expectedStart)
            XCTAssertEqual(activity.endDate, cal.date(byAdding: .hour, value: 1, to: expectedStart)!)
            XCTAssertEqual(activity.recurrenceId, store.series.first?.id)
        }
    }
}
