import XCTest
import CoreLocation
@testable import besir

/// SPEC-REPLAN-001: the pure rules (estimate, classification, texts, alert payload, navigation) and the fixed draft text,
/// T07 to T33. Pure tests use the fixed clock `TestClock` (2026-10-27, America/Los_Angeles); nothing here uses the network.
@MainActor
final class ReplanTests: XCTestCase {
    private typealias Support = RoutesTestSupport
    private typealias F = ReplanFixtures

    private let zone = TestClock.zone
    private func at(_ local: String) -> Date { TestClock.date(local) }

    private func tempLog() -> ConnectionLog {
        ConnectionLog(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("replan-\(UUID().uuidString)-connections.json"))
    }

    // Fixture of the classification tests: arrival 8:30 PM, buffer 5 min, stored plan 18 min (departure 8:07 PM).
    private func event(mode: TransportMode = .car, anchor: ScheduleAnchor? = nil, buffer: Int = 5,
                       arrival: String = "2026-10-27T20:30") -> ScheduledEvent {
        var e = ScheduledEvent(title: "Dinner with Sam", origin: F.home,
                               destination: Place(name: "Park", address: "", latitude: 37.7694, longitude: -122.4862),
                               arrivalDate: at(arrival), mode: mode, bufferMinutes: buffer, notifyLeadMinutes: 10)
        e.anchor = anchor
        return e
    }

    private func classify(live: TimeInterval, now: String = "2026-10-27T19:30", free: TimeInterval? = nil,
                          event e: ScheduledEvent? = nil,
                          reference: (departure: Date, travel: TimeInterval)? = nil) -> ReplanOutcome {
        let ev = e ?? event()
        let ref = reference ?? (at("2026-10-27T20:07"), 18 * 60)
        let n = at(now)
        return Replan.classify(eventID: ev.id, trigger: .appOpen, checkedAt: n, inputs: ReplanInputs(event: ev),
                               referenceDeparture: ref.departure, referenceTravel: ref.travel,
                               liveTravel: live, noTrafficTravel: free, now: n)
    }

    // MARK: T07-T08 estimate

    func testREPLAN_EstimateLiveCarCarriesStatic() async throws {
        let stub = RoutesTransportStub.answering(
            with: Support.json(["routes": [["duration": "1860s", "staticDuration": "1080s", "distanceMeters": 9214]]]))
        let log = tempLog()
        var service = Support.service(stub)
        service.connections = log
        let estimate = await service.estimate(.car, from: Support.origin, to: Support.dest, live: true)
        XCTAssertEqual(estimate.duration, 1860)
        XCTAssertEqual(estimate.staticDuration, 1080)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(Support.body(of: request)?["routingPreference"] as? String, "TRAFFIC_AWARE")
        await log.flush()
        XCTAssertEqual(log.packets.count, 1)
        XCTAssertEqual(log.packets.first?.summary, "Car route")
        XCTAssertEqual(log.packets.first?.status, .ok)
    }

    func testREPLAN_EstimateDefaultHasNoStatic() async throws {
        let answer = Support.json(["routes": [["duration": "1860s", "staticDuration": "1080s", "distanceMeters": 9214]]])
        let service = Support.service(RoutesTransportStub.answering(with: answer))
        let plain = await service.estimate(.car, from: Support.origin, to: Support.dest)
        XCTAssertEqual(plain.duration, 1860)
        XCTAssertNil(plain.staticDuration)
        let transit = await service.estimate(.transit, from: Support.origin, to: Support.dest, live: true)
        XCTAssertEqual(transit.duration, 1860)
        XCTAssertNil(transit.staticDuration)
    }

    // MARK: T09-T15 classification

    func testREPLAN_ClassifyEarlier() {
        let outcome = classify(live: 31 * 60)
        XCTAssertEqual(outcome.kind, .earlier)
        XCTAssertEqual(outcome.minutes, 13)
        XCTAssertEqual(outcome.newDeparture, at("2026-10-27T19:54"))
        XCTAssertNil(outcome.arrivalEstimate)
    }

    func testREPLAN_ClassifyLater() {
        let outcome = classify(live: 10 * 60)
        XCTAssertEqual(outcome.kind, .later)
        XCTAssertEqual(outcome.minutes, 8)
        XCTAssertEqual(outcome.newDeparture, at("2026-10-27T20:15"))
    }

    func testREPLAN_ClassifyThresholdBoundary() {
        let below = classify(live: 19 * 60 + 59)
        XCTAssertEqual(below.kind, .unchanged)
        XCTAssertEqual(below.minutes, 0)
        let exact = classify(live: 20 * 60)
        XCTAssertEqual(exact.kind, .earlier)
        XCTAssertEqual(exact.minutes, 2)
        let eased = classify(live: 16 * 60 + 1)
        XCTAssertEqual(eased.kind, .unchanged)
        XCTAssertEqual(classify(live: 16 * 60).kind, .later)
    }

    func testREPLAN_ClassifyLate() {
        let outcome = classify(live: 31 * 60, now: "2026-10-27T20:20")
        XCTAssertEqual(outcome.kind, .late)
        XCTAssertEqual(outcome.minutes, 21)
        XCTAssertEqual(outcome.arrivalEstimate, at("2026-10-27T20:51"))
        // One second over is still a whole minute late.
        let n = at("2026-10-27T20:30").addingTimeInterval(1 - 31 * 60)
        let edge = Replan.classify(eventID: UUID(), trigger: .appOpen, checkedAt: n, inputs: ReplanInputs(event: event()),
                                   referenceDeparture: at("2026-10-27T20:07"), referenceTravel: 18 * 60,
                                   liveTravel: 31 * 60, noTrafficTravel: nil, now: n)
        XCTAssertEqual(edge.kind, .late)
        XCTAssertEqual(edge.minutes, 1)
    }

    func testREPLAN_ClassifyPrecedenceAndDepartureAnchor() {
        // Both earlier and late: late wins.
        XCTAssertEqual(classify(live: 31 * 60, now: "2026-10-27T20:20").kind, .late)
        // An event anchored on departure never changes, whatever the live time says.
        let anchored = event(anchor: .departure)
        let lives: [TimeInterval] = [10 * 60, 31 * 60, 90 * 60]
        for live in lives {
            let outcome = classify(live: live, now: "2026-10-27T20:20", event: anchored)
            XCTAssertEqual(outcome.kind, .unchanged, "\(live)")
            XCTAssertEqual(outcome.minutes, 0)
            XCTAssertNil(outcome.arrivalEstimate)
        }
    }

    func testREPLAN_ClassifyEasingAgainstReference() {
        // The first plan was 8:07 PM and 18 minutes. Traffic eases step by step.
        XCTAssertEqual(classify(live: 31 * 60).minutes, 13)
        let partly = classify(live: 25 * 60)
        XCTAssertEqual(partly.kind, .earlier)
        XCTAssertEqual(partly.minutes, 7)
        let cleared = classify(live: 19 * 60)
        XCTAssertEqual(cleared.kind, .unchanged)
    }

    func testREPLAN_ClassifyAgainstReference() {
        let e = event()
        let inputs = ReplanInputs(event: e)
        let first = classify(live: 31 * 60, event: e)
        let storedDeparture = at("2026-10-27T19:54")
        let now = at("2026-10-27T19:40")
        // Same inputs, arrival ahead: the first plan of the cycle is the reference, not the adjusted stored pair.
        let kept = Replan.referencePair(existing: first, inputs: inputs, now: now,
                                        storedDeparture: storedDeparture, storedTravel: 31 * 60)
        XCTAssertEqual(kept.departure, at("2026-10-27T20:07"))
        XCTAssertEqual(kept.travel, 18 * 60)
        // The same live answer is judged against that reference: still 13 minutes earlier, not "unchanged".
        let again = classify(live: 31 * 60, now: "2026-10-27T19:40", event: e, reference: kept)
        XCTAssertEqual(again.kind, .earlier)
        XCTAssertEqual(again.minutes, 13)
        // An edited input (the buffer) or a passed arrival means the stored pair is the reference.
        let edited = ReplanInputs(event: event(buffer: 10))
        let afterEdit = Replan.referencePair(existing: first, inputs: edited, now: now,
                                             storedDeparture: storedDeparture, storedTravel: 31 * 60)
        XCTAssertEqual(afterEdit.departure, storedDeparture)
        XCTAssertEqual(afterEdit.travel, 31 * 60)
        let over = Replan.referencePair(existing: first, inputs: inputs, now: at("2026-10-27T20:31"),
                                        storedDeparture: storedDeparture, storedTravel: 31 * 60)
        XCTAssertEqual(over.travel, 31 * 60)
        let none = Replan.referencePair(existing: nil, inputs: inputs, now: now,
                                        storedDeparture: storedDeparture, storedTravel: 31 * 60)
        XCTAssertEqual(none.departure, storedDeparture)
    }

    // MARK: T16-T20 texts and what the card shows

    func testREPLAN_ReasonCarTraffic() {
        let outcome = classify(live: 31 * 60, free: 18 * 60)
        XCTAssertEqual(Replan.reason(for: outcome), "Traffic adds 13 min to the 18 min it takes without traffic.")
    }

    func testREPLAN_ReasonCarNoTrafficFreeTime() {
        XCTAssertEqual(Replan.reason(for: classify(live: 31 * 60)), "Travel time is now 31 min, was 18 min.")
        // Live minus without-traffic of 59 seconds does not name traffic.
        let close = classify(live: 31 * 60, free: 31 * 60 - 59)
        XCTAssertEqual(Replan.reason(for: close), "Travel time is now 31 min, was 18 min.")
        // Exactly 60 seconds does.
        let edge = classify(live: 31 * 60, free: 31 * 60 - 60)
        XCTAssertEqual(Replan.reason(for: edge), "Traffic adds 1 min to the 30 min it takes without traffic.")
    }

    func testREPLAN_ReasonOtherModes() {
        for mode in [TransportMode.transit, .walk, .bicycle] {
            let outcome = classify(live: 31 * 60, free: 18 * 60, event: event(mode: mode))
            XCTAssertEqual(Replan.reason(for: outcome), "Travel time is now 31 min, was 18 min.", "\(mode)")
        }
    }

    func testREPLAN_ReasonTemplatesOnly() throws {
        let traffic = try NSRegularExpression(pattern: #"^Traffic adds \d+ min to the \d+ min it takes without traffic\.$"#)
        let plain = try NSRegularExpression(pattern: #"^Travel time is now \d+ min, was \d+ min\.$"#)
        func matches(_ text: String, _ regex: NSRegularExpression) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        for mode in TransportMode.allCases {
            let frees: [TimeInterval?] = [nil, 10 * 60, 18 * 60, 30 * 60 + 30]
            for free in frees {
                for live in stride(from: 5.0 * 60, through: 60 * 60, by: 7 * 60 + 13) {
                    let text = Replan.reason(for: classify(live: live, free: free, event: event(mode: mode)))
                    XCTAssertTrue(matches(text, traffic) || matches(text, plain), text)
                    XCTAssertFalse(text.lowercased().contains("accident"), text)
                }
            }
        }
    }

    func testREPLAN_DisplayLinesAndLifetime() {
        let e = event()
        // earlier: the card shows it only while the event's departure is the outcome's new departure.
        let earlier = classify(live: 31 * 60, free: 18 * 60, event: e)
        var shown = e
        shown.departureDate = earlier.newDeparture
        let now = at("2026-10-27T19:31")
        let lines = Replan.displayLines(for: earlier, event: shown, now: now, timeZone: zone)
        XCTAssertEqual(lines?.headline, "Leave by 7:54 PM, 13 min earlier")
        XCTAssertEqual(lines?.reason, "Traffic adds 13 min to the 18 min it takes without traffic.")
        XCTAssertNil(lines?.draft)
        XCTAssertNil(Replan.displayLines(for: earlier, event: e, now: now, timeZone: zone), "departure differs")
        // A draft attached to a non-late outcome is never shown.
        var withDraft = earlier
        withDraft.draft = "x"
        XCTAssertNil(Replan.displayLines(for: withDraft, event: shown, now: now, timeZone: zone)?.draft)
        // later
        let later = classify(live: 10 * 60, event: e)
        var laterEvent = e
        laterEvent.departureDate = later.newDeparture
        XCTAssertEqual(Replan.displayLines(for: later, event: laterEvent, now: now, timeZone: zone)?.headline,
                       "Leave by 8:15 PM, 8 min later")
        // unchanged, no outcome, arrival passed, edited arrival, edited mode
        XCTAssertNil(Replan.displayLines(for: classify(live: 18 * 60, event: e), event: e, now: now, timeZone: zone))
        XCTAssertNil(Replan.displayLines(for: nil, event: e, now: now, timeZone: zone))
        XCTAssertNil(Replan.displayLines(for: earlier, event: shown, now: at("2026-10-27T20:31"), timeZone: zone))
        var movedArrival = shown
        movedArrival.arrivalDate = movedArrival.arrivalDate.addingTimeInterval(3600)
        XCTAssertNil(Replan.displayLines(for: earlier, event: movedArrival, now: now, timeZone: zone))
        var otherMode = shown
        otherMode.mode = .walk
        XCTAssertNil(Replan.displayLines(for: earlier, event: otherMode, now: now, timeZone: zone))
        // late: the lines and the draft live 15 minutes after the check, and need no matching departure.
        let lateEvent = event(arrival: "2026-10-27T20:40")
        var late = classify(live: 31 * 60, now: "2026-10-27T20:20", event: lateEvent)
        late.draft = "Hi, I'm running late."
        XCTAssertEqual(late.kind, .late)
        let checked = at("2026-10-27T20:20")
        let early = Replan.displayLines(for: late, event: lateEvent, now: checked.addingTimeInterval(14 * 60 + 59), timeZone: zone)
        XCTAssertEqual(early?.headline, "Leave now to arrive about 9:05 PM, 26 min late")
        XCTAssertEqual(early?.draft, Replan.templateDraft(lateBy: 26, title: "Dinner with Sam",
                                                          estimate: checked.addingTimeInterval(14 * 60 + 59 + 31 * 60),
                                                          timeZone: zone))
        XCTAssertEqual(early?.kind, .late)
        XCTAssertNil(Replan.displayLines(for: late, event: lateEvent, now: checked.addingTimeInterval(15 * 60), timeZone: zone))
    }

    // MARK: T50-T53 after the alert (SPEC-REPLAN-002)

    /// The fixture event as the store holds it after the alert: stored plan 18 min, stored departure 8:07 PM.
    private func storedEvent(arrival: String = "2026-10-27T20:30", departure: String = "2026-10-27T20:07") -> ScheduledEvent {
        var e = event(arrival: arrival)
        e.travelSeconds = 18 * 60
        e.departureDate = at(departure)
        return e
    }

    func testREPLAN_AfterAlertOutcomeShape() throws {
        let stored = at("2026-10-27T20:07")
        let made = classify(live: 10 * 60, now: "2026-10-27T20:10", free: 9 * 60)
        XCTAssertFalse(made.afterAlert)
        let outcome = try XCTUnwrap(Replan.afterAlert(made, storedDeparture: stored, storedTravel: 18 * 60))
        XCTAssertEqual(outcome.kind, .later)
        XCTAssertEqual(outcome.minutes, 8)
        XCTAssertEqual(outcome.newDeparture, at("2026-10-27T20:15"))
        XCTAssertEqual(outcome.referenceDeparture, stored)
        XCTAssertEqual(outcome.referenceTravel, 18 * 60)
        XCTAssertEqual(outcome.liveTravel, 10 * 60)
        XCTAssertEqual(outcome.noTrafficTravel, 9 * 60)
        XCTAssertNil(outcome.arrivalEstimate)
        XCTAssertNil(outcome.draft)
        XCTAssertTrue(outcome.afterAlert)
        XCTAssertEqual(outcome.trigger, made.trigger)
        XCTAssertEqual(outcome.checkedAt, made.checkedAt)

        // The kind the input outcome carried does not matter: a check that compared with a later reference said `earlier`.
        let compared = classify(live: 10 * 60, now: "2026-10-27T20:10",
                                reference: (at("2026-10-27T20:20"), 18 * 60))
        XCTAssertEqual(compared.kind, .earlier)
        let again = try XCTUnwrap(Replan.afterAlert(compared, storedDeparture: stored, storedTravel: 18 * 60))
        XCTAssertEqual(again.kind, .later)
        XCTAssertEqual(again.minutes, 8)
        XCTAssertEqual(again.referenceDeparture, stored)
    }

    func testREPLAN_AfterAlertThresholdAndLate() {
        let stored = at("2026-10-27T20:07")
        func shown(_ live: TimeInterval, now: String = "2026-10-27T19:30") -> ReplanOutcome? {
            Replan.afterAlert(classify(live: live, now: now), storedDeparture: stored, storedTravel: 18 * 60)
        }
        XCTAssertEqual(shown(16 * 60)?.minutes, 2, "exactly 120 seconds later")
        XCTAssertNil(shown(16 * 60 + 1), "119 seconds later")
        XCTAssertNil(shown(18 * 60), "equal")
        XCTAssertNil(shown(31 * 60), "earlier")
        XCTAssertNotNil(shown(10 * 60))
        // A late outcome gives nothing even though its new departure is later than the stored one.
        let late = classify(live: 31 * 60, now: "2026-10-27T20:20")
        XCTAssertEqual(late.kind, .late)
        XCTAssertNil(Replan.afterAlert(late, storedDeparture: at("2026-10-27T19:30"), storedTravel: 18 * 60))
    }

    func testREPLAN_DisplayLinesAfterAlert() throws {
        let e = storedEvent()
        let outcome = try XCTUnwrap(Replan.afterAlert(classify(live: 10 * 60, now: "2026-10-27T20:10", event: e),
                                                      storedDeparture: at("2026-10-27T20:07"), storedTravel: 18 * 60))
        // The stored departure (8:07 PM) has passed, yet the line shows while the live departure (8:15 PM) is ahead.
        let lines = Replan.displayLines(for: outcome, event: e, now: at("2026-10-27T20:11"), timeZone: zone)
        XCTAssertEqual(lines?.headline, "Leave by 8:15 PM, 8 min later")
        XCTAssertEqual(lines?.reason, "Travel time is now 10 min, was 18 min.")
        XCTAssertNil(lines?.draft)
        XCTAssertEqual(lines?.kind, .later)
        XCTAssertEqual(lines?.afterAlert, true)
        XCTAssertNotNil(Replan.displayLines(for: outcome, event: e, now: at("2026-10-27T20:14:59"), timeZone: zone))
        XCTAssertNil(Replan.displayLines(for: outcome, event: e, now: at("2026-10-27T20:15"), timeZone: zone),
                     "not before the live departure")
        let now = at("2026-10-27T20:11")
        var moved = e
        moved.departureDate = at("2026-10-27T20:08")
        XCTAssertNil(Replan.displayLines(for: outcome, event: moved, now: now, timeZone: zone), "stored departure moved")
        var nearly = e
        nearly.departureDate = at("2026-10-27T20:07").addingTimeInterval(0.5)
        XCTAssertNotNil(Replan.displayLines(for: outcome, event: nearly, now: now, timeZone: zone))
        var arrival = e
        arrival.arrivalDate = arrival.arrivalDate.addingTimeInterval(3600)
        XCTAssertNil(Replan.displayLines(for: outcome, event: arrival, now: now, timeZone: zone), "arrival moved")
        var mode = e
        mode.mode = .walk
        XCTAssertNil(Replan.displayLines(for: outcome, event: mode, now: now, timeZone: zone), "mode changed")
        XCTAssertNil(Replan.displayLines(for: outcome, event: e, now: at("2026-10-27T20:31"), timeZone: zone), "arrival passed")
        // An outcome of the ordinary kinds reports `afterAlert` false.
        let earlier = classify(live: 31 * 60, event: e)
        var shown = e
        shown.departureDate = earlier.newDeparture
        XCTAssertEqual(Replan.displayLines(for: earlier, event: shown, now: at("2026-10-27T19:31"), timeZone: zone)?.afterAlert,
                       false)

        // Lifetime: 15 minutes after the check, even while the live departure is still ahead.
        let long = storedEvent(arrival: "2026-10-27T21:30", departure: "2026-10-27T21:07")
        let later = try XCTUnwrap(Replan.afterAlert(classify(live: 10 * 60, now: "2026-10-27T20:10", event: long),
                                                    storedDeparture: at("2026-10-27T21:07"), storedTravel: 18 * 60))
        XCTAssertEqual(later.newDeparture, at("2026-10-27T21:15"))
        XCTAssertNotNil(Replan.displayLines(for: later, event: long, now: at("2026-10-27T20:24:59"), timeZone: zone))
        XCTAssertNil(Replan.displayLines(for: later, event: long, now: at("2026-10-27T20:25:00"), timeZone: zone))
    }

    func testREPLAN_ShowsPassedTable() {
        let departure = at("2026-10-27T20:07")
        let before = at("2026-10-27T20:06")
        let after = at("2026-10-27T20:08")
        XCTAssertTrue(Replan.showsPassed(departure: departure, now: after, afterAlertLine: false))
        XCTAssertFalse(Replan.showsPassed(departure: departure, now: after, afterAlertLine: true))
        XCTAssertFalse(Replan.showsPassed(departure: departure, now: before, afterAlertLine: false))
        XCTAssertFalse(Replan.showsPassed(departure: departure, now: before, afterAlertLine: true))
        XCTAssertFalse(Replan.showsPassed(departure: departure, now: departure, afterAlertLine: false))
    }

    // MARK: T21-T25 alert payload, tap, catch-up text, navigation

    func testREPLAN_ContentCarriesEventID() {
        let id = UUID()
        let with = NotificationManager.content(title: "t", body: "b", eventID: id)
        XCTAssertEqual(with.userInfo[NotificationManager.eventIDKey] as? String, id.uuidString)
        XCTAssertEqual(with.title, "t")
        XCTAssertEqual(with.body, "b")
        XCTAssertTrue(NotificationManager.content(title: "t", body: "b", eventID: nil).userInfo.isEmpty)
    }

    func testREPLAN_EventIDFromUserInfoTable() {
        let id = UUID()
        let key = NotificationManager.eventIDKey
        XCTAssertEqual(NotificationManager.eventID(from: [key: id.uuidString]), id)
        XCTAssertNil(NotificationManager.eventID(from: [:]))
        XCTAssertNil(NotificationManager.eventID(from: [key: 5]))
        XCTAssertNil(NotificationManager.eventID(from: [key: ""]))
        XCTAssertNil(NotificationManager.eventID(from: [key: "not-a-uuid"]))
        XCTAssertNil(NotificationManager.eventID(from: ["other": id.uuidString]))
    }

    func testREPLAN_HandleTapPublishesAndCallsHook() {
        let manager = NotificationManager()
        var called: [UUID] = []
        manager.onAlertTap = { called.append($0) }
        let id = UUID()
        manager.handleTap(userInfo: [NotificationManager.eventIDKey: id.uuidString])
        XCTAssertEqual(manager.tappedEventID, id)
        XCTAssertEqual(called, [id])
        XCTAssertEqual(manager.consumeTappedEventID(), id)
        XCTAssertNil(manager.tappedEventID)
        // A payload without a valid id does neither.
        manager.handleTap(userInfo: [:])
        manager.handleTap(userInfo: [NotificationManager.eventIDKey: "nope"])
        XCTAssertNil(manager.tappedEventID)
        XCTAssertEqual(called, [id])
    }

    func testREPLAN_CatchUpBodyCarriesReason() {
        let base = "Car to Park: 31 min. Leave by 7:54 PM to make it."
        XCTAssertEqual(Replan.catchUpBody(base: base, outcome: nil), base)
        let earlier = classify(live: 31 * 60, free: 18 * 60)
        XCTAssertEqual(Replan.catchUpBody(base: base, outcome: earlier),
                       base + " Traffic adds 13 min to the 18 min it takes without traffic.")
        XCTAssertEqual(Replan.catchUpBody(base: base, outcome: classify(live: 18 * 60)), base)
    }

    func testREPLAN_NavigationConsumeOnce() {
        let e = event()
        XCTAssertEqual(Replan.tapSelection(pending: e.id, events: [e]), e.id)
        XCTAssertNil(Replan.tapSelection(pending: UUID(), events: [e]))
        XCTAssertNil(Replan.tapSelection(pending: nil, events: [e]))
        let manager = NotificationManager()
        manager.handleTap(userInfo: [NotificationManager.eventIDKey: e.id.uuidString])
        // The first screen that asks gets the id; a second ask (the sheet is closed, a screen appears) gets nothing.
        XCTAssertEqual(Replan.tapSelection(pending: manager.consumeTappedEventID(), events: [e]), e.id)
        XCTAssertNil(Replan.tapSelection(pending: manager.consumeTappedEventID(), events: [e]))
        // An id that matches no event is dropped, and it is consumed too.
        manager.handleTap(userInfo: [NotificationManager.eventIDKey: UUID().uuidString])
        XCTAssertNil(Replan.tapSelection(pending: manager.consumeTappedEventID(), events: [e]))
        XCTAssertNil(manager.tappedEventID)
    }

    // MARK: T26-T33 delay draft

    func testREPLAN_DraftTemplateText() {
        let estimate = at("2026-10-27T20:51")
        XCTAssertEqual(Replan.templateDraft(lateBy: 21, title: "Dinner with Sam", estimate: estimate, timeZone: zone),
                       "Hi, I'm running about 21 min late for Dinner with Sam. I should be there around 8:51 PM.")
        let long = String(repeating: "abcdefghij", count: 6)
        let draft = Replan.templateDraft(lateBy: 21, title: long, estimate: estimate, timeZone: zone)
        XCTAssertTrue(draft.contains(String(long.prefix(40)) + "."))
        XCTAssertFalse(draft.contains(String(long.prefix(41))))
    }

    func testREPLAN_DraftOnlyWhenLate() {
        // The classification makes an arrival estimate only for a late outcome; the store adds the draft to that one.
        let lives: [TimeInterval] = [10 * 60, 18 * 60, 31 * 60]
        for live in lives {
            let outcome = classify(live: live)
            XCTAssertNil(outcome.arrivalEstimate, "\(live)")
            XCTAssertNil(outcome.draft, "\(live)")
        }
        XCTAssertNotNil(classify(live: 31 * 60, now: "2026-10-27T20:20").arrivalEstimate)
    }

    // MARK: SPEC-REPLAN-003 late numbers follow the clock

    /// Fixture: arrival 8:40 PM, live 31 min, check 8:20 PM (stored 11 min late, arrival estimate 8:51 PM).
    private func lateFixture() -> (event: ScheduledEvent, outcome: ReplanOutcome, checked: Date) {
        let lateEvent = event(arrival: "2026-10-27T20:40")
        let outcome = classify(live: 31 * 60, now: "2026-10-27T20:20", event: lateEvent)
        return (lateEvent, outcome, at("2026-10-27T20:20"))
    }

    func testREPLAN_LateNumbersFollowTheClock() throws {
        let fixture = lateFixture()
        XCTAssertEqual(fixture.outcome.kind, .late)
        XCTAssertEqual(fixture.outcome.minutes, 11)
        let rows: [(offset: TimeInterval, minutes: Int, arrival: String)] = [
            (-30, 11, "8:51 PM"),          // computed 10.5 min and 8:50 PM, held at the stored values
            (0, 11, "8:51 PM"),
            (180, 14, "8:54 PM"),
            (190, 15, "8:54 PM"),          // 14.17 min rounds up to 15 (to nearest would give 14)
            (210, 15, "8:54 PM"),
            (14 * 60 + 59, 26, "9:05 PM")
        ]
        for row in rows {
            let now = fixture.checked.addingTimeInterval(row.offset)
            let lines = try XCTUnwrap(Replan.displayLines(for: fixture.outcome, event: fixture.event, now: now, timeZone: zone),
                                      "\(row.offset)")
            XCTAssertEqual(lines.headline, "Leave now to arrive about \(row.arrival), \(row.minutes) min late", "\(row.offset)")
            // The minutes are the ones the classification gives for the same clock and the same live time.
            let again = Replan.classify(eventID: fixture.event.id, trigger: .appOpen, checkedAt: fixture.checked,
                                        inputs: ReplanInputs(event: fixture.event),
                                        referenceDeparture: at("2026-10-27T20:07"), referenceTravel: 18 * 60,
                                        liveTravel: 31 * 60, noTrafficTravel: nil, now: now)
            XCTAssertEqual(again.minutes, row.minutes, "\(row.offset)")
        }
        XCTAssertNil(Replan.displayLines(for: fixture.outcome, event: fixture.event,
                                         now: fixture.checked.addingTimeInterval(15 * 60), timeZone: zone))
    }

    func testREPLAN_MessageCarriesTheHeadlineNumbers() throws {
        var fixture = lateFixture()
        fixture.outcome.draft = "stale"
        let now = fixture.checked.addingTimeInterval(180)
        let estimate = now.addingTimeInterval(31 * 60)
        let lines = try XCTUnwrap(Replan.displayLines(for: fixture.outcome, event: fixture.event, now: now, timeZone: zone))
        XCTAssertEqual(lines.headline, "Leave now to arrive about 8:54 PM, 14 min late")
        XCTAssertEqual(lines.draft, Replan.templateDraft(lateBy: 14, title: "Dinner with Sam", estimate: estimate, timeZone: zone))

        var renamed = fixture.event
        renamed.title = "Lunch"
        let lunch = try XCTUnwrap(Replan.displayLines(for: fixture.outcome, event: renamed, now: now, timeZone: zone))
        XCTAssertTrue(try XCTUnwrap(lunch.draft).contains("Lunch"))

        func digitGroupsOf(_ text: String) -> [String] {
            var runs: [String] = []
            var current = ""
            for ch in text {
                if ch.isASCII, ch.isNumber { current.append(ch) } else if !current.isEmpty { runs.append(current); current = "" }
            }
            if !current.isEmpty { runs.append(current) }
            return runs
        }
        XCTAssertEqual(digitGroupsOf(try XCTUnwrap(lines.draft)), digitGroupsOf("14 8:54 PM"))

        // A draft attached to a non-late outcome is never shown.
        var earlier = classify(live: 31 * 60, free: 18 * 60, event: fixture.event)
        earlier.draft = "x"
        var shown = fixture.event
        shown.departureDate = earlier.newDeparture
        XCTAssertNil(Replan.displayLines(for: earlier, event: shown, now: at("2026-10-27T19:31"), timeZone: zone)?.draft)
    }
}
