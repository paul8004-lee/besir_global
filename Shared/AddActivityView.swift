import SwiftUI

/// 이동이 아닌 체류형 활동(수업·근무·약속 등)을 수동으로 추가하는 화면.
/// 카드 맨 아래 '반복' 줄에 글로 적으면 반복 활동이 되고, 비워 두면 한 번짜리다(SPEC-UIKIT-019 REQ-001) —
/// 반복을 AI 채팅에서만 만들 수 있던 때는 "+"로 연 사용자가 같은 활동을 회차마다 다시 만들어야 했다.
///
/// 활동과 함께 "가는 이동 / 오는 이동"도 같이 만들 수 있다. 따로따로 만들면 둘 사이에 아무
/// 연결이 없어서 나중에 활동 블록을 옮겨도 이동 블록이 제자리에 남는데, 여기서 같이 만들면
/// `linkedActivityId`로 묶여서 활동을 옮길 때 이동도 따라 움직이고 지울 때도 같이 지워진다.
struct AddActivityView: View {
    @EnvironmentObject var store: Store
    /// 가는 이동 출발지의 '현재 위치' 행(O-B6)이 읽는 측위 상태 — 카드 뷰는 순수 값 뷰라 화면이
    /// 이 환경 객체를 받아 줄 동작에 넘겨 준다(권한 판정·대기는 PlaceLineResolve가 안다).
    @EnvironmentObject var location: LocationManager
    /// '반복' 칸을 마칠 때의 해석(interpretRecurrence)만 빌린다 — 해석은 격리 메서드라 채팅 상태를 읽지도
    /// 바꾸지도 않는다. 새 AI 객체를 만들지 않는 이유는 계약 4다. 시트는 띄우는 화면의 환경을 물려받는다.
    @Environment(\.dismiss) private var dismiss
    /// 시작 바퀴가 처음 서는 날 — 생성을 누를 때 보고 있던 날(t50 P3, 운영자 원문 "11/14일 활동일정
    /// 생성을 누르면 시작 바퀴가 11/14일로"). 값이 아니라 위치다: 시작 줄은 확인을 눌러야 정해진다.
    /// 기본값이 오늘인 이유는 날짜 맥락 없이 여는 호출부가 생겨도 옛 동작(오늘 기준)과 같게 하려는 것이다.
    var defaultDay: Date = Date()
    /// 빈칸 꾹 누르기(REQ-009)가 정한 확정 시작 — 있으면 시작 줄이 그 시각으로 확정된 채 열리고,
    /// 없으면(맥 '+', O-C1) 지금처럼 미선택으로 열린다. 시트를 뜨는 값에서 파생한다: 23:55 누름의
    /// 시드는 다음 날 00:00이므로 defaultDay도 그 날이 된다(O-A6).
    var presetStart: Date? = nil

    // 폼의 값은 전부 카드(card.fields)에 산다 — 제출 판정도 card.isReady 하나다(REQ-010). 구간
    // (가는/오는 이동) 줄의 문법·좌표 사전·기억값은 뷰 밖의 LegCardForm이 한 몸으로 굴리고,
    // 이 화면은 그 값을 @State로 하나 들고 있을 뿐이다(SPEC-UIKIT-009 REQ-007 — 문법이 두
    // 화면에 벌로 있으면 줄 문구·멤버십 규칙이 어느 한쪽만 늙는다). 화면이 직접 드는 것은
    // 카드가 가질 수 없는 것뿐: 검색 묶음, 진행 깃발, 캘린더 폴백값.
    @State private var form: LegCardForm?
    /// 카드 검색 에디터의 묶음(350ms 지연·취소·같은 질의 스킵). PlaceField 쪽에는 붙이지 않는다
    /// (REQ-042(b)) — 저쪽은 onSubmit·버튼 탭 두 경로뿐이라 글자마다 부르지 않아, 묶음이 막을
    /// 할당량 소모가 애초에 없다.
    @State private var placeDebounce = PlaceSearchDebouncer()
    @State private var saving = false
    /// 캘린더 줄이 설정 조건으로 아예 없을 때 저장에 쓸 값. 줄이 화면에 있으면 카드가 정답이다.
    @State private var calendarDefault = true
    /// '현재 위치' 행의 측위 대기. 행을 다시 타면 이전 대기를 취소한다 — 대기가 둘 나란히 돌면
    /// 같은 확정이 두 번 일어난다(AddEventView.prefillTask와 같은 형태).
    @State private var originLocationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 카드는 이 자리에 무조건 둔다 — Group·AnyView·가변 .id로 감싸면 줄 에디터의
                    // 지역 상태가 매번 새 UUID로 앉아 장소 이름을 한 글자도 못 친다(REQ-013(b)).
                    // nil→값 전이는 .task가 딱 한 번 일으킨다.
                    if let card = form?.card {
                        EditCardView(card: card, busy: saving, actions: actions,
                                     chrome: EditCardChrome(header: nil, confirmTitle: nil))
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .background(Theme.bg)
        #if os(macOS)
        .frame(width: 560, height: 640)
        #endif
        // 카드는 정확히 한 번 만든다(REQ-013(a)) — 이후로는 줄을 제자리에서 고치거나 넣고 뺀다.
        .task { bootstrap() }
        // 시트가 내려가도 예약돼 있던 검색은 350ms 뒤 그대로 나간다 — 사라진 화면의 결과를 위해
        // 네트워크를 태우지 않는다는 정리 계약의 폼 쪽 이행이다(AddEventView와 같은 판단).
        .onDisappear {
            var d = placeDebounce
            d.cancelAll()
            placeDebounce = d
            // 진행 중인 측위 대기도 끊는다 — 위 검색과 같은 정리 계약.
            originLocationTask?.cancel()
        }
    }

    private var header: some View {
        HStack {
            Text("New Activity").font(.title2).bold()
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    /// 카드 뷰가 부르는 동작을 화면의 함수로 잇는 어댑터. rechooseTimeBasis·chooseTime는 이
    /// 카드에 기준 있는 시각 줄이 하나도 없어(REQ-001) 올 수 없는 경로다 — 서명 채움일 뿐이고,
    /// 기준 없는 줄의 확정은 chooseTimePlain으로 간다.
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
            closeDial: { field, _, now in closeDial(field: field, now: now) },
            // 이 카드의 '반복' 줄은 하나라 줄 id가 필요 없다 — 폼이 키로 찾는다.
            commitRecurrence: { _ in await commitRecurrence() },
            // 카드 쪽 확인 버튼은 크롬으로 꺼져 있지만 동작 자체는 화면의 저장이 곧 확인이다.
            confirm: { await save() }
        )
    }

    // MARK: - 카드 만들기

    /// 시트가 뜨는 동안 딱 한 번 카드를 만든다(REQ-013(a)).
    private func bootstrap() {
        guard form == nil else { return }
        // 줄 목록(제목 → 장소 → 시작·종료 → 캘린더 → '반복')은 모델 쪽 한 정의에서 받는다(SPEC-UIKIT-019 REQ-001) —
        // 뷰에 literal로 두면 드라이버가 '반복' 줄이 마지막인지를 재지 못한다. 캘린더 줄은 카드 생성 시점의 구글
        // 연결 상태로 정한다(D2): 연결이 없으면 줄 없이 기본값만 저장에 쓰이고, 나중에 연결하면 서버가 그 값을 따른다.
        calendarDefault = store.calendarSyncDefault
        let fields = LegCardForm.manualNewActivityRows(
            favorites: favoriteOptions, defaultDay: defaultDay, now: Date(), presetStart: presetStart,
            calendarDefaultOn: nil)
        var f = LegCardForm(card: EditCard(fields: fields), favoriteOptions: favoriteOptions)
        // 즐겨찾기는 줄이 서는 시점에 좌표까지 확정해 둔다(REQ-010) — 라벨로 고르는 옛 길의 씨앗이다.
        for fav in store.favorites { f.favoritePlaces[fav.label] = fav.place }
        form = f
    }

    /// 즐겨찾기 옵션 — 좌표까지 실어 만든다(REQ-005: 목록의 행이 자기 Place를 직접 나른다).
    private var favoriteOptions: [EditField.Option] {
        store.favorites.map { .init(label: $0.label, value: $0.label, place: $0.place) }
    }

    // MARK: - 칩 선택과 줄 멤버십

    /// 행을 탭했을 때. 값 적기·좌표 걸기·구간 줄의 멤버십 전이는 전부 LegCardForm이 안다 —
    /// 문법이 뷰에 남으면 활동 카드가 같은 규칙을 다시 배우게 된다(SPEC-UIKIT-009 REQ-007).
    private func choose(field: UUID, value: String, place: Place? = nil) {
        // '현재 위치' 행(가는 이동 출발지 O-B6 · 장소 줄 REQ-003 (2), 보완 E) — 값은 좌표와 함께
        // 도착해야 확정이므로 여기서 갈라진다. 권한 판정·측위 대기는 PlaceLineResolve(EditCard.swift)가
        // 단독으로 안다.
        if place == nil, value == PlaceTokens.currentLocation,
           let key = form?.card.fields.first(where: { $0.id == field })?.key,
           key == LegRowKeys.originQuery || key == "location_query" {
            pickCurrentLocationRow(field, isOrigin: key == LegRowKeys.originQuery)
            return
        }
        form?.choose(field: field, value: value, place: place)
        // 출발지 줄의 권한 거부 안내는 다른 값을 고르는 순간 낡는다 — 남아 있으면 잡음이다(note의
        // 원칙, LegCardForm이 location_query 줄에서 하는 일과 같은 자리).
        if form?.card.fields.first(where: { $0.id == field })?.key == LegRowKeys.originQuery {
            setRowNote(field, nil)
        }
        recomputePastAlarmNotes()
    }

    // MARK: - 현재 위치 행(가는 이동 출발지 O-B6 · 장소 줄 REQ-003 (2))

    /// '현재 위치' 행을 탭했을 때 — 두 줄(출발지·장소)이 같은 몸통을 공유한다. 권한이 거부·제한이면
    /// 값이 되지 않고 안내 문구만 띄운다(chosen이 nil이라 저장은 이미 잠겨 있다). 좌표가 이미 있으면
    /// 그 자리에서 확정하고, 없으면 측위를 기다리는 동안 줄의 busy가 알린다. 문구만 줄에 맞게
    /// 갈린다(O-S1-4 — 장소 줄에는 '출발지'라는 낱말이 맞지 않다).
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
            // 줄의 busy가 켜진 채 남아 스피너가 영구히 돈다(code-safety 결함 1).
            setRowBusy(field, false)
            guard !Task.isCancelled else { return }
            // await에서 돌아온 뒤 줄 id로 다시 찾는다 — 기다리는 사이 다리를 꺼 출발지 줄이 통째로
            // 빠졌을 수 있다(조용히 버린다, setLookup과 같은 규율).
            guard let row = form?.card.fields.first(where: { $0.id == field }) else { return }
            if let place {
                // 기다리는 사이 다른 값을 골랐으면 덮어쓰지 않는다 — await 너머의 상태를 믿지
                // 않는다(AddEventView.prefillOrigin과 같은 규율). 기준은 "비어 있었나"가 아니라
                // "대기 시작 뒤 그대로인가"다: 값이 미리 채워진 줄도 '현재 위치'를 눌렀으면 받는다(R1).
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

    // MARK: - 확정 · 직접입력

    /// 기준 없는 시각 줄의 확인 — 판정·전이의 단일 몸통은 LegCardForm.choosePlainTime이다
    /// (P-14: 생성 카드와 편집 카드가 같은 판정을 쓴다). 이 화면이 더 얹는 일은 하나, 확정에
    /// 성공한 뒤에 과거 알림 노트를 다시 맞추는 것 — 전이(종료 비움 포함)가 끝난 뒤에 돌아야
    /// 비워진 종료로 잘못 판정한 노트를 종료 노트가 지운다. 거절 경로에는 두지 않는다(plan §2.2 ①).
    private func confirmPlainTime(field: UUID, date: Date) -> Bool {
        guard var f = form else { return false }
        let ok = f.choosePlainTime(field: field, date: date)
        form = f
        if ok { recomputePastAlarmNotes() }
        return ok
    }

    /// 다이얼 닫기(REQ-006 F1·REQ-010) — 확정 몸통은 LegCardForm.closeDial 한 곳에 살고 이 화면은
    /// 과거 알림 노트만 다시 맞춘다(confirmPlainTime 성공 경로와 같은 뒷정리). 성공 여부를 몸통이
    /// 돌려주지 않아 무조건 다시 계산하지만, 그 계산은 줄 상태에서 노트를 다시 읽는 것뿐이라
    /// 거짓이 생기지 않는다. basis 인자는 무시한다 — 이 카드의 시각 줄은 전부 기준 없는 줄이라
    /// (REQ-001) 기준 있는 갈래가 올 일이 없다.
    private func closeDial(field: UUID, now: Date) {
        guard var f = form else { return }
        // now는 뷰가 다이얼을 연 순간 잡은 값이다(R3) — 여기서 Date()를 새로 잡으면 정시를 넘긴 사이
        // 화면이 보인 씨앗과 확정되는 씨앗이 어긋난다.
        f.closeDial(field: field, now: now)
        form = f
        recomputePastAlarmNotes()
    }

    /// 검색 후보를 탭했을 때 — 이름은 chosen에, 좌표는 이 순간 확정한다(REQ-010). 좌표를 여기서
    /// 먼저 적고 choose를 부르는 대신 인자로 실어 보내는 이유: 쓰기 자리가 하나면 "검색이
    /// 즐겨찾기를 이긴다"가 호출 순서가 아니라 구조로 정해진다.
    private func choosePlace(field: UUID, place: Place) {
        choose(field: field, value: place.name, place: place)
    }

    /// 직접입력(제목·여유·알림). 범위 밖은 받지 않는다 — 거절 표시는 카드 뷰가 띄운다. 장소 줄은
    /// 검색 에디터라 여기 오지 않는다.
    @discardableResult
    private func submitCustom(field: UUID, text: String) -> Bool {
        guard var f = form, let i = f.card.fields.firstIndex(where: { $0.id == field }),
              let value = f.card.fields[i].accepts(text) else { return false }
        f.card.fields[i].chosen = value
        form = f
        recomputePastAlarmNotes()
        return true
    }

    /// 제목 칸의 입력(REQ-001) — 칸 문법은 매 입력이 확정이라 화면이 따로 두는 통로. 값 규칙은
    /// LegCardForm이 EditCard 단일 규칙에 넘긴다. 과거 알림 노트를 다시 계산하지 않는 이유:
    /// 제목은 그 판정의 재료가 아니다(submitCustom은 여유·알림 줄도 함께 받아 계산한다).
    private func setTitleText(field: UUID, text: String) {
        guard var f = form else { return }
        f.setTitleText(field: field, text: text)
        form = f
    }

    // MARK: - 과거 알림 노트 재계산(SPEC-ONTIME-002 §2.2)

    /// 과거 알림 노트를 두 줄 모두 다시 맞춘다 — 시각 확정·칩·직접입력 뒤에 세 래퍼(choose·
    /// chooseTimePlain 성공 경로·submitCustom)가 공통으로 부른다. 칩 탭(LegCardForm.choose)과
    /// 직접입력은 노트를 다시 조립하지 않아 여기가 없으면 알림을 껐다 켰을 때 옛 노트가 남는다
    /// (AddEventView가 알림 토글 뒤 syncFieldExtras를 부르는 것과 같은 구멍). 그 줄의 다른
    /// 노트는 보존한다 — 종료가 비워진 순간(옛 시작을 몰랐거나 지킬 길이가 없어 따라가지 못한 때) 돌아오는
    /// 판정은 거짓이라 "종료는 시작보다 뒤여야 해요"를 덮지 않는다.
    private func recomputePastAlarmNotes() {
        guard var f = form else { return }
        // 읽는 우선순위는 저장(Store.saveManualActivity)과 같다 — 폼이 보여주는 예측이 저장될 값과 어긋나면 안 된다.
        let verdict = NotificationManager.activityPastAlarm(
            hasPlace: confirmedPlace("location_query") != nil,
            hasOutbound: field(LegRowKeys.outboundEnabled)?.chosen == "true",
            hasReturn: field(LegRowKeys.returnEnabled)?.chosen == "true",
            start: chosenIn("start_iso").flatMap(BesirTime.parseDatetime)?.date,
            end: chosenIn("end_iso").flatMap(BesirTime.parseDatetime)?.date,
            bufferMinutes: field(LegRowKeys.bufferMinutes)?.chosen.flatMap { Int($0) } ?? 0,
            leadMinutes: field(LegRowKeys.notifyLeadMinutes)?.chosen.flatMap { Int($0) }
                ?? Int(f.lastNotifyLead) ?? 0,
            wants: field(LegRowKeys.notifyEnabled)?.chosen != "false",
            now: Date())
        setPastAlarmNote(&f, key: "start_iso", past: verdict.outbound)
        setPastAlarmNote(&f, key: "end_iso", past: verdict.returnLeg)
        form = f
    }

    /// 그 줄의 노트가 과거 알림 문장(또는 비어 있음)일 때만 갈아끼운다 — 다른 노트가 앉아 있으면
    /// 그 노트가 이긴다.
    private func setPastAlarmNote(_ f: inout LegCardForm, key: String, past: Bool) {
        guard let i = f.card.fields.firstIndex(where: { $0.key == key }) else { return }
        if f.card.fields[i].note == nil || f.card.fields[i].note == NotificationManager.activityPastAlarmNote {
            f.card.fields[i].note = past ? NotificationManager.activityPastAlarmNote : nil
        }
    }

    // MARK: - 장소 검색

    /// 카드 검색 에디터의 입력. 묶음 정책(350ms 지연·취소·같은 질의 스킵)은 공용 디바운서가
    /// 단독으로 소유한다 — 이 화면이 지연 시간을 들면 카카오 할당량 정책이 두 벌이 된다.
    /// 검색 기준점은 없다(옛 PlaceField와 같다) — 출발지 근처를 우선할 근거가 이 화면엔 없다.
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
                let found = await self.store.placeSearch.search(q, near: nil)
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

    /// 검색 상태를 줄에 얹는다. await에서 돌아온 뒤 id로 다시 찾는다 — 줄이 없어졌으면(다리를
    /// 꺼서 출발지 줄이 빠졌으면) 조용히 버린다(위험 부류 H1과 같은 이유로 잡아둔 자리에 쓰지
    /// 않는다).
    private func setLookup(_ field: UUID, _ lookup: EditField.Lookup) {
        guard var f = form, let i = f.card.fields.firstIndex(where: { $0.id == field }) else { return }
        f.card.fields[i].lookup = lookup
        form = f
    }

    // MARK: - 읽기 보조

    private func field(_ key: String) -> EditField? {
        form?.card.fields.first { $0.key == key }
    }

    private func chosenIn(_ key: String) -> String? {
        field(key)?.chosen
    }

    /// 줄에 걸린 좌표를 되찾는다 — 열쇠는 chosen 이름이 아니라 줄 신원이다. "장소 없음" 칩은
    /// 고르는 순간 그 줄의 좌표가 지워지므로(choose) 여기서 nil이 나온다.
    /// `chosen == nil`을 먼저 거르는 이유는 지금 막히는 경로가 있어서가 아니라 **실패 방향을
    /// 닫아두기 위해서다.** 열쇠가 이름이던 시절엔 이름 없는 줄이 사전을 못 찾아 저절로 nil이
    /// 나왔다. 신원 열쇠에서는 "좌표만 걸리고 이름은 없는 줄"이 생기면 그 좌표가 조용히 실려
    /// 나간다 — 지금은 쓰기 세 자리가 이름과 좌표를 늘 함께 적어 도달 불가지만, 그 불변식을
    /// 강제하는 것은 코드가 아니라 규율뿐이라 한 절로 갚아 둔다(잘못된 장소보다 없는 장소가 낫다).
    private func confirmedPlace(_ key: String) -> Place? {
        field(key).flatMap { $0.chosen == nil ? nil : form?.confirmedPlaces[$0.id] }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button {
                Task { await save() }
            } label: {
                if saving { ProgressView().controlSize(.small) } else { Text("Add") }
            }
            .keyboardShortcut(.defaultAction)
            // 저장 중에는 라벨이 스피너로 접혀 이름이 사라진다 — VoiceOver는 여전히 무슨 버튼인지
            // 알아야 한다(AddEventView와 같은 판단).
            .accessibilityLabel("Add")
            // '반복' 줄이 해석 전이라서만 남은 카드도 누를 수 있다(019 m-4) — save가 해석을 먼저 끝내고 다시 판정한다.
            // 꺼 두면 누른 탭이 칸을 마치지 못해 해석이 영영 안 불렸다.
            .disabled(!((form?.card.isReady ?? false) || (form?.card.isReadyAfterRecurrenceCommit ?? false)) || saving)
        }
        .padding()
    }

    // MARK: - 저장

    /// 저장 몸통은 Store.saveManualActivity 하나다(SPEC-UIKIT-019) — 한 번짜리와 반복 가르기·좌표·시각 해석이 모두
    /// 그쪽에 있어 드라이버가 잰다. 실패(false)면 시트를 닫지 않는다: 닫으면 저장되지 않은 활동이 저장된 것처럼
    /// 사라진다. '반복' 줄이 해석 전이면 해석부터 끝내고, 그 결과로 다시 판정해 안 되면 멈춘다(안내는 해석이 줄 아래에
    /// 이미 세운다). saving은 해석 구간에도 서 있어 두 번 누름을 막는다. await 뒤에는 늘 form을 다시 읽는다(H1).
    private func save() async {
        guard form != nil else { return }
        saving = true
        if form?.card.isReadyAfterRecurrenceCommit == true { await commitRecurrence() }
        guard let g = form, g.card.isReady else {
            saving = false
            return
        }
        let saved = await store.saveManualActivity(g, calendarDefault: calendarDefault)
        saving = false
        if saved {
            dismiss()
        } else if form?.hasNoUpcomingOccurrence() == true {
            // 지금 이후 회차가 없어 아무것도 못 만들었다(지난 회차뿐) — 말없이 열려 있지 않게 기존 0회 안내를 걸고 잠근다.
            // 반복이 선 것만으로 걸면 다른 이유의 실패에도 "해당하는 날짜가 없어요"가 떠 앞 회차가 있는데 잠겼다(019 sync F1) —
            // 정말 없을 때만 거는 판정은 AI 카드가 확정 전에 쓰는 같은 관문이다.
            form?.markNoFutureOccurrence()
        }
    }

    // MARK: - '반복' 칸을 마칠 때(SPEC-UIKIT-019 REQ-004)

    /// 반복 칸을 마치면(바깥 탭·Return) 글을 해석한다. 해석이 필요한지는 폼이 정하고(빈 글·이미 해석한 글은 nil),
    /// 결과를 붙일지도 폼이 그 글과 대조해 정한다 — 뷰는 해석 결과를 들지 않는다. form은 값 타입이라 await 앞에서
    /// 한 번 써 두고, 돌아온 뒤 다시 읽어 붙인다: 기다리는 사이 사용자가 다른 줄을 고쳤을 수 있다(H1).
    private func commitRecurrence() async {
        guard var f = form else { return }
        // 빈 글이면 이 호출 안에서 한 번짜리로 서므로(종료 줄 모양까지) nil이어도 쓴 폼을 돌려놓아야 한다.
        let request = f.beginRecurrenceCommit()
        form = f
        guard let request else { return }
        guard var g = form else { return }
        g.applyRecurrenceInterpretation(arguments: nil, endDate: nil, for: request.text)
        form = g
        // 반복으로 읽히면 종료 줄이 반복 끝 시각으로 옮겨질 수 있다 — 과거 알림 판정의 재료가 바뀐다.
        recomputePastAlarmNotes()
    }
}

/// 장소 하나를 고르는 섹션(즐겨찾기 버튼 + 검색).
/// 활동 장소·출발지·도착지, 그리고 be full sir의 식사 일정 시트에서 같은 모양으로 쓴다
/// (화면마다 따로 만들면 검색 동작이 조금씩 갈라진다).
struct PlaceField: View {
    let title: String
    let systemImage: String
    @Binding var place: Place?

    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let p = place {
                HStack {
                    Image(systemName: systemImage).foregroundStyle(Theme.activity)
                    VStack(alignment: .leading) {
                        Text(p.name).bold()
                        if !p.address.isEmpty {
                            Text(p.address).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                    Button("Change") { place = nil }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
            } else {
                if !store.favorites.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.favorites) { fav in
                                Button(fav.label) { place = fav.place }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                HStack {
                    TextField("Search places or addresses", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { runSearch() }
                    // 아이콘만 있는 버튼은 VoiceOver가 읽을 문구가 없다 — 무엇을 여는지 직접 말해준다.
                    Button { runSearch() } label: {
                        if searching { ProgressView().controlSize(.small) }
                        else { Image(systemName: "magnifyingglass") }
                    }
                    .accessibilityLabel("Search places")
                    // 검색이 돌고 있을 때 다시 누르면 Task가 겹친다 — 다른 돋보기 둘과 같은 잠금.
                    .disabled(searching)
                }
                // 검색 결과는 이름이 겹칠 수 있어 좌표까지 합쳐 구분한다(같은 이름 두 곳이 한 줄로 합쳐지지 않게).
                ForEach(results, id: \.self) { found in
                    Button {
                        place = found
                        results = []
                    } label: {
                        HStack {
                            Image(systemName: "mappin.circle")
                            VStack(alignment: .leading) {
                                Text(found.name)
                                Text(found.address).font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    private func runSearch() {
        guard query.count >= 2 else { return }
        searching = true
        Task {
            let found = await store.placeSearch.search(query, near: nil)
            await MainActor.run { results = found; searching = false }
        }
    }
}
