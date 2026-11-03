import XCTest
@testable import besir

/// SPEC-UBERLINK-001 (card t120), T09-T20: an Uber trip is a car trip with a mark. The stored mark and its one writer, the
/// rule that names, lists and parses the travel choices, the activity card, the store's saves, edits and repeats, the
/// departure alert, and the chat path. Written before the behaviour: on the stub (base behaviour behind the final names)
/// every test fails on an assertion. Nothing here touches the network: travel times come from
/// `drvTravelLookupOverride` and the chat path runs on the stub transports of `PlaceRig`.
@MainActor
final class UberTripTests: XCTestCase {
    private var savedZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Seoul")!
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
        super.tearDown()
    }

    // MARK: Helpers

    private let home = Place(name: "Home", address: "1 Home St, San Francisco, CA 94103", latitude: 37.7749, longitude: -122.4194)
    private let ferry = Place(name: "Ferry Building", address: "1 Ferry Building, San Francisco, CA 94105",
                              latitude: 37.7955, longitude: -122.3937)

    private static let fiveValues = ["car", "uber", "transit", "walk", "bicycle"]
    private static let modeDescription = "How the user travels: car, transit, walk or bicycle. The user chooses; ask them if they have not said. Use uber only when the user has named Uber themselves."

    /// Read per use, not stored: `Calendar.current` follows the zone `setUp` sets.
    private var cal: Calendar { Calendar.current }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? .distantPast
    }

    /// The modes the store looked up, in order.
    private final class LookupLog {
        var modes: [TransportMode] = []
    }

    /// An empty store whose every travel lookup is recorded and answers 900 seconds.
    private func recordingStore() -> (Store, LookupLog) {
        let store = EmptyStore.make()
        let log = LookupLog()
        store.drvTravelLookupOverride = { mode, _, _ in
            log.modes.append(mode)
            return 900
        }
        return (store, log)
    }

    private func record(_ store: Store, _ id: UUID?) -> ScheduledEvent? {
        guard let id else { return nil }
        return store.events.first { $0.id == id }
    }

    private func rowId(_ f: LegCardForm, _ key: String) -> UUID? {
        f.card.fields.first { $0.key == key }?.id
    }

    private func choose(_ f: inout LegCardForm, _ key: String, _ value: String, place: Place? = nil,
                        file: StaticString = #filePath, line: UInt = #line) {
        guard let id = rowId(f, key) else { return XCTFail("the card has no \(key) row", file: file, line: line) }
        f.choose(field: id, value: value, place: place)
    }

    /// The New Activity card as the app builds it: a title, the Ferry Building, a start and an end; travel toggles off.
    private func newActivityForm(title: String, start: Date, end: Date) -> LegCardForm {
        let rows = LegCardForm.manualNewActivityRows(favorites: [], defaultDay: start, now: start, presetStart: nil)
        var f = LegCardForm(card: EditCard(fields: rows), favoriteOptions: [])
        if let id = rowId(f, "title") { f.setTitleText(field: id, text: title) }
        choose(&f, "location_query", ferry.name, place: ferry)
        if let id = rowId(f, "start_iso") { f.choosePlainTime(field: id, date: start) }
        if let id = rowId(f, "end_iso") { f.choosePlainTime(field: id, date: end) }
        return f
    }

    /// Types the Repeat text and commits the row (the step the screen runs when the row loses focus).
    private func commitRepeat(_ f: inout LegCardForm, _ text: String) {
        guard let id = rowId(f, RecurrenceLine.key) else { return XCTFail("the card has no Repeat row") }
        f.setTitleText(field: id, text: text)
        f.commitRecurrenceByRules()
    }

    /// A stored outbound leg of `activity` from Home, set to `choice`.
    private func outboundLeg(of activity: ActivityBlock, _ choice: TravelChoice) -> ScheduledEvent {
        var leg = ScheduledEvent(title: activity.title, origin: home, destination: ferry, arrivalDate: activity.startDate,
                                 mode: .transit, bufferMinutes: 10, notifyLeadMinutes: 10)
        leg.anchor = .arrival
        leg.linkedActivityId = activity.id
        leg.setTravel(choice)
        return leg
    }

    private func seededCard(_ activity: ActivityBlock, outbound: ScheduledEvent) -> LegCardForm {
        LegCardForm.seeded(activity: activity, outbound: outbound, returnLeg: nil, noPlaceValue: PlaceTokens.noPlace,
                           placeOptions: [], favoriteOptions: [])
    }

    /// The travel choice of every `.update` op, in order.
    private func updateChoices(_ ops: [LegSaveOp]) -> [TravelChoice?] {
        var out: [TravelChoice?] = []
        for op in ops {
            if case let .update(_, _, _, choice, _, _, _) = op { out.append(choice) }
        }
        return out
    }

    private func jsonText(_ event: ScheduledEvent) -> String {
        String(decoding: (try? JSONEncoder().encode(event)) ?? Data(), as: UTF8.self)
    }

    /// The ids of the occurrences of `series` the leg fill at `now` gives a leg: today through `legWindowDays`, started
    /// after `now`, ordered by start.
    private func filledOccurrenceIDs(_ series: RepeatSeries?, now: Date) -> [UUID] {
        guard let series else { return [] }
        let today = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: Store.legWindowDays + 1, to: today) else { return [] }
        return series.occurrences(in: DateInterval(start: today, end: end), calendar: cal)
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map(\.id)
    }

    private func legs(_ store: Store, linkedTo ids: [UUID], role: ScheduleAnchor) -> [ScheduledEvent] {
        store.events.filter { e in
            guard let link = e.linkedActivityId, ids.contains(link) else { return false }
            return (e.anchor ?? .arrival) == role
        }
    }

    // MARK: AC-009 - the stored mark, its one writer and old data

    func testUBER_T09_anUberTripIsStoredAsACarWithTheMarkAndOldDataReadsAsNotUber() throws {
        var trip = ScheduledEvent(title: "Ride", origin: home, destination: ferry, arrivalDate: at(2026, 12, 7, 9),
                                  mode: .transit, bufferMinutes: 5, notifyLeadMinutes: 10)
        trip.setTravel(.uber)
        XCTAssertEqual(trip.mode, .car, "an Uber trip is a car trip")
        XCTAssertEqual(trip.viaUber, true, "an Uber trip carries the mark")
        XCTAssertTrue(jsonText(trip).contains("\"viaUber\":true"), jsonText(trip))

        for choice in [TravelChoice.standard(.car), .standard(.transit)] {
            var plain = trip
            plain.setTravel(choice)
            XCTAssertNil(plain.viaUber, "\(choice) has no mark")
            XCTAssertFalse(jsonText(plain).contains("viaUber"), "\(choice) writes no key: \(jsonText(plain))")
        }
        var walked = trip
        walked.setTravel(.uber)
        walked.setTravel(.standard(.walk))
        XCTAssertEqual(walked.mode, .walk)
        XCTAssertNil(walked.viaUber, "Uber then Walk leaves no mark")

        let base = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old trip","destination":{"name":"Ferry Building","address":"1 Ferry Building, San Francisco, CA 94105","latitude":37.7955,"longitude":-122.3937},"arrivalDate":786000000,"mode":"car","bufferMinutes":5,"notifyLeadMinutes":10}"#
        let old = try JSONDecoder().decode(ScheduledEvent.self, from: Data(base.utf8))
        XCTAssertNil(old.viaUber, "old data has no mark")
        XCTAssertEqual(old.travelChoice, .standard(.car), "old data reads as Car")

        let handEdited = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","title":"Odd trip","destination":{"name":"Ferry Building","address":"","latitude":37.7955,"longitude":-122.3937},"arrivalDate":786000000,"mode":"transit","bufferMinutes":5,"notifyLeadMinutes":10,"viaUber":true}"#
        let odd = try JSONDecoder().decode(ScheduledEvent.self, from: Data(handEdited.utf8))
        XCTAssertEqual(odd.travelChoice, .standard(.transit), "a mark on a transit trip reads as Transit")
    }

    func testUBER_T10_theSyncContentCarriesTheMarkOnlyWhenItIsSet() {
        var trip = ScheduledEvent(title: "Ride", origin: home, destination: ferry, arrivalDate: at(2026, 12, 7, 9),
                                  mode: .car, bufferMinutes: 5, notifyLeadMinutes: 10)
        trip.setTravel(.uber)
        let uberText = String(decoding: trip.syncComparisonJSON(), as: UTF8.self)
        XCTAssertTrue(uberText.contains("\"viaUber\":true"), uberText)
        trip.setTravel(.standard(.car))
        let carText = String(decoding: trip.syncComparisonJSON(), as: UTF8.self)
        XCTAssertFalse(carText.contains("viaUber"), carText)
        XCTAssertNotEqual(carText, uberText, "Car and Uber are different sync content")
    }

    // MARK: AC-010, AC-011 - one rule names, lists and parses the choices

    func testUBER_T11_oneRuleNamesEveryTravelChoice() {
        XCTAssertEqual(TravelChoice.uber.title, "Uber")
        XCTAssertEqual(TravelChoice.uber.titleWithParticle, "By Uber")
        XCTAssertEqual(TravelChoice.uber.systemImage, "car.fill")
        XCTAssertEqual(TravelChoice.uber.mode, .car)
        XCTAssertEqual(TravelChoice.uber.value, "uber")
        for m in TransportMode.allCases {
            let c = TravelChoice.standard(m)
            XCTAssertEqual(c.title, m.title)
            XCTAssertEqual(c.titleWithParticle, m.titleWithParticle)
            XCTAssertEqual(c.systemImage, m.systemImage)
            XCTAssertEqual(c.mode, m)
            XCTAssertEqual(c.value, m.rawValue)
        }
        XCTAssertEqual(TravelChoice(mode: .car, viaUber: true), .uber)
        XCTAssertEqual(TravelChoice(mode: .car, viaUber: nil), .standard(.car))
        XCTAssertEqual(TravelChoice(mode: .car, viaUber: false), .standard(.car))
        XCTAssertEqual(TravelChoice(mode: .transit, viaUber: true), .standard(.transit))
        XCTAssertEqual(TravelChoice(mode: .walk, viaUber: true), .standard(.walk))
        XCTAssertEqual(AgentPlaces.modePhrase(.uber), "by Uber")
        XCTAssertEqual(AgentPlaces.modePhrase(.standard(.car)), "by car")
        XCTAssertEqual(AgentPlaces.modePhrase(TransportMode.walk), "on foot")
    }

    func testUBER_T12_theChoicesAreCarUberThenTheOtherModesAndOnlyExactValuesParse() {
        XCTAssertEqual(TravelChoice.all.map(\.value), ["car", "uber", "transit", "walk", "bicycle"])
        XCTAssertEqual(TravelChoice.all.map(\.title), ["Car", "Uber", "Transit", "Walk", "Bicycle"])
        for c in TravelChoice.all {
            XCTAssertEqual(TravelChoice(value: c.value), c, "\(c.value) parses back")
        }
        for bad in ["Uber", "UBER", " uber", "uber ", "taxi", "", "Car"] {
            XCTAssertNil(TravelChoice(value: bad), "\(bad.debugDescription) does not parse")
        }
    }

    // MARK: AC-011 - the activity card

    func testUBER_T13_theActivityCardOffersUberSeedsItAndPlansItsSave() {
        let activity = ActivityBlock(title: "Lunch", location: ferry, startDate: at(2026, 12, 7, 12),
                                     endDate: at(2026, 12, 7, 13), recurrenceId: nil, syncToCalendar: nil)
        let uberLeg = outboundLeg(of: activity, .uber)
        let seed = seededCard(activity, outbound: uberLeg)

        let outRow = seed.card.fields.first { $0.key == LegRowKeys.outboundMode }
        XCTAssertNotNil(outRow, "the seeded card has the outbound mode row")
        XCTAssertEqual(outRow?.options.map(\.value), Self.fiveValues, "the outbound row offers the five choices")
        XCTAssertEqual(outRow?.chosen, "uber", "the seed reads the stored Uber choice")
        var withReturn = seed
        choose(&withReturn, LegRowKeys.returnEnabled, "true")
        XCTAssertEqual(withReturn.card.fields.first { $0.key == LegRowKeys.returnMode }?.options.map(\.value), Self.fiveValues,
                       "the return row offers the five choices")
        XCTAssertEqual(outRow?.accepts("uber"), "uber")
        XCTAssertNil(outRow?.accepts("Uber"), "only the exact value is accepted")

        var toCar = seed
        choose(&toCar, LegRowKeys.outboundMode, "car")
        let carOps = LegSavePlanner.ops(seed: seed, current: toCar, outboundLeg: uberLeg, returnLeg: nil)
        XCTAssertEqual(carOps.count, 1, "Uber to Car is one change: \(carOps)")
        XCTAssertEqual(updateChoices(carOps), [Optional(TravelChoice.standard(.car))])

        var back = toCar
        choose(&back, LegRowKeys.outboundMode, "uber")
        let backOps = LegSavePlanner.ops(seed: seed, current: back, outboundLeg: uberLeg, returnLeg: nil)
        XCTAssertEqual(backOps.count, 0, "choosing Uber again plans nothing: \(backOps)")

        let carLeg = outboundLeg(of: activity, .standard(.car))
        let carSeed = seededCard(activity, outbound: carLeg)
        var toUber = carSeed
        choose(&toUber, LegRowKeys.outboundMode, "uber")
        let uberOps = LegSavePlanner.ops(seed: carSeed, current: toUber, outboundLeg: carLeg, returnLeg: nil)
        XCTAssertEqual(uberOps.count, 1, "Car to Uber is one change: \(uberOps)")
        XCTAssertEqual(updateChoices(uberOps), [Optional(TravelChoice.uber)])
    }

    // MARK: AC-012, AC-013 - saves, edits and repeats

    func testUBER_T14_savingWithUberStoresTheMarkAndLooksUpOneCarRoutePerLeg() async {
        let (store, log) = recordingStore()

        // An Uber outbound and a Car return.
        let first = await store.addActivityWithTravel(
            title: "Lunch A", location: ferry, startDate: at(2026, 12, 7, 12), endDate: at(2026, 12, 7, 13),
            travelFrom: home, returnTo: home, outboundMode: .car, returnMode: .car, outboundUber: true,
            bufferMinutes: 5, notifyLeadMinutes: 10)
        XCTAssertEqual(first.travelLegs, 2)
        let a = store.legs(of: first.activityId)
        XCTAssertEqual(a.outbound?.viaUber, true, "the Uber outbound leg carries the mark")
        XCTAssertNotNil(a.return)
        XCTAssertNil(a.return?.viaUber, "the Car return leg has no mark")
        XCTAssertEqual(log.modes, [.car, .car], "one car lookup per leg")

        // A1: a Car outbound and an Uber return.
        log.modes = []
        let second = await store.addActivityWithTravel(
            title: "Lunch B", location: ferry, startDate: at(2026, 12, 8, 12), endDate: at(2026, 12, 8, 13),
            travelFrom: home, returnTo: home, outboundMode: .car, returnMode: .car, returnUber: true,
            bufferMinutes: 5, notifyLeadMinutes: 10)
        XCTAssertEqual(second.travelLegs, 2)
        let b = store.legs(of: second.activityId)
        XCTAssertNotNil(b.return)
        XCTAssertEqual(b.return?.viaUber, true, "A1: the Uber return leg carries the mark")
        XCTAssertNotNil(b.outbound)
        XCTAssertNil(b.outbound?.viaUber, "the Car outbound leg has no mark")
        XCTAssertEqual(log.modes, [.car, .car], "one car lookup per leg")

        // Without the new arguments: no mark (the callers of SPEC-UBERLINK-002 as at base).
        let plain = await store.addActivityWithTravel(
            title: "Lunch C", location: ferry, startDate: at(2026, 12, 9, 12), endDate: at(2026, 12, 9, 13),
            travelFrom: home, returnTo: home, outboundMode: .car, returnMode: .car,
            bufferMinutes: 5, notifyLeadMinutes: 10)
        let c = store.legs(of: plain.activityId)
        XCTAssertNotNil(c.outbound)
        XCTAssertNotNil(c.return)
        XCTAssertNil(c.outbound?.viaUber)
        XCTAssertNil(c.return?.viaUber)

        // A trip on its own.
        log.modes = []
        let trip = await store.addEvent(title: "Ride", origin: home, destination: ferry, arrivalDate: at(2026, 12, 10, 9),
                                        mode: .car, uber: true, bufferMinutes: 5, notifyLeadMinutes: 10)
        XCTAssertEqual(record(store, trip.id)?.viaUber, true, "a car trip saved with Uber stores the mark")
        XCTAssertEqual(log.modes, [.car], "one car lookup")
        let transitTrip = await store.addEvent(title: "Tram", origin: home, destination: ferry,
                                               arrivalDate: at(2026, 12, 11, 9), mode: .transit, uber: true,
                                               bufferMinutes: 5, notifyLeadMinutes: 10)
        XCTAssertEqual(record(store, transitTrip.id)?.mode, .transit)
        XCTAssertNil(record(store, transitTrip.id)?.viaUber, "only a car trip carries the mark")

        // The New Activity card with the Uber outbound chip.
        log.modes = []
        var card = newActivityForm(title: "Card Uber", start: at(2026, 12, 12, 12), end: at(2026, 12, 12, 13))
        choose(&card, LegRowKeys.outboundEnabled, "true")
        choose(&card, LegRowKeys.originQuery, home.name, place: home)
        choose(&card, LegRowKeys.outboundMode, "uber")
        XCTAssertTrue(card.card.isReady)
        let saved = await store.saveManualActivity(card, calendarDefault: false)
        XCTAssertTrue(saved)
        let made = store.activities.first { $0.title == "Card Uber" }
        XCTAssertNotNil(made)
        let madeLegs = made.map { store.legs(of: $0.id) }
        XCTAssertEqual(madeLegs?.outbound?.mode, .car)
        XCTAssertEqual(madeLegs?.outbound?.viaUber, true, "the card's Uber chip stores an Uber leg")
        XCTAssertEqual(log.modes, [.car], "the Uber leg is looked up once, by car")

        // A1: the New Activity card with the Car outbound chip and the Uber return chip.
        var both = newActivityForm(title: "Card Return Uber", start: at(2026, 12, 13, 12), end: at(2026, 12, 13, 13))
        choose(&both, LegRowKeys.outboundEnabled, "true")
        choose(&both, LegRowKeys.originQuery, home.name, place: home)
        choose(&both, LegRowKeys.outboundMode, "car")
        choose(&both, LegRowKeys.returnEnabled, "true")
        choose(&both, LegRowKeys.returnQuery, home.name, place: home)
        choose(&both, LegRowKeys.returnMode, "uber")
        XCTAssertTrue(both.card.isReady)
        let savedBoth = await store.saveManualActivity(both, calendarDefault: false)
        XCTAssertTrue(savedBoth)
        let madeBoth = store.activities.first { $0.title == "Card Return Uber" }
        XCTAssertNotNil(madeBoth)
        let bothLegs = legs(store, linkedTo: madeBoth.map { [$0.id] } ?? [], role: .arrival)
            + legs(store, linkedTo: madeBoth.map { [$0.id] } ?? [], role: .departure)
        XCTAssertEqual(bothLegs.count, 2, "exactly two legs")
        let returnLeg = bothLegs.first { $0.anchor == .departure }
        let outLeg = bothLegs.first { ($0.anchor ?? .arrival) == .arrival }
        XCTAssertNotNil(returnLeg)
        XCTAssertEqual(returnLeg?.mode, .car)
        XCTAssertEqual(returnLeg?.viaUber, true, "A1: the card's Uber return chip stores the mark on the return leg")
        XCTAssertNotNil(outLeg)
        XCTAssertNil(outLeg?.viaUber, "the Car outbound leg has no mark")
    }

    func testUBER_T15_editsKeepTheMarkUnlessTheChoiceChanges() async {
        let (store, log) = recordingStore()

        // A trip on its own.
        let uberTrip = await store.addEvent(title: "Uber ride", origin: home, destination: ferry,
                                            arrivalDate: at(2026, 12, 14, 9), mode: .car, uber: true,
                                            bufferMinutes: 5, notifyLeadMinutes: 10)
        XCTAssertEqual(record(store, uberTrip.id)?.viaUber, true, "addEvent(uber: true) stores the mark")
        await store.updateEvent(id: uberTrip.id, title: "Renamed ride", origin: home, destination: ferry,
                                arrivalDate: at(2026, 12, 14, 9), mode: .car, bufferMinutes: 5, notifyLeadMinutes: 10)
        XCTAssertEqual(record(store, uberTrip.id)?.title, "Renamed ride")
        XCTAssertEqual(record(store, uberTrip.id)?.viaUber, true, "a title edit with uber omitted keeps the mark")
        await store.updateEvent(id: uberTrip.id, title: "Renamed ride", origin: home, destination: ferry,
                                arrivalDate: at(2026, 12, 14, 9), mode: .car, uber: false,
                                bufferMinutes: 5, notifyLeadMinutes: 10)
        XCTAssertEqual(record(store, uberTrip.id)?.mode, .car)
        XCTAssertNil(record(store, uberTrip.id)?.viaUber, "car without Uber removes the mark")

        let second = await store.addEvent(title: "Second ride", origin: home, destination: ferry,
                                          arrivalDate: at(2026, 12, 15, 9), mode: .car, uber: true,
                                          bufferMinutes: 5, notifyLeadMinutes: 10)
        XCTAssertEqual(record(store, second.id)?.viaUber, true)
        await store.updateEvent(id: second.id, title: "Second ride", origin: home, destination: ferry,
                                arrivalDate: at(2026, 12, 15, 9), mode: .transit, bufferMinutes: 5, notifyLeadMinutes: 10)
        XCTAssertEqual(record(store, second.id)?.travelChoice, .standard(.transit))
        XCTAssertNil(record(store, second.id)?.viaUber, "transit removes the mark")

        // A leg of an activity.
        let gym = await store.addActivityWithTravel(
            title: "Gym", location: ferry, startDate: at(2026, 12, 16, 18), endDate: at(2026, 12, 16, 19),
            travelFrom: home, returnTo: nil, outboundMode: .car, returnMode: .car, outboundUber: true,
            bufferMinutes: 5, notifyLeadMinutes: 10)
        let legId = store.legs(of: gym.activityId).outbound?.id
        XCTAssertNotNil(legId)
        XCTAssertEqual(record(store, legId)?.viaUber, true, "the Uber leg carries the mark")
        XCTAssertTrue(store.modifyActivity(id: gym.activityId, newStart: at(2026, 12, 16, 17)))
        XCTAssertEqual(record(store, legId)?.arrivalDate, at(2026, 12, 16, 17), "the leg moved with the activity")
        XCTAssertEqual(record(store, legId)?.viaUber, true, "moving the activity keeps the mark")
        if let legId {
            _ = await store.updateLeg(legId: legId, bufferMinutes: 10)
            XCTAssertEqual(record(store, legId)?.bufferMinutes, 10)
            XCTAssertEqual(record(store, legId)?.viaUber, true, "a buffer-only update keeps the mark")
            let lookups = log.modes.count
            _ = await store.updateLeg(legId: legId, mode: .car, uber: false)
            XCTAssertNil(record(store, legId)?.viaUber, "updateLeg(mode: .car, uber: false) removes the mark")
            XCTAssertEqual(log.modes.count, lookups + 1, "the edited leg is looked up once more")
            XCTAssertEqual(log.modes.last, .car)
        }

        let office = await store.addActivityWithTravel(
            title: "Office", location: ferry, startDate: at(2026, 12, 17, 9), endDate: at(2026, 12, 17, 17),
            travelFrom: home, returnTo: nil, outboundMode: .car, returnMode: .car,
            bufferMinutes: 5, notifyLeadMinutes: 10)
        let carLegId = store.legs(of: office.activityId).outbound?.id
        XCTAssertNotNil(carLegId)
        XCTAssertNil(record(store, carLegId)?.viaUber)
        if let carLegId {
            _ = await store.updateLeg(legId: carLegId, mode: .car, uber: true)
            XCTAssertEqual(record(store, carLegId)?.viaUber, true, "updateLeg(mode: .car, uber: true) sets the mark")
        }

        // Two Uber legs of one series.
        let r1 = await store.addEvent(title: "Series ride", origin: home, destination: ferry,
                                      arrivalDate: at(2026, 12, 21, 9), mode: .car, uber: true,
                                      bufferMinutes: 5, notifyLeadMinutes: 10)
        let r2 = await store.addEvent(title: "Series ride", origin: home, destination: ferry,
                                      arrivalDate: at(2026, 12, 28, 9), mode: .car, uber: true,
                                      bufferMinutes: 5, notifyLeadMinutes: 10)
        let rid = UUID()
        for i in store.events.indices where [r1.id, r2.id].contains(store.events[i].id) {
            store.events[i].recurrenceId = rid
        }
        XCTAssertEqual(store.recurringSeries(rid).count, 2)
        let kept = await store.updateRecurringSeries(rid, mode: nil, bufferMinutes: 5, notifyLeadMinutes: nil)
        XCTAssertEqual(kept, 2)
        XCTAssertEqual(store.recurringSeries(rid).map(\.viaUber), [true, true], "a series update without a mode keeps both marks")
        _ = await store.updateRecurringSeries(rid, mode: .car, bufferMinutes: nil, notifyLeadMinutes: nil)
        XCTAssertEqual(store.recurringSeries(rid).map(\.viaUber), [nil, nil], "a series update with a mode removes both marks")

        // Car against Uber is a change of the trip.
        let original = await store.addEvent(title: "Compare ride", origin: home, destination: ferry,
                                            arrivalDate: at(2026, 12, 30, 9), mode: .car, uber: true,
                                            bufferMinutes: 5, notifyLeadMinutes: 10)
        let o = record(store, original.id) ?? original
        XCTAssertTrue(Store.legEditChangesOccurrence(
            original: o, title: o.title, origin: o.origin ?? home, destination: o.destination, baseDate: o.anchorDate,
            anchor: o.anchor ?? .arrival, mode: .car, uber: false, bufferMinutes: o.bufferMinutes,
            notifyLeadMinutes: o.notifyLeadMinutes, notifyEnabled: o.wantsNotification), "Uber to Car is a change")
        XCTAssertFalse(Store.legEditChangesOccurrence(
            original: o, title: o.title, origin: o.origin ?? home, destination: o.destination, baseDate: o.anchorDate,
            anchor: o.anchor ?? .arrival, mode: .car, uber: true, bufferMinutes: o.bufferMinutes,
            notifyLeadMinutes: o.notifyLeadMinutes, notifyEnabled: o.wantsNotification), "Uber to Uber is no change")
    }

    func testUBER_T16_aRepeatingActivityCarriesTheMarkToEveryLeg() async {
        // The fixture clock: Monday 2026-11-02 08:00.
        let clock = at(2026, 11, 2, 8)

        // An Uber outbound chip on a weekly repeat.
        let (store, _) = recordingStore()
        store.replanNow = { clock }
        var f = newActivityForm(title: "Standup", start: at(2026, 11, 2, 9), end: at(2026, 11, 2, 9, 30))
        choose(&f, LegRowKeys.outboundEnabled, "true")
        choose(&f, LegRowKeys.originQuery, home.name, place: home)
        choose(&f, LegRowKeys.outboundMode, "uber")
        commitRepeat(&f, "every Monday")
        XCTAssertNotNil(f.activeRecurrence)
        let saved = await store.saveManualActivity(f, calendarDefault: false)
        XCTAssertTrue(saved)
        let series = store.series.first
        XCTAssertNotNil(series)
        XCTAssertEqual(series?.legPlan?.outboundUber, true, "the leg plan keeps the outbound mark")
        await store.fillSeriesLegs(now: clock)
        let occurrences = filledOccurrenceIDs(series, now: clock)
        let outbound = legs(store, linkedTo: occurrences, role: .arrival)
        XCTAssertEqual(outbound.count, occurrences.count, "one outbound leg per filled occurrence")
        XCTAssertGreaterThanOrEqual(outbound.count, 2, "the fill made legs")
        for leg in outbound {
            XCTAssertEqual(leg.mode, .car)
            XCTAssertEqual(leg.viaUber, true, "every filled outbound leg carries the mark")
        }

        // A1: an Uber return chip on a weekly repeat, outbound off.
        let (returnStore, _) = recordingStore()
        returnStore.replanNow = { clock }
        var g = newActivityForm(title: "Gym", start: at(2026, 11, 2, 18), end: at(2026, 11, 2, 19))
        choose(&g, LegRowKeys.returnEnabled, "true")
        choose(&g, LegRowKeys.returnQuery, home.name, place: home)
        choose(&g, LegRowKeys.returnMode, "uber")
        commitRepeat(&g, "every Monday")
        XCTAssertNotNil(g.activeRecurrence)
        let savedReturn = await returnStore.saveManualActivity(g, calendarDefault: false)
        XCTAssertTrue(savedReturn)
        let returnSeries = returnStore.series.first
        XCTAssertNotNil(returnSeries)
        XCTAssertEqual(returnSeries?.legPlan?.returnUber, true, "A1: the leg plan keeps the return mark")
        await returnStore.fillSeriesLegs(now: clock)
        let returnOccurrences = filledOccurrenceIDs(returnSeries, now: clock)
        let returns = legs(returnStore, linkedTo: returnOccurrences, role: .departure)
        XCTAssertEqual(returns.count, returnOccurrences.count, "A1: one return leg per filled occurrence")
        XCTAssertGreaterThanOrEqual(returns.count, 2, "A1: the fill made return legs, so zero legs cannot pass")
        for leg in returns {
            XCTAssertEqual(leg.mode, .car)
            XCTAssertEqual(leg.viaUber, true, "A1: every filled return leg carries the mark")
        }

        // Return legs added to the whole first series with Uber.
        guard let weekly = series, let firstOccurrence = occurrences.first else { return XCTFail("no series or occurrence") }
        let eligible = store.previewSeriesLegAdd(activityId: firstOccurrence, role: .departure)?.eligibleIds ?? []
        XCTAssertGreaterThanOrEqual(eligible.count, 2, "the series has occurrences to add a return leg to")
        let counts = await store.addLegToSeries(editedActivityId: firstOccurrence, seriesId: weekly.id, role: .departure,
                                                outerPlace: home, mode: .car, uber: true, bufferMinutes: 0,
                                                notifyLeadMinutes: 10, targetActivityIds: eligible, editedDetaches: false)
        XCTAssertEqual(counts.added, eligible.count)
        let added = legs(store, linkedTo: eligible, role: .departure)
        XCTAssertEqual(added.count, eligible.count, "one return leg per eligible occurrence")
        for leg in added {
            XCTAssertEqual(leg.mode, .car)
            XCTAssertEqual(leg.viaUber, true, "every return leg added to the series carries the mark")
        }
    }

    // MARK: AC-010 - the departure alert

    func testUBER_T17_theDepartureAlertNamesUber() {
        let store = EmptyStore.make()
        var trip = ScheduledEvent(title: "Ride", origin: home, destination: ferry, arrivalDate: at(2026, 12, 7, 9),
                                  mode: .transit, bufferMinutes: 0, notifyLeadMinutes: 10)
        trip.departureDate = at(2026, 12, 7, 8, 35)
        trip.setTravel(.uber)
        let estimate = TravelEstimate(mode: .car, duration: 1500, distance: nil, source: "Test")
        let uberBody = store.notificationBody(for: trip, estimate: estimate)
        XCTAssertTrue(uberBody.hasPrefix("Uber to Ferry Building: 25 min. Leave at "), uberBody)
        trip.setTravel(.standard(.car))
        let carBody = store.notificationBody(for: trip, estimate: estimate)
        XCTAssertTrue(carBody.hasPrefix("Car to Ferry Building: "), carBody)
    }

    // MARK: AC-014, AC-015, AC-016 - the chat path

    func testUBER_T18_aUserNamedUberIsRoutedByCarAndStoredAsAnUberLeg() async {
        let rig = PlaceRig()
        _ = await rig.search("cafe")
        rig.tools.userLines = { ["Get me to the Ferry Building by Uber"] }
        let routesBefore = rig.routes.callCount
        let reply = await rig.travel("p1", "uber")
        XCTAssertTrue(reply.accepted, "uber is accepted after the user named Uber: \(reply.text ?? "no text")")
        XCTAssertEqual(reply.status, "ok")
        XCTAssertEqual(reply.json?["mode"] as? String, "uber")
        let handle = reply.json?["route_id"] as? String
        XCTAssertNotNil(handle)
        XCTAssertEqual(rig.routes.callCount - routesBefore, 1, "exactly one Routes request")
        XCTAssertEqual(PlaceBody.json(rig.routes.requests.last)?["travelMode"] as? String, "DRIVE", "an Uber trip is routed by car")

        let card = rig.create(place: "p1", route: handle ?? "r1").card
        XCTAssertNotNil(card)
        let leave = card?.lines.first { $0.hasPrefix("Leave ") }
        XCTAssertTrue(leave?.hasSuffix(" by Uber") ?? false, leave ?? "no leave line")
        if let card { _ = await card.resolve(.confirm) }
        XCTAssertEqual(rig.store.events.count, 1, "Confirm stores one leg")
        let leg = rig.store.events.first
        XCTAssertEqual(leg?.mode, .car)
        XCTAssertEqual(leg?.viaUber, true)
        XCTAssertEqual(leg?.travelChoice, .uber)
        let memory = rig.store.memoryLines.last
        XCTAssertTrue(memory?.contains("mode=car") ?? false, memory ?? "no memory line")
        XCTAssertFalse(memory?.lowercased().contains("uber") ?? true, memory ?? "no memory line")

        // A car route: the card says by car and the leg has no mark.
        let carRig = PlaceRig()
        _ = await carRig.search("cafe")
        let carReply = await carRig.travel("p1", "car")
        let carHandle = carReply.json?["route_id"] as? String
        XCTAssertNotNil(carHandle)
        let carCard = carRig.create(place: "p1", route: carHandle ?? "r1").card
        XCTAssertNotNil(carCard)
        let carLeave = carCard?.lines.first { $0.hasPrefix("Leave ") }
        XCTAssertTrue(carLeave?.hasSuffix(" by car") ?? false, carLeave ?? "no leave line")
        if let carCard { _ = await carCard.resolve(.confirm) }
        XCTAssertEqual(carRig.store.events.count, 1)
        XCTAssertNotNil(carRig.store.events.first)
        XCTAssertNil(carRig.store.events.first?.viaUber, "a car route stores no mark")
    }

    func testUBER_T19_theModelIsNeverOfferedUberAndCannotPickItAlone() async {
        let declarations = (try? JSONSerialization.jsonObject(with: AgentTools.declarationsJSON())) as? [[String: Any]] ?? []
        let travel = declarations.first { $0["name"] as? String == "get_travel_time" }
        let properties = (travel?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
        let mode = properties?["mode"] as? [String: Any]
        XCTAssertEqual(mode?["description"] as? String, Self.modeDescription)
        let text = String(decoding: AgentTools.declarationsJSON(), as: UTF8.self).lowercased()
        XCTAssertEqual(text.components(separatedBy: "uber").count - 1, 2, "uber occurs only in the mode sentence")
        XCTAssertFalse(PlaceText.mode.lowercased().contains("uber"))
        XCTAssertFalse(PlaceText.travelAsk.lowercased().contains("uber"))

        let rig = PlaceRig()
        _ = await rig.search("cafe")
        let lines = ["I'll take a cab", "Uberize the plan", "Ubermensch"]
        rig.tools.userLines = { lines }
        let routesBefore = rig.routes.callCount
        let refused = await rig.travel("p1", "uber")
        XCTAssertEqual(refused.message, PlaceText.mode, "no user line names Uber: \(refused.text ?? "no text")")
        XCTAssertFalse(refused.isLookup)
        XCTAssertEqual(rig.routes.callCount, routesBefore, "a refused call sends no request")

        rig.tools.userLines = { lines + ["Uber, please"] }
        let accepted = await rig.travel("p1", "uber")
        XCTAssertTrue(accepted.accepted, "positive control: a line naming Uber opens it: \(accepted.text ?? "no text")")
        XCTAssertEqual(accepted.status, "ok")
        for wrong in ["Uber", "UBER", " uber", "taxi", "ride share"] {
            let reply = await rig.travel("p1", wrong)
            XCTAssertEqual(reply.message, PlaceText.mode, "\(wrong.debugDescription) is refused")
            XCTAssertFalse(reply.isLookup, "\(wrong.debugDescription) looks nothing up")
        }
        let placeOnly = rig.create(place: "p1")
        XCTAssertEqual(placeOnly.message, PlaceText.travelAsk)
        XCTAssertNil(placeOnly.card)
    }

    func testUBER_T20_aLineNamesUberOnlyAsAWholeWordInAnyCase() {
        for line in ["Uber", "UBER", "take an uber.", "Uber's pickup", "(Uber)", "by-uber", "Uberize then Uber"] {
            XCTAssertTrue(TravelChoice.namesUber(line), "\(line.debugDescription) names Uber")
        }
        for line in ["Uberize", "Ubermensch", "UberX", "uber2", "uber²", "superuber", "éuber", "über", "I'll drive", ""] {
            XCTAssertFalse(TravelChoice.namesUber(line), "\(line.debugDescription) does not name Uber")
        }
    }
}
