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
        XCTAssertEqual(bytes("activities.json"), controlActivities, "activities.json must not change because a series exists")
        XCTAssertEqual(bytes("events.json"), controlEvents, "events.json must not change because a series exists")

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
        XCTAssertEqual(before.first.map { Store.dayKey($0, calendar: cal) }, 20270206, "Lunar New Year 2027 is Feb 6")

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
        // The `saveManualActivity` half of AC-004 row 3 (a repeat returns false and leaves `store.series` empty)
        // arrives with the card at M3; this test covers `saveSeries` and `addSeries`.
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
}
