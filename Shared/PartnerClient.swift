import Foundation

/// SPEC-BOOKCARD-001 (card t89): the one client of the partner path. It names no partner. It asks the proxy for the directory,
/// asks an entry's route for its form and sends a request to that route. Built per call from the live configuration; it owns
/// no URL session, the caller hands in `send`.
final class PartnerClient {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    private static let timeout: TimeInterval = 20

    private let config: AppConfig
    private let send: Send
    private let connections: ConnectionLog

    init(config: AppConfig, send: @escaping Send, connections: ConnectionLog = ConnectionLog.shared) {
        self.config = config
        self.send = send
        self.connections = connections
    }

    var isConfigured: Bool { config.hasProxy }

    /// Asks the directory route which partners there are. Records `Partners requested` and `Partners received`.
    func directory(flow: UUID) async -> Result<[PartnerEntry], PartnerFailure> {
        await call(path: PartnerEntry.directoryPath, body: ["op": "list"], flow: flow, read: { PartnerEntry.list(from: $0) },
                   words: { _ in ("Partners requested", "Partners received", .ok) })
    }

    /// Asks an entry's route for its form. Records `<name>: Fields requested` and `<name>: Fields received`.
    func form(of entry: PartnerEntry, flow: UUID) async -> Result<PartnerSpec, PartnerFailure> {
        await call(path: entry.route, body: ["op": "fields"], flow: flow, read: { PartnerSpec.form(from: $0, entry: entry) },
                   words: { _ in ("\(entry.name): Fields requested", "\(entry.name): Fields received", .ok) })
    }

    /// Sends a request to the entry's route. Records `<name>: Request sent`, then `<name>: Request confirmed` or
    /// `<name>: Request declined`. No summary holds a value.
    func submit(_ request: PartnerRequest, to spec: PartnerSpec, flow: UUID) async -> Result<PartnerAnswer, PartnerFailure> {
        let name = spec.entry.name
        return await call(path: spec.entry.route, body: request.body, flow: flow, read: { PartnerAnswer.answer(from: $0, spec: spec) },
                          words: { answer in
                              switch answer {
                              case .confirmed: return ("\(name): Request sent", "\(name): Request confirmed", .ok)
                              case .declined: return ("\(name): Request sent", "\(name): Request declined", .declined)
                              }
                          })
    }

    /// Asks an entry's route for the places it finds for the text typed in one of its own lookup fields. Sends nothing (and fails
    /// with `other`) for a key that is not a marked field of `spec` or a text under two code points once normalised. Records
    /// `<name>: Candidates requested` and `<name>: Candidates received`; no summary holds the text, a candidate or a coordinate.
    func candidates(of spec: PartnerSpec, field: String, text: String, near: (latitude: Double, longitude: Double)?,
                    flow: UUID) async -> Result<[Place], PartnerFailure> {
        guard spec.fields.contains(where: { $0.key == field && $0.canLookUp }),
              let lookupText = PartnerCandidates.requestText(text) else { return .failure(.other) }
        let name = spec.entry.name
        return await call(path: spec.entry.route, body: PartnerCandidates.body(field: field, text: lookupText, near: near), flow: flow,
                          read: { PartnerCandidates.list(from: $0, spec: spec, field: field) },
                          words: { _ in ("\(name): Candidates requested", "\(name): Candidates received", .ok) })
    }

    // MARK: The exchange

    /// One request, one checked answer and the packets of the exchange under `flow`. Recording never changes the result.
    private func call<Value>(path: String, body: [String: Any], flow: UUID, read: (Data) -> Value?,
                             words: (Value) -> (sent: String, received: String, status: ConnectionStatus)) async -> Result<Value, PartnerFailure> {
        guard config.hasProxy else { return .failure(.notSetUp) }
        guard !Task.isCancelled,
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]),
              let urlRequest = config.proxyPOSTRequest(path, body: data, timeout: Self.timeout) else { return .failure(.other) }
        let result = await exchange(urlRequest, read: read)
        // A cancelled task records nothing: the outcome is not known.
        guard !Task.isCancelled else { return .failure(.other) }
        switch result {
        case .success(let value):
            let summaries = words(value)
            connections.record(from: .besir, to: .partner, kind: .partner, summary: summaries.sent, status: .ok, flowID: flow)
            connections.record(from: .partner, to: .besir, kind: .partner, summary: summaries.received, status: summaries.status, flowID: flow)
        case .failure(let failure):
            // A request that was never sent (no proxy) returned before this point. A failure has no name: it may happen before
            // any entry is known.
            guard failure != .notSetUp else { break }
            connections.record(from: .besir, to: .partner, kind: .partner, summary: "Request failed", status: .failed, flowID: flow)
        }
        return result
    }

    /// The one place that sends, reads the status and handles a rejected token, for all three calls.
    private func exchange<Value>(_ urlRequest: URLRequest, read: (Data) -> Value?) async -> Result<Value, PartnerFailure> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(urlRequest)
        } catch {
            return .failure(AgentClient.transportError(for: error) == .offline ? .offline : .other)
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.other) }
        switch http.statusCode {
        case 200:
            return read(data).map { .success($0) } ?? .failure(.other)
        case 401:
            return .failure(Self.isUnauthorizedBody(data) ? .tokenRejected : .other)
        default:
            return .failure(.other)
        }
    }

    /// The Worker's own rejection of a wrong app token: exactly `{"error":"unauthorized"}`.
    private static func isUnauthorizedBody(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 1 else { return false }
        return object["error"] as? String == "unauthorized"
    }
}
