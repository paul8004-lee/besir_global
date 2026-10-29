import Foundation

// SPEC-AGENT-002 (M4a): the request loop. The session works on already-parsed turns that an injected transport
// returns; it never sees the wire format. It owns the neutral turn type and the usable-response check.

// MARK: - Neutral turn types

/// One item of a model turn. `raw` is the item exactly as the transport received it, kept so a transport can replay it.
enum AgentItem: Equatable {
    case message(text: String, raw: Data)
    case functionCall(callID: String?, name: String?, arguments: String, raw: Data)
    case reasoning(raw: Data)
}

/// A function call that has a call id and a name.
struct AgentCall: Equatable {
    let callID: String
    let name: String
    let arguments: String
}

/// What a transport returns for one request, already parsed.
struct AgentTurn: Equatable {
    var completed: Bool
    var items: [AgentItem]
    /// An opaque handle for the transport's own use (the session never reads it).
    var responseID: String?

    init(completed: Bool = true, items: [AgentItem], responseID: String? = nil) {
        self.completed = completed
        self.items = items
        self.responseID = responseID
    }

    /// The usable-response check of spec.md section 3.4: completed, at least one message or function call, and
    /// every function call has a call id and a name.
    var isUsable: Bool {
        guard completed else { return false }
        var answers = false
        for item in items {
            switch item {
            case .message:
                answers = true
            case .functionCall(let callID, let name, _, _):
                guard let callID, !callID.isEmpty, let name, !name.isEmpty else { return false }
                answers = true
            case .reasoning:
                break
            }
        }
        return answers
    }

    /// The function calls in call order. Only meaningful for a usable turn.
    var calls: [AgentCall] {
        items.compactMap { item in
            guard case .functionCall(let callID?, let name?, let arguments, _) = item else { return nil }
            return AgentCall(callID: callID, name: name, arguments: arguments)
        }
    }

    /// The items to keep in the history: as received, except that reasoning items at the very end are dropped
    /// (a reasoning item must be followed by a message or a call).
    var replayItems: [AgentItem] {
        var kept = items
        while case .reasoning? = kept.last { kept.removeLast() }
        return kept
    }
}

/// The conversation as the session keeps it and hands it to the transport on every request.
enum AgentEntry: Equatable {
    case user(String)
    case assistant([AgentItem], responseID: String?)
    case callOutput(callID: String, result: String)
}

/// Failures a transport reports. The session turns each into one fixed line.
enum AgentTransportError: Error, Equatable {
    case offline
    case timedOut
    case cancelled
    case unreadableBody
    case http(status: Int, body: Data)
    case other
}

@MainActor
protocol AgentTransport: AnyObject {
    /// False while the build holds no Worker address or no token: the session then sends nothing.
    var isConfigured: Bool { get }
    func send(history: [AgentEntry]) async throws -> AgentTurn
}

/// Placeholder until the real transport exists: it reports the build as not set up, so nothing is sent.
@MainActor
final class AgentPendingTransport: AgentTransport {
    var isConfigured: Bool { false }
    func send(history: [AgentEntry]) async throws -> AgentTurn { throw AgentTransportError.other }
}

// MARK: - What the chat shows

struct AgentLogEntry: Identifiable {
    enum Kind {
        case user(String)
        case assistant(String)
        /// A tool call and its result are kept for the transcript only; the chat does not draw them.
        case tool(name: String, arguments: String)
        case result(String)
        case card(AgentCard)
        case notice(String)
        case error(String)
        /// The Google Maps mark row after an answer that used place or route data (log only, never in the history).
        case attribution
    }

    let id = UUID()
    let kind: Kind
}

// MARK: - Session

@MainActor
final class AgentSession: ObservableObject {
    static let maxRequests = 6

    private enum Line {
        static let unreachable = "Couldn't reach the assistant. Check your connection and try again."
        static let slow = "The assistant took too long to answer. Try again."
        static let tokenRejected = "The assistant rejected this build's access token."
        static let unexpected = "The assistant returned an unexpected response."
        static let tooManySteps = "The assistant needed too many steps. Try again with a simpler request."
        static let notSetUp = "The assistant is not set up in this build."
        static let interrupted = "The chat was closed before the assistant replied."
        static func http(_ status: Int) -> String { "The assistant returned an unexpected response (HTTP \(status))." }

        static let stepLimit = #"{"status":"rejected","message":"Not executed. The step limit was reached."}"#
        static let oneAtATime = #"{"status":"rejected","message":"Not executed. Make one tool call at a time."}"#
        static let lookupInterrupted = #"{"status":"unavailable","message":"The lookup was interrupted. Call the tool again if the user still wants it."}"#
    }

    /// What the chat draws, and what the transcript prints.
    @Published private(set) var entries: [AgentLogEntry] = []
    /// The card waiting for Confirm or Cancel, if any.
    @Published private(set) var pendingCard: AgentCard?
    /// True while a request is in flight.
    @Published private(set) var isWaiting = false
    /// True while a tapped card is being applied.
    @Published private(set) var isResolving = false
    /// The conversation as it goes to the transport.
    private(set) var history: [AgentEntry] = []
    /// How many answers of cancelled or superseded requests were dropped (for tests).
    private(set) var discardedCount = 0

    private let toolbox: AgentToolbox
    private let transport: AgentTransport
    /// The identity of the request being awaited; an answer for any other identity is dropped.
    private var currentRequest: UUID?
    private var requestTask: Task<Void, Never>?
    private var requestsThisMessage = 0
    /// Model requests the message being served may make: 6, or 12 for a plan message.
    private var requestCap = AgentSession.maxRequests
    /// The call a pending card belongs to, and the calls that came after it in the same response.
    private var pendingCalls: (first: AgentCall, extras: [AgentCall])?
    /// Set when the sheet closes while a tapped card is still being applied: record the result, send nothing.
    private var stopAfterResolve = false
    /// The calls of a lookup that is running and unanswered; set only while the lookup is in flight.
    private var lookupCalls: (first: AgentCall, extras: [AgentCall])?
    /// Set by any `ok` place or route result of the current user message; cleared only by `send` and `newChat`.
    private var googleDataThisMessage = false
    private let connections: ConnectionLog
    /// The flow the packets of the message being served belong to.
    private var flow = UUID()

    init(toolbox: AgentToolbox, transport: AgentTransport, connections: ConnectionLog = ConnectionLog.shared) {
        self.toolbox = toolbox
        self.transport = transport
        self.connections = connections
    }

    /// Send and the text field are available only when nothing is in flight and no card waits.
    var canSend: Bool { !isWaiting && pendingCard == nil }

    /// The entries the chat draws: tool and result entries are not drawn, and neither is a run of assistant entries
    /// directly before a tool entry (a preface to a tool call). Hidden entries stay in `entries` and the history.
    var chatEntries: [AgentLogEntry] {
        var shown: [AgentLogEntry] = []
        var run: [AgentLogEntry] = []
        for entry in entries {
            switch entry.kind {
            case .assistant:
                run.append(entry)
            case .tool:
                run = []
            case .result:
                shown += run
                run = []
            default:
                shown += run
                run = []
                shown.append(entry)
            }
        }
        return shown + run
    }

    // MARK: Entry points

    /// `text` is what the model gets. `shown`, when it is not blank, is what the chat draws instead (a share's short line);
    /// it never enters `history` or a request.
    func send(_ text: String, shown: String? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !clean.isEmpty else { return }
        toolbox.endDayPlan()
        begin(clean, shown: shown, cap: Self.maxRequests)
    }

    /// The path of every user message: the flow, the history, the chat line and the first request.
    private func begin(_ clean: String, shown: String?, cap: Int) {
        let line = shown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        flow = connections.takeOfferedFlow() ?? ConnectionLog.beginFlow()
        history.append(.user(clean))
        entries.append(AgentLogEntry(kind: .user(line.isEmpty ? clean : line)))
        requestCap = cap
        requestsThisMessage = 0
        googleDataThisMessage = false
        startRequest()
    }

    /// SPEC-PLANDAY-001: sends the one plan message with the request cap of a plan (12). The plan turn starts here and ends
    /// at the next ordinary message or at a new chat. False when a message cannot be taken now.
    @discardableResult
    func sendPlan(message: String, shown: String? = nil, context: DayPlanContext) -> Bool {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !clean.isEmpty else { return false }
        toolbox.beginDayPlan(context)
        begin(clean, shown: shown, cap: PlanMyDay.requestCap)
        return true
    }

    /// SPEC-PLANDAY-001: registers up to eight Store places as handles in this session and returns the events with them.
    func prepareDayPlan(events: [PlanMyDay.Event]) -> [PlanMyDay.Event] {
        PlanMyDay.registerStorePlaces(events, registry: &toolbox.registry)
    }

    /// SPEC-CAMSNAP-001: registers one snapped place as a handle in this session and returns it, so the model can use it in
    /// `create_activity`, `get_travel_time` and a day plan without searching for it. The same place keeps its handle.
    func registerPlace(_ place: Place) -> String? {
        toolbox.registry.register([place])?.first
    }

    /// Called by `newChat`, so whoever holds state that must not outlive the chat (a held plan) can drop it.
    var onNewChat: (() -> Void)?

    func confirmCard() async { await resolve(.confirm) }

    func cancelCard() async { await resolve(.cancel) }

    /// Clears the conversation. An in-flight request is cancelled silently and its answer dropped; a pending card
    /// is resolved as dismissed (nothing applied).
    func newChat() async {
        invalidateRequest()
        toolbox.resetConversation()
        let card = pendingCard
        pendingCard = nil
        pendingCalls = nil
        lookupCalls = nil
        isResolving = false
        stopAfterResolve = false
        googleDataThisMessage = false
        entries = []
        history = []
        requestsThisMessage = 0
        requestCap = Self.maxRequests
        onNewChat?()
        if let card { _ = await card.resolve(.dismiss) }
    }

    /// The chat sheet was closed: the conversation stays, an in-flight request is cancelled (the chat keeps one status
    /// notice, the history is unchanged), and a pending card is resolved as dismissed with `declined` recorded right
    /// after its call and no request.
    func sheetDismissed() async {
        let wasWaiting = isWaiting
        invalidateRequest()
        if wasWaiting { entries.append(AgentLogEntry(kind: .notice(Line.interrupted))) }
        // A lookup that was running has a call with no output yet: answer it once, and forget it in the same step.
        if let calls = lookupCalls {
            lookupCalls = nil
            record(calls, firstResult: Line.lookupInterrupted, notice: nil)
        }
        guard let card = pendingCard, let calls = pendingCalls else { return }
        if isResolving {
            stopAfterResolve = true
            return
        }
        isResolving = true
        let resolution = await card.resolve(.dismiss)
        guard pendingCard === card else { return }
        isResolving = false
        pendingCard = nil
        pendingCalls = nil
        record(calls, firstResult: resolution?.result ?? AgentToolbox.declinedResult, notice: resolution?.notice)
    }

    /// Returns when no request is outstanding. For tests; the chat does not need it.
    func settle() async {
        while let task = requestTask { await task.value }
    }

    // MARK: Requests

    private func invalidateRequest() {
        requestTask?.cancel()
        requestTask = nil
        currentRequest = nil
        isWaiting = false
    }

    private func startRequest() {
        guard transport.isConfigured else {
            endTurn(with: Line.notSetUp)
            return
        }
        requestsThisMessage += 1
        let identity = UUID()
        currentRequest = identity
        isWaiting = true
        let snapshot = history
        requestTask = Task { [weak self, transport] in
            do {
                let turn = try await transport.send(history: snapshot)
                self?.received(turn, identity)
            } catch {
                self?.failed(error, identity)
            }
        }
    }

    private func endTurn(with line: String) {
        entries.append(AgentLogEntry(kind: .error(line)))
        currentRequest = nil
        requestTask = nil
        isWaiting = false
    }

    private func failed(_ error: Error, _ identity: UUID) {
        guard identity == currentRequest else {
            discardedCount += 1
            return
        }
        currentRequest = nil
        requestTask = nil
        isWaiting = false
        if Self.isCancellation(error) { return }
        noteMessage(Self.failureWord(for: error), .failed)
        endTurn(with: Self.line(for: error))
    }

    /// One packet for a model request that ended: fixed words only, never the raw error.
    private func noteMessage(_ summary: String, _ status: ConnectionStatus) {
        connections.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: summary, status: status, flowID: flow)
    }

    private static func failureWord(for error: Error) -> String {
        switch error as? AgentTransportError {
        case .offline?: return "Offline"
        case .timedOut?: return "Timed out"
        case .http(let status, let body)?: return status == 401 && isWorkerUnauthorized(body) ? "Rejected" : "Unexpected"
        default: return "Unexpected"
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return (error as? AgentTransportError) == .cancelled
    }

    private static func line(for error: Error) -> String {
        guard let failure = error as? AgentTransportError else { return Line.unexpected }
        switch failure {
        case .offline:
            return Line.unreachable
        case .timedOut:
            return Line.slow
        case .http(let status, let body):
            return status == 401 && isWorkerUnauthorized(body) ? Line.tokenRejected : Line.http(status)
        case .unreadableBody, .other, .cancelled:
            return Line.unexpected
        }
    }

    /// The Worker's own check answers 401 with exactly `{"error":"unauthorized"}`; any other 401 is not its.
    private static func isWorkerUnauthorized(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object.count == 1 && object["error"] as? String == "unauthorized"
    }

    // MARK: The model's answer

    private func received(_ turn: AgentTurn, _ identity: UUID) {
        guard identity == currentRequest else {
            discardedCount += 1
            return
        }
        currentRequest = nil
        requestTask = nil
        isWaiting = false
        guard turn.isUsable else {
            noteMessage("Unexpected", .failed)
            endTurn(with: Line.unexpected)
            return
        }
        noteMessage("Reply received", .ok)

        let items = turn.replayItems
        history.append(.assistant(items, responseID: turn.responseID))
        for case .message(let text, _) in items where !text.isEmpty {
            entries.append(AgentLogEntry(kind: .assistant(text)))
        }
        let calls = turn.calls
        guard let first = calls.first else {
            // The final answer: one Google Maps row after it when place or route data was used and it has text.
            if googleDataThisMessage, items.contains(where: { if case .message(let text, _) = $0 { return !text.isEmpty } else { return false } }) {
                entries.append(AgentLogEntry(kind: .attribution))
            }
            return
        }
        let extras = Array(calls.dropFirst())
        entries.append(AgentLogEntry(kind: .tool(name: first.name, arguments: first.arguments)))

        if requestsThisMessage >= requestCap {
            record((first, extras), firstResult: Line.stepLimit, notice: nil)
            endTurn(with: Line.tooManySteps)
            return
        }
        switch toolbox.handle(name: first.name, arguments: first.arguments, flow: flow) {
        case .result(let result):
            record((first, extras), firstResult: result, notice: nil)
            startRequest()
        case .card(let card):
            pendingCard = card
            pendingCalls = (first, extras)
            entries.append(AgentLogEntry(kind: .card(card)))
        case .lookup(let lookup):
            // The lookup is the request in flight, under its own identity; it is not a model request, so it does not
            // count toward `maxRequests` (the step-limit test above already ran).
            let identity = UUID()
            currentRequest = identity
            isWaiting = true
            let pair = (first: first, extras: extras)
            lookupCalls = pair
            // @MX:WARN The lookup closure registers handles in the toolbox registry and runs for a while.
            // @MX:REASON A late answer must be dropped by request identity and must not write the registry; the
            // closure checks Task.isCancelled before registering, and `lookupFinished` checks the identity.
            requestTask = Task { [weak self] in
                let output = await lookup.run()
                self?.lookupFinished(output, identity, calls: pair)
            }
        }
    }

    private func lookupFinished(_ output: AgentLookupOutput, _ identity: UUID, calls: (first: AgentCall, extras: [AgentCall])) {
        guard identity == currentRequest else {
            discardedCount += 1
            return
        }
        currentRequest = nil
        requestTask = nil
        isWaiting = false
        lookupCalls = nil
        if output.showsGoogleData { googleDataThisMessage = true }
        record(calls, firstResult: output.result, notice: nil)
        startRequest()
    }

    /// Answers the first call with `firstResult` and every later call of the same response with the one-call
    /// rejection, in call order, in the history and in the log.
    private func record(_ calls: (first: AgentCall, extras: [AgentCall]), firstResult: String, notice: String?) {
        history.append(.callOutput(callID: calls.first.callID, result: firstResult))
        entries.append(AgentLogEntry(kind: .result(Self.status(of: firstResult))))
        noteToolCall(calls.first.name, status: Self.status(of: firstResult))
        if let notice { entries.append(AgentLogEntry(kind: .notice(notice))) }
        for extra in calls.extras {
            entries.append(AgentLogEntry(kind: .tool(name: extra.name, arguments: extra.arguments)))
            history.append(.callOutput(callID: extra.callID, result: Line.oneAtATime))
            entries.append(AgentLogEntry(kind: .result("rejected")))
        }
    }

    /// The first call of a response, once its result is final. The name is shown only when the app declared it to the
    /// model; a tool name is model text, so any other name is stored as `Unknown tool`.
    private func noteToolCall(_ name: String, status: String) {
        connections.record(from: .museSpark, to: .besir, kind: .agentToolCall,
                           summary: Self.toolCallSummary(name), status: Self.toolCallStatus(status), flowID: flow)
    }

    /// The `name` of every declaration in `declarations`; a list that cannot be read gives the empty set.
    static func knownToolNames(from declarations: Data = AgentTools.declarationsJSON()) -> Set<String> {
        guard let list = try? JSONSerialization.jsonObject(with: declarations) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { $0["name"] as? String })
    }

    private static let declaredToolNames = knownToolNames()

    /// The tool name with each `_` as a space when it is exactly a declared name, else `Unknown tool`.
    static func toolCallSummary(_ name: String) -> String {
        declaredToolNames.contains(name) ? name.replacingOccurrences(of: "_", with: " ") : "Unknown tool"
    }

    /// `ok` and `applied` are `ok`, `declined` is `declined`, `no_route` is `noRoute` (a normal answer), anything else
    /// (`rejected`, `not_found`, `stale`, `unavailable`, an unknown word) is `failed`.
    static func toolCallStatus(_ status: String) -> ConnectionStatus {
        switch status {
        case "ok", "applied": return .ok
        case "declined": return .declined
        case "no_route": return .noRoute
        default: return .failed
        }
    }

    /// The `status` of a tool result, or `ok` for a result that has none (a list answer).
    private static func status(of result: String) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        return (object?["status"] as? String) ?? "ok"
    }

    // MARK: The card

    private func resolve(_ how: AgentCardResolution) async {
        guard let card = pendingCard, let calls = pendingCalls, !isResolving else { return }
        isResolving = true
        let resolution = await card.resolve(how)
        // New chat or a sheet close may have taken over while the card was being applied.
        guard pendingCard === card else { return }
        isResolving = false
        pendingCard = nil
        pendingCalls = nil
        record(calls, firstResult: resolution?.result ?? AgentToolbox.declinedResult, notice: resolution?.notice)
        if stopAfterResolve {
            stopAfterResolve = false
            return
        }
        startRequest()
    }
}

#if DEBUG
extension AgentSession {
    /// The conversation as plain text, one line per item (spec.md section 3.7).
    func transcript() -> String {
        entries.map { entry -> String in
            switch entry.kind {
            case .user(let text): return "USER \(text)"
            case .assistant(let text): return "ASSISTANT \(text)"
            case .tool(let name, let arguments): return "TOOL \(name) \(arguments)"
            case .result(let status): return "RESULT \(status)"
            case .card(let card): return "CARD \(card.lines.first ?? "") \(card.mark?.rawValue ?? "Pending")"
            case .notice(let line): return "NOTICE \(line)"
            case .error(let line): return "ERROR \(line)"
            case .attribution: return "ATTRIBUTION"
            }
        }.joined(separator: "\n")
    }
}
#endif
