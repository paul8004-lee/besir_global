import Foundation

/// Why a budget request did not give an answer. No text of the server's answer is kept for any of them.
enum BudgetFailure: Error, Equatable {
    case notSetUp, offline, tokenRejected, other
}

/// What the week looks like after an answer: whole cents, and whether the week is within the budget.
struct BudgetStanding: Equatable {
    /// The Monday of the week, `yyyy-MM-dd`.
    let weekStart: String
    let budgetCents: Int
    let spentCents: Int
    /// Negative when the week is over the budget.
    let leftCents: Int
    let isWithin: Bool
    /// True when any entry of the week in the ledger is an estimate.
    let includesEstimate: Bool
}

/// One `POST /budget` through the configuration's single request builder (SPEC-BUDGET-001). Built per call from the live
/// configuration; it owns no URL session, the caller hands in `send`. The ledger's total goes out as `spent_cents`, and a
/// spend is written to the ledger only after an exact answer.
final class BudgetClient {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    /// The simulated partner's name: the app's one literal for it.
    static let partnerName = "Example Budget"
    /// The partner's fixed weekly dining budget: $200.00, in cents.
    static let weeklyBudgetCents = 20000

    private static let path = "/budget"
    private static let timeout: TimeInterval = 20

    /// What one request carried, as the answer has to echo it.
    struct Sent: Equatable {
        enum Operation: String { case left, spend }
        let operation: Operation
        let weekStart: String
        /// The ledger's total for the week at the moment of the call, before any amount of this request.
        let spentCents: Int
        /// The amount of a `spend`; nil for `left`.
        let amountCents: Int?
    }

    private let config: AppConfig
    private let ledger: BudgetLedger
    private let send: Send
    private let connections: ConnectionLog

    init(config: AppConfig, ledger: BudgetLedger = BudgetLedger.shared, send: @escaping Send,
         connections: ConnectionLog = ConnectionLog.shared) {
        self.config = config
        self.ledger = ledger
        self.send = send
        self.connections = connections
    }

    var isConfigured: Bool { config.hasProxy }

    /// How the week stands, from the ledger's total for `weekStart`. Records the packets of the exchange under `flow`.
    func left(weekStart: String, flow: UUID) async -> Result<BudgetStanding, BudgetFailure> {
        guard config.hasProxy else { return .failure(.notSetUp) }
        let sent = Sent(operation: .left, weekStart: weekStart, spentCents: ledger.spentCents(weekStart: weekStart), amountCents: nil)
        return await run(sent, requestID: nil, isEstimate: false, flow: flow)
    }

    /// Tells the partner about one amount and, after an exact answer, adds it to the ledger once. A request id that is already
    /// in the ledger sends nothing and fails as `other`.
    func spend(amountCents: Int, isEstimate: Bool, weekStart: String, requestID: String,
               flow: UUID) async -> Result<BudgetStanding, BudgetFailure> {
        guard config.hasProxy else { return .failure(.notSetUp) }
        guard !ledger.contains(requestID: requestID) else { return .failure(.other) }
        let sent = Sent(operation: .spend, weekStart: weekStart, spentCents: ledger.spentCents(weekStart: weekStart),
                        amountCents: amountCents)
        return await run(sent, requestID: requestID, isEstimate: isEstimate, flow: flow)
    }

    private func run(_ sent: Sent, requestID: String?, isEstimate: Bool, flow: UUID) async -> Result<BudgetStanding, BudgetFailure> {
        var fields: [String: Any] = ["op": sent.operation.rawValue, "week_start": sent.weekStart, "spent_cents": sent.spentCents]
        if let amount = sent.amountCents, let requestID {
            fields["amount_cents"] = amount
            fields["request_id"] = requestID
        }
        guard !Task.isCancelled,
              let body = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let urlRequest = config.proxyPOSTRequest(Self.path, body: body, timeout: Self.timeout) else { return .failure(.other) }
        let result = await exchange(urlRequest, sent: sent)
        // A cancelled task writes and records nothing: the outcome is not known.
        guard !Task.isCancelled else { return .failure(.other) }
        var outcome = result
        if case .success(let standing) = result {
            if let amount = sent.amountCents, let requestID {
                ledger.add(BudgetEntry(requestID: requestID, weekStart: sent.weekStart, amountCents: amount, isEstimate: isEstimate))
            }
            // Read after the write, so a spend that was just added counts.
            outcome = .success(BudgetStanding(weekStart: standing.weekStart, budgetCents: standing.budgetCents,
                                              spentCents: standing.spentCents, leftCents: standing.leftCents,
                                              isWithin: standing.isWithin,
                                              includesEstimate: ledger.hasEstimate(weekStart: sent.weekStart)))
        }
        note(outcome, sent: sent, flow: flow)
        return outcome
    }

    private func exchange(_ urlRequest: URLRequest, sent: Sent) async -> Result<BudgetStanding, BudgetFailure> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(urlRequest)
        } catch {
            return .failure(AgentClient.transportError(for: error) == .offline ? .offline : .other)
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.other) }
        switch http.statusCode {
        case 200:
            return Self.answer(from: data, sent: sent).map { .success($0) } ?? .failure(.other)
        case 401:
            return .failure(Self.isUnauthorizedBody(data) ? .tokenRejected : .other)
        default:
            return .failure(.other)
        }
    }

    /// The summaries hold fixed words only: never an amount, the week, the request id or any answer text.
    private func note(_ result: Result<BudgetStanding, BudgetFailure>, sent: Sent, flow: UUID) {
        switch result {
        case .success:
            let isSpend = sent.operation == .spend
            connections.record(from: .besir, to: .budgetPartner, kind: .budget,
                               summary: isSpend ? "Spend sent" : "Budget left asked", status: .ok, flowID: flow)
            // A week over the budget is a normal answer, not a failure.
            connections.record(from: .budgetPartner, to: .besir, kind: .budget,
                               summary: isSpend ? "Spend recorded" : "Budget left answered", status: .ok, flowID: flow)
        case .failure(let failure):
            // A request that was never sent (no proxy) returned before this point.
            guard failure != .notSetUp else { return }
            connections.record(from: .besir, to: .budgetPartner, kind: .budget,
                               summary: "Request failed", status: .failed, flowID: flow)
        }
    }

    // MARK: The answer is checked

    /// Accepts only the exact object the route sends: eight keys for `left`, nine for `spend`, the partner, `simulated` true,
    /// the echoes equal to what was sent, the fixed budget, and a `left_cents` and a `status` that agree with the total.
    /// `includesEstimate` is not in the answer, so it comes back false here; the client reads it from the ledger.
    static func answer(from data: Data, sent: Sent) -> BudgetStanding? {
        let isSpend = sent.operation == .spend
        let spent = sent.spentCents + (isSpend ? (sent.amountCents ?? 0) : 0)
        let left = weeklyBudgetCents - spent
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object.count == (isSpend ? 9 : 8),
              object["partner"] as? String == partnerName,
              isTrue(object["simulated"]),
              object["op"] as? String == sent.operation.rawValue,
              object["week_start"] as? String == sent.weekStart,
              isNumber(object["spent_cents"], equalTo: spent),
              isNumber(object["budget_cents"], equalTo: weeklyBudgetCents),
              isNumber(object["left_cents"], equalTo: left),
              object["status"] as? String == (left >= 0 ? "within" : "over") else { return nil }
        if isSpend {
            guard let amount = sent.amountCents, isNumber(object["amount_cents"], equalTo: amount) else { return nil }
        }
        return BudgetStanding(weekStart: sent.weekStart, budgetCents: weeklyBudgetCents, spentCents: spent, leftCents: left,
                              isWithin: left >= 0, includesEstimate: false)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, isBoolean(number) else { return false }
        return number.boolValue
    }

    /// A JSON number equal to `expected`; `2.0` counts as 2 and a boolean is never a number.
    private static func isNumber(_ value: Any?, equalTo expected: Int) -> Bool {
        guard let number = value as? NSNumber, !isBoolean(number) else { return false }
        return number.doubleValue == Double(expected)
    }

    /// The Worker's own rejection of a wrong app token: exactly `{"error":"unauthorized"}`.
    private static func isUnauthorizedBody(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 1 else { return false }
        return object["error"] as? String == "unauthorized"
    }
}
