import XCTest
@testable import besir

/// SPEC-UBERLINK-002 (card t123): Uber in the Plan my day dialog, the snap dialog and the partner card's `Travel mode` row.
/// An Uber choice is told to the model and looked up as a car; the day-plan card shows it as Uber and the stored legs carry
/// the mark. Every Uber rig is compared with a Car control built from the same inputs.

/// A calendar mirror that counts its day reads and gives no entry.
@MainActor
private final class UberPlanMirror: CalendarMirroring {
    private(set) var reads = 0
    func reconcile(_ activities: [ActivityBlock]) {}
    func entries(on day: Date, calendar: Calendar) async throws -> [CalendarEntry] {
        reads += 1
        return []
    }
}

/// A reader the text-only passes never call.
private final class UberPlanReader: VisionReading, @unchecked Sendable {
    let isConfigured = true
    func read(imageBase64: String, mime: String) async -> Result<VisionFields, VisionFailure> { .failure(.other) }
}

/// Stands in for the agent session of a plan: remembers each message, its shown line and its context, and accepts.
private final class UberPlanHandOff {
    private(set) var messages: [String] = []
    private(set) var shownLines: [String] = []
    private(set) var contexts: [DayPlanContext] = []

    func hand(_ message: String, _ shown: String, _ context: DayPlanContext) -> Bool {
        messages.append(message)
        shownLines.append(shown)
        contexts.append(context)
        return true
    }
}

@MainActor
private struct UberPlanRig {
    let inbox: SharedInbox
    let importer: SharedImport
    let mirror = UberPlanMirror()
    let reader = UberPlanReader()
    let handOff = UberPlanHandOff()
}

private func clue(_ kind: SnapKind = .foodPlace, name: String? = "Foo Kitchen", type: String? = nil, text: String? = nil,
                  title: String? = nil, time: String? = nil, confidence: Double = 0.9) -> SnapClue {
    SnapClue(kind: kind, name: name, placeType: type, text: text, title: title, time: time, confidence: confidence)
}

@MainActor
final class UberPickerTests: XCTestCase {
    // MARK: Fixtures copied from DayPlanToolTests

    private let p1 = Place(name: "Team HQ", address: "1 Main St", latitude: 37.78, longitude: -122.40)
    private let p2 = Place(name: "Foo Kitchen", address: "2 Mission St", latitude: 37.79, longitude: -122.41)
    private let p3 = Place(name: "Mission Hall", address: "3 Valencia St", latitude: 37.76, longitude: -122.42)
    private let p4 = Place(name: "Corner Cafe", address: "4 Market St", latitude: 37.77, longitude: -122.43)

    private func date(_ local: String) -> Date { TestClock.date("2026-10-27T" + local) }

    private func event(_ handle: String, _ title: String, _ start: String, _ end: String, place: Place?,
                       source: PlanMyDay.Source = .calendar) -> PlanMyDay.Event {
        PlanMyDay.Event(handle: handle, title: title, start: date(start), end: date(end), locationText: place?.name,
                        place: place, placeHandle: nil, source: source)
    }

    /// The day: A (event e1, P1) 17:00-18:00.
    private func dayA() -> PlanMyDay.Event { event("e1", "Team meeting", "17:00", "18:00", place: p1) }

    private func stopObject(_ title: String, _ start: String, _ end: String, place: String? = nil) -> [String: Any] {
        var object: [String: Any] = ["title": title, "start": "2026-10-27T" + start, "end": "2026-10-27T" + end]
        if let place { object["place_id"] = place }
        return object
    }

    private func encoded(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private var dayEnd: Date { TestClock.date("2026-10-28T00:00") }

    /// The day as the model proposes it: A is referenced, B at registry handle p1 (Foo Kitchen), C at p2 (Mission Hall).
    private func dayStops() -> [[String: Any]] {
        [["event": "e1"], stopObject("Dinner", "18:30", "19:30", place: "p1"), stopObject("Party", "19:45", "22:00", place: "p2")]
    }

    /// A rig in a plan turn (DayPlanToolTests `planRig`) with one added parameter: `viaUber` nil builds the context with the
    /// three-argument form, so the Car control reads the context's own default; a value is passed as the context's mark.
    private func planRig(routes: RoutesTransportStub = PlaceStubs.routesSequence([1080, 600]), mode: TransportMode = .car,
                         events: [PlanMyDay.Event]? = nil, viaUber: Bool? = nil) -> PlaceRig {
        let rig = PlaceRig(routes: routes, routesConfig: PlaceSentinel.config)
        _ = rig.tools.registry.register([p2, p3, p4])
        if let viaUber {
            rig.tools.beginDayPlan(DayPlanContext(mode: mode, events: events ?? [dayA()], checkWindowEnd: dayEnd, viaUber: viaUber))
        } else {
            rig.tools.beginDayPlan(DayPlanContext(mode: mode, events: events ?? [dayA()], checkWindowEnd: dayEnd))
        }
        return rig
    }

    private func check(_ rig: PlaceRig, _ stops: [[String: Any]]) async -> PlaceReply {
        await rig.run("check_day_plan", ["stops": encoded(stops)])
    }

    private func show(_ rig: PlaceRig, _ handle: String) async -> PlaceReply {
        await rig.run("show_day_plan", ["plan_id": handle])
    }

    /// One accepted check of `stops` (the day by default) and the card `show_day_plan` builds from it.
    private func dayCard(_ rig: PlaceRig, _ stops: [[String: Any]]? = nil, handle: String = "d1") async throws -> AgentCard {
        let checked = await check(rig, stops ?? dayStops())
        XCTAssertEqual(checked.status, "ok")
        let shown = await show(rig, handle)
        return try XCTUnwrap(shown.card, shown.text ?? "no card")
    }

    // MARK: Other rigs

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TestClock.zone
        return calendar
    }

    /// A share queue holding the same two text items (fixed received times) under the fixed clock.
    private func makePlanRig() throws -> UberPlanRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uber-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedInbox(directory: root.appendingPathComponent("inbox", isDirectory: true),
                                legacyFile: root.appendingPathComponent("pendingShares.json"))
        let log = ConnectionLog(fileURL: root.appendingPathComponent("log", isDirectory: true).appendingPathComponent(ConnectionLog.fileName))
        let importer = SharedImport(inbox: inbox, now: { TestClock.now }, connections: log)
#if DEBUG
        importer.logURL = root.appendingPathComponent("import.log")
#endif
        for (index, text) in ["Dinner with Sam at Foo Kitchen", "Party at Mission Hall after dinner"].enumerated() {
            let item = SharedInbox.Item(id: UUID(), receivedAt: TestClock.now.addingTimeInterval(-600 + Double(index + 1) * 10),
                                        text: text, imageBase64: nil, mimeType: nil)
            XCTAssertTrue(inbox.enqueue(item))
        }
        return UberPlanRig(inbox: inbox, importer: importer)
    }

    /// A place to eat has been found and the flow waits for the travel mode (SnapFlowTests `foodRig`).
    private func foodRig() async -> SnapRig {
        let rig = SnapRig(places: [.answer(PlacesTestSupport.nearbyAnswer([("Foo Kitchen", 120)]))])
        rig.reader.fallback = .success(clue(.foodPlace, name: "Foo Kitchen"))
        await rig.open()
        await rig.flow.submit(frame: SnapTestImages.small)
        return rig
    }

    private func makeTravelRig() -> TravelRig {
        let rig = TravelRig(shapes: [.placeTables()])
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        rig.store.memoryTimeZone = { TestClock.zone }
        return rig
    }

    /// A card for the partner whose Restaurant row is resolved by the partner, with a candidate tapped, `Travel` on and, when
    /// given, a mode chosen by its option id (PartnerTravelTests `tappedCard`, with a `String` mode id).
    private func tappedCard(_ rig: TravelRig, mode: String?, travelOn: Bool = true) async throws -> (AgentCard, AgentFieldCard) {
        let built = await rig.card(.init(restaurant: nil))
        let card = try XCTUnwrap(built)
        let fields = try XCTUnwrap(card.fieldCard)
        fields.search("restaurant", "Pasta")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(fields.choosePlace("restaurant", PartnerPlaceFixture.branches[1]))
        if travelOn { XCTAssertTrue(fields.chooseOption(AgentPartner.cardTravelKey, AgentFieldSpec.onValue)) }
        if let mode { XCTAssertTrue(fields.chooseOption(AgentPartner.cardModeKey, mode), "the row offers \(mode)") }
        return (card, fields)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: T01 the dialogs

    func testUBER2_T01_theDialogsListCarUberTransitWalkBicycleFromTheRule() throws {
        XCTAssertEqual(PlanMyDay.modeChoices, [.standard(.car), .uber, .standard(.transit), .standard(.walk), .standard(.bicycle)])
        XCTAssertEqual(PlanMyDay.modeChoices.map(\.title), ["Car", "Uber", "Transit", "Walk", "Bicycle"])
        XCTAssertEqual(PlanMyDay.modeChoices.map(\.value), ["car", "uber", "transit", "walk", "bicycle"])

        let root = try source("Shared/RootView.swift")
        XCTAssertTrue(root.contains("confirmationDialog"), "positive control: the Plan my day dialog is in this file")
        XCTAssertTrue(root.contains(#"ForEach(PlanMyDay.modeChoices, id: \.self) { choice in"#))
        XCTAssertTrue(root.contains("Button(choice.title)"))
        XCTAssertTrue(root.contains("runPlan(mode: choice.mode, viaUber: choice == .uber)"), "the Uber button passes the mark")
        XCTAssertTrue(root.contains(#""How will you travel today?""#))
        XCTAssertTrue(root.contains(#"Button("Cancel", role: .cancel) {}"#))
        XCTAssertFalse(root.contains("Button(mode.title)"))

        let snap = try source("Shared/SnapView.swift")
        XCTAssertTrue(snap.contains("confirmationDialog"), "positive control: the snap dialog is in this file")
        XCTAssertTrue(snap.contains(#"ForEach(PlanMyDay.modeChoices, id: \.self) { choice in"#))
        XCTAssertTrue(snap.contains("flow.chooseMode(choice.mode, viaUber: choice == .uber)"), "the Uber button passes the mark")
        XCTAssertTrue(snap.contains("flow.chooseMode(nil)"), "the dismiss path is unchanged")
        XCTAssertTrue(snap.contains("confirmationDialog(SnapLine.travelTitle"))
    }

    // MARK: T02 the plan pass

    func testUBER2_T02_anUberPlanPassTellsTheModelCarAndMarksTheContext() async throws {
        let uber = try makePlanRig()
        let car = try makePlanRig()
        await uber.importer.planPass(mode: .car, viaUber: true, vision: uber.reader, activities: { [] }, mirror: uber.mirror,
                                     calendar: calendar, prepare: { $0 }, canHand: { true }, hand: uber.handOff.hand)
        await car.importer.planPass(mode: .car, vision: car.reader, activities: { [] }, mirror: car.mirror,
                                    calendar: calendar, prepare: { $0 }, canHand: { true }, hand: car.handOff.hand)

        XCTAssertEqual(uber.handOff.messages.count, 1, "the Uber pass hands once")
        XCTAssertEqual(car.handOff.messages.count, 1, "the Car pass hands once")
        let message = try XCTUnwrap(uber.handOff.messages.first)
        XCTAssertEqual(message, car.handOff.messages.first, "the model gets the Car message")
        XCTAssertTrue(message.contains("I will travel by car. Do not ask me how I travel."))
        XCTAssertFalse(message.lowercased().contains("uber"))
        XCTAssertEqual(uber.handOff.shownLines, car.handOff.shownLines)

        let uberContext = try XCTUnwrap(uber.handOff.contexts.first)
        XCTAssertEqual(uberContext.mode, .car)
        XCTAssertTrue(uberContext.viaUber)
        XCTAssertEqual(uberContext.choice, .uber)
        let carContext = try XCTUnwrap(car.handOff.contexts.first)
        XCTAssertFalse(carContext.viaUber)
        XCTAssertEqual(carContext.choice, .standard(.car))
    }

    // MARK: T03 the snap flow

    func testUBER2_T03_anUberSnapChoiceTellsTheModelCarAndMarksTheContext() async throws {
        let uber = await foodRig()
        let car = await foodRig()
        await uber.flow.chooseMode(.car, viaUber: true)
        await car.flow.chooseMode(.car)
        guard case .plan(let uberText, let uberShown, let uberContext, _)? = uber.flow.takeOutcome() else {
            return XCTFail("the Uber choice gives a plan outcome")
        }
        guard case .plan(let carText, let carShown, let carContext, _)? = car.flow.takeOutcome() else {
            return XCTFail("the Car choice gives a plan outcome")
        }
        XCTAssertEqual(uberText, carText, "the model gets the Car message")
        XCTAssertTrue(uberText.contains("I will travel by car. Do not ask me how I travel."))
        XCTAssertFalse(uberText.lowercased().contains("uber"))
        XCTAssertEqual(uberShown, SnapMessage.shownMeal)
        XCTAssertEqual(carShown, SnapMessage.shownMeal)
        XCTAssertEqual(uber.registered.map(\.name), ["Foo Kitchen"])
        XCTAssertEqual(uber.prepared, 1)
        XCTAssertEqual(uberContext.choice, .uber)
        XCTAssertEqual(carContext.choice, .standard(.car))
        XCTAssertNil(uber.flow.takeOutcome(), "one tap, one outcome")

        // Cancel, or the dialog dismissed, ends with nothing whatever the mark says.
        let cancelled = await foodRig()
        await cancelled.flow.chooseMode(nil, viaUber: true)
        XCTAssertEqual(cancelled.flow.phase, .done)
        XCTAssertNil(cancelled.flow.takeOutcome())
        XCTAssertEqual(cancelled.prepared, 0)
        XCTAssertEqual(cancelled.mirror.reads, 0)
    }

    // MARK: T04 the day-plan check and card

    func testUBER2_T04_anUberDayPlanIsCheckedByCarWithTheSameResultAndShownByUber() async throws {
        let uber = planRig(viaUber: true)
        let car = planRig()
        uber.tools.userLines = { [] }
        car.tools.userLines = { [] }

        let uberCheck = await check(uber, dayStops())
        let carCheck = await check(car, dayStops())
        XCTAssertEqual(uberCheck.status, "ok")
        XCTAssertEqual(carCheck.status, "ok")
        let uberText = try XCTUnwrap(uberCheck.text)
        XCTAssertEqual(uberText, carCheck.text, "the model gets the Car result")
        XCTAssertFalse(uberText.lowercased().contains("uber"))

        XCTAssertEqual(uber.routes.callCount, 2)
        XCTAssertEqual(car.routes.callCount, 2)
        for request in uber.routes.requests + car.routes.requests {
            XCTAssertEqual(PlaceBody.json(request)?["travelMode"] as? String, "DRIVE")
        }
        XCTAssertEqual(uber.routes.requests.map(\.url), car.routes.requests.map(\.url))
        XCTAssertEqual(uber.routes.requests.map { $0.value(forHTTPHeaderField: GoogleRoutes.fieldMaskHeader) },
                       car.routes.requests.map { $0.value(forHTTPHeaderField: GoogleRoutes.fieldMaskHeader) })
        XCTAssertEqual(uber.routes.requests.map(\.httpBody), car.routes.requests.map(\.httpBody), "the same Routes requests, in order")

        XCTAssertEqual(uber.tools.checks.last?.legs.compactMap(\.route).map(\.viaUber), [true, true])
        XCTAssertEqual(car.tools.checks.last?.legs.compactMap(\.route).map(\.viaUber), [false, false])

        let uberShow = await show(uber, "d1")
        let carShow = await show(car, "d1")
        let uberCard = try XCTUnwrap(uberShow.card)
        let carCard = try XCTUnwrap(carShow.card)
        XCTAssertEqual(uberCard.lines, [
            "Plan for today",
            "5:00 PM - 6:00 PM Team meeting",
            "Leave 6:07 PM - 18 min by Uber - Verified by Routes",
            "6:30 PM - 7:30 PM Dinner (new)",
            "At Foo Kitchen",
            "Leave 7:30 PM - 10 min by Uber - Verified by Routes",
            "7:45 PM - 10:00 PM Party (new)",
            "At Mission Hall"])
        XCTAssertEqual(carCard.lines, [
            "Plan for today",
            "5:00 PM - 6:00 PM Team meeting",
            "Leave 6:07 PM - 18 min by car - Verified by Routes",
            "6:30 PM - 7:30 PM Dinner (new)",
            "At Foo Kitchen",
            "Leave 7:30 PM - 10 min by car - Verified by Routes",
            "7:45 PM - 10:00 PM Party (new)",
            "At Mission Hall"])
        XCTAssertEqual(uberShow.text, carShow.text)
    }

    // MARK: T05 Confirm of the day plan

    func testUBER2_T05_confirmingAnUberDayPlanStoresCarLegsWithTheMarkAndRemembersCar() async throws {
        let uber = planRig(viaUber: true)
        let uberCard = try await dayCard(uber)
        let uberLookups = uber.store.drvTravelLookupCount
        let uberResolution = await uberCard.resolve(.confirm)
        XCTAssertEqual(uberResolution?.status, "applied")
        XCTAssertEqual(uber.store.events.count, 2)
        XCTAssertEqual(uber.store.activities.map(\.title), ["Dinner", "Party"])
        let uberLegs = uber.store.activities.compactMap { activity in uber.store.events.first { $0.linkedActivityId == activity.id } }
        XCTAssertEqual(uberLegs.count, 2, "both legs, Dinner and Party")
        XCTAssertEqual(uberLegs.map(\.mode), [.car, .car])
        XCTAssertEqual(uberLegs.map(\.viaUber), [true, true])
        XCTAssertEqual(uberLegs.map(\.travelChoice), [.uber, .uber])
        XCTAssertEqual(uberLegs.map(\.travelSeconds), [1080, 600])
        XCTAssertEqual(uber.routes.callCount, 2, "no toolbox lookup at Confirm")
        XCTAssertEqual(uber.store.drvTravelLookupCount, uberLookups, "no Store lookup at Confirm")
        let uberMemory = uber.store.memoryLines.filter { $0.contains("| activity |") }
        XCTAssertEqual(uberMemory.count, 2)
        for line in uberMemory {
            XCTAssertTrue(line.contains("| mode=car"), line)
            XCTAssertFalse(line.lowercased().contains("uber"), line)
        }

        let car = planRig()
        let carCard = try await dayCard(car)
        let carLookups = car.store.drvTravelLookupCount
        let carResolution = await carCard.resolve(.confirm)
        XCTAssertEqual(carResolution?.status, "applied")
        let carLegs = car.store.activities.compactMap { activity in car.store.events.first { $0.linkedActivityId == activity.id } }
        XCTAssertEqual(carLegs.count, 2)
        XCTAssertEqual(carLegs.map(\.viaUber), [nil, nil])
        XCTAssertEqual(carLegs.map(\.travelChoice), [.standard(.car), .standard(.car)])
        XCTAssertEqual(car.store.drvTravelLookupCount, carLookups)
        let carMemory = car.store.memoryLines.filter { $0.contains("| activity |") }
        XCTAssertEqual(carMemory.count, 2, "positive control: the day-plan rig writes the activity lines")
        XCTAssertEqual(uberMemory, carMemory)
    }

    // MARK: T06 the context

    func testUBER2_T06_theContextReadsUberOnlyForCarWithTheMark() {
        let plain = DayPlanContext(mode: .car, events: [], checkWindowEnd: TestClock.now)
        XCTAssertFalse(plain.viaUber)
        XCTAssertEqual(plain.choice, .standard(.car))
        XCTAssertEqual(DayPlanContext(mode: .car, events: [], checkWindowEnd: TestClock.now, viaUber: true).choice, .uber)
        for mode in [TransportMode.transit, .walk, .bicycle] {
            XCTAssertEqual(DayPlanContext(mode: mode, events: [], checkWindowEnd: TestClock.now, viaUber: true).choice, .standard(mode),
                           "\(mode)")
        }
        let unread = DayPlanContext(mode: .car, events: [], checkWindowEnd: TestClock.now, calendarAvailable: false, viaUber: true)
        XCTAssertEqual(unread.choice, .uber)
        XCTAssertFalse(unread.calendarAvailable)
    }

    // MARK: T07 the partner row

    func testUBER2_T07_thePartnerTravelModeRowOffersTheFiveChoicesBlank() async throws {
        let rig = makeTravelRig()
        let built = await rig.card(.init(restaurant: nil))
        let card = try XCTUnwrap(built)
        let fields = try XCTUnwrap(card.fieldCard)
        XCTAssertTrue(fields.chooseOption(AgentPartner.cardTravelKey, AgentFieldSpec.onValue))
        XCTAssertEqual(fields.field(AgentPartner.cardModeKey)?.options.map(\.label), ["Car", "Uber", "Transit", "Walk", "Bicycle"])
        XCTAssertEqual(fields.field(AgentPartner.cardModeKey)?.options.map(\.value), ["car", "uber", "transit", "walk", "bicycle"])
        XCTAssertNil(fields.values.entry(AgentPartner.cardModeKey)?.value)
        XCTAssertEqual(fields.source(of: AgentPartner.cardModeKey), .blank)
        XCTAssertFalse(fields.chooseOption(AgentPartner.cardModeKey, "Uber"))
        XCTAssertFalse(fields.chooseOption(AgentPartner.cardModeKey, "UBER"))
        XCTAssertFalse(fields.chooseOption(AgentPartner.cardModeKey, " uber"))
        XCTAssertTrue(fields.chooseOption(AgentPartner.cardModeKey, "uber"))
    }

    // MARK: T08 the partner booking

    func testUBER2_T08_anUberPartnerBookingLooksUpOnceByCarAndStoresTheMarkedLeg() async throws {
        let expectedLine = "- 2026-10-28 | Wed | 7:00 PM | partner | Pasta Palace | mode=car | partner=Example Tables | quantity=2"

        let uber = makeTravelRig()
        let (uberCard, _) = try await tappedCard(uber, mode: "uber")
        let uberLookups = uber.store.drvTravelLookupCount
        let uberResolved = await uberCard.resolve(.confirm)
        let uberResolution = try XCTUnwrap(uberResolved)
        XCTAssertEqual(uberResolution.status, "applied")
        XCTAssertEqual(uber.routes.callCount, 1)
        let uberRequest = try XCTUnwrap(uber.routes.requests.first)
        XCTAssertEqual(PlaceBody.json(uberRequest)?["travelMode"] as? String, "DRIVE")
        XCTAssertEqual(uber.store.drvTravelLookupCount, uberLookups, "no Store lookup at Confirm")
        let uberEntry = try XCTUnwrap(uber.store.activities.first)
        let uberLegs = uber.store.events.filter { $0.linkedActivityId == uberEntry.id }
        XCTAssertEqual(uberLegs.count, 1)
        let uberLeg = try XCTUnwrap(uberLegs.first)
        XCTAssertEqual(uberLeg.mode, .car)
        XCTAssertEqual(uberLeg.viaUber, true)
        XCTAssertEqual(uberLeg.travelChoice, .uber)
        XCTAssertEqual(uberLeg.travelSeconds, 900)
        XCTAssertEqual(uberLeg.anchor, .arrival)
        let packets = await uber.packets()
        let routePackets = packets.filter { $0.kind == .route }
        XCTAssertEqual(routePackets.count, 1)
        XCTAssertEqual(routePackets.first?.summary, "Car route")
        let flow = try XCTUnwrap(routePackets.first?.flowID)
        XCTAssertEqual(packets.filter { $0.flowID == flow }.map(\.summary),
                       ["Car route", "Example Tables: Request sent", "Example Tables: Request confirmed"])
        let uberValues = try XCTUnwrap(uber.partner.bodies(op: "submit").first?["values"] as? NSDictionary)
        XCTAssertEqual(Set(uberValues.allKeys.compactMap { $0 as? String }), ["restaurant", "party_size", "start", "name"])
        XCTAssertEqual(Set(try XCTUnwrap(uberResolution.json).keys),
                       ["status", "partner", "simulated", "results", "message", "id", "title", "start", "end"])
        XCTAssertEqual(uber.store.memoryLines, [expectedLine])

        // The car control: the same steps with the mode id `car`.
        let car = makeTravelRig()
        let (carCard, _) = try await tappedCard(car, mode: "car")
        let carLookups = car.store.drvTravelLookupCount
        let carResolved = await carCard.resolve(.confirm)
        let carResolution = try XCTUnwrap(carResolved)
        XCTAssertEqual(carResolution.status, "applied")
        XCTAssertEqual(car.store.drvTravelLookupCount, carLookups)
        let carEntry = try XCTUnwrap(car.store.activities.first)
        let carLeg = try XCTUnwrap(car.store.events.first { $0.linkedActivityId == carEntry.id })
        XCTAssertNil(carLeg.viaUber)
        XCTAssertEqual(carLeg.travelChoice, .standard(.car))
        XCTAssertEqual(car.store.memoryLines, [expectedLine])

        // Against the control: the partner gets the same values, Routes the same request, the model the same result but the id.
        let carValues = try XCTUnwrap(car.partner.bodies(op: "submit").first?["values"] as? NSDictionary)
        XCTAssertEqual(uberValues, carValues)
        let carRequest = try XCTUnwrap(car.routes.requests.first)
        XCTAssertEqual(uberRequest.url, carRequest.url)
        XCTAssertEqual(uberRequest.value(forHTTPHeaderField: GoogleRoutes.fieldMaskHeader),
                       carRequest.value(forHTTPHeaderField: GoogleRoutes.fieldMaskHeader))
        XCTAssertEqual(uberRequest.httpBody, carRequest.httpBody)
        let uberID = try XCTUnwrap(uberResolution.json?["id"] as? String)
        let carID = try XCTUnwrap(carResolution.json?["id"] as? String)
        XCTAssertEqual(uberResolution.result.replacingOccurrences(of: uberID, with: ""),
                       carResolution.result.replacingOccurrences(of: carID, with: ""))
    }
}
