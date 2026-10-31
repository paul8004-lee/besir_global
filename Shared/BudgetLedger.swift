import Foundation

/// One amount the device sent to the budget partner (SPEC-BUDGET-001). Whole cents, the week and the request id, and nothing
/// else: there is no field for a place, a title, a time, a person or a payment, on purpose.
struct BudgetEntry: Codable, Equatable {
    /// A UUID made when the spend was made; the same id is never counted twice.
    let requestID: String
    /// The Monday of the week the amount counts in, `yyyy-MM-dd` (`BudgetWeek.start`).
    let weekStart: String
    let amountCents: Int
    /// True for an amount besir computed (a table's estimated spend); false for an amount the user stated.
    let isEstimate: Bool
}

/// The device's spending, in one JSON file and one capped list. It never throws and never gets in the way of the exchange it
/// belongs to: a failed file write leaves the in-memory list as it is.
final class BudgetLedger: @unchecked Sendable {
    static let fileName = "budget.json"
    static let maxEntries = 500

    private let fileURL: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private let limit: Int

    private let lock = NSLock()
    private var entries: [BudgetEntry] = []

    init(fileURL: URL,
         write: @escaping @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite,
         maxEntries: Int = BudgetLedger.maxEntries) {
        self.fileURL = fileURL
        self.write = write
        self.limit = maxEntries
        self.entries = Self.load(fileURL, limit: maxEntries)
    }

    /// The ledger the app uses. Under tests `AppConfig.supportDirectory` is a throw-away folder.
    static let shared = BudgetLedger(fileURL: AppConfig.supportDirectory.appendingPathComponent(BudgetLedger.fileName))

    // MARK: Read

    func spentCents(weekStart: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.reduce(0) { $0 + ($1.weekStart == weekStart ? $1.amountCents : 0) }
    }

    func hasEstimate(weekStart: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.weekStart == weekStart && $0.isEstimate }
    }

    func contains(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.requestID == requestID }
    }

    /// The entry a request id made, or nil when the ledger holds none.
    func entry(requestID: String) -> BudgetEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.requestID == requestID }
    }

    // MARK: Write

    /// Removes the entry a request id made. True when one was removed. The file is written as `add` writes it, and a failed
    /// write leaves the in-memory list in its new state.
    @discardableResult
    func remove(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }) else { return false }
        entries.remove(at: index)
        if let data = try? JSONEncoder().encode(entries) { try? write(data, fileURL) }
        return true
    }

    /// Appends one entry, dropping the oldest past the cap. Returns false, and changes nothing, when the request id is already
    /// in the list. The file is written before the lock is released, so the writes happen in call order.
    @discardableResult
    func add(_ entry: BudgetEntry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.contains(where: { $0.requestID == entry.requestID }) else { return false }
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        if let data = try? JSONEncoder().encode(entries) { try? write(data, fileURL) }
        return true
    }

    // MARK: Load

    private struct Lossy: Decodable {
        let entry: BudgetEntry?
        init(from decoder: Decoder) throws { entry = try? BudgetEntry(from: decoder) }
    }

    /// A missing, empty or undecodable file gives an empty list; an entry that cannot be decoded is dropped alone.
    private static func load(_ url: URL, limit: Int) -> [BudgetEntry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let all = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        return Array(all.compactMap(\.entry).suffix(limit))
    }
}

/// The week rule: Monday to Sunday in the device's time zone, named by its Monday.
enum BudgetWeek {
    /// The Monday on or before `date` in `zone`, as `yyyy-MM-dd` (`en_US_POSIX`, Gregorian). A Sunday belongs to the Monday
    /// six days before it.
    static func start(of date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // Sunday is 1 and Monday 2, so Monday gives 0 days back, Tuesday 1, and Sunday 6.
        let back = (calendar.component(.weekday, from: date) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -back, to: date) ?? date
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: monday)
    }
}
