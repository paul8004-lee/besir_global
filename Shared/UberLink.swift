import Foundation
import CoreLocation

/// SPEC-UBERLINK-001 (card t120): the link the trip screen's Open in Uber button opens. Foundation and CoreLocation only:
/// no view, no request, no device location. The link carries the trip's stored destination as the drop-off.
enum UberLink {
    /// The Uber link for a drop-off at `place`, or nil when its coordinate is not valid (the map's own check). The query
    /// is `action`, `pickup`, `dropoff[latitude]`, `dropoff[longitude]` and, when the trimmed name is not empty,
    /// `dropoff[nickname]`, in that order; the coordinates have six decimals and a point whatever the locale.
    // @MX:NOTE: [AUTO] Only the trip's stored destination leaves the device; the pickup is left to Uber's own reading
    // of the rider's position.
    static func url(for place: Place) -> URL? {
        guard MapFraming.isValid(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "m.uber.com"
        components.path = "/ul/"
        var items = [
            URLQueryItem(name: "action", value: "setPickup"),
            URLQueryItem(name: "pickup", value: "my_location"),
            URLQueryItem(name: "dropoff[latitude]", value: String(format: "%.6f", place.latitude)),
            URLQueryItem(name: "dropoff[longitude]", value: String(format: "%.6f", place.longitude)),
        ]
        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            items.append(URLQueryItem(name: "dropoff[nickname]", value: name))
        }
        components.queryItems = items
        // URLComponents leaves `+` as it is, and a form decoder reads it as a space; send it as %2B.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
