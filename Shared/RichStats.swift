import Foundation

/// SPEC-RICHSTATS-001 (card t116): the statistics of the be rich sir screen as one pure value. Foundation only: it reads no clock,
/// no process, no environment and no view; the instant, the calendar and the budget are handed in.
///
/// This is the skeleton of milestone M1: the types are final, `build` gives a blank value and `hero` gives `.none`, so the red
/// tests can compile and fail on their assertions. The rules of design.md section 3 arrive in milestone M4.
struct RichStats: Equatable {
    /// The statistics of `entries` at `now` in `calendar`'s zone, for a weekly budget of `budgetCents`.
    static func build(entries: [BudgetEntry], now: Date, calendar: Calendar, budgetCents: Int) -> RichStats {
        RichStats(weekTitle: "", budgetCents: 0, budgetText: "", halfBudgetText: "",
                  statedCents: 0, estimateCents: 0, recordCount: 0, estimateCount: 0, estimatesText: "", versus: nil, latest: [],
                  slices: [], days: nil, partners: [],
                  weeks: [], summary: nil,
                  groups: [])
    }

    /// The figure of This week, from the screen model's standing and busy state.
    static func hero(standing: BudgetStanding?, isBusy: Bool) -> Hero {
        .none
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
}
