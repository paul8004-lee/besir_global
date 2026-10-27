import XCTest
@testable import besir

/// SPEC-SHARE-001 AC-SHARE-003: the queue holds one file per share, is read back oldest first, and never touches the App Group in tests.
final class ShareInboxTests: XCTestCase {
    private var root: URL!
    private var inbox: SharedInbox!
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("besir-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        inbox = SharedInbox(directory: root.appendingPathComponent("inbox", isDirectory: true),
                            legacyFile: root.appendingPathComponent("pendingShares.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func item(at offset: TimeInterval, text: String? = "caption") -> SharedInbox.Item {
        SharedInbox.Item(id: UUID(), receivedAt: now.addingTimeInterval(offset), text: text, imageBase64: nil, mimeType: nil)
    }

    private func files() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("inbox").path)) ?? []
        return names.sorted()
    }

    func testAC_SHARE_003_twoEnqueuesMakeTwoFilesAndPendingIsOldestFirst() {
        let later = item(at: 5)
        let earlier = item(at: 1)
        XCTAssertTrue(inbox.enqueue(later))
        XCTAssertTrue(inbox.enqueue(earlier))
        XCTAssertEqual(files().count, 2)
        XCTAssertEqual(inbox.pending(now: now.addingTimeInterval(10)).map(\.id), [earlier.id, later.id])
    }

    func testAC_SHARE_003_noTemporaryFileRemainsAfterEnqueue() {
        for offset in 0..<3 { XCTAssertTrue(inbox.enqueue(item(at: TimeInterval(offset)))) }
        let names = files()
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.allSatisfy { $0.hasSuffix(".json") })
    }

    func testAC_SHARE_003_removeDeletesOnlyThatItemAndUnknownIdIsHarmless() {
        let keep = item(at: 1)
        let drop = item(at: 2)
        inbox.enqueue(keep)
        inbox.enqueue(drop)
        inbox.remove(UUID())
        XCTAssertEqual(inbox.pending(now: now.addingTimeInterval(10)).count, 2)
        inbox.remove(drop.id)
        XCTAssertEqual(inbox.pending(now: now.addingTimeInterval(10)).map(\.id), [keep.id])
    }

    func testAC_SHARE_003_undecodableFileIsSkippedAndTheOthersAreReturned() throws {
        let good = item(at: 1)
        inbox.enqueue(good)
        let directory = root.appendingPathComponent("inbox")
        let stamp = String(format: "%013lld", Int64(now.addingTimeInterval(2).timeIntervalSince1970 * 1000))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("\(stamp)-\(UUID().uuidString).json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("junk.json"))
        XCTAssertEqual(inbox.pending(now: now.addingTimeInterval(10)).map(\.id), [good.id])
    }

    func testAC_SHARE_003_itemOlderThanADayIsDeleted() {
        let stale = item(at: -25 * 3600)
        let fresh = item(at: -3600)
        inbox.enqueue(stale)
        inbox.enqueue(fresh)
        XCTAssertEqual(inbox.pending(now: now).map(\.id), [fresh.id])
        XCTAssertEqual(files().count, 1, "the stale file is removed from disk")
    }

    func testAC_SHARE_003_twelveEnqueuesKeepTheNewestTen() {
        let all = (0..<12).map { item(at: TimeInterval($0)) }
        all.forEach { inbox.enqueue($0) }
        XCTAssertEqual(files().count, 10)
        XCTAssertEqual(inbox.pending(now: now.addingTimeInterval(20)).map(\.id), all.suffix(10).map(\.id))
    }

    func testAC_SHARE_003_legacyFileIsDeletedUnread() throws {
        try Data("this is not json at all".utf8).write(to: root.appendingPathComponent("pendingShares.json"))
        XCTAssertTrue(inbox.pending(now: now).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pendingShares.json").path))
    }

    func testAC_SHARE_003_missingDirectoryMakesEnqueueFalseAndPendingEmpty() {
        let none = SharedInbox(directory: nil, legacyFile: nil)
        XCTAssertFalse(none.enqueue(item(at: 0)))
        XCTAssertTrue(none.pending(now: now).isEmpty)
        none.remove(UUID())
    }

    func testAC_SHARE_003_prepareKeepsTheTextWhenTheImageCannotBeShrunk() throws {
        let made = SharedInbox.prepare(text: "  Jazz night  ", imageData: Data([1, 2, 3]), mime: "image/png", shrink: { _ in nil })
        let value = try XCTUnwrap(made)
        XCTAssertEqual(value.text, "Jazz night")
        XCTAssertNil(value.imageBase64)
        XCTAssertNil(value.mimeType)
    }

    func testAC_SHARE_003_prepareReturnsNilWhenNothingIsLeft() {
        XCTAssertNil(SharedInbox.prepare(text: nil, imageData: Data([1, 2, 3]), mime: "image/png", shrink: { _ in nil }))
        XCTAssertNil(SharedInbox.prepare(text: "   \n", imageData: nil, mime: nil, shrink: { _ in nil }))
    }
}
