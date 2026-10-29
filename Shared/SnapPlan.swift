import Foundation

/// The fixed lines of the camera snap (SPEC-CAMSNAP-001 section 1.5). Nothing from the server or the model is ever shown; this
/// is the only place the strings exist, except the three the share flow already owns (`SharedLine`), which are referenced.
enum SnapLine {
    static let cameraOff = "Camera access is off. Allow it in Settings."
    static let unreadable = "The photo couldn't be read."
    static let offline = "Couldn't reach the image reader. Check your connection and try again."
    static let busy = "The image reader is busy. Try again in a minute."
    static let other = "Couldn't read the photo. Try again."
    static let unclear = "Couldn't tell what that is."
    static let noLocation = "The place can't be found without your location."
    static let noMatch = "No matching place was found nearby."
    static let noTime = "No time is left today for a meal."
    static let assistantBusy = "The assistant is busy. Try again in a moment."
    static let travelTitle = "How will you travel?"

    static func line(for failure: VisionFailure) -> String {
        switch failure {
        case .notSetUp: return SharedLine.notSetUp
        case .imageUnreadable: return unreadable
        case .tokenRejected: return SharedLine.tokenRejected
        case .busy: return busy
        case .offline: return offline
        case .other: return other
        }
    }
}

/// What a reading leads to, decided from the validated kind and confidence alone.
enum SnapDecision: Equatable {
    /// End with this fixed line; no agent call.
    case line(String)
    /// The poster hand-off, with the share fields built from the clue.
    case poster(VisionFields)
    /// One nearby lookup with this query.
    case lookup(String)
}

/// The pure rules of the camera snap: constants, the lookup query, the routing by kind and the suggested meal time.
/// Dates, zone and values come in as arguments, so a test needs no clock, no camera and no network.
enum SnapPlan {
    static let radiusMeters = 500
    static let candidateLimit = 3
    static let queryMax = 60
    static let queryMin = 2
    /// `text` is added to a query only when there is no name and it has at most this many characters.
    static let textMax = 24
    /// A reading under this is unclear; the floor itself proceeds.
    static let confidenceFloor = 0.5
    static let mealMinutes = 45
    static let markMinutes = 5
    static let leadMinutes = 10
    /// The shortest meal the message allows. It is the message's rule, not the app's: the day-plan tools take any stop.
    static let mealFloorMinutes = 20

    /// The one existing sanitizer, then every run of whitespace collapsed to one space, then trimmed; empty is nil.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = AgentToolbox.sanitized(text).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The search text for one lookup: the cleaned sign name, else the cleaned place type; the cleaned `text` follows only when
    /// there is no name and it is short. `text` alone gives none. Cut to 60 characters; fewer than 2 gives none.
    static func query(for clue: SnapClue) -> String? {
        let name = clean(clue.name)
        let type = clean(clue.placeType)
        guard var query = name ?? type else { return nil }
        if name == nil, let text = clean(clue.text), text.count <= textMax { query += " " + text }
        query = String(query.prefix(queryMax)).trimmingCharacters(in: .whitespaces)
        return query.count >= queryMin ? query : nil
    }

    /// `unknown` or a confidence under the floor is unclear. A poster needs at least one of title, time and venue and no
    /// position. A place needs a query first (no query wins over no fix), then a real fix.
    static func decide(_ clue: SnapClue, hasFix: Bool) -> SnapDecision {
        guard clue.kind != .unknown, clue.confidence >= confidenceFloor else { return .line(SnapLine.unclear) }
        switch clue.kind {
        case .eventPoster:
            let fields = VisionFields(title: clue.title, time: clue.time, place: clue.name, confidence: clue.confidence)
            return fields.isEmpty ? .line(SharedLine.nothingFound) : .poster(fields)
        case .foodPlace, .otherPlace:
            guard let query = query(for: clue) else { return .line(SnapLine.unclear) }
            return hasFix ? .lookup(query) : .line(SnapLine.noLocation)
        case .unknown:
            return .line(SnapLine.unclear)
        }
    }

    /// The meal's start S, the first 5-minute mark at least 10 minutes after the current minute (seconds dropped), and its
    /// default end S + 45 minutes. Nil when S is not on the same local day as `now`; the end may fall after midnight.
    static func suggestedMeal(now: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let minute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        guard let lead = calendar.date(byAdding: .minute, value: leadMinutes, to: minute) else { return nil }
        let past = calendar.component(.minute, from: lead) % markMinutes
        guard let start = calendar.date(byAdding: .minute, value: past == 0 ? 0 : markMinutes - past, to: lead),
              calendar.isDate(start, inSameDayAs: now),
              let end = calendar.date(byAdding: .minute, value: mealMinutes, to: start) else { return nil }
        return (start, end)
    }
}

/// The rules of the camera circle on the root screen.
enum SnapEntry {
    /// The circle is drawn only with the assistant, while the Plan my day dialog is closed and no share is being read.
    static func isShown(hasAI: Bool, choosingMode: Bool, isReading: Bool) -> Bool {
        hasAI && !choosingMode && !isReading
    }

    enum TapAction: Equatable {
        case openCamera
        /// The session cannot take a message now: only the chat opens.
        case openChatOnly
    }

    static func tapAction(canSend: Bool) -> TapAction {
        canSend ? .openCamera : .openChatOnly
    }

    /// The automatic share pass hands a message to the chat only with a free session and a closed camera cover.
    static func shareMayHand(canSend: Bool, coverOpen: Bool) -> Bool {
        canSend && !coverOpen
    }
}
