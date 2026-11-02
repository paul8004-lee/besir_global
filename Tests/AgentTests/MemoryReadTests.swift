import XCTest
@testable import besir

/// Finding F-133 (card t74): the memory line reader splits a line by code point, as the writer cleans it, so every line the
/// writer makes is read back.
final class MemoryReadTests: XCTestCase {
    /// A place or a value may begin with a combining mark (U+0301) or an emoji modifier (U+1F3FB), or end with a Prepend
    /// character (U+0D4E); each joins the next or previous space of the ` | ` separator into one Character. The writer keeps
    /// all three, so the reader must find the separator and the `=` of a field by code point.
    func testF133_EveryWrittenLineIsReadBack() throws {
        // (name, place, fields, a code point the stored line must keep)
        let cases: [(String, String?, [(String, String)], Unicode.Scalar)] = [
            // Controls: these read back at the base as well.
            ("plain place", "Example Cafe", [("mode", "car")], "C"),
            ("place ending in U+0D4E, no field after it", "Cafe\u{D4E}", [], "\u{D4E}"),
            ("value ending in U+0D4E, last field", "Example Cafe", [("mode", "car\u{D4E}")], "\u{D4E}"),
            // The finding: the separator or the `=` sits inside one Character.
            ("place beginning with U+0301", "\u{301}Cafe", [("mode", "car")], "\u{301}"),
            ("place beginning with U+1F3FB", "\u{1F3FB}Cafe", [("mode", "car")], "\u{1F3FB}"),
            ("place ending in U+0D4E before a field", "Cafe\u{D4E}", [("mode", "car")], "\u{D4E}"),
            ("value beginning with U+0301", "Example Cafe", [("mode", "\u{301}car")], "\u{301}"),
            ("value beginning with U+1F3FB", nil, [("partner", "\u{1F3FB}Tables")], "\u{1F3FB}"),
            ("value ending in U+0D4E before a field", "Example Cafe", [("mode", "car\u{D4E}"), ("x", "a")], "\u{D4E}"),
        ]
        for (name, place, fields, kept) in cases {
            let line = try XCTUnwrap(MemoryLine.make(kind: "activity", at: TestClock.now, zone: TestClock.zone,
                                                     place: place, fields: fields), name)
            XCTAssertTrue(line.text.unicodeScalars.contains(kept), "the writer dropped the code point: \(name)")
            XCTAssertEqual(MemoryLine(text: line.text), line, "not read back: \(name)")
        }
    }
}
