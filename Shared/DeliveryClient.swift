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

/// What the partner's options answer holds: the menu, the order form and the delivery fee. The prices exist only here, so the
/// total of an order is computed from this and nowhere else (SPEC-DELIVERY-001).
struct DeliveryOptions: Equatable {
    let menu: [DeliveryMenuItem]
    /// The partner's order form, already validated; the cards are the options of its `card_id` field.
    let fields: [PartnerField]
    let deliveryFeeCents: Int

    /// The cards, derived from the options of the `card_id` field: the one source of both the chips and the accepted ids.
    var cards: [DeliveryCard] {
        (fields.first { $0.key == DeliveryClient.cardKey }?.options ?? []).map { DeliveryCard(id: $0.id, label: $0.label) }
    }

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
    /// The keys of the three fields the delivery adapter knows, with the kind each has to be.
    static let arriveKey = "arrive_at"
    static let addressKey = "address"
    static let cardKey = "card_id"
    private static let knownFields: [String: PartnerFieldKind] = [arriveKey: .time, addressKey: .place, cardKey: .pickOne]
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

    /// Asks for the menu, the order form and the fee, and records the packets of the exchange under `flow`.
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
    /// entries (unique lower-case ids, printable ASCII names, prices of 1 to 100000 cents), a fee of 0 to 10000 cents and an
    /// `order_fields` list that obeys `PartnerForm` and, for this adapter, holds exactly `arrive_at` (time), `address` (place)
    /// and `card_id` (pick_one), each once, in any order, and no `on_off` field: the delivery partner has none.
    static func optionsAnswer(from data: Data) -> DeliveryOptions? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object.count == 5,
              object["partner"] as? String == partnerName,
              isTrue(object["simulated"]),
              let menuValues = object["menu"] as? [[String: Any]], (1...12).contains(menuValues.count),
              let fee = PartnerForm.integer(object["delivery_fee_cents"]), (0...10000).contains(fee),
              let fields = PartnerForm.fields(from: object["order_fields"]), isDeliveryForm(fields) else { return nil }
        var menu: [DeliveryMenuItem] = []
        for entry in menuValues {
            guard entry.count == 3,
                  let id = entry["id"] as? String, isItemID(id), !menu.contains(where: { $0.id == id }),
                  let name = entry["name"] as? String, isMenuName(name),
                  let price = PartnerForm.integer(entry["price_cents"]), (1...100000).contains(price) else { return nil }
            menu.append(DeliveryMenuItem(id: id, name: name, priceCents: price))
        }
        return DeliveryOptions(menu: menu, fields: fields, deliveryFeeCents: fee)
    }

    /// The adapter rule: the three known keys, each once, each of its own kind and each required. A duplicate is already
    /// refused by `PartnerForm`; an optional field is refused here because the delivery order has no field it may leave out.
    private static func isDeliveryForm(_ fields: [PartnerField]) -> Bool {
        fields.count == knownFields.count && fields.allSatisfy { knownFields[$0.key] == $0.kind && !$0.isOptional }
    }

    /// Accepts only the exact object the route sends for an order: the partner, `simulated` true, the echoes equal to what was
    /// sent, and either `confirmed` (ten keys: an order id of the right shape and a `results` list that obeys `PartnerForm`
    /// and holds the one `time` item equal to the wanted arrival and the one `money` item equal to the total by the held
    /// options' rule) or `declined` (nine keys: the reason `outside_hours`); the status has to agree with the hours rule.
    static func answer(from data: Data, sent: DeliveryRequest, options: DeliveryOptions) -> DeliveryAnswer? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = object["status"] as? String,
              object["partner"] as? String == partnerName,
              isTrue(object["simulated"]),
              object["restaurant"] as? String == sent.restaurant,
              object["arrive_at"] as? String == sent.arriveAt,
              linesMatch(object["items"], sent.items),
              object["address"] as? String == sent.address,
              object["card_id"] as? String == sent.cardID,
              let minute = PartnerForm.minuteOfDay(sent.arriveAt),
              let total = options.totalCents(for: sent.items) else { return nil }
        let isOpen = (openMinute...closeMinute).contains(minute)
        switch status {
        case "confirmed":
            guard isOpen, object.count == 10, object["reason"] == nil,
                  let orderID = object["order_id"] as? String, isOrderID(orderID),
                  let results = PartnerForm.results(from: object["results"]),
                  results.arrival == sent.arriveAt, results.moneyCents == total else { return nil }
            return .confirmed(orderID: orderID, results: results)
        case "declined":
            guard !isOpen, object.count == 9, object["order_id"] == nil, object["reason"] as? String == "outside_hours" else { return nil }
            return .declined
        default:
            return nil
        }
    }

    /// The echoed lines: the same count, the same order, exactly `item_id` and `quantity` in each.
    private static func linesMatch(_ value: Any?, _ lines: [DeliveryLine]) -> Bool {
        guard let echoed = value as? [[String: Any]], echoed.count == lines.count else { return false }
        return zip(echoed, lines).allSatisfy { echo, line in
            echo.count == 2 && echo["item_id"] as? String == line.itemID && isNumber(echo["quantity"], equalTo: line.quantity)
        }
    }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, PartnerForm.isBoolean(number) else { return false }
        return number.boolValue
    }

    private static func isNumber(_ value: Any?, equalTo expected: Int) -> Bool { PartnerForm.integer(value) == expected }

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

    /// `DL-` and six of `A-Z0-9`, ASCII only.
    private static func isOrderID(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 9, String(String.UnicodeScalarView(scalars.prefix(3))) == "DL-" else { return false }
        return scalars.suffix(6).allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The Worker's own rejection of a wrong app token: exactly `{"error":"unauthorized"}`.
    private static func isUnauthorizedBody(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 1 else { return false }
        return object["error"] as? String == "unauthorized"
    }
}
