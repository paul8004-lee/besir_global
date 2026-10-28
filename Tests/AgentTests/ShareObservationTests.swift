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

    // SPEC-SHAREDIAG-001: the Debug card says what failed and nothing else.
    private typealias Outcome = ShareObservation.Outcome

    private func outcome(
        hasContainer: Bool = true,
        record: Outcome.RecordResult = .written,
        queue: Outcome.QueueResult = .stored,
        inbox: Outcome.InboxState = .count(1)
    ) -> Outcome {
        Outcome(hasContainer: hasContainer, record: record, queue: queue, inbox: inbox)
    }

    func testAC_DIAG_001_allSuccessGivesNoLine() {
        XCTAssertEqual(ShareObservation.failureLines(for: outcome()), [])
    }

    func testAC_DIAG_001_anyInboxCountGivesNoLine() {
        for count in [0, 1, 10] {
            XCTAssertEqual(ShareObservation.failureLines(for: outcome(inbox: .count(count))), [], "count \(count)")
        }
        XCTAssertEqual(ShareObservation.failureLines(for: outcome(record: .written)), [])
        XCTAssertEqual(ShareObservation.failureLines(for: outcome(queue: .stored)), [])
    }

    func testAC_DIAG_002_eachFailureAloneGivesItsOneLine() {
        XCTAssertEqual(ShareObservation.failureLines(for: outcome(inbox: .noFolder)), ["Inbox: no folder"])
        XCTAssertEqual(ShareObservation.failureLines(for: outcome(inbox: .notReadable)), ["Inbox: folder not readable"])
        XCTAssertEqual(ShareObservation.failureLines(for: outcome(queue: .writeFailed)), ["Queue: write failed"])
        XCTAssertEqual(ShareObservation.failureLines(for: outcome(queue: .nothingToStore)), ["Queue: nothing to store"])
        XCTAssertEqual(ShareObservation.failureLines(for: outcome(hasContainer: false)), ["App Group: no container"])
    }

    func testAC_DIAG_002_recordFailuresKeepTheirWording() {
        XCTAssertEqual(ShareObservation.failureLines(for: outcome(record: .fileMissing)), ["Record: written, file missing"])
        let text = ShareObservation.describe(NSError(domain: NSCocoaErrorDomain, code: 513))
        XCTAssertEqual(ShareObservation.failureLines(for: outcome(record: .failed(text))), ["Record: failed NSCocoaErrorDomain 513"])
    }

    func testAC_DIAG_002_failuresComeInTheFixedOrderAndNoContainerHidesTheRecord() {
        XCTAssertEqual(
            ShareObservation.failureLines(for: outcome(hasContainer: false, record: .written, queue: .writeFailed, inbox: .notReadable)),
            ["App Group: no container", "Queue: write failed", "Inbox: folder not readable"])
        XCTAssertEqual(
            ShareObservation.failureLines(for: outcome(hasContainer: false, record: .failed("x"), queue: .writeFailed, inbox: .notReadable)),
            ["App Group: no container", "Queue: write failed", "Inbox: folder not readable"])
        XCTAssertEqual(
            ShareObservation.failureLines(for: outcome(record: .failed("x"), queue: .nothingToStore, inbox: .noFolder)),
            ["Record: failed x", "Queue: nothing to store", "Inbox: no folder"])
    }

    func testAC_DIAG_002_everyCombinationShowsOnlyItsFailures() {
        let containers: [Bool] = [true, false]
        let records: [Outcome.RecordResult] = [.written, .fileMissing, .failed("x")]
        let queues: [Outcome.QueueResult] = [.stored, .writeFailed, .nothingToStore]
        let inboxes: [Outcome.InboxState] = [.count(7), .noFolder, .notReadable]
        let removed = ["Found", "container found", "file present", "stored", "file(s)"]
        var seen = 0
        for container in containers {
            for record in records {
                for queue in queues {
                    for inbox in inboxes {
                        // The expected lines come from this table, not from the function under test.
                        var expected: [String] = []
                        if !container {
                            expected.append("App Group: no container")
                        } else {
                            switch record {
                            case .written: break
                            case .fileMissing: expected.append("Record: written, file missing")
                            case .failed: expected.append("Record: failed x")
                            }
                        }
                        switch queue {
                        case .stored: break
                        case .writeFailed: expected.append("Queue: write failed")
                        case .nothingToStore: expected.append("Queue: nothing to store")
                        }
                        switch inbox {
                        case .count: break
                        case .noFolder: expected.append("Inbox: no folder")
                        case .notReadable: expected.append("Inbox: folder not readable")
                        }
                        let given = outcome(hasContainer: container, record: record, queue: queue, inbox: inbox)
                        let lines = ShareObservation.failureLines(for: given)
                        XCTAssertEqual(lines, expected, "\(given)")
                        for line in lines {
                            for word in removed {
                                XCTAssertFalse(line.contains(word), "\(line) holds \(word)")
                            }
                        }
                        seen += 1
                    }
                }
            }
        }
        XCTAssertEqual(seen, 54)
        XCTAssertEqual(ShareObservation.failureLines(for: outcome(inbox: .count(7))), [])
    }
}
#endif
