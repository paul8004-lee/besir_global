import Foundation
import CoreLocation

/// 출발지→목적지 이동시간과 경로선을 수단별로 계산한다.
/// 네 수단 모두 카카오 하나로 조회한다 — 자동차는 카카오모빌리티 navi(`/kakao/directions`),
/// 대중교통·도보·자전거는 Worker의 `/kakao/route/<이름>`(경로 선택과 응답 축소는 Worker가 한다).
/// 예비 출처는 두지 않는다 — 출처가 둘이면 같은 구간이 칩과 상세 화면에서
/// 다른 분을 보여주고, 실패가 폴백에 가려진다(D1).
struct DirectionsService {
    let config: AppConfig

    /// 모든 수단을 TransportMode.allCases에서 파생한다 — 손으로 쓴 목록은 케이스가 늘 때
    /// 조용히 빠진다(자전거 추가 때 드러난 위험).
    func estimateAll(from origin: CLLocationCoordinate2D,
                     to dest: CLLocationCoordinate2D) async -> [TransportMode: TravelEstimate] {
        await withTaskGroup(of: TravelEstimate.self) { group in
            for mode in TransportMode.allCases {
                group.addTask { await self.estimate(mode, from: origin, to: dest) }
            }
            var map: [TransportMode: TravelEstimate] = [:]
            for await e in group { map[e.mode] = e }
            return map
        }
    }

    /// 실패(프록시 미설정·오프라인·경로 없음 등)는 값 없는 추정으로 돌려준다.
    /// 실패 이유를 붙일 자리는 이 catch 하나다 — 수단별로 `try?`를 흩어 두면 이유를 붙일 곳이 갈라진다.
    func estimate(_ mode: TransportMode,
                  from origin: CLLocationCoordinate2D,
                  to dest: CLLocationCoordinate2D) async -> TravelEstimate {
        // 프록시가 없으면 네트워크를 타지 않고 곧장 이유를 정한다 — 드라이버(프록시 비움)가 이 길에 기댄다.
        guard config.hasProxy else {
            return TravelEstimate(mode: mode, duration: nil, distance: nil, source: Self.source,
                                  failure: .notConfigured)
        }
        do {
            let r = try await lookup(mode, from: origin, to: dest, points: false)
            return TravelEstimate(mode: mode, duration: r.duration, distance: r.distance, source: Self.source)
        } catch {
            // 취소는 failure nil — 값도 이유도 없는 채로 돌려줘 호출 측이 "실패"로 그리지 않게 한다.
            return TravelEstimate(mode: mode, duration: nil, distance: nil, source: Self.source,
                                  failure: failure(for: error))
        }
    }

    private static let source = "카카오"

    /// 조회가 던진 오류 → 이유. 입력 추출만 여기서 하고 판정은 `TravelFailure.classify` 하나가 한다.
    private func failure(for error: Error) -> TravelFailure? {
        let urlError = error as? URLError
        var code: String?
        if case let LookupError.http(_, c) = error { code = c }
        return TravelFailure.classify(
            hasProxy: config.hasProxy,
            urlErrorCode: urlError?.code,
            bodyErrorCode: code,
            isCancellation: error is CancellationError || urlError?.code == .cancelled)
    }

    /// 조회 실패의 종류를 이유 판정까지 실어 나른다.
    /// http: 200이 아닌 응답(상태와 본문 `error` 코드). malformed: 200인데 필요한 필드가 없음.
    enum LookupError: Error {
        case http(status: Int, code: String?)
        case malformed
    }

    /// 오류 본문 `{"error": "..."}`의 코드. 본문이 JSON이 아니거나 키가 없으면 nil — 카카오 원문
    /// 그대로 통과한 오류(자동차 길찾기)에는 이 키가 없으므로 상태 코드가 대신 판단한다.
    static func errorCode(from data: Data) -> String? {
        struct Body: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error
    }

    /// 프록시 GET 한 곳. 200이 아니면 던진다 — 본문이 오류 JSON이어도 디코딩이 우연히 맞아
    /// 값이 있는 것처럼 되는 일을 막고, 이유 판정에 상태·코드를 넘긴다.
    private func fetch(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LookupError.http(status: status, code: Self.errorCode(from: data)) }
        return data
    }

    /// 한 번의 조회가 돌려주는 전부. 소요시간 조회(points 없음)와 상세 화면(points=1)이 같은
    /// 경로로 만들어야 칩의 분과 화면의 경로가 서로 다른 경로를 가리키지 않는다.
    private struct RouteLookup {
        var duration: TimeInterval
        var distance: Double?
        var segments: [RouteSegment] = []
        var steps: [TransitStep] = []
        var extraMinutes: Int?
    }

    private func lookup(_ mode: TransportMode,
                        from origin: CLLocationCoordinate2D,
                        to dest: CLLocationCoordinate2D,
                        points: Bool) async throws -> RouteLookup {
        switch mode {
        case .car: return try await lookupCar(origin, dest, points: points)
        case .transit: return try await lookupTransit(origin, dest, points: points)
        case .walk, .bicycle: return try await lookupWalkLike(mode, origin, dest, points: points)
        }
    }

    // MARK: - 카카오모빌리티 자동차 길찾기(프록시 경유)

    /// 요청 + 선택 + 변환을 한 함수에 둔다. 소요시간과 도로 좌표(vertexes: [x,y,x,y...] = [lng,lat...])가
    /// 같은 응답에서 나오므로 두 번 부르지 않는다.
    private func lookupCar(_ origin: CLLocationCoordinate2D,
                           _ dest: CLLocationCoordinate2D,
                           points: Bool) async throws -> RouteLookup {
        guard let req = config.proxyRequest("/kakao/directions", query: [
            URLQueryItem(name: "origin", value: "\(origin.longitude),\(origin.latitude)"),
            URLQueryItem(name: "destination", value: "\(dest.longitude),\(dest.latitude)"),
            URLQueryItem(name: "priority", value: "RECOMMEND")
        ]) else { throw URLError(.badURL) }

        let data = try await fetch(req)
        struct Resp: Decodable {
            struct Route: Decodable {
                struct Summary: Decodable { let duration: Int; let distance: Int }
                struct Section: Decodable {
                    struct Road: Decodable { let vertexes: [Double] }
                    let roads: [Road]?
                }
                let summary: Summary?
                let sections: [Section]?
            }
            let routes: [Route]
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let route = resp.routes.first, let summary = route.summary else {
            throw LookupError.malformed   // 경로 없음으로 단정하지 않는다 — 카카오 원문의 빈 routes는 이유를 모른다
        }
        var result = RouteLookup(duration: TimeInterval(summary.duration),
                                 distance: Double(summary.distance))
        if points {
            var coords: [CLLocationCoordinate2D] = []
            for section in route.sections ?? [] {
                for road in section.roads ?? [] {
                    let v = road.vertexes
                    var i = 0
                    while i + 1 < v.count {
                        coords.append(CLLocationCoordinate2D(latitude: v[i + 1], longitude: v[i]))
                        i += 2
                    }
                }
            }
            if !coords.isEmpty {
                result.segments = [RouteSegment(mode: .car, color: Self.carColor, coords: coords)]
            }
        }
        return result
    }

    // MARK: - Worker 경로 응답(v:1)

    /// `/kakao/route/*`의 v:1 응답. 필드는 Worker가 싣는 모양(proxy/src/index.js trimTransit·trimWalkLike)이고,
    /// 도보 단계의 line·lineType·from·to는 null로 온다 — 그래서 전부 옵셔널이다. 없으면 안 되는 건
    /// totalTime 하나뿐(없으면 조회 실패). fare·transfers 등은 화면에 쓰지 않아 디코딩하지 않는다.
    /// 좌표는 `[[경도, 위도], ...]` 쌍의 배열이다(저장된 응답 원문으로 확인, preflight §2-2·§2-4).
    struct RouteBody: Decodable {
        struct Step: Decodable {
            let type: String?       // WALKING / SUBWAY / BUS (카카오 원문)
            let time: Double?       // 초
            let line: String?       // 지하철 "4호선", 버스 "N16(심야)"
            let lineType: String?   // 버스: 간선·광역·지선·직행, 지하철: 일반·급행
            let from: String?
            let to: String?
            let stopCount: Int?     // 정차 정류장 수(승·하차 포함)
            let points: [[Double]]?
        }
        let totalTime: Double       // 초
        let totalDistance: Double?
        let steps: [Step]?
        let points: [[Double]]?     // 도보·자전거 전체 경로
    }

    /// Worker 요청 한 곳. 상태가 200이 아니면 던진다 — 본문이 오류 JSON이어도 디코딩이 우연히
    /// 맞아 값이 있는 것처럼 되는 일을 막는다.
    private func fetchRoute(_ name: String,
                            _ origin: CLLocationCoordinate2D,
                            _ dest: CLLocationCoordinate2D,
                            points: Bool) async throws -> RouteBody {
        var query = [
            URLQueryItem(name: "origin", value: "\(origin.longitude),\(origin.latitude)"),
            URLQueryItem(name: "destination", value: "\(dest.longitude),\(dest.latitude)")
        ]
        if points { query.append(URLQueryItem(name: "points", value: "1")) }
        guard let req = config.proxyRequest("/kakao/route/\(name)", query: query) else {
            throw URLError(.badURL)
        }
        return try JSONDecoder().decode(RouteBody.self, from: try await fetch(req))
    }

    /// `[[lng, lat], ...]` → 좌표열. 쌍이 아닌 원소는 건너뛴다(네트워크 데이터라 인덱싱 전에 길이 확인).
    private static func coords(_ raw: [[Double]]?) -> [CLLocationCoordinate2D] {
        (raw ?? []).compactMap { p in
            p.count >= 2 ? CLLocationCoordinate2D(latitude: p[1], longitude: p[0]) : nil
        }
    }

    // MARK: - 대중교통

    /// 대중교통 경로 결과: 지도에 그릴 좌표 구간 + 사람이 읽는 환승 안내 단계.
    struct TransitPlan {
        var segments: [RouteSegment] = []
        var steps: [TransitStep] = []
        /// 단계 분의 합으로 설명되지 않는 시간(첫·끝 도보·대기 등) N분. 1 이상일 때만 값이 있다.
        var extraMinutes: Int?
        /// 경로가 비었을 때의 이유(상세 화면 일정 영역의 한 줄). 취소·성공이면 nil.
        var failure: TravelFailure?
    }

    /// 상세 화면용. 경로는 Worker가 이미 골랐으므로 앱은 고르지 않는다(칩과 화면이 갈라지지 않게).
    /// 실패하면 빈 결과(호출 측에서 마커만 표시).
    func transitPlan(from origin: CLLocationCoordinate2D,
                     to dest: CLLocationCoordinate2D) async -> TransitPlan {
        guard config.hasProxy else { return TransitPlan(failure: .notConfigured) }
        do {
            let r = try await lookupTransit(origin, dest, points: true)
            return TransitPlan(segments: r.segments, steps: r.steps, extraMinutes: r.extraMinutes)
        } catch {
            return TransitPlan(failure: failure(for: error))
        }
    }

    private func lookupTransit(_ origin: CLLocationCoordinate2D,
                               _ dest: CLLocationCoordinate2D,
                               points: Bool) async throws -> RouteLookup {
        let body = try await fetchRoute("transit", origin, dest, points: points)
        let converted = Self.transitSteps(from: body)
        return RouteLookup(duration: body.totalTime,
                           distance: body.totalDistance,
                           segments: points ? Self.transitSegments(body, origin: origin, dest: dest) : [],
                           steps: converted.steps,
                           extraMinutes: converted.extraMinutes)
    }

    /// 단계마다 실제 좌표로 그린다(도보 단계도 점선 실좌표). 응답에는 출발지→첫 정류장,
    /// 마지막 정류장→도착지 단계가 없어 그 두 곳만 직선 연결선이다. 좌표가 하나도 없으면 빈 배열.
    private static func transitSegments(_ body: RouteBody,
                                        origin: CLLocationCoordinate2D,
                                        dest: CLLocationCoordinate2D) -> [RouteSegment] {
        var segments: [RouteSegment] = []
        for step in body.steps ?? [] {
            let pts = coords(step.points)
            guard !pts.isEmpty else { continue }
            switch step.type {
            case "SUBWAY":
                segments.append(RouteSegment(mode: .subway,
                                             color: subwayColor(name: shortLineName(step.line ?? "")),
                                             coords: pts))
            case "BUS":
                segments.append(RouteSegment(mode: .bus, color: busColor(typeName: step.lineType), coords: pts))
            default:
                segments.append(RouteSegment(mode: .walk, color: walkColor, coords: pts))
            }
        }
        guard let first = segments.first?.coords.first, let last = segments.last?.coords.last else { return [] }
        return [RouteSegment(mode: .walk, color: walkColor, coords: [origin, first])]
            + segments
            + [RouteSegment(mode: .walk, color: walkColor, coords: [last, dest])]
    }

    /// v:1 대중교통 본문 → 안내 단계 + "그 외" 분. 순수 함수라 드라이버가 합성 본문으로 직접 시험한다.
    /// N = 반올림(totalTime/60) − Σ(단계 분)이고 단계 분은 단계마다 같은 반올림 함수를 거친 값이다.
    /// 이렇게 정의해야 N ≥ 1일 때 "단계 분 합 + N = 전체 분"이 오차 없이 성립한다(단계마다 반올림한
    /// 초 단위 차이로 정의하면 단계 수만큼 오차가 쌓인다). N ≤ 0이면 nil.
    static func transitSteps(from body: RouteBody) -> (steps: [TransitStep], extraMinutes: Int?) {
        let raw = body.steps ?? []
        var steps: [TransitStep] = []
        var lastEnd = "출발지"
        for (i, s) in raw.enumerated() {
            let minutes = roundedMinutes(fromSeconds: s.time ?? 0)
            switch s.type {
            case "WALKING":
                if minutes <= 0 { continue }   // 0분짜리 연결 도보는 안내에서 생략
                // 도보 단계의 from/to는 같은 역 이름이 겹쳐 오므로(환승 통로) 다음 탑승 지점을 목적지로 쓴다.
                let next = raw[(i + 1)...].first { $0.type == "SUBWAY" || $0.type == "BUS" }
                var to = "목적지"
                if let next, let name = next.from {
                    to = stopName(isSubway: next.type == "SUBWAY", name)
                }
                steps.append(TransitStep(kind: .walk, line: "", from: lastEnd, to: to,
                                         minutes: minutes, stationCount: nil, color: walkColor))
            case "SUBWAY", "BUS":
                let isSubway = s.type == "SUBWAY"
                let from = s.from.map { stopName(isSubway: isSubway, $0) } ?? lastEnd
                let to = s.to.map { stopName(isSubway: isSubway, $0) } ?? "하차"
                let line: String
                let color: String
                if isSubway {
                    let name = shortLineName(s.line ?? "")
                    line = name.isEmpty ? "지하철" : name
                    color = subwayColor(name: name)
                } else {
                    line = s.line.map(busLabel) ?? "버스"
                    color = busColor(typeName: s.lineType)
                }
                // stops에는 승차·하차 정류장이 모두 들어 있어 지나는 역 수는 하나 적다.
                steps.append(TransitStep(kind: isSubway ? .subway : .bus,
                                         line: line, from: from, to: to,
                                         minutes: minutes,
                                         stationCount: s.stopCount.map { max($0 - 1, 0) },
                                         color: color))
                lastEnd = to
            default:
                continue
            }
        }
        let extra = roundedMinutes(fromSeconds: body.totalTime) - steps.reduce(0) { $0 + $1.minutes }
        return (steps, extra >= 1 ? extra : nil)
    }

    /// 지하철 역 이름엔 "역"을 붙인다(카카오는 "서울역"·"충무로"처럼 섞어 내려줌). 버스 정류장은 그대로.
    private static func stopName(isSubway: Bool, _ raw: String) -> String {
        guard isSubway else { return raw }
        return raw.hasSuffix("역") ? raw : raw + "역"
    }

    /// "N16(심야)" → "N16번(심야)". 괄호 앞에 번을 붙여야 "N16(심야)번"이 되지 않는다.
    private static func busLabel(_ raw: String) -> String {
        guard let paren = raw.firstIndex(of: "(") else { return raw + "번" }
        return String(raw[..<paren]) + "번" + String(raw[paren...])
    }

    /// "수도권 1호선" → "1호선" 처럼 지역 접두어를 뗀다. 카카오 표본(수도권)에선 이미 짧지만
    /// 부산·대구 노선의 모양은 확인하지 못해 남겨 둔다.
    private static func shortLineName(_ raw: String) -> String {
        for prefix in ["수도권 ", "부산 ", "대구 ", "광주 ", "대전 "] where raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        return raw
    }

    // MARK: - 도보·자전거

    /// 도보·자전거는 안내 단계가 쓸모 없어(자전거는 한 줄) 소요시간·거리·한 줄짜리 경로만 만든다.
    private func lookupWalkLike(_ mode: TransportMode,
                                _ origin: CLLocationCoordinate2D,
                                _ dest: CLLocationCoordinate2D,
                                points: Bool) async throws -> RouteLookup {
        let body = try await fetchRoute(mode.rawValue, origin, dest, points: points)
        var result = RouteLookup(duration: body.totalTime, distance: body.totalDistance)
        let pts = Self.coords(body.points)
        if points, !pts.isEmpty {
            let isBicycle = mode == .bicycle
            result.segments = [RouteSegment(mode: isBicycle ? .bicycle : .walk,
                                            color: isBicycle ? Self.bicycleColor : Self.walkColor,
                                            coords: pts)]
        }
        return result
    }

    /// 도보 경로선. 실패하면 빈 배열(마커만 표시).
    func walkRouteSegments(from origin: CLLocationCoordinate2D,
                           to dest: CLLocationCoordinate2D) async -> [RouteSegment] {
        (try? await lookup(.walk, from: origin, to: dest, points: true))?.segments ?? []
    }

    /// 자전거 경로선(실선). 실패하면 빈 배열(호출 측에서 직선 폴백).
    func bicycleRouteSegments(from origin: CLLocationCoordinate2D,
                              to dest: CLLocationCoordinate2D) async -> [RouteSegment] {
        (try? await lookup(.bicycle, from: origin, to: dest, points: true))?.segments ?? []
    }

    /// 자동차 경로선. 실패하면 빈 배열(호출 측에서 직선 폴백).
    func carRouteSegments(from origin: CLLocationCoordinate2D,
                          to dest: CLLocationCoordinate2D) async -> [RouteSegment] {
        (try? await lookup(.car, from: origin, to: dest, points: true))?.segments ?? []
    }

    // MARK: - 색상

    static let walkColor = "#9aa0a6"
    static let carColor = "#2b7fff"
    static let bicycleColor = "#0E9F8E"   // 도보 회색·자동차 파랑·1~9호선 표와 겹치지 않는 청록(D5)

    /// 카카오는 노선 색도 코드도 주지 않고 이름("4호선")만 준다 — 이름→색 표를 앱이 유지한다.
    /// 표에 없는 이름(신분당선 등)은 기본색.
    static func subwayColor(name: String) -> String {
        switch name.trimmingCharacters(in: .whitespaces) {
        case "1호선": return "#0052A4"; case "2호선": return "#00A84D"; case "3호선": return "#EF7C1C"
        case "4호선": return "#00A5DE"; case "5호선": return "#996CAC"; case "6호선": return "#CD7C2F"
        case "7호선": return "#747F00"; case "8호선": return "#E6186C"; case "9호선": return "#BDB092"
        default: return "#3d5bf0"
        }
    }

    /// 버스 단계에서만 부른다 — 지하철 단계의 일반·급행(열차 종류)은 이 함수로 오지 않는다.
    /// 아래 "급행"은 표본에 없는 버스 종류를 지금 앱처럼 빨강으로 두려는 것이다(퇴보 방지).
    static func busColor(typeName: String?) -> String {
        switch typeName?.trimmingCharacters(in: .whitespaces) {
        case "간선": return "#3D5BAB"                    // 간선(파랑)
        case "광역", "직행", "급행": return "#E60012"     // 광역·직행·급행(빨강)
        default: return "#33A23D"                        // 지선·그 밖의 처음 보는 종류(초록)
        }
    }
}
