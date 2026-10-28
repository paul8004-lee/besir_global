import XCTest
@testable import besir

/// Records every list the Store hands to its mirror.
@MainActor
final class RecordingMirror: CalendarMirroring {
    private(set) var calls: [[ActivityBlock]] = []

    func reconcile(_ activities: [ActivityBlock]) { calls.append(activities) }

    func entries(on day: Date, calendar: Calendar) async throws -> [CalendarEntry] { [] }
}

/// AC-APPLECAL-008: every path that saves activities reaches the mirror, and activities that existed
/// before the mirror was attached stay out of the calendar.
@MainActor
final class CalendarStoreHookTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
        super.tearDown()
    }

    private func newURL() -> URL {
        let url = CalendarTestSupport.freshLinksURL()
        urls.append(url)
        return url
    }

    private func add(_ store: Store, _ title: String, _ start: String = "2026-10-29T10:00",
                     _ end: String = "2026-10-29T11:00") async -> UUID {
        let made = await store.addActivityWithTravel(title: title, location: nil,
                                                     startDate: TestClock.date(start), endDate: TestClock.date(end),
                                                     travelFrom: nil, returnTo: nil,
                                                     outboundMode: .transit, returnMode: .transit,
                                                     bufferMinutes: 0, notifyLeadMinutes: 0)
        return made.activityId
    }

    func testAC_APPLECAL_008_AddModifyDeleteReachTheMirror() async throws {
        let store = EmptyStore.make()
        // A fresh Store holds the no-op mirror: saving reaches no calendar and reading is unavailable.
        XCTAssertTrue(store.calendarMirror is NoCalendarMirror)
        _ = await add(store, "Before the mirror")
        XCTAssertEqual(store.calendarStatus, .idle)
        do {
            _ = try await store.calendarMirror.entries(on: TestClock.now, calendar: .current)
            XCTFail("the no-op mirror must not return events")
        } catch {
            XCTAssertEqual(error as? CalendarReadError, .unavailable)
        }

        let recorder = RecordingMirror()
        store.calendarMirror = recorder
        let id = await add(store, "Dentist")
        XCTAssertGreaterThanOrEqual(recorder.calls.count, 1)
        XCTAssertTrue(recorder.calls.last?.contains { $0.id == id } ?? false)

        var seen = recorder.calls.count
        XCTAssertTrue(store.modifyActivity(id: id, newTitle: "Dentist, moved"))
        XCTAssertGreaterThan(recorder.calls.count, seen)
        XCTAssertEqual(recorder.calls.last?.first { $0.id == id }?.title, "Dentist, moved")

        seen = recorder.calls.count
        let current = try XCTUnwrap(store.activities.first { $0.id == id })
        store.deleteActivity(current)
        XCTAssertGreaterThan(recorder.calls.count, seen)
        XCTAssertFalse(recorder.calls.last?.contains { $0.id == id } ?? true)

        // The call the app makes when it becomes active.
        seen = recorder.calls.count
        store.reconcileCalendar()
        XCTAssertEqual(recorder.calls.count, seen + 1)
        XCTAssertEqual(recorder.calls.last?.map { $0.id }, store.activities.map { $0.id })
    }

    func testAC_APPLECAL_008_SeriesAndBulkDeletesReachTheMirror() async throws {
        let store = EmptyStore.make()
        let recorder = RecordingMirror()
        store.calendarMirror = recorder

        // A three-day series starting tomorrow (the series code skips occurrences that already started).
        let cal = Calendar.current
        let first = cal.startOfDay(for: Date().addingTimeInterval(86_400))
        let last = try XCTUnwrap(cal.date(byAdding: .day, value: 2, to: first))
        var rule = RecurrenceRule()
        rule.unit = .daily
        var seen = recorder.calls.count
        let series = await store.addRecurringLinkedSeries(
            title: "Class", location: nil, rule: rule, startDate: first, endDate: last,
            startHour: 10, startMinute: 0, end: (hour: 11, minute: 0, dayDistance: 0),
            outboundFrom: nil, returnTo: nil, outboundMode: .transit, returnMode: .transit,
            bufferMinutes: 0, notifyLeadMinutes: 0, notifyEnabled: false, syncToCalendar: true)
        XCTAssertEqual(series.activities, 3)
        XCTAssertGreaterThan(recorder.calls.count, seen)
        XCTAssertEqual(recorder.calls.last?.filter { $0.recurrenceId == series.recurrenceId }.count, 3)

        seen = recorder.calls.count
        store.deleteRecurringSeries(series.recurrenceId)
        XCTAssertGreaterThan(recorder.calls.count, seen)
        XCTAssertEqual(recorder.calls.last?.count, 0)

        let a = await add(store, "A", "2026-10-29T09:00", "2026-10-29T10:00")
        let b = await add(store, "B", "2026-10-29T11:00", "2026-10-29T12:00")
        let keep = await add(store, "Keep", "2026-10-29T13:00", "2026-10-29T14:00")
        seen = recorder.calls.count
        store.deleteActivities(store.activities.filter { $0.id == a || $0.id == b })
        XCTAssertGreaterThan(recorder.calls.count, seen)
        XCTAssertEqual(recorder.calls.last?.map { $0.id }, [keep])

        seen = recorder.calls.count
        store.deleteEverythingForTesting()
        XCTAssertGreaterThan(recorder.calls.count, seen)
        XCTAssertEqual(recorder.calls.last?.count, 0)
    }

    func testAC_APPLECAL_008_AttachKeepsOldActivitiesOutOfTheCalendar() async throws {
        let store = EmptyStore.make()
        let old = [("Old one", "2026-10-30T09:00", "2026-10-30T10:00"),
                   ("Old two", "2026-10-30T11:00", "2026-10-30T12:00"),
                   ("Old three", "2026-10-30T13:00", "2026-10-30T14:00")]
        for (title, start, end) in old {
            store.activities.append(ActivityBlock(title: title, location: nil,
                                                  startDate: TestClock.date(start), endDate: TestClock.date(end)))
        }
        let oldIds = Set(store.activities.map { $0.id.uuidString })
        let fake = FakeCalendarBackend()
        let url = newURL()
        let mirror = AppleCalendarMirror(backend: fake, linksURL: url, now: { TestClock.now })
        store.attachCalendar(mirror)

        let file = try XCTUnwrap(CalendarTestSupport.loadFile(url))
        XCTAssertEqual(file.baseline, oldIds)
        XCTAssertTrue(file.links.isEmpty)
        XCTAssertEqual(fake.accessCalls + fake.requestCalls + fake.totalWriteCalls, 0)

        // A new activity is mirrored.
        let newId = await add(store, "New one", "2026-10-31T09:00", "2026-10-31T10:00")
        let settled = await CalendarTestSupport.settle(mirror)
        XCTAssertTrue(settled)
        XCTAssertEqual(fake.createCalls, 1)
        XCTAssertEqual(Set(try XCTUnwrap(CalendarTestSupport.loadFile(url)).links.keys), [newId.uuidString])
        XCTAssertEqual(store.calendarStatus, .ok)

        // Editing an old one still writes nothing.
        let oldFirst = try XCTUnwrap(store.activities.first { $0.title == "Old one" })
        XCTAssertTrue(store.modifyActivity(id: oldFirst.id, newTitle: "Old one, renamed"))
        let settledAgain = await CalendarTestSupport.settle(mirror)
        XCTAssertTrue(settledAgain)
        XCTAssertEqual(fake.createCalls, 1)
        XCTAssertEqual(fake.updateCalls, 0)
    }

    func testAC_APPLECAL_008_AgentConfirmReachesTheMirror() async throws {
        let h = ToolHarness.make()
        let recorder = RecordingMirror()
        h.store.calendarMirror = recorder
        let args: [String: Any] = ["title": "Team sync", "start": "2026-10-28T15:00", "end": "2026-10-28T16:00"]
        let card = try XCTUnwrap(h.call("create_activity", args).card)
        XCTAssertTrue(recorder.calls.isEmpty)   // pending: nothing is saved yet
        let outcome = await card.resolve(.confirm)
        XCTAssertEqual(outcome?.status, "applied")
        XCTAssertGreaterThanOrEqual(recorder.calls.count, 1)
        let created = try XCTUnwrap(recorder.calls.last?.first { $0.title == "Team sync" })
        XCTAssertEqual(TestClock.local(created.startDate), "2026-10-28T15:00")
        XCTAssertEqual(TestClock.local(created.endDate), "2026-10-28T16:00")
    }
}
