import Foundation

/// The queue the share extension uses to hand shared items to the main app through the App Group.
/// Compiled into both targets (besir-iOS, besirShare), so it stays free of UIKit.
/// One share is one file (`<receivedAt epoch milliseconds, 13 digits>-<id>.json`): two shares that arrive together never
/// overwrite each other, and order and expiry come from the file name alone.
struct SharedInbox {
    struct Item: Codable, Equatable {
        var id: UUID
        var receivedAt: Date
        var text: String?
        var imageBase64: String?
        var mimeType: String?
    }

    static let appGroupID = "group.com.iseongmin.besir.global"
    /// At most ten items are kept, and none for longer than a day.
    static let maxItems = 10
    static let maxAge: TimeInterval = 24 * 3600

    /// The folder of item files and the single file an earlier version used. Tests swap both for temporary folders.
    let directory: URL?
    let legacyFile: URL?

    static let standard: SharedInbox = {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        return SharedInbox(directory: container?.appendingPathComponent("inbox", isDirectory: true),
                           legacyFile: container?.appendingPathComponent("pendingShares.json"))
    }()

    /// Called by the share extension: builds the queue item from what the share carried. An image goes in only as a JPEG
    /// from `ImageShrink`; if it cannot be shrunk it is dropped and the text stays. Nil when neither is left (nothing to store).
    static func prepare(text: String?, imageData: Data?, mime: String?,
                        shrink: (Data) -> Data? = { ImageShrink.jpeg(from: $0) },
                        now: Date = Date(), id: UUID = UUID()) -> Item? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableText = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let shrunk = imageData.flatMap(shrink)
        guard usableText != nil || shrunk != nil else { return nil }
        // A shrunk image is always JPEG, so the incoming mime type is not carried over.
        return Item(id: id, receivedAt: now, text: usableText,
                    imageBase64: shrunk?.base64EncodedString(), mimeType: shrunk == nil ? nil : "image/jpeg")
    }

    /// Writes one item as its own file, atomically. Past ten files the oldest are deleted. False when there is no location.
    @discardableResult
    func enqueue(_ item: Item) -> Bool {
        guard let directory else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(item).write(to: directory.appendingPathComponent(Self.fileName(for: item)), options: .atomic)
        } catch {
            return false
        }
        let names = fileNames()
        if names.count > Self.maxItems {
            for name in names.prefix(names.count - Self.maxItems) { delete(name) }
        }
        return true
    }

    /// Called by the main app: the items, oldest first. Files older than a day are deleted, unreadable files are skipped,
    /// and the single file of the earlier version is deleted without being read.
    func pending(now: Date = Date()) -> [Item] {
        if let legacyFile { try? FileManager.default.removeItem(at: legacyFile) }
        var items: [Item] = []
        for name in fileNames() {
            guard let stamp = Self.receivedMilliseconds(in: name) else { continue }
            if now.timeIntervalSince1970 - TimeInterval(stamp) / 1000 > Self.maxAge { delete(name); continue }
            guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let item = try? Self.decoder.decode(Item.self, from: data) else { continue }
            items.append(item)
        }
        return items
    }

    /// Deletes an item whose attempt is over. An unknown id is ignored.
    func remove(_ id: UUID) {
        for name in fileNames() where name.hasSuffix("-\(id.uuidString).json") { delete(name) }
    }

    // MARK: - Files

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func fileName(for item: Item) -> String {
        String(format: "%013lld-%@.json", Int64(item.receivedAt.timeIntervalSince1970 * 1000), item.id.uuidString)
    }

    /// The first 13 digits of a file name (the time received, epoch milliseconds). Nil for any other shape.
    private static func receivedMilliseconds(in name: String) -> Int64? {
        guard name.hasSuffix(".json"), let dash = name.firstIndex(of: "-"), name.distance(from: name.startIndex, to: dash) == 13 else { return nil }
        return Int64(name[name.startIndex..<dash])
    }

    /// Item file names, oldest first (name order). Files of any other shape are left out.
    private func fileNames() -> [String] {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { Self.receivedMilliseconds(in: $0) != nil }.sorted()
    }

    private func delete(_ name: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}
