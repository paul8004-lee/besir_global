import Foundation
import CoreLocation

/// One point of a decoded route line. Not Codable: a line is never stored.
struct RoutePoint: Equatable {
    var latitude: Double
    var longitude: Double
}

/// Google Routes (`computeRoutes`) through the Worker route `/routes`.
/// Pure request builders and response parsers plus one transport seam, so tests need no network.
/// The Google key stays on the Worker; the app sends only its own token (through the one proxy request builder).
enum GoogleRoutes {
    /// Sends one request and returns the raw answer. The default calls the shared URL session; tests inject a stub.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let urlSession: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    static let fieldMaskHeader = "x-goog-fieldmask"

    static let estimateMask = "routes.duration,routes.distanceMeters"
    static let warningsMask = "routes.duration,routes.distanceMeters,routes.warnings"
    /// The mask of a live car lookup (a replan trigger): `staticDuration` is the route time without traffic conditions,
    /// so the answer carries both the time with traffic (`duration`) and the time without it.
    static let liveCarMask = "routes.duration,routes.staticDuration,routes.distanceMeters"
    /// The mask of a route-line lookup: the time and the overview polyline, nothing else.
    static let routeLineMask = "routes.duration,routes.polyline.encodedPolyline"
    /// The most points a decoded route line may hold; a longer text is refused.
    static let maxLinePoints = 5_000

    // @MX:NOTE Adding a field to this mask can move every transit lookup to a higher billing tier.
    static let transitPlanMask = [
        "routes.duration",
        "routes.distanceMeters",
        "routes.legs.steps.travelMode",
        "routes.legs.steps.staticDuration",
        "routes.legs.steps.transitDetails.stopDetails.departureStop.name",
        "routes.legs.steps.transitDetails.stopDetails.arrivalStop.name",
        "routes.legs.steps.transitDetails.transitLine.name",
        "routes.legs.steps.transitDetails.transitLine.nameShort",
        "routes.legs.steps.transitDetails.transitLine.color",
        "routes.legs.steps.transitDetails.transitLine.vehicle.type",
        "routes.legs.steps.transitDetails.stopCount"
    ].joined(separator: ",")

    private static let path = "/routes"
    private static let timeout: TimeInterval = 15
    private static let languageCode = "en-US"
    private static let regionCode = "US"

    static let walkColor = "#9aa0a6"
    static let busFallbackColor = "#3D5BAB"
    static let transitFallbackColor = "#3d5bf0"

    private static let busVehicleTypes: Set<String> = ["BUS", "INTERCITY_BUS", "TROLLEYBUS"]

    /// The failure kinds of one lookup. `noRoute` and `malformed` come from the parser, `http` from the transport.
    enum LookupError: Error, Equatable {
        case http(status: Int, code: String?)
        case noRoute
        case malformed
    }

    /// One leg step of a route; only the fields the transit mask asks for.
    struct Step: Equatable {
        var travelMode: String? = nil
        var staticDuration: TimeInterval? = nil
        var departureStop: String? = nil
        var arrivalStop: String? = nil
        var lineName: String? = nil
        var lineShortName: String? = nil
        var lineColor: String? = nil
        var vehicleType: String? = nil
        var stopCount: Int? = nil
    }

    /// The first route of an answer.
    struct Route: Equatable {
        var duration: TimeInterval
        var distance: Double? = nil
        var warnings: [String] = []
        var steps: [Step] = []
        /// The route time without traffic conditions; only a live car request asks for it.
        var staticDuration: TimeInterval? = nil
        /// The overview polyline text; only a route-line request asks for it.
        var encodedPolyline: String? = nil
    }

    // MARK: - Requests

    /// Field mask of an estimate lookup: walking and bicycling routes also carry Google's warnings.
    static func mask(for mode: TransportMode) -> String {
        switch mode {
        case .car, .transit: return estimateMask
        case .walk, .bicycle: return warningsMask
        }
    }

    /// One `computeRoutes` request for `mode`. The routing preference is valid for DRIVE only, so no other mode sends it.
    /// `live` is true only for the lookups of a replan trigger: a car request then asks for traffic (`TRAFFIC_AWARE`) and
    /// for `staticDuration`; every other request, and every request with `live == false`, is byte-identical to the base.
    /// `polyline` is true only for a route-line lookup: the body then also asks for the overview quality in the encoded
    /// polyline format, the field mask is `routeLineMask` whatever `mask` is passed, and the request is never live.
    /// Nil when the proxy is not configured.
    static func request(mode: TransportMode, from origin: CLLocationCoordinate2D, to dest: CLLocationCoordinate2D,
                        mask: String, config: AppConfig, live: Bool = false, polyline: Bool = false) -> URLRequest? {
        var body: [String: Any] = [
            "origin": waypoint(origin),
            "destination": waypoint(dest),
            "travelMode": travelMode(for: mode),
            "languageCode": languageCode,
            "regionCode": regionCode
        ]
        if polyline {
            body["polylineEncoding"] = "ENCODED_POLYLINE"
            body["polylineQuality"] = "OVERVIEW"
        }
        let liveCar = live && !polyline && mode == .car
        if mode == .car { body["routingPreference"] = liveCar ? "TRAFFIC_AWARE" : "TRAFFIC_UNAWARE" }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              var request = config.proxyPOSTRequest(path, body: data, timeout: timeout) else { return nil }
        request.setValue(polyline ? routeLineMask : (liveCar ? liveCarMask : mask), forHTTPHeaderField: fieldMaskHeader)
        return request
    }

    private static func travelMode(for mode: TransportMode) -> String {
        switch mode {
        case .car: return "DRIVE"
        case .transit: return "TRANSIT"
        case .walk: return "WALK"
        case .bicycle: return "BICYCLE"
        }
    }

    private static func waypoint(_ point: CLLocationCoordinate2D) -> [String: Any] {
        ["location": ["latLng": ["latitude": point.latitude, "longitude": point.longitude]]]
    }

    // MARK: - Route line

    // @MX:NOTE The single decoder of Google's encoded polylines. Every check is deliberate: byte alphabet, at most 13
    // groups per number, a 13th payload of 15 or less (a bigger one loses its top bit in 64 bits), a checked add,
    // coordinate limits in integer units, at most `maxLinePoints` points and at least 2.
    /// The points of an encoded polyline (units of 1e-5 degree), or nil for any text that is not a valid line:
    /// a byte outside 63...126, a text that ends inside a number or after a latitude, a number of more than 13 groups
    /// or whose 13th group has a payload above 15, an overflowing sum, a coordinate out of range, more than
    /// `maxLinePoints` points, or fewer than 2.
    static func decodePolyline(_ text: String) -> [RoutePoint]? {
        let bytes = Array(text.utf8)
        var index = 0
        var latitude: Int64 = 0
        var longitude: Int64 = 0
        var points: [RoutePoint] = []
        while index < bytes.count {
            for component in 0..<2 {
                guard index < bytes.count else { return nil }
                var n: UInt64 = 0
                var groups = 0
                var more = true
                while more {
                    guard index < bytes.count else { return nil }
                    let byte = bytes[index]
                    guard byte >= 63 else { return nil }
                    guard byte <= 126 else { return nil }
                    index += 1
                    let value = Int(byte) - 63
                    groups += 1
                    if groups > 13 { return nil }
                    if groups == 13 && (value & 31) > 15 { return nil }
                    n |= UInt64(value & 31) << UInt64(5 * (groups - 1))
                    more = value >= 32
                }
                let step = (n & 1) != 0 ? ~Int64(bitPattern: n >> 1) : Int64(bitPattern: n >> 1)
                let (sum, overflow) = (component == 0 ? latitude : longitude).addingReportingOverflow(step)
                guard !overflow else { return nil }
                if component == 0 { latitude = sum } else { longitude = sum }
            }
            guard latitude >= -9_000_000 && latitude <= 9_000_000 else { return nil }
            guard longitude >= -18_000_000 && longitude <= 18_000_000 else { return nil }
            points.append(RoutePoint(latitude: Double(latitude) / 100_000, longitude: Double(longitude) / 100_000))
            if points.count > maxLinePoints { return nil }
        }
        guard points.count >= 2 else { return nil }
        return points
    }

    // MARK: - Transport

    /// The answer body when the Worker answered 200. Any other status (or a non-HTTP answer) throws
    /// `LookupError.http` with the error code of the body; a thrown transport error propagates.
    static func fetch(_ request: URLRequest, transport: Transport) async throws -> Data {
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw LookupError.http(status: 0, code: nil) }
        guard http.statusCode == 200 else {
            throw LookupError.http(status: http.statusCode, code: errorCode(from: data))
        }
        return data
    }

    // MARK: - Parsing

    // @MX:NOTE The single parser of Google's duration strings ("1053s", "3.5s"); no other code reads them.
    /// Seconds from a duration string of ASCII digits with an optional fraction and a final `s`; nil for anything else.
    static func parseDuration(_ text: String) -> TimeInterval? {
        guard text.hasSuffix("s") else { return nil }
        let number = text.dropLast()
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } })
        else { return nil }
        return Double(number)
    }

    /// The first route of a 200 answer. A missing, null or empty `routes` is `noRoute`; an undecodable body, a `routes`
    /// of another type or a first route without a valid `duration` is `malformed`.
    static func parse(_ data: Data) throws -> Route {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LookupError.malformed
        }
        guard let rawRoutes = object["routes"], !(rawRoutes is NSNull) else { throw LookupError.noRoute }
        guard let routes = rawRoutes as? [Any] else { throw LookupError.malformed }
        guard let first = routes.first else { throw LookupError.noRoute }
        guard let route = first as? [String: Any], let text = route["duration"] as? String,
              let duration = parseDuration(text) else { throw LookupError.malformed }
        let warnings = (route["warnings"] as? [Any])?.compactMap { $0 as? String } ?? []
        let legs = (route["legs"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let steps = legs.flatMap { leg in
            ((leg["steps"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []).map(step(from:))
        }
        // A missing, null or invalid `staticDuration` is nil; it never makes the route malformed.
        let staticDuration = (route["staticDuration"] as? String).flatMap(parseDuration)
        // A missing, null, empty or non-text polyline is nil; it never makes the route malformed.
        let polylineText = (route["polyline"] as? [String: Any])?["encodedPolyline"] as? String
        let encodedPolyline = (polylineText?.isEmpty ?? true) ? nil : polylineText
        return Route(duration: duration, distance: number(route["distanceMeters"]), warnings: warnings, steps: steps,
                     staticDuration: staticDuration, encodedPolyline: encodedPolyline)
    }

    private static func step(from raw: [String: Any]) -> Step {
        let details = raw["transitDetails"] as? [String: Any]
        let stops = details?["stopDetails"] as? [String: Any]
        let line = details?["transitLine"] as? [String: Any]
        let vehicle = line?["vehicle"] as? [String: Any]
        return Step(travelMode: raw["travelMode"] as? String,
                    staticDuration: (raw["staticDuration"] as? String).flatMap(parseDuration),
                    departureStop: (stops?["departureStop"] as? [String: Any])?["name"] as? String,
                    arrivalStop: (stops?["arrivalStop"] as? [String: Any])?["name"] as? String,
                    lineName: line?["name"] as? String,
                    lineShortName: line?["nameShort"] as? String,
                    lineColor: line?["color"] as? String,
                    vehicleType: vehicle?["type"] as? String,
                    stopCount: number(details?["stopCount"]).map { Int($0) })
    }

    /// A JSON number as a double; strings and booleans are not numbers here.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// One code from an error body in either shape: the Worker's `{"error":"<string>"}` as is; Google's
    /// `{"error":{"code","message","status"}}` as the first `details[].reason` beginning `API_KEY_` (it takes
    /// priority over the status), else the `status`, else `HTTP_<code>`. Nil for anything else.
    static func errorCode(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let worker = object["error"] as? String { return worker.isEmpty ? nil : worker }
        guard let error = object["error"] as? [String: Any] else { return nil }
        for detail in (error["details"] as? [Any]) ?? [] {
            if let reason = (detail as? [String: Any])?["reason"] as? String, reason.hasPrefix("API_KEY_") {
                return reason
            }
        }
        if let status = error["status"] as? String, !status.isEmpty { return status }
        if let code = number(error["code"]) { return "HTTP_\(Int(code))" }
        return nil
    }

    /// The failure a lookup error stands for; nil for a cancelled task.
    static func failure(for error: Error, hasProxy: Bool) -> TravelFailure? {
        let urlError = error as? URLError
        var code: String?
        var status: Int?
        switch error {
        case LookupError.noRoute:
            return .noRoute
        case let LookupError.http(httpStatus, httpCode):
            status = httpStatus
            code = httpCode
        default:
            break
        }
        return TravelFailure.classify(
            hasProxy: hasProxy,
            urlErrorCode: urlError?.code,
            bodyErrorCode: code,
            isCancellation: error is CancellationError || urlError?.code == .cancelled,
            httpStatus: status)
    }

    // MARK: - Transit steps

    /// Walk and transit steps in English from the first route, plus the minutes the steps do not explain.
    /// A step minute is the rounded `staticDuration` (a missing one counts 0, never invented); the extra minutes are the
    /// rounded total minus the sum of the step minutes, present only when at least 1, so that the steps plus the extra
    /// always equal the total. Google splits a walk into many small steps, so consecutive WALK steps are summed in seconds
    /// and rounded once into one walk step (omitted when that is 0 minutes); a TRANSIT step ends a run of walking.
    static func transitSteps(from route: Route) -> (steps: [TransitStep], extraMinutes: Int?) {
        var steps: [TransitStep] = []
        var lastEnd = "Start"
        var walkSeconds: TimeInterval = 0
        var isWalking = false
        func flushWalk(to: String) {
            defer { walkSeconds = 0; isWalking = false }
            guard isWalking else { return }
            let minutes = roundedMinutes(fromSeconds: walkSeconds)
            if minutes <= 0 { return }
            steps.append(TransitStep(kind: .walk, line: "", from: lastEnd, to: to,
                                     minutes: minutes, stationCount: nil, color: walkColor))
        }
        for raw in route.steps {
            let minutes = roundedMinutes(fromSeconds: raw.staticDuration ?? 0)
            switch raw.travelMode {
            case "WALK":
                walkSeconds += raw.staticDuration ?? 0
                isWalking = true
            case "TRANSIT":
                // The end of a walk is the next boarding stop, not the stop the walk passes.
                flushWalk(to: text(raw.departureStop) ?? "Destination")
                let isBus = raw.vehicleType.map(busVehicleTypes.contains) ?? false
                let from = text(raw.departureStop) ?? lastEnd
                let to = text(raw.arrivalStop) ?? "Get off"
                let line = text(raw.lineShortName) ?? text(raw.lineName) ?? (isBus ? "route" : "transit")
                steps.append(TransitStep(kind: isBus ? .bus : .subway, line: line, from: from, to: to,
                                         minutes: minutes, stationCount: raw.stopCount,
                                         color: lineColor(raw.lineColor, isBus: isBus)))
                lastEnd = to
            default:
                continue
            }
        }
        flushWalk(to: "Destination")
        let extra = roundedMinutes(fromSeconds: route.duration) - steps.reduce(0) { $0 + $1.minutes }
        return (steps, extra >= 1 ? extra : nil)
    }

    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Google's line colour when it is `#` and six hexadecimal digits, else a neutral colour of the vehicle kind.
    private static func lineColor(_ value: String?, isBus: Bool) -> String {
        if let value, value.unicodeScalars.count == 7, value.hasPrefix("#"),
           value.unicodeScalars.dropFirst().allSatisfy({ $0.isASCII && Character($0).isHexDigit }) {
            return value
        }
        return isBus ? busFallbackColor : transitFallbackColor
    }
}
