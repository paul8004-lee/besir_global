import Foundation
import CoreLocation

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

    /// True while the leg is still stored: only then does its screen draw the leg's own content. A gone leg draws the switch
    /// section alone.
    static func showsLegContent(legIsStored: Bool) -> Bool { legIsStored }

    /// The leg a host sheet keeps showing: the stored one when there is one, else the retained one while the selection still
    /// points at it, else none.
    static func openedLeg(stored: ScheduledEvent?, retained: ScheduledEvent?, selection: UUID?) -> ScheduledEvent? {
        if let stored { return stored }
        guard let retained, let selection, retained.id == selection else { return nil }
        return retained
    }

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

// MARK: - The center

/// What the departure card of a late leg shows for a booking that has a partner record, and what its one tap does. It keeps one
/// state per schedule entry: a read in flight, the offer, the steps running, a note, or the result. It reads once for an entry
/// and a late result, never changes anything on a read, and runs the steps of one tap in a task of its own, so the view going
/// away does not stop them. The view reads `states` and calls `check` and `confirm`; it holds no rule.
@MainActor
final class LateSwitchCenter: ObservableObject {
    /// The center the app uses. It builds its clients from the Store it is handed.
    static let shared = LateSwitchCenter()

    // MARK: Dependencies

    /// Everything the center reaches outside itself. The defaults are the live ones, built the way the toolbox builds them (an
    /// ephemeral URL session per call, the shared ledger, record and logs, the Store's own place search); a test injects stubs and
    /// a clock. The center reads no device position: the offer's place search is centred on the leg's own origin.
    @MainActor struct Dependencies {
        let store: Store
        let budget: () -> BudgetClient
        let delivery: () -> DeliveryClient
        let partners: () -> PartnerClient
        let ledger: BudgetLedger
        let records: PartnerRecords
        let orderLog: DeliveryOrderLog
        let placeSearch: () -> PlaceSearch
        let now: () -> Date
        let zone: () -> TimeZone
        let newID: () -> String
        let log: ConnectionLog

        init(store: Store,
             budget: (() -> BudgetClient)? = nil,
             delivery: (() -> DeliveryClient)? = nil,
             partners: (() -> PartnerClient)? = nil,
             ledger: BudgetLedger = BudgetLedger.shared,
             records: PartnerRecords = PartnerRecords.shared,
             orders: DeliveryOrderLog = DeliveryOrderLog.shared,
             placeSearch: (() -> PlaceSearch)? = nil,
             now: @escaping () -> Date = { Date() },
             zone: @escaping () -> TimeZone = { TimeZone.current },
             newID: @escaping () -> String = { UUID().uuidString },
             log: ConnectionLog = ConnectionLog.shared) {
            self.store = store
            self.budget = budget ?? { BudgetClient(config: store.config, ledger: ledger, send: Dependencies.send) }
            self.delivery = delivery ?? { DeliveryClient(config: store.config, send: Dependencies.send) }
            self.partners = partners ?? { PartnerClient(config: store.config, send: Dependencies.send) }
            self.ledger = ledger
            self.records = records
            self.orderLog = orders
            self.placeSearch = placeSearch ?? { store.placeSearch }
            self.now = now
            self.zone = zone
            self.newID = newID
            self.log = log
        }

        nonisolated private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            try await URLSession(configuration: .ephemeral).data(for: request)
        }

        /// True when all three partner clients have a proxy to call.
        var proxyConfigured: Bool { budget().isConfigured && delivery().isConfigured && partners().isConfigured }
    }

    // MARK: States

    /// The words of a finished tap, in the order the view draws them.
    struct Result: Equatable {
        let lines: [String]
    }

    /// An offer: the seed, the field card built from it (the edit card draws it), and what the tap needs later. The two lines under
    /// the card and the button's state come from the card as it is now.
    @MainActor struct Offer {
        let seed: LateSwitch.Seed
        let card: AgentFieldCard
        /// The one flow of the offer: the two reads and, after the tap, every step.
        let flow: UUID
        fileprivate let event: ScheduledEvent
        fileprivate let outcome: ReplanOutcome
        fileprivate let dependencies: Dependencies

        /// The estimates and the standing recomputed from the card's snapshot.
        var evaluation: LateSwitch.Evaluation {
            LateSwitch.evaluate(card.values, seed: seed, now: dependencies.now(), zone: dependencies.zone())
        }
    }

    enum State {
        /// A read is in flight; nothing is drawn.
        case checking
        case offer(Offer)
        case running
        case note(String)
        case finished(Result)
    }

    @Published private(set) var states: [UUID: State] = [:]
    /// The last late result read for each entry; a failed read counts, a cancelled one does not.
    private var checked: [UUID: Date] = [:]
    private let injected: Dependencies?

    init(dependencies: Dependencies? = nil) {
        injected = dependencies
    }

    private func dependencies(for store: Store) -> Dependencies { injected ?? Dependencies(store: store) }

    func state(for activityID: UUID) -> State? { states[activityID] }

    /// True while an offer is on and its card is ready and not frozen: the button's enabled state.
    func canConfirm(activityID id: UUID) -> Bool {
        guard case .offer(let offer)? = states[id] else { return false }
        return offer.card.isReady && !offer.card.isFrozen
    }

    /// An offer shows only while the card shows a late result for the leg; a running state, a note or a result shows whenever the
    /// center holds one for the entry; nothing shows while a read is in flight.
    static func shows(state: State?, lateLines: Bool) -> Bool {
        switch state {
        case .offer?: return lateLines
        case .running?, .note?, .finished?: return true
        case .checking?, nil: return false
        }
    }

    // MARK: The read

    /// REQ-LATESWITCH-007: for a late result of a leg whose entry has an unmarked record, one budget read for the entry's week
    /// and, after a good answer, one options read under the same new flow; then the seed. Nothing is shown while a read is in
    /// flight or after a failure. It reads once for an entry and a result.
    func check(event: ScheduledEvent, outcome: ReplanOutcome, store: Store) async {
        let deps = dependencies(for: store)
        guard outcome.kind == .late, outcome.eventID == event.id, let id = event.linkedActivityId, checked[id] != outcome.checkedAt,
              deps.store.activity(id: id) != nil, let record = deps.records.record(forActivity: id), !record.switchStarted,
              deps.proxyConfigured else { return }
        switch states[id] {
        case .checking?, .running?, .finished?: return
        case .offer?, .note?, nil: break
        }
        await read(event: event, outcome: outcome, id: id, deps: deps)
    }

    private func read(event: ScheduledEvent, outcome: ReplanOutcome, id: UUID, deps: Dependencies) async {
        var before = states[id]
        if case .checking? = before { before = nil }
        states[id] = .checking
        // Leaves the read: `counted` is false for a read that was cancelled, which is read again for the same result.
        func leave(_ state: State?, counted: Bool) {
            states[id] = state
            if counted { checked[id] = outcome.checkedAt }
        }
        guard let activity = deps.store.activity(id: id) else { return leave(before, counted: false) }
        let flow = ConnectionLog.beginFlow()
        let week = BudgetWeek.start(of: activity.startDate, in: deps.zone())
        let left = await deps.budget().left(weekStart: week, flow: flow)
        guard !Task.isCancelled else { return leave(before, counted: false) }
        guard case .success(let standing) = left else { return leave(nil, counted: true) }
        let asked = await deps.delivery().options(flow: flow)
        guard !Task.isCancelled else { return leave(before, counted: false) }
        guard case .success(let options) = asked else { return leave(nil, counted: true) }

        // The reads took time: the entry and its record are looked at again before the offer is built.
        guard let current = deps.store.activity(id: id), let record = deps.records.record(forActivity: id), !record.switchStarted else {
            return leave(nil, counted: true)
        }
        let now = deps.now()
        let zone = deps.zone()
        let shown = LateSwitch.shownArrival(outcome: outcome, now: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // The span holds both anchors of the place suggestion, the arrival (rounded up to the minute) and now.
        let span = DateInterval(start: min(shown, now), end: max(shown, now).addingTimeInterval(120))
        let schedule = deps.store.activities(in: span, calendar: calendar)
        let ledgerEntry = record.spendRequestID.flatMap { deps.ledger.entry(requestID: $0) }
        guard let seed = LateSwitch.seed(record: record, entryStart: current.startDate, place: current.location, ledgerEntry: ledgerEntry,
                                         standing: standing, options: options, shownArrival: shown, now: now, schedule: schedule,
                                         legOrigin: event.origin, zone: zone) else { return leave(nil, counted: true) }
        // The place search of the card is centred on the leg's own origin, none without one.
        let center = event.origin.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let card = AgentFieldCard(header: LateSwitch.cardHeader, rows: LateSwitch.rows(seed: seed), favorites: deps.store.favorites,
                                  search: { query in await deps.placeSearch().search(query, near: center) }, now: deps.now)
        leave(.offer(Offer(seed: seed, card: card, flow: flow, event: event, outcome: outcome, dependencies: deps)), counted: true)
    }

    // MARK: The tap

    /// What the tap takes from the card, trimmed once.
    private struct Order {
        let line: DeliveryLine
        let arrival: Date
        let address: String
        let card: DeliveryCard
        let mealTitle: String
    }

    /// REQ-LATESWITCH-009: freezes the card, takes its one snapshot and checks, in this order, that the entry and its record are
    /// still there with the mark clear, that the arrival is still usable, that the proxy is set and that the ledger's sum for the
    /// week is the one the offer was made from. A failed check sends and changes nothing. Then the mark is written to disk and the
    /// steps start in a task of their own.
    func confirm(activityID id: UUID) {
        guard case .offer(let offer)? = states[id], offer.card.isReady, !offer.card.isFrozen else { return }
        let deps = offer.dependencies
        offer.card.freeze()
        let evaluation = LateSwitch.evaluate(offer.card.values, seed: offer.seed, now: deps.now(), zone: deps.zone())
        guard let line = evaluation.line, let arrival = evaluation.arrival, let address = evaluation.address,
              let card = evaluation.card, let title = evaluation.mealTitle else { return note(LateSwitch.nothingChangedNote, id) }
        guard deps.store.activity(id: id) != nil, let record = deps.records.record(forActivity: id), !record.switchStarted else {
            return note(LateSwitch.nothingChangedNote, id)
        }
        guard evaluation.arrivalUsable else { return note(LateSwitch.arrivalNote, id) }
        guard deps.proxyConfigured else { return note(LateSwitch.nothingChangedNote, id) }
        guard deps.ledger.spentCents(weekStart: offer.seed.weekStart) == offer.seed.spentCentsAtOffer else {
            // The week moved on since the offer: it is dropped and read once more, under a new flow.
            states[id] = .checking
            Task { [self] in await read(event: offer.event, outcome: offer.outcome, id: id, deps: deps) }
            return
        }
        // The mark reaches the disk before anything is sent; a failed write sends nothing and leaves the mark false.
        guard deps.records.setSwitchStarted(true, forActivity: id) else { return note(LateSwitch.nothingChangedNote, id) }
        states[id] = .running
        let order = Order(line: line, arrival: arrival, address: address, card: card, mealTitle: title)
        Task { [self] in await run(offer: offer, order: order, record: record) }
    }

    private func note(_ text: String, _ id: UUID) {
        states[id] = .note(text)
    }

    /// REQ-LATESWITCH-010 and 011: the steps of one tap, in this order: the delivery order, the booking's cancel, the release of
    /// the booking's estimate with the delivery's spend, the move of the entry, the order record.
    private func run(offer: Offer, order: Order, record: PartnerRecord) async {
        let deps = offer.dependencies
        let id = offer.seed.activityID
        let flow = offer.flow
        let request = DeliveryRequest(requestID: deps.newID(), restaurant: offer.seed.restaurant,
                                      arriveAt: LateSwitch.arrivalText(order.arrival, zone: deps.zone()), items: [order.line],
                                      address: order.address, cardID: order.card.id)
        let ordered = await deps.delivery().order(request, options: offer.seed.options, flow: flow)
        let orderID: String
        let results: [PartnerResultItem]
        switch ordered {
        case .success(.confirmed(let confirmedID, let confirmedResults)):
            orderID = confirmedID
            results = confirmedResults
        case .success(.declined), .failure(.notSetUp), .failure(.tokenRejected):
            // The partner provably ordered nothing: the booking may be offered again.
            deps.records.setSwitchStarted(false, forActivity: id)
            return note(LateSwitch.notOrderedNote, id)
        case .failure(.offline), .failure(.other):
            // It may have ordered: the mark stays and the booking gets no offer again.
            return note(LateSwitch.notConfirmedNote, id)
        }
        guard let total = results.moneyCents, let moneyName = results.moneyName else { return note(LateSwitch.notConfirmedNote, id) }

        let cancel = await deps.partners().cancel(requestID: record.requestID, partner: (name: record.partnerName, route: record.route),
                                                  flow: flow)
        var cancelled = false
        if case .success(.cancelled) = cancel { cancelled = true }
        if cancelled { removeBookingLegs(store: deps.store, id: id) }

        // A cancelled booking gives its estimate back; the delivery's estimate is sent whatever the cancel said.
        var released: BudgetEntry?
        if cancelled, let spendID = record.spendRequestID, let held = deps.ledger.entry(requestID: spendID) {
            deps.ledger.remove(requestID: spendID)
            released = held
        }
        let week = BudgetWeek.start(of: order.arrival, in: deps.zone())
        let budgetLine: String
        switch await deps.budget().spend(amountCents: total, isEstimate: true, weekStart: week, requestID: request.requestID, flow: flow) {
        case .success(let standing):
            let phrase = AgentBudget.weekPhrase(weekStart: week, currentWeekStart: BudgetWeek.start(of: deps.now(), in: deps.zone()))
            budgetLine = AgentDelivery.budgetNotice(moneyName: moneyName, totalCents: total, standing: standing, week: phrase)
        case .failure:
            if let released { deps.ledger.add(released) }
            budgetLine = AgentDelivery.budgetFailureNotice
        }

        var moved = false
        if cancelled, let current = deps.store.activity(id: id) {
            let length = current.endDate.timeIntervalSince(current.startDate)
            moved = deps.store.modifyActivity(id: id, newTitle: AgentDelivery.mealTitle(typed: order.mealTitle), newStart: order.arrival,
                                              newEnd: order.arrival.addingTimeInterval(length))
        }
        if moved {
            deps.records.remove(activityID: id)
            if deps.store.activity(id: id)?.wantsCalendarSync == true {
                deps.log.record(from: .besir, to: .appleCalendar, kind: .calendarSave, summary: "Event move sent", status: .ok, flowID: flow)
            }
        }

        // The order record comes last; the meal id is the entry's only after a move.
        let item = offer.seed.options.menuItem(id: order.line.itemID)
        deps.orderLog.add(DeliveryOrderEntry(
            orderID: orderID, requestID: request.requestID, placeName: offer.seed.restaurant, arrival: request.arriveAt,
            items: [DeliveryOrderItem(itemID: order.line.itemID, name: item?.name ?? order.line.itemID, quantity: order.line.quantity,
                                      unitPriceCents: item?.priceCents ?? 0)],
            address: request.address, cardLabel: order.card.label, estimatedTotalCents: total, createdAt: deps.now(),
            mealActivityID: moved ? id.uuidString : nil))

        let delivery = LateSwitch.deliveryLine(orderID: orderID, arrival: order.arrival, zone: deps.zone())
        var lines: [String]
        if !cancelled {
            lines = [delivery, LateSwitch.notCancelledLine]
        } else if moved {
            lines = [LateSwitch.cancelledLine, delivery, LateSwitch.movedLine(start: order.arrival, zone: deps.zone())]
        } else {
            lines = [LateSwitch.cancelledLine, delivery, LateSwitch.notMovedLine]
        }
        lines.append(budgetLine)
        states[id] = .finished(Result(lines: lines))
    }

    /// REQ-SWITCHLEG-001: a cancelled booking has nothing left to travel to, so its two stored legs are taken out through the
    /// Store leg removal, the outbound one first, right after the cancel answer and before the spend is sent. Each outcome is
    /// left unread: the result lines are fixed words and nothing is reported.
    private func removeBookingLegs(store: Store, id: UUID) {
        let pair = store.legs(of: id)
        for leg in [pair.outbound, pair.return].compactMap({ $0 }) {
            store.removeLeg(legId: leg.id)
        }
    }
}
