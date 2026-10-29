import Foundation

/// One calendar event besir wrote: its identifier and the draft it was written from.
struct CalendarLink: Codable, Equatable {
    var eventId: String
    var signature: CalendarDraft
}

/// `calendar-links.json`, next to `activities.json`. It is the only list of calendar events besir may
/// update or remove, and it records which activities existed at the first run.
struct CalendarLinkFile: Codable, Equatable {
    enum Loaded: Equatable {
        case absent
        case unreadable
        case file(CalendarLinkFile)
    }

    var version = 1
    /// Key: the activity id (`uuidString`).
    var links: [String: CalendarLink] = [:]
    /// Activity ids that existed when the real mirror first ran. They are never mirrored.
    // @MX:NOTE: the baseline keeps the first launch from writing every existing future activity, up to a
    // 118-occurrence series, into a real calendar.
    var baseline: Set<String> = []

    static func load(_ url: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CalendarLinkFile.self, from: data) else { return .unreadable }
        return .file(file)
    }

    @discardableResult
    func save(to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

enum CalendarPlanner {
    struct Create: Equatable {
        let activityId: String
        let draft: CalendarDraft
    }

    struct Update: Equatable {
        let activityId: String
        let eventId: String
        let draft: CalendarDraft
    }

    struct Remove: Equatable {
        let activityId: String
        let eventId: String
    }

    struct Plan: Equatable {
        var removes: [Remove] = []
        var updates: [Update] = []
        var creates: [Create] = []
        var isEmpty: Bool { removes.isEmpty && updates.isEmpty && creates.isEmpty }
    }

    /// Decides which calendar events to remove, update and create. It reads nothing but its arguments and
    /// names only activity ids from `activities` and event ids from `file.links`. `retains` is asked about the key of a
    /// link whose activity is not in `activities`; a link it keeps is neither removed nor updated.
    // @MX:ANCHOR: called by the mirror and by every planner test; the invariant is that an event besir
    // did not create (no link) is never named.
    static func plan(activities: [ActivityBlock], file: CalendarLinkFile, now: Date,
                     calendar: Calendar = .current, retains: (String) -> Bool = { _ in false }) -> Plan {
        let startOfToday = calendar.startOfDay(for: now)
        var plan = Plan()
        var seen = Set<String>()

        for activity in activities {
            let key = activity.id.uuidString
            seen.insert(key)
            if file.baseline.contains(key) { continue }
            let link = file.links[key]
            if !activity.wantsCalendarSync {
                if let link { plan.removes.append(Remove(activityId: key, eventId: link.eventId)) }
                continue
            }
            let draft = CalendarDraft(activity)
            if let link {
                if draft != link.signature {
                    plan.updates.append(Update(activityId: key, eventId: link.eventId, draft: draft))
                }
            } else if activity.endDate >= startOfToday {
                plan.creates.append(Create(activityId: key, draft: draft))
            }
        }

        for (key, link) in file.links where !seen.contains(key) && !retains(key) {
            plan.removes.append(Remove(activityId: key, eventId: link.eventId))
        }

        // A total order, so two plans from the same input compare equal.
        plan.removes.sort { ($0.eventId, $0.activityId) < ($1.eventId, $1.activityId) }
        plan.updates.sort { ($0.draft.start, $0.activityId) < ($1.draft.start, $1.activityId) }
        plan.creates.sort { ($0.draft.start, $0.activityId) < ($1.draft.start, $1.activityId) }
        return plan
    }
}
