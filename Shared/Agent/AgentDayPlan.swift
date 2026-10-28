import Foundation

/// Plan my day (SPEC-PLANDAY-001): the overlap and lateness arithmetic, the result JSON and the card lines.
enum AgentDayPlan {
    static let lookupCap = 10

    struct Pair: Hashable {
        let from: Int
        let to: Int
    }

    struct Stop: Equatable {
        var title: String
        var start: Date
        var end: Date
        var place: Place?
        var eventHandle: String?
        var isNew: Bool
        var referenced: Bool
    }

    enum Problem: Equatable {
        case overlap(Int, Int, minutes: Int)
        case late(from: Int, to: Int, minutes: Int)
    }

    struct Leg: Equatable {
        let from: Int
        let to: Int
        let route: AgentRoute?
        let leave: Date?
    }

    struct Signature: Equatable {
        let id: UUID
        let title: String
        let place: Place?
        let start: Date
        let end: Date
    }

    struct Check {
        let handle: String
        let stops: [Stop]
        let legs: [Leg]
        let problems: [Problem]
        let createdAt: Date
        let signature: [Signature]
    }

    static func effective(_ parsed: [Stop], events: [PlanMyDay.Event]) -> [Stop] { [] }
    static func overlaps(_ stops: [Stop]) -> [Problem] { [.overlap(0, 0, minutes: 0)] }
    static func legPairs(_ stops: [Stop], cap: Int) -> (pairs: [Pair], overCap: [Pair]) { ([Pair(from: 0, to: 0)], []) }
    static func evaluate(stops: [Stop], routes: [Pair: AgentRoute], bufferMinutes: Int) -> (legs: [Leg], problems: [Problem]) { ([], [.overlap(0, 0, minutes: 0)]) }
    static func resultJSON(_ check: Check, checksMade: Int) -> String { "" }
    static func cardLines(_ check: Check, first: Check?, mode: TransportMode, zone: TimeZone) -> [String] { [] }
    static func showsGoogleMark(_ check: Check) -> Bool { false }
}
