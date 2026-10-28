import Foundation

/// The four values of one table request, already cleaned by the caller (SPEC-BOOKING-001).
/// There is no field for anything about the person, on purpose: only the table and the place.
struct BookingRequest: Equatable {
    /// A UUID made when the confirmation card was built.
    let requestID: String
    /// The place name as the app cleaned it, at most 80 Unicode scalars.
    let restaurant: String
    let partySize: Int
    /// A local date-time, `yyyy-MM-dd'T'HH:mm`.
    let start: String
}

/// Why a booking did not give an answer. No text of the server's answer is kept for any of them.
enum BookingFailure: Error, Equatable {
    case notSetUp, offline, tokenRejected, other
}

enum BookingAnswer: Equatable {
    case confirmed(code: String)
    case declined
}

/// One `POST /booking` through the configuration's single request builder. Built per booking from the live configuration;
/// it owns no URL session, the caller hands in `send`.
final class BookingClient {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    /// The simulated partner's name: the app's one literal for it.
    static let partnerName = "Example Tables"

    private static let path = "/booking"
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

    /// Sends the request and records the packets of the exchange under `flow`. Recording never changes the result.
    func book(_ request: BookingRequest, flow: UUID) async -> Result<BookingAnswer, BookingFailure> {
        guard config.hasProxy else { return .failure(.notSetUp) }
        let fields: [String: Any] = ["request_id": request.requestID, "restaurant": request.restaurant,
                                     "party_size": request.partySize, "start": request.start]
        guard !Task.isCancelled,
              let body = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let urlRequest = config.proxyPOSTRequest(Self.path, body: body, timeout: Self.timeout) else { return .failure(.other) }
        let result = await exchange(urlRequest, sent: request)
        // A cancelled task records nothing: the outcome is not known.
        guard !Task.isCancelled else { return .failure(.other) }
        note(result, sent: request, flow: flow)
        return result
    }

    private func exchange(_ urlRequest: URLRequest, sent: BookingRequest) async -> Result<BookingAnswer, BookingFailure> {
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
            return Self.answer(from: data, sent: sent).map { .success($0) } ?? .failure(.other)
        case 401:
            return .failure(Self.isUnauthorizedBody(data) ? .tokenRejected : .other)
        default:
            return .failure(.other)
        }
    }

    /// The summaries hold fixed words and the party size only: never the place, the time, the code or any answer text.
    private func note(_ result: Result<BookingAnswer, BookingFailure>, sent: BookingRequest, flow: UUID) {
        switch result {
        case .success(let answer):
            connections.record(from: .besir, to: .bookingPartner, kind: .booking,
                               summary: "Table for \(sent.partySize) requested", status: .ok, flowID: flow)
            switch answer {
            case .confirmed:
                connections.record(from: .bookingPartner, to: .besir, kind: .booking,
                                   summary: "Reservation confirmed", status: .ok, flowID: flow)
            case .declined:
                connections.record(from: .bookingPartner, to: .besir, kind: .booking,
                                   summary: "No table available", status: .declined, flowID: flow)
            }
        case .failure(let failure):
            // A request that was never sent (no proxy) returned before this point.
            guard failure != .notSetUp else { return }
            connections.record(from: .besir, to: .bookingPartner, kind: .booking,
                               summary: "Request failed", status: .failed, flowID: flow)
        }
    }

    // MARK: The answer is checked

    /// Accepts only the exact object the route sends: seven keys, the partner, `simulated` true, the echoes equal to what was
    /// sent, and either a code of the right shape (confirmed) or the reason `no_table` (declined).
    static func answer(from data: Data, sent: BookingRequest) -> BookingAnswer? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object.count == 7,
              let status = object["status"] as? String,
              object["partner"] as? String == partnerName,
              isTrue(object["simulated"]),
              object["restaurant"] as? String == sent.restaurant,
              isNumber(object["party_size"], equalTo: sent.partySize),
              object["start"] as? String == sent.start else { return nil }
        switch status {
        case "confirmed":
            guard object["reason"] == nil, let code = object["reservation_code"] as? String, isCode(code) else { return nil }
            return .confirmed(code: code)
        case "declined":
            guard object["reservation_code"] == nil, object["reason"] as? String == "no_table" else { return nil }
            return .declined
        default:
            return nil
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, isBoolean(number) else { return false }
        return number.boolValue
    }

    private static func isNumber(_ value: Any?, equalTo expected: Int) -> Bool {
        guard let number = value as? NSNumber, !isBoolean(number) else { return false }
        return number.doubleValue == Double(expected)
    }

    /// `EX-` and six of `A-Z0-9`, ASCII only.
    private static func isCode(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 9, String(String.UnicodeScalarView(scalars.prefix(3))) == "EX-" else { return false }
        return scalars.suffix(6).allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The Worker's own rejection of a wrong app token: exactly `{"error":"unauthorized"}`.
    private static func isUnauthorizedBody(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 1 else { return false }
        return object["error"] as? String == "unauthorized"
    }
}
