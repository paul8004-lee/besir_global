import SwiftUI

/// 앱의 최상위 화면. 서비스(be on-time sir / be full sir)를 고르는 홈을 두고,
/// 고른 서비스의 화면을 전체로 띄운다.
///
/// 서비스별로 화면을 나눈 이유: 일정·이동(be on-time sir)과 식사(be full sir)는 쓰는 맥락이
/// 다른데 한 화면에 섞으면 둘 다 복잡해진다. 대신 **데이터는 같은 Store를 공유**하므로,
/// 식사에서 고른 식당을 바로 일정으로 만들거나(`FullSirView`) 일정 상세에서 주변 맛집을
/// 보는(`EventDetailView`) 식의 연계는 그대로 된다.
struct RootView: View {
    enum Service: String, Identifiable, CaseIterable {
        case onTime, full
        var id: String { rawValue }

        var title: String {
            switch self {
            case .onTime: return "be on-time sir"
            case .full: return "be full sir"
            }
        }
        var systemImage: String {
            switch self {
            case .onTime: return "clock.badge.checkmark"
            case .full: return "fork.knife"
            }
        }
        /// 색은 서비스 구분에만 쓴다 — 이동=세이지, 식사=브라스.
        var tint: Color {
            switch self {
            case .onTime: return Theme.travel
            case .full: return Theme.activity
            }
        }
    }

    @EnvironmentObject var store: Store
    @State private var service: Service?
    @State private var showingSettings = false

    /// 로비 맨 위 줄의 besir 로고와 설정 톱니는 한 줄에 나란히 서지만 틀 크기는 따로 잡는다 — 로고(BesirMark)는 틀의 가로 약
    /// 88%·세로 약 85%만 칠하고 톱니는 틀을 거의 다 채워서, 같은 틀이면 톱니 잉크가 5~6pt 커 보인다. 틀 34·30이면 잉크가 둘 다 30pt 안팎으로
    /// 맞는다(운영자 t88 결정). 톱니를 로고 값의 비율로 계산하지 않은 이유: 비율을 쓰려면 BesirMark 안쪽 기하를 밖으로 꺼내야 한다.
    private static let lobbyMarkSize: CGFloat = 34
    private static let lobbyGearSize: CGFloat = 30

    var body: some View {
        Group {
            switch service {
            case .none:
                home
            case .onTime:
                ContentView(onBack: { service = nil })
            case .full:
                FullSirView(onBack: { service = nil })
            }
        }
    }

    /// 고를 것 두 개뿐. 설명 문구는 두지 않는다 — 이름만으로 충분하고,
    /// 매일 여는 첫 화면에 읽을 거리가 있으면 그게 그대로 피로가 된다.
    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BesirMark(size: Self.lobbyMarkSize)
                Text("besir")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Theme.ink)
                Spacer()
                // 설정은 시간표가 아니라 로비에서 연다(REQ-002) — 시간표 우상단은 비워 둔다(REQ-001).
                Button {
                    showingSettings = true
                } label: {
                    // 감싸는 원을 없애고 톱니 자체를 키운다(운영자 §37). 처음엔 원 크기(44pt)로 키웠더니 너무 커서
                    // "옆의 besir 로고와 비슷한 크기로"(운영자, 시뮬레이터 확인) — 톱니 틀은 로고 틀(lobbyMarkSize)과 따로 두고
                    // lobbyGearSize로 잉크를 로고에 맞춘다. font 크기는 글리프 여백이 섞여 틀과 안 맞으므로 resizable·scaledToFit으로
                    // 틀 안을 채운다. 탭 영역은 44×44를 유지한다(원이 없어도 손가락 닿는 곳이 줄지 않게 — 눈에 보이는 아이콘만 lobbyGearSize).
                    Image(systemName: "gearshape")
                        .resizable()
                        .scaledToFit()
                        .frame(width: Self.lobbyGearSize, height: Self.lobbyGearSize)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.top, 52)
            .padding(.bottom, 34)

            VStack(spacing: 0) {
                Divider().overlay(Theme.line)
                ForEach(Service.allCases) { s in
                    serviceCard(s)
                    Divider().overlay(Theme.line)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func serviceCard(_ s: Service) -> some View {
        Button {
            service = s
        } label: {
            HStack(spacing: 14) {
                Image(systemName: s.systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(s.tint)
                    .frame(width: 24)
                Text(s.title)
                    .font(.title3)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 화면 구석에 떠 있는 동그란 버튼의 모양 한 곳 — 우하단 besir 로고 버튼(RootView)과 왼쪽 아래 '오늘'
/// 버튼(ContentView)이 같은 크기·면·선·바깥 여백을 읽는다(계약 5). 두 버튼의 바닥 높이가 어긋나
/// 따로 고치는 일이 없게 숫자를 여기에만 둔다.
enum FloatingCircle {
    static let diameter: CGFloat = 56
    static let inset: CGFloat = 20
}

extension View {
    func floatingCircle() -> some View {
        self
            .frame(width: FloatingCircle.diameter, height: FloatingCircle.diameter)
            .background(Circle().fill(Theme.bg))
            .overlay(Circle().stroke(Theme.line))
            .contentShape(Circle())
    }
}
