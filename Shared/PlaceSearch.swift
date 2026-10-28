import Foundation
import CoreLocation

/// Place search through Google Places (New), by way of the Worker route `/places`.
/// This is a thin caller: `GooglePlaces` builds the request and parses the answer, and any failure gives an empty list.
struct PlaceSearch {
    /// Upper bound on the candidates one place search shows in a list.
    static let maxSuggestions = 5

    let config: AppConfig
    var transport: GooglePlaces.Transport = GooglePlaces.urlSession
    /// Where a request that was sent is noted. It never changes what a search returns.
    var connections: ConnectionLog = ConnectionLog.shared

    /// The words a nearby search sends to Google: the keyword, else the category word, else `restaurants`.
    static func nearbyTerm(category: MealCategoryFilter?, keyword: String?) -> String {
        let term = keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return term.isEmpty ? (category?.categoryWord ?? "restaurants") : term
    }

    private static func results(_ count: Int) -> String { count == 1 ? "1 result" : "\(count) results" }

    /// One packet for a request that was sent. A cancelled search records nothing.
    private func note(_ summary: String, _ status: ConnectionStatus) {
        guard !Task.isCancelled else { return }
        connections.record(from: .besir, to: .googlePlaces, kind: .placeSearch, summary: summary, status: status)
    }

    /// Typed search. A trimmed query under 2 characters sends nothing.
    /// - `center`: the device or base location, used as a bias circle; nil sends no bias.
    // @MX:ANCHOR fan_in 5 - add event, activity card, activity detail, favorites and the place field all call this
    // @MX:REASON the failure contract is an empty list: no proxy, a bad status, a thrown error or an undecodable body
    func search(_ query: String, near center: CLLocationCoordinate2D?) async -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let request = GooglePlaces.searchRequest(query: trimmed, near: center, config: config) else { return [] }
        guard let data = await GooglePlaces.fetch(request, transport: transport) else {
            note("Search failed", .failed)
            return []
        }
        let places = GooglePlaces.parsePlaces(data)
        note("Searched “\(trimmed)” · \(Self.results(places.count))", .ok)
        return places
    }

    /// Restaurants and cafes around a point, nearest first by default.
    /// - `keyword`: a specific dish or kind of shop; empty or nil falls back to the category word.
    /// - `category`: nil searches without a place type (free-text search).
    /// An empty list when the proxy is missing or anything fails; the caller shows its empty state.
    func nearbyPlaces(category: MealCategoryFilter?,
                      keyword: String? = nil,
                      near center: CLLocationCoordinate2D,
                      radiusMeters: Int = 1000,
                      sort: NearbySort = .distance,
                      limit: Int = 5) async -> [NearbyPlace] {
        guard let request = GooglePlaces.nearbyRequest(category: category, keyword: keyword, near: center,
                                                       radiusMeters: radiusMeters, config: config) else { return [] }
        guard let data = await GooglePlaces.fetch(request, transport: transport) else {
            note("Search failed", .failed)
            return []
        }
        let found = GooglePlaces.nearbyResults(from: data, near: center, radiusMeters: radiusMeters,
                                               sort: sort, limit: limit)
        note("Nearby \(Self.nearbyTerm(category: category, keyword: keyword)) · \(Self.results(found.count))", .ok)
        return found
    }
}
