import XCTest
@testable import besir

/// SPEC-CHOICECARD-001 AC-CHOICECARD-011 and 012 (REQ-011, 012): the third form of `AgentCard` carries a field-card model.
/// Its `canConfirm` is the model's readiness, Confirm freezes the model before the confirm closure runs, Cancel and dismiss run
/// no closure, and a second resolution returns nil. The two older forms keep their behaviour. The chat drawing itself is judged
/// on the simulator walk (W1), not here.
@MainActor
final class AgentFieldCardCardTests: XCTestCase {
    private let now = TestClock.now
    private let arrival = TestClock.date("2026-10-28T19:40")

    private let arriveSpec = AgentFieldSpec(key: "arrive_at", kind: .time, label: "Arrival")
    private let addressSpec = AgentFieldSpec(key: "address", kind: .place, label: "Delivery place")
    private let pay = AgentFieldSpec(key: "card_id", kind: .pickOne, label: "Pay with",
                                     options: [AgentFieldOption(id: "debit", label: "Debit one"), AgentFieldOption(id: "credit", label: "Credit two")])

    private let library = Place(name: "Library", address: "9 Library Road", latitude: 37.5, longitude: -122.4)

    /// A model with the place blank and the card chosen, as `order_delivery` builds it for a call that names no place.
    private func model() -> AgentFieldCard {
        AgentFieldCard(header: "Order delivery",
                       rows: [.line("Pasta Palace"),
                              .field(arriveSpec, value: .time(arrival), source: .stated),
                              .field(addressSpec, value: nil, source: .blank),
                              .field(pay, value: .option("debit"), source: .stated)],
                       favorites: [], search: { _ in [] }, now: { [now] in now })
    }

    /// What the confirm closure of a test saw when it ran.
    private final class Run {
        var count = 0
        var frozenWhenRun: Bool?
        var changeAppliedInside: Bool?
    }

    private func card(_ model: AgentFieldCard, _ run: Run, showsGoogleMark: Bool = true) -> AgentCard {
        AgentCard(fieldCard: model, showsGoogleMark: showsGoogleMark) {
            run.count += 1
            run.frozenWhenRun = model.isFrozen
            run.changeAppliedInside = model.chooseOption("card_id", "credit")
            return (AgentResolution(result: #"{"status":"applied"}"#, notice: nil), .confirmed)
        }
    }

    // MARK: K01

    func testK01_TheThirdFormFollowsTheModelFreezesOnConfirmAndResolvesOnce() async throws {
        let fields = model()
        let run = Run()
        let pending = card(fields, run)

        // Positive first: the card carries the model, its lines come from it, and Confirm waits for the blank place.
        XCTAssertTrue(pending.fieldCard === fields)
        XCTAssertEqual(pending.lines.first, "Order delivery")
        XCTAssertEqual(pending.lines, fields.lines)
        XCTAssertEqual(pending.lines.count, 5)
        XCTAssertTrue(pending.showsGoogleMark)
        XCTAssertNil(pending.mark)
        XCTAssertFalse(fields.isReady)
        XCTAssertFalse(pending.canConfirm, "a blank required value blocks Confirm")
        XCTAssertTrue(fields.choosePlace("address", library))
        XCTAssertTrue(fields.isReady)
        XCTAssertTrue(pending.canConfirm, "the card follows the model, not a copy")

        // Confirm: the model is frozen before the closure runs, and the closure runs once.
        XCTAssertFalse(fields.isFrozen)
        let outcome = await pending.resolve(.confirm)
        XCTAssertEqual(outcome?.status, "applied")
        XCTAssertEqual(run.count, 1)
        XCTAssertEqual(run.frozenWhenRun, true, "Confirm freezes the model before the closure runs")
        XCTAssertEqual(run.changeAppliedInside, false, "a change made while the closure runs changes nothing")
        XCTAssertEqual(fields.values.option("card_id"), "debit")
        XCTAssertEqual(pending.mark, .confirmed)
        XCTAssertTrue(fields.isFrozen)
        XCTAssertFalse(fields.chooseOption("card_id", "credit"), "an edit after the tap changes nothing")
        XCTAssertEqual(fields.values.option("card_id"), "debit")

        // A second resolution, of any kind, returns nil and runs nothing.
        let again = await pending.resolve(.confirm)
        XCTAssertNil(again)
        let cancelled = await pending.resolve(.cancel)
        XCTAssertNil(cancelled)
        let dismissed = await pending.resolve(.dismiss)
        XCTAssertNil(dismissed)
        XCTAssertEqual(run.count, 1)
        XCTAssertEqual(pending.mark, .confirmed)

        // Cancel and dismiss run no closure and return the declined result.
        for how in [AgentCardResolution.cancel, .dismiss] {
            let other = model()
            let ran = Run()
            let declinable = card(other, ran)
            XCTAssertEqual(declinable.lines.first, "Order delivery", "premise: this is a real field card")
            let result = await declinable.resolve(how)
            XCTAssertEqual(result?.status, "declined")
            XCTAssertEqual(result?.message, ToolText.declined)
            XCTAssertNil(result?.notice)
            XCTAssertEqual(ran.count, 0)
            XCTAssertEqual(declinable.mark, .cancelled)
            let second = await declinable.resolve(.confirm)
            XCTAssertNil(second)
            XCTAssertEqual(ran.count, 0, "a resolved card never runs its closure")
        }
    }

    // MARK: K02

    func testK02_AFieldCardDrawsItsResolvedLinesFromTheModelAndTheOlderFormsStayAsTheyWere() async throws {
        let fields = model()
        let run = Run()
        let field = card(fields, run, showsGoogleMark: false)
        XCTAssertFalse(field.showsGoogleMark)
        XCTAssertEqual(field.lines.first, "Order delivery")
        XCTAssertEqual(field.lines.last, "Pay with: Debit one")
        XCTAssertTrue(field.lines.contains("Delivery place:"), "a blank value reads as its label alone")
        XCTAssertTrue(fields.choosePlace("address", library))
        XCTAssertTrue(field.lines.contains("Delivery place: 9 Library Road"))

        // The resolved card keeps the values it was confirmed with; the chat draws them from the lines.
        let before = field.lines
        _ = await field.resolve(.confirm)
        XCTAssertEqual(field.lines, before)
        XCTAssertEqual(field.mark?.rawValue, "Confirmed")

        // The line form is untouched: no model, its own lines, Confirm always possible, one resolution.
        let ran = Run()
        let plain = AgentCard(lines: ["Add Review", "From 9:00 AM"], showsGoogleMark: false) {
            ran.count += 1
            return (AgentResolution(result: #"{"status":"applied"}"#, notice: nil), .confirmed)
        }
        XCTAssertNil(plain.fieldCard)
        XCTAssertEqual(plain.lines, ["Add Review", "From 9:00 AM"])
        XCTAssertTrue(plain.canConfirm)
        XCTAssertEqual(plain.actions, ["Confirm", "Cancel"])
        let applied = await plain.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        let twice = await plain.resolve(.confirm)
        XCTAssertNil(twice)
        XCTAssertEqual(ran.count, 1)
        XCTAssertEqual(plain.mark, .confirmed)

        // In a session, once `order_delivery` returns the card: it waits as the pending card, Confirm resolves it and the model
        // is asked again.
        let rig = DeliveryToolRig(injectBudget: true)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        rig.seedDinner()
        let order = try JSONSerialization.data(withJSONObject: DeliveryToolRig.arguments(), options: [.sortedKeys])
        let fake = FakeTransport([.turn(Turns.turn(Turns.call("get_delivery_options", "{}", id: "c1"))),
                                  .turn(Turns.turn(Turns.call("order_delivery", String(decoding: order, as: UTF8.self), id: "c2"))),
                                  .turn(Turns.text("Ordered."))])
        let session = AgentSession(toolbox: rig.tools, transport: fake, connections: rig.log)
        XCTAssertTrue(session.canSend)
        session.send("Order two ramen and a gyoza")
        await session.settle()
        XCTAssertEqual(fake.requests.count, 2, "the card waits: the model is not asked a third time")
        let pending = try XCTUnwrap(session.pendingCard, "order_delivery returned a card")
        XCTAssertNotNil(pending.fieldCard, "the card carries the field-card model")
        XCTAssertEqual(pending.lines.first, "Order delivery")
        XCTAssertEqual(session.entries.filter { entry in
            if case .card = entry.kind { return true }
            return false
        }.count, 1, "one card entry")
        XCTAssertFalse(session.canSend)
        #if DEBUG
        XCTAssertTrue(session.transcript().components(separatedBy: "\n").contains("CARD Order delivery Pending"))
        #endif
        XCTAssertEqual(rig.partner.requests.count, 1, "only the options request while the card waits")
        await session.confirmCard()
        await session.settle()
        XCTAssertNil(session.pendingCard)
        XCTAssertEqual(rig.partner.requests.count, 2, "Confirm sent the one order request")
        XCTAssertEqual(fake.requests.count, 3, "the next model request was made")
        XCTAssertEqual(session.assistantTexts, ["Ordered."])
        XCTAssertTrue(session.canSend)
        #if DEBUG
        XCTAssertTrue(session.transcript().components(separatedBy: "\n").contains("CARD Order delivery Confirmed"))
        #endif
    }

    // MARK: K03

    /// The queries a test's search closure was called with.
    private final class Queries {
        var list: [String] = []
    }

    private func isSearching(_ model: AgentFieldCard) -> Bool {
        if case .searching? = model.field("address")?.lookup { return true }
        return false
    }

    func testK03_CancelAndDismissFreezeTheModelSoAnArmedSearchNeverFires() async throws {
        let wait: UInt64 = 700_000_000

        // Control: an armed search that nobody cancels does fire after the debounce, so a silent search below proves the cancel.
        let controlQueries = Queries()
        let control = AgentFieldCard(header: "Order delivery", rows: [.field(addressSpec, value: nil, source: .blank)], favorites: [],
                                     search: { controlQueries.list.append($0); return [] }, now: { [now] in now })
        control.search("address", "tart")
        XCTAssertTrue(isSearching(control), "premise: the search is armed")
        XCTAssertEqual(controlQueries.list, [], "premise: nothing is searched before the debounce")
        try? await Task.sleep(nanoseconds: wait)
        XCTAssertEqual(controlQueries.list, ["tart"], "control: an armed search that is not cancelled fires")

        for how in [AgentCardResolution.cancel, .dismiss] {
            let queries = Queries()
            let fields = AgentFieldCard(header: "Order delivery", rows: [.field(addressSpec, value: nil, source: .blank)], favorites: [],
                                        search: { queries.list.append($0); return [] }, now: { [now] in now })
            let pending = card(fields, Run())
            fields.search("address", "tart")
            XCTAssertTrue(isSearching(fields), "premise: the search is armed before the card is resolved")
            XCTAssertFalse(fields.isFrozen)
            let result = await pending.resolve(how)
            XCTAssertEqual(result?.status, "declined")
            XCTAssertTrue(fields.isFrozen, "\(how) freezes the model")
            try? await Task.sleep(nanoseconds: wait)
            XCTAssertEqual(queries.list, [], "\(how): the armed search never fires")
            fields.search("address", "later")
            try? await Task.sleep(nanoseconds: wait)
            XCTAssertEqual(queries.list, [], "\(how): no search starts after the freeze")
        }
    }

    // MARK: K04, K05 the lines of the user that the quote check reads (SPEC-BOOKCARD-001 REQ-011, REQ-013)

    private func chatUserLines(_ session: AgentSession) -> [String] {
        session.entries.compactMap { if case .user(let text) = $0.kind { return text } else { return nil } }
    }

    private func quoted(_ rig: PartnerRig, _ value: String, quote: String) throws -> AgentFieldCard {
        let text = PartnerRig.fieldsText([["key": "restaurant", "value": value, "quote": quote]])
        let card = try XCTUnwrap(rig.call("request_partner", ["partner": "booking", "fields": text]).card)
        return try XCTUnwrap(card.fieldCard)
    }

    func testK04_TheUserLinesTheToolboxReadsAreTheLinesTheChatShowsAsTheUsersAndAQuoteFromAnEarlierTurnIsAccepted() async throws {
        let rig = PartnerRig()
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let fake = FakeTransport([.turn(Turns.text("What time would you like?")), .turn(Turns.text("Noted."))])
        let session = AgentSession(toolbox: rig.tools, transport: fake, connections: rig.log)
        XCTAssertEqual(rig.tools.userLines(), [], "no message yet")
        session.send("Book Pasta Palace for 2, name Sam")
        await session.settle()
        session.send("The long text the model gets for a share", shown: "Shared a photo")
        await session.settle()
        XCTAssertEqual(rig.tools.userLines(), ["Book Pasta Palace for 2, name Sam", "Shared a photo"], "a share line shows its short form")
        XCTAssertEqual(rig.tools.userLines(), chatUserLines(session))
        let all = rig.tools.userLines().joined(separator: "\n")
        XCTAssertFalse(all.contains("What time would you like?"), "the model's text is not the user's")
        XCTAssertFalse(all.contains("The long text"), "the text only the model gets is not the user's")

        // A quote from the first turn is accepted in the second; the model's own words and the model-only text are not.
        await rig.listed()
        let earlier = try quoted(rig, "Pasta Palace", quote: "Pasta Palace")
        XCTAssertEqual(earlier.values.text("restaurant"), "Pasta Palace")
        XCTAssertEqual(earlier.source(of: "restaurant"), .stated)
        let model = try quoted(rig, "What time", quote: "What time would you like?")
        XCTAssertNil(model.values.entry("restaurant")?.value)
        let hidden = try quoted(rig, "long text", quote: "The long text the model gets")
        XCTAssertNil(hidden.values.entry("restaurant")?.value)
    }

    func testK05_ANewChatClearsTheUserLinesAndTheHeldPartnersAndThreeModelRequestsMakeTheWholeCall() async throws {
        let rig = PartnerRig()
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let first = Turns.call("get_partners", "{}", id: "c0")
        let second = Turns.call("request_partner", PlaceTurns.arguments(PartnerRig.arguments()), id: "c1")
        let fake = FakeTransport([.turn(Turns.turn(first)), .turn(Turns.turn(second)), .turn(Turns.text("Booked, and it is simulated."))])
        let session = AgentSession(toolbox: rig.tools, transport: fake, connections: rig.log)
        session.send(PartnerRig.parts(.init()).line)
        await session.settle()
        XCTAssertNotNil(session.pendingCard)
        await session.confirmCard()
        await session.settle()
        XCTAssertEqual(fake.requests.count, 3, "get_partners, request_partner and the final reply")
        XCTAssertEqual(rig.partner.bodies(op: "submit").count, 1)
        XCTAssertEqual(rig.store.activities.count, 1)
        XCTAssertFalse(rig.tools.userLines().isEmpty, "premise: the chat holds the user's line")

        await session.newChat()
        XCTAssertEqual(rig.tools.userLines(), [], "a new chat forgets the user's lines")
        XCTAssertEqual(rig.call("request_partner", PartnerRig.arguments()).message,
                       "Call get_partners first, then call request_partner again with a partner id from its answer.")
        // The partners are fetched again, and a quote from before the new chat is refused.
        await rig.listed()
        let card = try XCTUnwrap(rig.call("request_partner", PartnerRig.arguments()).card)
        let fields = try XCTUnwrap(card.fieldCard)
        for key in ["restaurant", "party_size", "start", "name"] {
            XCTAssertNil(fields.values.entry(key)?.value, key)
            XCTAssertEqual(fields.source(of: key), .blank, key)
        }
    }
}
