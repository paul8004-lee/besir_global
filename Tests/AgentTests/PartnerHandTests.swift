import XCTest
import UIKit
@testable import besir

/// SPEC-FULLHAND-001 (card t101): the pure rules of the hand path that opens a partner's card by hand: what a tapped place seeds, and
/// the partner's own symbol (read from the directory's symbols answer, drawn only when this device has it).
final class PartnerHandTests: XCTestCase {
    private func entry(_ id: String = "booking", symbol: String? = nil) -> PartnerEntry {
        PartnerEntry(id: id, name: "Example Tables", title: "Reserve a table", summary: "Reserves a table.", route: "/\(id)", symbol: symbol)
    }

    private func spec(_ fields: [PartnerField]) -> PartnerSpec {
        PartnerSpec(entry: entry(), fields: fields, results: [PartnerResultSpec(name: "Number", kind: .text)])
    }

    private func field(_ key: String, _ kind: PartnerFieldKind, lookup: Bool = false) -> PartnerField {
        var field = PartnerField(key: key, kind: kind, label: key.capitalized, options: kind.hasOptions ? [PartnerOption(id: "a", label: "A"), PartnerOption(id: "b", label: "B")] : [])
        field.canLookUp = lookup
        return field
    }

    // MARK: R3 the photo strip keeps its height

    func testFULLHAND_R3_TheStripKeepsItsHeightWhileAPhotoIsOnItsWayOrShownAndLetsGoWhenAllFailed() {
        let one = NearbyPhoto(name: "a", author: "A", authorURL: nil)
        let two = NearbyPhoto(name: "b", author: "B", authorURL: nil)
        let height = PlacePhotoStrip.reservedHeight(photos: [one, two], loaded: [], failed: [])
        XCTAssertGreaterThan(height, 140, "room for a photo (140 pt) and its author line")
        XCTAssertEqual(PlacePhotoStrip.reservedHeight(photos: [one, two], loaded: ["a"], failed: []), height, "one shown, one on its way")
        XCTAssertEqual(PlacePhotoStrip.reservedHeight(photos: [one, two], loaded: ["a"], failed: ["b"]), height, "one shown, one failed")
        XCTAssertEqual(PlacePhotoStrip.reservedHeight(photos: [one, two], loaded: [], failed: ["a"]), height, "one failed, one on its way")
        XCTAssertEqual(PlacePhotoStrip.reservedHeight(photos: [one, two], loaded: [], failed: ["a", "b"]), 0, "every photo failed: nothing to keep room for")
        XCTAssertEqual(PlacePhotoStrip.reservedHeight(photos: [], loaded: [], failed: []), 0, "no photos")
    }

    // MARK: T06 the hand seed

    func testFULLHAND_T06_HandSeedsGoOnlyIntoTheFirstFieldWhenItTakesAName() {
        let name = "Pasta Palace"
        XCTAssertEqual(PartnerHand.seeds(for: spec([field("restaurant", .text), field("note", .text)]), placeName: name),
                       ["restaurant": .text(name)], "a text first field; the later text field is never seeded")
        XCTAssertEqual(PartnerHand.seeds(for: spec([field("where", .place)]), placeName: name), ["where": .text(name)])
        XCTAssertEqual(PartnerHand.seeds(for: spec([field("where", .place, lookup: true), field("to", .place, lookup: true)]), placeName: name),
                       ["where": .text(name)], "a partner-resolved place first field; the second place is never seeded")
        for kind in [PartnerFieldKind.number, .time, .pickOne, .onOff, .group] {
            XCTAssertEqual(PartnerHand.seeds(for: spec([field("first", kind), field("later", .text), field("spot", .place)]), placeName: name), [:],
                           "a first field of kind \(kind) takes nothing, and no later field is seeded in its place")
        }
        XCTAssertEqual(PartnerHand.seeds(for: spec([]), placeName: name), [:], "a partner with no field")

        XCTAssertEqual(PartnerHand.seeds(for: spec([field("restaurant", .text)]), placeName: "\u{200B}  Pasta\u{200B} Palace \n"),
                       ["restaurant": .text("Pasta Palace")], "hidden characters removed, trimmed")
        let long = String(repeating: "a", count: 130)
        XCTAssertEqual(PartnerHand.seeds(for: spec([field("restaurant", .text)]), placeName: long),
                       ["restaurant": .text(String(repeating: "a", count: 120))], "cut at 120 characters")
        XCTAssertEqual(PartnerHand.seeds(for: spec([field("restaurant", .text)]), placeName: String(repeating: "a", count: 120)),
                       ["restaurant": .text(String(repeating: "a", count: 120))], "120 characters are kept whole")
        for blank in ["", "   ", "\u{200B}\u{200B}", " \n\t "] {
            XCTAssertEqual(PartnerHand.seeds(for: spec([field("restaurant", .text)]), placeName: blank), [:], "a blank name seeds nothing: \(blank.debugDescription)")
        }
    }

    // MARK: T11 the partner's own symbol

    /// A directory answer of the given entries, as the proxy sends it.
    private func directory(_ entries: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["partners": entries])) ?? Data()
    }

    private func wire(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["id": id, "name": "Example \(id)", "title": "Title \(id)", "summary": "Does \(id).", "route": "/\(id)"]
        for (key, value) in extra { object[key] = value }
        return object
    }

    func testFULLHAND_T11_ThePartnersOwnSymbolIsReadKeptOrFallsBackToCircleAndEverySymbolUsedExists() throws {
        // Reader, flag on.
        let two = directory([wire("booking", ["symbol": "fork.knife"]), wire("delivery", ["symbol": "bicycle"])])
        let read = try XCTUnwrap(PartnerEntry.list(from: two, symbols: true))
        XCTAssertEqual(read.map(\.symbol), ["fork.knife", "bicycle"])
        let plain = try XCTUnwrap(PartnerEntry.list(from: directory([wire("booking")]), symbols: true))
        XCTAssertEqual(plain.map(\.symbol), [nil], "the five keys alone are kept, with no symbol")
        let edges: [(String, Any)] = [
            ("41 characters", String(repeating: "a", count: 41)), ("an upper case letter", "Fork.knife"), ("a leading dot", ".x"),
            ("a trailing line feed", "fork.knife\n"), ("a trailing CRLF", "fork.knife\r\n"),
            ("40 characters and a line feed", String(repeating: "a", count: 40) + "\n"), ("a number", 5), ("null", NSNull()),
            ("an empty text", ""), ("a space", "fork knife"),
        ]
        for (note, value) in edges {
            let list = PartnerEntry.list(from: directory([wire("booking", ["symbol": "fork.knife"]), wire("delivery", ["symbol": value])]), symbols: true)
            XCTAssertEqual(list?.map(\.symbol), ["fork.knife", nil], "\(note): the entry is kept without a symbol, the other keeps its own")
        }
        for (note, value) in [("40 characters", String(repeating: "a", count: 40)), ("a leading digit", "1a.b"), ("one letter", "a")] {
            let list = PartnerEntry.list(from: directory([wire("booking", ["symbol": value])]), symbols: true)
            XCTAssertEqual(list?.map(\.symbol), [value], note)
        }
        XCTAssertNil(PartnerEntry.list(from: directory([wire("booking", ["hint": "fork.knife"])]), symbols: true), "a sixth key that is not symbol")
        XCTAssertNil(PartnerEntry.list(from: directory([wire("booking", ["symbol": "fork.knife", "hint": "x"])]), symbols: true), "a seventh key")
        XCTAssertNil(PartnerEntry.list(from: directory([wire("booking", ["symbol": "fork.knife"]), wire("booking")]), symbols: true), "a repeated id still fails the list")

        // Reader, flag off: the reader an older build has.
        XCTAssertNil(PartnerEntry.list(from: two), "six keys are refused without the flag")
        XCTAssertNil(PartnerEntry.list(from: two, symbols: false))
        XCTAssertEqual(PartnerEntry.list(from: directory([wire("booking")]))?.map(\.symbol), [nil])

        // The fallback.
        XCTAssertEqual(PartnerHand.buttonSymbol(for: entry(symbol: "fork.knife")), "fork.knife")
        XCTAssertEqual(PartnerHand.buttonSymbol(for: entry(symbol: "bicycle")), "bicycle")
        XCTAssertEqual(PartnerHand.buttonSymbol(for: entry(symbol: nil)), "circle")
        XCTAssertNil(UIImage(systemName: "zz.nosuchsymbol"), "control: the name does not exist on this device")
        XCTAssertEqual(PartnerHand.buttonSymbol(for: entry(symbol: "zz.nosuchsymbol")), "circle")

        // Existence: every name the hand screens use, and the Worker's two defaults.
        XCTAssertEqual(PartnerHand.symbols, ["checkmark.circle", "calendar.badge.plus", "xmark.circle", "clock.arrow.circlepath",
                                             "arrow.up.forward.square", "circle"])
        for name in PartnerHand.symbols + ["fork.knife", "bicycle"] {
            XCTAssertNotNil(UIImage(systemName: name), name)
        }
    }

    // MARK: T07 to T10 the cancel and the history

    /// The partner's cancel route as a test sets it: it records every request and answers as told.
    private final class CancelStub {
        enum Reply { case cancelled, declined, status(Int), offline }
        var reply: Reply = .cancelled
        private(set) var requests: [URLRequest] = []

        var send: PartnerClient.Send {
            { [self] request in
                requests.append(request)
                func answer(_ status: Int, _ body: String) -> (Data, URLResponse) {
                    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                }
                switch reply {
                case .cancelled: return answer(200, #"{"status":"cancelled","partner":"Example Tables","simulated":true}"#)
                case .declined: return answer(200, #"{"status":"declined","partner":"Example Tables","simulated":true,"reason":"not_cancellable"}"#)
                case .status(let code): return answer(code, "oops")
                case .offline: throw URLError(.notConnectedToInternet)
                }
            }
        }
    }

    /// A schedule, the records and the ledger on temporary files, and a client over a stub.
    @MainActor
    private final class CancelRig {
        let store = EmptyStore.make()
        let stub = CancelStub()
        let folder: URL
        let records: PartnerRecords
        let ledger: BudgetLedger

        init() {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("partner-cancel-\(UUID().uuidString)", isDirectory: true)
            self.folder = folder
            records = PartnerRecords(fileURL: folder.appendingPathComponent(PartnerRecords.fileName))
            ledger = BudgetLedger(fileURL: folder.appendingPathComponent(BudgetLedger.fileName))
        }

        func client(configured: Bool = true) -> PartnerClient {
            PartnerClient(config: configured ? PlaceSentinel.config : PlaceSentinel.unconfigured, send: stub.send,
                          connections: ConnectionLog(fileURL: folder.appendingPathComponent(ConnectionLog.fileName)))
        }

        func run(_ id: UUID, configured: Bool = true) async -> PartnerCancel.Outcome {
            await PartnerCancel.run(activityID: id, store: store, records: records, ledger: ledger, client: client(configured: configured))
        }

        @discardableResult
        func entry(_ title: String, _ start: String, place: Place? = nil) -> ActivityBlock {
            let from = TestClock.date(start)
            let block = ActivityBlock(title: title, location: place, startDate: from, endDate: from.addingTimeInterval(3600))
            store.activities.append(block)
            return block
        }

        @discardableResult
        func record(_ entry: ActivityBlock, spend: String? = nil, estimate: Int? = 6000, partner: String = "Example Tables") -> PartnerRecord {
            let made = PartnerRecord(activityID: entry.id, partnerID: "partner", partnerName: partner, route: "/partner",
                                     requestID: UUID().uuidString, estimateCents: estimate, quantityHint: nil, spendRequestID: spend,
                                     switchStarted: false)
            records.add(made)
            return made
        }

        func spend(_ requestID: String, cents: Int) {
            ledger.add(BudgetEntry(requestID: requestID, weekStart: "2026-10-26", amountCents: cents, isEstimate: true))
        }

        /// The schedule, the records and the ledger as bytes: two pictures are equal only when nothing was written.
        func snapshot(spends: [String]) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            func file(_ name: String) -> String {
                String(decoding: (try? Data(contentsOf: folder.appendingPathComponent(name))) ?? Data(), as: UTF8.self)
            }
            let entries = spends.map { id in
                ledger.entry(requestID: id).flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "none"
            }
            return [String(decoding: (try? encoder.encode(store.activities)) ?? Data(), as: UTF8.self),
                    String(decoding: (try? encoder.encode(records.records)) ?? Data(), as: UTF8.self),
                    file(PartnerRecords.fileName), file(BudgetLedger.fileName)].joined(separator: "|") + "|" + entries.joined(separator: ",")
        }
    }

    @MainActor
    private func makeCancelRig() -> CancelRig {
        let rig = CancelRig()
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    @MainActor
    func testFULLHAND_T07_ACancelledRequestGivesTheEstimateBackRemovesTheEntryAndItsRecord() async throws {
        let rig = makeCancelRig()
        let first = rig.entry("Dinner A", "2026-10-28T19:00")
        let firstRecord = rig.record(first, spend: "spend-a", estimate: 9000)
        rig.spend("spend-a", cents: 9000)
        rig.spend("spend-other", cents: 1200)
        let bystander = rig.entry("Dinner B", "2026-10-29T19:00")
        let bystanderRecord = rig.record(bystander, spend: "spend-b", estimate: 500)
        rig.spend("spend-b", cents: 500)

        let outcome = await rig.run(first.id)
        XCTAssertEqual(outcome, .cancelled(partner: "Example Tables"))
        XCTAssertEqual(rig.stub.requests.count, 1, "exactly one cancel")
        let request = try XCTUnwrap(rig.stub.requests.first)
        XCTAssertEqual(request.url?.path, "/partner/cancel")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: body).isEqual(to: ["op": "cancel", "request_id": firstRecord.requestID]), "\(body)")
        XCTAssertFalse(rig.ledger.contains(requestID: "spend-a"), "the estimate is given back")
        XCTAssertTrue(rig.ledger.contains(requestID: "spend-other"))
        XCTAssertTrue(rig.ledger.contains(requestID: "spend-b"))
        XCTAssertNil(rig.store.activity(id: first.id), "the entry is gone")
        XCTAssertNotNil(rig.store.activity(id: bystander.id))
        XCTAssertNil(rig.records.record(forActivity: first.id), "the record is gone")
        XCTAssertEqual(rig.records.records, [bystanderRecord])

        // An entry whose record holds no spend id cancels without touching the ledger.
        let plain = rig.entry("Dinner C", "2026-10-30T19:00")
        rig.record(plain, spend: nil)
        let second = await rig.run(plain.id)
        XCTAssertEqual(second, .cancelled(partner: "Example Tables"))
        XCTAssertEqual(rig.stub.requests.count, 2)
        XCTAssertTrue(rig.ledger.contains(requestID: "spend-other"))
        XCTAssertTrue(rig.ledger.contains(requestID: "spend-b"))
        XCTAssertNil(rig.store.activity(id: plain.id))
        XCTAssertNil(rig.records.record(forActivity: plain.id))

        // A record whose entry is already gone is cancelled and removed.
        let lost = rig.entry("Dinner D", "2026-10-31T19:00")
        rig.record(lost, spend: "spend-d")
        rig.spend("spend-d", cents: 700)
        rig.store.activities.removeAll { $0.id == lost.id }
        let third = await rig.run(lost.id)
        XCTAssertEqual(third, .cancelled(partner: "Example Tables"))
        XCTAssertEqual(rig.stub.requests.count, 3)
        XCTAssertFalse(rig.ledger.contains(requestID: "spend-d"))
        XCTAssertNil(rig.records.record(forActivity: lost.id))
        XCTAssertEqual(rig.records.records, [bystanderRecord], "only the other entry's record is left")
    }

    @MainActor
    func testFULLHAND_T08_ADeclinedFailedOrUnrecordedCancelChangesNothing() async throws {
        let replies: [(String, CancelStub.Reply)] = [("declined", .declined), ("a 404", .status(404)), ("a 500", .status(500)),
                                                    ("an offline error", .offline)]
        for (note, reply) in replies {
            let rig = makeCancelRig()
            let entry = rig.entry("Dinner", "2026-10-28T19:00")
            rig.record(entry, spend: "spend-a", estimate: 9000)
            rig.spend("spend-a", cents: 9000)
            rig.stub.reply = reply
            let before = rig.snapshot(spends: ["spend-a"])
            let outcome = await rig.run(entry.id)
            if case .declined = reply {
                XCTAssertEqual(outcome, .declined(partner: "Example Tables"), note)
            } else {
                XCTAssertEqual(outcome, .unavailable(partner: "Example Tables"), note)
            }
            XCTAssertEqual(rig.stub.requests.count, 1, "\(note): one request")
            XCTAssertEqual(rig.snapshot(spends: ["spend-a"]), before, "\(note): the schedule, the records and the ledger are as they were")
            XCTAssertNotNil(rig.store.activity(id: entry.id), note)
            XCTAssertTrue(rig.ledger.contains(requestID: "spend-a"), note)
        }

        // A client with no proxy sends nothing.
        let bare = makeCancelRig()
        let kept = bare.entry("Dinner", "2026-10-28T19:00")
        bare.record(kept, spend: "spend-a")
        bare.spend("spend-a", cents: 6000)
        let bareBefore = bare.snapshot(spends: ["spend-a"])
        let unavailable = await bare.run(kept.id, configured: false)
        XCTAssertEqual(unavailable, .unavailable(partner: "Example Tables"))
        XCTAssertEqual(bare.stub.requests.count, 0)
        XCTAssertEqual(bare.snapshot(spends: ["spend-a"]), bareBefore)

        // An entry without a record, and an id that names nothing: nothing is sent.
        let rig = makeCancelRig()
        let plain = rig.entry("Plain event", "2026-10-28T12:00")
        let before = rig.snapshot(spends: [])
        let none = await rig.run(plain.id)
        XCTAssertEqual(none, .noRecord)
        let unknown = await rig.run(UUID())
        XCTAssertEqual(unknown, .noRecord)
        XCTAssertEqual(rig.stub.requests.count, 0, "no record, no request")
        XCTAssertEqual(rig.snapshot(spends: []), before)
    }

    @MainActor
    func testFULLHAND_T10_TheHistoryJoinsRecordsAndEntriesAndShowsOnlyStoredValues() throws {
        XCTAssertEqual(PartnerHand.estimateText(cents: 9000), "Estimate $90.00")
        XCTAssertEqual(PartnerHand.estimateText(cents: 50), "Estimate $0.50")

        let rig = makeCancelRig()
        let place = Place(name: "Pasta Palace", address: "1 Main Street", latitude: 37.78, longitude: -122.41)
        let later = rig.entry("Later dinner", "2026-10-30T19:00", place: place)
        let earlier = rig.entry("Earlier dinner", "2026-10-28T19:00")
        let gone = rig.entry("Gone dinner", "2026-10-29T19:00")
        rig.entry("Plain event", "2026-10-27T12:00")
        rig.record(later, estimate: 9000, partner: "Example Tables")
        rig.record(earlier, estimate: nil, partner: "Example Delivery")
        rig.record(gone, estimate: 100, partner: "Example Tables")
        rig.store.activities.removeAll { $0.id == gone.id }
        let index = try XCTUnwrap(rig.store.activities.firstIndex { $0.id == earlier.id })
        rig.store.activities[index].title = "Renamed dinner"
        let fileBefore = try Data(contentsOf: rig.folder.appendingPathComponent(PartnerRecords.fileName))
        let recordsBefore = rig.records.records

        let rows = PartnerHistory.rows(records: rig.records, store: rig.store)
        XCTAssertEqual(rows.map(\.id), [earlier.id, later.id], "two rows, earliest start first; the orphan and the unrecorded entry are not listed")
        guard rows.count == 2 else { return }
        XCTAssertEqual(rows[0].title, "Renamed dinner", "the entry's current title")
        XCTAssertEqual(rows[0].start, earlier.startDate)
        XCTAssertEqual(rows[0].end, earlier.endDate)
        XCTAssertNil(rows[0].place)
        XCTAssertNil(rows[0].estimateCents)
        XCTAssertEqual(rows[0].partnerName, "Example Delivery")
        XCTAssertEqual(rows[1].title, "Later dinner")
        XCTAssertEqual(rows[1].start, later.startDate)
        XCTAssertEqual(rows[1].end, later.endDate)
        XCTAssertEqual(rows[1].place, place)
        XCTAssertEqual(rows[1].estimateCents, 9000)
        XCTAssertEqual(rows[1].partnerName, "Example Tables")
        XCTAssertEqual(try Data(contentsOf: rig.folder.appendingPathComponent(PartnerRecords.fileName)), fileBefore, "reading writes nothing")
        XCTAssertEqual(rig.records.records, recordsBefore, "the orphan record is still there")
    }
}
