import XCTest
@testable import besir

/// SPEC-DELIVERY-001 AC-DELIVERY-010: the on-device order record keeps the fields of L17 and nothing else, in one capped JSON
/// file. Every log here is built with a temporary file.
@MainActor
final class DeliveryOrderLogTests: XCTestCase {
    private struct WriteFailure: Error {}

    /// Counts the writes the log makes and keeps the last file text it was handed.
    private final class WriteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(Data, URL)] = []

        var writes: [(Data, URL)] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var write: @Sendable (Data, URL) throws -> Void {
            { [self] data, url in
                lock.lock()
                stored.append((data, url))
                lock.unlock()
                try ConnectionLog.defaultWrite(data, url)
            }
        }
    }

    // MARK: Helpers

    private func makeFile() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-orders-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("delivery-orders.json")
    }

    private func entry(_ order: String = "DL-AB12CD", request: String = UUID().uuidString, meal: String? = "A1B2C3D4-0000-4000-8000-000000000001",
                       total: Int = 4000) -> DeliveryOrderEntry {
        DeliveryOrderEntry(
            orderID: order, requestID: request, placeName: "Test Cafe", arrival: "2026-11-02T19:40",
            items: [DeliveryOrderItem(itemID: "ramen", name: "Ramen", quantity: 2, unitPriceCents: 1400),
                    DeliveryOrderItem(itemID: "gyoza", name: "Gyoza", quantity: 1, unitPriceCents: 700)],
            address: "12 Example Street", cardLabel: "Example Debit \u{2022}\u{2022}4242 (Simulated)",
            estimatedTotalCents: total, createdAt: Date(timeIntervalSince1970: 1_793_000_000), mealActivityID: meal)
    }

    private func writeFile(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func objects(in file: URL) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
    }

    // MARK: L01-L06

    func testL01_OneEntryRoundTripsThroughTheFileWithEveryFieldAndTheInjectedWrite() throws {
        let file = makeFile()
        let recorder = WriteRecorder()
        let log = DeliveryOrderLog(fileURL: file, write: recorder.write)
        let first = entry("DL-AB12CD")
        XCTAssertTrue(log.add(first))
        XCTAssertEqual(log.orders, [first])
        XCTAssertEqual(recorder.writes.count, 1)
        XCTAssertEqual(recorder.writes.first?.1, file)
        XCTAssertEqual(DeliveryOrderLog.fileName, "delivery-orders.json")

        let again = DeliveryOrderLog(fileURL: file)
        XCTAssertEqual(again.orders, [first])
        let loaded = try XCTUnwrap(again.orders.first)
        XCTAssertEqual(loaded.orderID, "DL-AB12CD")
        XCTAssertEqual(loaded.placeName, "Test Cafe")
        XCTAssertEqual(loaded.arrival, "2026-11-02T19:40")
        XCTAssertEqual(loaded.items.map(\.itemID), ["ramen", "gyoza"])
        XCTAssertEqual(loaded.items.map(\.quantity), [2, 1])
        XCTAssertEqual(loaded.items.map(\.unitPriceCents), [1400, 700])
        XCTAssertEqual(loaded.address, "12 Example Street")
        XCTAssertEqual(loaded.cardLabel, "Example Debit \u{2022}\u{2022}4242 (Simulated)")
        XCTAssertEqual(loaded.estimatedTotalCents, 4000)
        XCTAssertEqual(loaded.createdAt, Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(loaded.mealActivityID, "A1B2C3D4-0000-4000-8000-000000000001")

        // An order without a meal entry keeps that as nil.
        let plain = entry("DL-ZZ99ZZ", meal: nil)
        XCTAssertTrue(again.add(plain))
        XCTAssertEqual(DeliveryOrderLog(fileURL: file).orders, [first, plain])
    }

    func testL02_TheCapDropsTheOldestEntriesFirst() throws {
        XCTAssertEqual(DeliveryOrderLog.maxEntries, 200)
        let file = makeFile()
        let log = DeliveryOrderLog(fileURL: file, maxEntries: 3)
        for index in 1...5 {
            XCTAssertTrue(log.add(entry("DL-00000\(index)", request: "request-\(index)")))
        }
        XCTAssertEqual(log.orders.map(\.orderID), ["DL-000003", "DL-000004", "DL-000005"])
        XCTAssertEqual(try objects(in: file).count, 3)
        XCTAssertEqual(DeliveryOrderLog(fileURL: file, maxEntries: 3).orders.map(\.orderID), ["DL-000003", "DL-000004", "DL-000005"])
        // A smaller cap on a later start keeps the newest entries.
        XCTAssertEqual(DeliveryOrderLog(fileURL: file, maxEntries: 2).orders.map(\.orderID), ["DL-000004", "DL-000005"])
        // A dropped order id can be added again: the oldest are forgotten.
        XCTAssertTrue(log.add(entry("DL-000001", request: "request-1")))
        XCTAssertEqual(log.orders.map(\.orderID), ["DL-000004", "DL-000005", "DL-000001"])
    }

    func testL03_AFailingWriteChangesNoResult() {
        let file = makeFile()
        let log = DeliveryOrderLog(fileURL: file, write: { _, _ in throw WriteFailure() })
        let first = entry("DL-AB12CD")
        XCTAssertTrue(log.add(first))
        XCTAssertTrue(log.add(entry("DL-CD34EF")))
        XCTAssertEqual(log.orders.count, 2)
        XCTAssertEqual(log.orders.first, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testL04_ARepeatedOrderIdOrRequestIdIsNotAddedTwice() throws {
        let file = makeFile()
        let log = DeliveryOrderLog(fileURL: file)
        let first = entry("DL-AB12CD", request: "request-a")
        XCTAssertTrue(log.add(first))
        let written = try Data(contentsOf: file)
        XCTAssertFalse(log.add(entry("DL-AB12CD", request: "request-b")), "the order id repeats")
        XCTAssertFalse(log.add(entry("DL-CD34EF", request: "request-a")), "the request id repeats")
        XCTAssertFalse(log.add(first))
        XCTAssertEqual(log.orders, [first])
        XCTAssertEqual(try Data(contentsOf: file), written)
        XCTAssertTrue(log.add(entry("DL-CD34EF", request: "request-b")))
        XCTAssertEqual(log.orders.count, 2)
        // The refusal also holds after a restart: the log loads its own file to refuse a repeat.
        let restarted = DeliveryOrderLog(fileURL: file)
        XCTAssertFalse(restarted.add(entry("DL-AB12CD", request: "request-z")))
        XCTAssertFalse(restarted.add(entry("DL-ZZ00ZZ", request: "request-b")))
        XCTAssertEqual(restarted.orders.count, 2)
    }

    func testL05_AMissingEmptyOrUndecodableFileLoadsEmptyAndABadEntryIsDroppedAlone() throws {
        XCTAssertEqual(DeliveryOrderLog(fileURL: makeFile()).orders, [])

        let empty = makeFile()
        try writeFile("", to: empty)
        XCTAssertEqual(DeliveryOrderLog(fileURL: empty).orders, [])

        for text in ["not json", "{}", "{\"orderID\":\"x\"}", "[1,2,3]"] {
            let broken = makeFile()
            try writeFile(text, to: broken)
            let log = DeliveryOrderLog(fileURL: broken)
            XCTAssertEqual(log.orders, [], text)
            XCTAssertTrue(log.add(entry()), "the log still works after \(text)")
        }

        let good = entry("DL-AB12CD", request: "request-a")
        let better = entry("DL-CD34EF", request: "request-b", meal: nil)
        let source = makeFile()
        let seed = DeliveryOrderLog(fileURL: source)
        seed.add(good)
        seed.add(better)
        var all = try objects(in: source)
        var missing = all[0]
        missing["address"] = nil
        missing["orderID"] = "DL-MISSING"
        var wrongType = all[0]
        wrongType["estimatedTotalCents"] = "many"
        wrongType["orderID"] = "DL-WRONGTY"
        var badItem = all[0]
        badItem["items"] = [["itemID": "ramen"]]
        badItem["orderID"] = "DL-BADITEM"
        all = [all[0], missing, wrongType, badItem, all[1]]
        let mixed = makeFile()
        try writeFile(String(decoding: try JSONSerialization.data(withJSONObject: all), as: UTF8.self), to: mixed)
        XCTAssertEqual(DeliveryOrderLog(fileURL: mixed).orders, [good, better])
    }

    func testL06_TheFileHoldsOnlyTheFieldsOfL17AndMoneyIsWholeCents() throws {
        let file = makeFile()
        let log = DeliveryOrderLog(fileURL: file)
        log.add(entry("DL-AB12CD", request: "request-a"))
        log.add(entry("DL-CD34EF", request: "request-b", meal: nil))
        let written = try objects(in: file)
        XCTAssertEqual(written.count, 2)
        let fields: Set<String> = ["orderID", "requestID", "placeName", "arrival", "items", "address", "cardLabel",
                                   "estimatedTotalCents", "createdAt", "mealActivityID"]
        XCTAssertEqual(Set(written[0].keys), fields)
        XCTAssertEqual(Set(written[1].keys), fields.subtracting(["mealActivityID"]))
        let forbidden = ["lat", "lng", "lon", "coord", "phone", "mail", "number", "account", "user", "person"]
        for object in written {
            let items = try XCTUnwrap(object["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 2)
            for item in items { XCTAssertEqual(Set(item.keys), ["itemID", "name", "quantity", "unitPriceCents"]) }
            let keys = Set(object.keys).union(items.flatMap { $0.keys })
            for key in keys {
                for word in forbidden { XCTAssertFalse(key.lowercased().contains(word), "\(key) holds \(word)") }
            }
            func isWhole(_ value: Any?) -> Bool {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
                return !CFNumberIsFloatType(number)
            }
            XCTAssertTrue(isWhole(object["estimatedTotalCents"]))
            for item in items {
                XCTAssertTrue(isWhole(item["quantity"]))
                XCTAssertTrue(isWhole(item["unitPriceCents"]))
            }
        }
        XCTAssertEqual(written[0]["estimatedTotalCents"] as? Int, 4000)
        XCTAssertNotEqual(DeliveryOrderLog.fileName, BudgetLedger.fileName)
        XCTAssertNotEqual(DeliveryOrderLog.fileName, ConnectionLog.fileName)
    }
}
