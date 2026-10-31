import Foundation

/// SPEC-LATESWITCH-001 (card t72): the pure rule that decides when a late booking can be switched to a delivery and what the offer
/// holds. Foundation only: it reads no network, no store and no clock (the instants and the zone are handed in), and it holds no
/// price, fee, item id, partner key, hours or partner name of its own. Every such value comes from the partner's own answer
/// (`DeliveryOptions`), from the one literal a partner client keeps for its name, or from the delivery client's hours.
enum LateSwitch {
    // MARK: The rule's constants

    /// The delivery may arrive at most this many minutes after the booked start.
    static let maxLateMinutes = 120

    // MARK: Keys and fixed texts

    /// The keys of the three rows that are the app's own; the hyphen keeps them apart from any partner key.
    static let itemKey = "switch-item"
    static let quantityKey = "switch-quantity"
    static let titleKey = "switch-title"

    static let cardHeader = "Order delivery instead"
    static let itemLabel = "Item"
    static let quantityLabel = "Quantity"
    static let buttonTitle = "Switch to delivery"

    static let bookingEstimateWord = "Booking est."
    static let deliveryEstimateWord = "Delivery est."
    static let afterSwitchWords = "after the switch"

    /// What the tap says when it changed or sent nothing, and the lines of a result.
    static let nothingChangedNote = "Nothing was changed."
    static let arrivalNote = "That arrival time cannot be used. Nothing was changed."
    static let notOrderedNote = "The delivery could not be ordered. Nothing was changed."
    static let notConfirmedNote = "The delivery could not be confirmed. Nothing else was changed."
    static let cancelledLine = "Booking cancelled"
    static let notCancelledLine = "The booking could not be cancelled."
    static let notMovedLine = "The schedule entry could not be moved."

    /// Every fixed text above, for the scans of the words and the characters.
    static var fixedTexts: [String] {
        [cardHeader, itemLabel, quantityLabel, buttonTitle, bookingEstimateWord, deliveryEstimateWord, afterSwitchWords, nothingChangedNote,
         arrivalNote, notOrderedNote, notConfirmedNote, cancelledLine, notCancelledLine, notMovedLine]
    }

    /// The line at the end of the offer card: the booking partner's name (the record's), then the two partners the switch uses.
    static func partnerLine(partnerName: String) -> String {
        "\(partnerName), \(DeliveryClient.partnerName) and \(BudgetClient.partnerName) - Simulated"
    }

    /// `Delivery <id> arrives <h:mm a>`, the id being the delivery partner's own.
    static func deliveryLine(orderID: String, arrival: Date, zone: TimeZone) -> String {
        "Delivery \(orderID) arrives \(Replan.clockText(arrival, timeZone: zone))"
    }

    static func movedLine(start: Date, zone: TimeZone) -> String {
        "Schedule entry moved to \(Replan.clockText(start, timeZone: zone))"
    }

    /// True when the section draws a Google mark of its own: only for a transit leg. The departure card draws the merged mark for
    /// the other modes.
    static func ownMark(mode: TransportMode) -> Bool { mode == .transit }

    // MARK: Times

    /// `yyyy-MM-ddTHH:mm` in `zone`, ASCII digits and the Gregorian calendar whatever the device's language: the text the order
    /// request carries.
    static func arrivalText(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    /// The arrival the late lines show: the later of the check's own estimate and `now` plus the live travel time, the rule the
    /// departure card draws it by.
    static func shownArrival(outcome: ReplanOutcome, now: Date) -> Date {
        let reached = now.addingTimeInterval(outcome.liveTravel)
        return max(outcome.arrivalEstimate ?? reached, reached)
    }

    /// The first instant at or after `date` that falls on a whole minute.
    private static func roundedUp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.up) * 60)
    }

    private static func minuteStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private static func minuteOfDay(_ date: Date, zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    /// An arrival is usable only when all four hold: its minute of the day in `zone` is inside the delivery partner's hours (both
    /// ends included); it is not before the current minute; it is at most `maxLateMinutes` after the booked start (an arrival
    /// before the start is usable on purpose: the delivery may come earlier and the entry moves to it); and it is in the same
    /// week as the booked start in `zone`.
    static func usableArrival(_ arrival: Date, entryStart: Date, now: Date, zone: TimeZone) -> Bool {
        guard (DeliveryClient.openMinute...DeliveryClient.closeMinute).contains(minuteOfDay(arrival, zone: zone)) else { return false }
        guard minuteStart(arrival) >= minuteStart(now) else { return false }
        guard arrival.timeIntervalSince(entryStart) <= TimeInterval(maxLateMinutes * 60) else { return false }
        return BudgetWeek.start(of: arrival, in: zone) == BudgetWeek.start(of: entryStart, in: zone)
    }

    // MARK: The delivery place

    /// The first value of the delivery place row: the place of the schedule entry in progress at the arrival, else at `now`, the
    /// booked entry left out; when the schedule gives none (nothing in progress, or two different places), the address of the
    /// leg's origin when it has one (a device fix has none). Nil otherwise. The row stays editable: this is a suggestion.
    static func suggestedPlace(schedule: [ActivityBlock], excluding booked: UUID, arrival: Date, now: Date, legOrigin: Place?) -> String? {
        let others = schedule.filter { $0.id != booked }
        if let text = AgentDelivery.suggestedPlaceText(activities: others, arrival: arrival, now: now) { return text }
        guard let legOrigin, !legOrigin.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AgentDelivery.placeText(legOrigin)
    }

    // MARK: The seed

    /// What the offer starts from: the rows of the card with their first values, and what the evaluation needs to judge a change
    /// of the card. Every row value is inferred or blank, none is stated.
    struct Seed {
        let activityID: UUID
        /// The booking partner's name as the record kept it.
        let partnerName: String
        /// The entry's place name as it leaves the app: sanitized and cut. The line at the top of the card and the order's name.
        let restaurant: String
        let entryStart: Date
        /// The week read, as the budget partner named it.
        let weekStart: String
        let budgetCents: Int
        /// The ledger's total for the week when the offer was made.
        let spentCentsAtOffer: Int
        /// The booking's amount: its ledger entry's, else the partner's answered amount.
        let bookingCents: Int
        /// True when the booking's ledger entry is in the week read, so the base leaves it out.
        let bookingInWeek: Bool
        let options: DeliveryOptions
        let itemID: String
        /// The quantity hint when it is 1 to 9, else nil (the row starts blank).
        let quantity: Int?
        /// The shown arrival, rounded up to the minute.
        let arrival: Date
        let address: String?
        let cardID: String
        /// The meal word of the seeded arrival's minute in the zone.
        let mealWord: String
        /// The keys of the delivery partner's three fields, found by kind.
        let arriveKey: String
        let addressKey: String
        let cardKey: String

        /// The week's spending without the booking, in cents.
        var baseCents: Int { spentCentsAtOffer - (bookingInWeek ? bookingCents : 0) }
    }

    /// The offer's seed, or nil. It exists only when the seeded arrival is usable, the record has an answered amount, the entry has
    /// a place with a name, the options hold an item and a card, and the delivery partner's form has exactly one field of each
    /// kind `time`, `place` and `pick_one` that a card can draw. The week of `standing` is the week of `entryStart`.
    static func seed(record: PartnerRecord, entryStart: Date, place: Place?, ledgerEntry: BudgetEntry?, standing: BudgetStanding,
                     options: DeliveryOptions, shownArrival: Date, now: Date, schedule: [ActivityBlock], legOrigin: Place?,
                     zone: TimeZone) -> Seed? {
        guard let place, let estimate = record.estimateCents else { return nil }
        let restaurant = AgentBooking.sentName(place)
        guard !restaurant.isEmpty, let item = options.menu.first, let card = options.cards.first,
              options.fields.allSatisfy({ AgentFieldSpec($0) != nil }),
              let arriveKey = soleKey(of: .time, in: options.fields), let addressKey = soleKey(of: .place, in: options.fields),
              let cardKey = soleKey(of: .pickOne, in: options.fields) else { return nil }
        let arrival = roundedUp(shownArrival)
        guard usableArrival(arrival, entryStart: entryStart, now: now, zone: zone) else { return nil }
        let hint = record.quantityHint.flatMap { (1...9).contains($0) ? $0 : nil }
        let address = suggestedPlace(schedule: schedule, excluding: record.activityID, arrival: arrival, now: now, legOrigin: legOrigin)
        return Seed(activityID: record.activityID, partnerName: record.partnerName, restaurant: restaurant, entryStart: entryStart,
                    weekStart: standing.weekStart, budgetCents: standing.budgetCents, spentCentsAtOffer: standing.spentCents,
                    bookingCents: ledgerEntry?.amountCents ?? estimate,
                    bookingInWeek: ledgerEntry.map { $0.weekStart == standing.weekStart } ?? false,
                    options: options, itemID: item.id, quantity: hint, arrival: arrival, address: address, cardID: card.id,
                    mealWord: AgentDelivery.mealWord(arrivalMinute: minuteOfDay(arrival, zone: zone)),
                    arriveKey: arriveKey, addressKey: addressKey, cardKey: cardKey)
    }

    /// The key of the one field of `kind`; nil when the form has none or more than one.
    private static func soleKey(of kind: PartnerFieldKind, in fields: [PartnerField]) -> String? {
        let found = fields.filter { $0.kind == kind }
        return found.count == 1 ? found[0].key : nil
    }

    // MARK: The rows

    /// The offer card's rows in order: the entry's place, `Item`, `Quantity`, the delivery partner's own fields in its order seeded
    /// by kind, `Meal title`, and the partner line.
    static func rows(seed: Seed) -> [AgentFieldRow] {
        var rows: [AgentFieldRow] = [.line(seed.restaurant)]
        let item = AgentFieldSpec(key: itemKey, kind: .pickOne, label: itemLabel,
                                  options: seed.options.menu.map { AgentFieldOption(id: $0.id, label: $0.name) })
        rows.append(.field(item, value: .option(seed.itemID), source: .inferred))
        let quantity = AgentFieldSpec(key: quantityKey, kind: .number, label: quantityLabel, limit: 1, range: 1...9)
        rows.append(.field(quantity, value: seed.quantity.map { AgentFieldValue.number($0) }, source: seed.quantity == nil ? .blank : .inferred))
        for field in seed.options.fields {
            guard let spec = AgentFieldSpec(field) else { continue }
            switch field.key {
            case seed.arriveKey:
                rows.append(.field(spec, value: .time(seed.arrival), source: .inferred))
            case seed.addressKey:
                rows.append(.field(spec, value: seed.address.map { AgentFieldValue.text($0) }, source: seed.address == nil ? .blank : .inferred))
            case seed.cardKey:
                rows.append(.field(spec, value: .option(seed.cardID), source: .inferred))
            default:
                rows.append(.field(spec, value: nil, source: .blank))
            }
        }
        let title = AgentFieldSpec(key: titleKey, kind: .text, label: AgentDelivery.mealTitleLabel,
                                   limit: AgentBooking.maxTitle - AgentBooking.simulatedSuffix.count)
        rows.append(.field(title, value: .text(seed.mealWord), source: .inferred))
        rows.append(.line(partnerLine(partnerName: seed.partnerName)))
        return rows
    }

    // MARK: The evaluation

    /// What a card snapshot means: the two estimates, what is left or over after the switch, whether its arrival can be used, and
    /// the values the order is made from (trimmed once, as the tap takes them).
    struct Evaluation: Equatable {
        /// The booking's estimated amount.
        let bookingCents: Int
        /// The delivery's estimated total for the card's one line; nil while the line cannot be totalled.
        let deliveryCents: Int?
        /// The week's budget less its spending with the delivery in place of the booking; negative when over.
        let leftAfterCents: Int?
        let weekPhrase: String
        let arrivalUsable: Bool
        /// The card's item and quantity, only when the options can total them.
        let line: DeliveryLine?
        let arrival: Date?
        let address: String?
        let card: DeliveryCard?
        let mealTitle: String?

        /// `Booking est. $60.00 - Delivery est. $33.00`; nil while the delivery cannot be totalled.
        var estimateLine: String? {
            deliveryCents.map { "\(LateSwitch.bookingEstimateWord) \(AgentBudget.dollars(cents: bookingCents)) - \(LateSwitch.deliveryEstimateWord) \(AgentBudget.dollars(cents: $0))" }
        }

        /// `$167.00 left this week after the switch` or `$0.01 over the budget this week after the switch`; nil while the delivery
        /// cannot be totalled.
        var standingLine: String? {
            guard let left = leftAfterCents else { return nil }
            let week = AgentBudget.inWeek(weekPhrase)
            let standing = left >= 0 ? "\(AgentBudget.dollars(cents: left)) left \(week)" : "\(AgentBudget.dollars(cents: -left)) over the budget \(week)"
            return "\(standing) \(LateSwitch.afterSwitchWords)"
        }
    }

    /// Judges a snapshot of the offer card. `bookingCents` is the booking's amount; the base leaves the booking out only when its
    /// ledger entry is in the week read; the delivery's total is the options' own for the one line.
    static func evaluate(_ snapshot: AgentFieldCard.Snapshot, seed: Seed, now: Date, zone: TimeZone) -> Evaluation {
        var line: DeliveryLine?
        var delivery: Int?
        if let item = snapshot.option(itemKey), let quantity = snapshot.int(quantityKey) {
            let candidate = DeliveryLine(itemID: item, quantity: quantity)
            if let total = seed.options.totalCents(for: [candidate]) {
                line = candidate
                delivery = total
            }
        }
        let arrival = snapshot.date(seed.arriveKey)
        return Evaluation(
            bookingCents: seed.bookingCents, deliveryCents: delivery,
            leftAfterCents: delivery.map { seed.budgetCents - (seed.baseCents + $0) },
            weekPhrase: AgentBudget.weekPhrase(weekStart: seed.weekStart, currentWeekStart: BudgetWeek.start(of: now, in: zone)),
            arrivalUsable: arrival.map { usableArrival($0, entryStart: seed.entryStart, now: now, zone: zone) } ?? false,
            line: line, arrival: arrival, address: snapshot.text(seed.addressKey).flatMap(AgentDelivery.snapshotText),
            card: snapshot.option(seed.cardKey).flatMap { seed.options.card(id: $0) },
            mealTitle: snapshot.text(titleKey).flatMap(AgentDelivery.snapshotText))
    }
}
