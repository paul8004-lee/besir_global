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
}
