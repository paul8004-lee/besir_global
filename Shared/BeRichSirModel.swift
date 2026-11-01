import Combine
import Foundation

/// The state of the be rich sir screen (SPEC-RICHHAND-001). Skeleton of card t103 M1: the members exist and do nothing.
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

    private let desk: BudgetDesk
    private let now: () -> Date
    private let zone: () -> TimeZone

    init(desk: BudgetDesk, now: @escaping () -> Date = { Date() }, zone: @escaping () -> TimeZone = { TimeZone.current }) {
        self.desk = desk
        self.now = now
        self.zone = zone
    }

    func start() {}

    func appear() async {}

    func record() async {}

    func ledgerChanged() async {}
}
