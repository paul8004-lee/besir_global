import Foundation

/// SPEC-CHOICECARD-001 (card t86): the field-card model. It draws an edit card from a list of field seeds and keeps the value
/// and the source of every field. It knows no session, no toolbox and no view, so another scene can draw the same card.

/// The kind of one field, as the partner's form names it (`PartnerFieldKind`) or as the app's own row says it.
enum AgentFieldKind: Equatable {
    case text, place, time, pickOne, onOff

    /// The five wire words; nil for any other word.
    init?(wire: String) {
        return nil
    }
}

/// Where the value of a field came from. `entered` is the state after the user changed the value on the card.
enum AgentFieldSource: Equatable {
    case stated, inferred, blank, entered
}

enum AgentFieldValue: Equatable {
    case text(String)
    case place(Place)
    case time(Date)
    /// The id of the chosen chip of a `pick_one` field.
    case option(String)
    /// The chosen side of an `on_off` field.
    case flag(Bool)
}

/// One chip of a `pick_one` or `on_off` field.
struct AgentFieldOption: Equatable {
    let id: String
    let label: String
}

struct AgentFieldSpec: Equatable {
    let key: String
    let kind: AgentFieldKind
    let label: String
    /// `pick_one`: the partner's 1 to 4 chips. `on_off`: the two chips, the words being the field's own.
    var options: [AgentFieldOption] = []
    /// Text only: the most characters the field holds.
    var limit: Int?

    init(key: String, kind: AgentFieldKind, label: String, options: [AgentFieldOption] = [], limit: Int? = nil) {
        self.key = key
        self.kind = kind
        self.label = label
        self.options = options
        self.limit = limit
    }

    /// The seed of a field the partner named.
    init?(_ field: PartnerField) {
        return nil
    }

    /// An `on_off` field whose two chips read `on` and `off`.
    static func onOff(key: String, label: String, on: String, off: String) -> AgentFieldSpec {
        AgentFieldSpec(key: key, kind: .onOff, label: label)
    }
}

indirect enum AgentFieldRow {
    /// A read-only row.
    case line(String)
    case field(AgentFieldSpec, value: AgentFieldValue?, source: AgentFieldSource)
    /// An `on_off` field that owns rows shown only while it is on.
    case switchField(AgentFieldSpec, value: AgentFieldValue?, source: AgentFieldSource, dependents: [AgentFieldRow])
}

@MainActor final class AgentFieldCard: ObservableObject {
    struct Snapshot: Equatable {
        struct Entry: Equatable {
            let key: String
            let value: AgentFieldValue?
            let source: AgentFieldSource
        }

        let entries: [Entry]

        func entry(_ key: String) -> Entry? { nil }
        func text(_ key: String) -> String? { nil }
        func date(_ key: String) -> Date? { nil }
        func option(_ key: String) -> String? { nil }
        func flag(_ key: String) -> Bool? { nil }
    }

    let header: String
    @Published private(set) var card: EditCard
    private(set) var isFrozen = false

    init(header: String, rows: [AgentFieldRow], favorites: [FavoritePlace], search: @escaping @MainActor (String) async -> [Place],
         now: @escaping () -> Date) {
        self.header = header
        card = EditCard(fields: [])
    }

    var actions: EditCardActions {
        EditCardActions(chooseValue: { _, _ in }, rechooseTimeBasis: { _, _ in }, chooseTime: { _, _, _ in false },
                        choosePlace: { _, _ in }, searchPlaces: { _, _ in }, submitCustom: { _, _ in false }, confirm: {})
    }

    var isReady: Bool { false }
    var values: Snapshot { Snapshot(entries: []) }
    var lines: [String] { [] }

    func field(_ key: String) -> EditField? { nil }
    func source(of key: String) -> AgentFieldSource { .blank }
    func freeze() {}

    @discardableResult func chooseOption(_ key: String, _ value: String) -> Bool { false }
    @discardableResult func choosePlace(_ key: String, _ place: Place) -> Bool { false }
    @discardableResult func setText(_ key: String, _ text: String) -> Bool { false }
    @discardableResult func chooseTime(_ key: String, _ date: Date) -> Bool { false }
    @discardableResult func closeDial(_ key: String, now: Date? = nil) -> Bool { false }
    func search(_ key: String, _ query: String) {}
}
