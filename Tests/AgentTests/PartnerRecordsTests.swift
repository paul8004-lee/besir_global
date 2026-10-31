import XCTest
@testable import besir

/// A file write a test can make fail and succeed again.
final class SwitchableWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false

    var isFailing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); failing = newValue; lock.unlock() }
    }

    var write: @Sendable (Data, URL) throws -> Void {
        { [self] data, url in
            if isFailing { throw StubPartner.WriteFailure() }
            try ConnectionLog.defaultWrite(data, url)
        }
    }
}

/// SPEC-LATESWITCH-001 AC-003 (REQ-004, REQ-005): the record that links an entry to the partner request that made it, the capped
/// file it lives in, the ledger's two new functions and the record the partner Confirm writes.
@MainActor
final class PartnerRecordsTests: XCTestCase {
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("partner-records-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sample(_ activity: UUID = UUID(), estimate: Int? = 6000, hint: Int? = 2, spend: String? = UUID().uuidString) -> PartnerRecord {
        PartnerRecord(activityID: activity, partnerID: "booking", partnerName: "Example Tables", route: "/booking",
                      requestID: UUID().uuidString, estimateCents: estimate, quantityHint: hint, spendRequestID: spend, switchStarted: false)
    }

    private func fileObjects(_ url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func makeRig(shapes: [StubPartner.Shape] = [.tables()], budget: BudgetToolPartner? = nil) -> TravelRig {
        let rig = TravelRig(shapes: shapes, budget: budget)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    private func confirmed(_ rig: TravelRig, _ fill: PartnerRig.Fill = .init(), prepare: (AgentFieldCard) -> Void = { _ in }) async throws -> AgentResolution {
        let cardValue = await rig.card(fill)
        let card = try XCTUnwrap(cardValue)
        prepare(try XCTUnwrap(card.fieldCard))
        let value = await card.resolve(.confirm)
        return try XCTUnwrap(value)
    }

    /// A table partner that answers a fixed cost whatever the form holds, with the fields `edit` leaves.
    private func tables(cost: Int, edit: (inout StubPartner.Shape) -> Void = { _ in }) -> StubPartner.Shape {
        var shape = StubPartner.Shape.tables()
        edit(&shape)
        shape.answer = { values in
            let results: [[String: Any]] = [["name": "Booking time", "kind": "time", "value": values["start"] ?? ""],
                                            ["name": "Reservation number", "kind": "text", "value": "EX-AB12CD"],
                                            ["name": "Estimated cost", "kind": "money", "value": cost],
                                            ["name": "Partner note", "kind": "text", "value": "Table held for 15 minutes"]]
            return ["status": "confirmed", "partner": "Example Tables", "simulated": true, "results": results]
        }
        return shape
    }

    // MARK: R01-R04 the store

    func testR01_AddReadAndRemove() throws {
        let url = folder().appendingPathComponent(PartnerRecords.fileName)
        let records = PartnerRecords(fileURL: url)
        let id = UUID()
        let record = sample(id)
        XCTAssertNil(records.record(forActivity: id))
        XCTAssertTrue(records.add(record))
        XCTAssertEqual(records.record(forActivity: id), record)
        XCTAssertNil(records.record(forActivity: UUID()))
        XCTAssertEqual(PartnerRecords(fileURL: url).record(forActivity: id), record, "it is on disk")
        XCTAssertTrue(records.remove(activityID: id))
        XCTAssertNil(records.record(forActivity: id))
        XCTAssertFalse(records.remove(activityID: id), "nothing left to remove")
        XCTAssertNil(PartnerRecords(fileURL: url).record(forActivity: id), "the removal is on disk")
        XCTAssertEqual(try fileObjects(url).count, 0)
    }

    func testR02_TheCapDropsTheOldestFirst() throws {
        XCTAssertEqual(PartnerRecords.maxEntries, 50)
        let url = folder().appendingPathComponent(PartnerRecords.fileName)
        let small = PartnerRecords(fileURL: url, maxEntries: 3)
        let ids = (0..<5).map { _ in UUID() }
        for id in ids { XCTAssertTrue(small.add(sample(id))) }
        XCTAssertEqual(small.records.map(\.activityID), Array(ids.suffix(3)))
        XCTAssertNil(small.record(forActivity: ids[0]))
        XCTAssertNotNil(small.record(forActivity: ids[4]))
        XCTAssertEqual(PartnerRecords(fileURL: url, maxEntries: 3).records.map(\.activityID), Array(ids.suffix(3)))

        let full = PartnerRecords(fileURL: folder().appendingPathComponent(PartnerRecords.fileName))
        let many = (0..<51).map { _ in UUID() }
        for id in many { full.add(sample(id)) }
        XCTAssertEqual(full.records.count, 50)
        XCTAssertNil(full.record(forActivity: many[0]))
        XCTAssertNotNil(full.record(forActivity: many[1]))
    }

    func testR03_AMissingAnEmptyAndAnUndecodableFileLoadAsEmpty() throws {
        let root = folder()
        let missing = root.appendingPathComponent("missing.json")
        XCTAssertEqual(PartnerRecords(fileURL: missing).records.count, 0)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let empty = root.appendingPathComponent("empty.json")
        try Data().write(to: empty)
        XCTAssertEqual(PartnerRecords(fileURL: empty).records.count, 0)

        let broken = root.appendingPathComponent("broken.json")
        try Data("this is not json".utf8).write(to: broken)
        let fromBroken = PartnerRecords(fileURL: broken)
        XCTAssertEqual(fromBroken.records.count, 0)
        XCTAssertTrue(fromBroken.add(sample()), "a store that loaded nothing still works")

        let wrongShape = root.appendingPathComponent("object.json")
        try Data(#"{"activityID":"x"}"#.utf8).write(to: wrongShape)
        XCTAssertEqual(PartnerRecords(fileURL: wrongShape).records.count, 0)
    }

    func testR04_OneUndecodableRecordIsDroppedAloneAndADuplicateActivityIsIgnored() throws {
        let root = folder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(PartnerRecords.fileName)
        let first = sample()
        let second = sample()
        let encoder = JSONEncoder()
        let good = try [first, second].map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
        let mixed: [Any] = [good[0], ["activityID": "not-a-uuid", "partnerID": 5], good[1]]
        try JSONSerialization.data(withJSONObject: mixed).write(to: url)
        let records = PartnerRecords(fileURL: url)
        XCTAssertEqual(records.records, [first, second])

        // A second record for the same activity changes nothing.
        let other = PartnerRecord(activityID: first.activityID, partnerID: "other", partnerName: "Other", route: "/other",
                                  requestID: UUID().uuidString, estimateCents: 1, quantityHint: nil, spendRequestID: nil, switchStarted: false)
        XCTAssertFalse(records.add(other))
        XCTAssertEqual(records.records, [first, second])
        XCTAssertEqual(records.record(forActivity: first.activityID)?.partnerID, "booking")
        XCTAssertEqual(try fileObjects(url).count, 3, "a duplicate writes nothing: the file is as it was")
    }

    // MARK: R05-R06 the file, the failures, the ledger

    func testR05_TheStoredJSONHoldsExactlyTheNineKeysAndTheMarkIsOnDiskAtOnce() throws {
        let url = folder().appendingPathComponent(PartnerRecords.fileName)
        let records = PartnerRecords(fileURL: url)
        let nine: Set<String> = ["activityID", "partnerID", "partnerName", "route", "requestID", "estimateCents", "quantityHint",
                                 "spendRequestID", "switchStarted"]
        let full = sample()
        let bare = sample(estimate: nil, hint: nil, spend: nil)
        XCTAssertTrue(records.add(full))
        XCTAssertTrue(records.add(bare))
        let stored = try fileObjects(url)
        XCTAssertEqual(stored.count, 2)
        for object in stored { XCTAssertEqual(Set(object.keys), nine, "a missing value is written as null, never left out") }
        XCTAssertEqual(stored[0]["switchStarted"] as? Bool, false)
        XCTAssertEqual(stored[0]["partnerName"] as? String, "Example Tables")
        XCTAssertEqual(stored[0]["route"] as? String, "/booking")
        XCTAssertEqual(stored[0]["estimateCents"] as? Int, 6000)
        XCTAssertEqual(stored[0]["quantityHint"] as? Int, 2)
        XCTAssertTrue(stored[1]["estimateCents"] is NSNull)

        XCTAssertTrue(records.setSwitchStarted(true, forActivity: full.activityID))
        let onDisk = try fileObjects(url)
        XCTAssertEqual(onDisk[0]["switchStarted"] as? Bool, true, "written before the call returned")
        XCTAssertEqual(onDisk[1]["switchStarted"] as? Bool, false)
        XCTAssertEqual(records.record(forActivity: full.activityID)?.switchStarted, true)
        XCTAssertEqual(PartnerRecords(fileURL: url).record(forActivity: full.activityID)?.switchStarted, true, "it survives a reload")
        XCTAssertFalse(records.setSwitchStarted(true, forActivity: UUID()), "no record, no mark")

        XCTAssertTrue(records.setSwitchStarted(false, forActivity: full.activityID))
        XCTAssertEqual(try fileObjects(url)[0]["switchStarted"] as? Bool, false)
        XCTAssertEqual(PartnerRecords(fileURL: url).record(forActivity: full.activityID)?.switchStarted, false)
    }

    func testR06_AFailedWriteKeepsTheNewListExceptAFailedMarkOfTrue_AndTheLedgerRemovesByRequestID() throws {
        let url = folder().appendingPathComponent(PartnerRecords.fileName)
        let gate = SwitchableWrite()
        let records = PartnerRecords(fileURL: url, write: gate.write)
        let kept = sample()
        XCTAssertTrue(records.add(kept))
        gate.isFailing = true

        // add and remove leave the memory list in its new state, as the ledger's add does.
        let added = sample()
        XCTAssertTrue(records.add(added))
        XCTAssertEqual(records.record(forActivity: added.activityID), added)
        XCTAssertEqual(try fileObjects(url).count, 1, "the file did not take it")
        XCTAssertTrue(records.remove(activityID: added.activityID))
        XCTAssertNil(records.record(forActivity: added.activityID))

        // A mark of true that cannot be written stays false, in memory too.
        XCTAssertFalse(records.setSwitchStarted(true, forActivity: kept.activityID))
        XCTAssertEqual(records.record(forActivity: kept.activityID)?.switchStarted, false)
        gate.isFailing = false
        XCTAssertTrue(records.setSwitchStarted(true, forActivity: kept.activityID))
        XCTAssertEqual(try fileObjects(url)[0]["switchStarted"] as? Bool, true)

        // Clearing that cannot be written: false in memory, the file keeps true until the next good write.
        gate.isFailing = true
        XCTAssertTrue(records.setSwitchStarted(false, forActivity: kept.activityID))
        XCTAssertEqual(records.record(forActivity: kept.activityID)?.switchStarted, false)
        XCTAssertEqual(try fileObjects(url)[0]["switchStarted"] as? Bool, true)
        gate.isFailing = false
        XCTAssertTrue(records.add(sample()))
        XCTAssertEqual(try fileObjects(url).first?["switchStarted"] as? Bool, false, "the next good write catches up")

        // The ledger: look up and remove by request id; the week's sum and estimate flag change and nothing else.
        let ledgerURL = folder().appendingPathComponent(BudgetLedger.fileName)
        let ledgerGate = SwitchableWrite()
        let ledger = BudgetLedger(fileURL: ledgerURL, write: ledgerGate.write)
        let estimate = BudgetEntry(requestID: UUID().uuidString, weekStart: "2026-10-26", amountCents: 3000, isEstimate: true)
        let stated = BudgetEntry(requestID: UUID().uuidString, weekStart: "2026-10-26", amountCents: 2000, isEstimate: false)
        let later = BudgetEntry(requestID: UUID().uuidString, weekStart: "2026-11-02", amountCents: 1000, isEstimate: true)
        for entry in [estimate, stated, later] { ledger.add(entry) }
        XCTAssertEqual(ledger.entry(requestID: estimate.requestID), estimate)
        XCTAssertNil(ledger.entry(requestID: UUID().uuidString))
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-10-26"), 5000)
        XCTAssertTrue(ledger.hasEstimate(weekStart: "2026-10-26"))

        XCTAssertFalse(ledger.remove(requestID: UUID().uuidString), "an unknown id removes nothing")
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-10-26"), 5000)
        XCTAssertTrue(ledger.remove(requestID: estimate.requestID))
        XCTAssertNil(ledger.entry(requestID: estimate.requestID))
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-10-26"), 2000)
        XCTAssertFalse(ledger.hasEstimate(weekStart: "2026-10-26"), "the estimate flag follows the removed entry")
        XCTAssertEqual(ledger.entry(requestID: stated.requestID), stated, "the other entry is untouched")
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-11-02"), 1000)
        XCTAssertTrue(ledger.hasEstimate(weekStart: "2026-11-02"))
        XCTAssertFalse(ledger.remove(requestID: estimate.requestID), "removed once")
        let reloaded = BudgetLedger(fileURL: ledgerURL)
        XCTAssertNil(reloaded.entry(requestID: estimate.requestID), "the file was written as add writes it")
        XCTAssertEqual(reloaded.spentCents(weekStart: "2026-10-26"), 2000)

        // A failed write keeps the new list in memory and the old one on disk.
        ledgerGate.isFailing = true
        XCTAssertTrue(ledger.remove(requestID: later.requestID))
        XCTAssertNil(ledger.entry(requestID: later.requestID))
        XCTAssertEqual(ledger.spentCents(weekStart: "2026-11-02"), 0)
        XCTAssertNotNil(BudgetLedger(fileURL: ledgerURL).entry(requestID: later.requestID))
    }

    // MARK: R07-R08 the record the partner Confirm writes

    func testR07_AConfirmedRequestThatWroteAnEntryAddsOneRecordAfterTheSpend() async throws {
        let budget = BudgetToolPartner()
        let rig = makeRig(budget: budget)
        var seenDuringSpend: Int?
        budget.duringSend = { [records = rig.records] in seenDuringSpend = records.records.count }
        let resolution = try await confirmed(rig)
        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(seenDuringSpend, 0, "the record is written after the spend, not before")

        let entry = try XCTUnwrap(rig.store.activities.first)
        XCTAssertEqual(rig.records.records.count, 1)
        let record = try XCTUnwrap(rig.records.record(forActivity: entry.id))
        XCTAssertEqual(record.partnerID, "booking")
        XCTAssertEqual(record.partnerName, "Example Tables")
        XCTAssertEqual(record.route, "/booking")
        XCTAssertEqual(record.requestID, rig.partner.bodies(op: "submit").first?["request_id"] as? String)
        XCTAssertEqual(record.estimateCents, 6000)
        XCTAssertEqual(record.quantityHint, 2, "party_size is the form's one number field")
        XCTAssertFalse(record.switchStarted)
        let spendID = try XCTUnwrap(record.spendRequestID)
        XCTAssertEqual(spendID, budget.body(0)?["request_id"] as? String, "the id the spend carried")
        let ledgerEntry = try XCTUnwrap(rig.ledger.entry(requestID: spendID))
        XCTAssertEqual(ledgerEntry.amountCents, 6000)
        XCTAssertTrue(ledgerEntry.isEstimate)
        XCTAssertNotEqual(spendID, record.requestID)

        // No proxy for the budget: the spend is not made, so the id is not kept.
        let unspent = makeRig()
        _ = try await confirmed(unspent)
        let unspentEntry = try XCTUnwrap(unspent.store.activities.first)
        XCTAssertNil(unspent.records.record(forActivity: unspentEntry.id)?.spendRequestID)
        XCTAssertEqual(unspent.records.record(forActivity: unspentEntry.id)?.estimateCents, 6000)

        // A failed spend: the id is not kept either.
        let failing = BudgetToolPartner()
        failing.mode = .status(500, "{}")
        let failed = makeRig(budget: failing)
        let failedResolution = try await confirmed(failed)
        XCTAssertEqual(failedResolution.status, "applied")
        XCTAssertEqual(failing.requests.count, 1, "premise: the spend was tried")
        let failedEntry = try XCTUnwrap(failed.store.activities.first)
        XCTAssertNil(failed.records.record(forActivity: failedEntry.id)?.spendRequestID)
        XCTAssertNotNil(failed.records.record(forActivity: failedEntry.id))

        // The hint is the value of the one number field; none or two number fields give none.
        let none = makeRig(shapes: [tables(cost: 4500) { $0.fields.removeAll { $0["key"] as? String == "party_size" } }])
        _ = try await confirmed(none, .init(party: nil))
        let noneEntry = try XCTUnwrap(none.store.activities.first)
        XCTAssertNil(none.records.record(forActivity: noneEntry.id)?.quantityHint)
        XCTAssertEqual(none.records.record(forActivity: noneEntry.id)?.estimateCents, 4500)

        let two = makeRig(shapes: [tables(cost: 4500) { $0.fields.append(StubPartner.field("seats", "number", "Seats")) }])
        _ = try await confirmed(two) { XCTAssertTrue($0.setText("seats", "3")) }
        let twoEntry = try XCTUnwrap(two.store.activities.first)
        XCTAssertNotNil(two.records.record(forActivity: twoEntry.id), "premise: the request went through")
        XCTAssertNil(two.records.record(forActivity: twoEntry.id)?.quantityHint)
    }

    func testR08_NothingElseAddsARecordAndTheAppliedResultIsTheBases() async throws {
        // The applied result and notice are the base's strings.
        let base = makeRig()
        let applied = try await confirmed(base)
        XCTAssertEqual(applied.status, "applied")
        XCTAssertNil(applied.notice)
        XCTAssertEqual(applied.json?["message"] as? String, AgentPartner.appliedMessage)
        XCTAssertEqual(Set(try XCTUnwrap(applied.json).keys), ["status", "partner", "simulated", "results", "message", "id", "title", "start", "end"])
        XCTAssertEqual(base.records.records.count, 1)

        // Declined (a party above 8).
        let declined = makeRig()
        let declinedResolution = try await confirmed(declined, .init(party: 9))
        XCTAssertEqual(declinedResolution.status, "declined")
        XCTAssertTrue(declined.records.records.isEmpty)

        // A failed request, and a cancelled task.
        let failed = makeRig()
        let failedCardValue = await failed.card()
        let failedCard = try XCTUnwrap(failedCardValue)
        failed.partner.mode = .status(500, "oops")
        let failedResolution = await failedCard.resolve(.confirm)
        XCTAssertEqual(failedResolution?.status, "unavailable")
        XCTAssertTrue(failed.records.records.isEmpty)

        let cancelled = makeRig()
        let cancelledCardValue = await cancelled.card()
        let cancelledCard = try XCTUnwrap(cancelledCardValue)
        cancelled.partner.mode = .cancel
        let cancelledResolution = await Task { await cancelledCard.resolve(.confirm) }.value
        XCTAssertEqual(cancelledResolution?.status, "unavailable")
        XCTAssertTrue(cancelled.records.records.isEmpty)

        // A refused card (a required value is empty).
        let refused = makeRig()
        let refusedResolution = try await confirmed(refused, .init(name: nil))
        XCTAssertEqual(refusedResolution.status, "rejected")
        XCTAssertTrue(refused.records.records.isEmpty)

        // The schedule switch off: no entry, no record.
        let skipped = makeRig()
        let skippedResolution = try await confirmed(skipped) { XCTAssertTrue($0.chooseOption("add-to-schedule", "false")) }
        XCTAssertEqual(skippedResolution.status, "applied")
        XCTAssertTrue(skipped.store.activities.isEmpty)
        XCTAssertTrue(skipped.records.records.isEmpty)

        // A partner that gives no time result: an applied answer, no entry, no record.
        let parcels = makeRig(shapes: [.parcels()])
        let parcelsCardValue = await parcels.card(.init(restaurant: nil, party: nil, start: nil, name: nil), partner: "parcels")
        let parcelsCard = try XCTUnwrap(parcelsCardValue)
        let parcelsFields = try XCTUnwrap(parcelsCard.fieldCard)
        XCTAssertTrue(parcelsFields.choosePlace("where", DeliveryToolFixture.library))
        XCTAssertTrue(parcelsFields.chooseOption("speed", "fast"))
        XCTAssertTrue(parcelsFields.chooseOption("signed", "true"))
        XCTAssertTrue(parcelsFields.setText("count", "1"))
        let parcelsResolutionValue = await parcelsCard.resolve(.confirm)
        let parcelsResolution = try XCTUnwrap(parcelsResolutionValue)
        XCTAssertEqual(parcelsResolution.status, "applied")
        XCTAssertTrue(parcels.store.activities.isEmpty)
        XCTAssertTrue(parcels.records.records.isEmpty)
    }
}
