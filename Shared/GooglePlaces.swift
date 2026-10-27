import Foundation
import CoreLocation

/// Google Places (New) Text Search through the Worker route `/places`.
/// Pure request builders and response parsers plus one transport seam, so tests need no network.
/// STUB for the recorded RED run: signatures only, every body returns empty.
enum GooglePlaces {
    /// Sends one request and returns the raw answer. The default calls the shared URL session; tests inject a stub.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let urlSession: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    static let fieldMask = ""
    static let fieldMaskHeader = "x-goog-fieldmask"

    static func searchRequest(query: String, near center: CLLocationCoordinate2D?, config: AppConfig) -> URLRequest? {
        nil
    }

    static func nearbyRequest(category: MealCategoryFilter?, keyword: String?, near center: CLLocationCoordinate2D,
                              radiusMeters: Int, config: AppConfig) -> URLRequest? {
        nil
    }

    static func fetch(_ request: URLRequest, transport: Transport) async -> Data? {
        nil
    }

    static func parsePlaces(_ data: Data) -> [Place] {
        []
    }

    static func nearbyResults(from data: Data, near center: CLLocationCoordinate2D, radiusMeters: Int,
                              sort: NearbySort, limit: Int) -> [NearbyPlace] {
        []
    }
}
