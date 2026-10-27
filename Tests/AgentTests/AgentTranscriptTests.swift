import XCTest
@testable import besir

/// AC-LOOP-004: the content of the DEBUG transcript (spec.md section 3.7).
@MainActor
final class AgentTranscriptTests: XCTestCase {

    private func lines(_ session: AgentSession) -> [String] {
        session.transcript().components(separatedBy: "\n")
    }

    func testLP003_TranscriptHasOneLinePerToolCallWithRawArguments() async {
        // A call carrying an undeclared key: the transcript shows the arguments exactly as received.
        let listArguments = #"{"from":"2026-10-28T00:00","to":"2026-10-29T00:00","extra":"xyz"}"#
        let rig = SessionRig([
            .turn(Turns.turn(Turns.message("Looking."), Turns.call("list_activities", listArguments, id: "c1"))),
            .turn(Turns.text("You have nothing.")),
            .turn(Turns.create(id: "c2")),
            .turn(Turns.text("Added.")),
        ])
        await rig.say("What is on tomorrow?")
        await rig.say("Add a meeting.")
        XCTAssertNotNil(rig.session.pendingCard)

        // While the card waits, it is listed as pending.
        XCTAssertEqual(lines(rig.session).last, "CARD Add event Pending")

        await rig.session.confirmCard()
        await rig.session.settle()

        let expected = [
            "USER What is on tomorrow?",
            "ASSISTANT Looking.",
            "TOOL list_activities \(listArguments)",
            "RESULT ok",
            "ASSISTANT You have nothing.",
            "USER Add a meeting.",
            "TOOL create_activity \(Turns.createArguments)",
            "CARD Add event Confirmed",
            "RESULT applied",
            "ASSISTANT Added.",
        ]
        XCTAssertEqual(lines(rig.session), expected)
        // One TOOL line per call.
        XCTAssertEqual(lines(rig.session).filter { $0.hasPrefix("TOOL ") }.count, 2)

        // Notice and error lines, and a dismissed card with its declined result after the call.
        let rest = SessionRig()
        let seeded = rest.tools.seed("Team sync", "2026-10-28T15:00", "2026-10-28T16:00")
        rest.fake.enqueue(.turn(Turns.delete(seeded.id, id: "d1")), .fail(AgentTransportError.offline))
        await rest.say("Delete Team sync.")
        rest.store.activities.removeAll()
        await rest.session.confirmCard()
        await rest.session.settle()
        let again = rest.tools.seed("Team sync", "2026-10-28T15:00", "2026-10-28T16:00")
        rest.fake.enqueue(.turn(Turns.delete(again.id, id: "d2")))
        await rest.say("Again.")
        XCTAssertNotNil(rest.session.pendingCard)
        await rest.session.sheetDismissed()
        let restLines = lines(rest.session)
        XCTAssertTrue(restLines.contains("NOTICE \(ToolText.notice)"))
        XCTAssertTrue(restLines.contains("ERROR Couldn't reach the assistant. Check your connection and try again."))
        XCTAssertTrue(restLines.contains("CARD Delete event Not applied"))
        XCTAssertTrue(restLines.contains("CARD Delete event Cancelled"))
        XCTAssertEqual(restLines.last, "RESULT declined")
        let tool = restLines.firstIndex { $0.hasPrefix("TOOL delete_activity") }
        let declined = restLines.lastIndex(of: "RESULT declined")
        XCTAssertNotNil(tool)
        XCTAssertNotNil(declined)
    }

    func testLP003_TranscriptNeverContainsURLOrToken() async {
        // The configuration holds a sentinel host and token, and the request builder puts the host in its URL.
        let config = AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(FakeTransport.host)", appToken: FakeTransport.token)
        let request = config.proxyPOSTRequest("/ai", body: Data("{}".utf8))
        XCTAssertTrue(request?.url?.absoluteString.contains(FakeTransport.host) == true)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-besir-token"), FakeTransport.token)

        // A conversation with a reply, a tool call and an error whose body holds both sentinels.
        let body = Data("\(FakeTransport.host) \(FakeTransport.token)".utf8)
        let rig = SessionRig([
            .turn(Turns.list(id: "c1")),
            .turn(Turns.text("Nothing today.")),
            .fail(AgentTransportError.http(status: 500, body: body)),
            .fail(AgentTransportError.http(status: 401, body: body)),
        ])
        await rig.say("What is on?")
        await rig.say("Again")
        await rig.say("Once more")

        let transcript = rig.session.transcript()
        XCTAssertTrue(transcript.contains("USER What is on?"))
        XCTAssertTrue(transcript.contains("ERROR The assistant returned an unexpected response (HTTP 500)."))
        XCTAssertTrue(transcript.contains("ERROR The assistant returned an unexpected response (HTTP 401)."))
        for needle in [FakeTransport.host, FakeTransport.token, "https://", "x-besir-token"] {
            XCTAssertFalse(transcript.contains(needle), needle)
        }
    }
}
