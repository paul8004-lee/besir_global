import XCTest
import CoreLocation
@testable import besir

/// Card t13: the decisions behind the Google map. No key and no network are needed;
/// the SDK call is replaced by a counting closure.
final class GoogleMapsSetupTests: XCTestCase {

    private final class Calls {
        private let lock = NSLock()
        private var keys: [String] = []
        func add(_ key: String) { lock.lock(); keys.append(key); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return keys }
    }

    private func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func setup(_ info: [String: Any]?, _ calls: Calls) -> GoogleMapsSetup {
        GoogleMapsSetup(info: info) { calls.add($0) }
    }

    // MARK: - key reading and the start-once rule

    func testGMAPS_KeyIsTrimmedFromInfo() {
        XCTAssertEqual(GoogleMapsSetup.key(from: ["BesirMapsKey": "  AIzaTEST  \n"]), "AIzaTEST")
    }

    func testGMAPS_KeyAbsentWhenBlankSpacesMissingNonTextOrUnexpanded() {
        XCTAssertNil(GoogleMapsSetup.key(from: [:]))
        XCTAssertNil(GoogleMapsSetup.key(from: ["BesirMapsKey": ""]))
        XCTAssertNil(GoogleMapsSetup.key(from: ["BesirMapsKey": "  \n"]))
        XCTAssertNil(GoogleMapsSetup.key(from: ["BesirMapsKey": 5]))
        XCTAssertNil(GoogleMapsSetup.key(from: ["BesirMapsKey": ["a"]]))
        XCTAssertNil(GoogleMapsSetup.key(from: ["BesirMapsKey": "$(BESIR_MAPS_IOS_KEY)"]))
        XCTAssertNil(GoogleMapsSetup.key(from: nil))
    }

    func testGMAPS_StartGivesTrimmedKeyToProviderOnce() {
        let calls = Calls()
        let s = setup(["BesirMapsKey": "  AIzaTEST \n"], calls)
        XCTAssertEqual(s.start(), .ready)
        XCTAssertEqual(s.start(), .ready)
        XCTAssertEqual(calls.all, ["AIzaTEST"])
    }

    func testGMAPS_StartWithoutKeyNeverCallsProvider() {
        let calls = Calls()
        let s = setup(["BesirMapsKey": "   "], calls)
        XCTAssertFalse(s.isConfigured)
        XCTAssertEqual(s.start(), .unavailable)
        XCTAssertEqual(s.start(), .unavailable)
        XCTAssertEqual(s.start(), .unavailable)
        XCTAssertEqual(calls.all.count, 0)
    }

    func testGMAPS_StartIsSafeFromManyThreads() {
        let calls = Calls()
        let s = setup(["BesirMapsKey": "AIzaTEST"], calls)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in _ = s.start() }
        XCTAssertEqual(calls.all.count, 1)
    }

    // MARK: - framing

    func testGMAPS_FramingBoundsForTwoDistinctPoints() {
        let plan = MapFraming.plan(origin: coord(37.7955, -122.3937), destination: coord(37.7694, -122.4862))
        XCTAssertEqual(plan, .bounds(south: 37.7694, west: -122.4862, north: 37.7955, east: -122.3937))
    }

    func testGMAPS_FramingBoundsAcrossNegativeLongitudes() {
        let plan = MapFraming.plan(origin: coord(40.7128, -74.0060), destination: coord(37.7749, -122.4194))
        XCTAssertEqual(plan, .bounds(south: 37.7749, west: -122.4194, north: 40.7128, east: -74.0060))
    }

    func testGMAPS_FramingPointWhenSamePoint() {
        let plan = MapFraming.plan(origin: coord(37.7749, -122.4194), destination: coord(37.7749, -122.4194))
        XCTAssertEqual(plan, .point(latitude: 37.7749, longitude: -122.4194, zoom: 15))
    }

    func testGMAPS_FramingPointForDestinationOnly() {
        let plan = MapFraming.plan(origin: nil, destination: coord(37.7694, -122.4862))
        XCTAssertEqual(plan, .point(latitude: 37.7694, longitude: -122.4862, zoom: 15))
    }

    func testGMAPS_FramingPointForOriginOnly() {
        let plan = MapFraming.plan(origin: coord(37.7955, -122.3937), destination: nil)
        XCTAssertEqual(plan, .point(latitude: 37.7955, longitude: -122.3937, zoom: 15))
    }

    func testGMAPS_FramingDefaultsToSanFranciscoWhenNothingValid() {
        let plan = MapFraming.plan(origin: nil, destination: nil)
        XCTAssertEqual(plan, .point(latitude: 37.7749, longitude: -122.4194, zoom: 12))
    }

    func testGMAPS_InvalidCoordinatesAreAbsent() {
        XCTAssertFalse(MapFraming.isValid(coord(.nan, 0)))
        XCTAssertFalse(MapFraming.isValid(coord(0, .infinity)))
        XCTAssertFalse(MapFraming.isValid(coord(91, 0)))
        XCTAssertFalse(MapFraming.isValid(coord(-91, 0)))
        XCTAssertFalse(MapFraming.isValid(coord(0, 181)))
        XCTAssertFalse(MapFraming.isValid(coord(0, -181)))
        XCTAssertTrue(MapFraming.isValid(coord(0, 0)))
        XCTAssertTrue(MapFraming.isValid(coord(90, 180)))
    }

    func testGMAPS_FramingIgnoresInvalidOriginKeepsDestinationPoint() {
        let plan = MapFraming.plan(origin: coord(91, 0), destination: coord(37.7694, -122.4862))
        XCTAssertEqual(plan, .point(latitude: 37.7694, longitude: -122.4862, zoom: 15))
    }

    // MARK: - markers

    func testGMAPS_MarkersOriginThenDestinationWithTitles() {
        let markers = MapMarkerSpec.markers(origin: coord(37.7955, -122.3937),
                                            destination: coord(37.7694, -122.4862),
                                            destinationName: "Tartine Bakery")
        XCTAssertEqual(markers, [
            MapMarkerSpec(role: .origin, latitude: 37.7955, longitude: -122.3937, title: "Origin"),
            MapMarkerSpec(role: .destination, latitude: 37.7694, longitude: -122.4862, title: "Tartine Bakery"),
        ])
    }

    func testGMAPS_MarkerOmittedWhenCoordinateInvalid() {
        let markers = MapMarkerSpec.markers(origin: coord(.nan, 0),
                                            destination: coord(37.7694, -122.4862),
                                            destinationName: "Tartine Bakery")
        XCTAssertEqual(markers.map(\.role), [.destination])
    }

    func testGMAPS_BlankDestinationNameFallsBackToDestination() {
        let markers = MapMarkerSpec.markers(origin: nil, destination: coord(37.7694, -122.4862), destinationName: "   ")
        XCTAssertEqual(markers.map(\.title), ["Destination"])
    }

    // MARK: - the map follows its inputs

    func testGMAPS_MarkerListChangesWhenOriginArrivesLater() {
        let d = coord(37.7694, -122.4862)
        let before = MapMarkerSpec.markers(origin: nil, destination: d, destinationName: "Park")
        let after = MapMarkerSpec.markers(origin: coord(37.7955, -122.3937), destination: d, destinationName: "Park")
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(after.count, 2)
        XCTAssertNotEqual(before, after)
    }

    func testGMAPS_FramingChangesWhenOriginArrivesLater() {
        let d = coord(37.7694, -122.4862)
        let before = MapFraming.plan(origin: nil, destination: d)
        let after = MapFraming.plan(origin: coord(37.7955, -122.3937), destination: d)
        guard case .point = before else { return XCTFail("expected a point, got \(before)") }
        guard case .bounds = after else { return XCTFail("expected bounds, got \(after)") }
    }

    func testGMAPS_FramingUnchangedWhenOnlyNameChanges() {
        let o = coord(37.7955, -122.3937)
        let d = coord(37.7694, -122.4862)
        XCTAssertNotEqual(MapMarkerSpec.markers(origin: o, destination: d, destinationName: "A"),
                          MapMarkerSpec.markers(origin: o, destination: d, destinationName: "B"))
        XCTAssertEqual(MapFraming.plan(origin: o, destination: d), MapFraming.plan(origin: o, destination: d))
    }

    // MARK: - fit insets that keep the name label inside the map

    func testGMAPS_FitInsetsShortNameKeepBaseSidesAndClearTheLabelAbove() {
        let insets = MapFitInsets.make(labelWidth: 60, mapWidth: 353, mapHeight: 280)
        XCTAssertEqual(insets.left, 48)
        XCTAssertEqual(insets.right, 48)
        XCTAssertEqual(insets.bottom, 48)
        XCTAssertGreaterThanOrEqual(insets.top, MapFitInsets.labelClearanceAbove)
    }

    func testGMAPS_FitInsetsSidesCoverHalfTheLabelWidthPlusMargin() {
        let insets = MapFitInsets.make(labelWidth: 148, mapWidth: 353, mapHeight: 280)
        XCTAssertGreaterThanOrEqual(insets.left, 148 / 2 + MapFitInsets.labelSideMargin)
        XCTAssertEqual(insets.left, insets.right)
    }

    func testGMAPS_FitInsetsSidesGrowWithALongerName() {
        let short = MapFitInsets.make(labelWidth: 120, mapWidth: 353, mapHeight: 280)
        let long = MapFitInsets.make(labelWidth: 180, mapWidth: 353, mapHeight: 280)
        XCTAssertGreaterThan(long.left, short.left)
    }

    func testGMAPS_FitInsetsSidesAreCappedSoAFitAreaRemains() {
        let insets = MapFitInsets.make(labelWidth: 900, mapWidth: 353, mapHeight: 280)
        XCTAssertLessThanOrEqual(insets.left + insets.right, 353 * MapFitInsets.maxShare + 0.001)
        XCTAssertGreaterThan(insets.left, 48)
    }

    func testGMAPS_FitInsetsOnATinyMapNeverTakeMoreThanTheShareAllowed() {
        let insets = MapFitInsets.make(labelWidth: 148, mapWidth: 100, mapHeight: 100)
        XCTAssertLessThanOrEqual(insets.left + insets.right, 100 * MapFitInsets.maxShare + 0.001)
        XCTAssertLessThanOrEqual(insets.top + insets.bottom, 100 * MapFitInsets.maxShare + 0.001)
        XCTAssertGreaterThan(insets.top, 0)
        XCTAssertGreaterThan(insets.bottom, 0)
    }

    func testGMAPS_FitInsetsZeroSizedMapGivesTheBaseOnAllSides() {
        let base = MapFitInsets(top: 48, left: 48, bottom: 48, right: 48)
        XCTAssertEqual(MapFitInsets.make(labelWidth: 148, mapWidth: 0, mapHeight: 280), base)
        XCTAssertEqual(MapFitInsets.make(labelWidth: 148, mapWidth: 353, mapHeight: 0), base)
    }

    // MARK: - putting the name label back after a change of appearance

    func testGMAPS_ReassertWindowIsActiveInsideAndOverAfterTheWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        let until = LabelReassert.until(from: start)
        XCTAssertTrue(LabelReassert.isActive(now: start, until: until))
        XCTAssertTrue(LabelReassert.isActive(now: start.addingTimeInterval(LabelReassert.window - 0.1), until: until))
        XCTAssertFalse(LabelReassert.isActive(now: start.addingTimeInterval(LabelReassert.window), until: until))
    }

    func testGMAPS_ReassertIsInactiveBeforeAnyAppearanceChange() {
        XCTAssertFalse(LabelReassert.isActive(now: Date(), until: .distantPast))
    }

    func testGMAPS_ReassertTimersAreIncreasingAndEndInsideTheWindow() {
        let delays = LabelReassert.delays
        XCTAssertFalse(delays.isEmpty)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertGreaterThan(delays.first ?? 0, 0)
        XCTAssertLessThan(delays.last ?? .infinity, LabelReassert.window)
    }
}
