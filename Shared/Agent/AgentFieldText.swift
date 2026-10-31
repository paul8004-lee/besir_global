import Foundation

/// The neutral home of the field-card text helpers every partner's card reads (SPEC-DELIVERYCARD-001, card t91): copied from
/// `AgentDelivery` with their bodies unchanged, so the common path keeps its helpers when the delivery-only file is deleted.
/// Foundation only, like `AgentPartner`; the toolbox is named nowhere here.
enum AgentFieldText {
    /// The most characters a text field holds when a field names no limit of its own.
    static let maxLength = 120

    /// Per keystroke: removes control, format, line-separator and paragraph-separator characters and cuts at `limit` Unicode
    /// scalars. It never trims, so a space typed after `12` stays and `12 Example Street` can be typed.
    static func cleanedTyped(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var kept = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default:
                guard kept < limit else { return String(scalars) }
                scalars.append(scalar)
                kept += 1
            }
        }
        return String(scalars)
    }

    /// The one trim, taken at Confirm on the snapshot of the editors. Nil when the text is blank.
    static func snapshotText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The text of a place: its address if that is, cleaned, 1 to 120 scalars; else its name on the same rule; else nil. Nothing
    /// is cut, so no half address is sent.
    static func placeText(_ place: Place) -> String? {
        for candidate in [place.address, place.name] {
            let clean = AgentToolbox.sanitized(candidate)
            if (1...maxLength).contains(clean.unicodeScalars.count) { return clean }
        }
        return nil
    }
}
