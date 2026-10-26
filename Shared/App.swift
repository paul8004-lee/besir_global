import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

#if os(iOS)
/// 앱이 포그라운드에 없을 때도 클라우드 동기화 주기가 돌도록 iOS에 백그라운드 실행을 요청한다.
///
/// **iOS는 앱이 원하는 때에 백그라운드에서 도는 걸 허용하지 않는다.** BGTaskScheduler에 "이 시각
/// 이후 아무 때나 잠깐 깨워달라"고 예약만 해두면, 실제 실행 시점은 iOS가 배터리·네트워크·평소
/// 사용 패턴을 보고 스스로 정한다(수십 분 뒤일 수도, 몇 시간 뒤일 수도 있고 보장되지 않는다).
/// 사용자가 앱 전환기에서 위로 밀어 강제 종료하면 iOS는 그 앱의 백그라운드 태스크를 아예 실행하지
/// 않는다 — 그 경우엔 다음에 앱을 열 때 동기화된다.
enum BackgroundSync {
    /// Info.plist의 `BGTaskSchedulerPermittedIdentifiers`에 같은 값이 있어야 등록이 된다.
    static let taskIdentifier = "com.iseongmin.besir.sync"

    /// 앱 실행 아주 초기(App.init)에 한 번만 호출해야 한다 — 등록되기 전에 iOS가 태스크를 던지면 크래시한다.
    static func register(store: Store) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            // 예약은 한 번 실행되면 소모된다 — 다음 회차를 먼저 잡아둬야 계속 이어진다.
            schedule()
            let work = Task { @MainActor in
                // 걸려 있음의 판정은 `CloudSync.isEngaged` 하나다. 걸려 있지 않은(로그인한 적 없는) 기기는
                // 주기를 돌리지 않는다 — 돌리면 세션 없음이 "로그인 만료" 실패로 화면에 남는다.
                if CloudSync.isEngaged {
                    await CloudSync.runCycle(store, origin: .background)
                }
                await store.refreshUpcomingEstimates()
                store.rescheduleNearestNotifications()
            }
            // 주어진 시간을 다 쓰면 iOS가 여기를 부른다. 정리하지 않으면 앱이 강제 종료된다.
            task.expirationHandler = { work.cancel() }
            Task {
                await work.value   // 완료됐든 취소됐든 종료 보고는 여기 한 곳에서만 한다.
                task.setTaskCompleted(success: true)
            }
        }
        schedule()
    }

    /// 다음 백그라운드 동기화를 예약한다.
    /// `earliestBeginDate`는 "이 시각 전에는 실행하지 말라"는 하한일 뿐, 주기를 보장하지 않는다.
    static func schedule(after minutes: Int = 30) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Double(minutes) * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif

@main
struct BesirApp: App {
    // 아래 init()에서 서로를 참조하는 순서로 한꺼번에 만들어 주입한다(기본값을 두면 그 인스턴스가
    // 만들어졌다가 그대로 버려진다).
    @StateObject private var notifications: NotificationManager
    @StateObject private var store: Store
    @StateObject private var location: LocationManager
    @StateObject private var assistant: AIAssistant
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let n = NotificationManager()
        let s = Store(notifications: n)
        let loc = LocationManager()
        _notifications = StateObject(wrappedValue: n)
        _store = StateObject(wrappedValue: s)
        _location = StateObject(wrappedValue: loc)
        _assistant = StateObject(wrappedValue: AIAssistant(store: s, location: loc))
        // besir 계정 항목은 기기 전용으로 올린다 — 백업 복원 뒤 새 폰이 옛 폰의 세션·기기 id를 물려받지 않게.
        CloudAccount.prepareForBackgroundAccess()
        #if os(iOS)
        // 백그라운드 태스크 등록은 앱 실행이 끝나기 전에 해야 한다 — 그래서 여기(App.init)다.
        BackgroundSync.register(store: s)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(location)
                .environmentObject(notifications)
                .environmentObject(assistant)
                // 기본 컨트롤(버튼·토글·피커·링크)이 시스템 파랑/초록 대신 앱 색을 쓰게 한다 —
                // 화면마다 파랑 링크와 초록 토글이 섞여 톤이 제각각으로 보이던 원인.
                .tint(Theme.travel)
                // DatePicker가 "Sep 11, 2026"처럼 영문으로 나오던 것을 한국어로 맞춘다.
                .environment(\.locale, Locale(identifier: "ko_KR"))
                // 글자 크기는 besir가 고정한다(기기 설정을 따르지 않음) — 레이아웃 여백을 일정하게 유지.
                .environment(\.dynamicTypeSize, .xLarge)
                .onAppear {
                    notifications.bootstrap()
                    location.useCurrentLocation()
                    LocalMapServer.shared.start(jsKey: store.config.kakaoJsKey)
                }
                .onChange(of: scenePhase) { _, phase in
                    // 앱이 활성화될 때마다 클라우드 동기화 주기를 돈다(다른 기기 변경 반영)
                    // + 공유 확장(Share Extension)이 남긴 공유 항목을 처리한다.
                    if phase == .active {
                        // 권한은 설정 앱에서 언제 바뀔지 모르니 활성화마다 다시 읽는다 — 느린
                        // 캘린더 동기화를 기다리면 그동안 캡션이 낡은 권한으로 남는다.
                        notifications.refreshPermissionStatus()
                        // 계정 세션 확인은 동기화 Task와 따로 돌린다 — 느린 동기화가 끝나길 기다리면
                        // 다른 기기에서 계정을 지운 뒤에도 그만큼 로그인 상태로 보인다.
                        // 확인 전에 계정 id가 없었다가 확인이 되살린 경우에만 주기를 한 번 더 돈다(Keychain에 토큰만 남았던 채로 뜬 앱).
                        Task {
                            let hadAccountId = store.cloudAccount.userId != nil
                            await store.cloudService.refresh()
                            await CloudSync.continueAfterSessionCheck(store, hadAccountId: hadAccountId)
                        }
                        // 구글 연결 상태는 활성화마다 한 번만 읽는다(주 1회 만료를 앞으로 올 때 알아채려고). 세션 확인·동기화와
                        // 따로 돌려 서로를 기다리지 않게 하고, 세션이 없으면 읽기 쪽에서 아무것도 하지 않는다.
                        Task { await store.cloudService.refreshGoogleStatus() }
                        Task {
                            // 걸려 있지 않은 기기는 주기를 돌리지 않는다(백그라운드 트리거와 같은 이유).
                            if CloudSync.isEngaged {
                                await CloudSync.runCycle(store, origin: .foreground)
                            }
                            await processSharedInbox()
                            // 출발이 임박한 일정은 실시간 교통상황으로 이동시간을 다시 계산.
                            await store.refreshUpcomingEstimates()
                            // iOS의 64건 제한 때문에 알림은 "가까운 것부터"만 실제로 예약해두고,
                            // 앱을 열 때마다 지나간 만큼 뒤쪽 회차를 채워 넣는다.
                            store.rescheduleNearestNotifications()
                        }
                    } else if phase == .background {
                        #if os(iOS)
                        // 백그라운드로 갈 때마다 다음 동기화를 예약해둔다(실행 시점은 iOS가 정함).
                        BackgroundSync.schedule()
                        #endif
                    }
                }
                #if os(macOS)
                .frame(minWidth: 1000, minHeight: 680)
                #endif
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }

    /// 공유 확장(ShareExtension)이 앱 그룹에 남긴 공유 항목을 꺼내 AI 파싱기로 넘긴다.
    @MainActor
    private func processSharedInbox() async {
        let items = SharedInbox.drain()
        guard !items.isEmpty else { return }
        for item in items {
            let imageData = item.imageBase64.flatMap { Data(base64Encoded: $0) }
            await assistant.handleShared(text: item.text, imageData: imageData, mimeType: item.mimeType)
        }
    }
}
