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
