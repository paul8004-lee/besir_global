import XCTest
@testable import besir

/// AC-APPLECAL-004..007 and 014 (texts): the mirror over a fake backend. The mirror's clock is TestClock
/// (2026-10-27T09:00 in America/Los_Angeles); every activity here is on 2026-10-29 or later, so the
/// past gate does not depend on the time zone of the machine running the tests.
@MainActor
final class CalendarMirrorTests: XCTestCase {
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

    /// A mirror whose link file exists (empty baseline), as after the app attached it.
    private func makeMirror(_ fake: FakeCalendarBackend, url: URL? = nil) -> (AppleCalendarMirror, URL) {
        let url = url ?? newURL()
        let mirror = AppleCalendarMirror(backend: fake, linksURL: url, now: { TestClock.now })
        mirror.captureBaseline([])
        return (mirror, url)
    }

    private func activity(_ title: String, _ start: String = "2026-10-29T10:00", _ end: String = "2026-10-29T11:00",
                          place: Place? = nil, id: UUID = UUID()) -> ActivityBlock {
        ActivityBlock(id: id, title: title, location: place, startDate: TestClock.date(start),
                      endDate: TestClock.date(end), recurrenceId: nil, syncToCalendar: nil)
    }

    private func seedLink(_ a: ActivityBlock, event: String, url: URL) {
        var file = CalendarTestSupport.loadFile(url) ?? CalendarLinkFile()
        file.links[a.id.uuidString] = CalendarLink(eventId: event, signature: CalendarDraft(a))
        XCTAssertTrue(file.save(to: url))
    }

    private func run(_ mirror: AppleCalendarMirror, _ list: [ActivityBlock],
                     file: StaticString = #filePath, line: UInt = #line) async {
        mirror.reconcile(list)
        let settled = await CalendarTestSupport.settle(mirror)
        XCTAssertTrue(settled, "the mirror did not finish its pass in 5 seconds", file: file, line: line)
    }

    // MARK: AC-004 access

    func testAC_APPLECAL_004_AsksOnceThenWrites() async {
        let fake = FakeCalendarBackend()
        fake.accessState = .notDetermined
        fake.requestResult = .full
        let (mirror, _) = makeMirror(fake)
        await run(mirror, [activity("Lunch")])
        XCTAssertEqual(fake.requestCalls, 1)
        XCTAssertEqual(fake.createCalls, 1)
        XCTAssertEqual(mirror.status, .ok)
    }

    func testAC_APPLECAL_004_NeverReprompts() async {
        // A refused request: nothing written, and a second pass does not ask again.
        let refused = FakeCalendarBackend()
        refused.accessState = .notDetermined
        refused.requestResult = .denied
        let (m1, _) = makeMirror(refused)
        let list = [activity("Lunch")]
        await run(m1, list)
        XCTAssertEqual(refused.createCalls, 0)
        XCTAssertEqual(m1.status, .denied)
        await run(m1, list)
        XCTAssertEqual(refused.requestCalls, 1)

        // The system leaves the state undecided: treated as denied, and never asked again in this run.
        let undecided = FakeCalendarBackend()
        undecided.accessState = .notDetermined
        undecided.requestResult = .notDetermined
        let (m2, _) = makeMirror(undecided)
        await run(m2, list)
        XCTAssertEqual(m2.status, .denied)
        XCTAssertEqual(undecided.totalWriteCalls, 0)
        await run(m2, list)
        await run(m2, list)
        XCTAssertEqual(undecided.requestCalls, 1)
    }

    func testAC_APPLECAL_004_RestrictedAndWriteOnlyWriteNothing() async {
        let restricted = FakeCalendarBackend()
        restricted.accessState = .restricted
        let (m1, _) = makeMirror(restricted)
        await run(m1, [activity("Lunch")])
        XCTAssertEqual(restricted.totalWriteCalls, 0)
        XCTAssertEqual(restricted.requestCalls, 0)
        XCTAssertEqual(m1.status, .restricted)

        // Write-only with a new activity.
        let writeOnly = FakeCalendarBackend()
        writeOnly.accessState = .writeOnly
        let (m2, _) = makeMirror(writeOnly)
        await run(m2, [activity("Lunch")])
        XCTAssertEqual(writeOnly.totalWriteCalls, 0)
        XCTAssertEqual(writeOnly.requestCalls, 0)
        XCTAssertEqual(m2.status, .denied)

        // Write-only with a linked activity whose title changed: no update, so no duplicate.
        let writeOnly2 = FakeCalendarBackend()
        writeOnly2.accessState = .writeOnly
        let (m3, url3) = makeMirror(writeOnly2)
        var linked = activity("Standup")
        seedLink(linked, event: "ev-1", url: url3)
        linked.title = "Daily standup"
        await run(m3, [linked])
        XCTAssertEqual(writeOnly2.createCalls, 0)
        XCTAssertEqual(writeOnly2.updateCalls, 0)
        XCTAssertEqual(writeOnly2.removeCalls, 0)
        XCTAssertEqual(writeOnly2.requestCalls, 0)
        XCTAssertEqual(m3.status, .denied)
    }

    func testAC_APPLECAL_004_NoCalendarStatus() async {
        // The plain create has nowhere to write.
        let fake = FakeCalendarBackend()
        fake.createErrors[1] = .noCalendar
        let (mirror, url) = makeMirror(fake)
        let a = activity("Lunch")
        await run(mirror, [a])
        XCTAssertEqual(mirror.status, .noCalendar)
        XCTAssertEqual(CalendarTestSupport.loadFile(url)?.links.count, 0)

        // The create that replaces a vanished event has nowhere to write: the old link stays.
        let fake2 = FakeCalendarBackend()
        fake2.createErrors[1] = .noCalendar
        let (mirror2, url2) = makeMirror(fake2)
        var linked = activity("Standup")
        seedLink(linked, event: "ev-1", url: url2)
        let before = CalendarTestSupport.loadFile(url2)?.links[linked.id.uuidString]
        linked.title = "Daily standup"
        await run(mirror2, [linked])
        XCTAssertEqual(fake2.updateCalls, 1)
        XCTAssertEqual(fake2.createCalls, 1)
        XCTAssertEqual(mirror2.status, .noCalendar)
        XCTAssertEqual(CalendarTestSupport.loadFile(url2)?.links[linked.id.uuidString], before)
    }

    func testAC_APPLECAL_004_EmptyPlanAsksNothingAndClearsStaleStatus() async {
        // Only a baseline activity: an empty plan, no request, no write, status unchanged.
        let fake = FakeCalendarBackend()
        fake.accessState = .notDetermined
        let url = newURL()
        let existing = activity("Existing")
        let mirror = AppleCalendarMirror(backend: fake, linksURL: url, now: { TestClock.now })
        mirror.captureBaseline([existing])
        await run(mirror, [existing])
        XCTAssertEqual(fake.requestCalls, 0)
        XCTAssertEqual(fake.totalWriteCalls, 0)
        XCTAssertEqual(mirror.status, .idle)

        // A refused-permission status clears once access reads as full; still no request.
        let denied = FakeCalendarBackend()
        denied.accessState = .denied
        let (m2, _) = makeMirror(denied)
        await run(m2, [activity("Lunch")])
        XCTAssertEqual(m2.status, .denied)
        await run(m2, [])
        XCTAssertEqual(m2.status, .denied)   // access is still denied: the cause is still there
        denied.accessState = .full
        await run(m2, [])
        XCTAssertEqual(m2.status, .idle)
        XCTAssertEqual(denied.requestCalls, 0)

        // A failed status clears on an empty plan.
        let failing = FakeCalendarBackend()
        failing.createErrors[1] = .failed("boom")
        let (m3, _) = makeMirror(failing)
        await run(m3, [activity("Lunch")])
        XCTAssertEqual(m3.status, .failed)
        await run(m3, [])
        XCTAssertEqual(m3.status, .idle)

        // So does a no-calendar status.
        let nowhere = FakeCalendarBackend()
        nowhere.createErrors[1] = .noCalendar
        let (m4, _) = makeMirror(nowhere)
        await run(m4, [activity("Lunch")])
        XCTAssertEqual(m4.status, .noCalendar)
        await run(m4, [])
        XCTAssertEqual(m4.status, .idle)

        // And a links-unreadable status, once the file loads again.
        let unreadable = FakeCalendarBackend()
        let (m5, url5) = makeMirror(unreadable)
        try? Data("not json {{".utf8).write(to: url5)
        await run(m5, [activity("Lunch")])
        XCTAssertEqual(m5.status, .linksUnreadable)
        XCTAssertTrue(CalendarLinkFile().save(to: url5))
        await run(m5, [])
        XCTAssertEqual(m5.status, .idle)

        // A baseline id whose activity is gone is dropped by an empty-plan pass.
        let url6 = newURL()
        let gone = activity("Gone")
        let kept = activity("Kept")
        let m6 = AppleCalendarMirror(backend: FakeCalendarBackend(), linksURL: url6, now: { TestClock.now })
        m6.captureBaseline([gone, kept])
        await run(m6, [kept])
        XCTAssertEqual(CalendarTestSupport.loadFile(url6)?.baseline, [kept.id.uuidString])
    }

    func testAC_APPLECAL_004_WritesAfterAccessBecomesFull() async {
        let fake = FakeCalendarBackend()
        fake.accessState = .notDetermined
        fake.requestResult = .denied
        let (mirror, _) = makeMirror(fake)
        let list = [activity("Lunch")]
        await run(mirror, list)
        XCTAssertEqual(mirror.status, .denied)
        XCTAssertEqual(fake.createCalls, 0)

        fake.accessState = .full   // the user allowed it in the Settings app
        await run(mirror, list)
        XCTAssertEqual(fake.createCalls, 1)
        XCTAssertEqual(mirror.status, .ok)
        XCTAssertLessThanOrEqual(fake.requestCalls, 1)
    }

    // MARK: AC-005 failures and the user's deletion

    func testAC_APPLECAL_005_VanishedEventIsRecreatedAndRelinked() async {
        let fake = FakeCalendarBackend()   // holds no events, so "ev-gone" has vanished
        let (mirror, url) = makeMirror(fake)
        var a = activity("Standup")
        seedLink(a, event: "ev-gone", url: url)
        a.title = "Daily standup"
        await run(mirror, [a])
        XCTAssertEqual(fake.updateCalls, 1)
        XCTAssertEqual(fake.createCalls, 1)
        let link = CalendarTestSupport.loadFile(url)?.links[a.id.uuidString]
        XCTAssertEqual(link?.eventId, "fake-1")
        XCTAssertEqual(link?.signature.title, "Daily standup")
        XCTAssertEqual(mirror.status, .ok)
    }

    func testAC_APPLECAL_005_FailureStopsThePass() async {
        let fake = FakeCalendarBackend()
        fake.createErrors[2] = .failed("boom")
        let (mirror, url) = makeMirror(fake)
        let list = [activity("One", "2026-10-29T09:00", "2026-10-29T10:00"),
                    activity("Two", "2026-10-29T11:00", "2026-10-29T12:00"),
                    activity("Three", "2026-10-29T13:00", "2026-10-29T14:00")]
        await run(mirror, list)
        XCTAssertEqual(mirror.status, .failed)
        XCTAssertEqual(fake.createCalls, 2)
        XCTAssertEqual(CalendarTestSupport.loadFile(url)?.links.count, 1)
        // No retry without a new save: three more turns of the run loop change nothing.
        for _ in 0..<3 { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(fake.createCalls, 2)
    }

    func testAC_APPLECAL_005_UserDeletedEventStaysDeleted() async {
        let fake = FakeCalendarBackend()   // the event the activity links to was deleted by the user
        let (mirror, url) = makeMirror(fake)
        var a = activity("Standup")
        seedLink(a, event: "ev-1", url: url)
        await run(mirror, [a])
        // Unchanged activity: nothing is written, updated, removed or read. The one backend call
        // allowed is the access-state read of an empty plan (REQ-005), which prompts nothing.
        XCTAssertEqual(fake.totalWriteCalls, 0)
        XCTAssertEqual(fake.requestCalls, 0)
        XCTAssertEqual(fake.entriesCalls, 0)

        a.title = "Daily standup"
        await run(mirror, [a])
        XCTAssertEqual(fake.updateCalls, 1)   // reports "no such event" ...
        XCTAssertEqual(fake.createCalls, 1)   // ... so a new event is written
    }

    // MARK: AC-006 one pass at a time

    func testAC_APPLECAL_006_QueuedRequestsRunAsOneNewestPass() async {
        let fake = FakeCalendarBackend()
        fake.accessState = .notDetermined
        fake.requestResult = .full
        fake.holdRequest()
        let (mirror, _) = makeMirror(fake)
        let a = activity("A", "2026-10-29T09:00", "2026-10-29T10:00")
        let b = activity("B", "2026-10-29T11:00", "2026-10-29T12:00")
        let c = activity("C", "2026-10-29T13:00", "2026-10-29T14:00")

        mirror.reconcile([a])
        let holding = await fake.waitUntilHolding()
        XCTAssertTrue(holding, "the fake never reported holding the access request")
        mirror.reconcile([a, b])
        mirror.reconcile([a, b, c])
        fake.releaseRequest()
        let settled = await CalendarTestSupport.settle(mirror)
        XCTAssertTrue(settled)

        XCTAssertEqual(mirror.passCount, 2)   // B was never planned on its own
        XCTAssertEqual(fake.requestCalls, 1)
        XCTAssertEqual(fake.createCalls, 3)
        XCTAssertEqual(Set(fake.events.values.map { $0.title }), ["A", "B", "C"])
    }

    func testAC_APPLECAL_006_BurstOfSavesCreatesEachEventOnce() async {
        let fake = FakeCalendarBackend()
        let (mirror, _) = makeMirror(fake)
        let list = [activity("A", "2026-10-29T09:00", "2026-10-29T10:00"),
                    activity("B", "2026-10-29T11:00", "2026-10-29T12:00")]
        for _ in 0..<5 { mirror.reconcile(list) }
        let settled = await CalendarTestSupport.settle(mirror)
        XCTAssertTrue(settled)
        XCTAssertLessThanOrEqual(mirror.passCount, 2)
        XCTAssertEqual(fake.createCalls, 2)
    }

    // MARK: AC-007 the link file

    func testAC_APPLECAL_007_LinkFileRoundTripsWithIdStringKeys() throws {
        let a = activity("Lunch", "2026-10-29T12:00", "2026-10-29T13:00",
                         place: Place(name: "Cafe", address: "1 Main St", latitude: 37.123456789, longitude: -122.987654321))
        var draft = CalendarDraft(a)
        draft.start = Date(timeIntervalSince1970: 1_800_000_000.123456)   // a fractional second must survive
        var file = CalendarLinkFile()
        file.links[a.id.uuidString] = CalendarLink(eventId: "ev-1", signature: draft)
        file.baseline = ["x", "y"]
        let url = newURL()
        XCTAssertTrue(file.save(to: url))
        XCTAssertEqual(CalendarLinkFile.load(url), .file(file))

        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let links = try XCTUnwrap(raw["links"] as? [String: Any])
        XCTAssertEqual(Array(links.keys), [a.id.uuidString])
    }

    func testAC_APPLECAL_007_EachSuccessIsOnDiskBeforeTheNextOperation() async {
        let fake = FakeCalendarBackend()
        fake.createErrors[2] = .failed("boom")
        let (mirror, url) = makeMirror(fake)
        let first = activity("First", "2026-10-29T09:00", "2026-10-29T10:00")
        let second = activity("Second", "2026-10-29T11:00", "2026-10-29T12:00")
        await run(mirror, [first, second])
        let file = CalendarTestSupport.loadFile(url)
        XCTAssertEqual(file?.links.count, 1)
        XCTAssertEqual(file?.links[first.id.uuidString]?.eventId, "fake-1")
        XCTAssertNil(file?.links[second.id.uuidString])
    }

    func testAC_APPLECAL_007_UnreadableFileIsLeftAlone() async {
        let fake = FakeCalendarBackend()
        let (mirror, url) = makeMirror(fake)
        let garbage = Data("not json {{".utf8)
        try? garbage.write(to: url)
        await run(mirror, [activity("Lunch")])
        XCTAssertEqual(mirror.status, .linksUnreadable)
        XCTAssertEqual(fake.accessCalls, 0)
        XCTAssertEqual(fake.requestCalls, 0)
        XCTAssertEqual(fake.totalWriteCalls, 0)
        XCTAssertEqual(try? Data(contentsOf: url), garbage)
    }

    func testAC_APPLECAL_007_BaselineIsWrittenOnceAndPrunedBeforeTheAccessGate() async {
        let url = newURL()
        let fake = FakeCalendarBackend()
        fake.accessState = .denied
        let mirror = AppleCalendarMirror(backend: fake, linksURL: url, now: { TestClock.now })
        let a = activity("A", "2026-10-29T09:00", "2026-10-29T10:00")
        let b = activity("B", "2026-10-29T11:00", "2026-10-29T12:00")
        let c = activity("C", "2026-10-29T13:00", "2026-10-29T14:00")

        mirror.captureBaseline([a, b])
        let first = CalendarTestSupport.loadFile(url)
        XCTAssertEqual(first?.baseline, [a.id.uuidString, b.id.uuidString])
        XCTAssertEqual(first?.links.count, 0)

        // b is gone and c is new, so the plan is not empty and the pass reaches the (denied) gate.
        await run(mirror, [a, c])
        XCTAssertEqual(mirror.status, .denied)
        XCTAssertEqual(CalendarTestSupport.loadFile(url)?.baseline, [a.id.uuidString])

        // A second capture changes nothing.
        let before = CalendarTestSupport.loadFile(url)
        mirror.captureBaseline([a, b, c])
        XCTAssertEqual(CalendarTestSupport.loadFile(url), before)

        // An absent file at reconcile time: failed, and nothing is called.
        let fake2 = FakeCalendarBackend()
        let lonely = AppleCalendarMirror(backend: fake2, linksURL: newURL(), now: { TestClock.now })
        await run(lonely, [c])
        XCTAssertEqual(lonely.status, .failed)
        XCTAssertEqual(fake2.accessCalls, 0)
        XCTAssertEqual(fake2.totalWriteCalls, 0)
    }

    // MARK: AC-014 texts

    func testAC_APPLECAL_014_StatusTexts() {
        let texts: [(CalendarStatus, String)] = [
            (.denied, "Calendar access is off or limited. Allow full access in the Settings app to save events to your calendar."),
            (.restricted, "Calendar access is restricted on this device."),
            (.noCalendar, "No calendar on this device can accept new events."),
            (.linksUnreadable, "besir could not read its calendar link file, so no events are saved to your calendar."),
            (.failed, "Some events could not be saved to your calendar."),
        ]
        for (status, text) in texts {
            XCTAssertEqual(CalendarStatusText.warning(status, switchOn: true), text)
        }
        XCTAssertNil(CalendarStatusText.warning(.idle, switchOn: true))
        XCTAssertNil(CalendarStatusText.warning(.ok, switchOn: true))
        for status in [CalendarStatus.idle, .ok, .denied, .restricted, .noCalendar, .linksUnreadable, .failed] {
            XCTAssertNil(CalendarStatusText.warning(status, switchOn: false))
        }
        XCTAssertEqual(CalendarStatusText.debugLine(for: CalendarReadError.accessDenied), "Calendar read failed: access denied")
        XCTAssertEqual(CalendarStatusText.debugLine(for: CalendarReadError.unavailable), "Calendar read failed: unavailable")
        XCTAssertEqual(CalendarStatusText.debugLine(for: CalendarBackendError.failed("x")), "Calendar read failed: unknown error")
    }
}
