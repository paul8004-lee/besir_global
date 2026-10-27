import XCTest
import CoreLocation
@testable import besir

/// Anchor class so the fixtures are found through the test bundle.
final class PlacesBundleToken {}

/// Shared helpers of the place-search tests (SPEC-PLACES-001). Nothing here touches the network.
enum PlacesTestSupport {
    static let host = "places-host.invalid"
    static let token = "places-token-0001"
    static let config = AppConfig(kakaoJsKey: "", proxyBaseURL: "https://" + host, appToken: token)
    static let center = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

    static func fixture(_ name: String, ext: String = "json") throws -> Data {
        let url = try XCTUnwrap(Bundle(for: PlacesBundleToken.self).url(forResource: name, withExtension: ext),
                                "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    /// The request body decoded to a dictionary, so key order never matters.
    static func body(of request: URLRequest) -> NSDictionary? {
        guard let data = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? NSDictionary
    }

    static func keys(of dictionary: NSDictionary?) -> Set<String> {
        Set((dictionary?.allKeys ?? []).compactMap { $0 as? String })
    }

    /// The bias circle of a body: centre and radius.
    static func circle(of body: NSDictionary) -> (latitude: Double, longitude: Double, radius: Double)? {
        guard let bias = body["locationBias"] as? NSDictionary,
              let circle = bias["circle"] as? NSDictionary,
              let center = circle["center"] as? NSDictionary,
              let latitude = (center["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (center["longitude"] as? NSNumber)?.doubleValue,
              let radius = (circle["radius"] as? NSNumber)?.doubleValue else { return nil }
        return (latitude, longitude, radius)
    }

    /// A point `meters` due north of `origin` whose geodesic distance is that value (to well under a millimetre).
    static func point(north meters: Double, of origin: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let from = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        var latitude = origin.latitude + meters / 111_000
        for _ in 0..<8 {
            let actual = CLLocation(latitude: latitude, longitude: origin.longitude).distance(from: from)
            latitude += (meters - actual) / 111_000
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: origin.longitude)
    }

    /// A Google-shaped answer holding one place per item, `meters` due north of the centre.
    static func nearbyAnswer(_ items: [(name: String, meters: Double)]) -> Data {
        let places: [[String: Any]] = items.map { item in
            let p = point(north: item.meters, of: center)
            return [
                "displayName": ["text": item.name],
                "formattedAddress": "\(item.name) address",
                "location": ["latitude": p.latitude, "longitude": p.longitude],
                "primaryTypeDisplayName": ["text": "Example type"],
                "googleMapsUri": "https://maps.example.invalid/\(item.name)"
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: ["places": places])) ?? Data()
    }
}

/// A transport that answers from a closure and records every request it receives.
final class PlacesTransportStub: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, URLResponse)

    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Answers every request with the given status and body.
    static func answering(status: Int = 200, with data: Data) -> PlacesTransportStub {
        PlacesTransportStub { request in (data, httpResponse(status: status, for: request)) }
    }

    static func httpResponse(status: Int, for request: URLRequest) -> URLResponse {
        let url = request.url ?? URL(fileURLWithPath: "/")
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
            ?? URLResponse()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var callCount: Int { requests.count }

    var transport: GooglePlaces.Transport {
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

/// SPEC-PLACES-001: request contract (RQ), parsing (PR), failure contract (FL) and live-body sync (LV).
final class GooglePlacesTests: XCTestCase {
    private typealias Support = PlacesTestSupport

    private let mask = "places.id,places.displayName,places.formattedAddress,places.location,places.primaryTypeDisplayName,places.googleMapsUri"

    // MARK: - RQ request contract

    func testPLACES_SearchBodyWithBias() throws {
        let request = try XCTUnwrap(GooglePlaces.searchRequest(query: "  blue bottle \n", near: Support.center,
                                                               config: Support.config))
        let body = try XCTUnwrap(Support.body(of: request))
        XCTAssertEqual(Support.keys(of: body), ["textQuery", "pageSize", "languageCode", "regionCode", "locationBias"])
        XCTAssertEqual(body["textQuery"] as? String, "blue bottle")
        XCTAssertEqual((body["pageSize"] as? NSNumber)?.intValue, 10)
        XCTAssertEqual(body["languageCode"] as? String, "en")
        XCTAssertEqual(body["regionCode"] as? String, "US")
        XCTAssertEqual(Support.keys(of: body["locationBias"] as? NSDictionary), ["circle"])
        let circle = try XCTUnwrap(Support.circle(of: body))
        XCTAssertEqual(circle.latitude, 37.7749, accuracy: 1e-9)
        XCTAssertEqual(circle.longitude, -122.4194, accuracy: 1e-9)
        XCTAssertEqual(circle.radius, 50_000, accuracy: 1e-9)
    }

    func testPLACES_SearchBodyWithoutBias() throws {
        let request = try XCTUnwrap(GooglePlaces.searchRequest(query: "blue bottle", near: nil, config: Support.config))
        let body = try XCTUnwrap(Support.body(of: request))
        XCTAssertEqual(Support.keys(of: body), ["textQuery", "pageSize", "languageCode", "regionCode"])
        XCTAssertEqual(body["textQuery"] as? String, "blue bottle")
        XCTAssertEqual((body["pageSize"] as? NSNumber)?.intValue, 10)
        XCTAssertNil(body["locationBias"])
        XCTAssertNil(body["locationRestriction"])
    }

    func testPLACES_NearbyBodyCafe() throws {
        let request = try XCTUnwrap(GooglePlaces.nearbyRequest(category: .cafe, keyword: nil, near: Support.center,
                                                               radiusMeters: 1000, config: Support.config))
        let body = try XCTUnwrap(Support.body(of: request))
        XCTAssertEqual(Support.keys(of: body),
                       ["textQuery", "includedType", "languageCode", "regionCode", "pageSize", "locationBias"])
        XCTAssertEqual(body["textQuery"] as? String, "cafes")
        XCTAssertEqual(body["includedType"] as? String, "cafe")
        XCTAssertEqual(body["languageCode"] as? String, "en")
        XCTAssertEqual(body["regionCode"] as? String, "US")
        XCTAssertEqual((body["pageSize"] as? NSNumber)?.intValue, 20)
        let circle = try XCTUnwrap(Support.circle(of: body))
        XCTAssertEqual(circle.latitude, 37.7749, accuracy: 1e-9)
        XCTAssertEqual(circle.longitude, -122.4194, accuracy: 1e-9)
        XCTAssertEqual(circle.radius, 1000, accuracy: 1e-9)
    }

    func testPLACES_NearbyBodyRestaurantEmptyKeyword() throws {
        let request = try XCTUnwrap(GooglePlaces.nearbyRequest(category: .restaurant, keyword: "  ", near: Support.center,
                                                               radiusMeters: 1000, config: Support.config))
        let body = try XCTUnwrap(Support.body(of: request))
        XCTAssertEqual(body["textQuery"] as? String, "restaurants")
        XCTAssertEqual(body["includedType"] as? String, "restaurant")
    }

    func testPLACES_NearbyBodyKeywordWithCategory() throws {
        let request = try XCTUnwrap(GooglePlaces.nearbyRequest(category: .restaurant, keyword: " Sushi ",
                                                               near: Support.center, radiusMeters: 1000,
                                                               config: Support.config))
        let body = try XCTUnwrap(Support.body(of: request))
        XCTAssertEqual(body["textQuery"] as? String, "Sushi")
        XCTAssertEqual(body["includedType"] as? String, "restaurant")
    }

    func testPLACES_NearbyBodyNoCategoryNoKeyword() throws {
        let request = try XCTUnwrap(GooglePlaces.nearbyRequest(category: nil, keyword: nil, near: Support.center,
                                                               radiusMeters: 1000, config: Support.config))
        let body = try XCTUnwrap(Support.body(of: request))
        XCTAssertEqual(body["textQuery"] as? String, "restaurants")
        XCTAssertNil(body["includedType"])
        XCTAssertFalse(Support.keys(of: body).contains("includedType"))
    }

    func testPLACES_NearbyRadiusClamp() throws {
        let cases: [(asked: Int, sent: Double)] = [(80_000, 50_000), (50, 100), (0, 100), (-5, 100),
                                                   (100, 100), (50_000, 50_000), (1500, 1500)]
        for item in cases {
            let request = try XCTUnwrap(GooglePlaces.nearbyRequest(category: .cafe, keyword: nil, near: Support.center,
                                                                   radiusMeters: item.asked, config: Support.config))
            let body = try XCTUnwrap(Support.body(of: request))
            let circle = try XCTUnwrap(Support.circle(of: body))
            XCTAssertEqual(circle.radius, item.sent, accuracy: 1e-9, "radius asked: \(item.asked)")
        }
    }

    func testPLACES_RequestHeadersAndTarget() throws {
        let search = try XCTUnwrap(GooglePlaces.searchRequest(query: "blue bottle", near: Support.center,
                                                              config: Support.config))
        let nearby = try XCTUnwrap(GooglePlaces.nearbyRequest(category: .cafe, keyword: nil, near: Support.center,
                                                              radiusMeters: 1000, config: Support.config))
        for request in [search, nearby] {
            XCTAssertEqual(request.url?.path, "/places")
            XCTAssertEqual(request.url?.host, Support.host)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 10)
            // The Worker token header is the positive control for the header scan below.
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-besir-token"), Support.token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-fieldmask"), mask)
            let names = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
            XCTAssertFalse(names.contains("x-goog-api-key"))
            XCTAssertFalse(names.contains("authorization"))
            let carrying = (request.allHTTPHeaderFields ?? [:]).filter { $0.value == Support.token }
                .map { $0.key.lowercased() }
            XCTAssertEqual(carrying, ["x-besir-token"])
            let bodyText = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertFalse(bodyText.isEmpty)
            XCTAssertFalse(bodyText.contains(Support.token))
        }
    }

    func testPLACES_FieldMaskExact() {
        XCTAssertEqual(GooglePlaces.fieldMask, mask)
        XCTAssertEqual(GooglePlaces.fieldMask.split(separator: ",").count, 6)
        XCTAssertFalse(GooglePlaces.fieldMask.contains("nationalPhoneNumber"))
        XCTAssertEqual(GooglePlaces.fieldMaskHeader, "x-goog-fieldmask")
    }

    func testPLACES_MealCategoryFilterValues() {
        XCTAssertEqual(MealCategoryFilter.restaurant.includedType, "restaurant")
        XCTAssertEqual(MealCategoryFilter.restaurant.categoryWord, "restaurants")
        XCTAssertEqual(MealCategoryFilter.cafe.includedType, "cafe")
        XCTAssertEqual(MealCategoryFilter.cafe.categoryWord, "cafes")
        for category in MealCategoryFilter.allCases {
            XCTAssertFalse(category.includedType.isEmpty)
            XCTAssertFalse(category.categoryWord.isEmpty)
            XCTAssertTrue(category.includedType.allSatisfy { $0.isASCII })
            XCTAssertTrue(category.categoryWord.allSatisfy { $0.isASCII })
        }
    }

    // MARK: - PR parsing

    func testPLACES_ParseSeveralResults() throws {
        let places = GooglePlaces.parsePlaces(try Support.fixture("places-search-three"))
        XCTAssertEqual(places, [
            Place(name: "Example Cafe", address: "100 Sample Avenue, Exampleton, EX 94100, USA",
                  latitude: 37.7801, longitude: -122.4101),
            Place(name: "Example Cafe", address: "200 Sample Boulevard, Exampleton, EX 94100, USA",
                  latitude: 37.7712, longitude: -122.4233),
            Place(name: "Sample Noodle House", address: "300 Placeholder Way, Exampleton, EX 94100, USA",
                  latitude: 37.7655, longitude: -122.4312)
        ])
        // The two places with one name stay two distinct values.
        XCTAssertEqual(Set(places).count, 3)
    }

    func testPLACES_ParseDropsResultWithoutLocation() throws {
        let places = GooglePlaces.parsePlaces(try Support.fixture("places-missing-location"))
        XCTAssertEqual(places.map(\.name), ["First Example Place", "Third Example Place"])
    }

    func testPLACES_ParseDropsResultWithoutDisplayName() throws {
        let places = GooglePlaces.parsePlaces(try Support.fixture("places-missing-name"))
        XCTAssertEqual(places.map(\.name), ["First Example Place", "Third Example Place"])
    }

    func testPLACES_ParseMissingAddressKeptEmpty() {
        let json = """
        {"places":[{"displayName":{"text":"Address Free Place"},"location":{"latitude":37.77,"longitude":-122.41}}]}
        """
        let places = GooglePlaces.parsePlaces(Data(json.utf8))
        XCTAssertEqual(places, [Place(name: "Address Free Place", address: "", latitude: 37.77, longitude: -122.41)])
    }

    func testPLACES_ParseNearbyFields() {
        let json = """
        {"places":[
          {"displayName":{"text":"Full Place"},"formattedAddress":"1 Example Street",
           "location":{"latitude":37.775,"longitude":-122.419},
           "primaryTypeDisplayName":{"text":"Coffee shop"},"googleMapsUri":"https://maps.example.invalid/full"},
          {"displayName":{"text":"Bare Place"},"location":{"latitude":37.776,"longitude":-122.418}},
          {"formattedAddress":"No Name Street","location":{"latitude":37.777,"longitude":-122.417}},
          {"displayName":{"text":"No Location Place"},"formattedAddress":"No Location Street"}
        ]}
        """
        let results = GooglePlaces.nearbyResults(from: Data(json.utf8), near: Support.center, radiusMeters: 50_000,
                                                 sort: .accuracy, limit: 20)
        XCTAssertEqual(results.map(\.place.name), ["Full Place", "Bare Place"])
        guard results.count == 2 else { return }
        XCTAssertEqual(results[0].category, "Coffee shop")
        XCTAssertEqual(results[0].url, "https://maps.example.invalid/full")
        XCTAssertEqual(results[0].place.address, "1 Example Street")
        XCTAssertNil(results[0].phone)
        XCTAssertEqual(results[1].category, "")
        XCTAssertNil(results[1].url)
        XCTAssertEqual(results[1].place.address, "")
        XCTAssertNil(results[1].phone)
    }

    // MARK: - FL failure contract (parsing half)

    func testPLACES_ParseEmptyObject() throws {
        XCTAssertEqual(GooglePlaces.parsePlaces(try Support.fixture("places-empty")), [])
        XCTAssertEqual(GooglePlaces.parsePlaces(Data("{\"places\":[]}".utf8)), [])
        XCTAssertEqual(GooglePlaces.nearbyResults(from: Data("{}".utf8), near: Support.center, radiusMeters: 1000,
                                                  sort: .distance, limit: 5).count, 0)
        // Counterpart: the same parser returns places for a real answer.
        XCTAssertEqual(GooglePlaces.parsePlaces(try Support.fixture("places-search-three")).count, 3)
    }

    func testPLACES_ParseErrorBodies() throws {
        XCTAssertEqual(GooglePlaces.parsePlaces(try Support.fixture("places-error")), [])
        XCTAssertEqual(GooglePlaces.parsePlaces(try Support.fixture("places-worker-error")), [])
        XCTAssertEqual(GooglePlaces.nearbyResults(from: try Support.fixture("places-error"), near: Support.center,
                                                  radiusMeters: 1000, sort: .distance, limit: 5).count, 0)
        XCTAssertEqual(GooglePlaces.parsePlaces(try Support.fixture("places-search-three")).count, 3)
    }

    func testPLACES_ParseUndecodable() throws {
        let html = Data("<html><body>Bad gateway</body></html>".utf8)
        let noise = Data([0xFF, 0x00, 0xFE, 0x7B, 0x22, 0x13, 0x80])
        for data in [html, noise, Data(), Data("[1,2,3]".utf8), Data("\"places\"".utf8)] {
            XCTAssertEqual(GooglePlaces.parsePlaces(data), [])
            XCTAssertEqual(GooglePlaces.nearbyResults(from: data, near: Support.center, radiusMeters: 1000,
                                                      sort: .distance, limit: 5).count, 0)
        }
        XCTAssertEqual(GooglePlaces.parsePlaces(try Support.fixture("places-search-three")).count, 3)
    }

    // MARK: - LV live-body sync

    func testPLACES_LiveFixtureBodiesEqualAppBodies() throws {
        let center = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let search = try XCTUnwrap(GooglePlaces.searchRequest(query: "blue bottle", near: center, config: Support.config))
        let nearby = try XCTUnwrap(GooglePlaces.nearbyRequest(category: .restaurant, keyword: "sushi", near: center,
                                                              radiusMeters: 1500, config: Support.config))
        let searchApp = try XCTUnwrap(Support.body(of: search))
        let nearbyApp = try XCTUnwrap(Support.body(of: nearby))
        let searchFixture = try JSONSerialization.jsonObject(with: Support.fixture("live-search-body"))
        let nearbyFixture = try JSONSerialization.jsonObject(with: Support.fixture("live-nearby-body"))
        XCTAssertTrue(searchApp.isEqual(searchFixture), "typed search body differs from live-search-body.json")
        XCTAssertTrue(nearbyApp.isEqual(nearbyFixture), "nearby body differs from live-nearby-body.json")
        let maskText = String(decoding: try Support.fixture("live-fieldmask", ext: "txt"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(maskText.split(whereSeparator: \.isNewline).count, 1)
        XCTAssertEqual(maskText, GooglePlaces.fieldMask)
        XCTAssertEqual(maskText, mask)
    }
}
