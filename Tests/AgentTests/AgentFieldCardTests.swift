import XCTest
@testable import besir

/// SPEC-CHOICECARD-001 AC-CHOICECARD-007 to 010 and 013: the field-card model draws an edit card from field seeds, keeps the
/// value and the source of each, and acts on exactly the change the user makes. Every test builds and drives the model alone:
/// no session, no toolbox, no view. A field is always reached by its key and `field(_:)`, never by an index, so a skeleton that
/// builds nothing fails on the assertion and not on a crash.
@MainActor
final class AgentFieldCardTests: XCTestCase {
    private let now = TestClock.now
    private let arrival = TestClock.date("2026-10-28T19:40")

    private func place(_ name: String, _ address: String, _ latitude: Double = 37.5, _ longitude: Double = -122.4) -> Place {
        Place(name: name, address: address, latitude: latitude, longitude: longitude)
    }

    private lazy var home = FavoritePlace(label: "Home", place: place("Home", "1 Home Road", 37.1, -122.1))
    private lazy var cafeNorth = FavoritePlace(label: "Cafe", place: place("Cafe", "10 North Street", 37.9, -122.9))
    private lazy var cafeSouth = FavoritePlace(label: "Cafe", place: place("Cafe", "20 South Street", 37.2, -122.2))

    /// The search closure of a test: records every query and answers `places`.
    private final class Searches {
        var queries: [String] = []
        var places: [Place] = []
        func run(_ query: String) async -> [Place] {
            queries.append(query)
            return places
        }
    }

    private let pay = AgentFieldSpec(key: "card_id", kind: .pickOne, label: "Pay with",
                                     options: [AgentFieldOption(id: "debit", label: "Debit one"), AgentFieldOption(id: "credit", label: "Credit two")])
    private var arriveSpec: AgentFieldSpec { AgentFieldSpec(key: "arrive_at", kind: .time, label: "Arrival") }
    private var addressSpec: AgentFieldSpec { AgentFieldSpec(key: "address", kind: .place, label: "Delivery place") }
    private var noteSpec: AgentFieldSpec { AgentFieldSpec(key: "note", kind: .text, label: "Note") }
    private var mealSwitch: AgentFieldSpec { .onOff(key: "meal", label: "Add to schedule", on: "Add", off: "Don't Add") }
    private var mealTitle: AgentFieldSpec { AgentFieldSpec(key: "meal_title", kind: .text, label: "Meal title", limit: 68) }
    private var mealStart: AgentFieldSpec { AgentFieldSpec(key: "meal_start", kind: .time, label: "Start") }

    private func make(_ rows: [AgentFieldRow], favorites: [FavoritePlace] = [], searches: Searches = Searches(),
                      header: String = "Order delivery") -> AgentFieldCard {
        AgentFieldCard(header: header, rows: rows, favorites: favorites, search: { await searches.run($0) }, now: { [now] in now })
    }

    /// The rows of AC-CHOICECARD-013 for a delivery order: four read-only rows, the partner's three fields, the app's own
    /// meal switch with its two dependents and the partner line. Arrival is stated, the card chosen, the place blank.
    private func deliveryRows(address: AgentFieldValue? = nil, addressSource: AgentFieldSource = .blank,
                              card: AgentFieldValue? = .option("debit"), cardSource: AgentFieldSource = .stated,
                              title: String = "Dinner") -> [AgentFieldRow] {
        [.line("Pasta Palace"), .line("2 x Ramen"), .line("1 x Gyoza"), .line("Estimated total $40.00"),
         .field(arriveSpec, value: .time(arrival), source: .stated),
         .field(addressSpec, value: address, source: addressSource),
         .field(pay, value: card, source: cardSource),
         .switchField(mealSwitch, value: .flag(true), source: .inferred, dependents: [
            .field(mealTitle, value: .text(title), source: .inferred),
            .field(mealStart, value: .time(arrival), source: .inferred)]),
         .line("Example Delivery - Simulated")]
    }

    private func keys(_ model: AgentFieldCard) -> [String] { model.card.fields.map(\.key) }

    private func isSearching(_ lookup: EditField.Lookup?) -> Bool {
        if case .searching? = lookup { return true }
        return false
    }

    private func results(_ lookup: EditField.Lookup?) -> [Place]? {
        if case .results(let found)? = lookup { return found }
        return nil
    }

    private func isEmptyLookup(_ lookup: EditField.Lookup?) -> Bool {
        if case .empty? = lookup { return true }
        return false
    }

    private func isIdle(_ lookup: EditField.Lookup?) -> Bool {
        if case .idle? = lookup { return true }
        return false
    }

    private func settle(_ seconds: Double = 0.7) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: M01 one seed per kind

    func testM01_OneSeedPerKindBuildsTheMatchingEditFieldInOrder() throws {
        let rows: [AgentFieldRow] = [
            .line("A read-only row"),
            .field(noteSpec, value: .text("hello"), source: .stated),
            .field(addressSpec, value: nil, source: .blank),
            .field(arriveSpec, value: .time(arrival), source: .stated),
            .field(pay, value: .option("credit"), source: .stated),
            .field(mealSwitch, value: .flag(true), source: .inferred)]
        let model = make(rows, favorites: [home])
        XCTAssertEqual(model.header, "Order delivery")
        XCTAssertEqual(model.card.fields.map(\.kind), [.readonly, .title, .place, .datetime, .toggle, .toggle])
        XCTAssertEqual(model.card.fields.dropFirst().map(\.key), ["note", "address", "arrive_at", "card_id", "meal"])
        XCTAssertEqual(model.card.fields.dropFirst().map(\.label), ["Note", "Delivery place", "Arrival", "Pay with", "Add to schedule"])
        XCTAssertEqual(try XCTUnwrap(model.card.fields.first).chosen, "A read-only row")
        XCTAssertEqual(Set(model.card.fields.map(\.id)).count, 6, "every row has its own identity")

        XCTAssertFalse(try XCTUnwrap(model.field("arrive_at")).anchored, "a time row has no arrival or departure chips")
        XCTAssertNil(try XCTUnwrap(model.field("arrive_at")).endWheel)
        let chips = try XCTUnwrap(model.field("card_id")).options
        XCTAssertEqual(chips.map(\.label), ["Debit one", "Credit two"])
        XCTAssertEqual(chips.map(\.value), ["debit", "credit"])
        // The on/off seed builds a toggle whose two chips read exactly the seed's words, with the values true then false.
        let door = try XCTUnwrap(model.field("meal")).options
        XCTAssertEqual(door.map(\.label), ["Add", "Don't Add"])
        XCTAssertEqual(door.map(\.value), ["true", "false"])
        // The place row carries the favorites with their coordinates and no special row.
        let placeRow = try XCTUnwrap(model.field("address"))
        XCTAssertEqual(placeRow.options.map(\.label), ["Home"])
        XCTAssertEqual(placeRow.options.first?.place, home.place)
        XCTAssertTrue(placeRow.placeSpecials.isEmpty)

        // The six wire words map to the six kinds; any other word maps to none.
        XCTAssertEqual(["text", "place", "time", "pick_one", "on_off", "number"].map(AgentFieldKind.init(wire:)),
                       [.text, .place, .time, .pickOne, .onOff, .number])
        XCTAssertNil(AgentFieldKind(wire: "integer"))
        // A seed made from the partner's field keeps its key, label and chips.
        let fromPartner = AgentFieldSpec(PartnerField(key: "door", kind: .onOff, label: "Leave at door",
                                                      options: [PartnerOption(id: "true", label: "Leave"), PartnerOption(id: "false", label: "Hand over")]))
        XCTAssertEqual(fromPartner?.kind, .onOff)
        XCTAssertEqual(fromPartner?.options.map(\.label), ["Leave", "Hand over"])
        let viaModel = make([.field(try XCTUnwrap(fromPartner), value: nil, source: .blank)])
        XCTAssertEqual(try XCTUnwrap(viaModel.field("door")).options.map(\.value), ["true", "false"])
    }

    // MARK: M02 the sources

    func testM02_StatedInferredAndBlankStartAsTheyAreAndAChangeReportsEntered() throws {
        let model = make([.field(noteSpec, value: .text("said"), source: .stated),
                          .field(arriveSpec, value: .time(arrival), source: .inferred),
                          .field(pay, value: nil, source: .blank)])
        XCTAssertEqual(try XCTUnwrap(model.field("note")).chosen, "said")
        XCTAssertEqual(try XCTUnwrap(model.field("arrive_at")).chosen, BesirTime.isoFormatter.string(from: arrival))
        XCTAssertNil(try XCTUnwrap(model.field("card_id")).chosen)
        XCTAssertEqual(model.source(of: "note"), .stated)
        XCTAssertEqual(model.source(of: "arrive_at"), .inferred)
        XCTAssertEqual(model.source(of: "card_id"), .blank)
        // A stated or inferred field is editable: the change reports entered; so does filling a blank.
        XCTAssertTrue(model.setText("note", "changed"))
        XCTAssertEqual(model.source(of: "note"), .entered)
        XCTAssertTrue(model.chooseTime("arrive_at", arrival.addingTimeInterval(1800)))
        XCTAssertEqual(model.source(of: "arrive_at"), .entered)
        XCTAssertTrue(model.chooseOption("card_id", "credit"))
        XCTAssertEqual(model.source(of: "card_id"), .entered)
        // Clearing a typed text leaves the field blank again.
        XCTAssertTrue(model.setText("note", ""))
        XCTAssertEqual(model.source(of: "note"), .blank)
        // A value nil always reads as blank, whatever the seed says; an unknown key reads as blank.
        let odd = make([.field(noteSpec, value: nil, source: .stated)])
        XCTAssertEqual(odd.source(of: "note"), .blank)
        XCTAssertEqual(odd.source(of: "nothing"), .blank)
    }

    // MARK: M03 readiness

    func testM03_ReadyOnlyWhenNoBlankRemainsAndNotAgainWhenATextIsCleared() throws {
        let model = make([.line("Info"), .field(noteSpec, value: nil, source: .blank), .field(pay, value: nil, source: .blank),
                          .field(arriveSpec, value: .time(arrival), source: .stated)])
        XCTAssertEqual(model.card.fields.count, 4, "positive: the card was built")
        XCTAssertFalse(model.isReady)
        XCTAssertTrue(model.chooseOption("card_id", "debit"))
        XCTAssertFalse(model.isReady, "a blank text remains")
        XCTAssertTrue(model.setText("note", "door code 1234"))
        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.isReady, model.card.isReady)
        XCTAssertTrue(model.setText("note", "   "))
        XCTAssertFalse(model.isReady, "a blank text blocks again")
        XCTAssertTrue(model.setText("note", "x"))
        XCTAssertTrue(model.isReady)
    }

    // MARK: M04 chips

    func testM04_ChipsAcceptOnlyListedIdsAndTheOnOffValuesDoNotDependOnTheWords() throws {
        let model = make([.field(pay, value: nil, source: .blank), .field(mealSwitch, value: nil, source: .blank),
                          .field(.onOff(key: "calendar", label: "Calendar", on: "Show", off: "Don't Show"), value: nil, source: .blank),
                          .field(noteSpec, value: .text("t"), source: .stated)])
        XCTAssertNotNil(model.field("card_id"), "positive: the card was built")
        // Only the listed ids are accepted; nothing changes on a refusal.
        XCTAssertFalse(model.chooseOption("card_id", "gold"))
        XCTAssertFalse(model.chooseOption("card_id", "Debit one"))
        XCTAssertFalse(model.chooseOption("card_id", "true"))
        XCTAssertNil(try XCTUnwrap(model.field("card_id")).chosen)
        XCTAssertEqual(model.source(of: "card_id"), .blank)
        XCTAssertTrue(model.chooseOption("card_id", "credit"))
        XCTAssertEqual(try XCTUnwrap(model.field("card_id")).chosen, "credit")
        XCTAssertEqual(model.values.option("card_id"), "credit")
        XCTAssertTrue(model.chooseOption("card_id", "debit"), "a chip can be changed")
        XCTAssertEqual(model.values.option("card_id"), "debit")
        // The on/off ids are true and false whatever the words; the words never count.
        for refused in ["Add", "Don't Add", "yes", "no", "on", "1", ""] { XCTAssertFalse(model.chooseOption("meal", refused), refused) }
        XCTAssertNil(try XCTUnwrap(model.field("meal")).chosen)
        XCTAssertFalse(model.chooseOption("note", "true"), "a text field has no chips")
        XCTAssertFalse(model.chooseOption("nothing", "true"))
        XCTAssertTrue(model.chooseOption("meal", "false"))
        XCTAssertEqual(model.values.flag("meal"), false)
        XCTAssertTrue(model.chooseOption("meal", "true"))
        XCTAssertEqual(model.values.flag("meal"), true)
        XCTAssertTrue(model.chooseOption("calendar", "true"))
        // Two seeds with different word pairs: different chip texts, the same values, and the chosen word in the line.
        XCTAssertEqual(try XCTUnwrap(model.field("meal")).options.map(\.label), ["Add", "Don't Add"])
        XCTAssertEqual(try XCTUnwrap(model.field("calendar")).options.map(\.label), ["Show", "Don't Show"])
        XCTAssertEqual(try XCTUnwrap(model.field("meal")).options.map(\.value), try XCTUnwrap(model.field("calendar")).options.map(\.value))
        XCTAssertTrue(model.lines.contains("Add to schedule: Add"))
        XCTAssertTrue(model.lines.contains("Calendar: Show"))
        XCTAssertTrue(model.chooseOption("calendar", "false"))
        XCTAssertTrue(model.lines.contains("Calendar: Don't Show"))
    }

    // MARK: M05 the switch group

    func testM05_TheSwitchRemovesAndRestoresItsDependentRowsWithTheirLastValues() throws {
        let model = make(deliveryRows(address: .text("9 Library Road"), addressSource: .inferred))
        XCTAssertEqual(keys(model).filter { !$0.allSatisfy(\.isNumber) },
                       ["arrive_at", "address", "card_id", "meal", "meal_title", "meal_start"], "positive: the dependents stand after the switch")
        let arriveID = try XCTUnwrap(model.field("arrive_at")).id
        let switchID = try XCTUnwrap(model.field("meal")).id
        XCTAssertTrue(model.setText("meal_title", "Family dinner"))
        let start = arrival.addingTimeInterval(1800)
        XCTAssertTrue(model.chooseTime("meal_start", start))
        let before = keys(model)

        // Off: the two rows go, the others keep their identity and the switch reports entered.
        XCTAssertTrue(model.chooseOption("meal", "false"))
        XCTAssertNil(model.field("meal_title"))
        XCTAssertNil(model.field("meal_start"))
        XCTAssertEqual(keys(model).count, before.count - 2)
        XCTAssertEqual(try XCTUnwrap(model.field("arrive_at")).id, arriveID)
        XCTAssertEqual(try XCTUnwrap(model.field("meal")).id, switchID)
        XCTAssertEqual(model.source(of: "meal"), .entered)
        XCTAssertFalse(model.lines.contains { $0.hasPrefix("Meal title") })
        XCTAssertTrue(model.lines.contains("Add to schedule: Don't Add"))
        XCTAssertNil(model.values.entry("meal_title"), "a hidden row is not in the snapshot")

        // On: the rows come back after the switch, at the same place, with their last values.
        XCTAssertTrue(model.chooseOption("meal", "true"))
        XCTAssertEqual(keys(model).count, before.count)
        XCTAssertEqual(keys(model).filter { !$0.allSatisfy(\.isNumber) }, ["arrive_at", "address", "card_id", "meal", "meal_title", "meal_start"])
        XCTAssertEqual(keys(model), before)
        XCTAssertEqual(model.values.text("meal_title"), "Family dinner")
        XCTAssertEqual(model.values.date("meal_start"), start)
        XCTAssertEqual(try XCTUnwrap(model.field("meal_start")).chosen, BesirTime.isoFormatter.string(from: start))
        XCTAssertEqual(model.source(of: "meal_title"), .entered)
        XCTAssertEqual(try XCTUnwrap(model.field("arrive_at")).id, arriveID)

        // A blank dependent title blocks only while the switch is on.
        XCTAssertTrue(model.isReady)
        XCTAssertTrue(model.setText("meal_title", ""))
        XCTAssertFalse(model.isReady)
        XCTAssertTrue(model.chooseOption("meal", "false"))
        XCTAssertTrue(model.isReady)
        XCTAssertTrue(model.chooseOption("meal", "true"))
        XCTAssertFalse(model.isReady, "the blank title is back with the switch")
        XCTAssertNil(try XCTUnwrap(model.field("meal_title")).chosen)
        // Choosing the side that is already on changes nothing in the rows.
        XCTAssertTrue(model.chooseOption("meal", "true"))
        XCTAssertEqual(keys(model), before)
    }

    // MARK: M06 text

    func testM06_TypedTextIsCleanedCutAtTheLimitNeverTrimmedAndBlankClears() throws {
        let model = make([.field(noteSpec, value: nil, source: .blank), .field(mealTitle, value: .text(String(repeating: "t", count: 75)), source: .inferred)])
        // Positive: a pre-filled text over its limit is cut to it at build; the card never holds more.
        XCTAssertEqual(model.values.text("meal_title")?.count, 68)
        XCTAssertEqual(try XCTUnwrap(model.field("meal_title")).chosen?.count, 68)
        XCTAssertEqual(model.source(of: "meal_title"), .inferred)

        // Hidden characters go per keystroke.
        XCTAssertTrue(model.setText("meal_title", "a\u{200B}b\tc\nd\u{2028}e"))
        XCTAssertEqual(model.values.text("meal_title"), "abcde")
        // 75 typed against the limit of 68: the model keeps the first 68.
        let typed = String(repeating: "x", count: 75)
        XCTAssertTrue(model.setText("meal_title", typed))
        XCTAssertEqual(model.values.text("meal_title"), String(typed.prefix(68)))
        XCTAssertEqual(try XCTUnwrap(model.field("meal_title")).chosen, String(typed.prefix(68)))
        XCTAssertEqual(model.source(of: "meal_title"), .entered)
        // Nothing is trimmed per keystroke: a space typed after 12 stays, and so does one before.
        XCTAssertTrue(model.setText("note", "12 "))
        XCTAssertEqual(model.values.text("note"), "12 ")
        XCTAssertTrue(model.setText("note", " 12 Example Street"))
        XCTAssertEqual(model.values.text("note"), " 12 Example Street")
        // A text with no limit of its own is cut at the delivery text limit.
        XCTAssertTrue(model.setText("note", String(repeating: "n", count: 130)))
        XCTAssertEqual(model.values.text("note")?.count, AgentDelivery.maxDeliveryText)
        // A blank text clears the value, and only blanks do.
        XCTAssertTrue(model.setText("note", " \t "))
        XCTAssertNil(model.values.text("note"))
        XCTAssertNil(try XCTUnwrap(model.field("note")).chosen)
        XCTAssertEqual(model.source(of: "note"), .blank)
        XCTAssertTrue(model.setText("note", "back"))
        XCTAssertEqual(model.source(of: "note"), .entered)
        // The view passes the whole draft each time, so a text change is also reachable through the actions.
        let noteID = try XCTUnwrap(model.field("note")).id
        model.actions.setTitleText?(noteID, "via actions")
        XCTAssertEqual(model.values.text("note"), "via actions")
        // Only a text field takes text; a refused change is reported.
        XCTAssertFalse(model.setText("nothing", "x"))
    }

    // MARK: M07 the place pick

    func testM07_APlacePickKeepsItsCoordinatesAndTheValueIsTheAddressElseTheName() throws {
        let model = make([.field(addressSpec, value: nil, source: .blank)], favorites: [cafeNorth, cafeSouth, home])
        XCTAssertEqual(try XCTUnwrap(model.field("address")).options.count, 3, "positive: the favorites are on the row")
        XCTAssertTrue(model.choosePlace("address", cafeNorth.place))
        XCTAssertEqual(try XCTUnwrap(model.field("address")).chosen, "10 North Street")
        XCTAssertEqual(model.values.entry("address")?.value, .place(cafeNorth.place))
        XCTAssertEqual(model.values.text("address"), "10 North Street")
        XCTAssertEqual(model.source(of: "address"), .entered)
        // Two favorites with the same label keep their own coordinates.
        XCTAssertTrue(model.choosePlace("address", cafeSouth.place))
        XCTAssertEqual(model.values.entry("address")?.value, .place(cafeSouth.place))
        XCTAssertEqual(try XCTUnwrap(model.field("address")).chosen, "20 South Street")
        // No usable address: the name is the value.
        let nameOnly = place("Corner Bakery", "")
        XCTAssertTrue(model.choosePlace("address", nameOnly))
        XCTAssertEqual(model.values.text("address"), "Corner Bakery")
        XCTAssertEqual(model.values.entry("address")?.value, .place(nameOnly))
        // An address of more than 120 characters is not used; the name is.
        let longAddress = place("Long Hall", String(repeating: "a", count: 121))
        XCTAssertTrue(model.choosePlace("address", longAddress))
        XCTAssertEqual(model.values.text("address"), "Long Hall")
        // Neither fits: the pick is refused and nothing changes.
        let unusable = place(String(repeating: "n", count: 121), String(repeating: "a", count: 121))
        XCTAssertFalse(model.choosePlace("address", unusable))
        XCTAssertEqual(model.values.text("address"), "Long Hall")
        XCTAssertFalse(model.choosePlace("address", place("", "")))
        XCTAssertEqual(model.values.entry("address")?.value, .place(longAddress))
        // A pick clears the row's note, and only a place row takes a place.
        XCTAssertFalse(model.choosePlace("nothing", home.place))
        // The favorite row and the search-result row reach the same pick through the actions.
        let addressID = try XCTUnwrap(model.field("address")).id
        model.actions.choosePlace(addressID, home.place)
        XCTAssertEqual(model.values.entry("address")?.value, .place(home.place))
        model.actions.chooseCandidate?(addressID, cafeNorth.place)
        XCTAssertEqual(model.values.entry("address")?.value, .place(cafeNorth.place))
        // A place seeded as text (the app's own inference) keeps only its text; a place seed keeps its coordinates.
        let seeded = make([.field(addressSpec, value: .text("9 Library Road"), source: .inferred),
                           .field(AgentFieldSpec(key: "to", kind: .place, label: "To"), value: .place(home.place), source: .stated)])
        XCTAssertEqual(seeded.values.entry("address")?.value, .text("9 Library Road"))
        XCTAssertEqual(seeded.values.text("address"), "9 Library Road")
        XCTAssertEqual(try XCTUnwrap(seeded.field("address")).chosen, "9 Library Road")
        XCTAssertEqual(seeded.values.entry("to")?.value, .place(home.place))
        XCTAssertEqual(try XCTUnwrap(seeded.field("to")).chosen, "1 Home Road")
        XCTAssertEqual(seeded.source(of: "address"), .inferred)
    }

    // MARK: M08 the search

    func testM08_FastTypingSearchesOnceAfterTheDebounceWithTheTrimmedQueryAndAtMostFiveResults() async throws {
        let searches = Searches()
        searches.places = (0..<7).map { place("Result \($0)", "\($0) Main Street") }
        let model = make([.field(addressSpec, value: nil, source: .blank)], searches: searches)
        XCTAssertNotNil(model.field("address"), "positive: the card was built")
        for typed in ["t", "ta", "tar", "tart", " tarti "] { model.search("address", typed) }
        XCTAssertTrue(isSearching(model.field("address")?.lookup))
        XCTAssertEqual(searches.queries, [], "nothing is searched before the debounce")
        await settle()
        XCTAssertEqual(searches.queries, ["tarti"])
        XCTAssertEqual(results(model.field("address")?.lookup)?.count, 5)
        XCTAssertEqual(results(model.field("address")?.lookup)?.map(\.name), (0..<5).map { "Result \($0)" })
        // The same query again after a finished search is not searched twice.
        model.search("address", "tarti")
        await settle()
        XCTAssertEqual(searches.queries, ["tarti"])
        // An empty query clears the row and calls nothing.
        model.search("address", "   ")
        XCTAssertTrue(isIdle(model.field("address")?.lookup))
        await settle(0.5)
        XCTAssertEqual(searches.queries, ["tarti"])
        // No result at all gives the empty state.
        searches.places = []
        model.search("address", "zzz")
        await settle()
        XCTAssertEqual(searches.queries, ["tarti", "zzz"])
        XCTAssertTrue(isEmptyLookup(model.field("address")?.lookup))
        // A search needs a place row.
        model.search("nothing", "x")
        await settle(0.5)
        XCTAssertEqual(searches.queries, ["tarti", "zzz"])
        // The view's search reaches the same path through the actions.
        searches.places = [place("Via actions", "1 Action Way")]
        let addressID = try XCTUnwrap(model.field("address")).id
        model.actions.searchPlaces(addressID, "actions")
        await settle()
        XCTAssertEqual(searches.queries.last, "actions")
        XCTAssertEqual(results(model.field("address")?.lookup)?.map(\.name), ["Via actions"])
        // After the freeze no search is armed and the closure is not called.
        model.freeze()
        model.search("address", "after freeze")
        model.actions.searchPlaces(addressID, "after freeze again")
        await settle()
        XCTAssertEqual(searches.queries.last, "actions")
        XCTAssertEqual(searches.queries.count, 3)
    }

    // MARK: M09 the time

    func testM09_ATimeKeepsTheDateAsPickedAndClosingTheDialSeedsThroughDialSeed() throws {
        let model = make([.field(arriveSpec, value: nil, source: .blank), .field(mealStart, value: .time(arrival), source: .inferred)])
        let exact = TestClock.date("2026-10-28T20:15:30").addingTimeInterval(0.25)
        XCTAssertTrue(model.chooseTime("arrive_at", exact))
        XCTAssertEqual(model.values.date("arrive_at"), exact, "the Date is kept as picked, never parsed back from the text")
        XCTAssertEqual(try XCTUnwrap(model.field("arrive_at")).chosen, BesirTime.isoFormatter.string(from: exact))
        XCTAssertEqual(try XCTUnwrap(model.field("arrive_at")).chosenLabel, BesirTime.when(exact))
        XCTAssertEqual(model.source(of: "arrive_at"), .entered)
        XCTAssertTrue(model.lines.contains("Arrival: " + BesirTime.when(exact)))
        XCTAssertFalse(model.chooseTime("note", exact), "only a time row takes a time")

        // Opening a wheel on a row with no value commits the wheel's seed through closeDial: the same seed the wheel shows.
        let blank = make([.field(arriveSpec, value: nil, source: .blank), .field(noteSpec, value: nil, source: .blank)])
        let blankRow = try XCTUnwrap(blank.field("arrive_at"))
        XCTAssertTrue(blank.card.commitsSeedWhenOpened(blankRow), "the view asks the model to commit the seed on opening")
        let wheelSeed = try XCTUnwrap(blank.card.dialSeed(for: blankRow, base: nil, now: now))
        let blankID = blankRow.id
        blank.actions.closeDial?(blankID, nil, now)
        XCTAssertEqual(blank.values.date("arrive_at"), wheelSeed)
        XCTAssertEqual(wheelSeed, EditCard.nextWholeHour(now: now))
        XCTAssertEqual(blank.source(of: "arrive_at"), .entered)
        XCTAssertFalse(blank.card.commitsSeedWhenOpened(try XCTUnwrap(blank.field("arrive_at"))), "a committed row does not commit again")
        // Closing it again changes nothing, and it clears a rejection note only.
        XCTAssertTrue(blank.closeDial("arrive_at", now: now.addingTimeInterval(7200)))
        XCTAssertEqual(blank.values.date("arrive_at"), wheelSeed)
        // The model's own clock is used when no now is given.
        let clocked = make([.field(arriveSpec, value: nil, source: .blank)])
        XCTAssertTrue(clocked.closeDial("arrive_at"))
        XCTAssertEqual(clocked.values.date("arrive_at"), EditCard.nextWholeHour(now: now))
        // A row that is not a time row does not seed.
        XCTAssertFalse(blank.closeDial("note", now: now))
        XCTAssertNil(blank.values.text("note"))
        // The wheel's own commit path (a pick while the wheel is open) is chooseTimePlain.
        let pick = TestClock.date("2026-10-28T21:00")
        XCTAssertEqual(blank.actions.chooseTimePlain(blankID, pick), true)
        XCTAssertEqual(blank.values.date("arrive_at"), pick)
    }

    // MARK: M10 the freeze

    func testM10_AfterTheFreezeEveryChangeASearchResultAndACloseDialChangeNothing() async throws {
        let gate = SearchGate()
        let model = AgentFieldCard(header: "Order delivery", rows: deliveryRows(), favorites: [home],
                                   search: { await gate.run($0) }, now: { [now] in now })
        model.setText("meal_title", "before")
        model.search("address", "tart")
        await settle(0.55)
        XCTAssertEqual(gate.queries, ["tart"], "positive: the search was fired and is waiting")
        XCTAssertTrue(isSearching(model.field("address")?.lookup))
        XCTAssertFalse(model.isFrozen)
        let linesBefore = model.lines
        let valuesBefore = model.values
        let keysBefore = keys(model)
        let ids = model.card.fields.map(\.id)

        model.freeze()
        XCTAssertTrue(model.isFrozen)
        XCTAssertFalse(model.chooseOption("card_id", "credit"))
        XCTAssertFalse(model.chooseOption("meal", "false"))
        XCTAssertFalse(model.choosePlace("address", home.place))
        XCTAssertFalse(model.setText("meal_title", "after"))
        XCTAssertFalse(model.chooseTime("arrive_at", arrival.addingTimeInterval(3600)))
        XCTAssertFalse(model.closeDial("arrive_at", now: now))
        model.search("address", "later")
        let addressID = try XCTUnwrap(model.field("address")).id
        model.actions.chooseValue(try XCTUnwrap(model.field("card_id")).id, "credit")
        model.actions.choosePlace(addressID, home.place)
        model.actions.chooseCandidate?(addressID, home.place)
        model.actions.setTitleText?(try XCTUnwrap(model.field("meal_title")).id, "after")
        XCTAssertEqual(model.actions.chooseTimePlain(try XCTUnwrap(model.field("meal_start")).id, arrival.addingTimeInterval(60)), false)
        model.actions.closeDial?(try XCTUnwrap(model.field("meal_start")).id, nil, now)
        model.actions.searchPlaces(addressID, "later again")
        // The answer of the search that was running arrives late.
        gate.answer([home.place])
        await settle(0.3)
        XCTAssertTrue(isSearching(model.field("address")?.lookup), "a late result is dropped")
        XCTAssertEqual(gate.queries, ["tart"], "no search is started after the freeze")
        XCTAssertEqual(model.lines, linesBefore)
        XCTAssertEqual(model.values, valuesBefore)
        XCTAssertEqual(keys(model), keysBefore)
        XCTAssertEqual(model.card.fields.map(\.id), ids)
        XCTAssertEqual(model.source(of: "meal_title"), .entered)
    }

    // MARK: M11 the snapshot

    func testM11_TheSnapshotHoldsTheTypedValuesAndTheirSourcesBuiltAndDrivenAlone() throws {
        let model = make(deliveryRows(address: nil, addressSource: .blank), favorites: [home])
        let start = arrival.addingTimeInterval(900)
        XCTAssertTrue(model.choosePlace("address", home.place))
        XCTAssertTrue(model.chooseOption("card_id", "credit"))
        XCTAssertTrue(model.chooseTime("meal_start", start))
        XCTAssertTrue(model.setText("meal_title", "Family dinner"))
        let snapshot = model.values
        XCTAssertEqual(snapshot.entries.map(\.key), ["arrive_at", "address", "card_id", "meal", "meal_title", "meal_start"],
                       "the read-only rows are not values")
        XCTAssertEqual(snapshot.entry("arrive_at"), AgentFieldCard.Snapshot.Entry(key: "arrive_at", value: .time(arrival), source: .stated))
        XCTAssertEqual(snapshot.entry("address"), AgentFieldCard.Snapshot.Entry(key: "address", value: .place(home.place), source: .entered))
        XCTAssertEqual(snapshot.entry("card_id"), AgentFieldCard.Snapshot.Entry(key: "card_id", value: .option("credit"), source: .entered))
        XCTAssertEqual(snapshot.entry("meal"), AgentFieldCard.Snapshot.Entry(key: "meal", value: .flag(true), source: .inferred))
        XCTAssertEqual(snapshot.entry("meal_title"), AgentFieldCard.Snapshot.Entry(key: "meal_title", value: .text("Family dinner"), source: .entered))
        XCTAssertEqual(snapshot.entry("meal_start"), AgentFieldCard.Snapshot.Entry(key: "meal_start", value: .time(start), source: .entered))
        XCTAssertEqual(snapshot.text("address"), "1 Home Road")
        XCTAssertEqual(snapshot.option("card_id"), "credit")
        XCTAssertEqual(snapshot.flag("meal"), true)
        XCTAssertEqual(snapshot.date("meal_start"), start)
        XCTAssertNil(snapshot.date("address"))
        XCTAssertNil(snapshot.entry("nothing"))
        // A later change does not reach a snapshot already taken.
        XCTAssertTrue(model.setText("meal_title", "Other"))
        XCTAssertEqual(snapshot.text("meal_title"), "Family dinner")
        XCTAssertEqual(model.values.text("meal_title"), "Other")
        // A blank field is in the snapshot with no value.
        let blank = make(deliveryRows())
        XCTAssertEqual(blank.values.entry("address"), AgentFieldCard.Snapshot.Entry(key: "address", value: nil, source: .blank))
    }

    // MARK: M12 the lines

    func testM12_LinesAreTheHeaderThenOneLinePerRowWithTheChosenWordOfAChipField() throws {
        let model = make(deliveryRows(address: .text("9 Library Road"), addressSource: .inferred, card: nil, cardSource: .blank))
        let when = BesirTime.when(arrival)
        XCTAssertEqual(model.lines, ["Order delivery", "Pasta Palace", "2 x Ramen", "1 x Gyoza", "Estimated total $40.00",
                                     "Arrival: " + when, "Delivery place: 9 Library Road", "Pay with:", "Add to schedule: Add",
                                     "Meal title: Dinner", "Start: " + when, "Example Delivery - Simulated"])
        // A blank value reads as the label and a colon; a chosen chip reads as its word, not its id.
        XCTAssertTrue(model.chooseOption("card_id", "credit"))
        XCTAssertTrue(model.lines.contains("Pay with: Credit two"))
        XCTAssertFalse(model.lines.contains("Pay with:"))
        // The meal switch off: the word of the off chip, and the two dependent lines are gone.
        XCTAssertTrue(model.chooseOption("meal", "false"))
        XCTAssertEqual(model.lines, ["Order delivery", "Pasta Palace", "2 x Ramen", "1 x Gyoza", "Estimated total $40.00",
                                     "Arrival: " + when, "Delivery place: 9 Library Road", "Pay with: Credit two",
                                     "Add to schedule: Don't Add", "Example Delivery - Simulated"])
        // The header alone for a card with no rows.
        XCTAssertEqual(make([], header: "Only").lines, ["Only"])
    }

    // MARK: M13 no marks, no captions

    func testM13_TheCardShowsNoNoteAndNoMarkForAnySource() throws {
        let model = make(deliveryRows(address: .text("9 Library Road"), addressSource: .inferred))
        // Precondition: the AC-CHOICECARD-013 card has more than 10 lines and the three partner fields.
        XCTAssertGreaterThan(model.lines.count, 10)
        XCTAssertEqual(model.lines.count, 12)
        XCTAssertNotNil(model.field("arrive_at"))
        XCTAssertNotNil(model.field("address"))
        XCTAssertNotNil(model.field("card_id"))
        for field in model.card.fields { XCTAssertNil(field.note, field.key) }
        for line in model.lines { XCTAssertFalse(line.lowercased().contains("suggested"), line) }
        // The sources are recorded, not drawn: the three kinds exist in the snapshot and in no line.
        XCTAssertEqual(model.source(of: "arrive_at"), .stated)
        XCTAssertEqual(model.source(of: "address"), .inferred)
        XCTAssertEqual(model.source(of: "meal"), .inferred)
        for word in ["stated", "inferred", "blank", "entered"] { XCTAssertFalse(model.lines.joined().lowercased().contains(word), word) }
        // Still true after the user changes values and after a search.
        model.chooseOption("card_id", "credit")
        model.setText("meal_title", "x")
        for field in model.card.fields { XCTAssertNil(field.note, field.key) }
    }

    // MARK: M14-M17 the number kind, optional fields and a number row under a switch (SPEC-BOOKCARD-001 REQ-010)

    private var sizeSpec: AgentFieldSpec { AgentFieldSpec(key: "party_size", kind: .number, label: "Party size") }
    private var nameSpec: AgentFieldSpec { AgentFieldSpec(key: "name", kind: .text, label: "Name") }
    private var optionalNote: AgentFieldSpec { AgentFieldSpec(key: "note", kind: .text, label: "Note", isOptional: true) }
    /// The row besir writes itself for the length of a schedule entry: at most 3 digits, a valid range of 5 to 720.
    private var lengthSpec: AgentFieldSpec { AgentFieldSpec(key: "schedule-length", kind: .number, label: "Length (min)", limit: 3, range: 5...720) }

    func testM14_ANumberFieldKeepsOnlyAsciiDigitsCutAtTheLimitWithoutLeadingZerosAndHonoursItsRange() throws {
        let model = make([.field(sizeSpec, value: nil, source: .blank), .field(lengthSpec, value: .number(60), source: .inferred)])
        XCTAssertEqual(model.card.fields.map(\.kind), [.title, .title], "positive: a number row is the typed row of a text field")
        XCTAssertEqual(model.values.int("schedule-length"), 60, "positive: a seed that fits its limit is kept")
        XCTAssertEqual(try XCTUnwrap(model.field("schedule-length")).chosen, "60")
        XCTAssertNil(model.values.int("party_size"))
        XCTAssertEqual(model.source(of: "party_size"), .blank)

        // Only ASCII digits stay; the value is a whole number and the source is entered.
        XCTAssertTrue(model.setText("party_size", "4a 2-"))
        XCTAssertEqual(model.values.int("party_size"), 42)
        XCTAssertEqual(model.values.entry("party_size")?.value, .number(42))
        XCTAssertEqual(try XCTUnwrap(model.field("party_size")).chosen, "42")
        XCTAssertEqual(model.source(of: "party_size"), .entered)
        XCTAssertNil(model.values.text("party_size"))
        // Digits of other scripts and full-width digits are not ASCII digits.
        XCTAssertTrue(model.setText("party_size", "\u{0663}\u{FF14}"))
        XCTAssertNil(model.values.int("party_size"))
        XCTAssertNil(try XCTUnwrap(model.field("party_size")).chosen)
        // Cut at 9 digits without a limit of its own.
        XCTAssertTrue(model.setText("party_size", "1234567890123"))
        XCTAssertEqual(model.values.int("party_size"), 123_456_789)
        XCTAssertEqual(try XCTUnwrap(model.field("party_size")).chosen, "123456789")
        // Leading zeros are dropped, and `000` reads 0.
        XCTAssertTrue(model.setText("party_size", "007"))
        XCTAssertEqual(model.values.int("party_size"), 7)
        XCTAssertEqual(try XCTUnwrap(model.field("party_size")).chosen, "7")
        XCTAssertTrue(model.setText("party_size", "000"))
        XCTAssertEqual(model.values.int("party_size"), 0)
        XCTAssertEqual(try XCTUnwrap(model.field("party_size")).chosen, "0")
        // Empty, or nothing but other characters, is blank and clears the value.
        for blank in ["", "abc", " "] {
            XCTAssertTrue(model.setText("party_size", "5"))
            XCTAssertTrue(model.setText("party_size", blank))
            XCTAssertNil(model.values.int("party_size"), blank)
            XCTAssertNil(try XCTUnwrap(model.field("party_size")).chosen, blank)
            XCTAssertEqual(model.source(of: "party_size"), .blank, blank)
        }
        // The limit of the seed cuts a number row: 3 for the length row.
        XCTAssertTrue(model.setText("schedule-length", "12345"))
        XCTAssertEqual(model.values.int("schedule-length"), 123)
        // A number row takes no chip, and a text row still takes text.
        XCTAssertFalse(model.chooseOption("party_size", "true"))
        XCTAssertFalse(model.setText("nothing", "1"))

        // The range of 5 to 720 decides readiness and nothing else: 4 and 721 are shown as typed and block the card.
        XCTAssertTrue(model.setText("party_size", "2"))
        for (typed, ready) in [("4", false), ("5", true), ("720", true), ("721", false), ("60", true), ("0", false)] {
            XCTAssertTrue(model.setText("schedule-length", typed))
            XCTAssertEqual(model.values.int("schedule-length"), Int(typed), typed)
            XCTAssertEqual(try XCTUnwrap(model.field("schedule-length")).chosen, typed, typed)
            XCTAssertEqual(model.isReady, ready, typed)
        }
        // A seed made from a partner's field has no range, and a number of any size is ready.
        let fromPartner = try XCTUnwrap(AgentFieldSpec(PartnerField(key: "count", kind: .number, label: "Count", options: [])))
        XCTAssertEqual(fromPartner.kind, .number)
        XCTAssertNil(fromPartner.range)
        XCTAssertNil(fromPartner.limit)
        let partnerModel = make([.field(fromPartner, value: nil, source: .blank)])
        XCTAssertFalse(partnerModel.isReady)
        XCTAssertTrue(partnerModel.setText("count", "999999999"))
        XCTAssertTrue(partnerModel.isReady)
        XCTAssertTrue(partnerModel.setText("count", "0"))
        XCTAssertTrue(partnerModel.isReady)
        // A seed value that does not fit its limit reads as blank.
        let tooLong = make([.field(lengthSpec, value: .number(1234), source: .inferred), .field(sizeSpec, value: .number(-3), source: .inferred)])
        XCTAssertNil(tooLong.values.int("schedule-length"))
        XCTAssertNil(tooLong.values.int("party_size"))
        XCTAssertEqual(tooLong.source(of: "schedule-length"), .blank)
    }

    func testM15_AnOptionalBlankFieldDoesNotBlockAndARequiredBlankStillDoes() throws {
        let model = make([.field(nameSpec, value: .text("Sam"), source: .stated), .field(optionalNote, value: nil, source: .blank)])
        XCTAssertEqual(model.card.fields.count, 2, "positive: the card was built")
        XCTAssertTrue(model.isReady, "an optional blank leaves the card ready")
        XCTAssertNil(model.values.text("note"))
        XCTAssertNil(model.values.entry("note")?.value, "the snapshot holds no value for a blank optional field")
        XCTAssertEqual(model.values.entry("note")?.source, .blank)
        XCTAssertNil(try XCTUnwrap(model.field("note")).chosen)
        // Typing in the optional field and clearing it keeps the card ready.
        XCTAssertTrue(model.setText("note", "door code"))
        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.values.text("note"), "door code")
        XCTAssertTrue(model.setText("note", ""))
        XCTAssertTrue(model.isReady)
        XCTAssertNil(model.values.entry("note")?.value)
        XCTAssertTrue(model.setText("note", "   "))
        XCTAssertTrue(model.isReady)

        // A required blank, or a text of spaces only, blocks whatever the optional field holds.
        let blankName = make([.field(nameSpec, value: nil, source: .blank), .field(optionalNote, value: .text("kept"), source: .stated)])
        XCTAssertEqual(blankName.values.text("note"), "kept")
        XCTAssertFalse(blankName.isReady)
        XCTAssertTrue(blankName.setText("name", "   "))
        XCTAssertFalse(blankName.isReady)
        XCTAssertTrue(blankName.setText("name", "Sam"))
        XCTAssertTrue(blankName.isReady)
        XCTAssertTrue(blankName.setText("name", ""))
        XCTAssertFalse(blankName.isReady)

        // The same holds for an optional number and an optional place: blank is ready; a value out of range is not.
        let optionalSize = AgentFieldSpec(key: "extra", kind: .number, label: "Extra", isOptional: true)
        let optionalPlace = AgentFieldSpec(key: "where_to", kind: .place, label: "Where", isOptional: true)
        let many = make([.field(nameSpec, value: .text("Sam"), source: .stated), .field(optionalSize, value: nil, source: .blank),
                         .field(optionalPlace, value: nil, source: .blank)])
        XCTAssertTrue(many.isReady)
        XCTAssertTrue(many.setText("extra", "12"))
        XCTAssertTrue(many.isReady)
        XCTAssertTrue(many.setText("extra", ""))
        XCTAssertTrue(many.isReady)
        let optionalRanged = AgentFieldSpec(key: "pct", kind: .number, label: "Percent", isOptional: true, range: 1...100)
        let ranged = make([.field(optionalRanged, value: nil, source: .blank)])
        XCTAssertTrue(ranged.isReady)
        XCTAssertTrue(ranged.setText("pct", "101"))
        XCTAssertFalse(ranged.isReady, "a value that lies outside its range is not chosen, optional or not")
        XCTAssertTrue(ranged.setText("pct", ""))
        XCTAssertTrue(ranged.isReady)
    }

    func testM16_AFieldSeedFromAPartnerFieldCarriesItsOptionalityAndTheLinesHoldNoWordForIt() throws {
        let optional = try XCTUnwrap(AgentFieldSpec(PartnerField(key: "note", kind: .text, label: "Note", options: [], isOptional: true)))
        XCTAssertTrue(optional.isOptional)
        XCTAssertEqual(optional.kind, .text)
        let mandatory = try XCTUnwrap(AgentFieldSpec(PartnerField(key: "name", kind: .text, label: "Name", options: [])))
        XCTAssertFalse(mandatory.isOptional)
        let number = try XCTUnwrap(AgentFieldSpec(PartnerField(key: "party_size", kind: .number, label: "Party size", options: [], isOptional: true)))
        XCTAssertEqual(number.kind, .number)
        XCTAssertTrue(number.isOptional)
        XCTAssertFalse(sizeSpec.isOptional)
        XCTAssertNil(sizeSpec.range)

        // An optional blank is drawn as every blank row is, and nothing says optional or required.
        let model = make([.field(try XCTUnwrap(AgentFieldSpec(PartnerField(key: "party_size", kind: .number, label: "Party size", options: []))),
                                 value: nil, source: .blank), .field(optional, value: nil, source: .blank)])
        XCTAssertEqual(model.lines, ["Order delivery", "Party size:", "Note:"])
        XCTAssertTrue(model.setText("party_size", "4"))
        XCTAssertEqual(model.lines, ["Order delivery", "Party size: 4", "Note:"])
        for line in model.lines {
            XCTAssertFalse(line.lowercased().contains("optional"), line)
            XCTAssertFalse(line.lowercased().contains("required"), line)
        }
        for field in model.card.fields { XCTAssertNil(field.note, field.key) }
        XCTAssertEqual(model.values.int("party_size"), 4)
        XCTAssertNil(model.values.entry("note")?.value)
        XCTAssertTrue(model.isReady)

        // An optional blank does not hide a required blank behind it, whichever comes first.
        let hidden = make([.field(optional, value: nil, source: .blank), .field(mandatory, value: nil, source: .blank)])
        XCTAssertFalse(hidden.isReady)
        XCTAssertTrue(hidden.setText("note", "x"))
        XCTAssertFalse(hidden.isReady)
        XCTAssertTrue(hidden.setText("name", "Sam"))
        XCTAssertTrue(hidden.isReady)
    }

    func testM17_ANumberRowUnderASwitchIsReadyOnlyWhileTheSwitchIsOnAndRemembersItsValueEvenWhenInvalid() throws {
        func rows(_ length: AgentFieldValue? = .number(60)) -> [AgentFieldRow] {
            [.field(nameSpec, value: .text("Sam"), source: .stated),
             .switchField(mealSwitch, value: .flag(true), source: .inferred, dependents: [.field(lengthSpec, value: length, source: length == nil ? .blank : .inferred)])]
        }
        let model = make(rows())
        XCTAssertEqual(keys(model), ["name", "meal", "schedule-length"], "positive: the row stands after its switch")
        XCTAssertEqual(model.values.int("schedule-length"), 60)
        XCTAssertEqual(model.source(of: "schedule-length"), .inferred)
        XCTAssertTrue(model.isReady, "built with 60 while the switch is on")

        // Blank or 721 makes the card not ready while the switch is on; turning the switch off removes the row.
        XCTAssertTrue(model.setText("schedule-length", ""))
        XCTAssertFalse(model.isReady)
        XCTAssertTrue(model.chooseOption("meal", "false"))
        XCTAssertNil(model.field("schedule-length"))
        XCTAssertNil(model.values.entry("schedule-length"), "no entry for a row that is off the card")
        XCTAssertTrue(model.isReady, "the blank row is off the card")
        XCTAssertTrue(model.chooseOption("meal", "true"))
        XCTAssertFalse(model.isReady, "the blank row is back with its switch")
        XCTAssertNil(try XCTUnwrap(model.field("schedule-length")).chosen)
        XCTAssertTrue(model.setText("schedule-length", "721"))
        XCTAssertFalse(model.isReady)
        XCTAssertTrue(model.chooseOption("meal", "false"))
        XCTAssertTrue(model.isReady, "an invalid row is off the card")
        XCTAssertNil(model.values.entry("schedule-length"))

        // Typing 90, turning the switch off and on again restores 90, not 60.
        let typed = make(rows())
        XCTAssertTrue(typed.setText("schedule-length", "90"))
        XCTAssertTrue(typed.chooseOption("meal", "false"))
        XCTAssertTrue(typed.chooseOption("meal", "true"))
        XCTAssertEqual(typed.values.int("schedule-length"), 90)
        XCTAssertEqual(try XCTUnwrap(typed.field("schedule-length")).chosen, "90")
        XCTAssertEqual(typed.source(of: "schedule-length"), .entered)
        XCTAssertTrue(typed.isReady)

        // An invalid value is restored as typed and the card is not ready until it is corrected.
        for invalid in ["721", "4", ""] {
            let run = make(rows())
            XCTAssertTrue(run.setText("schedule-length", invalid))
            XCTAssertTrue(run.chooseOption("meal", "false"))
            XCTAssertTrue(run.chooseOption("meal", "true"))
            XCTAssertEqual(run.values.int("schedule-length"), Int(invalid), invalid)
            XCTAssertEqual(try XCTUnwrap(run.field("schedule-length")).chosen, invalid.isEmpty ? nil : invalid, invalid)
            XCTAssertFalse(run.isReady, invalid)
            XCTAssertTrue(run.setText("schedule-length", "720"))
            XCTAssertTrue(run.isReady, invalid)
        }

        // After the freeze the row changes nothing.
        typed.freeze()
        XCTAssertFalse(typed.setText("schedule-length", "30"))
        XCTAssertFalse(typed.chooseOption("meal", "false"))
        XCTAssertEqual(typed.values.int("schedule-length"), 90)
        XCTAssertNotNil(typed.field("schedule-length"))
    }

    // MARK: M18 the rows besir added itself leave a card that ended without an answer

    func testM18_RemovingTheOwnRowsDropsEachSwitchWithItsDependentsAndKeepsEveryPartnerRow() throws {
        let length = AgentFieldSpec(key: "len", kind: .number, label: "Length (min)", limit: 3, range: 5...720)
        let signed = AgentFieldSpec.onOff(key: "signed", label: "Signature", on: "Needed", off: "Not needed")
        let model = make([.field(noteSpec, value: .text("Keep dry"), source: .stated),
                          .field(signed, value: .flag(false), source: .stated),
                          .field(pay, value: .option("debit"), source: .stated),
                          .switchField(mealSwitch, value: .flag(true), source: .inferred, dependents: [
                              .field(mealTitle, value: .text("Dinner"), source: .inferred),
                              .field(length, value: .number(60), source: .inferred)]),
                          .line("Example Delivery - Simulated")])
        // Before: every row is on the card, the app's own rows included.
        XCTAssertEqual(keys(model), ["note", "signed", "card_id", "meal", "meal_title", "len", "0"])
        let before = model.lines
        XCTAssertTrue(before.contains("Add to schedule: Add"), "\(before)")
        XCTAssertTrue(before.contains("Length (min): 60"), "\(before)")

        model.removeOwnRows()
        // After: the switch and its dependents are gone, the partner's own on_off, chip, text and the read-only row stay.
        XCTAssertEqual(keys(model), ["note", "signed", "card_id", "0"])
        XCTAssertEqual(model.lines, ["Order delivery", "Note: Keep dry", "Signature: Not needed", "Pay with: Debit one",
                                     "Example Delivery - Simulated"])
        XCTAssertNil(model.field("meal"))
        XCTAssertNil(model.field("meal_title"))
        XCTAssertNil(model.field("len"))
        XCTAssertNotNil(model.field("signed"))

        // A switch that was turned off already had no dependents on the card; the same rows leave, and calling twice changes nothing.
        let off = make([.field(noteSpec, value: .text("x"), source: .stated),
                        .switchField(mealSwitch, value: .flag(false), source: .entered, dependents: [
                            .field(mealTitle, value: .text("Dinner"), source: .inferred)])])
        XCTAssertEqual(keys(off), ["note", "meal"])
        off.removeOwnRows()
        off.removeOwnRows()
        XCTAssertEqual(keys(off), ["note"])
    }
}

/// A search that answers when the test says so: the closure waits for `answer`.
@MainActor
private final class SearchGate {
    var queries: [String] = []
    private var waiting: CheckedContinuation<[Place], Never>?

    func run(_ query: String) async -> [Place] {
        queries.append(query)
        return await withCheckedContinuation { waiting = $0 }
    }

    func answer(_ places: [Place]) {
        waiting?.resume(returning: places)
        waiting = nil
    }
}
