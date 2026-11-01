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
}
