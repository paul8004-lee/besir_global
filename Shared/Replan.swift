import Foundation

// Live replan (SPEC-REPLAN-001, card t18): the types and the pure rules. The store owns the triggers and the state.

/// What started a lookup. `.background` is the baseline app-refresh task: it is not live and makes no outcome.
enum ReplanTrigger: Equatable {
    case appOpen, alertTap, background
}

enum ReplanKind: Equatable {
    case earlier, later, late, unchanged
}

/// The inputs an outcome was made from. An outcome is trusted only while the event still has these.
struct ReplanInputs: Equatable {
    let arrivalDate: Date
    let mode: TransportMode
    let bufferMinutes: Int
    let origin: Place?
    let destination: Place
    let anchor: ScheduleAnchor?

    init(event: ScheduledEvent) {
        arrivalDate = event.arrivalDate
        mode = event.mode
        bufferMinutes = event.bufferMinutes
        origin = event.origin
        destination = event.destination
        anchor = event.anchor
    }
}

/// The result of one live lookup of one event. It lives in memory only (never in events.json, never synced).
struct ReplanOutcome: Equatable {
    let eventID: UUID
    let trigger: ReplanTrigger
    /// When the lookup started.
    let checkedAt: Date
    let inputs: ReplanInputs
    /// The departure and travel time of the cycle's first plan; later triggers compare the live time with these.
    let referenceDeparture: Date
    let referenceTravel: TimeInterval
    let liveTravel: TimeInterval
    /// The route time without traffic; known only for a live car lookup that returned it.
    let noTrafficTravel: TimeInterval?
    let newDeparture: Date
    let kind: ReplanKind
    /// earlier and later: the whole minutes of the difference; late: the minutes late; unchanged: 0.
    let minutes: Int
    /// Late only: the time the user would arrive if leaving at the moment of the check.
    let arrivalEstimate: Date?
    /// Late only: the message draft (the fixed text first, a checked Muse Spark text when one arrives).
    var draft: String?
    /// True for a later live departure found after the alert fired (SPEC-REPLAN-002): shown, never stored.
    var afterAlert: Bool = false
}

enum Replan {
    /// A change is announced from this many seconds of difference (2 minutes).
    static let changeThreshold: TimeInterval = 120
    /// A car lookup has to exceed the time without traffic by this much for the reason to name traffic.
    static let trafficThreshold: TimeInterval = 60
    /// One event gets at most one live lookup per this many seconds on app open.
    static let debounce: TimeInterval = 300
    /// The late lines and the draft are shown this long after the check.
    static let lateLinesLifetime: TimeInterval = 15 * 60
    /// The after-alert line (a live departure later than the stored one) is shown this long after the check.
    static let afterAlertLinesLifetime: TimeInterval = 15 * 60
    /// An app-open pass checks at most this many events beyond the baseline window.
    static let maxPostAlertEvents = 5
    static let draftMaxLength = 280
    static let draftTitleLength = 40

    // MARK: - Classification

    /// The late minutes: whole minutes, rounded up, of `now + live travel - arrival`; 0 when not late. One rule for
    /// `classify` and for the card (REQ-REPLAN-308).
    static func lateMinutes(now: Date, liveTravel: TimeInterval, arrival: Date) -> Int {
        let over = now.addingTimeInterval(liveTravel).timeIntervalSince(arrival)
        return over > 0 ? Int((over / 60).rounded(.up)) : 0
    }

    /// REQ-REPLAN-004. `referenceDeparture` and `referenceTravel` are the first plan of the cycle.
    static func classify(eventID: UUID, trigger: ReplanTrigger, checkedAt: Date, inputs: ReplanInputs,
                         referenceDeparture: Date, referenceTravel: TimeInterval,
                         liveTravel: TimeInterval, noTrafficTravel: TimeInterval?, now: Date) -> ReplanOutcome {
        let newDeparture = Store.departureTime(arrival: inputs.arrivalDate, travelSeconds: liveTravel,
                                               bufferMinutes: inputs.bufferMinutes)
        var kind = ReplanKind.unchanged
        var minutes = 0
        var estimate: Date?
        if (inputs.anchor ?? .arrival) == .arrival {
            let lateBy = lateMinutes(now: now, liveTravel: liveTravel, arrival: inputs.arrivalDate)
            let delta = referenceDeparture.timeIntervalSince(newDeparture)
            if lateBy >= 1 {
                kind = .late
                minutes = lateBy
                estimate = now.addingTimeInterval(liveTravel)
            } else if delta >= changeThreshold {
                kind = .earlier
                minutes = roundedMinutes(fromSeconds: delta)
            } else if delta <= -changeThreshold {
                kind = .later
                minutes = roundedMinutes(fromSeconds: -delta)
            }
        }
        return ReplanOutcome(eventID: eventID, trigger: trigger, checkedAt: checkedAt, inputs: inputs,
                             referenceDeparture: referenceDeparture, referenceTravel: referenceTravel,
                             liveTravel: liveTravel, noTrafficTravel: noTrafficTravel,
                             newDeparture: newDeparture, kind: kind, minutes: minutes,
                             arrivalEstimate: estimate, draft: nil)
    }

    /// The outcome of a check made after the alert fired when the live departure is later than the stored one (SPEC-REPLAN-002).
    /// Nothing is stored for it; it compares with the stored pair. nil for a late outcome and for less than `changeThreshold`.
    static func afterAlert(_ outcome: ReplanOutcome, storedDeparture: Date, storedTravel: TimeInterval) -> ReplanOutcome? {
        let difference = outcome.newDeparture.timeIntervalSince(storedDeparture)
        guard outcome.kind != .late, difference >= changeThreshold else { return nil }
        return ReplanOutcome(eventID: outcome.eventID, trigger: outcome.trigger, checkedAt: outcome.checkedAt, inputs: outcome.inputs,
                             referenceDeparture: storedDeparture, referenceTravel: storedTravel, liveTravel: outcome.liveTravel,
                             noTrafficTravel: outcome.noTrafficTravel, newDeparture: outcome.newDeparture, kind: .later,
                             minutes: roundedMinutes(fromSeconds: difference), arrivalEstimate: nil, draft: nil, afterAlert: true)
    }

    /// Whether the departure card shows the passed-departure warning and tint: the departure is behind `now` and no
    /// after-alert line says the trip still fits (REQ-REPLAN-106).
    static func showsPassed(departure: Date, now: Date, afterAlertLine: Bool) -> Bool {
        departure < now && !afterAlertLine
    }

    /// The pair a new check compares with: the first plan of the event's cycle (REQ-REPLAN-004). It is the pair of the
    /// event's outcome while that outcome was made from the same inputs and its arrival is ahead, else the stored pair.
    static func referencePair(existing: ReplanOutcome?, inputs: ReplanInputs, now: Date,
                              storedDeparture: Date, storedTravel: TimeInterval) -> (departure: Date, travel: TimeInterval) {
        if let existing, existing.inputs == inputs, existing.inputs.arrivalDate > now {
            return (existing.referenceDeparture, existing.referenceTravel)
        }
        return (storedDeparture, storedTravel)
    }

    // MARK: - Text

    /// `h:mm a`, en_US, as every clock time of the app.
    static func clockText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        f.timeZone = timeZone
        return f.string(from: date)
    }

    static func headline(for outcome: ReplanOutcome, timeZone: TimeZone = .current) -> String? {
        switch outcome.kind {
        case .earlier:
            return "Leave by \(clockText(outcome.newDeparture, timeZone: timeZone)), \(outcome.minutes) min earlier"
        case .later:
            return "Leave by \(clockText(outcome.newDeparture, timeZone: timeZone)), \(outcome.minutes) min later"
        case .late:
            let arrival = outcome.arrivalEstimate ?? outcome.newDeparture
            return "Leave now to arrive about \(clockText(arrival, timeZone: timeZone)), \(outcome.minutes) min late"
        case .unchanged:
            return nil
        }
    }

    /// The reason in facts the lookup returned: it names traffic only for a car lookup that shows it, and no other cause.
    static func reason(for outcome: ReplanOutcome) -> String {
        if outcome.inputs.mode == .car, let free = outcome.noTrafficTravel,
           outcome.liveTravel - free >= trafficThreshold {
            return "Traffic adds \(roundedMinutes(fromSeconds: outcome.liveTravel - free)) min to the "
                + "\(roundedMinutes(fromSeconds: free)) min it takes without traffic."
        }
        return "Travel time is now \(roundedMinutes(fromSeconds: outcome.liveTravel)) min, "
            + "was \(roundedMinutes(fromSeconds: outcome.referenceTravel)) min."
    }

    /// What the departure card shows for an event (REQ-REPLAN-012); nil shows nothing.
    static func displayLines(for outcome: ReplanOutcome?, event: ScheduledEvent, now: Date,
                             timeZone: TimeZone = .current)
        -> (headline: String, reason: String, draft: String?, kind: ReplanKind, afterAlert: Bool)? {
        guard let outcome, outcome.kind != .unchanged,
              event.arrivalDate > now,
              outcome.inputs.arrivalDate == event.arrivalDate, outcome.inputs.mode == event.mode,
              let headline = headline(for: outcome, timeZone: timeZone) else { return nil }
        switch outcome.kind {
        case .earlier, .later:
            guard let departure = event.departureDate else { return nil }
            if outcome.afterAlert {
                // The stored departure is the one the check compared with; the live one is ahead and the reading is young.
                guard abs(departure.timeIntervalSince(outcome.referenceDeparture)) < 1,
                      now < outcome.newDeparture,
                      now.timeIntervalSince(outcome.checkedAt) < afterAlertLinesLifetime else { return nil }
                return (headline, reason(for: outcome), nil, .later, true)
            }
            guard abs(departure.timeIntervalSince(outcome.newDeparture)) < 1 else { return nil }
            return (headline, reason(for: outcome), nil, outcome.kind, false)
        case .late:
            let age = now.timeIntervalSince(outcome.checkedAt)
            guard age < lateLinesLifetime else { return nil }
            return (headline, reason(for: outcome), outcome.draft, .late, false)
        case .unchanged:
            return nil
        }
    }

    /// REQ-REPLAN-011: the baseline body, and after it the reason when the event has an outcome.
    static func catchUpBody(base: String, outcome: ReplanOutcome?) -> String {
        guard let outcome, outcome.kind != .unchanged else { return base }
        return base + " " + reason(for: outcome)
    }

    // MARK: - Delay draft

    /// The fixed draft (REQ-REPLAN-014); the title is cut to 40 characters.
    static func templateDraft(lateBy: Int, title: String, estimate: Date, timeZone: TimeZone = .current) -> String {
        let shortTitle = String(title.prefix(draftTitleLength))
        return "Hi, I'm running about \(lateBy) min late for \(shortTitle). "
            + "I should be there around \(clockText(estimate, timeZone: timeZone))."
    }

    /// A model reply is used only when it is short, names the arrival time exactly as given, and holds no number
    /// that the two facts do not hold.
    static func accepts(draft: String, lateBy: Int, estimateText: String) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= draftMaxLength, text.contains(estimateText) else { return false }
        let allowed = Set(digitRuns(in: "\(lateBy) \(estimateText)"))
        return digitRuns(in: text).allSatisfy { allowed.contains($0) }
    }

    /// The runs of ASCII digits in a text.
    static func digitRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for ch in text {
            if ch.isASCII, ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: - Navigation

    /// REQ-REPLAN-013: the tapped id counts only when the event still exists.
    static func tapSelection(pending: UUID?, events: [ScheduledEvent]) -> UUID? {
        guard let pending, events.contains(where: { $0.id == pending }) else { return nil }
        return pending
    }
}

// MARK: - Draft client

/// One `POST /ai` that asks Muse Spark for a replacement of the delay draft (REQ-REPLAN-014, 015). The request carries
/// only the late minutes and the arrival time: no title, no place, no address, no coordinates, no event id.
struct ReplanDraftClient {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/ai"
    static let timeout: TimeInterval = 8
    static let model = "muse-spark-1.3"
    static let summary = "Delay message draft"
    static let instructions = "Write one or two short, polite sentences in plain English from the user to the people "
        + "waiting for them. Say that the user is running late by the number of minutes given and expects to arrive at "
        + "the time given. Use only those two facts. Do not add names, places, reasons or any other number. "
        + "Reply with the sentences only."

    let config: AppConfig
    let send: Send
    var connections: ConnectionLog = ConnectionLog.shared

    /// The text of the request input: the only place the two facts are put.
    static func input(lateBy: Int, estimateText: String) -> String {
        "Minutes late: \(lateBy). Expected arrival: \(estimateText)."
    }

    func makeRequest(lateBy: Int, estimateText: String) -> URLRequest? {
        let body: [String: Any] = [
            "model": Self.model,
            "instructions": Self.instructions,
            "input": Self.input(lateBy: lateBy, estimateText: estimateText),
            "reasoning": ["effort": reasoningEffort]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        return config.proxyPOSTRequest(Self.path, body: data, timeout: Self.timeout)
    }

    /// The accepted replacement text, or nil (the template stays). One packet per request: `failed` for a transport or
    /// HTTP failure, an undecodable body or an answer without text; `ok` for an answer with text, accepted or not;
    /// none for a cancelled request.
    func refine(lateBy: Int, estimateText: String) async -> String? {
        guard config.hasAI, let request = makeRequest(lateBy: lateBy, estimateText: estimateText) else { return nil }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            if AgentClient.transportError(for: error) != .cancelled { note(.failed) }
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = Self.outputText(from: data), !text.isEmpty else {
            note(.failed)
            return nil
        }
        note(.ok)
        return Replan.accepts(draft: text, lateBy: lateBy, estimateText: estimateText)
            ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private func note(_ status: ConnectionStatus) {
        connections.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: Self.summary, status: status, flowID: nil)
    }

    /// The text parts of the `message` items of a Responses answer, joined; nil for a body that is not a Responses answer.
    static func outputText(from data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let output = root["output"] as? [Any] else { return nil }
        var pieces: [String] = []
        for element in output {
            guard let item = element as? [String: Any], item["type"] as? String == "message" else { continue }
            for part in (item["content"] as? [[String: Any]]) ?? [] where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String { pieces.append(text) }
            }
        }
        return pieces.isEmpty ? nil : pieces.joined()
    }
}
