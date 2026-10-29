import XCTest
@testable import besir

/// SPEC-BUDGET-001 AC-BUDGET-003: the ledger keeps whole cents, the week and the request id, and nothing else; the week
/// rule gives the Monday on or before a date. Every ledger here is built with a temporary file.
@MainActor
final class BudgetClientTests: XCTestCase {
    private struct WriteFailure: Error {}

    // MARK: Helpers

    private func makeFile() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("budget-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("budget.json")
    }

    private func makeLedger(file: URL? = nil, failing: Bool = false) -> (ledger: BudgetLedger, file: URL) {
        let url = file ?? makeFile()
        if failing { return (BudgetLedger(fileURL: url, write: { _, _ in throw WriteFailure() }), url) }
        return (BudgetLedger(fileURL: url), url)
    }

    private func entry(_ id: String = UUID().uuidString, week: String = "2026-10-26", cents: Int = 1000,
                       estimate: Bool = false) -> BudgetEntry {
        BudgetEntry(requestID: id, weekStart: week, amountCents: cents, isEstimate: estimate)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, zone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return try XCTUnwrap(calendar.date(from: parts))
    }

    private func writeFile(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    // MARK: T01-T08 the week and the ledger

    func testBUDGET_T01_TheWeekStartsOnTheMondayOnOrBeforeTheDateInTheGivenZone() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        // 2026-10-26 is a Monday: each weekday gives it, and Sunday belongs to the earlier Monday.
        for day in 26...31 {
            XCTAssertEqual(BudgetWeek.start(of: try date(2026, 10, day, zone: utc), in: utc), "2026-10-26", "October \(day)")
        }
        XCTAssertEqual(BudgetWeek.start(of: try date(2026, 11, 1, 23, 59, zone: utc), in: utc), "2026-10-26")
        XCTAssertEqual(BudgetWeek.start(of: try date(2026, 11, 2, 0, 0, zone: utc), in: utc), "2026-11-02")
        // A month edge and a year edge.
        XCTAssertEqual(BudgetWeek.start(of: try date(2026, 10, 1, zone: utc), in: utc), "2026-09-28")
        XCTAssertEqual(BudgetWeek.start(of: try date(2026, 1, 1, zone: utc), in: utc), "2025-12-29")
        // A daylight-saving week: the clocks go back on Sunday 2026-11-01 and forward on Sunday 2026-03-08.
        XCTAssertEqual(BudgetWeek.start(of: try date(2026, 11, 1, 23, 30, zone: la), in: la), "2026-10-26")
        XCTAssertEqual(BudgetWeek.start(of: try date(2026, 11, 2, 0, 30, zone: la), in: la), "2026-11-02")
        XCTAssertEqual(BudgetWeek.start(of: try date(2026, 3, 8, 23, 30, zone: la), in: la), "2026-03-02")
        XCTAssertEqual(BudgetWeek.start(of: try date(2026, 3, 9, 0, 30, zone: la), in: la), "2026-03-09")
        // The zone decides: one instant, two sides of Monday midnight.
        let instant = Date(timeIntervalSince1970: 1_793_588_400)
        XCTAssertEqual(BudgetWeek.start(of: instant, in: utc), "2026-11-02")
        XCTAssertEqual(BudgetWeek.start(of: instant, in: la), "2026-10-26")
    }

    func testBUDGET_T02_TheLedgerSumsByWeekAndSaysWhetherTheWeekHoldsAnEstimate() {
        let (ledger, _) = makeLedger()
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-10-26"), 0)
        XCTAssertFalse(ledger.hasEstimate(weekStart: "2026-10-26"))
        XCTAssertTrue(ledger.add(entry(week: "2026-10-26", cents: 1850)))
        XCTAssertTrue(ledger.add(entry(week: "2026-10-26", cents: 6000, estimate: true)))
        XCTAssertTrue(ledger.add(entry(week: "2026-11-02", cents: 2500)))
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-10-26"), 7850)
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-11-02"), 2500)
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-11-09"), 0)
        XCTAssertTrue(ledger.hasEstimate(weekStart: "2026-10-26"))
        XCTAssertFalse(ledger.hasEstimate(weekStart: "2026-11-02"))
        XCTAssertFalse(ledger.hasEstimate(weekStart: "2026-11-09"))
    }

    func testBUDGET_T03_AnEntryWithAKnownRequestIdIsIgnored() {
        let (ledger, file) = makeLedger()
        XCTAssertTrue(ledger.add(entry("same-id", cents: 1000)))
        XCTAssertTrue(ledger.contains(requestID: "same-id"))
        XCTAssertFalse(ledger.add(entry("same-id", cents: 9999, estimate: true)))
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-10-26"), 1000)
        XCTAssertFalse(ledger.hasEstimate(weekStart: "2026-10-26"))
        XCTAssertFalse(ledger.contains(requestID: "other-id"))
        XCTAssertEqual(BudgetLedger(fileURL: file).spentCents(weekStart: "2026-10-26"), 1000)
    }

    func testBUDGET_T04_The501stEntryDropsTheOldest() {
        let (ledger, file) = makeLedger()
        XCTAssertTrue(ledger.add(entry("first", week: "2026-01-05", cents: 7)))
        for index in 1...499 {
            XCTAssertTrue(ledger.add(entry("id-\(index)", week: "2026-01-12", cents: 1)))
        }
        // 500 entries: the first is still there.
        XCTAssertTrue(ledger.contains(requestID: "first"))
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-01-05"), 7)
        XCTAssertTrue(ledger.add(entry("id-500", week: "2026-01-12", cents: 1)))
        XCTAssertFalse(ledger.contains(requestID: "first"))
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-01-05"), 0)
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-01-12"), 500)
        let reloaded = BudgetLedger(fileURL: file)
        XCTAssertEqual(reloaded.spentCents(weekStart: "2026-01-12"), 500)
        XCTAssertFalse(reloaded.contains(requestID: "first"))
    }

    func testBUDGET_T05_TheFileRoundTripsAndStoresExactlyTheFourKeys() throws {
        let (ledger, file) = makeLedger()
        ledger.add(entry("id-a", week: "2026-10-26", cents: 1850))
        ledger.add(entry("id-b", week: "2026-10-26", cents: 6000, estimate: true))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(objects.count, 2)
        for object in objects {
            XCTAssertEqual(Set(object.keys), ["requestID", "weekStart", "amountCents", "isEstimate"])
        }
        XCTAssertEqual(objects[0]["requestID"] as? String, "id-a")
        XCTAssertEqual(objects[0]["amountCents"] as? Int, 1850)
        XCTAssertEqual(objects[1]["isEstimate"] as? Bool, true)
        let again = BudgetLedger(fileURL: file)
        XCTAssertEqual(again.spentCents(weekStart: "2026-10-26"), 7850)
        XCTAssertTrue(again.hasEstimate(weekStart: "2026-10-26"))
        XCTAssertTrue(again.contains(requestID: "id-a"))
        XCTAssertTrue(again.contains(requestID: "id-b"))
    }

    func testBUDGET_T06_AMissingEmptyOrUndecodableFileLoadsEmptyAndABadEntryIsDroppedAlone() throws {
        XCTAssertEqual(BudgetLedger(fileURL: makeFile()).spentCents(weekStart: "2026-10-26"), 0)

        let empty = makeFile()
        try writeFile("", to: empty)
        XCTAssertEqual(BudgetLedger(fileURL: empty).spentCents(weekStart: "2026-10-26"), 0)

        for text in ["not json", "{}", "{\"requestID\":\"x\"}", "[1,2,3]"] {
            let broken = makeFile()
            try writeFile(text, to: broken)
            let ledger = BudgetLedger(fileURL: broken)
            XCTAssertEqual(ledger.spentCents(weekStart: "2026-10-26"), 0, text)
            XCTAssertTrue(ledger.add(entry(cents: 100)), "the ledger still works after \(text)")
        }

        let mixed = makeFile()
        try writeFile("""
        [{"requestID":"a","weekStart":"2026-10-26","amountCents":100,"isEstimate":false},
         {"requestID":"b","weekStart":"2026-10-26","isEstimate":false},
         {"requestID":"c","weekStart":"2026-10-26","amountCents":"many","isEstimate":false},
         {"requestID":"d","weekStart":"2026-10-26","amountCents":300,"isEstimate":true}]
        """, to: mixed)
        let ledger = BudgetLedger(fileURL: mixed)
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-10-26"), 400)
        XCTAssertTrue(ledger.contains(requestID: "a"))
        XCTAssertFalse(ledger.contains(requestID: "b"))
        XCTAssertFalse(ledger.contains(requestID: "c"))
        XCTAssertTrue(ledger.contains(requestID: "d"))
        XCTAssertTrue(ledger.hasEstimate(weekStart: "2026-10-26"))
    }

    func testBUDGET_T07_AFailingWriteDoesNotThrowAndTheListStillCounts() {
        let (ledger, file) = makeLedger(failing: true)
        XCTAssertTrue(ledger.add(entry("id-a", cents: 1200)))
        XCTAssertTrue(ledger.add(entry("id-b", cents: 300, estimate: true)))
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-10-26"), 1500)
        XCTAssertTrue(ledger.hasEstimate(weekStart: "2026-10-26"))
        XCTAssertTrue(ledger.contains(requestID: "id-a"))
        XCTAssertFalse(ledger.add(entry("id-a", cents: 5)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testBUDGET_T08_OneHundredConcurrentAddsGiveTheRightSum() {
        let (ledger, file) = makeLedger()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            ledger.add(BudgetEntry(requestID: "id-\(index)", weekStart: "2026-10-26", amountCents: index + 1, isEstimate: false))
        }
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-10-26"), 5050)
        XCTAssertEqual(BudgetLedger(fileURL: file).spentCents(weekStart: "2026-10-26"), 5050)
    }

    // MARK: Client helpers

    private let token = "budget-token-0001"
    private let host = "budget-host.invalid"
    private let flow = UUID()
    private let week = "2026-10-26"
    private let requestID = "3F2B8C1E-5D4A-4E7B-9A60-1C2D3E4F5A6B"
    private var config: AppConfig { AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: token) }
    private var blankConfigs: [AppConfig] {
        [AppConfig(), AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(host)", appToken: ""),
         AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: token)]
    }

    private func makeLog(failing: Bool = false) -> (log: ConnectionLog, file: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("budget-log-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(ConnectionLog.fileName)
        if failing { return (ConnectionLog(fileURL: file, write: { _, _ in throw WriteFailure() }), file) }
        return (ConnectionLog(fileURL: file, secrets: { [self] in [token, host] }), file)
    }

    private func client(_ recorder: BudgetSendRecorder, ledger: BudgetLedger, log: ConnectionLog? = nil,
                        config: AppConfig? = nil) -> BudgetClient {
        BudgetClient(config: config ?? self.config, ledger: ledger, send: recorder.send, connections: log ?? makeLog().log)
    }

    private func askLeft(_ recorder: BudgetSendRecorder, ledger: BudgetLedger, log: ConnectionLog? = nil,
                         config: AppConfig? = nil) async -> Result<BudgetStanding, BudgetFailure> {
        await client(recorder, ledger: ledger, log: log, config: config).left(weekStart: week, flow: flow)
    }

    private func spend(_ recorder: BudgetSendRecorder, ledger: BudgetLedger, amount: Int = 6000, estimate: Bool = true,
                       id: String? = nil, log: ConnectionLog? = nil,
                       config: AppConfig? = nil) async -> Result<BudgetStanding, BudgetFailure> {
        await client(recorder, ledger: ledger, log: log, config: config)
            .spend(amountCents: amount, isEstimate: estimate, weekStart: week, requestID: id ?? requestID, flow: flow)
    }

    /// The partner's answer for a ledger total of `spent` before the request, written as the Worker writes it.
    private func answerText(_ operation: String = "left", spent: Int, amount: Int? = nil,
                            _ mutate: (inout [String: Any]) -> Void = { _ in }) -> String {
        let total = spent + (amount ?? 0)
        var fields: [String: Any] = ["partner": "Example Budget", "simulated": true, "op": operation, "week_start": week,
                                     "spent_cents": total, "budget_cents": 20000, "left_cents": 20000 - total,
                                     "status": 20000 - total >= 0 ? "within" : "over"]
        if let amount { fields["amount_cents"] = amount }
        mutate(&fields)
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func spendText(spent: Int, amount: Int = 6000, _ mutate: (inout [String: Any]) -> Void = { _ in }) -> String {
        answerText("spend", spent: spent, amount: amount, mutate)
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func lines(_ log: ConnectionLog) -> [String] {
        log.packets.map { "\($0.from.rawValue)>\($0.to.rawValue) \($0.kind.rawValue) \($0.status.rawValue) \($0.summary)" }
    }

    private func ledger(holding cents: Int, estimate: Bool = false) -> BudgetLedger {
        let (ledger, _) = makeLedger()
        if cents > 0 { ledger.add(entry("held", week: week, cents: cents, estimate: estimate)) }
        return ledger
    }

    private func assertOther(_ bodies: [String], spent: Int = 5000, file: StaticString = #filePath, line: UInt = #line) async {
        for text in bodies {
            let held = ledger(holding: spent)
            let result = await spend(BudgetSendRecorder(body: text), ledger: held)
            XCTAssertEqual(result, .failure(.other), text, file: file, line: line)
            XCTAssertEqual(held.spentCents(weekStart: week), spent, "the ledger changed for \(text)", file: file, line: line)
            XCTAssertFalse(held.contains(requestID: requestID), text, file: file, line: line)
        }
    }

    // MARK: C01-C04 the request

    func testBUDGET_C01_ALeftRequestIsAPostToBudgetWithTheTokenAndTheLedgerTotal() async throws {
        let recorder = BudgetSendRecorder(body: answerText(spent: 5000))
        _ = await askLeft(recorder, ledger: ledger(holding: 5000))
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/budget")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-besir-token"), token)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let fields = try body(of: sent)
        XCTAssertEqual(Set(fields.keys), ["op", "week_start", "spent_cents"])
        XCTAssertEqual(fields["op"] as? String, "left")
        XCTAssertEqual(fields["week_start"] as? String, week)
        XCTAssertEqual(fields["spent_cents"] as? Int, 5000)
    }

    func testBUDGET_C02_ASpendRequestHasTheFiveKeysCentsAsIntegersAndATwentySecondTimeout() async throws {
        let recorder = BudgetSendRecorder(body: spendText(spent: 5000))
        _ = await spend(recorder, ledger: ledger(holding: 5000))
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/budget")
        XCTAssertEqual(sent.timeoutInterval, 20)
        let fields = try body(of: sent)
        XCTAssertEqual(Set(fields.keys), ["op", "week_start", "spent_cents", "amount_cents", "request_id"])
        XCTAssertEqual(fields["op"] as? String, "spend")
        XCTAssertEqual(fields["week_start"] as? String, week)
        XCTAssertEqual(fields["spent_cents"] as? Int, 5000)
        XCTAssertEqual(fields["amount_cents"] as? Int, 6000)
        XCTAssertEqual(fields["request_id"] as? String, requestID)
        let text = String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self)
        XCTAssertTrue(text.contains("\"amount_cents\":6000"), text)
        XCTAssertTrue(text.contains("\"spent_cents\":5000"), text)
        XCTAssertFalse(text.contains("."), "cents are integers: \(text)")
        let leftRecorder = BudgetSendRecorder(body: answerText(spent: 0))
        _ = await askLeft(leftRecorder, ledger: ledger(holding: 0))
        XCTAssertEqual(leftRecorder.requests.first?.timeoutInterval, 20)
    }

    func testBUDGET_C03_SentinelsOfAPlaceATitleATimeACoordinateAndTheConfigurationNeverReachTheBody() async throws {
        var loud = config
        loud.proxyBaseURL = "https://sentinel-host-777.invalid"
        loud.appToken = "sentinel-token-777"
        loud.kakaoJsKey = "sentinel-kakao-777"
        let recorder = BudgetSendRecorder(body: spendText(spent: 0))
        let held = ledger(holding: 0)
        _ = await spend(recorder, ledger: held, config: loud)
        let data = try XCTUnwrap(recorder.requests.first?.httpBody)
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for word in ["sentinel", "latitude", "longitude", "timezone", "time_zone", "place", "title", "address", "phone", "email",
                     "account", "card", "payment", "name\"", "device", "lunch", "cafe"] {
            XCTAssertFalse(text.contains(word), "the body holds \(word)")
        }
        XCTAssertEqual(Set(try body(of: XCTUnwrap(recorder.requests.first)).keys).count, 5)
        let leftRecorder = BudgetSendRecorder(body: answerText(spent: 0))
        _ = await askLeft(leftRecorder, ledger: held, config: loud)
        XCTAssertEqual(Set(try body(of: XCTUnwrap(leftRecorder.requests.first)).keys).count, 3)
    }

    func testBUDGET_C04_NoProxyGivesNotSetUpWithoutACallAPacketOrALedgerChange() async {
        let (log, _) = makeLog()
        let held = ledger(holding: 5000)
        for blank in blankConfigs {
            let leftRecorder = BudgetSendRecorder(body: answerText(spent: 5000))
            let left = await askLeft(leftRecorder, ledger: held, log: log, config: blank)
            XCTAssertEqual(left, .failure(.notSetUp))
            let spendRecorder = BudgetSendRecorder(body: spendText(spent: 5000))
            let spent = await spend(spendRecorder, ledger: held, log: log, config: blank)
            XCTAssertEqual(spent, .failure(.notSetUp))
            XCTAssertTrue(leftRecorder.requests.isEmpty)
            XCTAssertTrue(spendRecorder.requests.isEmpty)
        }
        XCTAssertFalse(client(BudgetSendRecorder(), ledger: held, config: AppConfig()).isConfigured)
        XCTAssertTrue(client(BudgetSendRecorder(), ledger: held).isConfigured)
        await log.flush()
        XCTAssertTrue(log.packets.isEmpty)
        XCTAssertEqual(held.spentCents(weekStart: week), 5000)
        XCTAssertFalse(held.contains(requestID: requestID))
    }

    // MARK: C05-C15 the answer is checked

    func testBUDGET_C05_AValidLeftAnswerGivesTheStanding() async {
        let result = await askLeft(BudgetSendRecorder(body: answerText(spent: 5000)), ledger: ledger(holding: 5000))
        XCTAssertEqual(result, .success(BudgetStanding(weekStart: week, budgetCents: 20000, spentCents: 5000, leftCents: 15000,
                                                       isWithin: true, includesEstimate: false)))
        let fresh = await askLeft(BudgetSendRecorder(body: answerText(spent: 0)), ledger: ledger(holding: 0))
        XCTAssertEqual(fresh, .success(BudgetStanding(weekStart: week, budgetCents: 20000, spentCents: 0, leftCents: 20000,
                                                      isWithin: true, includesEstimate: false)))
        let exact = await askLeft(BudgetSendRecorder(body: answerText(spent: 20000)), ledger: ledger(holding: 20000))
        XCTAssertEqual(exact, .success(BudgetStanding(weekStart: week, budgetCents: 20000, spentCents: 20000, leftCents: 0,
                                                      isWithin: true, includesEstimate: false)))
    }

    func testBUDGET_C06_AValidSpendAnswerGivesTheStandingAfterAndAddsOneEntryWithTheRightFlag() async {
        let estimateLedger = ledger(holding: 5000)
        let estimate = await spend(BudgetSendRecorder(body: spendText(spent: 5000)), ledger: estimateLedger)
        XCTAssertEqual(estimate, .success(BudgetStanding(weekStart: week, budgetCents: 20000, spentCents: 11000, leftCents: 9000,
                                                         isWithin: true, includesEstimate: true)))
        XCTAssertEqual(estimateLedger.spentCents(weekStart: week), 11000)
        XCTAssertTrue(estimateLedger.contains(requestID: requestID))
        XCTAssertTrue(estimateLedger.hasEstimate(weekStart: week))

        let actualLedger = ledger(holding: 5000)
        let actual = await spend(BudgetSendRecorder(body: spendText(spent: 5000, amount: 1850)), ledger: actualLedger,
                                 amount: 1850, estimate: false)
        XCTAssertEqual(actual, .success(BudgetStanding(weekStart: week, budgetCents: 20000, spentCents: 6850, leftCents: 13150,
                                                       isWithin: true, includesEstimate: false)))
        XCTAssertEqual(actualLedger.spentCents(weekStart: week), 6850)
        XCTAssertFalse(actualLedger.hasEstimate(weekStart: week))
    }

    func testBUDGET_C07_AnOverAnswerIsANormalResultWithAnOkPacket() async {
        let (log, _) = makeLog()
        let held = ledger(holding: 19000)
        let result = await spend(BudgetSendRecorder(body: spendText(spent: 19000, amount: 3000)), ledger: held, amount: 3000,
                                 estimate: false, log: log)
        XCTAssertEqual(result, .success(BudgetStanding(weekStart: week, budgetCents: 20000, spentCents: 22000, leftCents: -2000,
                                                       isWithin: false, includesEstimate: false)))
        XCTAssertEqual(held.spentCents(weekStart: week), 22000)
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>budgetPartner budget ok Spend sent", "budgetPartner>besir budget ok Spend recorded"])
        let over = await askLeft(BudgetSendRecorder(body: answerText(spent: 22000)), ledger: held)
        XCTAssertEqual(over, .success(BudgetStanding(weekStart: week, budgetCents: 20000, spentCents: 22000, leftCents: -2000,
                                                     isWithin: false, includesEstimate: false)))
    }

    func testBUDGET_C08_EveryDeviationOfTheAnswerIsOtherAndLeavesTheLedgerUnchanged() async {
        let sentSpend = BudgetClient.Sent(operation: .spend, weekStart: week, spentCents: 5000, amountCents: 6000)
        let sentLeft = BudgetClient.Sent(operation: .left, weekStart: week, spentCents: 5000, amountCents: nil)
        // Positive controls: the exact answers are accepted by the pure check.
        XCTAssertNotNil(BudgetClient.answer(from: Data(spendText(spent: 5000).utf8), sent: sentSpend))
        XCTAssertNotNil(BudgetClient.answer(from: Data(answerText(spent: 5000).utf8), sent: sentLeft))

        var spendBodies: [String] = []
        spendBodies += [spendText(spent: 5000) { $0["partner"] = "Real Budget" },
                        spendText(spent: 5000) { $0["partner"] = "example budget" },
                        spendText(spent: 5000) { $0["partner"] = "Example Budget " },
                        spendText(spent: 5000) { $0.removeValue(forKey: "partner") },
                        spendText(spent: 5000) { $0["partner"] = 5 }]
        spendBodies += [spendText(spent: 5000) { $0["simulated"] = false },
                        spendText(spent: 5000) { $0.removeValue(forKey: "simulated") },
                        spendText(spent: 5000) { $0["simulated"] = "true" },
                        spendText(spent: 5000) { $0["simulated"] = 1 },
                        spendText(spent: 5000) { $0["simulated"] = NSNull() }]
        spendBodies += [spendText(spent: 5000) { $0["op"] = "left" },
                        spendText(spent: 5000) { $0["op"] = "SPEND" },
                        spendText(spent: 5000) { $0.removeValue(forKey: "op") }]
        spendBodies += [spendText(spent: 5000) { $0["week_start"] = "2026-11-02" },
                        spendText(spent: 5000) { $0["week_start"] = "2026-10-26 " },
                        spendText(spent: 5000) { $0.removeValue(forKey: "week_start") }]
        spendBodies += [spendText(spent: 5000) { $0["amount_cents"] = 6001 },
                        spendText(spent: 5000) { $0["amount_cents"] = "6000" },
                        spendText(spent: 5000) { $0["amount_cents"] = 6000.5 },
                        spendText(spent: 5000) { $0.removeValue(forKey: "amount_cents") }]
        spendBodies += [spendText(spent: 5000) { $0["spent_cents"] = 11001 },
                        spendText(spent: 5000) { $0["spent_cents"] = 5000 },
                        spendText(spent: 5000) { $0["spent_cents"] = "11000" },
                        spendText(spent: 5000) { $0.removeValue(forKey: "spent_cents") }]
        spendBodies += [spendText(spent: 5000) { $0["budget_cents"] = 10000 },
                        spendText(spent: 5000) { $0["budget_cents"] = 20001 },
                        spendText(spent: 5000) { $0.removeValue(forKey: "budget_cents") }]
        spendBodies += [spendText(spent: 5000) { $0["left_cents"] = 9001 },
                        spendText(spent: 5000) { $0["left_cents"] = -9000 },
                        spendText(spent: 5000) { $0.removeValue(forKey: "left_cents") }]
        spendBodies += [spendText(spent: 5000) { $0["status"] = "over" },
                        spendText(spent: 5000) { $0["status"] = "WITHIN" },
                        spendText(spent: 5000) { $0["status"] = true },
                        spendText(spent: 5000) { $0.removeValue(forKey: "status") }]
        spendBodies += [spendText(spent: 5000) { $0["extra"] = 1 },
                        spendText(spent: 5000) { $0["request_id"] = requestID },
                        spendText(spent: 5000) { $0["note"] = NSNull() }]
        spendBodies += ["[]", "null", "\"within\"", "5", "", "not json", "{}"]
        for text in spendBodies {
            XCTAssertNil(BudgetClient.answer(from: Data(text.utf8), sent: sentSpend), text)
        }
        await assertOther(spendBodies)

        // The status must agree with the sign of left_cents when the week is over.
        let sentOver = BudgetClient.Sent(operation: .spend, weekStart: week, spentCents: 19000, amountCents: 3000)
        XCTAssertNotNil(BudgetClient.answer(from: Data(spendText(spent: 19000, amount: 3000).utf8), sent: sentOver))
        XCTAssertNil(BudgetClient.answer(from: Data(spendText(spent: 19000, amount: 3000) { $0["status"] = "within" }.utf8), sent: sentOver))
        // The edge: left 0 is within, and -1 called within is not.
        let sentEdge = BudgetClient.Sent(operation: .spend, weekStart: week, spentCents: 19999, amountCents: 2)
        XCTAssertNil(BudgetClient.answer(from: Data(spendText(spent: 19999, amount: 2) { $0["status"] = "within" }.utf8), sent: sentEdge))

        // A left answer: the same rules, and no amount key.
        let leftBodies = [answerText(spent: 5000) { $0["op"] = "spend" },
                          answerText(spent: 5000) { $0["amount_cents"] = 100 },
                          answerText(spent: 5000) { $0["left_cents"] = 14999 },
                          answerText(spent: 5000) { $0["spent_cents"] = 4999 },
                          answerText(spent: 5000) { $0["simulated"] = false },
                          answerText(spent: 5000) { $0.removeValue(forKey: "status") }]
        for text in leftBodies {
            XCTAssertNil(BudgetClient.answer(from: Data(text.utf8), sent: sentLeft), text)
            let result = await askLeft(BudgetSendRecorder(body: text), ledger: ledger(holding: 5000))
            XCTAssertEqual(result, .failure(.other), text)
        }

        // A status other than 200 is not an answer, whatever the body says.
        for status in [201, 202, 204, 302, 400, 404, 500, 503] {
            let held = ledger(holding: 5000)
            let result = await spend(BudgetSendRecorder(status: status, body: spendText(spent: 5000)), ledger: held)
            XCTAssertEqual(result, .failure(.other), "status \(status)")
            XCTAssertFalse(held.contains(requestID: requestID), "status \(status)")
        }
        let accepted = await spend(BudgetSendRecorder(status: 200, body: spendText(spent: 5000)), ledger: ledger(holding: 5000))
        XCTAssertNotNil(try? accepted.get())
    }

    func testBUDGET_C09_ATokenRejectionIsOnlyTheWorkersOwnBody() async {
        let held = ledger(holding: 0)
        let own = await spend(BudgetSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#), ledger: held)
        XCTAssertEqual(own, .failure(.tokenRejected))
        let ownLeft = await askLeft(BudgetSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#), ledger: held)
        XCTAssertEqual(ownLeft, .failure(.tokenRejected))
        for text in [#"{"error":"nope"}"#, #"{"error":"unauthorized","x":1}"#, #"{"error":"Unauthorized"}"#, "", "unauthorized", "[]"] {
            let other = await spend(BudgetSendRecorder(status: 401, body: text), ledger: held)
            XCTAssertEqual(other, .failure(.other), text)
        }
        XCTAssertFalse(held.contains(requestID: requestID))
    }

    func testBUDGET_C10_A404AndA500AreOtherAnOfflineErrorIsOfflineAndAnotherErrorIsOther() async {
        for status in [404, 500] {
            let result = await askLeft(BudgetSendRecorder(status: status, body: #"{"error":"not_found"}"#), ledger: ledger(holding: 0))
            XCTAssertEqual(result, .failure(.other), "status \(status)")
        }
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            let held = ledger(holding: 0)
            let result = await spend(BudgetSendRecorder(error: URLError(code)), ledger: held)
            XCTAssertEqual(result, .failure(.offline), "\(code)")
            XCTAssertFalse(held.contains(requestID: requestID))
        }
        for error in [URLError(.badServerResponse), URLError(.timedOut), URLError(.cancelled), WriteFailure()] as [Error] {
            let result = await askLeft(BudgetSendRecorder(error: error), ledger: ledger(holding: 0))
            XCTAssertEqual(result, .failure(.other), "\(error)")
        }
    }

    func testBUDGET_C11_AFailureHoldsNoTextOfTheAnswer() async {
        let leak = "LEAK-SENTINEL-99"
        let (log, file) = makeLog()
        let deviating = spendText(spent: 5000) { $0["partner"] = leak; $0["note"] = leak }
        for status in [200, 401, 404, 500] {
            let result = await spend(BudgetSendRecorder(status: status, body: deviating), ledger: ledger(holding: 5000), log: log)
            guard case .failure(let failure) = result else { return XCTFail("status \(status) is not a failure") }
            XCTAssertEqual(String(describing: failure), "other", "a failure is a bare case")
        }
        await log.flush()
        XCTAssertFalse(lines(log).joined().contains(leak))
        XCTAssertFalse(((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains(leak))
    }

    func testBUDGET_C12_ACancelledTaskWritesNothingToTheLedgerAndRecordsNoPacket() async {
        // Cancelled before the call: nothing is sent.
        let (before, _) = makeLog()
        let early = BudgetSendRecorder(body: spendText(spent: 5000))
        let earlyLedger = ledger(holding: 5000)
        let earlyResult = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await spend(early, ledger: earlyLedger, log: before)
        }.value
        XCTAssertEqual(earlyResult, .failure(.other))
        XCTAssertTrue(early.requests.isEmpty)
        await before.flush()
        XCTAssertTrue(before.packets.isEmpty)
        XCTAssertFalse(earlyLedger.contains(requestID: requestID))

        // Cancelled while the request is in flight, with a valid answer coming back.
        let (during, _) = makeLog()
        let inFlight = BudgetSendRecorder(body: spendText(spent: 5000))
        inFlight.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let flightLedger = ledger(holding: 5000)
        let flightResult = await Task { await spend(inFlight, ledger: flightLedger, log: during) }.value
        XCTAssertEqual(flightResult, .failure(.other))
        XCTAssertEqual(inFlight.requests.count, 1)
        await during.flush()
        XCTAssertTrue(during.packets.isEmpty)
        XCTAssertEqual(flightLedger.spentCents(weekStart: week), 5000)
        XCTAssertFalse(flightLedger.contains(requestID: requestID))
    }

    func testBUDGET_C13_ASpendWhoseRequestIdIsAlreadyInTheLedgerSendsNothingAndIsOther() async {
        let (log, _) = makeLog()
        let held = ledger(holding: 5000)
        held.add(entry(requestID, week: week, cents: 100))
        let recorder = BudgetSendRecorder(body: spendText(spent: 5100))
        let result = await spend(recorder, ledger: held, log: log)
        XCTAssertEqual(result, .failure(.other))
        XCTAssertTrue(recorder.requests.isEmpty)
        await log.flush()
        XCTAssertTrue(log.packets.isEmpty)
        XCTAssertEqual(held.spentCents(weekStart: week), 5100)
        // A new id is sent: the check is on the id, not on the amount.
        let fresh = BudgetSendRecorder(body: spendText(spent: 5100))
        let next = await spend(fresh, ledger: held, id: "another-id")
        XCTAssertNotNil(try? next.get())
        XCTAssertEqual(fresh.requests.count, 1)
    }

    func testBUDGET_C14_IncludesEstimateIsTrueAfterAnEstimateEntryAndFalseAfterAnActualOne() async {
        let estimateLedger = ledger(holding: 0)
        let estimate = await spend(BudgetSendRecorder(body: spendText(spent: 0)), ledger: estimateLedger, estimate: true)
        XCTAssertEqual(try? estimate.get().includesEstimate, true)
        let actualLedger = ledger(holding: 0)
        let actual = await spend(BudgetSendRecorder(body: spendText(spent: 0)), ledger: actualLedger, estimate: false)
        XCTAssertEqual(try? actual.get().includesEstimate, false)
        // A later actual spend in a week that already holds an estimate still says so; so does a left question.
        let later = await spend(BudgetSendRecorder(body: spendText(spent: 6000, amount: 1000)), ledger: estimateLedger,
                                amount: 1000, estimate: false, id: "later-id")
        XCTAssertEqual(try? later.get().includesEstimate, true)
        let asked = await askLeft(BudgetSendRecorder(body: answerText(spent: 7000)), ledger: estimateLedger)
        XCTAssertEqual(try? asked.get().includesEstimate, true)
        // An estimate in another week does not count for this one.
        let otherWeek = ledger(holding: 0)
        otherWeek.add(entry("elsewhere", week: "2026-11-02", cents: 6000, estimate: true))
        let clean = await askLeft(BudgetSendRecorder(body: answerText(spent: 0)), ledger: otherWeek)
        XCTAssertEqual(try? clean.get().includesEstimate, false)
    }

    func testBUDGET_C15_TheAnswerCheckAcceptsTwoPointZeroStyleNumbersAndRefusesABooleanWhereANumberBelongs() {
        let sent = BudgetClient.Sent(operation: .spend, weekStart: week, spentCents: 1, amountCents: 1)
        func text(spent: String = "2.0", budget: String = "20000.0", left: String = "19998.0", amount: String = "1.0") -> String {
            #"{"amount_cents":\#(amount),"budget_cents":\#(budget),"left_cents":\#(left),"op":"spend","partner":"Example Budget","simulated":true,"spent_cents":\#(spent),"status":"within","week_start":"2026-10-26"}"#
        }
        XCTAssertNotNil(BudgetClient.answer(from: Data(text().utf8), sent: sent))
        XCTAssertNotNil(BudgetClient.answer(from: Data(text(spent: "2", budget: "20000", left: "19998", amount: "1").utf8), sent: sent))
        for bad in [text(spent: "true"), text(spent: "\"2\""), text(spent: "2.5"), text(spent: "null"),
                    text(budget: "true"), text(budget: "1e4"), text(left: "true"), text(left: "19998.5"),
                    text(amount: "true"), text(amount: "\"1\""), text(amount: "1.5"), text(amount: "null")] {
            XCTAssertNil(BudgetClient.answer(from: Data(bad.utf8), sent: sent), bad)
        }
        // A boolean in the place of a number that would equal true as 1: sent total 1 and amount 0 cannot be told apart.
        let one = BudgetClient.Sent(operation: .left, weekStart: week, spentCents: 1, amountCents: nil)
        let truthy = #"{"budget_cents":20000,"left_cents":19999,"op":"left","partner":"Example Budget","simulated":true,"spent_cents":true,"status":"within","week_start":"2026-10-26"}"#
        XCTAssertNil(BudgetClient.answer(from: Data(truthy.utf8), sent: one))
        let honest = truthy.replacingOccurrences(of: "\"spent_cents\":true", with: "\"spent_cents\":1")
        XCTAssertNotNil(BudgetClient.answer(from: Data(honest.utf8), sent: one))
    }

    // MARK: P01-P07 the packets

    func testBUDGET_P01_ALeftRecordsTwoPacketsInOrderWithOneFlow() async {
        let (log, _) = makeLog()
        _ = await askLeft(BudgetSendRecorder(body: answerText(spent: 5000)), ledger: ledger(holding: 5000), log: log)
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>budgetPartner budget ok Budget left asked",
                                    "budgetPartner>besir budget ok Budget left answered"])
        XCTAssertEqual(log.packets.map(\.flowID), [flow, flow])
        XCTAssertEqual(ConnectionFlows.group(log.packets).map(ConnectionFlows.chainText), ["besir → Example Budget (Simulated) → besir"])
    }

    func testBUDGET_P02_ASpendRecordsSpendSentThenSpendRecorded() async {
        let (log, _) = makeLog()
        _ = await spend(BudgetSendRecorder(body: spendText(spent: 5000)), ledger: ledger(holding: 5000), log: log)
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>budgetPartner budget ok Spend sent", "budgetPartner>besir budget ok Spend recorded"])
        XCTAssertEqual(log.packets.map(\.flowID), [flow, flow])
    }

    func testBUDGET_P03_AFailedRequestRecordsOneRequestFailedPacketAndNothingAfterIt() async {
        let failures: [BudgetSendRecorder] = [BudgetSendRecorder(error: URLError(.notConnectedToInternet)),
                                              BudgetSendRecorder(status: 404, body: "{}"),
                                              BudgetSendRecorder(status: 500, body: "oops"),
                                              BudgetSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#),
                                              BudgetSendRecorder(body: "[]"),
                                              BudgetSendRecorder(body: spendText(spent: 5000) { $0["partner"] = "Real Budget" })]
        for recorder in failures {
            let (log, _) = makeLog()
            _ = await spend(recorder, ledger: ledger(holding: 5000), log: log)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>budgetPartner budget failed Request failed"])
            XCTAssertEqual(log.packets.first?.flowID, flow)
        }
        let (leftLog, _) = makeLog()
        _ = await askLeft(BudgetSendRecorder(status: 500, body: ""), ledger: ledger(holding: 0), log: leftLog)
        await leftLog.flush()
        XCTAssertEqual(lines(leftLog), ["besir>budgetPartner budget failed Request failed"])
    }

    func testBUDGET_P04_NoPacketWhenNoRequestWasSentOrTheTaskWasCancelled() async {
        let (log, _) = makeLog()
        // No proxy.
        for blank in blankConfigs {
            _ = await askLeft(BudgetSendRecorder(body: answerText(spent: 0)), ledger: ledger(holding: 0), log: log, config: blank)
            _ = await spend(BudgetSendRecorder(body: spendText(spent: 0)), ledger: ledger(holding: 0), log: log, config: blank)
        }
        // A request id that is already in the ledger.
        let held = ledger(holding: 0)
        held.add(entry(requestID, week: week, cents: 100))
        let duplicate = BudgetSendRecorder(body: spendText(spent: 100))
        _ = await spend(duplicate, ledger: held, log: log)
        XCTAssertTrue(duplicate.requests.isEmpty)
        // A task cancelled before the call and one cancelled in flight.
        let early = BudgetSendRecorder(body: answerText(spent: 0))
        let earlyLedger = ledger(holding: 0)
        _ = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await askLeft(early, ledger: earlyLedger, log: log)
        }.value
        XCTAssertTrue(early.requests.isEmpty)
        let inFlight = BudgetSendRecorder(body: answerText(spent: 0))
        inFlight.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let flightLedger = ledger(holding: 0)
        _ = await Task { await askLeft(inFlight, ledger: flightLedger, log: log) }.value
        XCTAssertEqual(inFlight.requests.count, 1)
        await log.flush()
        XCTAssertTrue(log.packets.isEmpty)
        // Positive counterpart: an exact answer does record.
        _ = await askLeft(BudgetSendRecorder(body: answerText(spent: 0)), ledger: ledger(holding: 0), log: log)
        await log.flush()
        XCTAssertEqual(log.packets.count, 2)
    }

    func testBUDGET_P05_NoSummaryHoldsADigitADollarSignOrAnyTextOfTheAnswer() async throws {
        let (log, file) = makeLog()
        let sentinel = 777
        let held = ledger(holding: 31337)
        let ask = BudgetSendRecorder(body: answerText(spent: 31337))
        let spent = BudgetSendRecorder(body: spendText(spent: 31337, amount: sentinel))
        _ = await askLeft(ask, ledger: held, log: log)
        _ = await spend(spent, ledger: held, amount: sentinel, log: log)
        _ = await spend(BudgetSendRecorder(status: 500, body: spendText(spent: 31337)), ledger: held, id: "failing-id", log: log)
        // The amount and the total exist in the requests and the answer, so the checks below can fail.
        XCTAssertTrue(String(decoding: try XCTUnwrap(spent.requests.first?.httpBody), as: UTF8.self).contains("777"))
        XCTAssertTrue(spendText(spent: 31337, amount: sentinel).contains("32114"))
        await log.flush()
        XCTAssertEqual(log.packets.count, 5)
        for packet in log.packets {
            XCTAssertNil(packet.summary.rangeOfCharacter(from: .decimalDigits), packet.summary)
            XCTAssertFalse(packet.summary.contains("$"), packet.summary)
            XCTAssertFalse(packet.summary.lowercased().contains("example"), packet.summary)
        }
        let stored = try String(contentsOf: file, encoding: .utf8)
        for secret in [week, requestID, "failing-id", token, host, "Example Budget", "within", "partner"] {
            XCTAssertFalse(stored.contains(secret), "connections.json holds \(secret)")
        }
    }

    func testBUDGET_P06_ALogThatCannotWriteChangesNoResult() async {
        func outcomes(failing: Bool) async -> [String] {
            let (log, _) = makeLog(failing: failing)
            let held = ledger(holding: 5000)
            let asked = await askLeft(BudgetSendRecorder(body: answerText(spent: 5000)), ledger: held, log: log)
            let spent = await spend(BudgetSendRecorder(body: spendText(spent: 5000)), ledger: held, log: log)
            let failed = await spend(BudgetSendRecorder(status: 500, body: ""), ledger: held, id: "failing-id", log: log)
            let again = await spend(BudgetSendRecorder(body: spendText(spent: 11000)), ledger: held, id: "again-id", log: log)
            return ["\(asked)", "\(spent)", "\(failed)", "\(again)", "\(held.spentCents(weekStart: week))",
                    "\(held.contains(requestID: requestID))", "\(held.contains(requestID: "failing-id"))"]
        }
        let healthy = await outcomes(failing: false)
        let broken = await outcomes(failing: true)
        XCTAssertEqual(healthy, broken)
        XCTAssertTrue(healthy[1].contains("success"))
        XCTAssertTrue(healthy[2].contains("failure"))
        XCTAssertEqual(healthy[4], "17000")
    }

    func testBUDGET_P07_TheNewPartyAndKindHaveTheirRawValuesNamesAndDefaultSummaryAndEveryOldCaseIsUnchanged() throws {
        XCTAssertEqual(ConnectionParty.budgetPartner.rawValue, "budgetPartner")
        XCTAssertEqual(ConnectionKind.budget.rawValue, "budget")
        XCTAssertEqual(ConnectionParty.budgetPartner.displayName, "Example Budget (Simulated)")
        XCTAssertEqual(ConnectionParty.budgetPartner.displayName, BudgetClient.partnerName + " (Simulated)")
        XCTAssertEqual(ConnectionKind.budget.displayName, "Budget")
        XCTAssertEqual(ConnectionKind.budget.defaultSummary, "Budget")
        for text in [ConnectionParty.budgetPartner.displayName, ConnectionKind.budget.displayName, ConnectionKind.budget.defaultSummary] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.unicodeScalars.allSatisfy { $0.isASCII })
        }
        // Every earlier case keeps its raw value and names.
        XCTAssertEqual(ConnectionParty.allCases.map(\.rawValue),
                       ["instagram", "shareSheet", "besir", "museSpark", "imageReader", "googlePlaces", "googleRoutes", "appleCalendar",
                        "bookingPartner", "budgetPartner"])
        XCTAssertEqual(ConnectionKind.allCases.map(\.rawValue),
                       ["share", "imageRead", "placeSearch", "route", "agentMessage", "agentToolCall", "calendarSave", "booking", "budget"])
        XCTAssertEqual(ConnectionParty.bookingPartner.displayName, "Example Tables (Simulated)")
        XCTAssertEqual(ConnectionParty.museSpark.displayName, "Muse Spark")
        XCTAssertEqual(ConnectionKind.booking.displayName, "Booking")
        XCTAssertEqual(ConnectionKind.booking.defaultSummary, "Reservation")
        XCTAssertEqual(ConnectionKind.calendarSave.defaultSummary, "Event saved")
        // A budget packet loads from the file, and an unknown case drops that packet alone.
        let file = makeLog().file
        let good = ConnectionPacket(id: UUID(), flowID: flow, at: Date(timeIntervalSince1970: 100), from: .besir, to: .budgetPartner,
                                    kind: .budget, summary: "Spend sent", status: .ok)
        let other = ConnectionPacket(id: UUID(), flowID: nil, at: Date(timeIntervalSince1970: 200), from: .budgetPartner, to: .besir,
                                     kind: .budget, summary: "Spend recorded", status: .ok)
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([good, other])) as? [[String: Any]])
        objects[1]["from"] = "carrierPigeon"
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: objects).write(to: file)
        XCTAssertEqual(ConnectionLog(fileURL: file).packets, [good])
    }
}

/// Hands out a scripted answer and remembers every request, so no test touches the network.
final class BudgetSendRecorder {
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

    var send: BudgetClient.Send {
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
