import XCTest
@testable import besir

// SPEC-MEMORY-002 (card t74): the counts made from the raw lines of memory.md (facts, window, groups, slices, ties), the count
// line grammar, and the selection by strength within 16 lines and 1600 code points. Today is 2026-10-27 in
// America/Los_Angeles (`TestClock`), so the window starts on 2026-09-15.

/// SMALL: eight raw lines; the last is older than the 42-day window.
private let small = [
    "- 2026-10-06 | Tue | 7:00 AM | activity | Example Gym | mode=car",
    "- 2026-10-08 | Thu | 7:00 AM | activity | Example Gym | mode=car",
    "- 2026-10-13 | Tue | 7:00 AM | activity | Example Gym | mode=car",
    "- 2026-10-14 | Wed | 12:30 PM | activity | Example Cafe | mode=transit",
    "- 2026-10-16 | Fri | 6:30 PM | activity | Example Cafe | mode=transit",
    "- 2026-10-21 | Wed | 12:30 PM | activity | Example Cafe | mode=transit",
    "- 2026-10-23 | Fri | 6:30 PM | activity | Example Cafe | mode=transit",
    "- 2026-09-01 | Tue | 7:00 AM | activity | Example Gym | mode=walk",
]

/// The four raw lines BIG adds to SMALL.
private let bigRaw = [
    "- 2026-10-20 | Tue | 12:20 PM | meal | Example Diner",
    "- 2026-10-26 | Mon | 12:15 PM | meal | Example Diner",
    "- 2026-10-17 | Sat | 7:00 PM | partner | - | partner=Example Tables | quantity=2",
    "- 2026-10-24 | Sat | 7:00 PM | partner | - | partner=Example Tables | quantity=2",
]

/// The three entries of BIG that are not raw lines (2026-10-22 is a Thursday).
private let bigNotRaw = [
    "- count | 2026-09-01..2026-09-30 | activity | mode=walk | 9 of 9",
    "# a heading line",
    "- 2026-10-22 | Wed | 7:00 AM | activity | Example Gym | mode=walk",
]

/// The five count lines of SMALL, in selection order (the count lines of instructions-memory-sample.txt).
private let smallCounts = [
    "- count | 2026-10-06..2026-10-13 | activity | mode=car | part=morning | 3 of 3",
    "- count | 2026-10-06..2026-10-13 | activity | mode=car | place=Example Gym | 3 of 3",
    "- count | 2026-10-06..2026-10-13 | activity | place=Example Gym | part=morning | 3 of 3",
    "- count | 2026-10-14..2026-10-23 | activity | mode=transit | - | 4 of 7",
    "- count | 2026-10-14..2026-10-23 | activity | place=Example Cafe | - | 4 of 7",
]

/// A flag: two code points, one Character, four UTF-16 units.
private let flag = "\u{1F1F0}\u{1F1F7}"

final class MemoryCountsTests: XCTestCase {
    // MARK: Helpers

    private func summary(_ lines: [String], now: Date = TestClock.now, zone: TimeZone = TestClock.zone) -> [String] {
        MemoryCounts.summary(lines: lines, now: now, timeZone: zone)
    }

    private func assertRaw(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in lines { XCTAssertNotNil(MemoryLine(text: text), "control: not read as a raw line: \(text)", file: file, line: line) }
    }

    private func assertRefused(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in lines { XCTAssertNil(MemoryLine(text: text), "control: read as a raw line: \(text)", file: file, line: line) }
    }

    /// A raw line spelled by the test: the weekday of `day` (a `yyyy-MM-dd` Gregorian day) is worked out here.
    private func raw(_ day: String, _ time: String, _ kind: String, _ place: String, _ fields: [String] = []) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.date(from: day) ?? .distantPast
        formatter.dateFormat = "EEE"
        return "- " + ([day, formatter.string(from: date), time, kind, place] + fields).joined(separator: " | ")
    }

    /// A candidate of kind `zz` and key `k`, from 2026-10-01.
    private func candidate(_ value: String, to: String, _ n: Int, of total: Int) -> MemoryCountLine {
        MemoryCountLine(from: "2026-10-01", to: to, kind: "zz", field: MemoryField(key: "k", value: value), context: nil,
                        n: n, total: total)
    }

    private func scalarsWithLineFeeds(_ lines: [MemoryCountLine]) -> Int {
        lines.reduce(0) { $0 + $1.text.unicodeScalars.count + 1 }
    }

    // MARK: C01-C10

    /// AC-011: the worked example BIG gives these eight lines in this order.
    func testMSUM_C01_TheWorkedExampleGivesTheseEightLinesInThisOrder() {
        assertRaw(small + bigRaw)
        assertRefused(bigNotRaw)
        XCTAssertEqual(summary(small + bigRaw + bigNotRaw), smallCounts + [
            "- count | 2026-10-20..2026-10-26 | meal | place=Example Diner | - | 2 of 2",
            "- count | 2026-10-17..2026-10-24 | partner | partner=Example Tables | - | 2 of 2",
            "- count | 2026-10-17..2026-10-24 | partner | quantity=2 | - | 2 of 2",
        ])
    }

    /// AC-009: the window starts 42 calendar days back in the request's zone and has no end.
    func testMSUM_C02_TheWindowStartsFortyTwoDaysBackAndHasNoEnd() throws {
        let window = [
            "- 2026-09-14 | Mon | 9:00 AM | zz_win | - | x=a",
            "- 2026-09-15 | Tue | 9:00 AM | zz_win | - | x=a",
            "- 2026-10-01 | Thu | 9:00 AM | zz_win | - | x=a",
            "- 2026-11-20 | Fri | 9:00 AM | zz_win | - | x=a",
        ]
        assertRaw(window)
        XCTAssertEqual(summary(window), ["- count | 2026-09-15..2026-11-20 | zz_win | x=a | - | 3 of 3"],
                       "09-14 is out, 09-15 is the first day in, 11-20 counts")

        // 3:30 AM in Los Angeles is 2026-10-28 12:30 AM in UTC+14, so today there is 2026-10-28 and the start 2026-09-16.
        let kiritimati = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let zone = [
            "- 2026-09-15 | Tue | 9:00 AM | zz_zone | - | x=a",
            "- 2026-09-16 | Wed | 9:00 AM | zz_zone | - | x=a",
            "- 2026-10-01 | Thu | 9:00 AM | zz_zone | - | x=a",
        ]
        assertRaw(zone)
        XCTAssertEqual(summary(zone, now: TestClock.date("2026-10-27T03:30"), zone: kiritimati),
                       ["- count | 2026-09-16..2026-10-01 | zz_zone | x=a | - | 2 of 2"],
                       "the window is taken in the request's zone, not the device's")

        // Clocks went forward on 2027-03-14 in Los Angeles: 42 calendar days back from 2027-04-20 is 2027-03-09.
        let dst = [
            "- 2027-03-08 | Mon | 9:00 AM | zz_dst | - | x=a",
            "- 2027-03-09 | Tue | 9:00 AM | zz_dst | - | x=a",
            "- 2027-03-20 | Sat | 9:00 AM | zz_dst | - | x=a",
        ]
        assertRaw(dst)
        XCTAssertEqual(summary(dst, now: TestClock.date("2027-04-20T00:30")),
                       ["- count | 2027-03-09..2027-03-20 | zz_dst | x=a | - | 2 of 2"],
                       "42 calendar days, not 42 times 86400 seconds")
    }

    /// AC-010: an overall line needs a leader chosen twice; a slice needs three lines and a leader chosen twice.
    func testMSUM_C03_AnOverallLineNeedsTwoAndASliceNeedsThree() {
        let mondays = ["2026-10-05", "2026-10-12", "2026-10-19", "2026-10-26"].map { raw($0, "8:00 AM", "zz_slice", "-", ["x=a"]) }
        let tuesdays = ["2026-10-06", "2026-10-13"].map { raw($0, "8:00 AM", "zz_slice", "-", ["x=b"]) }
        let thirdTuesday = raw("2026-10-20", "8:00 AM", "zz_slice", "-", ["x=b"])
        let wednesdays = [("2026-10-07", "x=c"), ("2026-10-14", "x=d"), ("2026-10-21", "x=e")]
            .map { raw($0.0, "8:00 AM", "zz_slice", "-", [$0.1]) }
        let single = "- 2026-10-20 | Tue | 8:00 AM | zz_one | - | x=a"
        assertRaw(mondays + tuesdays + [thirdTuesday] + wednesdays + [single])

        XCTAssertEqual(summary(mondays + tuesdays), ["- count | 2026-10-05..2026-10-26 | zz_slice | x=a | - | 4 of 6"],
                       "(a) a two-line slice is not enough")
        XCTAssertEqual(summary(mondays + tuesdays + [thirdTuesday]), [
            "- count | 2026-10-06..2026-10-20 | zz_slice | x=b | weekday=Tue | 3 of 3",
            "- count | 2026-10-05..2026-10-26 | zz_slice | x=a | - | 4 of 7",
        ], "(b) a three-line slice whose leader differs")
        XCTAssertEqual(summary(mondays + wednesdays), ["- count | 2026-10-05..2026-10-26 | zz_slice | x=a | - | 4 of 7"],
                       "(c) a slice leader chosen once is not enough")
        XCTAssertEqual(summary([single]), [], "(d) one line")
    }

    /// AC-010: a slice that repeats the overall leader is left out; a place is not sliced by place; a `place=` field is not counted.
    func testMSUM_C04_ASliceThatRepeatsTheOverallLineIsLeftOut() {
        let weeks = [
            ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09"],
            ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16"],
            ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23"],
        ]
        let modes = ["mode=transit", "mode=car", "mode=transit", "mode=car", "mode=transit"]
        let office = weeks.flatMap { week in
            week.indices.map { raw(week[$0], "8:30 AM", "activity", "Example Office", [modes[$0]]) }
        }
        XCTAssertEqual(office.count, 15)
        assertRaw(office)
        XCTAssertEqual(summary(office), [
            "- count | 2026-10-05..2026-10-23 | activity | place=Example Office | - | 15 of 15",
            "- count | 2026-10-05..2026-10-23 | activity | mode=transit | - | 9 of 15",
            "- count | 2026-10-08..2026-10-22 | activity | mode=car | weekday=Thu | 3 of 3",
            "- count | 2026-10-06..2026-10-20 | activity | mode=car | weekday=Tue | 3 of 3",
        ])

        let placeA = ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05"]
            .map { raw($0, "1:00 PM", "zz_place", "Place A", ["place=Hidden Name"]) }
        let placeB = ["2026-10-06", "2026-10-07", "2026-10-08"].map { raw($0, "1:00 PM", "zz_place", "Place B") }
        assertRaw(placeA + placeB)
        let places = summary(placeA + placeB)
        XCTAssertEqual(places, ["- count | 2026-10-01..2026-10-05 | zz_place | place=Place A | - | 5 of 8"])
        XCTAssertFalse(places.contains { $0.contains("Hidden Name") }, "a field with the key place is not counted")
    }

    /// AC-010: a tie goes to the value first in code-point order; the dates are the leader's own.
    func testMSUM_C05_ATieGoesToTheSmallerValueAndTheRangeIsTheLeaders() {
        let tie = [("2026-10-01", "x=alpha"), ("2026-10-02", "x=alpha"), ("2026-10-10", "x=Zed"), ("2026-10-11", "x=Zed")]
            .map { raw($0.0, "9:00 AM", "zz_tie", "-", [$0.1]) }
        assertRaw(tie)
        XCTAssertEqual(summary(tie), ["- count | 2026-10-10..2026-10-11 | zz_tie | x=Zed | - | 2 of 4"])
    }

    /// AC-012: strength is n times n over N; equal strengths go by the later end date, then by text.
    func testMSUM_C06_StrengthIsNTimesNOverN() {
        let input = [
            candidate("p", to: "2026-10-05", 2, of: 2),
            candidate("r", to: "2026-10-05", 2, of: 2),
            candidate("x", to: "2026-10-20", 3, of: 3),
            candidate("q", to: "2026-10-09", 4, of: 8),
            candidate("y", to: "2026-10-01", 8, of: 10),
        ]
        XCTAssertEqual(MemoryCounts.select(input).map(\.text), [
            "- count | 2026-10-01..2026-10-01 | zz | k=y | - | 8 of 10",
            "- count | 2026-10-01..2026-10-20 | zz | k=x | - | 3 of 3",
            "- count | 2026-10-01..2026-10-09 | zz | k=q | - | 4 of 8",
            "- count | 2026-10-01..2026-10-05 | zz | k=p | - | 2 of 2",
            "- count | 2026-10-01..2026-10-05 | zz | k=r | - | 2 of 2",
        ])
    }

    /// AC-012: taking stops at sixteen lines or at the first line that would pass 1600 code points.
    func testMSUM_C07_TheSummaryStopsAtSixteenLinesOr1600CodePoints() {
        // (a) twenty short lines: the first sixteen.
        let letters = "abcdefghijklmnopqrst".map(String.init)
        let twenty = letters.map { candidate($0, to: "2026-10-20", 2, of: 2) }
        let a = MemoryCounts.select(twenty)
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(a.map(\.field.value), Array(letters.prefix(16)))
        XCTAssertEqual(scalarsWithLineFeeds(a), 912)

        // (b) thirteen long lines and a flag line that fits exactly: 1600 code points.
        let thirteen = "ABCDEFGHIJKLM".map { candidate(String(repeating: String($0), count: 60), to: "2026-10-20", 2, of: 2) }
        XCTAssertEqual(thirteen.map { $0.text.unicodeScalars.count }, Array(repeating: 115, count: 13))
        let fits = candidate(String(repeating: "x", count: 34) + flag, to: "2026-10-19", 2, of: 2)
        XCTAssertEqual(fits.text.unicodeScalars.count, 91)
        let b = MemoryCounts.select(thirteen + [fits])
        XCTAssertEqual(b.count, 14)
        XCTAssertEqual(b.last?.field.value, fits.field.value)
        XCTAssertEqual(scalarsWithLineFeeds(b), 1600)

        // (c) the flag line one code point longer breaks the limit; taking stops, so the short line after it is not taken.
        let over = candidate(String(repeating: "x", count: 35) + flag, to: "2026-10-19", 2, of: 2)
        let short = candidate("z", to: "2026-10-18", 2, of: 2)
        let c = MemoryCounts.select(thirteen + [over, short])
        XCTAssertEqual(c.count, 13)
        XCTAssertEqual(c.map(\.text), thirteen.map(\.text))
        XCTAssertFalse(c.contains { $0.field.value == "z" }, "no k=z line")
    }

    /// AC-008: only raw lines are counted, each through the memory line reader.
    func testMSUM_C08_OnlyRawLinesAreCounted() {
        let l1 = "- 2026-10-20 | Tue | 7:00 AM | zz_raw | - | x=a"
        let r1 = "- 2026-10-21 | Tue | 7:00 AM | zz_raw | - | x=a"
        let r2 = "- count | 2026-10-01..2026-10-20 | zz_raw | x=a | 9 of 9"
        let r3 = "## x=a"
        let l2 = "- 2026-10-23 | Fri | 7:00 AM | zz_raw | - | x=a"
        assertRaw([l1, l2])
        assertRefused([r1, r2, r3])
        XCTAssertEqual(summary([l1, r1, r2, r3, l2]), ["- count | 2026-10-20..2026-10-23 | zz_raw | x=a | - | 2 of 2"],
                       "control: two raw lines make one count line")
        XCTAssertEqual(summary([l1, r1, r2, r3]), [], "one raw line; the refused, count and heading lines add nothing")
    }

    /// AC-011: the count line grammar, for any kind and key.
    func testMSUM_C09_ACountLineReadsLikeThisForAnyKind() {
        let bowl = MemoryField(key: "item", value: "Green Bowl")
        XCTAssertEqual(MemoryCountLine(from: "2026-10-01", to: "2026-10-20", kind: "zz_newkind", field: bowl, context: nil,
                                       n: 2, total: 3).text,
                       "- count | 2026-10-01..2026-10-20 | zz_newkind | item=Green Bowl | - | 2 of 3")
        XCTAssertEqual(MemoryCountLine(from: "2026-10-01", to: "2026-10-20", kind: "zz_newkind", field: bowl,
                                       context: MemoryField(key: "weekday", value: "Fri"), n: 2, total: 3).text,
                       "- count | 2026-10-01..2026-10-20 | zz_newkind | item=Green Bowl | weekday=Fri | 2 of 3")
        let lines = [
            "- 2026-10-02 | Fri | 12:15 PM | zz_newkind | Salad Place | item=Green Bowl | count=2",
            "- 2026-10-09 | Fri | 12:15 PM | zz_newkind | Salad Place | item=Green Bowl | count=2",
        ]
        assertRaw(lines)
        XCTAssertEqual(summary(lines), [
            "- count | 2026-10-02..2026-10-09 | zz_newkind | count=2 | - | 2 of 2",
            "- count | 2026-10-02..2026-10-09 | zz_newkind | item=Green Bowl | - | 2 of 2",
            "- count | 2026-10-02..2026-10-09 | zz_newkind | place=Salad Place | - | 2 of 2",
        ])
    }

    /// AC-008: the part of the day comes from the line's own time.
    func testMSUM_C10_ThePartOfTheDayComesFromTheLinesOwnTime() {
        XCTAssertEqual(MemoryCounts.part(of: "4:59 AM"), "night")
        XCTAssertEqual(MemoryCounts.part(of: "5:00 AM"), "morning")
        XCTAssertEqual(MemoryCounts.part(of: "11:59 AM"), "morning")
        XCTAssertEqual(MemoryCounts.part(of: "12:00 PM"), "afternoon")
        XCTAssertEqual(MemoryCounts.part(of: "4:59 PM"), "afternoon")
        XCTAssertEqual(MemoryCounts.part(of: "5:00 PM"), "evening")
        XCTAssertEqual(MemoryCounts.part(of: "9:59 PM"), "evening")
        XCTAssertEqual(MemoryCounts.part(of: "10:00 PM"), "night")
        XCTAssertEqual(MemoryCounts.part(of: "12:00 AM"), "night")
        XCTAssertEqual(MemoryCounts.part(of: "12:30 AM"), "night")
        XCTAssertNil(MemoryCounts.part(of: "13:00 PM"))
        XCTAssertNil(MemoryCounts.part(of: "7:00"))
    }
}
