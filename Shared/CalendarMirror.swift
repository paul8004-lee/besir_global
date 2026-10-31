import Foundation

/// What Settings shows about the calendar connection.
enum CalendarStatus: Equatable {
    case idle, ok, denied, restricted, noCalendar, linksUnreadable, failed
}

enum CalendarReadError: Error, Equatable {
    case unavailable
    case accessDenied
}

/// What `Store` talks to. `NoCalendarMirror` until the app attaches the real mirror.
@MainActor
protocol CalendarMirroring: AnyObject {
    func reconcile(_ activities: [ActivityBlock])
    func entries(on day: Date, calendar: Calendar) async throws -> [CalendarEntry]
}

@MainActor
final class NoCalendarMirror: CalendarMirroring {
    func reconcile(_ activities: [ActivityBlock]) {}
    func entries(on day: Date, calendar: Calendar) async throws -> [CalendarEntry] {
        throw CalendarReadError.unavailable
    }
}

/// The fixed lines Settings shows. Pure, so a test can pin every text.
enum CalendarStatusText {
    /// nil when the switch is off or the status is idle or ok.
    static func warning(_ status: CalendarStatus, switchOn: Bool) -> String? {
        guard switchOn else { return nil }
        switch status {
        case .idle, .ok:
            return nil
        case .denied:
            return "Calendar access is off or limited. Allow full access in the Settings app to save events to your calendar."
        case .restricted:
            return "Calendar access is restricted on this device."
        case .noCalendar:
            return "No calendar on this device can accept new events."
        case .linksUnreadable:
            return "besir could not read its calendar link file, so no events are saved to your calendar."
        case .failed:
            return "Some events could not be saved to your calendar."
        }
    }

    /// The Debug read button's error line.
    static func debugLine(for error: Error) -> String {
        switch error as? CalendarReadError {
        case .accessDenied: return "Calendar read failed: access denied"
        case .unavailable: return "Calendar read failed: unavailable"
        case nil: return "Calendar read failed: unknown error"
        }
    }
}

/// Keeps the Apple calendar in step with the activity list. It diffs the list against the link file
/// (`CalendarPlanner`), asks for access at most once per app run, and runs one pass at a time.
@MainActor
final class AppleCalendarMirror: CalendarMirroring {
    private let backend: CalendarBackend
    private let linksURL: URL
    private let now: () -> Date

    /// Called only when the status value changes.
    var onStatus: (CalendarStatus) -> Void = { _ in }
    private(set) var status: CalendarStatus = .idle
    private(set) var passCount = 0

    private var pending: [ActivityBlock]?
    /// True from the moment `reconcile` starts a pass until the last queued pass ends.
    private(set) var running = false
    /// The access request is made at most once per app run, across the write pass and the read.
    private var requested = false
    /// Whether the link of an activity that is not in the list a pass is given must stay. `Store.attachCalendar` sets it.
    // @MX:NOTE: the list a pass gets holds only the occurrences of a repeat inside the mirror window, so a live
    // occurrence outside it looks like a deleted activity. `retains` is how the store says "still alive, keep the
    // event" (and "keep everything" while the series file is unreadable); without it the planner would remove the
    // event of every occurrence that leaves the window.
    var retains: (String) -> Bool = { _ in false }

    static var defaultLinksURL: URL {
        AppConfig.supportDirectory.appendingPathComponent("calendar-links.json")
    }

    init(backend: CalendarBackend, linksURL: URL, now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.linksURL = linksURL
        self.now = now
    }

    /// Writes the link file once, with the ids of the activities that exist now as baseline and no links.
    /// Does nothing when the file already exists.
    func captureBaseline(_ activities: [ActivityBlock]) {
        guard case .absent = CalendarLinkFile.load(linksURL) else { return }
        var file = CalendarLinkFile()
        file.baseline = Set(activities.map { $0.id.uuidString })
        file.save(to: linksURL)
    }

    // @MX:WARN: `running` is set before the first await. Removing that re-opens the race in which two
    // quick saves start two passes and write every event twice. `pass` suspends after every operation,
    // so `running` is what keeps a second pass out.
    func reconcile(_ activities: [ActivityBlock]) {
        pending = activities
        if running { return }
        running = true
        Task { @MainActor in
            while let next = pending {
                pending = nil
                await pass(next)
            }
            running = false
        }
    }

    private func publish(_ new: CalendarStatus) {
        guard new != status else { return }
        status = new
        onStatus(new)
    }

    private func pass(_ list: [ActivityBlock]) async {
        passCount += 1
        var file: CalendarLinkFile
        switch CalendarLinkFile.load(linksURL) {
        case .unreadable:
            publish(.linksUnreadable)
            return
        case .absent:
            // The baseline write at attach must have failed; a baseline is never guessed.
            publish(.failed)
            return
        case .file(let loaded):
            file = loaded
        }

        let plan = CalendarPlanner.plan(activities: list, file: file, now: now(), retains: retains)

        // Baseline ids of activities that are gone are dropped and saved here, before the access gate,
        // so every exit below has already pruned.
        let pruned = file.baseline.intersection(Set(list.map { $0.id.uuidString }))
        if pruned != file.baseline {
            file.baseline = pruned
            file.save(to: linksURL)
        }

        if plan.isEmpty {
            // No request for an empty plan. The file loaded and nothing is left to write, so these
            // statuses have lost their cause; a refused-permission status clears once access is full.
            if status == .linksUnreadable || status == .failed || status == .noCalendar { publish(.idle) }
            if backend.access() == .full && (status == .denied || status == .restricted) { publish(.idle) }
            return
        }

        var access = backend.access()
        if access == .notDetermined && !requested {
            requested = true
            access = await backend.requestAccess()
        }
        switch access {
        case .full:
            break
        case .writeOnly, .denied, .notDetermined:
            // A write-only store cannot find an event it wrote, so an update would create a duplicate.
            publish(.denied)
            return
        case .restricted:
            publish(.restricted)
            return
        }

        do {
            for remove in plan.removes {
                try backend.remove(id: remove.eventId)
                file.links[remove.activityId] = nil
                try persist(file)
                await Task.yield()
            }
            for update in plan.updates {
                if try backend.update(id: update.eventId, update.draft) {
                    file.links[update.activityId] = CalendarLink(eventId: update.eventId, signature: update.draft)
                } else {
                    // The event vanished; write a new one and replace the link.
                    let eventId = try backend.create(update.draft)
                    file.links[update.activityId] = CalendarLink(eventId: eventId, signature: update.draft)
                }
                try persist(file)
                await Task.yield()
            }
            for create in plan.creates {
                let eventId = try backend.create(create.draft)
                file.links[create.activityId] = CalendarLink(eventId: eventId, signature: create.draft)
                try persist(file)
                await Task.yield()
            }
        } catch CalendarBackendError.noCalendar {
            publish(.noCalendar)
            return
        } catch {
            publish(.failed)
            return
        }
        publish(.ok)
    }

    // @MX:NOTE: each success is saved before the next operation. A crash after a create must not lose
    // its link, or the next pass would write the same event again. The yield comes after the save, so the
    // link is on disk whenever other work runs.
    private func persist(_ file: CalendarLinkFile) throws {
        guard file.save(to: linksURL) else { throw CalendarBackendError.failed("link file not saved") }
    }

    func entries(on day: Date, calendar: Calendar) async throws -> [CalendarEntry] {
        var access = backend.access()
        if access == .notDetermined && !requested {
            requested = true
            access = await backend.requestAccess()
        }
        guard access == .full else { throw CalendarReadError.accessDenied }

        let from = calendar.startOfDay(for: day)
        guard let to = calendar.date(byAdding: .day, value: 1, to: from) else { throw CalendarReadError.unavailable }
        var result = try backend.entries(from: from, to: to)

        var besirIds = Set<String>()
        if case .file(let file) = CalendarLinkFile.load(linksURL) {
            besirIds = Set(file.links.values.map { $0.eventId })
        }
        for index in result.indices { result[index].isFromBesir = besirIds.contains(result[index].id) }
        result.sort { ($0.start, $0.title) < ($1.start, $1.title) }
        return result
    }
}
