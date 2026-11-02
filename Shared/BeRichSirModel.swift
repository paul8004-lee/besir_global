import Combine
import Foundation

/// The state of the be rich sir screen (SPEC-RICHHAND-001). All state is in memory; nothing is written by this model.
@MainActor
final class BeRichSirModel: ObservableObject {
    enum Problem: Equatable {
        case amount, notSetUp, offline, unreachable

        init(_ failure: BudgetFailure) {
            switch failure {
            case .notSetUp: self = .notSetUp
            case .offline: self = .offline
            case .tokenRejected, .other: self = .unreachable
            }
        }

        /// The fixed line of the problem.
        var line: String {
            switch self {
            case .amount: return "Enter an amount from 0.01 to 10000.00."
            case .notSetUp: return "Budget is not set up."
            case .offline: return "You are offline."
            case .unreachable: return "Budget could not be reached."
            }
        }
    }

    @Published private(set) var standing: BudgetStanding?
    @Published private(set) var rows: [BudgetEntry] = []
    @Published private(set) var problem: Problem?
    @Published private(set) var isBusy = false
    @Published var amountText = ""
    /// The statistics of the four tabs (SPEC-RICHSTATS-001): rebuilt from the ledger wherever the rows are.
    @Published private(set) var stats: RichStats

    private let desk: BudgetDesk
    private let now: () -> Date
    private let zone: () -> TimeZone
    private var subscription: AnyCancellable?
    /// The number of the latest request the model started; it guards the figure and the problem only.
    private var sequence = 0
    /// How many requests are in flight; `isBusy` is true while it is above zero.
    private var running = 0

    init(desk: BudgetDesk, now: @escaping () -> Date = { Date() }, zone: @escaping () -> TimeZone = { TimeZone.current }) {
        self.desk = desk
        self.now = now
        self.zone = zone
        self.stats = Self.makeStats(desk: desk, now: now(), zone: zone())
    }

    /// The one place the stats are made, and the model's one read of the weekly budget; `init` and `refreshStats()` both use it.
    private static func makeStats(desk: BudgetDesk, now: Date, zone: TimeZone) -> RichStats {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return RichStats.build(entries: desk.allEntries(), now: now, calendar: calendar, budgetCents: BudgetDesk.weeklyBudgetCents)
    }

    /// Subscribes once to the ledger's changes. The ledger posts while it holds its lock, so the event hops to the main queue
    /// before anything reads the ledger.
    func start() {
        guard subscription == nil else { return }
        subscription = desk.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor [weak self] in await self?.ledgerChanged() }
            }
    }

    func appear() async {
        start()
        problem = nil
        standing = nil
        refreshRows()
        refreshStats()
        let number = begin()
        if await ask(number: number) { await settle() }
        finish()
    }

    func record() async {
        guard !isBusy else { return }
        guard let plan = BudgetDesk.spendPlan(amountText: amountText, now: now(), zone: zone()) else {
            problem = .amount
            return
        }
        let number = begin()
        problem = nil
        let answer = await desk.send(plan, flow: ConnectionLog.beginFlow())
        var applied = false
        switch answer {
        case .success(let figure):
            amountText = ""
            refreshRows()
            refreshStats()
            if number == sequence {
                standing = figure
                applied = true
            }
        case .failure(let failure):
            if number == sequence { problem = Problem(failure) }
        }
        if applied { await settle() }
        finish()
    }

    func ledgerChanged() async {
        refreshRows()
        refreshStats()
        guard !isBusy, ledgerDiffersFromStanding() else { return }
        let number = begin()
        if await ask(number: number) { await settle() }
        finish()
    }

    private func begin() -> Int {
        running += 1
        isBusy = true
        return nextNumber()
    }

    private func finish() {
        running -= 1
        if running == 0 { isBusy = false }
    }

    private func nextNumber() -> Int {
        sequence += 1
        return sequence
    }

    private func currentWeek() -> String {
        BudgetDesk.week(now: now(), zone: zone())
    }

    /// The current week's entries, newest first.
    private func refreshRows() {
        let fresh = Array(desk.weekEntries(weekStart: currentWeek()).reversed())
        if fresh != rows { rows = fresh }
    }

    /// The stats of the whole ledger at this moment; nothing is kept from an earlier build.
    private func refreshStats() {
        let fresh = Self.makeStats(desk: desk, now: now(), zone: zone())
        if fresh != stats { stats = fresh }
    }

    private func ledgerDiffersFromStanding() -> Bool {
        guard let standing else { return false }
        return standing.weekStart != currentWeek() || rows.reduce(0, { $0 + $1.amountCents }) != standing.spentCents
    }

    /// One left request. True when its figure was applied. A request that is no longer the latest applies nothing, and a
    /// failure sets the problem and asks nothing more.
    private func ask(number: Int) async -> Bool {
        let answer = await desk.askLeft(weekStart: currentWeek(), flow: ConnectionLog.beginFlow())
        guard number == sequence else { return false }
        switch answer {
        case .success(let figure):
            standing = figure
            if problem != .amount { problem = nil }
            return true
        case .failure(let failure):
            problem = Problem(failure)
            return false
        }
    }

    /// After an exact answer was applied: asks again while the ledger's rows still disagree with the figure.
    private func settle() async {
        while true {
            refreshRows()
            refreshStats()
            guard ledgerDiffersFromStanding() else { return }
            guard await ask(number: nextNumber()) else { return }
        }
    }
}
