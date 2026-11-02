import Foundation

/// SPEC-RICHSTATS-001 (card t116): the statistics of the be rich sir screen as one pure value. Foundation only: it reads no clock,
/// no process, no environment and no view; the instant, the calendar and the budget are handed in, so the same inputs always give
/// the same value. Money is text from `AgentBudget.dollars(cents:)` and every date text comes from one formatter factory.
struct RichStats: Equatable {
    /// The statistics of `entries` at `now` in `calendar`'s zone, for a weekly budget of `budgetCents`.
    static func build(entries: [BudgetEntry], now: Date, calendar: Calendar, budgetCents: Int) -> RichStats {
        let dates = Dates(calendar)

        // The week and the budget come from the inputs alone, so they are set for an empty ledger too.
        let thisMonday = dates.monday(of: now)
        let thisWeek = dates.iso(thisMonday)
        let budgetText = AgentBudget.dollars(cents: budgetCents)
        let halfBudgetText = AgentBudget.dollars(cents: (budgetCents + 1) / 2)

        // The window, newest first: this week's Monday and the seven before it.
        let mondays = (0...7).map { dates.shift(thisMonday, weeks: -$0) }
        let mondayTexts = mondays.map { dates.iso($0) }

        // An entry whose week is not a `yyyy-MM-dd` date is left out of everything.
        let valid = entries.filter { dates.day(from: $0.weekStart) != nil }
        let firstDataWeek = valid.map(\.weekStart).min()
        var totals: [String: Int] = [:]
        var estimateTotals: [String: Int] = [:]
        for entry in valid {
            totals[entry.weekStart, default: 0] += entry.amountCents
            if entry.isEstimate { estimateTotals[entry.weekStart, default: 0] += entry.amountCents }
        }

        // This week
        let weekEntries = valid.filter { $0.weekStart == thisWeek }
        let estimateCount = weekEntries.filter(\.isEstimate).count
        let thisTotal = totals[thisWeek] ?? 0
        let estimateCents = estimateTotals[thisWeek] ?? 0
        let lastWeek = mondayTexts[1]
        var versus: Versus?
        if let first = firstDataWeek, lastWeek >= first {
            let lastTotal = totals[lastWeek] ?? 0
            let direction: Direction = thisTotal < lastTotal ? .down : (thisTotal > lastTotal ? .up : .same)
            versus = Versus(differenceCents: abs(thisTotal - lastTotal), direction: direction, lastWeekCents: lastTotal)
        }

        // Trends: the window's weeks, oldest first, and the statistics of the counted completed weeks.
        let ordered = (0...7).reversed().map { (text: mondayTexts[$0], date: mondays[$0], isCurrent: $0 == 0) }
        let counted = ordered.filter { week in !week.isCurrent && firstDataWeek.map { week.text >= $0 } == true }
        let windowHoldsEntry = valid.contains { mondayTexts.contains($0.weekStart) }
        let weeks: [Week] = windowHoldsEntry ? ordered.map { week in
            let cents = totals[week.text] ?? 0
            let isCounted = !week.isCurrent && firstDataWeek.map { week.text >= $0 } == true
            return Week(weekStart: week.text, label: dates.shortDay(week.date), cents: cents, isCurrent: week.isCurrent,
                        isOver: cents > budgetCents, isCounted: isCounted, hasBar: week.isCurrent || isCounted)
        } : []
        var summary: Summary?
        if !counted.isEmpty {
            let weekCents = counted.map { totals[$0.text] ?? 0 }
            let total = weekCents.reduce(0, +)
            let estimated = counted.reduce(0) { $0 + (estimateTotals[$1.text] ?? 0) }
            let count = counted.count
            var lowest = 0
            var highest = 0
            for index in weekCents.indices {
                if weekCents[index] <= weekCents[lowest] { lowest = index }
                if weekCents[index] >= weekCents[highest] { highest = index }
            }
            summary = Summary(averageCents: (2 * total + count) / (2 * count),
                              underCount: weekCents.filter { $0 <= budgetCents }.count,
                              countedWeeks: count,
                              estimatePercent: total == 0 ? nil : (200 * estimated + total) / (2 * total),
                              lowest: Pick(cents: weekCents[lowest], label: dates.monthDay(counted[lowest].date)),
                              highest: Pick(cents: weekCents[highest], label: dates.monthDay(counted[highest].date)))
        }

        // Where
        let windowNamed = valid.filter { mondayTexts.contains($0.weekStart) && !($0.partnerName ?? "").isEmpty }
        var partnerTotals: [String: Int] = [:]
        for entry in windowNamed { partnerTotals[entry.partnerName ?? "", default: 0] += entry.amountCents }
        let rankedPartners = partnerTotals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
        let topCents = rankedPartners.first?.value ?? 0
        let partners = rankedPartners.map {
            Partner(name: $0.key, cents: $0.value, fraction: topCents > 0 ? Double($0.value) / Double(topCents) : 0)
        }

        // Entries
        let byWeek = Dictionary(grouping: valid, by: \.weekStart)
        let groups = byWeek.keys.sorted(by: >).map { week -> Group in
            let title = "Week of " + (dates.day(from: week).map { dates.monthDay($0) } ?? week)
            return Group(weekStart: week, title: title,
                         totalText: AgentBudget.dollars(cents: totals[week] ?? 0) + " / " + budgetText,
                         rows: (byWeek[week] ?? []).reversed().map(row))
        }

        return RichStats(weekTitle: "Week of " + dates.monthDay(thisMonday), budgetCents: budgetCents, budgetText: budgetText,
                         halfBudgetText: halfBudgetText,
                         statedCents: thisTotal - estimateCents, estimateCents: estimateCents, recordCount: weekEntries.count,
                         estimateCount: estimateCount, estimatesText: "\(estimateCount) estimate" + (estimateCount == 1 ? "" : "s"),
                         versus: versus, latest: weekEntries.reversed().prefix(3).map(row),
                         slices: makeSlices(of: weekEntries),
                         days: makeDays(of: weekEntries, thisWeek: thisWeek, now: now, dates: dates),
                         partners: partners,
                         weeks: weeks, summary: summary,
                         groups: groups)
    }

    /// The figure of This week, from the screen model's standing and busy state.
    static func hero(standing: BudgetStanding?, isBusy: Bool) -> Hero {
        guard let standing else { return isBusy ? .busy : .none }
        let within = standing.isWithin
        return .figure(amountText: AgentBudget.dollars(cents: within ? standing.leftCents : -standing.leftCents),
                       word: within ? "left" : "over",
                       spentLine: AgentBudget.dollars(cents: standing.spentCents) + " of "
                           + AgentBudget.dollars(cents: standing.budgetCents) + " spent",
                       isOver: !within)
    }

    // The week and the budget: made from now, the calendar and budgetCents alone, set for every input, [] included
    let weekTitle: String
    let budgetCents: Int
    let budgetText: String
    let halfBudgetText: String

    // This week
    let statedCents: Int
    let estimateCents: Int
    let recordCount: Int
    let estimateCount: Int
    let estimatesText: String
    let versus: Versus?
    let latest: [Row]

    // Where
    let slices: [Slice]
    let days: [Day]?
    let partners: [Partner]

    // Trends
    let weeks: [Week]
    let summary: Summary?

    // Entries
    let groups: [Group]

    struct Versus: Equatable { let differenceCents: Int; let direction: Direction; let lastWeekCents: Int }
    enum Direction: Equatable { case down, up, same }
    struct Row: Equatable { let id: String; let amountText: String; let tag: String }
    struct Slice: Equatable { let label: String; let cents: Int; let isOther: Bool }
    struct Day: Equatable { let letter: String; let cents: Int; let isToday: Bool }
    struct Partner: Equatable { let name: String; let cents: Int; let fraction: Double }
    struct Week: Equatable { let weekStart: String; let label: String; let cents: Int
                             let isCurrent: Bool; let isOver: Bool; let isCounted: Bool; let hasBar: Bool }
    struct Summary: Equatable { let averageCents: Int; let underCount: Int; let countedWeeks: Int
                                let estimatePercent: Int?; let lowest: Pick; let highest: Pick }
    struct Pick: Equatable { let cents: Int; let label: String }
    struct Group: Equatable { let weekStart: String; let title: String; let totalText: String; let rows: [Row] }

    /// The figure of This week (REQ-002), from the model's standing and busy state.
    enum Hero: Equatable {
        case figure(amountText: String, word: String, spentLine: String, isOver: Bool)
        case busy
        case none
    }

    // MARK: Parts of the build

    private static func row(_ entry: BudgetEntry) -> Row {
        Row(id: entry.requestID, amountText: AgentBudget.dollars(cents: entry.amountCents),
            tag: entry.isEstimate ? "Estimate" : "Stated")
    }

    /// The week's amounts by the kind each entry stores: a kind that obeys the kind rule and is not `Other` is its own label,
    /// everything else is `Other`. The four largest named labels stay, the rest join `Other`, which comes last; zero is no slice.
    private static func makeSlices(of weekEntries: [BudgetEntry]) -> [Slice] {
        var named: [String: Int] = [:]
        var other = 0
        for entry in weekEntries {
            if let kind = entry.kind, PartnerEntry.isKind(kind), kind != "Other" {
                named[kind, default: 0] += entry.amountCents
            } else {
                other += entry.amountCents
            }
        }
        let ranked = named.filter { $0.value != 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for rest in ranked.dropFirst(4) { other += rest.value }
        var slices = ranked.prefix(4).map { Slice(label: $0.key, cents: $0.value, isOther: false) }
        if other != 0 { slices.append(Slice(label: "Other", cents: other, isOther: true)) }
        return slices
    }

    /// Seven days, Monday first, from the week's entries that store a day inside that week; nil when none does.
    private static func makeDays(of weekEntries: [BudgetEntry], thisWeek: String, now: Date, dates: Dates) -> [Day]? {
        var sums = [Int](repeating: 0, count: 7)
        var found = false
        for entry in weekEntries {
            guard let text = entry.day, let date = dates.day(from: text), dates.iso(dates.monday(of: date)) == thisWeek else { continue }
            sums[dates.weekdayIndex(date)] += entry.amountCents
            found = true
        }
        guard found else { return nil }
        let todayIndex = dates.weekdayIndex(now)
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        return letters.indices.map { Day(letter: letters[$0], cents: sums[$0], isToday: $0 == todayIndex) }
    }

    // MARK: Dates

    /// The file's one formatter, `en_US_POSIX` with the handed calendar and its zone, so the text never depends on the device.
    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// The handed calendar and the three date texts the builder writes. Days are held at noon so a daylight-saving change never
    /// moves a Monday.
    private struct Dates {
        private let handed: Calendar
        private let isoFormat: DateFormatter
        private let monthDayFormat: DateFormatter
        private let shortDayFormat: DateFormatter

        init(_ calendar: Calendar) {
            handed = calendar
            isoFormat = RichStats.formatter("yyyy-MM-dd", calendar)
            monthDayFormat = RichStats.formatter("MMM d", calendar)
            shortDayFormat = RichStats.formatter("M/d", calendar)
        }

        func iso(_ date: Date) -> String { isoFormat.string(from: date) }
        func monthDay(_ date: Date) -> String { monthDayFormat.string(from: date) }
        func shortDay(_ date: Date) -> String { shortDayFormat.string(from: date) }

        /// The day a `yyyy-MM-dd` text names, at noon; nil for any other text (read back, so `2026-1-2` and `2026-02-30` fail).
        func day(from text: String) -> Date? {
            guard let parsed = isoFormat.date(from: text), isoFormat.string(from: parsed) == text else { return nil }
            return noon(parsed)
        }

        func noon(_ date: Date) -> Date {
            var parts = handed.dateComponents([.year, .month, .day], from: date)
            parts.hour = 12
            return handed.date(from: parts) ?? date
        }

        /// Monday 0 to Sunday 6.
        func weekdayIndex(_ date: Date) -> Int { (handed.component(.weekday, from: date) + 5) % 7 }

        func monday(of date: Date) -> Date {
            noon(handed.date(byAdding: .day, value: -weekdayIndex(date), to: date) ?? date)
        }

        func shift(_ date: Date, weeks: Int) -> Date { handed.date(byAdding: .day, value: 7 * weeks, to: date) ?? date }
    }
}
