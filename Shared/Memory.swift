import Foundation

/// One `key=value` field of a memory line.
struct MemoryField: Equatable {
    let key: String
    let value: String
}

// @MX:NOTE: [AUTO] The one place the memory.md line format lives; the save points of Store and the later counting and summary code read it. No kind or key list may be added here.
/// One raw line of `memory.md` (SPEC-MEMORY-001): `- ` then `date | weekday | time | kind | place`, then zero to four
/// `key=value` fields, all joined by ` | `. For example `- 2026-10-28 | Wed | 7:00 PM | activity | Example Cafe | mode=transit`.
///
/// The format is generic: the writer and the reader hold no list of kinds and no list of keys, so a new kind of choice joins by
/// writing a line with its own kind word and keys, and later counting code reads every kind the same way. Every stored string
/// passes `clean`, so no escaping exists: a stored text holds neither a line break nor ` | `. A line whose first field is the word
/// `count` is reserved for folded count lines and is never read as a raw line. This type takes only strings: the callers decide
/// which source values go in, and titles, addresses, coordinates, costs, ids and the meal's category never do.
struct MemoryLine: Equatable {
    static let maxRawLines = 200
    static let maxTextScalars = 60
    static let maxFields = 4
    static let maxLineScalars = 460

    private static let separator = " | "
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    let date: String
    let weekday: String
    let time: String
    let kind: String
    let place: String
    let fields: [MemoryField]

    private init(date: String, weekday: String, time: String, kind: String, place: String, fields: [MemoryField]) {
        self.date = date
        self.weekday = weekday
        self.time = time
        self.kind = kind
        self.place = place
        self.fields = fields
    }

    // MARK: Write

    /// The line of one choice at `date` in `zone`, or nil when the kind is not a token, or when the line would carry neither a
    /// place nor any field. Fields are taken in the given order; a field is dropped alone when its key is not a token, repeats a
    /// key already kept, its value cleans to no text, or four fields are already kept. A dropped field reserves no key.
    static func make(kind: String, at date: Date, zone: TimeZone, place: String?, fields: [(String, String)]) -> MemoryLine? {
        guard isToken(kind) else { return nil }
        var kept: [MemoryField] = []
        for (key, value) in fields {
            guard kept.count < maxFields, isToken(key), !kept.contains(where: { $0.key == key }),
                  let cleaned = clean(value) else { continue }
            kept.append(MemoryField(key: key, value: cleaned))
        }
        let cleanedPlace = place.flatMap(clean) ?? "-"
        guard cleanedPlace != "-" || !kept.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "EEE"
        let weekday = formatter.string(from: date)
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: date)
        return MemoryLine(date: day, weekday: weekday, time: time, kind: kind, place: cleanedPlace, fields: kept)
    }

    /// The stored text of the line, without its line feed.
    var text: String {
        "- " + ([date, weekday, time, kind, place] + fields.map { "\($0.key)=\($0.value)" }).joined(separator: Self.separator)
    }

    /// Cleans one stored string in one fixed order: each hidden character (general category Cc, Cf, Zl or Zp) and each `|`
    /// becomes a space, each run of white space (the Unicode `White_Space` property) becomes one U+0020 space, the text is
    /// trimmed, cut at 60 code points and trimmed again. Nil when nothing is left.
    static func clean(_ text: String) -> String? {
        let hidden: [Unicode.GeneralCategory] = [.control, .format, .lineSeparator, .paragraphSeparator]
        var scalars: [Unicode.Scalar] = []
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let mapped: Unicode.Scalar = hidden.contains(scalar.properties.generalCategory) || scalar == "|" ? " " : scalar
            if mapped.properties.isWhitespace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(mapped)
                lastWasSpace = false
            }
        }
        var cut = Array(trimmed(scalars).prefix(maxTextScalars))
        cut = trimmed(cut)
        guard !cut.isEmpty else { return nil }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: cut)
        return String(result)
    }

    private static func trimmed(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var slice = scalars[...]
        while slice.first == " " { slice = slice.dropFirst() }
        while slice.last == " " { slice = slice.dropLast() }
        return Array(slice)
    }

    // MARK: Read

    /// Reads one raw line, or nil when the text is not one: no `- ` prefix, longer than 460 code points, a date that is not a
    /// real `yyyy-MM-dd` day, a weekday that is not that day's, a time not of the form `h:mm AM` or `h:mm PM`, a kind or a key
    /// that is not a token, an empty place, a place or value that is not clean text, a repeated key, or more than four fields. A
    /// count line (first field `count`) is never a raw line.
    init?(text: String) {
        guard text.hasPrefix("- "), text.unicodeScalars.count <= Self.maxLineScalars else { return nil }
        let parts = Self.split(text.unicodeScalars.dropFirst(2))
        guard (5...(5 + Self.maxFields)).contains(parts.count) else { return nil }
        let (day, weekday, time, kind, place) = (parts[0], parts[1], parts[2], parts[3], parts[4])
        guard let dayWeekday = Self.weekday(ofDay: day), dayWeekday == weekday,
              Self.isTime(time), Self.isToken(kind), Self.clean(place) == place else { return nil }
        var fields: [MemoryField] = []
        for part in parts.dropFirst(5) {
            guard let equals = part.unicodeScalars.firstIndex(of: "=") else { return nil }
            let key = String(part.unicodeScalars[..<equals])
            let value = String(part.unicodeScalars[part.unicodeScalars.index(after: equals)...])
            guard Self.isToken(key), !fields.contains(where: { $0.key == key }), Self.clean(value) == value else { return nil }
            fields.append(MemoryField(key: key, value: value))
        }
        self.init(date: day, weekday: weekday, time: time, kind: kind, place: place, fields: fields)
    }

    /// The texts between the ` | ` separators, found by code point as `clean` writes them: a text that begins with a
    /// combining mark or ends with a prepended mark would otherwise join the separator's space into one Character.
    private static func split(_ scalars: Substring.UnicodeScalarView) -> [String] {
        let mark = Array(separator.unicodeScalars)
        var parts: [String] = []
        var rest = scalars[...]
        while let range = rest.firstRange(of: mark) {
            parts.append(String(rest[..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }
        parts.append(String(rest))
        return parts
    }

    /// A Settings row: the stored line without its leading `- `.
    static func display(_ line: String) -> String {
        line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
    }

    // MARK: Rules

    /// A token: `[a-z][a-z0-9_]{0,19}`.
    private static func isToken(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard (1...20).contains(scalars.count), ("a"..."z").contains(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// The weekday (`Mon` to `Sun`) of a strict `yyyy-MM-dd` day, or nil when the text is not a real Gregorian day.
    private static func weekday(ofDay text: String) -> String? {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
              let year = Int(pieces[0]), let month = Int(pieces[1]), let dayOfMonth = Int(pieces[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == dayOfMonth else { return nil }
        return weekdays[calendar.component(.weekday, from: date) - 1]
    }

    /// `h:mm AM` or `h:mm PM`: an hour 1 to 12 with no leading zero, two minute digits 00 to 59.
    private static func isTime(_ text: String) -> Bool {
        let halves = text.split(separator: " ", omittingEmptySubsequences: false)
        guard halves.count == 2, halves[1] == "AM" || halves[1] == "PM" else { return false }
        let clock = halves[0].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 2, (1...2).contains(clock[0].count), clock[1].count == 2, !clock[0].hasPrefix("0"),
              clock.allSatisfy({ $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
              let hour = Int(clock[0]), let minute = Int(clock[1]) else { return false }
        return (1...12).contains(hour) && (0...59).contains(minute)
    }
}

/// The file `memory.md` in the app's support folder: plain UTF-8, its item lines (lines beginning with `- `) each ended by one
/// line feed, newest last. It keeps no copy in memory and reads the file on every call, so a test that wipes the folder starts
/// with no memory. A missing file reads as no lines; a file that exists but is not UTF-8 text shows no lines and is never
/// overwritten by an add or a single delete (only `removingAll` replaces it). Every write returns the new list, or nil when it
/// failed; the default writer is atomic, so a failed write leaves the file as it was.
struct MemoryBook {
    static let fileName = "memory.md"

    let fileURL: URL
    private let write: @Sendable (Data, URL) throws -> Void

    init(fileURL: URL, write: @escaping @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite) {
        self.fileURL = fileURL
        self.write = write
    }

    /// The file the app uses. Under tests `AppConfig.supportDirectory` is a throw-away folder.
    static func app() -> MemoryBook {
        MemoryBook(fileURL: AppConfig.supportDirectory.appendingPathComponent(fileName))
    }

    /// The item lines in file order.
    func lines() -> [String] { read() ?? [] }

    /// Appends one raw line. Past 200 raw lines the first-written raw lines (topmost in the file, whatever their dates) are
    /// dropped; other item lines (count lines) are neither counted nor dropped, and nothing is merged.
    /// Given a compaction, the item lines are compacted once the line is added, before that cap applies.
    func appending(_ line: MemoryLine, compaction: MemoryCompaction? = nil) -> [String]? {
        guard var items = read() else { return nil }
        items.append(line.text)
        if let compaction { items = compaction.compact(items) }
        var rawCount = items.filter { MemoryLine(text: $0) != nil }.count
        while rawCount > MemoryLine.maxRawLines, let first = items.firstIndex(where: { MemoryLine(text: $0) != nil }) {
            items.remove(at: first)
            rawCount -= 1
        }
        return store(items) ? items : nil
    }

    /// Removes the one item line at `index` (never by value). An index out of range changes nothing and writes nothing.
    func removing(at index: Int) -> [String]? {
        guard var items = read() else { return nil }
        guard items.indices.contains(index) else { return items }
        items.remove(at: index)
        return store(items) ? items : nil
    }

    /// Empties the file, whatever it held.
    func removingAll() -> [String]? {
        store([]) ? [] : nil
    }

    /// The item lines, `[]` for a missing file, nil for a file that exists but cannot be read as UTF-8 text.
    private func read() -> [String]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard Data(text.utf8) == data else { return nil }
        return text.components(separatedBy: "\n").filter {
            $0.hasPrefix("- ") && $0.unicodeScalars.count <= MemoryLine.maxLineScalars
        }
    }

    private func store(_ items: [String]) -> Bool {
        do {
            try write(Data(items.map { $0 + "\n" }.joined().utf8), fileURL)
            return true
        } catch {
            return false
        }
    }
}
