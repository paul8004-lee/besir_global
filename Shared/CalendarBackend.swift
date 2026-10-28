import Foundation

/// What the app may do with the Apple calendar right now. Only `.full` lets besir write or read.
enum CalendarAccess: Equatable {
    case notDetermined, full, writeOnly, denied, restricted
}

/// The part of an activity that becomes a calendar event. Also stored in the link file as the
/// signature, so "did this activity change" is one equality check.
struct CalendarDraft: Codable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var placeName: String?
    var address: String?
    var latitude: Double?
    var longitude: Double?
}

extension CalendarDraft {
    init(_ activity: ActivityBlock) {
        self.init(title: activity.title,
                  start: activity.startDate,
                  end: activity.endDate,
                  placeName: activity.location?.name,
                  address: activity.location?.address,
                  latitude: activity.location?.latitude,
                  longitude: activity.location?.longitude)
    }
}

/// One event read back from the calendar.
struct CalendarEntry: Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var calendarName: String
    /// The backend returns false; the mirror sets it from the link file.
    var isFromBesir: Bool
}

enum CalendarBackendError: Error, Equatable {
    /// There is no default calendar that accepts new events.
    case noCalendar
    case failed(String)
}

/// The only door to the calendar. `EventKitBackend` is the real one; tests use a fake.
@MainActor
protocol CalendarBackend: AnyObject {
    func access() -> CalendarAccess
    /// Asks the system for full access and returns the state afterwards.
    func requestAccess() async -> CalendarAccess
    /// Saves and commits one event; returns its identifier.
    func create(_ draft: CalendarDraft) throws -> String
    /// Returns false when the event no longer exists.
    func update(id: String, _ draft: CalendarDraft) throws -> Bool
    /// An event that is already gone is not an error.
    func remove(id: String) throws
    func entries(from: Date, to: Date) throws -> [CalendarEntry]
}
