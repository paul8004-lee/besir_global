import XCTest
import CoreLocation
@testable import besir

/// A transport gate that ignores cancellation: a task suspended on it stays suspended until `open()`, and then goes on
/// even if it was cancelled meanwhile, so a cancelled lookup can still receive an answer.
private final class CancellationBlindGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var entered = false

    var hasEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            entered = true
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume()
    }
}

/// SPEC-ROUTELINE-001: the lookup, the key and the stale-answer slot (AC-ROUTELINE-004 and 005).
/// Every log is built with a temporary file; no key, no network.
final class RouteLineServiceTests: XCTestCase {
    private typealias Support = RoutesTestSupport
    private typealias Encoder = RouteLineTestEncoder

    private let lineMask = "routes.duration,routes.polyline.encodedPolyline"
    private let summary = "Route line"

    /// The invented points of routes-line-drive.json.
    private let driveUnits: [Encoder.Units] = [
        (3_779_550, -12_239_370), (3_778_600, -12_241_800), (3_776_500, -12_243_500), (3_775_200, -12_246_800),
        (3_772_100, -12_248_000), (3_770_200, -12_247_100), (3_769_400, -12_248_620)
    ]

    private let travelModes: [(mode: TransportMode, google: String)] = [
        (.car, "DRIVE"), (.transit, "TRANSIT"), (.walk, "WALK"), (.bicycle, "BICYCLE")
    ]

    // MARK: - Helpers

    private func makeLog() -> ConnectionLog {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("routeline-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return ConnectionLog(fileURL: folder.appendingPathComponent(ConnectionLog.fileName))
    }

    private func service(_ transport: @escaping GoogleRoutes.Transport, _ log: ConnectionLog,
                         config: AppConfig = Support.config) -> DirectionsService {
        DirectionsService(config: config, transport: transport, connections: log)
    }

    private func lookup(_ service: DirectionsService, mode: TransportMode = .car) async -> RouteLine {
        await service.routeLine(mode: mode, from: Support.origin, to: Support.dest)
    }

    /// One readable line per packet: `from>to kind status summary`.
    private func lines(_ log: ConnectionLog) async -> [String] {
        await log.flush()
        return log.packets.map { "\($0.from.rawValue)>\($0.to.rawValue) \($0.kind.rawValue) \($0.status.rawValue) \($0.summary)" }
    }

    private func assertDrivePoints(_ points: [RoutePoint], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(points.count, driveUnits.count, file: file, line: line)
        for (point, units) in zip(points, driveUnits) {
            XCTAssertEqual(point.latitude, Double(units.latitude) / 100_000, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(point.longitude, Double(units.longitude) / 100_000, accuracy: 1e-9, file: file, line: line)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<5_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("the transport was never reached")
    }

    /// Starts a lookup whose transport waits on a gate, cancels the task while it waits, then lets the answer through.
    private func cancelledLookup(answering data: Data) async throws -> (result: RouteLine, calls: Int, log: ConnectionLog) {
        let log = makeLog()
        let gate = CancellationBlindGate()
        let stub = RoutesTransportStub.answering(with: data)
        let gated: GoogleRoutes.Transport = { request in
            await gate.wait()
            return try await stub.transport(request)
        }
        let directions = service(gated, log)
        let task = Task { await directions.routeLine(mode: .car, from: Support.origin, to: Support.dest) }
        try await waitUntil { gate.hasEntered }
        task.cancel()
        gate.open()
        let result = await task.value
        return (result, stub.callCount, log)
    }

    private func key(_ mode: TransportMode = .car,
                     origin: (latitude: Double, longitude: Double) = (37.7955, -122.3937),
                     destination: (latitude: Double, longitude: Double) = (37.7694, -122.4862)) -> RouteLineKey? {
        RouteLineKey(mode: mode,
                     origin: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude),
                     destination: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude))
    }

    private func assertSame(_ first: RouteLineKey?, _ second: RouteLineKey?, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let first, let second else { return XCTFail("no key \(message)", file: file, line: line) }
        XCTAssertEqual(first, second, message, file: file, line: line)
        XCTAssertEqual(first.hashValue, second.hashValue, message, file: file, line: line)
    }

    private func assertDifferent(_ first: RouteLineKey?, _ second: RouteLineKey?, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let first, let second else { return XCTFail("no key \(message)", file: file, line: line) }
        XCTAssertNotEqual(first, second, message, file: file, line: line)
    }

    /// The latitude pair as the origin latitude and as the destination latitude; the longitude pair likewise.
    private func keys(latitude pair: (Double, Double)) -> [(RouteLineKey?, RouteLineKey?, String)] {
        [(key(origin: (pair.0, -122.3937)), key(origin: (pair.1, -122.3937)), "origin latitude \(pair)"),
         (key(destination: (pair.0, -122.4862)), key(destination: (pair.1, -122.4862)), "destination latitude \(pair)")]
    }

    private func keys(longitude pair: (Double, Double)) -> [(RouteLineKey?, RouteLineKey?, String)] {
        [(key(origin: (37.7955, pair.0)), key(origin: (37.7955, pair.1)), "origin longitude \(pair)"),
         (key(destination: (37.7694, pair.0)), key(destination: (37.7694, pair.1)), "destination longitude \(pair)")]
    }

    // MARK: - AC-ROUTELINE-004 lookup

    func testLINE_LookupOkReturnsPointsAndNotesRouteLine() async throws {
        let log = makeLog()
        let stub = RoutesTransportStub.answering(with: try Support.fixture("routes-line-drive"))
        let result = await lookup(service(stub.transport, log))
        XCTAssertNil(result.failure)
        assertDrivePoints(result.points)
        XCTAssertGreaterThanOrEqual(result.points.count, 2)
        XCTAssertEqual(stub.callCount, 1)
        let written = await lines(log)
        XCTAssertEqual(written, ["besir>googleRoutes route ok Route line"])
        XCTAssertEqual(log.packets.count, 1)
        XCTAssertEqual(log.packets.first?.summary, summary)
        XCTAssertEqual(log.packets.first?.status, .ok)
        XCTAssertNil(log.packets.first?.flowID)
    }

    func testLINE_LookupSendsLineRequestForEachMode() async throws {
        let answer = try Support.fixture("routes-line-drive")
        for (mode, google) in travelModes {
            let stub = RoutesTransportStub.answering(with: answer)
            _ = await lookup(service(stub.transport, makeLog()), mode: mode)
            XCTAssertEqual(stub.callCount, 1, "\(mode)")
            let request = try XCTUnwrap(stub.requests.first, "\(mode)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-fieldmask"), lineMask, "\(mode)")
            XCTAssertEqual(Support.travelMode(of: request), google, "\(mode)")
            XCTAssertEqual(Support.body(of: request)?["polylineQuality"] as? String, "OVERVIEW", "\(mode)")
        }
    }

    func testLINE_LookupNoRoute() async throws {
        let log = makeLog()
        let stub = RoutesTransportStub.answering(with: try Support.fixture("routes-empty-routes"))
        let result = await lookup(service(stub.transport, log))
        XCTAssertEqual(result.points, [])
        XCTAssertEqual(result.failure, .noRoute)
        let written = await lines(log)
        XCTAssertEqual(written, ["besir>googleRoutes route noRoute Route line"])
    }

    func testLINE_LookupMalformedAnswerIsLookupFailed() async throws {
        let log = makeLog()
        let stub = RoutesTransportStub.answering(with: try Support.fixture("routes-no-duration"))
        let result = await lookup(service(stub.transport, log))
        XCTAssertEqual(result.points, [])
        XCTAssertEqual(result.failure, .lookupFailed)
        let written = await lines(log)
        XCTAssertEqual(written, ["besir>googleRoutes route failed Route line"])
    }

    func testLINE_LookupAnswerWithoutPolylineIsLookupFailed() async throws {
        let log = makeLog()
        let stub = RoutesTransportStub.answering(with: try Support.fixture("routes-line-no-polyline"))
        let result = await lookup(service(stub.transport, log))
        XCTAssertEqual(result.points, [])
        XCTAssertEqual(result.failure, .lookupFailed)
        let written = await lines(log)
        XCTAssertEqual(written, ["besir>googleRoutes route failed Route line"])
    }

    func testLINE_LookupUndecodablePolylineIsLookupFailed() async throws {
        let log = makeLog()
        let stub = RoutesTransportStub.answering(with: try Support.fixture("routes-line-bad-polyline"))
        let result = await lookup(service(stub.transport, log))
        XCTAssertEqual(result.points, [])
        XCTAssertEqual(result.failure, .lookupFailed)
        let written = await lines(log)
        XCTAssertEqual(written, ["besir>googleRoutes route failed Route line"])
    }

    func testLINE_LookupHttpFailures() async throws {
        let cases: [(name: String, stub: RoutesTransportStub, failure: TravelFailure)] = [
            ("403", .answering(status: 403, with: Data("{}".utf8)), .notConfigured),
            ("500", .answering(status: 500, with: Data("{}".utf8)), .lookupFailed),
            ("offline", .throwing(URLError(.notConnectedToInternet)), .offline)
        ]
        for item in cases {
            let log = makeLog()
            let result = await lookup(service(item.stub.transport, log))
            XCTAssertEqual(result.points, [], item.name)
            XCTAssertEqual(result.failure, item.failure, item.name)
            XCTAssertEqual(item.stub.callCount, 1, item.name)
            let written = await lines(log)
            XCTAssertEqual(written, ["besir>googleRoutes route failed Route line"], item.name)
        }
    }

    func testLINE_LookupNotConfiguredSendsNothingAndRecordsNothing() async throws {
        let log = makeLog()
        let stub = RoutesTransportStub.answering(with: try Support.fixture("routes-line-drive"))
        let result = await lookup(service(stub.transport, log, config: Support.unconfigured))
        XCTAssertEqual(result.points, [])
        XCTAssertEqual(result.failure, .notConfigured)
        XCTAssertEqual(stub.callCount, 0)
        _ = await lines(log)
        XCTAssertEqual(log.packets, [])
    }

    func testLINE_CancelledTaskWithGoodAnswerReturnsNothing() async throws {
        let outcome = try await cancelledLookup(answering: try Support.fixture("routes-line-drive"))
        XCTAssertEqual(outcome.calls, 1)
        XCTAssertEqual(outcome.result.points, [])
        XCTAssertNil(outcome.result.failure)
        _ = await lines(outcome.log)
        XCTAssertEqual(outcome.log.packets, [])
    }

    func testLINE_CancelledTaskWithNoRouteAnswerReturnsNothing() async throws {
        let outcome = try await cancelledLookup(answering: try Support.fixture("routes-empty-routes"))
        XCTAssertEqual(outcome.calls, 1)
        XCTAssertEqual(outcome.result.points, [])
        XCTAssertNil(outcome.result.failure)
        _ = await lines(outcome.log)
        XCTAssertEqual(outcome.log.packets, [])
    }

    func testLINE_CancellationErrorRecordsNothing() async throws {
        let errors: [(name: String, error: Error)] = [("CancellationError", CancellationError()),
                                                       ("URLError cancelled", URLError(.cancelled))]
        for item in errors {
            XCTAssertFalse(Task.isCancelled, item.name)
            let log = makeLog()
            let stub = RoutesTransportStub.throwing(item.error)
            let result = await lookup(service(stub.transport, log))
            XCTAssertEqual(stub.callCount, 1, item.name)
            XCTAssertEqual(result.points, [], item.name)
            XCTAssertNil(result.failure, item.name)
            _ = await lines(log)
            XCTAssertEqual(log.packets, [], item.name)
        }
    }

    func testLINE_PacketTextHasNoCoordinateNorPolyline() async throws {
        let drive = try Support.fixture("routes-line-drive")
        let polyline = try XCTUnwrap(GoogleRoutes.parse(drive).encodedPolyline)
        XCTAssertFalse(polyline.isEmpty)
        let log = makeLog()
        let ok = RoutesTransportStub.answering(with: drive)
        let failed = RoutesTransportStub.answering(status: 500, with: Data("{}".utf8))
        let bad = RoutesTransportStub.answering(with: try Support.fixture("routes-line-bad-polyline"))
        for stub in [ok, failed, bad] {
            _ = await lookup(service(stub.transport, log), mode: .walk)
        }
        _ = await lines(log)
        XCTAssertEqual(log.packets.count, 3)
        let forbidden = ["37.7955", "-122.3937", "37.7694", "-122.4862", polyline, Support.token, Support.host]
        for packet in log.packets {
            XCTAssertEqual(packet.summary, summary)
            for text in forbidden {
                XCTAssertFalse(packet.summary.contains(text), text)
            }
        }
    }

    // MARK: - AC-ROUTELINE-005 key

    func testLINE_KeyEqualBelowPrecision() {
        let latitudes: [(Double, Double)] = [(37.79551, 37.79553), (37.79545, 37.79554)]
        let longitudes: [(Double, Double)] = [(-122.39371, -122.39373), (-122.39378, -122.39382), (-122.39365, -122.39374)]
        for pair in latitudes {
            for (first, second, name) in keys(latitude: pair) { assertSame(first, second, name) }
        }
        for pair in longitudes {
            for (first, second, name) in keys(longitude: pair) { assertSame(first, second, name) }
        }
    }

    func testLINE_KeyDiffersAtPrecision() {
        let latitudes: [(Double, Double)] = [(37.7952, 37.7954), (37.7692, 37.7694), (37.79554, 37.79556)]
        let longitudes: [(Double, Double)] = [(-122.39374, -122.39376)]
        for pair in latitudes {
            for (first, second, name) in keys(latitude: pair) { assertDifferent(first, second, name) }
        }
        for pair in longitudes {
            for (first, second, name) in keys(longitude: pair) { assertDifferent(first, second, name) }
        }
    }

    func testLINE_KeyIncludesModeAndBothEnds() {
        assertDifferent(key(.car), key(.walk), "mode")
        assertDifferent(key(.walk), key(.walk, destination: (37.7690, -122.4862)), "destination only")
        assertDifferent(key(.walk), key(.walk, origin: (37.7950, -122.3937)), "origin only")
        assertSame(key(.walk), key(.walk), "same inputs")
        XCTAssertEqual(key(.transit)?.mode, .transit)
    }

    func testLINE_KeyAbsentForInvalidCoordinates() {
        XCTAssertNotNil(key())
        XCTAssertNil(key(origin: (91, -122.3937)), "origin latitude 91")
        XCTAssertNil(key(origin: (37.7955, .nan)), "origin longitude NaN")
        XCTAssertNil(key(origin: (.infinity, -122.3937)), "origin latitude infinity")
        XCTAssertNil(key(destination: (91, -122.4862)), "destination latitude 91")
        XCTAssertNil(key(destination: (37.7694, .nan)), "destination longitude NaN")
        XCTAssertNil(key(destination: (.infinity, -122.4862)), "destination latitude infinity")
        let valid = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
        XCTAssertNil(RouteLineKey(mode: .car, origin: nil, destination: valid), "no origin")
        XCTAssertNil(RouteLineKey(mode: .car, origin: valid, destination: nil), "no destination")
    }

    // MARK: - AC-ROUTELINE-005 slot

    private let first = [RoutePoint(latitude: 37.7955, longitude: -122.3937), RoutePoint(latitude: 37.7694, longitude: -122.4862)]
    private let second = [RoutePoint(latitude: 37.80, longitude: -122.40), RoutePoint(latitude: 37.75, longitude: -122.45),
                          RoutePoint(latitude: 37.77, longitude: -122.48)]

    func testLINE_SlotAcceptsAnswerForCurrentKey() throws {
        let k1 = try XCTUnwrap(key(.car))
        var slot = RouteLineSlot()
        slot.begin(k1)
        XCTAssertEqual(slot.key, k1)
        XCTAssertEqual(slot.points, [])
        XCTAssertTrue(slot.accept(first, for: k1))
        XCTAssertEqual(slot.points, first)
        XCTAssertEqual(slot.key, k1)
    }

    func testLINE_SlotRejectsStaleAnswer() throws {
        let k1 = try XCTUnwrap(key(.car))
        let k2 = try XCTUnwrap(key(.walk))
        var slot = RouteLineSlot()
        slot.begin(k1)
        slot.begin(k2)
        XCTAssertFalse(slot.accept(first, for: k1))
        XCTAssertEqual(slot.points, [])

        var later = RouteLineSlot()
        later.begin(k1)
        later.begin(k2)
        XCTAssertTrue(later.accept(second, for: k2))
        XCTAssertFalse(later.accept(first, for: k1))
        XCTAssertEqual(later.points, second)

        var cleared = RouteLineSlot()
        cleared.begin(k1)
        XCTAssertTrue(cleared.accept(first, for: k1))
        cleared.begin(nil)
        XCTAssertEqual(cleared.points, [])
        XCTAssertNil(cleared.key)
        XCTAssertFalse(cleared.accept(first, for: k1))
        XCTAssertFalse(cleared.accept(second, for: k2))
        XCTAssertEqual(cleared.points, [])
    }

    func testLINE_SlotBeginClearsPoints() throws {
        let k1 = try XCTUnwrap(key(.car))
        let k2 = try XCTUnwrap(key(.walk))
        var slot = RouteLineSlot()
        slot.begin(k1)
        XCTAssertTrue(slot.accept(first, for: k1))
        XCTAssertEqual(slot.points, first)
        slot.begin(k2)
        XCTAssertEqual(slot.points, [])
        XCTAssertEqual(slot.key, k2)
    }
}
