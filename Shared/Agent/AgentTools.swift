import Foundation
import Combine
import CoreLocation

// SPEC-AGENT-001: the four schedule tools, SPEC-AGENTPLACE-001: the place and travel-time tools. The app, not the
// model, decides: every argument goes through one gate, every write waits for the user's Confirm, and the card shows
// validated values and Store records only. SPEC-PLANDAY-001 adds the two day plan tools and the plan turn.

enum AgentTools {
    /// JSON array of the thirteen function declarations sent with every request.
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
            "end": {"type": "string", "description": "End as a local date-time, YYYY-MM-DDTHH:MM. After start, at most 24 hours later."},
            "place_id": {"type": "string", "description": "Optional. A place_id returned by search_places, for where the event takes place."},
            "route_id": {"type": "string", "description": "Optional. The route_id returned by get_travel_time for the trip to that place."}
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
      },
      {
        "type": "function",
        "name": "search_places",
        "description": "Look up places by name or kind. Returns up to five places with a place_id for each.",
        "parameters": {
          "type": "object",
          "properties": {
            "query": {"type": "string", "description": "What to look for, such as a business name or a kind of place, 2 to 80 characters."}
          },
          "required": ["query"],
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "get_travel_time",
        "description": "Look up the travel time to a place found with search_places. Returns a route_id and the minutes.",
        "parameters": {
          "type": "object",
          "properties": {
            "place_id": {"type": "string", "description": "The destination: a place_id returned by search_places."},
            "mode": {"type": "string", "description": "How the user travels: car, transit, walk or bicycle. The user chooses; ask them if they have not said."},
            "origin_place_id": {"type": "string", "description": "Optional starting point: a place_id returned by search_places. Omit it to start from the user's current location."},
            "arrive_by": {"type": "string", "description": "Optional arrival time as a local date-time, YYYY-MM-DDTHH:MM. When given, the result also states when to leave."}
          },
          "required": ["place_id", "mode"],
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "check_day_plan",
        "description": "Check the stops of a day plan against the user's schedule. The app finds overlaps and late arrivals and works out every travel time. Returns a plan_id.",
        "parameters": {
          "type": "object",
          "properties": {
            "stops": {"type": "string", "description": "A JSON array of 1 to 8 stops. A new stop is an object with title, start and end as local date-times (YYYY-MM-DDTHH:MM) and optionally a place_id returned by search_places. An existing event is an object with event set to its id from the plan message; it may also have a place_id."}
          },
          "required": ["stops"],
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "show_day_plan",
        "description": "Show the user a checked day plan to add to their schedule. The user confirms before anything is added.",
        "parameters": {
          "type": "object",
          "properties": {
            "plan_id": {"type": "string", "description": "The plan_id returned by check_day_plan."}
          },
          "required": ["plan_id"],
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "get_budget_left",
        "description": "Look up how much of this week's dining budget is left in a simulated budget app. The budget app is simulated, not a real one: always call the result simulated. Takes no arguments.",
        "parameters": {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "record_spend",
        "description": "Record money the user spent on food or dining in a simulated budget app. The budget app is simulated, not a real one: always call the result simulated. It records at once with no confirmation, so call it only with an amount the user has stated.",
        "parameters": {
          "type": "object",
          "properties": {
            "amount": {"type": "string", "description": "The amount in US dollars, digits with an optional decimal point and up to two decimals, such as 18.50. No sign, comma or currency sign. Ask the user if they have not said."}
          },
          "required": ["amount"],
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "get_delivery_options",
        "description": "Look up what a simulated delivery app offers: its items with estimated prices, its delivery fee and the cards it holds. The delivery app is simulated, not a real one: always call the result simulated. Call it before order_delivery. Takes no arguments.",
        "parameters": {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "order_delivery",
        "description": "Order food delivery from a restaurant found with search_places, in a simulated delivery app, with items and a card taken from get_delivery_options. The delivery app is simulated, not a real one: always call the result simulated. items is written as item_id:quantity pairs separated by commas, such as ramen:2,gyoza:1. Ask the user for the arrival time, the items and the card if they have not said. deliver_to is a place_id from search_places, set only when the user named a place to deliver to and left out otherwise; the app may then suggest a place from the schedule. Never write an address. The user confirms before anything is sent.",
        "parameters": {
          "type": "object",
          "properties": {
            "place_id": {"type": "string", "description": "The restaurant: a place_id returned by search_places."},
            "arrive_at": {"type": "string", "description": "When the food is to arrive, as a local date-time, YYYY-MM-DDTHH:MM. Ask the user if they have not said."},
            "items": {"type": "string", "description": "What to order: item_id:quantity pairs separated by commas with no spaces, 1 to 6 pairs, each quantity 1 to 9, such as ramen:2,gyoza:1. Use item_id values from get_delivery_options. Ask the user if they have not said."},
            "card_id": {"type": "string", "description": "The card to pay with: a card_id from get_delivery_options. Ask the user if they have not said."},
            "deliver_to": {"type": "string", "description": "Optional. A place_id returned by search_places, set only when the user named a place to deliver to. Leave it out otherwise."}
          },
          "required": ["place_id", "arrive_at", "items", "card_id"],
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "request_booking",
        "description": "Ask a simulated table-booking partner for a table at a place found with search_places. The booking is simulated, not a real reservation: always call the result simulated. The user confirms before anything is sent.",
        "parameters": {
          "type": "object",
          "properties": {
            "place_id": {"type": "string", "description": "The restaurant: a place_id returned by search_places."},
            "start": {"type": "string", "description": "The time of the table as a local date-time, YYYY-MM-DDTHH:MM. Ask the user if they have not said."},
            "party_size": {"type": "string", "description": "How many people the table is for, 1 to 12. Ask the user if they have not said."}
          },
          "required": ["place_id", "start", "party_size"],
          "additionalProperties": false
        }
      }
    ]
    """#
}

/// SPEC-DELIVERY-001: one value the user changes inside a confirmation card. The view observes it. Once frozen it keeps the value
/// it had, so an edit made after the Confirm tap changes nothing.
@MainActor
class AgentCardField<Value: Equatable>: ObservableObject {
    @Published var value: Value {
        didSet { settle(oldValue) }
    }
    private(set) var isFrozen = false

    private var settling = false
    private let normalize: (Value) -> Value

    init(_ value: Value, normalize: @escaping (Value) -> Value = { $0 }) {
        self.value = value
        self.normalize = normalize
    }

    func freeze() { isFrozen = true }

    private func settle(_ old: Value) {
        guard !settling else { return }
        settling = true
        defer { settling = false }
        let next = isFrozen ? old : normalize(value)
        if next != value { value = next }
    }
}

/// A text the user types in the card. Per keystroke it only removes hidden characters and cuts at `limit` scalars; it never trims
/// (the one trim and the blank check are made at Confirm, on the snapshot).
@MainActor
final class AgentCardText: AgentCardField<String> {
    let limit: Int
    /// The app's own suggestion, or nil when the value is not one.
    let suggestion: String?

    init(text: String, limit: Int, suggestion: String?) {
        self.limit = limit
        self.suggestion = suggestion
        super.init(AgentDelivery.cleanedTyped(text, limit: limit), normalize: { AgentDelivery.cleanedTyped($0, limit: limit) })
    }

    var text: String {
        get { value }
        set { value = newValue }
    }
    /// True while the value is the app's suggestion.
    var isSuggestion: Bool { suggestion != nil && text == suggestion }
    var isBlank: Bool { AgentDelivery.snapshotText(text) == nil }
}

/// A switch in the card.
@MainActor
final class AgentCardSwitch: AgentCardField<Bool> {
    init(isOn: Bool) { super.init(isOn) }

    var isOn: Bool {
        get { value }
        set { value = newValue }
    }
}

/// A time in the card: it keeps the date of `arrival` and has no seconds.
@MainActor
final class AgentCardTime: AgentCardField<Date> {
    let arrival: Date
    let calendar: Calendar

    init(start: Date, arrival: Date, calendar: Calendar) {
        self.arrival = arrival
        self.calendar = calendar
        super.init(start, normalize: { date in
            let time = calendar.dateComponents([.hour, .minute], from: date)
            return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0,
                                 of: calendar.startOfDay(for: arrival)) ?? date
        })
    }

    var start: Date {
        get { value }
        set { value = newValue }
    }
    /// True while the time is the arrival time the app suggested.
    var isSuggestion: Bool { start == arrival }
}

/// The editors of one card, and the one object the view observes for all of them.
@MainActor
final class AgentCardEditors: ObservableObject {
    /// What the editors hold at a moment: the snapshot that Confirm takes.
    struct Values: Equatable {
        let deliveryText: String?
        let mealOn: Bool
        let mealTitle: String?
        let mealStart: Date?
    }

    let delivery: AgentCardText?
    let mealOn: AgentCardSwitch?
    let mealTitle: AgentCardText?
    let mealStart: AgentCardTime?
    private(set) var isFrozen = false
    private var forwards: [AnyCancellable] = []

    init(delivery: AgentCardText? = nil, mealOn: AgentCardSwitch? = nil, mealTitle: AgentCardText? = nil,
         mealStart: AgentCardTime? = nil) {
        self.delivery = delivery
        self.mealOn = mealOn
        self.mealTitle = mealTitle
        self.mealStart = mealStart
        let changes = [delivery?.objectWillChange, mealOn?.objectWillChange, mealTitle?.objectWillChange, mealStart?.objectWillChange]
        forwards = changes.compactMap { $0 }.map { $0.sink { [weak self] _ in self?.objectWillChange.send() } }
    }

    var isEmpty: Bool { delivery == nil && mealOn == nil && mealTitle == nil && mealStart == nil }

    /// False while the delivery text, or a title that is switched on, is blank after trimming. It only reads the values.
    var canConfirm: Bool {
        if let delivery, delivery.isBlank { return false }
        if mealOn?.isOn == true, let mealTitle, mealTitle.isBlank { return false }
        return true
    }

    var values: Values {
        Values(deliveryText: delivery?.text, mealOn: mealOn?.isOn ?? false, mealTitle: mealTitle?.text, mealStart: mealStart?.start)
    }

    func freeze() {
        isFrozen = true
        delivery?.freeze()
        mealOn?.freeze()
        mealTitle?.freeze()
        mealStart?.freeze()
    }
}

/// One row of a card. A row of an editable value carries its line and the mark the line holds; the view draws it as a control
/// while the card waits.
enum AgentCardRow: Equatable {
    case text(String)
    /// The delivery line, `To <text>` and its mark.
    case delivery(line: String, mark: String)
    /// The meal entry: its line (nil while the switch is off) and its mark.
    case meal(line: String?, mark: String)

    var line: String? {
        switch self {
        case .text(let line), .delivery(let line, _): return line
        case .meal(let line, _): return line
        }
    }
}

/// A pending confirmation card: its English lines, its actions, and a single resolution.
@MainActor
final class AgentCard {
    /// The lines in order, the heading first; for a card with editors they are read from the editors.
    var lines: [String] { makeRows == nil ? fixedLines : rows.compactMap(\.line) }
    /// The rows in order; a row of an editable value tells the view where a control goes.
    var rows: [AgentCardRow] { makeRows?() ?? fixedLines.map { .text($0) } }
    /// The values the user can change in this card (empty for every card but a delivery card).
    let editors: AgentCardEditors
    /// False while an edited value is blank; the chat disables Confirm then.
    var canConfirm: Bool { editors.canConfirm }
    /// The actions the card offers.
    let actions = ["Confirm", "Cancel"]
    /// Nil while the card is pending.
    private(set) var mark: AgentCardMark?
    /// True when the card carries Google place or route data, so the chat draws the Google Maps mark inside it
    /// (SPEC-AGENTPLACE-001).
    let showsGoogleMark: Bool

    private var taken = false
    private let fixedLines: [String]
    private let makeRows: (@MainActor () -> [AgentCardRow])?
    private let onConfirm: @MainActor () async -> (AgentResolution, AgentCardMark)

    init(lines: [String], showsGoogleMark: Bool = false,
         onConfirm: @escaping @MainActor () async -> (AgentResolution, AgentCardMark)) {
        fixedLines = lines
        makeRows = nil
        editors = AgentCardEditors()
        self.showsGoogleMark = showsGoogleMark
        self.onConfirm = onConfirm
    }

    /// SPEC-DELIVERY-001: a card whose rows are read from its editors.
    init(editors: AgentCardEditors, showsGoogleMark: Bool = false, rows: @escaping @MainActor () -> [AgentCardRow],
         onConfirm: @escaping @MainActor () async -> (AgentResolution, AgentCardMark)) {
        fixedLines = []
        makeRows = rows
        self.editors = editors
        self.showsGoogleMark = showsGoogleMark
        self.onConfirm = onConfirm
    }

    /// Acts on the first resolution only and returns its outcome; any later call returns nil. Confirm freezes the editors before
    /// it awaits the closure, so no edit made after the tap changes anything.
    func resolve(_ how: AgentCardResolution) async -> AgentResolution? {
        guard !taken else { return nil }
        taken = true
        switch how {
        case .confirm:
            editors.freeze()
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
    case search = "search_places"
    case travel = "get_travel_time"
    case booking = "request_booking"
    case checkDay = "check_day_plan"
    case showDay = "show_day_plan"
    case budgetLeft = "get_budget_left"
    case spend = "record_spend"
    case deliveryOptions = "get_delivery_options"
    case delivery = "order_delivery"

    /// The declared parameters, in declaration order. Nothing else is ever read.
    var params: [String] {
        switch self {
        case .list: return ["from", "to"]
        case .create: return ["title", "start", "end", "place_id", "route_id"]
        case .update: return ["id", "title", "start", "end"]
        case .delete: return ["id"]
        case .search: return ["query"]
        case .travel: return ["place_id", "mode", "origin_place_id", "arrive_by"]
        case .booking: return ["place_id", "start", "party_size"]
        case .checkDay: return ["stops"]
        case .showDay: return ["plan_id"]
        case .budgetLeft: return []
        case .spend: return ["amount"]
        case .deliveryOptions: return []
        case .delivery: return ["place_id", "arrive_at", "items", "card_id", "deliver_to"]
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
        // Every booking argument is required, so "omit it" would be the wrong advice for this tool.
        if tool == .booking {
            return "Call request_booking again with \(param) as a string. If you do not have it, ask the user; do not guess it."
        }
        // The day plan tools have their own fixed lines.
        if tool == .checkDay { return AgentDayPlan.Say.stopsFormat }
        if tool == .showDay { return AgentDayPlan.Say.planUnknown }
        // The one budget argument is required, so "omit it" would be the wrong advice here too.
        if tool == .spend { return "Call record_spend again with \(param) as a string. If you do not have it, ask the user; do not guess it." }
        // Four delivery arguments are required, so "omit it" is right for the optional deliver_to only.
        if tool == .delivery, param != "deliver_to" {
            return "Call order_delivery again with \(param) as a string. If you do not have it, ask the user; do not guess it."
        }
        return "Call \(tool.rawValue) again with \(param) as a string, or omit it if the user did not give it."
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

    // SPEC-AGENTPLACE-001, spec.md section 2.3.
    static let queryMissing = "Ask the user what place to look for, then call search_places again. Do not guess it."
    static let queryLong = "Call search_places again with a shorter query, or ask the user for a shorter one."
    static let findPlace = "Call search_places to find the place, then call get_travel_time again with the place_id it returns."
    static let mode = "Call get_travel_time again with mode set to how the user wants to travel, or ask the user."
    static let originPlace = "Call search_places to find the starting place, then call get_travel_time again with its place_id as origin_place_id, or omit origin_place_id to start from the user's current location."
    static let arriveWindow = "Ask the user to confirm the date, then call get_travel_time again. The arrival time must be within the past day or the next 366 days."
    static let noOrigin = "Ask the user to turn on location access or to name a starting place, search for it with search_places, then call get_travel_time again with its place_id as origin_place_id."
    static let createPlace = "Call search_places to find the place, then call create_activity again with the place_id it returns, or omit place_id."
    static let createRoute = "Call get_travel_time again for this place and mode, then call create_activity again with the route_id it returns, or omit route_id."
    static let createMismatch = "Call create_activity again with a place_id that matches the route_id, or omit place_id."
    static let routeExpired = "Call get_travel_time again, then call create_activity again with the new route_id."
    static let routeExpiredNotice = "The travel time is out of date. Nothing was added."

    // SPEC-BOOKING-001: each string names only request_booking or search_places.
    static let bookPlace = "Call search_places to find the place, then call request_booking again with the place_id it returns."
    static let bookStart = "Ask the user for the time, then call request_booking again. Do not guess it."
    static let bookWindow = "Ask the user to confirm the date, then call request_booking again. The start must be a time that has not passed and be within the next 366 days."
    static let bookParty = "Ask the user how many people the table is for, then call request_booking again. Do not guess it."
    static let bookUnavailable = "Tell the user booking is not available right now. Do not call request_booking again."

    // SPEC-BUDGET-001: each string names only get_budget_left or record_spend and the one declared parameter.
    static let spendAmount = "Ask the user how much they spent, as digits with an optional decimal point such as 18.50, then call record_spend again. Do not guess it."
    static let budgetUnavailable = "Tell the user the budget is not available right now. Do not call get_budget_left or record_spend again."

    // SPEC-DELIVERY-001: each string names only get_delivery_options, order_delivery, search_places and the declared parameters.
    static let deliveryPlace = "Call search_places to find the restaurant, then call order_delivery again with the place_id it returns."
    static let deliveryTime = "Ask the user when the food is to arrive, then call order_delivery again. Do not guess it."
    static let deliveryWindow = "Ask the user to confirm the date, then call order_delivery again. The arrive_at time must be a time that has not passed and be within the next 366 days."
    static let deliveryOptionsFirst = "Call get_delivery_options first, then call order_delivery again with items and card_id taken from its answer."
    static let deliveryItems = "Ask the user what to order, then call order_delivery again with items as comma-separated pairs of an item id from the get_delivery_options answer and a quantity from 1 to 9, 1 to 6 pairs, no spaces, no id repeated. Do not guess it."
    static let deliveryItemUnknown = "Call order_delivery again with items that use only item ids from the get_delivery_options answer, or ask the user what to order."
    static let deliveryCard = "Ask the user which card to pay with, then call order_delivery again with card_id from the get_delivery_options answer. Do not guess it."
    static let deliveryCardUnknown = "Call order_delivery again with a card_id from the get_delivery_options answer, or ask the user which card to pay with."
    static let deliveryTo = "Ask the user where to deliver. If they name a place, call search_places for it, then call order_delivery again with its place_id as deliver_to."
    static let deliveryToHandle = "Call search_places for the place to deliver to, then call order_delivery again with its place_id as deliver_to, or leave deliver_to out."
    static let deliveryUnavailable = "Tell the user delivery is not available right now. Do not call order_delivery again."
    static let deliveryOptionsUnavailable = "Tell the user delivery is not available right now. Do not call get_delivery_options or order_delivery again."

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

    /// SPEC-AGENTPLACE-001: the handles of places and routes the model may use, and the injected sources of a lookup.
    /// All three providers default to the Store's own services; tests inject stub transports through them.
    var registry = AgentPlaceRegistry()
    let deviceOrigin: () -> Place?
    let placeSearchProvider: (() -> PlaceSearch)?
    let directionsProvider: (() -> DirectionsService)?
    /// SPEC-BOOKING-001: the booking client, built on use from the live configuration; tests inject a stubbed one.
    let bookingProvider: (() -> BookingClient)?
    /// SPEC-BUDGET-001: the budget client, built on use from the live configuration; tests inject a stubbed one.
    let budgetProvider: (() -> BudgetClient)?
    /// SPEC-DELIVERY-001: the delivery client and the order record, built on use; tests inject stubbed ones.
    let deliveryProvider: (() -> DeliveryClient)?
    let deliveryOrdersProvider: (() -> DeliveryOrderLog)?
    /// The partner's last good options answer. In memory only: the next good answer replaces it and a new chat forgets it.
    private var deliveryOptions: DeliveryOptions?

    /// `timeZone` is read on every use, so a zone change while the app runs reaches dates, cards and the gate.
    init(store: Store, now: @escaping () -> Date, timeZone: @escaping () -> TimeZone,
         deviceOrigin: @escaping () -> Place? = { nil },
         places: (() -> PlaceSearch)? = nil,
         directions: (() -> DirectionsService)? = nil,
         booking: (() -> BookingClient)? = nil,
         budget: (() -> BudgetClient)? = nil,
         delivery: (() -> DeliveryClient)? = nil,
         deliveryOrders: (() -> DeliveryOrderLog)? = nil) {
        self.store = store
        self.now = now
        zone = timeZone
        self.deviceOrigin = deviceOrigin
        placeSearchProvider = places
        directionsProvider = directions
        bookingProvider = booking
        budgetProvider = budget
        deliveryProvider = delivery
        deliveryOrdersProvider = deliveryOrders
    }

    convenience init(store: Store, now: @escaping () -> Date, timeZone: TimeZone,
                     deviceOrigin: @escaping () -> Place? = { nil },
                     places: (() -> PlaceSearch)? = nil,
                     directions: (() -> DirectionsService)? = nil,
                     booking: (() -> BookingClient)? = nil,
                     budget: (() -> BudgetClient)? = nil,
                     delivery: (() -> DeliveryClient)? = nil,
                     deliveryOrders: (() -> DeliveryOrderLog)? = nil) {
        self.init(store: store, now: now, timeZone: { timeZone }, deviceOrigin: deviceOrigin,
                  places: places, directions: directions, booking: booking, budget: budget,
                  delivery: delivery, deliveryOrders: deliveryOrders)
    }

    /// New chat: forgets the handles; the counters keep counting up, so an old handle never names a new entry. The held
    /// delivery options go too.
    func resetConversation() {
        registry.clear()
        deliveryOptions = nil
        endDayPlan()
    }

    // MARK: - Plan turn state (SPEC-PLANDAY-001)

    /// Set while a plan turn is active; the two day plan tools exist only then.
    private(set) var dayPlan: DayPlanContext?
    /// The checks made in this plan turn, oldest first. The latest one is the only one `show_day_plan` may show.
    private(set) var checks: [AgentDayPlan.Check] = []
    /// `search_places` calls accepted in this plan turn.
    private(set) var searchesThisPlan = 0
    /// Set by the stale refusal of `show_day_plan`: one check more than the usual three is allowed in this turn.
    private(set) var extraCheckGranted = false
    /// The next plan handle number; it counts up for the session, so an old handle never names a new check.
    private var nextPlanNumber = 1

    /// Starts a plan turn: the counters and the stored checks of an earlier turn are gone.
    func beginDayPlan(_ context: DayPlanContext) {
        dayPlan = context
        checks = []
        searchesThisPlan = 0
        extraCheckGranted = false
    }

    /// Ends the plan turn (the next ordinary message, or a new chat).
    func endDayPlan() {
        dayPlan = nil
        checks = []
        searchesThisPlan = 0
        extraCheckGranted = false
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
    /// - `flow`: the Connections flow of the user message that caused the call. Only the two Google lookups, the two budget lookups and the delivery options lookup read it.
    func handle(name: String, arguments: String, flow: UUID? = nil) -> AgentToolOutcome {
        guard let tool = Tool(rawValue: name) else { return reject(Say.unknownTool) }
        // SPEC-PLANDAY-001: the rules of a plan turn come before any argument is read.
        switch tool {
        case .checkDay, .showDay:
            if dayPlan == nil { return reject(AgentDayPlan.Say.notInPlanTurn) }
        case .travel:
            if dayPlan != nil { return reject(AgentDayPlan.Say.travelRefused) }
        case .search:
            if dayPlan != nil, searchesThisPlan >= AgentDayPlan.searchesPerTurn { return reject(AgentDayPlan.Say.searchLimit) }
        case .budgetLeft, .spend:
            // SPEC-BUDGET-001: both budget tools need the proxy, and this check comes before any argument is read.
            if !budgetClient().isConfigured { return reject(Say.budgetUnavailable) }
        case .deliveryOptions:
            // SPEC-DELIVERY-001: the options tool needs the proxy, and this check comes before any argument is read.
            if !deliveryClient().isConfigured { return reject(Say.deliveryOptionsUnavailable) }
        default:
            break
        }
        // A blank arguments text is `{}` for the two tools that take no argument; every other tool keeps `Say.notObject`.
        let text = (tool == .budgetLeft || tool == .deliveryOptions) && arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "{}" : arguments
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return reject(Say.notObject(tool)) }
        do {
            let values = try read(parsed, tool)
            switch tool {
            case .list: return try list(values)
            case .create: return try create(values)
            case .update: return try update(values)
            case .delete: return try delete(values)
            case .search: return try search(values, flow: flow)
            case .travel: return try travel(values, flow: flow)
            case .booking: return try book(values)
            case .checkDay: return try checkDayPlan(values, flow: flow)
            case .showDay: return try showDayPlan(values)
            case .budgetLeft: return budgetLeft(flow: flow)
            case .spend: return try recordSpend(values, flow: flow)
            case .deliveryOptions: return deliveryOptionsLookup(flow: flow)
            case .delivery: return try orderDelivery(values)
            }
        } catch {
            return reject((error as? Rejection)?.message ?? Say.notObject(tool))
        }
    }

    // MARK: - Reading

    private func reject(_ message: String) -> AgentToolOutcome {
        .result(Self.encode(["status": "rejected", "message": message]))
    }

    nonisolated static func encode(_ object: [String: Any]) -> String {
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
            let clean = param == "title" || param == "query" ? Self.sanitized(text) : text
            if clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            values[param] = clean
        }
        return values
    }

    /// Removes the categories Cc, Cf, Zl and Zp, then trims. Shared with `AgentPlaces` so there is one sanitizer.
    nonisolated static func sanitized(_ title: String) -> String {
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

    private func withinWindow(_ date: Date) -> Bool {
        let minute = (now().timeIntervalSince1970 / 60).rounded(.down) * 60
        let earliest = Date(timeIntervalSince1970: minute - Self.pastWindow)
        let latest = Date(timeIntervalSince1970: minute + Self.futureWindow)
        return date >= earliest && date <= latest
    }

    private func checkWindow(_ start: Date, _ tool: Tool) throws {
        if !withinWindow(start) { throw Rejection(Say.window(tool)) }
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

        let local = formats.local
        var hits: [(start: Date, item: [String: Any])] = store.activities.enumerated()
            .filter { $0.element.startDate < to && $0.element.endDate > from }
            .sorted { ($0.element.startDate, $0.offset) < ($1.element.startDate, $1.offset) }
            .map { hit in
                let a = hit.element
                var item: [String: Any] = ["id": a.id.uuidString, "title": Self.sanitized(a.title), "start": local.string(from: a.startDate),
                                           "end": local.string(from: a.endDate), "recurring": a.recurrenceId != nil]
                if let place = a.location { item["location"] = Self.sanitized(place.name) }
                return (a.startDate, item)
            }
        // In a plan turn the calendar entries besir did not write are listed too, from the events the plan message showed
        // (so the model finds the same e1... ids here); only they carry a `source`.
        let calendarHits = (dayPlan?.events ?? []).filter { $0.source == .calendar && $0.start < to && $0.end > from }
        for event in calendarHits {
            var item: [String: Any] = ["id": event.handle, "title": Self.sanitized(event.title), "start": local.string(from: event.start),
                                       "end": local.string(from: event.end), "recurring": false, "source": event.source.rawValue]
            if let text = event.locationText { item["location"] = Self.sanitized(text) }
            hits.append((event.start, item))
        }
        // Stable: a besir activity and a calendar entry starting together keep the Store item first.
        let ordered = hits.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element.item)
        let items = Array(ordered.prefix(Self.maxItems))
        var result: [String: Any] = ["items": items, "count": items.count, "truncated": ordered.count > Self.maxItems]
        // Only in a plan turn whose calendar could not be read: an empty list is then not a clear day.
        if dayPlan?.calendarAvailable == false { result["calendar_available"] = false }
        return .result(Self.encode(result))
    }

    private func create(_ values: [String: String]) throws -> AgentToolOutcome {
        for param in ["title", "start", "end"] where values[param] == nil { throw Rejection(Say.missing(param)) }
        guard let title = values["title"], let start = try time(values, .create, "start"),
              let end = try time(values, .create, "end")
        else { throw Rejection(Say.missing("title")) }
        try checkSpan(from: start, to: end, .create)
        try checkWindow(start, .create)
        try checkTitle(title, .create)
        let trip = try resolveTrip(values)

        var lines = ["Add event", title, range(start, end)]
        if let place = trip.place { lines.append("At \(AgentPlaces.displayName(place.name))") }
        if let route = trip.route { lines += routeLines(route, start: start) }
        // The card keeps the place and route as they were when it was built; Confirm never reads the registry.
        return .card(AgentCard(lines: lines, showsGoogleMark: trip.place != nil) { [self] in
            // The card may have waited a long time: the start must still be inside the window the gate allows.
            do { try checkWindow(start, .create) } catch {
                let result = Self.encode(["status": "rejected", "message": Say.window(.create)])
                return (AgentResolution(result: result, notice: Say.startPassed), .notApplied)
            }
            if let route = trip.route, !AgentPlaces.isFresh(route, now: now()) {
                let result = Self.encode(["status": "rejected", "message": Say.routeExpired])
                return (AgentResolution(result: result, notice: Say.routeExpiredNotice), .notApplied)
            }
            let route = trip.route
            let made = await store.addActivityWithTravel(
                title: title, location: trip.place, startDate: start, endDate: end, travelFrom: route?.origin, returnTo: nil,
                outboundMode: route?.mode ?? .walk, returnMode: route?.mode ?? .walk,
                bufferMinutes: route == nil ? 0 : AgentPlaces.legBufferMinutes,
                notifyLeadMinutes: route == nil ? 0 : AgentPlaces.legNotifyLeadMinutes,
                syncToCalendar: store.calendarSyncDefault, travelSecondsHint: route?.seconds)
            return applied(made.activityId, withPlace: trip.place != nil)
        })
    }

    /// The place and route a create call points at, checked in the order of spec.md section 2.3. With a route and no
    /// place the place is the route's destination.
    private func resolveTrip(_ values: [String: String]) throws -> (place: Place?, route: AgentRoute?) {
        var place: Place?
        if let id = values["place_id"] {
            guard AgentPlaces.isPlaceHandle(id), let found = registry.place(id) else { throw Rejection(Say.createPlace) }
            place = found
        }
        var route: AgentRoute?
        if let id = values["route_id"] {
            guard AgentPlaces.isRouteHandle(id), let found = registry.route(id, now: now()) else {
                throw Rejection(Say.createRoute)
            }
            if let place, found.destination != place { throw Rejection(Say.createMismatch) }
            route = found
            place = found.destination
        }
        return (place, route)
    }

    /// `From`, `Leave`, Google's warnings and the verification line. Every number is the app's: the leave time comes
    /// from the call's start, the route's exact seconds and the leg buffer.
    private func routeLines(_ route: AgentRoute, start: Date) -> [String] {
        let f = formats
        let leave = Store.departureTime(arrival: start, travelSeconds: route.seconds, bufferMinutes: AgentPlaces.legBufferMinutes)
        let leaveText = (f.calendar.isDate(leave, inSameDayAs: start) ? f.time : f.day).string(from: leave)
        let duration = TravelEstimate(mode: route.mode, duration: route.seconds, distance: nil, source: "Google").durationText
        let warnings = route.warnings.map { Self.sanitized($0) }.filter { !$0.isEmpty }
        return ["From \(AgentPlaces.displayName(route.origin.name))",
                "Leave \(leaveText) - \(duration) \(AgentPlaces.modePhrase(route.mode))"]
            + warnings + [AgentPlaces.verifiedLine]
    }

    // MARK: - Lookups (SPEC-AGENTPLACE-001)

    private func search(_ values: [String: String], flow: UUID?) throws -> AgentToolOutcome {
        guard let query = values["query"], query.count >= AgentPlaces.queryMin else { throw Rejection(Say.queryMissing) }
        if query.count > AgentPlaces.queryMax { throw Rejection(Say.queryLong) }
        let center = deviceOrigin().map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        if dayPlan != nil { searchesThisPlan += 1 }
        return .lookup(AgentLookup { [self] in
            let service = placeSearchProvider?() ?? store.placeSearch
            let found = await service.lookup(query, near: center, flow: flow)
            // A cancelled lookup writes nothing: its answer is dropped by the session anyway.
            if Task.isCancelled { return AgentPlaces.searchOutput([], registry: &registry) }
            switch found {
            case .found(let places): return AgentPlaces.searchOutput(places, registry: &registry)
            case .failed: return AgentPlaces.searchFailure()
            }
        })
    }

    private func travel(_ values: [String: String], flow: UUID?) throws -> AgentToolOutcome {
        guard let destinationId = values["place_id"], AgentPlaces.isPlaceHandle(destinationId),
              let destination = registry.place(destinationId) else { throw Rejection(Say.findPlace) }
        guard let modeText = values["mode"], let mode = TransportMode(rawValue: modeText) else { throw Rejection(Say.mode) }
        let origin: Place
        if let originId = values["origin_place_id"] {
            guard AgentPlaces.isPlaceHandle(originId), let named = registry.place(originId) else {
                throw Rejection(Say.originPlace)
            }
            origin = named
        } else {
            guard let device = deviceOrigin() else { throw Rejection(Say.noOrigin) }
            origin = device
        }
        var arrival: Date?
        if let text = values["arrive_by"] {
            guard let date = localDate(text) else { throw Rejection(Say.timeForm(.travel, "arrive_by")) }
            guard withinWindow(date) else { throw Rejection(Say.arriveWindow) }
            arrival = date
        }
        let local = formats.local
        return .lookup(AgentLookup { [self] in
            let service = directionsProvider?() ?? store.directions
            let estimate = await service.estimate(
                mode, from: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude),
                to: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude),
                flow: flow)
            guard let seconds = estimate.duration else { return AgentPlaces.travelFailure(estimate.failure) }
            guard !Task.isCancelled else { return AgentPlaces.travelFailure(nil) }
            let route = AgentRoute(mode: mode, seconds: seconds, origin: origin, destination: destination,
                                   warnings: estimate.warnings, createdAt: now())
            let leaveBy = arrival.map {
                local.string(from: Store.departureTime(arrival: $0, travelSeconds: seconds, bufferMinutes: AgentPlaces.legBufferMinutes))
            }
            return AgentPlaces.travelOutput(route, leaveBy: leaveBy, registry: &registry)
        })
    }

    // MARK: - Day plan (SPEC-PLANDAY-001)

    /// Gate, then the Routes lookups one after the other, then the stored check. The numbers are the app's: a leg whose
    /// lookup failed, was cancelled or fell beyond the cap simply has no route and stays unchecked.
    private func checkDayPlan(_ values: [String: String], flow: UUID?) throws -> AgentToolOutcome {
        guard let context = dayPlan else { throw Rejection(AgentDayPlan.Say.notInPlanTurn) }
        guard checks.count < AgentDayPlan.checksPerTurn + (extraCheckGranted ? 1 : 0) else {
            throw Rejection(AgentDayPlan.Say.checksUsed)
        }
        guard let text = values["stops"] else { throw Rejection(AgentDayPlan.Say.stopsFormat) }
        let parsed: [AgentDayPlan.Stop]
        do {
            parsed = try AgentDayPlan.parse(text, context: context, registry: registry, now: now(), zone: zone())
        } catch let refusal as AgentDayPlan.Refusal {
            throw Rejection(refusal.message)
        }
        let stops = AgentDayPlan.effective(parsed, events: context.events)
        let pairs = AgentDayPlan.legPairs(stops, cap: AgentDayPlan.lookupCap).pairs
        let mode = context.mode
        return .lookup(AgentLookup { [self] in
            let service = directionsProvider?() ?? store.directions
            var routes: [AgentDayPlan.Pair: AgentRoute] = [:]
            for pair in pairs {
                // A cancelled run writes nothing and starts no further lookup.
                guard !Task.isCancelled else { return AgentPlaces.travelFailure(nil) }
                guard let origin = stops[pair.from - 1].place, let destination = stops[pair.to - 1].place else { continue }
                let estimate = await service.estimate(
                    mode, from: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude),
                    to: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude), flow: flow)
                guard let seconds = estimate.duration else { continue }
                routes[pair] = AgentRoute(mode: mode, seconds: seconds, origin: origin, destination: destination,
                                          warnings: estimate.warnings, createdAt: now())
            }
            guard !Task.isCancelled else { return AgentPlaces.travelFailure(nil) }
            let evaluated = AgentDayPlan.evaluate(stops: stops, routes: routes, bufferMinutes: AgentPlaces.legBufferMinutes)
            let created = now()
            let check = AgentDayPlan.Check(
                handle: "d\(nextPlanNumber)", stops: stops, legs: evaluated.legs, problems: evaluated.problems, createdAt: created,
                signature: AgentDayPlan.signature(of: store.activities, from: created, to: context.checkWindowEnd))
            nextPlanNumber += 1
            checks.append(check)
            return AgentLookupOutput(result: AgentDayPlan.resultJSON(check, checksMade: checks.count), showsGoogleData: !routes.isEmpty)
        })
    }

    /// True when a verified route of the check is older than the route rule allows at this moment.
    private func hasStaleRoute(_ check: AgentDayPlan.Check) -> Bool {
        check.legs.contains { leg in leg.route.map { !AgentPlaces.isFresh($0, now: now()) } ?? false }
    }

    /// The card of the latest check, built from the stored check only. Only the latest handle is shown; a plan with problems
    /// waits for the third check; a check whose routes have aged out is refused once with one more check allowed, then for good.
    private func showDayPlan(_ values: [String: String]) throws -> AgentToolOutcome {
        guard let context = dayPlan else { throw Rejection(AgentDayPlan.Say.notInPlanTurn) }
        guard let handle = values["plan_id"], let check = checks.first(where: { $0.handle == handle }) else {
            throw Rejection(AgentDayPlan.Say.planUnknown)
        }
        guard check.handle == checks.last?.handle else { throw Rejection(AgentDayPlan.Say.planOld) }
        if !check.problems.isEmpty, checks.count < AgentDayPlan.checksPerTurn { throw Rejection(AgentDayPlan.Say.planProblems) }
        if hasStaleRoute(check) {
            if extraCheckGranted { throw Rejection(AgentDayPlan.Say.planStaleLast) }
            extraCheckGranted = true
            throw Rejection(AgentDayPlan.Say.planStale)
        }
        // The baseline of "what changed" is the first check of the turn.
        let lines = AgentDayPlan.cardLines(check, first: checks.first, mode: context.mode, zone: zone())
        return .card(AgentCard(lines: lines, showsGoogleMark: AgentDayPlan.showsGoogleMark(check)) { [self] in
            await confirmDayPlan(check, context)
        })
    }

    /// One answer for a Confirm that writes nothing: the status and message for the model and the notice for the user.
    private func nothingAdded(_ status: String, _ message: String) -> (AgentResolution, AgentCardMark) {
        (AgentResolution(result: Self.encode(["status": status, "message": message]), notice: AgentDayPlan.Say.nothingAdded), .notApplied)
    }

    /// Confirm of a day plan. Nothing is written until the starts, the route ages and the Store signature all hold; no network
    /// call is made (the leg of a new stop is stored with the verified seconds as the hint).
    private func confirmDayPlan(_ check: AgentDayPlan.Check, _ context: DayPlanContext) async -> (AgentResolution, AgentCardMark) {
        let added = check.stops.enumerated().filter { $0.element.isNew }
        let minute = Date(timeIntervalSince1970: (now().timeIntervalSince1970 / 60).rounded(.down) * 60)
        if added.contains(where: { $0.element.start < minute }) {
            return nothingAdded("rejected", AgentDayPlan.Say.startPassed)
        }
        if hasStaleRoute(check) {
            // The same rule as `show_day_plan`: one more check once per turn, then the plan cannot be completed.
            if extraCheckGranted || dayPlan == nil { return nothingAdded("rejected", AgentDayPlan.Say.planStaleLast) }
            extraCheckGranted = true
            return nothingAdded("rejected", AgentDayPlan.Say.planStale)
        }
        if AgentDayPlan.signature(of: store.activities, from: check.createdAt, to: context.checkWindowEnd) != check.signature {
            return nothingAdded("stale", AgentDayPlan.Say.scheduleChanged)
        }
        var ids: [UUID] = []
        for (position, stop) in added {
            // The leg into this stop is stored only when Routes verified it; its origin is the place of the stop it starts from.
            let route = check.legs.first { $0.to == position + 1 }?.route
            let made = await store.addActivityWithTravel(
                title: stop.title, location: stop.place, startDate: stop.start, endDate: stop.end, travelFrom: route?.origin,
                returnTo: nil, outboundMode: context.mode, returnMode: context.mode,
                bufferMinutes: route == nil ? 0 : AgentPlaces.legBufferMinutes,
                notifyLeadMinutes: route == nil ? 0 : AgentPlaces.legNotifyLeadMinutes,
                syncToCalendar: store.calendarSyncDefault, travelSecondsHint: route?.seconds)
            ids.append(made.activityId)
        }
        return dayPlanApplied(ids, listed: added.count)
    }

    /// The result of a confirmed day plan: how many events and legs the Store holds for the activities just added, read back
    /// from it. Fewer events than the card listed gives the notice and rolls nothing back. Not private so a test can reach
    /// the shortfall, which the Store write cannot be made to produce.
    func dayPlanApplied(_ ids: [UUID], listed: Int) -> (AgentResolution, AgentCardMark) {
        let kept = ids.filter { id in store.activities.contains { $0.id == id } }
        guard !kept.isEmpty else { return nothingAdded("rejected", AgentDayPlan.Say.nothingAdded) }
        let legs = kept.filter { id in store.events.contains { $0.linkedActivityId == id } }.count
        let result = Self.encode(["status": "applied", "events": kept.count, "legs": legs])
        return (AgentResolution(result: result, notice: kept.count < listed ? AgentDayPlan.Say.partialAdded : nil), .confirmed)
    }

    // MARK: - Booking (SPEC-BOOKING-001)

    private func bookingClient() -> BookingClient {
        bookingProvider?() ?? BookingClient(config: store.config, send: { try await URLSession(configuration: .ephemeral).data(for: $0) })
    }

    /// A booking start is a time that has not passed (by the minute) and is within the next 366 days.
    private func withinBookingWindow(_ date: Date) -> Bool {
        let minute = (now().timeIntervalSince1970 / 60).rounded(.down) * 60
        return date >= Date(timeIntervalSince1970: minute) && date <= Date(timeIntervalSince1970: minute + Self.futureWindow)
    }

    private func book(_ values: [String: String]) throws -> AgentToolOutcome {
        guard let handle = values["place_id"], AgentPlaces.isPlaceHandle(handle), let place = registry.place(handle),
              !AgentPlaces.displayName(place.name).isEmpty else { throw Rejection(Say.bookPlace) }
        guard values["start"] != nil, let start = try time(values, .booking, "start") else { throw Rejection(Say.bookStart) }
        guard withinBookingWindow(start) else { throw Rejection(Say.bookWindow) }
        guard let sizeText = values["party_size"], let partySize = AgentBooking.parsePartySize(sizeText) else {
            throw Rejection(Say.bookParty)
        }
        guard bookingClient().isConfigured else { throw Rejection(Say.bookUnavailable) }

        let f = formats
        let placeName = AgentPlaces.displayName(place.name)
        let request = BookingRequest(requestID: UUID().uuidString, restaurant: AgentBooking.sentName(place),
                                     partySize: partySize, start: f.local.string(from: start))
        let lines = AgentBooking.cardLines(placeName: placeName, start: f.day.string(from: start), partySize: partySize)
        // The card keeps the place as it was when it was built; Confirm never reads the registry.
        return .card(AgentCard(lines: lines, showsGoogleMark: true) { [self] in
            // The card may have waited a long time: the start must still be a time that has not passed.
            guard withinBookingWindow(start) else {
                let result = Self.encode(["status": "rejected", "message": Say.bookWindow])
                return (AgentResolution(result: result, notice: Say.startPassed), .notApplied)
            }
            let flow = ConnectionLog.beginFlow()
            let answer = await bookingClient().book(request, flow: flow)
            // Cancellation is checked after the answer is known and before anything is written.
            guard !Task.isCancelled else { return bookingUnavailable() }
            switch answer {
            case .failure:
                return bookingUnavailable()
            case .success(.declined):
                let result = Self.encode(["status": "declined", "partner": BookingClient.partnerName, "simulated": true,
                                          "message": AgentBooking.declinedMessage])
                return (AgentResolution(result: result, notice: nil), .notApplied)
            case .success(.confirmed(let code)):
                let made = await store.addActivityWithTravel(
                    title: AgentBooking.entryTitle(partySize: partySize, placeName: placeName), location: place,
                    startDate: start, endDate: start.addingTimeInterval(AgentBooking.entryDuration), travelFrom: nil,
                    returnTo: nil, outboundMode: .walk, returnMode: .walk, bufferMinutes: 0, notifyLeadMinutes: 0,
                    syncToCalendar: store.calendarSyncDefault, travelSecondsHint: nil)
                // SPEC-BUDGET-001: the table is booked and on the schedule; its estimated spend goes to the budget partner
                // under the booking's own flow. With no proxy nothing is sent and the result is the base one.
                let budget = await sendEstimatedSpend(partySize: partySize, start: start, flow: flow)
                return bookingApplied(made.activityId, code: code, budget: budget)
            }
        })
    }

    /// One `spend` of the table's estimated amount, counted in the week of the table's start. Nil when the proxy is not
    /// configured. A failure, or a task cancelled meanwhile, never changes the booking.
    private func sendEstimatedSpend(partySize: Int, start: Date, flow: UUID) async -> AgentBudget.BookingSpend? {
        let client = budgetClient()
        guard client.isConfigured else { return nil }
        let amount = partySize * AgentBudget.estimatePerPersonCents
        let tableWeek = BudgetWeek.start(of: start, in: zone())
        let result = await client.spend(amountCents: amount, isEstimate: true, weekStart: tableWeek,
                                        requestID: UUID().uuidString, flow: flow)
        switch result {
        case .success(let standing):
            let week = AgentBudget.weekPhrase(weekStart: tableWeek, currentWeekStart: BudgetWeek.start(of: now(), in: zone()))
            return .recorded(amountCents: amount, standing: standing, week: week)
        case .failure:
            return .unavailable(notify: !Task.isCancelled)
        }
    }

    private func bookingUnavailable() -> (AgentResolution, AgentCardMark) {
        let result = Self.encode(["status": "unavailable", "partner": BookingClient.partnerName, "simulated": true,
                                  "message": AgentBooking.unavailableMessage])
        return (AgentResolution(result: result, notice: AgentBooking.unavailableNotice), .notApplied)
    }

    /// `applied`, with the entry's values read back from the Store. Not private so a test can reach the read-back refusal,
    /// which the Store write cannot be made to produce (it never suspends between the write and the read).
    func bookingApplied(_ id: UUID, code: String, budget: AgentBudget.BookingSpend? = nil) -> (AgentResolution, AgentCardMark) {
        guard let stored = store.activities.first(where: { $0.id == id }) else { return (notFound(), .notApplied) }
        let local = formats.local
        var object: [String: Any] = ["status": "applied", "partner": BookingClient.partnerName, "simulated": true,
                                     "reservation_code": code, "id": stored.id.uuidString, "title": Self.sanitized(stored.title),
                                     "start": local.string(from: stored.startDate), "end": local.string(from: stored.endDate),
                                     "message": AgentBooking.appliedMessage]
        if let place = stored.location { object["location"] = AgentPlaces.displayName(place.name) }
        if let budget {
            object["budget"] = budget.block
            object["message"] = AgentBooking.appliedMessage + " " + budget.sentence
        }
        return (AgentResolution(result: Self.encode(object), notice: budget?.notice), .confirmed)
    }

    // MARK: - Budget (SPEC-BUDGET-001)

    private func budgetClient() -> BudgetClient {
        budgetProvider?() ?? BudgetClient(config: store.config, send: { try await URLSession(configuration: .ephemeral).data(for: $0) })
    }

    /// `get_budget_left`: one `left` request for the current week, run as the request in flight. It writes nothing.
    private func budgetLeft(flow: UUID?) -> AgentToolOutcome {
        let week = BudgetWeek.start(of: now(), in: zone())
        let flow = flow ?? ConnectionLog.beginFlow()
        return .lookup(AgentLookup { [self] in
            switch await budgetClient().left(weekStart: week, flow: flow) {
            case .failure:
                return AgentLookupOutput(result: budgetUnavailable(AgentBudget.leftUnavailableMessage), showsGoogleData: false)
            case .success(let standing):
                var object = AgentBudget.standingFields(standing)
                object["status"] = "ok"
                object["partner"] = BudgetClient.partnerName
                object["simulated"] = true
                object["message"] = AgentBudget.leftMessage
                return AgentLookupOutput(result: Self.encode(object), showsGoogleData: false)
            }
        })
    }

    /// `record_spend`: no card. The amount is decided here before anything is made; the week and the request id are made now,
    /// so one call sends at most one request, and the lookup sends it when the session runs it.
    private func recordSpend(_ values: [String: String], flow: UUID?) throws -> AgentToolOutcome {
        guard let text = values["amount"], let cents = AgentBudget.parseAmountCents(text) else { throw Rejection(Say.spendAmount) }
        let week = BudgetWeek.start(of: now(), in: zone())
        let requestID = UUID().uuidString
        let flow = flow ?? ConnectionLog.beginFlow()
        return .lookup(AgentLookup { [self] in
            let answer = await budgetClient().spend(amountCents: cents, isEstimate: false, weekStart: week,
                                                    requestID: requestID, flow: flow)
            switch answer {
            case .failure:
                // A task cancelled meanwhile says nothing to the user, as in the booking hook.
                return AgentLookupOutput(result: budgetUnavailable(AgentBudget.spendUnavailableMessage), showsGoogleData: false,
                                         notice: Task.isCancelled ? nil : AgentBudget.spendFailureNotice)
            case .success(let standing):
                var object = AgentBudget.standingFields(standing)
                object["status"] = "applied"
                object["partner"] = BudgetClient.partnerName
                object["simulated"] = true
                object["recorded"] = AgentBudget.dollars(cents: cents)
                object["message"] = AgentBudget.spendMessage
                // The partner's name is in the app's own line, not left to the model's wording.
                let current = AgentBudget.weekPhrase(weekStart: week, currentWeekStart: BudgetWeek.start(of: now(), in: zone()))
                return AgentLookupOutput(result: Self.encode(object), showsGoogleData: false,
                                         notice: AgentBudget.spendNotice(amountCents: cents, standing: standing, week: current))
            }
        })
    }

    private func budgetUnavailable(_ message: String) -> String {
        Self.encode(["status": "unavailable", "partner": BudgetClient.partnerName, "simulated": true, "message": message])
    }

    // MARK: - Delivery (SPEC-DELIVERY-001)

    private func deliveryClient() -> DeliveryClient {
        deliveryProvider?() ?? DeliveryClient(config: store.config, send: { try await URLSession(configuration: .ephemeral).data(for: $0) })
    }

    /// What a confirmed delivery order is made from: the values of the card as it was built and the one snapshot of its editors.
    private struct DeliveryOrder {
        /// The meal entry as the snapshot has it: the title as typed and trimmed (before ` (Simulated)`) and the start time.
        struct Meal {
            let title: String
            let start: Date
        }

        let request: DeliveryRequest
        let options: DeliveryOptions
        let placeName: String
        let arrival: Date
        let cardLabel: String
        let items: [(name: String, quantity: Int)]
        let totalCents: Int
        let meal: Meal?
    }

    /// `get_delivery_options`: one options request, run as the request in flight. It writes nothing; a good answer is held in
    /// memory, a failure or a cancelled task holds nothing new.
    private func deliveryOptionsLookup(flow: UUID?) -> AgentToolOutcome {
        let flow = flow ?? ConnectionLog.beginFlow()
        return .lookup(AgentLookup { [self] in
            let answer = await deliveryClient().options(flow: flow)
            guard case .success(let options) = answer, !Task.isCancelled else {
                let result = Self.encode(["status": "unavailable", "partner": DeliveryClient.partnerName, "simulated": true,
                                          "message": AgentDelivery.optionsUnavailableMessage])
                return AgentLookupOutput(result: result, showsGoogleData: false)
            }
            deliveryOptions = options
            return AgentLookupOutput(result: Self.encode(AgentDelivery.optionsResult(options)), showsGoogleData: false)
        })
    }

    /// Gate, then the card: every argument is decided here, in the order of spec.md REQ-DELIVERY-008. Building the card writes
    /// nothing and sends nothing.
    private func orderDelivery(_ values: [String: String]) throws -> AgentToolOutcome {
        guard let handle = values["place_id"], AgentPlaces.isPlaceHandle(handle), let place = registry.place(handle),
              !AgentPlaces.displayName(place.name).isEmpty else { throw Rejection(Say.deliveryPlace) }
        guard values["arrive_at"] != nil, let arrival = try time(values, .delivery, "arrive_at") else { throw Rejection(Say.deliveryTime) }
        guard withinBookingWindow(arrival) else { throw Rejection(Say.deliveryWindow) }
        guard let options = deliveryOptions else { throw Rejection(Say.deliveryOptionsFirst) }
        guard let itemsText = values["items"], let lines = AgentDelivery.parseItems(itemsText) else { throw Rejection(Say.deliveryItems) }
        guard lines.allSatisfy({ options.menuItem(id: $0.itemID) != nil }) else { throw Rejection(Say.deliveryItemUnknown) }
        guard let cardID = values["card_id"] else { throw Rejection(Say.deliveryCard) }
        guard let card = options.card(id: cardID) else { throw Rejection(Say.deliveryCardUnknown) }
        guard let totalCents = options.totalCents(for: lines) else { throw Rejection(Say.deliveryItems) }
        // The delivery place comes from the place table or from the schedule, never from the model's text.
        let deliveryText: String
        let isSuggested: Bool
        if let target = values["deliver_to"] {
            guard AgentPlaces.isPlaceHandle(target), let named = registry.place(target), let text = AgentDelivery.placeText(named) else {
                throw Rejection(Say.deliveryToHandle)
            }
            deliveryText = text
            isSuggested = false
        } else {
            guard let text = AgentDelivery.suggestedPlaceText(activities: store.activities, arrival: arrival, now: now()) else {
                throw Rejection(Say.deliveryTo)
            }
            deliveryText = text
            isSuggested = true
        }
        guard deliveryClient().isConfigured else { throw Rejection(Say.deliveryUnavailable) }

        let f = formats
        let placeName = AgentPlaces.displayName(place.name)
        let arrives = f.day.string(from: arrival)
        let items = lines.map { (name: options.menuItem(id: $0.itemID)?.name ?? $0.itemID, quantity: $0.quantity) }
        let minuteOfDay = f.calendar.component(.hour, from: arrival) * 60 + f.calendar.component(.minute, from: arrival)
        let word = AgentDelivery.mealWord(arrivalMinute: minuteOfDay)
        let editors = AgentCardEditors(
            delivery: isSuggested ? AgentCardText(text: deliveryText, limit: AgentDelivery.maxDeliveryText, suggestion: deliveryText) : nil,
            mealOn: AgentCardSwitch(isOn: true),
            mealTitle: AgentCardText(text: word, limit: AgentDelivery.maxMealTitle, suggestion: word),
            mealStart: AgentCardTime(start: arrival, arrival: arrival, calendar: f.calendar))
        let requestID = UUID().uuidString
        // The card keeps the place, the items and the total as they were when it was built, except the editable values;
        // Confirm never reads the registry, the held options or the schedule again.
        let rows: @MainActor () -> [AgentCardRow] = {
            let text = editors.delivery?.text ?? deliveryText
            var meal: AgentDelivery.CardMeal?
            if editors.mealOn?.isOn == true, let title = editors.mealTitle, let start = editors.mealStart {
                meal = AgentDelivery.CardMeal(title: AgentDelivery.mealTitle(typed: title.text), time: f.time.string(from: start.start),
                                              isSuggested: title.isSuggestion && start.isSuggestion)
            }
            let cardLines = AgentDelivery.cardLines(placeName: placeName, arrives: arrives, items: items, deliveryText: text,
                                                    deliveryIsSuggested: editors.delivery?.isSuggestion ?? false, cardLabel: card.label,
                                                    totalCents: totalCents, meal: meal)
            return Self.deliveryRows(cardLines, itemCount: items.count, deliveryText: text, hasDeliveryEditor: editors.delivery != nil,
                                     meal: meal)
        }
        return .card(AgentCard(editors: editors, showsGoogleMark: true, rows: rows) { [self] in
            // The card may have waited a long time: the arrival must still be a time that has not passed.
            guard withinBookingWindow(arrival) else {
                let result = Self.encode(["status": "rejected", "message": Say.deliveryWindow])
                return (AgentResolution(result: result, notice: Say.startPassed), .notApplied)
            }
            // The one snapshot of the editors (Confirm froze them): the delivery text and the title are trimmed once, here.
            let taken = editors.values
            let address = AgentDelivery.snapshotText(taken.deliveryText ?? deliveryText)
            let title = AgentDelivery.snapshotText(taken.mealTitle ?? "")
            guard let address, !taken.mealOn || title != nil else {
                let result = Self.encode(["status": "rejected", "message": AgentDelivery.editRejectedMessage])
                return (AgentResolution(result: result, notice: nil), .notApplied)
            }
            let meal = title.flatMap { title in taken.mealOn ? DeliveryOrder.Meal(title: title, start: taken.mealStart ?? arrival) : nil }
            let request = DeliveryRequest(requestID: requestID, restaurant: AgentBooking.sentName(place), arriveAt: f.local.string(from: arrival),
                                          items: lines, address: address, cardID: card.id)
            return await placeOrder(DeliveryOrder(request: request, options: options, placeName: placeName, arrival: arrival,
                                                  cardLabel: card.label, items: items, totalCents: totalCents, meal: meal))
        })
    }

    /// The rows of a delivery card from its lines: the delivery line and the meal line carry the marks they hold, and the meal row
    /// exists (without a line) while the entry is switched off, so the view keeps its switch.
    private static func deliveryRows(_ lines: [String], itemCount: Int, deliveryText: String, hasDeliveryEditor: Bool,
                                     meal: AgentDelivery.CardMeal?) -> [AgentCardRow] {
        let deliveryIndex = 3 + itemCount
        let mealIndex = deliveryIndex + 3
        var rows: [AgentCardRow] = []
        for (index, line) in lines.enumerated() {
            if index == mealIndex, meal == nil { rows.append(.meal(line: nil, mark: "")) }
            if index == deliveryIndex, hasDeliveryEditor {
                rows.append(.delivery(line: line, mark: String(line.dropFirst("To \(deliveryText)".count))))
            } else if index == mealIndex, let meal {
                rows.append(.meal(line: line, mark: String(line.dropFirst("Add to schedule: \(meal.title) at \(meal.time)".count))))
            } else {
                rows.append(.text(line))
            }
        }
        return rows
    }

    /// The order request and what follows it. Milestone M4 replaces this body; until then an order is never made.
    private func placeOrder(_ order: DeliveryOrder) async -> (AgentResolution, AgentCardMark) {
        deliveryUnavailable()
    }

    /// `unavailable`: nothing was ordered. Not private so a test can reach it, as `bookingApplied` is.
    func deliveryUnavailable() -> (AgentResolution, AgentCardMark) {
        let result = Self.encode(["status": "unavailable", "partner": DeliveryClient.partnerName, "simulated": true,
                                  "message": AgentDelivery.unavailableMessage])
        return (AgentResolution(result: result, notice: AgentDelivery.unavailableNotice), .notApplied)
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

    /// `applied`, with the values read back from the Store. A created record with a place adds its location and, when a
    /// leg was stored, the leg's leave time and minutes.
    private func applied(_ id: UUID, withPlace: Bool = false) -> (AgentResolution, AgentCardMark) {
        guard let stored = store.activities.first(where: { $0.id == id }) else { return (notFound(), .notApplied) }
        let local = formats.local
        var object: [String: Any] = ["status": "applied", "id": stored.id.uuidString, "title": Self.sanitized(stored.title),
                                     "start": local.string(from: stored.startDate),
                                     "end": local.string(from: stored.endDate)]
        if withPlace {
            if let place = stored.location { object["location"] = AgentPlaces.displayName(place.name) }
            if let leg = store.events.first(where: { $0.linkedActivityId == id }),
               let departure = leg.departureDate, let seconds = leg.travelSeconds {
                object["leave_by"] = local.string(from: departure)
                object["minutes"] = roundedMinutes(fromSeconds: seconds)
            }
        }
        return (AgentResolution(result: Self.encode(object), notice: nil), .confirmed)
    }
}
