import Foundation

/// Place photos through the Worker route `/place-photo`.
/// The request goes through the configuration's one proxy request builder, so the app sends only its own token.
enum PlacePhotos {
    static let maxWidth = 800
    static let maxBytes = 5_000_000

    static func request(name: String, config: AppConfig) -> URLRequest? {
        nil
    }

    static func fetch(_ request: URLRequest, transport: GooglePlaces.Transport) async -> Data? {
        nil
    }
}
