import Foundation

/// SPEC-BOOKING-001: the pure helpers of the `request_booking` tool, so what decides is testable without the toolbox.
enum AgentBooking {
    static let maxPartySize = 12
    /// A booked table lasts 90 minutes.
    static let entryDuration: TimeInterval = 90 * 60
    static let maxTitle = 80
    static let maxSentScalars = 80
    static let simulatedSuffix = " (Simulated)"

    // MARK: Fixed result texts

    static let appliedMessage = "Tell the user the table is booked with a simulated partner, and give the reservation code. Do not describe it as a real reservation."
    static let declinedMessage = "The simulated partner had no table. Tell the user nothing was booked, and ask what they want to do next."
    static let unavailableMessage = "The simulated booking could not be made. Tell the user nothing was booked."
    static let unavailableNotice = "The reservation could not be made. Nothing was added."

    // MARK: Arguments

    /// 1 to 4 ASCII digits whose value is 1 to 12. No sign, space or separator; leading zeros are allowed (`0002` is 2).
    static func parsePartySize(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard (1...4).contains(bytes.count), bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        let value = bytes.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        return (1...maxPartySize).contains(value) ? value : nil
    }

    /// The name that leaves the app: the sanitized place name, cut to 80 Unicode scalars and trimmed. The Worker counts
    /// code points, so a cut by Characters could let a name with combining marks through and fail there.
    static func sentName(_ place: Place) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: AgentToolbox.sanitized(place.name).unicodeScalars.prefix(maxSentScalars))
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Card and entry

    /// `Reserve a table`, the place, the start, `Table for N` and the partner line, in this order.
    static func cardLines(placeName: String, start: String, partySize: Int) -> [String] {
        ["Reserve a table", placeName, start, "Table for \(partySize)", "\(BookingClient.partnerName) - Simulated"]
    }

    /// `Table for N - <place> (Simulated)`, at most 80 characters. When the place has to be cut, the name part ends with
    /// `…` and the suffix stays.
    static func entryTitle(partySize: Int, placeName: String) -> String {
        let head = "Table for \(partySize) - "
        let whole = head + placeName + simulatedSuffix
        guard whole.count > maxTitle else { return whole }
        let room = maxTitle - head.count - simulatedSuffix.count - 1
        let cut = String(placeName.prefix(max(room, 0))).trimmingCharacters(in: .whitespacesAndNewlines)
        return head + cut + "…" + simulatedSuffix
    }
}
