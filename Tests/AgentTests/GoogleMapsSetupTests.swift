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
}
