import Foundation

// SPEC-AGENT-001: the four schedule tools. The app, not the model, decides: every argument goes through one
// gate, every write waits for the user's Confirm, and the card shows validated values and Store records only.

enum AgentTools {
    /// JSON array of the four function declarations sent with every request.
    static func declarationsJSON() -> Data { Data(declarations.utf8) }

    private static let declarations = #"""
    [
      {
        "type": "function",
        "name": "list_activities",
        "description": "List the user's schedule items that overlap a date range.",
        "parameters": {
          "type": "object",
          "properties": {
            "from": {"type": "string", "description": "Start of the range as a local date-time, YYYY-MM-DDTHH:MM."},
            "to": {"type": "string", "description": "End of the range as a local date-time, YYYY-MM-DDTHH:MM. After from, at most 31 days later."}
          },
          "required": ["from", "to"],
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "create_activity",
        "description": "Add a new schedule item.",
        "parameters": {
          "type": "object",
          "properties": {
            "title": {"type": "string", "description": "Event title, at most 80 characters."},
            "start": {"type": "string", "description": "Start as a local date-time, YYYY-MM-DDTHH:MM."},
            "end": {"type": "string", "description": "End as a local date-time, YYYY-MM-DDTHH:MM. After start, at most 24 hours later."}
          },
          "required": ["title", "start", "end"],
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "update_activity",
        "description": "Change the title, start or end of an existing schedule item.",
        "parameters": {
          "type": "object",
          "properties": {
            "id": {"type": "string", "description": "Event id returned by list_activities."},
            "title": {"type": "string", "description": "New title, at most 80 characters."},
            "start": {"type": "string", "description": "New start as a local date-time, YYYY-MM-DDTHH:MM."},
            "end": {"type": "string", "description": "New end as a local date-time, YYYY-MM-DDTHH:MM."}
          },
          "required": ["id"],
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "delete_activity",
        "description": "Delete an existing schedule item.",
        "parameters": {
          "type": "object",
          "properties": {
            "id": {"type": "string", "description": "Event id returned by list_activities."}
          },
          "required": ["id"],
          "additionalProperties": false
        }
      }
    ]
    """#
}

/// A pending confirmation card: its English lines, its actions, and a single resolution.
@MainActor
final class AgentCard {
    /// The lines in order, the heading first.
    let lines: [String]
    /// The actions the card offers.
    let actions = ["Confirm", "Cancel"]
    /// Nil while the card is pending.
    private(set) var mark: AgentCardMark?

    private var taken = false
    private let onConfirm: @MainActor () async -> (AgentResolution, AgentCardMark)

    init(lines: [String], onConfirm: @escaping @MainActor () async -> (AgentResolution, AgentCardMark)) {
        self.lines = lines
        self.onConfirm = onConfirm
    }

    /// Acts on the first resolution only and returns its outcome; any later call returns nil.
    func resolve(_ how: AgentCardResolution) async -> AgentResolution? {
        guard !taken else { return nil }
        taken = true
        switch how {
        case .confirm:
            let (resolution, result) = await onConfirm()
            mark = result
            return resolution
        case .cancel, .dismiss:
            mark = .cancelled
            return AgentResolution(result: AgentToolbox.declinedResult, notice: nil)
        }
    }
}

/// A gate refusal: the exact message of spec.md section 3.4.
private struct Rejection: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private enum Tool: String {
    case list = "list_activities"
    case create = "create_activity"
    case update = "update_activity"
    case delete = "delete_activity"

    /// The declared parameters, in declaration order. Nothing else is ever read.
    var params: [String] {
        switch self {
        case .list: return ["from", "to"]
        case .create: return ["title", "start", "end"]
        case .update: return ["id", "title", "start", "end"]
        case .delete: return ["id"]
        }
    }
}

/// The re-ask strings. They lead with the corrective action, fill in declared names only and never repeat a model value.
private enum Say {
    static func missing(_ param: String) -> String {
        "Ask the user for \(param), then call create_activity again. Do not guess it."
    }
    static func findID(_ tool: Tool) -> String {
        "Call list_activities to find the event id, or ask the user which event they mean, then call \(tool.rawValue) again."
    }
    static let listRange = "Call list_activities again with from and to as local date-times, or ask the user which days they mean."
    static func wrongType(_ tool: Tool, _ param: String) -> String {
        "Call \(tool.rawValue) again with \(param) as a string, or omit it if the user did not give it."
    }
    static func timeForm(_ tool: Tool, _ param: String) -> String {
        "Call \(tool.rawValue) again with \(param) as a local date-time in the form YYYY-MM-DDTHH:MM, or ask the user."
    }
    static func endAfterStart(_ tool: Tool) -> String {
        "Ask the user for an end time after the start, then call \(tool.rawValue) again."
    }
    static func tooLong(_ tool: Tool) -> String {
        "Ask the user for a shorter duration (at most 24 hours), then call \(tool.rawValue) again."
    }
    static func window(_ tool: Tool) -> String {
        "Ask the user to confirm the date, then call \(tool.rawValue) again. The start must be within the past day or the next 366 days."
    }
    static func titleTooLong(_ tool: Tool) -> String {
        "Call \(tool.rawValue) again with a title of at most 80 characters, or ask the user for a shorter one."
    }
    static let noChange = "Ask the user what to change, then call update_activity again."
    static let listInvalid = "Call list_activities again with to after from and a range of at most 31 days."
    static func notObject(_ tool: Tool) -> String {
        "Call \(tool.rawValue) again with a valid JSON object of arguments."
    }
    static let unknownTool = "That tool does not exist. Answer the user without a tool, or call one of the declared tools."

    static let declined = "The user cancelled. Do not retry the change unless the user asks again."
    static let notFound = "That event no longer exists. Tell the user and ask what to do next."
    static let stale = "That event changed after the card was shown. Tell the user and ask what to do next."
    static let notice = "That event changed or no longer exists. Nothing was changed."
    static let startPassed = "That start time is now out of range. Nothing was added."
}

/// What a card showed of a record. At Confirm the record must still equal it, or nothing is applied.
private struct Snapshot: Equatable {
    let title: String
    let start: Date
    let end: Date
    let location: Place?
    let recurrenceId: UUID?

    init(_ a: ActivityBlock) {
        title = a.title
        start = a.startDate
        end = a.endDate
        location = a.location
        recurrenceId = a.recurrenceId
    }
}

/// The gate and the Store adapters of the four tools.
@MainActor
final class AgentToolbox {
    private static let maxTitle = 80
    private static let maxDuration: TimeInterval = 24 * 3600
    private static let maxListSpan: TimeInterval = 31 * 24 * 3600
    private static let pastWindow: TimeInterval = 24 * 3600
    private static let futureWindow: TimeInterval = 366 * 24 * 3600
    private static let maxItems = 50

    static var declinedResult: String {
        encode(["status": "declined", "message": Say.declined])
    }

    /// The calendar and the formatters of one time zone.
    private struct Formats {
        let zone: TimeZone
        let calendar: Calendar
        let local: DateFormatter
        let day: DateFormatter
        let time: DateFormatter

        init(zone: TimeZone) {
            self.zone = zone
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            calendar = cal
            func make(_ locale: String, _ pattern: String) -> DateFormatter {
                let f = DateFormatter()
                f.locale = Locale(identifier: locale)
                f.calendar = cal
                f.timeZone = zone
                f.isLenient = false
                f.dateFormat = pattern
                return f
            }
            local = make("en_US_POSIX", "yyyy-MM-dd'T'HH:mm")
            day = make("en_US", "EEE, MMM d, h:mm a")
            time = make("en_US", "h:mm a")
        }
    }

    private let store: Store
    private let now: () -> Date
    private let zone: () -> TimeZone
    private var cachedFormats: Formats?

    /// `timeZone` is read on every use, so a zone change while the app runs reaches dates, cards and the gate.
    init(store: Store, now: @escaping () -> Date, timeZone: @escaping () -> TimeZone) {
        self.store = store
        self.now = now
        zone = timeZone
    }

    convenience init(store: Store, now: @escaping () -> Date, timeZone: TimeZone) {
        self.init(store: store, now: now, timeZone: { timeZone })
    }

    /// The formatters for the zone as it is now; rebuilt only when the zone differs from the last use.
    private var formats: Formats {
        let current = zone()
        if let cachedFormats, cachedFormats.zone == current { return cachedFormats }
        let made = Formats(zone: current)
        cachedFormats = made
        return made
    }

    /// Reads one function call (tool name and the raw arguments string the model sent).
    func handle(name: String, arguments: String) -> AgentToolOutcome {
        guard let tool = Tool(rawValue: name) else { return reject(Say.unknownTool) }
        guard let data = arguments.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return reject(Say.notObject(tool)) }
        do {
            let values = try read(parsed, tool)
            switch tool {
            case .list: return try list(values)
            case .create: return try create(values)
            case .update: return try update(values)
            case .delete: return try delete(values)
            }
        } catch {
            return reject((error as? Rejection)?.message ?? Say.notObject(tool))
        }
    }

    // MARK: - Reading

    private func reject(_ message: String) -> AgentToolOutcome {
        .result(Self.encode(["status": "rejected", "message": message]))
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Only the declared keys, as strings. Undeclared keys are never looked at; a declared key that is not a string
    /// is refused; an empty or blank string is absent.
    private func read(_ object: [String: Any], _ tool: Tool) throws -> [String: String] {
        var values: [String: String] = [:]
        for param in tool.params {
            guard let raw = object[param] else { continue }
            guard let text = raw as? String else { throw Rejection(Say.wrongType(tool, param)) }
            let clean = param == "title" ? Self.sanitized(text) : text
            if clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            values[param] = clean
        }
        return values
    }

    /// Removes the categories Cc, Cf, Zl and Zp, then trims.
    private static func sanitized(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `YYYY-MM-DDTHH:MM` and nothing else; a local time that does not exist is not a date.
    private func localDate(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 16 else { return nil }
        for (i, b) in bytes.enumerated() {
            switch i {
            case 4, 7: if b != 0x2D { return nil }
            case 10: if b != 0x54 { return nil }
            case 13: if b != 0x3A { return nil }
            default: if b < 0x30 || b > 0x39 { return nil }
            }
        }
        let local = formats.local
        guard let date = local.date(from: text), local.string(from: date) == text else { return nil }
        return date
    }

    private func time(_ values: [String: String], _ tool: Tool, _ param: String) throws -> Date? {
        guard let text = values[param] else { return nil }
        guard let date = localDate(text) else { throw Rejection(Say.timeForm(tool, param)) }
        return date
    }

    private func checkTitle(_ title: String?, _ tool: Tool) throws {
        if let title, title.count > Self.maxTitle { throw Rejection(Say.titleTooLong(tool)) }
    }

    private func checkWindow(_ start: Date, _ tool: Tool) throws {
        let minute = (now().timeIntervalSince1970 / 60).rounded(.down) * 60
        let earliest = Date(timeIntervalSince1970: minute - Self.pastWindow)
        let latest = Date(timeIntervalSince1970: minute + Self.futureWindow)
        if start < earliest || start > latest { throw Rejection(Say.window(tool)) }
    }

    private func checkSpan(from start: Date, to end: Date, _ tool: Tool) throws {
        if end <= start { throw Rejection(Say.endAfterStart(tool)) }
        if end.timeIntervalSince(start) > Self.maxDuration { throw Rejection(Say.tooLong(tool)) }
    }

    /// The record an id names, or the find-the-event refusal.
    private func record(_ values: [String: String], _ tool: Tool) throws -> ActivityBlock {
        guard let text = values["id"], let id = UUID(uuidString: text),
              let found = store.activities.first(where: { $0.id == id })
        else { throw Rejection(Say.findID(tool)) }
        return found
    }

    // MARK: - Tools

    private func list(_ values: [String: String]) throws -> AgentToolOutcome {
        guard values["from"] != nil, values["to"] != nil else { throw Rejection(Say.listRange) }
        guard let from = try time(values, .list, "from"), let to = try time(values, .list, "to") else {
            throw Rejection(Say.listRange)
        }
        if to <= from || to.timeIntervalSince(from) > Self.maxListSpan { throw Rejection(Say.listInvalid) }

        let hits = store.activities.enumerated()
            .filter { $0.element.startDate < to && $0.element.endDate > from }
            .sorted { ($0.element.startDate, $0.offset) < ($1.element.startDate, $1.offset) }
        let local = formats.local
        let items: [[String: Any]] = hits.prefix(Self.maxItems).map { hit in
            let a = hit.element
            var item: [String: Any] = ["id": a.id.uuidString, "title": Self.sanitized(a.title), "start": local.string(from: a.startDate),
                                       "end": local.string(from: a.endDate), "recurring": a.recurrenceId != nil]
            if let place = a.location { item["location"] = Self.sanitized(place.name) }
            return item
        }
        return .result(Self.encode(["items": items, "count": items.count, "truncated": hits.count > Self.maxItems]))
    }

    private func create(_ values: [String: String]) throws -> AgentToolOutcome {
        for param in Tool.create.params where values[param] == nil { throw Rejection(Say.missing(param)) }
        guard let title = values["title"], let start = try time(values, .create, "start"),
              let end = try time(values, .create, "end")
        else { throw Rejection(Say.missing("title")) }
        try checkSpan(from: start, to: end, .create)
        try checkWindow(start, .create)
        try checkTitle(title, .create)

        let lines = ["Add event", title, range(start, end)]
        return .card(AgentCard(lines: lines) { [self] in
            // The card may have waited a long time: the start must still be inside the window the gate allows.
            do { try checkWindow(start, .create) } catch {
                let result = Self.encode(["status": "rejected", "message": Say.window(.create)])
                return (AgentResolution(result: result, notice: Say.startPassed), .notApplied)
            }
            let made = await store.addActivityWithTravel(
                title: title, location: nil, startDate: start, endDate: end, travelFrom: nil, returnTo: nil,
                outboundMode: .walk, returnMode: .walk, bufferMinutes: 0, notifyLeadMinutes: 0,
                syncToCalendar: store.calendarSyncDefault)
            return applied(made.activityId)
        })
    }

    private func update(_ values: [String: String]) throws -> AgentToolOutcome {
        let current = try record(values, .update)
        if values["title"] == nil, values["start"] == nil, values["end"] == nil { throw Rejection(Say.noChange) }
        let start = try time(values, .update, "start")
        let end = try time(values, .update, "end")

        var newStart = current.startDate
        var newEnd = current.endDate
        switch (start, end) {
        case let (s?, e?):
            try checkSpan(from: s, to: e, .update)
            try checkWindow(s, .update)
            newStart = s
            newEnd = e
        case let (s?, nil):
            // The end moves with the start: the duration of the record is kept, whatever it is.
            try checkWindow(s, .update)
            newStart = s
            newEnd = s.addingTimeInterval(current.endDate.timeIntervalSince(current.startDate))
        case let (nil, e?):
            try checkSpan(from: current.startDate, to: e, .update)
            newEnd = e
        case (nil, nil):
            break
        }
        try checkTitle(values["title"], .update)

        let newTitle = values["title"]
        let id = current.id
        let seen = Snapshot(current)
        var lines = ["Change event", "Was: \(Self.sanitized(current.title))", range(current.startDate, current.endDate),
                     "Now: \(newTitle ?? Self.sanitized(current.title))", range(newStart, newEnd)]
        lines += extraLines(current)
        return .card(AgentCard(lines: lines) { [self] in
            if let gone = vanishedOrChanged(id, seen) { return gone }
            store.modifyActivity(id: id, newTitle: newTitle, newStart: start, newEnd: end)
            return applied(id)
        })
    }

    private func delete(_ values: [String: String]) throws -> AgentToolOutcome {
        let current = try record(values, .delete)
        let id = current.id
        let seen = Snapshot(current)
        let lines = ["Delete event", Self.sanitized(current.title), range(current.startDate, current.endDate)] + extraLines(current)
        return .card(AgentCard(lines: lines) { [self] in
            if let gone = vanishedOrChanged(id, seen) { return gone }
            guard let target = store.activities.first(where: { $0.id == id }) else { return (notFound(), .notApplied) }
            store.deleteActivity(target)
            return (AgentResolution(result: Self.encode(["status": "applied", "id": id.uuidString]), notice: nil), .confirmed)
        })
    }

    // MARK: - Cards and results

    /// `At <place>` and the repeating-event line, from the Store record.
    private func extraLines(_ record: ActivityBlock) -> [String] {
        var lines: [String] = []
        if let place = record.location { lines.append("At \(Self.sanitized(place.name))") }
        if record.recurrenceId != nil { lines.append("Only this occurrence of a repeating event.") }
        return lines
    }

    private func range(_ start: Date, _ end: Date) -> String {
        let f = formats
        let second = f.calendar.isDate(start, inSameDayAs: end) ? f.time : f.day
        return "\(f.day.string(from: start)) - \(second.string(from: end))"
    }

    private func notFound() -> AgentResolution {
        AgentResolution(result: Self.encode(["status": "not_found", "message": Say.notFound]), notice: Say.notice)
    }

    /// The apply-time check: the record is still there and still equals what the card showed.
    private func vanishedOrChanged(_ id: UUID, _ seen: Snapshot) -> (AgentResolution, AgentCardMark)? {
        guard let present = store.activities.first(where: { $0.id == id }) else { return (notFound(), .notApplied) }
        if Snapshot(present) != seen {
            return (AgentResolution(result: Self.encode(["status": "stale", "message": Say.stale]), notice: Say.notice), .notApplied)
        }
        return nil
    }

    /// `applied`, with the values read back from the Store.
    private func applied(_ id: UUID) -> (AgentResolution, AgentCardMark) {
        guard let stored = store.activities.first(where: { $0.id == id }) else { return (notFound(), .notApplied) }
        let local = formats.local
        let result = Self.encode(["status": "applied", "id": stored.id.uuidString, "title": Self.sanitized(stored.title),
                                  "start": local.string(from: stored.startDate),
                                  "end": local.string(from: stored.endDate)])
        return (AgentResolution(result: result, notice: nil), .confirmed)
    }
}
