import XCTest
import CoreLocation
@testable import besir

/// SPEC-ROUTELINE-001: the line spec, the redraw decision and the camera frame (AC-ROUTELINE-006 and 007).
/// Pure values only: no map, no key, no network.
final class RouteLineMapTests: XCTestCase {
    private func point(_ latitude: Double, _ longitude: Double) -> RoutePoint {
        RoutePoint(latitude: latitude, longitude: longitude)
    }

    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func spec(_ points: [RoutePoint], file: StaticString = #filePath, line: UInt = #line) throws -> RouteLineSpec {
        try XCTUnwrap(RouteLineSpec.make(points), file: file, line: line)
    }

    private let origin = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
    private let destination = CLLocationCoordinate2D(latitude: 37.7694, longitude: -122.4862)

    /// Leaves the box of the two pins to the north and to the south.
    private let bulging = [RoutePoint(latitude: 37.7955, longitude: -122.3937), RoutePoint(latitude: 37.8100, longitude: -122.4500),
                           RoutePoint(latitude: 37.7500, longitude: -122.4000), RoutePoint(latitude: 37.7694, longitude: -122.4862)]

    /// Stays inside the box of the two pins.
    private let contained = [RoutePoint(latitude: 37.7900, longitude: -122.4000), RoutePoint(latitude: 37.7850, longitude: -122.4300),
                             RoutePoint(latitude: 37.7800, longitude: -122.4600), RoutePoint(latitude: 37.7700, longitude: -122.4800)]

    private let fivePoints = [RoutePoint(latitude: 37.7955, longitude: -122.3937), RoutePoint(latitude: 37.7900, longitude: -122.4100),
                              RoutePoint(latitude: 37.7800, longitude: -122.4300), RoutePoint(latitude: 37.7750, longitude: -122.4600),
                              RoutePoint(latitude: 37.7694, longitude: -122.4862)]

    private let baseBounds = MapFraming.bounds(south: 37.7694, west: -122.4862, north: 37.7955, east: -122.3937)

    // MARK: - AC-ROUTELINE-006 spec

    func testLINE_SpecNilForFewerThanTwoPoints() throws {
        XCTAssertNil(RouteLineSpec.make([]))
        XCTAssertNil(RouteLineSpec.make([point(37.7955, -122.3937)]))
        let two = [point(37.7955, -122.3937), point(37.7694, -122.4862)]
        XCTAssertEqual(try spec(two).points, two)
    }

    func testLINE_SpecNilWhenAnyPointInvalid() {
        let path = [point(37.7955, -122.3937), point(95, -122.4000), point(37.7694, -122.4862)]
        XCTAssertNil(RouteLineSpec.make(path))
        XCTAssertNotNil(RouteLineSpec.make([path[0], path[2]]))
    }

    func testLINE_SpecEqualForEqualPoints() throws {
        let list = fivePoints
        XCTAssertEqual(list.count, 5)
        let made = try spec(list)
        XCTAssertEqual(made.points.count, 5)
        XCTAssertEqual(made.points, list)
        XCTAssertEqual(made, try spec(list))
        var moved = list
        moved[2] = point(37.7800, -122.4301)
        XCTAssertNotEqual(made, try spec(moved))
        XCTAssertNotEqual(made, try spec(Array(list.reversed())))
        XCTAssertNotEqual(made, try spec(Array(list.dropLast())))
        XCTAssertNotEqual(made, try spec(Array(list.dropFirst())))
    }

    func testLINE_NoRedrawWhenNothingChanged() throws {
        let made = try spec(fivePoints)
        XCTAssertFalse(RouteLineSpec.needsRedraw(last: made, next: try spec(fivePoints), colourSchemeChanged: false))
    }

    func testLINE_RedrawWhenPointsChange() throws {
        let made = try spec(fivePoints)
        let other = try spec(bulging)
        XCTAssertTrue(RouteLineSpec.needsRedraw(last: made, next: other, colourSchemeChanged: false))
        XCTAssertTrue(RouteLineSpec.needsRedraw(last: nil, next: made, colourSchemeChanged: false))
    }

    func testLINE_RedrawWhenColourSchemeChanges() throws {
        let made = try spec(fivePoints)
        XCTAssertTrue(RouteLineSpec.needsRedraw(last: made, next: try spec(fivePoints), colourSchemeChanged: true))
    }

    func testLINE_RedrawToRemoveWhenLineGone() throws {
        let made = try spec(fivePoints)
        XCTAssertTrue(RouteLineSpec.needsRedraw(last: made, next: nil, colourSchemeChanged: false))
    }

    func testLINE_NoRedrawWhenBothAbsent() {
        XCTAssertFalse(RouteLineSpec.needsRedraw(last: nil, next: nil, colourSchemeChanged: true))
        XCTAssertFalse(RouteLineSpec.needsRedraw(last: nil, next: nil, colourSchemeChanged: false))
    }

    // MARK: - AC-ROUTELINE-007 framing

    func testLINE_FramingEmptyPathEqualsToday() {
        let sameSpot = coordinate(37.7749, -122.4194)
        let invalid = coordinate(95, -122.3937)
        let cases: [(name: String, origin: CLLocationCoordinate2D?, destination: CLLocationCoordinate2D?, expected: MapFraming)] = [
            ("two distinct points", origin, destination, baseBounds),
            ("two equal points", sameSpot, sameSpot, .point(latitude: 37.7749, longitude: -122.4194, zoom: 15)),
            ("origin only", origin, nil, .point(latitude: 37.7955, longitude: -122.3937, zoom: 15)),
            ("destination only", nil, destination, .point(latitude: 37.7694, longitude: -122.4862, zoom: 15)),
            ("neither", nil, nil, .point(latitude: 37.7749, longitude: -122.4194, zoom: 12)),
            ("invalid origin", invalid, destination, .point(latitude: 37.7694, longitude: -122.4862, zoom: 15))
        ]
        for item in cases {
            let withEmpty = MapFraming.plan(origin: item.origin, destination: item.destination, path: [])
            let without = MapFraming.plan(origin: item.origin, destination: item.destination)
            XCTAssertEqual(withEmpty, without, item.name)
            XCTAssertEqual(withEmpty, item.expected, item.name)
        }
    }

    func testLINE_FramingContainsBulgingPath() {
        let plan = MapFraming.plan(origin: origin, destination: destination, path: bulging)
        XCTAssertEqual(plan, .bounds(south: 37.75, west: -122.4862, north: 37.81, east: -122.3937))
        XCTAssertNotEqual(plan, MapFraming.plan(origin: origin, destination: destination))
    }

    func testLINE_FramingContainsEveryPointForManyRoutes() {
        var state: UInt64 = 20_261_029
        func next(_ low: Double, _ high: Double) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return low + Double(state >> 11) / Double(1 << 53) * (high - low)
        }
        var violations = 0
        for route in 0..<50 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let count = 2 + Int((state >> 33) % 39)
            let path = (0..<count).map { _ in point(next(-90, 90), next(-180, 180)) }
            let from = coordinate(next(-90, 90), next(-180, 180))
            let to = coordinate(next(-90, 90), next(-180, 180))
            let plan = MapFraming.plan(origin: from, destination: to, path: path)
            let everyone = path + [point(from.latitude, from.longitude), point(to.latitude, to.longitude)]
            var outside = 0
            switch plan {
            case let .bounds(south, west, north, east):
                outside = everyone.filter { !($0.latitude >= south && $0.latitude <= north
                                              && $0.longitude >= west && $0.longitude <= east) }.count
            case let .point(latitude, longitude, _):
                outside = everyone.filter { $0.latitude != latitude || $0.longitude != longitude }.count
            }
            violations += outside
        }
        XCTAssertEqual(violations, 0, "points outside the plan over 50 routes")

        let inside = MapFraming.plan(origin: origin, destination: destination, path: contained)
        XCTAssertEqual(inside, baseBounds)
        XCTAssertEqual(inside, MapFraming.plan(origin: origin, destination: destination))
    }

    func testLINE_FramingIgnoresPathWithInvalidPoint() {
        let path = bulging + [point(95, -122.4000)]
        XCTAssertEqual(MapFraming.plan(origin: origin, destination: destination, path: path), baseBounds)
        XCTAssertEqual(MapFraming.plan(origin: origin, destination: destination, path: path),
                       MapFraming.plan(origin: origin, destination: destination))
    }

    func testLINE_FramingPathWithoutOrigin() {
        let plan = MapFraming.plan(origin: nil, destination: destination, path: bulging)
        XCTAssertEqual(plan, .bounds(south: 37.75, west: -122.4862, north: 37.81, east: -122.3937))
    }

    func testLINE_FramingDegenerateIsPoint() {
        let spot = coordinate(37.7749, -122.4194)
        let path = [point(37.7749, -122.4194), point(37.7749, -122.4194)]
        let plan = MapFraming.plan(origin: spot, destination: spot, path: path)
        XCTAssertEqual(plan, .point(latitude: 37.7749, longitude: -122.4194, zoom: 15))
    }
}
