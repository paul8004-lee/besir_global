import Foundation
@testable import besir

/// Fixed clock and time zone of the tool tests: 2026-10-27T09:00 (a Tuesday) in America/Los_Angeles.
/// Nothing here reads the machine's current date, time zone or locale.
enum TestClock {
    static let zone = TimeZone(identifier: "America/Los_Angeles")!
    static let nowString = "2026-10-27T09:00"
    static var now: Date { date(nowString) }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.isLenient = false
        f.dateFormat = pattern
        return f
    }

    /// A local date-time `YYYY-MM-DDTHH:MM` (or with `:SS`) in the fixed zone. A bad literal gives distantPast.
    static func date(_ local: String) -> Date {
        let pattern = local.count > 16 ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd'T'HH:mm"
        return formatter(pattern).date(from: local) ?? .distantPast
    }

    /// The `YYYY-MM-DDTHH:MM` form of a date in the fixed zone.
    static func local(_ date: Date) -> String {
        formatter("yyyy-MM-dd'T'HH:mm").string(from: date)
    }

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

/// The exact texts of spec.md section 3.4 and 3.5, spelled once for the tests.
enum ToolText {
    static func missing(_ param: String) -> String {
        "Ask the user for \(param), then call create_activity again. Do not guess it."
    }
    static func findID(_ tool: String) -> String {
        "Call list_activities to find the event id, or ask the user which event they mean, then call \(tool) again."
    }
    static let listRange = "Call list_activities again with from and to as local date-times, or ask the user which days they mean."
    static func wrongType(_ tool: String, _ param: String) -> String {
        "Call \(tool) again with \(param) as a string, or omit it if the user did not give it."
    }
    static func timeForm(_ tool: String, _ param: String) -> String {
        "Call \(tool) again with \(param) as a local date-time in the form YYYY-MM-DDTHH:MM, or ask the user."
    }
    static func endAfterStart(_ tool: String) -> String {
        "Ask the user for an end time after the start, then call \(tool) again."
    }
    static func tooLong(_ tool: String) -> String {
        "Ask the user for a shorter duration (at most 24 hours), then call \(tool) again."
    }
    static func window(_ tool: String) -> String {
        "Ask the user to confirm the date, then call \(tool) again. The start must be within the past day or the next 366 days."
    }
    static func titleTooLong(_ tool: String) -> String {
        "Call \(tool) again with a title of at most 80 characters, or ask the user for a shorter one."
    }
    static let noChange = "Ask the user what to change, then call update_activity again."
    static let listInvalid = "Call list_activities again with to after from and a range of at most 31 days."
    static func notObject(_ tool: String) -> String {
        "Call \(tool) again with a valid JSON object of arguments."
    }
    static let unknownTool = "That tool does not exist. Answer the user without a tool, or call one of the declared tools."

    static let declined = "The user cancelled. Do not retry the change unless the user asks again."
    static let notFound = "That event no longer exists. Tell the user and ask what to do next."
    static let stale = "That event changed after the card was shown. Tell the user and ask what to do next."
    static let notice = "That event changed or no longer exists. Nothing was changed."
}

extension AgentToolOutcome {
    var card: AgentCard? {
        if case .card(let c) = self { return c }
        return nil
    }
    var resultText: String? {
        if case .result(let s) = self { return s }
        return nil
    }
    var json: [String: Any]? { resultText.flatMap(TestClock.object) }
    /// A card (write call accepted) or a list answer (read call accepted): the gate did not refuse.
    var accepted: Bool { card != nil || json?["items"] != nil }
    var status: String? { json?["status"] as? String }
    var message: String? { json?["message"] as? String }
}

extension AgentResolution {
    var json: [String: Any]? { TestClock.object(result) }
    var status: String? { json?["status"] as? String }
    var message: String? { json?["message"] as? String }
}

/// A Store over the throwaway data directory with a toolbox on the fixed clock. Configuration is blank, so nothing touches the network.
@MainActor
struct ToolHarness {
    let store: Store
    let tools: AgentToolbox

    static func make(now: String = TestClock.nowString) -> ToolHarness {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let instant = TestClock.date(now)
        return ToolHarness(store: store, tools: AgentToolbox(store: store, now: { instant }, timeZone: TestClock.zone))
    }

    func call(_ name: String, _ args: [String: Any]) -> AgentToolOutcome {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return tools.handle(name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    func call(_ name: String, raw: String) -> AgentToolOutcome {
        tools.handle(name: name, arguments: raw)
    }

    /// Puts an activity straight into the Store (local date-times) and returns it.
    @discardableResult
    func seed(_ title: String, _ start: String, _ end: String, location: Place? = nil, recurrence: UUID? = nil) -> ActivityBlock {
        var block = ActivityBlock(title: title, location: location,
                                  startDate: TestClock.date(start), endDate: TestClock.date(end))
        block.recurrenceId = recurrence
        store.activities.append(block)
        return block
    }

    func activity(_ id: UUID) -> ActivityBlock? { store.activities.first { $0.id == id } }

    /// A byte-for-byte picture of everything a tool could change.
    var snapshot: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let a = (try? enc.encode(store.activities)) ?? Data()
        let e = (try? enc.encode(store.events)) ?? Data()
        return String(decoding: a, as: UTF8.self) + "|" + String(decoding: e, as: UTF8.self)
    }
}
