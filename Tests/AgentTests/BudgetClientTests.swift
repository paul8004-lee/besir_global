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
}
