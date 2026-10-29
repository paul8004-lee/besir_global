import XCTest
@testable import besir

/// SPEC-DELIVERY-001 AC-DELIVERY-003 and AC-DELIVERY-004: one fixed request, only an exact answer is accepted, and the exchange
/// is drawn as packets that hold fixed words only. Every log is built with a temporary file; the scripted sender is the one
/// the booking client tests use (the function type is the same).
@MainActor
final class DeliveryClientTests: XCTestCase {
    private let token = "delivery-token-0001"
    private let host = "delivery-host.invalid"
    private let flow = UUID()
    private let evening = "2026-11-02T19:40"
    private let late = "2026-11-02T23:30"
    private var config: AppConfig { AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: token) }

    private struct WriteFailure: Error {}

    // MARK: Helpers

    private func request(people: Int = 2, arrive: String? = nil, restaurant: String = "Test Cafe") -> DeliveryRequest {
        DeliveryRequest(requestID: "3F2B8C1E-5D4A-4E7B-9A60-1C2D3E4F5A6B", restaurant: restaurant, people: people,
                        arriveAt: arrive ?? evening)
    }

    private func makeLog(failing: Bool = false) -> (log: ConnectionLog, file: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(ConnectionLog.fileName)
        if failing { return (ConnectionLog(fileURL: file, write: { _, _ in throw WriteFailure() }), file) }
        return (ConnectionLog(fileURL: file, secrets: { [self] in [token, host] }), file)
    }

    private func client(_ recorder: BookingSendRecorder, log: ConnectionLog? = nil, config: AppConfig? = nil) -> DeliveryClient {
        DeliveryClient(config: config ?? self.config, send: recorder.send, connections: log ?? makeLog().log)
    }

    private func order(_ recorder: BookingSendRecorder, _ sent: DeliveryRequest? = nil, log: ConnectionLog? = nil,
                       config: AppConfig? = nil) async -> Result<DeliveryAnswer, DeliveryFailure> {
        await client(recorder, log: log, config: config).order(sent ?? request(), flow: flow)
    }

    /// The answer the Worker gives to `request()`, or to the request of `people` and `arrive`; `mutate` bends it.
    /// A declined answer defaults to the late time, so the status agrees with the hours rule unless a test says otherwise.
    private func object(_ mutate: (inout [String: Any]) -> Void = { _ in }, declined: Bool = false, people: Int = 2,
                        arrive: String? = nil) -> String {
        let when = arrive ?? (declined ? late : evening)
        var fields: [String: Any] = ["status": declined ? "declined" : "confirmed", "partner": "Example Delivery", "simulated": true,
                                     "restaurant": "Test Cafe", "people": people, "arrive_at": when]
        if declined {
            fields["reason"] = "outside_hours"
        } else {
            fields["order_id"] = "DL-AB12CD"
            fields["arrival_estimate"] = when
            fields["estimated_total_cents"] = people * 2200 + 500
        }
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

    private func assertOther(_ bodies: [String], sent: DeliveryRequest? = nil, file: StaticString = #filePath,
                             line: UInt = #line) async {
        for text in bodies {
            let result = await order(BookingSendRecorder(body: text), sent)
            XCTAssertEqual(result, .failure(.other), text, file: file, line: line)
        }
    }

    // MARK: C01-C03 the request

    func testC01_RequestIsAPostToDeliveryWithTokenJsonTheFourKeysAndTwentySeconds() async throws {
        let recorder = BookingSendRecorder(body: object())
        _ = await order(recorder)
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/delivery")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-besir-token"), token)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.timeoutInterval, 20)
        let fields = try body(of: sent)
        XCTAssertEqual(Set(fields.keys), ["request_id", "restaurant", "people", "arrive_at"])
        XCTAssertEqual(fields["request_id"] as? String, request().requestID)
        XCTAssertEqual(fields["restaurant"] as? String, "Test Cafe")
        XCTAssertEqual(fields["people"] as? Int, 2)
        XCTAssertEqual(fields["arrive_at"] as? String, evening)
    }

    func testC02_BodyHoldsNothingPersonalOrFromTheConfiguration() async throws {
        var loud = config
        loud.proxyBaseURL = "https://sentinel-host-777.invalid"
        loud.appToken = "sentinel-token-777"
        loud.kakaoJsKey = "sentinel-kakao-777"
        let recorder = BookingSendRecorder(body: object())
        _ = await order(recorder, config: loud)
        let sent = try XCTUnwrap(recorder.requests.first)
        let text = String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self).lowercased()
        // The request type has no field for any of these; the words show that none is sent under another name.
        for word in ["sentinel", "latitude", "longitude", "coordinate", "timezone", "time_zone", "place_id", "placeid", "address",
                     "origin", "start_place", "location", "phone", "email", "payment", "account", "device", "name\""] {
            XCTAssertFalse(text.contains(word), "the body holds \(word)")
        }
        XCTAssertEqual(Set(try body(of: sent).keys).count, 4)
        // The configuration still reaches the request line and the header, which is where it belongs.
        XCTAssertEqual(sent.url?.host, "sentinel-host-777.invalid")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-besir-token"), "sentinel-token-777")
    }

    func testC03_NoProxyGivesNotSetUpWithoutACallOrAPacket() async {
        let (log, _) = makeLog()
        for blank in [AppConfig(), AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: ""),
                      AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: token)] {
            let recorder = BookingSendRecorder(body: object())
            let result = await order(recorder, log: log, config: blank)
            XCTAssertEqual(result, .failure(.notSetUp))
            XCTAssertTrue(recorder.requests.isEmpty)
        }
        XCTAssertFalse(client(BookingSendRecorder(), config: AppConfig()).isConfigured)
        XCTAssertTrue(client(BookingSendRecorder()).isConfigured)
        await log.flush()
        XCTAssertTrue(log.packets.isEmpty)
    }

    // MARK: C04-C06, C11, C12 the answer is checked

    func testC04_AConfirmedAnswerGivesTheOrderIdAndTheTotal() async {
        let result = await order(BookingSendRecorder(body: object()))
        XCTAssertEqual(result, .success(.confirmed(orderID: "DL-AB12CD", estimatedTotalCents: 4900)))
        let twelve = await order(BookingSendRecorder(body: object(people: 12)), request(people: 12))
        XCTAssertEqual(twelve, .success(.confirmed(orderID: "DL-AB12CD", estimatedTotalCents: 26900)))
    }

    func testC05_ADeclinedAnswerGivesDeclined() async {
        let result = await order(BookingSendRecorder(body: object(declined: true)), request(arrive: late))
        XCTAssertEqual(result, .success(.declined))
    }

    func testC06_AnAnswerThatDeviatesIsOther() async {
        // A confirmed answer for the evening request.
        var confirmed: [String] = []
        confirmed.append(object { $0["partner"] = "Real Delivery" })
        confirmed.append(object { $0["partner"] = "example delivery" })
        confirmed.append(object { $0["partner"] = "Example Delivery " })
        confirmed.append(object { $0.removeValue(forKey: "partner") })
        confirmed.append(object { $0["partner"] = 5 })
        confirmed.append(object { $0["simulated"] = false })
        confirmed.append(object { $0.removeValue(forKey: "simulated") })
        confirmed.append(object { $0["simulated"] = "true" })
        confirmed.append(object { $0["simulated"] = 1 })
        confirmed.append(object { $0["simulated"] = NSNull() })
        confirmed.append(object { $0["restaurant"] = "Other Cafe" })
        confirmed.append(object { $0["restaurant"] = "Test Cafe " })
        confirmed.append(object { $0["restaurant"] = 7 })
        confirmed.append(object { $0.removeValue(forKey: "restaurant") })
        confirmed.append(object { $0["people"] = 3 })
        confirmed.append(object { $0["people"] = "2" })
        confirmed.append(object { $0["people"] = NSNull() })
        confirmed.append(object { $0.removeValue(forKey: "people") })
        confirmed.append(object { $0["arrive_at"] = "2026-11-02T19:41" })
        confirmed.append(object { $0["arrive_at"] = "2026-11-03T19:40" })
        confirmed.append(object { $0["arrive_at"] = 20261102 })
        confirmed.append(object { $0["status"] = "pending" })
        confirmed.append(object { $0["status"] = "CONFIRMED" })
        confirmed.append(object { $0["status"] = true })
        confirmed.append(object { $0.removeValue(forKey: "status") })
        confirmed.append(object { $0["arrival_estimate"] = "2026-11-02T19:50" })
        confirmed.append(object { $0["arrival_estimate"] = 1940 })
        confirmed.append(object { $0.removeValue(forKey: "arrival_estimate") })
        confirmed.append(object { $0["estimated_total_cents"] = 4901 })
        confirmed.append(object { $0["estimated_total_cents"] = 4899 })
        confirmed.append(object { $0["estimated_total_cents"] = "4900" })
        confirmed.append(object { $0["estimated_total_cents"] = 4900.5 })
        confirmed.append(object { $0.removeValue(forKey: "estimated_total_cents") })
        confirmed.append(object { $0["order_id"] = "EX-AB12CD" })
        confirmed.append(object { $0["order_id"] = 123456789 })
        confirmed.append(object { $0.removeValue(forKey: "order_id") })
        confirmed.append(object { $0["reason"] = "outside_hours" })
        confirmed.append(object { $0["extra"] = 1 })
        confirmed.append(object { $0["note"] = NSNull() })
        await assertOther(confirmed)

        // A declined answer for the late request.
        var declined: [String] = []
        declined.append(object({ $0["order_id"] = "DL-AB12CD" }, declined: true))
        declined.append(object({ $0.removeValue(forKey: "reason") }, declined: true))
        declined.append(object({ $0["reason"] = "no_table" }, declined: true))
        declined.append(object({ $0["reason"] = "closed" }, declined: true))
        declined.append(object({ $0["reason"] = "OUTSIDE_HOURS" }, declined: true))
        declined.append(object({ $0["reason"] = 1 }, declined: true))
        declined.append(object({ $0["extra"] = 1 }, declined: true))
        declined.append(object({ $0["partner"] = "Real Delivery" }, declined: true))
        declined.append(object({ $0["simulated"] = false }, declined: true))
        declined.append(object({ $0["people"] = 3 }, declined: true))
        declined.append(object({ $0["arrive_at"] = "2026-11-02T23:31" }, declined: true))
        await assertOther(declined, sent: request(arrive: late))

        // The status has to agree with the hours rule, in both directions.
        await assertOther([object(arrive: late)], sent: request(arrive: late))
        await assertOther([object(declined: true, arrive: evening)], sent: request(arrive: evening))
        for time in ["2026-11-02T09:59", "2026-11-02T22:01", "2026-11-02T00:00", "2026-11-02T23:59"] {
            await assertOther([object(arrive: time)], sent: request(arrive: time))
        }
        for time in ["2026-11-02T10:00", "2026-11-02T22:00", "2026-11-02T12:00"] {
            let result = await order(BookingSendRecorder(body: object(arrive: time)), request(arrive: time))
            XCTAssertEqual(result, .success(.confirmed(orderID: "DL-AB12CD", estimatedTotalCents: 4900)), time)
        }
        for time in ["2026-11-02T09:59", "2026-11-02T22:01"] {
            let result = await order(BookingSendRecorder(body: object(declined: true, arrive: time)), request(arrive: time))
            XCTAssertEqual(result, .success(.declined), time)
        }

        // A time the client cannot read gives no answer at all.
        await assertOther([object(arrive: "tomorrow")], sent: request(arrive: "tomorrow"))
        await assertOther([object(arrive: "2026-11-02 19:40")], sent: request(arrive: "2026-11-02 19:40"))

        // A body that is not the object, and a status other than 200.
        await assertOther(["[]", "null", "\"confirmed\"", "5", "", "not json", "{}"])
        for status in [201, 202, 204, 302, 400, 404, 500, 503] {
            let result = await order(BookingSendRecorder(status: status, body: object()))
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }
        // Positive counterpart: the same body at 200 is accepted.
        let accepted = await order(BookingSendRecorder(status: 200, body: object()))
        XCTAssertEqual(accepted, .success(.confirmed(orderID: "DL-AB12CD", estimatedTotalCents: 4900)))
    }

    // MARK: C07-C10 failures

    func testC07_ATokenRejectionIsOnlyTheWorkersOwnBody() async {
        let own = await order(BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#))
        XCTAssertEqual(own, .failure(.tokenRejected))
        for text in [#"{"error":"nope"}"#, #"{"error":"unauthorized","x":1}"#, "", "unauthorized", "[]"] {
            let other = await order(BookingSendRecorder(status: 401, body: text))
            XCTAssertEqual(other, .failure(.other), text)
        }
    }

    func testC08_A404AndA500AreOtherAndAnOfflineErrorIsOffline() async {
        for status in [404, 500] {
            let result = await order(BookingSendRecorder(status: status, body: #"{"error":"not_found"}"#))
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            let result = await order(BookingSendRecorder(error: URLError(code)))
            XCTAssertEqual(result, .failure(.offline), "\(code)")
        }
        for error in [URLError(.badServerResponse), URLError(.timedOut), URLError(.cancelled), WriteFailure()] as [Error] {
            let result = await order(BookingSendRecorder(error: error))
            XCTAssertEqual(result, .failure(.other), "\(error)")
        }
    }

    func testC09_AFailureHoldsNoTextOfTheAnswer() async {
        let leak = "LEAK-SENTINEL-99"
        let (log, file) = makeLog()
        let deviating = object { $0["order_id"] = leak; $0["note"] = leak }
        for status in [200, 401, 404, 500] {
            let result = await order(BookingSendRecorder(status: status, body: deviating), log: log)
            guard case .failure(let failure) = result else { return XCTFail("status \(status) is not a failure") }
            XCTAssertEqual(String(describing: failure), "other", "a failure is a bare case")
        }
        await log.flush()
        XCTAssertFalse(lines(log).joined().contains(leak))
        XCTAssertFalse(((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains(leak))
    }

    func testC10_ACancelledTaskReturnsAFailureAndSendsNothingBeforeTheCall() async {
        // Cancelled before the call: nothing is sent.
        let early = BookingSendRecorder(body: object())
        let earlyResult = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await order(early)
        }.value
        XCTAssertEqual(earlyResult, .failure(.other))
        XCTAssertTrue(early.requests.isEmpty)

        // Cancelled while the request is in flight, with a valid confirmation coming back.
        let (during, _) = makeLog()
        let inFlight = BookingSendRecorder(body: object())
        inFlight.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let flightResult = await Task { await order(inFlight, log: during) }.value
        XCTAssertEqual(flightResult, .failure(.other))
        XCTAssertEqual(inFlight.requests.count, 1)
        await during.flush()
        XCTAssertTrue(during.packets.isEmpty)
    }

    func testC11_TheAnswerCheckAcceptsTwoPointZeroAndRefusesABooleanWhereANumberBelongs() async {
        let plain = object()
        XCTAssertTrue(plain.contains("\"people\":2,"))
        XCTAssertTrue(plain.contains("\"estimated_total_cents\":4900,"))
        let floating = plain.replacingOccurrences(of: "\"people\":2,", with: "\"people\":2.0,")
            .replacingOccurrences(of: "\"estimated_total_cents\":4900,", with: "\"estimated_total_cents\":4900.0,")
        XCTAssertTrue(floating.contains("\"people\":2.0,"))
        XCTAssertTrue(floating.contains("\"estimated_total_cents\":4900.0,"))
        let accepted = await order(BookingSendRecorder(body: floating))
        XCTAssertEqual(accepted, .success(.confirmed(orderID: "DL-AB12CD", estimatedTotalCents: 4900)))

        await assertOther([
            object { $0["people"] = true },
            object { $0["estimated_total_cents"] = true },
            object { $0["people"] = 2.5 },
            plain.replacingOccurrences(of: "\"people\":2,", with: "\"people\":2.5,"),
        ])
        let one = request(people: 1)
        await assertOther([object({ $0["people"] = true }, people: 1)], sent: one)
        await assertOther([object({ $0["estimated_total_cents"] = true }, people: 1)], sent: one)
    }

    func testC12_TheOrderIdIsDLAndSixOfUpperCaseAsciiLettersAndDigits() async {
        let valid = await order(BookingSendRecorder(body: object { $0["order_id"] = "DL-Z9Y8X7" }))
        XCTAssertEqual(valid, .success(.confirmed(orderID: "DL-Z9Y8X7", estimatedTotalCents: 4900)))
        let digits = await order(BookingSendRecorder(body: object { $0["order_id"] = "DL-012345" }))
        XCTAssertEqual(digits, .success(.confirmed(orderID: "DL-012345", estimatedTotalCents: 4900)))
        var bodies: [String] = []
        for id in ["DL-ab12cd", "DL-AB12Cd", "DL-AB12C", "DL-AB12CDE", "dl-AB12CD", "EX-AB12CD", "XX-AB12CD", "DL-AB12C\n",
                   "DL-AB 2CD", "DL-ÀB12CD", "DL-AB\u{0661}\u{0662}CD", "DL\u{2010}AB12CD", "DLAB12CDX", "DL-", ""] {
            bodies.append(object { $0["order_id"] = id })
        }
        await assertOther(bodies)
    }

    func testC13_TheClientNeverReadsOrWritesTheBudgetLedger() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-ledger-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(BudgetLedger.fileName)
        let ledger = BudgetLedger(fileURL: file)
        XCTAssertTrue(ledger.add(BudgetEntry(requestID: "ledger-entry-1", weekStart: "2026-11-02", amountCents: 1850, isEstimate: false)))
        let before = try Data(contentsOf: file)
        XCTAssertFalse(before.isEmpty)
        let shared = AppConfig.supportDirectory.appendingPathComponent(BudgetLedger.fileName)
        let sharedBefore = try? Data(contentsOf: shared)

        let (log, _) = makeLog()
        let confirmed = await order(BookingSendRecorder(body: object()), log: log)
        let declined = await order(BookingSendRecorder(body: object(declined: true)), request(arrive: late), log: log)
        let failed = await order(BookingSendRecorder(status: 500, body: "oops"), log: log)
        XCTAssertEqual(confirmed, .success(.confirmed(orderID: "DL-AB12CD", estimatedTotalCents: 4900)))
        XCTAssertEqual(declined, .success(.declined))
        XCTAssertEqual(failed, .failure(.other))

        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-11-02"), 1850)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [BudgetLedger.fileName])
        XCTAssertEqual(try? Data(contentsOf: shared), sharedBefore)
        XCTAssertFalse(BudgetLedger.shared.contains(requestID: request().requestID))
    }

    // MARK: P01-P06 the packets

    func testP01_AConfirmationRecordsTwoPacketsInOrderWithOneFlow() async {
        let (log, _) = makeLog()
        _ = await order(BookingSendRecorder(body: object()), log: log)
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>deliveryPartner delivery ok Delivery for 2 requested",
                                    "deliveryPartner>besir delivery ok Order confirmed"])
        XCTAssertEqual(log.packets.map(\.flowID), [flow, flow])
    }

    func testP02_ADeclineRecordsOrderNotAvailableAsDeclined() async {
        let (log, _) = makeLog()
        let result = await order(BookingSendRecorder(body: object(declined: true)), request(arrive: late), log: log)
        XCTAssertEqual(result, .success(.declined))
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>deliveryPartner delivery ok Delivery for 2 requested",
                                    "deliveryPartner>besir delivery declined Order not available"])
        XCTAssertEqual(log.packets.map(\.flowID), [flow, flow])
    }

    func testP03_AFailureRecordsOneRequestFailedPacketAndNothingAfterIt() async {
        let failures: [BookingSendRecorder] = [BookingSendRecorder(error: URLError(.notConnectedToInternet)),
                                               BookingSendRecorder(status: 404, body: "{}"),
                                               BookingSendRecorder(status: 500, body: "oops"),
                                               BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#),
                                               BookingSendRecorder(body: "[]"),
                                               BookingSendRecorder(body: object { $0["partner"] = "Real Delivery" })]
        for recorder in failures {
            let (log, _) = makeLog()
            _ = await order(recorder, log: log)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>deliveryPartner delivery failed Request failed"])
            XCTAssertEqual(log.packets.first?.flowID, flow)
        }
    }

    func testP04_NoPacketWhenNoRequestWasSentOrTheTaskWasCancelled() async {
        // No proxy: nothing is sent.
        let (blankLog, _) = makeLog()
        let blank = BookingSendRecorder(body: object())
        let blankResult = await order(blank, log: blankLog, config: AppConfig())
        XCTAssertEqual(blankResult, .failure(.notSetUp))
        XCTAssertTrue(blank.requests.isEmpty)

        // Cancelled before the call.
        let (earlyLog, _) = makeLog()
        let early = BookingSendRecorder(body: object())
        _ = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await order(early, log: earlyLog)
        }.value
        XCTAssertTrue(early.requests.isEmpty)

        // Cancelled while the request is in flight.
        let (flightLog, _) = makeLog()
        let flight = BookingSendRecorder(body: object())
        flight.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        _ = await Task { await order(flight, log: flightLog) }.value
        XCTAssertEqual(flight.requests.count, 1)

        for log in [blankLog, earlyLog, flightLog] {
            await log.flush()
            XCTAssertTrue(log.packets.isEmpty)
        }
        // Positive counterpart: a confirmed order does record.
        let (doneLog, _) = makeLog()
        _ = await order(BookingSendRecorder(body: object()), log: doneLog)
        await doneLog.flush()
        XCTAssertEqual(doneLog.packets.count, 2)
    }

    func testP05_NoSummaryHoldsThePlaceTheTimeTheOrderIdAMoneySignOrAnyAnswerText() async throws {
        let place = "Pasta Palace Unique"
        let specific = request(people: 7, arrive: evening, restaurant: place)
        let reply = object({ $0["restaurant"] = place; $0["order_id"] = "DL-QX7Z9K" }, people: 7)
        let recorder = BookingSendRecorder(body: reply)
        let (log, file) = makeLog()
        let result = await client(recorder, log: log).order(specific, flow: flow)
        // The name, the time, the id and the total exist in the request or the answer, so the checks below can fail.
        let sent = String(decoding: try XCTUnwrap(recorder.requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(sent.contains(place))
        XCTAssertTrue(sent.contains(evening))
        XCTAssertTrue(reply.contains("DL-QX7Z9K"))
        XCTAssertTrue(reply.contains("15900"))
        XCTAssertEqual(result, .success(.confirmed(orderID: "DL-QX7Z9K", estimatedTotalCents: 15900)))
        await log.flush()
        let stored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(stored.contains("Delivery for 7 requested"))
        for secret in [place, "Pasta", evening, "19:40", "7:40", "DL-QX7Z9K", "QX7Z9K", "15900", "159", token, host, specific.requestID] {
            XCTAssertFalse(stored.contains(secret), "connections.json holds \(secret)")
        }
        let summaries = log.packets.map(\.summary)
        XCTAssertEqual(summaries.count, 2)
        for summary in summaries {
            XCTAssertFalse(summary.contains("$"))
            XCTAssertTrue(summary.unicodeScalars.allSatisfy { $0.isASCII })
        }
        XCTAssertEqual(summaries.map { $0.filter(\.isNumber) }, ["7", ""])
    }

    func testP06_ALogThatCannotWriteChangesNoResult() async {
        let cases: [(BookingSendRecorder, DeliveryRequest)] = [
            (BookingSendRecorder(body: object()), request()),
            (BookingSendRecorder(body: object(declined: true)), request(arrive: late)),
            (BookingSendRecorder(status: 500, body: "oops"), request()),
            (BookingSendRecorder(error: URLError(.notConnectedToInternet)), request()),
        ]
        for (recorder, sent) in cases {
            let (broken, _) = makeLog(failing: true)
            let (healthy, _) = makeLog()
            let withBroken = await order(recorder, sent, log: broken)
            let withHealthy = await order(recorder, sent, log: healthy)
            XCTAssertEqual(withBroken, withHealthy)
            await broken.flush()
            await healthy.flush()
            XCTAssertEqual(lines(broken), lines(healthy))
        }
        let confirmed = await order(BookingSendRecorder(body: object()), log: makeLog(failing: true).log)
        XCTAssertEqual(confirmed, .success(.confirmed(orderID: "DL-AB12CD", estimatedTotalCents: 4900)))
    }

    // MARK: P07 the log cases

    func testP07_TheNewCasesHaveEnglishNamesTheDefaultSummaryAndEveryOldCaseIsUnchanged() throws {
        XCTAssertEqual(ConnectionParty.deliveryPartner.rawValue, "deliveryPartner")
        XCTAssertEqual(ConnectionKind.delivery.rawValue, "delivery")
        XCTAssertEqual(ConnectionParty.deliveryPartner.displayName, "Example Delivery (Simulated)")
        XCTAssertEqual(ConnectionParty.deliveryPartner.displayName, DeliveryClient.partnerName + " (Simulated)")
        XCTAssertEqual(ConnectionKind.delivery.displayName, "Delivery")
        XCTAssertEqual(ConnectionKind.delivery.defaultSummary, "Delivery")
        for text in [ConnectionParty.deliveryPartner.displayName, ConnectionKind.delivery.displayName, ConnectionKind.delivery.defaultSummary] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.unicodeScalars.allSatisfy { $0.isASCII })
        }
        // The new cases come after every old one.
        XCTAssertEqual(ConnectionParty.allCases.last, .deliveryPartner)
        XCTAssertEqual(ConnectionKind.allCases.last, .delivery)
        // Every earlier case keeps its raw value and name, the budget ones of card t70 among them.
        let parties: [(ConnectionParty, String, String)] = [
            (.instagram, "instagram", "Instagram"), (.shareSheet, "shareSheet", "Share sheet"), (.besir, "besir", "besir"),
            (.museSpark, "museSpark", "Muse Spark"), (.imageReader, "imageReader", "Image reader"),
            (.googlePlaces, "googlePlaces", "Google Places"), (.googleRoutes, "googleRoutes", "Google Routes"),
            (.appleCalendar, "appleCalendar", "Apple Calendar"), (.bookingPartner, "bookingPartner", "Example Tables (Simulated)"),
            (.budgetPartner, "budgetPartner", "Example Budget (Simulated)")]
        for (party, raw, name) in parties {
            XCTAssertEqual(party.rawValue, raw)
            XCTAssertEqual(party.displayName, name)
        }
        let kinds: [(ConnectionKind, String, String, String)] = [
            (.share, "share", "Share", "Shared item"), (.imageRead, "imageRead", "Image read", "Image read"),
            (.placeSearch, "placeSearch", "Place search", "Place search"), (.route, "route", "Route", "Route lookup"),
            (.agentMessage, "agentMessage", "Message", "Message"), (.agentToolCall, "agentToolCall", "Tool call", "Tool call"),
            (.calendarSave, "calendarSave", "Calendar save", "Event saved"), (.booking, "booking", "Booking", "Reservation"),
            (.budget, "budget", "Budget", "Budget")]
        for (kind, raw, name, summary) in kinds {
            XCTAssertEqual(kind.rawValue, raw)
            XCTAssertEqual(kind.displayName, name)
            XCTAssertEqual(kind.defaultSummary, summary)
        }
        XCTAssertEqual(ConnectionParty.allCases.count, parties.count + 1)
        XCTAssertEqual(ConnectionKind.allCases.count, kinds.count + 1)
        // A delivery packet survives the file round trip.
        let packet = ConnectionPacket(id: UUID(), flowID: flow, at: Date(timeIntervalSince1970: 100), from: .besir, to: .deliveryPartner,
                                      kind: .delivery, summary: "Delivery for 2 requested", status: .ok)
        let file = makeLog().file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([packet]).write(to: file)
        XCTAssertEqual(ConnectionLog(fileURL: file).packets, [packet])
    }
}
