import Combine
import Foundation

/// The state of the be rich sir screen (SPEC-RICHHAND-001). Skeleton of card t103 M1: the members exist and do nothing.
@MainActor
final class BeRichSirModel: ObservableObject {
    enum Problem: Equatable {
        case amount, notSetUp, offline, unreachable

        /// The fixed line of the problem (skeleton: empty until M2).
        var line: String { "" }
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
