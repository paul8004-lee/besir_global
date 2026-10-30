import XCTest
@testable import besir

/// SPEC-BOOKCARD-001 AC-011: a value that the model passes for a field is kept only when its quote is the user's own words and
/// the value is read back from the quote. The check is pure, so every test calls it alone on the fixed clock (Tuesday,
/// 2026-10-27 09:00 in the fixed zone).
final class AgentPrefillTests: XCTestCase {
    private let now = TestClock.now

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TestClock.zone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private let fields: [PartnerField] = [
        PartnerField(key: "name", kind: .text, label: "Name", options: []),
        PartnerField(key: "where_to", kind: .place, label: "Where", options: []),
        PartnerField(key: "size", kind: .number, label: "Size", options: []),
        PartnerField(key: "start", kind: .time, label: "Time", options: []),
        PartnerField(key: "side", kind: .pickOne, label: "Side", options: [PartnerOption(id: "small", label: "Small")]),
        PartnerField(key: "door", kind: .onOff, label: "Door",
                     options: [PartnerOption(id: "true", label: "Open"), PartnerOption(id: "false", label: "Shut")]),
    ]

    // MARK: Helpers

    private func entry(_ key: String, _ value: String, _ quote: String?) -> [String: Any] {
        var object: [String: Any] = ["key": key, "value": value]
        if let quote { object["quote"] = quote }
        return object
    }

    private func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func fill(_ entries: [Any], lines: [String]) -> [String: AgentFieldValue] {
        fillText(json(entries), lines: lines)
    }

    private func fillText(_ text: String?, lines: [String]) -> [String: AgentFieldValue] {
        AgentPrefill.values(fieldsText: text, fields: fields, userLines: lines, now: now, calendar: calendar)
    }

    /// What the check keeps for one `start` entry whose quote is the only line the user wrote.
    private func kept(time value: String, quote: String) -> AgentFieldValue? {
        fill([entry("start", value, quote)], lines: [quote])["start"]
    }

    // MARK: R01 text and place: the three cases of the lead

    func testR01_ATextOrPlaceValueIsKeptOnlyWhenItsQuoteIsInAUserLineAndTheValueIsInTheQuote() {
        let lines = ["I am Sam Lee and I want a seat at Pasta Palace", "a second line"]
        // The quote is in a user line: the value is kept.
        XCTAssertEqual(fill([entry("name", "Sam Lee", "I am Sam Lee")], lines: lines), ["name": .text("Sam Lee")])
        XCTAssertEqual(fill([entry("where_to", "Pasta Palace", "a seat at Pasta Palace")], lines: lines),
                       ["where_to": .text("Pasta Palace")], "a place field is kept as text")
        XCTAssertEqual(fill([entry("name", "Sam Lee", "I am Sam Lee"), entry("where_to", "Pasta Palace", "at Pasta Palace")], lines: lines).count, 2)
        // No quote at all: nothing is kept.
        XCTAssertEqual(fill([["key": "name", "value": "Sam Lee"]], lines: lines), [:])
        // A quote that is in no user line: nothing is kept.
        XCTAssertEqual(fill([entry("name", "Sam Lee", "My name is Sam Lee")], lines: lines), [:])
        // The quote is matched as written: case and spaces count, and two lines are not stitched.
        XCTAssertEqual(fill([entry("name", "Sam Lee", "i am sam lee")], lines: lines), [:])
        XCTAssertEqual(fill([entry("name", "Sam Lee", "I am  Sam Lee")], lines: lines), [:])
        XCTAssertEqual(fill([entry("name", "Sam Lee", "Pasta Palace a second line")], lines: lines), [:])
        // The value has to be inside its quote.
        XCTAssertEqual(fill([entry("name", "Sam Lee", "I am Sam")], lines: lines), [:])
        XCTAssertEqual(fill([entry("name", "Sam", "I am Sam Lee")], lines: lines), ["name": .text("Sam")], "a part of the quote is inside it")
        XCTAssertEqual(fill([entry("where_to", "Cafe Nero", "at Pasta Palace")], lines: lines), [:])
        // No user line, no value.
        XCTAssertEqual(fill([entry("name", "Sam Lee", "I am Sam Lee")], lines: []), [:])
        // The quote is trimmed and the value is cleaned the way typing is cleaned.
        XCTAssertEqual(fill([entry("name", "Sam Lee", "  I am Sam Lee  ")], lines: lines), ["name": .text("Sam Lee")])
        XCTAssertEqual(fill([entry("name", "Sam\u{200B} Lee", "I am Sam Lee")], lines: lines), ["name": .text("Sam Lee")])
        // A value is cut at 120 characters.
        let long = String(repeating: "x", count: 130)
        XCTAssertEqual(fill([entry("name", long, long)], lines: ["start " + long])["name"], .text(String(repeating: "x", count: 120)))
        // A blank value keeps nothing.
        XCTAssertEqual(fill([entry("name", "  ", "I am Sam Lee")], lines: lines), [:])
    }

    // MARK: R02 numbers

    func testR02_ANumberValueIsDigitsAndEqualsADigitRunOrAWordOfTheQuote() {
        let lines = ["table for 2", "Book a table for two for Friday", "we are twelve", "call 1234567890", "someone is coming", "Table for TWO",
                     "party of 2 please", "about thirteen of us"]
        func number(_ value: String, _ quote: String) -> AgentFieldValue? { fill([entry("size", value, quote)], lines: lines)["size"] }
        // A digit run of the quote.
        XCTAssertEqual(number("2", "table for 2"), .number(2))
        XCTAssertEqual(number("2", "party of 2"), .number(2))
        // The quote may name the number by a word; the value is the digits.
        XCTAssertEqual(number("2", "Book a table for two"), .number(2))
        XCTAssertEqual(number("2", "Table for TWO"), .number(2), "any case")
        XCTAssertEqual(number("12", "we are twelve"), .number(12))
        // The value is digits and only digits: a word is not a value, whatever the quote.
        XCTAssertNil(number("two", "Book a table for two"))
        XCTAssertNil(number("two", "table for 2"))
        // A value the quote does not name is dropped.
        XCTAssertNil(number("4", "party of 2"))
        XCTAssertNil(number("3", "Book a table for two"))
        XCTAssertNil(number("13", "about thirteen of us"), "words above twelve are not read")
        XCTAssertNil(number("13", "we are twelve"))
        XCTAssertNil(number("1", "someone is coming"), "a word inside a word is not a number")
        // Ten digits, a negative number and a decimal are not values.
        XCTAssertNil(number("1234567890", "call 1234567890"))
        XCTAssertNil(number("-2", "table for 2"))
        XCTAssertNil(number("2.5", "table for 2"))
        XCTAssertNil(number("2 ", "table for 2"))
        XCTAssertNil(number("", "table for 2"))
        XCTAssertNil(number("\u{0662}", "table for 2"), "an Arabic-Indic digit is not an ASCII digit")
        // The quote has to be a user line too.
        XCTAssertNil(number("2", "for 2 people"))
        // Nine digits are a value when the quote has them.
        XCTAssertEqual(fill([entry("size", "123456789", "id 123456789")], lines: ["id 123456789"])["size"], .number(123_456_789))
    }

    // MARK: R03 times

    func testR03_ATimeValueIsKeptOnlyWhenTheQuoteWritesItsClockTimeAndItsDate() {
        func at(_ local: String) -> AgentFieldValue { .time(TestClock.date(local)) }
        // Both halves in the quote, both equal to the value.
        let keptCases: [(String, String)] = [
            ("7 PM tomorrow", "2026-10-28T19:00"), ("19:00 on 2026-10-28", "2026-10-28T19:00"),
            ("7:30 pm on Nov 2nd", "2026-11-02T19:30"), ("noon on Friday", "2026-10-30T12:00"),
            ("tonight at 8 PM", "2026-10-27T20:00"), ("today at 5 pm", "2026-10-27T17:00"),
            ("9 AM today", "2026-10-27T09:00"), ("Tuesday at 6pm", "2026-10-27T18:00"),
            ("TOMORROW at 7 PM", "2026-10-28T19:00"), ("November 2, 7:00 PM", "2026-11-02T19:00"),
            ("12 am tomorrow", "2026-10-28T00:00"), ("12 pm tomorrow", "2026-10-28T12:00"),
            // A month and a day with no year: the nearest such day on or after today inside 366 days.
            ("Jan 5 at 6 pm", "2027-01-05T18:00"), ("Oct 27 at 6 pm", "2026-10-27T18:00"), ("Oct 26 at 6 pm", "2027-10-26T18:00"),
            ("7:00 PM tomorrow", "2026-10-28T19:00"), ("2027-10-27 7 PM", "2027-10-27T19:00"),
        ]
        for (quote, value) in keptCases { XCTAssertEqual(kept(time: value, quote: quote), at(value), "\(quote) / \(value)") }
        // The kept value is a date in the fixed zone.
        XCTAssertEqual(kept(time: "2026-10-28T19:00", quote: "7 PM tomorrow"), .time(Date(timeIntervalSince1970: TestClock.date("2026-10-28T19:00").timeIntervalSince1970)))

        let refused: [(String, String)] = [
            // A clock time with no date, a date with no clock time.
            ("at 7 PM", "2026-10-28T19:00"), ("tomorrow", "2026-10-28T19:00"), ("Friday", "2026-10-30T19:00"), ("on 2026-10-28", "2026-10-28T19:00"),
            // A different hour, minute or date.
            ("7 PM tomorrow", "2026-10-28T20:00"), ("7 PM tomorrow", "2026-10-28T19:30"), ("7 PM tomorrow", "2026-10-29T19:00"),
            ("7 PM tomorrow", "2026-10-28T07:00"), ("noon on Friday", "2026-10-31T12:00"), ("Nov 2nd at 7 PM", "2026-11-03T19:00"),
            // A past time, and a time beyond 366 days.
            ("8 AM today", "2026-10-27T08:00"), ("7 PM on 2027-11-30", "2027-11-30T19:00"), ("9:01 AM on 2027-10-28", "2027-10-28T09:01"),
            ("Oct 26 at 6 pm", "2026-10-26T18:00"), ("Jan 5 at 6 pm", "2026-01-05T18:00"),
            // A bare number and a phrase beyond the listed forms.
            ("7 tomorrow", "2026-10-28T07:00"), ("7:30 tomorrow", "2026-10-28T07:30"), ("next Friday at 7 PM", "2026-10-30T19:00"),
            ("next Friday at 7 PM", "2026-11-06T19:00"), ("seven pm tomorrow", "2026-10-28T19:00"), ("this evening, 7 PM", "2026-10-27T19:00"),
            // A date that does not exist.
            ("Feb 30 at 6 pm", "2027-02-28T18:00"), ("2026-02-30 7 PM", "2026-02-28T19:00"),
            // A value that is not a real local date-time of the form.
            ("7 PM tomorrow", "2026-10-28 19:00"), ("7 PM tomorrow", "2026-10-28T19:00:00"), ("7 PM tomorrow", "2026-10-28T7:00"),
            ("7 PM tomorrow", "tomorrow 7 PM"), ("2026-02-30 7 PM", "2026-02-30T19:00"), ("7 PM tomorrow", "2026-10-28T24:00"),
            ("7 PM tomorrow", ""),
        ]
        for (quote, value) in refused { XCTAssertNil(kept(time: value, quote: quote), "\(quote) / \(value)") }
        // Two dates or two clock times in one quote keep nothing, whichever one the value names.
        for value in ["2026-10-28T19:00", "2026-11-02T19:00"] { XCTAssertNil(kept(time: value, quote: "7 PM tomorrow or Nov 2"), value) }
        for value in ["2026-10-28T19:00", "2026-10-28T20:00"] { XCTAssertNil(kept(time: value, quote: "7 PM or 8 PM tomorrow"), value) }
        XCTAssertNil(kept(time: "2026-10-28T19:00", quote: "7 PM, yes 7 PM tomorrow"))
        XCTAssertNil(kept(time: "2026-10-30T19:00", quote: "7 PM Friday Oct 30"), "a weekday and a month with a day are two dates")
        // Tokens do not overlap: 7:00 PM is one clock time (not also 7 and 0 PM), so one such time with one date is kept.
        XCTAssertEqual(kept(time: "2026-10-28T19:00", quote: "7:00 PM tomorrow"), at("2026-10-28T19:00"))
        XCTAssertNil(kept(time: "2026-10-28T07:00", quote: "7:00 PM tomorrow"))
        // The clock time of a quote that is a user line is read; the same words in no user line keep nothing.
        XCTAssertNil(fill([entry("start", "2026-10-28T19:00", "7 PM tomorrow")], lines: ["7 PM on Wednesday"])["start"])
        XCTAssertEqual(fill([entry("start", "2026-10-28T19:00", "7 PM tomorrow")], lines: ["please, 7 PM tomorrow works"])["start"], at("2026-10-28T19:00"))
    }

    // MARK: R04 entries, keys and kinds

    func testR04_OnlyTextPlaceNumberAndTimeAreKeptAndTheFirstEntryOfAKeyIsTheOneConsidered() {
        let lines = ["Name Sam Lee, table for 2, tomorrow at 7 PM", "the small one, door open"]
        let name = entry("name", "Sam Lee", "Name Sam Lee")
        let size = entry("size", "2", "table for 2")
        let start = entry("start", "2026-10-28T19:00", "tomorrow at 7 PM")
        // Positive first: the good entries together.
        let all = fill([name, size, start], lines: lines)
        XCTAssertEqual(all, ["name": .text("Sam Lee"), "size": .number(2), "start": .time(TestClock.date("2026-10-28T19:00"))])
        // A pick_one or on_off entry is never kept, quote or no quote; an unknown key is skipped.
        XCTAssertEqual(fill([entry("side", "small", "the small one"), entry("door", "true", "door open"), entry("zzz", "x", "Name")], lines: lines), [:])
        XCTAssertEqual(fill([entry("side", "small", "the small one"), name], lines: lines), ["name": .text("Sam Lee")])
        // An entry without a quote member is skipped, and so is an unparsable text.
        XCTAssertEqual(fill([entry("name", "Sam Lee", nil), size], lines: lines), ["size": .number(2)])
        for text in ["not json", "{}", "[1, 2]", "", "[]", "null", #"{"key":"name","value":"Sam Lee","quote":"Name Sam Lee"}"#, "[{"] {
            XCTAssertEqual(fillText(text, lines: lines), [:], text)
        }
        XCTAssertEqual(fillText(nil, lines: lines), [:])
        // At most eight entries are read: a good ninth entry is not, a good eighth one is.
        let filler = (0..<8).map { entry("zzz\($0)", "x", "Name") }
        XCTAssertEqual(fill(filler + [name], lines: lines), [:])
        XCTAssertEqual(fill(Array(filler.prefix(7)) + [name], lines: lines), ["name": .text("Sam Lee")])
        // An entry with a member that is not a string is skipped alone, and a good neighbour is kept.
        let numberValue: [String: Any] = ["key": "name", "value": 5, "quote": "Name Sam Lee"]
        let nullQuote: [String: Any] = ["key": "name", "value": "Sam Lee", "quote": NSNull()]
        let numberKey: [String: Any] = ["key": 7, "value": "Sam Lee", "quote": "Name Sam Lee"]
        XCTAssertEqual(fill([numberValue, size], lines: lines), ["size": .number(2)])
        XCTAssertEqual(fill([nullQuote, size], lines: lines), ["size": .number(2)])
        XCTAssertEqual(fill([numberKey, size], lines: lines), ["size": .number(2)])
        XCTAssertEqual(fill(["Sam Lee", 5, NSNull(), size], lines: lines), ["size": .number(2)])
        // An entry skipped for a bad member claims no key, so a good later entry for that key is kept.
        XCTAssertEqual(fill([numberValue, name], lines: lines), ["name": .text("Sam Lee")])
        XCTAssertEqual(fill([entry("name", "Sam Lee", nil), name], lines: lines), ["name": .text("Sam Lee")])
        // A repeated key: the first entry is the one considered, and the test reads the final value.
        XCTAssertEqual(fill([name, entry("name", "Sam", "Name Sam Lee")], lines: lines), ["name": .text("Sam Lee")])
        XCTAssertEqual(fill([entry("name", "Sam", "Name Sam Lee"), name], lines: lines), ["name": .text("Sam")])
        // A first entry whose quote is empty or blank is considered: it claims its key and leaves the field blank.
        XCTAssertEqual(fill([entry("name", "Sam Lee", ""), name], lines: lines), [:])
        XCTAssertEqual(fill([entry("name", "Sam Lee", "   "), name], lines: lines), [:])
        // So does a first entry that fails the check, whatever a later entry holds.
        XCTAssertEqual(fill([entry("name", "Sam Lee", "Someone else"), name], lines: lines), [:])
        XCTAssertEqual(fill([entry("name", "Kim", "Name Sam Lee"), name], lines: lines), [:])
        // One bad entry does not drop a good one.
        XCTAssertEqual(fill([entry("name", "Sam Lee", "Someone else"), size, entry("start", "2026-10-28T19:00", "7 PM")], lines: lines), ["size": .number(2)])
        XCTAssertEqual(fill([size, entry("start", "2026-10-28T19:00", "7 PM"), name], lines: lines).count, 2)
    }
}
