import SwiftUI
import CoreLocation

struct AddEventView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationManager
    @Environment(\.dismiss) private var dismiss

    /// 편집할 기존 일정. nil이면 새 일정 추가.
    var editing: ScheduledEvent? = nil

    // 폼의 값은 전부 카드(card.fields)에 산다 — 제출 판정도 card.isReady 하나다(REQ-020). 화면이
    // 들고 있는 것은 카드가 가질 수 없는 것뿐: 좌표 사전, 이동시간 캐시, 진행 깃발, 그리고 줄이
    // 배열에서 빠져 있는 동안 그 값을 기억하는 상태들.
    @State private var card: EditCard?
    /// 칩·후보를 탭한 순간 좌표까지 확정된 장소. 열쇠는 이름이 아니라 **줄 신원**(EditField.id)이다.
    /// 이름으로 걸면 같은 상호의 다른 지점을 출발지·목적지 두 줄에서 고를 때(Place 주석이 말하는 그
    /// 겹침) 나중 쓰기가 앞 줄의 좌표까지 덮어 이동 0분짜리 일정이 되고, 출발 알람이 도착 시각으로
    /// 잡히는데 화면엔 이름만 보여 어긋난 걸 알 길이 없다. 줄 신원은 생성 때 한 번 찍히므로 두 줄이
    /// 겹칠 수가 없다. chosen은 이름만 담으므로 여기서 되찾고, 지연 해석 함수는 만들지 않는다
    /// (REQ-020: 만들면 resolvePlace의 두 번째 구현이 된다).
    @State private var confirmedPlaces: [UUID: Place] = [:]
    /// 즐겨찾기 칩의 라벨 → 장소. 칩 탭은 Place를 들고 오지 않고 라벨만 준다 — 그 라벨을 좌표로
    /// 푸는 씨앗이다. 줄 신원 사전과 합치지 않는 이유: 라벨은 줄이 아니라 즐겨찾기 목록의 것이고,
    /// 출발지 줄과 목적지 줄이 같은 칩을 고른다.
    @State private var favoritePlaces: [String: Place] = [:]
    @State private var estimates: [TransportMode: TravelEstimate] = [:]
    @State private var estimating = false
    /// 지금 떠 있는 estimateAll 호출의 수. estimating은 이 수가 0으로 돌아올 때만 내린다 —
    /// 먼저 끝난 계산이 내리면 새 계산이 아직 도는 중에도 스피너가 일찍 사라진다.
    @State private var estimateFlights = 0
    /// estimates가 어느 출발지·목적지 쌍에 대한 값인지. 저장 힌트는 폼의 좌표가 이 쌍과 같을
    /// 때만 넘긴다 — 재계산이 도는 창에 저장하면 estimates는 아직 옛 쌍의 값이라, 힌트로 흘러
    /// 옛 경로의 이동시간이 저장값으로 굳는다(수리 전에는 저장이 항상 새 좌표로 재조회해 이
    /// 창이 없었다 — code-safety F1).
    @State private var estimatesFor: (origin: Place, destination: Place)?
    @State private var saving = false
    /// 알림 줄이 토글 꺼짐으로 배열에서 빠져 있는 동안 마지막 값을 기억한다(REQ-022(b)) — 다시
    /// 켜면 이 값으로 되심는다.
    @State private var lastNotifyLead = EditCard.defaultNotifyLead
    /// 캘린더 줄이 설정 조건으로 아예 없을 때 저장에 쓸 값. 줄이 화면에 있으면 카드가 정답이다.
    @State private var calendarDefault = true
    /// 상태 래퍼로 감싼 이유: gate·arm·noteDone은 구조체를 고치는 호출이라, 래퍼 저장소를 향해
    /// 복사해 내보냈다 도로 반영해야 이 화면 안에서 정책 상태가 산다.
    @State private var placeDebounce = PlaceSearchDebouncer()
    /// 지금 떠 있는 이동시간 재계산. 출발지·목적지가 바뀔 때마다 이전 계산을 취소하고 새로 띄운다
    /// — 취소가 없으면 장소를 바꿀 때마다 카카오 조회가 한 벌씩 더 나간다(t11 sync
    /// N5). 취소는 URLSession의 진행 중 요청까지 끊는다.
    @State private var estimateTask: Task<Void, Never>?
    /// "현재 위치" 칩의 측위 대기 루프. 칩을 다시 타면 이전 대기를 취소한다 — 대기가 둘 나란히
    /// 돌면 같은 확정이 두 번 일어난다.
    @State private var prefillTask: Task<Void, Never>?

    /// "현재 위치" 칩의 값. AIAssistant.currentLocationToken과 같은 사정(빈 값과의 구분)으로
    /// 내부 토큰을 쓰되, 이 화면의 값은 모델로 흘러가지 않으므로 여기 private로 따로 둔다.
    /// 문자열은 PlaceTokens(t82 단일 집)을 참조한다 — 이 화면은 그 참조 외에는 이 단계에서
    /// 건드리지 않는다(O-B1).
    private static let hereMarker = PlaceTokens.currentLocation

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 카드는 이 자리에 무조건 둔다 — Group·AnyView·가변 .id로 감싸면 줄 에디터의
                    // 지역 상태(draft 등)가 매번 새 UUID로 앉아 장소 이름을 한 글자도 못 친다
                    // (REQ-021(b)). nil→값 전이는 .task가 딱 한 번 일으킨다.
                    if let card {
                        EditCardView(card: card, busy: saving, actions: actions,
                                     chrome: EditCardChrome(header: nil, confirmTitle: nil))
                    }
                    // 카드 아래 화면 소유 재계산 — 아이콘 + .help만으로는 iOS VoiceOver에서 이름이
                    // 없는 버튼이어서 글자 라벨을 얻었다(REQ-022(d)).
                    if hasTimeRow {
                        Button {
                            restartEstimates()
                        } label: {
                            Label("소요시간 다시 계산", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .background(Theme.bg)
        #if os(macOS)
        .frame(width: 640, height: 780)
        #endif
        // 카드는 정확히 한 번 만든다(REQ-021(a)) — 이후로는 줄을 제자리에서 고치거나 넣고 뺀다.
        .task { await bootstrap() }
        // 시트가 내려가도 예약돼 있던 검색은 350ms 뒤 그대로 나간다 — 사라진 화면의 결과를 위해
        // 네트워크를 태우지 않는다는 AI 쪽 정리 계약(cancelPlaceSearches)의 폼 쪽 이행이다.
        .onDisappear {
            var d = placeDebounce
            d.cancelAll()
            placeDebounce = d
            // 진행 중인 재계산·측위 대기도 끊는다 — 사라진 화면의 결과를 위해 네트워크를 태우지
            // 않는다는 위와 같은 정리 계약. 취소는 URLSession의 진행 중 요청까지 끊는다.
            estimateTask?.cancel()
            prefillTask?.cancel()
        }
        // 카드 뷰는 순수 값 뷰라 외부 상태를 스스로 못 본다 — 진행 깃발을 줄의 busy로 명시적으로
        // 잇는다. 잊으면 동작은 돼도 진행 표시가 조용히 안 뜬다(REQ-021(c), 휴면 계약).
        .onChange(of: estimating) { _, on in setBusy(key: "mode", on) }
        .onChange(of: location.isLocating) { _, _ in syncOriginBusy() }
    }

    private var header: some View {
        HStack {
            Text(editing == nil ? "새 일정" : "일정 편집").font(.title2).bold()
            Spacer()
            Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("취소") { dismiss() }
            Button {
                Task { await save() }
            } label: {
                if saving { ProgressView().controlSize(.small) }
                else { Text(editing == nil ? "추가" : "저장") }
            }
            .keyboardShortcut(.defaultAction)
            // 저장 중에는 라벨이 스피너로 접혀 이름이 사라진다 — VoiceOver는 여전히 무슨 버튼인지
            // 알아야 한다.
            .accessibilityLabel(editing == nil ? "추가" : "저장")
            .disabled(!(card?.isReady ?? false) || saving)
        }
        .padding()
    }

    /// 카드 뷰가 부르는 일곱 동작을 화면의 함수로 잇는 어댑터 — 컴포넌트는 이 묶음 너머를 모른다.
    private var actions: EditCardActions {
        EditCardActions(
            chooseValue: { choose(field: $0, value: $1) },
            rechooseTimeBasis: { rechooseTimeBasis(field: $0, basis: $1) },
            chooseTime: { chooseTime(field: $0, basis: $1, date: $2) },
            choosePlace: { choosePlace(field: $0, place: $1) },
            searchPlaces: { searchPlaces(field: $0, text: $1) },
            submitCustom: { submitCustom(field: $0, text: $1) },
            // 카드 쪽 확인 버튼은 크롬으로 꺼져 있지만 동작 자체는 화면의 저장이 곧 확인이다.
            confirm: { await save() }
        )
    }

    // MARK: - 카드 만들기

    /// 시트가 뜨는 동안 딱 한 번: 카드를 만들고, 편집 모드면 이동시간을 미리 계산해 두고, 출발지가
    /// 비어 있으면(새 일정·옛 일정) 현재 위치로 프리필한다.
    private func bootstrap() async {
        guard card == nil else { return }
        card = buildCard()
        // 출발지 줄의 진행 표시 규칙은 syncOriginBusy 한 곳에만 산다 — 카드를 처음 만들 때도
        // 같은 규칙으로 정한다. 시드를 따로 적으면 뜻이 같아도 규칙이 두 곳이 된다(sync 판정 N2).
        syncOriginBusy()
        // 스위치 줄이 없을 때(구글 연결 없음) 새 일정이 조용히 저장할 기본값 — 설정의 기본값 토글을 따른다(D2).
        // 편집이면 바로 아래에서 그 일정의 값으로 덮는다.
        calendarDefault = store.calendarSyncDefault
        if let e = editing {
            // 줄이 없을 수 있는 값들도 저장에 쓰는 기본값은 이벤트에서 가져온다
            lastNotifyLead = String(e.notifyLeadMinutes)
            calendarDefault = e.wantsCalendarSync
            await recomputeEstimates()
        }
        await prefillOrigin()
    }

    private func buildCard() -> EditCard {
        // 즐겨찾기는 칩을 만드는 시점에 좌표까지 확정해 둔다(REQ-020) — 탭 순간에 되찾기만 한다.
        for fav in store.favorites { favoritePlaces[fav.label] = fav.place }
        var originOptions = store.favorites.map { EditField.Option(label: $0.label, value: $0.label) }
        originOptions.append(.init(label: "현재 위치", value: Self.hereMarker))
        // 편집 모드는 값이 이미 있으니 에디터를 열어두지 않는다 — startsOpen은 "새 일정마다
        // 반드시 새로 치는 값"(REQ-003)을 위한 깃발이다.
        let fresh = editing == nil
        var fields: [EditField] = [
            .init(key: "title", kind: .title, label: "일정 제목", options: [], allowsCustom: true,
                  chosen: editing?.title, startsOpen: fresh),
            // 장소 줄이 검색창+목록 문법(S1)으로 바뀌며 옵션 배열의 토큰 칩은 목록에서 걸러진다
            // (PlaceLine.rows) — 같은 칩이 행으로 서야 기존 동작이 유지된다(REQ-003 "동작 무변경",
            // spec.md §2.1). 어댑터·저장 경로는 그대로다(O-B1).
            .init(key: "origin_query", kind: .place, label: "출발지", options: originOptions,
                  allowsCustom: true, chosen: editing?.origin?.name,
                  placeSpecials: PlaceLineSpecials.currentLocation),
            .init(key: "destination_query", kind: .place, label: "목적지",
                  options: store.favorites.map { .init(label: $0.label, value: $0.label) },
                  allowsCustom: true, chosen: editing?.destination.name, startsOpen: fresh),
        ]
        if let e = editing {
            // 편집 씨앗도 줄 신원으로 건다 — 이 자리의 fields는 바로 위에서 만든
            // [title, origin_query, destination_query] 순 지역 배열이라 인덱스가 곧 줄을 가리킨다.
            confirmedPlaces[fields[2].id] = e.destination
            // 옛 일정은 출발지가 nil일 수 있다 — 그러면 시각 줄 이하는 출발지가 정해진 뒤에
            // 생긴다(ensureGatedRows). 그때도 이벤트의 값으로 seed한다.
            if let o = e.origin {
                confirmedPlaces[fields[1].id] = o
                fields.append(contentsOf: gatedRows(seeding: e))
            }
        }
        return EditCard(fields: fields)
    }

    /// 출발지·목적지가 모두 골라지면 시각 줄 이하를 만든다 — 옛 화면의
    /// `if selectedPlace != nil && originPlace != nil` 조건부 섹션이 줄 멤버십으로 사는 자리다.
    private var hasTimeRow: Bool {
        card?.fields.contains { $0.key == "arrival_iso" } ?? false
    }

    private func ensureGatedRows() {
        guard var c = card, !hasTimeRow,
              c.fields.first(where: { $0.key == "origin_query" })?.chosen != nil,
              c.fields.first(where: { $0.key == "destination_query" })?.chosen != nil else { return }
        if let e = editing {
            // 늦게 생기는 줄도 편집 대상의 값으로 seed한다 — 기본값으로 덮으면 편집이 값을
            // 조용히 바꾸는 게 된다.
            c.fields.append(contentsOf: gatedRows(seeding: e))
        } else {
            // 폼의 문서화된 기본값 — 사용자가 보고 바꾸는 값이다(모델이 조용히 정한 값과 다르다)
            c.fields.append(contentsOf: gatedRows(datetime: nil, mode: TransportMode.transit.rawValue,
                                                  buffer: "5", notifyOn: "true", lead: EditCard.defaultNotifyLead,
                                                  calendar: String(store.calendarSyncDefault)))
        }
        card = c
        syncFieldExtras()
    }

    /// 편집 대상의 시각 줄 값. departure 기준에서 departureDate가 없으면 arrivalDate로 둔다 —
    /// 옛 loadEditing과 같은 판단.
    private func editingDatetime(_ e: ScheduledEvent) -> String {
        if (e.anchor ?? .arrival) == .arrival {
            return "arr:" + BesirTime.isoFormatter.string(from: e.arrivalDate)
        }
        return "dep:" + BesirTime.isoFormatter.string(from: e.departureDate ?? e.arrivalDate)
    }

    private func gatedRows(datetime: String?, mode: String, buffer: String, notifyOn: String,
                           lead: String, calendar: String) -> [EditField] {
        var rows: [EditField] = [
            .init(key: "arrival_iso", kind: .datetime, label: "시각", options: [],
                  allowsCustom: false, chosen: datetime),
            .init(key: "mode", kind: .mode, label: "이동수단",
                  options: TransportMode.allCases.map { .init(label: $0.title, value: $0.rawValue) },
                  allowsCustom: false, chosen: mode, busy: estimating),
            .init(key: "buffer_minutes", kind: .buffer, label: "도착 여유",
                  options: [.init(label: "0분", value: "0"), .init(label: "10분", value: "10"),
                            .init(label: "20분", value: "20"), .init(label: "30분", value: "30")],
                  allowsCustom: true, chosen: buffer),
            // 토글 줄은 생성 시 chosen을 seed한다 — 안 하면 isReady가 영원히 풀리지 않는다(REQ-001)
            .init(key: "notify_enabled", kind: .toggle, label: "출발 알림 받기",
                  options: [.init(label: "받기", value: "true"),
                            .init(label: "안 받기", value: "false")],
                  allowsCustom: false, chosen: notifyOn),
        ]
        // 알림을 끈 채 저장된 일정을 편집할 때는 리드 줄이 없다(켜면 lastNotifyLead로 돌아온다)
        if notifyOn == "true" { rows.append(notifyLeadRow(chosen: lead)) }
        // 구글 연결이 없는 빌드라 캘린더 줄은 묻지 않고 기본값(calendarDefault)만 저장에 쓴다.
        return rows
    }

    /// 편집 씨앗의 여섯 인자 변환은 이 과부하 하나에만 산다 — 변환식이 두 벌이면 필드가 늘 때
    /// 한쪽만 고치는 날이 온다(BesirMark 기하 상수를 한곳에 두는 것과 같은 이유).
    private func gatedRows(seeding e: ScheduledEvent) -> [EditField] {
        gatedRows(datetime: editingDatetime(e), mode: e.mode.rawValue,
                  buffer: String(e.bufferMinutes), notifyOn: String(e.wantsNotification),
                  lead: String(e.notifyLeadMinutes), calendar: String(e.wantsCalendarSync))
    }

    private func notifyLeadRow(chosen: String) -> EditField {
        .init(key: "notify_lead_minutes", kind: .notify, label: "알림",
              options: [.init(label: "출발 시각", value: "0"), .init(label: "10분 전", value: "10"),
                        .init(label: "30분 전", value: "30"), .init(label: "1시간 전", value: "60")],
              allowsCustom: true, chosen: chosen)
    }

    // MARK: - 칩 · 후보 · 직접입력

    /// 칩을 탭했을 때. 값은 줄에 적고, 키에 따라 딸린 일(조건부 줄·재계산·현재 위치 확정)이 따른다.
    /// `place`는 검색 후보를 탭해 지점까지 특정된 경우에만 실려 온다(choosePlace) — 칩 탭은 nil로
    /// 들어와 라벨을 즐겨찾기 씨앗에서 푼다.
    private func choose(field: UUID, value: String, place: Place? = nil) {
        guard var c = card, let i = c.fields.firstIndex(where: { $0.id == field }) else { return }
        let key = c.fields[i].key
        c.fields[i].chosen = value
        // 좌표는 값을 적은 그 줄 자리에 건다. 실려 온 place가 즐겨찾기 씨앗을 이기는 순서인 이유:
        // 검색 후보는 지점까지 특정된 값이고 즐겨찾기 라벨은 우연히 같을 수 있는 이름일 뿐이라,
        // 반대로 두면 검색해서 고른 "스타벅스" 홍대점이 즐겨찾기 "스타벅스"의 좌표로 조용히 바뀐다.
        // 둘 다 없으면 nil이 들어가 옛 좌표가 지워진다 — 이름이 열쇠이던 시절엔 열쇠가 바뀌며 저절로
        // 풀리던 자리라, 이제 명시로 갚는다.
        if c.fields[i].kind == .place { confirmedPlaces[field] = place ?? favoritePlaces[value] }
        switch key {
        case "notify_enabled":
            if value == "false" {
                // 끌 때 마지막 값을 화면이 기억한 뒤 줄을 뺀다 — 값까지 지우면 다시 켤 때 처음부터
                if let li = c.fields.firstIndex(where: { $0.key == "notify_lead_minutes" }) {
                    lastNotifyLead = c.fields[li].chosen ?? lastNotifyLead
                    c.fields.remove(at: li)
                }
            } else if !c.fields.contains(where: { $0.key == "notify_lead_minutes" }) {
                let at = c.fields.firstIndex(where: { $0.key == "notify_enabled" }).map { $0 + 1 }
                    ?? c.fields.count
                c.fields.insert(notifyLeadRow(chosen: lastNotifyLead), at: at)
            }
            card = c
            // 알림 켜짐이 시각 줄 노트(D-3)의 전제라 토글 뒤엔 노트를 다시 조립해야 한다 —
            // 안 하면 켤 때 경고가 끝까지 안 뜨고 끌 때 경고가 남는다(두 방향을 이 호출이 다 닫는다).
            syncFieldExtras()
        case "origin_query":
            if value == Self.hereMarker, location.currentLocation == nil {
                // 위치를 아직 모르는 동안엔 고른 값으로 남기지 않는다 — chosen이 있으면 isReady가
                // 풀려 저장 버튼이 열리는데 좌표는 없어 save()가 조용히 아무 일도 안 하게 된다.
                // 원본은 제출 판정 식으로 이 창을 잠갔고, 여기서는 미고름으로 같은 잠금을 낸다.
                // 기다림은 줄의 busy(위치 확인 중)가 보여준다.
                c.fields[i].chosen = nil
                card = c
                useCurrentLocationAsOrigin()
                syncOriginBusy()
            } else {
                card = c
                if value == Self.hereMarker {
                    useCurrentLocationAsOrigin()
                } else {
                    ensureGatedRows()
                    restartEstimates()
                }
                // 목적지가 아직 비어 있으면 ensureGatedRows도 재계산 가드도 여기까지 못 온다
                // — 그러면 권한 거부 안내가 값을 고른 줄에 남는다(note를 지우는 건
                // syncFieldExtras뿐이다). 줄 딸린글 조립이 두 자리가 되지 않게 호출로 갚는다.
                syncFieldExtras()
                syncOriginBusy()
            }
        case "destination_query":
            card = c
            ensureGatedRows()
            restartEstimates()
        default:
            card = c
            // 여유는 반대쪽 예상 시각에, 수단은 그 계산에 직접 닿는다 — 줄 캡션을 다시 맞춘다
            syncFieldExtras()
        }
    }

    /// 검색 후보를 탭했을 때 — 좌표 확정은 choose의 쓰기 자리에 맡긴다(REQ-020). 여기서 따로
    /// 쓰면 좌표 쓰기가 두 자리가 되어, 검색 결과가 즐겨찾기 씨앗을 이기는 순서가 호출 순서에
    /// 기대게 된다.
    private func choosePlace(field: UUID, place: Place) {
        choose(field: field, value: place.name, place: place)
    }

    /// 직접입력. 범위 밖은 받지 않는다 — 거절 표시는 카드 뷰가 띄운다.
    @discardableResult
    private func submitCustom(field: UUID, text: String) -> Bool {
        guard var c = card, let i = c.fields.firstIndex(where: { $0.id == field }),
              let value = c.fields[i].accepts(text) else { return false }
        c.fields[i].chosen = value
        card = c
        syncFieldExtras()
        return true
    }

    /// 커밋된 시각의 기준만 바꾼다(같은 시각, 접두만) — 기준 칩을 다시 탭했을 때.
    private func rechooseTimeBasis(field: UUID, basis: ScheduleAnchor) {
        guard var c = card, let i = c.fields.firstIndex(where: { $0.id == field }),
              let chosen = c.fields[i].chosen,
              let parsed = BesirTime.parseDatetime(chosen) else { return }
        c.fields[i].chosen = BesirTime.prefix(for: basis)
            + BesirTime.isoFormatter.string(from: parsed.date)
        card = c
        syncFieldExtras()
    }

    /// 시각 에디터의 확인. ISO 직렬화는 BesirTime이 단독으로 안다 — 뷰가 형식을 만들지 않는다.
    @discardableResult
    private func chooseTime(field: UUID, basis: ScheduleAnchor, date: Date) -> Bool {
        guard var c = card, let i = c.fields.firstIndex(where: { $0.id == field }) else { return false }
        c.fields[i].chosen = BesirTime.prefix(for: basis)
            + BesirTime.isoFormatter.string(from: date)
        card = c
        syncFieldExtras()
        return true
    }

    // MARK: - 장소 검색

    /// 카드 검색 에디터의 입력. 묶음 정책(350ms 지연·취소·같은 질의 스킵)은 공용 디바운서가
    /// 단독으로 소유한다 — 이 화면이 지연 시간을 들면 카카오 할당량 정책이 두 벌이 된다.
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
            // 출발지 검색은 현재 위치를, 목적지 검색은 출발지 좌표를 기준 삼는다(원본의 구분).
            // await 전에 값을 잡아둔다 — 기준이 되는 출발지는 도는 사이 바뀔 수 있다.
            let isOrigin = card?.fields.first(where: { $0.id == field })?.key == "origin_query"
            let near: CLLocationCoordinate2D? = isOrigin
                ? location.currentLocation
                : (originCoord ?? location.currentLocation)
            setLookup(field, .searching)
            var armed = placeDebounce
            armed.arm(field, q) {
                let found = await self.store.placeSearch.search(q, near: near)
                guard !Task.isCancelled else { return }
                self.finishPlaceSearch(field: field, query: q, found: found)
            }
            placeDebounce = armed
        }
    }

    /// 완료 기록(noteDone)이 상태 반영보다 먼저다 — 이 순서를 바꾸면 첫 검색이 도는 중에 같은
    /// 질의를 다시 쳤을 때 유일한 결과가 버려지고 줄이 "찾는 중"에 갇힌다(드라이버 P-5의 시점).
    private func finishPlaceSearch(field: UUID, query: String, found: [Place]) {
        var deb = placeDebounce
        deb.noteDone(field, query)
        placeDebounce = deb
        setLookup(field, found.isEmpty ? .empty
                  : .results(Array(found.prefix(PlaceSearch.maxSuggestions))))
    }

    /// 검색 상태를 줄에 얹는다. await에서 돌아온 뒤 id로 다시 찾는다 — 줄이 없어졌으면 조용히
    /// 버린다(위험 부류 H1과 같은 이유로 잡아둔 자리에 쓰지 않는다).
    private func setLookup(_ field: UUID, _ lookup: EditField.Lookup) {
        guard var c = card, let i = c.fields.firstIndex(where: { $0.id == field }) else { return }
        c.fields[i].lookup = lookup
        card = c
    }

    // MARK: - 현재 위치 출발지

    /// "현재 위치" 칩. 좌표가 이미 있으면 그 자리에서 확정하고, 아니면 위치를 얻을 때까지 기다린다.
    private func useCurrentLocationAsOrigin() {
        if let c = location.currentLocation {
            confirmCurrentLocationAsOrigin(c)
        } else {
            location.useCurrentLocation()
            // 대기도 취소-교체로 건다 — 칩을 다시 타면 이전 대기가 새 대기와 나란히 돌게 두지 않는다.
            prefillTask?.cancel()
            prefillTask = Task { await prefillOrigin() }
        }
    }

    /// 출발지가 비어 있으면 현재 위치로 채운다(측위 시한+1초까지 대기 — 아래 파생식 참조). 새 일정의
    /// 자동 프리필과 옛 일정의 출발지 nil을 채우는 길이 같다 — 옛 화면 prefillOrigin과 같은 흐름이다.
    private func prefillOrigin() async {
        guard confirmedPlace("origin_query") == nil else { return }
        // 권한이 거부된 상태에서 위치를 요청하면 영영 오지 않는 값을 기다린다 — 죽은 대기 대신
        // syncFieldExtras의 권한 안내만 띄운다.
        if location.authorizationStatus == .denied || location.authorizationStatus == .restricted {
            syncFieldExtras()
            return
        }
        if location.currentLocation == nil { location.useCurrentLocation() }
        // 대기 시한은 LocationManager의 측위 시한에서 파생한다(계약 5: 같은 값이 두 곳에 살지
        // 않는다) — 여기가 5초인데 측위가 8초까지 기다리면 5~8초에 오는 위치가 빈 출발지 줄을
        // 채우지 못했다(t11 sync N5). +1초는 시한 직후에 도착하는 값을 받는 여유고, max(5, ·)는
        // 측위 시한이 짧은 macOS의 오늘 행동(5초)을 그대로 지킨다.
        let waitSeconds = max(5, LocationManager.locateTimeoutSeconds + 1)
        for _ in 0..<Int(waitSeconds / 0.2) {
            // sleep은 취소되면 즉시 반환한다 — 대기가 태깅돼 취소가 실제로 닿게 된 지금, 재확인
            // 없이 돌면 0.2초 간격을 잃고 폴링이 빠르게 돈다.
            if Task.isCancelled { break }
            if let c = location.currentLocation {
                confirmCurrentLocationAsOrigin(c)
                return
            }
            // 기다리는 사이 사용자가 직접 출발지를 골랐으면 덮어쓰지 않는다 — 원본에는 없는
            // 재확인이지만, await 너머의 상태를 믿지 않는 규칙과 같은 부류이다.
            if let chosen = field("origin_query")?.chosen, chosen != Self.hereMarker { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func confirmCurrentLocationAsOrigin(_ c: CLLocationCoordinate2D) {
        // 다른 출발지가 이미 골라져 있으면(프리필 대기 중 사용자가 고른 경우) 그 값을 지키고,
        // "현재 위치" 칩 자체가 선택된 상태일 때만 확정한다
        guard field("origin_query")?.chosen == nil || field("origin_query")?.chosen == Self.hereMarker
        else { return }
        if var c2 = card, let i = c2.fields.firstIndex(where: { $0.key == "origin_query" }) {
            // 좌표를 chosen과 같은 블록에서 줄 신원으로 쓴다 — 밖에서 먼저 쓰면 카드가 없을 때
            // 좌표만 있고 chosen 없는 반쪽 확정이 생긴다. 실측상 두 호출 경로 모두 카드가 있어
            // 관측 변화는 없지만, 반쪽 상태를 만들지 않는 쪽이 fail-closed 읽기와 같은 길이다.
            confirmedPlaces[c2.fields[i].id] = Place(name: location.currentPlaceName ?? "현재 위치",
                                                     address: "", latitude: c.latitude, longitude: c.longitude)
            c2.fields[i].chosen = Self.hereMarker
            // GPS가 내가 생각한 곳으로 풀렸는지 보는 유일한 확인 수단이다 — 원본 확정 카드가 지명을
            // 보여줬던 것의 계승. 칩 글자에 지명을 얹고, 못 얻었으면 "현재 위치" 그대로 둔다.
            if let town = location.currentPlaceName, !town.isEmpty,
               let oi = c2.fields[i].options.firstIndex(where: { $0.value == Self.hereMarker }) {
                c2.fields[i].options[oi].label = "현재 위치(\(town))"
            }
            card = c2
        }
        ensureGatedRows()
        restartEstimates()
        syncOriginBusy()
    }

    // MARK: - 이동시간

    // View 순응으로 이 함수는 이미 주 액터에 격리된다(SDK의 View 프로토콜이 @MainActor다) —
    // 병렬 갱신 경합은 애초에 일어날 수 없었다(sync 판정 N1 정정). @MainActor는 그 사실을
    // 코드 자리에 문서로 못박는 역할만 한다.
    @MainActor
    private func recomputeEstimates() async {
        guard let origin = confirmedPlace("origin_query"),
              let dest = confirmedPlace("destination_query") else { return }
        estimating = true
        estimateFlights += 1
        let all = await store.directions.estimateAll(
            from: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude),
            to: CLLocationCoordinate2D(latitude: dest.latitude, longitude: dest.longitude))
        estimateFlights -= 1
        // 도는 사이 출발지·목적지를 바꾸면 두 비동기 작업이 겨루고 늦게 끝난 옛 계산이 이겨, 모드
        // 칩 소요시간·시각 줄 안내·충돌 배너에 옛 좌표의 값이 남는다. await 뒤 다시 읽어 시작할 때의
        // 줄 신원·좌표와 같을 때만 쓴다(setLookup과 같은 await 뒤 재확인 규율). 취소된 계산도 같은
        // 이유로 버린다 — 취소된 estimateAll이 꼭 빈 추정으로 돌아오는 건 아니다. 취소 전에 응답을
        // 받은 수단은 실제 값으로 돌아올 수 있어, 재계산 버튼 두 연타처럼 시작과 재시작이 같은
        // 좌표로 붙으면 신원 대조만으로는 그 값이 통과하는 걸 막지 못한다.
        // 밀린 계산은 값을 버리되 이것이 마지막 계산이면 estimating을 내린다 — 도중에 출발지가
        // 지워져도 플래그가 true로 남지 않게.
        guard !Task.isCancelled,
              confirmedPlace("origin_query") == origin,
              confirmedPlace("destination_query") == dest else {
            if estimateFlights == 0 { estimating = false }
            return
        }
        estimates = all
        estimatesFor = (origin, dest)
        if estimateFlights == 0 { estimating = false }
        syncFieldExtras()
    }

    /// 이동시간 재계산은 언제나 여기를 거쳐 띄운다(취소-교체) — 네 발화 지점이 각자 Task를 만들면
    /// 이전 계산을 취소할 손잡이가 없다. bootstrap의 구조적 .task 안 직접 await는 그대로 둔다
    /// (화면 생명주기가 취소를 소유한다).
    private func restartEstimates() {
        estimateTask?.cancel()
        estimateTask = Task { await recomputeEstimates() }
    }

    /// 줄에 붙는 딸린 글을 카드에 다시 맞춘다 — 모드 칩의 소요시간, 출처 캡션, 시각 줄 안내·예상
    /// 시각, 출발지 줄의 권한 거부 안내. 이 문자열들을 조립하는 곳은 이 함수 하나다(REQ-030(c)).
    private func syncFieldExtras() {
        guard var c = card else { return }
        let currentMode = c.fields.first(where: { $0.key == "mode" })?.chosen
            .flatMap(TransportMode.init(rawValue:)) ?? .transit
        if let mi = c.fields.firstIndex(where: { $0.key == "mode" }) {
            for oi in c.fields[mi].options.indices {
                let m = TransportMode(rawValue: c.fields[mi].options[oi].value)
                let est = m.flatMap { estimates[$0] }
                // 값이 없고 이유가 있으면 이유 캡션(D10) — 예비 경로가 사라져 네 칩이 한꺼번에 비는
                // 일이 생기는데, 모두 "정보 없음"이면 사용자가 원인을 알 수 없다. 이유가 없는 빈 값
                // (취소 등)은 실패라고 단정할 근거가 없으니 기존 "정보 없음" 그대로.
                c.fields[mi].options[oi].detail = est.map { e in
                    e.isAvailable ? e.durationText : (e.failure?.caption ?? e.durationText)
                }
            }
            // B7: 계산이 끝났는데 고른 수단의 값이 없으면 칩 캡션("정보 없음")만으로는 닿지
            // 않는다 — 줄 노트가 상태를 말한다. estimates가 빈 창(아직 계산 전)에는 말하지 않는다.
            var modeNote: String? = nil
            if !estimates.isEmpty, estimates[currentMode]?.duration == nil {
                // 이유를 알면 그 문장(Models 한 곳에서 만든 것)으로 말한다 — 같은 실패가 칩과 노트에서
                // 다르게 들리지 않게. 이유 모르는 빈 값만 기존 문장을 쓴다.
                modeNote = estimates[currentMode]?.failure?.sentence
                    ?? "선택한 이동수단은 소요시간을 계산하지 못했어요."
            }
            c.fields[mi].note = modeNote
        }
        if let ti = c.fields.firstIndex(where: { $0.key == "arrival_iso" }) {
            let parsed = c.fields[ti].chosen.flatMap(BesirTime.parseDatetime)
            let departureAnchored = parsed.flatMap { BesirTime.anchor(ofPrefix: $0.prefix) } == .departure
            // 시각 줄 노트에는 상태(예상 시각·알림 경고)만 남긴다 — 기준 설명 문안은 §10으로 지웠다.
            var note = ""
            // 이동시간을 알면 반대쪽 예상 시각을 붙인다 — 옛 화면의 비기준 줄 예상값이 사는 자리
            if let secs = estimates[currentMode]?.duration, let parsed {
                let buffer = c.fields.first(where: { $0.key == "buffer_minutes" })?.chosen
                    .flatMap { Int($0) } ?? 0
                if departureAnchored {
                    note += "예상 도착 " + BesirTime.compact.string(from: parsed.date.addingTimeInterval(secs))
                } else {
                    note += "예상 출발 "
                        + BesirTime.compact.string(from: Store.departureTime(arrival: parsed.date, travelSeconds: secs, bufferMinutes: buffer))
                }
            }
            // D-3: 과거 출발엔 알림이 예약되지 않는다(NotificationManager가 과거 시각을 거부한다).
            // 저장하고 나서 "왜 안 울리지"를 겪기 전에 폼이 먼저 말한다. 이동시간을 모르는 창에는
            // 기준 시각만으로 판단한다 — 모르고 단정하는 것보다 안 말하는 쪽을 택한다.
            if field("notify_enabled")?.chosen != "false", let parsed {
                let lead = field("notify_lead_minutes")?.chosen.flatMap { Int($0) }
                    ?? Int(lastNotifyLead) ?? 0
                let buffer = c.fields.first(where: { $0.key == "buffer_minutes" })?.chosen
                    .flatMap { Int($0) } ?? 0
                let depGuess: Date
                if departureAnchored {
                    depGuess = parsed.date
                } else if let secs = estimates[currentMode]?.duration {
                    depGuess = Store.departureTime(arrival: parsed.date, travelSeconds: secs, bufferMinutes: buffer)
                } else {
                    depGuess = parsed.date
                }
                if NotificationManager.alarmTime(departure: depGuess, leadMinutes: lead) <= Date() {
                    // 예상 시각 없이 경고만 붙는 창이 있어(이동시간 모르는 창) 이어붙임을 가린다.
                    note += note.isEmpty ? "" : " "
                    note += "알림 시각이 이미 지나 출발 알림이 예약되지 않아요."
                }
            }
            c.fields[ti].note = note.isEmpty ? nil : note
        }
        if let oi = c.fields.firstIndex(where: { $0.key == "origin_query" }) {
            // 권한 거부로 출발지가 비면 이유와 다른 길을 말한다 — 이 시트가 위치 실패를 알리는 유일한
            // 자리다(lastError를 읽는 곳이 없다). 상태 판정은 authorizationStatus로 하지 문자열
            // 매칭으로 하지 않는다. note는 줄 라벨 아래에 붙어 편집기를 닫아도 보이고 줄 라벨과
            // 함께 읽힌다.
            let blocked = location.authorizationStatus == .denied
                || location.authorizationStatus == .restricted
            c.fields[oi].note = blocked && c.fields[oi].chosen == nil
                ? "위치 권한이 꺼져 있어요. 시스템 설정에서 허용하거나 출발지를 직접 검색해 골라 주세요."
                : nil
        }
        card = c
    }

    private func setBusy(key: String, _ on: Bool) {
        guard var c = card, let i = c.fields.firstIndex(where: { $0.key == key }),
              c.fields[i].busy != on else { return }
        c.fields[i].busy = on
        card = c
    }

    /// 출발지 줄의 스피너는 "줄이 비어 있고 위치를 기다리는 중"일 때만 돈다 — isLocating은 앱 시작
    /// 프리필 같은 이 줄과 무관한 측위에도 켜지므로, 값이 있는 줄에 걸면 아무도 그 줄에서 일하지
    /// 않는데 도는 표시가 된다(편집 시트 냉시작에서 관측됨).
    private func syncOriginBusy() {
        setBusy(key: "origin_query", location.isLocating && field("origin_query")?.chosen == nil)
    }

    // MARK: - 읽기 보조

    private func field(_ key: String) -> EditField? {
        card?.fields.first { $0.key == key }
    }

    /// 줄에 걸린 좌표를 되찾는다 — 열쇠는 chosen 이름이 아니라 줄 신원이다.
    /// `chosen == nil`을 먼저 거르는 이유는 실패 방향을 닫아두기 위해서다. 열쇠가 이름이던 시절엔
    /// 이름 없는 줄이 사전을 못 찾아 저절로 nil이 나왔다. 신원 열쇠에서는 "좌표만 걸리고 이름은
    /// 없는 줄"이 생기면 그 좌표가 조용히 실려 나간다 — 쓰기 자리들이 지금은 이름과 좌표를 늘
    /// 함께 심지만 그 불변식은 코드가 아니라 규율이 지킨다. 출발지 줄의 nil을 "없는 장소"가 아니라
    /// **프리필을 여는 신호로 읽는 곳은 prefillOrigin의 가드 하나뿐**이다 — 그 밖의 읽기 자리는
    /// (재계산 가드·originCoord·save 가드 등 — 자리 수는 코드를 따라 늘어난다) nil을 있는 그대로
    /// "없는 장소"로 취급한다. fail-closed만 믿다가 저장된 출발지가 현재 위치로 조용히 바뀌었다
    /// (1b98e14).
    private func confirmedPlace(_ key: String) -> Place? {
        field(key).flatMap { $0.chosen == nil ? nil : confirmedPlaces[$0.id] }
    }

    private var originCoord: CLLocationCoordinate2D? {
        confirmedPlace("origin_query").map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    // MARK: - 저장

    private func save() async {
        // 카드가 다 차 있어도 좌표·시각은 여기서 되찾는다 — isReady는 줄의 chosen만 본다
        guard let origin = confirmedPlace("origin_query"),
              let dest = confirmedPlace("destination_query"),
              let parsed = field("arrival_iso")?.chosen.flatMap(BesirTime.parseDatetime)
        else { return }
        let title = field("title")?.chosen ?? ""
        // parsed가 "기준 시각"이다 — anchor == .arrival이면 도착 시각, .departure면 출발 시각이고
        // store의 arrivalDate 파라미터는 기준 시각을 받아 안에서 방향에 맞게 처리한다.
        let anchor: ScheduleAnchor = BesirTime.anchor(ofPrefix: parsed.prefix) ?? .departure
        let mode = field("mode")?.chosen.flatMap(TransportMode.init(rawValue:)) ?? .transit
        let bufferMinutes = field("buffer_minutes")?.chosen.flatMap { Int($0) } ?? 0
        // 알림 줄이 꺼져서 없으면 화면이 기억한 마지막 값을 쓴다(REQ-022(b))
        let notifyLeadMinutes = field("notify_lead_minutes")?.chosen.flatMap { Int($0) }
            ?? Int(lastNotifyLead) ?? 0
        let notifyEnabled = field("notify_enabled")?.chosen != "false"
        let syncToCalendar: Bool
        if let chosen = field("calendar_sync")?.chosen {
            syncToCalendar = chosen == "true"
        } else {
            syncToCalendar = calendarDefault
        }
        saving = true
        // 폼이 이미 보여준 이동시간을 그대로 저장한다 — 저장마다 카카오를 다시 부르지 않고,
        // 폼 표시값과 저장값이 어긋나는 창(재조회 사이 교통상황 변동)도 없어진다. 단 힌트는
        // estimates가 지금 폼의 출발지·목적지에 대한 값일 때만 넘긴다 — 재계산 왕복이 도는 창의
        // 옛 쌍이면 nil로 저장 시 한 번 재조회하게 한다(수리 전과 같은 정확성. code-safety F1).
        var hint: TimeInterval?
        if let pair = estimatesFor, pair.origin == origin, pair.destination == dest {
            hint = estimates[mode]?.duration
        }
        if let e = editing {
            await store.updateEvent(id: e.id, title: title, origin: origin, destination: dest,
                                    arrivalDate: parsed.date, mode: mode,
                                    bufferMinutes: bufferMinutes, notifyLeadMinutes: notifyLeadMinutes,
                                    anchor: anchor, travelSecondsHint: hint,
                                    notifyEnabled: notifyEnabled, syncToCalendar: syncToCalendar)
            // 이 폼의 저장도 "이 일정만" 변경이라 그 회차를 반복에서 뗀다(REQ-014). 빠짐을
            // updateEvent 안에 두지 않고 이 자리에서 직접 부르는 것은 P-11 금지 때문이다 —
            // realignLegs·updateLeg가 내부에서 updateEvent를 부르는데 거기까지 빠짐이 붙으면
            // "전체" 저장이 회차를 지운다. 소유 활동이 있으면 그 회차 전체가, 혼자 남은 옛 반복
            // 구간이면 구간 하나만 빠진다(J-10).
            // 단 아무것도 안 바꾼 저장은 떼지 않는다(REQ-014 끝 문장) — 열어 보고 확인만 눌러도 그날이
            // 반복에서 빠지면 사용자가 한 일이 없는데 묶음이 깨진다. 판정은 드라이버가 부를 수 있게
            // Store에 있다(계약 5).
            if Store.legEditChangesOccurrence(original: e, title: title, origin: origin, destination: dest,
                                              baseDate: parsed.date, anchor: anchor, mode: mode,
                                              bufferMinutes: bufferMinutes,
                                              notifyLeadMinutes: notifyLeadMinutes,
                                              notifyEnabled: notifyEnabled, syncToCalendar: syncToCalendar) {
                if let linked = e.linkedActivityId {
                    store.detachOccurrence(activityId: linked)
                } else {
                    store.detachOccurrence(legId: e.id)
                }
            }
        } else {
            await store.addEvent(title: title, origin: origin, destination: dest,
                                 arrivalDate: parsed.date, mode: mode,
                                 bufferMinutes: bufferMinutes, notifyLeadMinutes: notifyLeadMinutes,
                                 anchor: anchor, travelSecondsHint: hint,
                                 notifyEnabled: notifyEnabled, syncToCalendar: syncToCalendar)
        }
        saving = false
        dismiss()
    }
}
