import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var autoAdd = true

    @State private var showingWipe = false
    #if DEBUG && os(iOS)
    @State private var debugCalendarLines: [String] = []
    #endif

    // 즐겨찾기는 추가·삭제가 즉시 저장되고, 기본 설정은 아래 저장 단추를 눌러야 반영된다 —
    // 두 저장 문법이 섞이면 "저장을 안 눌렀는데 바뀌었네"가 생기므로 탭으로 가른다(REQ-003).
    private enum SettingsTab: Hashable {
        case basic
        case favorites
        case connections
    }

    @State private var tab: SettingsTab = .basic

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.title2).bold()

            Picker("Settings Section", selection: $tab) {
                Text("General").tag(SettingsTab.basic)
                Text("Favorites").tag(SettingsTab.favorites)
                Text("Connections").tag(SettingsTab.connections)
            }
            .pickerStyle(.segmented)

            switch tab {
            case .basic: basicTab
            case .favorites: favoritesTab
            case .connections: ConnectionsView()
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
            #if os(iOS)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Add events to Apple Calendar", isOn: $autoAdd)
                if let text = CalendarStatusText.warning(store.calendarStatus, switchOn: autoAdd) {
                    Text(text).font(.caption).foregroundStyle(Theme.warn)
                }
            }
            #endif
            // ⚠️ 테스트용 임시 버튼 — 출시 전에 이 블록과 Store.deleteEverythingForTesting을 같이 뺀다.
            VStack(alignment: .leading, spacing: 6) {
                Text("Testing").font(.headline)
                Button(role: .destructive) {
                    showingWipe = true
                } label: {
                    Label("Delete All Events", systemImage: "trash")
                }
                #if DEBUG && os(iOS)
                Button("Read Today's Calendar") { Task { await readTodayForDebug() } }
                ForEach(Array(debugCalendarLines.enumerated()), id: \.offset) { line in
                    Text(line.element).font(.caption)
                }
                #endif
            }
            .confirmationDialog("Delete all events, activities and meal records?",
                                isPresented: $showingWipe, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { store.deleteEverythingForTesting() }
                Button("Cancel", role: .cancel) {}
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var c = store.config
                    c.autoAddToCalendar = autoAdd
                    store.updateConfig(c)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    #if DEBUG && os(iOS)
    /// Debug builds only: lists today's Apple Calendar events (all calendars), or the error line.
    private func readTodayForDebug() async {
        do {
            let entries = try await store.calendarMirror.entries(on: Date(), calendar: .current)
            let time = DateFormatter()
            time.locale = Locale(identifier: "en_US")
            time.dateFormat = "h:mm a"
            var lines = entries.prefix(12).map { entry in
                "\(entry.isAllDay ? "All day" : time.string(from: entry.start))  \(entry.title)\(entry.isFromBesir ? " (besir)" : "")"
            }
            if entries.count > 12 { lines.append("+\(entries.count - 12) more") }
            debugCalendarLines = lines.isEmpty ? ["No events today"] : lines
        } catch {
            debugCalendarLines = [CalendarStatusText.debugLine(for: error)]
        }
    }
    #endif

    /// 즐겨찾기 탭 — 추가·삭제는 즉시 저장이라 저장/취소 줄이 없다. 목록이 화면보다 길어질 수
    /// 있어 스크롤로 싼다(기본 설정 탭은 줄 수가 정해져 있어 그대로 둔다).
    private var favoritesTab: some View {
        ScrollView {
            FavoritesList()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
