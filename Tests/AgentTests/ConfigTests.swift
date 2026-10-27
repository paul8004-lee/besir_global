import XCTest
@testable import besir

/// AC-AGENT-001: bundled configuration, the token header, and the temporary data directory of the hosted tests.
@MainActor
final class ConfigTests: XCTestCase {
    private static let scheme = "https://"
    private static let host = "bundled-host.invalid"
    private static let token = "bundled-token-0001"
    private static let savedHost = "saved-host.invalid"
    private static let savedToken = "saved-token-0001"

    private var bundledInfo: [String: Any] {
        ["BesirProxyHost": Self.host, "BesirAppToken": Self.token]
    }

    private func savedConfig() -> AppConfig {
        AppConfig(kakaoJsKey: "", proxyBaseURL: Self.scheme + Self.savedHost, appToken: Self.savedToken)
    }

    private func configuredRequestConfig() -> AppConfig {
        AppConfig(kakaoJsKey: "", proxyBaseURL: Self.scheme + Self.host, appToken: Self.token)
    }

    /// True when the app's data directory is inside this process's temporary directory.
    private func hostedDirectoryIsTemporary() -> Bool {
        let dir = AppConfig.supportDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        var tmp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        if !tmp.hasSuffix("/") { tmp += "/" }
        return dir.hasPrefix(tmp)
    }

    private func addProbeActivity(to store: Store) async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await store.addActivityWithTravel(title: "Directory probe", location: nil,
                                              startDate: start, endDate: start.addingTimeInterval(3600),
                                              travelFrom: nil, returnTo: nil,
                                              outboundMode: .transit, returnMode: .transit,
                                              bufferMinutes: 0, notifyLeadMinutes: 0, syncToCalendar: false)
    }

    // MARK: - Bundled values and the merge

    func testAG001_BundledValuesBuildHTTPSBaseURL() {
        let bundled = AppConfig.bundled(info: bundledInfo)
        XCTAssertEqual(bundled.proxyBaseURL, Self.scheme + Self.host)
        XCTAssertEqual(bundled.appToken, Self.token)
        XCTAssertTrue(bundled.hasProxy)
        XCTAssertTrue(bundled.hasAI)
    }

    func testAG001_BlankBundledValuesLeaveAppUnconfigured() {
        let blankInfos: [[String: Any]?] = [
            nil,
            [:],
            ["BesirProxyHost": "", "BesirAppToken": ""],
            ["BesirProxyHost": "   ", "BesirAppToken": "  "],
            ["BesirProxyHost": 5, "BesirAppToken": ["a"]],
        ]
        for info in blankInfos {
            let bundled = AppConfig.bundled(info: info)
            XCTAssertEqual(bundled.proxyBaseURL, "")
            XCTAssertEqual(bundled.appToken, "")
            XCTAssertFalse(bundled.hasProxy)
        }
        // Positive counterpart: the same call with real values is configured, so the checks above can fail.
        XCTAssertTrue(AppConfig.bundled(info: bundledInfo).hasProxy)
        // A host without a token is not configured either.
        XCTAssertFalse(AppConfig.bundled(info: ["BesirProxyHost": Self.host, "BesirAppToken": ""]).hasProxy)
    }

    func testAG001_NonBlankBundledValuesWinOverSavedProxyFields() {
        var saved = savedConfig()
        saved.autoAddToCalendar = false
        saved.kakaoJsKey = "k-saved"
        let merged = AppConfig.merged(saved: saved, bundled: AppConfig.bundled(info: bundledInfo))
        XCTAssertEqual(merged.proxyBaseURL, Self.scheme + Self.host)
        XCTAssertEqual(merged.appToken, Self.token)
        // The other saved settings are not touched by the merge.
        XCTAssertFalse(merged.autoAddToCalendar)
        XCTAssertEqual(merged.kakaoJsKey, "k-saved")
    }

    func testAG001_BlankBundledValuesFallBackToSavedProxyFields() {
        let saved = savedConfig()
        // Every bundled value blank: the saved proxy fields are used.
        let blank = AppConfig.bundled(info: ["BesirProxyHost": " ", "BesirAppToken": ""])
        let allSaved = AppConfig.merged(saved: saved, bundled: blank)
        XCTAssertEqual(allSaved.proxyBaseURL, Self.scheme + Self.savedHost)
        XCTAssertEqual(allSaved.appToken, Self.savedToken)
        // Field by field: a non-blank bundled host wins, the blank bundled token falls back to the saved one.
        let hostOnly = AppConfig.bundled(info: ["BesirProxyHost": Self.host, "BesirAppToken": ""])
        let mixed = AppConfig.merged(saved: saved, bundled: hostOnly)
        XCTAssertEqual(mixed.proxyBaseURL, Self.scheme + Self.host)
        XCTAssertEqual(mixed.appToken, Self.savedToken)
        // Nothing saved and nothing bundled: unconfigured.
        XCTAssertFalse(AppConfig.merged(saved: nil, bundled: blank).hasProxy)
    }

    /// PRESERVE: a saved auto-add setting (and the other saved settings) survive the merge. Passes before the change.
    func testAG001_SavedAutoAddSettingSurvivesTheMerge() throws {
        let json = "{\"autoAddToCalendar\":false,\"kakaoJsKey\":\"k-saved\"}"
        var saved = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        saved.proxyBaseURL = Self.scheme + Self.savedHost
        saved.appToken = Self.savedToken
        let merged = AppConfig.merged(saved: saved, bundled: AppConfig())
        XCTAssertFalse(merged.autoAddToCalendar)
        XCTAssertEqual(merged.kakaoJsKey, "k-saved")
        XCTAssertEqual(merged.proxyBaseURL, Self.scheme + Self.savedHost)
        XCTAssertEqual(merged.appToken, Self.savedToken)
    }

    // MARK: - What Save writes (audit D3)

    func testT28_D3_BundledProxyFieldsAreNotWrittenToTheSavedConfig() throws {
        var config = AppConfig.merged(saved: nil, bundled: AppConfig.bundled(info: bundledInfo))
        config.autoAddToCalendar = false
        // Positive counterpart: the merged config does hold the bundled values, so the blanks below are the change.
        XCTAssertEqual(config.proxyBaseURL, Self.scheme + Self.host)
        XCTAssertEqual(config.appToken, Self.token)
        let written = config.persistable(bundled: AppConfig.bundled(info: bundledInfo))
        XCTAssertEqual(written.proxyBaseURL, "")
        XCTAssertEqual(written.appToken, "")
        XCTAssertFalse(written.autoAddToCalendar)
        let json = String(decoding: try JSONEncoder().encode(written), as: UTF8.self)
        XCTAssertFalse(json.contains(Self.host))
        XCTAssertFalse(json.contains(Self.token))
        // Loading what was written gives the bundled values back.
        let reloaded = AppConfig.merged(saved: written, bundled: AppConfig.bundled(info: bundledInfo))
        XCTAssertEqual(reloaded.proxyBaseURL, Self.scheme + Self.host)
        XCTAssertEqual(reloaded.appToken, Self.token)
    }

    func testT28_D3_BlankBundledFieldsKeepTheSavedProxyValues() {
        let blank = AppConfig.bundled(info: ["BesirProxyHost": " ", "BesirAppToken": ""])
        let written = savedConfig().persistable(bundled: blank)
        XCTAssertEqual(written.proxyBaseURL, Self.scheme + Self.savedHost)
        XCTAssertEqual(written.appToken, Self.savedToken)
        // Field by field: only the field the bundle supplies is blanked.
        let hostOnly = AppConfig.bundled(info: ["BesirProxyHost": Self.host, "BesirAppToken": ""])
        let mixed = savedConfig().persistable(bundled: hostOnly)
        XCTAssertEqual(mixed.proxyBaseURL, "")
        XCTAssertEqual(mixed.appToken, Self.savedToken)
    }

    // MARK: - The token header

    func testAG001_TokenSentOnlyInBesirTokenHeader() throws {
        let cfg = configuredRequestConfig()
        let post = try XCTUnwrap(cfg.proxyPOSTRequest("/ai/chat", body: Data("{}".utf8)))
        let get = try XCTUnwrap(cfg.proxyRequest("/places", query: [URLQueryItem(name: "q", value: "a")]))
        for req in [post, get] {
            XCTAssertEqual(req.value(forHTTPHeaderField: "x-besir-token"), Self.token)
            // The token value appears in exactly one header, and that header is the one above.
            let carrying = (req.allHTTPHeaderFields ?? [:]).filter { $0.value == Self.token }.map { $0.key.lowercased() }
            XCTAssertEqual(carrying, ["x-besir-token"])
            XCTAssertFalse((req.url?.absoluteString ?? "").contains(Self.token))
        }
        XCTAssertFalse(String(decoding: post.httpBody ?? Data(), as: UTF8.self).contains(Self.token))
    }

    func testAG001_OldTokenHeaderIsAbsent() throws {
        let cfg = configuredRequestConfig()
        let plain = try XCTUnwrap(cfg.proxyPOSTRequest("/ai/chat", body: Data("{}".utf8)))
        let bearer = try XCTUnwrap(cfg.proxyRequest("/x", method: "POST", query: nil, body: nil, bearer: "bearer-0001"))
        for req in [plain, bearer] {
            let names = (req.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
            // Positive counterpart first: the new header is there, so an empty header list cannot pass.
            XCTAssertTrue(names.contains("x-besir-token"))
            XCTAssertFalse(names.contains("x-app-token"))
            XCTAssertNil(req.value(forHTTPHeaderField: "x-app-token"))
        }
    }

    /// PRESERVE: URL assembly, method, body, bearer and timeout of the one request builder. Passes before the change.
    func testAG001_RequestURLAndBodyBehaviorIsUnchanged() throws {
        let cfg = configuredRequestConfig()
        let body = Data("{\"k\":1}".utf8)
        let post = try XCTUnwrap(cfg.proxyPOSTRequest("/ai/chat", body: body))
        XCTAssertEqual(post.url?.absoluteString, Self.scheme + Self.host + "/ai/chat")
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.httpBody, body)
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(post.value(forHTTPHeaderField: "Authorization"))
        let postURL = try XCTUnwrap(post.url)
        XCTAssertEqual(post.timeoutInterval, URLRequest(url: postURL).timeoutInterval)
        let timed = try XCTUnwrap(cfg.proxyPOSTRequest("/ai/chat", body: body, timeout: 7))
        XCTAssertEqual(timed.timeoutInterval, 7)

        let get = try XCTUnwrap(cfg.proxyRequest("/places", query: [URLQueryItem(name: "q", value: "a b")]))
        XCTAssertEqual(get.httpMethod, "GET")
        XCTAssertNil(get.httpBody)
        XCTAssertNil(get.value(forHTTPHeaderField: "Content-Type"))
        let getURL = try XCTUnwrap(get.url)
        let comps = URLComponents(url: getURL, resolvingAgainstBaseURL: false)
        XCTAssertEqual(comps?.path, "/places")
        XCTAssertEqual(comps?.queryItems, [URLQueryItem(name: "q", value: "a b")])

        let bearer = try XCTUnwrap(cfg.proxyRequest("/x", method: "POST", query: nil, body: nil, bearer: "bearer-0001"))
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-0001")

        // A trailing slash on the base is dropped before the path is appended.
        let slashed = AppConfig(kakaoJsKey: "", proxyBaseURL: Self.scheme + Self.host + "/", appToken: Self.token)
        let slashedPost = try XCTUnwrap(slashed.proxyPOSTRequest("/ai/chat", body: body))
        XCTAssertEqual(slashedPost.url?.absoluteString, Self.scheme + Self.host + "/ai/chat")

        // Unconfigured: no request at all.
        let noToken = AppConfig(kakaoJsKey: "", proxyBaseURL: Self.scheme + Self.host, appToken: " ")
        XCTAssertNil(AppConfig().proxyPOSTRequest("/ai/chat", body: body))
        XCTAssertNil(noToken.proxyPOSTRequest("/ai/chat", body: body))
    }

    // MARK: - Test isolation

    func testAG001_SupportDirectoryIsTemporaryWhileHostingTests() async {
        let redirected = hostedDirectoryIsTemporary()
        XCTAssertTrue(redirected, "The data directory must be inside the temporary directory before any write.")
        guard redirected else { return }
        let store = Store(notifications: NotificationManager())
        await addProbeActivity(to: store)
        let file = AppConfig.supportDirectory.appendingPathComponent("activities.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// Self-test of the test-side helper `EmptyStore`.
    func testAG001_EachTestStartsFromAnEmptyStore() async {
        let redirected = hostedDirectoryIsTemporary()
        XCTAssertTrue(redirected, "The data directory must be inside the temporary directory before any write.")
        guard redirected else { return }
        let first = EmptyStore.make()
        XCTAssertTrue(first.activities.isEmpty)
        await addProbeActivity(to: first)
        XCTAssertEqual(first.activities.count, 1)
        let second = EmptyStore.make()
        XCTAssertTrue(second.activities.isEmpty)
    }
}
