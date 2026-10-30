import Foundation

/// The word a partner uses for the kind of one field of its order form (SPEC-CHOICECARD-001 REQ-002).
enum PartnerFieldKind: String, CaseIterable, Equatable {
    case text, place, time, number
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
    /// True when the partner marked the field optional. Defaulted, so a field written without it is required.
    var isOptional = false
}

/// One entry of the result-field list a partner announces before the card is drawn: the name and the kind of a result item.
struct PartnerResultSpec: Equatable {
    let name: String
    let kind: PartnerResultKind
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
/// that breaks any rule, so one defect makes the whole list unusable. A partner's own rule (which keys it may send) is the
/// caller's: this layer knows only the grammar.
enum PartnerForm {
    static let maxFields = 8
    static let maxKeyLength = 32
    static let maxFieldLabelLength = 40
    static let maxOptionLabelLength = 60
    static let maxPickOptions = 4
    static let maxItems = 8
    static let maxNameLength = 40
    static let maxTextLength = 80
    static let maxCents = 1_000_000

    // MARK: The field list

    /// 1 to 8 fields, each `key`, `kind`, `label` and, only for `pick_one` and `on_off`, `options`; keys unique.
    static func fields(from value: Any?) -> [PartnerField]? {
        guard let list = value as? [Any], (1...maxFields).contains(list.count) else { return nil }
        var fields: [PartnerField] = []
        for element in list {
            guard let object = element as? [String: Any], let field = field(from: object),
                  !fields.contains(where: { $0.key == field.key }) else { return nil }
            fields.append(field)
        }
        return fields
    }

    private static func field(from object: [String: Any]) -> PartnerField? {
        guard let key = object["key"] as? String, isFieldKey(key),
              let word = object["kind"] as? String, let kind = PartnerFieldKind(rawValue: word), kind != .number,
              let label = object["label"] as? String, isLabel(label, upTo: maxFieldLabelLength) else { return nil }
        guard kind.hasOptions else {
            return object.count == 3 ? PartnerField(key: key, kind: kind, label: label, options: []) : nil
        }
        guard object.count == 4, let listed = object["options"] as? [Any], let options = options(from: listed, kind: kind) else { return nil }
        return PartnerField(key: key, kind: kind, label: label, options: options)
    }

    /// `pick_one`: 1 to 4 entries with unique ids of `a-z0-9-_`. `on_off`: exactly two, the ids `true` then `false`, two
    /// different labels. Every entry is exactly `{id, label}`; every label is 1 to 60 characters with no hidden one.
    private static func options(from list: [Any], kind: PartnerFieldKind) -> [PartnerOption]? {
        let count = kind == .onOff ? list.count == 2 : (1...maxPickOptions).contains(list.count)
        guard count else { return nil }
        var options: [PartnerOption] = []
        for (index, element) in list.enumerated() {
            guard let object = element as? [String: Any], object.count == 2,
                  let id = object["id"] as? String, let label = object["label"] as? String,
                  isLabel(label, upTo: maxOptionLabelLength) else { return nil }
            if kind == .onOff {
                guard id == (index == 0 ? "true" : "false") else { return nil }
            } else {
                guard isOptionID(id), !options.contains(where: { $0.id == id }) else { return nil }
            }
            options.append(PartnerOption(id: id, label: label))
        }
        if kind == .onOff, options[0].label == options[1].label { return nil }
        return options
    }

    // MARK: The result list

    /// 1 to 8 items, each exactly `{name, kind, value}` with the value of that kind; at most one `time` and one `money` item.
    static func results(from value: Any?) -> [PartnerResultItem]? {
        guard let list = value as? [Any], (1...maxItems).contains(list.count) else { return nil }
        var items: [PartnerResultItem] = []
        for element in list {
            guard let object = element as? [String: Any], let item = item(from: object) else { return nil }
            items.append(item)
        }
        guard items.filter({ $0.kind == .time }).count <= 1, items.filter({ $0.kind == .money }).count <= 1 else { return nil }
        return items
    }

    private static func item(from object: [String: Any]) -> PartnerResultItem? {
        guard object.count == 3, let name = object["name"] as? String, isItemName(name),
              let word = object["kind"] as? String, let kind = PartnerResultKind(rawValue: word) else { return nil }
        switch kind {
        case .time:
            guard let text = object["value"] as? String, minuteOfDay(text) != nil else { return nil }
            return PartnerResultItem(name: name, value: .time(text))
        case .money:
            guard let cents = integer(object["value"]), (1...maxCents).contains(cents) else { return nil }
            return PartnerResultItem(name: name, value: .money(cents))
        case .text:
            guard let text = object["value"] as? String, isLabel(text, upTo: maxTextLength) else { return nil }
            return PartnerResultItem(name: name, value: .text(text))
        }
    }

    /// The announced result fields. Skeleton: nothing is read yet.
    static func resultFields(from value: Any?) -> [PartnerResultSpec]? { nil }

    // MARK: Shared reading rules

    /// A JSON number with a whole value, or nil; `2.0` counts as 2 and a boolean is never a number.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let parsed = number.doubleValue
        guard parsed == parsed.rounded(), abs(parsed) < 1e12 else { return nil }
        return Int(parsed)
    }

    static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    /// The minute of the day of a real local date-time `yyyy-MM-ddTHH:mm` (year 2000 to 2199, the calendar checked by
    /// arithmetic so no clock is read), or nil for any other text.
    static func minuteOfDay(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard bytes.count == 16, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":") else { return nil }
        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              let hour = digits(11..<13), let minute = digits(14..<16),
              (2000...2199).contains(year), (1...12).contains(month), hour < 24, minute < 60 else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = month == 2 ? (leap ? 29 : 28) : ([4, 6, 9, 11].contains(month) ? 30 : 31)
        guard (1...days).contains(day) else { return nil }
        return hour * 60 + minute
    }

    /// A field key: 1 to 32 characters of `a-z` and `_`.
    private static func isFieldKey(_ text: String) -> Bool {
        (1...maxKeyLength).contains(text.unicodeScalars.count) && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
    }

    /// An option id: 1 to 32 characters of `a-z`, `0-9`, `-` and `_`.
    private static func isOptionID(_ text: String) -> Bool {
        (1...maxKeyLength).contains(text.unicodeScalars.count) && text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// 1 to `limit` code points, none a control, format, line-separator or paragraph-separator character.
    static func isLabel(_ text: String, upTo limit: Int) -> Bool {
        (1...limit).contains(text.unicodeScalars.count) && text.unicodeScalars.allSatisfy {
            ![.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
    }

    /// A result item name: 1 to 40 printable ASCII characters.
    private static func isItemName(_ text: String) -> Bool {
        (1...maxNameLength).contains(text.unicodeScalars.count) && text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }
}

extension Array where Element == PartnerResultItem {
    /// The cents of the first `money` item.
    var moneyCents: Int? {
        for item in self { if case .money(let cents) = item.value { return cents } }
        return nil
    }

    /// The name of the first `money` item (the notice to the budget uses the partner's own word).
    var moneyName: String? {
        for item in self { if case .money = item.value { return item.name } }
        return nil
    }

    /// The text of the first `time` item.
    var arrival: String? {
        for item in self { if case .time(let text) = item.value { return text } }
        return nil
    }
}
