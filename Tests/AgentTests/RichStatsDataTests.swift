import XCTest
@testable import besir

/// SPEC-RICHSTATS-001 (card t116): the stored data and the wire of the statistics. The ledger's three new fields, what each
/// producer writes into them, that they never leave the device, the directory's kind and the screen model's rebuild of its stats.
/// Every expected text is a literal written here, never made by the code under test. The fixed clock is Tuesday 2026-10-27T09:00
/// in America/Los_Angeles.
@MainActor
final class RichStatsDataTests: XCTestCase {
    // MARK: Helpers

    private let fourKeys: Set<String> = ["requestID", "weekStart", "amountCents", "isEstimate"]

    private func makeRig(partner: BudgetToolPartner = BudgetToolPartner(), tables: StubPartner = StubPartner()) -> BudgetToolRig {
        let rig = BudgetToolRig(partner: partner, tables: tables)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    private func makeFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rich-stats-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// The card of a partner request: the chat line is set as the user's, `get_partners` runs, then `request_partner` is called.
    private func partnerCard(_ rig: BudgetToolRig, start: String = BookingFixture.start) async throws -> AgentCard {
        let fill = PartnerRig.Fill(restaurant: "Pasta Palace", party: 2, start: start, name: "Sam")
        let line = PartnerRig.parts(fill).line
        rig.tools.userLines = { [line] }
        _ = try await rig.runJSON(rig.call("get_partners"))
        return try XCTUnwrap(rig.call("request_partner", PartnerRig.arguments(fill)).card)
    }

    private func confirmed(_ card: AgentCard) async throws -> AgentResolution {
        let resolution = await card.resolve(.confirm)
        return try XCTUnwrap(resolution)
    }

    private func entry(_ id: String, _ week: String, _ cents: Int, estimate: Bool = false) -> BudgetEntry {
        BudgetEntry(requestID: id, weekStart: week, amountCents: cents, isEstimate: estimate)
    }

    private func objects(of file: URL) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
    }

    // MARK: T10 the ledger

    func testRICHSTATS_T10_TheLedgerKeepsOldFilesWritesFourKeysWhenUnsetAndListsEveryEntry() throws {
        let folder = makeFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(BudgetLedger.fileName)
        let oldOne: [String: Any] = ["requestID": "old-1", "weekStart": "2026-10-19", "amountCents": 1850, "isEstimate": false]
        let oldTwo: [String: Any] = ["requestID": "old-2", "weekStart": "2026-10-26", "amountCents": 6000, "isEstimate": true]
        try JSONSerialization.data(withJSONObject: [oldOne, oldTwo]).write(to: file)

        // An old file of two four-key entries loads whole, with the three fields nil.
        let ledger = BudgetLedger(fileURL: file)
        let loaded = ledger.allEntries()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.allSatisfy { $0.partnerName == nil && $0.day == nil && $0.kind == nil })

        // An entry with none of the fields writes four keys, an entry with all three writes seven.
        let plain = entry("new-1", "2026-10-26", 100)
        let full = BudgetEntry(requestID: "new-2", weekStart: "2026-10-26", amountCents: 4200, isEstimate: true,
                               partnerName: "Example Tables", day: "2026-10-28", kind: "Dining")
        XCTAssertTrue(ledger.add(plain))
        XCTAssertTrue(ledger.add(full))
        let written = try objects(of: file)
        XCTAssertEqual(written.count, 4)
        XCTAssertEqual(Set(written[2].keys), fourKeys, "an entry with no new field keeps the four keys")
        XCTAssertEqual(Set(written[3].keys), fourKeys.union(["partnerName", "day", "kind"]))
        XCTAssertEqual(written[3]["partnerName"] as? String, "Example Tables")
        XCTAssertEqual(written[3]["day"] as? String, "2026-10-28")
        XCTAssertEqual(written[3]["kind"] as? String, "Dining")

        // A new ledger on the file lists the same entries, in the same order.
        let expected = [entry("old-1", "2026-10-19", 1850), entry("old-2", "2026-10-26", 6000, estimate: true), plain, full]
        XCTAssertEqual(BudgetLedger(fileURL: file).allEntries(), expected)
        XCTAssertEqual(ledger.allEntries(), expected)

        // A key of the wrong type drops that entry alone.
        let badFile = folder.appendingPathComponent("bad-kind.json")
        var wrongType = oldTwo
        wrongType["kind"] = 5
        try JSONSerialization.data(withJSONObject: [oldOne, wrongType]).write(to: badFile)
        XCTAssertEqual(BudgetLedger(fileURL: badFile).allEntries().map(\.requestID), ["old-1"])

        // Every entry is listed in insertion order, whatever its week.
        let ordered = BudgetLedger(fileURL: folder.appendingPathComponent("order.json"))
        XCTAssertTrue(ordered.add(entry("a", "2026-10-26", 1)))
        XCTAssertTrue(ordered.add(entry("b", "2026-10-19", 2)))
        XCTAssertTrue(ordered.add(entry("c", "2026-11-02", 3)))
        XCTAssertEqual(ordered.allEntries().map(\.requestID), ["a", "b", "c"])
    }

    // MARK: T11 the producers

    func testRICHSTATS_T11_EachProducerStoresItsDayAndAnEstimateStoresItsPartner() async throws {
        // (a) A chat spend called at 23:59 on the Sunday and run after midnight stores the day of the call.
        let chat = makeRig()
        chat.clock.now = TestClock.date("2026-11-01T23:59")
        let outcome = chat.spend("18.50")
        chat.clock.now = TestClock.date("2026-11-02T00:01")
        _ = try await chat.runJSON(outcome)
        let chatEntries = chat.entries
        XCTAssertEqual(chatEntries.count, 1, "(a)")
        XCTAssertEqual(chatEntries.first.map { Set($0.keys) }, fourKeys.union(["day"]), "(a) the four keys and the day, nothing else")
        XCTAssertEqual(chatEntries.first?["day"] as? String, "2026-11-01", "(a)")
        XCTAssertEqual(chatEntries.first?["weekStart"] as? String, "2026-10-26", "(a)")

        // (b) The screen model's record stores the day of now, with no partner name and no kind.
        let screen = makeRig()
        let client = BudgetClient(config: BudgetToolFixture.config, ledger: screen.ledger, send: screen.partner.send, connections: screen.log)
        let clock = screen.clock
        let model = BeRichSirModel(desk: BudgetDesk(client: client), now: { clock.now }, zone: { clock.zone })
        model.amountText = "18.50"
        await model.record()
        let screenEntries = screen.entries
        XCTAssertEqual(screenEntries.count, 1, "(b)")
        XCTAssertEqual(screenEntries.first?["day"] as? String, "2026-10-27", "(b)")
        XCTAssertNil(screenEntries.first?["partnerName"], "(b)")
        XCTAssertNil(screenEntries.first?["kind"], "(b)")

        // (c) A chat booking for the next evening stores the table's day and the partner's name.
        let tomorrow = makeRig()
        let tomorrowResolution = try await confirmed(try await partnerCard(tomorrow))
        XCTAssertEqual(tomorrowResolution.status, "applied", "(c)")
        let tomorrowEntries = tomorrow.entries
        XCTAssertEqual(tomorrowEntries.count, 1, "(c)")
        XCTAssertEqual(tomorrowEntries.first?["day"] as? String, "2026-10-28", "(c)")
        XCTAssertEqual(tomorrowEntries.first?["weekStart"] as? String, "2026-10-26", "(c)")
        XCTAssertEqual(tomorrowEntries.first?["partnerName"] as? String, "Example Tables", "(c)")

        // (d) A booking in the next week stores that week and that day.
        let nextWeek = makeRig()
        let nextResolution = try await confirmed(try await partnerCard(nextWeek, start: "2026-11-02T19:00"))
        XCTAssertEqual(nextResolution.status, "applied", "(d)")
        let nextEntries = nextWeek.entries
        XCTAssertEqual(nextEntries.count, 1, "(d)")
        XCTAssertEqual(nextEntries.first?["day"] as? String, "2026-11-02", "(d)")
        XCTAssertEqual(nextEntries.first?["weekStart"] as? String, "2026-11-02", "(d)")
        XCTAssertEqual(nextEntries.first?["partnerName"] as? String, "Example Tables", "(d)")
    }

    // MARK: T12 nothing leaves the device

    /// Replaces every UUID-form text and every time stamp of a packet with a fixed mark.
    private func masked(_ text: String) -> String {
        let uuid = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        let first = text.replacingOccurrences(of: uuid, with: "<id>", options: .regularExpression)
        return first.replacingOccurrences(of: "\"at\":[-0-9.eE+]+", with: "\"at\":<t>", options: .regularExpression)
    }

    /// The packets of a connections file as objects (the encoder does not fix the order of a packet's keys), with every id and
    /// every time stamp replaced by a fixed mark.
    private func maskedPackets(_ text: String) -> NSArray {
        let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] ?? []
        return NSArray(array: parsed.map { object -> [String: Any] in
            var copy = object
            for key in ["id", "flowID"] where copy[key] != nil { copy[key] = "<id>" }
            if copy["at"] != nil { copy["at"] = "<t>" }
            return copy
        })
    }

    /// One run of the steps: a booking for 2026-10-28T19:00, `get_budget_left`, then `record_spend 18.50`.
    private struct Run {
        let rig: BudgetToolRig
        let listing: String
        let booking: String
        let notice: String
        let left: String
        let spent: String
        let ledgerText: String
        let connectionsText: String
        let budgetPackets: [ConnectionPacket]

        /// Every text the model is given or the user is shown.
        var modelFacing: [String] { [listing, booking, notice, left, spent] }
    }

    private func run(kind: String?) async throws -> Run {
        var shape = StubPartner.Shape.tables(name: "Sentinel Partner Qx7")
        shape.kind = kind
        let stub = StubPartner()
        stub.shapes = [shape]
        let rig = makeRig(tables: stub)
        let fill = PartnerRig.Fill(restaurant: "Pasta Palace", party: 2, start: BookingFixture.start, name: "Sam")
        let line = PartnerRig.parts(fill).line
        rig.tools.userLines = { [line] }
        let listing = try await rig.runJSON(rig.call("get_partners"))
        let card = try XCTUnwrap(rig.call("request_partner", PartnerRig.arguments(fill)).card)
        let resolution = try await confirmed(card)
        let left = try await rig.runJSON(rig.call("get_budget_left"))
        let spent = try await rig.runJSON(rig.spend("18.50"))
        let packets = await rig.packets()
        return Run(rig: rig, listing: AgentToolbox.encode(listing), booking: resolution.result, notice: resolution.notice ?? "",
                   left: AgentToolbox.encode(left), spent: AgentToolbox.encode(spent),
                   ledgerText: String(decoding: try Data(contentsOf: rig.ledgerFile), as: UTF8.self),
                   connectionsText: String(decoding: try Data(contentsOf: rig.folder.appendingPathComponent(ConnectionLog.fileName)),
                                           as: UTF8.self),
                   budgetPackets: packets.filter { $0.kind == .budget })
    }

    func testRICHSTATS_T12_TheNewFieldsAddNothingToTheBudgetBodyTheLogOrTheModel() async throws {
        let withKind = try await run(kind: "Sentinelkind")
        let withoutKind = try await run(kind: nil)

        // Positive control: the sentinels exist where they are allowed to be, in the ledger file.
        XCTAssertTrue(withKind.ledgerText.contains("Sentinel Partner Qx7"), "control: the file holds the partner's name")
        XCTAssertTrue(withKind.ledgerText.contains("Sentinelkind"), "control: the file holds the kind")
        XCTAssertTrue(withKind.ledgerText.contains(#""day":"2026-10-28""#), "control: the file holds the day")

        // (a) Every /budget body has exactly the base key set of its op and holds none of the sentinels or the day.
        let left: Set<String> = ["op", "week_start", "spent_cents"]
        let spend = left.union(["amount_cents", "request_id"])
        let requests = withKind.rig.partner.requests
        XCTAssertEqual(requests.count, 3, "(a) the booking's spend, the left and the stated spend")
        for index in requests.indices {
            let body = try XCTUnwrap(withKind.rig.partner.body(index))
            XCTAssertEqual(Set(body.keys), body["op"] as? String == "left" ? left : spend, "(a) body \(index)")
            let text = String(decoding: requests[index].httpBody ?? Data(), as: UTF8.self)
            for word in ["Sentinel", "Qx7", "Sentinelkind", #""day""#] { XCTAssertFalse(text.contains(word), "(a) \(word) in body \(index)") }
        }

        // (b) No budget packet holds the partner's name.
        let packetsText = String(decoding: try JSONEncoder().encode(withKind.budgetPackets), as: UTF8.self)
        for word in ["Sentinel", "Qx7"] { XCTAssertFalse(packetsText.contains(word), "(b) \(word) in a budget packet") }

        // (c) No connections line, model-facing result or notice holds the kind or the key day.
        for text in [withKind.connectionsText] + withKind.modelFacing {
            for word in ["Sentinelkind", #""day""#] { XCTAssertFalse(text.contains(word), "(c) \(word) in \(text.prefix(80))") }
        }

        // (d) With no kind announced, every model-facing text and every connections line is the same once ids and time stamps are masked.
        XCTAssertEqual(withKind.modelFacing.map(masked), withoutKind.modelFacing.map(masked), "(d) what the model and the user see")
        XCTAssertGreaterThan(maskedPackets(withKind.connectionsText).count, 0, "control: the connections file holds packets")
        XCTAssertEqual(maskedPackets(withKind.connectionsText), maskedPackets(withoutKind.connectionsText), "(d) the connections file")

        // (e) The budget packets are the six fixed words.
        XCTAssertEqual(withKind.budgetPackets.map(\.summary),
                       ["Spend sent", "Spend recorded", "Budget left asked", "Budget left answered", "Spend sent", "Spend recorded"], "(e)")
    }

    // MARK: T13 the reader

    private func directory(_ entries: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["partners": entries])) ?? Data()
    }

    private func wire(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["id": id, "name": "Example \(id)", "title": "Title \(id)", "summary": "Does \(id).", "route": "/\(id)"]
        for (key, value) in extra { object[key] = value }
        return object
    }

    func testRICHSTATS_T13_TheSymbolsReaderKeepsAWellFormedKindDropsABadOneAndRefusesOtherKeys() throws {
        // Seven keys keep the symbol and the kind; six keys with a kind alone keep the kind.
        let seven = PartnerEntry.list(from: directory([wire("booking", ["symbol": "fork.knife", "kind": "Dining"]),
                                                       wire("delivery", ["symbol": "bicycle", "kind": "Delivery"])]), symbols: true)
        XCTAssertEqual(seven?.map(\.kind), ["Dining", "Delivery"])
        XCTAssertEqual(seven?.map(\.symbol), ["fork.knife", "bicycle"])
        XCTAssertEqual(PartnerEntry.list(from: directory([wire("booking", ["kind": "Dining"])]), symbols: true)?.map(\.kind), ["Dining"])
        XCTAssertEqual(PartnerEntry.list(from: directory([wire("booking", ["kind": "Dining"])]), symbols: true)?.map(\.symbol), [nil])

        // A kind that obeys the rule is kept as received.
        for kind in ["A", String(repeating: "a", count: 20), "Fast Food"] {
            XCTAssertEqual(PartnerEntry.list(from: directory([wire("booking", ["kind": kind])]), symbols: true)?.map(\.kind), [kind], kind)
        }

        // A kind that breaks the rule is dropped alone: the entry and its symbol stay, and the other entry keeps its own kind.
        let bad: [(String, Any)] = [("an empty text", ""), ("a leading space", " Dining"), ("a trailing space", "Dining "),
                                    ("a digit", "Din1ng"), ("21 letters", String(repeating: "a", count: 21)),
                                    ("a trailing line feed", "Dining\n"), ("a number", 5), ("a boolean", true)]
        for (note, value) in bad {
            let list = PartnerEntry.list(from: directory([wire("booking", ["symbol": "fork.knife", "kind": "Dining"]),
                                                          wire("delivery", ["symbol": "bicycle", "kind": value])]), symbols: true)
            XCTAssertEqual(list?.map(\.kind), ["Dining", nil], note)
            XCTAssertEqual(list?.map(\.symbol), ["fork.knife", "bicycle"], note)
        }

        // Any other key refuses the whole directory.
        XCTAssertNil(PartnerEntry.list(from: directory([wire("booking", ["symbol": "fork.knife", "kind": "Dining", "hint": "x"])]), symbols: true))
        XCTAssertNil(PartnerEntry.list(from: directory([wire("booking", ["kind": "Dining", "hint": "x"])]), symbols: true))

        // With symbols off, the reader of every older build, a kind key refuses the directory.
        XCTAssertNil(PartnerEntry.list(from: directory([wire("booking", ["kind": "Dining"])])))
        XCTAssertNil(PartnerEntry.list(from: directory([wire("booking", ["kind": "Dining"])]), symbols: false))
        XCTAssertEqual(PartnerEntry.list(from: directory([wire("booking")]))?.map(\.kind), [nil], "five keys, no kind")

        // A kept directory with kinds is read back with them.
        let tables = StubPartner.Shape.tables()
        let form = try JSONSerialization.data(withJSONObject: ["partner": tables.name, "simulated": true, "fields": tables.fields,
                                                               "result_fields": tables.resultFields] as [String: Any], options: [.sortedKeys])
        let kept = directory([tables.entry.merging(["symbol": "fork.knife", "kind": "Dining"]) { _, new in new }])
        let url = makeFolder().appendingPathComponent(PartnerKeep.fileName)
        PartnerKeep(fileURL: url).save(PartnerRaw(directory: kept, forms: ["booking": form]))
        let read = PartnerKeep(fileURL: url).read()
        XCTAssertEqual(read?.map(\.entry.kind), ["Dining"])
        XCTAssertEqual(read?.map(\.entry.symbol), ["fork.knife"])
    }

    // MARK: T15 the screen model's stats

    /// Waits (bounded) until `condition` holds.
    private func wait(_ condition: () -> Bool) async {
        var waited = 0
        while !condition() && waited < 200 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
    }

    func testRICHSTATS_T15_TheScreenModelRebuildsItsStatsOnAppearAndOnEveryLedgerChange() async throws {
        let rig = makeRig()
        let client = BudgetClient(config: BudgetToolFixture.config, ledger: rig.ledger, send: rig.partner.send, connections: rig.log)
        let clock = rig.clock
        rig.hold(1850)
        rig.hold(6000, estimate: true)
        let model = BeRichSirModel(desk: BudgetDesk(client: client), now: { clock.now }, zone: { clock.zone })
        XCTAssertEqual(model.stats.weekTitle, "Week of Oct 26", "right after init, before appear")

        await model.appear()
        XCTAssertEqual(model.stats.recordCount, 2, "appear shows the held entries")
        XCTAssertEqual(model.stats.groups.first?.rows.count, 2)

        // Another path adds an entry; the event hops to the main queue and the stats follow.
        let outside = entry(UUID().uuidString, BudgetToolFixture.week, 4000)
        rig.ledger.add(outside)
        await wait { model.rows.count == 3 && !model.isBusy && model.standing?.spentCents == 11850 }
        XCTAssertEqual(model.stats.recordCount, 3, "an added entry")
        XCTAssertEqual(model.stats.groups.first?.rows.first?.amountText, "$40.00", "the newest row first")
        XCTAssertEqual(model.stats.groups.first?.rows.count, 3)

        // A removal.
        rig.ledger.remove(requestID: outside.requestID)
        await wait { model.rows.count == 2 && !model.isBusy && model.standing?.spentCents == 7850 }
        XCTAssertEqual(model.stats.recordCount, 2, "a removed entry")
        XCTAssertEqual(model.stats.groups.first?.rows.count, 2)

        // The stats add no request: the same three left requests the screen made before this card.
        let ops = (0..<rig.partner.requests.count).map { rig.partner.body($0)?["op"] as? String ?? "" }
        XCTAssertEqual(ops, ["left", "left", "left"])
    }
}
