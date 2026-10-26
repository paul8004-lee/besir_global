import Foundation

/// 외부 API 설정.
/// `~/Library/Application Support/besir/config.json` 에서 읽는다.
///
/// 보안 설계: Kakao REST 키는 **앱에 두지 않고** Cloudflare Worker 프록시가 보관한다.
/// 앱은 `proxyBaseURL` + `appToken` 으로 프록시만 호출한다(키 노출 없음).
/// Kakao JavaScript 키는 지도 SDK가 클라이언트에서 로드해야 해 불가피하게 앱에 두되,
/// 카카오 콘솔의 도메인 잠금(`https://localhost:8089`)으로 보호한다.
struct AppConfig: Codable {
    /// 지도 렌더링용 Kakao JS 키(클라이언트 노출, 도메인 잠금으로 보호).
    var kakaoJsKey: String = ""
    /// 프록시 서버 주소.
    var proxyBaseURL: String = ""
    /// 프록시 호출용 앱 토큰(비밀이 아니라 식별·차단용).
    var appToken: String = ""
    /// 새 일정을 구글 캘린더(서버의 besir 캘린더)에도 보일지의 기본값(기본 ON).
    /// 반영은 서버가 하므로 연결 여부와 무관하게 저장된다.
    var autoAddToCalendar: Bool = true

    // 구버전 config.json의 kakaoRestKey 키는 JSONDecoder가 무시한다.
    // preferredMode/preferredBuffer/preferredNotify도 같은 취급이다 — 저장된 선호가 조용히
    // 적용되다 여유 0분짜리 35건이 등록되고도 아무도 모른 사고(b303f41) 뒤, 값이 없으면
    // 추측하지 않고 앱이 그 자리에서 묻는 쪽으로 바꿨다. 기기에 남은 옛 키는 읽지 않는다.

    var hasKakaoJs: Bool { !kakaoJsKey.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 프록시(자동차 길찾기·대중교통·장소검색)가 설정돼 있는지.
    var hasProxy: Bool {
        !proxyBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !appToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 프록시 요청을 만드는 유일한 곳. URL 조립·앱 토큰 헤더·메서드·본문·세션 Bearer를 여기서만 붙인다 —
    /// GET/POST 빌더가 따로 조립하면 헤더 규칙이 바뀔 때 한쪽만 고쳐진다(계약 5). `method`에 기본값이 없는
    /// 것은 두 인자짜리 `proxyRequest(_:query:)`와 호출이 모호해지지 않게 하려는 것이다.
    /// `timeout`은 그 요청만의 시한(초)이다 — nil이면 URLRequest 기본값 그대로다. 반복 글 해석만 짧은 시한을 쓰는데
    /// (SPEC-UIKIT-019 REQ-006), 해석용 요청을 따로 조립하면 이 "유일한 곳"이 둘이 되므로 매개변수로 받는다(L-31).
    func proxyRequest(_ path: String, method: String, query: [URLQueryItem]?, body: Data?, bearer: String?,
                      timeout: TimeInterval? = nil) -> URLRequest? {
        let base = proxyBaseURL.trimmingCharacters(in: .whitespaces)
        guard hasProxy, var comps = URLComponents(string: base) else { return nil }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + path
        comps.queryItems = query
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        if let timeout { req.timeoutInterval = timeout }
        req.httpMethod = method
        req.setValue(appToken, forHTTPHeaderField: "X-App-Token")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    /// 프록시 GET 요청을 만든다. 경로(path)와 쿼리를 받아 토큰 헤더를 붙인다.
    func proxyRequest(_ path: String, query: [URLQueryItem]) -> URLRequest? {
        proxyRequest(path, method: "GET", query: query, body: nil, bearer: nil)
    }

    /// 프록시 POST 요청을 만든다(예: 대화형 일정 등록 `/ai/chat`).
    func proxyPOSTRequest(_ path: String, body: Data, timeout: TimeInterval? = nil) -> URLRequest? {
        proxyRequest(path, method: "POST", query: nil, body: body, bearer: nil, timeout: timeout)
    }

    /// LLM(대화형 일정 등록)을 쓸 수 있는지. 키는 프록시가 보관하므로 프록시 설정 여부로 판단.
    var hasAI: Bool { hasProxy }

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("besir", isDirectory: true)
    }()

    static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }

    /// 앱에 내장하는 기본 설정(출시본의 정상 기본값).
    /// - 비밀이 아닌 값만 내장한다: 프록시 주소, 앱 토큰(식별·차단용), 카카오 JS 키(도메인 잠금).
    /// - **REST 키는 여기 없음** — Cloudflare Worker 프록시(서버)에만 존재하므로 앱스토어 배포 안전.
    /// - 사용자가 설정 화면에서 값을 저장하면 그쪽(config.json)이 우선한다.
    static let bundledDefaults = AppConfig(
        kakaoJsKey: "",
        proxyBaseURL: "",
        appToken: ""
    )

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return bundledDefaults   // 설정 파일 없으면 내장 기본값 사용
        }
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.configURL)
        }
    }
}

extension AppConfig {
    private enum CodingKeys: String, CodingKey {
        case kakaoJsKey, proxyBaseURL, appToken, autoAddToCalendar
    }
    // 누락된 키는 기본값으로(새 필드 추가 시 옛 config.json이 깨지지 않게).
    // 옛 config.json의 구글 OAuth 클라이언트 id 키도 CodingKeys에 없어 조용히 무시된다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kakaoJsKey: (try? c.decode(String.self, forKey: .kakaoJsKey)) ?? "",
            proxyBaseURL: (try? c.decode(String.self, forKey: .proxyBaseURL)) ?? "",
            appToken: (try? c.decode(String.self, forKey: .appToken)) ?? "",
            autoAddToCalendar: (try? c.decode(Bool.self, forKey: .autoAddToCalendar)) ?? true
        )
    }
}
