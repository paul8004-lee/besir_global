import XCTest
@testable import besir

/// SPEC-CHOICECARD-001 AC-CHOICECARD-005 and AC-CHOICECARD-006 for the partner-neutral readers of `PartnerForm`: the field list
/// and the result list, parsed from JSON text as the wire gives them (a boolean is a boolean, a number is a number).
final class PartnerFormTests: XCTestCase {
    // MARK: Helpers

    /// The value as the wire would deliver it: serialized and parsed back.
    private func wire(_ value: Any) -> Any? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// The value as JSON text gives it: parsed once and never re-serialized, so a number written `2.0` reaches the reader as written.
    private func wireText(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private func fields(_ value: Any) -> [PartnerField]? { PartnerForm.fields(from: wire(value)) }

    private func results(_ value: Any) -> [PartnerResultItem]? { PartnerForm.results(from: wire(value)) }

    private func option(_ id: String, _ label: String) -> [String: Any] { ["id": id, "label": label] }

    private func field(_ key: String, _ kind: String, _ label: String, options: [[String: Any]]? = nil, optional: Any? = nil) -> [String: Any] {
        var object: [String: Any] = ["key": key, "kind": kind, "label": label]
        if let options { object["options"] = options }
        if let optional { object["optional"] = optional }
        return object
    }

    /// A group entry of the field list, its `repeat` the partner's maximum number of rows.
    private func group(_ key: String, _ label: String, members: [[String: Any]], repeat maximum: Int) -> [String: Any] {
        ["key": key, "kind": "group", "label": label, "fields": members, "repeat": maximum]
    }

    private func resultFields(_ value: Any) -> [PartnerResultSpec]? { PartnerForm.resultFields(from: wire(value)) }

    private func spec(_ name: String, _ kind: String) -> [String: Any] { ["name": name, "kind": kind] }

    private var cardOptions: [[String: Any]] {
        [option("debit-4242", "Example Debit \u{2022}\u{2022}4242 (Simulated)"), option("credit-1881", "Example Credit \u{2022}\u{2022}1881 (Simulated)")]
    }

    /// The delivery partner's three fields.
    private var deliveryList: [[String: Any]] {
        [field("arrive_at", "time", "Arrival"), field("address", "place", "Delivery place"),
         field("card_id", "pick_one", "Pay with", options: cardOptions)]
    }

    private var onOffOptions: [[String: Any]] { [option("true", "Add"), option("false", "Don't Add")] }

    private func item(_ name: String, _ kind: String, _ value: Any) -> [String: Any] { ["name": name, "kind": kind, "value": value] }

    private var threeItems: [[String: Any]] {
        [item("Arrival", "time", "2026-11-02T19:40"), item("Estimated total", "money", 4000), item("Status", "text", "Preparing")]
    }

    private func assertUnusable(_ cases: [(String, Any)], file: StaticString = #filePath, line: UInt = #line,
                                reader: (Any) -> Bool) {
        for (name, value) in cases { XCTAssertFalse(reader(value), name, file: file, line: line) }
    }

    // MARK: W01-W02 the field list

    func testW01_AFieldListOfAllFiveKindsDecodesInOrderWithItsOptions() throws {
        let list: [[String: Any]] = [
            field("note", "text", "Note"), field("where_to", "place", "Where"), field("when_at", "time", "When"),
            field("size", "pick_one", "Size", options: [option("small", "Small"), option("large_2", "Large")]),
            field("door", "on_off", "Leave at door", options: onOffOptions)]
        let decoded = try XCTUnwrap(fields(list))
        XCTAssertEqual(decoded.map(\.key), ["note", "where_to", "when_at", "size", "door"])
        XCTAssertEqual(decoded.map(\.kind), [.text, .place, .time, .pickOne, .onOff])
        XCTAssertEqual(decoded.map(\.label), ["Note", "Where", "When", "Size", "Leave at door"])
        XCTAssertEqual(decoded[0].options, [])
        XCTAssertEqual(decoded[3].options, [PartnerOption(id: "small", label: "Small"), PartnerOption(id: "large_2", label: "Large")])
        // The two chips of an on/off field are the field's own words, with the ids true then false.
        XCTAssertEqual(decoded[4].options, [PartnerOption(id: "true", label: "Add"), PartnerOption(id: "false", label: "Don't Add")])
        // Other words give other chips with the same ids.
        let show = try XCTUnwrap(fields([field("cal", "on_off", "Calendar", options: [option("true", "Show"), option("false", "Don't Show")])]))
        XCTAssertEqual(show[0].options.map(\.label), ["Show", "Don't Show"])
        XCTAssertEqual(show[0].options.map(\.id), ["true", "false"])
        // The edges: one field, eight fields, four options, a 60-character option label, a 40-character label, a 32-character key.
        XCTAssertEqual(fields([field("a", "text", "A")])?.count, 1)
        XCTAssertEqual(fields((1...8).map { field(String(repeating: "k", count: $0), "text", "L") })?.count, 8)
        let wide = fields([field(String(repeating: "a", count: 32), "pick_one", String(repeating: "L", count: 40),
                                 options: (0..<4).map { option(String(repeating: "i", count: 32 - $0), String(repeating: "O", count: 60)) })])
        XCTAssertEqual(wide?.first?.options.count, 4)
        XCTAssertEqual(wide?.first?.label.count, 40)
    }

    func testW02_ADefectInTheFieldListMakesTheWholeListUnusable() throws {
        // Positive first: the delivery list decodes to three fields with the card options (a nil skeleton cannot satisfy this).
        let good = try XCTUnwrap(fields(deliveryList))
        XCTAssertEqual(good.map(\.key), ["arrive_at", "address", "card_id"])
        XCTAssertEqual(good.map(\.kind), [.time, .place, .pickOne])
        XCTAssertEqual(good.map(\.label), ["Arrival", "Delivery place", "Pay with"])
        XCTAssertEqual(good[2].options.map(\.id), ["debit-4242", "credit-1881"])
        XCTAssertEqual(good[2].options.map(\.label), cardOptions.map { $0["label"] as? String ?? "" })

        let hidden: [(String, String)] = [("tab", "A\tB"), ("newline", "A\nB"), ("zero-width space", "A\u{200B}B"), ("line separator", "A\u{2028}B"),
                                          ("paragraph separator", "A\u{2029}B"), ("right-to-left mark", "A\u{200F}B")]
        var cases: [(String, Any)] = [
            ("not an array", ["key": "a", "kind": "text", "label": "A"]), ("a string", "a"), ("null", NSNull()), ("zero fields", [Any]()),
            ("nine fields", (0..<9).map { field(String(repeating: "a", count: $0 + 1), "text", "L") }),
            ("an element that is not an object", ["a"]),
            ("unknown kind", [field("a", "integer", "A")]), ("kind in upper case", [field("a", "Text", "A")]),
            ("kind with a dash", [field("a", "pick-one", "A", options: [option("x", "X")])]), ("kind not a string", [["key": "a", "kind": 1, "label": "A"]]),
            ("duplicate key", [field("a", "text", "A"), field("a", "place", "B")]),
            ("key of 33 characters", [field(String(repeating: "a", count: 33), "text", "A")]),
            ("key with an upper-case letter", [field("Arrive", "text", "A")]), ("empty key", [field("", "text", "A")]),
            ("key with a digit", [field("a1", "text", "A")]), ("key with a dash", [field("a-b", "text", "A")]),
            ("key not a string", [["key": 5, "kind": "text", "label": "A"]]),
            ("empty label", [field("a", "text", "")]), ("label of 41 characters", [field("a", "text", String(repeating: "L", count: 41))]),
            ("label not a string", [["key": "a", "kind": "text", "label": 5]]),
            ("missing key", [["kind": "text", "label": "A"]]), ("missing kind", [["key": "a", "label": "A"]]), ("missing label", [["key": "a", "kind": "text"]]),
            ("extra key in a field", [["key": "a", "kind": "text", "label": "A", "hint": "x"]]),
            ("options on a text field", [field("a", "text", "A", options: [option("x", "X")])]),
            ("options on a place field", [field("a", "place", "A", options: [option("x", "X")])]),
            ("options on a time field", [field("a", "time", "A", options: [option("x", "X")])]),
            ("empty options on a text field", [field("a", "text", "A", options: [])]),
            ("pick_one with no options key", [field("a", "pick_one", "A")]),
            ("pick_one with 0 options", [field("a", "pick_one", "A", options: [])]),
            ("duplicate option ids", [field("a", "pick_one", "A", options: [option("x", "X"), option("x", "Y")])]),
            ("empty option id", [field("a", "pick_one", "A", options: [option("", "X")])]),
            ("option id of 33 characters", [field("a", "pick_one", "A", options: [option(String(repeating: "i", count: 33), "X")])]),
            ("option id with an upper-case letter", [field("a", "pick_one", "A", options: [option("Debit", "X")])]),
            ("option id with a space", [field("a", "pick_one", "A", options: [option("a b", "X")])]),
            ("option id not a string", [field("a", "pick_one", "A", options: [["id": 1, "label": "X"]])]),
            ("empty option label", [field("a", "pick_one", "A", options: [option("x", "")])]),
            ("option label of 61 characters", [field("a", "pick_one", "A", options: [option("x", String(repeating: "L", count: 61))])]),
            ("option label not a string", [field("a", "pick_one", "A", options: [["id": "x", "label": 7]])]),
            ("extra key in an option", [field("a", "pick_one", "A", options: [["id": "x", "label": "X", "price": 1]])]),
            ("option without a label", [field("a", "pick_one", "A", options: [["id": "x"]])]),
            ("option without an id", [field("a", "pick_one", "A", options: [["label": "X"]])]),
            ("options not an array", [["key": "a", "kind": "pick_one", "label": "A", "options": "x"]]),
            ("option not an object", [["key": "a", "kind": "pick_one", "label": "A", "options": ["x"]]]),
            ("on_off with no options", [field("a", "on_off", "A")]),
            ("on_off with empty options", [field("a", "on_off", "A", options: [])]),
            ("on_off with one option", [field("a", "on_off", "A", options: [option("true", "Add")])]),
            ("on_off with three options", [field("a", "on_off", "A", options: [option("true", "Add"), option("false", "Skip"), option("maybe", "Maybe")])]),
            ("on_off ids swapped", [field("a", "on_off", "A", options: [option("false", "Add"), option("true", "Skip")])]),
            ("on_off ids renamed", [field("a", "on_off", "A", options: [option("on", "Add"), option("off", "Skip")])]),
            ("on_off ids repeated", [field("a", "on_off", "A", options: [option("true", "Add"), option("true", "Skip")])]),
            ("on_off ids false twice", [field("a", "on_off", "A", options: [option("false", "Add"), option("false", "Skip")])]),
            ("on_off ids in upper case", [field("a", "on_off", "A", options: [option("True", "Add"), option("False", "Skip")])]),
            ("on_off with equal labels", [field("a", "on_off", "A", options: [option("true", "Add"), option("false", "Add")])]),
            ("on_off with an empty label", [field("a", "on_off", "A", options: [option("true", ""), option("false", "Skip")])]),
            ("on_off with an over-long label", [field("a", "on_off", "A", options: [option("true", "Add"), option("false", String(repeating: "L", count: 61))])]),
            ("on_off with an extra key in an option", [field("a", "on_off", "A", options: [["id": "true", "label": "Add", "x": 1], option("false", "Skip")])]),
            ("on_off ids as booleans", [field("a", "on_off", "A", options: [["id": true, "label": "Add"], ["id": false, "label": "Skip"]])]),
        ]
        for (name, text) in hidden {
            cases.append(("label with a \(name)", [field("a", "text", text)]))
            cases.append(("option label with a \(name)", [field("a", "pick_one", "A", options: [option("x", text)])]))
            cases.append(("on_off label with a \(name)", [field("a", "on_off", "A", options: [option("true", text), option("false", "Skip")])]))
        }
        assertUnusable(cases) { fields($0) != nil }
        // Positive counterpart: the same shapes without the defect are accepted.
        XCTAssertNotNil(fields([field("a", "on_off", "A", options: [option("true", "Add"), option("false", "Skip")])]))
        XCTAssertNotNil(fields([field("a", "pick_one", "A", options: [option("x", "Wide \u{2022} dot")])]))
    }

    // MARK: G-W1 no cap on the options of a pick_one (SPEC-GROUPFIELD-001)

    func testGROUP_GW1_APickOneDecodesWithEveryOptionCountInOrderAndEachDefectIsRefused() throws {
        // 1, 4, 6, 40 and 500 options decode, each option in the partner's order.
        for count in [1, 4, 6, 40, 500] {
            let list = [field("size", "pick_one", "Size", options: (0..<count).map { option("o\($0)", "O\($0)") })]
            let decoded = try XCTUnwrap(fields(list), "\(count) options")
            XCTAssertEqual(decoded[0].options.map(\.id), (0..<count).map { "o\($0)" }, "\(count) options")
            XCTAssertEqual(decoded[0].options.map(\.label), (0..<count).map { "O\($0)" }, "\(count) options")
        }
        // The defects stay refused: no option at all, a repeated id, an over-long id or label, three chips on an on/off field.
        let cases: [(String, Any)] = [
            ("pick_one with 0 options", [field("a", "pick_one", "A", options: [])]),
            ("pick_one with a repeated id", [field("a", "pick_one", "A", options: [option("x", "X"), option("x", "Y")])]),
            ("pick_one with an id of 33 characters", [field("a", "pick_one", "A", options: [option(String(repeating: "i", count: 33), "X")])]),
            ("pick_one with a label of 61 characters", [field("a", "pick_one", "A", options: [option("x", String(repeating: "L", count: 61))])]),
            ("on_off with three options", [field("a", "on_off", "A", options: [option("true", "Add"), option("false", "Skip"), option("maybe", "Maybe")])]),
        ]
        for (name, list) in cases { XCTAssertNil(fields(list), name) }
    }

    // MARK: G-W2 to G-W3 the group entry in the field list (SPEC-GROUPFIELD-001)

    func testGROUP_GW2_AGroupEntryDecodesWithItsMembersAndEveryAcceptedEdge() throws {
        let menu: [[String: Any]] = [
            option("ramen", "Ramen"), option("gyoza", "Gyoza"), option("curry", "Curry rice"),
            option("pizza", "Cheese pizza"), option("salad", "Garden salad"), option("lemonade", "Lemonade")]
        let members: [[String: Any]] = [field("item", "pick_one", "Item", options: menu), field("quantity", "number", "Quantity")]
        // The design example: a scalar, the group `items` with its two members, an optional text, in that order.
        let decoded = try XCTUnwrap(fields([field("when_at", "time", "When"), group("items", "Items", members: members, repeat: 6),
                                            field("note", "text", "Note", optional: true)]))
        XCTAssertEqual(decoded.map(\.key), ["when_at", "items", "note"])
        XCTAssertEqual(decoded.map(\.kind), [.time, .group, .text])
        let items = decoded[1]
        XCTAssertEqual(items.label, "Items")
        XCTAssertEqual(items.maxRows, 6)
        XCTAssertEqual(items.members.map(\.key), ["item", "quantity"])
        XCTAssertEqual(items.members.map(\.kind), [.pickOne, .number])
        XCTAssertEqual(items.members[0].options.map(\.id), ["ramen", "gyoza", "curry", "pizza", "salad", "lemonade"])
        XCTAssertEqual(items.members[0].options.map(\.label), ["Ramen", "Gyoza", "Curry rice", "Cheese pizza", "Garden salad", "Lemonade"])
        XCTAssertEqual(items.members.map(\.isOptional), [false, false])

        // The maximum is the partner's: `repeat` 1, 2, 6, 1000000 and 999999999999 all decode with that maximum.
        for maximum in [1, 2, 6, 1_000_000, 999_999_999_999] {
            let one = try XCTUnwrap(fields([group("items", "Items", members: members, repeat: maximum)]), "repeat \(maximum)")
            XCTAssertEqual(one[0].maxRows, maximum, "repeat \(maximum)")
        }
        // `2.0` and the 10^12 boundary are built from JSON text so the numbers reach the reader as written (the `wire` round
        // trip would rewrite `2.0` as `2`): `2.0` is 2, and the whole-number reader's own limit refuses 10^12.
        let membersText = #"{"key":"item","kind":"pick_one","label":"Item","options":[{"id":"ramen","label":"Ramen"},{"id":"gyoza","label":"Gyoza"},{"id":"curry","label":"Curry rice"},{"id":"pizza","label":"Cheese pizza"},{"id":"salad","label":"Garden salad"},{"id":"lemonade","label":"Lemonade"}]},{"key":"quantity","kind":"number","label":"Quantity"}"#
        func listText(_ repeatText: String, repeatFirst: Bool = false) -> String {
            let groupBody = repeatFirst
                ? "\"repeat\":\(repeatText),\"fields\":[\(membersText)]"
                : "\"fields\":[\(membersText)],\"repeat\":\(repeatText)"
            return "[{\"key\":\"when_at\",\"kind\":\"time\",\"label\":\"When\"}"
                + ",{\"key\":\"items\",\"kind\":\"group\",\"label\":\"Items\"," + groupBody + "}"
                + ",{\"key\":\"note\",\"kind\":\"text\",\"label\":\"Note\",\"optional\":true}]"
        }
        let two = try XCTUnwrap(PartnerForm.fields(from: wireText(listText("2.0"))))
        XCTAssertEqual(two.map(\.kind), [.time, .group, .text])
        XCTAssertEqual(two[1].maxRows, 2)
        XCTAssertNil(PartnerForm.fields(from: wireText(listText("1000000000000"))))
        // `repeat` is a key of the parsed dictionary, never a position: written before `fields` it decodes alike.
        let reordered = try XCTUnwrap(PartnerForm.fields(from: wireText(listText("6", repeatFirst: true))))
        XCTAssertEqual(reordered[1].maxRows, 6)

        // One member and twenty members decode.
        let single = try XCTUnwrap(fields([group("items", "Items", members: [field("item", "pick_one", "Item", options: menu)], repeat: 3)]))
        XCTAssertEqual(single[0].members.count, 1)
        let twentyKeys = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t"]
        let twenty = try XCTUnwrap(fields([group("items", "Items", members: twentyKeys.map { field($0, "text", $0.capitalized) }, repeat: 3)]))
        XCTAssertEqual(twenty[0].members.count, 20)

        // The group is one of the eight entries; its members are not counted.
        let seven = (0..<7).map { field(String(repeating: "a", count: $0 + 1), "text", "L") }
        let eighth = try XCTUnwrap(fields(seven + [group("items", "Items", members: members, repeat: 2)]))
        XCTAssertEqual(eighth.count, 8)
        XCTAssertEqual(eighth[7].kind, .group)

        // A group label of 40 characters, the label rule of any field.
        let wide = try XCTUnwrap(fields([group("items", String(repeating: "L", count: 40), members: members, repeat: 2)]))
        XCTAssertEqual(wide[0].label.count, 40)

        // A member with `optional: true` beside a required one decodes.
        let mixed = try XCTUnwrap(fields([group("items", "Items", members: [field("item", "pick_one", "Item", options: menu),
                                                                            field("note", "text", "Note", optional: true)], repeat: 2)]))
        XCTAssertEqual(mixed[0].members.map(\.isOptional), [false, true])
    }

    func testGROUP_GW3_ADefectInTheGroupEntryMakesTheWholeListUnusable() throws {
        let menu: [[String: Any]] = [
            option("ramen", "Ramen"), option("gyoza", "Gyoza"), option("curry", "Curry rice"),
            option("pizza", "Cheese pizza"), option("salad", "Garden salad"), option("lemonade", "Lemonade")]
        let members: [[String: Any]] = [field("item", "pick_one", "Item", options: menu), field("quantity", "number", "Quantity")]
        // Positive first: the G-W2 list decodes (a reader that refuses a group cannot satisfy this).
        let good = try XCTUnwrap(fields([field("when_at", "time", "When"), group("items", "Items", members: members, repeat: 6),
                                         field("note", "text", "Note", optional: true)]))
        XCTAssertEqual(good.map(\.kind), [.time, .group, .text])

        // One group entry carrying the defect of the case, inside the same list as the positive.
        func entry(key: String = "items", label: String = "Items", extra: [String: Any]? = nil, members memberList: Any? = nil,
                   omitFields: Bool = false, repeat maximum: Any? = 6) -> [String: Any] {
            var object: [String: Any] = ["key": key, "kind": "group", "label": label]
            if !omitFields { object["fields"] = memberList ?? members }
            if let maximum { object["repeat"] = maximum }
            if let extra { object.merge(extra) { _, new in new } }
            return object
        }
        func list(_ entry: [String: Any]) -> [[String: Any]] {
            [field("when_at", "time", "When"), entry, field("note", "text", "Note", optional: true)]
        }
        var lookupMember = field("note", "text", "Note")
        lookupMember["lookup"] = true
        let cases: [(String, Any)] = [
            ("repeat 0", list(entry(repeat: 0))),
            ("repeat -1", list(entry(repeat: -1))),
            ("repeat false", list(entry(repeat: false))),
            ("repeat true", list(entry(repeat: true))),
            ("repeat as the text 3", list(entry(repeat: "3"))),
            ("repeat 2.5", list(entry(repeat: 2.5))),
            ("repeat null", list(entry(repeat: NSNull()))),
            ("repeat 1000000000000", list(entry(repeat: 1_000_000_000_000))),
            ("repeat missing", list(entry(repeat: nil))),
            ("fields missing", list(entry(omitFields: true))),
            ("fields not an array", list(entry(members: "x"))),
            ("fields empty", list(entry(members: [Any]()))),
            ("an optional key on the group", list(entry(extra: ["optional": true]))),
            ("a lookup key on the group", list(entry(extra: ["lookup": true]))),
            ("an extra key on the group", list(entry(extra: ["hint": "x"]))),
            ("a member of kind place", list(entry(members: [field("place_at", "place", "Where")]))),
            ("a member of kind time", list(entry(members: [field("when_at", "time", "When")]))),
            ("a member of kind on_off", list(entry(members: [field("door", "on_off", "Door",
                                                                   options: [option("true", "Add"), option("false", "Don't Add")])]))),
            ("a member of kind group", list(entry(members: [group("inner", "Inner", members: [field("item", "pick_one", "Item", options: menu)],
                                                                                              repeat: 2)]))),
            ("a member of an unknown kind", list(entry(members: [field("size", "integer", "Size")]))),
            ("a member with lookup", list(entry(members: [lookupMember]))),
            ("a member key equal to the group key", list(entry(members: [field("items", "text", "Row")]))),
            ("a member key equal to another entry's key", list(entry(members: [field("note", "text", "Row")]))),
            ("a member key equal to a second group's member key",
             [entry(key: "first", members: [field("item", "text", "Row")]), entry(key: "second", members: [field("item", "text", "Row")])]),
            ("a member key equal to another member's key of the same group",
             list(entry(members: [field("item", "text", "Row"), field("item", "number", "Row again")]))),
            ("a member key with a digit", list(entry(members: [field("item2", "text", "Row")]))),
            ("every member optional", list(entry(members: [field("item", "pick_one", "Item", options: menu, optional: true),
                                                            field("quantity", "number", "Quantity", optional: true)]))),
            ("a member that is not an object", list(entry(members: ["x"]))),
            ("an empty group label", list(entry(label: ""))),
            ("a group label of 41 characters", list(entry(label: String(repeating: "L", count: 41)))),
            ("an invalid group key", list(entry(key: "Items"))),
            ("a ninth entry", (0..<8).map { field(String(repeating: "a", count: $0 + 1), "text", "L") } + [entry()]),
        ]
        for (name, value) in cases { XCTAssertNil(fields(value), name) }
    }

    // MARK: W05-W07 the number kind and the optional marker

    func testW05_ANumberFieldAndAnOptionalFieldDecodeWithTheirKindsAndTheOthersAreRequired() throws {
        let list: [[String: Any]] = [
            field("restaurant", "text", "Restaurant"), field("party_size", "number", "Party size"), field("start", "time", "Time"),
            field("name", "text", "Name"), field("note", "text", "Note", optional: true)]
        let decoded = try XCTUnwrap(fields(list))
        XCTAssertEqual(decoded.map(\.key), ["restaurant", "party_size", "start", "name", "note"])
        XCTAssertEqual(decoded.map(\.kind), [.text, .number, .time, .text, .text])
        XCTAssertEqual(decoded.map(\.isOptional), [false, false, false, false, true])
        XCTAssertEqual(decoded[1].options, [])
        // The partner's order is kept whatever the kinds.
        let reversed = try XCTUnwrap(fields(Array(list.reversed())))
        XCTAssertEqual(reversed.map(\.key), ["note", "name", "start", "party_size", "restaurant"])

        // The key order `key, kind, label, options, optional` decodes for a pick_one.
        let chips = [option("small", "Small"), option("large_2", "Large")]
        let pick = try XCTUnwrap(fields([field("size", "pick_one", "Size", options: chips, optional: true)]))
        XCTAssertEqual(pick[0].kind, .pickOne)
        XCTAssertEqual(pick[0].options, [PartnerOption(id: "small", label: "Small"), PartnerOption(id: "large_2", label: "Large")])
        XCTAssertTrue(pick[0].isOptional)
        XCTAssertFalse(try XCTUnwrap(fields([field("size", "pick_one", "Size", options: chips)]))[0].isOptional)

        // Optional is accepted on every kind but on_off.
        for kind in ["text", "place", "time", "number"] {
            let one = try XCTUnwrap(fields([field("a", kind, "A", optional: true)]), kind)
            XCTAssertTrue(one[0].isOptional, kind)
        }
        // A field built without the marker is required.
        XCTAssertFalse(PartnerField(key: "a", kind: .text, label: "A", options: []).isOptional)
    }

    func testW06_AnOptionalMarkerThatIsNotTheBooleanTrueOrIsOnTheWrongKindMakesTheWholeListUnusable() throws {
        // Positive first: the valid list decodes (a reader that refuses a trailing optional cannot satisfy this).
        let valid: [[String: Any]] = [field("party_size", "number", "Party size"), field("note", "text", "Note", optional: true)]
        let good = try XCTUnwrap(fields(valid))
        XCTAssertEqual(good.map(\.isOptional), [false, true])

        let chips = [option("small", "Small")]
        let cases: [(String, Any)] = [
            ("optional false", [field("note", "text", "Note", optional: false)]),
            ("optional as the text true", [field("note", "text", "Note", optional: "true")]),
            ("optional as the number 1", [field("note", "text", "Note", optional: 1)]),
            ("optional as the number 0", [field("note", "text", "Note", optional: 0)]),
            ("optional as null", [field("note", "text", "Note", optional: NSNull())]),
            ("optional as a list", [field("note", "text", "Note", optional: [true])]),
            ("optional on an on_off field", [field("door", "on_off", "Door", options: onOffOptions, optional: true)]),
            ("a number field with options", [field("size", "number", "Size", options: chips)]),
            ("a number field with empty options", [field("size", "number", "Size", options: [])]),
            ("a number field with options and optional", [field("size", "number", "Size", options: chips, optional: true)]),
            ("a fifth key on a pick_one field", [["key": "a", "kind": "pick_one", "label": "A", "options": chips, "optional": true, "hint": "x"]]),
            ("a fourth key beside optional on a text field", [["key": "a", "kind": "text", "label": "A", "optional": true, "hint": "x"]]),
            ("a fifth key on a text field", [["key": "a", "kind": "text", "label": "A", "optional": true, "hint": "x", "more": 1]]),
            ("one bad optional among good fields", [field("a", "text", "A"), field("b", "text", "B", optional: false), field("c", "text", "C")]),
        ]
        assertUnusable(cases) { fields($0) != nil }

        // `optional` is a key of the parsed dictionary, never a position: the same keys in another order decode alike.
        let text = #"[{"optional":true,"label":"Note","kind":"text","key":"note"},{"label":"Size","options":[{"id":"small","label":"Small"}],"optional":true,"kind":"pick_one","key":"size"}]"#
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let reordered = try XCTUnwrap(PartnerForm.fields(from: parsed))
        XCTAssertEqual(reordered.map(\.key), ["note", "size"])
        XCTAssertEqual(reordered.map(\.isOptional), [true, true])
        XCTAssertEqual(reordered[1].options, [PartnerOption(id: "small", label: "Small")])
    }

    func testPLACE_W09_ALookupMarkerOnAPlaceFieldDecodesAndEveryOtherMarkerMakesTheWholeListUnusable() throws {
        func marked(_ key: String, _ kind: String, _ marker: Any, optional: Any? = nil) -> [String: Any] {
            var object = field(key, kind, key.capitalized, optional: optional)
            object["lookup"] = marker
            return object
        }
        // Positive first: a marked place field decodes with the flag, an unmarked one without it, and the list reads as before.
        let valid: [[String: Any]] = [marked("restaurant", "place", true), field("note", "text", "Note", optional: true), field("where_to", "place", "Where")]
        let good = try XCTUnwrap(fields(valid))
        XCTAssertEqual(good.map(\.canLookUp), [true, false, false])
        XCTAssertEqual(good.map(\.isOptional), [false, true, false])
        XCTAssertFalse(PartnerField(key: "a", kind: .place, label: "A", options: []).canLookUp)
        XCTAssertEqual(try XCTUnwrap(fields(deliveryList)).map(\.canLookUp), [false, false, false])

        let chips = [option("small", "Small")]
        let cases: [(String, Any)] = [
            ("lookup false", [marked("a", "place", false)]),
            ("lookup as the text true", [marked("a", "place", "true")]),
            ("lookup as the number 1", [marked("a", "place", 1)]),
            ("lookup as null", [marked("a", "place", NSNull())]),
            ("lookup as a list", [marked("a", "place", [true])]),
            ("lookup on a text field", [marked("a", "text", true)]),
            ("lookup on an on_off field", [marked("a", "on_off", true).merging(["options": onOffOptions]) { $1 }]),
            ("lookup on a number field", [marked("a", "number", true)]),
            ("lookup on a time field", [marked("a", "time", true)]),
            ("lookup on a pick_one field", [marked("a", "pick_one", true).merging(["options": chips]) { $1 }]),
            ("lookup beside optional", [marked("a", "place", true, optional: true)]),
            ("a fifth key beside lookup", [["key": "a", "kind": "place", "label": "A", "lookup": true, "hint": "x"]]),
            ("one bad lookup among good fields", [field("a", "text", "A"), marked("b", "place", false), field("c", "text", "C")]),
        ]
        assertUnusable(cases) { fields($0) != nil }

        // `lookup` is a key of the parsed dictionary, never a position, and beside `optional` in either key order it is refused.
        let text = #"[{"lookup":true,"label":"Restaurant","kind":"place","key":"restaurant"}]"#
        let reordered = try XCTUnwrap(PartnerForm.fields(from: try JSONSerialization.jsonObject(with: Data(text.utf8))))
        XCTAssertEqual(reordered.map(\.canLookUp), [true])
        for both in [#"[{"lookup":true,"optional":true,"label":"A","kind":"place","key":"a"}]"#,
                     #"[{"optional":true,"lookup":true,"label":"A","kind":"place","key":"a"}]"#] {
            XCTAssertNil(PartnerForm.fields(from: try JSONSerialization.jsonObject(with: Data(both.utf8))), both)
        }
    }

    func testW07_TheNumberKindIsAKindOfItsOwnWithThreeKeysAndAnUnknownWordIsStillRefused() throws {
        XCTAssertEqual(PartnerFieldKind(rawValue: "number"), .number)
        XCTAssertFalse(PartnerFieldKind.number.hasOptions)
        let decoded = try XCTUnwrap(fields([field("party_size", "number", "Party size")]))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].kind, .number)
        XCTAssertEqual(decoded[0].label, "Party size")
        XCTAssertEqual(decoded[0].options, [])
        XCTAssertFalse(decoded[0].isOptional)
        // The kind sits among others, in any position.
        let mixed = try XCTUnwrap(fields([field("a", "number", "A"), field("b", "time", "B"), field("c", "number", "C")]))
        XCTAssertEqual(mixed.map(\.kind), [.number, .time, .number])
        // Another word for a number is not a kind.
        let cases: [(String, Any)] = [
            ("integer", [field("a", "integer", "A")]), ("int", [field("a", "int", "A")]), ("Number in upper case", [field("a", "Number", "A")]),
            ("float", [field("a", "float", "A")]), ("decimal", [field("a", "decimal", "A")]),
        ]
        assertUnusable(cases) { fields($0) != nil }
    }

    // MARK: W08 the result-field list

    func testW08_TheResultFieldListDecodesWithKindsAndEachDefectIsRefused() throws {
        let booking: [[String: Any]] = [spec("Booking time", "time"), spec("Reservation number", "text"), spec("Estimated cost", "money"),
                                        spec("Partner note", "text")]
        let decoded = try XCTUnwrap(resultFields(booking))
        XCTAssertEqual(decoded, [PartnerResultSpec(name: "Booking time", kind: .time), PartnerResultSpec(name: "Reservation number", kind: .text),
                                 PartnerResultSpec(name: "Estimated cost", kind: .money), PartnerResultSpec(name: "Partner note", kind: .text)])
        XCTAssertEqual(decoded.map(\.kind), [.time, .text, .money, .text])

        // The edges: one item, eight items, a 40-character name, the printable ASCII range.
        XCTAssertEqual(resultFields([spec("A", "text")])?.count, 1)
        XCTAssertEqual(resultFields((0..<8).map { spec("N\($0)", "text") })?.count, 8)
        XCTAssertEqual(resultFields([spec(String(repeating: "N", count: 40), "money")])?.first?.name.count, 40)
        XCTAssertEqual(resultFields([spec("Price (est.) #1: ok~", "text")])?.first?.name, "Price (est.) #1: ok~")
        XCTAssertNotNil(resultFields([spec("A", "time")]))
        XCTAssertNotNil(resultFields([spec("A", "money")]))

        let cases: [(String, Any)] = [
            ("not an array", spec("A", "text")), ("null", NSNull()), ("a string", "A"), ("zero items", [Any]()),
            ("nine items", (0..<9).map { spec("N\($0)", "text") }), ("an item that is not an object", ["A"]),
            ("a second time item", [spec("A", "time"), spec("B", "text"), spec("C", "time")]),
            ("a second money item", [spec("A", "money"), spec("B", "money")]),
            ("an unknown kind", [spec("A", "link")]), ("a kind in upper case", [spec("A", "Text")]), ("a kind not a string", [["name": "A", "kind": 1]]),
            ("a name of 41 characters", [spec(String(repeating: "N", count: 41), "text")]), ("an empty name", [spec("", "text")]),
            ("a name with a non-ASCII character", [spec("Caf\u{00E9}", "text")]), ("a name with a newline", [spec("A\nB", "text")]),
            ("a name with a tab", [spec("A\tB", "text")]), ("a name not a string", [["name": 5, "kind": "text"]]),
            ("an extra key", [["name": "A", "kind": "text", "unit": "usd"]]),
            ("a value key", [["name": "A", "kind": "text", "value": "x"]]),
            ("a missing name", [["kind": "text"]]), ("a missing kind", [["name": "A"]]),
            ("one bad item among good ones", [spec("A", "text"), spec("B", "link"), spec("C", "text")]),
        ]
        assertUnusable(cases) { resultFields($0) != nil }
    }

    // MARK: W03-W04 the result list

    func testW03_AValidResultListDecodesAndEachItemDefectIsRefused() throws {
        let decoded = try XCTUnwrap(results(threeItems))
        XCTAssertEqual(decoded, [PartnerResultItem(name: "Arrival", value: .time("2026-11-02T19:40")),
                                 PartnerResultItem(name: "Estimated total", value: .money(4000)),
                                 PartnerResultItem(name: "Status", value: .text("Preparing"))])
        XCTAssertEqual(decoded.map(\.kind), [.time, .money, .text])
        XCTAssertEqual(decoded.moneyCents, 4000)
        XCTAssertEqual(decoded.arrival, "2026-11-02T19:40")

        func single(_ item: [String: Any]) -> Any { [item] }
        let hidden = ["A\tB", "A\nB", "A\u{200B}B", "A\u{2028}B", "A\u{2029}B", "A\u{202E}B"]
        var cases: [(String, Any)] = [
            ("not an array", item("A", "text", "x")), ("null", NSNull()), ("zero items", [Any]()),
            ("nine items", (0..<9).map { item("N\($0)", "text", "x") }), ("an item that is not an object", ["x"]),
            ("money as a boolean", single(item("T", "money", true))), ("money as text", single(item("T", "money", "4000"))),
            ("money 4000.5", single(item("T", "money", 4000.5))), ("money 0", single(item("T", "money", 0))),
            ("money -5", single(item("T", "money", -5))), ("money 1000001", single(item("T", "money", 1000001))),
            ("money null", single(item("T", "money", NSNull()))),
            ("time 25:00", single(item("T", "time", "2026-11-02T25:00"))), ("time minute 60", single(item("T", "time", "2026-11-02T19:60"))),
            ("time on a day that does not exist", single(item("T", "time", "2026-02-31T10:00"))),
            ("time in month 13", single(item("T", "time", "2026-13-02T10:00"))), ("time on day 0", single(item("T", "time", "2026-11-00T10:00"))),
            ("time in year 1999", single(item("T", "time", "1999-11-02T10:00"))), ("time in year 2200", single(item("T", "time", "2200-11-02T10:00"))),
            ("time with a space", single(item("T", "time", "2026-11-02 19:40"))), ("time with seconds", single(item("T", "time", "2026-11-02T19:40:00"))),
            ("time as a number", single(item("T", "time", 1940))), ("time in words", single(item("T", "time", "tomorrow"))),
            ("text of 81 characters", single(item("T", "text", String(repeating: "x", count: 81)))),
            ("empty text", single(item("T", "text", ""))), ("text as a number", single(item("T", "text", 5))),
            ("name of 41 characters", single(item(String(repeating: "N", count: 41), "text", "x"))),
            ("empty name", single(item("", "text", "x"))), ("name with a non-ASCII character", single(item("Caf\u{00E9}", "text", "x"))),
            ("name with a newline", single(item("A\nB", "text", "x"))), ("name not a string", single(["name": 5, "kind": "text", "value": "x"])),
            ("unknown kind", single(item("T", "link", "x"))), ("kind in upper case", single(item("T", "Text", "x"))),
            ("kind not a string", single(["name": "T", "kind": 1, "value": "x"])),
            ("extra key in an item", single(["name": "T", "kind": "text", "value": "x", "unit": "usd"])),
            ("missing name", single(["kind": "text", "value": "x"])), ("missing kind", single(["name": "T", "value": "x"])),
            ("missing value", single(["name": "T", "kind": "text"])),
        ]
        for text in hidden { cases.append(("text with a hidden character \(text.unicodeScalars.map(\.value))", single(item("T", "text", text)))) }
        assertUnusable(cases) { results($0) != nil }
        // Positive counterparts: the edges are accepted. 2.0 counts as 2 and 4000.0 as 4000.
        XCTAssertEqual(results(single(item("T", "money", 1)))?.moneyCents, 1)
        XCTAssertEqual(results(single(item("T", "money", 1000000)))?.moneyCents, 1000000)
        XCTAssertEqual(results(single(item("T", "money", 4000.0)))?.moneyCents, 4000)
        XCTAssertNotNil(results(single(item(String(repeating: "N", count: 40), "text", String(repeating: "x", count: 80)))))
        XCTAssertNotNil(results(single(item("T", "time", "2000-01-01T00:00"))))
        XCTAssertNotNil(results(single(item("T", "time", "2199-12-31T23:59"))))
        XCTAssertNotNil(results(single(item("T", "time", "2028-02-29T10:00"))))
        XCTAssertNil(results(single(item("T", "time", "2027-02-29T10:00"))))
        XCTAssertEqual(results((0..<8).map { item("N\($0)", "text", "x") })?.count, 8)
        XCTAssertNotNil(results(single(item("Price (est.) #1: ok~", "text", "caf\u{00E9} \u{2022} done"))))
    }

    func testW04_AtMostOneTimeAndOneMoneyItemAndAnyNumberOfTextItems() throws {
        let four = try XCTUnwrap(results(threeItems + [item("Courier", "text", "Sam")]))
        XCTAssertEqual(four.count, 4)
        XCTAssertEqual(four.map(\.kind), [.time, .money, .text, .text])
        let texts = try XCTUnwrap(results((0..<8).map { item("Note \($0)", "text", "x") }))
        XCTAssertEqual(texts.count, 8)
        XCTAssertNil(texts.moneyCents)
        XCTAssertNil(texts.arrival)
        // A list with only one acting kind, or none of them, is still a list: the delivery adapter asks for both.
        XCTAssertNotNil(results([item("Arrival", "time", "2026-11-02T19:40")]))
        XCTAssertNotNil(results([item("Estimated total", "money", 4000)]))
        // A second item of an acting kind makes the list unusable.
        XCTAssertNil(results(threeItems + [item("Tip", "money", 300)]))
        XCTAssertNil(results(threeItems + [item("Ready", "time", "2026-11-02T19:50")]))
        XCTAssertNil(results([item("A", "money", 1), item("B", "money", 1)]))
        XCTAssertNil(results([item("A", "time", "2026-11-02T19:40"), item("B", "time", "2026-11-02T19:40")]))
        XCTAssertNil(results([item("A", "money", 1), item("B", "text", "x"), item("C", "money", 2)]))
    }
}
