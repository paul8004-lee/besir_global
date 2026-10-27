import XCTest
@testable import besir

/// The exact lines of spec.md section 3.4, spelled once for the tests (the session has its own copies).
private enum Line {
    static let unreachable = "Couldn't reach the assistant. Check your connection and try again."
    static let slow = "The assistant took too long to answer. Try again."
    static let tokenRejected = "The assistant rejected this build's access token."
    static let unexpected = "The assistant returned an unexpected response."
    static let tooManySteps = "The assistant needed too many steps. Try again with a simpler request."
    static let notSetUp = "The assistant is not set up in this build."
    static func http(_ code: Int) -> String { "The assistant returned an unexpected response (HTTP \(code))." }
    /// SPEC-AGENT-003 section 3.4.
    static let interrupted = "The chat was closed before the assistant replied."
}

private let stepLimitResult = #"{"status":"rejected","message":"Not executed. The step limit was reached."}"#
private let oneAtATimeResult = #"{"status":"rejected","message":"Not executed. Make one tool call at a time."}"#

extension AgentSession {
    var errorLines: [String] {
        entries.compactMap { if case .error(let line) = $0.kind { return line } else { return nil } }
    }
    var noticeLines: [String] {
        entries.compactMap { if case .notice(let line) = $0.kind { return line } else { return nil } }
    }
    var userTexts: [String] {
        entries.compactMap { if case .user(let text) = $0.kind { return text } else { return nil } }
    }
    var assistantTexts: [String] {
        entries.compactMap { if case .assistant(let text) = $0.kind { return text } else { return nil } }
    }
    var historyHasCall: Bool {
        history.contains { entry in
            guard case .assistant(let items, _) = entry else { return false }
            return items.contains { if case .functionCall = $0 { return true } else { return false } }
        }
    }
    var assistantEntryCount: Int {
        history.filter { if case .assistant = $0 { return true } else { return false } }.count
    }
    /// What the chat draws, one tagged line per entry (a card is just `CARD`).
    var chatLines: [String] {
        chatEntries.map { entry -> String in
            switch entry.kind {
            case .user(let text): return "USER \(text)"
            case .assistant(let text): return "ASSISTANT \(text)"
            case .tool(let name, _): return "TOOL \(name)"
            case .result(let status): return "RESULT \(status)"
            case .card: return "CARD"
            case .notice(let line): return "NOTICE \(line)"
            case .error(let line): return "ERROR \(line)"
            }
        }
    }
}

/// A session over a real Store (empty, fixed clock), the real foundation gate and a scripted transport.
@MainActor
struct SessionRig {
    let tools: ToolHarness
    let fake: FakeTransport
    let session: AgentSession

    init(_ steps: [FakeTransport.Step] = []) {
        tools = ToolHarness.make()
        fake = FakeTransport(steps)
        session = AgentSession(toolbox: tools.tools, transport: fake)
    }

    var store: Store { tools.store }

    /// Sends a message and waits until the turn has nothing left in flight.
    func say(_ text: String) async {
        session.send(text)
        await session.settle()
    }
}

@MainActor
final class AgentSessionTests: XCTestCase {

    private func result(of entry: AgentEntry) -> [String: Any]? {
        if case .callOutput(_, let result) = entry { return TestClock.object(result) }
        return nil
    }

    // MARK: - LP001: bound, one call per turn, errors, unusable responses, valid history

    func testLP001_SixthResponseToolCallIsNotExecuted() async {
        // Five list calls, then a create call as the sixth response.
        var steps: [FakeTransport.Step] = (1...5).map { .turn(Turns.list(id: "c\($0)")) }
        steps.append(.turn(Turns.create(id: "c6")))
        let rig = SessionRig(steps)
        await rig.say("Add a meeting.")

        XCTAssertEqual(rig.fake.requests.count, 6)
        // The sixth call was not executed: no card, nothing in the store.
        XCTAssertNil(rig.session.pendingCard)
        XCTAssertTrue(rig.store.activities.isEmpty)
        XCTAssertEqual(rig.session.history.last, .callOutput(callID: "c6", result: stepLimitResult))
        XCTAssertEqual(rig.session.errorLines, [Line.tooManySteps])
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])
        // The earlier calls were executed and answered with data.
        XCTAssertNotNil(result(of: rig.fake.request(6).last ?? .user(""))?["items"])

        // Positive counterpart: the same create call as a first response does produce a card.
        let first = SessionRig([.turn(Turns.create(id: "c1"))])
        await first.say("Add a meeting.")
        XCTAssertNotNil(first.session.pendingCard)
    }

    func testLP001_NoSeventhRequestIsSent() async {
        let steps: [FakeTransport.Step] = (1...8).map { .turn(Turns.list(id: "c\($0)")) }
        let rig = SessionRig(steps)
        await rig.say("What do I have?")
        XCTAssertEqual(rig.fake.requests.count, 6)
        XCTAssertEqual(rig.fake.remaining, 2, "the script held more answers than the bound allows")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(rig.fake.requests.count, 6)
        XCTAssertFalse(rig.session.isWaiting)

        // The bound is per user message: the next message gets its own six (it uses the two leftover list answers, then this one).
        rig.fake.enqueue(.turn(Turns.text("Nothing.")))
        await rig.say("And now?")
        XCTAssertEqual(rig.fake.requests.count, 9)
        XCTAssertEqual(rig.session.assistantTexts, ["Nothing."])
    }

    func testLP001_ExtraCallsInOneResponseAreRejectedNotExecuted() async {
        let rig = SessionRig()
        let seeded = rig.tools.seed("Team sync", "2026-10-28T15:00", "2026-10-28T16:00")
        let first = Turns.call("list_activities", Turns.listArguments, id: "c1")
        let second = Turns.call("delete_activity", "{\"id\":\"\(seeded.id.uuidString)\"}", id: "c2")
        rig.fake.enqueue(.turn(Turns.turn(first, second)), .turn(Turns.text("You have one event.")))
        let before = rig.tools.snapshot
        await rig.say("What do I have, and delete it.")

        XCTAssertEqual(rig.fake.requests.count, 2)
        let next = rig.fake.request(2)
        XCTAssertEqual(next.count, 4)
        guard next.count == 4 else { return }
        // User message, the model's output as received, then the outputs in call order.
        XCTAssertEqual(next[1], .assistant([first, second], responseID: nil))
        guard case .callOutput(let firstID, _) = next[2], case .callOutput(let secondID, let secondResult) = next[3] else {
            return XCTFail("two outputs expected")
        }
        XCTAssertEqual([firstID, secondID], ["c1", "c2"])
        XCTAssertNotNil(result(of: next[2])?["items"], "the first call is answered with data")
        XCTAssertEqual(secondResult, oneAtATimeResult)
        // Nothing was executed or queued for the second call.
        XCTAssertNil(rig.session.pendingCard)
        XCTAssertEqual(rig.tools.snapshot, before)
        XCTAssertEqual(rig.store.activities.count, 1)
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])
        // Positive counterpart: alone, that delete call is accepted as a card.
        XCTAssertNotNil(rig.tools.call("delete_activity", ["id": seeded.id.uuidString]).card)
    }

    func testLP001_HistoryStaysValidAfterEveryTurnEnd() async {
        var checked = 0
        func check(_ name: String, _ rig: SessionRig, calls: Bool) {
            checked += 1
            XCTAssertFalse(rig.session.history.isEmpty, name)
            XCTAssertEqual(rig.session.historyHasCall, calls, name)
            XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [], name)
        }

        // Normal end: reasoning, a call, then the answer.
        let normal = SessionRig([
            .turn(Turns.turn(Turns.reasoning(), Turns.call("list_activities", Turns.listArguments, id: "c1"))),
            .turn(Turns.turn(Turns.reasoning(), Turns.message("Nothing.")))
        ])
        await normal.say("What do I have?")
        check("normal", normal, calls: true)

        // Step limit.
        let limited = SessionRig((1...6).map { .turn(Turns.list(id: "c\($0)")) })
        await limited.say("Loop.")
        check("limit", limited, calls: true)

        // Error after a tool result.
        let failing = SessionRig([.turn(Turns.list(id: "c1")), .fail(AgentTransportError.http(status: 500, body: Data()))])
        await failing.say("What do I have?")
        XCTAssertEqual(failing.session.errorLines, [Line.http(500)])
        check("error", failing, calls: true)

        // Cancel by closing the sheet with a card pending.
        let dismissed = SessionRig([.turn(Turns.turn(Turns.reasoning(), Turns.call("create_activity", Turns.createArguments, id: "c1")))])
        await dismissed.say("Add it.")
        XCTAssertNotNil(dismissed.session.pendingCard)
        await dismissed.session.sheetDismissed()
        check("sheet dismissal", dismissed, calls: true)

        // Cancel with a card and extra calls in the same response.
        let extras = SessionRig([.turn(Turns.turn(Turns.call("create_activity", Turns.createArguments, id: "c1"),
                                                  Turns.call("list_activities", Turns.listArguments, id: "c2")))])
        await extras.say("Add it.")
        await extras.session.sheetDismissed()
        check("dismissal with extra calls", extras, calls: true)

        // A request cancelled in flight leaves the earlier history untouched.
        let flight = SessionRig([.turn(Turns.list(id: "c1")), .hold])
        flight.session.send("What do I have?")
        _ = await flight.fake.waitForRequests(2)
        await flight.session.sheetDismissed()
        check("cancel in flight", flight, calls: true)

        XCTAssertEqual(checked, 6)
    }

    func testLP001_ErrorLinesByCategory() async {
        let unauthorized = Data(#"{"error":"unauthorized"}"#.utf8)
        let cases: [(AgentTransportError, String)] = [
            (.offline, Line.unreachable),
            (.timedOut, Line.slow),
            (.http(status: 401, body: unauthorized), Line.tokenRejected),
            (.http(status: 401, body: Data("nope".utf8)), Line.http(401)),
            (.http(status: 400, body: Data()), Line.http(400)),
            (.http(status: 404, body: Data()), Line.http(404)),
            (.http(status: 429, body: Data()), Line.http(429)),
            (.http(status: 502, body: Data()), Line.http(502)),
            (.unreadableBody, Line.unexpected),
            (.other, Line.unexpected),
        ]
        for (error, line) in cases {
            let rig = SessionRig([.fail(error)])
            await rig.say("Hello")
            XCTAssertEqual(rig.fake.requests.count, 1, "\(error)")
            XCTAssertEqual(rig.session.errorLines, [line], "\(error)")
            XCTAssertEqual(rig.session.userTexts, ["Hello"], "\(error)")
            XCTAssertTrue(rig.session.noticeLines.isEmpty)
            XCTAssertFalse(rig.session.isWaiting)
        }
        // An error that is not one of ours is the generic line.
        let rig = SessionRig([.fail(FakeTransport.Unscripted())])
        await rig.say("Hello")
        XCTAssertEqual(rig.session.errorLines, [Line.unexpected])
    }

    func testLP001_ErrorLinesNeverContainURLTokenOrBody() async {
        let rig = SessionRig()
        // The positive control: each sentinel exists where a leak could come from.
        let body = "BODY-SENTINEL-0001 \(FakeTransport.host) \(FakeTransport.token)"
        XCTAssertTrue(rig.fake.requestURL.absoluteString.contains(FakeTransport.host))
        XCTAssertTrue(body.contains(FakeTransport.token))
        let errors: [AgentTransportError] = [
            .http(status: 500, body: Data(body.utf8)),
            .http(status: 401, body: Data(body.utf8)),
            .http(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8)),
            .offline, .timedOut, .other, .unreadableBody,
        ]
        for error in errors {
            rig.fake.enqueue(.fail(error))
            await rig.say("Hello")
        }
        // An unusable response whose raw bytes hold the sentinels gets the generic line, not the bytes.
        rig.fake.enqueue(.turn(Turns.turn(.reasoning(raw: Data(body.utf8)))))
        await rig.say("Hello")

        XCTAssertEqual(rig.session.errorLines.count, errors.count + 1)
        for line in rig.session.errorLines {
            for sentinel in [FakeTransport.host, FakeTransport.token, "BODY-SENTINEL-0001", "https://", "http://"] {
                XCTAssertFalse(line.contains(sentinel), "\(line) contains \(sentinel)")
            }
        }
    }

    func testLP001_ConversationUsableAfterAnError() async {
        let rig = SessionRig([.fail(AgentTransportError.offline), .turn(Turns.text("Hello again."))])
        await rig.say("First")
        XCTAssertEqual(rig.session.errorLines, [Line.unreachable])
        XCTAssertTrue(rig.session.canSend)
        XCTAssertFalse(rig.session.isWaiting)
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])

        await rig.say("Second")
        XCTAssertEqual(rig.fake.requests.count, 2)
        XCTAssertEqual(rig.fake.request(2), [.user("First"), .user("Second")])
        XCTAssertEqual(rig.session.assistantTexts, ["Hello again."])
        XCTAssertEqual(rig.session.errorLines, [Line.unreachable], "the old line stays, no new one")
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])
    }

    func testLP001_UnconfiguredBuildSendsNothing() async {
        let rig = SessionRig([.turn(Turns.text("Hi."))])
        rig.fake.isConfigured = false
        await rig.say("Hello")
        XCTAssertEqual(rig.fake.requests.count, 0)
        XCTAssertEqual(rig.session.errorLines, [Line.notSetUp])
        XCTAssertFalse(rig.session.isWaiting)

        // Positive counterpart: the same session, once configured, sends.
        rig.fake.isConfigured = true
        await rig.say("Hello again")
        XCTAssertEqual(rig.fake.requests.count, 1)
        XCTAssertEqual(rig.session.assistantTexts, ["Hi."])

        // The shipped placeholder transport is unconfigured and never sends.
        let placeholder = AgentSession(toolbox: rig.tools.tools, transport: AgentPendingTransport())
        placeholder.send("Hello")
        await placeholder.settle()
        XCTAssertEqual(placeholder.errorLines, [Line.notSetUp])
    }

    func testLP001_MetaUnauthorizedIsNotReportedAsATokenRejection() async {
        let worker = Data(#"{"error":"unauthorized"}"#.utf8)
        let others: [Data] = [Data(), Data("Unauthorized".utf8), Data(#"{"error":"invalid_api_key"}"#.utf8),
                              Data(#"{"error":"unauthorized","detail":"x"}"#.utf8), Data(#"{"message":"unauthorized"}"#.utf8)]
        let own = SessionRig([.fail(AgentTransportError.http(status: 401, body: worker))])
        await own.say("Hello")
        XCTAssertEqual(own.session.errorLines, [Line.tokenRejected])

        for body in others {
            let rig = SessionRig([.fail(AgentTransportError.http(status: 401, body: body))])
            await rig.say("Hello")
            XCTAssertEqual(rig.session.errorLines, [Line.http(401)], String(decoding: body, as: UTF8.self))
        }
        // The Worker body on another status is not a token rejection either.
        let other = SessionRig([.fail(AgentTransportError.http(status: 403, body: worker))])
        await other.say("Hello")
        XCTAssertEqual(other.session.errorLines, [Line.http(403)])
    }

    func testLP001_ReasoningOnlyResponseAppendsNothingAndShowsErrorLine() async {
        let unusable: [(String, AgentTurn)] = [
            ("reasoning only", Turns.turn(Turns.reasoning())),
            ("empty output", AgentTurn(items: [])),
            ("call without call id", Turns.turn(.functionCall(callID: nil, name: "list_activities", arguments: "{}", raw: Data("x".utf8)))),
            ("call without name", Turns.turn(.functionCall(callID: "c1", name: nil, arguments: "{}", raw: Data("x".utf8)))),
            ("reasoning then call without id", Turns.turn(Turns.reasoning(), .functionCall(callID: nil, name: "list_activities", arguments: "{}", raw: Data("x".utf8)))),
            ("status not completed", Turns.turn(Turns.message("partial"), completed: false)),
        ]
        for (name, turn) in unusable {
            let rig = SessionRig([.turn(turn), .turn(Turns.text("Fine."))])
            await rig.say("First")
            XCTAssertEqual(rig.fake.requests.count, 1, name)
            XCTAssertEqual(rig.session.errorLines, [Line.unexpected], name)
            XCTAssertEqual(rig.session.history, [.user("First")], name)
            XCTAssertTrue(rig.session.assistantTexts.isEmpty, name)

            // The next message sends a valid request and is answered.
            await rig.say("Second")
            XCTAssertEqual(rig.fake.requests.count, 2, name)
            XCTAssertEqual(rig.fake.request(2), [.user("First"), .user("Second")], name)
            XCTAssertEqual(PairingValidator.problems(in: rig.fake.request(2)), [], name)
            XCTAssertEqual(rig.session.assistantTexts, ["Fine."], name)
        }
        // Positive counterpart: a usable turn is appended.
        let usable = SessionRig([.turn(Turns.turn(Turns.reasoning(), Turns.message("Hi.")))])
        await usable.say("First")
        XCTAssertEqual(usable.session.assistantEntryCount, 1)
        XCTAssertTrue(usable.session.errorLines.isEmpty)

        // A reasoning item that ends an otherwise usable response is not replayed.
        let trailing = SessionRig([.turn(Turns.turn(Turns.message("Hi."), Turns.reasoning()))])
        await trailing.say("First")
        XCTAssertEqual(PairingValidator.problems(in: trailing.session.history), [])
        XCTAssertEqual(trailing.session.assistantEntryCount, 1)
    }

    func testLP001_PairingValidatorRejectsADanglingHistory() {
        let call = Turns.call("list_activities", "{}", id: "c1")
        let call2 = Turns.call("list_activities", "{}", id: "c2")
        let valid: [AgentEntry] = [.user("a"), .assistant([Turns.reasoning(), call, call2], responseID: nil),
                                   .callOutput(callID: "c1", result: "{}"), .callOutput(callID: "c2", result: "{}"),
                                   .assistant([Turns.reasoning(), Turns.message("done")], responseID: nil)]
        XCTAssertEqual(PairingValidator.problems(in: valid), [])

        // A call without its output.
        XCTAssertFalse(PairingValidator.problems(in: [.user("a"), .assistant([call], responseID: nil)]).isEmpty)
        // A call whose output comes only after the next user message.
        XCTAssertFalse(PairingValidator.problems(in: [.assistant([call], responseID: nil), .user("b"), .callOutput(callID: "c1", result: "{}")]).isEmpty)
        // Outputs in the wrong order.
        XCTAssertFalse(PairingValidator.problems(in: [.assistant([call, call2], responseID: nil),
                                                      .callOutput(callID: "c2", result: "{}"), .callOutput(callID: "c1", result: "{}")]).isEmpty)
        // An output without a call.
        XCTAssertFalse(PairingValidator.problems(in: [.user("a"), .callOutput(callID: "c9", result: "{}")]).isEmpty)
        // A reasoning item at the end of an output, and one followed by another reasoning item.
        XCTAssertFalse(PairingValidator.problems(in: [.assistant([Turns.message("x"), Turns.reasoning()], responseID: nil)]).isEmpty)
        XCTAssertFalse(PairingValidator.problems(in: [.assistant([Turns.reasoning(), Turns.reasoning(), Turns.message("x")], responseID: nil)]).isEmpty)
    }

    // MARK: - LP002: re-entrancy, leaving the conversation, cancellation

    func testLP002_SendIsIgnoredWhileARequestIsInFlight() async {
        let rig = SessionRig([.hold, .turn(Turns.text("Second answer."))])
        rig.session.send("first")
        let reached = await rig.fake.waitForRequests(1)
        XCTAssertTrue(reached)
        XCTAssertTrue(rig.session.isWaiting)
        XCTAssertFalse(rig.session.canSend)

        rig.session.send("second")
        XCTAssertEqual(rig.session.userTexts, ["first"])
        XCTAssertEqual(rig.fake.requests.count, 1)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(rig.fake.requests.count, 1)

        rig.fake.release(1, .success(Turns.text("First answer.")))
        await rig.session.settle()
        XCTAssertTrue(rig.session.canSend)
        // Positive counterpart: once the request is done, Send is accepted.
        await rig.say("second")
        XCTAssertEqual(rig.session.userTexts, ["first", "second"])
        XCTAssertEqual(rig.fake.requests.count, 2)
    }

    func testLP002_SendIsIgnoredWhileACardIsPending() async {
        let rig = SessionRig([.turn(Turns.create(id: "c1")), .turn(Turns.text("Cancelled, ok.")), .turn(Turns.text("Sure."))])
        await rig.say("Add a meeting.")
        XCTAssertNotNil(rig.session.pendingCard)
        XCTAssertEqual(rig.fake.requests.count, 1)
        XCTAssertFalse(rig.session.canSend)

        let entriesBefore = rig.session.entries.count
        rig.session.send("again")
        XCTAssertEqual(rig.session.entries.count, entriesBefore)
        XCTAssertEqual(rig.session.userTexts, ["Add a meeting."])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(rig.fake.requests.count, 1)

        // Positive counterpart: after the card is resolved Send works again.
        await rig.session.cancelCard()
        await rig.session.settle()
        XCTAssertNil(rig.session.pendingCard)
        XCTAssertEqual(rig.fake.requests.count, 2)
        XCTAssertTrue(rig.session.canSend)
        await rig.say("again")
        XCTAssertEqual(rig.session.userTexts, ["Add a meeting.", "again"])
    }

    func testLP002_NewChatWithPendingCardResolvesDeclinedWithNoOrphanCall() async {
        let rig = SessionRig([.turn(Turns.create(id: "c1"))])
        await rig.say("Add a meeting.")
        guard let card = rig.session.pendingCard else { return XCTFail("a card should be pending") }
        XCTAssertTrue(rig.session.historyHasCall)

        await rig.session.newChat()
        XCTAssertEqual(card.mark, .cancelled)
        XCTAssertTrue(rig.store.activities.isEmpty, "nothing applied")
        XCTAssertNil(rig.session.pendingCard)
        XCTAssertTrue(rig.session.entries.isEmpty)
        XCTAssertTrue(rig.session.history.isEmpty, "no call without its output is left")
        XCTAssertTrue(rig.session.errorLines.isEmpty)
        XCTAssertEqual(rig.fake.requests.count, 1, "New chat sends nothing")
        XCTAssertTrue(rig.session.canSend)
        // The card is spent: a late Confirm applies nothing.
        let late = await card.resolve(.confirm)
        XCTAssertNil(late)
        XCTAssertTrue(rig.store.activities.isEmpty)

        // Positive counterpart: confirming the same kind of card does apply it.
        let other = SessionRig([.turn(Turns.create(id: "c1")), .turn(Turns.text("Added."))])
        await other.say("Add a meeting.")
        await other.session.confirmCard()
        await other.session.settle()
        XCTAssertEqual(other.store.activities.count, 1)
    }

    func testLP002_SheetDismissalWithPendingCardResolvesDeclinedWithoutRequest() async {
        let rig = SessionRig([.turn(Turns.create(id: "c1")), .turn(Turns.text("Ok."))])
        await rig.say("Add a meeting.")
        guard let card = rig.session.pendingCard else { return XCTFail("a card should be pending") }

        await rig.session.sheetDismissed()
        XCTAssertEqual(rig.fake.requests.count, 1, "no request at dismissal")
        XCTAssertEqual(card.mark, .cancelled)
        XCTAssertNil(rig.session.pendingCard)
        XCTAssertTrue(rig.store.activities.isEmpty)
        // The conversation is kept, and the declined output follows its call.
        XCTAssertEqual(rig.session.userTexts, ["Add a meeting."])
        XCTAssertEqual(rig.session.history.count, 3)
        XCTAssertEqual(rig.session.history.last, .callOutput(callID: "c1", result: AgentToolbox.declinedResult))
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])
        XCTAssertTrue(rig.session.errorLines.isEmpty)

        // The next message's request carries the call and its declined output.
        await rig.say("What do I have?")
        XCTAssertEqual(rig.fake.requests.count, 2)
        let carried = rig.fake.request(2)
        XCTAssertEqual(carried.count, 4)
        XCTAssertTrue(carried.contains(.callOutput(callID: "c1", result: AgentToolbox.declinedResult)))
        XCTAssertEqual(carried.last, .user("What do I have?"))
        XCTAssertEqual(PairingValidator.problems(in: carried), [])
    }

    private enum Cause: String { case newChat, sheetClose }
    private enum Delivery: String { case response, error }

    private func cancel(_ cause: Cause, _ rig: SessionRig) async {
        switch cause {
        case .newChat: await rig.session.newChat()
        case .sheetClose: await rig.session.sheetDismissed()
        }
    }

    func testLP002_LateResponseAfterNewChatIsDiscarded() async {
        for cause in [Cause.newChat, .sheetClose] {
            for delivery in [Delivery.response, .error] {
                let label = "\(cause.rawValue)/\(delivery.rawValue)"
                // The old response would, if accepted, show text and queue a card.
                let stale = Turns.turn(Turns.message("OLD ANSWER"), Turns.call("create_activity", Turns.createArguments, id: "old1"))
                let rig = SessionRig([.hold, .hold])
                rig.session.send("old question")
                let first = await rig.fake.waitForRequests(1)
                XCTAssertTrue(first, label)
                await cancel(cause, rig)
                XCTAssertFalse(rig.session.isWaiting, label)

                // A new message is sent before the old answer arrives.
                rig.session.send("new question")
                let second = await rig.fake.waitForRequests(2)
                XCTAssertTrue(second, label)
                XCTAssertTrue(rig.session.isWaiting, label)

                switch delivery {
                case .response:
                    XCTAssertTrue(rig.fake.release(1, .success(stale)), label)
                case .error:
                    XCTAssertTrue(rig.fake.release(1, .failure(AgentTransportError.http(status: 500, body: Data("BODY".utf8)))), label)
                }
                let dropped = await eventually { rig.session.discardedCount == 1 }
                XCTAssertTrue(dropped, label)

                XCTAssertNil(rig.session.pendingCard, label)
                XCTAssertTrue(rig.store.activities.isEmpty, label)
                XCTAssertTrue(rig.session.errorLines.isEmpty, label)
                XCTAssertFalse(rig.session.assistantTexts.contains("OLD ANSWER"), label)
                XCTAssertEqual(rig.session.assistantEntryCount, 0, label)
                XCTAssertTrue(rig.session.isWaiting, "the new request is still the awaited one: \(label)")
                let expectedUsers = cause == .newChat ? ["new question"] : ["old question", "new question"]
                XCTAssertEqual(rig.session.userTexts, expectedUsers, label)
                XCTAssertEqual(rig.fake.request(2).count, expectedUsers.count, label)

                // The identity of the awaited request still decides: its answer is accepted.
                rig.fake.release(2, .success(Turns.text("NEW ANSWER")))
                await rig.session.settle()
                XCTAssertEqual(rig.session.assistantTexts, ["NEW ANSWER"], label)
                XCTAssertFalse(rig.session.isWaiting, label)
            }
        }
    }

    func testLP002_CancelledRequestShowsNoErrorLine() async {
        for cause in [Cause.newChat, .sheetClose] {
            for error in [AgentTransportError.cancelled as Error, CancellationError(), URLError(.cancelled)] {
                let label = "\(cause.rawValue)/\(error)"
                let rig = SessionRig([.hold, .turn(Turns.text("Fine."))])
                rig.session.send("old question")
                let reached = await rig.fake.waitForRequests(1)
                XCTAssertTrue(reached, label)
                await cancel(cause, rig)

                XCTAssertTrue(rig.fake.release(1, .failure(error)), label)
                let dropped = await eventually { rig.session.discardedCount == 1 }
                XCTAssertTrue(dropped, label)
                XCTAssertTrue(rig.session.errorLines.isEmpty, label)
                // New chat stays silent; closing the sheet with the request in flight leaves the one status line.
                XCTAssertEqual(rig.session.noticeLines, cause == .newChat ? [] : [Line.interrupted], label)
                XCTAssertEqual(rig.session.history, cause == .newChat ? [] : [.user("old question")], label)
                XCTAssertTrue(rig.session.canSend, label)

                // The chat still works afterwards.
                await rig.say("again")
                XCTAssertEqual(rig.session.assistantTexts, ["Fine."], label)
            }
        }
        // A cancellation that reaches the request still awaited ends the turn without a line, and a real error does show one.
        let rig = SessionRig([.fail(AgentTransportError.cancelled), .fail(AgentTransportError.offline)])
        await rig.say("one")
        XCTAssertTrue(rig.session.errorLines.isEmpty)
        XCTAssertTrue(rig.session.canSend)
        XCTAssertFalse(rig.session.isWaiting)
        await rig.say("two")
        XCTAssertEqual(rig.session.errorLines, [Line.unreachable])
    }

    /// A delete card is shown for `Team sync`; `change` then alters the store; Confirm continues the turn with the
    /// result, which counts toward the six: five more list calls follow and the sixth response ends in the step limit.
    private func continuation(_ status: String, change: (SessionRig, ActivityBlock) -> Void) async {
        let rig = SessionRig()
        let seeded = rig.tools.seed("Team sync", "2026-10-28T15:00", "2026-10-28T16:00")
        var steps: [FakeTransport.Step] = [.turn(Turns.delete(seeded.id, id: "d1"))]
        steps += (2...6).map { .turn(Turns.list(id: "c\($0)")) }
        steps.append(.turn(Turns.text("never asked for")))
        rig.fake.enqueue(contentsOf: steps)

        await rig.say("Delete Team sync.")
        guard let card = rig.session.pendingCard else { return XCTFail("a card should be pending") }
        change(rig, seeded)
        await rig.session.confirmCard()
        await rig.session.settle()

        XCTAssertEqual(card.mark, .notApplied, status)
        XCTAssertEqual(rig.session.noticeLines, [ToolText.notice], status)
        XCTAssertEqual(rig.fake.requests.count, 6, "the notice continuation counted as request 2: \(status)")
        XCTAssertEqual(rig.fake.remaining, 1, status)
        XCTAssertEqual(rig.session.errorLines, [Line.tooManySteps], status)
        // The result went to the model in the next request.
        let second = rig.fake.request(2)
        XCTAssertEqual(result(of: second.last ?? .user(""))?["status"] as? String, status)
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [], status)
    }

    func testLP002_NotFoundResultContinuesTheTurnWithNoticeLine() async {
        await continuation("not_found") { rig, _ in rig.store.activities.removeAll() }

        // Positive counterpart: an unchanged record is applied, with no notice line.
        let rig = SessionRig()
        let seeded = rig.tools.seed("Team sync", "2026-10-28T15:00", "2026-10-28T16:00")
        rig.fake.enqueue(.turn(Turns.delete(seeded.id, id: "d1")), .turn(Turns.text("Deleted.")))
        await rig.say("Delete Team sync.")
        await rig.session.confirmCard()
        await rig.session.settle()
        XCTAssertTrue(rig.session.noticeLines.isEmpty)
        XCTAssertTrue(rig.store.activities.isEmpty)
        XCTAssertEqual(result(of: rig.fake.request(2).last ?? .user(""))?["status"] as? String, "applied")
    }

    func testLP002_StaleResultContinuesTheTurnWithNoticeLine() async {
        await continuation("stale") { rig, seeded in
            if let index = rig.store.activities.firstIndex(where: { $0.id == seeded.id }) {
                rig.store.activities[index].title = "Renamed after the card"
            }
        }
    }

    // MARK: - SPEC-AGENT-003 PL002: preface bubbles are not drawn (AC-POLISH-004)

    func testPL002_ChatHidesOnePrefaceBeforeAToolCall() async {
        let rig = SessionRig([
            .turn(Turns.turn(Turns.message("Looking."), Turns.call("list_activities", Turns.listArguments, id: "c1"))),
            .turn(Turns.text("Nothing.")),
        ])
        await rig.say("What is on?")
        XCTAssertEqual(rig.session.assistantTexts, ["Looking.", "Nothing."], "the log keeps the preface")
        XCTAssertEqual(rig.session.chatLines, ["USER What is on?", "ASSISTANT Nothing."])
    }

    func testPL002_ChatHidesAConsecutiveRunOfPrefaces() async {
        let rig = SessionRig([
            .turn(Turns.turn(Turns.message("First."), Turns.message("Second."),
                             Turns.call("list_activities", Turns.listArguments, id: "c1"))),
            .turn(Turns.text("Nothing.")),
        ])
        await rig.say("What is on?")
        XCTAssertEqual(rig.session.assistantTexts, ["First.", "Second.", "Nothing."], "both prefaces stay in the log")
        XCTAssertEqual(rig.session.chatLines, ["USER What is on?", "ASSISTANT Nothing."])
    }

    func testPL002_ChatKeepsTheFinalAnswerAfterAToolResult() async {
        let rig = SessionRig([
            .turn(Turns.turn(Turns.message("Looking A."), Turns.call("list_activities", Turns.listArguments, id: "c1"))),
            .turn(Turns.text("Answer A.")),
            .turn(Turns.turn(Turns.message("Looking B."), Turns.call("list_activities", Turns.listArguments, id: "c2"))),
            .turn(Turns.text("Answer B.")),
        ])
        await rig.say("First question")
        await rig.say("Second question")
        XCTAssertEqual(rig.session.chatLines, ["USER First question", "ASSISTANT Answer A.",
                                                "USER Second question", "ASSISTANT Answer B."])
        XCTAssertEqual(rig.session.assistantTexts.count, 4, "the log keeps all four")
    }

    func testPL002_ChatKeepsCardNoticeAndErrorNextToAHiddenPreface() async {
        // A preface and a create call: the card is drawn, the preface is not.
        let card = SessionRig([.turn(Turns.turn(Turns.message("Adding."), Turns.call("create_activity", Turns.createArguments, id: "c1")))])
        await card.say("Add it.")
        XCTAssertNotNil(card.session.pendingCard)
        XCTAssertEqual(card.session.assistantTexts, ["Adding."])
        XCTAssertEqual(card.session.chatLines, ["USER Add it.", "CARD"])

        // A preface and a call, then a transport error: the error line is drawn, the preface is not.
        let failing = SessionRig([.turn(Turns.turn(Turns.message("Looking."), Turns.call("list_activities", Turns.listArguments, id: "c1"))),
                                  .fail(AgentTransportError.offline)])
        await failing.say("What is on?")
        XCTAssertEqual(failing.session.assistantTexts, ["Looking."])
        XCTAssertEqual(failing.session.chatLines, ["USER What is on?", "ERROR \(Line.unreachable)"])

        // A preface and a delete call whose record went stale: the notice line and the answer after it are drawn.
        let stale = SessionRig()
        let seeded = stale.tools.seed("Team sync", "2026-10-28T15:00", "2026-10-28T16:00")
        stale.fake.enqueue(.turn(Turns.turn(Turns.message("Checking."), Turns.call("delete_activity", "{\"id\":\"\(seeded.id.uuidString)\"}", id: "d1"))),
                           .turn(Turns.text("Gone.")))
        await stale.say("Delete Team sync.")
        stale.store.activities.removeAll()
        await stale.session.confirmCard()
        await stale.session.settle()
        XCTAssertEqual(stale.session.assistantTexts, ["Checking.", "Gone."])
        XCTAssertEqual(stale.session.chatLines, ["USER Delete Team sync.", "CARD", "NOTICE \(ToolText.notice)", "ASSISTANT Gone."])
    }

    /// A guard that pins behavior that must not change: an answer with no tool call is always drawn.
    func testPL002_ChatKeepsAnAnswerThatCallsNoTool() async {
        let rig = SessionRig([
            .turn(Turns.text("Hello.")),
            .turn(Turns.turn(Turns.reasoning(), Turns.message("Again."))),
        ])
        await rig.say("Hi")
        XCTAssertEqual(rig.session.chatLines, ["USER Hi", "ASSISTANT Hello."])
        await rig.say("Hi again")
        XCTAssertEqual(rig.session.chatLines, ["USER Hi", "ASSISTANT Hello.", "USER Hi again", "ASSISTANT Again."])
    }

    // MARK: - SPEC-AGENT-003 PL003: the interrupted-reply line (AC-POLISH-006)

    func testPL003_ClosingTheSheetMidRequestAppendsTheInterruptedNoticeOnce() async {
        let rig = SessionRig([.hold])
        rig.session.send("What is on?")
        let reached = await rig.fake.waitForRequests(1)
        XCTAssertTrue(reached)
        XCTAssertTrue(rig.session.isWaiting)

        await rig.session.sheetDismissed()
        XCTAssertEqual(rig.session.noticeLines, [Line.interrupted])
        XCTAssertTrue(rig.session.errorLines.isEmpty)
        XCTAssertFalse(rig.session.isWaiting)

        await rig.session.sheetDismissed()
        XCTAssertEqual(rig.session.noticeLines, [Line.interrupted], "a second close adds nothing")
    }

    func testPL003_InterruptedNoticeLeavesHistoryValidAndTheNextMessageWorks() async {
        let rig = SessionRig([.hold, .hold])
        rig.session.send("old question")
        let first = await rig.fake.waitForRequests(1)
        XCTAssertTrue(first)
        await rig.session.sheetDismissed()
        XCTAssertEqual(rig.session.noticeLines, [Line.interrupted], "the line is there before the history is read")
        XCTAssertEqual(rig.session.history, [.user("old question")])
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])

        rig.session.send("new question")
        let second = await rig.fake.waitForRequests(2)
        XCTAssertTrue(second)
        XCTAssertEqual(rig.fake.request(2), [.user("old question"), .user("new question")])

        // The cancelled request answers late, during the next request: it is dropped.
        XCTAssertTrue(rig.fake.release(1, .success(Turns.text("OLD ANSWER"))))
        let dropped = await eventually { rig.session.discardedCount == 1 }
        XCTAssertTrue(dropped)
        XCTAssertTrue(rig.session.isWaiting, "the new request is still the awaited one")

        rig.fake.release(2, .success(Turns.text("NEW ANSWER")))
        await rig.session.settle()
        XCTAssertEqual(rig.session.assistantTexts, ["NEW ANSWER"])
        XCTAssertEqual(rig.session.noticeLines, [Line.interrupted])
        XCTAssertEqual(PairingValidator.problems(in: rig.session.history), [])
    }

    func testPL003_NoNoticeWhenIdleOrCardPendingOrNewChat() async {
        // Positive control: the same close with a request in flight does show the line.
        let flight = SessionRig([.hold])
        flight.session.send("What is on?")
        let reached = await flight.fake.waitForRequests(1)
        XCTAssertTrue(reached)
        await flight.session.sheetDismissed()
        XCTAssertEqual(flight.session.noticeLines, [Line.interrupted])

        // Idle after a completed answer.
        let idle = SessionRig([.turn(Turns.text("Hi."))])
        await idle.say("Hello")
        XCTAssertFalse(idle.session.isWaiting)
        await idle.session.sheetDismissed()
        XCTAssertTrue(idle.session.noticeLines.isEmpty)
        XCTAssertEqual(idle.session.chatLines, ["USER Hello", "ASSISTANT Hi."])

        // Only a card pending: the card shows Cancelled, no line.
        let pending = SessionRig([.turn(Turns.create(id: "c1"))])
        await pending.say("Add it.")
        guard let card = pending.session.pendingCard else { return XCTFail("a card should be pending") }
        await pending.session.sheetDismissed()
        XCTAssertEqual(card.mark, .cancelled)
        XCTAssertTrue(pending.session.noticeLines.isEmpty)

        // New chat with a request in flight stays silent, and a close afterwards adds nothing.
        let fresh = SessionRig([.hold])
        fresh.session.send("What is on?")
        let started = await fresh.fake.waitForRequests(1)
        XCTAssertTrue(started)
        await fresh.session.newChat()
        XCTAssertTrue(fresh.session.entries.isEmpty)
        await fresh.session.sheetDismissed()
        XCTAssertTrue(fresh.session.noticeLines.isEmpty)
    }
}
