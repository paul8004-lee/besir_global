import Foundation

/// Plan my day (SPEC-PLANDAY-001): the pure part that gathers today's events and composes the one plan message.
enum PlanMyDay {
    static let takeCount = 5
    static let visionParallel = 3
    static let eventsMax = 40
    static let storePlacesMax = 8
    static let requestCap = 12
    static let titleMax = 80
    static let locationMax = 120

    enum Source: String, Equatable {
        case besir, calendar
    }

    struct Event: Equatable {
        var handle: String
        var title: String
        var start: Date
        var end: Date
        var locationText: String?
        var place: Place?
        var placeHandle: String?
        var source: Source
    }

    enum Shared: Equatable {
        case image(VisionFields)
        case text(String)
    }

    struct Held {
        let shared: [Shared]
        let ids: [UUID]
        let skipped: Int
        let flow: UUID
    }

    static let modeChoices: [TransportMode] = []

    static func buttonLabel(count: Int, held: Bool) -> String? { "" }

    static func events(activities: [ActivityBlock], entries: [CalendarEntry], now: Date, calendar: Calendar) -> (events: [Event], cut: Bool) {
        ([], false)
    }

    @MainActor
    static func todaysEntries(from mirror: CalendarMirroring, now: Date, calendar: Calendar) async -> [CalendarEntry]? { [] }

    static func registerStorePlaces(_ events: [Event], registry: inout AgentPlaceRegistry) -> [Event] { [] }

    static func compose(now: Date, zone: TimeZone, mode: TransportMode, events: [Event], shared: [Shared]) -> String { "" }

    static func shownLine(sharedCount: Int, eventCount: Int, calendarAvailable: Bool, cut: Bool) -> String { "" }
}

/// What a plan turn knows about the day, kept by the app for every check.
struct DayPlanContext {
    let mode: TransportMode
    let events: [PlanMyDay.Event]
    let checkWindowEnd: Date
}
