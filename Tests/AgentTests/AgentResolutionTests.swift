import XCTest
@testable import besir

/// AC-AGENT-004: resolution and apply (spec.md section 3.5). A fake caller resolves the cards.
/// Clock 2026-10-27T09:00 in America/Los_Angeles; a throwaway Store emptied for every test.
@MainActor
final class AgentResolutionTests: XCTestCase {
    private let create = "create_activity"
    private let update = "update_activity"
    private let delete = "delete_activity"

    private func createArgs(title: String = "Team sync") -> [String: Any] {
        ["title": title, "start": "2026-10-28T15:00", "end": "2026-10-28T16:00"]
    }

    private func legEvent(_ title: String) -> ScheduledEvent {
        let place = Place(name: "Somewhere", address: "1 Road", latitude: 1, longitude: 2)
        return ScheduledEvent(title: title, destination: place, arrivalDate: TestClock.date("2026-11-02T10:00"),
                              mode: .walk, bufferMinutes: 0, notifyLeadMinutes: 0)
    }

    func testAG004_CreateAppliesOnlyAfterConfirm() async throws {
        let h = ToolHarness.make()
        let before = h.snapshot
        let card = try XCTUnwrap(h.call(create, createArgs()).card)
        // Pending: the Store equals its prior state.
        XCTAssertEqual(h.snapshot, before)
        XCTAssertTrue(h.store.activities.isEmpty)
        XCTAssertNil(card.mark)
        let outcome = await card.resolve(.confirm)
        XCTAssertEqual(outcome?.status, "applied")
        XCTAssertNil(outcome?.notice)
        XCTAssertEqual(card.mark, .confirmed)
        XCTAssertEqual(h.store.activities.count, 1)
        let stored = try XCTUnwrap(h.store.activities.first)
        XCTAssertEqual(stored.title, "Team sync")
        XCTAssertEqual(TestClock.local(stored.startDate), "2026-10-28T15:00")
        XCTAssertEqual(TestClock.local(stored.endDate), "2026-10-28T16:00")
        XCTAssertEqual(outcome?.json?["id"] as? String, stored.id.uuidString)
    }

    func testAG004_UpdateAppliesOnlyAfterConfirm() async throws {
        let h = ToolHarness.make()
        let place = Place(name: "Cafe Nero", address: "1 Secret Street", latitude: 37.123456, longitude: -122.654321)
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00", location: place)
        let before = h.snapshot
        let card = try XCTUnwrap(h.call(update, ["id": record.id.uuidString, "title": "Review 2", "end": "2026-10-28T12:00"]).card)
        XCTAssertEqual(h.snapshot, before)
        XCTAssertEqual(h.activity(record.id)?.title, "Review")
        let outcome = await card.resolve(.confirm)
        XCTAssertEqual(outcome?.status, "applied")
        XCTAssertEqual(card.mark, .confirmed)
        let stored = try XCTUnwrap(h.activity(record.id))
        XCTAssertEqual(stored.title, "Review 2")
        XCTAssertEqual(TestClock.local(stored.startDate), "2026-10-28T10:00")
        XCTAssertEqual(TestClock.local(stored.endDate), "2026-10-28T12:00")
        XCTAssertEqual(h.store.activities.count, 1)
        // Update leaves an existing location untouched: name, address and coordinates.
        XCTAssertEqual(stored.location?.name, "Cafe Nero")
        XCTAssertEqual(stored.location?.address, "1 Secret Street")
        XCTAssertEqual(stored.location?.latitude, 37.123456)
        XCTAssertEqual(stored.location?.longitude, -122.654321)
    }

    func testAG004_DeleteAppliesOnlyAfterConfirm() async throws {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let other = h.seed("Other", "2026-10-28T12:00", "2026-10-28T13:00")
        let before = h.snapshot
        let card = try XCTUnwrap(h.call(delete, ["id": record.id.uuidString]).card)
        XCTAssertEqual(h.snapshot, before)
        XCTAssertNotNil(h.activity(record.id))
        let outcome = await card.resolve(.confirm)
        XCTAssertEqual(outcome?.status, "applied")
        XCTAssertEqual(outcome?.json?["id"] as? String, record.id.uuidString)
        XCTAssertEqual(card.mark, .confirmed)
        XCTAssertNil(h.activity(record.id))
        XCTAssertNotNil(h.activity(other.id))
    }

    /// One card of each kind, with the Store state they act on.
    private func threeCards(_ h: ToolHarness) throws -> [AgentCard] {
        let a = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let b = h.seed("Dentist", "2026-10-28T12:00", "2026-10-28T13:00")
        return [
            try XCTUnwrap(h.call(create, createArgs()).card),
            try XCTUnwrap(h.call(update, ["id": a.id.uuidString, "title": "Review 2"]).card),
            try XCTUnwrap(h.call(delete, ["id": b.id.uuidString]).card),
        ]
    }

    func testAG004_CancelAppliesNothingAndReportsDeclined() async throws {
        let h = ToolHarness.make()
        let cards = try threeCards(h)
        let before = h.snapshot
        for card in cards {
            let outcome = await card.resolve(.cancel)
            XCTAssertEqual(outcome?.status, "declined")
            XCTAssertEqual(outcome?.message, ToolText.declined)
            XCTAssertEqual(outcome?.json.map { Set($0.keys) }, ["status", "message"])
            XCTAssertNil(outcome?.notice)
            XCTAssertEqual(card.mark, .cancelled)
        }
        XCTAssertEqual(h.snapshot, before)
        XCTAssertEqual(h.store.activities.count, 2)
    }

    func testAG004_DismissalAppliesNothingAndReportsDeclined() async throws {
        let h = ToolHarness.make()
        let cards = try threeCards(h)
        let before = h.snapshot
        for card in cards {
            let outcome = await card.resolve(.dismiss)
            XCTAssertEqual(outcome?.status, "declined")
            XCTAssertEqual(outcome?.message, ToolText.declined)
            XCTAssertNil(outcome?.notice)
            XCTAssertEqual(card.mark, .cancelled)
            XCTAssertEqual(card.mark?.rawValue, "Cancelled")
        }
        XCTAssertEqual(h.snapshot, before)
    }

    func testAG004_AppliedResultIsReadBackFromTheStore() async throws {
        let h = ToolHarness.make()
        // A record whose start has a stray 30 seconds: the Store moves it by whole minutes, so it cannot hold the requested start.
        let odd = h.seed("Odd", "2026-10-28T10:00:30", "2026-10-28T11:00:30")
        let card = try XCTUnwrap(h.call(update, ["id": odd.id.uuidString, "start": "2026-10-28T11:00"]).card)
        let outcome = await card.resolve(.confirm)
        let stored = try XCTUnwrap(h.activity(odd.id))
        XCTAssertNotEqual(TestClock.local(stored.startDate), "2026-10-28T11:00", "premise: the Store truncates the move")
        XCTAssertEqual(outcome?.status, "applied")
        XCTAssertEqual(outcome?.json?["start"] as? String, TestClock.local(stored.startDate))
        XCTAssertEqual(outcome?.json?["end"] as? String, TestClock.local(stored.endDate))
        XCTAssertEqual(outcome?.json?["title"] as? String, "Odd")
        XCTAssertEqual(outcome?.json?["id"] as? String, odd.id.uuidString)

        // An update that changes nothing: modifyActivity returns false, and the result is still applied with the stored values.
        let same = h.seed("Same", "2026-10-29T10:00", "2026-10-29T11:00")
        let noop = try XCTUnwrap(h.call(update, ["id": same.id.uuidString, "title": "Same"]).card)
        let unchanged = await noop.resolve(.confirm)
        XCTAssertEqual(unchanged?.status, "applied")
        XCTAssertNotEqual(unchanged?.status, "stale")
        XCTAssertEqual(unchanged?.json?["title"] as? String, "Same")
        XCTAssertEqual(unchanged?.json?["start"] as? String, "2026-10-29T10:00")
        XCTAssertEqual(unchanged?.json?["end"] as? String, "2026-10-29T11:00")
        XCTAssertEqual(noop.mark, .confirmed)

        // A create reports what the Store holds, id included.
        let made = try XCTUnwrap(h.call(create, createArgs()).card)
        let created = await made.resolve(.confirm)
        let newest = try XCTUnwrap(h.store.activities.first { $0.title == "Team sync" })
        XCTAssertEqual(created?.json?["id"] as? String, newest.id.uuidString)
        XCTAssertEqual(created?.json?["title"] as? String, newest.title)
        XCTAssertEqual(created?.json?["start"] as? String, TestClock.local(newest.startDate))
        XCTAssertEqual(created?.json?["end"] as? String, TestClock.local(newest.endDate))
    }

    func testAG004_CreateWritesNoLocationAndNoTravelLegs() async throws {
        let h = ToolHarness.make()
        h.store.events.append(legEvent("Existing leg"))
        let eventsBefore = h.store.events.count
        XCTAssertEqual(eventsBefore, 1)
        for sync in [false, true] {
            h.store.config.autoAddToCalendar = sync
            let title = sync ? "Synced" : "Unsynced"
            let card = try XCTUnwrap(h.call(create, createArgs(title: title)).card)
            let outcome = await card.resolve(.confirm)
            XCTAssertEqual(outcome?.status, "applied")
            let stored = try XCTUnwrap(h.store.activities.first { $0.title == title })
            XCTAssertNil(stored.location)
            XCTAssertNil(stored.recurrenceId)
            XCTAssertEqual(stored.syncToCalendar, sync, "inherits the app's calendar-sync setting")
            XCTAssertEqual(h.store.events.count, eventsBefore, "no travel leg is created")
            XCTAssertEqual(h.store.events.first?.title, "Existing leg")
        }
        XCTAssertEqual(h.store.activities.count, 2)
    }

    func testAG004_ResolvingTwiceActsOnce() async throws {
        let h = ToolHarness.make()
        // Confirm then Confirm creates one activity.
        let card = try XCTUnwrap(h.call(create, createArgs()).card)
        let first = await card.resolve(.confirm)
        XCTAssertEqual(first?.status, "applied")
        let second = await card.resolve(.confirm)
        XCTAssertNil(second)
        XCTAssertEqual(h.store.activities.count, 1)
        // Confirm then Cancel changes nothing further.
        let afterConfirm = h.snapshot
        let third = await card.resolve(.cancel)
        XCTAssertNil(third)
        XCTAssertEqual(h.snapshot, afterConfirm)
        XCTAssertEqual(card.mark, .confirmed)
        // Cancel then Confirm applies nothing.
        let other = try XCTUnwrap(h.call(create, createArgs(title: "Other")).card)
        let declined = await other.resolve(.cancel)
        XCTAssertEqual(declined?.status, "declined")
        let late = await other.resolve(.confirm)
        XCTAssertNil(late)
        XCTAssertEqual(h.store.activities.count, 1)
        XCTAssertEqual(other.mark, .cancelled)
        // A delete confirmed twice removes the record once and leaves its neighbour.
        let gone = h.seed("Gone", "2026-10-28T10:00", "2026-10-28T11:00")
        let kept = h.seed("Kept", "2026-10-28T12:00", "2026-10-28T13:00")
        let del = try XCTUnwrap(h.call(delete, ["id": gone.id.uuidString]).card)
        let removed = await del.resolve(.confirm)
        XCTAssertEqual(removed?.status, "applied")
        let again = await del.resolve(.confirm)
        XCTAssertNil(again)
        XCTAssertNil(h.activity(gone.id))
        XCTAssertNotNil(h.activity(kept.id))
    }
}
