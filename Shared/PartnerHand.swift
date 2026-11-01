import Foundation

/// SPEC-FULLHAND-001 (card t101): the rules of the hand path that opens a partner's card by hand.
enum PartnerHand {
    static let symbols: [String] = []

    static func seeds(for spec: PartnerSpec, placeName: String) -> [String: AgentFieldValue] { [:] }

    static func buttonSymbol(for entry: PartnerEntry) -> String { "" }
}
