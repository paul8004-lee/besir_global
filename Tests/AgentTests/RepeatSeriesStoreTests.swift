import XCTest
@testable import besir

/// SPEC-RECURRULE-001 (card t60): the stored series, its file, its ids and the readers. The tests arrive with the
/// milestone that builds what they read; the window core is covered in `RepeatSeriesWindowTests`.
/// All dates here are class A: only new code and injected clocks are reached, so fixed 2026 dates are safe.
@MainActor
final class RepeatSeriesStoreTests: XCTestCase {
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

    // MARK: Helpers

    /// Read per use, not stored: `Calendar.current` follows the zone `setUp` sets.
    private var cal: Calendar { Calendar.current }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func month(_ y: Int, _ m: Int) -> DateInterval {
        DateInterval(start: at(y, m, 1), end: at(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 1))
    }

    private func dataURL(_ name: String) -> URL {
        AppConfig.supportDirectory.appendingPathComponent(name)
    }

    private func bytes(_ name: String) -> Data? { try? Data(contentsOf: dataURL(name)) }

    private func write(_ data: Data, _ name: String) throws {
        try FileManager.default.createDirectory(at: AppConfig.supportDirectory, withIntermediateDirectories: true)
        try data.write(to: dataURL(name))
    }

    /// A second store on the same support directory, the way a relaunch builds one.
    private func relaunched() -> Store { Store(notifications: NotificationManager()) }

    private let home = Place(name: "Home", address: "1 Home St", latitude: 37.5, longitude: 127.0)
    private let office = Place(name: "Office", address: "2 Work Ave", latitude: 37.6, longitude: 127.1)

    /// Weekly on Monday, 09:00 to 09:30, first day Monday 2026-11-02.
    private func standup(last: Int? = nil, skipped: [Int] = []) -> RepeatSeries {
        RepeatSeries(id: RepeatSeries.newID(), title: "Standup", location: office,
                     rule: RecurrenceRule(weekdays: [2], unit: .weekly), lunarCalendar: nil,
                     firstDayKey: 20261102, lastDayKey: last, startMinute: 540, endMinute: 570,
                     endDayDistance: 0, syncToCalendar: nil, skippedDayKeys: skipped,
                     legPlan: nil, legsFilledThroughDayKey: nil)
    }

    /// The four big-endian bytes of a day key, built with shifts so the test does not copy the code under test.
    private func tailBytes(_ dayKey: Int) -> [UInt8] {
        let v = UInt32(dayKey)
        return [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    /// Two encodes of the same value do not always list the keys in the same order, so "the same bytes" is checked as the
    /// same byte count and the same JSON value: an added, dropped or changed field still fails.
    private func sameJSON(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b, a.count == b.count,
              let x = try? JSONSerialization.jsonObject(with: a) as? NSArray,
              let y = try? JSONSerialization.jsonObject(with: b) as? NSArray else { return false }
        return x.isEqual(y)
    }

    private func idBytes(_ id: UUID) -> [UInt8] { withUnsafeBytes(of: id.uuid) { Array($0) } }

    private func assertSameRule(_ a: RecurrenceRule, _ b: RecurrenceRule, _ label: String,
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

    // MARK: Forms (AC-001, AC-004, AC-008, AC-009)

    private func rowId(_ f: LegCardForm, _ key: String) -> UUID {
        f.card.fields.first { $0.key == key }!.id
    }

    private func note(_ f: LegCardForm) -> String? {
        f.card.fields.first { $0.key == RecurrenceLine.key }?.note
    }

    /// The New Activity card as the app builds it: title `Standup`, the given place (none when nil), start, and an end
    /// (30 minutes after the start unless given); the Repeat row empty and the travel toggles off.
    private func makeForm(start: Date, end: Date? = nil, place: Place? = nil) -> LegCardForm {
        let rows = LegCardForm.manualNewActivityRows(favorites: [], defaultDay: start, now: start,
                                                     presetStart: nil, calendarDefaultOn: nil)
        var f = LegCardForm(card: EditCard(fields: rows), favoriteOptions: [])
        f.setTitleText(field: rowId(f, "title"), text: "Standup")
        if let place {
            f.choose(field: rowId(f, "location_query"), value: place.name, place: place)
        } else {
            f.choose(field: rowId(f, "location_query"), value: PlaceTokens.noPlace)
        }
        f.choosePlainTime(field: rowId(f, "start_iso"), date: start)
        f.choosePlainTime(field: rowId(f, "end_iso"), date: end ?? start.addingTimeInterval(1800))
        return f
    }

    /// Types the Repeat text and commits the row (the step the screen runs when the row loses focus).
    private func commit(_ f: inout LegCardForm, _ text: String) {
        f.setTitleText(field: rowId(f, RecurrenceLine.key), text: text)
        f.commitRecurrenceByRules()
    }

    /// Writes the end field directly, past what the repeat's end wheel offers, to reach the last guard of the save.
    private func setEnd(_ f: inout LegCardForm, _ date: Date) {
        let i = f.card.fields.firstIndex { $0.key == "end_iso" }!
        f.card.fields[i].chosen = BesirTime.isoFormatter.string(from: date)
    }

    private var fixtureClock: Date { at(2026, 11, 2, 8) }

    /// An empty store whose clock is the fixture clock (Monday 2026-11-02 08:00).
    private func fixtureStore() -> Store {
        let store = EmptyStore.make()
        let clock = fixtureClock
        store.replanNow = { clock }
        return store
    }

    private func standups(in store: Store, _ interval: DateInterval) -> [ActivityBlock] {
        store.activities(in: interval).filter { $0.title == "Standup" }
    }

    // MARK: AC-002 - own file, old files untouched

    func testRECURRULE_SeriesFileLoadsAndOldFilesAreByteIdentical() throws {
        let owner = UUID()
        let activityA = ActivityBlock(title: "Old copy A", location: office, startDate: at(2026, 11, 2, 9),
                                      endDate: at(2026, 11, 2, 10), recurrenceId: owner)
        let activityB = ActivityBlock(title: "Old copy B", location: office, startDate: at(2026, 11, 9, 9),
                                      endDate: at(2026, 11, 9, 10), recurrenceId: owner)
        let leg = ScheduledEvent(title: "Old leg", destination: office, arrivalDate: at(2026, 11, 2, 9),
                                 mode: .car, bufferMinutes: 5, notifyLeadMinutes: 10, recurrenceId: owner,
                                 linkedActivityId: activityA.id)
        let seed = {
            try self.write(JSONEncoder().encode([activityA, activityB]), "activities.json")
            try self.write(JSONEncoder().encode([leg]), "events.json")
        }
        // A save of activities and of events with no `deleteActivities` target in the list rewrites both files.
        let dummy = ActivityBlock(title: "Not stored", location: nil, startDate: at(2026, 11, 3), endDate: at(2026, 11, 3, 1))

        // Control run: a store that never touches a series.
        _ = EmptyStore.make()
        try seed()
        let control = relaunched()
        XCTAssertEqual(control.activities.count, 2)
        XCTAssertEqual(control.events.count, 1)
        control.deleteActivities([dummy])
        control.save()
        let controlActivities = bytes("activities.json")
        let controlEvents = bytes("events.json")
        XCTAssertNotNil(controlActivities)
        XCTAssertNotNil(controlEvents)

        // Row 3: no series.json yet, the store starts with no series and every other file loads.
        _ = EmptyStore.make()
        try seed()
        XCTAssertNil(bytes("series.json"))
        let store = relaunched()
        XCTAssertEqual(store.series.count, 0)
        XCTAssertEqual(store.activities.count, 2)
        XCTAssertEqual(store.events.count, 1)

        // Row 2: with a series saved, the two old files carry the same bytes as the control run.
        var series = standup(skipped: [20261109, 20261116])
        series.legPlan = LegPlan(outboundFrom: home, returnTo: home, outboundMode: .transit, returnMode: .walk,
                                 bufferMinutes: 7, notifyLeadMinutes: 15, notifyEnabled: true)
        series.legsFilledThroughDayKey = 20261116
        XCTAssertTrue(store.addSeries(series))
        store.deleteActivities([dummy])
        store.save()
        XCTAssertNotNil(bytes("series.json"))
        XCTAssertTrue(sameJSON(bytes("activities.json"), controlActivities), "activities.json must not change because a series exists")
        XCTAssertTrue(sameJSON(bytes("events.json"), controlEvents), "events.json must not change because a series exists")

        // Row 1: a new store on the same directory loads the series with every field equal.
        let reloaded = relaunched()
        XCTAssertEqual(reloaded.series.count, 1)
        guard let loaded = reloaded.series.first else { return }
        XCTAssertEqual(loaded.id, series.id)
        XCTAssertEqual(loaded.title, series.title)
        XCTAssertEqual(loaded.location, series.location)
        assertSameRule(loaded.rule, series.rule, "loaded rule")
        XCTAssertEqual(loaded.firstDayKey, 20261102)
        XCTAssertNil(loaded.lastDayKey)
        XCTAssertEqual(loaded.startMinute, 540)
        XCTAssertEqual(loaded.endMinute, 570)
        XCTAssertEqual(loaded.endDayDistance, 0)
        XCTAssertEqual(loaded.skippedDayKeys, [20261109, 20261116])
        XCTAssertEqual(loaded.legsFilledThroughDayKey, 20261116)
        XCTAssertEqual(loaded.legPlan?.outboundFrom, home)
        XCTAssertEqual(loaded.legPlan?.returnTo, home)
        XCTAssertEqual(loaded.legPlan?.outboundMode, .transit)
        XCTAssertEqual(loaded.legPlan?.returnMode, .walk)
        XCTAssertEqual(loaded.legPlan?.bufferMinutes, 7)
        XCTAssertEqual(loaded.legPlan?.notifyLeadMinutes, 15)
        XCTAssertEqual(loaded.legPlan?.notifyEnabled, true)
        XCTAssertEqual(reloaded.activities.count, 2)
        XCTAssertEqual(reloaded.events.count, 1)
    }

    // MARK: AC-003 row 2(b) - the lunar choice is stored

    func testRECURRULE_LunarChoiceIsStoredAndKeepsTheDates() throws {
        // Lunar New Year (lunar month 1, day 1). The choice is stored with the series, so the dates are those of the
        // dangi calendar even when the OS default would give the chinese one.
        var series = standup()
        series.title = "Seollal"
        series.rule = RecurrenceRule(unit: .lunar, month: 1, day: 1)
        series.lunarCalendar = .dangi
        series.firstDayKey = 20270101
        let interval = DateInterval(start: at(2027, 1, 1), end: at(2028, 1, 1))

        let before = series.occurrences(in: interval).map(\.startDate)
        let expected = series.rule.dates(from: at(2027, 1, 1), through: at(2027, 12, 31),
                                           lunarCalendar: RecurrenceRule.lunarIdentifier(osMajorVersion: 26))
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before.map { cal.startOfDay(for: $0) }, expected.map { cal.startOfDay(for: $0) })
        // The Korean new moon of Feb 2027 falls just after midnight in Seoul and just before it in Beijing, so the
        // two calendars name different days: the stored choice is what keeps this series on the Korean one.
        if #available(iOS 26, macOS 26, *) {
            XCTAssertEqual(before.first.map { Store.dayKey($0, calendar: cal) }, 20270207, "dangi: Feb 7")
            var chinese = series
            chinese.lunarCalendar = .chinese
            XCTAssertEqual(chinese.occurrences(in: interval).first.map { Store.dayKey($0.startDate, calendar: cal) }, 20270206, "chinese: Feb 6")
        }

        let data = try JSONEncoder().encode(series)
        let decoded = try JSONDecoder().decode(RepeatSeries.self, from: data)
        XCTAssertEqual(decoded.lunarCalendar, .dangi)
        XCTAssertEqual(decoded.occurrences(in: interval).map(\.startDate), before)
    }

    // MARK: AC-004 - an unreadable series file

    func testRECURRULE_UnreadableSeriesFileIsCopiedBeforeTheNextSave() throws {
        _ = EmptyStore.make()
        let kept = ActivityBlock(title: "Kept", location: nil, startDate: at(2026, 11, 3, 9), endDate: at(2026, 11, 3, 10))
        try write(JSONEncoder().encode([kept]), "activities.json")
        try write(Data("not json".utf8), "series.json")

        // Row 1: no series, every other file still loads, and the bad file is left where it is.
        let store = relaunched()
        XCTAssertEqual(store.series.count, 0)
        XCTAssertTrue(store.seriesLoadFailed)
        XCTAssertEqual(store.activities.count, 1)
        XCTAssertEqual(bytes("series.json"), Data("not json".utf8))
        XCTAssertNil(bytes("series.unreadable.json"))

        // Row 2: the first save copies the old bytes, then writes the new list.
        XCTAssertTrue(store.addSeries(standup()))
        XCTAssertFalse(store.seriesLoadFailed)
        XCTAssertEqual(bytes("series.unreadable.json"), Data("not json".utf8))
        let written = try JSONDecoder().decode([RepeatSeries].self, from: XCTUnwrap(bytes("series.json")))
        XCTAssertEqual(written.count, 1)
    }

    func testRECURRULE_SecondUnreadableFileGetsANumberedName() throws {
        _ = EmptyStore.make()
        try write(Data("first bad".utf8), "series.json")
        let first = relaunched()
        XCTAssertTrue(first.saveSeries())
        XCTAssertEqual(bytes("series.unreadable.json"), Data("first bad".utf8))

        // Restore bad bytes, reload, save: the next free name is used and the first copy is untouched.
        try write(Data("second bad".utf8), "series.json")
        let second = relaunched()
        XCTAssertTrue(second.seriesLoadFailed)
        XCTAssertTrue(second.saveSeries())
        XCTAssertEqual(bytes("series.unreadable-2.json"), Data("second bad".utf8))
        XCTAssertEqual(bytes("series.unreadable.json"), Data("first bad".utf8))

        try write(Data("third bad".utf8), "series.json")
        let third = relaunched()
        XCTAssertTrue(third.saveSeries())
        XCTAssertEqual(bytes("series.unreadable-3.json"), Data("third bad".utf8))
        XCTAssertEqual(bytes("series.unreadable-2.json"), Data("second bad".utf8))
    }

    func testRECURRULE_FailedCopyDoesNotOverwriteAndSaveReturnsFalse() throws {
        // The `saveManualActivity` half of AC-004 row 3 is `testRECURRULE_SaveRefusedWhenSeriesFileCannotBeBackedUp`;
        // this test covers `saveSeries` and `addSeries`.
        _ = EmptyStore.make()
        try write(Data("bad".utf8), "series.json")
        for n in 1...9 {
            try write(Data("old \(n)".utf8), n == 1 ? "series.unreadable.json" : "series.unreadable-\(n).json")
        }
        let store = relaunched()
        XCTAssertTrue(store.seriesLoadFailed)

        XCTAssertFalse(store.saveSeries())
        XCTAssertEqual(bytes("series.json"), Data("bad".utf8), "a failed copy must not write over the bad file")
        XCTAssertTrue(store.seriesLoadFailed, "the flag stays while the file is unprotected")

        XCTAssertFalse(store.addSeries(standup()))
        XCTAssertEqual(store.series.count, 0, "the series is taken out of memory again")
        XCTAssertEqual(bytes("series.json"), Data("bad".utf8))
        for n in 1...9 {
            XCTAssertEqual(bytes(n == 1 ? "series.unreadable.json" : "series.unreadable-\(n).json"), Data("old \(n)".utf8))
        }
    }

    // MARK: AC-006 - occurrences

    func testRECURRULE_OccurrencesMondayNoEnd() {
        // Row 1.
        let series = standup()
        let blocks = series.occurrences(in: month(2026, 11))
        XCTAssertEqual(blocks.map(\.startDate), [at(2026, 11, 2, 9), at(2026, 11, 9, 9), at(2026, 11, 16, 9),
                                                 at(2026, 11, 23, 9), at(2026, 11, 30, 9)])
        XCTAssertEqual(blocks.map(\.endDate), [at(2026, 11, 2, 9, 30), at(2026, 11, 9, 9, 30), at(2026, 11, 16, 9, 30),
                                               at(2026, 11, 23, 9, 30), at(2026, 11, 30, 9, 30)])
        XCTAssertTrue(blocks.allSatisfy { $0.recurrenceId == series.id })
        XCTAssertTrue(blocks.allSatisfy { $0.title == "Standup" && $0.location == office })
        XCTAssertEqual(blocks.map(\.id), [20261102, 20261109, 20261116, 20261123, 20261130].map { series.occurrenceID(dayKey: $0) })

        // Nothing before the first day, however far the look-back reaches.
        XCTAssertTrue(series.occurrences(in: DateInterval(start: at(2026, 10, 1), end: at(2026, 11, 2))).isEmpty)

        // Row 2: a last day is inclusive of that day's occurrence.
        let ended = standup(last: 20261116)
        XCTAssertEqual(ended.occurrences(in: month(2026, 11)).map(\.startDate),
                       [at(2026, 11, 2, 9), at(2026, 11, 9, 9), at(2026, 11, 16, 9)])

        // Row 6: never a block that ends at or before its start.
        XCTAssertTrue(blocks.allSatisfy { $0.endDate > $0.startDate })
        let far = series.occurrences(in: month(2029, 3))
        XCTAssertEqual(far.count, 4)
        XCTAssertTrue(far.allSatisfy { $0.endDate > $0.startDate })
    }

    func testRECURRULE_SkippedDayIsAbsent() {
        let series = standup(skipped: [20261109])
        let starts = series.occurrences(in: month(2026, 11)).map(\.startDate)
        XCTAssertEqual(starts, [at(2026, 11, 2, 9), at(2026, 11, 16, 9), at(2026, 11, 23, 9), at(2026, 11, 30, 9)])
    }

    func testRECURRULE_OccurrenceCrossingMidnightIsReturnedForBothDays() {
        var series = standup()
        series.startMinute = 23 * 60
        series.endMinute = 60
        series.endDayDistance = 1
        let tuesday = DateInterval(start: at(2026, 11, 3), end: at(2026, 11, 4))
        let monday = DateInterval(start: at(2026, 11, 2), end: at(2026, 11, 3))

        let onTuesday = series.occurrences(in: tuesday)
        XCTAssertEqual(onTuesday.map(\.startDate), [at(2026, 11, 2, 23)], "the Monday night occurrence ends Tuesday 01:00")
        XCTAssertEqual(onTuesday.map(\.endDate), [at(2026, 11, 3, 1)])
        let onMonday = series.occurrences(in: monday)
        XCTAssertEqual(onMonday.map(\.startDate), [at(2026, 11, 2, 23)])
        XCTAssertEqual(onMonday.map(\.id), onTuesday.map(\.id), "one occurrence, one id, on both days")
        XCTAssertTrue(series.occurrences(in: DateInterval(start: at(2026, 11, 4), end: at(2026, 11, 5))).isEmpty)
    }

    func testRECURRULE_LastDayIsInclusive() {
        let series = standup(last: 20261116)
        let lastDay = DateInterval(start: at(2026, 11, 16), end: at(2026, 11, 17))
        XCTAssertEqual(series.occurrences(in: lastDay).map(\.startDate), [at(2026, 11, 16, 9)])
        XCTAssertTrue(series.occurrences(in: DateInterval(start: at(2026, 11, 17), end: at(2026, 11, 24))).isEmpty)
        // A last day that is not an occurrence day still ends the series after the last occurrence before it.
        let sunday = standup(last: 20261122)
        XCTAssertEqual(sunday.occurrences(in: month(2026, 11)).map(\.startDate),
                       [at(2026, 11, 2, 9), at(2026, 11, 9, 9), at(2026, 11, 16, 9)])
    }

    func testRECURRULE_PastOccurrencesAreDrawn() {
        let store = EmptyStore.make()
        store.replanNow = { self.at(2027, 1, 1, 8) }
        let series = standup()
        XCTAssertEqual(series.occurrences(in: month(2026, 11)).count, 5, "a rule has no creation time: past days are drawn")
        XCTAssertTrue(store.addSeries(series))
        XCTAssertEqual(store.activities(in: month(2026, 11)).count, 5)
    }

    // MARK: AC-007 - ids

    func testRECURRULE_OccurrenceIdRoundTrip() {
        let store = EmptyStore.make()
        let series = standup()
        XCTAssertEqual(Array(idBytes(series.id)[12...15]), [0, 0, 0, 0], "a series id has a zero tail")

        let id = series.occurrenceID(dayKey: 20261109)
        XCTAssertEqual(Array(idBytes(id)[12...15]), tailBytes(20261109))
        XCTAssertEqual(Array(idBytes(id)[0...11]), Array(idBytes(series.id)[0...11]))
        XCTAssertEqual(RepeatSeries.decode(id)?.dayKey, 20261109)
        XCTAssertEqual(RepeatSeries.decode(id)?.prefix, Array(idBytes(series.id)[0...11]))

        XCTAssertTrue(store.addSeries(series))
        let found = store.series(forOccurrence: id)
        XCTAssertEqual(found?.0.id, series.id)
        XCTAssertEqual(found?.dayKey, 20261109)
    }

    func testRECURRULE_IdStableAcrossCalls() {
        let store = EmptyStore.make()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let first = series.occurrences(in: month(2026, 11)).map(\.id)
        let second = series.occurrences(in: month(2026, 11)).map(\.id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first).count, first.count, "distinct days give distinct ids")

        let after = relaunched()
        XCTAssertEqual(after.series.first?.occurrences(in: month(2026, 11)).map(\.id), first, "the same ids after a relaunch")
        for id in first { XCTAssertEqual(UUID(uuidString: id.uuidString), id) }
    }

    func testRECURRULE_LegacyUUIDDoesNotResolveToASeries() {
        let store = EmptyStore.make()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let stored = ActivityBlock(title: "Stored", location: nil, startDate: at(2026, 11, 3, 9), endDate: at(2026, 11, 3, 10))
        store.activities.append(stored)

        XCTAssertNil(store.series(forOccurrence: UUID()), "a random UUID")
        XCTAssertNil(store.series(forOccurrence: stored.id), "the id of a stored activity")
        XCTAssertNil(store.series(forOccurrence: UUID()), "a leg id")
        let other = standup()
        XCTAssertNil(store.series(forOccurrence: other.occurrenceID(dayKey: 20261109)), "a series that does not exist")
        XCTAssertNil(store.series(forOccurrence: series.id), "the series id itself has no day")
        XCTAssertNil(store.series(forOccurrence: series.occurrenceID(dayKey: 20261399)), "invalid month 13")
        XCTAssertNil(store.series(forOccurrence: series.occurrenceID(dayKey: 20261100)), "day 0")
        XCTAssertNil(store.series(forOccurrence: series.occurrenceID(dayKey: 20260000)), "month 0 and day 0")
        XCTAssertNil(store.series(forOccurrence: series.occurrenceID(dayKey: 20261026)), "a day before the first day")

        let ended = standup(last: 20261130)
        XCTAssertTrue(store.addSeries(ended))
        XCTAssertNil(store.series(forOccurrence: ended.occurrenceID(dayKey: 20261207)), "a day after the last day")
        XCTAssertNotNil(store.series(forOccurrence: ended.occurrenceID(dayKey: 20261130)), "the last day itself")
    }

    func testRECURRULE_IdSurvivesJSONString() throws {
        let store = EmptyStore.make()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let id = series.occurrenceID(dayKey: 20261116)

        let wire = try JSONSerialization.data(withJSONObject: ["id": id.uuidString])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: String])
        let parsed = try XCTUnwrap(object["id"].flatMap { UUID(uuidString: $0) })
        XCTAssertEqual(parsed, id)
        XCTAssertEqual(store.series(forOccurrence: parsed)?.dayKey, 20261116)
        let block = store.activity(id: parsed)
        XCTAssertEqual(block?.id, id)
        XCTAssertEqual(block?.startDate, at(2026, 11, 16, 9))
        XCTAssertEqual(block?.recurrenceId, series.id)
    }

    func testRECURRULE_NonOccurrenceDayIsNotResolved() throws {
        let store = EmptyStore.make()
        let series = standup(skipped: [20261123])
        XCTAssertTrue(store.addSeries(series))

        // A valid Tuesday of a Monday rule: the series is found, the day is not an occurrence.
        let tuesday = series.occurrenceID(dayKey: 20261110)
        XCTAssertEqual(store.series(forOccurrence: tuesday)?.0.id, series.id)
        XCTAssertEqual(store.series(forOccurrence: tuesday)?.dayKey, 20261110)
        XCTAssertNil(store.activity(id: tuesday))

        // A skipped Monday: found by the first step, refused by the resolver.
        let skipped = series.occurrenceID(dayKey: 20261123)
        XCTAssertNotNil(store.series(forOccurrence: skipped))
        XCTAssertNil(store.activity(id: skipped))

        // A live Monday resolves, and a stored activity with that id wins over the computed one.
        let monday = series.occurrenceID(dayKey: 20261116)
        XCTAssertEqual(store.activity(id: monday)?.title, "Standup")
        var copy = try XCTUnwrap(store.activity(id: monday))
        copy.title = "Stored copy"
        copy.recurrenceId = nil
        store.activities.append(copy)
        XCTAssertEqual(store.activity(id: monday)?.title, "Stored copy")
    }

    // MARK: AC-014 row 8 - repair on load

    func testRECURRULE_RepairOnLoadAddsTheSkippedDay() throws {
        // The crash state of a materialize: the stored copy was saved, `series.json` was not.
        _ = EmptyStore.make()
        let series = standup()
        let copy = ActivityBlock(id: series.occurrenceID(dayKey: 20261109), title: "Standup (moved)", location: office,
                                 startDate: at(2026, 11, 9, 10), endDate: at(2026, 11, 9, 10, 30), recurrenceId: nil)
        let unrelated = ActivityBlock(title: "Dentist", location: nil, startDate: at(2026, 11, 9, 14), endDate: at(2026, 11, 9, 15))
        try write(JSONEncoder().encode([series]), "series.json")
        try write(JSONEncoder().encode([copy, unrelated]), "activities.json")

        let store = relaunched()
        XCTAssertEqual(store.series.first?.skippedDayKeys, [20261109], "only the day of the stored occurrence is added")
        let onDisk = try JSONDecoder().decode([RepeatSeries].self, from: XCTUnwrap(bytes("series.json")))
        XCTAssertEqual(onDisk.first?.skippedDayKeys, [20261109], "the repair is saved")

        // Deleting the stored copy afterwards must not bring the computed occurrence back.
        store.deleteActivity(copy)
        let november = store.activities(in: month(2026, 11))
        XCTAssertEqual(november.filter { $0.title.hasPrefix("Standup") }.count, 4)
        XCTAssertFalse(november.contains { $0.startDate == at(2026, 11, 9, 9) })
    }

    // MARK: AC-001 rows 1-2 - one record, no copies

    func testRECURRULE_SaveMakesOneSeriesAndNoCopies() async throws {
        let store = fixtureStore()
        var f = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30), place: office)
        commit(&f, "every Monday")
        XCTAssertTrue(f.card.isReady)
        XCTAssertNotNil(f.activeRecurrence)

        let saved = await store.saveManualActivity(f, calendarDefault: false)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.series.count, 1)
        XCTAssertEqual(store.activities.count, 0, "no stored copy per occurrence")
        XCTAssertEqual(store.events.count, 0, "no stored leg per occurrence")
        let series = try XCTUnwrap(store.series.first)
        XCTAssertEqual(series.title, "Standup")
        XCTAssertEqual(series.location?.name, "Office")
        XCTAssertEqual(series.rule.unit, .weekly)
        XCTAssertEqual(series.rule.weekdays, [2])
        XCTAssertNil(series.lastDayKey)
        XCTAssertEqual(series.firstDayKey, 20261102)
        XCTAssertEqual(series.startMinute, 540)
        XCTAssertEqual(series.endMinute, 570)
        XCTAssertEqual(series.endDayDistance, 0)
        XCTAssertNil(series.lunarCalendar)
        XCTAssertNil(series.legPlan, "the travel toggles are off")
        XCTAssertEqual(standups(in: store, month(2026, 11)).count, 5, "the occurrences are drawn from the rule")

        let reloaded = relaunched()
        XCTAssertEqual(reloaded.series.map { $0.id }, [series.id], "the series reached series.json")

        // The same form with the Repeat row empty is the one-time branch: one stored activity and no series.
        let once = fixtureStore()
        let plain = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30), place: office)
        let savedOnce = await once.saveManualActivity(plain, calendarDefault: false)
        XCTAssertTrue(savedOnce)
        XCTAssertEqual(once.series.count, 0)
        XCTAssertEqual(once.activities.count, 1)
        XCTAssertEqual(once.activities.first?.title, "Standup")
        XCTAssertEqual(once.activities.first?.startDate, at(2026, 11, 2, 9))
        XCTAssertEqual(once.activities.first?.endDate, at(2026, 11, 2, 9, 30))
        XCTAssertNil(once.activities.first?.recurrenceId)
    }

    // MARK: AC-004 row 3 - a series file that cannot be backed up

    func testRECURRULE_SaveRefusedWhenSeriesFileCannotBeBackedUp() async throws {
        _ = EmptyStore.make()
        try write(Data("bad".utf8), "series.json")
        for n in 1...9 {
            try write(Data("old \(n)".utf8), n == 1 ? "series.unreadable.json" : "series.unreadable-\(n).json")
        }
        let store = relaunched()
        let clock = fixtureClock
        store.replanNow = { clock }
        XCTAssertTrue(store.seriesLoadFailed)

        var f = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30), place: office)
        commit(&f, "every Monday until Nov 30")
        XCTAssertTrue(f.card.isReady)
        XCTAssertNotNil(f.activeRecurrence)

        let saved = await store.saveManualActivity(f, calendarDefault: false)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.series.count, 0, "nothing is left in memory")
        XCTAssertEqual(store.activities.count, 0)
        XCTAssertEqual(store.events.count, 0)
        XCTAssertEqual(bytes("series.json"), Data("bad".utf8), "the unreadable file is not written over")
        XCTAssertTrue(store.seriesLoadFailed)
    }

    // MARK: AC-008 - the lock and the cap are gone

    func testRECURRULE_NoEndRepeatHasNoNoteAndAddIsLive() {
        var f = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&f, "every Monday")
        XCTAssertNil(RecurrenceLine.problem(rule: f.recurrence.rule, endDate: f.recurrence.endDate, start: f.startDate))
        XCTAssertNil(note(f))
        XCTAssertTrue(f.card.isReady)
        guard let active = f.activeRecurrence else { return XCTFail("a repeat with no end is not active") }
        XCTAssertNil(active.endDate)
        XCTAssertEqual(active.rule.unit, .weekly)

        // The missing items of a rule never include an end date.
        let weekly = RecurrenceRule(weekdays: [2], unit: .weekly)
        XCTAssertEqual(RecurrenceLine.missingItems(rule: weekly, endDate: nil), [])
        let noWeekday = RecurrenceRule(weekdays: [], unit: .weekly)
        XCTAssertEqual(RecurrenceLine.missingItems(rule: noWeekday, endDate: nil), [RecurrenceLine.missingWeekdays])

        // An end well past the old count of 182 passes too.
        var daily = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&daily, "daily until 12/31/2027")
        XCTAssertNil(note(daily))
        XCTAssertNotNil(daily.activeRecurrence)
    }

    func testRECURRULE_EndBeyondHorizonIsTooFar() {
        var f = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&f, "every Monday until 1/1/9999")
        XCTAssertEqual(note(f), "End date is too far away")
        XCTAssertNil(f.activeRecurrence)

        // The boundary is the horizon counted from the start day: the last day is accepted, the next one is not.
        let rule = RecurrenceRule(weekdays: [2], unit: .weekly)
        let startDay = cal.startOfDay(for: at(2026, 11, 2, 9))
        let horizon = cal.date(byAdding: .year, value: RecurrenceRule.horizonYears, to: startDay)!
        XCTAssertNil(RecurrenceLine.problem(rule: rule, endDate: horizon, start: at(2026, 11, 2, 9)))
        let dayAfter = cal.date(byAdding: .day, value: 1, to: horizon)!
        XCTAssertEqual(RecurrenceLine.problem(rule: rule, endDate: dayAfter, start: at(2026, 11, 2, 9)), "End date is too far away")
    }

    func testRECURRULE_NoMatchingDatesStillNoted() {
        var before = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&before, "every Monday until 11/1/2026")
        XCTAssertEqual(note(before), "No matching dates")
        XCTAssertNil(before.activeRecurrence)

        // A rule with no occurrence inside the horizon and no end: Feb 30 never happens.
        var never = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        never.seedRecurrence(text: "every year on Feb 30",
                             arguments: [RecurrenceRule.Arg.unit: "year", RecurrenceRule.Arg.month: 2, RecurrenceRule.Arg.day: 30],
                             endDate: nil)
        XCTAssertEqual(note(never), "No matching dates")
        XCTAssertNil(never.activeRecurrence)

        // Positive control: Feb 28 happens, so the same shape of rule has no note.
        var feb28 = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        feb28.seedRecurrence(text: "every year on Feb 28",
                             arguments: [RecurrenceRule.Arg.unit: "year", RecurrenceRule.Arg.month: 2, RecurrenceRule.Arg.day: 28],
                             endDate: nil)
        XCTAssertNil(note(feb28))
        XCTAssertNotNil(feb28.activeRecurrence)
    }

    func testRECURRULE_TextWithUntilStillSetsTheEnd() async {
        var four = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&four, "every Monday for 4 weeks")
        XCTAssertEqual(four.activeRecurrence?.endDate, cal.startOfDay(for: at(2026, 11, 29)))
        let store = fixtureStore()
        let saved = await store.saveManualActivity(four, calendarDefault: false)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.series.first?.lastDayKey, 20261129)
        let weeks = standups(in: store, DateInterval(start: at(2026, 11, 1), end: at(2027, 1, 1)))
        XCTAssertEqual(weeks.map { $0.startDate }, [at(2026, 11, 2, 9), at(2026, 11, 9, 9), at(2026, 11, 16, 9), at(2026, 11, 23, 9)],
                       "the last occurrence is Monday Nov 23")

        let until = fixtureStore()
        var upTo = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&upTo, "every Monday until Nov 30")
        let savedUntil = await until.saveManualActivity(upTo, calendarDefault: false)
        XCTAssertTrue(savedUntil)
        XCTAssertEqual(until.series.first?.lastDayKey, 20261130)
        XCTAssertEqual(standups(in: until, DateInterval(start: at(2026, 11, 1), end: at(2027, 1, 1))).count, 5)
    }

    // MARK: AC-009 - save

    func testRECURRULE_SaveOfPastOnlyRepeatMakesNothing() async {
        let store = EmptyStore.make()
        let late = at(2027, 1, 1, 8)
        store.replanNow = { late }
        var f = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&f, "every Monday until 11/16/2026")
        XCTAssertNil(note(f))
        XCTAssertNotNil(f.activeRecurrence)
        XCTAssertTrue(f.card.isReady)

        let saved = await store.saveManualActivity(f, calendarDefault: false)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.series.count, 0)
        XCTAssertEqual(store.activities.count, 0)
        XCTAssertEqual(store.events.count, 0)
        XCTAssertTrue(f.hasNoUpcomingOccurrence(now: late))
        // Control: at the fixture clock the same form has upcoming occurrences.
        XCTAssertFalse(f.hasNoUpcomingOccurrence(now: fixtureClock))
    }

    func testRECURRULE_SaveRefusesOver24Hours() async throws {
        // Start 09:00, end the next day 09:30 (24.5 hours): refused, nothing made.
        var long = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&long, "every Monday")
        setEnd(&long, at(2026, 11, 3, 9, 30))
        XCTAssertTrue(long.card.isReady)
        XCTAssertNotNil(long.activeRecurrence)
        let longStore = fixtureStore()
        let longSaved = await longStore.saveManualActivity(long, calendarDefault: false)
        XCTAssertFalse(longSaved)
        XCTAssertEqual(longStore.series.count, 0)
        XCTAssertEqual(longStore.activities.count, 0)

        // End equal to start: refused.
        var same = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&same, "every Monday")
        setEnd(&same, at(2026, 11, 2, 9))
        XCTAssertTrue(same.card.isReady)
        XCTAssertNotNil(same.activeRecurrence)
        let sameStore = fixtureStore()
        let sameSaved = await sameStore.saveManualActivity(same, calendarDefault: false)
        XCTAssertFalse(sameSaved)
        XCTAssertEqual(sameStore.series.count, 0)

        // Start 23:00, end 01:00 the next day: saved, and the end falls on the next day.
        var night = makeForm(start: at(2026, 11, 2, 23), end: at(2026, 11, 3, 1))
        commit(&night, "every Monday")
        XCTAssertNotNil(night.activeRecurrence)
        let nightStore = fixtureStore()
        let nightSaved = await nightStore.saveManualActivity(night, calendarDefault: false)
        XCTAssertTrue(nightSaved)
        let series = try XCTUnwrap(nightStore.series.first)
        XCTAssertEqual(series.endDayDistance, 1)
        XCTAssertEqual(series.startMinute, 23 * 60)
        XCTAssertEqual(series.endMinute, 60)
    }

    func testRECURRULE_SaveDayThreeYearsLaterIsDrawn() async {
        let store = fixtureStore()
        var f = makeForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&f, "daily")
        XCTAssertNotNil(f.activeRecurrence)
        let saved = await store.saveManualActivity(f, calendarDefault: false)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.series.count, 1)
        XCTAssertEqual(store.activities.count, 0, "no occurrence was precomputed")
        XCTAssertEqual(store.events.count, 0)

        let day = DateInterval(start: at(2029, 3, 14), end: at(2029, 3, 15))
        let drawn = standups(in: store, day)
        XCTAssertEqual(drawn.count, 1)
        XCTAssertEqual(drawn.first?.startDate, at(2029, 3, 14, 9))
        XCTAssertEqual(store.activities(on: at(2029, 3, 14)).filter { $0.title == "Standup" }.count, 1)
    }

    // MARK: AC-010 - drawing (M4a: the screens call the Store members these tests read)

    private func stored(_ title: String, _ start: Date, _ end: Date, place: Place? = nil) -> ActivityBlock {
        ActivityBlock(title: title, location: place, startDate: start, endDate: end)
    }

    /// Weekly on one weekday (Calendar numbering, Sunday = 1) from a first day, optionally to a last day.
    private func weekly(_ title: String, weekday: Int, startMinute: Int, endMinute: Int, endDayDistance: Int = 0,
                        first: Int, last: Int? = nil, place: Place? = nil) -> RepeatSeries {
        RepeatSeries(id: RepeatSeries.newID(), title: title, location: place,
                     rule: RecurrenceRule(weekdays: [weekday], unit: .weekly), lunarCalendar: nil,
                     firstDayKey: first, lastDayKey: last, startMinute: startMinute, endMinute: endMinute,
                     endDayDistance: endDayDistance, syncToCalendar: nil, skippedDayKeys: [],
                     legPlan: nil, legsFilledThroughDayKey: nil)
    }

    private func leg(for activityId: UUID, at date: Date) -> ScheduledEvent {
        var leg = ScheduledEvent(title: "Leg", destination: office, arrivalDate: date, mode: .car, bufferMinutes: 5,
                                 notifyLeadMinutes: 10)
        leg.linkedActivityId = activityId
        return leg
    }

    func testRECURRULE_DayListShowsSeriesYearsAhead() {
        let store = fixtureStore()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        store.activities.append(stored("Lunch", at(2029, 3, 12, 12), at(2029, 3, 12, 13)))
        store.activities.append(stored("Early", at(2029, 3, 12, 8), at(2029, 3, 12, 8, 30)))

        // Row 1: 2029-03-12 is a Monday 2.4 years after the first day; stored blocks are mixed in, sorted by start.
        let monday = store.activities(on: at(2029, 3, 12))
        XCTAssertEqual(monday.map(\.title), ["Early", "Standup", "Lunch"])
        XCTAssertEqual(monday.dropFirst().first?.startDate, at(2029, 3, 12, 9))
        XCTAssertEqual(monday.dropFirst().first?.recurrenceId, series.id)
        // A Tuesday has no Standup and nothing else.
        XCTAssertEqual(store.activities(on: at(2029, 3, 13)).count, 0)
        // The interval read agrees: four Mondays in March 2029, and the stored blocks are in it too.
        let inMonth = store.activities(in: month(2029, 3))
        XCTAssertEqual(inMonth.filter { $0.title == "Standup" }.count, 4)
        XCTAssertEqual(inMonth.count, 6)
    }

    func testRECURRULE_MonthDotsAndTitlesFromSeries() {
        let store = fixtureStore()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let mondays: Set<Int> = [5, 12, 19, 26]
        for d in 1...31 {
            let day = at(2029, 3, d)
            // Row 2: a dot and one title on every Monday, neither on the other days.
            XCTAssertEqual(store.hasSchedule(on: day), mondays.contains(d), "dot on March \(d)")
            let titles = store.scheduleTitles(on: day)
            if mondays.contains(d) {
                XCTAssertEqual(titles.count, 1, "titles on March \(d)")
                XCTAssertEqual(titles.first?.title, "Standup")
                XCTAssertEqual(titles.first?.id, series.occurrenceID(dayKey: 20290300 + d))
            } else {
                XCTAssertTrue(titles.isEmpty, "titles on March \(d)")
            }
            // Row 3: the list, the dot and the titles say the same thing about the day.
            XCTAssertEqual(!store.activities(on: day).isEmpty, store.hasSchedule(on: day), "agree on March \(d)")
            XCTAssertEqual(!store.activities(on: day).isEmpty, !titles.isEmpty, "agree with titles on March \(d)")
        }

        // Row 3, second half: a 23:00-01:00 series also marks the day after each occurrence, even across a month end.
        let nightStore = fixtureStore()
        XCTAssertTrue(nightStore.addSeries(weekly("Night", weekday: 2, startMinute: 23 * 60, endMinute: 60, endDayDistance: 1,
                                                   first: 20261102)))
        var expected = Set<Int>()
        for monday in mondays { expected.insert(monday); expected.insert(monday + 1) }
        for d in 1...31 {
            let day = at(2029, 3, d)
            XCTAssertEqual(nightStore.hasSchedule(on: day), expected.contains(d), "night dot on March \(d)")
            XCTAssertEqual(!nightStore.activities(on: day).isEmpty, nightStore.hasSchedule(on: day), "night agree on March \(d)")
        }
        // 2029-04-30 is a Monday: its night spills into May 1, which belongs to the next month's cache entry.
        XCTAssertTrue(nightStore.hasSchedule(on: at(2029, 4, 30)))
        XCTAssertTrue(nightStore.hasSchedule(on: at(2029, 5, 1)))
        XCTAssertFalse(nightStore.hasSchedule(on: at(2029, 5, 2)))
        XCTAssertEqual(nightStore.scheduleTitles(on: at(2029, 5, 1)).map(\.title), ["Night"])
    }

    func testRECURRULE_CacheClearsWhenSeriesChanges() {
        let store = fixtureStore()
        XCTAssertTrue(store.addSeries(standup()))
        let before = RecurrenceRule.drvExpansionCount
        XCTAssertTrue(store.hasSchedule(on: at(2029, 3, 5)))
        let built = RecurrenceRule.drvExpansionCount
        // Positive control: the first read of the month expands the rule, so the counter is seen to move.
        XCTAssertGreaterThan(built, before)

        // Any other read of that month, of either cached function, is served from the cache.
        for d in 1...31 {
            _ = store.hasSchedule(on: at(2029, 3, d))
            _ = store.scheduleTitles(on: at(2029, 3, d))
        }
        XCTAssertEqual(RecurrenceRule.drvExpansionCount, built, "a cached month is not expanded again")

        // A change of the series list clears the cache: the next read expands again and shows the new series.
        XCTAssertFalse(store.hasSchedule(on: at(2029, 3, 7)))
        XCTAssertTrue(store.addSeries(weekly("Gym", weekday: 4, startMinute: 18 * 60, endMinute: 19 * 60, first: 20261104)))
        let afterChange = RecurrenceRule.drvExpansionCount
        XCTAssertTrue(store.hasSchedule(on: at(2029, 3, 7)))
        XCTAssertGreaterThan(RecurrenceRule.drvExpansionCount, afterChange, "the cleared cache is rebuilt")
        XCTAssertEqual(store.scheduleTitles(on: at(2029, 3, 7)).map(\.title), ["Gym"])
        // The skipped-day variant of this change belongs to M4b, where the store gets the writer that skips a day
        // (AC-013); this milestone has no store call that changes `skippedDayKeys`.
    }

    func testRECURRULE_ActivitiesDidSetDoesNotExpandSeries() {
        let store = fixtureStore()
        XCTAssertTrue(store.addSeries(standup()))
        let c0 = RecurrenceRule.drvExpansionCount
        XCTAssertTrue(store.hasSchedule(on: at(2029, 3, 5)))
        let c1 = RecurrenceRule.drvExpansionCount
        XCTAssertGreaterThan(c1, c0, "positive control: the counter moves when the month is read")

        // Each append and each removal runs the `didSet` of `activities`; none of them may expand the rule.
        for i in 0..<100 {
            let start = at(2027, 1, 1, 9).addingTimeInterval(Double(i) * 86400)
            store.activities.append(stored("Stored \(i)", start, start.addingTimeInterval(1800)))
        }
        XCTAssertEqual(RecurrenceRule.drvExpansionCount, c1, "100 stored appends did not expand the series")
        store.events.append(leg(for: UUID(), at: at(2027, 1, 1, 9)))
        XCTAssertEqual(RecurrenceRule.drvExpansionCount, c1, "an events change did not expand the series")
        store.activities.removeAll()
        XCTAssertEqual(RecurrenceRule.drvExpansionCount, c1, "a removal did not expand the series")
        // The month entry survived all of it.
        XCTAssertTrue(store.hasSchedule(on: at(2029, 3, 12)))
        XCTAssertEqual(RecurrenceRule.drvExpansionCount, c1)
    }

    func testRECURRULE_StoredWinsOverComputedWithSameId() {
        let store = fixtureStore()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        // The state after a crash between the two saves of a materialize: the copy is stored and Nov 9 is not skipped yet.
        var copy = stored("Standup moved", at(2026, 11, 9, 10), at(2026, 11, 9, 10, 30), place: office)
        copy.id = series.occurrenceID(dayKey: 20261109)
        copy.recurrenceId = series.id
        store.activities.append(copy)

        let day = store.activities(on: at(2026, 11, 9))
        XCTAssertEqual(day.count, 1)
        XCTAssertEqual(day.first?.title, "Standup moved")
        XCTAssertEqual(day.first?.startDate, at(2026, 11, 9, 10))
        let interval = store.activities(in: month(2026, 11)).filter { $0.id == copy.id }
        XCTAssertEqual(interval.count, 1)
        XCTAssertEqual(interval.first?.title, "Standup moved")
        let titles = store.scheduleTitles(on: at(2026, 11, 9))
        XCTAssertEqual(titles.count, 1, "the title appears once")
        XCTAssertEqual(titles.first?.title, "Standup moved")
        XCTAssertTrue(store.hasSchedule(on: at(2026, 11, 9)))
        // The neighbouring Mondays are still computed.
        XCTAssertEqual(store.activities(on: at(2026, 11, 16)).map(\.title), ["Standup"])
    }

    func testRECURRULE_TimeZoneChangeRebuildsTheMonthCache() {
        let store = fixtureStore()
        XCTAssertTrue(store.addSeries(standup()))
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let noon = DateComponents(year: 2029, month: 3, day: 5, hour: 12)

        let c0 = RecurrenceRule.drvExpansionCount
        XCTAssertTrue(store.hasSchedule(on: seoul.date(from: noon)!, calendar: seoul))
        let c1 = RecurrenceRule.drvExpansionCount
        XCTAssertGreaterThan(c1, c0, "positive control")
        XCTAssertTrue(store.hasSchedule(on: seoul.date(from: noon)!, calendar: seoul))
        XCTAssertEqual(RecurrenceRule.drvExpansionCount, c1, "same zone: served from the cache")

        // The zone changes between two reads of the same month: the entry is rebuilt, with the day keys of the new zone.
        XCTAssertTrue(store.hasSchedule(on: la.date(from: noon)!, calendar: la))
        let c2 = RecurrenceRule.drvExpansionCount
        XCTAssertGreaterThan(c2, c1, "a new zone rebuilds the month")
        XCTAssertFalse(store.hasSchedule(on: la.date(from: DateComponents(year: 2029, month: 3, day: 6, hour: 12))!, calendar: la))
        XCTAssertEqual(store.scheduleTitles(on: la.date(from: noon)!, calendar: la).count, 1)
        XCTAssertEqual(RecurrenceRule.drvExpansionCount, c2, "the second read in the new zone is cached")
    }

    // MARK: AC-011 - the other readers

    /// The tool tests spell their dates in the zone of `TestClock`; the Store reads follow the zone of the device, so a
    /// test that mixes them puts both in one zone (restored by `tearDown`).
    private func useToolZone() { NSTimeZone.default = TestClock.zone }

    func testRECURRULE_AgentListResolveUpdateDeleteByOccurrenceId() throws {
        useToolZone()
        let h = ToolHarness.make()
        let series = standup()
        XCTAssertTrue(h.store.addSeries(series))

        // Row 1: a 28-day window two years ahead lists the four Monday occurrences.
        let list = h.call("list_activities", ["from": "2028-11-06T00:00", "to": "2028-12-04T00:00"])
        let items = (list.json?["items"] as? [[String: Any]]) ?? []
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.map { $0["start"] as? String },
                       ["2028-11-06T09:00", "2028-11-13T09:00", "2028-11-20T09:00", "2028-11-27T09:00"])
        XCTAssertEqual(items.map { $0["title"] as? String }, Array(repeating: "Standup", count: 4))
        XCTAssertEqual(items.map { $0["recurring"] as? Bool }, Array(repeating: true, count: 4))
        XCTAssertEqual(list.json?["truncated"] as? Bool, false)

        // The id string round-trips: it parses, it is the occurrence id, and it resolves again to the same block.
        let text = try XCTUnwrap(items.first?["id"] as? String)
        let id = try XCTUnwrap(UUID(uuidString: text))
        XCTAssertEqual(id, series.occurrenceID(dayKey: 20281106))
        let resolved = try XCTUnwrap(h.store.activity(id: id))
        XCTAssertEqual(resolved.title, "Standup")
        XCTAssertEqual(resolved.startDate, TestClock.date("2028-11-06T09:00"))
        XCTAssertEqual(resolved.endDate, TestClock.date("2028-11-06T09:30"))
        // The same call twice gives equal ids.
        let again = h.call("list_activities", ["from": "2028-11-06T00:00", "to": "2028-12-04T00:00"])
        XCTAssertEqual((again.json?["items"] as? [[String: Any]])?.map { $0["id"] as? String }, items.map { $0["id"] as? String })

        // The limits keep their text: a window over 31 days is refused with the unchanged message.
        let tooLong = h.call("list_activities", ["from": "2028-11-06T00:00", "to": "2028-12-08T00:00"])
        XCTAssertEqual(tooLong.message, ToolText.listInvalid)
        // The 50-item cut counts occurrences: a daily series (30 days), the Mondays and 30 stored blocks make more than 50, and 50 are returned.
        let daily = RepeatSeries(id: RepeatSeries.newID(), title: "Daily", location: nil,
                                 rule: RecurrenceRule(weekdays: [], unit: .daily), lunarCalendar: nil,
                                 firstDayKey: 20281101, lastDayKey: nil, startMinute: 600, endMinute: 630,
                                 endDayDistance: 0, syncToCalendar: nil, skippedDayKeys: [], legPlan: nil,
                                 legsFilledThroughDayKey: nil)
        XCTAssertTrue(h.store.addSeries(daily))
        for i in 0..<30 {
            let start = TestClock.date("2028-11-10T12:00").addingTimeInterval(Double(i) * 600)
            h.store.activities.append(stored("Stored \(i)", start, start.addingTimeInterval(300)))
        }
        let cut = h.call("list_activities", ["from": "2028-11-01T00:00", "to": "2028-12-01T00:00"])
        XCTAssertEqual(cut.json?["count"] as? Int, 50)
        XCTAssertEqual(cut.json?["truncated"] as? Bool, true)

        // Row 2, the read half: the id resolves through the tool to the occurrence, and the cards show it.
        let update = h.call("update_activity", ["id": text, "title": "Renamed"])
        let updateCard = try XCTUnwrap(update.card)
        XCTAssertEqual(updateCard.lines.first, "Change event")
        XCTAssertTrue(updateCard.lines.contains("Was: Standup"))
        XCTAssertTrue(updateCard.lines.contains("Only this occurrence of a repeating event."))
        let delete = h.call("delete_activity", ["id": text])
        let deleteCard = try XCTUnwrap(delete.card)
        XCTAssertEqual(deleteCard.lines.first, "Delete event")
        XCTAssertTrue(deleteCard.lines.contains("Standup"))
        // A random UUID, and a day of the series that is not an occurrence (a Tuesday), are not found.
        XCTAssertEqual(h.call("update_activity", ["id": UUID().uuidString, "title": "x"]).message, ToolText.findID("update_activity"))
        let tuesday = series.occurrenceID(dayKey: 20281107)
        XCTAssertEqual(h.call("delete_activity", ["id": tuesday.uuidString]).message, ToolText.findID("delete_activity"))
        // Nothing was written by the read calls.
        XCTAssertEqual(h.store.series.first { $0.id == series.id }?.skippedDayKeys, [])
        // The confirmed update and delete (one stored copy and `Only this occurrence...` after confirm; the skipped day
        // and `applied` after confirm) need `materialize` and the skip writer: they are asserted in M4b (AC-013, AC-014).
    }

    func testRECURRULE_DayPlanSignatureStable() async throws {
        useToolZone()
        func stops() -> String {
            let stop: [String: Any] = ["title": "Dinner", "start": "2026-10-27T18:00", "end": "2026-10-27T19:00"]
            let data = (try? JSONSerialization.data(withJSONObject: [stop], options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        /// A rig in a plan turn on Tuesday 2026-10-27 09:00 with a Tuesday 10:00 series, and the card of one checked stop.
        func card(_ rig: PlaceRig) async throws -> AgentCard {
            let dayEnd = TestClock.date("2026-10-28T00:00")
            rig.tools.beginDayPlan(DayPlanContext(mode: .car, events: [], checkWindowEnd: dayEnd))
            let checked = await rig.run("check_day_plan", ["stops": stops()])
            XCTAssertEqual(checked.status, "ok")
            let shown = await rig.run("show_day_plan", ["plan_id": "d1"])
            return try XCTUnwrap(shown.card, shown.text ?? "no card")
        }
        let tuesday = weekly("Tuesday call", weekday: 3, startMinute: 600, endMinute: 660, first: 20261027)

        // The series is unchanged between the check and Confirm: the signatures are equal, the plan is applied.
        let steady = PlaceRig()
        XCTAssertTrue(steady.store.addSeries(tuesday))
        let steadyCard = try await card(steady)
        let steadyResult = await steadyCard.resolve(.confirm)
        XCTAssertEqual(steadyResult?.status, "applied")

        // The series gains another occurrence in the window after the check: the signature differs, the plan is stale.
        // (A skipped day is the other change; the skip writer is M4b, so its stale assertion is written there.)
        let changed = PlaceRig()
        XCTAssertTrue(changed.store.addSeries(tuesday))
        let changedCard = try await card(changed)
        XCTAssertTrue(changed.store.addSeries(weekly("Second", weekday: 3, startMinute: 720, endMinute: 780, first: 20261027)))
        let changedResult = await changedCard.resolve(.confirm)
        XCTAssertEqual(changedResult?.status, "stale")
        XCTAssertEqual(changedResult?.message, AgentDayPlan.Say.scheduleChanged)

        // Outside the window nothing counts: a series whose first day is after the window leaves the plan applied.
        let outside = PlaceRig()
        XCTAssertTrue(outside.store.addSeries(tuesday))
        let outsideCard = try await card(outside)
        XCTAssertTrue(outside.store.addSeries(weekly("Later", weekday: 3, startMinute: 720, endMinute: 780, first: 20261103)))
        let outsideResult = await outsideCard.resolve(.confirm)
        XCTAssertEqual(outsideResult?.status, "applied")
    }

    func testRECURRULE_PlanMyDayCountsTodaysOccurrence() {
        let store = fixtureStore()
        // Today is Monday 2026-11-02 08:00 on the fixture clock. Standup is today 09:00; a Tuesday series is tomorrow; a
        // Wednesday series is the day after tomorrow and is not planned.
        XCTAssertTrue(store.addSeries(standup()))
        XCTAssertTrue(store.addSeries(weekly("Tomorrow", weekday: 3, startMinute: 600, endMinute: 660, first: 20261103)))
        XCTAssertTrue(store.addSeries(weekly("Later", weekday: 4, startMinute: 600, endMinute: 660, first: 20261104)))
        store.activities.append(stored("Stored today", at(2026, 11, 2, 15), at(2026, 11, 2, 16)))

        let planning = store.activitiesForPlanning()
        XCTAssertEqual(planning.map(\.title), ["Standup", "Stored today", "Tomorrow"])

        let today = PlanMyDay.events(activities: planning, entries: [], now: store.replanNow(), calendar: cal)
        XCTAssertEqual(today.events.map(\.title), ["Standup", "Stored today"], "today's occurrence counts once")
        XCTAssertEqual(today.events.map(\.handle), ["e1", "e2"])
        XCTAssertFalse(today.cut)

        // The window starts at 00:00 today: an occurrence that began earlier today is listed (it is filtered by `now` later).
        let late = fixtureStore()
        let night = at(2026, 11, 2, 22)
        late.replanNow = { night }
        XCTAssertTrue(late.addSeries(standup()))
        XCTAssertEqual(late.activitiesForPlanning().map(\.title), ["Standup"])
        XCTAssertEqual(PlanMyDay.events(activities: late.activitiesForPlanning(), entries: [], now: late.replanNow(), calendar: cal)
            .events.count, 0)
    }

    func testRECURRULE_SurroundingPlacesUsesFourteenDays() {
        let store = fixtureStore()
        XCTAssertTrue(store.addSeries(standup()))
        // Saturday 2026-11-07 10:00-11:00: the Monday occurrence 5 days earlier is the place before, the next one (Nov 9,
        // 2 days later) the place after.
        let around = store.surroundingPlaces(start: at(2026, 11, 7, 10), end: at(2026, 11, 7, 11))
        XCTAssertEqual(around.before?.place, office)
        XCTAssertEqual(around.before?.label, "Standup")
        XCTAssertEqual(around.after?.place, office)
        XCTAssertEqual(around.after?.label, "Standup")

        // One occurrence 13 days before the start counts; one 15 days before does not (the window is 14 days).
        let near = fixtureStore()
        XCTAssertTrue(near.addSeries(weekly("Near", weekday: 6, startMinute: 540, endMinute: 570, first: 20261016, last: 20261016,
                                            place: home)))
        XCTAssertEqual(near.surroundingPlaces(start: at(2026, 10, 29, 10), end: at(2026, 10, 29, 11)).before?.place, home)
        let far = fixtureStore()
        XCTAssertTrue(far.addSeries(weekly("Far", weekday: 6, startMinute: 540, endMinute: 570, first: 20261016, last: 20261016,
                                           place: home)))
        XCTAssertNil(far.surroundingPlaces(start: at(2026, 10, 31, 10), end: at(2026, 10, 31, 11)).before)

        // The same on the after side: 13 days after the end counts, 15 days after does not.
        let ahead = fixtureStore()
        XCTAssertTrue(ahead.addSeries(weekly("Ahead", weekday: 6, startMinute: 540, endMinute: 570, first: 20261113, last: 20261113,
                                             place: home)))
        XCTAssertEqual(ahead.surroundingPlaces(start: at(2026, 10, 31, 10), end: at(2026, 10, 31, 11)).after?.place, home)
        let beyond = fixtureStore()
        XCTAssertTrue(beyond.addSeries(weekly("Beyond", weekday: 6, startMinute: 540, endMinute: 570, first: 20261113, last: 20261113,
                                              place: home)))
        XCTAssertNil(beyond.surroundingPlaces(start: at(2026, 10, 29, 10), end: at(2026, 10, 29, 11)).after)
    }

    // MARK: AC-012 - the resolver

    func testRECURRULE_ActivityByIdResolvesOccurrenceAndLegOwner() {
        let store = fixtureStore()
        let series = standup(skipped: [20261116])
        XCTAssertTrue(store.addSeries(series))
        let monday = series.occurrenceID(dayKey: 20261109)

        // Row 1: a computed occurrence resolves; a skipped day, a day before the first day and a Tuesday do not.
        let block = store.activity(id: monday)
        XCTAssertEqual(block?.title, "Standup")
        XCTAssertEqual(block?.startDate, at(2026, 11, 9, 9))
        XCTAssertEqual(block?.recurrenceId, series.id)
        XCTAssertNil(store.activity(id: series.occurrenceID(dayKey: 20261116)), "skipped")
        XCTAssertNil(store.activity(id: series.occurrenceID(dayKey: 20261026)), "before the first day")
        XCTAssertNil(store.activity(id: series.occurrenceID(dayKey: 20261110)), "a Tuesday")
        // A stored activity resolves to the stored one.
        let plain = stored("Dentist", at(2026, 11, 4, 14), at(2026, 11, 4, 15))
        store.activities.append(plain)
        XCTAssertEqual(store.activity(id: plain.id)?.title, "Dentist")
        // The "after materializing" clause (same id, the stored copy) is asserted in M4b with `materialize`.

        // Row 2: a leg linked to an occurrence id finds its owner, and the owner's legs are found by id.
        let travel = leg(for: monday, at: at(2026, 11, 9, 8, 30))
        store.events.append(travel)
        XCTAssertEqual(store.activity(forLeg: travel)?.id, monday)
        XCTAssertEqual(store.activity(forLeg: travel)?.title, "Standup")
        XCTAssertEqual(store.legs(of: monday).outbound?.id, travel.id)
        XCTAssertNil(store.activity(forLeg: leg(for: series.occurrenceID(dayKey: 20261116), at: at(2026, 11, 16, 8, 30))),
                     "a leg of a skipped day has no owner")

        // `activityIfChanged`: a snapshot of the computed occurrence against a stored copy with the same id and a new title.
        let snapshot = block
        XCTAssertNil(store.activityIfChanged(snapshot), "nothing changed yet")
        var copy = stored("Standup (edited)", at(2026, 11, 9, 9), at(2026, 11, 9, 9, 30), place: office)
        copy.id = monday
        copy.recurrenceId = series.id
        store.activities.append(copy)
        XCTAssertEqual(store.activityIfChanged(snapshot)?.title, "Standup (edited)")
        XCTAssertNil(store.activityIfChanged(copy), "the stored copy against itself")
        XCTAssertNil(store.activityIfChanged(nil))
    }

    // MARK: AC-015.6 - the Settings reset

    func testRECURRULE_ResetRemovesSeries() throws {
        let store = fixtureStore()
        let first = standup()
        let second = weekly("Gym", weekday: 4, startMinute: 1080, endMinute: 1140, first: 20261104)
        XCTAssertTrue(store.addSeries(first))
        XCTAssertTrue(store.addSeries(second))
        store.activities.append(stored("Dentist", at(2026, 11, 4, 14), at(2026, 11, 4, 15)))
        var travel = leg(for: first.occurrenceID(dayKey: 20261109), at: at(2026, 11, 9, 8, 30))
        travel.recurrenceId = first.id
        store.events.append(travel)
        XCTAssertEqual(store.series.count, 2)

        store.deleteEverythingForTesting()
        XCTAssertEqual(store.series.count, 0)
        XCTAssertEqual(store.activities.count, 0)
        XCTAssertEqual(store.events.count, 0, "the legs of the series went with it")
        XCTAssertEqual(store.activities(on: at(2026, 11, 9)).count, 0)
        XCTAssertFalse(store.hasSchedule(on: at(2026, 11, 9)))

        // series.json holds an empty list, and a relaunch starts with no series.
        let data = try XCTUnwrap(bytes("series.json"))
        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(list.count, 0)
        XCTAssertEqual(relaunched().series.count, 0)
    }
}
