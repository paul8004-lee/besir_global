import XCTest
@testable import besir

/// The simulated partner as the Worker route behaves: it echoes the request and confirms, except a party over 8.
/// It records every request and can be told to fail instead.
final class EchoPartner {
    enum Mode {
        case worker
        case status(Int, String)
        case error(Error)
    }

    struct WriteFailure: Error {}

    var mode: Mode = .worker
    private(set) var requests: [URLRequest] = []
    /// Runs inside the send call, before the answer is handed back.
    var duringSend: (() -> Void)?

    var send: BookingClient.Send {
        { [self] request in
            requests.append(request)
            duringSend?()
            switch mode {
            case .error(let error):
                throw error
            case .status(let status, let body):
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            case .worker:
                let sent = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                let size = sent["party_size"] as? Int ?? 0
                var answer: [String: Any] = ["partner": "Example Tables", "simulated": true, "restaurant": sent["restaurant"] ?? "",
                                             "party_size": size, "start": sent["start"] ?? ""]
                if size > 8 {
                    answer["status"] = "declined"
                    answer["reason"] = "no_table"
                } else {
                    answer["status"] = "confirmed"
                    answer["reservation_code"] = "EX-AB12CD"
                }
                let data = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    /// The JSON object of the nth request body.
    func body(_ index: Int = 0) -> [String: Any]? {
        guard requests.indices.contains(index), let data = requests[index].httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

final class BookingConfigBox {
    var config: AppConfig
    init(_ config: AppConfig) { self.config = config }
}

enum BookingFixture {
    static let place = Place(name: "Pasta Palace", address: "1 Main Street", latitude: 37.78, longitude: -122.41)
    /// Tomorrow 7 PM in the fixed clock's zone (the clock is 2026-10-27T09:00).
    static let start = "2026-10-28T19:00"
}

/// A toolbox over an empty Store with the fixed clock, a stubbed partner and a connection log on a temporary file.
@MainActor
final class BookingRig {
    let store: Store
    let clock: MutableClock
    let partner: EchoPartner
    let log: ConnectionLog
    let box: BookingConfigBox
    let tools: AgentToolbox
    let folder: URL

    init(config: AppConfig = PlaceSentinel.config, partner: EchoPartner = EchoPartner(), failingLog: Bool = false,
         places: [Place] = [BookingFixture.place]) {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let clock = MutableClock()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("booking-tool-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent(ConnectionLog.fileName)
        let log = failingLog ? ConnectionLog(fileURL: file, write: { _, _ in throw EchoPartner.WriteFailure() })
                             : ConnectionLog(fileURL: file)
        let box = BookingConfigBox(config)
        let toolbox = AgentToolbox(store: store, now: { clock.now }, timeZone: { clock.zone },
                                   booking: { BookingClient(config: box.config, send: partner.send, connections: log) })
        _ = toolbox.registry.register(places)
        self.store = store
        self.clock = clock
        self.partner = partner
        self.log = log
        self.box = box
        self.folder = folder
        tools = toolbox
    }

    static func arguments(_ over: [String: Any] = [:], drop: [String] = []) -> [String: Any] {
        var args: [String: Any] = ["place_id": "p1", "start": BookingFixture.start, "party_size": "2"]
        for (key, value) in over { args[key] = value }
        for key in drop { args.removeValue(forKey: key) }
        return args
    }

    func call(_ args: [String: Any]) -> AgentToolOutcome {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return tools.handle(name: "request_booking", arguments: String(decoding: data, as: UTF8.self))
    }

    /// A card for the usual arguments, or nil when the gate refused.
    func card(_ over: [String: Any] = [:]) -> AgentCard? { call(Self.arguments(over)).card }

    /// A byte-for-byte picture of the schedule.
    var snapshot: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(store.activities)) ?? Data(), as: UTF8.self)
    }
}

/// SPEC-BOOKING-001 AC-BOOKING-004, 005, 006: the declaration, the gate, the card and Confirm.
@MainActor
final class AgentBookingToolTests: XCTestCase {
    private func makeRig(config: AppConfig = PlaceSentinel.config, partner: EchoPartner = EchoPartner(),
                         places: [Place] = [BookingFixture.place]) -> BookingRig {
        let rig = BookingRig(config: config, partner: partner, places: places)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    private enum Text {
        static let place = "Call search_places to find the place, then call request_booking again with the place_id it returns."
        static let start = "Ask the user for the time, then call request_booking again. Do not guess it."
        static let window = "Ask the user to confirm the date, then call request_booking again. The start must be a time that has not passed and be within the next 366 days."
        static let party = "Ask the user how many people the table is for, then call request_booking again. Do not guess it."
        static let unavailable = "Tell the user booking is not available right now. Do not call request_booking again."
        static let notice = "The reservation could not be made. Nothing was added."
        static func wrongType(_ param: String) -> String {
            "Call request_booking again with \(param) as a string. If you do not have it, ask the user; do not guess it."
        }
        static let timeForm = "Call request_booking again with start as a local date-time in the form YYYY-MM-DDTHH:MM, or ask the user."
    }

    private func declarations() -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: AgentTools.declarationsJSON())) as? [[String: Any]]) ?? []
    }

    private func dayText(_ local: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TestClock.zone
        f.dateFormat = "EEE, MMM d, h:mm a"
        return f.string(from: TestClock.date(local))
    }

    private func assertRefused(_ outcome: AgentToolOutcome, _ message: String, _ note: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome.status, "rejected", note, file: file, line: line)
        XCTAssertEqual(outcome.message, message, note, file: file, line: line)
    }

    // MARK: G01-G02 the declaration

    func testBOOKING_G01_SevenDeclarationsTheOldOnesUnchangedAndTheNewOneStrict() throws {
        let decls = declarations()
        XCTAssertEqual(decls.count, 13)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tools", withExtension: "json"))
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(recorded.count, 13)
        for index in 0..<6 {
            XCTAssertTrue((decls[index] as AnyObject).isEqual(recorded[index]), "declaration \(index) changed")
        }
        let booking = try XCTUnwrap(decls.last)
        XCTAssertEqual(booking["name"] as? String, "request_booking")
        XCTAssertEqual(booking["type"] as? String, "function")
        let parameters = try XCTUnwrap(booking["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["place_id", "start", "party_size"])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["place_id", "start", "party_size"])
        for (name, spec) in properties {
            XCTAssertEqual((spec as? [String: Any])?["type"] as? String, "string", name)
        }
    }

    func testBOOKING_G02_TheDescriptionSaysSimulated() throws {
        let booking = try XCTUnwrap(declarations().last)
        let description = try XCTUnwrap(booking["description"] as? String).lowercased()
        XCTAssertTrue(description.contains("simulated"))
    }

    // MARK: G03-G15 the gate

    func testBOOKING_G03_AMissingPlaceIdIsRefused() {
        let rig = makeRig()
        assertRefused(rig.call(BookingRig.arguments(drop: ["place_id"])), Text.place)
        assertRefused(rig.call(BookingRig.arguments(["place_id": "  "])), Text.place, "a blank handle is absent")
        XCTAssertNotNil(rig.card(), "the same call with the handle builds a card")
    }

    func testBOOKING_G04_AnUnknownOrMalformedHandleIsRefused() {
        let rig = makeRig()
        for handle in ["p2", "p9999", "x1", "P1", "p", "p01x", "r1", "1"] {
            assertRefused(rig.call(BookingRig.arguments(["place_id": handle])), Text.place, handle)
        }
    }

    func testBOOKING_G05_AHandleFromBeforeANewChatIsRefused() {
        let rig = makeRig()
        XCTAssertNotNil(rig.card())
        rig.tools.resetConversation()
        assertRefused(rig.call(BookingRig.arguments()), Text.place)
    }

    func testBOOKING_G06_APlaceWithAnEmptySanitizedNameIsRefused() {
        let blank = Place(name: "\u{200B}\u{0007} \n", address: "x", latitude: 1, longitude: 2)
        let rig = makeRig(places: [BookingFixture.place, blank])
        XCTAssertNotNil(rig.card(["place_id": "p1"]))
        assertRefused(rig.call(BookingRig.arguments(["place_id": "p2"])), Text.place)
    }

    func testBOOKING_G07_AMissingStartAsksTheUser() {
        let rig = makeRig()
        assertRefused(rig.call(BookingRig.arguments(drop: ["start"])), Text.start)
        assertRefused(rig.call(BookingRig.arguments(["start": "   "])), Text.start, "a blank start is absent")
    }

    func testBOOKING_G08_ABadStartFormIsRefused() {
        let rig = makeRig()
        for start in ["tomorrow 7pm", "2026-10-28 19:00", "2026-10-28T19:00:00", "2026-02-30T19:00", "2026-10-28T7:00", " 2026-10-28T19:00"] {
            assertRefused(rig.call(BookingRig.arguments(["start": start])), Text.timeForm, start)
        }
    }

    func testBOOKING_G09_AStartThatHasPassedOrIsBeyondTheWindowIsRefused() {
        let rig = makeRig()
        // The clock is 2026-10-27T09:00: the minute itself is allowed, the minute before is not.
        XCTAssertNotNil(rig.card(["start": "2026-10-27T09:00"]))
        assertRefused(rig.call(BookingRig.arguments(["start": "2026-10-27T08:59"])), Text.window, "a minute ago")
        assertRefused(rig.call(BookingRig.arguments(["start": "2026-10-26T19:00"])), Text.window, "yesterday")
        XCTAssertNotNil(rig.card(["start": "2027-10-28T09:00"]), "366 days ahead, to the minute")
        assertRefused(rig.call(BookingRig.arguments(["start": "2027-10-28T09:01"])), Text.window, "a minute past the window")
        assertRefused(rig.call(BookingRig.arguments(["start": "2027-10-29T09:00"])), Text.window, "beyond 366 days")
        XCTAssertFalse(Text.window.contains("past day"), "the booking text does not allow the past day")
    }

    func testBOOKING_G10_AMissingPartySizeAsksTheUser() {
        let rig = makeRig()
        assertRefused(rig.call(BookingRig.arguments(drop: ["party_size"])), Text.party)
        assertRefused(rig.call(BookingRig.arguments(["party_size": ""])), Text.party)
    }

    func testBOOKING_G11_InvalidPartySizesAreRefused() {
        let rig = makeRig()
        for size in ["0", "13", "-2", "2.5", " 2", "2 ", "\u{0662}", "00002", "two", "1e1", "+2", "２"] {
            assertRefused(rig.call(BookingRig.arguments(["party_size": size])), Text.party, size)
        }
    }

    func testBOOKING_G12_ValidPartySizesBuildACard() throws {
        let rig = makeRig()
        for (size, expected) in [("1", 1), ("2", 2), ("12", 12), ("0002", 2), ("08", 8)] {
            let card = try XCTUnwrap(rig.card(["party_size": size]), size)
            XCTAssertEqual(card.lines[3], "Table for \(expected)", size)
        }
        XCTAssertEqual(AgentBooking.parsePartySize("12"), 12)
        XCTAssertNil(AgentBooking.parsePartySize("13"))
    }

    func testBOOKING_G13_ANonStringArgumentIsRefusedWithTheBookingMessage() {
        let rig = makeRig()
        let wrong: [Any] = [5, 2.5, true, false, NSNull(), ["a"], ["a": 1]]
        for param in ["place_id", "start", "party_size"] {
            for value in wrong {
                let outcome = rig.call(BookingRig.arguments([param: value]))
                assertRefused(outcome, Text.wrongType(param), "\(param) = \(value)")
                XCTAssertFalse((outcome.message ?? "").contains("omit"))
            }
        }
        XCTAssertEqual(rig.partner.requests.count, 0)
    }

    func testBOOKING_G14_NoProxyGivesTheNotAvailableMessage() {
        let rig = makeRig(config: PlaceSentinel.unconfigured)
        assertRefused(rig.call(BookingRig.arguments()), Text.unavailable)
        // The earlier checks come first.
        assertRefused(rig.call(BookingRig.arguments(drop: ["party_size"])), Text.party)
        assertRefused(rig.call(BookingRig.arguments(["place_id": "p5"])), Text.place)
        XCTAssertEqual(rig.partner.requests.count, 0)
    }

    func testBOOKING_G15_AnUndeclaredArgumentIsNeverReadOrSent() async throws {
        let rig = makeRig()
        let extras: [String: Any] = ["name": "SENTINEL-NAME-1", "phone": "SENTINEL-PHONE-1", "payment": "SENTINEL-CARD-1",
                                     "email": 5, "duration": ["x"]]
        let card = try XCTUnwrap(rig.call(BookingRig.arguments(extras)).card, "undeclared keys, even of a wrong type, are dropped")
        XCTAssertFalse(card.lines.joined().contains("SENTINEL"))
        _ = await card.resolve(.confirm)
        XCTAssertEqual(rig.partner.requests.count, 1)
        let sent = String(decoding: try XCTUnwrap(rig.partner.requests.first?.httpBody), as: UTF8.self)
        XCTAssertFalse(sent.contains("SENTINEL"))
        XCTAssertEqual(Set(try XCTUnwrap(rig.partner.body()).keys), ["request_id", "restaurant", "party_size", "start"])
        XCTAssertFalse(rig.snapshot.contains("SENTINEL"))
    }

    // MARK: G16-G17 the card

    func testBOOKING_G16_TheCardHasTheFiveLinesAndTheGoogleMark() throws {
        let rig = makeRig()
        let card = try XCTUnwrap(rig.card())
        XCTAssertEqual(card.lines, ["Reserve a table", "Pasta Palace", dayText(BookingFixture.start), "Table for 2",
                                    "Example Tables - Simulated"])
        XCTAssertTrue(card.showsGoogleMark)
        XCTAssertEqual(card.actions, ["Confirm", "Cancel"])

        let hostile = Place(name: "  Evil\u{200B}\nPlace\u{202E}\u{2028} ", address: "", latitude: 1, longitude: 2)
        let other = makeRig(places: [hostile])
        let hostileCard = try XCTUnwrap(other.card())
        XCTAssertEqual(hostileCard.lines[1], "EvilPlace", "a hostile place name is shown sanitized")
        XCTAssertEqual(hostileCard.lines.count, 5)
    }

    func testBOOKING_G17_BuildingTheCardSendsAndWritesNothing() throws {
        let rig = makeRig()
        let before = rig.snapshot
        XCTAssertNotNil(rig.card())
        XCTAssertEqual(rig.partner.requests.count, 0)
        XCTAssertEqual(rig.snapshot, before)
        XCTAssertTrue(rig.store.activities.isEmpty)
        XCTAssertTrue(rig.log.packets.isEmpty)
    }

    // MARK: G18-G23 Confirm

    func testBOOKING_G18_ConfirmWithAConfirmationAddsOneEntryAndAnAppliedResult() async throws {
        let rig = makeRig()
        let card = try XCTUnwrap(rig.card())
        let resolved = await card.resolve(.confirm)
        let resolution = try XCTUnwrap(resolved)
        XCTAssertEqual(rig.partner.requests.count, 1)
        XCTAssertEqual(rig.store.activities.count, 1)
        let entry = try XCTUnwrap(rig.store.activities.first)
        XCTAssertEqual(entry.title, "Table for 2 - Pasta Palace (Simulated)")
        XCTAssertEqual(entry.startDate, TestClock.date(BookingFixture.start))
        XCTAssertEqual(entry.endDate.timeIntervalSince(entry.startDate), 90 * 60)
        XCTAssertEqual(entry.location, BookingFixture.place)
        XCTAssertEqual(entry.wantsCalendarSync, rig.store.calendarSyncDefault)
        XCTAssertEqual(card.mark, .confirmed)
        XCTAssertNil(resolution.notice)
        XCTAssertEqual(resolution.status, "applied")
        let json = try XCTUnwrap(resolution.json)
        XCTAssertEqual(json["partner"] as? String, "Example Tables")
        XCTAssertEqual(json["simulated"] as? Bool, true)
        XCTAssertEqual(json["reservation_code"] as? String, "EX-AB12CD")
        XCTAssertEqual(json["id"] as? String, entry.id.uuidString)
        XCTAssertEqual(json["title"] as? String, entry.title)
        XCTAssertEqual(json["start"] as? String, BookingFixture.start)
        XCTAssertEqual(json["end"] as? String, TestClock.local(entry.endDate))
        XCTAssertEqual(json["location"] as? String, "Pasta Palace")
        XCTAssertTrue((json["message"] as? String ?? "").lowercased().contains("simulated"))
        let sent = try XCTUnwrap(rig.partner.body())
        XCTAssertEqual(sent["restaurant"] as? String, "Pasta Palace")
        XCTAssertEqual(sent["party_size"] as? Int, 2)
        XCTAssertEqual(sent["start"] as? String, BookingFixture.start)
    }

    func testBOOKING_G19_ALongPlaceNameGivesATitleOfAtMostEightyCharactersWithTheSuffix() async throws {
        let long = Place(name: String(repeating: "Wonderful ", count: 20), address: "x", latitude: 1, longitude: 2)
        let rig = makeRig(places: [long])
        let card = try XCTUnwrap(rig.card())
        _ = await card.resolve(.confirm)
        let title = try XCTUnwrap(rig.store.activities.first?.title)
        XCTAssertLessThanOrEqual(title.count, 80)
        XCTAssertTrue(title.hasSuffix(" (Simulated)"))
        XCTAssertTrue(title.hasPrefix("Table for 2 - Wonderful"))
        XCTAssertTrue(title.contains("… (Simulated)"), "the cut name part ends with an ellipsis: \(title)")
        // A name that fits is kept whole.
        XCTAssertEqual(AgentBooking.entryTitle(partySize: 12, placeName: "Pasta Palace"), "Table for 12 - Pasta Palace (Simulated)")
    }

    func testBOOKING_G20_ADeclinedAnswerAddsNothingAndSaysSo() async throws {
        let rig = makeRig()
        let card = try XCTUnwrap(rig.card(["party_size": "9"]))
        let resolved = await card.resolve(.confirm)
        let resolution = try XCTUnwrap(resolved)
        XCTAssertEqual(rig.partner.requests.count, 1)
        XCTAssertTrue(rig.store.activities.isEmpty)
        XCTAssertEqual(card.mark, .notApplied)
        XCTAssertEqual(resolution.status, "declined")
        XCTAssertEqual(resolution.json?["partner"] as? String, "Example Tables")
        XCTAssertEqual(resolution.json?["simulated"] as? Bool, true)
        XCTAssertTrue((resolution.message ?? "").contains("no table"))
        XCTAssertNil(resolution.json?["reservation_code"])
    }

    func testBOOKING_G21_EveryFailureAddsNothingAndGivesTheUnavailableResult() async throws {
        let modes: [(String, (EchoPartner, BookingRig) -> Void)] = [
            ("offline", { partner, _ in partner.mode = .error(URLError(.notConnectedToInternet)) }),
            ("token", { partner, _ in partner.mode = .status(401, #"{"error":"unauthorized"}"#) }),
            ("other", { partner, _ in partner.mode = .status(500, "oops") }),
            ("bad body", { partner, _ in partner.mode = .status(200, "[]") }),
            ("not set up", { _, rig in rig.box.config = PlaceSentinel.unconfigured }),
        ]
        for (name, arrange) in modes {
            let rig = makeRig()
            let card = try XCTUnwrap(rig.card(), name)
            arrange(rig.partner, rig)
            let resolved = await card.resolve(.confirm)
            let resolution = try XCTUnwrap(resolved, name)
            XCTAssertTrue(rig.store.activities.isEmpty, name)
            XCTAssertEqual(card.mark, .notApplied, name)
            XCTAssertEqual(resolution.status, "unavailable", name)
            XCTAssertEqual(resolution.json?["partner"] as? String, "Example Tables", name)
            XCTAssertEqual(resolution.json?["simulated"] as? Bool, true, name)
            XCTAssertEqual(resolution.notice, Text.notice, name)
        }
    }

    func testBOOKING_G22_ConfirmAfterTheStartPassedSendsNothing() async throws {
        let rig = makeRig()
        let card = try XCTUnwrap(rig.card())
        rig.clock.now = TestClock.date("2026-10-28T19:01")
        let resolved = await card.resolve(.confirm)
        let resolution = try XCTUnwrap(resolved)
        XCTAssertEqual(rig.partner.requests.count, 0)
        XCTAssertTrue(rig.store.activities.isEmpty)
        XCTAssertEqual(card.mark, .notApplied)
        XCTAssertEqual(resolution.status, "rejected")
        XCTAssertEqual(resolution.message, Text.window)
        XCTAssertEqual(resolution.notice, "That start time is now out of range. Nothing was added.")
        XCTAssertTrue(rig.log.packets.isEmpty)
    }

    func testBOOKING_G23_TwoConfirmTapsSendOnceAndAddOnce() async throws {
        let rig = makeRig()
        let card = try XCTUnwrap(rig.card())
        let first = await card.resolve(.confirm)
        let second = await card.resolve(.confirm)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(rig.partner.requests.count, 1)
        XCTAssertEqual(rig.store.activities.count, 1)
        let third = await card.resolve(.cancel)
        XCTAssertNil(third)
        XCTAssertEqual(card.mark, .confirmed)
    }

    // MARK: G24-G25 Cancel and a new chat

    func testBOOKING_G24_CancelAndDismissSendWriteAndRecordNothing() async throws {
        for how in [AgentCardResolution.cancel, .dismiss] {
            let rig = makeRig()
            let card = try XCTUnwrap(rig.card())
            let resolved = await card.resolve(how)
            let resolution = try XCTUnwrap(resolved)
            XCTAssertEqual(resolution.result, AgentToolbox.declinedResult)
            XCTAssertEqual(resolution.status, "declined")
            XCTAssertEqual(card.mark, .cancelled)
            XCTAssertEqual(rig.partner.requests.count, 0)
            XCTAssertTrue(rig.store.activities.isEmpty)
            await rig.log.flush()
            XCTAssertTrue(rig.log.packets.isEmpty)
        }
    }

    func testBOOKING_G25_ANewChatWhileTheCardIsPendingActsAsDismiss() async throws {
        let rig = makeRig()
        let fake = FakeTransport([.turn(Turns.turn(Turns.call("request_booking", PlaceTurns.arguments(BookingRig.arguments()), id: "c1")))])
        let session = AgentSession(toolbox: rig.tools, transport: fake, connections: rig.log)
        session.send("Book a table")
        await session.settle()
        XCTAssertNotNil(session.pendingCard)
        await session.newChat()
        XCTAssertNil(session.pendingCard)
        XCTAssertEqual(rig.partner.requests.count, 0)
        XCTAssertTrue(rig.store.activities.isEmpty)
        await rig.log.flush()
        XCTAssertTrue(rig.log.packets.filter { $0.kind == .partner }.isEmpty)
    }

    // MARK: G26-G28

    func testBOOKING_G26_TheRequestIdIsOnePerCardAndDiffersBetweenCards() async throws {
        let rig = makeRig()
        let first = try XCTUnwrap(rig.card())
        let second = try XCTUnwrap(rig.card())
        _ = await first.resolve(.confirm)
        _ = await first.resolve(.confirm)
        _ = await second.resolve(.confirm)
        XCTAssertEqual(rig.partner.requests.count, 2)
        let ids = [0, 1].compactMap { rig.partner.body($0)?["request_id"] as? String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
        for id in ids { XCTAssertNotNil(UUID(uuidString: id), id) }
    }

    func testBOOKING_G27_TwoCallsInOneResponseRunOnlyTheFirst() async throws {
        let rig = makeRig()
        let first = Turns.call("request_booking", PlaceTurns.arguments(BookingRig.arguments()), id: "c1")
        let second = Turns.call("request_booking", PlaceTurns.arguments(BookingRig.arguments(["party_size": "4"])), id: "c2")
        let fake = FakeTransport([.turn(Turns.turn(first, second)), .turn(Turns.text("Booked."))])
        let session = AgentSession(toolbox: rig.tools, transport: fake, connections: rig.log)
        session.send("Book a table")
        await session.settle()
        XCTAssertNotNil(session.pendingCard)
        XCTAssertEqual(rig.partner.requests.count, 0)
        await session.confirmCard()
        await session.settle()
        XCTAssertEqual(rig.partner.requests.count, 1)
        XCTAssertEqual(rig.partner.body()?["party_size"] as? Int, 2)
        XCTAssertEqual(rig.store.activities.count, 1)
        let next = fake.request(2)
        guard next.count == 4, case .callOutput(_, let secondResult) = next[3] else { return XCTFail("two outputs expected") }
        XCTAssertEqual(TestClock.object(secondResult)?["status"] as? String, "rejected")
    }

    func testBOOKING_G28_AStartBeforeTheCurrentMinuteIsRefusedAtTheGateAndAtConfirm() async throws {
        let rig = makeRig()
        assertRefused(rig.call(BookingRig.arguments(["start": "2026-10-27T08:59"])), Text.window)
        // Seconds into the clock minute do not matter: 09:00:45 still allows 09:00.
        rig.clock.now = TestClock.date("2026-10-27T09:00:45")
        let card = try XCTUnwrap(rig.card(["start": "2026-10-27T09:00"]))
        rig.clock.now = TestClock.date("2026-10-27T09:01:00")
        let resolved = await card.resolve(.confirm)
        let resolution = try XCTUnwrap(resolved)
        XCTAssertEqual(resolution.status, "rejected")
        XCTAssertEqual(rig.partner.requests.count, 0)
    }

    // MARK: G29-G30 in flight and read-back

    func testBOOKING_G29_ATaskCancelledInFlightWritesAndRecordsNothing() async throws {
        let rig = makeRig()
        rig.partner.duringSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let card = try XCTUnwrap(rig.card())
        let resolution = await Task { await card.resolve(.confirm) }.value
        XCTAssertEqual(rig.partner.requests.count, 1, "the stub answered a valid confirmation")
        XCTAssertTrue(rig.store.activities.isEmpty, "the cancellation check comes before the Store write")
        XCTAssertEqual(card.mark, .notApplied)
        XCTAssertEqual(resolution?.status, "unavailable")
        XCTAssertEqual(resolution?.notice, Text.notice)
        await rig.log.flush()
        XCTAssertTrue(rig.log.packets.isEmpty)
    }

    func testBOOKING_G30_AnEntryThatCannotBeReadBackGivesNotAppliedAndNotFound() {
        let rig = makeRig()
        let (resolution, mark) = rig.tools.bookingApplied(UUID(), code: "EX-AB12CD")
        XCTAssertEqual(mark, .notApplied)
        XCTAssertEqual(resolution.status, "not_found")
        XCTAssertEqual(resolution.notice, "That event changed or no longer exists. Nothing was changed.")
        XCTAssertNil(resolution.json?["reservation_code"])
    }

    // MARK: G31-G32 texts and the sent name

    func testBOOKING_G31_RefusalTextsNameOnlyTheTwoToolsAndKeepOldTextsUnchanged() throws {
        let rig = makeRig(places: [BookingFixture.place, Place(name: "\u{200B}", address: "", latitude: 1, longitude: 2)])
        let sentinel = "SENTINEL-MODEL-VALUE"
        var messages: [String] = []
        let refusals: [[String: Any]] = [
            BookingRig.arguments(drop: ["place_id"]), BookingRig.arguments(["place_id": sentinel]),
            BookingRig.arguments(["place_id": "p2"]), BookingRig.arguments(drop: ["start"]),
            BookingRig.arguments(["start": sentinel]), BookingRig.arguments(["start": "2020-01-01T10:00"]),
            BookingRig.arguments(drop: ["party_size"]), BookingRig.arguments(["party_size": sentinel]),
            BookingRig.arguments(["place_id": 5]), BookingRig.arguments(["start": 5]), BookingRig.arguments(["party_size": 5]),
        ]
        for args in refusals {
            let outcome = rig.call(args)
            XCTAssertEqual(outcome.status, "rejected")
            messages.append(try XCTUnwrap(outcome.message))
        }
        let unconfigured = makeRig(config: PlaceSentinel.unconfigured)
        messages.append(try XCTUnwrap(unconfigured.call(BookingRig.arguments()).message))
        XCTAssertEqual(messages.count, 12)
        let others = ["list_activities", "create_activity", "update_activity", "delete_activity", "get_travel_time"]
        for message in messages {
            for other in others { XCTAssertFalse(message.contains(other), "\(message) names \(other)") }
            XCTAssertFalse(message.contains(sentinel), message)
            XCTAssertTrue(message.contains("request_booking") || message.contains("search_places"), message)
        }
        // The re-ask strings of the six old tools are the t20 text, not the booking branch.
        let harness = ToolHarness.make()
        XCTAssertEqual(harness.call("create_activity", ["title": 5, "start": "x", "end": "y"]).message,
                       ToolText.wrongType("create_activity", "title"))
        XCTAssertEqual(harness.call("update_activity", ["id": 5]).message, ToolText.wrongType("update_activity", "id"))
        XCTAssertEqual(harness.call("list_activities", ["from": 5, "to": "x"]).message, ToolText.wrongType("list_activities", "from"))
        let places = PlaceRig()
        XCTAssertEqual(places.call("get_travel_time", ["place_id": 5, "mode": "walk"]).message,
                       ToolText.wrongType("get_travel_time", "place_id"))
        XCTAssertEqual(places.call("search_places", ["query": 5]).message, ToolText.wrongType("search_places", "query"))
    }

    func testBOOKING_G32_TheSentNameIsCutAtEightyUnicodeScalars() async throws {
        // 80 Characters made of 160 scalars: each is a letter and a combining accent.
        let name = String(repeating: "e\u{0301}", count: 80)
        XCTAssertEqual(name.count, 80)
        XCTAssertEqual(name.unicodeScalars.count, 160)
        let place = Place(name: name, address: "x", latitude: 1, longitude: 2)
        XCTAssertEqual(AgentBooking.sentName(place).unicodeScalars.count, 80)
        XCTAssertEqual(AgentBooking.sentName(Place(name: "  Pasta  ", address: "", latitude: 0, longitude: 0)), "Pasta")
        XCTAssertEqual(AgentBooking.sentName(Place(name: "A\u{200B}B\n", address: "", latitude: 0, longitude: 0)), "AB")

        let rig = makeRig(places: [place])
        let card = try XCTUnwrap(rig.card())
        _ = await card.resolve(.confirm)
        let sent = try XCTUnwrap(rig.partner.body()?["restaurant"] as? String)
        XCTAssertLessThanOrEqual(sent.unicodeScalars.count, 80)
        XCTAssertGreaterThan(sent.unicodeScalars.count, 0)
        XCTAssertEqual(rig.partner.requests.count, 1)
    }
}
