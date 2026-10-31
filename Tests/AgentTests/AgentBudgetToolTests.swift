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
    let tables: StubPartner
    let log: ConnectionLog
    let ledger: BudgetLedger
    let box: BookingConfigBox
    let tools: AgentToolbox
    let folder: URL

    var ledgerFile: URL { folder.appendingPathComponent(BudgetLedger.fileName) }

    init(config: AppConfig = BudgetToolFixture.config, partner: BudgetToolPartner = BudgetToolPartner(),
         tables: StubPartner = StubPartner(), places: [Place] = [BookingFixture.place], injectBudget: Bool = true) {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let clock = MutableClock()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("budget-tool-\(UUID().uuidString)", isDirectory: true)
        let log = ConnectionLog(fileURL: folder.appendingPathComponent(ConnectionLog.fileName),
                                secrets: { [BudgetToolFixture.token, BudgetToolFixture.host] })
        let ledger = BudgetLedger(fileURL: folder.appendingPathComponent(BudgetLedger.fileName))
        let box = BookingConfigBox(config)
        // Without an injected budget client the toolbox builds its own from the Store's configuration (no proxy here).
        let budget: (() -> BudgetClient)? = injectBudget
            ? { BudgetClient(config: box.config, ledger: ledger, send: partner.send, connections: log) } : nil
        let toolbox = AgentToolbox(store: store, now: { clock.now }, timeZone: { clock.zone },
                                   partners: { PartnerClient(config: box.config, send: tables.send, connections: log) },
                                   budget: budget)
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

/// SPEC-BUDGET-001 AC-BUDGET-006 to 010: the two tools, the gate, the lookups and the partner request hook.
@MainActor
final class AgentBudgetToolTests: XCTestCase {
    private func makeRig(config: AppConfig = BudgetToolFixture.config, partner: BudgetToolPartner = BudgetToolPartner(),
                         tables: StubPartner = StubPartner(), places: [Place] = [BookingFixture.place],
                         injectBudget: Bool = true) -> BudgetToolRig {
        let rig = BudgetToolRig(config: config, partner: partner, tables: tables, places: places, injectBudget: injectBudget)
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

    func testBUDGET_G01_FourteenDeclarationsTheBudgetTwoSitBeforeTheLastTwoAndAreStrict() throws {
        let decls = declarations()
        XCTAssertEqual(decls.count, 12)
        XCTAssertEqual(decls.compactMap { $0["name"] as? String },
                       ["list_activities", "create_activity", "update_activity", "delete_activity", "search_places",
                        "get_travel_time", "check_day_plan", "show_day_plan", "get_budget_left", "record_spend", "get_partners", "request_partner"])
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tools", withExtension: "json"))
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(recorded.count, 12)
        for index in decls.indices {
            XCTAssertTrue((decls[index] as AnyObject).isEqual(recorded[index]), "declaration \(index) differs from the fixture")
        }
        XCTAssertEqual(decls.last?["name"] as? String, "request_partner")

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
                      "check_day_plan", "show_day_plan", "request_partner", "place_id", "party_size", "route_id", "plan_id", "stops",
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
        let partner = makeRig()
        XCTAssertEqual(partner.call("request_partner", ["partner": 5]).message,
                       "Call request_partner again with partner as a string, an id from the get_partners answer.")
        let noProxy = makeRig(config: BudgetToolFixture.unconfigured)
        XCTAssertEqual(noProxy.call("get_partners").message,
                       "Tell the user partners are not available right now. Do not call get_partners or request_partner again.")
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

    // MARK: G21-G32 the partner request hook

    /// The card of a partner request: the chat line is set as the user's, `get_partners` runs, then `request_partner` is called
    /// with the party and the start (and a restaurant and a name), each with a quote.
    private func partnerCard(_ rig: BudgetToolRig, party: String = "2", start: String = BookingFixture.start,
                             restaurant: String = "Pasta Palace", name: String = "Sam") async throws -> AgentCard {
        let fill = PartnerRig.Fill(restaurant: restaurant, party: Int(party), start: start, name: name)
        let line = PartnerRig.parts(fill).line
        rig.tools.userLines = { [line] }
        _ = try await rig.runJSON(rig.call("get_partners"))
        return try XCTUnwrap(rig.call("request_partner", PartnerRig.arguments(fill)).card)
    }

    private func confirmed(_ card: AgentCard) async throws -> AgentResolution {
        let resolution = await card.resolve(.confirm)
        return try XCTUnwrap(resolution)
    }

    private func budgetPackets(_ rig: BudgetToolRig) async -> [ConnectionPacket] {
        await rig.packets().filter { $0.kind == .budget }
    }

    func testBUDGET_G21_AConfirmedBookingSendsItsEstimatedSpendUnderTheBookingsFlow() async throws {
        let rig = makeRig()
        let resolution = try await confirmed(try await partnerCard(rig))
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(rig.tables.requests.count, 3, "the directory, the form and the submit")
        XCTAssertEqual(rig.partner.requests.count, 1)
        let sent = try XCTUnwrap(rig.partner.body())
        XCTAssertEqual(Set(sent.keys), ["op", "week_start", "spent_cents", "amount_cents", "request_id"])
        XCTAssertEqual(sent["op"] as? String, "spend")
        XCTAssertEqual(sent["amount_cents"] as? Int, 6000)
        XCTAssertEqual(sent["week_start"] as? String, BudgetToolFixture.week)
        XCTAssertEqual(sent["spent_cents"] as? Int, 0)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(sent["request_id"] as? String)))
        let entries = rig.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["isEstimate"] as? Bool, true)
        XCTAssertEqual(entries[0]["amountCents"] as? Int, 6000)
        XCTAssertEqual(entries[0]["weekStart"] as? String, BudgetToolFixture.week)

        let packets = await rig.packets()
        XCTAssertEqual(packets.map(\.summary), ["Partners requested", "Partners received", "Example Tables: Fields requested",
                                               "Example Tables: Fields received", "Example Tables: Request sent",
                                               "Example Tables: Request confirmed", "Spend sent", "Spend recorded"])
        XCTAssertEqual(Set(packets.map(\.flowID)).count, 2, "the lookup's flow and the request's flow")
        XCTAssertNotNil(packets.first?.flowID)
        let flows = ConnectionFlows.group(packets)
        XCTAssertEqual(flows.count, 2)
        XCTAssertEqual(flows.first?.chain, [.besir, .partner, .besir, .budgetPartner, .besir])

        // A table in the next week is counted there.
        let next = makeRig()
        _ = try await confirmed(try await partnerCard(next, start: "2026-11-02T19:00"))
        XCTAssertEqual(next.partner.body()?["week_start"] as? String, "2026-11-02")
        XCTAssertEqual(next.ledger.spentCents(weekStart: "2026-11-02"), 6000)
        XCTAssertEqual(next.ledger.spentCents(weekStart: BudgetToolFixture.week), 0)
    }

    func testBUDGET_G22_TheBookingResultGainsTheBudgetBlockAndTheSentenceAndTheNoticeIsTheWithinForm() async throws {
        let rig = makeRig()
        let card = try await partnerCard(rig)
        let resolution = try await confirmed(card)
        XCTAssertEqual(card.mark, .confirmed)
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(rig.store.activities.count, 1)
        XCTAssertEqual(resolution.notice, "Estimated spend $60.00 sent to Example Budget (Simulated): $140.00 left this week.")
        let json = try XCTUnwrap(resolution.json)
        let items = try XCTUnwrap(json["results"] as? [[String: String]])
        XCTAssertEqual(items.first { $0["name"] == "Reservation number" }?["value"], "EX-AB12CD")
        XCTAssertEqual(json["partner"] as? String, "Example Tables")
        let block = try XCTUnwrap(json["budget"] as? [String: Any])
        XCTAssertEqual(Set(block.keys), ["simulated", "status", "estimated_spend", "week", "includes_estimate", "left"])
        XCTAssertEqual(block["status"] as? String, "recorded")
        XCTAssertEqual(block["estimated_spend"] as? String, "$60.00")
        XCTAssertEqual(block["week"] as? String, "this week")
        XCTAssertEqual(block["includes_estimate"] as? Bool, true)
        XCTAssertEqual(block["left"] as? String, "$140.00")
        XCTAssertEqual(json["message"] as? String, AgentPartner.appliedMessage + " " + AgentBudget.bookingRecordedSentence)
        let sentence = AgentBudget.bookingRecordedSentence.lowercased()
        XCTAssertTrue(sentence.contains("estimate") && sentence.contains("simulated"))
        XCTAssertTrue(sentence.contains("do not call record_spend for this request"))
    }

    func testBUDGET_G23_TheOverNoticeAndTheForTheWeekOfFormForAnotherWeek() async throws {
        let over = makeRig()
        over.hold(19000)
        let first = try await confirmed(try await partnerCard(over))
        XCTAssertEqual(first.notice, "Estimated spend $60.00 sent to Example Budget (Simulated): $50.00 over the budget this week.")
        let overBlock = try XCTUnwrap(first.json?["budget"] as? [String: Any])
        XCTAssertEqual(Set(overBlock.keys), ["simulated", "status", "estimated_spend", "week", "includes_estimate", "over_by"])
        XCTAssertEqual(overBlock["over_by"] as? String, "$50.00")
        XCTAssertNil(overBlock["left"])

        let next = makeRig()
        let second = try await confirmed(try await partnerCard(next, start: "2026-11-02T19:00"))
        XCTAssertEqual(second.notice, "Estimated spend $60.00 sent to Example Budget (Simulated): $140.00 left for the week of Nov 2.")
        XCTAssertEqual((second.json?["budget"] as? [String: Any])?["week"] as? String, "week of Nov 2")

        let nextOver = makeRig()
        nextOver.hold(19000, week: "2026-11-02")
        let third = try await confirmed(try await partnerCard(nextOver, start: "2026-11-02T19:00"))
        XCTAssertEqual(third.notice,
                       "Estimated spend $60.00 sent to Example Budget (Simulated): $50.00 over the budget for the week of Nov 2.")
        XCTAssertEqual(AgentBudget.weekPhrase(weekStart: "2026-11-02", currentWeekStart: "2026-11-02"), "this week")
        XCTAssertEqual(AgentBudget.weekPhrase(weekStart: "2026-12-07", currentWeekStart: "2026-11-02"), "week of Dec 7")
    }

    func testBUDGET_G24_ADeclinedAFailedAndACancelledBookingSendNoBudgetRequest() async throws {
        let declined = makeRig()
        let declinedResolution = try await confirmed(try await partnerCard(declined, party: "9"))
        XCTAssertEqual(declinedResolution.status, "declined")
        XCTAssertNil(declinedResolution.notice)

        let failed = makeRig()
        let failedCard = try await partnerCard(failed)
        failed.tables.mode = .status(500, "oops")
        let failedResolution = try await confirmed(failedCard)
        XCTAssertEqual(failedResolution.status, "unavailable")
        XCTAssertEqual(failedResolution.notice, AgentPartner.unavailableNotice)

        let cancelled = makeRig()
        let cancelledCard = try await partnerCard(cancelled)
        let cancelledResolution = await cancelledCard.resolve(.cancel)
        XCTAssertEqual(cancelledResolution?.status, "declined")

        let late = makeRig()
        let lateCard = try await partnerCard(late)
        late.clock.now = TestClock.date("2026-10-28T19:01")
        let lateResolution = try await confirmed(lateCard)
        XCTAssertEqual(lateResolution.status, "rejected")

        for (name, rig) in [("declined", declined), ("failed", failed), ("cancelled", cancelled), ("late", late)] {
            XCTAssertEqual(rig.partner.requests.count, 0, name)
            XCTAssertTrue(rig.entries.isEmpty, name)
            let packets = await budgetPackets(rig)
            XCTAssertTrue(packets.isEmpty, name)
        }
    }

    func testBUDGET_G25_ABudgetFailureLeavesTheBookingAppliedAndSaysSo() async throws {
        let modes: [(String, BudgetToolPartner.Mode)] = [
            ("offline", .error(URLError(.notConnectedToInternet))), ("missing route", .status(404, "Not found")),
            ("server", .status(500, "oops")), ("bad body", .status(200, "[]")),
        ]
        for (name, mode) in modes {
            let rig = makeRig()
            rig.partner.mode = mode
            let card = try await partnerCard(rig)
            let resolution = try await confirmed(card)
            XCTAssertEqual(resolution.status, "applied", name)
            XCTAssertEqual(card.mark, .confirmed, name)
            XCTAssertEqual(rig.store.activities.count, 1, name)
            XCTAssertEqual(resolution.notice, "The estimated spend could not be sent to Example Budget (Simulated).", name)
            let json = try XCTUnwrap(resolution.json, name)
            XCTAssertEqual((json["results"] as? [[String: String]])?.first { $0["name"] == "Reservation number" }?["value"], "EX-AB12CD", name)
            let block = try XCTUnwrap(json["budget"] as? [String: Any], name)
            XCTAssertEqual(Set(block.keys), ["simulated", "status"], name)
            XCTAssertEqual(block["status"] as? String, "unavailable", name)
            XCTAssertEqual(block["simulated"] as? Bool, true, name)
            XCTAssertEqual(json["message"] as? String, AgentPartner.appliedMessage + " " + AgentBudget.bookingUnavailableSentence, name)
            XCTAssertTrue(rig.entries.isEmpty, name)
            XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 0, name)
            let lines = await rig.lines()
            XCTAssertEqual(lines.last, "besir>budgetPartner budget failed Request failed", name)
        }
    }

    func testBUDGET_G26_WithNoProxyTheBookingResultIsTheBaseResultWithNoNoticeAndNoBudgetPacket() async throws {
        // No budget client is injected: the default one is built from the Store's configuration, which has no proxy.
        let rig = makeRig(injectBudget: false)
        let resolution = try await confirmed(try await partnerCard(rig))
        let entry = try XCTUnwrap(rig.store.activities.first)
        let results: [[String: Any]] = [["name": "Booking time", "kind": "time", "value": BookingFixture.start],
                                        ["name": "Reservation number", "kind": "text", "value": "EX-AB12CD"],
                                        ["name": "Estimated cost", "kind": "money", "value": "$60.00"],
                                        ["name": "Partner note", "kind": "text", "value": "Table held for 15 minutes"]]
        let expected: [String: Any] = ["status": "applied", "partner": "Example Tables", "simulated": true, "results": results,
                                       "id": entry.id.uuidString, "title": entry.title, "start": BookingFixture.start,
                                       "end": TestClock.local(entry.endDate), "message": AgentPartner.appliedMessage]
        XCTAssertEqual(resolution.result, AgentToolbox.encode(expected))
        XCTAssertNil(resolution.json?["budget"])
        XCTAssertNil(resolution.notice)
        XCTAssertEqual(rig.tables.requests.count, 3)
        XCTAssertEqual(rig.partner.requests.count, 0)
        let packets = await budgetPackets(rig)
        XCTAssertTrue(packets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.ledgerFile.path))
        let lines = await rig.lines()
        XCTAssertEqual(lines, ["besir>partner partner ok Partners requested", "partner>besir partner ok Partners received",
                               "besir>partner partner ok Example Tables: Fields requested", "partner>besir partner ok Example Tables: Fields received",
                               "besir>partner partner ok Example Tables: Request sent", "partner>besir partner ok Example Tables: Request confirmed"])
    }

    func testBUDGET_G27_APartyOfEightSendsTwentyFourThousandCents() async throws {
        let rig = makeRig()
        let resolution = try await confirmed(try await partnerCard(rig, party: "8"))
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(rig.partner.body()?["amount_cents"] as? Int, 24000)
        XCTAssertEqual(resolution.notice, "Estimated spend $240.00 sent to Example Budget (Simulated): $40.00 over the budget this week.")
        XCTAssertEqual((resolution.json?["budget"] as? [String: Any])?["estimated_spend"] as? String, "$240.00")
    }

    func testBUDGET_G28_EveryFixedTextIsEnglishHoldsNoAdviceWordAndMarksSimulatedAndEstimates() async throws {
        let advice = try NSRegularExpression(pattern: #"\b(should|recommend|advise|afford|save|invest|cut back|stop spending|overspend)\b"#,
                                             options: [.caseInsensitive])
        func hits(_ text: String) -> Int { advice.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) }
        // The scan can fire.
        XCTAssertEqual(hits("You should save and invest. Do not overspend. Stop spending, cut back, afford it, advise, recommend."), 9)
        XCTAssertEqual(hits("Give no advice about savings or the saved amount."), 0)

        var notices: [String] = []
        let cases: [(Int, String, BudgetToolPartner.Mode)] = [(0, BookingFixture.start, .worker), (19000, BookingFixture.start, .worker),
                                                              (0, "2026-11-02T19:00", .worker), (0, BookingFixture.start, .status(500, "oops"))]
        for (hold, start, mode) in cases {
            let rig = makeRig()
            rig.partner.mode = mode
            if hold > 0 { rig.hold(hold) }
            let resolution = try await confirmed(try await partnerCard(rig, start: start))
            notices.append(try XCTUnwrap(resolution.notice))
        }
        XCTAssertEqual(notices.count, 4)
        for notice in notices {
            XCTAssertTrue(notice.contains("Simulated"), notice)
            XCTAssertTrue(notice.lowercased().contains("estimated spend"), notice)
        }

        let live = makeRig()
        let left = try await live.runJSON(live.call("get_budget_left"))
        let spent = try await live.runJSON(live.spend("18.50"))
        live.partner.mode = .status(500, "oops")
        let leftDown = try await live.runJSON(live.call("get_budget_left"))
        let spentDown = try await live.runJSON(live.spend("5"))
        let models = [left, spent, leftDown, spentDown].compactMap { $0["message"] as? String }
        XCTAssertEqual(models.count, 4)
        for message in models { XCTAssertTrue(message.lowercased().contains("simulated"), message) }
        XCTAssertTrue(AgentBudget.leftMessage.contains("estimated spending"))
        XCTAssertTrue(AgentBudget.spendMessage.contains("estimated spending"))
        XCTAssertTrue(AgentBudget.bookingRecordedSentence.contains("estimated spend"))

        var texts = notices + models
        texts += [AgentBudget.leftMessage, AgentBudget.leftUnavailableMessage, AgentBudget.spendMessage, AgentBudget.spendUnavailableMessage,
                  AgentBudget.bookingRecordedSentence, AgentBudget.bookingUnavailableSentence, AgentBudget.bookingFailureNotice,
                  Text.unavailable, Text.amount, Text.wrongType("amount"), Text.notObject]
        for decl in declarations() where ["get_budget_left", "record_spend"].contains(decl["name"] as? String ?? "") {
            texts.append(try XCTUnwrap(decl["description"] as? String))
            let properties = (decl["parameters"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            for spec in properties.values { texts.append(try XCTUnwrap((spec as? [String: Any])?["description"] as? String)) }
        }
        XCTAssertGreaterThanOrEqual(texts.count, 20)
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertEqual(hits(text), 0, text)
            XCTAssertTrue(text.unicodeScalars.allSatisfy(\.isASCII), "English only: \(text)")
        }
    }

    func testBUDGET_G29_TheFieldValuesAndThePartnersReplyNeverReachTheBudgetRequestAPacketOrTheFile() async throws {
        let rig = makeRig()
        let card = try await partnerCard(rig, restaurant: "Sentinel Bistro Zq9", name: "Sentinel Name Zq9")
        let resolution = try await confirmed(card)
        // The sentinels exist where they are allowed to be: in the submit body, and the partner's reply in the result.
        let submit = String(decoding: try XCTUnwrap(rig.tables.requests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(submit.contains("Sentinel Bistro Zq9"))
        XCTAssertTrue(submit.contains("Sentinel Name Zq9"))
        XCTAssertTrue(resolution.result.contains("EX-AB12CD"))
        XCTAssertTrue(resolution.result.contains(BookingFixture.start))
        XCTAssertFalse(try XCTUnwrap(rig.store.activities.first?.title).contains("Zq9"), "the entry title holds no field value")

        let left = try await rig.runJSON(rig.call("get_budget_left"))
        let spent = try await rig.runJSON(rig.spend("18.50"))
        var seen: [String] = []
        for request in rig.partner.requests {
            seen.append(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self))
        }
        XCTAssertEqual(seen.count, 3)
        let packets = await budgetPackets(rig)
        XCTAssertEqual(packets.count, 6)
        seen.append(String(decoding: try JSONEncoder().encode(packets), as: UTF8.self))
        seen.append(String(decoding: try Data(contentsOf: rig.ledgerFile), as: UTF8.self))
        seen.append(AgentToolbox.encode(try XCTUnwrap(resolution.json?["budget"] as? [String: Any])))
        seen.append(try XCTUnwrap(resolution.notice))
        seen.append(AgentToolbox.encode(left))
        seen.append(AgentToolbox.encode(spent))
        for word in ["Sentinel", "Bistro", "Zq9", "EX-AB12CD", "19:00", "2026-10-28"] {
            for text in seen { XCTAssertFalse(text.contains(word), "\(word) in \(text)") }
        }
    }

    func testBUDGET_G30_TheToolNamesAppearInTheLogAsGetBudgetLeftAndRecordSpend() async throws {
        XCTAssertEqual(AgentSession.toolCallSummary("get_budget_left"), "get budget left")
        XCTAssertEqual(AgentSession.toolCallSummary("record_spend"), "record spend")
        let rig = makeRig()
        let fake = FakeTransport([.turn(Turns.turn(Turns.call("get_budget_left", "{}", id: "c1"))),
                                  .turn(Turns.turn(Turns.call("record_spend", PlaceTurns.arguments(["amount": "18.50"]), id: "c2"))),
                                  .turn(Turns.text("Done."))])
        let session = AgentSession(toolbox: rig.tools, transport: fake, connections: rig.log)
        session.send("How much is left? I spent 18.50 on lunch.")
        await session.settle()
        let packets = await rig.packets()
        let calls = packets.filter { $0.kind == .agentToolCall }
        XCTAssertEqual(calls.map(\.summary), ["get budget left", "record spend"])
        XCTAssertEqual(calls.map(\.status), [.ok, .ok])
        let budget = packets.filter { $0.kind == .budget }
        XCTAssertEqual(budget.map(\.summary), ["Budget left asked", "Budget left answered", "Spend sent", "Spend recorded"])
        XCTAssertEqual(Set(budget.map(\.flowID)), [calls[0].flowID])
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 1850)
        XCTAssertEqual(rig.partner.requests.count, 2)
        XCTAssertNil(session.pendingCard, "record_spend asks for no confirmation")
    }

    func testBUDGET_G31_ATaskCancelledWhileTheBudgetRequestIsInFlightLeavesTheBookingApplied() async throws {
        let rig = makeRig()
        rig.partner.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let card = try await partnerCard(rig)
        let resolved = await Task { await card.resolve(.confirm) }.value
        let resolution = try XCTUnwrap(resolved)
        XCTAssertEqual(rig.partner.requests.count, 1, "the budget stub answered a valid spend")
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(card.mark, .confirmed)
        XCTAssertEqual(rig.store.activities.count, 1)
        XCTAssertEqual((resolution.json?["budget"] as? [String: Any])?["status"] as? String, "unavailable")
        XCTAssertNil(resolution.notice, "a cancelled task says nothing about the budget")
        XCTAssertTrue(rig.entries.isEmpty)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: BudgetToolFixture.week), 0)
        let packets = await budgetPackets(rig)
        XCTAssertTrue(packets.isEmpty)
        let lines = await rig.lines()
        XCTAssertEqual(lines, ["besir>partner partner ok Partners requested", "partner>besir partner ok Partners received",
                               "besir>partner partner ok Example Tables: Fields requested", "partner>besir partner ok Example Tables: Fields received",
                               "besir>partner partner ok Example Tables: Request sent", "partner>besir partner ok Example Tables: Request confirmed"])
    }

    func testBUDGET_G32_TheBookingBudgetBlockHoldsSimulatedAndExactlyTheKeysOfEachForm() async throws {
        let within = BudgetStanding(weekStart: "2026-10-26", budgetCents: 20000, spentCents: 6000, leftCents: 14000, isWithin: true,
                                    includesEstimate: true)
        let over = BudgetStanding(weekStart: "2026-10-26", budgetCents: 20000, spentCents: 25000, leftCents: -5000, isWithin: false,
                                  includesEstimate: true)
        let recorded = AgentBudget.BookingSpend.recorded(amountCents: 6000, standing: within, week: "this week").block
        XCTAssertEqual(Set(recorded.keys), ["simulated", "status", "estimated_spend", "week", "includes_estimate", "left"])
        XCTAssertEqual(recorded["simulated"] as? Bool, true)
        XCTAssertEqual(recorded["status"] as? String, "recorded")
        XCTAssertEqual(recorded["includes_estimate"] as? Bool, true)
        let overBlock = AgentBudget.BookingSpend.recorded(amountCents: 6000, standing: over, week: "week of Nov 2").block
        XCTAssertEqual(Set(overBlock.keys), ["simulated", "status", "estimated_spend", "week", "includes_estimate", "over_by"])
        XCTAssertEqual(overBlock["over_by"] as? String, "$50.00")
        XCTAssertEqual(overBlock["week"] as? String, "week of Nov 2")
        let down = AgentBudget.BookingSpend.unavailable(notify: true)
        XCTAssertEqual(Set(down.block.keys), ["simulated", "status"])
        XCTAssertEqual(down.block["simulated"] as? Bool, true)
        XCTAssertEqual(down.block["status"] as? String, "unavailable")
        XCTAssertEqual(down.notice, "The estimated spend could not be sent to Example Budget (Simulated).")
        XCTAssertNil(AgentBudget.BookingSpend.unavailable(notify: false).notice)

        // The same forms in a live result.
        let rig = makeRig()
        let live = try await confirmed(try await partnerCard(rig))
        let block = try XCTUnwrap(live.json?["budget"] as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: block), NSDictionary(dictionary: recorded))
        XCTAssertEqual(AgentBudget.dollars(cents: 123_450), "$1,234.50")
        XCTAssertEqual(AgentBudget.dollars(cents: 5), "$0.05")
    }

    // MARK: G33-G35 the record_spend notice (operator decision 2026-10-29)

    /// The notice lines a session logged, what the chat draws, and whether it showed any card.
    private func spendSession(_ rig: BudgetToolRig, amount: String) async
        -> (notices: [String], chat: [String], cards: Int, pending: Bool) {
        let fake = FakeTransport([.turn(Turns.turn(Turns.call("record_spend", PlaceTurns.arguments(["amount": amount]), id: "c1"))),
                                  .turn(Turns.text("Done."))])
        let session = AgentSession(toolbox: rig.tools, transport: fake, connections: rig.log)
        session.send("I spent \(amount) on lunch.")
        await session.settle()
        let cards = session.entries.filter { if case .card = $0.kind { return true } else { return false } }.count
        return (session.noticeLines, session.chatLines, cards, session.pendingCard != nil)
    }

    func testBUDGET_G33_ARecordedSpendShowsTheFixedLeftNoticeAndNoCard() async throws {
        let rig = makeRig()
        let outcome = rig.spend("18.50")
        XCTAssertNil(outcome.card)
        let output = try await XCTUnwrap(outcome.lookup).run()
        XCTAssertEqual(output.notice, "$18.50 recorded in Example Budget (Simulated): $181.50 left this week.")

        let live = makeRig()
        let shown = await spendSession(live, amount: "18.50")
        XCTAssertEqual(shown.notices, ["$18.50 recorded in Example Budget (Simulated): $181.50 left this week."])
        XCTAssertEqual(shown.chat, ["USER I spent 18.50 on lunch.",
                                    "NOTICE $18.50 recorded in Example Budget (Simulated): $181.50 left this week.", "ASSISTANT Done."])
        XCTAssertEqual(shown.cards, 0)
        XCTAssertFalse(shown.pending, "record_spend asks for no confirmation")
    }

    func testBUDGET_G34_ASpendThatPassesTheBudgetShowsTheOverNotice() async throws {
        let rig = makeRig()
        rig.hold(19000)
        let output = try await XCTUnwrap(rig.spend("18.50").lookup).run()
        XCTAssertEqual(output.notice, "$18.50 recorded in Example Budget (Simulated): $8.50 over the budget this week.")

        let live = makeRig()
        live.hold(20000)
        let shown = await spendSession(live, amount: "5")
        XCTAssertEqual(shown.notices, ["$5.00 recorded in Example Budget (Simulated): $5.00 over the budget this week."])
        XCTAssertEqual(shown.cards, 0)

        let advice = try NSRegularExpression(pattern: #"\b(should|recommend|advise|afford|save|invest|cut back|stop spending|overspend)\b"#,
                                             options: [.caseInsensitive])
        for text in [output.notice ?? "", AgentBudget.spendFailureNotice] {
            XCTAssertEqual(advice.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)), 0, text)
            XCTAssertTrue(text.unicodeScalars.allSatisfy(\.isASCII), text)
        }
    }

    func testBUDGET_G35_AFailedSpendShowsTheFixedFailureNoticeAndACancelledOneSaysNothing() async throws {
        let rig = makeRig()
        rig.partner.mode = .status(500, "oops")
        let output = try await XCTUnwrap(rig.spend("18.50").lookup).run()
        XCTAssertEqual(output.notice, "The spend could not be recorded in Example Budget (Simulated).")

        let live = makeRig()
        live.partner.mode = .error(URLError(.notConnectedToInternet))
        let shown = await spendSession(live, amount: "18.50")
        XCTAssertEqual(shown.notices, ["The spend could not be recorded in Example Budget (Simulated)."])
        XCTAssertEqual(shown.cards, 0)

        let cancelled = makeRig()
        cancelled.partner.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let lookup = try XCTUnwrap(cancelled.spend("18.50").lookup)
        let quiet = await Task { await lookup.run() }.value
        XCTAssertNil(quiet.notice, "a cancelled task says nothing about the budget")

        // The left lookup shows no notice.
        let left = makeRig()
        let leftOutput = try await XCTUnwrap(left.call("get_budget_left").lookup).run()
        XCTAssertNil(leftOutput.notice)
    }
}
