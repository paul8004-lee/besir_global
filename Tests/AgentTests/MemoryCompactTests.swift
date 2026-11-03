import XCTest
@testable import besir

// SPEC-MEMORY-004 (card t74): the reader of the count line, the file's count lines in the counting, the compaction one append
// makes (fold, window, caps, file bound), and the Store hook. Every compaction and every summary gets an explicit instant and
// zone; nothing here reads the machine's clock.

/// A memory file write that always fails.
private struct CompactWriteFailure: Error {}

/// A memory file write that counts its calls and then writes the file as the app does.
private final class CompactCountingWrite: @unchecked Sendable {
    private(set) var calls = 0

    func write(_ data: Data, _ url: URL) throws {
        calls += 1
        try ConnectionLog.defaultWrite(data, url)
    }
}

/// Calendar days spelled by the tests themselves (Gregorian, UTC), so no fixture depends on the code under test.
private enum Days {
    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.isLenient = false
        f.dateFormat = pattern
        return f
    }

    /// The three weekday names every run of days relies on.
    static func checks() -> [String] {
        ["2026-09-01", "2026-10-01", "2026-12-31"].map(weekday)
    }

    static func weekday(_ day: String) -> String {
        formatter("EEE").string(from: formatter("yyyy-MM-dd").date(from: day) ?? .distantPast)
    }

    /// Every day from `first` to `last`, both included, as `yyyy-MM-dd`.
    static func run(_ first: String, _ last: String) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let f = formatter("yyyy-MM-dd")
        var result: [String] = []
        guard var day = f.date(from: first), let end = f.date(from: last) else { return result }
        while day <= end {
            result.append(f.string(from: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

/// One raw line with the weekday of its day worked out here.
private func raw(_ day: String, _ time: String, _ kind: String, _ place: String, _ fields: String...) -> String {
    "- \(day) | \(Days.weekday(day)) | \(time) | \(kind) | \(place)" + fields.map { " | " + $0 }.joined()
}

/// "zz run A..B": one raw line `- <date> | <weekday> | 8:00 AM | zz | - | k=a` a day.
private func zzRun(_ first: String, _ last: String, _ field: String = "k=a") -> [String] {
    Days.run(first, last).map { raw($0, "8:00 AM", "zz", "-", field) }
}

/// "zf filler A..B from vNN": one line `- <date> | <weekday> | 9:00 AM | zf | - | k=v<NN>` a day, NN counting up from `start`,
/// each value once, so no count line forms.
private func zfFiller(_ first: String, _ last: String, from start: Int) -> [String] {
    Days.run(first, last).enumerated().map { index, day in
        raw(day, "9:00 AM", "zf", "-", "k=v" + String(format: "%02d", start + index))
    }
}

/// The compaction at a local instant in the fixed zone.
private func compaction(_ now: String) -> MemoryCompaction {
    MemoryCompaction(now: TestClock.date(now), zone: TestClock.zone)
}

/// The summary at a local instant in the fixed zone.
private func summary(_ lines: [String], _ now: String = TestClock.nowString) -> [String] {
    MemoryCounts.summary(lines: lines, now: TestClock.date(now), timeZone: TestClock.zone)
}

/// The count lines of a list of item lines.
private func counts(_ lines: [String]) -> [String] {
    lines.filter { $0.hasPrefix("- count | ") }
}

/// The text of a count line read back, compared code point by code point.
private func readsBack(_ text: String) -> Bool {
    MemoryCountLine(text: text).map { Array($0.text.unicodeScalars) == Array(text.unicodeScalars) } ?? false
}

@MainActor
final class MemoryCompactTests: XCTestCase {
    // MARK: Helpers

    private let diner = Place(name: "Example Diner", address: "SENTINEL-ADDRESS-9", latitude: 37.1234, longitude: -122.5678)

    override func setUp() {
        super.setUp()
        XCTAssertEqual(Days.checks(), ["Tue", "Thu", "Thu"], "control: the test calendar names the weekdays")
    }

    private var supportMemoryURL: URL { AppConfig.supportDirectory.appendingPathComponent(MemoryBook.fileName) }

    private func fileText(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func lineFed(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }

    private func tempFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("compact-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func write(_ lines: [String], to url: URL) throws {
        try Data(lineFed(lines).utf8).write(to: url)
    }

    /// A Store over the support folder's `memory.md`, with the compaction clock and the zone fixed.
    private func launched(now: String = "2026-10-01T09:00") -> Store {
        let store = Store(notifications: NotificationManager())
        store.memoryNow = { TestClock.date(now) }
        store.memoryTimeZone = { TestClock.zone }
        return store
    }

    // MARK: R01 the reader (AC-001)

    func testCMP_R01_ACountLineReadsBackAndEveryOtherTextIsRefused() {
        let accepted = [
            "- count | 2026-10-14..2026-10-23 | activity | mode=transit | - | 4 of 7",
            "- count | 2026-10-06..2026-10-13 | activity | mode=car | part=morning | 3 of 3",
            "- count | 2026-10-06..2026-10-13 | activity | mode=car | place=Example Gym | 3 of 3",
            "- count | 2026-10-06..2026-10-20 | zz_slice | x=b | weekday=Tue | 3 of 3",
            "- count | 2026-10-14..2026-10-23 | activity | place=Example Cafe | - | 4 of 7",
            "- count | 2026-10-01..2026-10-01 | zz | weekday=x | part=night | 2 of 3",
            "- count | 2026-10-01..2026-10-20 | zz | k=\u{301}x | - | 2 of 3",
            "- count | 2026-10-01..2026-10-20 | zz | k=a\u{0D4E} | - | 2 of 3",
        ]
        let first = MemoryCountLine(text: accepted[0])
        XCTAssertEqual(first?.text, accepted[0])
        XCTAssertEqual(first?.from, "2026-10-14")
        XCTAssertEqual(first?.to, "2026-10-23")
        XCTAssertEqual(first?.kind, "activity")
        XCTAssertEqual(first?.field, MemoryField(key: "mode", value: "transit"))
        XCTAssertNil(first?.context)
        XCTAssertEqual(first?.n, 4)
        XCTAssertEqual(first?.total, 7)
        XCTAssertEqual(MemoryCountLine(text: accepted[3])?.context, MemoryField(key: "weekday", value: "Tue"))
        XCTAssertEqual(MemoryCountLine(text: accepted[5])?.context, MemoryField(key: "part", value: "night"))
        for text in accepted { XCTAssertTrue(readsBack(text), "reads back: \(text)") }

        // A value that begins with a combining mark: the field is those two code points, 57 code points and 56 Characters.
        let mark = MemoryCountLine(text: accepted[6])
        XCTAssertEqual(mark?.field.key, "k")
        XCTAssertEqual(mark?.field.value.unicodeScalars.map(\.value), [0x301, 0x78])
        XCTAssertEqual(accepted[6].unicodeScalars.count, 57)
        XCTAssertEqual(accepted[6].count, 56)
        // A value that ends with a prepended mark: a split by Character joins that code point with the space after it.
        let reph = MemoryCountLine(text: accepted[7])
        XCTAssertEqual(reph?.field.value.unicodeScalars.map(\.value), [0x61, 0x0D4E])
        XCTAssertEqual(reph?.total, 3)

        let p = "- count | 2026-10-01..2026-10-20 | zz | "
        let refused = [
            "- count | 2026-10-14..2026-10-23 | activity | mode=transit | 4 of 7",
            "- count | 2026-09-07 | 2026-09-25 | activity | Mon Wed Fri Sat | mode=transit | 10 of 12",
            "- count | 2026-09-01 | 2026-09-30 | mode=transit | 3 of 4",
            p + "k=a | - | 2 of 2 | extra",
            "- count | 2026-10-20..2026-10-01 | zz | k=a | - | 2 of 2",
            "- count | 2026-02-30..2026-03-01 | zz | k=a | - | 2 of 2",
            "- count | 2026-9-7..2026-09-28 | zz | k=a | - | 2 of 2",
            "- count | 2026-10-01-2026-10-20 | zz | k=a | - | 2 of 2",
            "- count | 2026-10-01..2026-10-20 | Meal | k=a | - | 2 of 2",
            p + "Mode=car | - | 2 of 2",
            p + "mode | - | 2 of 2",
            p + "k= | - | 2 of 2",
            p + "k=Example  Gym | - | 2 of 2",
            p + "k=" + String(repeating: "v", count: 61) + " | - | 2 of 2",
            p + "place=- | - | 2 of 2",
            p + "k=a | day=Mon | 3 of 3",
            p + "k=a | weekday=Monday | 3 of 3",
            p + "k=a | part=lunch | 3 of 3",
            p + "place=Example Gym | place=Example Gym | 3 of 3",
            p + "k=a | place=- | 3 of 3",
            p + "k=a | weekday=Tue | 2 of 2",
            p + "k=a | - | 1 of 3",
            p + "k=a | - | 5 of 4",
            p + "k=a | - | 02 of 3",
            p + "k=a | - | 3 of 10000",
            p + "k=a | - | 3 of 99999999999999999999999",
            p + "k=a | - | 2/3",
            "- 2026-10-20 | Tue | 7:00 AM | activity | Example Gym | mode=car",
            "count | 2026-10-01..2026-10-20 | zz | k=a | - | 2 of 2",
        ]
        XCTAssertEqual(refused.count, 29)
        for text in refused { XCTAssertNil(MemoryCountLine(text: text), "refused: \(text)") }

        let longest = "- count | 2026-10-01..2026-10-31 | " + String(repeating: "a", count: 20) + " | " + String(repeating: "k", count: 20)
            + "=" + String(repeating: "v", count: 60) + " | place=" + String(repeating: "p", count: 60) + " | 9999 of 9999"
        XCTAssertEqual(longest.unicodeScalars.count, 223)
        XCTAssertTrue(readsBack(longest))
    }

    // MARK: R02 file count lines in the window (AC-002)

    func testCMP_R02_AFileCountLineCountsWhileItsLastDateIsInTheWindow() {
        let fIn = "- count | 2026-08-01..2026-09-15 | zw | k=a | - | 5 of 6"
        let fOut = "- count | 2026-08-01..2026-09-14 | zw | k=a | - | 5 of 6"
        let fFut = "- count | 2026-10-01..2026-11-20 | zw | k=a | - | 5 of 6"
        XCTAssertEqual(summary([fIn]), [fIn], "its first date is before the window start, its last date is on it")
        XCTAssertEqual(summary([fOut]), [])
        XCTAssertEqual(summary([fFut]), [fFut])

        let evening = TestClock.date("2026-10-27T20:00")
        XCTAssertEqual(MemoryCounts.summary(lines: [fIn], now: evening, timeZone: TestClock.zone), [fIn])
        let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!
        XCTAssertEqual(MemoryCounts.summary(lines: [fIn], now: evening, timeZone: kiritimati), [],
                       "the same instant is the next day there, and the window starts a day later")

        let small = "- count | 2026-10-01..2026-10-31 | zc | k=a | - | 2 of 2"
        let big = "- count | 2026-10-01..2026-10-31 | zc | k=a | - | 9999 of 9999"
        let oldBig = "- count | 2026-08-01..2026-09-14 | zc | k=a | - | 9999 of 9999"
        let eighty = ["- count | 2026-10-01..2026-10-31 | zc | k=a | - | 80 of 80"]
        XCTAssertEqual(summary(Array(repeating: small, count: 40) + [big]), eighty, "the 41st count line adds nothing")
        XCTAssertEqual(summary([oldBig] + Array(repeating: small, count: 40)), eighty,
                       "a count line before the window does not use one of the 40")
    }

    // MARK: R03 file count lines join their identity's tally (AC-003)

    func testCMP_R03_FileCountLinesJoinTheirIdentitysTally() {
        let raw3 = [
            "- 2026-10-19 | Mon | 9:00 AM | zm | - | k=a",
            "- 2026-10-20 | Tue | 9:00 AM | zm | - | k=a",
            "- 2026-10-21 | Wed | 9:00 AM | zm | - | k=b",
            "- 2026-10-22 | Thu | 9:00 AM | zm | - | k=b",
            "- 2026-10-23 | Fri | 9:00 AM | zm | - | k=b",
            "- 2026-10-20 | Tue | 9:00 AM | zp | - | x=q",
            "- 2026-10-21 | Wed | 9:00 AM | zp | - | x=q",
            "- 2026-10-22 | Thu | 9:00 AM | zp | - | x=q",
        ]
        let file3 = [
            "- count | 2026-09-20..2026-10-10 | zm | k=a | - | 6 of 9",
            "- count | 2026-09-16..2026-09-18 | zm | k=a | - | 2 of 3",
            "- count | 2026-09-25..2026-10-05 | zm | k=c | - | 4 of 6",
            "- count | 2026-09-21..2026-10-05 | zm | k=a | weekday=Mon | 3 of 4",
            "- count | 2026-10-01..2026-10-08 | zp | x=q | - | 4 of 5",
            "- count | 2026-10-01..2026-10-08 | zn | x=q | part=evening | 3 of 3",
        ]
        XCTAssertEqual(summary(raw3), [
            "- count | 2026-10-20..2026-10-22 | zp | x=q | - | 3 of 3",
            "- count | 2026-10-21..2026-10-23 | zm | k=b | - | 3 of 5",
        ], "control: the raw lines alone")
        XCTAssertEqual(summary(raw3 + file3), [
            "- count | 2026-10-01..2026-10-22 | zp | x=q | - | 7 of 8",
            "- count | 2026-09-16..2026-10-20 | zm | k=a | - | 10 of 23",
            "- count | 2026-10-01..2026-10-08 | zn | x=q | part=evening | 3 of 3",
            "- count | 2026-10-21..2026-10-23 | zm | k=b | part=morning | 3 of 5",
        ])
    }

    // MARK: R04 a fold keeps only each group's leader (AC-004)

    func testCMP_R04_AFoldKeepsOnlyEachGroupsLeader() {
        var r4 = zzRun("2026-08-01", "2026-08-20")
        r4 += zzRun("2026-09-21", "2026-09-26") + zzRun("2026-09-27", "2026-10-01", "k=b")
        let bDays: Set<String> = ["2026-10-05", "2026-10-12", "2026-10-19", "2026-10-26"]
        var filler = 1
        for day in Days.run("2026-10-02", "2026-10-31") {
            if bDays.contains(day) {
                r4.append(raw(day, "8:00 AM", "zz", "-", "k=b"))
            } else if day == "2026-10-30" {
                r4.append(raw(day, "8:00 AM", "zz", "-", "k=a"))
            } else {
                r4.append(raw(day, "9:00 AM", "zf", "-", "k=v" + String(format: "%02d", filler)))
                filler += 1
            }
        }
        XCTAssertEqual(r4.count, 61)
        XCTAssertEqual(summary(r4, "2026-11-01T09:00"), ["- count | 2026-09-27..2026-10-26 | zz | k=b | - | 9 of 16"], "control: before the fold")

        let folded = compaction("2026-11-01T09:00").compact(r4)
        XCTAssertEqual(folded.count, 31)
        XCTAssertEqual(counts(folded), ["- count | 2026-09-21..2026-09-26 | zz | k=a | - | 6 of 11"], "one line, the leader of the fold")
        XCTAssertEqual(Array(folded.dropFirst()), Array(r4.suffix(30)))
        XCTAssertEqual(summary(folded, "2026-11-01T09:00"), [
            "- count | 2026-10-05..2026-10-26 | zz | k=b | weekday=Mon | 4 of 4",
            "- count | 2026-10-05..2026-10-26 | zz | k=b | part=morning | 4 of 5",
            "- count | 2026-09-21..2026-10-30 | zz | k=a | - | 7 of 16",
        ])
    }

    // MARK: F01 the fold writes the counts of the folded lines (AC-006)

    func testCMP_F01_AFoldWritesTheCountsOfTheFoldedLinesThatReadBackTheSame() {
        var f1: [String] = []
        let modes = ["transit", "car", "transit", "car", "transit"]
        for monday in ["2026-10-05", "2026-10-12", "2026-10-19"] {
            let week = Array(Days.run(monday, "2026-10-23").prefix(5))
            for (index, day) in week.enumerated() {
                f1.append(raw(day, "8:30 AM", "activity", "Example Office", "mode=" + modes[index]))
            }
        }
        for friday in ["2026-10-09", "2026-10-16", "2026-10-23"] {
            f1.append(raw(friday, "6:30 PM", "partner", "-", "partner=Example Pizza", "quantity=2"))
        }
        f1 += zfFiller("2026-10-01", "2026-10-13", from: 1) + zfFiller("2026-10-01", "2026-10-30", from: 14)
        XCTAssertEqual(f1.count, 61)

        let now = "2026-11-01T09:00"
        let result = compaction(now).compact(f1)
        XCTAssertEqual(result.count, 36)
        let six = [
            "- count | 2026-10-05..2026-10-23 | activity | place=Example Office | - | 15 of 15",
            "- count | 2026-10-05..2026-10-23 | activity | mode=transit | - | 9 of 15",
            "- count | 2026-10-09..2026-10-23 | partner | partner=Example Pizza | - | 3 of 3",
            "- count | 2026-10-09..2026-10-23 | partner | quantity=2 | - | 3 of 3",
            "- count | 2026-10-08..2026-10-22 | activity | mode=car | weekday=Thu | 3 of 3",
            "- count | 2026-10-06..2026-10-20 | activity | mode=car | weekday=Tue | 3 of 3",
        ]
        XCTAssertEqual(Array(result.prefix(6)), six)
        XCTAssertEqual(Array(result.dropFirst(6)), Array(f1.suffix(30)))

        let made = MemoryCounts.ranked(MemoryCounts.candidates(from: Array(f1.prefix(31)), now: TestClock.date(now),
                                                                timeZone: TestClock.zone)).map(\.text)
        XCTAssertEqual(six, made, "the lines are the counting's own")
        for text in six { XCTAssertTrue(readsBack(text), "reads back: \(text)") }
        XCTAssertEqual(summary(six, now), six, "counted alone, they say the same")
        XCTAssertEqual(summary(f1, now), summary(result, now), "the summary before the fold equals the summary after it")
    }

    // MARK: F02, F03 when the fold happens, its window and its date clamp (AC-007)

    func testCMP_F02_RawLinesFoldOnlyPastSixtyAndTheNewestThirtyStay() {
        let w = zzRun("2026-09-01", "2026-10-31")
        XCTAssertEqual(w.count, 61)
        let now = "2026-11-01T09:00"
        let r = ["- count | 2026-09-20..2026-10-01 | zz | k=a | - | 12 of 12"] + zzRun("2026-10-02", "2026-10-31")
        XCTAssertEqual(compaction(now).compact(w), r, "of the 31 folded lines only the 12 from the window start count")
        XCTAssertEqual(compaction(now).compact(r), r, "idempotent")
        XCTAssertEqual(compaction(now).compact(compaction(now).compact(w)), compaction(now).compact(w))
        XCTAssertEqual(compaction(now).compact(Array(w.prefix(60))), Array(w.prefix(60)), "60 raw lines do not fold")

        let old = zzRun("2026-07-01", "2026-08-30")
        XCTAssertEqual(old.count, 61)
        XCTAssertEqual(compaction(now).compact(old), zzRun("2026-08-01", "2026-08-30"), "the folded lines count in nothing")
    }

    func testCMP_F03_ADateAfterTodayIsWrittenAsTheDayOfTheFold() {
        let l1 = "- 2026-12-31 | Thu | 8:00 AM | zz | - | k=a"
        let input = [l1] + zzRun("2026-09-01", "2026-10-30")
        XCTAssertEqual(input.count, 61)
        let tail = zzRun("2026-10-01", "2026-10-30")
        let r3 = compaction("2026-11-01T09:00").compact(input)
        XCTAssertEqual(r3.count, 31)
        XCTAssertEqual(r3, ["- count | 2026-09-20..2026-11-01 | zz | k=a | - | 12 of 12"] + tail, "the booking is written as the day of the fold")
        XCTAssertEqual(compaction("2026-12-13T09:00").compact(r3), r3, "kept on the window start")
        XCTAssertEqual(compaction("2026-12-14T09:00").compact(r3), tail, "left out a day later")
    }

    // MARK: F04 an earlier count line is never reopened (AC-008)

    func testCMP_F04_AnEarlierCountLineIsNeverReopened() {
        let c0 = "- count | 2026-09-20..2026-09-22 | zz | k=a | - | 3 of 3"
        let input = [c0] + zzRun("2026-09-23", "2026-11-22")
        XCTAssertEqual(input.count, 62)
        let now = "2026-11-01T09:00"
        let result = compaction(now).compact(input)
        XCTAssertEqual(counts(result), ["- count | 2026-09-23..2026-10-23 | zz | k=a | - | 31 of 31", c0])
        XCTAssertEqual(Array(result.dropFirst(2)), zzRun("2026-10-24", "2026-11-22"))
        XCTAssertEqual(result.count, 32)
        let sixtyFour = ["- count | 2026-09-20..2026-11-22 | zz | k=a | - | 64 of 64"]
        XCTAssertEqual(summary(input, now), sixtyFour)
        XCTAssertEqual(summary(result, now), sixtyFour)
    }

    // MARK: F05 the append folds in its one write (AC-011)

    func testCMP_F05_TheAppendFoldsInItsOneWrite() throws {
        let sixty = zzRun("2026-09-01", "2026-10-30")
        let newest = try XCTUnwrap(MemoryLine(text: "- 2026-10-31 | Sat | 8:00 AM | zz | - | k=a"))
        let url = tempFolder().appendingPathComponent(MemoryBook.fileName)
        try write(sixty, to: url)
        let writer = CompactCountingWrite()
        let book = MemoryBook(fileURL: url, write: { data, target in try writer.write(data, target) })

        let expected = ["- count | 2026-09-20..2026-10-01 | zz | k=a | - | 12 of 12"] + zzRun("2026-10-02", "2026-10-31")
        let after = book.appending(newest, compaction: compaction("2026-11-01T09:00"))
        XCTAssertEqual(after?.count, 31)
        XCTAssertEqual(after, expected)
        XCTAssertEqual(fileText(url), lineFed(expected))
        XCTAssertEqual(writer.calls, 1, "one write")

        let plain = tempFolder().appendingPathComponent(MemoryBook.fileName)
        try write(sixty, to: plain)
        XCTAssertEqual(MemoryBook(fileURL: plain).appending(newest)?.count, 61, "without a compaction the append is SPEC-MEMORY-001's")
    }

    // MARK: A01 a changed habit (AC-009)

    func testCMP_A01_AChangedHabitShowsAtOnceAndTheOldCountLeavesWithTheWindow() {
        let ta = "- count | 2026-09-20..2026-10-11 | activity | mode=transit | - | 16 of 20"
        let gym = ["2026-10-12", "2026-10-14", "2026-10-16", "2026-10-19", "2026-10-28", "2026-10-31"]
            .map { raw($0, "6:00 PM", "activity", "Example Gym", "mode=car") }
        let a = [ta] + gym

        let both = [
            "- count | 2026-09-20..2026-10-11 | activity | mode=transit | - | 16 of 26",
            "- count | 2026-10-12..2026-10-31 | activity | mode=car | part=evening | 6 of 6",
            "- count | 2026-10-12..2026-10-31 | activity | mode=car | place=Example Gym | 6 of 6",
            "- count | 2026-10-12..2026-10-31 | activity | place=Example Gym | - | 6 of 6",
        ]
        XCTAssertEqual(summary(a, "2026-11-01T09:00"), both, "the new habit shows in two slices at once")
        XCTAssertEqual(summary(a, "2026-11-22T09:00"), both)
        XCTAssertEqual(summary(a, "2026-11-23T09:00"), [
            "- count | 2026-10-12..2026-10-31 | activity | mode=car | - | 6 of 6",
            "- count | 2026-10-12..2026-10-31 | activity | place=Example Gym | - | 6 of 6",
        ])
        XCTAssertEqual(compaction("2026-11-22T09:00").compact(a), a, "its last date is the window start")
        XCTAssertEqual(compaction("2026-11-23T09:00").compact(a), gym)
    }

    // MARK: C01, C02 the caps and the file bound (AC-010)

    func testCMP_C01_CountLinesStopAtFortyStrongestFirst() {
        func x(_ n: Int) -> String { "- count | 2026-10-01..2026-10-31 | zz | k=v" + String(format: "%02d", n) + " | - | \(n) of \(n)" }
        let z = "- count | 2026-10-01..2026-10-31 | zz | k=u20 | - | 20 of 20"
        let y = "- count | 2026-10-01..2026-10-30 | zz | k=w20 | - | 20 of 20"
        let o = "- count | 2026-08-01..2026-09-19 | zz | k=old | - | 50 of 50"
        let e = "- count | 2026-08-01..2026-09-20 | zz | k=edge | - | 45 of 45"
        let input = (3...44).map(x) + [z, y, o, e]
        XCTAssertEqual(input.count, 46)
        var expected: [String] = [e]
        expected += (21...44).reversed().map(x)
        expected += [z, x(20), y]
        expected += (8...19).reversed().map(x)
        let result = compaction("2026-11-01T09:00").compact(input)
        XCTAssertEqual(result.count, 40)
        XCTAssertEqual(result, expected, "O is before the window, E is on its start, X3 to X7 are past the cap")
    }

    func testCMP_C02_TheFileStaysBoundedAndUnknownLinesAreNotKept() throws {
        let now = "2026-11-01T09:00"
        let kept = "- 2026-10-30 | Fri | 8:00 AM | zz | - | k=a"
        let unknown = [
            "- count | 2026-09-07 | 2026-09-25 | activity | Mon Wed Fri Sat | mode=transit | 10 of 12",
            "- count | 2026-09-01 | 2026-09-30 | mode=transit | 3 of 4",
            "- count | 2026-10-01..2026-10-20 | zz | k=a | 9 of 9",
            "- zz | broken",
        ]
        XCTAssertEqual(compaction(now).compact(unknown + [kept]), [kept])

        let bound = (0..<40).map { index in
            "- count | 2026-10-01..2026-10-31 | " + String(repeating: "z", count: 20) + " | " + String(repeating: "k", count: 20)
                + "=" + String(repeating: "v", count: 60) + " | place=" + String(repeating: "p", count: 58)
                + String(format: "%02d", index) + " | 9999 of 9999"
        }
        for text in bound { XCTAssertTrue(readsBack(text), "control: a count line of 223 code points") }
        func big(_ day: String) throws -> String {
            let fields = ["a", "b", "c", "d"].map { (String(repeating: $0, count: 20), String(repeating: "x", count: 60)) }
            return try XCTUnwrap(MemoryLine.make(kind: String(repeating: "r", count: 20), at: TestClock.date(day + "T10:00"),
                                                 zone: TestClock.zone, place: String(repeating: "q", count: 60), fields: fields)).text
        }
        let sixtyBig = try Days.run("2026-09-01", "2026-10-30").map(big)
        let full = bound + sixtyBig
        XCTAssertEqual(sixtyBig.first?.unicodeScalars.count, 451)
        XCTAssertEqual(full.count, 100)
        let same = compaction(now).compact(full)
        XCTAssertEqual(same, full, "100 lines, no fold at 60 raw lines")
        XCTAssertEqual((same.joined(separator: "\n") + "\n").unicodeScalars.count, 36080)

        let over = compaction(now).compact(full + [try big("2026-10-31")])
        XCTAssertLessThanOrEqual(counts(over).count, 40)
        XCTAssertEqual(over.count - counts(over).count, 30, "exactly 30 raw lines, no other line")
        XCTAssertLessThanOrEqual((over.joined(separator: "\n") + "\n").unicodeScalars.count, 36080)

        let twoHundred = zzRun("2026-04-15", "2026-10-31")
        XCTAssertEqual(twoHundred.count, 200)
        XCTAssertEqual(compaction(now).compact(twoHundred),
                       ["- count | 2026-09-20..2026-10-01 | zz | k=a | - | 12 of 12"] + zzRun("2026-10-02", "2026-10-31"))

        let d = "- 2026-10-20 | Tue | 8:00 AM | zz | - | k=a"
        let copies = Array(repeating: d, count: 30)
        XCTAssertEqual(compaction(now).compact(Array(repeating: d, count: 10_029)),
                       ["- count | 2026-10-20..2026-10-20 | zz | k=a | - | 9999 of 9999"] + copies)
        XCTAssertEqual(compaction(now).compact(Array(repeating: d, count: 10_030)), copies,
                       "the line of 10000 of 10000 is not written, the reader would refuse it")
    }

    // MARK: G01 no kind is named (AC-014)

    func testCMP_G01_AnUnregisteredKindFoldsWithNoCodeChange() {
        let tail = " | 12:15 PM | zz_newkind | Salad Place | item=Green Bowl | count="
        let g = ["2026-10-09", "2026-10-16", "2026-10-23"].map { "- \($0) | Fri" + tail + "2 | color=teal | size=large" }
            + ["2026-10-12", "2026-10-19", "2026-10-26"].map { "- \($0) | Mon" + tail + "1 | color=teal | size=large" }
        let input = g + zfFiller("2026-10-01", "2026-10-25", from: 1) + zfFiller("2026-10-01", "2026-10-30", from: 26)
        XCTAssertEqual(input.count, 61)
        let result = counts(compaction("2026-11-01T09:00").compact(input))
        XCTAssertEqual(result, [
            "- count | 2026-10-09..2026-10-26 | zz_newkind | color=teal | - | 6 of 6",
            "- count | 2026-10-09..2026-10-26 | zz_newkind | item=Green Bowl | - | 6 of 6",
            "- count | 2026-10-09..2026-10-26 | zz_newkind | place=Salad Place | - | 6 of 6",
            "- count | 2026-10-09..2026-10-26 | zz_newkind | size=large | - | 6 of 6",
            "- count | 2026-10-09..2026-10-23 | zz_newkind | count=2 | weekday=Fri | 3 of 3",
            "- count | 2026-10-12..2026-10-26 | zz_newkind | count=1 | - | 3 of 6",
        ])

        // The text check: after the pieces of G and the fixed forms are taken out, only spaces and separators are left.
        func residue(_ line: String) -> String {
            var text = String(line.dropFirst(2))
            for field in ["item=Green Bowl", "count=2", "count=1", "color=teal", "size=large", "place=Salad Place",
                          "weekday=Fri", "weekday=Mon", "part=morning", "part=afternoon", "part=evening", "part=night",
                          "zz_newkind"] {
                text = text.replacingOccurrences(of: field, with: "")
            }
            for pattern in ["[0-9]{4}-[0-9]{2}-[0-9]{2}\\.\\.[0-9]{4}-[0-9]{2}-[0-9]{2}", "count", "of", "(?<=\\s)-(?=\\s)", "[0-9]+"] {
                text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            return text.filter { $0 != " " && $0 != "|" }
        }
        for line in result { XCTAssertEqual(residue(line), "", "nothing but pieces of G and the fixed forms: \(line)") }
        XCTAssertNotEqual(residue("- count | 2026-10-09..2026-10-26 | zz_newkind | note=Lunch with Ann | - | 6 of 6"), "", "control: a foreign field fails")
        XCTAssertNotEqual(residue("- count | 2026-10-09..2026-10-26 | zz_newkind | color=red | - | 6 of 6"), "", "control: a foreign value fails")
    }

    // MARK: H01-H03 the Store (AC-011, AC-012, AC-013)

    private var s0: String { "- count | 2026-08-25..2026-09-01 | zz | k=b | - | 3 of 3" }
    private var fold: String { "- count | 2026-08-20..2026-08-31 | zz | k=a | - | 12 of 12" }
    private var mealLine: String { "- 2026-10-01 | Thu | 12:30 PM | meal | Example Diner" }

    private func seedS0AndSixty() throws {
        try write([s0] + zzRun("2026-08-01", "2026-09-29"), to: supportMemoryURL)
    }

    func testCMP_H01_TheStoreFoldsOnTheSixtyFirstChoiceWithItsOwnClock() throws {
        _ = EmptyStore.make()
        try seedS0AndSixty()
        let s = launched()
        XCTAssertEqual(s.memoryLines.count, 61, "control: the seeded file is read as it is")
        s.addMeal(category: .diningOut, title: "SENTINEL-TITLE-9", place: diner, loggedAt: TestClock.date("2026-10-01T12:30"))
        XCTAssertEqual(s.meals.count, 1)
        XCTAssertEqual(s.memoryLines.count, 32)
        XCTAssertEqual(s.memoryLines, [fold, s0] + zzRun("2026-09-01", "2026-09-29") + [mealLine])
        XCTAssertEqual(fileText(supportMemoryURL), lineFed(s.memoryLines))
    }

    func testCMP_H02_AFailedWriteLeavesTheFileAndTheSaveAndAnUnreadableFileIsNotCompacted() throws {
        _ = EmptyStore.make()
        let sixty = zzRun("2026-08-01", "2026-09-29")
        try write(sixty, to: supportMemoryURL)
        let working = launched()
        working.addMeal(category: .diningOut, title: "SENTINEL-TITLE-9", place: diner, loggedAt: TestClock.date("2026-10-01T12:30"))
        XCTAssertEqual(working.memoryLines.count, 31, "control: a working writer folds")

        _ = EmptyStore.make()
        let f2 = tempFolder().appendingPathComponent(MemoryBook.fileName)
        try write(sixty, to: f2)
        let before = try Data(contentsOf: f2)
        let failing = Store(notifications: NotificationManager(),
                            memory: MemoryBook(fileURL: f2, write: { _, _ in throw CompactWriteFailure() }))
        failing.memoryNow = { TestClock.date("2026-10-01T09:00") }
        failing.memoryTimeZone = { TestClock.zone }
        failing.addMeal(category: .diningOut, title: "SENTINEL-TITLE-9", place: diner, loggedAt: TestClock.date("2026-10-01T12:30"))
        XCTAssertEqual(failing.meals.count, 1, "the save stands")
        XCTAssertEqual(failing.memoryLines, sixty)
        XCTAssertEqual(try Data(contentsOf: f2), before)

        let f3 = tempFolder().appendingPathComponent(MemoryBook.fileName)
        let bad = Data([0xFF, 0xFE, 0x0A])
        try bad.write(to: f3)
        let line = try XCTUnwrap(MemoryLine(text: mealLine))
        XCTAssertNil(MemoryBook(fileURL: f3).appending(line, compaction: compaction("2026-10-01T09:00")))
        XCTAssertEqual(try Data(contentsOf: f3), bad)
    }

    func testCMP_H03_ACountLineIsListedDeletedAloneAndClearedByDeleteAll() throws {
        _ = EmptyStore.make()
        try seedS0AndSixty()
        let s = launched()
        s.addMeal(category: .diningOut, title: "SENTINEL-TITLE-9", place: diner, loggedAt: TestClock.date("2026-10-01T12:30"))
        XCTAssertEqual(Array(s.memoryLines.prefix(2)), [fold, s0])
        XCTAssertEqual(MemoryLine.display(fold), "count | 2026-08-20..2026-08-31 | zz | k=a | - | 12 of 12")
        XCTAssertEqual(summary(s.memoryLines, "2026-10-01T09:00"), ["- count | 2026-08-20..2026-09-29 | zz | k=a | - | 41 of 44"])

        let withS0 = s.memoryLines
        s.deleteMemoryLine(at: 1)
        XCTAssertEqual(s.memoryLines, Array(withS0.enumerated().filter { $0.offset != 1 }.map(\.element)))
        XCTAssertEqual(s.memoryLines.count, 31)
        XCTAssertEqual(fileText(supportMemoryURL), lineFed(s.memoryLines))
        XCTAssertEqual(summary(s.memoryLines, "2026-10-01T09:00"), ["- count | 2026-08-20..2026-09-29 | zz | k=a | - | 41 of 41"])

        s.addMeal(category: .diningOut, title: "SENTINEL-TITLE-9", place: diner, loggedAt: TestClock.date("2026-10-02T12:30"))
        XCTAssertEqual(s.memoryLines.count, 32)
        XCTAssertEqual(s.memoryLines.first, fold)
        XCTAssertFalse(s.memoryLines.contains(s0), "a deleted count line is not rebuilt")
        XCTAssertEqual(Array(s.memoryLines.suffix(2)), [mealLine, "- 2026-10-02 | Fri | 12:30 PM | meal | Example Diner"])

        _ = EmptyStore.make()
        try write(zzRun("2026-08-01", "2026-10-01"), to: supportMemoryURL)
        let r = launched()
        XCTAssertEqual(r.memoryLines.count, 62, "no compaction at launch")
        r.deleteMemoryLine(at: 0)
        XCTAssertEqual(r.memoryLines.count, 61)
        XCTAssertTrue(counts(r.memoryLines).isEmpty, "no compaction on delete")
        r.deleteEverythingForTesting()
        XCTAssertEqual(r.memoryLines, [])
        XCTAssertFalse(fileText(supportMemoryURL).components(separatedBy: "\n").contains { $0.hasPrefix("- ") })
    }
}
