import XCTest
@testable import besir

/// Hands out a scripted answer and remembers every request, so no test touches the network.
final class SnapSendRecorder {
    private(set) var requests: [URLRequest] = []
    var result: Result<(Data, Int), Error>

    init(status: Int = 200, body: String = "") {
        result = .success((Data(body.utf8), status))
    }

    init(error: Error) {
        result = .failure(error)
    }

    var send: SnapClient.Send {
        { [self] request in
            requests.append(request)
            switch result {
            case .success(let (data, status)):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (data, response)
            case .failure(let error):
                throw error
            }
        }
    }
}

/// SPEC-CAMSNAP-001 AC-CAMSNAP-004: one fixed request to /snap, and only a valid answer is accepted.
final class SnapClientTests: XCTestCase {
    private let token = "snap-token-0001"
    private var config: AppConfig { AppConfig(kakaoJsKey: "", proxyBaseURL: "https://snap-host.invalid", appToken: token) }
    private let image = Data(count: 2_000).base64EncodedString()

    /// The food reply of F1 with raw JSON values replaced by `set` and keys removed by `drop`, keys in sorted order.
    private func reply(_ set: [String: String] = [:], drop: Set<String> = []) -> String {
        var fields: [String: String] = [
            "kind": "\"food_place\"", "name": "\"Chowder Hut\"", "place_type": "\"seafood restaurant\"",
            "text": "\"Clam chowder\"", "title": "null", "time": "null", "confidence": "0.9"]
        for (key, value) in set { fields[key] = value }
        for key in drop { fields[key] = nil }
        return "{" + fields.keys.sorted().map { "\"\($0)\":\(fields[$0] ?? "null")" }.joined(separator: ",") + "}"
    }

    private func read(_ recorder: SnapSendRecorder, config: AppConfig? = nil, image: String? = nil) async -> Result<SnapClue, VisionFailure> {
        await SnapClient(config: config ?? self.config, send: recorder.send).read(imageBase64: image ?? self.image, mime: "image/jpeg")
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCAMSNAP_T15_requestIsOnePostToSnapWithTokenJsonSixtySecondsAndOnlyImageAndMime() async throws {
        let recorder = SnapSendRecorder(body: reply())
        _ = await read(recorder)
        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/snap")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-besir-token"), token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 60)
        let sent = try body(of: request)
        XCTAssertEqual(Set(sent.keys), ["image", "mime"])
        XCTAssertEqual(sent["image"] as? String, image)
        XCTAssertEqual(sent["mime"] as? String, "image/jpeg")
    }

    func testCAMSNAP_T16_noHostOrTokenIsNotSetUpAndOneMiBIsTheLimitWithoutACall() async {
        let recorder = SnapSendRecorder(body: reply())
        let empty = AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: "")
        let client = SnapClient(config: empty, send: recorder.send)
        XCTAssertFalse(client.isConfigured)
        XCTAssertFalse(SnapClient.live(config: empty).isConfigured)
        XCTAssertTrue(SnapClient(config: config, send: recorder.send).isConfigured)
        let unset = await client.read(imageBase64: image, mime: "image/jpeg")
        XCTAssertEqual(unset, .failure(.notSetUp))
        XCTAssertTrue(recorder.requests.isEmpty)

        let over = Data(count: 1_048_577).base64EncodedString()
        XCTAssertEqual(over.count, 1_398_104)
        let refused = await read(recorder, image: over)
        XCTAssertEqual(refused, .failure(.imageUnreadable))
        XCTAssertTrue(recorder.requests.isEmpty, "1,048,577 bytes is refused before any call")

        let exact = Data(count: 1_048_576).base64EncodedString()
        XCTAssertEqual(exact.count, 1_398_104)
        let sent = await read(recorder, image: exact)
        XCTAssertEqual(sent, .success(SnapClue(kind: .foodPlace, name: "Chowder Hut", placeType: "seafood restaurant",
                                               text: "Clam chowder", title: nil, time: nil, confidence: 0.9)))
        XCTAssertEqual(recorder.requests.count, 1, "exactly 1 MiB is still sent")
    }

    func testCAMSNAP_T17_decodeIsStrictOnShapeAndLenientOnWhitespaceUnknownKeysAndRange() async {
        let food = await read(SnapSendRecorder(body: reply()))
        XCTAssertEqual(food, .success(SnapClue(kind: .foodPlace, name: "Chowder Hut", placeType: "seafood restaurant",
                                               text: "Clam chowder", title: nil, time: nil, confidence: 0.9)))
        let kinds: [(String, SnapKind)] = [("event_poster", .eventPoster), ("food_place", .foodPlace),
                                           ("other_place", .otherPlace), ("unknown", .unknown)]
        for (raw, kind) in kinds {
            let result = await read(SnapSendRecorder(body: reply(["kind": "\"\(raw)\""])))
            guard case .success(let clue) = result else { XCTFail("kind \(raw) must decode"); continue }
            XCTAssertEqual(clue.kind, kind, raw)
        }

        let poster = await read(SnapSendRecorder(body: reply(["kind": "\"event_poster\"", "name": "\"Marina Green\"", "place_type": "null",
                                                              "text": "null", "title": "\"Harbor Lights Concert\"",
                                                              "time": "\"Fri Oct 30, 7:30 PM\"", "confidence": "0.8"])))
        XCTAssertEqual(poster, .success(SnapClue(kind: .eventPoster, name: "Marina Green", placeType: nil, text: nil,
                                                 title: "Harbor Lights Concert", time: "Fri Oct 30, 7:30 PM", confidence: 0.8)))

        let failing: [(String, String)] = [
            ("missing kind", reply(drop: ["kind"])),
            ("kind restaurant", reply(["kind": "\"restaurant\""])),
            ("kind FOOD_PLACE", reply(["kind": "\"FOOD_PLACE\""])),
            ("kind 5", reply(["kind": "5"])),
            ("missing text key", reply(drop: ["text"])),
            ("name 5", reply(["name": "5"])),
            ("place_type true", reply(["place_type": "true"])),
            ("confidence string", reply(["confidence": "\"0.9\""])),
            ("confidence true", reply(["confidence": "true"])),
            ("confidence null", reply(["confidence": "null"])),
            ("confidence missing", reply(drop: ["confidence"])),
            ("top level array", "[\(reply())]")
        ]
        for (name, text) in failing {
            let result = await read(SnapSendRecorder(body: text))
            XCTAssertEqual(result, .failure(.other), name)
        }

        let extra = await read(SnapSendRecorder(body: reply(["x": "1"])))
        XCTAssertEqual(extra, food, "an unknown key is ignored")
        let spaced = await read(SnapSendRecorder(body: reply(["name": "\"  Chowder  Hut \""])))
        guard case .success(let spacedClue) = spaced else { return XCTFail("spaced name must decode") }
        XCTAssertEqual(spacedClue.name, "Chowder  Hut", "trimmed, inner spaces kept")
        let blank = await read(SnapSendRecorder(body: reply(["name": "\"\""])))
        guard case .success(let blankClue) = blank else { return XCTFail("empty name must decode") }
        XCTAssertNil(blankClue.name)
        let high = await read(SnapSendRecorder(body: reply(["confidence": "1.7"])))
        guard case .success(let highClue) = high else { return XCTFail("high confidence must decode") }
        XCTAssertEqual(highClue.confidence, 1.0)
        let low = await read(SnapSendRecorder(body: reply(["confidence": "-0.2"])))
        guard case .success(let lowClue) = low else { return XCTFail("low confidence must decode") }
        XCTAssertEqual(lowClue.confidence, 0.0)
    }

    func testCAMSNAP_T18_statusesMapToFailuresAndFailuresToTheFixedLinesWithoutServerText() async {
        let exact = await read(SnapSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#))
        XCTAssertEqual(exact, .failure(.tokenRejected))
        let upstream = await read(SnapSendRecorder(status: 401, body: #"{"error":"snap_upstream_auth","upstream_status":401}"#))
        XCTAssertEqual(upstream, .failure(.other))
        let empty = await read(SnapSendRecorder(status: 401, body: ""))
        XCTAssertEqual(empty, .failure(.other))
        let busy = await read(SnapSendRecorder(status: 429, body: #"{"error":"snap_rate_limited","upstream_status":429}"#))
        XCTAssertEqual(busy, .failure(.busy))
        let offline = await read(SnapSendRecorder(error: URLError(.notConnectedToInternet)))
        XCTAssertEqual(offline, .failure(.offline))
        let timedOut = await read(SnapSendRecorder(error: URLError(.timedOut)))
        XCTAssertEqual(timedOut, .failure(.other))
        let cancelled = await read(SnapSendRecorder(error: CancellationError()))
        XCTAssertEqual(cancelled, .failure(.other))
        let html = await read(SnapSendRecorder(status: 503, body: "<html><body>Service Unavailable</body></html>"))
        XCTAssertEqual(html, .failure(.other))
        let notJson = await read(SnapSendRecorder(body: "<html>ok but not json</html>"))
        XCTAssertEqual(notJson, .failure(.other))

        XCTAssertEqual(SnapLine.line(for: .notSetUp), "The assistant is not set up in this build.")
        XCTAssertEqual(SnapLine.line(for: .imageUnreadable), "The photo couldn't be read.")
        XCTAssertEqual(SnapLine.line(for: .tokenRejected), "The assistant rejected this build's access token.")
        XCTAssertEqual(SnapLine.line(for: .busy), "The image reader is busy. Try again in a minute.")
        XCTAssertEqual(SnapLine.line(for: .offline), "Couldn't reach the image reader. Check your connection and try again.")
        XCTAssertEqual(SnapLine.line(for: .other), "Couldn't read the photo. Try again.")

        let secret = "SECRET-SERVER-TEXT-9917"
        for status in [400, 401, 413, 429, 502, 503, 504] {
            let result = await read(SnapSendRecorder(status: status, body: "{\"error\":\"\(secret)\",\"detail\":\"\(secret)\"}"))
            guard case .failure(let failure) = result else { return XCTFail("status \(status) must fail") }
            XCTAssertFalse(SnapLine.line(for: failure).contains(secret), "status \(status)")
        }
    }
}
