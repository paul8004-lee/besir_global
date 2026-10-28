import XCTest
import CoreLocation
@testable import besir

/// SPEC-CONNECT-001: what the five connections record, and that recording changes nothing they return or show.
/// Every log is built with a temporary file; nothing here reads or writes the installed app's data.
@MainActor
final class ConnectionHooksTests: XCTestCase {
    private typealias Places = PlacesTestSupport
    private typealias Routes = RoutesTestSupport
    private struct WriteFailure: Error {}

    // MARK: - Helpers

    private func makeLog(failing: Bool = false) -> ConnectionLog {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("connhooks-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(ConnectionLog.fileName)
        if failing { return ConnectionLog(fileURL: file, write: { _, _ in throw WriteFailure() }) }
        return ConnectionLog(fileURL: file)
    }

    private func makeLog(secrets: [String]) -> (log: ConnectionLog, file: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("connhooks-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(ConnectionLog.fileName)
        return (ConnectionLog(fileURL: file, secrets: { secrets }), file)
    }

    /// One readable line per packet: `from>to kind status summary`.
    private func lines(_ log: ConnectionLog) -> [String] {
        log.packets.map { "\($0.from.rawValue)>\($0.to.rawValue) \($0.kind.rawValue) \($0.status.rawValue) \($0.summary)" }
    }

    private func chains(_ log: ConnectionLog) -> [String] {
        ConnectionFlows.group(log.packets).map(ConnectionFlows.chainText)
    }

    private func toolPackets(_ log: ConnectionLog) -> [String] {
        log.packets.filter { $0.kind == .agentToolCall }.map { "\($0.summary) \($0.status.rawValue)" }
    }

    /// Runs the work inside a task that is already cancelled, so `Task.isCancelled` is true when the outcome is known.
    private func cancelled<T>(_ work: @escaping () async -> T) async -> T {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await work()
        }.value
    }

    // MARK: - Places (T22-T30)

    private func placeSearch(_ stub: PlacesTransportStub, _ log: ConnectionLog, config: AppConfig = Places.config) -> PlaceSearch {
        PlaceSearch(config: config, transport: stub.transport, connections: log)
    }

    private func onePlaceAnswer() -> Data {
        let place: [String: Any] = ["id": "p1", "displayName": ["text": "Alpha Cafe"], "formattedAddress": "1 Alpha Street",
                                    "location": ["latitude": 37.77, "longitude": -122.41]]
        return (try? JSONSerialization.data(withJSONObject: ["places": [place]])) ?? Data()
    }

    func testCONNECT_T22_ATypedSearchRecordsOnePacketWithTheCount() async throws {
        let log = makeLog()
        let stub = PlacesTransportStub.answering(with: try Places.fixture("places-search-three"))
        let found = await placeSearch(stub, log).search("cafe", near: Places.center)
        XCTAssertEqual(found.count, 3)
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>googlePlaces placeSearch ok Searched “cafe” · 3 results"])
    }

    func testCONNECT_T23_ZeroAndOneResultAreWordedRight() async throws {
        let empty = makeLog()
        let none = await placeSearch(.answering(with: try Places.fixture("places-empty")), empty).search("cafe", near: nil)
        XCTAssertEqual(none, [])
        await empty.flush()
        XCTAssertEqual(lines(empty), ["besir>googlePlaces placeSearch ok Searched “cafe” · 0 results"])

        let one = makeLog()
        let single = await placeSearch(.answering(with: onePlaceAnswer()), one).search("cafe", near: nil)
        XCTAssertEqual(single.count, 1)
        await one.flush()
        XCTAssertEqual(lines(one), ["besir>googlePlaces placeSearch ok Searched “cafe” · 1 result"])
    }

    func testCONNECT_T24_ANon200AnswerRecordsAFailure() async throws {
        let log = makeLog()
        let stub = PlacesTransportStub.answering(status: 500, with: try Places.fixture("places-search-three"))
        let found = await placeSearch(stub, log).search("cafe", near: nil)
        XCTAssertEqual(found, [])
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>googlePlaces placeSearch failed Search failed"])
    }

    func testCONNECT_T25_AThrownTransportErrorRecordsAFailure() async {
        let log = makeLog()
        let stub = PlacesTransportStub { _ in throw URLError(.notConnectedToInternet) }
        let found = await placeSearch(stub, log).search("cafe", near: nil)
        XCTAssertEqual(found, [])
        XCTAssertEqual(stub.callCount, 1)
        await log.flush()
        XCTAssertEqual(lines(log), ["besir>googlePlaces placeSearch failed Search failed"])
    }

    func testCONNECT_T26_NoRequestMeansNoPacket() async throws {
        let log = makeLog()
        let stub = PlacesTransportStub.answering(with: try Places.fixture("places-search-three"))
        let short = await placeSearch(stub, log).search("a", near: nil)
        let unconfigured = await placeSearch(stub, log, config: AppConfig()).search("cafe", near: nil)
        XCTAssertEqual(short, [])
        XCTAssertEqual(unconfigured, [])
        XCTAssertEqual(stub.callCount, 0)
        await log.flush()
        XCTAssertEqual(log.packets, [])
    }

    func testCONNECT_T27_ACancelledSearchRecordsNothing() async throws {
        let failing = makeLog()
        let bad = PlacesTransportStub.answering(status: 500, with: Data("{}".utf8))
        let search = placeSearch(bad, failing)
        _ = await cancelled { await search.search("cafe", near: nil) }
        XCTAssertEqual(bad.callCount, 1)

        let answering = makeLog()
        let good = PlacesTransportStub.answering(with: try Places.fixture("places-search-three"))
        let goodSearch = placeSearch(good, answering)
        _ = await cancelled { await goodSearch.search("cafe", near: nil) }
        XCTAssertEqual(good.callCount, 1)

        await failing.flush()
        await answering.flush()
        XCTAssertEqual(failing.packets, [])
        XCTAssertEqual(answering.packets, [])
    }

    func testCONNECT_T28_ANearbySearchRecordsTheTermItSent() async {
        let answer = Places.nearbyAnswer([("Zephyr Noodle House", 100), ("Quill Diner", 200), ("Marlow Grill", 300)])
        let cases: [(category: MealCategoryFilter?, keyword: String?, term: String)] = [
            (.cafe, "  ramen ", "ramen"), (.cafe, nil, "cafes"), (.restaurant, "   ", "restaurants"), (nil, nil, "restaurants")
        ]
        for item in cases {
            let log = makeLog()
            let stub = PlacesTransportStub.answering(with: answer)
            let found = await placeSearch(stub, log).nearbyPlaces(category: item.category, keyword: item.keyword, near: Places.center)
            XCTAssertEqual(found.count, 3)
            let sent = Places.body(of: stub.requests[0])?["textQuery"] as? String
            XCTAssertEqual(sent, item.term)
            XCTAssertEqual(PlaceSearch.nearbyTerm(category: item.category, keyword: item.keyword), item.term)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>googlePlaces placeSearch ok Nearby \(item.term) · 3 results"])
        }
    }

    func testCONNECT_T29_APlaceSummaryHoldsNothingGoogleReturned() async throws {
        let typed = makeLog()
        let found = await placeSearch(.answering(with: try Places.fixture("places-search-three")), typed).search("cafe", near: nil)
        XCTAssertFalse(found.isEmpty)
        let nearby = makeLog()
        let near = await placeSearch(.answering(with: Places.nearbyAnswer([("Zephyr Noodle House", 100)])), nearby)
            .nearbyPlaces(category: nil, keyword: "noodles", near: Places.center)
        XCTAssertEqual(near.count, 1)
        await typed.flush()
        await nearby.flush()

        var forbidden = found.flatMap { [$0.name, $0.address, String($0.latitude), String($0.longitude)] }
        forbidden += ["Zephyr Noodle House", "Zephyr", "address", "maps.example.invalid", "http"]
        for summary in typed.packets.map(\.summary) + nearby.packets.map(\.summary) {
            for word in forbidden where !word.isEmpty {
                XCTAssertFalse(summary.contains(word), "\(summary) holds \(word)")
            }
        }
    }

    func testCONNECT_T30_AnUnwritableLogChangesNothingASearchReturns() async throws {
        let answer = try Places.fixture("places-search-three")
        let good = await placeSearch(.answering(with: answer), makeLog()).search("cafe", near: Places.center)
        let log = makeLog(failing: true)
        let bad = await placeSearch(.answering(with: answer), log).search("cafe", near: Places.center)
        XCTAssertEqual(good, bad)
        await log.flush()
        XCTAssertEqual(log.packets.count, 1)
    }

    // MARK: - Agent (T31-T36, T40, T43, T44, T47, T64, T65)

    @MainActor private struct HookRig {
        let tools: ToolHarness
        let fake: FakeTransport
        let log: ConnectionLog
        let session: AgentSession

        init(_ steps: [FakeTransport.Step], log: ConnectionLog) {
            tools = ToolHarness.make()
            fake = FakeTransport(steps)
            self.log = log
            session = AgentSession(toolbox: tools.tools, transport: fake, connections: log)
        }

        func say(_ text: String) async {
            session.send(text)
            await session.settle()
        }

        var resultStatuses: [String] {
            session.entries.compactMap { if case .result(let status) = $0.kind { return status } else { return nil } }
        }
    }

    private let workerBody = Data(#"{"error":"unauthorized"}"#.utf8)

    func testCONNECT_T31_AUsableReplyRecordsOneMessagePacket() async {
        let rig = HookRig([.turn(Turns.text("Hi."))], log: makeLog())
        await rig.say("Hello")
        await rig.log.flush()
        XCTAssertEqual(lines(rig.log), ["besir>museSpark agentMessage ok Reply received"])
    }

    func testCONNECT_T32_EachFailureHasOneFixedWordAndNoRawError() async {
        let body = Data("BODY-500-SECRET".utf8)
        let cases: [(step: FakeTransport.Step, word: String)] = [
            (.fail(AgentTransportError.offline), "Offline"),
            (.fail(AgentTransportError.timedOut), "Timed out"),
            (.fail(AgentTransportError.http(status: 401, body: workerBody)), "Rejected"),
            (.fail(AgentTransportError.http(status: 500, body: body)), "Unexpected"),
            (.fail(AgentTransportError.http(status: 401, body: body)), "Unexpected"),
            (.fail(AgentTransportError.unreadableBody), "Unexpected"),
            (.turn(Turns.turn(Turns.reasoning())), "Unexpected")
        ]
        for item in cases {
            let rig = HookRig([item.step], log: makeLog())
            await rig.say("Hello")
            await rig.log.flush()
            XCTAssertEqual(lines(rig.log), ["besir>museSpark agentMessage failed \(item.word)"], item.word)
        }
    }

    func testCONNECT_T33_ACancelledRequestAndItsLateAnswerRecordNothing() async {
        for close in ["newChat", "sheetDismissed"] {
            let rig = HookRig([.hold], log: makeLog())
            rig.session.send("Hello")
            let arrived = await rig.fake.waitForRequests(1)
            XCTAssertTrue(arrived, close)
            if close == "newChat" { await rig.session.newChat() } else { await rig.session.sheetDismissed() }
            XCTAssertTrue(rig.fake.release(1, .success(Turns.text("late"))), close)
            await rig.session.settle()
            await rig.log.flush()
            XCTAssertEqual(rig.log.packets, [], close)
        }

        let rig = HookRig([.turn(Turns.create(id: "c1"))], log: makeLog())
        await rig.say("Add a meeting")
        XCTAssertNotNil(rig.session.pendingCard)
        await rig.session.newChat()
        await rig.log.flush()
        XCTAssertEqual(lines(rig.log), ["besir>museSpark agentMessage ok Reply received"])
        XCTAssertEqual(toolPackets(rig.log), [])
    }

    func testCONNECT_T34_ToolCallsRecordTheirFinalStatus() async throws {
        // A list answer has no status: ok.
        let list = HookRig([.turn(Turns.list(id: "c1")), .turn(Turns.text("Nothing."))], log: makeLog())
        await list.say("What do I have?")
        await list.log.flush()
        XCTAssertEqual(lines(list.log), ["besir>museSpark agentMessage ok Reply received",
                                         "museSpark>besir agentToolCall ok list activities",
                                         "besir>museSpark agentMessage ok Reply received"])

        // A call the toolbox rejects.
        let rejected = HookRig([.turn(Turns.turn(Turns.call("create_activity", "{}", id: "c1"))), .turn(Turns.text("Sorry."))], log: makeLog())
        await rejected.say("Add")
        await rejected.log.flush()
        XCTAssertEqual(rejected.resultStatuses, ["rejected"])
        XCTAssertEqual(toolPackets(rejected.log), ["create activity failed"])

        // A card cancelled, and a card confirmed.
        let cancel = HookRig([.turn(Turns.create(id: "c1")), .turn(Turns.text("Ok."))], log: makeLog())
        await cancel.say("Add a meeting")
        await cancel.session.cancelCard()
        await cancel.session.settle()
        await cancel.log.flush()
        XCTAssertEqual(toolPackets(cancel.log), ["create activity declined"])

        let confirm = HookRig([.turn(Turns.create(id: "c1")), .turn(Turns.text("Done."))], log: makeLog())
        await confirm.say("Add a meeting")
        await confirm.session.confirmCard()
        await confirm.session.settle()
        await confirm.log.flush()
        XCTAssertEqual(confirm.resultStatuses, ["applied"])
        XCTAssertEqual(toolPackets(confirm.log), ["create activity ok"])

        // The step limit: the sixth response's call is not executed and is answered `rejected`.
        var steps: [FakeTransport.Step] = (1...5).map { .turn(Turns.list(id: "c\($0)")) }
        steps.append(.turn(Turns.create(id: "c6")))
        let limit = HookRig(steps, log: makeLog())
        await limit.say("Add a meeting")
        await limit.log.flush()
        XCTAssertEqual(toolPackets(limit.log), Array(repeating: "list activities ok", count: 5) + ["create activity failed"])
    }

    func testCONNECT_T35_OneMessageIsOneFlow() async {
        let rig = HookRig([.turn(Turns.list(id: "c1")), .turn(Turns.text("Nothing.")), .turn(Turns.text("Fine."))], log: makeLog())
        await rig.say("What do I have?")
        await rig.log.flush()
        XCTAssertEqual(rig.log.packets.count, 3)
        XCTAssertEqual(Set(rig.log.packets.map(\.flowID)).count, 1)
        XCTAssertNotNil(rig.log.packets[0].flowID)
        XCTAssertEqual(chains(rig.log), ["besir → Muse Spark → besir → Muse Spark"])

        await rig.say("And tomorrow?")
        await rig.log.flush()
        XCTAssertEqual(rig.log.packets.count, 4)
        XCTAssertNotEqual(rig.log.packets[3].flowID, rig.log.packets[0].flowID)
        XCTAssertNotNil(rig.log.packets[3].flowID)
    }

    func testCONNECT_T36_NoSecretReachesTheFile() async throws {
        let underscored = "sentinel_tok_en1"
        for token in [FakeTransport.token, underscored] {
            let made = makeLog(secrets: [token, FakeTransport.host])
            let body = Data("\(token) \(FakeTransport.host)".utf8)
            let rig = HookRig([.turn(Turns.turn(Turns.call(token, "{}", id: "c1"))),
                               .fail(AgentTransportError.http(status: 500, body: body))], log: made.log)
            await rig.say("visit \(FakeTransport.host)")
            await made.log.flush()

            // Both sentinels were really there to leak: the second request carries the call name and the user text.
            let sent = String(describing: rig.fake.request(2))
            XCTAssertTrue(sent.contains(token), token)
            XCTAssertTrue(sent.contains(FakeTransport.host), token)

            // The call name is model text: it is not a declared name, so it is stored as `Unknown tool`, never as itself.
            XCTAssertEqual(made.log.packets.map(\.summary), ["Reply received", "Unknown tool", "Unexpected"], token)
            let bytes = String(decoding: try Data(contentsOf: made.file), as: UTF8.self)
            XCTAssertFalse(bytes.contains(token), token)
            XCTAssertFalse(bytes.contains(FakeTransport.host), token)
        }
    }

    func testCONNECT_T40_AnUnwritableLogChangesNothingTheChatShows() async {
        let script: () -> [FakeTransport.Step] = {
            [.turn(Turns.list(id: "c1")), .turn(Turns.text("Nothing.")), .fail(AgentTransportError.offline)]
        }
        let good = HookRig(script(), log: makeLog())
        let bad = HookRig(script(), log: makeLog(failing: true))
        for rig in [good, bad] {
            await rig.say("What do I have?")
            await rig.say("And later?")
        }
        XCTAssertEqual(good.session.chatLines, bad.session.chatLines)
        XCTAssertEqual(good.session.errorLines, bad.session.errorLines)
        XCTAssertEqual(good.fake.requests.count, bad.fake.requests.count)
        await bad.log.flush()
        XCTAssertFalse(bad.log.packets.isEmpty)
    }

    func testCONNECT_T43_AConfirmedCardWhoseRecordChangedOrVanishedIsFailed() async throws {
        for vanish in [false, true] {
            let rig = HookRig([], log: makeLog())
            let record = rig.tools.seed("Review", "2026-10-28T10:00", "2026-10-28T11:00")
            let args = "{\"id\":\"\(record.id.uuidString)\",\"title\":\"Review 2\"}"
            rig.fake.enqueue(.turn(Turns.turn(Turns.call("update_activity", args, id: "c1"))), .turn(Turns.text("Ok.")))
            await rig.say("Rename it")
            XCTAssertNotNil(rig.session.pendingCard)
            if vanish {
                rig.tools.store.activities.removeAll()
            } else if let index = rig.tools.store.activities.firstIndex(where: { $0.id == record.id }) {
                rig.tools.store.activities[index].title = "Changed elsewhere"
            }
            await rig.session.confirmCard()
            await rig.session.settle()
            await rig.log.flush()
            XCTAssertEqual(rig.resultStatuses, [vanish ? "not_found" : "stale"])
            XCTAssertEqual(toolPackets(rig.log), ["update activity failed"])
        }
    }

    func testCONNECT_T44_ASendTakesTheOfferedFlowOnce() async {
        let rig = HookRig([.turn(Turns.text("One.")), .turn(Turns.text("Two."))], log: makeLog())
        let offered = ConnectionLog.beginFlow()
        rig.log.offerFlow(offered)
        await rig.say("First")
        XCTAssertNil(rig.log.takeOfferedFlow())
        await rig.say("Second")
        await rig.log.flush()
        XCTAssertEqual(rig.log.packets.count, 2)
        XCTAssertEqual(rig.log.packets[0].flowID, offered)
        XCTAssertNotNil(rig.log.packets[1].flowID)
        XCTAssertNotEqual(rig.log.packets[1].flowID, offered)
    }

    func testCONNECT_T47_ARefusedSendLeavesTheOfferInPlace() async {
        let rig = HookRig([.turn(Turns.create(id: "c1")), .turn(Turns.text("Ok.")), .turn(Turns.text("Again."))], log: makeLog())
        let blank = ConnectionLog.beginFlow()
        rig.log.offerFlow(blank)
        rig.session.send("   ")
        XCTAssertEqual(rig.log.takeOfferedFlow(), blank)

        await rig.say("Add a meeting")
        XCTAssertNotNil(rig.session.pendingCard)
        let pending = ConnectionLog.beginFlow()
        rig.log.offerFlow(pending)
        rig.session.send("Something else")
        XCTAssertEqual(rig.fake.requests.count, 1)
        XCTAssertEqual(rig.log.takeOfferedFlow(), pending)

        rig.log.offerFlow(pending)
        rig.log.withdrawOffer()
        XCTAssertNil(rig.log.takeOfferedFlow())
        await rig.session.cancelCard()
        await rig.session.settle()
        await rig.say("Again")
        await rig.log.flush()
        XCTAssertFalse(rig.log.packets.isEmpty)
        XCTAssertFalse(rig.log.packets.contains { $0.flowID == pending || $0.flowID == blank })
    }

    func testCONNECT_T64_ASendThatSendsNothingRecordsNothing() async {
        let rig = HookRig([], log: makeLog())
        rig.fake.isConfigured = false
        rig.log.offerFlow(ConnectionLog.beginFlow())
        await rig.say("Hello")
        await rig.log.flush()
        XCTAssertEqual(rig.session.errorLines, ["The assistant is not set up in this build."])
        XCTAssertEqual(rig.fake.requests.count, 0)
        XCTAssertEqual(rig.log.packets, [])
        XCTAssertNil(rig.log.takeOfferedFlow())
    }

    func testCONNECT_T65_OnlyTheFirstCallOfAResponseIsRecorded() async {
        let two = Turns.turn(Turns.call("list_activities", Turns.listArguments, id: "c1"),
                             Turns.call("list_activities", Turns.listArguments, id: "c2"))
        let rig = HookRig([.turn(two), .turn(Turns.text("Done."))], log: makeLog())
        await rig.say("What do I have?")
        await rig.log.flush()
        XCTAssertEqual(toolPackets(rig.log), ["list activities ok"])
        XCTAssertEqual(rig.resultStatuses, ["ok", "rejected"])
    }

    // MARK: - Share and image reading (T48-T57, T66-T68)

    @MainActor private struct ShareRig {
        let inbox: SharedInbox
        let importer: SharedImport
        let reader = FakeVisionReader()
        let handOff = FakeHandOff()
        let log: ConnectionLog
    }

    private var imageBase64: String { Data(count: 1_000).base64EncodedString() }

    private func makeShare(log: ConnectionLog? = nil) throws -> ShareRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("connshare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedInbox(directory: root.appendingPathComponent("inbox", isDirectory: true),
                                legacyFile: root.appendingPathComponent("pendingShares.json"))
        let log = log ?? makeLog()
        let importer = SharedImport(inbox: inbox, connections: log)
#if DEBUG
        importer.logURL = root.appendingPathComponent("import.log")
#endif
        return ShareRig(inbox: inbox, importer: importer, log: log)
    }

    @discardableResult
    private func enqueue(_ rig: ShareRig, text: String? = nil, image: String? = nil) -> SharedInbox.Item {
        let item = SharedInbox.Item(id: UUID(), receivedAt: Date().addingTimeInterval(-5), text: text,
                                    imageBase64: image, mimeType: image == nil ? nil : "image/jpeg")
        XCTAssertTrue(rig.inbox.enqueue(item))
        return item
    }

    private func pass(_ rig: ShareRig, canHand: Bool = true) async {
        await rig.importer.pass(vision: rig.reader, canHand: { canHand }, hand: rig.handOff.hand)
    }

    func testCONNECT_T48_APlainTextShareRecordsOnePacket() async throws {
        let rig = try makeShare()
        enqueue(rig, text: "Dinner with Sam on Friday at 7")
        await pass(rig)
        await rig.log.flush()
        XCTAssertEqual(lines(rig.log), ["shareSheet>besir share ok Text shared"])
        XCTAssertEqual(rig.handOff.messages.count, 1)
    }

    func testCONNECT_T49_ABareLinkNamesInstagramOnlyForInstagram() async throws {
        let insta = try makeShare()
        enqueue(insta, text: "https://www.instagram.com/p/AbC123/")
        await pass(insta)
        await insta.log.flush()
        XCTAssertEqual(lines(insta.log), ["instagram>besir share ok Link shared"])
        XCTAssertTrue(insta.handOff.messages.isEmpty)

        let other = try makeShare()
        enqueue(other, text: "https://example.org/event")
        await pass(other)
        await other.log.flush()
        XCTAssertEqual(lines(other.log), ["shareSheet>besir share ok Link shared"])
        XCTAssertTrue(other.handOff.messages.isEmpty)
    }

    func testCONNECT_T50_AnImageShareAndItsReadingJoinOneFlowWithoutContent() async throws {
        let rig = try makeShare()
        enqueue(rig, text: "SECRET CAPTION words", image: imageBase64)
        await pass(rig)
        await rig.log.flush()
        XCTAssertEqual(lines(rig.log), ["shareSheet>besir share ok Image shared", "besir>imageReader imageRead ok Image read"])
        XCTAssertNotNil(rig.log.packets[0].flowID)
        XCTAssertEqual(rig.log.packets[0].flowID, rig.log.packets[1].flowID)
        for summary in rig.log.packets.map(\.summary) {
            for word in ["JAZZ", "Blue Note", "2026-11-07", "SECRET", "CAPTION"] { XCTAssertFalse(summary.contains(word)) }
        }
    }

    func testCONNECT_T51_EveryReadingFailureIsRecordedAndAnUnsetBuildRecordsNothing() async throws {
        for failure in [VisionFailure.offline, .tokenRejected, .busy, .other] {
            let rig = try makeShare()
            rig.reader.result = .failure(failure)
            enqueue(rig, image: imageBase64)
            await pass(rig)
            await rig.log.flush()
            XCTAssertEqual(lines(rig.log), ["shareSheet>besir share ok Image shared", "besir>imageReader imageRead failed Image read failed"],
                           "\(failure)")
        }
        let unset = try makeShare()
        unset.reader.isConfigured = false
        enqueue(unset, image: imageBase64)
        await pass(unset)
        await unset.log.flush()
        XCTAssertEqual(unset.log.packets, [])
        XCTAssertEqual(unset.reader.calls, 0)
        XCTAssertEqual(unset.inbox.pending().count, 1)
    }

    func testCONNECT_T52_AnOversizeImageAndAnEmptyShareAreRecordedAsFailed() async throws {
        let big = try makeShare()
        enqueue(big, image: Data(count: SharedImage.maxBytes + 1).base64EncodedString())
        await pass(big)
        await big.log.flush()
        XCTAssertEqual(lines(big.log), ["shareSheet>besir share failed Image shared"])
        XCTAssertEqual(big.reader.calls, 0)

        let empty = try makeShare()
        enqueue(empty, text: "   ")
        await pass(empty)
        await empty.log.flush()
        XCTAssertEqual(lines(empty.log), ["shareSheet>besir share failed Empty share"])
    }

    func testCONNECT_T53_ARetryAfterARefusedHandOffRecordsNothingAndKeepsTheFlow() async throws {
        let rig = try makeShare()
        enqueue(rig, image: imageBase64)
        var offered: [UUID?] = []
        var accepts = false
        let hand: (String) -> Bool = { _ in
            let flow = rig.log.takeOfferedFlow()
            offered.append(flow)
            if let flow { rig.log.offerFlow(flow) }
            return accepts
        }
        await rig.importer.pass(vision: rig.reader, canHand: { true }, hand: hand)
        accepts = true
        await rig.importer.pass(vision: rig.reader, canHand: { true }, hand: hand)
        await rig.log.flush()
        XCTAssertEqual(rig.log.packets.count, 2)
        XCTAssertEqual(rig.reader.calls, 1)
        XCTAssertEqual(offered.count, 2)
        XCTAssertNotNil(offered[0])
        XCTAssertEqual(offered[0], offered[1])
        XCTAssertEqual(offered[0], rig.log.packets[0].flowID)
    }

    func testCONNECT_T54_TheOfferLivesOnlyInsideTheHandOff() async throws {
        for accepts in [true, false] {
            let rig = try makeShare()
            enqueue(rig, image: imageBase64)
            var inside: UUID?
            await rig.importer.pass(vision: rig.reader, canHand: { true }, hand: { _ in
                inside = rig.log.takeOfferedFlow()
                if let inside { rig.log.offerFlow(inside) }
                return accepts
            })
            await rig.log.flush()
            XCTAssertNotNil(inside)
            XCTAssertEqual(inside, rig.log.packets.first?.flowID)
            XCTAssertNil(rig.log.takeOfferedFlow(), "accepts: \(accepts)")
        }
    }

    func testCONNECT_T55_ARealSessionJoinsTheSharesFlow() async throws {
        let rig = try makeShare()
        enqueue(rig, image: imageBase64)
        let session = AgentSession(toolbox: ToolHarness.make().tools, transport: FakeTransport([.turn(Turns.text("Noted."))]),
                                   connections: rig.log)
        await rig.importer.pass(vision: rig.reader, canHand: { session.canSend }, hand: { message in
            session.send(message)
            return true
        })
        await session.settle()
        await rig.log.flush()
        XCTAssertEqual(rig.log.packets.count, 3)
        XCTAssertEqual(Set(rig.log.packets.map(\.flowID)).count, 1)
        XCTAssertEqual(chains(rig.log), ["Share sheet → besir → Image reader → besir → Muse Spark"])
    }

    func testCONNECT_T56_APassThatReturnsEarlyRecordsNothing() async throws {
        let rig = try makeShare()
        await pass(rig)
        enqueue(rig, text: "Dinner on Friday")
        await pass(rig, canHand: false)
        await rig.log.flush()
        XCTAssertEqual(rig.log.packets, [])
        XCTAssertEqual(rig.inbox.pending().count, 1)
    }

    func testCONNECT_T57_AnUnwritableLogChangesNothingAShareDoes() async throws {
        let scenarios: [(text: String?, image: Bool)] = [("Dinner on Friday", false), ("https://example.org/x", false), (nil, true)]
        for scenario in scenarios {
            let good = try makeShare()
            let bad = try makeShare(log: makeLog(failing: true))
            for rig in [good, bad] {
                enqueue(rig, text: scenario.text, image: scenario.image ? imageBase64 : nil)
                await pass(rig)
            }
            XCTAssertEqual(good.importer.alertLine, bad.importer.alertLine)
            XCTAssertEqual(good.handOff.messages, bad.handOff.messages)
            XCTAssertEqual(good.inbox.pending().count, bad.inbox.pending().count)
            await bad.log.flush()
            XCTAssertFalse(bad.log.packets.isEmpty)
        }
    }

    func testCONNECT_T66_AReadingThatFoundNothingIsStillOk() async throws {
        let rig = try makeShare()
        rig.reader.result = .success(VisionFields(title: nil, time: nil, place: nil, confidence: 0))
        enqueue(rig, image: imageBase64)
        await pass(rig)
        await rig.log.flush()
        XCTAssertEqual(lines(rig.log), ["shareSheet>besir share ok Image shared", "besir>imageReader imageRead ok Image read"])
        XCTAssertEqual(rig.importer.alertLine, SharedLine.nothingFound)
        XCTAssertTrue(rig.handOff.messages.isEmpty)
    }

    func testCONNECT_T67_NoRequestWasSentSoNoReadingIsRecorded() async throws {
        for failure in [VisionFailure.notSetUp, .imageUnreadable] {
            let rig = try makeShare()
            rig.reader.result = .failure(failure)
            enqueue(rig, image: imageBase64)
            await pass(rig)
            await rig.log.flush()
            XCTAssertEqual(lines(rig.log), ["shareSheet>besir share ok Image shared"], "\(failure)")
        }
    }

    func testCONNECT_T68_ACancelledPassRecordsTheShareButNotTheReading() async throws {
        let rig = try makeShare()
        enqueue(rig, image: imageBase64)
        await cancelled { await self.pass(rig) }
        await rig.log.flush()
        XCTAssertEqual(lines(rig.log), ["shareSheet>besir share ok Image shared"])
    }

    // MARK: - Routes (T58-T63, T69)

    private func directions(_ stub: RoutesTransportStub, _ log: ConnectionLog, config: AppConfig = Routes.config) -> DirectionsService {
        DirectionsService(config: config, transport: stub.transport, connections: log)
    }

    func testCONNECT_T58_EachModeRecordsItsFixedSummary() async throws {
        let expected: [(TransportMode, String)] = [(.car, "Car route"), (.transit, "Transit route"), (.walk, "Walk route"), (.bicycle, "Bicycle route")]
        for (mode, summary) in expected {
            let log = makeLog()
            let stub = RoutesTransportStub.answering(with: try Routes.fixture("routes-drive"))
            let estimate = await directions(stub, log).estimate(mode, from: Routes.origin, to: Routes.dest)
            XCTAssertEqual(estimate.duration, 1053)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>googleRoutes route ok \(summary)"])
            XCTAssertNil(log.packets[0].summary.rangeOfCharacter(from: .decimalDigits))
            XCTAssertNil(log.packets[0].flowID)
        }
    }

    func testCONNECT_T59_AFailedLookupIsRecordedAndReturnsTheSameFailure() async throws {
        let cases: [(name: String, stub: RoutesTransportStub, status: String)] = [
            ("500", .answering(status: 500, with: Data("{}".utf8)), "failed"),
            ("offline", .throwing(URLError(.notConnectedToInternet)), "failed"),
            ("empty routes", .answering(with: try Routes.fixture("routes-empty-routes")), "noRoute"),
            ("worker 401", .answering(status: 401, with: try Routes.fixture("routes-worker-unauthorized")), "failed")
        ]
        for item in cases {
            let log = makeLog()
            let estimate = await directions(item.stub, log).estimate(.car, from: Routes.origin, to: Routes.dest)
            let silent = await directions(item.stub, makeLog(failing: true)).estimate(.car, from: Routes.origin, to: Routes.dest)
            XCTAssertNotNil(estimate.failure, item.name)
            XCTAssertEqual(estimate.failure, silent.failure, item.name)
            await log.flush()
            XCTAssertEqual(lines(log), ["besir>googleRoutes route \(item.status) Car route"], item.name)
        }
    }

    func testCONNECT_T60_NoRequestAndNoCancelledLookupLeaveNoPacket() async throws {
        let log = makeLog()
        let stub = RoutesTransportStub.answering(with: try Routes.fixture("routes-drive"))
        let unconfigured = await directions(stub, log, config: Routes.unconfigured).estimate(.car, from: Routes.origin, to: Routes.dest)
        XCTAssertEqual(unconfigured.failure, .notConfigured)
        XCTAssertEqual(stub.callCount, 0)

        let thrown = RoutesTransportStub.throwing(CancellationError())
        let aborted = await directions(thrown, log).estimate(.bicycle, from: Routes.origin, to: Routes.dest)
        XCTAssertNil(aborted.failure)
        XCTAssertEqual(thrown.callCount, 1)

        let service = directions(stub, log)
        _ = await cancelled { await service.estimate(.car, from: Routes.origin, to: Routes.dest) }
        XCTAssertEqual(stub.callCount, 1)
        await log.flush()
        XCTAssertEqual(log.packets, [])
    }

    func testCONNECT_T61_EstimateAllGivesFourPacketsInOneFlow() async throws {
        let answer = try Routes.fixture("routes-drive")
        let log = makeLog()
        let all = await directions(.answering(with: answer), log).estimateAll(from: Routes.origin, to: Routes.dest)
        let silent = await directions(.answering(with: answer), makeLog(failing: true)).estimateAll(from: Routes.origin, to: Routes.dest)
        await log.flush()
        XCTAssertEqual(log.packets.count, 4)
        XCTAssertEqual(Set(log.packets.map(\.flowID)).count, 1)
        XCTAssertNotNil(log.packets[0].flowID)
        XCTAssertEqual(Set(log.packets.map(\.summary)), ["Car route", "Transit route", "Walk route", "Bicycle route"])
        XCTAssertEqual(chains(log), ["besir → Google Routes"])
        for mode in TransportMode.allCases {
            XCTAssertEqual(all[mode]?.duration, silent[mode]?.duration, "\(mode)")
            XCTAssertEqual(all[mode]?.failure, silent[mode]?.failure, "\(mode)")
        }
    }

    func testCONNECT_T62_ATransitPlanRecordsItsStepsWithNoFlow() async throws {
        let ok = makeLog()
        let plan = await directions(.answering(with: try Routes.fixture("routes-transit-steps")), ok)
            .transitPlan(from: Routes.origin, to: Routes.dest)
        XCTAssertEqual(plan.steps.count, 3)
        let bad = makeLog()
        let none = await directions(.answering(with: try Routes.fixture("routes-empty-object")), bad)
            .transitPlan(from: Routes.origin, to: Routes.dest)
        XCTAssertEqual(none.failure, .noRoute)
        let silent = makeLog()
        let stub = RoutesTransportStub.answering(with: try Routes.fixture("routes-transit-steps"))
        _ = await directions(stub, silent, config: Routes.unconfigured).transitPlan(from: Routes.origin, to: Routes.dest)
        XCTAssertEqual(stub.callCount, 0)
        await ok.flush()
        await bad.flush()
        await silent.flush()
        XCTAssertEqual(lines(ok), ["besir>googleRoutes route ok Transit steps"])
        XCTAssertEqual(lines(bad), ["besir>googleRoutes route noRoute Transit steps"])
        XCTAssertNil(ok.packets[0].flowID)
        XCTAssertEqual(silent.packets, [])

        // The plan is the same whether or not the log can write (TransitPlan has no `==`: compare its fields).
        for fixture in ["routes-transit-steps", "routes-empty-object"] {
            let answer = try Routes.fixture(fixture)
            let logged = await directions(.answering(with: answer), makeLog()).transitPlan(from: Routes.origin, to: Routes.dest)
            let unlogged = await directions(.answering(with: answer), makeLog(failing: true)).transitPlan(from: Routes.origin, to: Routes.dest)
            XCTAssertEqual(logged.steps.count, unlogged.steps.count, fixture)
            XCTAssertEqual(logged.extraMinutes, unlogged.extraMinutes, fixture)
            XCTAssertEqual(logged.failure, unlogged.failure, fixture)
        }
    }

    func testCONNECT_T63_AnUnwritableLogChangesNothingARouteReturns() async throws {
        let answer = try Routes.fixture("routes-drive")
        let good = await directions(.answering(with: answer), makeLog()).estimate(.car, from: Routes.origin, to: Routes.dest)
        let log = makeLog(failing: true)
        let bad = await directions(.answering(with: answer), log).estimate(.car, from: Routes.origin, to: Routes.dest)
        XCTAssertEqual(good.duration, bad.duration)
        XCTAssertEqual(good.failure, bad.failure)
        let all = await directions(.answering(with: answer), log).estimateAll(from: Routes.origin, to: Routes.dest)
        XCTAssertEqual(all.values.compactMap(\.duration), Array(repeating: 1053, count: 4))
        await log.flush()
        XCTAssertEqual(log.packets.count, 5)
    }

    func testCONNECT_T69_ACancelledTransitPlanRecordsNothing() async throws {
        let log = makeLog()
        let stub = RoutesTransportStub.answering(with: try Routes.fixture("routes-transit-steps"))
        let service = directions(stub, log)
        _ = await cancelled { await service.transitPlan(from: Routes.origin, to: Routes.dest) }
        XCTAssertEqual(stub.callCount, 1)
        await log.flush()
        XCTAssertEqual(log.packets, [])
    }

    // MARK: - SPEC-CONNECT-002 (card t47): known tool names, "no route" as its own status

    /// A session whose model asks for one transit trip to the place `p1`, over a toolbox whose route lookup is stubbed
    /// and writes to the same log as the session.
    @MainActor private struct TravelRig {
        let fake: FakeTransport
        let session: AgentSession

        func say(_ text: String) async {
            session.send(text)
            await session.settle()
        }

        var resultStatuses: [String] {
            session.entries.compactMap { if case .result(let status) = $0.kind { return status } else { return nil } }
        }
    }

    /// The place search that registers `p1` writes to a throwaway log, so `log` holds only the session's packets and
    /// the route lookup's.
    private func travelRig(routes: RoutesTransportStub, log: ConnectionLog) async throws -> TravelRig {
        let store = EmptyStore.make()
        store.config = AppConfig()
        let instant = TestClock.date(TestClock.nowString)
        let found = PlacesTransportStub.answering(with: try Places.fixture("places-search-three"))
        let scratch = makeLog()
        let tools = AgentToolbox(store: store, now: { instant }, timeZone: { TestClock.zone },
                                 deviceOrigin: { PlaceFixture.device },
                                 places: { PlaceSearch(config: Places.config, transport: found.transport, connections: scratch) },
                                 directions: { DirectionsService(config: Routes.config, transport: routes.transport, connections: log) })
        let search = tools.handle(name: "search_places", arguments: PlaceTurns.arguments(["query": "cafe"]))
        let lookup = try XCTUnwrap(search.lookup, "search_places did not answer with a lookup")
        _ = await lookup.run()
        let fake = FakeTransport([.turn(PlaceTurns.travel("p1", mode: "transit", id: "c1")),
                                  .turn(Turns.text("I cannot answer that."))])
        return TravelRig(fake: fake, session: AgentSession(toolbox: tools, transport: fake, connections: log))
    }

    private func routeLines(_ log: ConnectionLog) -> [String] {
        lines(log).filter { $0.hasPrefix("besir>googleRoutes") }
    }

    func testCONNECT2_T01_EveryDeclaredNameIsKnownAndHandled() throws {
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: AgentTools.declarationsJSON()) as? [[String: Any]])
        let declared = list.compactMap { $0["name"] as? String }
        XCTAssertFalse(declared.isEmpty)
        XCTAssertEqual(AgentSession.knownToolNames(), Set(declared))
        XCTAssertEqual(AgentSession.knownToolNames(from: Data("not json".utf8)), [])
        XCTAssertEqual(AgentSession.knownToolNames(from: Data("[]".utf8)), [])

        let harness = ToolHarness.make()
        for name in declared {
            XCTAssertEqual(AgentSession.toolCallSummary(name), name.replacingOccurrences(of: "_", with: " "), name)
            XCTAssertNotEqual(harness.call(name, raw: "{}").message, ToolText.unknownTool, "\(name) is declared but not handled")
        }

        // A name outside the set is `Unknown tool` and the toolbox answers it with the re-ask.
        XCTAssertFalse(declared.contains("drop_everything"))
        XCTAssertEqual(AgentSession.toolCallSummary("drop_everything"), "Unknown tool")
        XCTAssertEqual(harness.call("drop_everything", raw: "{}").message, ToolText.unknownTool)
    }

    func testCONNECT2_T02_AContentLikeToolNameIsStoredAsUnknownTool() async throws {
        let name = "Dinner with Sam Friday 7pm at Blue Note"
        let made = makeLog(secrets: [])
        let rig = HookRig([.turn(Turns.turn(Turns.call(name, "{}", id: "c1"))), .turn(Turns.text("Sorry."))], log: made.log)
        await rig.say("Add dinner")
        await made.log.flush()

        XCTAssertEqual(rig.resultStatuses, ["rejected"])
        XCTAssertEqual(toolPackets(made.log), ["Unknown tool failed"])
        // The next model request was still sent, so the chat went on.
        XCTAssertEqual(rig.fake.request(2).isEmpty, false)
        let bytes = String(decoding: try Data(contentsOf: made.file), as: UTF8.self)
        for word in ["Dinner", "Sam", "Friday", "Blue", "Note"] {
            XCTAssertFalse(bytes.contains(word), word)
        }
    }

    func testCONNECT2_T03_NearMissNamesAreUnknown() {
        XCTAssertEqual(AgentSession.toolCallSummary("list_activities"), "list activities")
        let names = ["List_Activities", " list_activities", "list_activities ", "list-activities", "list activities",
                     String(repeating: "a", count: 200), ""]
        for name in names {
            XCTAssertEqual(AgentSession.toolCallSummary(name), "Unknown tool", "'\(name)'")
        }
    }

    func testCONNECT2_T04_ToolCallStatusTable() {
        let table: [(String, ConnectionStatus)] = [
            ("ok", .ok), ("applied", .ok), ("no_results", .failed), ("declined", .declined), ("no_route", .noRoute),
            ("rejected", .failed), ("not_found", .failed), ("stale", .failed), ("unavailable", .failed),
            ("something_else", .failed), ("", .failed)
        ]
        for (word, expected) in table {
            XCTAssertEqual(AgentSession.toolCallStatus(word), expected, "'\(word)'")
        }
    }

    func testCONNECT2_T05_ANoRouteAnswerIsNotAFailure() async throws {
        let log = makeLog()
        let rig = try await travelRig(routes: .answering(with: try Routes.fixture("routes-empty-object")), log: log)
        await rig.say("How long by transit?")
        await log.flush()
        XCTAssertEqual(rig.resultStatuses, ["no_route"])
        XCTAssertEqual(toolPackets(log), ["get travel time noRoute"])
        XCTAssertEqual(routeLines(log), ["besir>googleRoutes route noRoute Transit route"])
    }

    func testCONNECT2_T06_AnUnavailableAnswerIsStillAFailure() async throws {
        let log = makeLog()
        let rig = try await travelRig(routes: .answering(status: 403, with: try Routes.fixture("routes-google-error-403")), log: log)
        await rig.say("How long by transit?")
        await log.flush()
        XCTAssertEqual(rig.resultStatuses, ["unavailable"])
        XCTAssertEqual(toolPackets(log), ["get travel time failed"])
        XCTAssertEqual(routeLines(log), ["besir>googleRoutes route failed Transit route"])
    }

    func testCONNECT2_T07_EstimateAllNoRouteIsFourNoRoutePackets() async throws {
        let answer = try Routes.fixture("routes-empty-routes")
        let log = makeLog()
        let all = await directions(.answering(with: answer), log).estimateAll(from: Routes.origin, to: Routes.dest)
        let silent = await directions(.answering(with: answer), makeLog(failing: true)).estimateAll(from: Routes.origin, to: Routes.dest)
        await log.flush()
        XCTAssertEqual(log.packets.count, 4)
        XCTAssertEqual(Set(log.packets.map(\.status)), [.noRoute])
        XCTAssertEqual(Set(log.packets.map(\.flowID)).count, 1)
        XCTAssertNotNil(log.packets[0].flowID)
        XCTAssertEqual(chains(log), ["besir → Google Routes"])
        for mode in TransportMode.allCases {
            XCTAssertEqual(all[mode]?.failure, .noRoute, "\(mode)")
            XCTAssertEqual(all[mode]?.duration, silent[mode]?.duration, "\(mode)")
            XCTAssertEqual(all[mode]?.failure, silent[mode]?.failure, "\(mode)")
        }
    }
}
