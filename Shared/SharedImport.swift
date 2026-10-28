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
    /// The composed message of an item whose hand-off was refused, so the retry does not call `/vision` again.
    private var kept: [UUID: String] = [:]

#if DEBUG
    /// Debug only: one `vision_call` line per `/vision` request, so a walk-through can count its paid calls. No content, no id.
    static let logMarker = "BESIR_DEBUG_SHARE_IMPORT_LOG_MARKER"
    var logURL = FileManager.default.temporaryDirectory.appendingPathComponent("besir-share-import.log")
#endif

    init(inbox: SharedInbox = .standard, now: @escaping () -> Date = Date.init) {
        self.inbox = inbox
        self.now = now
    }

    /// One pass handles at most one item. `canHand` says whether the agent can take a message right now; `hand` gives it the
    /// message and says whether it was accepted.
    func pass(vision: VisionReading, canHand: () -> Bool, hand: (String) -> Bool) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false; isReading = false }
        guard canHand(), let item = inbox.pending(now: now()).first else { return }
        if let message = kept[item.id] { deliver(message, for: item, hand: hand); return }

        let caption = SharedMessage.classify(item.text)
        guard let base64 = item.imageBase64 else {
            switch caption {
            case .text:
                if case .message(let message) = SharedMessage.compose(fields: nil, text: item.text) { deliver(message, for: item, hand: hand) }
            case .link:
                finish(item, line: SharedLine.linkOnly)
            case .none:
                finish(item, line: SharedLine.unreadable)
            }
            return
        }

        guard vision.isConfigured else { alertLine = SharedLine.notSetUp; return }
        guard SharedImage.decodedByteCount(ofBase64: base64) <= SharedImage.maxBytes else {
            finish(item, line: SharedLine.unreadable)
            return
        }
        isReading = true
#if DEBUG
        logVisionCall()
#endif
        switch await vision.read(imageBase64: base64, mime: item.mimeType ?? "image/jpeg") {
        case .failure(let failure):
            finish(item, line: SharedLine.line(for: failure))
        case .success(let fields):
            if fields.isEmpty { finish(item, line: SharedLine.nothingFound); return }
            if case .message(let message) = SharedMessage.compose(fields: fields, text: item.text) { deliver(message, for: item, hand: hand) }
        }
    }

    /// The attempt is over: show the line and take the item out.
    private func finish(_ item: SharedInbox.Item, line: String) {
        alertLine = line
        inbox.remove(item.id)
    }

    private func deliver(_ message: String, for item: SharedInbox.Item, hand: (String) -> Bool) {
        if hand(message) {
            inbox.remove(item.id)
            kept[item.id] = nil
        } else {
            kept[item.id] = message
        }
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
