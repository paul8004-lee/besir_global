import XCTest
@testable import besir

/// Fixtures of the live replan tests (SPEC-REPLAN-001). Every event is built from the real `Date()`: the baseline code
/// under test reads `Date()` itself, so a fixed past date would make every alert look fired. Only the new code's clock
/// (`Store.replanNow`) is moved by a test.
@MainActor
enum ReplanFixtures {
    static let home = Place(name: "Home", address: "", latitude: 37.7955, longitude: -122.3937)

    /// A store over the throwaway data directory. `ai` gives it a proxy address so `hasAI` is true; nothing is sent
    /// because every lookup and every draft request goes through a test seam.
    static func store(ai: Bool = false) -> Store {
        let store = EmptyStore.make()
        store.config = ai ? RoutesTestSupport.config : AppConfig()
        return store
    }

    /// A car event whose stored plan is `travel` seconds, arriving `arrivalIn` seconds after `now`. With the defaults
    /// (lead 10 minutes) an arrival 95 minutes away is inside the 120-minute window with its alert still ahead.
    static func event(now: Date, arrivalIn: TimeInterval, travel: TimeInterval = 18 * 60, buffer: Int = 5, lead: Int = 10,
                      mode: TransportMode = .car, name: String = "Park", title: String = "Dinner with Sam") -> ScheduledEvent {
        let arrival = now.addingTimeInterval(arrivalIn)
        let destination = Place(name: name, address: "", latitude: 37.7694, longitude: -122.4862)
        var event = ScheduledEvent(title: title, origin: home, destination: destination, arrivalDate: arrival,
                                   mode: mode, bufferMinutes: buffer, notifyLeadMinutes: lead)
        event.travelSeconds = travel
        event.departureDate = Store.departureTime(arrival: arrival, travelSeconds: travel, bufferMinutes: buffer)
        return event
    }

    /// An event whose alert fired 5 minutes ago and whose departure is 10 minutes ahead (arrival 33 minutes away).
    static func firedEvent(now: Date) -> ScheduledEvent {
        event(now: now, arrivalIn: 33 * 60, lead: 15)
    }

    /// A fired alert with room for a second reading 301 seconds later: stored departure 40 minutes ahead, alarm 5 minutes
    /// behind, arrival 63 minutes away.
    static func firedEventWithSlack(now: Date) -> ScheduledEvent {
        event(now: now, arrivalIn: 63 * 60, lead: 45)
    }

    /// An event whose departure passed 11 minutes ago while its arrival is 12 minutes away.
    static func lateEvent(now: Date) -> ScheduledEvent {
        event(now: now, arrivalIn: 12 * 60)
    }

    typealias Answer = (seconds: TimeInterval, noTrafficSeconds: TimeInterval?)

    static func answering(_ seconds: TimeInterval, free: TimeInterval? = nil) -> (TransportMode, Place, Place) async -> Answer? {
        { _, _, _ in (seconds: seconds, noTrafficSeconds: free) }
    }

    /// Waits (by yielding) until `condition` holds, at most a few thousand turns.
    static func wait(until condition: () -> Bool) async {
        var turns = 0
        while !condition(), turns < 5000 {
            await Task.yield()
            turns += 1
        }
    }
}

/// SPEC-REPLAN-001: the store's replan paths (REQ-REPLAN-003 and 005 to 009), T34 to T49.
@MainActor
final class ReplanStoreTests: XCTestCase {
    private typealias F = ReplanFixtures

    private func setUpStore(clock: MutableClock, events: [ScheduledEvent], ai: Bool = false) -> Store {
        let store = F.store(ai: ai)
        store.replanNow = { clock.now }
        store.events = events
        return store
    }

    // MARK: T34-T35 app open

    func testREPLAN_AppOpenRecordsOutcomeAndPatches() async throws {
        let clock = MutableClock(now: Date())
        let event = F.event(now: clock.now, arrivalIn: 95 * 60)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        let saves = store.drvSaveCount
        let requests = store.notifications.requestCount

        await store.refreshUpcomingEstimates()

        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(outcome.kind, .earlier)
        XCTAssertEqual(outcome.minutes, 13)
        XCTAssertEqual(outcome.noTrafficTravel, 18 * 60)
        XCTAssertEqual(outcome.referenceTravel, 18 * 60)
        XCTAssertEqual(outcome.referenceDeparture, event.departureDate)
        XCTAssertNil(outcome.draft)
        let stored = try XCTUnwrap(store.events.first)
        XCTAssertEqual(stored.travelSeconds, 31 * 60)
        XCTAssertEqual(stored.departureDate,
                       Store.departureTime(arrival: event.arrivalDate, travelSeconds: 31 * 60, bufferMinutes: 5))
        // The baseline path scheduled the departure alert once, and it carries the event id (audit note D2).
        XCTAssertEqual(store.notifications.requestCount, requests + 1)
        XCTAssertEqual(store.notifications.lastRequestEventID, event.id)
        XCTAssertEqual(store.drvSaveCount, saves + 1)
    }

    func testREPLAN_AppOpenUsesLiveLookup() async throws {
        let clock = MutableClock(now: Date())
        let event = F.event(now: clock.now, arrivalIn: 95 * 60)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)

        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        XCTAssertEqual(store.drvNonLiveLookupCount, 0)

        // The creation door is not a refresh: its lookup is not live.
        store.drvTravelLookupOverride = { _, _, _ in 18 * 60 }
        let created = await store.addEvent(title: "New", origin: F.home, destination: F.home,
                                           arrivalDate: clock.now.addingTimeInterval(3 * 3600), mode: .car,
                                           bufferMinutes: 5, notifyLeadMinutes: 10)
        XCTAssertEqual(created.travelSeconds, 18 * 60)
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        XCTAssertEqual(store.drvNonLiveLookupCount, 1)
    }

    // MARK: T36-T38 cost guard

    func testREPLAN_DebounceSkipsWithin300s() async throws {
        let clock = MutableClock(now: Date())
        let store = setUpStore(clock: clock, events: [F.event(now: clock.now, arrivalIn: 95 * 60)])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        clock.now = clock.now.addingTimeInterval(299)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 1)

        // A second pass that starts while the first lookup of the event is in flight makes no second lookup.
        let other = setUpStore(clock: clock, events: [F.event(now: clock.now, arrivalIn: 95 * 60)])
        var gate: CheckedContinuation<Void, Never>?
        other.drvLiveLookupOverride = { _, _, _ in
            await withCheckedContinuation { gate = $0 }
            return (seconds: 31 * 60, noTrafficSeconds: 18 * 60)
        }
        let first = Task { await other.refreshUpcomingEstimates() }
        await F.wait { gate != nil }
        await other.refreshUpcomingEstimates()
        XCTAssertEqual(other.drvLiveLookupCount, 1)
        gate?.resume()
        await first.value
        XCTAssertEqual(other.drvLiveLookupCount, 1)
    }

    func testREPLAN_DebounceReleasesAfter300s() async throws {
        let clock = MutableClock(now: Date())
        let store = setUpStore(clock: clock, events: [F.event(now: clock.now, arrivalIn: 95 * 60)])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        await store.refreshUpcomingEstimates()
        clock.now = clock.now.addingTimeInterval(300)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 2)
    }

    func testREPLAN_PassCapFive() async throws {
        let clock = MutableClock(now: Date())
        // Seven events whose departure already passed and whose arrival is 10 to 16 minutes away.
        let events = (0..<7).map { i in
            F.event(now: clock.now, arrivalIn: Double(10 + i) * 60, name: "D\(i)")
        }
        let store = setUpStore(clock: clock, events: events)
        var seen: [String] = []
        store.drvLiveLookupOverride = { _, _, destination in
            seen.append(destination.name)
            return (seconds: 18 * 60, noTrafficSeconds: nil)
        }
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 5)
        XCTAssertEqual(Set(seen), ["D0", "D1", "D2", "D3", "D4"])
    }

    // MARK: T39-T42 events whose alert fired

    func testREPLAN_PostAlertTargetsTable() {
        let now = TestClock.now
        func make(_ arrivalIn: TimeInterval, travel: TimeInterval? = 18 * 60, withOrigin: Bool = true,
                  anchor: ScheduleAnchor? = nil, lead: Int = 10, name: String) -> ScheduledEvent {
            var e = F.event(now: now, arrivalIn: arrivalIn, lead: lead, name: name)
            e.travelSeconds = travel
            if !withOrigin { e.origin = nil }
            e.anchor = anchor
            return e
        }
        let fired = make(30 * 60, name: "fired")
        let passed = make(10 * 60, name: "passed")
        let arrivalPassed = make(-60, name: "over")
        let anchored = make(30 * 60, anchor: .departure, name: "anchored")
        let baseline = make(95 * 60, name: "baseline")
        let far = make(300 * 60, name: "far")
        let noOrigin = make(20 * 60, withOrigin: false, name: "noOrigin")
        let noTravel = make(20 * 60, travel: nil, name: "noTravel")
        let all = [baseline, far, noOrigin, noTravel, anchored, arrivalPassed, fired, passed]
        let ids = Store.selectPostAlertTargets(events: all, now: now, withinMinutes: 120)
        XCTAssertEqual(ids, [passed.id, fired.id])
        XCTAssertEqual(Store.selectPostAlertTargets(events: all, now: now, withinMinutes: 120, limit: 1), [passed.id])
        XCTAssertTrue(Store.selectRefreshTargets(events: all, now: now, withinMinutes: 120).contains(baseline.id))
    }

    func testREPLAN_PostAlertEarlierStoresNoNotification() async throws {
        let clock = MutableClock(now: Date())
        let event = F.firedEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(31 * 60)
        let requests = store.notifications.requestCount
        let reschedules = store.drvRescheduleCount
        let saves = store.drvSaveCount

        await store.replanAfterAlert(id: event.id, trigger: .alertTap)

        let stored = try XCTUnwrap(store.events.first)
        XCTAssertEqual(stored.travelSeconds, 31 * 60)
        XCTAssertEqual(stored.departureDate,
                       Store.departureTime(arrival: event.arrivalDate, travelSeconds: 31 * 60, bufferMinutes: 5))
        XCTAssertEqual(store.notifications.requestCount, requests)
        XCTAssertEqual(store.drvRescheduleCount, reschedules)
        XCTAssertEqual(store.drvSaveCount, saves + 1)
        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(outcome.kind, .earlier)
        XCTAssertEqual(outcome.minutes, 13)
        XCTAssertEqual(outcome.trigger, .alertTap)
    }

    func testREPLAN_PostAlertLaterNeverStores() async throws {
        let clock = MutableClock(now: Date())
        let event = F.firedEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(10 * 60)
        let requests = store.notifications.requestCount
        let saves = store.drvSaveCount

        await store.replanAfterAlert(id: event.id, trigger: .alertTap)

        XCTAssertEqual(store.events.first?.travelSeconds, 18 * 60)
        XCTAssertEqual(store.events.first?.departureDate, event.departureDate)
        // The later departure is shown (SPEC-REPLAN-002) and never stored.
        let shown = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(shown.kind, .later)
        XCTAssertTrue(shown.afterAlert)
        XCTAssertEqual(shown.minutes, 8)
        XCTAssertEqual(store.notifications.requestCount, requests)
        XCTAssertEqual(store.drvSaveCount, saves)

        // The late warning does not depend on the stored value: the outcome is made, nothing is stored.
        let late = F.lateEvent(now: clock.now)
        let lateStore = setUpStore(clock: clock, events: [late])
        lateStore.drvLiveLookupOverride = F.answering(17 * 60)
        await lateStore.replanAfterAlert(id: late.id, trigger: .alertTap)
        let outcome = try XCTUnwrap(lateStore.replanOutcomes[late.id])
        XCTAssertEqual(outcome.kind, .late)
        XCTAssertEqual(outcome.minutes, 5)
        XCTAssertEqual(lateStore.events.first?.travelSeconds, 18 * 60)
        XCTAssertEqual(lateStore.events.first?.departureDate, late.departureDate)
    }

    func testREPLAN_PostAlertLateOutcomeNoNotification() async throws {
        let clock = MutableClock(now: Date())
        let event = F.lateEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(30 * 60)
        let requests = store.notifications.requestCount

        await store.replanAfterAlert(id: event.id, trigger: .alertTap)

        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(outcome.kind, .late)
        XCTAssertEqual(outcome.minutes, 18)
        let estimate = clock.now.addingTimeInterval(30 * 60)
        XCTAssertEqual(outcome.arrivalEstimate, estimate)
        XCTAssertEqual(outcome.draft, Replan.templateDraft(lateBy: 18, title: "Dinner with Sam", estimate: estimate))
        XCTAssertEqual(store.events.first?.travelSeconds, 30 * 60)
        XCTAssertEqual(store.events.first?.departureDate,
                       Store.departureTime(arrival: event.arrivalDate, travelSeconds: 30 * 60, bufferMinutes: 5))
        XCTAssertEqual(store.notifications.requestCount, requests)
    }

    // MARK: T43-T44 failure and tap

    func testREPLAN_LookupFailureKeepsEverythingAndDebounce() async throws {
        let clock = MutableClock(now: Date())
        let event = F.event(now: clock.now, arrivalIn: 95 * 60)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        await store.refreshUpcomingEstimates()
        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        let stored = try XCTUnwrap(store.events.first)

        clock.now = clock.now.addingTimeInterval(400)
        store.drvLiveLookupOverride = { _, _, _ in nil }
        await store.refreshUpcomingEstimates()

        XCTAssertEqual(store.drvLiveLookupCount, 2)
        XCTAssertEqual(store.replanOutcomes[event.id], outcome)
        XCTAssertEqual(store.events.first?.travelSeconds, stored.travelSeconds)
        XCTAssertEqual(store.events.first?.departureDate, stored.departureDate)
        XCTAssertEqual(store.events.first?.notificationId, stored.notificationId)

        // A failed lookup did not start the 300 seconds: the next pass at the same instant looks up again.
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 3)
    }

    func testREPLAN_AlertTapObeysTheLookupGuards() async throws {
        let clock = MutableClock(now: Date())
        let t0 = clock.now
        let fired = F.firedEvent(now: clock.now)
        var past = F.event(now: clock.now, arrivalIn: -60, name: "Past")
        past.departureDate = clock.now.addingTimeInterval(-30 * 60)
        var anchored = F.firedEvent(now: clock.now)
        anchored.anchor = .departure
        let store = setUpStore(clock: clock, events: [fired, past, anchored])
        store.drvLiveLookupOverride = F.answering(31 * 60)

        await store.replanAfterAlert(id: fired.id, trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        // Every tap obeys the guards of the app open (REQ-REPLAN-302): less than 300 seconds after the last lookup, no lookup.
        clock.now = t0.addingTimeInterval(10)
        await store.replanAfterAlert(id: fired.id, trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        clock.now = t0.addingTimeInterval(299)
        await store.replanAfterAlert(id: fired.id, trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        clock.now = t0.addingTimeInterval(300)
        await store.replanAfterAlert(id: fired.id, trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 2)

        // No lookup and no draft for a past arrival, an event anchored on departure, or an event that is gone.
        await store.replanAfterAlert(id: past.id, trigger: .alertTap)
        await store.replanAfterAlert(id: anchored.id, trigger: .alertTap)
        await store.replanAfterAlert(id: UUID(), trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 2)
        XCTAssertNil(store.replanOutcomes[past.id])
        XCTAssertNil(store.replanOutcomes[anchored.id])

        // The hook the store set on the notification manager starts the same check once the 300 seconds have passed.
        clock.now = t0.addingTimeInterval(600)
        store.notifications.handleTap(userInfo: [NotificationManager.eventIDKey: fired.id.uuidString])
        await F.wait { store.drvLiveLookupCount == 3 }
        XCTAssertEqual(store.drvLiveLookupCount, 3)
    }

    // MARK: T45-T46 second trigger and stale results

    func testREPLAN_SecondTriggerKeepsOutcome() async throws {
        let clock = MutableClock(now: Date())
        let event = F.event(now: clock.now, arrivalIn: 95 * 60)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        await store.refreshUpcomingEstimates()
        let first = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(first.kind, .earlier)
        XCTAssertEqual(first.minutes, 13)
        // The alert fires: the next taps are fired-alert taps.
        store.events[0].notifyLeadMinutes = 180

        // A tap with the same answer: the comparison is still with the first plan, so the lines are the same.
        clock.now = clock.now.addingTimeInterval(301)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        let second = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(second.referenceDeparture, event.departureDate)
        XCTAssertEqual(second.referenceTravel, 18 * 60)
        XCTAssertEqual(second.kind, .earlier)
        XCTAssertEqual(second.minutes, 13)
        XCTAssertEqual(Replan.headline(for: second), Replan.headline(for: first))
        XCTAssertEqual(Replan.reason(for: second), Replan.reason(for: first))

        // Traffic clears after the alert fired: a later departure than the stored one is shown and not stored, and it
        // compares with the stored pair (31 min), not with the first plan.
        clock.now = clock.now.addingTimeInterval(301)
        store.drvLiveLookupOverride = F.answering(19 * 60)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        let third = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(third.kind, .later)
        XCTAssertTrue(third.afterAlert)
        XCTAssertEqual(third.minutes, 12)
        XCTAssertEqual(third.referenceTravel, 31 * 60)
        XCTAssertEqual(store.events.first?.travelSeconds, 31 * 60)

        // The same answer on an app-open pass of an event whose alert has not fired: the stored pair is the new live pair
        // and the carried reference is the stored pair of the step before.
        store.events[0].notifyLeadMinutes = 10
        clock.now = clock.now.addingTimeInterval(400)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.events.first?.travelSeconds, 19 * 60)
        let fourth = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(fourth.kind, .later)
        XCTAssertEqual(fourth.minutes, 12)
        XCTAssertFalse(fourth.afterAlert)
    }

    func testREPLAN_StaleResultDiscarded() async throws {
        // The record is edited while the lookup is in flight: nothing is written, no outcome is stored.
        let clock = MutableClock(now: Date())
        let event = F.firedEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = { _, _, _ in
            store.events[0].bufferMinutes = 15
            return (seconds: 31 * 60, noTrafficSeconds: nil)
        }
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        XCTAssertNil(store.replanOutcomes[event.id])
        XCTAssertEqual(store.events.first?.travelSeconds, 18 * 60)
    }

    // MARK: T54-T58 after the alert, a later departure (SPEC-REPLAN-002)

    func testREPLAN_PostAlertLaterKeepsOutcomeStoresNothing() async throws {
        let clock = MutableClock(now: Date())
        let event = F.firedEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event], ai: true)
        store.drvLiveLookupOverride = F.answering(10 * 60)
        let requests = store.notifications.requestCount
        let saves = store.drvSaveCount
        let reschedules = store.drvRescheduleCount

        await store.replanAfterAlert(id: event.id, trigger: .alertTap)

        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(outcome.kind, .later)
        XCTAssertTrue(outcome.afterAlert)
        XCTAssertEqual(outcome.minutes, 8)
        XCTAssertEqual(outcome.trigger, .alertTap)
        XCTAssertEqual(outcome.referenceDeparture, event.departureDate)
        XCTAssertEqual(outcome.referenceTravel, 18 * 60)
        XCTAssertEqual(outcome.newDeparture,
                       Store.departureTime(arrival: event.arrivalDate, travelSeconds: 10 * 60, bufferMinutes: 5))
        let stored = try XCTUnwrap(store.events.first)
        XCTAssertEqual(stored.travelSeconds, 18 * 60)
        XCTAssertEqual(stored.departureDate, event.departureDate)
        XCTAssertEqual(stored.notificationId, event.notificationId)
        XCTAssertEqual(store.notifications.requestCount, requests)
        XCTAssertEqual(store.drvSaveCount, saves)
        XCTAssertEqual(store.drvRescheduleCount, reschedules)

        let lines = Replan.displayLines(for: outcome, event: stored, now: clock.now)
        XCTAssertEqual(lines?.afterAlert, true)
        // The reading is younger than the live departure only up to 15 minutes.
        XCTAssertNil(Replan.displayLines(for: outcome, event: stored, now: clock.now.addingTimeInterval(16 * 60)))
    }

    func testREPLAN_PostAlertSmallLaterRemovesOnlyAfterAlert() async throws {
        let clock = MutableClock(now: Date())
        let event = F.firedEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(10 * 60)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        XCTAssertEqual(store.replanOutcomes[event.id]?.afterAlert, true)

        // (a) A reading one minute later than the stored departure removes the after-alert outcome.
        clock.now = clock.now.addingTimeInterval(301)
        store.drvLiveLookupOverride = F.answering(17 * 60)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        XCTAssertNil(store.replanOutcomes[event.id])
        XCTAssertEqual(store.events.first?.travelSeconds, 18 * 60)
        XCTAssertEqual(store.events.first?.departureDate, event.departureDate)

        // (b) An outcome of another kind is left alone by the same small reading.
        let other = F.firedEventWithSlack(now: clock.now)
        let second = setUpStore(clock: clock, events: [other])
        second.drvLiveLookupOverride = F.answering(31 * 60)
        await second.replanAfterAlert(id: other.id, trigger: .alertTap)
        let earlier = try XCTUnwrap(second.replanOutcomes[other.id])
        XCTAssertEqual(earlier.kind, .earlier)
        clock.now = clock.now.addingTimeInterval(301)
        second.drvLiveLookupOverride = F.answering(30 * 60)
        await second.replanAfterAlert(id: other.id, trigger: .alertTap)
        XCTAssertEqual(second.replanOutcomes[other.id], earlier)
        XCTAssertEqual(second.events.first?.travelSeconds, 31 * 60)
    }

    func testREPLAN_PostAlertLaterThenEarlierUsesBasePath() async throws {
        let clock = MutableClock(now: Date())
        let event = F.firedEventWithSlack(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(10 * 60)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        XCTAssertEqual(store.replanOutcomes[event.id]?.afterAlert, true)
        let requests = store.notifications.requestCount

        clock.now = clock.now.addingTimeInterval(301)
        store.drvLiveLookupOverride = F.answering(31 * 60)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)

        XCTAssertEqual(store.events.first?.travelSeconds, 31 * 60)
        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(outcome.kind, .earlier)
        XCTAssertEqual(outcome.minutes, 13)
        XCTAssertFalse(outcome.afterAlert)
        XCTAssertEqual(store.notifications.requestCount, requests)
    }

    func testREPLAN_AppOpenPassShowsLaterForFiredEvent() async throws {
        let clock = MutableClock(now: Date())
        let event = F.firedEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(10 * 60)

        await store.refreshUpcomingEstimates()

        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(outcome.kind, .later)
        XCTAssertTrue(outcome.afterAlert)
        XCTAssertEqual(outcome.trigger, .appOpen)
        XCTAssertEqual(store.events.first?.travelSeconds, 18 * 60)
        XCTAssertEqual(store.events.first?.departureDate, event.departureDate)
        XCTAssertEqual(store.drvLiveLookupCount, 1)
    }

    func testREPLAN_RescheduleAfterLaterOutcomeAddsNoRequest() async throws {
        let clock = MutableClock(now: Date())
        let event = F.firedEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(10 * 60)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        XCTAssertEqual(store.replanOutcomes[event.id]?.afterAlert, true)
        let requests = store.notifications.requestCount

        store.rescheduleNearestNotifications()

        XCTAssertEqual(store.notifications.requestCount, requests)
        XCTAssertNil(store.events.first?.notificationId)
    }

    // MARK: T47-T49 reschedule, background, anchored

    func testREPLAN_RescheduleAfterPostAlertAddsNoRequest() async throws {
        let clock = MutableClock(now: Date())
        let event = F.firedEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(31 * 60)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        let requests = store.notifications.requestCount

        store.rescheduleNearestNotifications()

        XCTAssertEqual(store.notifications.requestCount, requests)
        XCTAssertNil(store.events.first?.notificationId)
    }

    func testREPLAN_BackgroundPassNotLive() async throws {
        let clock = MutableClock(now: Date())
        let car = F.event(now: clock.now, arrivalIn: 95 * 60, name: "Car")
        let transit = F.event(now: clock.now, arrivalIn: 100 * 60, mode: .transit, name: "Transit")
        // A fresh store, as in a background launch: no outcome in memory.
        let store = setUpStore(clock: clock, events: [car, transit], ai: true)
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        store.drvTravelLookupOverride = { _, _, _ in 40 * 60 }

        await store.refreshUpcomingEstimates(trigger: .background)

        XCTAssertEqual(store.events.first { $0.id == car.id }?.travelSeconds, 18 * 60)
        XCTAssertEqual(store.events.first { $0.id == car.id }?.departureDate, car.departureDate)
        XCTAssertEqual(store.events.first { $0.id == transit.id }?.travelSeconds, 40 * 60)
        XCTAssertEqual(store.drvLiveLookupCount, 0)
        XCTAssertEqual(store.drvNonLiveLookupCount, 1)
        XCTAssertTrue(store.replanOutcomes.isEmpty)
    }

    func testREPLAN_AnchoredEventNotLive() async throws {
        let clock = MutableClock(now: Date())
        var event = F.event(now: clock.now, arrivalIn: 60 * 60, buffer: 0)
        event.anchor = .departure
        event.departureDate = clock.now.addingTimeInterval(30 * 60)
        event.arrivalDate = clock.now.addingTimeInterval(30 * 60 + 18 * 60)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        store.drvTravelLookupOverride = { _, _, _ in 18 * 60 }

        await store.refreshUpcomingEstimates()

        XCTAssertEqual(store.drvLiveLookupCount, 0)
        XCTAssertEqual(store.drvNonLiveLookupCount, 1)
        XCTAssertTrue(store.replanOutcomes.isEmpty)
    }

    // MARK: SPEC-REPLAN-003 taps on alerts, late numbers, order

    func testREPLAN_TapRouteTable() {
        // Whole seconds, so that "alarm exactly now" is exact arithmetic.
        let now = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
        func off(_ e: ScheduledEvent) -> ScheduledEvent { var c = e; c.notifyEnabled = false; return c }
        // Departure 150 min ahead, alarm 30 min behind.
        let retimed = F.event(now: now, arrivalIn: 173 * 60, lead: 180)
        let rows: [(String, ScheduledEvent, Store.TapRoute, Bool)] = [
            ("pending inside", F.event(now: now, arrivalIn: 95 * 60), .baseline, true),
            ("pending at 120 min", F.event(now: now, arrivalIn: 143 * 60), .baseline, true),
            ("pending at 120 min + 1 s", F.event(now: now, arrivalIn: 143 * 60 + 1), .nothing, true),
            ("pending at 177 min", F.event(now: now, arrivalIn: 200 * 60), .nothing, true),
            ("fired inside", F.firedEvent(now: now), .fired, false),
            ("fired beyond", retimed, .fired, false),
            ("alerts off inside", off(F.event(now: now, arrivalIn: 95 * 60)), .fired, false),
            ("alerts off beyond", off(F.event(now: now, arrivalIn: 200 * 60)), .fired, false),
            ("departure behind", F.lateEvent(now: now), .fired, false),
            ("alarm exactly now", F.event(now: now, arrivalIn: 33 * 60, lead: 10), .fired, false)
        ]
        for (name, event, route, pending) in rows {
            XCTAssertEqual(Store.tapRoute(for: event, now: now, withinMinutes: Store.refreshWindowMinutes), route, name)
            let departure = event.departureDate ?? now
            XCTAssertEqual(Store.alertIsPending(wants: event.wantsNotification, departure: departure,
                                                leadMinutes: event.notifyLeadMinutes, now: now),
                           event.wantsNotification && pending, name)
            // The app-open selection and the route agree for every event that wants an alert and departs inside the window.
            if event.wantsNotification, departure > now,
               departure <= now.addingTimeInterval(Double(Store.refreshWindowMinutes) * 60) {
                let selected = Store.selectRefreshTargets(events: [event], now: now, withinMinutes: Store.refreshWindowMinutes)
                XCTAssertEqual(selected.contains(event.id), route == .baseline, name)
            }
        }
    }

    func testREPLAN_TapOnPendingAlertStoresAndMovesAlert() async throws {
        let clock = MutableClock(now: Date())
        var event = F.event(now: clock.now, arrivalIn: 95 * 60)
        event.notificationId = "old-alert"
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        let requests = store.notifications.requestCount
        let saves = store.drvSaveCount
        let reschedules = store.drvRescheduleCount

        await store.replanAfterAlert(id: event.id, trigger: .alertTap)

        let stored = try XCTUnwrap(store.events.first)
        XCTAssertEqual(stored.travelSeconds, 31 * 60)
        XCTAssertEqual(stored.departureDate,
                       Store.departureTime(arrival: event.arrivalDate, travelSeconds: 31 * 60, bufferMinutes: 5))
        XCTAssertNotNil(stored.notificationId)
        XCTAssertNotEqual(stored.notificationId, "old-alert")
        XCTAssertEqual(store.notifications.requestCount, requests + 1)
        XCTAssertEqual(store.notifications.lastRequestEventID, event.id)
        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(outcome.kind, .earlier)
        XCTAssertEqual(outcome.minutes, 13)
        XCTAssertEqual(outcome.trigger, .alertTap)
        XCTAssertFalse(outcome.afterAlert)
        XCTAssertEqual(store.drvSaveCount, saves + 1)
        // The tap alone moved the alert: no reschedule ran (D6).
        XCTAssertEqual(store.drvRescheduleCount, reschedules)
        XCTAssertEqual(store.drvLiveLookupCount, 1)

        // What the foreground does next re-adds the alert from the stored, new departure.
        store.rescheduleNearestNotifications()
        XCTAssertEqual(store.drvRescheduleCount, reschedules + 1)
        XCTAssertEqual(store.notifications.requestCount, requests + 2)
        XCTAssertNotNil(store.events.first?.notificationId)
        let after = try XCTUnwrap(store.events.first)
        XCTAssertTrue(Store.alertIsPending(wants: after.wantsNotification, departure: try XCTUnwrap(after.departureDate),
                                           leadMinutes: after.notifyLeadMinutes, now: Date()))
    }

    func testREPLAN_TapOnPendingAlertStoresLaterToo() async throws {
        let clock = MutableClock(now: Date())
        let event = F.event(now: clock.now, arrivalIn: 95 * 60)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(10 * 60, free: 10 * 60)
        let requests = store.notifications.requestCount

        await store.replanAfterAlert(id: event.id, trigger: .alertTap)

        let stored = try XCTUnwrap(store.events.first)
        XCTAssertEqual(stored.travelSeconds, 10 * 60)
        XCTAssertEqual(stored.departureDate,
                       Store.departureTime(arrival: event.arrivalDate, travelSeconds: 10 * 60, bufferMinutes: 5))
        XCTAssertEqual(store.notifications.requestCount, requests + 1)
        XCTAssertEqual(store.notifications.lastRequestEventID, event.id)
        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(outcome.kind, .later)
        XCTAssertEqual(outcome.minutes, 8)
        XCTAssertFalse(outcome.afterAlert)
    }

    func testREPLAN_TapOnPendingAlertUsesAppOpenGuards() async throws {
        let clock = MutableClock(now: Date())
        let t0 = clock.now
        let event = F.event(now: clock.now, arrivalIn: 95 * 60)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        let stored = try XCTUnwrap(store.events.first)

        clock.now = t0.addingTimeInterval(299)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        XCTAssertEqual(store.events.first?.travelSeconds, stored.travelSeconds)
        XCTAssertEqual(store.events.first?.departureDate, stored.departureDate)
        XCTAssertEqual(store.replanOutcomes[event.id], outcome)
        clock.now = t0.addingTimeInterval(300)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 2)

        // A tap while the first lookup of the event is in flight makes no second lookup.
        let other = setUpStore(clock: clock, events: [F.event(now: clock.now, arrivalIn: 95 * 60)])
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        other.drvLiveLookupOverride = { _, _, _ in
            calls += 1
            // Only the first lookup waits: a second one (a wrong build) must not hang the suite.
            if calls == 1 { await withCheckedContinuation { gate = $0 } }
            return (seconds: 31 * 60, noTrafficSeconds: 18 * 60)
        }
        let otherID = other.events[0].id
        let first = Task { await other.replanAfterAlert(id: otherID, trigger: .alertTap) }
        await F.wait { gate != nil }
        await other.replanAfterAlert(id: otherID, trigger: .alertTap)
        XCTAssertEqual(other.drvLiveLookupCount, 1)
        gate?.resume()
        await first.value
        XCTAssertEqual(other.drvLiveLookupCount, 1)

        // A failed lookup changes nothing, saves nothing and does not start the 300 seconds.
        let failing = setUpStore(clock: clock, events: [F.event(now: clock.now, arrivalIn: 95 * 60)])
        failing.drvLiveLookupOverride = { _, _, _ in nil }
        let failingID = failing.events[0].id
        let before = failing.events[0]
        let saves = failing.drvSaveCount
        await failing.replanAfterAlert(id: failingID, trigger: .alertTap)
        XCTAssertEqual(failing.drvLiveLookupCount, 1)
        XCTAssertEqual(failing.drvSaveCount, saves)
        XCTAssertNil(failing.replanOutcomes[failingID])
        XCTAssertEqual(failing.events[0].travelSeconds, before.travelSeconds)
        XCTAssertEqual(failing.events[0].departureDate, before.departureDate)
        await failing.replanAfterAlert(id: failingID, trigger: .alertTap)
        XCTAssertEqual(failing.drvLiveLookupCount, 2)
    }

    func testREPLAN_TapOnPendingAlertQueuesCatchUpAndDeliversIt() async throws {
        let clock = MutableClock(now: Date())
        let event = F.event(now: clock.now, arrivalIn: 95 * 60)
        let store = setUpStore(clock: clock, events: [event])
        // The new departure is 5 minutes ahead and its alarm (lead 10) is behind: a catch-up decision.
        store.drvLiveLookupOverride = F.answering(85 * 60, free: 18 * 60)
        let requests = store.notifications.requestCount
        let reschedules = store.drvRescheduleCount

        await store.replanAfterAlert(id: event.id, trigger: .alertTap)

        XCTAssertEqual(store.events.first?.travelSeconds, 85 * 60)
        XCTAssertEqual(store.drvRescheduleCount, reschedules + 1)
        XCTAssertEqual(store.notifications.requestCount, requests + 1)
        XCTAssertEqual(store.notifications.lastRequestEventID, event.id)
        XCTAssertNil(store.events.first?.notificationId)
    }

    func testREPLAN_TapOnPendingAlertBeyondWindowDoesNothing() async throws {
        let clock = MutableClock(now: Date())
        let event = F.event(now: clock.now, arrivalIn: 100 * 60)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])

        // The 300 seconds are over, so only the window can explain a missing lookup.
        clock.now = clock.now.addingTimeInterval(301)
        var edited = store.events[0]
        edited.arrivalDate = clock.now.addingTimeInterval(200 * 60)
        edited.departureDate = Store.departureTime(arrival: edited.arrivalDate, travelSeconds: 31 * 60,
                                                   bufferMinutes: edited.bufferMinutes)
        store.events[0] = edited
        let requests = store.notifications.requestCount
        let saves = store.drvSaveCount
        let reschedules = store.drvRescheduleCount

        await store.replanAfterAlert(id: event.id, trigger: .alertTap)

        XCTAssertEqual(store.drvLiveLookupCount, 1)
        XCTAssertEqual(store.events.first?.travelSeconds, edited.travelSeconds)
        XCTAssertEqual(store.events.first?.departureDate, edited.departureDate)
        XCTAssertEqual(store.events.first?.notificationId, edited.notificationId)
        XCTAssertEqual(store.replanOutcomes[event.id], outcome)
        XCTAssertEqual(store.notifications.requestCount, requests)
        XCTAssertEqual(store.drvSaveCount, saves)
        XCTAssertEqual(store.drvRescheduleCount, reschedules)

        // Control: a pending event inside the window is looked up by a tap at the same clock.
        let control = F.event(now: clock.now, arrivalIn: 100 * 60, name: "Control")
        store.events.append(control)
        await store.replanAfterAlert(id: control.id, trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 2)
    }

    func testREPLAN_FiredAlertTapStaysAndGuardsAlertPendingDuringLookup() async throws {
        // (a) Alerts off on a pending fixture keep the fired-alert path: a later departure is shown and not stored.
        let clock = MutableClock(now: Date())
        var off = F.event(now: clock.now, arrivalIn: 95 * 60)
        off.notifyEnabled = false
        let first = setUpStore(clock: clock, events: [off])
        first.drvLiveLookupOverride = F.answering(10 * 60)
        let requests = first.notifications.requestCount
        await first.replanAfterAlert(id: off.id, trigger: .alertTap)
        let shown = try XCTUnwrap(first.replanOutcomes[off.id])
        XCTAssertEqual(shown.kind, .later)
        XCTAssertTrue(shown.afterAlert)
        XCTAssertEqual(first.events.first?.travelSeconds, 18 * 60)
        XCTAssertEqual(first.notifications.requestCount, requests)
        XCTAssertEqual(first.drvLiveLookupCount, 1)

        // (b) The departure is retimed during the lookup so that the alert is pending: nothing is written.
        let fired = F.firedEvent(now: clock.now)
        let second = setUpStore(clock: clock, events: [fired])
        let retimed = clock.now.addingTimeInterval(60 * 60)
        second.drvLiveLookupOverride = { _, _, _ in
            second.events[0].departureDate = retimed
            return (seconds: 31 * 60, noTrafficSeconds: nil)
        }
        let secondRequests = second.notifications.requestCount
        await second.replanAfterAlert(id: fired.id, trigger: .alertTap)
        XCTAssertNil(second.replanOutcomes[fired.id])
        XCTAssertEqual(second.events.first?.travelSeconds, 18 * 60)
        XCTAssertEqual(second.events.first?.departureDate, retimed)
        XCTAssertEqual(second.notifications.requestCount, secondRequests)
    }

    func testREPLAN_SkippedTriggersLeaveTheOutcomeUntouched() async throws {
        let clock = MutableClock(now: Date())
        // (a) A pending alert: a skipped app-open pass and a skipped tap change nothing.
        let pending = F.event(now: clock.now, arrivalIn: 95 * 60)
        let store = setUpStore(clock: clock, events: [pending])
        store.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        let outcome = try XCTUnwrap(store.replanOutcomes[pending.id])
        let stored = try XCTUnwrap(store.events.first)
        let requests = store.notifications.requestCount

        clock.now = clock.now.addingTimeInterval(100)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        XCTAssertEqual(store.replanOutcomes[pending.id], outcome)
        XCTAssertEqual(store.events.first?.travelSeconds, stored.travelSeconds)
        XCTAssertEqual(store.events.first?.departureDate, stored.departureDate)
        XCTAssertEqual(store.notifications.requestCount, requests)
        let saves = store.drvSaveCount
        await store.replanAfterAlert(id: pending.id, trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        XCTAssertEqual(store.replanOutcomes[pending.id], outcome)
        XCTAssertEqual(store.events.first?.travelSeconds, stored.travelSeconds)
        XCTAssertEqual(store.events.first?.departureDate, stored.departureDate)
        XCTAssertEqual(store.notifications.requestCount, requests)
        XCTAssertEqual(store.drvSaveCount, saves)

        // (b) A fired alert: the same, for the post-alert guard of the app open and for the tap.
        let clock2 = MutableClock(now: Date())
        let fired = F.firedEvent(now: clock2.now)
        let second = setUpStore(clock: clock2, events: [fired])
        second.drvLiveLookupOverride = F.answering(31 * 60, free: 18 * 60)
        await second.replanAfterAlert(id: fired.id, trigger: .alertTap)
        XCTAssertEqual(second.drvLiveLookupCount, 1)
        let kept = try XCTUnwrap(second.replanOutcomes[fired.id])
        let storedFired = try XCTUnwrap(second.events.first)
        let firedRequests = second.notifications.requestCount

        clock2.now = clock2.now.addingTimeInterval(100)
        await second.refreshUpcomingEstimates()
        let firedSaves = second.drvSaveCount
        await second.replanAfterAlert(id: fired.id, trigger: .alertTap)
        XCTAssertEqual(second.drvLiveLookupCount, 1)
        XCTAssertEqual(second.replanOutcomes[fired.id], kept)
        XCTAssertEqual(second.events.first?.travelSeconds, storedFired.travelSeconds)
        XCTAssertEqual(second.events.first?.departureDate, storedFired.departureDate)
        XCTAssertEqual(second.notifications.requestCount, firedRequests)
        XCTAssertEqual(second.drvSaveCount, firedSaves)
    }

    func testREPLAN_LateLineGrowsWhileLookupsAreSkipped() async throws {
        let clock = MutableClock(now: Date())
        let t0 = clock.now
        let event = F.lateEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(30 * 60)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        let outcome = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(outcome.kind, .late)
        XCTAssertEqual(outcome.minutes, 18)

        clock.now = t0.addingTimeInterval(100)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        XCTAssertEqual(store.replanOutcomes[event.id], outcome)

        let now = t0.addingTimeInterval(180)
        let estimate = now.addingTimeInterval(30 * 60)
        let shown = try XCTUnwrap(store.events.first)
        let lines = try XCTUnwrap(Replan.displayLines(for: store.replanOutcomes[event.id], event: shown, now: now))
        XCTAssertEqual(lines.headline, "Leave now to arrive about \(Replan.clockText(estimate)), 21 min late")
        XCTAssertEqual(lines.draft, Replan.templateDraft(lateBy: 21, title: "Dinner with Sam", estimate: estimate))
    }

    func testREPLAN_FiredAlertTapUsesTheLookupGuards() async throws {
        let clock = MutableClock(now: Date())
        let event = F.firedEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        store.drvLiveLookupOverride = { _, _, _ in
            calls += 1
            // Only the first lookup waits: a second one (a wrong build) must not hang the suite.
            if calls == 1 { await withCheckedContinuation { gate = $0 } }
            return (seconds: 31 * 60, noTrafficSeconds: nil)
        }
        let first = Task { await store.replanAfterAlert(id: event.id, trigger: .alertTap) }
        await F.wait { gate != nil }
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        gate?.resume()
        await first.value
        XCTAssertEqual(store.drvLiveLookupCount, 1)
        XCTAssertEqual(store.events.first?.travelSeconds, 31 * 60)

        // A failed or cancelled lookup changes nothing, saves nothing and does not start the 300 seconds.
        let failing = setUpStore(clock: clock, events: [F.firedEvent(now: clock.now)])
        failing.drvLiveLookupOverride = { _, _, _ in nil }
        let failingID = failing.events[0].id
        let saves = failing.drvSaveCount
        await failing.replanAfterAlert(id: failingID, trigger: .alertTap)
        XCTAssertEqual(failing.drvLiveLookupCount, 1)
        XCTAssertEqual(failing.drvSaveCount, saves)
        XCTAssertNil(failing.replanOutcomes[failingID])
        await failing.replanAfterAlert(id: failingID, trigger: .alertTap)
        XCTAssertEqual(failing.drvLiveLookupCount, 2)

        // A skipped tap still opens the event screen.
        let again = setUpStore(clock: clock, events: [F.firedEvent(now: clock.now)])
        again.drvLiveLookupOverride = F.answering(31 * 60)
        let againID = again.events[0].id
        await again.replanAfterAlert(id: againID, trigger: .alertTap)
        XCTAssertEqual(again.drvLiveLookupCount, 1)
        again.notifications.handleTap(userInfo: [NotificationManager.eventIDKey: againID.uuidString])
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(again.drvLiveLookupCount, 1)
        XCTAssertEqual(again.notifications.tappedEventID, againID)
    }

    func testREPLAN_AppOpenPassReschedulesBeforePostAlertLookups() async throws {
        let clock = MutableClock(now: Date())
        let pending = F.event(now: clock.now, arrivalIn: 95 * 60, name: "P")
        let fired = F.event(now: clock.now, arrivalIn: 33 * 60, lead: 15, name: "F")
        let store = setUpStore(clock: clock, events: [pending, fired])
        var seen: [String: Int] = [:]
        store.drvLiveLookupOverride = { _, _, destination in
            seen[destination.name] = store.drvRescheduleCount
            return (seconds: 31 * 60, noTrafficSeconds: 18 * 60)
        }
        await store.runAppOpenPass()
        let atPending = try XCTUnwrap(seen["P"])
        let atFired = try XCTUnwrap(seen["F"])
        XCTAssertEqual(atFired, atPending + 1)
        XCTAssertEqual(store.drvRescheduleCount, atFired)

        let empty = setUpStore(clock: clock, events: [])
        let before = empty.drvRescheduleCount
        await empty.runAppOpenPass()
        XCTAssertEqual(empty.drvRescheduleCount, before + 1)
    }

    func testREPLAN_PostAlertPassLeavesRescheduleInputsAlone() async throws {
        let clock = MutableClock(now: Date())
        let earlier = F.event(now: clock.now, arrivalIn: 33 * 60, lead: 15, name: "E")
        let later = F.event(now: clock.now, arrivalIn: 33 * 60, lead: 15, name: "L")
        let late = F.event(now: clock.now, arrivalIn: 12 * 60, name: "T")
        let store = setUpStore(clock: clock, events: [earlier, later, late])
        store.drvLiveLookupOverride = { _, _, destination in
            switch destination.name {
            case "E": return (seconds: 31 * 60, noTrafficSeconds: nil)
            case "L": return (seconds: 10 * 60, noTrafficSeconds: nil)
            default: return (seconds: 30 * 60, noTrafficSeconds: nil)
            }
        }
        func pendingIDs() -> Set<UUID> {
            Set(store.events.filter { e in
                guard let departure = e.departureDate else { return false }
                return Store.alertIsPending(wants: e.wantsNotification, departure: departure,
                                            leadMinutes: e.notifyLeadMinutes, now: Date())
            }.map(\.id))
        }
        let pendingBefore = pendingIDs()
        let requests = store.notifications.requestCount
        let alertIDs = store.events.map(\.notificationId)

        for id in [earlier.id, later.id, late.id] {
            await store.replanAfterAlert(id: id, trigger: .appOpen)
        }

        XCTAssertEqual(pendingIDs(), pendingBefore)
        XCTAssertEqual(store.notifications.requestCount, requests)
        XCTAssertEqual(store.events.map(\.notificationId), alertIDs)
        store.rescheduleNearestNotifications()
        XCTAssertEqual(store.notifications.requestCount, requests)
    }

    func testREPLAN_RefreshUpcomingEstimatesContractUnchanged() async throws {
        let clock = MutableClock(now: Date())
        let pending = F.event(now: clock.now, arrivalIn: 95 * 60, name: "P")
        let fired = F.event(now: clock.now, arrivalIn: 33 * 60, lead: 15, name: "F")
        let store = setUpStore(clock: clock, events: [pending, fired])
        store.drvLiveLookupOverride = { _, _, destination in
            destination.name == "P" ? (seconds: 31 * 60, noTrafficSeconds: 18 * 60) : (seconds: 10 * 60, noTrafficSeconds: nil)
        }
        let reschedules = store.drvRescheduleCount

        await store.refreshUpcomingEstimates()

        let baseline = try XCTUnwrap(store.replanOutcomes[pending.id])
        XCTAssertEqual(baseline.kind, .earlier)
        XCTAssertFalse(baseline.afterAlert)
        let postAlert = try XCTUnwrap(store.replanOutcomes[fired.id])
        XCTAssertEqual(postAlert.kind, .later)
        XCTAssertTrue(postAlert.afterAlert)
        XCTAssertEqual(store.drvRescheduleCount, reschedules)
    }
}
