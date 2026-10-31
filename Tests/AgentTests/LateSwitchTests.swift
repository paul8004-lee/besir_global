import XCTest
@testable import besir

/// SPEC-LATESWITCH-001 (card t72), AC-LATESWITCH-004: the pure rule that decides when and how a late booking can be switched to
/// delivery. No network, no Store, no clock read: every instant and zone is handed in. Zone names appear here only, in tests.
@MainActor
final class LateSwitchTests: XCTestCase {
    // MARK: Fixtures

    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private static let cards = [DeliveryCard(id: "debit-4242", label: "Example Debit \u{2022}\u{2022}4242 (Simulated)"),
                                DeliveryCard(id: "credit-1881", label: "Example Credit \u{2022}\u{2022}1881 (Simulated)")]

    /// The delivery partner's tables as its options answer lists them (fee 500).
    private func options(fee: Int = 500, ramen: Int = 1400, cards: [DeliveryCard]? = nil, menu: Bool = true,
                         fields: [PartnerField]? = nil) -> DeliveryOptions {
        DeliveryOptions(
            menu: menu ? [DeliveryMenuItem(id: "ramen", name: "Ramen", priceCents: ramen),
                          DeliveryMenuItem(id: "gyoza", name: "Gyoza", priceCents: 700),
                          DeliveryMenuItem(id: "curry", name: "Curry rice", priceCents: 1300)] : [],
            fields: fields ?? PartnerField.delivery(cards: cards ?? Self.cards), deliveryFeeCents: fee)
    }

    private let bistro = Place(name: "Test Bistro", address: "5 Example Road", latitude: 37.5, longitude: 127.0)

    private func record(estimate: Int? = 6000, hint: Int? = 2, activity: UUID = UUID()) -> PartnerRecord {
        PartnerRecord(activityID: activity, partnerID: "booking", partnerName: "Example Tables", route: "/booking",
                      requestID: "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6b", estimateCents: estimate, quantityHint: hint,
                      spendRequestID: "spend-1", switchStarted: false)
    }

    private func standing(spent: Int, week: String = "2026-11-02") -> BudgetStanding {
        BudgetStanding(weekStart: week, budgetCents: 20000, spentCents: spent, leftCents: 20000 - spent, isWithin: spent <= 20000,
                       includesEstimate: true)
    }

    private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Double = 0, zone: TimeZone? = nil) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? seoul
        let parts = DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)
        return calendar.date(from: parts)!.addingTimeInterval(second)
    }

    /// The worked case of AC-LATESWITCH-004: a Monday-evening booking at 19:00 in Seoul, 12 minutes before the shown arrival.
    private struct Scene {
        var zone: TimeZone
        var record: PartnerRecord
        var entryStart: Date
        var place: Place?
        var ledger: BudgetEntry?
        var standing: BudgetStanding
        var options: DeliveryOptions
        var shown: Date
        var now: Date
        var schedule: [ActivityBlock] = []
        var legOrigin: Place?

        var seed: LateSwitch.Seed? {
            LateSwitch.seed(record: record, entryStart: entryStart, place: place, ledgerEntry: ledger, standing: standing,
                            options: options, shownArrival: shown, now: now, schedule: schedule, legOrigin: legOrigin, zone: zone)
        }
    }

    private func scene() -> Scene {
        Scene(zone: seoul, record: record(), entryStart: at(11, 2, 19, 0), place: bistro,
              ledger: BudgetEntry(requestID: "spend-1", weekStart: "2026-11-02", amountCents: 6000, isEstimate: true),
              standing: standing(spent: 6000), options: options(), shown: at(11, 2, 19, 11, 30), now: at(11, 2, 18, 47))
    }

    private func card(_ seed: LateSwitch.Seed, now: Date? = nil) -> AgentFieldCard {
        AgentFieldCard(header: LateSwitch.cardHeader, rows: LateSwitch.rows(seed: seed), favorites: [], search: { _ in [] },
                       now: { now ?? Date(timeIntervalSince1970: 0) })
    }

    private func evaluation(_ s: Scene, edit: (AgentFieldCard) -> Void = { _ in }) throws -> LateSwitch.Evaluation {
        let seed = try XCTUnwrap(s.seed)
        let model = card(seed, now: s.now)
        edit(model)
        return LateSwitch.evaluate(model.values, seed: seed, now: s.now, zone: s.zone)
    }

    private func forbiddenWords(in text: String) -> [String] {
        let words = ["should", "recommend", "advise", "afford", "save", "invest", "cut back", "stop spending", "overspend", "menu",
                     "dish", "calorie", "nutrition", "healthy"]
        return words.filter {
            text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func hasHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) }
    }

    private func clock(_ date: Date, _ zone: TimeZone? = nil) -> String { Replan.clockText(date, timeZone: zone ?? seoul) }

    private func sourceText(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: U01-U03 the worked case, the boundary, the ledger

    func testU01_TheWorkedCaseSeedsRamenTwoSevenTwelveTheFirstCardAndDinnerAndSaysSixteenSevenLeft() throws {
        let s = scene()
        let seed = try XCTUnwrap(s.seed)
        XCTAssertEqual(seed.itemID, "ramen")
        XCTAssertEqual(seed.quantity, 2)
        XCTAssertEqual(clock(seed.arrival), "7:12 PM")
        XCTAssertEqual(seed.cardID, "debit-4242")
        XCTAssertEqual(seed.mealWord, "Dinner")
        XCTAssertEqual(seed.address, nil, "no schedule entry and no leg origin: the delivery place is blank")

        let result = try evaluation(s)
        XCTAssertEqual(result.bookingCents, 6000)
        XCTAssertEqual(result.deliveryCents, 3300)
        XCTAssertEqual(result.leftAfterCents, 16700)
        XCTAssertEqual(result.estimateLine, "Booking est. $60.00 - Delivery est. $33.00")
        XCTAssertEqual(result.standingLine, "$167.00 left this week after the switch")
        XCTAssertTrue(result.arrivalUsable)
        XCTAssertEqual(result.line, DeliveryLine(itemID: "ramen", quantity: 2))

        // The arrival the card shows is the later of the estimate and now plus the live travel, as the late lines draw it.
        let event = ScheduledEvent(title: "Dinner", origin: Place(name: "Home", address: "1 Home Road", latitude: 37.4, longitude: 127.1),
                                   destination: bistro, arrivalDate: at(11, 2, 19, 0), mode: .car, bufferMinutes: 0, notifyLeadMinutes: 0)
        let checked = at(11, 2, 18, 47)
        let outcome = Replan.classify(eventID: event.id, trigger: .appOpen, checkedAt: checked, inputs: ReplanInputs(event: event),
                                      referenceDeparture: at(11, 2, 18, 20), referenceTravel: 25 * 60, liveTravel: 24 * 60 + 30,
                                      noTrafficTravel: nil, now: checked)
        XCTAssertEqual(outcome.kind, .late)
        XCTAssertEqual(LateSwitch.shownArrival(outcome: outcome, now: checked), at(11, 2, 19, 11, 30))
        // Later on, the live travel from the later now is the larger one.
        let later = at(11, 2, 18, 50)
        XCTAssertEqual(LateSwitch.shownArrival(outcome: outcome, now: later), at(11, 2, 19, 14, 30))
        let lines = Replan.displayLines(for: outcome, event: event, now: later, timeZone: seoul)
        XCTAssertTrue(lines?.headline.contains(clock(LateSwitch.shownArrival(outcome: outcome, now: later))) == true)
        // An outcome whose estimate is later than now plus the live travel keeps the estimate.
        let stale = at(11, 2, 18, 40)
        XCTAssertEqual(LateSwitch.shownArrival(outcome: outcome, now: stale), at(11, 2, 19, 11, 30))
    }

    func testU02_TheOverBoundaryReadsZeroLeftAtTwoHundredAndOneCentOverAboveItAndAWeekAlreadyOverReadsOver() throws {
        var s = scene()
        s.ledger = nil
        // 16700 spent and 3300 for the delivery make exactly 20000.
        s.standing = standing(spent: 16700)
        XCTAssertEqual(try evaluation(s).standingLine, "$0.00 left this week after the switch")
        XCTAssertEqual(try evaluation(s).leftAfterCents, 0)
        s.standing = standing(spent: 16701)
        XCTAssertEqual(try evaluation(s).standingLine, "$0.01 over the budget this week after the switch")
        XCTAssertEqual(try evaluation(s).leftAfterCents, -1)
        s.standing = standing(spent: 16699)
        XCTAssertEqual(try evaluation(s).standingLine, "$0.01 left this week after the switch")
        // A week already over before the switch.
        s.standing = standing(spent: 25000)
        XCTAssertEqual(try evaluation(s).standingLine, "$83.00 over the budget this week after the switch")
        // The switch is offered whether or not it fits (L7): the seed exists in every case above.
        XCTAssertNotNil(s.seed)
    }

    func testU03_TheLedgerEntryInTheWeekIsSubtractedOnceAndAbsentTheAnsweredAmountIsTheBookingAndNothingIsSubtracted() throws {
        var s = scene()
        // Spent 10000 of which the booking's entry is 6000: base 4000.
        s.standing = standing(spent: 10000)
        var result = try evaluation(s)
        XCTAssertEqual(result.bookingCents, 6000)
        XCTAssertEqual(result.leftAfterCents, 20000 - (4000 + 3300))
        // The entry's amount, not the record's, is the booking's amount when it is in the ledger.
        s.ledger = BudgetEntry(requestID: "spend-1", weekStart: "2026-11-02", amountCents: 5000, isEstimate: true)
        s.standing = standing(spent: 5000)
        result = try evaluation(s)
        XCTAssertEqual(result.bookingCents, 5000)
        XCTAssertEqual(result.leftAfterCents, 20000 - (0 + 3300))
        // No entry: T is the record's answered amount and nothing is subtracted.
        s.ledger = nil
        s.standing = standing(spent: 4000)
        result = try evaluation(s)
        XCTAssertEqual(result.bookingCents, 6000)
        XCTAssertEqual(result.leftAfterCents, 20000 - (4000 + 3300))
        XCTAssertEqual(result.estimateLine, "Booking est. $60.00 - Delivery est. $33.00")
    }

    // MARK: U04-U08 the arrival rule

    func testU04_TheHoursAreInAtTenAndTwentyTwoAndOutAtNineFiftyNineAndTwentyTwoOhOneInASeoulAndALosAngelesZone() {
        for zone in [seoul, losAngeles] {
            for (hour, minute, expected) in [(9, 59, false), (10, 0, true), (10, 1, true), (21, 59, true), (22, 0, true), (22, 1, false)] {
                let arrival = at(11, 2, hour, minute, zone: zone)
                let usable = LateSwitch.usableArrival(arrival, entryStart: arrival.addingTimeInterval(-30 * 60),
                                                      now: at(11, 2, 8, 0, zone: zone), zone: zone)
                XCTAssertEqual(usable, expected, "\(zone.identifier) \(hour):\(minute)")
            }
        }
        // The zone decides: the same instant is inside the hours in one zone and outside them in the other.
        let instant = at(11, 2, 16, 0, zone: seoul)
        XCTAssertTrue(LateSwitch.usableArrival(instant, entryStart: instant.addingTimeInterval(-1800), now: instant.addingTimeInterval(-7200), zone: seoul))
        XCTAssertFalse(LateSwitch.usableArrival(instant, entryStart: instant.addingTimeInterval(-1800), now: instant.addingTimeInterval(-7200), zone: losAngeles))
    }

    func testU05_TheArrivalRoundsUpToTheMinuteAndItsTextIsEnUSPosixGregorianInTheGivenZone() throws {
        var s = scene()
        for (second, expected) in [(0.0, at(11, 2, 19, 11)), (0.001, at(11, 2, 19, 12)), (1.0, at(11, 2, 19, 12)), (30.0, at(11, 2, 19, 12)),
                                   (59.0, at(11, 2, 19, 12)), (59.999, at(11, 2, 19, 12))] {
            s.shown = at(11, 2, 19, 11, second)
            XCTAssertEqual(try XCTUnwrap(s.seed).arrival, expected, "\(second) s")
        }
        let arrival = at(11, 2, 19, 12)
        XCTAssertEqual(LateSwitch.arrivalText(arrival, zone: seoul), "2026-11-02T19:12")
        XCTAssertEqual(LateSwitch.arrivalText(arrival, zone: losAngeles), "2026-11-02T02:12")
        XCTAssertEqual(LateSwitch.arrivalText(at(11, 2, 0, 5), zone: seoul), "2026-11-02T00:05")
        XCTAssertEqual(LateSwitch.arrivalText(at(11, 2, 23, 59), zone: seoul), "2026-11-02T23:59")
        // The pattern is fixed and the digits are ASCII whatever the device's language: the source says so.
        let source = try sourceText("Shared/LateSwitch.swift")
        XCTAssertTrue(source.contains("en_US_POSIX"))
        XCTAssertTrue(source.contains(".gregorian"))
        XCTAssertTrue(source.contains("yyyy-MM-dd'T'HH:mm"))
    }

    func testU06_AnArrivalBeforeTheCurrentMinuteIsNotUsableAndTheCurrentMinuteIs() {
        let start = at(11, 2, 18, 30)
        let now = at(11, 2, 18, 47, 20)
        XCTAssertFalse(LateSwitch.usableArrival(at(11, 2, 18, 46, 59), entryStart: start, now: now, zone: seoul))
        XCTAssertFalse(LateSwitch.usableArrival(at(11, 2, 18, 46), entryStart: start, now: now, zone: seoul))
        XCTAssertTrue(LateSwitch.usableArrival(at(11, 2, 18, 47), entryStart: start, now: now, zone: seoul))
        XCTAssertTrue(LateSwitch.usableArrival(at(11, 2, 18, 47, 59), entryStart: start, now: now, zone: seoul))
        XCTAssertTrue(LateSwitch.usableArrival(at(11, 2, 18, 48), entryStart: start, now: now, zone: seoul))
        // An arrival before the booked start is usable on purpose: there is no lower bound beyond the current minute.
        XCTAssertTrue(LateSwitch.usableArrival(at(11, 2, 18, 50), entryStart: at(11, 2, 19, 30), now: now, zone: seoul))
    }

    func testU07_AnArrivalInAnotherWeekThanTheEntrysStartIsNotUsableAndGivesNoSeed() throws {
        // Sunday evening now, a booking on Monday morning: an arrival on the Sunday is in the week before the booking's.
        var s = scene()
        s.entryStart = at(11, 2, 10, 30)
        s.now = at(11, 1, 20, 0)
        s.shown = at(11, 1, 21, 0)
        s.standing = standing(spent: 6000)
        XCTAssertNil(s.seed)
        XCTAssertFalse(LateSwitch.usableArrival(at(11, 1, 21, 0), entryStart: s.entryStart, now: s.now, zone: seoul))
        // Positive counterpart: an arrival on the Monday morning is in the booking's week.
        s.shown = at(11, 2, 10, 0)
        XCTAssertNotNil(s.seed)
        XCTAssertTrue(LateSwitch.usableArrival(at(11, 2, 10, 0), entryStart: s.entryStart, now: s.now, zone: seoul))
    }

    func testU08_TheSameInstantsGiveTheSameWeekInTwoZonesOnlyWhenTheZonesSayAnd() {
        // Sunday 21:00 in Los Angeles is Monday 14:00 in Seoul; the booking starts at Monday 00:30 in Los Angeles, 17:30 in Seoul.
        let arrival = at(11, 1, 21, 0, zone: losAngeles)
        let start = at(11, 2, 0, 30, zone: losAngeles)
        let now = at(11, 1, 20, 0, zone: losAngeles)
        XCTAssertEqual(arrival, at(11, 2, 14, 0, zone: seoul))
        XCTAssertEqual(start, at(11, 2, 17, 30, zone: seoul))
        XCTAssertTrue(LateSwitch.usableArrival(arrival, entryStart: start, now: now, zone: seoul), "one week in Seoul")
        XCTAssertFalse(LateSwitch.usableArrival(arrival, entryStart: start, now: now, zone: losAngeles), "two weeks in Los Angeles")
        // A pair inside one day is in one week in both zones.
        let same = at(11, 3, 12, 0, zone: losAngeles)
        XCTAssertTrue(LateSwitch.usableArrival(same, entryStart: same.addingTimeInterval(-600), now: same.addingTimeInterval(-3600), zone: losAngeles))
        XCTAssertEqual(BudgetWeek.start(of: arrival, in: seoul), "2026-11-02")
        XCTAssertEqual(BudgetWeek.start(of: arrival, in: losAngeles), "2026-10-26")
    }

    // MARK: U09-U10 the seed's conditions, the week phrase

    func testU09_TheQuantityHintSeedsOneToNineAndNoSeedWithoutAnItemACardAnAmountOrAPlace() throws {
        var s = scene()
        for hint in [1, 2, 8, 9] {
            s.record = record(hint: hint)
            XCTAssertEqual(try XCTUnwrap(s.seed).quantity, hint)
            XCTAssertEqual(try evaluation(s).line?.quantity, hint)
        }
        for hint: Int? in [0, 10, -1, nil] {
            s.record = record(hint: hint)
            let seed = try XCTUnwrap(s.seed, "a blank quantity still gives a seed")
            XCTAssertNil(seed.quantity, "\(String(describing: hint))")
            let model = card(seed)
            XCTAssertNil(model.values.int(LateSwitch.quantityKey))
            XCTAssertEqual(model.source(of: LateSwitch.quantityKey), .blank)
            XCTAssertFalse(model.isReady)
            let result = LateSwitch.evaluate(model.values, seed: seed, now: s.now, zone: s.zone)
            XCTAssertNil(result.deliveryCents)
            XCTAssertNil(result.line)
        }
        s = scene()
        XCTAssertNotNil(s.seed, "the control")
        s.options = options(menu: false)
        XCTAssertNil(s.seed, "no item")
        s.options = options(cards: [])
        XCTAssertNil(s.seed, "no card")
        s = scene()
        s.record = record(estimate: nil)
        XCTAssertNil(s.seed, "no answered amount")
        s = scene()
        s.place = nil
        XCTAssertNil(s.seed, "no place")
        s.place = Place(name: "  ", address: "5 Example Road", latitude: 0, longitude: 0)
        XCTAssertNil(s.seed, "a place without a name")
        // A seeded arrival that is not usable gives no seed: past 120 minutes after the start.
        s = scene()
        s.shown = at(11, 2, 21, 1)
        XCTAssertNil(s.seed)
    }

    func testU10_TheWeekPhraseIsThisWeekForTheCurrentWeekAndForTheWeekOfNov2OtherwiseInTheLeftAndTheOverLine() throws {
        var s = scene()
        XCTAssertEqual(try evaluation(s).weekPhrase, "this week")
        XCTAssertEqual(try evaluation(s).standingLine, "$167.00 left this week after the switch")
        // Saturday before: the booking's week is not the current one.
        s.now = at(10, 31, 12, 0)
        var result = try evaluation(s)
        XCTAssertEqual(result.weekPhrase, "week of Nov 2")
        XCTAssertEqual(result.standingLine, "$167.00 left for the week of Nov 2 after the switch")
        s.ledger = nil
        s.standing = standing(spent: 25000)
        result = try evaluation(s)
        XCTAssertEqual(result.standingLine, "$83.00 over the budget for the week of Nov 2 after the switch")
    }

    // MARK: U11-U12 the words and the constants

    func testU11_NoTextOfTheCardHoldsAForbiddenWordOrAHangulCharacter() throws {
        var s = scene()
        s.schedule = [ActivityBlock(title: "Office", location: Place(name: "Office", address: "10 Office Way", latitude: 0, longitude: 0),
                                    startDate: at(11, 2, 18, 0), endDate: at(11, 2, 21, 0))]
        let seed = try XCTUnwrap(s.seed)
        var texts = LateSwitch.fixedTexts
        texts += card(seed).lines
        texts.append(LateSwitch.deliveryLine(orderID: "DL-AB12CD", arrival: seed.arrival, zone: seoul))
        texts.append(LateSwitch.movedLine(start: seed.arrival, zone: seoul))
        var overScene = s
        overScene.ledger = nil
        overScene.standing = standing(spent: 25000)
        for result in [try evaluation(s), try evaluation(overScene)] {
            texts += [result.estimateLine, result.standingLine].compactMap { $0 }
        }
        XCTAssertGreaterThan(texts.count, 20, "the control: the list is not empty")
        for text in texts {
            XCTAssertEqual(forbiddenWords(in: text), [], text)
            XCTAssertFalse(hasHangul(text), text)
        }
        // The scans find what they look for.
        XCTAssertEqual(forbiddenWords(in: "You should save"), ["should", "save"])
        XCTAssertEqual(forbiddenWords(in: "Saved"), [])
        XCTAssertTrue(hasHangul("\u{C77C}\u{C815}"))
        // The partner line names the three partners as simulated.
        XCTAssertEqual(LateSwitch.partnerLine(partnerName: "Example Tables"),
                       "Example Tables, Example Delivery and Example Budget - Simulated")
    }

    func testU12_TheHoursConstantsAreTheWorkersAndTheDeliveryTotalFollowsTheOptions() throws {
        XCTAssertEqual(DeliveryClient.openMinute, 600)
        XCTAssertEqual(DeliveryClient.closeMinute, 1320)
        let worker = try sourceText("proxy/src/delivery.js")
        XCTAssertTrue(worker.contains("const OPEN_MINUTE = 600;"))
        XCTAssertTrue(worker.contains("const CLOSE_MINUTE = 1320;"))
        XCTAssertEqual(LateSwitch.maxLateMinutes, 120)
        XCTAssertTrue(LateSwitch.ownMark(mode: .transit))
        for mode in [TransportMode.car, .walk, .bicycle] { XCTAssertFalse(LateSwitch.ownMark(mode: mode)) }
        // D is the options' own total for the card's one line, for another price list and fee.
        var s = scene()
        s.options = options(fee: 700, ramen: 1500)
        let result = try evaluation(s)
        XCTAssertEqual(result.deliveryCents, s.options.totalCents(for: [DeliveryLine(itemID: "ramen", quantity: 2)]))
        XCTAssertEqual(result.deliveryCents, 3700)
        XCTAssertEqual(result.estimateLine, "Booking est. $60.00 - Delivery est. $37.00")
        // The pure part holds no price, fee, item id, partner key, hours literal or partner name.
        let source = try sourceText("Shared/LateSwitch.swift")
        for literal in ["1400", "700", "1320", "\"ramen\"", "\"arrive_at\"", "\"address\"", "\"card_id\"", "Example Tables", "Example Delivery",
                        "Example Budget", "Asia/", "America/"] {
            XCTAssertFalse(source.contains(literal), "the source holds \(literal)")
        }
        XCTAssertTrue(source.contains("DeliveryClient.openMinute"))
    }

    // MARK: U13-U14 the 120 minutes, the other week's entry

    func testU13_OneHundredTwentyMinutesAfterTheStartIsUsableOneHundredTwentyOneIsNotAndAnotherDayIsNot() throws {
        let start = at(11, 2, 18, 45)
        let now = at(11, 2, 18, 47)
        XCTAssertTrue(LateSwitch.usableArrival(at(11, 2, 20, 45), entryStart: start, now: now, zone: seoul))
        XCTAssertFalse(LateSwitch.usableArrival(at(11, 2, 20, 46), entryStart: start, now: now, zone: seoul))
        XCTAssertFalse(LateSwitch.usableArrival(at(11, 2, 20, 45, 1), entryStart: start, now: now, zone: seoul))
        XCTAssertTrue(LateSwitch.usableArrival(at(11, 2, 20, 44), entryStart: start, now: now, zone: seoul))
        // A multi-day arrival in the same week, inside the hours, is past the bound.
        XCTAssertFalse(LateSwitch.usableArrival(at(11, 4, 19, 0), entryStart: start, now: now, zone: seoul))
        // The seed follows the same bound.
        var s = scene()
        s.entryStart = start
        s.shown = at(11, 2, 20, 45)
        XCTAssertNotNil(s.seed)
        s.shown = at(11, 2, 20, 46)
        XCTAssertNil(s.seed)
    }

    func testU14_ALedgerEntryInAnotherWeekThanTheOneReadIsNotSubtractedAndTheBookingIsStillItsAmount() throws {
        var s = scene()
        s.ledger = BudgetEntry(requestID: "spend-1", weekStart: "2026-10-26", amountCents: 5000, isEstimate: true)
        s.standing = standing(spent: 3000)
        let result = try evaluation(s)
        XCTAssertEqual(result.bookingCents, 5000)
        XCTAssertEqual(result.leftAfterCents, 20000 - (3000 + 3300))
        // Positive counterpart: in the week read, the same entry is subtracted.
        s.ledger = BudgetEntry(requestID: "spend-1", weekStart: "2026-11-02", amountCents: 3000, isEstimate: true)
        XCTAssertEqual(try evaluation(s).leftAfterCents, 20000 - (0 + 3300))
    }

    // MARK: U15-U17 the rows, the standing words, the place

    func testU15_TheDeliveryFieldsAreSeededByKindInThePartnersOrderWithNoStatedSource() throws {
        // The same three kinds of field in another order, the card first, with other keys for the time and the place (the options
        // read the card's chips from the key `card_id`, which the delivery adapter guarantees).
        let fields = [PartnerField(key: "card_id", kind: .pickOne, label: "Pay with",
                                   options: Self.cards.map { PartnerOption(id: $0.id, label: $0.label) }),
                      PartnerField(key: "when", kind: .time, label: "Ready by", options: []),
                      PartnerField(key: "where", kind: .place, label: "Delivery place", options: [])]
        var s = scene()
        s.options = options(fields: fields)
        s.legOrigin = Place(name: "Home", address: "1 Home Road", latitude: 0, longitude: 0)
        let seed = try XCTUnwrap(s.seed)
        let model = card(seed)
        XCTAssertEqual(model.card.fields.map(\.key), ["0", LateSwitch.itemKey, LateSwitch.quantityKey, "card_id", "when", "where",
                                                    LateSwitch.titleKey, "1"])
        let values = model.values
        XCTAssertEqual(values.option("card_id"), "debit-4242")
        XCTAssertEqual(values.date("when"), seed.arrival)
        XCTAssertEqual(values.text("where"), "1 Home Road")
        XCTAssertEqual(values.text(LateSwitch.titleKey), "Dinner")
        XCTAssertEqual(values.option(LateSwitch.itemKey), "ramen")
        XCTAssertEqual(values.int(LateSwitch.quantityKey), 2)
        XCTAssertEqual(values.entries.count, 6)
        for entry in values.entries {
            XCTAssertEqual(entry.source, .inferred, entry.key)
            XCTAssertNotEqual(entry.source, .stated)
        }
        // The card is ready with a place, and blank without one.
        XCTAssertTrue(model.isReady)
        s.legOrigin = nil
        let blank = card(try XCTUnwrap(s.seed))
        XCTAssertEqual(blank.source(of: "where"), .blank)
        XCTAssertFalse(blank.isReady)
        // The evaluation reads the same keys: the edit changes the snapshot it returns.
        let result = LateSwitch.evaluate(model.values, seed: seed, now: s.now, zone: s.zone)
        XCTAssertEqual(result.arrival, seed.arrival)
        XCTAssertEqual(result.address, "1 Home Road")
        XCTAssertEqual(result.card, Self.cards[0])
        XCTAssertEqual(result.mealTitle, "Dinner")
        // The rows are the header's, in the order of REQ-008.
        XCTAssertEqual(model.header, "Order delivery instead")
        XCTAssertEqual(model.lines.first, "Order delivery instead")
        XCTAssertEqual(model.lines.last, "Example Tables, Example Delivery and Example Budget - Simulated")
        XCTAssertEqual(model.lines[1], "Test Bistro")
    }

    func testU16_TheStandingWordsOfTheLeftAndTheOverLineAreTheOnesTheBudgetNoticeMakes() throws {
        var s = scene()
        for spent in [6000, 16700, 16701, 25000] {
            s.standing = standing(spent: spent)
            s.ledger = spent == 6000 ? scene().ledger : nil
            let result = try evaluation(s)
            let total = try XCTUnwrap(result.deliveryCents)
            let after = try XCTUnwrap(result.leftAfterCents)
            let afterStanding = BudgetStanding(weekStart: "2026-11-02", budgetCents: 20000, spentCents: 20000 - after, leftCents: after,
                                               isWithin: after >= 0, includesEstimate: true)
            let notice = AgentDelivery.budgetNotice(moneyName: "Estimated total", totalCents: total, standing: afterStanding,
                                                    week: result.weekPhrase)
            let line = try XCTUnwrap(result.standingLine)
            XCTAssertTrue(line.hasSuffix(" after the switch"))
            let fragment = String(line.dropLast(" after the switch".count))
            XCTAssertTrue(notice.hasSuffix(": \(fragment)."), "\(notice) | \(line)")
        }
    }

    func testU17_ThePlaceSuggestionLeavesTheBookedEntryOutTheArrivalAnchorDecidesThenNowThenTheLegsOrigin() throws {
        let booked = UUID()
        let arrival = at(11, 2, 19, 12)
        let now = at(11, 2, 18, 47)
        func block(_ title: String, _ location: Place?, _ from: Date, _ to: Date, id: UUID = UUID(), repeats: UUID? = nil) -> ActivityBlock {
            ActivityBlock(id: id, title: title, location: location, startDate: from, endDate: to, recurrenceId: repeats)
        }
        let office = Place(name: "Office", address: "10 Office Way", latitude: 0, longitude: 0)
        let gym = Place(name: "Gym", address: "20 Gym Street", latitude: 0, longitude: 0)
        let bookedBlock = block("Dinner", bistro, at(11, 2, 18, 45), at(11, 2, 19, 45), id: booked)
        let home = Place(name: "Home", address: "1 Home Road", latitude: 0, longitude: 0)
        let device = Place(name: "Current location", address: "", latitude: 0, longitude: 0)

        func suggestion(_ schedule: [ActivityBlock], origin: Place? = nil) -> String? {
            LateSwitch.suggestedPlace(schedule: schedule, excluding: booked, arrival: arrival, now: now, legOrigin: origin)
        }
        // The booked entry is the only one in progress: it is left out, so there is no suggestion.
        XCTAssertNil(suggestion([bookedBlock]))
        // Another entry in progress at the arrival is the suggestion, with or without the booked one in the list.
        let other = block("Meeting", office, at(11, 2, 19, 0), at(11, 2, 20, 0))
        XCTAssertEqual(suggestion([bookedBlock, other]), "10 Office Way")
        XCTAssertEqual(suggestion([other]), "10 Office Way")
        // The arrival anchor decides alone: an entry at now only is not consulted when the arrival has one.
        let atNow = block("Gym class", gym, at(11, 2, 18, 30), at(11, 2, 19, 5))
        XCTAssertEqual(suggestion([atNow, other]), "10 Office Way")
        // Nothing at the arrival: the entry at now.
        XCTAssertEqual(suggestion([atNow]), "20 Gym Street")
        // Two different texts at the arrival give nil (and the later anchor is not consulted).
        let twin = block("Call", gym, at(11, 2, 19, 0), at(11, 2, 19, 30))
        XCTAssertNil(suggestion([other, twin, atNow]))
        // An occurrence of a repeating activity counts.
        let occurrence = block("Class", gym, at(11, 2, 19, 0), at(11, 2, 20, 0), repeats: UUID())
        XCTAssertEqual(suggestion([occurrence]), "20 Gym Street")
        // Then the leg's origin, when its address is not empty; the device fix has none.
        XCTAssertEqual(suggestion([bookedBlock], origin: home), "1 Home Road")
        XCTAssertNil(suggestion([bookedBlock], origin: device))
        XCTAssertNil(suggestion([], origin: Place(name: "Home", address: "   ", latitude: 0, longitude: 0)))
        XCTAssertEqual(suggestion([other], origin: home), "10 Office Way", "the schedule comes first")
        XCTAssertEqual(suggestion([other, twin], origin: home), "1 Home Road", "two texts give no suggestion, so the origin")
        // The seed uses it: the delivery place row is seeded and the booked entry (the record's) is left out.
        var s = scene()
        s.record = record(activity: booked)
        s.schedule = [bookedBlock, other]
        XCTAssertEqual(try XCTUnwrap(s.seed).address, "10 Office Way")
        s.schedule = [bookedBlock]
        s.legOrigin = home
        XCTAssertEqual(try XCTUnwrap(s.seed).address, "1 Home Road")
    }

    // MARK: U18-U19 the evaluation follows the card

    func testU18_TheEvaluationFollowsTheSnapshotAndACardChangeLeavesTheEstimateAndTheLinesUnchanged() throws {
        let s = scene()
        let cardKey = try XCTUnwrap(s.seed).cardKey
        let base = try evaluation(s)
        XCTAssertEqual(base.deliveryCents, 3300)
        // Another item: 700 x 2 + 500.
        var result = try evaluation(s) { $0.chooseOption(LateSwitch.itemKey, "gyoza") }
        XCTAssertEqual(result.deliveryCents, 1900)
        XCTAssertEqual(result.line, DeliveryLine(itemID: "gyoza", quantity: 2))
        XCTAssertEqual(result.estimateLine, "Booking est. $60.00 - Delivery est. $19.00")
        XCTAssertEqual(result.standingLine, "$181.00 left this week after the switch")
        // Another quantity.
        result = try evaluation(s) { $0.setText(LateSwitch.quantityKey, "3") }
        XCTAssertEqual(result.deliveryCents, 1400 * 3 + 500)
        XCTAssertEqual(result.line?.quantity, 3)
        result = try evaluation(s) { $0.setText(LateSwitch.quantityKey, "9") }
        XCTAssertEqual(result.deliveryCents, 1400 * 9 + 500)
        // Another card: the snapshot's card changes and nothing else of the numbers or the lines.
        result = try evaluation(s) { $0.chooseOption(cardKey, "credit-1881") }
        XCTAssertEqual(result.card, Self.cards[1])
        XCTAssertEqual(result.deliveryCents, base.deliveryCents)
        XCTAssertEqual(result.leftAfterCents, base.leftAfterCents)
        XCTAssertEqual(result.estimateLine, base.estimateLine)
        XCTAssertEqual(result.standingLine, base.standingLine)
        // A blank quantity gives no estimate lines.
        result = try evaluation(s) { $0.setText(LateSwitch.quantityKey, "") }
        XCTAssertNil(result.deliveryCents)
        XCTAssertNil(result.leftAfterCents)
        XCTAssertNil(result.estimateLine)
        XCTAssertNil(result.standingLine)
        XCTAssertNil(result.line)
        XCTAssertEqual(result.bookingCents, 6000, "the booking's amount does not depend on the card")
        // A quantity of zero is outside the rule: no estimate either.
        result = try evaluation(s) { $0.setText(LateSwitch.quantityKey, "0") }
        XCTAssertNil(result.deliveryCents)
        XCTAssertNil(result.estimateLine)
    }

    func testU19_AnEditedArrivalIsJudgedAgainOutsideTheHoursPastOneHundredTwentyMinutesInAnotherWeekOrPassedIsNotUsable() throws {
        let s = scene()
        let arriveKey = try XCTUnwrap(s.seed).arriveKey
        func usable(_ date: Date) throws -> Bool {
            try evaluation(s) { $0.chooseTime(arriveKey, date) }.arrivalUsable
        }
        XCTAssertTrue(try evaluation(s).arrivalUsable, "the seeded arrival")
        XCTAssertTrue(try usable(at(11, 2, 19, 30)), "inside")
        XCTAssertTrue(try usable(at(11, 2, 18, 47)), "the current minute")
        XCTAssertTrue(try usable(at(11, 2, 21, 0)), "120 minutes after the start")
        XCTAssertFalse(try usable(at(11, 2, 21, 1)), "past 120 minutes")
        XCTAssertFalse(try usable(at(11, 2, 18, 46)), "passed")
        XCTAssertFalse(try usable(at(11, 2, 9, 59)), "before the hours")
        XCTAssertFalse(try usable(at(11, 2, 22, 1)), "after the hours (and past 120 minutes)")
        XCTAssertFalse(try usable(at(11, 9, 19, 30)), "another week")
        // The edit is what the evaluation reads: the date comes back as the card holds it.
        let edited = try evaluation(s) { $0.chooseTime(arriveKey, at(11, 2, 19, 30)) }
        XCTAssertEqual(edited.arrival, at(11, 2, 19, 30))
    }

    // MARK: T32-T35 the leg screen and its host (SPEC-SWITCHLEG-001)

    func testT32_ShowsLegContentIsTrueWhileTheLegIsStoredAndFalseOnceItIsGone() {
        XCTAssertTrue(LateSwitch.showsLegContent(legIsStored: true))
        XCTAssertFalse(LateSwitch.showsLegContent(legIsStored: false))
    }

    func testT33_TheLegScreenDrawsTheBaseBodyOnlyWhileTheLegIsStoredAndTheSectionAloneOtherwise() throws {
        let source = try sourceText("Shared/EventDetailView.swift")
        let branch = "if LateSwitch.showsLegContent(legIsStored: store.events.contains(where: { $0.id == passedEvent.id })) {"
        XCTAssertEqual(source.components(separatedBy: branch).count - 1, 1, "the branch line occurs once")
        let branchRange = try XCTUnwrap(source.range(of: branch))
        let afterBranch = source[branchRange.upperBound...]
        let legBodyUse = try XCTUnwrap(afterBranch.range(of: "legBody"))
        let elseUse = try XCTUnwrap(afterBranch.range(of: "else"))
        XCTAssertLessThan(legBodyUse.lowerBound, elseUse.lowerBound, "the stored branch draws the base body before the else")
        let sectionLine = "LateSwitchSection(event: event, lateOutcome: nil)"
        XCTAssertEqual(source.components(separatedBy: sectionLine).count - 1, 1, "the section alone occurs once")
        let sectionUse = try XCTUnwrap(source.range(of: sectionLine))
        XCTAssertGreaterThan(sectionUse.lowerBound, elseUse.upperBound, "and only in the gone branch, after the else")
        XCTAssertEqual(source.components(separatedBy: "private var legBody: some View {").count - 1, 1, "the base body is the renamed one")
        XCTAssertEqual(source.components(separatedBy: "lateOutcome: lines?.kind == .late").count - 1, 1,
                       "the departure card keeps its own section call")
    }

    func testT35_TheHostSheetKeepsTheRetainedLegAndPicksTheLegItShowsThroughTheHelper() throws {
        let source = try sourceText("Shared/ContentView.swift")
        XCTAssertEqual(source.components(separatedBy: "@State private var retainedLeg: ScheduledEvent?").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: ".onChange(of: selection, initial: true)").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "retainedLeg = selectedEvent").count - 1, 1)
        let change = try XCTUnwrap(source.range(of: ".onChange(of: selection, initial: true)"))
        let keep = try XCTUnwrap(source.range(of: "retainedLeg = selectedEvent"))
        XCTAssertLessThan(change.lowerBound, keep.lowerBound, "the retained leg is set inside the change handler")
        let sheetLine = "if let event = LateSwitch.openedLeg(stored: selectedEvent, retained: retainedLeg, selection: selection) {"
        XCTAssertEqual(source.components(separatedBy: sheetLine).count - 1, 1)
        XCTAssertLessThan(keep.lowerBound, try XCTUnwrap(source.range(of: sheetLine)).lowerBound, "before the leg sheet reads it")
        XCTAssertEqual(source.components(separatedBy: "if let event = selectedEvent {").count - 1, 0,
                       "the sheet no longer reads the stored leg alone")
    }
}

// MARK: - The steps (milestone M4, T01-T26)

/// A value two threads may share: the stubs call their hooks from wherever the transport runs.
final class SwitchBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Names the requests that reach the stub partners in the order they arrive, and runs a hook inside the send of a named one.
final class SwitchCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var hooks: [String: @Sendable () -> Void] = [:]

    var list: [String] { lock.lock(); defer { lock.unlock() }; return names }

    func count(_ name: String) -> Int { list.filter { $0 == name }.count }

    func add(_ name: String) {
        lock.lock()
        names.append(name)
        let hook = hooks[name]
        lock.unlock()
        hook?()
    }

    func on(_ name: String, _ hook: @escaping @Sendable () -> Void) {
        lock.lock()
        hooks[name] = hook
        lock.unlock()
    }
}

final class SwitchIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        made += 1
        return String(format: "00000000-0000-4000-8000-%012d", made)
    }
}

@MainActor
final class SwitchClock {
    var now: Date
    var zone: TimeZone

    init(now: Date, zone: TimeZone) {
        self.now = now
        self.zone = zone
    }
}

extension LateSwitchCenter.State {
    var offerValue: LateSwitchCenter.Offer? {
        if case .offer(let value) = self { return value }
        return nil
    }

    var noteText: String? {
        if case .note(let text) = self { return text }
        return nil
    }

    var resultValue: LateSwitchCenter.Result? {
        if case .finished(let value) = self { return value }
        return nil
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

/// The scene of the worked case on a Monday evening in `zone`: a booked entry at 19:00 with one arrival leg, a ledger entry of
/// $60.00 for the booking, a record with a quantity hint of 2, and stub partners for the budget, the delivery and the cancel. Every
/// file is a temporary one; the clock and the zone are the rig's.
@MainActor
final class SwitchRig {
    nonisolated static let host = "switch-host.invalid"
    nonisolated static let token = "switch-token-0001"
    nonisolated static let config = AppConfig(kakaoJsKey: "", proxyBaseURL: "https://" + host, appToken: token)
    nonisolated static let unconfigured = AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: "")
    nonisolated static let seoul = TimeZone(identifier: "Asia/Seoul")!
    nonisolated static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    nonisolated static let bistro = Place(name: "Test Bistro", address: "5 Example Road", latitude: 37.5, longitude: 127.0)
    nonisolated static let home = Place(name: "Home", address: "1 Home Road", latitude: 37.4, longitude: 127.1)
    nonisolated static let deviceFix = Place(name: "Current location", address: "", latitude: 37.4, longitude: 127.1)
    nonisolated static let requestID = "3f2b8c1e-5d4a-4e7b-9a60-1c2d3e4f5a6b"
    nonisolated static let spendID = "spend-1"
    nonisolated static let week = "2026-11-02"
    nonisolated static let cancelledBody = #"{"partner":"Example Tables","simulated":true,"status":"cancelled"}"#
    nonisolated static let declinedBody = #"{"partner":"Example Tables","reason":"no_booking","simulated":true,"status":"declined"}"#
    nonisolated static let unauthorized = #"{"error":"unauthorized"}"#
    nonisolated static let bookingEntry = BudgetEntry(requestID: spendID, weekStart: week, amountCents: 6000, isEstimate: true)

    /// The packets of a full success, in order, without the calendar hop.
    nonisolated static let fullFlow = ["Budget left asked", "Budget left answered", "Options requested", "Options received",
                           "Delivery of 2 items requested", "Order confirmed", "Example Tables: Cancellation requested",
                           "Example Tables: Request cancelled", "Spend sent", "Spend recorded"]

    let zone0: TimeZone
    let clock: SwitchClock
    let store: Store
    let box: BookingConfigBox
    let budget = BudgetToolPartner()
    let delivery = DeliveryToolPartner()
    let tables: BookingSendRecorder
    let places: PlacesTransportStub
    let log: ConnectionLog
    let ledger: BudgetLedger
    let ledgerFile: URL
    let records: PartnerRecords
    let recordsFile: URL
    let recordsGate = SwitchableWrite()
    let orders: DeliveryOrderLog
    let calls = SwitchCalls()
    let ids = SwitchIDs()
    let activityID: UUID
    /// The leg as the view hands it to the center (its origin is nil when the scene asks for none).
    let event: ScheduledEvent
    let outcome: ReplanOutcome
    private(set) var center: LateSwitchCenter!

    static func time(_ zone: TimeZone, _ hour: Int, _ minute: Int, _ second: Double = 0, day: Int = 2) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)
        return calendar.date(from: parts)!.addingTimeInterval(second)
    }

    func at(_ hour: Int, _ minute: Int, _ second: Double = 0, day: Int = 2) -> Date {
        Self.time(zone0, hour, minute, second, day: day)
    }

    /// A late result of the leg checked at `checkedAt` (the live travel time is 24 minutes 30 seconds).
    static func makeOutcome(leg: ScheduledEvent, zone: TimeZone, checkedAt: Date, liveTravel: TimeInterval = 24 * 60 + 30) -> ReplanOutcome {
        Replan.classify(eventID: leg.id, trigger: .appOpen, checkedAt: checkedAt, inputs: ReplanInputs(event: leg),
                        referenceDeparture: time(zone, 18, 20), referenceTravel: 25 * 60, liveTravel: liveTravel,
                        noTrafficTravel: nil, now: checkedAt)
    }

    init(_ test: XCTestCase, zone: TimeZone = SwitchRig.seoul, sync: Bool = false, hint: Int? = 2, estimate: Int? = 6000,
         ledgerAmount: Int? = 6000, withRecord: Bool = true, place: Place = SwitchRig.bistro, origin: Place? = SwitchRig.home,
         extraSpent: Int = 0) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("late-switch-\(UUID().uuidString)", isDirectory: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let clock = SwitchClock(now: Self.time(zone, 18, 47), zone: zone)
        let store = EmptyStore.make()
        store.config = AppConfig()
        let start = Self.time(zone, 19, 0)
        let made = await store.addActivityWithTravel(
            title: "Dinner at Test Bistro (Simulated)", location: place, startDate: start, endDate: start.addingTimeInterval(3600),
            travelFrom: origin ?? Self.home, returnTo: nil, outboundMode: .car, returnMode: .car, bufferMinutes: 0,
            notifyLeadMinutes: 0, notifyEnabled: false, syncToCalendar: sync, travelSecondsHint: 1470)
        var leg = try XCTUnwrap(store.events.first { $0.linkedActivityId == made.activityId })
        if origin == nil { leg.origin = nil }
        let outcome = Self.makeOutcome(leg: leg, zone: zone, checkedAt: clock.now)
        XCTAssertEqual(outcome.kind, .late, "the control: the scene's result is late")

        let ledgerFile = folder.appendingPathComponent(BudgetLedger.fileName)
        let ledger = BudgetLedger(fileURL: ledgerFile)
        if let ledgerAmount {
            ledger.add(BudgetEntry(requestID: Self.spendID, weekStart: Self.week, amountCents: ledgerAmount, isEstimate: true))
        }
        if extraSpent > 0 {
            ledger.add(BudgetEntry(requestID: "other-1", weekStart: Self.week, amountCents: extraSpent, isEstimate: false))
        }
        let recordsFile = folder.appendingPathComponent(PartnerRecords.fileName)
        let gate = recordsGate
        let records = PartnerRecords(fileURL: recordsFile, write: gate.write)
        if withRecord {
            records.add(PartnerRecord(activityID: made.activityId, partnerID: "booking", partnerName: "Example Tables", route: "/booking",
                                      requestID: Self.requestID, estimateCents: estimate, quantityHint: hint,
                                      spendRequestID: ledgerAmount == nil ? nil : Self.spendID, switchStarted: false))
        }

        self.zone0 = zone
        self.clock = clock
        self.store = store
        self.box = BookingConfigBox(Self.config)
        self.tables = BookingSendRecorder(body: Self.cancelledBody)
        self.places = PlacesTransportStub.answering(with: PlacesTestSupport.nearbyAnswer([(name: "Cafe One", meters: 100)]))
        self.log = ConnectionLog(fileURL: folder.appendingPathComponent(ConnectionLog.fileName), secrets: { [Self.token, Self.host] })
        self.ledger = ledger
        self.ledgerFile = ledgerFile
        self.records = records
        self.recordsFile = recordsFile
        self.orders = DeliveryOrderLog(fileURL: folder.appendingPathComponent(DeliveryOrderLog.fileName))
        self.activityID = made.activityId
        self.event = leg
        self.outcome = outcome

        let calls = self.calls
        let budget = self.budget
        let delivery = self.delivery
        budget.duringSend = {
            let op = budget.body(budget.requests.count - 1)?["op"] as? String ?? "?"
            calls.add("budget-\(op)")
        }
        delivery.duringSend = {
            let op = delivery.body(delivery.requests.count - 1)?["op"] as? String ?? "?"
            calls.add("delivery-\(op)")
        }
        tables.duringSend = { calls.add("cancel") }
        center = LateSwitchCenter(dependencies: dependencies(records: records))
    }

    func dependencies(records: PartnerRecords) -> LateSwitchCenter.Dependencies {
        let box = self.box
        let ledger = self.ledger
        let log = self.log
        let budget = self.budget
        let delivery = self.delivery
        let tables = self.tables
        let places = self.places
        let clock = self.clock
        let ids = self.ids
        return LateSwitchCenter.Dependencies(
            store: store,
            budget: { BudgetClient(config: box.config, ledger: ledger, send: budget.send, connections: log) },
            delivery: { DeliveryClient(config: box.config, send: delivery.send, connections: log) },
            partners: { PartnerClient(config: box.config, send: tables.send, connections: log) },
            ledger: ledger, records: records, orders: orders,
            placeSearch: { PlaceSearch(config: PlacesTestSupport.config, transport: places.transport, connections: log) },
            now: { clock.now }, zone: { clock.zone }, newID: { ids.next() }, log: log)
    }

    // MARK: Driving

    var entry: ActivityBlock? { store.activity(id: activityID) }
    var state: LateSwitchCenter.State? { center.states[activityID] }

    func check(_ result: ReplanOutcome? = nil) async {
        await center.check(event: event, outcome: result ?? outcome, store: store)
    }

    func offer() throws -> LateSwitchCenter.Offer { try XCTUnwrap(state?.offerValue, "an offer is shown") }

    /// A later late result of the same leg; the clock moves to its check.
    func laterOutcome() -> ReplanOutcome {
        clock.now = at(18, 50)
        return Self.makeOutcome(leg: event, zone: zone0, checkedAt: at(18, 50))
    }

    func restore() {
        box.config = Self.config
        budget.mode = .worker
        delivery.mode = .worker
    }

    /// Waits until the center is neither checking nor running.
    func settle() async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let current = state, current.isRunning || current.isChecking {
                try? await Task.sleep(nanoseconds: 5_000_000)
            } else {
                return
            }
        }
        XCTFail("the center did not settle")
    }

    /// Waits until the tap has left the offer (running, a note, a result or a new read).
    func untilTapped() async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if state?.offerValue == nil { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the tap did not happen")
    }

    func tap() async {
        center.confirm(activityID: activityID)
        await settle()
    }

    func packets(in flow: UUID? = nil) async -> [ConnectionPacket] {
        await log.flush()
        return log.packets.filter { flow == nil || $0.flowID == flow }
    }

    func body(_ requests: [URLRequest], op: String) -> [String: Any]? {
        for request in requests.reversed() {
            if let data = request.httpBody, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               object["op"] as? String == op { return object }
        }
        return nil
    }

    var orderBody: [String: Any]? { body(delivery.requests, op: "order") }
    var spendBody: [String: Any]? { body(budget.requests, op: "spend") }

    nonisolated static func mark(at url: URL) -> Bool? {
        guard let data = try? Data(contentsOf: url), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let first = list.first else { return nil }
        return first["switchStarted"] as? Bool
    }

    /// How many stored events link to `activityId`, read from the saved schedule file. A hook runs off the main actor, so it
    /// reads the file the Store writes after every change instead of the Store itself. Nil when the file cannot be read or
    /// decoded: a hook that saw no file leaves its test failing instead of counting no legs.
    nonisolated static func linkedLegCount(activityId: UUID, at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([ScheduledEvent].self, from: data) else { return nil }
        return list.filter { $0.linkedActivityId == activityId }.count
    }

    func resultLines() -> [String]? { state?.resultValue?.lines }
}

/// SPEC-LATESWITCH-001 (card t72), AC-LATESWITCH-005 to 008: the center that reads, offers, checks the tap and runs the steps.
/// Every partner is a stub, the clock and the zone are injected, and every file is a temporary one.
@MainActor
final class LateSwitchStepsTests: XCTestCase {
    private let seoul = SwitchRig.seoul
    private let losAngeles = SwitchRig.losAngeles

    private func sourceText(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func summaries(_ packets: [ConnectionPacket]) -> [String] { packets.map(\.summary) }

    /// What the booking was before the steps: nothing sent beyond the two reads, nothing changed.
    private func assertUntouched(_ rig: SwitchRig, sent: [String] = ["budget-left", "delivery-options"], file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertEqual(rig.calls.list, sent, file: file, line: line)
        XCTAssertEqual(rig.ledger.entry(requestID: SwitchRig.spendID), SwitchRig.bookingEntry, file: file, line: line)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: SwitchRig.week), 6000, file: file, line: line)
        XCTAssertEqual(rig.entry?.startDate, rig.at(19, 0), file: file, line: line)
        XCTAssertEqual(rig.entry?.title, "Dinner at Test Bistro (Simulated)", file: file, line: line)
        XCTAssertNotNil(rig.records.record(forActivity: rig.activityID), file: file, line: line)
        XCTAssertTrue(rig.orders.orders.isEmpty, file: file, line: line)
    }

    private static func until(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the condition did not come true")
    }

    // MARK: T01-T04 the steps

    func testT01_FullSuccessRunsTheCallsInOrderWritesTheElevenPacketsUnderOneFlowAndShowsTheResultLines() async throws {
        let rig = try await SwitchRig(self, sync: true)
        await rig.check()
        let offer = try rig.offer()
        XCTAssertEqual(offer.evaluation.estimateLine, "Booking est. $60.00 - Delivery est. $33.00")
        XCTAssertEqual(offer.evaluation.standingLine, "$167.00 left this week after the switch")
        XCTAssertTrue(rig.center.canConfirm(activityID: rig.activityID))
        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options"])

        await rig.tap()
        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options", "delivery-order", "cancel", "budget-spend"])
        let flow = await rig.packets(in: offer.flow)
        XCTAssertEqual(summaries(flow), SwitchRig.fullFlow + ["Event move sent"])
        XCTAssertEqual(flow.map(\.from), [.besir, .budgetPartner, .besir, .deliveryPartner, .besir, .deliveryPartner, .besir, .partner,
                                          .besir, .budgetPartner, .besir])
        XCTAssertEqual(flow.map(\.to), [.budgetPartner, .besir, .deliveryPartner, .besir, .deliveryPartner, .besir, .partner, .besir,
                                        .budgetPartner, .besir, .appleCalendar])
        XCTAssertEqual(flow.last?.kind, .calendarSave)
        XCTAssertTrue(flow.allSatisfy { $0.status == .ok })
        let everything = await rig.packets()
        XCTAssertEqual(everything.count, 11, "no packet outside the offer's flow")

        XCTAssertEqual(rig.resultLines(), [
            "Booking cancelled",
            "Delivery DL-AB12CD arrives 7:12 PM",
            "Schedule entry moved to 7:12 PM",
            "Estimated total $33.00 sent to Example Budget (Simulated): $167.00 left this week."])
        XCTAssertFalse(rig.center.canConfirm(activityID: rig.activityID))
    }

    func testT02_TheBookingsLedgerEntryIsRemovedAfterTheCancelAnswerAndBeforeTheSpendWhichCarriesTheDeliverysRequestIDAndTheArrivalsWeek() async throws {
        let rig = try await SwitchRig(self)
        let seen = SwitchBox<[String]>([])
        let ledger = rig.ledger
        rig.calls.on("cancel") { seen.value += ["cancel:" + (ledger.contains(requestID: SwitchRig.spendID) ? "in" : "out")] }
        rig.calls.on("budget-spend") { seen.value += ["spend:" + (ledger.contains(requestID: SwitchRig.spendID) ? "in" : "out")] }
        await rig.check()
        await rig.tap()
        XCTAssertEqual(seen.value, ["cancel:in", "spend:out"])

        let order = try XCTUnwrap(rig.orderBody)
        let orderID = try XCTUnwrap(order["request_id"] as? String)
        let spend = try XCTUnwrap(rig.spendBody)
        XCTAssertEqual(spend["request_id"] as? String, orderID)
        XCTAssertEqual(spend["amount_cents"] as? Int, 3300)
        XCTAssertEqual(spend["week_start"] as? String, "2026-11-02")
        XCTAssertEqual(spend["spent_cents"] as? Int, 0, "the booking's entry was already released")
        XCTAssertNil(rig.ledger.entry(requestID: SwitchRig.spendID))
        XCTAssertEqual(rig.ledger.entry(requestID: orderID),
                       BudgetEntry(requestID: orderID, weekStart: "2026-11-02", amountCents: 3300, isEstimate: true))
        XCTAssertEqual(rig.ledger.spentCents(weekStart: "2026-11-02"), 3300)
        XCTAssertTrue(rig.ledger.hasEstimate(weekStart: "2026-11-02"))
    }

    func testT03_TheEntryIsRetitledMovedToTheArrivalKeepsItsLengthAndPlaceAndNoLegIsLeftAndTheRecordIsGone() async throws {
        let rig = try await SwitchRig(self)
        let before = try XCTUnwrap(rig.entry)
        XCTAssertNotNil(Replan.displayLines(for: rig.outcome, event: rig.event, now: rig.clock.now, timeZone: rig.zone0), "the control")
        await rig.check()
        await rig.tap()

        let after = try XCTUnwrap(rig.entry)
        XCTAssertEqual(after.title, "Dinner (Simulated)")
        XCTAssertEqual(after.startDate, rig.at(19, 12))
        XCTAssertEqual(after.endDate.timeIntervalSince(after.startDate), before.endDate.timeIntervalSince(before.startDate))
        XCTAssertEqual(after.location, before.location)
        XCTAssertFalse(rig.store.events.contains { $0.linkedActivityId == rig.activityID }, "no event links to the entry")
        XCTAssertFalse(rig.store.events.contains { $0.id == rig.event.id }, "the old leg is not stored any more")
        XCTAssertNil(rig.records.record(forActivity: rig.activityID), "the record is removed after a move")
        XCTAssertNil(SwitchRig.mark(at: rig.recordsFile), "and so is its file entry")
    }

    func testT04_EventMoveSentIsWrittenOnlyWhenTheMovedEntrySyncsToAppleCalendar() async throws {
        for sync in [true, false] {
            let rig = try await SwitchRig(self, sync: sync)
            await rig.check()
            let offer = try rig.offer()
            await rig.tap()
            let flow = await rig.packets(in: offer.flow)
            let hops = flow.filter { $0.to == .appleCalendar }
            XCTAssertEqual(hops.count, sync ? 1 : 0, "sync \(sync)")
            XCTAssertEqual(flow.count, sync ? 11 : 10, "sync \(sync)")
            if sync {
                XCTAssertEqual(hops.first?.summary, "Event move sent")
                XCTAssertEqual(hops.first?.kind, .calendarSave)
                XCTAssertEqual(hops.first?.from, .besir)
                XCTAssertEqual(hops.first?.status, .ok)
                XCTAssertEqual(flow.last?.summary, "Event move sent", "it comes after the spend")
            }
            XCTAssertEqual(rig.resultLines()?.count, 4)
        }
    }

    // MARK: T05-T08 the tap that sends nothing, or the delivery that does not come

    func testT05_ADeclinedDeliveryShowsTheNoteAndLeavesEverythingElseAloneWithTheMarkCleared() async throws {
        let rig = try await SwitchRig(self)
        await rig.check()
        let offer = try rig.offer()
        rig.center.confirm(activityID: rig.activityID)
        // The device zone changes before the request is made: the partner then reads an arrival outside its hours and declines it.
        rig.clock.zone = rig.zone0 == seoul ? losAngeles : seoul
        await rig.settle()

        XCTAssertEqual(rig.state?.noteText, "The delivery could not be ordered. Nothing was changed.")
        XCTAssertEqual(rig.orderBody?["arrive_at"] as? String, "2026-11-02T02:12", "the control: the order was made and refused")
        assertUntouched(rig, sent: ["budget-left", "delivery-options", "delivery-order"])
        XCTAssertEqual(rig.records.record(forActivity: rig.activityID)?.switchStarted, false)
        XCTAssertEqual(SwitchRig.mark(at: rig.recordsFile), false)
        let flow = await rig.packets(in: offer.flow)
        XCTAssertEqual(summaries(flow).suffix(2), ["Delivery of 2 items requested", "Order not available"])
        XCTAssertEqual(flow.last?.status, .declined)
        XCTAssertEqual(flow.count, 6)
    }

    func testT06_NoProxyAndTheWorkers401ClearTheMarkOfflineAndTheOtherEndingsKeepItAndAFailedWriteOfTheMarkSendsNothing() async throws {
        let endings: [(name: String, clears: Bool, before: (SwitchRig) -> Void, after: (SwitchRig) -> Void)] = [
            ("no proxy", true, { _ in }, { $0.box.config = SwitchRig.unconfigured }),
            ("401 with the Worker's body", true, { $0.delivery.mode = .status(401, SwitchRig.unauthorized) }, { _ in }),
            ("401 with another body", false, { $0.delivery.mode = .status(401, "denied") }, { _ in }),
            ("offline", false, { $0.delivery.mode = .error(URLError(.notConnectedToInternet)) }, { _ in }),
            ("404", false, { $0.delivery.mode = .status(404, "Not found") }, { _ in }),
            ("500", false, { $0.delivery.mode = .status(500, "oops") }, { _ in }),
            ("a deviating 200", false, { $0.delivery.mode = .status(200, "{}") }, { _ in })]
        for ending in endings {
            let rig = try await SwitchRig(self)
            await rig.check()
            ending.before(rig)
            rig.center.confirm(activityID: rig.activityID)
            ending.after(rig)
            await rig.settle()

            let expected = ending.clears ? "The delivery could not be ordered. Nothing was changed."
                                         : "The delivery could not be confirmed. Nothing else was changed."
            XCTAssertEqual(rig.state?.noteText, expected, ending.name)
            XCTAssertEqual(rig.records.record(forActivity: rig.activityID)?.switchStarted, !ending.clears, ending.name)
            XCTAssertEqual(SwitchRig.mark(at: rig.recordsFile), !ending.clears, ending.name)
            XCTAssertEqual(rig.calls.count("cancel"), 0, ending.name)
            XCTAssertEqual(rig.calls.count("budget-spend"), 0, ending.name)
            XCTAssertEqual(rig.ledger.entry(requestID: SwitchRig.spendID), SwitchRig.bookingEntry, ending.name)
            XCTAssertEqual(rig.entry?.startDate, rig.at(19, 0), ending.name)
            XCTAssertTrue(rig.orders.orders.isEmpty, ending.name)
            // A later result: offered again only when the mark is clear.
            rig.restore()
            await rig.check(rig.laterOutcome())
            XCTAssertEqual(rig.calls.count("budget-left"), ending.clears ? 2 : 1, ending.name)
            XCTAssertEqual(rig.state?.offerValue != nil, ending.clears, ending.name)
            if !ending.clears { XCTAssertEqual(rig.state?.noteText, expected, ending.name) }
        }

        // The mark is written before the request, on disk, and a failed write sends nothing and leaves it false.
        let early = try await SwitchRig(self)
        let atOrder = SwitchBox<Bool?>(nil)
        let file = early.recordsFile
        early.calls.on("delivery-order") { atOrder.value = SwitchRig.mark(at: file) }
        await early.check()
        await early.tap()
        XCTAssertEqual(atOrder.value, true, "the mark was on disk when the delivery request arrived")

        let failing = try await SwitchRig(self)
        await failing.check()
        failing.recordsGate.isFailing = true
        await failing.tap()
        XCTAssertEqual(failing.state?.noteText, "Nothing was changed.")
        XCTAssertEqual(failing.records.record(forActivity: failing.activityID)?.switchStarted, false)
        assertUntouched(failing)
    }

    func testT07_AnArrivalThatIsNoLongerUsableAtTheTapSendsNothingAndSaysSo() async throws {
        let note = "That arrival time cannot be used. Nothing was changed."
        // The minute passed while the offer was open.
        let passed = try await SwitchRig(self)
        await passed.check()
        let offer = try passed.offer()
        passed.clock.now = passed.at(19, 30)
        await passed.tap()
        XCTAssertEqual(passed.state?.noteText, note)
        XCTAssertTrue(offer.card.isFrozen, "the card was frozen by the tap")
        assertUntouched(passed)
        XCTAssertEqual(passed.records.record(forActivity: passed.activityID)?.switchStarted, false)

        // An edit outside the rule: after the hours, past 120 minutes, another week.
        let edits: [(String, (SwitchRig) -> Date)] = [("after the hours", { $0.at(22, 30) }), ("past 120 minutes", { $0.at(21, 30) }),
                                                      ("another week", { $0.at(19, 30, day: 9) })]
        for (name, edit) in edits {
            let rig = try await SwitchRig(self)
            await rig.check()
            let current = try rig.offer()
            XCTAssertTrue(current.card.chooseTime(current.seed.arriveKey, edit(rig)), name)
            await rig.tap()
            XCTAssertEqual(rig.state?.noteText, note, name)
            assertUntouched(rig)
        }
    }

    func testT08_ATapWithoutTheEntryTheRecordOrTheProxyOrWithTheMarkSetSendsNothingAndSaysNothingWasChanged() async throws {
        let vanish: [(String, (SwitchRig) -> Void)] = [
            ("the record is gone", { _ = $0.records.remove(activityID: $0.activityID) }),
            ("the entry is gone", { rig in if let entry = rig.entry { rig.store.deleteActivity(entry) } }),
            ("the proxy is gone", { $0.box.config = SwitchRig.unconfigured }),
            ("the mark is set", { _ = $0.records.setSwitchStarted(true, forActivity: $0.activityID) })]
        for (name, change) in vanish {
            let rig = try await SwitchRig(self)
            await rig.check()
            change(rig)
            await rig.tap()
            XCTAssertEqual(rig.state?.noteText, "Nothing was changed.", name)
            XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options"], name)
            XCTAssertTrue(rig.orders.orders.isEmpty, name)
            XCTAssertEqual(rig.ledger.entry(requestID: SwitchRig.spendID), SwitchRig.bookingEntry, name)
        }
    }

    // MARK: T09-T11 the endings after a confirmed delivery

    func testT09_ADeclinedCancelKeepsTheLedgerEntryDoesNotMoveTheEntryRecordsTheDeliverySpendOnceAndWritesTheOrderRecord() async throws {
        let rig = try await SwitchRig(self, sync: true)
        rig.tables.result = .success((Data(SwitchRig.declinedBody.utf8), 200))
        await rig.check()
        let offer = try rig.offer()
        await rig.tap()

        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options", "delivery-order", "cancel", "budget-spend"])
        XCTAssertEqual(rig.ledger.entry(requestID: SwitchRig.spendID), SwitchRig.bookingEntry, "the booking's entry stays")
        XCTAssertEqual(rig.ledger.spentCents(weekStart: SwitchRig.week), 9300)
        XCTAssertEqual(rig.calls.count("budget-spend"), 1)
        XCTAssertEqual(rig.entry?.startDate, rig.at(19, 0), "the entry is not moved")
        XCTAssertEqual(rig.entry?.title, "Dinner at Test Bistro (Simulated)")
        XCTAssertNotNil(rig.records.record(forActivity: rig.activityID), "the record stays")
        XCTAssertEqual(rig.orders.orders.count, 1)
        XCTAssertNil(rig.orders.orders.first?.mealActivityID)
        XCTAssertEqual(rig.resultLines(), [
            "Delivery DL-AB12CD arrives 7:12 PM",
            "The booking could not be cancelled.",
            "Estimated total $33.00 sent to Example Budget (Simulated): $107.00 left this week."])
        let flow = await rig.packets(in: offer.flow)
        XCTAssertEqual(summaries(flow), Array(SwitchRig.fullFlow.prefix(7)) + ["Example Tables: Cancellation declined", "Spend sent", "Spend recorded"])
        XCTAssertEqual(flow[7].status, .declined)
        XCTAssertTrue(flow.allSatisfy { $0.to != .appleCalendar }, "nothing was moved")
    }

    func testT10_ACancelThatFailsLikeAnOldWorkersNotFoundEndsAsADeclinedOne() async throws {
        let rig = try await SwitchRig(self, sync: true)
        rig.tables.result = .success((Data("Not found".utf8), 404))
        await rig.check()
        let offer = try rig.offer()
        await rig.tap()

        XCTAssertEqual(rig.ledger.entry(requestID: SwitchRig.spendID), SwitchRig.bookingEntry)
        XCTAssertEqual(rig.ledger.spentCents(weekStart: SwitchRig.week), 9300)
        XCTAssertEqual(rig.calls.count("budget-spend"), 1)
        XCTAssertEqual(rig.entry?.startDate, rig.at(19, 0))
        XCTAssertNotNil(rig.records.record(forActivity: rig.activityID))
        XCTAssertEqual(rig.orders.orders.count, 1)
        XCTAssertNil(rig.orders.orders.first?.mealActivityID)
        XCTAssertEqual(rig.resultLines()?[1], "The booking could not be cancelled.")
        XCTAssertEqual(rig.resultLines()?.count, 3)
        let flow = await rig.packets(in: offer.flow)
        XCTAssertEqual(summaries(flow), Array(SwitchRig.fullFlow.prefix(6)) + ["Request failed", "Spend sent", "Spend recorded"])
        XCTAssertEqual(flow[6].status, .failed)
    }

    func testT11_AFailedBudgetRequestAfterAGoodCancelUndoesNothingAndPutsTheReleasedEntryBackUnchanged() async throws {
        let rig = try await SwitchRig(self, sync: true, extraSpent: 2500)
        await rig.check()
        let offer = try rig.offer()
        let before = rig.ledger.spentCents(weekStart: SwitchRig.week)
        XCTAssertEqual(before, 8500)
        rig.budget.mode = .status(500, "oops")
        await rig.tap()

        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options", "delivery-order", "cancel", "budget-spend"])
        XCTAssertEqual(rig.ledger.entry(requestID: SwitchRig.spendID), SwitchRig.bookingEntry, "put back unchanged")
        XCTAssertEqual(rig.ledger.spentCents(weekStart: SwitchRig.week), before, "same sum")
        XCTAssertTrue(rig.ledger.hasEstimate(weekStart: SwitchRig.week), "same estimate flag")
        let deliveryID = try XCTUnwrap(rig.orderBody?["request_id"] as? String)
        XCTAssertFalse(rig.ledger.contains(requestID: deliveryID), "no delivery entry")
        XCTAssertEqual(rig.entry?.startDate, rig.at(19, 12), "the entry was moved")
        XCTAssertNil(rig.records.record(forActivity: rig.activityID))
        XCTAssertEqual(rig.orders.orders.count, 1)
        XCTAssertEqual(rig.orders.orders.first?.mealActivityID, rig.activityID.uuidString)
        XCTAssertEqual(rig.resultLines(), [
            "Booking cancelled",
            "Delivery DL-AB12CD arrives 7:12 PM",
            "Schedule entry moved to 7:12 PM",
            "The estimated total could not be sent to Example Budget (Simulated)."])
        let flow = await rig.packets(in: offer.flow)
        XCTAssertEqual(summaries(flow), Array(SwitchRig.fullFlow.prefix(8)) + ["Request failed", "Event move sent"])
    }

    // MARK: T12-T14 the task, the second tap, the reads

    func testT12_TheStepsFinishWhenTheViewGoesAwayAndTheResultIsKeptForTheEntry() async throws {
        let rig = try await SwitchRig(self)
        await rig.check()
        let holder = SwitchBox<Task<Void, Never>?>(nil)
        rig.calls.on("delivery-order") { holder.value?.cancel() }
        let id = rig.activityID
        let center = rig.center!
        let view = Task { @MainActor in
            center.confirm(activityID: id)
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        holder.value = view
        await rig.untilTapped()
        await rig.settle()
        XCTAssertTrue(view.isCancelled, "the control: the view's task was cancelled while the order was in flight")
        XCTAssertEqual(rig.resultLines()?.first, "Booking cancelled")
        XCTAssertEqual(rig.resultLines()?.count, 4)
        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options", "delivery-order", "cancel", "budget-spend"])
        XCTAssertEqual(rig.orders.orders.count, 1)
        // The result is kept: a later result of the leg changes nothing.
        await rig.check(rig.laterOutcome())
        XCTAssertEqual(rig.resultLines()?.first, "Booking cancelled")
    }

    func testT13_ASecondTapWhileRunningOrAfterFinishingSendsNothing() async throws {
        let rig = try await SwitchRig(self)
        await rig.check()
        rig.center.confirm(activityID: rig.activityID)
        XCTAssertEqual(rig.state?.isRunning, true)
        XCTAssertFalse(rig.center.canConfirm(activityID: rig.activityID), "the button is disabled while the steps run")
        rig.center.confirm(activityID: rig.activityID)
        await rig.settle()
        let counts = rig.calls.list
        XCTAssertEqual(counts, ["budget-left", "delivery-options", "delivery-order", "cancel", "budget-spend"])
        let finished = rig.state?.resultValue
        XCTAssertNotNil(finished)

        rig.center.confirm(activityID: rig.activityID)
        await rig.settle()
        XCTAssertEqual(rig.calls.list, counts)
        XCTAssertEqual(rig.state?.resultValue, finished)
        XCTAssertEqual(rig.orders.orders.count, 1)
    }

    func testT14_ItReadsOnceForAnEntryAndAnOutcomeAFailedReadShowsNothingAndACancelledReadDoesNotCount() async throws {
        let rig = try await SwitchRig(self)
        XCTAssertNil(rig.state)
        await rig.check()
        let first = try rig.offer()
        await rig.check()
        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options"], "the same entry and outcome reads once")
        // A new result reads again, under a new flow.
        await rig.check(rig.laterOutcome())
        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options", "budget-left", "delivery-options"])
        let second = try rig.offer()
        XCTAssertNotEqual(second.flow, first.flow)

        // A failed budget read shows nothing, asks for no options and is not repeated for the same result.
        let failed = try await SwitchRig(self)
        failed.budget.mode = .status(500, "oops")
        await failed.check()
        XCTAssertNil(failed.state)
        XCTAssertEqual(failed.calls.list, ["budget-left"])
        failed.budget.mode = .worker
        await failed.check()
        XCTAssertEqual(failed.calls.list, ["budget-left"], "not read again for the same result")
        await failed.check(failed.laterOutcome())
        XCTAssertNotNil(failed.state?.offerValue, "a later result reads again")

        // A failed options read shows nothing either.
        let noOptions = try await SwitchRig(self)
        noOptions.delivery.mode = .status(500, "oops")
        await noOptions.check()
        XCTAssertNil(noOptions.state)
        XCTAssertEqual(noOptions.calls.list, ["budget-left", "delivery-options"])

        // A read cancelled because the view went away does not count.
        let cancelled = try await SwitchRig(self)
        let holder = SwitchBox<Task<Void, Never>?>(nil)
        cancelled.calls.on("budget-left") { holder.value?.cancel() }
        let reading = Task { @MainActor in await cancelled.check() }
        holder.value = reading
        await reading.value
        XCTAssertNil(cancelled.state)
        XCTAssertEqual(cancelled.calls.list, ["budget-left"], "no options were asked for")
        cancelled.calls.on("budget-left") {}
        await cancelled.check()
        XCTAssertEqual(cancelled.calls.count("budget-left"), 2, "the same result reads again")
        XCTAssertNotNil(cancelled.state?.offerValue)
    }

    // MARK: T15-T17 when there is no offer, the zones, the visibility rule

    func testT15_ThereIsNoOfferForAResultThatIsNotLateALegWithoutARecordNoProxyOrAMissingEntry() async throws {
        let base = try await SwitchRig(self)
        await base.check()
        XCTAssertNotNil(base.state?.offerValue, "the control")

        let quiet = try await SwitchRig(self)
        let early = SwitchRig.makeOutcome(leg: quiet.event, zone: quiet.zone0, checkedAt: quiet.at(18, 0), liveTravel: 20 * 60)
        XCTAssertNotEqual(early.kind, .late)
        quiet.clock.now = quiet.at(18, 0)
        await quiet.check(early)
        XCTAssertNil(quiet.state)

        let bare = try await SwitchRig(self, withRecord: false)
        await bare.check()
        XCTAssertNil(bare.state)

        let offline = try await SwitchRig(self)
        offline.box.config = SwitchRig.unconfigured
        await offline.check()
        XCTAssertNil(offline.state)

        let gone = try await SwitchRig(self)
        if let entry = gone.entry { gone.store.deleteActivity(entry) }
        await gone.check()
        XCTAssertNil(gone.state)

        let unlinked = try await SwitchRig(self)
        var loose = unlinked.event
        loose.linkedActivityId = nil
        await unlinked.center.check(event: loose, outcome: unlinked.outcome, store: unlinked.store)
        XCTAssertNil(unlinked.state)

        for rig in [quiet, bare, offline, gone, unlinked] {
            XCTAssertTrue(rig.calls.list.isEmpty, "nothing was asked for")
        }
    }

    func testT16_TheWholeSceneRunsTheSameStepsInASeoulAndALosAngelesClockWithOnlyTheAllowedKeysInTheBodies() async throws {
        for zone in [seoul, losAngeles] {
            let rig = try await SwitchRig(self, zone: zone, sync: true)
            await rig.check()
            let offer = try rig.offer()
            await rig.tap()
            let name = zone.identifier
            XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options", "delivery-order", "cancel", "budget-spend"], name)
            XCTAssertEqual(rig.resultLines(), [
                "Booking cancelled",
                "Delivery DL-AB12CD arrives 7:12 PM",
                "Schedule entry moved to 7:12 PM",
                "Estimated total $33.00 sent to Example Budget (Simulated): $167.00 left this week."], name)
            let flow = await rig.packets(in: offer.flow)
            XCTAssertEqual(summaries(flow), SwitchRig.fullFlow + ["Event move sent"], name)

            let left = try XCTUnwrap(rig.body(rig.budget.requests, op: "left"))
            XCTAssertEqual(Set(left.keys), ["op", "week_start", "spent_cents"], name)
            XCTAssertEqual(left["week_start"] as? String, "2026-11-02", name)
            let options = try XCTUnwrap(rig.body(rig.delivery.requests, op: "options"))
            XCTAssertEqual(Set(options.keys), ["op"], name)
            let order = try XCTUnwrap(rig.orderBody)
            XCTAssertEqual(Set(order.keys), ["op", "request_id", "restaurant", "arrive_at", "items", "address", "card_id"], name)
            XCTAssertEqual(order["arrive_at"] as? String, "2026-11-02T19:12", name)
            let cancel = try XCTUnwrap(rig.tables.requests.first)
            XCTAssertEqual(cancel.url?.path, "/booking/cancel", name)
            let cancelBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(cancel.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(cancelBody.keys), ["op", "request_id"], name)
            XCTAssertEqual(cancelBody["request_id"] as? String, SwitchRig.requestID, name)
            let spend = try XCTUnwrap(rig.spendBody)
            XCTAssertEqual(Set(spend.keys), ["op", "week_start", "spent_cents", "amount_cents", "request_id"], name)
            XCTAssertEqual(spend["week_start"] as? String, "2026-11-02", name)
            XCTAssertEqual(rig.entry?.startDate, rig.at(19, 12), name)
            // No packet of the scene holds an amount, a place, a time, a code, an id or an address.
            let text = flow.map(\.summary).joined(separator: "\n")
            for word in ["$", "Bistro", "Home Road", "Example Road", "DL-", SwitchRig.requestID, "19:", "7:12"] {
                XCTAssertFalse(text.contains(word), "\(name): a packet holds \(word)")
            }
        }
    }

    func testT17_ShowsFollowsTheStateAndTheLateLinesAndOnlyATransitLegDrawsItsOwnMark() async throws {
        let rig = try await SwitchRig(self)
        await rig.check()
        let offer = try rig.offer()
        typealias Center = LateSwitchCenter
        XCTAssertTrue(Center.shows(state: .offer(offer), lateLines: true))
        XCTAssertFalse(Center.shows(state: .offer(offer), lateLines: false), "an offer needs the late lines")
        for lateLines in [true, false] {
            XCTAssertTrue(Center.shows(state: .running, lateLines: lateLines))
            XCTAssertTrue(Center.shows(state: .note("Nothing was changed."), lateLines: lateLines))
            XCTAssertTrue(Center.shows(state: .finished(Center.Result(lines: ["Booking cancelled"])), lateLines: lateLines))
            XCTAssertFalse(Center.shows(state: .checking, lateLines: lateLines), "nothing shows while a read is in flight")
            XCTAssertFalse(Center.shows(state: nil, lateLines: lateLines))
        }
        XCTAssertTrue(LateSwitch.ownMark(mode: .transit))
        for mode in [TransportMode.car, .walk, .bicycle] { XCTAssertFalse(LateSwitch.ownMark(mode: mode), "\(mode)") }
    }

    // MARK: T18-T21 one switch per booking, a failed move, a changed ledger, the over-budget offer

    func testT18_OneSwitchPerBookingNoOfferWhileRunningAfterAResultOrWithTheMarkSetAndTheMarkSurvivesARestart() async throws {
        // While the steps run, and after they finished, a later result reads and offers nothing.
        let rig = try await SwitchRig(self)
        await rig.check()
        rig.center.confirm(activityID: rig.activityID)
        await rig.check(rig.laterOutcome())
        XCTAssertEqual(rig.calls.count("budget-left"), 1, "no read while running")
        XCTAssertEqual(rig.state?.isRunning, true)
        await rig.settle()
        let result = rig.state?.resultValue
        XCTAssertNotNil(result)
        await rig.check(rig.laterOutcome())
        XCTAssertEqual(rig.calls.count("budget-left"), 1, "no read after a finished result")
        XCTAssertEqual(rig.state?.resultValue, result)

        // A partial result (the cancel was declined) keeps the mark: no offer, also after a restart.
        let partial = try await SwitchRig(self)
        partial.tables.result = .success((Data(SwitchRig.declinedBody.utf8), 200))
        await partial.check()
        await partial.tap()
        XCTAssertNotNil(partial.state?.resultValue)
        await partial.check(partial.laterOutcome())
        XCTAssertEqual(partial.calls.count("budget-left"), 1)
        XCTAssertEqual(SwitchRig.mark(at: partial.recordsFile), true, "the mark is on disk")
        let reloaded = PartnerRecords(fileURL: partial.recordsFile)
        XCTAssertEqual(reloaded.record(forActivity: partial.activityID)?.switchStarted, true, "the mark survives a restart")
        let restarted = LateSwitchCenter(dependencies: partial.dependencies(records: reloaded))
        await restarted.check(event: partial.event, outcome: partial.laterOutcome(), store: partial.store)
        XCTAssertNil(restarted.states[partial.activityID])
        XCTAssertEqual(partial.calls.count("budget-left"), 1, "the restarted center reads nothing")

        // An ending that may have ordered something keeps the mark; one that provably did not clears it.
        let unknown = try await SwitchRig(self)
        await unknown.check()
        unknown.delivery.mode = .error(URLError(.notConnectedToInternet))
        await unknown.tap()
        XCTAssertEqual(unknown.records.record(forActivity: unknown.activityID)?.switchStarted, true)
        unknown.restore()
        await unknown.check(unknown.laterOutcome())
        XCTAssertEqual(unknown.calls.count("budget-left"), 1)
        let cleared = try await SwitchRig(self)
        await cleared.check()
        cleared.delivery.mode = .status(401, SwitchRig.unauthorized)
        await cleared.tap()
        XCTAssertEqual(PartnerRecords(fileURL: cleared.recordsFile).record(forActivity: cleared.activityID)?.switchStarted, false)
        cleared.restore()
        await cleared.check(cleared.laterOutcome())
        XCTAssertNotNil(cleared.state?.offerValue, "offered again")
    }

    func testT19_AMoveThatFailsSaysSoKeepsTheRecordMakesNoSecondOfferAndWritesTheOrderRecordWithoutAMealID() async throws {
        let line = "The schedule entry could not be moved."
        // The entry vanishes while the order is in flight.
        let vanishing = try await SwitchRig(self, sync: true)
        await vanishing.check()
        vanishing.delivery.whileSending = { [vanishing] in
            if let entry = vanishing.entry { vanishing.store.deleteActivity(entry) }
        }
        await vanishing.tap()
        XCTAssertEqual(vanishing.resultLines(), [
            "Booking cancelled",
            "Delivery DL-AB12CD arrives 7:12 PM",
            line,
            "Estimated total $33.00 sent to Example Budget (Simulated): $167.00 left this week."])
        XCTAssertNotNil(vanishing.records.record(forActivity: vanishing.activityID), "the record is kept")
        XCTAssertNil(vanishing.orders.orders.first?.mealActivityID)
        XCTAssertEqual(vanishing.orders.orders.count, 1)
        let hops = await vanishing.packets()
        XCTAssertTrue(hops.allSatisfy { $0.to != .appleCalendar }, "no calendar hop for a move that did not happen")

        // The Store reports no change: the entry already holds the title and the start the card would give it.
        let unchanged = try await SwitchRig(self, sync: true)
        await unchanged.check()
        XCTAssertTrue(unchanged.store.modifyActivity(id: unchanged.activityID, newTitle: "Dinner (Simulated)", newStart: unchanged.at(19, 12),
                                                     newEnd: unchanged.at(20, 12)))
        await unchanged.tap()
        XCTAssertEqual(unchanged.resultLines()?[2], line)
        XCTAssertEqual(unchanged.resultLines()?.count, 4)
        XCTAssertNotNil(unchanged.records.record(forActivity: unchanged.activityID))
        XCTAssertNil(unchanged.orders.orders.first?.mealActivityID)
        // No second offer for a later result.
        await unchanged.check(unchanged.laterOutcome())
        XCTAssertEqual(unchanged.calls.count("budget-left"), 1)
        XCTAssertNotNil(unchanged.state?.resultValue)
    }

    func testT20_ASpendRecordedBetweenTheOfferAndTheTapSendsNothingShowsNoLineAndReadsOnceMoreUnderANewFlow() async throws {
        let rig = try await SwitchRig(self)
        await rig.check()
        let first = try rig.offer()
        XCTAssertEqual(first.seed.spentCentsAtOffer, 6000)
        rig.ledger.add(BudgetEntry(requestID: "late-1", weekStart: SwitchRig.week, amountCents: 1000, isEstimate: false))
        rig.center.confirm(activityID: rig.activityID)
        XCTAssertEqual(rig.state?.isChecking, true, "the offer is dropped and one new read follows")
        await rig.settle()

        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options", "budget-left", "delivery-options"], "nothing was ordered")
        XCTAssertTrue(first.card.isFrozen)
        let second = try rig.offer()
        XCTAssertNotEqual(second.flow, first.flow)
        XCTAssertEqual(second.seed.spentCentsAtOffer, 7000)
        XCTAssertNil(rig.state?.noteText, "no line")
        XCTAssertEqual(rig.records.record(forActivity: rig.activityID)?.switchStarted, false)
        XCTAssertEqual(rig.tables.requests.count, 0)
        let firstFlow = await rig.packets(in: first.flow)
        let secondFlow = await rig.packets(in: second.flow)
        let pairs = ["Budget left asked", "Budget left answered", "Options requested", "Options received"]
        XCTAssertEqual(summaries(firstFlow), pairs)
        XCTAssertEqual(summaries(secondFlow), pairs)
        XCTAssertEqual(second.evaluation.standingLine, "$157.00 left this week after the switch")
        // The new offer can be tapped.
        await rig.tap()
        XCTAssertNotNil(rig.state?.resultValue)
        XCTAssertEqual(rig.calls.count("delivery-order"), 1)
    }

    func testT21_TheOverBudgetOfferRunsEveryStepAndTheResultEndsWithTheOverFormOfTheBudgetNotice() async throws {
        let rig = try await SwitchRig(self, extraSpent: 18000)
        await rig.check()
        let offer = try rig.offer()
        XCTAssertEqual(offer.evaluation.estimateLine, "Booking est. $60.00 - Delivery est. $33.00")
        XCTAssertEqual(offer.evaluation.standingLine, "$13.00 over the budget this week after the switch")
        await rig.tap()
        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options", "delivery-order", "cancel", "budget-spend"])
        XCTAssertEqual(rig.resultLines()?.last, "Estimated total $33.00 sent to Example Budget (Simulated): $13.00 over the budget this week.")
        XCTAssertEqual(rig.resultLines()?.first, "Booking cancelled")
        XCTAssertEqual(rig.entry?.startDate, rig.at(19, 12))
        XCTAssertEqual(rig.orders.orders.count, 1)
    }

    // MARK: T22-T26 the card and what the steps are made from

    func testT22_TheDeliveryPlaceRowIsSeededOrBlankTheOrderCarriesTheTapsSnapshotAndTheTextOnlyLeavesInTheOrderAndItsRecord() async throws {
        // Seeded from the leg's origin; the button is enabled.
        let seeded = try await SwitchRig(self)
        await seeded.check()
        let offer = try seeded.offer()
        XCTAssertEqual(offer.card.values.text(offer.seed.addressKey), "1 Home Road")
        XCTAssertEqual(offer.card.source(of: offer.seed.addressKey), .inferred)
        XCTAssertTrue(seeded.center.canConfirm(activityID: seeded.activityID))
        seeded.center.confirm(activityID: seeded.activityID)
        // Frozen: an edit after the tap changes nothing.
        XCTAssertFalse(offer.card.setText(LateSwitch.quantityKey, "5"))
        XCTAssertFalse(offer.card.chooseOption(LateSwitch.itemKey, "gyoza"))
        XCTAssertEqual(offer.card.values.int(LateSwitch.quantityKey), 2)
        await seeded.settle()
        let order = try XCTUnwrap(seeded.orderBody)
        XCTAssertEqual(order["address"] as? String, "1 Home Road")
        XCTAssertEqual((order["items"] as? [[String: Any]])?.first?["quantity"] as? Int, 2)
        // With no search typed, the delivery text is in no packet, notice, result line or partner record.
        let packets = await seeded.packets()
        XCTAssertFalse(packets.map(\.summary).joined().contains("Home Road"))
        XCTAssertFalse((seeded.resultLines() ?? []).joined().contains("Home Road"))
        XCTAssertFalse(try String(contentsOf: seeded.ledgerFile, encoding: .utf8).contains("Home Road"))
        XCTAssertFalse(try String(contentsOf: seeded.recordsFile, encoding: .utf8).contains("Home Road"))
        XCTAssertEqual(seeded.orders.orders.first?.address, "1 Home Road", "the control: the order record keeps it")

        // Blank: the leg's origin is a device fix without an address and the schedule has no other entry.
        let blank = try await SwitchRig(self, origin: SwitchRig.deviceFix)
        await blank.check()
        let empty = try blank.offer()
        XCTAssertNil(empty.card.values.text(empty.seed.addressKey))
        XCTAssertEqual(empty.card.source(of: empty.seed.addressKey), .blank)
        XCTAssertFalse(blank.center.canConfirm(activityID: blank.activityID))
        blank.center.confirm(activityID: blank.activityID)
        XCTAssertNotNil(blank.state?.offerValue, "a blank required row sends nothing and leaves the offer")
        XCTAssertFalse(empty.card.isFrozen)
        XCTAssertEqual(blank.calls.list, ["budget-left", "delivery-options"])
        let cafe = Place(name: "Cafe One", address: "Cafe One address", latitude: 37.45, longitude: 127.05)
        XCTAssertTrue(empty.card.choosePlace(empty.seed.addressKey, cafe))
        XCTAssertTrue(blank.center.canConfirm(activityID: blank.activityID))
        await blank.tap()
        XCTAssertEqual(blank.orderBody?["address"] as? String, "Cafe One address")

        // A search typed in the row: the base search packet is the only one holding the text, centred on the leg's origin.
        let typed = try await SwitchRig(self)
        await typed.check()
        let searching = try typed.offer()
        searching.card.search(searching.seed.addressKey, "Cafe")
        try await Self.until { typed.places.callCount == 1 }
        let body = PlaceBody.json(typed.places.requests.last)
        let centre = try XCTUnwrap(PlaceBody.biasCenter(body))
        XCTAssertEqual(centre.latitude, 37.4, accuracy: 0.0001)
        XCTAssertEqual(centre.longitude, 127.1, accuracy: 0.0001)
        try await Self.until {
            await typed.log.flush()
            return typed.log.packets.contains { $0.to == .googlePlaces }
        }
        XCTAssertTrue(searching.card.choosePlace(searching.seed.addressKey, cafe))
        await typed.tap()
        let all = await typed.packets()
        let holding = all.filter { $0.summary.contains("Cafe") }
        XCTAssertEqual(holding.count, 1)
        XCTAssertEqual(holding.first?.to, .googlePlaces)
        XCTAssertEqual(holding.first?.kind, .placeSearch)
        XCTAssertEqual(holding.first?.summary.hasPrefix("Searched \u{201C}Cafe\u{201D} \u{00B7} "), true)
        XCTAssertNil(holding.first?.flowID)
        XCTAssertFalse((typed.resultLines() ?? []).joined().contains("Cafe"))
        XCTAssertEqual(typed.orderBody?["address"] as? String, "Cafe One address")

        // No origin on the leg: no bias, and the centre holds no device-position dependency.
        let bare = try await SwitchRig(self, origin: nil)
        await bare.check()
        let noBias = try bare.offer()
        noBias.card.search(noBias.seed.addressKey, "Cafe")
        try await Self.until { bare.places.callCount == 1 }
        XCTAssertNotNil(PlaceBody.json(bare.places.requests.last))
        XCTAssertNil(PlaceBody.biasCenter(PlaceBody.json(bare.places.requests.last)))
        let source = try sourceText("Shared/LateSwitch.swift")
        XCTAssertTrue(source.contains("placeSearch"), "the control: the scan reads the centre's source")
        for word in ["deviceOrigin", "CLLocationManager", "CLLocation("] {
            XCTAssertFalse(source.contains(word), "the centre holds \(word)")
        }
    }

    func testT23_ThereIsOneOrderRecordWithTheAnsweredOrderTheLineTheTextTheCardAndTheTotalAndAMealIDOnlyAfterAMove() async throws {
        let rig = try await SwitchRig(self)
        await rig.check()
        await rig.tap()
        let record = try XCTUnwrap(rig.orders.orders.first)
        XCTAssertEqual(rig.orders.orders.count, 1)
        XCTAssertEqual(record.orderID, "DL-AB12CD")
        XCTAssertEqual(record.requestID, rig.orderBody?["request_id"] as? String)
        XCTAssertEqual(record.placeName, "Test Bistro")
        XCTAssertEqual(record.arrival, "2026-11-02T19:12")
        XCTAssertEqual(record.items, [DeliveryOrderItem(itemID: "ramen", name: "Ramen", quantity: 2, unitPriceCents: 1400)])
        XCTAssertEqual(record.address, "1 Home Road")
        XCTAssertEqual(record.cardLabel, "Example Debit \u{2022}\u{2022}4242 (Simulated)")
        XCTAssertEqual(record.estimatedTotalCents, 3300)
        XCTAssertEqual(record.createdAt, rig.clock.now)
        XCTAssertEqual(record.mealActivityID, rig.activityID.uuidString, "the entry moved")
        XCTAssertNotNil(rig.state?.resultValue)

        // No record for a delivery that was not confirmed.
        for mode in [DeliveryToolPartner.Mode.error(URLError(.notConnectedToInternet)), .status(500, "oops")] {
            let failed = try await SwitchRig(self)
            await failed.check()
            failed.delivery.mode = mode
            await failed.tap()
            XCTAssertTrue(failed.orders.orders.isEmpty)
        }
    }

    func testT24_TheBudgetIsReadFirstTheOptionsFollowUnderTheSameFlowAndTheOrderBodyHoldsOnlyItsKeysAndTheEntrysPlaceName() async throws {
        let long = Place(name: "Le " + String(repeating: "N", count: 100), address: "7 Long Road", latitude: 37.5, longitude: 127.0)
        let rig = try await SwitchRig(self, place: long)
        await rig.check()
        let offer = try rig.offer()
        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options"])
        let reads = await rig.packets(in: offer.flow)
        XCTAssertEqual(summaries(reads), ["Budget left asked", "Budget left answered", "Options requested", "Options received"])
        await rig.tap()
        let order = try XCTUnwrap(rig.orderBody)
        XCTAssertEqual(Set(order.keys), ["op", "request_id", "restaurant", "arrive_at", "items", "address", "card_id"])
        XCTAssertEqual(order["restaurant"] as? String, AgentBooking.sentName(long))
        XCTAssertEqual((order["restaurant"] as? String)?.unicodeScalars.count, 80)
        XCTAssertNotEqual(order["restaurant"] as? String, long.name)
        XCTAssertNotEqual(order["restaurant"] as? String, "Example Tables")
        XCTAssertEqual(order["op"] as? String, "order")
        XCTAssertEqual(order["card_id"] as? String, "debit-4242")
        let items = try XCTUnwrap(order["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(Set(items[0].keys), ["item_id", "quantity"])
        XCTAssertEqual(items[0]["item_id"] as? String, "ramen")
        XCTAssertEqual(items[0]["quantity"] as? Int, 2)
        XCTAssertEqual(rig.orders.orders.first?.placeName, AgentBooking.sentName(long))

        // A failed budget read asks for no options and shows nothing.
        let down = try await SwitchRig(self)
        down.budget.mode = .error(URLError(.notConnectedToInternet))
        await down.check()
        XCTAssertTrue(down.delivery.requests.isEmpty)
        XCTAssertNil(down.state)
    }

    func testT25_TheOrderFollowsTheCardItsItemQuantityCardAndMealTitleReachTheOrderTheSpendTheRecordAndTheMovedEntry() async throws {
        let rig = try await SwitchRig(self)
        await rig.check()
        let offer = try rig.offer()
        XCTAssertTrue(offer.card.chooseOption(LateSwitch.itemKey, "gyoza"))
        XCTAssertTrue(offer.card.setText(LateSwitch.quantityKey, "1"))
        XCTAssertTrue(offer.card.chooseOption(offer.seed.cardKey, "credit-1881"))
        XCTAssertTrue(offer.card.setText(LateSwitch.titleKey, "Late bite"))
        XCTAssertEqual(offer.evaluation.estimateLine, "Booking est. $60.00 - Delivery est. $12.00")
        XCTAssertEqual(offer.evaluation.standingLine, "$188.00 left this week after the switch")
        await rig.tap()

        let order = try XCTUnwrap(rig.orderBody)
        let items = try XCTUnwrap(order["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["item_id"] as? String, "gyoza")
        XCTAssertEqual(items[0]["quantity"] as? Int, 1)
        XCTAssertEqual(order["card_id"] as? String, "credit-1881")
        XCTAssertEqual(rig.spendBody?["amount_cents"] as? Int, 1200)
        let record = try XCTUnwrap(rig.orders.orders.first)
        XCTAssertEqual(record.items, [DeliveryOrderItem(itemID: "gyoza", name: "Gyoza", quantity: 1, unitPriceCents: 700)])
        XCTAssertEqual(record.cardLabel, "Example Credit \u{2022}\u{2022}1881 (Simulated)")
        XCTAssertEqual(record.estimatedTotalCents, 1200)
        XCTAssertEqual(rig.entry?.title, "Late bite (Simulated)")
        XCTAssertEqual(rig.resultLines()?.last, "Estimated total $12.00 sent to Example Budget (Simulated): $188.00 left this week.")
    }

    func testT26_TheOfferIsAnAgentFieldCardWithTheHeaderTheRowsOfTheSpecInOrderNoStatedValueAndThePartnerLine() async throws {
        let rig = try await SwitchRig(self)
        await rig.check()
        let offer = try rig.offer()
        let card: AgentFieldCard = offer.card
        XCTAssertEqual(card.header, "Order delivery instead")
        XCTAssertEqual(card.card.fields.map(\.key), ["0", "switch-item", "switch-quantity", "arrive_at", "address", "card_id", "switch-title", "1"])
        XCTAssertEqual(card.card.fields.dropFirst().dropLast().map(\.label),
                       ["Item", "Quantity", "Arrival", "Delivery place", "Pay with", "Meal title"])
        XCTAssertEqual(card.lines.first, "Order delivery instead")
        XCTAssertEqual(card.lines[1], "Test Bistro")
        XCTAssertEqual(card.lines.last, "Example Tables, Example Delivery and Example Budget - Simulated")
        XCTAssertEqual(card.lines.last, LateSwitch.partnerLine(partnerName: "Example Tables"))
        XCTAssertEqual(card.lines[2], "Item: Ramen")
        XCTAssertEqual(card.lines[3], "Quantity: 2")
        XCTAssertEqual(card.lines[7], "Meal title: Dinner")
        let entries = card.values.entries
        XCTAssertEqual(entries.count, 6)
        XCTAssertTrue(entries.allSatisfy { $0.source == .inferred }, "every value is inferred")
        XCTAssertFalse(entries.contains { $0.source == .stated })
        XCTAssertTrue(card.isReady)
    }

    // MARK: T27-T31 the booking's legs after the switch (SPEC-SWITCHLEG-001)

    /// Adds the return leg the removal tests need (the rig itself makes only the outbound one) and asserts the call took.
    private func addReturnLeg(to rig: SwitchRig) async {
        let added = await rig.store.addLeg(activityId: rig.activityID, role: .departure, outerPlace: SwitchRig.home, mode: .car,
                                           bufferMinutes: 0, notifyLeadMinutes: 0, notifyEnabled: false, travelSecondsHint: 1470)
        guard case .created = added else { return XCTFail("the control: the return leg was not added") }
    }

    /// A second entry of the next day with one leg of its own: that leg must survive the booked entry's removal.
    private func secondEntryLegId(in rig: SwitchRig) async throws -> UUID {
        let made = await rig.store.addActivityWithTravel(title: "Lunch at Test Bistro (Simulated)", location: SwitchRig.bistro,
                                                         startDate: rig.at(12, 0, day: 3), endDate: rig.at(13, 0, day: 3),
                                                         travelFrom: SwitchRig.home, returnTo: nil, outboundMode: .car, returnMode: .car,
                                                         bufferMinutes: 0, notifyLeadMinutes: 0, notifyEnabled: false,
                                                         syncToCalendar: false, travelSecondsHint: 1470)
        return try XCTUnwrap(rig.store.events.first { $0.linkedActivityId == made.activityId }?.id)
    }

    /// The rig's two legs, unwrapped.
    private func bothLegs(_ rig: SwitchRig) throws -> (outbound: ScheduledEvent, returned: ScheduledEvent) {
        let pair = rig.store.legs(of: rig.activityID)
        return (try XCTUnwrap(pair.outbound), try XCTUnwrap(pair.return))
    }

    /// Both legs are still stored with the same id, title, arrival and departure they had before the tap.
    private func assertLegsStored(_ rig: SwitchRig, outbound: ScheduledEvent, returned: ScheduledEvent,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let after = rig.store.legs(of: rig.activityID)
        for (name, was, now) in [("outbound", outbound, after.outbound), ("return", returned, after.return)] {
            XCTAssertEqual(now?.id, was.id, name, file: file, line: line)
            XCTAssertEqual(now?.title, was.title, name, file: file, line: line)
            XCTAssertEqual(now?.arrivalDate, was.arrivalDate, name, file: file, line: line)
            XCTAssertEqual(now?.departureDate, was.departureDate, name, file: file, line: line)
        }
    }

    func testT27_ACancelledBookingLosesBothLegsWhileTheSecondEntrysLegStaysAndTheEntryIsMoved() async throws {
        let rig = try await SwitchRig(self)
        await addReturnLeg(to: rig)
        let secondLegId = try await secondEntryLegId(in: rig)
        let before = try XCTUnwrap(rig.entry)
        XCTAssertEqual(rig.store.events.count, 3, "the control: three events")
        XCTAssertEqual(rig.store.events.filter { $0.linkedActivityId == rig.activityID }.count, 2,
                       "the control: two of them linked to the booked entry")
        await rig.check()
        let offer = try rig.offer()
        await rig.tap()

        let pair = rig.store.legs(of: rig.activityID)
        XCTAssertNil(pair.outbound, "no outbound leg")
        XCTAssertNil(pair.return, "no return leg")
        XCTAssertFalse(rig.store.events.contains { $0.linkedActivityId == rig.activityID }, "no event links to the entry")
        XCTAssertTrue(rig.store.events.contains { $0.id == secondLegId }, "the second entry's leg is still stored")
        let after = try XCTUnwrap(rig.entry)
        XCTAssertEqual(after.title, "Dinner (Simulated)")
        XCTAssertEqual(after.startDate, rig.at(19, 12))
        XCTAssertEqual(after.endDate.timeIntervalSince(after.startDate), before.endDate.timeIntervalSince(before.startDate))
        XCTAssertEqual(after.location, before.location)
        XCTAssertNil(rig.records.record(forActivity: rig.activityID), "the record is removed after a move")
        XCTAssertEqual(rig.calls.list, ["budget-left", "delivery-options", "delivery-order", "cancel", "budget-spend"])
        let flow = await rig.packets(in: offer.flow)
        XCTAssertEqual(summaries(flow), SwitchRig.fullFlow)
        XCTAssertEqual(rig.resultLines(), [
            "Booking cancelled",
            "Delivery DL-AB12CD arrives 7:12 PM",
            "Schedule entry moved to 7:12 PM",
            "Estimated total $33.00 sent to Example Budget (Simulated): $167.00 left this week."])
    }

    func testT28_BothLegsAreStoredWhenTheOrderIsSentAndNoneWhenTheSpendIs() async throws {
        let rig = try await SwitchRig(self)
        await addReturnLeg(to: rig)
        _ = try await secondEntryLegId(in: rig)
        let eventsFile = AppConfig.supportDirectory.appendingPathComponent("events.json")
        let booked = rig.activityID
        let atOrder = SwitchBox<Int?>(nil)
        let atSpend = SwitchBox<Int?>(nil)
        rig.calls.on("delivery-order") { atOrder.value = SwitchRig.linkedLegCount(activityId: booked, at: eventsFile) }
        rig.calls.on("budget-spend") { atSpend.value = SwitchRig.linkedLegCount(activityId: booked, at: eventsFile) }
        await rig.check()
        await rig.tap()
        XCTAssertEqual(atOrder.value, 2, "both legs are stored while the delivery order is in flight")
        XCTAssertEqual(atSpend.value, 0, "no leg is stored any more when the spend is sent")
    }

    func testT29_BothLegsStayStoredWhenTheCancelAnswerIsDeclinedOrAFailedFortyFourFour() async throws {
        let declined = try await SwitchRig(self)
        await addReturnLeg(to: declined)
        let beforeDeclined = try bothLegs(declined)
        declined.tables.result = .success((Data(SwitchRig.declinedBody.utf8), 200))
        await declined.check()
        await declined.tap()
        assertLegsStored(declined, outbound: beforeDeclined.outbound, returned: beforeDeclined.returned)
        XCTAssertEqual(declined.resultLines(), [
            "Delivery DL-AB12CD arrives 7:12 PM",
            "The booking could not be cancelled.",
            "Estimated total $33.00 sent to Example Budget (Simulated): $107.00 left this week."])

        let notFound = try await SwitchRig(self)
        await addReturnLeg(to: notFound)
        let beforeNotFound = try bothLegs(notFound)
        notFound.tables.result = .success((Data("Not found".utf8), 404))
        await notFound.check()
        await notFound.tap()
        assertLegsStored(notFound, outbound: beforeNotFound.outbound, returned: beforeNotFound.returned)
        XCTAssertEqual(notFound.resultLines()?.count, 3)
        XCTAssertEqual(notFound.resultLines()?[1], "The booking could not be cancelled.")
    }

    func testT30_BothLegsStayStoredWhenTheDeliveryIsDeclinedOrOfflineOrTheArrivalIsNoLongerUsable() async throws {
        // The delivery is declined: the device zone changes once the tap started, so the partner reads an arrival outside
        // its hours and refuses the order.
        let declined = try await SwitchRig(self)
        await addReturnLeg(to: declined)
        let beforeDeclined = try bothLegs(declined)
        let eventsFile = AppConfig.supportDirectory.appendingPathComponent("events.json")
        let booked = declined.activityID
        let atOrder = SwitchBox<Int?>(nil)
        declined.calls.on("delivery-order") { atOrder.value = SwitchRig.linkedLegCount(activityId: booked, at: eventsFile) }
        await declined.check()
        declined.center.confirm(activityID: declined.activityID)
        declined.clock.zone = declined.zone0 == seoul ? losAngeles : seoul
        await declined.settle()
        XCTAssertEqual(atOrder.value, 2, "both legs were stored while the order was in flight")
        XCTAssertEqual(declined.state?.noteText, "The delivery could not be ordered. Nothing was changed.")
        assertLegsStored(declined, outbound: beforeDeclined.outbound, returned: beforeDeclined.returned)

        // The delivery fails offline: the order may have reached the partner, so nothing else is touched.
        let offline = try await SwitchRig(self)
        await addReturnLeg(to: offline)
        let beforeOffline = try bothLegs(offline)
        await offline.check()
        offline.delivery.mode = .error(URLError(.notConnectedToInternet))
        await offline.tap()
        XCTAssertEqual(offline.state?.noteText, "The delivery could not be confirmed. Nothing else was changed.")
        assertLegsStored(offline, outbound: beforeOffline.outbound, returned: beforeOffline.returned)

        // The arrival is edited past the rule before the tap.
        let edited = try await SwitchRig(self)
        await addReturnLeg(to: edited)
        let beforeEdited = try bothLegs(edited)
        await edited.check()
        let offer = try edited.offer()
        XCTAssertTrue(offer.card.chooseTime(offer.seed.arriveKey, edited.at(21, 30)))
        await edited.tap()
        XCTAssertEqual(edited.state?.noteText, "That arrival time cannot be used. Nothing was changed.")
        assertLegsStored(edited, outbound: beforeEdited.outbound, returned: beforeEdited.returned)
    }

    func testT31_TheLegsAreRemovedEvenWhenTheMoveFailsAndTheRecordStaysWithoutAMealID() async throws {
        let rig = try await SwitchRig(self, sync: true)
        await addReturnLeg(to: rig)
        await rig.check()
        // The entry already holds the title and times the card would give it, so the tap's own move reports no change.
        XCTAssertTrue(rig.store.modifyActivity(id: rig.activityID, newTitle: "Dinner (Simulated)", newStart: rig.at(19, 12),
                                               newEnd: rig.at(20, 12)))
        await rig.tap()
        let pair = rig.store.legs(of: rig.activityID)
        XCTAssertNil(pair.outbound)
        XCTAssertNil(pair.return)
        XCTAssertFalse(rig.store.events.contains { $0.linkedActivityId == rig.activityID }, "no leg is left")
        XCTAssertNotNil(rig.records.record(forActivity: rig.activityID), "the record is kept")
        XCTAssertNil(rig.orders.orders.first?.mealActivityID, "no meal id without a move")
        XCTAssertEqual(rig.resultLines(), [
            "Booking cancelled",
            "Delivery DL-AB12CD arrives 7:12 PM",
            "The schedule entry could not be moved.",
            "Estimated total $33.00 sent to Example Budget (Simulated): $167.00 left this week."])
    }

    func testT34_TheSheetShowsTheStoredLegFirstElseARetainedLegOnlyWhileTheSelectionPointsAtIt() async throws {
        let rig = try await SwitchRig(self)
        await addReturnLeg(to: rig)
        let pair = rig.store.legs(of: rig.activityID)
        let outbound = try XCTUnwrap(pair.outbound)
        let returned = try XCTUnwrap(pair.return)
        XCTAssertEqual(LateSwitch.openedLeg(stored: outbound, retained: returned, selection: returned.id)?.id, outbound.id,
                       "a stored leg wins over a different retained one")
        XCTAssertEqual(LateSwitch.openedLeg(stored: nil, retained: returned, selection: returned.id)?.id, returned.id,
                       "the retained leg while the selection is its own id")
        XCTAssertNil(LateSwitch.openedLeg(stored: nil, retained: returned, selection: outbound.id), "a retained leg of another id")
        XCTAssertNil(LateSwitch.openedLeg(stored: nil, retained: returned, selection: nil), "no leg without a selection")
    }
}
