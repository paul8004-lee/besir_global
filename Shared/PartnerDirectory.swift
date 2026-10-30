import Foundation

/// SPEC-BOOKCARD-001 (card t89): the pure value types and the readers of the partner path. Foundation only. The app names no
/// partner: the directory, the form and the answers below come from the proxy, and every check here is a rule of the grammar.

/// One entry of the directory a proxy lists: who the partner is, how the card is headed and where to ask it.
struct PartnerEntry: Equatable {
    let id: String
    let name: String
    let title: String
    let summary: String
    let route: String
}

/// An entry together with the form it announced: its fields and the kinds of result it will give.
struct PartnerSpec: Equatable {
    let entry: PartnerEntry
    let fields: [PartnerField]
    let results: [PartnerResultSpec]
}

/// A value of a partner's field, typed as the partner's kind needs it on the wire.
enum PartnerValue: Equatable {
    /// A `text` or `place` field, a `time` field (the local date-time text) and the id of a `pick_one` chip.
    case text(String)
    case number(Int)
    case flag(Bool)
}

/// One request: the id made when the card was built and the values of the fields that have one, in the partner's order.
struct PartnerRequest: Equatable {
    struct Item: Equatable {
        let key: String
        let value: PartnerValue
    }

    let requestID: String
    let values: [Item]
}

enum PartnerAnswer: Equatable {
    case confirmed(results: [PartnerResultItem])
    case declined
}

/// Why a partner call did not give an answer. No text of the server's answer is kept for any of them.
enum PartnerFailure: Error, Equatable {
    case notSetUp, offline, tokenRejected, other
}

extension PartnerEntry {
    /// Skeleton: nothing is read yet.
    static func list(from data: Data) -> [PartnerEntry]? { nil }
}

extension PartnerSpec {
    /// Skeleton: nothing is read yet.
    static func form(from data: Data, entry: PartnerEntry) -> PartnerSpec? { nil }
}

extension PartnerAnswer {
    /// Skeleton: nothing is read yet.
    static func answer(from data: Data, spec: PartnerSpec) -> PartnerAnswer? { nil }
}
