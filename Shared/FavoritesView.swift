import SwiftUI

/// 즐겨찾기 장소(집·회사 등) 관리 화면. 추가/삭제만 지원하는 단순 목록.
struct FavoritesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Favorite Places").font(.title2).bold()
                Spacer()
                Button("Close") { dismiss() }
            }

            FavoritesList()
            Spacer()
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 480, height: 560)
        #endif
    }
}

/// 즐겨찾기 목록·추가 통. 설정의 즐겨찾기 탭(REQ-003)과 단독 시트가 같은 목록을 쓰므로
/// 한 정의를 같이 부른다 — 추가·삭제 문법이 두 벌로 늘면 나중에 한쪽만 고쳐지는 사고가 생긴다.
struct FavoritesList: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationManager

    @State private var newLabel = ""
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.favorites.isEmpty {
                Text("No favorites yet.")
                    .font(.callout).foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.favorites) { fav in
                        HStack {
                            // 시스템 노랑 대신 브라스 — 하우스 팔레트의 따뜻한 강조를 별도 가져간다.
                            Image(systemName: "star.fill").foregroundStyle(Theme.activity)
                            VStack(alignment: .leading) {
                                Text(fav.label).bold()
                                Text(fav.place.name).font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button(role: .destructive) { store.deleteFavorite(fav.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete")
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }

            Divider()
            Text("Add Favorite").font(.headline)
            TextField("Name", text: $newLabel)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Search places", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button { runSearch() } label: {
                    if searching { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass") }
                }
                // 아이콘만 있는 버튼은 VoiceOver가 읽을 문구가 없다 — 무엇을 여는지 직접 말해준다.
                .accessibilityLabel("Search places")
                // 검색이 돌고 있을 때 다시 누르면 Task가 겹친다 — FullSirView 돋보기와 같은 잠금.
                .disabled(searching)
            }
            ForEach(results, id: \.self) { place in
                Button {
                    addFavorite(place)
                } label: {
                    HStack {
                        Image(systemName: "mappin.circle")
                        VStack(alignment: .leading) {
                            Text(place.name)
                            Text(place.address).font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                Divider()
            }
            if !results.isEmpty {
                GoogleMapsAttribution()
            }
        }
    }

    private func addFavorite(_ place: Place) {
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        store.addFavorite(label: label, place: place)
        newLabel = ""; query = ""; results = []
    }

    private func runSearch() {
        guard query.count >= 2 else { return }
        searching = true
        Task {
            let found = await store.placeSearch.search(query, near: location.currentLocation)
            await MainActor.run { results = found; searching = false }
        }
    }
}
