import Foundation
@testable import besir

/// A scripted transport. It records every history handed to it and answers from a script: a turn, an error,
/// or a hold that a test releases later (so late-response and cancellation tests do not depend on timing).
/// It ignores task cancellation on purpose: a test that needs a cancellation error scripts it.
@MainActor
final class FakeTransport: AgentTransport {
    enum Step {
        case turn(AgentTurn)
        case fail(Error)
        case hold
    }

    struct Unscripted: Error {}

    /// Sentinels that a real request would carry. Tests prove they exist here before they scan for their absence.
    static let host = "sentinel-host-0001.invalid"
    static let token = "SENTINEL-TOKEN-0001"
    let requestURL = URL(string: "https://sentinel-host-0001.invalid/ai")!

    var isConfigured = true
    private(set) var requests: [[AgentEntry]] = []
    private var script: [Step]
    private var held: [Int: CheckedContinuation<AgentTurn, Error>] = [:]

    init(_ script: [Step] = []) {
        self.script = script
    }

    /// The history of the nth request (1-based); empty when that request never arrived, so a missing request fails an
    /// assertion instead of crashing the test run.
    func request(_ number: Int) -> [AgentEntry] {
        requests.indices.contains(number - 1) ? requests[number - 1] : []
    }

    /// Steps not yet used.
    var remaining: Int { script.count }

    func enqueue(_ steps: Step...) {
        script.append(contentsOf: steps)
    }

    func enqueue(contentsOf steps: [Step]) {
        script.append(contentsOf: steps)
    }

    func send(history: [AgentEntry]) async throws -> AgentTurn {
        requests.append(history)
        let number = requests.count
        guard !script.isEmpty else { throw Unscripted() }
        switch script.removeFirst() {
        case .turn(let turn):
            return turn
        case .fail(let error):
            throw error
        case .hold:
            return try await withCheckedThrowingContinuation { held[number] = $0 }
        }
    }

    /// Delivers the answer of a held request (1-based request number). False when nothing is held under that number.
    @discardableResult
    func release(_ number: Int, _ result: Result<AgentTurn, Error>) -> Bool {
        guard let continuation = held.removeValue(forKey: number) else { return false }
        continuation.resume(with: result)
        return true
    }

    /// Waits (yielding, bounded) until `count` requests have reached the transport.
    func waitForRequests(_ count: Int) async -> Bool {
        await eventually { self.requests.count >= count }
    }
}

/// Yields to the main actor until the condition holds. Bounded, so a missing event fails a test instead of hanging it.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<5000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// Builders for neutral turns. The raw bytes are only markers; the session keeps them untouched.
enum Turns {
    static let listArguments = #"{"from":"2026-10-28T00:00","to":"2026-10-29T00:00"}"#
    static let createArguments = #"{"title":"Team sync","start":"2026-10-28T15:00","end":"2026-10-28T16:00"}"#

    private static func raw(_ kind: String, _ text: String) -> Data {
        Data("RAW \(kind) \(text)".utf8)
    }

    static func message(_ text: String) -> AgentItem {
        .message(text: text, raw: raw("message", text))
    }

    static func call(_ name: String, _ arguments: String, id: String) -> AgentItem {
        .functionCall(callID: id, name: name, arguments: arguments, raw: raw("call", id))
    }

    static func reasoning() -> AgentItem {
        .reasoning(raw: raw("reasoning", "r"))
    }

    static func turn(_ items: AgentItem..., completed: Bool = true, responseID: String? = nil) -> AgentTurn {
        AgentTurn(completed: completed, items: items, responseID: responseID)
    }

    static func text(_ text: String) -> AgentTurn {
        turn(message(text))
    }

    static func list(id: String) -> AgentTurn {
        turn(call("list_activities", listArguments, id: id))
    }

    static func create(id: String) -> AgentTurn {
        turn(call("create_activity", createArguments, id: id))
    }

    static func delete(_ activityID: UUID, id: String) -> AgentTurn {
        turn(call("delete_activity", "{\"id\":\"\(activityID.uuidString)\"}", id: id))
    }
}
