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
    /// Runs on the main actor while the request is in flight (the call is suspended there), so a test can edit the card.
    var whileSending: (@MainActor () -> Void)?
    /// The partner's unit prices in cents; a test changes one to show that the card's total comes from the held answer.
    var prices: [String: Int] = ["ramen": 1400, "gyoza": 700, "curry": 1300, "pizza": 2500, "salad": 900, "lemonade": 400]
    /// Added to the money item of an order answer, so the answer differs from the card's.
    var totalDelta = 0
    /// The keys of the order form in the order the partner lists them (its options answer holds exactly these three).
    var fieldOrder = ["arrive_at", "address", "card_id"]
    /// Result items sent after the three the Worker sends.
    var extraResults: [[String: Any]] = []
    /// When set, the `time` item of a confirmed order carries this text instead of the requested arrival.
    var timeItem: String?
    /// The name the partner gives its money item (the Worker says `Estimated total`).
    var moneyName = "Estimated total"

    private static let menu: [(id: String, name: String)] = [
        ("ramen", "Ramen"), ("gyoza", "Gyoza"), ("curry", "Curry rice"), ("pizza", "Cheese pizza"), ("salad", "Garden salad"),
        ("lemonade", "Lemonade")]
    static let cards: [(id: String, label: String)] = [
        ("debit-4242", "Example Debit \u{2022}\u{2022}4242 (Simulated)"), ("credit-1881", "Example Credit \u{2022}\u{2022}1881 (Simulated)")]

    var send: DeliveryClient.Send {
        { [self] request in
            requests.append(request)
            duringSend?()
            await whileSending?()
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

    private static func field(_ key: String) -> [String: Any] {
        switch key {
        case "arrive_at": return ["key": "arrive_at", "kind": "time", "label": "Arrival"]
        case "address": return ["key": "address", "kind": "place", "label": "Delivery place"]
        default:
            return ["key": "card_id", "kind": "pick_one", "label": "Pay with",
                    "options": cards.map { ["id": $0.id, "label": $0.label] }]
        }
    }

    private func optionsAnswer() -> [String: Any] {
        ["partner": "Example Delivery", "simulated": true,
         "menu": Self.menu.map { ["id": $0.id, "name": $0.name, "price_cents": prices[$0.id] ?? 0] as [String: Any] },
         "delivery_fee_cents": 500,
         "order_fields": fieldOrder.map(Self.field)]
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
            let total = totalDelta + lines.reduce(500) {
                $0 + (prices[$1["item_id"] as? String ?? ""] ?? 0) * ($1["quantity"] as? Int ?? 0)
            }
            let items: [[String: Any]] = [["name": "Arrival", "kind": "time", "value": timeItem ?? arrive],
                                          ["name": moneyName, "kind": "money", "value": total],
                                          ["name": "Status", "kind": "text", "value": "Preparing"]]
            answer["results"] = items + extraResults
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

struct DeliveryRecordWriteFailure: Error {}

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
    /// What the device position would give if the toolbox ever read it.
    static let device = Place(name: "SENTINEL-HOME-1", address: "SENTINEL-HOME-ADDRESS-1", latitude: 37.70, longitude: -122.30)
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
    let budgetPartner: BudgetToolPartner
    let ledger: BudgetLedger
    let orders: DeliveryOrderLog
    let reads = DeliveryDeviceReads()
    let tools: AgentToolbox
    let folder: URL

    var ledgerFile: URL { folder.appendingPathComponent(BudgetLedger.fileName) }
    var ordersFile: URL { folder.appendingPathComponent(DeliveryOrderLog.fileName) }

    init(config: AppConfig = DeliveryToolFixture.config, partner: DeliveryToolPartner = DeliveryToolPartner(),
         places: [Place] = DeliveryToolFixture.places, budgetPartner: BudgetToolPartner = BudgetToolPartner(),
         failingRecord: Bool = false, injectBudget: Bool = false, placesTransport: PlacesTransportStub? = nil) {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let clock = MutableClock()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-tool-\(UUID().uuidString)", isDirectory: true)
        let log = ConnectionLog(fileURL: folder.appendingPathComponent(ConnectionLog.fileName),
                                secrets: { [DeliveryToolFixture.token, DeliveryToolFixture.host] })
        let box = BookingConfigBox(config)
        let reads = self.reads
        let ledger = BudgetLedger(fileURL: folder.appendingPathComponent(BudgetLedger.fileName))
        var write: @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite
        if failingRecord { write = { _, _ in throw DeliveryRecordWriteFailure() } }
        let orders = DeliveryOrderLog(fileURL: folder.appendingPathComponent(DeliveryOrderLog.fileName), write: write)
        // Without an injected budget client the toolbox builds its own from the Store's configuration (no proxy here).
        var budget: (() -> BudgetClient)?
        if injectBudget { budget = { BudgetClient(config: box.config, ledger: ledger, send: budgetPartner.send, connections: log) } }
        // The card's place search reaches the same provider seam as `search_places`: a Places client over a stub transport.
        var search: (() -> PlaceSearch)?
        if let placesTransport {
            search = { PlaceSearch(config: PlacesTestSupport.config, transport: placesTransport.transport, connections: log) }
        }
        let toolbox = AgentToolbox(store: store, now: { clock.now }, timeZone: { clock.zone },
                                   deviceOrigin: { reads.count += 1; return DeliveryToolFixture.device },
                                   places: search,
                                   budget: budget,
                                   delivery: { DeliveryClient(config: box.config, send: partner.send, connections: log) },
                                   deliveryOrders: { orders })
        _ = toolbox.registry.register(places)
        self.store = store
        self.clock = clock
        self.partner = partner
        self.budgetPartner = budgetPartner
        self.ledger = ledger
        self.orders = orders
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

    /// Puts an amount straight into the budget ledger for the week of `week`.
    func hold(_ cents: Int, week: String = BudgetToolFixture.week) {
        ledger.add(BudgetEntry(requestID: UUID().uuidString, weekStart: week, amountCents: cents, isEstimate: false))
    }

    /// The packets once the log has written them.
    func packets() async -> [ConnectionPacket] {
        await log.flush()
        return log.packets
    }

    /// `from>to kind status summary`, one line for each packet.
    func lines() async -> [String] {
        await packets().map { "\($0.from.rawValue)>\($0.to.rawValue) \($0.kind.rawValue) \($0.status.rawValue) \($0.summary)" }
    }

    /// The file names in the test folder other than the connection log and its temporary write files (the log writes in the background).
    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(ConnectionLog.fileName) }.sorted()
    }
}

/// The order in which the stubs were called, for the tests that pin the order of effects.
final class DeliveryCallOrder {
    var lines: [String] = []
}

/// SPEC-DELIVERY-001 AC-DELIVERY-005 to 013: the two declarations, the options tool, the gate of `order_delivery`, the
/// suggestions, the confirmation card and Confirm (the order, the meal entry, the record and the budget hand-off).
@MainActor
final class AgentDeliveryToolTests: XCTestCase {
    private func makeRig(config: AppConfig = DeliveryToolFixture.config, partner: DeliveryToolPartner = DeliveryToolPartner(),
                         places: [Place] = DeliveryToolFixture.places, budgetPartner: BudgetToolPartner = BudgetToolPartner(),
                         failingRecord: Bool = false, injectBudget: Bool = true,
                         placesTransport: PlacesTransportStub? = nil) -> DeliveryToolRig {
        let rig = DeliveryToolRig(config: config, partner: partner, places: places, budgetPartner: budgetPartner,
                                  failingRecord: failingRecord, injectBudget: injectBudget, placesTransport: placesTransport)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    /// The exact re-ask strings of the gate, spelled once for the tests.
    private enum Text {
        static let place = "Call search_places to find the restaurant, then call order_delivery again with the place_id it returns."
        static let time = "Ask the user when the food is to arrive, then call order_delivery again. Do not guess it."
        static let timeForm = "Call order_delivery again with arrive_at as a local date-time in the form YYYY-MM-DDTHH:MM, or ask the user."
        static let window = "Nothing was ordered. Tell the user the arrival time is out of range and ask for a new time, then call order_delivery again. The arrive_at time must be a time that has not passed and be within the next 366 days."
        static let windowAtConfirm = "Nothing was ordered. Tell the user nothing was ordered because the arrival time given in the arrive_at key of this result is out of range, and ask for a new time, then call order_delivery again. The arrive_at time must be a time that has not passed and be within the next 366 days."
        static let optionsFirst = "Call get_delivery_options first, then call order_delivery again with items taken from its answer."
        static let items = "Ask the user what to order, then call order_delivery again with items as comma-separated pairs of an item id from the get_delivery_options answer and a quantity from 1 to 9, 1 to 6 pairs, no spaces, no id repeated. Do not guess it."
        static let itemUnknown = "Call order_delivery again with items that use only item ids from the get_delivery_options answer, or ask the user what to order."
        static let cardUnknown = "Call order_delivery again with a card_id from the get_delivery_options answer, or leave card_id out."
        static let toHandle = "Call search_places for the place to deliver to, then call order_delivery again with its place_id as deliver_to, or leave deliver_to out."
        static let unavailable = "Tell the user delivery is not available right now. Do not call order_delivery again."
        static let optionsUnavailable = "Tell the user delivery is not available right now. Do not call get_delivery_options or order_delivery again."
        static let optionsFailed = "The simulated delivery app could not be reached. Tell the user the delivery options are not available right now."
        static func wrongType(_ param: String) -> String {
            "Call order_delivery again with \(param) as a string. If you do not have it, ask the user; do not guess it."
        }
        static func wrongTypeOmit(_ param: String) -> String {
            "Call order_delivery again with \(param) as a string, or omit it if the user did not give it."
        }
        static let notice = "That start time is now out of range. Nothing was added."
    }

    private func declarations() -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: AgentTools.declarationsJSON())) as? [[String: Any]]) ?? []
    }

    /// The field-card model of a card; a card that is not a field card fails the test here.
    private func model(_ card: AgentCard?, file: StaticString = #filePath, line: UInt = #line) throws -> AgentFieldCard {
        try XCTUnwrap(card?.fieldCard, "the card carries the field-card model", file: file, line: line)
    }

    /// The delivery place on a card: its text and where the value came from.
    private func address(_ card: AgentCard?, file: StaticString = #filePath,
                         line: UInt = #line) throws -> (text: String?, source: AgentFieldSource) {
        let fields = try model(card, file: file, line: line)
        return (fields.values.text("address"), fields.source(of: "address"))
    }

    private var arrivalDate: Date { TestClock.date(DeliveryToolFixture.arrival) }

    /// The text a time row shows (the edit card formats in the device zone, so the tests use the same formatter).
    private func whenText(_ date: Date) -> String { BesirTime.when(date) }

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

    func testO01_FourteenDeclarationsTheDeliveryTwoSitBeforeTheLastTwoAndAreStrict() throws {
        let decls = declarations()
        XCTAssertEqual(decls.count, 14)
        XCTAssertEqual(decls.compactMap { $0["name"] as? String },
                       ["list_activities", "create_activity", "update_activity", "delete_activity", "search_places",
                        "get_travel_time", "check_day_plan", "show_day_plan", "get_budget_left", "record_spend",
                        "get_delivery_options", "order_delivery", "get_partners", "request_partner"])
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tools", withExtension: "json"))
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(recorded.count, 14)
        for index in decls.indices {
            XCTAssertTrue((decls[index] as AnyObject).isEqual(recorded[index]), "declaration \(index) differs from the fixture")
        }
        XCTAssertEqual(decls.last?["name"] as? String, "request_partner")

        let options = decls[10]
        XCTAssertEqual(options["type"] as? String, "function")
        let optionsParameters = try XCTUnwrap(options["parameters"] as? [String: Any])
        XCTAssertEqual((optionsParameters["properties"] as? [String: Any])?.count, 0)
        XCTAssertEqual(optionsParameters["additionalProperties"] as? Bool, false)
        XCTAssertNil(optionsParameters["required"])

        let order = decls[11]
        XCTAssertEqual(order["type"] as? String, "function")
        let orderParameters = try XCTUnwrap(order["parameters"] as? [String: Any])
        XCTAssertEqual(orderParameters["required"] as? [String], ["place_id", "arrive_at", "items"])
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
                       "with items taken from get_delivery_options", "item_id:quantity pairs separated by commas",
                       "Ask the user for the arrival time and the items if they have not said",
                       "card_id is a card_id from get_delivery_options, set only when the user named a card and left out otherwise",
                       "deliver_to is a place_id from search_places, set only when the user named a place to deliver to and left out otherwise",
                       "the app may then suggest a place from the schedule", "Never write an address",
                       "The user confirms before anything is sent, after filling in what is blank"] {
            XCTAssertTrue(orderText.contains(clause), clause)
        }
        XCTAssertFalse(orderText.contains("and the card if they have not said"), "the model is no longer told to ask for the card")
        XCTAssertEqual(orderText, "Order food delivery from a restaurant found with search_places, in a simulated delivery app, with items taken from get_delivery_options. The delivery app is simulated, not a real one: always call the result simulated. items is written as item_id:quantity pairs separated by commas, such as ramen:2,gyoza:1. Ask the user for the arrival time and the items if they have not said. card_id is a card_id from get_delivery_options, set only when the user named a card and left out otherwise. deliver_to is a place_id from search_places, set only when the user named a place to deliver to and left out otherwise; the app may then suggest a place from the schedule. Never write an address. The user confirms before anything is sent, after filling in what is blank.")
        let cardText = try XCTUnwrap((properties["card_id"] as? [String: Any])?["description"] as? String)
        XCTAssertEqual(cardText, "The card to pay with: a card_id from get_delivery_options. Set only when the user named a card. Leave it out otherwise.")
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
        XCTAssertEqual(Array(lines[2...3]), ["3 x Gyoza", "1 x Ramen"], "the lines keep the order given")
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

    func testO08_ACardIdIsOptionalAndAnUnknownOneIsRefused() async throws {
        let rig = makeRig()
        rig.seedDinner()
        await rig.hold()
        // A call with no card id, or a blank one, is no longer refused: the card shows the card blank.
        for card in [rig.order(drop: ["card_id"]).card, rig.order(["card_id": "  "]).card] {
            let fields = try model(card)
            XCTAssertEqual(fields.source(of: "card_id"), .blank)
            XCTAssertNil(fields.values.option("card_id"))
            XCTAssertTrue(fields.lines.contains("Pay with:"))
            XCTAssertFalse(fields.isReady)
        }
        let credit = try model(rig.order(["card_id": "credit-1881", "deliver_to": "p2"]).card)
        XCTAssertTrue(credit.lines.contains("Pay with: \(DeliveryToolPartner.cards[1].label)"))
        XCTAssertEqual(credit.source(of: "card_id"), .stated)
        XCTAssertNotNil(rig.order(["deliver_to": "p2"]).card)
        // An id the held options do not hold is still refused, with the reworded line.
        for id in ["visa", "DEBIT-4242", "debit-4242 ", "credit-1882"] {
            assertRefused(rig.order(["card_id": id]), Text.cardUnknown, id)
        }
        XCTAssertEqual(rig.partner.requests.count, 1, "only the options request")
    }

    func testO09_ANonStringArgumentGetsTheStringMessageAndNeverOmitForARequiredParameter() async {
        let rig = makeRig()
        await rig.hold()
        for param in ["place_id", "arrive_at", "items"] {
            for value in wrongValues {
                let outcome = rig.order([param: value])
                assertRefused(outcome, Text.wrongType(param), "\(param) = \(value)")
                XCTAssertFalse((outcome.message ?? "").contains("omit"))
            }
        }
        // The two optional arguments get the line that says to omit them.
        for param in ["card_id", "deliver_to"] {
            for value in wrongValues {
                let outcome = rig.order([param: value])
                assertRefused(outcome, Text.wrongTypeOmit(param), "\(param) = \(value)")
            }
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
        XCTAssertEqual(card.lines.count, 12, "premise: this is the full field card")
        XCTAssertEqual(card.lines, plain.lines, "an address or a meal key from the model changes nothing on the card")
        XCTAssertFalse(card.lines.joined().contains("SENTINEL"))
        XCTAssertEqual(try model(card).values, try model(plain).values, "nor on the values the card holds")
        XCTAssertEqual(rig.partner.requests.count, 1, "only the options request")
        let sent = String(decoding: try XCTUnwrap(rig.partner.requests.first?.httpBody), as: UTF8.self)
        XCTAssertFalse(sent.contains("SENTINEL"))
    }

    // MARK: O11-O13 the delivery place and the meal entry

    func testO11_ADeliverToHandleGivesTheStatedDeliveryTextOfTheRuleAndTheCardStaysEditable() async throws {
        let rig = makeRig()
        await rig.hold()
        let library = try model(rig.order(["deliver_to": "p2"]).card)
        XCTAssertTrue(library.lines.contains("Delivery place: 9 Library Road"), "the address, shown without a mark")
        XCTAssertEqual(library.source(of: "address"), .stated)
        XCTAssertEqual(library.values.text("address"), "9 Library Road")
        XCTAssertTrue(library.isReady)
        XCTAssertEqual(library.field("address")?.kind, .place, "a named place is still a place the user can change")
        XCTAssertTrue(library.choosePlace("address", DeliveryToolFixture.corner))
        XCTAssertEqual(library.values.text("address"), "Corner Cafe")
        XCTAssertEqual(library.source(of: "address"), .entered)
        XCTAssertEqual(library.values.flag("meal"), true, "the meal entry is still on the card")
        let corner = try model(rig.order(["deliver_to": "p3"]).card)
        XCTAssertEqual(corner.values.text("address"), "Corner Cafe", "no address: the name")
        XCTAssertEqual(corner.source(of: "address"), .stated)
        let harbor = try model(rig.order(["deliver_to": "p5"]).card)
        XCTAssertEqual(harbor.values.text("address"), "Harbor Hall", "an address over 120 scalars falls to the name")
        XCTAssertEqual(harbor.source(of: "address"), .stated)
        for handle in ["p99", "x1", "P2", "library", "r1", "p4"] {
            assertRefused(rig.order(["deliver_to": handle]), Text.toHandle, handle)
        }
        // A blank deliver_to is absent: with no schedule entry the card is returned with the delivery place blank.
        for blank in [rig.order(["deliver_to": "   "]).card, rig.order().card] {
            let fields = try model(blank)
            XCTAssertNil(fields.values.text("address"))
            XCTAssertEqual(fields.source(of: "address"), .blank)
            XCTAssertTrue(fields.lines.contains("Delivery place:"))
            XCTAssertFalse(fields.isReady)
        }
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

    /// A rig whose schedule holds `seeds`, the options held, and the card of the usual call without `deliver_to`.
    private func suggested(_ seeds: [Seed]) async -> (card: AgentCard?, rig: DeliveryToolRig) {
        let rig = makeRig()
        for seed in seeds { rig.seed(seed.title, seed.start, seed.end, place: seed.place) }
        await rig.hold()
        return (rig.order().card, rig)
    }

    func testO12_WithoutDeliverToTheScheduleSuggestsAPlaceOrTheDeliveryPlaceStaysBlank() async throws {
        let library = DeliveryToolFixture.library
        let corner = DeliveryToolFixture.corner
        let dinner = Seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", library)
        let nowEntry = Seed("Study", "2026-10-27T08:00", "2026-10-27T10:00", corner)
        // The entry in progress at the arrival time wins over a different one in progress now.
        let both = await suggested([dinner, nowEntry])
        let bothAddress = try address(both.card)
        XCTAssertEqual(bothAddress.text, "9 Library Road")
        XCTAssertEqual(bothAddress.source, .inferred)
        XCTAssertTrue(try XCTUnwrap(both.card).lines.contains("Delivery place: 9 Library Road"), "no mark on the line")
        XCTAssertTrue(try model(both.card).isReady)
        // With none at the arrival time the entry in progress now is used.
        let nowOnly = await suggested([nowEntry])
        let nowAddress = try address(nowOnly.card)
        XCTAssertEqual(nowAddress.text, "Corner Cafe")
        XCTAssertEqual(nowAddress.source, .inferred)
        // Two different places at one anchor give no suggestion, the later anchor is not used, and the call is not refused.
        let differ = await suggested([dinner, Seed("Other", "2026-10-28T19:30", "2026-10-28T20:30", DeliveryToolFixture.restaurant), nowEntry])
        let differAddress = try address(differ.card)
        XCTAssertNil(differAddress.text)
        XCTAssertEqual(differAddress.source, .blank)
        XCTAssertFalse(try model(differ.card).isReady)
        // Two equal places give one suggestion.
        let same = await suggested([dinner, Seed("Other", "2026-10-28T19:30", "2026-10-28T20:30", library)])
        XCTAssertEqual(try address(same.card).text, "9 Library Road")
        // None at either anchor, no place, no usable text, an ended entry, a future entry and a past one: the card is
        // returned with the delivery place blank.
        let none: [[Seed]] = [
            [],
            [Seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", nil)],
            [Seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", DeliveryToolFixture.noText)],
            [Seed("Ended", "2026-10-28T18:00", "2026-10-28T19:40", library)],
            [Seed("Later", "2026-10-28T19:41", "2026-10-28T21:00", library)],
            [Seed("Past", "2026-10-26T08:00", "2026-10-26T10:00", library)]]
        for (index, seeds) in none.enumerated() {
            let blank = await suggested(seeds)
            let got = try address(blank.card)
            XCTAssertNil(got.text, "case \(index)")
            XCTAssertEqual(got.source, .blank, "case \(index)")
            XCTAssertEqual(blank.rig.partner.requests.count, 1, "case \(index): only the options request")
        }
        // An entry that starts at the arrival minute counts.
        let starts = await suggested([Seed("Starts", "2026-10-28T19:40", "2026-10-28T21:00", library)])
        XCTAssertEqual(try address(starts.card).text, "9 Library Road")
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
        let evening = try model(rig.order(["deliver_to": "p2"]).card)
        XCTAssertEqual(evening.values.flag("meal"), true)
        XCTAssertEqual(evening.source(of: "meal"), .inferred)
        XCTAssertEqual(evening.values.text("meal_title"), "Dinner")
        XCTAssertEqual(evening.source(of: "meal_title"), .inferred)
        XCTAssertEqual(evening.values.date("meal_start"), arrivalDate, "Start is the arrival to begin with")
        XCTAssertEqual(evening.source(of: "meal_start"), .inferred)
        XCTAssertTrue(evening.lines.contains("Add to schedule: Add"))
        XCTAssertTrue(evening.lines.contains("Meal title: Dinner"))
        XCTAssertTrue(evening.lines.contains("Start: \(whenText(arrivalDate))"))
        for (arrive, word) in [("2026-10-27T10:30", "Brunch"), ("2026-10-27T11:00", "Lunch"), ("2026-10-27T14:59", "Lunch"),
                               ("2026-10-27T15:00", "Snack"), ("2026-10-27T16:59", "Snack"), ("2026-10-27T17:00", "Dinner")] {
            let card = try model(rig.order(["arrive_at": arrive, "deliver_to": "p2"]).card)
            XCTAssertEqual(card.values.text("meal_title"), word, arrive)
            XCTAssertEqual(card.values.date("meal_start"), TestClock.date(arrive), arrive)
            XCTAssertTrue(card.lines.contains("Meal title: \(word)"), arrive)
            XCTAssertTrue(card.lines.contains("Start: \(whenText(TestClock.date(arrive)))"), arrive)
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
        let asksForCardOrPlace = try NSRegularExpression(pattern: #"ask the user[^."]*\b(card|deliver)\b"#, options: [.caseInsensitive])
        let planted = "Ask the user which card to pay with."
        XCTAssertEqual(asksForCardOrPlace.numberOfMatches(in: planted, range: NSRange(planted.startIndex..., in: planted)), 1,
                       "the scan can fire")
        for message in messages {
            XCTAssertFalse(message.contains(sentinel), message)
            XCTAssertEqual(asksForCardOrPlace.numberOfMatches(in: message, range: NSRange(message.startIndex..., in: message)), 0, message)
            let words = message.split { !($0.isLetter || $0 == "_") }.map(String.init)
            for word in words where word.contains("_") {
                XCTAssertTrue(declared.contains(word) || toolNames.contains(word), "\(message) names \(word)")
            }
            for other in ["list_activities", "create_activity", "update_activity", "delete_activity", "get_travel_time", "check_day_plan",
                          "show_day_plan", "request_partner", "get_budget_left", "record_spend", "address", "meal"] {
                XCTAssertFalse(message.contains(other), "\(message) names \(other)")
            }
        }
        // The strings of the older tools are unchanged.
        let booking = DeliveryToolRig()
        XCTAssertEqual(booking.call("request_partner", ["partner": "p99"]).message,
                       "Call get_partners first, then call request_partner again with a partner id from its answer.")
        XCTAssertEqual(booking.call("record_spend", ["amount": 5]).message,
                       "Tell the user the budget is not available right now. Do not call get_budget_left or record_spend again.")
        XCTAssertEqual(booking.call("list_activities", ["from": 5]).message, ToolText.wrongType("list_activities", "from"))
        XCTAssertEqual(booking.call("search_places", ["query": 5]).message, ToolText.wrongType("search_places", "query"))
    }

    // MARK: O16-O18 the card

    func testO16_ValidArgumentsReturnAFieldCardWithTheExactLinesAndTheTotalOfTheHeldOptions() async throws {
        let rig = makeRig()
        rig.seedDinner()
        await rig.hold()
        let before = rig.snapshot
        let outcome = rig.order()
        XCTAssertNil(outcome.lookup)
        XCTAssertNil(outcome.resultText)
        let card = try XCTUnwrap(outcome.card)
        let fields = try model(card)
        let when = whenText(arrivalDate)
        XCTAssertEqual(card.lines, ["Order delivery", "Pasta Palace", "2 x Ramen", "1 x Gyoza", "Estimated total $40.00",
                                    "Arrival: \(when)", "Delivery place: 9 Library Road",
                                    "Pay with: \(DeliveryToolPartner.cards[0].label)", "Add to schedule: Add", "Meal title: Dinner",
                                    "Start: \(when)", "Example Delivery - Simulated"])
        XCTAssertTrue(card.showsGoogleMark)
        XCTAssertEqual(card.actions, ["Confirm", "Cancel"])
        XCTAssertTrue(card.canConfirm)
        XCTAssertFalse(fields.isFrozen)
        XCTAssertFalse(card.lines.joined().contains("DL-"), "no order id is on the card")
        XCTAssertFalse(card.lines.joined().contains("suggested"), "no source mark on the card")
        XCTAssertEqual(fields.card.fields.filter { $0.kind != .readonly }.map(\.key),
                       ["arrive_at", "address", "card_id", "meal", "meal_title", "meal_start"])
        // The two chips of the meal switch: the words of the delivery code, the values true and false.
        let chips = try XCTUnwrap(fields.field("meal")?.options)
        XCTAssertEqual(chips.map(\.label), ["Add", "Don't Add"])
        XCTAssertEqual(chips.map(\.value), ["true", "false"])
        // The Meal title holds at most 68 characters: 80 less the ` (Simulated)` suffix.
        XCTAssertEqual(AgentBooking.maxTitle - AgentBooking.simulatedSuffix.count, 68)
        XCTAssertTrue(fields.setText("meal_title", String(repeating: "m", count: 75)))
        XCTAssertEqual(fields.values.text("meal_title")?.count, 68)
        XCTAssertEqual(rig.partner.requests.count, 1, "nothing is sent while the card waits")
        XCTAssertEqual(rig.snapshot, before)
        XCTAssertEqual(rig.files, [])

        // A named delivery place and another card.
        let named = try XCTUnwrap(rig.order(["deliver_to": "p3", "card_id": "credit-1881"]).card)
        XCTAssertEqual(named.lines, ["Order delivery", "Pasta Palace", "2 x Ramen", "1 x Gyoza", "Estimated total $40.00",
                                     "Arrival: \(when)", "Delivery place: Corner Cafe",
                                     "Pay with: \(DeliveryToolPartner.cards[1].label)", "Add to schedule: Add", "Meal title: Dinner",
                                     "Start: \(when)", "Example Delivery - Simulated"])

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
        XCTAssertEqual(resolution.message, Text.windowAtConfirm)
        // The result carries the time the user chose, as a key, so the model does not repeat the time it first asked for.
        XCTAssertEqual(resolution.json?["arrive_at"] as? String, "2026-10-28T19:40")
        XCTAssertEqual(resolution.notice, Text.notice)
        XCTAssertEqual(card.mark, .notApplied)
        XCTAssertEqual(rig.partner.requests.count, sent, "nothing is sent")
        XCTAssertEqual(rig.snapshot, before)
        XCTAssertEqual(rig.files, [])
    }

    // MARK: Confirm helpers

    /// A card for the usual arguments (the dinner on the schedule, the options held).
    private func readyCard(_ rig: DeliveryToolRig, _ over: [String: Any] = [:]) async throws -> AgentCard {
        let made = await rig.readyCard(over)
        return try XCTUnwrap(made)
    }

    private func confirm(_ card: AgentCard) async throws -> AgentResolution {
        let resolved = await card.resolve(.confirm)
        return try XCTUnwrap(resolved)
    }

    /// The meal entry of a confirmed order: the Store activity that is not the seeded dinner.
    private func mealEntry(_ rig: DeliveryToolRig) -> ActivityBlock? {
        rig.store.activities.first { $0.title != "Team dinner" }
    }

    private func isCancelledInFlight() -> () -> Void {
        { withUnsafeCurrentTask { $0?.cancel() } }
    }

    private let withinNotice = "Estimated total $40.00 sent to Example Budget (Simulated): $160.00 left this week."

    // MARK: O19-O20 the order request and the packets

    func testO19_ConfirmSendsOneOrderRequestWithTheExactValuesAndOneSpendOfTheAnsweredTotal() async throws {
        let long = Place(name: "Cafe\u{200B}" + String(repeating: "X", count: 90), address: "2 Long Road", latitude: 37.7, longitude: -122.4)
        let rig = makeRig(places: DeliveryToolFixture.places + [long])
        let card = try await readyCard(rig, ["place_id": "p6"])
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(card.mark, .confirmed)
        XCTAssertEqual(rig.partner.requests.count, 2, "the options request and one order request")
        let body = try XCTUnwrap(rig.partner.body(1))
        XCTAssertEqual(Set(body.keys), ["op", "request_id", "restaurant", "arrive_at", "items", "address", "card_id"])
        XCTAssertEqual(body["op"] as? String, "order")
        XCTAssertEqual(body["restaurant"] as? String, "Cafe" + String(repeating: "X", count: 76), "cleaned and cut to 80 scalars")
        XCTAssertEqual(body["arrive_at"] as? String, DeliveryToolFixture.arrival)
        let lines = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(lines.compactMap { $0["item_id"] as? String }, ["ramen", "gyoza"])
        XCTAssertEqual(lines.compactMap { $0["quantity"] as? Int }, [2, 1])
        XCTAssertTrue(lines.allSatisfy { Set($0.keys) == ["item_id", "quantity"] })
        XCTAssertEqual(body["address"] as? String, "9 Library Road")
        XCTAssertEqual(body["card_id"] as? String, "debit-4242")
        let requestID = try XCTUnwrap(body["request_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: requestID))

        XCTAssertEqual(rig.budgetPartner.requests.count, 1)
        let spend = try XCTUnwrap(rig.budgetPartner.body())
        XCTAssertEqual(Set(spend.keys), ["op", "week_start", "spent_cents", "amount_cents", "request_id"])
        XCTAssertEqual(spend["op"] as? String, "spend")
        XCTAssertEqual(spend["amount_cents"] as? Int, 4000)
        XCTAssertEqual(spend["week_start"] as? String, BudgetToolFixture.week)
        XCTAssertEqual(spend["spent_cents"] as? Int, 0)
        XCTAssertEqual(spend["request_id"] as? String, requestID, "the order's own request id")
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 4000)
        XCTAssertTrue(rig.ledger.hasEstimate(weekStart: BudgetToolFixture.week), "sent as an estimate")

        // The order request and the spend are in one flow.
        let packets = await rig.packets()
        let flows = ConnectionFlows.group(packets)
        XCTAssertEqual(flows.count, 2, "the options exchange and the order")
        let withSpend = flows.filter { $0.packets.contains { $0.summary == "Spend sent" } }
        XCTAssertEqual(withSpend.count, 1)
        XCTAssertTrue(withSpend[0].packets.contains { $0.summary == "Delivery of 3 items requested" })
    }

    func testO20_ThePacketsOfOneOrderCarryOneFlowIdAndReadBesirDeliveryBesirBudgetBesir() async throws {
        let rig = makeRig()
        let card = try await readyCard(rig)
        _ = try await confirm(card)
        let packets = await rig.packets()
        let lines = await rig.lines()
        XCTAssertEqual(lines, [
            "besir>deliveryPartner delivery ok Options requested", "deliveryPartner>besir delivery ok Options received",
            "besir>deliveryPartner delivery ok Delivery of 3 items requested", "deliveryPartner>besir delivery ok Order confirmed",
            "besir>budgetPartner budget ok Spend sent", "budgetPartner>besir budget ok Spend recorded"])
        let flows = ConnectionFlows.group(packets)
        XCTAssertEqual(flows.count, 2)
        let order = try XCTUnwrap(flows.first { $0.packets.contains { $0.summary == "Order confirmed" } })
        XCTAssertEqual(order.packets.count, 4)
        XCTAssertEqual(Set(order.packets.map(\.flowID)).count, 1)
        XCTAssertNotNil(order.packets.first?.flowID)
        XCTAssertEqual(order.chain, [.besir, .deliveryPartner, .besir, .budgetPartner, .besir])
        XCTAssertEqual(ConnectionFlows.chainText(order), "besir → Example Delivery (Simulated) → besir → Example Budget (Simulated) → besir")
    }

    // MARK: O21-O23 the result and the notice

    func testO21_TheAppliedResultHoldsTheKeysAndValuesOfTheSpec() async throws {
        let rig = makeRig()
        let card = try await readyCard(rig)
        let resolution = try await confirm(card)
        XCTAssertEqual(card.mark, .confirmed)
        let json = try XCTUnwrap(resolution.json)
        // The keys of AC-019: the result items in one `results` array beside the unchanged keys, and none of the old estimate keys.
        XCTAssertEqual(Set(json.keys), ["status", "partner", "simulated", "order_id", "restaurant", "items", "address",
                                        "card", "results", "message", "budget", "meal"])
        for old in ["arrival_estimate", "estimated_total", "estimate", "estimated_total_cents"] {
            XCTAssertNil(json[old], old)
        }
        XCTAssertNil(json["people"])
        XCTAssertEqual(json["status"] as? String, "applied")
        XCTAssertEqual(json["partner"] as? String, DeliveryClient.partnerName)
        XCTAssertEqual(json["simulated"] as? Bool, true)
        XCTAssertEqual(json["order_id"] as? String, "DL-AB12CD")
        XCTAssertEqual(json["restaurant"] as? String, "Pasta Palace")
        // Every result item is a fact for the model: the time as text, the money through `AgentBudget.dollars`, the text as it is.
        let results = try XCTUnwrap(json["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { Set($0.keys) == ["name", "kind", "value"] })
        XCTAssertEqual(results.compactMap { $0["name"] as? String }, ["Arrival", "Estimated total", "Status"])
        XCTAssertEqual(results.compactMap { $0["kind"] as? String }, ["time", "money", "text"])
        XCTAssertEqual(results.compactMap { $0["value"] as? String }, [DeliveryToolFixture.arrival, "$40.00", "Preparing"])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["name"] as? String }, ["Ramen", "Gyoza"])
        XCTAssertEqual(items.compactMap { $0["quantity"] as? Int }, [2, 1])
        XCTAssertTrue(items.allSatisfy { Set($0.keys) == ["name", "quantity"] })
        XCTAssertEqual(json["address"] as? String, "9 Library Road")
        XCTAssertEqual(json["card"] as? String, DeliveryToolPartner.cards[0].label)
        let entry = try XCTUnwrap(mealEntry(rig))
        let meal = try XCTUnwrap(json["meal"] as? [String: Any])
        XCTAssertEqual(Set(meal.keys), ["status", "id", "title", "start", "end"])
        XCTAssertEqual(meal["status"] as? String, "added")
        XCTAssertEqual(meal["id"] as? String, entry.id.uuidString)
        XCTAssertEqual(meal["title"] as? String, "Dinner (Simulated)")
        XCTAssertEqual(meal["start"] as? String, DeliveryToolFixture.arrival)
        XCTAssertEqual(meal["end"] as? String, "2026-10-28T20:40")
        let budget = try XCTUnwrap(json["budget"] as? [String: Any])
        XCTAssertEqual(Set(budget.keys), ["simulated", "status", "week", "includes_estimate", "left"])
        XCTAssertEqual(budget["simulated"] as? Bool, true)
        XCTAssertEqual(budget["status"] as? String, "recorded")
        XCTAssertEqual(budget["week"] as? String, "this week")
        XCTAssertEqual(budget["includes_estimate"] as? Bool, true)
        XCTAssertEqual(budget["left"] as? String, "$160.00")
        XCTAssertEqual(json["message"] as? String,
                       AgentDelivery.appliedMessage + " " + AgentDelivery.mealAddedSentence + " " + AgentDelivery.budgetRecordedSentence)
        XCTAssertTrue(AgentDelivery.budgetRecordedSentence.contains("Do not call record_spend for this order"))
    }

    func testO22_TheNoticeWithinTheBudget() async throws {
        let rig = makeRig()
        let card = try await readyCard(rig)
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.notice, withinNotice)
    }

    func testO23_TheOverFormAndTheForTheWeekOfFormForAnArrivalInTheNextWeek() async throws {
        let over = makeRig()
        over.hold(18500)
        let first = try await confirm(try await readyCard(over))
        XCTAssertEqual(first.notice, "Estimated total $40.00 sent to Example Budget (Simulated): $25.00 over the budget this week.")
        let overBlock = try XCTUnwrap(first.json?["budget"] as? [String: Any])
        XCTAssertEqual(Set(overBlock.keys), ["simulated", "status", "week", "includes_estimate", "over_by"])
        XCTAssertEqual(overBlock["over_by"] as? String, "$25.00")
        XCTAssertNil(overBlock["left"])

        let next = makeRig()
        let second = try await confirm(try await readyCard(next, ["arrive_at": "2026-11-02T19:40", "deliver_to": "p2"]))
        XCTAssertEqual(second.notice, "Estimated total $40.00 sent to Example Budget (Simulated): $160.00 left for the week of Nov 2.")
        XCTAssertEqual((second.json?["budget"] as? [String: Any])?["week"] as? String, "week of Nov 2")
        XCTAssertEqual(next.budgetPartner.body()?["week_start"] as? String, "2026-11-02")
        XCTAssertEqual(next.ledger.spentCents(weekStart: "2026-11-02"), 4000)
        XCTAssertEqual(next.ledger.spentCents(weekStart: BudgetToolFixture.week), 0)

        let nextOver = makeRig()
        nextOver.hold(18500, week: "2026-11-02")
        let third = try await confirm(try await readyCard(nextOver, ["arrive_at": "2026-11-02T19:40", "deliver_to": "p2"]))
        XCTAssertEqual(third.notice,
                       "Estimated total $40.00 sent to Example Budget (Simulated): $25.00 over the budget for the week of Nov 2.")
    }

    // MARK: O24-O26 declined, failed, cancelled

    func testO24_ADeclinedOrderGivesTheDeclinedResultAndWritesAndSendsNothingMore() async throws {
        let rig = makeRig()
        let card = try await readyCard(rig, ["arrive_at": "2026-10-28T23:30", "deliver_to": "p2"])
        let before = rig.snapshot
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.status, "declined")
        XCTAssertEqual(Set(try XCTUnwrap(resolution.json).keys), ["status", "partner", "simulated", "message"])
        XCTAssertEqual(resolution.json?["partner"] as? String, DeliveryClient.partnerName)
        XCTAssertEqual(resolution.json?["simulated"] as? Bool, true)
        XCTAssertEqual(resolution.message, AgentDelivery.declinedMessage)
        XCTAssertNil(resolution.notice)
        XCTAssertEqual(card.mark, .notApplied)
        XCTAssertEqual(rig.partner.requests.count, 2, "the options request and the one order request")
        XCTAssertEqual(rig.snapshot, before, "no entry")
        XCTAssertTrue(rig.orders.orders.isEmpty)
        XCTAssertEqual(rig.budgetPartner.requests.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ordersFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ledgerFile.path))
        let lines = await rig.lines()
        XCTAssertEqual(Array(lines.suffix(2)), ["besir>deliveryPartner delivery ok Delivery of 3 items requested",
                                                 "deliveryPartner>besir delivery declined Order not available"])
        XCTAssertEqual(lines.count, 4, "no budget packet")
    }

    func testO25_AFailedRequestOrADifferentTotalGivesUnavailableAndWritesNothing() async throws {
        let failures: [(String, DeliveryToolPartner.Mode, Int)] = [
            ("offline", .error(URLError(.notConnectedToInternet)), 0), ("404", .status(404, "Not found"), 0),
            ("500", .status(500, "oops"), 0), ("401", .status(401, "{\"error\":\"unauthorized\"}"), 0),
            ("wrong shape", .status(200, "{\"partner\":\"Example Delivery\"}"), 0), ("a different total", .worker, 1)]
        for (name, mode, delta) in failures {
            let rig = makeRig()
            let card = try await readyCard(rig)
            let before = rig.snapshot
            rig.partner.mode = mode
            rig.partner.totalDelta = delta
            let resolution = try await confirm(card)
            XCTAssertEqual(resolution.status, "unavailable", name)
            XCTAssertEqual(Set(try XCTUnwrap(resolution.json).keys), ["status", "partner", "simulated", "message"], name)
            XCTAssertEqual(resolution.message, AgentDelivery.unavailableMessage, name)
            XCTAssertEqual(resolution.notice, "The delivery could not be ordered. Nothing was ordered.", name)
            XCTAssertEqual(card.mark, .notApplied, name)
            XCTAssertEqual(rig.snapshot, before, name)
            XCTAssertTrue(rig.orders.orders.isEmpty, name)
            XCTAssertEqual(rig.budgetPartner.requests.count, 0, name)
            XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 0, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ledgerFile.path), name)
            let lines = await rig.lines()
            XCTAssertEqual(lines.last, "besir>deliveryPartner delivery failed Request failed", name)
            XCTAssertFalse(lines.contains { $0.contains("budget") }, name)
        }
    }

    func testO26_ATaskCancelledWhileTheOrderRequestIsInFlightGivesUnavailableAndWritesNothing() async throws {
        let rig = makeRig()
        let card = try await readyCard(rig)
        let before = rig.snapshot
        rig.partner.duringSend = isCancelledInFlight()
        let task = Task { await card.resolve(.confirm) }
        let resolved = await task.value
        let resolution = try XCTUnwrap(resolved)
        XCTAssertEqual(resolution.status, "unavailable")
        XCTAssertEqual(resolution.message, AgentDelivery.unavailableMessage)
        XCTAssertEqual(resolution.notice, "The delivery could not be ordered. Nothing was ordered.")
        XCTAssertEqual(card.mark, .notApplied)
        XCTAssertEqual(rig.snapshot, before)
        XCTAssertTrue(rig.orders.orders.isEmpty)
        XCTAssertEqual(rig.budgetPartner.requests.count, 0)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 0)
        let lines = await rig.lines()
        XCTAssertEqual(lines, ["besir>deliveryPartner delivery ok Options requested", "deliveryPartner>besir delivery ok Options received"],
                       "no delivery packet for the cancelled order")
    }

    // MARK: O27-O28 the meal entry and the record

    func testO27_AConfirmedOrderWritesOneStoreActivityThroughTheBookingWriteAndItStaysWhenTheBudgetFails() async throws {
        let rig = makeRig()
        let card = try await readyCard(rig)
        let resolution = try await confirm(card)
        let activities = rig.store.activities
        XCTAssertEqual(activities.count, 2, "the seeded dinner and one meal entry")
        XCTAssertEqual(activities.filter { $0.title == "Dinner (Simulated)" }.count, 1)
        let entry = try XCTUnwrap(activities.first { $0.title == "Dinner (Simulated)" })
        XCTAssertEqual(entry.startDate, TestClock.date(DeliveryToolFixture.arrival))
        XCTAssertEqual(entry.endDate, TestClock.date("2026-10-28T20:40"))
        XCTAssertNil(entry.location, "no place")
        XCTAssertEqual(entry.syncToCalendar, rig.store.calendarSyncDefault)
        XCTAssertTrue(rig.store.events.filter { $0.linkedActivityId == entry.id }.isEmpty, "no travel leg")
        XCTAssertEqual((resolution.json?["meal"] as? [String: Any])?["id"] as? String, entry.id.uuidString)

        let failing = makeRig()
        failing.budgetPartner.mode = .status(500, "oops")
        let failedResolution = try await confirm(try await readyCard(failing))
        XCTAssertEqual(failedResolution.status, "applied")
        let kept = try XCTUnwrap(failing.store.activities.first { $0.title == "Dinner (Simulated)" })
        XCTAssertEqual((failedResolution.json?["meal"] as? [String: Any])?["id"] as? String, kept.id.uuidString)
        XCTAssertEqual(failing.store.activities.count, 2)
    }

    func testO28_TheRecordIsAppendedAfterTheConfirmedAnswerAndBeforeTheBudgetRequestWithTheFieldsOfL17() async throws {
        let rig = makeRig()
        let card = try await readyCard(rig)
        let order = DeliveryCallOrder()
        let orders = rig.orders
        rig.partner.duringSend = { order.lines.append("order request, record count \(orders.orders.count)") }
        rig.budgetPartner.duringSend = {
            let record = orders.orders
            order.lines.append("spend, record count \(record.count), meal id \(record.first?.mealActivityID ?? "none")")
        }
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.status, "applied")
        let entry = try XCTUnwrap(mealEntry(rig))
        XCTAssertEqual(order.lines, ["order request, record count 0", "spend, record count 1, meal id \(entry.id.uuidString)"],
                       "the entry and the record are there when the spend is sent")
        let requestID = try XCTUnwrap(rig.partner.body(1)?["request_id"] as? String)
        XCTAssertEqual(rig.orders.orders, [DeliveryOrderEntry(
            orderID: "DL-AB12CD", requestID: requestID, placeName: "Pasta Palace", arrival: DeliveryToolFixture.arrival,
            items: [DeliveryOrderItem(itemID: "ramen", name: "Ramen", quantity: 2, unitPriceCents: 1400),
                    DeliveryOrderItem(itemID: "gyoza", name: "Gyoza", quantity: 1, unitPriceCents: 700)],
            address: "9 Library Road", cardLabel: DeliveryToolPartner.cards[0].label, estimatedTotalCents: 4000,
            createdAt: rig.clock.now, mealActivityID: entry.id.uuidString)])
        let data = try Data(contentsOf: rig.ordersFile)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(Set(stored[0].keys), ["orderID", "requestID", "placeName", "arrival", "items", "address", "cardLabel",
                                              "estimatedTotalCents", "createdAt", "mealActivityID"])

        // None after a decline or a failure.
        let declined = makeRig()
        _ = try await confirm(try await readyCard(declined, ["arrive_at": "2026-10-28T23:30", "deliver_to": "p2"]))
        XCTAssertTrue(declined.orders.orders.isEmpty)
        let failed = makeRig()
        let failedCard = try await readyCard(failed)
        failed.partner.mode = .status(500, "oops")
        _ = try await confirm(failedCard)
        XCTAssertTrue(failed.orders.orders.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.ordersFile.path))

        // A failed write of the record changes neither the result nor the entry.
        let broken = makeRig(failingRecord: true)
        let brokenCard = try await readyCard(broken)
        let brokenResolution = try await confirm(brokenCard)
        XCTAssertEqual(brokenResolution.status, "applied")
        XCTAssertEqual(brokenCard.mark, .confirmed)
        XCTAssertEqual(brokenResolution.notice, withinNotice)
        XCTAssertEqual((brokenResolution.json?["meal"] as? [String: Any])?["status"] as? String, "added")
        XCTAssertEqual((brokenResolution.json?["budget"] as? [String: Any])?["status"] as? String, "recorded")
        XCTAssertNotNil(broken.store.activities.first { $0.title == "Dinner (Simulated)" })
        XCTAssertEqual(broken.budgetPartner.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.ordersFile.path))
    }

    // MARK: O29-O30 the budget hand-off fails

    func testO29_ABudgetFailureLeavesTheOrderAppliedAndSaysSo() async throws {
        let modes: [(String, BudgetToolPartner.Mode)] = [
            ("offline", .error(URLError(.notConnectedToInternet))), ("missing route", .status(404, "Not found")),
            ("server", .status(500, "oops")), ("bad body", .status(200, "[]"))]
        for (name, mode) in modes {
            let rig = makeRig()
            rig.budgetPartner.mode = mode
            let card = try await readyCard(rig)
            let resolution = try await confirm(card)
            XCTAssertEqual(resolution.status, "applied", name)
            XCTAssertEqual(card.mark, .confirmed, name)
            XCTAssertEqual(resolution.notice, "The estimated total could not be sent to Example Budget (Simulated).", name)
            XCTAssertNotNil(rig.store.activities.first { $0.title == "Dinner (Simulated)" }, name)
            XCTAssertEqual(rig.orders.orders.count, 1, name)
            let json = try XCTUnwrap(resolution.json, name)
            XCTAssertEqual(json["order_id"] as? String, "DL-AB12CD", name)
            let block = try XCTUnwrap(json["budget"] as? [String: Any], name)
            XCTAssertEqual(Set(block.keys), ["simulated", "status"], name)
            XCTAssertEqual(block["status"] as? String, "unavailable", name)
            XCTAssertEqual(block["simulated"] as? Bool, true, name)
            XCTAssertEqual(json["message"] as? String,
                           AgentDelivery.appliedMessage + " " + AgentDelivery.mealAddedSentence + " " + AgentDelivery.budgetUnavailableSentence, name)
            XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 0, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ledgerFile.path), name)
            let lines = await rig.lines()
            XCTAssertEqual(lines.last, "besir>budgetPartner budget failed Request failed", name)
        }
    }

    func testO30_ATaskCancelledWhileTheBudgetRequestIsInFlightLeavesTheOrderAppliedWithNoBudgetNotice() async throws {
        let rig = makeRig()
        let card = try await readyCard(rig)
        rig.budgetPartner.duringSend = isCancelledInFlight()
        let task = Task { await card.resolve(.confirm) }
        let resolved = await task.value
        let resolution = try XCTUnwrap(resolved)
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(card.mark, .confirmed)
        XCTAssertNil(resolution.notice, "a cancelled task says nothing about the budget")
        let block = try XCTUnwrap(resolution.json?["budget"] as? [String: Any])
        XCTAssertEqual(Set(block.keys), ["simulated", "status"])
        XCTAssertEqual(block["status"] as? String, "unavailable")
        XCTAssertNotNil(rig.store.activities.first { $0.title == "Dinner (Simulated)" })
        XCTAssertEqual(rig.orders.orders.count, 1)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ledgerFile.path))
        let packets = await rig.packets()
        XCTAssertTrue(packets.filter { $0.kind == .budget }.isEmpty, "no budget packet")
    }

    // MARK: O31 privacy

    func testO31_TheDeliveryTextItemsAndCardReachOnlyTheOrderRequestAndTheDevice() async throws {
        let place = Place(name: "Sentinel Bistro 77", address: "SENTINEL-PLACE-ADDRESS-1", latitude: 37.74, longitude: -122.37)
        let rig = makeRig(places: DeliveryToolFixture.places + [place])
        rig.seedDinner()
        await rig.hold()
        let card = try XCTUnwrap(rig.order(["place_id": "p6"]).card)
        let address = "SENTINEL-ADDRESS-1"
        let picked = Place(name: "Sentinel Pick", address: address, latitude: 37.5, longitude: -122.4)
        XCTAssertTrue(try model(card).choosePlace("address", picked))
        let cardText = card.lines.joined(separator: "\n")
        for part in [address, "Sentinel Bistro 77", "2 x Ramen", "1 x Gyoza", "Pay with: " + DeliveryToolPartner.cards[0].label] {
            XCTAssertTrue(cardText.contains(part), part)
        }
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.status, "applied")

        // Present: the order request, the applied result and the record.
        let sent = String(decoding: try XCTUnwrap(rig.partner.requests.dropFirst().first?.httpBody), as: UTF8.self)
        for part in [address, "Sentinel Bistro 77", "ramen", "gyoza", "debit-4242"] { XCTAssertTrue(sent.contains(part), part) }
        for part in [address, "Sentinel Bistro 77", "Ramen", "Gyoza", DeliveryToolPartner.cards[0].label] {
            XCTAssertTrue(resolution.result.contains(part), part)
        }
        let recordData = String(decoding: try Data(contentsOf: rig.ordersFile), as: UTF8.self)
        for part in [address, "Sentinel Bistro 77", "Ramen", "Gyoza", "ramen", DeliveryToolPartner.cards[0].label] {
            XCTAssertTrue(recordData.contains(part), part)
        }

        // Absent: the packets, the budget request, budget.json, the Store entry and the notice.
        let packets = await rig.packets()
        let entry = try XCTUnwrap(mealEntry(rig))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let budgetBody = String(decoding: try XCTUnwrap(rig.budgetPartner.requests.first?.httpBody), as: UTF8.self)
        let elsewhere: [(String, String)] = [
            ("packets", packets.map(\.summary).joined(separator: "\n")),
            ("connections.json", String(decoding: try Data(contentsOf: rig.folder.appendingPathComponent(ConnectionLog.fileName)), as: UTF8.self)),
            ("budget request", budgetBody),
            ("budget.json", String(decoding: try Data(contentsOf: rig.ledgerFile), as: UTF8.self)),
            ("store entry", String(decoding: try encoder.encode(entry), as: UTF8.self)),
            ("notice", resolution.notice ?? "")]
        let personal = [address, "Sentinel Bistro 77", "SENTINEL-PLACE-ADDRESS-1", "Ramen", "Gyoza", "ramen", "gyoza", "debit-4242",
                        "Example Debit", "DL-AB12CD"]
        for (name, text) in elsewhere {
            XCTAssertFalse(text.isEmpty, name)
            for part in personal { XCTAssertFalse(text.contains(part), "\(name) holds \(part)") }
        }
        // The device position is never read, and its sentinels are nowhere.
        XCTAssertEqual(rig.reads.count, 0)
        let everything = elsewhere.map(\.1) + [sent, resolution.result, recordData, cardText]
        for text in everything { XCTAssertFalse(text.contains("SENTINEL-HOME"), text) }
        XCTAssertFalse(sent.contains("SENTINEL-PLACE-ADDRESS-1"), "the restaurant's own address is not sent")
        XCTAssertFalse(sent.contains("DL-"))
    }

    // MARK: O32-O33 the texts

    func testO32_EveryFixedTextIsEnglishHoldsNoAdviceWordAndMarksSimulatedAndEstimates() async throws {
        let banned = try NSRegularExpression(
            pattern: #"\b(should|recommend|advise|afford|save|invest|cut back|stop spending|overspend|calorie|nutrition|healthy)\b"#,
            options: [.caseInsensitive])
        func hits(_ text: String) -> Int { banned.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) }
        func hangul(_ text: String) -> Int {
            text.unicodeScalars.filter { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }.count
        }
        // The scans can fire.
        XCTAssertEqual(hits("You should save and invest. Do not overspend. Stop spending, cut back, afford it, advise, recommend. Calorie, nutrition, healthy."), 12)
        XCTAssertEqual(hits("Give no advice about savings or the saved amount."), 0)
        XCTAssertEqual(hangul("abc \u{D55C}\u{AE00}"), 2)

        var texts: [String] = [
            AgentDelivery.optionsMessage, AgentDelivery.optionsUnavailableMessage, AgentDelivery.appliedMessage,
            AgentDelivery.mealAddedSentence, AgentDelivery.mealMissedSentence, AgentDelivery.declinedMessage,
            AgentDelivery.unavailableMessage, AgentDelivery.unavailableNotice, AgentDelivery.editRejectedMessage,
            AgentDelivery.budgetRecordedSentence, AgentDelivery.budgetUnavailableSentence, AgentDelivery.budgetFailureNotice,
            AgentDelivery.partnerLine, AgentDelivery.mealSwitchLabel, AgentDelivery.mealTitleLabel, AgentDelivery.mealStartLabel]
        XCTAssertEqual([AgentDelivery.mealSwitchLabel, AgentDelivery.mealTitleLabel, AgentDelivery.mealStartLabel],
                       ["Add to schedule", "Meal title", "Start"])
        // The model-facing texts that the field card changed, word for word.
        XCTAssertEqual(AgentDelivery.optionsMessage, "State the items with their estimated prices, the estimated delivery fee and the cards as facts, and say the delivery app is simulated and every price an estimate. Ask the user what to order and when it is to arrive. Do not ask which card or where to deliver: the user chooses them on the order card. Give no advice.")
        XCTAssertEqual(AgentDelivery.appliedMessage, "Tell the user the delivery is ordered with a simulated delivery app. Give the order id, the items, the delivery place (the address field) and each result item, and say any amount is an estimate. Give no advice.")
        XCTAssertEqual(AgentDelivery.editRejectedMessage, "A required value of the order card was empty. Tell the user nothing was ordered.")

        // The texts a run produces: the card, the results, the notices and the refusals.
        let rig = makeRig()
        let card = try await readyCard(rig)
        texts += card.lines
        let applied = try await confirm(card)
        texts += [applied.result, applied.notice ?? ""]
        let over = makeRig()
        over.hold(18500)
        let overResolution = try await confirm(try await readyCard(over))
        texts += [overResolution.result, overResolution.notice ?? ""]
        let next = makeRig()
        let nextResolution = try await confirm(try await readyCard(next, ["arrive_at": "2026-11-02T19:40", "deliver_to": "p2"]))
        texts += [nextResolution.result, nextResolution.notice ?? ""]
        let down = makeRig()
        down.budgetPartner.mode = .status(500, "oops")
        let downResolution = try await confirm(try await readyCard(down))
        texts += [downResolution.result, downResolution.notice ?? ""]
        let declined = makeRig()
        let declinedResolution = try await confirm(try await readyCard(declined, ["arrive_at": "2026-10-28T23:30", "deliver_to": "p2"]))
        texts += [declinedResolution.result]
        let failed = makeRig()
        let failedCard = try await readyCard(failed)
        failed.partner.mode = .status(500, "oops")
        let failedResolution = try await confirm(failedCard)
        texts += [failedResolution.result, failedResolution.notice ?? ""]
        let held = makeRig()
        let options = await held.run(held.call("get_delivery_options"))
        texts.append(String(decoding: try JSONSerialization.data(withJSONObject: try XCTUnwrap(options)), as: UTF8.self))
        for outcome in [makeRig().order(), makeRig().order(["place_id": "p99"]), makeRig(config: DeliveryToolFixture.unconfigured).order(),
                        held.order(["items": "sushi:1"]), held.order(["card_id": "visa"]), held.order(["deliver_to": "p4"]),
                        held.order(drop: ["arrive_at"]), makeRig(config: DeliveryToolFixture.unconfigured).call("get_delivery_options")] {
            texts.append(outcome.message ?? "")
        }
        for decl in declarations() where ["get_delivery_options", "order_delivery"].contains(decl["name"] as? String ?? "") {
            texts.append(decl["description"] as? String ?? "")
            let properties = (decl["parameters"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            texts += properties.values.compactMap { ($0 as? [String: Any])?["description"] as? String }
        }
        XCTAssertGreaterThan(texts.count, 40)
        let asksForCardOrPlace = try NSRegularExpression(pattern: #"ask the user[^."]*\b(card|deliver)\b"#, options: [.caseInsensitive])
        for text in texts {
            XCTAssertEqual(hits(text), 0, text)
            XCTAssertEqual(hangul(text), 0, text)
            XCTAssertEqual(asksForCardOrPlace.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)), 0, text)
        }

        // Simulated and estimate where the SPEC requires them.
        for text in [AgentDelivery.optionsMessage, AgentDelivery.appliedMessage, AgentDelivery.budgetRecordedSentence,
                     AgentDelivery.budgetUnavailableSentence] {
            XCTAssertTrue(text.lowercased().contains("estimate"), text)
            XCTAssertTrue(text.lowercased().contains("simulated"), text)
        }
        for text in [AgentDelivery.declinedMessage, AgentDelivery.unavailableMessage, AgentDelivery.optionsUnavailableMessage] {
            XCTAssertTrue(text.lowercased().contains("simulated"), text)
        }
        XCTAssertEqual(AgentDelivery.partnerLine, "\(DeliveryClient.partnerName) - Simulated")
        XCTAssertEqual(card.lines.last, AgentDelivery.partnerLine)
        XCTAssertEqual(AgentDelivery.budgetFailureNotice, "The estimated total could not be sent to \(BudgetClient.partnerName) (Simulated).")
        XCTAssertEqual(applied.notice, "Estimated total $40.00 sent to \(BudgetClient.partnerName) (Simulated): $160.00 left this week.")
        XCTAssertEqual(overResolution.notice, "Estimated total $40.00 sent to \(BudgetClient.partnerName) (Simulated): $25.00 over the budget this week.")
        for notice in [applied.notice, overResolution.notice, nextResolution.notice, downResolution.notice] {
            let text = try XCTUnwrap(notice)
            XCTAssertTrue(text.contains("(Simulated)") && text.lowercased().contains("estimated total"), text)
        }
        XCTAssertTrue(DeliveryToolPartner.cards.allSatisfy { $0.label.contains("(Simulated)") })
        let appliedResults = try XCTUnwrap(applied.json?["results"] as? [[String: Any]])
        XCTAssertEqual(appliedResults.compactMap { $0["value"] as? String }, [DeliveryToolFixture.arrival, "$40.00", "Preparing"])
        XCTAssertNil(applied.json?["estimated_total"])
        XCTAssertNil(applied.json?["estimate"])
        for resolution in [applied, declinedResolution, failedResolution] {
            XCTAssertEqual(resolution.json?["simulated"] as? Bool, true)
            XCTAssertEqual(resolution.json?["partner"] as? String, DeliveryClient.partnerName)
        }
        let optionsJSON = try XCTUnwrap(options)
        XCTAssertEqual(optionsJSON["simulated"] as? Bool, true)
        XCTAssertNotNil(optionsJSON["estimated_delivery_fee"])
        XCTAssertTrue((optionsJSON["menu"] as? [[String: Any]] ?? []).allSatisfy { $0["estimated_price"] != nil })
        XCTAssertEqual((applied.json?["meal"] as? [String: Any])?["title"] as? String, "Dinner (Simulated)")
        XCTAssertEqual(DeliveryClient.partnerName, "Example Delivery")
    }

    func testO33_TheSessionNamesTheTwoNewToolCallsInPlainWords() {
        XCTAssertEqual(AgentSession.toolCallSummary("get_delivery_options"), "get delivery options")
        XCTAssertEqual(AgentSession.toolCallSummary("order_delivery"), "order delivery")
        XCTAssertEqual(AgentSession.toolCallSummary("order_delivery_now"), "Unknown tool")
        XCTAssertEqual(AgentSession.toolCallStatus("applied"), .ok)
        XCTAssertEqual(AgentSession.toolCallStatus("declined"), .declined)
        XCTAssertEqual(AgentSession.toolCallStatus("unavailable"), .failed)
    }

    // MARK: O34-O35 the edits at Confirm

    func testO34_ThePickedDeliveryPlaceIsSentRecordedAndReturnedAsTheOneCleanedSnapshot() async throws {
        // A pick whose address holds a hidden character and spaces at both ends: sent as the cleaned text, and the same string
        // comes back.
        let picked = makeRig()
        let card = try await readyCard(picked)
        let fields = try model(card)
        XCTAssertEqual(fields.values.text("address"), "9 Library Road", "premise: the schedule's suggestion is on the card")
        let place = Place(name: "Picked", address: "  12 Example\u{0007} Street  ", latitude: 37.5, longitude: -122.4)
        XCTAssertTrue(fields.choosePlace("address", place))
        XCTAssertEqual(fields.values.text("address"), "12 Example Street")
        XCTAssertEqual(fields.source(of: "address"), .entered)
        XCTAssertTrue(card.lines.contains("Delivery place: 12 Example Street"))
        XCTAssertFalse(card.lines.joined().contains("suggested"), "an edited place carries no mark")
        XCTAssertTrue(card.canConfirm)
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.status, "applied", "the cleaned text is the one the partner echoes")
        XCTAssertEqual(picked.partner.body(1)?["address"] as? String, "12 Example Street")
        XCTAssertEqual(resolution.json?["address"] as? String, "12 Example Street")
        XCTAssertEqual(picked.orders.orders.first?.address, "12 Example Street")

        // A text over 120 scalars falls to the name; a place with no usable text is refused and the value stays; an address of
        // exactly 120 scalars is sent whole.
        let long = makeRig()
        let longCard = try await readyCard(long)
        let longFields = try model(longCard)
        XCTAssertTrue(longFields.choosePlace("address", Place(name: "Long Name", address: String(repeating: "A", count: 130),
                                                              latitude: 37.5, longitude: -122.4)))
        XCTAssertEqual(longFields.values.text("address"), "Long Name")
        XCTAssertFalse(longFields.choosePlace("address", DeliveryToolFixture.noText))
        XCTAssertEqual(longFields.values.text("address"), "Long Name")
        XCTAssertTrue(longFields.choosePlace("address", Place(name: "Exact", address: String(repeating: "A", count: 120),
                                                              latitude: 37.5, longitude: -122.4)))
        XCTAssertEqual(longFields.values.text("address")?.unicodeScalars.count, 120)
        _ = try await confirm(longCard)
        XCTAssertEqual(long.partner.body(1)?["address"] as? String, String(repeating: "A", count: 120))

        // An unedited suggestion is sent as suggested.
        let plain = makeRig()
        let plainCard = try await readyCard(plain)
        XCTAssertTrue(plainCard.lines.contains("Delivery place: 9 Library Road"))
        _ = try await confirm(plainCard)
        XCTAssertEqual(plain.partner.body(1)?["address"] as? String, "9 Library Road")

        // A blank place cannot be confirmed; forced, it is rejected and nothing is sent or written.
        let blank = makeRig()
        await blank.hold()
        let blankCard = try XCTUnwrap(blank.order().card)
        XCTAssertEqual(blankCard.lines.count, 12, "premise: the full card, with the place blank")
        XCTAssertEqual(try model(blankCard).source(of: "address"), .blank)
        XCTAssertFalse(blankCard.canConfirm)
        let before = blank.snapshot
        let rejected = try await confirm(blankCard)
        XCTAssertEqual(rejected.status, "rejected")
        XCTAssertEqual(rejected.message, AgentDelivery.editRejectedMessage)
        XCTAssertNil(rejected.notice)
        XCTAssertEqual(blankCard.mark, .notApplied)
        XCTAssertEqual(blank.partner.requests.count, 1, "only the options request")
        XCTAssertEqual(blank.budgetPartner.requests.count, 0)
        XCTAssertEqual(blank.snapshot, before)
        XCTAssertTrue(blank.orders.orders.isEmpty)

        // The model's undeclared address key changes nothing.
        let undeclared = makeRig()
        undeclared.seedDinner()
        await undeclared.hold()
        let undeclaredCard = try XCTUnwrap(undeclared.order(["address": "SENTINEL-ADDRESS-2", "meal": "SENTINEL-MEAL-2"]).card)
        _ = try await confirm(undeclaredCard)
        XCTAssertEqual(undeclared.partner.body(1)?["address"] as? String, "9 Library Road")
        for request in undeclared.partner.requests + undeclared.budgetPartner.requests {
            XCTAssertFalse(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("SENTINEL"))
        }

        // An edit made while the order request is in flight changes none of request, record or result.
        let moving = makeRig()
        let movingCard = try await readyCard(moving)
        let movingFields = try model(movingCard)
        moving.partner.whileSending = { _ = movingFields.choosePlace("address", DeliveryToolFixture.corner) }
        let movingResolution = try await confirm(movingCard)
        XCTAssertEqual(movingResolution.status, "applied")
        XCTAssertEqual(moving.partner.body(1)?["address"] as? String, "9 Library Road")
        XCTAssertEqual(movingResolution.json?["address"] as? String, "9 Library Road")
        XCTAssertEqual(moving.orders.orders.first?.address, "9 Library Road")
        XCTAssertEqual(movingFields.values.text("address"), "9 Library Road", "frozen at the tap")
        XCTAssertTrue(movingCard.lines.contains("Delivery place: 9 Library Road"))
    }

    func testO35_TheMealSwitchTitleAndStartAreWrittenOrLeftOutAsTheSnapshotHasThem() async throws {
        // The switch off: the two dependent rows go, nothing is written and nothing says there was an entry.
        let off = makeRig()
        let offCard = try await readyCard(off)
        let offFields = try model(offCard)
        XCTAssertTrue(offCard.lines.contains("Add to schedule: Add"), "premise: the switch starts on")
        XCTAssertTrue(offFields.chooseOption("meal", "false"))
        XCTAssertTrue(offCard.lines.contains("Add to schedule: Don't Add"))
        XCTAssertFalse(offCard.lines.contains { $0.hasPrefix("Meal title") || $0.hasPrefix("Start") })
        let offResolution = try await confirm(offCard)
        XCTAssertEqual(offResolution.status, "applied")
        XCTAssertEqual(offCard.mark, .confirmed)
        XCTAssertEqual(off.store.activities.count, 1, "only the seeded dinner")
        XCTAssertNil(offResolution.json?["meal"])
        XCTAssertEqual(offResolution.json?["message"] as? String, AgentDelivery.appliedMessage + " " + AgentDelivery.budgetRecordedSentence)
        let offRecord = try XCTUnwrap(off.orders.orders.first)
        XCTAssertNil(offRecord.mealActivityID)

        // A typed title and a chosen time reach the Store entry, and the title is trimmed once.
        let edit = makeRig()
        let editCard = try await readyCard(edit)
        let editFields = try model(editCard)
        let start = TestClock.date("2026-10-28T20:15")
        XCTAssertTrue(editFields.setText("meal_title", "Family dinner"))
        XCTAssertTrue(editFields.chooseTime("meal_start", start))
        XCTAssertEqual(editFields.source(of: "meal_title"), .entered)
        XCTAssertEqual(editFields.source(of: "meal_start"), .entered)
        XCTAssertTrue(editCard.lines.contains("Meal title: Family dinner"))
        XCTAssertTrue(editCard.lines.contains("Start: \(whenText(start))"))
        XCTAssertTrue(editFields.setText("meal_title", "  Family dinner "))
        let editResolution = try await confirm(editCard)
        let entry = try XCTUnwrap(edit.store.activities.first { $0.title == "Family dinner (Simulated)" }, "the title is trimmed once")
        XCTAssertEqual(entry.startDate, start)
        XCTAssertEqual(entry.endDate, TestClock.date("2026-10-28T21:15"))
        XCTAssertEqual(edit.store.activities.count, 2)
        let meal = try XCTUnwrap(editResolution.json?["meal"] as? [String: Any])
        XCTAssertEqual(meal["title"] as? String, "Family dinner (Simulated)")
        XCTAssertEqual(meal["id"] as? String, entry.id.uuidString)
        XCTAssertEqual(edit.orders.orders.first?.mealActivityID, entry.id.uuidString)

        // Start has no rule tied to the arrival date: another day is written as chosen.
        let elsewhere = makeRig()
        let elsewhereCard = try await readyCard(elsewhere)
        let otherDay = TestClock.date("2026-10-30T09:00")
        XCTAssertTrue(try model(elsewhereCard).chooseTime("meal_start", otherDay))
        _ = try await confirm(elsewhereCard)
        XCTAssertEqual(try XCTUnwrap(mealEntry(elsewhere)).startDate, otherDay)

        // No edit: the suggested entry is written.
        let plain = makeRig()
        _ = try await confirm(try await readyCard(plain))
        let suggested = try XCTUnwrap(mealEntry(plain))
        XCTAssertEqual(suggested.title, "Dinner (Simulated)")
        XCTAssertEqual(suggested.startDate, TestClock.date(DeliveryToolFixture.arrival))

        // A title of 75 typed characters is held at 68; the entry is exactly 80 characters, the first 68 and the suffix.
        let typed = String((0..<75).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })
        let long = makeRig()
        let longCard = try await readyCard(long)
        let longFields = try model(longCard)
        XCTAssertTrue(longFields.setText("meal_title", typed))
        XCTAssertEqual(longFields.values.text("meal_title"), String(typed.prefix(68)))
        XCTAssertTrue(longCard.canConfirm)
        let longResolution = try await confirm(longCard)
        XCTAssertEqual(longResolution.status, "applied", "an over-length title is cut, never refused")
        let longEntry = try XCTUnwrap(mealEntry(long))
        XCTAssertEqual(longEntry.title, String(typed.prefix(68)) + " (Simulated)")
        XCTAssertEqual(longEntry.title.count, 80)
        XCTAssertTrue(longEntry.title.hasSuffix(" (Simulated)"))
        XCTAssertEqual((longResolution.json?["meal"] as? [String: Any])?["title"] as? String, longEntry.title)

        // A blank title blocks Confirm while the switch is on, and does not once the switch is off.
        let blank = makeRig()
        let blankCard = try await readyCard(blank)
        let blankFields = try model(blankCard)
        XCTAssertTrue(blankCard.canConfirm, "premise: the same card can be confirmed")
        XCTAssertTrue(blankFields.setText("meal_title", "   "))
        XCTAssertFalse(blankCard.canConfirm)
        let rejected = try await confirm(blankCard)
        XCTAssertEqual(rejected.status, "rejected")
        XCTAssertEqual(rejected.message, AgentDelivery.editRejectedMessage)
        XCTAssertEqual(blank.partner.requests.count, 1)
        XCTAssertEqual(blank.store.activities.count, 1)
        let blankOff = makeRig()
        let blankOffCard = try await readyCard(blankOff)
        let blankOffFields = try model(blankOffCard)
        XCTAssertTrue(blankOffFields.setText("meal_title", "   "))
        XCTAssertFalse(blankOffCard.canConfirm)
        XCTAssertTrue(blankOffFields.chooseOption("meal", "false"))
        XCTAssertTrue(blankOffCard.canConfirm)
        let blankOffResolution = try await confirm(blankOffCard)
        XCTAssertEqual(blankOffResolution.status, "applied")
        XCTAssertEqual(blankOff.store.activities.count, 1)

        // Edits made while the order request is in flight change neither the entry, the record nor the result.
        let moving = makeRig()
        let movingCard = try await readyCard(moving)
        let movingFields = try model(movingCard)
        moving.partner.whileSending = {
            _ = movingFields.chooseOption("meal", "false")
            _ = movingFields.setText("meal_title", "Other")
            _ = movingFields.chooseTime("meal_start", TestClock.date("2026-10-28T21:00"))
        }
        let movingResolution = try await confirm(movingCard)
        let movedEntry = try XCTUnwrap(mealEntry(moving))
        XCTAssertEqual(moving.store.activities.count, 2)
        XCTAssertEqual(movedEntry.title, "Dinner (Simulated)")
        XCTAssertEqual(movedEntry.startDate, TestClock.date(DeliveryToolFixture.arrival))
        XCTAssertEqual((movingResolution.json?["meal"] as? [String: Any])?["title"] as? String, "Dinner (Simulated)")
        XCTAssertEqual(moving.orders.orders.first?.mealActivityID, movedEntry.id.uuidString)
        // And the other way round: off at the tap, switched on meanwhile.
        let late = makeRig()
        let lateCard = try await readyCard(late)
        let lateFields = try model(lateCard)
        XCTAssertTrue(lateFields.chooseOption("meal", "false"))
        late.partner.whileSending = { _ = lateFields.chooseOption("meal", "true") }
        let lateResolution = try await confirm(lateCard)
        XCTAssertEqual(lateResolution.status, "applied")
        XCTAssertEqual(late.store.activities.count, 1)
        XCTAssertNil(lateResolution.json?["meal"])
        XCTAssertNil(late.orders.orders.first?.mealActivityID)
    }

    // MARK: O36 the sources at build

    func testO36_TheSourcesAtBuildAreStatedInferredOrBlank() async throws {
        // The usual call: the arrival and the card stated, the place inferred from the schedule, the meal rows inferred.
        let rig = makeRig()
        let usual = try await readyCard(rig)
        let fields = try model(usual)
        XCTAssertEqual(fields.source(of: "arrive_at"), .stated)
        XCTAssertEqual(fields.values.date("arrive_at"), arrivalDate)
        XCTAssertEqual(fields.source(of: "card_id"), .stated)
        XCTAssertEqual(fields.values.option("card_id"), "debit-4242")
        XCTAssertEqual(fields.source(of: "address"), .inferred)
        XCTAssertEqual(fields.values.text("address"), "9 Library Road")
        XCTAssertEqual(fields.source(of: "meal"), .inferred)
        XCTAssertEqual(fields.values.flag("meal"), true)
        XCTAssertEqual(fields.source(of: "meal_title"), .inferred)
        XCTAssertEqual(fields.values.text("meal_title"), "Dinner")
        XCTAssertEqual(fields.source(of: "meal_start"), .inferred)
        XCTAssertEqual(fields.values.date("meal_start"), arrivalDate)
        XCTAssertTrue(usual.canConfirm)
        XCTAssertEqual(rig.partner.requests.count, 1, "building the card sends nothing")

        // No card id and no schedule: the call is not refused; the card and the place are blank and Confirm waits.
        let bare = makeRig()
        await bare.hold()
        let blankCard = try XCTUnwrap(bare.order(drop: ["card_id"]).card)
        let blank = try model(blankCard)
        XCTAssertEqual(blank.source(of: "arrive_at"), .stated)
        XCTAssertEqual(blank.source(of: "card_id"), .blank)
        XCTAssertEqual(blank.source(of: "address"), .blank)
        XCTAssertEqual(blank.source(of: "meal"), .inferred)
        XCTAssertNil(blank.values.option("card_id"))
        XCTAssertNil(blank.values.text("address"))
        XCTAssertFalse(blankCard.canConfirm)

        // deliver_to names the place: stated; a model-passed card id the options hold is stated, and an unknown one is refused.
        let named = try model(bare.order(["deliver_to": "p3"]).card)
        XCTAssertEqual(named.source(of: "address"), .stated)
        XCTAssertEqual(named.values.text("address"), "Corner Cafe")
        XCTAssertEqual(named.source(of: "card_id"), .stated)
        assertRefused(bare.order(["card_id": "visa", "deliver_to": "p3"]), Text.cardUnknown, "an unknown card id")
        assertRefused(bare.order(["deliver_to": "p4"]), Text.toHandle, "a place with no usable text")
        XCTAssertEqual(bare.partner.requests.count, 1, "only the options request")
        XCTAssertEqual(bare.reads.count, 0)
    }

    // MARK: O37-O40 the delivery place sees the occurrences of repeating activities (T-a to T-d)

    /// A weekly repeating activity (Calendar numbering, Sunday = 1) from a first day, added to the rig's Store.
    private func addRepeat(_ rig: DeliveryToolRig, weekday: Int, from startMinute: Int, to endMinute: Int, first: Int, place: Place?,
                           file: StaticString = #filePath, line: UInt = #line) {
        let series = RepeatSeries(id: RepeatSeries.newID(), title: "Repeating", location: place,
                                  rule: RecurrenceRule(weekdays: [weekday], unit: .weekly), lunarCalendar: nil,
                                  firstDayKey: first, lastDayKey: nil, startMinute: startMinute, endMinute: endMinute,
                                  endDayDistance: 0, syncToCalendar: nil, skippedDayKeys: [], legPlan: nil,
                                  legsFilledThroughDayKey: nil)
        XCTAssertTrue(rig.store.addSeries(series), "the series was stored", file: file, line: line)
    }

    // The arrival is Wednesday 2026-10-28 19:40; the fixed clock is Tuesday 2026-10-27 09:00.
    private static let wednesday = 4
    private static let tuesday = 3
    private static let firstWednesday = 20261028
    private static let firstTuesday = 20261027

    func testO37_ARepeatingEntryInProgressAtTheArrivalGivesTheDeliveryPlaceAndThePartnersFieldOrderIsFollowed() async throws {
        let rig = makeRig()
        addRepeat(rig, weekday: Self.wednesday, from: 19 * 60, to: 21 * 60, first: Self.firstWednesday, place: DeliveryToolFixture.library)
        await rig.hold()
        let card = try XCTUnwrap(rig.order().card, "the occurrence in progress at the arrival is the suggestion")
        let got = try address(card)
        XCTAssertEqual(got.text, "9 Library Road")
        XCTAssertEqual(got.source, .inferred)
        XCTAssertTrue(card.lines.contains("Delivery place: 9 Library Road"))
        XCTAssertEqual(rig.reads.count, 0)

        // The card follows the partner's order of fields when the list is reordered.
        let partner = DeliveryToolPartner()
        partner.fieldOrder = ["card_id", "arrive_at", "address"]
        let other = makeRig(partner: partner)
        addRepeat(other, weekday: Self.wednesday, from: 19 * 60, to: 21 * 60, first: Self.firstWednesday, place: DeliveryToolFixture.library)
        await other.hold()
        let reordered = try XCTUnwrap(other.order().card)
        let when = whenText(arrivalDate)
        XCTAssertEqual(reordered.lines, ["Order delivery", "Pasta Palace", "2 x Ramen", "1 x Gyoza", "Estimated total $40.00",
                                         "Pay with: \(DeliveryToolPartner.cards[0].label)", "Arrival: \(when)",
                                         "Delivery place: 9 Library Road", "Add to schedule: Add", "Meal title: Dinner",
                                         "Start: \(when)", "Example Delivery - Simulated"])
    }

    func testO38_AOneOffAndARepeatingOccurrenceAtDifferentPlacesGiveNoSuggestion() async throws {
        let rig = makeRig()
        rig.seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", place: DeliveryToolFixture.library)
        addRepeat(rig, weekday: Self.wednesday, from: 19 * 60 + 30, to: 20 * 60 + 30, first: Self.firstWednesday,
                  place: DeliveryToolFixture.corner)
        await rig.hold()
        let card = try XCTUnwrap(rig.order().card, "the call is not refused")
        XCTAssertEqual(card.lines.count, 12, "premise: the full card is returned")
        let got = try address(card)
        XCTAssertNil(got.text, "two different places give none")
        XCTAssertEqual(got.source, .blank)
        XCTAssertFalse(card.lines.joined().contains("9 Library Road"))
        XCTAssertFalse(card.lines.joined().contains("Corner Cafe"))
    }

    func testO39_AOneOffAndARepeatingOccurrenceAtTheSamePlaceGiveThatOneText() async throws {
        let rig = makeRig()
        rig.seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", place: DeliveryToolFixture.library)
        addRepeat(rig, weekday: Self.wednesday, from: 19 * 60 + 30, to: 20 * 60 + 30, first: Self.firstWednesday,
                  place: DeliveryToolFixture.library)
        await rig.hold()
        let got = try address(rig.order().card)
        XCTAssertEqual(got.text, "9 Library Road")
        XCTAssertEqual(got.source, .inferred)
    }

    func testO40_AnOccurrenceInProgressAtNowIsTheSecondAnchorAndTheEdgesOfTheIntervalHold() async throws {
        // Only in progress now (Tuesday 08:00 to 10:00), nothing at the arrival: the second anchor.
        let nowOnly = makeRig()
        addRepeat(nowOnly, weekday: Self.tuesday, from: 8 * 60, to: 10 * 60, first: Self.firstTuesday, place: DeliveryToolFixture.corner)
        await nowOnly.hold()
        let nowAddress = try address(nowOnly.order().card)
        XCTAssertEqual(nowAddress.text, "Corner Cafe", "the occurrence in progress now is the suggestion")
        XCTAssertEqual(nowAddress.source, .inferred)

        // Entries at the arrival that differ give none, and the later anchor is not used.
        let differ = makeRig()
        differ.seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", place: DeliveryToolFixture.library)
        differ.seed("Other", "2026-10-28T19:30", "2026-10-28T20:30", place: DeliveryToolFixture.restaurant)
        addRepeat(differ, weekday: Self.tuesday, from: 8 * 60, to: 10 * 60, first: Self.firstTuesday, place: DeliveryToolFixture.corner)
        await differ.hold()
        let differAddress = try address(differ.order().card)
        XCTAssertNil(differAddress.text, "two different places give none and the later anchor is not used")
        XCTAssertEqual(differAddress.source, .blank)

        // An occurrence that starts at the arrival minute counts.
        let starts = makeRig()
        addRepeat(starts, weekday: Self.wednesday, from: 19 * 60 + 40, to: 21 * 60, first: Self.firstWednesday, place: DeliveryToolFixture.library)
        await starts.hold()
        XCTAssertEqual(try address(starts.order().card).text, "9 Library Road", "an occurrence that starts at the arrival minute counts")

        // One that ends at the arrival minute does not, and neither does one that ended a minute before it.
        for end in [19 * 60 + 40, 19 * 60 + 39] {
            let ends = makeRig()
            addRepeat(ends, weekday: Self.wednesday, from: 18 * 60, to: end, first: Self.firstWednesday, place: DeliveryToolFixture.library)
            await ends.hold()
            let endsAddress = try address(ends.order().card)
            XCTAssertNil(endsAddress.text, "an occurrence that ends at minute \(end) does not count")
            XCTAssertEqual(endsAddress.source, .blank)
        }

        // One in progress at both anchors (now is 19:00 the same day) is suggested.
        let both = makeRig()
        both.clock.now = TestClock.date("2026-10-28T19:00")
        addRepeat(both, weekday: Self.wednesday, from: 18 * 60, to: 21 * 60, first: Self.firstWednesday, place: DeliveryToolFixture.library)
        await both.hold()
        XCTAssertEqual(try address(both.order().card).text, "9 Library Road", "an occurrence in progress at both anchors is suggested")

        // An arrival at the current minute: the interval is that minute alone, and the occurrence in progress is seen.
        let same = makeRig()
        addRepeat(same, weekday: Self.tuesday, from: 8 * 60, to: 10 * 60, first: Self.firstTuesday, place: DeliveryToolFixture.corner)
        await same.hold()
        let sameAddress = try address(same.order(["arrive_at": "2026-10-27T09:00"]).card)
        XCTAssertEqual(sameAddress.text, "Corner Cafe")
    }

    // MARK: O41-O42 acting by kind

    func testO41_AConfirmedOrderActsByKindTheEntryStartsAtTheCardsStartOneSpendOfTheMoneyItemAndATextItemTouchesNothingElse() async throws {
        let partner = DeliveryToolPartner()
        partner.extraResults = [["name": "Driver note", "kind": "text", "value": "SENTINEL-NOTE-1"]]
        let rig = makeRig(partner: partner)
        let card = try await readyCard(rig)
        let start = TestClock.date("2026-10-28T20:15")
        XCTAssertTrue(try model(card).chooseTime("meal_start", start))
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(card.mark, .confirmed)

        // The text item is in the reply, in the partner's order beside the other items, and only there.
        let reply = try XCTUnwrap(resolution.json?["results"] as? [[String: Any]])
        XCTAssertEqual(reply.compactMap { $0["name"] as? String }, ["Arrival", "Estimated total", "Status", "Driver note"])
        XCTAssertEqual(reply.compactMap { $0["kind"] as? String }, ["time", "money", "text", "text"])
        XCTAssertEqual(reply.compactMap { $0["value"] as? String },
                       [DeliveryToolFixture.arrival, "$40.00", "Preparing", "SENTINEL-NOTE-1"])

        // The time item is the arrival; the meal entry starts at the card's Start and lasts 60 minutes.
        let entry = try XCTUnwrap(mealEntry(rig))
        XCTAssertEqual(entry.startDate, start)
        XCTAssertEqual(entry.endDate, TestClock.date("2026-10-28T21:15"))
        XCTAssertEqual(rig.orders.orders.first?.arrival, DeliveryToolFixture.arrival)

        // The money item goes to the budget as one spend of its cents, in the week of the arrival.
        XCTAssertEqual(rig.budgetPartner.requests.count, 1)
        let spend = try XCTUnwrap(rig.budgetPartner.body())
        XCTAssertEqual(spend["amount_cents"] as? Int, 4000)
        XCTAssertEqual(spend["week_start"] as? String, BudgetToolFixture.week)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 4000)

        // The text item changes nothing but the reply: it is in no entry, request, record, ledger, packet or notice.
        XCTAssertEqual(rig.store.activities.count, 2, "the seeded dinner and one meal entry")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        await rig.log.flush()
        let elsewhere: [String] = [
            String(decoding: try encoder.encode(entry), as: UTF8.self),
            String(decoding: try XCTUnwrap(rig.budgetPartner.requests.first?.httpBody), as: UTF8.self),
            String(decoding: try Data(contentsOf: rig.ordersFile), as: UTF8.self),
            String(decoding: try Data(contentsOf: rig.ledgerFile), as: UTF8.self),
            String(decoding: try Data(contentsOf: rig.folder.appendingPathComponent(ConnectionLog.fileName)), as: UTF8.self),
            rig.log.packets.map(\.summary).joined(separator: "\n"),
            resolution.notice ?? ""]
        for text in elsewhere {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("SENTINEL-NOTE"), text)
        }

        // The notice names the money item with the partner's own word, and the reply states that name.
        let named = DeliveryToolPartner()
        named.moneyName = "Order total"
        let namedRig = makeRig(partner: named)
        let namedResolution = try await confirm(try await readyCard(namedRig))
        XCTAssertEqual(namedResolution.status, "applied")
        XCTAssertEqual(namedResolution.notice, "Order total $40.00 sent to Example Budget (Simulated): $160.00 left this week.")
        let namedResults = try XCTUnwrap(namedResolution.json?["results"] as? [[String: Any]])
        XCTAssertEqual(namedResults.compactMap { $0["name"] as? String }, ["Arrival", "Order total", "Status"])
        XCTAssertEqual(namedRig.budgetPartner.requests.count, 1)
    }

    func testO42_UnusableResultsGiveUnavailableAndWriteNothing() async throws {
        // Premise: the same card with the Worker's three items is applied.
        let good = makeRig()
        let goodCard = try await readyCard(good)
        XCTAssertTrue(try model(goodCard).isReady)
        let goodResolution = try await confirm(goodCard)
        XCTAssertEqual(goodResolution.status, "applied")
        XCTAssertEqual(good.orders.orders.count, 1)
        XCTAssertEqual((goodResolution.json?["results"] as? [[String: Any]])?.count, 3, "the reply states the three result items")

        let defects: [(String, (DeliveryToolPartner) -> Void)] = [
            ("a second money item", { $0.extraResults = [["name": "Tip", "kind": "money", "value": 100]] }),
            ("a second time item", { $0.extraResults = [["name": "Pickup", "kind": "time", "value": DeliveryToolFixture.arrival]] }),
            ("a time item that is not the requested arrival", { $0.timeItem = "2026-10-28T19:41" }),
            ("a money item that is not the total", { $0.totalDelta = 1 })]
        for (name, change) in defects {
            let partner = DeliveryToolPartner()
            change(partner)
            let rig = makeRig(partner: partner)
            let card = try await readyCard(rig)
            XCTAssertTrue(try model(card).isReady, name)
            let before = rig.snapshot
            let resolution = try await confirm(card)
            XCTAssertEqual(resolution.status, "unavailable", name)
            XCTAssertEqual(resolution.message, AgentDelivery.unavailableMessage, name)
            XCTAssertEqual(resolution.notice, "The delivery could not be ordered. Nothing was ordered.", name)
            XCTAssertEqual(card.mark, .notApplied, name)
            XCTAssertEqual(rig.partner.requests.count, 2, "\(name): the options request and the one order request")
            XCTAssertEqual(rig.snapshot, before, name)
            XCTAssertTrue(rig.orders.orders.isEmpty, name)
            XCTAssertEqual(rig.budgetPartner.requests.count, 0, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ordersFile.path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ledgerFile.path), name)
        }
    }

    // MARK: O43 blanks

    func testO43_ACardWithTheCardAndThePlaceBlankWaitsForBothAndTheChosenValuesReachTheOneRequest() async throws {
        let rig = makeRig()
        await rig.hold()
        let card = try XCTUnwrap(rig.order(drop: ["card_id"]).card)
        let fields = try model(card)
        XCTAssertEqual(card.lines.count, 12, "premise: the full card")
        XCTAssertFalse(fields.isReady)
        XCTAssertFalse(card.canConfirm)
        XCTAssertFalse(fields.chooseOption("card_id", "visa"), "only a card the partner lists can be chosen")
        XCTAssertTrue(fields.chooseOption("card_id", "credit-1881"))
        XCTAssertFalse(card.canConfirm, "the place is still blank")
        XCTAssertTrue(fields.choosePlace("address", DeliveryToolFixture.corner))
        XCTAssertTrue(card.canConfirm)
        XCTAssertEqual(fields.source(of: "card_id"), .entered)
        XCTAssertEqual(fields.source(of: "address"), .entered)
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(rig.partner.requests.count, 2, "the options request and one order request")
        XCTAssertEqual(rig.partner.body(1)?["address"] as? String, "Corner Cafe")
        XCTAssertEqual(rig.partner.body(1)?["card_id"] as? String, "credit-1881")
        XCTAssertEqual(rig.orders.orders.first?.cardLabel, DeliveryToolPartner.cards[1].label)
        XCTAssertEqual(resolution.json?["card"] as? String, DeliveryToolPartner.cards[1].label)
    }

    // MARK: O44 the edited Arrival

    /// A ready card whose Arrival the user then dials to `local`.
    private func dialled(_ local: String, _ over: [String: Any] = [:], file: StaticString = #filePath,
                         line: UInt = #line) async throws -> (rig: DeliveryToolRig, card: AgentCard) {
        let rig = makeRig()
        let card = try await readyCard(rig, over)
        let fields = try model(card, file: file, line: line)
        XCTAssertTrue(fields.isReady, local, file: file, line: line)
        XCTAssertTrue(fields.chooseTime("arrive_at", TestClock.date(local)), local, file: file, line: line)
        XCTAssertEqual(fields.source(of: "arrive_at"), .entered, local, file: file, line: line)
        return (rig, card)
    }

    func testO44_TheEditedArrivalDecidesTheWindowTheRequestTheRecordAndTheBudgetWeek() async throws {
        // Premise: the same card with its own arrival is applied.
        let untouched = makeRig()
        let untouchedResolution = try await confirm(try await readyCard(untouched))
        XCTAssertEqual(untouchedResolution.status, "applied")

        // An Arrival dialled to a minute before the clock, and to day 367: rejected, nothing sent, written or recorded.
        for (label, local) in [("a minute ago", "2026-10-27T08:59"), ("day 367", "2027-10-29T09:00")] {
            let (rig, card) = try await dialled(local)
            let before = rig.snapshot
            let resolution = try await confirm(card)
            XCTAssertEqual(resolution.status, "rejected", label)
            XCTAssertEqual(resolution.message, Text.windowAtConfirm, label)
            XCTAssertEqual(resolution.json?["arrive_at"] as? String, local, label)
            XCTAssertEqual(resolution.notice, Text.notice, label)
            XCTAssertEqual(card.mark, .notApplied, label)
            XCTAssertEqual(rig.partner.requests.count, 1, "\(label): only the options request is on the partner")
            XCTAssertEqual(rig.snapshot, before, label)
            XCTAssertTrue(rig.orders.orders.isEmpty, label)
            XCTAssertEqual(rig.budgetPartner.requests.count, 0, label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ordersFile.path), label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ledgerFile.path), label)
            await rig.log.flush()
            XCTAssertEqual(rig.log.packets.count, 2, "\(label): only the options exchange is on the log")
        }

        // Another valid time the same day: the request, the partner's time item, the record and the window all use it.
        let (rig, card) = try await dialled("2026-10-28T20:15")
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(rig.partner.body(1)?["arrive_at"] as? String, "2026-10-28T20:15")
        XCTAssertEqual(rig.orders.orders.first?.arrival, "2026-10-28T20:15")
        XCTAssertEqual(rig.budgetPartner.body()?["week_start"] as? String, BudgetToolFixture.week)
        XCTAssertEqual(try XCTUnwrap(mealEntry(rig)).startDate, arrivalDate, "Start does not follow an edited Arrival")

        // An Arrival dialled into the next week spends in that week.
        let (next, nextCard) = try await dialled("2026-11-02T19:40", ["deliver_to": "p2"])
        let nextResolution = try await confirm(nextCard)
        XCTAssertEqual(nextResolution.status, "applied")
        XCTAssertEqual(next.partner.body(1)?["arrive_at"] as? String, "2026-11-02T19:40")
        XCTAssertEqual(next.budgetPartner.body()?["week_start"] as? String, "2026-11-02")
        XCTAssertEqual(next.ledger.spentCents(weekStart: "2026-11-02"), 4000)
        XCTAssertEqual(next.ledger.spentCents(weekStart: BudgetToolFixture.week), 0)
        XCTAssertEqual(next.orders.orders.first?.arrival, "2026-11-02T19:40")

        // An Arrival outside the partner's hours is sent and declined.
        let (late, lateCard) = try await dialled("2026-10-28T23:30")
        let lateResolution = try await confirm(lateCard)
        XCTAssertEqual(lateResolution.status, "declined")
        XCTAssertEqual(late.partner.requests.count, 2)
        XCTAssertEqual(late.partner.body(1)?["arrive_at"] as? String, "2026-10-28T23:30")
        XCTAssertTrue(late.orders.orders.isEmpty)
    }

    // MARK: O45 the search wiring

    func testO45_TheCardsPlaceSearchReadsTheDeviceOnlyWhenASearchFiresAndSendsItOnlyToPlaces() async throws {
        let places = PlacesTransportStub.answering(with: PlaceFixture.data("places-search-three"))
        let rig = makeRig(placesTransport: places)
        let card = try await readyCard(rig)
        let fields = try model(card)
        // Building the card reads the device position 0 times and calls no provider.
        XCTAssertEqual(rig.reads.count, 0)
        XCTAssertEqual(places.callCount, 0)

        // A search that fires after the debounce reaches the provider once, with the trimmed query, and reads the origin once.
        fields.search("address", "  Tartine  ")
        XCTAssertEqual(places.callCount, 0, "nothing is searched before the debounce")
        XCTAssertEqual(rig.reads.count, 0)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(places.callCount, 1)
        XCTAssertEqual(rig.reads.count, 1)
        let body = PlaceBody.json(places.requests.first)
        XCTAssertEqual(body?["textQuery"] as? String, "Tartine")
        let center = try XCTUnwrap(PlaceBody.biasCenter(body))
        XCTAssertEqual(center.latitude, DeliveryToolFixture.device.latitude)
        XCTAssertEqual(center.longitude, DeliveryToolFixture.device.longitude)
        guard case .results(let found)? = fields.field("address")?.lookup else { return XCTFail("the row holds the results") }
        XCTAssertEqual(found.count, 3)

        // Pick a result and confirm: the device position is in the Places request and nowhere else.
        XCTAssertTrue(fields.choosePlace("address", found[2]))
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(rig.partner.body(1)?["address"] as? String, found[2].address)
        let placesText = PlaceBody.text(places.requests.first)
        for number in ["37.7", "-122.3"] { XCTAssertTrue(placesText.contains(number), "positive control: \(number)") }
        let packets = await rig.packets()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entry = try XCTUnwrap(mealEntry(rig))
        let elsewhere: [(String, String)] = [
            ("order request", String(decoding: try XCTUnwrap(rig.partner.requests.dropFirst().first?.httpBody), as: UTF8.self)),
            ("options request", String(decoding: try XCTUnwrap(rig.partner.requests.first?.httpBody), as: UTF8.self)),
            ("budget request", String(decoding: try XCTUnwrap(rig.budgetPartner.requests.first?.httpBody), as: UTF8.self)),
            ("order record", String(decoding: try Data(contentsOf: rig.ordersFile), as: UTF8.self)),
            ("connections file", String(decoding: try Data(contentsOf: rig.folder.appendingPathComponent(ConnectionLog.fileName)), as: UTF8.self)),
            ("packet summaries", packets.map(\.summary).joined(separator: "\n")),
            ("store entry", String(decoding: try encoder.encode(entry), as: UTF8.self)),
            ("result", resolution.result),
            ("notice", resolution.notice ?? ""),
            ("card", card.lines.joined(separator: "\n"))]
        for (name, text) in elsewhere {
            XCTAssertFalse(text.isEmpty, name)
            for number in ["37.7", "-122.3", "SENTINEL-HOME"] { XCTAssertFalse(text.contains(number), "\(name) holds \(number)") }
        }

        // The Places packet is the provider's own and shares no flow id with the order.
        let searchPacket = try XCTUnwrap(packets.first { $0.kind == .placeSearch })
        XCTAssertEqual(searchPacket.summary, "Searched \u{201C}Tartine\u{201D} \u{00B7} 3 results")
        XCTAssertNil(searchPacket.flowID)
        let orderFlows = Set(packets.filter { $0.kind == .delivery || $0.kind == .budget }.compactMap(\.flowID))
        XCTAssertFalse(orderFlows.isEmpty)
        XCTAssertFalse(orderFlows.contains { $0 == searchPacket.flowID })
        XCTAssertEqual(rig.reads.count, 1, "Confirm reads the position no more")
    }
}
