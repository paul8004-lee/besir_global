import Foundation
import CoreLocation

/// SPEC-UBERLINK-001 (card t120): the link the trip screen's Open in Uber button opens. Foundation and CoreLocation only:
/// no view, no request, no device location. The link carries the trip's stored destination as the drop-off.
enum UberLink {
    /// The Uber link for a drop-off at `place`, or nil when its coordinate is not valid.
    static func url(for place: Place) -> URL? {
        return nil
    }
}
