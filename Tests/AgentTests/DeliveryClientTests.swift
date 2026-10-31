import XCTest
@testable import besir

/// SPEC-DELIVERY-001 AC-DELIVERY-003 and AC-DELIVERY-004: one fixed request per call (the options and the order), only an exact
/// answer is accepted, the total is the one the held options give, and the exchange is drawn as packets that hold fixed words
/// and counts only. Every log is built with a temporary file; the scripted sender is the one the partner client tests use (the
/// function type is the same).
@MainActor
final class DeliveryClientTests: XCTestCase {
    private let token = "delivery-token-0001"
    private let host = "delivery-host.invalid"
    private let flow = UUID()
    private let evening = "2026-11-02T19:40"
    private let late = "2026-11-02T23:30"
    private var config: AppConfig { AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: token) }

    private static let sampleCards = [DeliveryCard(id: "debit-4242", label: "Example Debit \u{2022}\u{2022}4242 (Simulated)"),
                                    DeliveryCard(id: "credit-1881", label: "Example Credit \u{2022}\u{2022}1881 (Simulated)")]

    /// The partner's fixed tables (SPEC-DELIVERY-001 L13) and its order form (SPEC-CHOICECARD-001), as the held options.
    private let options = DeliveryOptions(
        menu: [DeliveryMenuItem(id: "ramen", name: "Ramen", priceCents: 1400),
               DeliveryMenuItem(id: "gyoza", name: "Gyoza", priceCents: 700),
               DeliveryMenuItem(id: "curry", name: "Curry rice", priceCents: 1300),
               DeliveryMenuItem(id: "pizza", name: "Cheese pizza", priceCents: 2500),
               DeliveryMenuItem(id: "salad", name: "Garden salad", priceCents: 900),
               DeliveryMenuItem(id: "lemonade", name: "Lemonade", priceCents: 400)],
        fields: PartnerField.delivery(cards: DeliveryClientTests.sampleCards),
        deliveryFeeCents: 500)
    /// The same prices, written out once more for the tests' own arithmetic.
    private let prices = ["ramen": 1400, "gyoza": 700, "curry": 1300, "pizza": 2500, "salad": 900, "lemonade": 400]

    private struct WriteFailure: Error {}

    // MARK: Helpers

    private func lines(_ pairs: (String, Int)...) -> [DeliveryLine] {
        pairs.map { DeliveryLine(itemID: $0.0, quantity: $0.1) }
    }

    /// Two ramen and one gyoza (4000 cents with the fee) unless a test says otherwise.
    private func request(items: [DeliveryLine]? = nil, arrive: String? = nil, restaurant: String = "Test Cafe",
                         address: String = "12 Example Street", card: String = "debit-4242") -> DeliveryRequest {
        DeliveryRequest(requestID: "3F2B8C1E-5D4A-4E7B-9A60-1C2D3E4F5A6B", restaurant: restaurant, arriveAt: arrive ?? evening,
                        items: items ?? lines(("ramen", 2), ("gyoza", 1)), address: address, cardID: card)
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
        await client(recorder, log: log, config: config).order(sent ?? request(), options: options, flow: flow)
    }

    private func fetchOptions(_ recorder: BookingSendRecorder, log: ConnectionLog? = nil,
                              config: AppConfig? = nil) async -> Result<DeliveryOptions, DeliveryFailure> {
        await client(recorder, log: log, config: config).options(flow: flow)
    }

    private func isOpen(_ time: String) -> Bool {
        guard let hour = Int(time.dropFirst(11).prefix(2)), let minute = Int(time.dropFirst(14).prefix(2)) else { return false }
        return (600...1320).contains(hour * 60 + minute)
    }

    private func json(_ fields: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func total(of sent: DeliveryRequest) -> Int {
        sent.items.reduce(500) { $0 + (prices[$1.itemID] ?? 0) * $1.quantity }
    }

    /// The three result items the Worker sends: the arrival, the estimated total and the status.
    private func resultItems(arrive: String, total: Int) -> [[String: Any]] {
        [["name": "Arrival", "kind": "time", "value": arrive], ["name": "Estimated total", "kind": "money", "value": total],
         ["name": "Status", "kind": "text", "value": "Preparing"]]
    }

    /// The confirmed answer the client returns for those three items.
    private func confirmedAnswer(_ orderID: String = "DL-AB12CD", total: Int = 4000, arrive: String? = nil) -> DeliveryAnswer {
        .confirmed(orderID: orderID, results: [PartnerResultItem(name: "Arrival", value: .time(arrive ?? evening)),
                                               PartnerResultItem(name: "Estimated total", value: .money(total)),
                                               PartnerResultItem(name: "Status", value: .text("Preparing"))])
    }

    /// The order answer the Worker gives to `sent` (the default request when nil); the status follows the hours rule.
    /// `mutate` bends it.
    private func object(_ mutate: (inout [String: Any]) -> Void = { _ in }, for sent: DeliveryRequest? = nil) -> String {
        let sent = sent ?? request()
        let open = isOpen(sent.arriveAt)
        var fields: [String: Any] = ["status": open ? "confirmed" : "declined", "partner": "Example Delivery", "simulated": true,
                                     "restaurant": sent.restaurant, "arrive_at": sent.arriveAt,
                                     "items": sent.items.map { ["item_id": $0.itemID, "quantity": $0.quantity] as [String: Any] },
                                     "address": sent.address, "card_id": sent.cardID]
        if open {
            fields["order_id"] = "DL-AB12CD"
            fields["results"] = resultItems(arrive: sent.arriveAt, total: total(of: sent))
        } else {
            fields["reason"] = "outside_hours"
        }
        mutate(&fields)
        return json(fields)
    }

    private func menuEntry(_ id: String, _ name: String, _ price: Any) -> [String: Any] {
        ["id": id, "name": name, "price_cents": price]
    }

    private func cardEntry(_ id: String, _ label: String) -> [String: Any] {
        ["id": id, "label": label]
    }

    /// The options answer the Worker gives; `mutate` bends it.
    private func optionsObject(_ mutate: (inout [String: Any]) -> Void = { _ in }) -> String {
        var fields: [String: Any] = ["partner": "Example Delivery", "simulated": true,
                                     "menu": options.menu.map { menuEntry($0.id, $0.name, $0.priceCents) },
                                     "order_fields": orderFields(),
                                     "delivery_fee_cents": 500]
        mutate(&fields)
        return json(fields)
    }

    /// An options answer whose menu is `entries` and whose cards and fee are the sample's.
    private func optionsObject(menu entries: [[String: Any]]) -> String { optionsObject { $0["menu"] = entries } }

    private func optionsObject(cards entries: [[String: Any]]) -> String { optionsObject { $0["order_fields"] = orderFields(cards: entries) } }

    /// The delivery partner's field list as the Worker sends it: the arrival, the delivery place and the card.
    private func orderFields(cards entries: [[String: Any]]? = nil) -> [[String: Any]] {
        [["key": "arrive_at", "kind": "time", "label": "Arrival"], ["key": "address", "kind": "place", "label": "Delivery place"],
         ["key": "card_id", "kind": "pick_one", "label": "Pay with",
          "options": entries ?? Self.sampleCards.map { cardEntry($0.id, $0.label) }]]
    }

    /// `count` distinct menu entries with lower-case letter ids.
    private func menuOf(_ count: Int, price: Int = 100) -> [[String: Any]] {
        (0..<count).map { menuEntry(String(UnicodeScalar(UInt8(97 + $0))), "Item \($0)", price) }
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func packetLines(_ log: ConnectionLog) -> [String] {
        log.packets.map { "\($0.from.rawValue)>\($0.to.rawValue) \($0.kind.rawValue) \($0.status.rawValue) \($0.summary)" }
    }

    private func assertOther(_ bodies: [String], sent: DeliveryRequest? = nil, file: StaticString = #filePath,
                             line: UInt = #line) async {
        for text in bodies {
            let result = await order(BookingSendRecorder(body: text), sent)
            XCTAssertEqual(result, .failure(.other), text, file: file, line: line)
        }
    }

    /// The static check of an order answer, called directly.
    private func assertRefused(_ bodies: [String], sent: DeliveryRequest? = nil, file: StaticString = #filePath,
                               line: UInt = #line) {
        for text in bodies {
            XCTAssertNil(DeliveryClient.answer(from: Data(text.utf8), sent: sent ?? request(), options: options), text,
                         file: file, line: line)
        }
    }

    /// The static check of an options answer, called directly.
    private func assertOptionsRefused(_ bodies: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in bodies {
            XCTAssertNil(DeliveryClient.optionsAnswer(from: Data(text.utf8)), text, file: file, line: line)
        }
    }

    // MARK: C01-C03 the order request

    func testC01_OrderRequestIsAPostToDeliveryWithTokenJsonTheSevenKeysAndTwentySeconds() async throws {
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
        XCTAssertEqual(Set(fields.keys), ["op", "request_id", "restaurant", "arrive_at", "items", "address", "card_id"])
        XCTAssertEqual(fields["op"] as? String, "order")
        XCTAssertEqual(fields["request_id"] as? String, request().requestID)
        XCTAssertEqual(fields["restaurant"] as? String, "Test Cafe")
        XCTAssertEqual(fields["arrive_at"] as? String, evening)
        XCTAssertEqual(fields["address"] as? String, "12 Example Street")
        XCTAssertEqual(fields["card_id"] as? String, "debit-4242")
        // The lines go out in the given order, each with exactly two keys.
        let items = try XCTUnwrap(fields["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map { $0["item_id"] as? String }, ["ramen", "gyoza"])
        XCTAssertEqual(items.map { $0["quantity"] as? Int }, [2, 1])
        for line in items { XCTAssertEqual(Set(line.keys), ["item_id", "quantity"]) }
        // A reversed list goes out reversed.
        let reversed = BookingSendRecorder(body: object(for: request(items: lines(("gyoza", 1), ("ramen", 2)))))
        _ = await order(reversed, request(items: lines(("gyoza", 1), ("ramen", 2))))
        let reversedItems = try XCTUnwrap(try body(of: XCTUnwrap(reversed.requests.first))["items"] as? [[String: Any]])
        XCTAssertEqual(reversedItems.map { $0["item_id"] as? String }, ["gyoza", "ramen"])
    }

    func testC02_BodyHoldsNothingPersonalOrFromTheConfigurationAndTheAddressOnlyInItsOwnField() async throws {
        var loud = config
        loud.proxyBaseURL = "https://sentinel-host-777.invalid"
        loud.appToken = "sentinel-token-777"
        loud.kakaoJsKey = "sentinel-kakao-777"
        let sentinel = "88 Addr-Sentinel Lane"
        let sample = request(address: sentinel)
        let recorder = BookingSendRecorder(body: object(for: sample))
        _ = await order(recorder, sample, config: loud)
        let sent = try XCTUnwrap(recorder.requests.first)
        let raw = String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self)
        let fields = try body(of: sent)
        XCTAssertEqual(fields["address"] as? String, sentinel)
        // Without the value of the `address` field the sentinel is nowhere in the body.
        let rest = raw.replacingOccurrences(of: sentinel, with: "").lowercased()
        XCTAssertTrue(raw.contains(sentinel))
        for word in ["sentinel", "addr-", "latitude", "longitude", "coordinate", "timezone", "time_zone", "place_id", "placeid",
                     "origin", "start_place", "location", "phone", "email", "payment", "account", "device", "name\"", "label",
                     "price", "total", "simulated"] {
            XCTAssertFalse(rest.contains(word), "the body holds \(word)")
        }
        // Neither the card's label nor an item's name nor a price goes out: the lines hold ids and quantities only.
        for text in [options.cards[0].label, "Example Debit", "\u{2022}", "Ramen", "1400"] {
            XCTAssertFalse(raw.contains(text), "the body holds \(text)")
        }
        XCTAssertEqual(Set(fields.keys).count, 7)
        // The configuration still reaches the request line and the header, which is where it belongs.
        XCTAssertEqual(sent.url?.host, "sentinel-host-777.invalid")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-besir-token"), "sentinel-token-777")
    }

    func testC03_NoProxyGivesNotSetUpWithoutACallOrAPacketForTheOrder() async {
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

    // MARK: C04-C06, C11, C12 the order answer is checked

    func testC04_AConfirmedAnswerGivesTheOrderIdAndTheRecomputedTotal() async {
        let result = await order(BookingSendRecorder(body: object()))
        XCTAssertEqual(result, .success(confirmedAnswer("DL-AB12CD", total: 4000)))
        // Six lines of nine of the real table: 9 x 7200 + 500.
        let all = lines(("ramen", 9), ("gyoza", 9), ("curry", 9), ("pizza", 9), ("salad", 9), ("lemonade", 9))
        let big = await order(BookingSendRecorder(body: object(for: request(items: all))), request(items: all))
        XCTAssertEqual(big, .success(confirmedAnswer("DL-AB12CD", total: 65300)))
        // A single cheapest item: the fee counts once.
        let single = lines(("lemonade", 1))
        let one = await order(BookingSendRecorder(body: object(for: request(items: single))), request(items: single))
        XCTAssertEqual(one, .success(confirmedAnswer("DL-AB12CD", total: 900)))
    }

    func testC05_ADeclinedAnswerGivesDeclined() async {
        let sample = request(arrive: late)
        let result = await order(BookingSendRecorder(body: object(for: sample)), sample)
        XCTAssertEqual(result, .success(.declined))
    }

    func testC06_AnOrderAnswerThatDeviatesIsOther() async {
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
        confirmed.append(object { $0["arrive_at"] = "2026-11-02T19:41" })
        confirmed.append(object { $0["arrive_at"] = "2026-11-03T19:40" })
        confirmed.append(object { $0["arrive_at"] = 20261102 })
        confirmed.append(object { $0.removeValue(forKey: "arrive_at") })
        confirmed.append(object { $0["address"] = "12 Example Street " })
        confirmed.append(object { $0["address"] = "14 Example Street" })
        confirmed.append(object { $0["address"] = 12 })
        confirmed.append(object { $0.removeValue(forKey: "address") })
        confirmed.append(object { $0["card_id"] = "credit-1881" })
        confirmed.append(object { $0["card_id"] = "Debit-4242" })
        confirmed.append(object { $0["card_id"] = 4242 })
        confirmed.append(object { $0.removeValue(forKey: "card_id") })
        confirmed.append(object { $0["status"] = "pending" })
        confirmed.append(object { $0["status"] = "CONFIRMED" })
        confirmed.append(object { $0["status"] = true })
        confirmed.append(object { $0.removeValue(forKey: "status") })
        // The keys of the former answer are an eleventh key; their absence is not the defect, the list is.
        confirmed.append(object { $0["arrival_estimate"] = "2026-11-02T19:50" })
        confirmed.append(object { $0["arrival_estimate"] = evening })
        confirmed.append(object { $0["estimated_total_cents"] = 4000 })
        confirmed.append(object { $0["estimated_total_cents"] = 4001 })
        confirmed.append(object { $0.removeValue(forKey: "results"); $0["estimated_total_cents"] = 4000 })
        confirmed.append(object { $0.removeValue(forKey: "results"); $0["arrival_estimate"] = evening })
        confirmed.append(object { $0.removeValue(forKey: "results") })
        // The result list: a total off by one cent either way, a time that is not the requested one, a wrong kind of value.
        confirmed.append(object { $0["results"] = resultItems(arrive: evening, total: 4001) })
        confirmed.append(object { $0["results"] = resultItems(arrive: evening, total: 3999) })
        confirmed.append(object { $0["results"] = resultItems(arrive: "2026-11-02T19:41", total: 4000) })
        confirmed.append(object { $0["results"] = resultItems(arrive: "2026-11-03T19:40", total: 4000) })
        confirmed.append(object { $0["results"] = [["name": "Arrival", "kind": "time", "value": evening],
                                                   ["name": "Estimated total", "kind": "money", "value": "4000"]] })
        confirmed.append(object { $0["results"] = [["name": "Arrival", "kind": "time", "value": evening],
                                                   ["name": "Estimated total", "kind": "money", "value": 4000.5]] })
        confirmed.append(object { $0["results"] = [["name": "Arrival", "kind": "time", "value": evening],
                                                   ["name": "Estimated total", "kind": "money", "value": true]] })
        confirmed.append(object { $0["results"] = [["name": "Arrival", "kind": "time", "value": evening],
                                                   ["name": "Estimated total", "kind": "money", "value": 0]] })
        confirmed.append(object { $0["results"] = [["name": "Arrival", "kind": "time", "value": evening]] })
        confirmed.append(object { $0["results"] = [["name": "Estimated total", "kind": "money", "value": 4000]] })
        confirmed.append(object { $0["results"] = [["name": "Status", "kind": "text", "value": "Preparing"]] })
        confirmed.append(object { $0["results"] = [] })
        confirmed.append(object { $0["results"] = "Preparing" })
        confirmed.append(object { $0["results"] = NSNull() })
        confirmed.append(object { $0["results"] = [["name": "Arrival", "kind": "time", "value": "2026-11-02T25:00"],
                                                   ["name": "Estimated total", "kind": "money", "value": 4000]] })
        confirmed.append(object { $0["results"] = resultItems(arrive: evening, total: 4000).map { var item = $0; item["unit"] = "x"; return item } })
        confirmed.append(object { $0["order_id"] = "EX-AB12CD" })
        confirmed.append(object { $0["order_id"] = 123456789 })
        confirmed.append(object { $0.removeValue(forKey: "order_id") })
        confirmed.append(object { $0["reason"] = "outside_hours" })
        confirmed.append(object { $0["extra"] = 1 })
        confirmed.append(object { $0["note"] = NSNull() })
        // The item lines: any difference from what was sent.
        confirmed.append(object { $0["items"] = [["item_id": "ramen", "quantity": 3], ["item_id": "gyoza", "quantity": 1]] })
        confirmed.append(object { $0["items"] = [["item_id": "ramen", "quantity": 2], ["item_id": "gyoza", "quantity": 2]] })
        confirmed.append(object { $0["items"] = [["item_id": "gyoza", "quantity": 1], ["item_id": "ramen", "quantity": 2]] })
        confirmed.append(object { $0["items"] = [["item_id": "ramen", "quantity": 2]] })
        confirmed.append(object { $0["items"] = [["item_id": "ramen", "quantity": 2], ["item_id": "gyoza", "quantity": 1],
                                                 ["item_id": "salad", "quantity": 1]] })
        confirmed.append(object { $0["items"] = [["item_id": "ramen", "quantity": 2], ["item_id": "curry", "quantity": 1]] })
        confirmed.append(object { $0["items"] = [["item_id": "ramen", "quantity": 2], ["item_id": "gyoza", "quantity": 1, "price": 7]] })
        confirmed.append(object { $0["items"] = [["item_id": "ramen", "quantity": 2], ["item_id": "gyoza"]] })
        confirmed.append(object { $0["items"] = [["item_id": "ramen", "quantity": 2], ["item_id": "gyoza", "quantity": "1"]] })
        confirmed.append(object { $0["items"] = [["item_id": "ramen", "quantity": 2], ["item_id": "gyoza", "quantity": true]] })
        confirmed.append(object { $0["items"] = [["item_id": "ramen", "quantity": 2], ["item_id": 5, "quantity": 1]] })
        confirmed.append(object { $0["items"] = ["ramen:2", "gyoza:1"] })
        confirmed.append(object { $0["items"] = [] })
        confirmed.append(object { $0["items"] = "ramen:2,gyoza:1" })
        confirmed.append(object { $0["items"] = NSNull() })
        confirmed.append(object { $0.removeValue(forKey: "items") })
        assertRefused(confirmed)

        // A declined answer for the late request.
        let lateRequest = request(arrive: late)
        var declined: [String] = []
        declined.append(object({ $0["order_id"] = "DL-AB12CD" }, for: lateRequest))
        declined.append(object({ $0["arrival_estimate"] = late }, for: lateRequest))
        declined.append(object({ $0["estimated_total_cents"] = 4000 }, for: lateRequest))
        declined.append(object({ $0["results"] = resultItems(arrive: late, total: 4000) }, for: lateRequest))
        declined.append(object({ $0.removeValue(forKey: "reason") }, for: lateRequest))
        declined.append(object({ $0["reason"] = "no_table" }, for: lateRequest))
        declined.append(object({ $0["reason"] = "closed" }, for: lateRequest))
        declined.append(object({ $0["reason"] = "OUTSIDE_HOURS" }, for: lateRequest))
        declined.append(object({ $0["reason"] = 1 }, for: lateRequest))
        declined.append(object({ $0["extra"] = 1 }, for: lateRequest))
        declined.append(object({ $0["partner"] = "Real Delivery" }, for: lateRequest))
        declined.append(object({ $0["simulated"] = false }, for: lateRequest))
        declined.append(object({ $0["arrive_at"] = "2026-11-02T23:31" }, for: lateRequest))
        declined.append(object({ $0["address"] = "elsewhere" }, for: lateRequest))
        declined.append(object({ $0["card_id"] = "credit-1881" }, for: lateRequest))
        declined.append(object({ $0["items"] = [["item_id": "ramen", "quantity": 1]] }, for: lateRequest))
        assertRefused(declined, sent: lateRequest)

        // The status has to agree with the hours rule, in both directions.
        assertRefused([object({ $0["status"] = "confirmed"; $0["order_id"] = "DL-AB12CD"
                                $0["results"] = resultItems(arrive: late, total: 4000); $0.removeValue(forKey: "reason") }, for: lateRequest)],
                      sent: lateRequest)
        assertRefused([object({ $0["status"] = "declined"; $0["reason"] = "outside_hours"; $0.removeValue(forKey: "order_id")
                                $0.removeValue(forKey: "results") })])
        for time in ["2026-11-02T09:59", "2026-11-02T22:01", "2026-11-02T00:00", "2026-11-02T23:59"] {
            let sample = request(arrive: time)
            assertRefused([object({ $0["status"] = "confirmed"; $0["order_id"] = "DL-AB12CD"
                                    $0["results"] = resultItems(arrive: time, total: 4000); $0.removeValue(forKey: "reason") }, for: sample)],
                          sent: sample)
        }
        for time in ["2026-11-02T10:00", "2026-11-02T22:00", "2026-11-02T12:00"] {
            let sample = request(arrive: time)
            let result = await order(BookingSendRecorder(body: object(for: sample)), sample)
            XCTAssertEqual(result, .success(confirmedAnswer("DL-AB12CD", total: 4000, arrive: time)), time)
        }
        for time in ["2026-11-02T09:59", "2026-11-02T22:01"] {
            let sample = request(arrive: time)
            let result = await order(BookingSendRecorder(body: object(for: sample)), sample)
            XCTAssertEqual(result, .success(.declined), time)
        }

        // A time the client cannot read gives no answer at all.
        for time in ["tomorrow", "2026-11-02 19:40"] {
            let sample = request(arrive: time)
            assertRefused([object({ $0["status"] = "confirmed" }, for: sample), object(for: sample)], sent: sample)
        }

        // A body that is not the object, and a status other than 200.
        await assertOther(["[]", "null", "\"confirmed\"", "5", "", "not json", "{}"])
        for status in [201, 202, 204, 302, 400, 404, 500, 503] {
            let result = await order(BookingSendRecorder(status: status, body: object()))
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }
        // Positive counterpart: the same body at 200 is accepted.
        let accepted = await order(BookingSendRecorder(status: 200, body: object()))
        XCTAssertEqual(accepted, .success(confirmedAnswer("DL-AB12CD", total: 4000)))
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
            let listed = await fetchOptions(BookingSendRecorder(status: status, body: optionsObject { $0["note"] = leak }), log: log)
            guard case .failure(let listFailure) = listed else { return XCTFail("options status \(status) is not a failure") }
            XCTAssertEqual(String(describing: listFailure), "other", "a failure is a bare case")
        }
        await log.flush()
        XCTAssertFalse(packetLines(log).joined().contains(leak))
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

    func testC11_TheAnswerChecksAcceptTwoPointZeroAndRefuseABooleanWhereANumberBelongs() async {
        // The order answer: a quantity and the total written as 2.0 and 4000.0.
        let plain = object()
        XCTAssertTrue(plain.contains("\"quantity\":2}"))
        XCTAssertTrue(plain.contains("\"value\":4000}"))
        let floating = plain.replacingOccurrences(of: "\"quantity\":2}", with: "\"quantity\":2.0}")
            .replacingOccurrences(of: "\"value\":4000}", with: "\"value\":4000.0}")
        XCTAssertTrue(floating.contains("\"quantity\":2.0}"))
        XCTAssertTrue(floating.contains("\"value\":4000.0}"))
        let accepted = await order(BookingSendRecorder(body: floating))
        XCTAssertEqual(accepted, .success(confirmedAnswer("DL-AB12CD", total: 4000)))

        assertRefused([
            object { $0["results"] = resultItems(arrive: evening, total: 4000).map { item in
                var changed = item
                if item["kind"] as? String == "money" { changed["value"] = true }
                return changed } },
            object { $0["items"] = [["item_id": "ramen", "quantity": true], ["item_id": "gyoza", "quantity": 1]] },
            plain.replacingOccurrences(of: "\"quantity\":2}", with: "\"quantity\":2.5}"),
            plain.replacingOccurrences(of: "\"value\":4000}", with: "\"value\":4000.5}"),
        ])
        // A single line of quantity 1 is not read as `true`, and a total of 900 is not read as `true`.
        let one = request(items: lines(("ramen", 1)))
        assertRefused([object({ $0["items"] = [["item_id": "ramen", "quantity": true]] }, for: one),
                       object({ $0["results"] = [["name": "Arrival", "kind": "time", "value": evening],
                                                 ["name": "Estimated total", "kind": "money", "value": true]] }, for: one)], sent: one)

        // The options answer: a price and the fee written as 1400.0 and 500.0.
        let optionsText = optionsObject()
        XCTAssertTrue(optionsText.contains("\"price_cents\":1400}"))
        XCTAssertTrue(optionsText.contains("\"delivery_fee_cents\":500,"))
        let floatingOptions = optionsText.replacingOccurrences(of: "\"price_cents\":1400}", with: "\"price_cents\":1400.0}")
            .replacingOccurrences(of: "\"delivery_fee_cents\":500,", with: "\"delivery_fee_cents\":500.0,")
        XCTAssertTrue(floatingOptions.contains("\"price_cents\":1400.0}"))
        XCTAssertEqual(DeliveryClient.optionsAnswer(from: Data(floatingOptions.utf8)), self.options)
        assertOptionsRefused([
            optionsText.replacingOccurrences(of: "\"price_cents\":1400}", with: "\"price_cents\":1400.5}"),
            optionsText.replacingOccurrences(of: "\"price_cents\":1400}", with: "\"price_cents\":true}"),
            optionsText.replacingOccurrences(of: "\"delivery_fee_cents\":500,", with: "\"delivery_fee_cents\":500.5,"),
            optionsObject { $0["delivery_fee_cents"] = true },
        ])
    }

    func testC12_TheOrderIdIsDLAndSixOfUpperCaseAsciiLettersAndDigits() async {
        let valid = await order(BookingSendRecorder(body: object { $0["order_id"] = "DL-Z9Y8X7" }))
        XCTAssertEqual(valid, .success(confirmedAnswer("DL-Z9Y8X7", total: 4000)))
        let digits = await order(BookingSendRecorder(body: object { $0["order_id"] = "DL-012345" }))
        XCTAssertEqual(digits, .success(confirmedAnswer("DL-012345", total: 4000)))
        var bodies: [String] = []
        for id in ["DL-ab12cd", "DL-AB12Cd", "DL-AB12C", "DL-AB12CDE", "dl-AB12CD", "EX-AB12CD", "XX-AB12CD", "DL-AB12C\n",
                   "DL-AB 2CD", "DL-ÀB12CD", "DL-AB\u{0661}\u{0662}CD", "DL\u{2010}AB12CD", "DLAB12CDX", "DL-", ""] {
            bodies.append(object { $0["order_id"] = id })
        }
        assertRefused(bodies)
    }

    func testC13_TheClientNeverReadsOrWritesTheBudgetLedgerOrTheOrderRecord() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-ledger-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(BudgetLedger.fileName)
        let ledger = BudgetLedger(fileURL: file)
        XCTAssertTrue(ledger.add(BudgetEntry(requestID: "ledger-entry-1", weekStart: "2026-11-02", amountCents: 1850, isEstimate: false)))
        let before = try Data(contentsOf: file)
        XCTAssertFalse(before.isEmpty)
        // A file of the order record's name next to it, written by hand: the client does not know the type.
        let recordName = "delivery-orders.json"
        let record = folder.appendingPathComponent(recordName)
        try Data("[]".utf8).write(to: record)
        let recordBefore = try Data(contentsOf: record)
        let shared = AppConfig.supportDirectory.appendingPathComponent(BudgetLedger.fileName)
        let sharedBefore = try? Data(contentsOf: shared)
        let sharedRecord = AppConfig.supportDirectory.appendingPathComponent(recordName)
        let sharedRecordBefore = try? Data(contentsOf: sharedRecord)

        let (log, _) = makeLog()
        let listed = await fetchOptions(BookingSendRecorder(body: optionsObject()), log: log)
        let confirmed = await order(BookingSendRecorder(body: object()), log: log)
        let lateRequest = request(arrive: late)
        let declined = await order(BookingSendRecorder(body: object(for: lateRequest)), lateRequest, log: log)
        let failed = await order(BookingSendRecorder(status: 500, body: "oops"), log: log)
        XCTAssertEqual(listed, .success(options))
        XCTAssertEqual(confirmed, .success(confirmedAnswer("DL-AB12CD", total: 4000)))
        XCTAssertEqual(declined, .success(.declined))
        XCTAssertEqual(failed, .failure(.other))

        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try Data(contentsOf: record), recordBefore)
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-11-02"), 1850)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), [BudgetLedger.fileName, recordName])
        XCTAssertEqual(try? Data(contentsOf: shared), sharedBefore)
        XCTAssertEqual(try? Data(contentsOf: sharedRecord), sharedRecordBefore)
        XCTAssertFalse(BudgetLedger.shared.contains(requestID: request().requestID))
    }

    // MARK: C14-C16 the options call and the total rule

    func testC14_TheOptionsRequestIsAPostWithTheBodyOpOptionsAndTwentySeconds() async throws {
        let recorder = BookingSendRecorder(body: optionsObject())
        let (log, _) = makeLog()
        _ = await fetchOptions(recorder, log: log)
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/delivery")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-besir-token"), token)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.timeoutInterval, 20)
        XCTAssertEqual(String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self), #"{"op":"options"}"#)

        // No proxy: nothing is sent and no packet is recorded.
        let (quiet, _) = makeLog()
        for blank in [AppConfig(), AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: ""),
                      AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: token)] {
            let none = BookingSendRecorder(body: optionsObject())
            let result = await fetchOptions(none, log: quiet, config: blank)
            XCTAssertEqual(result, .failure(.notSetUp))
            XCTAssertTrue(none.requests.isEmpty)
        }
        await quiet.flush()
        XCTAssertTrue(quiet.packets.isEmpty)
    }

    func testC15_TheOptionsAnswerIsCheckedAndEachDeviationIsOther() async {
        let result = await fetchOptions(BookingSendRecorder(body: optionsObject()))
        XCTAssertEqual(result, .success(options))
        XCTAssertEqual(DeliveryClient.optionsAnswer(from: Data(optionsObject().utf8)), options)

        var bodies: [String] = []
        bodies.append(optionsObject { $0["partner"] = "Real Delivery" })
        bodies.append(optionsObject { $0["partner"] = "example delivery" })
        bodies.append(optionsObject { $0.removeValue(forKey: "partner") })
        bodies.append(optionsObject { $0["partner"] = 5 })
        bodies.append(optionsObject { $0["simulated"] = false })
        bodies.append(optionsObject { $0.removeValue(forKey: "simulated") })
        bodies.append(optionsObject { $0["simulated"] = "true" })
        bodies.append(optionsObject { $0["simulated"] = 1 })
        bodies.append(optionsObject { $0["extra"] = 1 })
        bodies.append(optionsObject { $0["status"] = "ok" })
        bodies.append(optionsObject { $0["cards"] = options.cards.map { cardEntry($0.id, $0.label) } })
        for key in ["menu", "order_fields", "delivery_fee_cents"] { bodies.append(optionsObject { $0.removeValue(forKey: key) }) }
        // The menu.
        bodies.append(optionsObject(menu: []))
        bodies.append(optionsObject(menu: menuOf(13)))
        bodies.append(optionsObject(menu: [menuEntry("ramen", "Ramen", 1400), menuEntry("ramen", "Ramen two", 1500)]))
        bodies.append(optionsObject(menu: [menuEntry("Ramen", "Ramen", 1400)]))
        bodies.append(optionsObject(menu: [menuEntry("", "Ramen", 1400)]))
        bodies.append(optionsObject(menu: [menuEntry("ram\u{00E9}n", "Ramen", 1400)]))
        bodies.append(optionsObject(menu: [menuEntry("ra men", "Ramen", 1400)]))
        bodies.append(optionsObject(menu: [menuEntry("ramen:2", "Ramen", 1400)]))
        bodies.append(optionsObject(menu: [menuEntry("ramen,gyoza", "Ramen", 1400)]))
        bodies.append(optionsObject(menu: [["id": 5, "name": "Ramen", "price_cents": 1400]]))
        bodies.append(optionsObject(menu: [menuEntry("ramen", "Ramen", 0)]))
        bodies.append(optionsObject(menu: [menuEntry("ramen", "Ramen", -5)]))
        bodies.append(optionsObject(menu: [menuEntry("ramen", "Ramen", 100001)]))
        bodies.append(optionsObject(menu: [menuEntry("ramen", "Ramen", 14.5)]))
        bodies.append(optionsObject(menu: [["id": "ramen", "name": "Ramen", "price_cents": "1400"]]))
        bodies.append(optionsObject(menu: [["id": "ramen", "name": "Ramen", "price_cents": true]]))
        bodies.append(optionsObject(menu: [menuEntry("ramen", "R\u{00E4}men", 1400)]))
        bodies.append(optionsObject(menu: [menuEntry("ramen", "Ra\nmen", 1400)]))
        bodies.append(optionsObject(menu: [menuEntry("ramen", "", 1400)]))
        bodies.append(optionsObject(menu: [menuEntry("ramen", String(repeating: "R", count: 41), 1400)]))
        bodies.append(optionsObject(menu: [["id": "ramen", "name": 5, "price_cents": 1400]]))
        bodies.append(optionsObject(menu: [["id": "ramen", "name": "Ramen", "price_cents": 1400, "kind": "soup"]]))
        bodies.append(optionsObject(menu: [["id": "ramen", "name": "Ramen"]]))
        bodies.append(optionsObject(menu: [["id": "ramen", "price_cents": 1400]]))
        bodies.append(optionsObject(menu: [["name": "Ramen", "price_cents": 1400]]))
        bodies.append(optionsObject { $0["menu"] = ["ramen"] })
        bodies.append(optionsObject { $0["menu"] = "ramen" })
        bodies.append(optionsObject { $0["menu"] = NSNull() })
        // The cards.
        bodies.append(optionsObject(cards: []))
        bodies.append(optionsObject(cards: [cardEntry("debit-4242", "A (Simulated)"), cardEntry("debit-4242", "B (Simulated)")]))
        bodies.append(optionsObject(cards: [cardEntry("", "Example Debit (Simulated)")]))
        bodies.append(optionsObject(cards: [cardEntry("debit-4242", "")]))
        bodies.append(optionsObject(cards: [cardEntry("debit-4242", "Example\tDebit (Simulated)")]))
        bodies.append(optionsObject(cards: [cardEntry("debit-4242", "Example\u{200B}Debit (Simulated)")]))
        bodies.append(optionsObject(cards: [cardEntry("debit-4242", "Example\u{2028}Debit (Simulated)")]))
        bodies.append(optionsObject(cards: [cardEntry("debit-4242", String(repeating: "L", count: 61))]))
        bodies.append(optionsObject(cards: [["id": "debit-4242", "label": 5]]))
        bodies.append(optionsObject(cards: [["id": 5, "label": "Example Debit (Simulated)"]]))
        bodies.append(optionsObject(cards: [["id": "debit-4242", "label": "Example Debit (Simulated)", "number": "4242"]]))
        bodies.append(optionsObject(cards: [["id": "debit-4242"]]))
        bodies.append(optionsObject(cards: [["label": "Example Debit (Simulated)"]]))
        bodies.append(optionsObject { $0["order_fields"] = "debit-4242" })
        bodies.append(optionsObject { $0["order_fields"] = NSNull() })
        bodies.append(optionsObject { $0["order_fields"] = [] })
        // The fee.
        for fee: Any in [-1, 10001, 5.5, "500", true, NSNull()] { bodies.append(optionsObject { $0["delivery_fee_cents"] = fee }) }
        // A body that is not the object.
        bodies.append(contentsOf: ["[]", "null", "\"options\"", "5", "", "not json", "{}"])
        assertOptionsRefused(bodies)

        // Each of the same bodies is `other` through the client too, and so is a status other than 200.
        for text in bodies.prefix(12) {
            let viaClient = await fetchOptions(BookingSendRecorder(body: text))
            XCTAssertEqual(viaClient, .failure(.other), text)
        }
        for status in [201, 202, 204, 302, 400, 503] {
            let other = await fetchOptions(BookingSendRecorder(status: status, body: optionsObject()))
            XCTAssertEqual(other, .failure(.other), "status \(status)")
        }
        let own = await fetchOptions(BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#))
        XCTAssertEqual(own, .failure(.tokenRejected))
        let foreign = await fetchOptions(BookingSendRecorder(status: 401, body: #"{"error":"nope"}"#))
        XCTAssertEqual(foreign, .failure(.other))
        for status in [404, 500] {
            let result = await fetchOptions(BookingSendRecorder(status: status, body: #"{"error":"not_found"}"#))
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }
        let offline = await fetchOptions(BookingSendRecorder(error: URLError(.notConnectedToInternet)))
        XCTAssertEqual(offline, .failure(.offline))
        let timedOut = await fetchOptions(BookingSendRecorder(error: URLError(.timedOut)))
        XCTAssertEqual(timedOut, .failure(.other))

        // The edges are accepted.
        let widest = optionsObject {
            $0["menu"] = menuOf(12, price: 100000)
            $0["order_fields"] = orderFields(cards: (0..<4).map { cardEntry("card\($0)", String(repeating: "L", count: 60)) })
            $0["delivery_fee_cents"] = 10000
        }
        let edge = DeliveryClient.optionsAnswer(from: Data(widest.utf8))
        XCTAssertEqual(edge?.menu.count, 12)
        XCTAssertEqual(edge?.menu.first?.priceCents, 100000)
        XCTAssertEqual(edge?.cards.count, 4)
        XCTAssertEqual(edge?.deliveryFeeCents, 10000)
        let narrowest = optionsObject {
            $0["menu"] = [menuEntry("a", String(repeating: "N", count: 40), 1)]
            $0["order_fields"] = orderFields(cards: [cardEntry("c", "L")])
            $0["delivery_fee_cents"] = 0
        }
        XCTAssertEqual(DeliveryClient.optionsAnswer(from: Data(narrowest.utf8)),
                       DeliveryOptions(menu: [DeliveryMenuItem(id: "a", name: String(repeating: "N", count: 40), priceCents: 1)],
                                       fields: PartnerField.delivery(cards: [DeliveryCard(id: "c", label: "L")]), deliveryFeeCents: 0))
    }

    func testC16_TheTotalRuleOfTheOptionsAndAnOrderOfUnheldIdsIsNotSent() async {
        // The sum of price times quantity plus the fee, the fee counted once.
        XCTAssertEqual(options.totalCents(for: lines(("ramen", 2), ("gyoza", 1))), 4000)
        XCTAssertEqual(options.totalCents(for: lines(("lemonade", 1))), 900)
        XCTAssertEqual(options.totalCents(for: lines(("pizza", 1))), 3000)
        XCTAssertEqual(options.totalCents(for: lines(("ramen", 9), ("gyoza", 9), ("curry", 9), ("pizza", 9), ("salad", 9), ("lemonade", 9))), 65300)
        let letters = (0..<8).map { String(UnicodeScalar(UInt8(97 + $0))) }
        let flat = DeliveryOptions(menu: letters.prefix(6).map { DeliveryMenuItem(id: $0, name: "N", priceCents: 2500) },
                                   fields: PartnerField.delivery(cards: [DeliveryCard(id: "c", label: "L")]), deliveryFeeCents: 500)
        XCTAssertEqual(flat.totalCents(for: letters.prefix(6).map { DeliveryLine(itemID: $0, quantity: 9) }), 135500)
        // Refused: no lines, 7 lines, a repeated id, an unknown id, a quantity outside 1 to 9.
        let wide = DeliveryOptions(menu: letters.map { DeliveryMenuItem(id: $0, name: "N", priceCents: 100) },
                                   fields: PartnerField.delivery(cards: [DeliveryCard(id: "c", label: "L")]), deliveryFeeCents: 500)
        XCTAssertEqual(wide.totalCents(for: letters.prefix(6).map { DeliveryLine(itemID: $0, quantity: 1) }), 1100)
        XCTAssertNil(wide.totalCents(for: letters.prefix(7).map { DeliveryLine(itemID: $0, quantity: 1) }))
        XCTAssertNil(options.totalCents(for: []))
        XCTAssertNil(options.totalCents(for: lines(("ramen", 1), ("ramen", 1))))
        XCTAssertNil(options.totalCents(for: lines(("sushi", 1))))
        XCTAssertNil(options.totalCents(for: lines(("Ramen", 1))))
        for quantity in [0, 10, -1, 99] { XCTAssertNil(options.totalCents(for: lines(("ramen", quantity))), "\(quantity)") }
        for quantity in 1...9 { XCTAssertEqual(options.totalCents(for: lines(("ramen", quantity))), 1400 * quantity + 500) }
        // The lookups by id.
        XCTAssertEqual(options.menuItem(id: "ramen"), DeliveryMenuItem(id: "ramen", name: "Ramen", priceCents: 1400))
        XCTAssertNil(options.menuItem(id: "sushi"))
        XCTAssertEqual(options.card(id: "credit-1881")?.label, "Example Credit \u{2022}\u{2022}1881 (Simulated)")
        XCTAssertNil(options.card(id: "debit"))

        // An order naming an item or a card the options do not hold, or lines the options cannot total, is not sent.
        let (log, _) = makeLog()
        let refused: [DeliveryRequest] = [request(items: lines(("sushi", 1))), request(card: "gold-0001"), request(card: "Debit-4242"),
                                          request(items: lines(("ramen", 10))), request(items: lines(("ramen", 0))),
                                          request(items: lines(("ramen", 1), ("ramen", 1))), request(items: [])]
        for sample in refused {
            let recorder = BookingSendRecorder(body: object(for: request()))
            let result = await order(recorder, sample, log: log)
            XCTAssertEqual(result, .failure(.other), "\(sample)")
            XCTAssertTrue(recorder.requests.isEmpty, "\(sample)")
        }
        await log.flush()
        XCTAssertTrue(log.packets.isEmpty)
        // Positive counterpart: the sample request is sent.
        let sent = BookingSendRecorder(body: object())
        let accepted = await order(sent, log: log)
        XCTAssertEqual(accepted, .success(confirmedAnswer("DL-AB12CD", total: 4000)))
        XCTAssertEqual(sent.requests.count, 1)
    }

    // MARK: C17-C18 the field list and the result list of the delivery adapter

    func testC17_TheAdapterRuleAcceptsOnlyTheThreeKnownFieldsInAnyOrderAndRefusesTheRest() async throws {
        // Positive first: the partner's list decodes to the held options, fields in the partner's order.
        let usual = try XCTUnwrap(DeliveryClient.optionsAnswer(from: Data(optionsObject().utf8)))
        XCTAssertEqual(usual, options)
        XCTAssertEqual(usual.fields.map(\.key), ["arrive_at", "address", "card_id"])
        XCTAssertEqual(usual.cards.map(\.id), ["debit-4242", "credit-1881"])
        XCTAssertEqual(usual.cards.map(\.label), Self.sampleCards.map(\.label))

        // A reordered list is accepted and the partner's order is kept; so is a relabelled one with other cards.
        let reordered = optionsObject {
            let all = orderFields()
            $0["order_fields"] = [all[2], all[0], all[1]]
        }
        let reorderedOptions = try XCTUnwrap(DeliveryClient.optionsAnswer(from: Data(reordered.utf8)))
        XCTAssertEqual(reorderedOptions.fields.map(\.key), ["card_id", "arrive_at", "address"])
        XCTAssertEqual(reorderedOptions.cards, usual.cards)
        let relabelled = optionsObject {
            $0["order_fields"] = [["key": "arrive_at", "kind": "time", "label": "When"], ["key": "address", "kind": "place", "label": "Where to"],
                                  ["key": "card_id", "kind": "pick_one", "label": "Card",
                                   "options": [cardEntry("gold-1", "Example Gold (Simulated)")]]]
        }
        let relabelledOptions = try XCTUnwrap(DeliveryClient.optionsAnswer(from: Data(relabelled.utf8)))
        XCTAssertEqual(relabelledOptions.fields.map(\.label), ["When", "Where to", "Card"])
        XCTAssertEqual(relabelledOptions.cards, [DeliveryCard(id: "gold-1", label: "Example Gold (Simulated)")])
        XCTAssertEqual(relabelledOptions.card(id: "gold-1")?.label, "Example Gold (Simulated)")

        let arrive: [String: Any] = ["key": "arrive_at", "kind": "time", "label": "Arrival"]
        let address: [String: Any] = ["key": "address", "kind": "place", "label": "Delivery place"]
        let card: [String: Any] = ["key": "card_id", "kind": "pick_one", "label": "Pay with", "options": [cardEntry("debit-4242", "Example Debit (Simulated)")]]
        let onOff: (String) -> [String: Any] = { key in
            ["key": key, "kind": "on_off", "label": "Leave at door", "options": [self.cardEntry("true", "Leave"), self.cardEntry("false", "Hand over")]]
        }
        let note: [String: Any] = ["key": "note", "kind": "text", "label": "Note"]
        func listed(_ fields: [[String: Any]]) -> String { optionsObject { $0["order_fields"] = fields } }
        var bodies: [String] = [
            // An unknown key (a well-formed text field), a missing key of each of the three, a known key of the wrong kind.
            listed([arrive, address, card, note]), listed([arrive, card]), listed([address, card]), listed([arrive, address]), listed([]),
            listed([["key": "arrive_at", "kind": "place", "label": "Arrival"], address, card]),
            listed([["key": "arrive_at", "kind": "text", "label": "Arrival"], address, card]),
            listed([arrive, ["key": "address", "kind": "text", "label": "Delivery place"], card]),
            listed([arrive, ["key": "address", "kind": "time", "label": "Delivery place"], card]),
            listed([arrive, address, ["key": "card_id", "kind": "text", "label": "Pay with"]]),
            listed([arrive, address, ["key": "card_id", "kind": "place", "label": "Pay with"]]),
            // A duplicate key, and a key outside the three in place of one of them.
            listed([arrive, arrive, address, card]), listed([arrive, address, card, card]),
            listed([arrive, address, ["key": "payment", "kind": "pick_one", "label": "Pay with", "options": [cardEntry("debit-4242", "Example Debit (Simulated)")]]]),
            listed([["key": "when", "kind": "time", "label": "Arrival"], address, card]),
            // An on_off field is refused for the delivery partner, well-formed or not, whatever its key.
            listed([arrive, address, card, onOff("leave_at_door")]), listed([arrive, address, onOff("card_id")]),
            listed([onOff("arrive_at"), address, card]), listed([arrive, onOff("address"), card]),
            listed([arrive, address, card, ["key": "door", "kind": "on_off", "label": "Door"]]),
            // The shapes of the former answers: the former five keys, four keys, six keys, a top-level cards.
            optionsObject { $0.removeValue(forKey: "order_fields"); $0["cards"] = options.cards.map { cardEntry($0.id, $0.label) } },
            optionsObject { $0.removeValue(forKey: "delivery_fee_cents") },
            optionsObject { $0["cards"] = options.cards.map { cardEntry($0.id, $0.label) } },
            optionsObject { $0.removeValue(forKey: "order_fields") },
            optionsObject { $0["order_fields"] = options.cards.map { cardEntry($0.id, $0.label) } },
        ]
        // The same list with the pick_one options of the card field defective.
        bodies.append(listed([arrive, address, ["key": "card_id", "kind": "pick_one", "label": "Pay with", "options": []]]))
        assertOptionsRefused(bodies)
        // Each refusal is `other` through the client too.
        for text in bodies.prefix(6) {
            let viaClient = await fetchOptions(BookingSendRecorder(body: text))
            XCTAssertEqual(viaClient, .failure(.other), text)
        }
    }

    func testC18_TheConfirmedAnswerIsReadByKindAndOnlyTheExactAdapterShapeIsRecorded() async throws {
        // Positive first: the three items are accepted, and so is an extra text item.
        let plain = await order(BookingSendRecorder(body: object()))
        XCTAssertEqual(plain, .success(confirmedAnswer("DL-AB12CD", total: 4000)))
        let withExtra = object { $0["results"] = resultItems(arrive: evening, total: 4000) + [["name": "Courier", "kind": "text", "value": "Sam"]] }
        let extra = await order(BookingSendRecorder(body: withExtra))
        guard case .success(.confirmed(let orderID, let results)) = extra else { return XCTFail("an extra text item is accepted") }
        XCTAssertEqual(orderID, "DL-AB12CD")
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results.moneyCents, 4000)
        XCTAssertEqual(results.arrival, evening)
        XCTAssertEqual(results.last, PartnerResultItem(name: "Courier", value: .text("Sam")))
        // The order of the items is the partner's, and the money item is not tied to a name: the kind decides.
        let renamed = object { $0["results"] = [["name": "Status", "kind": "text", "value": "Preparing"],
                                                ["name": "Total due", "kind": "money", "value": 4000],
                                                ["name": "ETA", "kind": "time", "value": evening]] }
        let byKind = await order(BookingSendRecorder(body: renamed))
        guard case .success(.confirmed(_, let renamedResults)) = byKind else { return XCTFail("the kind decides, not the name") }
        XCTAssertEqual(renamedResults.moneyCents, 4000)
        XCTAssertEqual(renamedResults.arrival, evening)

        let three = resultItems(arrive: evening, total: 4000)
        let refused: [String] = [
            object { $0["results"] = three + [["name": "Tip", "kind": "money", "value": 300]] },
            object { $0["results"] = three + [["name": "Ready", "kind": "time", "value": evening]] },
            object { $0["results"] = three + [["name": "Total", "kind": "money", "value": 4000]] },
            object { $0["results"] = resultItems(arrive: "2026-11-02T19:41", total: 4000) },
            object { $0["results"] = resultItems(arrive: evening, total: 4001) },
            object { $0["results"] = resultItems(arrive: evening, total: 3999) },
            object { $0["results"] = [["name": "Estimated total", "kind": "money", "value": 4000], ["name": "Status", "kind": "text", "value": "Preparing"]] },
            object { $0["results"] = [["name": "Arrival", "kind": "time", "value": evening], ["name": "Status", "kind": "text", "value": "Preparing"]] },
            object { $0["results"] = [["name": "Status", "kind": "text", "value": "Preparing"]] },
            object { $0.removeValue(forKey: "results"); $0["arrival_estimate"] = evening; $0["estimated_total_cents"] = 4000 },
            object { $0["arrival_estimate"] = evening; $0["estimated_total_cents"] = 4000 },
        ]
        assertRefused(refused)
        // Through the client a refused answer is `other` and records one failure packet, never an order.
        for text in refused {
            let (log, _) = makeLog()
            let result = await order(BookingSendRecorder(body: text), log: log)
            XCTAssertEqual(result, .failure(.other), text)
            await log.flush()
            XCTAssertEqual(packetLines(log), ["besir>deliveryPartner delivery failed Request failed"], text)
        }
        // The total is the held menu's: one more line in the request moves the expected total with it.
        let two = request(items: lines(("lemonade", 1), ("pizza", 1)))
        let moved = await order(BookingSendRecorder(body: object(for: two)), two)
        XCTAssertEqual(moved, .success(confirmedAnswer("DL-AB12CD", total: 3400)))
        let stale = await order(BookingSendRecorder(body: object({ $0["results"] = resultItems(arrive: evening, total: 4000) }, for: two)), two)
        XCTAssertEqual(stale, .failure(.other))
    }

    // MARK: C19 the delivery adapter stays closed to the booking grammar

    func testC19_AnOptionsAnswerWithAnOptionalFieldOrANumberFieldIsRefused() async {
        // Positive first: the valid options answer decodes.
        XCTAssertEqual(DeliveryClient.optionsAnswer(from: Data(optionsObject().utf8)), options)

        // `optional: true` on each of the three known fields, alone and together, makes the whole answer unusable. The reader
        // accepts the marker, so only the adapter rule refuses it: this part is red between the reader change and the adapter change.
        let arrive: [String: Any] = ["key": "arrive_at", "kind": "time", "label": "Arrival"]
        let address: [String: Any] = ["key": "address", "kind": "place", "label": "Delivery place"]
        let card = orderFields()[2]
        func marked(_ field: [String: Any]) -> [String: Any] { field.merging(["optional": true]) { _, new in new } }
        func listed(_ fields: [[String: Any]]) -> String { optionsObject { $0["order_fields"] = fields } }
        let optionalBodies = [
            listed([marked(arrive), address, card]), listed([arrive, marked(address), card]), listed([arrive, address, marked(card)]),
            listed([marked(arrive), marked(address), marked(card)]),
        ]
        assertOptionsRefused(optionalBodies)

        // A field of kind `number` on each known key makes it unusable. This part is green throughout: the adapter's kind map
        // (`knownFields[$0.key] == $0.kind`) already fails a `number` field on a known key.
        func number(_ key: String, _ label: String) -> [String: Any] { ["key": key, "kind": "number", "label": label] }
        let numberBodies = [
            listed([number("arrive_at", "Arrival"), address, card]), listed([arrive, number("address", "Delivery place"), card]),
            listed([arrive, address, number("card_id", "Pay with")]),
        ]
        assertOptionsRefused(numberBodies)

        // Each refusal is `other` through the client too.
        for text in optionalBodies + numberBodies {
            let viaClient = await fetchOptions(BookingSendRecorder(body: text))
            XCTAssertEqual(viaClient, .failure(.other), text)
        }
    }

    // MARK: P01-P06 the order packets

    func testP01_AConfirmationRecordsTwoPacketsInOrderWithOneFlow() async {
        let (log, _) = makeLog()
        _ = await order(BookingSendRecorder(body: object()), log: log)
        await log.flush()
        XCTAssertEqual(packetLines(log), ["besir>deliveryPartner delivery ok Delivery of 3 items requested",
                                          "deliveryPartner>besir delivery ok Order confirmed"])
        XCTAssertEqual(log.packets.map(\.flowID), [flow, flow])

        // One item in all: the singular.
        let single = request(items: lines(("ramen", 1)))
        let (singleLog, _) = makeLog()
        _ = await order(BookingSendRecorder(body: object(for: single)), single, log: singleLog)
        await singleLog.flush()
        XCTAssertEqual(packetLines(singleLog), ["besir>deliveryPartner delivery ok Delivery of 1 item requested",
                                                "deliveryPartner>besir delivery ok Order confirmed"])
        // The count is the total quantity, not the number of lines.
        let nine = request(items: lines(("ramen", 9)))
        let (nineLog, _) = makeLog()
        _ = await order(BookingSendRecorder(body: object(for: nine)), nine, log: nineLog)
        await nineLog.flush()
        XCTAssertEqual(nineLog.packets.first?.summary, "Delivery of 9 items requested")
    }

    func testP02_ADeclineRecordsOrderNotAvailableAsDeclined() async {
        let (log, _) = makeLog()
        let sample = request(arrive: late)
        let result = await order(BookingSendRecorder(body: object(for: sample)), sample, log: log)
        XCTAssertEqual(result, .success(.declined))
        await log.flush()
        XCTAssertEqual(packetLines(log), ["besir>deliveryPartner delivery ok Delivery of 3 items requested",
                                          "deliveryPartner>besir delivery declined Order not available"])
        XCTAssertEqual(log.packets.map(\.flowID), [flow, flow])
    }

    func testP03_AFailureRecordsOneRequestFailedPacketAndNothingAfterIt() async {
        let failures: [BookingSendRecorder] = [BookingSendRecorder(error: URLError(.notConnectedToInternet)),
                                               BookingSendRecorder(status: 404, body: "{}"),
                                               BookingSendRecorder(status: 500, body: "oops"),
                                               BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#),
                                               BookingSendRecorder(body: "[]"),
                                               BookingSendRecorder(body: object { $0["partner"] = "Real Delivery" }),
                                               BookingSendRecorder(body: object { $0["results"] = resultItems(arrive: evening, total: 4001) })]
        for recorder in failures {
            let (log, _) = makeLog()
            _ = await order(recorder, log: log)
            await log.flush()
            XCTAssertEqual(packetLines(log), ["besir>deliveryPartner delivery failed Request failed"])
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

    func testP05_NoSummaryHoldsAPlaceATimeAnAddressAnItemTheCardTheOrderIdAMoneySignOrAnyAnswerText() async throws {
        let place = "Pasta Palace Unique"
        let address = "4471 Sentinel Avenue"
        let specific = request(items: lines(("ramen", 4), ("gyoza", 3)), arrive: evening, restaurant: place, address: address,
                               card: "credit-1881")
        let reply = object({ $0["order_id"] = "DL-QX7Z9K" }, for: specific)
        let recorder = BookingSendRecorder(body: reply)
        let (log, file) = makeLog()
        let result = await client(recorder, log: log).order(specific, options: options, flow: flow)
        // The name, the time, the address, the lines, the card, the id and the total exist in the request or the answer, so the
        // checks below can fail.
        let sent = String(decoding: try XCTUnwrap(recorder.requests.first?.httpBody), as: UTF8.self)
        for present in [place, evening, address, "ramen", "gyoza", "credit-1881"] { XCTAssertTrue(sent.contains(present), present) }
        XCTAssertTrue(reply.contains("DL-QX7Z9K"))
        XCTAssertTrue(reply.contains("8200"))
        XCTAssertEqual(result, .success(confirmedAnswer("DL-QX7Z9K", total: 8200)))
        await log.flush()
        let stored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(stored.contains("Delivery of 7 items requested"))
        for secret in [place, "Pasta", evening, "19:40", "7:40", address, "Sentinel", "ramen", "Ramen", "gyoza", "Gyoza", "credit-1881",
                       "Example Credit", "DL-QX7Z9K", "QX7Z9K", "$", token, host, specific.requestID] {
            XCTAssertFalse(stored.contains(secret), "connections.json holds \(secret)")
        }
        let summaries = log.packets.map(\.summary)
        XCTAssertEqual(summaries.count, 2)
        for summary in summaries {
            XCTAssertFalse(summary.contains("$"))
            XCTAssertTrue(summary.unicodeScalars.allSatisfy { $0.isASCII })
        }
        // The only digit is the total quantity.
        XCTAssertEqual(summaries.map { $0.filter(\.isNumber) }, ["7", ""])
    }

    func testP06_ALogThatCannotWriteChangesNoResult() async {
        let lateRequest = request(arrive: late)
        let cases: [(BookingSendRecorder, DeliveryRequest)] = [
            (BookingSendRecorder(body: object()), request()),
            (BookingSendRecorder(body: object(for: lateRequest)), lateRequest),
            (BookingSendRecorder(status: 500, body: "oops"), request()),
            (BookingSendRecorder(error: URLError(.notConnectedToInternet)), request()),
        ]
        for (recorder, sent) in cases {
            let (broken, _) = makeLog(failing: true)
            let (working, _) = makeLog()
            let withBroken = await order(recorder, sent, log: broken)
            let withWorking = await order(recorder, sent, log: working)
            XCTAssertEqual(withBroken, withWorking)
            await broken.flush()
            await working.flush()
            XCTAssertEqual(packetLines(broken), packetLines(working))
        }
        let confirmed = await order(BookingSendRecorder(body: object()), log: makeLog(failing: true).log)
        XCTAssertEqual(confirmed, .success(confirmedAnswer("DL-AB12CD", total: 4000)))
        let listed = await fetchOptions(BookingSendRecorder(body: optionsObject()), log: makeLog(failing: true).log)
        XCTAssertEqual(listed, .success(options))
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
            (.appleCalendar, "appleCalendar", "Apple Calendar"), (.partner, "partner", "Partner (Simulated)"),
            (.budgetPartner, "budgetPartner", "Example Budget (Simulated)")]
        for (party, raw, name) in parties {
            XCTAssertEqual(party.rawValue, raw)
            XCTAssertEqual(party.displayName, name)
        }
        let kinds: [(ConnectionKind, String, String, String)] = [
            (.share, "share", "Share", "Shared item"), (.imageRead, "imageRead", "Image read", "Image read"),
            (.placeSearch, "placeSearch", "Place search", "Place search"), (.route, "route", "Route", "Route lookup"),
            (.agentMessage, "agentMessage", "Message", "Message"), (.agentToolCall, "agentToolCall", "Tool call", "Tool call"),
            (.calendarSave, "calendarSave", "Calendar save", "Event saved"), (.partner, "partner", "Partner", "Partner request"),
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

    // MARK: P08 the options packets

    func testP08_TheOptionsExchangeRecordsOptionsRequestedThenReceivedUnderOneFlow() async throws {
        let (log, file) = makeLog()
        let result = await fetchOptions(BookingSendRecorder(body: optionsObject()), log: log)
        XCTAssertEqual(result, .success(options))
        await log.flush()
        XCTAssertEqual(packetLines(log), ["besir>deliveryPartner delivery ok Options requested",
                                          "deliveryPartner>besir delivery ok Options received"])
        XCTAssertEqual(log.packets.map(\.flowID), [flow, flow])
        // No summary holds a menu name, a price or a card label.
        let stored = try String(contentsOf: file, encoding: .utf8)
        for secret in ["Ramen", "ramen", "Gyoza", "Cheese", "Lemonade", "$", "Example Debit", "Example Credit", "debit-4242", token, host] {
            XCTAssertFalse(stored.contains(secret), "connections.json holds \(secret)")
        }
        XCTAssertTrue(log.packets.map(\.summary).allSatisfy { $0.unicodeScalars.allSatisfy { $0.isASCII } && !$0.contains(where: \.isNumber) })

        // A failed options request records one `Request failed` packet.
        let failures: [BookingSendRecorder] = [BookingSendRecorder(error: URLError(.notConnectedToInternet)),
                                               BookingSendRecorder(status: 404, body: "{}"),
                                               BookingSendRecorder(status: 500, body: "oops"),
                                               BookingSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#),
                                               BookingSendRecorder(body: "[]"),
                                               BookingSendRecorder(body: optionsObject { $0["partner"] = "Real Delivery" })]
        for recorder in failures {
            let (failed, _) = makeLog()
            _ = await fetchOptions(recorder, log: failed)
            await failed.flush()
            XCTAssertEqual(packetLines(failed), ["besir>deliveryPartner delivery failed Request failed"])
            XCTAssertEqual(failed.packets.first?.flowID, flow)
        }

        // No packet when no request was sent or the task was cancelled.
        let (blankLog, _) = makeLog()
        let blank = BookingSendRecorder(body: optionsObject())
        let blankResult = await fetchOptions(blank, log: blankLog, config: AppConfig())
        XCTAssertEqual(blankResult, .failure(.notSetUp))
        XCTAssertTrue(blank.requests.isEmpty)
        let (earlyLog, _) = makeLog()
        let early = BookingSendRecorder(body: optionsObject())
        let earlyResult = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fetchOptions(early, log: earlyLog)
        }.value
        XCTAssertEqual(earlyResult, .failure(.other))
        XCTAssertTrue(early.requests.isEmpty)
        let (flightLog, _) = makeLog()
        let flight = BookingSendRecorder(body: optionsObject())
        flight.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let flightResult = await Task { await fetchOptions(flight, log: flightLog) }.value
        XCTAssertEqual(flightResult, .failure(.other))
        XCTAssertEqual(flight.requests.count, 1)
        for quiet in [blankLog, earlyLog, flightLog] {
            await quiet.flush()
            XCTAssertTrue(quiet.packets.isEmpty)
        }
    }
}
