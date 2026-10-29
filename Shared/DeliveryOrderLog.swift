import Foundation

/// One item line of a stored order: the menu id, the name and the unit price as the order was made. Whole cents.
struct DeliveryOrderItem: Codable, Equatable {
    let itemID: String
    let name: String
    let quantity: Int
    let unitPriceCents: Int
}

/// One confirmed order as the device keeps it (SPEC-DELIVERY-001 L17). The fields are the ones the order record is allowed to
/// hold; there is no field for a person, a position or a payment, on purpose.
struct DeliveryOrderEntry: Codable, Equatable {
    /// The partner's order id, `DL-` and six characters.
    let orderID: String
    /// A UUID made when the confirmation card was built; the same id is never stored twice.
    let requestID: String
    let placeName: String
    /// The wanted arrival time as a local date-time, `yyyy-MM-dd'T'HH:mm`.
    let arrival: String
    let items: [DeliveryOrderItem]
    /// The delivery text as it was confirmed in the card.
    let address: String
    /// The partner's own label of the card, nothing more.
    let cardLabel: String
    let estimatedTotalCents: Int
    let createdAt: Date
    /// The id of the meal entry the same Confirm added to the schedule, if one was added.
    let mealActivityID: String?
}

/// The orders the device has made, in one JSON file and one capped list. Written here and read back by no other function of the
/// app (the log loads its own file to start, to refuse a repeat and to keep the cap); a later card reads it. It never throws
/// and never gets in the way of the order it belongs to: a failed file write leaves the in-memory list as it is.
final class DeliveryOrderLog: @unchecked Sendable {
    static let fileName = "delivery-orders.json"
    static let maxEntries = 200

    private let fileURL: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private let limit: Int

    private let lock = NSLock()
    private var entries: [DeliveryOrderEntry] = []

    init(fileURL: URL,
         write: @escaping @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite,
         maxEntries: Int = DeliveryOrderLog.maxEntries) {
        self.fileURL = fileURL
        self.write = write
        self.limit = maxEntries
        self.entries = Self.load(fileURL, limit: maxEntries)
    }

    /// The log the app uses. Under tests `AppConfig.supportDirectory` is a throw-away folder.
    static let shared = DeliveryOrderLog(fileURL: AppConfig.supportDirectory.appendingPathComponent(DeliveryOrderLog.fileName))

    // MARK: Read

    /// The stored orders, oldest first. For tests only: no function of the app reads the record (SPEC-DELIVERY-001 L17, S12).
    var orders: [DeliveryOrderEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    // MARK: Write

    /// Appends one entry, dropping the oldest past the cap. Returns false, and changes nothing, when the order id or the request
    /// id is already in the list. The file is written before the lock is released, so the writes happen in call order.
    @discardableResult
    func add(_ entry: DeliveryOrderEntry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.contains(where: { $0.orderID == entry.orderID || $0.requestID == entry.requestID }) else { return false }
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        if let data = try? Self.encoder.encode(entries) { try? write(data, fileURL) }
        return true
    }

    // MARK: Load

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private struct Lossy: Decodable {
        let entry: DeliveryOrderEntry?
        init(from decoder: Decoder) throws { entry = try? DeliveryOrderEntry(from: decoder) }
    }

    /// A missing, empty or undecodable file gives an empty list; an entry that cannot be decoded is dropped alone.
    private static func load(_ url: URL, limit: Int) -> [DeliveryOrderEntry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let all = try? decoder.decode([Lossy].self, from: data) else { return [] }
        return Array(all.compactMap(\.entry).suffix(limit))
    }
}
