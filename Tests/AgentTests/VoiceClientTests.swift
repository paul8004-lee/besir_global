import XCTest
@testable import besir

/// Hands out a scripted answer and remembers every request, so no test touches the network.
final class VoiceSendRecorder {
    private(set) var requests: [URLRequest] = []
    var result: Result<(Data, Int), Error>

    init(status: Int = 200, body: String = "") {
        result = .success((Data(body.utf8), status))
    }

    init(error: Error) {
        result = .failure(error)
    }

    var send: VoiceClient.Send {
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

/// SPEC-VOICE-001 AC-VOICE-010: one fixed request to /voice, and only a valid answer is accepted.
@MainActor
final class VoiceClientTests: XCTestCase {
    private let token = "voice-token-0001"
    private var config: AppConfig { AppConfig(kakaoJsKey: "", proxyBaseURL: "https://voice-host.invalid", appToken: token) }
    private let clip = Data((0..<2_000).map { UInt8($0 & 0xff) })

    private func transcribe(_ recorder: VoiceSendRecorder, config: AppConfig? = nil, wav: Data? = nil) async -> Result<String, VoiceFailure> {
        await VoiceClient(config: config ?? self.config, send: recorder.send).transcribe(wav: wav ?? clip)
    }

    func testVOICE_T01_requestIsOnePostToVoiceWithTokenJsonThirtySecondsAndOnlyAudio() async throws {
        let recorder = VoiceSendRecorder(body: #"{"text":"hi"}"#)
        _ = await transcribe(recorder)
        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/voice")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-besir-token"), token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 30)
        let data = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Array(object.keys), ["audio"])
        XCTAssertEqual(object["audio"] as? String, clip.base64EncodedString())
    }

    func testVOICE_T02_unsetConfigAndOversizeClipMakeNoCallAndTheLimitItselfMakesOne() async {
        let blank = AppConfig(kakaoJsKey: "", proxyBaseURL: "", appToken: "")
        XCTAssertFalse(VoiceClient(config: blank, send: VoiceSendRecorder().send).isConfigured)
        XCTAssertTrue(VoiceClient(config: config, send: VoiceSendRecorder().send).isConfigured)

        let unset = VoiceSendRecorder(body: #"{"text":"hi"}"#)
        let notSetUp = await transcribe(unset, config: blank)
        XCTAssertEqual(notSetUp, .failure(.notSetUp))
        XCTAssertEqual(unset.requests.count, 0)

        let tooBig = VoiceSendRecorder(body: #"{"text":"hi"}"#)
        let refused = await transcribe(tooBig, wav: Data(count: 1_000_001))
        XCTAssertEqual(refused, .failure(.other))
        XCTAssertEqual(tooBig.requests.count, 0)

        let atLimit = VoiceSendRecorder(body: #"{"text":"hi"}"#)
        let accepted = await transcribe(atLimit, wav: Data(count: 1_000_000))
        XCTAssertEqual(accepted, .success("hi"))
        XCTAssertEqual(atLimit.requests.count, 1)
    }

    func testVOICE_T03_outcomeTableMapsEveryAnswerToATextOrOneFailure() async {
        let table: [(status: Int, body: String, expected: Result<String, VoiceFailure>)] = [
            (200, #"{"text":"hi"}"#, .success("hi")),
            (200, "{}", .failure(.other)),
            (200, #"{"text":5}"#, .failure(.other)),
            (200, "[]", .failure(.other)),
            (200, "not json", .failure(.other)),
            (401, #"{"error":"unauthorized"}"#, .failure(.tokenRejected)),
            (401, #"{"error":"voice_upstream_auth"}"#, .failure(.other)),
            (401, #"{"error":"unauthorized","extra":1}"#, .failure(.other)),
            (429, #"{"error":"voice_rate_limited"}"#, .failure(.busy)),
            (400, "{}", .failure(.other)),
            (413, "{}", .failure(.other)),
            (500, "{}", .failure(.other)),
            (502, "{}", .failure(.other)),
            (504, "{}", .failure(.other)),
        ]
        for row in table {
            let result = await transcribe(VoiceSendRecorder(status: row.status, body: row.body))
            XCTAssertEqual(result, row.expected, "status \(row.status) body \(row.body)")
        }
        let offline = await transcribe(VoiceSendRecorder(error: URLError(.notConnectedToInternet)))
        XCTAssertEqual(offline, .failure(.offline))
        let timedOut = await transcribe(VoiceSendRecorder(error: URLError(.timedOut)))
        XCTAssertEqual(timedOut, .failure(.other))
    }
}
