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
}

struct AgentFieldSpec: Equatable {
    let key: String
    let kind: AgentFieldKind
    let label: String
    /// `pick_one`: the partner's chips, one or more. `on_off`: the two chips, the words being the field's own; the first stands for
    /// the on side and the second for the off side whatever their ids.
    var options: [AgentFieldOption] = []
    /// Text only: the most characters the field holds. Without one the field holds `AgentDelivery.maxDeliveryText`.
    var limit: Int?
    /// True when the card may leave the field blank.
    var isOptional = false
    /// Number only: the values the field may hold. Only a seed besir writes itself sets one.
    var range: ClosedRange<Int>?
    /// Place only: true when the partner resolves the field itself, so the card lists the partner's candidates (never besir's own
    /// place search) and the value is the candidate the user taps.
    var partnerLookup = false

    init(key: String, kind: AgentFieldKind, label: String, options: [AgentFieldOption] = [], limit: Int? = nil,
         isOptional: Bool = false, range: ClosedRange<Int>? = nil, partnerLookup: Bool = false) {
        self.key = key
        self.kind = kind
        self.label = label
        self.options = options
        self.limit = limit
        self.isOptional = isOptional
        self.range = range
        self.partnerLookup = partnerLookup
    }

    /// The seed of a field the partner named; nil when its chips do not fit its kind.
    init?(_ field: PartnerField) {
        guard let kind = AgentFieldKind(field.kind) else { return nil }
        switch kind {
        case .pickOne: guard !field.options.isEmpty else { return nil }
        case .onOff: guard field.options.count == 2 else { return nil }
        case .text, .place, .time, .number: break
        }
        self.init(key: field.key, kind: kind, label: field.label, options: field.options.map { AgentFieldOption(id: $0.id, label: $0.label) },
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

indirect enum AgentFieldRow {
    /// A read-only row.
    case line(String)
    /// A field with the value it starts with (nil: the user fills it) and where that value came from.
    case field(AgentFieldSpec, value: AgentFieldValue?, source: AgentFieldSource)
    /// An `on_off` field that owns rows shown only while it is on.
    case switchField(AgentFieldSpec, value: AgentFieldValue?, source: AgentFieldSource, dependents: [AgentFieldRow])
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

        /// The text of a text field, or the delivery text of a place (its address, else its name).
        func text(_ key: String) -> String? {
            switch entry(key)?.value {
            case .text(let text)?: return text
            case .place(let place)?: return AgentDelivery.placeText(place)
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
    }

    let header: String
    /// Built once; changed in place. The view reads it, never writes it.
    @Published private(set) var card: EditCard
    private(set) var isFrozen = false

    private var slots: [String: Slot] = [:]
    private var layout: [Node] = []
    private let favoriteOptions: [EditField.Option]
    private let searchPlaces: @MainActor (String) async -> [Place]
    private let partnerCandidates: (@MainActor (String, String) async -> PlaceLookup)?
    private let now: () -> Date
    private var debouncer = PlaceSearchDebouncer()

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
        card = EditCard(fields: fields(for: layout))
    }

    // MARK: Reading

    /// Every row on the card is chosen except the optional ones, and no number lies outside its range. A row that is off the card
    /// (the dependents of a switch that is off) is not looked at. A number outside its range is never ready, optional or not.
    var isReady: Bool {
        card.fields.allSatisfy { field in
            guard let slot = slots[field.key] else { return field.chosen != nil }
            if case .number(let number)? = slot.value, let range = slot.spec.range, !range.contains(number) { return false }
            return slot.spec.isOptional || field.chosen != nil
        }
    }

    var values: Snapshot {
        Snapshot(entries: card.fields.compactMap { field in
            slots[field.key].map { Snapshot.Entry(key: field.key, value: $0.value, source: $0.source) }
        })
    }

    /// The header, then one line per row on the card: a read-only row as its text, a field as `label: value` (`label:` while
    /// blank; a chip field shows the word of its chosen chip). The debug transcript and the resolved card are drawn from it.
    var lines: [String] {
        [header] + card.fields.map { field in
            if field.kind == .readonly { return field.chosen ?? String() }
            return (field.label + ": " + (field.chosenLabel ?? String())).trimmingCharacters(in: .whitespaces)
        }
    }

    func field(_ key: String) -> EditField? { card.fields.first { $0.key == key } }

    func source(of key: String) -> AgentFieldSource { slots[key]?.source ?? .blank }

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

    /// Chooses a place with its coordinates; the value is the delivery text of the place (its address, else its name). A place
    /// with neither is refused and nothing changes.
    @discardableResult
    func choosePlace(_ key: String, _ place: Place) -> Bool {
        guard !isFrozen, let index = index(of: key), var slot = slots[key], slot.spec.kind == .place,
              var text = AgentDelivery.placeText(place) else { return false }
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
            let cleaned = AgentDelivery.cleanedTyped(text, limit: slot.spec.limit ?? AgentDelivery.maxDeliveryText)
            card.setTitleText(field: card.fields[index].id, text: cleaned)
            let blank = cleaned.trimmingCharacters(in: .whitespaces).isEmpty
            slot.value = blank ? nil : .text(cleaned)
            slot.source = blank ? .blank : .entered
        case .number:
            let number = Self.number(from: text, upTo: slot.spec.limit)
            card.setTitleText(field: card.fields[index].id, text: number.map { String($0) } ?? String())
            slot.value = number.map { AgentFieldValue.number($0) }
            slot.source = number == nil ? .blank : .entered
        default:
            return false
        }
        slots[key] = slot
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
        slot.value = .time(date)
        slot.source = .entered
        slots[key] = slot
        card.fields[index].chosen = BesirTime.isoFormatter.string(from: date)
        card.fields[index].note = nil
        return true
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
        guard let seed = card.dialSeed(for: field, base: nil, now: at ?? now()) else { return false }
        return chooseTime(key, card.dialCommitCandidate(pick: seed, field: field, base: nil))
    }

    /// A query typed in a place row: the debouncer decides whether, when and with what text the search closure is called.
    func search(_ key: String, _ query: String) {
        guard !isFrozen, let index = index(of: key), let spec = slots[key]?.spec, spec.kind == .place else { return }
        let id = card.fields[index].id
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

    /// The Confirm tap: from now on every change, search and result changes nothing.
    func freeze() {
        isFrozen = true
        debouncer.cancelAll()
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
        case (.place, .place?) where spec.partnerLookup:
            // A partner-resolved row holds only a candidate the user tapped: no seeded place is a value.
            kept = nil
        case (.place, .text(let text)?) where spec.partnerLookup:
            // The stated text only seeds the row's search; it is never the value, so Confirm cannot pass on unresolved text.
            seed = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
        case (.text, .text(let text)?):
            let cleaned = AgentDelivery.cleanedTyped(text, limit: spec.limit ?? AgentDelivery.maxDeliveryText)
            kept = cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .text(cleaned)
        case (.place, .place(let place)?):
            kept = AgentDelivery.placeText(place) == nil ? nil : .place(place)
        case (.place, .text(let text)?):
            kept = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .text(text)
        case (.time, .time?):
            kept = value
        case (.pickOne, .option(let id)?):
            kept = spec.options.contains { $0.id == id } ? value : nil
        case (.onOff, .flag?):
            kept = value
        case (.number, .number(let number)?):
            kept = number >= 0 && String(number).count <= min(spec.limit ?? Self.maxNumberDigits, Self.maxNumberDigits) ? value : nil
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
            }
        }
        return built
    }

    private func editField(_ key: String) -> EditField {
        guard let slot = slots[key] else { return EditField(key: key, kind: .readonly, label: String(), options: [], allowsCustom: false) }
        let spec = slot.spec
        let chosen = chosenText(slot.value)
        switch spec.kind {
        case .text, .number:
            return EditField(key: key, kind: .title, label: spec.label, options: [], allowsCustom: true,
                             chosen: chosen.map { $0.trimmingCharacters(in: .whitespaces) }, placeholder: String())
        case .place:
            guard spec.partnerLookup else {
                return EditField(key: key, kind: .place, label: spec.label, options: favoriteOptions, allowsCustom: true, chosen: chosen)
            }
            // The partner lists the candidates: no favorites ride the row, and a held place shows as its name and address.
            var row = EditField(key: key, kind: .place, label: spec.label, options: [], allowsCustom: true, chosen: nil)
            if case .place(let place)? = slot.value { row.chosen = Self.chosenText(of: place) }
            row.partnerLookup = true
            row.searchSeed = slot.seed
            return row
        case .time:
            return EditField(key: key, kind: .datetime, label: spec.label, options: [], allowsCustom: false, chosen: chosen, anchored: false)
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
        case .place(let place)?: return AgentDelivery.placeText(place)
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
