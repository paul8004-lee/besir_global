import Foundation
import CoreLocation

/// 편집 카드의 필드 모델. AI 채팅의 되묻기 카드로 태어나 AIAssistant 안에 중첩돼 있었지만,
/// 네 편집 화면이 같은 타입을 쓰게 되며 중첩을 벗어났다 — 모델이 AI 전용 이름에 묶여 있으면
/// 화면이 빌려 쓸 수가 없다. 시각 해석의 단일 출처(BesirTime)도 이 파일이 함께 가진다.
///
/// 이 파일은 SwiftUI를 가져오지 않는다. 가드 드라이버(Tools/GuardDriver.swift)는 뷰 없이
/// 컴파일되는데, 모델이 뷰 프레임워크에 기대면 그 컴파일 집합이 깨진다. CoreLocation은 뷰가
/// 아니라 PlaceLineResolve가 LocationManager의 권한 값을 읽기 위해 가져온다(드라이버 컴파일
/// 목록의 LocationManager.swift도 같은 import로 이미 컴파일된다).

/// 시각 표기("9월 17일 (목) 오후 3:00")와 카드 시각 값의 왕복 해석을 홀로 안다. 포매터·파서가
/// 파일마다 제각각 생기는 것이 이 프로젝트가 이미 한 번 당한 어긋남이라 정의는 이곳 하나고,
/// AIAssistant는 위탁 한 줄로 같은 시그니처를 유지한다.
@MainActor enum BesirTime {
    private static let whenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE, MMM d, h:mm a"
        return f
    }()
    static func when(_ d: Date) -> String { whenFormatter.string(from: d) }

    /// 배너가 두 시각을 "~"로 잇는 데 쓰는 좁은 표기("9/17 (목) 오후 3시 05분"). `when`으로
    /// 흡수하지 않는 이유는 폭이다 — 실측 결과 `when`("9월 17일 (목) 오후 3시 5분")은 이보다
    /// 길어, 이 표기를 폼 노트("예상 출발 ~")에 이어 붙이면 줄바꿈이 깨진다(SPEC-UIKIT-002 REQ-023).
    /// static let인 이유: 옛 AddEventView의 depFmt는 계산 프로퍼티라 접근할 때마다 포매터를
    /// 새로 만들어 한 차례 재렌더에 최대 세 번 할당했다.
    static let compact: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "M/d EEE h:mm a"
        return f
    }()

    /// 상세 화면 헤더의 완전한 표기("9월 17일 (목) 오후 3시 05분"). `when`과 패딩만 다른
    /// 쌍둥이인데 mm을 m으로 통일하면 "05분"의 0이 사라진다 — EventDetailView에서 이사해 온
    /// 그대로이고 한 글자도 다시 쓰지 않는다(SPEC-UIKIT-004 REQ-001).
    static let full: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE, MMM d, h:mm a"
        return f
    }()

    /// 하루 안의 시각만("오후 3시 05분") — 출발 시각 큰 숫자가 쓴다. 이사 본체, 패턴 불변.
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f
    }()

    /// 카드가 확정한 시각의 왕복 형식 — 쓰기(직렬화)와 읽기(accepts·재확정)가 같은 포매터를
    /// 쓴다. 형식 문자열이 두 벌이 되면 한쪽만 고쳐지는 날이 온다(렌더링·히트테스트가 어긋났던
    /// 그 모양). 실행부의 parseDate가 받는 형식이기도 하다.
    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// "arr:2026-09-17T15:00:00" 형태의 시각 줄 값을 (접두, Date)로 푼다. accepts·customLabel·
    /// 직렬화·기준 재선택이 전부 이 파서를 지난다 — 제각각 파면 어느 한쪽만 고쳐진다.
    /// 접두 없는 값도 ("", Date)로 푼다 — 활동의 시작·종료는 도착/출발 기준을 갖지 않는 시각이라
    /// 확정값에 접두가 붙지 않는다. 빈 문자열이 목록 맨 끝인 이유: hasPrefix("")는 항상 참이라
    /// 앞에 두면 "arr:"와 "dep:"가 영영 도달하지 않는다.
    static func parseDatetime(_ raw: String) -> (prefix: String, date: Date)? {
        for prefix in ["arr:", "dep:", ""] where raw.hasPrefix(prefix) {
            if let d = isoFormatter.date(from: String(raw.dropFirst(prefix.count))) {
                return (prefix, d)
            }
        }
        return nil
    }

    /// 접두("arr:"/"dep:")와 도착·출발 기준을 잇는 매핑의 유일한 집 — 폼·AI 카드·컴포넌트가
    /// 제각각 삼항으로 알던 모양이 이 매핑의 계약 5 위반이었다. 몸통을 switch로 쓰는 것은
    /// 소유자 자신이 세는 신호(잔여 비교·삼항 grep)를 깨뜨리지 않기 위해서고, 커밋된 줄을
    /// 통째로 물어온 호출부는 parseDatetime을 먼저 거치게 한다(형식 지식이 호출부에 새는 것을
    /// 막는다 — 잘못된 값은 nil로, 삼항 시절의 "나머지 전부 출발"이 아니라).
    static func anchor(ofPrefix: String) -> ScheduleAnchor? {
        switch ofPrefix {
        case "arr:": return .arrival
        case "dep:": return .departure
        default: return nil
        }
    }

    /// anchor(ofPrefix:)의 역방향 — 직렬화하는 세 곳(폼 두 곳·AI 보류 턴)이 공유한다.
    static func prefix(for anchor: ScheduleAnchor) -> String {
        switch anchor {
        case .arrival: return "arr:"
        case .departure: return "dep:"
        }
    }
}

/// 종료 바퀴 줄의 명세(REQ-020) — 기준이 어디서 오는지(기준 줄 또는 고정 기준)와 상한, 확정 전 바퀴의
/// 출발 자리만 안다. 모양(네이티브 다이얼 — SPEC-UIKIT-016 S1부터 48행 커스텀 바퀴를 대체했다)은 뷰의
/// 것이고, 여기는 세 자리(수동 만들기·활동 편집·반복 확인 카드)가 같은 규칙을 공유할 수 있는 최소한의 데이터다. 새 `Kind`를 만들지 않는 이유: `.datetime`의 해석(accepts·customLabel)과 확정
/// 경로가 갈라지면 같은 값을 두 문법으로 배우게 된다(design-lens-2 A.11).
struct EndWheelSpec {
    /// 바퀴가 출발하는 기준 줄의 툴 인자 키. 수동 만들기·활동 편집에서는 시작 줄("start_iso")이고,
    /// AI 반복 활동 카드의 종료 줄도 시작 줄을 가리킨다(018 REQ-011 — 시작을 바꾸면 바퀴가 따라간다).
    let baseKey: String
    /// AI 반복 활동 카드의 종료 줄이면 true — 종료를 시작 + 24시간 안으로 묶는다(REQ-018, 정확히 24시간은
    /// 받는다, J-12). 수동 만들기·편집은 바퀴가 다음 날까지만 덮고 그 너머는 날짜 표시의 달력으로
    /// 가므로(REQ-021) 상한을 새로 두지 않는다.
    let capsAt24Hours: Bool
    /// 기준 줄이 카드에 없을 때의 기준 시각 — 수동 만들기의 시작 줄(기대는 줄이 없다)이 쓴다. 옛 반복
    /// 확인 카드의 끝 쪽 줄(기준이 'HH:mm' 인자라 줄로 없던 것)은 018 M3에서 종료 줄로 대신했다.
    var fixedBase: Date? = nil
    /// 확정 전 바퀴가 서는 자리의 시각 씨앗(J-13 (나) — 모델이 준 종료를 기준 뒤 첫 같은 시각에 두되 줄은
    /// 미선택). 날짜는 줄이 세워질 때의 기준일 뿐이라 쓰는 쪽은 `draft(base:)`로 지금 기준에 다시 맞춘다.
    var draftSeed: Date? = nil
    /// 기준 줄이 아직 안 골라져 바퀴를 못 세울 때 대신 보일 안내(종료 줄 — 시작을 먼저 고른다).
    var baseHint: String? = nil
    // 절대 상한(endBefore — 옛 반복 확인 카드의 점심 끝 줄만 채우던 값)은 그 줄이 018 M3에서 없어져 늘 nil이었고,
    // 채우는 곳이 0이 되어 018 M4에서 판정 한 줄과 함께 지웠다.
    /// 수동 활동 만들기의 **시작** 줄이면 true(t50 P3, 운영자 원문 "시작도 바퀴로"). 같은 바퀴를 쓰되
    /// 기준은 "넘어야 할 시각"이 아니라 바퀴가 처음 서는 날(생성을 누른 날의 0시)일 뿐이라, 경계
    /// 판정이 없고 기준 날 0시도 고를 수 있다. 바퀴를 따로 만들지 않는 이유: 시작·종료가 다른
    /// 컨트롤이면 같은 날짜·시각을 두 문법으로 배우게 된다(계약 5, 결과로 두 줄 표기가 같아진다).
    /// 기본값 false라 기존 종료 줄(편집 화면 포함)은 한 글자도 바뀌지 않는다.
    var isStart: Bool = false

    /// 거절 문구의 단일 출처 — 모델(choosePlainTime·AIAssistant.chooseTimePlain)과 바퀴 뷰가 같은 글자를
    /// 말해야 한다(계약 5). 유효 범위를 나열하지 않는 것은 프로젝트 규칙이다.
    static let notAfterBaseMessage = "종료는 시작보다 뒤여야 해요"
    // 24시간 상한 거절 문구(overCapMessage)는 그것을 쓰던 폼 밖 끝 쪽 줄 확정 갈래가 018 M4에서 지워져 참조가
    // 0이 되어 018 M6에서 지웠다 — 반복 카드의 상한은 바퀴 뷰(accepts)와 실행부 가드가 맡는다.

    /// 확정 전 바퀴의 시작 위치 — 씨앗의 시각을 기준 시각 뒤 첫 순간에 놓는다. 기준이 바뀌는 줄도
    /// 날짜가 틀어지지 않게 시각만 쓴다. 기준 이하의 끝만 이 줄을 세우므로 결과는 늘 기준 + 24시간
    /// 안이다(정확히 24시간 포함).
    func draft(base: Date, calendar: Calendar = .current) -> Date? {
        guard let seed = draftSeed else { return nil }
        let tod = calendar.dateComponents([.hour, .minute], from: seed)
        // 시작 줄은 기준 날 0시 자신도 자리다 — "뒤 첫 순간"으로 찾으면 0시 씨앗이 다음 날로 밀려
        // 바퀴가 생성을 누른 날이 아닌 날짜를 보인다(운영자 원문 "시작 바퀴가 11/14일로").
        let from = isStart ? base.addingTimeInterval(-1) : base
        return calendar.nextDate(after: from, matching: tod, matchingPolicy: .nextTime)
    }

    /// 후보 종료가 이 줄의 경계 안에 드는지. 바퀴 뷰가 흐림·거절 판정을 따로 짜면 J-12 경계가 두
    /// 벌이 되므로(계약 5) 판정은 카드·뷰 쪽에서는 이곳 하나다. 실행부의 endSideTimeIssue는 시각을 분
    /// 단위 산술로 재서 이 함수와 잇지 않았다 — 이쪽은 실제 Date 간격이라 서머타임 날에 갈릴 수 있기
    /// 때문이다. 대신 드라이버가 두 판정이 경계에서 같은 답을 내는지 잰다.
    func accepts(end: Date, base: Date) -> Bool {
        // 시작 줄의 기준은 첫 날일 뿐 넘어야 할 경계가 아니다 — 시작과 종료의 앞뒤 판정은 확정
        // 경로(choosePlainTime)가 이미 혼자 맡는다(종료를 직접 거절하면 줄 note로 말하고, 시작을 옮기면 종료가 따라간다).
        if isStart { return true }
        guard end > base else { return false }
        return !capsAt24Hours || end.timeIntervalSince(base) <= 24 * 60 * 60
    }
}

/// 수동 활동 만들기의 시작·종료 줄(t50 P3·렌즈 U-1). 줄 정의가 뷰 파일(AddActivityView)에 있으면
/// 드라이버가 닿지 못해 "생성을 누른 날에 바퀴가 선다"·"시작 전엔 종료가 달력으로 떨어지지 않는다"가
/// 시뮬레이터에서만 판정된다 — 모델 쪽에 두어 매 빌드마다 결정적으로 잰다. 활동 편집의 줄
/// (LegCardForm.seeded)은 운영자 지시("활동 편집 화면은 그대로")로 여기를 쓰지 않는다.
extension EndWheelSpec {
    /// 시작 줄 — 바퀴의 첫 날은 생성을 누를 때 보고 있던 날이다(운영자 원문 "11/14일 활동일정 생성을
    /// 누르면 시작 바퀴가 11/14일로 지정후 시간 선택"). 초안 시각은 지금의 다음 정각(옛 달력의
    /// nextWholeHour와 같은 '값 아닌 위치')을 그 날에 옮긴 것이고, 23시 뒤에는 23시에 둔다 — 다음
    /// 정각이 자정이면 바퀴가 다른 날짜를 보이며 열리기 때문이다. 확인을 눌러야 값이 된다.
    static func manualStart(day: Date, now: Date, calendar: Calendar = .current) -> EndWheelSpec {
        let firstDay = calendar.startOfDay(for: day)
        let hour = min(calendar.component(.hour, from: now) + 1, 23)
        // baseKey가 빈 이유: 시작 줄은 기대는 줄이 없다 — endWheelBase가 같은 키의 줄을 못 찾아
        // fixedBase(첫 날)로 간다. 자기 키를 넣으면 미확정 시작이 nil 기준이 되어 바퀴가 안 선다.
        return EndWheelSpec(baseKey: "", capsAt24Hours: false, fixedBase: firstDay,
                            draftSeed: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: firstDay),
                            isStart: true)
    }

    /// 종료 줄 — 편집 화면 줄(seeded)과 같은 규칙에 안내 하나만 더한다. 수동 만들기는 시작이 비어
    /// 열리므로 안내가 없으면 시작을 고르기 전 종료 에디터가 옛 큰 달력으로 떨어져, 같은 줄이 순서에
    /// 따라 두 컨트롤을 보였다(렌즈 U-1). 편집 화면은 시작이 늘 차 있어 이 안내가 필요 없다.
    static var manualEnd: EndWheelSpec {
        EndWheelSpec(baseKey: "start_iso", capsAt24Hours: false, baseHint: manualEndHint)
    }
    static let manualEndHint = "시작을 먼저 골라 주세요"

    /// 반복 활동의 종료 줄 — 시각만 고르는 반복 끝 바퀴(시작 뒤 24시간 안, 018 REQ-018). AI 카드의 첫 모양과 반복 글을
    /// 넣어 반복으로 바뀐 카드(수동·AI)가 같은 명세를 쓴다(019 L-28 — 두 곳에 적으면 한쪽만 늙는다).
    static var recurringEndRow: EndWheelSpec {
        EndWheelSpec(baseKey: "start_iso", capsAt24Hours: true, baseHint: manualEndHint)
    }
}

/// "반복 전체" 이동 추가의 결과 줄 문구(REQ-016 — 붙인 수와 "이미 있음"·"장소 없음" 두 건너뜀 이유를
/// 각각 말한다). 화면(ActivityDetailView)이 문장을 직접 조립하던 자리에서 "장소 없음"이 빠져 있었다
/// (렌즈 U-2) — 문장을 이곳 하나에 두어 드라이버가 세 갈래를 다 잰다(계약 5). 0건인 건너뜀은 줄을
/// 만들지 않는다(없는 이유를 말하면 잡음이다).
enum SeriesLegAddReport {
    struct Line: Equatable {
        let text: String
        /// 붙인 결과(체크 표시·travelInk)인지, 건너뜀(muted)인지 — 색만이 아니라 글리프로도 가른다.
        let done: Bool
    }

    static func lines(role: ScheduleAnchor, added: Int, skippedExisting: Int, skippedNoPlace: Int) -> [Line] {
        let word = role == .arrival ? "가는" : "오는"
        var lines = [Line(text: "\(added)개 회차에 \(word) 이동을 붙였어요.", done: true)]
        if skippedExisting > 0 {
            lines.append(.init(text: "\(skippedExisting)개 회차는 이미 \(word) 이동이 있어 건너뛰었어요.", done: false))
        }
        if skippedNoPlace > 0 {
            // 방향 낱말을 넣는 이유: 장소 없음은 회차의 장소가 비었는지로 세므로 가는 편과 오는 편의 수가 같다 —
            // 낱말이 없으면 두 방향을 한 저장에 붙일 때 똑같은 줄이 두 번 나온다(ui-design 판정).
            lines.append(.init(text: "\(skippedNoPlace)개 회차는 장소가 없어 \(word) 이동을 건너뛰었어요.", done: false))
        }
        return lines
    }
}

extension EditCard {
    /// 수동 활동 만들기 카드의 시작·종료 두 줄(t50 P3). 종료 줄은 늘 미선택으로 열린다(O-A7) —
    /// 옛 폼의 +1시간 프리필은 보이지 않는 기본값이었으므로 카드 문법대로 비워 둔다. 시작 줄은
    /// presetStart가 있을 때만 그 시각으로 **확정된 채** 열린다(빈칸 꾹 누르기, REQ-009 — 바퀴의
    /// 위치(씨앗)만 바꾸는 길은 '이미 확정된 채'를 채우지 못해 쓰지 않는다, plan §3.3 '쓰지 말 길').
    /// 확정 글자는 다이얼 확정(choosePlainTime)과 같은 인코더가 내야 어긋난 값을 아무도 못 잡으므로
    /// (계약 5) 여기서 같은 ISO 포매터로 만든다. preset이 없는 호출(맥 '+', O-C1)은 둘 다 미선택 —
    /// 지금 동작 그대로다.
    /// 두 줄 모두 기준 없는 시각(REQ-001)이라 확정은 chooseTimePlain 한 길이다.
    static func manualActivityTimeRows(defaultDay: Date, now: Date, presetStart: Date? = nil) -> [EditField] {
        [
            .init(key: "start_iso", kind: .datetime, label: "시작", options: [], allowsCustom: false,
                  chosen: presetStart.map { BesirTime.isoFormatter.string(from: $0) },
                  anchored: false, endWheel: .manualStart(day: defaultDay, now: now)),
            // 종료 줄은 시작 날짜에서 출발하는 종료 바퀴다(REQ-020 (a)) — 상한 없음(바퀴 다음 날
            // 너머는 날짜 표시의 달력, REQ-021).
            .init(key: "end_iso", kind: .datetime, label: "종료", options: [], allowsCustom: false,
                  anchored: false, endWheel: .manualEnd),
        ]
    }
}

/// 실제로 만들어질 첫 회차의 시작 시각(REQ-020 (b) 카드 날짜 표시의 단일 출처, A.5·F9) —
/// rule.dates에 "회차 자기 시작 > now" 필터를 건 첫 날이다. 카드가 이 계산을 따로 하면 "오늘
/// 시작 시각이 지났는데 카드는 오늘 날짜를 보이는" 어긋남이 생긴다(계약 5). 시작 시각을 인자로
/// 받는 이유: 반복마다 회차 시작이 다르다 — 호출자가 그 반복의 시작을 넣게 한다. Store의 생성 루프
/// (addRecurringLinkedSeries)가 이 관문의 행동 기준이고, 드라이버가 둘의 일치를 잰다. 이 파일에
/// 사는 이유: 실행부(카드 줄을 세우는 쪽)와 바퀴 날짜 표시가 같은 파일에서 읽어야 하는데, 이 파일이
/// 이미 카드 시각 해석의 단일 출처(BesirTime)를 가지고 있어서다.
extension RecurrenceRule {
    /// 종료 날짜(그날 포함)까지에서 첫 회차.
    /// 찾는 순간 멈추는 firstDate를 쓴다: 종료 날짜를 아직 모르는 카드가 먼 범위를 넘겨도 목록 전체를 짓지 않는다.
    func firstOccurrenceStart(from startDate: Date, startHour: Int, startMinute: Int,
                              through endDate: Date, now: Date, calendar: Calendar = .current) -> Date? {
        func start(on day: Date) -> Date? {
            calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: day)
        }
        return firstDate(from: startDate, through: endDate, calendar: calendar) { day in
            start(on: day).map { $0 > now } ?? false
        }.flatMap { start(on: $0) }
    }
}

// MARK: - 장소 줄 문법(SPEC-UIKIT-016 S1, REQ-003~005)

/// 장소 줄의 내부 토큰 셋 — 문자열 값의 단일 출처다. 토큰은 줄의 값으로만 살고 Store에는
/// 흘러가지 않는데(저장 자리에서 nil로 풀린다), 문자열이 파일마다 벌로 존재하면 한쪽만 고쳐지는
/// 날 인자·저장·판정이 어긋난다(계약 5 — 세 토큰이 AIAssistant에 private로 살던 시절의 모양).
/// 리터럴을 바꾸면 토큰이 흘러가는 저장·인자 형식이 깨지므로 값은 그대로 둔다.
/// 머무는 요청의 '이동 없음' 토큰은 018 M4에서 지웠다 — 그 뜻은 '가는 이동' 토글 끔이 맡고(O-B7),
/// 행도 호출처도 남지 않았다(O-S3-12).
enum PlaceTokens {
    /// 카드에서 고르는 "현재 위치"(AI 카드 출발지 줄·수동 활동의 가는 이동 출발지 줄).
    static let currentLocation = "__current_location__"
    /// 가는 편을 만들지 않는 "가는 편 없음" — 빈 값(진짜 편도)과 구분된다. 018부터 카드에 이 행은
    /// 없고(REQ-008 — '가는 이동' 토글이 그 뜻), 활동 카드 확정 어댑터가 토글 끔을 이 값으로 싣는다.
    static let noOutboundLeg = "__no_outbound_leg__"
    /// 수동 활동 카드의 "장소 없음" — 장소가 선택임을 푸는 열쇠.
    static let noPlace = "__no_place__"

    static func isInternalToken(_ v: String) -> Bool {
        v == currentLocation || v == noOutboundLeg || v == noPlace
    }

    /// 토큰을 사람이 읽는 표시 문구로 바꾼다. 토큰이 문구로 새는 결함이 자리마다 따로 나온 전력이
    /// 있어(AIAssistant.displayText 머리말) 매퍼도 이곳 하나로 모은다.
    static func displayText(_ value: String) -> String {
        switch value {
        case currentLocation: return "현재 위치"
        case noOutboundLeg: return "가는 편 없음"
        case noPlace: return "장소 없음"
        default: return value
        }
    }

    /// 토큰 칩(값·라벨 한 쌍) — 칩 문법 시절 옵션 배열에 얹던 모양 그대로. 옵션은 이제 그리는 데
    /// 쓰이지 않아도 chosenLabel의 값→라벨 매핑이 읽는다.
    static func chip(_ token: String) -> EditField.Option {
        .init(label: displayText(token), value: token)
    }
}

/// 줄의 특수 행 나열 — spec.md §2.1 표가 단일 출처다. 칩 문법에서 칩이 줄 지어 붙던 조건이 그대로
/// 행 나열로 옮겨온 것이므로 어느 줄에 무엇이 서는지는 이 상수들이 말한다(REQ-003 "동작 무변경").
enum PlaceLineSpecials {
    static let currentLocation = [PlaceTokens.currentLocation]
    // '가는 편 없음'을 얹던 가는 편 출발지 묶음과 '이동 없음'을 얹던 머무는 출발지 묶음은 018 M4에서
    // 지웠다 — AI 카드의 두 행은 '가는 이동' 토글이 대신하고(REQ-008·O-B7), 남은 호출처가 없었다
    // (후보 카드의 가는 편 출발지 줄도 이제 현재 위치 행 하나다 — AC-008).
    /// 수동 활동 카드의 장소 줄(REQ-003 (2), §2.1) — 운영자 §9 추가 "장소 탭에서도 현재 위치가
    /// 있어야 함"으로 더했다. 순서가 현재 위치 → 장소 없음인 이유는 출발지 줄의 '현재 위치 →
    /// 가는 편 없음'과 같은 모양이어서다(보완 E).
    static let currentLocationAndNoPlace = [PlaceTokens.currentLocation, PlaceTokens.noPlace]
}

/// 장소 줄의 목록 구성(REQ-003·004) — 특수 행 → 즐겨찾기 → 검색 후보 순서를 내는 순수 함수.
/// 목록 순서와 즐겨찾기 걸러짐(라벨·장소 이름·주소의 부분 일치, 대소문자 무시)을 뷰와 드라이버가
/// 함께 읽는 단일 출처이다(계약 5 — 네 벌이던 검색→줄 상태 파이프를 모으는 S1의 몫). 드라이버
/// 컴파일 목록 안 파일이라 여기 둔다(뷰 파일에 두면 AC-004·005·007의 AUTO가 성립하지 않는다).
enum PlaceLine {
    /// 목록의 행 세 갈래. 즐겨찾기 행이 Place를 직접 실는 이유: 라벨이 같은 즐겨찾기 둘이 있을 때
    /// 이름으로 좌표를 풀면 한쪽이 이겨 다른 줄의 좌표가 조용히 바뀐다(REQ-005) — 행이 자기 Place를
    /// 들면 탭이 줄 신원에 좌표를 그대로 걸고, 좌표 없는 옵션(AddEventView의 옛 생성부)만 라벨로
    /// 고르는 옛 길로 폴백한다.
    enum Row: Equatable {
        case special(String)
        case favorite(label: String, place: Place?)
        case candidate(Place)
    }

    static func rows(query: String, specials: [String], favorites: [EditField.Option],
                     candidates: [Place]) -> [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // 옵션 배열에는 토큰 칩이 섞여 있다 — 토큰은 행 나열(specials)이 이미 말하므로 여기선 걸러낸다.
        let favs = favorites.filter { !PlaceTokens.isInternalToken($0.value) }
        if q.isEmpty {
            // 검색창이 비어 있는 동안 목록은 특수 행과 즐겨찾기 전체다(REQ-003). 실어 온 후보가
            // 있다면(후보 카드가 미리 얹은 lookup 결과) 즐겨찾기 아래에 함께 보인다(R-1) — 후보를
            // 얹어 두고도 첫 화면에서 보이지 않으면 사용자는 다시 검색해야 한다. 직접 치다 지운
            // 검색어는 묶음이 lookup을 .idle로 되돌리므로 평범한 빈 칸에는 후보가 없다.
            return specials.map(Row.special)
                + favs.map { .favorite(label: $0.label, place: $0.place) }
                + candidates.map(Row.candidate)
        }
        // 즐겨찾기 일치는 라벨·장소 이름·주소의 부분 일치(대소문자 무시, O-B5) — 좌표가 없는 옵션은
        // 라벨만 안다(옛 생성부).
        let matched = favs.filter { opt in
            if opt.label.lowercased().contains(q) { return true }
            guard let p = opt.place else { return false }
            return p.name.lowercased().contains(q) || p.address.lowercased().contains(q)
        }
        // 맞는 즐겨찾기 묶음이 후보 위에 온다(REQ-004). 개수 상한은 없다(O-B3 — 스크롤이 담당).
        return matched.map { .favorite(label: $0.label, place: $0.place) } + candidates.map(Row.candidate)
    }

    /// 닫힌 검색창이 보일 글자의 단일 출처(REQ-005 C, 보완 F3) — 수동 카드(줄 신원 사전)와
    /// AI 카드(문자열 사전)의 두 사전 방식을 이 함수 하나로 커버한다. 우선순위가 이 순서인
    /// 이유: ① 고른 값이 없으면 보일 글자 자체가 없고, ② 내부 토큰은 토큰 글자가 아니라 표시
    /// 문구로 보여야 하며(displayText 머리말), ③ 좌표가 확정된 장소는 **누른 행의 라벨**이
    /// 이긴다 — 즐겨찾기 행을 눌렀으면 '회사' 라벨을 보여야 하는데 저장값은 place.name 그대로라
    /// 표시만 라벨로 바꾸는 것이다(R-3, 기록 형식은 무변경). 라벨을 못 찾으면 후보 행에서 골랐다는
    /// 뜻이므로 place.name, 그 밖(좌표 없는 옛 옵션)은 값이 곧 라벨이다.
    static func closedSearchText(chosen: String?, confirmedPlace: Place?,
                                 favorites: [EditField.Option]) -> String {
        guard let chosen else { return "" }
        if PlaceTokens.isInternalToken(chosen) { return PlaceTokens.displayText(chosen) }
        if let confirmedPlace {
            if let label = favorites.first(where: { $0.place == confirmedPlace })?.label { return label }
            return confirmedPlace.name
        }
        return favorites.first { $0.value == chosen }?.label ?? chosen
    }

    /// 0건 안내 문구의 단일 출처(경계 ①) — 뒤에 원인을 덧붙이지 않는 이유: 검색 실패와 인터넷 끊김은
    /// 화면에서 가를 수 없어 "다른 이름으로 적어보세요" 같은 처방이 틀린 안내가 되는 날이 있다.
    static let noResultNote = "후보를 찾지 못했어요."

    /// "후보를 찾지 못했어요" 문구를 띄울지의 단일 판정(REQ-004, 보완 F2) — 검색 0건이어도 맞는
    /// 즐겨찾기가 하나라도 있으면 목록이 비어 있지 않으므로 띄우지 않는다. 목록 구성(rows)과 빈
    /// 상태 판정이 저마다 계산되면 어긋나는 날 문구가 잘못된 쪽만 말한다(계약 5) — 같은 질의·
    /// 같은 특수 행 나열(검색어가 있으면 특수 행이 서지 않는다)으로 rows를 다시 돌려 잰다.
    static func showsNoResultNote(query: String, lookup: EditField.Lookup,
                                  favorites: [EditField.Option]) -> Bool {
        guard case .empty = lookup else { return false }
        return rows(query: query, specials: [], favorites: favorites, candidates: []).isEmpty
    }
}

/// 수동 활동 카드 '현재 위치' 행의 위치 해석(O-B6) — 권한 판정과 측위 대기를 한 곳에 둔다. 대기
/// 루프의 파생식(측위 시한 + 1초, 바닥 5초)과 재확인 간격은 AddEventView.prefillOrigin이 써 온
/// 값 그대로인데, 그 벌과 AIAssistant.currentPlace를 이 자리로 모으는 일은 그 화면들을 고칠
/// 단계(SPEC-UIKIT-018, plan §4-1)의 몫이라 지금은 사본이 산다 — 이 함수가 모일 자리다.
@MainActor enum PlaceLineResolve {
    /// 권한이 거부·제한이면 '현재 위치'는 줄 값이 될 수 없다 — 영영 오지 않는 위치를 기다리는
    /// 죽은 대기 대신 안내 문구로 막는다(AddEventView.prefillOrigin과 같은 판정).
    static func isLocationBlocked(_ location: LocationManager) -> Bool {
        location.authorizationStatus == .denied || location.authorizationStatus == .restricted
    }

    /// 권한 거부 안내(출발지 줄) — AddEventView.syncFieldExtras의 문구 원문(O-B3: 새 문구를 만들지
    /// 않는다). 그 화면은 이 단계의 대상 밖(O-B1)이라 글자가 두 벌로 살 수밖에 없고 018이 한 벌로 모은다.
    static let locationPermissionNote =
        "위치 권한이 꺼져 있어요. 시스템 설정에서 허용하거나 출발지를 직접 검색해 골라 주세요."

    /// 권한 거부 안내(장소 줄) — 리드 결정 O-S1-4: 장소 줄에는 '출발지'라는 낱말이 맞지 않아
    /// 출발지 줄 문구에서 그 낱말 하나만 '장소를'로 바꿨다. 그 밖은 같은 문장이다(O-B3의 정신).
    static let locationPermissionNoteForPlace =
        "위치 권한이 꺼져 있어요. 시스템 설정에서 허용하거나 장소를 직접 검색해 골라 주세요."

    /// 대기 끝에 도착한 위치를 줄에 받아들일지의 단일 판정(R1, AC-015) — 기준은 "비어 있었나"가
    /// 아니라 "대기를 시작한 뒤 줄 값이 그대로인가"다. 옛 가드(`chosen == nil`)는 수정 카드처럼
    /// 값이 미리 채워진 줄에서 '현재 위치'를 눌러도 도착한 위치를 영영 버렸다. 기다리는 사이 사용자가
    /// 다른 행을 골랐으면 값이 달라져 버린다(덮어쓰지 않는다). chosen 문자열만 비교한다 —
    /// 같은 라벨의 다른 좌표로 바뀐 경우까지 가르려면 좌표 비교가 필요하나, 그 경우는 사용자가 같은
    /// 행을 다시 고른 것이라 도착한 위치를 받아도 뜻이 어긋나지 않는다.
    static func adoptsArrivedPlace(chosenAtWaitStart: String?, chosenNow: String?) -> Bool {
        chosenAtWaitStart == chosenNow
    }

    /// 이미 잡혀 있는 좌표로 Place를 만든다(없으면 nil) — 대기 없이 확정되는 길.
    static func availablePlace(_ location: LocationManager) -> Place? {
        guard let c = location.currentLocation else { return nil }
        return Place(name: location.currentPlaceName ?? "현재 위치",
                     address: "", latitude: c.latitude, longitude: c.longitude)
    }

    /// 위치를 얻을 때까지 기다려 Place를 돌린다(권한 거부·시한 초과면 nil). sleep은 취소되면 즉시
    /// 반환하므로 0.2초마다 취소와 좌표를 함께 재확인한다(대기가 빠르게 도는 것을 막는다).
    static func waitForCurrentPlace(_ location: LocationManager) async -> Place? {
        guard !isLocationBlocked(location) else { return nil }
        if location.currentLocation == nil { location.useCurrentLocation() }
        // 시한은 LocationManager의 측위 시한에서 파생한다(계약 5) — 여기가 짧으면 시한 직후에 오는
        // 위치가 빈 줄을 채우지 못한다(t11 sync N5). max(5, ·)는 측위 시한이 짧은 맥의 행동을 지킨다.
        let waitSeconds = max(5, LocationManager.locateTimeoutSeconds + 1)
        for _ in 0..<Int(waitSeconds / 0.2) {
            if Task.isCancelled { break }
            if let place = availablePlace(location) { return place }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }
}

/// 앱이 직접 물을 인자 하나 = 카드의 한 줄.
///
/// 되묻는 주체가 모델이 아니라 앱인 이유: 이 모델은 선언된 선택 인자를 비워두지 못하고 전부
/// 채운다(b303f41 — 저장해둔 여유 10분이 0으로 덮여 35건이 등록되고도 아무도 몰랐다).
/// "비워둬라"·"물어봐라"는 이 프로젝트에서 가장 안 지켜지는 지시였고 두 번 실패했다.
/// 그래서 이 인자들은 툴 선언에서 아예 뺐다 — 모델이 채울 수 없어야 앱이 "비었다"를 관측한다.
// @MainActor를 명시하는 이유: 중첩 타입은 바깥 클래스의 배우 격리를 상속하지 않는다. 이
// 줄의 해석(accepts·customLabel)이 BesirTime의 포매터·파서를 쓰는데, 격리가 없으면 MainActor
// 정적 멤버를 부를 수 없다. 실제 호출자(뷰·AIAssistant·드라이버의 @MainActor 진입점)는 전부
// MainActor라 자연스럽다.
@MainActor struct EditField: Identifiable {
    /// 고른 문자열을 툴 인자로 되돌릴 때 쓰는 해석 방식.
    /// 줄마다 받아들이는 범위가 달라서 종류를 나눈다 — 여유와 알림은 상한이 다르다
    /// (여유는 Store가 180분에서 묶고, 알림은 "하루 전에 알려줘"가 실제 요청이라 안 묶는다).
    enum Kind {
        // '반복' 줄(019)은 새 case 없이 .title 칸을 쓴다(O-E8·L-33 — 카드 안에 입력 문법이 둘이 되지 않게).
        case place, mode, buffer, notify, title, datetime
        // 칩에서 **하나를 고르는** 줄. 원래 불(예·아니요) 칩 둘을 위한 것이었는데(SPEC-ASK-001
        // D-2), 칩 셋 중 하나 고르기(반복 수정의 "체류/점심/둘 다", J-36)도 같은 문법에 얹는다 —
        // 새 Kind를 만들면 카드 안에 문법이 둘이 되어 줄마다 익히는 법이 둘이 된다(D-2). 직접입력은
        // 없고(allowsCustom false), 고른 값이 없으면 확인이 영원히 풀리지 않으므로(isReady), 불
        // 줄은 생성 시 "true"/"false"로 chosen을 seed한다.
        case toggle
        // 읽기 전용 값 줄(SPEC-UIKIT-018 REQ-009) — "말씀하신 대로" 줄이 사라지면서 그 줄만 보이던
        // 값 가운데 사용자가 고르는 값이 아닌 것(수정 카드의 고칠 일정·날짜)의 자리다. 값은 chosen에
        // 실려 오고 accepts가 전부 거절해 확정 통로가 없다 — 확인 주입은 이 줄의 키를 묻지 않으므로
        // 모델이 보낸 값이 그대로 살아간다. toggle을 재사용하지 않은 이유: 값을 내는 문법(하나뿐인
        // 선택지)이지 고르는 문법이 아니라서 뜻이 다른데 이름까지 빌리면 다음 줄이 toggle인지
        // readonly인지 코드가 말해 주지 않는다.
        case readonly
    }
    struct Option: Identifiable {
        let id = UUID()
        /// 칩 글자는 소유 화면이 확정 뒤에 고칠 수 있다(현재 위치 칩에 지명을 얹는 확인 경로).
        /// options와 같은 이유로 var — 새 Option으로 갈아끼우면 id가 다시 찍혀 칩 신원이 흔들린다.
        var label: String
        let value: String
        /// 칩 안에 작게 따라붙는 근거 글(이동수단의 소요시간). 고르는 값과 고르는 근거를 같은
        /// 자리에 두는 것이 목적이라 줄 캡션으로 몰지 않는다 — 몰면 어느 칩이 어느 시간인지
        /// 눈으로 다시 맞춰야 한다. 기본값이 있어 기존 생성부는 한 줄도 바뀌지 않는다.
        var detail: String? = nil
        /// 즐겨찾기 옵션의 좌표 — 장소 줄 목록의 행이 자기 Place를 직접 실으려면 옵션에 좌표가
        /// 붙어 있어야 한다(REQ-005: 같은 라벨 즐겨찾기 둘의 좌표가 라벨로 섞이지 않게). 좌표
        /// 없는 옵션(옛 생성부)은 라벨로 고르는 길로 남는다. 기본값이 있어 기존 생성부는 무변경이다.
        var place: Place? = nil
    }
    let id = UUID()
    /// 툴 인자 이름. 확인 시 이 키로 값이 실린다.
    let key: String
    let kind: Kind
    let label: String
    /// 칩의 소요시간(detail)은 이동시간 계산이 돌아온 뒤 소유 화면이 채운다 — 그때 줄을 통째로
    /// 새로 만들면 id가 바뀌어 줄 에디터의 지역 상태가 흩어지므로(REQ-021), 배열째 제자리에서
    /// 고칠 수 있어야 한다.
    var options: [Option]
    /// 칩만으로 모든 값을 열거할 수 없는 줄에만 붙인다. 이동수단은 세 칩이 곧 전체 집합이라
    /// 붙이지 않는다(승인된 카드 형태 그대로 — 직접입력이 없어도 못 고르는 값이 없다).
    let allowsCustom: Bool
    /// 이 줄이 **왜 떴는지** 한 줄로. 값이 차 있는데 앱이 풀지 못할 때만 붙는다("회사"라고
    /// 말했는데 그 이름의 즐겨찾기가 없는 경우) — 말한 적 없는 값을 묻는 줄과 겉모습이 같으면
    /// 사용자는 "방금 말했는데 왜 또 묻지"로 읽는다. 빈 값을 묻는 평범한 줄에는 nil이다.
    var note: String? = nil
    /// 장소 줄의 검색 상태. 장소는 **후보를 탭해서** 고르는 것이 정상 경로다 — 자유 텍스트를
    /// 그대로 확정하면 좌표가 없어, 카드를 다 채우고 확인을 누른 **뒤에야** 실행부의 검색이
    /// 실패한다("'ㅁㄴㅇㄹ' 위치를 찾지 못했어요" — 2026-09-16 실기기 결함 P). 가장 늦게
    /// 알게 되는 실패를 가장 이른 자리로 옮기는 것이 이 상태의 존재 이유다.
    enum Lookup { case idle, searching, results([Place]), empty }
    var lookup: Lookup = .idle
    /// 사용자가 고른 원시 값. nil이면 아직 안 골랐다 — 확인 버튼이 잠긴다.
    var chosen: String? = nil
    /// 줄이 진행 중임을 알리는 깃발. 카드 뷰는 순수 값 뷰라 외부 상태를 스스로 관찰할 수
    /// 없어, 소유 화면이 자기 상태(현재 위치 찾기·이동시간 계산)를 이 값으로 줄에 잇고 바꿔
    /// 재렌더를 일으킨다. 참이면 줄 이름 옆에 작은 ProgressView가 뜬다.
    var busy: Bool = false
    /// 카드가 뜰 때 에디터를 열어두는 줄(제목·목적지처럼 새 일정마다 반드시 새로 치는 값).
    /// 칩 문법은 칩을 먼저 탭해야 입력칸이 열리므로 이 깃발이 없으면 주 경로에 탭이 하나
    /// 늘어난다. 소유 화면이 카드를 완성한 뒤에 띄운다는 전제로 뷰가 onAppear에서 씨앗을
    /// 뿌린다. AI 후보 카드(U-4)는 후보를 미리 얹은 줄에서 이 깃발을 켠다(D-6 (a)) — 후보가
    /// 카드 안에 있으면서도 첫 화면에서는 보이지 않는 일이 없게 한다.
    var startsOpen: Bool = false
    /// 후보 카드가 미리 얹은 검색 낱말(O-S1-1 (나)) — 뷰가 검색창을 열 때 씨앗으로 심는다.
    /// startsOpen과 짝이면 카드가 뜰 때부터 글자가 있는 갈래(맞는 즐겨찾기 → 후보)로 열리고,
    /// 홀로 오면 닫힌 줄을 열 때 그 낱말로 시작한다 — AI 활동 카드가 말한 장소를 줄에 심어 두는
    /// 갈래다(018 REQ-009: 앱이 못 푼 값은 그 줄에서 고르게 하되 낱말은 남긴다). 이미 실린
    /// 후보를 다시 검색하지는 않는다.
    var searchSeed: String? = nil
    /// 시각 줄이 도착/출발 기준을 갖는지. 활동의 시작·종료처럼 기준 없는 시각은 false로 만들며,
    /// 그런 줄은 기준 칩이 없고(REQ-002) 확정이 chooseTimePlain으로 간다(REQ-001 (d)). 기본값이
    /// true인 이유는 기존 생성부(AddEventView·AIAssistant)가 전부 기준 있는 줄이라 그 둘이 한
    /// 줄도 바뀌지 않게 하려는 것이다.
    var anchored: Bool = true
    /// 이 `.datetime` 줄이 종료 다이얼의 바퀴 규칙(기준·상한·씨앗)을 쓴다는 표시(REQ-020 — S1부터
    /// 시각 줄 전부가 같은 다이얼 부품으로 그려진다, SPEC-UIKIT-016 REQ-006). nil이면 기준 있는 줄
    /// (도착/출발) 또는 확정 경로만 있는 일반 줄이다. 그리는 것은 EditCardView 몫이고 이 모델은
    /// "어느 줄의 날짜에서 출발하는지·상한이 있는지"만 안다.
    var endWheel: EndWheelSpec? = nil
    /// 장소 줄의 특수 행 나열(REQ-003, spec.md §2.1). 칩 문법에서 칩이 붙던 조건이 그대로 행으로
    /// 옮겨온 것이라 여기가 줄별 구성의 단일 출처이다(PlaceLineSpecials). 기본값이 빈 배열이라
    /// 이 속성을 모르는 생성부(AddEventView 등)의 줄은 한 줄도 바뀌지 않는다.
    var placeSpecials: [String] = []
    /// 글은 바뀌었는데 아직 해석되지 않은 '반복' 줄(SPEC-UIKIT-019 REQ-004 — 칸을 마칠 때 해석한다). 그동안은 확인이
    /// 잠긴다: 쓰다 만 글로 저장되면 고친 글과 다른 규칙(또는 한 번짜리)이 조용히 만들어진다. busy를 쓰지 않은 이유:
    /// busy는 줄 옆에 진행 표시를 띄우는 깃발이라 글자를 치는 동안 줄곧 돌게 된다. 다른 줄은 늘 false다.
    var pendingCommit: Bool = false

    var chosenLabel: String? {
        guard let chosen else { return nil }
        return options.first { $0.value == chosen }?.label ?? Self.customLabel(kind, chosen)
    }
    static func customLabel(_ kind: Kind, _ value: String) -> String {
        switch kind {
        case .buffer, .notify: return "\(value)분"
        // .toggle 가지는 컴파일 강제일 뿐 실행 중 오지 않는다 — 토글 줄은 allowsCustom이
        // false라 칩 밖에서 온 값(customLabel의 유일한 호출 경로)이 생기지 않는다.
        // 장소 줄의 값이 토큰이면 표시 문구로 푼다 — 옵션 배열에 칩이 없는 생성부(시드의 빈
        // placeOptions)에서도 "__no_place__" 따위가 글자로 새지 않는다(displayText 머리말).
        case .place: return PlaceTokens.displayText(value)
        case .mode, .title, .toggle, .readonly: return value
        case .datetime:
            // "arr:2026-09-17T15:00:00" → "도착 9월 17일 (목) 오후 3:00" — 기준이 글자로 박혀
            // 나간다(확정 요약·재오픈 칩 모두 이 문구를 쓴다). 기준 글자는 anchor(ofPrefix:)의
            // 답으로만 정한다 — 여기서 접두를 다시 읽으면 해석이 두 곳에 살고(계약 5) ""(기준
            // 없는 시각)이 "출발"로 박혀 나간다.
            return BesirTime.parseDatetime(value).map { parsed in
                switch BesirTime.anchor(ofPrefix: parsed.prefix) {
                case .arrival: return "도착 " + BesirTime.when(parsed.date)
                case .departure: return "출발 " + BesirTime.when(parsed.date)
                case nil: return BesirTime.when(parsed.date)
                }
            } ?? value
        }
    }

    /// 직접입력 값을 받아들일지 판정한다. 범위 밖을 카드에서 막아야 실행부까지 흘러가지 않는다.
    /// 빈 입력은 어떤 줄에서도 제출되지 않는다.
    func accepts(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        switch kind {
        // .toggle도 컴파일 강제 가지다 — 토글 줄은 직접입력 에디터가 없어 accepts가 불리지 않는다.
        // .readonly는 값이 아니라 보이기만 하는 줄이라 무엇도 받지 않는다.
        case .readonly: return nil
        case .place, .title, .toggle: return t
        case .mode: return TransportMode(rawValue: t) != nil ? t : nil
        case .buffer:
            guard let v = Int(t), (0...Store.maxBufferMinutes).contains(v) else { return nil }
            return String(v)
        case .notify:
            // 카드 입력의 상한일 뿐 저장값의 상한이 아니다 — clampNotifyLead는 위로 묶지 않는다.
            // 하루(1440분) 전 알림까지는 실제 요청이고, 그 밖은 오타로 본다.
            guard let v = Int(t), (0...1440).contains(v) else { return nil }
            return String(v)
        case .datetime:
            // 뷰의 DatePicker가 만든 값의 불변식 게이트다(시각 줄에는 텍스트 입력 경로가 없다) —
            // 접두(도착/출발) + 정규 ISO만 받아들이고 통과하면 정규화해 돌려준다. 접두 없는 정규
            // ISO도 받는다 — parseDatetime이 ""를 푼다(REQ-001 (a)).
            return BesirTime.parseDatetime(t)
                .map { $0.prefix + BesirTime.isoFormatter.string(from: $0.date) }
        }
    }

    // ── t62(SPEC-UIKIT-014): 직접 넣은 값 칩 유지 ── 이 규칙들이 뷰 안에 있으면 드라이버가
    // 닿지 못해 경계(추가 칩은 많아야 하나 등)가 시뮬레이터 실행에서만 판정된다. 모델의 순수
    // 멤버로 두면 매 빌드마다 결정적으로 검사되고, 판정이 두 곳에 살지도 않는다(계약 5).

    /// 직접 넣은 값 — `chosen`이 칩 목록 어디에도 없을 때만 산다. 이 판정의 유일한 출처이고,
    /// 뷰의 typedLabel도 아래 두 규칙도 이것만 읽는다.
    var typedValue: String? {
        guard let chosen, !options.contains(where: { $0.value == chosen }) else { return nil }
        return chosen
    }

    /// 칩 문법의 '직접입력' 칩 글자 — 숫자 줄(여유·알림)이 아직 칩 문법이라 뷰가 여기서
    /// 읽는다. 리터럴이 모델에 사는 이유는 두 가지다: 칩 글자의 단일 출처(계약 5)이고, 제목 줄이
    /// 칩 문법을 잃으며(S1, REQ-001) 이 글자를 쓰는 줄이 숫자 줄로 좁혀진 사실을 AC-001 grep이
    /// 뷰 파일에서 잰다 — 글자가 뷰에 남으면 제목 줄이 다시 칩으로 돌아갔는지와 구분되지 않는다.
    static let customEntryChipLabel = "직접입력"

    /// 직접 넣은 값을 다른 칩 탭에도 남겨 두는 줄 — 여유·알림뿐이다(옛 반복 기간 줄은 019에서 없어졌다). 장소는 choose가 좌표
    /// 사전과 줄 구성을 함께 바꾸고, 나머지는 덮어쓸 다른 칩이 없거나 직접입력 자체가 없다.
    /// 전수 switch라 새 Kind가 생기면 기억 여부를 다시 정하도록 컴파일러가 강제한다.
    var keepsTypedValue: Bool {
        switch kind {
        case .buffer, .notify: return true
        case .place, .mode, .title, .datetime, .toggle, .readonly: return false
        }
    }

    /// 옵션 칩으로 떠날 때 새로 기억할 값. 정규형(accepts가 그대로 돌려주는 값)만 기억한다 —
    /// "04" 같은 비정규 시드까지 기억하면 그릴 때의 옵션 값 비교가 틀려진다(REQ-005). 기억하지
    /// 않는 사례(옵션 값·nil·제외 줄·범위 밖·비정규)는 previous를 통째로 돌려준다 — 여기서
    /// 지우면 남은 칩이 말없이 사라져 칩 수 불변(REQ-002)과 모순된다.
    func valueToKeep(onLeaving previous: String?) -> String? {
        guard keepsTypedValue, let typed = typedValue, accepts(typed) == typed else { return previous }
        return typed
    }

    /// 옵션·직접입력 칩 외에 이 줄에 그릴 추가 칩 — 많아야 하나다. 선택된 직접 값이 있으면 그것이
    /// 이기고(다음에 옵션 칩으로 떠날 때 기억 칸 하나를 덮어쓴다), 아니면 기억한 값이 옵션과 다를
    /// 때만 미선택 칩으로 남는다. 둘을 함께 돌려주는 경로가 없다는 것이 이 함수의 계약이다.
    func extraChip(kept: String?) -> (value: String, label: String, selected: Bool)? {
        if let typed = typedValue {
            // typed가 살아 있으면 chosen이 반드시 있고 옵션이 아니므로 chosenLabel도 항상 산다 —
            // 폴백은 타입을 맞추는 것일 뿐 실행 중 도달하지 않는다.
            return (typed, chosenLabel ?? typed, true)
        }
        guard let kept, !options.contains(where: { $0.value == kept }) else { return nil }
        return (kept, Self.customLabel(kind, kept), false)
    }
}

/// 부재 인자를 전부 모은 카드 한 장. 요청당 정확히 한 장이고, 확인을 누르면 보류해 둔
/// 호출이 채워진 인자와 함께 **1회** 실행된다 — 선택과 값 사이에 모델이 끼어들 틈이 없다.
/// parts·stated의 기본값은 화면 카드가 이 둘 없이 카드를 만들기 위한 것 — let에 기본값을
/// 붙이면 멤버와이즈 이니셜라이저에서 빠져 기존 호출부가 깨지므로 var이다.
@MainActor struct EditCard: Identifiable {
    /// 새 일정 폼(AddEventView)의 알림 기본값과 같은 출처 — 상세에서 이동을 처음 켤 때 "30분 전"이
    /// 따로 나오던 불일치(t50 P4-h)를 상수 한 벌로 닫는다. 새 일정 폼도 이 값을 참조한다.
    static let defaultNotifyLead = "10"
    let id = UUID()
    /// 보류해 둔 모델 턴 원본. 확인 시 인자만 채워 히스토리에 넣는다 — 미완성 인자가 담긴
    /// 턴을 히스토리에 먼저 넣으면 다음 요청에 그 값이 계속 딸려간다.
    var parts: [[String: Any]] = []
    /// 사용자가 말로 이미 정한 값(카드에 줄을 만들지 않은 것들). 옛 카드는 이것을 "말씀하신
    /// 대로" 안내 줄로 보였으나 그 줄이 사라지면서(018 REQ-009) 값은 채워진 줄로 옮겨갔고 이
    /// 배열은 늘 빈 채로 남는다 — 드라이버 픽스처가 이 멤버로 카드를 만들어 온 역사가 길어
    /// 구조를 지우는 대신 표시만 폐지했다.
    var stated: [String] = []
    /// 후보 카드(parkForUnclearPlaces)가 인자를 **비워 둔** 키의 기록. 확인 경로의 사전 주입은
    /// 이 키에만 실린다 — 빈 값이면 어디에나 있을 수 있어서다(모델이 안 보낸 키도 비어 있다).
    /// 카드가 비우지 않은 빈 키(같은 턴 다른 호출의 같은 이름 키)에 고른 값을 실으면 그 호출이
    /// 묻지 않은 장소로 조용히 등록된다(sync 1차 D4). 실행 전 카드는 비운 키가 없으므로 공집합.
    var clearedKeys: Set<String> = []
    var fields: [EditField]
    /// 아직 고르지 않은 줄의 이름(SPEC-UIKIT-015 REQ-001). fields 순서를 그대로 지킨다 —
    /// 남은 것 한 줄이 카드에 줄이 벌어진 순서로 이름을 읽어 줘야 눈으로 짝을 맞출 수 있다.
    /// '반복' 줄만 판정이 다르다(SPEC-UIKIT-019 REQ-004): 빈 글은 한 번짜리라 고른 것이고(O-S4-6 축 ①), 글이 있으면
    /// 줄 아래 안내(빠진 항목·오류)가 있거나 아직 해석 전일 때 남은 것이다. 이름은 세부 항목이 아니라 줄 이름 '반복'
    /// 하나다(축 ②) — 세부는 줄 아래 note가 말한다.
    var unchosenLabels: [String] { unchosenFields.map(\.label) }
    /// 남은 줄 자체 — 판정의 단일 출처다(unchosenLabels·isReadyAfterRecurrenceCommit이 이것만 읽는다, 계약 5).
    private var unchosenFields: [EditField] {
        fields.filter { f in
            f.key == RecurrenceLine.key ? (f.note != nil || f.pendingCommit) : f.chosen == nil
        }
    }
    /// 다른 줄은 다 찼고 '반복' 줄이 해석 전이라서만 남은 상태(019 안전성 렌즈 m-4) — 확인·추가를 누르면 먼저 해석을 끝내고
    /// 그 결과로 다시 판정하면 되는 카드다. 버튼이 이 상태에서 꺼져 있으면 눌러도 칸이 마쳐지지 않아 해석이 영영 불리지
    /// 않았다. 안내(note)가 선 '반복' 줄(해석 실패·빠진 항목·0회·상한)은 해석이 끝난 문제라 여기 들지 않고 계속 잠긴다.
    var isReadyAfterRecurrenceCommit: Bool {
        let rest = unchosenFields
        return rest.count == 1 && rest[0].key == RecurrenceLine.key && rest[0].pendingCommit && rest[0].note == nil
    }
    /// 남은 것 한 줄의 변형 셋(REQ-002) — 덜 줄인 것부터. ViewThatFits이 앞에서부터 폭에 맞는
    /// 변형을 고르므로 이 순서가 곧 정보가 줄어드는 순서다. 이름은 label 원문 그대로 쓴다 —
    /// 라벨 자체에 " · "가 들어 있어도 쪼개지 않는다. 이음표와 이름을 구분할 방법이 없고,
    /// 화면의 줄 제목과 다른 문자열로 이름을 재조립하면 짝을 맞추기 어려워지기 때문이다.
    var remainingVariants: [String] {
        let labels = unchosenLabels
        if labels.isEmpty { return ["다 골랐어요"] }
        if labels.count == 1 { return ["남은 것: \(labels[0])", "남은 것 1개"] }
        return ["남은 것: " + labels.joined(separator: " · "),
                "남은 것: \(labels[0]) 외 \(labels.count - 1)개",
                "남은 것 \(labels.count)개"]
    }
    /// 판정의 단일 출처는 unchosenLabels다(REQ-001) — allSatisfy 식을 옆에 두면 같은 계산이
    /// 두 곳에 살아 어긋날 여지가 생긴다(계약 5).
    var isReady: Bool { unchosenLabels.isEmpty }
}

extension EditCard {
    /// 종료 바퀴 줄의 기준 시각 — 모델 쪽 단일 출처다(계약 5). 뷰의 바퀴 그리기와 AIAssistant의
    /// 확정·날짜 거리 환산이 같은 기준을 봐야 "화면은 되는데 실행부는 거절"이 안 생긴다.
    /// 기준 줄이 카드에 있으면 그 줄의 확정값(미확정이면 nil — 바퀴를 세우지 않는다), 없으면 줄이
    /// 세워질 때 실어 둔 고정 기준이다.
    func endWheelBase(for field: EditField) -> Date? {
        guard let spec = field.endWheel else { return nil }
        if let base = fields.first(where: { $0.key == spec.baseKey }) {
            return base.chosen.flatMap { BesirTime.parseDatetime($0)?.date }
        }
        return spec.fixedBase
    }

    /// '지금'의 다음 정각 — 옛 뷰 전용 nextWholeHour(EditCardView)를 모델로 옮긴 것(REQ-006 F1).
    /// '지금'을 인자로 받는 이유: 드라이버가 시각을 고정해 사본 대조를 결정적으로 만들기
    /// 위해서다(AC-012) — 몸통에서 Date()를 직접 읽으면 같은 질문에 답이 매번 달라져 잴 수가
    /// 없다.
    static func nextWholeHour(now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(minute: 0),
                          matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
    }

    /// 시각 다이얼이 처음 서는 자리(REQ-006) — 확정값이 있으면 그 시각, 없으면 줄의 씨앗 규칙을 잇는다.
    /// 옛 EndTimeWheel이 뷰 이니셜라이저 안에서 홀로 계산하던 것을 모델로 옮긴 이유: 씨앗 규칙이 뷰에
    /// 남으면 드라이버가 잴 수 없어 "재오픈한 다이얼이 다른 날에 선다"가 시뮬레이터에서만 판정된다.
    /// 확정값이 있어도 다이얼은 접힌 값 글자로 시작하므로 이 값이 쓰이는 순간은 펼쳐진 직후다.
    /// 씨앗은 세 갈래다(D10): ① 확정값 → 그 시각, ② 바퀴 규칙 줄 → 규칙의 초안(기준이 있을 때만 —
    /// 미확정이면 다이얼 자체가 안 서는 줄이므로 nil), ③ 그 밖 → 다음 정각. 닫을 때 확정하는 씨앗이
    /// 화면이 보인 씨앗과 같아야 하므로(REQ-006 F1, AC-012) 세 갈래 전부가 이 한 곳에서 나온다.
    func dialSeed(for field: EditField, base: Date?, now: Date) -> Date? {
        if let chosen = field.chosen, let d = BesirTime.parseDatetime(chosen)?.date { return d }
        if let spec = field.endWheel {
            // 바퀴 규칙 줄은 기준이 있어야 초안이 산다 — 종료 줄의 기준(시작)이 미확정이면 nil을
            // 유지한다(다이얼이 안 서는 줄이라 닫아도 확정할 것이 없다).
            guard let base else { return nil }
            return spec.draft(base: base) ?? base.addingTimeInterval(3600)
        }
        // 기준도 바퀴 규칙도 없는 줄(새 활동 시작·기준 있는 줄)은 다음 정각이 씨앗이다 — 옛
        // 뷰의 nextWholeHour가 담당하던 갈래.
        return Self.nextWholeHour(now: now)
    }

    /// 다이얼이 고른 시각을 확정 경로에 넘기기 전의 정규화 단일 통로 — 뷰의 다이얼 commit과 닫기
    /// 동작(LegCardForm.closeDial·AIAssistant.closeDial)이 같은 변환을 타야 "화면이 보인 씨앗을
    /// 닫았는데 값이 다르게 확정된다"는 어긋남이 생기지 않는다(계약 5). 반복 끝 줄
    /// (capsAt24Hours)만 시각→절대 시각 합성을 거치고, 합성 자체는 EndWheelSpec.recurringEnd
    /// 한 곳에 산다. 인자로만 사는 계산이라 static도 가능하지만 뷰 갈래가 카드 인스턴스에서
    /// 부르는 것으로 시그니처를 맞췄다(R1·R2 합의).
    func dialCommitCandidate(pick: Date, field: EditField, base: Date?) -> Date {
        if field.endWheel?.capsAt24Hours == true, let base {
            return EndWheelSpec.recurringEnd(pick: pick, base: base)
        }
        return pick
    }

    /// 제목 줄의 확정(REQ-001, S1) — 칸에 적힌 글자가 곧 값이라 화면이 매 입력을 부르는 통로다.
    /// accepts를 그대로 쓰면 빈 트림이 nil로 돌아 옛 chosen이 남는다(칩 문법은 "빈 제출이 없다"가
    /// 전제라 지울 경로가 애초에 없다) — 비움이 곧 값 없음인 칸 문법의 규칙은 이곳 하나다(계약 5).
    /// 수동 두 화면(LegCardForm)과 채팅 카드(AIAssistant)가 같은 몸통을 탄다.
    mutating func setTitleText(field: UUID, text: String) {
        guard let i = fields.firstIndex(where: { $0.id == field }) else { return }
        let t = text.trimmingCharacters(in: .whitespaces)
        fields[i].chosen = t.isEmpty ? nil : t
    }
}

// MARK: - 시각 다이얼의 데이터 규칙(SPEC-UIKIT-016 S1, REQ-006·007)

extension EndWheelSpec {
    /// 반복 끝 시각 줄(REQ-007)의 시각→절대 시각 합성 — 시각만 고르는 다이얼에는 날짜가 없으므로 고른
    /// 시·분을 기준 날에 붙인다. 기준보다 이르면 다음 날(거리 1), 늦거나 같으면 그날(거리 0). '같으면
    /// 그날'이 end == base가 되어 accepts의 end > base에서 거부되는 것은 의도다(REQ-007 "같은 시각은
    /// 기존 확정 규칙에 맡긴다") — 거부 판정이 확정 경로 한 곳에만 산다. 날짜 거리는 applyEndSideChoice가
    /// 확정 날에서 세는 값과 같아야 하므로(드라이버가 양쪽을 대조해 잰다) 합성은 이곳 하나다.
    static func recurringEnd(pick: Date, base: Date, calendar: Calendar = .current) -> Date {
        let tod = calendar.dateComponents([.hour, .minute], from: pick)
        let baseTod = calendar.dateComponents([.hour, .minute], from: base)
        let earlier = (tod.hour ?? 0, tod.minute ?? 0) < (baseTod.hour ?? 0, baseTod.minute ?? 0)
        let day = calendar.date(byAdding: .day, value: earlier ? 1 : 0,
                                to: calendar.startOfDay(for: base)) ?? base
        return calendar.date(bySettingHour: tod.hour ?? 0, minute: tod.minute ?? 0, second: 0, of: day) ?? day
    }

    /// 한 번짜리 종료가 시작을 따라가는 값(SPEC-UIKIT-020) — 새 시작 + (옛 종료 − 옛 시작). 길이는 두 시각 사이의
    /// 경과 시간(초)이다: 달력으로 시·분을 맞추면 서머타임 날 벽시계 길이로 어긋나므로(운영자 결정 C-2) 일부러
    /// 달력을 쓰지 않는다. 카드의 시작 이동(choosePlainTime)과 AI 사진 턴의 모델 간격(imageTurnEnd)이 같은 규칙이라
    /// 식은 이곳 하나다(계약 5) — 반복 끝 바퀴(recurringEnd)는 고른 시각을 지키는 다른 규칙이라 합치지 않는다.
    static func followingEnd(oldStart: Date, oldEnd: Date, newStart: Date) -> Date {
        newStart.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
    }
}

// MARK: - 구간 줄 문법(SPEC-UIKIT-009 MB)

/// 구간 줄 아홉의 키 표 — 리터럴은 이 표에만 산다(AC-006 (9)). 생성 카드·활동 카드·이 파일의
/// 전이와 줄 공장이 전부 이 상수를 읽는다. AI 카드의 어휘(travel_from_query·return_to_query)와
/// 이름이 다른 채로 둔 이유: 사상은 어댑터의 일이고 그 어댑터는 t30의 몫이기 때문이다(REQ-007) —
/// 여기서는 두 화면이 같은 키로 말하게 하는 것만이 목적이다.
@MainActor enum LegRowKeys {
    static let outboundEnabled = "outbound_enabled"
    static let originQuery = "origin_query"
    static let outboundMode = "outbound_mode"
    static let bufferMinutes = "buffer_minutes"
    static let returnEnabled = "return_enabled"
    static let returnQuery = "return_query"
    static let returnMode = "return_mode"
    static let notifyEnabled = "notify_enabled"
    static let notifyLeadMinutes = "notify_lead_minutes"
    /// 장소가 사라질 때 한꺼번에 빠지는 아홉 줄의 집합 — 키 나열이 호출부마다 배열 리터럴로
    /// 흩어져 있으면 열째 줄이 생기는 날 한 자리만 늙는다.
    static let allKeys: Set<String> = [outboundEnabled, originQuery, outboundMode, bufferMinutes,
                                       returnEnabled, returnQuery, returnMode,
                                       notifyEnabled, notifyLeadMinutes]
}

/// 활동의 구간(가는/오는 이동) 줄을 굴리는 값 상태와 전이. 생성 카드(AddActivityView)가 뷰의
/// @State 아홉과 빌더 다섯으로 홀로 들고 있던 것을, 활동 카드(ActivityDetailView)도 같은 문법으로
/// 쓰게 하려고 뷰 밖으로 뽑았다(SPEC-UIKIT-009 REQ-007) — 문법이 두 화면에 벌로 있으면 줄
/// 문구·멤버십 규칙이 어느 한쪽만 늙는다(계약 5). EditField가 @MainActor struct이므로 이 타입도
/// 같은 격리를 따른다(이 파일 머리 주석의 이유와 같다).
///
/// 뷰는 이 값 하나를 @State로 들고 choose만 부른다. 좌표 사전(줄 신원 → Place)과 기억값 아홉이
/// card와 한 몸인 이유: choose의 전이가 셋을 함께 고치는데 뷰 쪽에 흩어 두면 어느 하나만 값을
/// 옮기는 순간 전이가 반쪽으로 도는 문법이 된다.
@MainActor struct LegCardForm {
    var card: EditCard
    /// 후보를 탭한 순간 좌표까지 확정된 장소. 열쇠는 이름이 아니라 **줄 신원**(EditField.id)이다.
    /// 이름으로 걸면 같은 상호의 다른 지점을 두 줄에서 고를 때 나중 쓰기가 앞 줄의 좌표까지
    /// 덮어, 활동 장소와 출발지가 한 좌표가 된다 — 이동 0분짜리 구간에 출발 알람이 활동 시작
    /// 시각으로 잡히고, 화면엔 이름만 보여 어긋난 걸 알 길이 없다. 줄 신원은 생성 때 한 번
    /// 찍히므로 두 줄이 겹칠 수가 없다. 지연 해석 함수는 만들지 않는다(계약 5: 만들면
    /// resolvePlace의 세 번째 구현이 된다).
    var confirmedPlaces: [UUID: Place] = [:]
    /// 즐겨찾기 칩의 옵션과 라벨 → 좌표 씨앗. 칩 탭은 Place를 들고 오지 않고 라벨만 주므로 그
    /// 라벨을 좌표로 푸는 씨앗이 전이에 필요하다 — 카드를 띄우는 화면이 시트가 뜰 때 채워 넣는다.
    var favoriteOptions: [EditField.Option] = []
    var favoritePlaces: [String: Place] = [:]

    // ── 줄이 배열에서 빠져 있는 동안의 기억값(REQ-011). 되살리지 않으면 토글을 껐다 켠 사용자가
    // 방금 고른 출발지·여유를 잃는다 — AddEventView의 lastNotifyLead와 같은 형태다.
    /// 가는 편이 꺼져 있는(또는 장소가 없어 줄 자체가 없는) 동안의 출발지 이름.
    var rememberedOutboundOrigin: String? = nil
    /// 그 출발지의 좌표. 이름만 기억하면 다리를 껐다 켠 사용자가 좌표를 잃는다 — 좌표가 줄 신원에
    /// 걸린 뒤로, 되살린 줄은 신원이 달라 이름으로는 되찾을 길이 없다.
    var rememberedOutboundOriginPlace: Place? = nil
    var rememberedOutboundMode = TransportMode.transit.rawValue
    /// 가는 편이 꺼져 있는 동안의 도착 여유(분).
    var rememberedBuffer = "10"
    /// 오는 편이 꺼져 있는 동안의 도착지 이름.
    var rememberedReturnTo: String? = nil
    /// 그 도착지의 좌표 — 출발지와 같은 이유로 이름과 함께 기억한다.
    var rememberedReturnToPlace: Place? = nil
    var rememberedReturnMode = TransportMode.transit.rawValue
    /// 알림 줄이 꺼져 있는 동안의 마지막 켬/끔 — 다리를 껐다 켜도 알림을 끊은 사실이 되살아나야
    /// 옛 폼과 같다(옛 폼의 알림 스위치는 다리를 꺼도 값을 유지했다).
    var lastNotifyOn = true
    /// 알림 줄이 꺼져 있는 동안의 마지막 리드 값.
    var lastNotifyLead = EditCard.defaultNotifyLead
    /// 장소가 정해져 토글이 처음 태어날 때 켬으로 세울 편 — AI 카드에서 사용자가 출발지·돌아올 곳을 말했는데 장소가 아직 못
    /// 푼 값이라 토글이 설 수 없었던 경우다(운영자 §17 O-E2 "말했으면 켜진 채로" — SIM s3-04·05·06·14·21에서 장소를 고르자
    /// '안 만들기'로 섰다). 수동 카드는 늘 거짓이라 지금 동작(끔) 그대로다.
    var bornOutboundOn = false
    var bornReturnOn = false
    /// '반복' 줄의 해석 상태(SPEC-UIKIT-019). 글자는 줄의 chosen에 살고, 여기는 그 글을 해석한 결과다 — 수동·AI 카드가
    /// 같은 폼 값이라 같은 판정·같은 안내를 탄다(계약 5).
    var recurrence = RecurrenceState()

    /// 해석 결과 하나. `interpretedText`는 이 결과를 낸 글이다 — 줄의 글이 이것과 다르면 아직 해석 전이다.
    /// 규칙이 nil인데 글이 있으면 해석 실패다(도구 미호출·오류·반복 아님으로 읽힘 — REQ-006 "반복을 해석하지 못했어요").
    struct RecurrenceState {
        var interpretedText: String?
        /// 확정 때 실행부로 넘어갈 반복 인자(RecurrenceRule.from(arguments:)가 읽는 꼴). 처음 글(AI 카드)은 호출의 구조
        /// 인자이고, 고쳐 해석한 글은 해석 결과다(L-34) — 어느 쪽이든 이 자리 하나에서 넘어간다.
        var arguments: [String: Any] = [:]
        var rule: RecurrenceRule?
        /// 반복 글에 있던 종료 날짜(그날 포함). 여러 날짜 반복은 목록의 마지막 날이 종료라 이 값을 보지 않는다.
        var endDate: Date?
        /// 해석이 실패한 글(프록시 없음·오프라인·시간 초과·도구 미호출). interpretedText와 따로 두는 이유: 실패한 글을 해석된
        /// 글로 기록하면 칸을 다시 마쳐도 해석을 부르지 않아, 망이 돌아온 뒤에도 글자를 고치기 전에는 풀 길이 없었다(019 안전성
        /// 렌즈 m-3). 이 글이면 안내("반복을 해석하지 못했어요")와 잠금은 그대로이고, 칸을 마치면 다시 해석한다.
        var failedText: String? = nil
        /// 저장해 보니 지금 이후 회차가 없던 (글, 시작 날짜) — 카드의 회차 셈은 지난 회차도 세서(REQ-007 셈 규칙 그대로) 카드가
        /// 풀리는데 저장은 지난 회차를 건너뛰어 0건이 된다(019 안전성 렌즈 m-2). 그 쌍이면 기존 0회 안내로 잠그고, 글이나 시작이
        /// 바뀌면 쌍이 달라져 저절로 다시 판정한다(운영자 §30 — 새 문구 없음).
        var noFutureFor: (text: String, start: Date)? = nil
    }

    /// 칩을 탭했을 때의 전이 — 생성 카드의 choose(field:value:place:)에서 구간 네 분기와 공통
    /// 몸통(값 적기·좌표 걸기)을 그대로 옮겼다. 문구·멤버십·줄 위치가 한 글자도 다르지 않아야
    /// 같은 문법이다(AC-006 (2)가 전 저장소에서 문구가 정확히 한 번 나온다고 잰다).
    /// `place`는 검색 후보를 탭해 지점까지 특정된 경우에만 실려 온다(choosePlace) — 칩 탭은
    /// nil로 들어와 라벨을 즐겨찾기 씨앗에서 푼다.
    mutating func choose(field: UUID, value: String, place: Place? = nil) {
        guard let i = card.fields.firstIndex(where: { $0.id == field }) else { return }
        let key = card.fields[i].key
        card.fields[i].chosen = value
        // 좌표는 값을 적은 그 줄 자리에 건다. 실려 온 place가 즐겨찾기 씨앗을 이기는 순서인 이유:
        // 검색 후보는 지점까지 특정된 값이고 즐겨찾기 라벨은 우연히 같을 수 있는 이름일 뿐이라,
        // 반대로 두면 검색해서 고른 "스타벅스" 홍대점이 즐겨찾기 "스타벅스"의 좌표로 조용히
        // 바뀐다. 씨앗에도 없으면("장소 없음" 칩) nil이 들어가 옛 좌표가 지워진다 — 이름이
        // 열쇠이던 시절엔 열쇠가 바뀌며 저절로 풀리던 자리라, 이제 명시로 갚는다.
        if card.fields[i].kind == .place {
            confirmedPlaces[field] = place ?? favoritePlaces[value]
            // note는 줄이 **왜 떴는지**의 말이라 고르는 순간 낡는다 — 남아 있으면 잡음이다.
            // 장소 줄 전부에 두는 이유: 못 푼 값·같은 이름 캡션 모두 값이 정해지고 나면 같은 잡음이
            // 된다(018 안 A — AI 활동 카드가 이 캡션들을 얹는 줄도 이 전이를 탄다).
            card.fields[i].note = nil
        }
        switch key {
        case "location_query":
            if confirmedPlaces[field] != nil {
                // 실제 장소를 고른 순간 다리 토글 줄이 태어난다 — 옛 화면의 else 가지가 줄 멤버십으로
                // 옮겨온 자리다. "장소 없음"은 즐겨찾기 씨앗에도 검색 결과에도 없어 바로 위에서
                // 이 줄의 좌표가 nil로 지워지므로 이 가지를 타지 않는다. 반복 회차도 예외 없이
                // 여기서 줄이 산다(REQ-011) — 만든 구간이 번호 없이 붙고 그 회차가 반복에서 빠지는
                // 판단은 Store가 안다(REQ-014).
                if !card.fields.contains(where: { $0.key == LegRowKeys.outboundEnabled }) {
                    let at = card.fields.firstIndex(where: { $0.key == "end_iso" }).map { $0 + 1 }
                        ?? card.fields.count
                    // 괄호 설명을 뗀 이유(REQ-008): 줄 이름이 곧 문장이라 설명은 같은 말을 두 번
                    // 하는 군더더기였다 — 방향(가는/오는)만으로 뜻이 닫힌다.
                    card.fields.insert(contentsOf: [
                        legToggleRow(key: LegRowKeys.outboundEnabled, label: "가는 이동"),
                        legToggleRow(key: LegRowKeys.returnEnabled, label: "오는 이동"),
                    ], at: at)
                    // 말한 편은 태어나는 순간 켠다 — 켜는 전이를 그대로 타서 기억값(출발지·좌표·수단·여유)이 되살아나고,
                    // 기억값이 없으면(못 푼 낱말 — AIAssistant의 rememberable) 그 줄이 미선택으로 남은 것에 든다.
                    if bornOutboundOn, let t = card.fields.first(where: { $0.key == LegRowKeys.outboundEnabled }) {
                        choose(field: t.id, value: "true")
                    }
                    if bornReturnOn, let t = card.fields.first(where: { $0.key == LegRowKeys.returnEnabled }) {
                        choose(field: t.id, value: "true")
                    }
                }
            } else {
                rememberTravelValues()
                forgetPlaces([LegRowKeys.originQuery, LegRowKeys.returnQuery])
                card.fields.removeAll { LegRowKeys.allKeys.contains($0.key) }
            }
        case LegRowKeys.outboundEnabled:
            if value == "true" {
                // 칩은 선택 상태를 스스로 가리지 않고 매 탭마다 불린다 — 이미 켠 다리를 다시
                // 탭해도 줄이 겹치면 field()가 첫 줄을 읽어 저장값이 씨앗값으로 굳는다.
                if !card.fields.contains(where: { $0.key == LegRowKeys.originQuery }) {
                    let at = card.fields.firstIndex(where: { $0.key == LegRowKeys.outboundEnabled }).map { $0 + 1 }
                        ?? card.fields.count
                    let rows = outboundRows(origin: rememberedOutboundOrigin,
                                            mode: rememberedOutboundMode,
                                            buffer: rememberedBuffer)
                    // 되살린 줄은 신원이 새로 찍힌다 — 기억해 둔 좌표를 그 새 신원에 다시 건다.
                    // 안 걸면 이름만 살아나고 저장 때 출발지가 nil로 풀려, 다리는 켜졌는데
                    // 출발지 없는 구간이 만들어진다.
                    reseed(rows, LegRowKeys.originQuery, rememberedOutboundOriginPlace)
                    card.fields.insert(contentsOf: rows, at: at)
                }
                ensureNotifyRows()
            } else {
                rememberOutboundOrigin()
                if let m = chosenIn(LegRowKeys.outboundMode) { rememberedOutboundMode = m }
                if let b = chosenIn(LegRowKeys.bufferMinutes) { rememberedBuffer = b }
                forgetPlaces([LegRowKeys.originQuery])
                card.fields.removeAll {
                    [LegRowKeys.originQuery, LegRowKeys.outboundMode, LegRowKeys.bufferMinutes].contains($0.key)
                }
                // 다리가 전부 꺼지면 알림 줄도 근거를 잃는다 — 옛 폼 조건의 멤버십 판이다.
                if chosenIn(LegRowKeys.returnEnabled) != "true" { removeNotifyRows() }
            }
        case LegRowKeys.returnEnabled:
            if value == "true" {
                // 위와 같은 이유 — 켜진 오는 편을 다시 탭해도 줄이 겹쳐 들어가지 않게 멤버십이 가드한다.
                if !card.fields.contains(where: { $0.key == LegRowKeys.returnQuery }) {
                    let at = card.fields.firstIndex(where: { $0.key == LegRowKeys.returnEnabled }).map { $0 + 1 }
                        ?? card.fields.count
                    let rows = returnRows(to: rememberedReturnTo, mode: rememberedReturnMode)
                    // 가는 편과 같은 이유 — 되살린 줄의 새 신원에 기억해 둔 좌표를 다시 건다.
                    reseed(rows, LegRowKeys.returnQuery, rememberedReturnToPlace)
                    card.fields.insert(contentsOf: rows, at: at)
                }
                ensureNotifyRows()
            } else {
                rememberReturnTo()
                if let m = chosenIn(LegRowKeys.returnMode) { rememberedReturnMode = m }
                forgetPlaces([LegRowKeys.returnQuery])
                card.fields.removeAll {
                    [LegRowKeys.returnQuery, LegRowKeys.returnMode].contains($0.key)
                }
                if chosenIn(LegRowKeys.outboundEnabled) != "true" { removeNotifyRows() }
            }
        case LegRowKeys.notifyEnabled:
            lastNotifyOn = value == "true"
            if value == "false" {
                // 끌 때 마지막 값을 기억한 뒤 줄을 뺀다 — 값까지 지우면 다시 켤 때 처음부터
                if let l = chosenIn(LegRowKeys.notifyLeadMinutes) { lastNotifyLead = l }
                card.fields.removeAll { $0.key == LegRowKeys.notifyLeadMinutes }
            } else if !card.fields.contains(where: { $0.key == LegRowKeys.notifyLeadMinutes }) {
                let at = card.fields.firstIndex(where: { $0.key == LegRowKeys.notifyEnabled }).map { $0 + 1 }
                    ?? card.fields.count
                card.fields.insert(notifyLeadRow(chosen: lastNotifyLead), at: at)
            }
        default:
            break
        }
    }

    /// 제목 줄의 확정(REQ-001, S1) — 값 규칙은 EditCard.setTitleText 한 곳에 살고 여기는 form이
    /// 값 타입이라 화면이 갈아끼우는 문법만 맞춘다(choose·choosePlainTime과 같은 자리). 매 입력이
    /// 곧 값이라 화면의 저장이 따로 확정을 재요구하지 않는다(REQ-002).
    mutating func setTitleText(field: UUID, text: String) {
        card.setTitleText(field: field, text: text)
        // '반복' 줄은 같은 칸 문법이되 해석 상태가 따라온다 — 글을 비우면 해석 없이 한 번짜리로 서고(L-34), 고치면
        // 칸을 마칠 때까지 확인이 잠긴다(beginRecurrenceCommit에서 해석).
        guard card.fields.first(where: { $0.id == field })?.key == RecurrenceLine.key else { return }
        if recurrenceText == nil { _ = beginRecurrenceCommit() } else { refreshRecurrenceNote() }
    }

    /// 기준 없는 시각 줄(활동의 시작·종료)의 확정 — 생성 카드와 편집 카드가 같은 몸통으로 따로
    /// 가지고 있던 판정을 이곳으로 모았다(계약 5, P-14). 모을 때 규칙은 옛 두 벌과 한 글자도 다르지 않았다
    /// (F5): 종료가 시작 이하면 문구 원문으로 거절하고 chosen이 생기지 않는다. 시작을 옮기는 쪽은 이후
    /// SPEC-UIKIT-020이 바꿨다 — 확정된 종료가 있으면 종료도 같은 길이로 따라가고, 옛 시작을 읽지 못하거나
    /// 지킬 길이가 없는 쌍(종료 ≤ 옛 시작)일 때만 시작을 종료 뒤로 옮기면 종료를 비워 isReady를 다시 잠근다. 성공 여부를 돌려주는 이유: 거절에는
    /// false가 실려 돌아가고 호출자가 얹은 note가 그 줄에 남아 이유를 말한다 — 카드 뷰의 rejected
    /// 표시는 직접입력 줄 전용이라 시각 줄엔 오지 않는다.
    @discardableResult
    mutating func choosePlainTime(field: UUID, date: Date) -> Bool {
        guard let i = card.fields.firstIndex(where: { $0.id == field }) else { return false }
        if card.fields[i].key == "end_iso",
           let startRaw = card.fields.first(where: { $0.key == "start_iso" })?.chosen,
           let start = BesirTime.parseDatetime(startRaw)?.date,
           date <= start {
            card.fields[i].note = EndWheelSpec.notAfterBaseMessage
            return false
        }
        // 옛 시작은 아래에서 chosen을 덮기 전에 읽는다 — 덮은 뒤에는 새 값뿐이라 길이가 0이 되어 종료가 새 시작에 붙는다.
        let oldStart = card.fields[i].key == "start_iso"
            ? card.fields[i].chosen.flatMap { BesirTime.parseDatetime($0)?.date } : nil
        card.fields[i].chosen = BesirTime.isoFormatter.string(from: date)
        // 거절 사유는 유효 확정과 함께 지운다 — 남아 있으면 방금 고른 값도 거절된 것처럼 보인다.
        card.fields[i].note = nil
        if card.fields[i].key == "start_iso",
           let ei = card.fields.firstIndex(where: { $0.key == "end_iso" }),
           let endRaw = card.fields[ei].chosen,
           let end = BesirTime.parseDatetime(endRaw)?.date {
            if card.fields[ei].endWheel?.capsAt24Hours == true {
                // 반복 끝 바퀴는 시각만 고르는 줄이라 날짜가 시작에 딸려 간다 — 옛 절대 시각을 두면 시작을 며칠 옮긴 뒤 종료가
                // 시작 뒤 24시간 밖에 남아 저장이 조용히 거절되고, 종료를 다시 골라도 안 풀렸다(019 sync F1). 고른 시각은 지킨다(L-28).
                rebaseRecurringEnd(at: ei, start: date)
            } else if let oldStart, end > oldStart {
                // 한 번짜리 종료는 시작을 따라간다 — 종료가 새 시작 앞이든 뒤든 길이(옛 종료 − 옛 시작)를 지킨다
                // (SPEC-UIKIT-020, 운영자 결정 C-1). 앞선 거절 문구는 값이 유효해졌으니 함께 지운다. 길이가 0 이하인
                // 옛 쌍(end > oldStart가 아님)은 지킬 길이가 없어 아래 옛 규칙으로 떨어진다.
                card.fields[ei].chosen = BesirTime.isoFormatter.string(
                    from: EndWheelSpec.followingEnd(oldStart: oldStart, oldEnd: end, newStart: date))
                card.fields[ei].note = nil
            } else if end <= date {
                // 옛 시작을 모르거나 길이를 못 지키는 쌍에서 시작을 종료 뒤로 옮기면 확정된 종료는 무효가 된다 — 옛 폼이
                // 종료>시작 판정으로 저장을 막던 것의 계승. 줄 문법에서는 chosen을 비워 isReady를 다시 잠근다.
                card.fields[ei].chosen = nil
                card.fields[ei].note = EndWheelSpec.notAfterBaseMessage
            }
        }
        // 시작이 바뀌면 이미 해석된 규칙으로 회차를 그 자리에서 다시 센다(SPEC-UIKIT-019 L-22) — 해석은 다시 부르지 않는다.
        // 반복 글 안의 종료 날짜는 글에 박혀 있어 그대로다.
        if card.fields[i].key == "start_iso" { refreshRecurrenceNote() }
        return true
    }

    /// 다이얼을 닫을 때의 동작(REQ-006 F1·REQ-010) — 줄에 값이 있으면 값은 그대로 두고 그 줄의
    /// note만 지운다: 다이얼은 거절 위치에서 직전 값으로 되돌아가므로 확정 경로가 다시 불리지
    /// 않아, 지움이 없으면 거절 문구가 값이 돌아온 뒤에도 남는다(SIM t82-3). 비어 있으면 씨앗을
    /// dialSeed로 구해 dialCommitCandidate를 거쳐 **그 줄이 돌릴 때 쓰는 확정 경로 그대로**
    /// (choosePlainTime)에 넘긴다 — 닫아서 확정되는 값이 돌려서 확정되는 값과 같은 길을 타지
    /// 않으면 어긋난 날 아무도 잡지 못한다(AC-012 사본 대조). 씨앗이 nil(기준 없는 종료 줄)이면
    /// 아무 것도 하지 않는다 — 값이 비어 있는 동안 문구가 남는 것은 REQ-010의 빈 값 예외다.
    mutating func closeDial(field: UUID, now: Date) {
        guard let i = card.fields.firstIndex(where: { $0.id == field }) else { return }
        if card.fields[i].chosen != nil {
            card.fields[i].note = nil
            return
        }
        let base = card.endWheelBase(for: card.fields[i])
        guard let seed = card.dialSeed(for: card.fields[i], base: base, now: now) else { return }
        let candidate = card.dialCommitCandidate(pick: seed, field: card.fields[i], base: base)
        choosePlainTime(field: field, date: candidate)
    }

    /// 닫힌 검색창이 보일 글자(REQ-005) — 좌표 사전(confirmedPlaces)을 이 폼이 쥐고 있으므로
    /// 여기가 단일 몸통이고, 생성 카드(AddActivityView)와 편집 카드(ActivityDetailView) 두 화면이
    /// 같은 글자를 낸다(계약 5 — 판정은 PlaceLine.closedSearchText가 내린다).
    func closedSearchText(field: UUID) -> String {
        guard let f = card.fields.first(where: { $0.id == field }) else { return "" }
        return PlaceLine.closedSearchText(chosen: f.chosen,
                                          confirmedPlace: f.chosen == nil ? nil : confirmedPlaces[field],
                                          favorites: f.options)
    }

    /// '현재 위치' 행을 골랐는데 위치를 얻지 못했을 때(권한 거부·시한 초과) 그 장소 줄을 비운다 — 앞서 고른 값('집')이 남으면
    /// 사용자가 고른 것과 다른 값이 그대로 등록될 수 있다(SIM s3-20). 비우면 남은 것에 들어 확인이 잠긴다. 안내(note)는 실패 이유다.
    mutating func abandonPlaceRow(field: UUID, note: String?) {
        guard let i = card.fields.firstIndex(where: { $0.id == field }) else { return }
        card.fields[i].chosen = nil
        card.fields[i].note = note
        confirmedPlaces[field] = nil
    }

    /// 장소가 사라질 때(장소 없음 칩) 다리 줄 전부의 값을 기억해 둔다 — 다시 실제 장소를 고르면
    /// 토글은 문서화된 기본값(끔)으로 돌아오지만, 토글을 켜면 고르던 값들이 되살아난다.
    /// 장소 줄은 다리를 끈 뒤엔 이미 없다 — 칩이 nil을 돌려도 무조건 넣으면 끌 때 기억한 값까지 지운다.
    private mutating func rememberTravelValues() {
        rememberOutboundOrigin()
        if let m = chosenIn(LegRowKeys.outboundMode) { rememberedOutboundMode = m }
        if let b = chosenIn(LegRowKeys.bufferMinutes) { rememberedBuffer = b }
        rememberReturnTo()
        if let m = chosenIn(LegRowKeys.returnMode) { rememberedReturnMode = m }
        if let l = chosenIn(LegRowKeys.notifyLeadMinutes) { lastNotifyLead = l }
        if let n = chosenIn(LegRowKeys.notifyEnabled) { lastNotifyOn = n == "true" }
    }

    /// 출발지 줄의 이름과 좌표를 함께 기억한다. 둘을 갈라 두지 않는 이유: 좌표가 줄 신원에 걸린
    /// 뒤로, 이름만 기억하면 되살린 줄에서 그 좌표를 되찾을 길이 없다.
    private mutating func rememberOutboundOrigin() {
        guard let f = card.fields.first(where: { $0.key == LegRowKeys.originQuery }), let o = f.chosen else { return }
        rememberedOutboundOrigin = o
        rememberedOutboundOriginPlace = confirmedPlaces[f.id]
    }

    /// 도착지 줄도 같은 이유로 이름과 좌표를 함께 기억한다.
    private mutating func rememberReturnTo() {
        guard let f = card.fields.first(where: { $0.key == LegRowKeys.returnQuery }), let r = f.chosen else { return }
        rememberedReturnTo = r
        rememberedReturnToPlace = confirmedPlaces[f.id]
    }

    /// 아직 배열에 넣기 전인 줄에 기억해 둔 좌표를 건다 — 되살린 줄은 신원이 다르기 때문이다.
    private mutating func reseed(_ rows: [EditField], _ key: String, _ place: Place?) {
        guard let place, let row = rows.first(where: { $0.key == key }) else { return }
        confirmedPlaces[row.id] = place
    }

    /// 줄이 배열에서 빠질 때 그 줄에 걸린 좌표도 놓는다 — 신원이 사라진 좌표는 아무도 되찾지
    /// 못하는데, 놓지 않으면 카드가 사는 동안 사전만 자란다.
    private mutating func forgetPlaces(_ keys: [String]) {
        for f in card.fields where keys.contains(f.key) { confirmedPlaces[f.id] = nil }
    }

    /// 다리가 하나라도 켜지면 알림 줄이 필요해진다 — 캘린더 줄이 있다면 그 앞에, 없으면 '반복' 줄 앞에, 그것도 없으면
    /// 맨 끝에. '반복' 줄은 알림·캘린더 줄을 붙인 뒤에도 늘 마지막이어야 한다(SPEC-UIKIT-019 REQ-001, L-5) — 맨 끝에
    /// 끼우면 토글을 켜는 순간 알림이 반복 줄 뒤로 간다.
    private mutating func ensureNotifyRows() {
        let legOn = card.fields.first(where: { $0.key == LegRowKeys.outboundEnabled })?.chosen == "true"
            || card.fields.first(where: { $0.key == LegRowKeys.returnEnabled })?.chosen == "true"
        guard legOn, !card.fields.contains(where: { $0.key == LegRowKeys.notifyEnabled }) else { return }
        let at = card.fields.firstIndex(where: { $0.key == "calendar_sync" })
            ?? card.fields.firstIndex(where: { $0.key == RecurrenceLine.key }) ?? card.fields.count
        card.fields.insert(notifyToggleRow(chosen: lastNotifyOn ? "true" : "false"), at: at)
        // 꺼져 있던 채로 돌아오는 것이 아니라면 리드 줄이 곧바로 따라온다 — 토글만 홀로 나오는
        // 순간이 없게 한다(켬이 문서화된 기본값이다).
        if lastNotifyOn { card.fields.insert(notifyLeadRow(chosen: lastNotifyLead), at: at + 1) }
    }

    /// 알림 줄을 지우기 전에 마지막 값을 기억한다 — 다리를 다시 켤 때 되살린다.
    private mutating func removeNotifyRows() {
        if let l = chosenIn(LegRowKeys.notifyLeadMinutes) { lastNotifyLead = l }
        if let n = chosenIn(LegRowKeys.notifyEnabled) { lastNotifyOn = n == "true" }
        card.fields.removeAll {
            $0.key == LegRowKeys.notifyEnabled || $0.key == LegRowKeys.notifyLeadMinutes
        }
    }

    // MARK: '반복' 줄(SPEC-UIKIT-019 REQ-001·003·004·007·008)

    /// 지금 '반복' 줄의 글(트림, 비었으면 nil).
    var recurrenceText: String? { chosenIn(RecurrenceLine.key) }

    /// 시작 줄의 날짜 — 회차 셈의 첫 날이자(L-22) 해석 요청에 실을 첫 회차 날짜다.
    var startDate: Date? { chosenIn("start_iso").flatMap { BesirTime.parseDatetime($0)?.date } }

    /// 반복이 확정 가능한 상태로 서 있는지 — 글이 있고, 그 글이 해석됐고, 안내할 문제가 없을 때. 확정(AI 어댑터)·저장
    /// (수동)이 이것을 보고 반복으로 만들지 한 번짜리로 만들지 가른다. 빈 글이면 nil(한 번짜리).
    var activeRecurrence: (rule: RecurrenceRule, arguments: [String: Any], endDate: Date)? {
        guard let row = card.fields.first(where: { $0.key == RecurrenceLine.key }), let text = row.chosen,
              text == recurrence.interpretedText, !row.pendingCommit, row.note == nil,
              let rule = recurrence.rule,
              let end = RecurrenceLine.effectiveEnd(rule: rule, endDate: recurrence.endDate) else { return nil }
        return (rule, recurrence.arguments, end)
    }

    /// 줄 아래 안내를 지금 상태로 다시 세운다 — 해석 뒤·시작 변경 뒤·글 변경 뒤에 부른다. 해석 결과(규칙 문장·회차 수)는
    /// 되보이지 않는다(O-S4-3 (나)) — 안내는 빠진 항목·오류뿐이고 없으면 nil이다.
    mutating func refreshRecurrenceNote() {
        guard let i = card.fields.firstIndex(where: { $0.key == RecurrenceLine.key }) else { return }
        let text = card.fields[i].chosen
        let pending = text != nil && text != recurrence.interpretedText && text != recurrence.failedText
        card.fields[i].pendingCommit = pending
        let noFuture: Bool = recurrence.noFutureFor.map { $0.text == text && $0.start == startDate } ?? false
        card.fields[i].note = (text == nil || pending) ? nil
            : RecurrenceLine.problem(rule: recurrence.rule, endDate: recurrence.endDate, start: startDate)
                ?? (noFuture ? RecurrenceLine.noOccurrence : nil)
    }

    /// 수동 저장이 지금 이후 회차가 없어 아무것도 만들지 못했을 때 화면이 부른다(019 안전성 렌즈 m-2, 운영자 §30) — 지금의
    /// (글, 시작) 쌍에 0회 안내("해당하는 날짜가 없어요")를 걸고 저장을 잠근다. 글이나 시작 줄이 바뀌면 저절로 풀린다.
    mutating func markNoFutureOccurrence() {
        guard let text = recurrenceText, let start = startDate else { return }
        recurrence.noFutureFor = (text, start)
        refreshRecurrenceNote()
    }

    /// 확정하면 지금 이후 회차가 하나도 없을 반복인가(019 안전성 렌즈 m-2, 운영자 §31) — 카드의 회차 셈은 지난 회차도 세서 카드가
    /// 풀리는데 실행은 지난 회차를 건너뛰어 0건이 된다. AI 카드는 수동처럼 저장 뒤 실패를 볼 길이 없어(확인이 카드를 먼저
    /// 소비한다) 확정 **전에** 같은 관문(Store.occurrenceSpan)으로 센다. 반복이 서 있지 않거나 시작·끝을 읽지 못하면 거짓 —
    /// 그 판단은 실행부 방어가 맡는다.
    func hasNoUpcomingOccurrence(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let active = activeRecurrence, let start = startDate,
              let end = chosenIn("end_iso").flatMap({ BesirTime.parseDatetime($0)?.date }),
              let distance = RecurrenceRule.occurrenceEndDayDistance(start: start, end: end) else { return false }
        let startTod = calendar.dateComponents([.hour, .minute], from: start)
        let endTod = calendar.dateComponents([.hour, .minute], from: end)
        return !active.rule.dates(from: calendar.startOfDay(for: start), through: active.endDate, calendar: calendar).contains {
            Store.occurrenceSpan(on: $0, startHour: startTod.hour ?? 0, startMinute: startTod.minute ?? 0,
                                 end: (endTod.hour ?? 0, endTod.minute ?? 0, distance), after: now, calendar: calendar) != nil
        }
    }

    /// 반복 칸을 마칠 때(바깥 탭·Return — REQ-004). 해석이 필요하면 (글, 첫 회차 날짜)를 돌려주고, 필요 없으면 그 자리에서
    /// 상태를 세운 뒤 nil이다: 빈 글은 해석하지 않고 한 번짜리로 선다(L-34 — 종료 줄도 날짜·시각 줄로 돌아간다), 이미 해석한
    /// 글은 다시 부르지 않는다. 해석 호출은 부르는 쪽(AIAssistant.commitRecurrence·수동 화면)이 하고 결과를
    /// applyRecurrenceInterpretation으로 돌려준다 — 폼은 값 타입이라 await를 품지 않는다.
    mutating func beginRecurrenceCommit() -> (text: String, start: Date)? {
        guard card.fields.contains(where: { $0.key == RecurrenceLine.key }) else { return nil }
        guard let text = recurrenceText else {
            recurrence = RecurrenceState()
            setEndRowRecurring(false)
            refreshRecurrenceNote()
            return nil
        }
        if text == recurrence.interpretedText {
            refreshRecurrenceNote()
            return nil
        }
        return (text, startDate ?? Date())
    }

    /// 해석 결과를 그 글에 붙인다. `arguments`가 nil이면 해석 실패다. 결과가 돌아오는 사이 글이 또 바뀌었으면 버린다 —
    /// 옛 글의 결과가 새 글에 붙으면 사용자가 본 글과 다른 규칙이 만들어진다(await 너머 재조회, H1). 반복으로 읽히면
    /// 종료 줄을 시각만 고르는 반복 끝 바퀴로 다시 세운다(L-28 — 이미 고른 시각은 지킨다).
    mutating func applyRecurrenceInterpretation(arguments: [String: Any]?, endDate: Date?, for text: String) {
        guard recurrenceText == text else { return }
        guard let arguments else {
            // 실패는 해석된 글로 남기지 않는다(failedText 주석) — 같은 글로 칸을 다시 마치면 다시 해석한다.
            recurrence = RecurrenceState(failedText: text)
            refreshRecurrenceNote()
            return
        }
        recurrence = RecurrenceState(interpretedText: text, arguments: arguments,
                                     rule: RecurrenceRule.from(arguments: arguments), endDate: endDate)
        if recurrence.rule != nil { setEndRowRecurring(true) }
        refreshRecurrenceNote()
    }

    /// AI 카드의 처음 글(O-S4-9 (나)) — 호출의 구조 인자를 되살린 글을 해석된 글로 심는다. 해석한 적은 없지만 그 인자가
    /// 곧 규칙이라, 고치지 않은 카드는 다시 해석하지 않고 그 인자 + 발화 종료 날짜로 확정된다(L-34).
    mutating func seedRecurrence(text: String, arguments: [String: Any], endDate: Date?) {
        guard let i = card.fields.firstIndex(where: { $0.key == RecurrenceLine.key }) else { return }
        card.fields[i].chosen = text
        recurrence = RecurrenceState(interpretedText: text, arguments: arguments,
                                     rule: RecurrenceRule.from(arguments: arguments), endDate: endDate)
        refreshRecurrenceNote()
    }

    /// 종료 줄의 모양을 반복/한 번짜리에 맞춘다(L-28) — 반복이면 시각만 고르는 바퀴(시작 뒤 24시간 안), 한 번짜리면 날짜·
    /// 시각 바퀴. 이미 고른 끝은 지킨다: 반복으로 갈 때는 고른 시각을 시작 뒤 첫 그 시각으로 옮기고(합성은
    /// EndWheelSpec.recurringEnd 한 곳), 한 번짜리로 갈 때는 반복 끝이 이미 시작 뒤 24시간 안이라 그대로 맞는 값이다.
    mutating func setEndRowRecurring(_ recurring: Bool) {
        guard let i = card.fields.firstIndex(where: { $0.key == "end_iso" }),
              (card.fields[i].endWheel?.capsAt24Hours == true) != recurring else { return }
        card.fields[i].endWheel = recurring ? .recurringEndRow : .manualEnd
        guard recurring, let start = startDate else { return }
        rebaseRecurringEnd(at: i, start: start)
    }

    /// 반복 끝 바퀴인 종료 줄의 고른 시각을 주어진 시작 뒤 첫 그 시각으로 다시 붙인다 — 모양을 바꿀 때(setEndRowRecurring)와
    /// 시작이 옮겨질 때(choosePlainTime)가 같은 합성(EndWheelSpec.recurringEnd)을 한 곳에서 쓴다(계약 5). 종료가 비어 있으면 할 일 없다.
    private mutating func rebaseRecurringEnd(at index: Int, start: Date) {
        guard let raw = card.fields[index].chosen, let end = BesirTime.parseDatetime(raw)?.date else { return }
        let moved = EndWheelSpec.recurringEnd(pick: end, base: start)
        if moved > start {
            card.fields[index].chosen = BesirTime.isoFormatter.string(from: moved)
        } else {
            // 시작과 같은 시각은 반복 끝이 될 수 없다 — 확정 경로(choosePlainTime)와 같은 거절 문구로 다시 고르게 한다.
            card.fields[index].chosen = nil
            card.fields[index].note = EndWheelSpec.notAfterBaseMessage
        }
    }

    /// 수동 새 활동 카드의 줄 정의 — 제목 → 장소 → 시작 → 종료 → (연결 때) 구글 캘린더 → '반복'(늘 마지막, REQ-001).
    /// 뷰(AddActivityView)에 두면 드라이버가 줄 목록을 못 재므로 모델 쪽에 둔다(manualActivityTimeRows와 같은 이유).
    /// `calendarDefaultOn`이 nil이면 구글 미연결이라 캘린더 줄이 없다.
    static func manualNewActivityRows(favorites: [EditField.Option], defaultDay: Date, now: Date,
                                      presetStart: Date?, calendarDefaultOn: Bool?) -> [EditField] {
        var fields: [EditField] = [
            .init(key: "title", kind: .title, label: "활동 제목", options: [], allowsCustom: true),
            manualPlaceRow(label: "장소", favorites: favorites),
        ]
        fields += EditCard.manualActivityTimeRows(defaultDay: defaultDay, now: now, presetStart: presetStart)
        if let calendarDefaultOn { fields.append(calendarSyncRow(defaultOn: calendarDefaultOn)) }
        fields.append(RecurrenceLine.row())
        return fields
    }

    // MARK: 줄 만들기

    private func legToggleRow(key: String, label: String) -> EditField {
        .init(key: key, kind: .toggle, label: label,
              options: [.init(label: "만들기", value: "true"), .init(label: "안 만들기", value: "false")],
              allowsCustom: false, chosen: "false")
    }

    private func outboundRows(origin: String?, mode: String, buffer: String) -> [EditField] {
        // 가는 이동 출발지의 특수 행(운영자 O-B6 "넣음") — 칩과 행 나열이 같은 상수에서 나온다:
        // 따로 적으면 한쪽만 고쳐지는 날 chosenLabel의 라벨과 목록의 행이 어긋난다.
        let specials = PlaceLineSpecials.currentLocation
        return [
            .init(key: LegRowKeys.originQuery, kind: .place, label: "출발지",
                  options: favoriteOptions + specials.map { PlaceTokens.chip($0) },
                  allowsCustom: true, chosen: origin, placeSpecials: specials),
            .init(key: LegRowKeys.outboundMode, kind: .mode, label: "가는 편 이동수단",
                  options: TransportMode.allCases.map { .init(label: $0.title, value: $0.rawValue) },
                  allowsCustom: false, chosen: mode),
            // 이름에 "가는 편"이 붙는 이유: 복귀 구간의 여유는 Store가 0으로 박아 둔다
            // (addActivityWithTravel). "도착 여유"라고만 쓰면 이 줄이 오는 편에도 적용된다고
            // 말하는 셈이 된다(REQ-014).
            .init(key: LegRowKeys.bufferMinutes, kind: .buffer, label: "가는 편 도착 여유",
                  options: [.init(label: "0분", value: "0"), .init(label: "10분", value: "10"),
                            .init(label: "20분", value: "20"), .init(label: "30분", value: "30")],
                  allowsCustom: true, chosen: buffer),
        ]
    }

    private func returnRows(to: String?, mode: String) -> [EditField] {
        [
            .init(key: LegRowKeys.returnQuery, kind: .place, label: "도착지", options: favoriteOptions,
                  allowsCustom: true, chosen: to),
            .init(key: LegRowKeys.returnMode, kind: .mode, label: "오는 편 이동수단",
                  options: TransportMode.allCases.map { .init(label: $0.title, value: $0.rawValue) },
                  allowsCustom: false, chosen: mode),
        ]
    }

    private func notifyToggleRow(chosen: String) -> EditField {
        .init(key: LegRowKeys.notifyEnabled, kind: .toggle, label: "이동 알림 받기",
              options: [.init(label: "받기", value: "true"), .init(label: "안 받기", value: "false")],
              allowsCustom: false, chosen: chosen)
    }

    /// 알림 옵션은 AddEventView.notifyLeadRow와 같은 넷이다 — 두 폼이 다른 보기를 내면 같은
    /// 값을 두 문법으로 배우게 된다(REQ-012).
    private func notifyLeadRow(chosen: String) -> EditField {
        .init(key: LegRowKeys.notifyLeadMinutes, kind: .notify, label: "알림",
              options: [.init(label: "출발 시각", value: "0"), .init(label: "10분 전", value: "10"),
                        .init(label: "30분 전", value: "30"), .init(label: "1시간 전", value: "60")],
              allowsCustom: true, chosen: chosen)
    }

    /// 수동 활동 카드(새 활동·활동 편집)의 장소 줄 — '현재 위치'와 '장소 없음' 행까지 포함해
    /// 모델 쪽에서 지어 준다(REQ-003 (2), §2.1 — 출발지 줄과 같은 체). 줄 정의가 뷰
    /// 파일(AddActivityView)에만 있으면 드라이버가 닿지 못해 장소 줄의 행 문법(AC-004)이
    /// 시뮬레이터에서만 판정된다. 칩을 옵션 배열에도 얹는 것은 chosenLabel이 읽을 값→라벨
    /// 매핑이다(칩과 행 나열이 같은 상수에서 나온다).
    static func manualPlaceRow(label: String, favorites: [EditField.Option]) -> EditField {
        let specials = PlaceLineSpecials.currentLocationAndNoPlace
        return .init(key: "location_query", kind: .place, label: label,
              options: favorites + specials.map { PlaceTokens.chip($0) },
              allowsCustom: true, placeSpecials: specials)
    }

    /// 구글 캘린더 줄(018 REQ-004·O-E4) — AI 활동 카드와 수동 새 활동 카드가 같은 이 공장을 쓴다(수동 카드는
    /// 019부터 manualNewActivityRows를 거친다). 두 카드의 (kind, label) 순서는 AC-005가 잰다.
    static func calendarSyncRow(defaultOn: Bool) -> EditField {
        .init(key: "calendar_sync", kind: .toggle, label: "구글 캘린더에 보이기",
              options: [.init(label: "보이기", value: "true"), .init(label: "안 함", value: "false")],
              allowsCustom: false, chosen: String(defaultOn))
    }

    private func chosenIn(_ key: String) -> String? {
        card.fields.first(where: { $0.key == key })?.chosen
    }
}

// MARK: - '반복' 줄의 글자와 판정(SPEC-UIKIT-019)

/// '반복' 줄의 글자·안내·처음 글 — 수동 새 활동 카드와 AI 활동 카드가 같은 줄과 같은 안내 함수를 쓴다(계약 5).
/// 안내 글은 plan §4 표의 글자 그대로다(운영자 §10 — 이 밖의 설명 문구는 두지 않는다).
@MainActor enum RecurrenceLine {
    static let key = "recurrence_text"
    static let label = "반복"
    /// 입력칸 빈 글자(plan §4 행 8) — 예시는 넣지 않는다(§10 "장소 검색(예...) 대신 장소 검색 한 글자로").
    static let placeholder = "반복"

    static let missingWeekdays = "요일 입력"
    static let missingMonthDays = "매월 며칠 입력"
    static let missingLunarDate = "음력 날짜 입력"
    static let missingDate = "날짜 입력"
    static let missingEndDate = "종료 날짜 입력"
    static let interpretFailed = "반복을 해석하지 못했어요"
    static let tooFar = "종료 날짜가 너무 멀어요"
    static let noOccurrence = "해당하는 날짜가 없어요"
    /// 빠진 항목이 여럿일 때의 이음표(L-9).
    static let joiner = " · "

    /// '반복' 줄 — 기존 `.title` 칸 문법(입력칸 하나, 매 입력이 값)을 쓴다(새 Kind 없음, O-E8·L-33). 빈 글이 한 번짜리다.
    static func row(text: String? = nil) -> EditField {
        .init(key: key, kind: .title, label: label, options: [], allowsCustom: true, chosen: text)
    }

    /// 빠진 항목의 **단 하나의 함수**(REQ-003·004, 계약 5) — 세부 항목은 한 번에 하나(가장 앞 것)이고, 그 뒤에
    /// "종료 날짜 입력"이 붙을 수 있다. 여러 날짜는 마지막 날이 종료라 붙지 않는다(O-D8). 매핑은 plan §4 「행 2 매핑」:
    /// 매월에 날짜도 몇째 주도 없으면 "매월 며칠 입력", 몇째 주만 있고 요일이 없으면 "요일 입력", 요일만 있고 몇째 주가
    /// 없으면 "매월 며칠 입력"(L-21).
    static func missingItems(rule: RecurrenceRule, endDate: Date?) -> [String] {
        var items: [String] = []
        switch rule.unit {
        case .weekly:
            if rule.weekdays.isEmpty { items.append(missingWeekdays) }
        case .monthly:
            if rule.monthDays.isEmpty && !rule.lastDayOfMonth {
                if rule.nthWeekOfMonth == nil { items.append(missingMonthDays) }
                else if rule.weekdays.isEmpty { items.append(missingWeekdays) }
            }
        case .lunar:
            if rule.month == nil || rule.day == nil { items.append(missingLunarDate) }
        case .yearly:
            if rule.month == nil || rule.day == nil { items.append(missingDate) }
        case .dateList:
            if rule.explicitDates.isEmpty { items.append(missingDate) }
        case .daily:
            break
        }
        if rule.unit != .dateList, endDate == nil { items.append(missingEndDate) }
        return items
    }

    /// 실제로 쓰는 종료 날짜 — 여러 날짜 반복은 목록의 마지막 날이다(REQ-003). 나머지는 반복 글의 종료 날짜.
    static func effectiveEnd(rule: RecurrenceRule, endDate: Date?) -> Date? {
        rule.unit == .dateList ? rule.explicitDates.max() : endDate
    }

    /// 줄 아래 한 줄 — 해석 실패 → 빠진 항목 → 회차 0 → 상한 초과 순. 문제가 없으면 nil. 회차는 전개 **전에** 같은
    /// 셈 함수(RecurrenceRule.occurrenceCount)로 센다(REQ-007 — 9999년 종료가 메인 액터를 막지 않게). 시작이 아직
    /// 없으면 세지 않는다 — 그 줄 자신이 남은 것에 들어 확인이 잠겨 있다.
    static func problem(rule: RecurrenceRule?, endDate: Date?, start: Date?, calendar: Calendar = .current) -> String? {
        guard let rule else { return interpretFailed }
        let missing = missingItems(rule: rule, endDate: endDate)
        if !missing.isEmpty { return missing.joined(separator: joiner) }
        guard let end = effectiveEnd(rule: rule, endDate: endDate), let start else { return nil }
        let cap = Store.maxRecurrenceOccurrences
        let n = rule.occurrenceCount(from: calendar.startOfDay(for: start), through: end, limit: cap, calendar: calendar)
        if n == 0 { return noOccurrence }
        if n > cap { return tooFar }
        return nil
    }

    /// AI 카드 반복 줄의 처음 글(plan §4.1 — 운영자 확정 꼴) — 구조 인자에서 읽은 규칙을 같은 꼴의 글로 되살리고, 종료
    /// 날짜가 있으면 붙인다. 시작(첫 회차 날짜)과 같은 해의 날짜는 "M월 D일", 다른 해면 "YYYY년 M월 D일". 요일은 월→일 순
    /// 한 글자를 `·`로 잇고, 여러 날짜는 날짜를 ` · `로 잇되 종료 부분이 없다(마지막 날이 종료).
    static func text(rule: RecurrenceRule, start: Date, endDate: Date?, calendar: Calendar = .current) -> String {
        let startYear = calendar.component(.year, from: start)
        func dateText(_ d: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            let md = "\(c.month ?? 0)월 \(c.day ?? 0)일"
            return c.year == startYear ? md : "\(c.year ?? 0)년 " + md
        }
        let weekdayOrder: [Int] = [2, 3, 4, 5, 6, 7, 1]
        let weekdayNames: [Int: String] = [1: "일", 2: "월", 3: "화", 4: "수", 5: "목", 6: "금", 7: "토"]
        let shortDays: [String] = weekdayOrder.filter { rule.weekdays.contains($0) }.compactMap { weekdayNames[$0] }
        let nthNames: [Int: String] = [1: "첫째", 2: "둘째", 3: "셋째", 4: "넷째", -1: "마지막"]
        func nthText(_ nth: Int) -> String {
            let days = shortDays.map { $0 + "요일" }.joined(separator: "·")
            return [nthNames[nth] ?? "", days].filter { !$0.isEmpty }.joined(separator: " ")
        }
        var parts: [String] = []
        switch rule.unit {
        case .daily:
            parts.append(rule.interval == 1 ? "매일" : "\(rule.interval)일마다")
        case .weekly:
            if let nth = rule.nthWeekOfMonth {
                // 단위 이름 없이 요일 + 몇째 주로 온 옛 모양은 "매월 n째 요일"이다(같은 날짜를 낸다).
                parts += ["매월", nthText(nth)]
            } else {
                let n = rule.everyNWeeks
                parts.append(n == 1 ? "매주" : n == 2 ? "격주" : "\(n)주마다")
                if !shortDays.isEmpty { parts.append(shortDays.joined(separator: "·")) }
            }
        case .monthly:
            parts.append(rule.interval == 1 ? "매월" : "\(rule.interval)개월마다")
            var days: [String] = rule.monthDays.sorted().map { "\($0)일" }
            if rule.lastDayOfMonth { days.append("마지막 날") }
            if !days.isEmpty { parts.append(days.joined(separator: "·")) }
            if let nth = rule.nthWeekOfMonth, !rule.weekdays.isEmpty { parts.append(nthText(nth)) }
        case .yearly:
            parts.append(rule.interval == 1 ? "매년" : "\(rule.interval)년마다")
            if let m = rule.month, let d = rule.day { parts.append("\(m)월 \(d)일") }
        case .lunar:
            parts.append("음력 매년")
            if let m = rule.month, let d = rule.day { parts.append((rule.isLeapMonth ? "윤" : "") + "\(m)월 \(d)일") }
        case .dateList:
            return rule.explicitDates.sorted().map { dateText($0) }.joined(separator: " · ")
        }
        if rule.skipHolidays { parts.append("공휴일 빼고") }
        if let endDate { parts.append(dateText(endDate) + "까지") }
        return parts.joined(separator: " ")
    }
}

// MARK: - 편집 카드의 시드 · 저장 diff(SPEC-UIKIT-009 MB, design §2·§3)

/// 편집 카드의 저장 diff가 내는 연산 한 개. 뷰는 이 목록을 **제거 → 수정 → 추가** 순서로
/// 하나씩 직렬 실행한다(design §3 저장 순서 — 제거를 먼저 해야 추가의 중복 검사가 빈자리를
/// 보고, 구간 수정은 updateEvent의 await 전 스냅샷 되쓰기 위험 때문에 갱신 사이에 다른 갱신을
/// 끼우지 않는다). 시드와 diff가 이 파일에 사는 이유는 문법(B1)과 같다 — 드라이버가 뷰 없이
/// 컴파일해야 AG-011 단언이 가능하다.
enum LegSaveOp {
    case remove(legId: UUID)
    /// nil 인자는 "그 값은 그대로 둔다"다(updateLeg의 옵션 인자와 같은 규칙).
    case update(legId: UUID, role: ScheduleAnchor, outerPlace: Place?, mode: TransportMode?,
                bufferMinutes: Int?, notifyLeadMinutes: Int?, notifyEnabled: Bool?)
    case add(role: ScheduleAnchor, outerPlace: Place, mode: TransportMode, bufferMinutes: Int,
             notifyLeadMinutes: Int, notifyEnabled: Bool)
}

extension LegCardForm {

    /// 편집 카드의 시드(design §2 시드 문단). 기본 줄 넷을 만든 뒤 **전이 자체를 돌려** 구간 줄을
    /// 세운다 — 시드가 줄을 손으로 배열하면 생성 카드의 전이와 순서가 어긋나는 날 AG-006-06이
    /// 늙는다(전이를 재사용하면 그 단언을 코드가 지킨다). 토글의 초기값은 전이의 "false"를
    /// 덮어 쓰지 않고, 구간이 있는 역할만 다시 "true"로 고른다.
    ///
    /// 반복 회차도 다른 활동과 같은 규칙으로 시드한다(REQ-011) — 명시적 연결이 있으면 그 구간으로
    /// 시드하고, 없으면 장소가 확정된 순간 토글이 꺼진 채로 선다. 같은 반복·같은 날·같은 장소 이름의
    /// 이벤트가 배치 묶음 추정에 걸려 보여도 시드는 명시적 연결만 본다. 장소가 없는(또는 지워진)
    /// 활동은 전이의 "좌표 없는 값" 가지가 아홉 줄을 전부 빼므로 부재 상태가 된다.
    static func seeded(activity: ActivityBlock,
                       outbound: ScheduledEvent?,
                       returnLeg: ScheduledEvent?,
                       noPlaceValue: String,
                       placeOptions: [EditField.Option],
                       favoriteOptions: [EditField.Option]) -> LegCardForm {
        // 장소 줄 모양은 모델 쪽 공장이 지은다(줄 만들기의 manualPlaceRow 머리말) — chosen은 아래
        // 시드 문법이 얹는다. noPlaceValue는 PlaceTokens.noPlace여야 한다(장소 없음 행의 값과 같은
        // 토큰이어야 chosenLabel과 목록의 행이 어긋나지 않는다).
        let locationRow = LegCardForm.manualPlaceRow(label: "장소", favorites: placeOptions)
        var f = LegCardForm(card: EditCard(fields: [
            .init(key: "title", kind: .title, label: "제목", options: [], allowsCustom: true,
                  chosen: activity.title),
            locationRow,
            .init(key: "start_iso", kind: .datetime, label: "시작", options: [], allowsCustom: false,
                  chosen: BesirTime.isoFormatter.string(from: activity.startDate), anchored: false),
            .init(key: "end_iso", kind: .datetime, label: "종료", options: [], allowsCustom: false,
                  chosen: BesirTime.isoFormatter.string(from: activity.endDate), anchored: false,
                  endWheel: .init(baseKey: "start_iso", capsAt24Hours: false)),
        ]), favoriteOptions: favoriteOptions)
        // 명시적 연결이 있는 회차는 그 구간으로 시드한다 — 활동↔구간 짝은 연결뿐이라는
        // 규칙(legs(of:)와 같다)을 시드도 따른다. 연결 없는 반복 회차도 이 전이를 그대로 탄다
        // (REQ-011 — 옛 가드가 토글조차 못 세우게 막던 자리다. 가드가 일찍 돌아가면 장소 확정까지
        // 건너뛰어 confirmedPlaces가 비고 저장 판정이 clearPlace=true로 굳어져 편집만 열어 닫아도
        // 장소가 지워졌다(t58) — 그 수리의 회귀선 T58-1·2는 이 전이가 좌표를 보존하는 한 그대로다).
        // 장소 칩을 고른 것으로 전이를 돈다 — 좌표가 실리는 순간 토글 둘이 end_iso 뒤에 선다.
        f.choose(field: locationRow.id, value: activity.location?.name ?? noPlaceValue,
                 place: activity.location)
        // 알림 줄의 시드값은 ensureNotifyRows가 기억값에서 읽으므로 토글을 켜기 전에 심는다 —
        // 가는 편(없으면 오는 편) 구간의 알림 설정이 시드다(두 구간이 다른 옛 데이터는 가는 편이
        // 이긴다 — 바꾸지 않은 저장이 어느 구간도 손대지 않는 전제, AC-011 (3)).
        let notifyLeg = outbound ?? returnLeg
        f.lastNotifyOn = notifyLeg?.wantsNotification ?? true
        if let lead = notifyLeg?.notifyLeadMinutes { f.lastNotifyLead = String(lead) }
        if let leg = outbound {
            f.choose(field: f.card.fields.first { $0.key == LegRowKeys.outboundEnabled }!.id, value: "true")
            // 출발지가 nil인 옛 레코드는 줄을 비워 둔다 — 빈 이름을 chosen으로 적으면 isReady가
            // 풀려 좌표 없는 구간이 조용히 저장된다(고르지 않으면 저장이 잠긴 채 사용자에게 맡긴다).
            if let origin = leg.origin {
                f.choose(field: f.card.fields.first { $0.key == LegRowKeys.originQuery }!.id,
                         value: origin.name, place: origin)
            }
            f.choose(field: f.card.fields.first { $0.key == LegRowKeys.outboundMode }!.id,
                     value: leg.mode.rawValue)
            f.choose(field: f.card.fields.first { $0.key == LegRowKeys.bufferMinutes }!.id,
                     value: String(leg.bufferMinutes))
        }
        if let leg = returnLeg {
            f.choose(field: f.card.fields.first { $0.key == LegRowKeys.returnEnabled }!.id, value: "true")
            f.choose(field: f.card.fields.first { $0.key == LegRowKeys.returnQuery }!.id,
                     value: leg.destination.name, place: leg.destination)
            f.choose(field: f.card.fields.first { $0.key == LegRowKeys.returnMode }!.id,
                     value: leg.mode.rawValue)
        }
        return f
    }
}

/// 저장 diff(design §3 표) — (시드, 현재 폼, 시드 때의 구간 둘) → 연산 목록의 순수 함수.
/// (그 역할 기존 구간) × (토글) × (줄이 시드와 다른가)로 동작이 정해지고, 무변경 저장은
/// 빈 목록을 내야 한다(REQ-008의 레코드 바이트 동일이 이 빈 목록에서 나온다).
@MainActor enum LegSavePlanner {
    static func ops(seed: LegCardForm, current: LegCardForm,
                    outboundLeg: ScheduledEvent?, returnLeg: ScheduledEvent?) -> [LegSaveOp] {
        // 공유 알림 줄은 **줄을 바꿨을 때만** 두 구간에 적용한다 — 바꾸지 않은 저장은 어느
        // 구간의 알림도 손대지 않는다(서로 다른 알림 설정의 옛 데이터가 그대로 산다, AC-011 (3)).
        let notifyChanged = chosen(seed, LegRowKeys.notifyEnabled) != chosen(current, LegRowKeys.notifyEnabled)
            || chosen(seed, LegRowKeys.notifyLeadMinutes) != chosen(current, LegRowKeys.notifyLeadMinutes)
        var removes: [LegSaveOp] = []
        var updates: [LegSaveOp] = []
        var adds: [LegSaveOp] = []
        for (role, leg) in [(ScheduleAnchor.arrival, outboundLeg), (.departure, returnLeg)] {
            let toggleKey = role == .departure ? LegRowKeys.returnEnabled : LegRowKeys.outboundEnabled
            // 토글 줄이 아예 없으면 부재(장소 지움)다 — 연결 구간 제거는 modifyActivity의
            // clearPlace 경로가 이미 했으므로 diff는 여기서 아무것도 내지 않는다.
            guard let toggle = current.card.fields.first(where: { $0.key == toggleKey }) else { continue }
            let placeKey = role == .departure ? LegRowKeys.returnQuery : LegRowKeys.originQuery
            let modeKey = role == .departure ? LegRowKeys.returnMode : LegRowKeys.outboundMode
            if toggle.chosen != "true" {
                if let leg { removes.append(.remove(legId: leg.id)) }
                continue
            }
            let outerPlace = current.card.fields.first { $0.key == placeKey }
                .flatMap { $0.chosen == nil ? nil : current.confirmedPlaces[$0.id] }
            let mode = chosen(current, modeKey).flatMap(TransportMode.init(rawValue:))
            let buffer = role == .departure ? nil : Int(chosen(current, LegRowKeys.bufferMinutes) ?? "")
            let notifyLead = Int(chosen(current, LegRowKeys.notifyLeadMinutes) ?? current.lastNotifyLead)
            let notifyOn = chosen(current, LegRowKeys.notifyEnabled) != "false"
            guard let leg else {
                // 좌표 없는 출발지·도착지로는 구간을 만들 수 없다 — addLeg의 outerPlace가
                // 비-Optional이라 여기서 걸러낸다(칩은 chosen이 찍혀도 씨앗이 없으면 좌표가 nil).
                if let outerPlace, let mode {
                    adds.append(.add(role: role, outerPlace: outerPlace, mode: mode,
                                     bufferMinutes: buffer ?? 0,
                                     notifyLeadMinutes: notifyLead ?? 0, notifyEnabled: notifyOn))
                }
                continue
            }
            // "줄이 시드와 다른가" — 그 역할에 속한 줄과 공유 알림 줄을 시드값과 비교한다.
            let placeChanged = chosen(seed, placeKey) != chosen(current, placeKey)
                || placeOf(seed, placeKey) != placeOf(current, placeKey)
            let modeChanged = chosen(seed, modeKey) != chosen(current, modeKey)
            let bufferChanged = role == .departure ? false
                : chosen(seed, LegRowKeys.bufferMinutes) != chosen(current, LegRowKeys.bufferMinutes)
            guard placeChanged || modeChanged || bufferChanged || notifyChanged else { continue }
            updates.append(.update(legId: leg.id, role: role, outerPlace: outerPlace, mode: mode,
                                   bufferMinutes: buffer,
                                   notifyLeadMinutes: notifyChanged ? notifyLead : nil,
                                   notifyEnabled: notifyChanged ? notifyOn : nil))
        }
        return removes + updates + adds
    }

    /// 값 읽기 보조. 구조체를 값으로 받는 것 자체가 순수 함수의 계약이다(원본을 고칠 수 없다).
    private static func chosen(_ f: LegCardForm, _ key: String) -> String? {
        f.card.fields.first { $0.key == key }?.chosen
    }

    private static func placeOf(_ f: LegCardForm, _ key: String) -> Place? {
        f.card.fields.first { $0.key == key }
            .flatMap { $0.chosen == nil ? nil : f.confirmedPlaces[$0.id] }
    }
}

/// 카드가 스스로 그리는 크롬(머리글·확인 문구)을 끄는 스위치. 소유 화면이 자기 제목과 제출
/// 버튼을 이미 갖고 있으면 카드 쪽을 꺼야 한다 — 둘을 다 그리면 제목이 둘, 제출 버튼이 둘로
/// 보인다. nil이면 숨긴다. AI 카드의 기본 문구는 뷰 쪽 기본값에 두고 이 타입엔 없다 — 모델이
/// 특정 화면의 문구를 알면 중립 타입이 아니게 된다.
struct EditCardChrome {
    var header: String?
    var confirmTitle: String?
}

/// 카드 뷰가 값을 소유한 쪽(AIAssistant 등)을 타입으로 모르게 하는 다리 — 뷰가 부르는
/// 여덟 동작을 클로저로 묶어 넘긴다. 값은 Store/AIAssistant에만 있고, 결합이 이 어댑터로
/// 수축한다(네 편집 화면이 같은 카드를 쓰려면 뷰가 특정 소유자를 가져선 안 된다).
struct EditCardActions {
    var chooseValue: @MainActor (UUID, String) -> Void
    var rechooseTimeBasis: @MainActor (UUID, ScheduleAnchor) -> Void
    var chooseTime: @MainActor (UUID, ScheduleAnchor, Date) -> Bool
    /// 기준 없는 시각 줄의 확정 — chooseTime에서 ScheduleAnchor만 뺀 형태. chooseTime의 인자를
    /// 옵셔널로 바꾸는 대신 별도 클로저를 둔 이유는 생성부 둘(AIAssistant·AddEventView)과 그
    /// 안쪽 시그니처가 함께 바뀌지 않게 하려는 것이다(SPEC-UIKIT-003 D-2). 기본값이 있어 기존
    /// 생성부는 무변경이고, 아직 기준 없는 줄을 만들지 않는 화면은 항상 false를 받는다.
    var chooseTimePlain: @MainActor (UUID, Date) -> Bool = { _, _ in false }
    var choosePlace: @MainActor (UUID, Place) -> Void
    var searchPlaces: @MainActor (UUID, String) -> Void
    var submitCustom: @MainActor (UUID, String) -> Bool
    /// 제목 줄의 확정(REQ-001, S1) — 칸 문법은 확인 동작이 없어 매 입력이 이 통로로 흐른다.
    /// 옵셔널인 이유: 옛 단독 이동 편집 화면(AddEventView)은 이 단계 대상 밖(O-B1)이라 어댑터를
    /// 고칠 수 없는데, nil이면 뷰가 옛 확정 경로(submitCustom)로 흘러 그 화면의 제목 입력이
    /// 끊기지 않는다. 새로 카드를 쓰는 화면은 반드시 연결한다.
    var setTitleText: (@MainActor (UUID, String) -> Void)? = nil
    /// 닫힌 검색창이 보일 글자(REQ-005) — 소유자가 자기 좌표 사전과 함께 PlaceLine.closedSearchText를
    /// 부른다. setTitleText와 같은 이유로 옵셔널이다: nil이면 뷰가 chosenLabel 폴백으로 옛 동작을
    /// 유지해 대상 밖 화면(AddEventView, O-B1)이 고장 나지 않는다.
    var closedSearchText: (@MainActor (UUID) -> String)? = nil
    /// 다이얼 닫기 확정(REQ-006 F1·REQ-010) — basis 인자는 기준 있는 줄의 것이다(뷰의
    /// currentBasis). nil이면 뷰는 다이얼을 접기만 한다: 옛 화면(O-B1)은 확정 없이 접히는 옛
    /// 동작이 그대로 남는다. 셋째 인자는 다이얼이 열린 순간 뷰가 한 번 잡은 'now'다(R3, AC-012) —
    /// 화면은 그 now로 씨앗을 보였으므로, 닫을 때 소유자가 새 Date()를 잡으면 분이 넘어간 사이
    /// 보인 씨앗과 확정되는 씨앗이 어긋난다.
    var closeDial: (@MainActor (UUID, ScheduleAnchor?, Date) -> Void)? = nil
    /// '반복' 칸을 마칠 때(바깥 탭·Return — SPEC-UIKIT-019 REQ-004) — 해석은 칸을 마칠 때 한 번이라 매 입력
    /// 통로(setTitleText)와 따로 둔다. setTitleText와 같은 이유로 옵셔널이다: '반복' 줄이 없는 화면은 잇지 않는다.
    var commitRecurrence: (@MainActor (UUID) async -> Void)? = nil
    var confirm: @MainActor () async -> Void
}

/// 장소 검색 묶음(debounce) — **입력이 멈춘 뒤 한 번만** 부르게 만드는 정책의 단일 소유자.
/// 글자마다 부르면 카카오 일일 할당량을 그대로 태운다(이 프로젝트는 외부 한도로 이미 데였다:
/// iOS 알림 64건). 350ms인 이유는 한글 조합이 한 글자를 완성하는 간격보다는 길고
/// ("가"→"강"→"강남"이 한 번으로 묶인다) 다 치고 기다리는 느낌이 나기엔 짧아서다.
///
/// 정책이 이 타입에만 있는 이유는 계약 5(같은 계산은 한 곳에)다 — AI 카드와 이 카드를 빌려 쓸
/// 화면이 각자 지연 시간을 들고 있으면 한쪽만 늙는다. 지연 상수도 이 타입이 유일하게 소유하고,
/// 소유자는 인스턴스를 하나씩 들며 줄 id(UUID)로 서로 다른 줄의 검색을 구분한다.
/// 같은 질의를 건너뛰는 것도 정책의 일부다 — 단 **직전 검색이 완료된 뒤의 같은 질의에만** 내린
/// 다. 방금 진행 중 작업을 끊은 참이면 같은 질의라도 다시 실행한다: 끊긴 작업이 줄에 뿌린
/// '찾는 중'을 되돌릴 주체가 더는 없어서다.
@MainActor struct PlaceSearchDebouncer {
    /// gate의 판정. 호출자는 이 세 갈래를 그대로 따를 뿐 정책을 다시 해석하지 않는다 —
    /// 판단이 밖으로 새면 정책이 두 벌이 된다.
    enum Outcome {
        /// 정리된 질의로 검색을 시작해야 한다.
        case fire(String)
        /// 같은 질의가 이어서 왔다 — 부르지 않고, 상태도 되돌리지 않는다.
        case skip
        /// 입력이 비었다 — 호출자가 줄 상태를 비운다.
        case clear
    }

    /// 지연 시간은 이곳이 유일한 출처다(REQ-010). 350ms.
    private static let delayNanos: UInt64 = 350_000_000

    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 완료된 마지막 질의 — skip 판정의 재료.
    private var lastQuery: [UUID: String] = [:]
    /// 예약(arm)돼 아직 완료되지 않은 질의 — 이번 gate에서 진행 중 작업을 끊었는지 아는 재료.
    private var armedQuery: [UUID: String] = [:]

    /// 새 입력에 대한 판정. 예전 작업은 이 자리에서 끊는다 — gate이 끊어 주지 않으면
    /// 호출자의 취소 실수 하나로 묶음이 아니라 지연된 연쇄 호출이 된다. skip은 **완료된 뒤의
    /// 같은 질의에만** 내린다: 방금 진행 중 작업을 끊었는데 skip을 내리면 그 작업이 줄에 뿌린
    /// '찾는 중'을 되돌릴 주체가 남지 않아 줄이 영원히 찾는 중에 갇힌다(한 글자 지웠다 다시
    /// 치는 정정이 대표 경로) — 끊은 작업이 있으면 같은 질의라도 다시 실행한다.
    mutating func gate(_ key: UUID, _ raw: String) -> Outcome {
        let q = raw.trimmingCharacters(in: .whitespaces)
        let hadLiveTask = armedQuery[key] != nil
        tasks[key]?.cancel()
        tasks[key] = nil
        armedQuery[key] = nil
        guard !q.isEmpty else {
            lastQuery[key] = nil
            return .clear
        }
        if lastQuery[key] == q, !hadLiveTask { return .skip }
        return .fire(q)
    }

    /// 판정이 fire일 때만 부른다. 지연을 기다렸다가 그새 취소되지 않았으면 호출자의 클로저를
    /// 실행한다. 예약 질의를 함께 기록한다 — gate가 "방금 진행 중 작업을 끊었는가"를 아는
    /// 유일한 재료라서, 기록이 남으면 skip이 억제되고 재실행으로 간다.
    mutating func arm(_ key: UUID, _ query: String, fire: @escaping @MainActor () async -> Void) {
        tasks[key] = Task {
            try? await Task.sleep(nanoseconds: Self.delayNanos)
            guard !Task.isCancelled else { return }
            await fire()
        }
        armedQuery[key] = query
    }

    /// 완료한 질의를 기록한다 — **비동기 작업이 돌아온 뒤에만**(호출자는 fire 클로저의 끝에서
    /// 부른다). 예약 시점에 기록하면 아직 도는 검색까지 "완료된 질의"로 세여 skip이 결과를
    /// 덮어써 버린다. 완료 시점에 기록해야 "지우고 다시 친 같은 질의"는 다시 불린다. 드라이버
    /// P-5가 단언 추가 없이 초록인 것이 이 시점이 살아 있다는 증거다. 예약 기록도 함께 지운다 —
    /// 완료한 작업은 더 진행 중이 아니다.
    mutating func noteDone(_ key: UUID, _ query: String) {
        lastQuery[key] = query
        armedQuery[key] = nil
    }

    /// 모든 작업을 끊고 기록을 비운다. 카드가 사라지는 순간(취소·확인)에 불린다.
    mutating func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        lastQuery = [:]
        armedQuery = [:]
    }
}
