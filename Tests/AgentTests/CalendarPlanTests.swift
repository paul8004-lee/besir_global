import XCTest
@testable import besir

/// AC-APPLECAL-001..003: what the planner creates, updates and removes. The planner reads only its
/// arguments. Clock 2026-10-27T09:00 in America/Los_Angeles (TestClock).
final class CalendarPlanTests: XCTestCase {
    private let now = TestClock.now
    private let cafe = Place(name: "Cafe Roma", address: "1 Main St", latitude: 37.77, longitude: -122.41)
    private let library = Place(name: "Library", address: "9 Oak Ave", latitude: 37.80, longitude: -122.27)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TestClock.zone
        return c
    }

    private func activity(_ title: String, _ start: String, _ end: String, place: Place? = nil,
                          sync: Bool? = nil, id: UUID = UUID()) -> ActivityBlock {
        ActivityBlock(id: id, title: title, location: place, startDate: TestClock.date(start),
                      endDate: TestClock.date(end), recurrenceId: nil, syncToCalendar: sync)
    }

    private func linked(_ activity: ActivityBlock, event: String, in file: inout CalendarLinkFile) {
        file.links[activity.id.uuidString] = CalendarLink(eventId: event, signature: CalendarDraft(activity))
    }

    private func plan(_ activities: [ActivityBlock], _ file: CalendarLinkFile = CalendarLinkFile()) -> CalendarPlanner.Plan {
        CalendarPlanner.plan(activities: activities, file: file, now: now, calendar: calendar)
    }

    // MARK: AC-001 creates

    func testAC_APPLECAL_001_CreateCarriesAllFields() throws {
        let a = activity("Lunch", "2026-10-27T15:00", "2026-10-27T16:00", place: cafe)
        let p = plan([a])
        XCTAssertEqual(p.creates.count, 1)
        XCTAssertTrue(p.updates.isEmpty)
        XCTAssertTrue(p.removes.isEmpty)
        let create = try XCTUnwrap(p.creates.first)
        XCTAssertEqual(create.activityId, a.id.uuidString)
        XCTAssertEqual(create.draft.title, "Lunch")
        XCTAssertEqual(create.draft.start, TestClock.date("2026-10-27T15:00"))
        XCTAssertEqual(create.draft.end, TestClock.date("2026-10-27T16:00"))
        XCTAssertEqual(create.draft.placeName, "Cafe Roma")
        XCTAssertEqual(create.draft.address, "1 Main St")
        XCTAssertEqual(create.draft.latitude, 37.77)
        XCTAssertEqual(create.draft.longitude, -122.41)
    }

    func testAC_APPLECAL_001_SyncFlagDecidesCreate() {
        let off = activity("Off", "2026-10-27T15:00", "2026-10-27T16:00", sync: false)
        XCTAssertTrue(plan([off]).isEmpty)
        let unset = activity("Unset", "2026-10-27T15:00", "2026-10-27T16:00", sync: nil)
        XCTAssertEqual(plan([unset]).creates.count, 1)
        let on = activity("On", "2026-10-27T15:00", "2026-10-27T16:00", sync: true)
        XCTAssertEqual(plan([on]).creates.count, 1)
    }

    func testAC_APPLECAL_001_PastActivitiesAreNotCreated() {
        let yesterday = activity("Yesterday", "2026-10-26T23:00", "2026-10-26T23:59")
        XCTAssertTrue(plan([yesterday]).isEmpty)
        let endsAtMidnight = activity("Midnight", "2026-10-26T23:00", "2026-10-27T00:00")
        XCTAssertEqual(plan([endsAtMidnight]).creates.count, 1)
    }

    func testAC_APPLECAL_001_BaselineActivitiesAreSkipped() {
        var a = activity("Existing", "2026-10-28T10:00", "2026-10-28T11:00")
        XCTAssertEqual(plan([a]).creates.count, 1)   // positive control: without the baseline it is created
        var file = CalendarLinkFile()
        file.baseline = [a.id.uuidString]
        XCTAssertTrue(plan([a], file).isEmpty)
        a.title = "Existing, renamed"
        XCTAssertTrue(plan([a], file).isEmpty)
    }

    func testAC_APPLECAL_001_UnchangedLinkedActivityPlansNothing() {
        let a = activity("Standup", "2026-10-27T10:00", "2026-10-27T10:15", place: cafe)
        var file = CalendarLinkFile()
        linked(a, event: "ev-1", in: &file)
        XCTAssertTrue(plan([a], file).isEmpty)
    }

    // MARK: AC-002 updates

    func testAC_APPLECAL_002_TitleChangeIsOneUpdate() throws {
        var a = activity("Standup", "2026-10-27T10:00", "2026-10-27T10:15")
        var file = CalendarLinkFile()
        linked(a, event: "ev-1", in: &file)
        a.title = "Daily standup"
        let p = plan([a], file)
        XCTAssertEqual(p.updates.count, 1)
        XCTAssertTrue(p.creates.isEmpty)
        XCTAssertTrue(p.removes.isEmpty)
        let update = try XCTUnwrap(p.updates.first)
        XCTAssertEqual(update.eventId, "ev-1")
        XCTAssertEqual(update.activityId, a.id.uuidString)
        XCTAssertEqual(update.draft.title, "Daily standup")
    }

    func testAC_APPLECAL_002_TimeChangeIsOneUpdate() {
        let original = activity("Standup", "2026-10-27T10:00", "2026-10-27T10:15")
        var file = CalendarLinkFile()
        linked(original, event: "ev-1", in: &file)

        var movedStart = original
        movedStart.startDate = TestClock.date("2026-10-27T10:30")
        movedStart.endDate = TestClock.date("2026-10-27T10:45")
        XCTAssertEqual(plan([movedStart], file).updates.count, 1)

        var longer = original
        longer.endDate = TestClock.date("2026-10-27T10:30")
        let p = plan([longer], file)
        XCTAssertEqual(p.updates.count, 1)
        XCTAssertTrue(p.creates.isEmpty)
        XCTAssertTrue(p.removes.isEmpty)
    }

    func testAC_APPLECAL_002_PlaceSetChangedAndClearedAreUpdates() throws {
        let noPlace = activity("Study", "2026-10-27T13:00", "2026-10-27T14:00")
        var withoutPlace = CalendarLinkFile()
        linked(noPlace, event: "ev-1", in: &withoutPlace)
        var gotPlace = noPlace
        gotPlace.location = cafe
        XCTAssertEqual(plan([gotPlace], withoutPlace).updates.count, 1)

        var withCafe = CalendarLinkFile()
        linked(gotPlace, event: "ev-1", in: &withCafe)
        var otherPlace = gotPlace
        otherPlace.location = library
        let changed = plan([otherPlace], withCafe)
        XCTAssertEqual(changed.updates.count, 1)
        XCTAssertEqual(changed.updates.first?.draft.placeName, "Library")

        var cleared = gotPlace
        cleared.location = nil
        let p = plan([cleared], withCafe)
        let update = try XCTUnwrap(p.updates.first)
        XCTAssertEqual(p.updates.count, 1)
        XCTAssertNil(update.draft.placeName)
        XCTAssertNil(update.draft.address)
        XCTAssertNil(update.draft.latitude)
        XCTAssertNil(update.draft.longitude)
    }

    // MARK: AC-003 removes

    func testAC_APPLECAL_003_DeletedActivityRemovesItsLink() {
        let kept = activity("Kept", "2026-10-27T10:00", "2026-10-27T11:00")
        let gone = activity("Gone", "2026-10-27T12:00", "2026-10-27T13:00")
        var file = CalendarLinkFile()
        linked(kept, event: "ev-1", in: &file)
        linked(gone, event: "ev-2", in: &file)
        let p = plan([kept], file)
        XCTAssertEqual(p.removes, [CalendarPlanner.Remove(activityId: gone.id.uuidString, eventId: "ev-2")])
        XCTAssertTrue(p.updates.isEmpty)
        XCTAssertTrue(p.creates.isEmpty)
    }

    func testAC_APPLECAL_003_SyncOffRemovesItsLink() {
        var a = activity("Switched off", "2026-10-27T10:00", "2026-10-27T11:00")
        var file = CalendarLinkFile()
        linked(a, event: "ev-1", in: &file)
        a.syncToCalendar = false
        let p = plan([a], file)
        XCTAssertEqual(p.removes, [CalendarPlanner.Remove(activityId: a.id.uuidString, eventId: "ev-1")])
        XCTAssertTrue(p.updates.isEmpty)
        XCTAssertTrue(p.creates.isEmpty)
    }

    func testAC_APPLECAL_003_PastGateDoesNotApplyToRemoves() {
        let old = activity("Last month", "2026-09-20T10:00", "2026-09-20T11:00")
        var file = CalendarLinkFile()
        linked(old, event: "ev-old", in: &file)
        XCTAssertTrue(plan([old], file).isEmpty)   // still present and unchanged: nothing to do
        let p = plan([], file)                      // deleted: the event goes, however old it is
        XCTAssertEqual(p.removes, [CalendarPlanner.Remove(activityId: old.id.uuidString, eventId: "ev-old")])
    }

    func testAC_APPLECAL_003_PlanNamesOnlyKnownIds() {
        var file = CalendarLinkFile()
        var list: [ActivityBlock] = []

        // Five activities that become creates.
        list.append(activity("a0", "2026-10-27T09:30", "2026-10-27T10:00"))
        list.append(activity("a1", "2026-10-27T11:00", "2026-10-27T12:00", place: cafe))
        list.append(activity("a9", "2026-10-28T09:00", "2026-10-28T10:00"))
        list.append(activity("a10", "2026-11-03T09:00", "2026-11-03T10:00"))
        list.append(activity("a11", "2026-10-27T17:00", "2026-10-27T18:00", sync: true))
        // Past, baseline, sync off without a link: nothing planned.
        list.append(activity("a2", "2026-10-26T09:00", "2026-10-26T10:00"))
        let baselineA = activity("a3", "2026-10-29T09:00", "2026-10-29T10:00")
        let baselineB = activity("a4", "2026-10-30T09:00", "2026-10-30T10:00")
        list.append(contentsOf: [baselineA, baselineB])
        file.baseline = [baselineA.id.uuidString, baselineB.id.uuidString]
        list.append(activity("a5", "2026-10-27T19:00", "2026-10-27T20:00", sync: false))
        // Linked: unchanged, changed, switched off.
        let unchanged = activity("a6", "2026-10-27T14:00", "2026-10-27T15:00")
        linked(unchanged, event: "ev-6", in: &file)
        var changed = activity("a7", "2026-10-27T15:00", "2026-10-27T16:00")
        linked(changed, event: "ev-7", in: &file)
        changed.title = "a7 renamed"
        var off = activity("a8", "2026-10-27T16:00", "2026-10-27T17:00")
        linked(off, event: "ev-8", in: &file)
        off.syncToCalendar = false
        list.append(contentsOf: [unchanged, changed, off])
        // Links whose activities no longer exist.
        for n in 1...3 {
            let ghost = activity("ghost\(n)", "2026-10-2\(n)T09:00", "2026-10-2\(n)T10:00")
            linked(ghost, event: "ev-ghost\(n)", in: &file)
        }
        XCTAssertEqual(list.count, 12)
        XCTAssertEqual(file.links.count, 6)

        let p = plan(list, file)
        XCTAssertEqual(p.creates.count, 5)
        XCTAssertEqual(p.updates.count, 1)
        XCTAssertEqual(p.removes.count, 4)

        let activityIds = Set(list.map { $0.id.uuidString }).union(file.links.keys)
        let eventIds = Set(file.links.values.map { $0.eventId })
        for c in p.creates { XCTAssertTrue(activityIds.contains(c.activityId)) }
        for u in p.updates {
            XCTAssertTrue(activityIds.contains(u.activityId))
            XCTAssertTrue(eventIds.contains(u.eventId))
        }
        for r in p.removes {
            XCTAssertTrue(activityIds.contains(r.activityId))
            XCTAssertTrue(eventIds.contains(r.eventId))
        }
        // Creates carry no event id at all, and a plan from the same input is the same plan.
        XCTAssertEqual(plan(list, file), p)
    }
}
