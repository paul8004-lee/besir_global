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

    func testREPLAN_PostAlertLaterSkipsEntirely() async throws {
        let clock = MutableClock(now: Date())
        let event = F.firedEvent(now: clock.now)
        let store = setUpStore(clock: clock, events: [event])
        store.drvLiveLookupOverride = F.answering(10 * 60)
        let requests = store.notifications.requestCount
        let saves = store.drvSaveCount

        await store.replanAfterAlert(id: event.id, trigger: .alertTap)

        XCTAssertEqual(store.events.first?.travelSeconds, 18 * 60)
        XCTAssertEqual(store.events.first?.departureDate, event.departureDate)
        XCTAssertNil(store.replanOutcomes[event.id])
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

    func testREPLAN_AlertTapIgnoresDebounce() async throws {
        let clock = MutableClock(now: Date())
        let fired = F.firedEvent(now: clock.now)
        var past = F.event(now: clock.now, arrivalIn: -60, name: "Past")
        past.departureDate = clock.now.addingTimeInterval(-30 * 60)
        var anchored = F.firedEvent(now: clock.now)
        anchored.anchor = .departure
        let store = setUpStore(clock: clock, events: [fired, past, anchored])
        store.drvLiveLookupOverride = F.answering(31 * 60)

        await store.replanAfterAlert(id: fired.id, trigger: .alertTap)
        clock.now = clock.now.addingTimeInterval(10)
        await store.replanAfterAlert(id: fired.id, trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 2)

        // No lookup and no draft for a past arrival, an event anchored on departure, or an event that is gone.
        await store.replanAfterAlert(id: past.id, trigger: .alertTap)
        await store.replanAfterAlert(id: anchored.id, trigger: .alertTap)
        await store.replanAfterAlert(id: UUID(), trigger: .alertTap)
        XCTAssertEqual(store.drvLiveLookupCount, 2)
        XCTAssertNil(store.replanOutcomes[past.id])
        XCTAssertNil(store.replanOutcomes[anchored.id])

        // The hook the store set on the notification manager starts the same check.
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

        // A tap with the same answer: the comparison is still with the first plan, so the lines are the same.
        clock.now = clock.now.addingTimeInterval(30)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        let second = try XCTUnwrap(store.replanOutcomes[event.id])
        XCTAssertEqual(second.referenceDeparture, event.departureDate)
        XCTAssertEqual(second.referenceTravel, 18 * 60)
        XCTAssertEqual(second.kind, .earlier)
        XCTAssertEqual(second.minutes, 13)
        XCTAssertEqual(Replan.headline(for: second), Replan.headline(for: first))
        XCTAssertEqual(Replan.reason(for: second), Replan.reason(for: first))

        // Traffic clears after the alert fired: a later departure than the stored one changes nothing, the lines stay.
        clock.now = clock.now.addingTimeInterval(30)
        store.drvLiveLookupOverride = F.answering(19 * 60)
        await store.replanAfterAlert(id: event.id, trigger: .alertTap)
        XCTAssertEqual(store.replanOutcomes[event.id], second)
        XCTAssertEqual(store.events.first?.travelSeconds, 31 * 60)

        // The same answer on an app-open pass of an event whose alert has not fired: stored pair back, lines gone.
        clock.now = clock.now.addingTimeInterval(400)
        await store.refreshUpcomingEstimates()
        XCTAssertEqual(store.events.first?.travelSeconds, 19 * 60)
        XCTAssertNil(store.replanOutcomes[event.id])
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

        // Two lookups of one event overlap and the older one finishes last: it writes nothing.
        let other = F.firedEvent(now: clock.now)
        let ordered = setUpStore(clock: clock, events: [other])
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        ordered.drvLiveLookupOverride = { _, _, _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { gate = $0 }
                return (seconds: 40 * 60, noTrafficSeconds: nil)
            }
            return (seconds: 31 * 60, noTrafficSeconds: nil)
        }
        let older = Task { await ordered.replanAfterAlert(id: other.id, trigger: .alertTap) }
        await F.wait { gate != nil }
        clock.now = clock.now.addingTimeInterval(1)
        let newerStart = clock.now
        await ordered.replanAfterAlert(id: other.id, trigger: .alertTap)
        gate?.resume()
        await older.value
        XCTAssertEqual(ordered.events.first?.travelSeconds, 31 * 60)
        let outcome = try XCTUnwrap(ordered.replanOutcomes[other.id])
        XCTAssertEqual(outcome.liveTravel, 31 * 60)
        XCTAssertEqual(outcome.checkedAt, newerStart)
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
        XCTAssertNil(store.replanDraftTask)
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
}
