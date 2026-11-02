import Foundation

/// SPEC-CHOICECARD-001 (card t86): the field-card model. It draws an edit card from a list of field seeds and keeps the value
/// and the source of every field. It knows no session, no toolbox and no view, so another scene can draw the same card.
/// Every chip word and every label comes from a seed; the model writes none of its own.

/// The kind of one field, as the partner's form names it (`PartnerFieldKind`) or as the app's own row says it.
enum AgentFieldKind: Equatable {
    case text, place, time, pickOne, onOff, number

    /// The six wire words; nil for any other word.
    init?(wire: String) {
        guard let kind = PartnerFieldKind(rawValue: wire) else { return nil }
        self.init(kind)
    }

    init?(_ kind: PartnerFieldKind) {
        switch kind {
        case .text: self = .text
        case .place: self = .place
        case .time: self = .time
        case .pickOne: self = .pickOne
        case .onOff: self = .onOff
        case .number: self = .number
        case .group: return nil
        }
    }
}

/// Where the value of a field came from. `entered` is the state after the user changed the value on the card (a design
/// addition: a changed value would otherwise still claim `stated` or `inferred`).
enum AgentFieldSource: Equatable {
    case stated, inferred, blank, entered
}

enum AgentFieldValue: Equatable {
    /// The text of a `text` field, or the text of a `place` field that came as text (no coordinates).
    case text(String)
    case place(Place)
    case time(Date)
    /// The id of the chosen chip of a `pick_one` field.
    case option(String)
    /// The chosen side of an `on_off` field.
    case flag(Bool)
    /// The whole number of a `number` field.
    case number(Int)
}

/// One chip of a `pick_one` or `on_off` field.
struct AgentFieldOption: Equatable {
    let id: String
    let label: String
    /// The price of this option in whole cents, carried only by the item member of a list group (SPEC-MENULIST-001).
    var priceCents: Int? = nil
}

struct AgentFieldSpec: Equatable {
    let key: String
    let kind: AgentFieldKind
    let label: String
    /// `pick_one`: the partner's chips, one or more. `on_off`: the two chips, the words being the field's own; the first stands for
    /// the on side and the second for the off side whatever their ids.
    var options: [AgentFieldOption] = []
    /// Text only: the most characters the field holds. Without one the field holds `AgentFieldText.maxLength`.
    var limit: Int?
    /// True when the card may leave the field blank.
    var isOptional = false
    /// Number only: the values the field may hold. Only a seed besir writes itself sets one.
    var range: ClosedRange<Int>?
    /// Place only: true when the partner resolves the field itself, so the card lists the partner's candidates (never besir's own
    /// place search) and the value is the candidate the user taps.
    var partnerLookup = false
    /// Time only: true for the app's own `End` row of the schedule choice, which follows the card's first time field.
    var isEndOfFirstTime = false

    init(key: String, kind: AgentFieldKind, label: String, options: [AgentFieldOption] = [], limit: Int? = nil,
         isOptional: Bool = false, range: ClosedRange<Int>? = nil, partnerLookup: Bool = false, isEndOfFirstTime: Bool = false) {
        self.key = key
        self.kind = kind
        self.label = label
        self.options = options
        self.limit = limit
        self.isOptional = isOptional
        self.range = range
        self.partnerLookup = partnerLookup
        self.isEndOfFirstTime = isEndOfFirstTime
    }

    /// What a number field with no range of its own may hold: from 1, with no highest value.
    static let defaultNumberBounds = NumberBounds(lowest: 1)

    /// The bounds of a number field: its own range, else the default.
    var bounds: NumberBounds { range.map { NumberBounds($0) } ?? Self.defaultNumberBounds }

    /// The seed of a field the partner named; nil when its chips do not fit its kind.
    init?(_ field: PartnerField) {
        guard let kind = AgentFieldKind(field.kind) else { return nil }
        switch kind {
        case .pickOne: guard !field.options.isEmpty else { return nil }
        case .onOff: guard field.options.count == 2 else { return nil }
        case .text, .place, .time, .number: break
        }
        self.init(key: field.key, kind: kind, label: field.label,
                  options: field.options.map { AgentFieldOption(id: $0.id, label: $0.label, priceCents: $0.priceCents) },
                  isOptional: field.isOptional, partnerLookup: field.canLookUp)
    }

    /// The two sides of an `on_off` field are the values the edit card's own toggles hold, whatever the chip words.
    static let onValue = "true"
    static let offValue = "false"

    /// An `on_off` field whose two chips read `on` and `off`.
    static func onOff(key: String, label: String, on: String, off: String) -> AgentFieldSpec {
        AgentFieldSpec(key: key, kind: .onOff, label: label,
                       options: [AgentFieldOption(id: AgentFieldSpec.onValue, label: on), AgentFieldOption(id: AgentFieldSpec.offValue, label: off)])
    }
}

/// The value one member of one row of a repeatable group starts with: the value and where it came from.
struct AgentFieldSeed: Equatable {
    var value: AgentFieldValue?
    var source: AgentFieldSource
}

/// A list group of a partner card (SPEC-MENULIST-001): the partner's members (exactly one `pick_one`, whose options are the
/// lines, and one `number`, whose value is a line's count), the partner's maximum number of lines, the fee it charges a
/// non-empty order and the word its total line shows. The word and the fee live in what the caller passes; the card model
/// writes none of its own.
struct AgentFieldGroup: Equatable {
    let key: String
    let label: String
    let members: [AgentFieldSpec]
    let maxRows: Int
    /// The group's fee in whole cents, carried only while its options carry prices.
    var feeCents: Int? = nil
    /// The word the group's total line shows; passed in the seed, never written by the model.
    var totalLabel: String = ""

    /// The `pick_one` member, whose options are the lines.
    var itemMember: AgentFieldSpec { members.first { $0.kind == .pickOne } ?? members[0] }

    /// The `number` member, whose value is a line's count.
    var countMember: AgentFieldSpec { members.first { $0.kind == .number } ?? members[0] }

    /// True when every option of the item member carries a price: only then does the card draw prices and a total line.
    var isPriced: Bool {
        let options = itemMember.options
        return !options.isEmpty && options.allSatisfy { $0.priceCents != nil }
    }
}

extension AgentFieldGroup {
    /// The group a partner named: nil unless the field is a group of the list shape (one required `pick_one` and one required
    /// `number`, in either order), the defence behind the grammar's own rule (SPEC-MENULIST-001 REQ-001).
    init?(_ field: PartnerField, totalLabel: String) {
        guard field.kind == .group, field.members.count == 2,
              field.members.contains(where: { $0.kind == .pickOne }),
              field.members.contains(where: { $0.kind == .number }),
              field.members.allSatisfy({ !$0.isOptional }) else { return nil }
        var members: [AgentFieldSpec] = []
        for member in field.members {
            guard let spec = AgentFieldSpec(member) else { return nil }
            members.append(spec)
        }
        self.init(key: field.key, label: field.label, members: members, maxRows: field.maxRows,
                  feeCents: field.feeCents, totalLabel: totalLabel)
    }
}

indirect enum AgentFieldRow {
    /// A read-only row.
    case line(String)
    /// A field with the value it starts with (nil: the user fills it) and where that value came from.
    case field(AgentFieldSpec, value: AgentFieldValue?, source: AgentFieldSource)
    /// An `on_off` field that owns rows shown only while it is on.
    case switchField(AgentFieldSpec, value: AgentFieldValue?, source: AgentFieldSource, dependents: [AgentFieldRow])
    /// A repeatable group of rows: one seed per member, in member order, for each row the model stated; the card matches the
    /// rows to the group's lines by the item each row names (SPEC-MENULIST-001 REQ-007).
    case repeating(AgentFieldGroup, rows: [[AgentFieldSeed]])
}

/// The card: built once from the rows, then changed in place so a row keeps its identity (the view keeps its open list, wheel
/// and draft text per row). Every change goes through one function below, and every one returns at once when the card is
/// frozen. The model keeps the typed value of each field beside the edit card's `chosen` text, because `chosen` is a string
/// and a `Date` or a `Place` must never be read back from it.
@MainActor final class AgentFieldCard: ObservableObject {
    /// What the card holds at one moment: the field rows that are on the card, with their typed values and sources.
    struct Snapshot: Equatable {
        struct Entry: Equatable {
            let key: String
            let value: AgentFieldValue?
            let source: AgentFieldSource
        }

        let entries: [Entry]

        func entry(_ key: String) -> Entry? { entries.first { $0.key == key } }

        /// The text of a text field, or the text of a place (its address, else its name).
        func text(_ key: String) -> String? {
            switch entry(key)?.value {
            case .text(let text)?: return text
            case .place(let place)?: return AgentFieldText.placeText(place)
            default: return nil
            }
        }

        func date(_ key: String) -> Date? {
            if case .time(let date)? = entry(key)?.value { return date }
            return nil
        }

        func option(_ key: String) -> String? {
            if case .option(let id)? = entry(key)?.value { return id }
            return nil
        }

        func flag(_ key: String) -> Bool? {
            if case .flag(let on)? = entry(key)?.value { return on }
            return nil
        }

        /// The whole number of a number field.
        func int(_ key: String) -> Int? {
            if case .number(let number)? = entry(key)?.value { return number }
            return nil
        }

        /// The place of a place field, whole: name, address and coordinates as the user tapped them.
        func place(_ key: String) -> Place? {
            if case .place(let place)? = entry(key)?.value { return place }
            return nil
        }

        /// The entries of one group's rows in row-number order, each dictionary keyed by member key (a blank member included,
        /// with its source). The dot after the group's key makes the prefix exact, so a group whose key shares it does not mix.
        func rows(of group: String) -> [[String: Entry]] {
            var byRow: [Int: [String: Entry]] = [:]
            for entry in entries where entry.key.hasPrefix(group + ".") {
                let parts = entry.key.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 3, let row = Int(parts[1]) else { continue }
                byRow[row, default: [:]][String(parts[2])] = entry
            }
            return byRow.keys.sorted().map { byRow[$0] ?? [:] }
        }
    }

    private struct Slot {
        var spec: AgentFieldSpec
        var value: AgentFieldValue?
        var source: AgentFieldSource
        /// A partner-resolved place row only: the text the model stated, kept as the row's search seed (never as its value) until
        /// the row's first search spends it.
        var seed: String?
    }

    /// The layout of the rows. A line has a key of its own (its position among the lines) so the edit card can tell rows apart.
    private indirect enum Node {
        case line(key: String, text: String)
        case field(key: String)
        case group(key: String, dependents: [Node])
        case repeating(key: String)
    }

    let header: String
    /// Built once; changed in place. The view reads it, never writes it.
    @Published private(set) var card: EditCard
    private(set) var isFrozen = false

    private var slots: [String: Slot] = [:]
    /// The repeatable groups the card holds, by the group's key.
    private var groups: [String: AgentFieldGroup] = [:]
    /// The line of each list group's count field: the group, the option the line is for and the option's number from 1. A
    /// count field of a line is drawn as a menu line; the item field of a line holds no card field of its own.
    private var lineOption: [String: (group: AgentFieldGroup, option: AgentFieldOption, number: Int)] = [:]
    private var layout: [Node] = []
    private let favoriteOptions: [EditField.Option]
    private let searchPlaces: @MainActor (String) async -> [Place]
    private let partnerCandidates: (@MainActor (String, String) async -> PlaceLookup)?
    private let now: () -> Date
    private var debouncer = PlaceSearchDebouncer()
    /// The app's own `End` row and the partner's first time field it follows; both nil when the card has no `End` row.
    private var endKey: String?
    private var endBaseKey: String?

    /// `search` answers a place query (the caller decides the provider and the search centre); `now` is the clock the dial
    /// reads when its owner passes none. `candidates` answers the lookup of a place row the partner resolves itself, given the
    /// row's key and the lookup text; without it such a row fails.
    init(header: String, rows: [AgentFieldRow], favorites: [FavoritePlace], search: @escaping @MainActor (String) async -> [Place],
         now: @escaping () -> Date, candidates: (@MainActor (String, String) async -> PlaceLookup)? = nil) {
        self.header = header
        self.favoriteOptions = favorites.map { EditField.Option(label: $0.label, value: $0.label, place: $0.place) }
        self.searchPlaces = search
        self.partnerCandidates = candidates
        self.now = now
        card = EditCard(fields: [])
        var lineCount = 0
        layout = nodes(for: rows, lines: &lineCount)
        resolveEnd()
        card = EditCard(fields: fields(for: layout))
    }

    // MARK: Reading

    /// Every row on the card is chosen except the optional ones, and no number lies outside its bounds. A row that is off the card
    /// (the dependents of a switch that is off) is not looked at. A number outside its bounds is never ready, optional or not.
    /// A blank line of a list group never blocks the card, and every group needs at least one ordered line (REQ-009).
    var isReady: Bool {
        card.fields.allSatisfy { field in
            // A line of a list group never blocks: blank or ordered, it is the user's to fill.
            if lineOption[field.key] != nil { return true }
            guard let slot = slots[field.key] else { return field.chosen != nil }
            if case .number(let number)? = slot.value, !slot.spec.bounds.contains(number) { return false }
            return slot.spec.isOptional || field.chosen != nil
        } && groups.values.allSatisfy { orderedCount(of: $0) >= 1 }
    }

    /// The values of the card: for each ordered line of a list group an entry for its item (the option id, `inferred`) and one
    /// for its count; a blank line holds no entry, and the total field holds none either (REQ-009).
    var values: Snapshot {
        var entries: [Snapshot.Entry] = []
        for field in card.fields {
            if let line = lineOption[field.key] {
                guard let slot = slots[field.key], slot.value != nil else { continue }
                entries.append(Snapshot.Entry(key: Self.rowKey(line.group.key, line.number, line.group.itemMember.key),
                                              value: .option(line.option.id), source: .inferred))
                entries.append(Snapshot.Entry(key: field.key, value: slot.value, source: slot.source))
                continue
            }
            if let slot = slots[field.key] {
                entries.append(Snapshot.Entry(key: field.key, value: slot.value, source: slot.source))
            }
        }
        return Snapshot(entries: entries)
    }

    /// The header, then one line per row on the card: a read-only row as its text (a labelled one, like the total, as
    /// `label: value`), a field as `label: value` (`label:` while blank; a chip field shows the word of its chosen chip). A
    /// blank line of a list group prints nothing. The debug transcript and the resolved card are drawn from it.
    var lines: [String] {
        [header] + card.fields.compactMap { field in
            if lineOption[field.key] != nil, slots[field.key]?.value == nil { return nil }
            if field.kind == .readonly {
                return field.label.isEmpty ? (field.chosen ?? String()) : "\(field.label): \(field.chosen ?? String())"
            }
            return (field.label + ": " + (field.chosenLabel ?? String())).trimmingCharacters(in: .whitespaces)
        }
    }

    func field(_ key: String) -> EditField? { card.fields.first { $0.key == key } }

    func source(of key: String) -> AgentFieldSource { slots[key]?.source ?? .blank }

    /// The key of one member of one row of a group: `group.row.member`, the row counted from 1.
    static func rowKey(_ group: String, _ row: Int, _ member: String) -> String { "\(group).\(row).\(member)" }

    /// The bundle of closures the edit card view calls. A row is found by its id and the change is the model's own.
    var actions: EditCardActions {
        EditCardActions(
            chooseValue: { id, value in
                if let key = self.key(of: id) { self.chooseOption(key, value) }
            },
            rechooseTimeBasis: { _, _ in },
            chooseTime: { _, _, _ in false },
            chooseTimePlain: { id, date in
                self.key(of: id).map { self.chooseTime($0, date) } ?? false
            },
            choosePlace: { id, place in
                if let key = self.key(of: id) { self.choosePlace(key, place) }
            },
            searchPlaces: { id, text in
                if let key = self.key(of: id) { self.search(key, text) }
            },
            submitCustom: { _, _ in false },
            setTitleText: { id, text in
                if let key = self.key(of: id) { self.setText(key, text) }
            },
            chooseCandidate: { id, place in
                if let key = self.key(of: id) { self.choosePlace(key, place) }
            },
            closeDial: { id, _, now in
                if let key = self.key(of: id) { self.closeDial(key, now: now) }
            },
            confirm: {})
    }

    // MARK: Changes

    /// Chooses a chip. `pick_one`: the value is one of the listed ids. `on_off`: the value is `true` or `false` whatever the
    /// chip words. For the switch of a group the dependent rows are inserted after it (on) or removed (off).
    @discardableResult
    func chooseOption(_ key: String, _ value: String) -> Bool {
        guard !isFrozen, let index = index(of: key), var slot = slots[key] else { return false }
        switch slot.spec.kind {
        case .pickOne:
            guard slot.spec.options.contains(where: { $0.id == value }) else { return false }
            slot.value = .option(value)
        case .onOff:
            guard value == AgentFieldSpec.onValue || value == AgentFieldSpec.offValue else { return false }
            slot.value = .flag(value == AgentFieldSpec.onValue)
        case .text, .place, .time, .number:
            return false
        }
        slot.source = .entered
        slots[key] = slot
        card.fields[index].chosen = value
        if slot.spec.kind == .onOff, let dependents = dependents(of: key, in: layout) { showDependents(dependents, after: key, on: value == AgentFieldSpec.onValue) }
        return true
    }

    /// Chooses a place with its coordinates; the value is the text of the place (its address, else its name). A place
    /// with neither is refused and nothing changes.
    @discardableResult
    func choosePlace(_ key: String, _ place: Place) -> Bool {
        guard !isFrozen, let index = index(of: key), var slot = slots[key], slot.spec.kind == .place,
              var text = AgentFieldText.placeText(place) else { return false }
        if slot.spec.partnerLookup {
            // @MX:NOTE a partner-resolved row takes only a candidate the partner listed and the row still shows; a place of an older
            // list, a favorite or an unlisted place changes nothing. The check is of the tap, not of a value already held.
            guard case .results(let listed) = card.fields[index].lookup, listed.contains(place) else { return false }
            text = Self.chosenText(of: place)
        }
        slot.value = .place(place)
        slot.source = .entered
        slots[key] = slot
        card.fields[index].chosen = text
        card.fields[index].note = nil
        card.fields[index].keptQuery = nil
        return true
    }

    /// What a closed partner-resolved row shows for its chosen candidate: the name, then the address.
    private static func chosenText(of place: Place) -> String { "\(place.name), \(place.address)" }

    /// Types text: hidden characters go, the text is cut at the field's limit, nothing is trimmed, and a blank text clears the
    /// value. The view passes the whole draft each time. A number field keeps only ASCII digits, cut at its limit (at most
    /// `maxNumberDigits`), holds the whole number they make (so leading zeros go) and reads empty as blank.
    @discardableResult
    func setText(_ key: String, _ text: String) -> Bool {
        guard !isFrozen, let index = index(of: key), var slot = slots[key] else { return false }
        switch slot.spec.kind {
        case .text:
            let cleaned = AgentFieldText.cleanedTyped(text, limit: slot.spec.limit ?? AgentFieldText.maxLength)
            card.setTitleText(field: card.fields[index].id, text: cleaned)
            let blank = cleaned.trimmingCharacters(in: .whitespaces).isEmpty
            slot.value = blank ? nil : .text(cleaned)
            slot.source = blank ? .blank : .entered
        case .number:
            var number = Self.number(from: text, upTo: slot.spec.limit)
            if let line = lineOption[key] {
                // A line of a list group: a number outside the count member's bounds reads as blank (SPEC-NUMSTEPPER-001's
                // seed rule), and a new count on a blank line while the order holds the group's maximum is refused and
                // changes nothing (SPEC-MENULIST-001 REQ-008).
                number = number.flatMap { slot.spec.bounds.contains($0) ? $0 : nil }
                let wasBlank = slot.value == nil
                if number != nil, wasBlank, orderedCount(of: line.group) >= line.group.maxRows { return false }
            }
            card.setTitleText(field: card.fields[index].id, text: number.map { String($0) } ?? String())
            slot.value = number.map { AgentFieldValue.number($0) }
            slot.source = number == nil ? .blank : .entered
        default:
            return false
        }
        slots[key] = slot
        if let line = lineOption[key] { refreshList(of: line.group) }
        return true
    }

    static let maxNumberDigits = 9

    /// The ASCII digits of `text`, the first `limit` of them (never more than `maxNumberDigits`), as one whole number; nil
    /// when there is none.
    private static func number(from text: String, upTo limit: Int?) -> Int? {
        let digits = text.unicodeScalars.filter { (0x30...0x39).contains($0.value) }.prefix(min(limit ?? maxNumberDigits, maxNumberDigits))
        return Int(String(String.UnicodeScalarView(digits)))
    }

    /// Chooses a time. The `Date` is kept as picked; the edit card's text is written from it and never read back.
    @discardableResult
    func chooseTime(_ key: String, _ date: Date) -> Bool {
        guard !isFrozen, let index = index(of: key), var slot = slots[key], slot.spec.kind == .time else { return false }
        // The `End` row takes only a time after its base and within the wheel's 24 hours; anything else changes nothing.
        if slot.spec.isEndOfFirstTime {
            guard let wheel = card.fields[index].endWheel, let base = card.endWheelBase(for: card.fields[index]),
                  wheel.accepts(end: date, base: base) else {
                card.fields[index].note = EndWheelSpec.notAfterBaseMessage
                return false
            }
        }
        let before = slot.value
        slot.value = .time(date)
        slot.source = .entered
        slots[key] = slot
        card.fields[index].chosen = BesirTime.isoFormatter.string(from: date)
        card.fields[index].note = nil
        if key == endBaseKey { moveEnd(from: before, to: date) }
        return true
    }

    /// The `End` row follows its base: it keeps its span, or takes the base plus the default length while it holds no value. It is
    /// written on its slot whether or not its row is on the card (the schedule switch off removes the row), so turning the switch
    /// on again never shows an `End` before its base.
    private func moveEnd(from before: AgentFieldValue?, to newBase: Date) {
        guard let endKey, var end = slots[endKey] else { return }
        let moved: Date
        if case .time(let oldEnd)? = end.value, case .time(let oldBase)? = before {
            moved = EndWheelSpec.followingEnd(oldStart: oldBase, oldEnd: oldEnd, newStart: newBase)
        } else {
            moved = newBase.addingTimeInterval(TimeInterval(AgentPartner.lengthInitial * 60))
            end.source = .inferred
        }
        end.value = .time(moved)
        slots[endKey] = end
        if let at = index(of: endKey) {
            card.fields[at].chosen = BesirTime.isoFormatter.string(from: moved)
            card.fields[at].note = nil
        }
    }

    /// Finds the `End` row, if the card has one, and the first time field of the partner's own order it follows. A card with no
    /// time field loses the row; otherwise the row is seeded from the base's value, and stays blank while the base is blank.
    private func resolveEnd() {
        guard let end = layoutKeys.first(where: { slots[$0]?.spec.isEndOfFirstTime == true }) else { return }
        let base = layout.compactMap { node -> String? in
            guard case .field(let key) = node, let spec = slots[key]?.spec, spec.kind == .time, !spec.isEndOfFirstTime else { return nil }
            return key
        }.first
        guard let base else {
            layout = removing(end, from: layout)
            slots.removeValue(forKey: end)
            return
        }
        endKey = end
        endBaseKey = base
        if case .time(let start)? = slots[base]?.value, var row = slots[end] {
            row.value = .time(start.addingTimeInterval(TimeInterval(AgentPartner.lengthInitial * 60)))
            row.source = .inferred
            slots[end] = row
        }
    }

    private var layoutKeys: [String] { Array(keys(in: layout)) }

    private func removing(_ key: String, from nodes: [Node]) -> [Node] {
        nodes.compactMap { node in
            switch node {
            case .field(let found) where found == key: return nil
            case .group(let groupKey, let dependents): return .group(key: groupKey, dependents: removing(key, from: dependents))
            default: return node
            }
        }
    }

    /// Closing (or opening) a time wheel: a row with a value keeps it; a row with none takes the seed the wheel shows, which
    /// the edit card computes (`dialSeed`), so the closed wheel and the card agree. Returns false for a row that is not a time.
    @discardableResult
    func closeDial(_ key: String, now at: Date? = nil) -> Bool {
        guard !isFrozen, let index = index(of: key), slots[key]?.spec.kind == .time else { return false }
        if card.fields[index].chosen != nil {
            card.fields[index].note = nil
            return true
        }
        let field = card.fields[index]
        // An `End` row reads its base from the card; every other time row has none.
        let base = card.endWheelBase(for: field)
        guard let seed = card.dialSeed(for: field, base: base, now: at ?? now()) else { return false }
        return chooseTime(key, card.dialCommitCandidate(pick: seed, field: field, base: base))
    }

    /// A query typed in a place row: the debouncer decides whether, when and with what text the search closure is called.
    func search(_ key: String, _ query: String) {
        guard !isFrozen, let index = index(of: key), let spec = slots[key]?.spec, spec.kind == .place else { return }
        let id = card.fields[index].id
        // The row keeps the text of its latest search (a blank text keeps nothing), so a closed list gives it back on reopening.
        card.fields[index].keptQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : query
        // The first search of a partner-resolved row spends its seed, whatever that search asks (even nothing).
        if spec.partnerLookup { spendSeed(key, index) }
        switch debouncer.gate(id, query) {
        case .clear:
            setLookup(id, .idle)
        case .skip:
            break
        case .fire(let cleaned):
            guard spec.partnerLookup else {
                setLookup(id, .searching)
                debouncer.arm(id, cleaned) { [weak self] in
                    guard let self else { return }
                    let found = await self.searchPlaces(cleaned)
                    guard !Task.isCancelled else { return }
                    self.finishSearch(id, cleaned, .found(found))
                }
                return
            }
            // The gate has already cancelled a lookup in flight. A text that is too short once normalised asks nothing, and is
            // recorded as done so a later different text is not skipped as a repeat.
            guard let asked = PartnerCandidates.requestText(cleaned) else {
                setLookup(id, .idle)
                debouncer.noteDone(id, cleaned)
                return
            }
            setLookup(id, .searching)
            debouncer.arm(id, cleaned) { [weak self] in
                guard let self else { return }
                // Never the place search: a row the partner resolves fails when the card has no partner to ask.
                let found = await self.partnerCandidates?(key, asked) ?? .failed
                guard !Task.isCancelled else { return }
                self.finishSearch(id, cleaned, found)
            }
        }
    }

    private func spendSeed(_ key: String, _ index: Int) {
        slots[key]?.seed = nil
        card.fields[index].searchSeed = nil
    }

    /// The Confirm tap: from now on every change, search and result changes nothing. The card keeps its rows; a frozen card
    /// shows what was ordered (SPEC-MENULIST-001 REQ-009: the freeze removes nothing).
    func freeze() {
        isFrozen = true
        debouncer.cancelAll()
    }

    // MARK: List groups (SPEC-MENULIST-001)

    /// The key of a group's total line.
    static func totalKey(_ group: String) -> String { "\(group).total" }

    /// The number of lines of a group that hold a count.
    private func orderedCount(of group: AgentFieldGroup) -> Int {
        var count = 0
        for (index, _) in group.itemMember.options.enumerated() {
            if slots[Self.rowKey(group.key, index + 1, group.countMember.key)]?.value != nil { count += 1 }
        }
        return count
    }

    /// The total of a group's order in whole cents, as `MenuListTotal` counts it.
    private func totalCents(of group: AgentFieldGroup) -> Int {
        let lines = group.itemMember.options.enumerated().compactMap { index, option -> (priceCents: Int, count: Int)? in
            guard let price = option.priceCents,
                  case .number(let count)? = slots[Self.rowKey(group.key, index + 1, group.countMember.key)]?.value else { return nil }
            return (price, count)
        }
        return MenuListTotal.cents(lines: lines, feeCents: group.feeCents)
    }

    /// After a write to a line: sets `canAdd` on every line of the group (the order holds fewer lines than the group's
    /// maximum) and rewrites the total line's text, in place, so the view's rows keep their ids (REQ-008, REQ-010).
    private func refreshList(of group: AgentFieldGroup) {
        let canAdd = orderedCount(of: group) < group.maxRows
        for index in card.fields.indices where lineOption[card.fields[index].key]?.group.key == group.key {
            card.fields[index].menuLine?.canAdd = canAdd
        }
        if group.isPriced, let total = index(of: Self.totalKey(group.key)) {
            card.fields[total].chosen = AgentBudget.dollars(cents: totalCents(of: group))
        }
    }

    /// The fields of a group's list: one line for each option of the item member, in the partner's order, then the total
    /// line while the options carry prices (REQ-005, REQ-010).
    private func lineFields(of groupKey: String) -> [EditField] {
        guard let group = groups[groupKey] else { return [] }
        var built: [EditField] = []
        for index in group.itemMember.options.indices {
            built.append(editField(Self.rowKey(groupKey, index + 1, group.countMember.key)))
        }
        if group.isPriced {
            built.append(EditField(key: Self.totalKey(groupKey), kind: .readonly, label: group.totalLabel,
                                   options: [], allowsCustom: false, chosen: AgentBudget.dollars(cents: totalCents(of: group))))
        }
        return built
    }

    /// The edit field of one line of a list group: the option's label with the price under it, the stepper rule of the
    /// line's count and whether the round plus may add one; a `.title` row the view draws as a menu line (REQ-005, 006).
    private func menuLineField(_ key: String, _ slot: Slot) -> EditField? {
        guard let line = lineOption[key] else { return nil }
        var row = EditField(key: key, kind: .title, label: line.option.label, options: [], allowsCustom: true,
                            chosen: chosenText(slot.value), placeholder: String())
        row.menuLine = EditField.MenuLine(price: line.option.priceCents.map { AgentBudget.dollars(cents: $0) },
                                          rule: NumberStepperRule(bounds: slot.spec.bounds, allowsBlank: true),
                                          canAdd: orderedCount(of: line.group) < line.group.maxRows)
        return row
    }

    /// The member's spec under its row key: everything of the member but the key, so every rule of a scalar field applies.
    private static func rowSpec(of member: AgentFieldSpec, group: String, row: Int) -> AgentFieldSpec {
        AgentFieldSpec(key: rowKey(group, row, member.key), kind: member.kind, label: member.label, options: member.options,
                       limit: member.limit, isOptional: member.isOptional, range: member.range, partnerLookup: member.partnerLookup)
    }

    /// The rows besir added itself (each switch with its dependents) leave the card: a card that ended without an applied answer
    /// must not read as if they had taken effect. The partner's own rows stay.
    func removeOwnRows() {
        let owned = keys(in: layout.filter { node in
            if case .group = node { return true }
            return false
        })
        card.fields.removeAll { owned.contains($0.key) }
    }

    // MARK: Building

    private func nodes(for rows: [AgentFieldRow], lines: inout Int) -> [Node] {
        var built: [Node] = []
        for row in rows {
            switch row {
            case .line(let text):
                built.append(.line(key: String(lines), text: text))
                lines += 1
            case .field(let spec, let value, let source):
                slots[spec.key] = slot(spec, value, source)
                built.append(.field(key: spec.key))
            case .switchField(let spec, let value, let source, let dependents):
                slots[spec.key] = slot(spec, value, source)
                built.append(.group(key: spec.key, dependents: nodes(for: dependents, lines: &lines)))
            case .repeating(let group, let seeded):
                groups[group.key] = group
                let item = group.itemMember
                let count = group.countMember
                // The rows are matched to the options by the item each row names: the first row naming an item decides its
                // line (a row naming no item, an id that is not an option or an item already taken is ignored), and its count
                // seed is recorded even when it is blank (REQ-007).
                var recorded: [(id: String, seed: AgentFieldSeed)] = []
                var taken: Set<String> = []
                for row in seeded {
                    var itemSeed: AgentFieldSeed?
                    var countSeed: AgentFieldSeed?
                    for (member, seed) in zip(group.members, row) {
                        if member.kind == .pickOne { itemSeed = seed }
                        if member.kind == .number { countSeed = seed }
                    }
                    guard let itemSeed, case .option(let id)? = itemSeed.value,
                          item.options.contains(where: { $0.id == id }), !taken.contains(id) else { continue }
                    taken.insert(id)
                    recorded.append((id, countSeed ?? AgentFieldSeed(value: nil, source: .blank)))
                }
                // Each recorded seed is built into its slot; a seed whose slot keeps a value counts against the maximum and
                // is dropped once the maximum values are kept, in the order the rows were stated (REQ-007).
                let seedsByID = Dictionary(recorded.map { ($0.id, $0.seed) }, uniquingKeysWith: { first, _ in first })
                var keptIDs: Set<String> = []
                var kept = 0
                for row in recorded {
                    let built = slot(Self.rowSpec(of: count, group: group.key, row: 0), row.seed.value, row.seed.source)
                    if built.value != nil {
                        guard kept < group.maxRows else { continue }
                        kept += 1
                        keptIDs.insert(row.id)
                    }
                }
                // One slot per option: the item fixed to its option (inferred) and the count from the recorded seed or blank.
                for (index, option) in item.options.enumerated() {
                    let number = index + 1
                    slots[Self.rowKey(group.key, number, item.key)] =
                        slot(Self.rowSpec(of: item, group: group.key, row: number), .option(option.id), .inferred)
                    let countKey = Self.rowKey(group.key, number, count.key)
                    let countSpec = Self.rowSpec(of: count, group: group.key, row: number)
                    var countSlot = slot(countSpec, nil, .blank)
                    if let seed = seedsByID[option.id] {
                        let built = slot(countSpec, seed.value, seed.source)
                        if built.value == nil || keptIDs.contains(option.id) { countSlot = built }
                    }
                    slots[countKey] = countSlot
                    lineOption[countKey] = (group, option, number)
                }
                built.append(.repeating(key: group.key))
            }
        }
        return built
    }

    /// A seed value is kept only when it fits its kind: a text is cleaned and cut at the limit, a chip must be listed, a place
    /// must have a usable text. A value that does not fit reads as blank. A seed that claims `blank` with a value reads as
    /// inferred.
    private func slot(_ spec: AgentFieldSpec, _ value: AgentFieldValue?, _ source: AgentFieldSource) -> Slot {
        var kept: AgentFieldValue?
        var seed: String?
        switch (spec.kind, value) {
        case (.place, .place(let place)?) where spec.partnerLookup:
            // A partner-resolved row holds only a candidate the user tapped: no seeded place is a value. The place's text only
            // seeds the row's search: its name, then its address when there is one, each cleaned of hidden characters
            // (SPEC-CARDPLACE-001 REQ-006).
            kept = nil
            let name = AgentToolbox.sanitized(place.name)
            let address = AgentToolbox.sanitized(place.address)
            let text = name.isEmpty ? address : (address.isEmpty ? name : "\(name), \(address)")
            seed = text.isEmpty ? nil : text
        case (.place, .text(let text)?) where spec.partnerLookup:
            // The stated text only seeds the row's search; it is never the value, so Confirm cannot pass on unresolved text.
            seed = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
        case (.text, .text(let text)?):
            let cleaned = AgentFieldText.cleanedTyped(text, limit: spec.limit ?? AgentFieldText.maxLength)
            kept = cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .text(cleaned)
        case (.place, .place(let place)?):
            kept = AgentFieldText.placeText(place) == nil ? nil : .place(place)
        case (.place, .text(let text)?):
            kept = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .text(text)
        case (.time, .time?):
            kept = value
        case (.pickOne, .option(let id)?):
            kept = spec.options.contains { $0.id == id } ? value : nil
        case (.onOff, .flag?):
            kept = value
        case (.number, .number(let number)?):
            kept = spec.bounds.contains(number) && String(number).count <= min(spec.limit ?? Self.maxNumberDigits, Self.maxNumberDigits) ? value : nil
        default:
            kept = nil
        }
        return Slot(spec: spec, value: kept, source: kept == nil ? .blank : (source == .blank ? .inferred : source), seed: seed)
    }

    private func fields(for nodes: [Node]) -> [EditField] {
        var built: [EditField] = []
        for node in nodes {
            switch node {
            case .line(let key, let text):
                built.append(EditField(key: key, kind: .readonly, label: String(), options: [], allowsCustom: false, chosen: text))
            case .field(let key):
                built.append(editField(key))
            case .group(let key, let dependents):
                built.append(editField(key))
                if slots[key]?.value == .flag(true) { built += fields(for: dependents) }
            case .repeating(let key):
                built += lineFields(of: key)
            }
        }
        return built
    }

    private func editField(_ key: String) -> EditField {
        guard let slot = slots[key] else { return EditField(key: key, kind: .readonly, label: String(), options: [], allowsCustom: false) }
        // A line of a list group is built before the kind switch: it is a `.title` row the view draws as a menu line, and
        // its `stepper` stays nil (SPEC-NUMSTEPPER-001's number arm is never reached by it).
        if let line = menuLineField(key, slot) { return line }
        let spec = slot.spec
        let chosen = chosenText(slot.value)
        switch spec.kind {
        case .text, .number:
            var row = EditField(key: key, kind: .title, label: spec.label, options: [], allowsCustom: true,
                                chosen: chosen.map { $0.trimmingCharacters(in: .whitespaces) }, placeholder: String())
            // A number row is drawn as a minus/plus stepper; it stays a typed row for the card model's single digit writer.
            if spec.kind == .number { row.stepper = NumberStepperRule(bounds: spec.bounds, allowsBlank: spec.isOptional) }
            return row
        case .place:
            guard spec.partnerLookup else {
                return EditField(key: key, kind: .place, label: spec.label, options: favoriteOptions, allowsCustom: true, chosen: chosen)
            }
            // The partner lists the candidates: no favorites ride the row, and a held place shows as its name and address.
            var row = EditField(key: key, kind: .place, label: spec.label, options: [], allowsCustom: true, chosen: nil)
            if case .place(let place)? = slot.value { row.chosen = Self.chosenText(of: place) }
            row.partnerLookup = true
            row.searchSeed = slot.seed
            // A seeded row starts open, so the card shows which place it is for and the view searches the seed as the card appears.
            row.startsOpen = slot.seed != nil
            return row
        case .time:
            var row = EditField(key: key, kind: .datetime, label: spec.label, options: [], allowsCustom: false, chosen: chosen, anchored: false)
            if spec.isEndOfFirstTime, let base = endBaseKey {
                row.endWheel = EndWheelSpec(baseKey: base, capsAt24Hours: true, baseHint: EndWheelSpec.manualEndHint)
            }
            return row
        case .pickOne:
            return EditField(key: key, kind: .toggle, label: spec.label,
                             options: spec.options.map { EditField.Option(label: $0.label, value: $0.id) }, allowsCustom: false, chosen: chosen)
        case .onOff:
            let values = [AgentFieldSpec.onValue, AgentFieldSpec.offValue]
            return EditField(key: key, kind: .toggle, label: spec.label,
                             options: zip(spec.options, values).map { EditField.Option(label: $0.label, value: $1) },
                             allowsCustom: false, chosen: chosen)
        }
    }

    /// The edit card's `chosen` text of a value; nil for no value.
    private func chosenText(_ value: AgentFieldValue?) -> String? {
        switch value {
        case .text(let text)?: return text
        case .place(let place)?: return AgentFieldText.placeText(place)
        case .time(let date)?: return BesirTime.isoFormatter.string(from: date)
        case .option(let id)?: return id
        case .flag(let on)?: return on ? AgentFieldSpec.onValue : AgentFieldSpec.offValue
        case .number(let number)?: return String(number)
        case nil: return nil
        }
    }

    // MARK: Rows

    private func index(of key: String) -> Int? { card.fields.firstIndex { $0.key == key } }

    private func key(of id: UUID) -> String? { card.fields.first { $0.id == id }?.key }

    private func dependents(of key: String, in nodes: [Node]) -> [Node]? {
        for node in nodes {
            guard case .group(let groupKey, let dependents) = node else { continue }
            if groupKey == key { return dependents }
            if let nested = self.dependents(of: key, in: dependents) { return nested }
        }
        return nil
    }

    private func keys(in nodes: [Node]) -> Set<String> {
        var found: Set<String> = []
        for node in nodes {
            switch node {
            case .line(let key, _), .field(let key): found.insert(key)
            case .group(let key, let dependents): found.insert(key); found.formUnion(keys(in: dependents))
            case .repeating(let key): found.insert(key)
            }
        }
        return found
    }

    /// Off removes the dependent rows; on inserts them again after the switch, new identities, with the values the model
    /// remembered. A switch that is already in the state asked for changes no row.
    private func showDependents(_ dependents: [Node], after key: String, on: Bool) {
        let owned = keys(in: dependents)
        let shown = card.fields.contains { owned.contains($0.key) }
        if on {
            guard !shown, let at = index(of: key) else { return }
            card.fields.insert(contentsOf: fields(for: dependents), at: at + 1)
        } else if shown {
            card.fields.removeAll { owned.contains($0.key) }
        }
    }

    private func setLookup(_ id: UUID, _ lookup: EditField.Lookup) {
        guard let index = card.fields.firstIndex(where: { $0.id == id }) else { return }
        card.fields[index].lookup = lookup
    }

    /// The answer of a search. The done mark comes before the state, so a query typed again while the first one runs is not
    /// dropped as a repeat. A frozen card, or a row that is gone, drops the answer.
    private func finishSearch(_ id: UUID, _ query: String, _ found: PlaceLookup) {
        guard !isFrozen else { return }
        debouncer.noteDone(id, query)
        switch found {
        case .found(let places):
            setLookup(id, places.isEmpty ? .empty : .results(Array(places.prefix(PlaceSearch.maxSuggestions))))
        case .failed:
            setLookup(id, .failed)
        }
    }
}
