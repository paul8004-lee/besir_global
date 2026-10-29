import XCTest
@testable import besir

/// The simulated budget app as the Worker route behaves: it computes its answer from the request alone and keeps nothing.
/// It records every request and can be told to fail instead.
final class BudgetToolPartner {
    enum Mode {
        case worker
        case status(Int, String)
        case error(Error)
    }

    var mode: Mode = .worker
    private(set) var requests: [URLRequest] = []
    /// Runs inside the send call, before the answer is handed back.
    var duringSend: (() -> Void)?

    var send: BudgetClient.Send {
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
                let amount = sent["amount_cents"] as? Int
                let total = (sent["spent_cents"] as? Int ?? 0) + (amount ?? 0)
                var answer: [String: Any] = ["partner": "Example Budget", "simulated": true, "op": sent["op"] ?? "",
                                             "week_start": sent["week_start"] ?? "", "spent_cents": total, "budget_cents": 20000,
                                             "left_cents": 20000 - total, "status": 20000 - total >= 0 ? "within" : "over"]
                if let amount { answer["amount_cents"] = amount }
                let data = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    /// The JSON object of the nth request body.
    func body(_ index: Int = 0) -> [String: Any]? {
        guard requests.indices.contains(index), let data = requests[index].httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum BudgetToolFixture {
    static let host = "budget-tool-host.invalid"
    static let token = "budget-tool-token-0001"
    static let config = AppConfig(kakaoJsKey: "", proxyBaseURL: "https://" + host, appToken: token)
    static let unconfigured = AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: "")
    /// The Monday of the fixed clock's week (the clock is Tuesday 2026-10-27T09:00).
    static let week = "2026-10-26"
}

/// A toolbox over an empty Store with the fixed clock, a stubbed table partner, a stubbed budget partner, a ledger and a
/// connection log on temporary files.
@MainActor
final class BudgetToolRig {
    let store: Store
    let clock: MutableClock
    let partner: BudgetToolPartner
    let tables: EchoPartner
    let log: ConnectionLog
    let ledger: BudgetLedger
    let box: BookingConfigBox
    let tools: AgentToolbox
    let folder: URL

    var ledgerFile: URL { folder.appendingPathComponent(BudgetLedger.fileName) }

    init(config: AppConfig = BudgetToolFixture.config, partner: BudgetToolPartner = BudgetToolPartner(),
         tables: EchoPartner = EchoPartner(), places: [Place] = [BookingFixture.place]) {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let clock = MutableClock()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("budget-tool-\(UUID().uuidString)", isDirectory: true)
        let log = ConnectionLog(fileURL: folder.appendingPathComponent(ConnectionLog.fileName),
                                secrets: { [BudgetToolFixture.token, BudgetToolFixture.host] })
        let ledger = BudgetLedger(fileURL: folder.appendingPathComponent(BudgetLedger.fileName))
        let box = BookingConfigBox(config)
        let toolbox = AgentToolbox(store: store, now: { clock.now }, timeZone: { clock.zone },
                                   booking: { BookingClient(config: box.config, send: tables.send, connections: log) },
                                   budget: { BudgetClient(config: box.config, ledger: ledger, send: partner.send, connections: log) })
        _ = toolbox.registry.register(places)
        self.store = store
        self.clock = clock
        self.partner = partner
        self.tables = tables
        self.log = log
        self.ledger = ledger
        self.box = box
        self.folder = folder
        tools = toolbox
    }

    func call(_ name: String, _ args: [String: Any] = [:], flow: UUID? = nil) -> AgentToolOutcome {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return tools.handle(name: name, arguments: String(decoding: data, as: UTF8.self), flow: flow)
    }

    func spend(_ amount: Any, flow: UUID? = nil) -> AgentToolOutcome {
        call("record_spend", ["amount": amount], flow: flow)
    }

    /// Runs a lookup to its end and reads the result; nil when the outcome is not a lookup.
    func run(_ outcome: AgentToolOutcome) async -> [String: Any]? {
        guard let lookup = outcome.lookup else { return nil }
        let output = await lookup.run()
        return TestClock.object(output.result)
    }

    /// `run`, with the result required.
    func runJSON(_ outcome: AgentToolOutcome, _ note: String = "") async throws -> [String: Any] {
        let json = await run(outcome)
        return try XCTUnwrap(json, note)
    }

    /// The packets once the log has written them.
    func packets() async -> [ConnectionPacket] {
        await log.flush()
        return log.packets
    }

    func lines() async -> [String] {
        await packets().map { "\($0.from.rawValue)>\($0.to.rawValue) \($0.kind.rawValue) \($0.status.rawValue) \($0.summary)" }
    }

    /// The entries in `budget.json`, or an empty list when the file is not there.
    var entries: [[String: Any]] {
        guard let data = try? Data(contentsOf: ledgerFile) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    /// A byte-for-byte picture of the schedule.
    var snapshot: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(store.activities)) ?? Data(), as: UTF8.self)
    }

    func hold(_ cents: Int, estimate: Bool = false, week: String = BudgetToolFixture.week) {
        ledger.add(BudgetEntry(requestID: UUID().uuidString, weekStart: week, amountCents: cents, isEstimate: estimate))
    }
}

/// SPEC-BUDGET-001 AC-BUDGET-006 to 010: the two tools, the gate, the lookups and the booking hook.
@MainActor
final class AgentBudgetToolTests: XCTestCase {
    private func makeRig(config: AppConfig = BudgetToolFixture.config, partner: BudgetToolPartner = BudgetToolPartner(),
                         tables: EchoPartner = EchoPartner()) -> BudgetToolRig {
        let rig = BudgetToolRig(config: config, partner: partner, tables: tables)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    private enum Text {
        static let unavailable = "Tell the user the budget is not available right now. Do not call get_budget_left or record_spend again."
        static let amount = "Ask the user how much they spent, as digits with an optional decimal point such as 18.50, then call record_spend again. Do not guess it."
        static func wrongType(_ param: String) -> String {
            "Call record_spend again with \(param) as a string. If you do not have it, ask the user; do not guess it."
        }
        static let notObject = "Call record_spend again with a valid JSON object of arguments."
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

    /// Amounts the gate refuses (the G04 list).
    private let refusedAmounts = ["", " 18", "18 ", "-5", "+5", "1,000", "$18", "18.", ".5", "0", "0.00", "0.001", "10000.01", "100000",
                                  "1e2", "\u{0661}\u{0668}", "NaN"]

    // MARK: G01 the declarations

    func testBUDGET_G01_ElevenDeclarationsTheNewTwoSitBeforeRequestBookingAndAreStrict() throws {
        let decls = declarations()
        XCTAssertEqual(decls.count, 11)
        XCTAssertEqual(decls.compactMap { $0["name"] as? String },
                       ["list_activities", "create_activity", "update_activity", "delete_activity", "search_places",
                        "get_travel_time", "check_day_plan", "show_day_plan", "get_budget_left", "record_spend", "request_booking"])
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tools", withExtension: "json"))
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(recorded.count, 11)
        for index in decls.indices {
            XCTAssertTrue((decls[index] as AnyObject).isEqual(recorded[index]), "declaration \(index) differs from the fixture")
        }
        XCTAssertEqual(decls.last?["name"] as? String, "request_booking")

        let left = decls[8]
        XCTAssertEqual(left["type"] as? String, "function")
        let leftParameters = try XCTUnwrap(left["parameters"] as? [String: Any])
        XCTAssertEqual((leftParameters["properties"] as? [String: Any])?.count, 0)
        XCTAssertEqual(leftParameters["additionalProperties"] as? Bool, false)
        XCTAssertNil(leftParameters["required"])

        let spend = decls[9]
        XCTAssertEqual(spend["type"] as? String, "function")
        let spendParameters = try XCTUnwrap(spend["parameters"] as? [String: Any])
        XCTAssertEqual(spendParameters["required"] as? [String], ["amount"])
        XCTAssertEqual(spendParameters["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(spendParameters["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["amount"])
        XCTAssertEqual((properties["amount"] as? [String: Any])?["type"] as? String, "string")

        for decl in [left, spend] {
            let description = try XCTUnwrap(decl["description"] as? String).lowercased()
            XCTAssertTrue(description.contains("simulated"), "\(decl["name"] ?? "?")")
        }
        let spendText = try XCTUnwrap(spend["description"] as? String).lowercased()
        XCTAssertTrue(spendText.contains("food") || spendText.contains("dining"))
        XCTAssertTrue(spendText.contains("no confirmation"))
        let found = keys(in: decls)
        XCTAssertFalse(found.contains("enum"))
        XCTAssertFalse(found.contains("pattern"))
        XCTAssertEqual(AgentSession.knownToolNames().intersection(["get_budget_left", "record_spend"]).count, 2)
    }

    // MARK: G02-G08 the gate

    func testBUDGET_G02_GetBudgetLeftNeverReadsAnUndeclaredKeyAndAcceptsABlankArgumentsText() async throws {
        let rig = makeRig()
        let extras: [String: Any] = ["name": "SENTINEL-NAME-1", "amount": "SENTINEL-AMOUNT-1", "payment": "SENTINEL-CARD-1", "week": 5,
                                     "duration": ["x"]]
        let result = await rig.run(rig.call("get_budget_left", extras))
        XCTAssertEqual(result?["status"] as? String, "ok", "undeclared keys, even of a wrong type, are dropped")
        let sent = try XCTUnwrap(rig.partner.body())
        XCTAssertEqual(Set(sent.keys), ["op", "week_start", "spent_cents"])
        XCTAssertFalse(String(decoding: try XCTUnwrap(rig.partner.requests.first?.httpBody), as: UTF8.self).contains("SENTINEL"))

        for text in ["", "   ", " \n\t ", "{}"] {
            let outcome = rig.tools.handle(name: "get_budget_left", arguments: text)
            XCTAssertTrue(outcome.isLookup, "arguments text \(text.debugDescription)")
        }
        // Any other tool keeps its base behaviour for a blank text.
        let harness = ToolHarness.make()
        XCTAssertEqual(harness.call("list_activities", raw: "").message, ToolText.notObject("list_activities"))
        XCTAssertEqual(harness.call("create_activity", raw: "  ").message, ToolText.notObject("create_activity"))
        assertRefused(rig.tools.handle(name: "record_spend", arguments: ""), Text.notObject)
        assertRefused(rig.tools.handle(name: "record_spend", arguments: " \n "), Text.notObject)
        assertRefused(rig.tools.handle(name: "get_budget_left", arguments: "[]"), "Call get_budget_left again with a valid JSON object of arguments.")
    }

    func testBUDGET_G03_RecordSpendAcceptsAmountsAndGivesTheExactCents() async throws {
        let cases: [(String, Int)] = [("18", 1800), ("18.5", 1850), ("18.50", 1850), ("0.01", 1), ("10000", 1_000_000),
                                      ("10000.00", 1_000_000), ("00018", 1800), ("0.5", 50), ("9999.99", 999_999)]
        for (text, cents) in cases {
            XCTAssertEqual(AgentBudget.parseAmountCents(text), cents, text)
            let rig = makeRig()
            let outcome = rig.spend(text)
            XCTAssertTrue(outcome.isLookup, text)
            _ = await rig.run(outcome)
            XCTAssertEqual(rig.partner.body()?["amount_cents"] as? Int, cents, text)
        }
        // The largest five-digit text is above the limit and is refused.
        XCTAssertNil(AgentBudget.parseAmountCents("99999"))
        XCTAssertEqual(AgentBudget.dollars(cents: 1_000_000), "$10,000.00")
    }

    func testBUDGET_G04_RecordSpendRefusesEveryOtherAmountText() async {
        let rig = makeRig()
        for text in refusedAmounts {
            XCTAssertNil(AgentBudget.parseAmountCents(text), text.debugDescription)
            let outcome = rig.spend(text)
            XCTAssertFalse(outcome.isLookup, text.debugDescription)
            assertRefused(outcome, Text.amount, text.debugDescription)
        }
        XCTAssertEqual(rig.partner.requests.count, 0)
    }

    func testBUDGET_G05_ANonStringAmountGetsTheStringMessageAndNeverOmit() {
        let rig = makeRig()
        let wrong: [Any] = [5, 2.5, true, false, NSNull(), ["a"], ["a": 1]]
        for value in wrong {
            let outcome = rig.spend(value)
            assertRefused(outcome, Text.wrongType("amount"), "\(value)")
            XCTAssertFalse((outcome.message ?? "").contains("omit"))
        }
        XCTAssertEqual(rig.partner.requests.count, 0)
    }

    func testBUDGET_G06_AMissingOrBlankAmountTellsTheModelToAskTheUser() {
        let rig = makeRig()
        assertRefused(rig.call("record_spend", [:]), Text.amount, "missing")
        assertRefused(rig.spend(""), Text.amount, "empty")
        assertRefused(rig.spend("   "), Text.amount, "blank")
        assertRefused(rig.spend("\n"), Text.amount, "newline")
        XCTAssertTrue(Text.amount.contains("Ask the user"))
        XCTAssertTrue(Text.amount.contains("Do not guess"))
        XCTAssertEqual(rig.partner.requests.count, 0)
    }

    func testBUDGET_G07_WithNoProxyBothToolsGiveTheUnavailableMessageAndSendNothing() {
        let rig = makeRig(config: BudgetToolFixture.unconfigured)
        assertRefused(rig.call("get_budget_left"), Text.unavailable)
        assertRefused(rig.tools.handle(name: "get_budget_left", arguments: ""), Text.unavailable)
        assertRefused(rig.spend("18"), Text.unavailable)
        // The proxy comes first: a bad or missing amount gets the same message.
        assertRefused(rig.spend("0"), Text.unavailable)
        assertRefused(rig.spend(5), Text.unavailable)
        assertRefused(rig.call("record_spend", [:]), Text.unavailable)
        XCTAssertEqual(rig.partner.requests.count, 0)
        XCTAssertTrue(rig.entries.isEmpty)
        // The same rig with a proxy accepts the same calls.
        rig.box.config = BudgetToolFixture.config
        XCTAssertTrue(rig.call("get_budget_left").isLookup)
        XCTAssertTrue(rig.spend("18").isLookup)
    }

    func testBUDGET_G08_EveryReAskStringNamesOnlyDeclaredNamesAndRepeatsNoModelValue() throws {
        let sentinel = "SENTINEL-MODEL-VALUE"
        let rig = makeRig()
        var messages: [String] = []
        let values: [Any] = refusedAmounts as [Any] + [sentinel, 5, true, NSNull()]
        for value in values {
            messages.append(try XCTUnwrap(rig.spend(value).message))
        }
        messages.append(try XCTUnwrap(rig.call("record_spend", [:]).message))
        messages.append(try XCTUnwrap(rig.tools.handle(name: "record_spend", arguments: "").message))
        messages.append(try XCTUnwrap(rig.tools.handle(name: "get_budget_left", arguments: "[1]").message))
        let unconfigured = makeRig(config: BudgetToolFixture.unconfigured)
        messages.append(try XCTUnwrap(unconfigured.call("get_budget_left").message))
        messages.append(try XCTUnwrap(unconfigured.spend("18").message))

        let others = ["list_activities", "create_activity", "update_activity", "delete_activity", "search_places", "get_travel_time",
                      "check_day_plan", "show_day_plan", "request_booking", "place_id", "party_size", "route_id", "plan_id", "stops",
                      "origin_place_id", "arrive_by"]
        for message in messages {
            for other in others { XCTAssertFalse(message.contains(other), "\(message) names \(other)") }
            XCTAssertFalse(message.contains(sentinel), message)
            XCTAssertTrue(message.contains("record_spend") || message.contains("get_budget_left"), message)
        }
        XCTAssertEqual(Set(messages), [Text.amount, Text.wrongType("amount"), Text.notObject,
                                       "Call get_budget_left again with a valid JSON object of arguments.", Text.unavailable])

        // The re-ask strings of the old tools are the base text.
        let harness = ToolHarness.make()
        XCTAssertEqual(harness.call("create_activity", ["title": 5, "start": "x", "end": "y"]).message,
                       ToolText.wrongType("create_activity", "title"))
        XCTAssertEqual(harness.call("update_activity", ["id": 5]).message, ToolText.wrongType("update_activity", "id"))
        XCTAssertEqual(harness.call("list_activities", ["from": 5, "to": "x"]).message, ToolText.wrongType("list_activities", "from"))
        let booking = makeRig()
        XCTAssertEqual(booking.call("request_booking", ["place_id": "p1", "start": BookingFixture.start, "party_size": 5]).message,
                       "Call request_booking again with party_size as a string. If you do not have it, ask the user; do not guess it.")
        let noProxy = makeRig(config: BudgetToolFixture.unconfigured)
        XCTAssertEqual(noProxy.call("request_booking", ["place_id": "p1", "start": BookingFixture.start, "party_size": "2"]).message,
                       "Tell the user booking is not available right now. Do not call request_booking again.")
    }

    // MARK: G09-G14 get_budget_left

    func testBUDGET_G09_GetBudgetLeftWithinGivesTheKeysAndDollarStrings() async throws {
        let rig = makeRig()
        rig.hold(5000)
        rig.hold(2500, week: "2026-11-02")
        let outcome = rig.call("get_budget_left")
        XCTAssertTrue(outcome.isLookup)
        XCTAssertNil(outcome.card)
        let result = try await rig.runJSON(outcome)
        XCTAssertEqual(Set(result.keys), ["status", "partner", "simulated", "week_start", "budget", "spent", "standing",
                                          "includes_estimate", "left", "message"])
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["partner"] as? String, "Example Budget")
        XCTAssertEqual(result["simulated"] as? Bool, true)
        XCTAssertEqual(result["week_start"] as? String, BudgetToolFixture.week)
        XCTAssertEqual(result["budget"] as? String, "$200.00")
        XCTAssertEqual(result["spent"] as? String, "$50.00")
        XCTAssertEqual(result["left"] as? String, "$150.00")
        XCTAssertEqual(result["standing"] as? String, "within")
        XCTAssertEqual(result["includes_estimate"] as? Bool, false)
        XCTAssertEqual(result["message"] as? String, AgentBudget.leftMessage)
        let message = (result["message"] as? String ?? "").lowercased()
        XCTAssertTrue(message.contains("simulated"))
        XCTAssertTrue(message.contains("fact"))
        XCTAssertTrue(message.contains("no advice"))
        XCTAssertTrue(message.contains("estimated spending"))
        let sent = try XCTUnwrap(rig.partner.body())
        XCTAssertEqual(sent["op"] as? String, "left")
        XCTAssertEqual(sent["week_start"] as? String, BudgetToolFixture.week)
        XCTAssertEqual(sent["spent_cents"] as? Int, 5000)
    }

    func testBUDGET_G10_GetBudgetLeftOverGivesOverByAndNoLeft() async throws {
        let rig = makeRig()
        rig.hold(23000)
        let result = try await rig.runJSON(rig.call("get_budget_left"))
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["standing"] as? String, "over")
        XCTAssertEqual(result["over_by"] as? String, "$30.00")
        XCTAssertNil(result["left"])
        XCTAssertEqual(result["spent"] as? String, "$230.00")
        XCTAssertEqual(Set(result.keys), ["status", "partner", "simulated", "week_start", "budget", "spent", "standing",
                                          "includes_estimate", "over_by", "message"])
        // Exactly the budget is not over.
        let edge = makeRig()
        edge.hold(20000)
        let atEdge = try await edge.runJSON(edge.call("get_budget_left"))
        XCTAssertEqual(atEdge["standing"] as? String, "within")
        XCTAssertEqual(atEdge["left"] as? String, "$0.00")
    }

    func testBUDGET_G11_IncludesEstimateFollowsTheLedger() async throws {
        let actual = makeRig()
        actual.hold(1850)
        let first = try await actual.runJSON(actual.call("get_budget_left"))
        XCTAssertEqual(first["includes_estimate"] as? Bool, false)

        let estimated = makeRig()
        estimated.hold(1850)
        estimated.hold(6000, estimate: true)
        let second = try await estimated.runJSON(estimated.call("get_budget_left"))
        XCTAssertEqual(second["includes_estimate"] as? Bool, true)

        // An estimate in another week does not count.
        let other = makeRig()
        other.hold(6000, estimate: true, week: "2026-11-02")
        let third = try await other.runJSON(other.call("get_budget_left"))
        XCTAssertEqual(third["includes_estimate"] as? Bool, false)
    }

    func testBUDGET_G12_AFailedRequestGivesUnavailableWithTheFixedMessage() async throws {
        let modes: [(String, BudgetToolPartner.Mode)] = [
            ("offline", .error(URLError(.notConnectedToInternet))), ("token", .status(401, #"{"error":"unauthorized"}"#)),
            ("missing route", .status(404, "Not found")), ("server", .status(500, "oops")), ("bad body", .status(200, "[]")),
        ]
        for (name, mode) in modes {
            let rig = makeRig()
            rig.partner.mode = mode
            let result = try await rig.runJSON(rig.call("get_budget_left"), name)
            XCTAssertEqual(Set(result.keys), ["status", "partner", "simulated", "message"], name)
            XCTAssertEqual(result["status"] as? String, "unavailable", name)
            XCTAssertEqual(result["partner"] as? String, "Example Budget", name)
            XCTAssertEqual(result["simulated"] as? Bool, true, name)
            XCTAssertEqual(result["message"] as? String, AgentBudget.leftUnavailableMessage, name)
        }
        // The proxy was set up when the tool was called and gone when the lookup ran.
        let gone = makeRig()
        let outcome = gone.call("get_budget_left")
        gone.box.config = BudgetToolFixture.unconfigured
        let result = try await gone.runJSON(outcome)
        XCTAssertEqual(result["status"] as? String, "unavailable")
        XCTAssertEqual(gone.partner.requests.count, 0)
    }

    func testBUDGET_G13_TheLookupRunsUnderTheMessagesFlowId() async throws {
        let rig = makeRig()
        let flow = UUID()
        _ = await rig.run(rig.call("get_budget_left", flow: flow))
        var packets = await rig.packets()
        XCTAssertEqual(packets.map(\.flowID), [flow, flow])
        XCTAssertEqual(packets.map(\.summary), ["Budget left asked", "Budget left answered"])
        XCTAssertEqual(packets.map(\.status), [.ok, .ok])
        XCTAssertEqual(packets.map(\.kind), [.budget, .budget])
        XCTAssertEqual(packets.map(\.from), [.besir, .budgetPartner])
        XCTAssertEqual(packets.map(\.to), [.budgetPartner, .besir])
        // Another message, another flow.
        let second = UUID()
        _ = await rig.run(rig.call("get_budget_left", flow: second))
        packets = await rig.packets()
        XCTAssertEqual(packets.suffix(2).map(\.flowID), [second, second])
        // No flow given: the packets still share one.
        _ = await rig.run(rig.call("get_budget_left"))
        packets = await rig.packets()
        let last = packets.suffix(2).map(\.flowID)
        XCTAssertNotNil(last[0])
        XCTAssertEqual(last[0], last[1])
        XCTAssertNotEqual(last[0], flow)
    }

    func testBUDGET_G14_GetBudgetLeftWritesNothingToTheLedger() async throws {
        let rig = makeRig()
        rig.hold(1850)
        let before = rig.entries
        XCTAssertEqual(before.count, 1)
        for _ in 0..<2 { _ = await rig.run(rig.call("get_budget_left")) }
        XCTAssertEqual(rig.partner.requests.count, 2)
        XCTAssertEqual(rig.entries.count, 1)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 1850)
        XCTAssertEqual(NSArray(array: rig.entries), NSArray(array: before))
        let fresh = makeRig()
        _ = await fresh.run(fresh.call("get_budget_left"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.ledgerFile.path), "an empty ledger is never written")
    }

    // MARK: G15-G20 record_spend

    func testBUDGET_G15_RecordSpendReturnsALookupNotACardAndSendsNothingUntilItRuns() async throws {
        let rig = makeRig()
        let outcome = rig.spend("18.50")
        XCTAssertTrue(outcome.isLookup)
        XCTAssertNil(outcome.card)
        XCTAssertNil(outcome.resultText)
        XCTAssertEqual(rig.partner.requests.count, 0)
        XCTAssertTrue(rig.entries.isEmpty)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 0)
        let packets = await rig.packets()
        XCTAssertTrue(packets.isEmpty)
        // Nothing but the lookup: there is no card to confirm, so running it is the whole write.
        _ = await rig.run(outcome)
        XCTAssertEqual(rig.partner.requests.count, 1)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 1850)
    }

    func testBUDGET_G16_RunningTheLookupSendsOneSpendAndGivesTheAppliedResult() async throws {
        let rig = makeRig()
        // Sunday night: the week is the one that began on Monday 2026-10-26.
        rig.clock.now = TestClock.date("2026-11-01T23:59")
        let flow = UUID()
        let outcome = rig.spend("18.50", flow: flow)
        // The clock moves past midnight between the call and the run: the week was made at the call.
        rig.clock.now = TestClock.date("2026-11-02T00:01")
        let result = try await rig.runJSON(outcome)

        XCTAssertEqual(rig.partner.requests.count, 1)
        let sent = try XCTUnwrap(rig.partner.body())
        XCTAssertEqual(Set(sent.keys), ["op", "week_start", "spent_cents", "amount_cents", "request_id"])
        XCTAssertEqual(sent["op"] as? String, "spend")
        XCTAssertEqual(sent["week_start"] as? String, "2026-10-26")
        XCTAssertEqual(sent["spent_cents"] as? Int, 0)
        XCTAssertEqual(sent["amount_cents"] as? Int, 1850)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(sent["request_id"] as? String)))

        let entries = rig.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(Set(entries[0].keys), ["requestID", "weekStart", "amountCents", "isEstimate"])
        XCTAssertEqual(entries[0]["weekStart"] as? String, "2026-10-26")
        XCTAssertEqual(entries[0]["amountCents"] as? Int, 1850)
        XCTAssertEqual(entries[0]["isEstimate"] as? Bool, false)
        XCTAssertEqual(entries[0]["requestID"] as? String, sent["request_id"] as? String)
        XCTAssertFalse(rig.ledger.hasEstimate(weekStart: "2026-10-26"))

        XCTAssertEqual(Set(result.keys), ["status", "partner", "simulated", "week_start", "budget", "spent", "standing",
                                          "includes_estimate", "left", "recorded", "message"])
        XCTAssertEqual(result["status"] as? String, "applied")
        XCTAssertEqual(result["partner"] as? String, "Example Budget")
        XCTAssertEqual(result["simulated"] as? Bool, true)
        XCTAssertEqual(result["recorded"] as? String, "$18.50")
        XCTAssertEqual(result["spent"] as? String, "$18.50")
        XCTAssertEqual(result["left"] as? String, "$181.50")
        XCTAssertEqual(result["standing"] as? String, "within")
        XCTAssertEqual(result["includes_estimate"] as? Bool, false)
        XCTAssertEqual(result["week_start"] as? String, "2026-10-26")
        XCTAssertEqual(result["message"] as? String, AgentBudget.spendMessage)
        let message = (result["message"] as? String ?? "").lowercased()
        XCTAssertTrue(message.contains("simulated"))
        XCTAssertTrue(message.contains("amount recorded"))
        XCTAssertTrue(message.contains("no advice"))

        let packets = await rig.packets()
        XCTAssertEqual(packets.map(\.summary), ["Spend sent", "Spend recorded"])
        XCTAssertEqual(packets.map(\.flowID), [flow, flow])
    }

    func testBUDGET_G17_TwoCallsMakeTwoRequestIdsAndOneCallSendsAtMostOneRequest() async throws {
        let rig = makeRig()
        let first = rig.spend("5")
        let second = rig.spend("5")
        _ = await rig.run(first)
        _ = await rig.run(second)
        XCTAssertEqual(rig.partner.requests.count, 2)
        let ids = [0, 1].compactMap { rig.partner.body($0)?["request_id"] as? String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(rig.entries.count, 2)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 1000)
        XCTAssertEqual(rig.partner.body(1)?["spent_cents"] as? Int, 500)

        // The same lookup run again sends nothing: its request id is already in the ledger.
        let once = rig.spend("7")
        let ran = try await rig.runJSON(once)
        XCTAssertEqual(ran["status"] as? String, "applied")
        XCTAssertEqual(rig.partner.requests.count, 3)
        let again = try await rig.runJSON(once)
        XCTAssertEqual(again["status"] as? String, "unavailable")
        XCTAssertEqual(rig.partner.requests.count, 3)
        XCTAssertEqual(rig.entries.count, 3)
    }

    func testBUDGET_G18_ARefusedOrUnreadableAmountSendsWritesAndRecordsNothing() async throws {
        let rig = makeRig()
        let bad: [Any] = refusedAmounts as [Any] + [5, true, NSNull(), "   "]
        for value in bad {
            let outcome = rig.spend(value)
            XCTAssertFalse(outcome.isLookup, "\(value)")
            XCTAssertEqual(outcome.status, "rejected", "\(value)")
        }
        XCTAssertEqual(rig.call("record_spend", [:]).status, "rejected")
        XCTAssertEqual(rig.partner.requests.count, 0)
        XCTAssertTrue(rig.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ledgerFile.path))
        let packets = await rig.packets()
        XCTAssertTrue(packets.isEmpty)
    }

    func testBUDGET_G19_AFailedRequestGivesUnavailableAndAddsNothing() async throws {
        let modes: [(String, BudgetToolPartner.Mode)] = [
            ("offline", .error(URLError(.notConnectedToInternet))), ("server", .status(500, "oops")),
            ("missing route", .status(404, "Not found")), ("token", .status(401, #"{"error":"unauthorized"}"#)),
        ]
        for (name, mode) in modes {
            let rig = makeRig()
            rig.hold(1000)
            rig.partner.mode = mode
            let result = try await rig.runJSON(rig.spend("18.50"), name)
            XCTAssertEqual(Set(result.keys), ["status", "partner", "simulated", "message"], name)
            XCTAssertEqual(result["status"] as? String, "unavailable", name)
            XCTAssertEqual(result["simulated"] as? Bool, true, name)
            XCTAssertEqual(result["message"] as? String, AgentBudget.spendUnavailableMessage, name)
            let message = (result["message"] as? String ?? "").lowercased()
            XCTAssertTrue(message.contains("could not be recorded") && message.contains("nothing was added"), name)
            XCTAssertEqual(rig.partner.requests.count, 1, name)
            XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 1000, name)
            XCTAssertEqual(rig.entries.count, 1, name)
            let lines = await rig.lines()
            XCTAssertEqual(lines, ["besir>budgetPartner budget failed Request failed"], name)
        }
    }

    func testBUDGET_G20_ATaskCancelledInFlightGivesUnavailableAndAddsNothing() async throws {
        let rig = makeRig()
        rig.partner.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let outcome = rig.spend("18.50")
        let lookup = try XCTUnwrap(outcome.lookup)
        let output = await Task { await lookup.run() }.value
        let result = try XCTUnwrap(TestClock.object(output.result))
        XCTAssertEqual(rig.partner.requests.count, 1, "the stub answered a valid spend")
        XCTAssertEqual(result["status"] as? String, "unavailable")
        XCTAssertEqual(result["message"] as? String, AgentBudget.spendUnavailableMessage)
        XCTAssertTrue(rig.entries.isEmpty)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 0)
        let packets = await rig.packets()
        XCTAssertTrue(packets.isEmpty)
    }
}
