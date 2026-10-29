import CoreLocation
#if canImport(GoogleMaps)
import GoogleMaps
#endif

/// Whether the Maps SDK has been given its key.
enum MapKeyState: Equatable { case ready, unavailable }

/// Reads the Maps key from the Info dictionary and hands it to the SDK exactly once,
/// just before the first map view is created. The SDK call is injected so the rule can be tested
/// without the SDK, a key or the network.
final class GoogleMapsSetup {
    static let infoKey = "BesirMapsKey"

    /// The trimmed key, or nil when it is missing, blank, not text, or still an unexpanded `$(…)` build value.
    static func key(from info: [String: Any]?) -> String? {
        guard let raw = info?[infoKey] as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty || key.hasPrefix("$(") { return nil }
        return key
    }

    private let key: String?
    private let provide: (String) -> Void
    private let lock = NSLock()
    private var provided = false

    init(info: [String: Any]?, provide: @escaping (String) -> Void) {
        self.key = Self.key(from: info)
        self.provide = provide
    }

    /// True when the build supplied a usable key. Pure, so it is safe to read in a view body.
    var isConfigured: Bool { key != nil }

    /// Gives the key to the SDK on the first call that has one; later calls do nothing.
    /// Without a key the SDK is never called.
    func start() -> MapKeyState {
        guard let key else { return .unavailable }
        lock.lock()
        defer { lock.unlock() }
        if !provided {
            provided = true
            provide(key)
        }
        return .ready
    }

    #if canImport(GoogleMaps)
    static let shared = GoogleMapsSetup(info: Bundle.main.infoDictionary) { GMSServices.provideAPIKey($0) }
    #endif
}

/// Where the camera should be for a pair of coordinates. A coordinate that is not a number or lies
/// outside the latitude and longitude range counts as absent. A route line (`path`) that `RouteLineSpec` accepts widens
/// the frame to hold every one of its points; without a line the frame is the one of the two coordinates alone.
enum MapFraming: Equatable {
    case bounds(south: Double, west: Double, north: Double, east: Double)
    case point(latitude: Double, longitude: Double, zoom: Float)

    static let streetZoom: Float = 15
    static let defaultPoint = MapFraming.point(latitude: 37.7749, longitude: -122.4194, zoom: 12)

    static func isValid(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude.isFinite && c.longitude.isFinite && abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }

    static func plan(origin: CLLocationCoordinate2D?, destination: CLLocationCoordinate2D?,
                     path: [RoutePoint] = []) -> MapFraming {
        let o = origin.flatMap { isValid($0) ? $0 : nil }
        let d = destination.flatMap { isValid($0) ? $0 : nil }
        // The line counts only when `RouteLineSpec` accepts it whole; an invalid point drops the whole path.
        let line = RouteLineSpec.make(path)?.points ?? []
        var all = [o, d].compactMap { $0 }.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        all += line
        guard let first = all.first else { return defaultPoint }
        var south = first.latitude
        var north = first.latitude
        var west = first.longitude
        var east = first.longitude
        for point in all {
            south = min(south, point.latitude)
            north = max(north, point.latitude)
            west = min(west, point.longitude)
            east = max(east, point.longitude)
        }
        if south == north && west == east { return .point(latitude: south, longitude: west, zoom: streetZoom) }
        return .bounds(south: south, west: west, north: north, east: east)
    }
}

/// The route line the map draws, as plain values so two lines can be compared before the map is touched. It is the one
/// rule for "is this a line": the drawing and the camera frame both start from `make`.
struct RouteLineSpec: Equatable {
    let points: [RoutePoint]
    /// The one place the line width is set; all four travel modes share it.
    static let width: Double = 5

    /// Nil when fewer than 2 points or when any point is not a valid coordinate: one bad point drops the whole line.
    static func make(_ points: [RoutePoint]) -> RouteLineSpec? {
        guard points.count >= 2 else { return nil }
        let everyPointValid = points.allSatisfy { MapFraming.isValid(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        guard everyPointValid else { return nil }
        return RouteLineSpec(points: points)
    }

    /// Whether the drawn line must be taken off and drawn again: a line appeared, went, or changed its points, or the
    /// colour scheme changed while a line is on the map.
    static func needsRedraw(last: RouteLineSpec?, next: RouteLineSpec?, colourSchemeChanged: Bool) -> Bool {
        guard let next else { return last != nil }
        guard let last else { return true }
        if last.points != next.points { return true }
        return colourSchemeChanged
    }
}

/// How far the camera fit keeps the markers from each edge so the destination's name label
/// (the SDK's info window above the pin) stays inside the map.
struct MapFitInsets: Equatable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat

    static let base: CGFloat = 48
    /// Pin height + info window + its pointer + a margin, measured on the iPhone 17 Pro walk.
    static let labelClearanceAbove: CGFloat = 85
    static let labelSideMargin: CGFloat = 8
    /// Opposite sides together may take at most this share of the map, so a fit area always remains.
    static let maxShare: CGFloat = 0.6

    static func make(labelWidth: CGFloat, mapWidth: CGFloat, mapHeight: CGFloat) -> MapFitInsets {
        guard mapWidth > 0, mapHeight > 0 else {
            return MapFitInsets(top: base, left: base, bottom: base, right: base)
        }
        let side = min(max(base, labelWidth / 2 + labelSideMargin), mapWidth * maxShare / 2)
        let bottom = min(base, mapHeight * maxShare / 2)
        let top = min(max(base, labelClearanceAbove), mapHeight * maxShare - bottom)
        return MapFitInsets(top: top, left: side, bottom: bottom, right: side)
    }
}

/// When the destination's name label is put back after a change of appearance: a window of seconds in which
/// timers and the end of tile rendering select the destination marker again.
enum LabelReassert {
    static let window: TimeInterval = 3
    static let delays: [TimeInterval] = [0.4, 1.2, 2.5]

    static func until(from start: Date) -> Date { start.addingTimeInterval(window) }
    static func isActive(now: Date, until: Date) -> Bool { now < until }
}

/// One marker the map shows, as plain values so the list can be compared before the map is touched.
struct MapMarkerSpec: Equatable {
    enum Role { case origin, destination }
    let role: Role
    let latitude: Double
    let longitude: Double
    let title: String

    static func markers(origin: CLLocationCoordinate2D?, destination: CLLocationCoordinate2D?, destinationName: String) -> [MapMarkerSpec] {
        var list: [MapMarkerSpec] = []
        if let o = origin, MapFraming.isValid(o) {
            list.append(MapMarkerSpec(role: .origin, latitude: o.latitude, longitude: o.longitude, title: "Origin"))
        }
        if let d = destination, MapFraming.isValid(d) {
            let name = destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
            list.append(MapMarkerSpec(role: .destination, latitude: d.latitude, longitude: d.longitude,
                                      title: name.isEmpty ? "Destination" : name))
        }
        return list
    }
}
