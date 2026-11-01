import Foundation

/// Why a clip did not become a text (SPEC-VOICE-001). One case per line the chat can show.
enum VoiceFailure: Error, Equatable {
    case notSetUp
    case tokenRejected
    case busy
    case offline
    case other
}

@MainActor
protocol VoiceTranscribing: AnyObject {
    var isConfigured: Bool { get }
    func transcribe(wav: Data) async -> Result<String, VoiceFailure>
}

/// One `POST /voice` through the configuration's single request builder, modelled on `SnapClient`.
/// It owns no URL session: `send` is handed in, and `live` builds it over an ephemeral session.
@MainActor
final class VoiceClient: VoiceTranscribing {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/voice"
    static let timeout: TimeInterval = 30
    /// The Worker refuses more than this many decoded bytes; a larger clip is refused here without a call.
    static let maxBytes = 1_000_000

    private let config: AppConfig
    private let send: Send

    init(config: AppConfig, send: @escaping Send) {
        self.config = config
        self.send = send
    }

    /// The client the app uses: a fresh ephemeral session per call, so nothing is cached or shared.
    static func live(config: AppConfig) -> VoiceClient {
        VoiceClient(config: config, send: { try await URLSession(configuration: .ephemeral).data(for: $0) })
    }

    var isConfigured: Bool { config.hasProxy }

    func transcribe(wav: Data) async -> Result<String, VoiceFailure> {
        guard config.hasProxy else { return .failure(.notSetUp) }
        guard wav.count <= Self.maxBytes else { return .failure(.other) }
        guard let body = try? JSONSerialization.data(withJSONObject: ["audio": wav.base64EncodedString()],
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let request = config.proxyPOSTRequest(Self.path, body: body, timeout: Self.timeout) else { return .failure(.other) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            return .failure(AgentClient.transportError(for: error) == .offline ? .offline : .other)
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.other) }
        switch http.statusCode {
        case 200:
            return Self.text(from: data).map { .success($0) } ?? .failure(.other)
        case 401:
            return .failure(Self.isUnauthorizedBody(data) ? .tokenRejected : .other)
        case 429:
            return .failure(.busy)
        default:
            return .failure(.other)
        }
    }

    /// Accepts only a JSON object whose `text` is a string. Unknown keys are ignored.
    static func text(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["text"] as? String
    }

    /// The Worker's own rejection of a wrong app token: exactly `{"error":"unauthorized"}`.
    private static func isUnauthorizedBody(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 1 else { return false }
        return object["error"] as? String == "unauthorized"
    }
}
