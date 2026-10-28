#if os(iOS)
import EventKit
import CoreLocation

/// The real calendar: the only file that knows EventKit. Every write is committed at once, so the
/// returned identifier is final and a crash cannot leave a half-saved event.
@MainActor
final class EventKitBackend: CalendarBackend {
    private let store = EKEventStore()

    func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .full
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess() async -> CalendarAccess {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            return .denied
        }
        return access()
    }

    func create(_ draft: CalendarDraft) throws -> String {
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarBackendError.noCalendar }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        fill(event, from: draft)
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarBackendError.failed(error.localizedDescription)
        }
        guard let identifier = event.eventIdentifier else { throw CalendarBackendError.failed("no identifier") }
        return identifier
    }

    func update(id: String, _ draft: CalendarDraft) throws -> Bool {
        guard let event = store.event(withIdentifier: id) else { return false }
        fill(event, from: draft)
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarBackendError.failed(error.localizedDescription)
        }
        return true
    }

    func remove(id: String) throws {
        guard let event = store.event(withIdentifier: id) else { return }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarBackendError.failed(error.localizedDescription)
        }
    }

    func entries(from: Date, to: Date) throws -> [CalendarEntry] {
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { event in
                CalendarEntry(id: event.eventIdentifier ?? "", title: event.title ?? "",
                              start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                              location: event.location, calendarName: event.calendar?.title ?? "",
                              isFromBesir: false)
            }
    }

    /// Title, times and place only: no alarm, no note, no URL.
    /// The place label is the name, else the address; the text adds the address after the name when both exist.
    private func fill(_ event: EKEvent, from draft: CalendarDraft) {
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end

        let name = draft.placeName.flatMap { $0.isEmpty ? nil : $0 }
        let address = draft.address.flatMap { $0.isEmpty ? nil : $0 }
        guard let label = name ?? address else {
            event.structuredLocation = nil
            event.location = nil
            return
        }
        let structured = EKStructuredLocation(title: label)
        if let latitude = draft.latitude, let longitude = draft.longitude {
            structured.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        }
        event.structuredLocation = structured
        if let name, let address {
            event.location = "\(name), \(address)"
        } else {
            event.location = label
        }
    }
}
#endif
