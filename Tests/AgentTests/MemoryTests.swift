import XCTest
@testable import besir

/// A memory file write that always fails.
struct MemoryWriteFailure: Error {}

/// SPEC-MEMORY-001 (card t74): the memory line and its cleaning, the memory file and its cap, the four save points, a failed
/// write, the Settings delete and Delete All. Every test that reads a Store's lines first sets its zone to `TestClock.zone`.
@MainActor
final class MemoryTests: XCTestCase {
    // MARK: Fixed values

    private let zone = TestClock.zone
    private let gym = Place(name: "Example Gym", address: "SENTINEL-ADDRESS-1", latitude: 37.1234, longitude: -122.5678)
    private let office = Place(name: "Example Office", address: "SENTINEL-ADDRESS-2", latitude: 37.2345, longitude: -122.6789)
    private let diner = Place(name: "Example Diner", address: "SENTINEL-ADDRESS-3", latitude: 37.3456, longitude: -122.7891)
    private let origin = Place(name: "SENTINEL-ORIGIN-1", address: "SENTINEL-ADDRESS-4", latitude: 37.4567, longitude: -122.8912)

    private let mealLine = "- 2026-10-27 | Tue | 12:30 PM | meal | Example Diner"
    private let tripLine = "- 2026-10-30 | Fri | 9:00 AM | trip | Example Office | mode=bicycle"
    private let countLine = "- count | 2026-09-01 | 2026-09-30 | mode=transit | 3 of 4"

    // MARK: Helpers

    /// The app's memory file under the test process's throw-away support folder.
    private var memoryURL: URL { AppConfig.supportDirectory.appendingPathComponent("memory.md") }

    private func fileText(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func fileBytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// An empty Store whose memory lines are written in the fixed zone.
    private func emptyStore() -> Store {
        let store = EmptyStore.make()
        store.memoryTimeZone = { TestClock.zone }
        return store
    }

    /// A fresh temporary folder, removed when the test ends.
    private func tempFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func assertAbsent(_ needles: [String], in text: String, file: StaticString = #filePath, line: UInt = #line) {
        for needle in needles {
            XCTAssertFalse(text.contains(needle), "the memory file holds \(needle)", file: file, line: line)
        }
    }

    /// A raw line spelled by the test, not by the code under test: a 9:00 AM `trip` to Example Office by car on a local day.
    private func rawTrip(on day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd' | 'EEE"
        return "- \(formatter.string(from: day)) | 9:00 AM | trip | Example Office | mode=car"
    }

    /// `make` at 2026-10-30 12:15 in the fixed zone, kind `meal` and place `X` unless given; its text or nil.
    private func made(_ fields: [(String, String)], kind: String = "meal", place: String? = "X") -> String? {
        MemoryLine.make(kind: kind, at: TestClock.date("2026-10-30T12:15"), zone: zone, place: place, fields: fields)?.text
    }

    // MARK: F01-F03 the line (AC-001, AC-002)

    func testMEM_F01_ALineIsDateWeekdayTimeKindPlaceThenItsFields() {
        let evening = TestClock.date("2026-10-28T19:00")
        let both = [("mode", "transit"), ("return_mode", "car")]
        XCTAssertEqual(MemoryLine.make(kind: "activity", at: evening, zone: zone, place: "Example Cafe", fields: both)?.text,
                       "- 2026-10-28 | Wed | 7:00 PM | activity | Example Cafe | mode=transit | return_mode=car")
        // The 12-hour edges.
        XCTAssertEqual(MemoryLine.make(kind: "activity", at: TestClock.date("2026-10-28T00:05"), zone: zone, place: "Example Cafe",
                                       fields: [])?.time, "12:05 AM")
        XCTAssertEqual(MemoryLine.make(kind: "activity", at: TestClock.date("2026-10-28T12:00"), zone: zone, place: "Example Cafe",
                                       fields: [])?.time, "12:00 PM")
        // The same instant in another zone: the date, the weekday and the time are those of the given zone.
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(MemoryLine.make(kind: "activity", at: evening, zone: seoul, place: "Example Cafe", fields: both)?.text,
                       "- 2026-10-29 | Thu | 11:00 AM | activity | Example Cafe | mode=transit | return_mode=car")
        // No place with a field: the place is `-`. No place and no field: no line.
        let placeless = MemoryLine.make(kind: "partner", at: evening, zone: zone, place: nil, fields: [("partner", "Example Tables")])
        XCTAssertEqual(placeless?.place, "-")
        XCTAssertEqual(placeless?.text, "- 2026-10-28 | Wed | 7:00 PM | partner | - | partner=Example Tables")
        XCTAssertNil(MemoryLine.make(kind: "activity", at: evening, zone: zone, place: nil, fields: []))
        // A place with no field is a line.
        XCTAssertEqual(made([]), "- 2026-10-30 | Fri | 12:15 PM | meal | X")
    }

    func testMEM_F02_AnUnregisteredKindRoundTripsWithNoKindSpecificCode() throws {
        let fields = [("item", "Green Bowl"), ("count", "2"), ("color", "teal")]
        let line = MemoryLine.make(kind: "zz_newkind", at: TestClock.date("2026-10-30T12:15"), zone: zone, place: "Salad Place",
                                   fields: fields)
        XCTAssertEqual(line?.text, "- 2026-10-30 | Fri | 12:15 PM | zz_newkind | Salad Place | item=Green Bowl | count=2 | color=teal")
        let read = MemoryLine(text: line?.text ?? "")
        XCTAssertNotNil(read)
        XCTAssertEqual(read, line)
        XCTAssertEqual(read?.fields.map(\.key), ["item", "count", "color"])
        XCTAssertEqual(read?.fields.map(\.value), ["Green Bowl", "2", "teal"])

        // Writer rules.
        let base = "- 2026-10-30 | Fri | 12:15 PM | meal | X"
        XCTAssertEqual(made([("a", "1"), ("b", "2"), ("c", "3"), ("d", "4"), ("e", "5")]), base + " | a=1 | b=2 | c=3 | d=4")
        XCTAssertNil(made([("a", "1")], kind: "Bad Kind"))
        XCTAssertEqual(made([("a", "1"), ("Bad-Key", "2"), ("b", "3")]), base + " | a=1 | b=3")
        XCTAssertEqual(made([("a", "1"), ("a", "2")]), base + " | a=1")
        let equals = try XCTUnwrap(made([("a", "x=y")]))
        XCTAssertEqual(equals, base + " | a=x=y")
        XCTAssertEqual(MemoryLine(text: equals)?.fields, [MemoryField(key: "a", value: "x=y")])
        // A dropped field does not count toward the four, and reserves no key.
        XCTAssertEqual(made([("Bad-Key", "0"), ("a", "1"), ("b", "2"), ("c", "3"), ("d", "4")]), base + " | a=1 | b=2 | c=3 | d=4")
        XCTAssertEqual(made([("a", "   "), ("a", "2")]), base + " | a=2")

        // Reader: positive controls.
        XCTAssertNotNil(MemoryLine(text: base))
        XCTAssertNotNil(MemoryLine(text: "- 2026-10-30 | Fri | 12:15 PM | partner | - | partner=Example Tables"))
        XCTAssertNotNil(MemoryLine(text: base + " | a=1 | b=2 | c=3 | d=4"))
        // Reader refusals.
        var long = base + " | a="
        long += String(repeating: "y", count: 461 - long.unicodeScalars.count)
        XCTAssertEqual(long.unicodeScalars.count, 461)
        let refused = [
            "- 2026-10-30 | Thu | 12:15 PM | meal | X",
            "- 2026-10-30 | Fri | 12:15 | meal | X",
            "- 2026-10-30 | Fri | 12:15 PM | Meal | X",
            "- 2026-10-30 | Fri | 12:15 PM | meal",
            "- 2026-10-30 | Fri | 12:15 PM | meal | X | a=1 | a=2",
            base + " | a=1 | b=2 | c=3 | d=4 | e=5",
            long,
            "- 2026-10-30 | Fri | 12:15 PM | meal | X  Y",
            "- 2026-10-30 | Fri | 12:15 PM | meal | X | a=1\u{200B}",
            countLine,
            "- 2026-10-30 | Fri | 12:15 PM | abcdefghijklmnopqrstu | X",
            "- 2026-02-30 | Mon | 12:15 PM | meal | X",
            "- 2026-10-30 | Fri | 7:60 PM | meal | X",
            "- 2026-10-30 | Fri | 0:15 PM | meal | X",
            "- 2026-10-30 | Fri | 13:15 PM | meal | X",
            "- 2026-10-30 | Fri | 07:15 PM | meal | X",
            "- 2026-10-30 | Fri | 12:15 PM | meal | ",
            "- 2026-10-30 | Fri | 12:15 PM | meal | X | =1",
            "- 2026-10-30 | Fri | 12:15 PM | meal | X | a=",
            "2026-10-30 | Fri | 12:15 PM | meal | X",
        ]
        for text in refused {
            XCTAssertNil(MemoryLine(text: text), text)
        }
    }

    func testMEM_F03_EveryStoredStringIsCleaned() throws {
        XCTAssertEqual(MemoryLine.clean("Tartine\nBakery|Mission\u{200B}"), "Tartine Bakery Mission")
        XCTAssertEqual(made([], place: "Tartine\nBakery|Mission\u{200B}"), "- 2026-10-30 | Fri | 12:15 PM | meal | Tartine Bakery Mission")
        XCTAssertEqual(MemoryLine.clean("Example\u{200E}Cafe"), "Example Cafe")
        XCTAssertEqual(MemoryLine.clean("Example \u{200E} Cafe"), "Example Cafe")
        XCTAssertEqual(MemoryLine.clean("Green\u{00A0}\u{3000}Bowl"), "Green Bowl")
        XCTAssertEqual(MemoryLine.clean("  Green \t Bowl  "), "Green Bowl")
        // Cut at 60 code points, then trimmed again.
        XCTAssertEqual(MemoryLine.clean(String(repeating: "a", count: 61)), String(repeating: "a", count: 60))
        XCTAssertEqual(MemoryLine.clean(String(repeating: "a", count: 59) + " b"), String(repeating: "a", count: 59))
        let emoji = try XCTUnwrap(MemoryLine.clean(String(repeating: "\u{1F600}", count: 61)))
        XCTAssertEqual(emoji, String(repeating: "\u{1F600}", count: 60))
        XCTAssertEqual(emoji.unicodeScalars.count, 60)
        // Blanks.
        XCTAssertNil(MemoryLine.clean("    "))
        XCTAssertNil(MemoryLine.clean("\u{7}"))
        XCTAssertEqual(MemoryLine.make(kind: "meal", at: TestClock.date("2026-10-30T12:15"), zone: zone, place: "    ",
                                       fields: [("a", "1")])?.place, "-")
        XCTAssertEqual(made([("a", "\u{7}")]), "- 2026-10-30 | Fri | 12:15 PM | meal | X")
        XCTAssertEqual(made([("a", "one\ntwo | three")]), "- 2026-10-30 | Fri | 12:15 PM | meal | X | a=one two three")
        // No made line holds a line feed or more separators than its fields need.
        let samples: [(String?, Int)] = [
            (made([("a", "x\ny"), ("b", "p|q")], place: "A\nB | C"), 2),
            (made([], place: "line\u{2028}break"), 0),
            (made([("k", "v\u{2029}w")]), 1),
        ]
        for (text, fieldCount) in samples {
            let line = try XCTUnwrap(text)
            XCTAssertFalse(line.contains("\n"), line)
            XCTAssertEqual(line.components(separatedBy: " | ").count - 1, 4 + fieldCount, line)
        }
        // The longest line the writer can make is 451 code points.
        let longest = MemoryLine.make(kind: "abcdefghijklmnopqrst", at: TestClock.date("2026-10-30T12:15"), zone: zone,
                                      place: String(repeating: "p", count: 70),
                                      fields: ["a", "b", "c", "d"].map { (String(repeating: $0, count: 20), String(repeating: "v", count: 70)) })
        XCTAssertEqual(longest?.text.unicodeScalars.count, 451)
        XCTAssertNotNil(MemoryLine(text: longest?.text ?? ""))
    }

    // MARK: B01-B02 the file (AC-003)

    func testMEM_B01_TheFirstWrittenRawLineGoesPastTwoHundredAndACountLineStays() throws {
        let url = tempFolder().appendingPathComponent(MemoryBook.fileName)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let newYear = TestClock.date("2026-01-01T09:00")
        let latest = rawTrip(on: TestClock.date("2026-12-31T09:00"))
        let daily = (0..<199).map { rawTrip(on: calendar.date(byAdding: .day, value: $0, to: newYear)!) }
        let seeded = [countLine, latest] + daily
        try Data(seeded.map { $0 + "\n" }.joined().utf8).write(to: url)

        let book = MemoryBook(fileURL: url)
        XCTAssertEqual(book.lines().count, 201)
        XCTAssertEqual(book.lines(), seeded)
        let newLine = try XCTUnwrap(MemoryLine(text: rawTrip(on: TestClock.date("2026-11-01T09:00"))))
        let after = try XCTUnwrap(book.appending(newLine))
        XCTAssertEqual(after.count, 201, "the count line and 200 raw lines")
        XCTAssertEqual(after.first, countLine)
        XCTAssertFalse(after.contains(latest), "the first-written raw line goes, though its date is the latest")
        XCTAssertEqual(after[1], daily[0], "the 2026-01-01 line, the earliest date, stays")
        XCTAssertEqual(after.last, newLine.text)
        XCTAssertEqual(book.lines(), after)
        // Removing the item at index 0 removes the count line and nothing else.
        let removed = try XCTUnwrap(book.removing(at: 0))
        XCTAssertEqual(removed, Array(after.dropFirst()))
        XCTAssertEqual(book.lines(), removed)
    }

    func testMEM_B02_TheFileIsItemLinesEachEndedByALineFeed() throws {
        let store = emptyStore()
        let lunch = TestClock.date("2026-10-27T12:30")
        store.addMeal(category: .diningOut, title: "Lunch", place: diner, loggedAt: lunch)
        store.addMeal(category: .diningOut, title: "Lunch", place: diner, loggedAt: lunch)
        XCTAssertEqual(store.memoryLines.count, 2)
        XCTAssertEqual(store.memoryLines, [mealLine, mealLine], "two equal choices are two lines")
        XCTAssertEqual(MemoryBook.fileName, "memory.md")
        XCTAssertEqual(fileBytes(memoryURL), Data((mealLine + "\n" + mealLine + "\n").utf8))
        XCTAssertEqual(Store(notifications: NotificationManager()).memoryLines, [mealLine, mealLine], "a relaunch reads the same lines")

        // A line that is not an item line, and an item line past 460 code points, is neither read nor written back.
        let tooLong = "- " + String(repeating: "z", count: 459)
        XCTAssertEqual(tooLong.unicodeScalars.count, 461)
        try Data(("# heading\n" + mealLine + "\n\n" + tooLong + "\n").utf8).write(to: memoryURL)
        let book = MemoryBook(fileURL: memoryURL)
        XCTAssertEqual(book.lines(), [mealLine])
        let trip = try XCTUnwrap(MemoryLine(text: tripLine))
        XCTAssertEqual(book.appending(trip), [mealLine, tripLine])
        XCTAssertEqual(fileText(memoryURL), mealLine + "\n" + tripLine + "\n")

        // A file that is not UTF-8 shows no lines and is left as it is by an add and a single delete; only removingAll replaces it.
        let unreadable = tempFolder().appendingPathComponent(MemoryBook.fileName)
        let badBytes = Data([0xFF, 0xFE, 0x0A])
        try badBytes.write(to: unreadable)
        let badBook = MemoryBook(fileURL: unreadable)
        XCTAssertEqual(badBook.lines(), [])
        XCTAssertNil(badBook.appending(trip))
        XCTAssertNil(badBook.removing(at: 0))
        XCTAssertEqual(fileBytes(unreadable), badBytes)
        XCTAssertEqual(badBook.removingAll(), [])
        XCTAssertEqual(fileBytes(unreadable), Data())
        XCTAssertEqual(badBook.appending(trip), [tripLine])
        XCTAssertEqual(fileText(unreadable), tripLine + "\n")
    }

    // MARK: S01, A01 the activity save point (AC-004)

    func testMEM_S01_AnActivityWithAPlaceWritesOneLineAndItsLegsNone() async {
        let store = emptyStore()
        await store.addActivityWithTravel(title: "SENTINEL-TITLE-1", location: gym, startDate: TestClock.date("2026-10-29T07:00"),
                                          endDate: TestClock.date("2026-10-29T08:00"), travelFrom: origin, returnTo: origin,
                                          outboundMode: .transit, returnMode: .car, bufferMinutes: 0, notifyLeadMinutes: 0,
                                          travelSecondsHint: 600)
        XCTAssertEqual(store.events.count, 2, "positive control: both legs were made")
        XCTAssertEqual(store.memoryLines, ["- 2026-10-29 | Thu | 7:00 AM | activity | Example Gym | mode=transit | return_mode=car"])
        let text = fileText(memoryURL)
        XCTAssertFalse(text.isEmpty, "positive control: the file was written")
        assertAbsent(["SENTINEL-TITLE-1", "SENTINEL-ADDRESS-1", "SENTINEL-ORIGIN-1", "SENTINEL-ADDRESS-4", "37.1234", "trip"], in: text)

        // An activity with no place writes no line.
        await store.addActivityWithTravel(title: "SENTINEL-TITLE-1", location: nil, startDate: TestClock.date("2026-10-29T09:00"),
                                          endDate: TestClock.date("2026-10-29T10:00"), travelFrom: origin, returnTo: origin,
                                          outboundMode: .transit, returnMode: .car, bufferMinutes: 0, notifyLeadMinutes: 0,
                                          travelSecondsHint: 600)
        XCTAssertEqual(store.activities.count, 2, "positive control: the place-less activity was stored")
        XCTAssertEqual(store.memoryLines.count, 1)
    }

    func testMEM_A01_TheChatCardWritesOnlyAfterConfirmAndEqualsTheHandLine() async throws {
        let rig = PlaceRig()
        rig.store.memoryTimeZone = { TestClock.zone }
        await rig.seedBasics()
        let card = try XCTUnwrap(rig.create(place: "p1", route: "r1").card)
        XCTAssertEqual(rig.store.memoryLines, [], "nothing while the card is open")
        _ = await card.resolve(.confirm)
        XCTAssertEqual(rig.store.activities.count, 1, "positive control: Confirm stored the activity")
        let chat = "- 2026-10-28 | Wed | 7:00 PM | activity | Example Cafe | mode=transit"
        XCTAssertEqual(rig.store.memoryLines, [chat])

        // A card resolved with Cancel writes nothing.
        let cancelled = try XCTUnwrap(rig.create(place: "p1", route: "r1").card)
        _ = await cancelled.resolve(.cancel)
        XCTAssertEqual(rig.store.memoryLines, [chat])

        // The same choice made by hand, under another title, writes the same line.
        await rig.store.addActivityWithTravel(title: "Another title", location: PlaceFixture.places("places-search-three")[0],
                                              startDate: TestClock.date(PlaceRig.start), endDate: TestClock.date(PlaceRig.end),
                                              travelFrom: PlaceFixture.device, returnTo: nil, outboundMode: .transit,
                                              returnMode: .transit, bufferMinutes: 0, notifyLeadMinutes: 0, travelSecondsHint: 600)
        XCTAssertEqual(rig.store.activities.count, 2)
        XCTAssertEqual(rig.store.memoryLines, [chat, chat])
        assertAbsent(["Team sync", "Another title"], in: fileText(memoryURL))
    }

    // MARK: S02 the trip save point (AC-005)

    func testMEM_S02_AHandMadeTripWritesOneLineAndALegNone() async {
        let store = emptyStore()
        await store.addEvent(title: "SENTINEL-TITLE-2", origin: origin, destination: office,
                             arrivalDate: TestClock.date("2026-10-30T09:00"), mode: .bicycle, bufferMinutes: 5,
                             notifyLeadMinutes: 10, travelSecondsHint: 600)
        XCTAssertEqual(store.memoryLines, [tripLine])
        let text = fileText(memoryURL)
        XCTAssertFalse(text.isEmpty, "positive control: the file was written")
        assertAbsent(["SENTINEL-ORIGIN-1", "SENTINEL-TITLE-2", "SENTINEL-ADDRESS-2", "SENTINEL-ADDRESS-4"], in: text)

        // An event made for an activity is a leg and writes no line.
        await store.addEvent(title: "SENTINEL-TITLE-2", origin: origin, destination: office,
                             arrivalDate: TestClock.date("2026-10-30T11:00"), mode: .bicycle, bufferMinutes: 5,
                             notifyLeadMinutes: 10, travelSecondsHint: 600, linkedActivityId: UUID())
        XCTAssertEqual(store.events.count, 2, "positive control: the linked event was stored")
        XCTAssertEqual(store.memoryLines, [tripLine])
    }

    // MARK: P01-P02 the partner record point (AC-006)

    func testMEM_P01_APartnerBookingWritesOnePartnerLineAndNoActivityLine() async throws {
        let rig = PartnerRig()
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        rig.store.memoryTimeZone = { TestClock.zone }
        let built = await rig.card()
        let card = try XCTUnwrap(built)
        XCTAssertEqual(rig.store.memoryLines, [], "nothing while the card is open")
        _ = await card.resolve(.confirm)
        XCTAssertEqual(rig.store.activities.count, 1, "positive control: the booking stored its entry")
        XCTAssertEqual(rig.store.memoryLines, ["- 2026-10-28 | Wed | 7:00 PM | partner | - | partner=Example Tables | quantity=2"])
        assertAbsent(["Sam", "Pasta Palace", "EX-AB12CD", "6000", "booking", "/booking", "activity"], in: fileText(memoryURL))

        // A declined request writes no line.
        let declining = PartnerRig()
        let declinedFolder = declining.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: declinedFolder) }
        declining.store.memoryTimeZone = { TestClock.zone }
        let declinedBuilt = await declining.card(PartnerRig.Fill(party: 9))
        let declinedCard = try XCTUnwrap(declinedBuilt)
        _ = await declinedCard.resolve(.confirm)
        XCTAssertEqual(declinedCard.mark, .notApplied, "positive control: the stub declined")
        XCTAssertTrue(declining.store.activities.isEmpty)
        XCTAssertEqual(declining.store.memoryLines, [])
        XCTAssertFalse(fileText(memoryURL).contains("- "))
    }

    func testMEM_P02_APartnerBookingWithAPlaceAndTravelWritesThePlaceAndTheMode() async throws {
        let rig = TravelRig(shapes: [.placeTables()])
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        rig.store.memoryTimeZone = { TestClock.zone }
        let built = await rig.card(.init(restaurant: nil))
        let card = try XCTUnwrap(built)
        let fields = try XCTUnwrap(card.fieldCard)
        fields.search("restaurant", "Pasta")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(fields.choosePlace("restaurant", PartnerPlaceFixture.branches[1]))
        XCTAssertTrue(fields.chooseOption(AgentPartner.cardTravelKey, AgentFieldSpec.onValue))
        XCTAssertTrue(fields.chooseOption(AgentPartner.cardModeKey, TransportMode.transit.rawValue))
        _ = await card.resolve(.confirm)
        XCTAssertEqual(rig.store.activities.count, 1, "positive control: the entry")
        XCTAssertEqual(rig.store.events.count, 1, "positive control: its leg")
        XCTAssertEqual(rig.store.memoryLines,
                       ["- 2026-10-28 | Wed | 7:00 PM | partner | Pasta Palace | mode=transit | partner=Example Tables | quantity=2"])
        assertAbsent(["22 Oak Avenue", "SENTINEL-HOME-1", "SENTINEL-HOME-ADDRESS-1", "Sam", "37.74", "activity"], in: fileText(memoryURL))
    }

    // MARK: S03 the meal save point (AC-007)

    func testMEM_S03_AnIAteHereMealWritesOneLineAndALinkedMealNone() {
        let store = emptyStore()
        let lunch = TestClock.date("2026-10-27T12:30")
        store.addMeal(category: .diningOut, title: "SENTINEL-TITLE-3", place: diner, loggedAt: lunch)
        XCTAssertEqual(store.memoryLines, [mealLine])
        // A meal linked to an activity or an event, and a meal with no place, write no line.
        store.addMeal(category: .diningOut, title: "SENTINEL-TITLE-3", place: diner, activityId: UUID(), loggedAt: lunch)
        store.addMeal(category: .diningOut, title: "SENTINEL-TITLE-3", place: diner, scheduledEventId: UUID(), loggedAt: lunch)
        store.addMeal(category: .diningOut, title: "SENTINEL-TITLE-3", place: nil, loggedAt: lunch)
        XCTAssertEqual(store.meals.count, 4, "positive control: every meal was stored")
        XCTAssertEqual(store.memoryLines, [mealLine])
        let text = fileText(memoryURL)
        XCTAssertFalse(text.isEmpty, "positive control: the file was written")
        assertAbsent(["SENTINEL-TITLE-3", "diningOut", "SENTINEL-ADDRESS-3", "37.3456"], in: text)
    }

    // MARK: S04 nowhere else (AC-008)

    private func assertUnchanged(_ store: Store, _ before: [String], _ bytes: Data?, _ step: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.memoryLines, before, step, file: file, line: line)
        XCTAssertEqual(fileBytes(memoryURL), bytes, step, file: file, line: line)
    }

    func testMEM_S04_LegsEditsAndDeletesWriteNoLine() async throws {
        let store = emptyStore()
        store.addMeal(category: .diningOut, title: "Lunch", place: diner, loggedAt: TestClock.date("2026-10-27T12:30"))
        XCTAssertEqual(store.memoryLines.count, 1, "positive control: one meal line")
        let before = store.memoryLines
        let bytes = fileBytes(memoryURL)
        XCTAssertNotNil(bytes)

        let block = ActivityBlock(title: "SENTINEL-TITLE-1", location: gym, startDate: TestClock.date("2026-10-29T07:00"),
                                  endDate: TestClock.date("2026-10-29T08:00"))
        store.activities.append(block)

        let outcome = await store.addLeg(activityId: block.id, role: .arrival, outerPlace: origin, mode: .walk, bufferMinutes: 0,
                                         notifyLeadMinutes: 0, travelSecondsHint: 600)
        guard case .created = outcome else { return XCTFail("addLeg did not create the leg: \(outcome)") }
        assertUnchanged(store, before, bytes, "after addLeg")

        XCTAssertTrue(store.modifyActivity(id: block.id, newStart: TestClock.date("2026-10-29T07:30"),
                                           newEnd: TestClock.date("2026-10-29T08:30")))
        assertUnchanged(store, before, bytes, "after modifyActivity")

        let leg = try XCTUnwrap(store.events.first { $0.linkedActivityId == block.id })
        _ = await store.updateLeg(legId: leg.id, mode: .car, travelSecondsHint: 600)
        XCTAssertEqual(store.events.first { $0.id == leg.id }?.mode, .car, "positive control: the leg changed")
        assertUnchanged(store, before, bytes, "after updateLeg")

        var renamed = try XCTUnwrap(store.activity(id: block.id))
        renamed.title = "SENTINEL-TITLE-2"
        store.updateActivity(renamed)
        XCTAssertEqual(store.activity(id: block.id)?.title, "SENTINEL-TITLE-2", "positive control: the activity changed")
        assertUnchanged(store, before, bytes, "after updateActivity")

        store.deleteActivity(try XCTUnwrap(store.activity(id: block.id)))
        XCTAssertNil(store.activity(id: block.id), "positive control: the activity is gone")
        assertUnchanged(store, before, bytes, "after deleteActivity")
    }

    // MARK: S05 a failed write (AC-009)

    func testMEM_S05_AFailedWriteLeavesTheSaveAndTheList() async throws {
        _ = EmptyStore.make()
        let url = tempFolder().appendingPathComponent(MemoryBook.fileName)
        let seeded = Data((mealLine + "\n").utf8)
        try seeded.write(to: url)
        let failing = MemoryBook(fileURL: url, write: { _, _ in throw MemoryWriteFailure() })
        let store = Store(notifications: NotificationManager(), memory: failing)
        store.memoryTimeZone = { TestClock.zone }
        XCTAssertEqual(store.memoryLines, [mealLine])

        let made = await store.addActivityWithTravel(title: "SENTINEL-TITLE-1", location: gym,
                                                     startDate: TestClock.date("2026-10-29T07:00"),
                                                     endDate: TestClock.date("2026-10-29T08:00"), travelFrom: nil, returnTo: nil,
                                                     outboundMode: .walk, returnMode: .walk, bufferMinutes: 0, notifyLeadMinutes: 0)
        XCTAssertEqual(store.activities.count, 1, "the save stands")
        XCTAssertEqual(store.activities.first?.id, made.activityId)
        XCTAssertEqual(store.memoryLines, [mealLine])
        XCTAssertEqual(fileBytes(url), seeded)

        store.deleteMemoryLine(at: 0)
        XCTAssertEqual(store.memoryLines, [mealLine], "a failed delete keeps the line")
        XCTAssertEqual(fileBytes(url), seeded)

        store.deleteEverythingForTesting()
        XCTAssertTrue(store.activities.isEmpty, "Delete All still removes the activities")
        XCTAssertEqual(store.memoryLines, [mealLine], "a failed emptying keeps the lines")
        XCTAssertEqual(fileBytes(url), seeded)

        // Positive control: the same call with a working memory file writes one line.
        let working = Store(notifications: NotificationManager(),
                            memory: MemoryBook(fileURL: tempFolder().appendingPathComponent(MemoryBook.fileName)))
        working.memoryTimeZone = { TestClock.zone }
        await working.addActivityWithTravel(title: "SENTINEL-TITLE-1", location: gym, startDate: TestClock.date("2026-10-29T07:00"),
                                            endDate: TestClock.date("2026-10-29T08:00"), travelFrom: nil, returnTo: nil,
                                            outboundMode: .walk, returnMode: .walk, bufferMinutes: 0, notifyLeadMinutes: 0)
        XCTAssertEqual(working.memoryLines.count, 1)
    }

    // MARK: S06 the Settings delete (AC-010)

    func testMEM_S06_DeleteRemovesExactlyOneLine() throws {
        _ = EmptyStore.make()
        let url = tempFolder().appendingPathComponent(MemoryBook.fileName)
        try Data((mealLine + "\n" + tripLine + "\n" + mealLine + "\n").utf8).write(to: url)
        let store = Store(notifications: NotificationManager(), memory: MemoryBook(fileURL: url))
        XCTAssertEqual(store.memoryLines.count, 3)

        store.deleteMemoryLine(at: 2)
        XCTAssertEqual(store.memoryLines, [mealLine, tripLine], "the line at that index goes, not the first equal one")
        XCTAssertEqual(fileText(url), mealLine + "\n" + tripLine + "\n")

        store.deleteMemoryLine(at: 99)
        XCTAssertEqual(store.memoryLines, [mealLine, tripLine])
        XCTAssertEqual(fileText(url), mealLine + "\n" + tripLine + "\n")

        XCTAssertEqual(MemoryLine.display(mealLine), "2026-10-27 | Tue | 12:30 PM | meal | Example Diner")
    }

    // MARK: S07 Delete All (AC-011)

    func testMEM_S07_DeleteAllEventsEmptiesTheMemoryFile() async {
        let store = emptyStore()
        store.addMeal(category: .diningOut, title: "Lunch", place: diner, loggedAt: TestClock.date("2026-10-27T12:30"))
        await store.addActivityWithTravel(title: "Workout", location: gym, startDate: TestClock.date("2026-10-29T07:00"),
                                          endDate: TestClock.date("2026-10-29T08:00"), travelFrom: nil, returnTo: nil,
                                          outboundMode: .walk, returnMode: .walk, bufferMinutes: 0, notifyLeadMinutes: 0)
        XCTAssertEqual(store.memoryLines.count, 2)
        XCTAssertEqual(store.activities.count, 1)

        store.deleteEverythingForTesting()
        XCTAssertEqual(store.memoryLines, [])
        XCTAssertFalse(fileText(memoryURL).components(separatedBy: "\n").contains { $0.hasPrefix("- ") })
        XCTAssertTrue(store.activities.isEmpty)
        XCTAssertEqual(Store(notifications: NotificationManager()).memoryLines, [], "a relaunch reads no line")
    }
}
