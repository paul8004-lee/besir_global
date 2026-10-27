import Foundation
@testable import besir

/// Checks the replay rules of spec.md section 3.4 on a session history: every function call has its output after
/// it, in call order, before anything else is said; every reasoning item is followed, in its own output, by a
/// message or a function call.
enum PairingValidator {
    /// One text per problem found; empty means the history is valid.
    static func problems(in history: [AgentEntry]) -> [String] {
        var found: [String] = []
        var waiting: [String] = []

        for (index, entry) in history.enumerated() {
            switch entry {
            case .user:
                if !waiting.isEmpty { found.append("entry \(index): user message while \(waiting) have no output") }
            case .assistant(let items, _):
                if !waiting.isEmpty { found.append("entry \(index): new output while \(waiting) have no output") }
                waiting = []
                for (position, item) in items.enumerated() {
                    switch item {
                    case .reasoning:
                        let next = position + 1 < items.count ? items[position + 1] : nil
                        switch next {
                        case .message?, .functionCall?: break
                        default: found.append("entry \(index): reasoning item \(position) is not followed by a message or a call")
                        }
                    case .functionCall(let callID, _, _, _):
                        waiting.append(callID ?? "<no id>")
                    case .message:
                        break
                    }
                }
            case .callOutput(let callID, _):
                if waiting.first == callID {
                    waiting.removeFirst()
                } else {
                    found.append("entry \(index): output \(callID) is not the next call in call order")
                }
            }
        }
        if !waiting.isEmpty { found.append("end: \(waiting) have no output") }
        return found
    }
}
