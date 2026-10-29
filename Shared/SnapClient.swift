import Foundation

/// What a photo shows, as the Worker route `/snap` classifies it (SPEC-CAMSNAP-001).
enum SnapKind: String, Equatable {
    case eventPoster = "event_poster"
    case foodPlace = "food_place"
    case otherPlace = "other_place"
    case unknown
}

/// The clues `/snap` read from one photo. Every text is untrusted; the app never sends one to a model or a log as a sentence.
struct SnapClue: Equatable {
    var kind: SnapKind
    /// The business or venue name as written on a sign.
    var name: String? = nil
    /// A short generic kind of place, such as library.
    var placeType: String? = nil
    var text: String? = nil
    /// Event title and date text, for a poster only.
    var title: String? = nil
    var time: String? = nil
    /// 0...1, clamped by the client.
    var confidence: Double
}

protocol SnapReading {
    var isConfigured: Bool { get }
    func read(imageBase64: String, mime: String) async -> Result<SnapClue, VisionFailure>
}

/// One `POST /snap` through the configuration's single request builder, modelled on `VisionClient`.
/// It owns no URL session: `send` is handed in, and `live` builds it over an ephemeral session.
final class SnapClient: SnapReading {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    private static let path = "/snap"
    private static let timeout: TimeInterval = 60

    private let config: AppConfig
    private let send: Send

    init(config: AppConfig, send: @escaping Send) {
        self.config = config
        self.send = send
    }

    /// The client the app uses: a fresh ephemeral session per call, so nothing is cached or shared.
    static func live(config: AppConfig) -> SnapClient {
        SnapClient(config: config, send: { try await URLSession(configuration: .ephemeral).data(for: $0) })
    }

    var isConfigured: Bool { config.hasProxy }

    func read(imageBase64: String, mime: String) async -> Result<SnapClue, VisionFailure> {
        guard config.hasProxy else { return .failure(.notSetUp) }
        // The Worker caps at 4 MiB; the app sends at most 1 MiB, so a larger image is refused here without a call.
        guard SharedImage.decodedByteCount(ofBase64: imageBase64) <= SharedImage.maxBytes else { return .failure(.imageUnreadable) }
        guard let body = try? JSONSerialization.data(withJSONObject: ["image": imageBase64, "mime": mime],
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
            return Self.clue(from: data).map { .success($0) } ?? .failure(.other)
        case 401:
            return .failure(Self.isUnauthorizedBody(data) ? .tokenRejected : .other)
        case 429:
            return .failure(.busy)
        default:
            return .failure(.other)
        }
    }

    /// Accepts only a JSON object whose `kind` is one of the four values, whose six texts are each a string or null and
    /// whose confidence is a finite number. Unknown keys are ignored.
    static func clue(from data: Data) -> SnapClue? {
        var name: String?
        var placeType: String?
        var text: String?
        var title: String?
        var time: String?
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawKind = object["kind"] as? String, let kind = SnapKind(rawValue: rawKind),
              store(object["name"], into: &name),
              store(object["place_type"], into: &placeType),
              store(object["text"], into: &text),
              store(object["title"], into: &title),
              store(object["time"], into: &time),
              let number = object["confidence"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return SnapClue(kind: kind, name: name, placeType: placeType, text: text, title: title, time: time,
                        confidence: min(1, max(0, number.doubleValue)))
    }

    /// A present string (trimmed, empty becomes nil) or an explicit null is stored; anything else, or a missing key, is invalid.
    private static func store(_ value: Any?, into target: inout String?) -> Bool {
        if value is NSNull { target = nil; return true }
        guard let text = value as? String else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        target = trimmed.isEmpty ? nil : trimmed
        return true
    }

    /// The Worker's own rejection of a wrong app token: exactly `{"error":"unauthorized"}`.
    private static func isUnauthorizedBody(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 1 else { return false }
        return object["error"] as? String == "unauthorized"
    }
}
