import XCTest
import Combine
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
@testable import besir

// MARK: - Fakes (shared with the M4 session tests of the same card)

/// Camera access: whether a camera exists, what the status is, and what one permission request answers (or holds).
@MainActor
final class SnapAccessFake: SnapCameraAccess {
    var hasCamera = true
    var status: SnapAccess = .authorized
    var answer = true
    var holdRequest = false
    private(set) var requests = 0
    private var held: CheckedContinuation<Bool, Never>?

    func request() async -> Bool {
        requests += 1
        if holdRequest { return await withCheckedContinuation { held = $0 } }
        return answer
    }

    func releaseRequest(_ granted: Bool) {
        held?.resume(returning: granted)
        held = nil
    }
}

/// A shutter that counts starts, stops and captures. The first capture can be held until the test releases it.
@MainActor
final class SnapShutterFake: SnapShutter {
    var frame: Data? = SnapTestImages.small
    var holdFirst = false
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var captures = 0
    private var held: CheckedContinuation<Data?, Never>?

    func start() { starts += 1 }
    func stop() { stops += 1 }

    func capture() async -> Data? {
        captures += 1
        if holdFirst, captures == 1 { return await withCheckedContinuation { held = $0 } }
        return frame
    }

    func releaseCapture(_ data: Data?) {
        held?.resume(returning: data)
        held = nil
    }
}

/// A reader that answers from a script (an answer, or a hold that the test releases) and remembers every image it was given.
final class SnapReaderFake: SnapReading, @unchecked Sendable {
    enum Step {
        case answer(Result<SnapClue, VisionFailure>)
        case hold
    }

    var isConfigured = true
    var script: [Step] = []
    var fallback: Result<SnapClue, VisionFailure> = .failure(.other)
    private let lock = NSLock()
    private var received: [(base64: String, mime: String)] = []
    private var held: CheckedContinuation<Result<SnapClue, VisionFailure>, Never>?

    var calls: Int { lock.withLock { received.count } }
    var images: [(base64: String, mime: String)] { lock.withLock { received } }

    func read(imageBase64: String, mime: String) async -> Result<SnapClue, VisionFailure> {
        let step: Step = lock.withLock {
            received.append((imageBase64, mime))
            return script.isEmpty ? .answer(fallback) : script.removeFirst()
        }
        switch step {
        case .answer(let result): return result
        case .hold: return await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
        }
    }

    func release(_ result: Result<SnapClue, VisionFailure>) {
        let continuation: CheckedContinuation<Result<SnapClue, VisionFailure>, Never>? = lock.withLock {
            let current = held
            held = nil
            return current
        }
        continuation?.resume(returning: result)
    }
}

/// The transport under a real `PlaceSearch`: answers from a script (the last step repeats), or holds until released.
final class SnapPlacesTransport: @unchecked Sendable {
    enum Step {
        case answer(Data)
        case status(Int)
        case hold
    }

    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private var script: [Step]
    private var held: CheckedContinuation<Data, Never>?

    init(_ script: [Step] = []) { self.script = script }

    var requests: [URLRequest] { lock.withLock { seen } }
    var callCount: Int { requests.count }

    var transport: GooglePlaces.Transport {
        { [self] request in
            let step: Step = lock.withLock {
                seen.append(request)
                if script.isEmpty { return .answer(Data("{}".utf8)) }
                return script.count > 1 ? script.removeFirst() : script[0]
            }
            switch step {
            case .answer(let data):
                return (data, PlacesTransportStub.httpResponse(status: 200, for: request))
            case .status(let code):
                return (Data(), PlacesTransportStub.httpResponse(status: code, for: request))
            case .hold:
                let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                    lock.withLock { held = continuation }
                }
                return (data, PlacesTransportStub.httpResponse(status: 200, for: request))
            }
        }
    }

    func release(with data: Data) {
        let continuation: CheckedContinuation<Data, Never>? = lock.withLock {
            let current = held
            held = nil
            return current
        }
        continuation?.resume(returning: data)
    }
}

/// A calendar mirror that counts its day reads and can hold the first one.
@MainActor
final class SnapMirrorFake: CalendarMirroring {
    var canned: [CalendarEntry] = []
    var failure: CalendarReadError?
    var hold = false
    private(set) var reads = 0
    private var held: CheckedContinuation<Void, Never>?

    func reconcile(_ activities: [ActivityBlock]) {}

    func entries(on day: Date, calendar: Calendar) async throws -> [CalendarEntry] {
        reads += 1
        if hold { await withCheckedContinuation { held = $0 } }
        if let failure { throw failure }
        return canned
    }

    func releaseRead() {
        held?.resume()
        held = nil
    }
}

enum SnapTestImages {
    /// A small valid JPEG.
    static var small: Data { ShareTestImages.poster(width: 64, height: 48) }

    /// A JPEG of the given size that carries a GPS dictionary and a TIFF `Make`.
    static func withMetadata(width: Int, height: Int) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(ShareTestImages.poster(width: width, height: height) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestMake", kCGImagePropertyTIFFModel: "TestModel"]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func properties(of data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }
}

/// One flow with every seam faked: camera, shutter, reader, a real `PlaceSearch` over a scripted transport, a real
/// `ConnectionLog` that writes nothing to disk, the calendar and the session closures.
@MainActor
final class SnapRig {
    let access = SnapAccessFake()
    let shutter = SnapShutterFake()
    let reader = SnapReaderFake()
    let mirror = SnapMirrorFake()
    let places: SnapPlacesTransport
    let log = ConnectionLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("snap-rig-\(UUID().uuidString).json"),
                            write: { _, _ in })
    let flow = SnapFlow()
    var fix: CLLocationCoordinate2D? = PlacesTestSupport.center
    var now = TestClock.date("2026-10-27T12:03")
    var handle: String? = "p1"
    var activities: [ActivityBlock] = []
    private(set) var registered: [Place] = []
    private(set) var prepared = 0

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TestClock.zone
        return calendar
    }

    /// `camera` false makes the flow take the photo picker path (no camera on the device).
    init(camera: Bool = false, places: [SnapPlacesTransport.Step] = []) {
        access.hasCamera = camera
        self.places = SnapPlacesTransport(places)
    }

    var deps: SnapFlow.Deps {
        SnapFlow.Deps(reader: reader,
                      placeSearch: PlaceSearch(config: PlacesTestSupport.config, transport: places.transport, connections: log),
                      realFix: { [unowned self] in self.fix },
                      activities: { [unowned self] in self.activities },
                      mirror: mirror,
                      prepare: { [unowned self] events in self.prepared += 1; return events },
                      register: { [unowned self] place in self.registered.append(place); return self.handle },
                      access: access, shutter: shutter,
                      now: { [unowned self] in self.now }, calendar: calendar, connections: log)
    }

    /// The screen opens: the flow gets its seams and begins.
    func open() async {
        flow.start(deps)
        await flow.begin()
    }

    func answer(_ items: [(name: String, meters: Double)]) -> SnapPlacesTransport.Step {
        .answer(PlacesTestSupport.nearbyAnswer(items))
    }

    var rows: [SnapCandidate] {
        if case .choosing(let rows) = flow.phase { return rows }
        return []
    }
}

private func clue(_ kind: SnapKind = .foodPlace, name: String? = "Foo Kitchen", type: String? = nil, text: String? = nil,
                  title: String? = nil, time: String? = nil, confidence: Double = 0.9) -> SnapClue {
    SnapClue(kind: kind, name: name, placeType: type, text: text, title: title, time: time, confidence: confidence)
}

private let posterClue = SnapClue(kind: .eventPoster, name: "Marina Green", placeType: nil, text: nil, title: "Harbor Lights Concert",
                                  time: "Fri Oct 30, 7:30 PM", confidence: 0.9)

/// SPEC-CAMSNAP-001 AC-CAMSNAP-006, 007, 008 and 015: the flow from a frame to a decision, with every seam faked.
@MainActor
final class SnapFlowTests: XCTestCase {
    /// Waits (at most about three seconds) until a held step of a test has arrived.
    @discardableResult
    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    // MARK: AC-CAMSNAP-006

    func testCAMSNAP_T27_captureSourceAndPermissionMatrix() async {
        struct Row {
            let camera: Bool
            let status: SnapAccess
            let granted: Bool
            let phase: SnapPhase
            let requests: Int
            let starts: Int
        }
        let rows = [
            Row(camera: true, status: .authorized, granted: true, phase: .ready(.camera), requests: 0, starts: 1),
            Row(camera: true, status: .notDetermined, granted: true, phase: .ready(.camera), requests: 1, starts: 1),
            Row(camera: true, status: .notDetermined, granted: false, phase: .line(SnapLine.cameraOff), requests: 1, starts: 0),
            Row(camera: true, status: .denied, granted: true, phase: .line(SnapLine.cameraOff), requests: 0, starts: 0),
            Row(camera: false, status: .authorized, granted: true, phase: .ready(.picker), requests: 0, starts: 0),
            Row(camera: false, status: .notDetermined, granted: true, phase: .ready(.picker), requests: 0, starts: 0)
        ]
        for (index, row) in rows.enumerated() {
            let rig = SnapRig(camera: row.camera)
            rig.access.status = row.status
            rig.access.answer = row.granted
            await rig.open()
            XCTAssertEqual(rig.flow.phase, row.phase, "row \(index)")
            XCTAssertEqual(rig.access.requests, row.requests, "row \(index) permission requests")
            XCTAssertEqual(rig.shutter.starts, row.starts, "row \(index) session starts")
            XCTAssertEqual(rig.shutter.captures, 0, "row \(index) captures")
        }
    }

    func testCAMSNAP_T28_shutterLifecycle() async {
        // One tap: the capture runs once, the session stops once, the frame is read, the session never starts again.
        do {
            let rig = SnapRig(camera: true)
            await rig.open()
            XCTAssertEqual(rig.shutter.starts, 1)
            await rig.flow.shutterTapped()
            XCTAssertEqual(rig.shutter.captures, 1)
            XCTAssertEqual(rig.shutter.stops, 1)
            XCTAssertEqual(rig.shutter.starts, 1)
            XCTAssertEqual(rig.reader.calls, 1)
            XCTAssertEqual(rig.flow.phase, .line(SnapLine.other))
            await rig.flow.shutterTapped()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.shutter.captures, 1)
            XCTAssertEqual(rig.reader.calls, 1)
            rig.flow.close()
            XCTAssertEqual(rig.shutter.stops, 1, "the session already stopped, so closing stops nothing more")
        }
        // A second tap while the capture is held is ignored: capture runs once (the capturing phase).
        do {
            let rig = SnapRig(camera: true)
            rig.shutter.holdFirst = true
            await rig.open()
            let first = Task { await rig.flow.shutterTapped() }
            let held = await until { rig.shutter.captures == 1 }
            XCTAssertTrue(held)
            XCTAssertEqual(rig.flow.phase, .capturing)
            await rig.flow.shutterTapped()
            XCTAssertEqual(rig.shutter.captures, 1)
            rig.shutter.releaseCapture(SnapTestImages.small)
            await first.value
            XCTAssertEqual(rig.shutter.captures, 1)
            XCTAssertEqual(rig.shutter.stops, 1)
            XCTAssertEqual(rig.reader.calls, 1)
        }
        // A tap or a frame while the read is running is ignored.
        do {
            let rig = SnapRig(camera: true)
            rig.reader.script = [.hold]
            await rig.open()
            let first = Task { await rig.flow.shutterTapped() }
            let reading = await until { rig.reader.calls == 1 }
            XCTAssertTrue(reading)
            XCTAssertEqual(rig.flow.phase, .reading)
            await rig.flow.shutterTapped()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.shutter.captures, 1)
            XCTAssertEqual(rig.reader.calls, 1)
            rig.reader.release(.failure(.other))
            await first.value
            XCTAssertEqual(rig.reader.calls, 1)
        }
        // Closing before any shot stops the session once and ends with no line and no outcome.
        do {
            let rig = SnapRig(camera: true)
            await rig.open()
            rig.flow.close()
            XCTAssertEqual(rig.shutter.stops, 1)
            XCTAssertEqual(rig.flow.phase, .done)
            XCTAssertNil(rig.flow.takeOutcome())
            await rig.flow.shutterTapped()
            XCTAssertEqual(rig.shutter.captures, 0)
        }
        // The picker path touches no session.
        do {
            let rig = SnapRig(camera: false)
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.reader.calls, 1)
            XCTAssertEqual(rig.shutter.starts, 0)
            XCTAssertEqual(rig.shutter.stops, 0)
            XCTAssertEqual(rig.shutter.captures, 0)
        }
    }

    func testCAMSNAP_T29_theReaderGetsAShrunkJpegWithoutLocationOrMake() async throws {
        let input = try SnapTestImages.withMetadata(width: 3000, height: 2000)
        // Control: the input really carries both, and is larger than the bound.
        let inputProperties = try XCTUnwrap(SnapTestImages.properties(of: input))
        XCTAssertNotNil(inputProperties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual((inputProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, "TestMake")
        XCTAssertEqual(inputProperties[kCGImagePropertyPixelWidth] as? Int, 3000)

        let rig = SnapRig(camera: false)
        await rig.open()
        await rig.flow.submit(frame: input)
        XCTAssertEqual(rig.reader.calls, 1)
        let image = try XCTUnwrap(rig.reader.images.first)
        XCTAssertEqual(image.mime, "image/jpeg")
        let sent = try XCTUnwrap(Data(base64Encoded: image.base64))
        XCTAssertLessThanOrEqual(sent.count, 1_048_576)
        let properties = try XCTUnwrap(SnapTestImages.properties(of: sent))
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(max(width, height), 2048)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "no GPS dictionary")
        XCTAssertNil((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake], "no camera make")

        // Data that is not an image: the photo line and no reader call.
        let other = SnapRig(camera: false)
        await other.open()
        await other.flow.submit(frame: Data("this is not an image".utf8))
        XCTAssertEqual(other.flow.phase, .line(SnapLine.unreadable))
        XCTAssertEqual(other.reader.calls, 0)
    }

    func testCAMSNAP_T30_oneReadPerTapNoRetryAndANilCaptureReadsNothing() async {
        // A failed read is not repeated; a later tap is a new call.
        do {
            let rig = SnapRig(camera: false)
            rig.reader.fallback = .failure(.offline)
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.reader.calls, 1)
            XCTAssertEqual(rig.flow.phase, .line(SnapLine.offline))
            for _ in 0..<5 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(rig.reader.calls, 1, "no automatic retry")
            rig.flow.close()
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.reader.calls, 2, "a new tap is a new call")
        }
        // Two frames while the first is being read: the reader is called once.
        do {
            let rig = SnapRig(camera: false)
            rig.reader.script = [.hold]
            await rig.open()
            let first = Task { await rig.flow.submit(frame: SnapTestImages.small) }
            let reading = await until { rig.reader.calls == 1 }
            XCTAssertTrue(reading)
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.reader.calls, 1)
            rig.reader.release(.failure(.other))
            await first.value
            XCTAssertEqual(rig.reader.calls, 1)
        }
        // A capture that returns nothing stops the session once, shows the photo line and reads nothing.
        do {
            let rig = SnapRig(camera: true)
            rig.shutter.frame = nil
            await rig.open()
            await rig.flow.shutterTapped()
            XCTAssertEqual(rig.shutter.captures, 1)
            XCTAssertEqual(rig.shutter.stops, 1)
            XCTAssertEqual(rig.flow.phase, .line(SnapLine.unreadable))
            XCTAssertEqual(rig.reader.calls, 0)
        }
        // A finished outcome survives close() before takeOutcome() (debt D33), and is taken once.
        do {
            let rig = SnapRig(camera: false)
            rig.reader.fallback = .success(posterClue)
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.flow.phase, .done)
            rig.flow.close()
            guard case .message(let text, let shown, _)? = rig.flow.takeOutcome() else {
                return XCTFail("the outcome was lost by close()")
            }
            XCTAssertEqual(text, SnapMessage.poster(clue: posterClue))
            XCTAssertEqual(shown, SnapMessage.shownPoster)
            XCTAssertNil(rig.flow.takeOutcome())
        }
    }

    func testCAMSNAP_T31_theFrameIsHeldInMemoryOnlyAndNothingIsWrittenToDisk() async throws {
        let marker = "SNAP-MARKER-5521"
        let directories = [FileManager.default.temporaryDirectory,
                           FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first].compactMap { $0 }

        func subpaths(_ directory: URL) -> [String] {
            (try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []
        }
        func listing() -> Set<String> {
            var paths = Set<String>()
            for directory in directories {
                for path in subpaths(directory) { paths.insert(directory.lastPathComponent + "/" + path) }
            }
            return paths
        }
        func filesHolding(_ marker: String) -> [String] {
            var found: [String] = []
            for directory in directories {
                for path in subpaths(directory) {
                    let url = directory.appendingPathComponent(path)
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 8_000_000 else { continue }
                    if data.range(of: Data(marker.utf8)) != nil { found.append(path) }
                }
            }
            return found
        }
        /// How many `Data` values and strings over 1000 characters the object holds, looking inside its own properties
        /// (the injected seams are skipped: a fake reader keeps what it received on purpose).
        func holdings(_ value: Any, depth: Int = 0) -> (data: Int, longStrings: Int) {
            if value is Data { return (1, 0) }
            if let text = value as? String { return (0, text.count > 1000 ? 1 : 0) }
            guard depth < 5 else { return (0, 0) }
            var total = (data: 0, longStrings: 0)
            for child in Mirror(reflecting: value).children where child.label != "deps" {
                let inner = holdings(child.value, depth: depth + 1)
                total = (total.data + inner.data, total.longStrings + inner.longStrings)
            }
            return total
        }

        // Controls: the scanners find planted values.
        struct Planted { let blob = Data("x".utf8); let text = String(repeating: "y", count: 1001); let label = "short" }
        let planted = holdings(Planted())
        XCTAssertEqual(planted.data, 1)
        XCTAssertEqual(planted.longStrings, 1)
        let plantedFile = FileManager.default.temporaryDirectory.appendingPathComponent("snap-t31-\(UUID().uuidString).bin")
        try Data(marker.utf8).write(to: plantedFile)
        XCTAssertFalse(filesHolding(marker).isEmpty, "the scanner must find a planted marker")
        try FileManager.default.removeItem(at: plantedFile)

        var input = SnapTestImages.small
        input.append(Data(String(repeating: marker, count: 20).utf8))
        XCTAssertNotNil(ImageShrink.jpeg(from: input), "the input with its trailing marker is still a readable image")

        let before = listing()
        XCTAssertTrue(filesHolding(marker).isEmpty)
        for (reading, expected) in [(Result<SnapClue, VisionFailure>.success(posterClue), SnapPhase.done),
                                    (.failure(.offline), .line(SnapLine.offline))] {
            let rig = SnapRig(camera: false)
            rig.reader.fallback = reading
            await rig.open()
            await rig.flow.submit(frame: input)
            XCTAssertEqual(rig.flow.phase, expected)
            XCTAssertEqual(rig.reader.calls, 1)
            let held = holdings(rig.flow)
            XCTAssertEqual(held.data, 0, "the flow keeps no Data")
            XCTAssertEqual(held.longStrings, 0, "the flow keeps no long string")
        }
        XCTAssertTrue(filesHolding(marker).isEmpty, "the marker is in no file of the temp or caches directories")
        XCTAssertEqual(listing().subtracting(before), [], "no file appeared in the temp or caches directories")
    }

    // MARK: AC-CAMSNAP-007

    func testCAMSNAP_T32_noRealFixMakesNoLookupAndAPosterIsNotBlocked() async {
        // A place kind with a query and no fix: the location line, one reader call, no lookup.
        do {
            let rig = SnapRig()
            rig.fix = nil
            rig.reader.fallback = .success(clue(.foodPlace, name: "Chowder Hut"))
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.flow.phase, .line(SnapLine.noLocation))
            XCTAssertEqual(rig.reader.calls, 1)
            XCTAssertEqual(rig.places.callCount, 0)
        }
        // A poster does not need a position.
        do {
            let rig = SnapRig()
            rig.fix = nil
            rig.reader.fallback = .success(posterClue)
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.places.callCount, 0)
            guard case .message(_, let shown, _)? = rig.flow.takeOutcome() else { return XCTFail("a poster needs no fix") }
            XCTAssertEqual(shown, SnapMessage.shownPoster)
        }
        // A fix gives exactly one lookup.
        do {
            let rig = SnapRig(places: [.answer(PlacesTestSupport.nearbyAnswer([("Chowder Hut", 100)]))])
            rig.reader.fallback = .success(clue(.foodPlace, name: "Chowder Hut"))
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.places.callCount, 1)
        }
    }

    func testCAMSNAP_T33_theLookupIsOneNearbyTextSearchAroundTheFix() async throws {
        let rig = SnapRig(places: [.answer(PlacesTestSupport.nearbyAnswer([("Foo Kitchen", 120)]))])
        rig.reader.fallback = .success(clue(.otherPlace, name: "Foo Kitchen"))
        await rig.open()
        await rig.flow.submit(frame: SnapTestImages.small)
        XCTAssertEqual(rig.places.callCount, 1)
        let request = try XCTUnwrap(rig.places.requests.first)
        XCTAssertEqual(request.url?.path, "/places")
        let body = try XCTUnwrap(PlacesTestSupport.body(of: request))
        XCTAssertEqual(body["textQuery"] as? String, "Foo Kitchen")
        let circle = try XCTUnwrap(PlacesTestSupport.circle(of: body))
        XCTAssertEqual(circle.latitude, 37.7749, accuracy: 1e-9)
        XCTAssertEqual(circle.longitude, -122.4194, accuracy: 1e-9)
        XCTAssertEqual(circle.radius, 500, accuracy: 1e-9)
        XCTAssertEqual((body["pageSize"] as? NSNumber)?.intValue, 20)
        XCTAssertNil(body["includedType"], "a free-text search with no place type")
        XCTAssertEqual(request.value(forHTTPHeaderField: GooglePlaces.fieldMaskHeader), GooglePlaces.fieldMask)
        // The one place that came back is the one the flow went on with.
        XCTAssertEqual(rig.registered.map(\.name), ["Foo Kitchen"])
        XCTAssertEqual(rig.registered.first?.address, "Foo Kitchen address")
        // Only that request carries the position: the image sent to the reader does not.
        let image = try XCTUnwrap(rig.reader.images.first)
        XCTAssertFalse(image.base64.contains("37.7749"))
    }

    // MARK: AC-CAMSNAP-008

    func testCAMSNAP_T34_outcomesByResultCount() async {
        func run(_ step: SnapPlacesTransport.Step) async -> (SnapRig, [SnapPhase]) {
            let rig = SnapRig(places: [step])
            rig.reader.fallback = .success(clue(.foodPlace, name: "Foo Kitchen"))
            var seen: [SnapPhase] = []
            let watch = rig.flow.$phase.sink { seen.append($0) }
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            watch.cancel()
            return (rig, seen)
        }
        func answer(_ items: [(name: String, meters: Double)]) -> SnapPlacesTransport.Step {
            .answer(PlacesTestSupport.nearbyAnswer(items))
        }
        func summary(_ rows: [SnapCandidate]) -> [String] { rows.map { "\($0.name) \($0.distanceText ?? "-")" } }

        // (a) no places
        var (rig, _) = await run(answer([]))
        XCTAssertEqual(rig.flow.phase, .line(SnapLine.noMatch))
        // (b) one place: the flow goes on without a list
        var seen: [SnapPhase]
        (rig, seen) = await run(answer([("A", 100)]))
        XCTAssertEqual(rig.flow.phase, .awaitingMode)
        XCTAssertFalse(seen.contains { if case .choosing = $0 { return true } else { return false } }, "never a list for one place")
        // (c) two places
        (rig, _) = await run(answer([("A", 100), ("B", 180)]))
        XCTAssertEqual(summary(rig.rows), ["A 100m", "B 180m"])
        // (d) three places, nearest first
        (rig, _) = await run(answer([("B", 180), ("C", 90), ("A", 120)]))
        XCTAssertEqual(summary(rig.rows), ["C 90m", "A 120m", "B 180m"])
        // (e) five answered: the one beyond 500 m is dropped and the list holds three
        (rig, _) = await run(answer([("Far", 650), ("B", 180),("C", 90), ("D", 240), ("A", 120)]))
        XCTAssertEqual(summary(rig.rows), ["C 90m", "A 120m", "B 180m"])
        // (f) a failed transport
        (rig, _) = await run(.status(500))
        XCTAssertEqual(rig.flow.phase, .line(SnapLine.noMatch))
        // (g) one place inside the radius and one beyond it: the far one is dropped, so there is no list
        (rig, _) = await run(answer([("Far", 650), ("A", 120)]))
        XCTAssertEqual(rig.flow.phase, .awaitingMode)
    }

    func testCAMDEVICE_T05_theRadiusBoundaryIs500Metres() async {
        // A place 480 m away is inside the radius: the flow goes on with it and registers it.
        let inside = SnapRig(places: [.answer(PlacesTestSupport.nearbyAnswer([("Inside", 480)]))])
        inside.reader.fallback = .success(clue(.otherPlace, name: "Inside"))
        await inside.open()
        await inside.flow.submit(frame: SnapTestImages.small)
        XCTAssertEqual(inside.registered.map(\.name), ["Inside"])
        // A place 520 m away is beyond it: nothing is registered and the flow ends with the no-match line.
        let outside = SnapRig(places: [.answer(PlacesTestSupport.nearbyAnswer([("Outside", 520)]))])
        outside.reader.fallback = .success(clue(.otherPlace, name: "Outside"))
        await outside.open()
        await outside.flow.submit(frame: SnapTestImages.small)
        XCTAssertEqual(outside.flow.phase, .line(SnapLine.noMatch))
        XCTAssertEqual(outside.registered.map(\.name), [])
    }

    func testCAMSNAP_T35_candidateRowsAreCutCleanAndCarryTheGoogleMark() async throws {
        let long = String(repeating: "N", count: 130)
        let rig = SnapRig(places: [.answer(PlacesTestSupport.nearbyAnswer([(long, 90), ("Blue\u{07} Bottle", 100)]))])
        rig.reader.fallback = .success(clue(.otherPlace, name: "Foo Kitchen"))
        await rig.open()
        await rig.flow.submit(frame: SnapTestImages.small)
        XCTAssertEqual(rig.rows.count, 2)
        XCTAssertTrue(rig.flow.showsGoogleMark, "the Google mark goes under the list")
        let first = try XCTUnwrap(rig.rows.first)
        XCTAssertEqual(first.name, String(repeating: "N", count: 80))
        XCTAssertEqual(first.address, String(repeating: "N", count: 120))
        XCTAssertEqual(first.distanceText, "90m")
        let second = try XCTUnwrap(rig.rows.last)
        XCTAssertEqual(second.name, "Blue Bottle")
        XCTAssertEqual(second.distanceText, "100m")
        for row in rig.rows {
            for text in [row.name, row.address, row.distanceText ?? ""] {
                XCTAssertFalse(text.contains("37.77"), "no coordinate in a row")
                XCTAssertFalse(text.contains("maps.example.invalid"), "no link in a row")
            }
        }
        // One choice yields that place and leaves no list.
        await rig.flow.choose(second)
        XCTAssertEqual(rig.registered.count, 1)
        XCTAssertEqual(rig.registered.first?.name, "Blue\u{07} Bottle")
        XCTAssertEqual(rig.flow.phase, .done)
        XCTAssertTrue(rig.rows.isEmpty)
        XCTAssertFalse(rig.flow.showsGoogleMark)
        XCTAssertNotNil(rig.flow.takeOutcome())
    }

    // MARK: AC-CAMSNAP-015

    func testCAMSNAP_T36_connectionPacketsOfAFullTap() async {
        let titleSentinel = "SENTINEL-TITLE-1"
        let timeSentinel = "SENTINEL-TIME-2"
        let textSentinel = "SENTINEL-TEXT-3"
        let food = SnapClue(kind: .foodPlace, name: "Chowder Hut", placeType: "seafood restaurant", text: textSentinel,
                            title: titleSentinel, time: timeSentinel, confidence: 0.9)
        func assertClean(_ packets: [ConnectionPacket], _ note: String) {
            for packet in packets {
                for word in [titleSentinel, timeSentinel, textSentinel, "37.77", "122.41", "SENTINEL"] {
                    XCTAssertFalse(packet.summary.contains(word), "\(note): \(packet.summary)")
                }
            }
        }

        // A success with a lookup.
        do {
            let rig = SnapRig(places: [.answer(PlacesTestSupport.nearbyAnswer([("Chowder Hut", 100)]))])
            rig.reader.fallback = .success(food)
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            await rig.log.flush()
            let packets = rig.log.packets
            XCTAssertEqual(packets.count, 2)
            let read = packets.filter { $0.kind == .imageRead }
            XCTAssertEqual(read.map(\.summary), ["Image read"])
            XCTAssertEqual(read.first?.from, .besir)
            XCTAssertEqual(read.first?.to, .imageReader)
            XCTAssertEqual(read.first?.status, .ok)
            let readFlow = read.first?.flowID
            XCTAssertNotNil(readFlow)
            let search = packets.filter { $0.kind == .placeSearch }
            XCTAssertEqual(search.map(\.summary), ["Nearby Chowder Hut · 1 result"])
            XCTAssertEqual(search.first?.from, .besir)
            XCTAssertEqual(search.first?.to, .googlePlaces)
            XCTAssertNil(search.first?.flowID, "the baseline place packet joins no flow")
            XCTAssertFalse(search.first?.summary.contains(readFlow?.uuidString ?? "?") ?? true)
            assertClean(packets, "success with lookup")
        }
        // A poster: the outcome carries the flow of the image-read packet.
        do {
            let rig = SnapRig()
            rig.reader.fallback = .success(posterClue)
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            await rig.log.flush()
            XCTAssertEqual(rig.log.packets.map(\.summary), ["Image read"])
            guard case .message(_, _, let flow)? = rig.flow.takeOutcome() else { return XCTFail("a poster gives a message outcome") }
            XCTAssertEqual(rig.log.packets.first?.flowID, flow)
        }
        // A failed read.
        do {
            let rig = SnapRig()
            rig.reader.fallback = .failure(.offline)
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            await rig.log.flush()
            XCTAssertEqual(rig.log.packets.map(\.summary), ["Image read failed"])
            XCTAssertEqual(rig.log.packets.first?.status, .failed)
            XCTAssertEqual(rig.log.packets.first?.from, .besir)
            XCTAssertEqual(rig.log.packets.first?.to, .imageReader)
        }
        // Not set up, an unreadable frame and a cancelled read write nothing.
        do {
            let rig = SnapRig()
            rig.reader.isConfigured = false
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.flow.phase, .line(SharedLine.notSetUp))
            await rig.log.flush()
            XCTAssertTrue(rig.log.packets.isEmpty, "not set up")
        }
        do {
            let rig = SnapRig()
            await rig.open()
            await rig.flow.submit(frame: Data("not an image".utf8))
            await rig.log.flush()
            XCTAssertTrue(rig.log.packets.isEmpty, "unreadable")
        }
        do {
            let rig = SnapRig()
            rig.reader.script = [.hold]
            await rig.open()
            let tap = Task { await rig.flow.submit(frame: SnapTestImages.small) }
            let reading = await until { rig.reader.calls == 1 }
            XCTAssertTrue(reading)
            rig.flow.close()
            rig.reader.release(.success(food))
            await tap.value
            await rig.log.flush()
            XCTAssertTrue(rig.log.packets.isEmpty, "cancelled read")
        }
        // No name: the term is the place type plus the short text, and nothing else of the reading.
        do {
            let rig = SnapRig(places: [.answer(PlacesTestSupport.nearbyAnswer([("Main Library", 100)]))])
            rig.reader.fallback = .success(SnapClue(kind: .otherPlace, name: nil, placeType: "library", text: "Main",
                                                    title: titleSentinel, time: timeSentinel, confidence: 0.9))
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            await rig.log.flush()
            XCTAssertEqual(rig.log.packets.filter { $0.kind == .placeSearch }.map(\.summary), ["Nearby library Main · 1 result"])
            assertClean(rig.log.packets, "term from the type")
        }
        // A lookup whose transport fails writes the baseline failure packet.
        do {
            let rig = SnapRig(places: [.status(500)])
            rig.reader.fallback = .success(food)
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            await rig.log.flush()
            let search = rig.log.packets.filter { $0.kind == .placeSearch }
            XCTAssertEqual(search.map(\.summary), ["Search failed"])
            XCTAssertEqual(search.first?.status, .failed)
            assertClean(rig.log.packets, "failed lookup")
        }
    }

    // MARK: AC-CAMSNAP-012 - the mode dialog and the day context

    /// A place to eat has been found and the flow waits for the travel mode.
    private func foodRig() async -> SnapRig {
        let rig = SnapRig(places: [.answer(PlacesTestSupport.nearbyAnswer([("Foo Kitchen", 120)]))])
        rig.reader.fallback = .success(clue(.foodPlace, name: "Foo Kitchen"))
        await rig.open()
        await rig.flow.submit(frame: SnapTestImages.small)
        return rig
    }

    func testCAMSNAP_T37_theModeDialogEndsWithNothingOrAPlanOutcome() async throws {
        // While the dialog is open: no outcome, no preparation, no registration, no calendar read.
        let waiting = await foodRig()
        XCTAssertEqual(waiting.flow.phase, .awaitingMode)
        XCTAssertNil(waiting.flow.takeOutcome(), "no outcome before a mode is chosen")
        XCTAssertEqual(waiting.prepared, 0)
        XCTAssertTrue(waiting.registered.isEmpty)
        XCTAssertEqual(waiting.mirror.reads, 0)

        // Cancel, or the dialog dismissed: the flow ends with nothing.
        await waiting.flow.chooseMode(nil)
        XCTAssertEqual(waiting.flow.phase, .done)
        XCTAssertNil(waiting.flow.takeOutcome(), "Cancel builds no outcome")
        XCTAssertEqual(waiting.prepared, 0)
        XCTAssertTrue(waiting.registered.isEmpty, "Cancel registers no place")
        XCTAssertEqual(waiting.mirror.reads, 0)
        await waiting.flow.chooseMode(.walk)
        XCTAssertNil(waiting.flow.takeOutcome(), "a mode after the end builds nothing")

        // Each mode gives one plan outcome with that mode.
        for mode in PlanMyDay.modeChoices {
            let rig = await foodRig()
            await rig.flow.chooseMode(mode)
            guard case .plan(let text, let shown, let context, _)? = rig.flow.takeOutcome() else {
                XCTFail("\(mode): a plan outcome")
                continue
            }
            XCTAssertEqual(context.mode, mode)
            XCTAssertTrue(text.contains("I will travel by \(mode.rawValue). Do not ask me how I travel."), "\(mode)")
            XCTAssertEqual(shown, SnapMessage.shownMeal)
            XCTAssertEqual(rig.registered.map(\.name), ["Foo Kitchen"])
            XCTAssertEqual(rig.prepared, 1)
            XCTAssertNil(rig.flow.takeOutcome(), "\(mode): one tap, one outcome")
        }

        // The dialog offers the four modes of Plan my day, under the fixed title.
        XCTAssertEqual(PlanMyDay.modeChoices.map(\.rawValue), ["car", "transit", "walk", "bicycle"])
        XCTAssertEqual(SnapLine.travelTitle, "How will you travel?")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Shared/SnapView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("ForEach(PlanMyDay.modeChoices)"), "the buttons are the choices of Plan my day")
        XCTAssertTrue(view.contains("confirmationDialog(SnapLine.travelTitle"))
    }

    /// Hands out handles the way an agent session does, so a flow test sees real place handles.
    private final class RegistryBox {
        var registry = AgentPlaceRegistry()
    }

    func testCAMSNAP_T38_theDayContextIsWhatPlanMyDayBuildsFromTheSameInputs() async throws {
        let harbor = Place(name: "Harbor Office", address: "1 Harbor St, San Francisco, CA 94111, USA", latitude: 37.79, longitude: -122.39)
        let teamSync = ActivityBlock(title: "Team sync", location: harbor, startDate: TestClock.date("2026-10-27T13:00"),
                                     endDate: TestClock.date("2026-10-27T14:00"))
        func entry(_ id: String, _ title: String, _ start: String, _ end: String, allDay: Bool = false, location: String? = nil,
                   besir: Bool = false) -> CalendarEntry {
            CalendarEntry(id: id, title: title, start: TestClock.date(start), end: TestClock.date(end), isAllDay: allDay,
                          location: location, calendarName: "Home", isFromBesir: besir)
        }
        let entries = [
            entry("c1", "Dentist", "2026-10-27T15:00", "2026-10-27T16:00", location: "Dental Care, 5 Oak St"),
            entry("c2", "Written by besir", "2026-10-27T14:30", "2026-10-27T15:00", besir: true),
            entry("c3", "Holiday", "2026-10-27T00:00", "2026-10-28T00:00", allDay: true),
            entry("c4", "Standup", "2026-10-27T11:00", "2026-10-27T11:30")
        ]
        func run(_ failure: CalendarReadError?) async throws -> (rig: SnapRig, text: String, shown: String, context: DayPlanContext) {
            let rig = SnapRig(places: [.answer(PlacesTestSupport.nearbyAnswer([("Foo Kitchen", 120)]))])
            rig.reader.fallback = .success(clue(.foodPlace, name: "Foo Kitchen"))
            rig.mirror.canned = entries
            rig.mirror.failure = failure
            rig.activities = [teamSync]
            let box = RegistryBox()
            var deps = rig.deps
            deps.prepare = { PlanMyDay.registerStorePlaces($0, registry: &box.registry) }
            deps.register = { box.registry.register([$0])?.first }
            rig.flow.start(deps)
            await rig.flow.begin()
            await rig.flow.submit(frame: SnapTestImages.small)
            await rig.flow.chooseMode(.walk)
            guard case .plan(let text, let shown, let context, _)? = rig.flow.takeOutcome() else {
                XCTFail("no plan outcome")
                throw CancellationError()
            }
            return (rig, text, shown, context)
        }

        // The calendar is readable: the Store event, the calendar entry that is neither besir's, all-day nor over.
        let result = try await run(nil)
        let expected = [
            PlanMyDay.Event(handle: "e1", title: "Team sync", start: TestClock.date("2026-10-27T13:00"),
                            end: TestClock.date("2026-10-27T14:00"), locationText: "Harbor Office", place: harbor, placeHandle: "p1",
                            source: .besir),
            PlanMyDay.Event(handle: "e2", title: "Dentist", start: TestClock.date("2026-10-27T15:00"),
                            end: TestClock.date("2026-10-27T16:00"), locationText: "Dental Care, 5 Oak St", place: nil, placeHandle: nil,
                            source: .calendar)
        ]
        XCTAssertEqual(result.context.events, expected)
        XCTAssertEqual(result.context.checkWindowEnd, TestClock.date("2026-10-28T00:00"))
        XCTAssertEqual(result.context.mode, .walk)
        XCTAssertEqual(result.shown, "I snapped a place to eat.")
        // The same function, the same inputs: the context holds what Plan my day builds, with the handles of the registry.
        let plain = PlanMyDay.events(activities: [teamSync], entries: entries, now: TestClock.date("2026-10-27T12:03"), calendar: result.rig.calendar)
        XCTAssertEqual(plain.events.map(\.handle), ["e1", "e2"])
        XCTAssertEqual(plain.events.map(\.title), result.context.events.map(\.title))
        XCTAssertEqual(plain.events.map(\.start), result.context.events.map(\.start))
        // The message carries the same events (and the place after them), and the chosen place got the handle after the Store place.
        let line = try XCTUnwrap(result.text.components(separatedBy: "\n").first { $0.hasPrefix("Today's events, as data: ") })
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst("Today's events, as data: ".count).utf8)) as? [[String: Any]])
        XCTAssertEqual(sent.map { $0["id"] as? String }, ["e1", "e2"])
        XCTAssertEqual(sent.first?["place_id"] as? String, "p1")
        XCTAssertTrue(result.text.contains("\"place_id\":\"p2\""), "the chosen place is registered after the Store place")

        // The calendar cannot be read: only the Store event, and the chat line says so.
        let fallback = try await run(.accessDenied)
        XCTAssertEqual(fallback.context.events.map(\.handle), ["e1"])
        XCTAssertEqual(fallback.context.events.map(\.title), ["Team sync"])
        XCTAssertEqual(fallback.shown, "I snapped a place to eat. Calendar not available.")
    }

    // MARK: AC-CAMSNAP-006 and 015 - the source scan

    private func scan(_ text: String, for needles: [String]) -> [String] {
        needles.filter { text.contains($0) }
    }

    func testCAMSNAP_T47_sourceScanOfTheSnapFiles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let forbidden = ["AVCaptureVideoDataOutput", "AVCaptureMovieFileOutput", "AVAssetWriter", "AVCaptureAudio",
                         "UIImageWriteToSavedPhotosAlbum", "PHPhotoLibrary", "VNDetect", "CIDetector", "FileManager",
                         "write(to", "createFile", "URLSession.shared", "BESIR_DEBUG"]
        // Each file: the type that proves the real file was read, then the strings it must hold.
        let files: [(name: String, identity: String, required: [String])] = [
            ("SnapClient", "final class SnapClient", ["URLSession(configuration: .ephemeral)"]),
            ("SnapFlow", "final class SnapFlow", ["generation"]),
            ("SnapCapture", "final class SnapCamera", ["AVCapturePhotoOutput"]),
            ("SnapView", "struct SnapView",
             ["preferredColorScheme(.dark)", "GoogleMapsAttribution()", "confirmationDialog", "photosPicker", "loadTransferable(type: Data.self)"])
        ]
        for file in files {
            let url = root.appendingPathComponent("Shared/\(file.name).swift")
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains(file.identity), "Shared/\(file.name).swift is the real file")
            XCTAssertEqual(file.required.filter { !text.contains($0) }, [], "required strings missing from \(file.name)")
            XCTAssertEqual(scan(text, for: forbidden), [], "forbidden strings in \(file.name)")
            if file.name == "SnapView" {
                XCTAssertEqual(text.components(separatedBy: "GoogleMapsAttribution()").count - 1, 1, "the Google mark appears once")
            }
        }
        // Planted-string check: the scanner finds every forbidden string it is given and nothing in clean text.
        for word in forbidden {
            XCTAssertEqual(scan("let x = \(word)()", for: forbidden), [word], "the scan must find a planted \(word)")
        }
        XCTAssertEqual(scan("let output = AVCapturePhotoOutput()", for: forbidden), [])
    }

    // MARK: SPEC-CAMDEVICE-001 - the capture guard

    /// The source lines with every `/* */` span and everything from `//` to the end of the line removed. The result keeps
    /// one entry per source line, so a line that held only a comment is empty.
    private func codeLines(of text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var inBlock = false
        var inLine = false
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if char == "\n" {
                lines.append(current)
                current = ""
                inLine = false
                index += 1
            } else if inLine {
                index += 1
            } else if inBlock {
                if char == "*", next == "/" {
                    inBlock = false
                    index += 2
                } else {
                    index += 1
                }
            } else if char == "/", next == "/" {
                inLine = true
                index += 2
            } else if char == "/", next == "*" {
                inBlock = true
                index += 2
            } else {
                current.append(char)
                index += 1
            }
        }
        lines.append(current)
        return lines
    }

    /// True when one code line before the line holding `capturePhoto(with` starts with `guard` and holds both
    /// `session.isRunning` and `isActive`.
    private func captureIsGuarded(_ text: String) -> Bool {
        let lines = codeLines(of: text)
        guard let capture = lines.firstIndex(where: { $0.contains("capturePhoto(with") }) else { return false }
        return lines[..<capture].contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("guard") && trimmed.contains("session.isRunning") && trimmed.contains("isActive")
        }
    }

    func testCAMDEVICE_T06_theCaptureIsRefusedUnlessTheSessionRunsAndTheConnectionIsActive() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Shared/SnapCapture.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("final class SnapCamera"), "Shared/SnapCapture.swift is the real file")
        XCTAssertTrue(text.contains("capturePhoto(with"), "the capture call is in the file")
        XCTAssertTrue(captureIsGuarded(text), "a guard on the running session and the active connection comes before the capture")

        // Planted texts: the checker must tell a real guard from each wrong build.
        let guardLine = "        guard configured, pending == nil, session.isRunning, output.connection(with: .video)?.isActive == true else { return nil }"
        let captureLine = "        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)"
        XCTAssertTrue(captureIsGuarded("\(guardLine)\n\(captureLine)\n"), "a guard before the capture")
        XCTAssertFalse(captureIsGuarded("\(captureLine)\n\(guardLine)\n"), "a guard after the capture")
        XCTAssertFalse(captureIsGuarded("        guard configured, pending == nil else { return nil }\n\(captureLine)\n"), "no guard on the session")
        XCTAssertFalse(captureIsGuarded("        // \(guardLine.trimmingCharacters(in: .whitespaces))\n\(captureLine)\n"), "a // comment")
        XCTAssertFalse(captureIsGuarded("        /* \(guardLine.trimmingCharacters(in: .whitespaces)) */\n\(captureLine)\n"), "a /* */ comment")
        XCTAssertFalse(captureIsGuarded("        /*\n\(guardLine)\n        */\n\(captureLine)\n"), "a multi-line /* */ comment")
        XCTAssertFalse(captureIsGuarded("        _ = session.isRunning && output.connection(with: .video)?.isActive == true\n\(captureLine)\n"),
                       "a statement that is not a guard")
    }

    // MARK: AC-CAMSNAP-006 and 008 - the generation rule

    func testCAMSNAP_T48_aStepAfterAnAwaitIsDroppedWhenTheScreenWasClosedMeanwhile() async throws {
        let foodAnswer = PlacesTestSupport.nearbyAnswer([("Foo Kitchen", 120)])

        // (a) A read held in the reader: the first result changes nothing; a new frame of the reopened screen completes.
        do {
            let rig = SnapRig()
            rig.reader.script = [.hold]
            rig.reader.fallback = .success(posterClue)
            await rig.open()
            let stale = Task { await rig.flow.submit(frame: SnapTestImages.small) }
            let reading = await until { rig.reader.calls == 1 }
            XCTAssertTrue(reading, "(a) the read is held")
            rig.flow.close()
            await rig.open()
            rig.reader.release(.success(posterClue))
            await stale.value
            XCTAssertEqual(rig.flow.phase, .ready(.picker), "(a) no phase change")
            XCTAssertNil(rig.flow.takeOutcome(), "(a) no outcome")
            XCTAssertTrue(rig.registered.isEmpty, "(a) no registration")
            await rig.log.flush()
            XCTAssertTrue(rig.log.packets.isEmpty, "(a) no packet")
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.reader.calls, 2)
            XCTAssertNotNil(rig.flow.takeOutcome(), "(a) the new frame completes normally")
            await rig.log.flush()
            XCTAssertEqual(rig.log.packets.map(\.kind), [.imageRead], "(a) one packet, for the new frame only")
        }

        // (b) A lookup held in the places transport, with a real PlaceSearch and a real log.
        do {
            let rig = SnapRig(places: [.hold])
            rig.reader.fallback = .success(clue(.otherPlace, name: "Foo Kitchen"))
            await rig.open()
            let stale = Task { await rig.flow.submit(frame: SnapTestImages.small) }
            let looking = await until { rig.places.callCount == 1 }
            XCTAssertTrue(looking, "(b) the lookup is held")
            rig.flow.close()
            await rig.open()
            rig.places.release(with: foodAnswer)
            await stale.value
            XCTAssertEqual(rig.flow.phase, .ready(.picker), "(b) no phase change")
            XCTAssertNil(rig.flow.takeOutcome(), "(b) no outcome")
            XCTAssertTrue(rig.registered.isEmpty, "(b) no registration")
            await rig.log.flush()
            XCTAssertTrue(rig.log.packets.filter { $0.kind == .placeSearch }.isEmpty, "(b) no place packet for a cancelled search")
        }

        // (c) A held capture: the old continuation neither submits nor stops the reopened screen's session.
        do {
            let rig = SnapRig(camera: true)
            rig.shutter.holdFirst = true
            await rig.open()
            let stale = Task { await rig.flow.shutterTapped() }
            let capturing = await until { rig.shutter.captures == 1 }
            XCTAssertTrue(capturing, "(c) the capture is held")
            rig.flow.close()
            await rig.open()
            XCTAssertEqual(rig.flow.phase, .ready(.camera))
            rig.shutter.releaseCapture(SnapTestImages.small)
            await stale.value
            XCTAssertEqual(rig.reader.calls, 0, "(c) the old frame is not read")
            XCTAssertEqual(rig.flow.phase, .ready(.camera), "(c) the reopened screen is untouched")
            XCTAssertEqual(rig.shutter.stops, 1, "(c) only the close stopped a session")
        }

        // (d) A held permission request: a grant that arrives after close starts no session.
        do {
            let rig = SnapRig(camera: true)
            rig.access.status = .notDetermined
            rig.access.holdRequest = true
            rig.flow.start(rig.deps)
            let stale = Task { await rig.flow.begin() }
            let asking = await until { rig.access.requests == 1 }
            XCTAssertTrue(asking, "(d) the request is held")
            rig.flow.close()
            rig.flow.start(rig.deps)
            rig.access.releaseRequest(true)
            await stale.value
            XCTAssertEqual(rig.shutter.starts, 0, "(d) no session start")
            XCTAssertEqual(rig.flow.phase, .idle, "(d) no phase change")
        }

        // (e) A held calendar read of chooseMode: no outcome, no preparation and no registration after close and reopen.
        do {
            let rig = SnapRig(places: [.answer(foodAnswer)])
            rig.reader.fallback = .success(clue(.foodPlace, name: "Foo Kitchen"))
            rig.mirror.hold = true
            await rig.open()
            await rig.flow.submit(frame: SnapTestImages.small)
            XCTAssertEqual(rig.flow.phase, .awaitingMode)
            let stale = Task { await rig.flow.chooseMode(.walk) }
            let reading = await until { rig.mirror.reads == 1 }
            XCTAssertTrue(reading, "(e) the calendar read is held")
            rig.flow.close()
            await rig.open()
            rig.mirror.releaseRead()
            await stale.value
            XCTAssertNil(rig.flow.takeOutcome(), "(e) no outcome")
            XCTAssertEqual(rig.prepared, 0, "(e) no preparation")
            XCTAssertTrue(rig.registered.isEmpty, "(e) no registration")
            XCTAssertEqual(rig.flow.phase, .ready(.picker), "(e) no phase change")
        }

        // (f) A held picker load (debt D30): the generation is taken before the load, so a late photo is dropped.
        do {
            let rig = SnapRig()
            await rig.open()
            var release: CheckedContinuation<Data?, Never>?
            var loading = false
            let stale = Task {
                await rig.flow.pick {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                        release = continuation
                        loading = true
                    }
                }
            }
            let waiting = await until { loading }
            XCTAssertTrue(waiting, "(f) the load is held")
            rig.flow.close()
            await rig.open()
            release?.resume(returning: SnapTestImages.small)
            await stale.value
            XCTAssertEqual(rig.reader.calls, 0, "(f) the late photo is not read")
            XCTAssertEqual(rig.flow.phase, .ready(.picker), "(f) the reopened screen is untouched")
            await rig.flow.pick { SnapTestImages.small }
            XCTAssertEqual(rig.reader.calls, 1, "(f) a photo of the reopened screen is read")
        }
    }
}
