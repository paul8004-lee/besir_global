import Combine
import Foundation

/// One stated spend, made together: the cents, the week and the request id (SPEC-RICHHAND-001). Skeleton of card t103 M1.
struct BudgetSpendPlan: Equatable {
    let cents: Int
    let weekStart: String
    let requestID: String
}

/// The one neutral home of the budget steps both the chat's tools and the be rich sir screen use. Skeleton of card t103 M1:
/// every member answers with an empty value until M2.
struct BudgetDesk {
    let client: BudgetClient

    init(client: BudgetClient) {
        self.client = client
    }

    static func week(now: Date, zone: TimeZone) -> String { "" }

    static func spendPlan(amountText: String, now: Date, zone: TimeZone,
                          requestID: String = UUID().uuidString) -> BudgetSpendPlan? { nil }

    var isConfigured: Bool { false }

    func askLeft(weekStart: String, flow: UUID) async -> Result<BudgetStanding, BudgetFailure> { .failure(.other) }

    func send(_ plan: BudgetSpendPlan, flow: UUID) async -> Result<BudgetStanding, BudgetFailure> { .failure(.other) }

    func weekEntries(weekStart: String) -> [BudgetEntry] { [] }

    var changes: AnyPublisher<Void, Never> { Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher() }
}
