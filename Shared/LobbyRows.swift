import Foundation

/// One schedule item the be on-time sir row reads: an activity, or a travel event that belongs
/// to no activity, with the leg facts it holds.
struct LobbyItem: Equatable {
    let id: String
    let title: String
    let start: Date
    let leaveBy: Date?
    let travelSeconds: Int?
    let mode: TransportMode?
}

/// One entry of today that a partner request made, as the be full sir row groups it.
struct LobbyStay: Equatable {
    let id: String
    let start: Date
    let partnerID: String
    let partnerName: String
}

/// One feature row of the lobby: the feature's id and title with the key lines under it.
struct LobbyRow: Equatable, Identifiable {
    let id: String
    let title: String
    let lines: [String]
}

/// The lobby's key lines, built from the schedule, the partner records and the budget ledger
/// the app already holds.
enum LobbyRows {
    /// One row per feature of the feature list, in the list's order.
    static func rows(items: [LobbyItem], stays: [LobbyStay], spentCents: Int, entries: [BudgetEntry],
                     now: Date, calendar: Calendar) -> [LobbyRow] {
        RootView.Service.allCases.map { service in
            let lines: [String]
            switch service {
            case .onTime: lines = onTimeLines(items: items, now: now, calendar: calendar)
            case .full: lines = fullLines(stays: stays, now: now, calendar: calendar)
            case .rich: lines = richLines(spentCents: spentCents, entries: entries)
            }
            return LobbyRow(id: service.id, title: service.title, lines: lines)
        }
    }

    /// The be on-time sir lines of the day's items: the next item's stored departure time, then
    /// its title, start, travel time and the count of the rest of today. The next item is the
    /// first, in start order and then id order, whose start is on the calendar day of now and
    /// after now; a later item's departure time is never shown.
    static func onTimeLines(items: [LobbyItem], now: Date, calendar: Calendar) -> [String] {
        let ordered = items.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        guard let nextIndex = ordered.indices.first(where: {
            startsToday(ordered[$0].start, now: now, calendar: calendar)
                && isUpcoming(start: ordered[$0].start, now: now)
        }) else { return [] }
        let next = ordered[nextIndex]
        var lines: [String] = []
        if let leaveBy = next.leaveBy {
            lines.append("Leave by " + Replan.clockText(leaveBy, timeZone: calendar.timeZone))
        }
        var parts: [String] = []
        let time = Replan.clockText(next.start, timeZone: calendar.timeZone)
        parts.append(next.title.isEmpty ? time : next.title + " " + time)
        if let travelSeconds = next.travelSeconds, let mode = next.mode {
            // The estimate is built for its duration text only; its source field is never shown,
            // so it carries the mode's own raw value instead of a data source the lobby lacks.
            let estimate = TravelEstimate(mode: mode, duration: TimeInterval(travelSeconds), distance: nil,
                                          source: mode.rawValue)
            parts.append(estimate.durationText + " " + travelWord(for: mode))
        }
        let moreToday = ordered.enumerated().filter {
            $0.offset != nextIndex && startsToday($0.element.start, now: now, calendar: calendar)
                && isUpcoming(start: $0.element.start, now: now)
        }.count
        if moreToday >= 1 {
            parts.append("\(moreToday) more today")
        }
        lines.append(parts.joined(separator: " · "))
        return lines
    }

    /// The be full sir lines, one per partner that has an entry starting today, each partner id
    /// taken as an opaque key: the partner line of the picked stay's name and the picked start.
    static func fullLines(stays: [LobbyStay], now: Date, calendar: Calendar) -> [String] {
        let todays = stays.filter { startsToday($0.start, now: now, calendar: calendar) }
        let picks = Dictionary(grouping: todays, by: { $0.partnerID })
            .compactMapValues { pickStay(from: $0, now: now) }
        return picks.sorted {
            if $0.value.start != $1.value.start { return $0.value.start < $1.value.start }
            return $0.key < $1.key
        }.map { _, stay in
            // @MX:NOTE: the marker's only source in the lobby is this call; the word itself is typed nowhere else.
            AgentPartner.partnerLine(stay.partnerName) + " " + Replan.clockText(stay.start, timeZone: calendar.timeZone)
        }
    }

    /// The be rich sir lines: the amount left or over this week, and the last estimate of the
    /// week's entries by their position.
    static func richLines(spentCents: Int, entries: [BudgetEntry]) -> [String] {
        let left = BudgetClient.weeklyBudgetCents - spentCents
        var texts = [AgentBudget.dollars(cents: abs(left)) + (left >= 0 ? " left this week" : " over this week")]
        if let estimate = entries.last(where: { $0.isEstimate }) {
            texts.append("Estimate " + AgentBudget.dollars(cents: estimate.amountCents))
        }
        // @MX:NOTE: the marker's only source in the lobby is this call; the word itself is typed nowhere else.
        return texts.map(AgentPartner.partnerLine)
    }

    /// The one rule of what is still ahead: a start after now.
    // @MX:NOTE: one rule shared by the next-item pick and the per-partner pick; a change must move both.
    static func isUpcoming(start: Date, now: Date) -> Bool {
        start > now
    }

    /// Whether a start falls on the calendar day of now, midnight to midnight in the calendar's zone.
    private static func startsToday(_ start: Date, now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(start, inSameDayAs: now)
    }

    /// The word of the second on-time line for a travel mode.
    private static func travelWord(for mode: TransportMode) -> String {
        switch mode {
        case .car: return "drive"
        case .transit: return "transit"
        case .walk: return "walk"
        case .bicycle: return "ride"
        }
    }

    /// The one stay of a partner's today entries: the earliest start after now, or when none is
    /// ahead the latest start; equal starts go to the smaller entry id. Nil for an empty group.
    private static func pickStay(from group: [LobbyStay], now: Date) -> LobbyStay? {
        let ahead = group.filter { isUpcoming(start: $0.start, now: now) }
        if !ahead.isEmpty {
            return ahead.min { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        }
        return group.min { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
    }

    /// The same rows, read from the app's own store, partner records and budget ledger.
    @MainActor
    static func rows(store: Store, records: PartnerRecords, ledger: BudgetLedger, now: Date,
                     calendar: Calendar) -> [LobbyRow] {
        rows(items: [], stays: [], spentCents: 0, entries: [], now: now, calendar: calendar)
    }
}
