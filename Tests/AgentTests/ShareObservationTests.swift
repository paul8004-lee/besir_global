#if DEBUG
import XCTest
import UIKit
@testable import besir

/// SPEC-SHARE-001 AC-SHARE-001: the Debug recorder writes types and sizes, never content.
final class ShareObservationTests: XCTestCase {
    private func json(_ record: ShareObservation.Record) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    private func record(_ attachment: ShareObservation.Attachment) -> ShareObservation.Record {
        ShareObservation.record(at: Date(timeIntervalSince1970: 1_793_100_000), itemCount: 1, attachments: [attachment])
    }

    private func png(width: Int, height: Int) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testAC_SHARE_001_urlRecordKeepsHostAndFirstPathComponentOnly() throws {
        let url = try XCTUnwrap(URL(string: "https://www.instagram.com/p/ShortCode123/?igsh=secretquery"))
        let entry = ShareObservation.attachment(types: ["public.url"], url: url)
        XCTAssertEqual(entry.kind, .url)
        XCTAssertEqual(entry.host, "www.instagram.com")
        XCTAssertEqual(entry.firstPath, "p")
        let text = try json(record(entry))
        XCTAssertFalse(text.contains("ShortCode123"))
        XCTAssertFalse(text.contains("igsh"))
        XCTAssertFalse(text.contains("secretquery"))
    }

    func testAC_SHARE_001_textRecordKeepsLengthAndUrlFlagOnly() throws {
        let shared = "Jazz night Saturday 7pm https://example.com/tickets/JAZZ99"
        let entry = ShareObservation.attachment(types: ["public.utf8-plain-text"], text: shared)
        XCTAssertEqual(entry.kind, .text)
        XCTAssertEqual(entry.textLength, shared.count)
        XCTAssertEqual(entry.hasURL, true)
        let plain = ShareObservation.attachment(types: ["public.plain-text"], text: "Dinner at six")
        XCTAssertEqual(plain.hasURL, false)
        let text = try json(record(entry))
        XCTAssertFalse(text.contains("Jazz"))
        XCTAssertFalse(text.contains("JAZZ99"))
        XCTAssertFalse(text.contains("tickets"))
    }

    func testAC_SHARE_001_imageRecordKeepsByteCountAndSizeOnly() throws {
        let data = png(width: 64, height: 48)
        let entry = ShareObservation.attachment(types: ["public.png"], imageData: data)
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.bytes, data.count)
        XCTAssertEqual(entry.width, 64)
        XCTAssertEqual(entry.height, 48)
        let text = try json(record(entry))
        XCTAssertFalse(text.contains(data.base64EncodedString().prefix(40)))
        XCTAssertFalse(text.contains("url"), "no URL key on an image entry")
        XCTAssertFalse(text.contains("textLength"))
    }

    func testAC_SHARE_001_kindPrecedenceIsMovieImageUrlTextOther() {
        XCTAssertEqual(ShareObservation.kind(forTypes: ["public.jpeg", "public.mpeg-4", "public.url"]), .movie)
        XCTAssertEqual(ShareObservation.kind(forTypes: ["public.url", "public.jpeg", "public.plain-text"]), .image)
        XCTAssertEqual(ShareObservation.kind(forTypes: ["public.plain-text", "public.url"]), .url)
        XCTAssertEqual(ShareObservation.kind(forTypes: ["public.utf8-plain-text"]), .text)
        XCTAssertEqual(ShareObservation.kind(forTypes: ["com.example.not-a-real-type"]), .other)
        XCTAssertEqual(ShareObservation.kind(forTypes: []), .other)
    }
}
#endif
