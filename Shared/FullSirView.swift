import SwiftUI
import CoreLocation

/// be full sir — 무엇을 먹을지 찾고, 먹은 것을 남기는 화면.
///
/// be on-time sir와 화면은 분리돼 있지만 **같은 Store를 쓰므로 연계된다**:
/// - 기준 위치를 "오늘 일정의 목적지"에서 고를 수 있다(그 장소 주변에서 검색).
/// - 고른 식당을 **식사 활동 블록 + 왕복 이동**으로 등록할 수 있다(`addActivityWithTravel`).
///   출발지·복귀지는 앞뒤 일정에서 자동으로 제안한다.
/// - 등록한 식사 일정을 be on-time sir에서 지우면 아직 안 먹은 기록은 여기서도 사라진다.
struct FullSirView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationManager

    /// 홈으로 돌아가기.
    var onBack: () -> Void

    /// 검색 기준 위치.
    private enum Basis: Hashable {
        case current
        case event(UUID)
        /// 현재 위치·오늘 일정 목적지 둘 다 아닌 곳(외곽 지역 등)을 직접 검색해서 쓴다.
        case custom
    }

    @State private var basis: Basis = .current
    @State private var customPlace: Place?
    @State private var keyword = ""
    /// 빠른 검색에서 고른 항목. nil이면 자유 입력 검색(업종을 가리지 않음).
    @State private var selectedQuick: String?
    @State private var sort: NearbySort = .distance
    @State private var results: [NearbyPlace] = []
    @State private var searching = false
    @State private var searched = false
    @State private var status = ""

    /// 일정으로 등록하려고 고른 식당.
    @State private var scheduling: NearbyPlace?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    basisSection
                    searchSection
                    resultsSection
                    recentMealsSection
                }
                .padding(20)
                // 우하단 besir 로고 버튼(REQ-007)이 맨 아래 휴지통을 덮지 않게 하는 여백이다 —
                // 버튼 56 + 바닥 여백 20을 목록 바깥에 한 번에 둔다(각 행이 아니라).
                .padding(.bottom, 56)
            }
            .background(Theme.bg)
            .navigationTitle("be full sir")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { onBack() } label: { Label("홈", systemImage: "chevron.left") }
                }
                // AI는 우하단 besir 로고 버튼(RootView) 하나로 통일됐다(REQ-008) — 툴바에는 두지 않는다.
            }
            .sheet(item: $scheduling) { item in
                MealScheduleSheet(target: item) { scheduling = nil }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 640)
        #endif
    }

    // MARK: - 기준 위치

    /// 오늘 이후로 도착 예정인 일정들(그 목적지 주변에서 찾을 수 있게).
    private var upcomingEvents: [ScheduledEvent] {
        let now = Date()
        return store.events
            .filter { $0.arrivalDate >= Calendar.current.startOfDay(for: now) }
            .sorted { $0.arrivalDate < $1.arrivalDate }
            .prefix(8)
            .map { $0 }
    }

    private var basisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("기준 위치").font(.caption).foregroundStyle(Theme.faint)
            Picker("기준 위치", selection: $basis) {
                Text(location.currentPlaceName ?? "현재 위치").tag(Basis.current)
                ForEach(upcomingEvents) { e in
                    Text("\(e.destination.name) · \(Self.dayFmt.string(from: e.arrivalDate))")
                        .tag(Basis.event(e.id))
                }
                Text("직접 검색").tag(Basis.custom)
            }
            #if os(iOS)
            .pickerStyle(.menu)
            #endif
            if case .current = basis, location.currentLocation == nil {
                Text("위치 권한이 필요해요")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
            // 현재 위치·오늘 일정 목적지 둘 다 기준으로 삼기 어려운 경우(외곽 지역 등)를 위한
            // 자유 검색 — 실기기 테스트에서 이 방법이 없다는 피드백을 받아 추가함.
            if case .custom = basis {
                PlaceField(title: "검색할 위치", systemImage: "mappin.and.ellipse", place: $customPlace)
            }
        }
    }

    private var basisCoordinate: CLLocationCoordinate2D? {
        switch basis {
        case .current:
            return location.currentLocation
        case .event(let id):
            guard let e = store.events.first(where: { $0.id == id }) else { return nil }
            return CLLocationCoordinate2D(latitude: e.destination.latitude, longitude: e.destination.longitude)
        case .custom:
            guard let p = customPlace else { return nil }
            return CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
        }
    }

    private var basisName: String {
        switch basis {
        case .current: return location.currentPlaceName ?? "현재 위치"
        case .event(let id): return store.events.first(where: { $0.id == id })?.destination.name ?? "목적지"
        case .custom: return customPlace?.name ?? "직접 검색"
        }
    }

    // MARK: - 검색

    /// 빠른 검색 목록. 카페도 여기 들어간다(예전엔 맛집/카페를 위에서 따로 골라야 했다).
    private static let quickPicks = ["카페", "한식", "일식", "초밥", "중식", "양식", "분식", "고기", "국밥"]

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("메뉴·업종", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { selectedQuick = nil; Task { await runSearch() } }
                Button { selectedQuick = nil; Task { await runSearch() } } label: {
                    if searching { ProgressView().controlSize(.small) }
                    else { Image(systemName: "magnifyingglass") }
                }
                .disabled(searching || basisCoordinate == nil)
                .accessibilityLabel("검색")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.quickPicks, id: \.self) { pick in
                        let on = selectedQuick == pick
                        Button {
                            selectedQuick = pick
                            keyword = pick
                            Task { await runSearch() }
                        } label: {
                            Text(pick)
                                .font(.caption)
                                .foregroundStyle(on ? Theme.bg : Theme.ink)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(on ? Theme.travel : Color.clear,
                                            in: Capsule())
                                .overlay(Capsule().stroke(on ? Color.clear : Theme.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }

            // 정렬은 검색 결과가 있을 때만 의미가 있다.
            if searched {
                Picker("정렬", selection: $sort) {
                    ForEach(NearbySort.allCases) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
                .onChange(of: sort) { Task { await runSearch() } }
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if searched {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(basisName) 주변").font(.caption).foregroundStyle(Theme.faint)
                if results.isEmpty && !searching {
                    Text("결과 없음")
                        .font(.caption).foregroundStyle(Theme.faint)
                } else {
                    ForEach(results) { item in
                        resultRow(item)
                        Divider().overlay(Theme.line)
                    }
                }
            }
        }
    }

    private func resultRow(_ item: NearbyPlace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
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
                    Link(destination: url) { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("지도에서 보기")
                }
            }
            HStack(spacing: 8) {
                Button {
                    // 먹은 것으로 바로 남긴다(일정 없이 기록만).
                    store.addMeal(category: .diningOut, title: item.place.name, place: item.place)
                    status = "기록됨"
                } label: {
                    Label("먹었어요", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    scheduling = item
                } label: {
                    Label("식사 일정 추가", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if !status.isEmpty {
                Text(status).font(.caption2).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 6)
    }

    /// "카페"를 고르면 카페(CE7), 음식 항목을 고르면 음식점(FD6)으로 좁힌다.
    /// 자유 입력이면 업종을 가리지 않아(nil) 카페·식당이 섞여 나온다.
    private var searchCategory: MealCategoryFilter? {
        guard let selectedQuick else { return nil }
        return selectedQuick == "카페" ? .cafe : .restaurant
    }

    private func runSearch() async {
        guard let center = basisCoordinate else { return }
        searching = true
        status = ""
        results = await store.placeSearch.nearbyPlaces(category: searchCategory,
                                                       keyword: keyword,
                                                       near: center,
                                                       radiusMeters: 1500,
                                                       sort: sort,
                                                       limit: 10)
        searching = false
        searched = true
    }

    // MARK: - 최근 식사 기록

    @ViewBuilder
    private var recentMealsSection: some View {
        let meals = store.recentMeals(limit: 10)
        if !meals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("최근 먹은 것").font(.caption).foregroundStyle(Theme.faint)
                ForEach(meals) { meal in
                    HStack {
                        Image(systemName: meal.category.systemImage).foregroundStyle(Theme.activity)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meal.title).font(.subheadline)
                            Text("\(meal.category.title) · \(Self.dayFmt.string(from: meal.loggedAt))")
                                .font(.caption2).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button {
                            store.deleteMeal(meal.id)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("삭제")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "M/d EEE h:mm a"; return f
    }()
}

/// 추천에서 고른 식당을 **식사 일정**으로 등록하는 시트.
///
/// "식당까지 가는 이동"만 만들면 시간표에 이동 블록만 덩그러니 남아 언제 먹는지가 안 보인다.
/// 그래서 **식사 시간 자체를 활동 블록으로** 만들고(1~2시 ○○에서 식사), 거기로 가는 이동과
/// 먹고 나서 돌아가는 이동을 그 활동에 묶어서 함께 만든다(`Store.addActivityWithTravel`).
///
/// 출발지·복귀지는 앞뒤 일정을 보고 미리 채워둔다(`Store.surroundingPlaces`) — 대부분
/// "직전에 있던 곳에서 출발해 먹고 다음 일정 장소로" 이므로 그대로 두면 된다.
private struct MealScheduleSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationManager
    @Environment(\.dismiss) private var dismiss

    let target: NearbyPlace
    var onDone: () -> Void

    @State private var start = MealScheduleSheet.defaultStart()
    @State private var durationMinutes = 60
    @State private var origin: Place?
    @State private var destination: Place?
    @State private var addOutbound = true
    @State private var addReturn = true
    @State private var outboundMode: TransportMode = .walk
    @State private var returnMode: TransportMode = .walk
    @State private var saving = false
    @State private var loadedSuggestion = false
    /// 사용자가 출발지·도착지를 직접 건드렸으면 시각을 바꿔도 제안으로 되돌리지 않는다.
    @State private var originEdited = false
    @State private var destinationEdited = false

    private var end: Date { start.addingTimeInterval(Double(durationMinutes) * 60) }

    var body: some View {
        NavigationStack {
            Form {
                Section("식당") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.place.name).bold()
                        if !target.place.address.isEmpty {
                            Text(target.place.address).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Section("식사 시간") {
                    DatePicker("시작", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    Picker("소요", selection: $durationMinutes) {
                        ForEach([30, 45, 60, 90, 120], id: \.self) { m in Text("\(m)분").tag(m) }
                    }

                }
                Section("가는 길") {
                    Toggle("식당까지 이동 만들기", isOn: $addOutbound)
                    if addOutbound {
                        // 제안값을 그대로 쓰는 경우가 대부분이지만, 바꿀 수 있어야 한다
                        // (제안은 앞뒤 일정에서 추정한 것이라 늘 맞지는 않는다).
                        PlaceField(title: "출발지", systemImage: "figure.walk.departure", place: $origin)
                        Picker("이동수단", selection: $outboundMode) {
                            ForEach(TransportMode.allCases) { m in Text(m.title).tag(m) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("먹고 나서") {
                    Toggle("돌아가는 이동 만들기", isOn: $addReturn)
                    if addReturn {
                        PlaceField(title: "도착지", systemImage: "house", place: $destination)
                        Picker("이동수단", selection: $returnMode) {
                            ForEach(TransportMode.allCases) { m in Text(m.title).tag(m) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("식사 일정으로 추가")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss(); onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView().controlSize(.small) } else { Text("추가") }
                    }
                    .disabled(saving)
                }
            }
            // 시각을 바꾸면 앞뒤 일정이 달라지므로 제안도 다시 계산한다.
            .onChange(of: start) { applySuggestion() }
            .onChange(of: origin) { if loadedSuggestion { originEdited = true } }
            .onChange(of: destination) { if loadedSuggestion { destinationEdited = true } }
            .task { if !loadedSuggestion { applySuggestion(); loadedSuggestion = true } }
        }
        #if os(macOS)
        .frame(width: 480, height: 620)
        #endif
    }

    /// 다음 정시(또는 30분)로 맞춰 기본 시작 시각을 잡는다.
    private static func defaultStart() -> Date {
        let cal = Calendar.current
        let soon = Date().addingTimeInterval(1800)
        let m = cal.component(.minute, from: soon)
        return cal.date(bySetting: .minute, value: m < 30 ? 30 : 0,
                        of: m < 30 ? soon : soon.addingTimeInterval(1800)) ?? soon
    }

    /// 앞뒤 일정을 보고 출발지·복귀지를 채운다.
    private func applySuggestion() {
        let around = store.surroundingPlaces(start: start, end: end)
        if !originEdited { applyOriginSuggestion(around.before) }
        if !destinationEdited { applyDestinationSuggestion(around.after) }
    }

    private func applyOriginSuggestion(_ before: (place: Place, label: String)?) {
        // 제안 근거를 설명하는 캡션은 §10으로 지웠다 — 여기는 장소 값만 채운다.
        if let b = before {
            origin = b.place
        } else if let c = location.currentLocation {
            origin = Place(name: location.currentPlaceName ?? "현재 위치", address: "",
                           latitude: c.latitude, longitude: c.longitude)
        } else {
            origin = nil
        }
    }

    private func applyDestinationSuggestion(_ after: (place: Place, label: String)?) {
        if let a = after {
            destination = a.place
        } else if let o = origin {
            // 다음 일정이 없으면(가장 흔한 경우) "먹고 나서"는 곧 "온 곳으로 되돌아감"이다.
            // 여기서 비워두면 "돌아가는 이동 만들기" 토글이 켜져 있어도 도착지가 없어
            // 왕복 이동이 조용히 안 만들어졌다(실기기 테스트에서 발견됨).
            destination = o
        } else {
            destination = nil
        }
    }

    private func save() async {
        saving = true
        let made = await store.addActivityWithTravel(
            title: target.place.name,
            location: target.place,
            startDate: start,
            endDate: end,
            travelFrom: addOutbound ? origin : nil,
            returnTo: addReturn ? destination : nil,
            outboundMode: outboundMode,
            returnMode: returnMode,
            bufferMinutes: 5,
            notifyLeadMinutes: 20,
            syncToCalendar: store.calendarSyncDefault)   // 함수 기본값 true면 설정을 끈 사용자도 미러에 올라간다
        // 식사 기록을 방금 만든 활동에 묶어 둔다(일정을 지우면 이 기록도 같이 지워지도록).
        // 제목·시각으로 되찾지 않고 id를 직접 받는다 — 되찾는 방식은 같은 이름·같은 시각 활동이
        // 이미 있을 때 엉뚱한 쪽에 붙었다.
        store.addMeal(category: .diningOut,
                      title: target.place.name,
                      place: target.place,
                      activityId: made.activityId,
                      plannedAt: start)
        saving = false
        dismiss()
        onDone()
    }
}
