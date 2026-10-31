import XCTest
import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import besir

/// SPEC-CONNECT-001: the packet, the cleaning, the storage, the flows and the time text. Every log here is built with a
/// temporary file, so nothing reads or writes the installed app's data.
@MainActor
final class ConnectionLogTests: XCTestCase {
    private struct WriteFailure: Error {}

    private func makeFileURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("connlog-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent(ConnectionLog.fileName)
    }

    private func makeLog(secrets: [String] = [],
                         file: URL? = nil,
                         maxPackets: Int = ConnectionLog.maxPackets,
                         write: @escaping @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite) -> ConnectionLog {
        ConnectionLog(fileURL: file ?? makeFileURL(), secrets: { secrets }, write: write, maxPackets: maxPackets)
    }

    /// Records one packet with the given summary and returns the summary as stored.
    private func stored(_ summary: String, kind: ConnectionKind = .agentMessage, secrets: [String] = []) async -> String? {
        let log = makeLog(secrets: secrets)
        log.record(from: .besir, to: .museSpark, kind: kind, summary: summary, status: .ok)
        await log.flush()
        return log.packets.last?.summary
    }

    private func packet(_ flow: UUID?, _ from: ConnectionParty, _ to: ConnectionParty, at seconds: TimeInterval,
                        kind: ConnectionKind = .agentMessage) -> ConnectionPacket {
        ConnectionPacket(id: UUID(), flowID: flow, at: Date(timeIntervalSince1970: seconds), from: from, to: to,
                         kind: kind, summary: "s", status: .ok)
    }

    /// Words of nine letters, so no run reaches the 40-character secret rule, cut to exactly `count` characters.
    private func words(_ count: Int) -> String {
        var text = String(String(repeating: "abcdefghi ", count: count / 10 + 1).prefix(count))
        if text.hasSuffix(" ") { text.removeLast(); text += "z" }
        return text
    }

    // MARK: - Packet shape (T01-T03)

    func testCONNECT_T01_PacketRoundTripsWithEveryFieldEqual() throws {
        let packet = ConnectionPacket(id: UUID(), flowID: UUID(), at: Date(), from: .besir, to: .googlePlaces,
                                      kind: .placeSearch, summary: "Searched “cafe” · 3 results", status: .ok)
        let back = try JSONDecoder().decode(ConnectionPacket.self, from: JSONEncoder().encode(packet))
        XCTAssertEqual(back, packet)
        XCTAssertEqual(back.at, packet.at)
    }

    func testCONNECT_T02_PacketHasExactlyTheEightKeys() throws {
        let keys = Set(["id", "flowID", "at", "from", "to", "kind", "summary", "status"])
        let withFlow = ConnectionPacket(id: UUID(), flowID: UUID(), at: Date(), from: .besir, to: .museSpark,
                                        kind: .agentMessage, summary: "Reply received", status: .ok)
        let withoutFlow = ConnectionPacket(id: UUID(), flowID: nil, at: Date(), from: .besir, to: .museSpark,
                                           kind: .agentMessage, summary: "Reply received", status: .ok)
        let objectWith = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(withFlow)) as? [String: Any])
        let objectWithout = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(withoutFlow)) as? [String: Any])
        XCTAssertEqual(Set(objectWith.keys), keys)
        XCTAssertEqual(Set(objectWithout.keys), keys.subtracting(["flowID"]))

        let children = Mirror(reflecting: withFlow).children
        XCTAssertEqual(Set(children.compactMap(\.label)), keys)
        for child in children {
            XCTAssertFalse(child.value is Data, "\(child.label ?? "?") must not be Data")
            XCTAssertFalse(child.value is URL, "\(child.label ?? "?") must not be URL")
        }
    }

    func testCONNECT_T03_EnumsHaveExactlyTheSpecifiedCasesAndEnglishNames() {
        XCTAssertEqual(Set(ConnectionParty.allCases.map(\.rawValue)),
                       ["instagram", "shareSheet", "besir", "museSpark", "imageReader", "googlePlaces", "googleRoutes", "appleCalendar", "partner", "budgetPartner", "deliveryPartner"])
        XCTAssertEqual(Set(ConnectionKind.allCases.map(\.rawValue)),
                       ["share", "imageRead", "placeSearch", "route", "agentMessage", "agentToolCall", "calendarSave", "partner", "budget", "delivery"])
        XCTAssertEqual(ConnectionStatus.allCases.map(\.rawValue), ["ok", "failed", "declined", "noRoute"])
        let names = ConnectionParty.allCases.map(\.displayName) + ConnectionKind.allCases.map(\.displayName)
            + ConnectionKind.allCases.map(\.defaultSummary) + ConnectionStatus.allCases.map(\.word)
        for name in names {
            XCTAssertFalse(name.isEmpty)
            XCTAssertTrue(name.unicodeScalars.allSatisfy { $0.isASCII }, "\(name) must be English")
        }
    }

    // MARK: - Load (T04, T13, T14)

    func testCONNECT_T04_AFileWithOneUnknownKindLoadsTheTwoGoodPackets() throws {
        let file = makeFileURL()
        let good = [packet(nil, .besir, .museSpark, at: 100), packet(nil, .besir, .googlePlaces, at: 200, kind: .placeSearch)]
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [[String: Any]])
        var odd = objects[0]
        odd["kind"] = "carrierPigeon"
        odd["id"] = UUID().uuidString
        objects.insert(odd, at: 1)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: objects).write(to: file)

        let log = makeLog(file: file)
        XCTAssertEqual(log.packets, good)
    }

    // MARK: SPEC-DELIVERYCARD-001 (card t91) the removed delivery cases

    func testDELIVERY_L01_AStoredPacketOfARemovedDeliveryCaseDropsAloneAndTheRemainingCasesKeepTheirNames() throws {
        XCTAssertEqual(ConnectionParty.allCases.map(\.rawValue),
                       ["instagram", "shareSheet", "besir", "museSpark", "imageReader", "googlePlaces", "googleRoutes",
                        "appleCalendar", "partner", "budgetPartner"])
        XCTAssertEqual(ConnectionKind.allCases.map(\.rawValue),
                       ["share", "imageRead", "placeSearch", "route", "agentMessage", "agentToolCall", "calendarSave",
                        "partner", "budget"])
        // The removed cases are named only as the raw strings a stored file holds.
        let file = makeFileURL()
        let good = [packet(nil, .besir, .partner, at: 100, kind: .partner),
                    packet(nil, .besir, .budgetPartner, at: 200, kind: .budget)]
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [[String: Any]])
        var partyPacket = objects[0]
        partyPacket["from"] = "deliveryPartner"
        partyPacket["id"] = UUID().uuidString
        var kindPacket = objects[1]
        kindPacket["kind"] = "delivery"
        kindPacket["id"] = UUID().uuidString
        objects.append(contentsOf: [partyPacket, kindPacket])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: objects).write(to: file)

        let log = makeLog(file: file)
        XCTAssertEqual(log.packets, good, "the packets of the removed cases drop alone; the good ones load")
    }

    func testCONNECT_T13_ANewLogOnTheSameFileShowsTheSamePacketsAtOnce() async {
        let file = makeFileURL()
        let log = makeLog(file: file)
        for i in 1...3 { log.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: "Reply \(i)", status: .ok) }
        await log.flush()
        let again = makeLog(file: file)
        XCTAssertEqual(again.packets.count, 3)
        XCTAssertEqual(again.packets, log.packets)
        XCTAssertEqual(again.packets.map(\.summary), ["Reply 1", "Reply 2", "Reply 3"])
    }

    func testCONNECT_T14_ACorruptFileGivesAnEmptyLogAndTheNextRecordRepairsIt() async throws {
        let file = makeFileURL()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: file)
        let log = makeLog(file: file)
        XCTAssertEqual(log.packets, [])
        log.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: "Reply received", status: .ok)
        await log.flush()
        XCTAssertEqual(makeLog(file: file).packets.count, 1)
    }

    // MARK: - Cleaning (T05-T11, T45, T46, T70)

    func testCONNECT_T05_ControlAndZeroWidthCharactersAreRemovedAndWhiteSpaceCollapsed() async {
        let dirty = "  a\u{200B}b\nc\u{0007}d    e\u{2028}f   "
        let summary = await stored(dirty)
        XCTAssertEqual(summary, "abcd ef")
    }

    func testCONNECT_T06_TheEightyCharacterCut() async {
        let long = words(81)
        XCTAssertEqual(long.count, 81)
        let cut = await stored(long)
        XCTAssertEqual(cut, String(long.prefix(79)) + "…")
        XCTAssertEqual(cut?.count, 80)

        let exact = words(80)
        XCTAssertEqual(exact.count, 80)
        let kept = await stored(exact)
        XCTAssertEqual(kept, exact)
    }

    func testCONNECT_T07_AUrlInsideTextBecomesItsHost() async {
        let summary = await stored("See https://www.instagram.com/p/AbC/?igsh=ZZZ now")
        XCTAssertEqual(summary, "See www.instagram.com now")
    }

    func testCONNECT_T08_EverySecretShapeGivesDetailsHidden() async {
        let samples = ["data:image/png;base64,AAAA", "DATA:text/plain,hello", String(repeating: "A", count: 40),
                       "key AIzaSyDUMMYDUMMYDUMMY123456", "sk-abcdefghijklmnop1234", "use sk-abcdefghijklmnop1234 here",
                       "Bearer abc123", "bearer abc123", "x-besir-token", "X-BESIR-TOKEN"]
        for sample in samples {
            let summary = await stored(sample)
            XCTAssertEqual(summary, ConnectionLog.hiddenText, "sample: \(sample)")
        }
    }

    func testCONNECT_T09_TheConfigurationSecretsAreHiddenInAnyCaseAndShortOnesIgnored() async {
        let secrets = ["TOKEN-abc123", "host.example.invalid"]
        let token = await stored("sent with token-ABC123", secrets: secrets)
        let host = await stored("went to HOST.example.INVALID", secrets: secrets)
        XCTAssertEqual(token, ConnectionLog.hiddenText)
        XCTAssertEqual(host, ConnectionLog.hiddenText)

        let short = await stored("abc def", secrets: ["abc"])
        XCTAssertEqual(short, "abc def")

        let spaced = await stored("ab cd efgh", secrets: ["ab_cd_efgh"])
        XCTAssertEqual(spaced, ConnectionLog.hiddenText)
    }

    func testCONNECT_T10_ASecretInsideAUrlQueryIsCaughtBeforeTheUrlIsCutToItsHost() async {
        let withSecret = await stored("see https://example.com/path?k=secretvalue99", secrets: ["secretvalue99"])
        XCTAssertEqual(withSecret, ConnectionLog.hiddenText)
        let control = await stored("see https://example.com/path?k=secretvalue99")
        XCTAssertEqual(control, "see example.com")
    }

    func testCONNECT_T11_AnEmptySummaryBecomesTheDefaultTextOfItsKind() async {
        for kind in ConnectionKind.allCases {
            let empty = await stored("", kind: kind)
            let blank = await stored("  \n\u{200B} ", kind: kind)
            XCTAssertEqual(empty, kind.defaultSummary)
            XCTAssertEqual(blank, kind.defaultSummary)
        }
        let route = await stored("", kind: .route)
        XCTAssertEqual(route, "Route lookup")
    }

    func testCONNECT_T45_ASecretSplitByAZeroWidthCharacterIsHidden() async {
        let split = "SENTINEL-TO\u{200B}KEN-0001"
        let summary = await stored("sent \(split)", secrets: ["SENTINEL-TOKEN-0001"])
        XCTAssertEqual(summary, ConnectionLog.hiddenText)
    }

    func testCONNECT_T46_TheFortyCharacterBoundaryAndHyphenatedWords() async {
        let thirtyNine = await stored(String(repeating: "a", count: 39))
        XCTAssertEqual(thirtyNine, String(repeating: "a", count: 39))
        let lamp = await stored("desk-lamp")
        XCTAssertEqual(lamp, "desk-lamp")
        let forty = await stored(String(repeating: "a", count: 40))
        XCTAssertEqual(forty, ConnectionLog.hiddenText)
    }

    func testCONNECT_T70_AUrlCutByAZeroWidthCharacterIsWholeAgainBeforeItBecomesItsHost() async {
        let cut = await stored("https://example.com/pa\u{200B}th?x=1")
        XCTAssertEqual(cut, "example.com")
        let words = await stored("Go to https://example.com/x for details")
        XCTAssertEqual(words, "Go to example.com for details")
    }

    // MARK: - Storage (T12, T15-T18, T41, T42)

    func testCONNECT_T12_TheTwoHundredAndFirstRecordDropsTheOldest() async {
        let log = makeLog()
        for i in 1...201 { log.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: "Item \(i)", status: .ok) }
        await log.flush()
        XCTAssertEqual(log.packets.count, 200)
        XCTAssertEqual(log.packets.first?.summary, "Item 2")
        XCTAssertEqual(log.packets.last?.summary, "Item 201")
    }

    func testCONNECT_T15_AfterAWriteTheFolderHoldsOnlyTheLogFile() async throws {
        let file = makeFileURL()
        let log = makeLog(file: file)
        log.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: "Reply received", status: .ok)
        await log.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(names, [ConnectionLog.fileName])
    }

    func testCONNECT_T16_AWriterThatThrowsLeavesTheMemoryListIntact() async {
        let log = makeLog(write: { _, _ in throw WriteFailure() })
        log.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: "Reply received", status: .ok)
        await log.flush()
        XCTAssertEqual(log.packets.map(\.summary), ["Reply received"])
    }

    func testCONNECT_T17_OneHundredConcurrentRecordsGiveOneHundredDistinctPackets() async throws {
        let file = makeFileURL()
        let log = makeLog(file: file)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { log.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: "Item \(i)", status: .ok) }
            }
        }
        await log.flush()
        XCTAssertEqual(log.packets.count, 100)
        XCTAssertEqual(Set(log.packets.map(\.id)).count, 100)
        let decoded = try JSONDecoder().decode([ConnectionPacket].self, from: Data(contentsOf: file))
        XCTAssertEqual(decoded, log.packets)
    }

    func testCONNECT_T18_PacketsChangeOnlyOnTheMainThread() async {
        let log = makeLog()
        var threads: [Bool] = []
        let sink = log.$packets.dropFirst().sink { _ in threads.append(Thread.isMainThread) }
        await Task.detached {
            for i in 0..<5 { log.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: "Item \(i)", status: .ok) }
        }.value
        await log.flush()
        sink.cancel()
        XCTAssertFalse(threads.isEmpty)
        XCTAssertTrue(threads.allSatisfy { $0 })
    }

    func testCONNECT_T41_RecordReturnsWhileTheWriterIsBlocked() async {
        let file = makeFileURL()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let log = makeLog(file: file) { data, url in
            started.signal()
            release.wait()
            try ConnectionLog.defaultWrite(data, url)
        }
        log.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: "Reply received", status: .ok)
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        release.signal()
        await log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCONNECT_T42_AMissingDataFolderIsCreatedByTheDefaultWriter() async {
        let file = makeFileURL().deletingLastPathComponent().appendingPathComponent("a/b/\(ConnectionLog.fileName)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        let log = makeLog(file: file)
        log.record(from: .besir, to: .museSpark, kind: .agentMessage, summary: "Reply received", status: .ok)
        await log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Flows (T19, T20, T38, T39)

    func testCONNECT_T19_PacketsGroupIntoFlowsNewestFirst() {
        let a = UUID(), b = UUID()
        let packets = [packet(a, .besir, .museSpark, at: 100), packet(nil, .besir, .googlePlaces, at: 150, kind: .placeSearch),
                       packet(a, .museSpark, .besir, at: 200), packet(b, .besir, .googleRoutes, at: 300, kind: .route)]
        let flows = ConnectionFlows.group(packets)
        XCTAssertEqual(flows.count, 3)
        XCTAssertEqual(flows.map(\.latest), [300, 200, 150].map { Date(timeIntervalSince1970: $0) })
        XCTAssertEqual(flows[1].packets.map(\.at), [100, 200].map { Date(timeIntervalSince1970: $0) })
        XCTAssertEqual(flows[2].packets.count, 1)
        XCTAssertNil(flows[2].packets[0].flowID)
    }

    func testCONNECT_T20_TheChainDropsAdjacentRepeats() {
        let flow = UUID()
        let packets = [packet(flow, .besir, .museSpark, at: 1), packet(flow, .museSpark, .besir, at: 2),
                       packet(flow, .besir, .museSpark, at: 3)]
        let grouped = ConnectionFlows.group(packets)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].chain, [.besir, .museSpark, .besir, .museSpark])
        XCTAssertEqual(ConnectionFlows.chainText(grouped[0]), "besir → Muse Spark → besir → Muse Spark")

        // Packets between the same two parties one after another add no hop.
        let routes = UUID()
        let four = (1...4).map { packet(routes, .besir, .googleRoutes, at: TimeInterval($0), kind: .route) }
        XCTAssertEqual(ConnectionFlows.group(four)[0].chain, [.besir, .googleRoutes])
        XCTAssertEqual(ConnectionFlows.chainText(ConnectionFlows.group(four)[0]), "besir → Google Routes")
    }

    func testCONNECT_T38_EmptyTextStatusWordsAndTheShareChain() {
        XCTAssertEqual(ConnectionLog.emptyText, "No connections yet")
        XCTAssertEqual(ConnectionStatus.allCases.map(\.word), ["OK", "Failed", "Declined", "No route"])
        let flow = UUID()
        let share = packet(flow, .shareSheet, .besir, at: 1, kind: .share)
        let read = packet(flow, .besir, .imageReader, at: 2, kind: .imageRead)
        XCTAssertEqual(ConnectionFlows.chainText(ConnectionFlows.group([share, read])[0]), "Share sheet → besir → Image reader")
    }

    // SPEC-CONNECT-002 (card t47): the status of a "no route" answer.
    func testCONNECT2_T08_ANoRoutePacketSurvivesTheFile() async throws {
        let file = makeFileURL()
        let log = makeLog(file: file)
        log.record(from: .besir, to: .googleRoutes, kind: .route, summary: "Transit route", status: .noRoute)
        await log.flush()
        let again = makeLog(file: file)
        XCTAssertEqual(again.packets, log.packets)
        XCTAssertEqual(again.packets.map(\.status), [.noRoute])

        // A build that does not know a status word loses that packet only (REQ-CONNECT-029).
        let kept = ConnectionPacket(id: UUID(), flowID: nil, at: Date(timeIntervalSince1970: 100), from: .besir, to: .googleRoutes,
                                    kind: .route, summary: "Car route", status: .noRoute)
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([kept, kept])) as? [[String: Any]])
        objects[1]["id"] = UUID().uuidString
        objects[1]["status"] = "mystery"
        let mixed = makeFileURL()
        try FileManager.default.createDirectory(at: mixed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: objects).write(to: mixed)
        XCTAssertEqual(makeLog(file: mixed).packets, [kept])
    }

    func testCONNECT_T39_FiftyOneFlowsShowFifty() async {
        let log = makeLog()
        for i in 0..<51 { log.record(from: .besir, to: .googlePlaces, kind: .placeSearch, summary: "Search \(i)", status: .ok) }
        await log.flush()
        XCTAssertEqual(ConnectionFlows.group(log.packets).count, 51)
        XCTAssertEqual(ConnectionFlows.shown(log.packets).count, 50)
    }

    // MARK: - Sender (T21)

    func testCONNECT_T21_TheSenderIsInstagramOnlyWhenEveryUrlIsOnInstagram() {
        for text in ["https://www.instagram.com/p/x", "https://instagram.com/reel/y", "check m.instagram.com",
                     "look https://www.instagram.com/p/x and https://instagram.com/reel/y"] {
            XCTAssertEqual(ConnectionParty.forSharedText(text), .instagram, text)
        }
        for text in ["https://notinstagram.com/p/x", "https://instagram.com.example.org/p/x", "Instagram is great", "",
                     "https://www.instagram.com/p/x and https://example.org/y", "https://instagram.com@example.org/",
                     "user@host", "see user@example.org"] {
            XCTAssertEqual(ConnectionParty.forSharedText(text), .shareSheet, text)
        }
        XCTAssertEqual(ConnectionParty.forSharedText(nil), .shareSheet)
    }

    // MARK: - Time (T37)

    func testCONNECT_T37_TimeTextIsEnglishAndRelativeToToday() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func date(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)))
        }
        let now = try date(28, 20, 0)
        XCTAssertEqual(ConnectionLog.timeText(try date(28, 15, 5), now: now, timeZone: zone), "3:05 PM")
        XCTAssertEqual(ConnectionLog.timeText(try date(26, 15, 5), now: now, timeZone: zone), "Oct 26, 3:05 PM")
    }

    // MARK: - Secret source (T71)

    func testCONNECT_T71_TheShippedSecretSourceReturnsTheTokenAndTheHost() async {
        let config = AppConfig(kakaoJsKey: "", proxyBaseURL: "https://\(FakeTransport.host)", appToken: FakeTransport.token)
        let secrets = ConnectionLog.secrets(from: config)
        XCTAssertEqual(secrets, [FakeTransport.token, FakeTransport.host])
        let log = ConnectionLog(fileURL: makeFileURL(), secrets: { ConnectionLog.secrets(from: config) })
        log.record(from: .besir, to: .museSpark, kind: .agentToolCall, summary: "sent \(FakeTransport.token.lowercased())", status: .ok)
        log.record(from: .besir, to: .museSpark, kind: .agentToolCall, summary: "to \(FakeTransport.host)", status: .ok)
        await log.flush()
        XCTAssertEqual(log.packets.map(\.summary), [ConnectionLog.hiddenText, ConnectionLog.hiddenText])
    }
}
