import XCTest
import CoreLocation
@testable import besir

// SPEC-AGENTPLACE-001: the shared harness of the place and travel-time tool tests. Nothing here touches the network:
// a toolbox over an empty Store, stub transports for Places and Routes, a movable clock, and a transport a test
// releases by hand (for lookups that must stay in flight).

/// Anchor class so the fixtures are found through the test bundle.
final class PlaceFixtureToken {}

/// Values a real request would carry. Tests prove they exist before they scan for their absence.
enum PlaceSentinel {
    static let host = "sentinel-host-0003.invalid"
    static let token = "SENTINEL-TOKEN-0003"
    static let config = AppConfig(kakaoJsKey: "", proxyBaseURL: "https://" + host, appToken: token)
    static let unconfigured = AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: "")
}

/// Fixtures and fixed values of the group.
enum PlaceFixture {
    /// The device position as the toolbox names it: 37.7749, -122.4194.
    static let device = Place(name: "Current location", address: "", latitude: 37.7749, longitude: -122.4194)

    static func data(_ name: String, ext: String = "json") -> Data {
        guard let url = Bundle(for: PlaceFixtureToken.self).url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            XCTFail("missing fixture \(name).\(ext)")
            return Data()
        }
        return data
    }

    static func text(_ name: String) -> String {
        String(decoding: data(name), as: UTF8.self)
    }

    /// The places a fixture holds as the production parser reads them: the original values the registry must keep.
    static func places(_ name: String) -> [Place] {
        GooglePlaces.parsePlaces(data(name))
    }

    /// A Routes answer holding one route of `seconds` and, when given, warning strings.
    static func routes(seconds: Int, warnings: [String] = []) -> Data {
        var route: [String: Any] = ["duration": "\(seconds)s", "distanceMeters": 1000]
        if !warnings.isEmpty { route["warnings"] = warnings }
        return (try? JSONSerialization.data(withJSONObject: ["routes": [route]])) ?? Data()
    }

    /// A distinct invented place, for tests that fill the registry.
    static func bulkPlace(_ index: Int) -> Place {
        Place(name: "Bulk Place \(index)", address: "\(index) Bulk Street, Exampleton, EX 94103, USA",
              latitude: 37.0 + Double(index) / 1000, longitude: -122.0 - Double(index) / 1000)
    }

    /// A route record for registry tests.
    static func route(to destination: Place, mode: TransportMode = .transit, seconds: TimeInterval = 1053,
                      warnings: [String] = [], at date: Date = TestClock.now) -> AgentRoute {
        AgentRoute(mode: mode, seconds: seconds, origin: device, destination: destination, warnings: warnings, createdAt: date)
    }
}

/// The exact texts of spec.md section 2.2 and 2.3, spelled once for the tests.
enum PlaceText {
    static let queryMissing = "Ask the user what place to look for, then call search_places again. Do not guess it."
    static let queryLong = "Call search_places again with a shorter query, or ask the user for a shorter one."
    static let findPlace = "Call search_places to find the place, then call get_travel_time again with the place_id it returns."
    static let mode = "Call get_travel_time again with mode set to how the user wants to travel, or ask the user."
    static let originPlace = "Call search_places to find the starting place, then call get_travel_time again with its place_id as origin_place_id, or omit origin_place_id to start from the user's current location."
    static let arriveForm = "Call get_travel_time again with arrive_by as a local date-time in the form YYYY-MM-DDTHH:MM, or ask the user."
    static let arriveWindow = "Ask the user to confirm the date, then call get_travel_time again. The arrival time must be within the past day or the next 366 days."
    static let noOrigin = "Ask the user to turn on location access or to name a starting place, search for it with search_places, then call get_travel_time again with its place_id as origin_place_id."
    static let createPlace = "Call search_places to find the place, then call create_activity again with the place_id it returns, or omit place_id."
    static let createRoute = "Call get_travel_time again for this place and mode, then call create_activity again with the route_id it returns, or omit route_id."
    static let createMismatch = "Call create_activity again with a place_id that matches the route_id, or omit place_id."
    static let routeExpired = "Call get_travel_time again, then call create_activity again with the new route_id."
    static let expiredNotice = "The travel time is out of date. Nothing was added."

    static let noResults: [String: String] = [
        "status": "no_results",
        "message": "No places were found. Tell the user and ask what else to search for; do not invent a place."]
    static let placesUnavailable: [String: String] = [
        "status": "unavailable",
        "message": "Places cannot be looked up right now. Tell the user it is unavailable."]
    static let noRoute: [String: String] = [
        "status": "no_route",
        "message": "No route was found for that trip. Tell the user; do not estimate the travel time."]
    static let travelUnavailable: [String: String] = [
        "status": "unavailable",
        "message": "The travel time could not be looked up. Tell the user it is unavailable; do not estimate it."]
    static let interrupted: [String: String] = [
        "status": "unavailable",
        "message": "The lookup was interrupted. Call the tool again if the user still wants it."]
}

/// Reads of the request bodies the stub transports recorded.
enum PlaceBody {
    static func json(_ request: URLRequest?) -> NSDictionary? {
        guard let data = request?.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? NSDictionary
    }

    static func text(_ request: URLRequest?) -> String {
        String(decoding: request?.httpBody ?? Data(), as: UTF8.self)
    }

    static func response(_ status: Int, for request: URLRequest) -> URLResponse {
        let url = request.url ?? URL(fileURLWithPath: "/")
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) ?? URLResponse()
    }

    /// `origin` or `destination` of a Routes body.
    static func waypoint(_ body: NSDictionary?, _ key: String) -> (latitude: Double, longitude: Double)? {
        guard let point = body?[key] as? NSDictionary,
              let location = point["location"] as? NSDictionary,
              let latLng = location["latLng"] as? NSDictionary,
              let latitude = (latLng["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (latLng["longitude"] as? NSNumber)?.doubleValue else { return nil }
        return (latitude, longitude)
    }

    /// The centre of the bias circle of a Places body.
    static func biasCenter(_ body: NSDictionary?) -> (latitude: Double, longitude: Double)? {
        guard let bias = body?["locationBias"] as? NSDictionary,
              let circle = bias["circle"] as? NSDictionary,
              let center = circle["center"] as? NSDictionary,
              let latitude = (center["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (center["longitude"] as? NSNumber)?.doubleValue else { return nil }
        return (latitude, longitude)
    }
}

/// A counter two stub handlers can share across threads.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// The number of earlier calls, then counts up.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

/// Ready-made stub transports.
enum PlaceStubs {
    static func places(_ fixture: String, status: Int = 200) -> PlacesTransportStub {
        .answering(status: status, with: PlaceFixture.data(fixture))
    }

    /// Routes: car and transit answer `routes-drive` (1053 s), walk and bicycle answer their warning fixtures.
    static func routesByMode() -> RoutesTransportStub {
        let drive = PlaceFixture.data("routes-drive")
        let walk = PlaceFixture.data("routes-walk-warnings")
        let bicycle = PlaceFixture.data("routes-bicycle-warnings")
        return RoutesTransportStub { request in
            let mode = PlaceBody.json(request)?["travelMode"] as? String
            let data: Data
            switch mode {
            case "WALK": data = walk
            case "BICYCLE": data = bicycle
            default: data = drive
            }
            return (data, PlaceBody.response(200, for: request))
        }
    }

    /// Routes: every request answers the given fixture with the given status.
    static func routes(_ fixture: String, status: Int = 200) -> RoutesTransportStub {
        .answering(status: status, with: PlaceFixture.data(fixture))
    }

    /// Routes: the nth request answers `seconds[n]` (the last value repeats).
    static func routesSequence(_ seconds: [Int]) -> RoutesTransportStub {
        let counter = LockedCounter()
        return RoutesTransportStub { request in
            let index = counter.next()
            let value = seconds.isEmpty ? 0 : seconds[min(index, seconds.count - 1)]
            return (PlaceFixture.routes(seconds: value), PlaceBody.response(200, for: request))
        }
    }

    /// Routes: every request answers one route of `seconds` with the given warnings.
    static func routes(seconds: Int, warnings: [String] = []) -> RoutesTransportStub {
        .answering(with: PlaceFixture.routes(seconds: seconds, warnings: warnings))
    }
}

/// A transport that holds every request until the test releases it, so a lookup stays in flight on demand.
/// It ignores task cancellation on purpose, like `FakeTransport`: a late answer must still arrive.
final class HoldableTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private var waiting: [CheckedContinuation<(Data, URLResponse), Error>] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var callCount: Int { requests.count }

    /// Requests received and not yet released.
    var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting.count
    }

    var places: GooglePlaces.Transport {
        { [self] request in try await hold(request) }
    }

    var routes: GoogleRoutes.Transport {
        { [self] request in try await hold(request) }
    }

    private func hold(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(request, continuation)
        }
    }

    private func enqueue(_ request: URLRequest, _ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        seen.append(request)
        waiting.append(continuation)
        lock.unlock()
    }

    private func dequeue() -> CheckedContinuation<(Data, URLResponse), Error>? {
        lock.lock()
        defer { lock.unlock() }
        return waiting.isEmpty ? nil : waiting.removeFirst()
    }

    /// Answers the oldest held request. False when nothing is held.
    @discardableResult
    func release(with data: Data, status: Int = 200) -> Bool {
        guard let continuation = dequeue() else { return false }
        let url = URL(string: "https://\(PlaceSentinel.host)/held") ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) ?? URLResponse()
        continuation.resume(returning: (data, response))
        return true
    }

    /// Fails the oldest held request. False when nothing is held.
    @discardableResult
    func fail(with error: Error) -> Bool {
        guard let continuation = dequeue() else { return false }
        continuation.resume(throwing: error)
        return true
    }

    /// Waits (yielding, bounded) until `count` requests have arrived.
    func waitForRequests(_ count: Int) async -> Bool {
        for _ in 0..<5000 {
            if callCount >= count { return true }
            await Task.yield()
        }
        return callCount >= count
    }
}

/// The device position a test can change after the toolbox was built.
@MainActor
final class DeviceBox {
    var place: Place?

    init(_ place: Place?) {
        self.place = place
    }
}

extension AgentToolOutcome {
    var lookup: AgentLookup? {
        if case .lookup(let l) = self { return l }
        return nil
    }
    var isLookup: Bool { lookup != nil }
}

/// What a tool call came to once a lookup has been run: a result text, a card, or a finished lookup.
struct PlaceReply {
    let text: String?
    let card: AgentCard?
    let isLookup: Bool
    let showsGoogleData: Bool

    var json: [String: Any]? { text.flatMap(TestClock.object) }
    var status: String? { json?["status"] as? String }
    var message: String? { json?["message"] as? String }
    /// The gate did not refuse: a lookup ran or a card was built.
    var accepted: Bool { isLookup || card != nil }
    /// The `places` array of a search answer.
    var places: [[String: Any]] { (json?["places"] as? [[String: Any]]) ?? [] }
}

/// A toolbox over an empty Store with stub transports, a movable clock and a changeable device position.
@MainActor
struct PlaceRig {
    nonisolated static let start = "2026-10-28T19:00"
    nonisolated static let end = "2026-10-28T20:00"

    let store: Store
    let clock: MutableClock
    let places: PlacesTransportStub
    let routes: RoutesTransportStub
    let device: DeviceBox
    let tools: AgentToolbox

    init(places: PlacesTransportStub = PlaceStubs.places("places-search-three"),
         routes: RoutesTransportStub = PlaceStubs.routesByMode(),
         device: Place? = PlaceFixture.device,
         routesConfig: AppConfig = PlaceSentinel.config,
         now: String = TestClock.nowString) {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let clock = MutableClock(now: TestClock.date(now))
        let box = DeviceBox(device)
        let placeTransport = places.transport
        let routeTransport = routes.transport
        self.store = store
        self.clock = clock
        self.places = places
        self.routes = routes
        self.device = box
        tools = AgentToolbox(store: store, now: { clock.now }, timeZone: { clock.zone },
                             deviceOrigin: { box.place },
                             places: { PlaceSearch(config: PlaceSentinel.config, transport: placeTransport) },
                             directions: { DirectionsService(config: routesConfig, transport: routeTransport) })
    }

    /// A rig whose place search answers the hostile fixture.
    static func hostile() -> PlaceRig {
        PlaceRig(places: PlaceStubs.places("agentplace-places-hostile"))
    }

    // MARK: Calls

    func call(_ name: String, _ args: [String: Any]) -> AgentToolOutcome {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return tools.handle(name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    /// Calls a tool and, when it returned a lookup, runs it to the end.
    func run(_ name: String, _ args: [String: Any]) async -> PlaceReply {
        switch call(name, args) {
        case .result(let text):
            return PlaceReply(text: text, card: nil, isLookup: false, showsGoogleData: false)
        case .card(let card):
            return PlaceReply(text: nil, card: card, isLookup: false, showsGoogleData: false)
        case .lookup(let lookup):
            let output = await lookup.run()
            return PlaceReply(text: output.result, card: nil, isLookup: true, showsGoogleData: output.showsGoogleData)
        }
    }

    func search(_ query: String) async -> PlaceReply {
        await run("search_places", ["query": query])
    }

    func travel(_ place: String, _ mode: String = "transit", origin: String? = nil, arriveBy: String? = nil) async -> PlaceReply {
        var args: [String: Any] = ["place_id": place, "mode": mode]
        if let origin { args["origin_place_id"] = origin }
        if let arriveBy { args["arrive_by"] = arriveBy }
        return await run("get_travel_time", args)
    }

    func create(place: String? = nil, route: String? = nil, title: String = "Team sync",
                start: String = PlaceRig.start, end: String = PlaceRig.end) -> AgentToolOutcome {
        var args: [String: Any] = ["title": title, "start": start, "end": end]
        if let place { args["place_id"] = place }
        if let route { args["route_id"] = route }
        return call("create_activity", args)
    }

    /// Search for "cafe" (p1 Example Cafe, p2 Example Cafe elsewhere, p3 Sample Noodle House), then a transit route
    /// to p1 (r1, 1053 s) and a walk route to p1 (r2, 1200 s with two warnings).
    @discardableResult
    func seedBasics() async -> [PlaceReply] {
        let found = await search("cafe")
        let transit = await travel("p1", "transit")
        let walk = await travel("p1", "walk")
        XCTAssertEqual(tools.registry.placeHandles, ["p1", "p2", "p3"], "seed: the search registered three places")
        XCTAssertEqual(tools.registry.routeHandles, ["r1", "r2"], "seed: the two trips registered two routes")
        return [found, transit, walk]
    }

    /// A byte-for-byte picture of everything a tool could change.
    var snapshot: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let a = (try? enc.encode(store.activities)) ?? Data()
        let e = (try? enc.encode(store.events)) ?? Data()
        return String(decoding: a, as: UTF8.self) + "|" + String(decoding: e, as: UTF8.self)
    }
}

// MARK: - Session helpers (M1b)

/// Scripted model turns that call the new tools. The arguments are the JSON a model would send.
enum PlaceTurns {
    static func arguments(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func searchCall(_ query: String = "cafe", id: String) -> AgentItem {
        Turns.call("search_places", arguments(["query": query]), id: id)
    }

    static func travelCall(_ place: String = "p1", mode: String = "transit", id: String) -> AgentItem {
        Turns.call("get_travel_time", arguments(["place_id": place, "mode": mode]), id: id)
    }

    static func createCall(place: String? = nil, route: String? = nil, id: String) -> AgentItem {
        var args: [String: Any] = ["title": "Team sync", "start": PlaceRig.start, "end": PlaceRig.end]
        if let place { args["place_id"] = place }
        if let route { args["route_id"] = route }
        return Turns.call("create_activity", arguments(args), id: id)
    }

    static func search(_ query: String = "cafe", id: String) -> AgentTurn {
        Turns.turn(searchCall(query, id: id))
    }

    static func travel(_ place: String = "p1", mode: String = "transit", id: String) -> AgentTurn {
        Turns.turn(travelCall(place, mode: mode, id: id))
    }

    static func create(place: String? = nil, route: String? = nil, id: String) -> AgentTurn {
        Turns.turn(createCall(place: place, route: route, id: id))
    }
}

/// A session over a place-ready toolbox (empty Store, fixed clock, stub or holdable transports) and a scripted model.
@MainActor
struct PlaceSessionRig {
    let store: Store
    let clock: MutableClock
    let device: DeviceBox
    let tools: AgentToolbox
    let fake: FakeTransport
    let session: AgentSession
    let placesStub: PlacesTransportStub
    let routesStub: RoutesTransportStub
    /// When given, every Places and Routes request is held here until the test releases it.
    let hold: HoldableTransport?

    init(_ steps: [FakeTransport.Step] = [],
         hold: HoldableTransport? = nil,
         places: PlacesTransportStub = PlaceStubs.places("places-search-three"),
         routes: RoutesTransportStub = PlaceStubs.routesByMode(),
         device: Place? = PlaceFixture.device) {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let clock = MutableClock(now: TestClock.date(TestClock.nowString))
        let box = DeviceBox(device)
        let placeTransport: GooglePlaces.Transport = hold?.places ?? places.transport
        let routeTransport: GoogleRoutes.Transport = hold?.routes ?? routes.transport
        let toolbox = AgentToolbox(store: store, now: { clock.now }, timeZone: { clock.zone },
                                   deviceOrigin: { box.place },
                                   places: { PlaceSearch(config: PlaceSentinel.config, transport: placeTransport) },
                                   directions: { DirectionsService(config: PlaceSentinel.config, transport: routeTransport) })
        let transport = FakeTransport(steps)
        self.store = store
        self.clock = clock
        self.device = box
        tools = toolbox
        fake = transport
        session = AgentSession(toolbox: toolbox, transport: transport)
        placesStub = places
        routesStub = routes
        self.hold = hold
    }

    /// Sends a message and waits until nothing is in flight. Never use it while a lookup or a model request is held.
    func say(_ text: String) async {
        session.send(text)
        await session.settle()
    }

    /// Runs one `search_places` lookup straight through the toolbox (outside the session), so the registry holds
    /// places without the session having seen an `ok` result. False when the toolbox did not answer with a lookup.
    func seedPlaces(_ query: String = "cafe") async -> Bool {
        guard case .lookup(let lookup) = tools.handle(name: "search_places", arguments: PlaceTurns.arguments(["query": query])) else {
            return false
        }
        _ = await lookup.run()
        return true
    }

    /// The statuses of the tool results the chat log recorded, in order.
    var resultStatuses: [String] {
        session.entries.compactMap { if case .result(let status) = $0.kind { return status } else { return nil } }
    }

    /// How many attribution rows the log holds.
    var attributionCount: Int {
        session.entries.filter { if case .attribution = $0.kind { return true } else { return false } }.count
    }

    /// Every text of the history, one per line (user text, message text, call name and arguments, results).
    var historyText: String {
        session.history.map { entry -> String in
            switch entry {
            case .user(let text): return text
            case .callOutput(_, let result): return result
            case .assistant(let items, _):
                return items.map { item -> String in
                    switch item {
                    case .message(let text, _): return text
                    case .functionCall(_, let name, let arguments, _): return "\(name ?? "") \(arguments)"
                    case .reasoning: return ""
                    }
                }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    /// Every text of the chat log, one per entry (a card is its lines).
    var logText: String {
        session.entries.map { entry -> String in
            switch entry.kind {
            case .user(let text), .assistant(let text), .result(let text), .notice(let text), .error(let text): return text
            case .tool(let name, let arguments): return "\(name) \(arguments)"
            case .card(let card): return card.lines.joined(separator: "\n")
            case .attribution: return "ATTRIBUTION"
            }
        }.joined(separator: "\n")
    }

    /// Releases whatever a test left held and waits (bounded), so no task of the session outlives the test.
    func finish() async {
        for _ in 0..<4 {
            if let hold { while hold.release(with: Data()) {} }
            for number in 1...12 { fake.release(number, .failure(CancellationError())) }
            for _ in 0..<20 { await Task.yield() }
        }
        _ = await eventually { !session.isWaiting }
    }
}
