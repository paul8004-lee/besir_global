import SwiftUI
import CoreLocation

/// REQ-016 선택창이 뜨는 동안 잡아 두는 저장 몸통 — 단추를 고르는 순간까지 아무것도 쓰지
/// 않는다(취소 = 되돌릴 것 없음).
private struct PendingSeriesSave {
    /// "반복 전체"를 물을 역할과 선택창을 연 순간의 조사 결과. 대상 회차 집합(eligibleIds)은
    /// 이 조사에 잡힌 그대로 저장에 흘러간다(REQ-016 — 같은 저장 안 재계산 금지).
    struct Ask {
        let role: ScheduleAnchor
        let preview: Store.SeriesLegAddPreview
    }
    let asks: [Ask]
    let ops: [LegSaveOp]
    let activity: ActivityBlock
    let start: Date
    let end: Date
    let newPlace: Place?
    let seed: LegCardForm
    let current: LegCardForm
}

/// "반복 전체" 붙이기의 결과 한 줄(J-18) — done이 참이면 checkmark·travelInk, 거짓이면
/// 건너뛴 줄(muted).
private struct SeriesResultLine: Identifiable {
    let id = UUID()
    let text: String
    let done: Bool
}

/// 활동(체류형) 블록의 정보 보기·편집 화면. 이동 구간(ScheduledEvent)의 편집도 연결된 구간이면
/// 이 카드가 맡는다(SPEC-UIKIT-009 REQ-001 — 시간을 고치면 활동과 분리되던 창이 나오지 않게).
/// 구간 줄의 문법은 생성 카드(AddActivityView)와 같은 LegCardForm이다(REQ-007).
struct ActivityDetailView: View {
    let activityId: UUID
    @EnvironmentObject var store: Store
    /// 가는 이동 출발지의 '현재 위치' 행(O-B6)이 읽는 측위 상태 — 카드 뷰는 순수 값 뷰라 화면이
    /// 이 환경 객체를 받아 줄 동작에 넘겨 준다(권한 판정·대기는 PlaceLineResolve가 안다).
    @EnvironmentObject var location: LocationManager
    @Environment(\.dismiss) private var dismiss

    // 편집값 넷(제목·장소·시작·종료)과 구간 줄의 문법·좌표 사전·기억값은 전부 LegCardForm 한 몸에
    // 산다(SPEC-UIKIT-009 MB). 화면이 직접 드는 것은 문법이 가질 수 없는 것뿐: 시드 때의 스냅샷
    // (저장 diff의 기준), 검색 묶음, 주변 맛집, 저장 진행·결과, 삭제 대화상자.
    @State private var form: LegCardForm?
    /// 저장 diff의 기준 — 시드 때의 폼 그대로. diff가 (시드, 현재, 시드 때 구간)의 순수 함수라
    /// await 사이에도 늙지 않는다.
    @State private var seed: LegCardForm?
    /// 시드 때의 명시적 연결 구간(Store.legs(of:)). 저장이 끝난 뒤엔 다시 읽지 않는다 — 시드와
    /// diff가 같은 순간을 보아야 무변경 저장이 바이트 동일로 닫힌다(REQ-008).
    @State private var seedLegs: (outbound: ScheduledEvent?, `return`: ScheduledEvent?) = (nil, nil)
    /// 저장 도중 저장·닫기를 잠근다(생성 카드의 saving 패턴 그대로) — 활동만 저장되고 구간은
    /// 미적용인 중간 상태에서 시트가 내려가는 것을 막는다(design §3). 이 잠금이 MA code-safety
    /// 경고 1(addLeg 중복 역할 검사가 await 앞에만 있다)의 뷰 경로를 닫는다 — 같은 카드에서
    /// 두 번 저장이 겹칠 수 없으므로 이 화면에서는 같은 역할 addLeg가 경쟁하지 않는다.
    @State private var saving = false
    /// 저장 결과 안내(REQ-010·REQ-009). nil이면 저장이 조용히 닫혔다는 뜻이다.
    @State private var saveReport: String?
    /// 카드 검색 에디터의 묶음(350ms 지연·취소·같은 질의 스킵). 지연 상수는 이 타입이 단독으로
    /// 소유한다 — 화면이 들고 있으면 카카오 할당량 정책이 두 벌이 된다.
    @State private var placeDebounce = PlaceSearchDebouncer()
    @State private var showingDeleteMenu = false
    @State private var showingDeleteConfirm = false
    // REQ-016 선택창 — Store 쓰기 앞에 띄워야 하므로 저장을 둘로 쪼갠다: save()가 쓰기 전에
    // 조사(previewSeriesLegAdd, 읽기 전용)만 하고 선택창을 띄우며, 단추를 고르면 여기 잡아 둔
    // 몸통이 쓰기(performSave)를 굴린다. 조사 결과(대상 회차 집합)는 선택창을 **연 순간**의
    // 그대로다 — 같은 저장 안에서 다시 계산하지 않는다(REQ-016).
    @State private var pendingSeriesSave: PendingSeriesSave?
    @State private var showingSeriesAddAsk = false
    /// "반복 전체" 붙이기의 결과 줄(J-18) — 빈 배열이면 보일 결과 없음.
    @State private var seriesReport: [SeriesResultLine] = []

    // 주변 맛집 추천(be full sir) — 실기기 테스트 피드백으로 이동 일정 상세에서 옮겨옴:
    // "식사하는 곳"인 활동 쪽에 있는 게 "이동하는 중"인 쪽보다 자연스럽다는 의견.
    @State private var nearby: [NearbyPlace] = []
    @State private var nearbyCategory: MealCategoryFilter = .restaurant
    @State private var loadingNearby = false
    @State private var nearbyLoaded = false
    /// 지금 떠 있는 주변 조회. 종류를 연달아 바꾸면 취소 없이는 카카오 조회가 한 벌씩 쌓이고,
    /// 취소된 조회는 try?로 삼켜진 빈 배열로 정상 돌아와 늦은 옛 빈 결과가 새 결과를 덮는다
    /// (day-close §6 후속 12).
    @State private var nearbyTask: Task<Void, Never>?
    /// '현재 위치' 행의 측위 대기. 행을 다시 타면 이전 대기를 취소한다 — 대기가 둘 나란히 돌면
    /// 같은 확정이 두 번 일어난다(AddEventView.prefillTask와 같은 형태).
    @State private var originLocationTask: Task<Void, Never>?
    // Bumped by a tap on the empty sheet area; the card closes its open wheel when it changes.
    @State private var outsideTapCount = 0

    private var activity: ActivityBlock? {
        store.activity(id: activityId)
    }

    private var placeCoord: CLLocationCoordinate2D? {
        guard let loc = activity?.location else { return nil }
        return CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 카드는 이 자리에 무조건 둔다 — Group·AnyView·가변 .id로 감싸면 줄 에디터의
                    // 지역 상태가 매번 새 UUID로 앉아 장소 이름을 한 글자도 못 친다. nil→값 전이는
                    // .task가 딱 한 번 일으킨다.
                    if let card = form?.card {
                        EditCardView(card: card, busy: saving, actions: actions,
                                     chrome: EditCardChrome(header: nil, confirmTitle: nil),
                                     outsideTapCount: outsideTapCount)
                    }
                    ForEach(seriesReport) { line in
                        if line.done {
                            // "반복 전체" 붙이기의 결과는 시트를 열어 둔 채 말한다(J-18) — 회차 수를
                            // 말하는 이 줄이 사용자가 받는 유일한 확인이다.
                            Label(line.text, systemImage: "checkmark")
                                .font(.callout).foregroundStyle(Theme.travelInk)
                        } else {
                            Text(line.text).font(.callout).foregroundStyle(Theme.muted)
                        }
                    }
                    if let saveReport {
                        // 저장 결과는 시트 안에서 말한다(REQ-010) — 닫고 나면 들을 자리가 없다.
                        Label(saveReport, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(Theme.warn)
                    }
                    if activity?.recurrenceId != nil {
                        // 반복 회차 안내는 글을 없애고 repeat 글리프만 남긴다(운영자 §10 부연 설명
                        // 문구 없음). 빠진 회차는 번호가 nil이라 이 조건에서 아이콘이 저절로 사라진다.
                        // 보이는 것은 그림뿐이지만 Label의 제목이 접근성 이름 '반복 일정'으로 읽힌다.
                        Label("Repeating Event", systemImage: "repeat").labelStyle(.iconOnly)
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    if placeCoord != nil {
                        nearbySection
                    }
                    Button("Delete", role: .destructive) {
                        if activity?.recurrenceId != nil {
                            showingDeleteMenu = true
                        } else {
                            showingDeleteConfirm = true
                        }
                    }
                }
                .padding(24)
            }
            .onTapGesture { outsideTapCount += 1 }
            .background(Theme.bg)
            .navigationTitle("Edit Activity")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!(form?.card.isReady ?? false) || saving)
                }
            }
            .confirmationDialog("How do you want to delete this repeating event?", isPresented: $showingDeleteMenu, titleVisibility: .visible) {
                Button(singleOccurrenceDeleteTitle, role: .destructive) { delete() }
                Button("Delete Entire Series", role: .destructive) { deleteWholeSeries() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteConfirmTitle, isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            }
            // "반복 전체 / 이 일정만" 선택창(REQ-016) — 반복 삭제 선택창과 같은 모양이다(렌즈 B.1).
            .confirmationDialog(seriesAskTitle, isPresented: $showingSeriesAddAsk, titleVisibility: .visible) {
                Button(seriesWholeTitle) { pickSeriesAdd(true) }
                Button("This Event Only") { pickSeriesAdd(false) }
                // 취소는 아무것도 저장하지 않고 편집 화면으로 돌아간다 — 쓰기는 단추를 골라야
                // 시작하므로 되돌릴 것도 없다.
                Button("Cancel", role: .cancel) {}
            }
            // 선택창이 닫힐 때(단추·바깥 탭 모두) 잡아 둔 저장 몸통을 지운다 — 단추 동작이 먼저
            // 실행되고 닫힘이 온다므로 저장은 이미 필요한 값을 복사해 간 뒤다.
            .onChange(of: showingSeriesAddAsk) { _, shown in
                if !shown { pendingSeriesSave = nil }
            }
        }
        // 카드는 저장된 활동에서 정확히 한 번 만든다 — 이후로는 줄을 제자리에서 고친다.
        .task { bootstrap() }
        // 시트가 내려가도 예약돼 있던 검색은 350ms 뒤 그대로 나간다 — 사라진 화면의 결과를 위해
        // 네트워크를 태우지 않는다는 정리 계약의 폼 쪽 이행이다(AddEventView와 같은 판단).
        .onDisappear {
            var d = placeDebounce
            d.cancelAll()
            placeDebounce = d
            // 진행 중인 주변 조회·측위 대기도 끊는다 — 위 검색과 같은 정리 계약, 취소는 진행 중 요청까지 끊는다.
            nearbyTask?.cancel()
            originLocationTask?.cancel()
        }
    }

    /// 카드 뷰가 부르는 동작을 화면의 함수로 잇는 어댑터. rechooseTimeBasis·chooseTime는 이
    /// 카드에 기준 있는 시각 줄이 하나도 없어 올 수 없는 경로다 — 서명 채움일 뿐이고, 기준 없는
    /// 줄의 확정은 chooseTimePlain으로 간다.
    private var actions: EditCardActions {
        EditCardActions(
            chooseValue: { choose(field: $0, value: $1) },
            rechooseTimeBasis: { _, _ in },
            chooseTime: { _, _, _ in false },
            chooseTimePlain: { confirmPlainTime(field: $0, date: $1) },
            choosePlace: { choosePlace(field: $0, place: $1) },
            searchPlaces: { searchPlaces(field: $0, text: $1) },
            submitCustom: { submitCustom(field: $0, text: $1) },
            setTitleText: { setTitleText(field: $0, text: $1) },
            closedSearchText: { form?.closedSearchText(field: $0) ?? "" },
            chooseCandidate: { chooseCandidate(field: $0, place: $1) },
            closeDial: { field, _, now in closeDial(field: field, now: now) },
            // 카드 쪽 확인 버튼은 크롬으로 꺼져 있지만 동작 자체는 화면의 저장이 곧 확인이다.
            confirm: { save() }
        )
    }

    // MARK: - 카드 만들기

    /// 화면이 뜨는 동안 딱 한 번, 저장된 활동에서 카드를 만든다. 구간 줄의 시드는 전부
    /// LegCardForm.seeded가 안다(REQ-011 — 반복 회차도 연결된 구간으로 시드하고, 연결이
    /// 없으면 토글이 꺼진 채로 보인다).
    private func bootstrap() {
        guard form == nil, let a = activity else { return }
        let legs = store.legs(of: a.id)
        var f = LegCardForm.seeded(activity: a, outbound: legs.outbound, returnLeg: legs.return,
                                   noPlaceValue: PlaceTokens.noPlace,
                                   placeOptions: placeOptions, favoriteOptions: favoriteOptions)
        // 즐겨찾기는 줄이 서는 시점에 좌표까지 확정해 둔다 — 라벨로 고르는 옛 길의 씨앗이다.
        for fav in store.favorites { f.favoritePlaces[fav.label] = fav.place }
        seed = f
        seedLegs = legs
        form = f
    }

    /// 장소 줄의 즐겨찾기 옵션 — 좌표까지 실어 만든다(REQ-005: 목록의 행이 자기 Place를 직접
    /// 나른다). '장소 없음' 행은 모델 쪽 공장(manualPlaceRow)이 줄에 얹는다.
    private var placeOptions: [EditField.Option] {
        store.favorites.map { .init(label: $0.label, value: $0.label, place: $0.place) }
    }

    private var favoriteOptions: [EditField.Option] {
        store.favorites.map { .init(label: $0.label, value: $0.label, place: $0.place) }
    }

    // MARK: - 칩 선택 · 확정

    /// 행을 탭했을 때. 값 적기·좌표 걸기·구간 줄의 멤버십 전이는 전부 LegCardForm이 안다 —
    /// 문법이 뷰에 남으면 생성 카드와 규칙이 두 벌이 된다(REQ-007). 화면이 더하는 일은 문법이
    /// 모르는 것 둘: 장소가 바뀌면 주변 맛집 결과를 낡은 채로 두지 않는 것과, '현재 위치' 행
    /// (가는 이동 출발지 O-B6 · 장소 줄 REQ-003 (2), 보완 E) — 권한 판정·측위 대기는
    /// PlaceLineResolve(EditCard.swift)가 단독으로 안다.
    private func choose(field: UUID, value: String, place: Place? = nil) {
        guard let f = form, let row = f.card.fields.first(where: { $0.id == field }) else { return }
        let key = row.key
        let previous = row.chosen
        if place == nil, value == PlaceTokens.currentLocation,
           key == LegRowKeys.originQuery || key == "location_query" {
            pickCurrentLocationRow(field, isOrigin: key == LegRowKeys.originQuery)
            return
        }
        form?.choose(field: field, value: value, place: place)
        // 출발지 줄의 권한 거부 안내는 다른 값을 고르는 순간 낡는다 — 남아 있으면 잡음이다(note의
        // 원칙, LegCardForm이 location_query 줄에서 하는 일과 같은 자리).
        if key == LegRowKeys.originQuery { setRowNote(field, nil) }
        if key == "location_query", previous != value {
            // 좌표가 달라질 장소를 골랐다는 뜻이다 — 비우지 않으면 저장 뒤 새 장소 이름 아래
            // 옛 장소의 식당이 남는다(§1.2의 결함이 형태만 바꿔 살아남는 경로, REQ-021).
            // 도는 중인 옛 장소 조회도 취소한다 — 놔두면 착지해서 막 비운 목록을 옛 결과로 다시
            // 채운다. 취소를 여기 더해도 거짓 "찾지 못함"이 안 생기는 건 가드가 이미 앞이라
            // 취소된 조회가 빈 결과를 쓸 길이 없기 때문이다(t12 sync N2·N3).
            nearbyTask?.cancel()
            nearby = []
            nearbyLoaded = false
        }
    }

    // MARK: - 현재 위치 행(가는 이동 출발지 O-B6 · 장소 줄 REQ-003 (2))

    /// '현재 위치' 행을 탭했을 때 — 두 줄(출발지·장소)이 같은 몸통을 공유한다. 권한이 거부·제한이면
    /// 값이 되지 않고 안내 문구만 띄운다(chosen이 nil이라 저장은 이미 잠겨 있다). 좌표가 이미 있으면
    /// 그 자리에서 확정하고, 없으면 측위를 기다리는 동안 줄의 busy가 알린다. 문구만 줄에 맞게
    /// 갈린다(O-S1-4). 생성 카드(AddActivityView)와 같은 몸통이다 — 이 화면만의 규칙이 없어
    /// 어느 쪽을 고쳐도 같게 움직인다.
    private func pickCurrentLocationRow(_ field: UUID, isOrigin: Bool) {
        let permissionNote = isOrigin ? PlaceLineResolve.locationPermissionNote
                                      : PlaceLineResolve.locationPermissionNoteForPlace
        if PlaceLineResolve.isLocationBlocked(location) {
            setRowNote(field, permissionNote)
            return
        }
        if let place = PlaceLineResolve.availablePlace(location) {
            choose(field: field, value: PlaceTokens.currentLocation, place: place)
            return
        }
        // 대기를 시작하는 순간의 줄 값 — 도착 시점의 채택 판정이 "그 사이 바뀌었나"를 이 값과 비교한다.
        let chosenAtWaitStart = form?.card.fields.first(where: { $0.id == field })?.chosen
        setRowBusy(field, true)
        // 대기도 취소-교체로 건다 — 행을 다시 타면 이전 대기가 새 대기와 나란히 돌게 두지 않는다.
        originLocationTask?.cancel()
        originLocationTask = Task { @MainActor in
            let place = await PlaceLineResolve.waitForCurrentPlace(location)
            // 취소로 끊긴 대기도 스피너부터 끈다 — '현재 위치' 행이 출발지·장소 두 줄로 늘며 하나의
            // 대기 슬롯을 공유하게 됐다. 뒤의 탭이 앞의 대기를 끊는데 가드가 먼저 반환하면 끊긴
            // 줄의 busy가 켜진 채 남아 스피너가 영구히 돈다(code-safety 결함 1, 생성 카드와 같은 몸통).
            setRowBusy(field, false)
            guard !Task.isCancelled else { return }
            // await에서 돌아온 뒤 줄 id로 다시 찾는다 — 기다리는 사이 장소를 지우는 등으로 출발지
            // 줄이 통째로 빠졌을 수 있다(조용히 버린다, setLookup과 같은 규율).
            guard let row = form?.card.fields.first(where: { $0.id == field }) else { return }
            if let place {
                // 기다리는 사이 다른 값을 골랐으면 덮어쓰지 않는다 — await 너머의 상태를 믿지
                // 않는다(AddEventView.prefillOrigin과 같은 규율). 기준은 "비어 있었나"가 아니라
                // "대기 시작 뒤 그대로인가"다: 수정 카드처럼 값이 미리 채워진 줄도 '현재 위치'를
                // 눌렀으면 받는다(R1).
                guard PlaceLineResolve.adoptsArrivedPlace(chosenAtWaitStart: chosenAtWaitStart,
                                                          chosenNow: row.chosen) else { return }
                choose(field: field, value: PlaceTokens.currentLocation, place: place)
            } else if PlaceLineResolve.isLocationBlocked(location) {
                // 기다림이 끝났는데 권한이 거부로 굳었다 — 안내로 말한다. 측위 시한만 넘긴 경우는
                // 값을 비워 둔 채 끝난다: 빈 줄이 곧 아직 안 골랐다는 뜻이라 두 번 말하지 않는다.
                setRowNote(field, permissionNote)
            }
        }
    }

    /// 줄의 note를 고친다 — 권한 안내를 얹고 지우는 유일한 길. form은 값 타입이라 갈아끼운다.
    private func setRowNote(_ field: UUID, _ note: String?) {
        guard var f = form, let i = f.card.fields.firstIndex(where: { $0.id == field }) else { return }
        f.card.fields[i].note = note
        form = f
    }

    /// 줄의 busy를 고친다 — 측위 대기의 스피너.
    private func setRowBusy(_ field: UUID, _ on: Bool) {
        guard var f = form, let i = f.card.fields.firstIndex(where: { $0.id == field }),
              f.card.fields[i].busy != on else { return }
        f.card.fields[i].busy = on
        form = f
    }

    /// 검색 후보를 탭했을 때 — 이름은 chosen에, 좌표는 이 순간 확정한다(REQ-021).
    private func choosePlace(field: UUID, place: Place) {
        choose(field: field, value: place.name, place: place)
    }

    /// A tap on a search-result row: the same pick, then the form remembers it came from a search so the
    /// closed field shows the place's own name. The pick clears the memory first, so the order matters.
    private func chooseCandidate(field: UUID, place: Place) {
        choosePlace(field: field, place: place)
        form?.markCandidatePick(field: field)
    }

    /// 직접입력(제목). 범위 밖은 받지 않는다 — 거절 표시는 카드 뷰가 띄운다. 장소 줄은 검색
    /// 에디터라 여기 오지 않는다.
    @discardableResult
    private func submitCustom(field: UUID, text: String) -> Bool {
        guard var f = form, let i = f.card.fields.firstIndex(where: { $0.id == field }),
              let value = f.card.fields[i].accepts(text) else { return false }
        f.card.fields[i].chosen = value
        form = f
        return true
    }

    /// 제목 칸의 입력(REQ-001) — 칸 문법은 매 입력이 확정이라 화면이 따로 두는 통로. 값 규칙은
    /// LegCardForm이 EditCard 단일 규칙에 넘긴다(생성 카드와 같은 몸통).
    private func setTitleText(field: UUID, text: String) {
        guard var f = form else { return }
        f.setTitleText(field: field, text: text)
        form = f
    }

    /// 다이얼 닫기(REQ-006 F1·REQ-010) — 확정 몸통은 LegCardForm.closeDial 한 곳에 살고 이
    /// 화면은 아무 것을 더 얹지 않는다(confirmPlainTime과 같은 자리 — 과거 알림 노트 계산은
    /// 생성 카드에만 있다). basis 인자는 무시한다 — 이 카드의 시각 줄은 전부 기준 없는 줄이라
    /// (REQ-001) 기준 있는 갈래가 올 일이 없다.
    private func closeDial(field: UUID, now: Date) {
        guard var f = form else { return }
        // now는 뷰가 다이얼을 연 순간 잡은 값이다(R3) — 새 Date()를 잡으면 보인 씨앗과 어긋난다.
        f.closeDial(field: field, now: now)
        form = f
    }

    /// 기준 없는 시각 줄의 확인 — 판정·전이의 단일 몸통은 LegCardForm.choosePlainTime이다
    /// (P-14: 생성 카드와 편집 카드가 같은 판정을 쓴다). 이 화면은 아무 것을 더 얹지 않는다 —
    /// 과거 알림 노트 계산은 생성 카드에만 있다.
    private func confirmPlainTime(field: UUID, date: Date) -> Bool {
        guard var f = form else { return false }
        let ok = f.choosePlainTime(field: field, date: date)
        form = f
        return ok
    }

    // MARK: - 장소 검색

    /// 카드 검색 에디터의 입력. 묶음 정책(350ms 지연·취소·같은 질의 스킵)은 공용 디바운서가
    /// 단독으로 소유한다 — 이 화면이 지연 시간을 들면 카카오 할당량 정책이 두 벌이 된다.
    /// The search centre is the device's current location (nil until a fix arrives), so the Google
    /// search favours places near the user.
    private func searchPlaces(field: UUID, text: String) {
        var deb = placeDebounce
        switch deb.gate(field, text) {
        case .clear:
            placeDebounce = deb
            setLookup(field, .idle)
        case .skip:
            placeDebounce = deb
        case .fire(let q):
            placeDebounce = deb
            setLookup(field, .searching)
            var armed = placeDebounce
            armed.arm(field, q) {
                let found = await store.placeSearch.search(q, near: location.currentLocation)
                guard !Task.isCancelled else { return }
                self.finishPlaceSearch(field: field, query: q, found: found)
            }
            placeDebounce = armed
        }
    }

    /// 완료 기록(noteDone)이 상태 반영보다 먼저다 — 이 순서를 바꾸면 첫 검색이 도는 중에 같은
    /// 질의를 다시 쳤을 때 유일한 결과가 버려지고 줄이 "찾는 중"에 갇힌다.
    private func finishPlaceSearch(field: UUID, query: String, found: [Place]) {
        var deb = placeDebounce
        deb.noteDone(field, query)
        placeDebounce = deb
        setLookup(field, found.isEmpty ? .empty
                  : .results(Array(found.prefix(PlaceSearch.maxSuggestions))))
    }

    /// 검색 상태를 줄에 얹는다. await에서 돌아온 뒤 id로 다시 찾는다 — 줄이 없어졌으면(장소를
    /// 지워 구간 줄이 빠졌으면) 조용히 버린다(위험 부류 H1과 같은 이유로 잡아둔 자리에 쓰지 않는다).
    private func setLookup(_ field: UUID, _ lookup: EditField.Lookup) {
        guard var f = form, let i = f.card.fields.firstIndex(where: { $0.id == field }) else { return }
        f.card.fields[i].lookup = lookup
        form = f
    }

    // MARK: - 읽기 보조

    private func field(_ key: String) -> EditField? {
        form?.card.fields.first { $0.key == key }
    }

    /// 줄에 걸린 좌표를 되찾는다 — 열쇠는 chosen 이름이 아니라 줄 신원이다. "장소 없음" 칩은
    /// 고르는 순간 그 줄의 좌표가 지워지므로(choose) 여기서 nil이 나온다.
    /// `chosen == nil`을 먼저 거르는 이유는 지금 막히는 경로가 있어서가 아니라 **실패 방향을
    /// 닫아두기 위해서다.** 좌표만 걸리고 이름은 없는 줄이 생기면 그 좌표가 조용히 실려
    /// 나간다 — 쓰기 자리가 이름과 좌표를 늘 함께 적어 도달 불가하지만, 그 불변식을 강제하는
    /// 것은 코드가 아니라 규율뿐이라 잘못된 장소보다 없는 장소가 낫다.
    private func confirmedPlace(_ key: String) -> Place? {
        field(key).flatMap { $0.chosen == nil ? nil : form?.confirmedPlaces[$0.id] }
    }

    // MARK: - 저장 · 삭제

    /// 저장 순서는 design §3 그대로: ① 활동 저장(제목·시간·장소 — "장소 없음"이면 clearPlace) →
    /// ② 구간 diff의 제거를 먼저 → ③ 구간 따라오기(바뀐 구간만, Store가 바이트 동일을 지킨다) →
    /// ④ 남은 diff를 수정 → 추가 순서로 하나씩 직렬 → ⑤ 결과 집계(미계산은 연산 뒤 레코드에서) →
    /// ⑥ 닫기(안내가 있으면 시트를 열어 둔 뒤 재시드). 결과에 이동시간 미계산·거절이 있으면
    /// 시트 안에 안내하고 열어 둔다(REQ-010·009).
    ///
    /// .add 연산이 있고 편집 회차가 아직 반복 안에 있으면 이 순서 **앞에** "반복 전체 /
    /// 이 일정만" 선택창이 낀다(REQ-016) — save()는 조사만 하고 여기서 돌아가며, 단추를 고르면
    /// performSave가 위 순서를 그대로 굴린다.
    private func save() {
        guard !saving, let a = activity,
              let start = field("start_iso")?.chosen.flatMap(BesirTime.parseDatetime)?.date,
              let end = field("end_iso")?.chosen.flatMap(BesirTime.parseDatetime)?.date,
              let seed, let current = form else { return }
        let newPlace = confirmedPlace("location_query")
        let ops = LegSavePlanner.ops(seed: seed, current: current,
                                     outboundLeg: seedLegs.outbound, returnLeg: seedLegs.return)
        // 붙일 회차가 있는 역할만 묻는다 — 붙일 곳이 없는 역할(N=0)은 묻지 않고 "이 일정만"처럼
        // 흐른다(B.1 꼬리). 그날이 반복에서 빠지는 것은 역할과 무관하게 그대로다(B.3 안내가 미리
        // 말한다). preview가 nil이면 편집 회차가 이미 반복 밖(단독 일정)이라 물을 대상이 없다.
        var asks: [PendingSeriesSave.Ask] = []
        for op in ops {
            guard case .add(let role, _, _, _, _, _) = op,
                  let preview = store.previewSeriesLegAdd(activityId: a.id, role: role),
                  !preview.wouldAddIds.isEmpty else { continue }
            asks.append(.init(role: role, preview: preview))
        }
        if !asks.isEmpty {
            pendingSeriesSave = PendingSeriesSave(asks: asks, ops: ops, activity: a,
                                                  start: start, end: end, newPlace: newPlace,
                                                  seed: seed, current: current)
            showingSeriesAddAsk = true
            return
        }
        performSave(ops: ops, activity: a, start: start, end: end, newPlace: newPlace,
                    seed: seed, current: current, asks: nil)
    }

    /// 선택창 단추의 동작 — "반복 전체"면 잡아 둔 조사를, "이 일정만"이면 nil을 들고 같은 쓰기
    /// 몸통으로 간다. 저장에 필요한 값은 여기서 동기로 복사해 간다(선택창이 닫히며 pending이
    /// 지워져도 Task는 이미 복사본을 잡는다).
    private func pickSeriesAdd(_ wholeSeries: Bool) {
        guard let p = pendingSeriesSave else { return }
        performSave(ops: p.ops, activity: p.activity, start: p.start, end: p.end,
                    newPlace: p.newPlace, seed: p.seed, current: p.current,
                    asks: wholeSeries ? p.asks : nil)
    }

    /// save()의 쓰기 몸통 — 선택창 없이 온 저장과 선택창 단추 뒤의 저장이 같은 길을 쓴다.
    /// asks가 있는 역할의 .add는 addLegToSeries("반복 전체")로 흐르고, 나머지 .add는 addLeg
    /// 하나로 끝난다("이 일정만" — 만든 구간은 번호 없이, 빠짐은 addLeg 안에서 일어난다).
    private func performSave(ops: [LegSaveOp], activity a: ActivityBlock, start: Date, end: Date,
                             newPlace: Place?, seed: LegCardForm, current: LegCardForm,
                             asks: [PendingSeriesSave.Ask]?) {
        guard !saving else { return }
        saving = true
        seriesReport = []
        // 뷰는 구조체라 weak 캡처가 없다 — Task가 값 복사를 잡지만 @State는 참조 지지대라
        // 화면이 사라져도 쓰기가 시트 재생성으로 새는 일 없이 그 시트의 상태에만 닿는다
        // (EventDetailView의 Task 패턴과 같은 판단).
        Task { @MainActor in
            // ① 활동 먼저 확정한다 — 구간 시간 유도의 입력이 활동 시각이므로(design §3).
            // modifyActivity여야 묶인 구간이 같이 움직인다. "장소 없음"은 좌표가 nil로 풀리는
            // 것과 clearPlace로 구분해 넘긴다(REQ-004). 반환값(실제 변경)은 뒤의 빠짐 판단
            // (editedDetaches)이 쓴다 — 여기서 활동이 바뀌었다면 modifyActivity 안에서 이미
            // 그 회차가 빠져 있다(REQ-014).
            let activityChanged = store.modifyActivity(id: a.id,
                                 newTitle: field("title")?.chosen ?? "",
                                 newStart: start,
                                 newEnd: end,
                                 newPlace: newPlace,
                                 clearPlace: newPlace == nil)
            // 장소를 지운 저장은 구간이 이미 ①에서 함께 지워졌다 — 따라오기·diff를 돌지 않는다.
            if newPlace != nil {
                // ② diff의 제거를 먼저 돈다 — realign이 곧 지울 구간을 다시 쓰며 추정·캘린더
                // 업로드 큐에 올리는 일(sync 1차 W3)을 막고, 제거가 빈자리를 내야 추가의 중복
                // 검사가 그 빈자리를 본다(design §3).
                var refusedReasons: Set<String> = []
                var failed = 0
                for op in ops {
                    // removeLeg는 비-Optional 결과를 주므로 조건 바인딩이 아니라 그대로
                    // 패턴 매칭한다 — .removed는 세지 않고 .failed만 계수한다(기존 집계와 동등).
                    guard case .remove(let legId) = op else { continue }
                    if case .failed = store.removeLeg(legId: legId) { failed += 1 }
                }
                // ③ 구간 따라오기(바뀐 구간만, Store가 바이트 동일을 지킨다). 결과 플래그는
                // 따로 모으지 않는다 — 미계산 안내는 연산 뒤 레코드 하나에서 읽는다(sync 2차
                // F1: 통로별 플래그를 OR로 쌓으면 나중 통로가 값을 고쳐도 처음 통로의 거짓이
                // 남아 안내가 최종 레코드와 어긋난다).
                _ = await store.realignLegs(of: a.id)
                // ④ 남은 diff 연산(수정 → 추가)을 하나씩 직렬 실행한다. "반복 전체" 추가는
                // P-12 순서(형제→편집 회차→빠짐)를 Store가 지키고, 결과는 건수로 돌아오므로
                // LegOutcome 집계와 따로 모은다.
                var seriesResults: [(role: ScheduleAnchor,
                                     counts: (added: Int, skippedExisting: Int, skippedNoPlace: Int))] = []
                for op in ops {
                    let outcome: Store.LegOutcome
                    switch op {
                    case .remove:
                        continue
                    case .update(let legId, _, let outer, let mode, let buffer, let lead, let enabled):
                        outcome = await store.updateLeg(legId: legId, outerPlace: outer, mode: mode,
                                                             bufferMinutes: buffer,
                                                             notifyLeadMinutes: lead,
                                                             notifyEnabled: enabled)
                    case .add(let role, let outer, let mode, let buffer, let lead, let enabled):
                        if let ask = asks?.first(where: { $0.role == role }) {
                            // editedDetaches = "같은 저장이 편집 회차도 바꿨는가"(REQ-016 끝 문장).
                            // 활동 필드가 실제로 바뀌었거나 구간 줄 제거·수정이 있는 저장이 그렇다.
                            let editedDetaches = activityChanged
                                || ops.contains { if case .add = $0 { return false }; return true }
                            let counts = await store.addLegToSeries(editedActivityId: a.id,
                                                                    seriesId: ask.preview.seriesId,
                                                                    role: role, outerPlace: outer,
                                                                    mode: mode, bufferMinutes: buffer,
                                                                    notifyLeadMinutes: lead,
                                                                    notifyEnabled: enabled,
                                                                    targetActivityIds: ask.preview.eligibleIds,
                                                                    editedDetaches: editedDetaches)
                            seriesResults.append((role, counts))
                            continue
                        }
                        outcome = await store.addLeg(activityId: a.id, role: role, outerPlace: outer,
                                                          mode: mode, bufferMinutes: buffer,
                                                          notifyLeadMinutes: lead, notifyEnabled: enabled)
                    }
                    switch outcome {
                    case .refused(let reason):
                        // 결과가 어느 이유인지 말한다(REQ-009) — "저장됐다"로 세지 않는다.
                        refusedReasons.insert(Self.refusalText(reason))
                    case .created, .updated, .removed:
                        break
                    case .failed:
                        failed += 1
                    }
                }
                // ⑤ 결과 집계 — 안내가 없을 때만 ⑥ 닫는다. 문구의 의미가 기준이다(design §8).
                // 미계산은 저장이 끝난 레코드가 유일한 사실이다(계약 5) — 존재하는 구간의
                // travelSeconds가 nil이면 알리고, 없는 구간은 따지지 않는다. "반복 전체"를 돌린
                // 저장은 안내가 없어도 닫지 않는다(J-18) — 회차 수를 말하는 결과 줄이 사용자가
                // 받는 유일한 확인이기 때문이다.
                let finalLegs = store.legs(of: a.id)
                let unknownTravel = [finalLegs.outbound, finalLegs.return].compactMap { $0 }
                    .contains { $0.travelSeconds == nil }
                var messages: [String] = []
                if unknownTravel { messages.append("Couldn't calculate travel time") }
                if !refusedReasons.isEmpty { messages.append(refusedReasons.sorted().joined(separator: " · ")) }
                if failed > 0 { messages.append("Some travel couldn't be saved") }
                saving = false
                if seriesResults.isEmpty && messages.isEmpty {
                    dismiss()
                } else {
                    var lines: [SeriesResultLine] = []
                    // 문장은 모델 쪽 한 함수가 만든다(REQ-016 — "이미 있음"·"장소 없음" 두 이유를
                    // 각각 말한다, 렌즈 U-2). 화면은 그 줄을 그리기만 한다.
                    for (role, counts) in seriesResults {
                        for line in SeriesLegAddReport.lines(role: role, added: counts.added,
                                                             skippedExisting: counts.skippedExisting,
                                                             skippedNoPlace: counts.skippedNoPlace) {
                            lines.append(.init(text: line.text, done: line.done))
                        }
                    }
                    seriesReport = lines
                    saveReport = messages.isEmpty ? nil : messages.joined(separator: " · ")
                    // 안내를 띄우고 시트가 열린 채 남으면 diff 기준을 지금 상태로 다시 잡는다.
                    // bootstrap은 화면마다 한 번만 돈다 — 낡은 seed로 다시 저장하면 이미 끝난
                    // 제거가 .failed, 이미 만든 추가가 .refused(.duplicateRole)로 거짓 안내가
                    // 된다(sync 2차 F2). 다시 저장은 제목·끝점이 바뀐 구간의 추정을 다시 한다 —
                    // 끝점이 그대로인 nil 구간은 realignLegs가 건너뛴다(기존 동작, sync 최종 W1).
                    // seed는 매개변수가 지역으로 가려 self.로 쓴다. diff 기준을 current(저장
                    // 시작 때의 폼)로 잡는 이유: 방금 Store에 적용된 연산은 그 폼의 diff이므로 —
                    // 저장 도중 줄을 고쳤다면(줄 편집은 잠기지 않는다) 다음 diff는 그 새 값과
                    // 비교되어야 한다. 구간 목록은 방금 읽은 finalLegs 그대로 — 그 사이 Store를
                    // 고치는 호출은 없다.
                    self.seed = current
                    self.seedLegs = finalLegs
                }
            } else {
                saving = false
                dismiss()
            }
        }
    }

    // MARK: - "반복 전체 / 이 일정만" 선택창 문구(REQ-016, 렌즈 B.1)

    /// 제목 — 물은 역할에 따라 한쪽만 또는 둘 다.
    private var seriesAskTitle: String {
        let roles = pendingSeriesSave?.asks.map(\.role) ?? []
        let asksOut = roles.contains(.arrival), asksReturn = roles.contains(.departure)
        if asksOut && asksReturn { return "Where should the outbound and return travel go?" }
        return asksReturn ? "Where should the return travel go?" : "Where should the outbound travel go?"
    }

    /// 단추 1의 N — 붙일 회차의 합집합. 두 역할의 수가 다르면 같은 회차를 두 번 세지 않게
    /// 역할별 목록을 합쳐 중복을 뺀다.
    private var seriesWholeTitle: String {
        let n = Set((pendingSeriesSave?.asks ?? []).flatMap { $0.preview.wouldAddIds }).count
        return "Entire Series (occurrences: \(n))"
    }

    /// 거절 사유의 안내 문구 — 화면이 이유를 사실대로 말한다(REQ-009).
    private static func refusalText(_ reason: Store.LegRefusalReason) -> String {
        switch reason {
        case .duplicateRole: return "Couldn't create it because the same kind of travel already exists"
        case .noPlace: return "Can't create travel for an activity with no place"
        case .activityMissing: return "Couldn't create travel because the activity was already deleted"
        }
    }

    /// 삭제 확인 제목 — 딸린 이동 수를 Store 조회 하나로 읽는다(REQ-014). 반복 회차 안내 문구는
    /// 그대로 둔다(AC-011 (4)).
    private var deleteConfirmTitle: String {
        let n = store.explicitLegCount(of: activityId)
        return n >= 1 ? "Delete this activity and its linked travel (\(n))?" : "Delete this activity?"
    }

    /// 반복 회차 삭제 단추 글자(REQ-017) — 제목은 그대로 두고 단추에만 딸린 이동 수를 붙인다.
    /// 같은 Store 조회(deleteConfirmTitle)를 읽어 화면 안에서 계산이 두 벌이 되지 않게 한다.
    /// N이 0이면 숫자 없는 옛 글자 그대로다(운영자 J-20·[리드] 정리).
    private var singleOccurrenceDeleteTitle: String {
        let n = store.explicitLegCount(of: activityId)
        return n >= 1 ? "Delete This Event Only (with travel: \(n))" : "Delete This Event Only"
    }

    private func delete() {
        guard let a = activity else { return }
        store.deleteActivity(a)
        dismiss()
    }

    private func deleteWholeSeries() {
        guard let rid = activity?.recurrenceId else { return }
        store.deleteRecurringSeries(rid)
        dismiss()
    }

    // MARK: - 주변 맛집 추천 (be full sir)

    /// 활동 장소 좌표를 기준으로 주변 음식점·카페를 보여준다.
    /// 펼쳐야만 조회한다 — 상세를 열 때마다 장소 검색 API를 쓰면 낭비다.
    /// 좌표는 저장된 활동(store)의 것을 읽는다 — 카드에서 고른 중간값이 아니라 저장 결과가
    /// 근거여야 한다(REQ-021의 무효화 판단도 이 좌표 기준으로 짝지어 있다).
    @ViewBuilder
    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nearby").font(.headline)
            HStack {
                Label(nearbyTitle, systemImage: nearbyCategory.systemImage)
                Spacer()
                if loadingNearby { ProgressView().controlSize(.small) }
                Button(nearbyLoaded ? "Refresh" : "Show Suggestions") {
                    startNearby()
                }
                .buttonStyle(.borderless)
                .disabled(loadingNearby)
            }

            if nearbyLoaded {
                Picker("Type", selection: $nearbyCategory) {
                    ForEach(MealCategoryFilter.allCases) { c in
                        Label(c.title, systemImage: c.systemImage).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: nearbyCategory) { startNearby() }

                if nearby.isEmpty && !loadingNearby {
                    Text("Nothing found within 1 km.")
                        .font(.callout).foregroundStyle(Theme.muted)
                } else {
                    ForEach(nearby) { item in
                        nearbyRow(item)
                    }
                    if !nearby.isEmpty {
                        GoogleMapsAttribution()
                    }
                }
            }
            // 펼치기 전 캡션은 지웠다 — 무엇을 찾아줄지 예고하는 부연 설명이다(REQ-011 G6).
            // '추천 보기' 버튼이 절의 역할을 이미 말한다.
        }
    }

    /// The block title names the chosen type; the switch has no default so a third type fails to compile here.
    private var nearbyTitle: String {
        switch nearbyCategory {
        case .restaurant: return "Restaurant Suggestions"
        case .cafe: return "Cafe Suggestions"
        }
    }

    private func nearbyRow(_ item: NearbyPlace) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: nearbyCategory.systemImage)
                .foregroundStyle(Theme.activity)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.place.name).font(.subheadline).bold()
                HStack(spacing: 6) {
                    if !item.category.isEmpty {
                        Text(item.category).font(.caption).foregroundStyle(Theme.muted)
                    }
                    if let d = item.distanceText {
                        Text("· \(d)").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                if !item.place.address.isEmpty {
                    Text(item.place.address).font(.caption2).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            Spacer()
            if let urlString = item.url, let url = URL(string: urlString) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("View on Map")
            }
        }
        .padding(.vertical, 4)
    }

    /// 주변 조회는 언제나 여기를 거쳐 띄운다(취소-교체) — 두 발화 지점이 각자 Task를 만들면 이전
    /// 조회를 취소할 손잡이가 없다. nearbyCategory는 @State라 새 작업이 제 값을 읽는다.
    private func startNearby() {
        nearbyTask?.cancel()
        nearbyTask = Task { await loadNearby() }
    }

    private func loadNearby() async {
        // 취소 가드가 플래그를 마지막 조회에만 맡기는 이상(아래) 조기 반환에서도 내린다.
        guard let coord = placeCoord else {
            loadingNearby = false
            return
        }
        loadingNearby = true
        let found = await store.placeSearch.nearbyPlaces(category: nearbyCategory, near: coord)
        // 취소 가드를 스피너 해제·nearbyLoaded보다 앞에 둔다 — 종류를 연달아 바꾸면(B→C) 취소된
        // B가 곧바로 돌아와 C가 도는 중에 스피너를 내리고 새로고침이 다시 눌리게 한다. 취소된
        // 조회는 아무것도 쓰지 않고 플래그는 새 조회가 끝날 때 내린다. 그래도 플래그가 켜진 채
        // 남는 길은 placeCoord nil(섹션 자체가 숨는다)과 onDisappear(시트가 사라진다)뿐이라
        // 걸려 있어도 화면에 남지 않는다.
        guard !Task.isCancelled else { return }
        loadingNearby = false
        nearbyLoaded = true
        nearby = found
    }
}
