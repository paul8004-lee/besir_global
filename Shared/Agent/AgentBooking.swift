import Foundation

/// The title limit, the suffix and the sent-name rule that the delivery tools still read (SPEC-BOOKCARD-001 plan 1.1: a neutral
/// home for them is card t93's). The booking-only helpers are gone; the partner path has its own in `AgentPartner`.
enum AgentBooking {
    static let maxTitle = 80
    static let maxSentScalars = 80
    static let simulatedSuffix = " (Simulated)"

    /// The name that leaves the app: the sanitized place name, cut to 80 Unicode scalars and trimmed. The Worker counts
    /// code points, so a cut by Characters could let a name with combining marks through and fail there.
    static func sentName(_ place: Place) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: AgentToolbox.sanitized(place.name).unicodeScalars.prefix(maxSentScalars))
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
