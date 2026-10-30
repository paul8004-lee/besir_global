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
                await store.backgroundRefresh()
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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let n = NotificationManager()
        let s = Store(notifications: n)
        let loc = LocationManager()
        _notifications = StateObject(wrappedValue: n)
        _store = StateObject(wrappedValue: s)
        _location = StateObject(wrappedValue: loc)
        #if os(iOS)
        // 백그라운드 태스크 등록은 앱 실행이 끝나기 전에 해야 한다 — 그래서 여기(App.init)다.
        BackgroundSync.register(store: s)
        // Attach the Apple Calendar mirror before any save of this run, so the baseline is taken first.
        s.attachCalendar(AppleCalendarMirror(backend: EventKitBackend(), linksURL: AppleCalendarMirror.defaultLinksURL))
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(location)
                .environmentObject(notifications)
                // 기본 컨트롤(버튼·토글·피커·링크)이 시스템 파랑/초록 대신 앱 색을 쓰게 한다 —
                // 화면마다 파랑 링크와 초록 토글이 섞여 톤이 제각각으로 보이던 원인.
                .tint(Theme.travel)
                // Keep DatePicker and other locale-aware controls in English whatever the device language is.
                .environment(\.locale, Locale(identifier: "en_US"))
                // 글자 크기는 besir가 고정한다(기기 설정을 따르지 않음) — 레이아웃 여백을 일정하게 유지.
                .environment(\.dynamicTypeSize, .xLarge)
                .onAppear {
                    notifications.bootstrap()
                    location.useCurrentLocation()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        location.setForeground(true)
                        // 권한은 설정 앱에서 언제 바뀔지 모르니 활성화마다 다시 읽는다 — 느린
                        // 캘린더 동기화를 기다리면 그동안 캡션이 낡은 권한으로 남는다.
                        notifications.refreshPermissionStatus()
                        notifications.clearShareNudge()
                        // A calendar permission changed in Settings takes effect: hand the list over again.
                        store.reconcileCalendar()
                        Task {
                            // The one app-open sequence: legs, live check of imminent events, alert reschedule, after-alert checks.
                            await store.runAppOpenPass()
                        }
                    } else if phase == .background {
                        location.setForeground(false)
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
}
