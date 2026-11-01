import XCTest
@testable import besir

/// SPEC-VOICE-001 AC-VOICE-011 and 012: the chat's error line and the one path a voice text takes into the chat.
@MainActor
final class VoiceChatTests: XCTestCase {

    func testVOICE_T12_showErrorAppendsOneLineAndTouchesNothingElse() async {
        let rig = SessionRig([.turn(Turns.text("ok"))])
        let historyBefore = rig.session.history.count
        let canSendBefore = rig.session.canSend

        rig.session.showError("x")

        XCTAssertEqual(rig.session.errorLines, ["x"])
        XCTAssertEqual(rig.session.chatLines, ["ERROR x"])
        XCTAssertEqual(rig.session.history.count, historyBefore)
        XCTAssertEqual(rig.session.canSend, canSendBefore)
        XCTAssertEqual(rig.fake.requests.count, 0)

        await rig.say("hi")
        XCTAssertEqual(rig.fake.requests.count, 1)
    }

    func testVOICE_T14_aVoiceTextTakesTheSamePathAsATypedMessage() async {
        let spoken = "move dinner 30 minutes later"
        let rig = SessionRig([.turn(Turns.text("Moved."))])
        let recorder = FakeVoiceRecorder()
        let client = FakeVoiceClient()
        client.result = .success("  \(spoken) ")
        let input = VoiceInput(recorder: recorder, client: client)
        let session = rig.session
        let deliver: @MainActor (String) -> Void = { text in
            switch VoiceDelivery.route(text: text, canSend: session.canSend) {
            case .send(let message): session.send(message)
            case .draft: break
            }
        }

        await input.tap(deliver: deliver, fail: session.showError)
        await input.tap(deliver: deliver, fail: session.showError)
        await session.settle()

        XCTAssertEqual(rig.fake.request(1).last, .user(spoken))
        XCTAssertEqual(session.userTexts, [spoken])
        XCTAssertEqual(session.chatLines.first, "USER \(spoken)")

        let typed = SessionRig([.turn(Turns.text("Moved."))])
        await typed.say(spoken)
        XCTAssertEqual(rig.fake.request(1), typed.fake.request(1), "the request is the one a typed message makes")
    }
}
