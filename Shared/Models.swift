import Foundation
import CoreGraphics
import CoreLocation

/// 이동수단.
enum TransportMode: String, Codable, CaseIterable, Identifiable {
    case car        // 자동차
    case transit    // 대중교통
    case walk       // 도보
    case bicycle    // 자전거 — 옛 빌드는 이 raw 값을 디코딩하다 던져 일정 전체를 못 읽는다(D12, Store.save 백업)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .car: return "Car"
        case .transit: return "Transit"
        case .walk: return "Walk"
        case .bicycle: return "Bicycle"
        }
    }

    /// 조사가 붙은 수단 이름("대중교통으로"). "대중교통로"처럼 받침 판정을 잘못 타는 문장을
    /// 조합하지 않도록 이름과 조사를 한 곳에 묶어 둔다(D14) — 호출 쪽은 이 값만 붙인다.
    var titleWithParticle: String {
        switch self {
        case .car: return "By car"
        case .transit: return "By transit"
        case .walk: return "On foot"
        case .bicycle: return "By bicycle"
        }
    }

    var systemImage: String {
        switch self {
        case .car: return "car.fill"
        case .transit: return "tram.fill"
        case .walk: return "figure.walk"
        case .bicycle: return "bicycle"
        }
    }
}

/// 초 → 분 반올림의 단일 출처. durationText·대중교통 단계 분·"그 외" N이 같은 식을 써야
/// 단계 분의 합과 전체 분이 어긋나지 않는다(계약 5). `.rounded()`는 .5를 0에서 먼 쪽으로
/// 올린다(90초 → 2분).
func roundedMinutes(fromSeconds seconds: TimeInterval) -> Int {
    Int((seconds / 60).rounded())
}

/// 이동시간이 비었을 때의 이유(D10). 칩 캡션과 안내 문장을 이 enum 한 곳에서만 만든다 —
/// 칩·줄 노트·상세 화면이 각자 문구를 쓰면 같은 실패가 화면마다 다르게 말한다(계약 5).
/// 문장은 수단 이름을 넣지 않는다: 같은 이유가 네 칩과 상세 화면 어디에나 쓰인다.
enum TravelFailure: String, CaseIterable {
    case offline, lookupFailed, noRoute, notConfigured

    /// (칩 캡션, 한 문장 설명). 캡션은 칩 폭 때문에 4자 이하여야 한다.
    var text: (caption: String, sentence: String) {
        switch self {
        case .offline:
            return ("Offline", "No internet connection, so travel time couldn't be calculated.")
        case .lookupFailed:
            return ("Failed", "The directions service didn't respond, so travel time couldn't be calculated. Try again in a moment.")
        case .noRoute:
            return ("No route", "No route was found between the two places, so travel time couldn't be calculated.")
        case .notConfigured:
            return ("Setup", "The directions server isn't set up, so travel time couldn't be calculated. Check the settings.")
        }
    }

    var caption: String { text.caption }
    var sentence: String { text.sentence }

    /// The single source of the reason (plan §2.5). A pure function, so tests run it as a table.
    /// The body code comes from `GoogleRoutes.errorCode(from:)`: the Worker's own code, or Google's status, or a Google
    /// reason beginning `API_KEY_`. A code that means "the key or the app token is not accepted" gives `notConfigured`;
    /// so does an HTTP status of 401 or 403. Every other answer is a failed lookup. The Worker never sends a no-route
    /// code: "no route" comes from an empty 200 answer, not from this function. A cancelled lookup is not a failure.
    static func classify(hasProxy: Bool,
                         urlErrorCode: URLError.Code?,
                         bodyErrorCode: String?,
                         isCancellation: Bool,
                         httpStatus: Int? = nil) -> TravelFailure? {
        if isCancellation { return nil }   // a lookup cut off by leaving the screen must not show a false warning
        if !hasProxy { return .notConfigured }
        if let code = urlErrorCode, offlineCodes.contains(code) { return .offline }
        if let body = bodyErrorCode, rejectedCodes.contains(body) || body.hasPrefix("API_KEY_") {
            return .notConfigured
        }
        if let status = httpStatus, status == 401 || status == 403 { return .notConfigured }
        return .lookupFailed   // other codes, other statuses, undecodable answers, unknown errors
    }

    /// Codes that mean the Worker or Google did not accept the app token or the key.
    private static let rejectedCodes: Set<String> = [
        "unauthorized", "google_key_not_configured", "PERMISSION_DENIED", "UNAUTHENTICATED"
    ]

    /// Codes that point at the device's network. Host resolution and connection failures are almost always a dropped
    /// connection rather than the Worker, so they are included.
    /// Excluded: timedOut - the request timeout cannot tell a slow service from a weak connection, and "try again in a
    /// moment" (a failed lookup) is right either way.
    /// Excluded: secureConnectionFailed, badServerResponse, cannotParseResponse and badURL - those are the lookup's
    /// problem, not the connection's.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
        .internationalRoamingOff, .callIsActive,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed
    ]
}

/// The travel time estimate of one mode.
struct TravelEstimate: Identifiable {
    let mode: TransportMode
    /// Travel time in seconds. Nil when it could not be calculated.
    let duration: TimeInterval?
    /// Distance in metres. Nil when unknown.
    let distance: Double?
    /// The data source (always "Google").
    let source: String
    /// Why there is no value. Filled only when the lookup really failed; a cancelled lookup leaves it nil.
    var failure: TravelFailure? = nil
    /// The warning strings Google returned with the route, in its order. Only walking and bicycling routes carry any.
    var warnings: [String] = []
    /// The route time without traffic conditions. Filled only by a live car lookup (a replan trigger).
    var staticDuration: TimeInterval? = nil

    var id: String { mode.rawValue }

    var isAvailable: Bool { duration != nil }

    /// "23분" 형태 문자열.
    var durationText: String {
        guard let duration else { return "No info" }
        let minutes = roundedMinutes(fromSeconds: duration)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }
}

/// 대중교통 경로의 한 구간(도보/지하철/버스)을 색과 좌표열로 표현.
enum RouteMode: String {
    case walk, subway, bus, car, bicycle
}

struct RouteSegment {
    let mode: RouteMode
    let color: String   // hex, 예: "#00A84D"
    let coords: [CLLocationCoordinate2D]
}

/// 대중교통 경로 안내의 한 단계(도보 이동 / 버스·지하철 탑승).
struct TransitStep: Identifiable {
    let id = UUID()
    let kind: RouteMode
    /// 노선 이름("1호선", "101번"). 도보 구간은 빈 문자열.
    let line: String
    /// 승차 정류장·역 이름. 도보는 출발 지점.
    let from: String
    /// 하차 정류장·역 이름. 도보는 도착 지점.
    let to: String
    let minutes: Int
    /// 지나는 역·정류장 수(대중교통 구간만).
    let stationCount: Int?
    let color: String   // hex
}

extension TransitStep {
    var systemImage: String {
        switch kind {
        case .walk: return "figure.walk"
        case .subway: return "tram.fill"
        case .bus: return "bus.fill"
        case .car: return "car.fill"
        case .bicycle: return "bicycle"
        }
    }

    /// "도보 5분" / "1호선 탑승" / "101번 버스 탑승"
    var headline: String {
        switch kind {
        case .walk: return "Walk \(minutes) min"
        case .bus: return "Take bus \(line)"
        default: return "Take \(line)"
        }
    }

    /// "시청역까지 이동" / "시청역 → 종로3가역 · 3개 역 · 8분"
    var detail: String {
        if kind == .walk { return "Walk to \(to)" }
        let unit = kind == .subway ? " station(s)" : " stop(s)"
        let count = stationCount.map { " · \($0)\(unit)" } ?? ""
        return "\(from) → \(to)\(count) · \(minutes) min"
    }
}

/// 좌표가 있는 장소.
/// Hashable인 이유: 장소 검색 결과 목록은 이름이 겹칠 수 있어(같은 상호의 다른 지점) 좌표까지
/// 포함한 값 전체로 구분해야 ForEach에서 두 곳이 한 줄로 합쳐지지 않는다.
struct Place: Codable, Equatable, Hashable {
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
}

/// 즐겨찾기 장소(집·회사 등 자주 쓰는 곳). 일정 추가 시 빠른 선택, AI 파싱 시 목적지 이름 해석에 쓰인다.
struct FavoritePlace: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var label: String
    var place: Place
}

/// 등록된 일정.
struct ScheduledEvent: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    /// 출발지(일정 추가 시 지정). 옛 일정은 nil일 수 있음.
    var origin: Place?
    var destination: Place
    /// 도착해야 하는 시각.
    var arrivalDate: Date
    /// 선택한 이동수단.
    var mode: TransportMode
    /// 도착 시 여유로 둘 버퍼(분). 출발 시각 = 도착 - 이동시간 - 버퍼.
    var bufferMinutes: Int
    /// 출발 시각 몇 분 전에 알릴지(분).
    var notifyLeadMinutes: Int
    /// 이 일정의 출발 알림을 켤지. 옛 데이터는 nil이고 켜진 것으로 본다(`wantsNotification`).
    var notifyEnabled: Bool?
    /// 이 일정을 구글 캘린더에 올릴지. nil(옛 데이터)이면 전역 설정(autoAddToCalendar)을 따른다.
    var syncToCalendar: Bool?
    /// 계산된 출발 시각(스냅샷).
    var departureDate: Date?
    /// 계산에 사용된 이동시간(초) 스냅샷.
    var travelSeconds: TimeInterval?
    /// 예약된 알림 식별자.
    var notificationId: String?
    /// 반복 일정으로 한 번에 생성된 경우 같은 값을 공유(그룹 일괄 삭제용). 단발성 일정은 nil.
    var recurrenceId: UUID?
    /// 이 이동 구간이 딸려 있는 활동 블록(ActivityBlock.id).
    /// 구간이 활동에 속하는 유일한 길이다(SPEC-ONTIME-008 REQ-001·012): 값이 있으면 그 활동을
    /// 옮기거나 고칠 때 이 구간도 같이 움직이고, 활동과 함께 만들어질 때 기록된다. nil인 구간은
    /// 주인 없는 단독 이동이다 — 제목·시각·장소가 어떤 활동과 맞아도 짝으로 읽지 않는다. 옛
    /// 반복 데이터가 연결 없이 남은 것도 같은 대접이다(D-3, 이전 변환 없음).
    var linkedActivityId: UUID?

    /// 알림을 예약해야 하는지(옛 데이터는 켜진 것으로 취급).
    var wantsNotification: Bool { notifyEnabled ?? true }
    /// 구글 캘린더에 올려도 되는지(옛 데이터는 전역 설정을 따르므로 true).
    var wantsCalendarSync: Bool { syncToCalendar ?? true }

    /// 이 일정의 시각 기준. nil(옛 데이터)은 .arrival과 동일하게 취급.
    /// 실시간 재계산(refreshUpcomingEstimates) 시 어느 방향으로 계산해야 하는지 판단하는 데 쓰인다.
    var anchor: ScheduleAnchor?

    // MARK: 이동시간 미계산 표시(REQ-023, SPEC-UIKIT-009 MC)

    /// 이동시간이 계산되지 않은 구간의 경고 블록이 설 자리 — 앵커 시각 A. 계산된 구간은 nil.
    /// A는 추정과 무관한 쪽이다: 출발 기준(`.departure`)이면 `departureDate ?? arrivalDate`
    /// (출발은 추정 앞에 대입되고, 반복 뒤 회차처럼 nil이면 그 회차의 출발이 곧 arrivalDate),
    /// 그 밖(`.arrival`·nil 옛 데이터)이면 `arrivalDate`. "이동시간 미계산" 판정은 이 값이
    /// nil이 아닌 것과 같은 말이다(AC-010의 "미계산 판정"). 저장 필드가 아니라 계산이라
    /// JSON에 나타나지 않는다(REQ-019).
    var failedBlockAnchor: Date? {
        guard travelSeconds == nil else { return nil }
        return anchorDate
    }

    /// 사용자가 정한 쪽의 시각 — 출발 기준이면 `departureDate ?? arrivalDate`, 그 밖은 `arrivalDate`.
    /// 이동시간 재조회(`refreshUpcomingEstimates`)가 건드리지 않는 쪽이라, 미계산 경고 블록의 자리와
    /// 동기화 비교(`EventSyncContent`)가 같은 식을 읽는다(계약 5 — 식이 두 곳에 있으면 한쪽만 고쳐진다).
    var anchorDate: Date {
        (anchor ?? .arrival) == .departure ? (departureDate ?? arrivalDate) : arrivalDate
    }

    /// 시간표에 나열되는 구간. 계산된 구간은 [출발, 도착]. 이동시간 계산이 실패한 구간은
    /// 가는 편(도착 고정) [앵커−10분, 앵커], 오는 편(출발 고정) [앵커, 앵커+10분] — 운영자 제안
    /// "값을 가진 10분짜리 블럭으로 취급"(REQ-016, t82). 폭은 드래그 눈금 상수를 읽는다(REQ-013) —
    /// 그리기·끌기 판정·날 나열이 같은 구간을 보게 기준 트리에서 `guard let dep …`가 살던 자리의
    /// 계산이 이렇게 하나로 모인다(계약 5 — Store의 달력 점도 이 값을 읽는다). 출발이 없거나
    /// 도착 ≤ 출발인 깨진 레코드(travelSeconds는 있는데 departureDate가 비었다)는 nil — 그때는
    /// 도착일 하루만 나열한다.
    var listedSpan: (start: Date, end: Date)? {
        if let a = failedBlockAnchor {
            let width = Double(Store.dragSnapStepMinutes) * 60
            // 고정된 쪽(앵커)에 붙어 반대로 늘린다 — 계산된 짧은 구간의 최소 높이 산식과 같은 방향.
            if (anchor ?? .arrival) == .departure {
                return (a, a.addingTimeInterval(width))      // 오는 편 — 출발 고정, 아래로
            }
            return (a.addingTimeInterval(-width), a)          // 가는 편 — 도착 고정, 위로
        }
        guard let dep = departureDate, arrivalDate > dep else { return nil }
        return (dep, arrivalDate)
    }

    /// 이 구간이 그 날의 시간표에 나열되는가. 나열 구간(listedSpan — 계산 성공·실패 모두)이
    /// 걸치는 모든 날(`Store.overlapsDay`, 반열린), 그게 없는 깨진 레코드는 도착일(옛 폴백).
    /// 실패 블록의 날 나열도 다른 이동과 같은 구간 규칙을 탄다(REQ-016 — 앵커 00:00 가는 편은
    /// [23:50, 00:00)이라 전날에만 나열된다). 점(recomputeDaysWithSchedule)과 나열(events(on:))
    /// 이 같은 날을 내는 것도 이 함수가 보증한다(AC-010 (13)).
    /// `Store.overlapsDay`를 읽으므로 MainActor다 — 호출자(뷰·Store·드라이버 main) 전부 그렇다.
    @MainActor func isListed(on day: Date, calendar: Calendar) -> Bool {
        if let span = listedSpan {
            return Store.overlapsDay(start: span.start, end: span.end, day: day, calendar: calendar)
        }
        return calendar.isDate(arrivalDate, inSameDayAs: day)
    }
}

/// 일정의 시각 기준. `.arrival`은 도착 시각이 고정값(출발 시각을 역산), `.departure`는 출발 시각이
/// 고정값(도착 시각을 순산) — 예: 퇴근/복귀처럼 "이 시각에 출발"이 우선인 경우.
enum ScheduleAnchor: String, Codable {
    case arrival, departure
}

// MARK: - 일정 판단 로직(순수 함수)

/// 저장·네트워크 없이 **판단만** 하는 로직 모음.
/// Store 안에 두면 알림·파일·캘린더에 얽혀 따로 검증하기 어려워서, 입력만 받아 결과를 내는
/// 형태로 떼어 놓았다(Store의 같은 이름 메서드가 이걸 호출한다).
enum ScheduleLogic {

    /// 어떤 시간대 앞뒤로 사용자가 있을/가야 할 장소를 기존 일정에서 추정한다.
    /// 활동 블록(그 장소에 머무는 시간)을 먼저 보고, 없으면 이동 일정의 목적지를 본다.
    static func surroundingPlaces(start: Date,
                                  end: Date,
                                  activities: [ActivityBlock],
                                  events: [ScheduledEvent],
                                  home: Place?)
    -> (before: (place: Place, label: String)?, after: (place: Place, label: String)?) {
        var before: (Place, String)?
        if let a = activities.filter({ $0.startDate <= start && $0.location != nil })
            .max(by: { $0.startDate < $1.startDate }), let p = a.location {
            before = (p, a.title)
        } else if let e = events.filter({ $0.arrivalDate <= start })
            .max(by: { $0.arrivalDate < $1.arrivalDate }) {
            before = (e.destination, e.title)
        } else if let home {
            before = (home, "Home")
        }

        var after: (Place, String)?
        if let a = activities.filter({ $0.startDate >= end && $0.location != nil })
            .min(by: { $0.startDate < $1.startDate }), let p = a.location {
            after = (p, a.title)
        } else if let e = events.filter({ $0.arrivalDate >= end })
            .min(by: { $0.arrivalDate < $1.arrivalDate }) {
            after = (e.destination, e.title)
        } else if let home {
            after = (home, "Home")
        }
        return (before, after)
    }

    // MARK: 시간표 겹침 배치(t17-c C1 — ContentView.positionedBlocks에서 옮김)

    /// 겹침 배치의 입력 항목 — 뷰 레코드가 아니라 (id, 자정 기준 분)쌍만 안다.
    /// 레코드(ScheduledEvent·ActivityBlock)를 받으면 묶음 키를 스스로 만들고 싶어지므로
    /// (AC-015 (8)) id는 String으로만 흐른다. `groupKey`도 호출자가 주입한다(같은 묶음원에
    /// 같은 문자열) — 키를 아는 것은 조회(packingGroups)지 이 함수가 아니다.
    struct LayoutItem {
        let id: String
        let start: CGFloat        // 자정 기준 분 — span(for:on:)이 이미 잘라·부풀린 값
        let end: CGFloat
        let groupKey: String?

        init(id: String, start: CGFloat, end: CGFloat, groupKey: String? = nil) {
            self.id = id; self.start = start; self.end = end; self.groupKey = groupKey
        }
    }

    /// 칸 함수의 결과 — 항목의 가로 범위 [lo, hi](0~1). 렌더 프레임과 히트테스트가 **같은 값**을
    /// 읽는 계약의 단일 출처이다(AC-016): 점 환산(points)도 여기 있으므로 뷰는 이 범위를 점으로
    /// 받아 쓰기만 한다. `columns`는 바깥 칸 수로, 칸 경계마다 들어가는 간격을 계산하는 데 쓰인다.
    struct SlotRange {
        let id: String
        let lo: CGFloat
        let hi: CGFloat
        let columns: Int

        /// [lo, hi]를 실제 점 위치·폭으로 바꾼다. 칸 경계(1/columns 간격)마다 `gap`pt를 빼고,
        /// 묶음 안쪽의 나눔에는 간격을 넣지 않는다 — 간격은 서로 다른 묶음·블록 사이에만 필요하다.
        /// 렌더(columnFrame)와 히트테스트(block(atX:))가 같은 호출로 같은 사각형을 얻는다:
        /// 예전엔 렌더만 간격을 빼 히트가 최대 3pt 어긋났다(F9).
        /// 간격 자체는 어느 블록에도 속하지 않는다(죽은 띠) — 그래서 히트는 이 사각형 그대로 본다.
        func points(in total: CGFloat, gap: CGFloat) -> (x: CGFloat, width: CGFloat) {
            guard columns > 1, hi > lo else { return (lo * total, (hi - lo) * total) }
            let usable = total - gap * CGFloat(columns - 1)
            let boundariesBefore = Int((lo * CGFloat(columns)).rounded(.down))
            let x = lo * usable + CGFloat(boundariesBefore) * gap
            return (x, (hi - lo) * usable)
        }
    }

    /// 겹침 배치의 결과 — 항목별 (열 번호, 무리의 열 수).
    struct LayoutSlot {
        let id: String
        let column: Int           // 0부터
        let columns: Int
    }

    /// 하루치 블록을 훑어 겹치는 것끼리 열을 나눈다.
    ///
    /// 시간이 겹치는 블록들을 하나의 "무리"로 묶고, 무리 안에서는 먼저 시작한 것부터
    /// **비어 있는 첫 열**에 넣는다. 무리의 열 수만큼 가로를 나눠 쓰므로, 두 개가 겹치면
    /// 반씩, 세 개면 1/3씩 차지한다. 겹치지 않는 블록은 전처럼 가로 전체를 쓴다.
    /// 뷰가 이 계산을 따로 들고 있으면 렌더와 히트테스트가 어긋나므로(AC-016) 순수 함수로
    /// 뺐다 — 본문은 `ContentView.positionedBlocks`에서 글자 그대로 옮겼다(동작 불변).
    /// 정렬의 마지막 동률(시작·끝이 모두 같은 두 항목)만 id로 갈랐다 — 안정 정렬을 문서가
    /// 보장하지 않아 입력 순서가 새면 출력이 흔들리는 것을 끊는다(AC-017 (7)). 같은 시각의
    /// 둘이 열 0·1을 맞바꿈할 뿐 겉보기 배치는 같다.
    static func overlapColumns(_ input: [LayoutItem]) -> [LayoutSlot] {
        var items = input
        items.sort {
            $0.start == $1.start
                ? ($0.end == $1.end ? $0.id < $1.id : $0.end < $1.end)
                : $0.start < $1.start
        }

        var out: [LayoutSlot] = []
        var cluster: [(item: LayoutItem, column: Int)] = []
        var columnEnds: [CGFloat] = []          // 열별로 현재까지 차 있는 끝 시각

        func flush() {
            let columns = max(1, columnEnds.count)
            for entry in cluster {
                out.append(LayoutSlot(id: entry.item.id, column: entry.column, columns: columns))
            }
            cluster.removeAll(); columnEnds.removeAll()
        }

        for item in items {
            // 지금까지의 무리와 전혀 겹치지 않으면(모든 열이 이미 끝났으면) 새 무리를 시작한다.
            if !columnEnds.isEmpty, columnEnds.allSatisfy({ $0 <= item.start }) { flush() }
            // 비어 있는 첫 열을 찾고, 없으면 열을 하나 늘린다.
            if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
                columnEnds[free] = item.end
                cluster.append((item, free))
            } else {
                columnEnds.append(item.end)
                cluster.append((item, columnEnds.count - 1))
            }
        }
        flush()
        return out
    }

    /// 묶음을 아는 배치(design §6.2 안 A) — 같은 groupKey의 구성원을 한 칸으로 묶되, 묶음 안
    /// 겹침은 안쪽 배치로 나눈다. 세 단계: ① 안쪽 배치(구성원끼리 overlapColumns) ② 바깥 배치
    /// (낱개 + 묶음 항목[구성원 start 최솟값, end 최댯값]을 함께 overlapColumns) ③ 칸 합성
    /// `lo = 바깥칸/바깥칸수 + (1/바깥칸수) × 안쪽칸/안쪽칸수`, `hi = lo + (1/바깥칸수)/안쪽칸수`.
    /// 이 [lo, hi]를 내는 곳은 이 함수 하나뿐이다(칸 산술의 단일 출처, AC-016) — 뷰는
    /// `SlotRange.points`로 점을 얻기만 한다.
    ///
    /// 묶음에 그날 목록에서 구성원이 하나뿐이면(다른 구성원이 다른 날 — 자정 넘김 — 이거나
    /// 활동 없는 매달린 링크) 낱개로 본다. 묶음 키가 없는 입력에서는 바깥 배치가 곧 전부라
    /// 결과가 `overlapColumns`의 (칸/칸수)와 정확히 같다 — C1 특성화(AH-015-01/02·AH-017-01~07)가
    /// 회귀선이 되는 근거다.
    ///
    /// @MX:NOTE 안쪽 배치가 필요한 이유(plan §7 F10): 묶음 구성원이 서로 겹치는 경우가 셋이다 —
    /// 활동이 최소 높이(20분)로 부풀고 그 실제 끝에서 출발하는 오는 편이 부푼 블록과 겹침 ·
    /// 이동시간 계산 실패 블록이 앵커 시각에서 아래로 자라 가는 편이 활동 시작 위로 겹침 ·
    /// 오는 편을 활동 안쪽으로 끌어 들인 구간. 묶음을 한 칸에 그냥 채우면 이 셋이 한 칸 안에서
    /// 서로를 덮는다.
    /// @MX:ANCHOR 렌더 프레임·히트테스트·드라이버가 같은 [lo, hi]를 읽는다는 계약 — 이 함수의
    /// 출력을 다른 산술로 다시 가공하는 호출자를 만들지 않는다.
    static func overlapSlots(_ input: [LayoutItem]) -> [SlotRange] {
        var members: [String: [LayoutItem]] = [:]
        for item in input {
            guard let key = item.groupKey else { continue }
            members[key, default: []].append(item)
        }

        // ① 안쪽 배치 + 묶음 항목 조립(구성원이 둘 이상인 묶음만).
        var inner: [String: (column: Int, columns: Int)] = [:]
        var grouped: [LayoutItem] = []
        for (key, list) in members where list.count > 1 {
            for slot in overlapColumns(list) { inner[slot.id] = (slot.column, slot.columns) }
            grouped.append(LayoutItem(id: "group:\(key)",
                                      start: list.map { $0.start }.min() ?? 0,
                                      end: list.map { $0.end }.max() ?? 0))
        }
        let groupedKeys = Set(members.filter { $0.value.count > 1 }.keys)

        // ② 바깥 배치 — 낱개(키 없음·구성원 하나뿐인 묶음 포함)와 묶음 항목을 함께.
        let outerInput = input.filter { $0.groupKey.map { !groupedKeys.contains($0) } ?? true } + grouped
        var outer: [String: (column: Int, columns: Int)] = [:]
        for slot in overlapColumns(outerInput) { outer[slot.id] = (slot.column, slot.columns) }

        // ③ 칸 합성. 바깥 배치에서 묶음원은 묶음 항목("group:키") 칸을, 낱개(구성원 하나뿐인
        // 묶음 포함)는 제 칸을 읽는다.
        var out: [SlotRange] = []
        for item in input {
            let isGrouped = item.groupKey.map { groupedKeys.contains($0) } ?? false
            let outerKey = isGrouped ? "group:\(item.groupKey!)" : item.id
            guard let slot = outer[outerKey], !isGrouped || inner[item.id] != nil else { continue }
            let outerCount = max(1, slot.columns)
            let lo: CGFloat, hi: CGFloat
            if isGrouped, let innerSlot = inner[item.id] {
                let innerCount = max(1, innerSlot.columns)
                lo = CGFloat(slot.column) / CGFloat(outerCount)
                    + (1 / CGFloat(outerCount)) * CGFloat(innerSlot.column) / CGFloat(innerCount)
                hi = lo + (1 / CGFloat(outerCount)) / CGFloat(innerCount)
            } else {
                lo = CGFloat(slot.column) / CGFloat(outerCount)
                hi = lo + 1 / CGFloat(outerCount)
            }
            out.append(SlotRange(id: item.id, lo: lo, hi: hi, columns: outerCount))
        }
        return out
    }

    /// 일정을 지울 때 **같이 지워야 할 식사 기록**의 id.
    /// 아직 오지 않은 식사만 대상이다 — 이미 지난 식사는 "실제로 먹은 기록"이라 남긴다.
    static func mealsToRemove(meals: [MealLog],
                              eventIDs: Set<UUID>,
                              activityIDs: Set<UUID>,
                              now: Date) -> Set<UUID> {
        Set(meals.filter { meal in
            let linked = (meal.scheduledEventId.map { eventIDs.contains($0) } ?? false)
                || (meal.activityId.map { activityIDs.contains($0) } ?? false)
            guard linked else { return false }
            // 계획 시각을 모르면 기록 시각으로 판단한다(수동 기록은 plannedAt이 없다).
            return (meal.plannedAt ?? meal.loggedAt) > now
        }.map { $0.id })
    }
}

// MARK: - 반복 규칙 · 공휴일

/// 반복 일정이 실제로 어느 날짜에 생기는지 정하는 규칙.
/// 예전엔 "요일 목록"만 있어서 매주 반복밖에 못 했다 — 격주·월 단위·공휴일 제외를 여기로 모았고,
/// 이제 N일·N개월·N년·한국 음력·날짜 목록까지 한 타입이 표현한다(SPEC-UIKIT-019 REQ-002·008).
/// 필드를 넓혔을 뿐 옛 init 호출(`RecurrenceRule(weekdays:everyNWeeks:…)`)은 그대로 컴파일된다 —
/// 새 필드는 모두 기본값이 있고, 기본 `unit`이 옛 동작(요일 집합)이다.
struct RecurrenceRule: Codable {
    /// 규칙의 종류. `weekly`가 옛 동작이고 나머지는 019에서 더했다.
    enum Unit: String, Codable, Equatable { case weekly, daily, monthly, yearly, lunar, dateList }

    /// 반복 요일(1=일 … 7=토, `Calendar.component(.weekday:)` 기준). 주 단위 반복과
    /// "매월 n번째 요일"(`unit == .monthly`)이 읽는다.
    var weekdays: Set<Int> = []
    /// 1=매주, 2=격주, 3=3주마다… (`unit == .weekly`만 읽는다 — 옛 필드를 그대로 둬 호출처를 안 깨뜨린다)
    var everyNWeeks: Int = 1
    /// 월 단위 반복: 그 달의 몇 번째 해당 요일인지(1~4, -1=마지막). nil이면 주 단위 반복.
    var nthWeekOfMonth: Int?
    /// 한국 공휴일은 건너뛴다(날짜 목록은 사용자가 고른 날이라 건너뛰지 않는다).
    var skipHolidays: Bool = false

    var unit: Unit = .weekly
    /// N일마다(`daily`)·N개월마다(`monthly`)·N년마다(`yearly`)의 N. 1=매일·매월·매년.
    var interval: Int = 1
    /// 매월 반복의 날짜(1~31). 여러 개면 한 반복이다(예 5일과 20일). 그 달에 없는 날은 회차가 없다.
    var monthDays: [Int] = []
    /// 매월 반복의 "마지막 날".
    var lastDayOfMonth: Bool = false
    /// 매년(양력)·음력 반복의 월·일. 음력이면 음력 월·일이다.
    var month: Int?
    var day: Int?
    /// 음력 반복의 윤달 여부(`unit == .lunar`).
    var isLeapMonth: Bool = false
    /// 날짜 목록 반복의 날짜들 — 마지막 날이 곧 종료 날짜다.
    var explicitDates: [Date] = []

    // MARK: 전개

    /// 드라이버 가시 계수기: 전개 함수 `dates(from:through:…)`가 불린 횟수. 앱 논리는 읽지 않는다.
    /// 먼 종료 날짜가 전개 **전에** 회차 수 셈에서 걸러지는지(REQ-007) 드라이버가 이 값으로 잰다.
    static var drvExpansionCount = 0

    /// Driver-visible counter: loop iterations the expansion core walked, one per iteration in every branch. Application
    /// logic never reads it; a test reads it to show the walk does not grow with the distance to the window.
    static var drvWalkSteps = 0

    /// 간격(N일·N주·N개월·N년마다의 N)의 상한. 뜻이 있는 간격(천 일·천 주·천 달·천 해)보다 넉넉히 크고, 전개 코어의
    /// `step * n`·`year += n`이 아래 시야(horizonYears) 안에서 넘치지 않는 값이다 — 모델이 Int.max 같은 값을 실어 오면
    /// 정수 넘침으로 앱이 그 자리에서 죽는다(019 안전성 렌즈 m-1). 읽기 함수와 전개 코어가 같은 상수로 묶는다.
    static let maxInterval = 1000

    /// 전개 코어가 걷는 시야(해) — 시작일 + 이만큼을 넘는 종료 날짜는 걷지 않는다. 9999년 같은 먼 종료 날짜에서 맞는 날이
    /// 드문 규칙(음력 윤달·없는 2월 30일·큰 간격)은 회차 상한(182)에 닿기 전에 수천~수백만 번을 돌며 메인 액터를 수 초 막았다
    /// (019 안전성 렌즈 M-2). 정상 규칙은 182회에서 훨씬 먼저 걸리므로 이 시야에 닿지 않는다 — 셈은 시야 밖 종료를 바로
    /// "상한 초과"로 돌려주고(occurrenceCount), 전개·첫 날 찾기도 끝을 이 시야로 묶는다(generate). SPEC에 없는 방어다.
    /// 이 안에서는 어떤 종류도 오래 걷지 않는다: 주 단위 일별 ≤ 73,050회, 월 ≤ 2,400달, 해·음력 ≤ 200해.
    static let horizonYears = 200

    /// 시작일에서 본 시야의 끝(그날 포함). 셈·전개가 같은 끝을 본다(계약 5).
    private static func horizonEnd(from startDay: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .year, value: horizonYears, to: startDay)
    }

    /// "OS 버전 → 음력 달력" 순수 함수. `.dangi`(한국 음력)는 iOS·macOS 26부터 있어서 그 아래는 같은
    /// 삭망월 체계인 `.chinese`로 대신한다. OS 분기를 숫자 인자로 떼어 둔 이유: 호출 시점의 OS에 매이면
    /// 드라이버(macOS 26)가 `.chinese` 길을 한 번도 못 돌려 "늘 `.dangi`"인 구현도 초록이 된다.
    /// 가드의 `macOS`를 빼면 맥 타깃(최소 14.0)이 깨진다 — 맥은 지금 빌드하지 않지만 코드는 보존한다.
    static func lunarIdentifier(osMajorVersion: Int) -> Calendar.Identifier {
        if osMajorVersion >= 26, #available(iOS 26, macOS 26, *) { return .dangi }
        return .chinese
    }

    /// 음력 전개의 기본 달력 — 지금 OS의 분기.
    static var defaultLunarIdentifier: Calendar.Identifier {
        lunarIdentifier(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// `startDate`부터 `endDate`(그날 포함)까지 이 규칙에 맞는 날짜를 만드는 **단 하나의 전개 함수**(계약 5).
    /// 없는 날(매월 29~31일이 없는 달·평년 2월 29일·음력 윤달이 없는 해·음력 30일이 없는 달)은 회차를
    /// 만들지 않는다 — 다른 날로 대신하지도, 알리지도 않는다(§0.2). 지난 회차를 거르는 일은 저장 쪽 몫이다.
    func dates(from startDate: Date, through endDate: Date, calendar: Calendar = .current,
               lunarCalendar: Calendar.Identifier = RecurrenceRule.defaultLunarIdentifier) -> [Date] {
        Self.drvExpansionCount += 1
        return generate(from: startDate, through: endDate, calendar: calendar,
                        lunarCalendar: lunarCalendar, stopAfter: nil)
    }

    /// The dates of the rule that fall on or after the day of `windowStart`, up to `endDate`. The phase (the biweekly
    /// week base, the month and year steps) comes from `startDate`, so the answer equals `dates(from:through:)`
    /// filtered to the window; `windowStart` only moves where each branch begins walking. Counted by
    /// `drvExpansionCount` like the unwindowed call.
    func dates(from startDate: Date, through endDate: Date, startingAt windowStart: Date, calendar: Calendar = .current,
               lunarCalendar: Calendar.Identifier = RecurrenceRule.defaultLunarIdentifier) -> [Date] {
        Self.drvExpansionCount += 1
        return generate(from: startDate, through: endDate, calendar: calendar,
                        lunarCalendar: lunarCalendar, stopAfter: nil, windowStart: windowStart)
    }

    /// Whether an end date is inside the horizon the expansion core walks, counted from the start day.
    static func withinHorizon(_ end: Date, from start: Date, calendar: Calendar = .current) -> Bool {
        guard let horizon = horizonEnd(from: calendar.startOfDay(for: start), calendar: calendar) else { return false }
        return calendar.startOfDay(for: end) <= horizon
    }

    /// 종료 날짜까지의 회차 수. 센 개수가 `limit`을 넘는 순간 멈추므로 반환값은 많아야 `limit + 1`이다.
    /// 전개 함수를 거치지 않고 같은 생성 코어(`generate`)를 쓴다 — 코어가 하나라 센 값과 만들어질 값이
    /// 어긋나지 않고(계약 5), 9999년 같은 먼 종료 날짜도 `limit + 1`개를 모으면 끝나 메인 액터를 막지 않는다.
    /// 지난 회차도 센다(상한은 규칙이 가리키는 길이이지 오늘 이후의 길이가 아니다).
    func occurrenceCount(from startDate: Date, through endDate: Date, limit: Int, calendar: Calendar = .current,
                         lunarCalendar: Calendar.Identifier = RecurrenceRule.defaultLunarIdentifier) -> Int {
        // 시야 밖 종료는 걷지 않고 바로 "상한 초과"다(horizonYears 주석) — 세 호출처(카드 안내·실행부·Store 가드)가 이미
        // 초과로 다룬다. 맞는 날이 아예 없는 규칙도 여기서는 초과로 읽히지만, 그런 종료 날짜는 어차피 쓸 수 없는 값이다.
        if let horizon = Self.horizonEnd(from: calendar.startOfDay(for: startDate), calendar: calendar),
           calendar.startOfDay(for: endDate) > horizon {
            return max(0, limit) + 1
        }
        return generate(from: startDate, through: endDate, calendar: calendar, lunarCalendar: lunarCalendar,
                 stopAfter: max(0, limit)).count
    }

    /// 규칙 날짜 가운데 `accept`를 처음 만족하는 날 — 찾는 순간 멈춘다. 카드의 첫 회차 가늠이 쓴다:
    /// 전개 함수로 목록을 다 만든 뒤 고르면 먼 종료 날짜에서 목록 전체를 짓게 되고, 같은 코어를 쓰지 않으면
    /// 카드가 보인 첫 날과 만들어질 첫 날이 갈라진다(계약 5).
    func firstDate(from startDate: Date, through endDate: Date, calendar: Calendar = .current,
                   lunarCalendar: Calendar.Identifier = RecurrenceRule.defaultLunarIdentifier,
                   where accept: @escaping (Date) -> Bool) -> Date? {
        generate(from: startDate, through: endDate, calendar: calendar, lunarCalendar: lunarCalendar,
                 stopAfter: 0, accept: accept).first
    }

    /// 전개와 셈이 함께 쓰는 생성 코어. `stopAfter`가 있으면 그 개수를 넘겨 모은 순간 돌려준다.
    /// `accept`가 있으면 거기 맞지 않는 날은 모으지 않는다(세지도 않는다).
    private func generate(from startDate: Date, through endDate: Date, calendar: Calendar,
                          lunarCalendar: Calendar.Identifier, stopAfter limit: Int?,
                          accept: ((Date) -> Bool)? = nil, windowStart: Date? = nil) -> [Date] {
        let startDay = calendar.startOfDay(for: startDate)
        // 끝은 시야(horizonYears)로 묶는다 — 셈이 시야 밖을 먼저 거르지만 전개·첫 날 찾기도 같은 끝을 봐야 어떤 호출도 오래 걷지 않는다.
        let endDay = min(calendar.startOfDay(for: endDate), Self.horizonEnd(from: startDay, calendar: calendar) ?? startDay)
        guard startDay <= endDay else { return [] }
        let startTime = calendar.dateComponents([.hour, .minute, .second], from: startDate)
        var out: [Date] = []
        // First day of the window, when there is one; a branch begins walking near it and `push` drops anything before it.
        let windowDay = windowStart.map { calendar.startOfDay(for: $0) }

        /// 날짜 하나를 모은다. 거짓을 돌려주면 더 모을 필요가 없다는 뜻이다.
        func push(_ date: Date) -> Bool {
            if let windowDay, calendar.startOfDay(for: date) < windowDay { return true }
            if skipHolidays, unit != .dateList, KoreanHolidays.isHoliday(date, calendar: calendar) { return true }
            if let accept, !accept(date) { return true }
            out.append(date)
            if let limit, out.count > limit { return false }
            return true
        }
        /// 시작일의 시각을 입힌다 — 주 단위 전개가 예전부터 시작 시각을 달고 나오던 것과 맞춘다.
        func atStartTime(_ dayStart: Date) -> Date {
            calendar.date(bySettingHour: startTime.hour ?? 0, minute: startTime.minute ?? 0,
                          second: startTime.second ?? 0, of: dayStart) ?? dayStart
        }
        func inRange(_ dayStart: Date) -> Bool { dayStart >= startDay && dayStart <= endDay }

        switch unit {
        case .weekly:
            guard !weekdays.isEmpty else { return [] }
            let n = min(max(1, everyNWeeks), Self.maxInterval)
            // 격주 간격은 "주의 시작(일요일)" 기준으로 센다 — 시작일이 주 중간이어도 간격이 어긋나지 않게.
            let baseWeek = calendar.dateInterval(of: .weekOfYear, for: startDate)?.start ?? startDate
            var offset = 0
            if let windowDay {
                offset = max(0, calendar.dateComponents([.day], from: startDay, to: windowDay).day ?? 0)
            }
            while let day = calendar.date(byAdding: .day, value: offset, to: startDate),
                  calendar.startOfDay(for: day) <= endDay {
                Self.drvWalkSteps += 1
                offset += 1
                guard weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
                if n > 1 {
                    let weekStart = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
                    let weeksApart = (calendar.dateComponents([.day], from: baseWeek, to: weekStart).day ?? 0) / 7
                    guard weeksApart % n == 0 else { continue }
                }
                if let nth = nthWeekOfMonth, !Self.isNthWeekday(day, nth: nth, calendar: calendar) { continue }
                if !push(day) { return out }
            }

        case .daily:
            // 간격을 상한으로 묶어 아래 `step * n`·`year += n`이 시야 안에서 넘치지 않게 한다(maxInterval 주석).
            let n = min(max(1, interval), Self.maxInterval)
            var step = 0
            if let windowDay {
                step = max(0, (calendar.dateComponents([.day], from: startDay, to: windowDay).day ?? 0) / n)
            }
            while let day = calendar.date(byAdding: .day, value: step * n, to: startDate),
                  calendar.startOfDay(for: day) <= endDay {
                Self.drvWalkSteps += 1
                step += 1
                if !push(day) { return out }
            }

        case .monthly:
            // 고를 날이 하나도 없는 규칙(날짜·말일·몇째 주 요일 모두 없음)은 달을 훑어도 빈손이다 — 끝 날짜가
            // 먼 첫 회차 가늠(firstDate)이 수천 달을 헛돌지 않게 먼저 끊는다. 결과는 훑었을 때와 같다(빈 목록).
            guard !monthDays.isEmpty || lastDayOfMonth || (nthWeekOfMonth != nil && !weekdays.isEmpty) else { return [] }
            // 간격을 상한으로 묶어 아래 `step * n`·`year += n`이 시야 안에서 넘치지 않게 한다(maxInterval 주석).
            let n = min(max(1, interval), Self.maxInterval)
            // 시작이 든 달이 첫째 달이다 — "2개월마다"는 거기서부터 두 달 간격.
            guard let firstMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: startDay)) else { return [] }
            var step = 0
            if let windowDay,
               let windowMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: windowDay)) {
                step = max(0, (calendar.dateComponents([.month], from: firstMonth, to: windowMonth).month ?? 0) / n)
            }
            while let monthStart = calendar.date(byAdding: .month, value: step * n, to: firstMonth), monthStart <= endDay {
                Self.drvWalkSteps += 1
                step += 1
                guard let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else { continue }
                var picked = Set<Int>()
                // 그 달에 없는 날(30일 달의 31일 등)은 범위 검사에서 빠져 회차가 없다 — 말일로 당기지 않는다.
                for d in monthDays where dayRange.contains(d) { picked.insert(d) }
                if lastDayOfMonth { picked.insert(dayRange.upperBound - 1) }
                if let nth = nthWeekOfMonth, !weekdays.isEmpty {
                    for d in dayRange {
                        guard let date = calendar.date(byAdding: .day, value: d - 1, to: monthStart),
                              weekdays.contains(calendar.component(.weekday, from: date)),
                              Self.isNthWeekday(date, nth: nth, calendar: calendar) else { continue }
                        picked.insert(d)
                    }
                }
                for d in picked.sorted() {
                    guard let date = calendar.date(byAdding: .day, value: d - 1, to: monthStart) else { continue }
                    let dayStart = calendar.startOfDay(for: date)
                    guard inRange(dayStart) else { continue }
                    if !push(atStartTime(dayStart)) { return out }
                }
            }

        case .yearly:
            guard let month, let day else { return [] }
            // 간격을 상한으로 묶어 아래 `step * n`·`year += n`이 시야 안에서 넘치지 않게 한다(maxInterval 주석).
            let n = min(max(1, interval), Self.maxInterval)
            let endYear = calendar.component(.year, from: endDay)
            let startYear = calendar.component(.year, from: startDay)
            var year = startYear
            if let windowDay {
                let windowYear = calendar.component(.year, from: windowDay)
                if windowYear > startYear { year = startYear + ((windowYear - startYear) / n) * n }
            }
            while year <= endYear {
                Self.drvWalkSteps += 1
                defer { year += n }
                // 평년의 2월 29일처럼 없는 날은 date(from:)이 다음 날로 굴려 버리므로 월·일이 그대로인지 되짚는다.
                guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { continue }
                let back = calendar.dateComponents([.month, .day], from: date)
                guard back.month == month, back.day == day else { continue }
                let dayStart = calendar.startOfDay(for: date)
                guard inRange(dayStart) else { continue }
                if !push(atStartTime(dayStart)) { return out }
            }

        case .lunar:
            guard let month, let day else { return [] }
            var lunar = Calendar(identifier: lunarCalendar)
            lunar.timeZone = calendar.timeZone
            let endYear = calendar.component(.year, from: endDay)
            // 음력 해의 12월은 이듬해 양력 1~2월에 걸리므로 시작 해보다 한 해 앞에서부터 훑는다.
            var year = calendar.component(.year, from: startDay) - 1
            if let windowDay { year = max(year, calendar.component(.year, from: windowDay) - 1) }
            while year <= endYear {
                Self.drvWalkSteps += 1
                defer { year += 1 }
                // 3월 1일은 어느 해에서든 음력 설(1월 21일~2월 20일) 뒤라 그 양력 해와 같은 음력 해를 가리킨다.
                guard let ref = calendar.date(from: DateComponents(year: year, month: 3, day: 1)) else { continue }
                var comps = lunar.dateComponents([.era, .year], from: ref)
                comps.month = month
                comps.day = day
                comps.isLeapMonth = isLeapMonth
                guard let date = lunar.date(from: comps) else { continue }
                // 왕복 검증: 없는 윤달·없는 30일은 date(from:)이 평달이나 다음 달로 굴려 낸다. 같은 달력으로
                // 되돌려 요청한 월·일·윤달이 그대로일 때만 받아들이고, 아니면 그 해는 회차가 없다.
                let back = lunar.dateComponents([.month, .day, .isLeapMonth], from: date)
                guard back.month == month, back.day == day, (back.isLeapMonth ?? false) == isLeapMonth else { continue }
                let dayStart = calendar.startOfDay(for: date)
                guard inRange(dayStart) else { continue }
                if !push(atStartTime(dayStart)) { return out }
            }

        case .dateList:
            var seen = Set<Date>()
            for date in explicitDates.sorted() {
                let dayStart = calendar.startOfDay(for: date)
                guard inRange(dayStart), seen.insert(dayStart).inserted else { continue }
                if !push(atStartTime(dayStart)) { return out }
            }
        }
        return out
    }

    // MARK: 인자 → 규칙

    /// create_activity의 반복 인자 이름. 선언(AIAssistant.toolsJSON)과 이 읽기가 같은 상수를 쓴다 — 정화는 선언에 없는
    /// 키를 말없이 버리므로(018 REQ-011) 두 곳의 글자가 한 자라도 어긋나면 그 인자는 늘 "없음"으로 읽힌다.
    enum Arg {
        static let unit = "repeat_unit"
        static let interval = "repeat_interval"
        static let monthDays = "month_days"
        static let month = "repeat_month"
        static let day = "repeat_day"
        static let leapMonth = "lunar_leap_month"
        static let dates = "dates"
        static let weekdays = "weekdays"
        static let everyNWeeks = "every_n_weeks"
        static let nthWeek = "nth_week_of_month"
        static let skipHolidays = "skip_holidays"
        /// 위 반복 인자 전부 — 카드 확정이 보류 호출의 원래 반복 인자를 지우고 '반복' 줄의 결과로 갈아 끼울 때 쓴다
        /// (019 L-27). 하나라도 빠지면 그 인자의 원래 값이 해석 결과와 섞여 실행부에 간다.
        static let all: Set<String> = [unit, interval, monthDays, month, day, leapMonth, dates,
                                       weekdays, everyNWeeks, nthWeek, skipHolidays]
    }

    /// `repeat_unit`의 값 ↔ 규칙 종류. 선언의 enum이 이 순서 그대로 나간다(값 목록이 두 벌이 되지 않게).
    /// "none"은 한 번짜리다 — 이 모델은 선언된 선택 인자를 비우지 못하고 채우므로 한 번짜리에도 실어 올 값이 있어야 한다.
    static let unitArguments: [(name: String, unit: Unit?)] = [
        ("none", nil), ("day", .daily), ("week", .weekly), ("month", .monthly),
        ("year", .yearly), ("lunar", .lunar), ("dates", .dateList),
    ]

    /// create_activity 인자에서 반복 규칙을 읽는 **단 하나의 함수**(계약 5) — 반복인지의 판정, 카드의 첫 회차 가늠,
    /// 실행부의 규칙 짓기가 모두 이것을 지난다. 나중에 수동 카드의 해석 결과도 같은 인자 꼴로 와서 같은 함수를 지난다.
    /// 한 번짜리면 nil이다: `repeat_unit`이 "none"(또는 없음)이고 요일도 없을 때. 단위 이름 없이 요일만 실린
    /// 호출은 옛 판정 그대로 매주 반복이다 — 018 때의 호출·히스토리 에코가 그 모양으로 온다.
    /// 각 인자의 "없음" 값(0·빈 배열·false)은 규칙 기본값과 같은 뜻으로 읽힌다 — 값이 범위 밖이면 버린다.
    static func from(arguments args: [String: Any]) -> RecurrenceRule? {
        let rawWeekdays = args[Arg.weekdays] as? [String] ?? []
        let name = (args[Arg.unit] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
        let unit: Unit
        if let named = unitArguments.first(where: { $0.name == name })?.unit {
            unit = named
        } else if !rawWeekdays.isEmpty {
            unit = .weekly
        } else {
            return nil
        }
        var rule = RecurrenceRule()
        rule.unit = unit
        rule.weekdays = Set(rawWeekdays.compactMap(weekday(symbol:)))
        rule.everyNWeeks = everyNWeeksArgument(args)
        // 1~4·-1 밖의 몇째 주는 규칙에 싣지 않는다 — 실행부 가드(recurringArgumentIssue)가 원값을 따로 읽어 되돌려
        // 보내고, 카드의 첫 회차 가늠이 맞을 수 없는 조건으로 끝없이 훑지 않게 한다.
        if let nth = nthWeekArgument(args), nth == -1 || (1...4).contains(nth) { rule.nthWeekOfMonth = nth }
        rule.skipHolidays = (args[Arg.skipHolidays] as? Bool) ?? false
        rule.interval = min(max(1, intArgument(args[Arg.interval]) ?? 1), maxInterval)
        let days = (args[Arg.monthDays] as? [Any] ?? []).compactMap { intArgument($0) }
        rule.monthDays = Array(Set(days.filter { (1...31).contains($0) })).sorted()
        rule.lastDayOfMonth = days.contains(-1)
        if let m = intArgument(args[Arg.month]), (1...12).contains(m) { rule.month = m }
        if let d = intArgument(args[Arg.day]), (1...31).contains(d) { rule.day = d }
        rule.isLeapMonth = unit == .lunar && (args[Arg.leapMonth] as? Bool) == true
        rule.explicitDates = (args[Arg.dates] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(argumentDay) }
        return rule
    }

    /// 인자의 날짜 글("2026-07-06" → 그날 0시, 지금 시간대)을 읽는 단 한 곳 — 반복의 날짜 목록·종료 날짜와 다른 도구의
    /// 날짜 인자(AIAssistant.parseDay)가 같은 해석을 탄다(계약 5 — 두 벌이면 시간대·로캘 규칙이 한쪽만 늙는다).
    static func argumentDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// 반복 회차 하나의 시작에서 끝까지 날짜 거리(0 또는 1) — 끝이 시작 뒤 24시간 안일 때만이고, 아니면 nil.
    /// AI 실행부와 수동 저장이 같은 판정을 탄다(계약 5 — 두 곳에 적혀 있던 24시간 가드와 거리 셈을 모았다).
    static func occurrenceEndDayDistance(start: Date, end: Date, calendar: Calendar = .current) -> Int? {
        guard end > start, end.timeIntervalSince(start) <= 86400 else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                       to: calendar.startOfDay(for: end)).day ?? 0
    }

    /// 요일 기호(mon…sun) → `Calendar` 요일 번호(1=일 … 7=토). 선언의 요일 enum과 같은 글자다.
    private static let weekdaySymbols: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7
    ]
    static func weekday(symbol s: String) -> Int? { weekdaySymbols[s.lowercased()] }

    /// 정수 인자를 너그럽게 읽는다 — 백엔드가 숫자를 Int·Double·문자열 어느 쪽으로든 실어 온다.
    /// Double은 Int 범위 안의 유한한 값만 받는다 — 1e19·NaN·무한을 Int(d)로 바꾸면 앱이 그 자리에서 죽는다(019 안전성 렌즈
    /// m-1). 범위 안의 값은 예전처럼 소수점을 버린다(10.5 → 10). 문자열은 Int(s)가 범위 밖이면 nil이라 그대로다.
    static func intArgument(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double {
            guard d.isFinite, d >= -9.0e18, d <= 9.0e18 else { return nil }
            return Int(d)
        }
        if let s = any as? String { return Int(s) }
        return nil
    }

    /// `nth_week_of_month`를 읽는 **단 한 곳**(가드와 규칙이 같은 값을 보게 — 계약 5).
    ///
    /// 0은 오류가 아니라 "해당 없음"으로 읽는다. 이 모델은 선언된 선택 인자를 비워두지 못하고 전부
    /// 채워 보낸다 — 옛 반복 도구 호출에 점심 시각·복귀 시각이 빈 문자열로 같이 왔다. 문자열은
    /// 빈 값으로 "없음"을 말할 수 있지만 INTEGER에는 그 자리가 0뿐이다. 빈 문자열을 resolvedMode·
    /// resolveOriginAdoption이 조용히 흘려보내는 것과 같은 처리를 숫자 쪽에도 해준다.
    /// 툴 선언과 시스템 프롬프트에도 "매월이 아니면 0"이라고 적어 뒀다 — 앱만 알고 모델은 모르면,
    /// 되돌려 보낼 때 모델이 쓸 수 있는 탈출로가 없어 선언에 적힌 1~4·-1 중 하나를 다시 고른다.
    ///
    /// **인자마다 따로 판단한다 — 0을 일괄로 "없음" 처리하는 헬퍼로 합치지 말 것.**
    /// · `nth_week_of_month`는 0에 뜻이 없다("0번째 주"는 없다). 그래서 0은 모델의 "없음"으로만 읽힌다.
    /// · `buffer_minutes`·`notify_lead_minutes`의 0은 사용자가 실제로 할 수 있는 말이다
    ///   ("여유 없이", "출발 시각에 알림"). 여기까지 없앰 처리하면 진짜 요청을 버리고
    ///   기억해둔 기본값을 조용히 끼워 넣는다 — AIAssistant.recurringArgumentIssue 주석의 "값을 조용히
    ///   버리는 건 조용히 따르는 것만큼 나쁘다"가 정확히 그 경우다. 그 둘은 그대로 둔다.
    static func nthWeekArgument(_ args: [String: Any]) -> Int? {
        guard let nth = intArgument(args[Arg.nthWeek]), nth != 0 else { return nil }
        return nth
    }

    /// `every_n_weeks`를 읽는 **단 한 곳**(가드와 규칙이 같은 값을 보게 — 계약 5).
    /// 위와 달리 Int?가 아니라 Int다: 0도 없음도 "매주"라는 같은 뜻이라 호출부가 구분할 게 없다.
    /// 두 곳에 `max(1, ... ?? 1)`이 똑같이 적혀 있었다 — 지금은 값이 같지만 한쪽만 고쳐지면
    /// 되묻기 판단과 실제 생성이 서로 다른 주기를 보게 된다(렌더링·히트테스트가 어긋났던 그 모양).
    static func everyNWeeksArgument(_ args: [String: Any]) -> Int {
        // 상한은 전개 코어와 같은 maxInterval이다 — 되묻기 가드와 규칙이 같은 값을 본다.
        min(max(1, intArgument(args[Arg.everyNWeeks]) ?? 1), maxInterval)
    }

    /// 그 달의 n번째 같은 요일인지. `nth == -1`이면 "마지막".
    static func isNthWeekday(_ date: Date, nth: Int, calendar: Calendar = .current) -> Bool {
        if nth == -1 {
            guard let next = calendar.date(byAdding: .day, value: 7, to: date) else { return false }
            return calendar.component(.month, from: next) != calendar.component(.month, from: date)
        }
        return (calendar.component(.day, from: date) - 1) / 7 + 1 == nth
    }
}

/// 한국 공휴일 판정.
///
/// 음력 공휴일(설날·부처님오신날·추석)은 **표를 하드코딩하지 않고** Foundation의 음력 달력
/// (`.chinese` — 한국 음력과 같은 삭망월 체계)으로 계산한다. 해마다 표를 갱신할 필요가 없다.
///
/// 대체공휴일은 단순화했다: 대상 공휴일이 토·일이거나 다른 공휴일과 겹치면 다음 평일 하루를
/// 더한다. 신정·현충일은 대체공휴일 대상이 아니라 제외한다.
enum KoreanHolidays {
    /// 연도별 yyyyMMdd 키 집합 캐시(한 해치를 만들 때 음력 탐색으로 365일을 훑으므로 재사용).
    private static var cache: [Int: Set<Int>] = [:]

    static func isHoliday(_ date: Date, calendar: Calendar = .current) -> Bool {
        let year = calendar.component(.year, from: date)
        return keys(year: year, calendar: calendar).contains(dayKey(date, calendar))
    }

    /// 그 해 공휴일 목록(오름차순). 확인·표시용.
    static func dates(year: Int, calendar: Calendar = .current) -> [Date] {
        keys(year: year, calendar: calendar).sorted().compactMap {
            calendar.date(from: DateComponents(year: $0 / 10000, month: ($0 / 100) % 100, day: $0 % 100))
        }
    }

    private static func dayKey(_ date: Date, _ calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    private static func keys(year: Int, calendar: Calendar) -> Set<Int> {
        if let cached = cache[year] { return cached }
        var days: Set<Int> = []
        var substitutable: [Date] = []   // 대체공휴일 대상
        func add(_ d: Date?) { if let d { days.insert(dayKey(d, calendar)) } }
        func solar(_ m: Int, _ d: Int) -> Date? {
            calendar.date(from: DateComponents(year: year, month: m, day: d))
        }

        // 양력 고정 공휴일.
        for (m, d) in [(1, 1), (3, 1), (5, 5), (6, 6), (8, 15), (10, 3), (10, 9), (12, 25)] {
            let date = solar(m, d)
            add(date)
            // 신정(1/1)·현충일(6/6)은 대체공휴일 대상이 아니다.
            if let date, !(m == 1 && d == 1), !(m == 6 && d == 6) { substitutable.append(date) }
        }
        // 음력 공휴일. 설날·추석은 전날~다음날까지 사흘.
        if let seollal = lunar(year: year, month: 1, day: 1, calendar: calendar) {
            for off in -1...1 {
                let date = calendar.date(byAdding: .day, value: off, to: seollal)
                add(date); if let date { substitutable.append(date) }
            }
        }
        if let buddha = lunar(year: year, month: 4, day: 8, calendar: calendar) {
            add(buddha); substitutable.append(buddha)
        }
        if let chuseok = lunar(year: year, month: 8, day: 15, calendar: calendar) {
            for off in -1...1 {
                let date = calendar.date(byAdding: .day, value: off, to: chuseok)
                add(date); if let date { substitutable.append(date) }
            }
        }

        // 대체공휴일: 토·일이거나 이미 다른 공휴일과 겹치면 다음 평일 하루를 더한다.
        for date in substitutable.sorted() {
            let weekday = calendar.component(.weekday, from: date)
            let overlaps = substitutable.filter { dayKey($0, calendar) == dayKey(date, calendar) }.count > 1
            guard weekday == 1 || weekday == 7 || overlaps else { continue }
            var probe = date
            for _ in 0..<10 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: probe) else { break }
                probe = next
                let wd = calendar.component(.weekday, from: probe)
                if wd != 1, wd != 7, !days.contains(dayKey(probe, calendar)) {
                    days.insert(dayKey(probe, calendar)); break
                }
            }
        }

        cache[year] = days
        return days
    }

    /// 그 해 안에서 음력 (month, day)에 해당하는 양력 날짜(윤달 제외).
    private static func lunar(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        var lunarCal = Calendar(identifier: .chinese)
        lunarCal.timeZone = calendar.timeZone
        guard let jan1 = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
        for offset in 0..<366 {
            guard let d = calendar.date(byAdding: .day, value: offset, to: jan1) else { continue }
            guard calendar.component(.year, from: d) == year else { break }
            let c = lunarCal.dateComponents([.month, .day, .isLeapMonth], from: d)
            if c.month == month, c.day == day, c.isLeapMonth != true { return d }
        }
        return nil
    }
}

// MARK: - be full sir (식사)

/// 식사를 어떤 방식으로 해결했는지/할 것인지.
enum MealCategory: String, Codable, CaseIterable, Identifiable {
    case diningOut  // 외식
    case delivery   // 배달
    case cooking    // 요리

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diningOut: return "Dining Out"
        case .delivery: return "Delivery"
        case .cooking: return "Cooking"
        }
    }

    var systemImage: String {
        switch self {
        case .diningOut: return "fork.knife"
        case .delivery: return "bag.fill"
        case .cooking: return "frying.pan.fill"
        }
    }
}

/// The kind of place a nearby search looks for. Each case maps to one Google place type and one plain search word.
enum MealCategoryFilter: String, CaseIterable, Identifiable {
    case restaurant, cafe

    var id: String { rawValue }
    /// The Google place type sent as the included type.
    var includedType: String { self == .restaurant ? "restaurant" : "cafe" }
    /// The search word used when no keyword is given.
    var categoryWord: String { self == .restaurant ? "restaurants" : "cafes" }
    var title: String { self == .restaurant ? "Restaurants" : "Cafes" }
    var systemImage: String { self == .restaurant ? "fork.knife" : "cup.and.saucer.fill" }
}

/// Sort order of a nearby search.
/// Distance is computed on the device from the straight-line distance, so it covers only the places Google returned.
/// Relevance keeps the order Google answered in. A rating order cannot be built because the requested fields carry no rating.
enum NearbySort: String, CaseIterable, Identifiable {
    case distance, accuracy
    var id: String { rawValue }
    var title: String { self == .distance ? "Distance" : "Relevance" }
}

/// One nearby search result (distance, category and link included).
struct NearbyPlace: Identifiable {
    var id: String { "\(place.name)-\(place.latitude)-\(place.longitude)" }
    let place: Place
    /// The primary type display name Google gives, such as a coffee shop; empty when Google gives none.
    let category: String
    let distanceMeters: Int?
    /// Always nil: the phone number is not requested because it would move every call to a higher billing tier.
    let phone: String?
    /// The Google Maps page address of the place; nil when Google gives none.
    let url: String?

    /// "230m" / "1.4km"
    var distanceText: String? {
        guard let d = distanceMeters else { return nil }
        return d < 1000 ? "\(d)m" : String(format: "%.1fkm", Double(d) / 1000)
    }
}

/// 한 끼 식사 기록. be full sir의 추천 이력이자, 나중에 be rich sir(지출)와 이어질 접점이다.
///
/// 일정(ScheduledEvent)과는 별개의 데이터다 — 식사는 "무엇을 먹었나"의 기록이고, 그 식당까지
/// 가는 이동은 기존 일정 파이프라인이 담당한다. 추천을 골라 실제 일정으로 등록한 경우에만
/// `scheduledEventId`로 둘을 연결한다(Phase 1 Day 10).
struct MealLog: Identifiable, Codable {
    var id: UUID = UUID()
    var category: MealCategory
    /// 식당명(외식·배달) 또는 메뉴명(요리).
    var title: String
    /// 식당 위치. 배달·요리는 대개 nil.
    var place: Place?
    /// 예상 비용(원). 모르면 nil — 나중에 be rich sir 예산 연동에 쓴다.
    var estimatedCost: Int?
    /// 이 식사로 등록된 이동 일정이 있으면 그 id(추천 → 일정 등록 연결용).
    var scheduledEventId: UUID?
    /// 이 식사로 만든 활동 블록(식사 시간)의 id. 일정을 지우면 이 기록도 같이 지우는 데 쓴다.
    var activityId: UUID?
    /// 계획된 식사 시각(등록해둔 경우). 아직 안 먹은 일정을 지울 때 기록도 지울지 판단한다.
    var plannedAt: Date?
    /// 기록한 시각.
    var loggedAt: Date = Date()
}

/// 이동이 아니라 "그 장소에 머무는 활동"(수업·근무·점심 등)을 나타내는 시간 블록.
/// ScheduledEvent(이동+도착 알람)와 달리 이동시간 계산·알림이 없는 순수 시간표 항목이다.
struct ActivityBlock: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var location: Place?
    var startDate: Date
    var endDate: Date
    /// 반복 일정 그룹(ScheduledEvent의 recurrenceId)과 공유 — 같이 일괄 삭제된다.
    var recurrenceId: UUID?
    /// 이 활동을 구글 캘린더에 올릴지. nil(옛 데이터)이면 전역 설정을 따른다.
    var syncToCalendar: Bool?

    var wantsCalendarSync: Bool { syncToCalendar ?? true }
}

// MARK: - 기기 동기화의 "동기화 내용"(SPEC-SYNC-004 §2.1)

/// 동기화하는 네 종류. 원시값은 서버 `kind`와 상태 파일의 키로 그대로 간다.
enum SyncKind: String, Codable, CaseIterable {
    case event, activity, meal, favorite
}

/// 항목별 "무엇이 고침인가"의 단일 정의(계약 5). 감지의 비교와 서버로 보낼 페이로드가 모두 이
/// 정의에서 나오므로, 필드를 하나 더하거나 빼려면 각 모델의 `syncContent` 한 곳만 고친다.
/// 정의가 둘이면 비교는 못 보는데 페이로드엔 실리는 필드가 생겨 기기 사이에 조용히 갈라진다.
protocol SyncItem: Identifiable where ID == UUID {
    static var syncKind: SyncKind { get }
    /// `forPayload == false`: 비교에 넣는 것만(지문 입력). `true`: 거기에 페이로드에만 넣는 것을 더한 것.
    /// 어디에도 안 넣는 것(기기 안에만 두는 `notificationId`)은 양쪽에서 빠진다.
    func syncContent(forPayload: Bool) -> any Encodable
}

/// 페이로드 판. 바꾸려면 서버(SPEC-SYNC-003·006)와 함께 올린다.
let syncPayloadVersion = 1

private struct SyncPayloadBody: Encodable {
    let content: any Encodable
    private enum Key: String, CodingKey { case v }
    func encode(to encoder: Encoder) throws {
        // 같은 인코더에 키 컨테이너를 두 번 여는 방식 — 내용을 평평하게 두고 "v"만 더한다.
        try content.encode(to: encoder)
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(syncPayloadVersion, forKey: .v)
    }
}

extension SyncItem {
    /// 지문 입력. 키를 정렬해야 같은 내용이 늘 같은 바이트가 된다(날짜 전략은 정하지 않는다 — 아래와 같은 이유).
    /// 인코딩 실패(좌표가 NaN 등)는 빈 데이터로 둔다: 저장 함수가 이미 `try?`로 같은 값을 못 쓰는 자리라
    /// 여기서 던지면 감지가 통째로 멈추는 쪽이 더 나쁘다.
    func syncComparisonJSON() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(SyncAnyEncodable(base: syncContent(forPayload: false)))) ?? Data()
    }

    /// 서버로 보낼 페이로드. 전략을 정하지 않은 기본 인코더라 날짜는 2001-01-01T00:00:00Z 기준 초다(D21 —
    /// 네 데이터 파일의 인코더와 같다. 서버 쪽 해석은 SPEC-SYNC-003·006의 몫).
    func syncPayloadJSON() -> Data {
        (try? JSONEncoder().encode(SyncPayloadBody(content: syncContent(forPayload: true)))) ?? Data()
    }
}

private struct SyncAnyEncodable: Encodable {
    let base: any Encodable
    func encode(to encoder: Encoder) throws { try base.encode(to: encoder) }
}

/// `ScheduledEvent`의 동기화 내용. 비교에는 **기준 시각**(`anchorDate`)만 넣고 기준이 아닌 쪽 시각과
/// 이동시간은 페이로드에만 싣는다: `refreshUpcomingEstimates`가 그쪽을 다시 계산해 저장하는데, 이것을
/// 고침으로 세면 기기마다 앞으로 올 때 서로의 일정을 고쳐 이기려 든다(핑퐁).
struct EventSyncContent: Encodable {
    let event: ScheduledEvent
    let forPayload: Bool

    private enum CodingKeys: String, CodingKey {
        case id, title, origin, destination, mode, bufferMinutes, notifyLeadMinutes, notifyEnabled
        case syncToCalendar, recurrenceId, linkedActivityId, anchor, anchorDate
        case arrivalDate, departureDate, travelSeconds
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(event.id, forKey: .id)
        try c.encode(event.title, forKey: .title)
        try c.encodeIfPresent(event.origin, forKey: .origin)
        try c.encode(event.destination, forKey: .destination)
        try c.encode(event.mode, forKey: .mode)
        try c.encode(event.bufferMinutes, forKey: .bufferMinutes)
        try c.encode(event.notifyLeadMinutes, forKey: .notifyLeadMinutes)
        try c.encodeIfPresent(event.notifyEnabled, forKey: .notifyEnabled)
        try c.encodeIfPresent(event.syncToCalendar, forKey: .syncToCalendar)
        try c.encodeIfPresent(event.recurrenceId, forKey: .recurrenceId)
        try c.encodeIfPresent(event.linkedActivityId, forKey: .linkedActivityId)
        try c.encodeIfPresent(event.anchor, forKey: .anchor)
        try c.encode(event.anchorDate, forKey: .anchorDate)
        guard forPayload else { return }
        // 받는 기기가 이동시간을 다시 조회하지 않고 바로 표시·예약하도록 스냅샷을 싣는다(카카오 할당량).
        try c.encode(event.arrivalDate, forKey: .arrivalDate)
        try c.encodeIfPresent(event.departureDate, forKey: .departureDate)
        try c.encodeIfPresent(event.travelSeconds, forKey: .travelSeconds)
    }
}

extension ScheduledEvent: SyncItem {
    static var syncKind: SyncKind { .event }
    func syncContent(forPayload: Bool) -> any Encodable { EventSyncContent(event: self, forPayload: forPayload) }
}

extension ActivityBlock: SyncItem {
    static var syncKind: SyncKind { .activity }
    /// 기기 전용 필드가 없는 모델은 합성 인코더에 맡긴다 — 필드가 새로 생기면 자동으로 동기화 내용에 든다.
    func syncContent(forPayload: Bool) -> any Encodable { self }
}

extension MealLog: SyncItem {
    static var syncKind: SyncKind { .meal }
    func syncContent(forPayload: Bool) -> any Encodable { self }
}

extension FavoritePlace: SyncItem {
    static var syncKind: SyncKind { .favorite }
    func syncContent(forPayload: Bool) -> any Encodable { self }
}
