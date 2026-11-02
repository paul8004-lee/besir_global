import XCTest
@testable import besir

/// SPEC-RICHSTATS-001 (card t116): the pure builder of the be rich sir statistics and the hero. Every expected text is a literal
/// written here, never made by the code under test. The fixed clock is Tuesday 2026-10-27T09:00 in America/Los_Angeles; a test
/// that needs another instant says so. The weekly budget handed in is 20000 cents unless a row says otherwise.
final class RichStatsTests: XCTestCase {
    // MARK: Helpers

    private func calendar(_ identifier: String = "America/Los_Angeles") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func entry(_ week: String, _ cents: Int, estimate: Bool = false, name: String? = nil, day: String? = nil,
                       kind: String? = nil) -> BudgetEntry {
        BudgetEntry(requestID: UUID().uuidString, weekStart: week, amountCents: cents, isEstimate: estimate, partnerName: name,
                    day: day, kind: kind)
    }

    private func build(_ entries: [BudgetEntry], now: Date = TestClock.now, zone: String = "America/Los_Angeles",
                       budget: Int = 20000) -> RichStats {
        RichStats.build(entries: entries, now: now, calendar: calendar(zone), budgetCents: budget)
    }

    /// The rows as one text each: the amount, a space and the tag.
    private func texts(_ rows: [RichStats.Row]) -> [String] {
        rows.map { "\($0.amountText) \($0.tag)" }
    }

    /// The week of 2026-10-26 in insertion order: stated 2400, a table estimate 4200, stated 3150, a delivery estimate 2250 and
    /// a stated 1800 with no day.
    private func thisWeekEntries() -> [BudgetEntry] {
        let week = "2026-10-26"
        return [entry(week, 2400),
                entry(week, 4200, estimate: true, name: "Example Tables", kind: "Dining"),
                entry(week, 3150),
                entry(week, 2250, estimate: true, name: "Example Delivery", kind: "Delivery"),
                entry(week, 1800)]
    }

    /// One stated entry per week: the mockup row of the trends tab. Weeks 9/14 to 10/26 are completed at 2026-11-03, 11/2 is current.
    private let mockupWeeks: [(String, Int)] = [("2026-09-14", 18375), ("2026-09-21", 23625), ("2026-09-28", 17125), ("2026-10-05", 11250),
                                                ("2026-10-12", 20500), ("2026-10-19", 15750), ("2026-10-26", 16250), ("2026-11-02", 13800)]

    private var tuesdayAfterClockChange: Date { TestClock.date("2026-11-03T09:00") }

    // MARK: T01 this week

    func testRICHSTATS_T01_ThisWeekSumsStatedAndEstimatedCountsRecordsAndListsTheLatestThree() {
        let older = [entry("2026-10-19", 5000), entry("2026-10-19", 1000, estimate: true)]
        let stats = build(older + thisWeekEntries())
        XCTAssertEqual(stats.weekTitle, "Week of Oct 26")
        XCTAssertEqual(stats.statedCents, 7350)
        XCTAssertEqual(stats.estimateCents, 6450)
        XCTAssertEqual(stats.recordCount, 5)
        XCTAssertEqual(stats.estimateCount, 2)
        XCTAssertEqual(stats.estimatesText, "2 estimates")
        XCTAssertEqual(texts(stats.latest), ["$18.00 Stated", "$22.50 Estimate", "$31.50 Stated"], "the three newest, newest first")

        let one = build([entry("2026-10-26", 1000, estimate: true)])
        XCTAssertEqual(one.estimateCount, 1)
        XCTAssertEqual(one.estimatesText, "1 estimate")

        let empty = build([entry("2026-10-19", 5000), entry("2026-10-19", 1000, estimate: true)])
        XCTAssertEqual(empty.recordCount, 0, "entries of another week are not this week's")
        XCTAssertEqual(empty.estimatesText, "0 estimates")
        XCTAssertEqual(empty.latest, [])
        XCTAssertEqual(empty.statedCents, 0)
        XCTAssertEqual(empty.estimateCents, 0)
    }

    // MARK: T02 versus last week

    func testRICHSTATS_T02_VersusLastWeekGivesTheDifferenceAndArrowOnlyWhenLastWeekCounts() {
        func check(_ entries: [BudgetEntry], _ expected: RichStats.Versus?, _ note: String) {
            let stats = build(entries)
            if let expected {
                XCTAssertNotNil(stats.versus, note)
                XCTAssertEqual(stats.versus, expected, note)
            } else {
                XCTAssertNil(stats.versus, note)
            }
        }
        check([entry("2026-10-19", 16250), entry("2026-10-26", 13800)],
              RichStats.Versus(differenceCents: 2450, direction: .down, lastWeekCents: 16250), "13800 against 16250")
        check([entry("2026-10-19", 3000), entry("2026-10-26", 5000)],
              RichStats.Versus(differenceCents: 2000, direction: .up, lastWeekCents: 3000), "5000 against 3000")
        check([entry("2026-10-19", 4000), entry("2026-10-26", 4000)],
              RichStats.Versus(differenceCents: 0, direction: .same, lastWeekCents: 4000), "equal weeks")
        check([entry("2026-10-12", 1000), entry("2026-10-26", 4000)],
              RichStats.Versus(differenceCents: 4000, direction: .up, lastWeekCents: 0), "last week empty but counted")
        check([entry("2026-10-26", 4000)], nil, "the first data week is the current week")
        check([entry("2026-10-19", 1000), entry("2026-10-26", 4000)],
              RichStats.Versus(differenceCents: 3000, direction: .up, lastWeekCents: 1000), "the first data week is last week")
    }

    // MARK: T03 kind slices

    func testRICHSTATS_T03_KindSlicesKeepTheStoredTextFoldPastFourAndPutOtherLast() {
        XCTAssertEqual(build(thisWeekEntries()).slices,
                       [RichStats.Slice(label: "Dining", cents: 4200, isOther: false),
                        RichStats.Slice(label: "Delivery", cents: 2250, isOther: false),
                        RichStats.Slice(label: "Other", cents: 7350, isOther: true)],
                       "Other is last though it is the largest")

        let week = "2026-10-26"
        let many = [entry(week, 900, estimate: true, kind: "Delta"), entry(week, 500, estimate: true, kind: "Alpha"),
                    entry(week, 500, estimate: true, kind: "Beta"), entry(week, 300, estimate: true, kind: "Gamma"),
                    entry(week, 100, estimate: true, kind: "Epsilon"), entry(week, 50, estimate: true, kind: "Other"),
                    entry(week, 70, estimate: true, kind: "9lives"), entry(week, 30)]
        XCTAssertEqual(build(many).slices,
                       [RichStats.Slice(label: "Delta", cents: 900, isOther: false),
                        RichStats.Slice(label: "Alpha", cents: 500, isOther: false),
                        RichStats.Slice(label: "Beta", cents: 500, isOther: false),
                        RichStats.Slice(label: "Gamma", cents: 300, isOther: false),
                        RichStats.Slice(label: "Other", cents: 250, isOther: true)],
                       "four named, the rest and the stored Other and the ill-formed kind and the none joined in Other")

        XCTAssertEqual(build([entry(week, 100, estimate: true, kind: "Dining"), entry(week, 200, estimate: true, kind: "dining")]).slices,
                       [RichStats.Slice(label: "dining", cents: 200, isOther: false),
                        RichStats.Slice(label: "Dining", cents: 100, isOther: false)],
                       "case makes two slices")

        XCTAssertEqual(build([entry(week, 500, estimate: true, kind: "Dining"), entry(week, 0, estimate: true, kind: "Alpha")]).slices,
                       [RichStats.Slice(label: "Dining", cents: 500, isOther: false)],
                       "a kind of 0 cents is not a slice, and there is no empty Other")

        XCTAssertEqual(build([]).slices, [])
    }

    // MARK: T04 by day

    func testRICHSTATS_T04_ByDayIsMondayFirstLeavesOutEntriesWithNoValidDayAndMarksToday() {
        let week = "2026-10-26"
        let entries = [entry(week, 2400, day: "2026-10-26"), entry(week, 4200, day: "2026-10-28"), entry(week, 3150, day: "2026-10-29"),
                       entry(week, 2250, day: "2026-10-30"), entry(week, 600, day: "2026-11-01"), entry(week, 1800),
                       entry(week, 500, day: "2026-11-02"), entry(week, 700, day: "2026/10/27"), entry(week, 900, day: "2026-10-25")]
        let stats = build(entries)
        XCTAssertEqual(stats.days?.map(\.letter), ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(stats.days?.map(\.cents), [2400, 0, 4200, 3150, 2250, 0, 600])
        XCTAssertEqual(stats.days?.map(\.isToday), [false, true, false, false, false, false, false])
        XCTAssertEqual(stats.slices.reduce(0) { $0 + $1.cents }, 16500, "every entry counts in the ring, valid day or not")

        let noValidDay = build([entry(week, 100), entry(week, 200, day: "2026/10/27"), entry(week, 300, day: "2026-11-02")])
        XCTAssertNil(noValidDay.days)
    }

    // MARK: T05 top partners

    func testRICHSTATS_T05_TopPartnersGroupByStoredNameOverTheEightWeekWindow() {
        let tables = "Example Tables"
        let delivery = "Example Delivery"
        let entries = [entry("2026-09-14", 6375, estimate: true, name: tables), entry("2026-09-28", 4100, estimate: true, name: tables),
                       entry("2026-10-12", 9000, estimate: true, name: tables), entry("2026-10-26", 5000, estimate: true, name: tables),
                       entry("2026-11-02", 4200, estimate: true, name: tables),
                       entry("2026-09-21", 8625, estimate: true, name: delivery), entry("2026-10-19", 5000, estimate: true, name: delivery),
                       entry("2026-11-02", 2250, estimate: true, name: delivery),
                       entry("2026-10-05", 1800), entry("2026-11-02", 2000),
                       entry("2026-09-07", 7777, estimate: true, name: tables),
                       entry("2026-11-09", 3000, estimate: true, name: delivery),
                       entry("2026-11-02", 999, estimate: true, name: "")]
        let partners = build(entries, now: tuesdayAfterClockChange).partners
        XCTAssertEqual(partners.map(\.name), [tables, delivery])
        XCTAssertEqual(partners.map(\.cents), [28675, 15875])
        XCTAssertEqual(partners.map(\.fraction).count, 2)
        if partners.count == 2 {
            XCTAssertEqual(partners[0].fraction, 1.0, accuracy: 0.000_001)
            XCTAssertEqual(partners[1].fraction, 15875.0 / 28675.0, accuracy: 0.000_001)
        }

        let four = ["A", "B", "C", "D"].enumerated().map { entry("2026-11-02", ($0.offset + 1) * 100, estimate: true, name: $0.element) }
        XCTAssertEqual(build(four, now: tuesdayAfterClockChange).partners.map(\.name), ["D", "C", "B"], "at most three rows")

        let tie = [entry("2026-11-02", 500, estimate: true, name: "Beta"), entry("2026-11-02", 500, estimate: true, name: "Alpha")]
        XCTAssertEqual(build(tie, now: tuesdayAfterClockChange).partners.map(\.name), ["Alpha", "Beta"], "a tie goes to the smaller name")
    }

    // MARK: T06 trends weeks

    func testRICHSTATS_T06_TrendsWeeksAreEightMondaysOldestFirstAcrossTheClockChange() {
        let labels = ["9/14", "9/21", "9/28", "10/5", "10/12", "10/19", "10/26", "11/2"]
        let starts = ["2026-09-14", "2026-09-21", "2026-09-28", "2026-10-05", "2026-10-12", "2026-10-19", "2026-10-26", "2026-11-02"]
        let entries = mockupWeeks.map { entry($0.0, $0.1) }
        let stats = build(entries, now: tuesdayAfterClockChange)
        XCTAssertEqual(stats.weeks.map(\.label), labels)
        XCTAssertEqual(stats.weeks.map(\.weekStart), starts)
        XCTAssertEqual(stats.weeks.map(\.cents), [18375, 23625, 17125, 11250, 20500, 15750, 16250, 13800])
        XCTAssertEqual(stats.weeks.map(\.isOver), [false, true, false, false, true, false, false, false])
        XCTAssertEqual(stats.weeks.map(\.isCurrent), [false, false, false, false, false, false, false, true])
        XCTAssertEqual(stats.weeks.map(\.hasBar), [Bool](repeating: true, count: 8))
        XCTAssertEqual(stats.budgetCents, 20000)
        XCTAssertEqual(stats.budgetText, "$200.00")
        XCTAssertEqual(stats.halfBudgetText, "$100.00")

        var exact = mockupWeeks.map { entry($0.0, $0.1) }
        exact[0] = entry("2026-09-14", 20000)
        XCTAssertEqual(build(exact, now: tuesdayAfterClockChange).weeks.first?.isOver, false, "exactly the budget is not over")

        let fromOctober12 = mockupWeeks.filter { $0.0 >= "2026-10-12" }.map { entry($0.0, $0.1) }
        let late = build(fromOctober12, now: tuesdayAfterClockChange)
        XCTAssertEqual(late.weeks.map(\.hasBar), [false, false, false, false, true, true, true, true])
        XCTAssertEqual(late.weeks.map(\.isCounted), [false, false, false, false, true, true, true, false])

        XCTAssertEqual(build([entry("2026-11-09", 3000)], now: tuesdayAfterClockChange).weeks, [], "a future entry alone gives no week")

        let smaller = build(entries, now: tuesdayAfterClockChange, budget: 15000)
        XCTAssertEqual(smaller.budgetCents, 15000)
        XCTAssertEqual(smaller.budgetText, "$150.00")
        XCTAssertEqual(smaller.halfBudgetText, "$75.00")
        XCTAssertEqual(smaller.weeks.map(\.isOver), [true, true, true, false, true, true, true, false], "over follows the budget handed in")
        XCTAssertEqual(build(entries, now: tuesdayAfterClockChange, budget: 15001).halfBudgetText, "$75.01", "half rounds up")
    }

    // MARK: T07 trends stats

    func testRICHSTATS_T07_TrendsStatsCountCompletedWeeksFromTheFirstDataWeek() {
        let now = tuesdayAfterClockChange
        let split: [(String, Int, Int)] = [("2026-09-14", 12000, 6375), ("2026-09-21", 15000, 8625), ("2026-09-28", 13025, 4100),
                                           ("2026-10-05", 11250, 0), ("2026-10-12", 11500, 9000), ("2026-10-19", 10750, 5000),
                                           ("2026-10-26", 11250, 5000)]
        var entries: [BudgetEntry] = []
        for (week, stated, estimated) in split {
            entries.append(entry(week, stated))
            if estimated > 0 { entries.append(entry(week, estimated, estimate: true)) }
        }
        entries.append(entry("2026-11-02", 3801))
        entries.append(entry("2026-11-02", 9999, estimate: true))
        XCTAssertEqual(build(entries, now: now).summary,
                       RichStats.Summary(averageCents: 17554, underCount: 5, countedWeeks: 7, estimatePercent: 31,
                                         lowest: RichStats.Pick(cents: 11250, label: "Oct 5"),
                                         highest: RichStats.Pick(cents: 23625, label: "Sep 21")),
                       "seven completed weeks; the current week's estimate of 9999 is not counted")

        let gap = [entry("2026-10-12", 9000), entry("2026-10-26", 6000), entry("2026-11-02", 100)]
        let gapSummary = build(gap, now: now).summary
        XCTAssertEqual(gapSummary?.countedWeeks, 3, "the empty week 10/19 counts as 0")
        XCTAssertEqual(gapSummary?.averageCents, 5000)
        XCTAssertEqual(gapSummary?.lowest, RichStats.Pick(cents: 0, label: "Oct 19"))

        let tie = [("2026-09-14", 18000), ("2026-09-21", 12000), ("2026-09-28", 14000), ("2026-10-05", 10000), ("2026-10-12", 15000),
                   ("2026-10-19", 10000), ("2026-10-26", 13000)].map { entry($0.0, $0.1) }
        XCTAssertEqual(build(tie, now: now).summary?.lowest, RichStats.Pick(cents: 10000, label: "Oct 19"), "a tie goes to the more recent week")

        let halfUp = build([entry("2026-10-12", 100), entry("2026-10-19", 101)]).summary
        XCTAssertEqual(halfUp?.countedWeeks, 2)
        XCTAssertEqual(halfUp?.averageCents, 101, "100.5 rounds up")

        let percent = build([entry("2026-10-12", 37), entry("2026-10-12", 63, estimate: true), entry("2026-10-19", 100)]).summary
        XCTAssertEqual(percent?.estimatePercent, 32, "31.5 rounds up")

        let old = build([entry("2026-08-31", 1000)], now: now).summary
        XCTAssertEqual(old?.countedWeeks, 7, "a first data week before the window counts all seven completed weeks")
        XCTAssertEqual(old?.averageCents, 0)
        XCTAssertEqual(old?.underCount, 7)
        XCTAssertNil(old?.estimatePercent)
        XCTAssertEqual(old?.lowest, RichStats.Pick(cents: 0, label: "Oct 26"))
        XCTAssertEqual(old?.highest, RichStats.Pick(cents: 0, label: "Oct 26"))

        XCTAssertNil(build([entry("2026-11-02", 5000)], now: now).summary, "only the current week: nothing completed is counted")
    }

    // MARK: T08 entries

    func testRICHSTATS_T08_EntriesGroupEveryWeekNewestFirstWithTotalsAndTags() {
        let entries = [entry("2026-10-19", 4800), entry("2026-10-26", 2400), entry("2026-10-19", 4150, estimate: true),
                       entry("2026-10-26", 4200, estimate: true), entry("2026-11-02", 3000, estimate: true), entry("bad-week", 100)]
        let groups = build(entries).groups
        XCTAssertEqual(groups.map(\.weekStart), ["2026-11-02", "2026-10-26", "2026-10-19"], "newest week first; the malformed week is nowhere")
        XCTAssertEqual(groups.map(\.title), ["Week of Nov 2", "Week of Oct 26", "Week of Oct 19"])
        XCTAssertEqual(groups.map(\.totalText), ["$30.00 / $200.00", "$66.00 / $200.00", "$89.50 / $200.00"])
        XCTAssertEqual(groups.map { texts($0.rows) }, [["$30.00 Estimate"], ["$42.00 Estimate", "$24.00 Stated"],
                                                         ["$41.50 Estimate", "$48.00 Stated"]], "rows newest first")

        XCTAssertEqual(build([entry("2026-12-28", 1000)]).groups.map(\.title), ["Week of Dec 28"])
        XCTAssertEqual(build([]).groups, [])
    }

    // MARK: T09 pure function and the empty ledger

    func testRICHSTATS_T09_TheBuilderIsAPureFunctionAndAnEmptyLedgerStillHasItsWeekAndBudget() {
        let entries = thisWeekEntries()
        XCTAssertEqual(build(entries), build(entries), "the same inputs give equal values")

        let sundayEvening = TestClock.date("2026-11-01T20:00")
        XCTAssertEqual(build([], now: sundayEvening, zone: "America/Los_Angeles").weekTitle, "Week of Oct 26")
        XCTAssertEqual(build([], now: sundayEvening, zone: "Asia/Tokyo").weekTitle, "Week of Nov 2", "Monday 13:00 there")

        let empty = build([], now: TestClock.now, zone: "America/Los_Angeles", budget: 20000)
        XCTAssertEqual(empty.weekTitle, "Week of Oct 26")
        XCTAssertEqual(empty.budgetCents, 20000)
        XCTAssertEqual(empty.budgetText, "$200.00")
        XCTAssertEqual(empty.halfBudgetText, "$100.00")
        XCTAssertEqual(empty.recordCount, 0)
        XCTAssertEqual(empty.estimatesText, "0 estimates")
        XCTAssertEqual(empty.statedCents, 0)
        XCTAssertEqual(empty.estimateCents, 0)
        XCTAssertEqual(empty.latest, [])
        XCTAssertEqual(empty.slices, [])
        XCTAssertEqual(empty.partners, [])
        XCTAssertEqual(empty.weeks, [])
        XCTAssertEqual(empty.groups, [])
        XCTAssertNil(empty.versus)
        XCTAssertNil(empty.days)
        XCTAssertNil(empty.summary)
    }

    // MARK: T16 the hero

    func testRICHSTATS_T16_TheHeroIsTheFigureWithLeftOrOverABusyMarkOrNothing() {
        func standing(spent: Int, left: Int, within: Bool) -> BudgetStanding {
            BudgetStanding(weekStart: "2026-10-26", budgetCents: 20000, spentCents: spent, leftCents: left, isWithin: within,
                           includesEstimate: false)
        }
        let within = standing(spent: 13800, left: 6200, within: true)
        XCTAssertEqual(RichStats.hero(standing: within, isBusy: false),
                       RichStats.Hero.figure(amountText: "$62.00", word: "left", spentLine: "$138.00 of $200.00 spent", isOver: false))
        XCTAssertEqual(RichStats.hero(standing: standing(spent: 22800, left: -2800, within: false), isBusy: false),
                       RichStats.Hero.figure(amountText: "$28.00", word: "over", spentLine: "$228.00 of $200.00 spent", isOver: true))
        XCTAssertEqual(RichStats.hero(standing: standing(spent: 20000, left: 0, within: true), isBusy: false),
                       RichStats.Hero.figure(amountText: "$0.00", word: "left", spentLine: "$200.00 of $200.00 spent", isOver: false))
        XCTAssertEqual(RichStats.hero(standing: within, isBusy: true),
                       RichStats.Hero.figure(amountText: "$62.00", word: "left", spentLine: "$138.00 of $200.00 spent", isOver: false),
                       "the figure stays while a request runs")
        XCTAssertEqual(RichStats.hero(standing: nil, isBusy: true), RichStats.Hero.busy)
        XCTAssertEqual(RichStats.hero(standing: nil, isBusy: false), RichStats.Hero.none)
    }
}
