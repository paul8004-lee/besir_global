import Foundation

/// What the device keeps about one booked entry so a later scene can find the partner request that made it (SPEC-LATESWITCH-001).
/// The fields are the ones the record is allowed to hold; there is no field for a person, a payment, an address, a coordinate or
/// a time, on purpose. It names no partner and no kind of partner: the partner is whichever one answered.
struct PartnerRecord: Codable, Equatable {
    /// The entry the partner request made.
    let activityID: UUID
    /// The partner's id, name and route as the directory gave them.
    let partnerID: String
    let partnerName: String
    let route: String
    /// The request id of the partner request (a UUID made when the card was built).
    let requestID: String
    /// The partner's answered `money` item in whole cents, if the answer held one.
    let estimateCents: Int?
    /// The value sent for the partner's one `number` field when its field list holds exactly one, else nil.
    let quantityHint: Int?
    /// The request id of the estimated spend, kept only when the budget partner recorded it.
    let spendRequestID: String?
    /// True once a switch for this entry was started; written to disk before the request that starts it.
    var switchStarted: Bool

    private enum CodingKeys: String, CodingKey {
        case activityID, partnerID, partnerName, route, requestID, estimateCents, quantityHint, spendRequestID, switchStarted
    }

    /// Every key is written, a missing value as null, so the stored shape never changes with the values.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activityID, forKey: .activityID)
        try container.encode(partnerID, forKey: .partnerID)
        try container.encode(partnerName, forKey: .partnerName)
        try container.encode(route, forKey: .route)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(estimateCents, forKey: .estimateCents)
        try container.encode(quantityHint, forKey: .quantityHint)
        try container.encode(spendRequestID, forKey: .spendRequestID)
        try container.encode(switchStarted, forKey: .switchStarted)
    }
}

/// The records of the entries partner requests made, in one JSON file and one capped list. It never throws and never gets in the
/// way of the request it belongs to: a failed file write leaves the in-memory list as it is, except a failed mark of
/// `switchStarted` true (see `setSwitchStarted`).
final class PartnerRecords: @unchecked Sendable {
    static let fileName = "partner-records.json"
    static let maxEntries = 50

    private let fileURL: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private let limit: Int

    private let lock = NSLock()
    private var entries: [PartnerRecord] = []

    init(fileURL: URL,
         write: @escaping @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite,
         maxEntries: Int = PartnerRecords.maxEntries) {
        self.fileURL = fileURL
        self.write = write
        self.limit = maxEntries
        self.entries = Self.load(fileURL, limit: maxEntries)
    }

    /// The store the app uses. Under tests `AppConfig.supportDirectory` is a throw-away folder.
    static let shared = PartnerRecords(fileURL: AppConfig.supportDirectory.appendingPathComponent(PartnerRecords.fileName))

    // MARK: Read

    func record(forActivity id: UUID) -> PartnerRecord? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.activityID == id }
    }

    /// The stored records, oldest first. For tests only: the app reads one record at a time.
    var records: [PartnerRecord] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    // MARK: Write

    /// Appends one record, dropping the oldest past the cap. Returns false, and changes nothing, when the entry already has a
    /// record. The file is written before the lock is released, so the writes happen in call order.
    @discardableResult
    func add(_ record: PartnerRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.contains(where: { $0.activityID == record.activityID }) else { return false }
        entries.append(record)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        save()
        return true
    }

    /// Removes the record of an entry. True when one was removed.
    @discardableResult
    func remove(activityID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.activityID == activityID }) else { return false }
        entries.remove(at: index)
        save()
        return true
    }

    /// Sets the mark and writes the file at once. True when the record now holds the mark asked for in memory. Setting `true`
    /// is the one write that must reach the disk: when it fails the mark stays false in memory and the answer is false, so
    /// nothing is sent on the strength of a mark that a killed app would not find. Clearing that fails leaves the mark false in
    /// memory and the file as it was until the next good write. False for an entry without a record.
    @discardableResult
    func setSwitchStarted(_ started: Bool, forActivity id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.activityID == id }) else { return false }
        var changed = entries
        changed[index].switchStarted = started
        guard let data = try? JSONEncoder().encode(changed) else { return false }
        do {
            try write(data, fileURL)
        } catch {
            guard !started else { return false }
        }
        entries = changed
        return true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? write(data, fileURL) }
    }

    // MARK: Load

    private struct Lossy: Decodable {
        let record: PartnerRecord?
        init(from decoder: Decoder) throws { record = try? PartnerRecord(from: decoder) }
    }

    /// A missing, empty or undecodable file gives an empty list; a record that cannot be decoded is dropped alone.
    private static func load(_ url: URL, limit: Int) -> [PartnerRecord] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let all = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        var seen = Set<UUID>()
        let kept = all.compactMap(\.record).filter { seen.insert($0.activityID).inserted }
        return Array(kept.suffix(limit))
    }
}
