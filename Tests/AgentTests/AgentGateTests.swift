import XCTest
@testable import besir

/// AC-AGENT-002, gate reading, value rules, ids and apply-time results (spec.md sections 3.3 and 3.4).
/// Clock 2026-10-27T09:00 in America/Los_Angeles; a throwaway Store emptied for every test.
@MainActor
final class AgentGateTests: XCTestCase {
    private let create = "create_activity"
    private let update = "update_activity"
    private let delete = "delete_activity"
    private let list = "list_activities"

    private func createArgs(title: Any = "Team sync", start: Any = "2026-10-28T15:00", end: Any = "2026-10-28T16:00") -> [String: Any] {
        ["title": title, "start": start, "end": end]
    }

    private func assertRejected(_ outcome: AgentToolOutcome, _ message: String, _ note: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(outcome.card, note, file: file, line: line)
        XCTAssertEqual(outcome.status, "rejected", note, file: file, line: line)
        XCTAssertEqual(outcome.message, message, note, file: file, line: line)
    }

    // MARK: - Gate reading

    func testAG002_UndeclaredKeysAreDroppedBeforeReading() async throws {
        let h = ToolHarness.make()
        let record = h.seed("Stored", "2026-10-28T10:00", "2026-10-28T11:00")
        // Positive counterpart: the plain call gives a card.
        XCTAssertNotNil(h.call(create, createArgs()).card)
        // Undeclared keys, some with the wrong type, are never read and never shown.
        var extra = createArgs()
        extra["location"] = "SENTINEL_PLACE"
        extra["duration"] = 90
        extra["id"] = ["x"]
        extra["label"] = "SENTINEL_LABEL"
        let card = try XCTUnwrap(h.call(create, extra).card)
        let text = card.lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Team sync"))
        XCTAssertFalse(text.contains("SENTINEL"))
        let applied = await card.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        let created = h.store.activities.first { $0.title == "Team sync" }
        XCTAssertNotNil(created)
        XCTAssertNil(created?.location)
        // Keys declared for another tool are undeclared here: title and start on delete are dropped.
        let del = try XCTUnwrap(h.call(delete, ["id": record.id.uuidString, "title": 5, "start": ["x"], "force": true]).card)
        XCTAssertEqual(del.lines.first, "Delete event")
        XCTAssertEqual(del.lines.dropFirst().first, "Stored")
        // A list call ignores a limit key.
        XCTAssertNotNil(h.call(list, ["from": "2026-10-28T00:00", "to": "2026-10-29T00:00", "limit": 1]).json?["items"])
    }

    func testAG002_ConfirmLikeKeysHaveNoEffect() async throws {
        let h = ToolHarness.make()
        let before = h.snapshot
        var args = createArgs()
        args["confirm"] = true
        args["confirmed"] = true
        args["approved"] = true
        let card = try XCTUnwrap(h.call(create, args).card)
        // Nothing is written until the card is confirmed.
        XCTAssertEqual(h.store.activities.count, 0)
        XCTAssertEqual(h.snapshot, before)
        let applied = await card.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        XCTAssertEqual(h.store.activities.count, 1)

        let record = h.seed("Keep me", "2026-10-28T10:00", "2026-10-28T11:00")
        let del = try XCTUnwrap(h.call(delete, ["id": record.id.uuidString, "confirm": true, "force": "yes", "approved": "true"]).card)
        XCTAssertNotNil(h.activity(record.id))
        XCTAssertEqual(h.store.activities.count, 2)
        let declined = await del.resolve(.cancel)
        XCTAssertEqual(declined?.status, "declined")
        XCTAssertNotNil(h.activity(record.id))
    }

    func testAG002_EmptyStringOptionalReadsAsAbsent() async throws {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        // Empty or blank start and end read as absent: only the title changes.
        let card = try XCTUnwrap(h.call(update, ["id": record.id.uuidString, "title": "Renamed", "start": "", "end": "   "]).card)
        let applied = await card.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        let stored = try XCTUnwrap(h.activity(record.id))
        XCTAssertEqual(stored.title, "Renamed")
        XCTAssertEqual(TestClock.local(stored.startDate), "2026-10-28T10:00")
        XCTAssertEqual(TestClock.local(stored.endDate), "2026-10-28T11:00")
        // An empty title with a real start: only the start changes.
        let moved = try XCTUnwrap(h.call(update, ["id": record.id.uuidString, "title": "", "start": "2026-10-28T14:00", "end": ""]).card)
        _ = await moved.resolve(.confirm)
        let after = try XCTUnwrap(h.activity(record.id))
        XCTAssertEqual(after.title, "Renamed")
        XCTAssertEqual(TestClock.local(after.startDate), "2026-10-28T14:00")
    }

    func testAG002_EmptyRequiredReadsAsMissing() {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let before = h.snapshot
        for param in ["title", "start", "end"] {
            for empty in ["", "   "] {
                var args = createArgs()
                args[param] = empty
                assertRejected(h.call(create, args), ToolText.missing(param), "create \(param) empty")
            }
            var absent = createArgs()
            absent[param] = nil
            assertRejected(h.call(create, absent), ToolText.missing(param), "create \(param) absent")
        }
        for tool in [update, delete] {
            for empty in ["", "  "] {
                assertRejected(h.call(tool, ["id": empty, "title": "X"]), ToolText.findID(tool), "\(tool) id empty")
            }
            assertRejected(h.call(tool, ["title": "X"]), ToolText.findID(tool), "\(tool) id absent")
        }
        for param in ["from", "to"] {
            for empty in ["", " "] {
                var args: [String: Any] = ["from": "2026-10-28T00:00", "to": "2026-10-29T00:00"]
                args[param] = empty
                assertRejected(h.call(list, args), ToolText.listRange, "list \(param) empty")
            }
            var absent: [String: Any] = ["from": "2026-10-28T00:00", "to": "2026-10-29T00:00"]
            absent[param] = nil
            assertRejected(h.call(list, absent), ToolText.listRange, "list \(param) absent")
        }
        // Positive counterpart: the same record is found when the id is present.
        XCTAssertNotNil(h.call(delete, ["id": record.id.uuidString]).card)
        XCTAssertEqual(h.snapshot, before)
    }

    func testAG002_WrongJSONTypeIsRejectedNotCoerced() {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let before = h.snapshot
        XCTAssertNotNil(h.call(create, createArgs()).card)
        for wrong in [5, 5.5, true, ["a"], ["a": 1]] as [Any] {
            assertRejected(h.call(create, createArgs(title: wrong)), ToolText.wrongType(create, "title"), "title \(wrong)")
        }
        assertRejected(h.call(create, createArgs(start: 20261028)), ToolText.wrongType(create, "start"))
        assertRejected(h.call(create, createArgs(end: 5)), ToolText.wrongType(create, "end"))
        assertRejected(h.call(update, ["id": ["x"]]), ToolText.wrongType(update, "id"))
        assertRejected(h.call(update, ["id": record.id.uuidString, "title": 5]), ToolText.wrongType(update, "title"))
        assertRejected(h.call(delete, ["id": 12]), ToolText.wrongType(delete, "id"))
        assertRejected(h.call(delete, ["id": [record.id.uuidString]]), ToolText.wrongType(delete, "id"))
        assertRejected(h.call(list, ["from": 5, "to": "2026-10-29T00:00"]), ToolText.wrongType(list, "from"))
        assertRejected(h.call(list, ["from": "2026-10-28T00:00", "to": true]), ToolText.wrongType(list, "to"))
        XCTAssertEqual(h.snapshot, before)
    }

    func testAG002_ArgumentsThatAreNotAnObjectAreRejected() {
        let h = ToolHarness.make()
        let before = h.snapshot
        // Positive counterpart: an empty object is an object, so it is refused for another reason.
        XCTAssertEqual(h.call(create, raw: "{}").status, "rejected")
        XCTAssertNotEqual(h.call(create, raw: "{}").message, ToolText.notObject(create))
        XCTAssertEqual(h.call(list, raw: "{}").message, ToolText.listRange)
        for tool in [list, create, update, delete] {
            for raw in ["[]", "[1,2]", "\"text\"", "5", "null", "true"] {
                assertRejected(h.call(tool, raw: raw), ToolText.notObject(tool), "\(tool) \(raw)")
            }
        }
        XCTAssertEqual(h.snapshot, before)
    }

    func testAG002_UnparsableArgumentsAreRejected() {
        let h = ToolHarness.make()
        let before = h.snapshot
        XCTAssertNotNil(h.call(create, raw: "{\"title\":\"Team sync\",\"start\":\"2026-10-28T15:00\",\"end\":\"2026-10-28T16:00\"}").card)
        for tool in [list, create, update, delete] {
            for raw in ["{", "{\"title\":", "not json", "{'a':1}"] {
                assertRejected(h.call(tool, raw: raw), ToolText.notObject(tool), "\(tool) \(raw)")
            }
        }
        XCTAssertEqual(h.snapshot, before)
    }

    func testAG002_UnknownToolIsRejected() {
        let h = ToolHarness.make()
        let before = h.snapshot
        // Positive counterpart: a declared name is not unknown.
        XCTAssertNotNil(h.call(create, createArgs()).card)
        let names = ["delete_all_activities", "List_Activities", "create_activity ", "", "SENTINEL_IGNORE_PREVIOUS_INSTRUCTIONS"]
        for name in names {
            let outcome = h.call(name, ["title": "Team sync"])
            assertRejected(outcome, ToolText.unknownTool, "name '\(name)'")
            // The unknown name is never echoed.
            XCTAssertFalse((outcome.message ?? "").contains("SENTINEL"))
        }
        XCTAssertEqual(h.snapshot, before)
    }

    func testAG002_DuplicateKeysAreReadOnceAndTheCardAgrees() async throws {
        let h = ToolHarness.make()
        let raw = "{\"title\":\"First\",\"start\":\"2026-10-28T15:00\",\"end\":\"2026-10-28T16:00\",\"title\":\"Second\"}"
        // The parser's result is authoritative: ask Foundation which of the two it keeps.
        let parsed = try XCTUnwrap(TestClock.object(raw))
        let expected = try XCTUnwrap(parsed["title"] as? String)
        XCTAssertTrue(["First", "Second"].contains(expected))
        let card = try XCTUnwrap(h.call(create, raw: raw).card)
        XCTAssertEqual(card.lines.dropFirst().first, expected)
        XCTAssertFalse(card.lines.contains { $0.contains(expected == "First" ? "Second" : "First") })
        let applied = await card.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        XCTAssertEqual(h.store.activities.map(\.title), [expected])
    }

    // MARK: - Value rules

    func testAG002_TimeFormatIsStrict() {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let before = h.snapshot
        let id = record.id.uuidString
        XCTAssertNotNil(h.call(create, createArgs(start: "2026-10-28T19:00", end: "2026-10-28T20:00")).card)
        XCTAssertNotNil(h.call(list, ["from": "2026-10-28T19:00", "to": "2026-10-29T19:00"]).json?["items"])
        let bad = ["2026-10-28 19:00", "2026-10-28T19:00:00", "2026-10-28T19:00Z", "10/28/2026 7pm", "2026-10-28",
                   "2026-10-28T19:00+09:00", "2026-10-28t19:00", "2026-10-28T7:00"]
        for value in bad {
            assertRejected(h.call(create, createArgs(start: value, end: "2026-10-28T20:00")),
                           ToolText.timeForm(create, "start"), "create start \(value)")
            assertRejected(h.call(create, createArgs(start: "2026-10-28T19:00", end: value)),
                           ToolText.timeForm(create, "end"), "create end \(value)")
            assertRejected(h.call(update, ["id": id, "start": value]), ToolText.timeForm(update, "start"), "update start \(value)")
            assertRejected(h.call(update, ["id": id, "end": value]), ToolText.timeForm(update, "end"), "update end \(value)")
            assertRejected(h.call(list, ["from": value, "to": "2026-10-29T19:00"]), ToolText.timeForm(list, "from"), "list from \(value)")
            assertRejected(h.call(list, ["from": "2026-10-28T19:00", "to": value]), ToolText.timeForm(list, "to"), "list to \(value)")
        }
        XCTAssertEqual(h.snapshot, before)
    }

    func testAG002_NonexistentLocalTimesAreRejected() {
        let h = ToolHarness.make()
        // A date that does not exist: refused as not being a local date-time (never rolled over to the next month).
        assertRejected(h.call(create, createArgs(start: "2026-02-30T10:00", end: "2026-02-30T11:00")), ToolText.timeForm(create, "start"))
        assertRejected(h.call(create, createArgs(start: "2026-11-31T10:00", end: "2026-12-01T10:00")), ToolText.timeForm(create, "start"))
        XCTAssertNotNil(h.call(create, createArgs(start: "2026-11-30T10:00", end: "2026-11-30T11:00")).card)
        // The spring-forward gap of 2027-03-14 (02:00 to 03:00 does not exist) with the clock the day before.
        let spring = ToolHarness.make(now: "2027-03-13T09:00")
        assertRejected(spring.call(create, createArgs(start: "2027-03-14T02:30", end: "2027-03-14T04:00")), ToolText.timeForm(create, "start"))
        assertRejected(spring.call(create, createArgs(start: "2027-03-14T01:00", end: "2027-03-14T02:30")), ToolText.timeForm(create, "end"))
        XCTAssertNotNil(spring.call(create, createArgs(start: "2027-03-14T03:30", end: "2027-03-14T04:30")).card)
        // The repeated hour of the fall-back night (2026-11-01 01:00 to 02:00 happens twice) is accepted.
        XCTAssertNotNil(h.call(create, createArgs(start: "2026-11-01T01:30", end: "2026-11-01T03:00")).card)
    }

    func testAG002_EndMustBeAfterStart() {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        XCTAssertNotNil(h.call(create, createArgs(start: "2026-10-28T15:00", end: "2026-10-28T15:01")).card)
        assertRejected(h.call(create, createArgs(start: "2026-10-28T15:00", end: "2026-10-28T15:00")), ToolText.endAfterStart(create), "equal")
        assertRejected(h.call(create, createArgs(start: "2026-10-28T15:00", end: "2026-10-28T14:59")), ToolText.endAfterStart(create), "before")
        let id = record.id.uuidString
        assertRejected(h.call(update, ["id": id, "start": "2026-10-28T15:00", "end": "2026-10-28T15:00"]), ToolText.endAfterStart(update), "update equal")
        assertRejected(h.call(update, ["id": id, "start": "2026-10-28T15:00", "end": "2026-10-28T14:00"]), ToolText.endAfterStart(update), "update before")
        XCTAssertNotNil(h.call(update, ["id": id, "start": "2026-10-28T15:00", "end": "2026-10-28T16:00"]).card)
    }

    func testAG002_DurationAtMostTwentyFourHours() {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let id = record.id.uuidString
        XCTAssertNotNil(h.call(create, createArgs(start: "2026-10-28T09:00", end: "2026-10-29T09:00")).card, "exactly 24 hours")
        assertRejected(h.call(create, createArgs(start: "2026-10-28T09:00", end: "2026-10-29T09:01")), ToolText.tooLong(create), "24 hours and a minute")
        XCTAssertNotNil(h.call(update, ["id": id, "start": "2026-10-28T09:00", "end": "2026-10-29T09:00"]).card, "update both, 24 hours")
        assertRejected(h.call(update, ["id": id, "start": "2026-10-28T09:00", "end": "2026-10-29T09:01"]), ToolText.tooLong(update), "update both, over")
    }

    func testAG002_StartWindowBoundaries() {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let before = h.snapshot
        // The clock is 2026-10-27T09:00: the window is 2026-10-26T09:00 to 2027-10-28T09:00, both ends inclusive.
        XCTAssertNotNil(h.call(create, createArgs(start: "2026-10-26T09:00", end: "2026-10-26T10:00")).card, "now minus one day")
        assertRejected(h.call(create, createArgs(start: "2026-10-26T08:59", end: "2026-10-26T10:00")), ToolText.window(create), "one minute earlier")
        XCTAssertNotNil(h.call(create, createArgs(start: "2027-10-28T09:00", end: "2027-10-28T10:00")).card, "now plus 366 days")
        assertRejected(h.call(create, createArgs(start: "2027-10-28T09:01", end: "2027-10-28T10:00")), ToolText.window(create), "one minute later")
        let id = record.id.uuidString
        XCTAssertNotNil(h.call(update, ["id": id, "start": "2026-10-26T09:00"]).card)
        assertRejected(h.call(update, ["id": id, "start": "2026-10-26T08:59"]), ToolText.window(update), "update earlier")
        assertRejected(h.call(update, ["id": id, "start": "2027-10-28T09:01"]), ToolText.window(update), "update later")
        XCTAssertEqual(h.snapshot, before)
    }

    func testAG002_TitleIsTrimmedAndControlCharactersRemoved() async throws {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let card = try XCTUnwrap(h.call(create, createArgs(title: "  Team\u{07} sync\n  ")).card)
        XCTAssertEqual(card.lines.dropFirst().first, "Team sync")
        let applied = await card.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        XCTAssertEqual(applied?.json?["title"] as? String, "Team sync")
        XCTAssertTrue(h.store.activities.contains { $0.title == "Team sync" })
        // Nothing left after removing controls and trimming: the title is missing.
        assertRejected(h.call(create, createArgs(title: "\u{07} \n \t ")), ToolText.missing("title"))
        // On update a title that is empty afterwards is absent, so no change is named.
        assertRejected(h.call(update, ["id": record.id.uuidString, "title": "\n\u{07}"]), ToolText.noChange)
    }

    func testAG002_LineSeparatorsAndFormatCharactersAreRemoved() async throws {
        let h = ToolHarness.make()
        // U+2028, U+2029, a right-to-left override, the zero-width space (Cf) and a left-to-right isolate are removed.
        let title = "Lunch\u{2028}with\u{2029}Sam\u{202E}\u{200B}\u{2066}!"
        let card = try XCTUnwrap(h.call(create, createArgs(title: title)).card)
        XCTAssertEqual(card.lines.dropFirst().first, "LunchwithSam!")
        let applied = await card.resolve(.confirm)
        XCTAssertEqual(applied?.json?["title"] as? String, "LunchwithSam!")
        XCTAssertEqual(h.store.activities.first?.title, "LunchwithSam!")
        assertRejected(h.call(create, createArgs(title: "\u{200B}\u{202E}\u{2028}")), ToolText.missing("title"))
    }

    func testAG002_TitleLimitCountsGraphemes() throws {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let emoji = "\u{1F44D}\u{1F3FD}"
        let accent = "e\u{0301}"
        let sets = ["a", emoji, accent]
        for unit in sets {
            let ok = String(repeating: unit, count: 80)
            XCTAssertEqual(ok.count, 80, "premise: 80 clusters")
            let card = try XCTUnwrap(h.call(create, createArgs(title: ok)).card, "80 accepted")
            // Not truncated and not altered.
            XCTAssertEqual(card.lines.dropFirst().first, ok)
            let tooLong = String(repeating: unit, count: 81)
            assertRejected(h.call(create, createArgs(title: tooLong)), ToolText.titleTooLong(create), "81 rejected")
            assertRejected(h.call(update, ["id": record.id.uuidString, "title": tooLong]), ToolText.titleTooLong(update), "update 81 rejected")
        }
        XCTAssertGreaterThan(String(repeating: emoji, count: 80).unicodeScalars.count, 80)
    }

    func testAG002_UpdateNeedsAtLeastOneChange() {
        let h = ToolHarness.make()
        let id = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00").id.uuidString
        XCTAssertNotNil(h.call(update, ["id": id, "title": "X"]).card)
        assertRejected(h.call(update, ["id": id]), ToolText.noChange, "id only")
        assertRejected(h.call(update, ["id": id, "title": ""]), ToolText.noChange, "empty title")
        assertRejected(h.call(update, ["id": id, "title": "  ", "start": "", "end": " "]), ToolText.noChange, "all blank")
    }

    func testAG002_UpdateStartOnlyKeepsDuration() async throws {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        // The new start is after the old end: allowed, because the end moves with the start.
        let card = try XCTUnwrap(h.call(update, ["id": record.id.uuidString, "start": "2026-10-28T14:00"]).card)
        XCTAssertEqual(card.lines.last, "Wed, Oct 28, 2:00 PM - 3:00 PM")
        let applied = await card.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        XCTAssertEqual(applied?.json?["start"] as? String, "2026-10-28T14:00")
        XCTAssertEqual(applied?.json?["end"] as? String, "2026-10-28T15:00")
        let stored = try XCTUnwrap(h.activity(record.id))
        XCTAssertEqual(stored.endDate.timeIntervalSince(stored.startDate), 3600)
    }

    func testAG002_UpdateEndOnlyKeepsStart() async throws {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let id = record.id.uuidString
        assertRejected(h.call(update, ["id": id, "end": "2026-10-28T10:00"]), ToolText.endAfterStart(update), "end equals start")
        assertRejected(h.call(update, ["id": id, "end": "2026-10-28T09:00"]), ToolText.endAfterStart(update), "end before start")
        let card = try XCTUnwrap(h.call(update, ["id": id, "end": "2026-10-28T12:00"]).card)
        XCTAssertEqual(card.lines.last, "Wed, Oct 28, 10:00 AM - 12:00 PM")
        let applied = await card.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        let stored = try XCTUnwrap(h.activity(record.id))
        XCTAssertEqual(TestClock.local(stored.startDate), "2026-10-28T10:00")
        XCTAssertEqual(TestClock.local(stored.endDate), "2026-10-28T12:00")
    }

    func testAG002_ListRangeRules() {
        let h = ToolHarness.make()
        // 31 days with no clock change inside: accepted. One minute more: rejected.
        XCTAssertNotNil(h.call(list, ["from": "2026-11-05T00:00", "to": "2026-12-06T00:00"]).json?["items"], "31 days")
        assertRejected(h.call(list, ["from": "2026-11-05T00:00", "to": "2026-12-06T00:01"]), ToolText.listInvalid, "31 days and a minute")
        assertRejected(h.call(list, ["from": "2026-11-05T00:00", "to": "2026-11-05T00:00"]), ToolText.listInvalid, "to equals from")
        assertRejected(h.call(list, ["from": "2026-11-05T00:00", "to": "2026-11-04T00:00"]), ToolText.listInvalid, "to before from")
        XCTAssertNotNil(h.call(list, ["from": "2026-11-05T00:00", "to": "2026-11-05T00:01"]).json?["items"], "one minute")
    }

    func testAG002_LongRecordTitleOnlyUpdateIsAccepted() async throws {
        let h = ToolHarness.make()
        let record = h.seed("Conference", "2026-10-28T09:00", "2026-10-30T09:00")
        let card = try XCTUnwrap(h.call(update, ["id": record.id.uuidString, "title": "Conference trip"]).card)
        let applied = await card.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        let stored = try XCTUnwrap(h.activity(record.id))
        XCTAssertEqual(stored.title, "Conference trip")
        XCTAssertEqual(stored.endDate.timeIntervalSince(stored.startDate), 48 * 3600)
    }

    func testAG002_LongRecordStartOnlyKeepsDuration() async throws {
        let h = ToolHarness.make()
        let record = h.seed("Conference", "2026-10-28T09:00", "2026-10-30T09:00")
        let card = try XCTUnwrap(h.call(update, ["id": record.id.uuidString, "start": "2026-10-29T09:00"]).card)
        let applied = await card.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        let stored = try XCTUnwrap(h.activity(record.id))
        XCTAssertEqual(TestClock.local(stored.startDate), "2026-10-29T09:00")
        XCTAssertEqual(stored.endDate.timeIntervalSince(stored.startDate), 48 * 3600)
    }

    func testAG002_LongRecordEndOnlyOverLimitIsRejected() {
        let h = ToolHarness.make()
        let id = h.seed("Conference", "2026-10-28T09:00", "2026-10-30T09:00").id.uuidString
        // New end minus the record's start is 47 hours: over the limit.
        assertRejected(h.call(update, ["id": id, "end": "2026-10-30T08:00"]), ToolText.tooLong(update), "47 hours")
        assertRejected(h.call(update, ["id": id, "end": "2026-10-29T09:01"]), ToolText.tooLong(update), "24 hours and a minute")
        // Bringing the duration to 24 hours or less is accepted.
        XCTAssertNotNil(h.call(update, ["id": id, "end": "2026-10-29T09:00"]).card, "exactly 24 hours")
    }

    // MARK: - Ids and apply-time results

    func testAG002_NonUUIDIdIsRejected() {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let before = h.snapshot
        for tool in [update, delete] {
            XCTAssertNotNil(h.call(tool, ["id": record.id.uuidString, "title": "X"]).card, "\(tool) real id")
            for bad in ["not-a-uuid", "12345", "ABC", "\(record.id.uuidString)x", "{\(record.id.uuidString)}"] {
                assertRejected(h.call(tool, ["id": bad, "title": "X"]), ToolText.findID(tool), "\(tool) \(bad)")
            }
        }
        XCTAssertEqual(h.snapshot, before)
    }

    func testAG002_UnknownIdIsRejectedAtCardTime() {
        let h = ToolHarness.make()
        let record = h.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
        let before = h.snapshot
        for tool in [update, delete] {
            XCTAssertNotNil(h.call(tool, ["id": record.id.uuidString, "title": "X"]).card, "\(tool) existing")
            // A well-formed UUID that is not in the Store.
            assertRejected(h.call(tool, ["id": UUID().uuidString, "title": "X"]), ToolText.findID(tool), "\(tool) unknown")
        }
        XCTAssertEqual(h.snapshot, before)
    }

    func testAG002_IdMissingAtApplyTimeReportsNotFound() async throws {
        let h = ToolHarness.make()
        let doomed = h.seed("Doomed", "2026-10-28T10:00", "2026-10-28T11:00")
        let doomedToo = h.seed("Doomed too", "2026-10-28T12:00", "2026-10-28T13:00")
        let healthy = h.seed("Healthy", "2026-10-28T14:00", "2026-10-28T15:00")
        let updateCard = try XCTUnwrap(h.call(update, ["id": doomed.id.uuidString, "title": "Renamed"]).card)
        let deleteCard = try XCTUnwrap(h.call(delete, ["id": doomedToo.id.uuidString]).card)
        h.store.deleteActivity(doomed)
        h.store.deleteActivity(doomedToo)
        let prior = h.snapshot
        for card in [updateCard, deleteCard] {
            let outcome = await card.resolve(.confirm)
            XCTAssertEqual(outcome?.status, "not_found")
            XCTAssertEqual(outcome?.message, ToolText.notFound)
            XCTAssertEqual(outcome?.json.map { Set($0.keys) }, ["status", "message"])
            XCTAssertEqual(outcome?.notice, ToolText.notice)
            XCTAssertEqual(card.mark, .notApplied)
        }
        // Nothing was applied, and nothing came back to life.
        XCTAssertEqual(h.snapshot, prior)
        XCTAssertEqual(h.store.activities.map(\.title), ["Healthy"])
        // An unchanged record is applied normally.
        let ok = try XCTUnwrap(h.call(update, ["id": healthy.id.uuidString, "title": "Healthy 2"]).card)
        let applied = await ok.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        XCTAssertNil(applied?.notice)
        XCTAssertEqual(ok.mark, .confirmed)
        XCTAssertEqual(h.activity(healthy.id)?.title, "Healthy 2")
    }

    func testAG002_ChangedRecordAtApplyTimeReportsStale() async throws {
        let h = ToolHarness.make()
        let first = h.seed("First", "2026-10-28T10:00", "2026-10-28T11:00")
        let second = h.seed("Second", "2026-10-28T12:00", "2026-10-28T13:00")
        let healthy = h.seed("Healthy", "2026-10-28T14:00", "2026-10-28T15:00")
        let placed = h.seed("Placed", "2026-10-28T16:00", "2026-10-28T17:00")
        let series = h.seed("Series", "2026-10-28T18:00", "2026-10-28T19:00")
        let updateCard = try XCTUnwrap(h.call(update, ["id": first.id.uuidString, "title": "Card title"]).card)
        let deleteCard = try XCTUnwrap(h.call(delete, ["id": second.id.uuidString]).card)
        let placedCard = try XCTUnwrap(h.call(update, ["id": placed.id.uuidString, "title": "Placed 2"]).card)
        let seriesCard = try XCTUnwrap(h.call(delete, ["id": series.id.uuidString]).card)
        // Another writer changes the records after the cards were shown.
        h.store.modifyActivity(id: first.id, newTitle: "Changed elsewhere")
        h.store.modifyActivity(id: second.id, newEnd: TestClock.date("2026-10-28T13:30"))
        // A place or a repeat series added after the card was shown is a change too: the card did not show it.
        let placedAt = try XCTUnwrap(h.store.activities.firstIndex { $0.id == placed.id })
        h.store.activities[placedAt].location = Place(name: "Cafe Nero", address: "1 Road", latitude: 1, longitude: 2)
        let seriesAt = try XCTUnwrap(h.store.activities.firstIndex { $0.id == series.id })
        h.store.activities[seriesAt].recurrenceId = UUID()
        let prior = h.snapshot
        for card in [updateCard, deleteCard, placedCard, seriesCard] {
            let outcome = await card.resolve(.confirm)
            XCTAssertEqual(outcome?.status, "stale")
            XCTAssertEqual(outcome?.message, ToolText.stale)
            XCTAssertEqual(outcome?.json.map { Set($0.keys) }, ["status", "message"])
            XCTAssertEqual(outcome?.notice, ToolText.notice)
            XCTAssertEqual(card.mark, .notApplied)
        }
        XCTAssertEqual(h.snapshot, prior)
        XCTAssertEqual(h.activity(first.id)?.title, "Changed elsewhere")
        XCTAssertNotNil(h.activity(second.id))
        // An unchanged record is applied normally.
        let ok = try XCTUnwrap(h.call(delete, ["id": healthy.id.uuidString]).card)
        let applied = await ok.resolve(.confirm)
        XCTAssertEqual(applied?.status, "applied")
        XCTAssertNil(h.activity(healthy.id))
    }
}
