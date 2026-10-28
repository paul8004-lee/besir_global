import XCTest
import UIKit
import CoreLocation
@testable import besir

/// SPEC-PLACES-001: the thin `PlaceSearch` caller through a stubbed transport (PR client step, FL), the preserved
/// contract and source scans (SC) and the attribution logo (LG). Nothing here touches the network.
final class PlaceSearchTests: XCTestCase {
    private typealias Support = PlacesTestSupport

    private func makeSearch(_ stub: PlacesTransportStub, config: AppConfig = Support.config) -> PlaceSearch {
        PlaceSearch(config: config, transport: stub.transport)
    }

    private func threePlacesStub(status: Int = 200) throws -> PlacesTransportStub {
        PlacesTransportStub.answering(status: status, with: try Support.fixture("places-search-three"))
    }

    /// The distance the app computes, from the place a result carries.
    private func distance(of result: NearbyPlace) -> Double {
        CLLocation(latitude: result.place.latitude, longitude: result.place.longitude)
            .distance(from: CLLocation(latitude: Support.center.latitude, longitude: Support.center.longitude))
    }

    // MARK: - PR typed search and client step

    func testPLACES_SearchTrimsAndRequiresTwoCharacters() async throws {
        let stub = try threePlacesStub()
        let search = makeSearch(stub)
        for short in ["a", " a ", "   ", "", "\n"] {
            let result = await search.search(short, near: Support.center)
            XCTAssertEqual(result, [], "query: \(short.debugDescription)")
        }
        XCTAssertEqual(stub.callCount, 0)

        let trimmed = await search.search("  cafe ", near: Support.center)
        XCTAssertEqual(trimmed.count, 3)
        XCTAssertEqual(stub.callCount, 1)
        XCTAssertEqual(Support.body(of: try XCTUnwrap(stub.requests.first))?["textQuery"] as? String, "cafe")

        let twoCharacters = await search.search("ab", near: nil)
        XCTAssertEqual(twoCharacters.count, 3)
        XCTAssertEqual(stub.callCount, 2)
        XCTAssertEqual(Support.body(of: try XCTUnwrap(stub.requests.last))?["textQuery"] as? String, "ab")
    }

    func testPLACES_NearbyDistanceFilter() async {
        let answer = Support.nearbyAnswer([("near", 1000), ("far", 2000), ("inside", 1499.6), ("outside", 1500.4)])
        let stub = PlacesTransportStub.answering(with: answer)
        let results = await makeSearch(stub).nearbyPlaces(category: .restaurant, near: Support.center,
                                                          radiusMeters: 1500, sort: .accuracy, limit: 20)
        XCTAssertEqual(stub.callCount, 1)
        // Just inside the radius stays although its rounded distance is 1500; just outside goes.
        XCTAssertEqual(results.map(\.place.name), ["near", "inside"])
        for result in results {
            XCTAssertEqual(result.distanceMeters, Int(distance(of: result).rounded()))
        }
        XCTAssertEqual(results.last?.distanceMeters, 1500)
        XCTAssertEqual(results.first?.distanceMeters, 1000)

        // A requested radius of 50 is clamped to 100.
        let smallStub = PlacesTransportStub.answering(with: Support.nearbyAnswer([("in80", 80), ("out120", 120)]))
        let small = await makeSearch(smallStub).nearbyPlaces(category: nil, near: Support.center,
                                                             radiusMeters: 50, sort: .accuracy, limit: 20)
        XCTAssertEqual(small.map(\.place.name), ["in80"])

        // A requested radius of 80000 is clamped to 50000.
        let wideStub = PlacesTransportStub.answering(with: Support.nearbyAnswer([("in49k", 49_000), ("out51k", 51_000)]))
        let wide = await makeSearch(wideStub).nearbyPlaces(category: nil, near: Support.center,
                                                           radiusMeters: 80_000, sort: .accuracy, limit: 20)
        XCTAssertEqual(wide.map(\.place.name), ["in49k"])
    }

    func testPLACES_NearbySortDistance() async {
        let stub = PlacesTransportStub.answering(with: Support.nearbyAnswer([("far", 900), ("near", 300), ("mid", 600)]))
        let results = await makeSearch(stub).nearbyPlaces(category: .cafe, near: Support.center,
                                                          radiusMeters: 1500, sort: .distance, limit: 5)
        XCTAssertEqual(results.map(\.place.name), ["near", "mid", "far"])
    }

    func testPLACES_NearbySortRelevanceKeepsOrder() async {
        let answer = Support.nearbyAnswer([("far", 900), ("gone", 2000), ("near", 300), ("mid", 600)])
        let stub = PlacesTransportStub.answering(with: answer)
        let results = await makeSearch(stub).nearbyPlaces(category: .cafe, near: Support.center,
                                                          radiusMeters: 1500, sort: .accuracy, limit: 5)
        XCTAssertEqual(results.map(\.place.name), ["far", "near", "mid"])
    }

    func testPLACES_NearbyLimitTrims() async {
        let meters: [Double] = [1100, 300, 900, 100, 1400, 500, 1200, 700, 200, 1000, 400, 800]
        let items = meters.enumerated().map { (name: "P\($0.offset)", meters: $0.element) }
        let stub = PlacesTransportStub.answering(with: Support.nearbyAnswer(items))
        let search = makeSearch(stub)
        let byDistance = await search.nearbyPlaces(category: .restaurant, near: Support.center,
                                                   radiusMeters: 1500, sort: .distance, limit: 5)
        // The five nearest are 100, 200, 300, 400 and 500 metres: P3, P8, P1, P10, P5.
        XCTAssertEqual(byDistance.map(\.place.name), ["P3", "P8", "P1", "P10", "P5"])
        let byRelevance = await search.nearbyPlaces(category: .restaurant, near: Support.center,
                                                    radiusMeters: 1500, sort: .accuracy, limit: 5)
        XCTAssertEqual(byRelevance.map(\.place.name), ["P0", "P1", "P2", "P3", "P4"])
    }

    func testPLACES_NearbyLimitClamp() async {
        // 25 places inside the radius, answered farthest first, so the nearest one is the last in Google's order.
        let many = (0..<25).reversed().map { (name: "P\($0)", meters: 50.0 + 100.0 * Double($0)) }
        let search = makeSearch(PlacesTransportStub.answering(with: Support.nearbyAnswer(many)))
        func count(_ limit: Int, _ sort: NearbySort = .distance) async -> [NearbyPlace] {
            await search.nearbyPlaces(category: .restaurant, near: Support.center, radiusMeters: 5000,
                                      sort: sort, limit: limit)
        }
        let zero = await count(0)
        XCTAssertEqual(zero.map(\.place.name), ["P0"])
        let negative = await count(-3)
        XCTAssertEqual(negative.count, 1)
        let twenty = await count(20)
        XCTAssertEqual(twenty.count, 20)
        let twentyOne = await count(21)
        XCTAssertEqual(twentyOne.count, 20)
        let ninetyNine = await count(99)
        XCTAssertEqual(ninetyNine.count, 20)
        XCTAssertEqual(ninetyNine.first?.place.name, "P0")

        let fewSearch = makeSearch(PlacesTransportStub.answering(
            with: Support.nearbyAnswer([("A", 100), ("B", 200), ("C", 300)])))
        let few = await fewSearch.nearbyPlaces(category: .cafe, near: Support.center, radiusMeters: 5000,
                                               sort: .distance, limit: 99)
        XCTAssertEqual(few.count, 3)
    }

    // MARK: - FL failure contract (transport half)

    func testPLACES_SearchNon200GivesEmpty() async throws {
        for status in [400, 401, 403, 429, 500, 502, 503] {
            let stub = try threePlacesStub(status: status)
            let result = await makeSearch(stub).search("blue bottle", near: Support.center)
            XCTAssertEqual(result, [], "status \(status)")
            XCTAssertEqual(stub.callCount, 1, "status \(status)")
        }
        // A response that is not an HTTP response.
        let body = try Support.fixture("places-search-three")
        let plain = PlacesTransportStub { request in
            (body, URLResponse(url: request.url ?? URL(fileURLWithPath: "/"), mimeType: "application/json",
                               expectedContentLength: body.count, textEncodingName: nil))
        }
        let nonHTTP = await makeSearch(plain).search("blue bottle", near: Support.center)
        XCTAssertEqual(nonHTTP, [])
        XCTAssertEqual(plain.callCount, 1)
        // Counterpart: status 200 with the same body returns the three places.
        let good = await makeSearch(try threePlacesStub()).search("blue bottle", near: Support.center)
        XCTAssertEqual(good.count, 3)
    }

    // MARK: - SPEC-PLACEFAIL-001: lookup tells a failure from an empty answer

    func testPLACEFAIL_LookupSeparatesFailureFromEmpty() async throws {
        for status in [400, 401, 403, 429, 500, 502, 503] {
            let stub = try threePlacesStub(status: status)
            let result = await makeSearch(stub).lookup("cafe", near: nil)
            XCTAssertEqual(result, .failed, "status \(status)")
            XCTAssertEqual(stub.callCount, 1, "status \(status)")
        }
        let body = try Support.fixture("places-search-three")
        let plain = PlacesTransportStub { request in
            (body, URLResponse(url: request.url ?? URL(fileURLWithPath: "/"), mimeType: "application/json",
                               expectedContentLength: body.count, textEncodingName: nil))
        }
        let nonHTTP = await makeSearch(plain).lookup("cafe", near: nil)
        XCTAssertEqual(nonHTTP, .failed)

        let offline = PlacesTransportStub { _ in throw URLError(.notConnectedToInternet) }
        let thrown = await makeSearch(offline).lookup("cafe", near: nil)
        XCTAssertEqual(thrown, .failed)
        XCTAssertEqual(offline.callCount, 1)

        let unconfiguredStub = try threePlacesStub()
        let unconfigured = await makeSearch(unconfiguredStub, config: AppConfig()).lookup("cafe", near: nil)
        XCTAssertEqual(unconfigured, .failed)
        XCTAssertEqual(unconfiguredStub.callCount, 0, "no proxy: nothing can be sent")

        // Counterparts: an answer that came back is `.found`, empty or not.
        let good = await makeSearch(try threePlacesStub()).lookup("cafe", near: nil)
        guard case .found(let places) = good else { return XCTFail("a good answer is found, got \(good)") }
        XCTAssertEqual(places.count, 3)
        let empty = await makeSearch(PlacesTransportStub.answering(with: try Support.fixture("places-empty")))
            .lookup("cafe", near: nil)
        XCTAssertEqual(empty, .found([]))
        let garbled = await makeSearch(PlacesTransportStub.answering(with: Data("not json".utf8))).lookup("cafe", near: nil)
        XCTAssertEqual(garbled, .found([]), "a 200 with an unreadable body stays an empty answer (L3)")

        let shortStub = try threePlacesStub()
        let short = await makeSearch(shortStub).lookup("a", near: nil)
        XCTAssertEqual(short, .found([]))
        XCTAssertEqual(shortStub.callCount, 0, "a query under 2 characters sends nothing")
    }

    func testPLACEFAIL_LookupRecordsTheSamePacketsAsSearch() async throws {
        func logged(_ log: ConnectionLog) async -> [String] {
            await log.flush()
            return log.packets.map { "\($0.from.rawValue)>\($0.to.rawValue) \($0.kind.rawValue) \($0.status.rawValue) \($0.summary)" }
        }
        func makeLog() -> ConnectionLog {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("placefail-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            return ConnectionLog(fileURL: folder.appendingPathComponent(ConnectionLog.fileName))
        }
        let failedLine = "besir>googlePlaces placeSearch failed Search failed"
        let goodLine = "besir>googlePlaces placeSearch ok Searched “cafe” · 3 results"
        let failing: [(String, PlacesTransportStub)] = [
            ("status 500", try threePlacesStub(status: 500)),
            ("thrown", PlacesTransportStub { _ in throw URLError(.notConnectedToInternet) })]
        for (label, stub) in failing {
            let flow = UUID()
            let lookLog = makeLog()
            var lookSearch = makeSearch(stub)
            lookSearch.connections = lookLog
            let looked = await lookSearch.lookup("cafe", near: nil, flow: flow)
            XCTAssertEqual(looked, .failed, label)
            let linesLookLog = await logged(lookLog)
            XCTAssertEqual(linesLookLog, [failedLine], label)
            XCTAssertEqual(lookLog.packets.first?.flowID, flow, label)

            let searchLog = makeLog()
            var plainSearch = makeSearch(stub)
            plainSearch.connections = searchLog
            let searched = await plainSearch.search("cafe", near: nil, flow: flow)
            XCTAssertEqual(searched, [], label)
            let linesSearchLog = await logged(searchLog)
            XCTAssertEqual(linesSearchLog, [failedLine], label)
        }

        let goodLog = makeLog()
        var good = makeSearch(try threePlacesStub())
        good.connections = goodLog
        let found = await good.lookup("cafe", near: nil)
        guard case .found(let places) = found else { return XCTFail("a good answer is found, got \(found)") }
        XCTAssertEqual(places.count, 3)
        let linesGoodLog = await logged(goodLog)
        XCTAssertEqual(linesGoodLog, [goodLine])
        let searchedLog = makeLog()
        var searchedGood = makeSearch(try threePlacesStub())
        searchedGood.connections = searchedLog
        let searchedPlaces = await searchedGood.search("cafe", near: nil)
        XCTAssertEqual(searchedPlaces.count, 3)
        let linesSearchedLog = await logged(searchedLog)
        XCTAssertEqual(linesSearchedLog, [goodLine])

        let noProxyLog = makeLog()
        var noProxy = makeSearch(try threePlacesStub(), config: AppConfig())
        noProxy.connections = noProxyLog
        let unconfigured = await noProxy.lookup("cafe", near: nil)
        XCTAssertEqual(unconfigured, .failed)
        let linesNoProxyLog = await logged(noProxyLog)
        XCTAssertEqual(linesNoProxyLog, [], "nothing was sent, so nothing is recorded")
        let unconfiguredSearch = await noProxy.search("cafe", near: nil)
        XCTAssertEqual(unconfiguredSearch, [])
        let linesAfterSearch = await logged(noProxyLog)
        XCTAssertEqual(linesAfterSearch, [])
    }

    func testPLACES_SearchTransportThrowsGivesEmpty() async throws {
        let offline = PlacesTransportStub { _ in throw URLError(.notConnectedToInternet) }
        let offlineResult = await makeSearch(offline).search("blue bottle", near: Support.center)
        XCTAssertEqual(offlineResult, [])
        XCTAssertEqual(offline.callCount, 1)
        let cancelled = PlacesTransportStub { _ in throw CancellationError() }
        let cancelledResult = await makeSearch(cancelled).search("blue bottle", near: Support.center)
        XCTAssertEqual(cancelledResult, [])
        XCTAssertEqual(cancelled.callCount, 1)
        let good = await makeSearch(try threePlacesStub()).search("blue bottle", near: Support.center)
        XCTAssertEqual(good.count, 3)
    }

    func testPLACES_UnconfiguredSendsNothing() async throws {
        let stub = try threePlacesStub()
        let unconfigured = makeSearch(stub, config: AppConfig())
        let typed = await unconfigured.search("blue bottle", near: Support.center)
        let nearby = await unconfigured.nearbyPlaces(category: .cafe, near: Support.center)
        XCTAssertEqual(typed, [])
        XCTAssertEqual(nearby.count, 0)
        XCTAssertEqual(stub.callCount, 0)
        // Counterpart: the configured search reaches the transport and returns places.
        let configured = await makeSearch(stub).search("blue bottle", near: Support.center)
        XCTAssertEqual(configured.count, 3)
        XCTAssertEqual(stub.callCount, 1)
    }

    func testPLACES_NearbyFailureGivesEmpty() async {
        let answer = Support.nearbyAnswer([("A", 100)])
        for status in [401, 429, 503] {
            let stub = PlacesTransportStub.answering(status: status, with: answer)
            let result = await makeSearch(stub).nearbyPlaces(category: .cafe, near: Support.center)
            XCTAssertEqual(result.count, 0, "status \(status)")
            XCTAssertEqual(stub.callCount, 1, "status \(status)")
        }
        let thrown = PlacesTransportStub { _ in throw URLError(.timedOut) }
        let thrownResult = await makeSearch(thrown).nearbyPlaces(category: .cafe, near: Support.center)
        XCTAssertEqual(thrownResult.count, 0)
        XCTAssertEqual(thrown.callCount, 1)
        let garbage = PlacesTransportStub.answering(with: Data("<html>Bad gateway</html>".utf8))
        let garbageResult = await makeSearch(garbage).nearbyPlaces(category: .cafe, near: Support.center)
        XCTAssertEqual(garbageResult.count, 0)
        XCTAssertEqual(garbage.callCount, 1)
        // Counterpart: a good answer returns the place.
        let good = PlacesTransportStub.answering(with: answer)
        let goodResult = await makeSearch(good).nearbyPlaces(category: .cafe, near: Support.center)
        XCTAssertEqual(goodResult.count, 1)
    }

    // MARK: - SC preserved contract and scans

    func testPLACES_PlaceCodableShapeUnchanged() throws {
        let place = Place(name: "Example Cafe", address: "100 Sample Avenue", latitude: 37.78, longitude: -122.41)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(place))
        let object = try XCTUnwrap(encoded as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["address", "latitude", "longitude", "name"])
        // A value saved before this change still decodes.
        let old = "{\"name\":\"Old Place\",\"address\":\"1 Old Road\",\"latitude\":37.5,\"longitude\":127.0}"
        let decoded = try JSONDecoder().decode(Place.self, from: Data(old.utf8))
        XCTAssertEqual(decoded, Place(name: "Old Place", address: "1 Old Road", latitude: 37.5, longitude: 127.0))
    }

    /// The needles of `needles` that appear in `text`.
    private static func scan(_ text: String, for needles: [String]) -> [String] {
        needles.filter { text.contains($0) }
    }

    func testPLACES_SourceScanFindsNoOldPaths() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let needles = ["/kakao", "MKLocalSearch", "category_group_code"]
        for name in ["PlaceSearch", "GooglePlaces"] {
            let url = root.appendingPathComponent("Shared/\(name).swift")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("cannot read the source file Shared/\(name).swift")
                continue
            }
            // Control: the text read is the real file, not an empty string.
            XCTAssertTrue(text.contains(name), "Shared/\(name).swift read, but it does not mention \(name)")
            XCTAssertEqual(Self.scan(text, for: needles), [], "old path left in Shared/\(name).swift")
        }
    }

    func testPLACES_SourceScanHelperFindsPlantedString() {
        let needles = ["/kakao", "MKLocalSearch", "category_group_code"]
        XCTAssertEqual(Self.scan("let path = \"/kakao/local\"", for: needles), ["/kakao"])
        XCTAssertEqual(Self.scan("request = MKLocalSearch.Request()\nitems.append(\"category_group_code\")", for: needles),
                       ["MKLocalSearch", "category_group_code"])
        XCTAssertEqual(Self.scan("let path = \"/places\"", for: needles), [])
    }

    func testPLACES_SortAndCategoryTitlesUnchanged() {
        XCTAssertEqual(NearbySort.distance.title, "Distance")
        XCTAssertEqual(NearbySort.accuracy.title, "Relevance")
        XCTAssertEqual(NearbySort.distance.rawValue, "distance")
        XCTAssertEqual(NearbySort.accuracy.rawValue, "accuracy")
        XCTAssertEqual(MealCategoryFilter.restaurant.title, "Restaurants")
        XCTAssertEqual(MealCategoryFilter.cafe.title, "Cafes")
        XCTAssertEqual(MealCategoryFilter.restaurant.rawValue, "restaurant")
        XCTAssertEqual(MealCategoryFilter.cafe.rawValue, "cafe")
        XCTAssertEqual(PlaceSearch.maxSuggestions, 5)
    }

    // MARK: - LG logo

    func testPLACES_LogoAssetResolvesInLightAndDark() throws {
        let bundle = Bundle(for: LocationManager.self)
        let light = try XCTUnwrap(UIImage(named: "GoogleMapsLogo", in: bundle,
                                          compatibleWith: UITraitCollection(userInterfaceStyle: .light)))
        let dark = try XCTUnwrap(UIImage(named: "GoogleMapsLogo", in: bundle,
                                         compatibleWith: UITraitCollection(userInterfaceStyle: .dark)))
        let expectedRatio = 98.0 / 18.0
        for image in [light, dark] {
            XCTAssertGreaterThan(image.size.height, 0)
            XCTAssertEqual(image.size.width / image.size.height, expectedRatio, accuracy: expectedRatio * 0.02)
        }
        func rendering(_ image: UIImage) -> Data? {
            let size = CGSize(width: 98, height: 18)
            return UIGraphicsImageRenderer(size: size).pngData { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        let lightData = try XCTUnwrap(rendering(light))
        let darkData = try XCTUnwrap(rendering(dark))
        XCTAssertFalse(lightData.isEmpty)
        XCTAssertNotEqual(lightData, darkData, "the light and dark renderings must differ")
    }
}

/// Card t48: a location source with no CoreLocation behind it. It counts what the manager asks of it.
@MainActor
final class FakeLocationSource: LocationSource {
    var authorizationStatus: CLAuthorizationStatus
    var cachedLocation: CLLocation?
    var distanceFilter: CLLocationDistance = 0
    private(set) var requestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(status: CLAuthorizationStatus) { authorizationStatus = status }

    func requestWhenInUseAuthorization() { requestCount += 1 }
    func startUpdatingLocation() { startCount += 1 }
    func stopUpdatingLocation() { stopCount += 1 }
}

/// Card t39: an IP-based approximate origin must not outlive the real fix.
@MainActor
final class OriginLocationTests: XCTestCase {
    func testORIGIN_ApproximateStillStartsUpdatesWhenPermissionIsGranted() {
        let source = FakeLocationSource(status: .notDetermined)
        let lm = LocationManager(source: source, ipLookup: { nil }, nameResolver: { _ in nil }, waitSeconds: 0.05)
        lm.handleAuthorization(.notDetermined)
        XCTAssertEqual(source.startCount, 0, "a fresh manager has nothing to start")
        lm.applyApproximate(latitude: 37.5661369, longitude: 126.9783785, region: "Seoul", city: "Seoul")
        XCTAssertFalse(lm.isLocating, "the fallback ends the locating state")
        XCTAssertTrue(lm.isApproximate)
        source.authorizationStatus = .authorizedWhenInUse
        lm.handleAuthorization(.authorizedWhenInUse)
        XCTAssertEqual(source.startCount, 1, "granting permission after the fallback must start real positioning")
    }

    func testORIGIN_RealFixReplacesApproximateCoordinateAndName() {
        let lm = LocationManager()
        lm.applyApproximate(latitude: 37.5661369, longitude: 126.9783785, region: "Seoul", city: "Seoul")
        XCTAssertEqual(lm.currentPlaceName, "Seoul (approx.)")
        lm.applyFix(CLLocation(latitude: 37.7849, longitude: -122.4094))
        XCTAssertEqual(lm.currentLocation?.latitude, 37.7849)
        XCTAssertEqual(lm.currentLocation?.longitude, -122.4094)
        XCTAssertFalse(lm.isApproximate)
        XCTAssertNotEqual(lm.currentPlaceName, "Seoul (approx.)", "the approximate name must not stay on the real coordinate")
    }

    func testORIGIN_ApproximateNameJoinsRegionAndCity() {
        XCTAssertEqual(LocationManager.joinedApproxName(region: "Seoul", city: "Seoul"), "Seoul")
        XCTAssertEqual(LocationManager.joinedApproxName(region: "California", city: "San Francisco"), "California San Francisco")
    }
}

// MARK: - Card t48: location permission flow

/// An IP lookup that counts its calls. With `suspendFirst` the first call parks until `release`.
final class IPLookupStub: @unchecked Sendable {
    private let lock = NSLock()
    private var calledCount = 0
    private var parkedCount = 0
    private var waiting: [CheckedContinuation<ApproximateLocation?, Never>] = []
    private let answer: ApproximateLocation?
    private let suspendFirst: Bool

    init(answer: ApproximateLocation? = nil, suspendFirst: Bool = false) {
        self.answer = answer
        self.suspendFirst = suspendFirst
    }

    var calls: Int { lock.withLock { calledCount } }
    /// Calls that are parked and ready to be released.
    var parked: Int { lock.withLock { parkedCount } }

    func lookup() async -> ApproximateLocation? {
        let n = lock.withLock { () -> Int in
            calledCount += 1
            return calledCount
        }
        guard suspendFirst, n == 1 else { return answer }
        return await withCheckedContinuation { c in
            lock.withLock {
                waiting.append(c)
                parkedCount += 1
            }
        }
    }

    func release(_ value: ApproximateLocation?) {
        let all = lock.withLock { () -> [CheckedContinuation<ApproximateLocation?, Never>] in
            let taken = waiting
            waiting = []
            return taken
        }
        for c in all { c.resume(returning: value) }
    }
}

/// A name lookup that follows a script: answer at once, or park until `release`.
final class NameLookupStub: @unchecked Sendable {
    enum Step { case answer(String?), suspend }

    private let lock = NSLock()
    private var script: [Step]
    private var waiting: [CheckedContinuation<String?, Never>] = []
    private var parkedCount = 0
    private var cancelledAfterParking: [Bool] = []

    init(_ script: [Step]) { self.script = script }

    var parked: Int { lock.withLock { parkedCount } }
    /// For each parked call, whether its task was cancelled when it was released.
    var cancelledSeen: [Bool] { lock.withLock { cancelledAfterParking } }

    func resolve(_ location: CLLocation) async -> String? {
        let step = lock.withLock { () -> Step in script.isEmpty ? .answer(nil) : script.removeFirst() }
        switch step {
        case .answer(let name):
            return name
        case .suspend:
            let name = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                lock.withLock {
                    waiting.append(c)
                    parkedCount += 1
                }
            }
            let cancelled = Task.isCancelled
            lock.withLock { cancelledAfterParking.append(cancelled) }
            return name
        }
    }

    func release(_ name: String?) {
        let all = lock.withLock { () -> [CheckedContinuation<String?, Never>] in
            let taken = waiting
            waiting = []
            return taken
        }
        for c in all { c.resume(returning: name) }
    }
}

/// Card t48: the permission flow, the IP guess that is never an origin, and the fresh position, driven through a
/// fake location source. Nothing here touches CoreLocation, the network or the geocoder.
@MainActor
final class LocationPermissionTests: XCTestCase {
    private let sf = CLLocation(latitude: 37.7849, longitude: -122.4094)
    private let seoul = ApproximateLocation(latitude: 37.5661369, longitude: 126.9783785, region: "Seoul", city: "Seoul")
    private let deniedText = "Location permission was denied. Allow it in Settings."
    private let failureText = "Couldn't get your location. Check Settings → Location Services, or search for an origin yourself."

    private struct Rig {
        let lm: LocationManager
        let source: FakeLocationSource
        let ip: IPLookupStub
        let names: NameLookupStub
    }

    private func makeRig(_ status: CLAuthorizationStatus, ip: IPLookupStub = IPLookupStub(),
                         names: NameLookupStub = NameLookupStub([]), wait: TimeInterval = 0.05) -> Rig {
        let source = FakeLocationSource(status: status)
        let lm = LocationManager(source: source,
                                 ipLookup: { await ip.lookup() },
                                 nameResolver: { await names.resolve($0) },
                                 waitSeconds: wait)
        return Rig(lm: lm, source: source, ip: ip, names: names)
    }

    /// Polls every 10 ms until the condition holds or the deadline passes.
    private func eventually(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func grant(_ rig: Rig) {
        rig.source.authorizationStatus = .authorizedWhenInUse
        rig.lm.handleAuthorization(.authorizedWhenInUse)
    }

    private func holdSeoul(_ rig: Rig) {
        rig.lm.applyApproximate(latitude: seoul.latitude, longitude: seoul.longitude, region: "Seoul", city: "Seoul")
    }

    // MARK: AU authorization and waits

    func testLOCPERM_GrantAfterDenialStartsPositioning() {
        let rig = makeRig(.denied)
        rig.lm.useCurrentLocation()
        XCTAssertNotNil(rig.lm.lastError)
        XCTAssertFalse(rig.lm.isLocating)
        grant(rig)
        XCTAssertEqual(rig.source.startCount, 1)
        XCTAssertTrue(rig.lm.isLocating)
    }

    func testLOCPERM_GrantAfterFailedIPLookupStartsPositioning() async {
        let rig = makeRig(.notDetermined)
        rig.lm.useCurrentLocation()
        let ended = await eventually { !rig.lm.isLocating }
        XCTAssertTrue(ended)
        XCTAssertNil(rig.lm.currentLocation)
        XCTAssertFalse(rig.lm.isApproximate)
        let before = rig.source.startCount
        grant(rig)
        XCTAssertTrue(rig.lm.isLocating)
        XCTAssertEqual(rig.source.startCount, before + 1)
    }

    func testLOCPERM_GrantAfterApproximateStartsPositioning() {
        let rig = makeRig(.notDetermined)
        holdSeoul(rig)
        grant(rig)
        XCTAssertEqual(rig.source.startCount, 1)
        XCTAssertTrue(rig.lm.isLocating)
        rig.lm.handleUpdate(sf)
        XCTAssertFalse(rig.lm.isApproximate)
        XCTAssertEqual(rig.lm.currentLocation?.latitude, sf.coordinate.latitude)
        XCTAssertEqual(rig.lm.currentLocation?.longitude, sf.coordinate.longitude)
    }

    func testLOCPERM_GrantWithARealFixStartsNoWait() async {
        let rig = makeRig(.authorizedWhenInUse)
        rig.lm.handleUpdate(sf)
        grant(rig)
        XCTAssertFalse(rig.lm.isLocating)
        await pause(0.15)
        XCTAssertEqual(rig.ip.calls, 0)
    }

    func testLOCPERM_GrantArmsABoundedWait() async {
        let rig = makeRig(.notDetermined, ip: IPLookupStub(answer: seoul))
        grant(rig)
        let done = await eventually { rig.ip.calls == 1 && rig.lm.isApproximate }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.ip.calls, 1)
        XCTAssertNotNil(rig.lm.currentLocation)
        XCTAssertFalse(rig.lm.isLocating)
    }

    func testLOCPERM_BeginningTwiceKeepsOneWait() async {
        let rig = makeRig(.notDetermined, ip: IPLookupStub(suspendFirst: true))
        grant(rig)
        grant(rig)
        let parked = await eventually { rig.ip.parked == 1 }
        XCTAssertTrue(parked)
        await pause(0.1)
        XCTAssertEqual(rig.ip.calls, 1, "a wait that was not cancelled would have called the lookup twice")
        rig.ip.release(seoul)
        let applied = await eventually { rig.lm.currentLocation != nil }
        XCTAssertTrue(applied)
        XCTAssertEqual(rig.lm.currentLocation?.latitude, seoul.latitude)
        XCTAssertEqual(rig.lm.currentPlaceName, "Seoul (approx.)")
    }

    func testLOCPERM_WaitEndWithApproximateHeldClearsIsLocating() async {
        let rig = makeRig(.authorizedWhenInUse)
        holdSeoul(rig)
        rig.lm.useCurrentLocation()
        XCTAssertTrue(rig.lm.isLocating)
        let ended = await eventually { !rig.lm.isLocating }
        XCTAssertTrue(ended)
        XCTAssertNil(rig.lm.lastError)
        XCTAssertEqual(rig.ip.calls, 0)
    }

    func testLOCPERM_WaitEndWithNothingRunsIPLookupThenReportsFailure() async {
        let rig = makeRig(.notDetermined)
        rig.lm.useCurrentLocation()
        let ended = await eventually { !rig.lm.isLocating }
        XCTAssertTrue(ended)
        XCTAssertEqual(rig.lm.lastError, failureText)
    }

    func testLOCPERM_DenialDiscardsApproximateAndStopsEverything() async {
        let rig = makeRig(.authorizedWhenInUse)
        holdSeoul(rig)
        rig.lm.useCurrentLocation()
        XCTAssertTrue(rig.lm.isLocating)
        rig.source.authorizationStatus = .denied
        rig.lm.handleAuthorization(.denied)
        XCTAssertNil(rig.lm.currentLocation)
        XCTAssertFalse(rig.lm.isApproximate)
        XCTAssertNil(rig.lm.currentPlaceName)
        XCTAssertFalse(rig.lm.isLocating)
        XCTAssertGreaterThanOrEqual(rig.source.stopCount, 1)
        XCTAssertEqual(rig.lm.lastError, deniedText)
        await pause(0.15)
        XCTAssertEqual(rig.ip.calls, 0)
    }

    func testLOCPERM_DenialKeepsARealFix() {
        let rig = makeRig(.authorizedWhenInUse)
        rig.lm.handleUpdate(sf)
        rig.source.authorizationStatus = .denied
        rig.lm.handleAuthorization(.denied)
        XCTAssertEqual(rig.lm.currentLocation?.latitude, sf.coordinate.latitude)
        XCTAssertEqual(rig.lm.currentLocation?.longitude, sf.coordinate.longitude)
        XCTAssertFalse(rig.lm.isApproximate)
        XCTAssertNotNil(rig.lm.lastError)
    }

    func testLOCPERM_IPAnswerAfterDenialIsDiscarded() async {
        let rig = makeRig(.notDetermined, ip: IPLookupStub(suspendFirst: true))
        rig.lm.useCurrentLocation()
        let parked = await eventually { rig.ip.parked == 1 }
        XCTAssertTrue(parked)
        rig.source.authorizationStatus = .denied
        rig.lm.handleAuthorization(.denied)
        rig.ip.release(seoul)
        await pause(0.1)
        XCTAssertNil(rig.lm.currentLocation)
        XCTAssertFalse(rig.lm.isApproximate)
    }

    func testLOCPERM_IPAnswerAfterRealFixIsDiscarded() async {
        let rig = makeRig(.notDetermined, ip: IPLookupStub(suspendFirst: true))
        rig.lm.useCurrentLocation()
        let parked = await eventually { rig.ip.parked == 1 }
        XCTAssertTrue(parked)
        rig.lm.handleUpdate(sf)
        rig.ip.release(seoul)
        await pause(0.1)
        XCTAssertEqual(rig.lm.currentLocation?.latitude, sf.coordinate.latitude)
        XCTAssertEqual(rig.lm.currentLocation?.longitude, sf.coordinate.longitude)
        XCTAssertFalse(rig.lm.isApproximate)
    }

    func testLOCPERM_IPLookupIsNotRunWhenDenied() async {
        let rig = makeRig(.notDetermined)
        rig.lm.useCurrentLocation()
        XCTAssertTrue(rig.lm.isLocating)
        rig.source.authorizationStatus = .denied
        let ended = await eventually { !rig.lm.isLocating }
        XCTAssertTrue(ended)
        XCTAssertEqual(rig.ip.calls, 0)
    }

    func testLOCPERM_FailureWithALocationHeldWritesNoError() async {
        let rig = makeRig(.authorizedWhenInUse)
        holdSeoul(rig)
        rig.lm.useCurrentLocation()
        XCTAssertTrue(rig.lm.isLocating)
        rig.lm.handleFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertNil(rig.lm.lastError)
        XCTAssertFalse(rig.lm.isLocating)
        await pause(0.15)
        XCTAssertEqual(rig.ip.calls, 0)
    }

    func testLOCPERM_LocationUnknownFailureIsIgnored() {
        let rig = makeRig(.authorizedWhenInUse)
        rig.lm.useCurrentLocation()
        XCTAssertTrue(rig.lm.isLocating)
        rig.lm.handleFailure(CLError(.locationUnknown))
        XCTAssertTrue(rig.lm.isLocating)
        XCTAssertNil(rig.lm.lastError)
    }

    func testLOCPERM_IPAnswerAfterAReplacedWaitIsDiscarded() async {
        let rig = makeRig(.notDetermined, ip: IPLookupStub(suspendFirst: true), wait: 1)
        rig.lm.useCurrentLocation()
        let parked = await eventually(3) { rig.ip.parked == 1 }
        XCTAssertTrue(parked)
        grant(rig)
        rig.ip.release(seoul)
        await pause(0.1)
        XCTAssertNil(rig.lm.currentLocation)
        XCTAssertFalse(rig.lm.isApproximate)
        XCTAssertTrue(rig.lm.isLocating, "the newer wait is still armed")
        XCTAssertNil(rig.lm.lastError)
    }

    // MARK: RF real fix and the places that commit an origin

    func testLOCPERM_RealFixLocationIsNilForApproximate() {
        let rig = makeRig(.notDetermined)
        holdSeoul(rig)
        XCTAssertNotNil(rig.lm.currentLocation)
        XCTAssertNil(rig.lm.realFixLocation)
    }

    func testLOCPERM_RealFixLocationFollowsTheFix() {
        let rig = makeRig(.authorizedWhenInUse)
        XCTAssertNil(rig.lm.realFixLocation)
        rig.lm.applyFix(sf)
        XCTAssertEqual(rig.lm.realFixLocation?.latitude, sf.coordinate.latitude)
        XCTAssertEqual(rig.lm.realFixLocation?.longitude, sf.coordinate.longitude)
    }

    func testLOCPERM_AvailablePlaceIgnoresApproximate() {
        let rig = makeRig(.notDetermined)
        holdSeoul(rig)
        XCTAssertNil(PlaceLineResolve.availablePlace(rig.lm))
        rig.lm.applyFix(sf)
        let place = PlaceLineResolve.availablePlace(rig.lm)
        XCTAssertEqual(place?.latitude, sf.coordinate.latitude)
        XCTAssertEqual(place?.longitude, sf.coordinate.longitude)
    }

    func testLOCPERM_WaitReturnsTheRealFixThatReplacesApproximate() async {
        let rig = makeRig(.authorizedWhenInUse)
        holdSeoul(rig)
        let lm = rig.lm
        let started = Date()
        let waiter = Task { @MainActor in await PlaceLineResolve.waitForCurrentPlace(lm, maxSeconds: 2) }
        await pause(0.3)
        lm.handleUpdate(sf)
        let place = await waiter.value
        XCTAssertEqual(place?.latitude, sf.coordinate.latitude)
        XCTAssertEqual(place?.longitude, sf.coordinate.longitude)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testLOCPERM_WaitEndsEmptyWhenOnlyApproximateIsHeld() async {
        let rig = makeRig(.authorizedWhenInUse)
        holdSeoul(rig)
        let place = await PlaceLineResolve.waitForCurrentPlace(rig.lm, maxSeconds: 0.6)
        XCTAssertNil(place)
        XCTAssertTrue(rig.lm.isApproximate)
        XCTAssertNotNil(rig.lm.currentLocation)
    }

    func testLOCPERM_WaitAsksForPositioningWhenOnlyApproximateIsHeld() async {
        let rig = makeRig(.authorizedWhenInUse)
        holdSeoul(rig)
        _ = await PlaceLineResolve.waitForCurrentPlace(rig.lm, maxSeconds: 0.3)
        XCTAssertEqual(rig.source.startCount, 1)
    }

    // MARK: FR foreground freshness

    func testLOCPERM_ForegroundWithGrantStartsUpdates() {
        let rig = makeRig(.authorizedWhenInUse)
        rig.lm.setForeground(true)
        XCTAssertEqual(rig.source.startCount, 1)
        XCTAssertTrue(rig.lm.isLocating)
    }

    func testLOCPERM_ForegroundWithoutGrantStartsNothing() {
        let rig = makeRig(.notDetermined)
        rig.lm.setForeground(true)
        XCTAssertEqual(rig.source.startCount, 0)
        rig.source.authorizationStatus = .denied
        rig.lm.setForeground(true)
        XCTAssertEqual(rig.source.startCount, 0)
    }

    func testLOCPERM_SecondFixReplacesFirstAndUpdatesKeepRunning() {
        let rig = makeRig(.authorizedWhenInUse)
        let a = CLLocation(latitude: 37.30, longitude: -121.90)
        let b = CLLocation(latitude: 37.33, longitude: -122.00)
        rig.lm.handleUpdate(a)
        rig.lm.handleUpdate(b)
        XCTAssertEqual(rig.lm.currentLocation?.latitude, b.coordinate.latitude)
        XCTAssertEqual(rig.lm.currentLocation?.longitude, b.coordinate.longitude)
        XCTAssertEqual(rig.source.stopCount, 0)
    }

    func testLOCPERM_BackgroundStopsUpdatesAndForegroundResumes() {
        let rig = makeRig(.authorizedWhenInUse)
        rig.lm.handleUpdate(sf)
        rig.lm.setForeground(false)
        XCTAssertEqual(rig.source.stopCount, 1)
        XCTAssertFalse(rig.lm.isLocating)
        let starts = rig.source.startCount
        rig.lm.setForeground(true)
        XCTAssertEqual(rig.source.startCount, starts + 1)
        XCTAssertFalse(rig.lm.isLocating)

        let other = makeRig(.notDetermined)
        other.lm.setForeground(false)
        grant(other)
        XCTAssertEqual(other.source.startCount, 0)
        XCTAssertFalse(other.lm.isLocating)
    }

    func testLOCPERM_DistanceFilterIsOneHundredMeters() {
        let rig = makeRig(.notDetermined)
        XCTAssertEqual(rig.source.distanceFilter, 100)
    }

    func testLOCPERM_FixClearsThePreviousNameUntilItsOwnArrives() async {
        let rig = makeRig(.authorizedWhenInUse, names: NameLookupStub([.answer("Alpha"), .suspend]))
        rig.lm.handleUpdate(CLLocation(latitude: 37.30, longitude: -121.90))
        let named = await eventually { rig.lm.currentPlaceName == "Alpha" }
        XCTAssertTrue(named)
        rig.lm.handleUpdate(CLLocation(latitude: 37.33, longitude: -122.00))
        XCTAssertNil(rig.lm.currentPlaceName)
        let parked = await eventually { rig.names.parked == 1 }
        XCTAssertTrue(parked)
        rig.names.release("Beta")
        let renamed = await eventually { rig.lm.currentPlaceName == "Beta" }
        XCTAssertTrue(renamed)
    }

    func testLOCPERM_LateNameForAnOlderFixIsDropped() async {
        let rig = makeRig(.authorizedWhenInUse, names: NameLookupStub([.suspend, .answer("Beta")]))
        rig.lm.handleUpdate(CLLocation(latitude: 37.30, longitude: -121.90))
        let parked = await eventually { rig.names.parked == 1 }
        XCTAssertTrue(parked)
        rig.lm.handleUpdate(CLLocation(latitude: 37.33, longitude: -122.00))
        let named = await eventually { rig.lm.currentPlaceName == "Beta" }
        XCTAssertTrue(named)
        rig.names.release("Alpha")
        let seen = await eventually { rig.names.cancelledSeen.count == 1 }
        XCTAssertTrue(seen)
        await pause(0.1)
        XCTAssertEqual(rig.lm.currentPlaceName, "Beta")
        XCTAssertEqual(rig.names.cancelledSeen, [true], "the older name lookup was cancelled")
    }
}
