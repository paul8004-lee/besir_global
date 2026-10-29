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
    /// Added to the total of an order answer, so the answer differs from the card's.
    var totalDelta = 0

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
            answer["estimated_total_cents"] = totalDelta + lines.reduce(500) {
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
         failingRecord: Bool = false, injectBudget: Bool = false) {
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
        let toolbox = AgentToolbox(store: store, now: { clock.now }, timeZone: { clock.zone },
                                   deviceOrigin: { reads.count += 1; return DeliveryToolFixture.device },
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
                         failingRecord: Bool = false, injectBudget: Bool = true) -> DeliveryToolRig {
        let rig = DeliveryToolRig(config: config, partner: partner, places: places, budgetPartner: budgetPartner,
                                  failingRecord: failingRecord, injectBudget: injectBudget)
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
        XCTAssertEqual(Set(json.keys), ["status", "partner", "simulated", "order_id", "restaurant", "arrival_estimate", "items", "address",
                                        "card", "estimated_total", "estimate", "message", "budget", "meal"])
        XCTAssertNil(json["people"])
        XCTAssertEqual(json["status"] as? String, "applied")
        XCTAssertEqual(json["partner"] as? String, DeliveryClient.partnerName)
        XCTAssertEqual(json["simulated"] as? Bool, true)
        XCTAssertEqual(json["order_id"] as? String, "DL-AB12CD")
        XCTAssertEqual(json["restaurant"] as? String, "Pasta Palace")
        XCTAssertEqual(json["arrival_estimate"] as? String, DeliveryToolFixture.arrival)
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["name"] as? String }, ["Ramen", "Gyoza"])
        XCTAssertEqual(items.compactMap { $0["quantity"] as? Int }, [2, 1])
        XCTAssertTrue(items.allSatisfy { Set($0.keys) == ["name", "quantity"] })
        XCTAssertEqual(json["address"] as? String, "9 Library Road")
        XCTAssertEqual(json["card"] as? String, DeliveryToolPartner.cards[0].label)
        XCTAssertEqual(json["estimated_total"] as? String, "$40.00")
        XCTAssertEqual(json["estimate"] as? Bool, true)
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
        card.editors.delivery?.text = address
        let cardText = card.lines.joined(separator: "\n")
        for part in [address, "Sentinel Bistro 77", "2 x Ramen", "1 x Gyoza", "Pay with " + DeliveryToolPartner.cards[0].label] {
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
            AgentDelivery.partnerLine] + AgentDelivery.controlLabels
        XCTAssertEqual(AgentDelivery.controlLabels, ["Delivery place", "Add to schedule", "Meal title", "Start"])

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
        for text in texts {
            XCTAssertEqual(hits(text), 0, text)
            XCTAssertEqual(hangul(text), 0, text)
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
        XCTAssertEqual(applied.json?["estimated_total"] as? String, "$40.00")
        XCTAssertEqual(applied.json?["estimate"] as? Bool, true)
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

    func testO34_AnEditedDeliveryTextIsSentRecordedAndReturnedAsTheOneTrimmedSnapshot() async throws {
        // Typed text with a hidden character and spaces at both ends: sent trimmed, and the same string comes back.
        let typed = makeRig()
        let card = try await readyCard(typed)
        card.editors.delivery?.text = "  12 Example\u{0007} Street  "
        XCTAssertEqual(card.editors.delivery?.text, "  12 Example Street  ", "hidden characters go as they are typed, the spaces stay")
        XCTAssertFalse(card.lines[5].contains("(suggested"), "an edited text loses its mark")
        XCTAssertTrue(card.canConfirm)
        let resolution = try await confirm(card)
        XCTAssertEqual(resolution.status, "applied", "the trimmed text is the one the partner echoes")
        XCTAssertEqual(typed.partner.body(1)?["address"] as? String, "12 Example Street")
        XCTAssertEqual(resolution.json?["address"] as? String, "12 Example Street")
        XCTAssertEqual(typed.orders.orders.first?.address, "12 Example Street")

        // Cut at 120 scalars as it is typed.
        let long = makeRig()
        let longCard = try await readyCard(long)
        longCard.editors.delivery?.text = String(repeating: "A", count: 130)
        XCTAssertEqual(longCard.editors.delivery?.text.unicodeScalars.count, 120)
        _ = try await confirm(longCard)
        XCTAssertEqual(long.partner.body(1)?["address"] as? String, String(repeating: "A", count: 120))

        // An unedited suggestion is sent as suggested.
        let plain = makeRig()
        let plainCard = try await readyCard(plain)
        XCTAssertEqual(plainCard.lines[5], "To 9 Library Road (suggested from your schedule)")
        _ = try await confirm(plainCard)
        XCTAssertEqual(plain.partner.body(1)?["address"] as? String, "9 Library Road")

        // A blank text cannot be confirmed; forced, it is rejected and nothing is sent or written.
        let blank = makeRig()
        let blankCard = try await readyCard(blank)
        blankCard.editors.delivery?.text = "   "
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
        let model = makeRig()
        model.seedDinner()
        await model.hold()
        let modelCard = try XCTUnwrap(model.order(["address": "SENTINEL-ADDRESS-2", "meal": "SENTINEL-MEAL-2"]).card)
        _ = try await confirm(modelCard)
        XCTAssertEqual(model.partner.body(1)?["address"] as? String, "9 Library Road")
        for request in model.partner.requests + model.budgetPartner.requests {
            XCTAssertFalse(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("SENTINEL"))
        }

        // An edit made while the order request is in flight changes none of request, record or result.
        let moving = makeRig()
        let movingCard = try await readyCard(moving)
        moving.partner.whileSending = { movingCard.editors.delivery?.text = "CHANGED-WHILE-SENT" }
        let movingResolution = try await confirm(movingCard)
        XCTAssertEqual(movingResolution.status, "applied")
        XCTAssertEqual(moving.partner.body(1)?["address"] as? String, "9 Library Road")
        XCTAssertEqual(movingResolution.json?["address"] as? String, "9 Library Road")
        XCTAssertEqual(moving.orders.orders.first?.address, "9 Library Road")
        XCTAssertEqual(movingCard.editors.delivery?.text, "9 Library Road", "frozen at the tap")
        XCTAssertEqual(movingCard.lines[5], "To 9 Library Road (suggested from your schedule)")
    }

    func testO35_AnEditedMealEntryIsWrittenOrLeftOutAsTheSnapshotHasIt() async throws {
        // The switch off: nothing is written and nothing says there was an entry.
        let off = makeRig()
        let offCard = try await readyCard(off)
        offCard.editors.mealOn?.isOn = false
        XCTAssertFalse(offCard.lines.contains { $0.hasPrefix("Add to schedule") })
        let offResolution = try await confirm(offCard)
        XCTAssertEqual(offResolution.status, "applied")
        XCTAssertEqual(offCard.mark, .confirmed)
        XCTAssertEqual(off.store.activities.count, 1, "only the seeded dinner")
        XCTAssertNil(offResolution.json?["meal"])
        XCTAssertEqual(offResolution.json?["message"] as? String, AgentDelivery.appliedMessage + " " + AgentDelivery.budgetRecordedSentence)
        let offRecord = try XCTUnwrap(off.orders.orders.first)
        XCTAssertNil(offRecord.mealActivityID)

        // A typed title and a chosen time reach the Store entry, and the marks are gone.
        let edit = makeRig()
        let editCard = try await readyCard(edit)
        editCard.editors.mealTitle?.text = "Family dinner"
        editCard.editors.mealStart?.start = TestClock.date("2026-10-28T20:15")
        XCTAssertEqual(editCard.lines[8], "Add to schedule: Family dinner (Simulated) at \(timeText("2026-10-28T20:15"))")
        editCard.editors.mealTitle?.text = "  Family dinner "
        let editResolution = try await confirm(editCard)
        let entry = try XCTUnwrap(edit.store.activities.first { $0.title == "Family dinner (Simulated)" }, "the title is trimmed once")
        XCTAssertEqual(entry.startDate, TestClock.date("2026-10-28T20:15"))
        XCTAssertEqual(entry.endDate, TestClock.date("2026-10-28T21:15"))
        XCTAssertEqual(edit.store.activities.count, 2)
        let meal = try XCTUnwrap(editResolution.json?["meal"] as? [String: Any])
        XCTAssertEqual(meal["title"] as? String, "Family dinner (Simulated)")
        XCTAssertEqual(meal["id"] as? String, entry.id.uuidString)
        XCTAssertEqual(edit.orders.orders.first?.mealActivityID, entry.id.uuidString)

        // No edit: the suggested entry is written.
        let plain = makeRig()
        _ = try await confirm(try await readyCard(plain))
        let suggested = try XCTUnwrap(mealEntry(plain))
        XCTAssertEqual(suggested.title, "Dinner (Simulated)")
        XCTAssertEqual(suggested.startDate, TestClock.date(DeliveryToolFixture.arrival))

        // A blank title blocks Confirm while the switch is on, and does not once the switch is off.
        let blank = makeRig()
        let blankCard = try await readyCard(blank)
        blankCard.editors.mealTitle?.text = "   "
        XCTAssertFalse(blankCard.canConfirm)
        let rejected = try await confirm(blankCard)
        XCTAssertEqual(rejected.status, "rejected")
        XCTAssertEqual(blank.partner.requests.count, 1)
        XCTAssertEqual(blank.store.activities.count, 1)
        let blankOff = makeRig()
        let blankOffCard = try await readyCard(blankOff)
        blankOffCard.editors.mealTitle?.text = "   "
        blankOffCard.editors.mealOn?.isOn = false
        XCTAssertTrue(blankOffCard.canConfirm)
        let blankOffResolution = try await confirm(blankOffCard)
        XCTAssertEqual(blankOffResolution.status, "applied")
        XCTAssertEqual(blankOff.store.activities.count, 1)

        // Edits made while the order request is in flight change neither the entry, the record nor the result.
        let moving = makeRig()
        let movingCard = try await readyCard(moving)
        moving.partner.whileSending = {
            movingCard.editors.mealOn?.isOn = false
            movingCard.editors.mealTitle?.text = "Other"
            movingCard.editors.mealStart?.start = TestClock.date("2026-10-28T21:00")
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
        lateCard.editors.mealOn?.isOn = false
        late.partner.whileSending = { lateCard.editors.mealOn?.isOn = true }
        let lateResolution = try await confirm(lateCard)
        XCTAssertEqual(lateResolution.status, "applied")
        XCTAssertEqual(late.store.activities.count, 1)
        XCTAssertNil(lateResolution.json?["meal"])
        XCTAssertNil(late.orders.orders.first?.mealActivityID)
    }

    // MARK: O37-O40 the delivery place sees the occurrences of repeating activities

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

    /// The text of a place as it shows on the card, found in a line of the card.
    private func shows(_ card: AgentCard?, _ text: String) -> Bool {
        card?.lines.contains { $0.contains(text) } ?? false
    }

    // The arrival is Wednesday 2026-10-28 19:40; the fixed clock is Tuesday 2026-10-27 09:00.
    private static let wednesday = 4
    private static let tuesday = 3
    private static let firstWednesday = 20261028
    private static let firstTuesday = 20261027

    func testO37_ARepeatingEntryInProgressAtTheArrivalGivesTheDeliveryPlace() async throws {
        let rig = makeRig()
        addRepeat(rig, weekday: Self.wednesday, from: 19 * 60, to: 21 * 60, first: Self.firstWednesday, place: DeliveryToolFixture.library)
        await rig.hold()
        let card = try XCTUnwrap(rig.order().card, "the occurrence in progress at the arrival is the suggestion")
        XCTAssertTrue(shows(card, "9 Library Road"))
        XCTAssertEqual(rig.reads.count, 0)
    }

    func testO38_AOneOffAndARepeatingOccurrenceAtDifferentPlacesGiveNoSuggestion() async throws {
        let rig = makeRig()
        rig.seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", place: DeliveryToolFixture.library)
        addRepeat(rig, weekday: Self.wednesday, from: 19 * 60 + 30, to: 20 * 60 + 30, first: Self.firstWednesday,
                  place: DeliveryToolFixture.corner)
        await rig.hold()
        let card = rig.order().card
        XCTAssertFalse(shows(card, "9 Library Road"), "two different places give none")
        XCTAssertFalse(shows(card, "Corner Cafe"), "two different places give none")
    }

    func testO39_AOneOffAndARepeatingOccurrenceAtTheSamePlaceGiveThatOneText() async throws {
        let rig = makeRig()
        rig.seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", place: DeliveryToolFixture.library)
        addRepeat(rig, weekday: Self.wednesday, from: 19 * 60 + 30, to: 20 * 60 + 30, first: Self.firstWednesday,
                  place: DeliveryToolFixture.library)
        await rig.hold()
        let card = try XCTUnwrap(rig.order().card)
        XCTAssertTrue(shows(card, "9 Library Road"))
    }

    func testO40_AnOccurrenceInProgressAtNowIsTheSecondAnchorAndTheEdgesOfTheIntervalHold() async throws {
        // Only in progress now (Tuesday 08:00 to 10:00), nothing at the arrival: the second anchor.
        let nowOnly = makeRig()
        addRepeat(nowOnly, weekday: Self.tuesday, from: 8 * 60, to: 10 * 60, first: Self.firstTuesday, place: DeliveryToolFixture.corner)
        await nowOnly.hold()
        let nowCard = try XCTUnwrap(nowOnly.order().card, "the occurrence in progress now is the suggestion")
        XCTAssertTrue(shows(nowCard, "Corner Cafe"))

        // Entries at the arrival that differ give none, and the later anchor is not used.
        let differ = makeRig()
        differ.seed("Team dinner", "2026-10-28T19:00", "2026-10-28T21:00", place: DeliveryToolFixture.library)
        differ.seed("Other", "2026-10-28T19:30", "2026-10-28T20:30", place: DeliveryToolFixture.restaurant)
        addRepeat(differ, weekday: Self.tuesday, from: 8 * 60, to: 10 * 60, first: Self.firstTuesday, place: DeliveryToolFixture.corner)
        await differ.hold()
        let differCard = differ.order().card
        XCTAssertFalse(shows(differCard, "Corner Cafe"), "the later anchor is not used")
        XCTAssertFalse(shows(differCard, "9 Library Road"), "two different places give none")

        // An occurrence that starts at the arrival minute counts.
        let starts = makeRig()
        addRepeat(starts, weekday: Self.wednesday, from: 19 * 60 + 40, to: 21 * 60, first: Self.firstWednesday, place: DeliveryToolFixture.library)
        await starts.hold()
        let startsCard = try XCTUnwrap(starts.order().card, "an occurrence that starts at the arrival minute counts")
        XCTAssertTrue(shows(startsCard, "9 Library Road"))

        // One that ends at the arrival minute does not.
        let ends = makeRig()
        addRepeat(ends, weekday: Self.wednesday, from: 18 * 60, to: 19 * 60 + 40, first: Self.firstWednesday, place: DeliveryToolFixture.library)
        await ends.hold()
        XCTAssertFalse(shows(ends.order().card, "9 Library Road"), "an occurrence that ends at the arrival minute does not count")

        // One in progress at both anchors (now is 19:00 the same day) is read once and suggested.
        let both = makeRig()
        both.clock.now = TestClock.date("2026-10-28T19:00")
        addRepeat(both, weekday: Self.wednesday, from: 18 * 60, to: 21 * 60, first: Self.firstWednesday, place: DeliveryToolFixture.library)
        await both.hold()
        let bothCard = try XCTUnwrap(both.order().card, "an occurrence in progress at both anchors is suggested")
        XCTAssertTrue(shows(bothCard, "9 Library Road"))
    }
}
