import CoreLocation

// Stub for the first failing run of card t13 (M1): every body returns a fixed wrong value.

enum MapKeyState: Equatable { case ready, unavailable }

final class GoogleMapsSetup {
    static func key(from info: [String: Any]?) -> String? { "stub" }

    init(info: [String: Any]?, provide: @escaping (String) -> Void) {}

    var isConfigured: Bool { true }

    func start() -> MapKeyState { .unavailable }
}

enum MapFraming: Equatable {
    case bounds(south: Double, west: Double, north: Double, east: Double)
    case point(latitude: Double, longitude: Double, zoom: Float)

    static func isValid(_ c: CLLocationCoordinate2D) -> Bool { true }

    static func plan(origin: CLLocationCoordinate2D?, destination: CLLocationCoordinate2D?) -> MapFraming {
        .point(latitude: 0, longitude: 0, zoom: 1)
    }
}

struct MapMarkerSpec: Equatable {
    enum Role { case origin, destination }
    let role: Role
    let latitude: Double
    let longitude: Double
    let title: String

    static func markers(origin: CLLocationCoordinate2D?, destination: CLLocationCoordinate2D?, destinationName: String) -> [MapMarkerSpec] {
        []
    }
}
