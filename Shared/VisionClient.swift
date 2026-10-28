import Foundation

/// What the Worker route `/vision` read from one image. Every field is untrusted text.
struct VisionFields: Equatable {
    var title: String?
    var time: String?
    var place: String?
    /// 0...1, clamped by the client.
    var confidence: Double

    var isEmpty: Bool { title == nil && time == nil && place == nil }
}

/// Why a read did not give fields. The coordinator turns each into one fixed line; no server text is kept.
enum VisionFailure: Error, Equatable {
    case notSetUp, imageUnreadable, tokenRejected, busy, offline, other
}

protocol VisionReading {
    var isConfigured: Bool { get }
    func read(imageBase64: String, mime: String) async -> Result<VisionFields, VisionFailure>
}

/// One `POST /vision` through the configuration's single request builder (SPEC-SHARE-001).
/// Built per import pass from the live configuration; it owns no URL session, the caller hands in `send`.
final class VisionClient: VisionReading {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    private static let path = "/vision"
    private static let timeout: TimeInterval = 60

    private let config: AppConfig
    private let send: Send

    init(config: AppConfig, send: @escaping Send) {
        self.config = config
        self.send = send
    }

    var isConfigured: Bool { config.hasProxy }

    func read(imageBase64: String, mime: String) async -> Result<VisionFields, VisionFailure> {
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
            return Self.fields(from: data).map { .success($0) } ?? .failure(.other)
        case 401:
            return .failure(Self.isUnauthorizedBody(data) ? .tokenRejected : .other)
        case 429:
            return .failure(.busy)
        default:
            return .failure(.other)
        }
    }

    /// Accepts only a JSON object whose title, time and place are a string or null and whose confidence is a finite number.
    static func fields(from data: Data) -> VisionFields? {
        var title: String?
        var time: String?
        var place: String?
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              store(object["title"], into: &title),
              store(object["time"], into: &time),
              store(object["place"], into: &place),
              let number = object["confidence"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return VisionFields(title: title, time: time, place: place, confidence: min(1, max(0, number.doubleValue)))
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
