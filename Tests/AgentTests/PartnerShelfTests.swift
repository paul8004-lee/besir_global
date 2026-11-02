import Network
import XCTest
@testable import besir

/// SPEC-PARTNEROFFLINE-001 (card t110): the partner buttons survive being offline. The keep, the shelf's rules, the pure rule of the
/// network probe and the loader's outcome. The view has no test host; its wiring is pinned by static checks (plan.md 6.2).
@MainActor
final class PartnerShelfTests: XCTestCase {
    // MARK: Helpers

    /// A probe a test sets by hand. Never told anything: not offline.
    private final class StubReachability: NetworkReachability {
        var offline = false
        var isOffline: Bool { offline }
    }

    /// A load the test scripts: counts its calls, answers the scripted loads in order, and can hold the first one until `open()`.
    private final class ScriptedLoad {
        private(set) var calls = 0
        private var script: [PartnerLoad]
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var holds = false
        var isWaiting: Bool { !waiting.isEmpty }

        init(_ script: [PartnerLoad]) { self.script = script }

        @MainActor
        func load() async -> PartnerLoad {
            calls += 1
            let next = script.isEmpty ? PartnerShelfTests.load(.failed) : script.removeFirst()
            if holds { await withCheckedContinuation { waiting.append($0) } }
            return next
        }

        /// Lets every held load go on, so a second load started by a broken shelf cannot leave the test waiting for ever.
        func open() {
            holds = false
            let held = waiting
            waiting = []
            for continuation in held { continuation.resume() }
        }
    }

    private static func load(_ outcome: PartnerLoad.Outcome, specs: [PartnerSpec] = [], raw: PartnerRaw? = nil) -> PartnerLoad {
        PartnerLoad(outcome: outcome, specs: specs, raw: raw ?? PartnerRaw(directory: Data(), forms: [:]))
    }

    /// The table partner and the delivery partner of the stub, each announcing a symbol.
    private func shapes(symbols: Bool = true) -> [StubPartner.Shape] {
        var tables = StubPartner.Shape.tables()
        var delivery = StubPartner.Shape.delivery()
        if symbols {
            tables.symbol = "fork.knife"
            delivery.symbol = "bicycle"
        }
        return [tables, delivery]
    }

    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The directory answer of the stub: with `symbols` the entries carry the symbol their shape announces.
    private func directoryData(_ shapes: [StubPartner.Shape], symbols: Bool = true, extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = ["partners": shapes.map { shape -> [String: Any] in
            var entry = shape.entry
            if symbols, let symbol = shape.symbol { entry["symbol"] = symbol }
            return entry
        }]
        for (key, value) in extra { object[key] = value }
        return json(object)
    }

    private func formData(_ shape: StubPartner.Shape) -> Data {
        json(["partner": shape.name, "simulated": true, "fields": shape.fields, "result_fields": shape.resultFields] as [String: Any])
    }

    private func rawOf(_ shapes: [StubPartner.Shape], symbols: Bool = true) -> PartnerRaw {
        PartnerRaw(directory: directoryData(shapes, symbols: symbols),
                   forms: Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, formData($0)) }))
    }

    private func rawOfTwoPartners() -> PartnerRaw { rawOf(shapes()) }

    /// What the two readers make of a raw, the one grammar the keep must agree with.
    private func expectedSpecs(_ raw: PartnerRaw) -> [PartnerSpec] {
        guard let entries = PartnerEntry.list(from: raw.directory, symbols: true) else { return [] }
        return entries.compactMap { entry in raw.forms[entry.id].flatMap { PartnerSpec.form(from: $0, entry: entry) } }
    }

    private func makeURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("partner-keep-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent(PartnerKeep.fileName)
    }

    private func makeKeep(write: (@Sendable (Data, URL) throws -> Void)? = nil) -> (keep: PartnerKeep, url: URL) {
        let url = makeURL()
        return (write.map { PartnerKeep(fileURL: url, write: $0) } ?? PartnerKeep(fileURL: url), url)
    }

    private func ids(_ specs: [PartnerSpec]?) -> [String]? { specs?.map(\.entry.id) }

    private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    // MARK: T01

    func testPARTNEROFFLINE_T01_AKeptListIsReadBackThroughTheReadersAndAFileThatNoLongerPassesIsNeverLoaded() throws {
        let raw = rawOfTwoPartners()
        let (keep, url) = makeKeep()
        keep.save(raw)

        let again = PartnerKeep(fileURL: url).read()
        XCTAssertEqual(again, expectedSpecs(raw))
        XCTAssertEqual(ids(again), ["booking", "delivery"])
        XCTAssertEqual(again?.map(\.entry.symbol), ["fork.knife", "bicycle"])

        let stored = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(stored.keys), ["directory", "forms"])
        XCTAssertEqual(Set((stored["forms"] as? [String: Any] ?? [:]).keys), ["booking", "delivery"])

        let other = makeKeep()
        XCTAssertNil(other.keep.read(), "no file")

        try FileManager.default.createDirectory(at: other.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: other.url)
        XCTAssertNil(other.keep.read(), "not json")

        other.keep.save(PartnerRaw(directory: json(["partners": [] as [Any]]), forms: raw.forms))
        XCTAssertNil(other.keep.read(), "the reader refuses 0 entries")

        other.keep.save(PartnerRaw(directory: raw.directory, forms: ["booking": Data("{}".utf8), "delivery": Data("{}".utf8)]))
        XCTAssertNil(other.keep.read(), "no good form")

        other.keep.save(PartnerRaw(directory: directoryData(shapes(), extra: ["x": 1]), forms: raw.forms))
        XCTAssertNil(other.keep.read(), "an extra top-level key")

        var oneBad = raw
        oneBad.forms["booking"] = Data("{}".utf8)
        other.keep.save(oneBad)
        XCTAssertEqual(ids(other.keep.read()), ["delivery"], "one bad form leaves the other partner")

        other.keep.save(rawOf(shapes(symbols: false), symbols: false))
        XCTAssertEqual(ids(other.keep.read()), ["booking", "delivery"])
        XCTAssertEqual(other.keep.read()?.map(\.entry.symbol), [nil, nil], "a plain five-key directory has no symbol")
    }

    // MARK: T02

    func testPARTNEROFFLINE_T02_TheShelfStartsWithTheKeptListAndOnlyASuccessfulLoadReplacesTheListAndTheFile() async throws {
        let raw = rawOfTwoPartners()
        let expected = expectedSpecs(raw)
        let (keep, url) = makeKeep()
        keep.save(raw)
        let before = bytes(url)
        XCTAssertNotNil(before, "the saved file exists")

        let shelf = PartnerShelf(keep: keep, reachability: StubReachability())
        XCTAssertEqual(ids(shelf.specs), ["booking", "delivery"], "the kept list is shown before any load")

        let offline = ScriptedLoad([Self.load(.offline)])
        let first = try XCTUnwrap(shelf.rowOpened(load: offline.load))
        await first.value
        XCTAssertEqual(ids(shelf.specs), ["booking", "delivery"])
        XCTAssertEqual(bytes(url), before, "an offline load leaves the file")

        let failed = ScriptedLoad([Self.load(.failed, specs: [expected[0]], raw: PartnerRaw(directory: Data("x".utf8), forms: [:]))])
        let second = try XCTUnwrap(shelf.rowOpened(load: failed.load), "an offline load left the screen free")
        await second.value
        XCTAssertEqual(ids(shelf.specs), ["booking", "delivery"])
        XCTAssertEqual(bytes(url), before, "a failed load leaves the file")

        let fresh = PartnerShelf(keep: PartnerKeep(fileURL: url), reachability: StubReachability())
        let deliveryOnly = rawOf([shapes()[1]])
        let loaded = ScriptedLoad([Self.load(.loaded, specs: [expected[1]], raw: deliveryOnly)])
        let third = try XCTUnwrap(fresh.rowOpened(load: loaded.load))
        await third.value
        XCTAssertEqual(ids(fresh.specs), ["delivery"])
        XCTAssertEqual(ids(PartnerKeep(fileURL: url).read()), ["delivery"])

        let broken = makeKeep(write: { _, _ in throw StubPartner.WriteFailure() })
        let lone = PartnerShelf(keep: broken.keep, reachability: StubReachability())
        let both = ScriptedLoad([Self.load(.loaded, specs: expected, raw: raw)])
        let fourth = try XCTUnwrap(lone.rowOpened(load: both.load))
        await fourth.value
        XCTAssertEqual(ids(lone.specs), ["booking", "delivery"], "a failed write leaves the screen working")
        XCTAssertNil(broken.keep.read())
    }

    // MARK: T03

    func testPARTNEROFFLINE_T03_ANeverLoadedShelfShowsNothingAsksAgainAfterAnOfflineLoadAndNeverAfterASuccessOrAFailure() async throws {
        let raw = rawOfTwoPartners()
        let expected = expectedSpecs(raw)
        let shelf = PartnerShelf(keep: makeKeep().keep, reachability: StubReachability())
        XCTAssertEqual(shelf.specs, [])

        let script = ScriptedLoad([Self.load(.offline), Self.load(.loaded, specs: expected, raw: raw)])
        let one = try XCTUnwrap(shelf.rowOpened(load: script.load))
        await one.value
        XCTAssertEqual(shelf.specs, [])
        let two = try XCTUnwrap(shelf.rowOpened(load: script.load), "asked again after an offline load")
        await two.value
        XCTAssertEqual(ids(shelf.specs), ["booking", "delivery"])
        XCTAssertNil(shelf.rowOpened(load: script.load))
        XCTAssertNil(shelf.rowOpened(load: script.load))
        XCTAssertEqual(script.calls, 2)

        let failing = PartnerShelf(keep: makeKeep().keep, reachability: StubReachability())
        let bad = ScriptedLoad([Self.load(.failed)])
        let first = try XCTUnwrap(failing.rowOpened(load: bad.load))
        await first.value
        XCTAssertEqual(failing.specs, [])
        XCTAssertNil(failing.rowOpened(load: bad.load), "a failed load is not repeated")
        XCTAssertEqual(bad.calls, 1)
    }

    // MARK: T04

    func testPARTNEROFFLINE_T04_TwoRowOpensInQuickSuccessionStartOneLoad() async throws {
        let shelf = PartnerShelf(keep: makeKeep().keep, reachability: StubReachability())
        let script = ScriptedLoad([Self.load(.offline), Self.load(.offline)])
        script.holds = true
        let first = try XCTUnwrap(shelf.rowOpened(load: script.load))
        XCTAssertNil(shelf.rowOpened(load: script.load), "a load is in flight")
        for _ in 0..<5000 where !script.isWaiting { await Task.yield() }
        XCTAssertTrue(script.isWaiting)
        XCTAssertEqual(script.calls, 1)
        script.open()
        await first.value
        let third = try XCTUnwrap(shelf.rowOpened(load: script.load), "offline frees the screen")
        await third.value
        XCTAssertEqual(script.calls, 2)
    }

    // MARK: T05

    func testPARTNEROFFLINE_T05_AnOfflineTapShowsTheErrorAndOpensNoCardAndAnOnlineTapOpensTheCard() async throws {
        let raw = rawOfTwoPartners()
        let (keep, _) = makeKeep()
        keep.save(raw)
        let probe = StubReachability()
        let shelf = PartnerShelf(keep: keep, reachability: probe)
        let spec = try XCTUnwrap(expectedSpecs(raw).first)

        probe.offline = true
        XCTAssertFalse(shelf.tapped(spec, row: "r1"))
        XCTAssertEqual(shelf.notice?.rowID, "r1")
        XCTAssertEqual(shelf.notice?.text, "You are offline.")
        let firstSerial = try XCTUnwrap(shelf.notice?.serial)

        XCTAssertFalse(shelf.tapped(spec, row: "r2"))
        XCTAssertEqual(shelf.notice?.rowID, "r2")
        XCTAssertGreaterThan(try XCTUnwrap(shelf.notice?.serial), firstSerial)

        probe.offline = false
        XCTAssertTrue(shelf.tapped(spec, row: "r2"))
        XCTAssertNil(shelf.notice)

        let loadedShelf = PartnerShelf(keep: makeKeep().keep, reachability: probe)
        let script = ScriptedLoad([Self.load(.loaded, specs: expectedSpecs(raw), raw: raw)])
        let task = try XCTUnwrap(loadedShelf.rowOpened(load: script.load))
        await task.value
        XCTAssertEqual(ids(loadedShelf.specs), ["booking", "delivery"])
        XCTAssertTrue(loadedShelf.tapped(spec, row: "r1"))
        XCTAssertNil(loadedShelf.notice)

        let untold = PartnerShelf(keep: keep, reachability: StubReachability())
        XCTAssertTrue(untold.tapped(spec, row: "r1"), "a probe that was never told anything is not offline")
    }

    // MARK: T06

    func testPARTNEROFFLINE_T06_OnlyAnUnsatisfiedPathCountsAsOffline() {
        XCTAssertTrue(PathReachability.isOffline(.unsatisfied))
        XCTAssertFalse(PathReachability.isOffline(.satisfied))
        XCTAssertFalse(PathReachability.isOffline(.requiresConnection))
        XCTAssertFalse(PathReachability.isOffline(nil))
        let probe: NetworkReachability = PathReachability.shared
        _ = probe
    }

    // MARK: T07

    func testPARTNEROFFLINE_T07_TheErrorLineGoesWhenItsRowClosesTheSearchChangesOrItExpires() throws {
        let raw = rawOfTwoPartners()
        let (keep, _) = makeKeep()
        keep.save(raw)
        let probe = StubReachability()
        probe.offline = true
        let shelf = PartnerShelf(keep: keep, reachability: probe)
        let spec = try XCTUnwrap(expectedSpecs(raw).first)

        XCTAssertFalse(shelf.tapped(spec, row: "r1"))
        XCTAssertNotNil(shelf.notice)
        shelf.rowClosed("r2")
        XCTAssertNotNil(shelf.notice, "another row closing keeps the line")
        shelf.rowClosed("r1")
        XCTAssertNil(shelf.notice)

        XCTAssertFalse(shelf.tapped(spec, row: "r1"))
        shelf.searchReplaced()
        XCTAssertNil(shelf.notice)

        XCTAssertFalse(shelf.tapped(spec, row: "r1"))
        let older = try XCTUnwrap(shelf.notice)
        XCTAssertFalse(shelf.tapped(spec, row: "r1"))
        let newer = try XCTUnwrap(shelf.notice)
        XCTAssertNotEqual(older.serial, newer.serial)
        shelf.expire(older)
        XCTAssertEqual(shelf.notice, newer, "the expiry of the first notice leaves the second")
        shelf.expire(newer)
        XCTAssertNil(shelf.notice)

        XCTAssertEqual(PartnerShelf.noticeSeconds, 4)
    }

    // MARK: T08

    private func stub(_ shapes: [StubPartner.Shape]) -> StubPartner {
        let partner = StubPartner()
        partner.shapes = shapes
        return partner
    }

    private func loadHand(_ rig: PartnerRig) async -> PartnerLoad {
        await rig.tools.loadPartnerDirectory(flow: ConnectionLog.beginFlow(), symbols: true)
    }

    func testPARTNEROFFLINE_T08_TheLoaderTellsSuccessfulOfflineOrFailedAndHandsBackTheAcceptedBytes() async throws {
        // (a) two partners with symbols
        let a = PartnerRig(partner: stub(shapes()))
        let loadedA = await loadHand(a)
        XCTAssertEqual(loadedA.outcome, .loaded)
        XCTAssertEqual(ids(loadedA.specs), ["booking", "delivery"])
        XCTAssertEqual(PartnerEntry.list(from: loadedA.raw.directory, symbols: true), loadedA.specs.map(\.entry))
        for spec in loadedA.specs {
            XCTAssertEqual(loadedA.raw.forms[spec.entry.id].flatMap { PartnerSpec.form(from: $0, entry: spec.entry) }, spec)
        }
        XCTAssertEqual(a.partner.requests.count, 3)
        let body = try XCTUnwrap(a.partner.body(0))
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body["op"] as? String, "list")
        XCTAssertEqual(body["symbols"] as? Bool, true)
        let wrapped = await a.tools.loadPartners(flow: ConnectionLog.beginFlow(), symbols: true)
        XCTAssertEqual(wrapped, loadedA.specs)

        // (b) offline from the first request
        let b = PartnerRig(partner: stub(shapes()))
        b.partner.mode = .error(URLError(.notConnectedToInternet))
        let loadedB = await loadHand(b)
        XCTAssertEqual(loadedB.outcome, .offline)
        XCTAssertEqual(loadedB.specs, [])
        XCTAssertEqual(loadedB.raw, PartnerRaw(directory: Data(), forms: [:]))

        // (c) the network goes at the third request, after the directory and one form were good
        let c = PartnerRig(partner: stub(shapes()))
        c.partner.duringSend = { [partner = c.partner] in
            if partner.requests.count == 3 { partner.mode = .error(URLError(.notConnectedToInternet)) }
        }
        let loadedC = await loadHand(c)
        XCTAssertEqual(loadedC.outcome, .offline)
        XCTAssertEqual(ids(loadedC.specs), ["booking"])

        // (d) failures that are not offline
        let d1 = PartnerRig(partner: stub(shapes()))
        d1.partner.brokenRoutes = ["/booking", "/delivery"]
        let failedD1 = await loadHand(d1)
        XCTAssertEqual(failedD1.outcome, .failed, "no form is good")
        let d2 = PartnerRig(partner: stub(shapes()))
        d2.partner.mode = .status(500, "oops")
        let failedD2 = await loadHand(d2)
        XCTAssertEqual(failedD2.outcome, .failed, "a server error")
        let d3 = PartnerRig(partner: stub(shapes()))
        d3.partner.mode = .status(401, "{\"error\":\"unauthorized\"}")
        let failedD3 = await loadHand(d3)
        XCTAssertEqual(failedD3.outcome, .failed, "a rejected token")
        let d4 = PartnerRig(partner: stub(shapes()))
        d4.partner.mode = .error(URLError(.timedOut))
        let failedD4 = await loadHand(d4)
        XCTAssertEqual(failedD4.outcome, .failed, "a time-out is not offline")

        // (e) one form broken, the other good
        let e = PartnerRig(partner: stub(shapes()))
        e.partner.brokenRoutes = ["/booking"]
        let loadedE = await loadHand(e)
        XCTAssertEqual(loadedE.outcome, .loaded)
        XCTAssertEqual(ids(loadedE.specs), ["delivery"])
        XCTAssertEqual(Set(loadedE.raw.forms.keys), ["delivery"])

        // (f) no proxy
        let f = PartnerRig(config: PlaceSentinel.unconfigured, partner: stub(shapes()))
        let loadedF = await loadHand(f)
        XCTAssertEqual(loadedF.outcome, .failed)
        XCTAssertEqual(f.partner.requests.count, 0)
    }

    // MARK: T09

    func testPARTNEROFFLINE_T09_TheModelPathLoadsAsBeforeAndWritesAndReadsNoFile() async throws {
        let file = PartnerKeep.defaultURL
        try? FileManager.default.removeItem(at: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }

        let first = PartnerRig()
        let listed = await first.listed()
        XCTAssertEqual((listed?["partners"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(first.partner.requests.count, 2)
        let body = try XCTUnwrap(first.partner.body(0))
        // SPEC-RICHSTATS-001 D11: the chat's lookup asks the directory with symbols so a booking can keep the partner's kind.
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body["op"] as? String, "list")
        XCTAssertEqual(body["symbols"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the model path writes no file")

        // Building a rig empties the support folder (`EmptyStore.make`), so the second rig is built before the seed is written.
        let second = PartnerRig()
        let seed = PartnerRaw(directory: directoryData([shapes()[1]]), forms: ["delivery": formData(shapes()[1])])
        let seedBytes = try JSONEncoder().encode(seed)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try seedBytes.write(to: file)

        let again = await second.listed()
        XCTAssertEqual((again?["partners"] as? [[String: Any]])?.map { $0["id"] as? String }, ["booking"], "nothing is read from the keep")
        let afterwards: Data? = FileManager.default.contents(atPath: file.path)
        XCTAssertEqual(afterwards, seedBytes, "the model path does not rewrite the file")
    }
}
