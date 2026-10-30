import Foundation

/// SPEC-BOOKCARD-001 (card t89): the one client of the partner path. It names no partner. It asks the proxy for the directory,
/// asks an entry's route for its form and sends a request to that route. Built per call from the live configuration; it owns
/// no URL session, the caller hands in `send`.
final class PartnerClient {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    private let config: AppConfig
    private let send: Send
    private let connections: ConnectionLog

    init(config: AppConfig, send: @escaping Send, connections: ConnectionLog = ConnectionLog.shared) {
        self.config = config
        self.send = send
        self.connections = connections
    }

    var isConfigured: Bool { config.hasProxy }

    /// Skeleton: no call is made yet.
    func directory(flow: UUID) async -> Result<[PartnerEntry], PartnerFailure> { .failure(.other) }

    /// Skeleton: no call is made yet.
    func form(of entry: PartnerEntry, flow: UUID) async -> Result<PartnerSpec, PartnerFailure> { .failure(.other) }

    /// Skeleton: no call is made yet.
    func submit(_ request: PartnerRequest, to spec: PartnerSpec, flow: UUID) async -> Result<PartnerAnswer, PartnerFailure> { .failure(.other) }
}
