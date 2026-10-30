import Foundation

/// SPEC-BUDGET-001: the pure helpers of the `get_budget_left` and `record_spend` tools and of the partner request hook, so what decides
/// and what is said is testable without the toolbox. Money is whole cents (`Int`) everywhere; dollars appear only in text.
enum AgentBudget {
    /// The largest amount `record_spend` takes: $10,000.00.
    static let maxAmountCents = 1_000_000

    // MARK: Fixed result texts

    static let leftMessage = "State the amount left or over as a fact and say it comes from a simulated budget app. If includes_estimate is true, say it includes estimated spending. Give no advice."
    static let leftUnavailableMessage = "The simulated budget app could not be reached. Tell the user the budget left is not available right now."
    static let spendMessage = "State the amount recorded and the amount left or over as facts in one line and say it comes from a simulated budget app. If includes_estimate is true, say it includes estimated spending. Give no advice."
    static let spendUnavailableMessage = "The simulated budget app could not record the spend. Tell the user the spend could not be recorded and that nothing was added."

    // MARK: Partner request hook texts

    static let bookingRecordedSentence = "Tell the user the estimated spend sent to the simulated budget app and the amount left or over, as facts and as estimates. Do not call record_spend for this request."
    static let bookingUnavailableSentence = "The estimated spend could not be sent to the simulated budget app. Tell the user so, and do not call record_spend for this request."
    static let bookingFailureNotice = "The estimated spend could not be sent to \(partnerLabel)."
    static let spendFailureNotice = "The spend could not be recorded in \(partnerLabel)."

    /// The partner as the user reads it. Built from the one literal of the app.
    static var partnerLabel: String { "\(BudgetClient.partnerName) (Simulated)" }

    // MARK: Arguments

    /// 1 to 5 ASCII digits, optionally followed by `.` and 1 or 2 ASCII digits; no sign, space, comma or currency sign. The
    /// value is 0.01 to 10000.00 and is converted to cents by integer arithmetic (leading zeros are allowed: `00018` is 18).
    static func parseAmountCents(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        var whole: [UInt8] = bytes
        var fraction: [UInt8] = []
        if let dot = bytes.firstIndex(of: 0x2E) {
            whole = Array(bytes[..<dot])
            fraction = Array(bytes[(dot + 1)...])
            guard (1...2).contains(fraction.count) else { return nil }
        }
        guard (1...5).contains(whole.count), (whole + fraction).allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        let dollars = whole.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        var cents = 0
        for (index, digit) in fraction.enumerated() { cents += Int(digit - 0x30) * (index == 0 ? 10 : 1) }
        let total = dollars * 100 + cents
        return (1...maxAmountCents).contains(total) ? total : nil
    }

    // MARK: Text of amounts and weeks

    /// `$1,234.50`, from integer parts. A negative amount reads `-$1.00`.
    static func dollars(cents: Int) -> String {
        let whole = cents.magnitude / 100
        let fraction = cents.magnitude % 100
        let digits = Array(String(whole))
        var grouped = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        return (cents < 0 ? "-$" : "$") + grouped + "." + (fraction < 10 ? "0" : "") + String(fraction)
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `this week` when the week is the current one, else `week of MMM d` (`week of Nov 2`), read from the `yyyy-MM-dd` text.
    static func weekPhrase(weekStart: String, currentWeekStart: String) -> String {
        if weekStart == currentWeekStart { return "this week" }
        let parts = weekStart.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return "that week" }
        return "week of \(months[parts[1] - 1]) \(parts[2])"
    }

    /// The week phrase as it sits in a sentence: `this week` or `for the week of Nov 2`.
    static func inWeek(_ phrase: String) -> String {
        phrase == "this week" ? phrase : "for the \(phrase)"
    }

    // MARK: Results

    /// `left` when the week is within the budget, else `over_by`, as a dollar string.
    private static func leftField(_ standing: BudgetStanding) -> (key: String, value: String) {
        standing.isWithin ? ("left", dollars(cents: standing.leftCents)) : ("over_by", dollars(cents: -standing.leftCents))
    }

    /// `$140.00 left this week` or `$50.00 over the budget for the week of Nov 2`: the standing as a notice says it.
    private static func standingText(_ standing: BudgetStanding, week: String) -> String {
        let field = leftField(standing)
        return standing.isWithin ? "\(field.value) left \(inWeek(week))" : "\(field.value) over the budget \(inWeek(week))"
    }

    /// The one notice line after a recorded `record_spend`, in the same form as the partner request's.
    static func spendNotice(amountCents: Int, standing: BudgetStanding, week: String) -> String {
        "\(dollars(cents: amountCents)) recorded in \(partnerLabel): \(standingText(standing, week: week))."
    }

    /// The fields both lookups share: the week, the budget, what is spent, the standing and `left` or `over_by`.
    static func standingFields(_ standing: BudgetStanding) -> [String: Any] {
        let field = leftField(standing)
        return ["week_start": standing.weekStart, "budget": dollars(cents: standing.budgetCents),
                "spent": dollars(cents: standing.spentCents), "standing": standing.isWithin ? "within" : "over",
                "includes_estimate": standing.includesEstimate, field.key: field.value]
    }

    // MARK: The partner request hook

    /// What the budget partner came to for a confirmed table.
    enum BookingSpend {
        /// The spend was sent and recorded; `week` is the week phrase of the table's week.
        case recorded(amountCents: Int, standing: BudgetStanding, week: String)
        /// The request failed (`notify` is false when the task was cancelled, which says nothing to the user).
        case unavailable(notify: Bool)

        /// The `budget` key of the partner result.
        var block: [String: Any] {
            switch self {
            case .recorded(let amount, let standing, let week):
                let field = AgentBudget.leftField(standing)
                return ["simulated": true, "status": "recorded", "estimated_spend": AgentBudget.dollars(cents: amount),
                        "week": week, "includes_estimate": true, field.key: field.value]
            case .unavailable:
                return ["simulated": true, "status": "unavailable"]
            }
        }

        /// The fixed sentence added to the partner result's message.
        var sentence: String {
            switch self {
            case .recorded: return AgentBudget.bookingRecordedSentence
            case .unavailable: return AgentBudget.bookingUnavailableSentence
            }
        }

        /// The one notice line of the partner request, or nil.
        var notice: String? {
            switch self {
            case .recorded(let amount, let standing, let week):
                let standingText = AgentBudget.standingText(standing, week: week)
                return "Estimated spend \(AgentBudget.dollars(cents: amount)) sent to \(AgentBudget.partnerLabel): \(standingText)."
            case .unavailable(let notify):
                return notify ? AgentBudget.bookingFailureNotice : nil
            }
        }
    }
}
