import Foundation
import CoreLocation

// SPEC-AGENT-001: the four schedule tools, SPEC-AGENTPLACE-001: the place and travel-time tools. The app, not the
// model, decides: every argument goes through one gate, every write waits for the user's Confirm, and the card shows
// validated values and Store records only. SPEC-PLANDAY-001 adds the two day plan tools and the plan turn.

enum AgentTools {
    /// JSON array of the fourteen function declarations sent with every request.
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
        "description": "Order food delivery from a restaurant found with search_places, in a simulated delivery app, with items taken from get_delivery_options. The delivery app is simulated, not a real one: always call the result simulated. items is written as item_id:quantity pairs separated by commas, such as ramen:2,gyoza:1. Ask the user for the arrival time and the items if they have not said. card_id is a card_id from get_delivery_options, set only when the user named a card and left out otherwise. deliver_to is a place_id from search_places, set only when the user named a place to deliver to and left out otherwise; the app may then suggest a place from the schedule. Never write an address. The user confirms before anything is sent, after filling in what is blank.",
        "parameters": {
          "type": "object",
          "properties": {
            "place_id": {"type": "string", "description": "The restaurant: a place_id returned by search_places."},
            "arrive_at": {"type": "string", "description": "When the food is to arrive, as a local date-time, YYYY-MM-DDTHH:MM. Ask the user if they have not said."},
            "items": {"type": "string", "description": "What to order: item_id:quantity pairs separated by commas with no spaces, 1 to 6 pairs, each quantity 1 to 9, such as ramen:2,gyoza:1. Use item_id values from get_delivery_options. Ask the user if they have not said."},
            "card_id": {"type": "string", "description": "The card to pay with: a card_id from get_delivery_options. Set only when the user named a card. Leave it out otherwise."},
            "deliver_to": {"type": "string", "description": "Optional. A place_id returned by search_places, set only when the user named a place to deliver to. Leave it out otherwise."}
          },
          "required": ["place_id", "arrive_at", "items"],
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "get_partners",
        "description": "Look up the partners the app can ask, with the fields each one needs and what each answer will hold. Partners are simulated, not real ones: always call them simulated. Call it before request_partner. Takes no arguments.",
        "parameters": {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
      },
      {
        "type": "function",
        "name": "request_partner",
        "description": "Ask one simulated partner from get_partners to act for the user. The partner is simulated, not a real one: always call the result simulated. The user checks and fills the card and confirms before anything is sent. Pass only what the user said in the chat: for each field the user mentioned, its key, the value, and the exact words of the user that give the value as the quote. Leave out every field the user did not mention, and do not ask the user for it in the chat: the user fills it on the card.",
        "parameters": {
          "type": "object",
          "properties": {
            "partner": {"type": "string", "description": "The id of a partner returned by get_partners."},
            "fields": {"type": "string", "description": "A JSON array text of objects with the members key, value and quote, all strings, one object for each field the user mentioned. key is a field key from get_partners. value is written as the field needs it: a time as a local date-time YYYY-MM-DDTHH:MM, a number as digits only (2, not two), a text as the user said it; never fill a field that has options outside a group. A field of kind group is a list of rows. Pass one entry for each member of each row the user named, with the key written group.row.member and the row counted from 1 (for example lines.1.size, lines.2.size); a text or number member is filled like any other field, the value of a member that has options is the id of the option, and its quote is only the user's words for that row. Leave out a row the user did not name. The quote is the user's exact words. Leave the field out when the user did not say it. Never guess."}
          },
          "required": ["partner"],
          "additionalProperties": false
        }
      }
    ]
    """#
}

/// A pending confirmation card: its English lines, its actions, and a single resolution. A card has fixed lines or, for a card
/// drawn from a partner's field list (SPEC-CHOICECARD-001), the model of that list.
@MainActor
final class AgentCard {
    /// The lines in order, the heading first; for a field card they are read from its model.
    var lines: [String] { fieldCard?.lines ?? fixedLines }
    /// SPEC-CHOICECARD-001: the model of a card drawn from a partner's field list; nil for a card of fixed lines.
    let fieldCard: AgentFieldCard?
    /// False while a field card has a blank required value; the chat disables Confirm then.
    var canConfirm: Bool { fieldCard?.isReady ?? true }
    /// The actions the card offers.
    let actions = ["Confirm", "Cancel"]
    /// Nil while the card is pending.
    private(set) var mark: AgentCardMark?
    /// What the model reads after Cancel or a closed sheet; nil means the generic declined answer.
    fileprivate(set) var cancelResult: String?
    /// True when the card carries Google place or route data, so the chat draws the Google Maps mark inside it
    /// (SPEC-AGENTPLACE-001). A field card also carries it while its `Leave from` row is on it, because that row searches places.
    var showsGoogleMark: Bool { builtMark || fieldCard?.field(AgentPartner.cardFromKey) != nil }

    private let builtMark: Bool
    private var taken = false
    private let fixedLines: [String]
    private let onConfirm: @MainActor () async -> (AgentResolution, AgentCardMark)

    init(lines: [String], showsGoogleMark: Bool = false,
         onConfirm: @escaping @MainActor () async -> (AgentResolution, AgentCardMark)) {
        fixedLines = lines
        fieldCard = nil
        builtMark = showsGoogleMark
        self.onConfirm = onConfirm
    }

    /// SPEC-CHOICECARD-001: a card whose rows are the fields of `fieldCard`.
    init(fieldCard: AgentFieldCard, showsGoogleMark: Bool = false,
         onConfirm: @escaping @MainActor () async -> (AgentResolution, AgentCardMark)) {
        fixedLines = []
        self.fieldCard = fieldCard
        builtMark = showsGoogleMark
        self.onConfirm = onConfirm
    }

    /// Acts on the first resolution only and returns its outcome; any later call returns nil. Every resolution freezes the field card
    /// (Confirm before it awaits the closure), so no edit or armed search made after the tap changes anything.
    func resolve(_ how: AgentCardResolution) async -> AgentResolution? {
        guard !taken else { return nil }
        taken = true
        switch how {
        case .confirm:
            fieldCard?.freeze()
            let (resolution, result) = await onConfirm()
            mark = result
            // A card that ended without an applied answer no longer shows the rows besir added itself.
            if result != .confirmed { fieldCard?.removeOwnRows() }
            return resolution
        case .cancel, .dismiss:
            fieldCard?.freeze()
            mark = .cancelled
            fieldCard?.removeOwnRows()
            return AgentResolution(result: cancelResult ?? AgentToolbox.declinedResult, notice: nil)
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
    case checkDay = "check_day_plan"
    case showDay = "show_day_plan"
    case budgetLeft = "get_budget_left"
    case spend = "record_spend"
    case deliveryOptions = "get_delivery_options"
    case delivery = "order_delivery"
    case partners = "get_partners"
    case partner = "request_partner"

    /// The declared parameters, in declaration order. Nothing else is ever read.
    var params: [String] {
        switch self {
        case .list: return ["from", "to"]
        case .create: return ["title", "start", "end", "place_id", "route_id"]
        case .update: return ["id", "title", "start", "end"]
        case .delete: return ["id"]
        case .search: return ["query"]
        case .travel: return ["place_id", "mode", "origin_place_id", "arrive_by"]
        case .checkDay: return ["stops"]
        case .showDay: return ["plan_id"]
        case .budgetLeft: return []
        case .spend: return ["amount"]
        case .deliveryOptions: return []
        case .delivery: return ["place_id", "arrive_at", "items", "card_id", "deliver_to"]
        case .partners: return []
        case .partner: return ["partner", "fields"]
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
        // The partner id is required, so "omit it" would be the wrong advice for it; `fields` is optional and gets the last line.
        if tool == .partner, param == "partner" { return "Call request_partner again with partner as a string, an id from the get_partners answer." }
        // The day plan tools have their own fixed lines.
        if tool == .checkDay { return AgentDayPlan.Say.stopsFormat }
        if tool == .showDay { return AgentDayPlan.Say.planUnknown }
        // The one budget argument is required, so "omit it" would be the wrong advice here too.
        if tool == .spend { return "Call record_spend again with \(param) as a string. If you do not have it, ask the user; do not guess it." }
        // Three delivery arguments are required, so "omit it" is right for the two optional ones, card_id and deliver_to, only.
        if tool == .delivery, param != "deliver_to", param != "card_id" {
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

    // SPEC-BOOKCARD-001: each string names only get_partners or request_partner.
    static let partnersFirst = "Call get_partners first, then call request_partner again with a partner id from its answer."
    static let partnerWindowAtConfirm = "Nothing was done. Tell the user nothing was done because the time given in the chosen_time key of this result is out of range, and ask for a new time, then call request_partner again. A time must not have passed and must be within the next 366 days."
    static let partnersUnavailable = "Tell the user partners are not available right now. Do not call get_partners or request_partner again."
    static let partnerUnavailable = "Tell the user the partner is not available right now. Do not call request_partner again."

    // SPEC-BUDGET-001: each string names only get_budget_left or record_spend and the one declared parameter.
    static let spendAmount = "Ask the user how much they spent, as digits with an optional decimal point such as 18.50, then call record_spend again. Do not guess it."
    static let budgetUnavailable = "Tell the user the budget is not available right now. Do not call get_budget_left or record_spend again."

    // SPEC-DELIVERY-001: each string names only get_delivery_options, order_delivery, search_places and the declared parameters.
    static let deliveryPlace = "Call search_places to find the restaurant, then call order_delivery again with the place_id it returns."
    static let deliveryTime = "Ask the user when the food is to arrive, then call order_delivery again. Do not guess it."
    static let deliveryWindow = "Nothing was ordered. Tell the user the arrival time is out of range and ask for a new time, then call order_delivery again. The arrive_at time must be a time that has not passed and be within the next 366 days."
    // Said when the card was already confirmed: the value is in the arrive_at key of the same result, never in this text.
    static let deliveryWindowAtConfirm = "Nothing was ordered. Tell the user nothing was ordered because the arrival time given in the arrive_at key of this result is out of range, and ask for a new time, then call order_delivery again. The arrive_at time must be a time that has not passed and be within the next 366 days."
    static let deliveryOptionsFirst = "Call get_delivery_options first, then call order_delivery again with items taken from its answer."
    static let deliveryItems = "Ask the user what to order, then call order_delivery again with items as comma-separated pairs of an item id from the get_delivery_options answer and a quantity from 1 to 9, 1 to 6 pairs, no spaces, no id repeated. Do not guess it."
    static let deliveryItemUnknown = "Call order_delivery again with items that use only item ids from the get_delivery_options answer, or ask the user what to order."
    static let deliveryCardUnknown = "Call order_delivery again with a card_id from the get_delivery_options answer, or leave card_id out."
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
    /// SPEC-BOOKCARD-001: the partner client, built on use from the live configuration; tests inject a stubbed one.
    let partnersProvider: (() -> PartnerClient)?
    /// The lines the user wrote in this chat, read when a card is built; the session sets it. Empty for a toolbox with no session.
    var userLines: () -> [String] = { [] }
    /// SPEC-BUDGET-001: the budget client, built on use from the live configuration; tests inject a stubbed one.
    let budgetProvider: (() -> BudgetClient)?
    /// SPEC-DELIVERY-001: the delivery client and the order record, built on use; tests inject stubbed ones.
    let deliveryProvider: (() -> DeliveryClient)?
    let deliveryOrdersProvider: (() -> DeliveryOrderLog)?
    /// SPEC-LATESWITCH-001: the records of the entries partner requests made, built on use; tests inject a stubbed one.
    let partnerRecordsProvider: (() -> PartnerRecords)?
    /// The partner's last good options answer. In memory only: the next good answer replaces it and a new chat forgets it.
    private var deliveryOptions: DeliveryOptions?
    /// The partners the last good `get_partners` answer held, with their forms. In memory only: a good answer replaces it and a
    /// new chat forgets it.
    private var partners: [PartnerSpec] = []

    /// `timeZone` is read on every use, so a zone change while the app runs reaches dates, cards and the gate.
    init(store: Store, now: @escaping () -> Date, timeZone: @escaping () -> TimeZone,
         deviceOrigin: @escaping () -> Place? = { nil },
         places: (() -> PlaceSearch)? = nil,
         directions: (() -> DirectionsService)? = nil,
         partners: (() -> PartnerClient)? = nil,
         budget: (() -> BudgetClient)? = nil,
         delivery: (() -> DeliveryClient)? = nil,
         deliveryOrders: (() -> DeliveryOrderLog)? = nil,
         partnerRecords: (() -> PartnerRecords)? = nil) {
        self.store = store
        self.now = now
        zone = timeZone
        self.deviceOrigin = deviceOrigin
        placeSearchProvider = places
        directionsProvider = directions
        partnersProvider = partners
        budgetProvider = budget
        deliveryProvider = delivery
        deliveryOrdersProvider = deliveryOrders
        partnerRecordsProvider = partnerRecords
    }

    convenience init(store: Store, now: @escaping () -> Date, timeZone: TimeZone,
                     deviceOrigin: @escaping () -> Place? = { nil },
                     places: (() -> PlaceSearch)? = nil,
                     directions: (() -> DirectionsService)? = nil,
                     partners: (() -> PartnerClient)? = nil,
                     budget: (() -> BudgetClient)? = nil,
                     delivery: (() -> DeliveryClient)? = nil,
                     deliveryOrders: (() -> DeliveryOrderLog)? = nil,
                     partnerRecords: (() -> PartnerRecords)? = nil) {
        self.init(store: store, now: now, timeZone: { timeZone }, deviceOrigin: deviceOrigin,
                  places: places, directions: directions, partners: partners, budget: budget,
                  delivery: delivery, deliveryOrders: deliveryOrders, partnerRecords: partnerRecords)
    }

    /// New chat: forgets the handles; the counters keep counting up, so an old handle never names a new entry. The held
    /// delivery options and partners go too.
    func resetConversation() {
        registry.clear()
        deliveryOptions = nil
        partners = []
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
    /// - `flow`: the Connections flow of the user message that caused the call. Only the two Google lookups, the two budget lookups and the delivery options and partners lookups read it.
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
        case .partners:
            // SPEC-BOOKCARD-001: the partners tool needs the proxy, and this check comes before any argument is read.
            if !partnerClient().isConfigured { return reject(Say.partnersUnavailable) }
        default:
            break
        }
        // A blank arguments text is `{}` for the three tools that take no argument; every other tool keeps `Say.notObject`.
        let text = (tool == .budgetLeft || tool == .deliveryOptions || tool == .partners) && arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            case .checkDay: return try checkDayPlan(values, flow: flow)
            case .showDay: return try showDayPlan(values)
            case .budgetLeft: return budgetLeft(flow: flow)
            case .spend: return try recordSpend(values, flow: flow)
            case .deliveryOptions: return deliveryOptionsLookup(flow: flow)
            case .delivery: return try orderDelivery(values)
            case .partners: return partnersLookup(flow: flow)
            case .partner: return try requestPartner(values)
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
              let found = store.activity(id: id)
        else { throw Rejection(Say.findID(tool)) }
        return found
    }

    /// The day-plan signature of the window `from` to `to`: stored activities and series occurrences, so a repeat that
    /// changes between the check and Confirm makes the plan stale.
    private func scheduleSignature(from: Date, to: Date) -> [AgentDayPlan.Signature] {
        AgentDayPlan.signature(of: store.activities(in: DateInterval(start: from, end: max(from, to))), from: from, to: to)
    }

    // MARK: - Tools

    private func list(_ values: [String: String]) throws -> AgentToolOutcome {
        guard values["from"] != nil, values["to"] != nil else { throw Rejection(Say.listRange) }
        guard let from = try time(values, .list, "from"), let to = try time(values, .list, "to") else {
            throw Rejection(Say.listRange)
        }
        if to <= from || to.timeIntervalSince(from) > Self.maxListSpan { throw Rejection(Say.listInvalid) }

        let local = formats.local
        var hits: [(start: Date, item: [String: Any])] = store.activities(in: DateInterval(start: from, end: to))
            .map { a in
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
                signature: scheduleSignature(from: created, to: context.checkWindowEnd))
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
        let card = AgentCard(lines: lines, showsGoogleMark: AgentDayPlan.showsGoogleMark(check)) { [self] in
            await confirmDayPlan(check, context)
        }
        card.cancelResult = Self.encode(["status": "declined", "message": AgentDayPlan.Say.cancelled])
        return .card(card)
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
        if scheduleSignature(from: check.createdAt, to: context.checkWindowEnd) != check.signature {
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
        let kept = ids.filter { id in store.activity(id: id) != nil }
        guard !kept.isEmpty else { return nothingAdded("rejected", AgentDayPlan.Say.nothingAdded) }
        let legs = kept.filter { id in store.events.contains { $0.linkedActivityId == id } }.count
        let result = Self.encode(["status": "applied", "events": kept.count, "legs": legs])
        return (AgentResolution(result: result, notice: kept.count < listed ? AgentDayPlan.Say.partialAdded : nil), .confirmed)
    }

    // MARK: - Partners (SPEC-BOOKCARD-001)

    private func partnerClient() -> PartnerClient {
        partnersProvider?() ?? PartnerClient(config: store.config, send: { try await URLSession(configuration: .ephemeral).data(for: $0) })
    }

    /// A time the card may carry is a time that has not passed (by the minute) and is within the next 366 days.
    private func withinBookingWindow(_ date: Date) -> Bool {
        let minute = (now().timeIntervalSince1970 / 60).rounded(.down) * 60
        return date >= Date(timeIntervalSince1970: minute) && date <= Date(timeIntervalSince1970: minute + Self.futureWindow)
    }

    /// `get_partners`: the directory and one form for each entry, run as the request in flight. It writes nothing; the partners
    /// whose form is good are held in memory, and a failure, a task cancelled meanwhile or no good partner holds nothing new.
    private func partnersLookup(flow: UUID?) -> AgentToolOutcome {
        let flow = flow ?? ConnectionLog.beginFlow()
        return .lookup(AgentLookup { [self] in
            let client = partnerClient()
            var good: [PartnerSpec] = []
            if case .success(let entries) = await client.directory(flow: flow) {
                for entry in entries {
                    if case .success(let spec) = await client.form(of: entry, flow: flow) { good.append(spec) }
                }
            }
            guard !good.isEmpty, !Task.isCancelled else {
                let result = Self.encode(["status": "unavailable", "simulated": true, "message": AgentPartner.listUnavailableMessage])
                return AgentLookupOutput(result: result, showsGoogleData: false)
            }
            partners = good
            return AgentLookupOutput(result: Self.encode(AgentPartner.listResult(good)), showsGoogleData: false)
        })
    }

    /// Gate, then the card: the partner must be a held one, and the card is exactly the partner's field list in its order.
    /// Building the card writes nothing and sends nothing; the model's `fields` fill only what its quotes support.
    private func requestPartner(_ values: [String: String]) throws -> AgentToolOutcome {
        guard let id = values["partner"], let spec = partners.first(where: { $0.entry.id == id }) else { throw Rejection(Say.partnersFirst) }
        guard partnerClient().isConfigured else { throw Rejection(Say.partnerUnavailable) }

        let f = formats
        let filled = AgentPrefill.values(fieldsText: values["fields"], fields: spec.fields, userLines: userLines(), now: now(),
                                         calendar: f.calendar)
        var rows: [AgentFieldRow] = []
        for field in spec.fields {
            if field.kind == .group {
                guard let group = AgentFieldGroup(field, addSymbol: AgentPartner.groupAddSymbol, addName: AgentPartner.groupAddName)
                else { throw Rejection(Say.partnerUnavailable) }
                // The kept row numbers are compacted: numbers 1 and 3 give two rows. No kept number gives one blank row.
                let numbers = AgentPrefill.rowNumbers(kept: filled, group: field.key)
                let seeded = (numbers.isEmpty ? [0] : numbers).map { number in
                    group.members.map { member -> AgentFieldSeed in
                        let value = filled[AgentFieldCard.rowKey(field.key, number, member.key)]
                        return AgentFieldSeed(value: value, source: value == nil ? .blank : .stated)
                    }
                }
                rows.append(.repeating(group, rows: seeded))
                continue
            }
            guard let seed = AgentFieldSpec(field) else { throw Rejection(Say.partnerUnavailable) }
            let kept = filled[field.key]
            rows.append(.field(seed, value: kept, source: kept == nil ? .blank : .stated))
        }
        // The schedule choice is the app's own row and exists only when the partner announced a time result.
        let schedulable = spec.results.contains { $0.kind == .time }
        if schedulable { rows.append(AgentPartner.scheduleRow(origin: deviceOrigin())) }
        rows.append(.line(AgentPartner.partnerLine(spec.entry.name)))

        // The card's place search goes through the provider `search_places` uses. The device position is read when the card is
        // built, for a card with a schedule choice (it is the first value of `Leave from`), and again when a search fires, where it
        // reaches the Google Places request only.
        let fieldCard = AgentFieldCard(header: spec.entry.title, rows: rows, favorites: store.favorites, search: { [self] query in
            let center = deviceOrigin().map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            return await (placeSearchProvider?() ?? store.placeSearch).search(query, near: center)
        }, now: { [self] in now() }, candidates: { [self] key, text in
            // A place row the partner resolves asks the partner's own route, never Google. The device position is read when the
            // lookup fires; the client rounds it. Each lookup is a flow of its own, apart from the Confirm flow.
            let origin = deviceOrigin().map { (latitude: $0.latitude, longitude: $0.longitude) }
            switch await partnerClient().candidates(of: spec, field: key, text: text, near: origin, flow: ConnectionLog.beginFlow()) {
            case .success(let places): return .found(places)
            case .failure: return .failed
            }
        })
        let requestID = UUID().uuidString
        return .card(AgentCard(fieldCard: fieldCard, showsGoogleMark: spec.fields.contains { $0.kind == .place }) { [self] in
            // The one snapshot of the model (Confirm froze it): every use below reads it, never a value from the build.
            await confirmPartner(spec, taken: fieldCard.values, requestID: requestID, schedulable: schedulable)
        })
    }

    /// Confirm, in order: the window check of every time field, the one trim and the required values, the length of the
    /// entry, then one request under a new flow and, on `confirmed`, the acting by kind.
    private func confirmPartner(_ spec: PartnerSpec, taken: AgentFieldCard.Snapshot, requestID: String,
                                schedulable: Bool) async -> (AgentResolution, AgentCardMark) {
        let f = formats
        for field in spec.fields where field.kind == .time {
            if let when = taken.date(field.key), !withinBookingWindow(when) {
                let result = Self.encode(["status": "rejected", "message": Say.partnerWindowAtConfirm, "chosen_time": f.local.string(from: when)])
                return (AgentResolution(result: result, notice: Say.startPassed), .notApplied)
            }
        }
        var items: [PartnerRequest.Item] = []
        for field in spec.fields {
            let value: PartnerValue?
            switch field.kind {
            case .text, .place: value = taken.text(field.key).flatMap(AgentDelivery.snapshotText).map { PartnerValue.text($0) }
            case .time: value = taken.date(field.key).map { PartnerValue.text(f.local.string(from: $0)) }
            case .number: value = taken.int(field.key).map { PartnerValue.number($0) }
            case .pickOne: value = taken.option(field.key).map { PartnerValue.text($0) }
            case .onOff: value = taken.flag(field.key).map { PartnerValue.flag($0) }
            case .group:
                let groupRows = taken.rows(of: field.key)
                guard !groupRows.isEmpty else { return partnerEditRejected() }
                var sent: [[PartnerRequest.Item]] = []
                for row in groupRows {
                    var rowItems: [PartnerRequest.Item] = []
                    for member in field.members {
                        let memberValue: PartnerValue?
                        switch (member.kind, row[member.key]?.value) {
                        case (.text, .text(let text)?): memberValue = AgentDelivery.snapshotText(text).map { PartnerValue.text($0) }
                        case (.number, .number(let number)?): memberValue = .number(number)
                        case (.pickOne, .option(let id)?): memberValue = .text(id)
                        default: memberValue = nil
                        }
                        if let memberValue {
                            rowItems.append(PartnerRequest.Item(key: member.key, value: memberValue))
                        } else if !member.isOptional {
                            return partnerEditRejected()
                        }
                    }
                    sent.append(rowItems)
                }
                value = .rows(sent)
            }
            if let value {
                items.append(PartnerRequest.Item(key: field.key, value: value))
            } else if !field.isOptional {
                return partnerEditRejected()
            }
        }
        // The one `number` field of the form, if there is exactly one, gives the record its quantity hint.
        let numberFields = spec.fields.filter { $0.kind == .number }
        var quantityHint: Int?
        if numberFields.count == 1, let item = items.first(where: { $0.key == numberFields[0].key }), case .number(let count) = item.value {
            quantityHint = count
        }
        // The length is the app's own row: it counts only while the switch is on.
        let scheduleOn = schedulable && taken.flag(AgentPartner.cardSwitchKey) == true
        var minutes = 0
        if scheduleOn {
            guard let length = taken.int(AgentPartner.cardLengthKey), AgentPartner.lengthRange.contains(length) else { return partnerEditRejected() }
            minutes = length
        }

        // The booked entry's place is the candidate tapped in the first lookup field of the partner's own order; an unmarked place
        // field, even an earlier one, and a later marked one never supply it.
        let place = spec.fields.first { $0.canLookUp }.flatMap { taken.place($0.key) }

        // The travel rows are the app's own: they count only while the schedule switch and `Travel` are on. Leave from and the mode
        // must hold values, and the entry must have a location (the form needs a lookup field) for the leg to have a destination.
        var travel: (from: Place, mode: TransportMode, destination: Place)?
        if scheduleOn, taken.flag(AgentPartner.cardTravelKey) == true {
            guard let from = taken.place(AgentPartner.cardFromKey), let modeID = taken.option(AgentPartner.cardModeKey),
                  let mode = TransportMode(rawValue: modeID), let destination = place else { return partnerEditRejected() }
            travel = (from, mode, destination)
        }

        let flow = ConnectionLog.beginFlow()
        // The one Routes lookup of the leg, before anything is sent: no travel time (offline, a Routes error, no route, a cancelled
        // lookup) ends Confirm here. The service notes its own packet under this flow.
        var leg: (from: Place, mode: TransportMode, seconds: TimeInterval)?
        if let travel {
            let service = directionsProvider?() ?? store.directions
            let estimate = await service.estimate(
                travel.mode, from: CLLocationCoordinate2D(latitude: travel.from.latitude, longitude: travel.from.longitude),
                to: CLLocationCoordinate2D(latitude: travel.destination.latitude, longitude: travel.destination.longitude), flow: flow)
            guard let seconds = estimate.duration, !Task.isCancelled else { return partnerUnavailable(spec) }
            leg = (travel.from, travel.mode, seconds)
        }
        let answer = await partnerClient().submit(PartnerRequest(requestID: requestID, values: items), to: spec, flow: flow)
        // Cancellation is checked after the answer is known and before anything is written.
        guard !Task.isCancelled else { return partnerUnavailable(spec) }
        switch answer {
        case .failure:
            return partnerUnavailable(spec)
        case .success(.declined):
            let result = Self.encode(["status": "declined", "partner": spec.entry.name, "simulated": true, "message": AgentPartner.declinedMessage])
            return (AgentResolution(result: result, notice: nil), .notApplied)
        case .success(.confirmed(let results)):
            return await actOnPartner(spec, results: results, scheduleOn: scheduleOn, skipped: schedulable && !scheduleOn, minutes: minutes,
                                      place: place, leg: leg, requestID: requestID, quantityHint: quantityHint, flow: flow)
        }
    }

    /// Acting by kind, from the answer only: a `time` item becomes the entry when the switch was on, a `money` item goes to the
    /// budget as an estimate in the week of the `time` item (this week when there is none), a `text` item stays in the reply.
    private func actOnPartner(_ spec: PartnerSpec, results: [PartnerResultItem], scheduleOn: Bool, skipped: Bool, minutes: Int,
                              place: Place?, leg: (from: Place, mode: TransportMode, seconds: TimeInterval)?, requestID: String,
                              quantityHint: Int?, flow: UUID) async -> (AgentResolution, AgentCardMark) {
        var start: Date?
        var itemName: String?
        for item in results {
            if case .time(let text) = item.value {
                start = localDate(text)
                itemName = item.name
            }
        }
        var entryID: UUID?
        if scheduleOn, let start, let itemName {
            let made = await store.addActivityWithTravel(
                title: AgentPartner.entryTitle(partner: spec.entry.name, item: itemName), location: place, startDate: start,
                endDate: start.addingTimeInterval(TimeInterval(minutes * 60)), travelFrom: leg?.from, returnTo: nil,
                outboundMode: leg?.mode ?? .walk, returnMode: .walk, bufferMinutes: 0, notifyLeadMinutes: 0,
                syncToCalendar: store.calendarSyncDefault, travelSecondsHint: leg?.seconds)
            entryID = made.activityId
        }
        var budget: AgentBudget.BookingSpend?
        var spendID: String?
        if let cents = results.moneyCents {
            let sent = await sendEstimatedSpend(amountCents: cents, start: start ?? now(), requestID: UUID().uuidString, flow: flow)
            budget = sent?.spend
            // The id is kept only when the budget partner recorded the spend: only then is there an entry under it.
            if case .recorded? = sent?.spend { spendID = sent?.requestID }
        }
        // The record comes after the spend, so it holds the spend's id; a request that wrote no entry leaves none.
        if let entryID, store.activity(id: entryID) != nil {
            (partnerRecordsProvider?() ?? PartnerRecords.shared).add(
                PartnerRecord(activityID: entryID, partnerID: spec.entry.id, partnerName: spec.entry.name, route: spec.entry.route,
                              requestID: requestID, estimateCents: results.moneyCents, quantityHint: quantityHint,
                              spendRequestID: spendID, switchStarted: false))
        }
        return partnerApplied(entryID, partner: spec.entry.name, results: results, skipped: skipped, budget: budget)
    }

    /// One `spend` of the answered amount, counted in the week of `start`, under the request's own flow, with the request id the
    /// caller made (returned with the result so the record can keep it). Nil when the proxy is not configured. A failure, or a task
    /// cancelled meanwhile, never changes the request.
    private func sendEstimatedSpend(amountCents: Int, start: Date, requestID: String,
                                    flow: UUID) async -> (spend: AgentBudget.BookingSpend, requestID: String)? {
        let client = budgetClient()
        guard client.isConfigured else { return nil }
        let week = BudgetWeek.start(of: start, in: zone())
        let result = await client.spend(amountCents: amountCents, isEstimate: true, weekStart: week,
                                        requestID: requestID, flow: flow)
        switch result {
        case .success(let standing):
            let phrase = AgentBudget.weekPhrase(weekStart: week, currentWeekStart: BudgetWeek.start(of: now(), in: zone()))
            return (.recorded(amountCents: amountCents, standing: standing, week: phrase), requestID)
        case .failure:
            return (.unavailable(notify: !Task.isCancelled), requestID)
        }
    }

    private func partnerEditRejected() -> (AgentResolution, AgentCardMark) {
        let result = Self.encode(["status": "rejected", "message": AgentPartner.editRejectedMessage])
        return (AgentResolution(result: result, notice: nil), .notApplied)
    }

    private func partnerUnavailable(_ spec: PartnerSpec) -> (AgentResolution, AgentCardMark) {
        let result = Self.encode(["status": "unavailable", "partner": spec.entry.name, "simulated": true, "message": AgentPartner.unavailableMessage])
        return (AgentResolution(result: result, notice: AgentPartner.unavailableNotice), .notApplied)
    }

    /// `applied`, with the entry's values read back from the Store. Not private so a test can reach the read-back refusal, which
    /// the Store write cannot be made to produce (it never suspends between the write and the read). `skipped` is true when the
    /// user chose not to add the entry to the schedule.
    func partnerApplied(_ id: UUID?, partner: String, results: [PartnerResultItem], skipped: Bool,
                        budget: AgentBudget.BookingSpend? = nil) -> (AgentResolution, AgentCardMark) {
        var object: [String: Any] = ["status": "applied", "partner": partner, "simulated": true, "results": AgentDelivery.resultFields(results)]
        var message = AgentPartner.appliedMessage
        if skipped { message += " " + AgentPartner.scheduleSkippedSentence }
        if let id {
            guard let stored = store.activity(id: id) else { return (notFound(), .notApplied) }
            let local = formats.local
            object["id"] = stored.id.uuidString
            object["title"] = Self.sanitized(stored.title)
            object["start"] = local.string(from: stored.startDate)
            object["end"] = local.string(from: stored.endDate)
        }
        if let budget {
            object["budget"] = budget.block
            message += " " + budget.sentence
        }
        object["message"] = message
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
                // A task cancelled meanwhile says nothing to the user, as in the partner request.
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

    /// What a confirmed delivery order is made from: the values of the card as it was built and the one snapshot of its field card.
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

    /// Gate, then the card: every argument is decided here, in the order of design.md section 4. Building the card writes
    /// nothing and sends nothing. The card is the generic field card (SPEC-CHOICECARD-001): the user fills what is blank and
    /// taps Confirm once.
    private func orderDelivery(_ values: [String: String]) throws -> AgentToolOutcome {
        guard let handle = values["place_id"], AgentPlaces.isPlaceHandle(handle), let place = registry.place(handle),
              !AgentPlaces.displayName(place.name).isEmpty else { throw Rejection(Say.deliveryPlace) }
        guard values["arrive_at"] != nil, let arrival = try time(values, .delivery, "arrive_at") else { throw Rejection(Say.deliveryTime) }
        guard withinBookingWindow(arrival) else { throw Rejection(Say.deliveryWindow) }
        guard let options = deliveryOptions else { throw Rejection(Say.deliveryOptionsFirst) }
        guard let itemsText = values["items"], let lines = AgentDelivery.parseItems(itemsText) else { throw Rejection(Say.deliveryItems) }
        guard lines.allSatisfy({ options.menuItem(id: $0.itemID) != nil }) else { throw Rejection(Say.deliveryItemUnknown) }
        // A card id is optional. The model fills optional arguments with guesses, so the card shows what it passed and an id the
        // held options do not hold is refused.
        var card: DeliveryCard?
        if let cardID = values["card_id"] {
            guard let held = options.card(id: cardID) else { throw Rejection(Say.deliveryCardUnknown) }
            card = held
        }
        guard let totalCents = options.totalCents(for: lines) else { throw Rejection(Say.deliveryItems) }
        // The delivery place comes from the place table or from the schedule, never from the model's text.
        var named: String?
        if let target = values["deliver_to"] {
            guard AgentPlaces.isPlaceHandle(target), let found = registry.place(target), let text = AgentDelivery.placeText(found) else {
                throw Rejection(Say.deliveryToHandle)
            }
            named = text
        }
        guard deliveryClient().isConfigured else { throw Rejection(Say.deliveryUnavailable) }

        let f = formats
        let current = now()
        var addressValue: AgentFieldValue?
        var addressSource = AgentFieldSource.blank
        if let named {
            addressValue = .text(named)
            addressSource = .stated
        } else {
            // One read of the schedule sees the stored entries and the occurrences of repeating activities (REQ-015); the
            // interval holds both anchors, the arrival and now, and the minute of the later one.
            let span = DateInterval(start: min(arrival, current), end: max(arrival, current).addingTimeInterval(60))
            let entries = store.activities(in: span, calendar: f.calendar)
            if let suggestion = AgentDelivery.suggestedPlaceText(activities: entries, arrival: arrival, now: current) {
                addressValue = .text(suggestion)
                addressSource = .inferred
            }
        }

        let placeName = AgentPlaces.displayName(place.name)
        let items = lines.map { (name: options.menuItem(id: $0.itemID)?.name ?? $0.itemID, quantity: $0.quantity) }
        var rows: [AgentFieldRow] = [.line(placeName)]
        rows += items.map { AgentFieldRow.line("\($0.quantity) x \($0.name)") }
        rows.append(.line(AgentDelivery.estimatedTotalLine(cents: totalCents)))
        // The partner's fields, in the partner's order; the value of each comes from what the call and the schedule gave.
        for field in options.fields {
            guard let spec = AgentFieldSpec(field) else { throw Rejection(Say.deliveryUnavailable) }
            switch field.key {
            case DeliveryClient.arriveKey:
                rows.append(.field(spec, value: .time(arrival), source: .stated))
            case DeliveryClient.addressKey:
                rows.append(.field(spec, value: addressValue, source: addressSource))
            default:
                rows.append(.field(spec, value: card.map { AgentFieldValue.option($0.id) }, source: card == nil ? .blank : .stated))
            }
        }
        // The meal entry is the app's own row: the switch, and while it is on the title and the start, all inferred.
        let minuteOfDay = f.calendar.component(.hour, from: arrival) * 60 + f.calendar.component(.minute, from: arrival)
        let mealSwitch = AgentFieldSpec.onOff(key: AgentDelivery.mealSwitchKey, label: AgentDelivery.mealSwitchLabel,
                                              on: AgentDelivery.mealOnWord, off: AgentDelivery.mealOffWord)
        let mealTitle = AgentFieldSpec(key: AgentDelivery.mealTitleKey, kind: .text, label: AgentDelivery.mealTitleLabel,
                                       limit: AgentBooking.maxTitle - AgentBooking.simulatedSuffix.count)
        let mealStart = AgentFieldSpec(key: AgentDelivery.mealStartKey, kind: .time, label: AgentDelivery.mealStartLabel)
        rows.append(.switchField(mealSwitch, value: .flag(true), source: .inferred, dependents: [
            .field(mealTitle, value: .text(AgentDelivery.mealWord(arrivalMinute: minuteOfDay)), source: .inferred),
            .field(mealStart, value: .time(arrival), source: .inferred)]))
        rows.append(.line(AgentDelivery.partnerLine))

        // The card's place search goes through the provider `search_places` uses. The device position is read here, when a
        // search fires, and reaches the Google Places request only.
        let fieldCard = AgentFieldCard(header: AgentDelivery.cardHeader, rows: rows, favorites: store.favorites, search: { [self] query in
            let center = deviceOrigin().map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            return await (placeSearchProvider?() ?? store.placeSearch).search(query, near: center)
        }, now: { [self] in now() })
        let requestID = UUID().uuidString
        // The card keeps the place, the items and the total as they were when it was built, except the editable values;
        // Confirm never reads the registry, the held options or the schedule again.
        return .card(AgentCard(fieldCard: fieldCard, showsGoogleMark: true) { [self] in
            // The one snapshot of the model (Confirm froze it): every use of the arrival below reads this value, never the
            // arrival that was captured when the card was built, because the Arrival is an editable field.
            let taken = fieldCard.values
            let when = taken.date(DeliveryClient.arriveKey)
            // The card may have waited a long time, and the user may have dialled another time: it must still be a time that
            // has not passed and that is inside the window.
            if let when, !withinBookingWindow(when) {
                let result = Self.encode(["status": "rejected", "message": Say.deliveryWindowAtConfirm, "arrive_at": f.local.string(from: when)])
                return (AgentResolution(result: result, notice: Say.startPassed), .notApplied)
            }
            // The one trim, here: the delivery text and the title.
            let address = taken.text(DeliveryClient.addressKey).flatMap(AgentDelivery.snapshotText)
            let chosen = taken.option(DeliveryClient.cardKey).flatMap { options.card(id: $0) }
            let mealOn = taken.flag(AgentDelivery.mealSwitchKey) == true
            let title = mealOn ? taken.text(AgentDelivery.mealTitleKey).flatMap(AgentDelivery.snapshotText) : nil
            guard let when, let address, let chosen, !mealOn || title != nil else {
                let result = Self.encode(["status": "rejected", "message": AgentDelivery.editRejectedMessage])
                return (AgentResolution(result: result, notice: nil), .notApplied)
            }
            let meal = title.map { DeliveryOrder.Meal(title: $0, start: taken.date(AgentDelivery.mealStartKey) ?? when) }
            let request = DeliveryRequest(requestID: requestID, restaurant: AgentBooking.sentName(place), arriveAt: f.local.string(from: when),
                                          items: lines, address: address, cardID: chosen.id)
            return await placeOrder(DeliveryOrder(request: request, options: options, placeName: placeName, arrival: when,
                                                  cardLabel: chosen.label, items: items, totalCents: totalCents, meal: meal))
        })
    }

    /// The order request and what follows it (spec.md REQ-DELIVERY-011 to 013): one request under a new flow, the cancellation
    /// check, then on `confirmed` the meal entry, the order record and the budget hand-off, in that order. It uses only the
    /// snapshot in `order`: the field card, the registry, the held options and the schedule are not read again.
    private func placeOrder(_ order: DeliveryOrder) async -> (AgentResolution, AgentCardMark) {
        let flow = ConnectionLog.beginFlow()
        let answer = await deliveryClient().order(order.request, options: order.options, flow: flow)
        // Cancellation is checked after the answer is known and before anything is written.
        guard !Task.isCancelled else { return deliveryUnavailable() }
        switch answer {
        case .failure:
            return deliveryUnavailable()
        case .success(.declined):
            let result = Self.encode(["status": "declined", "partner": DeliveryClient.partnerName, "simulated": true,
                                      "message": AgentDelivery.declinedMessage])
            return (AgentResolution(result: result, notice: nil), .notApplied)
        case .success(.confirmed(let orderID, let results)):
            // Act by kind. The client already refuses a different total or arrival; the `money` and `time` items are checked
            // again here against the card's, and the total, the arrival and the money item's name are read from those items.
            guard let totalCents = results.moneyCents, totalCents == order.totalCents, let moneyName = results.moneyName,
                  let arrivalText = results.arrival, arrivalText == order.request.arriveAt else { return deliveryUnavailable() }
            let f = formats
            // The suggested meal entry, with the write `book(_:)` uses; the written activity is looked up in the Store.
            var meal: AgentDelivery.AppliedMeal?
            if let wanted = order.meal {
                let made = await store.addActivityWithTravel(
                    title: AgentDelivery.mealTitle(typed: wanted.title), location: nil, startDate: wanted.start,
                    endDate: wanted.start.addingTimeInterval(TimeInterval(AgentDelivery.mealMinutes * 60)), travelFrom: nil,
                    returnTo: nil, outboundMode: .walk, returnMode: .walk, bufferMinutes: 0, notifyLeadMinutes: 0,
                    syncToCalendar: store.calendarSyncDefault, travelSecondsHint: nil)
                if let stored = store.activities.first(where: { $0.id == made.activityId }) {
                    meal = .added(id: stored.id.uuidString, title: Self.sanitized(stored.title),
                                  start: f.local.string(from: stored.startDate), end: f.local.string(from: stored.endDate))
                } else {
                    meal = .notAdded
                }
            }
            // The order record, before any budget request. A failed write changes nothing else.
            var mealID: String?
            if case .added(let id, _, _, _)? = meal { mealID = id }
            let lines = order.request.items.map { line in
                DeliveryOrderItem(itemID: line.itemID, name: order.options.menuItem(id: line.itemID)?.name ?? line.itemID,
                                  quantity: line.quantity, unitPriceCents: order.options.menuItem(id: line.itemID)?.priceCents ?? 0)
            }
            (deliveryOrdersProvider?() ?? DeliveryOrderLog.shared).add(DeliveryOrderEntry(
                orderID: orderID, requestID: order.request.requestID, placeName: order.placeName, arrival: arrivalText,
                items: lines, address: order.request.address, cardLabel: order.cardLabel, estimatedTotalCents: totalCents,
                createdAt: now(), mealActivityID: mealID))
            let budget = await sendOrderTotal(order, totalCents: totalCents, flow: flow)
            let fields = AgentDelivery.appliedFields(
                orderID: orderID, restaurant: order.placeName, items: order.items, address: order.request.address,
                cardLabel: order.cardLabel, results: results, meal: meal, budget: budget)
            let notice = budget.notice(moneyName: moneyName, totalCents: totalCents)
            return (AgentResolution(result: Self.encode(fields), notice: notice), .confirmed)
        }
    }

    /// One `spend` of the answered total, counted in the week of the arrival, under the order's own flow and request id. A
    /// failure, or a task cancelled meanwhile, never changes the order, the entry or the record.
    private func sendOrderTotal(_ order: DeliveryOrder, totalCents: Int, flow: UUID) async -> AgentDelivery.BudgetHandOff {
        let client = budgetClient()
        guard client.isConfigured else { return .unavailable(notify: !Task.isCancelled) }
        let orderWeek = BudgetWeek.start(of: order.arrival, in: zone())
        let result = await client.spend(amountCents: totalCents, isEstimate: true, weekStart: orderWeek,
                                        requestID: order.request.requestID, flow: flow)
        switch result {
        case .success(let standing):
            let week = AgentBudget.weekPhrase(weekStart: orderWeek, currentWeekStart: BudgetWeek.start(of: now(), in: zone()))
            return .recorded(standing: standing, week: week)
        case .failure:
            return .unavailable(notify: !Task.isCancelled)
        }
    }

    /// `unavailable`: nothing was ordered. Not private so a test can reach it, as `partnerApplied` is.
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
            guard let target = store.activity(id: id) else { return (notFound(), .notApplied) }
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
        guard let present = store.activity(id: id) else { return (notFound(), .notApplied) }
        if Snapshot(present) != seen {
            return (AgentResolution(result: Self.encode(["status": "stale", "message": Say.stale]), notice: Say.notice), .notApplied)
        }
        return nil
    }

    /// `applied`, with the values read back from the Store. A created record with a place adds its location and, when a
    /// leg was stored, the leg's leave time and minutes.
    private func applied(_ id: UUID, withPlace: Bool = false) -> (AgentResolution, AgentCardMark) {
        guard let stored = store.activity(id: id) else { return (notFound(), .notApplied) }
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
