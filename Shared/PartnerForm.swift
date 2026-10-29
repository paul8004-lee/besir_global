import Foundation

/// The word a partner uses for the kind of one field of its order form (SPEC-CHOICECARD-001 REQ-002).
enum PartnerFieldKind: String, CaseIterable, Equatable {
    case text, place, time
    case pickOne = "pick_one"
    case onOff = "on_off"

    /// A `pick_one` or `on_off` field carries the words of its chips; no other kind does.
    var hasOptions: Bool { self == .pickOne || self == .onOff }
}

/// One chip of a `pick_one` or `on_off` field: the partner's id and the words the chip shows.
struct PartnerOption: Equatable {
    let id: String
    let label: String
}

/// One field of the form a partner names for an action. Foundation only: it knows nothing of the app or of any one partner.
struct PartnerField: Equatable {
    let key: String
    let kind: PartnerFieldKind
    let label: String
    /// Empty for every kind but `pick_one` and `on_off`.
    let options: [PartnerOption]
}

enum PartnerResultKind: String, Equatable {
    case time, money, text
}

/// One item of the result list a partner sends after an action: a name and a value of one kind (REQ-006).
struct PartnerResultItem: Equatable {
    enum Value: Equatable {
        /// A real local date-time, `yyyy-MM-dd'T'HH:mm`.
        case time(String)
        /// A whole number of cents.
        case money(Int)
        case text(String)
    }

    let name: String
    let value: Value

    var kind: PartnerResultKind {
        switch value {
        case .time: return .time
        case .money: return .money
        case .text: return .text
        }
    }
}

/// The wire rules of the field list and the result list, read from a parsed JSON value. Every reader returns nil for a list
/// that breaks any rule, so one defect makes the whole list unusable.
enum PartnerForm {
    static func fields(from value: Any?) -> [PartnerField]? { nil }

    static func results(from value: Any?) -> [PartnerResultItem]? { nil }
}

extension Array where Element == PartnerResultItem {
    /// The cents of the first `money` item.
    var moneyCents: Int? { nil }

    /// The text of the first `time` item.
    var arrival: String? { nil }
}
