import XCTest
@testable import besir

/// SPEC-DELIVERY-001 AC-DELIVERY-008 (the editors of the confirmation card, at view-model level; no UI automation): what a
/// typed value becomes, when a card can be confirmed, what the lines show, and the freeze at Confirm.
@MainActor
final class AgentCardEditTests: XCTestCase {
    private func makeRig() -> DeliveryToolRig {
        let rig = DeliveryToolRig()
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    private let suggestionMark = " (suggested from your schedule)"

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TestClock.zone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    // MARK: V01 the delivery text

    func testV01_TheDeliveryTextStartsWithTheSuggestionIsCleanedAsTypedAndNeverTrimmed() async throws {
        let made = await makeRig().readyCard()
        let card = try XCTUnwrap(made)
        let text = try XCTUnwrap(card.editors.delivery)
        XCTAssertEqual(text.text, "9 Library Road")
        XCTAssertTrue(text.isSuggestion)
        XCTAssertEqual(card.lines[5], "To 9 Library Road" + suggestionMark)
        XCTAssertTrue(card.canConfirm)

        // The typing sequence keeps every step as typed.
        for step in ["1", "12", "12 ", "12 E", "12 Example Street"] {
            text.text = step
            XCTAssertEqual(text.text, step)
            XCTAssertEqual(card.lines[5], "To \(step)", "the lines show the edited text, without the mark")
            XCTAssertFalse(text.isSuggestion)
        }
        // Hidden characters are removed as they are typed; a space is kept.
        text.text = "12\u{0007} Exa\u{200B}mple\u{2028}\u{2029} Street "
        XCTAssertEqual(text.text, "12 Example Street ")
        // The text is cut at 120 scalars.
        text.text = String(repeating: "x", count: 130)
        XCTAssertEqual(text.text.unicodeScalars.count, 120)
        XCTAssertTrue(card.canConfirm)
        // A text of only spaces is kept as typed and makes the card unconfirmable.
        text.text = "   "
        XCTAssertEqual(text.text, "   ")
        XCTAssertFalse(card.canConfirm)
        XCTAssertTrue(text.isBlank)
        text.text = "\u{0007}"
        XCTAssertEqual(text.text, "")
        XCTAssertFalse(card.canConfirm)
        // The mark goes with a changed value and comes back when the value is made equal to the suggestion again.
        text.text = "9 Library Road"
        XCTAssertTrue(text.isSuggestion)
        XCTAssertEqual(card.lines[5], "To 9 Library Road" + suggestionMark)
        XCTAssertTrue(card.canConfirm)
        text.text = "9 Library Road "
        XCTAssertFalse(text.isSuggestion, "a trailing space is a change")
        XCTAssertEqual(card.lines[5], "To 9 Library Road ")
    }

    // MARK: V02 the meal entry

    func testV02_TheMealSwitchTitleAndTimeKeepTheirRulesAndTheMarkFollowsTheSuggestion() async throws {
        let made = await makeRig().readyCard()
        let card = try XCTUnwrap(made)
        let on = try XCTUnwrap(card.editors.mealOn)
        let title = try XCTUnwrap(card.editors.mealTitle)
        let start = try XCTUnwrap(card.editors.mealStart)
        let arrival = TestClock.date(DeliveryToolFixture.arrival)
        let time = timeText(arrival)
        let suggested = "Add to schedule: Dinner (Simulated) at \(time) (suggested)"
        XCTAssertEqual(card.lines.count, 10)
        XCTAssertEqual(card.lines[8], suggested)

        // The switch removes the schedule line and restores it.
        on.isOn = false
        XCTAssertEqual(card.lines.count, 9)
        XCTAssertFalse(card.lines.contains { $0.hasPrefix("Add to schedule") })
        XCTAssertEqual(card.lines.last, "Example Delivery - Simulated")
        on.isOn = true
        XCTAssertEqual(card.lines[8], suggested)

        // The title is cleaned and cut at 40 scalars as it is typed, and never trimmed.
        title.text = "Family "
        XCTAssertEqual(title.text, "Family ")
        XCTAssertEqual(card.lines[8], "Add to schedule: Family  (Simulated) at \(time)", "no mark on a changed title")
        title.text = "Fam\u{200B}ily\u{0007}"
        XCTAssertEqual(title.text, "Family")
        title.text = String(repeating: "t", count: 50)
        XCTAssertEqual(title.text.unicodeScalars.count, 40)
        // A blank title makes the card unconfirmable while the switch is on, not while it is off.
        title.text = "  "
        XCTAssertEqual(title.text, "  ")
        XCTAssertFalse(card.canConfirm)
        on.isOn = false
        XCTAssertTrue(card.canConfirm)
        on.isOn = true
        XCTAssertFalse(card.canConfirm)
        title.text = "Dinner"
        XCTAssertTrue(card.canConfirm)
        XCTAssertEqual(card.lines[8], suggested, "the mark returns when the title is made equal again")

        // The time keeps the arrival's date and zeroes the seconds.
        start.start = TestClock.date("2026-11-05T20:15:42")
        XCTAssertEqual(TestClock.local(start.start), "2026-10-28T20:15")
        XCTAssertEqual(start.start, TestClock.date("2026-10-28T20:15"))
        XCTAssertEqual(card.lines[8], "Add to schedule: Dinner (Simulated) at \(timeText(start.start))", "no mark on a changed time")
        start.start = arrival
        XCTAssertEqual(card.lines[8], suggested)

        // The mark needs the switch, the title and the time to equal the suggestion all at once.
        title.text = "Supper"
        start.start = TestClock.date("2026-10-28T20:00")
        title.text = "Dinner"
        XCTAssertFalse(card.lines[8].hasSuffix("(suggested)"))
        start.start = arrival
        XCTAssertTrue(card.lines[8].hasSuffix("(suggested)"))
    }

    // MARK: V03 the closure reads the editors

    func testV03_TheConfirmClosureKeepsItsTypeReadsTheCurrentEditorsAndRejectsABlankOne() async throws {
        // The type is unchanged: a closure that takes no argument and gives a resolution and a mark builds a card.
        let plain = AgentCard(lines: ["x"]) { (AgentResolution(result: "{}", notice: nil), .confirmed) }
        XCTAssertEqual(plain.lines, ["x"])

        // A blank delivery text typed after the card was built is seen by the closure.
        let rig = makeRig()
        let made = await rig.readyCard()
        let blank = try XCTUnwrap(made)
        let before = rig.snapshot
        let sent = rig.partner.requests.count
        try XCTUnwrap(blank.editors.delivery).text = "   "
        XCTAssertFalse(blank.canConfirm)
        let resolved = await blank.resolve(.confirm)
        let rejected = try XCTUnwrap(resolved)
        XCTAssertEqual(rejected.status, "rejected")
        XCTAssertEqual(rejected.message, AgentDelivery.editRejectedMessage)
        XCTAssertNil(rejected.notice)
        XCTAssertEqual(blank.mark, .notApplied)
        XCTAssertEqual(rig.partner.requests.count, sent, "nothing is sent")
        XCTAssertEqual(rig.snapshot, before)

        // A blank title while the switch is on is rejected the same way.
        let madeTitled = await makeRig().readyCard()
        let titled = try XCTUnwrap(madeTitled)
        try XCTUnwrap(titled.editors.mealTitle).text = " "
        let titledResolution = await titled.resolve(.confirm)
        XCTAssertEqual(titledResolution?.message, AgentDelivery.editRejectedMessage)
        XCTAssertEqual(titled.mark, .notApplied)

        // A blank title with the switch off is no fault of the card, and an edited text is not rejected.
        let madeOff = await makeRig().readyCard()
        let off = try XCTUnwrap(madeOff)
        try XCTUnwrap(off.editors.mealTitle).text = ""
        try XCTUnwrap(off.editors.mealOn).isOn = false
        try XCTUnwrap(off.editors.delivery).text = "12 Example Street"
        XCTAssertTrue(off.canConfirm)
        let offResolution = await off.resolve(.confirm)
        XCTAssertNotEqual(offResolution?.status, "rejected")
        XCTAssertNotEqual(offResolution?.message, AgentDelivery.editRejectedMessage)
    }

    // MARK: V04 the freeze

    /// A card whose closure takes its snapshot, then waits until the test lets it go.
    private final class Hold {
        var release: CheckedContinuation<Void, Never>?
        var snapshot: AgentCardEditors.Values?
        var ran = false
    }

    private func stubEditors() -> AgentCardEditors {
        let arrival = TestClock.date("2026-10-28T19:40")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TestClock.zone
        return AgentCardEditors(delivery: AgentCardText(text: "9 Library Road", limit: 120, suggestion: "9 Library Road"),
                                mealOn: AgentCardSwitch(isOn: true),
                                mealTitle: AgentCardText(text: "Dinner", limit: 40, suggestion: "Dinner"),
                                mealStart: AgentCardTime(start: arrival, arrival: arrival, calendar: calendar))
    }

    private func stubCard(_ editors: AgentCardEditors, _ hold: Hold) -> AgentCard {
        AgentCard(editors: editors, rows: {
            [.text("To \(editors.delivery?.text ?? "")"), .text("\(editors.mealOn?.isOn == true ? "on" : "off") \(editors.mealTitle?.text ?? "")")]
        }, onConfirm: {
            hold.ran = true
            hold.snapshot = editors.values
            await withCheckedContinuation { hold.release = $0 }
            return (AgentResolution(result: "{}", notice: nil), .confirmed)
        })
    }

    func testV04_ConfirmFreezesTheEditorsBeforeItAwaitsTheClosureAndCancelRunsNoClosure() async throws {
        let editors = stubEditors()
        let hold = Hold()
        let card = stubCard(editors, hold)
        XCTAssertFalse(editors.isFrozen)
        let task = Task { await card.resolve(.confirm) }
        while hold.release == nil { await Task.yield() }
        XCTAssertTrue(editors.isFrozen, "frozen before the closure was awaited")
        let taken = try XCTUnwrap(hold.snapshot)
        XCTAssertEqual(taken.deliveryText, "9 Library Road")

        // Edits made while the closure is suspended change nothing.
        let delivery = try XCTUnwrap(editors.delivery)
        let title = try XCTUnwrap(editors.mealTitle)
        let on = try XCTUnwrap(editors.mealOn)
        let start = try XCTUnwrap(editors.mealStart)
        delivery.text = "12 Example Street"
        title.text = "Family dinner"
        on.isOn = false
        start.start = TestClock.date("2026-10-28T21:15")
        XCTAssertEqual(editors.values, taken)
        XCTAssertEqual(delivery.text, "9 Library Road")
        XCTAssertEqual(title.text, "Dinner")
        XCTAssertTrue(on.isOn)
        XCTAssertEqual(start.start, TestClock.date("2026-10-28T19:40"))
        hold.release?.resume()
        let resolved = await task.value
        XCTAssertNotNil(resolved)
        XCTAssertEqual(card.mark, .confirmed)
        XCTAssertEqual(card.lines, ["To 9 Library Road", "on Dinner"], "the lines show the confirmed values")
        let second = await card.resolve(.confirm)
        XCTAssertNil(second, "a second resolution does nothing")
        XCTAssertEqual(editors.values, taken)

        // Cancel and dismiss ignore the edits and run no closure.
        for how in [AgentCardResolution.cancel, .dismiss] {
            let other = stubEditors()
            let otherHold = Hold()
            let otherCard = stubCard(other, otherHold)
            try XCTUnwrap(other.delivery).text = "Somewhere else"
            let resolution = await otherCard.resolve(how)
            XCTAssertFalse(otherHold.ran)
            XCTAssertEqual(otherCard.mark, .cancelled)
            XCTAssertEqual(resolution?.result, AgentToolbox.declinedResult)
            XCTAssertEqual(otherCard.lines.first, "To Somewhere else", "a cancelled card keeps what was typed")
            let again = await otherCard.resolve(.confirm)
            XCTAssertNil(again)
            XCTAssertFalse(otherHold.ran)
        }
    }

    // MARK: V05 a card without editors

    func testV05_ACardWithoutEditorsBehavesAsBefore() async throws {
        var confirmed = 0
        let card = AgentCard(lines: ["Add event", "Team sync"], showsGoogleMark: true) {
            confirmed += 1
            return (AgentResolution(result: "{\"status\":\"applied\"}", notice: "n"), .confirmed)
        }
        XCTAssertEqual(card.lines, ["Add event", "Team sync"])
        XCTAssertEqual(card.rows, [.text("Add event"), .text("Team sync")])
        XCTAssertTrue(card.editors.isEmpty)
        XCTAssertTrue(card.canConfirm)
        XCTAssertEqual(card.actions, ["Confirm", "Cancel"])
        XCTAssertTrue(card.showsGoogleMark)
        XCTAssertNil(card.mark)
        let first = await card.resolve(.confirm)
        XCTAssertEqual(first?.notice, "n")
        XCTAssertEqual(card.mark, .confirmed)
        XCTAssertEqual(confirmed, 1)
        let second = await card.resolve(.confirm)
        XCTAssertNil(second)
        let third = await card.resolve(.cancel)
        XCTAssertNil(third)
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(card.mark, .confirmed)

        let cancelled = AgentCard(lines: ["Delete event"]) { (AgentResolution(result: "{}", notice: nil), .confirmed) }
        XCTAssertFalse(cancelled.showsGoogleMark)
        let cancel = await cancelled.resolve(.cancel)
        XCTAssertEqual(cancelled.mark, .cancelled)
        XCTAssertEqual(cancel?.result, AgentToolbox.declinedResult)
        XCTAssertEqual(cancelled.lines, ["Delete event"])
    }
}
