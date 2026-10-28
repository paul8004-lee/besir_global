import XCTest
@testable import besir

/// Hands out a scripted answer and remembers every request, so no test touches the network.
final class VisionSendRecorder {
    private(set) var requests: [URLRequest] = []
    var result: Result<(Data, Int), Error>

    init(status: Int = 200, body: String = "") {
        result = .success((Data(body.utf8), status))
    }

    init(error: Error) {
        result = .failure(error)
    }

    var send: VisionClient.Send {
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

/// SPEC-SHARE-001 AC-SHARE-006 and AC-SHARE-007: one fixed request, and only a valid answer is accepted.
final class ShareVisionClientTests: XCTestCase {
    private let token = "vision-token-0001"
    private var config: AppConfig { AppConfig(kakaoJsKey: "", proxyBaseURL: "https://vision-host.invalid", appToken: token) }
    private let image = Data(count: 2_000).base64EncodedString()
    private let valid = #"{"title":"JAZZ NIGHT","time":"2026-11-07T19:00","place":"Blue Note","confidence":0.9}"#

    private func read(_ recorder: VisionSendRecorder, config: AppConfig? = nil, image: String? = nil) async -> Result<VisionFields, VisionFailure> {
        await VisionClient(config: config ?? self.config, send: recorder.send).read(imageBase64: image ?? self.image, mime: "image/jpeg")
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: AC-SHARE-006

    func testAC_SHARE_006_requestIsAPostToVisionWithTokenJsonAndSixtySeconds() async throws {
        let recorder = VisionSendRecorder(body: valid)
        _ = await read(recorder)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/vision")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-besir-token"), token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 60)
    }

    func testAC_SHARE_006_bodyHasExactlyImageAndMime() async throws {
        let recorder = VisionSendRecorder(body: valid)
        _ = await read(recorder)
        let sent = try body(of: XCTUnwrap(recorder.requests.first))
        XCTAssertEqual(Set(sent.keys), ["image", "mime"])
        XCTAssertEqual(sent["image"] as? String, image)
        XCTAssertEqual(sent["mime"] as? String, "image/jpeg")
    }

    func testAC_SHARE_006_noHostOrTokenGivesNotSetUpWithoutACall() async {
        let recorder = VisionSendRecorder(body: valid)
        let empty = AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: "")
        let client = VisionClient(config: empty, send: recorder.send)
        XCTAssertFalse(client.isConfigured)
        let result = await client.read(imageBase64: image, mime: "image/jpeg")
        XCTAssertEqual(result, .failure(.notSetUp))
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testAC_SHARE_006_imageAboveOneMiBGivesUnreadableWithoutACall() async {
        let recorder = VisionSendRecorder(body: valid)
        let over = Data(count: SharedImage.maxBytes + 1).base64EncodedString()
        let result = await read(recorder, image: over)
        XCTAssertEqual(result, .failure(.imageUnreadable))
        XCTAssertTrue(recorder.requests.isEmpty)
        let exact = Data(count: SharedImage.maxBytes).base64EncodedString()
        _ = await read(recorder, image: exact)
        XCTAssertEqual(recorder.requests.count, 1, "exactly 1 MiB is still sent")
    }

    // MARK: AC-SHARE-007

    func testAC_SHARE_007_validAnswerGivesFieldsAndClampsConfidence() async {
        let result = await read(VisionSendRecorder(body: valid))
        XCTAssertEqual(result, .success(VisionFields(title: "JAZZ NIGHT", time: "2026-11-07T19:00", place: "Blue Note", confidence: 0.9)))
        let high = await read(VisionSendRecorder(body: #"{"title":null,"time":null,"place":"x","confidence":1.7}"#))
        XCTAssertEqual(high, .success(VisionFields(title: nil, time: nil, place: "x", confidence: 1)))
        let low = await read(VisionSendRecorder(body: #"{"title":"a","time":null,"place":null,"confidence":-1}"#))
        XCTAssertEqual(low, .success(VisionFields(title: "a", time: nil, place: nil, confidence: 0)))
    }

    func testAC_SHARE_007_wrongTypesOrMissingConfidenceGiveOther() async {
        let bodies = [
            #"{"title":42,"time":null,"place":null,"confidence":0.9}"#,
            #"{"title":"a","time":null,"place":null}"#,
            #"{"title":"a","time":null,"place":null,"confidence":"NaN"}"#,
            #"{"title":"a","time":null,"place":null,"confidence":true}"#,
            #"{"title":"a","time":null,"confidence":0.9}"#,
            #"["title","time"]"#
        ]
        for text in bodies {
            let result = await read(VisionSendRecorder(body: text))
            XCTAssertEqual(result, .failure(.other), text)
        }
    }

    func testAC_SHARE_007_nonJsonOkAndHtmlServiceUnavailableGiveOther() async {
        let notJson = await read(VisionSendRecorder(body: "<html>ok but not json</html>"))
        XCTAssertEqual(notJson, .failure(.other))
        let html = await read(VisionSendRecorder(status: 503, body: "<html><body>Service Unavailable</body></html>"))
        XCTAssertEqual(html, .failure(.other))
    }

    func testAC_SHARE_007_unauthorizedBodyGivesTokenRejectedAndOtherFourOhOnesDoNot() async {
        let exact = await read(VisionSendRecorder(status: 401, body: #"{"error":"unauthorized"}"#))
        XCTAssertEqual(exact, .failure(.tokenRejected))
        let upstream = await read(VisionSendRecorder(status: 401, body: #"{"error":"vision_upstream_auth","upstream_status":401}"#))
        XCTAssertEqual(upstream, .failure(.other))
        let empty = await read(VisionSendRecorder(status: 401, body: ""))
        XCTAssertEqual(empty, .failure(.other))
    }

    func testAC_SHARE_007_rateLimitIsBusyOfflineIsOfflineAndTimeoutIsOther() async {
        let busy = await read(VisionSendRecorder(status: 429, body: #"{"error":"vision_rate_limited","upstream_status":429}"#))
        XCTAssertEqual(busy, .failure(.busy))
        let offline = await read(VisionSendRecorder(error: URLError(.notConnectedToInternet)))
        XCTAssertEqual(offline, .failure(.offline))
        let timedOut = await read(VisionSendRecorder(error: URLError(.timedOut)))
        XCTAssertEqual(timedOut, .failure(.other))
        let cancelled = await read(VisionSendRecorder(error: CancellationError()))
        XCTAssertEqual(cancelled, .failure(.other))
    }

    func testAC_SHARE_007_serverTextNeverReachesTheShownLine() async throws {
        let secret = "SECRET-SERVER-TEXT-9917"
        let statuses = [400, 401, 413, 429, 502, 503, 504]
        for status in statuses {
            let result = await read(VisionSendRecorder(status: status, body: "{\"error\":\"\(secret)\",\"detail\":\"\(secret)\"}"))
            guard case .failure(let failure) = result else { return XCTFail("status \(status) must fail") }
            XCTAssertFalse(SharedLine.line(for: failure).contains(secret))
        }
    }

    func testAC_SHARE_007_sharedLineHasTheExactTextsOfThePlan() {
        XCTAssertEqual(SharedLine.line(for: .notSetUp), "The assistant is not set up in this build.")
        XCTAssertEqual(SharedLine.line(for: .imageUnreadable), "The shared image couldn't be read.")
        XCTAssertEqual(SharedLine.line(for: .tokenRejected), "The assistant rejected this build's access token.")
        XCTAssertEqual(SharedLine.line(for: .busy), "The image reader is busy. Share the image again in a minute.")
        XCTAssertEqual(SharedLine.line(for: .offline), "Couldn't reach the image reader. Check your connection and share it again.")
        XCTAssertEqual(SharedLine.line(for: .other), "Couldn't read the shared image. Share it again.")
        XCTAssertEqual(SharedLine.linkOnly, "That share only had a link. Share a screenshot of the post instead.")
        XCTAssertEqual(SharedLine.nothingFound, "Nothing that looks like an event was found in that image.")
    }
}
