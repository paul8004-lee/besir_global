import Foundation

/// A repeating activity stored as its rule instead of as one copy per day (SPEC-RECURRULE-001, card t60).
/// Days are kept as `yyyyMMdd` keys so a time-zone change cannot move a day; dates are rebuilt at read time.
/// This file holds the stored shape, the id codec and the occurrence reader.
struct RepeatSeries: Identifiable, Codable {
    /// Which lunar calendar a lunar rule was made with, so its dates do not move when the OS version changes.
    enum LunarChoice: String, Codable {
        case dangi, chinese

        /// The calendar identifier the expansion core takes. `.dangi` needs a recent OS, so the base's own OS branch
        /// decides; the choice that is stored stays `dangi` either way.
        var identifier: Calendar.Identifier {
            self == .dangi ? RecurrenceRule.lunarIdentifier(osMajorVersion: 26) : .chinese
        }
    }

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

// MARK: - Occurrence ids

/// An occurrence id is the series id with its last four bytes replaced by the occurrence's day key (`yyyyMMdd` as a
/// big-endian `UInt32`). A series id has random first twelve bytes and a zero tail, so an occurrence id is a normal `UUID`
/// that can be read back to (series, day) without a lookup table.
extension RepeatSeries {
    private static let prefixLength = 12

    private static func bytes(of id: UUID) -> [UInt8] {
        withUnsafeBytes(of: id.uuid) { Array($0) }
    }

    private static func uuid(from b: [UInt8]) -> UUID {
        UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// A new series id: twelve random bytes and a zero tail.
    static func newID() -> UUID {
        var b = (0..<prefixLength).map { _ in UInt8.random(in: 0...255) }
        b += [0, 0, 0, 0]
        return uuid(from: b)
    }

    /// The id of the occurrence on a day. The day key is the occurrence's original date, so the id stays the same when
    /// the occurrence is later moved.
    func occurrenceID(dayKey: Int) -> UUID {
        let v = UInt32(truncatingIfNeeded: dayKey)
        let tail = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return Self.uuid(from: Array(Self.bytes(of: id)[0..<Self.prefixLength]) + tail)
    }

    /// Reads an id back: the first twelve bytes and the day key. Syntactic only: it returns nil unless the last four
    /// bytes are a valid `yyyyMMdd` (year 1900 to 9999, month 1 to 12, day 1 to 31). Whether a series with that prefix
    /// exists, and whether the day is one of its occurrences, is for `Store.series(forOccurrence:)` and `Store.activity(id:)`.
    static func decode(_ id: UUID) -> (prefix: [UInt8], dayKey: Int)? {
        let b = bytes(of: id)
        let v = (UInt32(b[12]) << 24) | (UInt32(b[13]) << 16) | (UInt32(b[14]) << 8) | UInt32(b[15])
        guard v <= 99_991_231 else { return nil }
        let key = Int(v)
        let year = key / 10_000, month = key / 100 % 100, day = key % 100
        guard year >= 1900, (1...12).contains(month), (1...31).contains(day) else { return nil }
        return (Array(b[0..<prefixLength]), key)
    }

    /// Whether a decoded occurrence id carries this series' prefix; this series' own tail must be zero (a series id,
    /// not an occurrence id).
    func owns(_ decoded: (prefix: [UInt8], dayKey: Int)) -> Bool {
        let b = Self.bytes(of: id)
        return Array(b[0..<Self.prefixLength]) == decoded.prefix && b[12...15].allSatisfy { $0 == 0 }
    }

    /// The first moment of the day a day key names, in `calendar`.
    static func date(forDayKey key: Int, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: key / 10_000, month: key / 100 % 100, day: key % 100))
    }
}

// MARK: - Occurrences

extension RepeatSeries {
    /// The occurrences of the series that overlap `interval`, one `ActivityBlock` each, computed from the rule. A
    /// block that crosses midnight is returned for both days. Nothing is stored: the block carries the occurrence id,
    /// the series id as `recurrenceId`, and the times of `Store.occurrenceSpan`, passed `.distantPast` so past
    /// occurrences are drawn too.
    // @MX:ANCHOR: every reader of a repeat (day list, month dots and titles, agent tools, planning, calendar mirror) gets
    // its blocks here, and the resolver `Store.activity(id:)` builds its answer from this. A change to which days or times
    // a series produces changes every one of them at once.
    @MainActor
    func occurrences(in interval: DateInterval, calendar: Calendar = .current) -> [ActivityBlock] {
        guard let first = Self.date(forDayKey: firstDayKey, calendar: calendar),
              // One day back: an occurrence that began the evening before and ends inside the interval is found. The
              // 24-hour rule of `occurrenceEndDayDistance` makes one day enough.
              let windowStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: interval.start))
        else { return [] }
        var through = calendar.startOfDay(for: interval.end)
        if let lastDayKey, let last = Self.date(forDayKey: lastDayKey, calendar: calendar) { through = min(through, last) }
        let days = rule.dates(from: first, through: through, startingAt: windowStart, calendar: calendar,
                              lunarCalendar: lunarCalendar?.identifier ?? RecurrenceRule.defaultLunarIdentifier)
        var blocks: [ActivityBlock] = []
        for day in days {
            let dayKey = Store.dayKey(day, calendar: calendar)
            guard !skippedDayKeys.contains(dayKey),
                  let span = Store.occurrenceSpan(on: day, startHour: startMinute / 60, startMinute: startMinute % 60,
                                                  end: (endMinute / 60, endMinute % 60, endDayDistance),
                                                  after: .distantPast, calendar: calendar),
                  span.start < interval.end, span.stop > interval.start else { continue }
            var block = ActivityBlock(title: title, location: location, startDate: span.start, endDate: span.stop,
                                      recurrenceId: id)
            block.id = occurrenceID(dayKey: dayKey)
            block.syncToCalendar = syncToCalendar
            blocks.append(block)
        }
        return blocks
    }
}
