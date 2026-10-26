import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// besir의 색·간격 토큰. 화면마다 색을 직접 쓰지 않고 전부 여기를 거친다.
///
/// 방향은 "차분한 여백": 카드와 그림자를 쓰지 않고 **얇은 선과 여백**으로 나누며, 색은
/// 블록 왼쪽의 가는 띠와 아주 옅은 배경에만 쓴다. 시스템 기본 파랑·주황 대신 고유한
/// 세이지 그린(이동)과 브라스(활동)를 쓴다 — 일정이 하루에 여러 건 쌓여도 화면이 조용하도록.
///
/// 다크 모드는 라이트를 반전한 게 아니라 따로 고른 값이다. 기기 설정을 그대로 따라간다
/// (앱에서 `preferredColorScheme`을 강제하지 않는다).
enum Theme {

    // MARK: 바탕과 글자

    /// 화면 바탕.
    static let bg = adaptive(light: 0xFCFCFB, dark: 0x141613)
    /// 바탕 위에 살짝 올라오는 면(입력창·선택된 칸 등). 카드가 아니라 "아주 옅은 면"이다.
    static let raised = adaptive(light: 0xF4F5F2, dark: 0x1D211B)
    /// 본문 글자.
    static let ink = adaptive(light: 0x22251F, dark: 0xE7EAE3)
    /// 보조 설명.
    static let muted = adaptive(light: 0x8A9086, dark: 0x868C81)
    /// 더 약한 보조(단위·비활성).
    static let faint = adaptive(light: 0xB6BBB1, dark: 0x5C6259)
    /// 구분선. 이 방향에서 거의 유일한 구조 요소라 너무 진하면 안 된다.
    static let line = adaptive(light: 0xE7E9E3, dark: 0x262A24)

    // MARK: 의미색

    /// 이동 구간. 시스템 파랑 대신 차분한 세이지 그린.
    static let travel = adaptive(light: 0x4A6B5A, dark: 0x7FAE93)
    static let travelFill = adaptive(light: 0xEFF2EF, dark: 0x1B2520)
    static let travelInk = adaptive(light: 0x38503F, dark: 0xA5C6B2)

    /// 체류 활동. 시스템 주황 대신 브라스.
    static let activity = adaptive(light: 0xA8763F, dark: 0xC99B5E)
    static let activityFill = adaptive(light: 0xF4F1EC, dark: 0x292218)
    static let activityInk = adaptive(light: 0x5A4326, dark: 0xDFBE8B)

    /// 경고(이동시간 계산 실패).
    static let warn = adaptive(light: 0xB4553A, dark: 0xD2705A)
    static let warnFill = adaptive(light: 0xF7EDE9, dark: 0x2B1C17)

    /// 지금 시각을 가리키는 선.
    static let nowLine = adaptive(light: 0xC2452E, dark: 0xE2705A)

    // MARK: 형태

    /// 이 방향은 거의 각진 모서리를 쓴다(카드가 아니라 면이라서).
    static let radius: CGFloat = 3
    /// 블록 왼쪽 띠 두께 — 색을 쓰는 거의 유일한 자리.
    static let railWidth: CGFloat = 2.5

    // MARK: 구현

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #endif
    }
}

#if os(iOS)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
#else
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
#endif

extension View {
    /// 블록 왼쪽에 색 띠를 붙이고 옅은 면을 깐다. 시간표 블록이 공통으로 쓰는 모양.
    func blockSurface(fill: Color, rail: Color, emphasized: Bool) -> some View {
        self
            .background(fill)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(rail)
                    .frame(width: emphasized ? Theme.railWidth * 1.8 : Theme.railWidth)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

/// besir 마크 — 오각으로 이어진 다섯 방울과, 각 방울 바깥의 떨어진 점.
///
/// 방울 다섯은 다섯 서비스(on-time·full·healthy·fun·rich), 안으로 휜 곡선은 서비스끼리의 연계,
/// 바깥의 점은 외부 서비스 연동(구글 캘린더·카카오맵·배달)을 뜻한다.
///
/// 이미지가 아니라 벡터로 그리는 이유: 크기를 마음대로 키워도 깨지지 않고, **다크 모드에서
/// 색이 알아서 따라간다**(Theme 토큰을 그대로 쓴다).
///
/// ⚠️ 아래 수치는 `Tools/MakeAppIcon.swift`(홈 화면 아이콘 PNG를 그리는 스크립트)와
///    **반드시 같아야 한다**. 한쪽만 고치면 앱 안 로고와 아이콘이 서로 달라 보인다.
struct BesirMark: View {
    /// 마크가 차지할 한 변의 길이.
    var size: CGFloat = 28

    // 마크 좌표계(0~104). 바깥 점 끝이 중심에서 48이라 사방에 4만큼 여백이 남는다.
    private static let box: CGFloat = 104
    private static let center = CGPoint(x: 52, y: 52)
    private static let ringRadius: CGFloat = 24    // 방울 중심이 놓인 원
    private static let nodeRadius: CGFloat = 10
    private static let dotRadius: CGFloat = 6
    private static let dotOffset: CGFloat = 18     // 방울 중심에서 바깥 점까지
    private static let linkWidth: CGFloat = 7
    /// 잇는 곡선을 중심 쪽으로 당기는 정도.
    private static let pull: CGFloat = 0.22

    private static func angle(_ i: Int) -> CGFloat { (-90 + 72 * CGFloat(i)) * .pi / 180 }
    private static func node(_ i: Int) -> CGPoint {
        let a = angle(i)
        return .init(x: center.x + ringRadius * cos(a), y: center.y + ringRadius * sin(a))
    }
    private static func dot(_ i: Int) -> CGPoint {
        let a = angle(i), r = ringRadius + dotOffset
        return .init(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }
    private static func control(_ i: Int) -> CGPoint {
        let a = node(i), b = node((i + 1) % 5)
        let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        return .init(x: m.x + (center.x - m.x) * pull, y: m.y + (center.y - m.y) * pull)
    }

    var body: some View {
        Canvas { context, canvasSize in
            let k = min(canvasSize.width, canvasSize.height) / Self.box
            func p(_ point: CGPoint) -> CGPoint { .init(x: point.x * k, y: point.y * k) }

            var link = Path()
            link.move(to: p(Self.node(0)))
            for i in 0..<5 {
                link.addQuadCurve(to: p(Self.node((i + 1) % 5)), control: p(Self.control(i)))
            }
            link.closeSubpath()
            context.stroke(link, with: .color(Theme.travel),
                           style: StrokeStyle(lineWidth: Self.linkWidth * k, lineJoin: .round))

            func circle(_ c: CGPoint, _ r: CGFloat, _ color: Color) {
                let o = p(c), rr = r * k
                context.fill(Path(ellipseIn: CGRect(x: o.x - rr, y: o.y - rr, width: rr * 2, height: rr * 2)),
                             with: .color(color))
            }
            for i in 0..<5 { circle(Self.node(i), Self.nodeRadius, Theme.travel) }
            for i in 0..<5 { circle(Self.dot(i), Self.dotRadius, Theme.activity) }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("besir")
    }
}
