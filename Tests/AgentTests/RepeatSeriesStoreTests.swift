import XCTest
@testable import besir

/// SPEC-RECURRULE-001 (card t60): the stored series, its file, its ids and the readers. The tests arrive with the
/// milestone that builds what they read; the window core is covered in `RepeatSeriesWindowTests`.
/// All dates here are class A: only new code and injected clocks are reached, so fixed 2026 dates are safe.
@MainActor
final class RepeatSeriesStoreTests: XCTestCase {
    private var savedZone: TimeZone!
    /// Link files of the mirrors a test built (AC-017); removed in `tearDown`.
    private var linkURLs: [URL] = []

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Seoul")!
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
        for url in linkURLs { try? FileManager.default.removeItem(at: url) }
        linkURLs = []
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

    func testRECURRULE_CacheClearsWhenSeriesChanges() throws {
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

        // The skipped-day variant (AC-010.4): a day added to `skippedDayKeys` through the store clears the cache, the next
        // read expands again and shows the skip.
        XCTAssertTrue(store.hasSchedule(on: at(2029, 3, 5)))
        XCTAssertTrue(store.hasSchedule(on: at(2029, 3, 12)))
        let monday = standupSeries(in: store).occurrenceID(dayKey: 20290305)
        let beforeSkip = RecurrenceRule.drvExpansionCount
        store.deleteActivity(try XCTUnwrap(store.activity(id: monday), "the occurrence of 2029-03-05 resolves"))
        XCTAssertEqual(store.series.first { $0.title == "Standup" }?.skippedDayKeys, [20290305])
        XCTAssertFalse(store.hasSchedule(on: at(2029, 3, 5)), "the skip is reflected")
        XCTAssertGreaterThan(RecurrenceRule.drvExpansionCount, beforeSkip, "the skip cleared the cache")
        XCTAssertTrue(store.scheduleTitles(on: at(2029, 3, 5)).isEmpty)
        XCTAssertTrue(store.hasSchedule(on: at(2029, 3, 12)), "the other Mondays stay")
    }

    private func standupSeries(in store: Store) -> RepeatSeries {
        store.series.first { $0.title == "Standup" }!
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

    func testRECURRULE_AgentListResolveUpdateDeleteByOccurrenceId() async throws {
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
        let secondText = try XCTUnwrap(items.dropFirst().first?["id"] as? String)
        let delete = h.call("delete_activity", ["id": secondText])
        let deleteCard = try XCTUnwrap(delete.card)
        XCTAssertEqual(deleteCard.lines.first, "Delete event")
        XCTAssertTrue(deleteCard.lines.contains("Standup"))
        // A random UUID, and a day of the series that is not an occurrence (a Tuesday), are not found.
        XCTAssertEqual(h.call("update_activity", ["id": UUID().uuidString, "title": "x"]).message, ToolText.findID("update_activity"))
        let tuesday = series.occurrenceID(dayKey: 20281107)
        XCTAssertEqual(h.call("delete_activity", ["id": tuesday.uuidString]).message, ToolText.findID("delete_activity"))
        // Nothing was written by the read calls.
        XCTAssertEqual(h.store.series.first { $0.id == series.id }?.skippedDayKeys, [])
        XCTAssertTrue(h.store.activities.allSatisfy { $0.title.hasPrefix("Stored") }, "no copy was made by the cards")

        // Row 2, the confirmed half (AC-011.2): the update leaves one stored copy with the same id, the day is skipped, and
        // the apply result is `applied`.
        let updated = await updateCard.resolve(.confirm)
        XCTAssertEqual(updated?.status, "applied")
        XCTAssertEqual(updateCard.mark, .confirmed)
        let copies = h.store.activities.filter { $0.id == id }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first?.title, "Renamed")
        XCTAssertNil(copies.first?.recurrenceId)
        XCTAssertEqual(h.store.series.first { $0.id == series.id }?.skippedDayKeys, [20281106])
        // The delete adds the skipped day of the second occurrence, makes no copy, and answers `applied`.
        let secondId = try XCTUnwrap(UUID(uuidString: secondText))
        let deleted = await deleteCard.resolve(.confirm)
        XCTAssertEqual(deleted?.status, "applied")
        XCTAssertEqual(deleteCard.mark, .confirmed)
        XCTAssertEqual(Set(h.store.series.first { $0.id == series.id }?.skippedDayKeys ?? []), [20281106, 20281113])
        XCTAssertNil(h.store.activity(id: secondId))
        XCTAssertEqual(h.store.activities.filter { $0.id == secondId }.count, 0)
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
        // (A skipped day is the other change; it is asserted right after this one.)
        let changed = PlaceRig()
        XCTAssertTrue(changed.store.addSeries(tuesday))
        let changedCard = try await card(changed)
        XCTAssertTrue(changed.store.addSeries(weekly("Second", weekday: 3, startMinute: 720, endMinute: 780, first: 20261027)))
        let changedResult = await changedCard.resolve(.confirm)
        XCTAssertEqual(changedResult?.status, "stale")
        XCTAssertEqual(changedResult?.message, AgentDayPlan.Say.scheduleChanged)

        // The occurrence in the window is deleted after the check (a skipped day): the signature differs, the plan is stale.
        let skipped = PlaceRig()
        XCTAssertTrue(skipped.store.addSeries(tuesday))
        let skippedCard = try await card(skipped)
        let tuesdayBlock = try XCTUnwrap(skipped.store.activity(id: tuesday.occurrenceID(dayKey: 20261027)))
        skipped.store.deleteActivity(tuesdayBlock)
        XCTAssertEqual(skipped.store.series.first?.skippedDayKeys, [20261027])
        let skippedResult = await skippedCard.resolve(.confirm)
        XCTAssertEqual(skippedResult?.status, "stale")
        XCTAssertEqual(skippedResult?.message, AgentDayPlan.Say.scheduleChanged)

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

        // Row 1, after materializing: an edit of the Nov 23 occurrence makes a stored copy with the same id, and the
        // resolver returns that copy.
        let nov23 = series.occurrenceID(dayKey: 20261123)
        XCTAssertEqual(store.activity(id: nov23)?.recurrenceId, series.id)
        XCTAssertTrue(store.modifyActivity(id: nov23, newTitle: "Standup (renamed)"))
        let after = store.activity(id: nov23)
        XCTAssertEqual(after?.id, nov23)
        XCTAssertEqual(after?.title, "Standup (renamed)")
        XCTAssertNil(after?.recurrenceId, "the stored copy left the series")
        XCTAssertEqual(store.activities.filter { $0.id == nov23 }.count, 1)
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

    // MARK: M4b - delete one, edit or move one, delete the series, add a leg to the series (AC-013, AC-014, AC-015)

    /// A leg as `addLegToSeries` makes it: linked to the occurrence id, carrying the series id, with its estimate of 900
    /// seconds, so a move or a drag has something to carry along. Built by hand where a test must not depend on the
    /// writer that is not under test.
    private func seriesLeg(_ s: RepeatSeries, _ dayKey: Int, _ role: ScheduleAnchor) -> ScheduledEvent {
        let day = RepeatSeries.date(forDayKey: dayKey, calendar: cal)!
        let start = day.addingTimeInterval(Double(s.startMinute) * 60)
        let end = day.addingTimeInterval(Double(s.endMinute + s.endDayDistance * 1440) * 60)
        var e: ScheduledEvent
        if role == .departure {
            e = ScheduledEvent(title: "\(s.title) (return)", origin: s.location, destination: home,
                               arrivalDate: end.addingTimeInterval(900), mode: .car, bufferMinutes: 0, notifyLeadMinutes: 10)
            e.departureDate = end
        } else {
            e = ScheduledEvent(title: s.title, origin: home, destination: s.location ?? office,
                               arrivalDate: start, mode: .car, bufferMinutes: 0, notifyLeadMinutes: 10)
            e.departureDate = start.addingTimeInterval(-900)
        }
        e.anchor = role
        e.travelSeconds = 900
        e.linkedActivityId = s.occurrenceID(dayKey: dayKey)
        e.recurrenceId = s.id
        return e
    }

    /// Class B (design rule 5): the first Monday at least 400 days after the real date, so the baseline readers of the real
    /// clock (`removeUpcomingMeals`, `rescheduleNearestNotifications`) see only dates in their future.
    private func classBMonday() -> Date {
        var d = cal.date(byAdding: .day, value: 400, to: cal.startOfDay(for: Date()))!
        while cal.component(.weekday, from: d) != 2 { d = cal.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    private func key(_ date: Date) -> Int { Store.dayKey(date, calendar: cal) }

    /// Makes both legs for the clock day and the two Mondays after it with `addLegToSeries`, the way the screen does.
    private func addBothLegs(_ store: Store, _ series: RepeatSeries, edited: UUID, editedDetaches: Bool = false) async throws {
        for role in [ScheduleAnchor.arrival, ScheduleAnchor.departure] {
            let preview = try XCTUnwrap(store.previewSeriesLegAdd(activityId: edited, role: role))
            let made = await store.addLegToSeries(editedActivityId: edited, seriesId: series.id, role: role, outerPlace: home,
                                                  mode: .car, bufferMinutes: 5, notifyLeadMinutes: 10,
                                                  targetActivityIds: preview.eligibleIds, editedDetaches: editedDetaches)
            XCTAssertEqual(made.added, 3, "legs made for \(role)")
        }
    }

    // MARK: AC-013 - delete one occurrence

    func testRECURRULE_DeleteOneSkipsDayAndRemovesLegsAndMeals() async throws {
        let d0 = classBMonday()
        func day(_ n: Int, _ hour: Int = 0) -> Date { d0.addingTimeInterval(Double(n) * 86400 + Double(hour) * 3600) }
        let store = EmptyStore.make()
        let clock = day(0, 8)
        store.replanNow = { clock }
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        var series = standup()
        series.firstDayKey = key(d0)
        XCTAssertTrue(store.addSeries(series))
        let ids = [0, 7, 14].map { series.occurrenceID(dayKey: key(day($0))) }
        try await addBothLegs(store, series, edited: ids[0])
        XCTAssertEqual(store.events.count, 6)

        // Upcoming meals: one on a leg of the middle occurrence (goes with it), one on a leg of the last (stays).
        store.addMeal(category: .cooking, title: "Goes", scheduledEventId: try XCTUnwrap(store.legs(of: ids[1]).return).id,
                      plannedAt: day(7, 12), loggedAt: day(-1))
        store.addMeal(category: .cooking, title: "Stays", scheduledEventId: try XCTUnwrap(store.legs(of: ids[2]).return).id,
                      plannedAt: day(14, 12), loggedAt: day(-1))
        XCTAssertEqual(store.meals.count, 2)

        let eventSaves = store.drvSaveCount
        store.deleteActivity(try XCTUnwrap(store.activity(id: ids[1])))
        XCTAssertGreaterThan(store.drvSaveCount, eventSaves, "the legs were removed through the base clean-up")
        XCTAssertEqual(store.series[0].skippedDayKeys, [key(day(7))])
        XCTAssertTrue(store.events.filter { $0.linkedActivityId == ids[1] }.isEmpty, "the legs of the day are gone")
        XCTAssertEqual(store.events.count, 4)
        XCTAssertEqual(Set(store.events.compactMap(\.linkedActivityId)), [ids[0], ids[2]])
        XCTAssertEqual(store.meals.map(\.title), ["Stays"], "the upcoming meal of the removed leg is removed")
        XCTAssertEqual(store.activities.count, 0, "no record was removed or made")
        XCTAssertNil(store.activity(id: ids[1]))
        XCTAssertEqual(store.activities(on: day(7)).count, 0)
        XCTAssertEqual(store.activities(on: day(0)).count, 1)
        XCTAssertEqual(store.activities(on: day(14)).count, 1)

        // Alarms: after a reschedule exactly the remaining legs carry one (the removed legs are gone from `events`; the
        // cancellation of their pending requests is not observable here and rests on `removeExplicitLegs`).
        store.rescheduleNearestNotifications()
        XCTAssertEqual(Set(store.events.filter { $0.notificationId != nil }.map(\.id)), Set(store.events.map(\.id)))

        // The skip survives a relaunch.
        XCTAssertEqual(relaunched().series.first?.skippedDayKeys, [key(day(7))])

        // `deleteActivities` takes the same path for several occurrences in one call.
        store.deleteActivities([try XCTUnwrap(store.activity(id: ids[0])), try XCTUnwrap(store.activity(id: ids[2]))])
        XCTAssertEqual(Set(store.series[0].skippedDayKeys), [key(day(0)), key(day(7)), key(day(14))])
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.meals.isEmpty)
        XCTAssertEqual(store.activities(in: DateInterval(start: day(0), end: day(21))).count, 0)
    }

    // MARK: AC-014 - edit or move one occurrence

    func testRECURRULE_UnchangedSaveMaterializesNothing() async throws {
        let store = fixtureStore()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let monday = series.occurrenceID(dayKey: 20261109)
        store.events.append(seriesLeg(series, 20261109, .arrival))
        let block = try XCTUnwrap(store.activity(id: monday))
        let saves = (store.drvSaveActivitiesCount, store.drvSaveCount)

        // The detail screen calls `modifyActivity` with every field on every Save.
        let changed = store.modifyActivity(id: monday, newTitle: block.title, newStart: block.startDate, newEnd: block.endDate,
                                           newPlace: block.location, clearPlace: false)
        XCTAssertFalse(changed)
        XCTAssertEqual(store.activities.count, 0)
        XCTAssertEqual(store.series[0].skippedDayKeys, [])
        XCTAssertEqual(store.activity(id: monday)?.recurrenceId, series.id)
        XCTAssertEqual(store.drvSaveActivitiesCount, saves.0)

        // `realignLegs` finds the leg through the occurrence id (positive control) and, with nothing to follow, writes
        // nothing and materializes nothing.
        let realigned = await store.realignLegs(of: monday)
        XCTAssertNotNil(realigned.outbound, "the leg of the occurrence is found")
        XCTAssertNil(realigned.return)
        XCTAssertEqual(store.activities.count, 0)
        XCTAssertEqual(store.series[0].skippedDayKeys, [])
        XCTAssertEqual(store.drvSaveActivitiesCount, saves.0)
        XCTAssertEqual(store.drvSaveCount, saves.1)
        XCTAssertEqual(store.events.first?.recurrenceId, series.id)
        XCTAssertEqual(store.activity(id: monday)?.recurrenceId, series.id)
    }

    func testRECURRULE_EditOneMaterializesWithSameIdAndNoDuplicate() throws {
        let store = fixtureStore()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let monday = series.occurrenceID(dayKey: 20261109)

        XCTAssertTrue(store.modifyActivity(id: monday, newTitle: "Standup (moved)"))
        XCTAssertEqual(store.activities.count, 1)
        let copy = try XCTUnwrap(store.activities.first)
        XCTAssertEqual(copy.id, monday)
        XCTAssertEqual(copy.title, "Standup (moved)")
        XCTAssertNil(copy.recurrenceId)
        XCTAssertEqual(copy.startDate, at(2026, 11, 9, 9))
        XCTAssertEqual(copy.endDate, at(2026, 11, 9, 9, 30))
        XCTAssertEqual(copy.location, office)
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])
        XCTAssertEqual(store.activities(on: at(2026, 11, 9)).map(\.title), ["Standup (moved)"], "exactly one block that day")
        // AC-012.1 after materializing: the resolver returns the stored copy with the same id.
        XCTAssertEqual(store.activity(id: monday)?.title, "Standup (moved)")
        XCTAssertNil(store.activity(id: monday)?.recurrenceId)
        // The other Mondays are still computed.
        XCTAssertEqual(store.activities(on: at(2026, 11, 16)).first?.recurrenceId, series.id)
        XCTAssertEqual(store.activities(on: at(2026, 11, 2)).first?.recurrenceId, series.id)

        // A second edit finds the copy and adds no second one.
        XCTAssertTrue(store.modifyActivity(id: monday, newTitle: "Again"))
        XCTAssertEqual(store.activities.count, 1)
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])
        XCTAssertEqual(store.activities(on: at(2026, 11, 9)).map(\.title), ["Again"])

        // Both files reached the disk: a relaunch shows one block that day.
        let again = relaunched()
        XCTAssertEqual(again.activities.map(\.id), [monday])
        XCTAssertEqual(again.series.first?.skippedDayKeys, [20261109])
        XCTAssertEqual(again.activities(on: at(2026, 11, 9)).map(\.title), ["Again"])

        // The end and the place are edits too: each makes its own copy; clearing the place removes the occurrence's legs.
        let nov16 = series.occurrenceID(dayKey: 20261116)
        XCTAssertTrue(store.modifyActivity(id: nov16, newEnd: at(2026, 11, 16, 10)))
        XCTAssertEqual(store.activity(id: nov16)?.endDate, at(2026, 11, 16, 10))
        XCTAssertNil(store.activity(id: nov16)?.recurrenceId)
        let nov23 = series.occurrenceID(dayKey: 20261123)
        store.events.append(seriesLeg(series, 20261123, .arrival))
        XCTAssertTrue(store.modifyActivity(id: nov23, clearPlace: true))
        XCTAssertNil(store.activity(id: nov23)?.location)
        XCTAssertTrue(store.events.isEmpty, "the leg of a place-less occurrence is removed")
        XCTAssertEqual(Set(store.series[0].skippedDayKeys), [20261109, 20261116, 20261123])
        XCTAssertEqual(store.activities.count, 3)
    }

    func testRECURRULE_MoveOneMaterializes() throws {
        let store = fixtureStore()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let monday = series.occurrenceID(dayKey: 20261109)
        store.events.append(seriesLeg(series, 20261109, .arrival))
        store.events.append(seriesLeg(series, 20261109, .departure))
        store.events.append(seriesLeg(series, 20261116, .arrival))

        store.moveActivity(try XCTUnwrap(store.activity(id: monday)), byMinutes: 30, wholeSeries: false)
        XCTAssertEqual(store.activities.count, 1)
        let copy = try XCTUnwrap(store.activities.first)
        XCTAssertEqual(copy.id, monday)
        XCTAssertEqual(copy.startDate, at(2026, 11, 9, 9, 30))
        XCTAssertEqual(copy.endDate, at(2026, 11, 9, 10))
        XCTAssertNil(copy.recurrenceId)
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])
        // The other Mondays stay at 09:00.
        XCTAssertEqual(store.activities(on: at(2026, 11, 16)).first?.startDate, at(2026, 11, 16, 9))
        XCTAssertEqual(store.activities(on: at(2026, 11, 2)).first?.startDate, at(2026, 11, 2, 9))
        // The legs of the moved occurrence went along and left the series; the leg of the other Monday did not move.
        let moved = store.events.filter { $0.linkedActivityId == monday }
        XCTAssertEqual(moved.count, 2)
        XCTAssertTrue(moved.allSatisfy { $0.recurrenceId == nil })
        XCTAssertEqual(store.legs(of: monday).outbound?.arrivalDate, at(2026, 11, 9, 9, 30))
        XCTAssertEqual(store.legs(of: monday).return?.departureDate, at(2026, 11, 9, 10))
        let other = store.legs(of: series.occurrenceID(dayKey: 20261116)).outbound
        XCTAssertEqual(other?.arrivalDate, at(2026, 11, 16, 9))
        XCTAssertEqual(other?.recurrenceId, series.id)
        // `modifyActivity` with a new start is the same move.
        let nov23 = series.occurrenceID(dayKey: 20261123)
        XCTAssertTrue(store.modifyActivity(id: nov23, newStart: at(2026, 11, 23, 11)))
        XCTAssertEqual(store.activity(id: nov23)?.startDate, at(2026, 11, 23, 11))
        XCTAssertEqual(store.activities.count, 2)
        // A move by zero changes nothing.
        let nov30 = try XCTUnwrap(store.activity(id: series.occurrenceID(dayKey: 20261130)))
        store.moveActivity(nov30, byMinutes: 0, wholeSeries: false)
        XCTAssertEqual(store.activities.count, 2)
    }

    func testRECURRULE_AddUpdateRemoveLegMaterializeOnce() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let nov9 = series.occurrenceID(dayKey: 20261109)

        // addLeg on a computed occurrence: the leg is linked to the occurrence id and the occurrence leaves the series.
        let added = await store.addLeg(activityId: nov9, role: .arrival, outerPlace: home, mode: .car, bufferMinutes: 5,
                                       notifyLeadMinutes: 10)
        guard case .created = added else { return XCTFail("expected a created leg, got \(added)") }
        XCTAssertEqual(store.activities.count, 1)
        XCTAssertEqual(store.activities.first?.id, nov9)
        XCTAssertNil(store.activities.first?.recurrenceId)
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])
        let outbound = try XCTUnwrap(store.legs(of: nov9).outbound)
        XCTAssertEqual(outbound.linkedActivityId, nov9)
        XCTAssertNil(outbound.recurrenceId)
        // A second addLeg on the same occurrence finds the copy and adds no second one.
        let second = await store.addLeg(activityId: nov9, role: .departure, outerPlace: home, mode: .car, bufferMinutes: 0,
                                        notifyLeadMinutes: 10)
        guard case .created = second else { return XCTFail("expected a created leg, got \(second)") }
        XCTAssertEqual(store.activities.count, 1)
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])

        // updateLeg on a leg of a computed occurrence (a leg that carries the series id, as the leg window makes it).
        let nov16 = series.occurrenceID(dayKey: 20261116)
        let legOfNov16 = seriesLeg(series, 20261116, .arrival)
        store.events.append(legOfNov16)
        let updated = await store.updateLeg(legId: legOfNov16.id, bufferMinutes: 7)
        guard case .updated = updated else { return XCTFail("expected an updated leg, got \(updated)") }
        XCTAssertEqual(Set(store.activities.map(\.id)), [nov9, nov16])
        XCTAssertEqual(store.events.first { $0.id == legOfNov16.id }?.bufferMinutes, 7)
        XCTAssertNil(store.events.first { $0.id == legOfNov16.id }?.recurrenceId)
        _ = await store.updateLeg(legId: legOfNov16.id, bufferMinutes: 8)
        XCTAssertEqual(store.activities.count, 2, "a second update adds no second copy")

        // removeLeg on a leg of a computed occurrence.
        let nov23 = series.occurrenceID(dayKey: 20261123)
        let legOfNov23 = seriesLeg(series, 20261123, .arrival)
        let returnOfNov23 = seriesLeg(series, 20261123, .departure)
        store.events.append(contentsOf: [legOfNov23, returnOfNov23])
        if case .failed = store.removeLeg(legId: legOfNov23.id) { XCTFail("the leg should be removed") }
        XCTAssertEqual(store.activities.count, 3)
        XCTAssertNotNil(store.activities.first { $0.id == nov23 })
        XCTAssertNil(store.events.first { $0.id == legOfNov23.id })
        XCTAssertNil(store.events.first { $0.id == returnOfNov23.id }?.recurrenceId, "the rest of the occurrence left the series")
        XCTAssertEqual(Set(store.series[0].skippedDayKeys), [20261109, 20261116, 20261123])
        XCTAssertEqual(Set(store.activities.map(\.id)).count, store.activities.count)
    }

    func testRECURRULE_SingleLegDragMaterializesAndMovesTheCopy() throws {
        let store = fixtureStore()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let monday = series.occurrenceID(dayKey: 20261109)
        let outbound = seriesLeg(series, 20261109, .arrival)
        let returnLeg = seriesLeg(series, 20261109, .departure)
        store.events.append(contentsOf: [outbound, returnLeg])
        store.events.append(seriesLeg(series, 20261116, .arrival))

        // The outbound leg is dragged 10 minutes down (one grid step): the leg moves, the owner's start follows.
        store.adjustTravelLeg(outbound, byMinutes: 10, wholeSeries: false)
        XCTAssertEqual(store.activities.count, 1)
        let copy = try XCTUnwrap(store.activities.first)
        XCTAssertEqual(copy.id, monday)
        XCTAssertEqual(copy.startDate, at(2026, 11, 9, 9, 10))
        XCTAssertEqual(copy.endDate, at(2026, 11, 9, 9, 30))
        XCTAssertNil(copy.recurrenceId)
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])
        XCTAssertEqual(store.events.first { $0.id == outbound.id }?.arrivalDate, at(2026, 11, 9, 9, 10))
        XCTAssertTrue(store.events.filter { $0.linkedActivityId == monday }.allSatisfy { $0.recurrenceId == nil })
        // The other Mondays and their legs are unchanged.
        XCTAssertEqual(store.activities(on: at(2026, 11, 16)).first?.startDate, at(2026, 11, 16, 9))
        XCTAssertEqual(store.legs(of: series.occurrenceID(dayKey: 20261116)).outbound?.arrivalDate, at(2026, 11, 16, 9))
        XCTAssertEqual(store.legs(of: series.occurrenceID(dayKey: 20261116)).outbound?.recurrenceId, series.id)

        // The return leg of another occurrence, dragged down: the owner's end follows.
        let nov23 = series.occurrenceID(dayKey: 20261123)
        let returnOfNov23 = seriesLeg(series, 20261123, .departure)
        store.events.append(returnOfNov23)
        store.adjustTravelLeg(returnOfNov23, byMinutes: 10, wholeSeries: false)
        XCTAssertEqual(store.activity(id: nov23)?.endDate, at(2026, 11, 23, 9, 40))
        XCTAssertNil(store.activity(id: nov23)?.recurrenceId)
        XCTAssertEqual(store.activities.count, 2)
    }

    func testRECURRULE_StoredCopyAndOccurrenceAreNeverBothDrawn() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let nov = [2, 9, 16, 23, 30].map { series.occurrenceID(dayKey: 20261100 + $0) }
        let dec7 = series.occurrenceID(dayKey: 20261207)
        let nov23Leg = seriesLeg(series, 20261123, .arrival)
        store.events.append(nov23Leg)
        let nov30Leg = seriesLeg(series, 20261130, .arrival)
        store.events.append(nov30Leg)

        XCTAssertTrue(store.modifyActivity(id: nov[0], newTitle: "Edited"))                                   // AC-014.2
        store.moveActivity(try XCTUnwrap(store.activity(id: nov[1])), byMinutes: 30, wholeSeries: false)        // AC-014.3
        _ = await store.updateLeg(legId: nov23Leg.id, bufferMinutes: 9)                                          // AC-014.4
        store.adjustTravelLeg(nov30Leg, byMinutes: 10, wholeSeries: false)                                       // AC-014.5
        XCTAssertTrue(store.detachOccurrence(activityId: dec7))                                                  // AC-014.7
        XCTAssertEqual(store.activities.count, 5, "five occurrences were materialized, one copy each")

        // Over two months, no id is drawn twice in the day list, in the interval read or in the month titles.
        var day = at(2026, 11, 1)
        while day < at(2027, 1, 1) {
            let ids = store.activities(on: day).map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "no id twice on \(day)")
            let titles = store.scheduleTitles(on: day).map(\.id)
            XCTAssertEqual(Set(titles).count, titles.count, "no title twice on \(day)")
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        let all = store.activities(in: DateInterval(start: at(2026, 11, 1), end: at(2026, 12, 29)))
        XCTAssertEqual(all.count, 9, "the nine Mondays of the two months, each once")
        XCTAssertEqual(Set(all.map(\.id)).count, 9)
        for copy in store.activities {
            XCTAssertEqual(all.filter { $0.id == copy.id }.count, 1)
            XCTAssertTrue(store.series[0].skippedDayKeys.contains(RepeatSeries.decode(copy.id)!.dayKey))
        }
        XCTAssertEqual(all.filter { $0.recurrenceId == series.id }.count, 4, "four are still computed")
    }

    func testRECURRULE_DetachOccurrenceMaterializes() throws {
        let store = fixtureStore()
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let monday = series.occurrenceID(dayKey: 20261109)
        store.events.append(seriesLeg(series, 20261109, .arrival))

        XCTAssertTrue(store.detachOccurrence(activityId: monday))
        XCTAssertEqual(store.activities.count, 1)
        XCTAssertEqual(store.activities.first?.id, monday)
        XCTAssertNil(store.activities.first?.recurrenceId)
        XCTAssertEqual(store.activities.first?.title, "Standup")
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])
        XCTAssertNil(store.legs(of: monday).outbound?.recurrenceId, "the leg left the series with its occurrence")
        // The leg's change reached events.json: a relaunch reads it back.
        XCTAssertNil(relaunched().events.first?.recurrenceId)
        // A second call finds the copy and has nothing left to detach.
        XCTAssertFalse(store.detachOccurrence(activityId: monday))
        XCTAssertEqual(store.activities.count, 1)
        // An id that is not an occurrence (a Tuesday of the series, a random id) detaches nothing.
        XCTAssertFalse(store.detachOccurrence(activityId: series.occurrenceID(dayKey: 20261110)))
        XCTAssertFalse(store.detachOccurrence(activityId: UUID()))
        XCTAssertEqual(store.activities.count, 1)
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])
    }

    // MARK: AC-015 - the whole series: delete

    func testRECURRULE_DeleteSeriesKeepsMaterializedCopiesAndTheirLegs() async throws {
        let d0 = classBMonday()
        func day(_ n: Int, _ hour: Int = 0) -> Date { d0.addingTimeInterval(Double(n) * 86400 + Double(hour) * 3600) }
        let store = EmptyStore.make()
        let clock = day(0, 8)
        store.replanNow = { clock }
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        var series = standup()
        series.firstDayKey = key(d0)
        XCTAssertTrue(store.addSeries(series))
        let ids = [0, 7, 14].map { series.occurrenceID(dayKey: key(day($0))) }
        try await addBothLegs(store, series, edited: ids[0])
        XCTAssertEqual(store.events.count, 6)
        // The middle occurrence is edited: it becomes a stored copy and its two legs leave the series.
        XCTAssertTrue(store.modifyActivity(id: ids[1], newTitle: "Standup (moved)"))
        XCTAssertTrue(store.events.filter { $0.linkedActivityId == ids[1] }.allSatisfy { $0.recurrenceId == nil })
        // Upcoming meals: one on a leg of the last occurrence (goes with the series), one on a leg of the copy (stays).
        store.addMeal(category: .cooking, title: "Goes", scheduledEventId: try XCTUnwrap(store.legs(of: ids[2]).return).id,
                      plannedAt: day(14, 12), loggedAt: day(-1))
        store.addMeal(category: .cooking, title: "Stays", scheduledEventId: try XCTUnwrap(store.legs(of: ids[1]).return).id,
                      plannedAt: day(7, 12), loggedAt: day(-1))

        store.deleteRecurringSeries(series.id)
        XCTAssertTrue(store.series.isEmpty)
        XCTAssertEqual(store.activities.map(\.id), [ids[1]], "the materialized copy is still there")
        XCTAssertEqual(store.activities.first?.title, "Standup (moved)")
        XCTAssertEqual(store.events.count, 2, "only the copy's two legs remain")
        XCTAssertTrue(store.events.allSatisfy { $0.linkedActivityId == ids[1] && $0.recurrenceId == nil })
        XCTAssertEqual(store.meals.map(\.title), ["Stays"], "the meal on a removed leg went, the meal on the copy's leg stayed")
        XCTAssertNil(store.activity(id: ids[0]))
        XCTAssertNil(store.activity(id: ids[2]))
        XCTAssertEqual(store.activities(in: DateInterval(start: day(0), end: day(21))).map(\.id), [ids[1]])
        XCTAssertEqual(relaunched().series.count, 0)
    }

    func testRECURRULE_DeleteSeriesAfterReloadKeepsMaterializedCopiesAndTheirLegs() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let nov2 = series.occurrenceID(dayKey: 20261102)
        let nov9 = series.occurrenceID(dayKey: 20261109)
        try await addBothLegs(store, series, edited: nov2)
        XCTAssertEqual(store.events.count, 6)
        // An edit that changes the title clears the legs' series id.
        XCTAssertTrue(store.modifyActivity(id: nov9, newTitle: "Standup (moved)"))
        XCTAssertTrue(store.events.filter { $0.linkedActivityId == nov9 }.allSatisfy { $0.recurrenceId == nil })

        // A new Store on the same support directory reads the legs' series id back from events.json, not from memory.
        let reloaded = relaunched()
        let copyLegs = reloaded.events.filter { $0.linkedActivityId == nov9 }
        XCTAssertEqual(copyLegs.count, 2)
        XCTAssertTrue(copyLegs.allSatisfy { $0.recurrenceId == nil }, "the clear of the legs' series id was saved")
        reloaded.deleteRecurringSeries(series.id)
        XCTAssertTrue(reloaded.series.isEmpty)
        XCTAssertEqual(reloaded.activities.map(\.id), [nov9])
        XCTAssertEqual(reloaded.events.count, 2)
        XCTAssertTrue(reloaded.events.allSatisfy { $0.linkedActivityId == nov9 && $0.recurrenceId == nil })
    }

    // MARK: AC-015.5 - add a leg to the whole series

    func testRECURRULE_AddLegToWholeSeriesMakesLegsAndWritesThePlan() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        XCTAssertEqual(Store.legWindowDays, 14)
        XCTAssertEqual(Store.legRetentionDays, 30)
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        XCTAssertNil(store.series[0].legPlan)
        XCTAssertNil(store.series[0].legsFilledThroughDayKey)
        let id = { (key: Int) in series.occurrenceID(dayKey: key) }
        let (nov2, nov9, nov16, nov23) = (id(20261102), id(20261109), id(20261116), id(20261123))

        // The preview reports the occurrences from the clock day through 14 days ahead (Nov 2, 9 and 16; Nov 23 is day 21).
        let preview = try XCTUnwrap(store.previewSeriesLegAdd(activityId: nov9, role: .arrival))
        XCTAssertEqual(preview.seriesId, series.id)
        XCTAssertEqual(preview.eligibleIds, [nov2, nov9, nov16])
        XCTAssertEqual(preview.wouldAddIds, [nov2, nov9, nov16])
        XCTAssertEqual(preview.alreadyHasRoleCount, 0)
        XCTAssertEqual(preview.noPlaceCount, 0)
        XCTAssertFalse(preview.eligibleIds.contains(nov23))

        let result = await store.addLegToSeries(editedActivityId: nov9, seriesId: series.id, role: .arrival, outerPlace: home,
                                                mode: .car, bufferMinutes: 5, notifyLeadMinutes: 10,
                                                targetActivityIds: preview.eligibleIds, editedDetaches: true)
        XCTAssertEqual(result.added, 3)
        XCTAssertEqual(result.skippedExisting, 0)
        XCTAssertEqual(result.skippedNoPlace, 0)
        XCTAssertEqual(store.events.count, 3)
        for occurrence in [nov2, nov9, nov16] {
            let leg = try XCTUnwrap(store.legs(of: occurrence).outbound, "a leg for \(occurrence)")
            XCTAssertEqual(leg.linkedActivityId, occurrence)
            XCTAssertEqual(leg.anchor, .arrival)
            XCTAssertEqual(leg.origin, home)
            XCTAssertEqual(leg.destination, office)
            XCTAssertEqual(leg.travelSeconds, 900)
            XCTAssertEqual(leg.recurrenceId, occurrence == nov9 ? nil : series.id)
        }
        // The edited occurrence was materialized.
        XCTAssertEqual(store.activities.map(\.id), [nov9])
        XCTAssertNil(store.activities.first?.recurrenceId)
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])
        // The role is in the plan, and the mark was nil so it is now the key of today + 14 (asserted directly).
        let plan = try XCTUnwrap(store.series[0].legPlan)
        XCTAssertEqual(plan.outboundFrom, home)
        XCTAssertEqual(plan.outboundMode, .car)
        XCTAssertEqual(plan.bufferMinutes, 5)
        XCTAssertEqual(plan.notifyLeadMinutes, 10)
        XCTAssertTrue(plan.notifyEnabled)
        XCTAssertNil(plan.returnTo)
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116)
        // The plan and the mark are on the disk.
        let reloaded = relaunched()
        XCTAssertEqual(reloaded.series.first?.legsFilledThroughDayKey, 20261116)
        XCTAssertEqual(reloaded.series.first?.legPlan?.outboundFrom, home)

        // The return role on the same series: the plan gets it, the mark that exists is left alone, and the stored copy of
        // Nov 9 is not a target any more (it left the series).
        let back = try XCTUnwrap(store.previewSeriesLegAdd(activityId: nov2, role: .departure))
        XCTAssertEqual(back.eligibleIds, [nov2, nov16])
        let backResult = await store.addLegToSeries(editedActivityId: nov2, seriesId: series.id, role: .departure,
                                                    outerPlace: home, mode: .transit, bufferMinutes: 0, notifyLeadMinutes: 10,
                                                    targetActivityIds: back.eligibleIds, editedDetaches: false)
        XCTAssertEqual(backResult.added, 2)
        XCTAssertEqual(store.series[0].legPlan?.returnTo, home)
        XCTAssertEqual(store.series[0].legPlan?.returnMode, .transit)
        XCTAssertEqual(store.series[0].legPlan?.outboundFrom, home)
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116, "an existing mark is left alone")
        XCTAssertNil(store.legs(of: nov9).return, "the stored copy got no return leg")
        XCTAssertEqual(store.legs(of: nov2).return?.recurrenceId, series.id)
    }

    func testRECURRULE_AddLegToWholeSeriesIncludesTheEditedOccurrence() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        XCTAssertEqual(cal.component(.weekday, from: at(2027, 5, 3)), 2, "2027-05-03 is a Monday")
        let far = series.occurrenceID(dayKey: 20270503)
        let window = [20261102, 20261109, 20261116].map { series.occurrenceID(dayKey: $0) }

        // The edited occurrence is six months ahead: the preview lists it besides the window occurrences.
        let preview = try XCTUnwrap(store.previewSeriesLegAdd(activityId: far, role: .arrival))
        XCTAssertEqual(preview.eligibleIds, window + [far])
        XCTAssertEqual(preview.wouldAddIds, window + [far])
        XCTAssertFalse(preview.eligibleIds.contains(series.occurrenceID(dayKey: 20261123)), "day 21 is outside the window")

        let result = await store.addLegToSeries(editedActivityId: far, seriesId: series.id, role: .arrival, outerPlace: home,
                                                mode: .car, bufferMinutes: 5, notifyLeadMinutes: 10,
                                                targetActivityIds: preview.eligibleIds, editedDetaches: false)
        XCTAssertEqual(result.added, 4, "added counts every leg made, the edited occurrence's included")
        XCTAssertEqual(store.events.count, 4)
        let farLeg = try XCTUnwrap(store.legs(of: far).outbound)
        XCTAssertEqual(farLeg.linkedActivityId, far)
        XCTAssertEqual(farLeg.recurrenceId, series.id)
        for occurrence in window { XCTAssertNotNil(store.legs(of: occurrence).outbound) }
        XCTAssertNil(store.legs(of: series.occurrenceID(dayKey: 20261123)).outbound)
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116)
        XCTAssertEqual(store.activities.count, 0, "nothing was materialized: the edited occurrence was not detached")

        // An occurrence that already started is not offered (the window ones after the clock still are).
        let late = fixtureStore()
        let noon = at(2026, 11, 2, 12)
        late.replanNow = { noon }
        XCTAssertTrue(late.addSeries(series))
        let early = try XCTUnwrap(late.previewSeriesLegAdd(activityId: window[0], role: .arrival))
        XCTAssertEqual(early.eligibleIds, [window[1], window[2]], "Nov 2 09:00 is before the clock")
    }

    // MARK: AC-015.2-4 and 7 - the whole series: move and leg drag

    func testRECURRULE_WholeSeriesMoveShiftsTimeOfDayAndClamps() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let (nov2, nov9, nov16) = (series.occurrenceID(dayKey: 20261102), series.occurrenceID(dayKey: 20261109),
                                   series.occurrenceID(dayKey: 20261116))
        try await addBothLegs(store, series, edited: nov2)
        // Nov 16 is edited before the move: a stored copy and its legs are not part of the series any more.
        XCTAssertTrue(store.modifyActivity(id: nov16, newTitle: "Standup (moved)"))
        // The clock is later than the first Mondays, so they are past ones (L15: they are redrawn too).
        let later = at(2026, 12, 1, 8)
        store.replanNow = { later }

        store.moveActivity(try XCTUnwrap(store.activity(id: nov9)), byMinutes: 60, wholeSeries: true)
        XCTAssertEqual(store.series[0].startMinute, 600)
        XCTAssertEqual(store.series[0].endMinute, 630)
        XCTAssertEqual(store.series[0].endDayDistance, 0)
        for date in [(2026, 11, 2), (2026, 11, 9), (2026, 11, 23), (2026, 11, 30), (2026, 12, 7)] {
            let block = try XCTUnwrap(store.activities(on: at(date.0, date.1, date.2)).first, "\(date)")
            XCTAssertEqual(block.startDate, at(date.0, date.1, date.2, 10))
            XCTAssertEqual(block.endDate, at(date.0, date.1, date.2, 10, 30))
        }
        // The stored copy of Nov 16 keeps its time.
        XCTAssertEqual(store.activities(on: at(2026, 11, 16)).map(\.title), ["Standup (moved)"])
        XCTAssertEqual(store.activities(on: at(2026, 11, 16)).first?.startDate, at(2026, 11, 16, 9))
        // The legs of the unstored occurrences were shifted by the same hour; the copy's legs were not.
        for (occurrence, d) in [(nov2, 2), (nov9, 9)] {
            XCTAssertEqual(store.legs(of: occurrence).outbound?.arrivalDate, at(2026, 11, d, 10))
            // The estimate is 900 seconds and the buffer 5 minutes, so the departure is 20 minutes before the arrival.
            XCTAssertEqual(store.legs(of: occurrence).outbound?.departureDate, at(2026, 11, d, 9, 40))
            XCTAssertEqual(store.legs(of: occurrence).return?.departureDate, at(2026, 11, d, 10, 30))
        }
        XCTAssertEqual(store.legs(of: nov16).outbound?.arrivalDate, at(2026, 11, 16, 9))
        XCTAssertEqual(store.legs(of: nov16).return?.departureDate, at(2026, 11, 16, 9, 30))
        XCTAssertEqual(store.events.count, 6, "no leg was made or removed")
        // The move is on the disk.
        XCTAssertEqual(relaunched().series.first?.startMinute, 600)

        // +900 minutes from 09:00 is clamped to 23:59; the end wraps past midnight and stays 30 minutes later.
        let up = fixtureStore()
        XCTAssertTrue(up.addSeries(series))
        up.moveActivity(try XCTUnwrap(up.activity(id: nov9)), byMinutes: 900, wholeSeries: true)
        XCTAssertEqual(up.series[0].startMinute, 1439)
        XCTAssertEqual(up.series[0].endMinute, 29)
        XCTAssertEqual(up.series[0].endDayDistance, 1)
        let wrapped = try XCTUnwrap(up.activities(in: DateInterval(start: at(2026, 11, 9), end: at(2026, 11, 10))).first)
        XCTAssertEqual(wrapped.startDate, at(2026, 11, 9, 23, 59))
        XCTAssertEqual(wrapped.endDate, at(2026, 11, 10, 0, 29))
        // -600 minutes is clamped to 00:00, the end 30 minutes later on the same day.
        let down = fixtureStore()
        XCTAssertTrue(down.addSeries(series))
        down.moveActivity(try XCTUnwrap(down.activity(id: nov9)), byMinutes: -600, wholeSeries: true)
        XCTAssertEqual(down.series[0].startMinute, 0)
        XCTAssertEqual(down.series[0].endMinute, 30)
        XCTAssertEqual(down.series[0].endDayDistance, 0)
        XCTAssertEqual(down.activities(on: at(2026, 11, 9)).first?.endDate, at(2026, 11, 9, 0, 30))
    }

    func testRECURRULE_WholeSeriesMoveDoesNotBringBackADeletedLeg() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let (nov2, nov9, nov16) = (series.occurrenceID(dayKey: 20261102), series.occurrenceID(dayKey: 20261109),
                                   series.occurrenceID(dayKey: 20261116))
        let preview = try XCTUnwrap(store.previewSeriesLegAdd(activityId: nov2, role: .arrival))
        let made = await store.addLegToSeries(editedActivityId: nov2, seriesId: series.id, role: .arrival, outerPlace: home,
                                              mode: .car, bufferMinutes: 5, notifyLeadMinutes: 10,
                                              targetActivityIds: preview.eligibleIds, editedDetaches: false)
        XCTAssertEqual(made.added, 3)
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116)
        // The user deletes the leg of Nov 9 by hand.
        store.deleteEvent(try XCTUnwrap(store.legs(of: nov9).outbound))
        XCTAssertEqual(store.events.count, 2)

        store.moveActivity(try XCTUnwrap(store.activity(id: nov2)), byMinutes: 60, wholeSeries: true)
        XCTAssertEqual(store.series[0].startMinute, 600, "the move happened")
        XCTAssertNil(store.legs(of: nov9).outbound, "the deleted leg was not made again")
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.legs(of: nov2).outbound?.arrivalDate, at(2026, 11, 2, 10), "the others moved with the series")
        XCTAssertEqual(store.legs(of: nov16).outbound?.arrivalDate, at(2026, 11, 16, 10))
        // The mark is not reset by the move, so the next fill does not bring the deleted leg back (M5a).
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116)
        await store.fillSeriesLegs()
        XCTAssertNil(store.legs(of: nov9).outbound, "the next fill did not recreate the deleted leg")
        XCTAssertEqual(store.events.count, 2)
    }

    func testRECURRULE_WholeSeriesLegDragMovesTheRuleMinutes() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let (nov2, nov9, nov16) = (series.occurrenceID(dayKey: 20261102), series.occurrenceID(dayKey: 20261109),
                                   series.occurrenceID(dayKey: 20261116))
        try await addBothLegs(store, series, edited: nov2)

        // A return leg dragged one grid step down (the grid turns a request of 15 into 20, so 10 is used): the end of every
        // occurrence moves 10 minutes, the start does not, the existing return legs follow, and the alarms are rescheduled once.
        let reschedules = store.drvRescheduleCount
        store.adjustTravelLeg(try XCTUnwrap(store.legs(of: nov9).return), byMinutes: 10, wholeSeries: true)
        XCTAssertEqual(store.series[0].startMinute, 540)
        XCTAssertEqual(store.series[0].endMinute, 580)
        XCTAssertEqual(store.series[0].endDayDistance, 0)
        XCTAssertEqual(store.drvRescheduleCount, reschedules + 1)
        for (occurrence, d) in [(nov2, 2), (nov9, 9), (nov16, 16)] {
            XCTAssertEqual(store.legs(of: occurrence).return?.departureDate, at(2026, 11, d, 9, 40))
            XCTAssertEqual(store.legs(of: occurrence).outbound?.arrivalDate, at(2026, 11, d, 9), "the outbound legs stay")
        }
        XCTAssertEqual(store.activities(on: at(2026, 11, 23)).first?.endDate, at(2026, 11, 23, 9, 40))
        XCTAssertEqual(store.activities(on: at(2026, 11, 23)).first?.startDate, at(2026, 11, 23, 9))
        XCTAssertTrue(store.activities.isEmpty, "a whole-series drag materializes nothing")

        // An outbound leg dragged 10 minutes up: the start of every occurrence moves, the end does not.
        let more = store.drvRescheduleCount
        store.adjustTravelLeg(try XCTUnwrap(store.legs(of: nov16).outbound), byMinutes: -10, wholeSeries: true)
        XCTAssertEqual(store.series[0].startMinute, 530)
        XCTAssertEqual(store.series[0].endMinute, 580)
        XCTAssertEqual(store.drvRescheduleCount, more + 1)
        for (occurrence, d) in [(nov2, 2), (nov9, 9), (nov16, 16)] {
            XCTAssertEqual(store.legs(of: occurrence).outbound?.arrivalDate, at(2026, 11, d, 8, 50))
            XCTAssertEqual(store.legs(of: occurrence).return?.departureDate, at(2026, 11, d, 9, 40), "the return legs stay")
        }
        XCTAssertEqual(store.activities(on: at(2026, 11, 30)).first?.startDate, at(2026, 11, 30, 8, 50))
        XCTAssertEqual(relaunched().series.first?.startMinute, 530)

        // A drag that would make an occurrence longer than 24 hours is clamped to exactly 24 hours.
        let long = fixtureStore()
        long.drvTravelLookupOverride = { _, _, _ in 900 }
        XCTAssertTrue(long.addSeries(series))
        try await addBothLegs(long, series, edited: nov2)
        long.adjustTravelLeg(try XCTUnwrap(long.legs(of: nov9).return), byMinutes: 1500, wholeSeries: true)
        XCTAssertEqual(long.series[0].startMinute, 540)
        XCTAssertEqual(long.series[0].endMinute, 540)
        XCTAssertEqual(long.series[0].endDayDistance, 1)
        let day = try XCTUnwrap(long.activities(in: DateInterval(start: at(2026, 11, 9), end: at(2026, 11, 10))).first)
        XCTAssertEqual(day.endDate.timeIntervalSince(day.startDate), 86400)
        XCTAssertEqual(long.legs(of: nov9).return?.departureDate, at(2026, 11, 10, 9))
    }

    func testRECURRULE_LegacyStoredSeriesStillDeletesAndMoves() throws {
        let store = fixtureStore()
        let rid = UUID()
        var blocks: [ActivityBlock] = []
        for d in [2, 9, 16] {
            var block = stored("Old", at(2026, 11, d, 9), at(2026, 11, d, 9, 30), place: office)
            block.recurrenceId = rid
            blocks.append(block)
        }
        store.activities.append(contentsOf: blocks)
        for block in blocks {
            for role in [ScheduleAnchor.arrival, ScheduleAnchor.departure] {
                var e = ScheduledEvent(title: "Old", origin: home, destination: office,
                                       arrivalDate: role == .departure ? block.endDate.addingTimeInterval(900) : block.startDate,
                                       mode: .car, bufferMinutes: 0, notifyLeadMinutes: 10)
                e.anchor = role
                e.departureDate = role == .departure ? block.endDate : block.startDate.addingTimeInterval(-900)
                e.travelSeconds = 900
                e.linkedActivityId = block.id
                e.recurrenceId = rid
                store.events.append(e)
            }
        }
        // A computed series beside it must not be touched by any of this.
        let computed = standup()
        XCTAssertTrue(store.addSeries(computed))

        // The whole-series move is the base's: every stored sibling and its legs move, the members stay members.
        store.moveActivity(blocks[1], byMinutes: 30, wholeSeries: true)
        XCTAssertEqual(store.activities.map(\.startDate).sorted(), [2, 9, 16].map { at(2026, 11, $0, 9, 30) })
        XCTAssertTrue(store.activities.allSatisfy { $0.recurrenceId == rid })
        XCTAssertEqual(store.legs(of: blocks[0].id).outbound?.arrivalDate, at(2026, 11, 2, 9, 30))
        XCTAssertEqual(store.series[0].startMinute, 540, "the computed series did not move")

        // The whole-series leg drag is the base's too: every stored sibling's end and its return leg move.
        store.adjustTravelLeg(try XCTUnwrap(store.legs(of: blocks[0].id).return), byMinutes: 10, wholeSeries: true)
        XCTAssertEqual(store.activities.map(\.endDate).sorted(), [2, 9, 16].map { at(2026, 11, $0, 10, 10) })
        XCTAssertEqual(store.series[0].endMinute, 570)

        // Delete Entire Series with the shared id removes the stored members and their legs, and only them.
        store.deleteRecurringSeries(rid)
        XCTAssertTrue(store.activities.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.series.count, 1)
        XCTAssertEqual(store.activities(on: at(2026, 11, 9)).map(\.title), ["Standup"])
    }

    // MARK: M5a - the leg window fill (AC-001 row 3, AC-015 5(b), AC-016)

    /// Weekly on Monday 09:00-09:30 from Nov 2 with a place and a leg plan: outbound from Home, return to Home, by car.
    private func plannedStandup(outbound: Bool = true, back: Bool = true) -> RepeatSeries {
        var s = standup()
        s.legPlan = LegPlan(outboundFrom: outbound ? home : nil, returnTo: back ? home : nil, outboundMode: .car,
                            returnMode: .car, bufferMinutes: 5, notifyLeadMinutes: 10, notifyEnabled: true)
        return s
    }

    /// Every day from a first day, 30 minutes long from `startMinute`, at the office, with a leg plan.
    private func plannedDaily(first: Int, title: String, startMinute: Int, outbound: Bool = true, back: Bool = true,
                              buffer: Int = 5, lead: Int = 10) -> RepeatSeries {
        RepeatSeries(id: RepeatSeries.newID(), title: title, location: office,
                     rule: RecurrenceRule(weekdays: [], unit: .daily), lunarCalendar: nil,
                     firstDayKey: first, lastDayKey: nil, startMinute: startMinute, endMinute: startMinute + 30,
                     endDayDistance: 0, syncToCalendar: nil, skippedDayKeys: [],
                     legPlan: LegPlan(outboundFrom: outbound ? home : nil, returnTo: back ? home : nil,
                                      outboundMode: .car, returnMode: .car, bufferMinutes: buffer,
                                      notifyLeadMinutes: lead, notifyEnabled: true),
                     legsFilledThroughDayKey: nil)
    }

    /// The New Activity card as the screen fills it for a repeat with both travel legs on (the toggles stand once the
    /// place carries coordinates; the origin and the destination are Home).
    private func makeLegForm(start: Date, end: Date, title: String = "Standup") -> LegCardForm {
        var f = makeForm(start: start, end: end, place: office)
        f.setTitleText(field: rowId(f, "title"), text: title)
        f.choose(field: rowId(f, LegRowKeys.outboundEnabled), value: "true")
        f.choose(field: rowId(f, LegRowKeys.originQuery), value: home.name, place: home)
        f.choose(field: rowId(f, LegRowKeys.returnEnabled), value: "true")
        f.choose(field: rowId(f, LegRowKeys.returnQuery), value: home.name, place: home)
        return f
    }

    private func legCount(_ store: Store, _ occurrence: UUID, _ role: ScheduleAnchor) -> Int {
        store.events.filter { $0.linkedActivityId == occurrence && ($0.anchor ?? .arrival) == role }.count
    }

    /// The day keys of the occurrences the legs of a role are linked to, sorted.
    private func legDayKeys(_ store: Store, _ role: ScheduleAnchor) -> [Int] {
        store.events.filter { ($0.anchor ?? .arrival) == role }
            .compactMap { $0.linkedActivityId.flatMap { RepeatSeries.decode($0)?.dayKey } }.sorted()
    }

    // MARK: AC-001 row 3 - the travel toggles make legs for the window only

    func testRECURRULE_SaveWithTravelTogglesMakesLegsForTheWindowOnly() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        var f = makeLegForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&f, "daily")
        XCTAssertTrue(f.card.isReady)
        XCTAssertNotNil(f.activeRecurrence)

        let saved = await store.saveManualActivity(f, calendarDefault: false)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.series.count, 1)
        let series = try XCTUnwrap(store.series.first)
        XCTAssertEqual(series.legPlan?.outboundFrom, home)
        XCTAssertEqual(series.legPlan?.returnTo, home)
        XCTAssertEqual(store.activities.count, 0)
        XCTAssertEqual(store.events.count, 30, "15 days x 2 legs through the window, not one pair per occurrence")
        XCTAssertEqual(Set(legDayKeys(store, .arrival)), Set((2...16).map { 20261100 + $0 }))
        XCTAssertEqual(Set(legDayKeys(store, .departure)), Set((2...16).map { 20261100 + $0 }))
        XCTAssertEqual(series.legsFilledThroughDayKey, 20261116)
        XCTAssertEqual(store.drvTravelLookupCount, 2, "one lookup per direction")
        XCTAssertEqual(relaunched().events.count, 30, "the legs reached events.json")
    }

    // MARK: AC-016 rows 1-2 - fifteen days of legs

    func testRECURRULE_LegWindowOnlyFifteenDays() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        var f = makeLegForm(start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        commit(&f, "every Monday")
        let saved = await store.saveManualActivity(f, calendarDefault: false)
        XCTAssertTrue(saved)
        let series = try XCTUnwrap(store.series.first)

        // Nov 2, 9 and 16 (Nov 16 is day 14, so today + 14 inclusive is 15 days); none for Nov 23.
        XCTAssertEqual(store.events.count, 6)
        for d in [20261102, 20261109, 20261116] {
            let occurrence = series.occurrenceID(dayKey: d)
            let pair = store.legs(of: occurrence)
            XCTAssertEqual(pair.outbound?.anchor, .arrival, "outbound of \(d)")
            XCTAssertEqual(pair.return?.anchor, .departure, "return of \(d)")
            XCTAssertEqual(store.events.filter { $0.linkedActivityId == occurrence }.count, 2)
        }
        XCTAssertTrue(store.events.filter { $0.linkedActivityId == series.occurrenceID(dayKey: 20261123) }.isEmpty)
        for leg in store.events {
            XCTAssertEqual(leg.recurrenceId, series.id)
            XCTAssertEqual(leg.travelSeconds, 900, "the other legs of a direction carry the looked-up time")
        }
        XCTAssertEqual(store.legs(of: series.occurrenceID(dayKey: 20261109)).return?.title, "Standup (return)")
        XCTAssertEqual(store.drvTravelLookupCount, 2, "one lookup per direction, the others are copied")
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116)
        XCTAssertEqual(relaunched().series.first?.legsFilledThroughDayKey, 20261116, "the mark is on the disk")
    }

    // MARK: AC-016 row 3 - the fill is idempotent and respects the high-water mark

    func testRECURRULE_FillIsIdempotentAndRespectsHighWaterMark() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = plannedStandup()
        XCTAssertTrue(store.addSeries(series))
        let (nov9, nov23) = (series.occurrenceID(dayKey: 20261109), series.occurrenceID(dayKey: 20261123))

        // An outbound leg added by hand to a window occurrence while the mark is still nil: no second outbound for it.
        let byHand = seriesLeg(series, 20261109, .arrival)
        store.events.append(byHand)
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 6, "the hand-made leg and five new ones")
        XCTAssertEqual(legCount(store, nov9, .arrival), 1)
        XCTAssertEqual(store.legs(of: nov9).outbound?.id, byHand.id)
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116)

        // The same fill the same day makes no new event.
        let ids = Set(store.events.map(\.id))
        let lookups = store.drvTravelLookupCount
        await store.fillSeriesLegs()
        XCTAssertEqual(Set(store.events.map(\.id)), ids)
        XCTAssertEqual(store.drvTravelLookupCount, lookups)

        // A week later only the legs of Nov 23 are added, and no lookup is made: stored legs of both directions exist.
        let week = at(2026, 11, 9, 8)
        store.replanNow = { week }
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 8)
        XCTAssertEqual(store.events.filter { $0.linkedActivityId == nov23 }.count, 2)
        XCTAssertEqual(store.drvTravelLookupCount, lookups, "the travel time is copied from a stored leg of the series")
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261123)
    }

    // MARK: AC-016 row 3b - two fills at once make each leg once

    func testRECURRULE_TwoFillsAtOnceMakeEachLegOnce() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let first = plannedStandup()
        XCTAssertTrue(store.addSeries(first))
        var gateCalls = 0
        var held: CheckedContinuation<Void, Never>?
        store.drvFillGate = {
            gateCalls += 1
            // Suspends on the first call only: the pass that `fillAgain` asks for reaches the gate too and must not wait.
            guard gateCalls == 1 else { return }
            await withCheckedContinuation { held = $0 }
        }

        // Call 1 is held at the gate; the test waits for the signal that it got there.
        let call1 = Task { await store.fillSeriesLegs() }
        var spins = 0
        while store.drvFillGateReached == 0, spins < 20_000 { await Task.yield(); spins += 1 }
        XCTAssertEqual(store.drvFillGateReached, 1, "call 1 reached the gate")
        XCTAssertNotNil(held)

        // Call 2 returns at once and writes nothing while call 1 is held.
        let before = store.events.count
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, before, "a call during a running fill makes nothing")
        XCTAssertEqual(store.drvFillGateReached, 1, "call 2 did not start a pass of its own")

        // A second series is saved while call 1 is held: its own save-time fill (call 3) also returns at once.
        var f = makeLegForm(start: at(2026, 11, 4, 18), end: at(2026, 11, 4, 19), title: "Gym")
        commit(&f, "every Wednesday")
        let saved = await store.saveManualActivity(f, calendarDefault: false)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.series.count, 2)
        XCTAssertEqual(store.events.count, before, "call 3 made nothing either")

        held?.resume()
        await call1.value

        // Each occurrence has one leg per role, and the second series has its legs too (the pass `fillAgain` asked for).
        XCTAssertEqual(store.events.count, 10, "Mondays Nov 2, 9, 16 and Wednesdays Nov 4, 11, two legs each")
        for d in [20261102, 20261109, 20261116] {
            let occurrence = first.occurrenceID(dayKey: d)
            XCTAssertEqual(legCount(store, occurrence, .arrival), 1, "outbound of \(d)")
            XCTAssertEqual(legCount(store, occurrence, .departure), 1, "return of \(d)")
        }
        let gym = try XCTUnwrap(store.series.first { $0.title == "Gym" })
        for d in [20261104, 20261111] {
            let occurrence = gym.occurrenceID(dayKey: d)
            XCTAssertEqual(legCount(store, occurrence, .arrival), 1, "Gym outbound of \(d)")
            XCTAssertEqual(legCount(store, occurrence, .departure), 1, "Gym return of \(d)")
        }
        XCTAssertEqual(store.drvFillGateReached, 2, "the second pass reached the gate and did not wait again")
        XCTAssertEqual(gateCalls, 2)
    }

    // MARK: AC-016 row 2 - the travel time is looked up once per direction and copied

    func testRECURRULE_FillReusesExistingTravelTime() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = plannedStandup()
        XCTAssertTrue(store.addSeries(series))
        var known = seriesLeg(series, 20261102, .arrival)
        known.travelSeconds = 600
        store.events.append(known)

        await store.fillSeriesLegs()
        // The outbound time comes from the stored leg (no lookup); the return direction has none and is looked up once.
        XCTAssertEqual(store.drvTravelLookupCount, 1)
        for d in [20261109, 20261116] {
            XCTAssertEqual(store.legs(of: series.occurrenceID(dayKey: d)).outbound?.travelSeconds, 600, "copied for \(d)")
        }
        for d in [20261102, 20261109, 20261116] {
            XCTAssertEqual(store.legs(of: series.occurrenceID(dayKey: d)).return?.travelSeconds, 900, "looked up once for \(d)")
        }
        // A fill that finds legs of both directions looks nothing up.
        let week = at(2026, 11, 9, 8)
        store.replanNow = { week }
        await store.fillSeriesLegs()
        XCTAssertEqual(store.drvTravelLookupCount, 1)
        XCTAssertEqual(store.legs(of: series.occurrenceID(dayKey: 20261123)).outbound?.travelSeconds, 600)
        XCTAssertEqual(store.legs(of: series.occurrenceID(dayKey: 20261123)).return?.travelSeconds, 900)
    }

    // MARK: AC-016 row 4 - a deleted leg does not come back

    func testRECURRULE_DeletedLegDoesNotReturn() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = plannedStandup()
        XCTAssertTrue(store.addSeries(series))
        let nov9 = series.occurrenceID(dayKey: 20261109)
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 6)

        store.deleteEvent(try XCTUnwrap(store.legs(of: nov9).outbound))
        XCTAssertEqual(store.events.count, 5)
        await store.fillSeriesLegs()
        XCTAssertNil(store.legs(of: nov9).outbound, "the day is at or below the high-water mark")
        XCTAssertNotNil(store.legs(of: nov9).return)
        XCTAssertEqual(store.events.count, 5)

        // Also after a relaunch: the mark is on the disk.
        let again = relaunched()
        let clock = fixtureClock
        again.replanNow = { clock }
        again.drvTravelLookupOverride = { _, _, _ in 900 }
        await again.fillSeriesLegs()
        XCTAssertEqual(again.events.count, 5)
        XCTAssertNil(again.legs(of: nov9).outbound)
    }

    // MARK: AC-016 row 5 - a skipped day gets no leg and none is recreated

    func testRECURRULE_SkippedDayGetsNoLegAndNoneIsRecreated() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = plannedStandup()
        XCTAssertTrue(store.addSeries(series))
        let nov9 = series.occurrenceID(dayKey: 20261109)
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 6)

        // The day is deleted after the fill: its legs go with it and the next fill makes nothing for it.
        store.deleteActivity(try XCTUnwrap(store.activity(id: nov9)))
        XCTAssertEqual(store.events.count, 4)
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 4)
        XCTAssertTrue(store.events.filter { $0.linkedActivityId == nov9 }.isEmpty)
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])

        // A day skipped before any fill never gets a leg either.
        let fresh = fixtureStore()
        fresh.drvTravelLookupOverride = { _, _, _ in 900 }
        var skipped = plannedStandup()
        skipped.skippedDayKeys = [20261109]
        XCTAssertTrue(fresh.addSeries(skipped))
        await fresh.fillSeriesLegs()
        XCTAssertEqual(fresh.events.count, 4)
        XCTAssertEqual(Set(legDayKeys(fresh, .arrival)), [20261102, 20261116])
        XCTAssertEqual(Set(legDayKeys(fresh, .departure)), [20261102, 20261116])
    }

    // MARK: AC-016 row 6 - old legs are pruned

    func testRECURRULE_OldLegsArePruned() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = plannedStandup()
        XCTAssertTrue(store.addSeries(series))
        let (nov2, nov9, nov16) = (series.occurrenceID(dayKey: 20261102), series.occurrenceID(dayKey: 20261109),
                                   series.occurrenceID(dayKey: 20261116))
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 6)
        // Nov 2 is edited, so it is a stored copy; its legs are not the series' legs to prune.
        XCTAssertTrue(store.modifyActivity(id: nov2, newTitle: "Standup (moved)"))
        XCTAssertEqual(store.events.filter { $0.linkedActivityId == nov2 }.count, 2)

        let later = at(2026, 12, 10, 8)
        store.replanNow = { later }
        await store.fillSeriesLegs()
        XCTAssertNil(store.legs(of: nov9).outbound, "older than 30 days")
        XCTAssertNil(store.legs(of: nov9).return)
        XCTAssertNotNil(store.legs(of: nov16).outbound, "Nov 16 is inside the 30 days")
        XCTAssertNotNil(store.legs(of: nov16).return)
        XCTAssertNotNil(store.legs(of: nov2).outbound, "a stored copy keeps its legs")
        XCTAssertNotNil(store.legs(of: nov2).return)
        // The new window (Dec 14 and Dec 21) got its legs.
        XCTAssertEqual(store.events.count, 2 + 2 + 4)
        XCTAssertEqual(Set(legDayKeys(store, .arrival)), [20261102, 20261116, 20261214, 20261221])
    }

    // MARK: AC-016 row 7 - at most sixty alarms (class B: reads the real clock)

    func testRECURRULE_AlarmsStayAtSixty() async throws {
        let d0 = classBMonday()
        let store = EmptyStore.make()
        let clock = d0.addingTimeInterval(8 * 3600)
        store.replanNow = { clock }
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        for (title, minute) in [("A", 540), ("B", 720), ("C", 900)] {
            XCTAssertTrue(store.addSeries(plannedDaily(first: key(d0), title: title, startMinute: minute, buffer: 0, lead: 0)))
        }
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 90, "3 series x 15 days x 2 legs")
        XCTAssertTrue(store.events.allSatisfy { ($0.departureDate ?? .distantPast) > clock }, "every leg is in the future")

        store.rescheduleNearestNotifications()
        let sorted = store.events.sorted {
            NotificationManager.alarmTime(departure: $0.departureDate!, leadMinutes: $0.notifyLeadMinutes)
                < NotificationManager.alarmTime(departure: $1.departureDate!, leadMinutes: $1.notifyLeadMinutes)
        }
        XCTAssertEqual(store.events.filter { $0.notificationId != nil }.count, 60)
        guard sorted.count > 60 else { return XCTFail("fewer than 61 legs") }
        XCTAssertTrue(sorted.prefix(60).allSatisfy { $0.notificationId != nil }, "the 60 earliest alarms are the ones scheduled")
        XCTAssertNil(sorted[60].notificationId, "the 61st alarm time has none")
        XCTAssertTrue(sorted.dropFirst(60).allSatisfy { $0.notificationId == nil })
    }

    // MARK: AC-016 row 8 - no place, no plan, one direction

    func testRECURRULE_SeriesWithoutPlaceOrPlanMakesNoLegs() async throws {
        // A plan without a place.
        let noPlace = fixtureStore()
        noPlace.drvTravelLookupOverride = { _, _, _ in 900 }
        var placeless = plannedStandup()
        placeless.location = nil
        XCTAssertTrue(noPlace.addSeries(placeless))
        await noPlace.fillSeriesLegs()
        XCTAssertTrue(noPlace.events.isEmpty)
        XCTAssertNil(noPlace.series[0].legsFilledThroughDayKey)

        // A place without a plan.
        let noPlan = fixtureStore()
        noPlan.drvTravelLookupOverride = { _, _, _ in 900 }
        XCTAssertTrue(noPlan.addSeries(standup()))
        await noPlan.fillSeriesLegs()
        XCTAssertTrue(noPlan.events.isEmpty)
        XCTAssertNil(noPlan.series[0].legsFilledThroughDayKey)

        // A plan with only an outbound place makes outbound legs only (the positive control for the two rows above).
        let outboundOnly = fixtureStore()
        outboundOnly.drvTravelLookupOverride = { _, _, _ in 900 }
        XCTAssertTrue(outboundOnly.addSeries(plannedStandup(back: false)))
        await outboundOnly.fillSeriesLegs()
        XCTAssertEqual(outboundOnly.events.count, 3)
        XCTAssertEqual(legDayKeys(outboundOnly, .arrival), [20261102, 20261109, 20261116])
        XCTAssertTrue(legDayKeys(outboundOnly, .departure).isEmpty, "a nil returnTo makes no return leg")

        // And a plan with only a return place makes return legs only.
        let returnOnly = fixtureStore()
        returnOnly.drvTravelLookupOverride = { _, _, _ in 900 }
        XCTAssertTrue(returnOnly.addSeries(plannedStandup(outbound: false)))
        await returnOnly.fillSeriesLegs()
        XCTAssertEqual(returnOnly.events.count, 3)
        XCTAssertEqual(legDayKeys(returnOnly, .departure), [20261102, 20261109, 20261116])
        XCTAssertTrue(legDayKeys(returnOnly, .arrival).isEmpty)
    }

    // MARK: AC-016 row 9 - the background path fills legs (class B: reads the real clock)

    func testRECURRULE_BackgroundPathFillsLegs() async throws {
        let d0 = classBMonday()
        func day(_ n: Int, _ hour: Int = 0) -> Date { d0.addingTimeInterval(Double(n) * 86400 + Double(hour) * 3600) }
        let store = EmptyStore.make()
        var clock = day(0, 8)
        store.replanNow = { clock }
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        var series = plannedStandup()
        series.firstDayKey = key(d0)
        XCTAssertTrue(store.addSeries(series))
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 6, "D0, D0+7, D0+14")

        clock = day(7, 8)
        let (lookups, reschedules) = (store.drvTravelLookupCount, store.drvRescheduleCount)
        await store.backgroundRefresh()
        XCTAssertEqual(store.events.count, 8)
        XCTAssertEqual(store.events.filter { $0.linkedActivityId == series.occurrenceID(dayKey: key(day(21))) }.count, 2,
                       "the legs of D0+21 came from the fill in the background path")
        XCTAssertEqual(store.drvTravelLookupCount, lookups, "the refresh selects nothing and the fill copies stored times")
        XCTAssertEqual(store.drvRescheduleCount, reschedules + 2, "one at the end of the fill, one at the end of the refresh")
    }

    // MARK: AC-016 row w - the fill skips a role that has a leg

    func testRECURRULE_FillSkipsARoleThatHasALeg() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = plannedStandup()
        XCTAssertTrue(store.addSeries(series))
        let (nov2, nov9, nov16) = (series.occurrenceID(dayKey: 20261102), series.occurrenceID(dayKey: 20261109),
                                   series.occurrenceID(dayKey: 20261116))
        // Legs made by hand before any fill: a return leg for Nov 2 and an outbound leg for Nov 9.
        let back = seriesLeg(series, 20261102, .departure)
        let out = seriesLeg(series, 20261109, .arrival)
        store.events.append(contentsOf: [back, out])

        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 6)
        for occurrence in [nov2, nov9, nov16] {
            XCTAssertEqual(legCount(store, occurrence, .arrival), 1, "one outbound leg for \(occurrence)")
            XCTAssertEqual(legCount(store, occurrence, .departure), 1, "one return leg for \(occurrence)")
        }
        XCTAssertEqual(store.legs(of: nov2).return?.id, back.id, "the hand-made leg was not replaced")
        XCTAssertEqual(store.legs(of: nov9).outbound?.id, out.id)
        XCTAssertEqual(store.drvTravelLookupCount, 0, "both directions had a stored leg to copy the time from")
    }

    // MARK: AC-015 5(b), 5(b2) - the fill after a whole-series leg add

    func testRECURRULE_SecondFillAfterWholeSeriesLegAddIsIdempotent() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        let nov2 = series.occurrenceID(dayKey: 20261102)
        let preview = try XCTUnwrap(store.previewSeriesLegAdd(activityId: nov2, role: .arrival))
        let made = await store.addLegToSeries(editedActivityId: nov2, seriesId: series.id, role: .arrival, outerPlace: home,
                                              mode: .car, bufferMinutes: 5, notifyLeadMinutes: 10,
                                              targetActivityIds: preview.eligibleIds, editedDetaches: false)
        XCTAssertEqual(made.added, 3)
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116)
        let ids = Set(store.events.map(\.id))

        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 3, "a second fill leaves the events as they are")
        XCTAssertEqual(Set(store.events.map(\.id)), ids)
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116)
    }

    func testRECURRULE_AddRoleToASeriesThatHasAMarkKeepsTheMark() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = plannedDaily(first: 20261102, title: "Daily", startMinute: 540, back: false)
        XCTAssertTrue(store.addSeries(series))
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 15, "outbound legs for Nov 2 ... Nov 16")
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116)

        // Three days later a return role is added to the whole series.
        let later = at(2026, 11, 5, 8)
        store.replanNow = { later }
        let nov5 = series.occurrenceID(dayKey: 20261105)
        let preview = try XCTUnwrap(store.previewSeriesLegAdd(activityId: nov5, role: .departure))
        XCTAssertEqual(preview.eligibleIds.count, 15, "Nov 5 ... Nov 19")
        let made = await store.addLegToSeries(editedActivityId: nov5, seriesId: series.id, role: .departure, outerPlace: home,
                                              mode: .car, bufferMinutes: 0, notifyLeadMinutes: 10,
                                              targetActivityIds: preview.eligibleIds, editedDetaches: false)
        XCTAssertEqual(made.added, 15)
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116, "an existing mark is left alone")
        XCTAssertEqual(store.series[0].legPlan?.returnTo, home)
        XCTAssertEqual(legDayKeys(store, .departure), (5...19).map { 20261100 + $0 })

        // The next fill makes the outbound legs of Nov 17 ... Nov 19 and no second return leg.
        await store.fillSeriesLegs()
        XCTAssertEqual(legDayKeys(store, .arrival), (2...19).map { 20261100 + $0 })
        XCTAssertEqual(legDayKeys(store, .departure), (5...19).map { 20261100 + $0 }, "no duplicate return leg")
        XCTAssertEqual(store.events.count, 18 + 15)
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261119)
    }

    // MARK: M5b - the Apple Calendar mirror window (AC-017, AC-004 row 4)

    /// A real mirror over the fake backend and a temporary link file, attached to the store, with the store's clock.
    private func mirrorRig(_ store: Store) -> (fake: FakeCalendarBackend, mirror: AppleCalendarMirror, url: URL) {
        let fake = FakeCalendarBackend()
        let url = CalendarTestSupport.freshLinksURL()
        linkURLs.append(url)
        let mirror = AppleCalendarMirror(backend: fake, linksURL: url, now: { store.replanNow() })
        store.attachCalendar(mirror)
        return (fake, mirror, url)
    }

    private func settle(_ mirror: AppleCalendarMirror, file: StaticString = #filePath, line: UInt = #line) async {
        let settled = await CalendarTestSupport.settle(mirror)
        XCTAssertTrue(settled, "the mirror did not settle", file: file, line: line)
    }

    private func links(_ url: URL) throws -> [String: CalendarLink] {
        try XCTUnwrap(CalendarTestSupport.loadFile(url)).links
    }

    /// The nine Mondays of the window that opens on the fixture clock: Nov 2 ... Dec 28 2026.
    private var firstWindowMondays: [(Int, Int)] { [(11, 2), (11, 9), (11, 16), (11, 23), (11, 30), (12, 7), (12, 14), (12, 21), (12, 28)] }

    // MARK: AC-017 row 1 - the mirror gets the window only

    func testRECURRULE_MirrorGetsWindowOnly() async throws {
        let store = fixtureStore()
        let rig = mirrorRig(store)
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        await settle(rig.mirror)

        let starts = rig.fake.events.values.map(\.start).sorted()
        XCTAssertEqual(starts, firstWindowMondays.map { at(2026, $0.0, $0.1, 9) }, "Nov 2 ... Dec 28, none for January")
        XCTAssertEqual(rig.fake.createCalls, 9)
        XCTAssertEqual(Set(try links(rig.url).keys),
                       Set(firstWindowMondays.map { series.occurrenceID(dayKey: 20260000 + $0.0 * 100 + $0.1).uuidString }))
        // What the store hands the mirror: nine occurrences, although the series goes on (positive control).
        XCTAssertEqual(store.mirrorActivities().count, 9)
        XCTAssertEqual(store.activities(in: DateInterval(start: at(2027, 1, 4), end: at(2027, 1, 5))).count, 1)
    }

    // MARK: AC-017 row 2 - a link outside the window is kept

    func testRECURRULE_OutOfWindowLinkIsRetained() async throws {
        let store = fixtureStore()
        let rig = mirrorRig(store)
        XCTAssertTrue(store.addSeries(standup()))
        await settle(rig.mirror)
        XCTAssertEqual(rig.fake.createCalls, 9)

        // The window moves on to Jan 4 ... Mar 1 2027; the November occurrences are live and out of it.
        let later = at(2027, 1, 4, 8)
        store.replanNow = { later }
        store.reconcileCalendar()
        await settle(rig.mirror)

        XCTAssertEqual(rig.fake.removeCalls, 0, "a link outside the window is not removed")
        XCTAssertEqual(rig.fake.createCalls, 18, "nine events for the new window")
        let starts = rig.fake.events.values.map(\.start).sorted()
        XCTAssertEqual(starts.count, 18)
        XCTAssertEqual(starts.first, at(2026, 11, 2, 9))
        XCTAssertEqual(starts.last, at(2027, 3, 1, 9))
        XCTAssertEqual(try links(rig.url).count, 18)
    }

    // MARK: AC-017 row 3 - a skipped day and a deleted series lose their links

    func testRECURRULE_SkippedAndDeletedLinksAreRemoved() async throws {
        let store = fixtureStore()
        let rig = mirrorRig(store)
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        await settle(rig.mirror)
        XCTAssertEqual(rig.fake.createCalls, 9)

        let nov9 = series.occurrenceID(dayKey: 20261109)
        store.deleteActivity(try XCTUnwrap(store.activity(id: nov9)))
        await settle(rig.mirror)
        XCTAssertEqual(rig.fake.removeCalls, 1, "the skipped occurrence's event is removed")
        XCTAssertNil(try links(rig.url)[nov9.uuidString])
        XCTAssertEqual(try links(rig.url).count, 8)
        XCTAssertEqual(rig.fake.events.count, 8)

        store.deleteRecurringSeries(series.id)
        await settle(rig.mirror)
        XCTAssertEqual(rig.fake.removeCalls, 9, "every link of the deleted series is removed")
        XCTAssertTrue(try links(rig.url).isEmpty)
        XCTAssertTrue(rig.fake.events.isEmpty)
    }

    // MARK: AC-017 row 5 and AC-004 row 4 - an unreadable series file keeps every link

    func testRECURRULE_UnreadableFileKeepsEveryLink() async throws {
        let store = fixtureStore()
        let rig = mirrorRig(store)
        XCTAssertTrue(store.addSeries(standup()))
        await settle(rig.mirror)
        XCTAssertEqual(try links(rig.url).count, 9)

        // A relaunch on a series file that cannot be read: no series, the flag is up, the mirror is the same.
        try write(Data("not json".utf8), "series.json")
        let clock = fixtureClock
        let again = relaunched()
        again.replanNow = { clock }
        XCTAssertTrue(again.seriesLoadFailed)
        XCTAssertTrue(again.series.isEmpty)
        let mirror = AppleCalendarMirror(backend: rig.fake, linksURL: rig.url, now: { again.replanNow() })
        again.attachCalendar(mirror)
        again.reconcileCalendar()
        await settle(mirror)
        XCTAssertEqual(rig.fake.removeCalls, 0, "no link is removed while the file is unreadable")
        XCTAssertEqual(try links(rig.url).count, 9)
        XCTAssertEqual(rig.fake.events.count, 9)

        // Positive control: once the bad file is backed up and the new list written, the protection ends and the links
        // of the series that were lost with it are removed (design 3.4, accepted).
        XCTAssertTrue(again.saveSeries())
        XCTAssertFalse(again.seriesLoadFailed)
        await settle(mirror)
        XCTAssertEqual(rig.fake.removeCalls, 9)
        XCTAssertTrue(try links(rig.url).isEmpty)
    }

    // MARK: AC-017 row 4 - the planner without `retains` is unchanged

    func testRECURRULE_PlannerWithoutRetainsIsUnchanged() {
        func link(_ id: String) -> CalendarLink {
            CalendarLink(eventId: "event-" + id, signature: CalendarDraft(stored("Linked", at(2026, 11, 3, 9), at(2026, 11, 3, 10))))
        }
        let orphan = UUID().uuidString
        let other = UUID().uuidString
        var file = CalendarLinkFile()
        file.links[orphan] = link(orphan)
        file.links[other] = link(other)
        let now = fixtureClock

        // Without the parameter, and with one that keeps nothing: every link of an activity that is gone is removed.
        let plain = CalendarPlanner.plan(activities: [], file: file, now: now)
        XCTAssertEqual(plain, CalendarPlanner.plan(activities: [], file: file, now: now, retains: { _ in false }))
        XCTAssertEqual(Set(plain.removes.map(\.activityId)), [orphan, other])
        XCTAssertTrue(plain.updates.isEmpty)
        XCTAssertTrue(plain.creates.isEmpty)

        // With a closure, the orphans are asked about, and a link it keeps is not removed.
        var asked: [String] = []
        let keeping = CalendarPlanner.plan(activities: [], file: file, now: now, retains: { key in
            asked.append(key)
            return key == other
        })
        XCTAssertEqual(keeping.removes.map(\.activityId), [orphan])
        XCTAssertEqual(Set(asked), [orphan, other])

        // It is asked about orphans only: the link of an activity that is in the list and has its sync turned off is
        // removed whatever the closure says, and the closure is not asked about that key.
        var off = stored("Off", at(2026, 11, 3, 9), at(2026, 11, 3, 10))
        off.syncToCalendar = false
        var offFile = CalendarLinkFile()
        offFile.links[off.id.uuidString] = link(off.id.uuidString)
        asked = []
        let seenPlan = CalendarPlanner.plan(activities: [off], file: offFile, now: now, retains: { key in
            asked.append(key)
            return true
        })
        XCTAssertEqual(seenPlan.removes.map(\.activityId), [off.id.uuidString])
        XCTAssertTrue(asked.isEmpty)
    }

    // MARK: AC-017 row 6 - a materialized copy is updated in place

    func testRECURRULE_MaterializedCopyIsUpdatedInPlace() async throws {
        let store = fixtureStore()
        let rig = mirrorRig(store)
        let series = standup()
        XCTAssertTrue(store.addSeries(series))
        await settle(rig.mirror)
        let nov9 = series.occurrenceID(dayKey: 20261109)
        let before = try XCTUnwrap(try links(rig.url)[nov9.uuidString], "the Nov 9 occurrence has a link")

        XCTAssertTrue(store.modifyActivity(id: nov9, newTitle: "Standup (moved)"))
        XCTAssertEqual(store.activities.count, 1, "the occurrence is a stored copy now")
        await settle(rig.mirror)

        let after = try XCTUnwrap(try links(rig.url)[nov9.uuidString])
        XCTAssertEqual(after.eventId, before.eventId, "same key, same event")
        XCTAssertEqual(rig.fake.events[after.eventId]?.title, "Standup (moved)")
        XCTAssertEqual(rig.fake.createCalls, 9, "not created again")
        XCTAssertEqual(rig.fake.removeCalls, 0, "not removed")
        XCTAssertEqual(rig.fake.updateCalls, 1)
        XCTAssertEqual(try links(rig.url).count, 9)
    }

    // MARK: AC-017 row 7 - `retains` is true only for a live occurrence

    func testRECURRULE_RetainsIsTrueOnlyForLiveOccurrences() async throws {
        let store = fixtureStore()
        let rig = mirrorRig(store)
        let mondays = standup()
        let wednesdays = weekly("Gym", weekday: 4, startMinute: 18 * 60, endMinute: 19 * 60, first: 20261104, last: 20261125)
        XCTAssertTrue(store.addSeries(mondays))
        XCTAssertTrue(store.addSeries(wednesdays))
        await settle(rig.mirror)
        let retains = rig.mirror.retains

        // Live: a Monday in the window, a Monday years out, the last Wednesday of the second series.
        XCTAssertTrue(retains(mondays.occurrenceID(dayKey: 20261109).uuidString))
        XCTAssertTrue(retains(mondays.occurrenceID(dayKey: 20290305).uuidString))
        XCTAssertTrue(retains(wednesdays.occurrenceID(dayKey: 20261125).uuidString))
        // A valid day of the series that the rule does not produce (a Tuesday of a Monday rule).
        XCTAssertNotNil(store.series(forOccurrence: mondays.occurrenceID(dayKey: 20261103)), "it passes the syntax check")
        XCTAssertFalse(retains(mondays.occurrenceID(dayKey: 20261103).uuidString))
        // Before the first day, after the last day.
        XCTAssertFalse(retains(mondays.occurrenceID(dayKey: 20261026).uuidString))
        XCTAssertFalse(retains(wednesdays.occurrenceID(dayKey: 20261202).uuidString))
        // A skipped day.
        let nov16 = mondays.occurrenceID(dayKey: 20261116)
        XCTAssertTrue(retains(nov16.uuidString))
        store.deleteActivity(try XCTUnwrap(store.activity(id: nov16)))
        XCTAssertFalse(retains(nov16.uuidString))
        // An unknown id, a string that is no id, a stored activity that is no occurrence.
        XCTAssertFalse(retains(UUID().uuidString))
        XCTAssertFalse(retains("not an id"))
        XCTAssertFalse(retains(""))
        let plain = stored("Dentist", at(2026, 11, 3, 9), at(2026, 11, 3, 10))
        store.activities.append(plain)
        XCTAssertFalse(retains(plain.id.uuidString))
        // A deleted series.
        store.deleteRecurringSeries(wednesdays.id)
        XCTAssertFalse(retains(wednesdays.occurrenceID(dayKey: 20261111).uuidString))

        // An unreadable series file: true for every string.
        try write(Data("not json".utf8), "series.json")
        let again = relaunched()
        XCTAssertTrue(again.seriesLoadFailed)
        let mirror = AppleCalendarMirror(backend: rig.fake, linksURL: rig.url, now: { again.replanNow() })
        again.attachCalendar(mirror)
        for key in [UUID().uuidString, mondays.occurrenceID(dayKey: 20261103).uuidString, "not an id", ""] {
            XCTAssertTrue(mirror.retains(key), "kept while the series file is unreadable: \(key)")
        }
        await settle(rig.mirror)
    }

    // MARK: SPEC-REPEATFIX-001 (card t82) - repairs of the stored repeat rule

    // MARK: AC-007 - the fill chooses its days again after its awaits

    func testREPEATFIX_FillChoosesDaysAgainAfterItsAwaits() async throws {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let series = plannedStandup()
        XCTAssertTrue(store.addSeries(series))
        let nov9 = series.occurrenceID(dayKey: 20261109)
        // Runs once per pass, after the days are chosen and before anything is written: the occurrence goes meanwhile.
        store.drvFillGate = {
            if let occurrence = store.activity(id: nov9) { store.deleteActivity(occurrence) }
        }

        await store.fillSeriesLegs()
        XCTAssertEqual(store.drvFillGateReached, 1)
        XCTAssertEqual(store.series[0].skippedDayKeys, [20261109])
        XCTAssertEqual(store.events.count, 4, "legs for Nov 2 and Nov 16 only")
        XCTAssertEqual(legDayKeys(store, .arrival), [20261102, 20261116])
        XCTAssertEqual(legDayKeys(store, .departure), [20261102, 20261116])
        XCTAssertTrue(store.events.allSatisfy { $0.linkedActivityId != nov9 }, "no leg for the deleted occurrence")
        XCTAssertEqual(store.series[0].legsFilledThroughDayKey, 20261116)
    }

    // MARK: AC-001 - Delete Entire Series keeps the legs and meals of a stored copy

    func testREPEATFIX_DeleteSeriesKeepsLegsLinkedToAStoredCopy() async throws {
        let d0 = classBMonday()
        func day(_ n: Int, _ hour: Int = 0) -> Date { d0.addingTimeInterval(Double(n) * 86400 + Double(hour) * 3600) }
        let store = EmptyStore.make()
        let clock = day(0, 8)
        store.replanNow = { clock }
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        var series = standup()
        series.firstDayKey = key(d0)
        XCTAssertTrue(store.addSeries(series))
        let ids = [0, 7, 14].map { series.occurrenceID(dayKey: key(day($0))) }
        try await addBothLegs(store, series, edited: ids[0])
        XCTAssertEqual(store.events.count, 6)
        XCTAssertTrue(store.modifyActivity(id: ids[1], newTitle: "Standup (moved)"))

        // The crash state, put back by hand: the copy's legs carry the series id again, and an old-style event with the
        // series id and no link exists. No relaunch happens, so the load-time heal does not run.
        store.events = store.events.map { e in
            var e = e
            if e.linkedActivityId == ids[1] { e.recurrenceId = series.id }
            return e
        }
        store.events.append(ScheduledEvent(title: "Old leg", destination: office, arrivalDate: day(3, 9),
                                           mode: .car, bufferMinutes: 5, notifyLeadMinutes: 10, recurrenceId: series.id))
        store.addMeal(category: .cooking, title: "Goes", scheduledEventId: try XCTUnwrap(store.legs(of: ids[2]).return).id,
                      plannedAt: day(14, 12), loggedAt: day(-1))
        store.addMeal(category: .cooking, title: "Stays", scheduledEventId: try XCTUnwrap(store.legs(of: ids[1]).return).id,
                      plannedAt: day(7, 12), loggedAt: day(-1))
        let keptLegs = store.events.filter { $0.linkedActivityId == ids[1] }
        XCTAssertEqual(keptLegs.count, 2)
        XCTAssertTrue(keptLegs.allSatisfy { $0.recurrenceId == series.id && $0.notificationId != nil },
                      "class B: the copy's legs are in the crash state and have alarms")
        let alarms = Dictionary(uniqueKeysWithValues: keptLegs.map { ($0.id, $0.notificationId) })

        let saves = store.drvSaveCount
        store.deleteRecurringSeries(series.id)

        // Row 1
        XCTAssertTrue(store.series.isEmpty)
        XCTAssertEqual(store.activities.map(\.id), [ids[1]])
        XCTAssertEqual(store.events.count, 2, "the copy's two legs stay; the other four legs and `unlinked` go")
        XCTAssertTrue(store.events.allSatisfy { $0.linkedActivityId == ids[1] })
        XCTAssertEqual(store.meals.map(\.title), ["Stays"])
        for leg in store.events { XCTAssertEqual(leg.notificationId, alarms[leg.id] ?? nil, "the kept alarm is untouched") }
        // Row 2
        XCTAssertTrue(store.events.allSatisfy { $0.recurrenceId == nil }, "no event keeps the id of a series that is gone")
        // Row 3
        let again = relaunched()
        XCTAssertEqual(again.events.count, 2)
        XCTAssertTrue(again.events.allSatisfy { $0.recurrenceId == nil })
        XCTAssertEqual(again.activities.map(\.id), [ids[1]])
        XCTAssertTrue(again.series.isEmpty)
        // Row 4
        XCTAssertEqual(store.drvSaveCount, saves + 1, "events.json is written once")
    }

    // MARK: AC-002 - the load heals the crash state

    /// A store with a leg plan whose six legs (Nov 2, 9, 16) are filled and on disk, plus the pieces of the crash state of
    /// `materialize` for Nov 9: the stored copy (not yet saved), the ids of the two fill-made legs of the day, and, when
    /// asked, a `foreign` event linked to the day that carries another series' id (written with `save()`).
    private struct HealRig {
        let store: Store
        let series: RepeatSeries
        let nov9: UUID
        let copy: ActivityBlock
        let fillLegIDs: Set<UUID>
        let foreign: ScheduledEvent?
    }

    private func healRig(withForeign: Bool) async throws -> HealRig {
        let store = fixtureStore()
        store.drvTravelLookupOverride = { _, _, _ in 900 }
        let s = plannedStandup()
        XCTAssertTrue(store.addSeries(s))
        await store.fillSeriesLegs()
        XCTAssertEqual(store.events.count, 6)
        let nov9 = s.occurrenceID(dayKey: 20261109)
        var copy = try XCTUnwrap(store.activity(id: nov9))
        copy.recurrenceId = nil
        let fillLegIDs = Set(store.events.filter { $0.linkedActivityId == nov9 }.map(\.id))
        XCTAssertEqual(fillLegIDs.count, 2)
        var foreign: ScheduledEvent?
        if withForeign {
            var f = ScheduledEvent(title: "Foreign leg", destination: office, arrivalDate: at(2026, 11, 9, 9),
                                   mode: .car, bufferMinutes: 5, notifyLeadMinutes: 10, recurrenceId: UUID(),
                                   linkedActivityId: nov9)
            f.travelSeconds = 900
            store.events.append(f)
            store.save()
            foreign = f
        }
        return HealRig(store: store, series: s, nov9: nov9, copy: copy, fillLegIDs: fillLegIDs, foreign: foreign)
    }

    /// Row 1 and 2 share what the relaunched store must show.
    private func assertHealed(_ r: HealRig, _ reloaded: Store) {
        for leg in reloaded.events where r.fillLegIDs.contains(leg.id) {
            XCTAssertNil(leg.recurrenceId, "the copy's fill-made leg lost the series id")
        }
        XCTAssertEqual(reloaded.events.filter { r.fillLegIDs.contains($0.id) }.count, 2)
        XCTAssertEqual(reloaded.events.first { $0.id == r.foreign?.id }?.recurrenceId, r.foreign?.recurrenceId,
                       "an event of another series is not touched")
        let others = reloaded.events.filter { $0.linkedActivityId != r.nov9 }
        XCTAssertEqual(others.count, 4)
        XCTAssertTrue(others.allSatisfy { $0.recurrenceId == r.series.id }, "the legs of Nov 2 and Nov 16 keep the series id")
    }

    func testREPEATFIX_LoadClearsSeriesIdOnCopyLegsWhenTheDayIsNotSkipped() async throws {
        let r = try await healRig(withForeign: true)
        // The app died after the first save of `materialize`: the copy is on disk, nothing else.
        try write(JSONEncoder().encode([r.copy]), "activities.json")

        let reloaded = relaunched()
        XCTAssertEqual(reloaded.series[0].skippedDayKeys, [20261109], "the existing repair")
        assertHealed(r, reloaded)
        XCTAssertEqual(reloaded.drvSaveCount, 1, "events.json is written once")

        let second = relaunched()
        assertHealed(r, second)
        XCTAssertEqual(second.drvSaveCount, 0, "nothing is left to heal")
    }

    func testREPEATFIX_LoadClearsSeriesIdOnCopyLegsWhenTheDayIsSkipped() async throws {
        let r = try await healRig(withForeign: true)
        // The app died after the second save: the copy and the skipped day are on disk, the legs are not.
        try write(JSONEncoder().encode([r.copy]), "activities.json")
        var skipped = r.store.series[0]
        skipped.skippedDayKeys = [20261109]
        try write(JSONEncoder().encode([skipped]), "series.json")

        let reloaded = relaunched()
        XCTAssertEqual(reloaded.series[0].skippedDayKeys, [20261109], "still one entry")
        assertHealed(r, reloaded)
        XCTAssertEqual(reloaded.drvSaveCount, 1)

        reloaded.deleteRecurringSeries(r.series.id)
        XCTAssertEqual(reloaded.events.count, 3, "the three events linked to the copy are what is left")
        XCTAssertTrue(reloaded.events.allSatisfy { $0.linkedActivityId == r.nov9 })
    }

    func testREPEATFIX_LoadWithNothingToHealWritesNoEvents() async throws {
        // (a) No copy.
        _ = try await healRig(withForeign: false)
        let aBytes = bytes("events.json")
        XCTAssertNotNil(aBytes)
        let aStore = relaunched()
        XCTAssertEqual(aStore.drvSaveCount, 0)
        XCTAssertEqual(bytes("events.json"), aBytes)

        // (b) A copy whose legs already have no series id: the state after `materialize`.
        let b = try await healRig(withForeign: false)
        XCTAssertTrue(b.store.modifyActivity(id: b.nov9, newTitle: "Standup (moved)"))
        let bBytes = bytes("events.json")
        let bStore = relaunched()
        XCTAssertEqual(bStore.drvSaveCount, 0)
        XCTAssertEqual(bytes("events.json"), bBytes)

        // (c) The series file is unreadable, with the copy and the legs of the crash state: nothing owns the legs.
        let c = try await healRig(withForeign: false)
        try write(JSONEncoder().encode([c.copy]), "activities.json")
        try write(Data("not json".utf8), "series.json")
        let cBytes = bytes("events.json")
        let cStore = relaunched()
        XCTAssertTrue(cStore.seriesLoadFailed)
        XCTAssertEqual(cStore.drvSaveCount, 0)
        XCTAssertEqual(bytes("events.json"), cBytes)
        XCTAssertEqual(cStore.events.filter { c.fillLegIDs.contains($0.id) }.count, 2)
        XCTAssertTrue(cStore.events.allSatisfy { $0.recurrenceId == c.series.id }, "the legs still carry the series id")
    }
}
