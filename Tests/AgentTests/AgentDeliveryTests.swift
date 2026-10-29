import XCTest
@testable import besir

/// SPEC-DELIVERY-001 AC-DELIVERY-006 to AC-DELIVERY-013: the pure helpers of the delivery tools, so what decides and what is
/// said is testable without the toolbox. Money is whole cents; dollars appear only in text.
@MainActor
final class AgentDeliveryTests: XCTestCase {
    // MARK: Helpers

    private let hour: TimeInterval = 3600
    /// An arbitrary Monday-evening instant; only the differences between instants matter here.
    private let anchor = Date(timeIntervalSince1970: 1_793_000_400)

    private func place(_ name: String, address: String = "", latitude: Double = 0, longitude: Double = 0) -> Place {
        Place(name: name, address: address, latitude: latitude, longitude: longitude)
    }

    private func activity(_ title: String, at location: Place?, from start: Date, to end: Date) -> ActivityBlock {
        ActivityBlock(title: title, location: location, startDate: start, endDate: end)
    }

    /// Whole-word, case-insensitive scan for the words of REQ-DELIVERY-015.
    private func forbiddenWords(in text: String) -> [String] {
        let words = ["should", "recommend", "advise", "afford", "save", "invest", "cut back", "stop spending", "overspend",
                     "calorie", "nutrition", "healthy"]
        return words.filter {
            text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func hasHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) }
    }

    private func standing(left: Int, within: Bool = true, estimate: Bool = true) -> BudgetStanding {
        BudgetStanding(weekStart: "2026-10-26", budgetCents: 20000, spentCents: 20000 - left, leftCents: left,
                       isWithin: within, includesEstimate: estimate)
    }

    // MARK: H01-H05

    func testH01_ParseItemsTakesOnlyStrictPairsOfAnIdAndOneDigit() {
        XCTAssertEqual(AgentDelivery.parseItems("ramen:2,gyoza:1"),
                       [DeliveryLine(itemID: "ramen", quantity: 2), DeliveryLine(itemID: "gyoza", quantity: 1)])
        XCTAssertEqual(AgentDelivery.parseItems("pizza:9"), [DeliveryLine(itemID: "pizza", quantity: 9)])
        XCTAssertEqual(AgentDelivery.parseItems("a_b-9:1")?.first?.itemID, "a_b-9")
        XCTAssertEqual(AgentDelivery.parseItems("a:1,b:2,c:3,d:4,e:5,f:6")?.count, 6)
        let refused = ["", " ", "ramen:2, gyoza:1", "ramen:2,", ",ramen:2", "ramen", "ramen:", "ramen:2:1", "ramen:0", "ramen:10",
                       "ramen:01", "ramen:x", "ramen:\u{0662}", "ramen:\u{FF12}", "ramen:-1", "ramen:+1", "ramen: 2", " ramen:2",
                       "ramen:2 ", "ramen:2,ramen:1", "a:1,b:1,c:1,d:1,e:1,f:1,g:1", "Ramen:2", "ramEN:2", ":2", "ra men:2",
                       "ramen:2;gyoza:1", "ramen:2\n", "r\u{00E4}men:2"]
        for text in refused { XCTAssertNil(AgentDelivery.parseItems(text), "\(text.debugDescription) is refused") }
    }

    func testH02_PlaceTextAndTheScheduleSuggestionFollowTheRulesOfL18AndL26() {
        // placeText: the address, else the name, each cleaned and 1 to 120 scalars.
        XCTAssertEqual(AgentDelivery.placeText(place("Test Cafe", address: "1 Main Street")), "1 Main Street")
        XCTAssertEqual(AgentDelivery.placeText(place("Test Cafe", address: "")), "Test Cafe")
        XCTAssertEqual(AgentDelivery.placeText(place("Test Cafe", address: "  \n ")), "Test Cafe")
        XCTAssertEqual(AgentDelivery.placeText(place("Test Cafe", address: String(repeating: "a", count: 120))), String(repeating: "a", count: 120))
        XCTAssertEqual(AgentDelivery.placeText(place("Test Cafe", address: String(repeating: "a", count: 121))), "Test Cafe")
        XCTAssertEqual(AgentDelivery.placeText(place(String(repeating: "n", count: 120), address: String(repeating: "a", count: 121))),
                       String(repeating: "n", count: 120))
        XCTAssertNil(AgentDelivery.placeText(place(String(repeating: "n", count: 121), address: String(repeating: "a", count: 121))))
        XCTAssertNil(AgentDelivery.placeText(place("", address: "")))
        XCTAssertNil(AgentDelivery.placeText(place(" \u{200B} ", address: "\u{0007}")))
        XCTAssertEqual(AgentDelivery.placeText(place("Test Cafe", address: "1 Main\u{0007} Street\u{2028}")), "1 Main Street")
        // Nothing is cut: a text of 121 scalars that cleaning shortens to 120 is accepted.
        XCTAssertEqual(AgentDelivery.placeText(place("x", address: String(repeating: "a", count: 120) + "\u{200B}")), String(repeating: "a", count: 120))

        let arrival = anchor.addingTimeInterval(24 * hour)
        let now = anchor
        let home = place("Home", address: "1 Home Road")
        let work = place("Work", address: "2 Work Road")
        func suggestion(_ entries: [ActivityBlock]) -> String? {
            AgentDelivery.suggestedPlaceText(activities: entries, arrival: arrival, now: now)
        }
        // In progress at the arrival time.
        XCTAssertEqual(suggestion([activity("Dinner", at: home, from: arrival.addingTimeInterval(-hour), to: arrival.addingTimeInterval(hour))]), "1 Home Road")
        // An entry that starts at the anchor counts; one that ends at it does not.
        XCTAssertEqual(suggestion([activity("Starts", at: home, from: arrival, to: arrival.addingTimeInterval(hour))]), "1 Home Road")
        XCTAssertNil(suggestion([activity("Ends", at: home, from: arrival.addingTimeInterval(-hour), to: arrival)]))
        // No place, not started, ended, none.
        XCTAssertNil(suggestion([activity("No place", at: nil, from: arrival.addingTimeInterval(-hour), to: arrival.addingTimeInterval(hour))]))
        XCTAssertNil(suggestion([activity("Later", at: home, from: arrival.addingTimeInterval(1), to: arrival.addingTimeInterval(hour))]))
        XCTAssertNil(suggestion([activity("Earlier", at: home, from: arrival.addingTimeInterval(-2 * hour), to: arrival.addingTimeInterval(-hour))]))
        XCTAssertNil(suggestion([]))
        XCTAssertNil(suggestion([activity("Unusable", at: place("", address: ""), from: arrival.addingTimeInterval(-hour), to: arrival.addingTimeInterval(hour))]))
        // Two entries at one anchor: equal texts give one suggestion, different texts give none.
        let both = [activity("One", at: home, from: arrival.addingTimeInterval(-hour), to: arrival.addingTimeInterval(hour)),
                    activity("Two", at: place("Other name", address: "1 Home Road"), from: arrival, to: arrival.addingTimeInterval(2 * hour))]
        XCTAssertEqual(suggestion(both), "1 Home Road")
        let differ = [activity("One", at: home, from: arrival.addingTimeInterval(-hour), to: arrival.addingTimeInterval(hour)),
                      activity("Two", at: work, from: arrival.addingTimeInterval(-hour), to: arrival.addingTimeInterval(hour))]
        XCTAssertNil(suggestion(differ))
        // The minute of the call is the second anchor: used when the arrival time has no usable entry.
        let nowEntry = activity("Now", at: work, from: now.addingTimeInterval(-hour), to: now.addingTimeInterval(hour))
        XCTAssertEqual(suggestion([nowEntry]), "2 Work Road")
        // An arrival-time hit wins over a different now-time hit.
        let arrivalEntry = activity("Arrival", at: home, from: arrival.addingTimeInterval(-hour), to: arrival.addingTimeInterval(hour))
        XCTAssertEqual(suggestion([nowEntry, arrivalEntry]), "1 Home Road")
        // Two different arrival-time texts give none, and the later anchor is not consulted.
        XCTAssertNil(suggestion([nowEntry, arrivalEntry, activity("Third", at: work, from: arrival, to: arrival.addingTimeInterval(hour))]))
        // An arrival-time entry without a usable text does not block the later anchor.
        let unusable = activity("Unusable", at: place("", address: ""), from: arrival.addingTimeInterval(-hour), to: arrival.addingTimeInterval(hour))
        XCTAssertEqual(suggestion([unusable, nowEntry]), "2 Work Road")
        // An entry of the past or the future of the call does not count at the second anchor.
        XCTAssertNil(AgentDelivery.suggestedPlaceText(activities: [activity("Past", at: work, from: now.addingTimeInterval(-2 * hour), to: now.addingTimeInterval(-hour))],
                                                      arrival: arrival, now: now))
    }

    func testH03_TheMealRuleTheTypingCleanerAndTheOneTrim() {
        let expected: [(Int, String)] = [(0, "Brunch"), (659, "Brunch"), (660, "Lunch"), (899, "Lunch"), (900, "Snack"), (1019, "Snack"),
                                         (1020, "Dinner"), (1180, "Dinner"), (1320, "Dinner"), (1439, "Dinner")]
        for (minute, word) in expected {
            XCTAssertEqual(AgentDelivery.mealWord(arrivalMinute: minute), word, "minute \(minute)")
            XCTAssertEqual(AgentDelivery.mealTitle(arrivalMinute: minute), word + " (Simulated)")
        }
        XCTAssertEqual(AgentDelivery.mealTitle(arrivalMinute: 10 * 60 + 59), "Brunch (Simulated)")
        XCTAssertEqual(AgentDelivery.mealTitle(arrivalMinute: 11 * 60), "Lunch (Simulated)")
        XCTAssertEqual(AgentDelivery.mealTitle(typed: "Family dinner"), "Family dinner (Simulated)")
        XCTAssertTrue(AgentDelivery.mealTitle(typed: "x").hasSuffix(" (Simulated)"))
        XCTAssertEqual(AgentDelivery.mealMinutes, 60)
        XCTAssertEqual(AgentDelivery.maxDeliveryText, 120)
        XCTAssertEqual(AgentDelivery.maxMealTitle, 40)

        // Per keystroke: hidden characters go, the cut is at the limit, and nothing is trimmed.
        XCTAssertEqual(AgentDelivery.cleanedTyped("12", limit: 120), "12")
        XCTAssertEqual(AgentDelivery.cleanedTyped("12 ", limit: 120), "12 ")
        XCTAssertEqual(AgentDelivery.cleanedTyped("12 E", limit: 120), "12 E")
        XCTAssertEqual(AgentDelivery.cleanedTyped("   ", limit: 120), "   ")
        XCTAssertEqual(AgentDelivery.cleanedTyped(" lead", limit: 120), " lead")
        XCTAssertEqual(AgentDelivery.cleanedTyped("a\u{0007}b\u{200B}c\u{2028}d\u{2029}e\nf\tg", limit: 120), "abcdefg")
        XCTAssertEqual(AgentDelivery.cleanedTyped(String(repeating: "a", count: 130), limit: 120).unicodeScalars.count, 120)
        XCTAssertEqual(AgentDelivery.cleanedTyped(String(repeating: "a", count: 130), limit: 40).unicodeScalars.count, 40)
        XCTAssertEqual(AgentDelivery.cleanedTyped(String(repeating: "a", count: 40), limit: 40).unicodeScalars.count, 40)
        // Hidden characters are removed before the cut is counted.
        XCTAssertEqual(AgentDelivery.cleanedTyped(String(repeating: "a\u{200B}", count: 50), limit: 40), String(repeating: "a", count: 40))
        XCTAssertEqual(AgentDelivery.cleanedTyped("", limit: 40), "")

        // The one trim, at Confirm: nil when blank.
        XCTAssertEqual(AgentDelivery.snapshotText("  12 Example Street \n"), "12 Example Street")
        XCTAssertEqual(AgentDelivery.snapshotText("a b"), "a b")
        XCTAssertNil(AgentDelivery.snapshotText(""))
        XCTAssertNil(AgentDelivery.snapshotText("   "))
        XCTAssertNil(AgentDelivery.snapshotText(" \n\t "))
    }

    func testH04_CardLinesAreExactForEveryCombinationOfSuggestionsAndEdits() {
        let items = [(name: "Ramen", quantity: 2), (name: "Gyoza", quantity: 1)]
        let suggestedMeal = AgentDelivery.CardMeal(title: "Dinner (Simulated)", time: "7:40 PM", isSuggested: true)
        func lines(deliveryText: String = "1 Home Road", suggested: Bool, meal: AgentDelivery.CardMeal?) -> [String] {
            AgentDelivery.cardLines(placeName: "Test Cafe", arrives: "Tue, Nov 3 at 7:40 PM", items: items, deliveryText: deliveryText,
                                    deliveryIsSuggested: suggested, cardLabel: "Example Debit \u{2022}\u{2022}4242 (Simulated)",
                                    totalCents: 4000, meal: meal)
        }
        XCTAssertEqual(lines(suggested: true, meal: suggestedMeal), [
            "Order delivery", "Test Cafe", "Arrives Tue, Nov 3 at 7:40 PM", "2 x Ramen", "1 x Gyoza",
            "To 1 Home Road (suggested from your schedule)", "Pay with Example Debit \u{2022}\u{2022}4242 (Simulated)",
            "Estimated total $40.00", "Add to schedule: Dinner (Simulated) at 7:40 PM (suggested)", "Example Delivery - Simulated"])
        // A named place: no mark on the To line.
        XCTAssertEqual(lines(deliveryText: "5 Library Lane", suggested: false, meal: suggestedMeal)[5], "To 5 Library Lane")
        // An edited text and an edited title or time: no marks.
        let edited = AgentDelivery.CardMeal(title: "Family dinner (Simulated)", time: "8:00 PM", isSuggested: false)
        let editedLines = lines(deliveryText: "12 Example Street", suggested: false, meal: edited)
        XCTAssertEqual(editedLines[5], "To 12 Example Street")
        XCTAssertEqual(editedLines[8], "Add to schedule: Family dinner (Simulated) at 8:00 PM")
        // The entry switched off: no schedule line.
        let off = lines(suggested: true, meal: nil)
        XCTAssertEqual(off.count, 9)
        XCTAssertFalse(off.contains { $0.hasPrefix("Add to schedule") })
        XCTAssertEqual(off.last, "Example Delivery - Simulated")
        // The total text.
        XCTAssertEqual(AgentDelivery.cardLines(placeName: "P", arrives: "A", items: [(name: "Cheese pizza", quantity: 9)], deliveryText: "T",
                                               deliveryIsSuggested: false, cardLabel: "C", totalCents: 35600, meal: nil)[6],
                       "Estimated total $356.00")
        XCTAssertEqual(AgentDelivery.cardLines(placeName: "P", arrives: "A", items: [(name: "Lemonade", quantity: 1)], deliveryText: "T",
                                               deliveryIsSuggested: false, cardLabel: "C", totalCents: 905, meal: nil)[6],
                       "Estimated total $9.05")
        XCTAssertEqual(AgentDelivery.estimatedTotalLine(cents: 65300), "Estimated total $653.00")
    }

    func testH05_FixedTextsAndBuildersAreEnglishFactualAndBuiltFromThePartnerConstants() throws {
        XCTAssertEqual(AgentDelivery.controlLabels, ["Delivery place", "Add to schedule", "Meal title", "Start"])
        XCTAssertEqual([AgentDelivery.deliveryPlaceLabel, AgentDelivery.mealSwitchLabel, AgentDelivery.mealTitleLabel, AgentDelivery.mealStartLabel],
                       AgentDelivery.controlLabels)
        XCTAssertEqual(AgentDelivery.partnerLine, "\(DeliveryClient.partnerName) - Simulated")

        let options = DeliveryOptions(
            menu: [DeliveryMenuItem(id: "ramen", name: "Ramen", priceCents: 1400), DeliveryMenuItem(id: "gyoza", name: "Gyoza", priceCents: 700)],
            cards: [DeliveryCard(id: "debit-4242", label: "Example Debit \u{2022}\u{2022}4242 (Simulated)")], deliveryFeeCents: 500)
        let optionsResult = AgentDelivery.optionsResult(options)
        XCTAssertEqual(Set(optionsResult.keys), ["status", "partner", "simulated", "menu", "cards", "estimated_delivery_fee", "message"])
        XCTAssertEqual(optionsResult["status"] as? String, "ok")
        XCTAssertEqual(optionsResult["partner"] as? String, DeliveryClient.partnerName)
        XCTAssertEqual(optionsResult["simulated"] as? Bool, true)
        XCTAssertEqual(optionsResult["estimated_delivery_fee"] as? String, "$5.00")
        let menu = try XCTUnwrap(optionsResult["menu"] as? [[String: Any]])
        XCTAssertEqual(menu.map { Set($0.keys) }, [["item_id", "name", "estimated_price"], ["item_id", "name", "estimated_price"]])
        XCTAssertEqual(menu.first?["estimated_price"] as? String, "$14.00")
        XCTAssertEqual(menu.last?["item_id"] as? String, "gyoza")
        let cards = try XCTUnwrap(optionsResult["cards"] as? [[String: Any]])
        XCTAssertEqual(cards.first?["card_id"] as? String, "debit-4242")
        XCTAssertEqual(cards.first?["label"] as? String, "Example Debit \u{2022}\u{2022}4242 (Simulated)")

        // Applied: the keys of REQ-DELIVERY-013.
        let recorded = AgentDelivery.BudgetHandOff.recorded(standing: standing(left: 16000), week: "this week")
        let meal = AgentDelivery.AppliedMeal.added(id: "ID-1", title: "Dinner (Simulated)", start: "2026-11-03T19:40", end: "2026-11-03T20:40")
        func applied(meal: AgentDelivery.AppliedMeal?, budget: AgentDelivery.BudgetHandOff) -> [String: Any] {
            AgentDelivery.appliedFields(orderID: "DL-AB12CD", restaurant: "Test Cafe", arrival: "2026-11-03T19:40",
                                        items: [(name: "Ramen", quantity: 2), (name: "Gyoza", quantity: 1)], address: "12 Example Street",
                                        cardLabel: "Example Debit \u{2022}\u{2022}4242 (Simulated)", totalCents: 4000, meal: meal, budget: budget)
        }
        let withMeal = applied(meal: meal, budget: recorded)
        XCTAssertEqual(Set(withMeal.keys), ["status", "partner", "simulated", "order_id", "restaurant", "arrival_estimate", "items", "address",
                                            "card", "estimated_total", "estimate", "message", "meal", "budget"])
        XCTAssertEqual(withMeal["status"] as? String, "applied")
        XCTAssertEqual(withMeal["partner"] as? String, DeliveryClient.partnerName)
        XCTAssertEqual(withMeal["simulated"] as? Bool, true)
        XCTAssertEqual(withMeal["estimate"] as? Bool, true)
        XCTAssertEqual(withMeal["estimated_total"] as? String, "$40.00")
        XCTAssertEqual(withMeal["address"] as? String, "12 Example Street")
        XCTAssertEqual(withMeal["card"] as? String, "Example Debit \u{2022}\u{2022}4242 (Simulated)")
        XCTAssertEqual((withMeal["items"] as? [[String: Any]])?.map { Set($0.keys) }, [["name", "quantity"], ["name", "quantity"]])
        let mealBlock = try XCTUnwrap(withMeal["meal"] as? [String: Any])
        XCTAssertEqual(mealBlock as NSDictionary, ["status": "added", "id": "ID-1", "title": "Dinner (Simulated)",
                                                   "start": "2026-11-03T19:40", "end": "2026-11-03T20:40"] as NSDictionary)
        let budgetBlock = try XCTUnwrap(withMeal["budget"] as? [String: Any])
        XCTAssertEqual(budgetBlock as NSDictionary, ["simulated": true, "status": "recorded", "week": "this week",
                                                     "includes_estimate": true, "left": "$160.00"] as NSDictionary)
        let overBlock = AgentDelivery.BudgetHandOff.recorded(standing: standing(left: -2500, within: false), week: "week of Nov 2").block
        XCTAssertEqual(overBlock as NSDictionary, ["simulated": true, "status": "recorded", "week": "week of Nov 2",
                                                   "includes_estimate": true, "over_by": "$25.00"] as NSDictionary)
        XCTAssertEqual(AgentDelivery.BudgetHandOff.unavailable(notify: true).block as NSDictionary,
                       ["simulated": true, "status": "unavailable"] as NSDictionary)
        let message = try XCTUnwrap(withMeal["message"] as? String)
        XCTAssertTrue(message.contains(AgentDelivery.appliedMessage))
        // The walk found the reply without the delivery place: the message names it and the result key that holds it.
        XCTAssertTrue(message.contains("the delivery place"), message)
        XCTAssertTrue(message.contains("address"), message)
        XCTAssertTrue(message.contains(AgentDelivery.mealAddedSentence))
        XCTAssertTrue(message.contains(AgentDelivery.budgetRecordedSentence))
        XCTAssertFalse(message.contains(AgentDelivery.mealMissedSentence))
        let missed = applied(meal: .notAdded, budget: .unavailable(notify: true))
        XCTAssertEqual((missed["meal"] as? [String: Any]) as NSDictionary?, ["status": "not_added"] as NSDictionary)
        let missedMessage = try XCTUnwrap(missed["message"] as? String)
        XCTAssertTrue(missedMessage.contains(AgentDelivery.mealMissedSentence))
        XCTAssertTrue(missedMessage.contains(AgentDelivery.budgetUnavailableSentence))
        XCTAssertFalse(missedMessage.contains(AgentDelivery.mealAddedSentence))
        // The entry off at Confirm: no meal key and no meal sentence.
        let none = applied(meal: nil, budget: recorded)
        XCTAssertNil(none["meal"])
        XCTAssertFalse(try XCTUnwrap(none["message"] as? String).contains(AgentDelivery.mealAddedSentence))

        // The notice: within, over and in the next week, built from the Budget partner label.
        XCTAssertEqual(AgentDelivery.BudgetHandOff.recorded(standing: standing(left: 16000), week: "this week").notice(totalCents: 4000),
                       "Estimated total $40.00 sent to Example Budget (Simulated): $160.00 left this week.")
        XCTAssertEqual(AgentDelivery.BudgetHandOff.recorded(standing: standing(left: -2500, within: false), week: "this week").notice(totalCents: 4000),
                       "Estimated total $40.00 sent to Example Budget (Simulated): $25.00 over the budget this week.")
        XCTAssertEqual(AgentDelivery.BudgetHandOff.recorded(standing: standing(left: 16000), week: "week of Nov 2").notice(totalCents: 4000),
                       "Estimated total $40.00 sent to Example Budget (Simulated): $160.00 left for the week of Nov 2.")
        XCTAssertEqual(AgentDelivery.BudgetHandOff.recorded(standing: standing(left: -2500, within: false), week: "week of Nov 2").notice(totalCents: 4000),
                       "Estimated total $40.00 sent to Example Budget (Simulated): $25.00 over the budget for the week of Nov 2.")
        XCTAssertEqual(AgentDelivery.budgetNotice(totalCents: 35600, standing: standing(left: -15600, within: false), week: "this week"),
                       "Estimated total $356.00 sent to Example Budget (Simulated): $156.00 over the budget this week.")
        XCTAssertEqual(AgentDelivery.BudgetHandOff.unavailable(notify: true).notice(totalCents: 4000),
                       "The estimated total could not be sent to \(BudgetClient.partnerName) (Simulated).")
        XCTAssertEqual(AgentDelivery.budgetFailureNotice, "The estimated total could not be sent to Example Budget (Simulated).")
        XCTAssertNil(AgentDelivery.BudgetHandOff.unavailable(notify: false).notice(totalCents: 4000))

        // Every fixed text: English, no Hangul, none of the words of REQ-DELIVERY-015.
        var texts: [String] = [
            AgentDelivery.optionsMessage, AgentDelivery.optionsUnavailableMessage, AgentDelivery.appliedMessage,
            AgentDelivery.mealAddedSentence, AgentDelivery.mealMissedSentence, AgentDelivery.declinedMessage,
            AgentDelivery.unavailableMessage, AgentDelivery.unavailableNotice, AgentDelivery.editRejectedMessage,
            AgentDelivery.budgetRecordedSentence, AgentDelivery.budgetUnavailableSentence, AgentDelivery.budgetFailureNotice,
            AgentDelivery.partnerLine, message, missedMessage, AgentDelivery.estimatedTotalLine(cents: 4000)]
        texts += AgentDelivery.controlLabels
        texts += AgentDelivery.cardLines(placeName: "P", arrives: "A", items: [(name: "Ramen", quantity: 1)], deliveryText: "T",
                                         deliveryIsSuggested: true, cardLabel: "C", totalCents: 1900,
                                         meal: AgentDelivery.CardMeal(title: "Dinner (Simulated)", time: "7:40 PM", isSuggested: true))
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(hasHangul(text), text)
            XCTAssertEqual(forbiddenWords(in: text), [], text)
        }
        // Where the SPEC requires it, a text says Simulated or estimate.
        for text in [AgentDelivery.optionsMessage, AgentDelivery.appliedMessage, AgentDelivery.declinedMessage, AgentDelivery.unavailableMessage,
                     AgentDelivery.optionsUnavailableMessage, AgentDelivery.budgetRecordedSentence, AgentDelivery.budgetUnavailableSentence] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains("simulated"), text)
        }
        for text in [AgentDelivery.optionsMessage, AgentDelivery.appliedMessage, AgentDelivery.budgetRecordedSentence] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains("estimate"), text)
        }
        XCTAssertTrue(AgentDelivery.budgetFailureNotice.contains("(Simulated)"))
        XCTAssertEqual(AgentDelivery.unavailableNotice, "The delivery could not be ordered. Nothing was ordered.")
        XCTAssertTrue(AgentDelivery.mealTitle(arrivalMinute: 1180).contains("Simulated"))
    }
}
