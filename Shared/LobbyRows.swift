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
        RootView.Service.allCases.map { LobbyRow(id: $0.id, title: $0.title, lines: []) }
    }

    /// The be on-time sir lines of the day's items.
    static func onTimeLines(items: [LobbyItem], now: Date, calendar: Calendar) -> [String] {
        []
    }

    /// The be full sir lines, one per partner that has an entry today.
    static func fullLines(stays: [LobbyStay], now: Date, calendar: Calendar) -> [String] {
        []
    }

    /// The be rich sir lines: the amount left or over this week, and the last estimate.
    static func richLines(spentCents: Int, entries: [BudgetEntry]) -> [String] {
        []
    }

    /// The one rule of what is still ahead: a start after now.
    static func isUpcoming(start: Date, now: Date) -> Bool {
        false
    }

    /// The same rows, read from the app's own store, partner records and budget ledger.
    @MainActor
    static func rows(store: Store, records: PartnerRecords, ledger: BudgetLedger, now: Date,
                     calendar: Calendar) -> [LobbyRow] {
        rows(items: [], stays: [], spentCents: 0, entries: [], now: now, calendar: calendar)
    }
}
