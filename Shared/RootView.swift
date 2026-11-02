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
        case onTime, full, rich
        var id: String { rawValue }

        var title: String {
            switch self {
            case .onTime: return "be on-time sir"
            case .full: return "be full sir"
            case .rich: return "be rich sir"
            }
        }
        var systemImage: String {
            switch self {
            case .onTime: return "clock.badge.checkmark"
            case .full: return "fork.knife"
            case .rich: return "dollarsign.circle"
            }
        }
        /// 색은 서비스 구분에만 쓴다 — 이동=세이지, 식사=브라스.
        var tint: Color {
            switch self {
            case .onTime: return Theme.travel
            case .full: return Theme.activity
            case .rich: return Theme.ink
            }
        }
        /// The colour of a row's key lines under its first one: the service's own ink, the deep tone of its tint.
        var detailInk: Color {
            switch self {
            case .onTime: return Theme.travelInk
            case .full: return Theme.activityInk
            case .rich: return Theme.muted
            }
        }
    }

    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationManager
    @EnvironmentObject var notifications: NotificationManager
    @State private var service: Service?
    @State private var showingSettings = false
    // The session lives here, not in the sheet, so the conversation survives closing the sheet. It sits in a reference
    // holder because the sheet's content and onDismiss closures are built from a copy of this view and read a plain
    // @State optional as nil (a blank sheet); the holder is the same object in every copy.
    @State private var chatHolder = AgentChatHolder()
    @State private var showingChat = false
    @State private var choosingMode = false
    @State private var showingSnap = false
    @StateObject private var snap = SnapFlow()
    @StateObject private var shareImport = SharedImport()
    /// The open sheets: the automatic share pass waits while any is open and runs again when the last one closes.
    @ObservedObject private var sheets = SheetHold.shared
    @Environment(\.scenePhase) private var scenePhase

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
            case .rich:
                BeRichSirView(onBack: { service = nil })
            }
        }
        .sheet(isPresented: $showingChat, onDismiss: { Task { await chatHolder.session?.sheetDismissed(); SheetHold.shared.closed(SheetHold.chatKey) } }) {
            if let session = chatHolder.session { AgentChatView(session: session).holdsSharePass(key: SheetHold.chatKey) }
        }
        .overlay(alignment: .bottomTrailing) {
            if store.config.hasAI {
                VStack(alignment: .trailing, spacing: 12) {
                    if !choosingMode, let label = PlanMyDay.buttonLabel(count: shareImport.waitingCount, held: shareImport.held != nil) {
                        Button {
                            planTapped()
                        } label: {
                            Text(label)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 16)
                                .frame(height: 40)
                                .background(Capsule().fill(Theme.bg))
                                .overlay(Capsule().stroke(Theme.line))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        openChat()
                    } label: {
                        Image(systemName: "ellipsis.bubble")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.ink)
                            .floatingCircle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("besir AI")
                }
                .padding(.trailing, FloatingCircle.inset)
                .padding(.bottom, FloatingCircle.inset)
            }
        }
        // Cancelling or dismissing reads no item, asks for no calendar access and makes no call.
        .confirmationDialog("How will you travel today?", isPresented: $choosingMode, titleVisibility: .visible) {
            ForEach(PlanMyDay.modeChoices) { mode in
                Button(mode.title) { Task { await runPlan(mode: mode) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .snapCamera(flow: snap, isPresented: $showingSnap, onDismiss: snapClosed)
        .overlay { if shareImport.isReading { ProgressView().controlSize(.large) } }
        .alert(shareImport.alertLine ?? "", isPresented: Binding(get: { shareImport.alertLine != nil },
                                                                 set: { if !$0 { shareImport.alertLine = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task { await runShareImport() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await runShareImport() } } }
        .onChange(of: sheets.isAnyOpen) { _, open in if !open { Task { await runShareImport() } } }
        // A tap on a departure alert opens its event on the on-time screen, from the home screen and from be full sir alike.
        .onChange(of: notifications.tappedEventID, initial: true) { _, id in
            if id != nil, service != .onTime { service = .onTime }
        }
    }

    /// One pass over the share queue: one item per pass, the agent gets only the composed text and the chat draws a short line
    /// (SPEC-SHARE-001, SPEC-SHAREBUBBLE-001).
    private func runShareImport() async {
        let client = VisionClient(config: store.config, send: { try await URLSession(configuration: .ephemeral).data(for: $0) })
        await shareImport.pass(vision: client, canHand: { SnapEntry.shareMayHand(canSend: chatHolder.session?.canSend ?? true, coverOpen: showingSnap, sheetOpen: sheets.isAnyOpen) },
                              holdForPlan: true, hand: SharedImport.chatHandOff(holder: chatHolder, openChat: openChat))
    }

    /// The Plan my day button: with a session that cannot take a message the tap only opens the chat (SPEC-PLANDAY-001).
    private func planTapped() {
        switch PlanMyDay.tapAction(canSend: chatHolder.session?.canSend ?? true) {
        case .chooseMode: choosingMode = true
        case .openChatOnly: openChat()
        }
    }

    /// The mode was chosen: gather the waiting items and today's schedule and hand the agent one plan message.
    private func runPlan(mode: TransportMode) async {
        ensureSession()
        guard let session = chatHolder.session else { return }
        let client = VisionClient(config: store.config, send: { try await URLSession(configuration: .ephemeral).data(for: $0) })
        await shareImport.planPass(mode: mode, vision: client, activities: { store.activitiesForPlanning() }, mirror: store.calendarMirror,
                                   prepare: { session.prepareDayPlan(events: $0) }, canHand: { session.canSend },
                                   hand: { message, shown, context in
            openChat()
            return session.sendPlan(message: message, shown: shown, context: context)
        })
    }

    /// The camera circle (SPEC-CAMSNAP-001): with a session that cannot take a message the tap only opens the chat.
    private func openSnap() {
        ensureSession()
        guard let session = chatHolder.session else { return }
        switch SnapEntry.tapAction(canSend: session.canSend) {
        case .openChatOnly:
            openChat()
        case .openCamera:
            let device = SnapDevice.make()
            snap.start(SnapFlow.Deps(reader: SnapClient.live(config: store.config), placeSearch: store.placeSearch,
                                     realFix: { location.realFixLocation }, activities: { store.activitiesForPlanning() },
                                     mirror: store.calendarMirror, prepare: { session.prepareDayPlan(events: $0) },
                                     register: { session.registerPlace($0) }, access: device.access, shutter: device.shutter))
            showingSnap = true
        }
    }

    /// The camera cover is gone: hand over what the tap made, after the cover so the chat sheet never competes with it.
    private func snapClosed() {
        guard let outcome = snap.takeOutcome() else {
            Task { await runShareImport() }
            return
        }
        openChat()
        if let session = chatHolder.session, !SnapHandOff.perform(outcome, to: session) {
            shareImport.alertLine = SnapLine.assistantBusy
        }
    }

    private func ensureSession() {
        if chatHolder.session == nil {
            let location = location
            let origin = { AgentPlaces.devicePlace(manual: location.manualOrigin, current: location.realFixLocation) }
            let session = AgentSession(toolbox: AgentToolbox(store: store, now: { Date() }, timeZone: { TimeZone.current },
                                                             deviceOrigin: origin, searchOrigin: { location.searchOrigin }),
                                       transport: AgentClient(config: store.config, now: { Date() }, timeZone: { TimeZone.current }))
            // A held plan carries place handles of this conversation, so a new chat drops it.
            let shareImport = shareImport
            session.onNewChat = { shareImport.dropHeld() }
            chatHolder.session = session
        }
    }

    private func openChat() {
        ensureSession()
        showingChat = true
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
                SnapEntryButton(isShown: SnapEntry.isShown(hasAI: store.config.hasAI, choosingMode: choosingMode,
                                                           isReading: shareImport.isReading)) { openSnap() }
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

            // The clock is read here and nowhere else: the closure builds the rows from today's store each minute.
            TimelineView(.everyMinute) { _ in
                let rows = LobbyRows.rows(store: store, records: PartnerRecords.shared, ledger: BudgetLedger.shared,
                                          now: Date(), calendar: Calendar.current)
                ScrollView {
                    // One block that always takes the full width between the side margins; the last row stops above the besir AI circle.
                    LobbyColumn {
                        ForEach(rows) { row in
                            if let s = Service(rawValue: row.id) { serviceCard(s, row) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, FloatingCircle.diameter + 2 * FloatingCircle.inset)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .sheet(isPresented: $showingSettings) {
            SettingsView().holdsSharePass()
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    /// One lobby row: the icon beside the first line, the name, then the key lines. No line is cut off.
    private func serviceCard(_ s: Service, _ row: LobbyRow) -> some View {
        Button {
            service = s
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Image(systemName: s.systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(s.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.title3)
                        .foregroundStyle(Theme.ink)
                    ForEach(Array(row.lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(index == 0 ? .subheadline.weight(.semibold) : .subheadline)
                            .foregroundStyle(index == 0 ? Theme.ink : s.detailInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// The lobby rows as one block: always the full width offered, whatever the row text, so the icons
/// and names never move sideways when a line gets longer or shorter. Every row is stacked on the
/// same left edge and given the block's width (so a divider spans the block). With no width offered
/// the block falls back to its widest row.
private struct LobbyColumn: Layout {
    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = width(proposal, subviews)
        let h = subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height
        }
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
