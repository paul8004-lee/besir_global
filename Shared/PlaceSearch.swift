import Foundation
import CoreLocation

/// Place search through Google Places (New), by way of the Worker route `/places`.
/// This is a thin caller: `GooglePlaces` builds the request and parses the answer, and any failure gives an empty list.
struct PlaceSearch {
    /// Upper bound on the candidates one place search shows in a list.
    static let maxSuggestions = 5

    let config: AppConfig
    var transport: GooglePlaces.Transport = GooglePlaces.urlSession

    /// Typed search. A trimmed query under 2 characters sends nothing.
    /// - `center`: the device or base location, used as a bias circle; nil sends no bias.
    // @MX:ANCHOR fan_in 5 - add event, activity card, activity detail, favorites and the place field all call this
    // @MX:REASON the failure contract is an empty list: no proxy, a bad status, a thrown error or an undecodable body
    func search(_ query: String, near center: CLLocationCoordinate2D?) async -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let request = GooglePlaces.searchRequest(query: trimmed, near: center, config: config),
              let data = await GooglePlaces.fetch(request, transport: transport) else { return [] }
        return GooglePlaces.parsePlaces(data)
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
                                                       radiusMeters: radiusMeters, config: config),
              let data = await GooglePlaces.fetch(request, transport: transport) else { return [] }
        return GooglePlaces.nearbyResults(from: data, near: center, radiusMeters: radiusMeters,
                                          sort: sort, limit: limit)
    }
}
