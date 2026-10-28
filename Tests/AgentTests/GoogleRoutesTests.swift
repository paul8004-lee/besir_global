import XCTest
import CoreLocation
@testable import besir

/// Anchor class so the fixtures are found through the test bundle.
final class RoutesBundleToken {}

/// Shared helpers of the route tests (SPEC-ROUTES-001). Nothing here touches the network.
enum RoutesTestSupport {
    static let host = "sentinel-host-0002.invalid"
    static let token = "SENTINEL-TOKEN-0002"
    static let config = AppConfig(kakaoJsKey: "", proxyBaseURL: "https://" + host, appToken: token)
    static let unconfigured = AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: "")
    static let origin = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
    static let dest = CLLocationCoordinate2D(latitude: 37.7694, longitude: -122.4862)

    static func fixture(_ name: String, ext: String = "json") throws -> Data {
        let url = try XCTUnwrap(Bundle(for: RoutesBundleToken.self).url(forResource: name, withExtension: ext),
                                "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    static func fixtureText(_ name: String) throws -> String {
        let text = String(decoding: try fixture(name, ext: "txt"), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The request body decoded to a dictionary, so key order never matters.
    static func body(of request: URLRequest) -> NSDictionary? {
        guard let data = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? NSDictionary
    }

    static func travelMode(of request: URLRequest) -> String? {
        body(of: request)?["travelMode"] as? String
    }

    static func latLng(_ body: NSDictionary, _ key: String) -> (latitude: Double, longitude: Double)? {
        guard let point = body[key] as? NSDictionary,
              let location = point["location"] as? NSDictionary,
              let latLng = location["latLng"] as? NSDictionary,
              let latitude = (latLng["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (latLng["longitude"] as? NSNumber)?.doubleValue else { return nil }
        return (latitude, longitude)
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func service(_ stub: RoutesTransportStub, config: AppConfig = RoutesTestSupport.config) -> DirectionsService {
        DirectionsService(config: config, transport: stub.transport)
    }

    static func httpResponse(status: Int, for request: URLRequest) -> URLResponse {
        let url = request.url ?? URL(fileURLWithPath: "/")
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
            ?? URLResponse()
    }

    static func step(_ travelMode: String, seconds: Double? = nil, from: String? = nil, to: String? = nil,
                     name: String? = nil, short: String? = nil, color: String? = nil, vehicle: String? = nil,
                     stops: Int? = nil) -> GoogleRoutes.Step {
        GoogleRoutes.Step(travelMode: travelMode, staticDuration: seconds, departureStop: from, arrivalStop: to,
                          lineName: name, lineShortName: short, lineColor: color, vehicleType: vehicle,
                          stopCount: stops)
    }
}

/// A transport that answers from a closure and records every request it receives.
final class RoutesTransportStub: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, URLResponse)

    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Answers every request with the given status and body.
    static func answering(status: Int = 200, with data: Data) -> RoutesTransportStub {
        RoutesTransportStub { request in (data, RoutesTestSupport.httpResponse(status: status, for: request)) }
    }

    /// Throws the given error for every request.
    static func throwing(_ error: Error) -> RoutesTransportStub {
        RoutesTransportStub { _ in throw error }
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var callCount: Int { requests.count }

    var transport: GoogleRoutes.Transport {
        { [self] request in
            record(request)
            return try handler(request)
        }
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        seen.append(request)
        lock.unlock()
    }
}

/// SPEC-ROUTES-001: request contract (RQ), parsing (PR), transit steps (ST), failure contract (FL),
/// preserved contract and wiring (SC) and live-request sync (LV).
final class GoogleRoutesTests: XCTestCase {
    private typealias Support = RoutesTestSupport

    private let transitPlanMask = "routes.duration,routes.distanceMeters,routes.legs.steps.travelMode,routes.legs.steps.staticDuration,routes.legs.steps.transitDetails.stopDetails.departureStop.name,routes.legs.steps.transitDetails.stopDetails.arrivalStop.name,routes.legs.steps.transitDetails.transitLine.name,routes.legs.steps.transitDetails.transitLine.nameShort,routes.legs.steps.transitDetails.transitLine.color,routes.legs.steps.transitDetails.transitLine.vehicle.type,routes.legs.steps.transitDetails.stopCount"

    private let travelModes: [(mode: TransportMode, google: String)] = [
        (.car, "DRIVE"), (.transit, "TRANSIT"), (.walk, "WALK"), (.bicycle, "BICYCLE")
    ]

    private func request(_ mode: TransportMode, config: AppConfig = Support.config) throws -> URLRequest {
        try XCTUnwrap(GoogleRoutes.request(mode: mode, from: Support.origin, to: Support.dest,
                                           mask: GoogleRoutes.mask(for: mode), config: config))
    }

    private func parsedRoute(_ fixture: String) throws -> GoogleRoutes.Route {
        try GoogleRoutes.parse(try Support.fixture(fixture))
    }

    private func assertThrows(_ expected: GoogleRoutes.LookupError, _ data: Data,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try GoogleRoutes.parse(data), file: file, line: line) { error in
            XCTAssertEqual(error as? GoogleRoutes.LookupError, expected, file: file, line: line)
        }
    }

    // MARK: - RQ request contract

    func testROUTES_RequestTargetAndHeaders() throws {
        let request = try request(.car)
        XCTAssertEqual(request.url?.path, "/routes")
        XCTAssertEqual(request.url?.host, Support.host)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-besir-token"), Support.token)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "x-goog-fieldmask"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
        let carrying = (request.allHTTPHeaderFields ?? [:]).filter { $0.value.contains(Support.token) }
        XCTAssertEqual(carrying.count, 1)
        let bodyText = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(bodyText.contains(Support.token))
        XCTAssertFalse(bodyText.isEmpty)
    }

    func testROUTES_BodyCommonFields() throws {
        for (mode, google) in travelModes {
            let body = try XCTUnwrap(Support.body(of: try request(mode)), "\(mode)")
            let origin = try XCTUnwrap(Support.latLng(body, "origin"))
            let destination = try XCTUnwrap(Support.latLng(body, "destination"))
            XCTAssertEqual(origin.latitude, 37.7955, accuracy: 1e-9)
            XCTAssertEqual(origin.longitude, -122.3937, accuracy: 1e-9)
            XCTAssertEqual(destination.latitude, 37.7694, accuracy: 1e-9)
            XCTAssertEqual(destination.longitude, -122.4862, accuracy: 1e-9)
            XCTAssertEqual(body["languageCode"] as? String, "en-US")
            XCTAssertEqual(body["regionCode"] as? String, "US")
            XCTAssertEqual(body["travelMode"] as? String, google)
        }
    }

    func testROUTES_BodyDriveTrafficUnaware() throws {
        let body = try XCTUnwrap(Support.body(of: try request(.car)))
        XCTAssertEqual(body["routingPreference"] as? String, "TRAFFIC_UNAWARE")
    }

    func testROUTES_BodyOtherModesNoRoutingPreference() throws {
        for mode in [TransportMode.transit, .walk, .bicycle] {
            let body = try XCTUnwrap(Support.body(of: try request(mode)), "\(mode)")
            XCTAssertNil(body["routingPreference"], "\(mode)")
            XCTAssertEqual(body["regionCode"] as? String, "US")
        }
    }

    func testROUTES_BodyHasNoTimesAndNoPolylineOptions() throws {
        for mode in TransportMode.allCases {
            let body = try XCTUnwrap(Support.body(of: try request(mode)), "\(mode)")
            for key in ["departureTime", "arrivalTime", "polylineQuality", "polylineEncoding"] {
                XCTAssertNil(body[key], "\(mode) \(key)")
            }
        }
    }

    func testROUTES_MaskEstimateDriveTransit() throws {
        XCTAssertEqual(GoogleRoutes.mask(for: .car), "routes.duration,routes.distanceMeters")
        XCTAssertEqual(GoogleRoutes.mask(for: .transit), "routes.duration,routes.distanceMeters")
        XCTAssertEqual(try request(.car).value(forHTTPHeaderField: "x-goog-fieldmask"),
                       "routes.duration,routes.distanceMeters")
        XCTAssertEqual(try request(.transit).value(forHTTPHeaderField: "x-goog-fieldmask"),
                       "routes.duration,routes.distanceMeters")
    }

    func testROUTES_MaskEstimateWalkBicycleWarnings() throws {
        let expected = "routes.duration,routes.distanceMeters,routes.warnings"
        XCTAssertEqual(GoogleRoutes.mask(for: .walk), expected)
        XCTAssertEqual(GoogleRoutes.mask(for: .bicycle), expected)
        XCTAssertEqual(try request(.walk).value(forHTTPHeaderField: "x-goog-fieldmask"), expected)
        XCTAssertEqual(try request(.bicycle).value(forHTTPHeaderField: "x-goog-fieldmask"), expected)
    }

    // MARK: - REPLAN live request (SPEC-REPLAN-001, AC-REPLAN-001 and 002)

    private func liveRequest(_ mode: TransportMode, live: Bool = true) throws -> URLRequest {
        try XCTUnwrap(GoogleRoutes.request(mode: mode, from: Support.origin, to: Support.dest,
                                           mask: GoogleRoutes.mask(for: mode), config: Support.config, live: live))
    }

    func testREPLAN_LiveCarBodyTrafficAware() throws {
        let body = try XCTUnwrap(Support.body(of: try liveRequest(.car)))
        XCTAssertEqual(body["routingPreference"] as? String, "TRAFFIC_AWARE")
        XCTAssertEqual(body["travelMode"] as? String, "DRIVE")
        for key in ["departureTime", "arrivalTime"] { XCTAssertNil(body[key], key) }
    }

    func testREPLAN_LiveCarMaskExact() throws {
        let expected = "routes.duration,routes.staticDuration,routes.distanceMeters"
        XCTAssertEqual(GoogleRoutes.liveCarMask, expected)
        XCTAssertEqual(try liveRequest(.car).value(forHTTPHeaderField: "x-goog-fieldmask"), expected)
    }

    func testREPLAN_LiveOtherModesUnchanged() throws {
        for mode in [TransportMode.transit, .walk, .bicycle] {
            let live = try liveRequest(mode, live: true)
            let plain = try liveRequest(mode, live: false)
            XCTAssertEqual(live.httpBody, plain.httpBody, "\(mode)")
            XCTAssertEqual(live.value(forHTTPHeaderField: "x-goog-fieldmask"),
                           plain.value(forHTTPHeaderField: "x-goog-fieldmask"), "\(mode)")
            XCTAssertEqual(live.url, plain.url, "\(mode)")
        }
    }

    func testREPLAN_DefaultRequestsByteIdentical() throws {
        for mode in TransportMode.allCases {
            let omitted = try request(mode)
            let explicit = try liveRequest(mode, live: false)
            XCTAssertEqual(omitted.httpBody, explicit.httpBody, "\(mode)")
            XCTAssertEqual(omitted.value(forHTTPHeaderField: "x-goog-fieldmask"),
                           explicit.value(forHTTPHeaderField: "x-goog-fieldmask"), "\(mode)")
        }
        let car = try XCTUnwrap(Support.body(of: try request(.car)))
        XCTAssertEqual(Set(car.allKeys.compactMap { $0 as? String }),
                       ["origin", "destination", "travelMode", "languageCode", "regionCode", "routingPreference"])
        XCTAssertEqual(car["routingPreference"] as? String, "TRAFFIC_UNAWARE")
        XCTAssertEqual(try request(.car).value(forHTTPHeaderField: "x-goog-fieldmask"), "routes.duration,routes.distanceMeters")
    }

    func testREPLAN_ParseStaticDuration() throws {
        let data = Support.json(["routes": [["duration": "1860s", "staticDuration": "1080s", "distanceMeters": 9214]]])
        let route = try GoogleRoutes.parse(data)
        XCTAssertEqual(route.duration, 1860)
        XCTAssertEqual(route.staticDuration, 1080)
        XCTAssertEqual(route.distance, 9214)
    }

    func testREPLAN_ParseStaticDurationAbsentOrInvalid() throws {
        let variants: [[String: Any]] = [
            ["duration": "1860s"],
            ["duration": "1860s", "staticDuration": NSNull()],
            ["duration": "1860s", "staticDuration": "abc"],
            ["duration": "1860s", "staticDuration": "-5s"],
            ["duration": "1860s", "staticDuration": 5]
        ]
        for route in variants {
            let parsed = try GoogleRoutes.parse(Support.json(["routes": [route]]))
            XCTAssertEqual(parsed.duration, 1860, "\(route)")
            XCTAssertNil(parsed.staticDuration, "\(route)")
        }
    }

    func testROUTES_MaskTransitPlanExact() throws {
        XCTAssertEqual(GoogleRoutes.transitPlanMask, transitPlanMask)
        XCTAssertEqual(GoogleRoutes.transitPlanMask.split(separator: ",").count, 11)
        let planRequest = try XCTUnwrap(GoogleRoutes.request(mode: .transit, from: Support.origin, to: Support.dest,
                                                             mask: GoogleRoutes.transitPlanMask,
                                                             config: Support.config))
        XCTAssertEqual(planRequest.value(forHTTPHeaderField: "x-goog-fieldmask"), transitPlanMask)
    }

    func testROUTES_MasksHaveNoWildcardAndNoPolyline() {
        var masks = TransportMode.allCases.map { GoogleRoutes.mask(for: $0) }
        masks.append(GoogleRoutes.transitPlanMask)
        XCTAssertEqual(masks.count, 5)
        for mask in masks {
            XCTAssertFalse(mask.isEmpty)
            XCTAssertFalse(mask.contains("*"), mask)
            XCTAssertFalse(mask.lowercased().contains("polyline"), mask)
        }
    }

    func testROUTES_UnconfiguredBuildsNoRequest() async throws {
        let stub = RoutesTransportStub.answering(with: try Support.fixture("routes-drive"))
        for mode in TransportMode.allCases {
            XCTAssertNil(GoogleRoutes.request(mode: mode, from: Support.origin, to: Support.dest,
                                              mask: GoogleRoutes.mask(for: mode), config: Support.unconfigured),
                         "\(mode)")
            XCTAssertNotNil(GoogleRoutes.request(mode: mode, from: Support.origin, to: Support.dest,
                                                 mask: GoogleRoutes.mask(for: mode), config: Support.config),
                            "\(mode)")
        }
        _ = await Support.service(stub, config: Support.unconfigured).estimateAll(from: Support.origin,
                                                                                  to: Support.dest)
        XCTAssertEqual(stub.callCount, 0)
    }

    // MARK: - PR response parsing

    func testROUTES_DurationStringParsing() {
        XCTAssertEqual(GoogleRoutes.parseDuration("1053s"), 1053)
        XCTAssertEqual(GoogleRoutes.parseDuration("3.5s"), 3.5)
        XCTAssertEqual(GoogleRoutes.parseDuration("0s"), 0)
        for bad in ["1053", "-5s", "s", "", "1e3s", "10 s", "NaNs", "1.s", ".5s", "1..5s"] {
            XCTAssertNil(GoogleRoutes.parseDuration(bad), bad)
        }
    }

    func testROUTES_ParseEstimateDriveShape() throws {
        let literal = Data(#"{"routes":[{"duration":"1053s","distanceMeters":9214}]}"#.utf8)
        for data in [literal, try Support.fixture("routes-drive")] {
            let route = try GoogleRoutes.parse(data)
            XCTAssertEqual(route.duration, 1053)
            XCTAssertEqual(route.distance, 9214)
            XCTAssertEqual(route.warnings, [])
        }
    }

    func testROUTES_ParseEstimateDistanceOptional() throws {
        let missing = try GoogleRoutes.parse(Support.json(["routes": [["duration": "600s"]]]))
        XCTAssertEqual(missing.duration, 600)
        XCTAssertNil(missing.distance)
        let text = try GoogleRoutes.parse(Support.json(["routes": [["duration": "600s", "distanceMeters": "9214"]]]))
        XCTAssertEqual(text.duration, 600)
        XCTAssertNil(text.distance)
    }

    func testROUTES_ParseWarningsKeptVerbatim() throws {
        let warnings: [Any] = ["He said \"hi\"", "caf\u{e9} \u{2013} ok", "third", 3, ["x": 1]]
        let route = try GoogleRoutes.parse(Support.json(["routes": [["duration": "60s", "warnings": warnings]]]))
        XCTAssertEqual(route.warnings, ["He said \"hi\"", "caf\u{e9} \u{2013} ok", "third"])
        let fixture = try parsedRoute("routes-walk-warnings")
        XCTAssertEqual(fixture.warnings, ["WARNING-FIXTURE-1", "WARNING-FIXTURE-2"])
    }

    func testROUTES_ParseEmptyRoutesIsNoRoute() async throws {
        let bodies = [Data("{}".utf8), Data(#"{"routes":[]}"#.utf8), Data(#"{"routes":null}"#.utf8)]
        for data in bodies {
            assertThrows(.noRoute, data)
            let stub = RoutesTransportStub.answering(with: data)
            let estimate = await Support.service(stub).estimate(.car, from: Support.origin, to: Support.dest)
            XCTAssertNil(estimate.duration)
            XCTAssertEqual(estimate.failure, .noRoute)
        }
        XCTAssertEqual(try parsedRoute("routes-drive").duration, 1053)
    }

    func testROUTES_ParseRouteWithoutDurationIsMalformed() async throws {
        let bodies = [Data(#"{"routes":[{}]}"#.utf8), Data(#"{"routes":[{"duration":"abc"}]}"#.utf8),
                      try Support.fixture("routes-no-duration")]
        for data in bodies {
            assertThrows(.malformed, data)
            let stub = RoutesTransportStub.answering(with: data)
            let estimate = await Support.service(stub).estimate(.car, from: Support.origin, to: Support.dest)
            XCTAssertNil(estimate.duration)
            XCTAssertEqual(estimate.failure, .lookupFailed)
        }
        XCTAssertEqual(try parsedRoute("routes-drive").duration, 1053)
    }

    func testROUTES_ParseRoutesNotArrayIsMalformed() throws {
        assertThrows(.malformed, Data(#"{"routes":"x"}"#.utf8))
        assertThrows(.malformed, Data(#"{"routes":{}}"#.utf8))
        assertThrows(.malformed, try Support.fixture("routes-routes-not-array"))
        XCTAssertEqual(try parsedRoute("routes-drive").duration, 1053)
    }

    func testROUTES_ParseUndecodableIsMalformed() throws {
        assertThrows(.malformed, Data("<html>Bad gateway</html>".utf8))
        assertThrows(.malformed, Data())
        assertThrows(.malformed, Data([0xff, 0xfe, 0x00, 0x9c, 0x41]))
        assertThrows(.malformed, Data("[1,2,3]".utf8))
        XCTAssertEqual(try parsedRoute("routes-drive").duration, 1053)
    }

    func testROUTES_ParseIgnoresUnknownFields() throws {
        let plain = try parsedRoute("routes-transit-steps")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try Support.fixture("routes-transit-steps"))
                                   as? [String: Any])
        object["extraTop"] = ["a": 1]
        var routes = try XCTUnwrap(object["routes"] as? [[String: Any]])
        routes[0]["extraRoute"] = "x"
        routes[0]["viewport"] = ["low": 1]
        var legs = try XCTUnwrap(routes[0]["legs"] as? [[String: Any]])
        var steps = try XCTUnwrap(legs[0]["steps"] as? [[String: Any]])
        steps[0]["extraStep"] = [1, 2, 3]
        legs[0]["steps"] = steps
        routes[0]["legs"] = legs
        object["routes"] = routes
        XCTAssertEqual(try GoogleRoutes.parse(Support.json(object)), plain)
    }

    // MARK: - ST transit steps

    func testROUTES_StepsWalkBusWalk() throws {
        let route = try parsedRoute("routes-transit-steps")
        let result = GoogleRoutes.transitSteps(from: route)
        XCTAssertEqual(result.steps.map(\.kind), [.walk, .bus, .walk])
        guard result.steps.count == 3 else { return }
        XCTAssertEqual(result.steps[0].headline, "Walk 4 min")
        XCTAssertEqual(result.steps[0].detail, "Walk to Example Stop A")
        XCTAssertEqual(result.steps[1].headline, "Take bus 38R")
        XCTAssertEqual(result.steps[1].detail, "Example Stop A \u{2192} Example Stop B \u{b7} 3 stop(s) \u{b7} 12 min")
        XCTAssertEqual(result.steps[2].headline, "Walk 2 min")
        XCTAssertEqual(result.steps[2].detail, "Walk to Destination")
        XCTAssertEqual(result.extraMinutes, 7)
    }

    func testROUTES_StepsPreferNameShort() {
        func line(_ short: String?, _ name: String?, vehicle: String = "BUS") -> String {
            let route = GoogleRoutes.Route(duration: 600, steps: [
                Support.step("TRANSIT", seconds: 600, name: name, short: short, vehicle: vehicle)
            ])
            return GoogleRoutes.transitSteps(from: route).steps.first?.line ?? "<none>"
        }
        XCTAssertEqual(line("38R", "Geary Rapid"), "38R")
        XCTAssertEqual(line(nil, "Geary Rapid"), "Geary Rapid")
        XCTAssertEqual(line("   ", "Geary Rapid"), "Geary Rapid")
        XCTAssertEqual(line(nil, nil), "route")
        XCTAssertEqual(line(nil, nil, vehicle: "SUBWAY"), "transit")
        for label in [line("38R", "Geary Rapid"), line(nil, nil), line(nil, nil, vehicle: "SUBWAY")] {
            XCTAssertFalse(label.contains("Bus"), label)
        }
    }

    func testROUTES_StepsLineColorFromGoogle() {
        let route = GoogleRoutes.Route(duration: 600, steps: [
            Support.step("TRANSIT", seconds: 600, short: "38R", color: "#0E61A8", vehicle: "BUS")
        ])
        XCTAssertEqual(GoogleRoutes.transitSteps(from: route).steps.first?.color, "#0E61A8")
    }

    func testROUTES_StepsColorFallbackPerVehicleKind() {
        func color(_ value: String?, vehicle: String) -> String {
            let route = GoogleRoutes.Route(duration: 600, steps: [
                Support.step("TRANSIT", seconds: 600, short: "X", color: value, vehicle: vehicle)
            ])
            return GoogleRoutes.transitSteps(from: route).steps.first?.color ?? "<none>"
        }
        for value in [nil, "0E61A8", "#12", "#GGGGGG", "#0E61A8FF"] as [String?] {
            XCTAssertEqual(color(value, vehicle: "BUS"), "#3D5BAB", "\(value ?? "nil")")
            XCTAssertEqual(color(value, vehicle: "SUBWAY"), "#3d5bf0", "\(value ?? "nil")")
        }
        XCTAssertEqual(color("#0E61A8", vehicle: "BUS"), "#0E61A8")
    }

    func testROUTES_StepsVehicleKindMapping() {
        func kind(_ vehicle: String?) -> RouteMode? {
            let route = GoogleRoutes.Route(duration: 600, steps: [
                Support.step("TRANSIT", seconds: 600, short: "X", vehicle: vehicle)
            ])
            return GoogleRoutes.transitSteps(from: route).steps.first?.kind
        }
        for bus in ["BUS", "INTERCITY_BUS", "TROLLEYBUS"] {
            XCTAssertEqual(kind(bus), .bus, bus)
        }
        for other in ["SUBWAY", "TRAM", "HEAVY_RAIL", "FERRY", "CABLE_CAR", "SOMETHING_NEW", nil] as [String?] {
            XCTAssertEqual(kind(other), .subway, "\(other ?? "nil")")
        }
        let route = GoogleRoutes.Route(duration: 600, steps: [Support.step("TRANSIT", seconds: 600, vehicle: "TRAM")])
        XCTAssertEqual(GoogleRoutes.transitSteps(from: route).steps.first?.systemImage, "tram.fill")
    }

    func testROUTES_StepsExtraMinutesInvariant() {
        let cases: [(total: Double, parts: [Double])] = [
            (1500, [240, 720, 120]),
            (2000, [90, 600, 45]),
            (5400, [300, 1800, 300]),
            (1000, [30, 500]),
            (777, [60, 600])
        ]
        for item in cases {
            var steps: [GoogleRoutes.Step] = []
            for (index, seconds) in item.parts.enumerated() {
                steps.append(index == 1
                             ? Support.step("TRANSIT", seconds: seconds, from: "A", to: "B", short: "X", vehicle: "BUS")
                             : Support.step("WALK", seconds: seconds))
            }
            let result = GoogleRoutes.transitSteps(from: GoogleRoutes.Route(duration: item.total, steps: steps))
            let sum = result.steps.reduce(0) { $0 + $1.minutes }
            let extra = result.extraMinutes
            XCTAssertNotNil(extra, "\(item.total)")
            XCTAssertEqual(sum + (extra ?? 0), roundedMinutes(fromSeconds: item.total), "\(item.total)")
            XCTAssertGreaterThanOrEqual(extra ?? 0, 1)
            for (step, seconds) in zip(result.steps, item.parts) {
                XCTAssertEqual(step.minutes, roundedMinutes(fromSeconds: seconds))
            }
        }
    }

    func testROUTES_StepsNoExtraWhenNoWait() throws {
        let exact = GoogleRoutes.transitSteps(from: try parsedRoute("routes-transit-no-wait"))
        XCTAssertEqual(exact.steps.count, 3)
        XCTAssertNil(exact.extraMinutes)
        let over = GoogleRoutes.Route(duration: 600, steps: [
            Support.step("WALK", seconds: 300), Support.step("TRANSIT", seconds: 600, from: "A", to: "B", short: "X")
        ])
        XCTAssertNil(GoogleRoutes.transitSteps(from: over).extraMinutes)
        XCTAssertEqual(GoogleRoutes.transitSteps(from: try parsedRoute("routes-transit-steps")).extraMinutes, 7)
    }

    func testROUTES_StepsZeroMinuteWalkSkipped() {
        let route = GoogleRoutes.Route(duration: 900, steps: [
            Support.step("WALK", seconds: 20),
            Support.step("TRANSIT", seconds: 10, from: "A", to: "B", short: "X", vehicle: "BUS"),
            Support.step("WALK", seconds: 120)
        ])
        let result = GoogleRoutes.transitSteps(from: route)
        XCTAssertEqual(result.steps.map(\.kind), [.bus, .walk])
        XCTAssertEqual(result.steps.first?.minutes, 0)
        XCTAssertEqual(result.steps.last?.minutes, 2)
    }

    func testROUTES_StepsConsecutiveWalksMergedIntoOneRow() throws {
        let route = try parsedRoute("routes-transit-many-walks")
        XCTAssertEqual(route.steps.count, 14)
        let result = GoogleRoutes.transitSteps(from: route)
        XCTAssertEqual(result.steps.map(\.kind), [.walk, .bus, .walk])
        guard result.steps.count == 3 else { return }
        XCTAssertEqual(result.steps.map(\.minutes), [9, 37, 7])
        XCTAssertEqual(result.steps[0].headline, "Walk 9 min")
        XCTAssertEqual(result.steps[0].detail, "Walk to Example Stop A")
        XCTAssertEqual(result.steps[1].headline, "Take bus 38R")
        XCTAssertEqual(result.steps[1].detail, "Example Stop A \u{2192} Example Stop B \u{b7} 20 stop(s) \u{b7} 37 min")
        XCTAssertEqual(result.steps[2].headline, "Walk 7 min")
        XCTAssertEqual(result.steps[2].detail, "Walk to Destination")
        XCTAssertNil(result.extraMinutes)
    }

    func testROUTES_StepsMergedWalkRoundsOnce() {
        let tiny = GoogleRoutes.Route(duration: 600, steps: [
            Support.step("WALK", seconds: 20), Support.step("WALK", seconds: 20), Support.step("WALK", seconds: 20),
            Support.step("TRANSIT", seconds: 300, from: "A", to: "B", short: "X", vehicle: "BUS")
        ])
        let tinyResult = GoogleRoutes.transitSteps(from: tiny)
        XCTAssertEqual(tinyResult.steps.map(\.kind), [.walk, .bus])
        XCTAssertEqual(tinyResult.steps.first?.minutes, 1)
        XCTAssertEqual(tinyResult.extraMinutes, 4)
        let halves = GoogleRoutes.Route(duration: 600, steps: [
            Support.step("WALK", seconds: 40), Support.step("WALK", seconds: 40),
            Support.step("TRANSIT", seconds: 300, from: "A", to: "B", short: "X", vehicle: "BUS")
        ])
        XCTAssertEqual(GoogleRoutes.transitSteps(from: halves).steps.first?.minutes, 1)
        let dust = GoogleRoutes.Route(duration: 600, steps: [
            Support.step("WALK", seconds: 12), Support.step("WALK", seconds: 5),
            Support.step("TRANSIT", seconds: 300, from: "A", to: "B", short: "X", vehicle: "BUS")
        ])
        XCTAssertEqual(GoogleRoutes.transitSteps(from: dust).steps.map(\.kind), [.bus])
    }

    func testROUTES_StepsWalkRunsStayApartAcrossTransit() {
        let route = GoogleRoutes.Route(duration: 2400, steps: [
            Support.step("WALK", seconds: 120), Support.step("WALK", seconds: 60),
            Support.step("TRANSIT", seconds: 600, from: "A", to: "B", short: "X", vehicle: "BUS"),
            Support.step("WALK", seconds: 90), Support.step("WALK"), Support.step("WALK", seconds: 90),
            Support.step("TRANSIT", seconds: 600, from: "C", to: "D", short: "Y", vehicle: "SUBWAY"),
            Support.step("WALK", seconds: 60), Support.step("WALK", seconds: 60)
        ])
        let result = GoogleRoutes.transitSteps(from: route)
        XCTAssertEqual(result.steps.map(\.kind), [.walk, .bus, .walk, .subway, .walk])
        XCTAssertEqual(result.steps.map(\.minutes), [3, 10, 3, 10, 2])
        XCTAssertEqual(result.steps.map(\.to), ["A", "B", "C", "D", "Destination"])
        XCTAssertEqual(result.steps.map(\.from), ["Start", "A", "B", "C", "D"])
        let sum = result.steps.reduce(0) { $0 + $1.minutes }
        XCTAssertEqual(sum + (result.extraMinutes ?? 0), roundedMinutes(fromSeconds: 2400))
    }

    func testROUTES_StepsMissingDurationCountsZero() throws {
        let result = GoogleRoutes.transitSteps(from: try parsedRoute("routes-transit-no-duration"))
        XCTAssertEqual(result.steps.map(\.kind), [.bus])
        XCTAssertEqual(result.steps.first?.minutes, 0)
        XCTAssertEqual(result.extraMinutes, 25)
        let route = GoogleRoutes.Route(duration: 600, steps: [Support.step("TRANSIT", from: "A", to: "B", short: "X")])
        let plain = GoogleRoutes.transitSteps(from: route)
        XCTAssertEqual(plain.steps.first?.minutes, 0)
        XCTAssertEqual(plain.extraMinutes, 10)
    }

    func testROUTES_StepsEnglishFallbackNames() {
        let route = GoogleRoutes.Route(duration: 1800, steps: [
            Support.step("TRANSIT", seconds: 600, vehicle: "BUS"),
            Support.step("TRANSIT", seconds: 300, vehicle: "SUBWAY"),
            Support.step("WALK", seconds: 120)
        ])
        let steps = GoogleRoutes.transitSteps(from: route).steps
        XCTAssertEqual(steps.count, 3)
        guard steps.count == 3 else { return }
        XCTAssertEqual(steps[0].from, "Start")
        XCTAssertEqual(steps[0].to, "Get off")
        XCTAssertEqual(steps[1].from, "Get off")
        XCTAssertEqual(steps[1].to, "Get off")
        XCTAssertEqual(steps[2].kind, .walk)
        XCTAssertEqual(steps[2].to, "Destination")
        for step in steps {
            for text in [step.headline, step.detail, step.from, step.to, step.line] {
                let allowed: Set<UInt32> = [0xb7, 0x2192]
                XCTAssertTrue(text.unicodeScalars.allSatisfy { ($0.isASCII) || allowed.contains($0.value) }, text)
            }
        }
        let first = GoogleRoutes.Route(duration: 600, steps: [Support.step("WALK", seconds: 300),
                                                                Support.step("TRANSIT", seconds: 300, vehicle: "BUS")])
        XCTAssertEqual(GoogleRoutes.transitSteps(from: first).steps.first?.kind, .walk)
        XCTAssertEqual(GoogleRoutes.transitSteps(from: first).steps.first?.from, "Start")
        XCTAssertEqual(GoogleRoutes.transitSteps(from: first).steps.first?.to, "Destination")
    }

    func testROUTES_StepsStopCount() {
        func stationCount(_ stops: Int?) -> Int? {
            let route = GoogleRoutes.Route(duration: 600, steps: [
                Support.step("TRANSIT", seconds: 600, from: "A", to: "B", short: "X", vehicle: "BUS", stops: stops)
            ])
            return GoogleRoutes.transitSteps(from: route).steps.first?.stationCount
        }
        XCTAssertEqual(stationCount(3), 3)
        XCTAssertNil(stationCount(nil))
        XCTAssertEqual(stationCount(1), 1)
    }

    // MARK: - FL failure contract

    func testROUTES_ErrorCodeFromWorkerShape() throws {
        XCTAssertEqual(GoogleRoutes.errorCode(from: try Support.fixture("routes-worker-unauthorized")), "unauthorized")
        XCTAssertEqual(GoogleRoutes.errorCode(from: try Support.fixture("routes-worker-key-missing")),
                       "google_key_not_configured")
        XCTAssertNil(GoogleRoutes.errorCode(from: Data("<html>nope</html>".utf8)))
        XCTAssertNil(GoogleRoutes.errorCode(from: Data()))
    }

    func testROUTES_ErrorCodeFromGoogleShape() throws {
        XCTAssertEqual(GoogleRoutes.errorCode(from: try Support.fixture("routes-google-error-403")),
                       "PERMISSION_DENIED")
        XCTAssertEqual(GoogleRoutes.errorCode(from: try Support.fixture("routes-google-error-400")),
                       "API_KEY_INVALID")
        XCTAssertEqual(GoogleRoutes.errorCode(from: Data(#"{"error":{"code":429,"message":"x"}}"#.utf8)), "HTTP_429")
    }

    func testROUTES_ClassifyNotConfigured() {
        func classify(_ code: String?, status: Int? = nil) -> TravelFailure? {
            TravelFailure.classify(hasProxy: true, urlErrorCode: nil, bodyErrorCode: code, isCancellation: false,
                                   httpStatus: status)
        }
        for code in ["unauthorized", "google_key_not_configured", "PERMISSION_DENIED", "UNAUTHENTICATED",
                     "API_KEY_INVALID"] {
            XCTAssertEqual(classify(code), .notConfigured, code)
        }
        XCTAssertEqual(classify(nil, status: 401), .notConfigured)
        XCTAssertEqual(classify(nil, status: 403), .notConfigured)
        XCTAssertEqual(classify("INVALID_ARGUMENT"), .lookupFailed)
    }

    func testROUTES_ClassifyLookupFailed() {
        func classify(_ code: String?, status: Int? = nil) -> TravelFailure? {
            TravelFailure.classify(hasProxy: true, urlErrorCode: nil, bodyErrorCode: code, isCancellation: false,
                                   httpStatus: status)
        }
        for code in ["INVALID_ARGUMENT", "HTTP_429", "upstream_unreachable", "invalid_json"] {
            XCTAssertEqual(classify(code), .lookupFailed, code)
        }
        for status in [400, 404, 500, 502, 503] {
            XCTAssertEqual(classify(nil, status: status), .lookupFailed, "\(status)")
        }
        XCTAssertEqual(classify(nil), .lookupFailed)
        XCTAssertEqual(classify("PERMISSION_DENIED"), .notConfigured)
    }

    func testROUTES_ClassifyOfflineAndCancellation() {
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                                        .internationalRoamingOff, .callIsActive, .cannotFindHost,
                                        .cannotConnectToHost, .dnsLookupFailed]
        for code in offline {
            XCTAssertEqual(TravelFailure.classify(hasProxy: true, urlErrorCode: code, bodyErrorCode: nil,
                                                  isCancellation: false, httpStatus: nil), .offline, "\(code)")
        }
        XCTAssertEqual(TravelFailure.classify(hasProxy: true, urlErrorCode: .timedOut, bodyErrorCode: nil,
                                              isCancellation: false, httpStatus: nil), .lookupFailed)
        XCTAssertNil(TravelFailure.classify(hasProxy: true, urlErrorCode: .notConnectedToInternet,
                                            bodyErrorCode: "unauthorized", isCancellation: true, httpStatus: 403))
        XCTAssertEqual(TravelFailure.classify(hasProxy: true, urlErrorCode: nil, bodyErrorCode: nil,
                                              isCancellation: false, httpStatus: 403), .notConfigured)
        XCTAssertEqual(TravelFailure.classify(hasProxy: false, urlErrorCode: nil, bodyErrorCode: nil,
                                              isCancellation: false, httpStatus: nil), .notConfigured)
    }

    func testROUTES_FailureForNoRouteError() throws {
        XCTAssertEqual(GoogleRoutes.failure(for: GoogleRoutes.LookupError.noRoute, hasProxy: true), .noRoute)
        XCTAssertEqual(GoogleRoutes.failure(for: GoogleRoutes.LookupError.malformed, hasProxy: true), .lookupFailed)
        XCTAssertNil(GoogleRoutes.failure(for: CancellationError(), hasProxy: true))
        XCTAssertNil(GoogleRoutes.failure(for: URLError(.cancelled), hasProxy: true))
        XCTAssertEqual(GoogleRoutes.failure(for: GoogleRoutes.LookupError.http(status: 403, code: nil), hasProxy: true),
                       .notConfigured)
        XCTAssertEqual(try parsedRoute("routes-drive").duration, 1053)
    }

    func testROUTES_EstimateNon200GivesFailure() async throws {
        let table: [(status: Int, failure: TravelFailure)] = [
            (400, .lookupFailed), (401, .notConfigured), (403, .notConfigured), (429, .lookupFailed),
            (500, .lookupFailed), (502, .lookupFailed), (503, .lookupFailed)
        ]
        for item in table {
            let stub = RoutesTransportStub.answering(status: item.status, with: Data("{}".utf8))
            let estimate = await Support.service(stub).estimate(.car, from: Support.origin, to: Support.dest)
            XCTAssertNil(estimate.duration, "\(item.status)")
            XCTAssertEqual(estimate.failure, item.failure, "\(item.status)")
        }
        let nonHTTP = RoutesTransportStub { _ in (Data("{}".utf8), URLResponse()) }
        let odd = await Support.service(nonHTTP).estimate(.car, from: Support.origin, to: Support.dest)
        XCTAssertEqual(odd.failure, .lookupFailed)
        let good = RoutesTransportStub.answering(with: try Support.fixture("routes-drive"))
        let estimate = await Support.service(good).estimate(.car, from: Support.origin, to: Support.dest)
        XCTAssertEqual(estimate.duration, 1053)
        XCTAssertNil(estimate.failure)
    }

    func testROUTES_EstimateTransportThrows() async throws {
        let offline = RoutesTransportStub.throwing(URLError(.notConnectedToInternet))
        let first = await Support.service(offline).estimate(.walk, from: Support.origin, to: Support.dest)
        XCTAssertEqual(first.failure, .offline)
        let timeout = RoutesTransportStub.throwing(URLError(.timedOut))
        let second = await Support.service(timeout).estimate(.walk, from: Support.origin, to: Support.dest)
        XCTAssertEqual(second.failure, .lookupFailed)
        XCTAssertEqual(offline.callCount, 1)
        XCTAssertEqual(timeout.callCount, 1)
    }

    func testROUTES_EstimateCancelledHasNoFailure() async throws {
        let stub = RoutesTransportStub.throwing(CancellationError())
        let estimate = await Support.service(stub).estimate(.bicycle, from: Support.origin, to: Support.dest)
        XCTAssertNil(estimate.duration)
        XCTAssertNil(estimate.failure)
        XCTAssertEqual(stub.callCount, 1)
    }

    func testROUTES_EstimateUnconfiguredSendsNothing() async throws {
        let stub = RoutesTransportStub.answering(with: try Support.fixture("routes-drive"))
        for mode in TransportMode.allCases {
            let estimate = await Support.service(stub, config: Support.unconfigured)
                .estimate(mode, from: Support.origin, to: Support.dest)
            XCTAssertEqual(estimate.failure, .notConfigured, "\(mode)")
        }
        XCTAssertEqual(stub.callCount, 0)
        let configured = await Support.service(stub).estimate(.car, from: Support.origin, to: Support.dest)
        XCTAssertEqual(configured.duration, 1053)
        XCTAssertEqual(stub.callCount, 1)
    }

    func testROUTES_EstimateAllSendsOneRequestPerMode() async throws {
        let stub = RoutesTransportStub.answering(with: try Support.fixture("routes-drive"))
        let all = await Support.service(stub).estimateAll(from: Support.origin, to: Support.dest)
        XCTAssertEqual(stub.callCount, 4)
        XCTAssertEqual(stub.requests.compactMap(Support.travelMode(of:)).sorted(),
                       ["BICYCLE", "DRIVE", "TRANSIT", "WALK"])
        XCTAssertEqual(Set(all.keys), Set(TransportMode.allCases))
        for mode in TransportMode.allCases {
            XCTAssertEqual(all[mode]?.duration, 1053, "\(mode)")
        }
    }

    // MARK: - SC preserved contract and wiring

    func testROUTES_EstimateSourceIsGoogle() async throws {
        let good = RoutesTransportStub.answering(with: try Support.fixture("routes-drive"))
        let ok = await Support.service(good).estimate(.car, from: Support.origin, to: Support.dest)
        XCTAssertEqual(ok.duration, 1053)
        XCTAssertEqual(ok.source, "Google")
        let bad = RoutesTransportStub.answering(status: 500, with: Data("{}".utf8))
        let failed = await Support.service(bad).estimate(.car, from: Support.origin, to: Support.dest)
        XCTAssertEqual(failed.source, "Google")
        let unconfigured = await Support.service(good, config: Support.unconfigured)
            .estimate(.car, from: Support.origin, to: Support.dest)
        XCTAssertEqual(unconfigured.source, "Google")
    }

    func testROUTES_TravelEstimateOldInitializerStillCompiles() {
        let estimate = TravelEstimate(mode: .car, duration: 600, distance: 1000, source: "Google")
        XCTAssertEqual(estimate.warnings, [])
        XCTAssertNil(estimate.failure)
        XCTAssertEqual(estimate.duration, 600)
    }

    func testROUTES_TitlesAndDurationTextUnchanged() {
        XCTAssertEqual(TransportMode.allCases.map(\.title), ["Car", "Transit", "Walk", "Bicycle"])
        XCTAssertEqual(TransportMode.allCases.map(\.titleWithParticle), ["By car", "By transit", "On foot", "By bicycle"])
        XCTAssertEqual(TravelEstimate(mode: .car, duration: 1500, distance: nil, source: "Google").durationText, "25 min")
        XCTAssertEqual(TravelEstimate(mode: .car, duration: 5400, distance: nil, source: "Google").durationText,
                       "1 hr 30 min")
        XCTAssertEqual(TravelEstimate(mode: .car, duration: nil, distance: nil, source: "Google").durationText, "No info")
        XCTAssertEqual(TravelFailure.allCases.map(\.caption).sorted(), ["Failed", "No route", "Offline", "Setup"])
    }

    func testROUTES_DepartureFormulaUnchanged() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let arrival = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 18)))
        let departure = Store.departureTime(arrival: arrival, travelSeconds: 1500, bufferMinutes: 10)
        let parts = calendar.dateComponents([.hour, .minute], from: departure)
        XCTAssertEqual(parts.hour, 17)
        XCTAssertEqual(parts.minute, 25)
    }

    func testROUTES_TransitPlanFailurePlumbing() async throws {
        let empty = RoutesTransportStub.answering(with: try Support.fixture("routes-empty-object"))
        let none = await Support.service(empty).transitPlan(from: Support.origin, to: Support.dest)
        XCTAssertTrue(none.steps.isEmpty)
        XCTAssertEqual(none.failure, .noRoute)

        let good = RoutesTransportStub.answering(with: try Support.fixture("routes-transit-steps"))
        let plan = await Support.service(good).transitPlan(from: Support.origin, to: Support.dest)
        XCTAssertEqual(plan.steps.count, 3)
        XCTAssertEqual(plan.extraMinutes, 7)
        XCTAssertNil(plan.failure)
        XCTAssertEqual(good.requests.first.flatMap { $0.value(forHTTPHeaderField: "x-goog-fieldmask") },
                       transitPlanMask)

        let denied = RoutesTransportStub.answering(status: 403, with: try Support.fixture("routes-google-error-403"))
        let refused = await Support.service(denied).transitPlan(from: Support.origin, to: Support.dest)
        XCTAssertTrue(refused.steps.isEmpty)
        XCTAssertEqual(refused.failure, .notConfigured)
    }

    func testROUTES_WalkWarningsReachEstimate() async throws {
        let walk = RoutesTransportStub.answering(with: try Support.fixture("routes-walk-warnings"))
        let walked = await Support.service(walk).estimate(.walk, from: Support.origin, to: Support.dest)
        XCTAssertEqual(walked.warnings, ["WARNING-FIXTURE-1", "WARNING-FIXTURE-2"])
        XCTAssertEqual(walked.duration, 1200)
        let bicycle = RoutesTransportStub.answering(with: try Support.fixture("routes-bicycle-warnings"))
        let cycled = await Support.service(bicycle).estimate(.bicycle, from: Support.origin, to: Support.dest)
        XCTAssertEqual(cycled.warnings, ["WARNING-FIXTURE-3"])
        let drive = RoutesTransportStub.answering(with: try Support.fixture("routes-drive"))
        let driven = await Support.service(drive).estimate(.car, from: Support.origin, to: Support.dest)
        XCTAssertEqual(driven.warnings, [])
        XCTAssertEqual(driven.duration, 1053)
    }

    func testROUTES_DetailLookupPerMode() {
        XCTAssertEqual(DirectionsService.detailLookup(for: .transit), .transitPlan)
        XCTAssertEqual(DirectionsService.detailLookup(for: .walk), .estimateForWarnings)
        XCTAssertEqual(DirectionsService.detailLookup(for: .bicycle), .estimateForWarnings)
        XCTAssertEqual(DirectionsService.detailLookup(for: .car), .none)
    }

    // MARK: - LV live-request sync

    func testROUTES_LiveFixtureBodiesEqualAppBodies() throws {
        let cases: [(name: String, mode: TransportMode, mask: String, destination: CLLocationCoordinate2D)] = [
            ("transit", .transit, GoogleRoutes.transitPlanMask, Support.dest),
            ("walk", .walk, GoogleRoutes.mask(for: .walk), Support.dest),
            ("bicycle", .bicycle, GoogleRoutes.mask(for: .bicycle), Support.dest),
            ("noroute", .transit, GoogleRoutes.mask(for: .transit),
             CLLocationCoordinate2D(latitude: 21.3069, longitude: -157.8583))
        ]
        for item in cases {
            let request = try XCTUnwrap(GoogleRoutes.request(mode: item.mode, from: Support.origin, to: item.destination,
                                                             mask: item.mask, config: Support.config), item.name)
            let built = try XCTUnwrap(Support.body(of: request), item.name)
            let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: try Support.fixture("live-\(item.name)-body"))
                                         as? NSDictionary, item.name)
            XCTAssertTrue(built.isEqual(recorded), item.name)
            XCTAssertEqual(try Support.fixtureText("live-\(item.name)-mask"), item.mask, item.name)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-fieldmask"), item.mask, item.name)
        }
    }
}
