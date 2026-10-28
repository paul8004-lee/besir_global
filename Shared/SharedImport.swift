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
    func pass(vision: VisionReading, canHand: () -> Bool, hand: (_ message: String, _ shown: String) -> Bool) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false; isReading = false }
        guard canHand(), let item = inbox.pending(now: now()).first else { return }
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
