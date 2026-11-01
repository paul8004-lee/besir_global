import Foundation

/// Place photos through the Worker route `/place-photo`.
/// The request goes through the configuration's one proxy request builder, so the app sends only its own token.
/// Nothing is recorded, written or cached here: the caller keeps the bytes in its own view state.
enum PlacePhotos {
    static let maxWidth = 800
    static let maxBytes = 5_000_000

    private static let path = "/place-photo"
    private static let timeout: TimeInterval = 20

    /// An ephemeral session with no URL cache, so no photo reaches the disk. The default transport of `fetch` callers.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static let ephemeral: GooglePlaces.Transport = { request in
        try await session.data(for: request)
    }

    /// `POST /place-photo` with the photo's resource name and the width. Nil when the proxy is not configured.
    static func request(name: String, config: AppConfig) -> URLRequest? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["name": name, "max_width": maxWidth],
                                                     options: [.sortedKeys]) else { return nil }
        return config.proxyPOSTRequest(path, body: body, timeout: timeout)
    }

    /// The image bytes when the Worker answered 200 with an `image/` content type and 1 to `maxBytes` bytes;
    /// nil for anything else, a thrown error or a cancelled task.
    static func fetch(_ request: URLRequest, transport: GooglePlaces.Transport) async -> Data? {
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let type = http.value(forHTTPHeaderField: "Content-Type"),
                  type.lowercased().hasPrefix("image/"),
                  (1...maxBytes).contains(data.count) else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
