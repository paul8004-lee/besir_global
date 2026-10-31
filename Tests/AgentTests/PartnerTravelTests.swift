import XCTest
import CoreLocation
@testable import besir

/// How often the toolbox asked for its directions provider.
@MainActor
final class TravelCalls {
    var count = 0
}

/// A toolbox over an empty Store with the fixed clock, a stubbed partner, a stubbed Routes transport, a partner-record file in a
/// temporary folder and a connection log on a temporary file. The partner Confirm reads the travel rows through it
/// (SPEC-LATESWITCH-001, card t72). Built here because the merged `PartnerRig` takes no directions or record provider.
@MainActor
final class TravelRig {
    let store: Store
    let clock = MutableClock()
    let partner = StubPartner()
    let log: ConnectionLog
    let box: BookingConfigBox
    let tools: AgentToolbox
    let folder: URL
    let routes: RoutesTransportStub
    let places: PlacesTransportStub?
    let records: PartnerRecords
    let ledger: BudgetLedger
    let budget: BudgetToolPartner?
    let position = DevicePosition()
    let providerCalls = TravelCalls()

    init(shapes: [StubPartner.Shape] = [.tables()], routes: RoutesTransportStub = PlaceStubs.routesSequence([900]),
         budget: BudgetToolPartner? = nil, places: PlacesTransportStub? = nil,
         recordsWrite: @escaping @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite) {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("partner-travel-\(UUID().uuidString)", isDirectory: true)
        let log = ConnectionLog(fileURL: folder.appendingPathComponent(ConnectionLog.fileName))
        let box = BookingConfigBox(PlaceSentinel.config)
        let ledger = BudgetLedger(fileURL: folder.appendingPathComponent(BudgetLedger.fileName))
        let records = PartnerRecords(fileURL: folder.appendingPathComponent(PartnerRecords.fileName), write: recordsWrite)
        let clock = self.clock
        let position = self.position
        let calls = self.providerCalls
        let partner = self.partner
        partner.shapes = shapes
        var budgetClient: (() -> BudgetClient)?
        if let budget {
            budgetClient = { BudgetClient(config: box.config, ledger: ledger, send: budget.send, connections: log) }
        }
        var search: (() -> PlaceSearch)?
        if let places {
            search = { PlaceSearch(config: PlacesTestSupport.config, transport: places.transport, connections: log) }
        }
        tools = AgentToolbox(store: store, now: { clock.now }, timeZone: { clock.zone },
                             deviceOrigin: { position.place },
                             places: search,
                             directions: { calls.count += 1; return DirectionsService(config: PlaceSentinel.config, transport: routes.transport, connections: log) },
                             partners: { PartnerClient(config: box.config, send: partner.send, connections: log) },
                             budget: budgetClient,
                             partnerRecords: { records })
        self.store = store
        self.log = log
        self.box = box
        self.folder = folder
        self.routes = routes
        self.places = places
        self.records = records
        self.ledger = ledger
        self.budget = budget
    }

    func call(_ name: String, _ args: [String: Any] = [:]) -> AgentToolOutcome {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return tools.handle(name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    /// `get_partners` run to its end, then `request_partner` for the fill. Nil when the gate refused.
    func card(_ fill: PartnerRig.Fill = .init(), partner id: String = "booking") async -> AgentCard? {
        let line = PartnerRig.parts(fill).line
        tools.userLines = { [line] }
        if case .lookup(let lookup) = call("get_partners") { _ = await lookup.run() }
        return call("request_partner", PartnerRig.arguments(fill, partner: id)).card
    }

    /// The packets once the log has written them, oldest first.
    func packets() async -> [ConnectionPacket] {
        await log.flush()
        return log.packets
    }
}

/// SPEC-LATESWITCH-001 AC-012 (REQ-004): the booking card's `Travel` rows, the one Routes lookup at Confirm and the leg.
@MainActor
final class PartnerTravelTests: XCTestCase {
    private func makeRig(shapes: [StubPartner.Shape] = [.tables()], routes: RoutesTransportStub = PlaceStubs.routesSequence([900]),
                         places: PlacesTransportStub? = nil) -> TravelRig {
        let rig = TravelRig(shapes: shapes, routes: routes, places: places)
        let folder = rig.folder
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return rig
    }

    private func model(_ card: AgentCard) throws -> AgentFieldCard { try XCTUnwrap(card.fieldCard) }

    private func built(_ rig: TravelRig, _ fill: PartnerRig.Fill = .init(), partner: String = "booking") async throws -> AgentCard {
        let card = await rig.card(fill, partner: partner)
        return try XCTUnwrap(card)
    }

    private func confirm(_ card: AgentCard) async throws -> AgentResolution {
        let resolution = await card.resolve(.confirm)
        return try XCTUnwrap(resolution)
    }

    private func typeAndPause(_ fields: AgentFieldCard, _ key: String, _ text: String) async throws {
        fields.search(key, text)
        try await Task.sleep(nanoseconds: 800_000_000)
    }

    /// A card for the partner whose Restaurant row is resolved by the partner, with a candidate tapped, `Travel` on and, when
    /// given, a mode chosen.
    private func tappedCard(_ rig: TravelRig, mode: TransportMode?, travelOn: Bool = true) async throws -> (AgentCard, AgentFieldCard) {
        let card = try await built(rig, .init(restaurant: nil))
        let fields = try model(card)
        try await typeAndPause(fields, "restaurant", "Pasta")
        XCTAssertTrue(fields.choosePlace("restaurant", PartnerPlaceFixture.branches[1]))
        if travelOn { XCTAssertTrue(fields.chooseOption(AgentPartner.cardTravelKey, AgentFieldSpec.onValue)) }
        if let mode { XCTAssertTrue(fields.chooseOption(AgentPartner.cardModeKey, mode.rawValue)) }
        return (card, fields)
    }

    private func waypoint(_ request: URLRequest?, _ key: String) -> (latitude: Double, longitude: Double)? {
        PlaceBody.waypoint(PlaceBody.json(request), key)
    }

    // MARK: V01 the row at build

    func testV01_TheCardHoldsTravelDontAddAfterTheLengthAndIsReady() async throws {
        let rig = makeRig()
        let card = try await built(rig)
        let fields = try model(card)
        XCTAssertEqual(card.lines.count, 10)
        XCTAssertEqual(card.lines[7], "Length (min): 60")
        XCTAssertEqual(card.lines[8], "Travel: Don't Add")
        XCTAssertEqual(card.lines.last, "Example Tables - Simulated")
        XCTAssertEqual(fields.card.fields.map(\.key),
                       ["restaurant", "party_size", "start", "name", "note", "add-to-schedule", "schedule-length", "schedule-travel", "0"])
        XCTAssertEqual(fields.values.flag("schedule-travel"), false)
        XCTAssertEqual(fields.source(of: "schedule-travel"), .inferred)
        XCTAssertEqual(fields.field("schedule-travel")?.label, "Travel")
        XCTAssertEqual(fields.field("schedule-travel")?.options.map(\.label), ["Add", "Don't Add"])
        XCTAssertTrue(fields.isReady)
        XCTAssertTrue(card.canConfirm)
        XCTAssertNil(fields.field("schedule-from"))
        XCTAssertNil(fields.field("schedule-mode"))
        // The schedule switch off takes the Travel group away with the length, and on brings it back as it was.
        XCTAssertTrue(fields.chooseOption("add-to-schedule", "false"))
        XCTAssertNil(fields.field("schedule-travel"))
        XCTAssertTrue(fields.chooseOption("add-to-schedule", "true"))
        XCTAssertEqual(fields.values.flag("schedule-travel"), false)
    }

    // MARK: V02 turning it on

    func testV02_TravelOnShowsLeaveFromAndTheModeAndTheGoogleMarkFollowsTheRow() async throws {
        let places = PlacesTransportStub.answering(with: PlaceFixture.data("places-search-three"))
        let rig = makeRig(places: places)
        let card = try await built(rig)
        let fields = try model(card)
        XCTAssertFalse(card.showsGoogleMark, "the stub form has no place field and Travel is off")
        XCTAssertTrue(fields.chooseOption("schedule-travel", "true"))
        XCTAssertEqual(fields.card.fields.map(\.key),
                       ["restaurant", "party_size", "start", "name", "note", "add-to-schedule", "schedule-length", "schedule-travel",
                        "schedule-from", "schedule-mode", "0"])
        XCTAssertFalse(fields.card.fields.map(\.key).contains("schedule-place"), "there is no Place row")
        XCTAssertEqual(fields.field("schedule-from")?.label, "Leave from")
        XCTAssertEqual(fields.values.entry("schedule-from")?.value, .place(DeliveryToolFixture.device))
        XCTAssertEqual(fields.source(of: "schedule-from"), .inferred)
        XCTAssertEqual(fields.field("schedule-mode")?.label, "Travel mode")
        XCTAssertEqual(fields.field("schedule-mode")?.options.map(\.label), ["Car", "Transit", "Walk", "Bicycle"])
        XCTAssertNil(fields.values.entry("schedule-mode")?.value)
        XCTAssertEqual(fields.source(of: "schedule-mode"), .blank)
        XCTAssertFalse(fields.isReady, "the mode is required while shown")
        XCTAssertFalse(card.canConfirm)
        XCTAssertTrue(card.showsGoogleMark, "the Leave from row shows Google results")
        XCTAssertTrue(fields.chooseOption("schedule-mode", "walk"))
        XCTAssertTrue(fields.isReady)
        XCTAssertTrue(card.canConfirm)

        // A search typed in Leave from is centred on the device position; a picked Leave from place does not move the centre.
        try await typeAndPause(fields, "schedule-from", "Library")
        XCTAssertEqual(places.requests.count, 1)
        let first = try XCTUnwrap(PlaceBody.biasCenter(PlaceBody.json(places.requests.last)))
        XCTAssertEqual(first.latitude, DeliveryToolFixture.device.latitude, accuracy: 1e-9)
        XCTAssertEqual(first.longitude, DeliveryToolFixture.device.longitude, accuracy: 1e-9)
        XCTAssertTrue(fields.choosePlace("schedule-from", DeliveryToolFixture.library))
        XCTAssertNotEqual(DeliveryToolFixture.library.latitude, DeliveryToolFixture.device.latitude)
        try await typeAndPause(fields, "schedule-from", "Museum")
        XCTAssertEqual(places.requests.count, 2)
        let second = try XCTUnwrap(PlaceBody.biasCenter(PlaceBody.json(places.requests.last)))
        XCTAssertEqual(second.latitude, DeliveryToolFixture.device.latitude, accuracy: 1e-9)
        XCTAssertEqual(second.longitude, DeliveryToolFixture.device.longitude, accuracy: 1e-9)

        // Off removes the rows and the mark is the base's again.
        XCTAssertTrue(fields.chooseOption("schedule-travel", "false"))
        XCTAssertNil(fields.field("schedule-from"))
        XCTAssertNil(fields.field("schedule-mode"))
        XCTAssertFalse(card.showsGoogleMark)
        XCTAssertTrue(fields.isReady)

        // No device position: the same search carries no bias.
        let bare = makeRig(places: places)
        bare.position.place = nil
        let bareCard = try await built(bare)
        let bareFields = try model(bareCard)
        XCTAssertTrue(bareFields.chooseOption("schedule-travel", "true"))
        let before = places.requests.count
        try await typeAndPause(bareFields, "schedule-from", "Library")
        XCTAssertEqual(places.requests.count, before + 1)
        XCTAssertNil(PlaceBody.biasCenter(PlaceBody.json(places.requests.last)), "no position, no locationBias")

        // A form with a place field has the mark with Travel off, as at the base.
        let marked = makeRig(shapes: [.placeTables()])
        let markedCard = try await built(marked, .init(restaurant: nil))
        XCTAssertTrue(markedCard.showsGoogleMark)
    }

    // MARK: V03 no device origin

    func testV03_WithoutADeviceOriginLeaveFromIsBlankAndRequired() async throws {
        let rig = makeRig()
        rig.position.place = nil
        let card = try await built(rig)
        let fields = try model(card)
        XCTAssertTrue(card.canConfirm, "Travel is off")
        XCTAssertTrue(fields.chooseOption("schedule-travel", "true"))
        XCTAssertNotNil(fields.field("schedule-from"))
        XCTAssertNil(fields.values.entry("schedule-from")?.value)
        XCTAssertEqual(fields.source(of: "schedule-from"), .blank)
        XCTAssertTrue(fields.chooseOption("schedule-mode", "car"))
        XCTAssertFalse(fields.isReady, "Leave from is required while shown")
        XCTAssertTrue(fields.choosePlace("schedule-from", DeliveryToolFixture.library))
        XCTAssertTrue(fields.isReady)
    }

    // MARK: V04 Confirm with Travel on

    func testV04_ConfirmWithTravelOnLooksUpOnceWritesTheLegAndRefusesWhatCannotHaveOne() async throws {
        try await confirmWritesTheEntryWithItsLeg()
        try await noRouteEndsConfirmUnavailable()
        try await missingValuesAreRefusedAsAnEditWithNoLookup()
    }

    private func confirmWritesTheEntryWithItsLeg() async throws {
        let branches = PartnerPlaceFixture.branches
        let rig = makeRig(shapes: [.placeTables(candidates: { _, _ in branches })], routes: PlaceStubs.routesSequence([900]))
        let (card, fields) = try await tappedCard(rig, mode: .transit)
        XCTAssertTrue(card.canConfirm)
        XCTAssertEqual(fields.values.entry("schedule-from")?.value, .place(DeliveryToolFixture.device))
        let resolution = try await confirm(card)

        XCTAssertEqual(resolution.status, "applied")
        XCTAssertEqual(card.mark, .confirmed)
        XCTAssertEqual(rig.providerCalls.count, 1)
        XCTAssertEqual(rig.routes.callCount, 1, "one lookup, and the Store makes no second one")
        let routeRequest = rig.routes.requests.first
        XCTAssertEqual(PlaceBody.json(routeRequest)?["travelMode"] as? String, "TRANSIT")
        let origin = try XCTUnwrap(waypoint(routeRequest, "origin"))
        XCTAssertEqual(origin.latitude, DeliveryToolFixture.device.latitude, accuracy: 1e-9)
        XCTAssertEqual(origin.longitude, DeliveryToolFixture.device.longitude, accuracy: 1e-9)
        let destination = try XCTUnwrap(waypoint(routeRequest, "destination"))
        XCTAssertEqual(destination.latitude, branches[1].latitude, accuracy: 1e-9)
        XCTAssertEqual(destination.longitude, branches[1].longitude, accuracy: 1e-9)

        // The entry carries the tapped candidate and one arrival leg from Leave from.
        let entry = try XCTUnwrap(rig.store.activities.first)
        XCTAssertEqual(rig.store.activities.count, 1)
        XCTAssertEqual(entry.location, branches[1])
        let legs = rig.store.events.filter { $0.linkedActivityId == entry.id }
        XCTAssertEqual(legs.count, 1)
        XCTAssertEqual(rig.store.events.count, 1)
        let leg = try XCTUnwrap(legs.first)
        XCTAssertEqual(leg.origin, DeliveryToolFixture.device)
        XCTAssertEqual(leg.destination, branches[1])
        XCTAssertEqual(leg.mode, .transit)
        XCTAssertEqual(leg.bufferMinutes, 0)
        XCTAssertEqual(leg.notifyLeadMinutes, 0)
        XCTAssertEqual(leg.anchor, .arrival)
        XCTAssertEqual(leg.arrivalDate, entry.startDate)
        XCTAssertEqual(leg.travelSeconds, 900, "the looked-up time is the leg's")

        // The partner's submit body is the base's: no travel value leaves in it.
        let submits = rig.partner.bodies(op: "submit")
        XCTAssertEqual(submits.count, 1)
        let sent = try XCTUnwrap(submits.first)
        XCTAssertEqual(Set(sent.keys), ["op", "request_id", "values"])
        let values = try XCTUnwrap(sent["values"] as? [String: Any])
        XCTAssertEqual(Set(values.keys), ["restaurant", "party_size", "start", "name"])
        XCTAssertEqual(values["restaurant"] as? String, branches[1].address)
        XCTAssertFalse(String(decoding: try XCTUnwrap(rig.partner.requests.last?.httpBody), as: UTF8.self).contains(DeliveryToolFixture.device.address))

        // The booking's flow: the one route packet, then the partner's two. The Restaurant lookup has a flow of its own.
        let packets = await rig.packets()
        let routePackets = packets.filter { $0.kind == .route }
        XCTAssertEqual(routePackets.count, 1)
        let route = try XCTUnwrap(routePackets.first)
        XCTAssertEqual(route.from, .besir)
        XCTAssertEqual(route.to, .googleRoutes)
        XCTAssertEqual(route.summary, "Transit route")
        XCTAssertEqual(route.status, .ok)
        let flow = try XCTUnwrap(route.flowID)
        XCTAssertEqual(packets.filter { $0.flowID == flow }.map(\.summary),
                       ["Transit route", "Example Tables: Request sent", "Example Tables: Request confirmed"])
        let candidatePackets = packets.filter { $0.summary.contains("Candidates") }
        XCTAssertEqual(candidatePackets.map(\.summary), ["Example Tables: Candidates requested", "Example Tables: Candidates received"])
        XCTAssertEqual(Set(candidatePackets.compactMap(\.flowID)).count, 1)
        XCTAssertNotEqual(candidatePackets.first?.flowID, flow)
        XCTAssertFalse(packets.contains { $0.summary.contains(DeliveryToolFixture.device.address) })
    }

    private func noRouteEndsConfirmUnavailable() async throws {
        let rig = makeRig(shapes: [.placeTables()], routes: PlaceStubs.routes("routes-empty-routes"))
        let (card, _) = try await tappedCard(rig, mode: .walk)
        let resolution = try await confirm(card)

        XCTAssertEqual(resolution.status, "unavailable")
        XCTAssertEqual(resolution.notice, "The request could not be made. Nothing was added.")
        XCTAssertEqual(resolution.json?["message"] as? String, AgentPartner.unavailableMessage)
        XCTAssertEqual(card.mark, .notApplied)
        XCTAssertEqual(rig.providerCalls.count, 1)
        XCTAssertTrue(rig.partner.bodies(op: "submit").isEmpty, "nothing is sent to the partner")
        XCTAssertTrue(rig.store.activities.isEmpty)
        XCTAssertTrue(rig.store.events.isEmpty)
        let packets = await rig.packets()
        let route = try XCTUnwrap(packets.first { $0.kind == .route })
        XCTAssertEqual(route.summary, "Walk route")
        XCTAssertEqual(route.status, .noRoute)
        let flow = try XCTUnwrap(route.flowID)
        XCTAssertEqual(packets.filter { $0.flowID == flow }.map(\.summary), ["Walk route"], "the route packet is alone in the flow")

        // A failed lookup (a server error) ends the same way and records the lookup as failed.
        let down = makeRig(shapes: [.placeTables()], routes: PlaceStubs.routes("routes-empty-routes", status: 500))
        let (downCard, _) = try await tappedCard(down, mode: .car)
        let downResolution = try await confirm(downCard)
        XCTAssertEqual(downResolution.status, "unavailable")
        XCTAssertTrue(down.partner.bodies(op: "submit").isEmpty)
        let downPackets = await down.packets()
        XCTAssertEqual(downPackets.first { $0.kind == .route }?.status, .failed)
    }

    private func missingValuesAreRefusedAsAnEditWithNoLookup() async throws {
        // No mode chosen.
        let noMode = makeRig(shapes: [.placeTables()])
        let (noModeCard, _) = try await tappedCard(noMode, mode: nil)
        let noModeResolution = try await confirm(noModeCard)
        XCTAssertEqual(noModeResolution.status, "rejected")
        XCTAssertEqual(noModeResolution.json?["message"] as? String, AgentPartner.editRejectedMessage)
        XCTAssertEqual(noMode.providerCalls.count, 0)
        XCTAssertTrue(noMode.partner.bodies(op: "submit").isEmpty)
        XCTAssertTrue(noMode.store.activities.isEmpty)

        // No Leave from place.
        let noFrom = makeRig(shapes: [.placeTables()])
        noFrom.position.place = nil
        let (noFromCard, _) = try await tappedCard(noFrom, mode: .car)
        let noFromResolution = try await confirm(noFromCard)
        XCTAssertEqual(noFromResolution.status, "rejected")
        XCTAssertEqual(noFrom.providerCalls.count, 0)
        XCTAssertTrue(noFrom.partner.bodies(op: "submit").isEmpty)

        // A form with no lookup field gives the entry no location: Travel on is refused.
        let plain = makeRig()
        let plainCard = try await built(plain)
        let plainFields = try model(plainCard)
        XCTAssertTrue(plainFields.chooseOption("schedule-travel", "true"))
        XCTAssertTrue(plainFields.chooseOption("schedule-mode", "walk"))
        XCTAssertTrue(plainCard.canConfirm)
        let plainResolution = try await confirm(plainCard)
        XCTAssertEqual(plainResolution.status, "rejected")
        XCTAssertEqual(plainResolution.json?["message"] as? String, AgentPartner.editRejectedMessage)
        XCTAssertEqual(plain.providerCalls.count, 0, "the provider is not called")
        XCTAssertEqual(plain.routes.callCount, 0)
        XCTAssertTrue(plain.partner.bodies(op: "submit").isEmpty)
        XCTAssertTrue(plain.store.activities.isEmpty)
        let packets = await plain.packets()
        XCTAssertFalse(packets.contains { $0.kind == .route })
    }

    // MARK: V05 Travel off

    func testV05_ConfirmWithTravelOffIsTheMergedBase() async throws {
        let branches = PartnerPlaceFixture.branches
        let rig = makeRig(shapes: [.placeTables(candidates: { _, _ in branches })])
        let (card, fields) = try await tappedCard(rig, mode: nil, travelOn: false)
        XCTAssertEqual(fields.values.flag("schedule-travel"), false)
        let resolution = try await confirm(card)

        XCTAssertEqual(resolution.status, "applied")
        XCTAssertNil(resolution.notice)
        XCTAssertEqual(Set(try XCTUnwrap(resolution.json).keys), ["status", "partner", "simulated", "results", "message", "id", "title", "start", "end"])
        XCTAssertEqual(resolution.json?["message"] as? String, AgentPartner.appliedMessage)
        let entry = try XCTUnwrap(rig.store.activities.first)
        XCTAssertEqual(entry.location, branches[1], "t98's location is kept")
        XCTAssertTrue(rig.store.events.isEmpty, "no leg")
        XCTAssertEqual(rig.providerCalls.count, 0, "the provider is not called")
        XCTAssertEqual(rig.routes.callCount, 0)
        let packets = await rig.packets()
        XCTAssertFalse(packets.contains { $0.kind == .route }, "no googleRoutes packet")
        XCTAssertEqual(packets.filter { $0.summary.hasPrefix("Example Tables: Request") }.map(\.summary),
                       ["Example Tables: Request sent", "Example Tables: Request confirmed"])
        let values = try XCTUnwrap(rig.partner.bodies(op: "submit").first?["values"] as? [String: Any])
        XCTAssertEqual(Set(values.keys), ["restaurant", "party_size", "start", "name"])

        // A form with no lookup field: no location, no leg, no lookup.
        let plain = makeRig()
        let plainCard = try await built(plain)
        let plainResolution = try await confirm(plainCard)
        XCTAssertEqual(plainResolution.status, "applied")
        XCTAssertNil(plain.store.activities.first?.location)
        XCTAssertTrue(plain.store.events.isEmpty)
        XCTAssertEqual(plain.providerCalls.count, 0)
        XCTAssertEqual(plain.routes.callCount, 0)

        // The schedule switch off with Travel on: the rows are not read and nothing is looked up.
        let skipped = makeRig(shapes: [.placeTables()])
        let (skippedCard, skippedFields) = try await tappedCard(skipped, mode: nil)
        XCTAssertTrue(skippedFields.chooseOption("add-to-schedule", "false"))
        let skippedResolution = try await confirm(skippedCard)
        XCTAssertEqual(skippedResolution.status, "applied")
        XCTAssertTrue(skipped.store.activities.isEmpty)
        XCTAssertEqual(skipped.providerCalls.count, 0)
        XCTAssertEqual(skipped.routes.callCount, 0)
    }

    // MARK: V06 ended cards, partners without a time result

    func testV06_ACardThatEndedWithoutConfirmationDropsTheTravelRowsAndATimelessPartnerHasNone() async throws {
        for how in [AgentCardResolution.cancel, .dismiss] {
            let rig = makeRig()
            let card = try await built(rig)
            let fields = try model(card)
            XCTAssertTrue(fields.chooseOption("schedule-travel", "true"))
            XCTAssertTrue(card.lines.contains("Leave from: \(DeliveryToolFixture.device.address)"), "premise: \(how)")
            _ = await card.resolve(how)
            XCTAssertEqual(card.mark, .cancelled)
            XCTAssertEqual(fields.card.fields.map(\.key), ["restaurant", "party_size", "start", "name", "note", "0"], "\(how)")
            let text = card.lines.joined(separator: "\n")
            for word in ["Travel", "Leave from", "Add to schedule", "Length (min)"] {
                XCTAssertFalse(text.contains(word), "\(how): \(word)")
            }
            XCTAssertFalse(card.showsGoogleMark, "the row is gone, so is the mark: \(how)")
        }

        let trips = makeRig(shapes: [.trips()])
        let tripsCard = try await built(trips, .init(restaurant: nil, party: nil, start: nil, name: nil), partner: "trips")
        let keys = try model(tripsCard).card.fields.map(\.key)
        XCTAssertEqual(keys, ["out", "back", "0"])
        XCTAssertFalse(keys.contains { $0.hasPrefix("schedule") })
    }

    // MARK: V07 the words

    func testV07_TheTravelRowsNameNoPartnerFieldOrKindAndNoPartnerFieldCanCollideWithThem() async throws {
        let keys = [AgentPartner.cardTravelKey, AgentPartner.cardFromKey, AgentPartner.cardModeKey]
        XCTAssertEqual(keys, ["schedule-travel", "schedule-from", "schedule-mode"])
        let labels = [AgentPartner.cardTravelLabel, AgentPartner.cardFromLabel, AgentPartner.cardModeLabel]
        XCTAssertEqual(labels, ["Travel", "Leave from", "Travel mode"])
        let chips = TransportMode.allCases.map(\.title)
        let partnerKeys = ["restaurant", "party_size", "start", "name", "note", "from", "pickup", "dropoff", "where", "speed", "signed",
                           "count", "memo", "out", "back"]
        let partnerKinds = ["text", "place", "time", "pick_one", "on_off", "number", "money"]
        let forbidden = ["should", "recommend", "advise", "afford", "save", "invest", "cut back", "stop spending", "overspend", "menu",
                         "dish", "calorie", "nutrition", "healthy"]
        for word in keys + labels + chips {
            let lowered = word.lowercased()
            XCTAssertFalse(lowered.contains("example"), word)
            XCTAssertFalse(lowered.contains("table"), word)
            XCTAssertFalse(lowered.contains("restaurant"), word)
            XCTAssertTrue(word.unicodeScalars.allSatisfy { $0.isASCII }, word)
            for other in partnerKeys + partnerKinds { XCTAssertNotEqual(lowered, other, word) }
            for bad in forbidden { XCTAssertFalse(lowered.contains(bad), "\(word): \(bad)") }
        }
        for key in keys {
            XCTAssertTrue(key.contains("-"), key)
            XCTAssertFalse(partnerKeys.contains(key), key)
        }
        // The hyphen is what keeps a partner's key apart: a form that names one of these keys is not a form.
        for key in keys {
            var shape = StubPartner.Shape.tables()
            shape.fields[0] = StubPartner.field(key, "text", "Restaurant")
            let rig = makeRig(shapes: [shape])
            let outcome = rig.call("get_partners")
            guard case .lookup(let lookup) = outcome else { return XCTFail("expected a lookup") }
            let result = TestClock.object(await lookup.run().result)
            XCTAssertEqual(result?["status"] as? String, "unavailable", "a partner key with a hyphen is refused: \(key)")
        }
    }
}
