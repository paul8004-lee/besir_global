import XCTest
@testable import besir

/// SPEC-SHAREHOLD-001: while any sheet is open the automatic share pass is held at its check, the item stays queued,
/// and the pass runs again once the last sheet has closed.
@MainActor
final class ShareHoldTests: XCTestCase {
    private struct Rig {
        let inbox: SharedInbox
        let importer: SharedImport
        let reader = FakeVisionReader()
        let handOff = FakeHandOff()
    }

    /// A queue of its own in a temporary folder, as `ShareImportTests.makeRig()` builds one (copied: that helper is private).
    private func makeRig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("besir-hold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedInbox(directory: root.appendingPathComponent("inbox", isDirectory: true),
                                legacyFile: root.appendingPathComponent("pendingShares.json"))
        let importer = SharedImport(inbox: inbox)
#if DEBUG
        importer.logURL = root.appendingPathComponent("import.log")
#endif
        return Rig(inbox: inbox, importer: importer)
    }

    private func enqueue(_ rig: Rig, text: String? = nil, image: String? = nil) {
        let item = SharedInbox.Item(id: UUID(), receivedAt: Date().addingTimeInterval(-5), text: text,
                                    imageBase64: image, mimeType: image == nil ? nil : "image/jpeg")
        XCTAssertTrue(rig.inbox.enqueue(item))
    }

    /// The automatic pass as RootView starts it: the free chat and the closed cover are fixed, the sheet state comes from `hold`.
    private func pass(_ rig: Rig, _ hold: SheetHold) async {
        await rig.importer.pass(vision: rig.reader,
                                canHand: { SnapEntry.shareMayHand(canSend: true, coverOpen: false, sheetOpen: hold.isAnyOpen) },
                                holdForPlan: true, hand: rig.handOff.hand)
    }

    func testSHAREHOLD_T01_ThePassMayRunOnlyWithAFreeChatNoCoverAndNoOpenSheet() {
        for canSend in [false, true] {
            for coverOpen in [false, true] {
                for sheetOpen in [false, true] {
                    let expected = canSend && !coverOpen && !sheetOpen
                    XCTAssertEqual(SnapEntry.shareMayHand(canSend: canSend, coverOpen: coverOpen, sheetOpen: sheetOpen), expected,
                                   "canSend \(canSend), coverOpen \(coverOpen), sheetOpen \(sheetOpen)")
                }
            }
        }
        XCTAssertFalse(SnapEntry.shareMayHand(canSend: true, coverOpen: false, sheetOpen: true))
        // The two-argument form keeps its old four answers.
        XCTAssertTrue(SnapEntry.shareMayHand(canSend: true, coverOpen: false))
        XCTAssertFalse(SnapEntry.shareMayHand(canSend: true, coverOpen: true))
        XCTAssertFalse(SnapEntry.shareMayHand(canSend: false, coverOpen: false))
        XCTAssertFalse(SnapEntry.shareMayHand(canSend: false, coverOpen: true))
    }

    func testSHAREHOLD_T02_TheTrackerTurnsClosedOnlyWhenTheLastSheetCloses() {
        let a = UUID()
        let b = UUID()

        // (a) one sheet opens and closes.
        let one = SheetHold()
        XCTAssertFalse(one.isAnyOpen)
        one.opened(a)
        XCTAssertTrue(one.isAnyOpen)
        XCTAssertTrue(one.closed(a))
        XCTAssertFalse(one.isAnyOpen)

        // (b) a sheet over a sheet: the inner close starts nothing, the outer close does.
        let stacked = SheetHold()
        stacked.opened(a)
        stacked.opened(b)
        XCTAssertFalse(stacked.closed(b))
        XCTAssertTrue(stacked.isAnyOpen)
        XCTAssertTrue(stacked.closed(a))
        XCTAssertFalse(stacked.isAnyOpen)

        // (c) two closes in quick succession, outer first: exactly one answers true.
        let quick = SheetHold()
        quick.opened(a)
        quick.opened(b)
        let first = quick.closed(a)
        let second = quick.closed(b)
        XCTAssertFalse(first)
        XCTAssertTrue(second)
        XCTAssertEqual([first, second].filter { $0 }.count, 1)
        XCTAssertFalse(quick.isAnyOpen)

        // (d) a duplicate appear under one id: only the first close answers true.
        let twice = SheetHold()
        twice.opened(a)
        twice.opened(a)
        XCTAssertTrue(twice.closed(a))
        XCTAssertFalse(twice.closed(a))
        XCTAssertFalse(twice.isAnyOpen)

        // (e) a close of an id never opened, on an empty tracker.
        let empty = SheetHold()
        XCTAssertFalse(empty.closed(a))
        XCTAssertFalse(empty.isAnyOpen)

        // (f) new content before old content closes: the old close starts nothing.
        let replaced = SheetHold()
        replaced.opened(a)
        replaced.opened(b)
        XCTAssertFalse(replaced.closed(a))
        XCTAssertTrue(replaced.isAnyOpen)

        // (g) the chat holds two ids, the chat key and the content's own id (SPEC-SHAREHOLD-001 decision C-t).
        let content = UUID()

        // (g1) a sheet closing over the held chat starts nothing.
        let overChat = SheetHold()
        overChat.opened(SheetHold.chatKey)
        overChat.opened(content)
        overChat.opened(a)
        XCTAssertFalse(overChat.closed(a))
        XCTAssertTrue(overChat.isAnyOpen)

        // (g2) the dismissal is handled first, as measured: only the content's release answers true.
        let dismissalFirst = SheetHold()
        dismissalFirst.opened(SheetHold.chatKey)
        dismissalFirst.opened(content)
        XCTAssertFalse(dismissalFirst.closed(SheetHold.chatKey))
        XCTAssertTrue(dismissalFirst.isAnyOpen)
        XCTAssertTrue(dismissalFirst.closed(content))
        XCTAssertFalse(dismissalFirst.isAnyOpen)

        // (g3) the content goes first: only the key's release answers true.
        let contentFirst = SheetHold()
        contentFirst.opened(SheetHold.chatKey)
        contentFirst.opened(content)
        XCTAssertFalse(contentFirst.closed(content))
        XCTAssertTrue(contentFirst.isAnyOpen)
        XCTAssertTrue(contentFirst.closed(SheetHold.chatKey))
        XCTAssertFalse(contentFirst.isAnyOpen)
    }

    func testSHAREHOLD_T03_AHeldShareStaysQueuedAndFailsOnceAfterTheSheetCloses() async throws {
        let a = UUID()
        let b = UUID()

        // Link: held while the sheet is open, fails once after the close, and never again.
        let hold = SheetHold()
        let link = try makeRig()
        enqueue(link, text: "https://example.com")
        hold.opened(a)
        await pass(link, hold)
        XCTAssertNil(link.importer.alertLine)
        XCTAssertEqual(link.inbox.pending().count, 1)
        XCTAssertTrue(link.handOff.messages.isEmpty)
        XCTAssertEqual(link.reader.calls, 0)
        XCTAssertTrue(hold.closed(a))
        await pass(link, hold)
        XCTAssertEqual(link.importer.alertLine, SharedLine.linkOnly)
        XCTAssertTrue(link.inbox.pending().isEmpty)
        link.importer.alertLine = nil
        await pass(link, hold)
        XCTAssertNil(link.importer.alertLine)
        XCTAssertTrue(link.handOff.messages.isEmpty)

        // Image: no paid read while held; one read and its failure line after the close.
        let image = try makeRig()
        image.reader.result = .failure(.offline)
        enqueue(image, image: Data(count: 1_000).base64EncodedString())
        hold.opened(b)
        await pass(image, hold)
        XCTAssertEqual(image.reader.calls, 0)
        XCTAssertEqual(image.inbox.pending().count, 1)
        XCTAssertNil(image.importer.alertLine)
        hold.closed(b)
        await pass(image, hold)
        XCTAssertEqual(image.reader.calls, 1)
        XCTAssertEqual(image.importer.alertLine, SharedLine.offline)
        XCTAssertTrue(image.inbox.pending().isEmpty)

        // Text, held by the chat (its key and its content id): handed over once, only after the second of the two
        // is released, in either release order. Each order has a queue, a tracker and a hand-off of its own.
        for dismissalFirst in [true, false] {
            let order = dismissalFirst ? "dismissal first" : "content first"
            let content = UUID()
            let chat = SheetHold()
            let text = try makeRig()
            text.handOff.accepts = true
            enqueue(text, text: "zz hold text")
            chat.opened(SheetHold.chatKey)
            chat.opened(content)
            await pass(text, chat)
            XCTAssertTrue(text.handOff.messages.isEmpty, order)
            XCTAssertEqual(text.inbox.pending().count, 1, order)
            XCTAssertNil(text.importer.alertLine, order)

            // The first release leaves the other id in the set: the pass is still held.
            XCTAssertFalse(chat.closed(dismissalFirst ? SheetHold.chatKey : content), order)
            await pass(text, chat)
            XCTAssertTrue(text.handOff.messages.isEmpty, order)
            XCTAssertEqual(text.inbox.pending().count, 1, order)

            // The second release empties the set: exactly one hand-off, and a further pass hands nothing again.
            XCTAssertTrue(chat.closed(dismissalFirst ? content : SheetHold.chatKey), order)
            await pass(text, chat)
            XCTAssertEqual(text.handOff.messages.count, 1, order)
            XCTAssertTrue(text.inbox.pending().isEmpty, order)
            await pass(text, chat)
            XCTAssertEqual(text.handOff.messages.count, 1, order)
        }
    }
}
