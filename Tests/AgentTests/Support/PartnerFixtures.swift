import Foundation
@testable import besir

extension PartnerField {
    /// The delivery partner's order form as its options answer lists it (SPEC-CHOICECARD-001 REQ-002): the arrival, the delivery
    /// place and the card, whose options are `cards`.
    static func delivery(cards: [DeliveryCard]) -> [PartnerField] {
        [PartnerField(key: "arrive_at", kind: .time, label: "Arrival", options: []),
         PartnerField(key: "address", kind: .place, label: "Delivery place", options: []),
         PartnerField(key: "card_id", kind: .pickOne, label: "Pay with",
                      options: cards.map { PartnerOption(id: $0.id, label: $0.label) })]
    }
}
