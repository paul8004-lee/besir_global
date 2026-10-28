import SwiftUI
import os
#if os(iOS)
import UIKit
#endif

// 따라가기 도착 스크롤의 정식 로거 — 레지스트리 miss(대상 UIScrollView를 찾지 못해 스크롤이
// 조용히 사라지는 길) 한 가지만 남긴다(운영자 채택 제안 B, 2026-10-10). 조용히 묻히는
// 실패는 관측 근거가 사라진 뒤에도 없음이 보여야 하므로 임시 측정이 아니라 남는다.
private let arrivalLog = Logger(subsystem: "besir.app", category: "arrival")
// 가로 페이저가 스스로 멈춘 일(되돌림 차단기) — 조용히 묻히면 "넘어가지 않는다"로만 보이므로 관측 근거를 남긴다.
private let pagerLog = Logger(subsystem: "besir.app", category: "pager")

// 따라가기 도착 스크롤은 ScrollViewReader.scrollTo에 맡기지 않고 페이지의 UIScrollView에
// contentOffset을 직접 지정한다(0.9.1 수리 라운드 3 — 측정 2차에서 scrollTo가 그려진 위치와
// 다른 위치로 해석해 떨어지는 것이 확정됐다). 직접 지정하려면 그 페이지의 실제 UIScrollView
// 참조가 필요한데 SwiftUI는 그것을 내놓지 않는다 — 0×0 프로브를 콘텐츠 안쪽에 박아 조상 걷기로
// 찾아 날 키로 등록한다. 조상 걷기 방식은 이 파일의 ScrollTouchFixView가 프로덕션에서 써 온
// 그대로다.
#if os(iOS)
/// 페이지 날(0시 정규화) 키 → 그 페이지 ScrollView의 약한 참조. 등록은 프로브가, 조회는
/// 도착 스크롤이 한다. 약한 참조라 페이지 자리가 재사용되며 스크롤 뷰가 교체돼도
/// 옛 것을 붙잡지 않고, 날 키의 빈 상자 잔여 항목은 본 날 수만큼만 자라 정리 기구를 따로
/// 두지 않는다.
private enum PageScrollRegistry {
    static var byDay: [Date: PageScrollWeakBox] = [:]
    /// 세로 위치 미러링 중 표시 — 미러가 쓴 offset이 다시 미러를 부르는 핑퐁을 막는다. KVO 통지는 쓰는 호출 안에서 동기로
    /// 오므로 이 표시 하나로 충분하다.
    static var mirroring = false

    /// 이 날 앞·뒤 이틀 페이지의 스크롤 뷰(등록된 것만, 가까운 쪽이 앞). 페이지들이 늘 이웃 날이라는 페이저 구조에 기댄다 —
    /// 쉬는 자리 양옆 두 쪽씩(PagerSlots)이라 연타로 둘 건너뛴 쪽도 처음부터 같은 시간대로 보여야 한다.
    static func neighbors(of day: Date) -> [UIScrollView] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let reach = PagerSlots.rest
        return ((-reach)...reach).filter { $0 != 0 }.sorted { abs($0) < abs($1) }.compactMap { delta -> UIScrollView? in
            guard let d = cal.date(byAdding: .day, value: delta, to: start) else { return nil }
            return byDay[cal.startOfDay(for: d)]?.value
        }
    }

    /// 세로 위치 하나를 다른 스크롤 뷰에 옮긴다(애니메이션 없이, 범위 안으로 자르고, 0.5pt 넘게 다를 때만).
    /// 자르는 범위는 도착 스크롤(scrollArrivalBlock)의 ceiling과 같은 식이다.
    static func apply(y: CGFloat, to scroll: UIScrollView) {
        let minY = -scroll.adjustedContentInset.top
        let maxY = max(minY, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        let clamped = min(max(y, minY), maxY)
        guard abs(scroll.contentOffset.y - clamped) > 0.5 else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: clamped), animated: false)
    }
}
private final class PageScrollWeakBox {
    weak var value: UIScrollView?
    init(_ v: UIScrollView?) { value = v }
}
private final class PageScrollProbeView: UIView {
    /// 이 프로브가 박힌 페이지의 날. 페이지 자리는 재사용되므로 날이 바뀔 때마다 다시 등록한다. Swift의 didSet은 같은 값을
    /// 써도 불리므로 바뀐 때만 등록한다 — 갱신마다 등록하면 이웃 세로 위치를 이어받는 쓰기까지 매번 돌아 레이아웃과 서로를
    /// 다시 부른다(r10 크래시).
    var day: Date? { didSet { if day != oldValue { register() } } }
    /// 이 페이지 스크롤 뷰의 세로 위치 관찰 — 넘기는 와중에 옆 페이지가 이미 같은 시간대로 보이게(운영자 t87 "넘기는 와중부터
    /// 같은 시간대") 이웃 날 페이지에 같은 값을 옮긴다. 프로브가 사라질 때 함께 해제한다.
    private var offsetObservation: NSKeyValueObservation?
    private weak var observedScroll: UIScrollView?

    deinit { offsetObservation?.invalidate() }

    private func register() {
        guard let day else { return }
        var v: UIView? = superview
        while let cur = v {
            if let scroll = cur as? UIScrollView {
                PageScrollRegistry.byDay[Calendar.current.startOfDay(for: day)] = PageScrollWeakBox(scroll)
                observe(scroll)
                adoptNeighborOffset(into: scroll)
                return
            }
            v = cur.superview
        }
    }

    private func observe(_ scroll: UIScrollView) {
        guard observedScroll !== scroll else { return }
        observedScroll = scroll
        offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
            self?.mirror(from: sv)
        }
    }

    private func mirror(from source: UIScrollView) {
        // 사용자가 손으로 세로 스크롤하는 동안만 옮긴다 — 레이아웃이 offset을 고치는 중(setContentSize의 보정 등)에 이웃에게 쓰면
        // 갱신 안에서 갱신을 부르는 고리가 된다. 도착 스크롤 같은 프로그램 이동은 옮기지 않는다(그 쪽 하나만 움직인다).
        guard source.isTracking || source.isDragging || source.isDecelerating else { return }
        guard !PageScrollRegistry.mirroring, let day else { return }
        PageScrollRegistry.mirroring = true
        defer { PageScrollRegistry.mirroring = false }
        for other in PageScrollRegistry.neighbors(of: day) where other !== source {
            PageScrollRegistry.apply(y: source.contentOffset.y, to: other)
        }
    }

    /// 새로 등록된 페이지(나타남·자리 재사용)는 이웃이 이미 있으면 그 세로 위치를 이어받는다. 아직 레이아웃 전이라
    /// 내용 높이가 없는 스크롤 뷰는 자를 범위가 없어 건너뛴다.
    private func adoptNeighborOffset(into scroll: UIScrollView) {
        // 등록은 SwiftUI 갱신·창 붙임 도중에 불린다 — offset 쓰기는 다음 턴으로 미룬다.
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll, !PageScrollRegistry.mirroring, let day = self.day,
                  scroll.contentSize.height > scroll.bounds.height,
                  let neighbor = PageScrollRegistry.neighbors(of: day).first(where: { $0 !== scroll }) else { return }
            PageScrollRegistry.mirroring = true
            defer { PageScrollRegistry.mirroring = false }
            PageScrollRegistry.apply(y: neighbor.contentOffset.y, to: scroll)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        register()
    }
}
private struct PageScrollProbeRepresentable: UIViewRepresentable {
    let day: Date
    func makeUIView(context: Context) -> PageScrollProbeView {
        let v = PageScrollProbeView()
        v.day = day   // makeUIView 시점엔 아직 조상이 없으니 등록은 didMoveToWindow가 한다
        return v
    }
    func updateUIView(_ v: PageScrollProbeView, context: Context) {
        v.day = day   // 같은 값이면 didSet 안의 비교가 막아 재등록하지 않는다(창에 붙을 때 이미 등록됨)
    }
}
#endif

/// 프로브를 감싸는 플랫폼 중립 뷰 — 호출처에 #if가 흩어지지 않게 macOS에서는 빈 뷰다.
private struct PageScrollProbe: View {
    let day: Date
    var body: some View {
        #if os(iOS)
        PageScrollProbeRepresentable(day: day)
        #else
        EmptyView()
        #endif
    }
}

struct ContentView: View {
    /// 홈(서비스 선택 화면)으로 돌아가기. RootView가 넘겨준다.
    var onBack: (() -> Void)? = nil

    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationManager
    @EnvironmentObject var notifications: NotificationManager

    @State private var selection: ScheduledEvent.ID?
    @State private var selectedActivityId: ActivityBlock.ID?
    @State private var showingAdd = false
    @State private var showingAddActivity = false
    @State private var showingSettings = false
    @State private var showingFavorites = false

    /// true = 월간 그리드만 표시. false = 주간 스트립 + 일간 시간표 표시.
    @State private var isMonthExpanded = true
    @State private var selectedDate: Date = Date()

    /// 드래그로 재조정 중인 블록(시간표에서 꾹 눌러 옮기는 동안의 임시 상태).
    @State private var activeDrag: ActiveDrag?
    /// 반복 일정 블록을 옮겼을 때 "전체/이 일정만" 확인이 필요한 대기 중인 이동.
    @State private var pendingMove: PendingMove?
    /// t71(REQ-012) — 반복 블록을 놓아 "전체/이 일정만" 선택창이 떠 있는 동안 블록을 놓은 자리에
    /// 그려 두는 미리보기. activeDrag는 놓는 순간 정리되므로(스크롤·페이저 잠금을 함께 켠다 — 그래서
    /// 살려 둘 수 없다) 드래그 값 전체를 여기 복사해 들고, 그림은 legDragShift·dragOffsetMinutes·
    /// span이 activeDrag를 본 뒤 이 값을 이어 보는 한 읽기 함수로 읽는다(계약 5 — 선택창 동안 모양이
    /// 끌기 중 모양과 어긋나면 안 된다). targetDay는 선택창 동안 페이지가 넘어가 있을 날(O-A3·N-8).
    @State private var seriesPreview: SeriesPreview?
    /// 빈칸 꾹 누르기(REQ-009) — 인식(.began) 때 정한 누른 시각의 시드. 카드는 손을 뗄 때(O-A4)
    /// 떠야 하므로 이 값은 시트를 띄우기 전까지 대기만 한다.
    @State private var emptyPressCandidate: Date?
    /// 빈칸 생성 시트의 값 — 불리언 시트는 눌린 값이 첫 렌더에 비어 보일 수 있어(§6 위험 표) 값을
    /// 묶어 띄운다(.sheet(item:)).
    @State private var emptyPressSeed: EmptyPressSeed?
    /// 따라가기 슬라이드 요청(REQ-015 (3)) — 부모는 페이저의 자식 @State를 못 바꾸므로 요청
    /// 값(고유 토큰 + 절대 목표 날)을 바인딩으로 넘기고 페이저가 소비하고 비운다(D-12 (나)).
    @State private var legSlideRequest: SlideRequest?
    /// 따라가기 도착 위치 스크롤 대기 중인 구간 — 확정으로 날짜가 바뀐 뒤 도착 프레임 관찰자가
    /// 안착을 감지하면 이 값을 읽고 그 자리에서 소비한다(정확히 한 번의 보장도 이 소비가 한다).
    /// 발화가 영영 일어나지 않는 실패(드롭이 구간을 0으로 잘라 그 날 목록에서 빠지는 경우 등)에
    /// 대비해, 확정이 도착 날이 아닌 다른 날로 넘어가면 그냥 버린다(수리 S — 마감 없이 남으면
    /// 이후 옆 넘김·재배치 때 세로 점프로 터진다).
    @State private var pendingArrival: (blockId: String, day: Date)?
    /// 도착 스크롤 대상 블록의 전역 프레임을 관찰할 id — followAfterDrop(구간 확정 따라가기)과
    /// beginSeriesPreview(반복 선택창 미리보기가 다른 날로 넘어갈 때, 수리 3)에서 pendingArrival과
    /// 함께 세운다. 블록 id 문법은 positionedBlocks("a-/e-"+UUID)를 그대로 쓴다. 소비
    /// (pendingArrival = nil) 뒤에도 다음 따라가기까지 남기는데, 안착 뒤
    /// 스크롤로 블록 프레임이 다시 변해도 관찰이 살아 있어야 최종 위치를 읽을 수 있기 때문이다.
    @State private var arrivalWatchId: String?

    /// 월·주·일간 페이저가 넘기는 동안(스크롤이 쉬는 자리를 벗어난 뒤 날짜를 쓸 때까지) 켜지는 표시 — 칸 탭이 읽고
    /// (CS-F1·N1), 오늘 버튼은 이 구간이 끝난 뒤로 미룬다.
    @State private var pagerSettle = PagerSettle()

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 56

    /// DateFormatter는 생성 비용이 큰데(로케일·포맷 파싱) 아래 셀들은 스와이프 중 매 프레임,
    /// 한 페이지당 7~42개씩 다시 그려진다 — 매번 새로 만들면 그게 그대로 프레임 낭비다.
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "E"; return f
    }()
    private static let monthTitleFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMMM yyyy"; return f
    }()
    private static let dayTitleFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEE, MMM d"; return f
    }()
    private static let todayTitleFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "'Today,' EEE MMM d"; return f
    }()

    var selectedEvent: ScheduledEvent? {
        store.events.first { $0.id == selection }
    }

    // MARK: - 드래그 상태

    private struct ActiveDrag {
        enum Kind {
            case event(ScheduledEvent)
            case activity(ActivityBlock)
        }
        var kind: Kind
        var deltaMinutes: Int = 0
        /// 구간 드래그가 시작될 때 onBegin이 한 번 구해 둔 소유 활동(REQ-009). 드래그 중에는
        /// span·도우미·onChange 어디서도 다시 조회하지 않는다 — 중간에 값이 어긋나면 미리보기와
        /// 드롭이 다른 블록을 움직인다. 활동 드래그와 소유 없는 구간 드래그는 nil.
        var owner: ActivityBlock? = nil
        /// 드래그가 시작된 페이지 날짜 — 가장자리 상태 판정(D-14)·드롭의 눌렀던 날 전달·놓은 뒤
        /// 따라가기의 기준 날이 이 날이다(따라가기의 눌렀던 날은 운영자 D7).
        var pageDate: Date = Date()
        /// 끄는 중 가장자리 상태(D-14 (가)) — onChange가 Store 바깥 함수(dragEdgeOutcome)에서
        /// 받아 넣어 둔 값이다. 그림(붙음 표지·칩·넘김 중 숨김)은 이 값을 읽기만 하고 시각으로
        /// 다시 판정하지 않는다(표시 = 결과, AC-013 G). 활동 드래그는 늘 안쪽.
        var edgeState: Store.DragEdgeState = .inside
        /// 끌기 방향(요청 Δ의 부호) — dragEdgeOutcome이 상태와 함께 돌려주는 값이다. 붙음에서
        /// deltaMinutes가 0으로 접혀도 방향은 살아 있고, 접힌 Δ의 부호로 다시 뽑으면 아래로 끄는
        /// 중에 "00:00부터"가 맨 위에 뜬다(0.9.1 N1, 계약 5 — 판정 재료를 뷰가 다시 계산하지 않는다).
        /// 0은 요청이 0으로 스냅된 순간뿐인데 그때 한계 함수도 0을 내므로(dragEdgeOutcome 초깃값
        /// 갈래) 상태는 항상 안쪽이고, 표지는 상태가 안쪽이 아니어야만 그려진다 — 즉 그려지는
        /// 시점의 방향은 항상 ±1이다.
        var direction: Int = 0
        var blockId: String {
            switch kind {
            case .event(let e): return "e-\(e.id)"
            case .activity(let a): return "a-\(a.id)"
            }
        }
    }

    private struct PendingMove {
        let message: String
        let apply: (Bool) -> Void   // Bool = wholeSeries
        /// 확정 뒤 따라가기(REQ-015 (3)) — 대화상자가 닫힌 뒤에야 부른다(t60 가설 ④: 확정 창(그때 0.22초,
        /// 지금은 스크롤 정착 감시 PagerScrollController)이 닫힘 전이와 겹치는지는 시험이 가른다). "취소"로는 불리지 않는다.
        var followUp: (() -> Void)? = nil
    }

    /// t71 미리보기 덩어리 — 드래그가 끝난 뒤에도 그림이 끌기 중과 같은 값을 읽게 하려고 ActiveDrag를
    /// 통째로 복사해 들고 온다(owner·가장자리 상태·방향까지 그대로여야 가는/오는 편 끌기 미리보기와
    /// 자정 넘김 지우기가 재현된다). targetDay는 놓은 날(같은 날에 남으면 pageDate와 같은 날).
    private struct SeriesPreview {
        let drag: ActiveDrag
        let targetDay: Date
    }

    /// 빈칸 꾹 누르기 시트의 값(REQ-009) — Identifiable로 묶어 .sheet(item:)에 실는다.
    private struct EmptyPressSeed: Identifiable {
        let id = UUID()
        let start: Date
    }

    // MARK: - 날짜별 데이터

    /// 자정을 넘는 이동은 출발일과 도착일 양쪽에 나열한다(결함 G) — 도착일에만 두면 출발일
    /// 저녁 구간이 통째로 그려지지 않는다. 어느 날에 나열되는지의 판정은 `isListed(on:calendar:)`
    /// (Models.swift) 한 곳에서 낸다 — 월간·주간 점(daysWithSchedule)도 같은 판정으로 켜지므로
    /// 같은 앱이 같은 날에 대해 다른 말을 하지 않게(계약 5). 이동시간 미계산 구간은 앵커 시각이
    /// 든 날 하루에만 나열된다(REQ-023 — 경고 블록이 날짜로 잘리지 않는 것과 세트).
    private func events(on date: Date) -> [ScheduledEvent] {
        store.events.filter { $0.isListed(on: date, calendar: calendar) }
            .sorted { $0.arrivalDate < $1.arrivalDate }
    }

    /// 활동도 이동과 같은 기준으로 [시작, 끝) 구간이 그 날과 겹치면 나열한다 — 자정을 넘는
    /// 활동의 끝날 반쪽이 통째로 안 그려지던 것(결함 G)이 이것으로 닫힌다. 시작·끝이 같거나
    /// 어긋난 깨진 레코드는 구간이 없으므로 시작일에만 두는 기존 동작을 유지한다.
    private func activities(on date: Date) -> [ActivityBlock] {
        store.activities.filter { a in
            guard a.endDate > a.startDate else {
                return calendar.isDate(a.startDate, inSameDayAs: date)
            }
            return Store.overlapsDay(start: a.startDate, end: a.endDate, day: date, calendar: calendar)
        }
        .sorted { $0.startDate < $1.startDate }
    }

    /// 월간 그리드가 좌우 스와이프 중에도 매 프레임 부르는 함수라 O(1) 캐시(Store.daysWithSchedule)만
    /// 본다 — 예전엔 events/activities 전체를 매번 훑어서(day * event 조합) 스와이프 중 버벅였다.
    private func hasEvents(on date: Date) -> Bool {
        store.daysWithSchedule.contains(Store.dayKey(date, calendar: calendar))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ContentUnavailableView("Select an Event", systemImage: "calendar")
        }
        // NavigationSplitView의 detail 컬럼은 iPhone처럼 좁은 화면(compact)에서는 실제 네비게이션
        // push가 있어야 사이드바에서 넘어간다 — selection 상태만 바꿔서는(제스처로 탭했을 때처럼)
        // 화면 전환이 일어나지 않는다(탭해도 상세정보가 안 보이던 원인). 시트로 띄우면 이 문제가 없다.
        // A tap on a departure alert opens that event's detail; the id is consumed once, and an id with no event is dropped
        // (SPEC-REPLAN-001 REQ-REPLAN-013).
        .onChange(of: notifications.tappedEventID, initial: true) {
            if let id = Replan.tapSelection(pending: notifications.consumeTappedEventID(), events: store.events) {
                selection = id
            }
        }
        .sheet(isPresented: Binding(
            get: { selection != nil },
            set: { if !$0 { selection = nil } }
        )) {
            if let event = selectedEvent {
                NavigationStack {
                    EventDetailView(event: event)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { selection = nil }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedActivityId != nil },
            set: { if !$0 { selectedActivityId = nil } }
        )) {
            if let activityId = selectedActivityId {
                ActivityDetailView(activityId: activityId)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddEventView()
        }
        .sheet(isPresented: $showingAddActivity) {
            // 보고 있던 날을 넘긴다 — 시작 바퀴가 그 날에 선다(t50 P3).
            AddActivityView(defaultDay: selectedDate)
        }
        // 빈칸 꾹 누르기의 새 활동 카드(REQ-009) — 불리언 시트(showingAddActivity) 대신 값을 묶어
        // 띄운다: 눌린 시각은 시트가 뜨는 값에서 파생해야 첫 렌더에 비어 보이지 않는다(§6 위험 표).
        // 날은 selectedDate가 아니라 시드의 날 — 23:55 누름은 다음 날 00:00 시드로 카드가 다음 날에
        // 열린다(O-A6), 누른 페이지의 날이라는 것도 같은 이유다(§4-c).
        .sheet(item: $emptyPressSeed) { seed in
            AddActivityView(defaultDay: calendar.startOfDay(for: seed.start), presetStart: seed.start)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingFavorites) {
            FavoritesView()
        }
        // AI 채팅 시트는 RootView가 띄운다 — AI를 여는 버튼이 우하단 besir 로고 버튼 하나로
        // 통일돼 그 자리가 RootView이기 때문이다(REQ-007).
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            calendarHeader

            if isMonthExpanded {
                monthGrid
            } else {
                weekStrip
                Divider()
                dayTimetable
            }
        }
        .background(Theme.bg)
        .navigationTitle("be on-time sir")
        .frame(minWidth: 280)
        // 왼쪽 아래 '오늘' 버튼(REQ-001 뒷문장, O-C7 — 목업 t82-3). 우상단 툴바가 비워지는 뒤
        // 마일스톨과 무관하게 이 단계에 늘 떠 있고(오늘을 보고 있을 때도), 월 달력이 펼쳐져 있으면
        // 접지 않고 오늘 든 달만 보여준다(페이저 두 개 모두 selectedDate에서 페이지를 정하므로 날만
        // 바꾸면 된다). 모양은 우하단 besir 로고 버튼과 같은 동그란 버튼 하나(FloatingCircle — 운영자
        // 지시 §33 "똑같이 동그란 선으로 감싸기")이고, 크기·바깥 여백을 같은 상수에서 읽어 두 원의
        // 바닥이 같은 높이에 선다(계약 5). 글자 대신 달력·시계 아이콘이라 이름은 접근성 라벨이 맡는다.
        // 넘김이 진행되는 구간(스크롤이 쉬는 자리를 벗어난 뒤 날짜를 쓸 때까지) 안에 누르면 그 자리에서 쓰지 않고 구간이 끝난 뒤에 쓴다 — 지금 쓰면 곧 이어
        // 정착 확정(PagerScrollController.commit)이 오늘 위에 ±1(달·주·일)을 얹어 엉뚱한 날이 된다(폰 피드백 — 월 5/5). 칸 탭과 달리 버리지
        // 않는 것은 목적지(오늘)가 구간 끝에도 같아서다.
        .overlay(alignment: .bottomLeading) {
            Button {
                pagerSettle.whenSettled { selectedDate = Date() }
            } label: {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.muted)
                    .floatingCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today")
            .padding(.leading, FloatingCircle.inset)
            .padding(.bottom, FloatingCircle.inset)
        }
        // 따라가기 도착 위치(REQ-015 (3))의 실행은 도착 프레임 관찰자의 안착 판정
        // (settleArrivalIfNeeded)이 한다 — 확정 onChange에서 곧바로 스크롤을 부르면 확정
        // 트랜잭션 직후 약 20ms, 옆 슬라이드가 아직 안착하는 동안 발사해 스크롤이 도중에
        // 끊기는 것이 측정으로 확정됐다(0.9.1 수리 라운드 3 — lead-repair-091-r3-measure.md).
        // 이 자리는 그 실패의 마감이다(수리 S): 안착 판정이 영영 일어나지 않아 pendingArrival이
        // 남아 있으면, 확정이 도착 날이 아닌 다른 날로 넘어가는 순간 버린다 — 남은 값은 이후
        // 옆 넘김이나 재배치 때 세로 점프로 터진다. 월·일간 두 갈래를 모두 품는 이 VStack에
        // 붙인다(일간 페이저에 두면 월 확장으로 언마운트되는 찰나의 날 변경이 마감을 빠져나간다).
        .onChange(of: selectedDate) { _, newValue in
            guard let arrival = pendingArrival,
                  !calendar.isDate(newValue, inSameDayAs: arrival.day) else { return }
            pendingArrival = nil
        }
        .confirmationDialog(pendingMove?.message ?? "", isPresented: Binding(
            get: { pendingMove != nil },
            // 닫힘 갈래 둘(바깥 탭·취소 단추) 다 미리보기 정리를 함께 한다(REQ-012 — 취소하면 원래
            // 날·원래 자리). 단추 갈래는 단추 동작(applyPendingMove)이 먼저 실행된 뒤라 이미 정리된
            // 상태를 다시 정리하지 않게 nil 확인이 문이 된다.
            set: { if !$0 { pendingMove = nil; cancelSeriesPreview() } }
        ), titleVisibility: .visible) {
            Button("Move Entire Series") { applyPendingMove(true) }
            Button("Move This Event Only") { applyPendingMove(false) }
            Button("Cancel", role: .cancel) { pendingMove = nil; cancelSeriesPreview() }
        }
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .cancellationAction) {
                    Button { onBack() } label: { Label("Home", systemImage: "chevron.left") }
                }
            }
            // 맥은 지금 모양 그대로(O-C1 — '+' 메뉴 포함 전부), 아이폰은 우상단을 비운다(REQ-001).
            // 항목마다 #if를 두지 않고 맥 전용 항목 전체를 한 블록으로 감싼 이유: AC-001의 awk가
            // #if 중첩을 읽지 못해 중간에 #if가 끼면 셈이 무너진다. iOS 갈래(#else)는 비워 둔다 —
            // 아이폰의 설정은 로비(RootView), AI는 우하단 besir 로고 버튼, '오늘'은 왼쪽 아래
            // 원 버튼(M2)이 각각 맡는다.
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button { selectedDate = Date(); isMonthExpanded = false } label: { Image(systemName: "calendar.badge.clock") }
                    .help("Go to Today")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingFavorites = true } label: { Image(systemName: "star") }
                    .help("Favorite Places")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showingAdd = true } label: { Label("Add Travel Event", systemImage: "arrow.triangle.turn.up.right.diamond") }
                    Button { showingAddActivity = true } label: { Label("Add Activity", systemImage: "clock") }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add New Event")
            }
            #else
            #endif
        }
    }

    // MARK: - 헤더(월간⇄주간+일간 전환)

    private var calendarHeader: some View {
        HStack {
            // 아이폰은 전환 버튼 없이 날짜 제목만 둔다(운영자 §33) — 월 달력은 주간 날짜 줄을 아래로 쓸어
            // 펴고(weekStrip), 월 달력에서 날짜를 누르면 그날 시간표로 간다. 맥은 버튼이 있어 쓸기를
            // 달지 않고 지금 단추를 그대로 보존한다(새 맥 기능 0).
            #if os(macOS)
            Button {
                withAnimation(.easeInOut) { isMonthExpanded.toggle() }
            } label: {
                Image(systemName: isMonthExpanded ? "chevron.down.circle" : "chevron.up.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(isMonthExpanded ? "Switch to Day View" : "Switch to Month View")
            // .help는 맥 툴팁용 — iOS VoiceOver용으로 같은 문구를 라벨에도 둔다.
            .accessibilityLabel(isMonthExpanded ? "Switch to Day View" : "Switch to Month View")
            #endif

            Spacer()
            Text(isMonthExpanded ? monthTitle(selectedDate) : dayTitle(selectedDate))
                .font(.headline).foregroundStyle(Theme.ink)
            Spacer()

            #if os(macOS)
            // 좌우 대칭을 위한 자리(버튼 없음 — 넘기기는 스와이프로 처리).
            Color.clear.frame(width: 22, height: 22)
            #endif
        }
        .padding()
    }

    // MARK: - 월간(Month) 그리드

    /// 월 칸 한 칸의 높이를 정하는 **숨은 본보기**(수리 4b) — 가장 꽉 찬 칸 모양(날짜 숫자 +
    /// 한글 제목 알약 둘 + "+N")을 실제 글꼴·여백·간격으로 그려, 그 렌더 높이가 곧 모든 칸의
    /// 높이다. UIFont 줄 높이(수리 4)는 SF 기준이라 한글이 실제로 그려지는 대체 글꼴보다 작아
    /// 늘 모자랐다("+2"가 오히려 더 가려짐) — 글꼴 값으로 어림하지 말고 그려진 크기로 잰다.
    private static let monthCellVSpacing: CGFloat = 2      // 칸 VStack 간격(본보기·실제 칸이 같이 읽음)
    private static let monthPillVPadding: CGFloat = 1      // 알약 위아래 여백(dayTitlePill)
    /// Template text: a title, a two-digit date and a two-digit "+N" (the app is English, so the title sets the line height).
    private static let monthTemplateTitle = "Title"
    private static let monthTemplateDay = 28
    private static let monthTemplateMore = "+9"

    /// 숨은 본보기 뷰 — .hidden()은 렌더만 감추고 레이아웃 크기를 낸다.
    private var monthCellTemplate: some View {
        VStack(alignment: .center, spacing: Self.monthCellVSpacing) {
            Text("\(Self.monthTemplateDay)").font(.callout)
            dayTitlePill((id: UUID(), title: Self.monthTemplateTitle))
            dayTitlePill((id: UUID(), title: Self.monthTemplateTitle))
            Text(Self.monthTemplateMore).font(.caption2).foregroundStyle(Theme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .hidden()
    }

    /// 본보기 렌더 높이(격자 높이의 출처). 첫 그림 기본값은 수리 2의 72 — 측정되기 전에
    /// 짧게 잘리는 쪽보다 넉넉한 쪽이 낫다(지시서).
    @State private var monthTemplateHeight: CGFloat = 72
    private static let monthRowCount = 6
    private static let monthRowSpacing: CGFloat = 4
    /// 요일 줄(HStack)과 날짜 격자(칸 HStack)의 열 간격 — 한 상수를 둘이 읽는다(계약 5). 요일 줄이 기본 간격(약 8)이고
    /// 격자가 2여서 칸 폭이 달랐고, 가운데(수)는 맞아도 양끝(일·토)으로 갈수록 숫자가 글자 밑에서 벌어졌다(운영자 §37).
    private static let monthColumnSpacing: CGFloat = 2
    private static let monthBottomPadding: CGFloat = 6
    /// 월 격자 전체 높이 = 칸 높이(본보기 렌더 높이) × 줄 + 줄 간격 × (줄−1) + 아래 여백.
    /// 칸 높이와 같은 출처에서 계산해 한쪽만 바뀌어 다시 잘리는 창을 없앤다(계약 5 — 아래
    /// padding과 줄 VStack spacing도 같은 상수를 읽는다).
    private var monthGridHeight: CGFloat {
        CGFloat(Self.monthRowCount) * monthTemplateHeight
            + CGFloat(Self.monthRowCount - 1) * Self.monthRowSpacing + Self.monthBottomPadding
    }

    private var monthGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: Self.monthColumnSpacing) {
                ForEach(Self.weekdayFormatter.shortStandaloneWeekdaySymbols, id: \.self) { d in
                    Text(d).font(.caption2).foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)
            // 본보기 높이를 여기서 한 번 읽는다(수리 4b) — 배경에 깔아 레이아웃에 영향을 주지
            // 않게. 글자 크기가 바뀌면 다시 잰다(환경 변화로 뷰가 다시 그려질 때 발화).
            .background {
                monthCellTemplate
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { monthTemplateHeight = max(monthTemplateHeight, g.size.height) }
                            .onChange(of: g.size.height) { _, h in monthTemplateHeight = max(monthTemplateHeight, h) }
                    })
            }

            // 손가락을 따라 이전/현재/다음 달이 함께 움직이는 캐러셀. 높이는 monthGridHeight가
            // 본보기 렌더 높이에서 낸다 — 칸 × 6 + 줄 간격 × 5 + 아래 여백(REQ-014).
            SwipePager(date: $selectedDate,
                       step: { d, delta in calendar.date(byAdding: .month, value: delta, to: d) ?? d },
                       settle: pagerSettle) { pageDate in
                monthGridContent(for: pageDate)
            }
            .frame(height: monthGridHeight)
            Spacer()
        }
        .padding(.top, 2)
    }

    /// 날짜 격자는 LazyVGrid가 아니라 즉시 만드는 VStack·HStack이다 — 쪽을 가로 ScrollView에 넣은 뒤로는 LazyVGrid가 화면 밖
    /// 쪽의 칸을 넘기는 도중에야 만들어(42칸이 한 프레임에 생겨 월 넘김 렉이 되살아난다) 쪽 생성 비용을 날짜가 바뀌는 순간으로
    /// 되돌린다. 열 폭은 칸의 `.frame(maxWidth: .infinity)`가 똑같이 나눈다(주간 줄과 같은 방식).
    private func monthGridContent(for date: Date) -> some View {
        let days = daysInMonthGrid(for: date)
        return VStack(spacing: Self.monthRowSpacing) {
            ForEach(0..<Self.monthRowCount, id: \.self) { row in
                HStack(spacing: Self.monthColumnSpacing) {
                    ForEach(0..<7, id: \.self) { col in
                        if row * 7 + col < days.count {
                            dayCell(days[row * 7 + col], pageMonth: date)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, Self.monthBottomPadding)
    }

    private func dayCell(_ day: Date, pageMonth: Date) -> some View {
        // 달 안/밖 색은 선택한 날이 아니라 이 칸이 그려지는 쪽의 달과 비교한다 — 선택한 날과 비교하면 슬라이드 중 옆 쪽의 날짜가
        // 전부 옅은 색으로 들어왔다가 확정되는 순간 진한 색으로 바뀐다(운영자 t87 "애초에 바뀌어져 있는 색으로 넘겨지도록").
        let inMonth = calendar.isDate(day, equalTo: pageMonth, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        // 칸 제목은 Store 캐시(daysWithActivityTitles)만 본다(REQ-014) — 뷰가 activities를
        // 다시 훑으면 점과 같은 날별 판정이 두 곳에 생긴다(계약 5).
        let titles = store.daysWithActivityTitles[Store.dayKey(day, calendar: calendar)] ?? []
        // 칸 높이는 숨은 본보기(monthCellTemplate)의 렌더 높이가 정한다(수리 4b) — 모든 칸이
        // 같은 높이·위쪽 정렬이라 마지막 줄이 잘리지 않고 날짜 숫자도 같은 높이에 선다(수리 2의
        // 증상). 큰 글씨에서 내용이 칸을 넘으면 이웃 칸을 덮지 않게 자른다(블록 뷰의 clipped와
        // 같은 이유).
        // 날짜 숫자와 "+N"은 칸 가운데에 서고(운영자 §33 "가운데 정렬이 아니라 왼쪽 정렬이라 불편"),
        // 제목 알약은 frame(maxWidth: .infinity)라 칸 너비 그대로 펴진다. 본보기도 같은 정렬로 둔다 —
        // 높이는 정렬과 무관하지만 둘이 다르면 다음에 한쪽만 읽고 고치게 된다(계약 5).
        return ZStack(alignment: .top) {
            monthCellTemplate
            VStack(alignment: .center, spacing: Self.monthCellVSpacing) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout)
                    .foregroundStyle(inMonth ? Theme.ink : Theme.faint)
                // 칸 높이에 들어가는 만큼(제목 둘)만 보이고 남은 수는 "+N" 한 줄로 알린다(상태
                // 표시라 §10 규칙 밖). 점은 칸에 제목이 직접 들어온 만큼 쓸모를 잃어 월 칸에서는
                // 빼고 주간 스트립(weekDayCell)에만 남긴다(목업 t82-10).
                ForEach(0..<min(2, titles.count), id: \.self) { i in
                    dayTitlePill(titles[i])
                }
                if titles.count > 2 {
                    Text("+\(titles.count - 2)")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        // 오늘은 테두리로 감싸지 않고 아래 선 하나로만 표시한다(이 방향은 선으로 나눈다).
        .overlay(alignment: .bottom) {
            Rectangle().fill(isToday ? Theme.ink : .clear).frame(height: 1.5).padding(.horizontal, 10)
        }
        .contentShape(Rectangle())
        // 숫자와 제목 알약을 한 덩어리로 읽게 한다 — 제목이 알약(색)만으로는 전달되지 않게.
        .accessibilityElement(children: .combine)
        // 탭은 시스템 onTapGesture로 받는다 — 손가락이 닿자마자 시작하는 DragGesture(minimumDistance: 0)는
        // 바깥 가로 페이징 스크롤의 팬 인식을 막아(simultaneous로 달아도 월 달력이 좌우로 안 넘어갔다, 시뮬레이터
        // t87 2차) 쓰지 않는다. 시스템 탭은 움직임이 시작되면 스스로 취소되므로 넘기는 손짓이 탭으로 읽히지 않는다.
        .onTapGesture { tapDay(day, collapsingMonth: true) }
        // VoiceOver는 제스처를 누르지 못하므로(UI-U1) 같은 몸통(selectDay)을 기본 동작으로도 건다 —
        // 전환 버튼이 빠진 아이폰에서 월 달력 → 일간으로 돌아오는 길이 이 칸 하나뿐이다. 이름 없는 동작이라
        // 새 문구가 없고, 버튼 특성은 읽는 말('버튼')만 더한다.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selectDay(day, collapsingMonth: true) }
    }

    /// 날짜 칸을 눌렀을 때의 몸통 하나 — 칸 탭 제스처와 손쉬운 사용 기본 동작이 같이 부른다(계약 5).
    /// 월 달력의 칸이면 선택 뒤 일간으로 접고, 주간 줄의 칸이면 날만 바꾼다.
    private func selectDay(_ day: Date, collapsingMonth: Bool) {
        selectedDate = day
        if collapsingMonth { withAnimation(.easeInOut) { isMonthExpanded = false } }
    }

    /// 칸 제목 알약 한 줄 — 색은 옅은 바탕(travelFill)에 같은 계열 글자(travelInk)로만
    /// (계약 6), 모서리는 Theme.radius(거의 사각) 방향을 따른다.
    private func dayTitlePill(_ item: (id: UUID, title: String)) -> some View {
        Text(item.title)
            .font(.caption2)
            .foregroundStyle(Theme.travelInk)
            .lineLimit(1)
            .padding(.horizontal, 3)
            // 여백 값은 칸 높이를 정하는 본보기(monthCellTemplate)가 읽는 상수와 같은 것 —
            // 여기만 바꾸면 칸이 다시 모자라진다(수리 4b, 계약 5).
            .padding(.vertical, Self.monthPillVPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.travelFill, in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    /// 항상 6주(42칸) 격자로 반환해 레이아웃이 흔들리지 않게 한다.
    private func daysInMonthGrid(for date: Date) -> [Date] {
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard let monthStart = calendar.date(from: comps) else { return [] }
        let leading = calendar.component(.weekday, from: monthStart) - 1
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func monthTitle(_ d: Date) -> String { Self.monthTitleFormatter.string(from: d) }

    // MARK: - 주간(Week) 스트립 — 일간 보기 위에 표시

    /// 손가락을 따라 이전/현재/다음 주가 함께 움직이는 캐러셀(일간 시간표와 같은 SwipePager 재사용,
    /// 한 번에 7일씩 이동). selectedDate를 그대로 공유하므로 주를 넘기면 아래 일간 시간표도 같이 넘어간다.
    private var weekStrip: some View {
        SwipePager(date: $selectedDate,
                   step: { d, delta in calendar.date(byAdding: .day, value: delta * 7, to: d) ?? d },
                   isLocked: activeDrag != nil,
                   settle: pagerSettle) { pageDate in
            weekStripContent(for: pageDate)
        }
        .frame(height: 64)
        // 주간 줄을 아래로 쓸면 월 달력이 펴진다(운영자 §33 — 전환 버튼 대체, 닫는 쓸기는 없음). 이 줄에는
        // 이미 제스처가 둘 있다: 가로 넘김(SwipePager의 가로 페이징 스크롤)과 날짜 칸 탭
        // (onTapGesture — 움직임이 시작되면 시스템이 취소). 아래로 쓸기는 simultaneous로 나란히 두고 축과 거리로
        // 나눈다 — 여기는 |세로| > |가로|이고 40pt를 넘길 때만 반응하므로 가로 넘김과 겹치지 않고, 쓸려 움직인
        // 터치는 칸 탭도 되지 않는다. 시간표의 세로 스크롤은 이 줄 밖(Divider 아래)이라 닿지 않는다.
        // 맥은 전환 버튼(calendarHeader)이 있어 쓸기를 달지 않는다(AF1 — 맥은 지금 동작 보존). 손쉬운 사용
        // 쪽 길('월간 보기로')은 각 날짜 칸에 있다(weekDayCell).
        #if os(iOS)
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard value.translation.height > 40,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    expandMonth()
                }
        )
        #endif
    }

    /// 월 달력 펴기 — 아래로 쓸기와 손쉬운 사용 동작이 같은 몸통을 부른다(계약 5).
    private func expandMonth() {
        withAnimation(.easeInOut) { isMonthExpanded = true }
    }

    private func weekStripContent(for date: Date) -> some View {
        HStack(spacing: 4) {
            ForEach(daysInWeek(for: date), id: \.self) { day in
                weekDayCell(day, pageDate: date)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func weekDayCell(_ day: Date, pageDate: Date) -> some View {
        // 선택 표시는 선택한 날이 아니라 이 칸이 그려지는 쪽의 기준 날(선택한 날 ± 7일)과 비교한다 — 옆 주 쪽에도 같은 요일 칸에
        // 밑줄이 미리 서 있어, 확정되는 순간 밑줄이 툭 생기지 않는다(운영자 t87, 월 칸 색과 같은 이유). 가운데 쪽은 기준 날이
        // 선택한 날 그대로라 지금 동작과 같다.
        let isSelected = calendar.isDate(day, inSameDayAs: pageDate)
        let isToday = calendar.isDateInToday(day)
        return VStack(spacing: 3) {
            Text(Self.weekdayFormatter.string(from: day)).font(.caption2).foregroundStyle(Theme.faint)
            Text("\(calendar.component(.day, from: day))")
                .font(.callout)
                .foregroundStyle(isSelected ? Theme.ink : (isToday ? Theme.travel : Theme.muted))
            Circle()
                .fill(hasEvents(on: day) ? Theme.travel : .clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        // 선택은 면을 칠하지 않고 밑줄로만 — 주간 스트립이 색 덩어리가 되지 않게.
        .overlay(alignment: .bottom) {
            Rectangle().fill(isSelected ? Theme.ink : .clear).frame(height: 1.5).padding(.horizontal, 6)
        }
        .contentShape(Rectangle())
        .onTapGesture { tapDay(day, collapsingMonth: false) }
        // 같은 이유로 기본 동작을 건다(UI-U1). '월간 보기로'는 줄 묶음이 아니라 각 칸에 단다(UI-U2) —
        // 묶음(.contain) 위의 동작은 자식 칸에 포커스가 있을 때 회전자에 안 뜰 수 있어, 칸마다 같은 이름을
        // 두면 어느 칸에 있어도 노출된다. 이름은 전환 버튼이 갖던 문구 그대로(새 문구 0), 맥은 버튼이 있어
        // 필요 없다. 요일·날짜 글자가 따로 잡혀 동작이 중복되지 않게 칸을 한 요소로 묶는다(월 칸과 같은 .combine).
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selectDay(day, collapsingMonth: false) }
        #if os(iOS)
        .accessibilityAction(named: "Switch to Month View") { expandMonth() }
        #endif
    }

    /// 칸 탭 — 넘김이 확정되는 동안(PagerSettle.settling)의 탭은 버린다(폰 피드백 CS-F1). 페이지가 아직 움직이는
    /// 중이라 손가락 밑 칸이 들어오는 달의 칸이고, 이 탭이 selectedDate를 쓴 직후 정착 확정(PagerScrollController.commit)이
    /// 현재 date에서 상대로 한 달을 더 얹어 "누른 칸 ± 한 달"로 어긋났다(sim-tester 10/10). 감속 중인 페이지를
    /// 손가락으로 멈추기만 한 탭도 이 구간 안이라 같이 버려진다.
    private func tapDay(_ day: Date, collapsingMonth: Bool) {
        guard !pagerSettle.settling else { return }
        selectDay(day, collapsingMonth: collapsingMonth)
    }

    private func daysInWeek(for date: Date) -> [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        var days: [Date] = []
        var cur = interval.start
        while cur < interval.end {
            days.append(cur)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
        return days
    }

    private func dayTitle(_ d: Date) -> String {
        (calendar.isDateInToday(d) ? Self.todayTitleFormatter : Self.dayTitleFormatter).string(from: d)
    }

    // MARK: - 일간(day) 시간표(타임라인) UI

    /// 반복 대화상자에서 "전체/이 일정만"을 곌 때의 공통 경로 — 적용 → 닫기(pendingMove = nil) →
    /// 따라가기 순서를 한 곳에서 지킨다. 따라가기 요청은 대화상자가 닫힌 뒤에 내진다(t60 가설 ④,
    /// plan D-12 (나) — 겹침 여부는 시뮬레이터 시험이 가른다). 미리보기(seriesPreview)는 저장 **앞에**
    /// 지운다(REQ-012) — 미리보기 Δ는 확정값과 같은 함수가 낸 값이라 그림이 흔들리지 않고, 저장된
    /// 레코드 위에 미리보기가 얹히는 한 프레임도 없다. 페이지는 followUp(followAfterDrop)이 정확히
    /// 옮긴다.
    private func applyPendingMove(_ wholeSeries: Bool) {
        guard let move = pendingMove else { return }
        seriesPreview = nil
        move.apply(wholeSeries)
        pendingMove = nil
        move.followUp?()
    }

    @ViewBuilder
    private var dayTimetable: some View {
        // 손가락을 따라 이전/현재/다음 날이 함께 움직이는 캐러셀. 블록을 드래그하는 동안(activeDrag)은
        // 페이지 전환용 좌우 제스처를 잠가 재조정 드래그와 서로 방해하지 않게 한다. 따라가기 슬라이드
        // 요청(legSlideRequest)도 손 넘김과 같은 경로로 이 페이저에서 소비된다(REQ-015 (3)).
        SwipePager(date: $selectedDate,
                   step: { d, delta in calendar.date(byAdding: .day, value: delta, to: d) ?? d },
                   isLocked: activeDrag != nil,
                   slideRequest: $legSlideRequest,
                   settle: pagerSettle) { pageDate in
            dayTimetableContent(for: pageDate)
        }
    }

    private func dayTimetableContent(for date: Date) -> some View {
        var dayEvents = events(on: date)
        var dayActivities = activities(on: date)
        // t71 미리보기(REQ-012) — 저장 나열은 아직 옛 값이므로, 놓은 날 페이지에 미리보기 블록을
        // 끼워 넣는다(그 자리 그리기는 span이 미리보기 Δ로 한다). 눌렀던 날에도 걸쳐 나열되는
        // 이동(자정 넘김)은 이미 목록에 있으므로 contains가 중복 삽입을 막는다.
        if let preview = seriesPreview, calendar.isDate(preview.targetDay, inSameDayAs: date) {
            switch preview.drag.kind {
            case .event(let e):
                if !dayEvents.contains(where: { $0.id == e.id }) { dayEvents.append(e) }
            case .activity(let a):
                if !dayActivities.contains(where: { $0.id == a.id }) { dayActivities.append(a) }
            }
        }
        let placed = positionedBlocks(events: dayEvents, activities: dayActivities, on: date)
        // 하루 창은 24시간 고정(REQ-009, 0.9.0 — 연장·자동 스크롤 거둠). 눈금·구분선·콘텐츠 높이·
        // 두 span의 자르기가 전부 이 고정 창을 읽는다.
        let hourCount = 24
        return ScrollView {
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 4) {
                        VStack(spacing: 0) {
                            // Array로 싸는 것은 hourCount가 let 값이라 리터럴 범위 ForEach를 못 쓰기
                            // 때문이다(0.8.x의 연장처럼 칸 수가 변하던 흔적 — 지금은 24로 고정).
                            ForEach(Array(0..<hourCount), id: \.self) { h in
                                Text(String(format: "%02d", h))
                                    .font(.caption2).foregroundStyle(Theme.faint)
                                    .lineLimit(1).minimumScaleFactor(0.6)
                                    .frame(width: 28, height: hourHeight, alignment: .top)
                            }
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 0) {
                                    ForEach(Array(0..<hourCount), id: \.self) { _ in
                                        Divider().overlay(Theme.line).frame(height: hourHeight, alignment: .top)
                                    }
                                }
                                ForEach(placed) { p in
                                    let f = columnFrame(p, total: geo.size.width)
                                    // 자리는 패딩(레이아웃)으로 잡는다 — .offset은 렌더 변환일 뿐이라
                                    // 뷰의 레이아웃 프레임이 항상 0시 끝에 있었다(F4 — 옛 도착 스크롤이
                                    // 옮긴 블록 위치와 무관하게 0시에만 떨어졌던 원인). 패딩 안쪽에 두면
                                    // 관찰자가 읽는 전역 프레임이 그려지는 블록 사각형 그 자체가 된다.
                                    // 값은 그리기·히트테스트와 같은 출처(columnFrame·offsetY)를 그대로
                                    // 읽는다(계약 5 — 두 번째 계산 없음).
                                    blockView(for: p, on: date)
                                        .frame(width: f.width)
                                        // 도착 프레임 관찰자(0.9.1 수리 라운드 3) — 따라가기 대상 블록에만
                                        // 붙는다. 블록 체인의 안쪽(패딩 앞)에 붙여야 겉 패딩이 체인 전체를
                                        // 밀 때 관찰자도 함께 밀려 전역 프레임이 블록을 따라간다. 자정을
                                        // 넘는 구간은 이틀 페이지에 함께 나열되므로 두 인스턴스가 모두
                                        // 관찰되고, 안착 판정(minX)과 페이지 날 조건이 화면 안쪽 인스턴스를
                                        // 가린다.
                                        .background {
                                            if p.id == arrivalWatchId {
                                                GeometryReader { g in
                                                    Color.clear
                                                        .onAppear {
                                                            // 수리 3b 진단: 관찰자가 실제로 붙었는지 — 이 줄이
                                                            // 없으면 대기만 세워지고 관찰자가 아예 안 붙은 것.
                                                            arrivalLog.notice("arrival observer appeared block=\(p.id, privacy: .public) page=\(dayTitle(date), privacy: .public)")
                                                            settleArrivalIfNeeded(page: date, block: p, columnX: f.x,
                                                                                  frame: g.frame(in: .global))
                                                        }
                                                        .onChange(of: g.frame(in: .global)) { _, fr in
                                                            settleArrivalIfNeeded(page: date, block: p, columnX: f.x,
                                                                                  frame: fr)
                                                        }
                                                }
                                            }
                                        }
                                        .padding(.leading, f.x)
                                        .padding(.top, offsetY(for: p))
                                }
                                // 오늘이면 지금 시각을 가는 선으로 표시한다 — "다음 일정까지 얼마 남았나"를
                                // 스크롤하며 시각을 세지 않아도 알 수 있다.
                                if calendar.isDateInToday(date) {
                                    Rectangle()
                                        .fill(Theme.nowLine)
                                        .frame(height: 1)
                                        .offset(y: minutesSinceMidnight(Date()) / 60 * hourHeight)
                                        .allowsHitTesting(false)
                                }
                                // 끄는 중 가장자리 표시(D-14 (가)) — 붙음 표지·넘김 칩. 상태와 방향은
                                // onChange가 Store 바깥 함수에서 받아 ActiveDrag에 넣어 둔 값만 읽는다
                                // (여기서 시각이나 접힌 Δ의 부호로 다시 판정하지 않는다 — 표시 = 결과,
                                // AC-013 G). 눌렀던 날 페이지에만 그린다.
                                if let drag = activeDrag, case .event(let leg) = drag.kind,
                                   drag.edgeState != .inside, calendar.isDate(drag.pageDate, inSameDayAs: date) {
                                    edgeIndicator(for: leg, state: drag.edgeState,
                                                  downward: drag.direction > 0,
                                                  deltaMinutes: drag.deltaMinutes)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                                               alignment: drag.direction > 0 ? .bottomLeading : .topLeading)
                                        .padding(3)
                                        .allowsHitTesting(false)
                                }
                            }
                            #if os(iOS)
                            // SwiftUI의 LongPress+Drag 조합 제스처는(.simultaneousGesture로 붙여도) ScrollView의
                            // 팬 제스처·블록의 onTapGesture와 계속 충돌했다(실패하는 시도조차 터치를 붙잡고 있음).
                            // UIKit 레벨에서 shouldRecognizeSimultaneouslyWith를 직접 true로 선언하면 확실히
                            // 동시 인식되므로, 투명 오버레이 하나로 이 부분만 UIKit 제스처로 처리한다.
                            // 이 오버레이가 블록들 위를 덮기 때문에 블록 자체의 onTapGesture는 더 이상 히트
                            // 테스트에 닿지 않는다 — 탭도 이 오버레이의 UITapGestureRecognizer가 대신 처리한다.
                            .overlay(
                                RescheduleOverlay(
                                    onBegin: { x, y in
                                        // 넘김이 확정되는 동안(PagerSettle.settling)엔 시작하지 않는다 — 감속하는 쪽을 손가락으로 멈춘
                                        // 터치가 옮겨 오는 새 날 블록의 끌기·편집으로 읽히지 않게(t87 F1, 월 칸 탭과 같은 규칙).
                                        // false면 빈칸 길로 넘어가므로 그쪽도 같은 문을 둔다.
                                        guard !pagerSettle.settling else { return false }
                                        guard let found = block(atX: x, y: y, in: placed, total: geo.size.width) else { return false }
                                        // 소유 조회는 드래그 시작 때 이 한 번뿐이다(REQ-009·AC-007) — 이후
                                        // span·도우미·onChange가 다시 찾으면 드래그 중 회차가 어긋날 때
                                        // 미리보기와 드롭이 다른 활동을 움직인다. 활동 드래그는 소유가 없다.
                                        let owner: ActivityBlock?
                                        if case .event(let e) = found { owner = store.owningActivity(of: e) } else { owner = nil }
                                        activeDrag = ActiveDrag(kind: found, deltaMinutes: 0, owner: owner, pageDate: date)
                                        // 꾹 누름 인식 진동(REQ-011, t70) — 빈칸 길과 같은 함수·같은 진동(O-A9).
                                        hapticPressRecognized()
                                        return true
                                    },
                                    onEmptyBegin: { x, y in
                                        // onBegin과 같은 문 — 확정 중의 눌림이 빈칸 생성 길로 새지 않게(꾹 누름은 취소로 끝난다).
                                        guard !pagerSettle.settling else { return false }
                                        // 빈칸 판정(REQ-009·O-A5) — 히트테스트와 같은 목록(placed)·같은
                                        // 환산(minutes(atY:))으로만 판정한다(계약 5). 규칙: 누른 분(세로)이
                                        // 어떤 블록의 시간 범위에 걸쳐 있으면 가로가 칸 간격(3pt) 등에 빗나간
                                        // 누름으로 보고 무시한다(사용자는 블록 옆을 눌렀다고 생각한다 — 그 자리에
                                        // 새 활동이 뜨는 것이 요구가 아니고 틈이라는 REQ-009 서술과도 같다).
                                        // 세로 어디에도 닿지 않는 빈칸일 때만 생성 길.
                                        let pressed = minutes(atY: y)
                                        let touchesBlockTime = placed.contains { pressed >= $0.start && pressed <= $0.start + $0.minutes }
                                        guard !touchesBlockTime else { return false }
                                        // 시각은 처음 누른 자리(.began의 y)로 정한다(O-A4) — 인식 뒤 손끝이
                                        // 흔들려도 다른 칸으로 바뀌지 않게. 눈금 반올림·자정 넘김은
                                        // Store.emptyPressStartDate가 한다(REQ-013 단일 출처). 지난 시각도
                                        // 막지 않는다(O-A8 — 카드의 과거 알림 노트가 경고한다).
                                        emptyPressCandidate = Store.emptyPressStartDate(day: date,
                                                                                        minutesFromMidnight: Double(pressed))
                                        hapticPressRecognized()
                                        return true
                                    },
                                    onChange: { dy in
                                        let rawMinutes = Double(dy) / Double(hourHeight) * 60
                                        var requested = Int(rawMinutes.rounded())
                                        if let drag = activeDrag, case .activity(let a) = drag.kind {
                                            // 활동 블록의 요청은 시작이 눈금에 놓이는 Δ로 만든다(REQ-010 —
                                            // Δ 배수가 아니라 눈금). moveActivity 자체는 눈금을 넣지 않는다:
                                            // 편집 경로(Store의 modifyActivity)가 정확 Δ를 유지한다(AC-008 (4)).
                                            requested = Store.gridSnappedDelta(from: a.startDate, requestedMinutes: requested)
                                        }
                                        // 구간 드래그는 소유 여부와 무관하게 가장자리 바깥 함수로 유효 Δ와
                                        // 상태를 함께 받는다(REQ-008·D-14 (가) — 요청은 1분 정밀도 그대로
                                        // 넘기고 눈금 접기는 그 안의 effectiveDragMinutes가 한다, REQ-010.
                                        // 미리보기(두 span)와 드롭(adjustTravelLeg)이 같은 함수를 읽게 하는
                                        // 단일 출처다). 붙음은 Δ가
                                        // 가장자리에 닿는 값으로 접혀 들어오므로 미리보기 블록이 저절로
                                        // 가장자리에 붙고, 상태는 ActiveDrag가 들고 그림은 그 값만 읽는다.
                                        if let drag = activeDrag, case .event(let leg) = drag.kind {
                                            let outcome = store.dragEdgeOutcome(leg: leg, owner: drag.owner,
                                                                                requestedMinutes: requested,
                                                                                pressedOn: drag.pageDate)
                                            requested = outcome.deltaMinutes
                                            // @MX:NOTE 진동은 넘김에 들어서는 순간에만 한 번(D-14 (가) ③)
                                            // — onChange마다 울리면 문턱 근처에서 손가락이 조금만 흔들려도
                                            // 진동이 반복된다. 직전 상태와 비교하는 것은 이 한 줄뿐이다.
                                            if outcome.state == .crossed, drag.edgeState != .crossed {
                                                hapticEdgeCrossed()
                                            }
                                            activeDrag?.edgeState = outcome.state
                                            // 방향도 같은 곳에서 한 번만 정한다(N1) — 붙음에서 Δ가
                                            // 0으로 접혀도 요청의 부호는 여기 들어온다.
                                            activeDrag?.direction = outcome.direction
                                        }
                                        activeDrag?.deltaMinutes = requested
                                    },
                                    onEnd: { committed in
                                        guard let drag = activeDrag else { return }
                                        activeDrag = nil
                                        if committed && drag.deltaMinutes != 0 { finalizeDrag(drag) }
                                    },
                                    onEmptyEnd: { committed in
                                        // 카드는 손을 뗄 때만 뜬다(O-A4) — 취소·실패로 끝나면 시드를 버린다.
                                        if committed, let seed = emptyPressCandidate {
                                            emptyPressSeed = EmptyPressSeed(start: seed)
                                        }
                                        emptyPressCandidate = nil
                                    },
                                    onTap: { x, y in
                                        // 확정 중의 탭은 감속하는 쪽을 멈추기만 한다(sim 재현: 미끄러지는 중 탭이 활동 편집 시트를 열었다).
                                        guard !pagerSettle.settling else { return }
                                        guard let found = block(atX: x, y: y, in: placed, total: geo.size.width) else { return }
                                        switch found {
                                        case .event(let e): selection = e.id
                                        case .activity(let a): selectedActivityId = a.id
                                        }
                                    }
                                )
                            )
                            #endif
                        }
                        .frame(height: CGFloat(hourCount) * hourHeight)
                    }
                    .frame(height: CGFloat(hourCount) * hourHeight, alignment: .topLeading)
                }
                .padding(.horizontal)
                // 우하단 besir 로고 버튼(REQ-007)이 마지막 칸을 덮지 않게 하는 여백이다 — 버튼
                // 56 + 바닥 여백 20. RootView 오버레이가 화면을 덮는 만큼 스크롤 끝에서 비워 둔다.
                .padding(.bottom, 76)
                // 이 페이지 ScrollView를 날 키로 레지스트리에 등록하는 프로브(0×0 배경 — 레이아웃에는
                // 영향이 없다). ScrollView 콘텐츠 안쪽에 두어 조상 걷기가 바깥 페이저가 아니라 이
                // 페이지의 스크롤 뷰를 찾게 한다.
                .background {
                    PageScrollProbe(day: date).frame(width: 0, height: 0)
                }

                if dayEvents.isEmpty && dayActivities.isEmpty {
                    Text("No events").foregroundStyle(Theme.faint).font(.caption).padding()
                }
            }
            // 블록을 꾹 눌러 드래그하는 동안만 스크롤을 잠가 화면 스크롤과 블록 이동이 서로 방해하지
            // 않게 한다(평소엔 블록 위에서 시작한 스와이프도 정상적으로 화면을 스크롤할 수 있어야 함).
            // 활동·소유 구간·소유 없는 구간 드래그를 가리지 않는다 — 드래그 중 잠금은 이 하나뿐이다
            // (0.9.0 — 연장·자동 스크롤과 함께 팬 잠금 대체안도 거뒀다, §13 #18).
            // 가로 넘김과의 중재는 UIKit이 한다 — 가로 페이징 스크롤 안의 세로 스크롤은 먼저 움직인 축이 이긴다.
            .scrollDisabled(activeDrag != nil)
    }

    /// 따라가기 도착 스크롤의 실행 지점(0.9.1 수리 라운드 3, F4 · 수리 S) — 관찰 블록의 전역
    /// 프레임이 제자리에 닿았다고 판정되면 contentOffset을 직접 쓴다. 안착 x는 '거터 48 +
    /// 그 블록의 열 x'다. 거터 48(안쪽 여백 16 + 시간 라벨 28 + HStack 간격 4)은 리드 실측값
    /// (arrivalGutter)이고, 열 x는 그리기가 쓰는 columnFrame 값을 관찰자가 붙는 자리에서 그대로
    /// 받는다(계약 5 — 판정이 그리기와 다른 산술을 따로 두지 않는다). 첫 열(x=0)의 안착 x가
    /// 실측 48과 같은 식이며, 겹침으로 2열 이상에 놓인 도착 블록도 자기 열에 안착하면 발화한다
    /// (수리 S 이전엔 첫 열 x만 맞아 2열 이상이면 영영 발화하지 않았다 — md-091-repair-r4-column).
    /// 프레임이 안착 x를 '지나가며' 변하지 않고 처음부터 안착 x에 나타나는 길(이틀 넘어 따라가기
    /// 처럼 슬라이드 없이 같은 트랜잭션으로 페이지가 갈리는 경우)도 있으므로 appear와 change
    /// 두 지점에서 같은 판정을 돌리고, 정확히 한 번은 pendingArrival 소비가 보장한다 — offset
    /// 쓰기가 블록 프레임(minY)을 바꿔 change가 다시 발화해도 pendingArrival가 이미 nil이라
    /// 재진입하지 않는다. change 경로에 '밴드 바깥→안' 방향 문을 붙이는 안은 뺐다 — 자정 넘는
    /// 구간은 같은 블록 id가 두 날 페이지에 함께 나열되어 페이지 갈림에서 뷰가 새로 만들어지지
    /// 않으므로 change가 유일한 발화 경로인데, 그때 열 위치가 같으면(밴드 안→안) 방향 문이
    /// 정상 따라가기를 막는다.
    private func settleArrivalIfNeeded(page: Date, block: PositionedBlock, columnX: CGFloat, frame fr: CGRect) {
        // 수리 3b 진단: 대기가 있는데 문에서 돌아가면 어느 문인지 남긴다 — 정적 페이지는 프레임이
        // 다시 변하지 않아 조용한 실패에 재기회가 없다(관측: 로그 0줄). 대기 없는 조용한 반환은
        // 소비 뒤 잔여 관찰이라 그대로(로그 없음). 슬라이드 중에는 가로문이 프레임마다 잠시 걸려
        // 몇 줄 몰리는 게 정상이다.
        if let waiting = pendingArrival {
            let expected = Self.arrivalGutter + columnX
            if abs(fr.minX - expected) >= 1 {
                arrivalLog.notice("arrival check, horizontal gate: block=\(block.id, privacy: .public) minX=\(Int(fr.minX)) expected=\(Int(expected))")
            } else if !calendar.isDate(page, inSameDayAs: waiting.day) {
                arrivalLog.notice("arrival check, day gate: block=\(block.id, privacy: .public) page=\(dayTitle(page), privacy: .public) waitingDay=\(dayTitle(waiting.day), privacy: .public)")
            }
        }
        guard abs(fr.minX - (Self.arrivalGutter + columnX)) < 1,
              let arrival = pendingArrival,
              calendar.isDate(page, inSameDayAs: arrival.day) else { return }
        pendingArrival = nil
        scrollArrivalBlock(day: page, block: block, blockHeight: fr.height)
    }

    /// 도착 스크롤의 실제 쓰기(REQ-015 (3), 0.9.1 수리 라운드 3) — 페이지의 UIScrollView에
    /// contentOffset을 직접 지정한다. scrollTo가 그려진 위치(offsetY)와 다른 위치로 해석해
    /// 떨어졌기 때문(측정 2차 — ≈258pt 일정 낙차)에 그 원인에 기대지 않고, 블록 윗변이 뷰
    /// 높이의 위 1/3에 오게 하는 값은 그리기와 같은 출처(offsetY)에서, 블록 높이는 관찰된
    /// 프레임에서 읽는다(계약 5 — 이 산술은 여기 한 곳만 한다). 애니메이션 없이 놓는다 —
    /// 안착 순간은 페이저 스냅 뒤 첫 레이아웃이라 여기 애니메이션을 섞으면 같은 갱신에
    /// 레이아웃이 한 번 더 흔들리고, 착지와 함께 이미 제자리에 보이는 점프가 측정 기대값과도
    /// 곧장 일치한다. 등록이 없으면(프로브가 아직 안 찍힘) miss 로그 한 줄만 남기고 돌아간다 —
    /// 이 길이 아니면 따라가기가 조용히 사라지므로 없음도 관측이어야 한다(운영자 채택 제안 B).
    /// macOS 보존 코드는 도착 스크롤을 하지 않는다(iOS 완성 뒤 맥 포트 때 다시 붙인다).
    private func scrollArrivalBlock(day: Date, block: PositionedBlock, blockHeight: CGFloat) {
        #if os(iOS)
        guard let sv = PageScrollRegistry.byDay[calendar.startOfDay(for: day)]?.value else {
            arrivalLog.notice("arrival scroll miss — no page scroll view registered, day \(dayTitle(day), privacy: .public)")
            return
        }
        let y = offsetY(for: block) + blockHeight / 3 - sv.bounds.height / 3
        let ceiling = sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height
        // 수리 3b 진단: 쓰기까지 왔다는 것과 쓴 값을 남긴다 — 관측(로그 0줄)은 쓰기 자체가
        // 없었음을 뜻했지만, 쓰고도 효과가 없던 갈래와 이 로그로 가른다.
        arrivalLog.notice("arrival scroll applied: block=\(block.id, privacy: .public) y=\(Int(y)) ceiling=\(Int(ceiling)) previous=\(Int(sv.contentOffset.y)) day=\(dayTitle(day), privacy: .public)")
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: min(max(y, 0), ceiling)), animated: false)
        #endif
    }

    /// 자리가 정해진 블록 하나를 그린다(종류에 맞는 뷰 선택). date는 그리는 날 — 자정을
    /// 넘는 블록의 잘린 범위 계산에 쓰인다.
    @ViewBuilder
    private func blockView(for p: PositionedBlock, on date: Date) -> some View {
        switch p.kind {
        case .activity(let a):
            activityBlockView(a, on: date)
        case .event(let e):
            // 이동시간 계산 실패(API 할당량 소진 등)는 조용히 숨기지 않고 따로 표시한다.
            // 판정은 앵커 함수 하나가 낸다(REQ-023) — 출발 기준인데 출발만 저장된 모양(재추정 실패의
            // 옛 도착·새로 만든 출발=도착)도 경고 블록이 되고, 레코드 생김새를 여기서 다시 해석하지 않는다.
            // 경고 블록의 세로 자리도 계산된 구간과 같은 span(for:on:)이 낸다(REQ-016 — 앵커 붙은
            // 10분 구간, 옛 "앵커 분에서 아래로 고정 높이"는 폈다).
            if e.failedBlockAnchor != nil { failedEstimateBlockView(e, on: date) } else { travelBlockView(e, on: date) }
        }
    }

    /// 드래그 중이면 그만큼(분) 더해 미리보기 위치를 보여준다.
    private func offsetY(for p: PositionedBlock) -> CGFloat {
        let drag: CGFloat
        switch p.kind {
        case .activity(let a): drag = dragOffsetMinutes(forActivity: a.id)
        case .event(let e): drag = dragOffsetMinutes(forEvent: e.id)
        }
        return (p.start + drag) / 60 * hourHeight
    }

    private func minutesSinceMidnight(_ d: Date) -> CGFloat {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return CGFloat((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// 블록이 화면에서 실제로 그려지는 최소 높이(분 환산). 이 값보다 짧은 일정도 눈에 보이게
    /// 이만큼은 그리므로, 히트 테스트 범위도 반드시 같은 값을 써야 한다 — 예전엔 렌더와 히트
    /// 테스트가 따로 계산돼 "보이는데 탭이 안 되는" 짧은 블록 문제가 있었다. 그리기 전용 값이다 —
    /// 드래그가 만들 수 있는 가장 짧은 활동이 눈금 위 10분이 된 뒤로는 값이 달라져도 폼이 1분
    /// 단위라 5분 활동은 여전히 존재하므로 바닥은 그대로 둔다. 5분 이상 활동은 모두 실제 길이로
    /// 그려진다.
    private static let minActivityMinutes: CGFloat = 5
    private static let minTravelMinutes: CGFloat = 16
    /// 깨진 레코드(travelSeconds 있는데 출발 없음) 폴백 그리기의 고정 높이(pt). 계산 실패 블록은
    /// 0.2.6(t82 REQ-016)부터 listedSpan 10분 구간으로 그려 이 경로를 쓰지 않는다.
    private static let failedBlockHeight: CGFloat = 20
    /// 같은 줄에 놓인 블록 사이 간격(pt) — 칸 경계에만 들어가고 묶음 안쪽 나눔에는 안 들어간다.
    /// 렌더와 히트테스트가 같은 값을 쓰는지는 `SlotRange.points`가 보증한다.
    private static let columnGap: CGFloat = 3
    /// 따라가기 도착의 안착 판정에서 블록 영역 왼쪽에 더해지는 거터(pt) — 기본 안쪽 여백 16 +
    /// 시간 라벨 폭 28 + HStack 간격 4의 합계 48로, 리드가 t52-7 실측으로 확정한 값이다.
    /// 블록의 안착 x는 이 거터 + 자기 열 x(columnFrame)다(수리 S — 열 배치와 무관하게 발화).
    private static let arrivalGutter: CGFloat = 48

    /// 구간 드래그의 이동량(유효 Δ, 분)을 한 곳에서 낸다(REQ-009 — 미리보기 = 확정).
    /// 끌리는 구간 자신(legId)은 소유 여부와 무관하게 Δ를 받는다 — 소유 없는 짧은 구간도
    /// 평행이동이 아니라 옮긴 시각의 span으로 그려야 놓았을 때 모양이 그대로다(0.9.1 N2,
    /// 저장 갈래의 최소 높이 규칙이 0시 경계에서 비선형이라 평행이동과 값이 어긋난다).
    /// 소유 활동(activityId) 갈래는 소유 있을 때만 — 소유 없는 끌림이 남의 활동을 움직이면
    /// 안 된다. 두 span이 이 값으로 옮긴 범위를 만들고 dragOffsetMinutes는 끌림 구간의
    /// 평행이동을 이 값으로 걷는다(같은 블록이 두 번 움직이지 않게). 소유 조회는 onBegin이
    /// 이미 끝냈다 — 여기서 다시 찾지 않는다(AC-007).
    /// t71(REQ-012): 드래그가 끝나도 반복 선택창이 떠 있는 동안엔 seriesPreview가 같은 Δ를
    /// 들고 있다 — activeDrag를 본 뒤 이어 보는 한 몸통으로 읽는다. 두 상태를 각자 읽는 판정이
    /// 둘로 늘어나면 선택창 동안 그림이 끌기 중 그림과 어긋난다(계약 5). 활동 미리보기도 같은
    /// 몸통의 마지막 갈래로 여기서만 읽힌다.
    private func legDragShift(legId: ScheduledEvent.ID? = nil, activityId: ActivityBlock.ID? = nil) -> Int {
        guard let drag = activeDrag ?? seriesPreview?.drag, case .event(let e) = drag.kind else {
            if let drag = seriesPreview?.drag, case .activity(let a) = drag.kind, activityId == a.id {
                return drag.deltaMinutes
            }
            return 0
        }
        if legId == e.id { return drag.deltaMinutes }
        if let owner = drag.owner, activityId == owner.id { return drag.deltaMinutes }
        return 0
    }

    /// 일간 시간표에서 블록이 차지하는 세로 범위(자정 기준 분). 렌더링 위치·높이와 히트 테스트가
    /// 반드시 같은 값을 보도록 여기 한 곳에서만 계산한다. 자정을 넘는 블록은 이틀에 나뉘어
    /// 그려지므로 "그리는 날"(on)을 받아 그 날의 고정 창(0시~24시, REQ-009)으로 자른다 —
    /// 호출자가 제각각 자르면 렌더와 히트 테스트가 어긋나는, 이 함수가 원래 하나로 묶으려
    /// 했던 문제가 다시 생긴다.
    private func span(for activity: ActivityBlock, on date: Date) -> (start: CGFloat, minutes: CGFloat) {
        // 소유 활동이 끌리는 중에는 먼저 옮긴 시각을 만든다 — 오는 편 드래그는 활동 끝이, 가는 편
        // 드래그는 활동 시작이 유효 Δ만큼 움직이고 반대쪽은 그대로(REQ-001·002와 같은 방향 —
        // 미리보기가 곧 확정값이므로 드래그 중에도 확정과 같은 모양으로 그린다).
        var startDate = activity.startDate
        var endDate = activity.endDate
        // 선택창 미리보기 중인 활동(REQ-012, 수리 3c)은 Δ만큼 **통째로** 옮긴 범위로 그린다 —
        // 나열·그리기가 옮긴 시각을 봐야 놓은 날 페이지에 블록이 나열되고 관찰자가 붙는다(진단
        // 로그: 놓은 날에는 관찰자가 한 번도 등장하지 않았다). Δ는 legDragShift와 같은 상태를
        // 읽는다(한 읽기 함수). 끌기 중(activeDrag) 활동은 offsetY의 dragOffsetMinutes가
        // 미리보기를 맡으므로 여기서 두 번 움직이지 않게 활동 갈래를 나눈다.
        if activeDrag == nil, case .activity(let pa)? = seriesPreview?.drag.kind, pa.id == activity.id {
            let delta = TimeInterval(legDragShift(activityId: activity.id)) * 60
            startDate = startDate.addingTimeInterval(delta)
            endDate = endDate.addingTimeInterval(delta)
        }
        let shift = legDragShift(activityId: activity.id)
        if shift != 0, case .event(let leg)? = (activeDrag ?? seriesPreview?.drag)?.kind {
            let delta = TimeInterval(shift) * 60
            if (leg.anchor ?? .arrival) == .departure {
                endDate = endDate.addingTimeInterval(delta)      // 오는 편 → 끝을 늘린다
            } else {
                startDate = startDate.addingTimeInterval(delta)  // 가는 편 → 시작을 민다
            }
        }
        let dayStart = calendar.startOfDay(for: date)
        let clippedStart = max(startDate, dayStart)
        let clippedEnd = min(endDate, dayStart.addingTimeInterval(24 * 3600))
        // 옮긴 범위가 그 날에 남지 않으면 (start, 0)을 돌려 positionedBlocks가 건너뛰게 한다(REQ-009)
        // — 최소 높이로 늘려 그리면 하루 끝에 없는 토막이 생긴다. 저장된 블록(나열 판정이 그 날과
        // 겹침을 보장)과 시작 = 끝인 깨진 레코드는 이 갈래에 오지 않고 오늘처럼 최소 높이로 그린다.
        guard clippedEnd > clippedStart else {
            if shift != 0 { return (0, 0) }
            let s = calendar.isDate(activity.startDate, inSameDayAs: date) ? minutesSinceMidnight(activity.startDate) : 0
            return (s, Self.minActivityMinutes)
        }
        // 잘린 반쪽이 최소 높이에 못 미쳐도 늘리는 방향은 그대로 아래로 둔다. 늘리지 않으면 그
        // 조각은 보이지도 탭되지도 않는 블록이 되고(이 값은 렌더와 히트 테스트가 함께 쓴다),
        // 반대 방향(위로)은 자리가 없다 — 자정 직전에 잘린 반쪽이 위로 늘면 그 날의 이웃을 덮는다.
        // 밑으로 넘치는 몇 분은 그 날 화면 밖이라 아무것도 덮지 않는다.
        // 분 단위로 자른다(초는 내린다) — 외부 가져오기·AI가 만든 시각은 초가 0이 아닐 수 있는데,
        // 초까지 반영하면 10:00:30~11:00:30 활동과 11:00:30 복귀 다리가 반쪽 폭으로 갈라진다.
        // b59fcaa 기준선의 minutesSinceMidnight(시*60+분, 초 버림)와 같은 의미이며 초가 0이면
        // 내림이 항등이므로 기존 그림은 바이트 단위로 그대로다.
        let start = CGFloat((clippedStart.timeIntervalSince(dayStart) / 60).rounded(.down))
        let end = CGFloat((clippedEnd.timeIntervalSince(dayStart) / 60).rounded(.down))
        return (start, max(Self.minActivityMinutes, end - start))
    }

    private func span(for event: ScheduledEvent, on date: Date) -> (start: CGFloat, minutes: CGFloat) {
        let dayStart = calendar.startOfDay(for: date)
        // 하루 창은 24시간 고정(REQ-009, 0.9.0 — 연장 거둠).
        let limit: CGFloat = 1440
        // 넘김 중인 끌린 구간은 눌렀던 날 페이지에서 지운다(D-14 (가) ③ — 소유 없는 구간도 같은
        // 규칙이다). 착지 시각은 가장자리 칩이 미리 보여 준다. positionedBlocks가 minutes 0을
        // 건너뛰므로 그려지지도 눌리지도 않는다. 반복 선택창 미리보기(t71)도 같은 지움을 가져야
        // 놓은 날 페이지에만 블록이 보인다(REQ-012) — 같은 읽기(legDragShift)로 seriesPreview를
        // 이어 본다.
        if let drag = activeDrag ?? seriesPreview?.drag, case .event(let e) = drag.kind, e.id == event.id,
           drag.edgeState == .crossed, calendar.isDate(drag.pageDate, inSameDayAs: date) {
            return (0, 0)
        }
        // 끌리는 구간은 소유 여부와 무관하게 시각에 유효 Δ를 더해 옮긴 뒤 그 날의 고정 창(0~24시)
        // 안에서 그린다(REQ-009, 0.9.1 N2 — 소유 없는 구간도 미리보기가 확정과 같은 함수를
        // 밟는다) — 평행이동 미리보기(dragOffsetMinutes)를 겹쳐 쓰지 않는다. 옮긴 범위가 그 날에
        // 남지 않으면 (start, 0)을 돌려 positionedBlocks가 건너뛰게 한다 — 창 밖이나 0시 앞에 토막을
        // 그리면 놓을 자리를 잘못 읽게 한다.
        let shift = legDragShift(legId: event.id)
        if shift != 0 {
            let delta = TimeInterval(shift) * 60
            // 계산 성공·실패(REQ-016) 모두 listedSpan의 구간을 Δ만큼 옮겨 그 날의 고정 창 안에서
            // 그린다 — 미리보기가 확정과 같은 모양이다(0.9.1 N2와 같은 이유).
            guard let span = event.listedSpan else {
                let m = CGFloat(event.arrivalDate.addingTimeInterval(delta).timeIntervalSince(dayStart) / 60)
                guard m >= 0, m < limit else { return (0, 0) }
                return (m, Self.failedBlockHeight / hourHeight * 60)
            }
            let depMin = min(max(CGFloat(span.start.addingTimeInterval(delta).timeIntervalSince(dayStart) / 60), 0), limit)
            let arrivalMin = min(max(CGFloat(span.end.addingTimeInterval(delta).timeIntervalSince(dayStart) / 60), 0), limit)
            guard arrivalMin > depMin else { return (0, 0) }
            let natural = arrivalMin - depMin
            guard natural < Self.minTravelMinutes else { return (depMin, natural) }
            // 최소 높이로 늘리는 방향은 고정된 쪽의 반대 — 아래 저장된 구간의 규칙과 같다.
            if (event.anchor ?? .arrival) == .departure {
                return (depMin, Self.minTravelMinutes)                                   // 출발 고정 → 아래로
            }
            return (max(0, arrivalMin - Self.minTravelMinutes), Self.minTravelMinutes)    // 도착 고정 → 위로
        }
        // 이하는 저장된 구간. 계산 성공·실패(REQ-016, t82) 모두 listedSpan의 [시작, 끝]을 그리는
        // 날 창(0~24시)으로 잘라 그린다 — 실패 블록도 가는 편 [앵커−10분, 앵커]·오는 편
        // [앵커, 앵커+10분] 구간이라 계산된 구간과 같은 길을 걷고, 짧아서 늘릴 때도 같은 산식
        // (고정 쪽 반대)을 탄다. 나열 판정(isListed)도 같은 listedSpan을 읽는다(계약 5).
        guard let span = event.listedSpan else {
            // 여기 오는 건 이동시간은 계산됐는데 출발이 없는 깨진 레코드뿐이다(nil을 만드는 곳은
            // travelSeconds도 같이 비운다). 도착 시각에서 아래로 그려 옛 경고 모양으로 폴백한다.
            return (minutesSinceMidnight(event.arrivalDate), Self.failedBlockHeight / hourHeight * 60)
        }
        // 구간 양끝을 그리는 날의 0~24시 안으로 자른다 — 전날 밤에 출발해 자정을 넘겨 도착하는
        // 구간은 출발 시각(예: 23:30)을 그대로 쓰면 도착일 화면의 엉뚱한 자리에 그려지므로 도착일
        // 에서는 0시부터, 출발일에서는 그 날 끝까지. 자정을 넘는 이동이 이틀에 각각 반쪽씩
        // 그려지는 것(결함 G)은 이 자르기와 나열(events(on:)의 겹침 판정)이 함께 완성한다.
        let depMin = calendar.isDate(span.start, inSameDayAs: date) ? minutesSinceMidnight(span.start) : 0
        let arrivalMin = calendar.isDate(span.end, inSameDayAs: date)
            ? minutesSinceMidnight(span.end) : limit
        let natural = arrivalMin - depMin
        guard natural < Self.minTravelMinutes else { return (depMin, natural) }

        // 너무 짧아 최소 높이로 그려야 할 때, **늘어나는 방향은 고정된 쪽의 반대**여야 한다.
        // 도착 기준 구간을 아래로 늘리면 도착 시각에 바로 시작하는 활동 블록을 덮어버린다
        // (도보 1분 거리 식당을 잡았을 때 이동 블록이 식사 블록과 겹쳐 보이던 원인).
        // 잘린 반쪽에도 이 규칙을 그대로 적용한다 — 규칙이 지키려는 것(고정된 끝에 붙어 시작하는
        // 블록을 덮지 않기)은 실제 출발·도착이 붙은 날의 반쪽에서 여전히 옳고, 반쪽끼리만 예외
        // 방향을 만들면 규칙이 둘로 갈라져 어느 쪽이 맞는지 판단이 흐려진다.
        if (event.anchor ?? .arrival) == .departure {
            return (depMin, Self.minTravelMinutes)                                   // 출발 고정 → 아래로
        }
        return (max(0, arrivalMin - Self.minTravelMinutes), Self.minTravelMinutes)    // 도착 고정 → 위로
    }

    /// 드래그 중인 블록이면 그 만큼(분) 임시로 더해 미리보기 위치를 보여준다. 반복 선택창
    /// 미리보기(t71)도 같은 값 — legDragShift와 같은 순서(activeDrag 뒤 seriesPreview)로 읽는다.
    private func dragOffsetMinutes(forActivity id: ActivityBlock.ID) -> CGFloat {
        guard let drag = activeDrag ?? seriesPreview?.drag, case .activity(let a) = drag.kind, a.id == id else { return 0 }
        // 선택창 미리보기 중인 활동은 span이 이미 Δ만큼 통째로 옮긴 범위로 그린다(수리 3c) —
        // 여기서 또 평행이동하면 같은 블록이 2Δ로 움직인다. 구간 쪽 legDragShift 가드와 같은
        // 이유이고, 판정 조건은 span의 activity 갈래와 글자로 같은 읽기로 맞춘다(계약 5 —
        // 둘이 따로 읽으면 나중에 다시 어긋난다). 끌기 중(activeDrag) 미리보기는 여기가 맡는다.
        if activeDrag == nil, case .activity(let pa)? = seriesPreview?.drag.kind, pa.id == id { return 0 }
        return CGFloat(drag.deltaMinutes)
    }

    private func dragOffsetMinutes(forEvent id: ScheduledEvent.ID) -> CGFloat {
        guard let drag = activeDrag ?? seriesPreview?.drag, case .event(let e) = drag.kind, e.id == id else { return 0 }
        // 끌림 구간의 미리보기는 소유 여부와 무관하게 span이 옮긴 범위로 이미 그린다
        // (legDragShift가 Δ를 주는 블록, 0.9.1 N2 — 소유 없는 구간도 평행이동 대신 같은 span) —
        // 여기서 또 평행이동하면 같은 블록이 두 번 움직인다(REQ-009). Δ 0(접힌 붙음 포함)에서는
        // legDragShift도 0이라 아래 값도 0이고 그림이 그대로다.
        if legDragShift(legId: id) != 0 { return 0 }
        return CGFloat(drag.deltaMinutes)
    }

    /// 가장자리 넘김 칩의 착지 시각("00:20" 꼴) — DateFormatter 생성 비용이 커서 정적 하나만
    /// 만든다(위 weekdayFormatter와 같은 이유).
    private static let edgeChipTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "h:mm a"; return f
    }()

    /// 끄는 중 가장자리 표시(D-14 (가)) — 붙음은 그 날에 남는다는 안내 표지, 넘김은 착지 시각을
    /// 미리 보여 주는 칩(놓으면 그 날로 따라간다). 색은 전부 Theme 토큰(계약 6): 붙음은 조용한
    /// 안내(muted), 넘김은 이동(travel) — 진동과 한 쌍인 확실한 신호 쪽이다. 모양은 이 방향의
    /// 다른 표시와 같이 가는 선 테두리(카드·그림자 없음).
    @ViewBuilder
    private func edgeIndicator(for leg: ScheduledEvent, state: Store.DragEdgeState,
                               downward: Bool, deltaMinutes: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius)
        switch state {
        case .inside:
            EmptyView()
        case .held:
            Text(downward ? "Until midnight" : "From midnight")
                .font(.caption2).foregroundStyle(Theme.muted)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.bg, in: shape)
                .overlay(shape.stroke(Theme.line))
        case .crossed:
            // 착지 시각 = 끌린 구간의 나열 시작(listedSpan의 시작 — 실패 블록·깨진 레코드는 출발
            // 대신 구간/도착)을 유효 Δ만큼 민 값 — 미리보기와 드롭이 같은 Δ(dragEdgeOutcome)를
            // 쓰므로 칩의 시각이 곧 놓일 시각이다.
            let listingStart = leg.listedSpan?.start ?? leg.departureDate ?? leg.arrivalDate
            let landing = listingStart.addingTimeInterval(TimeInterval(deltaMinutes) * 60)
            Text("\(downward ? "▾ Next day" : "▴ Previous day") \(Self.edgeChipTimeFormatter.string(from: landing))")
                .font(.caption2).foregroundStyle(Theme.travel)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.bg, in: shape)
                .overlay(shape.stroke(Theme.line))
        }
    }

    /// 넘김 진동(D-14 (가) ③) — 상태 판정은 Store 바깥 함수가 하고 여기선 울리기만 한다.
    /// 불리는 곳이 iOS 오버레이 콜백 안뿐이지만 이 파일은 macOS도 함께 컴파일하므로 분기한다.
    private func hapticEdgeCrossed() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// 꾹 누름 인식 진동(REQ-011, t70) — 블록 위 길(onBegin)과 빈칸 길(onEmptyBegin)이 같은 것을
    /// 읽는다(O-A9 — 같은 진동 한 번). hapticEdgeCrossed와 같은 '상태 변화 시 1회' 원칙으로,
    /// 인식 순간에 호출하는 두 갈래가 이 도우미 하나를 공유해 두 진동 규칙이 갈라지지 않게 한다.
    private func hapticPressRecognized() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func activityBlockView(_ a: ActivityBlock, on date: Date) -> some View {
        let isDragging = activeDrag?.blockId == "a-\(a.id)"
        let minutes = span(for: a, on: date).minutes
        let past = a.endDate < Date()
        return VStack(alignment: .leading, spacing: 1) {
            Text(a.title).font(.caption).foregroundStyle(Theme.activityInk).lineLimit(1)
            if let loc = a.location, !loc.name.isEmpty, minutes >= 40 {
                // 장소는 블록이 넉넉할 때만 — 짧은 블록에 두 줄을 넣으면 읽히지도 않고 잘린다.
                Text(loc.name).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .padding(.leading, 9)
        .padding(.vertical, 4)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: minutes / 60 * hourHeight, alignment: .topLeading)
        .clipped()   // 짧은 활동에서 글자가 블록 밖으로 새어 나가지 않게
        .blockSurface(fill: Theme.activityFill, rail: Theme.activity, emphasized: isDragging)
        .opacity(past ? 0.45 : 1)   // 지나간 일정은 흐리게 — 남은 일정이 먼저 눈에 들어오도록
        .contentShape(Rectangle())
        // iOS에서는 시간표를 덮는 RescheduleOverlay가 탭을 좌표로 판단해 처리하므로 여기 onTapGesture는
        // 도달하지 않는다(무해한 죽은 코드). macOS에서는 이 탭이 그대로 쓰인다.
        .onTapGesture { selectedActivityId = a.id }
        .scaleEffect(x: 1, y: isDragging ? 1.06 : 1, anchor: .top)
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }

    /// 이동시간을 계산 못한 일정(API 할당량 소진 등)도 조용히 숨기지 않고 표시한다.
    /// iOS에서는 탭을 시간표 전체를 덮는 RescheduleOverlay의 UITapGestureRecognizer가 처리하므로
    /// (그 오버레이가 히트 테스트를 가로채 여기 onTapGesture는 호출되지 않는다) macOS에서만 필요하지만,
    /// 남겨둬도 iOS에서는 그냥 도달하지 않는 죽은 코드일 뿐이라 무해하다.
    private func failedEstimateBlockView(_ event: ScheduledEvent, on date: Date) -> some View {
        // 높이는 span의 분 높이에서 낸다(travelBlockView와 같은 모양) — REQ-016(t82)부터 실패
        // 블록도 listedSpan 10분 구간을 그리므로 그리기·히트테스트가 같은 span을 읽는다(계약 5).
        let height = span(for: event, on: date).minutes / 60 * hourHeight
        return HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
            Text(event.title).font(.caption2).lineLimit(1)
        }
        .foregroundStyle(Theme.warn)
        .padding(.leading, 9)
        .padding(.vertical, 4)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        .clipped()
        .blockSurface(fill: Theme.warnFill, rail: Theme.warn, emphasized: false)
        .contentShape(Rectangle())
        .onTapGesture { selection = event.id }
    }

    private func travelBlockView(_ event: ScheduledEvent, on date: Date) -> some View {
        let isDragging = activeDrag?.blockId == "e-\(event.id)"
        let height = span(for: event, on: date).minutes / 60 * hourHeight
        let past = event.arrivalDate < Date()
        // 활동에 묶인 이동 구간(식당 왕복 등)은 제목을 그리지 않는다 — 대개 도보 몇 분이라
        // 블록이 최소 높이로 그려지는데, 글자가 그 안에 안 들어가 옆 블록 위로 삐져나와 겹쳐 보였다.
        // 바로 옆 활동 블록에 이미 제목이 있어 무엇을 위한 이동인지는 충분히 드러난다.
        // 링크가 **살아 있는지**는 조회로 본다(AC-005 (3)) — linkedActivityId만 보면 활동이 지워진
        // 매달린 링크가 연결된 것처럼 제목을 숨긴다.
        let showsTitle = store.activity(forLeg: event) == nil
        // 아이콘조차 들어가지 않을 만큼 낮으면 색 띠만 남긴다.
        let showsIcon = height >= 20
        return HStack(spacing: 4) {
            if showsIcon {
                Image(systemName: event.mode.systemImage).font(.caption2).foregroundStyle(Theme.travel)
            }
            if showsTitle {
                Text(event.title).font(.caption2).foregroundStyle(Theme.travelInk).lineLimit(1)
            }
        }
        .padding(.leading, showsIcon || showsTitle ? 9 : 0)
        .padding(.vertical, showsIcon || showsTitle ? 4 : 0)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        // 내용이 블록 밖으로 넘쳐 이웃 블록을 덮지 않게 잘라낸다(짧은 블록에서 생기던 문제).
        .clipped()
        .blockSurface(fill: Theme.travelFill, rail: Theme.travel, emphasized: isDragging)
        .opacity(past ? 0.45 : 1)
        .contentShape(Rectangle())
        // iOS에서는 시간표 전체를 덮는 RescheduleOverlay가 탭/드래그 모두 좌표로 판단해 처리하므로
        // 여기 onTapGesture는 도달하지 않는다(무해한 죽은 코드). macOS에서는 이 탭이 그대로 쓰인다.
        .onTapGesture { selection = event.id }
        .scaleEffect(x: 1, y: isDragging ? 1.06 : 1, anchor: .top)
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }


    // MARK: - 겹친 블록 나란히 배치

    /// 화면에 놓일 자리가 정해진 블록. 가로 범위는 칸 함수가 낸 [lo, hi]를 통째로 든다 —
    /// 렌더(columnFrame)와 히트테스트(block(atX:))가 이 값을 그대로 읽는다(AC-016).
    private struct PositionedBlock: Identifiable {
        let id: String
        let kind: ActiveDrag.Kind
        let start: CGFloat      // 자정 기준 분
        let minutes: CGFloat
        let range: ScheduleLogic.SlotRange
    }

    /// 하루치 블록을 겹침·묶음 배치로 자리 정한다.
    ///
    /// 배치 산술 전부는 `ScheduleLogic.overlapSlots`(Models.swift)이 한다 — 뷰가 칸 계산을
    /// 따로 들고 있으면 렌더와 히트테스트가 어긋난다(AC-016). 여기는 레코드를 (id, start, end)로
    /// 펴서 넣고 결과를 다시 블록으로 매핑하기만 한다. 범위는 그리는 날(on)로 잘라 계산한다 —
    /// 자정을 넘는 블록이 이틀에 나열돼도 각 날의 목록·배치는 서로 별개라 같은 블록이 하루 안에서
    /// 두 번 세어질 일은 없다. 묶음 키는 여기서 주입한다(REQ-015): 활동은 자기 id, 구간은
    /// `packingGroups`가 대응시켜 준 활동 id, 대응이 없으면 nil(단독 이동·매달린 링크).
    private func positionedBlocks(events dayEvents: [ScheduledEvent],
                                  activities dayActivities: [ActivityBlock],
                                  on date: Date) -> [PositionedBlock] {
        let groups = store.packingGroups(events: dayEvents, activities: dayActivities)
        struct Item { let id: String; let kind: ActiveDrag.Kind; let start: CGFloat; let end: CGFloat; let key: String? }
        // 옮긴 범위가 그 날에 남지 않은 블록(span이 minutes 0을 돌려준 것)은 여기서 뺀다 — 렌더와
        // 히트 테스트가 같은 목록을 보므로 그려지지도 눌리지도 않는다(REQ-009). 저장된 블록은
        // 나열 판정이 그 날과의 겹침을 보장하므로 이 갈래에 오지 않는다.
        var items: [Item] = dayActivities.compactMap {
            let s = span(for: $0, on: date)
            guard s.minutes > 0 else { return nil }
            return Item(id: "a-\($0.id)", kind: .activity($0), start: s.start, end: s.start + s.minutes,
                        key: $0.id.uuidString)
        }
        items += dayEvents.compactMap {
            let s = span(for: $0, on: date)
            guard s.minutes > 0 else { return nil }
            return Item(id: "e-\($0.id)", kind: .event($0), start: s.start, end: s.start + s.minutes,
                        key: groups[$0.id]?.uuidString)
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return ScheduleLogic.overlapSlots(items.map {
            ScheduleLogic.LayoutItem(id: $0.id, start: $0.start, end: $0.end, groupKey: $0.key)
        }).compactMap { range -> PositionedBlock? in
            guard let it = byID[range.id] else { return nil }
            return PositionedBlock(id: it.id, kind: it.kind, start: it.start,
                                   minutes: it.end - it.start, range: range)
        }
    }

    /// 칸 범위 [lo, hi]에 맞는 가로 위치·폭. `total`은 블록이 놓일 영역 전체 폭 — 점 환산(간격
    /// 포함)은 `SlotRange.points`가 하므로 여기엔 칸 산술이 없다(AC-016).
    private func columnFrame(_ p: PositionedBlock, total: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let f = p.range.points(in: total, gap: Self.columnGap)
        return (f.x, max(f.width, 1))
    }

    // MARK: - 시간표 재조정: 어느 블록을 눌렀는지 좌표로 찾기

    /// 좌표(세로 y pt, 가로는 정규화 x에 `total`을 곱한 점)가 어느 블록 위인지 찾는다.
    ///
    /// 겹치는 블록은 가로로 나눠 놓기 때문에 세로만 봐서는 어느 쪽을 눌렀는지 알 수 없다 —
    /// 가로 판정은 **렌더와 같은 점 사각형**(`SlotRange.points`, 칸 경계 간격 포함)으로 한다.
    /// 예전엔 히트가 칸 비율만 봐 렌더의 3pt 간격과 어긋났다(F9). 간격 3pt 자체는 어느 블록도
    /// 아니므로 그 안의 탭은 빈 곳으로 양보된다(잘못된 블록이 열리는 것보다 낫다 — 렌더와
    /// 히트가 같은 사각형을 쓰는 것 자체가 계약이다, AC-016).
    /// 여전히 여러 개가 걸리면 지속시간이 가장 짧은(=가장 구체적인) 블록을 고른다.
    /// 세로 y(pt)를 자정 기준 분으로 바꾼다 — 그리기(offsetY)의 역변환이자 히트테스트
    /// (block(atX:y:))와 빈칸 꾹 누르기 생성(REQ-009)이 같이 읽는 환산이다(계약 5 — 세 번째
    /// 사본이 생기면 렌더·히트·생성 셋이 제각각 늙는다, plan §3.1 제안 3).
    private func minutes(atY y: CGFloat) -> CGFloat {
        y / hourHeight * 60
    }

    private func block(atX x: CGFloat, y: CGFloat, in blocks: [PositionedBlock], total: CGFloat) -> ActiveDrag.Kind? {
        let px = x * total
        let minutes = minutes(atY: y)
        var best: (duration: CGFloat, kind: ActiveDrag.Kind)?
        for p in blocks {
            guard minutes >= p.start, minutes <= p.start + p.minutes else { continue }
            let f = p.range.points(in: total, gap: Self.columnGap)
            guard px >= f.x, px <= f.x + f.width else { continue }
            let duration = max(p.minutes, 1)
            if best == nil || duration < best!.duration { best = (duration, p.kind) }
        }
        return best?.kind
    }

    private func finalizeDrag(_ drag: ActiveDrag) {
        switch drag.kind {
        case .activity(let a):
            if a.recurrenceId != nil {
                pendingMove = PendingMove(message: "'\(a.title)' is a repeating event. How do you want to move it?") { whole in
                    store.moveActivity(a, byMinutes: drag.deltaMinutes, wholeSeries: whole)
                }
                // 선택창 동안 미리보기(t71, REQ-012) — 활동 블록의 놓은 날은 시작+Δ의 달력 날.
                beginSeriesPreview(drag: drag,
                                   targetDay: a.startDate.addingTimeInterval(TimeInterval(drag.deltaMinutes) * 60))
            } else {
                store.moveActivity(a, byMinutes: drag.deltaMinutes, wholeSeries: false)
            }
        case .event(let e):
            // 구간 드래그는 소유 여부와 무관하게 따라간다(Q-20) — 활동 블록 드래그는 따라가지 않는다.
            // 반복이면 대화상자에서 "전체/이 일정만"을 고른 뒤에만(applyPendingMove), 비반복이면 확정
            // 직후. "취소"·끄기 취소·유효 Δ 0(onEnd가 이미 걸렀다)에는 따라가기가 없다. 드롭은 눌렀던
            // 날(pressedOn)을 함께 넘긴다 — Store가 미리보기와 같은 바깥 함수(dragEdgeOutcome)로
            // 확정하므로 끄는 중 표시와 놓은 결과가 어긋나지 않는다(D-14).
            let follow: () -> Void = {
                // 방향은 ActiveDrag가 든 요청 부호를 그대로 쓴다(N1 — Δ에서 다시 뽑지 않는다).
                // 여기 오는 길은 onEnd가 Δ 0을 이미 걸렀으므로 ±1만 들어온다.
                followAfterDrop(of: e, pressedOn: drag.pageDate, deltaSign: drag.direction)
            }
            if e.recurrenceId != nil {
                pendingMove = PendingMove(message: "'\(e.title)' is a repeating event. How do you want to move it?",
                                          apply: { whole in
                                              store.adjustTravelLeg(e, byMinutes: drag.deltaMinutes, wholeSeries: whole,
                                                                    pressedOn: drag.pageDate)
                                          },
                                          followUp: follow)
                // 미리보기가 페이지를 넘길 날은 확정 때의 따라가기와 같은 규칙(followDay)이 정한다 —
                // Δ를 적용한 구간 복사본으로 미리 세우고, 확정 때는 실제 followUp을 그대로 탄다.
                // 눌렀던 날에 여전히 나열되면 nil(같은 날) — 페이지는 안 넘어간다.
                var moved = e
                moved.arrivalDate = e.arrivalDate.addingTimeInterval(TimeInterval(drag.deltaMinutes) * 60)
                moved.departureDate = e.departureDate?.addingTimeInterval(TimeInterval(drag.deltaMinutes) * 60)
                let target = Store.followDay(for: moved, pressedOn: drag.pageDate, deltaSign: drag.direction,
                                             calendar: calendar) ?? drag.pageDate
                beginSeriesPreview(drag: drag, targetDay: target)
            } else {
                store.adjustTravelLeg(e, byMinutes: drag.deltaMinutes, wholeSeries: false,
                                      pressedOn: drag.pageDate)
                follow()
            }
        }
    }

    /// t71 미리보기 시작(REQ-012) — 선택창이 떠 있는 동안 페이지를 놓은 날로 넘겨 놓고(O-A3, 전날도
    /// 같은 규칙 N-8) 블록을 놓은 자리에 그려 둔다. 같은 날에 남는 이동이면 targetDay가 눌렀던 날과
    /// 같은 날이라 화면은 그대로다. 다른 날로 넘어갈 때는 도착 스크롤을 걸어 놓은 블록이 화면에
    /// 보이게 한다(수리 3 — 페이지만 넘기면 스크롤 위치가 옛 자리라 자정 너머 블록이 화면 밖이었다).
    /// 스크롤 산술은 새로 만들지 않고 구간 확정 따라가기와 같은 길(pendingArrival →
    /// settleArrivalIfNeeded → scrollArrivalBlock)을 탄다(계약 5).
    private func beginSeriesPreview(drag: ActiveDrag, targetDay: Date) {
        let target = calendar.startOfDay(for: targetDay)
        seriesPreview = SeriesPreview(drag: drag, targetDay: target)
        if !calendar.isDate(target, inSameDayAs: drag.pageDate) {
            // 블록 id 문법은 positionedBlocks와 같다 — 활동 "a-", 구간 "e-".
            let blockId: String
            switch drag.kind {
            case .activity(let a): blockId = "a-\(a.id)"
            case .event(let e): blockId = "e-\(e.id)"
            }
            pendingArrival = (blockId: blockId, day: target)
            arrivalWatchId = blockId
            // 수리 3b 진단: 대기가 세워졌는데도 스크롤이 0줄 로그로 끝났다 — 어느 문에서
            // 끊기는지 이 로그와 아래 관찰자·판정 로그의 조합으로 가른다.
            arrivalLog.notice("preview arrival wait set: block=\(blockId, privacy: .public) day=\(dayTitle(target), privacy: .public)")
        }
        selectedDate = target
    }

    /// 선택창을 취소로 닫을 때(REQ-012) — 미리보기를 비우고 페이지를 눌렀던 날로 되돌린다. 이 경로는
    /// 저장을 아무것도 하지 않는다(AC-011 — activities.json·events.json 무변경).
    private func cancelSeriesPreview() {
        guard let preview = seriesPreview else { return }
        seriesPreview = nil
        selectedDate = preview.drag.pageDate
    }

    /// 놓은 뒤 따라가기(REQ-015 (3), D-12 (나)) — Store가 실제로 적용한 뒤에만 불린다. 따라갈
    /// 날은 Store.followDay 한 곳이 정한다(뷰가 나열 판정을 다시 계산하지 않는다 — AC-017 G).
    /// 드래그 시작 때가 아니라 지금 저장된 구간을 다시 읽는 것은 드롭 재읽기(REQ-008)와 같은
    /// 이유다 — 적용이 0으로 잘려 구간이 그대로면 followDay가 스스로 nil을 돌려준다.
    private func followAfterDrop(of leg: ScheduledEvent, pressedOn: Date, deltaSign: Int) {
        guard let moved = store.events.first(where: { $0.id == leg.id }) else { return }
        guard let target = Store.followDay(for: moved, pressedOn: pressedOn,
                                           deltaSign: deltaSign, calendar: calendar) else { return }
        // 도착 위치 값은 슬라이드보다 먼저 세운다 — 확정(onChange)은 두 값이 다 세워진 뒤에 온다.
        pendingArrival = (blockId: "e-\(leg.id)", day: target)
        arrivalWatchId = pendingArrival?.blockId
        legSlideRequest = SlideRequest(id: UUID(), target: target)
    }
}

/// 월·주·일간 페이저의 넘김 진행 구간 표시 — 스크롤이 쉬는 자리를 벗어난 순간(손 넘김) 또는 따라가기 요청을 받은 순간부터 날짜를 쓸 때까지. 참조 타입이라 켜고 꺼도
/// 뷰가 다시 그려지지 않는다. 확정이 겹쳐도(연달아 넘김) 앞 확정이 끝났다고 풀리지 않게 개수로 센다.
/// 세 페이저가 한 표시를 같이 쓰는 이유: 화면에는 주간 줄(주 페이저)과 시간표(일간 페이저)가 함께 떠 있어,
/// 어느 쪽을 넘기든 그 사이 닿은 위쪽 칸·오늘 버튼이 같은 상대 이동(step(date, delta))과 부딪친다(N1).
private final class PagerSettle {
    private var pending = 0
    private var deferred: (() -> Void)?
    var settling: Bool { pending > 0 }
    func begin() { pending += 1 }
    func end() {
        pending = max(0, pending - 1)
        guard pending == 0, let action = deferred else { return }
        deferred = nil
        action()
    }

    /// 확정 구간이면 구간이 끝난 뒤(날짜가 쓰인 다음) 한 번 실행하고, 아니면 곧바로 실행한다. 오늘 버튼처럼
    /// 버리면 안 되는 동작용 — 칸 탭은 위치가 바뀌어 의미가 없어지니 무시하지만, 오늘은 목적지가 고정이라
    /// 구간 끝에 가도 같은 곳이다. 하나만 기억하므로(나중 것이 앞 것을 덮음) 구간 중에 여러 번 눌러도 한 번만
    /// 실행되고, 구간이 연달아 이어지면(pending이 0이 될 때까지) 마지막 확정 뒤에 실행된다.
    func whenSettled(_ action: @escaping () -> Void) {
        if settling { deferred = action } else { action() }
    }
}

/// 따라가기 슬라이드 요청(REQ-015 (3), D-12 (나)) — 고유 토큰(UUID)과 절대 목표 날. 부모
/// SwiftUI 뷰는 페이저 안의 상태(스크롤 위치·확정 컨트롤러)를 함수 호출로 바꿀 수 없어 "노출"은
/// 호출이 아니라 요청 값이다. 토큰이 있어야 같은 날로 연달아 두 번 따라가도 둘 다 발화하고
/// 재렌더로 다시 발화하지 않는다. 목표는 상대 delta가 아니라 절대 날짜로 넣는다.
private struct SlideRequest: Equatable {
    let id: UUID
    let target: Date
}

/// 같은 날 판정 한 곳(sync F1, 0.9.0) — 따라가기의 인접일 판단이 이 함수만 부른다. Date == 로
/// 비교하면 시각이 붙은 selectedDate(Date() 로 시작)와 0시로 정규화된 목표(followDay)가
/// 영원히 같지 않아 첫 따라가기가 슬라이드 없이 툭 바뀌었으므로 하루 단위 비교로 고쳤다.
private func isSameDay(_ a: Date, _ b: Date) -> Bool {
    Calendar.current.isDate(a, inSameDayAs: b)
}

/// 가로 페이저의 쪽 자리 수와 쉬는 자리 — 렌더(SwipePager)와 확정(PagerScrollController)이 같은 값을 읽는다(계약 5).
/// 쪽을 다섯으로 두는 이유(폰 피드백 F2 "연타가 거슬림"): 쪽이 셋이면 첫 넘김이 감속하는 동안(확정 전) 같은 쪽으로 다시 끌
/// 때 이미 끝 쪽이라 벽에 막혔다. 쉬는 자리 양쪽에 두 쪽씩 있으면 확정 전에 한 번 더 넘길 수 있고, 그때는 하루(한 주·한 달)가
/// 아니라 둘이 한꺼번에 확정된다. 넘김 한 번의 움직임은 그대로다(끌기·절반·감속은 여전히 시스템 페이징 몫).
private enum PagerSlots {
    static let count = 5
    static let rest = 2
}

#if os(iOS)
/// 가로 페이저(UIScrollView)의 "정착" 감시자 — 손으로 넘기든 따라가기로 넘기든 스크롤이 쪽 경계에 멈춘 순간 한 곳에서
/// 날짜를 확정한다(t87 2차 수리). 끌기·절반 판정·감속은 시스템 페이징 스크롤이 하고, 앱은 멈춘 자리만 본다.
/// iOS 18의 스크롤 단계 API를 못 쓰는 배포 대상(17.0)이라 contentOffset을 KVO로 보고, 마지막 변화 뒤 잠시 조용해지고
/// 손·감속이 없을 때를 정착으로 친다. 참조 타입이고 @Published가 없어 프레임마다 SwiftUI를 다시 그리지 않는다.
///
/// 날짜를 바꾼 뒤 스크롤 자리를 가운데로 돌려놓는 일은 scrollPosition(id:) 같은 SwiftUI API를 거치지 않고 UIScrollView에
/// 직접 쓴다 — 이 파일 맨 위 주석대로 SwiftUI의 스크롤 위치 API는 이 저장소에서 믿을 수 없다고 이미 확인됐고, 초기 자리도
/// 같은 이유로 여기서 잡아 offset을 쓰는 손이 하나로 모이게 했다.
private final class PagerScrollController {
    private weak var scrollView: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?

    private var dateBinding: Binding<Date>?
    private var step: ((Date, Int) -> Date)?
    private var settle: PagerSettle?

    /// 첫 레이아웃 뒤 가운데 쪽(쉬는 자리)으로 옮겼는지 — 그 전의 offset 변화는 감시하지 않는다.
    private var initialized = false
    /// 우리가 offset을 쓰는 중 — 그 KVO 통지가 다시 정착 판정을 일으키지 않게 한다.
    private var recentering = false
    /// settle.begin()을 불렀고 아직 end()를 못 부른 상태. begin/end가 한 쌍으로만 나가게 하는 단일 표시다.
    private var settleActive = false
    /// 이번 이동이 손(끌기·감속) 또는 따라가기 요청으로 일어났는지. 둘 다 아닌 이동(레이아웃이 offset을 흔드는 등)이
    /// 쪽 넘김으로 읽혀 날짜가 엉뚱하게 바뀌는 것을 막는다.
    private var gestureDriven = false
    /// 프로그램이 애니메이션으로 보내는 중인 목표 자리와 그 기한 — 이 사이엔 "멈췄는데 경계가 아님"을 보정하지 않고 기다린다.
    private var animatingSlot: Int?
    private var animationDeadline: TimeInterval = 0
    /// 따라가기가 정한 절대 목표 날과 그 자리. 확정이 같은 자리에서 일어났을 때만 쓴다(사이에 손이 끼어들어 반대쪽으로
    /// 갔으면 목표를 버리고 손이 간 쪽으로 한 칸 — 안 그러면 엉뚱한 날이 된다).
    private var pendingSlot: Int?
    private var pendingTarget: Date?
    /// 확정 중에 도착한 따라가기 요청 — 버리면 도착 스크롤 대기(pendingArrival)만 남아 허공을 가리키므로 줄 세워
    /// 확정이 끝난 뒤에 실행한다. 하나만 기억한다(나중 것이 앞 것을 덮음).
    private var queuedTarget: Date?
    private var checkWork: DispatchWorkItem?
    /// 첫 자리 잡기 예약 중·재시도 횟수 — 레이아웃이 안 끝난 채 끝없이 다시 보지 않게 센다.
    private var initializeScheduled = false
    private var initializeAttempts = 0
    /// 마지막으로 본 스크롤 폭 — 폭이 바뀔 때만 쉬는 자리를 다시 맞춘다.
    private var lastWidth: CGFloat = 0
    /// 최근 되돌림 시각들과 차단기 상태(moveInstantly 주석).
    private var recentMoves: [TimeInterval] = []
    private var tripped = false

    /// 마지막 offset 변화 뒤 이만큼 조용하면 멈춘 것으로 본다.
    private static let quietDelay: TimeInterval = 0.05
    /// 손·감속·애니메이션이 아직 끝나지 않았을 때 다시 확인하는 간격.
    private static let pollInterval: TimeInterval = 0.1
    /// 프로그램 애니메이션이 이 시간 안에 안 끝나면 목표 자리로 직접 옮긴다.
    private static let animationLimit: TimeInterval = 1.0
    private static let boundaryTolerance: CGFloat = 0.5
    /// 차단기: 이 시간(초) 안에 되돌림이 이 횟수에 닿으면 멈춘다. 정상 사용은 넘김 한 번에 되돌림 한 번이고 연달아 튕겨도
    /// 초당 두세 번이라 한참 못 미친다.
    private static let breakerWindow: TimeInterval = 2
    private static let breakerLimit = 12
    private static let initializeAttemptLimit = 40

    deinit {
        checkWork?.cancel()
        // 페이저가 넘김 도중에 사라지면(월 달력 펴기 등) end()를 못 불러 칸 탭이 영영 막힌다 — 짝을 여기서 맞춘다.
        if settleActive { settle?.end() }
    }

    func configure(date: Binding<Date>, step: @escaping (Date, Int) -> Date, settle: PagerSettle?) {
        dateBinding = date
        self.step = step
        self.settle = settle
        // 여기는 SwiftUI 갱신 한가운데다 — offset은 쓰지 않고 다음 턴으로 미룬다.
        if !initialized { scheduleInitialize() }
    }

    func attach(to sv: UIScrollView) {
        guard scrollView !== sv else { return }
        scrollView = sv
        initialized = false
        initializeAttempts = 0
        lastWidth = sv.bounds.width
        // 가운데 쪽만 쉬는 자리라 양 끝 바깥으로 끌려나갈 일이 없다 — 튕김이 있으면 끝 쪽에서 고무줄처럼 늘었다 줄어든다.
        // SwiftUI에는 가로 튕김만 끄는 값이 없어(ScrollBounceBehavior에 never가 없다) UIKit에 직접 쓴다. SwiftUI가 다시 덮어쓰면
        // 효과가 없을 뿐 동작은 그대로다.
        sv.bounces = false
        offsetObservation = sv.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.offsetDidChange()
        }
        sizeObservation = sv.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            self?.contentSizeDidChange()
        }
        // 부착 시점엔 아직 레이아웃 전일 수 있다 — 한 턴 뒤에 다시 본다.
        scheduleInitialize()
    }

    // MARK: 좌표

    private func slotOffsetX(_ slot: Int, in sv: UIScrollView) -> CGFloat {
        -sv.adjustedContentInset.left + CGFloat(slot) * sv.bounds.width
    }

    /// 우리가 쓰는 offset은 전부 여기를 지난다 — 통지를 막는 표시와 애니메이션 없음이 한 곳에서 보장된다.
    /// 차단기: 짧은 시간에 되돌림이 너무 잦으면 레이아웃과 서로를 다시 부르는 고리라고 보고 더는 쓰지 않는다 — 폰에서
    /// 쪽 전체 재레이아웃이 바퀴마다 수 초라 워치독에 죽었던 일(r10)이 다시 일어나지 않게 하는 마지막 방어선이다.
    private func moveInstantly(to slot: Int, in sv: UIScrollView) {
        let now = ProcessInfo.processInfo.systemUptime
        recentMoves = recentMoves.filter { now - $0 < Self.breakerWindow }
        if recentMoves.count >= Self.breakerLimit {
            if !tripped {
                tripped = true
                pagerLog.error("horizontal pager snapped back \(Self.breakerLimit, privacy: .public) times within \(Self.breakerWindow, privacy: .public) s — treating it as a loop and stopping")
            }
            return
        }
        recentMoves.append(now)
        recentering = true
        sv.setContentOffset(CGPoint(x: slotOffsetX(slot, in: sv), y: sv.contentOffset.y), animated: false)
        recentering = false
    }

    /// 첫 자리 잡기를 다음 런루프 턴으로 미룬다. 호출처(SwiftUI 갱신·contentSize/offset KVO)는 UIKit이 스크롤 뷰를 갱신하는
    /// 도중이라 거기서 바로 setContentOffset을 쓰면 갱신 안에서 갱신을 부르는 꼴이 된다.
    private func scheduleInitialize() {
        guard !initialized, !initializeScheduled, !tripped else { return }
        initializeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.initializeScheduled = false
            self.initializeIfReady()
        }
    }

    private func initializeIfReady() {
        guard !initialized, let sv = scrollView else { return }
        let w = sv.bounds.width
        // 모든 쪽이 다 깔린 뒤에만(폭이 쪽 수 가까이) 가운데로 옮긴다 — 레이아웃 전의 작은 contentSize에서 옮기면 0으로 되돌려진다.
        guard w > 1, sv.contentSize.width >= w * (CGFloat(PagerSlots.count) - 0.5) else {
            // 레이아웃이 아직이다 — 짧게 몇 번만 다시 본다(끝없이 돌지 않게).
            initializeAttempts += 1
            if initializeAttempts < Self.initializeAttemptLimit {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.initializeIfReady() }
            }
            return
        }
        initialized = true
        moveInstantly(to: PagerSlots.rest, in: sv)
    }

    // MARK: 관찰

    private func contentSizeDidChange() {
        guard let sv = scrollView else { return }
        if !initialized {
            scheduleInitialize()
            return
        }
        // 폭이 바뀐 경우(회전·분할)만 쉬는 자리를 다시 본다 — 폭이 같은 크기 갱신마다 판정을 돌리면 레이아웃 고리를 키운다.
        let width = sv.bounds.width
        guard abs(width - lastWidth) > Self.boundaryTolerance else { return }
        lastWidth = width
        scheduleCheck(after: Self.quietDelay)
    }

    private func offsetDidChange() {
        guard !recentering else { return }
        guard initialized, let sv = scrollView else {
            scheduleInitialize()
            return
        }
        if sv.isTracking || sv.isDragging || sv.isDecelerating { gestureDriven = true }
        let fromRest = abs(sv.contentOffset.x - slotOffsetX(PagerSlots.rest, in: sv))
        // 쉬는 자리에서 처음 벗어나는 순간 한 번 알린다 — 감속 중 닿은 칸 탭이 날짜를 고르지 않게 한다.
        if gestureDriven, fromRest > Self.boundaryTolerance { beginSettleIfNeeded() }
        scheduleCheck(after: Self.quietDelay)
    }

    private func scheduleCheck(after delay: TimeInterval) {
        checkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 마지막 변화 뒤 조용해진 시점의 판정. 손이 닿아 있거나 감속 중이면 아직 안 멈춘 것이다.
    private func check() {
        checkWork = nil
        // 차단기가 걸렸다 — 더는 날짜를 확정하지도 offset을 쓰지도 않고 탭 막기만 푼다(앱이 멈추는 쪽이 훨씬 나쁘다).
        if tripped {
            endSettleIfNeeded()
            return
        }
        guard initialized, let sv = scrollView else { return }
        let w = sv.bounds.width
        guard w > 1 else { return }
        if sv.isTracking || sv.isDragging || sv.isDecelerating {
            scheduleCheck(after: Self.pollInterval)
            return
        }
        let pages = (sv.contentOffset.x - slotOffsetX(0, in: sv)) / w
        let slot = min(max(Int(pages.rounded()), 0), PagerSlots.count - 1)
        let distance = abs(sv.contentOffset.x - slotOffsetX(slot, in: sv))
        guard distance > Self.boundaryTolerance else {
            animatingSlot = nil
            settled(at: slot)
            return
        }
        // 멈췄는데 쪽 경계가 아니다 — 프로그램 애니메이션 도중이면 기다리고, 아니면(감속 중 손가락으로 붙잡았다 뗀 경우 등)
        // 가까운 쪽으로 마저 보낸다.
        if let target = animatingSlot {
            if ProcessInfo.processInfo.systemUptime < animationDeadline {
                scheduleCheck(after: Self.pollInterval)
                return
            }
            animatingSlot = nil
            moveInstantly(to: target, in: sv)
            settled(at: target)
            return
        }
        gestureDriven = true
        beginSettleIfNeeded()
        startAnimation(toSlot: slot, in: sv)
    }

    private func startAnimation(toSlot slot: Int, in sv: UIScrollView) {
        animatingSlot = slot
        animationDeadline = ProcessInfo.processInfo.systemUptime + Self.animationLimit
        sv.setContentOffset(CGPoint(x: slotOffsetX(slot, in: sv), y: sv.contentOffset.y), animated: true)
        scheduleCheck(after: Self.pollInterval)
    }

    // MARK: 확정

    private func beginSettleIfNeeded() {
        guard !settleActive else { return }
        settleActive = true
        settle?.begin()
    }

    private func endSettleIfNeeded() {
        guard settleActive else { return }
        settleActive = false
        settle?.end()
    }

    private func settled(at slot: Int) {
        let driven = gestureDriven
        gestureDriven = false
        if slot == PagerSlots.rest || !driven {
            // 제자리로 돌아왔거나, 손도 요청도 아닌 이동이다 — 날짜는 건드리지 않는다.
            pendingSlot = nil
            pendingTarget = nil
            if slot != PagerSlots.rest, let sv = scrollView { moveInstantly(to: PagerSlots.rest, in: sv) }
            endSettleIfNeeded()
            runQueuedFollow()
            return
        }
        commit(slot: slot)
    }

    /// 쪽이 바뀐 확정(가설 기반 방어 — t60). 날짜 쓰기와 스크롤 자리 되돌리기를 한 트랜잭션에 애니메이션 없이 묶는다.
    /// 낱개로 쓰면 하위트리 일부(주간 스트립·시트 제시)만 낡은 상태에 남는다는 **가설**이다(t60 progress.md §2). 화면은
    /// 이 호출이 끝난 뒤에야 그려지므로 날짜가 바뀐 채 옛 자리가 비치는 한 프레임도 없다. 따라가기는 절대 목표 날
    /// 갈래로 확정한다 — 두 갈래를 한 식으로 합치지 않는다(감사 F2: 상대 이동 대입은 이 한 곳만 남아야 한다).
    private func commit(slot: Int) {
        let target: Date? = (pendingSlot == slot) ? pendingTarget : nil
        pendingSlot = nil
        pendingTarget = nil
        guard let binding = dateBinding, let stepFn = step else {
            if let sv = scrollView { moveInstantly(to: PagerSlots.rest, in: sv) }
            endSettleIfNeeded()
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // 쉬는 자리에서 떨어진 쪽 수만큼 한 번에 간다(연타로 두 쪽 건너뛴 경우 ±2) — 화면에 보인 쪽의 날짜
            // (SwipePager.pageDate)와 같은 식이라 확정 순간 내용이 바뀌지 않는다.
            binding.wrappedValue = target ?? stepFn(binding.wrappedValue, slot - PagerSlots.rest)
            if let sv = scrollView { moveInstantly(to: PagerSlots.rest, in: sv) }
        }
        endSettleIfNeeded()
        runQueuedFollow()
    }

    // MARK: 따라가기

    /// 따라가기 요청(REQ-015 (3)) — 목표가 앞·뒤 하루(주간 줄은 7일)면 옆으로 미끄러지고, 아니면 슬라이드 없이 바로 확정한다.
    func follow(to target: Date) {
        // 호출처(.onChange)는 SwiftUI 갱신 처리 중이라 UIKit 스크롤 뷰를 거기서 바로 만지지 않고 다음 턴으로 미룬다.
        DispatchQueue.main.async { [weak self] in self?.followNow(target) }
    }

    private func followNow(_ target: Date) {
        if settleActive {
            queuedTarget = target
            return
        }
        guard initialized, let sv = scrollView, let binding = dateBinding, let stepFn = step else {
            commitWithoutSlide(target)
            return
        }
        let current = binding.wrappedValue
        if isSameDay(stepFn(current, 1), target) {
            slide(toSlot: PagerSlots.rest + 1, target: target, in: sv)
        } else if isSameDay(stepFn(current, -1), target) {
            slide(toSlot: PagerSlots.rest - 1, target: target, in: sv)
        } else {
            commitWithoutSlide(target)
        }
    }

    private func slide(toSlot slot: Int, target: Date, in sv: UIScrollView) {
        pendingSlot = slot
        pendingTarget = target
        gestureDriven = true
        beginSettleIfNeeded()
        startAnimation(toSlot: slot, in: sv)
    }

    /// 이틀 이상 건너뛰는 따라가기 — 맞출 곡선이 없어 날짜만 바꾼다. 요청을 처리하던 갱신이 끝난 뒤(다음 턴)에 쓴다.
    private func commitWithoutSlide(_ target: Date) {
        beginSettleIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.dateBinding?.wrappedValue = target
                if self.initialized, let sv = self.scrollView { self.moveInstantly(to: PagerSlots.rest, in: sv) }
            }
            self.endSettleIfNeeded()
            self.runQueuedFollow()
        }
    }

    private func runQueuedFollow() {
        guard let queued = queuedTarget else { return }
        queuedTarget = nil
        followNow(queued)
    }
}

/// 가로 페이저의 UIScrollView를 찾아 컨트롤러에 물리는 0×0 프로브. 페이저 쪽 안이 아니라 가로 ScrollView 콘텐츠 바로
/// 안(HStack 배경)에 둔다 — 조상 걷기가 가장 가까운 UIScrollView(= 이 가로 스크롤)에서 멈추고, 쪽 안의 세로 스크롤은
/// 후손이라 걸리지 않는다. 조상 걷기 방식은 PageScrollProbeView·ScrollTouchFixView와 같다.
private final class PagerOffsetProbeView: UIView {
    var controller: PagerScrollController? { didSet { attachIfPossible() } }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachIfPossible()
    }

    private func attachIfPossible() {
        guard window != nil, let controller else { return }
        var v: UIView? = superview
        while let cur = v {
            if let scroll = cur as? UIScrollView {
                controller.attach(to: scroll)
                return
            }
            v = cur.superview
        }
    }
}

private struct PagerOffsetProbe: UIViewRepresentable {
    let controller: PagerScrollController
    let date: Binding<Date>
    let step: (Date, Int) -> Date
    let settle: PagerSettle?

    func makeUIView(context: Context) -> PagerOffsetProbeView {
        let v = PagerOffsetProbeView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: PagerOffsetProbeView, context: Context) {
        controller.configure(date: date, step: step, settle: settle)
        v.controller = controller
    }
}
#endif

/// 좌우로 넘기면 이전/현재/다음 쪽이 손가락을 따라 함께 움직이는 캐러셀 — iOS 표준 페이징 스크롤 뷰(가로 ScrollView +
/// `.paging`) 위에 선다. 끌기 추적·절반/튕김 판정·놓은 뒤 감속은 전부 시스템 동작이라 손으로 짠 끌기 판정이 없다(t87 2차
/// 수리 — 앞 판의 DragGesture 페이저는 미끄러짐이 안 보이고 절반 전에도 넘어갔다). 쪽(PagerSlots.count개)은 위치로 정체성이
/// 고정된 자리라 시간표 안쪽 세로 ScrollView가 확정 뒤에도 재사용된다. 날짜는 멈춘 자리에서만 쓰고(PagerScrollController)
/// 쓴 직후 스크롤 자리를 가운데로 돌려놓는다. macOS는 보존 코드라 한 쪽만 보이는 최소 대체다(맥은 iOS 완성 뒤 제작).
private struct SwipePager<Content: View>: View {
    @Binding var date: Date
    let step: (Date, Int) -> Date
    /// true면(예: 블록을 드래그하는 중) 페이지 전환 제스처를 잠근다.
    var isLocked: Bool = false
    /// 따라가기 슬라이드 요청 — 일간 시간표 페이저만 받는다(월간·주간은 nil 그대로). onChange로
    /// 소비하고 비운다(같은 경로를 손 넘김과 공유, t60 방어 재사용).
    var slideRequest: Binding<SlideRequest?>? = nil
    /// 넘김이 진행되는 구간(스크롤이 쉬는 자리를 벗어난 순간 ~ 날짜를 쓴 순간)을 알리는 표시 — 월·주·일간 세 페이저가
    /// 모두 받는다(칸 탭이 이 구간에 읽히지 않게, CS-F1·N1). 일간 시간표 자체에는 날짜 칸이 없지만, 그 위의
    /// 주간 줄 칸이 같은 화면에 있어 일간 넘김 중 칸을 눌러도 selectedDate 위에 하루가 더 얹혔다(N1).
    var settle: PagerSettle? = nil
    @ViewBuilder let content: (Date) -> Content

    #if os(iOS)
    @State private var controller = PagerScrollController()
    #endif

    /// 자리 번호(쉬는 자리가 현재, 양옆이 이전·다음)의 날짜. 쉬는 자리는 step을 거치지 않고 date 그대로다(시각이 붙은 값을
    /// 바꾸지 않는다).
    private func pageDate(_ slot: Int) -> Date {
        slot == PagerSlots.rest ? date : step(date, slot - PagerSlots.rest)
    }

    var body: some View {
        #if os(iOS)
        // 놓은 뒤 움직임에 .animation(value:)를 걸지 않는다 — 체인 끝에 걸면 모든 쪽의 내용 전체가 그 하위가 되어 월 넘김에서
        // 쪽 안 레이아웃이 프레임마다 다시 계산됐다(t87 §4·§8 V3). 움직임은 전부 UIScrollView 몫이다.
        //
        // 쪽 크기는 containerRelativeFrame이 아니라 루트 GeometryReader가 준 숫자로 못박는다 — 폰에서 containerRelativeFrame이
        // 가로 스크롤 안 쪽마다 자식의 정렬을 묻느라 쪽 전체 레이아웃을 되풀이해(첫 화면이 열리지 않고 워치독이 죽였다, r10 크래시
        // 스택: ContainerRelativeFrameLayout.placement → explicitAlignment → ScrollViewUtilities.sizeThatFits) 측정 단계의 컨테이너
        // 크기가 흔들리면 contentSize가 1쪽↔3쪽으로 번갈아 바뀌었다. 숫자 크기는 앞 페이저가 쓰던 검증된 길이다.
        GeometryReader { geo in
            let pageWidth = max(geo.size.width, 1)
            let pageHeight = max(geo.size.height, 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(0..<PagerSlots.count, id: \.self) { slot in
                        content(pageDate(slot))
                            .frame(width: pageWidth, height: pageHeight, alignment: .top)
                    }
                }
                .background {
                    PagerOffsetProbe(controller: controller, date: $date, step: step, settle: settle)
                        .frame(width: 0, height: 0)
                }
            }
            // 첫 배치부터 가운데 쪽(쉬는 자리)이 그려지게 한다 — UIScrollView의 처음 offset은 0이라 이게 없으면 맨 왼쪽 쪽이
            // 먼저 그려졌다가 PagerScrollController가 다음 턴(내용 크기가 깔릴 때까지 50ms 간격 재시도)에야 가운데로
            // 옮겼다. 월을 여는 첫 프레임에 두 달 앞 칸이 0.17초 비쳤다(sim t87-s3). 쪽이 폭이 같은 다섯이라 가운데
            // 앵커 = 쉬는 자리다. 동적 위치 지정(scrollPosition 등)이 아니라 첫 배치 한 번이라 파일 맨 위 주석이 믿지 않는
            // 범위와 다르다. 컨트롤러의 첫 자리 잡기는 그대로 둔다(앵커가 안 먹는 경우의 백스톱).
            .defaultScrollAnchor(.center)
            .scrollTargetBehavior(.paging)
            .scrollDisabled(isLocked)
            // 따라가기(REQ-015 (3)) — 컨트롤러가 앞·뒤 하루면 옆으로 미끄러지고 아니면 슬라이드 없이 확정한다.
            // 소비한 요청은 여기서 비운다(재발화 방지).
            .onChange(of: slideRequest?.wrappedValue) { _, req in
                guard let req else { return }
                controller.follow(to: req.target)
                slideRequest?.wrappedValue = nil
            }
        }
        #else
        content(date)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: slideRequest?.wrappedValue) { _, req in
                guard let req else { return }
                date = req.target
                slideRequest?.wrappedValue = nil
            }
        #endif
    }
}

#if os(iOS)
/// UIScrollView.delaysContentTouches(기본 true)는 스크롤인지 판단될 때까지 콘텐츠 뷰(와 그
/// 제스처 인식기)로의 터치 전달을 지연·취소시킬 수 있다 — 길게 눌러야 하는 드래그(0.35초)는
/// 그 사이 무사히 살아남지만, 짧은 탭은 이 지연 때문에 종종 씹혔다(탭해도 상세정보가 안 뜨던
/// 원인). window에 붙는 시점에 조상 UIScrollView를 찾아 꺼버려 탭이 확실히 전달되게 한다.
private final class ScrollTouchFixView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var v: UIView? = superview
        while let cur = v {
            if let scroll = cur as? UIScrollView { scroll.delaysContentTouches = false }
            v = cur.superview
        }
    }
}

/// 시간표 전체(ZStack)를 덮는 투명 UIKit 오버레이. 블록을 꾹 눌러 옮기는 드래그와
/// 블록 탭(상세보기)을 여기서 직접 처리한다.
///
/// SwiftUI의 `.simultaneousGesture`는 ScrollView 내부 UIPanGestureRecognizer와 진짜
/// UIKit 레벨 동시 인식(shouldRecognizeSimultaneouslyWith)을 보장하지 않아, 블록 위에서
/// 시작한 스크롤이 계속 막히고 탭도 씹혔다(여러 라운드에 걸쳐 확인됨). UIKit
/// UIGestureRecognizerDelegate로 이 값을 직접 true로 선언하면 ScrollView의 팬 제스처와
/// 나란히 인식되게 만들 수 있다 — 이 오버레이가 아무 처리도 안 하기로 한 터치(빈 공간,
/// 짧은 탭, 짧은 스크롤)는 그냥 실패시켜 스크롤/탭이 정상 동작하도록 양보한다.
///
/// 이 오버레이가 블록들 위에 얹혀 히트 테스트를 가로채므로, 블록 자신의 onTapGesture는
/// 더 이상 호출되지 않는다 — 탭 판정도 이 뷰의 UITapGestureRecognizer가 좌표로 대신한다.
private struct RescheduleOverlay: UIViewRepresentable {
    /// 꾹 눌러 0.35초 유지된 시점의 좌표(가로는 0~1로 정규화, 세로는 pt).
    /// 블록 위가 아니면 false를 반환해 즉시 포기한다(스크롤/탭에 양보 — activeDrag를 절대 세우지 않는다).
    let onBegin: (CGFloat, CGFloat) -> Bool
    /// onBegin이 false를 돌려준 자리의 빈칸 길(REQ-009) — true(빈칸)면 제스처를 취소하지 않고
    /// 살려 둔다(스크롤과의 동시 인식은 그대로 — 빈칸 길은 activeDrag를 세우지 않아 스크롤 잠금도
    /// 없다). false(블록 사이 틈, O-A5)면 길게누름을 .cancelled로 끝낸다.
    let onEmptyBegin: (CGFloat, CGFloat) -> Bool
    /// 드래그 중 시작 y좌표 대비 이동량(pt, 부호 있음).
    let onChange: (CGFloat) -> Void
    /// 손을 뗐을 때: true면 커밋(실제로 옮김), false면 취소(꾹 누르기가 중간에 실패/취소됨).
    let onEnd: (Bool) -> Void
    /// 빈칸 길에서 손을 뗐을 때: true(.ended — 카드를 띄운다, O-A4), false(.failed/.cancelled —
    /// 인식 뒤 제스처가 취소돼 시드를 버린다).
    let onEmptyEnd: (Bool) -> Void
    /// 짧은 탭이 끝난 시점의 좌표(가로 0~1 정규화, 세로 pt).
    let onTap: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegin: onBegin, onEmptyBegin: onEmptyBegin, onChange: onChange,
                    onEnd: onEnd, onEmptyEnd: onEmptyEnd, onTap: onTap)
    }

    func makeUIView(context: Context) -> UIView {
        let view = ScrollTouchFixView()
        view.backgroundColor = .clear
        view.isOpaque = false

        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                       action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        // 탭은 길게누름이 실패한 뒤에만 인식한다 — 동시 인식 허용만으로는 꾹 누른 손가락을 떼는
        // 순간에도 탭이 함께 인식되어(탭에는 누른 시간 상한이 없다) 홀드가 상세 열기로 변했다
        // (t65 재현 6/6, 끌기 중 열림은 t52 운영자 관찰). 짧은 탭은 손을 떼는 순간 길게누름이
        // 실패하므로 지연 없이 그대로 인식된다.
        tap.require(toFail: longPress)
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegin = onBegin
        context.coordinator.onEmptyBegin = onEmptyBegin
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
        context.coordinator.onEmptyEnd = onEmptyEnd
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegin: (CGFloat, CGFloat) -> Bool
        var onEmptyBegin: (CGFloat, CGFloat) -> Bool
        var onChange: (CGFloat) -> Void
        var onEnd: (Bool) -> Void
        var onEmptyEnd: (Bool) -> Void
        var onTap: (CGFloat, CGFloat) -> Void

        private var startY: CGFloat = 0
        private var didBegin = false
        /// 빈칸 길(REQ-009)이 인식돼 살아 있는 상태 — didBegin(블록 길)과 함께 서는 일은 없다
        /// (onBegin이 false일 때만 빈칸 길이 묻는다).
        private var didEmptyBegin = false

        init(onBegin: @escaping (CGFloat, CGFloat) -> Bool, onEmptyBegin: @escaping (CGFloat, CGFloat) -> Bool,
             onChange: @escaping (CGFloat) -> Void, onEnd: @escaping (Bool) -> Void,
             onEmptyEnd: @escaping (Bool) -> Void, onTap: @escaping (CGFloat, CGFloat) -> Void) {
            self.onBegin = onBegin; self.onEmptyBegin = onEmptyBegin; self.onChange = onChange
            self.onEnd = onEnd; self.onEmptyEnd = onEmptyEnd; self.onTap = onTap
        }

        /// 가로 좌표를 0~1로 바꾼다(겹친 블록이 좌우로 나뉘어 있어 어느 열인지 판단해야 한다).
        private func normalizedX(_ gr: UIGestureRecognizer) -> CGFloat {
            let width = gr.view?.bounds.width ?? 1
            return width > 0 ? min(max(gr.location(in: gr.view).x / width, 0), 1) : 0
        }

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            let y = gr.location(in: gr.view).y
            switch gr.state {
            case .began:
                startY = y
                didBegin = onBegin(normalizedX(gr), y)
                if !didBegin {
                    // 블록 밖 — 빈칸 길(REQ-009)을 묻는다. 빈칸이면 제스처를 취소하지 않고 살려 둔다
                    // (카드는 .ended에서, O-A4). 틈(O-A5)이면 옛 동작대로 취소로 끝낸다.
                    didEmptyBegin = onEmptyBegin(normalizedX(gr), y)
                    if !didEmptyBegin {
                        gr.state = .cancelled
                        return
                    }
                }
            case .changed:
                // 빈칸 길은 이동량을 받지 않는다 — 시각은 인식 순간의 y로 정해져 있다(O-A4).
                guard didBegin else { return }
                onChange(y - startY)
            case .ended:
                if didBegin { onEnd(true) }
                else if didEmptyBegin { onEmptyEnd(true) }
                didBegin = false; didEmptyBegin = false
            case .cancelled, .failed:
                if didBegin { onEnd(false) }
                else if didEmptyBegin { onEmptyEnd(false) }
                didBegin = false; didEmptyBegin = false
            default:
                break
            }
        }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended else { return }
            onTap(normalizedX(gr), gr.location(in: gr.view).y)
        }

        // ScrollView의 내부 팬 제스처·이 뷰의 롱프레스/탭 서로가 동시에 인식되도록 허용한다.
        // 기본값(false)이면 UIKit이 하나만 골라 스크롤이나 탭이 막힌다.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
