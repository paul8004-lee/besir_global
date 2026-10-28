import XCTest
@testable import besir

/// SPEC-SHARE-001 AC-SHARE-010: the agent gets only the composed text, and a share ends in the existing confirmation card.
@MainActor
final class ShareAgentHandoffTests: XCTestCase {
    private let fields = VisionFields(title: "JAZZ NIGHT", time: "2026-11-07T19:00", place: "Blue Note SF", confidence: 0.9)

    private func composedText() throws -> String {
        guard case .message(let text) = SharedMessage.compose(fields: fields, text: nil) else {
            throw XCTSkip("the message did not compose")
        }
        return text
    }

    func testAC_SHARE_010_theHistoryEndsWithTheComposedTextAndHoldsNoImage() async throws {
        let base64 = Data((0..<3_000).map { UInt8($0 % 251) }).base64EncodedString()
        let text = try composedText()
        let rig = SessionRig([.turn(Turns.text("Noted."))])
        await rig.say(text)

        let history = rig.fake.request(1)
        XCTAssertEqual(history.last, .user(text))
        let dump = history.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertTrue(dump.contains("JAZZ NIGHT"), "positive control: the scan reads the values that were sent")
        XCTAssertFalse(dump.contains(String(base64.prefix(60))))
        XCTAssertFalse(dump.contains("data:image"))
    }

    func testAC_SHARE_010_aCreateTurnMakesTheAddEventCardAndConfirmPutsItInTheStore() async throws {
        let rig = SessionRig([.turn(Turns.create(id: "c1")), .turn(Turns.text("Added."))])
        await rig.say(try composedText())

        let card = try XCTUnwrap(rig.session.pendingCard)
        XCTAssertEqual(card.lines.first, "Add event")
        XCTAssertTrue(rig.store.activities.isEmpty, "nothing is written before Confirm")

        await rig.session.confirmCard()
        await rig.session.settle()
        XCTAssertEqual(rig.store.activities.count, 1)
    }

    // MARK: - SPEC-SHAREBUBBLE-001: the chat draws the shown line, the model gets the composed text

    func testAC_BUBBLE_003_theChatDrawsTheShownLineAndTheModelGetsTheComposedText() async throws {
        let text = try composedText()
        let line = SharedMessage.shownLine(fields: fields)
        let rig = SessionRig([.turn(Turns.text("Noted."))])
        rig.session.send(text, shown: line)
        await rig.session.settle()

        XCTAssertEqual(rig.session.userTexts, [line])
        XCTAssertEqual(rig.session.history.first, .user(text))
        XCTAssertEqual(rig.fake.request(1).last, .user(text))
        let dump = rig.fake.request(1).map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertTrue(dump.contains("JAZZ NIGHT"), "positive control: the scan reads what the model got")
        XCTAssertFalse(dump.contains("Read with 90% confidence"), "the shown line never reaches the request")
    }

    func testAC_BUBBLE_003_aMissingOrBlankShownLineLeavesTheBubbleAsTheText() async {
        for shown in [nil, "", "  \n "] as [String?] {
            let rig = SessionRig([.turn(Turns.text("a"))])
            rig.session.send("  hello  ", shown: shown)
            await rig.session.settle()
            XCTAssertEqual(rig.session.userTexts, ["hello"], "shown \(String(describing: shown))")
            XCTAssertEqual(rig.session.history.first, .user("hello"))
        }

        let spaced = SessionRig([.turn(Turns.text("a"))])
        spaced.session.send("hello", shown: "  the line \n")
        await spaced.session.settle()
        XCTAssertEqual(spaced.session.userTexts, ["the line"])
        XCTAssertEqual(spaced.session.history.first, .user("hello"))

        let blankText = SessionRig()
        blankText.session.send("   ", shown: "The line")
        await blankText.session.settle()
        XCTAssertTrue(blankText.session.entries.isEmpty, "a blank text sends nothing, whatever the shown line")
        XCTAssertTrue(blankText.session.history.isEmpty)
        XCTAssertTrue(blankText.fake.requests.isEmpty)
    }

    func testAC_BUBBLE_002_theRequestBodyIsByteIdenticalWithOrWithoutTheShownLine() async throws {
        let text = try composedText()
        let withLine = SessionRig([.turn(Turns.text("Noted."))])
        withLine.session.send(text, shown: SharedMessage.shownLine(fields: fields))
        await withLine.session.settle()
        let plain = SessionRig([.turn(Turns.text("Noted."))])
        await plain.say(text)

        let instructions = AgentWire.instructions(now: TestClock.now, timeZone: TestClock.zone)
        let bodyWithLine = AgentWire.requestBody(history: withLine.session.history, instructions: instructions)
        let bodyPlain = AgentWire.requestBody(history: plain.session.history, instructions: instructions)
        XCTAssertFalse(bodyPlain.isEmpty)
        XCTAssertEqual(bodyWithLine, bodyPlain)
    }

    func testAC_BUBBLE_003_aShareStillEndsInTheAddEventCardWithOneUserRowOnScreen() async throws {
        let line = SharedMessage.shownLine(fields: fields)
        let rig = SessionRig([.turn(Turns.create(id: "c1")), .turn(Turns.text("Added."))])
        rig.session.send(try composedText(), shown: line)
        await rig.session.settle()

        XCTAssertEqual(rig.session.chatLines.filter { $0.hasPrefix("USER") }, ["USER \(line)"])
        let card = try XCTUnwrap(rig.session.pendingCard)
        XCTAssertEqual(card.lines.first, "Add event")
        XCTAssertTrue(rig.store.activities.isEmpty)

        await rig.session.confirmCard()
        await rig.session.settle()
        XCTAssertEqual(rig.store.activities.count, 1)
    }
}
