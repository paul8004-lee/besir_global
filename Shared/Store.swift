import Foundation
import CoreLocation
#if os(iOS)
import UIKit
#endif

/// 앱 전역 상태: 일정 목록, 설정, 영속화.
@MainActor
final class Store: ObservableObject {
    @Published var events: [ScheduledEvent] = [] { didSet { recomputeDaysWithSchedule() } }
    @Published var config: AppConfig
    @Published var favorites: [FavoritePlace] = []
    /// 이동이 아닌 체류형 활동(수업·근무·점심 등) 시간표 블록.
    @Published var activities: [ActivityBlock] = [] { didSet { recomputeDaysWithSchedule() } }
    /// Repeating activities stored as their rule (SPEC-RECURRULE-001). Occurrences are computed when drawn, never stored.
    /// Changing the list clears the month cache of occurrence titles.
    @Published private(set) var series: [RepeatSeries] = [] { didSet { seriesMonthCache = [:] } }
    /// 식사 기록(be full sir). 시간표에 그리는 블록이 아니라 "무엇을 먹었나"의 이력이라
    /// daysWithSchedule에는 넣지 않는다 — 식당까지 가는 이동은 별도 ScheduledEvent가 담당한다.
    @Published var meals: [MealLog] = []
    /// "이 날짜에 일정이 있는가"만 O(1)로 확인하기 위한 캐시(yyyyMMdd 정수 키).
    /// 월간 캘린더 그리드는 이 값만 보고 점을 찍는다 — events/activities 전체를 매 프레임
    /// 스캔하면(특히 좌우 스와이프 애니메이션 중 여러 번 재계산되며) 버벅임이 생겼다.
    /// 키를 DateComponents가 아니라 Int로 두는 이유: 월간 그리드 한 장을 그릴 때만 42칸 ×
    /// 3페이지 = 126번 조회하는데, DateComponents는 옵셔널 필드가 많은 구조체라 해시 계산이
    /// 눈에 띄게 비싸다(스와이프 중 매 프레임 반복됨).
    @Published private(set) var daysWithSchedule: Set<Int> = []
    /// 월 달력 칸의 날별 활동 제목(REQ-014) — 점(daysWithSchedule)을 정하는 같은 순회에서
    /// 채운다. 값은 그 날에 걸치는 활동 전부를 시작 시각 오름차순으로 담는다(칸에 몇 줄이
    /// 보일지는 뷰가 정하는 일이라 캐시는 전부 둔다 — AC-010 ③). 활동만 담는다(O-C5): 붙은
    /// 이동의 제목("(복귀)" 등)과 옛 단독 이동은 점에만 남고 여기엔 없다.
    @Published private(set) var daysWithActivityTitles: [Int: [(id: UUID, title: String)]] = [:]

    /// Date → yyyyMMdd 정수 키(daysWithSchedule 조회용).
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// [start, end) 반열린 구간이 그 날과 겹치는지. 일간 나열(ContentView.events/activities(on:))과
    /// 월간·주간 점(daysWithSchedule)이 같은 날에 대해 다른 말을 하지 않도록 판정을 이 한 곳에
    /// 둔다(계약 5 — 자정 넘김 결함을 일간만 고쳤을 때 점과 나열이 어긋나며 드러났다).
    /// 반열린 이유: 정확히 0시에 끝나는 구간은 다음 날과 겹친다고 보지 않는다(그릴 분이 0분).
    /// end ≤ start인 깨진 구간은 어느 날과도 겹치지 않는다고 본다 — 호출자의 폴백(앵커 날 하루)과
    /// 함께 쓴다.
    static func overlapsDay(start: Date, end: Date, day: Date, calendar: Calendar = .current) -> Bool {
        guard end > start, let d = calendar.dateInterval(of: .day, for: day) else { return false }
        return start < d.end && end > d.start
    }

    /// 한 구간(활동·이동)이 달력 점 계산에서 하루씩 걷히는 최대 날 수이자, 생성 시점에 활동
    /// 길이로 받아들이는 상한. 두 곳이 **같은 값**이어야 한다 — 걷기 상한만 있으면 상한 넘는
    /// 활동이 "점이 잘린 채" 저장되고, 생성 가드만 있으면 깨진 저장 데이터가 걷기를 비한정으로
    /// 돌린다(AIAssistant.executeCreateActivity가 이 상한으로 거른다).
    /// nonisolated — 실행부(executeCreateActivity)가 static 문맥에서도 읽을 수 있게.
    nonisolated static let maxIntervalDays = 366

    /// 도착 여유의 허용 범위. 음수는 출발을 그만큼 늦추고, 과도한 값은 실수다 — 수동 조정·AI 생성·
    /// AI 수정이 같은 한도를 쓰도록 한곳에 둔다(계약 5. 예전엔 이 식이 세 곳에 복사돼 있었고,
    /// 그래서 AI 생성 경로만 클램프가 빠진 채 남아 있었다).
    /// 카드의 직접입력 검증도 같은 상한을 봐야 한다 — 리터럴로 두 곳에 적으면 한쪽만 바뀐다.
    /// nonisolated인 이유: 카드의 값 검증(AskField.accepts)이 메인액터 격리 밖에서도 불린다.
    nonisolated static let maxBufferMinutes = 180
    static func clampBuffer(_ minutes: Int) -> Int { max(0, min(Self.maxBufferMinutes, minutes)) }

    /// 알림 리드타임은 음수면 "출발한 뒤에 알린다"가 되어 무의미하다. 상한은 두지 않는다 —
    /// "하루 전에 알려줘" 같은 요청이 실재한다.
    static func clampNotifyLead(_ minutes: Int) -> Int { max(0, minutes) }

    let notifications: NotificationManager

    private var eventsURL: URL {
        AppConfig.supportDirectory.appendingPathComponent("events.json")
    }
    private var favoritesURL: URL {
        AppConfig.supportDirectory.appendingPathComponent("favorites.json")
    }
    private var activitiesURL: URL {
        AppConfig.supportDirectory.appendingPathComponent("activities.json")
    }
    private var mealsURL: URL {
        AppConfig.supportDirectory.appendingPathComponent("meals.json")
    }
    private var seriesURL: URL {
        AppConfig.supportDirectory.appendingPathComponent("series.json")
    }

    /// 재조회가 따라잡기 알림을 기다리는 일정 id(비저장, REQ-003). 일정 id 키라 한 일정에 많아야
    /// 하나다. rescheduleNearestNotifications 꼬리에서 꺼낸다(REQ-009).
    private var pendingCatchUpIDs: Set<UUID> = []

    // MARK: Live replan state (SPEC-REPLAN-001) - in memory only, never in events.json

    /// The result of the last live check of each event; the departure card of the detail screen reads it.
    @Published private(set) var replanOutcomes: [UUID: ReplanOutcome] = [:]
    /// The clock of the new code only (debounce, `now` of the classification, `checkedAt`). The baseline reads of `Date()`
    /// stay as they are.
    var replanNow: () -> Date = { Date() }
    /// How many days after today the leg window of a repeat reaches, and how many days after its day a leg of an
    /// unstored occurrence is kept.
    nonisolated static let legWindowDays = 14
    nonisolated static let legRetentionDays = 30
    /// How far ahead the app-open check reaches, in minutes. The tap of a pending alert uses the same number.
    nonisolated static let refreshWindowMinutes = 120
    /// When the last successful live lookup of an event finished.
    private var lastLiveLookup: [UUID: Date] = [:]
    /// Events with a live lookup in flight.
    private var liveLookupsInFlight: [UUID: Int] = [:]
    /// The start stamp of the newest live lookup of an event that has finished and written.
    private var finishedLookupStart: [UUID: Date] = [:]
    /// The answer of the live lookup that `applyEstimate` just made for an event, read once by the refresh loop.
    private var lastLiveAnswers: [UUID: (seconds: TimeInterval, noTrafficSeconds: TimeInterval?)] = [:]

    init(notifications: NotificationManager) {
        self.notifications = notifications
        self.config = AppConfig.load()
        load()
        loadFavorites()
        loadActivities()
        loadSeries()
        loadMeals()
        // A tap on a departure alert starts the live check of its event (REQ-REPLAN-006).
        notifications.onAlertTap = { [weak self] id in
            Task { @MainActor in await self?.replanAfterAlert(id: id, trigger: .alertTap) }
        }
    }

    /// 점(달력 날짜 키)은 일간 나열과 같은 겹침 판정으로 채운다 — 자정을 넘는 블록은 구간이
    /// 걸치는 모든 날에 점이 켜진다. 이벤트 쪽 판정은 레코드의 계산 속성(REQ-023)에서만 나온다:
    /// 미계산 구간은 앵커 시각의 날 키 하나, 계산된 구간은 나열 구간(listedSpan)이 걸치는 날,
    /// 그도 없으면 도착일 하나(0.2.6 t82 — 미계산 구간도 listedSpan의 10분 구간으로 들어갔다,
    /// REQ-016) — 일간 나열(isListed)과 점이 같은 날을 내는 것도 같은 계산이
    /// 보증한다(AC-010 (13)). 월 달력 칸의 제목 캐시(daysWithActivityTitles)도 이 한 순회에서
    /// 같이 나온다(REQ-014). 저장·네트워크 호출은 없고 집합만 다시 만든다 — 반복 그룹이
    /// 118건이어도 이 함수 자체는 레코드당 한 번 돈다.
    private func recomputeDaysWithSchedule() {
        let cal = Calendar.current
        var set = Set<Int>(minimumCapacity: events.count + activities.count)
        for e in events {
            // 실패 블록(REQ-016, t82)도 listedSpan의 10분 구간이 걸치는 날에 점이 켠다 —
            // 나열(isListed)과 달력 점이 같은 계산을 읽는다(AC-010 (13), 계약 5).
            if let span = e.listedSpan {
                set.formUnion(Self.dayKeys(start: span.start, end: span.end, calendar: cal))
            } else {
                set.insert(Self.dayKey(e.arrivalDate, calendar: cal))
            }
        }
        // 칸 제목(daysWithActivityTitles)도 점과 같은 이 순회에서 채운다(REQ-014 "같은 날별
        // 계산") — 순회를 나누면 같은 활동에 대해 점·제목이 다른 날을 내는 창이 생긴다.
        // 배열은 이벤트 배열이 바뀔 때마다 여기도 도는데, 그때는 activities가 움직이지 않아도
        // 다시 돌므로 정렬 보증을 여기서 스스로 세운다(끌기 뒤 저장 순서에 의존하지 않는다).
        var titles: [Int: [(id: UUID, title: String)]] = [:]
        for a in activities.sorted(by: { $0.startDate < $1.startDate }) {
            // 깨진 레코드(endDate ≤ startDate)는 위 점 계산과 같은 폴백(시작일 하루)을 쓴다 —
            // 두 캐시가 같은 레코드에서 다른 날을 내지 않는다(계약 5).
            let keys = a.endDate > a.startDate
                ? Self.dayKeys(start: a.startDate, end: a.endDate, calendar: cal)
                : [Self.dayKey(a.startDate, calendar: cal)]
            set.formUnion(keys)
            for k in keys { titles[k, default: []].append((id: a.id, title: a.title)) }
        }
        daysWithSchedule = set
        daysWithActivityTitles = titles
    }

    /// [start, end) 반열린 구간이 걸치는 날들의 키. 후보를 시작일 자정부터 end 직전까지 하루씩
    /// 세되, 넣을지의 최종 판정은 overlapsDay(start:end:day:)가 내린다 — 루프 범위는 후보
    /// 생성일 뿐이라 판정 규칙이 바뀌어도 이 열거가 저절로 따라가고, 두 번째 판정이 생기지
    /// 않는다(계약 5). private가 아닌 이유: 드라이버(W·X절)가 이 열거와 overlapsDay 판정이
    /// 같은 날을 내는지 직접 재는데, private면 타입 선언 범위 밖에서 못 부른다.
    static func dayKeys(start: Date, end: Date, calendar cal: Calendar) -> [Int] {
        var keys: [Int] = []
        var cur = cal.startOfDay(for: start)
        // end의 상한을 검사하는 곳은 없다(AI의 end_iso는 9999년도 parseDate를 통과한다). 이 걷기는
        // activities 배열의 didSet 안에서 돌므로 비한정이면 화면이 얼고, 그 레코드를 지우려 해도
        // 앱이 켜질 때마다 다시 얼어 지울 수도 없다. 정상적인 장기 체류(여행 몇 주)보다 넉넉한
        // 366일에서 끊는다 — 그 너머의 긴 반복은 반복 활동이 담당하는 영역이다.
        while cur < end, keys.count < maxIntervalDays {
            if overlapsDay(start: start, end: end, day: cur, calendar: cal) {
                keys.append(dayKey(cur, calendar: cal))
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
        return keys
    }

    // MARK: - 활동(체류형) 블록

    /// 활동 블록과 그에 딸린 이동 구간(가는 편·오는 편)을 **한 번에, 서로 묶어서** 만든다.
    ///
    /// 따로 만들면 둘 사이에 아무 연결이 없어서, 나중에 활동 블록을 드래그해 옮겨도 이동 구간은
    /// 제자리에 남는다(사용자가 겪은 문제). 여기서 만든 구간은 `linkedActivityId`로 활동을
    /// 가리키므로 `moveActivity`가 같이 옮기고, 활동을 지우면 같이 지워진다.
    ///
    /// - `travelFrom`: 여기서 출발해 활동 시작 시각까지 도착하는 구간(도착 기준).
    /// - 가는 편·오는 편의 이동수단은 따로 받는다(갈 땐 지하철, 올 땐 택시처럼 다른 경우가 흔하다).
    /// - `returnTo`: 활동 종료 시각에 출발해 여기로 돌아오는 구간(출발 기준, 버퍼 없음).
    /// - 반환값은 만든 활동의 id와 이동 구간 수. **id를 함께 돌려주는 이유**: 호출부가 `await`가 끝난 뒤
    ///   제목·시작시각으로 방금 만든 활동을 되찾다가, 같은 이름·같은 시각 활동이 이미 있으면 엉뚱한 쪽에
    ///   붙고 못 찾으면 연결이 통째로 빠졌다(식사 기록이 일정과 함께 안 지워지는 원인이었다).
    @discardableResult
    func addActivityWithTravel(title: String,
                               location: Place?,
                               startDate: Date,
                               endDate: Date,
                               travelFrom: Place?,
                               returnTo: Place?,
                               outboundMode: TransportMode,
                               returnMode: TransportMode,
                               bufferMinutes: Int,
                               notifyLeadMinutes: Int,
                               notifyEnabled: Bool = true,
                               syncToCalendar: Bool = true,
                               travelSecondsHint: TimeInterval? = nil) async -> (activityId: UUID, travelLegs: Int) {
        var activity = ActivityBlock(title: title, location: location, startDate: startDate, endDate: endDate)
        activity.syncToCalendar = syncToCalendar
        activities.append(activity)
        activities.sort { $0.startDate < $1.startDate }
        saveActivities()

        // 이동 구간은 활동 장소를 알아야 만들 수 있다(목적지/출발지가 곧 활동 장소).
        // 구간 생성은 addLeg 하나로만 지난다(계약 5) — 여기서 addEvent를 직접 부르면 생성 경로가
        // 둘이 되어 보호 조건(중복 역할 거절·보상 검사)이 한쪽에만 붙는다. 이 리팩터가 옛 코드의
        // 두 await 사이 활동 재확인 부재도 함께 닫는다(addLeg의 보상 검사가 그 몫이다).
        guard location != nil else { return (activity.id, 0) }
        var made = 0
        if let from = travelFrom {
            _ = await addLeg(activityId: activity.id, role: .arrival, outerPlace: from,
                             mode: outboundMode, bufferMinutes: bufferMinutes,
                             notifyLeadMinutes: notifyLeadMinutes, notifyEnabled: notifyEnabled,
                             travelSecondsHint: travelSecondsHint, syncToCalendar: syncToCalendar)
            made += 1
        }
        if let to = returnTo {
            _ = await addLeg(activityId: activity.id, role: .departure, outerPlace: to,
                             mode: returnMode, bufferMinutes: 0,
                             notifyLeadMinutes: notifyLeadMinutes, notifyEnabled: notifyEnabled,
                             travelSecondsHint: travelSecondsHint, syncToCalendar: syncToCalendar)
            made += 1
        }
        return (activity.id, made)
    }

    // The repeat that made activities without travel (addRecurringActivities) went in SPEC-UIKIT-018 M3, and the repeat
    // that made one stored activity per day went in SPEC-RECURRULE-001: a repeat is now one stored RepeatSeries,
    // made by saveManualActivity and drawn from its rule.

    /// 활동 블록 정보를 수정한다(제목·장소·시간).
    func updateActivity(_ updated: ActivityBlock) {
        var updated = updated
        // A computed occurrence becomes a stored copy first and leaves the series (REQ-014).
        if !activities.contains(where: { $0.id == updated.id }), resolveStored(updated.id) != nil {
            updated.recurrenceId = nil
        }
        guard let idx = activities.firstIndex(where: { $0.id == updated.id }) else { return }
        activities[idx] = updated
        activities.sort { $0.startDate < $1.startDate }
        saveActivities()
    }

    /// 활동 블록의 시간을 옮기고/줄이고, 제목·장소를 바꾼다(주어진 것만).
    ///
    /// **묶인 이동 구간도 같이 맞춘다** — 시작을 옮기면 `moveActivity`가 양쪽 구간을 평행이동하고,
    /// 종료만 바뀌면(식사 시간이 길어지는 등) 복귀 구간의 출발 시각을 새 종료 시각에 다시 붙인다.
    /// 상세 화면에서 시각을 고쳤을 때 이동 블록이 제자리에 남던 문제를 막기 위함.
    ///
    /// `clearPlace`가 "장소 지우기"를 `newPlace == nil`("그대로 둠")과 구분한다(REQ-004). 기존
    /// 호출 모양(지우기 인자 없음)은 기본값 false로 옛 동작 그대로다 — AI 경로의 호출 모양이
    /// 바뀌지 않는다는 게 회귀선이다.
    @discardableResult
    func modifyActivity(id: UUID,
                        newTitle: String? = nil,
                        newStart: Date? = nil,
                        newEnd: Date? = nil,
                        newPlace: Place? = nil,
                        clearPlace: Bool = false) -> Bool {
        // A computed occurrence is read, not stored: it becomes a stored copy only below, when something changed.
        guard let current = activity(id: id) else { return false }
        var changed = false

        // 장소를 지우면 명시적으로 연결된 구간도 함께 지운다 — 구간은 활동 장소가 있어야
        // 존재할 수 있어서(REQ-004). 알림 취소·캘린더 삭제까지 기존 정리 경로를 탄다.
        if clearPlace, current.location != nil { removeExplicitLegs(of: [id]) }

        // 복귀 구간 짝은 끝·시작을 쓰기 전에 id로 잡아 둔다 — 짝은 명시 연결(linkedActivityId)로만
        // 찾으므로 그날 빠짐(REQ-014)이나 새 끝 저장에 짝이 흔들리지는 않지만, moveActivity가
        // 구간을 이미 평행이동한 뒤에는 id로 다시 읽은 현재값을 잔차 재정렬(t49 조합 경로)의
        // 기준으로 써야 해서 id를 먼저 쥐어 둔다. clearPlace면 잡지 않는다: 장소를 지운 활동의
        // 구간은 존재할 수 없어 지워지는데(REQ-004), 그 구간을 끝을 따라 옮기면 그 규칙과
        // 어긋난다(카드 t49).
        let returnLegId = clearPlace ? nil : legs(of: current.id).return?.id
        // 시작을 옮기는 건 "이동"이므로 moveActivity로 처리해야 딸린 이동 구간이 따라온다.
        if let newStart {
            let delta = Int(newStart.timeIntervalSince(current.startDate) / 60)
            if delta != 0 {
                moveActivity(current, byMinutes: delta, wholeSeries: false)
                changed = true
            }
        }
        // 위에서 옮겼을 수 있으니 최신 값을 다시 읽는다.
        guard var updated = activity(id: id) else { return changed }
        let endBefore = updated.endDate
        // moveActivity가 구간을 이미 평행이동했을 수 있으니 id로 다시 읽은 **현재값**을 잔차
        // 재정렬의 기준으로 쓴다(빠짐 전에 잡은 id — 옛 스냅샷을 쓰면 이동량이 두 번 붙는다).
        let returnLegBefore = returnLegId.flatMap { legId in events.first { $0.id == legId } }
        if let newTitle, !newTitle.isEmpty, newTitle != updated.title { updated.title = newTitle; changed = true }
        if let newPlace, newPlace != updated.location { updated.location = newPlace; changed = true }
        if clearPlace, updated.location != nil { updated.location = nil; changed = true }
        if let newEnd, newEnd != updated.endDate, newEnd > updated.startDate { updated.endDate = newEnd; changed = true }
        // `updateActivity` makes the stored copy of a computed occurrence, and only here, once `changed` is known.
        if changed { updateActivity(updated) }

        // 복귀 구간 재정렬은 endDate가 **실제로** 바뀐 경우에만 한다 — 끝 ≤ 시작으로 거절된
        // newEnd는 endDate도 안 바꿨으니 재정렬도 하지 않는다(잘못된 끝에 구간을 붙이지 않는다).
        if updated.endDate != endBefore {
            realignReturnLeg(returnLegBefore, departingAt: updated.endDate)
        }
        // 실제 변경이 있을 때만 그 회차를 반복에서 뗀다(REQ-014) — 재정렬 뒤에 두는 이유는
        // 빠짐이 returnLegBefore 짝(listedLegs)보다 먼저면 아무 상관 없지만, 같은 저장 흐름의
        // 마지막 단계라는 규칙(REQ-016 순서 ④)을 편집 경로에서도 그대로 지키기 위해서다.
        if changed { detachOccurrence(activityId: id) }
        return changed
    }

    /// 활동에 묶인 복귀(출발 기준) 이동 구간의 출발 시각을 주어진 시각으로 옮긴다.
    /// 이동량(shift) 기반의 기존 함수라 legAnchor(유도 규칙의 한 자리)를 바로 쓰지 않는다 —
    /// 시각을 호출자가 이미 알고 있을 때 쓰는 경로다(design §9). 짝은 호출부가 **끝을 쓰기 전에**
    /// 잡아 넘긴다(legs(of:) — 명시 연결만, 카드 t49·t50). 변위의 기준은 대조 시각
    /// (anchorDate)이다: 출발 시각이 없는 회차(첫 추정 실패)는 출발이 arrivalDate에
    /// 있어 departureDate로 잴면 그 회차만 편집에서 남겨진다. 짝을 가리는 비교가 아니라 변위를
    /// 재는 값이라 짝 판정 은퇴(REQ-012) 뒤에도 남는다.
    private func realignReturnLeg(_ leg: ScheduledEvent?, departingAt: Date) {
        guard let leg else { return }
        let delta = Int(departingAt.timeIntervalSince(leg.anchorDate) / 60)
        guard delta != 0 else { return }
        shiftEvent(leg.id, byMinutes: delta)
        save()
    }

    // MARK: - 그날 빠짐(SPEC-ONTIME-008 REQ-014, P-11)

    /// 빠짐의 몸통(저장 없음) — 저장을 한 번만 해야 하는 같은 저장 흐름(REQ-016의 순서 ②③④)이
    /// 같은 파일 안에서 직접 쓴다. 반환값은 어느 쪽이 실제로 비워졌는지다(호출부가 무슨 배열을
    /// 저장할지 정하게).
    @discardableResult
    private func clearSeriesMembership(activityId: UUID) -> (activity: Bool, legs: Bool) {
        var actChanged = false
        if let idx = activities.firstIndex(where: { $0.id == activityId }), activities[idx].recurrenceId != nil {
            activities[idx].recurrenceId = nil
            actChanged = true
        }
        // 요소 단위로 여러 번 고치면 didSet(달력 점 재계산)이 구간 수만큼 돈다 — 복사본에서 다
        // 고치고 한 번만 대입한다(rescheduleNearestNotifications와 같은 이유).
        var evs = events
        var evChanged = false
        for i in evs.indices where evs[i].linkedActivityId == activityId && evs[i].recurrenceId != nil {
            evs[i].recurrenceId = nil
            evChanged = true
        }
        if evChanged { events = evs }
        return (actChanged, evChanged)
    }

    /// 소유 활동 없이 혼자 반복에 남은 구간의 빠짐 — 그 구간 하나만 뗀다(J-10).
    @discardableResult
    private func clearSeriesMembership(legId: UUID) -> Bool {
        guard let idx = events.firstIndex(where: { $0.id == legId }), events[idx].recurrenceId != nil else {
            return false
        }
        events[idx].recurrenceId = nil
        return true
    }

    /// "이 일정만" 변경이 그 회차를 반복에서 뗀다(REQ-014) — 고친 활동과 그것에 **명시적으로**
    /// 연결된 구간 전부의 recurrenceId를 비운다. 명시 연결만 본다(REQ-012): 연결 없는 옛
    /// 반복 이동은 어느 활동의 것도 아니라 이 함수가 건드리지 않고, 끌기 같은 자기 자신의
    /// 변경이 있을 때 그 구간 하나만 빠진다(J-10, detachOccurrence(legId:)). 공개 변경 함수의
    /// "실제 변경" 갈래가 부르고, 무변경 저장·"전체" 조작·삭제는 부르지 않는다. 빠짐을
    /// updateEvent 안에 두면 realignLegs·updateLeg의 내부 호출까지 빠지게
    /// 되므로(P-11 금지) 이동 편집 폼(AddEventView)의 updateEvent 저장 자리가 이 함수를 직접
    /// 부른다.
    @discardableResult
    func detachOccurrence(activityId: UUID) -> Bool {
        // A computed occurrence has no record to clear: it becomes a stored copy, which has left the series.
        if !series.isEmpty, !activities.contains(where: { $0.id == activityId }), materialize(activityId) != nil {
            return true
        }
        let cleared = clearSeriesMembership(activityId: activityId)
        if cleared.activity { saveActivities() }
        if cleared.legs { save() }
        return cleared.activity || cleared.legs
    }

    /// 이동 편집 폼의 저장이 그 회차를 **실제로 바꿨는가**(REQ-014 "바꾸지 않는 저장은 안 뗀다").
    /// 비교 범위는 폼이 저장으로 내보내는 값 전부 — 제목·출발지·목적지·기준 시각·방향·이동수단·
    /// 도착 여유·알림(켬/끔·리드)·캘린더 동의. 이동시간은 폼이 다시 계산해 내는 파생값이라
    /// 넣지 않는다(교통 상황만 달라져도 "바뀜"이 되면 열었다 닫기만 해도 회차가 빠진다).
    /// 판정을 뷰가 아니라 여기 둔 것은 드라이버가 부를 수 있게 하려는 것이고(계약 5), 폼이
    /// 불러온 값(`editing`)과 저장 값을 같은 정규화로 맞춰 읽는다 — 출발 기준은 도착 여유가
    /// 저장 때 0으로 눌리므로 원본도 0으로 읽고, 기준 시각은 방향에 따라 도착/출발 쪽을 본다.
    static func legEditChangesOccurrence(original e: ScheduledEvent,
                                         title: String, origin: Place, destination: Place,
                                         baseDate: Date, anchor: ScheduleAnchor, mode: TransportMode,
                                         bufferMinutes: Int, notifyLeadMinutes: Int,
                                         notifyEnabled: Bool, syncToCalendar: Bool) -> Bool {
        let origAnchor = e.anchor ?? .arrival
        let origBase = e.anchorDate   // 같은 식이 이미 있다(계약 5) — 두 벌로 두지 않는다
        let origBuffer = origAnchor == .departure ? 0 : e.bufferMinutes
        let newBuffer = anchor == .departure ? 0 : bufferMinutes
        return e.title != title
            || e.origin != origin
            || e.destination != destination
            || origAnchor != anchor
            // 폼의 시각 문자열은 초 단위라 왕복에서 밀리초가 잘린다 — 1초 미만 차이는 같은 값이다.
            || abs(origBase.timeIntervalSince(baseDate)) >= 1
            || e.mode != mode
            || origBuffer != newBuffer
            || e.notifyLeadMinutes != notifyLeadMinutes
            || e.wantsNotification != notifyEnabled
            || e.wantsCalendarSync != syncToCalendar
    }

    /// 구간 쪽 빠짐의 공개 진입점 — 명시 소유가 없는 반복 구간 하나를 반복에서 뗀다(J-10).
    @discardableResult
    func detachOccurrence(legId: UUID) -> Bool {
        guard clearSeriesMembership(legId: legId) else { return false }
        save()
        return true
    }

    // MARK: - 구간 진입점·조회(SPEC-UIKIT-009 MA)

    /// 구간 추가·수정·제거·따라오기의 결과 값(REQ-009·010). travelKnown은 결과 플래그이고
    /// 레코드의 travelSeconds와 일치해야 한다 — 성공 판정의 단일 출처는 레코드다(계약 5).
    enum LegRefusalReason { case duplicateRole, noPlace, activityMissing }
    enum LegOutcome {
        case created(travelKnown: Bool)
        case updated(travelKnown: Bool)
        case removed
        case refused(reason: LegRefusalReason)
        case failed
    }

    /// 구간 시간 유도의 한 자리(design §4) — 가는 편은 활동 **시작에 도착**, 오는 편은 활동
    /// **끝에 출발**. addLeg·updateLeg·realignLegs가 같이 읽는다(셋이 각자 계산하면 세 번째
    /// 복제가 된다). realignReturnLeg는 이동량(shift)으로 옮기는 기존 함수라 이 함수를 바로
    /// 쓰지 않는다(design §9).
    private func legAnchor(role: ScheduleAnchor, activity: ActivityBlock) -> Date {
        role == .departure ? activity.endDate : activity.startDate
    }

    /// 구간 제목의 한 자리 — 오는 편에만 " (복귀)"가 붙는다는 규칙이 추가·따라오기에서 같은
    /// 문장을 내게 한다(addActivityWithTravel이 내던 문구와 글자 하나까지 같다).
    private func legTitle(role: ScheduleAnchor, activity: ActivityBlock) -> String {
        role == .departure ? "\(activity.title) (return)" : activity.title
    }

    /// await(updateEvent의 추정) 사이 활동이 다른 경로로 바뀌었는지 — 바뀌었으면 현재값,
    /// 아니면 nil. 유도값(앵커·끝점·제목)을 await 전 스냅샷으로 쓰는 updateLeg·realignLegs가
    /// await 뒤 이것을 불러 옛 스냅샷이 들어갔으면 현재값으로 다시 쓴다(MA code-safety 경고 2).
    func activityIfChanged(_ before: ActivityBlock?) -> ActivityBlock? {
        guard let before, let now = activity(id: before.id) else { return nil }
        if now.title == before.title, now.startDate == before.startDate,
           now.endDate == before.endDate, now.location == before.location { return nil }
        return now
    }

    /// 활동의 명시적 연결 구간 전부(같은 역할 둘 포함) — legs(of:)·packingGroups가
    /// 같은 목록을 읽는다.
    private func explicitLegs(of activityId: UUID) -> [ScheduledEvent] {
        events.filter { $0.linkedActivityId == activityId }
    }

    /// 활동의 명시적 연결 구간을 (가는 편, 오는 편)으로 돌려준다. 활동↔구간의 짝은 이 연결뿐이다
    /// (REQ-001·012 — 제목·시각·장소로 짝을 짓지 않는다): 편집·삭제·"전체" 이동·끌기 소유·시간표
    /// 묶음이 모두 이 목록을 읽는다. 같은 역할이 둘 이상인 옛 데이터는 첫째를 돌려준다.
    func legs(of activityId: UUID) -> (outbound: ScheduledEvent?, `return`: ScheduledEvent?) {
        let explicit = explicitLegs(of: activityId)
        return (explicit.first { ($0.anchor ?? .arrival) == .arrival },
                explicit.first { $0.anchor == .departure })
    }

    /// 구간의 linkedActivityId가 가리키는 활동. 없거나 매달렸으면(가리키는 활동이 지워졌으면) nil —
    /// 편집 라우팅·제목 표시의 단일 조회(REQ-001·006).
    func activity(forLeg event: ScheduledEvent) -> ActivityBlock? {
        guard let id = event.linkedActivityId else { return nil }
        return activity(id: id)
    }

    /// 구간의 소유 활동 조회(REQ-004) — 시간표 미리보기와 드롭이 같은 판정을 읽게 한 곳에 둔다
    /// (계약 5). 소유는 명시 연결(linkedActivityId)뿐이다(REQ-001·012): 연결이 살아 있으면 그
    /// 활동, 매달렸으면(가리키는 활동이 지워졌으면) 소유 없음, 연결이 없으면 소유 없음 — 연결
    /// 없는 옛 반복 이동은 단독 구간으로 지금 동작(REQ-005)을 탄다. 예전엔 반복 회차 구간을
    /// 시각·장소 일치로 활동에 짝지었지만 은퇴했다(D-3 — 기존 데이터는 고려하지 않는다).
    /// activity(forLeg:)와 같은 조회다.
    /// @MX:ANCHOR fan_in ≥ 3 — 드래그 시작(ContentView)과 adjustTravelLeg의 소유 갈래·전체 끌기 후보 거름(두 곳)이 같이 부른다
    func owningActivity(of leg: ScheduledEvent) -> ActivityBlock? {
        activity(forLeg: leg)
    }

    /// 활동에 명시적으로 연결된 구간 수(같은 역할 중복 포함) — 삭제 확인 문구가 읽는다(REQ-014).
    func explicitLegCount(of activityId: UUID) -> Int {
        explicitLegs(of: activityId).count
    }

    /// 같은 제목 삭제 집합(REQ-013) — 연결된 구간은 활동 삭제의 연쇄가 지우므로 이 묶음에 속하지
    /// 않는다. 연결 없는 구간 자신은 집합에 포함된다.
    func sameTitleSweep(for event: ScheduledEvent) -> [ScheduledEvent] {
        events.filter { $0.title == event.title && $0.linkedActivityId == nil }
    }

    /// 그날 목록의 구간을 배치 묶음의 활동에 대응시킨다(REQ-015) — 명시 연결 구간 **전부**(같은
    /// 역할 둘 포함)가 그 활동의 묶음이다. 연결 없는 구간은 키가 없어 단독으로 배치된다.
    /// 결과는 넘겨받은 events/activities 안의 id만 담는다.
    // @MX:NOTE 짝은 linkedActivityId뿐이다(REQ-012) — 시각·장소 대조로 묶음을 추정하지 않는다
    // @MX:WARN 연결이 없는 옛 반복 이동은 활동 옆에 놓여도 같은 칸으로 묶이지 않는다(D-3, 결정된 동작)
    // @MX:REASON 잘못된 추정이 구간을 활동과 함께 움직이거나 지우는 일을 구조적으로 끊는다
    func packingGroups(events: [ScheduledEvent], activities: [ActivityBlock]) -> [UUID: UUID] {
        let activityIDs = Set(activities.map { $0.id })
        var out: [UUID: UUID] = [:]
        for e in events {
            if let owner = e.linkedActivityId, activityIDs.contains(owner) { out[e.id] = owner }
        }
        return out
    }

    /// 활동에 이동 구간 하나를 붙인다 — 구간 생성 경로의 단일 진입점(addActivityWithTravel도 이것을
    /// 두 번 부른다, 계약 5). 앵커 시각은 활동에서 유도하고(legAnchor) 앵커 쪽은 추정과 무관하다.
    /// 보호 조건(REQ-009): 같은 역할의 명시적 구간이 이미 있으면 거절(이벤트 수 불변) · 활동 장소가
    /// 없으면 거절 · await(addEvent) 뒤 활동이 사라졌으면 방금 만든 구간을 지우고 거절한다(보상
    /// 검사가 기본 — 매달린 링크를 만들지 않는다).
    /// @MX:ANCHOR fan_in ≥ 3 — 생성 카드·편집 카드·addActivityWithTravel이 같이 부른다
    @discardableResult
    func addLeg(activityId: UUID,
                role: ScheduleAnchor,
                outerPlace: Place,
                mode: TransportMode,
                bufferMinutes: Int,
                notifyLeadMinutes: Int,
                notifyEnabled: Bool = true,
                travelSecondsHint: TimeInterval? = nil,
                syncToCalendar: Bool? = nil) async -> LegOutcome {
        guard let activity = self.activity(id: activityId) else {
            return .refused(reason: .activityMissing)
        }
        // 같은 역할이 이미 있으면 거절 — 이벤트 수가 불변이어야 카드의 저장 diff가 빈자리를 믿는다.
        if explicitLegs(of: activityId).contains(where: { ($0.anchor ?? .arrival) == role }) {
            return .refused(reason: .duplicateRole)
        }
        // 반복 회차 활동에도 구간을 만들 수 있다(REQ-011 — 예전 거절은 폼의 회차 깃발과 같이
        // 걷힌다). 번호 없는 구간이 반복 전체 삭제에서 살아남는 옛 우려(sync 1차 B1)는 이제
        // 반대로 "회차가 빠진다"(REQ-014)가 답이다 — 붙이는 순간 그 회차는 단독 일정이 된다.
        guard let place = activity.location else { return .refused(reason: .noPlace) }
        // 구간의 캘린더 동의는 기본으로 활동을 따른다 — "캘린더 안 함" 활동에 붙은 구간이 구글
        // 캘린더에 오르면 활동과 구간의 동의가 어긋난다(REQ-008, sync 1차 W1). 명시적으로 넘긴
        // 값(생성 카드의 addActivityWithTravel)은 그대로 이긴다.
        let legSync = syncToCalendar ?? activity.wantsCalendarSync
        let leg = await addEvent(title: legTitle(role: role, activity: activity),
                                 origin: role == .departure ? place : outerPlace,
                                 destination: role == .departure ? outerPlace : place,
                                 arrivalDate: legAnchor(role: role, activity: activity),
                                 mode: mode,
                                 bufferMinutes: bufferMinutes,
                                 notifyLeadMinutes: notifyLeadMinutes,
                                 anchor: role,
                                 travelSecondsHint: travelSecondsHint,
                                 linkedActivityId: activityId,
                                 notifyEnabled: notifyEnabled,
                                 syncToCalendar: legSync)
        // await 뒤 배열이 바뀌었을 수 있으니 활동을 다시 본다 — 지워졌으면 방금 만든 구간을
        // 되돌린다(보상 검사). leg를 검색이 아니라 반환값으로 얻는 건 같은 제목·시각 구간이
        // 이미 있을 때 엉뚱한 쪽을 집는 일을 막는다(addEvent가 레코드를 돌려주는 이유와 같다).
        guard self.activity(id: activityId) != nil else {
            deleteEvent(leg)
            return .refused(reason: .activityMissing)
        }
        // 같은 역할 재검사도 await **뒤에** 한 번 더 돈다 — 위 검사는 await 앞에만 있어 두 Task가
        // 같은 활동·같은 역할으로 겹치면 둘 다 통과한다(더블탭 등). 방금 만든 구간(leg.id) 외에
        // 같은 역할이 생겨 있으면 방금 것을 지우고 거절한다 — 보상 검사와 같은 패턴으로, 재검사와
        // 삭제 사이에 await가 없으므로 어느 끼어듦에서도 같은 역할이 둘 남지 않는다.
        if explicitLegs(of: activityId).contains(where: { ($0.anchor ?? .arrival) == role && $0.id != leg.id }) {
            deleteEvent(leg)
            return .refused(reason: .duplicateRole)
        }
        // 만든 구간은 번호 없이(단독) — 아직 반복 안의 회차에 붙였으면 그 회차를 반복에서 뗀다
        // (REQ-014·J-4: "이 일정만" 추가도 그날을 바꾼 것이다). 거절 갈래는 여기 오지 않는다.
        detachOccurrence(activityId: activityId)
        return .created(travelKnown: leg.travelSeconds != nil)
    }

    /// 연결 구간의 줄을 고친다(주어진 것만). 앵커 시각은 활동의 **현재** 값에서 다시 유도한다
    /// (legAnchor) — 옛 버전에서 오는 편을 끌어 벌어진 틈은 이 저장으로 닫힌다(design §4). 활동이 사라진
    /// 매달린 구간은 유도를 못 하므로 저장된 시각을 그대로 쓴다.
    @discardableResult
    func updateLeg(legId: UUID,
                   outerPlace: Place? = nil,
                   mode: TransportMode? = nil,
                   bufferMinutes: Int? = nil,
                   notifyLeadMinutes: Int? = nil,
                   notifyEnabled: Bool? = nil,
                   travelSecondsHint: TimeInterval? = nil,
                   syncToCalendar: Bool? = nil) async -> LegOutcome {
        guard let leg = events.first(where: { $0.id == legId }) else { return .failed }
        let role = leg.anchor ?? .arrival
        let activity = leg.linkedActivityId.flatMap { id in self.activity(id: id) }
        let anchorDate = activity.map { legAnchor(role: role, activity: $0) }
            ?? (role == .departure ? (leg.departureDate ?? leg.arrivalDate) : leg.arrivalDate)
        let title = activity.map { legTitle(role: role, activity: $0) } ?? leg.title
        // 활동 쪽 끝점은 활동 장소에서, 바깥 쪽은 저장값(또는 인자)에서 — updateEvent가 Place를
        // 비-Optional로 받으므로 매달린 구간은 저장값으로 폴백한다(modifyEvent과 같은 규칙).
        let outer = outerPlace ?? (role == .departure ? leg.destination : (leg.origin ?? leg.destination))
        func write(_ act: ActivityBlock?) async {
            let activitySide = act?.location
            await updateEvent(id: legId,
                              title: act.map { legTitle(role: role, activity: $0) } ?? title,
                              origin: role == .departure ? (activitySide ?? leg.origin ?? leg.destination) : outer,
                              destination: role == .departure ? outer : (activitySide ?? leg.destination),
                              arrivalDate: act.map { legAnchor(role: role, activity: $0) } ?? anchorDate,
                              mode: mode ?? leg.mode,
                              bufferMinutes: bufferMinutes ?? leg.bufferMinutes,
                              notifyLeadMinutes: notifyLeadMinutes ?? leg.notifyLeadMinutes,
                              anchor: role,
                              travelSecondsHint: travelSecondsHint,
                              notifyEnabled: notifyEnabled,
                              syncToCalendar: syncToCalendar)
        }
        await write(activity)
        // await(추정) 사이 활동이 다른 경로로 바뀌면 위 쓰기에 옛 앵커·끝점·제목이 들어갔다 —
        // 현재값으로 한 번 더 쓴다(MA code-safety 경고 2의 간단한 형태). 같은 저장 안의 재시도라
        // 사이에 다른 갱신을 끼우지 않는다(design §5의 직렬 규칙과 같은 이유).
        if let fresh = activityIfChanged(activity) { await write(fresh) }
        // 줄 고침도 "이 일정만" 변경이다(REQ-014) — 명시 소유면 그 회차 전체가, 소유 없는 옛
        // 반복 구간이면 구간 하나만 빠진다(J-10). updateEvent을 직접 고친 게 아니라 여기 두는
        // 이유는 P-11 금지(realignLegs의 따라오기까지 빠지게 하면 "전체" 저장이 회차를 지운다).
        if let linked = leg.linkedActivityId {
            detachOccurrence(activityId: linked)
        } else {
            detachOccurrence(legId: legId)
        }
        // 플래그는 레코드에서 읽는다 — 추정 성패를 결과가 거짓말하면 안 된다(AC-010 (2)).
        guard let updated = events.first(where: { $0.id == legId }) else { return .failed }
        return .updated(travelKnown: updated.travelSeconds != nil)
    }

    /// 구간 하나만 지운다(활동은 그대로) — REQ-013의 구간 삭제 몫. 정리 경로는 deleteEvent를 탄다.
    /// 줄 삭제도 "이 일정만" 변경이라 남은 회차(활동과 나머지 연결 구간)를 반복에서 뗀다(REQ-014).
    @discardableResult
    func removeLeg(legId: UUID) -> LegOutcome {
        guard let leg = events.first(where: { $0.id == legId }) else { return .failed }
        deleteEvent(leg)
        if let linked = leg.linkedActivityId {
            detachOccurrence(activityId: linked)
        } else {
            detachOccurrence(legId: legId)
        }
        return .removed
    }

    /// 활동 저장 **뒤**에 불러, 명시적 연결 구간이 저장된 활동을 따라오게 한다(REQ-003) — 시간은
    /// legAnchor, 활동 쪽 끝점은 활동 location, 제목은 legTitle, 바깥 끝점은 그대로, 이동시간은 다시
    /// 추정한다(힌트 인자 옵션). **유도한 값이 저장값과 같은 구간은 전혀 쓰지 않는다** — 무변경
    /// 저장은 레코드 바이트가 동일해야 한다(REQ-008). 구간은 하나씩 직렬로 처리한다: updateEvent는
    /// await 전 스냅샷을 되쓰므로 갱신 사이에 다른 갱신을 끼우지 않는다(design §5 위험 표).
    /// 결과의 updated는 "활동을 따르고 있음"의 뜻이지 쓰기가 있었다는 뜻이 아니다 — 쓰지 않은
    /// 구간도 플래그는 레코드에서 읽어 돌려준다.
    @discardableResult
    func realignLegs(of activityId: UUID,
                     outboundTravelSecondsHint: TimeInterval? = nil,
                     returnTravelSecondsHint: TimeInterval? = nil) async -> (outbound: LegOutcome?, `return`: LegOutcome?) {
        guard let activity = self.activity(id: activityId) else { return (nil, nil) }
        var results: [ScheduleAnchor: LegOutcome] = [:]
        for role in [ScheduleAnchor.arrival, ScheduleAnchor.departure] {
            guard let leg = events.first(where: { $0.linkedActivityId == activityId && ($0.anchor ?? .arrival) == role })
            else { continue }
            let anchorDate = legAnchor(role: role, activity: activity)
            let title = legTitle(role: role, activity: activity)
            let activitySide = activity.location
            let newOrigin = role == .departure ? (activitySide ?? leg.origin ?? leg.destination)
                                               : (leg.origin ?? leg.destination)
            let newDestination = role == .departure ? leg.destination : (activitySide ?? leg.destination)
            let anchorSame = role == .departure ? leg.departureDate == anchorDate : leg.arrivalDate == anchorDate
            // 유도한 값이 저장값과 같으면 updateEvent를 부르지 않는다 — 불러도 레코드가 같으면
            // 알림 재예약·정렬·저장만 일어나고, 다르면 바이트 동일이 깨진다.
            if leg.title == title && anchorSame && leg.origin == newOrigin && leg.destination == newDestination {
                results[role] = .updated(travelKnown: leg.travelSeconds != nil)
                continue
            }
            // 끝점이 그대로면 저장된 이동시간이 여전히 사실이다 — 힌트 없이 재추정하면 실패 때
            // (오프라인·할당량·경로 없음) applyEstimate가 알림을 취소하고 travelSeconds를 비운
            // 채 끝나는 값 손실이 생긴다(sync 1차 B2, REQ-010). 끝점이 바뀌면 저장값이 사실이
            // 아니므로 nil로 재추정을 유지한다. 명시적 힌트 인자가 있으면 그 값이 이긴다.
            let endpointsSame = leg.origin == newOrigin && leg.destination == newDestination
            let roleHint = (role == .departure ? returnTravelSecondsHint : outboundTravelSecondsHint)
                ?? (endpointsSame ? leg.travelSeconds : nil)
            await updateEvent(id: leg.id,
                              title: title,
                              origin: newOrigin,
                              destination: newDestination,
                              arrivalDate: anchorDate,
                              mode: leg.mode,
                              bufferMinutes: leg.bufferMinutes,
                              notifyLeadMinutes: leg.notifyLeadMinutes,
                              anchor: role,
                              travelSecondsHint: roleHint)
            // await(추정) 사이 활동이 다른 경로로 바뀌면 위 쓰기에 옛 앵커·끝점이 들어갔다 —
            // 현재값으로 한 번 더 쓴다(updateLeg과 같은 형태, MA code-safety 경고 2). 힌트는 이때
            // **새 끝점** 기준으로 다시 계산한다 — 첫 쓰기의 endpointsSame을 그대로 쓰면 바뀐
            // 활동 장소의 끝점에 옛 경로 이동시간이 "조회됨"으로 굳는다(수리 diff code-safety W-a).
            if let fresh = activityIfChanged(activity) {
                let freshOrigin = role == .departure ? (fresh.location ?? leg.origin ?? leg.destination)
                                                     : (leg.origin ?? leg.destination)
                let freshDestination = role == .departure ? leg.destination : (fresh.location ?? leg.destination)
                let freshHint = (role == .departure ? returnTravelSecondsHint : outboundTravelSecondsHint)
                    ?? (leg.origin == freshOrigin && leg.destination == freshDestination ? leg.travelSeconds : nil)
                await updateEvent(id: leg.id,
                                  title: legTitle(role: role, activity: fresh),
                                  origin: freshOrigin,
                                  destination: freshDestination,
                                  arrivalDate: legAnchor(role: role, activity: fresh),
                                  mode: leg.mode,
                                  bufferMinutes: leg.bufferMinutes,
                                  notifyLeadMinutes: leg.notifyLeadMinutes,
                                  anchor: role,
                                  travelSecondsHint: freshHint)
            }
            if let updated = events.first(where: { $0.id == leg.id }) {
                results[role] = .updated(travelKnown: updated.travelSeconds != nil)
            }
        }
        return (results[.arrival], results[.departure])
    }

    /// 이동 일정 하나의 제목·시각·장소·이동수단을 바꾼다(주어진 것만 — 나머지는 그대로 둔다).
    /// 시각을 바꾸면 이동시간을 다시 계산한다.
    @discardableResult
    func modifyEvent(id: UUID,
                     newTitle: String? = nil,
                     newAnchorDate: Date? = nil,
                     newAnchor: ScheduleAnchor? = nil,
                     newDestination: Place? = nil,
                     newOrigin: Place? = nil,
                     newMode: TransportMode? = nil) async -> Bool {
        guard let current = events.first(where: { $0.id == id }) else { return false }
        let anchor = newAnchor ?? current.anchor ?? .arrival
        // 기준이 되는 시각: 도착 기준이면 도착 시각, 출발 기준이면 출발 시각.
        let existingAnchorDate = anchor == .departure ? (current.departureDate ?? current.arrivalDate) : current.arrivalDate
        await updateEvent(id: id,
                          title: newTitle?.isEmpty == false ? newTitle! : current.title,
                          origin: newOrigin ?? current.origin ?? current.destination,
                          destination: newDestination ?? current.destination,
                          arrivalDate: newAnchorDate ?? existingAnchorDate,
                          mode: newMode ?? current.mode,
                          bufferMinutes: current.bufferMinutes,
                          notifyLeadMinutes: current.notifyLeadMinutes,
                          anchor: anchor)
        // 단건 이동 고침도 "이 일정만"(REQ-014·J-11) — 명시 소유면 그 회차 전체가 빠진다.
        // updateEvent 자체에 두지 않는다(P-11): realignLegs·updateLeg가 내부에서 부르는
        // "전체" 경로까지 빠지게 된다.
        if let linked = current.linkedActivityId {
            detachOccurrence(activityId: linked)
        } else {
            detachOccurrence(legId: id)
        }
        return true
    }

    /// 활동 블록을 삭제한다. 이 활동에 **묶여서 만들어진** 이동 구간(linkedActivityId)도 같이 지운다 —
    /// 활동만 사라지고 그 활동을 위한 이동만 덩그러니 남으면 시간표가 이상해진다(일괄 삭제가 이
    /// 연쇄를 빠뜨려 매달린 링크가 남았다 — SPEC-UIKIT-009 REQ-012의 수리).
    /// 반복 일정이 만든 구간은 명시적 연결이 없으므로 여기서 건드리지 않는다(반복 전체 삭제로 처리).
    func deleteActivity(_ activity: ActivityBlock) {
        // 낱개·일괄이 같은 정리 절차를 탄다(계약 5) — 정리 몸통이 둘이면 한쪽만 고쳐지는 날이 온다.
        deleteActivitiesCore([activity])
    }

    private func saveActivities() {
        drvSaveActivitiesCount += 1   // t50 S1 — REQ-005 계수기(앱 논리 영향 없음)
        try? FileManager.default.createDirectory(at: AppConfig.supportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(activities).write(to: activitiesURL)
        calendarMirror.reconcile(mirrorActivities())
    }

    private func loadActivities() {
        guard let decoded: [ActivityBlock] = loadDataFile(activitiesURL) else { return }
        activities = decoded
    }

    // MARK: - Repeat series (SPEC-RECURRULE-001)

    /// True while `series.json` exists but could not be decoded. The file is copied to `series.unreadable.json` (or the
    /// next free numbered name) before any save overwrites it; until then the calendar mirror keeps every link.
    private(set) var seriesLoadFailed = false
    /// Occurrence titles of the visible months, keyed by "<time-zone id>/<yyyyMM>"; cleared whenever `series` changes.
    private var seriesMonthCache: [String: [Int: [(id: UUID, title: String)]]] = [:]

    private func loadSeries() {
        guard FileManager.default.fileExists(atPath: seriesURL.path) else { return }
        guard let decoded: [RepeatSeries] = loadDataFile(seriesURL) else {
            seriesLoadFailed = true
            return
        }
        series = decoded
        repairSkippedDaysOfStoredOccurrences()
    }

    /// A materialized occurrence is saved as a stored activity first, as a skipped day second and as the legs' cleared
    /// series id third. If the app died between the first two saves, a stored activity has the id of an occurrence that is
    /// not skipped, and deleting the copy would let the computed occurrence come back: add the day here and save once.
    /// If it died before the third, the copy's legs still carry the series id, whether or not the day is skipped: clear it
    /// here and save `events` once, only when something was cleared.
    private func repairSkippedDaysOfStoredOccurrences() {
        var repaired = series
        var changed = false
        for stored in activities {
            guard let (owner, dayKey) = series(forOccurrence: stored.id),
                  let index = repaired.firstIndex(where: { $0.id == owner.id }),
                  !repaired[index].skippedDayKeys.contains(dayKey) else { continue }
            repaired[index].skippedDayKeys.append(dayKey)
            changed = true
        }
        if changed {
            series = repaired
            saveSeries()
        }
        healLegsOfStoredOccurrences()
    }

    /// Clears the series id of the legs linked to a stored copy of an occurrence when it is the id of the series that owns
    /// the occurrence. A leg that carries another id is not touched. One assignment, one save, and none when nothing changed.
    private func healLegsOfStoredOccurrences() {
        var healed = events
        var cleared = false
        for stored in activities {
            guard let (owner, _) = series(forOccurrence: stored.id) else { continue }
            for i in healed.indices where healed[i].linkedActivityId == stored.id && healed[i].recurrenceId == owner.id {
                healed[i].recurrenceId = nil
                cleared = true
            }
        }
        guard cleared else { return }
        events = healed
        save()
    }

    /// Writes `series.json`. When the file was unreadable at load, its bytes are first copied to `series.unreadable.json`
    /// (`-2` to `-9` when that name is taken). If no copy can be made nothing is written, the flag stays, and the result
    /// is false. Internal so a test can call it; the writers of the app go through `addSeries`.
    @discardableResult
    func saveSeries() -> Bool {
        try? FileManager.default.createDirectory(at: AppConfig.supportDirectory, withIntermediateDirectories: true)
        if seriesLoadFailed, !copyUnreadableSeriesFile() { return false }
        guard let data = try? JSONEncoder().encode(series),
              (try? data.write(to: seriesURL, options: .atomic)) != nil else { return false }
        seriesLoadFailed = false
        // Every change of a series (a skipped day, a deleted series) reaches the mirror, so its link is removed.
        calendarMirror.reconcile(mirrorActivities())
        return true
    }

    private func copyUnreadableSeriesFile() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: seriesURL.path) else { return true }
        for n in 1...9 {
            let name = n == 1 ? "series.unreadable.json" : "series.unreadable-\(n).json"
            let target = AppConfig.supportDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { continue }
            return (try? fm.copyItem(at: seriesURL, to: target)) != nil
        }
        return false
    }

    /// Adds a series and saves it. When the file cannot be written the series is taken out of memory again and the
    /// result is false.
    @discardableResult
    func addSeries(_ new: RepeatSeries) -> Bool {
        series.append(new)
        guard saveSeries() else {
            series.removeAll { $0.id == new.id }
            return false
        }
        return true
    }

    /// The series an occurrence id belongs to and the day it names. Syntax and range only: the id must decode, carry the
    /// prefix of an existing series, and name a day between that series' first and last day. It does not ask the rule
    /// whether the day is an occurrence (a valid Tuesday of a Monday rule passes); `activity(id:)` does.
    // @MX:ANCHOR: the one place an id is read back to (series, day). The resolver, delete and edit of a computed
    // occurrence, the leg owner lookup and the calendar mirror's `retains` all start here; accepting an id it should
    // refuse would let a random UUID act on a series.
    func series(forOccurrence id: UUID) -> (RepeatSeries, dayKey: Int)? {
        guard let decoded = RepeatSeries.decode(id),
              let owner = series.first(where: { $0.owns(decoded) }),
              decoded.dayKey >= owner.firstDayKey,
              owner.lastDayKey.map({ decoded.dayKey <= $0 }) ?? true else { return nil }
        return (owner, decoded.dayKey)
    }

    /// The activity with an id: the stored one if there is one, else the computed occurrence. A computed occurrence needs
    /// an existing series, a day in its range that the rule produces, and a day that is not skipped.
    // @MX:ANCHOR: the one resolver of an activity id. Agent lookups, the detail screen, leg owners and the stale check
    // call it; a stored copy must win over the computed occurrence of the same id so a materialized edit is what is seen.
    func activity(id: UUID, calendar: Calendar = .current) -> ActivityBlock? {
        if let stored = activities.first(where: { $0.id == id }) { return stored }
        guard let (owner, dayKey) = series(forOccurrence: id), !owner.skippedDayKeys.contains(dayKey),
              let day = RepeatSeries.date(forDayKey: dayKey, calendar: calendar),
              let interval = calendar.dateInterval(of: .day, for: day) else { return nil }
        return owner.occurrences(in: interval, calendar: calendar).first { $0.id == id }
    }

    /// Makes a stored copy of a computed occurrence: same id, `recurrenceId` nil, the day added to the series' skipped
    /// days, and the `recurrenceId` of the legs linked to the id cleared (what `clearSeriesMembership` does for a stored
    /// copy). Returns the copy, or nil when the id is stored already or is not a live occurrence.
    // @MX:WARN: writes three files in a row: `activities.json`, `series.json` and, when it cleared a leg's `recurrenceId`,
    // `events.json`.
    // @MX:REASON: the copy, the skipped day and the legs' cleared `recurrenceId` must all reach the disk. Without the first
    // two a relaunch draws the occurrence twice; without the third `deleteRecurringSeries(series.id)` would find the copy's
    // legs still carrying the series id and remove them. A crash between any two of the saves is repaired on load: the
    // skipped day after the first, the legs' cleared series id after the first or the second.
    private func materialize(_ id: UUID) -> ActivityBlock? {
        guard !activities.contains(where: { $0.id == id }),
              let (owner, dayKey) = series(forOccurrence: id),
              let index = series.firstIndex(where: { $0.id == owner.id }),
              var copy = activity(id: id) else { return nil }
        copy.recurrenceId = nil
        activities.append(copy)
        activities.sort { $0.startDate < $1.startDate }
        series[index].skippedDayKeys.append(dayKey)
        // Mutate a copy of `events` and assign it once, as `clearSeriesMembership` does (the `didSet` runs once).
        var legs = events
        var clearedLegs = false
        for i in legs.indices where legs[i].linkedActivityId == id && legs[i].recurrenceId != nil {
            legs[i].recurrenceId = nil
            clearedLegs = true
        }
        if clearedLegs { events = legs }
        saveActivities()
        saveSeries()
        if clearedLegs { save() }
        return copy
    }

    /// The stored activity with this id, else the stored copy that `materialize` makes of the computed occurrence.
    private func resolveStored(_ id: UUID) -> ActivityBlock? {
        activities.first(where: { $0.id == id }) ?? materialize(id)
    }

    /// Stored activities that overlap `interval`, plus the series occurrences that do, with a stored activity winning
    /// over an occurrence of the same id. Sorted by start, then by id string. A broken stored record (end not after
    /// start) counts on its start day, as the day list has always done.
    func activities(in interval: DateInterval, calendar: Calendar = .current) -> [ActivityBlock] {
        let stored = activities.filter { a in
            guard a.endDate > a.startDate else { return a.startDate >= interval.start && a.startDate < interval.end }
            return a.startDate < interval.end && a.endDate > interval.start
        }
        return Self.sortedByStart(stored + computedOccurrences(in: interval, calendar: calendar))
    }

    /// The day list of one day: what `ContentView.activities(on:)` showed (a stored activity listed by `overlapsDay`, a
    /// broken record on its start day), plus the series occurrences of the day.
    func activities(on day: Date, calendar: Calendar = .current) -> [ActivityBlock] {
        let stored = activities.filter { a in
            guard a.endDate > a.startDate else { return calendar.isDate(a.startDate, inSameDayAs: day) }
            return Self.overlapsDay(start: a.startDate, end: a.endDate, day: day, calendar: calendar)
        }
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return Self.sortedByStart(stored) }
        return Self.sortedByStart(stored + computedOccurrences(in: interval, calendar: calendar))
    }

    /// The occurrences of every series inside `interval`, without the ones whose id is also a stored activity's id.
    private func computedOccurrences(in interval: DateInterval, calendar: Calendar) -> [ActivityBlock] {
        guard !series.isEmpty else { return [] }
        let storedIDs = Set(activities.map { $0.id })
        return series.flatMap { $0.occurrences(in: interval, calendar: calendar) }.filter { !storedIDs.contains($0.id) }
    }

    /// The activities Plan my day reads: stored ones and series occurrences from today 00:00 to the end of tomorrow, with
    /// "today" taken from `replanNow()`.
    func activitiesForPlanning(calendar: Calendar = .current) -> [ActivityBlock] {
        let today = calendar.startOfDay(for: replanNow())
        guard let end = calendar.date(byAdding: .day, value: 2, to: today) else { return [] }
        return activities(in: DateInterval(start: today, end: end), calendar: calendar)
    }

    private static func sortedByStart(_ list: [ActivityBlock]) -> [ActivityBlock] {
        list.sorted { ($0.startDate, $0.id.uuidString) < ($1.startDate, $1.id.uuidString) }
    }

    /// The occurrence titles of the month that contains `day`, by day key. Built on the first request for a month and kept
    /// until a series changes.
    private func seriesTitles(inMonthOf day: Date, calendar: Calendar) -> [Int: [(id: UUID, title: String)]] {
        guard !series.isEmpty else { return [:] }
        let c = calendar.dateComponents([.year, .month], from: day)
        let cacheKey = "\(calendar.timeZone.identifier)/\(String(format: "%04d%02d", c.year ?? 0, c.month ?? 0))"
        if let cached = seriesMonthCache[cacheKey] { return cached }
        var byDay: [Int: [(id: UUID, title: String)]] = [:]
        if let month = calendar.dateInterval(of: .month, for: day) {
            let blocks = Self.sortedByStart(series.flatMap { $0.occurrences(in: month, calendar: calendar) })
            for block in blocks {
                // The same day rule as the stored titles: the days the block overlaps, its start day when it is broken.
                let keys = block.endDate > block.startDate
                    ? Self.dayKeys(start: block.startDate, end: block.endDate, calendar: calendar)
                    : [Self.dayKey(block.startDate, calendar: calendar)]
                for key in keys { byDay[key, default: []].append((id: block.id, title: block.title)) }
            }
        }
        seriesMonthCache[cacheKey] = byDay
        return byDay
    }

    /// Titles for a month-grid cell: the stored activities' titles, then the series occurrences' (a series entry whose id
    /// is also in the stored entry is dropped, stored wins).
    func scheduleTitles(on day: Date, calendar: Calendar = .current) -> [(id: UUID, title: String)] {
        let key = Self.dayKey(day, calendar: calendar)
        let stored = daysWithActivityTitles[key] ?? []
        let fromSeries = seriesTitles(inMonthOf: day, calendar: calendar)[key] ?? []
        let storedIDs = Set(stored.map { $0.id })
        return stored + fromSeries.filter { !storedIDs.contains($0.id) }
    }

    /// Whether a day shows a dot: the stored cache says so, or a series has an occurrence on it.
    func hasSchedule(on day: Date, calendar: Calendar = .current) -> Bool {
        let key = Self.dayKey(day, calendar: calendar)
        return daysWithSchedule.contains(key) || !(seriesTitles(inMonthOf: day, calendar: calendar)[key] ?? []).isEmpty
    }

    // MARK: - 식사 기록(be full sir)

    /// 식사 기록을 하나 추가한다. 최신 것이 앞에 오도록 정렬해 "최근 뭘 먹었나"를 바로 볼 수 있게 한다
    /// (추천 시 최근 이력을 참고하고, 같은 걸 연달아 추천하지 않기 위해 필요).
    @discardableResult
    func addMeal(category: MealCategory,
                 title: String,
                 place: Place? = nil,
                 estimatedCost: Int? = nil,
                 scheduledEventId: UUID? = nil,
                 activityId: UUID? = nil,
                 plannedAt: Date? = nil,
                 loggedAt: Date = Date()) -> MealLog {
        let meal = MealLog(category: category, title: title, place: place,
                           estimatedCost: estimatedCost, scheduledEventId: scheduledEventId,
                           activityId: activityId, plannedAt: plannedAt, loggedAt: loggedAt)
        meals.append(meal)
        meals.sort { $0.loggedAt > $1.loggedAt }
        saveMeals()
        return meal
    }

    /// 호출부가 0개여도 남긴다 — 진행 중인 SPEC-FULL-001 REQ-003이 이 연산을 Store 요구사항으로 명시한다.
    func updateMeal(_ updated: MealLog) {
        guard let idx = meals.firstIndex(where: { $0.id == updated.id }) else { return }
        meals[idx] = updated
        meals.sort { $0.loggedAt > $1.loggedAt }
        saveMeals()
    }

    func deleteMeal(_ id: UUID) {
        meals.removeAll { $0.id == id }
        saveMeals()
    }


    /// 일정·활동을 지울 때, 거기 딸린 **아직 오지 않은** 식사 기록도 같이 지운다
    /// (이미 지난 식사는 실제로 먹은 기록이라 남긴다 — 판단은 `ScheduleLogic.mealsToRemove`).
    private func removeUpcomingMeals(eventIDs: Set<UUID> = [], activityIDs: Set<UUID> = []) {
        let doomed = ScheduleLogic.mealsToRemove(meals: meals, eventIDs: eventIDs,
                                                 activityIDs: activityIDs, now: Date())
        guard !doomed.isEmpty else { return }
        meals.removeAll { doomed.contains($0.id) }
        saveMeals()
    }

    /// 최근 식사 기록(기본 10건). AI 추천 프롬프트에 넣을 때 길이가 무한정 늘지 않도록 여기서 자른다.
    func recentMeals(limit: Int = 10) -> [MealLog] {
        Array(meals.prefix(limit))
    }

    private func saveMeals() {
        drvSaveMealsCount += 1   // SPEC-SYNC-004 §2.6 계수기(앱 논리 영향 없음)
        try? FileManager.default.createDirectory(at: AppConfig.supportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(meals).write(to: mealsURL)
    }

    private func loadMeals() {
        guard let decoded: [MealLog] = loadDataFile(mealsURL) else { return }
        meals = decoded.sorted { $0.loggedAt > $1.loggedAt }
    }

    // MARK: - 즐겨찾기 장소

    func addFavorite(label: String, place: Place) {
        favorites.append(FavoritePlace(label: label, place: place))
        saveFavorites()
    }

    func deleteFavorite(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        saveFavorites()
    }

    private func saveFavorites() {
        drvSaveFavoritesCount += 1   // SPEC-SYNC-004 §2.6 계수기(앱 논리 영향 없음)
        try? FileManager.default.createDirectory(at: AppConfig.supportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(favorites).write(to: favoritesURL)
    }

    private func loadFavorites() {
        guard let decoded: [FavoritePlace] = loadDataFile(favoritesURL) else { return }
        favorites = decoded
    }

    var directions: DirectionsService { DirectionsService(config: config) }
    var placeSearch: PlaceSearch { PlaceSearch(config: config) }

    /// 새 일정·활동의 "구글 캘린더에 보이기" 기본값. 연결이 없어도 값은 저장되므로 연결 상태로 가리지
    /// 않는다. 추가 화면 둘은 드라이버가 컴파일하지 못해서, 계산을 여기 한 곳에 두고 화면은 읽기만 하게 한다(계약 5).
    var calendarSyncDefault: Bool { config.autoAddToCalendar }

    /// Apple Calendar link (SPEC-APPLECAL-001): a no-op until the app attaches the real mirror.
    var calendarMirror: CalendarMirroring = NoCalendarMirror()
    @Published private(set) var calendarStatus: CalendarStatus = .idle

    func attachCalendar(_ mirror: AppleCalendarMirror) {
        mirror.onStatus = { [weak self] in self?.calendarStatus = $0 }
        // A store that is gone keeps every link: nothing is left to say a link is dead.
        mirror.retains = { [weak self] key in self?.retainsCalendarLink(key) ?? true }
        mirror.captureBaseline(activities)
        calendarMirror = mirror
    }

    func reconcileCalendar() { calendarMirror.reconcile(mirrorActivities()) }

    /// How many days after today the Apple Calendar mirror is given occurrences of a repeat.
    nonisolated static let mirrorWindowDays = 60

    /// What the Apple Calendar mirror is given: the stored activities plus the occurrences of every series from the start
    /// of today to `mirrorWindowDays` days later (a stored activity wins over an occurrence of the same id).
    func mirrorActivities(now: Date? = nil, calendar: Calendar = .current) -> [ActivityBlock] {
        let start = calendar.startOfDay(for: now ?? replanNow())
        guard let end = calendar.date(byAdding: .day, value: Self.mirrorWindowDays, to: start) else { return activities }
        return activities + computedOccurrences(in: DateInterval(start: start, end: end), calendar: calendar)
    }

    /// Whether the calendar link of an activity that is not in the mirror's list must stay: always while `series.json` is
    /// unreadable (the series that were lost with it are unknown), else when the key is a live occurrence of an existing
    /// series (a day the rule produces and that is not skipped). Anything else is an activity that is gone.
    // @MX:NOTE: a live occurrence outside the window is kept, not removed; only a skipped day, a deleted series or an id
    // that is no occurrence loses its event (REQ-017).
    func retainsCalendarLink(_ key: String) -> Bool {
        if seriesLoadFailed { return true }
        guard let id = UUID(uuidString: key), series(forOccurrence: id) != nil else { return false }
        return activity(id: id) != nil
    }


    /// 어떤 시간대 앞뒤로 사용자가 있을/가야 할 장소를 추정한다(판단은 `ScheduleLogic`이 한다).
    /// 식사 일정을 만들 때 출발지·복귀지를 미리 채워주는 데 쓴다.
    func surroundingPlaces(start: Date, end: Date) -> (before: (place: Place, label: String)?,
                                                       after: (place: Place, label: String)?) {
        // Series occurrences within 14 days either side count as neighbours (a stored activity has no such limit).
        let window = DateInterval(start: start.addingTimeInterval(-14 * 86400), end: end.addingTimeInterval(14 * 86400))
        return ScheduleLogic.surroundingPlaces(start: start, end: end,
                                               activities: activities + computedOccurrences(in: window, calendar: .current),
                                               events: events,
                                               home: favorites.first { $0.label == "Home" }?.place)
    }

    /// 모든 수단(`TransportMode.allCases`)의 이동시간을 한 번에 구한다(조회 전용).
    func travelEstimates(from origin: Place, to destination: Place) async -> [TransportMode: TravelEstimate] {
        await directions.estimateAll(
            from: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude),
            to: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude))
    }

    /// 이동시간만 조회한다(등록 요약을 즉시 채우고 addEvent의 재조회를 피할 때). 실패하면 nil.
    /// 여기서 받은 값을 `addEvent(travelSecondsHint:)`로 넘기면 생성할 때 다시 조회하지 않는다.
    func travelSeconds(from origin: Place, to destination: Place, mode: TransportMode) async -> TimeInterval? {
        await directions.estimate(
            mode,
            from: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude),
            to: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)).duration
    }

    // MARK: - 일정 추가/갱신

    /// 이동시간을 계산하고, 출발/알림 시각을 산정한 뒤 알림을 예약하고 저장한다.
    /// `anchor`가 `.arrival`이면 `anchorDate`는 "도착 시각"(출발을 역산), `.departure`면
    /// "출발 시각"(도착을 순산, 예: 퇴근/귀가) — 퇴근길처럼 출발 시각이 우선인 경우 버퍼가
    /// 의미 없어(도착 여유를 둘 필요가 없음) `.departure`에서는 bufferMinutes를 항상 0으로 둔다.
    /// 방금 만든 일정을 그대로 돌려준다 — 호출자가 제목·목적지로 되찾으면 같은 이름의 더 늦은
    /// 회차(도착일순 정렬이라 `.last`가 집는 쪽)를 집는다(2026-09-16 결함 J). @discardableResult인
    /// 이유: 다리 생성·수동 추가처럼 되찾을 일 없는 호출자가 대부분이라 반환 강제가 소음이 되고,
    /// 반환을 써야 하는 호출자(executeCreateSchedule)가 쓰는지는 드라이버 J절이 지킨다.
    @discardableResult
    func addEvent(title: String,
                  origin: Place,
                  destination: Place,
                  arrivalDate: Date,
                  mode: TransportMode,
                  bufferMinutes: Int,
                  notifyLeadMinutes: Int,
                  anchor: ScheduleAnchor = .arrival,
                  travelSecondsHint: TimeInterval? = nil,
                  linkedActivityId: UUID? = nil,
                  notifyEnabled: Bool = true,
                  syncToCalendar: Bool = true) async -> ScheduledEvent {
        var event = ScheduledEvent(title: title,
                                   origin: origin,
                                   destination: destination,
                                   arrivalDate: arrivalDate,
                                   mode: mode,
                                   bufferMinutes: anchor == .departure ? 0 : bufferMinutes,
                                   notifyLeadMinutes: notifyLeadMinutes)
        event.linkedActivityId = linkedActivityId
        event.notifyEnabled = notifyEnabled
        event.syncToCalendar = syncToCalendar
        // 호출부가 충돌 검사를 위해 이미 이동시간을 조회했다면 그 값을 쓴다(외부 API 중복 호출 방지).
        switch (anchor, travelSecondsHint) {
        case (.arrival, let hint?):
            applyCachedArrivalEstimate(to: &event, travelSeconds: hint, source: "Looked up")
        case (.departure, let hint?):
            applyCachedDepartureEstimate(to: &event, departureDate: arrivalDate, travelSeconds: hint, source: "Looked up")
        case (.arrival, nil): await applyEstimate(to: &event)
        case (.departure, nil): await applyDepartureAnchoredEstimate(to: &event, departureDate: arrivalDate)
        }
        events.append(event)
        events.sort { $0.arrivalDate < $1.arrivalDate }
        save()
        return event
    }


    /// 회차 하루의 (시작, 끝) — 그날 시작이 `now` 이후이고 끝이 시작보다 뒤일 때만 있다. 반복 저장의 회차별 관문이자
    /// AI 카드가 확정 전에 "지금 이후 회차가 있나"를 묻는 셈(LegCardForm.hasNoUpcomingOccurrence)의 단일 출처다 —
    /// 둘이 따로 세면 카드는 풀렸는데 저장은 0건이 되는 어긋남이 되살아난다(계약 5, 019 안전성 렌즈 m-2).
    static func occurrenceSpan(on day: Date, startHour: Int, startMinute: Int,
                               end: (hour: Int, minute: Int, dayDistance: Int),
                               after now: Date, calendar: Calendar) -> (start: Date, stop: Date)? {
        guard let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: day),
              start > now,
              let endDay = calendar.date(byAdding: .day, value: end.dayDistance, to: day),
              let stop = calendar.date(bySettingHour: end.hour, minute: end.minute, second: 0, of: endDay),
              stop > start else { return nil }
        return (start, stop)
    }

    /// The save of the manual New Activity card (SPEC-UIKIT-019, SPEC-RECURRULE-001), called by AddActivityView. An empty
    /// Repeat makes one stored activity (`addActivityWithTravel`). A repeat that stands makes one stored `RepeatSeries`
    /// (no copy per day): the rule is read again from the interpreted arguments (`RecurrenceRule.from(arguments:)`), the
    /// same rule-making and expansion code as the agent, so both cards make the same dates. The travel legs of the next
    /// `legWindowDays` days are made before the call returns (`fillSeriesLegs`). Nothing is made, and the result is false,
    /// when the card is not ready, an occurrence would end outside 24 hours after its start, no occurrence lies after the
    /// current time inside the horizon, or the series file cannot be written. The coordinates the screen holds are in the
    /// form (`form.confirmedPlaces`), so a name is not searched again.
    @discardableResult
    func saveManualActivity(_ form: LegCardForm, calendarDefault: Bool) async -> Bool {
        let card = form.card
        guard card.isReady else { return false }
        func field(_ key: String) -> EditField? { card.fields.first { $0.key == key } }
        func confirmedPlace(_ key: String) -> Place? {
            field(key).flatMap { $0.chosen == nil ? nil : form.confirmedPlaces[$0.id] }
        }
        guard let start = field("start_iso")?.chosen.flatMap({ BesirTime.parseDatetime($0)?.date }),
              let end = field("end_iso")?.chosen.flatMap({ BesirTime.parseDatetime($0)?.date }), end > start else { return false }
        let outboundOn = field(LegRowKeys.outboundEnabled)?.chosen == "true"
        let returnOn = field(LegRowKeys.returnEnabled)?.chosen == "true"
        let title = field("title")?.chosen ?? ""
        // "장소 없음" 행은 좌표 사전에 없는 값이라 여기서 nil로 풀린다 — Store에는 흘러가지 않는다.
        let location = confirmedPlace("location_query")
        let from = outboundOn ? confirmedPlace(LegRowKeys.originQuery) : nil
        let to = returnOn ? confirmedPlace(LegRowKeys.returnQuery) : nil
        let outboundMode = field(LegRowKeys.outboundMode)?.chosen.flatMap(TransportMode.init(rawValue:)) ?? .transit
        let returnMode = field(LegRowKeys.returnMode)?.chosen.flatMap(TransportMode.init(rawValue:)) ?? .transit
        // 여유 줄은 가는 편이 켜져 있어야 배열에 있으므로 폴백 0은 다리 없는 저장에만 닿는다.
        let buffer = field(LegRowKeys.bufferMinutes)?.chosen.flatMap { Int($0) } ?? 0
        // 알림 줄이 꺼져서 없으면 문법 값이 기억한 마지막 값을 쓴다(REQ-012).
        let notifyLead = field(LegRowKeys.notifyLeadMinutes)?.chosen.flatMap { Int($0) } ?? Int(form.lastNotifyLead) ?? 0
        let notifyOn = field(LegRowKeys.notifyEnabled)?.chosen != "false"
        let sync = field("calendar_sync")?.chosen.map { $0 == "true" } ?? calendarDefault

        guard let active = form.activeRecurrence else {
            _ = await addActivityWithTravel(title: title, location: location, startDate: start, endDate: end,
                                            travelFrom: from, returnTo: to, outboundMode: outboundMode, returnMode: returnMode,
                                            bufferMinutes: buffer, notifyLeadMinutes: notifyLead,
                                            notifyEnabled: notifyOn, syncToCalendar: sync)
            return true
        }
        // 반복 회차는 하루 안에 끝나야 한다 — 카드의 반복 끝 바퀴가 그 안에서만 고르게 하고, 여기는 AI 실행부와 같은 판정 함수
        // (occurrenceEndDayDistance)로 거는 마지막 방어다. 날짜 거리(0 또는 1)도 그 함수가 낸다.
        guard let rule = RecurrenceRule.from(arguments: active.arguments),
              let distance = RecurrenceRule.occurrenceEndDayDistance(start: start, end: end) else { return false }
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let startTod = cal.dateComponents([.hour, .minute], from: start)
        let endTod = cal.dateComponents([.hour, .minute], from: end)
        let lunar: RepeatSeries.LunarChoice? = rule.unit == .lunar
            ? (RecurrenceRule.defaultLunarIdentifier == .chinese ? .chinese : .dangi) : nil
        // The repeat is refused, and nothing is made, when no occurrence lies after the current time inside the horizon.
        let now = replanNow()
        let hasUpcoming = rule.firstDate(from: startDay,
                                         through: active.endDate ?? RecurrenceLine.endOfHorizon(from: startDay, calendar: cal),
                                         calendar: cal, lunarCalendar: lunar?.identifier ?? RecurrenceRule.defaultLunarIdentifier) {
            Self.occurrenceSpan(on: $0, startHour: startTod.hour ?? 0, startMinute: startTod.minute ?? 0,
                                end: (endTod.hour ?? 0, endTod.minute ?? 0, distance), after: now, calendar: cal) != nil
        } != nil
        guard hasUpcoming else { return false }
        // Travel legs: a direction is planned only when its toggle was on and its place was picked.
        let legPlan: LegPlan? = (from == nil && to == nil) ? nil
            : LegPlan(outboundFrom: from, returnTo: to, outboundMode: outboundMode, returnMode: returnMode,
                      bufferMinutes: Self.clampBuffer(buffer), notifyLeadMinutes: Self.clampNotifyLead(notifyLead),
                      notifyEnabled: notifyOn)
        let made = RepeatSeries(id: RepeatSeries.newID(), title: title, location: location, rule: rule,
                                lunarCalendar: lunar, firstDayKey: Self.dayKey(startDay, calendar: cal),
                                lastDayKey: active.endDate.map { Self.dayKey($0, calendar: cal) },
                                startMinute: (startTod.hour ?? 0) * 60 + (startTod.minute ?? 0),
                                endMinute: (endTod.hour ?? 0) * 60 + (endTod.minute ?? 0),
                                endDayDistance: distance, syncToCalendar: sync, legPlan: legPlan)
        guard addSeries(made) else { return false }
        // The legs of the next days are made before the save returns (a fill already running makes them in its next pass).
        await fillSeriesLegs()
        return true
    }

    // MARK: - Leg window fill (REQ-016, SPEC-RECURRULE-001)

    /// True while a fill runs. A call during it sets `fillAgain` and returns; the running fill then makes one more pass.
    private var fillInFlight = false
    private var fillAgain = false

    /// Test seam, driver-visible like `drvTravelLookupOverride`; application logic never sets it. Awaited once per pass,
    /// after the days to fill are chosen and before anything is written. A test closure suspends on its first call only,
    /// because the pass that `fillAgain` asks for reaches the gate too.
    var drvFillGate: (() async -> Void)?
    /// Driver-visible counter of the passes that reached the gate point (before the closure runs); a test polls it to
    /// know that a held call is at the gate. Application logic never reads it.
    var drvFillGateReached = 0

    private struct LegFillKey: Hashable {
        let seriesID: UUID
        let role: ScheduleAnchor
    }

    private struct LegFillRoute {
        let origin: Place
        let destination: Place
        let mode: TransportMode
    }

    private struct LegFillAttempt {
        let result: (seconds: TimeInterval, source: String)?
    }

    /// What one series still needs for the window at a clock: the occurrences and roles that have no leg yet, and the
    /// legs it made earlier that still have no travel time (a lookup failed, for example because the phone was offline).
    private struct LegFillWork {
        let series: RepeatSeries
        let plan: LegPlan
        let place: Place
        let endKey: Int
        let legs: [(occurrence: ActivityBlock, role: ScheduleAnchor)]
        let untimed: [(id: UUID, role: ScheduleAnchor)]
    }

    /// Makes the legs of every series with a leg plan for the occurrences from today through `legWindowDays` that the
    /// series' high-water mark has not passed, removes the legs of unstored occurrences older than `legRetentionDays`,
    /// moves the legs of unstored occurrences that are off their occurrence's anchor (a time zone change) onto it, gives a
    /// travel time to the legs of unstored occurrences from today on that an earlier fill left without one (a lookup
    /// failed; the high-water mark does not stop this retry), and saves `events` once and reschedules the alarms once per
    /// pass. Idempotent. One fill runs at a time: a call
    /// during a running fill sets `fillAgain` and returns, and the running fill makes another pass, so a series saved
    /// meanwhile is not lost and no leg is made twice. The days are chosen before the awaits (the gate and the travel-time
    /// lookups) and chosen again after them, per chosen series, so a skip, a series delete, a leg add or a mark that
    /// changed during an await is respected.
    func fillSeriesLegs(now: Date? = nil) async {
        guard !fillInFlight else {
            fillAgain = true
            return
        }
        fillInFlight = true
        defer { fillInFlight = false }
        repeat {
            fillAgain = false
            await fillPass(now: now ?? replanNow())
        } while fillAgain
    }

    /// The fill of the foreground and of the background task: the legs of the window, the live re-estimates of the legs
    /// that are about to start, and the nearest alarms, in that order.
    func backgroundRefresh() async {
        await fillSeriesLegs()
        await refreshUpcomingEstimates(trigger: .background)
        rescheduleNearestNotifications()
    }

    private func legFillRoute(_ plan: LegPlan, place: Place, role: ScheduleAnchor) -> LegFillRoute? {
        if role == .arrival {
            return plan.outboundFrom.map { LegFillRoute(origin: $0, destination: place, mode: plan.outboundMode) }
        }
        return plan.returnTo.map { LegFillRoute(origin: place, destination: $0, mode: plan.returnMode) }
    }

    /// The days to fill for one series at `now`: `key >= today`, `key <= today + legWindowDays`, `key` above the series'
    /// mark, started after `now` (the per-occurrence gate of the removed writer), not skipped, not stored, and without a
    /// stored leg of the role. The untimed legs are the legs of the same days (the high-water mark does not apply to
    /// them) that are on the plan's route and mode and have no travel time. Nil when the series is gone or cannot have
    /// legs (no place, or no direction in its plan).
    private func legFillWork(for seriesID: UUID, now: Date, calendar: Calendar) -> LegFillWork? {
        guard let s = series.first(where: { $0.id == seriesID }), let plan = s.legPlan, let place = s.location,
              plan.outboundFrom != nil || plan.returnTo != nil else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let windowEnd = calendar.date(byAdding: .day, value: Self.legWindowDays, to: today),
              let after = calendar.date(byAdding: .day, value: 1, to: windowEnd) else { return nil }
        let todayKey = Self.dayKey(today, calendar: calendar), endKey = Self.dayKey(windowEnd, calendar: calendar)
        let storedIDs = Set(activities.map { $0.id })
        var legs: [(occurrence: ActivityBlock, role: ScheduleAnchor)] = []
        var untimed: [(id: UUID, role: ScheduleAnchor)] = []
        for occurrence in s.occurrences(in: DateInterval(start: today, end: after), calendar: calendar) {
            guard let dayKey = RepeatSeries.decode(occurrence.id)?.dayKey,
                  dayKey >= todayKey, dayKey <= endKey,
                  occurrence.startDate > now, !storedIDs.contains(occurrence.id) else { continue }
            let present = explicitLegs(of: occurrence.id)
            for leg in present where leg.travelSeconds == nil {
                let role: ScheduleAnchor = leg.anchor == .departure ? .departure : .arrival
                guard let route = legFillRoute(plan, place: place, role: role), leg.origin == route.origin,
                      leg.destination == route.destination, leg.mode == route.mode else { continue }
                untimed.append((leg.id, role))
            }
            // The mark applies to the legs to make only: a failed lookup leaves the mark at the window end.
            guard s.legsFilledThroughDayKey.map({ dayKey > $0 }) ?? true else { continue }
            if plan.outboundFrom != nil, !present.contains(where: { ($0.anchor ?? .arrival) == .arrival }) {
                legs.append((occurrence, .arrival))
            }
            if plan.returnTo != nil, !present.contains(where: { $0.anchor == .departure }) {
                legs.append((occurrence, .departure))
            }
        }
        return LegFillWork(series: s, plan: plan, place: place, endKey: endKey, legs: legs, untimed: untimed)
    }

    /// The travel time new legs of the series copy in the direction of `role`: the one the most legs carry, among the legs
    /// of the series on the same route and by the same mode (so a changed plan is not given the time of an old route).
    /// The legs of unstored occurrences count first; only when none of them has a time do the legs of stored copies
    /// (they link to an occurrence) count. A tie goes to the time of the leg with the latest arrival, then to the smaller
    /// time, so the choice does not depend on the order of `events`.
    // @MX:NOTE: the first leg found used to be copied (F7 of the t60 review): a leg the live re-estimate had adjusted, or
    // one the user edited, spread its time to every leg made after it. A stored copy is where an edit lands, so its legs
    // are the second tier, and within a tier the most common time wins over any single leg.
    private func storedLegSeconds(for work: LegFillWork, role: ScheduleAnchor) -> TimeInterval? {
        guard let route = legFillRoute(work.plan, place: work.place, role: role) else { return nil }
        let storedIDs = Set(activities.map { $0.id })
        var unstored: [(seconds: TimeInterval, arrival: Date)] = []
        var all: [(seconds: TimeInterval, arrival: Date)] = []
        for e in events {
            guard let seconds = e.travelSeconds, (e.anchor ?? .arrival) == role, e.mode == route.mode,
                  e.origin == route.origin, e.destination == route.destination else { continue }
            let owner = e.linkedActivityId.flatMap { series(forOccurrence: $0)?.0.id }
            guard e.recurrenceId == work.series.id || owner == work.series.id else { continue }
            all.append((seconds, e.arrivalDate))
            if let link = e.linkedActivityId, !storedIDs.contains(link), owner == work.series.id {
                unstored.append((seconds, e.arrivalDate))
            }
        }
        var tally: [TimeInterval: (count: Int, latest: Date)] = [:]
        for leg in unstored.isEmpty ? all : unstored {
            let seen = tally[leg.seconds]
            tally[leg.seconds] = ((seen?.count ?? 0) + 1, max(seen?.latest ?? .distantPast, leg.arrival))
        }
        return tally.max { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            if a.value.latest != b.value.latest { return a.value.latest < b.value.latest }
            return a.key > b.key
        }?.key
    }

    private func fillPass(now: Date) async {
        let calendar = Calendar.current
        // Choose: the series that can have legs, and the directions that need one lookup because no stored leg of the
        // series and direction carries a travel time. A direction needs one for the legs to make and for the untimed
        // legs together, so a retry costs the lookup of the fill and no more.
        var chosen: [UUID] = []
        var lookups: [(key: LegFillKey, route: LegFillRoute)] = []
        for s in series {
            guard let work = legFillWork(for: s.id, now: now, calendar: calendar) else { continue }
            chosen.append(s.id)
            for role in [ScheduleAnchor.arrival, ScheduleAnchor.departure]
            where (work.legs.contains(where: { $0.role == role }) || work.untimed.contains(where: { $0.role == role }))
                && storedLegSeconds(for: work, role: role) == nil {
                if let route = legFillRoute(work.plan, place: work.place, role: role) {
                    lookups.append((LegFillKey(seriesID: s.id, role: role), route))
                }
            }
        }
        drvFillGateReached += 1
        await drvFillGate?()
        // The only other await: one lookup per direction per series.
        var attempts: [LegFillKey: LegFillAttempt] = [:]
        for item in lookups {
            let found = await lookupTravelSeconds(item.route.mode, origin: item.route.origin, destination: item.route.destination)
            attempts[item.key] = LegFillAttempt(result: found.map { (seconds: $0.seconds, source: $0.source) })
        }

        // Write, with no await from here on. Each chosen series is read again, so what changed meanwhile is respected.
        var made: [ScheduledEvent] = []
        var retimed: [(id: UUID, role: ScheduleAnchor, seconds: TimeInterval, source: String?)] = []
        var updatedSeries = series
        var seriesChanged = false
        for id in chosen {
            guard let work = legFillWork(for: id, now: now, calendar: calendar),
                  let index = updatedSeries.firstIndex(where: { $0.id == id }) else { continue }
            var complete = true
            var lookupSourceUsed = Set<ScheduleAnchor>()
            for item in work.legs {
                guard let route = legFillRoute(work.plan, place: work.place, role: item.role) else { continue }
                var seconds = storedLegSeconds(for: work, role: item.role)
                var source: String?
                if seconds == nil {
                    // No stored leg to copy from: the lookup of this fill, if one was made for the direction.
                    guard let attempt = attempts[LegFillKey(seriesID: id, role: item.role)] else {
                        complete = false   // the stored leg this relied on is gone; the next fill looks it up
                        continue
                    }
                    seconds = attempt.result?.seconds
                    if lookupSourceUsed.insert(item.role).inserted { source = attempt.result?.source }
                }
                made.append(makeSeriesLeg(for: work, route: route, occurrence: item.occurrence, role: item.role,
                                          seconds: seconds, source: source))
            }
            // The legs an earlier fill left untimed get the time a stored leg carries, or else the lookup's. A failed
            // lookup changes nothing, and the mark (about the legs to make) is not touched either way.
            for item in work.untimed {
                var seconds = storedLegSeconds(for: work, role: item.role)
                var source: String?
                if seconds == nil {
                    guard let found = attempts[LegFillKey(seriesID: id, role: item.role)]?.result else { continue }
                    seconds = found.seconds
                    if lookupSourceUsed.insert(item.role).inserted { source = found.source }
                }
                if let seconds { retimed.append((item.id, item.role, seconds, source)) }
            }
            if complete {
                let mark = max(work.series.legsFilledThroughDayKey ?? 0, work.endKey)
                if mark != work.series.legsFilledThroughDayKey {
                    updatedSeries[index].legsFilledThroughDayKey = mark
                    seriesChanged = true
                }
            }
        }

        var pruned: [ScheduledEvent] = []
        if let cutoff = calendar.date(byAdding: .day, value: -Self.legRetentionDays, to: now) {
            for s in series { pruned += unstoredOccurrenceLegs(of: s.id).filter { $0.arrivalDate < cutoff } }
        }
        let realigned = realignedSeriesLegs(calendar: calendar)
        if !made.isEmpty || !pruned.isEmpty || realigned != nil || !retimed.isEmpty {
            for e in pruned { if let nid = e.notificationId { notifications.cancel(id: nid) } }
            let prunedIDs = Set(pruned.map { $0.id })
            var updated = realigned ?? events
            updated.removeAll { prunedIDs.contains($0.id) }
            updated.append(contentsOf: made)
            // The retime follows the realignment, so a leg is timed from the date it now stands on. The alarm each helper
            // hands over is cancelled and set again by the reschedule below, the way the legs to make are.
            for item in retimed {
                guard let i = updated.firstIndex(where: { $0.id == item.id }), updated[i].travelSeconds == nil else { continue }
                var leg = updated[i]
                if item.role == .arrival {
                    if let source = item.source {
                        applyCachedArrivalEstimate(to: &leg, travelSeconds: item.seconds, source: source)
                    } else {
                        applyCachedArrivalEstimate(to: &leg, travelSeconds: item.seconds)
                    }
                } else {
                    let departure = leg.departureDate ?? leg.arrivalDate
                    if let source = item.source {
                        applyCachedDepartureEstimate(to: &leg, departureDate: departure, travelSeconds: item.seconds, source: source)
                    } else {
                        applyCachedDepartureEstimate(to: &leg, departureDate: departure, travelSeconds: item.seconds)
                    }
                }
                updated[i] = leg
            }
            updated.sort { $0.arrivalDate < $1.arrivalDate }
            events = updated
            // The save of the reschedule writes `events` once. The legs reach the disk before the mark: a crash between
            // the two leaves legs and an old mark, and the role check of the next fill makes no second leg.
            rescheduleNearestNotifications()
        }
        if seriesChanged {
            series = updatedSeries
            saveSeries()
        }
    }

    /// The events with the legs of live computed occurrences moved onto their occurrence's anchor, or nil when none is off
    /// it. A leg of a stored copy, an event with no link and a link that is no live occurrence (a skipped day, no series) are
    /// left alone. The anchor side (the one `anchorDate` reads) is set to the occurrence's time exactly and the other side
    /// moves by the same difference, so the travel time, buffer, lead, ids and `recurrenceId` stay. No clock, no await.
    // @MX:NOTE: every leg of an unstored occurrence sits on its occurrence's anchor (the start for an outbound leg, the end
    // for a return leg): each writer builds it there and each path that moves one leg off it materializes the occurrence.
    // A computed occurrence follows `Calendar.current`, a leg is an absolute date, so after a time zone change the two
    // part; the fill pass checks the invariant and moves the legs, whether or not the zone changed.
    private func realignedSeriesLegs(calendar: Calendar) -> [ScheduledEvent]? {
        guard !series.isEmpty else { return nil }
        let stored = Set(activities.map { $0.id })
        var shifted = events
        var moved = false
        for i in shifted.indices {
            guard let link = shifted[i].linkedActivityId, !stored.contains(link),
                  let occurrence = activity(id: link, calendar: calendar) else { continue }
            let event = shifted[i]
            let departureAnchored = event.anchor == .departure
            let delta = (departureAnchored ? occurrence.endDate : occurrence.startDate).timeIntervalSince(event.anchorDate)
            guard delta != 0 else { continue }
            if departureAnchored, event.departureDate != nil {
                shifted[i].departureDate = occurrence.endDate
                shifted[i].arrivalDate = event.arrivalDate.addingTimeInterval(delta)
            } else {
                shifted[i].arrivalDate = departureAnchored ? occurrence.endDate : occurrence.startDate
                shifted[i].departureDate = event.departureDate?.addingTimeInterval(delta)
            }
            moved = true
        }
        return moved ? shifted : nil
    }

    /// One leg of the fill, built the way the removed writer built it: linked to the occurrence id, carrying the series
    /// id, anchored on the start (outbound) or the end (return) of the occurrence. The travel time is copied (`seconds`,
    /// the most common time of the series' legs, see `storedLegSeconds`); a nil `seconds` (a failed lookup) leaves the leg
    /// with its direction and its fixed time, which a later fill gives a time to (the retry in `fillPass`).
    private func makeSeriesLeg(for work: LegFillWork, route: LegFillRoute, occurrence: ActivityBlock,
                               role: ScheduleAnchor, seconds: TimeInterval?, source: String?) -> ScheduledEvent {
        let outbound = role == .arrival
        let anchorDate = outbound ? occurrence.startDate : occurrence.endDate
        var event = ScheduledEvent(title: legTitle(role: role, activity: occurrence), origin: route.origin,
                                   destination: route.destination, arrivalDate: anchorDate, mode: route.mode,
                                   bufferMinutes: outbound ? work.plan.bufferMinutes : 0,
                                   notifyLeadMinutes: work.plan.notifyLeadMinutes)
        event.recurrenceId = work.series.id
        event.linkedActivityId = occurrence.id
        event.notifyEnabled = work.plan.notifyEnabled
        event.syncToCalendar = work.series.syncToCalendar
        if outbound {
            event.anchor = .arrival
            if let seconds {
                if let source {
                    applyCachedArrivalEstimate(to: &event, travelSeconds: seconds, source: source)
                } else {
                    applyCachedArrivalEstimate(to: &event, travelSeconds: seconds)
                }
            }
        } else {
            // The direction and the fixed departure are set before any estimate, so a failed lookup still leaves a leg a
            // later re-estimate can pick up.
            event.anchor = .departure
            event.departureDate = anchorDate
            if let seconds {
                if let source {
                    applyCachedDepartureEstimate(to: &event, departureDate: anchorDate, travelSeconds: seconds, source: source)
                } else {
                    applyCachedDepartureEstimate(to: &event, departureDate: anchorDate, travelSeconds: seconds)
                }
            }
        }
        return event
    }

    /// recurrenceId로 반복 그룹의 이동 구간을 도착 순으로 돌려준다 — 멤버십·정렬 판단의 단일 출처(계약 5).
    func recurringSeries(_ recurrenceId: UUID) -> [ScheduledEvent] {
        events.filter { $0.recurrenceId == recurrenceId }.sorted { $0.arrivalDate < $1.arrivalDate }
    }

    // MARK: - "반복 전체" 이동 추가(SPEC-ONTIME-008 REQ-016, P-12)

    /// "반복 전체 / 이 일정만" 선택창의 숫자를 **저장 없이** 먼저 계산해 준다(렌즈 B.1 — 선택창은
    /// Store 쓰기 앞에 떠야 하므로 읽기 전용이다). 대상은 선택창을 연 순간의 형제(siblingOccurrences,
    /// 번호만) 중 시작이 지나지 않은 것(J-17 — 지난 회차는 세지도 붙이지도 않는다). 건너뜀 이유는
    /// "이미 있음·장소 없음" 둘뿐(J-14)이고 빠진 회차는 번호가 없어 애초에 형제 집합에 없다.
    struct SeriesLegAddPreview {
        let seriesId: UUID
        /// 시작 안 지난 형제(편집 회차 포함) — 선택창을 연 순간에 잡은 집합. addLegToSeries가
        /// 이 id 목록을 그대로 받아, 같은 저장에서 편집 회차가 먼저 빠져도 그 회차의 이동을 놓치지
        /// 않는다.
        let eligibleIds: [UUID]
        /// 장소 있고 그 역할 이동이 없어 붙일 회차 — 선택창의 "N개 회차에 붙여요" 숫자.
        let wouldAddIds: [UUID]
        let alreadyHasRoleCount: Int
        let noPlaceCount: Int
    }

    func previewSeriesLegAdd(activityId: UUID, role: ScheduleAnchor) -> SeriesLegAddPreview? {
        guard let edited = activity(id: activityId),
              let rid = edited.recurrenceId else { return nil }
        let now = replanNow()
        var eligible: [UUID] = []
        var wouldAdd: [UUID] = []
        var hasRole = 0, noPlace = 0
        for sibling in siblingOccurrences(of: edited) where sibling.startDate > now {
            eligible.append(sibling.id)
            if explicitLegs(of: sibling.id).contains(where: { ($0.anchor ?? .arrival) == role }) {
                hasRole += 1
            } else if sibling.location == nil {
                noPlace += 1
            } else {
                wouldAdd.append(sibling.id)
            }
        }
        return SeriesLegAddPreview(seriesId: rid, eligibleIds: eligible, wouldAddIds: wouldAdd,
                                   alreadyHasRoleCount: hasRole, noPlaceCount: noPlace)
    }

    /// Adds a leg to the whole series (REQ-016). It is the second way legs are made (the fill is the first; a single
    /// occurrence goes through addLeg). The target set is the targetActivityIds taken when the dialog opened (the preview's
    /// eligibleIds), taken as they are. The order inside the save (P-12): 2. the siblings get the leg, 3. the edited
    /// occurrence gets it too (without a number when editedDetaches), 4. the edited occurrence leaves the series last.
    /// Only the first occurrence is looked up and the rest copy it (REQ-005), and activities and events are each saved
    /// once, with one reschedule. Calendar consent follows each activity's wantsCalendarSync (the same rule as addLeg;
    /// autoAddToCalendar is a setting for automatic adding, not consent). "This event only" does not come through here: addLeg
    /// does it alone (the leg it makes has no number, and the detach inside addLeg takes that occurrence out).
    @discardableResult
    func addLegToSeries(editedActivityId: UUID,
                        seriesId: UUID,
                        role: ScheduleAnchor,
                        outerPlace: Place,
                        mode: TransportMode,
                        bufferMinutes: Int,
                        notifyLeadMinutes: Int,
                        notifyEnabled: Bool = true,
                        targetActivityIds: [UUID],
                        editedDetaches: Bool) async
        -> (added: Int, skippedExisting: Int, skippedNoPlace: Int) {
        var created: [ScheduledEvent] = []
        var added = 0, skippedExisting = 0, skippedNoPlace = 0
        var firstDone = false
        var cachedSeconds: TimeInterval?
        for tid in targetActivityIds {
            // 선택창과 저장 사이에 회차가 바뀌거나 사라졌을 수 있다 — 조사와 같은 판정으로 다시
            // 걸러 센다(건너뜀 건수가 선택창 숫자와 어긋나지 않게).
            guard let occurrence = activity(id: tid) else { continue }
            if explicitLegs(of: tid).contains(where: { ($0.anchor ?? .arrival) == role }) {
                skippedExisting += 1
                continue
            }
            guard let place = occurrence.location else {
                skippedNoPlace += 1
                continue
            }
            var leg = ScheduledEvent(title: legTitle(role: role, activity: occurrence),
                                     origin: role == .departure ? place : outerPlace,
                                     destination: role == .departure ? outerPlace : place,
                                     arrivalDate: legAnchor(role: role, activity: occurrence),
                                     mode: mode,
                                     bufferMinutes: role == .departure ? 0 : bufferMinutes,
                                     notifyLeadMinutes: notifyLeadMinutes)
            leg.linkedActivityId = occurrence.id
            leg.notifyEnabled = notifyEnabled
            leg.syncToCalendar = occurrence.wantsCalendarSync
            // 같은 저장에서 편집 회차가 빠지면(회차를 바꿨거나 "이 일정만"을 골랐을 때) 그 회차의
            // 이동은 번호 없이 만든다(REQ-016 끝 문장).
            if tid == editedActivityId && editedDetaches {
                leg.recurrenceId = nil
            } else {
                leg.recurrenceId = occurrence.recurrenceId ?? seriesId
            }
            switch role {
            case .arrival:
                leg.anchor = .arrival
                if !firstDone {
                    await applyEstimate(to: &leg)
                    cachedSeconds = leg.travelSeconds
                    firstDone = true
                } else if let seconds = cachedSeconds {
                    applyCachedArrivalEstimate(to: &leg, travelSeconds: seconds)
                }
            case .departure:
                // 방향은 조회 결과와 무관하게 먼저 못 박는다 — 첫 회차는 applyDepartureAnchoredEstimate가
                // 조회 전에 세우지만, 둘째 회차부터 쓰는 캐시 복사는 값이 있을 때만 세운다. 첫 조회가
                // 실패하면 캐시가 비어 anchor가 nil로 남고, nil은 "도착 기준(가는 이동)"으로 읽힌다
                // (t50 sync F1). makeLeg의 .departure 갈래와 같은 모양. 출발 시각도 같은 이유로 먼저
                // 세운다 — 출발 기준 구간은 이 값이 곧 고정 기준이라, 비면 재조회 대상(selectRefreshTargets의
                // departureDate guard)에서 빠져 첫 조회 실패 뒤 둘째 회차부터 출발 알림이 영영 안 선다(N-1).
                leg.anchor = .departure
                leg.departureDate = leg.arrivalDate
                if !firstDone {
                    await applyDepartureAnchoredEstimate(to: &leg, departureDate: leg.arrivalDate)
                    cachedSeconds = leg.travelSeconds
                    firstDone = true
                } else if let seconds = cachedSeconds {
                    applyCachedDepartureEstimate(to: &leg, departureDate: leg.arrivalDate, travelSeconds: seconds)
                }
            }
            created.append(leg)
            added += 1
        }
        guard !created.isEmpty else { return (added, skippedExisting, skippedNoPlace) }
        events.append(contentsOf: created)
        events.sort { $0.arrivalDate < $1.arrivalDate }
        // 순서 ④ — 편집 회차의 빠짐은 이동 추가 **뒤, 저장 직전**에(REQ-016). 몸통(저장 없음)을
        // 직접 써 activities·events 저장을 각 한 번으로 유지한다(REQ-005).
        var detachedActivity = false
        // A computed series keeps the role in its leg plan, so later fills carry it.
        recordLegRole(role, inSeries: seriesId, outerPlace: outerPlace, mode: mode, bufferMinutes: bufferMinutes,
                      notifyLeadMinutes: notifyLeadMinutes, notifyEnabled: notifyEnabled)
        if editedDetaches {
            // A computed edited occurrence becomes a stored copy (and saves itself); a stored one is cleared as before.
            if materialize(editedActivityId) == nil {
                detachedActivity = clearSeriesMembership(activityId: editedActivityId).activity
            }
        }
        if detachedActivity { saveActivities() }
        // The save() at the tail of this reschedule writes the whole events batch once (the leg fill has the same
        // shape); a save() of its own here would make the single save two.
        rescheduleNearestNotifications()
        return (added, skippedExisting, skippedNoPlace)
    }

    /// Writes the role of a whole-series leg add into the leg plan of a computed series (created when it had none) and,
    /// only when the series has no mark yet, sets the mark to the key of today + `legWindowDays` so the next fill does not
    /// make the same legs again. A mark that exists is left alone: raising it would hide the days between the old mark
    /// and the window end from the old role, which no fill has made yet.
    private func recordLegRole(_ role: ScheduleAnchor, inSeries seriesID: UUID, outerPlace: Place, mode: TransportMode,
                               bufferMinutes: Int, notifyLeadMinutes: Int, notifyEnabled: Bool) {
        guard let index = series.firstIndex(where: { $0.id == seriesID }) else { return }
        var updated = series[index]
        var plan = updated.legPlan ?? LegPlan(outboundFrom: nil, returnTo: nil, outboundMode: mode, returnMode: mode,
                                              bufferMinutes: role == .arrival ? bufferMinutes : 0,
                                              notifyLeadMinutes: notifyLeadMinutes, notifyEnabled: notifyEnabled)
        if role == .arrival {
            plan.outboundFrom = outerPlace
            plan.outboundMode = mode
            plan.bufferMinutes = bufferMinutes
        } else {
            plan.returnTo = outerPlace
            plan.returnMode = mode
        }
        updated.legPlan = plan
        if updated.legsFilledThroughDayKey == nil {
            let calendar = Calendar.current
            if let end = calendar.date(byAdding: .day, value: Self.legWindowDays, to: calendar.startOfDay(for: replanNow())) {
                updated.legsFilledThroughDayKey = Self.dayKey(end, calendar: calendar)
            }
        }
        series[index] = updated
        saveSeries()
    }

    /// 반복 일정 그룹 전체를 한 번에 삭제한다(이동 구간 + 활동 블록 + 알림 포함).
    /// 삭제는 그 번호만 본다(같은 요청이 만든 다른 반복—점심—은 남는다). 지워질 활동에
    /// 연결된 구간까지 따라간다(REQ-009) — 연결 구간은 번호가 없거나(회차에 나중에 붙인 이동)
    /// 다른 번호를 실어도, 지워진 활동을 가리키는 매달린 연결을 남겨선 안 된다. 정리 절차
    /// (알림 취소·식사 기록)는 아래 이미 있는 흐름을 그대로 확장한 것 — 두 벌로
    /// 만들지 않는다(계약 5).
    func deleteRecurringSeries(_ recurrenceId: UUID) {
        // A computed series has no records to remove: the rule goes, with the legs of its unstored occurrences.
        if series.contains(where: { $0.id == recurrenceId }) {
            deleteComputedSeries(recurrenceId)
            return
        }
        let activityGroup = activities.filter { $0.recurrenceId == recurrenceId }
        let activityIDs = Set(activityGroup.map { $0.id })
        // 같은 번호의 구간은 앞의 필터에 이미 들어 있으므로 여기선 제외해 group에 중복을 만들지 않는다.
        let linked = events.filter { e in
            guard let link = e.linkedActivityId else { return false }
            return e.recurrenceId != recurrenceId && activityIDs.contains(link)
        }
        let group = recurringSeries(recurrenceId) + linked
        for e in group {
            if let nid = e.notificationId { notifications.cancel(id: nid) }
        }
        events.removeAll {
            $0.recurrenceId == recurrenceId
                || ($0.linkedActivityId.map { activityIDs.contains($0) } ?? false)
        }
        save()

        activities.removeAll { $0.recurrenceId == recurrenceId }
        saveActivities()
        removeUpcomingMeals(eventIDs: Set(group.map { $0.id }),
                            activityIDs: activityIDs)
    }

    /// The legs of the unstored occurrences of a computed series: events whose linked activity id is an occurrence id of
    /// the series and has no stored activity. A materialized copy keeps its legs, so its id is left out.
    private func unstoredOccurrenceLegs(of seriesID: UUID) -> [ScheduledEvent] {
        let stored = Set(activities.map { $0.id })
        return events.filter { e in
            guard let link = e.linkedActivityId, !stored.contains(link),
                  let (owner, _) = series(forOccurrence: link) else { return false }
            return owner.id == seriesID
        }
    }

    /// `Delete Entire Series` on a computed series: the series, the events that carry its id, and the legs of its
    /// unstored occurrences go, with their pending alarms and the upcoming meals logged against them. A materialized
    /// copy and its legs stay, even when a leg still carries the series id (the state a crash while saving the copy
    /// leaves); that id is cleared, so no event keeps the id of a series that no longer exists.
    private func deleteComputedSeries(_ seriesID: UUID) {
        let stored = Set(activities.map { $0.id })
        let unstored = unstoredOccurrenceLegs(of: seriesID)
        let unstoredIDs = Set(unstored.map { $0.id })
        let group = events.filter { e in
            if unstoredIDs.contains(e.id) { return true }
            guard e.recurrenceId == seriesID else { return false }
            return !(e.linkedActivityId.map { stored.contains($0) } ?? false)
        }
        for e in group {
            if let nid = e.notificationId { notifications.cancel(id: nid) }
        }
        let groupIDs = Set(group.map { $0.id })
        var kept = events.filter { !groupIDs.contains($0.id) }
        for i in kept.indices where kept[i].recurrenceId == seriesID { kept[i].recurrenceId = nil }
        events = kept
        save()
        series.removeAll { $0.id == seriesID }
        saveSeries()
        removeUpcomingMeals(eventIDs: groupIDs, activityIDs: Set(group.compactMap { $0.linkedActivityId }))
    }

    /// 반복 일정 그룹 전체의 이동수단·버퍼·알림 리드타임을 바꾸고 이동시간을 다시 계산한다(새로
    /// 만들지 않고 기존 그룹을 그대로 갱신 — AI 채팅에서 "방금 만든 일정 자동차로 바꿔줘" 같은
    /// 수정 요청을 다시 create로 처리하면 중복 생성되므로 이 경로로 처리한다).
    /// 반환값은 갱신된 일정 수(0이면 해당 recurrenceId 없음).
    @discardableResult
    func updateRecurringSeries(_ recurrenceId: UUID,
                               mode: TransportMode?,
                               bufferMinutes: Int?,
                               notifyLeadMinutes: Int?) async -> Int {
        let ids = recurringSeries(recurrenceId).map(\.id)
        guard !ids.isEmpty else { return 0 }

        // To save API calls only the first occurrence looks up the new travel time and the rest copy it (the leg fill
        // does the same).
        var cachedTravelSeconds: TimeInterval?
        var firstDone = false
        for id in ids {
            guard let idx = events.firstIndex(where: { $0.id == id }) else { continue }
            var event = events[idx]
            if let mode { event.mode = mode }
            // 출발 기준(귀가 등) 구간은 버퍼 개념이 없다 — 항상 0으로 강제. 음수 버퍼는 매 회차
            // 늦게 출발하게 만들므로, clampBuffer의 상하한으로 묶는다.
            if let bufferMinutes { event.bufferMinutes = (event.anchor == .departure) ? 0 : Self.clampBuffer(bufferMinutes) }
            if let notifyLeadMinutes { event.notifyLeadMinutes = Self.clampNotifyLead(notifyLeadMinutes) }
            switch event.anchor ?? .arrival {
            case .arrival:
                if !firstDone {
                    await applyEstimate(to: &event)
                    cachedTravelSeconds = event.travelSeconds
                    firstDone = true
                } else if let secs = cachedTravelSeconds {
                    applyCachedArrivalEstimate(to: &event, travelSeconds: secs)
                }
            case .departure:
                if let dep = event.departureDate {
                    if !firstDone {
                        await applyDepartureAnchoredEstimate(to: &event, departureDate: dep)
                        cachedTravelSeconds = event.travelSeconds
                        firstDone = true
                    } else if let secs = cachedTravelSeconds {
                        applyCachedDepartureEstimate(to: &event, departureDate: dep, travelSeconds: secs)
                    }
                }
            }
            // await(이동시간 조회) 사이 동기화·삭제로 배열이 바뀔 수 있으니 쓸 때 id로 다시 찾는다.
            guard let writeIdx = events.firstIndex(where: { $0.id == id }) else { continue }
            events[writeIdx] = event
        }
        events.sort { $0.arrivalDate < $1.arrivalDate }
        save()

        // 수정 뒤에도 iOS 알림 64건 한도는 그대로다 — 생성 경로와 같은 이유로 가까운 것부터 다시 채운다.
        rescheduleNearestNotifications()
        return ids.count
    }

    /// 기존 일정의 모든 필드를 수정하고, 이동시간·출발시각·알림을 다시 계산한다.
    /// `travelSecondsHint`는 addEvent의 같은 인자와 같은 역할 — 폼이 이미 보여준 이동시간이
    /// 있으면 그 값으로 산정하고 저장마다 외부 조회를 다시 하지 않는다.
    func updateEvent(id: UUID,
                     title: String,
                     origin: Place,
                     destination: Place,
                     arrivalDate: Date,
                     mode: TransportMode,
                     bufferMinutes: Int,
                     notifyLeadMinutes: Int,
                     anchor: ScheduleAnchor = .arrival,
                     travelSecondsHint: TimeInterval? = nil,
                     notifyEnabled: Bool? = nil,
                     syncToCalendar: Bool? = nil) async {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        var event = events[idx]
        event.title = title
        event.origin = origin
        event.destination = destination
        event.arrivalDate = arrivalDate
        event.mode = mode
        event.bufferMinutes = anchor == .departure ? 0 : bufferMinutes
        event.notifyLeadMinutes = notifyLeadMinutes
        if let notifyEnabled { event.notifyEnabled = notifyEnabled }
        if let syncToCalendar { event.syncToCalendar = syncToCalendar }
        // 폼이 이미 보여준 이동시간이 있으면 그 값으로 산정한다(addEvent의 같은 스위치와 같은
        // 이유 — 외부 API 중복 호출 방지). 힌트가 없을 때만 다시 조회한다.
        switch (anchor, travelSecondsHint) {
        case (.arrival, let hint?):
            applyCachedArrivalEstimate(to: &event, travelSeconds: hint, source: "Looked up")
        case (.departure, let hint?):
            applyCachedDepartureEstimate(to: &event, departureDate: arrivalDate, travelSeconds: hint, source: "Looked up")
        case (.arrival, nil): await applyEstimate(to: &event)
        case (.departure, nil): await applyDepartureAnchoredEstimate(to: &event, departureDate: arrivalDate)
        }
        // await(이동시간 조회) 사이 동기화·삭제로 배열이 바뀔 수 있으니 쓸 때 id로 다시 찾는다.
        guard let writeIdx = events.firstIndex(where: { $0.id == id }) else { return }
        events[writeIdx] = event
        events.sort { $0.arrivalDate < $1.arrivalDate }
        save()
    }

    /// 출발 시각 = 도착 − 이동시간 − 버퍼. 이 식이 폼 노트·지난 알림 판정·저장 departureDate에
    /// 걸쳐 손으로 흩어져 있었다 — 화면과 알림이 각자 계산해 어긋나면 "화면과 다른 시각에 알림이
    /// 온다"가 된다. 폼 노트·지난 알림 판정·저장 departureDate가 같은 값을 보게 한곳에 둔다(계약 5).
    /// nonisolated인 이유: 순수 계산이라 호출처가 메인액터 격리에 매이지 않게 한다
    /// (maxBufferMinutes·truncatedToMinute와 같은 선례).
    /// @MX:ANCHOR fan_in ≥ 3 — applyEstimate·applyCachedArrivalEstimate·AddEventView(폼 노트·depGuess)가 같이 부른다
    /// @MX:REASON 계약 5(같은 계산 두 곳 금지) — 저장·화면·알림이 같은 값임을 보장한다
    nonisolated static func departureTime(arrival: Date, travelSeconds: TimeInterval, bufferMinutes: Int) -> Date {
        arrival.addingTimeInterval(-travelSeconds - Double(bufferMinutes) * 60)
    }

    // MARK: - 이동시간 조회 통로(t50 S1 — 드라이버 가시)

    /// 이동시간 **네트워크 조회의 단일 통로**. 드라이버 가시 계수기와 대역 클로저를 여기 둔다
    /// (SPEC-ONTIME-008 AC-005·REQ-013): 대역이 차 있으면 그 값을 쓰고 네트워크를 아예 타지
    /// 않아 단언 픽스처가 결정적으로 돌고(이따금 실패하는 MapKit 조회에 좌우되지 않는다),
    /// 비어 있으면 지금까지와 바이트 단위로 같은 동작이다. 조회 몸통이 applyEstimate·
    /// applyDepartureAnchoredEstimate 두 곳에 복사돼 있던 것도 이 통로로 모아 들였다(계약 5).
    var drvTravelLookupCount = 0
    var drvTravelLookupOverride: ((_ mode: TransportMode, _ origin: Place, _ destination: Place) -> TimeInterval?)?

    /// REQ-005·AC-005의 "저장 1·재예약 1"을 재는 드라이버 가시 계수기. 앱 논리는 읽지 않는다.
    var drvRescheduleCount = 0
    var drvSaveCount = 0
    var drvSaveActivitiesCount = 0
    /// SPEC-SYNC-004 §2.6 — 식사·즐겨찾기 저장 횟수. 앱 논리는 읽지 않는다.
    var drvSaveMealsCount = 0
    var drvSaveFavoritesCount = 0

    /// SPEC-REPLAN-001 — the seam of a live lookup (a replan trigger): the live seconds and the seconds without traffic,
    /// or nil for a failed lookup. It may suspend, so a test can overlap two lookups. The counters tell a test whether a
    /// lookup was live; the app logic does not read them.
    var drvLiveLookupOverride: ((_ mode: TransportMode, _ origin: Place, _ destination: Place) async
        -> (seconds: TimeInterval, noTrafficSeconds: TimeInterval?)?)?
    var drvLiveLookupCount = 0
    var drvNonLiveLookupCount = 0

    /// 조회 결과 (초, 출처). nil은 조회 실패 — 대역에서도 실패 모양을 흉내 낼 수 있게 옵셔널이다.
    /// `live` is true only for the lookups of a replan trigger (SPEC-REPLAN-001): a car lookup then carries traffic and
    /// also returns the seconds without traffic.
    private func lookupTravelSeconds(_ mode: TransportMode, origin: Place, destination: Place, live: Bool = false) async
        -> (seconds: TimeInterval, source: String, noTrafficSeconds: TimeInterval?)? {
        drvTravelLookupCount += 1
        if live { drvLiveLookupCount += 1 } else { drvNonLiveLookupCount += 1 }
        if live, let drvLiveLookupOverride {
            return await drvLiveLookupOverride(mode, origin, destination).map {
                (seconds: $0.seconds, source: "Test driver", noTrafficSeconds: $0.noTrafficSeconds)
            }
        }
        if let drvTravelLookupOverride {
            return drvTravelLookupOverride(mode, origin, destination).map {
                (seconds: $0, source: "Test driver", noTrafficSeconds: nil)
            }
        }
        let estimate = await directions.estimate(
            mode,
            from: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude),
            to: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude),
            live: live)
        guard let seconds = estimate.duration else { return nil }
        return (seconds: seconds, source: estimate.source, noTrafficSeconds: estimate.staticDuration)
    }

    /// 출발지·목적지·수단으로 이동시간을 계산해 출발시각/알림을 세팅한다(기존 알림은 갱신).
    /// @MX:NOTE keepOnFailure is switched on for the refresh lookup only; the other call groups (addEvent,
    /// updateRecurringSeries, updateEvent, the Google import) have no earlier value, or a wrong one, so "keep on failure"
    /// means nothing there (SPEC-ONTIME-005 REQ-003, plan F1). When it is on, the old alarm is
    /// cancelled and cleared only after the lookup succeeded, so an offline re-entry does not erase the travel time and
    /// the alarm (REQ-001).
    @discardableResult
    private func applyEstimate(to event: inout ScheduledEvent, keepOnFailure: Bool = false,
                               live: Bool = false) async -> RefreshAlarmDecision? {
        if !keepOnFailure {
            event.anchor = .arrival
            if let nid = event.notificationId { notifications.cancel(id: nid) }
            event.notificationId = nil
            event.travelSeconds = nil
            event.departureDate = nil
        }
        guard let o = event.origin else { return .normal }   // 출발지 없음 — 사본 무변화, 오늘처럼 되쓴다
        guard let found = await lookupTravelSeconds(event.mode, origin: o, destination: event.destination, live: live) else {
            return .normal   // 조회 실패 — 유지 모드라 사본 무변화, 되쓰기 무해(t68 동작 보존)
        }
        let seconds = found.seconds
        if live { lastLiveAnswers[event.id] = (seconds: seconds, noTrafficSeconds: found.noTrafficSeconds) }
        var decision: RefreshAlarmDecision = .normal
        if keepOnFailure {
            // 판정(REQ-004·001·002): await 사이에 옛 알림이 울렸는지 되쓰기 직전에, id로 다시 읽은
            // 레코드와 새 Date()로 판정한다(D3·N4). 레코드가 없거나(삭제) 출발이 nil이면(다른 경로가
            // 비움) 판정 함수 없이 버린다 — 취소·재예약·되쓰기 없음(감사 N4).
            let id = event.id
            guard let rIdx = events.firstIndex(where: { $0.id == id }),
                  let oldDeparture = events[rIdx].departureDate else { return nil }
            guard Store.estimateInputsUnchanged(event, events[rIdx]) else { return nil }   // 입력이 await 중 바뀜 — 낡은 사본 기준 결과는 버린다
            let newDeparture = Store.departureTime(arrival: event.arrivalDate, travelSeconds: seconds,
                                                   bufferMinutes: event.bufferMinutes)
            decision = Store.refreshAlarmDecision(wants: events[rIdx].wantsNotification,
                                                  oldDeparture: oldDeparture,
                                                  newDeparture: newDeparture,
                                                  leadMinutes: events[rIdx].notifyLeadMinutes,
                                                  now: Date())
            guard decision != .discardFired else { return nil }   // C1 — 취소·재예약·되쓰기 생략(REQ-004)
            // 순서 변경(AC-008): 유지 모드에서만 취소·비움을 조회 뒤로 미룬다 — 실패로 여기까지
            // 오지 않으면 조회 전 레코드가 통째로 남는다(REQ-001).
            event.anchor = .arrival
            if let nid = events[rIdx].notificationId { notifications.cancel(id: nid) }   // 취소 id도 재조회 레코드에서(N4·N10)
            event.notificationId = nil
            event.travelSeconds = nil
            event.departureDate = nil
        }
        event.travelSeconds = seconds
        let departure = Store.departureTime(arrival: event.arrivalDate, travelSeconds: seconds, bufferMinutes: event.bufferMinutes)
        event.departureDate = departure
        event.notificationId = scheduleDepartureNotification(
            for: event, departure: departure, travelSeconds: seconds, source: found.source)
        return decision
    }

    /// 출발 시각을 고정하고(예: 근무 종료 후 복귀) 도착 시각을 순산한다(출발 + 이동시간).
    /// `applyEstimate`(도착 역산)의 반대 방향 버전 — 데이터 모델은 동일(arrivalDate/departureDate 둘 다 채움).
    /// keepOnFailure의 쓰임은 applyEstimate 머리말과 같다(refresh 재조회 전용, REQ-001·REQ-003).
    @discardableResult
    private func applyDepartureAnchoredEstimate(to event: inout ScheduledEvent, departureDate: Date, keepOnFailure: Bool = false) async -> RefreshAlarmDecision? {
        if !keepOnFailure {
            event.anchor = .departure
            if let nid = event.notificationId { notifications.cancel(id: nid) }
            event.notificationId = nil
            event.travelSeconds = nil
            event.departureDate = departureDate
        }
        guard let o = event.origin else { return .normal }   // 출발지 없음 — 사본 무변화, 오늘처럼 되쓴다
        guard let found = await lookupTravelSeconds(event.mode, origin: o, destination: event.destination) else {
            return .normal   // 조회 실패 — 유지 모드라 사본 무변화, 되쓰기 무해(t68 동작 보존)
        }
        let seconds = found.seconds
        var decision: RefreshAlarmDecision = .normal
        if keepOnFailure {
            // 판정(REQ-004): 도착 기준과 같은 규칙으로 판정한다. 출발 기준은 재조회가 출발을
            // 옮기지 않는다(newDeparture가 곧 고정 departureDate) — 그래서 catchUp·late는 나올
            // 수 없고 none·discardFired·normal뿐이다(감사 D12). 판정 규칙을 하나로 두느라 그대로
            // 지나며, 버림이면 이동시간·도착 갱신까지 버린다(의도, spec §1.3 예외 3·감사 N15).
            let id = event.id
            guard let rIdx = events.firstIndex(where: { $0.id == id }),
                  let oldDeparture = events[rIdx].departureDate else { return nil }
            guard Store.estimateInputsUnchanged(event, events[rIdx]) else { return nil }   // 입력이 await 중 바뀜 — 낡은 사본 기준 결과는 버린다
            decision = Store.refreshAlarmDecision(wants: events[rIdx].wantsNotification,
                                                  oldDeparture: oldDeparture,
                                                  newDeparture: departureDate,
                                                  leadMinutes: events[rIdx].notifyLeadMinutes,
                                                  now: Date())
            guard decision != .discardFired else { return nil }   // 버림 — 취소·재예약·되쓰기 생략(REQ-004)
            // 순서 변경(AC-008): 조회 성공 뒤에만 취소·비움 — 실패하면 출발 시각이 그대로 남아
            // 다음 재진입에서 재시도된다(REQ-001·REQ-005).
            event.anchor = .departure
            if let nid = events[rIdx].notificationId { notifications.cancel(id: nid) }   // 취소 id도 재조회 레코드에서(N4·N10)
            event.notificationId = nil
            event.travelSeconds = nil
            event.departureDate = departureDate
        }
        event.travelSeconds = seconds
        // @MX:NOTE: 역방향 식(출발 + 이동 + 버퍼) — 접으려면 저장된 버퍼 의미 정리가 먼저다(후속 카드 t67).
        event.arrivalDate = departureDate.addingTimeInterval(seconds + Double(event.bufferMinutes) * 60)
        event.notificationId = scheduleDepartureNotification(
            for: event, departure: departureDate, travelSeconds: seconds, source: found.source)
        return decision
    }

    /// 출발 알림을 예약하고 id를 돌려준다(꺼져 있거나 과거면 nil).
    /// 예전엔 이 6줄이 추정 함수 4곳에 그대로 복사돼 있어, 알림 끄기 같은 변경을 넣으려면
    /// 네 군데를 똑같이 고쳐야 했다 — 한 곳으로 모았다.
    private func scheduleDepartureNotification(for event: ScheduledEvent,
                                               departure: Date,
                                               travelSeconds: TimeInterval,
                                               source: String) -> String? {
        guard event.wantsNotification else { return nil }
        let estimate = TravelEstimate(mode: event.mode, duration: travelSeconds, distance: nil, source: source)
        return notifications.schedule(
            title: "🚶 \(event.title) — time to get ready",
            body: notificationBody(for: event, estimate: estimate),
            at: NotificationManager.alarmTime(departure: departure, leadMinutes: event.notifyLeadMinutes),
            eventID: event.id)
    }

    func notificationBody(for event: ScheduledEvent, estimate: TravelEstimate) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        let dep = event.departureDate.map { f.string(from: $0) } ?? "-"
        return "\(event.mode.title) to \(event.destination.name): \(estimate.durationText). Leave at \(dep)."
    }

    // MARK: - 드래그로 시간 재조정(일간 시간표)

    /// 활동 블록의 시작·종료를 그대로 분 단위로 옮긴다(이동시간 재계산 없음, 순수 이동).
    /// 반복 그룹 전체를 옮기면(wholeSeries) 매 회차 + 그 회차에 연계된 이동 구간까지 같이 옮긴다.
    func moveActivity(_ activity: ActivityBlock, byMinutes minutes: Int, wholeSeries: Bool) {
        guard minutes != 0 else { return }
        let targets: [ActivityBlock]
        if wholeSeries, let rid = activity.recurrenceId {
            if let index = series.firstIndex(where: { $0.id == rid }) {
                moveComputedSeries(at: index, byMinutes: minutes)
                return
            }
            targets = activities.filter { $0.recurrenceId == rid }
        } else {
            // A computed occurrence becomes a stored copy before it is shifted (REQ-014).
            _ = resolveStored(activity.id)
            targets = [activity]
        }
        // 활동에 명시적으로 연결된 이동 구간만 같이 옮긴다(REQ-012) — 연결 없는 옛 반복 이동은 제자리다.
        for a in targets {
            let (arrivalLeg, departureLeg) = legs(of: a.id)
            if let arrivalLeg { shiftEvent(arrivalLeg.id, byMinutes: minutes) }
            if let departureLeg { shiftEvent(departureLeg.id, byMinutes: minutes) }
        }
        for t in targets {
            guard let idx = activities.firstIndex(where: { $0.id == t.id }) else { continue }
            activities[idx].startDate = activities[idx].startDate.addingTimeInterval(Double(minutes) * 60)
            activities[idx].endDate = activities[idx].endDate.addingTimeInterval(Double(minutes) * 60)
        }
        // "이 일정만" 이동(Δ≠0만 여기까지 온다)은 그 회차를 반복에서 뗀다(REQ-014). "전체"는
        // 빠짐 없음 — 아래 저장 한 벌이 이동과 빠짐을 함께 쓴다.
        if !wholeSeries { _ = clearSeriesMembership(activityId: activity.id) }
        saveActivities()
        save()   // shiftEvent는 저장하지 않는다(아래 주석) — 옮긴 이동 구간을 여기서 한 번에 저장.
    }

    /// The whole-series move of a computed series changes the time of day of the rule (L9): the delta is clamped so the
    /// start stays on its day, the end keeps its length, and the existing legs of the unstored occurrences shift by the
    /// same delta. Nothing is refilled and the leg mark is not touched, so a leg the user deleted stays deleted. Every
    /// occurrence of the rule, past ones included, is drawn at the new time (L15).
    private func moveComputedSeries(at index: Int, byMinutes minutes: Int) {
        var updated = series[index]
        let newStart = min(max(updated.startMinute + minutes, 0), 1439)
        let delta = newStart - updated.startMinute
        guard delta != 0,
              let end = Self.seriesEnd(startMinute: newStart,
                                       absoluteEnd: updated.endMinute + updated.endDayDistance * 1440 + delta) else { return }
        let legIDs = unstoredOccurrenceLegs(of: updated.id).map { $0.id }
        updated.startMinute = newStart
        updated.endMinute = end.endMinute
        updated.endDayDistance = end.endDayDistance
        series[index] = updated
        saveSeries()
        for id in legIDs { shiftEvent(id, byMinutes: delta) }
        save()   // `shiftEvent` does not save
    }

    /// The end minute and the end-day distance of a series for a start minute and an end counted in minutes from the
    /// midnight of the start day, by the 24-hour rule of `RecurrenceRule.occurrenceEndDayDistance`; nil when the length
    /// breaks the rule.
    private static func seriesEnd(startMinute: Int, absoluteEnd: Int) -> (endMinute: Int, endDayDistance: Int)? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? utc.timeZone
        let midnight = Date(timeIntervalSince1970: 0)
        guard let distance = RecurrenceRule.occurrenceEndDayDistance(
            start: midnight.addingTimeInterval(Double(startMinute) * 60),
            end: midnight.addingTimeInterval(Double(absoluteEnd) * 60), calendar: utc) else { return nil }
        return (absoluteEnd % 1440, distance)
    }

    /// 이동 구간(ScheduledEvent) 블록을 드래그해 놓았을 때의 확정. 소유 활동이 있으면 활동
    /// 가장자리를 함께 옮긴다(REQ-001·002 — 오는 편 Δ는 활동 끝, 가는 편 Δ는 활동 시작.
    /// 18번 메모 "오는 이동을 아래로 30분 끌면 활동 블록도 30분 추가"). 소유 활동이 없어도
    /// 통째로 옮긴다(REQ-005, 0.8.2 — 도착 기준이 버퍼를 흡수하던 옛 동작 대신 구간만 평행이동,
    /// 여유·이동시간 그대로, ⚠ 블록도 나열 시각이 함께 움직인다). 반복 그룹 전체(wholeSeries)면
    /// 소유 갈래는 "같은 반복 번호" 회차 전부(REQ-010·J-24 — 제목·장소 비교 없이 번호만 본다,
    /// siblingOccurrences. 옛 한 번호 데이터에서 같은 날 점심까지 함께 옮겨지는 결과는 spec
    /// §4.1이 받아들였다), 소유 없는 갈래는 "같은 역할"(같은
    /// anchor + 같은 목적지/출발지) 가운데 연결 없는 회차만(운영자 D1 — 형태가 같은 회차만 옮긴다).
    /// "이 일정만"(단일 확정, 실제 Δ≠0)은 REQ-014의 빠짐으로 이어진다.
    /// pressedOn(눌렀던 날)이 있으면 끌린 구간은 가장자리 바깥 함수 dragEdgeOutcome으로 유효 Δ를
    /// 정한다(REQ-015 (1) — 미리보기가 저장해 둔 유효 Δ를 현재 저장값에 다시 적용, 같은 함수라
    /// 놓은 결과가 끄는 중 표시와 어긋나지 않는다). 없으면 지금까지처럼 상태 없는 한계 함수만
    /// 쓴다(드라이버 기존 호출·뷰의 옛 경로). "전체"의 다른 회차는 언제나 한계 함수만 받는다
    /// (REQ-010 끝 문장 — 회차마다 이동시간이 달라 가장자리 상태를 공유할 수 없다).
    func adjustTravelLeg(_ event: ScheduledEvent, byMinutes minutes: Int, wholeSeries: Bool,
                         pressedOn: Date? = nil) {
        guard minutes != 0 else { return }
        // 드래그가 시작된 뒤 저장소가 바뀌었을 수 있으니 id로 현재 값을 다시 읽어 판정한다(REQ-008
        // 드롭 재읽기) — 드래그 시작 때 잡아둔 사본의 시각으로 한계를 정하면 옛 값이 확정에 섞인다.
        // id가 이미 없으면 소유 여부와 무관하게 아무것도 바꾸지 않는다.
        guard let current = events.first(where: { $0.id == event.id }) else { return }
        if let owner = owningActivity(of: current) {
            applyLinkedLegDrag(current, owner: owner, requestedMinutes: minutes,
                               wholeSeries: wholeSeries, pressedOn: pressedOn)
            return
        }
        let anchorKind = current.anchor ?? .arrival
        let roleKey = anchorKind == .arrival ? current.destination.name : (current.origin?.name ?? "")
        var draggedSoloMoved = false
        let targets: [ScheduledEvent]
        if wholeSeries, let rid = current.recurrenceId {
            // 후보(같은 반복·같은 기준·같은 역할 장소)를 먼저 모은 뒤, 어느 구간도 옮기기 전에
            // 소유를 한 번에 푼다. 소유 있는 회차를 빼는 것(운영자 D1)은 "전체"가 형태가 같은,
            // 연결 없는 회차만 옮긴다는 뜻이다 — 활동에 붙은 회차를 같이 밀면 활동은 그대로인데
            // 구간만 떨어진다.
            let candidates = events.filter {
                $0.recurrenceId == rid && ($0.anchor ?? .arrival) == anchorKind
                    && (anchorKind == .arrival ? $0.destination.name : ($0.origin?.name ?? "")) == roleKey
            }
            targets = candidates.filter { owningActivity(of: $0) == nil }
        } else {
            targets = [current]
        }
        for t in targets {
            // 각 회차는 자기 한계(같은 날짜 창)로 자른 유효 Δ로 통째 이동한다(REQ-005 — REQ-010과
            // 같은 방식) — 끌린 회차의 한계를 다른 회차에 덮어쓰지 않는다. 출발 기준·도착 기준
            // 구분 없이 shiftEvent 하나: 여유·이동시간은 그대로이고 알림도 함께 옮는다.
            // 눌렀던 날이 있어도 끌린 회차만 바깥 함수를 지난다 — 가장자리 상태는 끌린 구간의
            // 것이지 회차마다 있는 것이 아니다(REQ-010 끝 문장).
            guard let now = events.first(where: { $0.id == t.id }) else { continue }
            let delta: Int
            if let pressedOn, t.id == event.id {
                delta = dragEdgeOutcome(leg: now, owner: nil, requestedMinutes: minutes,
                                        pressedOn: pressedOn).deltaMinutes
            } else {
                delta = effectiveDragMinutes(leg: now, owner: nil, requestedMinutes: minutes)
            }
            if delta != 0 {
                shiftEvent(t.id, byMinutes: delta)
                // "이 일정만"은 실제로 움직였을 때만 빠진다(REQ-014) — 유효 Δ가 0으로 잘린
                // 드롭(눈금 최소 길이·나열 창)은 무변경 저장과 같다. 소유 없는 구간이라 구간 하나만.
                if !wholeSeries && t.id == event.id { draggedSoloMoved = true }
            }
        }
        if !wholeSeries && draggedSoloMoved {
            _ = clearSeriesMembership(legId: event.id)   // J-10 — 구간 하나만 뗀다
        }
        if wholeSeries {
            // "전체"는 회차 수와 무관하게 재예약·저장 한 번으로 끝낸다 — rescheduleNearestNotifications가
            // save()까지 한다(64건 상한 재계산도 여기 다시 걸린다, 소유 있는 "전체"와 같은 규율).
            rescheduleNearestNotifications()
        } else {
            save()   // "이 일정만"은 지금처럼 저장 한 번.
        }
    }

    /// 형제 회차 조회의 단일 출처(P-12, REQ-016·J-24): 같은 반복 번호의 활동 전부를 **번호만으로**
    /// 고른다(제목·장소 비교 없음). "전체" 끌기(applyLinkedLegDrag)와 "반복 전체" 이동 추가
    /// (addLegToSeries)가 같이 부른다 — 둘이 판정을 나눠 가지면 옛 한 번호 데이터에서 범위가
    /// 어긋난다. 이 함수는 형제를 고를 뿐 구간-활동 짝을 제목·장소로 짓지 않으므로 REQ-001·012와
    /// 충돌하지 않는다. 빠진 회차는 번호가 비워져 있어 자연히 빠진다(§4.2).
    func siblingOccurrences(of activity: ActivityBlock) -> [ActivityBlock] {
        guard let rid = activity.recurrenceId else { return [] }
        if let owner = series.first(where: { $0.id == rid }) {
            return computedSiblings(of: activity, in: owner)
        }
        return activities.filter { $0.recurrenceId == rid }
    }

    /// The siblings of a computed occurrence: the occurrences of its series from today through `legWindowDays` that are
    /// not skipped and not stored, plus the occurrence being edited itself when it starts after `replanNow()`, so the leg
    /// the user asked for on the screen in front of them is made even when that occurrence lies months ahead.
    private func computedSiblings(of activity: ActivityBlock, in owner: RepeatSeries) -> [ActivityBlock] {
        let calendar = Calendar.current
        let now = replanNow()
        guard let end = calendar.date(byAdding: .day, value: Self.legWindowDays + 1, to: calendar.startOfDay(for: now))
        else { return [] }
        let stored = Set(activities.map { $0.id })
        var siblings = owner.occurrences(in: DateInterval(start: calendar.startOfDay(for: now), end: end), calendar: calendar)
            .filter { !stored.contains($0.id) }
        if activity.startDate > now, !siblings.contains(where: { $0.id == activity.id }),
           let edited = self.activity(id: activity.id), edited.recurrenceId == owner.id {
            siblings.append(edited)
        }
        return Self.sortedByStart(siblings)
    }

    /// 소유 활동이 있는 구간 드래그의 확정(REQ-001·002·010·011). 유효 Δ는 effectiveDragMinutes
    /// 한 곳에서 정하고(계약 5), 구간의 평행이동 산식은 shiftEvent가 유일하다 — 여기서 시각
    /// 산수를 다시 쓰지 않는다. 동기 경로다: 구글 반영도 Task도 없다(REQ-012, 카드 t48).
    /// pressedOn이 있으면 끌린 회차만 dragEdgeOutcome을 지난다(adjustTravelLeg 머리말 참조).
    private func applyLinkedLegDrag(_ leg: ScheduledEvent, owner: ActivityBlock,
                                    requestedMinutes: Int, wholeSeries: Bool,
                                    pressedOn: Date? = nil) {
        let isReturnLeg = leg.anchor == .departure
        if wholeSeries, let rid = owner.recurrenceId, let index = series.firstIndex(where: { $0.id == rid }) {
            dragComputedSeries(at: index, leg: leg, owner: owner, requestedMinutes: requestedMinutes, pressedOn: pressedOn)
            return
        }
        if wholeSeries, owner.recurrenceId != nil {
            // @MX:WARN 모든 회차의 (활동, 구간, Δ)를 먼저 모은 뒤 한 번씩 옮긴다 — 조회(legs(of:))와
            // 이동(shiftEvent)을 회차마다 교차하는 버릇은 시각으로 짝을 짓던 때 방금 밀린 구간을 다음
            // 회차의 조회가 다시 집어 두 번 옮기게 했다(N5-1 · AF-018-27). 짝이 id 연결로 바뀐 뒤에는
            // 일어나지 않지만 순서는 그대로 둔다 — 틀을 지키는 쪽이 값싸다.
            var moves: [(activityId: UUID, legId: UUID, delta: Int)] = []
            // 형제 판정은 번호만 본다(J-24·P-12 — 제목·장소 비교는 걷어냈다). 표지는 끌린 구간이
            // 아니라 소유 활동의 번호다: 연결이 살아 있으면 그 회차가 속한 시리즈가 "전체"의 범위다.
            let peers = siblingOccurrences(of: owner)
            for occurrence in peers {
                let (outbound, returnLeg) = legs(of: occurrence.id)
                // 그 회차에 같은 역할 구간이 없으면 건너뛴다(REQ-010) — 활동을 편집하지 않는다.
                guard let sameRole = isReturnLeg ? returnLeg : outbound else { continue }
                // 각 회차의 Δ는 그 회차 자신의 한계(활동 길이·나열 범위)로 잘린다 — 드래그한
                // 회차의 한계를 다른 회차에 덮어쓰지 않는다(AF-018-16: 눈금 접힘 −10·−10·0). 끌린 회차만
                // 눌렀던 날이 있으면 바깥 함수로 대신한다(가장자리 상태는 회차마다 있지 않다).
                let delta: Int
                if let pressedOn, sameRole.id == leg.id {
                    delta = dragEdgeOutcome(leg: sameRole, owner: occurrence,
                                            requestedMinutes: requestedMinutes,
                                            pressedOn: pressedOn).deltaMinutes
                } else {
                    delta = effectiveDragMinutes(leg: sameRole, owner: occurrence,
                                                 requestedMinutes: requestedMinutes)
                }
                if delta != 0 { moves.append((occurrence.id, sameRole.id, delta)) }
            }
            guard !moves.isEmpty else { return }
            var startMoved = false
            for move in moves {
                guard let idx = activities.firstIndex(where: { $0.id == move.activityId }) else { continue }
                if isReturnLeg {
                    activities[idx].endDate = activities[idx].endDate.addingTimeInterval(Double(move.delta) * 60)
                } else {
                    activities[idx].startDate = activities[idx].startDate.addingTimeInterval(Double(move.delta) * 60)
                    startMoved = true
                }
                shiftEvent(move.legId, byMinutes: move.delta)
            }
            if startMoved { activities.sort { $0.startDate < $1.startDate } }
            saveActivities()
            // 회차 수와 무관하게 이벤트 저장·알림 재예약은 이 한 번으로 끝난다 — 이 함수가 save()까지
            // 한다(rescheduleNearestNotifications의 64건 상한 재계산도 여기서 다시 걸린다).
            rescheduleNearestNotifications()
            return
        }
        // 단일 확정(REQ-011): 드래그 시작 때가 아니라 지금 저장된 값으로 유효 Δ를 정한다.
        // 눌렀던 날이 있으면 가장자리 바깥 함수가 한계 함수를 감싸 부른다(붙음 Δ 접기 포함).
        let delta: Int
        if let pressedOn {
            delta = dragEdgeOutcome(leg: leg, owner: owner, requestedMinutes: requestedMinutes,
                                    pressedOn: pressedOn).deltaMinutes
        } else {
            delta = effectiveDragMinutes(leg: leg, owner: owner, requestedMinutes: requestedMinutes)
        }
        // A computed owner becomes a stored copy once the drag really moves something (REQ-014).
        guard delta != 0, resolveStored(owner.id) != nil,
              let idx = activities.firstIndex(where: { $0.id == owner.id }) else { return }
        if isReturnLeg {
            activities[idx].endDate = activities[idx].endDate.addingTimeInterval(Double(delta) * 60)
        } else {
            activities[idx].startDate = activities[idx].startDate.addingTimeInterval(Double(delta) * 60)
            activities.sort { $0.startDate < $1.startDate }
        }
        shiftEvent(leg.id, byMinutes: delta)
        // "이 일정만" 확정(Δ≠0만 여기 온다)의 빠짐(REQ-014) — 소유는 명시 연결뿐이라 그 회차 전체
        // (활동과 연결 구간 전부)가 빠진다. 연결 없는 구간 하나만 빠지는 갈래(J-10)는 소유 없는
        // 단독 드래그(adjustTravelLeg)에 있다.
        _ = clearSeriesMembership(activityId: owner.id)
        saveActivities()
        save()   // shiftEvent는 저장하지 않는다 — 여기서 한 번(저장 규율은 moveActivity와 같다).
    }

    /// The whole-series leg drag of a computed series: one delta, taken from the dragged occurrence only, changes the rule's
    /// `endMinute` (a return leg) or `startMinute` (an outbound leg), clamped so the start stays in 0..<1440 and the
    /// length stays above zero and within 24 hours. The existing legs of the same role of the unstored occurrences shift
    /// by it and the alarms are rescheduled once. The occurrences of one rule share their clock times, so the limits of the
    /// dragged one are the limits of all.
    private func dragComputedSeries(at index: Int, leg: ScheduledEvent, owner: ActivityBlock,
                                    requestedMinutes: Int, pressedOn: Date?) {
        let isReturnLeg = leg.anchor == .departure
        let requested: Int
        if let pressedOn {
            requested = dragEdgeOutcome(leg: leg, owner: owner, requestedMinutes: requestedMinutes,
                                        pressedOn: pressedOn).deltaMinutes
        } else {
            requested = effectiveDragMinutes(leg: leg, owner: owner, requestedMinutes: requestedMinutes)
        }
        guard requested != 0 else { return }
        var updated = series[index]
        let absoluteEnd = updated.endMinute + updated.endDayDistance * 1440
        var newStart = updated.startMinute
        var newEnd = absoluteEnd
        if isReturnLeg {
            newEnd = min(max(absoluteEnd + requested, newStart + 1), newStart + 1440)
        } else {
            newStart = min(max(newStart + requested, max(0, absoluteEnd - 1440)), min(1439, absoluteEnd - 1))
        }
        let delta = isReturnLeg ? newEnd - absoluteEnd : newStart - updated.startMinute
        guard delta != 0, let end = Self.seriesEnd(startMinute: newStart, absoluteEnd: newEnd) else { return }
        updated.startMinute = newStart
        updated.endMinute = end.endMinute
        updated.endDayDistance = end.endDayDistance
        let role: ScheduleAnchor = isReturnLeg ? .departure : .arrival
        let legIDs = unstoredOccurrenceLegs(of: updated.id).filter { ($0.anchor ?? .arrival) == role }.map { $0.id }
        series[index] = updated
        saveSeries()
        for id in legIDs { shiftEvent(id, byMinutes: delta) }
        rescheduleNearestNotifications()   // saves the legs, once for the whole series
    }

    /// 드래그로 만들 수 있는 가장 짧은 활동(REQ-006·010, t82 F-1 — 눈금 위에서 10분). 반대쪽
    /// 끝이 눈금 밖이면 끈 쪽 끝은 그 끝에서 10분 이상 떨어진 첫 눈금까지만 줄어든다(12:45 시작
    /// → 끝은 13:00 — 12:50·12:55에 닿지 않는다). 폼이 1분 단위라 그보다 짧은 활동은 존재하고,
    /// 드래그가 그 아래로 줄이지 않는다. ContentView의 그리기 바닥(5분 최소 높이)과 값이 달라져도
    /// 그쪽은 그리기 전용 상수라 여기 묶지 않는다(하나로 묶으면 화면 상수가 Store 격리를
    /// 끌어당긴다).
    nonisolated static let minDraggedActivityMinutes = 10

    /// 드래그 눈금 간격(REQ-008·013, t82 — 10분). 빈칸 생성(emptyPressStartDate)·활동 끌기
    /// (gridSnappedDelta)·붙음 접기(dragEdgeOutcome)가 같은 상수를 읽는다 — 두 곳에 두면
    /// 한쪽만 바뀐 채 드래그 중 미리보기와 놓기 결과가 어긋난다.
    nonisolated static let dragSnapStepMinutes = 10

    /// reference에서 requestedMinutes만큼 더한 도착 시각을 가장 가까운 눈금(:00·:10·:20…,
    /// 분이 dragSnapStepMinutes의 배수·초 0)으로 반올림하고 그 도착에서 reference를 뺀 Δ(분)을
    /// 돌려준다(REQ-013). 같은 거리면 올린다 — 23:55는 23:50이 아니라 다음 날 00:00이 된다
    /// (O-A6). 반올림이 요청을 넘을 수 있다(끝 01:38:20 요청 +15 → 눈금 01:40:00), 그때 Δ의
    /// 남는 초(16분 40초)는 정수 분으로 접는다. 눈금 판정의 단일 출처다 — 빈칸 생성·끌기·접기가
    /// 도우미를 따로 두면 규칙이 갈라진다(계약 5).
    nonisolated static func gridSnappedDelta(from reference: Date, requestedMinutes: Int,
                                              calendar: Calendar = .current) -> Int {
        let step = dragSnapStepMinutes
        let target = reference.addingTimeInterval(Double(requestedMinutes) * 60)
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: target)
        let minute = comps.minute ?? 0
        comps.minute = minute - minute % step
        comps.second = 0
        guard let lower = calendar.date(from: comps) else { return requestedMinutes }
        let upper = lower.addingTimeInterval(Double(step) * 60)
        // 가까운 쪽(같은 거리면 늦은 쪽)의 눈금에서 reference까지의 Δ를 정수 분으로 접는다.
        let snapped = upper.timeIntervalSince(target) <= target.timeIntervalSince(lower) ? upper : lower
        return Int(snapped.timeIntervalSince(reference) / 60)
    }

    /// 빈칸 꾹 누르기의 y→시각 변환(REQ-009·013). minutesFromMidnight는 뷰가 y/높이×60으로
    /// 낸 실수이고, 가까운 눈금으로의 반올림은 gridSnappedDelta가 한다 — 생성의 10분 끊기와
    /// 끌기의 눈금이 같은 판정을 탄다(계약 5). 자정을 넘는 반올림(23:55 → 1440분)은 다음 날
    /// 00:00이 된다(O-A6).
    nonisolated static func emptyPressStartDate(day: Date, minutesFromMidnight: Double,
                                                calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        let requested = Int(minutesFromMidnight.rounded())
        let delta = gridSnappedDelta(from: start, requestedMinutes: requested, calendar: calendar)
        return start.addingTimeInterval(Double(delta) * 60)
    }

    /// Answer for the drag of an occurrence of a repeating activity (card t83): ask this event or the series, or cancel.
    enum SeriesDragOutcome: Equatable { case askThisOrSeries, cancel }
    /// Cancel when the offset (elapsed minutes, like the preview target) puts the activity's own start on another
    /// calendar day of `calendar`. Reads the start date only: never the end, the place or a travel leg.
    nonisolated static func seriesDragOutcome(for activity: ActivityBlock, deltaMinutes: Int,
                                              calendar: Calendar = .current) -> SeriesDragOutcome {
        let landed = activity.startDate.addingTimeInterval(Double(deltaMinutes) * 60)
        return calendar.startOfDay(for: landed) == calendar.startOfDay(for: activity.startDate) ? .askThisOrSeries : .cancel
    }
    /// Answer for the drag of a travel leg (card t92): cancel only when the leg is an outbound leg whose owner is an
    /// occurrence of a repeating activity and the offset puts that owner's own start on another calendar day, decided by
    /// the day function above. Every other case is not cancelled: the existing code runs unchanged.
    nonisolated static func legDragOutcome(leg: ScheduledEvent, owner: ActivityBlock?, deltaMinutes: Int,
                                           calendar: Calendar = .current) -> SeriesDragOutcome {
        guard let owner, owner.recurrenceId != nil, leg.anchor != .departure else { return .askThisOrSeries }
        return seriesDragOutcome(for: owner, deltaMinutes: deltaMinutes, calendar: calendar)
    }

    /// 가장자리 넘김 문턱이자 붙는 구간의 최소 폭(분, REQ-015 (1) — D-14 (가), 운영자 Q-24
    /// "30분"). 앞쪽 끝이 가장자리를 넘은 뒤 이만큼 더 끌어야 다음 날로 넘어간다. 드래그 상수
    /// 곁에 두지만 그리기가 아니라 Store 판정만 읽는다(화면 상수가 Store 격리를 끌어당기는 일,
    /// minDraggedActivityMinutes 머리말과 같은 이유).
    nonisolated static let minEdgeHoldMinutes = 30

    /// 소유 활동이 있는 구간 드래그의 유효 Δ(REQ-006~008·010, t82 — 눈금 의미로 재작성).
    /// 저장된 일정을 다시 찾아보지 않고 받은 두 레코드의 시각만으로 정하는 순수 함수다(재읽기
    /// 책임은 adjustTravelLeg에 있다). ① 한계는 시각 경계로만 적용해 끈 쪽 끝의 허용 구간을 정하고,
    /// ② reference + 요청을 gridSnappedDelta의 눈금으로 반올림하며, ③ 반올림한 도착이 구간을
    /// 벗어나면 구간 안의 눈금 가운데 목표에 가장 가까운 것으로 안으로 접는다(구간에 눈금이 없는
    /// 퇴화 경우엔 경계값). 반올림이 요청을 넘을 수 있어 "유효 Δ는 0과 요청 사이"이던 옛 규칙은
    /// 폈다 — 한계의 방향은 여전히 요청 방향뿐이다(양방향 자르기는 옛 데이터에서 +15 요청이
    /// −60이 되는 뜻하지 않은 반대 이동을 만들었다, progress §E.1). 최소 길이 한계는 눈금 공간에서
    /// 잰다: 끈 쪽 끝이 반대쪽 끝에서 minDraggedActivityMinutes 이상 떨어진 첫 눈금보다 더
    /// 줄지 않는다(12:45 시작 → 끝 13:00). owner가 nil이면 소유 없는 구간 드래그(REQ-005) —
    /// 활동이 없으니 최소 길이 한계는 걸리지 않고, 날짜 창(위쪽 F 전날 시작 … 아래쪽 F 다음 날
    /// 끝)만 적용된다.
    /// reference(끈 쪽 끝)은 소유 활동이 있으면 끌리는 활동 가장자리(오는 편=끝, 가는 편=시작),
    /// 없으면 블록 위끝(span?.start ?? 앵커/도착 — r3 탐침 변형과 같은 기준).
    /// @MX:NOTE 끄는 중 미리보기와 드롭이 같은 한계를 읽게 단일 출처로 둔다(계약 5)
    func effectiveDragMinutes(leg: ScheduledEvent, owner: ActivityBlock?, requestedMinutes: Int) -> Int {
        guard requestedMinutes != 0 else { return 0 }
        // 초 단위 시각은 경계 계산에서 먼저 0쪽으로 분 잘라 쓴다(REQ-008) — 이동시간 조회가 남긴
        // 초가 0시·자정 경계 판정을 흔들지 않게.
        var t = leg
        t.arrivalDate = Self.truncatedToMinute(t.arrivalDate)
        t.departureDate = t.departureDate.map(Self.truncatedToMinute)
        let isReturnLeg = leg.anchor == .departure
        let calendar = Calendar.current

        // REQ-007의 첫 나열일 F. 나열 판정은 isListed(반열린 겹침)의 규칙을 그대로 따른다 —
        // 여기서 다른 규칙을 쓰면 화면 나열과 드래그 한계가 어긋난다(계약 5). 실패 블록(REQ-016)도
        // listedSpan 구간이 들어가고, 깨진 레코드만 나열 시각(도착) 하나로 한계에 들어간다(N4-1).
        let span = t.listedSpan
        let listingTime = t.arrivalDate
        let firstListed = calendar.startOfDay(for: span?.start ?? listingTime)

        let reference: Date
        if let owner {
            reference = isReturnLeg ? owner.endDate : owner.startDate
        } else {
            reference = span?.start ?? listingTime
        }

        // 눈금 Δ 격자와 접기 도구 — 격자 판정은 gridSnappedDelta만 한다(REQ-013 단일 출처).
        // reference에서 가장 가까운 눈금까지의 변위(base)에서 step 간격의 눈금 Δ를 만든다.
        let stepMin = Self.dragSnapStepMinutes
        let base = Self.gridSnappedDelta(from: reference, requestedMinutes: 0, calendar: calendar)
        // bound를 넘지 않는 가장 큰 눈금 Δ / bound부터 올라가는 가장 작은 눈금 Δ.
        func gridFloor(_ bound: Int) -> Int {
            var d = base + (bound - base) / stepMin * stepMin
            if d > bound { d -= stepMin }
            return d
        }
        func gridCeil(_ bound: Int) -> Int {
            var d = base + (bound - base) / stepMin * stepMin
            if d < bound { d += stepMin }
            return d
        }

        if requestedMinutes < 0 {
            // 위로(Δ<0): 줄이는 방향의 한계만 적용한다. 시작값은 요청이 아니라 무한 — 반올림이
            // 요청을 넘을 수 있어서다(아래 날짜 창이 늘 한계로 걸린다).
            var low = -(1 << 30)
            if isReturnLeg, let owner {
                // 오는 편을 위로 끌면 활동 끝이 줄어든다 — 결과 길이가 눈금 위에서 최소 밑으로 내려가면
                // 안 된다(REQ-006). 허용 아래 끝은 시작+최소를 넘는 첫 눈금이다(12:45 시작 → 13:00).
                // 이미 최소 미만인 활동은 min(0, …)이 0이 되어 어떤 줄임도 거절한다.
                let floorTime = owner.startDate.addingTimeInterval(Double(Self.minDraggedActivityMinutes) * 60)
                var shift = Self.gridSnappedDelta(from: floorTime, requestedMinutes: 0, calendar: calendar)
                if shift < 0 { shift += stepMin }   // 가까운 눈금이 경계 앞이면 한 눈금 안으로
                low = max(low, min(0, shift + Int(floorTime.timeIntervalSince(reference) / 60)))
            }
            // 위쪽 하한은 아래 상한(새 도착 ≤ F 다음 날 끝)의 거울이다(D-4 0.8.0 안 B, Q-16):
            // 새 출발 ≥ F 전날 시작(비엄격 — 그 0시에 정확히 닿아도 된다). 옛 두 줄(새 출발 ≥
            // F 시작 · 새 도착 > L 시작)은 아래로 끌어 다음 날로 통째 넘어간 구간을 전날로 되돌리지
            // 못했다(S-6). 하한은 늘 지금 출발보다 앞이므로(F 시작 ≤ 출발) 이 값이 양수로 뒤집히는
            // 일은 없다.
            if let firstPrevDay = calendar.date(byAdding: .day, value: -1, to: firstListed) {
                low = max(low, Int(firstPrevDay.timeIntervalSince(span?.start ?? listingTime) / 60))
            }
            // 눈금 반올림한 도착이 구간 안이면 그 값을, 밖이면 구간 안의 가장 가까운 눈금으로 접는다.
            let target = Self.gridSnappedDelta(from: reference, requestedMinutes: requestedMinutes, calendar: calendar)
            // 반올림이 요청과 반대 부호가 되는 눈금(기준 시각이 눈금 밖인 1~4분 요청)은 "범위
            // 밖"이 아니라 제자리다 — 접으면 날짜 창 끝(전날 00:00)까지 튄다(수리 1 S-1: 12:47
            // 출발 −1 요청이 눈금 12:50의 +3으로 반올림되는 모양).
            if target > 0 { return 0 }
            if target >= low { return target }
            return min(0, gridCeil(low))
        }

        // 아래로(Δ>0): 늘리는 방향의 한계만 적용한다. 시작값은 무한(위 갈래와 같은 이유).
        var high = 1 << 30
        if !isReturnLeg, let owner {
            // 가는 편을 아래로 끌면 활동 시작이 줄어든다(끝은 고정) — 오는 편과 대칭 산식.
            // 허용 위 끝은 끝−최소를 넘지 않는 마지막 눈금이다.
            let ceilTime = owner.endDate.addingTimeInterval(Double(-Self.minDraggedActivityMinutes) * 60)
            var shift = Self.gridSnappedDelta(from: ceilTime, requestedMinutes: 0, calendar: calendar)
            if shift > 0 { shift -= stepMin }      // 가까운 눈금이 경계를 넘으면 한 눈금 안으로
            high = min(high, max(0, shift + Int(ceilTime.timeIntervalSince(reference) / 60)))
        }
        // 새 (나열) 시각이 끌기 전 첫 나열일 F의 다음 날 끝을 넘지 않아야 한다(REQ-007). 구간이
        // 있는 레코드는 도착이 상한에 정확히 닿아도 되고(AF-018-26: 도착 D+2 00:00), 깨진 레코드는
        // 엄격(그 전)이다. 상한을 이미 넘은 구간(이틀 넘게 걸친 옛 데이터)은 max(0, …)의
        // 0에서 멈춘다 — 대칭 자르기처럼 반대 방향으로 넘기지 않는다(AF-018-25).
        let downwardTime = span?.end ?? listingTime
        if let dayAfterF = calendar.date(byAdding: .day, value: 1, to: firstListed),
           let dayEnd = calendar.dateInterval(of: .day, for: dayAfterF)?.end {
            let strictness = span == nil ? 1 : 0
            high = min(high, max(0, Int(dayEnd.timeIntervalSince(downwardTime) / 60) - strictness))
        }
        let target = Self.gridSnappedDelta(from: reference, requestedMinutes: requestedMinutes, calendar: calendar)
        // 위 갈래와 같은 반대 부호 가드(수리 1 S-1) — 12:53 출발 +1 요청이 눈금 12:50의 −3으로
        // 반올림되면 창 끝까지 접히지 않고 제자리에 머문다.
        if target < 0 { return 0 }
        if target <= high { return target }
        return max(0, gridFloor(high))
    }

    /// 가장자리 드래그의 세 상태(REQ-015 (1) — D-14 (가), 운영자 Q-23 "(가)"). 안쪽은 가장자리를
    /// 넘지 않은 채, 붙음은 앞쪽 끝이 가장자리에 붙어 눌렀던 날에 남는 상태, 넘김은 구간 전체가
    /// 눌렀던 날을 떠난 상태다. 뷰(P2)의 표지·칩·숨김은 이 값을 읽기만 하고 다시 판정하지 않는다.
    enum DragEdgeState: Equatable {
        case inside
        case held
        case crossed
    }

    /// 드래그 가장자리 판정의 바깥 함수(REQ-015 (1)·REQ-008 0.9.0 문장). 한계 함수
    /// effectiveDragMinutes를 딱 한 번 불러 유효 Δ의 상한을 정하고(한계는 여전히 한 곳), 그
    /// 잘린 값으로만 상태를 정한다 — 상태를 다른 곳에서 다시 계산하면 표시 ≠ 결과(R-1)가
    /// 되돌아온다. 미리보기(onChange)와 드롭(adjustTravelLeg의 pressedOn)이 같이 부르며,
    /// 자기 결과에 다시 적용하면 같은 Δ에 넘김 여부도 같다(붙음 결과는 앞쪽 끝이 가장자리에
    /// 닿은 값이라 '안쪽'으로 읽히지만 눌렀던 날에 남는다는 결과는 같다).
    /// @MX:ANCHOR fan_in ≥ 3 — 드래그 미리보기·드롭(adjustTravelLeg)·드라이버(AF-018-37~41)가 같이 부른다
    /// 반환 direction는 요청 Δ의 부호(손가락 방향)다 — 붙음에서 deltaMinutes가 0으로 접혀도 방향은
    /// 살아 있고, 뷰는 방향을 접힌 Δ의 부호로 다시 추론하지 말고 이 값만 읽는다(계약 5). Δ 0 붙음을
    /// 0의 부호로 읽으면 아래로 끄는 중에 "00:00부터"가 맨 위에 뜬다(sync 0.9.1 N1). 한계가 0으로
    /// 잘린 조기 반환에서도 요청의 부호를 그대로 돌려준다.
    func dragEdgeOutcome(leg: ScheduledEvent, owner: ActivityBlock?, requestedMinutes: Int,
                         pressedOn: Date) -> (deltaMinutes: Int, state: DragEdgeState, direction: Int) {
        let direction = requestedMinutes.signum()
        let limited = effectiveDragMinutes(leg: leg, owner: owner, requestedMinutes: requestedMinutes)
        // 한계가 0으로 잘리면 구간은 움직이지 않는다 — 따라가기도 없으니(REQ-015 (3) "Δ 0") 상태는
        // 안쪽으로 하나로 둔다. 나머지 판정을 건너뛰는 것도 이 때문이다.
        guard limited != 0 else { return (0, .inside, direction) }
        let calendar = Calendar.current
        guard let pressDay = calendar.dateInterval(of: .day, for: pressedOn) else { return (limited, .inside, direction) }
        let downward = limited > 0
        let edge = downward ? pressDay.end : pressDay.start

        // effectiveDragMinutes와 같은 이유로 초를 먼저 잘라 쓴다 — 경계 판정이 초 때문에 흔들리지
        // 않게. 활동 끝도 같이 자른다(앞쪽 끝 묶음에 들어가니 같은 격자에 둬야 한다).
        var t = leg
        t.arrivalDate = Self.truncatedToMinute(t.arrivalDate)
        t.departureDate = t.departureDate.map(Self.truncatedToMinute)
        let span = t.listedSpan
        // 깨진 레코드(travelSeconds 있는데 출발 없음)만 나열 시각 하나가 앞쪽 끝에 들어간다 —
        // 실패 블록(REQ-016)은 listedSpan 구간이 들어가 일반 구간과 같은 길을 걷는다.
        let listingTime = Self.truncatedToMinute(t.arrivalDate)
        let ownerStart = owner.map { Self.truncatedToMinute($0.startDate) }
        let ownerEnd = owner.map { Self.truncatedToMinute($0.endDate) }
        // 끌리는 쪽 활동 가장자리: 가는 편은 활동 시작, 오는 편은 활동 끝(REQ-001·002 — 드래그가
        // 함께 미는 끝). 앞쪽 끝은 이 묶음에서 끄는 방향의 맨 앞끝(아래로 = 가장 늦은 끝,
        // 위로 = 가장 이른 끝)이다.
        let draggedEdge: Date?
        if owner != nil {
            draggedEdge = (t.anchor ?? .arrival) == .departure ? ownerEnd : ownerStart
        } else {
            draggedEdge = nil
        }
        let leadingEnd: Date
        if downward {
            leadingEnd = [span?.end ?? listingTime, draggedEdge].compactMap { $0 }.max() ?? listingTime
        } else {
            leadingEnd = [span?.start ?? listingTime, draggedEdge].compactMap { $0 }.min() ?? listingTime
        }

        // x: 잘린 Δ에서 앞쪽 끝이 가장자리를 넘은 분(방향 무관히 넘으면 양수). 위로는
        // 00:00 정확히가 아직 안쪽이다(반열린 나열 규칙과 같은 방향).
        let movedLeading = leadingEnd.addingTimeInterval(Double(limited) * 60)
        let x = downward ? Int(movedLeading.timeIntervalSince(edge) / 60)
                         : Int(edge.timeIntervalSince(movedLeading) / 60)
        let passesEdge = x > 0

        // 이미 걸친 구간: 누를 때 앞쪽 끝이 이미 가장자리 너머면 붙음이 없다 — 아직 나열되는 동안
        // 안쪽(눈금 밀기 그대로, D7), 완전히 떠나는 순간 넘김. 30분 최소 폭은 붙음 구간을 위한
        // 것이므로 여기엔 없다(D-14 "이미 걸친 구간").
        let alreadyCrossedAtPress = downward ? leadingEnd > edge : leadingEnd < edge
        if alreadyCrossedAtPress {
            return (limited, Self.movedLegIsListed(t, limited, on: pressedOn) ? .inside : .crossed, direction)
        }
        guard passesEdge else { return (limited, .inside, direction) }

        // 넘김: 뒤쪽 끝(구간의 다른 쪽 끝)까지 넘어 눌렀던 날을 완전히 떠났고, 문턱
        // max(구간이 떠나는 x, 최소 붙음 폭)도 넘었다. 구간이 떠나는 x는 나열 길이와 같다 — 오는 편은
        // 이동시간, 가는 편은 이동시간+여유(도착 기준 산식). 깨진 레코드(구간 없음)는 0.9.1 감사 O3의
        // 점 예외를 이어 나열 시각 하나로만 잰다(REQ-016 뒤에도 깨진 레코드는 구간이 없다).
        if let span {
            let listedLength = Int(Self.truncatedToMinute(span.end).timeIntervalSince(Self.truncatedToMinute(span.start)) / 60)
            if x >= max(listedLength, Self.minEdgeHoldMinutes),
               !Self.movedLegIsListed(t, limited, on: pressedOn) {
                return (limited, .crossed, direction)
            }
        } else if x >= Self.minEdgeHoldMinutes, !Self.movedLegIsListed(t, limited, on: pressedOn) {
            return (limited, .crossed, direction)
        }

        // 붙음: 앞쪽 끝이 가장자리에 닿는 가장 큰 눈금 Δ로 접는다. 가장자리(0시·24시)는 눈금이므로
        // 도착(앞쪽 끝 + 거리)의 가까운 눈금이 곧 후보고, 그 눈금이 가장자리를 넘으면 한 눈금 안으로
        // 물러난다 — 눈금 판정은 gridSnappedDelta가 단일 출처로 한다(REQ-013, 계약 5). 거리는 끄는
        // 방향으로 부호를 붙인다(위로 끌면 가장자리가 앞쪽 끝보다 앞에 있어 음수다 — 1차 드라이버에서
        // 위 거울이 0으로 접히던 것은 이 부호를 양수 거리로 계산했기 때문이다).
        let gapMinutes = Int(edge.timeIntervalSince(leadingEnd) / 60)
        var reachDelta = Self.gridSnappedDelta(from: leadingEnd, requestedMinutes: gapMinutes, calendar: calendar)
        let landing = leadingEnd.addingTimeInterval(Double(reachDelta) * 60)
        // 구간 없는 깨진 레코드는 나열 시각이 하루뿐이라 가장자리 '전'(엄격)에 멈춘다 — 정각은
        // 이미 다음 날이다(옛 점 예외의 잔여. REQ-016 뒤에도 깨진 레코드는 구간이 없다).
        let strict = span == nil && downward
        if (downward && landing > edge) || (!downward && landing < edge) || (strict && landing >= edge) {
            reachDelta += downward ? -Self.dragSnapStepMinutes : Self.dragSnapStepMinutes
        }
        let heldMagnitude = min(abs(limited), abs(reachDelta))
        return (limited > 0 ? heldMagnitude : -heldMagnitude, .held, direction)
    }

    /// dragEdgeOutcome이 잘린 Δ를 적용한 구간이 눌렀던 날에 여전히 나열되는지 본다. 판정은
    /// isListed(반열린)를 그대로 부른다 — 여기서 다른 규칙을 쓰면 화면 나열·따라가기(followDay)와
    /// 어긋난다(계약 5).
    private static func movedLegIsListed(_ leg: ScheduledEvent, _ minutes: Int, on day: Date) -> Bool {
        var moved = leg
        moved.arrivalDate = leg.arrivalDate.addingTimeInterval(Double(minutes) * 60)
        moved.departureDate = leg.departureDate?.addingTimeInterval(Double(minutes) * 60)
        return moved.isListed(on: day, calendar: .current)
    }

    /// 놓은 뒤 화면이 따라갈 날(REQ-015 (3), D-12 (나)) — 유효 Δ가 0이 아닐 때만 의미가 있다.
    /// 규칙은 눌렀던 날 기준(운영자 D7): 구간이 눌렀던 날에 (반열린 나열 규칙으로) 여전히 나열되면
    /// nil — 눈금 한 칸만 밀어도 눌렀던 화면에 남는다. 완전히 벗어났을 때만 따라가는데, 아래로 끌었으면
    /// 그 구간이 나열되는 마지막 날, 위로 끌었으면 처음 날이다(도착이 정확히 0시면 반열린 규칙에서
    /// 그 날은 빠진다). 소유 여부와 무관하게 구간 시각만 읽는다(Q-20). 나열일 후보는 listedSpan
    /// (계산 성공·실패 모두 — 깨진 레코드만 나열 시각 하루, t82 REQ-016)이 걸칠 수 있는 날뿐이라
    /// 그 창 안에서 isListed로
    /// 스캔한다 — 반열린 판정을 여기서 다시 만들지 않고 isListed를 그대로 부른다(계약 5, AC-017
    /// G — 뷰는 이 함수의 값만 받고 isListed를 따로 재계산하지 않는다). 드라이버(AF-018-32)가
    /// 인스턴스 없이 부를 수 있게 static인데, isListed가 MainActor여서 Store의 다른 순수
    /// static(overlapsDay·dayKey)과 같은 격리를 따른다.
    static func followDay(for leg: ScheduledEvent, pressedOn day: Date, deltaSign: Int,
                          calendar: Calendar = .current) -> Date? {
        if leg.isListed(on: day, calendar: calendar) { return nil }
        guard deltaSign != 0 else { return nil }   // 유효 Δ 0이면 구간은 그대로 — 눌렀던 날에 있다.
        if let span = leg.listedSpan {
            guard let from = calendar.dateInterval(of: .day, for: span.start)?.start,
                  let to = calendar.dateInterval(of: .day, for: span.end)?.start else { return nil }
            var d = deltaSign > 0 ? to : from
            while deltaSign > 0 ? d >= from : d <= to {
                if leg.isListed(on: d, calendar: calendar) { return d }
                guard let next = calendar.date(byAdding: .day, value: deltaSign > 0 ? -1 : 1, to: d) else { break }
                d = next
            }
            return nil
        }
        // 깨진 레코드(travelSeconds 있는데 출발 없음)의 나열일은 하루뿐이다 — 방향과 무관하게 그
        // 날이 따라갈 날이다. 실패 블록은 위 구간 갈래로 간다(REQ-016 — listedSpan이 있다).
        return calendar.startOfDay(for: leg.failedBlockAnchor ?? leg.arrivalDate)
    }

    /// 시각을 0쪽으로 분 단위로 자른다(REQ-008 "초 단위 시각은 먼저 분으로 자른다").
    /// effectiveDragMinutes가 처음에 한 번만 불러 경계 판정 전에 초를 없앤다.
    nonisolated private static func truncatedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.towardZero) * 60)
    }

    /// 이동시간 재계산 없이 도착·출발 시각을 그대로 분 단위 평행이동한다(알림도 같이 옮김).
    /// 반복 그룹을 옮길 때 회차 수만큼 반복 호출되므로 여기서는 저장하지 않는다 — 호출부가
    /// 루프를 다 돈 뒤 save()를 한 번만 부른다(회차마다 JSON 인코딩+디스크 쓰기를 하면 느림).
    private func shiftEvent(_ id: UUID, byMinutes minutes: Int) {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        if let nid = events[idx].notificationId { notifications.cancel(id: nid) }
        events[idx].arrivalDate = events[idx].arrivalDate.addingTimeInterval(Double(minutes) * 60)
        if let dep = events[idx].departureDate {
            events[idx].departureDate = dep.addingTimeInterval(Double(minutes) * 60)
        }
        rescheduleNotification(at: idx)
    }

    /// 인덱스의 현재 값(도착/출발/알림리드)으로 알림만 다시 예약한다(이동시간 재계산 없음).
    private func rescheduleNotification(at idx: Int) {
        var event = events[idx]
        if let nid = event.notificationId { notifications.cancel(id: nid) }
        event.notificationId = nil
        guard let dep = event.departureDate, let travel = event.travelSeconds else { events[idx] = event; return }
        event.notificationId = scheduleDepartureNotification(
            for: event, departure: dep, travelSeconds: travel, source: "Adjusted")
        events[idx] = event
    }

    /// 네트워크 호출 없이, 이미 구한 이동시간(같은 반복 그룹의 첫 회차 값)을 그대로 적용한다.
    private func applyCachedArrivalEstimate(to event: inout ScheduledEvent, travelSeconds: TimeInterval,
                                            source: String = "Estimated from the same repeating event") {
        event.anchor = .arrival
        if let nid = event.notificationId { notifications.cancel(id: nid) }
        event.travelSeconds = travelSeconds
        let departure = Store.departureTime(arrival: event.arrivalDate, travelSeconds: travelSeconds, bufferMinutes: event.bufferMinutes)
        event.departureDate = departure
        event.notificationId = scheduleDepartureNotification(
            for: event, departure: departure, travelSeconds: travelSeconds, source: source)
    }

    /// 네트워크 호출 없이, 이미 구한 이동시간을 출발-고정형(복귀 등) 회차에 적용한다.
    private func applyCachedDepartureEstimate(to event: inout ScheduledEvent, departureDate: Date,
                                              travelSeconds: TimeInterval,
                                              source: String = "Estimated from the same repeating event") {
        event.anchor = .departure
        if let nid = event.notificationId { notifications.cancel(id: nid) }
        event.travelSeconds = travelSeconds
        event.departureDate = departureDate
        // @MX:NOTE: 역방향 식(출발 + 이동 + 버퍼) — 접으려면 저장된 버퍼 의미 정리가 먼저다(후속 카드 t67).
        event.arrivalDate = departureDate.addingTimeInterval(travelSeconds + Double(event.bufferMinutes) * 60)
        event.notificationId = scheduleDepartureNotification(
            for: event, departure: departureDate, travelSeconds: travelSeconds, source: source)
    }

    /// iOS는 앱 하나가 예약해둘 수 있는 로컬 알림을 64개까지만 유지하고, 그걸 넘긴 요청은
    /// **조용히 버린다**(가장 먼저 울릴 64개만 남김). 26주짜리 반복 일정을 하루 4구간
    /// (등원·복귀·점심 왕복)으로 만들면 520건이라, 3주쯤 뒤 회차부터는 알림이 아예 오지 않는다 —
    /// 앱은 notificationId를 갖고 있으니 예약된 줄 알지만 실제로는 없는 상태가 된다.
    ///
    /// 그래서 "알림 시각이 가장 가까운 것부터 limit건"만 실제로 예약해두고, 앱이 foreground로
    /// 올 때마다 다시 채워 넣는다(앞쪽 회차가 지나가면 그만큼 뒤쪽 회차가 새로 들어온다).
    func rescheduleNearestNotifications(limit: Int = 60) {
        drvRescheduleCount += 1   // t50 S1 — REQ-005 "재예약 1" 계수기(앱 논리 영향 없음)
        let now = Date()
        // events를 요소 단위로 여러 번 고치면 didSet(daysWithSchedule 재계산)이 매번 돌아
        // 건수의 제곱에 비례해 느려진다 — 복사본에서 다 고치고 마지막에 한 번만 대입한다.
        var updated = events
        let upcoming = updated.indices.compactMap { i -> (idx: Int, at: Date)? in
            guard updated[i].wantsNotification,
                  let dep = updated[i].departureDate, updated[i].travelSeconds != nil else { return nil }
            let at = NotificationManager.alarmTime(departure: dep, leadMinutes: updated[i].notifyLeadMinutes)
            return at > now ? (i, at) : nil
        }
        .sorted { $0.at < $1.at }
        .prefix(limit)

        notifications.cancelAll()
        for i in updated.indices { updated[i].notificationId = nil }
        for item in upcoming {
            guard let travel = updated[item.idx].travelSeconds,
                  let dep = updated[item.idx].departureDate else { continue }
            updated[item.idx].notificationId = scheduleDepartureNotification(
                for: updated[item.idx], departure: dep, travelSeconds: travel, source: "Schedule refresh")
        }
        events = updated
        save()
        // 재조회가 심어둔 따라잡기 알림은 여기서 보낸다 — cancelAll·재예약 뒤여야 평소 알림이
        // 다시 미래인 일정을 걸러내고(W5), 즉시 요청이 cancelAll과 엇갈리지 않는다(M10).
        drainCatchUpAlerts()
    }

    /// 재조회가 심어둔 따라잡기 알림을 현재 레코드로 다시 판정해 즉시 요청으로 보낸다(REQ-009).
    /// @MX:WARN 재예약의 cancelAll() 뒤에만 꺼낸다(M10) — 꺼냄이 앞서면 즉시 요청이 뒤이은
    /// cancelAll과 엇갈릴 수 있고(미확인, R-2) 평소 알림이 다시 미래인 일정을 W5처럼 걸러내지 못한다.
    /// @MX:REASON 목록은 비저장이라 여기서 못 보내면 종료 창에 사라진다(R-7, 받아들인 잔여 위험).
    private func drainCatchUpAlerts() {
        guard !pendingCatchUpIDs.isEmpty else { return }
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        for id in pendingCatchUpIDs {
            guard let record = events.first(where: { $0.id == id }) else { continue }   // W3 — 지워짐
            let verdict = Store.catchUpDrainDecision(exists: true, wants: record.wantsNotification,
                                                     departure: record.departureDate,
                                                     leadMinutes: record.notifyLeadMinutes, now: now)
            guard verdict != .drop, let dep = record.departureDate, let travel = record.travelSeconds else { continue }
            // 이동시간이 비면 본문에 쓸 게 없어 보내지 않는다(다른 경로가 비운 드문 경우).
            let estimate = TravelEstimate(mode: record.mode, duration: travel, distance: nil, source: "Re-lookup")
            let depText = f.string(from: dep)
            switch verdict {
            case .catchUp:
                let base = "\(record.mode.title) to \(record.destination.name): \(estimate.durationText). Leave by \(depText) to make it."
                notifications.deliverNow(title: "🚶 \(record.title) — leave earlier than planned",
                                         body: Replan.catchUpBody(base: base, outcome: replanOutcomes[id]),
                                         id: "catchup-" + record.id.uuidString, eventID: record.id)
            case .late:
                let base = "\(record.mode.title) to \(record.destination.name): \(estimate.durationText). The departure time (\(depText)) has passed."
                notifications.deliverNow(title: "🚶 \(record.title) — the departure time has passed",
                                         body: Replan.catchUpBody(base: base, outcome: replanOutcomes[id]),
                                         id: "catchup-" + record.id.uuidString, eventID: record.id)
            case .drop: break
            }
        }
        pendingCatchUpIDs.removeAll()
    }

    /// refreshUpcomingEstimates의 대상 선택 — 창(지금 < 출발 ≤ 지금 + withinMinutes분) 안이면서
    /// REQ-004로 동결되지 않은 일정의 id. 순수 함수라 드라이버가 값 표로 단언한다.
    /// 일반 static(메인 액터 격리)로 둔 이유: 부르는 alarmTime이 메인 액터 격리라 nonisolated에서는
    /// 컴파일되지 않는다(SPEC-ONTIME-005 M17). departureTime이 nonisolated일 수 있는 것은 순수
    /// 산술이라서고, 여기는 격리된 호출이 있어 그 선례를 따르지 않는다.
    /// @MX:NOTE 알림 시각 판정은 alarmTime 호출로만 한다(계약 5) — 여기서 리드×60을 다시 쓰면
    /// 예약·재예약과 동결 판정이 어긋나 "동결됐는데 알림이 다시 울린다"가 생긴다.
    static func selectRefreshTargets(events: [ScheduledEvent], now: Date, withinMinutes: Int) -> [UUID] {
        let horizon = now.addingTimeInterval(Double(withinMinutes) * 60)
        return events.compactMap { e in
            guard let dep = e.departureDate, dep > now, dep <= horizon else { return nil }
            // 알림을 원하고 알림 시각이 지났으면(같음 포함 — alarmVerdict의 .past 판정과 같은 경계)
            // 이미 울린 알림이다. 재계산이 출발을 늦추면 새 알림 시각이 다시 미래가 돼 같은 일정의
            // 알림이 두 번 울리므로(X16) 재조회 대상에서 뺀다. 알림을 끈 일정은 이 규칙에 걸리지 않는다.
            if e.wantsNotification,
               NotificationManager.alarmTime(departure: dep, leadMinutes: e.notifyLeadMinutes) <= now {
                return nil
            }
            return e.id
        }
    }

    /// The alert of an event is pending: it wants one and its alarm time is ahead. The complement of the fired test of
    /// `selectRefreshTargets`.
    /// @MX:NOTE the alarm time is read through `alarmTime` only (contract 5): one rule for the selection, the refresh
    /// decision, the drain and the tap.
    static func alertIsPending(wants: Bool, departure: Date, leadMinutes: Int, now: Date) -> Bool {
        wants && NotificationManager.alarmTime(departure: departure, leadMinutes: leadMinutes) > now
    }

    enum TapRoute: Equatable { case baseline, nothing, fired }

    /// Where the tap of an alert goes: a pending alert is a baseline check when the app-open selection would select the
    /// event, and nothing otherwise; everything else keeps the fired-alert path.
    /// @MX:NOTE the window is the app-open selection's own: the same function and the same number, not a copy of the rule.
    static func tapRoute(for event: ScheduledEvent, now: Date, withinMinutes: Int) -> TapRoute {
        guard let departure = event.departureDate,
              alertIsPending(wants: event.wantsNotification, departure: departure,
                             leadMinutes: event.notifyLeadMinutes, now: now) else { return .fired }
        return selectRefreshTargets(events: [event], now: now, withinMinutes: withinMinutes).isEmpty ? .nothing : .baseline
    }

    /// @MX:NOTE 계약 5 — 알림 시각은 alarmTime 호출로만 계산한다(본문 2줄). 옛 출발은 await 뒤
    /// id로 다시 읽은 레코드의 출발이다(사본이 아니라, D3). 순수 함수라 드라이버가 값 표로 단언한다.
    /// 일반 static(메인 액터 격리)인 이유는 selectRefreshTargets 머리말과 같다(SPEC-ONTIME-005 M17).
    static func refreshAlarmDecision(wants: Bool, oldDeparture: Date, newDeparture: Date,
                                     leadMinutes: Int, now: Date) -> RefreshAlarmDecision {
        guard wants else { return .none }
        if NotificationManager.alarmTime(departure: oldDeparture, leadMinutes: leadMinutes) <= now {
            return .discardFired
        }
        if NotificationManager.alarmTime(departure: newDeparture, leadMinutes: leadMinutes) > now {
            return .normal
        }
        return newDeparture > now ? .catchUp : .late
    }

    /// 따라잡기 목록을 꺼낼 때의 재판정(REQ-009). 지워졌거나 알림을 껼거나 알림 시각이 다시
    /// 미래면(평소 알림이 맡음) 버리고, 출발이 미래면 따라잡기 문구, 지났으면 늦음 문구로 보낸다.
    /// 출발이 nil이면 판정할 근거가 없어 버린다. 나이 상한은 없다(R-7 잔여 위험).
    static func catchUpDrainDecision(exists: Bool, wants: Bool, departure: Date?,
                                     leadMinutes: Int, now: Date) -> CatchUpDrainDecision {
        guard exists, wants, let departure else { return .drop }
        if NotificationManager.alarmTime(departure: departure, leadMinutes: leadMinutes) > now {
            return .drop
        }
        return departure > now ? .catchUp : .late
    }

    /// 출발 시각이 임박한(기본 2시간 이내) 일정들의 이동시간을 실시간으로 다시 조회해 갱신한다.
    /// 반복 일정 생성 때 아낀 API 호출을, 실제로 그 회차가 다가왔을 때만 소비한다. 앱이 foreground될 때 호출.
    /// SPEC-REPLAN-001: `trigger` says who asked. `.appOpen` (the default; the foreground call) looks up with traffic and
    /// keeps a replan outcome; `.background` (the baseline app-refresh task) is not live, keeps no outcome and leaves every
    /// car event alone.
    func refreshUpcomingEstimates(withinMinutes: Int = Store.refreshWindowMinutes, trigger: ReplanTrigger = .appOpen) async {
        let postAlertIDs = await refreshBaselineEstimates(withinMinutes: withinMinutes, trigger: trigger)
        await replanPostAlertEvents(postAlertIDs)
    }

    /// The foreground sequence (SPEC-REPLAN-003): the legs of the repeats, the baseline check, the alert reschedule, then the
    /// after-alert checks.
    /// @MX:NOTE the reschedule runs before the after-alert lookups (REQ-REPLAN-310): that pass stores only earlier departures
    /// of events whose alert is not pending, never touches a notification and queues no catch-up alert, so it changes neither
    /// the alerts the reschedule adds nor the catch-up alerts it delivers, and opening the app does not wait for it.
    func runAppOpenPass() async {
        // The legs of the repeats for the next days are made before the alarms are rescheduled.
        await fillSeriesLegs()
        let postAlertIDs = await refreshBaselineEstimates()
        rescheduleNearestNotifications()
        await replanPostAlertEvents(postAlertIDs)
    }

    /// The baseline pass of `refreshUpcomingEstimates`: the events whose alert has not fired. Returns the ids of the events
    /// the after-alert pass checks next.
    private func refreshBaselineEstimates(withinMinutes: Int = Store.refreshWindowMinutes,
                                          trigger: ReplanTrigger = .appOpen) async -> [UUID] {
        let now = Date()
        // 인덱스가 아니라 id로 대상을 잡는다 — 아래 루프는 await로 중단되고, 그 사이 동기화나
        // 사용자의 추가·삭제로 events 배열이 바뀌면 인덱스가 다른 일정을 가리키거나(엉뚱한 일정을
        // 덮어씀) 범위를 벗어나 크래시할 수 있다.
        // 창 안 판정과 알림 경과 동결은 selectRefreshTargets가 단독으로 한다(REQ-004·드라이버 R4~R10).
        var targetIDs = Store.selectRefreshTargets(events: events, now: now, withinMinutes: withinMinutes)
        // A background launch is a fresh process with no outcome in memory, and a car lookup without traffic could only
        // overwrite a live-adjusted departure, so the background pass skips every car event (REQ-REPLAN-009).
        if trigger == .background {
            targetIDs.removeAll { id in events.first(where: { $0.id == id })?.mode == .car }
        }
        // Events the window skips because their alert fired or their departure passed, while the arrival is ahead.
        let postAlertIDs = trigger == .appOpen
            ? Store.selectPostAlertTargets(events: events, now: replanNow(), withinMinutes: withinMinutes) : []
        guard !targetIDs.isEmpty || !postAlertIDs.isEmpty else { return [] }
        for id in targetIDs {
            _ = await refreshOneEstimate(id: id, trigger: trigger)
        }
        if !targetIDs.isEmpty { save() }
        return postAlertIDs
    }

    /// The after-alert pass of the app open: one live check for each event the baseline pass left out.
    private func replanPostAlertEvents(_ ids: [UUID]) async {
        for id in ids {
            await replanAfterAlert(id: id, trigger: .appOpen)
        }
    }

    /// The baseline step for one event, moved out of the loop of `refreshBaselineEstimates` unchanged. Returns true only when
    /// a live answer was recorded and the record patched; a guard skip, a failed lookup and a discarded answer return false.
    private func refreshOneEstimate(id: UUID, trigger: ReplanTrigger) async -> Bool {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return false }
        var event = events[idx]
        let before = event   // the copy before the await: the reference for which fields the lookup really changed
        // Live only for the two foreground triggers and for an event anchored on arrival (REQ-REPLAN-005, 009).
        let live = trigger != .background && (event.anchor ?? .arrival) == .arrival
        let started = replanNow()
        if live {
            if isLookupInFlight(id) || recentLiveLookup(of: id, at: started) { return false }
            beginLookup(id)
            lastLiveAnswers[id] = nil
        }
        let decision: RefreshAlarmDecision?
        switch event.anchor ?? .arrival {
        case .arrival:
            // Keep mode: a failed lookup does not erase the previous travel time, departure or alert (REQ-001).
            decision = await applyEstimate(to: &event, keepOnFailure: true, live: live)
        case .departure:
            guard let dep = event.departureDate else { return false }
            decision = await applyDepartureAnchoredEstimate(to: &event, departureDate: dep, keepOnFailure: true)
        }
        if live { endLookup(id) }
        // A discard (nil = no record, no departure, or the old alert rang during the lookup) skips the write-back too (REQ-004, Q2=A).
        guard let decision else { return false }
        // The index is found again after the await (same reason as above).
        guard let writeIdx = events.firstIndex(where: { $0.id == id }) else { return false }
        // The record is not written back whole: only the fields the lookup changed are put on the current record. If another
        // write (a title or buffer applied from another device) edited the record during the await, a whole write-back would
        // revert that edit to a stale copy, and the save detection would push the stale version to every device.
        Store.patchEstimateFields(from: before, to: event, into: &events[writeIdx])
        // A catch-up or late alert is sent as an immediate request at the end of the reschedule (REQ-001, 002). It is queued in
        // the same synchronous stretch right after the write-back: queued earlier, a drain in the gap would see the old record
        // (alert in the future) and drop it (audit N5).
        if decision == .catchUp || decision == .late {
            pendingCatchUpIDs.insert(event.id)
        }
        if live, let answer = lastLiveAnswers.removeValue(forKey: id) {
            recordOutcomeOfOpenPass(before: before, started: started, trigger: trigger, answer: answer)
            return true
        }
        return false
    }

    // MARK: - Live replan (SPEC-REPLAN-001, card t18)

    /// Events the baseline window skips because their alert fired or their departure passed, while the arrival is still
    /// ahead: arrival ahead, departure inside the window, not in the baseline selection, anchored on arrival, with a stored
    /// plan and an origin. Soonest arrival first, at most `limit` (REQ-REPLAN-005, L3). Pure, so a test reads it as a table.
    static func selectPostAlertTargets(events: [ScheduledEvent], now: Date, withinMinutes: Int,
                                       limit: Int = Replan.maxPostAlertEvents) -> [UUID] {
        let baseline = Set(selectRefreshTargets(events: events, now: now, withinMinutes: withinMinutes))
        let horizon = now.addingTimeInterval(Double(withinMinutes) * 60)
        return events
            .filter { e in
                guard e.arrivalDate > now, (e.anchor ?? .arrival) == .arrival, e.origin != nil,
                      e.travelSeconds != nil, let departure = e.departureDate, departure <= horizon else { return false }
                return !baseline.contains(e.id)
            }
            .sorted { $0.arrivalDate < $1.arrivalDate }
            .prefix(limit)
            .map { $0.id }
    }

    private func recentLiveLookup(of id: UUID, at now: Date) -> Bool {
        guard let last = lastLiveLookup[id] else { return false }
        return now.timeIntervalSince(last) < Replan.debounce
    }

    private func beginLookup(_ id: UUID) { liveLookupsInFlight[id, default: 0] += 1 }

    private func endLookup(_ id: UUID) {
        let left = (liveLookupsInFlight[id] ?? 1) - 1
        liveLookupsInFlight[id] = left > 0 ? left : nil
    }

    private func isLookupInFlight(_ id: UUID) -> Bool { liveLookupsInFlight[id] != nil }

    /// The pair a new check compares with: the first plan of the event's cycle (REQ-REPLAN-004). It is the pair of the
    /// event's outcome while that outcome was made from the same inputs and its arrival is ahead, else the stored pair.
    private func referencePair(of id: UUID, inputs: ReplanInputs, now: Date, storedDeparture: Date,
                               storedTravel: TimeInterval) -> (departure: Date, travel: TimeInterval) {
        Replan.referencePair(existing: replanOutcomes[id], inputs: inputs, now: now,
                             storedDeparture: storedDeparture, storedTravel: storedTravel)
    }

    /// Keeps an outcome, or removes the event's outcome when the result is unchanged. A late one carries the fixed draft.
    private func keep(_ outcome: ReplanOutcome, title: String) {
        guard outcome.kind != .unchanged else {
            replanOutcomes[outcome.eventID] = nil
            return
        }
        var kept = outcome
        if kept.kind == .late, let estimate = kept.arrivalEstimate {
            kept.draft = Replan.templateDraft(lateBy: kept.minutes, title: title, estimate: estimate)
        }
        replanOutcomes[kept.eventID] = kept
    }

    /// The app-open path of an event whose alert has not fired: the baseline code has already stored the live pair, so this
    /// only keeps the outcome. `before` is the copy taken before the lookup.
    private func recordOutcomeOfOpenPass(before: ScheduledEvent, started: Date, trigger: ReplanTrigger,
                                         answer: (seconds: TimeInterval, noTrafficSeconds: TimeInterval?)) {
        let id = before.id
        guard let current = events.first(where: { $0.id == id }) else { return }
        // A lookup that started earlier writes no outcome when a later-started one of the event has finished.
        // @MX:NOTE unreachable behind the lookup guards while the clock does not move back by 300 s or more during a lookup;
        // kept as defensive code (SPEC-REPLAN-003, plan.md 6.2).
        if let done = finishedLookupStart[id], done >= started { return }
        finishedLookupStart[id] = started
        let finished = replanNow()
        lastLiveLookup[id] = finished
        guard let storedDeparture = before.departureDate, let storedTravel = before.travelSeconds else { return }
        let inputs = ReplanInputs(event: current)
        let reference = referencePair(of: id, inputs: inputs, now: finished,
                                      storedDeparture: storedDeparture, storedTravel: storedTravel)
        let outcome = Replan.classify(eventID: id, trigger: trigger, checkedAt: started, inputs: inputs,
                                      referenceDeparture: reference.departure, referenceTravel: reference.travel,
                                      liveTravel: answer.seconds, noTrafficTravel: answer.noTrafficSeconds, now: finished)
        keep(outcome, title: current.title)
    }

    /// The live check of one event whose alert has fired (a tap on its alert, or an app-open pass over an event the window
    /// skips). It sends no notification, stores the new travel time and departure only when the new departure is not later
    /// than the stored one, and keeps the outcome (REQ-REPLAN-006, 007, 008). A later departure of at least two minutes is
    /// kept as an after-alert outcome without storing anything (SPEC-REPLAN-002).
    func replanAfterAlert(id: UUID, trigger: ReplanTrigger) async {
        guard let startIndex = events.firstIndex(where: { $0.id == id }) else { return }
        let copy = events[startIndex]
        let started = replanNow()
        // No lookup and no draft for a past arrival or an event anchored on departure (REQ-REPLAN-006).
        guard copy.arrivalDate > started, (copy.anchor ?? .arrival) == .arrival,
              let origin = copy.origin, copy.departureDate != nil, copy.travelSeconds != nil else { return }
        // @MX:NOTE the tap of an old banner of an event whose new alert is pending is the app-open check of that event
        // (SPEC-REPLAN-003): without the alert move, the pending alert could ring after the new departure.
        if trigger == .alertTap {
            switch Store.tapRoute(for: copy, now: started, withinMinutes: Store.refreshWindowMinutes) {
            case .nothing:
                return   // pending but beyond the app-open window: no lookup, nothing stored, the outcome stays
            case .baseline:
                // Skipped, failed or discarded: nothing is written.
                guard await refreshOneEstimate(id: id, trigger: .alertTap) else { return }
                save()
                // The reschedule delivers a queued catch-up or late alert; otherwise the check has already moved the alert.
                if pendingCatchUpIDs.contains(id) { rescheduleNearestNotifications() }
                return
            case .fired:
                break
            }
        }
        // @MX:NOTE every tap obeys the guards of the app open: no live lookup while one of the event is in flight or within
        // 300 seconds of its last successful one. A skipped tap writes nothing and still opens the event screen.
        if isLookupInFlight(id) || recentLiveLookup(of: id, at: started) { return }
        beginLookup(id)
        let found = await lookupTravelSeconds(copy.mode, origin: origin, destination: copy.destination, live: true)
        endLookup(id)
        guard !Task.isCancelled, let found else { return }
        let finished = replanNow()
        // The record is read again by id: gone, edited meanwhile, or past its arrival means nothing is written.
        guard let current = events.firstIndex(where: { $0.id == id }),
              Store.estimateInputsUnchanged(copy, events[current]),
              events[current].arrivalDate > finished,
              let storedDeparture = events[current].departureDate,
              let storedTravel = events[current].travelSeconds else { return }
        // An alert that became pending during the lookup (the departure was retimed) is not a fired-alert case any more.
        if Store.alertIsPending(wants: events[current].wantsNotification, departure: storedDeparture,
                                leadMinutes: events[current].notifyLeadMinutes, now: finished) { return }
        // @MX:NOTE unreachable behind the lookup guards while the clock does not move back by 300 s or more during a lookup;
        // kept as defensive code (SPEC-REPLAN-003, plan.md 6.2).
        if let done = finishedLookupStart[id], done >= started { return }
        finishedLookupStart[id] = started
        lastLiveLookup[id] = finished
        let inputs = ReplanInputs(event: events[current])
        let reference = referencePair(of: id, inputs: inputs, now: finished,
                                      storedDeparture: storedDeparture, storedTravel: storedTravel)
        let outcome = Replan.classify(eventID: id, trigger: trigger, checkedAt: started, inputs: inputs,
                                      referenceDeparture: reference.departure, referenceTravel: reference.travel,
                                      liveTravel: found.seconds, noTrafficTravel: found.noTrafficSeconds, now: finished)
        // A new departure later than the stored one would schedule a second alert, so it is shown and never stored (L4).
        // @MX:NOTE: the stored departure stays; `rescheduleNearestNotifications` adds a request for any alarm time still ahead.
        if outcome.newDeparture > storedDeparture, outcome.kind != .late {
            if let shown = Replan.afterAlert(outcome, storedDeparture: storedDeparture, storedTravel: storedTravel) {
                keep(shown, title: events[current].title)
            } else if replanOutcomes[id]?.afterAlert == true {
                replanOutcomes[id] = nil
            }
            return
        }
        if outcome.newDeparture <= storedDeparture {
            let currentCopy = events[current]
            var after = currentCopy
            after.travelSeconds = found.seconds
            after.departureDate = outcome.newDeparture
            Store.patchEstimateFields(from: currentCopy, to: after, into: &events[current])
            save()
        }
        keep(outcome, title: events[current].title)
    }

    /// 이동시간 재계산의 입력이 `await` 동안 그대로인지 본다(`copy` = await 전 사본, `current` = id로 다시 읽은 레코드).
    /// 다른 기기에서 받아 적용한 레코드가 기준(도착/고정 출발 시각·anchor)이나 버퍼·출발지·수단·알림 설정을 바꿨다면,
    /// 낡은 사본으로 계산한 파생값(출발·도착·이동시간·알림 id)을 붙이는 순간 상대의 새 기준값과 낡은 파생값이 섞여
    /// 앞뒤가 안 맞는 레코드가 되고, 그 판이 저장 감지로 다시 올라가 모든 기기로 퍼진다. 버리면 다음 재조회가
    /// 새 입력으로 다시 계산하므로 잃는 게 없다. 기준 시각은 동기화 지문과 같은 `anchorDate` 한 곳을 읽는다(계약 5).
    private static func estimateInputsUnchanged(_ copy: ScheduledEvent, _ current: ScheduledEvent) -> Bool {
        (copy.anchor ?? .arrival) == (current.anchor ?? .arrival)
            && copy.anchorDate == current.anchorDate
            && copy.bufferMinutes == current.bufferMinutes
            && copy.origin == current.origin
            && copy.destination == current.destination
            && copy.mode == current.mode
            && copy.wantsNotification == current.wantsNotification
            && copy.notifyLeadMinutes == current.notifyLeadMinutes
    }

    /// `applyEstimate`·`applyDepartureAnchoredEstimate`가 `event`에서 바꾸는 필드의 전부: `anchor`, `travelSeconds`,
    /// `departureDate`, `arrivalDate`(출발 기준일 때), `notificationId`. 이 다섯 중 `before`와 달라진 것만 `target`에
    /// 옮긴다 — 달라지지 않은 필드는 지금 레코드의 값을 그대로 둬야 그 사이 다른 쓰기가 바꾼 값이 살아남는다.
    /// 동시에 쓴 이가 없으면 `target == before`라 결과는 통째 되쓰기와 같다. 위 목록에 필드가 늘면 여기도 늘려야 한다.
    private static func patchEstimateFields(from before: ScheduledEvent, to after: ScheduledEvent,
                                            into target: inout ScheduledEvent) {
        if after.anchor != before.anchor { target.anchor = after.anchor }
        if after.travelSeconds != before.travelSeconds { target.travelSeconds = after.travelSeconds }
        if after.departureDate != before.departureDate { target.departureDate = after.departureDate }
        if after.arrivalDate != before.arrivalDate { target.arrivalDate = after.arrivalDate }
        if after.notificationId != before.notificationId { target.notificationId = after.notificationId }
    }

    func deleteEvent(_ event: ScheduledEvent) {
        if let nid = event.notificationId { notifications.cancel(id: nid) }
        events.removeAll { $0.id == event.id }
        save()
        removeUpcomingMeals(eventIDs: [event.id])
    }

    /// 여러 일정을 한 번에 삭제한다(알림 취소·캘린더 삭제 포함). 낱개 deleteEvent를 루프로 부르면
    /// 건수만큼 JSON 인코딩+디스크 쓰기 + daysWithSchedule 재계산이 반복돼(AI 일괄 삭제에서 수십 건)
    /// 눈에 띄게 느려진다 — 여기서는 저장·재계산이 한 번만 일어난다.
    func deleteEvents(_ list: [ScheduledEvent]) {
        guard !list.isEmpty else { return }
        let ids = Set(list.map { $0.id })
        for e in list {
            if let nid = e.notificationId { notifications.cancel(id: nid) }
        }
        events.removeAll { ids.contains($0.id) }
        save()
        removeUpcomingMeals(eventIDs: ids)
    }

    /// deleteEvents의 활동 블록 버전. 낱개 deleteActivity와 같은 정리 절차를 탄다(REQ-012) —
    /// 연결 구간까지 지운다는 점이 옛 코드와 다르다(옛 일괄 삭제는 구간을 남겨 매달린 링크를
    /// 만들었다). 기존 일괄 최적화(알림 취소·저장이 목록 전체에 한 번)는 유지한다.
    func deleteActivities(_ list: [ActivityBlock]) {
        deleteActivitiesCore(list)
    }

    /// 삭제 정리의 공통 몸통 — 낱개·일괄이 같은 절차를 탄다(계약 5). 구간 정리는
    /// removeExplicitLegs(알림 취소·식사 기록까지)가, 활동 제거·저장·식사는
    /// 여기서 각각 한 번만 돈다.
    private func deleteActivitiesCore(_ list: [ActivityBlock]) {
        guard !list.isEmpty else { return }
        let ids = Set(list.map { $0.id })
        removeExplicitLegs(of: ids)
        skipComputedOccurrences(ids)
        activities.removeAll { ids.contains($0.id) }
        saveActivities()
        removeUpcomingMeals(activityIDs: ids)
    }

    /// Deleting a computed occurrence adds its day to the series' skipped days; there is no record to remove. An id that
    /// is stored, is skipped already, or is not a live occurrence changes nothing here.
    private func skipComputedOccurrences(_ ids: Set<UUID>) {
        guard !series.isEmpty else { return }
        var updated = series
        var changed = false
        for id in ids where !activities.contains(where: { $0.id == id }) {
            guard let (owner, dayKey) = series(forOccurrence: id), activity(id: id) != nil,
                  let index = updated.firstIndex(where: { $0.id == owner.id }) else { continue }
            updated[index].skippedDayKeys.append(dayKey)
            changed = true
        }
        guard changed else { return }
        series = updated
        saveSeries()
    }

    /// 활동들의 명시적 연결 구간(linkedActivityId)만 지운다 — 반복 번호만 공유하는 연결 없는 구간은
    /// 활동의 것이 아니므로 여기서 건드리지 않는다(반복 전체 삭제의 몫). deleteActivity·
    /// deleteActivities·modifyActivity(clearPlace)가 같은 절차를 쓴다(정리 절차 두 벌 금지).
    private func removeExplicitLegs(of activityIds: Set<UUID>) {
        let legs = events.filter { $0.linkedActivityId != nil && activityIds.contains($0.linkedActivityId!) }
        guard !legs.isEmpty else { return }
        for e in legs { if let nid = e.notificationId { notifications.cancel(id: nid) } }
        let legIDs = Set(legs.map { $0.id })
        events.removeAll { legIDs.contains($0.id) }
        save()
        removeUpcomingMeals(eventIDs: legIDs)
    }

    /// **[테스트용]** 일정·활동·식사 기록을 전부 지운다. 출시 전에 이 함수와 설정의 버튼을 같이 뺀다.
    ///
    /// 낱개 삭제 경로(`deleteEvents`/`deleteActivities`)를 그대로 거치므로 알림 취소까지
    /// 정상적으로 처리된다.
    func deleteEverythingForTesting() {
        deleteEvents(events)
        deleteActivities(activities)
        if !meals.isEmpty {
            meals.removeAll()
            saveMeals()
        }
        // The repeats go too. Backups of an unreadable series file (`series.unreadable*.json`) are left alone.
        series = []
        saveSeries()
    }

    // MARK: - 설정

    func updateConfig(_ newConfig: AppConfig) {
        config = newConfig
        config.save()
    }

    // MARK: - 영속화

    func save() {
        drvSaveCount += 1   // t50 S1 — REQ-005 "저장 1" 계수기(앱 논리 영향 없음)
        try? FileManager.default.createDirectory(at: AppConfig.supportDirectory, withIntermediateDirectories: true)
        backupEventsBeforeFirstBicycleSave()
        try? JSONEncoder().encode(events).write(to: eventsURL)
    }

    /// D12 — 자전거 일정이 처음 저장되기 직전의 events.json을 한 번만 복사해 둔다.
    /// 옛 빌드는 "bicycle" raw 값에서 디코딩이 던져 load()가 빈 배열로 시작하고, 다음 save()가
    /// 그 빈 배열로 파일을 덮어 일정 전체가 사라진다. 이 사본은 그 손실을 막지 못하고(롤백 금지가
    /// 1차 방어) 사람이 되돌릴 수 있는 원본을 남길 뿐이다. 새 영속화 레이어가 아니라 기존 파일의
    /// 바이트 사본이라 계약 3과 충돌하지 않는다. 한 번만이어야 하는 이유: 두 번째 복사본은 이미
    /// 자전거가 섞인 파일이라 "자전거 이전" 사본이 아니게 된다.
    /// internal인 이유: 드라이버가 (a) 자전거 없음 → 사본 없음 (b) 첫 자전거 저장 → 사본 하나, 원본과
    /// 바이트 동일 (c) 둘째 저장 → 사본 불변을 직접 단언한다.
    static var bicycleBackupURL: URL {
        AppConfig.supportDirectory.appendingPathComponent("events.pre-bicycle.json")
    }

    /// 이 실행에서 백업 판정이 끝났는가(A4). 사본을 떴든, 이미 있든, 디스크가 이미 자전거를 담고 있어
    /// 뜰 필요가 없다고 정했든 다시 읽지 않는다. 플래그가 없으면 사본 없이 끝난 사용자는 저장 때마다
    /// events.json 전체를 읽고 디코딩한다. **복사가 실패한 경우는 판정이 끝난 것이 아니다**(아래 catch).
    /// 한계(비용과 맞바꾼 선택): "디스크에 이미 자전거" 갈래는 이후 저장도 같은 답이라는 보장이 없다 —
    /// 새 설치의 첫 일정이 자전거라 사본 없이 판정이 끝난 뒤 같은 실행에서 자전거를 모두 지웠다 다시
    /// 넣으면 사본을 못 뜬다(수리 전엔 떴다). 재시작해도 디스크에 이미 자전거라 되살아나지 않는다.
    /// 사본은 옛 빌드로 되돌릴 때만 쓰이고 1차 방어가 롤백 금지(운영자 결정 8)라 무게는 낮다.
    private var bicycleBackupSettled = false
    var drvBackupInspectCount = 0   // 드라이버 가시 계수기 — events.json을 읽어 디코딩한 횟수(앱 논리 영향 없음)

    func backupEventsBeforeFirstBicycleSave() {
        guard !bicycleBackupSettled, events.contains(where: { $0.mode == .bicycle }) else { return }
        let fm = FileManager.default
        let backup = Self.bicycleBackupURL
        if fm.fileExists(atPath: backup.path) { bicycleBackupSettled = true; return }
        // 기존 파일이 없으면 지킬 데이터가 없다. 판정은 보류한다 — 아직 읽은 것이 없고, 파일이 생긴 뒤의
        // 저장에서 다시 봐야 한다.
        guard fm.fileExists(atPath: eventsURL.path) else { return }
        // 디스크의 파일이 이미 자전거를 담고 있으면 그 사본은 "자전거 이전"이 아니다 — 옛 빌드에
        // 되돌려 넣으면 손실을 막으려던 사본이 같은 손실을 다시 부른다. 첫 자전거 일정이 파일 없이
        // 저장됐거나(지킬 것이 없었다) 첫 복사가 실패한 채 자전거가 이미 쓰인 경우가 여기에 걸린다.
        // 읽지 못하는 파일(손상)은 걸러 내지 않고 보존한다 — 그쪽이 지켜야 할 원본일 수 있다.
        drvBackupInspectCount += 1
        if let data = try? Data(contentsOf: eventsURL),
           let onDisk = try? JSONDecoder().decode([ScheduledEvent].self, from: data),
           onDisk.contains(where: { $0.mode == .bicycle }) {
            bicycleBackupSettled = true
            return
        }
        do {
            try fm.copyItem(at: eventsURL, to: backup)
            bicycleBackupSettled = true
        } catch {
            // 복사 실패가 저장을 막으면 일정 저장이 사라지는 쪽이 더 나쁘다 — 저장은 계속하되
            // 흔적은 남긴다. 플래그는 세우지 않는다: 복사 실패와 이어지는 쓰기 실패는 원인(공간·권한·
            // 보호 등급)이 같아 함께 일어날 수 있고, 그러면 파일에 아직 자전거가 없으니 다음 저장이
            // 다시 사본을 시도해야 한다. 쓰기가 성공했다면 다음 저장의 위 검사(디스크에 자전거 있음)가
            // 걸러 내 사본 없음으로 판정이 끝난다(자전거가 섞인 파일을 "이전" 사본으로 만들지 않는다).
            print("[Store] Failed to back up the earlier bicycle data: \(error)")
        }
    }

    private func load() {
        guard let decoded: [ScheduledEvent] = loadDataFile(eventsURL) else { return }
        events = decoded.sorted { $0.arrivalDate < $1.arrivalDate }
    }

    /// 네 데이터 파일을 읽는 한 곳. 파일이 없거나 읽거나 디코딩하지 못하면 nil(빈 배열로 시작).
    private func loadDataFile<T: Decodable>(_ url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        return nil
    }
}

/// 재조회 뒤 알림 처리 판정(SPEC-ONTIME-006 REQ-006). 케이스 줄 순서가 판정 우선순위다 —
/// none(알림 끔) → discardFired(조회 중 옛 알림이 울림, C1·REQ-004) → normal(평소) →
/// catchUp(출발이 당겨져 새 알림 시각이 지남, t68-M12·REQ-001) → late(새 출발까지 지남, REQ-002).
/// 알림 시각은 alarmTime 호출로만 계산한다(계약 5).
/// Store 안이 아니라 파일 범위로 둔 이유: 드라이버가 여러 파일을 한 모듈로 이어붙여 이 이름을
/// 한정자 없이 쓴다(AlarmVerdict가 NotificationManager.swift에서 같은 모양으로 서 있는 이유와 같다).
enum RefreshAlarmDecision: Equatable {
    case none, discardFired, normal, catchUp, late
}

/// 따라잡기 목록을 꺼낼 때의 재판정(REQ-009). 지워졌거나 알림을 껼거나 알림 시각이 다시
/// 미래면(평소 알림이 맡음) 버리고, 출발이 미래면 따라잡기 문구, 지났으면 늦음 문구로 보낸다.
/// 출발이 nil이면 판정할 근거가 없어 버린다. 나이 상한은 없다(R-7 잔여 위험). 파일 범위 이유는
/// RefreshAlarmDecision 머리말과 같다(드라이버의 한정자 없는 이름).
enum CatchUpDrainDecision: Equatable {
    case drop, catchUp, late
}
