import Foundation
import UserNotifications

/// 알림 진실성 판정 결과(SPEC-ONTIME-002). 상세 캡션과 AI 요약이 같은 판정에서 각자의 문장을
/// 낸다 — 판정이 한몸이어야 화면과 요약이 어긋나지 않는다(계약 5).
enum AlarmVerdict: Equatable {
    case off            // 꺼짐
    case noPermission   // 권한 없음
    case past           // 알림 시각이 이미 지남
    case scheduled      // 지금 예약돼 있음
    case later          // 가까워지면 예약됨
}

/// 시스템 알림 권한을 앱이 아는 세 값으로 모은 것. '모름'은 조회 전·조회 못 함 상태다.
enum AlarmPermission: Equatable {
    case allowed    // 허용
    case denied     // 거부
    case unknown    // 모름
}

/// alarmSentence의 갈래 — 캡션(상세 화면)과 요약(AI 답변)은 같은 판정에서 다른 문장을 낸다.
enum AlarmSentenceVariant {
    case caption
    case summary
}

/// 로컬 알림(알람) 예약/취소.
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// 시스템 알림 권한(초기 모름 — 조회 전에는 아는 게 없다). 상세 캡션이 이 값을 보고 재판정한다.
    @Published private(set) var permissionStatus: AlarmPermission = .unknown
    @Published var lastError: String?

    /// The event of the departure alert the user tapped, until a screen consumes it (SPEC-REPLAN-001 REQ-REPLAN-013).
    @Published private(set) var tappedEventID: UUID?
    /// Set by the store: a tap on an alert that carries an event id starts the live check of that event.
    var onAlertTap: ((UUID) -> Void)?
    /// How many requests `schedule` and `deliverNow` handed to the center. Tests read it; the app does not.
    private(set) var requestCount = 0
    /// The event id the last handed-over request carried. Tests read it; the app does not.
    private(set) var lastRequestEventID: UUID?

    /// The payload key that carries the event id of an alert.
    nonisolated static let eventIDKey = "besirEventID"

    override init() {
        super.init()
        // The delegate is set here, not only in `bootstrap()`: a tap that launches the app is delivered only to a
        // delegate that exists before the app finishes launching, and this object is made in `BesirApp.init`.
        center?.delegate = self
    }

    private var center: UNUserNotificationCenter? {
        // 번들 식별자가 없으면(예: 비번들 실행) UNUserNotificationCenter 접근이 크래시 나므로 가드.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func bootstrap() {
        guard let center else {
            lastError = "Notifications are unavailable because there is no bundle identifier."
            return
        }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            Task { @MainActor in
                // granted 불리언은 provisional 등 중간 상태를 말하지 못한다 — settings가 정본이다.
                self.refreshPermissionStatus()
                if let error { self.lastError = error.localizedDescription }
            }
        }
    }

    /// 시스템 알림 권한을 다시 읽는다. 값이 바뀔 때만 publish하고 재예약은 유발하지 않는다
    /// (iOS 대기 알림 64건 한도 — 권한 조회가 예약 창을 밀어내면 안 된다). center가 없으면
    /// (드라이버 등 비번들 실행) 아무것도 하지 않고 모름을 유지한다.
    func refreshPermissionStatus() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            Task { @MainActor in
                let value = Self.permission(from: settings.authorizationStatus)
                if self.permissionStatus != value { self.permissionStatus = value }
            }
        }
    }

    /// 지정 시각에 알림을 예약하고 식별자를 반환한다. 실패 시 nil.
    @discardableResult
    func schedule(title: String, body: String, at date: Date, id: String = UUID().uuidString,
                  eventID: UUID? = nil) -> String? {
        guard let center else { return nil }
        guard date > Date() else { return nil }   // 과거 시각은 예약하지 않음
        requestCount += 1
        lastRequestEventID = eventID

        let content = Self.content(title: title, body: body, eventID: eventID)

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request) { error in
            if let error { Task { @MainActor in self.lastError = error.localizedDescription } }
        }
        return id
    }

    func cancel(id: String) {
        center?.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// 즉시 알림을 보내고 식별자를 반환한다(실패 시 nil). 재조회 뒤 알림 시각이 이미 지난 일정의
    /// 따라잡기 전용(SPEC-ONTIME-006 REQ-003) — 트리거 nil 즉시 요청이라 대기 목록에 남지 않아
    /// rescheduleNearestNotifications의 cancelAll()에 지워지지 않는다(M10). 식별자는 호출처가
    /// "catchup-"+일정 id로 결정적으로 만든다(기본 UUID 인자를 두지 않는다, AC-003).
    @discardableResult
    func deliverNow(title: String, body: String, id: String, eventID: UUID? = nil) -> String? {
        guard let center else { return nil }
        requestCount += 1
        lastRequestEventID = eventID
        let content = Self.content(title: title, body: body, eventID: eventID)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { error in
            if let error { Task { @MainActor in self.lastError = error.localizedDescription } }
        }
        return id
    }

    /// Removes the delivered "Tap to review what you shared." banner once besir is in front (SPEC-SHAREOPEN-001 REQ-005).
    func clearShareNudge(center: NudgeCenter = SystemNudgeCenter()) {
        ShareNudge.clear(center: center)
    }

    /// 예약 대기 중인 알림을 전부 취소한다(Store가 "가까운 것부터 N건"만 다시 채울 때 사용).
    func cancelAll() {
        center?.removeAllPendingNotificationRequests()
    }

    // 앱이 포그라운드일 때도 배너를 보여준다.
    // @MX:NOTE .list(Y1, 2026-10-12): 배너만 넘기면 포그라운드로 받은 알림이 알림 센터에는 남지
    // 않고 지나가 버린다(t68-2 관측) — .list를 더해 센터에도 쌓이게 한다. 따라잡기 알림도 이 델리게이트를 거친다.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // A tap on an alert: forward the payload to `handleTap`. Only strings cross to the main actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        var payload: [String: String] = [:]
        if let value = response.notification.request.content.userInfo[NotificationManager.eventIDKey] as? String {
            payload[NotificationManager.eventIDKey] = value
        }
        completionHandler()
        Task { @MainActor in self.handleTap(userInfo: payload) }
    }

    /// Publishes the tapped event id and starts the live check. A payload without a valid id changes nothing.
    func handleTap(userInfo: [AnyHashable: Any]) {
        guard let id = Self.eventID(from: userInfo) else { return }
        tappedEventID = id
        onAlertTap?(id)
    }

    /// The tapped id, once: a screen that took it opens the event and the id is gone.
    func consumeTappedEventID() -> UUID? {
        guard let id = tappedEventID else { return nil }
        tappedEventID = nil
        return id
    }
}

// MARK: - 알림 진실성 판정(SPEC-ONTIME-002) — 전부 순수 함수, 센터를 건드리지 않는다

extension NotificationManager {

    /// The content of an alert; the event id rides in the payload when there is one (SPEC-REPLAN-001 REQ-REPLAN-010).
    static func content(title: String, body: String, eventID: UUID?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let eventID { content.userInfo = [eventIDKey: eventID.uuidString] }
        return content
    }

    /// The event id of a tapped alert: nil for a missing key, a value that is not a string, or a string that is not a UUID.
    static func eventID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let text = userInfo[eventIDKey] as? String else { return nil }
        return UUID(uuidString: text)
    }

    /// 알림 시각(출발 − 리드×60). 운영 소스 전체에서 리드 값에 60을 곱해 알림 시각을 만드는 곳은
    /// 이 본문 하나다(계약 5) — 실제 예약·64건 창 정렬·일정 추가 폼 노트가 전부 이 함수를 거친다.
    static func alarmTime(departure: Date, leadMinutes: Int) -> Date {
        departure.addingTimeInterval(-Double(leadMinutes) * 60)
    }

    /// 알림 상태 판정. 줄 순서가 뜻이다(plan §2.1): 꺼짐 → 출발 없으면 나중에 → 알림 시각이
    /// 지났으면(같음 포함) 시각 지남 → 권한 거부 → 식별자 있으면 예약됨 → 나중에. 지난 알림에
    /// 권한 문구가 나오지 않게 시각 지남이 권한보다 앞서고, '모름'은 권한 없음을 내지 않는다
    /// (거부만 낸다) — 첫 조회 전 캡션이 거짓말을 하지 않게.
    static func alarmVerdict(wants: Bool, hasId: Bool, departure: Date?, leadMinutes: Int,
                             permission: AlarmPermission, now: Date) -> AlarmVerdict {
        guard wants else { return .off }
        guard let departure else { return .later }
        if alarmTime(departure: departure, leadMinutes: leadMinutes) <= now { return .past }
        if permission == .denied { return .noPermission }
        if hasId { return .scheduled }
        return .later
    }

    /// 판정 → 캡션/요약 문장. 문구는 운영자 결정(2026-10-11)과 현행 alarmStatus 문구로 글자까지
    /// 정해져 있다 — 여기서 다듬지 않는다. "예약됨"은 예약됨 판정의 문장에만 들어간다(REQ-005).
    static func alarmSentence(for verdict: AlarmVerdict, leadMinutes: Int,
                              variant: AlarmSentenceVariant) -> String {
        switch (variant, verdict) {
        case (.caption, .off): return "Alert off"
        case (.caption, .noPermission): return "Notification permission is off, so it won't ring"
        case (.caption, .past): return "Alert time has passed, nothing scheduled"
        case (.caption, .scheduled): return "Alert scheduled \(leadMinutes) min before"
        case (.caption, .later): return "Alert will be scheduled closer to the time"
        case (.summary, .off): return "The departure alert is off."
        case (.summary, .noPermission): return "The alert \(leadMinutes) min before departure won't ring because notification permission is off."
        case (.summary, .past): return "The alert time has already passed, so no departure alert was scheduled."
        case (.summary, .scheduled): return "Alert scheduled \(leadMinutes) min before departure."
        case (.summary, .later): return "The alert \(leadMinutes) min before departure will be scheduled closer to the time."
        }
    }

    /// 반복 등록 요약의 알림 구절(D-4). 반복은 notify_enabled을 읽지 않아 꺼짐을 가리지 못하고
    /// 회차별 식별자도 없으니, 앱 전역 권한이 거부일 때만 이 문장을 내고 그 밖엔 nil — 호출부가
    /// 현행 "출발 N분 전 알림."을 그대로 두게 한다.
    static func alarmSentence(permission: AlarmPermission) -> String? {
        guard permission == .denied else { return nil }
        return "The departure alert won't ring because notification permission is off."
    }

    /// UNAuthorizationStatus → 세 값. switch로 고정한다: 임시 권한(ephemeral) 분기는
    /// #if os(iOS) 안에만 둔다 — 그 값을 식으로 참조하면 macOS 드라이버(swiftc)에서 컴파일이
    /// 안 되고, 밖에 두면 rawValue 4가 macOS에서 허용에 떨어져 기대값(모름)과 어긋난다.
    /// rawValue 비교는 같은 이유로 금지다.
    static func permission(from status: UNAuthorizationStatus) -> AlarmPermission {
        switch status {
        case .authorized, .provisional: return .allowed
        case .denied: return .denied
        case .notDetermined: return .unknown
        #if os(iOS)
        case .ephemeral: return .allowed
        #endif
        @unknown default: return .unknown
        }
    }

    /// 활동 추가 폼의 구간별 "확실히 지난" 판정. 폼은 저장 전이라 Store의 구간(저장 뒤 비동기로
    /// 생긴다)을 부를 수 없어 구간 규칙을 폼 예측용으로 다시 적는다(계약 5 비용 — 접는 일은
    /// 별도 카드 후보로 남긴다, 운영자 결정 2026-10-11). 가는 편은 하한(시작 − 여유 − 리드,
    /// 이동시간 미지), 돌아오는 편은 여유 0(Store.swift:229-230). 시각이 아직 없으면 그 구간의
    /// 약속은 아무것도 못 한다(거짓).
    static func activityPastAlarm(hasPlace: Bool, hasOutbound: Bool, hasReturn: Bool,
                                  start: Date?, end: Date?, bufferMinutes: Int, leadMinutes: Int,
                                  wants: Bool, now: Date) -> (outbound: Bool, returnLeg: Bool) {
        let outboundPast = hasPlace && hasOutbound && wants
            && start.map { alarmTime(departure: $0, leadMinutes: bufferMinutes + leadMinutes) <= now } == true
        let returnPast = hasPlace && hasReturn && wants
            && end.map { alarmTime(departure: $0, leadMinutes: leadMinutes) <= now } == true
        return (outboundPast, returnPast)
    }

    /// 활동 폼의 과거 알림 노트(D-6) — AddEventView:617과 글자까지 같되 앞 공백이 없다. 저쪽은
    /// `note +=`로 이어 붙이고 활동 폼은 줄의 단독 노트로 쓰기 때문이다.
    static let activityPastAlarmNote = "The alert time has already passed, so no departure alert will be scheduled."
}
