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
/// outside the latitude and longitude range counts as absent.
enum MapFraming: Equatable {
    case bounds(south: Double, west: Double, north: Double, east: Double)
    case point(latitude: Double, longitude: Double, zoom: Float)

    static let streetZoom: Float = 15
    static let defaultPoint = MapFraming.point(latitude: 37.7749, longitude: -122.4194, zoom: 12)

    static func isValid(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude.isFinite && c.longitude.isFinite && abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }

    static func plan(origin: CLLocationCoordinate2D?, destination: CLLocationCoordinate2D?) -> MapFraming {
        let o = origin.flatMap { isValid($0) ? $0 : nil }
        let d = destination.flatMap { isValid($0) ? $0 : nil }
        switch (o, d) {
        case let (o?, d?):
            if o.latitude == d.latitude && o.longitude == d.longitude {
                return .point(latitude: o.latitude, longitude: o.longitude, zoom: streetZoom)
            }
            return .bounds(south: min(o.latitude, d.latitude), west: min(o.longitude, d.longitude),
                           north: max(o.latitude, d.latitude), east: max(o.longitude, d.longitude))
        case let (o?, nil):
            return .point(latitude: o.latitude, longitude: o.longitude, zoom: streetZoom)
        case let (nil, d?):
            return .point(latitude: d.latitude, longitude: d.longitude, zoom: streetZoom)
        case (nil, nil):
            return defaultPoint
        }
    }
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
