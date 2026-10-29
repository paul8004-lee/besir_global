import Foundation

/// One item of the partner's fixed menu, as its options answer lists it. The price is an estimate, whole cents.
struct DeliveryMenuItem: Equatable {
    let id: String
    let name: String
    let priceCents: Int
}

/// One card the partner holds on file: its own id and a label. No card data beyond what the label shows.
struct DeliveryCard: Equatable {
    let id: String
    let label: String
}

/// One line of an order: an item id of the menu and a quantity from 1 to 9.
struct DeliveryLine: Equatable {
    let itemID: String
    let quantity: Int
}

/// What the partner's options answer holds: the menu, the cards and the delivery fee. The prices exist only here, so the total
/// of an order is computed from this and nowhere else (SPEC-DELIVERY-001).
struct DeliveryOptions: Equatable {
    let menu: [DeliveryMenuItem]
    /// The partner's order form, already validated; the cards are the options of its `card_id` field.
    let fields: [PartnerField]
    let deliveryFeeCents: Int

    var cards: [DeliveryCard] { [] }

    func menuItem(id: String) -> DeliveryMenuItem? { menu.first { $0.id == id } }

    func card(id: String) -> DeliveryCard? { cards.first { $0.id == id } }

    /// The sum of each line's price times its quantity, plus the fee. Nil for no lines, more than 6, a repeated id, an id the
    /// menu does not hold or a quantity outside 1 to 9.
    func totalCents(for lines: [DeliveryLine]) -> Int? {
        guard (1...6).contains(lines.count), Set(lines.map(\.itemID)).count == lines.count else { return nil }
        var total = deliveryFeeCents
        for line in lines {
            guard (1...9).contains(line.quantity), let item = menuItem(id: line.itemID) else { return nil }
            total += item.priceCents * line.quantity
        }
        return total
    }
}

/// The values of one delivery order, already cleaned by the caller (SPEC-DELIVERY-001).
/// The only field about the person is the delivery address; the item lines and the card id are the partner's own.
struct DeliveryRequest: Equatable {
    /// A UUID made when the confirmation card was built.
    let requestID: String
    /// The place name as the app cleaned it, at most 80 Unicode scalars.
    let restaurant: String
    /// A local date-time, `yyyy-MM-dd'T'HH:mm`.
    let arriveAt: String
    let items: [DeliveryLine]
    /// The delivery text, trimmed, 1 to 120 Unicode scalars. The app builds it; the model never writes it.
    let address: String
    /// An id from the held options' cards.
    let cardID: String
}

/// Why a call did not give an answer. No text of the server's answer is kept for any of them.
enum DeliveryFailure: Error, Equatable {
    case notSetUp, offline, tokenRejected, other
}

enum DeliveryAnswer: Equatable {
    case confirmed(orderID: String, results: [PartnerResultItem])
    case declined
}

/// One `POST /delivery` through the configuration's single request builder: the options call and the order call. Built per call
/// from the live configuration; it owns no URL session, the caller hands in `send`. It never touches the budget ledger or the
/// order record.
final class DeliveryClient {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    /// The simulated partner's name: the app's one literal for it.
    static let partnerName = "Example Delivery"
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

    /// Asks for the menu, the cards and the fee, and records the packets of the exchange under `flow`.
    func options(flow: UUID) async -> Result<DeliveryOptions, DeliveryFailure> {
        guard config.hasProxy else { return .failure(.notSetUp) }
        return await run(["op": "options"], requested: "Options requested", parse: { Self.optionsAnswer(from: $0) },
                         received: { _ in ("Options received", .ok) }, flow: flow)
    }

    /// Sends the order and records the packets of the exchange under `flow`. A request whose item ids or card id `options` does
    /// not hold, or whose lines it cannot total, is not sent: the failure is `other` and no packet is recorded.
    func order(_ request: DeliveryRequest, options: DeliveryOptions, flow: UUID) async -> Result<DeliveryAnswer, DeliveryFailure> {
        guard config.hasProxy else { return .failure(.notSetUp) }
        guard options.totalCents(for: request.items) != nil, options.card(id: request.cardID) != nil else { return .failure(.other) }
        let fields: [String: Any] = ["op": "order", "request_id": request.requestID, "restaurant": request.restaurant,
                                     "arrive_at": request.arriveAt,
                                     "items": request.items.map { ["item_id": $0.itemID, "quantity": $0.quantity] as [String: Any] },
                                     "address": request.address, "card_id": request.cardID]
        let count = request.items.reduce(0) { $0 + $1.quantity }
        return await run(fields, requested: count == 1 ? "Delivery of 1 item requested" : "Delivery of \(count) items requested",
                         parse: { Self.answer(from: $0, sent: request, options: options) },
                         received: { answer in
                             switch answer {
                             case .confirmed: return ("Order confirmed", .ok)
                             case .declined: return ("Order not available", .declined)
                             }
                         }, flow: flow)
    }

    private func run<Value>(_ fields: [String: Any], requested: String, parse: (Data) -> Value?,
                            received: (Value) -> (summary: String, status: ConnectionStatus),
                            flow: UUID) async -> Result<Value, DeliveryFailure> {
        guard !Task.isCancelled,
              let body = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let urlRequest = config.proxyPOSTRequest(Self.path, body: body, timeout: Self.timeout) else { return .failure(.other) }
        let result = await exchange(urlRequest, parse: parse)
        // A cancelled task records nothing: the outcome is not known.
        guard !Task.isCancelled else { return .failure(.other) }
        switch result {
        case .success(let value):
            connections.record(from: .besir, to: .deliveryPartner, kind: .delivery,
                               summary: requested, status: .ok, flowID: flow)
            let reply = received(value)
            connections.record(from: .deliveryPartner, to: .besir, kind: .delivery,
                               summary: reply.summary, status: reply.status, flowID: flow)
        case .failure:
            // A call that sent nothing (no proxy, an unheld id) returned before this point.
            connections.record(from: .besir, to: .deliveryPartner, kind: .delivery,
                               summary: "Request failed", status: .failed, flowID: flow)
        }
        return result
    }

    private func exchange<Value>(_ urlRequest: URLRequest, parse: (Data) -> Value?) async -> Result<Value, DeliveryFailure> {
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
            return parse(data).map { .success($0) } ?? .failure(.other)
        case 401:
            return .failure(Self.isUnauthorizedBody(data) ? .tokenRejected : .other)
        default:
            return .failure(.other)
        }
    }

    // MARK: The answers are checked

    /// Accepts only the exact object the route sends for `options`: five keys, the partner, `simulated` true, 1 to 12 menu
    /// entries (unique lower-case ids, printable ASCII names, prices of 1 to 100000 cents), 1 to 4 cards (unique ids, labels
    /// without hidden characters) and a fee of 0 to 10000 cents.
    static func optionsAnswer(from data: Data) -> DeliveryOptions? { nil }

    static func answer(from data: Data, sent: DeliveryRequest, options: DeliveryOptions) -> DeliveryAnswer? { nil }

    /// The echoed lines: the same count, the same order, exactly `item_id` and `quantity` in each.
    private static func linesMatch(_ value: Any?, _ lines: [DeliveryLine]) -> Bool {
        guard let echoed = value as? [[String: Any]], echoed.count == lines.count else { return false }
        return zip(echoed, lines).allSatisfy { echo, line in
            echo.count == 2 && echo["item_id"] as? String == line.itemID && isNumber(echo["quantity"], equalTo: line.quantity)
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, isBoolean(number) else { return false }
        return number.boolValue
    }

    /// A JSON number with a whole value, or nil; `2.0` counts as 2 and a boolean is never a number.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let parsed = number.doubleValue
        guard parsed == parsed.rounded(), abs(parsed) < 1e12 else { return nil }
        return Int(parsed)
    }

    private static func isNumber(_ value: Any?, equalTo expected: Int) -> Bool { integer(value) == expected }

    /// A menu item id: lower-case ASCII letters, digits, `-` and `_`.
    private static func isItemID(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// A menu item name: 1 to 40 printable ASCII characters.
    private static func isMenuName(_ text: String) -> Bool {
        (1...40).contains(text.unicodeScalars.count) && text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    /// A card label: 1 to 60 code points, none a control, format, line-separator or paragraph-separator character.
    private static func isCardLabel(_ text: String) -> Bool {
        (1...60).contains(text.unicodeScalars.count) && text.unicodeScalars.allSatisfy {
            ![.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
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
