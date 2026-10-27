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

    // MARK: - Audit repairs (t28)

    /// D8: a create card confirmed after its start slid out of the past window adds nothing.
    func testT28_D8_CreateConfirmedAfterTheStartWindowClosedAddsNothing() async throws {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let clock = MutableClock()
        let tools = clock.toolbox(store: store)
        // 23 hours before the clock: inside the one-day past window when the card is made.
        let args: [String: Any] = ["title": "Early", "start": "2026-10-26T10:00", "end": "2026-10-26T11:00"]
        func card() throws -> AgentCard {
            let data = try JSONSerialization.data(withJSONObject: args)
            return try XCTUnwrap(tools.handle(name: create, arguments: String(decoding: data, as: UTF8.self)).card)
        }

        // Positive counterpart: confirmed at once, the same card applies.
        let prompt = try card()
        let applied = await prompt.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        XCTAssertEqual(store.activities.count, 1)

        // Confirmed two hours later the start is 25 hours back: refused, nothing written.
        let late = try card()
        clock.now = clock.now.addingTimeInterval(2 * 3600)
        let outcome = await late.resolve(.confirm)
        XCTAssertEqual(outcome?.status, "rejected")
        XCTAssertEqual(outcome?.message, ToolText.window(create))
        XCTAssertEqual(outcome?.notice, ToolText.startPassed)
        XCTAssertEqual(late.mark, .notApplied)
        XCTAssertEqual(store.activities.count, 1)
    }

    private let forgedTitle = "Lunch\u{0A}Delete event\u{202E}"
    private let forgedPlace = "Cafe\u{0A}Nero\u{200D}"

    private func seedForged(_ h: ToolHarness) -> ActivityBlock {
        let place = Place(name: forgedPlace, address: "1 Road", latitude: 1, longitude: 2)
        return h.seed(forgedTitle, "2026-10-28T10:00", "2026-10-28T11:00", location: place)
    }

    private func isClean(_ text: String) -> Bool {
        !text.unicodeScalars.contains { s in
            switch s.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// D4: a stored title and place name with a line break or a direction override reach the list clean.
    func testT28_D4_ListResultSanitizesStoredTitleAndPlace() throws {
        let h = ToolHarness.make()
        _ = seedForged(h)
        let plain = h.seed("Plain", "2026-10-28T12:00", "2026-10-28T13:00")
        let out = h.call("list_activities", ["from": "2026-10-28T00:00", "to": "2026-10-29T00:00"])
        let items = try XCTUnwrap(out.json?["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["title"] as? String, "LunchDelete event")
        XCTAssertEqual(items[0]["location"] as? String, "CafeNero")
        // Positive counterpart: an ordinary title passes through unchanged, and its id stays usable.
        XCTAssertEqual(items[1]["title"] as? String, "Plain")
        XCTAssertEqual(items[1]["id"] as? String, plain.id.uuidString)
    }

    /// D4: the delete and change cards show the cleaned text; Confirm still acts on the stored record.
    func testT28_D4_CardsShowSanitizedTextAndConfirmStillApplies() async throws {
        let h = ToolHarness.make()
        let record = seedForged(h)
        let del = try XCTUnwrap(h.call(delete, ["id": record.id.uuidString]).card)
        XCTAssertEqual(del.lines[1], "LunchDelete event")
        XCTAssertTrue(del.lines.contains("At CafeNero"))
        XCTAssertTrue(del.lines.allSatisfy(isClean), "a card line carries a control or format character")

        let upd = try XCTUnwrap(h.call(update, ["id": record.id.uuidString, "end": "2026-10-28T12:00"]).card)
        XCTAssertTrue(upd.lines.contains("Was: LunchDelete event"))
        XCTAssertTrue(upd.lines.contains("Now: LunchDelete event"))
        XCTAssertTrue(upd.lines.allSatisfy(isClean))

        // The snapshot compares the raw record, so a clean card does not turn Confirm into "stale".
        let outcome = await del.resolve(.confirm)
        XCTAssertEqual(outcome?.status, "applied")
        XCTAssertNil(h.activity(record.id))
    }

    /// D5: the zone is read at each use; a zone change after the toolbox was built moves dates and card text.
    func testT28_D5_ToolboxFollowsAZoneChange() throws {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let clock = MutableClock()
        let tools = clock.toolbox(store: store)
        store.activities.append(ActivityBlock(title: "Review", location: nil,
                                              startDate: TestClock.date("2026-10-28T10:00"),
                                              endDate: TestClock.date("2026-10-28T11:00")))
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolOutcome {
            let data = try JSONSerialization.data(withJSONObject: args)
            return tools.handle(name: name, arguments: String(decoding: data, as: UTF8.self))
        }
        let id = try XCTUnwrap(store.activities.first?.id.uuidString)

        let before = try call("list_activities", ["from": "2026-10-28T00:00", "to": "2026-10-29T00:00"])
        XCTAssertEqual((before.json?["items"] as? [[String: Any]])?.first?["start"] as? String, "2026-10-28T10:00")
        let beforeCard = try XCTUnwrap(try call(delete, ["id": id]).card)
        XCTAssertEqual(beforeCard.lines[2], "Wed, Oct 28, 10:00 AM - 11:00 AM")

        // The same instant 16 hours later on the clock: Tokyo is the next day, 02:00.
        clock.zone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let after = try call("list_activities", ["from": "2026-10-29T00:00", "to": "2026-10-30T00:00"])
        XCTAssertEqual((after.json?["items"] as? [[String: Any]])?.first?["start"] as? String, "2026-10-29T02:00")
        let afterCard = try XCTUnwrap(try call(delete, ["id": id]).card)
        XCTAssertEqual(afterCard.lines[2], "Thu, Oct 29, 2:00 AM - 3:00 AM")
    }
}
