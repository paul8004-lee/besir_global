import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// SPEC-FULLHAND-001 (card t101): the rules of the hand path that opens a partner's card by hand. It names no partner, partner id or
/// field key: what a tapped place seeds comes from the kind of the partner's first field, and the glyph of a partner's button comes
/// from the symbol the partner announced.
enum PartnerHand {
    /// The most characters of a place name the card takes as its seed.
    static let seedLimit = 120

    /// Every symbol the hand screens draw by themselves; the partners' own symbols come from the directory.
    static let symbols: [String] = ["checkmark.circle", "calendar.badge.plus", "xmark.circle", "clock.arrow.circlepath",
                                    "arrow.up.forward.square", "circle"]

    /// The name of the tapped place, as the one value the card starts with: the partner's first field, and only when it takes a name
    /// (`text` or `place`). Hidden characters are removed, the name is trimmed and cut at `seedLimit`. A blank name, a first field of
    /// another kind and a partner with no field give nothing. No later field is ever seeded.
    static func seeds(for spec: PartnerSpec, placeName: String) -> [String: AgentFieldValue] {
        guard let first = spec.fields.first, first.kind == .text || first.kind == .place else { return [:] }
        let name = AgentToolbox.sanitized(String(AgentToolbox.sanitized(placeName).prefix(seedLimit)))
        return name.isEmpty ? [:] : [first.key: .text(name)]
    }

    /// The symbol a partner's button draws: the one the partner announced when this device has it, else `circle`.
    static func buttonSymbol(for entry: PartnerEntry) -> String {
        let fallback = "circle"
        guard let symbol = entry.symbol else { return fallback }
        #if canImport(UIKit)
        return UIImage(systemName: symbol) == nil ? fallback : symbol
        #else
        return symbol
        #endif
    }

    /// The history row's estimate line: `Estimate $90.00`. Every price in the app is marked as an estimate.
    static func estimateText(cents: Int) -> String { "" }
}

/// SPEC-FULLHAND-001 (card t101): the one cancel of a partner's request. The button and the toolbox's tool both call it; it names no
/// partner.
enum PartnerCancel {
    enum Outcome: Equatable {
        case cancelled(partner: String), declined(partner: String), unavailable(partner: String), noRecord
    }

    /// The warning both callers show after a cancel that changed nothing.
    static let notCancelledNotice = "Nothing was cancelled."

    @MainActor
    static func run(activityID: UUID, store: Store, records: PartnerRecords, ledger: BudgetLedger,
                    client: PartnerClient) async -> Outcome {
        .noRecord
    }
}

/// One row of the history list: an entry the schedule still holds and the partner request record that made it.
struct PartnerHistoryRow: Identifiable, Equatable {
    /// The entry's id.
    let id: UUID
    /// The entry's current title.
    let title: String
    let start: Date
    let end: Date
    /// The entry's place: the one the partner request chose.
    let place: Place?
    /// The record's estimate in whole cents, when the partner gave one.
    let estimateCents: Int?
    let partnerName: String
}

enum PartnerHistory {
    @MainActor
    static func rows(records: PartnerRecords, store: Store) -> [PartnerHistoryRow] { [] }
}
