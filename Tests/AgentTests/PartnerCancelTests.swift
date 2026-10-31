import XCTest
@testable import besir

/// SPEC-LATESWITCH-001 (card t72), REQ-LATESWITCH-003 and AC-LATESWITCH-002: the generic cancel call of the partner client. It posts
/// to the record's route followed by `/cancel` with `op` and `request_id` only, accepts only the exact `cancelled` or `declined`
/// answer of the partner it names, and draws the exchange as packets that hold fixed words and the partner's name only. No test
/// touches the network; every log is built with a temporary file.
@MainActor
final class PartnerCancelTests: XCTestCase {
    private let token = "cancel-token-0001"
    private let host = "cancel-host.invalid"
    private let flow = UUID()
    private let requestID = "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6b"
    private let tables = (name: "Example Tables", route: "/booking")
    private var config: AppConfig { AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: token) }

    // MARK: Helpers

    private func makeLog() -> (log: ConnectionLog, file: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(ConnectionLog.fileName)
        return (ConnectionLog(fileURL: file, secrets: { [self] in [token, host] }), file)
    }

    private func client(_ send: @escaping PartnerClient.Send, log: ConnectionLog? = nil, config: AppConfig? = nil) -> PartnerClient {
        PartnerClient(config: config ?? self.config, send: send, connections: log ?? makeLog().log)
    }

    private func cancel(_ recorder: BookingSendRecorder, partner: (name: String, route: String)? = nil, log: ConnectionLog? = nil,
                        config: AppConfig? = nil) async -> Result<PartnerCancelAnswer, PartnerFailure> {
        await client(recorder.send, log: log, config: config).cancel(requestID: requestID, partner: partner ?? tables, flow: flow)
    }

    private func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The `cancelled` answer the sample partner gives, or its `declined` answer; `mutate` bends it.
    private func answer(declined: Bool = false, reason: String = "no_booking", name: String = "Example Tables",
                        _ mutate: (inout [String: Any]) -> Void = { _ in }) -> String {
        var fields: [String: Any] = ["status": declined ? "declined" : "cancelled", "partner": name, "simulated": true]
        if declined { fields["reason"] = reason }
        mutate(&fields)
        return json(fields)
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func lines(_ log: ConnectionLog) -> [String] {
        log.packets.map { "\($0.from.rawValue)>\($0.to.rawValue) \($0.kind.rawValue) \($0.status.rawValue) \($0.summary)" }
    }

    private func assertOther(_ bodies: [String], partner: (name: String, route: String)? = nil, file: StaticString = #filePath,
                             line: UInt = #line) async {
        for text in bodies {
            let result = await cancel(BookingSendRecorder(body: text), partner: partner)
            XCTAssertEqual(result, .failure(.other), text, file: file, line: line)
        }
    }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    // MARK: C01-C02 the request

    func testC01_TheRequestIsAPostOfExactlyOpAndRequestIDToTheRouteWithCancelAfterItWithTheTokenAndATwentySecondTimeout() async throws {
        let recorder = BookingSendRecorder(body: answer())
        let result = await cancel(recorder)
        XCTAssertEqual(result, .success(.cancelled))
        XCTAssertEqual(recorder.requests.count, 1)
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/booking/cancel")
        // `path` drops a trailing slash, so the whole address is compared too.
        XCTAssertEqual(sent.url?.absoluteString, "https://\(host)/booking/cancel")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-besir-token"), token)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.timeoutInterval, 20)
        let fields = try body(of: sent)
        XCTAssertEqual(Set(fields.keys), ["op", "request_id"])
        XCTAssertEqual(fields["op"] as? String, "cancel")
        XCTAssertEqual(fields["request_id"] as? String, requestID)
        XCTAssertEqual(String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self), #"{"op":"cancel","request_id":"\#(requestID)"}"#)
        // Nothing of the configuration or of the entry travels in the body.
        let text = String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self).lowercased()
        for word in ["example", token, host, "latitude", "longitude", "address", "values", "reservation"] {
            XCTAssertFalse(text.contains(word), "the body holds \(word)")
        }
    }

    func testC02_NoProxyGivesNotSetUpWithoutACallOrAPacket() async {
        let (log, _) = makeLog()
        for blank in [AppConfig(), AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: ""),
                      AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: token)] {
            let recorder = BookingSendRecorder(body: answer())
            let result = await cancel(recorder, log: log, config: blank)
            XCTAssertEqual(result, .failure(.notSetUp))
            XCTAssertTrue(recorder.requests.isEmpty)
        }
        await log.flush()
        XCTAssertTrue(log.packets.isEmpty)
        // Positive counterpart: with a proxy the same call sends and answers.
        let counterpart = BookingSendRecorder(body: answer())
        let result = await cancel(counterpart, log: log)
        XCTAssertEqual(result, .success(.cancelled))
        XCTAssertEqual(counterpart.requests.count, 1)
    }

    // MARK: C03-C06 the answer

    func testC03_TheExactCancelledAnswerIsAccepted() async {
        let result = await cancel(BookingSendRecorder(body: answer()))
        XCTAssertEqual(result, .success(.cancelled))
        // The key order of the answer does not matter.
        let reordered = await cancel(BookingSendRecorder(body: #"{"simulated":true,"partner":"Example Tables","status":"cancelled"}"#))
        XCTAssertEqual(reordered, .success(.cancelled))
        // The name is the one the caller gives, not a constant of the client.
        let other = await cancel(BookingSendRecorder(body: answer(name: "Second Partner")), partner: (name: "Second Partner", route: "/second"))
        XCTAssertEqual(other, .success(.cancelled))
    }

    func testC04_TheExactDeclinedAnswerIsAcceptedAndItsReasonIsCheckedAndDropped() async {
        for reason in ["no_booking", "x", "_", "closed_for_the_day", String(repeating: "a", count: 40)] {
            let result = await cancel(BookingSendRecorder(body: answer(declined: true, reason: reason)))
            XCTAssertEqual(result, .success(.declined), reason)
            // The reason is dropped: the answer is a bare case.
            if case .success(let kept) = result { XCTAssertEqual(String(describing: kept), "declined") }
        }
    }

    func testC05_EveryDeviationOfTheAnswerIsOtherAndNeverCancelled() async {
        var bodies: [String] = []
        // Another partner, or none.
        bodies.append(answer(name: "Real Tables"))
        bodies.append(answer(name: "example tables"))
        bodies.append(answer(name: "Example Tables "))
        bodies.append(answer { $0.removeValue(forKey: "partner") })
        bodies.append(answer { $0["partner"] = 5 })
        bodies.append(answer { $0["partner"] = NSNull() })
        // `simulated` that is not the boolean true.
        for value: Any in [false, "true", 1, NSNull()] { bodies.append(answer { $0["simulated"] = value }) }
        bodies.append(answer { $0.removeValue(forKey: "simulated") })
        // An extra key on either answer, a missing key, a wrong type.
        bodies.append(answer { $0["reason"] = "no_booking" })
        bodies.append(answer { $0["reservation_code"] = "EX-AB12CD" })
        bodies.append(answer { $0["extra"] = NSNull() })
        bodies.append(answer(declined: true) { $0["extra"] = 1 })
        bodies.append(answer { $0.removeValue(forKey: "status") })
        bodies.append(answer(declined: true) { $0.removeValue(forKey: "reason") })
        // An unknown status.
        for status: Any in ["confirmed", "CANCELLED", "Cancelled", "pending", "cancelled ", "", 7, true, NSNull()] {
            bodies.append(answer { $0["status"] = status })
        }
        // A reason outside 1 to 40 characters of `a-z` and `_`.
        for reason: Any in ["", "NO_BOOKING", "no booking", "no-booking", "no_booking1", "é", String(repeating: "a", count: 41), 1, NSNull()] {
            bodies.append(answer(declined: true) { $0["reason"] = reason })
        }
        // Not an object, or an empty one.
        bodies.append(contentsOf: ["[]", "null", "\"cancelled\"", "5", "", "not json", "{}"])
        // Positive counterpart: the exact answers are accepted.
        let accepted = await cancel(BookingSendRecorder(body: answer()))
        XCTAssertEqual(accepted, .success(.cancelled))
        await assertOther(bodies)
    }

    func testC06_ThePureReaderAnswersTheSameTableWhenCalledDirectly() {
        let name = "Example Tables"
        XCTAssertEqual(PartnerCancelAnswer.answer(cancelFrom: data(answer()), name: name), .cancelled)
        XCTAssertEqual(PartnerCancelAnswer.answer(cancelFrom: data(answer(declined: true)), name: name), .declined)
        XCTAssertEqual(PartnerCancelAnswer.answer(cancelFrom: data(answer(name: "Second Partner")), name: "Second Partner"), .cancelled)
        XCTAssertNil(PartnerCancelAnswer.answer(cancelFrom: data(answer()), name: "Second Partner"))
        XCTAssertNil(PartnerCancelAnswer.answer(cancelFrom: data(answer()), name: ""))
        XCTAssertNil(PartnerCancelAnswer.answer(cancelFrom: data(answer { $0["reason"] = "no_booking" }), name: name))
        XCTAssertNil(PartnerCancelAnswer.answer(cancelFrom: data(answer(declined: true) { $0.removeValue(forKey: "reason") }), name: name))
        XCTAssertNil(PartnerCancelAnswer.answer(cancelFrom: data(answer(declined: true, reason: "No")), name: name))
        XCTAssertNil(PartnerCancelAnswer.answer(cancelFrom: data(answer { $0["status"] = "confirmed" }), name: name))
        XCTAssertNil(PartnerCancelAnswer.answer(cancelFrom: data(answer { $0["simulated"] = false }), name: name))
        XCTAssertNil(PartnerCancelAnswer.answer(cancelFrom: Data(), name: name))
        XCTAssertNil(PartnerCancelAnswer.answer(cancelFrom: data("[]"), name: name))
    }

    // MARK: C07-C09 failures

    func testC07_ATokenRejectionIsOnlyTheWorkersOwnBody() async {
        let own = await cancel(BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#))
        XCTAssertEqual(own, .failure(.tokenRejected))
        for text in [#"{"error":"nope"}"#, #"{"error":"unauthorized","x":1}"#, "", "unauthorized", "[]"] {
            let other = await cancel(BookingSendRecorder(status: 401, body: text))
            XCTAssertEqual(other, .failure(.other), text)
        }
    }

    func testC08_A404A500AndAnAnswerThatIsNotHTTPAreOtherWhateverTheyCarry() async {
        for status in [201, 204, 302, 400, 404, 500, 503] {
            let result = await cancel(BookingSendRecorder(status: status, body: answer()))
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }
        let notHTTP: PartnerClient.Send = { [self] request in
            (Data(answer().utf8), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
        let result = await client(notHTTP).cancel(requestID: requestID, partner: tables, flow: flow)
        XCTAssertEqual(result, .failure(.other))
        // Positive counterpart: the same body at 200 is accepted.
        let accepted = await cancel(BookingSendRecorder(status: 200, body: answer()))
        XCTAssertEqual(accepted, .success(.cancelled))
    }

    func testC09_AnOfflineErrorIsOfflineAndAnotherErrorIsOther() async {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            let result = await cancel(BookingSendRecorder(error: URLError(code)))
            XCTAssertEqual(result, .failure(.offline), "\(code)")
        }
        struct Other: Error {}
        for error in [URLError(.badServerResponse), URLError(.timedOut), URLError(.cancelled), Other()] as [Error] {
            let result = await cancel(BookingSendRecorder(error: error))
            XCTAssertEqual(result, .failure(.other), "\(error)")
        }
    }

    // MARK: C10-C12 the packets

    func testC10_ACancelledBookingRecordsTwoPacketsInOrderUnderTheGivenFlow() async {
        let (log, _) = makeLog()
        let result = await cancel(BookingSendRecorder(body: answer()), log: log)
        XCTAssertEqual(result, .success(.cancelled))
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>partner partner ok Example Tables: Cancellation requested",
                                    "partner>besir partner ok Example Tables: Request cancelled"])
        XCTAssertEqual(log.packets.map(\.flowID), [flow, flow])
    }

    func testC11_ADeclinedCancelRecordsTheDeclinedPacketAndAFailureRecordsOneRequestFailed() async {
        let (declinedLog, _) = makeLog()
        let declined = await cancel(BookingSendRecorder(body: answer(declined: true)), log: declinedLog)
        XCTAssertEqual(declined, .success(.declined))
        await declinedLog.flush()
        XCTAssertEqual(lines(declinedLog), ["besir>partner partner ok Example Tables: Cancellation requested",
                                            "partner>besir partner declined Example Tables: Cancellation declined"])
        XCTAssertEqual(declinedLog.packets.map(\.flowID), [flow, flow])

        let failures: [BookingSendRecorder] = [BookingSendRecorder(error: URLError(.notConnectedToInternet)),
                                               BookingSendRecorder(status: 404, body: "{}"),
                                               BookingSendRecorder(status: 500, body: "oops"),
                                               BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#),
                                               BookingSendRecorder(body: "[]"),
                                               BookingSendRecorder(body: answer(name: "Real Tables"))]
        for recorder in failures {
            let (log, _) = makeLog()
            _ = await cancel(recorder, log: log)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>partner partner failed Request failed"])
            XCTAssertEqual(log.packets.first?.flowID, flow)
        }
    }

    func testC12_ACancelledTaskRecordsNothingAndNoPacketHoldsTheRequestIDAPlaceOrATime() async throws {
        // Cancelled before the call: nothing is sent.
        let (before, _) = makeLog()
        let early = BookingSendRecorder(body: answer())
        let earlyResult = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cancel(early, log: before)
        }.value
        XCTAssertEqual(earlyResult, .failure(.other))
        XCTAssertTrue(early.requests.isEmpty)
        await before.flush()
        XCTAssertTrue(before.packets.isEmpty)

        // Cancelled while the request is in flight, with a valid answer coming back.
        let (during, _) = makeLog()
        let inFlight = BookingSendRecorder(body: answer())
        inFlight.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let flightResult = await Task { await cancel(inFlight, log: during) }.value
        XCTAssertEqual(flightResult, .failure(.other))
        XCTAssertEqual(inFlight.requests.count, 1)
        await during.flush()
        XCTAssertTrue(during.packets.isEmpty)

        // A finished exchange: neither the packets nor the file hold the id, a place, a time or the token.
        let (log, file) = makeLog()
        _ = await cancel(BookingSendRecorder(body: answer()), log: log)
        _ = await cancel(BookingSendRecorder(body: answer(declined: true)), log: log)
        await log.flush()
        XCTAssertEqual(log.packets.count, 4)
        let stored = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let seen = (lines(log).joined(separator: "\n") + "\n" + stored).lowercased()
        XCTAssertFalse(stored.isEmpty, "the control: the file was written")
        for word in [requestID, "3f2b8c1e", "latitude", "longitude", "address", "2026", "t19:00", token, host] {
            XCTAssertFalse(seen.contains(word), "a packet holds \(word)")
        }
    }

    // MARK: C13 the client is generic

    private static func scan(_ text: String, for needles: [String]) -> [String] {
        let lower = text.lowercased()
        return needles.filter { lower.contains($0) }
    }

    func testC13_ThePathIsTheGivenRouteFollowedByCancelAndTheClientNamesNoPartnerAndNoRoute() async throws {
        for route in ["/second", "/ride-share", "/booking", "/a"] {
            let recorder = BookingSendRecorder(body: answer(name: "Second Partner"))
            let (log, _) = makeLog()
            let result = await cancel(recorder, partner: (name: "Second Partner", route: route), log: log)
            XCTAssertEqual(result, .success(.cancelled), route)
            XCTAssertEqual(recorder.requests.first?.url?.path, route + "/cancel")
            XCTAssertEqual(recorder.requests.first?.url?.absoluteString, "https://\(host)" + route + "/cancel")
            await log.flush()
            XCTAssertEqual(lines(log).first, "besir>partner partner ok Second Partner: Cancellation requested", route)
        }
        // The answer is checked against the name the caller gives, not against a name of the client.
        let wrongName = await cancel(BookingSendRecorder(body: answer()), partner: (name: "Second Partner", route: "/second"))
        XCTAssertEqual(wrongName, .failure(.other))

        // Source scan: the client names no partner and holds no route literal but the suffix.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Shared/PartnerClient.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("final class PartnerClient"), "the control: the file read is the client")
        XCTAssertTrue(text.contains("func cancel("), "the control: the file holds the cancel call")
        XCTAssertEqual(Self.scan(text, for: ["booking", "example", "tables", "delivery", "budget"]), [])
        XCTAssertEqual(text.components(separatedBy: "\"/").count - 1, 1, "a route literal other than the suffix")
        XCTAssertTrue(text.contains("\"/cancel\""))
        // The scan finds what it looks for.
        XCTAssertEqual(Self.scan("let route = \"/Booking\" // Example Tables", for: ["booking", "example", "tables"]), ["booking", "example", "tables"])
        XCTAssertEqual(Self.scan("let route = entry.route", for: ["booking", "example", "tables"]), [])
    }
}
