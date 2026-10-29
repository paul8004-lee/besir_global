import Foundation

/// SPEC-DELIVERY-001: the pure helpers of the `get_delivery_options` and `order_delivery` tools, so what decides and what is said
/// is testable without the toolbox. Money is whole cents (`Int`) everywhere; dollars appear only in text, through `AgentBudget`.
enum AgentDelivery {
    static let maxDeliveryText = 120
    static let maxMealTitle = 40
    /// A meal entry lasts 60 minutes.
    static let mealMinutes = 60
    static let maxItemLines = 6

    // MARK: The four controls of the card

    /// The labels of the card's controls are fixed words, not captions; the card view uses these constants.
    static let deliveryPlaceLabel = "Delivery place"
    static let mealSwitchLabel = "Add to schedule"
    static let mealTitleLabel = "Meal title"
    static let mealStartLabel = "Start"
    static let controlLabels = [deliveryPlaceLabel, mealSwitchLabel, mealTitleLabel, mealStartLabel]

    // MARK: Fixed texts

    static let optionsMessage = "State the items with their estimated prices, the estimated delivery fee and the cards as facts, and say the delivery app is simulated and every price an estimate. Ask the user what to order, when it is to arrive and which card to pay with. Give no advice."
    static let optionsUnavailableMessage = "The simulated delivery app could not be reached. Tell the user the delivery options are not available right now."
    static let appliedMessage = "Tell the user the delivery is ordered with a simulated delivery app. Give the order id, the arrival time, the items, the delivery place (the address field) and the estimated total as facts, and say the total is an estimate. Give no advice."
    static let mealAddedSentence = "Say the meal entry was added to the schedule."
    static let mealMissedSentence = "Say the meal entry could not be added to the schedule."
    static let declinedMessage = "The simulated delivery app could not take the order. Tell the user that the simulated delivery app could not take the order and that nothing was ordered, and ask what they want to do next."
    static let unavailableMessage = "The simulated delivery order could not be made. Tell the user nothing was ordered."
    static let unavailableNotice = "The delivery could not be ordered. Nothing was ordered."
    static let editRejectedMessage = "The delivery place or the meal title was empty. Tell the user nothing was ordered."
    static let budgetRecordedSentence = "Tell the user the estimated total was sent to the simulated budget app and the amount left or over, as facts and as estimates. Do not call record_spend for this order."
    static let budgetUnavailableSentence = "The estimated total could not be sent to the simulated budget app. Tell the user so, and do not call record_spend for this order."
    static let budgetFailureNotice = "The estimated total could not be sent to \(AgentBudget.partnerLabel)."

    /// The partner's line at the end of the card. Built from the one literal of the app.
    static var partnerLine: String { "\(DeliveryClient.partnerName) - Simulated" }

    // MARK: Arguments

    /// `item_id:quantity` pairs separated by commas: 1 to 6 pairs, no spaces, an id of lower-case ASCII letters, digits, `-` and
    /// `_`, a quantity of one ASCII digit from 1 to 9, no repeated id. Anything else gives nil.
    static func parseItems(_ text: String) -> [DeliveryLine]? {
        let pairs = text.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...maxItemLines).contains(pairs.count) else { return nil }
        var lines: [DeliveryLine] = []
        for pair in pairs {
            let parts = pair.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, isItemID(parts[0]) else { return nil }
            let digits = Array(parts[1].utf8)
            guard digits.count == 1, (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(digits[0]) else { return nil }
            let id = String(parts[0])
            guard !lines.contains(where: { $0.itemID == id }) else { return nil }
            lines.append(DeliveryLine(itemID: id, quantity: Int(digits[0] - UInt8(ascii: "0"))))
        }
        return lines
    }

    private static func isItemID(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    // MARK: The delivery place

    /// The text of a place: its address if that is, cleaned, 1 to 120 scalars; else its name on the same rule; else nil. Nothing
    /// is cut, so no half address is sent.
    static func placeText(_ place: Place) -> String? {
        for candidate in [place.address, place.name] {
            let clean = AgentToolbox.sanitized(candidate)
            if (1...maxDeliveryText).contains(clean.unicodeScalars.count) { return clean }
        }
        return nil
    }

    /// The place of the schedule entry in progress (start at or before the anchor, end after it) at the first anchor that has any
    /// entry with a usable text: the arrival time, then `now`. That anchor decides alone: one distinct text is the suggestion, two
    /// or more different texts give nil, and the later anchor is not consulted.
    static func suggestedPlaceText(activities: [ActivityBlock], arrival: Date, now: Date) -> String? {
        for anchor in [arrival, now] {
            let texts = activities.filter { $0.startDate <= anchor && anchor < $0.endDate }
                .compactMap { $0.location.flatMap { placeText($0) } }
            if texts.isEmpty { continue }
            return Set(texts).count == 1 ? texts[0] : nil
        }
        return nil
    }

    // MARK: The meal entry

    /// `Brunch` before 11:00, `Lunch` from 11:00, `Snack` from 15:00, `Dinner` from 17:00, by the minute of the day.
    static func mealWord(arrivalMinute: Int) -> String {
        switch arrivalMinute {
        case ..<660: return "Brunch"
        case 660..<900: return "Lunch"
        case 900..<1020: return "Snack"
        default: return "Dinner"
        }
    }

    /// The suggested title: the word of the arrival minute followed by ` (Simulated)`.
    static func mealTitle(arrivalMinute: Int) -> String { mealTitle(typed: mealWord(arrivalMinute: arrivalMinute)) }

    /// A title as the entry carries it: the part the user sees and edits, followed by ` (Simulated)`.
    static func mealTitle(typed: String) -> String { typed + AgentBooking.simulatedSuffix }

    // MARK: What the user types in the card

    /// Per keystroke: removes control, format, line-separator and paragraph-separator characters and cuts at `limit` Unicode
    /// scalars. It never trims, so a space typed after `12` stays and `12 Example Street` can be typed.
    static func cleanedTyped(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var kept = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default:
                guard kept < limit else { return String(scalars) }
                scalars.append(scalar)
                kept += 1
            }
        }
        return String(scalars)
    }

    /// The one trim, taken at Confirm on the snapshot of the editors. Nil when the text is blank.
    static func snapshotText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: The card

    /// The meal line of the card: the title as the entry carries it, the start time as text, and whether the card still shows the
    /// app's own suggestion.
    struct CardMeal: Equatable {
        let title: String
        let time: String
        let isSuggested: Bool
    }

    /// `Estimated total $40.00`.
    static func estimatedTotalLine(cents: Int) -> String { "Estimated total \(AgentBudget.dollars(cents: cents))" }

    /// The lines of the confirmation card, in order: the heading, the place, the arrival, one line for each item, the delivery
    /// text (marked while it is the app's suggestion), the card, the estimated total, the meal entry while it is on (marked
    /// while it is the app's suggestion) and the partner line.
    static func cardLines(placeName: String, arrives: String, items: [(name: String, quantity: Int)], deliveryText: String,
                          deliveryIsSuggested: Bool, cardLabel: String, totalCents: Int, meal: CardMeal?) -> [String] {
        var lines = ["Order delivery", placeName, "Arrives \(arrives)"]
        lines += items.map { "\($0.quantity) x \($0.name)" }
        lines.append("To \(deliveryText)" + (deliveryIsSuggested ? " (suggested from your schedule)" : ""))
        lines.append("Pay with \(cardLabel)")
        lines.append(estimatedTotalLine(cents: totalCents))
        if let meal {
            lines.append("Add to schedule: \(meal.title) at \(meal.time)" + (meal.isSuggested ? " (suggested)" : ""))
        }
        lines.append(partnerLine)
        return lines
    }

    // MARK: Results

    /// The result of `get_delivery_options`: the menu with estimated prices, the cards, the estimated fee and the fixed message.
    static func optionsResult(_ options: DeliveryOptions) -> [String: Any] {
        let menu: [[String: Any]] = options.menu.map {
            ["item_id": $0.id, "name": $0.name, "estimated_price": AgentBudget.dollars(cents: $0.priceCents)]
        }
        let cards: [[String: Any]] = options.cards.map { ["card_id": $0.id, "label": $0.label] }
        return ["status": "ok", "partner": DeliveryClient.partnerName, "simulated": true, "menu": menu, "cards": cards,
                "estimated_delivery_fee": AgentBudget.dollars(cents: options.deliveryFeeCents), "message": optionsMessage]
    }

    /// The meal entry as the Store holds it after the write, for the `meal` key of the applied result.
    enum AppliedMeal {
        case added(id: String, title: String, start: String, end: String)
        case notAdded

        var block: [String: Any] {
            switch self {
            case .added(let id, let title, let start, let end):
                return ["status": "added", "id": id, "title": title, "start": start, "end": end]
            case .notAdded:
                return ["status": "not_added"]
            }
        }

        var sentence: String {
            switch self {
            case .added: return AgentDelivery.mealAddedSentence
            case .notAdded: return AgentDelivery.mealMissedSentence
            }
        }
    }

    /// What the budget partner came to for a confirmed order.
    enum BudgetHandOff {
        /// The spend was sent and recorded; `week` is the week phrase of the arrival's week.
        case recorded(standing: BudgetStanding, week: String)
        /// The request failed (`notify` is false when the task was cancelled, which says nothing to the user).
        case unavailable(notify: Bool)

        /// The `budget` key of the applied result.
        var block: [String: Any] {
            switch self {
            case .recorded(let standing, let week):
                let fields = AgentBudget.standingFields(standing)
                var object: [String: Any] = ["simulated": true, "status": "recorded", "week": week]
                for key in ["includes_estimate", "left", "over_by"] { object[key] = fields[key] }
                return object
            case .unavailable:
                return ["simulated": true, "status": "unavailable"]
            }
        }

        /// The fixed sentence added to the applied result's message.
        var sentence: String {
            switch self {
            case .recorded: return AgentDelivery.budgetRecordedSentence
            case .unavailable: return AgentDelivery.budgetUnavailableSentence
            }
        }

        /// The one notice line of the order, or nil.
        func notice(totalCents: Int) -> String? {
            switch self {
            case .recorded(let standing, let week):
                return AgentDelivery.budgetNotice(totalCents: totalCents, standing: standing, week: week)
            case .unavailable(let notify):
                return notify ? AgentDelivery.budgetFailureNotice : nil
            }
        }
    }

    /// `Estimated total $40.00 sent to Example Budget (Simulated): $160.00 left this week.` or, over, `$25.00 over the budget
    /// for the week of Nov 2.`
    static func budgetNotice(totalCents: Int, standing: BudgetStanding, week: String) -> String {
        let fields = AgentBudget.standingFields(standing)
        let standingText: String
        if let left = fields["left"] as? String {
            standingText = "\(left) left \(AgentBudget.inWeek(week))"
        } else {
            standingText = "\(fields["over_by"] as? String ?? "") over the budget \(AgentBudget.inWeek(week))"
        }
        return "\(estimatedTotalLine(cents: totalCents)) sent to \(AgentBudget.partnerLabel): \(standingText)."
    }

    /// The fields of the `applied` result. `meal` is nil when the entry was off at Confirm; the message carries the meal
    /// sentence only when the entry was on.
    static func appliedFields(orderID: String, restaurant: String, arrival: String, items: [(name: String, quantity: Int)],
                              address: String, cardLabel: String, totalCents: Int, meal: AppliedMeal?,
                              budget: BudgetHandOff) -> [String: Any] {
        var message = appliedMessage
        if let meal { message += " " + meal.sentence }
        message += " " + budget.sentence
        var object: [String: Any] = [
            "status": "applied", "partner": DeliveryClient.partnerName, "simulated": true, "order_id": orderID,
            "restaurant": restaurant, "arrival_estimate": arrival,
            "items": items.map { ["name": $0.name, "quantity": $0.quantity] as [String: Any] }, "address": address,
            "card": cardLabel, "estimated_total": AgentBudget.dollars(cents: totalCents), "estimate": true,
            "message": message, "budget": budget.block]
        if let meal { object["meal"] = meal.block }
        return object
    }
}
