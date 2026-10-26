import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var autoAdd = true

    @State private var showingWipe = false

    // 즐겨찾기는 추가·삭제가 즉시 저장되고, 기본 설정은 아래 저장 단추를 눌러야 반영된다 —
    // 두 저장 문법이 섞이면 "저장을 안 눌렀는데 바뀌었네"가 생기므로 탭으로 가른다(REQ-003).
    private enum SettingsTab: Hashable {
        case basic
        case favorites
    }

    @State private var tab: SettingsTab = .basic

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("설정").font(.title2).bold()

            Picker("설정 종류", selection: $tab) {
                Text("기본 설정").tag(SettingsTab.basic)
                Text("즐겨찾기").tag(SettingsTab.favorites)
            }
            .pickerStyle(.segmented)

            switch tab {
            case .basic: basicTab
            case .favorites: favoritesTab
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 460)
        .frame(minHeight: 260)
        #endif
        .onAppear {
            autoAdd = store.config.autoAddToCalendar
        }
    }

    /// 기본 설정 탭 — 탭으로 나누기 전의 설정 본문 그대로. 저장/취소 줄은 이 탭에만 있다.
    private var basicTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 계정 서버는 프록시 위에서만 돈다 — 프록시 없는 빌드에 누를 수 없는 로그인 버튼을 두지 않는다.
            if store.config.hasProxy {
                CloudAccountSection(cloud: store.cloudService)
                Divider().overlay(Theme.line)
                // 구글 연결은 besir 세션으로 서버에 묻는 일이라 로그인한 동안만 둔다. 401 뒤(걸려 있지만 세션
                // 없음)에도 숨는다 — 그때 할 일은 다시 로그인이고, 그 안내는 위 계정 구역이 맡는다(D15).
                if store.cloudAccount.userId != nil {
                    GoogleCalendarSection(cloud: store.cloudService, autoAdd: $autoAdd)
                    Divider().overlay(Theme.line)
                }
            }

            // ⚠️ 테스트용 임시 버튼 — 출시 전에 이 블록과 Store.deleteEverythingForTesting을 같이 뺀다.
            VStack(alignment: .leading, spacing: 6) {
                Text("테스트").font(.headline)
                Button(role: .destructive) {
                    showingWipe = true
                } label: {
                    Label("일정 모두 삭제", systemImage: "trash")
                }
            }
            .confirmationDialog("등록된 일정·활동·식사 기록을 모두 지울까요?",
                                isPresented: $showingWipe, titleVisibility: .visible) {
                Button("모두 삭제", role: .destructive) { store.deleteEverythingForTesting() }
                Button("취소", role: .cancel) {}
            }

            Spacer()
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("저장") {
                    var c = store.config
                    c.autoAddToCalendar = autoAdd
                    store.updateConfig(c)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// 즐겨찾기 탭 — 추가·삭제는 즉시 저장이라 저장/취소 줄이 없다. 목록이 화면보다 길어질 수
    /// 있어 스크롤로 싼다(기본 설정 탭은 줄 수가 정해져 있어 그대로 둔다).
    private var favoritesTab: some View {
        ScrollView {
            FavoritesList()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "besir 계정" 구역. 진행 중 표시와 문구는 `CloudAccount`가 들고 있는데 `Store`가 그 객체를
/// `@Published`로 내보내지 않으므로, 부모 본문에서 읽으면 바뀌어도 다시 그려지지 않는다 — 그래서
/// 이 구역만 따로 떼어 서비스를 직접 관찰한다.
private struct CloudAccountSection: View {
    @EnvironmentObject var store: Store
    @ObservedObject var cloud: CloudAccount

    @State private var showingDelete = false
    @State private var showingSignOut = false
    @State private var showingRedownload = false
    // 확인창의 N은 누른 순간의 값으로 묶어 둔다 — 창이 떠 있는 동안 주기가 돌아 수가 바뀌면, 읽은 문구와
    // 실제로 버려지는 수가 달라 보인다.
    @State private var signOutUnsent = 0
    @State private var redownloadDiscard = 0

    init(cloud: CloudAccount) { self.cloud = cloud }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("besir 계정").font(.headline)

            switch store.cloudAccount {
            case .signedOut:
                Button {
                    Task { await cloud.signInWithGoogle() }
                } label: {
                    Label(cloud.isWorking ? "로그인 중…" : "Google로 로그인", systemImage: "person.crop.circle")
                }
                .disabled(cloud.isWorking)
                // 로그인하면 일정 내용이 서버로 간다 — 무엇이 올라가는지를 누르기 전에 읽게 한다. 경고가 아니라
                // 고지라 가장 옅은 글자색.
                Text("Google로 로그인하면 일정 제목, 장소(이름·주소·좌표), 식사 기록, 즐겨찾기가 besir 서버에 저장돼요.")
                    .font(.caption).foregroundStyle(Theme.faint)
            case let .signedIn(provider, _):
                // 계정 id는 사용자가 읽을 값이 아니라 동기화가 쓰는 열쇠라 화면에 내지 않는다.
                Label(provider == "google" ? "Google 계정으로 로그인됨" : "besir 계정으로 로그인됨",
                      systemImage: "checkmark.circle.fill")
                    // 로그인됨은 성공·등록 상태 — 구글 연결 줄과 같은 세이지.
                    .foregroundStyle(Theme.travel).font(.callout)
                HStack(spacing: 16) {
                    // 로그아웃은 보내지 못한 대기열을 버린다(일정 자체는 기기에 남는다). 버릴 것이 있을 때만 묻고,
                    // 없으면 지금처럼 바로 나간다 — 잃을 것이 없는데 묻는 창은 습관적으로 넘기게 만든다.
                    Button("로그아웃") {
                        let unsent = CloudSync.unsentCount(store)
                        if unsent > 0 {
                            signOutUnsent = unsent
                            showingSignOut = true
                        } else {
                            Task { await cloud.signOut() }
                        }
                    }
                    Button("계정 삭제", role: .destructive) { showingDelete = true }
                        .foregroundStyle(Theme.warn)
                }
                .disabled(cloud.isWorking)
                // 계정 삭제 창과 같은 이유로 알림창 — 시트 위에서도 취소가 보인다.
                .alert("로그아웃할까요?", isPresented: $showingSignOut) {
                    Button("로그아웃", role: .destructive) { Task { await cloud.signOut() } }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("보내지 못한 변경 \(signOutUnsent)건은 이 기기에만 남아요.")
                }
            }

            // 401 뒤에는 계정 상태가 로그아웃이어도 상태 파일이 대기열을 쥐고 있다 — 그때 "만료" 줄이 사라지면
            // 사용자는 왜 다시 로그인해야 하는지 모른다. 걸려 있음의 판정은 `isEngaged` 하나만 읽는다(베끼지 않음).
            if store.cloudAccount.userId != nil || CloudSync.isEngaged {
                syncStatus
            }

            // 세 문구 모두 실패 안내라 경고색 하나로 충분하다. 구글 연결 문구도 같은 자리에 담기지만 그 묶음
            // 아래에서 보여 준다 — 여기서도 그리면 같은 문장이 두 번 보이고, 계정 실패처럼 읽힌다.
            if let message = cloud.message, !GoogleCalendarSection.ownsMessage(message) {
                Text(message).font(.caption).foregroundStyle(Theme.warn)
            }
        }
        // 문구를 쥔 서비스는 Store가 앱 수명 동안 들고 있어, 지우지 않으면 지난 실패 안내가 설정을 다시
        // 열 때마다 새 실패처럼 보인다.
        .onAppear { cloud.clearMessage() }
        // 확인창이 떠 있는 동안 세션이 무효로 지워지면(다른 기기에서 계정 삭제) 창이 남아, 거기서 누른
        // "삭제"가 세션 없음으로 아무 말 없이 끝난다. 상태가 바뀌면 창을 닫는다.
        .onChange(of: store.cloudAccount) { _, state in
            if state == .signedOut {
                showingDelete = false
                showingSignOut = false
                showingRedownload = false
            }
        }
        // 설정이 시트로 떠 있어 액션 시트의 '취소' 버튼이 보이지 않았다 — 알림창은 취소를 항상 그린다.
        .alert("계정을 삭제할까요?", isPresented: $showingDelete) {
            Button("삭제", role: .destructive) { Task { await cloud.deleteAccount() } }
            Button("취소", role: .cancel) {}
        } message: {
            // 구글 문장은 연결 상태를 보지 않고 늘 넣는다(운영자 "그냥 항상 보이게") — 연결한 적
            // 없는 사람에게도 지워진다고 먼저 읽히는 쪽이, 삭제 뒤에야 알게 되는 쪽보다 안전하다.
            Text("besir 서버의 계정과 저장된 일정·장소·식사 기록·즐겨찾기가 지워져요. 구글 캘린더의 'besir' 캘린더도 함께 지워져요. 되돌릴 수 없어요. 이 기기의 일정은 그대로 남아요.")
        }
    }

    /// 동기화 상태 묶음. 본문 줄은 하나만 고른다 — 여러 상태가 겹칠 때 줄을 다 늘어놓으면 무엇을 해야 하는지가
    /// 묻힌다. 위에 있는 조건이 이긴다: 최초 연결 중엔 고치지 말라는 안내가, 읽지 못한 파일은 다른 무엇보다
    /// 먼저 풀어야 동기화가 다시 돌므로 그다음이다.
    @ViewBuilder private var syncStatus: some View {
        let sync = store.cloudSync
        VStack(alignment: .leading, spacing: 6) {
            if sync.firstSyncInProgress {
                Text("처음 동기화하는 중… 끝날 때까지 일정을 고치지 말아 주세요.")
                    .font(.caption).foregroundStyle(Theme.muted)
            } else if !sync.unreadableKinds.isEmpty {
                Text("이 기기의 \(Self.kindNames(sync.unreadableKinds)) 파일을 읽지 못해 동기화를 멈췄어요.")
                    .font(.caption).foregroundStyle(Theme.warn)
                Button("클라우드에서 다시 받기") {
                    let discard = CloudSync.redownloadDiscardCount(store)
                    if discard > 0 {
                        redownloadDiscard = discard
                        showingRedownload = true
                    } else {
                        Task { await CloudSync.redownloadFromCloud(store) }
                    }
                }
                .disabled(sync.isRunning)
            } else {
                if sync.isRunning {
                    Text("동기화 중…").font(.caption).foregroundStyle(Theme.muted)
                } else if let failure = sync.failure {
                    Text(Self.failureText(failure, pending: sync.pendingCount))
                        .font(.caption).foregroundStyle(Theme.warn)
                    // 줄 하나만 고르는 원칙의 예외: 연결이 끊긴 때가 바로 남은 변경 수가 궁금한 때인데, 실패 줄이
                    // 본문 자리를 이겨 대기 수가 사라졌다(S4-B). 실패 줄 바로 아래 옅게 덧붙여 행동(버튼)보다 먼저 읽힌다.
                    if Self.showsPendingUnderFailure(failure) && sync.pendingCount > 0 {
                        Text(Self.pendingText(sync.pendingCount, lastSuccessAt: sync.lastSuccessAt))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                } else if sync.pendingCount > 0 {
                    Text(Self.pendingText(sync.pendingCount, lastSuccessAt: sync.lastSuccessAt))
                        .font(.caption).foregroundStyle(Theme.muted)
                } else if let last = sync.lastSuccessAt {
                    // 상태가 바뀌지 않아도 "방금 전"이 몇 분 뒤 그대로 남지 않게 30초마다 다시 그린다.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("동기화됨 · \(Self.relativeTime(last, now: context.date))")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                if sync.quarantinedCount > 0 {
                    Text("서버가 받지 않은 변경 \(sync.quarantinedCount)건이 있어요.")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
                // 실패 줄과 격리 줄이 함께 있어도 버튼은 하나다 — `retry`가 격리를 풀고 한 주기를 돌려 둘 다 맡는다.
                if (!sync.isRunning && sync.failure.map(Self.offersRetry) == true) || sync.quarantinedCount > 0 {
                    Button("다시 시도") { Task { await CloudSync.retry(store) } }
                        .disabled(sync.isRunning)
                }
            }
        }
        .alert("클라우드에서 다시 받을까요?", isPresented: $showingRedownload) {
            Button("다시 받기", role: .destructive) { Task { await CloudSync.redownloadFromCloud(store) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("서버가 받지 않은 변경 \(redownloadDiscard)건은 다시 받으면 이 기기 백업에만 남아요.")
        }
    }

    /// 로그인 만료·계정 불일치는 다시 로그인해야 풀리므로 [다시 시도]를 주지 않는다 — 눌러도 같은 자리에서 멈춘다.
    private static func offersRetry(_ failure: CloudSyncFailure) -> Bool {
        switch failure {
        case .loginExpired, .accountMismatch: return false
        case .noResponse, .serverError, .storageWriteFailed, .undecodablePayload: return true
        }
    }

    private static func failureText(_ failure: CloudSyncFailure, pending: Int) -> String {
        switch failure {
        case .loginExpired:
            // 이어서 보낼 것이 없을 때 "0건을 이어서 보내요"는 거짓 약속처럼 읽힌다.
            return pending > 0
                ? "로그인이 만료됐어요. 같은 계정으로 다시 로그인하면 보내지 못한 변경 \(pending)건을 이어서 보내요."
                : "로그인이 만료됐어요. 같은 계정으로 다시 로그인해 주세요."
        case .accountMismatch:
            return "다른 계정의 변경이 남아 있어 동기화를 멈췄어요. 다시 로그인해 주세요."
        case .noResponse:
            return "동기화하지 못했어요. 연결을 확인해 주세요."
        case .serverError, .storageWriteFailed, .undecodablePayload:
            // 디스크 쓰기 실패·디코딩 못 한 항목은 전용 문구가 아직 없다 — 사용자가 할 수 있는 일이 "다시 시도"로
            // 같아서 서버 오류 문구를 함께 쓴다.
            return "동기화하지 못했어요. 잠시 뒤 다시 시도해 주세요."
        }
    }

    /// 실패 줄 아래 대기 수를 덧붙일 실패. 로그인 만료는 문구가 이미 건수를 말하고, 계정 불일치는 다시 로그인해야
    /// 풀려 건수가 할 일을 바꾸지 않으며, 디코딩 못 한 항목은 성공한 주기에도 남는 값이라 대기 수와 무관하다.
    /// switch로 둬서 실패 종류가 늘면 여기서 컴파일러가 결정을 요구한다.
    private static func showsPendingUnderFailure(_ failure: CloudSyncFailure) -> Bool {
        switch failure {
        case .noResponse, .serverError, .storageWriteFailed: return true
        case .loginExpired, .accountMismatch, .undecodablePayload: return false
        }
    }

    /// 대기 줄 문구. 본문 자리와 실패 줄 아래 두 곳이 같은 문장을 써야 해서 한 곳에서 만든다.
    private static func pendingText(_ pending: Int, lastSuccessAt: Date?) -> String {
        "보내지 못한 변경 \(pending)건"
            + (lastSuccessAt.map { " · 마지막 동기화 \(absoluteTime($0))" } ?? "")
    }

    private static func kindNames(_ kinds: [SyncKind]) -> String {
        kinds.map { kind -> String in
            switch kind {
            case .event: return "일정"
            case .activity: return "활동"
            case .meal: return "식사"
            case .favorite: return "즐겨찾기"
            }
        }.joined(separator: "·")
    }

    /// "마지막 동기화" 뒤의 시각. 오늘이면 날짜는 군더더기라 시각만. 구글 반영 시각도 같은 꼴로 읽혀야
    /// 해서 그 묶음이 이 함수를 빌려 쓴다(계약 5 — 시각 문법을 두 벌 두지 않는다).
    fileprivate static func absoluteTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "a h:mm" : "M월 d일 a h:mm"
        return f.string(from: date)
    }

    /// "동기화됨" 뒤의 상대 시각. 1분 안쪽은 "0분 전"보다 "방금 전"이 자연스럽고, 기기 시계가 서버보다
    /// 늦어 미래 시각이 와도 같은 쪽으로 떨어진다.
    private static func relativeTime(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "방금 전" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// "구글 캘린더에 보이기" 구역(SPEC-SYNC-007). 기기는 구글과 말하지 않고, 서버가 구글의 "besir" 캘린더에
/// 일정을 비춰 준다 — 여기서 하는 일은 그 연결을 켜고 끄고 상태를 읽어 보여 주는 것뿐이다. 계정 구역과
/// 같은 이유로(진행 표시·문구가 `Store`가 내보내지 않는 `CloudAccount`에 있다) 서비스를 직접 관찰한다.
private struct GoogleCalendarSection: View {
    @EnvironmentObject var store: Store
    @ObservedObject var cloud: CloudAccount
    /// 기본값 토글은 화면의 저장 버튼이 이 값을 `autoAddToCalendar`로 저장하는 한 길만 쓴다 —
    /// 바꾼 즉시 저장되는 스위치가 아니라는 점은 토글의 힌트가 말한다.
    @Binding var autoAdd: Bool

    @State private var showingUnlink = false

    /// 이 구역이 보여 줄 문구. 문구 칸은 계정 구역과 하나를 같이 쓰므로, 어느 쪽 아래에 그릴지를 문장
    /// 상수로 가른다 — 같은 상수를 `CloudAccount`가 쓰므로 문장이 바뀌어도 어긋나지 않는다.
    static func ownsMessage(_ message: String) -> Bool {
        message == CloudAccount.googleLinkFailedMessage
            || message == CloudAccount.googleUnlinkFailedMessage
            || message == CloudAccount.googleNotRevokedMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("구글 캘린더에 보이기").font(.headline)

            Toggle("새 일정을 구글 캘린더에도 보이기", isOn: $autoAdd)
                .accessibilityHint("새로 만드는 일정의 기본값이에요. 아래 저장을 눌러야 바뀌어요.")

            linkState

            if let message = cloud.message, Self.ownsMessage(message) {
                // 철회 안내는 실패가 아니라 남은 손일이라 옅은 색, 나머지 둘은 실패라 경고색.
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message == CloudAccount.googleNotRevokedMessage ? Theme.muted : Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 설정이 시트로 떠 있어 액션 시트의 '취소'가 보이지 않던 일이 있어(계정 삭제 창과 같은 이유) 알림창으로
        // 묻는다. 첫 버튼에 기본 동작 단축키를 달아 그 버튼을 알림창의 기본(굵게) 버튼으로 둔다 — 되돌릴 수 있는
        // 쪽이 기본이어야 습관적으로 누른 손이 구글 캘린더를 지우지 않는다(D3).
        .alert("구글 캘린더 연결을 끊을까요?", isPresented: $showingUnlink) {
            Button("연결만 끊기") { Task { await cloud.unlinkGoogleCalendar(deleteCalendar: false) } }
                .keyboardShortcut(.defaultAction)
            Button("구글의 besir 캘린더도 지우기", role: .destructive) {
                Task { await cloud.unlinkGoogleCalendar(deleteCalendar: true) }
            }
            Button("취소", role: .cancel) {}
        }
    }

    /// 연결 상태 줄. 상태마다 한 줄과 할 수 있는 일만 둔다. 다시 연결(주 1회 만료, D12)은 정상 일과라
    /// 경고 아이콘·대화상자 없이 보통 글자색으로 말한다.
    @ViewBuilder private var linkState: some View {
        switch store.googleLink {
        case .none:
            Button {
                Task { await cloud.linkGoogleCalendar() }
            } label: {
                Label(cloud.isWorking ? "연결 중…" : "구글 캘린더 연결", systemImage: "calendar.badge.plus")
            }
            .disabled(cloud.isWorking)
        case .linked:
            // 연결됨은 성공 상태 — 계정 구역의 "로그인됨"과 같은 세이지, 뜻은 글자가 말한다.
            Label(linkedLine, systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(Theme.travel)
            if store.googleFailedCount > 0 {
                Label("구글이 거절한 일정 \(store.googleFailedCount)건", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Theme.warn)
            }
            unlinkButton
        case .needsReauth:
            Text("구글 연결이 만료됐어요. 다시 연결해 주세요.")
                .font(.callout).foregroundStyle(Theme.ink)
            HStack(spacing: 16) {
                Button("다시 연결") { Task { await cloud.linkGoogleCalendar() } }
                    .disabled(cloud.isWorking)
                unlinkButton
            }
        case .paused:
            Text("구글 캘린더 반영이 일시 중지됐어요.")
                .font(.callout).foregroundStyle(Theme.muted)
            // 일시 중지는 서버의 비상 스위치라 사용자 해제는 막지 않는다(서버도 200으로 받는다).
            unlinkButton
        }
    }

    private var unlinkButton: some View {
        Button("연결 끊기", role: .destructive) { showingUnlink = true }
            .foregroundStyle(Theme.warn)
            .disabled(cloud.isWorking)
    }

    /// "구글 캘린더 · 연결됨 · 오전 9:12 반영". 아직 반영한 적이 없으면 시각을 지어내지 않고 뺀다.
    private var linkedLine: String {
        "구글 캘린더 · 연결됨"
            + (store.googleLastSuccess.map { " · \(CloudAccountSection.absoluteTime($0)) 반영" } ?? "")
    }
}
