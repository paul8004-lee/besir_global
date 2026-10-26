import SwiftUI
import CoreLocation

struct EventDetailView: View {
    /// 푸시 시점에 전달된 값(폴백). 실제로는 store에서 최신 값을 읽는다.
    private let passedEvent: ScheduledEvent
    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationManager
    /// 알림 권한이 바뀌면 캡션이 즉시 재판정되게 하는 관찰 경로(Store.notifications는 let이라
    /// 그 경로로는 재렌더가 일어나지 않는다).
    @EnvironmentObject var notifications: NotificationManager

    init(event: ScheduledEvent) { self.passedEvent = event }

    /// 항상 store의 최신 일정을 사용한다. (편집으로 수단 등을 바꿔도 즉시 반영)
    private var event: ScheduledEvent {
        store.events.first { $0.id == passedEvent.id } ?? passedEvent
    }

    /// 경로 안내 단계 옆에 붙는 짧은 시각("오후 3:05").
    private static let shortTimeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"; return f
    }()

    @Environment(\.dismiss) private var dismiss

    @State private var routeSegments: [RouteSegment] = []
    @State private var transitSteps: [TransitStep] = []
    /// 단계 분 합으로 설명되지 않는 "그 외" 분(첫·끝 도보·대기). 값은 변환 함수가 정하고(N ≥ 1일 때만)
    /// 화면은 그리기만 한다 — 여기서 다시 빼면 같은 계산이 두 곳에 생긴다(계약 5).
    @State private var transitExtraMinutes: Int?
    /// 끝난 환승 조회가 빈 이유(D10). 조회 중에는 nil이라 실패 줄이 로딩 사이에 깜빡이지 않는다.
    @State private var transitFailure: TravelFailure?
    @State private var showingEdit = false
    @State private var showingDeleteMenu = false
    @State private var showingDeleteConfirm = false
    /// 항목 스위치 저장이 도는 동안 같은 스위치를 다시 눌러 고침이 겹치지 않게 막는다.
    @State private var savingCalendarSync = false
    /// 지금 떠 있는 경로 조회. 출발지 좌표가 GPS 정밀화로 계속 미세하게 바뀌면 키가 다시
    /// 불리고, 취소 없이 두면 조회가 한 벌씩 쌓여 카카오 할당량이 타며(t11 sync N5),
    /// 취소된 조회는 서비스의 catch가 값 없는 결과로 바꿔 정상 반환처럼 돌아오기 때문에 늦은 옛
    /// 결과가 새 결과를 덮는다.
    @State private var transitTask: Task<Void, Never>?

    /// 38pt 고정은 큰 글씨를 무시한다(D-4 9번) — 출발 숫자가 본문과 함께 자라게 한다.
    @ScaledMetric(relativeTo: .largeTitle) private var departureTimeSize: CGFloat = 38

    private var destCoord: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: event.destination.latitude, longitude: event.destination.longitude)
    }

    /// 이 일정의 출발지 좌표(저장된 출발지 우선, 없으면 현재 위치).
    private var originCoord: CLLocationCoordinate2D? {
        if let o = event.origin {
            return CLLocationCoordinate2D(latitude: o.latitude, longitude: o.longitude)
        }
        return location.originCoordinate
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                mapView
                    .frame(height: 280)
                    // 지도 클립은 크롬이 아니라 콘텐츠 경계다 — Theme.radius(3)를 얹으면 280pt
                    // 이미지가 사각형과 구분되지 않는다(D-4 2번 유지 판정).
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("\(event.destination.name) 지도")

                departureCard

                transitItinerary

                calendarButton

                detailRows
            }
            .padding(24)
        }
        .background(Theme.bg)
        .navigationTitle(event.title)
        // 처음 표시 + 일정의 수단·출발지·목적지가 바뀔 때마다 경로 재로딩. 이전 조회는 취소하고
        // 새로 띄운다(LocationManager.startTimeout과 같은 취소-교체) — 취소는 URLSession의 진행
        // 중 요청까지 끊어, 바뀌어버린 옛 조회를 끝까지 태우지 않는다.
        .onChange(of: transitTaskKey, initial: true) {
            transitTask?.cancel()
            transitTask = Task { await loadTransitPath() }
        }
        // 사라진 화면의 결과를 위해 네트워크를 태우지 않는다(AddEventView의 정리 계약과 같은
        // 판단) — 상세를 닫아도 진행 중인 조회는 계속 도는 게 지금까지의 모습이었다.
        .onDisappear { transitTask?.cancel() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingEdit = true } label: { Label("편집", systemImage: "pencil") }
            }
        }
        .sheet(isPresented: $showingEdit) {
            // 연결된 구간의 편집은 활동 카드로 간다(REQ-001·006) — 시간을 고치면 활동과 분리되던
            // 창이 나오지 않게 한다. 활동이 없으면(단독 구간·매달린 링크) 지금처럼 이동 일정 폼.
            if let linked = store.activity(forLeg: event) {
                ActivityDetailView(activityId: linked.id)
            } else {
                AddEventView(editing: event)
            }
        }
    }

    /// 일정의 이동수단·출발지·목적지가 바뀌면 경로를 다시 불러오기 위한 키.
    /// 수단(mode)을 포함해야 편집으로 수단을 바꿨을 때 즉시 경로가 갱신된다.
    private var transitTaskKey: String {
        let o = originCoord
        return "\(event.id)-\(event.mode.rawValue)-\(o?.latitude ?? 0),\(o?.longitude ?? 0)-\(destCoord.latitude),\(destCoord.longitude)"
    }

    @ViewBuilder
    private var mapView: some View {
        if store.config.hasKakaoJs {
            KakaoMapView(jsKey: store.config.kakaoJsKey,
                         origin: originCoord,
                         destination: destCoord,
                         destinationName: event.destination.name,
                         mode: event.mode,
                         segments: routeSegments)
        } else {
            RouteMapView(origin: originCoord,
                         destination: destCoord,
                         destinationName: event.destination.name)
        }
    }

    /// 기기는 구글과 말하지 않고 서버가 대신 반영하므로(D15), 여기 둘 것은 항목 스위치뿐이다 —
    /// 서버 연결이 `linked`일 때만 보인다(REQ-005). 연결이 없으면 아무것도 그리지 않는다:
    /// 스위치를 꺼도 효과가 없고, 안내할 기기 쪽 연결 길도 이제 없다. 로그인한 적 없는 기기는
    /// 걸려 있음 자체가 없으므로 묶음째 `isEngaged` 아래에 둔다.
    @ViewBuilder
    private var calendarButton: some View {
        if CloudSync.isEngaged {
            // 출발지 없는 옛 일정은 일반 고침 경로가 출발지를 요구해 값을 보존한 채 저장할 수 없다 —
            // 눌러도 저장되지 않는 스위치를 두느니 편집에서 출발지를 정한 뒤에 보이게 한다.
            if store.googleLink == .linked, event.origin != nil {
                Toggle("구글 캘린더에 보이기", isOn: calendarSyncBinding)
                    .font(.callout)
                    .disabled(savingCalendarSync)
                    .accessibilityHint("끄면 구글의 besir 캘린더에서 이 일정이 빠져요.")
            }
        }
    }

    /// 스위치는 저장된 값을 그대로 비춘다 — 화면 상태를 따로 두면 동기화로 값이 바뀌었을 때 둘이 어긋난다.
    private var calendarSyncBinding: Binding<Bool> {
        Binding(get: { event.wantsCalendarSync },
                set: { on in Task { await setCalendarSync(on) } })
    }

    /// 항목 스위치의 저장. 일반 고침(`updateEvent`) 한 길로 보내 저장·동기화 대기열이 다른 고침과 같게 돈다.
    /// 나머지 필드는 지금 값 그대로 넘기고, 이동시간은 저장된 값을 힌트로 줘 스위치 하나에 길찾기를 다시
    /// 부르지 않는다(modifyEvent가 앵커 시각을 고르는 것과 같은 식).
    private func setCalendarSync(_ on: Bool) async {
        let id = event.id
        // 값은 누른 순간 store에서 id로 다시 읽는다 — 화면이 들고 있던 사본이나 배열 위치를 믿지 않는다.
        guard let current = store.events.first(where: { $0.id == id }),
              current.wantsCalendarSync != on,
              let origin = current.origin else { return }
        savingCalendarSync = true
        defer { savingCalendarSync = false }
        await store.updateEvent(id: id,
                                title: current.title,
                                origin: origin,
                                destination: current.destination,
                                arrivalDate: current.anchorDate,
                                mode: current.mode,
                                bufferMinutes: current.bufferMinutes,
                                notifyLeadMinutes: current.notifyLeadMinutes,
                                anchor: current.anchor ?? .arrival,
                                travelSecondsHint: current.travelSeconds,
                                syncToCalendar: on)
    }

    private func loadTransitPath() async {
        routeSegments = []
        transitSteps = []
        transitExtraMinutes = nil
        transitFailure = nil
        guard let origin = originCoord else { return }
        switch event.mode {
        case .transit:
            // 프록시 유무는 여기서 가르지 않는다 — 서비스가 네트워크 없이 `.notConfigured`를 돌려주므로
            // 가드를 두면 '설정 필요'가 이 화면에 닿지 않고 안내 블록이 말없이 사라진다(REQ-020).
            let plan = await store.directions.transitPlan(from: origin, to: destCoord)
            // 취소된 조회는 에러가 아니라 빈 결과로 돌아온다(서비스의 catch가 값 없음으로 바꾼다) — await 뒤
            // 재확인 없이 쓰면 옛 조회의 빈 결과가 새 조회의 결과를 덮는다(setLookup과 같은 규율).
            guard !Task.isCancelled else { return }
            routeSegments = plan.segments
            transitSteps = plan.steps
            transitExtraMinutes = plan.extraMinutes
            transitFailure = plan.failure
        case .car:
            let segments = await store.directions.carRouteSegments(from: origin, to: destCoord)
            guard !Task.isCancelled else { return }
            routeSegments = segments
        case .walk:
            let segments = await store.directions.walkRouteSegments(from: origin, to: destCoord)
            guard !Task.isCancelled else { return }
            routeSegments = segments
        case .bicycle:
            let segments = await store.directions.bicycleRouteSegments(from: origin, to: destCoord)
            guard !Task.isCancelled else { return }
            routeSegments = segments
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(event.destination.name, systemImage: "flag.fill")
                .font(.title2).bold()
            if !event.destination.address.isEmpty {
                Text(event.destination.address).foregroundStyle(Theme.muted)
            }
            Label("도착 \(BesirTime.full.string(from: event.arrivalDate))", systemImage: "clock")
                .font(.callout).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder
    private var departureCard: some View {
        if let dep = event.departureDate, let travel = event.travelSeconds {
            let minutes = roundedMinutes(fromSeconds: travel)
            let isPast = dep < Date()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: event.mode.systemImage)
                    // "대중교통로"가 되지 않게 조사 붙은 이름을 쓴다(D14) — 캘린더 설명과 같은 출처.
                    Text("\(event.mode.titleWithParticle) 약 \(minutes)분")
                        .font(.headline)
                    Spacer()
                }
                Divider()
                Group {
                    HStack(alignment: .firstTextBaseline) {
                        Text("출발 시각")
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Text(BesirTime.clock.string(from: dep))
                            .font(.system(size: departureTimeSize, weight: .bold, design: .rounded))
                            .foregroundStyle(isPast ? Theme.nowLine : Theme.travel)
                    }
                    if isPast {
                        Text("⚠️ 이미 출발 시각이 지났습니다.")
                            .font(.caption).foregroundStyle(Theme.warn)
                    } else {
                        // 알림 상태는 사실대로 — 꺼졌거나, 예약돼 있거나, 아니라면 그 이유까지
                        // (판정식은 alarmStatus에). "예약됨"이라고만 쓰면 울리지 않을 약속을
                        // 화면이 한다(D-3).
                        Text("출발까지 \(relativeText(to: dep)) 남음 · \(alarmStatus(for: event, departure: dep))")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                // 시각과 상태 캡션을 한 덩어리로 낭독한다(REQ-023) — 따로 읽히면 "언제"와 "얼마나
                // 남았는지"가 갈라져 한 번에 이해되지 않는다.
                .accessibilityElement(children: .combine)
            }
            .padding(18)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
        } else {
            // 저장된 일정은 이유를 갖고 있지 않다(travelSeconds가 비었다는 사실뿐) — 이유를 지어내지
            // 않고, 이 화면의 환승 조회가 방금 실패했을 때만 그 이유를 빌린다. 그 밖에는 수단을
            // 말하지 않는 고정 문장(예전엔 도보·자동차에도 "대중교통"이라고 했다). 색은 실패의 뜻인
            // warn — activity(브라스)는 활동 블록의 색이라 뜻이 틀렸다(렌즈 F-1).
            Label(transitFailure?.sentence ?? "이동시간을 계산하지 못했어요. 출발지와 도착지를 확인해 주세요.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.warn)
                .padding()
        }
    }

    /// 대중교통 환승 안내: 어떤 노선을 몇 시에 타는지 단계별로 보여준다.
    @ViewBuilder
    private var transitItinerary: some View {
        if event.mode == .transit, !transitSteps.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("이동 경로", systemImage: "arrow.triangle.turn.up.right.diamond")
                        .font(.headline)
                    Spacer()
                    if event.departureDate != nil {
                        Text("예상 시각")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.bottom, 6)

                ForEach(Array(transitSteps.enumerated()), id: \.element.id) { index, step in
                    stepRow(step, at: stepStartTime(index))
                }

                // 남는 시간은 맨 아래에 둔다(D7, 운영자 #10) — 맨 위에 두면 모든 탑승 시각이 N분 늦게
                // 찍혀 열차를 놓치는 쪽으로 틀린다. 시각은 마지막 단계가 끝나는 때(앞선 단계 분 합).
                if let extra = transitExtraMinutes {
                    tailRow("그 외 약 \(extra)분", at: stepStartTime(transitSteps.count)) {
                        Rectangle()
                            .fill(Theme.line)
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                    }
                }
                // 도착은 계산값이 아니라 일정에 적힌 도착 시각이다 — 단계 시각이 어긋나도 약속 시각은
                // 여기서 그대로 보인다.
                tailRow("도착", at: event.arrivalDate) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 26, height: 26)
                }

                // 카카오가 출발 시각을 받는지·시간표 기준인지 확인하지 못했다 — 실시간도 평균도
                // 단정하지 않고 출처만 밝힌다.
                Text("카카오 길찾기 기준 예상 경로예요.")
                    .font(.caption2).foregroundStyle(Theme.faint)
                    .padding(.top, 8)
            }
            .padding(18)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
        } else if event.mode == .transit, let failure = transitFailure,
                  event.departureDate != nil, event.travelSeconds != nil {
            // 안내 블록이 말없이 사라지면 사용자는 경로가 원래 없는 건지 못 불러온 건지 모른다(렌즈
            // C-5). 이유 문장이 아니라 캡션을 쓰는 이유: 문장은 "이동시간을 계산하지 못했어요"로
            // 끝나는데 바로 위 카드에는 저장된 이동시간이 보여 서로 어긋난다. 출발 카드가 대체
            // 라벨일 때(조건은 departureCard와 같다)는 그 라벨이 이미 이유 문장을 말하므로 되풀이하지 않는다.
            Label("경로 안내를 불러오지 못했어요 · \(failure.caption)", systemImage: "info.circle")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    /// 단계 아래에는 늘 "도착" 줄이 오므로 마지막 단계도 레일을 내려 그 줄과 잇는다.
    private func stepRow(_ step: TransitStep, at time: Date?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    // 뱃지 바탕은 API가 준 노선색(콘텐츠)이라 Theme 의미색이 아니다 — 고정 콘텐츠색
                    // 위 글자는 Theme.bg(다크 모드에서 거의 검정)보다 흰 쪽이 두 모드 다 읽힌다.
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color(hex: step.color), in: Circle())
                Rectangle()
                    .fill(Theme.line)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(minHeight: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.headline).font(.callout).bold()
                Text(step.detail).font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(.top, 3)

            Spacer(minLength: 8)

            if let time {
                Text(Self.shortTimeFmt.string(from: time))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 5)
            }
        }
        // 헤드라인과 예상 시각을 함께 읽는다(REQ-023) — 시각만 따로 읽히면 어느 단계의 시각인지
        // 알 수 없다.
        .accessibilityElement(children: .combine)
    }

    /// 단계 뒤 꼬리 줄("그 외"·"도착"). 노선 배지 대신 중립 표지를 두고 글자를 muted로 내려 단계보다
    /// 한 단 낮게 읽히게 한다 — 탈 것이 아니라 안내의 마무리라서다.
    private func tailRow<Lead: View>(_ label: String, at time: Date?,
                                     @ViewBuilder lead: () -> Lead) -> some View {
        HStack(alignment: .top, spacing: 12) {
            lead()
                .frame(width: 26)
                .frame(minHeight: 32)
                .accessibilityHidden(true)

            Text(label)
                .font(.callout).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)

            Spacer(minLength: 8)

            if let time {
                // 큰 글씨에서 시각 열이 말줄임되지 않게 시각은 줄이지 않고 글자 쪽이 줄바꿈한다.
                Text(Self.shortTimeFmt.string(from: time))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                    .padding(.top, 5)
            }
        }
        // 단계 줄과 같은 규칙 — "그 외 약 8분, 오전 9:52"처럼 이름과 시각을 한 번에 읽는다.
        .accessibilityElement(children: .combine)
    }

    /// index번째 단계가 시작되는 예상 시각 = 출발 시각 + 앞선 단계들의 소요시간 합.
    private func stepStartTime(_ index: Int) -> Date? {
        guard let departure = event.departureDate else { return nil }
        let elapsed = transitSteps.prefix(index).reduce(0) { $0 + $1.minutes }
        return departure.addingTimeInterval(Double(elapsed) * 60)
    }

    /// 같은 제목 일괄 삭제의 집합은 Store 조회가 정한다(REQ-013) — 연결된 구간은 활동 삭제의
    /// 연쇄가 지우므로 이 묶음에 속하지 않는다. recurrenceId가 없어도(옛날에 반복 대신 낱개로
    /// 여러 날 따로 만들어진 경우 등) 제목이 완전히 같은 **연결 없는** 일정이 여러 건이면
    /// "일괄 삭제" 대상으로 봐준다 — 하나씩만 지울 수 있어 여러 건을 한 번에 정리할 방법이
    /// 없었기 때문이다.
    private var sameTitleEvents: [ScheduledEvent] {
        store.sameTitleSweep(for: event)
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 값 행(+반복 배지)만 카드로 감싼다 — 삭제 단추는 카드 밖에 그대로 둔다(AC-006
            // 8·9행의 분할이 규범 — REQ-020의 :302-348 인용이 잘못 넓었고 0.1.3으로 정정).
            VStack(alignment: .leading, spacing: 10) {
                row("이동수단", "\(event.mode.title)")
                row("도착 여유(버퍼)", "\(event.bufferMinutes)분")
                // 위 캡션(alarmStatus)은 알림 상태를 사실대로 말하는데 이 행은 무조건 "출발 N분 전"을
                // 그려 "알림 꺼짐" 캡션과 모순됐다 — 끈 일정에는 받지 않음을 보인다.
                row("알림", event.wantsNotification ? "출발 \(event.notifyLeadMinutes)분 전" : "받지 않음")
                if event.recurrenceId != nil {
                    Label("반복 일정", systemImage: "repeat")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding(18)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
            HStack {
                Spacer()
                Button(role: .destructive) {
                    if event.recurrenceId != nil || sameTitleEvents.count > 1 {
                        showingDeleteMenu = true
                    } else {
                        showingDeleteConfirm = true
                    }
                } label: {
                    Label("일정 삭제", systemImage: "trash")
                }
            }
            .padding(.top, 8)
        }
        .confirmationDialog("반복 일정을 어떻게 삭제할까요?", isPresented: $showingDeleteMenu, titleVisibility: .visible) {
            Button(event.recurrenceId != nil ? "전체 반복 일정 삭제" : "같은 제목 일정 모두 삭제(\(sameTitleEvents.count)건)",
                   role: .destructive) {
                if let rid = event.recurrenceId {
                    store.deleteRecurringSeries(rid)
                } else {
                    for e in sameTitleEvents { store.deleteEvent(e) }
                }
                dismiss()
            }
            Button("이 일정만 삭제", role: .destructive) {
                store.deleteEvent(event)
                dismiss()
            }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("이 일정을 삭제할까요?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                store.deleteEvent(event)
                dismiss()
            }
            Button("취소", role: .cancel) {}
        }
    }

    /// 알림 상태 문구 — 화면이 예약 여부를 사실대로 말한다(D-3). 판정·문구는 NotificationManager의
    /// 순수 함수가 단일 출처다: notificationId == nil에는 두 원인이 섞여 있다(과거 시각 거부·64건
    /// 창 밖 대기 — 리스케줄러가 가까운 것만 채운다)며 아이디만으로는 갈라지지 않으므로 알림
    /// 시각·시스템 권한까지 함께 판정한다. 권한은 live 값이라 설정 앱에서 꺼고 돌아오면 재렌더가
    /// 곧바로 참 문구로 바꾼다.
    private func alarmStatus(for event: ScheduledEvent, departure: Date) -> String {
        let verdict = NotificationManager.alarmVerdict(
            wants: event.wantsNotification,
            hasId: event.notificationId != nil,
            departure: departure,
            leadMinutes: event.notifyLeadMinutes,
            permission: notifications.permissionStatus,
            now: Date())
        return NotificationManager.alarmSentence(for: verdict, leadMinutes: event.notifyLeadMinutes,
                                                 variant: .caption)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Theme.muted)
            Spacer()
            Text(v).bold()
        }
        .font(.callout)
    }

    private func relativeText(to date: Date) -> String {
        let secs = Int(date.timeIntervalSinceNow)
        let m = secs / 60
        if m < 60 { return "\(m)분" }
        return "\(m / 60)시간 \(m % 60)분"
    }
}

extension Color {
    /// 노선 색상 문자열("#00A84D")을 Color로. 지도 폴리라인과 같은 값을 공유한다.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(cleaned, radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
