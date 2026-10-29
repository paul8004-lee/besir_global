import Foundation

/// A repeating activity stored as its rule instead of as one copy per day (SPEC-RECURRULE-001, card t60).
/// Days are kept as `yyyyMMdd` keys so a time-zone change cannot move a day; dates are rebuilt at read time.
/// This file holds the stored shape, the id codec and the occurrence reader.
struct RepeatSeries: Identifiable, Codable {
    /// Which lunar calendar a lunar rule was made with, so its dates do not move when the OS version changes.
    enum LunarChoice: String, Codable { case dangi, chinese }

    var id: UUID
    var title: String
    var location: Place?
    var rule: RecurrenceRule
    var lunarCalendar: LunarChoice?
    var firstDayKey: Int
    var lastDayKey: Int?
    var startMinute: Int
    var endMinute: Int
    var endDayDistance: Int
    var syncToCalendar: Bool?
    var skippedDayKeys: [Int] = []
    var legPlan: LegPlan?
    var legsFilledThroughDayKey: Int?
}

/// What travel legs a series makes for the days inside the leg window.
struct LegPlan: Codable {
    var outboundFrom: Place?
    var returnTo: Place?
    var outboundMode: TransportMode
    var returnMode: TransportMode
    var bufferMinutes: Int
    var notifyLeadMinutes: Int
    var notifyEnabled: Bool
}

// Stubs for the red run: the codec and the reader return nothing useful yet.
extension RepeatSeries {
    static func newID() -> UUID { UUID() }
    func occurrenceID(dayKey: Int) -> UUID { UUID() }
    static func decode(_ id: UUID) -> (prefix: [UInt8], dayKey: Int)? { nil }
    @MainActor func occurrences(in interval: DateInterval, calendar: Calendar = .current) -> [ActivityBlock] { [] }
}
