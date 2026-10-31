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

// MARK: The directory

extension PartnerEntry {
    static let maxEntries = 8
    /// The one route the app knows by itself; every other route comes from the directory.
    static let directoryPath = "/partners"

    /// Accepts only the exact one-key answer: 1 to 8 entries, each exactly `id`, `name`, `title`, `summary`, `route`, with
    /// unique ids and unique routes. One defect in one entry makes the whole directory unusable.
    static func list(from data: Data) -> [PartnerEntry]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 1,
              let listed = object["partners"] as? [Any], (1...maxEntries).contains(listed.count) else { return nil }
        var entries: [PartnerEntry] = []
        for element in listed {
            guard let value = element as? [String: Any], let entry = PartnerEntry(object: value),
                  !entries.contains(where: { $0.id == entry.id || $0.route == entry.route }) else { return nil }
            entries.append(entry)
        }
        return entries
    }

    private init?(object: [String: Any]) {
        guard object.count == 5, let id = object["id"] as? String, Self.isID(id),
              let name = object["name"] as? String, PartnerForm.isItemName(name),
              let title = object["title"] as? String, PartnerForm.isLabel(title, upTo: 40),
              let summary = object["summary"] as? String, PartnerForm.isLabel(summary, upTo: 120),
              let route = object["route"] as? String, Self.isRoute(route) else { return nil }
        self.init(id: id, name: name, title: title, summary: summary, route: route)
    }

    /// 1 to 24 characters of `a-z`, `0-9` and `_`, the first a letter.
    private static func isID(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard (1...24).contains(scalars.count), isLower(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { isLower($0) || isDigit($0) || $0 == "_" }
    }

    /// A slash, then 1 to 32 characters of `a-z`, `0-9` and `-`, the first a letter; not the route of the directory.
    private static func isRoute(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard (2...33).contains(scalars.count), scalars[0] == "/", isLower(scalars[1]), text != directoryPath else { return false }
        return scalars.dropFirst(2).allSatisfy { isLower($0) || isDigit($0) || $0 == "-" }
    }

    private static func isLower(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
}

// MARK: The form

extension PartnerSpec {
    /// Accepts only the exact four-key answer of an entry's route for `fields`: the entry's own name, `simulated` true, and a
    /// field list and a result-field list that obey `PartnerForm`. It asks for no particular key, kind or number of fields.
    static func form(from data: Data, entry: PartnerEntry) -> PartnerSpec? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 4,
              object["partner"] as? String == entry.name, isTrue(object["simulated"]),
              let fields = PartnerForm.fields(from: object["fields"]),
              let results = PartnerForm.resultFields(from: object["result_fields"]) else { return nil }
        return PartnerSpec(entry: entry, fields: fields, results: results)
    }
}

// MARK: The request and its answer

extension PartnerRequest {
    /// The body of a `submit`: the id and the values, each typed by its kind; a field with no value has no entry.
    var body: [String: Any] {
        var typed: [String: Any] = [:]
        for item in values {
            switch item.value {
            case .text(let text): typed[item.key] = text
            case .number(let number): typed[item.key] = number
            case .flag(let flag): typed[item.key] = flag
            }
        }
        return ["op": "submit", "request_id": requestID, "values": typed]
    }
}

extension PartnerAnswer {
    /// Accepts only the exact four-key answer of a `submit`: the entry's own name and `simulated` true, then either
    /// `confirmed` with `results` that equal the announced list in count, order, names and kinds, or `declined` with a
    /// `reason` of 1 to 40 characters of `a-z` and `_`. The reason is checked and then dropped.
    static func answer(from data: Data, spec: PartnerSpec) -> PartnerAnswer? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 4,
              let status = object["status"] as? String,
              object["partner"] as? String == spec.entry.name, isTrue(object["simulated"]) else { return nil }
        switch status {
        case "confirmed":
            guard let results = PartnerForm.results(from: object["results"]), results.count == spec.results.count,
                  zip(results, spec.results).allSatisfy({ $0.name == $1.name && $0.kind == $1.kind }) else { return nil }
            return .confirmed(results: results)
        case "declined":
            guard let reason = object["reason"] as? String, isReason(reason) else { return nil }
            return .declined
        default:
            return nil
        }
    }

    private static func isReason(_ text: String) -> Bool {
        (1...40).contains(text.unicodeScalars.count) && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
    }
}

// MARK: The place lookup

/// The lookup a partner answers for a field it marked `"lookup": true` (SPEC-PARTNERPLACE-001): the text the user typed goes out,
/// up to five candidates come back. The grammar of both sides lives here and nowhere else.
enum PartnerCandidates {
    static let minTextLength = 2
    static let maxTextLength = 80
    static let maxCandidates = 5
    static let maxNameLength = 80
    static let maxAddressLength = 120

    /// The text a lookup asks for: hidden characters removed, white space trimmed, cut at 80 code points, trimmed again. Nil when
    /// fewer than 2 code points remain, because then nothing is asked. The one place that fixes this order.
    static func requestText(_ typed: String) -> String? {
        let visible = typed.unicodeScalars.filter { !isHidden($0) }
        let cut = String(String.UnicodeScalarView(visible.prefix(maxTextLength)))
        let text = cut.trimmingCharacters(in: .whitespaces)
        return text.unicodeScalars.count >= minTextLength ? text : nil
    }

    /// The body of a lookup: `op`, `field`, `text`, and `near` (exactly `latitude` and `longitude`, each rounded to 2 decimals,
    /// about 1 km) only when the device position is known.
    static func body(field: String, text: String, near: (latitude: Double, longitude: Double)?) -> [String: Any] {
        var body: [String: Any] = ["op": "lookup", "field": field, "text": text]
        if let near { body["near"] = ["latitude": rounded(near.latitude), "longitude": rounded(near.longitude)] }
        return body
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// The characters `PartnerForm.isLabel` refuses: control, format, line separator, paragraph separator.
    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        [.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
    }

    /// Accepts only the exact four-key answer of a `lookup`: the entry's own name, `simulated` true, the requested `field`, and
    /// 0 to 5 `candidates`, each exactly `name`, `address` and `location` (`latitude`, `longitude`). One defect anywhere makes the
    /// whole answer unusable (nil); an empty list is an answer.
    // @MX:NOTE the one place the grammar of a lookup answer lives; the Worker drops what this refuses, so one bad result never fails a lookup
    static func list(from data: Data, spec: PartnerSpec, field: String) -> [Place]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 4,
              object["partner"] as? String == spec.entry.name, isTrue(object["simulated"]), object["field"] as? String == field,
              let listed = object["candidates"] as? [Any], listed.count <= maxCandidates else { return nil }
        var places: [Place] = []
        for element in listed {
            guard let candidate = element as? [String: Any], let place = place(from: candidate) else { return nil }
            places.append(place)
        }
        return places
    }

    private static func place(from object: [String: Any]) -> Place? {
        guard object.count == 3, let name = object["name"] as? String, isText(name, upTo: maxNameLength),
              let address = object["address"] as? String, isText(address, upTo: maxAddressLength),
              let location = object["location"] as? [String: Any], location.count == 2,
              let latitude = coordinate(location["latitude"], within: 90),
              let longitude = coordinate(location["longitude"], within: 180) else { return nil }
        return Place(name: name, address: address, latitude: latitude, longitude: longitude)
    }

    /// 1 to `limit` code points, no hidden character, and not white space only.
    private static func isText(_ text: String, upTo limit: Int) -> Bool {
        PartnerForm.isLabel(text, upTo: limit) && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A finite JSON number (never a boolean) within `-limit...limit`.
    private static func coordinate(_ value: Any?, within limit: Double) -> Double? {
        guard let number = value as? NSNumber, !PartnerForm.isBoolean(number) else { return nil }
        let parsed = number.doubleValue
        return parsed.isFinite && abs(parsed) <= limit ? parsed : nil
    }
}

/// True only for the JSON boolean `true`; a number, a text and null never count.
private func isTrue(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, PartnerForm.isBoolean(number) else { return false }
    return number.boolValue
}
