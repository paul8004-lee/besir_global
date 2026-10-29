import Foundation

/// The four values of one delivery order, already cleaned by the caller (SPEC-DELIVERY-001).
/// There is no field for anything about the person, on purpose: only the place, the people count and the arrival time.
struct DeliveryRequest: Equatable {
    /// A UUID made when the confirmation card was built.
    let requestID: String
    /// The place name as the app cleaned it, at most 80 Unicode scalars.
    let restaurant: String
    let people: Int
    /// A local date-time, `yyyy-MM-dd'T'HH:mm`.
    let arriveAt: String
}

/// Why an order did not give an answer. No text of the server's answer is kept for any of them.
enum DeliveryFailure: Error, Equatable {
    case notSetUp, offline, tokenRejected, other
}

enum DeliveryAnswer: Equatable {
    case confirmed(orderID: String, estimatedTotalCents: Int)
    case declined
}

/// One `POST /delivery` through the configuration's single request builder. Built per order from the live configuration;
/// it owns no URL session, the caller hands in `send`. It never touches the budget ledger.
final class DeliveryClient {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    /// The simulated partner's name: the app's one literal for it.
    static let partnerName = "Example Delivery"
    /// The partner's estimate rule: $22.00 a person plus a $5.00 delivery fee, in cents.
    static let perPersonCents = 2200
    static let feeCents = 500
    /// The partner's hours as minutes of the day: 10:00 to 22:00, both ends included.
    static let openMinute = 600
    static let closeMinute = 1320

    private static let path = "/delivery"
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
    func order(_ request: DeliveryRequest, flow: UUID) async -> Result<DeliveryAnswer, DeliveryFailure> {
        guard config.hasProxy else { return .failure(.notSetUp) }
        let fields: [String: Any] = ["request_id": request.requestID, "restaurant": request.restaurant,
                                     "people": request.people, "arrive_at": request.arriveAt]
        guard !Task.isCancelled,
              let body = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let urlRequest = config.proxyPOSTRequest(Self.path, body: body, timeout: Self.timeout) else { return .failure(.other) }
        let result = await exchange(urlRequest, sent: request)
        // A cancelled task records nothing: the outcome is not known.
        guard !Task.isCancelled else { return .failure(.other) }
        note(result, sent: request, flow: flow)
        return result
    }

    private func exchange(_ urlRequest: URLRequest, sent: DeliveryRequest) async -> Result<DeliveryAnswer, DeliveryFailure> {
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

    /// The summaries hold fixed words and the people count only: never the place, the time, the order id or any answer text.
    private func note(_ result: Result<DeliveryAnswer, DeliveryFailure>, sent: DeliveryRequest, flow: UUID) {
        switch result {
        case .success(let answer):
            connections.record(from: .besir, to: .deliveryPartner, kind: .delivery,
                               summary: "Delivery for \(sent.people) requested", status: .ok, flowID: flow)
            switch answer {
            case .confirmed:
                connections.record(from: .deliveryPartner, to: .besir, kind: .delivery,
                                   summary: "Order confirmed", status: .ok, flowID: flow)
            case .declined:
                connections.record(from: .deliveryPartner, to: .besir, kind: .delivery,
                                   summary: "Order not available", status: .declined, flowID: flow)
            }
        case .failure(let failure):
            // A request that was never sent (no proxy) returned before this point.
            guard failure != .notSetUp else { return }
            connections.record(from: .besir, to: .deliveryPartner, kind: .delivery,
                               summary: "Request failed", status: .failed, flowID: flow)
        }
    }

    // MARK: The answer is checked

    /// Accepts only the exact object the route sends: nine keys when confirmed (an order id of the right shape, the arrival
    /// estimate equal to the wanted time, the total by the estimate rule) or seven when declined (the reason `outside_hours`),
    /// the partner, `simulated` true, the echoes equal to what was sent, and a status that agrees with the hours rule.
    static func answer(from data: Data, sent: DeliveryRequest) -> DeliveryAnswer? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = object["status"] as? String,
              object["partner"] as? String == partnerName,
              isTrue(object["simulated"]),
              object["restaurant"] as? String == sent.restaurant,
              isNumber(object["people"], equalTo: sent.people),
              object["arrive_at"] as? String == sent.arriveAt,
              let minute = minuteOfDay(sent.arriveAt) else { return nil }
        let isOpen = (openMinute...closeMinute).contains(minute)
        switch status {
        case "confirmed":
            let total = sent.people * perPersonCents + feeCents
            guard isOpen, object.count == 9, object["reason"] == nil,
                  let orderID = object["order_id"] as? String, isOrderID(orderID),
                  object["arrival_estimate"] as? String == sent.arriveAt,
                  isNumber(object["estimated_total_cents"], equalTo: total) else { return nil }
            return .confirmed(orderID: orderID, estimatedTotalCents: total)
        case "declined":
            guard !isOpen, object.count == 7, object["order_id"] == nil, object["reason"] as? String == "outside_hours" else { return nil }
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

    /// A JSON number equal to `expected`; `2.0` counts as 2 and a boolean is never a number.
    private static func isNumber(_ value: Any?, equalTo expected: Int) -> Bool {
        guard let number = value as? NSNumber, !isBoolean(number) else { return false }
        return number.doubleValue == Double(expected)
    }

    /// `DL-` and six of `A-Z0-9`, ASCII only.
    private static func isOrderID(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 9, String(String.UnicodeScalarView(scalars.prefix(3))) == "DL-" else { return false }
        return scalars.suffix(6).allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The minute of the day of a `yyyy-MM-dd'T'HH:mm` text, or nil for any other form.
    private static func minuteOfDay(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard bytes.count == 16, bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":") else { return nil }
        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let hour = digits(11..<13), let minute = digits(14..<16), hour < 24, minute < 60 else { return nil }
        return hour * 60 + minute
    }

    /// The Worker's own rejection of a wrong app token: exactly `{"error":"unauthorized"}`.
    private static func isUnauthorizedBody(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 1 else { return false }
        return object["error"] as? String == "unauthorized"
    }
}
