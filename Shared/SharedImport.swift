import Foundation

/// The fixed lines the import shows. Nothing from the server or the model is ever shown; this is the only place the strings exist.
enum SharedLine {
    static let notSetUp = "The assistant is not set up in this build."
    static let linkOnly = "That share only had a link. Share a screenshot of the post instead."
    static let unreadable = "The shared image couldn't be read."
    static let offline = "Couldn't reach the image reader. Check your connection and share it again."
    static let tokenRejected = "The assistant rejected this build's access token."
    static let busy = "The image reader is busy. Share the image again in a minute."
    static let other = "Couldn't read the shared image. Share it again."
    static let nothingFound = "Nothing that looks like an event was found in that image."
    static let planNothingRead = "Nothing in the shared items could be read."

    /// After a Plan my day hand-off in which some shared items were dropped.
    static func planSkipped(_ count: Int) -> String {
        count == 1 ? "1 shared item couldn't be used and was skipped." : "\(count) shared items couldn't be used and were skipped."
    }

    static func line(for failure: VisionFailure) -> String {
        switch failure {
        case .notSetUp: return notSetUp
        case .imageUnreadable: return unreadable
        case .tokenRejected: return tokenRejected
        case .busy: return busy
        case .offline: return offline
        case .other: return other
        }
    }
}

/// Takes shared items out of the queue and hands them to the agent, one item per pass, one paid `/vision` call per share.
@MainActor
final class SharedImport: ObservableObject {
    /// The fixed line to show, or nil. The view clears it when the alert is dismissed.
    @Published var alertLine: String?
    @Published private(set) var isReading = false
    /// The number of waiting items as of the last pass that could read the queue (SPEC-PLANDAY-001).
    @Published private(set) var waitingCount = 0
    /// A plan whose hand-off was refused, until the next tap on Plan my day or a new chat.
    @Published private(set) var held: PlanMyDay.Held?

    private let inbox: SharedInbox
    private let now: () -> Date
    /// Set before the pass first waits and cleared on every exit, so overlapping triggers cannot take the same item twice.
    private var inFlight = false
    /// The message and the shown line of an item whose hand-off was refused, so the retry does not call `/vision` again.
    private var kept: [UUID: (message: String, shown: String)] = [:]
    /// The flow of an item whose hand-off was refused, so its retry joins the same flow.
    private var flows: [UUID: UUID] = [:]
    private let connections: ConnectionLog

#if DEBUG
    /// Debug only: one `vision_call` line per `/vision` request, so a walk-through can count its paid calls. No content, no id.
    static let logMarker = "BESIR_DEBUG_SHARE_IMPORT_LOG_MARKER"
    var logURL = FileManager.default.temporaryDirectory.appendingPathComponent("besir-share-import.log")
#endif

    init(inbox: SharedInbox = .standard, now: @escaping () -> Date = Date.init,
         connections: ConnectionLog = ConnectionLog.shared) {
        self.inbox = inbox
        self.now = now
        self.connections = connections
    }

    /// One pass handles at most one item. `canHand` says whether the agent can take a message right now; `hand` gives it the
    /// message and the short line the chat shows for it, and says whether they were accepted.
    func pass(vision: VisionReading, canHand: () -> Bool, holdForPlan: Bool = false,
              hand: (_ message: String, _ shown: String) -> Bool) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false; isReading = false }
        guard canHand() else { return }
        let items = inbox.pending(now: now())
        if holdForPlan {
            // Two or more waiting items, or a held plan, belong to Plan my day: the automatic pass takes none of them, unless
            // a one-item message is held for its retry.
            waitingCount = items.count
            if items.count >= 2 || held != nil, kept.isEmpty { return }
        }
        guard let item = items.first else { return }
        if let held = kept[item.id] {
            deliver(held.message, shown: held.shown, for: item, flow: flows[item.id] ?? ConnectionLog.beginFlow(), hand: hand)
            return
        }

        let flow = ConnectionLog.beginFlow()
        let caption = SharedMessage.classify(item.text)
        guard let base64 = item.imageBase64 else {
            switch caption {
            case .text:
                noteShare("Text shared", .ok, item, flow)
                if case .message(let message) = SharedMessage.compose(fields: nil, text: item.text) {
                    deliver(message, shown: SharedMessage.shownLine(fields: nil), for: item, flow: flow, hand: hand)
                }
            case .link:
                noteShare("Link shared", .ok, item, flow)
                finish(item, line: SharedLine.linkOnly)
            case .none:
                noteShare("Empty share", .failed, item, flow)
                finish(item, line: SharedLine.unreadable)
            }
            return
        }

        guard vision.isConfigured else { alertLine = SharedLine.notSetUp; return }
        guard SharedImage.decodedByteCount(ofBase64: base64) <= SharedImage.maxBytes else {
            noteShare("Image shared", .failed, item, flow)
            finish(item, line: SharedLine.unreadable)
            return
        }
        noteShare("Image shared", .ok, item, flow)
        isReading = true
#if DEBUG
        logVisionCall()
#endif
        switch await vision.read(imageBase64: base64, mime: item.mimeType ?? "image/jpeg") {
        case .failure(let failure):
            noteRead(failure, flow)
            finish(item, line: SharedLine.line(for: failure))
        case .success(let fields):
            noteRead(nil, flow)
            if fields.isEmpty { finish(item, line: SharedLine.nothingFound); return }
            if case .message(let message) = SharedMessage.compose(fields: fields, text: item.text) {
                deliver(message, shown: SharedMessage.shownLine(fields: fields), for: item, flow: flow, hand: hand)
            }
        }
    }

    /// The receipt of one queue item. The words are fixed: nothing of the shared text or image is ever recorded.
    private func noteShare(_ summary: String, _ status: ConnectionStatus, _ item: SharedInbox.Item, _ flow: UUID) {
        connections.record(from: ConnectionParty.forSharedText(item.text), to: .besir, kind: .share,
                           summary: summary, status: status, flowID: flow)
    }

    /// The image reading, once the reader has answered. Nothing was sent for `notSetUp` and `imageUnreadable`, and a
    /// cancelled pass records nothing.
    private func noteRead(_ failure: VisionFailure?, _ flow: UUID) {
        guard !Task.isCancelled else { return }
        switch failure {
        case .notSetUp?, .imageUnreadable?:
            return
        case nil:
            connections.record(from: .besir, to: .imageReader, kind: .imageRead, summary: "Image read", status: .ok, flowID: flow)
        default:
            connections.record(from: .besir, to: .imageReader, kind: .imageRead, summary: "Image read failed", status: .failed, flowID: flow)
        }
    }

    /// The attempt is over: show the line and take the item out.
    private func finish(_ item: SharedInbox.Item, line: String) {
        alertLine = line
        inbox.remove(item.id)
    }

    /// The flow is on offer to the log only while `hand` runs, so the agent's packets for this message join it.
    private func deliver(_ message: String, shown: String, for item: SharedInbox.Item, flow: UUID,
                         hand: (_ message: String, _ shown: String) -> Bool) {
        connections.offerFlow(flow)
        let accepted = hand(message, shown)
        connections.withdrawOffer()
        if accepted {
            inbox.remove(item.id)
            kept[item.id] = nil
            flows[item.id] = nil
        } else {
            kept[item.id] = (message, shown)
            flows[item.id] = flow
        }
    }

    /// Plan my day (SPEC-PLANDAY-001): the five oldest waiting items become usable shared items (images are read by `/vision`,
    /// three at a time), today's events are read after the mode was chosen, and the agent gets one message. `activities` and
    /// `mirror` are the two sources of today's events; `prepare` registers the Store places in the agent session and gives the
    /// events their place handles. Dropped items leave the queue at once, usable ones when `hand` accepts the message. A refused
    /// hand-off keeps the usable fields (not the message) as `held`, so the next tap composes again with its own mode and time.
    func planPass(mode: TransportMode, vision: VisionReading, activities: () -> [ActivityBlock], mirror: CalendarMirroring,
                  calendar: Calendar = .current, prepare: ([PlanMyDay.Event]) -> [PlanMyDay.Event], canHand: () -> Bool,
                  hand: (_ message: String, _ shown: String, _ context: DayPlanContext) -> Bool) async {
        guard !inFlight else { return }
        inFlight = true
        // Every exit leaves the count equal to the queue, so no state shows the button over an empty queue.
        defer { inFlight = false; isReading = false; waitingCount = inbox.pending(now: now()).count }
        guard canHand() else { return }

        let flow: UUID
        let usable: [PlanMyDay.Shared]
        let usableIDs: [UUID]
        let skipped: Int
        if let held {
            flow = held.flow
            usable = held.shared
            usableIDs = held.ids
            skipped = held.skipped
        } else {
            let items = Array(inbox.pending(now: now()).prefix(PlanMyDay.takeCount))
            if !vision.isConfigured, items.contains(where: { $0.imageBase64 != nil }) {
                alertLine = SharedLine.notSetUp
                return
            }
            flow = ConnectionLog.beginFlow()
            let gathered = await gather(items, vision: vision, flow: flow)
            usable = gathered.shared
            usableIDs = gathered.usableIDs
            skipped = gathered.droppedIDs.count
            // A dropped item is over: it leaves the queue now, whatever happens to the rest.
            for id in gathered.droppedIDs { inbox.remove(id) }
            guard !usable.isEmpty else {
                alertLine = SharedLine.planNothingRead
                return
            }
        }

        isReading = true
        let entries = await PlanMyDay.todaysEntries(from: mirror, now: now(), calendar: calendar)
        let current = now()
        let today = PlanMyDay.events(activities: activities(), entries: entries ?? [], now: current, calendar: calendar)
        let events = prepare(today.events)
        let message = PlanMyDay.compose(now: current, zone: calendar.timeZone, mode: mode, events: events, shared: usable,
                                        calendarAvailable: entries != nil)
        let shown = PlanMyDay.shownLine(sharedCount: usable.count, eventCount: events.count, calendarAvailable: entries != nil, cut: today.cut)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current)) ?? current
        let context = DayPlanContext(mode: mode, events: events, checkWindowEnd: dayEnd, calendarAvailable: entries != nil)

        connections.offerFlow(flow)
        let accepted = hand(message, shown, context)
        connections.withdrawOffer()
        if accepted {
            for id in usableIDs { inbox.remove(id) }
            held = nil
            if skipped > 0 { alertLine = SharedLine.planSkipped(skipped) }
        } else {
            held = PlanMyDay.Held(shared: usable, ids: usableIDs, skipped: skipped, flow: flow)
        }
    }

    /// A new chat starts: a held plan must not outlive the conversation that its handles belong to.
    func dropHeld() {
        held = nil
    }

    /// Turns the taken items into usable shared items, in queue order, and names the ones that were dropped. The receipts are
    /// the baseline's fixed words, all in the flow of the tap; an image goes to `/vision` once, never more than
    /// `visionParallel` reads at a time.
    private func gather(_ items: [SharedInbox.Item], vision: VisionReading, flow: UUID)
        async -> (shared: [PlanMyDay.Shared], usableIDs: [UUID], droppedIDs: [UUID]) {
        var texts: [Int: String] = [:]
        var reads: [(index: Int, base64: String, mime: String)] = []
        var dropped = Set<Int>()
        for (index, item) in items.enumerated() {
            guard let base64 = item.imageBase64 else {
                switch SharedMessage.classify(item.text) {
                case .text(let text):
                    noteShare("Text shared", .ok, item, flow)
                    texts[index] = text
                case .link:
                    noteShare("Link shared", .ok, item, flow)
                    dropped.insert(index)
                case .none:
                    noteShare("Empty share", .failed, item, flow)
                    dropped.insert(index)
                }
                continue
            }
            guard SharedImage.decodedByteCount(ofBase64: base64) <= SharedImage.maxBytes else {
                noteShare("Image shared", .failed, item, flow)
                dropped.insert(index)
                continue
            }
            noteShare("Image shared", .ok, item, flow)
            reads.append((index, base64, item.mimeType ?? "image/jpeg"))
        }

        var readings: [Int: Result<VisionFields, VisionFailure>] = [:]
        if !reads.isEmpty {
            isReading = true
            await withTaskGroup(of: (Int, Result<VisionFields, VisionFailure>).self) { group in
                var running = 0
                for read in reads {
                    if running == PlanMyDay.visionParallel, let done = await group.next() {
                        readings[done.0] = done.1
                        running -= 1
                    }
#if DEBUG
                    logVisionCall()
#endif
                    group.addTask { (read.index, await vision.read(imageBase64: read.base64, mime: read.mime)) }
                    running += 1
                }
                for await done in group { readings[done.0] = done.1 }
            }
        }

        var shared: [PlanMyDay.Shared] = []
        var usableIDs: [UUID] = []
        for (index, item) in items.enumerated() where !dropped.contains(index) {
            if let text = texts[index] {
                shared.append(.text(text))
                usableIDs.append(item.id)
                continue
            }
            switch readings[index] {
            case .success(let fields)?:
                noteRead(nil, flow)
                if fields.isEmpty { dropped.insert(index); continue }
                shared.append(.image(fields))
                usableIDs.append(item.id)
            case .failure(let failure)?:
                noteRead(failure, flow)
                dropped.insert(index)
            case nil:
                dropped.insert(index)
            }
        }
        return (shared, usableIDs, items.indices.filter { dropped.contains($0) }.map { items[$0].id })
    }

    /// The one place that decides what a share puts into the chat: the model gets `message`, the chat draws `shown`.
    /// Sends nothing and answers false when there is no session or it cannot take a message now.
    static func give(message: String, shown: String, to session: AgentSession?) -> Bool {
        guard let session, session.canSend else { return false }
        session.send(message, shown: shown)
        return true
    }

#if DEBUG
    private func logVisionCall() {
        let line = Data("vision_call\n".utf8)
        guard let handle = try? FileHandle(forWritingTo: logURL) else { try? line.write(to: logURL); return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
#endif
}
