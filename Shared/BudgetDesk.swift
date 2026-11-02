import Combine
import Foundation

/// One stated spend, made together: the cents, the week and the request id (SPEC-RICHHAND-001).
struct BudgetSpendPlan: Equatable {
    let cents: Int
    let weekStart: String
    let requestID: String
    /// The day of the same `now` the week came from, `yyyy-MM-dd`; it goes into the ledger entry only (SPEC-RICHSTATS-001).
    var day: String? = nil
}

/// The one neutral home of the budget steps both the chat's tools and the be rich sir screen use. It builds no JSON for a
/// model and no sentence for a user, and imports no UI.
struct BudgetDesk {
    let client: BudgetClient

    init(client: BudgetClient) {
        self.client = client
    }

    /// The one `BudgetClient` the app builds: its own ephemeral session, as the chat's tools have always used.
    static func makeClient(config: AppConfig) -> BudgetClient {
        BudgetClient(config: config, send: { try await URLSession(configuration: .ephemeral).data(for: $0) })
    }

    static func live(config: AppConfig) -> BudgetDesk {
        BudgetDesk(client: makeClient(config: config))
    }

    /// The weekly budget in cents: the client's one constant, forwarded so the screen reads it through the desk.
    static let weeklyBudgetCents = BudgetClient.weeklyBudgetCents

    static func week(now: Date, zone: TimeZone) -> String {
        BudgetWeek.start(of: now, in: zone)
    }

    /// The cents, the week of `now` in `zone` and the request id of one stated spend, or nil when the amount text is refused
    /// by `AgentBudget.parseAmountCents`.
    static func spendPlan(amountText: String, now: Date, zone: TimeZone,
                          requestID: String = UUID().uuidString) -> BudgetSpendPlan? {
        guard let cents = AgentBudget.parseAmountCents(amountText) else { return nil }
        return BudgetSpendPlan(cents: cents, weekStart: week(now: now, zone: zone), requestID: requestID,
                               day: BudgetWeek.day(of: now, in: zone))
    }

    var isConfigured: Bool { client.isConfigured }

    func askLeft(weekStart: String, flow: UUID) async -> Result<BudgetStanding, BudgetFailure> {
        await client.left(weekStart: weekStart, flow: flow)
    }

    func send(_ plan: BudgetSpendPlan, flow: UUID) async -> Result<BudgetStanding, BudgetFailure> {
        await client.spend(amountCents: plan.cents, isEstimate: false, weekStart: plan.weekStart, requestID: plan.requestID,
                           flow: flow, day: plan.day)
    }

    func weekEntries(weekStart: String) -> [BudgetEntry] {
        client.weekEntries(weekStart: weekStart)
    }

    func allEntries() -> [BudgetEntry] {
        client.allEntries()
    }

    var changes: AnyPublisher<Void, Never> { client.changes }
}
