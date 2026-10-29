import XCTest
@testable import besir

/// The simulated delivery app as the Worker route behaves: it answers its fixed tables for an options request and computes an
/// order answer from the request alone. It records every request and can be told to fail instead.
final class DeliveryToolPartner {
    enum Mode {
        case worker
        case status(Int, String)
        case error(Error)
    }

    var mode: Mode = .worker
    private(set) var requests: [URLRequest] = []
    /// Runs inside the send call, before the answer is handed back.
    var duringSend: (() -> Void)?
    /// The partner's unit prices in cents; a test changes one to show that the card's total comes from the held answer.
    var prices: [String: Int] = ["ramen": 1400, "gyoza": 700, "curry": 1300, "pizza": 2500, "salad": 900, "lemonade": 400]

    private static let menu: [(id: String, name: String)] = [
        ("ramen", "Ramen"), ("gyoza", "Gyoza"), ("curry", "Curry rice"), ("pizza", "Cheese pizza"), ("salad", "Garden salad"),
        ("lemonade", "Lemonade")]
    static let cards: [(id: String, label: String)] = [
        ("debit-4242", "Example Debit \u{2022}\u{2022}4242 (Simulated)"), ("credit-1881", "Example Credit \u{2022}\u{2022}1881 (Simulated)")]

    var send: DeliveryClient.Send {
        { [self] request in
            requests.append(request)
            duringSend?()
            switch mode {
            case .error(let error):
                throw error
            case .status(let status, let body):
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            case .worker:
                let sent = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                let answer = sent["op"] as? String == "options" ? optionsAnswer() : orderAnswer(sent)
                let data = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private func optionsAnswer() -> [String: Any] {
        ["partner": "Example Delivery", "simulated": true,
         "menu": Self.menu.map { ["id": $0.id, "name": $0.name, "price_cents": prices[$0.id] ?? 0] as [String: Any] },
         "cards": Self.cards.map { ["id": $0.id, "label": $0.label] },
         "delivery_fee_cents": 500]
    }

    private func orderAnswer(_ sent: [String: Any]) -> [String: Any] {
        let arrive = sent["arrive_at"] as? String ?? ""
        let minute = (Int(arrive.dropFirst(11).prefix(2)) ?? 0) * 60 + (Int(arrive.dropFirst(14).prefix(2)) ?? 0)
        let lines = sent["items"] as? [[String: Any]] ?? []
        var answer: [String: Any] = ["partner": "Example Delivery", "simulated": true, "restaurant": sent["restaurant"] ?? "",
                                     "arrive_at": arrive, "items": lines, "address": sent["address"] ?? "",
                                     "card_id": sent["card_id"] ?? ""]
        if (600...1320).contains(minute) {
            answer["status"] = "confirmed"
            answer["order_id"] = "DL-AB12CD"
            answer["arrival_estimate"] = arrive
            answer["estimated_total_cents"] = lines.reduce(500) {
                $0 + (prices[$1["item_id"] as? String ?? ""] ?? 0) * ($1["quantity"] as? Int ?? 0)
            }
        } else {
            answer["status"] = "declined"
            answer["reason"] = "outside_hours"
        }
        return answer
    }

    /// The JSON object of the nth request body.
    func body(_ index: Int = 0) -> [String: Any]? {
        guard requests.indices.contains(index), let data = requests[index].httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// How often the toolbox asked for the device position (the manual start place merged with the current location).
@MainActor
final class DeliveryDeviceReads {
    var count = 0
}

enum DeliveryToolFixture {
    static let host = "delivery-tool-host.invalid"
    static let token = "delivery-tool-token-0001"
    static let config = AppConfig(kakaoJsKey: "", proxyBaseURL: "https://" + host, appToken: token)
    static let unconfigured = AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: "")
    /// The places of the registry, in handle order: p1 to p5.
    static let restaurant = Place(name: "Pasta Palace", address: "1 Main Street", latitude: 37.78, longitude: -122.41)
    static let library = Place(name: "Central Library", address: "9 Library Road", latitude: 37.79, longitude: -122.42)
    /// No address: its text is its name.
    static let corner = Place(name: "Corner Cafe", address: "", latitude: 37.77, longitude: -122.40)
    /// Neither the name nor the address fits 120 scalars: no usable text.
    static let noText = Place(name: String(repeating: "N", count: 121), address: String(repeating: "A", count: 121),
                              latitude: 37.76, longitude: -122.39)
    /// A 121-scalar address with a short name: its text is its name.
    static let harbor = Place(name: "Harbor Hall", address: String(repeating: "H", count: 121), latitude: 37.75, longitude: -122.38)
    static let places = [restaurant, library, corner, noText, harbor]
    /// Tomorrow 7:40 PM in the fixed clock's zone (the clock is 2026-10-27T09:00).
    static let arrival = "2026-10-28T19:40"
    static let items = "ramen:2,gyoza:1"
}

/// A toolbox over an empty Store with the fixed clock, a stubbed delivery partner and a connection log on a temporary file.
@MainActor
final class DeliveryToolRig {
    let store: Store
    let clock: MutableClock
    let partner: DeliveryToolPartner
    let log: ConnectionLog
    let box: BookingConfigBox
    let reads = DeliveryDeviceReads()
    let tools: AgentToolbox
    let folder: URL

    init(config: AppConfig = DeliveryToolFixture.config, partner: DeliveryToolPartner = DeliveryToolPartner(),
         places: [Place] = DeliveryToolFixture.places) {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let clock = MutableClock()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-tool-\(UUID().uuidString)", isDirectory: true)
        let log = ConnectionLog(fileURL: folder.appendingPathComponent(ConnectionLog.fileName),
                                secrets: { [DeliveryToolFixture.token, DeliveryToolFixture.host] })
        let box = BookingConfigBox(config)
        let reads = self.reads
        let toolbox = AgentToolbox(store: store, now: { clock.now }, timeZone: { clock.zone },
                                   deviceOrigin: { reads.count += 1; return nil },
                                   delivery: { DeliveryClient(config: box.config, send: partner.send, connections: log) })
        _ = toolbox.registry.register(places)
        self.store = store
        self.clock = clock
        self.partner = partner
        self.log = log
        self.box = box
        self.folder = folder
        tools = toolbox
    }

    static func arguments(_ over: [String: Any] = [:], drop: [String] = []) -> [String: Any] {
        var args: [String: Any] = ["place_id": "p1", "arrive_at": DeliveryToolFixture.arrival, "items": DeliveryToolFixture.items,
                                   "card_id": "debit-4242"]
        for (key, value) in over { args[key] = value }
        for key in drop { args.removeValue(forKey: key) }
        return args
    }

    func call(_ name: String, _ args: [String: Any] = [:]) -> AgentToolOutcome {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return tools.handle(name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    func order(_ over: [String: Any] = [:], drop: [String] = []) -> AgentToolOutcome {
        call("order_delivery", Self.arguments(over, drop: drop))
    }

    /// Runs a lookup to its end and reads the result; nil when the outcome is not a lookup.
    func run(_ outcome: AgentToolOutcome) async -> [String: Any]? {
        guard let lookup = outcome.lookup else { return nil }
        return TestClock.object(await lookup.run().result)
    }

    /// Asks `get_delivery_options` once, so the toolbox holds the partner's answer.
    func hold() async {
        _ = await run(call("get_delivery_options"))
    }

    /// Puts a schedule entry straight into the Store (local date-times).
    func seed(_ title: String, _ start: String, _ end: String, place: Place?) {
        store.activities.append(ActivityBlock(title: title, location: place, startDate: TestClock.date(start), endDate: TestClock.date(end)))
    }

    /// The usual schedule: a dinner at the library across the arrival time, so the delivery place is suggested.
    func seedDinner() {
        seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", place: DeliveryToolFixture.library)
    }

    /// A card for the usual arguments once the options are held and the schedule has the dinner; nil when the gate refused.
    func readyCard(_ over: [String: Any] = [:], drop: [String] = []) async -> AgentCard? {
        seedDinner()
        await hold()
        return order(over, drop: drop).card
    }

    /// A byte-for-byte picture of the schedule.
    var snapshot: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(store.activities)) ?? Data(), as: UTF8.self)
    }

    /// The file names in the test folder other than the connection log and its temporary write files (the log writes in the background).
    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(ConnectionLog.fileName) }.sorted()
    }
}

/// SPEC-DELIVERY-001 AC-DELIVERY-005 to 008: the two declarations, the options tool, the gate of `order_delivery`, the
/// suggestions and the confirmation card. M4 adds the Confirm tests (O19 to O35) to this file.
@MainActor
final class AgentDeliveryToolTests: XCTestCase {
    private func makeRig(config: AppConfig = DeliveryToolFixture.config, partner: DeliveryToolPartner = DeliveryToolPartner(),
                         places: [Place] = DeliveryToolFixture.places) -> DeliveryToolRig {
        let rig = DeliveryToolRig(config: config, partner: partner, places: places)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    /// The exact re-ask strings of the gate, spelled once for the tests.
    private enum Text {
        static let place = "Call search_places to find the restaurant, then call order_delivery again with the place_id it returns."
        static let time = "Ask the user when the food is to arrive, then call order_delivery again. Do not guess it."
        static let timeForm = "Call order_delivery again with arrive_at as a local date-time in the form YYYY-MM-DDTHH:MM, or ask the user."
        static let window = "Ask the user to confirm the date, then call order_delivery again. The arrive_at time must be a time that has not passed and be within the next 366 days."
        static let optionsFirst = "Call get_delivery_options first, then call order_delivery again with items and card_id taken from its answer."
        static let items = "Ask the user what to order, then call order_delivery again with items as comma-separated pairs of an item id from the get_delivery_options answer and a quantity from 1 to 9, 1 to 6 pairs, no spaces, no id repeated. Do not guess it."
        static let itemUnknown = "Call order_delivery again with items that use only item ids from the get_delivery_options answer, or ask the user what to order."
        static let card = "Ask the user which card to pay with, then call order_delivery again with card_id from the get_delivery_options answer. Do not guess it."
        static let cardUnknown = "Call order_delivery again with a card_id from the get_delivery_options answer, or ask the user which card to pay with."
        static let to = "Ask the user where to deliver. If they name a place, call search_places for it, then call order_delivery again with its place_id as deliver_to."
        static let toHandle = "Call search_places for the place to deliver to, then call order_delivery again with its place_id as deliver_to, or leave deliver_to out."
        static let unavailable = "Tell the user delivery is not available right now. Do not call order_delivery again."
        static let optionsUnavailable = "Tell the user delivery is not available right now. Do not call get_delivery_options or order_delivery again."
        static let optionsFailed = "The simulated delivery app could not be reached. Tell the user the delivery options are not available right now."
        static func wrongType(_ param: String) -> String {
            "Call order_delivery again with \(param) as a string. If you do not have it, ask the user; do not guess it."
        }
        static let wrongTypeDeliverTo = "Call order_delivery again with deliver_to as a string, or omit it if the user did not give it."
        static let notice = "That start time is now out of range. Nothing was added."
    }

    private func declarations() -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: AgentTools.declarationsJSON())) as? [[String: Any]]) ?? []
    }

    private func assertRefused(_ outcome: AgentToolOutcome, _ message: String, _ note: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome.status, "rejected", note, file: file, line: line)
        XCTAssertEqual(outcome.message, message, note, file: file, line: line)
    }

    /// Every key name found anywhere in a JSON value.
    private func keys(in value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return Set(object.keys).union(object.values.reduce(into: Set<String>()) { $0.formUnion(keys(in: $1)) })
        }
        if let list = value as? [Any] {
            return list.reduce(into: Set<String>()) { $0.formUnion(keys(in: $1)) }
        }
        return []
    }

    private func formatted(_ local: String, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TestClock.zone
        f.dateFormat = pattern
        return f.string(from: TestClock.date(local))
    }

    private func dayText(_ local: String) -> String { formatted(local, "EEE, MMM d, h:mm a") }

    private func timeText(_ local: String) -> String { formatted(local, "h:mm a") }

    private let wrongValues: [Any] = [5, 2.5, true, false, NSNull(), ["a"], ["a": 1]]

    // MARK: O01 the declarations

    func testO01_ThirteenDeclarationsTheNewTwoSitBeforeRequestBookingAndAreStrict() throws {
        let decls = declarations()
        XCTAssertEqual(decls.count, 13)
        XCTAssertEqual(decls.compactMap { $0["name"] as? String },
                       ["list_activities", "create_activity", "update_activity", "delete_activity", "search_places",
                        "get_travel_time", "check_day_plan", "show_day_plan", "get_budget_left", "record_spend",
                        "get_delivery_options", "order_delivery", "request_booking"])
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tools", withExtension: "json"))
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(recorded.count, 13)
        for index in decls.indices {
            XCTAssertTrue((decls[index] as AnyObject).isEqual(recorded[index]), "declaration \(index) differs from the fixture")
        }
        XCTAssertEqual(decls.last?["name"] as? String, "request_booking")

        let options = decls[10]
        XCTAssertEqual(options["type"] as? String, "function")
        let optionsParameters = try XCTUnwrap(options["parameters"] as? [String: Any])
        XCTAssertEqual((optionsParameters["properties"] as? [String: Any])?.count, 0)
        XCTAssertEqual(optionsParameters["additionalProperties"] as? Bool, false)
        XCTAssertNil(optionsParameters["required"])

        let order = decls[11]
        XCTAssertEqual(order["type"] as? String, "function")
        let orderParameters = try XCTUnwrap(order["parameters"] as? [String: Any])
        XCTAssertEqual(orderParameters["required"] as? [String], ["place_id", "arrive_at", "items", "card_id"])
        XCTAssertEqual(orderParameters["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(orderParameters["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["place_id", "arrive_at", "items", "card_id", "deliver_to"])
        for (name, spec) in properties {
            XCTAssertEqual((spec as? [String: Any])?["type"] as? String, "string", name)
            XCTAssertFalse(((spec as? [String: Any])?["description"] as? String ?? "").isEmpty, name)
        }
        let found = keys(in: decls)
        XCTAssertFalse(found.contains("enum"))
        XCTAssertFalse(found.contains("pattern"))

        // The names that the three guard tests reject (their lists, spelled once more): none of the declared names is one.
        let containsA = ["confirm", "approv", "yes", "force", "skip", "authoriz", "accept", "location", "place", "address", "coord",
                         "latitude", "longitude", "geo"]
        let containsB = ["lat", "lng", "lon", "coord", "address", "name", "minute", "duration", "leave", "depart", "confirm", "approv",
                         "force", "skip"]
        for name in properties.keys where name != "place_id" {
            XCTAssertFalse(containsA.contains { name.contains($0) }, name)
            XCTAssertFalse(containsB.contains { name.contains($0) }, name)
        }
        for forbidden in ["address", "meal", "name", "location"] { XCTAssertNil(properties[forbidden], forbidden) }

        let optionsText = try XCTUnwrap(options["description"] as? String)
        for clause in ["simulated delivery app", "always call the result simulated", "items with estimated prices", "delivery fee",
                       "cards", "Call it before order_delivery"] {
            XCTAssertTrue(optionsText.contains(clause), clause)
        }
        let orderText = try XCTUnwrap(order["description"] as? String)
        for clause in ["simulated delivery app", "always call the result simulated", "found with search_places",
                       "taken from get_delivery_options", "item_id:quantity pairs separated by commas",
                       "Ask the user for the arrival time, the items and the card if they have not said",
                       "deliver_to is a place_id from search_places, set only when the user named a place to deliver to and left out otherwise",
                       "the app may then suggest a place from the schedule", "Never write an address",
                       "The user confirms before anything is sent"] {
            XCTAssertTrue(orderText.contains(clause), clause)
        }
        let toText = try XCTUnwrap((properties["deliver_to"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(toText.contains("only when the user named a place"))
        XCTAssertEqual(AgentSession.knownToolNames().intersection(["get_delivery_options", "order_delivery"]).count, 2)
    }

    // MARK: O02-O03 the options tool

    func testO02_GetDeliveryOptionsSendsOneRequestReturnsTheFixedResultAndWritesNothing() async throws {
        let rig = makeRig()
        for text in ["{}", "", "   ", " \n\t "] {
            let outcome = rig.tools.handle(name: "get_delivery_options", arguments: text)
            XCTAssertTrue(outcome.isLookup, "arguments text \(text.debugDescription)")
            XCTAssertNil(outcome.card)
        }
        XCTAssertEqual(rig.partner.requests.count, 0, "building the lookup sends nothing")
        let before = rig.snapshot
        let ran = await rig.run(rig.call("get_delivery_options", ["address": "SENTINEL-ADDRESS-1", "menu": 5]))
        let result = try XCTUnwrap(ran)
        XCTAssertEqual(rig.partner.requests.count, 1)
        XCTAssertEqual(rig.partner.body()?["op"] as? String, "options")
        XCTAssertEqual(Set(try XCTUnwrap(rig.partner.body()).keys), ["op"])
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["partner"] as? String, DeliveryClient.partnerName)
        XCTAssertEqual(result["simulated"] as? Bool, true)
        XCTAssertEqual(result["estimated_delivery_fee"] as? String, "$5.00")
        XCTAssertEqual(result["message"] as? String, AgentDelivery.optionsMessage)
        let menu = try XCTUnwrap(result["menu"] as? [[String: Any]])
        XCTAssertEqual(menu.compactMap { $0["item_id"] as? String }, ["ramen", "gyoza", "curry", "pizza", "salad", "lemonade"])
        XCTAssertEqual(menu.compactMap { $0["name"] as? String }, ["Ramen", "Gyoza", "Curry rice", "Cheese pizza", "Garden salad", "Lemonade"])
        XCTAssertEqual(menu.compactMap { $0["estimated_price"] as? String }, ["$14.00", "$7.00", "$13.00", "$25.00", "$9.00", "$4.00"])
        let cards = try XCTUnwrap(result["cards"] as? [[String: Any]])
        XCTAssertEqual(cards.compactMap { $0["card_id"] as? String }, ["debit-4242", "credit-1881"])
        XCTAssertEqual(cards.compactMap { $0["label"] as? String }, DeliveryToolPartner.cards.map(\.label))
        XCTAssertFalse(String(decoding: try XCTUnwrap(rig.partner.requests.first?.httpBody), as: UTF8.self).contains("SENTINEL"))
        XCTAssertEqual(rig.snapshot, before)
        XCTAssertTrue(rig.store.activities.isEmpty)
        XCTAssertEqual(rig.files, [], "nothing but the connection log is on disk")
        XCTAssertEqual(rig.reads.count, 0)
    }

    func testO03_AFailedOrCancelledOptionsCallHoldsNothingNewAndANewChatForgetsTheAnswer() async throws {
        let failures: [(String, DeliveryToolPartner.Mode)] = [
            ("offline", .error(URLError(.notConnectedToInternet))), ("404", .status(404, "{}")), ("500", .status(500, "{}")),
            ("wrong shape", .status(200, "{\"partner\":\"Example Delivery\"}"))]
        for (name, mode) in failures {
            let partner = DeliveryToolPartner()
            partner.mode = mode
            let rig = makeRig(partner: partner)
            let ran = await rig.run(rig.call("get_delivery_options"))
            let result = try XCTUnwrap(ran, name)
            XCTAssertEqual(result["status"] as? String, "unavailable", name)
            XCTAssertEqual(result["partner"] as? String, DeliveryClient.partnerName, name)
            XCTAssertEqual(result["simulated"] as? Bool, true, name)
            XCTAssertEqual(result["message"] as? String, Text.optionsFailed, name)
            // Nothing was held: the order tool still asks for the options first.
            assertRefused(rig.order(), Text.optionsFirst, name)
        }
        // A task cancelled in flight gives the same result and holds nothing.
        let partner = DeliveryToolPartner()
        let rig = makeRig(partner: partner)
        partner.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let lookup = try XCTUnwrap(rig.call("get_delivery_options").lookup)
        let cancelled = await Task { await lookup.run() }.value
        XCTAssertEqual(TestClock.object(cancelled.result)?["status"] as? String, "unavailable")
        partner.duringSend = nil
        assertRefused(rig.order(), Text.optionsFirst, "cancelled")

        // An answer held before stays when a later call fails; a new chat forgets it.
        await rig.hold()
        rig.partner.mode = .status(500, "{}")
        let failedRun = await rig.run(rig.call("get_delivery_options"))
        let failed = try XCTUnwrap(failedRun)
        XCTAssertEqual(failed["status"] as? String, "unavailable")
        XCTAssertNotNil(rig.order(["deliver_to": "p2"]).card, "the held answer stays after a failed call")
        rig.tools.resetConversation()
        let handles = try XCTUnwrap(rig.tools.registry.register(DeliveryToolFixture.places))
        assertRefused(rig.order(["place_id": handles[0], "deliver_to": handles[1]]), Text.optionsFirst, "a new chat forgets the held answer")

        // No proxy: the fixed message comes before any argument is read, and nothing is sent.
        let quiet = makeRig(config: DeliveryToolFixture.unconfigured)
        assertRefused(quiet.call("get_delivery_options"), Text.optionsUnavailable)
        assertRefused(quiet.tools.handle(name: "get_delivery_options", arguments: ""), Text.optionsUnavailable)
        assertRefused(quiet.tools.handle(name: "get_delivery_options", arguments: "not json"), Text.optionsUnavailable)
        XCTAssertEqual(quiet.partner.requests.count, 0)
    }

    // MARK: O04-O10 the gate

    func testO04_APlaceIdThatIsMissingNotAHandleOrUnknownIsRefused() async {
        let rig = makeRig()
        await rig.hold()
        assertRefused(rig.order(drop: ["place_id"]), Text.place, "missing")
        assertRefused(rig.order(["place_id": "  "]), Text.place, "blank")
        for handle in ["p99", "p9999", "x1", "P1", "p", "p01x", "r1", "1", "Pasta Palace"] {
            assertRefused(rig.order(["place_id": handle]), Text.place, handle)
        }
        XCTAssertEqual(rig.partner.requests.count, 1, "only the options request")
    }

    func testO05_AnArrivalThatIsMissingBlankBadlyFormedPassedOrBeyondTheWindowIsRefused() async {
        let rig = makeRig()
        await rig.hold()
        assertRefused(rig.order(drop: ["arrive_at"]), Text.time, "missing")
        assertRefused(rig.order(["arrive_at": "   "]), Text.time, "blank")
        for text in ["tomorrow 7pm", "2026-10-28 19:00", "2026-10-28T19:00:00", "2026-02-30T19:00", "2026-10-28T7:00", " 2026-10-28T19:00"] {
            assertRefused(rig.order(["arrive_at": text]), Text.timeForm, text)
        }
        // The clock is 2026-10-27T09:00: the minute itself is allowed, the minute before is not.
        XCTAssertNotNil(rig.order(["arrive_at": "2026-10-27T09:00", "deliver_to": "p2"]).card)
        assertRefused(rig.order(["arrive_at": "2026-10-27T08:59"]), Text.window, "a minute ago")
        assertRefused(rig.order(["arrive_at": "2026-10-26T19:00"]), Text.window, "yesterday")
        XCTAssertNotNil(rig.order(["arrive_at": "2027-10-28T09:00", "deliver_to": "p2"]).card, "366 days ahead, to the minute")
        assertRefused(rig.order(["arrive_at": "2027-10-28T09:01"]), Text.window, "a minute past the window")
        assertRefused(rig.order(["arrive_at": "2027-10-29T09:00"]), Text.window, "beyond 366 days")
    }

    func testO06_WithoutAHeldOptionsAnswerTheCallIsRefusedAndNothingIsSent() async {
        let rig = makeRig()
        rig.seedDinner()
        assertRefused(rig.order(), Text.optionsFirst)
        // The earlier checks come first, and the later ones wait for the answer.
        assertRefused(rig.order(["place_id": "p99"]), Text.place)
        assertRefused(rig.order(["items": "sushi:1"]), Text.optionsFirst)
        XCTAssertEqual(rig.partner.requests.count, 0)
        await rig.hold()
        XCTAssertNotNil(rig.order().card, "after the options tool the same call passes")
        XCTAssertEqual(rig.partner.requests.count, 1)
    }

    func testO07_ItemsAreParsedStrictlyAndCheckedAgainstTheHeldMenu() async throws {
        let rig = makeRig()
        await rig.hold()
        for (text, count) in [("ramen:2,gyoza:1", 2), ("pizza:9", 1), ("ramen:1,gyoza:1,curry:1,pizza:1,salad:1,lemonade:1", 6)] {
            let card = try XCTUnwrap(rig.order(["items": text, "deliver_to": "p2"]).card, text)
            XCTAssertEqual(card.lines.filter { $0.contains(" x ") }.count, count, text)
        }
        let lines = try XCTUnwrap(rig.order(["items": "gyoza:3,ramen:1", "deliver_to": "p2"]).card).lines
        XCTAssertEqual(Array(lines[3...4]), ["3 x Gyoza", "1 x Ramen"], "the lines keep the order given")
        assertRefused(rig.order(drop: ["items"]), Text.items, "missing")
        assertRefused(rig.order(["items": "  "]), Text.items, "blank")
        for text in ["ramen", "ramen:0", "ramen:10", "ramen:2,", ",ramen:2", "ramen: 2", "ramen:2, gyoza:1", "ramen:2:1", "ramen:x",
                     "ramen:\u{0662}", "ramen:1,ramen:2", "Ramen:1", ":2",
                     "ramen:1,gyoza:1,curry:1,pizza:1,salad:1,lemonade:1,ramen:2"] {
            assertRefused(rig.order(["items": text]), Text.items, text)
        }
        assertRefused(rig.order(["items": "sushi:1"]), Text.itemUnknown, "an id the held menu does not hold")
        assertRefused(rig.order(["items": "ramen:1,sushi:2"]), Text.itemUnknown, "one unknown id among known ones")
    }

    func testO08_ACardIdIsCheckedAgainstTheHeldCards() async throws {
        let rig = makeRig()
        await rig.hold()
        assertRefused(rig.order(drop: ["card_id"]), Text.card, "missing")
        assertRefused(rig.order(["card_id": "  "]), Text.card, "blank")
        for id in ["visa", "DEBIT-4242", "debit-4242 ", "credit-1882"] {
            assertRefused(rig.order(["card_id": id]), Text.cardUnknown, id)
        }
        let credit = try XCTUnwrap(rig.order(["card_id": "credit-1881", "deliver_to": "p2"]).card)
        XCTAssertTrue(credit.lines.contains("Pay with \(DeliveryToolPartner.cards[1].label)"))
        XCTAssertNotNil(rig.order(["deliver_to": "p2"]).card)
    }

    func testO09_ANonStringArgumentGetsTheStringMessageAndNeverOmitForARequiredParameter() async {
        let rig = makeRig()
        await rig.hold()
        for param in ["place_id", "arrive_at", "items", "card_id"] {
            for value in wrongValues {
                let outcome = rig.order([param: value])
                assertRefused(outcome, Text.wrongType(param), "\(param) = \(value)")
                XCTAssertFalse((outcome.message ?? "").contains("omit"))
            }
        }
        for value in wrongValues {
            let outcome = rig.order(["deliver_to": value])
            assertRefused(outcome, Text.wrongTypeDeliverTo, "deliver_to = \(value)")
        }
        XCTAssertEqual(rig.partner.requests.count, 1, "only the options request")
    }

    func testO10_AnUndeclaredArgumentIsNeverReadOrSent() async throws {
        let rig = makeRig()
        rig.seedDinner()
        await rig.hold()
        let extras: [String: Any] = ["address": "SENTINEL-ADDRESS-1", "meal": "SENTINEL-MEAL-1", "people": 5, "payment": "SENTINEL-CARD-1",
                                     "total": "SENTINEL-TOTAL-1", "phone": "SENTINEL-PHONE-1", "menu": ["x"], "price": 1,
                                     "name": "SENTINEL-NAME-1", "duration": ["x"]]
        let plain = try XCTUnwrap(rig.order().card)
        let card = try XCTUnwrap(rig.order(extras).card, "undeclared keys, even of a wrong type, are dropped")
        XCTAssertEqual(card.lines, plain.lines, "an address or a meal key from the model changes nothing on the card")
        XCTAssertFalse(card.lines.joined().contains("SENTINEL"))
        XCTAssertEqual(card.editors.delivery?.text, plain.editors.delivery?.text)
        XCTAssertEqual(card.editors.mealTitle?.text, plain.editors.mealTitle?.text)
        XCTAssertEqual(rig.partner.requests.count, 1, "only the options request")
        let sent = String(decoding: try XCTUnwrap(rig.partner.requests.first?.httpBody), as: UTF8.self)
        XCTAssertFalse(sent.contains("SENTINEL"))
    }

    // MARK: O11-O13 the delivery place and the meal entry

    func testO11_ADeliverToHandleGivesTheDeliveryTextOfTheRuleAndIsNotEditable() async throws {
        let rig = makeRig()
        await rig.hold()
        let library = try XCTUnwrap(rig.order(["deliver_to": "p2"]).card)
        XCTAssertEqual(library.lines[5], "To 9 Library Road", "the address, shown without a mark")
        XCTAssertNil(library.editors.delivery, "a named place is not edited in the card")
        XCTAssertNotNil(library.editors.mealOn, "the meal entry is still editable")
        let corner = try XCTUnwrap(rig.order(["deliver_to": "p3"]).card)
        XCTAssertEqual(corner.lines[5], "To Corner Cafe", "no address: the name")
        let harbor = try XCTUnwrap(rig.order(["deliver_to": "p5"]).card)
        XCTAssertEqual(harbor.lines[5], "To Harbor Hall", "an address over 120 scalars falls to the name")
        for handle in ["p99", "x1", "P2", "library", "r1", "p4"] {
            assertRefused(rig.order(["deliver_to": handle]), Text.toHandle, handle)
        }
        // A blank deliver_to is absent: with no schedule entry the call asks the user.
        assertRefused(rig.order(["deliver_to": "   "]), Text.to, "blank")
        assertRefused(rig.order(), Text.to, "absent")
        XCTAssertEqual(rig.partner.requests.count, 1, "only the options request")
        XCTAssertEqual(rig.reads.count, 0)
    }

    private struct Seed {
        let title: String
        let start: String
        let end: String
        let place: Place?
        init(_ title: String, _ start: String, _ end: String, _ place: Place?) {
            self.title = title
            self.start = start
            self.end = end
            self.place = place
        }
    }

    /// A rig whose schedule holds `seeds`, the options held, and the card of the usual call without `deliver_to` (nil when refused).
    private func suggested(_ seeds: [Seed]) async -> (card: AgentCard?, rig: DeliveryToolRig) {
        let rig = makeRig()
        for seed in seeds { rig.seed(seed.title, seed.start, seed.end, place: seed.place) }
        await rig.hold()
        return (rig.order().card, rig)
    }

    func testO12_WithoutDeliverToTheScheduleSuggestsAPlaceOrTheCallAsksTheUser() async throws {
        let library = DeliveryToolFixture.library
        let corner = DeliveryToolFixture.corner
        let dinner = Seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", library)
        let nowEntry = Seed("Study", "2026-10-27T08:00", "2026-10-27T10:00", corner)
        // The entry in progress at the arrival time wins over a different one in progress now.
        let both = await suggested([dinner, nowEntry])
        XCTAssertEqual(both.card?.lines[5], "To 9 Library Road (suggested from your schedule)")
        // With none at the arrival time the entry in progress now is used.
        let nowOnly = await suggested([nowEntry])
        XCTAssertEqual(nowOnly.card?.lines[5], "To Corner Cafe (suggested from your schedule)")
        XCTAssertEqual(nowOnly.card?.editors.delivery?.text, "Corner Cafe")
        // Two different places at one anchor give no suggestion, and the later anchor is not used.
        let differ = await suggested([dinner, Seed("Other", "2026-10-28T19:30", "2026-10-28T20:30", DeliveryToolFixture.restaurant), nowEntry])
        XCTAssertNil(differ.card)
        assertRefused(differ.rig.order(), Text.to)
        // Two equal places give one suggestion.
        let same = await suggested([dinner, Seed("Other", "2026-10-28T19:30", "2026-10-28T20:30", library)])
        XCTAssertEqual(same.card?.lines[5], "To 9 Library Road (suggested from your schedule)")
        // None at either anchor, no place, no usable text, an ended entry, a future entry and a past one: the call asks the user.
        let none: [[Seed]] = [
            [],
            [Seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", nil)],
            [Seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", DeliveryToolFixture.noText)],
            [Seed("Ended", "2026-10-28T18:00", "2026-10-28T19:40", library)],
            [Seed("Later", "2026-10-28T19:41", "2026-10-28T21:00", library)],
            [Seed("Past", "2026-10-26T08:00", "2026-10-26T10:00", library)]]
        for (index, seeds) in none.enumerated() {
            let refused = await suggested(seeds)
            XCTAssertNil(refused.card, "case \(index)")
            assertRefused(refused.rig.order(), Text.to, "case \(index)")
        }
        // An entry that starts at the arrival minute counts.
        let starts = await suggested([Seed("Starts", "2026-10-28T19:40", "2026-10-28T21:00", library)])
        XCTAssertNotNil(starts.card)
        // Building the card does not write the Store and the device position is never read.
        let rig = makeRig()
        rig.seedDinner()
        await rig.hold()
        let before = rig.snapshot
        XCTAssertNotNil(rig.order().card)
        XCTAssertEqual(rig.snapshot, before)
        XCTAssertEqual(rig.store.activities.count, 1)
        XCTAssertEqual(rig.reads.count, 0)
        XCTAssertEqual(both.rig.reads.count + differ.rig.reads.count, 0)
    }

    func testO13_TheCardCarriesTheSuggestedMealEntryByTheArrivalMinute() async throws {
        let rig = makeRig()
        await rig.hold()
        let evening = try XCTUnwrap(rig.order(["deliver_to": "p2"]).card)
        XCTAssertEqual(evening.lines[8], "Add to schedule: Dinner (Simulated) at \(timeText(DeliveryToolFixture.arrival)) (suggested)")
        XCTAssertEqual(evening.editors.mealTitle?.text, "Dinner")
        XCTAssertEqual(evening.editors.mealOn?.isOn, true)
        XCTAssertEqual(evening.editors.mealStart?.start, TestClock.date(DeliveryToolFixture.arrival))
        for (arrive, word) in [("2026-10-27T10:30", "Brunch"), ("2026-10-27T11:00", "Lunch"), ("2026-10-27T14:59", "Lunch"),
                               ("2026-10-27T15:00", "Snack"), ("2026-10-27T16:59", "Snack"), ("2026-10-27T17:00", "Dinner")] {
            let card = try XCTUnwrap(rig.order(["arrive_at": arrive, "deliver_to": "p2"]).card, arrive)
            XCTAssertEqual(card.lines[8], "Add to schedule: \(word) (Simulated) at \(timeText(arrive)) (suggested)", arrive)
        }
    }

    // MARK: O14-O15 the proxy and the texts

    func testO14_WithNoProxyTheCallGivesTheUnavailableMessageAfterTheOtherArgumentsAreValid() async {
        let rig = makeRig()
        rig.seedDinner()
        await rig.hold()
        XCTAssertNotNil(rig.order().card)
        rig.box.config = DeliveryToolFixture.unconfigured
        let sent = rig.partner.requests.count
        assertRefused(rig.order(), Text.unavailable)
        // The earlier checks come first.
        assertRefused(rig.order(["place_id": "p99"]), Text.place)
        assertRefused(rig.order(drop: ["items"]), Text.items)
        assertRefused(rig.order(["card_id": "visa"]), Text.cardUnknown)
        assertRefused(rig.order(["deliver_to": "p4"]), Text.toHandle)
        XCTAssertEqual(rig.partner.requests.count, sent, "nothing is sent")
        rig.box.config = DeliveryToolFixture.config
        XCTAssertNotNil(rig.order().card)
    }

    func testO15_EveryReAskStringNamesOnlyDeclaredParametersAndToolsAndHoldsNoModelValue() async throws {
        let rig = makeRig()
        let declared: Set<String> = ["place_id", "arrive_at", "items", "card_id", "deliver_to"]
        let toolNames: Set<String> = ["search_places", "get_delivery_options", "order_delivery"]
        let sentinel = "SENTINEL-MODEL-VALUE"
        rig.seedDinner()
        var messages: [String] = []
        func collect(_ outcome: AgentToolOutcome) { if let message = outcome.message { messages.append(message) } }
        // Before the options are held, then with them held.
        collect(rig.order())
        await rig.hold()
        collect(rig.order(["place_id": sentinel]))
        collect(rig.order(["arrive_at": sentinel]))
        collect(rig.order(["arrive_at": "2020-01-01T10:00"]))
        collect(rig.order(["items": sentinel]))
        collect(rig.order(["items": "\(sentinel):1"]))
        collect(rig.order(["card_id": sentinel]))
        collect(rig.order(["deliver_to": sentinel]))
        collect(rig.order(drop: ["place_id", "arrive_at"]))
        collect(rig.order(drop: ["items"]))
        collect(rig.order(drop: ["card_id"]))
        for param in declared { collect(rig.order([param: 5])) }
        collect(makeRig().order(["deliver_to": "p99"]))
        let empty = makeRig()
        empty.seed("Study", "2026-10-28T08:00", "2026-10-28T09:00", place: DeliveryToolFixture.library)
        await empty.hold()
        collect(empty.order())
        rig.box.config = DeliveryToolFixture.unconfigured
        collect(rig.order())
        collect(makeRig(config: DeliveryToolFixture.unconfigured).call("get_delivery_options"))
        XCTAssertGreaterThan(messages.count, 15)
        for message in messages {
            XCTAssertFalse(message.contains(sentinel), message)
            let words = message.split { !($0.isLetter || $0 == "_") }.map(String.init)
            for word in words where word.contains("_") {
                XCTAssertTrue(declared.contains(word) || toolNames.contains(word), "\(message) names \(word)")
            }
            for other in ["list_activities", "create_activity", "update_activity", "delete_activity", "get_travel_time", "check_day_plan",
                          "show_day_plan", "request_booking", "get_budget_left", "record_spend", "address", "meal"] {
                XCTAssertFalse(message.contains(other), "\(message) names \(other)")
            }
        }
        // The strings of the older tools are unchanged.
        let booking = DeliveryToolRig()
        XCTAssertEqual(booking.call("request_booking", ["place_id": "p99", "start": "x", "party_size": "2"]).message,
                       "Call search_places to find the place, then call request_booking again with the place_id it returns.")
        XCTAssertEqual(booking.call("record_spend", ["amount": 5]).message,
                       "Tell the user the budget is not available right now. Do not call get_budget_left or record_spend again.")
        XCTAssertEqual(booking.call("list_activities", ["from": 5]).message, ToolText.wrongType("list_activities", "from"))
        XCTAssertEqual(booking.call("search_places", ["query": 5]).message, ToolText.wrongType("search_places", "query"))
    }

    // MARK: O16-O18 the card

    func testO16_ValidArgumentsReturnACardWithTheExactLinesAndTheTotalOfTheHeldOptions() async throws {
        let rig = makeRig()
        rig.seedDinner()
        await rig.hold()
        let before = rig.snapshot
        let outcome = rig.order()
        XCTAssertNil(outcome.lookup)
        XCTAssertNil(outcome.resultText)
        let card = try XCTUnwrap(outcome.card)
        let arrives = "Arrives \(dayText(DeliveryToolFixture.arrival))"
        let dinner = "Add to schedule: Dinner (Simulated) at \(timeText(DeliveryToolFixture.arrival))"
        XCTAssertEqual(card.lines, ["Order delivery", "Pasta Palace", arrives, "2 x Ramen", "1 x Gyoza",
                                    "To 9 Library Road (suggested from your schedule)", "Pay with \(DeliveryToolPartner.cards[0].label)",
                                    "Estimated total $40.00", dinner + " (suggested)", "Example Delivery - Simulated"])
        XCTAssertTrue(card.showsGoogleMark)
        XCTAssertEqual(card.actions, ["Confirm", "Cancel"])
        XCTAssertTrue(card.canConfirm)
        XCTAssertFalse(card.lines.joined().contains("DL-"), "no order id is on the card")
        XCTAssertEqual(rig.partner.requests.count, 1, "nothing is sent while the card waits")
        XCTAssertEqual(rig.snapshot, before)
        XCTAssertEqual(rig.files, [])

        // A named delivery place: no mark on the To line.
        let named = try XCTUnwrap(rig.order(["deliver_to": "p3", "card_id": "credit-1881"]).card)
        XCTAssertEqual(named.lines, ["Order delivery", "Pasta Palace", arrives, "2 x Ramen", "1 x Gyoza", "To Corner Cafe",
                                     "Pay with \(DeliveryToolPartner.cards[1].label)", "Estimated total $40.00", dinner + " (suggested)",
                                     "Example Delivery - Simulated"])

        // The total comes from the options the app holds, not from a constant: a partner with another price is held and shown.
        let partner = DeliveryToolPartner()
        partner.prices["ramen"] = 1500
        let other = makeRig(partner: partner)
        await other.hold()
        let priced = try XCTUnwrap(other.order(["deliver_to": "p2"]).card)
        XCTAssertTrue(priced.lines.contains("Estimated total $42.00"))
        let big = try XCTUnwrap(other.order(["items": "ramen:9,pizza:9", "deliver_to": "p2"]).card)
        XCTAssertTrue(big.lines.contains("Estimated total $365.00"))
    }

    func testO17_CancelResolvesTheCardAsCancelledAndSendsAndWritesNothing() async throws {
        for how in [AgentCardResolution.cancel, .dismiss] {
            let rig = makeRig()
            let made = await rig.readyCard()
            let card = try XCTUnwrap(made)
            let before = rig.snapshot
            let sent = rig.partner.requests.count
            let resolution = await card.resolve(how)
            XCTAssertEqual(card.mark, .cancelled)
            XCTAssertEqual(resolution?.result, AgentToolbox.declinedResult)
            XCTAssertNil(resolution?.notice)
            XCTAssertEqual(rig.partner.requests.count, sent)
            XCTAssertEqual(rig.snapshot, before)
            let second = await card.resolve(.confirm)
            XCTAssertNil(second, "a second resolution does nothing")
            XCTAssertEqual(rig.partner.requests.count, sent)
            XCTAssertEqual(card.mark, .cancelled)
            await rig.log.flush()
            XCTAssertEqual(rig.log.packets.count, 2, "only the options exchange is on the log")
        }
    }

    func testO18_AnArrivalThatPassedWhileTheCardWaitedGivesRejectedTheNoticeAndNothingElse() async throws {
        let rig = makeRig()
        let made = await rig.readyCard()
        let card = try XCTUnwrap(made)
        let before = rig.snapshot
        let sent = rig.partner.requests.count
        // The minute of the arrival is still allowed; the next one is not.
        rig.clock.now = TestClock.date("2026-10-28T19:41")
        let resolved = await card.resolve(.confirm)
        let resolution = try XCTUnwrap(resolved)
        XCTAssertEqual(resolution.status, "rejected")
        XCTAssertEqual(resolution.message, Text.window)
        XCTAssertEqual(resolution.notice, Text.notice)
        XCTAssertEqual(card.mark, .notApplied)
        XCTAssertEqual(rig.partner.requests.count, sent, "nothing is sent")
        XCTAssertEqual(rig.snapshot, before)
        XCTAssertEqual(rig.files, [])
    }
}
