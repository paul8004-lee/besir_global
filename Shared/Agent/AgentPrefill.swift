import Foundation

/// SPEC-BOOKCARD-001 (card t89) REQ-011: the check of what the model fills in. Foundation only: no session, no toolbox and no
/// view. Skeleton: nothing is kept yet.
enum AgentPrefill {
    static func values(fieldsText: String?, fields: [PartnerField], userLines: [String], now: Date,
                       calendar: Calendar) -> [String: AgentFieldValue] {
        [:]
    }
}
