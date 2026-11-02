import SwiftUI
import XCTest
@testable import besir

/// SPEC-LOBBYROWS-001 (card t105), plan 4.1: the lobby's key lines, T01 to T15. Every expected
/// text below is a literal spelled by the plan, never built by the code under test.
@MainActor
final class LobbyRowsTests: XCTestCase {

    // MARK: Shared fixtures (plan 4.1 preamble)

    /// The fixtures of T02 to T14: the pure inputs of the builders, and the store-backed setups.
    /// Every test builds its lines from these members and T15 walks the same ones.
    enum LobbyFixtures {
        /// Which row a line belongs to; the raw value is the service id.
        enum RowKind: String { case onTime, full, rich }

        /// The inputs of the three pure builders at one instant.
        struct PureCase {
            var label: String
            var items: [LobbyItem] = []
            var stays: [LobbyStay] = []
            var spentCents: Int = 0
            var entries: [BudgetEntry] = []
            var now: Date = TestClock.now
            var calendar: Calendar = LobbyFixtures.calendar
            /// Every item title the scanner of T15 removes from the on-time lines.
            var itemTitles: [String] { items.map(\.title) }
        }

        /// A store-backed setup of T11 to T14: `rows` rebuilds the store, the records and the
        /// ledger from scratch and calls the adapter at the instant it is given.
        struct StoredCase {
            var label: String
            var itemTitles: [String]
            var now: Date
            var rows: @MainActor (URL, Date) -> [LobbyRow]
        }

        /// The store, the records and the ledger a store-backed fixture reads.
        struct Rig {
            let store: Store
            let records: PartnerRecords
            let ledger: BudgetLedger
            var calendar: Calendar = LobbyFixtures.calendar

            @MainActor
            func rows(now: Date) -> [LobbyRow] {
                LobbyRows.rows(store: store, records: records, ledger: ledger, now: now, calendar: calendar)
            }
        }

        static var calendar: Calendar {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TestClock.zone
            return c
        }

        static func calendar(in zone: TimeZone) -> Calendar {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = zone
            return c
        }

        /// A schedule item of the pure fixtures: title, start and the leg facts it holds.
        static func item(_ title: String, _ start: String, id: String = "i1",
                         leaveBy: String? = nil, travel: Int? = nil, mode: TransportMode? = nil) -> LobbyItem {
            LobbyItem(id: id, title: title, start: TestClock.date(start),
                      leaveBy: leaveBy.map(TestClock.date), travelSeconds: travel, mode: mode)
        }

        /// A stay of the pure fixtures: entry id, partner id and name, and the start.
        static func stay(_ id: String, partner: String, name: String, _ start: String) -> LobbyStay {
            LobbyStay(id: id, start: TestClock.date(start), partnerID: partner, partnerName: name)
        }

        /// A ledger entry of the fixtures, in the test week unless another is named.
        static func entry(_ cents: Int, estimate: Bool, week: String = "2026-10-26") -> BudgetEntry {
            BudgetEntry(requestID: UUID().uuidString, weekStart: week, amountCents: cents, isEstimate: estimate)
        }

        /// A partner record of the fixtures.
        static func record(activityID: UUID, partner: String, name: String, hint: Int?) -> PartnerRecord {
            PartnerRecord(activityID: activityID, partnerID: partner, partnerName: name, route: "/\(partner)",
                          requestID: UUID().uuidString, estimateCents: nil, quantityHint: hint,
                          spendRequestID: nil, switchStarted: false)
        }

        /// The one-item Dinner fixture of T03: 19:00 today, a leave-by and a car leg.
        private static func dinner(leaveBy: String = "2026-10-27T18:35", travel: Int = 1320,
                                   mode: TransportMode = .car) -> LobbyItem {
            item("Dinner", "2026-10-27T19:00", leaveBy: leaveBy, travel: travel, mode: mode)
        }

        private static let destination = Place(name: "Destination", address: "1 Destination St",
                                               latitude: 37.0, longitude: -122.0)

        /// A travel leg of the store fixtures, with the fields the adapter reads set afterwards.
        private static func leg(title: String, arrival: String, departure: String?, travel: Int?,
                                mode: TransportMode, anchor: ScheduleAnchor?) -> ScheduledEvent {
            var event = ScheduledEvent(title: title, origin: nil, destination: destination,
                                       arrivalDate: TestClock.date(arrival), mode: mode,
                                       bufferMinutes: 5, notifyLeadMinutes: 10)
            event.departureDate = departure.map(TestClock.date)
            event.travelSeconds = travel.map { TimeInterval($0) }
            event.anchor = anchor
            return event
        }

        static let tablesTitle = "Example Tables: Booking time (Simulated)"
        static let deliveryTitle = "Example Delivery: Delivery time (Simulated)"
        static let longTitle = "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij"

        // MARK: T02 to T10, the pure fixtures

        static var t02: [PureCase] {
            [
                PureCase(label: "no items"),
                PureCase(label: "an item before now", items: [item("Early", "2026-10-27T08:59")]),
                PureCase(label: "an item at exactly now", items: [item("Now", "2026-10-27T09:00")]),
                PureCase(label: "an item tomorrow", items: [item("Tomorrow", "2026-10-28T00:00")]),
                PureCase(label: "an item yesterday evening", items: [item("Yesterday", "2026-10-26T20:00")]),
                PureCase(label: "the positive control", items: [item("Item", "2026-10-27T10:00")]),
                PureCase(label: "no stays"),
                PureCase(label: "a stay tomorrow",
                         stays: [stay("s1", partner: "p-tables", name: "Example Tables", "2026-10-28T10:00")]),
            ]
        }

        static var t03: [PureCase] {
            [
                PureCase(label: "two more today",
                         items: [dinner(), item("Later one", "2026-10-27T20:00"), item("Later two", "2026-10-27T21:00")]),
                PureCase(label: "one more today",
                         items: [dinner(), item("Later one", "2026-10-27T20:00")]),
                PureCase(label: "no more part", items: [dinner()]),
                PureCase(label: "the car word", items: [dinner(mode: .car)]),
                PureCase(label: "the transit word", items: [dinner(mode: .transit)]),
                PureCase(label: "the walk word", items: [dinner(mode: .walk)]),
                PureCase(label: "the bicycle word", items: [dinner(mode: .bicycle)]),
                PureCase(label: "one hour five", items: [dinner(travel: 3900)]),
                PureCase(label: "exactly one hour", items: [dinner(travel: 3600)]),
                PureCase(label: "rounds down to 22", items: [dinner(travel: 1349)]),
                PureCase(label: "rounds up to 23", items: [dinner(travel: 1350)]),
                PureCase(label: "under half a minute", items: [dinner(travel: 29)]),
                PureCase(label: "just after midnight", items: [dinner(leaveBy: "2026-10-27T00:05")]),
                PureCase(label: "noon", items: [dinner(leaveBy: "2026-10-27T12:00")]),
                PureCase(label: "early afternoon", items: [dinner(leaveBy: "2026-10-27T13:07")]),
                PureCase(label: "already passed", items: [dinner(leaveBy: "2026-10-27T08:10")]),
                PureCase(label: "a New York calendar",
                         items: [dinner()],
                         calendar: calendar(in: TimeZone(identifier: "America/New_York")!)),
                PureCase(label: "a Tokyo calendar",
                         items: [dinner()],
                         calendar: calendar(in: TimeZone(identifier: "Asia/Tokyo")!)),
            ]
        }

        static var t04: [PureCase] {
            [
                PureCase(label: "no departure and no travel time", items: [item("Dinner", "2026-10-27T19:00")]),
                PureCase(label: "no leg at all, one more today",
                         items: [item("Dinner", "2026-10-27T19:00"), item("Second", "2026-10-27T20:00")]),
                PureCase(label: "a departure but no travel time",
                         items: [item("Dinner", "2026-10-27T19:00", leaveBy: "2026-10-27T18:35")]),
                PureCase(label: "a travel time but no departure",
                         items: [item("Dinner", "2026-10-27T19:00", travel: 1320, mode: .car)]),
                PureCase(label: "a blank title", items: [item("", "2026-10-27T19:00")]),
                PureCase(label: "a partner entry title", items: [item(tablesTitle, "2026-10-27T19:00")]),
                PureCase(label: "eighty characters", items: [item(longTitle, "2026-10-27T19:00")]),
            ]
        }

        static var t05: [PureCase] {
            [
                PureCase(label: "given out of order",
                         items: [item("Late morning", "2026-10-27T12:00"), item("Next", "2026-10-27T10:00"),
                                 item("Evening", "2026-10-27T18:30")]),
                PureCase(label: "the same start, ids a and b",
                         items: [item("A", "2026-10-27T10:00", id: "a"), item("B", "2026-10-27T10:00", id: "b")]),
                PureCase(label: "the same start and a later one",
                         items: [item("A", "2026-10-27T10:00", id: "a"), item("B", "2026-10-27T10:00", id: "b"),
                                 item("C", "2026-10-27T11:00", id: "c")]),
                PureCase(label: "the last minute of today counts",
                         items: [item("A", "2026-10-27T10:00", id: "a"), item("Late night", "2026-10-27T23:59")]),
                PureCase(label: "the first minute of tomorrow does not",
                         items: [item("A", "2026-10-27T10:00", id: "a"), item("Tomorrow", "2026-10-28T00:00")]),
                PureCase(label: "a started item is neither next nor counted",
                         items: [item("Started", "2026-10-27T08:00"), item("A", "2026-10-27T10:00", id: "a")]),
                PureCase(label: "only the next item's departure time shows",
                         items: [item("Gym", "2026-10-27T18:00"),
                                 item("Dinner", "2026-10-27T18:20", leaveBy: "2026-10-27T17:50")]),
            ]
        }

        static var t06: [PureCase] {
            [
                PureCase(label: "the table partner",
                         stays: [stay("s1", partner: "p-tables", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "the delivery partner",
                         stays: [stay("s1", partner: "p-delivery", name: "Example Delivery", "2026-10-27T12:40")]),
                PureCase(label: "a partner the app has never heard of",
                         stays: [stay("s1", partner: "p-cars", name: "Acme Cars", "2026-10-27T09:05")]),
                PureCase(label: "an id the directory uses",
                         stays: [stay("s1", partner: "booking", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "five past midnight, already past",
                         stays: [stay("s1", partner: "p-tables", name: "Example Tables", "2026-10-27T00:05")]),
            ]
        }

        static var t07: [PureCase] {
            [
                PureCase(label: "two entries, the earliest upcoming wins",
                         stays: [stay("e1", partner: "p-tables", name: "Example Tables", "2026-10-27T11:00"),
                                 stay("e2", partner: "p-tables", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "two past entries, the latest wins",
                         stays: [stay("e1", partner: "p-tables", name: "Example Tables", "2026-10-27T07:00"),
                                 stay("e2", partner: "p-tables", name: "Example Tables", "2026-10-27T08:00")]),
                PureCase(label: "a past and an upcoming entry",
                         stays: [stay("e1", partner: "p-tables", name: "Example Tables", "2026-10-27T07:00"),
                                 stay("e2", partner: "p-tables", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "one at exactly now and a later one",
                         stays: [stay("e1", partner: "p-tables", name: "Example Tables", "2026-10-27T09:00"),
                                 stay("e2", partner: "p-tables", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "one entry at exactly now",
                         stays: [stay("e1", partner: "p-tables", name: "Example Tables", "2026-10-27T09:00")]),
                PureCase(label: "several partners",
                         stays: [stay("e1", partner: "a-id", name: "Example Tables", "2026-10-27T19:00"),
                                 stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T12:40")]),
                PureCase(label: "equal starts, ordered by partner id",
                         stays: [stay("e1", partner: "a-id", name: "Example Tables", "2026-10-27T19:00"),
                                 stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T19:00")]),
                PureCase(label: "equal starts, the other input order",
                         stays: [stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T19:00"),
                                 stay("e1", partner: "a-id", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "three partners, capped at two",
                         stays: [stay("e1", partner: "c-id", name: "Acme Cars", "2026-10-27T09:05"),
                                 stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T12:40"),
                                 stay("e3", partner: "a-id", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "three partners, the other input order",
                         stays: [stay("e3", partner: "a-id", name: "Example Tables", "2026-10-27T19:00"),
                                 stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T12:40"),
                                 stay("e1", partner: "c-id", name: "Acme Cars", "2026-10-27T09:05")]),
                PureCase(label: "an entry tie, upcoming",
                         stays: [stay("a", partner: "a-id", name: "Alpha", "2026-10-27T19:00"),
                                 stay("b", partner: "a-id", name: "Beta", "2026-10-27T19:00")]),
                PureCase(label: "an entry tie, upcoming, the other input order",
                         stays: [stay("b", partner: "a-id", name: "Beta", "2026-10-27T19:00"),
                                 stay("a", partner: "a-id", name: "Alpha", "2026-10-27T19:00")]),
                PureCase(label: "an entry tie, past",
                         stays: [stay("a", partner: "a-id", name: "Alpha", "2026-10-27T08:00"),
                                 stay("b", partner: "a-id", name: "Beta", "2026-10-27T08:00")]),
                PureCase(label: "an entry tie, past, the other input order",
                         stays: [stay("b", partner: "a-id", name: "Beta", "2026-10-27T08:00"),
                                 stay("a", partner: "a-id", name: "Alpha", "2026-10-27T08:00")]),
            ]
        }

        static var t08: [PureCase] {
            [
                PureCase(label: "a stay still overlapping today",
                         stays: [stay("s1", partner: "p-tables", name: "Example Tables", "2026-10-26T22:00")]),
                PureCase(label: "a stay tomorrow",
                         stays: [stay("s1", partner: "p-tables", name: "Example Tables", "2026-10-28T00:00")]),
                PureCase(label: "the positive control",
                         stays: [stay("s1", partner: "p-tables", name: "Example Tables", "2026-10-27T19:00")]),
            ]
        }

        static var t09: [PureCase] {
            [
                PureCase(label: "nothing spent", spentCents: 0, entries: []),
                PureCase(label: "one stated spend", spentCents: 5000, entries: [entry(5000, estimate: false)]),
                PureCase(label: "the last estimate by position", spentCents: 14400,
                         entries: [entry(8600, estimate: true), entry(1800, estimate: false), entry(4000, estimate: true)]),
                PureCase(label: "exactly at the budget", spentCents: 20000, entries: [entry(20000, estimate: false)]),
                PureCase(label: "over the budget", spentCents: 25000, entries: [entry(25000, estimate: false)]),
                PureCase(label: "over with an estimate", spentCents: 30000, entries: [entry(30000, estimate: true)]),
                PureCase(label: "one cent", spentCents: 1, entries: [entry(1, estimate: false)]),
                PureCase(label: "with a thousands separator", spentCents: 143450, entries: [entry(143450, estimate: false)]),
                PureCase(label: "an estimate alone", spentCents: 8600, entries: [entry(8600, estimate: true)]),
            ]
        }

        static var t10: [PureCase] {
            [
                PureCase(label: "spent 0", spentCents: 0),
                PureCase(label: "spent 5000", spentCents: 5000),
                PureCase(label: "spent 20000", spentCents: 20000),
                PureCase(label: "spent 25000", spentCents: 25000),
            ]
        }

        /// The two-line cap of the be full sir row (SPEC-LOBBYROWS-002 REQ-LOBBYROWS2-004), nine cases.
        static var t17: [PureCase] {
            [
                PureCase(label: "three partners, capped at two",
                         stays: [stay("e1", partner: "c-id", name: "Acme Cars", "2026-10-27T09:05"),
                                 stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T12:40"),
                                 stay("e3", partner: "a-id", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "three partners, the other input order",
                         stays: [stay("e3", partner: "a-id", name: "Example Tables", "2026-10-27T19:00"),
                                 stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T12:40"),
                                 stay("e1", partner: "c-id", name: "Acme Cars", "2026-10-27T09:05")]),
                PureCase(label: "exactly two partners",
                         stays: [stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T12:40"),
                                 stay("e3", partner: "a-id", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "one partner",
                         stays: [stay("e3", partner: "a-id", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "three at one start, partner ids decide",
                         stays: [stay("e2", partner: "c-id", name: "Beta", "2026-10-27T19:00"),
                                 stay("e1", partner: "b-id", name: "Alpha", "2026-10-27T19:00"),
                                 stay("e3", partner: "a-id", name: "Gamma", "2026-10-27T19:00")]),
                PureCase(label: "the pick comes before the cap",
                         stays: [stay("e1", partner: "c-id", name: "Acme Cars", "2026-10-27T07:00"),
                                 stay("e4", partner: "c-id", name: "Acme Cars", "2026-10-27T20:00"),
                                 stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T12:40"),
                                 stay("e3", partner: "a-id", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "a passed pick sorts first",
                         stays: [stay("e5", partner: "d-id", name: "Delta", "2026-10-27T08:00"),
                                 stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T12:40"),
                                 stay("e3", partner: "a-id", name: "Example Tables", "2026-10-27T19:00")]),
                PureCase(label: "four partners",
                         stays: [stay("e4", partner: "d-id", name: "Delta", "2026-10-27T13:00"),
                                 stay("e3", partner: "c-id", name: "Gamma", "2026-10-27T12:00"),
                                 stay("e2", partner: "b-id", name: "Beta", "2026-10-27T11:00"),
                                 stay("e1", partner: "a-id", name: "Alpha", "2026-10-27T10:00")]),
                PureCase(label: "a partner tomorrow does not take a slot",
                         stays: [stay("e2", partner: "b-id", name: "Example Delivery", "2026-10-27T12:40"),
                                 stay("e3", partner: "a-id", name: "Example Tables", "2026-10-27T19:00"),
                                 stay("e6", partner: "c-id", name: "Acme Cars", "2026-10-28T09:00")]),
            ]
        }

        static var pureCases: [PureCase] {
            t02 + t03 + t04 + t05 + t06 + t07 + t08 + t09 + t10 + t17
        }

        // MARK: T11 to T14, the store-backed fixtures

        @MainActor
        static func t11Rig(folder: URL) -> Rig {
            let store = EmptyStore.make()
            store.activities = [
                ActivityBlock(title: "Late", location: nil,
                              startDate: TestClock.date("2026-10-28T00:00:30"), endDate: TestClock.date("2026-10-28T00:30")),
                ActivityBlock(title: "Late", location: nil,
                              startDate: TestClock.date("2026-11-01T23:30"), endDate: TestClock.date("2026-11-01T23:45")),
                ActivityBlock(title: "Day after", location: nil,
                              startDate: TestClock.date("2026-11-02T00:00"), endDate: TestClock.date("2026-11-02T00:30")),
            ]
            let ledger = BudgetLedger(fileURL: folder.appendingPathComponent(BudgetLedger.fileName))
            ledger.add(entry(3000, estimate: false))
            ledger.add(entry(5000, estimate: true, week: "2026-11-02"))
            return Rig(store: store,
                       records: PartnerRecords(fileURL: folder.appendingPathComponent(PartnerRecords.fileName)),
                       ledger: ledger)
        }

        @MainActor
        static func t12Rig(folder: URL) -> Rig {
            let store = EmptyStore.make()
            let dinner = ActivityBlock(title: "Dinner", location: nil,
                                       startDate: TestClock.date("2026-10-27T19:00"), endDate: TestClock.date("2026-10-27T20:00"))
            let gym = ActivityBlock(title: "Gym", location: nil,
                                    startDate: TestClock.date("2026-10-27T17:00"), endDate: TestClock.date("2026-10-27T18:00"))
            store.activities = [dinner, gym]
            var outbound = leg(title: "Dinner travel", arrival: "2026-10-27T19:00", departure: "2026-10-27T18:35",
                               travel: 1320, mode: .car, anchor: .arrival)
            outbound.linkedActivityId = dinner.id
            var returnLeg = leg(title: "Dinner return", arrival: "2026-10-27T20:40", departure: "2026-10-27T20:10",
                                travel: 1800, mode: .car, anchor: .departure)
            returnLeg.linkedActivityId = dinner.id
            let standup = RepeatSeries(id: RepeatSeries.newID(), title: "Standup", location: nil,
                                       rule: RecurrenceRule(weekdays: [3], unit: .weekly), lunarCalendar: nil,
                                       firstDayKey: 20261020, lastDayKey: nil, startMinute: 600, endMinute: 630,
                                       endDayDistance: 0, syncToCalendar: nil, skippedDayKeys: [],
                                       legPlan: nil, legsFilledThroughDayKey: nil)
            let review = RepeatSeries(id: RepeatSeries.newID(), title: "Review", location: nil,
                                       rule: RecurrenceRule(weekdays: [3], unit: .weekly), lunarCalendar: nil,
                                       firstDayKey: 20261020, lastDayKey: nil, startMinute: 780, endMinute: 810,
                                       endDayDistance: 0, syncToCalendar: nil, skippedDayKeys: [],
                                       legPlan: nil, legsFilledThroughDayKey: nil)
            var reviewLeg = leg(title: "Review travel", arrival: "2026-10-27T13:00", departure: "2026-10-27T12:30",
                                travel: 1800, mode: .walk, anchor: .arrival)
            reviewLeg.linkedActivityId = review.occurrenceID(dayKey: 20261027)
            store.events = [outbound, returnLeg, reviewLeg]
            store.addSeries(standup)
            store.addSeries(review)
            return Rig(store: store,
                       records: PartnerRecords(fileURL: folder.appendingPathComponent(PartnerRecords.fileName)),
                       ledger: BudgetLedger(fileURL: folder.appendingPathComponent(BudgetLedger.fileName)))
        }

        @MainActor
        static func t13Rig(folder: URL) -> Rig {
            let store = EmptyStore.make()
            let dinner = ActivityBlock(title: "Dinner", location: nil,
                                       startDate: TestClock.date("2026-10-27T19:00"), endDate: TestClock.date("2026-10-27T20:00"))
            store.activities = [dinner]
            var outbound = leg(title: "Dinner travel", arrival: "2026-10-27T19:00", departure: "2026-10-27T18:35",
                               travel: 1320, mode: .car, anchor: .arrival)
            outbound.linkedActivityId = dinner.id
            var returnLeg = leg(title: "Dinner return", arrival: "2026-10-27T20:40", departure: "2026-10-27T20:10",
                                travel: 1800, mode: .car, anchor: .departure)
            returnLeg.linkedActivityId = dinner.id
            let airport = leg(title: "Airport", arrival: "2026-10-27T15:30", departure: "2026-10-27T14:50",
                              travel: 2400, mode: .transit, anchor: .arrival)
            var old = leg(title: "Old", arrival: "2026-10-27T16:00", departure: nil, travel: nil, mode: .car, anchor: nil)
            old.linkedActivityId = UUID()
            let homeRun = leg(title: "Home run", arrival: "2026-10-27T18:50", departure: "2026-10-27T18:20",
                              travel: 1800, mode: .car, anchor: .departure)
            let back = leg(title: "Back", arrival: "2026-10-27T21:00", departure: nil, travel: nil, mode: .car,
                           anchor: .departure)
            let nightDrive = leg(title: "Night drive", arrival: "2026-10-28T00:30", departure: "2026-10-27T23:50",
                                 travel: 2400, mode: .car, anchor: .departure)
            let lateFlight = leg(title: "Late flight", arrival: "2026-10-28T00:20", departure: "2026-10-27T23:40",
                                 travel: 2400, mode: .car, anchor: .arrival)
            store.events = [outbound, returnLeg, airport, old, homeRun, back, nightDrive, lateFlight]
            return Rig(store: store,
                       records: PartnerRecords(fileURL: folder.appendingPathComponent(PartnerRecords.fileName)),
                       ledger: BudgetLedger(fileURL: folder.appendingPathComponent(BudgetLedger.fileName)))
        }

        @MainActor
        static func t14Rig(folder: URL) -> Rig {
            let store = EmptyStore.make()
            let tables = ActivityBlock(title: tablesTitle, location: nil,
                                       startDate: TestClock.date("2026-10-27T19:00"), endDate: TestClock.date("2026-10-27T20:00"))
            let delivery = ActivityBlock(title: deliveryTitle, location: nil,
                                         startDate: TestClock.date("2026-10-27T12:40"), endDate: TestClock.date("2026-10-27T13:40"))
            store.activities = [tables, delivery]
            let records = PartnerRecords(fileURL: folder.appendingPathComponent(PartnerRecords.fileName))
            records.add(record(activityID: tables.id, partner: "booking", name: "Example Tables", hint: 2))
            records.add(record(activityID: delivery.id, partner: "delivery", name: "Example Delivery", hint: nil))
            return Rig(store: store, records: records,
                       ledger: BudgetLedger(fileURL: folder.appendingPathComponent(BudgetLedger.fileName)))
        }

        static var t11: StoredCase {
            StoredCase(label: "T11 the day and week edges", itemTitles: ["Late", "Day after"], now: TestClock.now) { folder, now in
                t11Rig(folder: folder).rows(now: now)
            }
        }

        static var t12: StoredCase {
            StoredCase(label: "T12 the store's items", itemTitles: ["Dinner", "Gym", "Standup", "Review"],
                       now: TestClock.now) { folder, now in
                t12Rig(folder: folder).rows(now: now)
            }
        }

        static var t13: StoredCase {
            StoredCase(label: "T13 travel events without an activity",
                       itemTitles: ["Dinner", "Airport", "Old", "Home run", "Back", "Night drive", "Late flight"],
                       now: TestClock.now) { folder, now in
                t13Rig(folder: folder).rows(now: now)
            }
        }

        static var t14: StoredCase {
            StoredCase(label: "T14 the records and the ledger", itemTitles: [tablesTitle, deliveryTitle],
                       now: TestClock.now) { folder, now in
                t14Rig(folder: folder).rows(now: now)
            }
        }

        static var storedCases: [StoredCase] { [t11, t12, t13, t14] }
    }

    // MARK: Helpers

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lobby-rows-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func build(_ c: LobbyFixtures.PureCase) -> [LobbyRow] {
        LobbyRows.rows(items: c.items, stays: c.stays, spentCents: c.spentCents, entries: c.entries,
                       now: c.now, calendar: c.calendar)
    }

    private func lines(_ rows: [LobbyRow], _ service: RootView.Service) -> [String] {
        rows.first { $0.id == service.id }?.lines ?? []
    }

    private func onTimeLines(_ rows: [LobbyRow]) -> [String] { lines(rows, .onTime) }
    private func fullLines(_ rows: [LobbyRow]) -> [String] { lines(rows, .full) }
    private func richLines(_ rows: [LobbyRow]) -> [String] { lines(rows, .rich) }

    // MARK: T01 to T10, the pure builders

    func testLOBBYROWS_T01_TheLobbyHasOneRowPerFeatureInServiceOrderWithUniqueIds() {
        let rows = LobbyRows.rows(items: [], stays: [], spentCents: 0, entries: [],
                                  now: TestClock.now, calendar: LobbyFixtures.calendar)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.id), RootView.Service.allCases.map(\.id))
        XCTAssertEqual(rows.map(\.title), ["be on-time sir", "be full sir", "be rich sir"])
        XCTAssertEqual(rows.map(\.title), RootView.Service.allCases.map(\.title))
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "the ids are unique")
        XCTAssertEqual(onTimeLines(rows), ["No plans today"])
        XCTAssertEqual(fullLines(rows), ["No orders today"])
        XCTAssertEqual(richLines(rows), ["$200.00 left this week - Simulated"])
    }

    func testLOBBYROWS_T02_AFeatureWithNothingToSayShowsItsPlaceholderAndItsBuilderGivesNoLines() {
        let cases = LobbyFixtures.t02
        XCTAssertEqual(cases.count, 8)
        for c in cases[0...4] {
            XCTAssertEqual(onTimeLines(build(c)), ["No plans today"], c.label)
            XCTAssertEqual(LobbyRows.onTimeLines(items: c.items, now: c.now, calendar: c.calendar), [],
                           "the builder itself still gives no line: \(c.label)")
        }
        XCTAssertEqual(onTimeLines(build(cases[5])), ["Item 10:00 AM"], "the positive control keeps the row honest")
        XCTAssertEqual(fullLines(build(cases[6])), ["No orders today"], cases[6].label)
        XCTAssertEqual(fullLines(build(cases[7])), ["No orders today"], cases[7].label)
        for c in cases[6...7] {
            XCTAssertEqual(LobbyRows.fullLines(stays: c.stays, now: c.now, calendar: c.calendar), [],
                           "the builder itself still gives no line: \(c.label)")
        }
        XCTAssertTrue(build(cases[5]).flatMap(\.lines).allSatisfy { !$0.isEmpty },
                      "no empty string on any row")
    }

    func testLOBBYROWS_T03_OnTimeLinesCarryLeaveByThenTitleTimeTravelAndMoreToday() {
        let expected: [[String]] = [
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 22 min drive · 2\u{00A0}more today"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 22 min drive · 1\u{00A0}more today"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 22 min drive"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 22 min drive"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 22 min transit"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 22 min walk"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 22 min ride"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 1 hr 5 min drive"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 1 hr 0 min drive"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 22 min drive"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 23 min drive"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM · 0 min drive"],
            ["Leave by 12:05 AM", "Dinner 7:00 PM · 22 min drive"],
            ["Leave by 12:00 PM", "Dinner 7:00 PM · 22 min drive"],
            ["Leave by 1:07 PM", "Dinner 7:00 PM · 22 min drive"],
            ["Leave by 8:10 AM", "Dinner 7:00 PM · 22 min drive"],
            ["Leave by 9:35 PM", "Dinner 10:00 PM · 22 min drive"],
            ["Leave by 10:35 AM", "Dinner 11:00 AM · 22 min drive"],
        ]
        XCTAssertEqual(LobbyFixtures.t03.count, expected.count)
        for (c, want) in zip(LobbyFixtures.t03, expected) {
            XCTAssertEqual(LobbyRows.onTimeLines(items: c.items, now: c.now, calendar: c.calendar), want, c.label)
        }
    }

    func testLOBBYROWS_T04_OnTimeLinesLeaveOutWhatTheRecordDoesNotHold() {
        let expected: [[String]] = [
            ["Dinner 7:00 PM"],
            ["Dinner 7:00 PM · 1\u{00A0}more today"],
            ["Leave by 6:35 PM", "Dinner 7:00 PM"],
            ["Dinner 7:00 PM · 22 min drive"],
            ["7:00 PM"],
            ["Example Tables: Booking time (Simulated) 7:00 PM"],
            [LobbyFixtures.longTitle + " 7:00 PM"],
        ]
        XCTAssertEqual(LobbyFixtures.t04.count, expected.count)
        XCTAssertEqual(LobbyFixtures.longTitle.count, 80)
        for (c, want) in zip(LobbyFixtures.t04, expected) {
            XCTAssertEqual(LobbyRows.onTimeLines(items: c.items, now: c.now, calendar: c.calendar), want, c.label)
        }
    }

    func testLOBBYROWS_T05_TheNextItemIsTheFirstStartAfterNowAndMoreTodayCountsEveryOtherLaterOneOfToday() {
        let expected: [[String]] = [
            ["Next 10:00 AM · 2\u{00A0}more today"],
            ["A 10:00 AM · 1\u{00A0}more today"],
            ["A 10:00 AM · 2\u{00A0}more today"],
            ["A 10:00 AM · 1\u{00A0}more today"],
            ["A 10:00 AM"],
            ["A 10:00 AM"],
            ["Gym 6:00 PM · 1\u{00A0}more today"],
        ]
        XCTAssertEqual(LobbyFixtures.t05.count, expected.count)
        for (c, want) in zip(LobbyFixtures.t05, expected) {
            XCTAssertEqual(LobbyRows.onTimeLines(items: c.items, now: c.now, calendar: c.calendar), want, c.label)
        }
        XCTAssertTrue(LobbyRows.isUpcoming(start: TestClock.date("2026-10-27T09:00:01"), now: TestClock.now))
        XCTAssertFalse(LobbyRows.isUpcoming(start: TestClock.date("2026-10-27T09:00:00"), now: TestClock.now))
        XCTAssertFalse(LobbyRows.isUpcoming(start: TestClock.date("2026-10-27T08:59:59"), now: TestClock.now))
    }

    func testLOBBYROWS_T06_TheFullLineIsThePartnerLineAndTheTimeForAnyPartner() {
        let expected: [[String]] = [
            ["Example Tables - Simulated 7:00 PM"],
            ["Example Delivery - Simulated 12:40 PM"],
            ["Acme Cars - Simulated 9:05 AM"],
            ["Example Tables - Simulated 7:00 PM"],
            ["Example Tables - Simulated 12:05 AM"],
        ]
        XCTAssertEqual(LobbyFixtures.t06.count, expected.count)
        for (c, want) in zip(LobbyFixtures.t06, expected) {
            let lines = LobbyRows.fullLines(stays: c.stays, now: c.now, calendar: c.calendar)
            XCTAssertEqual(lines, want, c.label)
            XCTAssertEqual((lines.first ?? "").components(separatedBy: "Simulated").count - 1, 1,
                           "the line holds the marker once: \(c.label)")
        }
    }

    func testLOBBYROWS_T07_EachPartnerGivesOneLineByTheSamePickAndTheLinesAreOrdered() {
        let expected: [[String]] = [
            ["Example Tables - Simulated 11:00 AM"],
            ["Example Tables - Simulated 8:00 AM"],
            ["Example Tables - Simulated 7:00 PM"],
            ["Example Tables - Simulated 7:00 PM"],
            ["Example Tables - Simulated 9:00 AM"],
            ["Example Delivery - Simulated 12:40 PM", "Example Tables - Simulated 7:00 PM"],
            ["Example Tables - Simulated 7:00 PM", "Example Delivery - Simulated 7:00 PM"],
            ["Example Tables - Simulated 7:00 PM", "Example Delivery - Simulated 7:00 PM"],
            ["Acme Cars - Simulated 9:05 AM", "Example Delivery - Simulated 12:40 PM"],
            ["Acme Cars - Simulated 9:05 AM", "Example Delivery - Simulated 12:40 PM"],
            ["Alpha - Simulated 7:00 PM"],
            ["Alpha - Simulated 7:00 PM"],
            ["Alpha - Simulated 8:00 AM"],
            ["Alpha - Simulated 8:00 AM"],
        ]
        XCTAssertEqual(LobbyFixtures.t07.count, expected.count)
        for (c, want) in zip(LobbyFixtures.t07, expected) {
            XCTAssertEqual(LobbyRows.fullLines(stays: c.stays, now: c.now, calendar: c.calendar), want, c.label)
        }
    }

    func testLOBBYROWS_T08_TheFullLinesIgnoreStaysNotStartingToday() {
        let expected: [[String]] = [[], [], ["Example Tables - Simulated 7:00 PM"]]
        XCTAssertEqual(LobbyFixtures.t08.count, expected.count)
        for (c, want) in zip(LobbyFixtures.t08, expected) {
            XCTAssertEqual(LobbyRows.fullLines(stays: c.stays, now: c.now, calendar: c.calendar), want, c.label)
        }
    }

    func testLOBBYROWS_T09_TheRichLinesReadLeftOrOverAndTheLastEstimateOfTheWeekEachWithTheSimulatedMarker() {
        let expected: [[String]] = [
            ["$200.00 left this week - Simulated"],
            ["$150.00 left this week - Simulated"],
            ["$56.00 left this week - Simulated", "Estimate $40.00 - Simulated"],
            ["$0.00 left this week - Simulated"],
            ["$50.00 over this week - Simulated"],
            ["$100.00 over this week - Simulated", "Estimate $300.00 - Simulated"],
            ["$199.99 left this week - Simulated"],
            ["$1,234.50 over this week - Simulated"],
            ["$114.00 left this week - Simulated", "Estimate $86.00 - Simulated"],
        ]
        XCTAssertEqual(LobbyFixtures.t09.count, expected.count)
        for (c, want) in zip(LobbyFixtures.t09, expected) {
            XCTAssertEqual(LobbyRows.richLines(spentCents: c.spentCents, entries: c.entries), want, c.label)
        }
    }

    func testLOBBYROWS_T10_TheRichFigureEqualsTheLeftAmountTheBudgetAnswerIsCheckedAgainst() throws {
        for c in LobbyFixtures.t10 {
            let sent = BudgetClient.Sent(operation: .left, weekStart: "2026-10-26",
                                         spentCents: c.spentCents, amountCents: nil)
            let left = BudgetClient.weeklyBudgetCents - c.spentCents
            let answer: [String: Any] = ["partner": BudgetClient.partnerName, "simulated": true, "op": "left",
                                         "week_start": "2026-10-26", "spent_cents": c.spentCents,
                                         "budget_cents": BudgetClient.weeklyBudgetCents, "left_cents": left,
                                         "status": left >= 0 ? "within" : "over"]
            let data = try JSONSerialization.data(withJSONObject: answer)
            let standing = try XCTUnwrap(BudgetClient.answer(from: data, sent: sent), c.label)
            let text = AgentBudget.dollars(cents: abs(standing.leftCents))
                + (standing.isWithin ? " left this week" : " over this week")
            XCTAssertEqual(LobbyRows.richLines(spentCents: c.spentCents, entries: c.entries).first,
                           AgentPartner.partnerLine(text), c.label)
        }
        let off: [String: Any] = ["partner": BudgetClient.partnerName, "simulated": true, "op": "left",
                                  "week_start": "2026-10-26", "spent_cents": 0,
                                  "budget_cents": BudgetClient.weeklyBudgetCents, "left_cents": 19999,
                                  "status": "within"]
        let sent = BudgetClient.Sent(operation: .left, weekStart: "2026-10-26", spentCents: 0, amountCents: nil)
        XCTAssertNil(BudgetClient.answer(from: try JSONSerialization.data(withJSONObject: off), sent: sent),
                     "an answer one cent off is not accepted, so the figure cannot differ from it")
    }

    // MARK: T11 to T14, the store-backed rows

    func testLOBBYROWS_T11_MidnightWeekAndClockChangeEdgesInLosAngeles() {
        let rig = LobbyFixtures.t11Rig(folder: folder())
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T23:59:59"))), ["No plans today"],
                       "an item at the next day's first half minute is not today's")
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-28T00:00:00"))), ["Late 12:00 AM"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-11-01T22:00"))), ["Late 11:30 PM"],
                       "the 25-hour day keeps tomorrow's midnight item out of the count")
        XCTAssertEqual(richLines(rig.rows(now: TestClock.date("2026-11-01T23:59:59"))),
                       ["$170.00 left this week - Simulated"])
        XCTAssertEqual(richLines(rig.rows(now: TestClock.date("2026-11-02T00:00:00"))),
                       ["$150.00 left this week - Simulated", "Estimate $50.00 - Simulated"])
        XCTAssertEqual(richLines(rig.rows(now: TestClock.date("2026-10-25T23:59:59"))),
                       ["$200.00 left this week - Simulated"])
        for now in [TestClock.date("2026-11-01T22:00"), TestClock.date("2026-11-01T23:59:59"),
                    TestClock.date("2026-11-02T00:00:00"), TestClock.date("2026-10-25T23:59:59")] {
            let week = BudgetWeek.start(of: now, in: TestClock.zone)
            let left = BudgetClient.weeklyBudgetCents - rig.ledger.spentCents(weekStart: week)
            XCTAssertEqual(richLines(rig.rows(now: now)).first,
                           AgentPartner.partnerLine(AgentBudget.dollars(cents: abs(left))
                                                    + (left >= 0 ? " left this week" : " over this week")),
                           "the week the adapter used is \(week)")
        }
    }

    func testLOBBYROWS_T12_TheOnTimeItemsComeFromTheStoreIncludingRepeatsAndTheirStoredLegs() throws {
        let rig = LobbyFixtures.t12Rig(folder: folder())
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T09:00"))),
                       ["Standup 10:00 AM · 3\u{00A0}more today"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T10:30"))),
                       ["Leave by 12:30 PM", "Review 1:00 PM · 30 min walk · 2\u{00A0}more today"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T13:30"))), ["Gym 5:00 PM · 1\u{00A0}more today"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T17:30"))),
                       ["Leave by 6:35 PM", "Dinner 7:00 PM · 22 min drive"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T19:30"))), ["No plans today"],
                       "the owned return leg is not an item")

        let dinner = try XCTUnwrap(rig.store.activities.first { $0.title == "Dinner" })
        for i in rig.store.events.indices where rig.store.events[i].linkedActivityId == dinner.id && rig.store.events[i].anchor == .arrival {
            rig.store.events[i].departureDate = TestClock.date("2026-10-27T18:25")
            rig.store.events[i].travelSeconds = 1800
        }
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T17:30"))),
                       ["Leave by 6:25 PM", "Dinner 7:00 PM · 30 min drive"],
                       "the rows read the store again, not a copy")
    }

    func testLOBBYROWS_T13_TravelEventsWithoutAnActivityAreItemsByTheirAnchorTime() {
        let rig = LobbyFixtures.t13Rig(folder: folder())
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T13:30"))),
                       ["Leave by 2:50 PM", "Airport 3:30 PM · 40 min transit · 5\u{00A0}more today"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T15:45"))), ["Old 4:00 PM · 4\u{00A0}more today"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T17:30"))),
                       ["Leave by 6:20 PM", "Home run 6:20 PM · 30 min drive · 3\u{00A0}more today"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T18:45"))),
                       ["Leave by 6:35 PM", "Dinner 7:00 PM · 22 min drive · 2\u{00A0}more today"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T19:30"))), ["Back 9:00 PM · 1\u{00A0}more today"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T22:00"))),
                       ["Leave by 11:50 PM", "Night drive 11:50 PM · 40 min drive"])
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T23:55"))), ["No plans today"])

        for i in rig.store.events.indices where rig.store.events[i].title == "Airport" {
            rig.store.events[i].departureDate = TestClock.date("2026-10-27T14:40")
            rig.store.events[i].travelSeconds = 3000
        }
        XCTAssertEqual(onTimeLines(rig.rows(now: TestClock.date("2026-10-27T13:30"))),
                       ["Leave by 2:40 PM", "Airport 3:30 PM · 50 min transit · 5\u{00A0}more today"],
                       "the rows read the store again, not a copy")
    }

    func testLOBBYROWS_T14_TheFullAndRichRowsReadTheRecordsAndTheLedgerTheAppKeeps() throws {
        let rig = LobbyFixtures.t14Rig(folder: folder())
        let tables = try XCTUnwrap(rig.store.activities.first { $0.title == LobbyFixtures.tablesTitle })
        let delivery = try XCTUnwrap(rig.store.activities.first { $0.title == LobbyFixtures.deliveryTitle })
        let both = ["Example Delivery - Simulated 12:40 PM", "Example Tables - Simulated 7:00 PM"]
        XCTAssertEqual(fullLines(rig.rows(now: TestClock.now)), both)
        XCTAssertTrue(rig.records.add(LobbyFixtures.record(activityID: UUID(), partner: "p-orphan",
                                                           name: "Example Orphan", hint: nil)))
        XCTAssertEqual(fullLines(rig.rows(now: TestClock.now)), both, "an orphan record whose entry is gone shows nothing")
        rig.store.activities.append(ActivityBlock(title: LobbyFixtures.tablesTitle, location: nil,
                                                  startDate: TestClock.date("2026-10-27T18:00"),
                                                  endDate: TestClock.date("2026-10-27T19:00")))
        XCTAssertEqual(fullLines(rig.rows(now: TestClock.now)), both, "an entry without a record is not a line")
        rig.store.activities.removeAll { $0.id == tables.id }
        XCTAssertEqual(fullLines(rig.rows(now: TestClock.now)), ["Example Delivery - Simulated 12:40 PM"])
        XCTAssertTrue(rig.records.remove(activityID: delivery.id))
        XCTAssertEqual(fullLines(rig.rows(now: TestClock.now)), ["No orders today"])

        let stated = LobbyFixtures.entry(1800, estimate: false)
        let earlyEstimate = LobbyFixtures.entry(8600, estimate: true)
        XCTAssertTrue(rig.ledger.add(stated))
        XCTAssertTrue(rig.ledger.add(earlyEstimate))
        XCTAssertEqual(richLines(rig.rows(now: TestClock.now)),
                       ["$96.00 left this week - Simulated", "Estimate $86.00 - Simulated"])
        let laterEstimate = LobbyFixtures.entry(3000, estimate: true)
        XCTAssertTrue(rig.ledger.add(laterEstimate))
        XCTAssertEqual(richLines(rig.rows(now: TestClock.now)),
                       ["$66.00 left this week - Simulated", "Estimate $30.00 - Simulated"],
                       "the last estimate by ledger order wins")
        XCTAssertTrue(rig.ledger.remove(requestID: laterEstimate.requestID))
        XCTAssertEqual(richLines(rig.rows(now: TestClock.now)),
                       ["$96.00 left this week - Simulated", "Estimate $86.00 - Simulated"])
        XCTAssertTrue(rig.ledger.remove(requestID: earlyEstimate.requestID))
        XCTAssertEqual(richLines(rig.rows(now: TestClock.now)), ["$182.00 left this week - Simulated"])
        let week = BudgetWeek.start(of: TestClock.now, in: TestClock.zone)
        let left = BudgetClient.weeklyBudgetCents - rig.ledger.spentCents(weekStart: week)
        XCTAssertEqual(richLines(rig.rows(now: TestClock.now)).first,
                       AgentPartner.partnerLine(AgentBudget.dollars(cents: abs(left)) + " left this week"),
                       "the rich figure is the weekly budget less the ledger's total for the week")
    }

    // MARK: T16 and T17, SPEC-LOBBYROWS-002 (card t117): the placeholders and the two-line cap

    func testLOBBYROWS_T16_AnEmptyOnTimeOrFullRowShowsItsPlaceholderAndNothingElseChanges() {
        let empty = LobbyRows.rows(items: [], stays: [], spentCents: 0, entries: [],
                                   now: TestClock.now, calendar: LobbyFixtures.calendar)
        XCTAssertEqual(empty.map(\.lines), [["No plans today"], ["No orders today"],
                                            ["$200.00 left this week - Simulated"]])

        let control = LobbyRows.rows(items: [LobbyFixtures.item("Item", "2026-10-27T10:00")],
                                     stays: [LobbyFixtures.stay("s1", partner: "p-tables", name: "Example Tables",
                                                                "2026-10-27T19:00")],
                                     spentCents: 0, entries: [], now: TestClock.now, calendar: LobbyFixtures.calendar)
        XCTAssertEqual(control.map(\.lines), [["Item 10:00 AM"], ["Example Tables - Simulated 7:00 PM"],
                                              ["$200.00 left this week - Simulated"]],
                       "the positive control: rows with something to say show no placeholder")
        XCTAssertFalse(control.flatMap(\.lines).contains("No plans today"))
        XCTAssertFalse(control.flatMap(\.lines).contains("No orders today"))

        let passed = LobbyRows.rows(items: [LobbyFixtures.item("Early", "2026-10-27T08:59")], stays: [],
                                    spentCents: 0, entries: [], now: TestClock.now, calendar: LobbyFixtures.calendar)
        XCTAssertEqual(onTimeLines(passed), ["No plans today"], "today's items are all over: the same placeholder")

        let over = LobbyRows.rows(items: [], stays: [], spentCents: 25000, entries: [LobbyFixtures.entry(25000, estimate: false)],
                                  now: TestClock.now, calendar: LobbyFixtures.calendar)
        XCTAssertEqual(richLines(over), ["$50.00 over this week - Simulated"], "the rich row never gets a placeholder")

        for c in LobbyFixtures.pureCases {
            let rows = build(c)
            let onTime = LobbyRows.onTimeLines(items: c.items, now: c.now, calendar: c.calendar)
            let full = LobbyRows.fullLines(stays: c.stays, now: c.now, calendar: c.calendar)
            let rich = LobbyRows.richLines(spentCents: c.spentCents, entries: c.entries)
            XCTAssertEqual(onTimeLines(rows), onTime.isEmpty ? ["No plans today"] : onTime, c.label)
            XCTAssertEqual(fullLines(rows), full.isEmpty ? ["No orders today"] : full, c.label)
            XCTAssertEqual(richLines(rows), rich, c.label)
        }

        XCTAssertEqual("No plans today".components(separatedBy: "Simulated").count - 1, 0)
        XCTAssertEqual("No orders today".components(separatedBy: "Simulated").count - 1, 0)
    }

    func testLOBBYROWS_T17_TheFullRowShowsAtMostTheTwoEarliestPicks() {
        let cases = LobbyFixtures.t17
        let expected: [[String]] = [
            ["Acme Cars - Simulated 9:05 AM", "Example Delivery - Simulated 12:40 PM"],
            ["Acme Cars - Simulated 9:05 AM", "Example Delivery - Simulated 12:40 PM"],
            ["Example Delivery - Simulated 12:40 PM", "Example Tables - Simulated 7:00 PM"],
            ["Example Tables - Simulated 7:00 PM"],
            ["Gamma - Simulated 7:00 PM", "Alpha - Simulated 7:00 PM"],
            ["Example Delivery - Simulated 12:40 PM", "Example Tables - Simulated 7:00 PM"],
            ["Delta - Simulated 8:00 AM", "Example Delivery - Simulated 12:40 PM"],
            ["Alpha - Simulated 10:00 AM", "Beta - Simulated 11:00 AM"],
            ["Example Delivery - Simulated 12:40 PM", "Example Tables - Simulated 7:00 PM"],
        ]
        XCTAssertEqual(cases.count, expected.count)
        for (c, want) in zip(cases, expected) {
            XCTAssertEqual(LobbyRows.fullLines(stays: c.stays, now: c.now, calendar: c.calendar), want, c.label)
            XCTAssertEqual(fullLines(build(c)), want, "the full row: \(c.label)")
        }
        for c in cases[0...1] {
            XCTAssertFalse(LobbyRows.fullLines(stays: c.stays, now: c.now, calendar: c.calendar)
                            .contains("Example Tables - Simulated 7:00 PM"), "the third partner is absent: \(c.label)")
        }
    }

    // MARK: T18 and T19, SPEC-LOBBYROWS-002 (card t117): the line slots and the equal row height

    func testLOBBYROWS_T18_EveryRowHasExactlyTwoLineSlots() {
        func row(_ lines: [String]) -> LobbyRow { LobbyRow(id: "x", title: "t", lines: lines) }
        XCTAssertEqual(LobbyRows.slots(for: row([])), [nil, nil])
        XCTAssertEqual(LobbyRows.slots(for: row(["No orders today"])), ["No orders today", nil])
        XCTAssertEqual(LobbyRows.slots(for: row(["A - Simulated 7:00 PM", "B - Simulated 8:00 PM"])),
                       ["A - Simulated 7:00 PM", "B - Simulated 8:00 PM"])
        for c in LobbyFixtures.pureCases {
            for r in build(c) {
                let slots = LobbyRows.slots(for: r)
                XCTAssertEqual(slots.count, 2, "\(c.label): \(r.id)")
                XCTAssertEqual(slots.compactMap { $0 }, r.lines, "the filled slots are the row's lines in order: \(c.label): \(r.id)")
                XCTAssertFalse(slots.contains { $0 == "" }, "no slot holds an empty string: \(c.label): \(r.id)")
            }
        }
    }

    /// The height `sizeThatFits` gives a hosted view proposed 316 pt of width (the 354 pt row less the 24 pt icon and
    /// the 14 pt spacing), at a text size the test names: the default cases are pinned to `.large`.
    private func hostedHeight<V: View>(_ view: V, size: DynamicTypeSize = .large) -> CGFloat {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: 316, height: CGFloat.greatestFiniteMagnitude)).height
    }

    /// A key line's text as the lobby draws it: `.subheadline`, wrapping, never cut.
    private func keyLineText(_ text: String) -> some View {
        Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }

    /// The height of one visual line and the pitch between two (the measured gap from one visual line to the
    /// next). The probe measured them different at `.large` (18 and 20 pt: a single line is as tall as its
    /// glyphs, a following line adds the text style's leading), so the guard measures both and checks the pitch
    /// is steady (three explicit lines against two) before it counts anything.
    private func lineMetrics(size: DynamicTypeSize) -> (one: CGFloat, pitch: CGFloat) {
        let one = hostedHeight(keyLineText("A"), size: size)
        let two = hostedHeight(keyLineText("A\nA"), size: size)
        let three = hostedHeight(keyLineText("A\nA\nA"), size: size)
        XCTAssertGreaterThan(one, 0, "a hosted one-line text has a height")
        XCTAssertEqual(one, hostedHeight(keyLineText("A"), size: size), accuracy: 0.01, "two identical measurements agree")
        XCTAssertEqual(three - two, two - one, accuracy: 0.1, "the line pitch is steady, so a visual line count is trustworthy")
        return (one, two - one)
    }

    /// The number of visual lines a text takes at 316 pt: the height above one line, in whole pitches. A height
    /// that is not a whole number of pitches (within 0.1) fails the test instead of being rounded.
    private func visualLines(of text: String, size: DynamicTypeSize = .large) -> Int {
        let metrics = lineMetrics(size: size)
        let extra = (hostedHeight(keyLineText(text), size: size) - metrics.one) / metrics.pitch
        XCTAssertEqual(extra, extra.rounded(), accuracy: 0.1, "a whole number of visual lines: \(text)")
        return 1 + Int(extra.rounded())
    }

    /// The text grown one word at a time from `base` until it takes `count` visual lines (one added word adds at
    /// most one line, so the count cannot be skipped); it fails after 40 words.
    private func grown(from base: String, to count: Int) -> String {
        var text = base
        var words = 0
        while visualLines(of: text) < count && words < 40 {
            text += " delivery"
            words += 1
        }
        XCTAssertEqual(visualLines(of: text), count, "the derived text takes \(count) visual lines: \(text)")
        return text
    }

    func testLOBBYROWS_T19_RowsWithZeroOneOrTwoLinesHaveTheSameHeight() {
        let short = "Alpha - Simulated 7:00 PM"
        let short2 = "Beta - Simulated 8:00 PM"
        XCTAssertEqual(visualLines(of: short), 1)
        XCTAssertEqual(visualLines(of: short2), 1)
        let wrapTwoA = grown(from: short, to: 2)
        let wrapTwoB = grown(from: short2, to: 2)
        let wrapThree = grown(from: "Gamma - Simulated 9:00 PM", to: 3)
        XCTAssertEqual(visualLines(of: wrapTwoA), 2)
        XCTAssertEqual(visualLines(of: wrapTwoB), 2)
        XCTAssertEqual(visualLines(of: wrapThree), 3)

        func column(_ lines: [String], _ size: DynamicTypeSize = .large) -> CGFloat {
            let row = LobbyRow(id: RootView.Service.full.id, title: "be full sir", lines: lines)
            return hostedHeight(LobbyRowText(service: .full, row: row), size: size)
        }
        let name = hostedHeight(Text("be full sir").font(.title3))
        let one = lineMetrics(size: .large).one

        // Equal at the default size: the reserve is three key-line heights, so 0, 1 or 2 lines, and a line that
        // wraps inside the reserve, change nothing.
        let reference = column([short, short2])
        XCTAssertGreaterThan(reference, 0)
        let equalCases: [(String, [String])] = [
            ("no line", []), ("one line", ["No orders today"]), ("two lines", [short, short2]),
            ("first wraps once", [wrapTwoA, short]), ("second wraps once", [short, wrapTwoA]),
            ("one line takes three visual lines", [wrapThree]),
        ]
        for (label, lines) in equalCases {
            XCTAssertEqual(column(lines), reference, accuracy: 0.5, "the same height: \(label)")
        }
        XCTAssertEqual(reference, name + 4 + 3 * one + 2 * 4, accuracy: 0.5,
                       "the key-line area is the reserve: the name, the gap, three key-line heights and two gaps")

        // Grows by the excess only: the lines need more than the reserve, the row takes exactly their height.
        let wrapped = hostedHeight(keyLineText(wrapTwoA)) + 4 + hostedHeight(keyLineText(wrapTwoB))
        let bothWrap = column([wrapTwoA, wrapTwoB])
        XCTAssertGreaterThan(bothWrap, reference + 0.5, "both lines wrap: the row grows")
        XCTAssertEqual(bothWrap, name + 4 + wrapped, accuracy: 0.5, "it grows by the excess, nothing is added")
        let threeAndOne = hostedHeight(keyLineText(wrapThree)) + 4 + hostedHeight(keyLineText(short))
        let threePlus = column([wrapThree, short])
        XCTAssertGreaterThan(threePlus, reference + 0.5, "one line needs three visual lines beside another: the row grows")
        XCTAssertEqual(threePlus, name + 4 + threeAndOne, accuracy: 0.5, "it grows by the excess, nothing is added")

        // The largest size checked: the lines are one visual line each, so only the reserve decides.
        for text in ["No orders today", "A 1:00 PM", "B 2:00 PM"] {
            XCTAssertEqual(visualLines(of: text, size: .xxxLarge), 1, "one visual line at the largest size: \(text)")
        }
        let largest = column(["A 1:00 PM", "B 2:00 PM"], .xxxLarge)
        XCTAssertGreaterThan(largest, 0)
        XCTAssertEqual(column([], .xxxLarge), largest, accuracy: 0.5)
        XCTAssertEqual(column(["No orders today"], .xxxLarge), largest, accuracy: 0.5)
        XCTAssertGreaterThan(largest, reference, "the reserve follows the text size")
    }

    // MARK: T15, the scanner

    /// Removes each item title with the one space that follows it, then trims: what is left is
    /// the row's own text.
    private func scanned(_ line: String, titles: [String]) -> String {
        var text = line
        for title in titles where !title.isEmpty {
            text = text.replacingOccurrences(of: title + " ", with: "")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Non-empty, and only ASCII letters and digits, space, `. , : $ ( ) -` and the middle dot.
    private func isFactText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let allowed: Set<Character> = [" ", "\u{00A0}", ".", ",", ":", "$", "(", ")", "-", "·"]
        return text.allSatisfy { c in (c.isASCII && (c.isLetter || c.isNumber)) || allowed.contains(c) }
    }

    /// None of the advice words, and no whole-word `save` or `tip`.
    private func holdsNoAdvice(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let banned = ["should", "recommend", "advise", "afford", "invest"]
        if banned.contains(where: lowered.contains) { return false }
        let words = lowered.split(whereSeparator: { !($0.isASCII && $0.isLetter) })
        return !words.contains { $0 == "save" || $0 == "tip" }
    }

    private func markerCount(_ line: String) -> Int {
        line.components(separatedBy: "Simulated").count - 1
    }

    /// An on-time line, without its item titles, holds no marker.
    private func onTimeHoldsNoMarker(_ line: String, titles: [String]) -> Bool {
        !scanned(line, titles: titles).contains("Simulated")
    }

    /// A full line is `<name> - Simulated <time>` and holds the marker once.
    private func fullLineIsWellFormed(_ line: String) -> Bool {
        let pattern = "^.+ - Simulated [0-9]{1,2}:[0-9]{2} (AM|PM)$"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..., in: line)
        return regex?.firstMatch(in: line, range: range) != nil && markerCount(line) == 1
    }

    /// A rich line ends with one marker.
    private func richLineIsWellFormed(_ line: String) -> Bool {
        line.hasSuffix(" - Simulated") && markerCount(line) == 1
    }

    func testLOBBYROWS_T15_EveryLineIsPlainEnglishFactsWithoutAdviceAndTheMarkerIsAppliedOnceOnlyToPartnerLines() {
        var collected: [(kind: LobbyFixtures.RowKind, line: String, titles: [String])] = []
        var placeholders: [String] = []
        for c in LobbyFixtures.pureCases {
            let onTime = LobbyRows.onTimeLines(items: c.items, now: c.now, calendar: c.calendar)
            let full = LobbyRows.fullLines(stays: c.stays, now: c.now, calendar: c.calendar)
            let rich = LobbyRows.richLines(spentCents: c.spentCents, entries: c.entries)
            XCTAssertLessThanOrEqual(onTime.count, 2, "an on-time row never has more than 2 key lines: \(c.label)")
            XCTAssertLessThanOrEqual(rich.count, 2, "a rich row never has more than 2 key lines: \(c.label)")
            XCTAssertLessThanOrEqual(full.count, 2, "a full row never has more than 2 key lines: \(c.label)")
            collected += onTime.map { (kind: LobbyFixtures.RowKind.onTime, line: $0, titles: c.itemTitles) }
            collected += full.map { (kind: LobbyFixtures.RowKind.full, line: $0, titles: c.itemTitles) }
            collected += rich.map { (kind: LobbyFixtures.RowKind.rich, line: $0, titles: c.itemTitles) }
        }
        for s in LobbyFixtures.storedCases {
            let rows = s.rows(folder(), s.now)
            XCTAssertLessThanOrEqual(lines(rows, .onTime).count, 2, "an on-time row never has more than 2 key lines: \(s.label)")
            XCTAssertLessThanOrEqual(lines(rows, .rich).count, 2, "a rich row never has more than 2 key lines: \(s.label)")
            XCTAssertLessThanOrEqual(lines(rows, .full).count, 2, "a full row never has more than 2 key lines: \(s.label)")
            for row in rows {
                if let kind = LobbyFixtures.RowKind(rawValue: row.id) {
                    for placeholder in ["No plans today", "No orders today"] where row.lines.contains(placeholder) {
                        XCTAssertEqual(row.lines, [placeholder], "a placeholder stands alone in its row: \(s.label)")
                        XCTAssertEqual(kind, placeholder == "No plans today" ? .onTime : .full,
                                       "a placeholder belongs to its own row: \(s.label)")
                    }
                    if row.lines == ["No plans today"] && kind == .onTime || row.lines == ["No orders today"] && kind == .full {
                        placeholders += row.lines
                    } else {
                        collected += row.lines.map { (kind: kind, line: $0, titles: s.itemTitles) }
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(collected.count, 25, "the fixtures of T02 to T14 together hold at least 25 lines")
        XCTAssertTrue(placeholders.contains("No plans today"), "a stored case shows the be on-time sir placeholder")
        XCTAssertTrue(placeholders.contains("No orders today"), "a stored case shows the be full sir placeholder")
        for placeholder in placeholders {
            XCTAssertTrue(isFactText(placeholder), "only fact characters: \(placeholder)")
            XCTAssertTrue(holdsNoAdvice(placeholder), "no advice word: \(placeholder)")
            XCTAssertEqual(markerCount(placeholder), 0, "a placeholder carries no marker: \(placeholder)")
        }
        XCTAssertFalse(collected.contains { $0.line == "No plans today" || $0.line == "No orders today" },
                       "a placeholder is never collected as a partner or schedule line")
        for item in collected {
            let text = scanned(item.line, titles: item.titles)
            XCTAssertTrue(isFactText(text), "only fact characters: \(item.line)")
            XCTAssertTrue(holdsNoAdvice(text), "no advice word: \(item.line)")
            switch item.kind {
            case .onTime:
                XCTAssertTrue(onTimeHoldsNoMarker(item.line, titles: item.titles),
                              "an on-time line carries no marker of its own: \(item.line)")
            case .full:
                XCTAssertTrue(fullLineIsWellFormed(item.line), "a full line is a partner line and a time: \(item.line)")
            case .rich:
                XCTAssertTrue(richLineIsWellFormed(item.line), "a rich line ends with one marker: \(item.line)")
            }
        }

        XCTAssertTrue(onTimeHoldsNoMarker(LobbyFixtures.tablesTitle + " 7:00 PM", titles: [LobbyFixtures.tablesTitle]),
                      "a title's own suffix is the title's")
        XCTAssertFalse(holdsNoAdvice("You should save"), "the scanner flags advice")
        XCTAssertFalse(onTimeHoldsNoMarker("Dinner - Simulated 7:00 PM", titles: ["Dinner"]),
                       "the scanner flags a marker an on-time row added")
        XCTAssertFalse(onTimeHoldsNoMarker("Dinner (Simulated) 7:00 PM", titles: ["Dinner"]),
                       "the scanner flags a marker an on-time row added")
        XCTAssertFalse(fullLineIsWellFormed("Example Tables - Simulated - Simulated 7:00 PM"),
                       "the scanner flags a doubled marker")
        XCTAssertFalse(richLineIsWellFormed("$140.00 left this week - Simulated - Simulated"),
                       "the scanner flags a doubled marker")
        XCTAssertFalse(fullLineIsWellFormed("Example Tables 7:00 PM"), "the scanner flags a missing marker")
        XCTAssertFalse(richLineIsWellFormed("$140.00 left this week"), "the scanner flags a missing marker")
        XCTAssertFalse(fullLineIsWellFormed("No orders today"), "a placeholder is not a partner line")
        XCTAssertFalse(richLineIsWellFormed("No orders today"), "a placeholder is not a rich line")
        XCTAssertTrue(fullLineIsWellFormed("Example Tables - Simulated 7:00 PM"))
        XCTAssertTrue(richLineIsWellFormed("Estimate $86.00 - Simulated"))
    }
}
