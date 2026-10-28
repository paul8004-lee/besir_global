import XCTest
@testable import besir

/// AC-APPLECAL-010: a real EventKit store creates, reads, updates and removes an event. It runs only
/// when the app already has full calendar access (on the simulator:
/// `xcrun simctl privacy <device> grant calendar com.iseongmin.besir.global`); otherwise it is skipped,
/// never failed, and never asks for access itself.
@MainActor
final class EventKitRoundTripTests: XCTestCase {
    func testAC_APPLECAL_010_RealEventKitRoundTrip() throws {
        let backend: CalendarBackend = EventKitBackend()
        try XCTSkipUnless(backend.access() == .full, "calendar access is not granted to the test host")

        let calendar = Calendar.current
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())))
        let start = try XCTUnwrap(calendar.date(byAdding: .hour, value: 10, to: tomorrow))
        let end = try XCTUnwrap(calendar.date(byAdding: .hour, value: 11, to: tomorrow))
        let title = "besir test \(UUID().uuidString)"

        let draft = CalendarDraft(title: title, start: start, end: end, placeName: "Test Place",
                                  address: "1 Test St", latitude: 37.77, longitude: -122.41)
        let id = try backend.create(draft)
        addTeardownBlock { @MainActor in try? backend.remove(id: id) }

        let found = try backend.entries(from: tomorrow, to: end.addingTimeInterval(3600))
        let created = try XCTUnwrap(found.first { $0.id == id }, "the created event was not found")
        XCTAssertEqual(created.title, title)
        XCTAssertTrue(created.location?.contains("Test Place") ?? false)

        var changed = draft
        changed.title = title + " updated"
        changed.placeName = nil
        changed.address = nil
        changed.latitude = nil
        changed.longitude = nil
        XCTAssertTrue(try backend.update(id: id, changed))
        let afterUpdate = try backend.entries(from: tomorrow, to: end.addingTimeInterval(3600))
        let updated = try XCTUnwrap(afterUpdate.first { $0.id == id }, "the updated event was not found")
        XCTAssertEqual(updated.title, title + " updated")
        XCTAssertTrue(updated.location?.isEmpty ?? true, "the place should be cleared, got \(updated.location ?? "nil")")

        try backend.remove(id: id)
        let afterRemove = try backend.entries(from: tomorrow, to: end.addingTimeInterval(3600))
        XCTAssertNil(afterRemove.first { $0.id == id })
        XCTAssertFalse(try backend.update(id: id, changed), "an update of a removed event must report that it is gone")
    }
}
