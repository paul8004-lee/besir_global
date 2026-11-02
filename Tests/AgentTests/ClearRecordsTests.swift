import XCTest
@testable import besir

/// Counts the posts of `BudgetLedger.didChange` that carried one ledger as their object.
private final class ClearPostCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [AnyObject?] = []

    func add(_ object: AnyObject?) {
        lock.lock()
        defer { lock.unlock() }
        objects.append(object)
    }

    func count(for ledger: BudgetLedger) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return objects.filter { $0 === ledger }.count
    }
}

/// SPEC-CLEARRECORDS-001 (card t115): Delete All also empties the budget ledger and the partner records, in memory and on
/// disk, and leaves the connection log as it was.
@MainActor
final class ClearRecordsTests: XCTestCase {
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clear-records-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The number of items in the JSON list a file holds.
    private func itemCount(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any]).count
    }

    private func record(_ activity: UUID) -> PartnerRecord {
        PartnerRecord(activityID: activity, partnerID: "booking", partnerName: "Example Tables", route: "/booking",
                      requestID: UUID().uuidString, estimateCents: nil, quantityHint: nil, spendRequestID: nil, switchStarted: false)
    }

    // MARK: Delete All (REQ-001, REQ-004)

    func testCLEARRECORDS_T01_DeleteAllEmptiesTheLedgerAndTheRecords() throws {
        let store = EmptyStore.make()
        let week = BudgetWeek.start(of: Date(), in: .current)
        let id = UUID().uuidString
        let activity = UUID()
        let budgetURL = AppConfig.supportDirectory.appendingPathComponent(BudgetLedger.fileName)
        let recordsURL = AppConfig.supportDirectory.appendingPathComponent(PartnerRecords.fileName)

        XCTAssertTrue(BudgetLedger.shared.add(BudgetEntry(requestID: id, weekStart: week, amountCents: 1200, isEstimate: false)))
        XCTAssertTrue(PartnerRecords.shared.add(record(activity)))
        XCTAssertTrue(BudgetLedger.shared.contains(requestID: id))
        XCTAssertNotNil(PartnerRecords.shared.record(forActivity: activity))
        XCTAssertGreaterThanOrEqual(try itemCount(budgetURL), 1)
        XCTAssertGreaterThanOrEqual(try itemCount(recordsURL), 1)

        store.deleteEverythingForTesting()

        XCTAssertFalse(BudgetLedger.shared.contains(requestID: id))
        XCTAssertTrue(BudgetLedger.shared.weekEntries(weekStart: week).isEmpty)
        XCTAssertTrue(PartnerRecords.shared.records.isEmpty)
        XCTAssertEqual(try itemCount(budgetURL), 0)
        XCTAssertEqual(try itemCount(recordsURL), 0)
        XCTAssertTrue(BudgetLedger(fileURL: budgetURL).weekEntries(weekStart: week).isEmpty)
        XCTAssertTrue(PartnerRecords(fileURL: recordsURL).records.isEmpty)
    }

    func testCLEARRECORDS_T02_DeleteAllLeavesTheConnectionLog() throws {
        let store = EmptyStore.make()
        let url = AppConfig.supportDirectory.appendingPathComponent(ConnectionLog.fileName)
        try FileManager.default.createDirectory(at: AppConfig.supportDirectory, withIntermediateDirectories: true)
        try Data("t115-sentinel".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let before = try Data(contentsOf: url)
        store.deleteEverythingForTesting()
        let after = try Data(contentsOf: url)

        XCTAssertEqual(after, before)
    }

    // MARK: A failed write (REQ-002, REQ-003)

    func testCLEARRECORDS_T03_LedgerClearEmptiesMemoryWhenTheWriteFails() throws {
        let url = folder().appendingPathComponent(BudgetLedger.fileName)
        let seed = BudgetLedger(fileURL: url)
        XCTAssertTrue(seed.add(BudgetEntry(requestID: "a", weekStart: "2026-10-26", amountCents: 1000, isEstimate: false)))
        XCTAssertTrue(seed.add(BudgetEntry(requestID: "b", weekStart: "2026-11-02", amountCents: 2000, isEstimate: true)))

        let gate = SwitchableWrite()
        let ledger = BudgetLedger(fileURL: url, write: gate.write)
        XCTAssertTrue(ledger.contains(requestID: "a"))
        XCTAssertTrue(ledger.contains(requestID: "b"))

        let counter = ClearPostCounter()
        let token = NotificationCenter.default.addObserver(forName: BudgetLedger.didChange, object: nil, queue: nil) {
            counter.add($0.object as AnyObject?)
        }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }
        XCTAssertEqual(counter.count(for: ledger), 0)

        // First clear: the write fails, the memory is emptied anyway, one post.
        let bytesBefore = try Data(contentsOf: url)
        gate.isFailing = true
        ledger.removeAll()
        XCTAssertFalse(ledger.contains(requestID: "a"))
        XCTAssertFalse(ledger.contains(requestID: "b"))
        XCTAssertTrue(ledger.weekEntries(weekStart: "2026-10-26").isEmpty)
        XCTAssertTrue(ledger.weekEntries(weekStart: "2026-11-02").isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
        XCTAssertEqual(counter.count(for: ledger), 1)

        // Second clear: the list is already empty, the write works, the file is repaired, no post.
        gate.isFailing = false
        ledger.removeAll()
        XCTAssertEqual(try itemCount(url), 0)
        let reread = BudgetLedger(fileURL: url)
        XCTAssertFalse(reread.contains(requestID: "a"))
        XCTAssertFalse(reread.contains(requestID: "b"))
        XCTAssertEqual(counter.count(for: ledger), 1)

        // Third clear: an entry is added and cleared with a working write, one more post.
        XCTAssertTrue(ledger.add(BudgetEntry(requestID: "c", weekStart: "2026-11-02", amountCents: 300, isEstimate: false)))
        let n = counter.count(for: ledger)
        ledger.removeAll()
        XCTAssertFalse(ledger.contains(requestID: "c"))
        XCTAssertEqual(try itemCount(url), 0)
        XCTAssertEqual(counter.count(for: ledger), n + 1)
    }

    func testCLEARRECORDS_T04_RecordsClearEmptiesMemoryWhenTheWriteFails() throws {
        let url = folder().appendingPathComponent(PartnerRecords.fileName)
        let first = UUID()
        let second = UUID()
        let seed = PartnerRecords(fileURL: url)
        XCTAssertTrue(seed.add(record(first)))
        XCTAssertTrue(seed.add(record(second)))

        let gate = SwitchableWrite()
        let records = PartnerRecords(fileURL: url, write: gate.write)
        XCTAssertNotNil(records.record(forActivity: first))
        XCTAssertNotNil(records.record(forActivity: second))

        // First clear: the write fails, the memory is emptied anyway.
        let bytesBefore = try Data(contentsOf: url)
        gate.isFailing = true
        records.removeAll()
        XCTAssertTrue(records.records.isEmpty)
        XCTAssertNil(records.record(forActivity: first))
        XCTAssertNil(records.record(forActivity: second))
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)

        // Second clear: the write works, the file is repaired.
        gate.isFailing = false
        records.removeAll()
        XCTAssertEqual(try itemCount(url), 0)
        XCTAssertTrue(PartnerRecords(fileURL: url).records.isEmpty)
    }
}
