import XCTest
@testable import besir

/// SPEC-AGENTPLACE-001, session path: the asynchronous lookup (SP) and the attribution row (AT).
/// Written before the implementation (M1b): against the M1a stubs every test except `MaxRequestsIsStillSix` fails by
/// assertion. Lookups that must stay in flight wait in a `HoldableTransport`; every wait is bounded, so a lookup that
/// never starts fails an assertion instead of hanging. Nothing here touches the network.
private enum SessionLine {
    static let interrupted = "The chat was closed before the assistant replied."
    static let tooManySteps = "The assistant needed too many steps. Try again with a simpler request."
    static let stepLimit = #"{"status":"rejected","message":"Not executed. The step limit was reached."}"#
    static let oneAtATime = #"{"status":"rejected","message":"Not executed. Make one tool call at a time."}"#
}

@MainActor
final class AgentPlaceSessionTests: XCTestCase {

    // MARK: - Helpers

    private func callOutputs(_ history: [AgentEntry]) -> [(callID: String, result: String)] {
        history.compactMap { entry in
            if case .callOutput(let callID, let result) = entry { return (callID, result) }
            return nil
        }
    }

    private func status(_ result: String) -> String? {
        TestClock.object(result)?["status"] as? String
    }

    private func isInterrupted(_ result: String) -> Bool {
        (TestClock.object(result) as NSDictionary?) == (PlaceText.interrupted as NSDictionary)
    }

    private var threePlaces: Data { PlaceFixture.data("places-search-three") }

    // MARK: - SP: the asynchronous lookup path (REQ-014, REQ-015, REQ-016)

    func testAGPLACE_LookupRunsAsTheInFlightRequestAndSendIsIgnored() async {
        let hold = HoldableTransport()
        let rig = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1")), .hold], hold: hold)
        rig.session.send("Find a cafe")
        let started = await hold.waitForRequests(1)
        XCTAssertTrue(started, "the lookup reached the Places transport")
        XCTAssertEqual(rig.fake.requests.count, 1, "a lookup is not a model request")
        XCTAssertTrue(rig.session.isWaiting)
        XCTAssertFalse(rig.session.canSend)

        rig.session.send("again")
        XCTAssertEqual(rig.fake.requests.count, 1, "Send is ignored while the lookup runs")
        XCTAssertEqual(rig.session.userTexts, ["Find a cafe"])

        XCTAssertTrue(hold.release(with: threePlaces), "the lookup was waiting for its answer")
        let next = await rig.fake.waitForRequests(2)
        XCTAssertTrue(next, "the next model request follows the lookup")
        XCTAssertTrue(rig.session.isWaiting, "the next model request keeps the session waiting")
        XCTAssertTrue(rig.fake.release(2, .success(Turns.text("Two cafes."))))
        await rig.session.settle()
        XCTAssertFalse(rig.session.isWaiting)
        XCTAssertTrue(rig.session.canSend)
        await rig.finish()
    }

    func testAGPLACE_LookupResultGoesBackToTheModelAndTheTurnContinues() async {
        let rig = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text("Two cafes."))])
        await rig.say("Find a cafe")
        let outputs = callOutputs(rig.session.history)
        XCTAssertEqual(outputs.map { $0.callID }, ["c1"])
        XCTAssertEqual(outputs.first.flatMap { status($0.result) }, "ok", "the history holds the ok result")
        XCTAssertEqual(rig.session.history.count, 4, "user, call, output, answer")
        XCTAssertEqual(rig.fake.requests.count, 2)

        let second = rig.fake.request(2)
        XCTAssertEqual(second.count, 3, "the second request carries the user text, the call and its output")
        if case .callOutput(let callID, let result) = second.last ?? .user("") {
            XCTAssertEqual(callID, "c1")
            XCTAssertEqual(status(result), "ok")
            XCTAssertEqual((TestClock.object(result)?["places"] as? [Any])?.count, 3)
        } else {
            XCTFail("the second request does not end with the lookup result")
        }
        XCTAssertEqual(rig.session.assistantTexts, ["Two cafes."])
        #if DEBUG
        let lines = rig.session.transcript().components(separatedBy: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("TOOL search_places ") }, "the transcript shows the call")
        XCTAssertTrue(lines.contains("RESULT ok"), "the transcript shows the result")
        #endif
        await rig.finish()
    }

    func testAGPLACE_HappyPathUsesFourModelRequests() async throws {
        let rig = PlaceSessionRig([
            .turn(PlaceTurns.search(id: "c1")),
            .turn(PlaceTurns.travel("p1", mode: "transit", id: "c2")),
            .turn(PlaceTurns.create(place: "p1", route: "r1", id: "c3")),
            .turn(Turns.text("Added dinner.")),
        ])
        await rig.say("Add dinner at the cafe on Wednesday at 7 PM")

        // Without Confirm the script stops at three requests with a pending card (the positive control).
        let before = callOutputs(rig.session.history)
        XCTAssertEqual(before.map { status($0.result) }, ["ok", "ok"], "the two lookups answered ok")
        XCTAssertEqual(rig.fake.requests.count, 3)
        let card = try XCTUnwrap(rig.session.pendingCard, "the third response built a card")
        XCTAssertTrue(card.lines.contains("Verified by Routes"))
        XCTAssertTrue(rig.store.activities.isEmpty, "nothing is written before Confirm")

        await rig.session.confirmCard()
        await rig.session.settle()
        XCTAssertEqual(rig.fake.requests.count, 4)
        XCTAssertEqual(rig.store.activities.count, 1)
        XCTAssertEqual(rig.store.activities.first?.location?.name, "Example Cafe")
        XCTAssertEqual(rig.store.events.count, 1, "the activity and its leg")
        XCTAssertEqual(rig.session.assistantTexts, ["Added dinner."])
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])
        let applied = callOutputs(rig.session.history).last.flatMap { TestClock.object($0.result) }
        XCTAssertEqual(applied?["status"] as? String, "applied")
        XCTAssertEqual(applied?["leave_by"] as? String, "2026-10-28T18:37")

        // The device position never reaches the history, the log or the transcript (positive control: the request
        // body to Places did carry it).
        let body = PlaceBody.text(rig.placesStub.requests.first)
        XCTAssertTrue(body.contains("37.7749"), "the stub request body does hold the device latitude")
        XCTAssertTrue(body.contains("-122.4194"), "the stub request body does hold the device longitude")
        var surfaces = [rig.historyText, rig.logText]
        #if DEBUG
        surfaces.append(rig.session.transcript())
        #endif
        for surface in surfaces {
            XCTAssertFalse(surface.isEmpty)
            XCTAssertFalse(surface.contains("37.7749"))
            XCTAssertFalse(surface.contains("-122.4194"))
        }
        await rig.finish()
    }

    func testAGPLACE_SixthResponseLookupCallIsNotExecuted() async {
        // Positive counterpart: the same search call as a first response does run the lookup.
        let first = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text("Found."))])
        await first.say("Find a cafe")
        XCTAssertEqual(first.placesStub.callCount, 1, "a lookup call within the bound is executed")

        var steps: [FakeTransport.Step] = (1...5).map { .turn(Turns.list(id: "c\($0)")) }
        steps.append(.turn(PlaceTurns.search(id: "c6")))
        let rig = PlaceSessionRig(steps)
        await rig.say("What is on?")
        XCTAssertEqual(rig.fake.requests.count, 6)
        XCTAssertEqual(rig.placesStub.callCount, 0, "the sixth response is not executed")
        XCTAssertEqual(rig.session.history.last, .callOutput(callID: "c6", result: SessionLine.stepLimit))
        XCTAssertEqual(rig.session.errorLines, [SessionLine.tooManySteps])
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])
    }

    func testAGPLACE_ExtraCallsBesideALookupAreRejectedNotExecuted() async {
        let rig = PlaceSessionRig()
        let seeded = ActivityBlock(title: "Team sync", location: nil,
                                   startDate: TestClock.date("2026-10-28T15:00"), endDate: TestClock.date("2026-10-28T16:00"))
        rig.store.activities.append(seeded)
        rig.fake.enqueue(
            .turn(Turns.turn(PlaceTurns.searchCall(id: "c1"),
                             Turns.call("delete_activity", PlaceTurns.arguments(["id": seeded.id.uuidString]), id: "c2"))),
            .turn(Turns.text("Found.")))
        await rig.say("Find a cafe and delete Team sync")
        let outputs = callOutputs(rig.session.history)
        XCTAssertEqual(outputs.map { $0.callID }, ["c1", "c2"], "one output per call, in call order")
        XCTAssertEqual(outputs.first.flatMap { status($0.result) }, "ok", "the first call, the lookup, ran")
        XCTAssertEqual(outputs.last?.result, SessionLine.oneAtATime, "the second call is answered, not executed")
        XCTAssertEqual(rig.placesStub.callCount, 1)
        XCTAssertEqual(rig.store.activities.count, 1, "nothing was deleted")
        XCTAssertNil(rig.session.pendingCard)
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])
    }

    func testAGPLACE_NewChatDuringALookupDropsTheResult() async {
        let hold = HoldableTransport()
        let rig = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1"))], hold: hold)
        rig.session.send("Find a cafe")
        let started = await hold.waitForRequests(1)
        XCTAssertTrue(started, "the lookup is in flight")
        await rig.session.newChat()
        XCTAssertTrue(hold.release(with: threePlaces), "the lookup was still waiting")
        let dropped = await eventually { rig.session.discardedCount == 1 }
        XCTAssertTrue(dropped, "the late answer is dropped and counted")
        XCTAssertEqual(rig.session.discardedCount, 1)
        XCTAssertTrue(rig.session.entries.isEmpty)
        XCTAssertTrue(rig.session.history.isEmpty)
        XCTAssertEqual(rig.tools.registry.placeHandles, [], "the dropped answer registered nothing")
        XCTAssertTrue(rig.session.errorLines.isEmpty)
        XCTAssertFalse(rig.session.isWaiting)
        await rig.finish()
    }

    func testAGPLACE_CancelledLookupNeverWritesTheRegistry() async {
        let hold = HoldableTransport()
        let rig = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text("Hello."))], hold: hold)
        rig.session.send("Find a cafe")
        let started = await hold.waitForRequests(1)
        XCTAssertTrue(started, "the lookup is in flight")
        await rig.session.newChat()
        await rig.say("hello")
        XCTAssertEqual(rig.session.assistantTexts, ["Hello."], "the new message ran its own request")

        XCTAssertTrue(hold.release(with: threePlaces), "the old lookup was still waiting")
        let dropped = await eventually { rig.session.discardedCount == 1 }
        XCTAssertTrue(dropped)
        XCTAssertEqual(rig.tools.registry.placeHandles, [], "a cancelled lookup never writes the registry")
        XCTAssertEqual(rig.tools.registry.routeHandles, [])
        XCTAssertEqual(rig.fake.requests.count, 2)
        await rig.finish()
    }

    func testAGPLACE_SheetCloseDuringALookupKeepsTheHistoryValid() async {
        let hold = HoldableTransport()
        let rig = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text("Fine."))], hold: hold)
        rig.session.send("Find a cafe")
        let started = await hold.waitForRequests(1)
        XCTAssertTrue(started, "the lookup is in flight")
        await rig.session.sheetDismissed()

        let outputs = callOutputs(rig.session.history)
        XCTAssertEqual(outputs.map { $0.callID }, ["c1"])
        XCTAssertTrue(outputs.first.map { isInterrupted($0.result) } ?? false, "the call got the interrupted result")
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])

        // The next user message sends a valid request.
        await rig.say("next")
        XCTAssertEqual(rig.fake.requests.count, 2)
        XCTAssertEqual(PairingValidator.problems(in: rig.fake.request(2)), [])
        XCTAssertEqual(rig.fake.request(2).last, .user("next"))

        // The old lookup answers late: dropped, nothing written.
        XCTAssertTrue(hold.release(with: threePlaces))
        let dropped = await eventually { rig.session.discardedCount == 1 }
        XCTAssertTrue(dropped)
        XCTAssertEqual(rig.session.discardedCount, 1)
        XCTAssertEqual(rig.tools.registry.placeHandles, [])
        XCTAssertEqual(callOutputs(rig.session.history).count, 1)
        await rig.finish()
    }

    func testAGPLACE_SheetCloseDuringALookupAppendsTheInterruptedNoticeOnce() async {
        let hold = HoldableTransport()
        let rig = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1"))], hold: hold)
        rig.session.send("Find a cafe")
        let started = await hold.waitForRequests(1)
        XCTAssertTrue(started, "the lookup is in flight")
        await rig.session.sheetDismissed()
        XCTAssertEqual(rig.session.noticeLines, [SessionLine.interrupted])
        XCTAssertTrue(rig.session.errorLines.isEmpty)
        XCTAssertFalse(rig.session.isWaiting)
        await rig.finish()
    }

    func testAGPLACE_DoubleSheetCloseRecordsOneOutputPerCall() async {
        let hold = HoldableTransport()
        let rig = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1")), .hold, .turn(Turns.text("Fine."))], hold: hold)
        rig.session.send("Find a cafe")
        let started = await hold.waitForRequests(1)
        XCTAssertTrue(started, "the lookup is in flight")

        // The first close records one output for the call (the positive control of the later counts).
        await rig.session.sheetDismissed()
        func outputsForC1() -> [String] { callOutputs(rig.session.history).filter { $0.callID == "c1" }.map { $0.result } }
        XCTAssertEqual(outputsForC1().count, 1, "the first close recorded one output")
        XCTAssertTrue(outputsForC1().first.map { isInterrupted($0) } ?? false)
        XCTAssertEqual(rig.resultStatuses, ["unavailable"], "one RESULT line")

        // Reopen and send: a model request is in flight (held), then the sheet closes a second time.
        rig.session.send("again")
        let second = await rig.fake.waitForRequests(2)
        XCTAssertTrue(second, "the second model request is in flight")
        XCTAssertTrue(rig.session.isWaiting)
        await rig.session.sheetDismissed()
        XCTAssertEqual(outputsForC1().count, 1, "the second close adds no output")
        XCTAssertEqual(rig.resultStatuses, ["unavailable"], "and no RESULT line")
        XCTAssertEqual(rig.session.noticeLines, [SessionLine.interrupted, SessionLine.interrupted], "one notice per close that interrupted a request")
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])

        // A third message sends a valid request.
        rig.session.send("third")
        let third = await rig.fake.waitForRequests(3)
        XCTAssertTrue(third)
        XCTAssertEqual(PairingValidator.problems(in: rig.fake.request(3)), [])
        await rig.finish()

        // A close during a plain model request, with no lookup ever started, records no output either.
        let plain = PlaceSessionRig([.hold])
        plain.session.send("What is on?")
        let reached = await plain.fake.waitForRequests(1)
        XCTAssertTrue(reached)
        await plain.session.sheetDismissed()
        XCTAssertEqual(plain.session.history, [.user("What is on?")])
        XCTAssertTrue(plain.resultStatuses.isEmpty)
        await plain.finish()
    }

    func testAGPLACE_LateLookupAfterANewMessageIsDropped() async {
        let hold = HoldableTransport()
        let rig = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text("Hello back."))], hold: hold)
        rig.session.send("Find a cafe")
        let started = await hold.waitForRequests(1)
        XCTAssertTrue(started, "the lookup is in flight")
        await rig.session.newChat()
        await rig.say("hello")
        XCTAssertEqual(rig.session.assistantTexts, ["Hello back."])

        XCTAssertTrue(hold.release(with: threePlaces), "the old lookup answers late")
        let dropped = await eventually { rig.session.discardedCount == 1 }
        XCTAssertTrue(dropped)
        XCTAssertEqual(rig.session.discardedCount, 1)
        XCTAssertEqual(rig.fake.requests.count, 2, "the late answer started no request")
        XCTAssertEqual(rig.fake.request(2), [.user("hello")], "the new message's request is untouched")
        XCTAssertEqual(rig.session.userTexts, ["hello"])
        XCTAssertEqual(rig.tools.registry.placeHandles, [])
        await rig.finish()
    }

    func testAGPLACE_MaxRequestsIsStillSix() {
        XCTAssertEqual(AgentSession.maxRequests, 6)
    }

    // MARK: - AT: the attribution row (REQ-017)

    /// A session over one chat; `seed` fills the registry first, outside the session, so no `ok` result is latched.
    private func chat(_ steps: [FakeTransport.Step], places: PlacesTransportStub = PlaceStubs.places("places-search-three"),
                      routes: RoutesTransportStub = PlaceStubs.routesByMode(), seed: Bool = false,
                      say text: String = "Go") async -> PlaceSessionRig {
        let rig = PlaceSessionRig(steps, places: places, routes: routes)
        if seed {
            let seeded = await rig.seedPlaces()
            XCTAssertTrue(seeded, "the seed lookup ran")
        }
        await rig.say(text)
        return rig
    }

    func testAGPLACE_AttributionRowFollowsTheFinalAnswerAfterOkLookups() async {
        let rig = await chat([
            .turn(Turns.turn(Turns.message("Looking."), PlaceTurns.searchCall(id: "c1"))),
            .turn(Turns.text("Two cafes.")),
        ], say: "Find a cafe")
        XCTAssertEqual(rig.resultStatuses, ["ok"])
        XCTAssertEqual(rig.session.chatLines, ["USER Find a cafe", "ASSISTANT Two cafes.", "ATTRIBUTION"],
                       "the hidden preface stays hidden and the row follows the text")
        XCTAssertEqual(rig.attributionCount, 1)
        XCTAssertEqual(rig.session.assistantTexts, ["Looking.", "Two cafes."])
        if case .attribution? = rig.session.entries.last?.kind {} else { XCTFail("the row is the last log entry") }
        await rig.finish()
    }

    func testAGPLACE_NoAttributionWhenOnlyErrorsCame() async {
        // no_results
        let none = await chat([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text("No cafes."))],
                              places: PlaceStubs.places("places-empty"))
        XCTAssertEqual(none.resultStatuses, ["no_results"])
        XCTAssertEqual(none.attributionCount, 0)
        XCTAssertFalse(none.session.chatLines.contains("ATTRIBUTION"))

        // unavailable
        let unavailable = await chat([.turn(PlaceTurns.travel("p1", mode: "transit", id: "c1")), .turn(Turns.text("Unavailable."))],
                                     routes: PlaceStubs.routes("routes-google-error-403", status: 403), seed: true)
        XCTAssertEqual(unavailable.resultStatuses, ["unavailable"])
        XCTAssertEqual(unavailable.attributionCount, 0)
        XCTAssertFalse(unavailable.session.chatLines.contains("ATTRIBUTION"))

        // no_route
        let noRoute = await chat([.turn(PlaceTurns.travel("p1", mode: "transit", id: "c1")), .turn(Turns.text("No route."))],
                                 routes: PlaceStubs.routes("routes-empty-object"), seed: true)
        XCTAssertEqual(noRoute.resultStatuses, ["no_route"])
        XCTAssertEqual(noRoute.attributionCount, 0)
        XCTAssertFalse(noRoute.session.chatLines.contains("ATTRIBUTION"))

        // a gate rejection
        let rejected = await chat([.turn(Turns.turn(Turns.call("search_places", #"{"query":""}"#, id: "c1"))),
                                   .turn(Turns.text("Which place?"))])
        XCTAssertEqual(rejected.resultStatuses, ["rejected"])
        XCTAssertEqual(rejected.attributionCount, 0)
        XCTAssertFalse(rejected.session.chatLines.contains("ATTRIBUTION"))

        // An ok lookup whose final turn has an empty message text draws no row either.
        let empty = await chat([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text(""))])
        XCTAssertEqual(empty.resultStatuses, ["ok"])
        XCTAssertEqual(empty.attributionCount, 0)
        XCTAssertEqual(empty.session.chatLines, ["USER Go"])

        // Positive control: the same flow with a final text does draw the row.
        let shown = await chat([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text("Found."))])
        XCTAssertEqual(shown.attributionCount, 1)
    }

    func testPLACEFAIL_AFailedSearchInAChatIsUnavailableAndNotNoResults() async {
        let failing = PlacesTransportStub.answering(status: 500, with: Data("{}".utf8))
        let rig = await chat([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text("I could not look that up."))],
                             places: failing)
        XCTAssertEqual(rig.resultStatuses, ["unavailable"])
        XCTAssertEqual(rig.attributionCount, 0)
        XCTAssertFalse(rig.session.chatLines.contains("ATTRIBUTION"))
        XCTAssertEqual(rig.session.chatLines, ["USER Go", "ASSISTANT I could not look that up."],
                       "the follow-up model turn is shown: the session continued")
        let outputs = callOutputs(rig.session.history)
        XCTAssertEqual(outputs.first.flatMap { TestClock.object($0.result) as NSDictionary? },
                       PlaceText.placesUnavailable as NSDictionary)
        await rig.finish()
    }

    func testAGPLACE_AttributionAppearsOncePerUserMessageAndResetsOnNewChat() async {
        // Two ok lookups in one message give one row.
        let rig = PlaceSessionRig([
            .turn(PlaceTurns.search(id: "c1")),
            .turn(PlaceTurns.travel("p1", mode: "transit", id: "c2")),
            .turn(Turns.text("Done.")),
            .turn(Turns.text("Fine.")),
        ])
        await rig.say("How long to the cafe?")
        XCTAssertEqual(rig.resultStatuses, ["ok", "ok"])
        XCTAssertEqual(rig.session.chatLines.filter { $0 == "ATTRIBUTION" }.count, 1, "one row for two lookups")
        XCTAssertEqual(rig.session.chatLines.last, "ATTRIBUTION")

        // The next message with no lookup gives none.
        await rig.say("Thanks")
        XCTAssertEqual(rig.session.chatLines.filter { $0 == "ATTRIBUTION" }.count, 1, "no new row without a lookup")
        XCTAssertEqual(rig.session.chatLines.last, "ASSISTANT Fine.")

        // The flag latches: an ok search followed by a no_route in the same message still gives the row.
        let latch = await chat([.turn(PlaceTurns.search(id: "c1")),
                                .turn(PlaceTurns.travel("p1", mode: "transit", id: "c2")),
                                .turn(Turns.text("No route found."))],
                               routes: PlaceStubs.routes("routes-empty-object"))
        XCTAssertEqual(latch.resultStatuses, ["ok", "no_route"])
        XCTAssertEqual(latch.session.chatLines.last, "ATTRIBUTION", "a later failed lookup does not clear the flag")
        XCTAssertEqual(latch.attributionCount, 1)

        // A lookup, New chat, then a plain message gives none: the flag was cleared. The lookup's ok result is latched,
        // the model then proposes a card, and New chat resolves it.
        let reset = PlaceSessionRig([.turn(PlaceTurns.search(id: "c1")),
                                     .turn(PlaceTurns.create(place: "p1", id: "c2")),
                                     .turn(Turns.text("Hi."))])
        await reset.say("Add dinner at the cafe")
        XCTAssertEqual(reset.resultStatuses.first, "ok")
        XCTAssertNotNil(reset.session.pendingCard, "the card waits")
        await reset.session.newChat()
        await reset.say("hello")
        XCTAssertEqual(reset.session.chatLines, ["USER hello", "ASSISTANT Hi."])
        XCTAssertEqual(reset.attributionCount, 0)
    }

    func testAGPLACE_AttributionIsLogOnlyAndNotInTheHistory() async {
        let rig = await chat([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text("Two cafes."))], say: "Find a cafe")
        // First: the log does hold the entry, so the absence checks below cannot pass on an empty log.
        XCTAssertEqual(rig.attributionCount, 1, "the log holds the attribution entry")
        XCTAssertEqual(rig.session.history.count, 4, "user, call, output, answer: no entry for the row")
        XCTAssertFalse(rig.historyText.contains("ATTRIBUTION"))
        let instructions = AgentWire.instructions(now: TestClock.now, timeZone: TestClock.zone)
        let body = String(decoding: AgentWire.requestBody(history: rig.session.history, instructions: instructions), as: UTF8.self)
        XCTAssertFalse(body.lowercased().contains("attribution"), "no byte of a request body mentions the row")
        for number in 1..<(rig.fake.requests.count + 1) {
            let sent = String(describing: rig.fake.request(number))
            XCTAssertFalse(sent.lowercased().contains("attribution"))
        }
        XCTAssertGreaterThan(rig.fake.requests.count, 1)
        await rig.finish()
    }

    func testAGPLACE_AttributionTranscriptLine() async {
        let rig = await chat([.turn(PlaceTurns.search(id: "c1")), .turn(Turns.text("Two cafes."))], say: "Find a cafe")
        #if DEBUG
        let lines = rig.session.transcript().components(separatedBy: "\n")
        XCTAssertEqual(lines.last, "ATTRIBUTION", "the transcript prints the row")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(Array(lines.prefix(4)), [
            "USER Find a cafe",
            "TOOL search_places " + PlaceTurns.arguments(["query": "cafe"]),
            "RESULT ok",
            "ASSISTANT Two cafes.",
        ], "the existing lines are unchanged")
        #endif
        await rig.finish()
    }
}
