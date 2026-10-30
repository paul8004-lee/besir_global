import XCTest
@testable import besir

/// Card t94: a leg drag of a non-repeating activity across midnight changes only the dragged edge of the activity
/// (the start for an outbound leg, the end for a return leg), as it does within one day.
@MainActor
final class OneOffLegEdgeTests: XCTestCase {
    private var savedZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Seoul")!
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
        super.tearDown()
    }

    private var cal: Calendar { Calendar.current }

    private func at(_ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }

    private let home = Place(name: "Home", address: "1 Home St", latitude: 37.5, longitude: 127.0)
    private let office = Place(name: "Office", address: "2 Work Ave", latitude: 37.6, longitude: 127.1)

    private func fixtureStore() -> Store {
        let store = EmptyStore.make()
        let clock = at(11, 2, 8)
        store.replanNow = { clock }
        return store
    }

    /// The walk's shape: a one-off activity 03:40 to 06:10 on Nov 11 with a linked 10-minute outbound leg before it.
    private func outboundCase() -> (Store, ActivityBlock, ScheduledEvent) {
        let store = fixtureStore()
        let activity = ActivityBlock(title: "Standup", location: office, startDate: at(11, 11, 3, 40),
                                     endDate: at(11, 11, 6, 10))
        store.activities.append(activity)
        var leg = ScheduledEvent(title: "Drive", origin: home, destination: office, arrivalDate: at(11, 11, 3, 40),
                                 mode: .car, bufferMinutes: 0, notifyLeadMinutes: 10)
        leg.departureDate = at(11, 11, 3, 30)
        leg.anchor = .arrival
        leg.travelSeconds = 600
        leg.linkedActivityId = activity.id
        store.events.append(leg)
        return (store, activity, leg)
    }

    /// A return leg dragged down across midnight moves only the end of a one-off activity.
    func testONEOFF_ReturnLegAcrossMidnightMovesOnlyTheEnd() throws {
        let store = fixtureStore()
        let activity = ActivityBlock(title: "Dinner", location: office, startDate: at(11, 11, 22),
                                     endDate: at(11, 11, 23, 30))
        store.activities.append(activity)
        var leg = ScheduledEvent(title: "Drive (return)", origin: office, destination: home,
                                 arrivalDate: at(11, 11, 23, 45), mode: .car, bufferMinutes: 0, notifyLeadMinutes: 10)
        leg.departureDate = at(11, 11, 23, 30)
        leg.anchor = .departure
        leg.travelSeconds = 900
        leg.linkedActivityId = activity.id
        store.events.append(leg)
        store.adjustTravelLeg(leg, byMinutes: 60, wholeSeries: false, pressedOn: at(11, 11, 12))
        let moved = try XCTUnwrap(store.activity(id: activity.id))
        XCTAssertEqual(moved.startDate, at(11, 11, 22))
        XCTAssertEqual(moved.endDate, at(11, 12, 0, 30))
        XCTAssertEqual(store.events.first { $0.id == leg.id }?.departureDate, at(11, 12, 0, 30))
    }

    /// The stored result of the t92 walk (activity Nov 10 23:10 to Nov 11 01:40, leg 23:00 to 23:10) is what the drag
    /// of the activity block gives on the same data: the length is kept and the linked leg follows. A leg drag does not.
    func testONEOFF_TheWalkResultIsTheActivityBlockDrag() throws {
        let (store, activity, leg) = outboundCase()
        store.moveActivity(activity, byMinutes: -270, wholeSeries: false)
        let moved = try XCTUnwrap(store.activity(id: activity.id))
        XCTAssertEqual(moved.startDate, at(11, 10, 23, 10))
        XCTAssertEqual(moved.endDate, at(11, 11, 1, 40))
        let followed = try XCTUnwrap(store.events.first { $0.id == leg.id })
        XCTAssertEqual(followed.departureDate, at(11, 10, 23, 0))
        XCTAssertEqual(followed.arrivalDate, at(11, 10, 23, 10))
    }

    /// The drag of the walk: 4 h 30 min up, across midnight, with and without the pressed day the view passes.
    func testONEOFF_OutboundLegAcrossMidnightMovesOnlyTheStart() throws {
        for pressedOn in [Optional(at(11, 11, 12)), nil] {
            let (store, activity, leg) = outboundCase()
            store.adjustTravelLeg(leg, byMinutes: -270, wholeSeries: false, pressedOn: pressedOn)
            let moved = try XCTUnwrap(store.activity(id: activity.id))
            XCTAssertEqual(moved.startDate, at(11, 10, 23, 10), "start, pressed \(String(describing: pressedOn))")
            XCTAssertEqual(moved.endDate, at(11, 11, 6, 10), "end stays, pressed \(String(describing: pressedOn))")
            XCTAssertEqual(store.events.first { $0.id == leg.id }?.arrivalDate, at(11, 10, 23, 10))
        }
    }
}
