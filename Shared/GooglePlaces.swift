import Foundation
import CoreLocation

/// Google Places (New) Text Search through the Worker route `/places`.
/// Pure request builders and response parsers plus one transport seam, so tests need no network.
/// The Google key stays on the Worker; the app sends only its own token (through the one proxy request builder).
enum GooglePlaces {
    /// Sends one request and returns the raw answer. The default calls the shared URL session; tests inject a stub.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let urlSession: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    // @MX:NOTE Adding a phone-number field here would move every call to the Enterprise billing tier.
    static let fieldMask = "places.id,places.displayName,places.formattedAddress,places.location,places.primaryTypeDisplayName,places.googleMapsUri"
    static let fieldMaskHeader = "x-goog-fieldmask"

    private static let path = "/places"
    private static let timeout: TimeInterval = 10
    private static let languageCode = "en"
    private static let regionCode = "US"
    private static let searchPageSize = 10
    private static let nearbyPageSize = 20
    private static let searchBiasRadius = 50_000
    private static let minRadius = 100
    private static let maxRadius = 50_000
    private static let minLimit = 1
    private static let maxLimit = 20

    // MARK: - Requests

    /// Typed search: the trimmed query, a bias circle around `center` when one is given, no bias otherwise.
    /// Nil when the proxy is not configured.
    static func searchRequest(query: String, near center: CLLocationCoordinate2D?, config: AppConfig) -> URLRequest? {
        var body: [String: Any] = [
            "textQuery": query.trimmingCharacters(in: .whitespacesAndNewlines),
            "languageCode": languageCode,
            "regionCode": regionCode,
            "pageSize": searchPageSize
        ]
        if let center { body["locationBias"] = biasCircle(center: center, radius: searchBiasRadius) }
        return request(body: body, config: config)
    }

    /// Nearby search: the keyword, else the category word, else "restaurants"; the radius is clamped to 100...50000.
    /// Nil when the proxy is not configured.
    static func nearbyRequest(category: MealCategoryFilter?, keyword: String?, near center: CLLocationCoordinate2D,
                              radiusMeters: Int, config: AppConfig) -> URLRequest? {
        let term = keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var body: [String: Any] = [
            "textQuery": term.isEmpty ? (category?.categoryWord ?? "restaurants") : term,
            "languageCode": languageCode,
            "regionCode": regionCode,
            "pageSize": nearbyPageSize,
            "locationBias": biasCircle(center: center, radius: clampedRadius(radiusMeters))
        ]
        if let category { body["includedType"] = category.includedType }
        return request(body: body, config: config)
    }

    static func clampedRadius(_ radiusMeters: Int) -> Int {
        min(max(radiusMeters, minRadius), maxRadius)
    }

    static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, minLimit), maxLimit)
    }

    private static func biasCircle(center: CLLocationCoordinate2D, radius: Int) -> [String: Any] {
        ["circle": ["center": ["latitude": center.latitude, "longitude": center.longitude], "radius": radius]]
    }

    private static func request(body: [String: Any], config: AppConfig) -> URLRequest? {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              var request = config.proxyPOSTRequest(path, body: data, timeout: timeout) else { return nil }
        request.setValue(fieldMask, forHTTPHeaderField: fieldMaskHeader)
        return request
    }

    // MARK: - Transport

    /// The answer body when the Worker answered 200; nil for any other status, a non-HTTP answer, a thrown error
    /// or a cancelled task.
    static func fetch(_ request: URLRequest, transport: Transport) async -> Data? {
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Parsing

    /// Google's order; results without a display name or a valid location are dropped.
    static func parsePlaces(_ data: Data) -> [Place] {
        rawPlaces(data).compactMap(place(from:))
    }

    /// Parses like `parsePlaces`, drops results beyond the clamped radius, orders by distance for `.distance`
    /// (Google's order for `.accuracy`), keeps at most the clamped `limit` and fills the distance in whole metres.
    static func nearbyResults(from data: Data, near center: CLLocationCoordinate2D, radiusMeters: Int,
                              sort: NearbySort, limit: Int) -> [NearbyPlace] {
        let radius = Double(clampedRadius(radiusMeters))
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        var found: [(distance: Double, item: NearbyPlace)] = []
        for raw in rawPlaces(data) {
            guard let place = place(from: raw) else { continue }
            let distance = CLLocation(latitude: place.latitude, longitude: place.longitude).distance(from: origin)
            guard distance <= radius else { continue }
            found.append((distance, NearbyPlace(place: place,
                                                category: raw.primaryTypeDisplayName?.text ?? "",
                                                distanceMeters: Int(distance.rounded()),
                                                phone: nil,
                                                url: raw.googleMapsUri)))
        }
        if sort == .distance {
            found = found.enumerated().sorted { lhs, rhs in
                lhs.element.distance != rhs.element.distance
                    ? lhs.element.distance < rhs.element.distance
                    : lhs.offset < rhs.offset
            }.map(\.element)
        }
        return found.prefix(clampedLimit(limit)).map(\.item)
    }

    private static func place(from raw: Raw) -> Place? {
        guard let name = raw.displayName?.text,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let latitude = raw.location?.latitude, let longitude = raw.location?.longitude,
              (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else { return nil }
        return Place(name: name, address: raw.formattedAddress ?? "", latitude: latitude, longitude: longitude)
    }

    private static func rawPlaces(_ data: Data) -> [Raw] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        return envelope.places.compactMap(\.value)
    }

    /// One bad element must not discard the others, so every element decodes on its own.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct Envelope: Decodable {
        let places: [Lossy<Raw>]
        private enum Keys: String, CodingKey { case places }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            places = (try? container.decode([Lossy<Raw>].self, forKey: .places)) ?? []
        }
    }

    private struct Raw: Decodable {
        struct Words: Decodable {
            let text: String?
            private enum Keys: String, CodingKey { case text }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                text = try? container.decode(String.self, forKey: .text)
            }
        }
        struct Spot: Decodable {
            let latitude: Double?
            let longitude: Double?
            private enum Keys: String, CodingKey { case latitude, longitude }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                latitude = try? container.decode(Double.self, forKey: .latitude)
                longitude = try? container.decode(Double.self, forKey: .longitude)
            }
        }
        let displayName: Words?
        let formattedAddress: String?
        let location: Spot?
        let primaryTypeDisplayName: Words?
        let googleMapsUri: String?
        private enum Keys: String, CodingKey {
            case displayName, formattedAddress, location, primaryTypeDisplayName, googleMapsUri
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            displayName = try? container.decode(Words.self, forKey: .displayName)
            formattedAddress = try? container.decode(String.self, forKey: .formattedAddress)
            location = try? container.decode(Spot.self, forKey: .location)
            primaryTypeDisplayName = try? container.decode(Words.self, forKey: .primaryTypeDisplayName)
            googleMapsUri = try? container.decode(String.self, forKey: .googleMapsUri)
        }
    }
}
