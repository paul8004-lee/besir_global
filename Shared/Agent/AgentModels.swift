import Foundation

// Wire types shared by the tool layer (AgentTools.swift) and the loop of SPEC-AGENT-002.

/// How a pending confirmation card ends.
enum AgentCardResolution {
    case confirm, cancel, dismiss
}

/// The mark a resolved card carries.
enum AgentCardMark: String {
    case confirmed = "Confirmed"
    case cancelled = "Cancelled"
    case notApplied = "Not applied"
}

/// What a resolved card yields: the tool result text for the model and, when relevant, a one-line notice for the user.
struct AgentResolution {
    let result: String
    let notice: String?
}

/// The gate's answer to one function call: a result for the model now, a card that waits for the user, or a network
/// lookup the session runs as the request in flight (SPEC-AGENTPLACE-001).
enum AgentToolOutcome {
    case result(String)
    case card(AgentCard)
    case lookup(AgentLookup)
}
