import XCTest
import CoreLocation
@testable import besir

/// The test-side encoder of Google's published polyline algorithm, written independently of the app decoder.
/// Every polyline text in the fixtures and in these tests comes from it (or from Google's documented example).
enum RouteLineTestEncoder {
    typealias Units = (latitude: Int, longitude: Int)

    /// One signed number: shift left by one (invert when negative), then 5-bit groups, lowest group first,
    /// every group but the last gets 0x20, and every group gets 63 added.
    static func number(_ value: Int) -> String {
        var rest = value < 0 ? ~(value << 1) : value << 1
        var out = ""
        while rest >= 0x20 {
            out.append(Character(UnicodeScalar(UInt8((0x20 | (rest & 0x1f)) + 63))))
            rest >>= 5
        }
        out.append(Character(UnicodeScalar(UInt8(rest + 63))))
        return out
    }

    /// Points in units of 1e-5 degree; each pair is written as the step from the point before it.
    static func encode(_ points: [Units]) -> String {
        var previous: Units = (0, 0)
        var out = ""
        for point in points {
            out += number(point.latitude - previous.latitude) + number(point.longitude - previous.longitude)
            previous = point
        }
        return out
    }

    /// Deterministic walk near San Francisco: steps of up to 500 units either way, every 7th point repeats the one
    /// before it (a zero step), so negative, positive and zero steps all occur.
    static func syntheticUnits(count: Int) -> [Units] {
        var state: UInt64 = 20_261_029
        var latitude = 3_770_000
        var longitude = -12_240_000
        var points: [Units] = []
        for index in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let latitudeStep = Int((state >> 33) % 1001) - 500
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let longitudeStep = Int((state >> 33) % 1001) - 500
            if index % 7 != 6 {
                latitude += latitudeStep
                longitude += longitudeStep
            }
            points.append((latitude, longitude))
        }
        return points
    }
}

/// SPEC-ROUTELINE-001: the polyline decoder (AC-ROUTELINE-001), the line request and the parser (AC-ROUTELINE-002),
/// and the requests that must stay byte-identical (AC-ROUTELINE-003). No key, no network.
final class RouteLineRoutesTests: XCTestCase {
    private typealias Support = RoutesTestSupport
    private typealias Encoder = RouteLineTestEncoder

    /// Google's documented example: (38.5, -120.2), (40.7, -120.95), (43.252, -126.453).
    private let example = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
    private let exampleUnits: [Encoder.Units] = [(3_850_000, -12_020_000), (4_070_000, -12_095_000), (4_325_200, -12_645_300)]
    private let lineMask = "routes.duration,routes.polyline.encodedPolyline"

    /// The invented points of routes-line-drive.json and the text the test-side encoder makes from them.
    private let driveUnits: [Encoder.Units] = [
        (3_779_550, -12_239_370), (3_778_600, -12_241_800), (3_776_500, -12_243_500), (3_775_200, -12_246_800),
        (3_772_100, -12_248_000), (3_770_200, -12_247_100), (3_769_400, -12_248_620)
    ]
    private let driveText = "{|teFr_`jVjz@zvCfbCfiBfpAfmEv`E~iAvuBgw@~p@~}A"

    private let travelModes: [(mode: TransportMode, google: String)] = [
        (.car, "DRIVE"), (.transit, "TRANSIT"), (.walk, "WALK"), (.bicycle, "BICYCLE")
    ]

    // MARK: - Helpers

    private func decode(_ text: String) -> [RoutePoint]? {
        GoogleRoutes.decodePolyline(text)
    }

    private func assertPoints(_ actual: [RoutePoint]?, _ expected: [Encoder.Units], _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("no points \(message)", file: file, line: line) }
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (point, units) in zip(actual, expected) {
            XCTAssertEqual(point.latitude, Double(units.latitude) / 100_000, accuracy: 1e-9, message, file: file, line: line)
            XCTAssertEqual(point.longitude, Double(units.longitude) / 100_000, accuracy: 1e-9, message, file: file, line: line)
        }
    }

    /// The text with the character at `index` replaced.
    private func replacing(_ text: String, at index: Int, with replacement: Character) -> String {
        var characters = Array(text)
        characters[index] = replacement
        return String(characters)
    }

    /// The Google example whose first latitude number is written with exactly `groups` groups: the original last group
    /// continues, the groups added after it carry no payload, and the last group is `?` (payload 0).
    private func exampleWithFirstLatitudeGroups(_ groups: Int) -> String {
        "_p~if" + String(repeating: "_", count: groups - 6) + "?" + example.dropFirst(5)
    }

    private func lineRequest(_ mode: TransportMode, mask: String? = nil, live: Bool = false) throws -> URLRequest {
        try XCTUnwrap(GoogleRoutes.request(mode: mode, from: Support.origin, to: Support.dest,
                                           mask: mask ?? lineMask, config: Support.config, live: live, polyline: true))
    }

    private func plainRequest(_ mode: TransportMode) throws -> URLRequest {
        try XCTUnwrap(GoogleRoutes.request(mode: mode, from: Support.origin, to: Support.dest,
                                           mask: GoogleRoutes.mask(for: mode), config: Support.config))
    }

    private func keys(of body: NSDictionary) -> Set<String> {
        Set(body.allKeys.compactMap { $0 as? String })
    }

    // MARK: - AC-ROUTELINE-001 decoder

    func testLINE_DecodesGoogleExample() {
        assertPoints(decode(example), exampleUnits)
        XCTAssertEqual(Encoder.encode(exampleUnits), example)
        let points = decode(example)
        XCTAssertEqual(points?.first, RoutePoint(latitude: 38.5, longitude: -120.2))
        XCTAssertEqual(points?.count, 3)
    }

    func testLINE_DecoderRoundTripsSyntheticRoute() {
        let units = Encoder.syntheticUnits(count: 200)
        XCTAssertEqual(units.count, 200)
        XCTAssertTrue(zip(units, units.dropFirst()).contains { $0 == $1 }, "a zero step occurs")
        assertPoints(decode(Encoder.encode(units)), units)
    }

    func testLINE_DecoderRejectsTruncatedMidNumber() {
        XCTAssertNil(decode(String(example.dropLast())))
    }

    func testLINE_DecoderRejectsMissingLongitude() {
        XCTAssertNil(decode(String(example.dropLast(5))))
    }

    func testLINE_DecoderRejectsCharactersBelowAlphabet() {
        XCTAssertNil(decode(replacing(example, at: 4, with: " ")))
        XCTAssertNil(decode(replacing(example, at: 9, with: ">")))
    }

    func testLINE_DecoderRejectsCharactersAboveAlphabet() {
        XCTAssertNil(decode(replacing(example, at: 5, with: "\u{7F}")))
        XCTAssertNil(decode(replacing(example, at: 14, with: "é")))
    }

    func testLINE_DecoderLatitudeBoundary() {
        assertPoints(decode(Encoder.encode([(9_000_000, 0), (8_999_990, 10)])), [(9_000_000, 0), (8_999_990, 10)], "90.0")
        assertPoints(decode(Encoder.encode([(-9_000_000, 0), (-8_999_990, 10)])), [(-9_000_000, 0), (-8_999_990, 10)], "-90.0")
        XCTAssertNil(decode(Encoder.encode([(9_000_001, 0), (8_999_991, 10)])), "90.00001")
        XCTAssertNil(decode(Encoder.encode([(-9_000_001, 0), (-8_999_991, 10)])), "-90.00001")
    }

    func testLINE_DecoderLongitudeBoundary() {
        assertPoints(decode(Encoder.encode([(0, 18_000_000), (10, 17_999_990)])), [(0, 18_000_000), (10, 17_999_990)], "180")
        assertPoints(decode(Encoder.encode([(0, -18_000_000), (10, -17_999_990)])), [(0, -18_000_000), (10, -17_999_990)], "-180")
        XCTAssertNil(decode(Encoder.encode([(0, 18_000_001), (10, 17_999_991)])), "180.00001")
        XCTAssertNil(decode(Encoder.encode([(0, -18_000_001), (10, -17_999_991)])), "-180.00001")
    }

    func testLINE_DecoderRejectsFewerThanTwoPoints() {
        XCTAssertNil(decode(""))
        XCTAssertNil(decode("_p~iF~ps|U"))
    }

    func testLINE_DecoderLimitsAndHostileInput() {
        XCTAssertEqual(GoogleRoutes.maxLinePoints, 5_000)
        // (1) the point cap
        XCTAssertEqual(decode(Encoder.encode(Encoder.syntheticUnits(count: 5_000)))?.count, 5_000)
        XCTAssertNil(decode(Encoder.encode(Encoder.syntheticUnits(count: 5_001))))
        // (2) the group cap: 13 groups decode, 14 do not
        assertPoints(decode(exampleWithFirstLatitudeGroups(13)), exampleUnits, "13 groups")
        XCTAssertNil(decode(exampleWithFirstLatitudeGroups(14)), "14 groups")
        // (3) a 13th group with payload 16 would lose its top bit in 64 bits
        XCTAssertNil(decode("_p~if_______O" + example.dropFirst(5)))
        // (4) no trap: the step +(2^63 - 1) overflows a 64-bit add, the step -2^63 is stopped by the range check
        let firstPoint = String(example.prefix(10))
        XCTAssertNil(decode(firstPoint + "}" + String(repeating: "~", count: 11) + "N" + "?"), "+(2^63 - 1)")
        XCTAssertNil(decode(firstPoint + String(repeating: "~", count: 12) + "N" + "?"), "-2^63")
        XCTAssertNil(decode(String(repeating: "~", count: 20)))
        XCTAssertNil(decode(String(repeating: "~", count: 5_000)))
    }

    // MARK: - AC-ROUTELINE-002 parser

    func testLINE_ParsePicksUpPolyline() throws {
        XCTAssertEqual(Encoder.encode(driveUnits), driveText)
        let route = try GoogleRoutes.parse(try Support.fixture("routes-line-drive"))
        XCTAssertEqual(route.duration, 600)
        XCTAssertEqual(route.encodedPolyline, driveText)
        assertPoints(route.encodedPolyline.flatMap(decode), driveUnits)
    }

    func testLINE_ParseWithoutPolylineIsNotMalformed() throws {
        let route = try GoogleRoutes.parse(try Support.fixture("routes-line-no-polyline"))
        XCTAssertEqual(route.duration, 600)
        XCTAssertNil(route.encodedPolyline)
    }

    func testLINE_ParseEmptyOrNonTextPolylineIsNil() throws {
        let variants: [(name: String, route: [String: Any])] = [
            ("empty text", ["duration": "600s", "polyline": ["encodedPolyline": ""]]),
            ("number", ["duration": "600s", "polyline": 5]),
            ("null", ["duration": "600s", "polyline": NSNull()]),
            ("object without text", ["duration": "600s", "polyline": ["other": "x"]]),
            ("number as text", ["duration": "600s", "polyline": ["encodedPolyline": 5]])
        ]
        for variant in variants {
            let route = try GoogleRoutes.parse(Support.json(["routes": [variant.route]]))
            XCTAssertEqual(route.duration, 600, variant.name)
            XCTAssertNil(route.encodedPolyline, variant.name)
        }
    }

    // MARK: - AC-ROUTELINE-002 request

    func testLINE_RequestBodyAddsOnlyTwoPolylineKeys() throws {
        for (mode, _) in travelModes {
            let plain = try XCTUnwrap(Support.body(of: try plainRequest(mode)), "\(mode)")
            let line = try XCTUnwrap(Support.body(of: try lineRequest(mode)), "\(mode)")
            XCTAssertEqual(keys(of: line).subtracting(keys(of: plain)), ["polylineEncoding", "polylineQuality"], "\(mode)")
            XCTAssertTrue(keys(of: plain).isSubset(of: keys(of: line)), "\(mode)")
            XCTAssertEqual(line["polylineEncoding"] as? String, "ENCODED_POLYLINE", "\(mode)")
            XCTAssertEqual(line["polylineQuality"] as? String, "OVERVIEW", "\(mode)")
            let expected = NSMutableDictionary(dictionary: plain)
            expected["polylineEncoding"] = "ENCODED_POLYLINE"
            expected["polylineQuality"] = "OVERVIEW"
            XCTAssertTrue(line.isEqual(expected), "\(mode)")
        }
    }

    func testLINE_RequestMaskExact() throws {
        let literal = "routes.duration,routes.polyline.encodedPolyline"
        XCTAssertEqual(GoogleRoutes.routeLineMask, literal)
        for (mode, _) in travelModes {
            for mask in [GoogleRoutes.mask(for: mode), GoogleRoutes.transitPlanMask, literal] {
                let header = try lineRequest(mode, mask: mask).value(forHTTPHeaderField: "x-goog-fieldmask")
                XCTAssertEqual(header, literal, "\(mode)")
                XCTAssertEqual(header?.split(separator: ",").count, 2, "\(mode)")
            }
        }
    }

    func testLINE_RequestKeepsRoutingPreferenceAndHasNoExtraComputations() throws {
        for (mode, google) in travelModes {
            for live in [false, true] {
                let request = try lineRequest(mode, live: live)
                let body = try XCTUnwrap(Support.body(of: request), "\(mode)")
                if mode == .car {
                    XCTAssertEqual(body["routingPreference"] as? String, "TRAFFIC_UNAWARE", "\(mode) live \(live)")
                } else {
                    XCTAssertNil(body["routingPreference"], "\(mode) live \(live)")
                }
                XCTAssertEqual(body["travelMode"] as? String, google, "\(mode)")
                XCTAssertNil(body["extraComputations"], "\(mode)")
                let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                XCTAssertFalse(text.contains("TRAFFIC_ON_POLYLINE"), "\(mode)")
                XCTAssertFalse(text.contains("TRAFFIC_AWARE"), "\(mode) live \(live)")
                XCTAssertFalse(text.contains("extraComputations"), "\(mode)")
                XCTAssertEqual(request.url?.path, "/routes", "\(mode)")
                let carrying = (request.allHTTPHeaderFields ?? [:]).filter { $0.value.contains(Support.token) }
                XCTAssertEqual(carrying.count, 1, "\(mode)")
                XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"), "\(mode)")
            }
        }
    }

    // MARK: - AC-ROUTELINE-003 flag false

    func testLINE_FlagFalseIsByteIdentical() throws {
        let baseKeys: Set<String> = ["origin", "destination", "travelMode", "languageCode", "regionCode"]
        for (mode, _) in travelModes {
            let omitted = try plainRequest(mode)
            let explicit = try XCTUnwrap(GoogleRoutes.request(mode: mode, from: Support.origin, to: Support.dest,
                                                              mask: GoogleRoutes.mask(for: mode), config: Support.config,
                                                              live: false, polyline: false), "\(mode)")
            XCTAssertEqual(explicit.httpBody, omitted.httpBody, "\(mode)")
            XCTAssertEqual(explicit.url, omitted.url, "\(mode)")
            XCTAssertEqual(explicit.timeoutInterval, omitted.timeoutInterval, "\(mode)")
            XCTAssertEqual(explicit.allHTTPHeaderFields, omitted.allHTTPHeaderFields, "\(mode)")
            let body = try XCTUnwrap(Support.body(of: explicit), "\(mode)")
            XCTAssertEqual(keys(of: body), mode == .car ? baseKeys.union(["routingPreference"]) : baseKeys, "\(mode)")
            let baseMask = (mode == .car || mode == .transit)
                ? "routes.duration,routes.distanceMeters"
                : "routes.duration,routes.distanceMeters,routes.warnings"
            XCTAssertEqual(explicit.value(forHTTPHeaderField: "x-goog-fieldmask"), baseMask, "\(mode)")
        }
    }

    // MARK: - Fixtures

    func testLINE_FixtureBodiesEqualAppBodies() throws {
        let names: [(name: String, mode: TransportMode)] = [("car", .car), ("walk", .walk), ("bicycle", .bicycle),
                                                            ("transit", .transit)]
        for item in names {
            let request = try lineRequest(item.mode, mask: GoogleRoutes.routeLineMask)
            let built = try XCTUnwrap(Support.body(of: request), item.name)
            let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: try Support.fixture("live-line-\(item.name)-body"))
                                         as? NSDictionary, item.name)
            XCTAssertTrue(built.isEqual(recorded), item.name)
        }
        XCTAssertEqual(try Support.fixtureText("live-line-mask"), GoogleRoutes.routeLineMask)
    }
}
