import XCTest
@testable import besir

/// AC-APPLECAL-009: reading the events of a day through the mirror, over a fake backend.
@MainActor
final class CalendarReadTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
        super.tearDown()
    }

    private func makeMirror(_ fake: FakeCalendarBackend) -> (AppleCalendarMirror, URL) {
        let url = CalendarTestSupport.freshLinksURL()
        urls.append(url)
        let mirror = AppleCalendarMirror(backend: fake, linksURL: url, now: { TestClock.now })
        mirror.captureBaseline([])
        return (mirror, url)
    }

    private func entry(_ id: String, _ title: String, _ start: String, _ end: String, allDay: Bool = false,
                       location: String? = nil, calendar: String = "Home") -> CalendarEntry {
        CalendarEntry(id: id, title: title, start: TestClock.date(start), end: TestClock.date(end),
                      isAllDay: allDay, location: location, calendarName: calendar, isFromBesir: false)
    }

    private var losAngeles: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TestClock.zone
        return c
    }

    func testAC_APPLECAL_009_ReadIsSortedMarkedAndUnchanged() async throws {
        let fake = FakeCalendarBackend()
        fake.entriesResult = [
            entry("ev-1", "Bravo", "2026-10-27T10:00", "2026-10-27T11:00", location: "Room 4", calendar: "Work"),
            entry("ev-2", "Holiday", "2026-10-27T00:00", "2026-10-28T00:00", allDay: true, calendar: "Holidays"),
            entry("ev-3", "Alpha", "2026-10-27T10:00", "2026-10-27T10:30"),
        ]
        let (mirror, url) = makeMirror(fake)
        var file = try XCTUnwrap(CalendarTestSupport.loadFile(url))
        let linkedActivity = ActivityBlock(title: "Alpha", location: nil, startDate: TestClock.date("2026-10-27T10:00"),
                                           endDate: TestClock.date("2026-10-27T10:30"))
        file.links[linkedActivity.id.uuidString] = CalendarLink(eventId: "ev-3", signature: CalendarDraft(linkedActivity))
        XCTAssertTrue(file.save(to: url))

        let result = try await mirror.entries(on: TestClock.now, calendar: losAngeles)
        // Start time, then title: the all-day entry (00:00) first, then Alpha before Bravo at 10:00.
        XCTAssertEqual(result.map { $0.id }, ["ev-2", "ev-3", "ev-1"])
        XCTAssertEqual(result.filter { $0.isFromBesir }.map { $0.id }, ["ev-3"])

        let bravo = try XCTUnwrap(result.first { $0.id == "ev-1" })
        XCTAssertEqual(bravo.title, "Bravo")
        XCTAssertEqual(bravo.start, TestClock.date("2026-10-27T10:00"))
        XCTAssertEqual(bravo.end, TestClock.date("2026-10-27T11:00"))
        XCTAssertFalse(bravo.isAllDay)
        XCTAssertEqual(bravo.location, "Room 4")
        XCTAssertEqual(bravo.calendarName, "Work")
        let holiday = try XCTUnwrap(result.first { $0.id == "ev-2" })
        XCTAssertTrue(holiday.isAllDay)
        XCTAssertEqual(holiday.calendarName, "Holidays")
    }

    func testAC_APPLECAL_009_WindowIsTheLocalDayEvenOnADaylightSavingDay() async throws {
        let fake = FakeCalendarBackend()
        let (mirror, _) = makeMirror(fake)

        // Los Angeles, 2026-11-01: the clocks go back, so the local day is 25 hours long.
        let dstDay = TestClock.date("2026-11-01T12:00")
        _ = try await mirror.entries(on: dstDay, calendar: losAngeles)
        let from = losAngeles.startOfDay(for: dstDay)
        let window = try XCTUnwrap(fake.lastWindow)
        XCTAssertEqual(window.from, from)
        XCTAssertEqual(window.to, losAngeles.date(byAdding: .day, value: 1, to: from))
        XCTAssertEqual(window.to.timeIntervalSince(window.from), 25 * 3600)

        // Seoul has no daylight saving: a plain 24-hour day.
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        _ = try await mirror.entries(on: dstDay, calendar: seoul)
        let seoulFrom = seoul.startOfDay(for: dstDay)
        let seoulWindow = try XCTUnwrap(fake.lastWindow)
        XCTAssertEqual(seoulWindow.from, seoulFrom)
        XCTAssertEqual(seoulWindow.to.timeIntervalSince(seoulWindow.from), 24 * 3600)
    }

    func testAC_APPLECAL_009_ReadNeedsFullAccess() async throws {
        for state in [CalendarAccess.denied, .restricted, .writeOnly] {
            let fake = FakeCalendarBackend()
            fake.accessState = state
            let (mirror, _) = makeMirror(fake)
            do {
                _ = try await mirror.entries(on: TestClock.now, calendar: losAngeles)
                XCTFail("access \(state) must not read")
            } catch {
                XCTAssertEqual(error as? CalendarReadError, .accessDenied)
            }
            XCTAssertEqual(fake.entriesCalls, 0)
            XCTAssertEqual(fake.requestCalls, 0)
        }

        // Undecided and refused: one request, then the error.
        let refused = FakeCalendarBackend()
        refused.accessState = .notDetermined
        refused.requestResult = .denied
        let (m1, _) = makeMirror(refused)
        do {
            _ = try await m1.entries(on: TestClock.now, calendar: losAngeles)
            XCTFail("a refused request must not read")
        } catch {
            XCTAssertEqual(error as? CalendarReadError, .accessDenied)
        }
        XCTAssertEqual(refused.requestCalls, 1)
        XCTAssertEqual(refused.entriesCalls, 0)

        // Undecided and allowed: one request, then the read.
        let allowed = FakeCalendarBackend()
        allowed.accessState = .notDetermined
        allowed.requestResult = .full
        allowed.entriesResult = [entry("ev-1", "Dentist", "2026-10-27T09:00", "2026-10-27T10:00")]
        let (m2, _) = makeMirror(allowed)
        let result = try await m2.entries(on: TestClock.now, calendar: losAngeles)
        XCTAssertEqual(result.map { $0.title }, ["Dentist"])
        XCTAssertEqual(allowed.requestCalls, 1)
        XCTAssertEqual(allowed.entriesCalls, 1)
    }
}
