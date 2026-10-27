#if DEBUG
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Debug-only record of what a share sheet hands the share extension (SPEC-SHARE-001).
/// It keeps type identifiers and sizes only: for a URL the host and the first path component, for text its length and
/// whether it holds a URL, for an image its byte count and pixel size. No path beyond the first component, no text, no pixels.
enum ShareObservation {
    /// Found by a scan of the whole app bundle: the Release build must not contain it.
    static let marker = "BESIR_DEBUG_SHARE_OBSERVATIONS_MARKER"
    static let fileName = "shareObservations.json"
    static let keepCount = 20

    enum Kind: String, Codable, Equatable {
        case image, movie, url, text, other
    }

    /// One attachment of a share. Keys that do not apply to the kind stay nil and are left out of the JSON.
    struct Attachment: Codable, Equatable {
        var kind: Kind
        var types: [String]
        var host: String?
        var firstPath: String?
        var textLength: Int?
        var hasURL: Bool?
        var bytes: Int?
        var width: Int?
        var height: Int?
    }

    /// One share. `at` is UTC ISO-8601 (`2026-10-27T11:35:02Z`).
    struct Record: Codable, Equatable {
        var at: String
        var itemCount: Int
        var attachments: [Attachment]
    }

    /// Precedence: movie, image, url, text, other. A shared photo often lists a file URL type beside the image type.
    static func kind(forTypes types: [String]) -> Kind {
        let resolved = types.compactMap { UTType($0) }
        if resolved.contains(where: { $0.conforms(to: .movie) }) { return .movie }
        if resolved.contains(where: { $0.conforms(to: .image) }) { return .image }
        if resolved.contains(where: { $0.conforms(to: .url) }) { return .url }
        if resolved.contains(where: { $0.conforms(to: .text) }) { return .text }
        return .other
    }

    /// Builds the attachment entry. Only the values the kind needs are read from the inputs; the inputs are not kept.
    static func attachment(types: [String], url: URL? = nil, text: String? = nil, imageData: Data? = nil) -> Attachment {
        var entry = Attachment(kind: kind(forTypes: types), types: types)
        switch entry.kind {
        case .url:
            entry.host = url?.host
            entry.firstPath = url?.pathComponents.first(where: { $0 != "/" })
        case .text:
            if let text {
                entry.textLength = text.count
                entry.hasURL = containsURL(text)
            }
        case .image:
            if let imageData {
                entry.bytes = imageData.count
                if let size = pixelSize(of: imageData) {
                    entry.width = size.width
                    entry.height = size.height
                }
            }
        case .movie, .other:
            break
        }
        return entry
    }

    static func record(at date: Date, itemCount: Int, attachments: [Attachment]) -> Record {
        Record(at: ISO8601DateFormatter().string(from: date), itemCount: itemCount, attachments: attachments)
    }

    /// Appends the record to the JSON array at `fileURL` (newest last, the newest `keepCount` kept). Returns false when it could not write.
    @discardableResult
    static func append(_ record: Record, to fileURL: URL) -> Bool {
        var records = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        records.append(record)
        if records.count > keepCount { records.removeFirst(records.count - keepCount) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(records) else { return false }
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }

    /// The kinds found, in order, for the Debug label of the extension (for example `image, url`).
    static func summary(of record: Record) -> String {
        record.attachments.isEmpty ? "nothing" : record.attachments.map { $0.kind.rawValue }.joined(separator: ", ")
    }

    private static func containsURL(_ text: String) -> Bool {
        text.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Reads the size from the image header, without decoding the bitmap.
    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
#endif
