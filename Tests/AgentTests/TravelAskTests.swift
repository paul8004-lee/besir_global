import XCTest
@testable import besir

/// SPEC-TRAVELASK-001: a `create_activity` call with a place and no route is refused once with the travel question, and a
/// place-only card is built only after the user has written a line since that refusal. Written before the app change: on the
/// base app T01-T06, T09, T10 and T11 fail by assertion, and T07 and T08 (the unchanged paths) pass.
/// Nothing here touches the network; Places and Routes answer from stub transports and fixtures.
@MainActor
final class TravelAskTests: XCTestCase {
    private static let rangeLine = "Wed, Oct 28, 7:00 PM - 8:00 PM"
    private static let placeCard = ["Add event", "Team sync", rangeLine, "At Example Cafe"]
    private static let refusal = ["status": "rejected", "message": PlaceText.travelAsk] as NSDictionary

    // MARK: - Helpers

    /// A rig with places p1..p3 and the routes r1 (transit) and r2 (walk) to p1.
    private func seeded() async -> PlaceRig {
        let rig = PlaceRig()
        await rig.seedBasics()
        return rig
    }

    /// Adds one line to the lines the user wrote in this chat.
    private func addUserLine(_ rig: PlaceRig, _ text: String = "I'm already there.") {
        let earlier = rig.tools.userLines()
        rig.tools.userLines = { earlier + [text] }
    }

    private func assertRefused(_ outcome: AgentToolOutcome, _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome.json as NSDictionary?, Self.refusal, label, file: file, line: line)
        XCTAssertNil(outcome.card, "\(label): no card", file: file, line: line)
    }

    /// The route handle a good `get_travel_time` answer gave.
    private func routeHandle(_ reply: PlaceReply, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        XCTAssertEqual(reply.status, "ok", reply.text ?? "no text", file: file, line: line)
        return try XCTUnwrap(reply.json?["route_id"] as? String, reply.text ?? "no route_id", file: file, line: line)
    }

    // MARK: - REQ-001, REQ-002

    func testTRAVELASK_T01_placeOnlyCreateIsRefusedAndChangesNothing() async throws {
        let rig = await seeded()
        let before = rig.snapshot
        let placeCalls = rig.places.callCount
        let routeCalls = rig.routes.callCount
        // First: the seed did reach both stubs, so the unchanged counts below are not two zeros.
        XCTAssertGreaterThan(placeCalls, 0)
        XCTAssertGreaterThan(routeCalls, 0)

        let outcome = rig.create(place: "p1")

        XCTAssertEqual(outcome.status, "rejected")
        XCTAssertEqual(outcome.json?["message"] as? String, PlaceText.travelAsk)
        XCTAssertNil(outcome.card, "no card before the travel question")
        XCTAssertFalse(outcome.isLookup, "the refusal looks nothing up")
        XCTAssertEqual(rig.snapshot, before, "the refusal writes nothing")
        XCTAssertEqual(rig.places.callCount, placeCalls, "no Places request")
        XCTAssertEqual(rig.routes.callCount, routeCalls, "no Routes request")
    }

    func testTRAVELASK_T02_theRefusalLeadsWithTheActionAndNamesNoModeOrValue() async throws {
        let rig = await seeded()
        let message = try XCTUnwrap(rig.create(place: "p1").json?["message"] as? String, "a refusal message")
        XCTAssertEqual(message, PlaceText.travelAsk)
        XCTAssertTrue(message.hasPrefix("Call get_travel_time"), "it leads with the corrective action")
        XCTAssertTrue(message.hasSuffix("do not choose a mode for them."), "it ends by leaving the choice to the user")
        let lower = message.lowercased()
        for word in ["car ", "transit", "walk", "bicycle", "omit", "p1", "example cafe", "team sync", "2026"] {
            XCTAssertFalse(lower.contains(word), "the message holds no '\(word)'")
        }
    }

    // MARK: - REQ-003, REQ-004

    func testTRAVELASK_T03_aSecondCallWithoutAUserLineIsRefusedAgain() async throws {
        let rig = await seeded()
        addUserLine(rig, "Add dinner at the cafe")
        assertRefused(rig.create(place: "p1"), "first call")
        assertRefused(rig.create(place: "p1"), "second call with the same user lines")
        XCTAssertTrue(rig.store.activities.isEmpty)
    }

    func testTRAVELASK_T04_afterAUserLineThePlaceOnlyCardIsBuiltOnceAndStoresNoLeg() async throws {
        let originals = PlaceFixture.places("places-search-three")
        let rig = await seeded()
        assertRefused(rig.create(place: "p1"), "first call")
        addUserLine(rig)

        let card = try XCTUnwrap(rig.create(place: "p1").card, "after a user line the place card is built")
        XCTAssertEqual(card.lines, Self.placeCard)
        XCTAssertEqual(card.actions, ["Confirm", "Cancel"])

        assertRefused(rig.create(place: "p1"), "the opening was used up by the card")

        _ = await card.resolve(.confirm)
        XCTAssertEqual(rig.store.activities.count, 1)
        XCTAssertEqual(rig.store.activities.first?.location, originals.first)
        XCTAssertEqual(rig.store.events.count, 0, "a place with no route stores no travel leg")
        XCTAssertEqual(card.mark, .confirmed)
    }

    func testTRAVELASK_T05_aRouteReturnedAfterTheRefusalKeepsThePlaceOnlyCardShut() async throws {
        let rig = await seeded()
        assertRefused(rig.create(place: "p1"), "first call")
        addUserLine(rig, "By car.")
        let handle = try routeHandle(await rig.travel("p1", "car"))

        assertRefused(rig.create(place: "p1"), "a route came back after the refusal")
        assertRefused(rig.create(place: "p1"), "that refusal opens nothing without a later user line")
        addUserLine(rig)
        let placeOnly = try XCTUnwrap(rig.create(place: "p1").card, "a user line after the latest refusal opens it")
        XCTAssertEqual(placeOnly.lines, Self.placeCard)
        assertRefused(rig.create(place: "p1"), "the opening was used up by the card")

        let card = try XCTUnwrap(rig.create(place: "p1", route: handle).card, "the route builds its card")
        XCTAssertEqual(card.lines.count, 7)
        XCTAssertEqual(Array(card.lines.prefix(4)), Self.placeCard)
        XCTAssertEqual(card.lines.count > 4 ? card.lines[4] : nil, "From Current location")
        XCTAssertEqual(card.lines.filter { $0.hasPrefix("Leave ") }, ["Leave 6:37 PM - 18 min by car"])
        XCTAssertEqual(card.lines.last, "Verified by Routes")
    }

    func testTRAVELASK_T06_theOpeningIsPerPlace() async throws {
        // (a) The opening of p1 does not open p3.
        let rig = await seeded()
        assertRefused(rig.create(place: "p1"), "(a) p1 first call")
        addUserLine(rig)
        assertRefused(rig.create(place: "p3"), "(a) p3 was never refused, so it has no opening")
        let opened = try XCTUnwrap(rig.create(place: "p1").card, "(a) p1 builds its card")
        XCTAssertEqual(opened.lines, Self.placeCard)

        // (b) A route for p3 shuts only p3's opening.
        let fresh = await seeded()
        assertRefused(fresh.create(place: "p1"), "(b) p1 first call")
        assertRefused(fresh.create(place: "p3"), "(b) p3 first call")
        addUserLine(fresh)
        let handle = try routeHandle(await fresh.travel("p3", "car"))
        XCTAssertEqual(fresh.tools.registry.route(handle, now: fresh.clock.now)?.destination,
                       fresh.tools.registry.place("p3"), "(b) the new route goes to p3")
        let p1Card = try XCTUnwrap(fresh.create(place: "p1").card, "(b) a route for p3 does not shut p1's opening")
        XCTAssertEqual(p1Card.lines, Self.placeCard)
        assertRefused(fresh.create(place: "p3"), "(b) p3 has its own route since the refusal")
    }

    // MARK: - REQ-005 (characterization: the same on the base app and after)

    func testTRAVELASK_T07_routeRouteOnlyAndNoPlaceAreUnchanged() async throws {
        let rig = await seeded()
        let both = try XCTUnwrap(rig.create(place: "p1", route: "r1").card, "place and route")
        XCTAssertEqual(both.lines, Self.placeCard + ["From Current location", "Leave 6:37 PM - 18 min by transit",
                                                     "Verified by Routes"])
        let routeOnly = try XCTUnwrap(rig.create(route: "r1").card, "route only")
        XCTAssertEqual(routeOnly.lines, both.lines)
        let neither = try XCTUnwrap(rig.create().card, "no place and no route")
        XCTAssertEqual(neither.lines, ["Add event", "Team sync", Self.rangeLine])
    }

    func testTRAVELASK_T08_aPlanTurnIsUnchanged() async throws {
        let rig = await seeded()
        rig.tools.beginDayPlan(DayPlanContext(mode: .car, events: [], checkWindowEnd: TestClock.date("2026-10-29T00:00")))
        XCTAssertNotNil(rig.tools.dayPlan, "a plan turn is active")
        let card = try XCTUnwrap(rig.create(place: "p1").card, "in a plan turn the place card is built at once")
        XCTAssertEqual(card.lines, Self.placeCard)
    }

    // MARK: - REQ-007

    func testTRAVELASK_T09_aRefusalThenATravelLookupThenARouteBuildsTheCardWithoutAUserLine() async throws {
        let rig = await seeded()
        assertRefused(rig.create(place: "p1"), "first call")
        let handle = try routeHandle(await rig.travel("p1", "transit"))
        XCTAssertEqual(rig.tools.userLines(), [], "no user line was added")
        let card = try XCTUnwrap(rig.create(place: "p1", route: handle).card, "the route builds its card at once")
        XCTAssertEqual(card.lines, Self.placeCard + ["From Current location", "Leave 6:37 PM - 18 min by transit",
                                                     "Verified by Routes"])
    }

    // MARK: - The F-142 conversation

    func testTRAVELASK_T10_theF142ConversationAsksBeforeAnyCard() async throws {
        let question = "How will you travel?"
        let rig = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1")),
                                   .turn(PlaceTurns.create(place: "p1", id: "c2")),
                                   .turn(Turns.text(question)),
                                   .turn(PlaceTurns.create(place: "p1", id: "c3")),
                                   .turn(Turns.text("Cancelled."))])

        await rig.say("Add a visit to the cafe tomorrow at 7 PM.")
        XCTAssertNil(rig.session.pendingCard, "no card before the travel question")
        XCTAssertEqual(rig.resultStatuses, ["ok", "rejected"])
        XCTAssertEqual(rig.session.assistantTexts.last, question)
        XCTAssertEqual(rig.routesStub.callCount, 0, "the app looked up no route by itself")
        XCTAssertTrue(rig.historyText.contains(PlaceText.travelAsk), "the model was sent the travel question")

        await rig.say("I'm already there.")
        let card = try XCTUnwrap(rig.session.pendingCard, "after the user's answer the place card waits")
        XCTAssertEqual(card.lines, Self.placeCard)

        await rig.session.cancelCard()
        await rig.session.settle()
        XCTAssertTrue(rig.store.activities.isEmpty, "Cancel adds nothing")
        XCTAssertEqual(rig.store.events.count, 0)
        XCTAssertEqual(rig.fake.remaining, 0, "the whole script was used")
        await rig.finish()
    }

    // MARK: - REQ-003 (3): a failed lookup

    func testTRAVELASK_T11_aFailedTravelLookupLeavesTheOpeningAsItIs() async throws {
        let rig = PlaceRig(routes: PlaceStubs.routes("routes-empty-object"))
        _ = await rig.search("cafe")
        XCTAssertEqual(rig.tools.registry.placeHandles, ["p1", "p2", "p3"])
        assertRefused(rig.create(place: "p1"), "first call")
        addUserLine(rig)
        let failed = await rig.travel("p1", "car")
        XCTAssertEqual(failed.status, "no_route", failed.text ?? "no text")
        XCTAssertEqual(rig.tools.registry.routeHandles, [], "a failed lookup registers no route")
        let card = try XCTUnwrap(rig.create(place: "p1").card, "the opening stays as it was")
        XCTAssertEqual(card.lines, Self.placeCard)
    }
}
