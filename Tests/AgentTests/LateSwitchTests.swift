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
}
