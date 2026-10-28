import XCTest
@testable import besir

/// Hands out a scripted answer and remembers every request, so no test touches the network.
final class BookingSendRecorder {
    private(set) var requests: [URLRequest] = []
    var result: Result<(Data, Int), Error>
    /// Runs inside the send call, before the answer is handed back (for a task cancelled in flight).
    var duringSend: (() -> Void)?

    init(status: Int = 200, body: String = "") {
        result = .success((Data(body.utf8), status))
    }

    init(error: Error) {
        result = .failure(error)
    }

    var send: BookingClient.Send {
        { [self] request in
            requests.append(request)
            duringSend?()
            switch result {
            case .success(let (data, status)):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (data, response)
            case .failure(let error):
                throw error
            }
        }
    }
}

/// SPEC-BOOKING-001 AC-BOOKING-003 and AC-BOOKING-007: one fixed request, only an exact answer is accepted, and the exchange
/// is drawn as packets that hold fixed words only. Every log is built with a temporary file.
@MainActor
final class BookingClientTests: XCTestCase {
    private let token = "booking-token-0001"
    private let host = "booking-host.invalid"
    private let flow = UUID()
    private var config: AppConfig { AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: token) }
    private let request = BookingRequest(requestID: "3F2B8C1E-5D4A-4E7B-9A60-1C2D3E4F5A6B", restaurant: "Test Cafe",
                                         partySize: 2, start: "2026-11-02T19:00")

    // MARK: Helpers

    private func makeLog(failing: Bool = false) -> (log: ConnectionLog, file: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("booking-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(ConnectionLog.fileName)
        if failing { return (ConnectionLog(fileURL: file, write: { _, _ in throw WriteFailure() }), file) }
        return (ConnectionLog(fileURL: file, secrets: { [self] in [token, host] }), file)
    }

    private struct WriteFailure: Error {}

    private func client(_ recorder: BookingSendRecorder, log: ConnectionLog? = nil, config: AppConfig? = nil) -> BookingClient {
        BookingClient(config: config ?? self.config, send: recorder.send, connections: log ?? makeLog().log)
    }

    private func book(_ recorder: BookingSendRecorder, log: ConnectionLog? = nil,
                      config: AppConfig? = nil) async -> Result<BookingAnswer, BookingFailure> {
        await client(recorder, log: log, config: config).book(request, flow: flow)
    }

    private func object(_ mutate: (inout [String: Any]) -> Void = { _ in }, declined: Bool = false) -> String {
        var fields: [String: Any] = ["status": declined ? "declined" : "confirmed", "partner": "Example Tables", "simulated": true,
                                     "restaurant": "Test Cafe", "party_size": 2, "start": "2026-11-02T19:00"]
        if declined { fields["reason"] = "no_table" } else { fields["reservation_code"] = "EX-AB12CD" }
        mutate(&fields)
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func lines(_ log: ConnectionLog) -> [String] {
        log.packets.map { "\($0.from.rawValue)>\($0.to.rawValue) \($0.kind.rawValue) \($0.status.rawValue) \($0.summary)" }
    }

    private func assertOther(_ bodies: [String], file: StaticString = #filePath, line: UInt = #line) async {
        for text in bodies {
            let result = await book(BookingSendRecorder(body: text))
            XCTAssertEqual(result, .failure(.other), text, file: file, line: line)
        }
    }

    // MARK: C01-C04 the request

    func testBOOKING_C01_RequestIsAPostToBookingWithTokenAndJson() async throws {
        let recorder = BookingSendRecorder(body: object())
        _ = await book(recorder)
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/booking")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-besir-token"), token)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testBOOKING_C02_BodyHasExactlyTheFourKeysAndTheRequestValues() async throws {
        let recorder = BookingSendRecorder(body: object())
        _ = await book(recorder)
        let sent = try body(of: XCTUnwrap(recorder.requests.first))
        XCTAssertEqual(Set(sent.keys), ["request_id", "restaurant", "party_size", "start"])
        XCTAssertEqual(sent["request_id"] as? String, request.requestID)
        XCTAssertEqual(sent["restaurant"] as? String, "Test Cafe")
        XCTAssertEqual(sent["party_size"] as? Int, 2)
        XCTAssertEqual(sent["start"] as? String, "2026-11-02T19:00")
    }

    func testBOOKING_C03_BodyHoldsNothingPersonalOrFromTheConfiguration() async throws {
        var loud = config
        loud.proxyBaseURL = "https://sentinel-host-777.invalid"
        loud.appToken = "sentinel-token-777"
        loud.kakaoJsKey = "sentinel-kakao-777"
        let recorder = BookingSendRecorder(body: object())
        _ = await book(recorder, config: loud)
        let data = try XCTUnwrap(recorder.requests.first?.httpBody)
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for word in ["sentinel", "latitude", "longitude", "timezone", "place_id", "placeid", "address", "phone", "email", "name\""] {
            XCTAssertFalse(text.contains(word), "the body holds \(word)")
        }
        XCTAssertEqual(Set(try body(of: XCTUnwrap(recorder.requests.first)).keys).count, 4)
    }

    func testBOOKING_C04_NoProxyGivesNotSetUpWithoutACallOrAPacket() async {
        let (log, _) = makeLog()
        for blank in [AppConfig(), AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: ""),
                      AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: token)] {
            let recorder = BookingSendRecorder(body: object())
            let result = await book(recorder, log: log, config: blank)
            XCTAssertEqual(result, .failure(.notSetUp))
            XCTAssertTrue(recorder.requests.isEmpty)
        }
        XCTAssertFalse(client(BookingSendRecorder(), config: AppConfig()).isConfigured)
        XCTAssertTrue(client(BookingSendRecorder()).isConfigured)
        await log.flush()
        XCTAssertTrue(log.packets.isEmpty)
    }

    // MARK: C05-C14 the answer is checked

    func testBOOKING_C05_AConfirmedAnswerGivesTheCode() async {
        let result = await book(BookingSendRecorder(body: object()))
        XCTAssertEqual(result, .success(.confirmed(code: "EX-AB12CD")))
    }

    func testBOOKING_C06_ADeclinedAnswerGivesDeclined() async {
        let result = await book(BookingSendRecorder(body: object(declined: true)))
        XCTAssertEqual(result, .success(.declined))
    }

    func testBOOKING_C07_AConfirmedAnswerThatDeviatesIsOther() async {
        var bodies: [String] = []
        for code in ["EX-ab12cd", "EX-AB12C", "EX-AB12CDE", "ex-AB12CD", "XX-AB12CD", "EX-AB12C\n", "EX-AB 2CD", "EX-ÀB12CD", ""] {
            bodies.append(object { $0["reservation_code"] = code })
        }
        bodies.append(object { $0.removeValue(forKey: "reservation_code") })
        bodies.append(object { $0["reservation_code"] = 123456789 })
        bodies.append(object { $0["reason"] = "no_table" })
        bodies.append(object { $0["status"] = "pending" })
        bodies.append(object { $0["status"] = "CONFIRMED" })
        bodies.append(object { $0.removeValue(forKey: "status") })
        bodies.append(object { $0["status"] = true })
        await assertOther(bodies)
    }

    func testBOOKING_C08_ADeclinedAnswerThatDeviatesIsOther() async {
        var bodies: [String] = []
        bodies.append(object({ $0["reservation_code"] = "EX-AB12CD" }, declined: true))
        bodies.append(object({ $0.removeValue(forKey: "reason") }, declined: true))
        bodies.append(object({ $0["reason"] = "closed" }, declined: true))
        bodies.append(object({ $0["reason"] = "NO_TABLE" }, declined: true))
        bodies.append(object({ $0["reason"] = 1 }, declined: true))
        await assertOther(bodies)
    }

    func testBOOKING_C09_APartnerThatIsWrongOrMissingIsOther() async {
        await assertOther([
            object { $0["partner"] = "Real Tables" },
            object { $0["partner"] = "example tables" },
            object { $0["partner"] = "Example Tables " },
            object { $0.removeValue(forKey: "partner") },
            object { $0["partner"] = 5 },
        ])
    }

    func testBOOKING_C10_SimulatedThatIsNotTrueIsOther() async {
        await assertOther([
            object { $0["simulated"] = false },
            object { $0.removeValue(forKey: "simulated") },
            object { $0["simulated"] = "true" },
            object { $0["simulated"] = 1 },
            object { $0["simulated"] = NSNull() },
        ])
    }

    func testBOOKING_C11_AMissingKeyOrAWrongTypeIsOther() async {
        await assertOther([
            object { $0.removeValue(forKey: "restaurant") },
            object { $0.removeValue(forKey: "party_size") },
            object { $0.removeValue(forKey: "start") },
            object { $0["party_size"] = "2" },
            object { $0["party_size"] = true },
            object { $0["party_size"] = NSNull() },
            object { $0["restaurant"] = 7 },
            object { $0["start"] = 20261102 },
        ])
    }

    func testBOOKING_C12_AnEchoThatDiffersIsOther() async {
        await assertOther([
            object { $0["restaurant"] = "Other Cafe" },
            object { $0["restaurant"] = "Test Cafe " },
            object { $0["party_size"] = 3 },
            object { $0["party_size"] = 2.5 },
            object { $0["start"] = "2026-11-02T19:01" },
            object { $0["start"] = "2026-11-03T19:00" },
        ])
    }

    func testBOOKING_C13_AnExtraKeyIsOther() async {
        await assertOther([
            object { $0["name"] = "x" },
            object { $0["note"] = NSNull() },
            object({ $0["extra"] = 1 }, declined: true),
        ])
    }

    func testBOOKING_C14_ANonObjectBodyOrAStatusOtherThan200IsOther() async {
        await assertOther(["[]", "null", "\"confirmed\"", "5", "", "not json", "{}"])
        for status in [201, 202, 204, 302, 400, 404, 500, 503] {
            let result = await book(BookingSendRecorder(status: status, body: object()))
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }
        // Positive counterpart: the same body at 200 is accepted.
        let accepted = await book(BookingSendRecorder(status: 200, body: object()))
        XCTAssertEqual(accepted, .success(.confirmed(code: "EX-AB12CD")))
    }

    // MARK: C15-C20 failures

    func testBOOKING_C15_ATokenRejectionIsOnlyTheWorkersOwnBody() async {
        let own = await book(BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#))
        XCTAssertEqual(own, .failure(.tokenRejected))
        for text in [#"{"error":"nope"}"#, #"{"error":"unauthorized","x":1}"#, "", "unauthorized", "[]"] {
            let other = await book(BookingSendRecorder(status: 401, body: text))
            XCTAssertEqual(other, .failure(.other), text)
        }
    }

    func testBOOKING_C16_A404AndA500AreOther() async {
        for status in [404, 500] {
            let result = await book(BookingSendRecorder(status: status, body: #"{"error":"not_found"}"#))
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }
    }

    func testBOOKING_C17_AnOfflineErrorIsOfflineAndAnotherErrorIsOther() async {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            let result = await book(BookingSendRecorder(error: URLError(code)))
            XCTAssertEqual(result, .failure(.offline), "\(code)")
        }
        for error in [URLError(.badServerResponse), URLError(.timedOut), URLError(.cancelled), WriteFailure()] as [Error] {
            let result = await book(BookingSendRecorder(error: error))
            XCTAssertEqual(result, .failure(.other), "\(error)")
        }
    }

    func testBOOKING_C18_TheTimeoutIsTwentySeconds() async throws {
        let recorder = BookingSendRecorder(body: object())
        _ = await book(recorder)
        XCTAssertEqual(try XCTUnwrap(recorder.requests.first).timeoutInterval, 20)
    }

    func testBOOKING_C19_ACancelledTaskReturnsAndRecordsNothing() async {
        // Cancelled before the call: nothing is sent.
        let (before, _) = makeLog()
        let early = BookingSendRecorder(body: object())
        let earlyResult = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await book(early, log: before)
        }.value
        XCTAssertEqual(earlyResult, .failure(.other))
        XCTAssertTrue(early.requests.isEmpty)
        await before.flush()
        XCTAssertTrue(before.packets.isEmpty)

        // Cancelled while the request is in flight, with a valid confirmation coming back.
        let (during, _) = makeLog()
        let inFlight = BookingSendRecorder(body: object())
        inFlight.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let flightResult = await Task { await book(inFlight, log: during) }.value
        XCTAssertEqual(flightResult, .failure(.other))
        XCTAssertEqual(inFlight.requests.count, 1)
        await during.flush()
        XCTAssertTrue(during.packets.isEmpty)
    }

    func testBOOKING_C20_AFailureHoldsNoTextOfTheAnswer() async {
        let leak = "LEAK-SENTINEL-99"
        let (log, file) = makeLog()
        let deviating = object { $0["reservation_code"] = leak; $0["note"] = leak }
        for status in [200, 401, 404, 500] {
            let result = await book(BookingSendRecorder(status: status, body: deviating), log: log)
            guard case .failure(let failure) = result else { return XCTFail("status \(status) is not a failure") }
            XCTAssertEqual(String(describing: failure), "other", "a failure is a bare case")
        }
        await log.flush()
        XCTAssertFalse(lines(log).joined().contains(leak))
        XCTAssertFalse(((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains(leak))
    }

    // MARK: L01-L02 the log cases

    func testBOOKING_L01_TheNewCasesHaveEnglishNamesAndTheDefaultSummary() {
        XCTAssertEqual(ConnectionParty.bookingPartner.displayName, "Example Tables (Simulated)")
        XCTAssertEqual(ConnectionParty.bookingPartner.displayName, BookingClient.partnerName + " (Simulated)")
        XCTAssertEqual(ConnectionKind.booking.displayName, "Booking")
        XCTAssertEqual(ConnectionKind.booking.defaultSummary, "Reservation")
        for text in [ConnectionParty.bookingPartner.displayName, ConnectionKind.booking.displayName, ConnectionKind.booking.defaultSummary] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.unicodeScalars.allSatisfy { $0.isASCII })
        }
        // Every earlier case keeps its raw value and name.
        XCTAssertEqual(ConnectionParty.appleCalendar.rawValue, "appleCalendar")
        XCTAssertEqual(ConnectionParty.museSpark.displayName, "Muse Spark")
        XCTAssertEqual(ConnectionKind.calendarSave.defaultSummary, "Event saved")
    }

    func testBOOKING_L02_ABookingPacketLoadsAndAnUnknownCaseDropsThatPacketAlone() throws {
        let file = makeLog().file
        let good = ConnectionPacket(id: UUID(), flowID: flow, at: Date(timeIntervalSince1970: 100), from: .besir, to: .bookingPartner,
                                    kind: .booking, summary: "Table for 2 requested", status: .ok)
        let other = ConnectionPacket(id: UUID(), flowID: nil, at: Date(timeIntervalSince1970: 200), from: .bookingPartner, to: .besir,
                                     kind: .booking, summary: "Reservation confirmed", status: .ok)
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([good, other])) as? [[String: Any]])
        objects[1]["from"] = "carrierPigeon"
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: objects).write(to: file)
        let loaded = ConnectionLog(fileURL: file)
        XCTAssertEqual(loaded.packets, [good])
    }

    // MARK: P01-P03, P05, P06, P08 the packets

    func testBOOKING_P01_AConfirmationRecordsTwoPacketsInOrderWithOneFlow() async {
        let (log, _) = makeLog()
        _ = await book(BookingSendRecorder(body: object()), log: log)
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>bookingPartner booking ok Table for 2 requested",
                                    "bookingPartner>besir booking ok Reservation confirmed"])
        XCTAssertEqual(log.packets.map(\.flowID), [flow, flow])
    }

    func testBOOKING_P02_ADeclineRecordsNoTableAvailableAsDeclined() async {
        let (log, _) = makeLog()
        var big = request
        big = BookingRequest(requestID: big.requestID, restaurant: big.restaurant, partySize: 9, start: big.start)
        let reply = object({ $0["party_size"] = 9 }, declined: true)
        _ = await client(BookingSendRecorder(body: reply), log: log).book(big, flow: flow)
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>bookingPartner booking ok Table for 9 requested",
                                    "bookingPartner>besir booking declined No table available"])
    }

    func testBOOKING_P03_AFailureRecordsOneRequestFailedPacket() async {
        let failures: [BookingSendRecorder] = [BookingSendRecorder(error: URLError(.notConnectedToInternet)),
                                               BookingSendRecorder(status: 404, body: "{}"),
                                               BookingSendRecorder(status: 500, body: "oops"),
                                               BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#),
                                               BookingSendRecorder(body: "[]"),
                                               BookingSendRecorder(body: object { $0["partner"] = "Real Tables" })]
        for recorder in failures {
            let (log, _) = makeLog()
            _ = await book(recorder, log: log)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>bookingPartner booking failed Request failed"])
            XCTAssertEqual(log.packets.first?.flowID, flow)
        }
    }

    private func makeRig(config: AppConfig = PlaceSentinel.config, partner: EchoPartner = EchoPartner(),
                         failingLog: Bool = false) -> BookingRig {
        let rig = BookingRig(config: config, partner: partner, failingLog: failingLog)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    func testBOOKING_P04_CancelNoProxyAndACancelledTaskRecordNoPacket() async throws {
        // Cancel.
        let cancelRig = makeRig()
        _ = await cancelRig.card()?.resolve(.cancel)
        // No proxy: the gate refuses before any card exists.
        let blankRig = makeRig(config: PlaceSentinel.unconfigured)
        XCTAssertNil(blankRig.card())
        // A task cancelled while the request is in flight.
        let flightRig = makeRig()
        flightRig.partner.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let card = try XCTUnwrap(flightRig.card())
        _ = await Task { await card.resolve(.confirm) }.value
        XCTAssertEqual(flightRig.partner.requests.count, 1)
        for rig in [cancelRig, blankRig, flightRig] {
            await rig.log.flush()
            XCTAssertTrue(rig.log.packets.isEmpty)
            XCTAssertEqual(rig.partner.requests.count, rig === flightRig ? 1 : 0)
        }
        // Positive counterpart: a confirmed booking does record.
        let doneRig = makeRig()
        _ = await doneRig.card()?.resolve(.confirm)
        await doneRig.log.flush()
        XCTAssertEqual(doneRig.log.packets.count, 2)
    }

    func testBOOKING_P07_ALogThatCannotWriteChangesNothingTheUserOrTheModelSees() async throws {
        /// Everything a booking shows, except the random ids.
        func shown(_ rig: BookingRig) async throws -> String {
            let card = try XCTUnwrap(rig.card())
            let resolved = await card.resolve(.confirm)
            let resolution = try XCTUnwrap(resolved)
            var json = resolution.json ?? [:]
            json.removeValue(forKey: "id")
            let result = String(decoding: (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            let entries = rig.store.activities.map { "\($0.title)|\($0.startDate)|\($0.endDate)|\($0.location?.name ?? "")" }
            return [result, card.mark?.rawValue ?? "pending", resolution.notice ?? "no notice"].joined(separator: "\n") + "\n" + entries.joined(separator: "\n")
        }
        let healthy = try await shown(makeRig())
        let broken = try await shown(makeRig(failingLog: true))
        XCTAssertEqual(healthy, broken)
        XCTAssertTrue(healthy.contains("applied"))

        let offlineHealthy = EchoPartner()
        offlineHealthy.mode = .error(URLError(.notConnectedToInternet))
        let offlineBroken = EchoPartner()
        offlineBroken.mode = .error(URLError(.notConnectedToInternet))
        let failedHealthy = try await shown(makeRig(partner: offlineHealthy))
        let failedBroken = try await shown(makeRig(partner: offlineBroken, failingLog: true))
        XCTAssertEqual(failedHealthy, failedBroken)
        XCTAssertTrue(failedHealthy.contains("unavailable"))
    }

    func testBOOKING_P09_ABookingDoesNotChangeTheFlowOfTheAgentMessagePackets() async throws {
        let rig = makeRig()
        let call = Turns.call("request_booking", PlaceTurns.arguments(BookingRig.arguments()), id: "c1")
        let fake = FakeTransport([.turn(Turns.turn(call)), .turn(Turns.text("Booked, and it is simulated."))])
        let session = AgentSession(toolbox: rig.tools, transport: fake, connections: rig.log)
        session.send("Book a table for 2 tomorrow at 7 PM")
        await session.settle()
        XCTAssertNotNil(session.pendingCard)
        await session.confirmCard()
        await session.settle()
        await rig.log.flush()
        let agentFlows = Set(rig.log.packets.filter { $0.kind == .agentMessage || $0.kind == .agentToolCall }.map(\.flowID))
        let bookingFlows = Set(rig.log.packets.filter { $0.kind == .booking }.map(\.flowID))
        XCTAssertEqual(agentFlows.count, 1, "the agent's packets stay in one flow")
        XCTAssertNotNil(agentFlows.first ?? nil)
        XCTAssertEqual(bookingFlows.count, 1)
        XCTAssertNotNil(bookingFlows.first ?? nil)
        XCTAssertTrue(agentFlows.isDisjoint(with: bookingFlows), "the booking is a flow of its own")
        XCTAssertEqual(rig.log.packets.filter { $0.kind == .booking }.count, 2)
        XCTAssertFalse(rig.log.packets.filter { $0.kind == .agentMessage }.isEmpty)
    }

    func testBOOKING_P05_TheFileHoldsNoPlaceTimeCodeTokenOrHost() async throws {
        let place = "Pasta Palace Unique"
        let start = "2026-11-02T19:00"
        let specific = BookingRequest(requestID: request.requestID, restaurant: place, partySize: 2, start: start)
        let reply = object { $0["restaurant"] = place }
        let recorder = BookingSendRecorder(body: reply)
        let (log, file) = makeLog()
        let result = await client(recorder, log: log).book(specific, flow: flow)
        // The name and the time exist in the request, and the code in the answer, so the checks below can fail.
        let sent = String(decoding: try XCTUnwrap(recorder.requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(sent.contains(place))
        XCTAssertTrue(sent.contains(start))
        XCTAssertTrue(reply.contains("EX-AB12CD"))
        XCTAssertEqual(result, .success(.confirmed(code: "EX-AB12CD")))
        await log.flush()
        let stored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(stored.contains("Table for 2 requested"))
        for secret in [place, "Pasta", start, "19:00", "7:00", "EX-AB12CD", token, host, request.requestID] {
            XCTAssertFalse(stored.contains(secret), "connections.json holds \(secret)")
        }
    }

    func testBOOKING_P06_TheFlowReadsBesirExampleTablesBesir() async {
        let (log, _) = makeLog()
        _ = await book(BookingSendRecorder(body: object()), log: log)
        await log.flush()
        let flows = ConnectionFlows.group(log.packets)
        XCTAssertEqual(flows.count, 1)
        XCTAssertEqual(flows.map(ConnectionFlows.chainText), ["besir → Example Tables (Simulated) → besir"])
    }

    func testBOOKING_P08_TwoBookingsMakeTwoFlows() async {
        let (log, _) = makeLog()
        let first = UUID()
        let second = UUID()
        _ = await client(BookingSendRecorder(body: object()), log: log).book(request, flow: first)
        _ = await client(BookingSendRecorder(body: object()), log: log).book(request, flow: second)
        await log.flush()
        XCTAssertEqual(log.packets.count, 4)
        XCTAssertEqual(ConnectionFlows.group(log.packets).count, 2)
        XCTAssertEqual(Set(log.packets.compactMap(\.flowID)), [first, second])
    }
}
