import Foundation
import CoreLocation

// SPEC-AGENTPLACE-001: handles, the registry and the lookup types of the place and travel-time tools.
// The model works with app-issued handles (`p1`, `r1`); it never sees or sends a coordinate, a Google id or a duration.

enum AgentPlaces {
    // MARK: Limits and fixed texts (data, not behaviour)

    /// Places kept from one search.
    static let maxResults = 5
    /// Entries kept per kind in the registry; the oldest is evicted first.
    static let registryCap = 30
    /// A route older than this many seconds is unknown (inclusive limit).
    static let routeMaxAge = 15 * 60
    // @MX:NOTE The stored leg mirrors the New Event screen defaults (AddEventView buffer 5, EditCard lead 10); a change
    // there needs a change here (SPEC-AGENTPLACE-001 R13).
    static let legBufferMinutes = 5
    static let legNotifyLeadMinutes = 10
    /// Query length bounds in extended grapheme clusters after sanitizing.
    static let queryMin = 2
    static let queryMax = 80
    /// Caps for text shown to the model or on a card (extended grapheme clusters).
    static let nameLimit = 80
    static let addressLimit = 120
    // @MX:NOTE The one home of the verification line the card mandates; no other file spells it.
    static let verifiedLine = "Verified by Routes"

    /// The name of the device position as a place.
    private static let deviceName = "Current location"
    /// Handles have one to four digits; a fifth would be a different handle format.
    fileprivate static let lastNumber = 9999

    private static let noResults = AgentToolbox.encode([
        "status": "no_results",
        "message": "No places were found. Tell the user and ask what else to search for; do not invent a place."])
    private static let placesUnavailable = AgentToolbox.encode([
        "status": "unavailable",
        "message": "Places cannot be looked up right now. Tell the user it is unavailable."])
    private static let noRoute = AgentToolbox.encode([
        "status": "no_route",
        "message": "No route was found for that trip. Tell the user; do not estimate the travel time."])
    private static let travelUnavailable = AgentToolbox.encode([
        "status": "unavailable",
        "message": "The travel time could not be looked up. Tell the user it is unavailable; do not estimate it."])

    // MARK: Pure helpers

    /// `^p[0-9]{1,4}$`, ASCII digits only.
    static func isPlaceHandle(_ text: String) -> Bool { isHandle(text, prefix: UInt8(ascii: "p")) }

    /// `^r[0-9]{1,4}$`, ASCII digits only.
    static func isRouteHandle(_ text: String) -> Bool { isHandle(text, prefix: UInt8(ascii: "r")) }

    private static func isHandle(_ text: String, prefix: UInt8) -> Bool {
        let bytes = Array(text.utf8)
        guard (2...5).contains(bytes.count), bytes[0] == prefix else { return false }
        return bytes.dropFirst().allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// The place a trip starts from when no origin is named: the manual origin as is, else the current location named
    /// `Current location` with an empty address, else nil.
    static func devicePlace(manual: Place?, current: CLLocationCoordinate2D?) -> Place? {
        if let manual { return manual }
        return current.map { Place(name: deviceName, address: "", latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// `by car`, `by transit`, `on foot` or `by bicycle`.
    static func modePhrase(_ mode: TransportMode) -> String {
        let phrase = mode.titleWithParticle
        return phrase.prefix(1).lowercased() + phrase.dropFirst()
    }

    /// The text rule for a name: sanitizer, cut to `nameLimit`, trimmed again.
    static func displayName(_ text: String) -> String { capped(text, nameLimit) }

    /// The text rule for an address: sanitizer, cut to `addressLimit`, trimmed again.
    static func displayAddress(_ text: String) -> String { capped(text, addressLimit) }

    private static func capped(_ text: String, _ limit: Int) -> String {
        String(AgentToolbox.sanitized(text).prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A route is known for `routeMaxAge` seconds, the limit included.
    static func isFresh(_ route: AgentRoute, now: Date) -> Bool {
        now.timeIntervalSince(route.createdAt) <= TimeInterval(routeMaxAge)
    }

    // MARK: Result encoders

    /// The `search_places` answer for the places Google returned; registers the first `maxResults` of them.
    static func searchOutput(_ places: [Place], registry: inout AgentPlaceRegistry) -> AgentLookupOutput {
        let kept = Array(places.prefix(maxResults))
        guard !kept.isEmpty else { return AgentLookupOutput(result: noResults, showsGoogleData: false) }
        guard let handles = registry.register(kept) else {
            return AgentLookupOutput(result: placesUnavailable, showsGoogleData: false)
        }
        let list: [[String: Any]] = zip(handles, kept).map { handle, place in
            ["place_id": handle, "name": displayName(place.name), "address": displayAddress(place.address)]
        }
        let result = AgentToolbox.encode(["status": "ok", "count": list.count, "places": list])
        return AgentLookupOutput(result: result, showsGoogleData: true)
    }

    /// The `search_places` answer for a search that failed: the places-unavailable text, no place, no Google data.
    static func searchFailure() -> AgentLookupOutput {
        AgentLookupOutput(result: placesUnavailable, showsGoogleData: false)
    }

    /// The `get_travel_time` answer for a route; registers it. `leaveBy` is the app-computed `YYYY-MM-DDTHH:MM`.
    static func travelOutput(_ route: AgentRoute, leaveBy: String?, registry: inout AgentPlaceRegistry) -> AgentLookupOutput {
        guard let handle = registry.register(route) else {
            return AgentLookupOutput(result: travelUnavailable, showsGoogleData: false)
        }
        var object: [String: Any] = [
            "status": "ok", "route_id": handle, "mode": route.mode.rawValue,
            "minutes": roundedMinutes(fromSeconds: route.seconds),
            "origin": displayName(route.origin.name), "destination": displayName(route.destination.name),
            "source": "Google Routes"]
        if let leaveBy { object["leave_by"] = leaveBy }
        return AgentLookupOutput(result: AgentToolbox.encode(object), showsGoogleData: true)
    }

    /// The answer when a lookup gave no duration: no route, or anything else (offline, not set up, cancelled).
    static func travelFailure(_ failure: TravelFailure?) -> AgentLookupOutput {
        AgentLookupOutput(result: failure == .noRoute ? noRoute : travelUnavailable, showsGoogleData: false)
    }
}

/// One Google route as the app keeps it: the exact seconds, both ends, Google's warning strings and when it was made.
struct AgentRoute: Equatable {
    var mode: TransportMode
    var seconds: TimeInterval
    var origin: Place
    var destination: Place
    var warnings: [String]
    var createdAt: Date
}

/// The places and routes the model may point at with a handle. The model never sees a coordinate or a Google id.
struct AgentPlaceRegistry {
    private var places: [(handle: String, place: Place)] = []
    private var routes: [(handle: String, route: AgentRoute)] = []
    private var nextPlace: Int
    private var nextRoute: Int

    /// `nextPlaceNumber` and `nextRouteNumber` let a test start near the four-digit ceiling.
    init(nextPlaceNumber: Int = 1, nextRouteNumber: Int = 1) {
        nextPlace = nextPlaceNumber
        nextRoute = nextRouteNumber
    }

    /// Handles in registration order, oldest first.
    var placeHandles: [String] { places.map(\.handle) }
    var routeHandles: [String] { routes.map(\.handle) }

    /// All or nothing: nil when any place would need a fifth digit. An identical place keeps its handle.
    mutating func register(_ newPlaces: [Place]) -> [String]? {
        var kept = places
        var next = nextPlace
        var handles: [String] = []
        for place in newPlaces {
            if let known = kept.first(where: { $0.place == place }) {
                handles.append(known.handle)
                continue
            }
            guard next <= AgentPlaces.lastNumber else { return nil }
            let handle = "p\(next)"
            next += 1
            kept.append((handle, place))
            handles.append(handle)
        }
        places = Array(kept.suffix(AgentPlaces.registryCap))
        nextPlace = next
        return handles
    }

    /// The handle of a new route, or nil when no handle is left.
    mutating func register(_ route: AgentRoute) -> String? {
        guard nextRoute <= AgentPlaces.lastNumber else { return nil }
        let handle = "r\(nextRoute)"
        nextRoute += 1
        routes = Array((routes + [(handle, route)]).suffix(AgentPlaces.registryCap))
        return handle
    }

    func place(_ handle: String) -> Place? {
        places.first { $0.handle == handle }?.place
    }

    /// Nil when unknown or older than `AgentPlaces.routeMaxAge` at `now`.
    func route(_ handle: String, now: Date) -> AgentRoute? {
        guard let found = routes.first(where: { $0.handle == handle })?.route,
              AgentPlaces.isFresh(found, now: now) else { return nil }
        return found
    }

    /// Forgets the entries; the counters keep counting up.
    mutating func clear() {
        places = []
        routes = []
    }
}

/// What a lookup tool hands back: the result text for the model and whether Google data was shown (only for `ok`).
struct AgentLookupOutput {
    let result: String
    let showsGoogleData: Bool
}

/// A network lookup the session runs as the request in flight (design.md section 3).
struct AgentLookup {
    let run: @MainActor () async -> AgentLookupOutput
}
