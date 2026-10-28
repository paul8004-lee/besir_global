import Foundation

// SPEC-PLANDAY-001: the pure part of the day plan. The model proposes stops; the app compares them with all of today's
// events, finds the overlaps and the late arrivals from Routes numbers it computed itself, and builds the card lines from
// the stored check only. Nothing here reads the Store, the network or a clock.

enum AgentDayPlan {
    /// Routes lookups per check, checks per turn, and the longest lists of explaining lines on a card.
    static let lookupCap = 10
    static let checksPerTurn = 3
    private static let firstIdeaMax = 2
    private static let changeMax = 2

    /// The two stops of a leg as 1-based positions in the effective order (the later stop is `to`).
    struct Pair: Hashable {
        let from: Int
        let to: Int
    }

    /// One stop of the day: an event of the app's list (`eventHandle` set, `isNew` false) or a stop the model proposes.
    /// `referenced` marks an event the model named in its stops (to give it a place).
    struct Stop: Equatable {
        var title: String
        var start: Date
        var end: Date
        var place: Place?
        var eventHandle: String?
        var isNew: Bool
        var referenced: Bool
    }

    /// A problem the app found. Positions are 1-based in the effective order; minutes are the app's, rounded up.
    enum Problem: Equatable {
        case overlap(Int, Int, minutes: Int)
        case late(from: Int, to: Int, minutes: Int)
    }

    /// The travel between the earlier stop that ends last (`from`) and a later stop (`to`). `route` nil means unchecked:
    /// no number is ever given to it.
    struct Leg: Equatable {
        let from: Int
        let to: Int
        let route: AgentRoute?
        /// The time to leave (`start of to - travel - buffer`); nil with the route.
        let leave: Date?
    }

    /// What the Store held in the signature window when the check was made (`Confirm` compares it again).
    struct Signature: Equatable {
        let id: UUID
        let title: String
        let place: Place?
        let start: Date
        let end: Date
    }

    /// One stored check: the effective stops in order, the legs, the problems and when it was made.
    struct Check {
        let handle: String
        let stops: [Stop]
        let legs: [Leg]
        let problems: [Problem]
        let createdAt: Date
        let signature: [Signature]
    }

    /// Every fixed string of the day plan, spelled once (plan.md section 3.4). None repeats a model value or lists valid ones.
    enum Say {
        static let notInPlanTurn = "Day plans are only prepared after the user taps Plan my day."
        static let stopsFormat = "Call check_day_plan again with stops as a JSON array of 1 to 8 stops, each an object with string values."
        static let stopBuild = "Call check_day_plan again with each stop built as the tool describes."
        static let stopEvent = "Call check_day_plan again using only event ids from the plan message, each at most once."
        static let stopNew = "Call check_day_plan again with a title, a start and an end for each new stop."
        static let stopTime = "Call check_day_plan again with start and end as local date-times in the form YYYY-MM-DDTHH:MM, today, not in the past, with the end after the start and at most 24 hours later."
        static let stopTitle = "Call check_day_plan again with a title of at most 80 characters."
        static let stopDuplicate = "Call check_day_plan again without adding an event that is already in the schedule."
        static let stopNone = "Call check_day_plan again with at least one new stop to add."
        static let stopPlace = "Call search_places to find the place, then call check_day_plan again with the place_id it returns, or leave place_id out."
        static let searchLimit = "In a day plan at most six places can be searched. Use the places already found, or leave the stop without a place."
        static let travelRefused = "In a day plan the travel times come from check_day_plan. Do not call get_travel_time."
        static let checksUsed = "The plan was already checked three times. Call show_day_plan with the last plan_id."
        static let planUnknown = "Call check_day_plan to prepare a plan, then call show_day_plan with the plan_id it returns."
        static let planOld = "Only the latest checked plan can be shown. Call show_day_plan with the latest plan_id."
        static let planProblems = "That plan still has problems. Fix them and call check_day_plan again."
        static let planStale = "The travel times are out of date. Call check_day_plan once more, then show_day_plan."
        static let planStaleLast = "The travel times are out of date and the plan cannot be shown now. Tell the user the plan could not be completed."
        static let okMessage = "No overlap or late arrival was found. Call show_day_plan with this plan_id. Do not state any time that this result does not give."
        static let conflictMessage = "Fix these problems by changing the stops, then call check_day_plan again. Do not state any time that this result does not give."
        static let lastMessage = "This is the last check. Call show_day_plan with this plan_id."
        /// Notices after Confirm.
        static let partialAdded = "Some events were not added."
        static let nothingAdded = "Nothing was added."
        /// Result messages when Confirm adds nothing (the stale-route messages are `planStale` and `planStaleLast`).
        static let scheduleChanged = "Nothing was added. Tell the user the schedule changed."
        static let startPassed = "Nothing was added. Tell the user the start time has passed."
        /// Card lines.
        static let heading = "Plan for today"
        static let headingProblems = "Plan for today - needs attention"
        static let unchecked = "Travel time not checked"
        static func overlap(_ first: String, _ second: String, _ minutes: Int) -> String {
            "Overlap: \(first) and \(second) share \(minutes) min."
        }
        static func late(_ minutes: Int, _ title: String) -> String { "Late: \(minutes) min late for \(title)." }
        static func firstIdeaOverlap(_ first: String, _ second: String, _ minutes: Int) -> String {
            "First idea: \(first) and \(second) overlapped by \(minutes) min."
        }
        static func firstIdeaLate(_ minutes: Int, _ title: String) -> String { "First idea: \(minutes) min late for \(title)." }
        static func moved(_ title: String, _ time: String) -> String { "Moved: \(title) to \(time)." }
        static func leftOut(_ title: String) -> String { "Left out: \(title)." }
    }

    /// A refusal of the stop gate: one fixed `Say` string.
    struct Refusal: Error {
        let message: String
    }

    /// The strict stop gate of REQ-PLANDAY-008 (signature only in the red commit).
    static func parse(_ text: String, context: DayPlanContext, registry: AgentPlaceRegistry, now: Date, zone: TimeZone) throws -> [Stop] {
        throw Refusal(message: "")
    }

    // MARK: Effective stops, overlaps and legs (REQ-PLANDAY-009)

    /// Every event of the app's list plus the model's new stops, sorted by start; on a tie an event comes before a new stop,
    /// then input order. An event the model named (`parsed` with its handle) keeps the app's title and times and may gain a
    /// place only when the app's event has none.
    static func effective(_ parsed: [Stop], events: [PlanMyDay.Event]) -> [Stop] {
        var all: [Stop] = events.map { event in
            let named = parsed.first { $0.eventHandle == event.handle }
            return Stop(title: event.title, start: event.start, end: event.end, place: event.place ?? named?.place,
                        eventHandle: event.handle, isNew: false, referenced: named != nil)
        }
        all += parsed.filter(\.isNew)
        return all.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.isNew != b.element.isNew { return !a.element.isNew }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Every pair of stops, at least one of them new, whose intervals intersect. Touching intervals do not; two existing
    /// events are never reported.
    static func overlaps(_ stops: [Stop]) -> [Problem] {
        var found: [Problem] = []
        for (later, stop) in stops.enumerated() {
            for (earlier, other) in stops[..<later].enumerated() where other.isNew || stop.isNew {
                guard other.start < stop.end, stop.start < other.end else { continue }
                let seconds = min(other.end, stop.end).timeIntervalSince(max(other.start, stop.start))
                guard seconds > 0 else { continue }
                found.append(.overlap(earlier + 1, later + 1, minutes: Int((seconds / 60).rounded(.up))))
            }
        }
        return found
    }

    /// For every stop that has an earlier stop: the earlier stop that ends last (the later one on a tie) and the stop. The pair
    /// counts when one of them is new, the later one starts at or after the other's end (an overlapping pair is only an
    /// overlap) and the two places differ. `lookup` is false when a place is missing: the leg is unchecked, no lookup is made.
    private static func candidates(_ stops: [Stop]) -> [(pair: Pair, lookup: Bool)] {
        var found: [(Pair, Bool)] = []
        for later in stops.indices.dropFirst() {
            var origin = 0
            for earlier in 0..<later where stops[earlier].end >= stops[origin].end { origin = earlier }
            guard stops[origin].isNew || stops[later].isNew, stops[later].start >= stops[origin].end else { continue }
            let pair = Pair(from: origin + 1, to: later + 1)
            if let a = stops[origin].place, let b = stops[later].place {
                if a != b { found.append((pair, true)) }
            } else {
                found.append((pair, false))
            }
        }
        return found
    }

    /// The pairs to look up with Routes, in order of the later stop: the first `cap` and the rest.
    static func legPairs(_ stops: [Stop], cap: Int) -> (pairs: [Pair], overCap: [Pair]) {
        let wanted = candidates(stops).filter(\.lookup).map(\.pair)
        let limit = max(0, cap)
        return (Array(wanted.prefix(limit)), Array(wanted.dropFirst(limit)))
    }

    /// The legs and every problem: overlaps first, then late arrivals. `routes` holds the answers of the lookups; a pair with
    /// no answer (failed, cancelled, offline, beyond the cap) or with a missing place is an unchecked leg. A leg is late by
    /// the whole minutes (rounded up) that the leave time is before the end of the stop it starts from.
    static func evaluate(stops: [Stop], routes: [Pair: AgentRoute], bufferMinutes: Int) -> (legs: [Leg], problems: [Problem]) {
        var legs: [Leg] = []
        var late: [Problem] = []
        for (pair, lookup) in candidates(stops) {
            guard lookup, let route = routes[pair] else {
                legs.append(Leg(from: pair.from, to: pair.to, route: nil, leave: nil))
                continue
            }
            let leave = Store.departureTime(arrival: stops[pair.to - 1].start, travelSeconds: route.seconds, bufferMinutes: bufferMinutes)
            legs.append(Leg(from: pair.from, to: pair.to, route: route, leave: leave))
            let behind = stops[pair.from - 1].end.timeIntervalSince(leave)
            if behind > 0 { late.append(.late(from: pair.from, to: pair.to, minutes: Int((behind / 60).rounded(.up)))) }
        }
        return (legs, overlaps(stops) + late)
    }

    // MARK: The result for the model (REQ-PLANDAY-009)

    /// Sorted keys: `message`, `plan_id`, `problems` (type, minutes, the two stops by event id or title), `status` and
    /// `unchecked` (position pairs). Only the app's numbers and fixed words; the last allowed check says so.
    static func resultJSON(_ check: Check, checksMade: Int) -> String {
        func named(_ position: Int) -> [String: String] {
            guard check.stops.indices.contains(position - 1) else { return [:] }
            let stop = check.stops[position - 1]
            if let handle = stop.eventHandle { return ["id": handle] }
            return ["title": AgentPlaces.displayName(stop.title)]
        }
        let problems: [[String: Any]] = check.problems.map { problem in
            switch problem {
            case .overlap(let first, let second, let minutes):
                return ["type": "overlap", "minutes": minutes, "stops": [named(first), named(second)]]
            case .late(let from, let to, let minutes):
                return ["type": "late", "minutes": minutes, "stops": [named(from), named(to)]]
            }
        }
        let ok = check.problems.isEmpty
        let message = ok ? Say.okMessage : (checksMade >= checksPerTurn ? Say.lastMessage : Say.conflictMessage)
        return AgentToolbox.encode(["status": ok ? "ok" : "conflict", "plan_id": check.handle, "problems": problems,
                                    "unchecked": check.legs.filter { $0.route == nil }.map { [$0.from, $0.to] }, "message": message])
    }

    // MARK: The card (REQ-PLANDAY-010, 011)

    /// The stops the card draws, as indices: the new stops, the referenced events, the stops named in a problem and the
    /// stop directly before and after each new stop.
    private static func shown(_ check: Check) -> [Int] {
        var drawn = Set<Int>()
        for (index, stop) in check.stops.enumerated() {
            if stop.referenced { drawn.insert(index) }
            guard stop.isNew else { continue }
            drawn.formUnion([index - 1, index, index + 1].filter { check.stops.indices.contains($0) })
        }
        for problem in check.problems {
            switch problem {
            case .overlap(let first, let second, _): drawn.formUnion([first - 1, second - 1])
            case .late(let from, let to, _): drawn.formUnion([from - 1, to - 1])
            }
        }
        return drawn.filter { check.stops.indices.contains($0) }.sorted()
    }

    /// True when a line of the card holds a place name (a new stop with a place) or a drawn leg is verified: Google's mark.
    static func showsGoogleMark(_ check: Check) -> Bool {
        let drawn = shown(check)
        if drawn.contains(where: { check.stops[$0].isNew && check.stops[$0].place != nil }) { return true }
        return check.legs.contains { $0.route != nil && drawn.contains($0.to - 1) }
    }

    /// The card lines in order: the heading, the drawn stops in time order with the leg into each directly above it, one
    /// line per remaining problem and, when `first` (the first check of the turn) is another check, at most four lines on
    /// what changed from it. Every title is the sanitized title; every number is the app's.
    static func cardLines(_ check: Check, first: Check?, mode: TransportMode, zone: TimeZone) -> [String] {
        let time = timeFormatter(zone)
        func title(_ stop: Stop) -> String { AgentPlaces.displayName(stop.title) }
        func title(at position: Int) -> String { check.stops.indices.contains(position - 1) ? title(check.stops[position - 1]) : "" }

        var lines = [check.problems.isEmpty ? Say.heading : Say.headingProblems]
        var above: Int?
        for index in shown(check) {
            let stop = check.stops[index]
            if let leg = check.legs.first(where: { $0.to == index + 1 }) {
                if let route = leg.route, let leave = leg.leave {
                    let duration = TravelEstimate(mode: mode, duration: route.seconds, distance: nil, source: "Google").durationText
                    var line = "Leave \(time.string(from: leave)) - \(duration) \(AgentPlaces.modePhrase(mode))"
                    if above != leg.from - 1 { line += " from \(title(at: leg.from))" }
                    lines.append(line + " - " + AgentPlaces.verifiedLine)
                } else {
                    lines.append(Say.unchecked)
                }
            }
            lines.append("\(time.string(from: stop.start)) - \(time.string(from: stop.end)) \(title(stop))" + (stop.isNew ? " (new)" : ""))
            if stop.isNew, let place = stop.place { lines.append("At \(AgentPlaces.displayName(place.name))") }
            above = index
        }
        for problem in check.problems {
            switch problem {
            case .overlap(let a, let b, let minutes): lines.append(Say.overlap(title(at: a), title(at: b), minutes))
            case .late(_, let to, let minutes): lines.append(Say.late(minutes, title(at: to)))
            }
        }
        if let first, first.handle != check.handle { lines += changeLines(check, first: first, time: time) }
        return lines
    }

    /// What a stop is called across two checks: its event handle, else its lower-cased title and its order among the new
    /// stops of that title (by start).
    private struct Identity: Hashable {
        let key: String
        let ordinal: Int
    }

    private static func identities(_ stops: [Stop]) -> [Identity] {
        var seen: [String: Int] = [:]
        return stops.map { stop in
            if let handle = stop.eventHandle { return Identity(key: "e:" + handle, ordinal: 0) }
            let key = "t:" + AgentPlaces.displayName(stop.title).lowercased()
            defer { seen[key, default: 0] += 1 }
            return Identity(key: key, ordinal: seen[key, default: 0])
        }
    }

    /// `First idea:` lines (the first check's problems, largest minutes first, at most two) and then `Moved:` and `Left out:`
    /// lines (at most two together, in time order), all from the stored checks.
    private static func changeLines(_ check: Check, first: Check, time: DateFormatter) -> [String] {
        func title(_ stops: [Stop], _ position: Int) -> String {
            stops.indices.contains(position - 1) ? AgentPlaces.displayName(stops[position - 1].title) : ""
        }
        func minutes(_ problem: Problem) -> Int {
            switch problem {
            case .overlap(_, _, let value): return value
            case .late(_, _, let value): return value
            }
        }
        var lines: [String] = []
        let ideas = first.problems.enumerated().sorted { a, b in
            minutes(a.element) != minutes(b.element) ? minutes(a.element) > minutes(b.element) : a.offset < b.offset
        }.prefix(firstIdeaMax)
        for (_, problem) in ideas {
            switch problem {
            case .overlap(let a, let b, let value): lines.append(Say.firstIdeaOverlap(title(first.stops, a), title(first.stops, b), value))
            case .late(_, let to, let value): lines.append(Say.firstIdeaLate(value, title(first.stops, to)))
            }
        }
        let now = identities(check.stops)
        var changes: [(at: Date, text: String)] = []
        for (index, identity) in identities(first.stops).enumerated() {
            let before = first.stops[index]
            if let match = now.firstIndex(of: identity) {
                let after = check.stops[match]
                if after.start != before.start {
                    changes.append((after.start, Say.moved(AgentPlaces.displayName(after.title), time.string(from: after.start))))
                }
            } else {
                changes.append((before.start, Say.leftOut(AgentPlaces.displayName(before.title))))
            }
        }
        let ordered = changes.enumerated().sorted { a, b in
            a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
        }
        return lines + ordered.prefix(changeMax).map(\.element.text)
    }

    private static func timeFormatter(_ zone: TimeZone) -> DateFormatter {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.calendar = calendar
        f.timeZone = zone
        f.dateFormat = "h:mm a"
        return f
    }
}
