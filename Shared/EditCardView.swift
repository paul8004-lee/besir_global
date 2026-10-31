import SwiftUI

/// 빠진 인자를 **한 장에 모아** 묻는 카드. 호출마다 끼어들지 않는 이유는 카드를 만드는 쪽에
/// 적혀 있고, 여기서 지키는 건 그 반대편이다: 물어본 값도 묻지 않고 정해진 값도 **전부 화면에
/// 보인다**. 화면에서 빠진 값은 사용자가 고칠 수 없는 값이고, 그게 b303f41(여유 0분 35건)의 모양이었다.
struct EditCardView: View {
    let card: EditCard
    // 확인 버튼 잠금·진행 표시에 쓰는 호출자 쪽 상태 — 뷰가 값을 소유한 주체를 타입으로 알지
    // 못하므로 바쁨 여부만 값으로 받는다.
    let busy: Bool
    // 동작은 전부 이 묶음으로 온다 — 값의 주인을 뷰가 직접 부르면 네 편집 화면이 이 카드를
    // 빌려 쓸 수 없다.
    let actions: EditCardActions
    // 카드 크롬의 뷰 쪽 기본값 — 확인 문구만 기본값을 갖는다. 머리글 기본값은 S1에서 빠졌다
    // (REQ-008): 줄 이름이 곧 물어보는 문장이라 머리글은 같은 말을 두 번 하는 군더더기였다.
    var chrome: EditCardChrome = EditCardChrome(header: nil, confirmTitle: "Add")
    // Pulse from the owner screen: each tap on the empty sheet area outside the card bumps it, and the
    // card answers with the same close a tap on its own empty space gives.
    var outsideTapCount: Int = 0

    // 직접입력 상태는 카드와 수명을 같이 한다. 채팅 뷰에 두면 카드가 요약으로 바뀐 뒤에도
    // 열린 입력창과 거절 표시가 남아 다음 카드로 흘러간다.
    @State private var customOpen: Set<UUID> = []
    @State private var draft: [UUID: String] = [:]
    @State private var rejected: Set<UUID> = []
    // 직접 넣은 값의 기억 — 같은 줄의 다른 칩을 골라도 그 값이 미선택 칩으로 남게 하는 상태
    // (SPEC-UIKIT-014). 값의 주인이 넷이라 모델이 아니라 여기 두고, 줄 id가 열쇠라 카드와 수명을
    // 같이 한다. 줄이 다시 서면 새 UUID라 기억이 못 따라가는 것은 의도된 한계다.
    @State private var keptTyped: [UUID: String] = [:]
    // 시각 줄의 임시 상태 — 기준 칩뿐이다. 다이얼 위치는 임시 상태가 아니다: 돌리는 즉시 확정
    // 경로를 지나므로(O-A1) 다이얼이 서 있는 자리는 언제나 카드의 확정값이다. 기준은 처음에
    // 아무것도 골라두지 않는다(사용자 결정: 앱이 먼저 정해둔 값이 오늘 하루 종일 없애던 것이므로,
    // 여기서도 예외를 두지 않는다).
    @State private var draftBasis: [UUID: ScheduleAnchor] = [:]
    // 장소 목록은 검색창을 누른 동안에만 열린다(REQ-003 A) — 늘 펼쳐 두면 고르지 않을 줄이
    // 카드를 밀어 올리고, 검색한 적 없는 줄에 빈 상태 문구까지 떠 있다(F3).
    @State private var placeOpen: Set<UUID> = []
    // 시각 다이얼이 열린 순간의 'now'(R3, AC-012) — 씨앗은 now에 기대는데(dialSeed) 렌더마다 Date()를
    // 새로 잡으면 분이 넘어가는 순간 화면의 씨앗이 슬쩍 바뀌고, 닫을 때 확정되는 씨앗은 또 다른 now로
    // 구해져 보인 값과 달라진다. 열 때 한 번 잡아 화면과 닫기가 이 값을 같이 읽는다.
    @State private var dialOpenedAt: [UUID: Date] = [:]
    // 열린 검색창의 포커스 — openPlaceList가 목록을 여는 순간 키보드까지 같이 올린다.
    @FocusState private var placeFocus: UUID?
    // 텍스트 칸(제목·'반복')의 포커스 — '반복' 칸은 마칠 때 해석하므로(SPEC-UIKIT-019 REQ-004) 포커스가 떠나는
    // 순간이 곧 마침이다. Return·바깥 탭 두 길이 모두 이 값의 변화로 모여 해석이 한 번만 불린다.
    @FocusState private var titleFocus: UUID?

    // 칩 높이는 글자 크기를 따라 커진다 — 고정하면 큰 글씨 설정에서 칩이 잘린다.
    // iOS는 손가락이라 44pt가 최소고, macOS는 포인터라 그만큼 키우면 카드만 길어진다.
    #if os(iOS)
    @ScaledMetric(relativeTo: .callout) private var chipHeight: CGFloat = 44
    #else
    @ScaledMetric(relativeTo: .callout) private var chipHeight: CGFloat = 28
    #endif

    // '반복' 줄이 해석 전이라서만 남은 카드도 누를 수 있다(019 m-4) — 꺼 두면 눌러도 칸이 마쳐지지 않아 해석이 영영
    // 안 불렸다. 누르면 소유자의 확정 경로가 해석을 먼저 끝내고 다시 판정한다.
    private var canConfirm: Bool { (card.isReady || card.isReadyAfterRecurrenceCommit) && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 머리글은 카드가 스스로 그리는 크롬이라 소유 화면이 끌 수 있다 — 화면 제목과
            // 겹치는 화면에서 둘 다 보이면 제목이 둘로 읽힌다.
            if let header = chrome.header {
                Text(header)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }

            // 정해진 값은 별도 안내 줄이 아니라 값이 채워진 줄로 보인다(REQ-009) — 안내 줄에만
            // 적혀 있던 값은 사용자가 고칠 수 없는, 조용히 적용되는 값이었다(b303f41).

            // A field of a repeatable row group is drawn inside the group's swipe container; every other field exactly as
            // before, with no wrapper, so a card that sets no rowID draws as it always did.
            ForEach(FieldRun.of(card.fields)) { run in
                if let rowID = run.rowID {
                    SwipeRow(rowID: rowID, actions: actions) {
                        ForEach(run.fields) { field in
                            fieldRow(field, depBasis: departureAnchored)
                        }
                    }
                } else {
                    fieldRow(run.fields[0], depBasis: departureAnchored)
                }
            }

            confirmButton
        }
        .padding(14)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
        // 카드의 빈 곳을 누르면 열려 있는 목록·다이얼이 정리된다(REQ-003 A) — Button·TextField는
        // 탭을 자기가 받아 이 제스처에 걸리지 않으므로 빈 곳에만 닿는다.
        .contentShape(Rectangle())
        .onTapGesture { collapseOtherEditors() }
        .onChange(of: outsideTapCount) {
            collapseOtherEditors()
        }
        // '반복' 칸에서 포커스가 떠나면 해석을 맡긴다 — 해석이 필요한지(빈 글·이미 해석한 글)는 소유자 쪽 폼이 정하고,
        // 결과도 소유자가 줄에 붙인다. 뷰는 결과를 들지 않는다.
        .onChange(of: titleFocus) { old, new in
            guard let old, old != new,
                  card.fields.first(where: { $0.id == old })?.key == RecurrenceLine.key,
                  let commit = actions.commitRecurrence else { return }
            Task { await commit(old) }
        }
        // startsOpen 줄의 에디터를 카드가 뜰 때 연다. 합집합으로 씨앗을 뿌리는 까닭은 이미
        // 열려 있는 입력칸을 닫을 근거가 없어서고, draft를 채우지 않는 까닭은 빈 칸이 곧
        // "새로 입력하라"는 뜻이라서다 — 완성 전 카드가 뜨는 일은 소유 화면이 막는다.
        .onAppear {
            // 장소 줄의 에디터는 이제 placeOpen이 연다 — customOpen에 섞이면 칩 문법의 줄로 읽힌다.
            customOpen.formUnion(card.fields.filter { $0.startsOpen && $0.kind != .place }.map(\.id))
            // 처음부터 열리는 시각 줄도 여는 순간의 now를 잡는다(openCustom을 거치지 않는 길).
            for f in card.fields where f.startsOpen && f.kind == .datetime && dialOpenedAt[f.id] == nil {
                dialOpenedAt[f.id] = Date()
            }
            // startsOpen인 장소 줄은 목록을 연 채 시작한다 — 후보 카드가 미리 얹은 낱말(searchSeed)을
            // 검색창에 채워 글자가 있는 갈래(맞는 즐겨찾기 → 후보)로 보이게 하고, 이미 실린 후보를
            // 다시 검색하지 않는다(O-S1-1 (나)).
            for f in card.fields where f.kind == .place && f.startsOpen {
                placeOpen.insert(f.id)
                if let seed = f.searchSeed { draft[f.id] = seed }
            }
        }
    }

    /// 시각 줄이 출발 기준으로 확정됐는지 — 이면 도착 여유 줄이 흐려지고 캡션이 붙는다. 기준 있는
    /// 줄만 재료로 삼는다: 활동 카드의 시작·종료는 기준이 없어 currentBasis의 ?? .departure
    /// 폴백이 언제나 출발로 답하는데, 그 줄을 재보면 여유 줄은 생기자마자 영구히 흐려진다
    /// (SPEC-UIKIT-003 §1.4 — REQ-014의 선행 조건이라 폴백은 고치지 않고 묻는 대상을 고쳤다).
    private var departureAnchored: Bool {
        guard let time = card.fields.first(where: { $0.kind == .datetime && $0.anchored }) else { return false }
        return currentBasis(time) == .departure
    }

    // MARK: 줄

    @ViewBuilder
    private func fieldRow(_ field: EditField, depBasis: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 줄 이름 옆의 진행 표시 — 화면 소유 상태가 이 줄에서 일하는 중임을 알린다.
            // 장소 검색의 "찾는 중…"과 같은 문법이라 두 진행이 한 카드에서 같게 읽힌다.
            HStack(spacing: 6) {
                Text(field.label)
                if field.busy {
                    // 이름 없는 스피너는 VoiceOver에서 소리만 나고 무엇이 진행 중인지 안 들린다 —
                    // 줄 컨테이너(.contain)가 줄 이름 뒤에 이 문구를 이어 읽는다.
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("In progress")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.faint)

            // 값이 차 있는데 앱이 풀지 못해 뜬 줄에만 붙는다. 줄 이름만 있으면 "말한 적 없는 값"을
            // 묻는 줄과 구분되지 않아, 방금 "회사"라고 말한 사용자가 왜 또 묻는지 알 수 없다(결함 O).
            // fixedSize로 줄바꿈을 강제한다 — 길어도 잘리지 않는다(G11: 줄을 숨기지 않는다).
            // 시각 줄의 note는 이 자리에 오지 않는다 — 몸통(다이얼) 아래로 옮겼다(REQ-010 F5).
            // 이 자리의 글은 오류·경고(못 푼 값·같은 이름·위치 권한 꺼짐)라 같은 카드의 '검색 결과 없음'과 같은 경고 색이다
            // (0.2.12 D-1 — 권한 안내가 흐린 색이라 오류로 읽히지 않았다). 색은 Theme 토큰만(계약 6).
            if let note = field.note, field.kind != .datetime {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if field.kind == .datetime {
                datetimeRow(field)
            } else if field.kind == .place {
                // 장소 줄은 칩 줄이 아니라 검색창 하나와 목록이다(REQ-003) — 값은 목록의 행을
                // 탭해 정한다. 네 편집 화면이 같은 카드를 쓰므로 AI 채팅 카드도 같은 문법이 된다.
                placeLine(field)
            } else if field.kind == .title {
                // 제목 줄은 칩도 확인 단추도 없는 칸 하나다(REQ-001) — 확정 동작을 거치지 않고
                // 매 입력이 값이 된다.
                titleLine(field)
            } else if field.kind == .readonly {
                // 읽기 전용 값 줄(REQ-009) — 고르거나 고칠 수 없는 맥락 값이다. 값 칸과 같은 문법으로
                // 보이되 누르지 않는다: 누를 수 있게 두면 고를 수 있다는 뜻이 된다.
                HStack {
                    Text(field.chosenLabel ?? "")
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(minHeight: chipHeight)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
            } else {
                ChipFlow(spacing: 6, lineSpacing: 6) {
                    ForEach(field.options) { option in
                        chip(option.label, selected: field.chosen == option.value, detail: option.detail,
                             name: option.accessibilityName) {
                            // 떠나기 전의 직접 값을 먼저 기록하고 선택을 바꾼다 — 클로저가 잡은
                            // field는 렌더 시점 값이라 어느 쪽을 먼저 부르든 옛 chosen을 읽지만,
                            // 이 순서(떠남 → 기록 → 선택)가 읽는 사람에게 자연스럽다.
                            keptTyped[field.id] = field.valueToKeep(onLeaving: keptTyped[field.id])
                            actions.chooseValue(field.id, option.value)
                            closeCustom(field)
                            // 이 줄에서 값을 골랐으니 다른 줄의 에디터는 정리한다(시안: 다른 줄을
                            // 누르면 다시 값 글자로 접힌다).
                            collapseOtherEditors()
                        }
                    }
                    // 추가 칩은 많아야 하나다 — 선택된 직접 값이 있으면 그것이 이기고, 아니면 기억한
                    // 값이 미선택 칩으로 남는다(SPEC-UIKIT-014 D2b). 기억 칩을 다시 누르면 직접입력
                    // 확인과 같은 길(submitCustom)로 골라 받아들이되, closeCustom이 거절 표시를
                    // 지우므로 닫기가 먼저다. 기억은 성공·실패 어느 쪽에서도 지우지 않는다 —
                    // 거절됐다고 칩이 말없이 사라지면 이 수리가 없던 것과 같다.
                    if let extra = field.extraChip(kept: keptTyped[field.id]) {
                        chip(extra.label, selected: extra.selected) {
                            if extra.selected {
                                openCustom(field)
                            } else {
                                closeCustom(field)
                                if !actions.submitCustom(field.id, extra.value) {
                                    rejected.insert(field.id)
                                }
                            }
                        }
                    }
                    if field.allowsCustom {
                        // 칩 글자는 모델의 단일 출처에서 온다 — 이 문법에 남는 줄은 숫자뿐이다
                        // (제목·장소는 각자 항상 열려 있는 칸, S1).
                        chip(EditField.customEntryChipLabel, selected: false) { openCustom(field) }
                    }
                }

                if customOpen.contains(field.id) { textCustomEditor(field) }

                // 거절 사유에 범위를 적지 않는 이유: 상한이 Store 상수라 문구에 박으면 두 곳이 된다.
                if rejected.contains(field.id) {
                    Text("That value can't be used")
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                }
            }

            // 시각 줄의 거절 문구(REQ-010 F5) — 몸통(다이얼) 아래·다이얼과 겹치지 않는 곳. 자리를
            // 미리 비워 두지 않으므로 문구가 나타났다 사라져도 다이얼 위치는 움직이지 않는다.
            if field.kind == .datetime, let note = field.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        // 출발 기준으로 확정된 카드의 도착 여유는 쓰이지 않는다 — 캡션은 지웠고(REQ-011 G4) 흐림만
        // 남는다. 값은 그대로 골을 수 있고 chosen도 남아 있어서 확인 버튼이 막히지 않는다(직렬화에서만 빠진다).
        .opacity(field.kind == .buffer && depBasis ? 0.5 : 1)
        // 칩만 따로 읽히면 무엇에 대한 선택인지 알 수 없다 — 줄 이름과 묶어서 읽히게 한다.
        .accessibilityElement(children: .contain)
        // 캡션이 있으면 줄 이름과 함께 읽힌다 — 왜 떴는지가 화면에만 있고 음성엔 없으면 안 된다.
        .accessibilityLabel(field.note.map { "\(field.label). \($0)" } ?? field.label)
        // 흐려진 이유가 화면의 색에만 있으면 음성으로는 닿지 않는다 — 캡션을 지운 만큼 보이지 않는
        // 접근성 값이 그 이유를 대신 말한다(O-S1-5, 색만으로 상태를 말하지 않는다는 설계 유지).
        .modifier(BufferDimValue(dimmed: field.kind == .buffer && depBasis))
    }

    /// 칩 목록에 없는 값이 골라져 있으면 그 표시 문구. 없으면 nil.
    private func typedLabel(_ field: EditField) -> String? {
        field.typedValue != nil ? field.chosenLabel : nil
    }

    // MARK: 시각 줄

    /// 시각 줄의 현재 기준. 커밋된 값이 있으면 그 접두가 정답이고, 없으면 사용자가 방금 탭한
    /// 임시값이다(처음엔 둘 다 없다 — 기준은 미리 골라두지 않는다).
    private func currentBasis(_ field: EditField) -> ScheduleAnchor? {
        if let chosen = field.chosen { return BesirTime.parseDatetime(chosen).flatMap { BesirTime.anchor(ofPrefix: $0.prefix) } ?? .departure }
        return draftBasis[field.id]
    }

    private func tapBasis(_ field: EditField, _ basis: ScheduleAnchor) {
        // 이미 커밋된 시각이면 같은 시각으로 접두만 바꿔 재확정한다(에디터 재오픈 없이) — 이때
        // 도착 여유 줄의 흐림이 함께 바뀐다.
        actions.rechooseTimeBasis(field.id, basis)
        draftBasis[field.id] = basis
    }

    /// 시각 줄 몸통 — 기준 칩(기준 있는 줄만)과 값 칸 하나. 값 칸을 누르면 그 자리가 다이얼로
    /// 펼쳐진다(REQ-006 — 다이얼 위에 값 칸을 따로 두지 않는다). 펼쳐진 동안에도 기준 칩은 줄 위에
    /// 그대로 살아 있어 도착/출발을 바꾸면 그 기준으로 재확정된다.
    private func datetimeRow(_ field: EditField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 기준 없는 줄(활동의 시작·종료)은 이 줄이 통째로 없다 — 기준 칩만 남기면 고를 수
            // 없는 값을 보여주는 셈이다(REQ-001).
            if field.anchored {
                ChipFlow(spacing: 6, lineSpacing: 6) {
                    // 출발 기준 → 도착 기준 순서는 사용자 확인 요청 ③(2026-09-20)이다.
                    ForEach([ScheduleAnchor.departure, .arrival], id: \.self) { basis in
                        chip(basis == .arrival ? "By Arrival" : "By Departure",
                             selected: currentBasis(field) == basis) {
                            tapBasis(field, basis)
                        }
                    }
                }
            }

            if customOpen.contains(field.id) {
                datetimeEditor(field)
            } else {
                valueCell(field)
            }
        }
    }

    /// 접힌 값 칸 — 확정값을 BesirTime.when 표기(chosenLabel)로 보이는 누를 수 있는 글자다.
    /// 값이 없을 때도 같은 자리에 '고르기' 글자가 서게 한다: 빈 칸은 어디를 누를지 알려 주지
    /// 않는다(장소 줄의 검색창과 같은 원칙). 시각 표기의 단일 출처는 chosenLabel이 읽는
    /// BesirTime.when이고, 다이얼 안의 날짜 열 표기는 네이티브가 주는 것을 그대로 둔다(O-A10 관측).
    private func valueCell(_ field: EditField) -> some View {
        Button {
            openCustom(field)
        } label: {
            HStack {
                Text(field.chosenLabel ?? "Pick date and time")
                    .font(.callout)
                    .foregroundStyle(field.chosenLabel == nil ? Theme.muted : Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: chipHeight)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }

    /// 펼쳐진 시각 줄 — 다이얼 하나뿐이고 확인 단추는 없다(REQ-006, O-A1). 종료 다이얼 줄은 기준이
    /// 있어야 세운다(없으면 baseHint 안내 — 확정 경로가 기준 없이는 도는 일이 없게), 기준 있는 줄은
    /// 기준 칩을 먼저 골라야 세운다. 나머지(기준 없는 일반 줄)는 같은 다이얼로 곧장 확정한다.
    /// 씨앗은 모델의 dialSeed가 홀로 정한다(REQ-006 F1·D10, 계약 5) — 닫기 동작(closeDial)이
    /// 확정하는 씨앗과 화면이 보인 씨앗이 같아야 하므로 뷰는 임시 폴백을 갖지 않는다. 씨앗이 nil인
    /// 줄은 다이얼을 세우지 않는다(endWheel-no-base의 안내 가지와 같은 문법).
    private func datetimeEditor(_ field: EditField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let spec = field.endWheel {
                if let base = card.endWheelBase(for: field) {
                    if let seed = card.dialSeed(for: field, base: base, now: dialNow(field)) {
                        ValueDial(timeOnly: spec.capsAt24Hours, label: field.label, seed: seed) { pick in
                            // 반복 끝 줄(REQ-007)의 시각→절대 시각 합성까지 닫기 동작과 같은 길
                            // (dialCommitCandidate)로 보낸다 — 합성이 뷰에 남으면 닫을 때 확정되는
                            // 값과 돌려 확정되는 값이 어긋난다(계약 5).
                            let candidate = card.dialCommitCandidate(pick: pick, field: field, base: base)
                            return actions.chooseTimePlain(field.id, candidate)
                        }
                    }
                } else if let hint = spec.baseHint {
                    Text(hint).font(.caption).foregroundStyle(Theme.muted)
                }
            } else if field.anchored, let basis = currentBasis(field) {
                if let seed = card.dialSeed(for: field, base: nil, now: dialNow(field)) {
                    ValueDial(timeOnly: false, label: field.label, seed: seed) { pick in
                        actions.chooseTime(field.id, basis, pick)
                    }
                }
            } else if field.anchored {
                // 기준 있는 줄은 기준 없이는 확정 경로가 안 돈다 — 다이얼 대신 안내만(baseHint 문법).
                Text("Pick a basis first").font(.caption).foregroundStyle(Theme.muted)
            } else {
                // 기준도 바퀴 규칙도 없는 줄(활동 편집의 시작) — 같은 다이얼, 확정은 chooseTimePlain.
                if let seed = card.dialSeed(for: field, base: nil, now: dialNow(field)) {
                    ValueDial(timeOnly: false, label: field.label, seed: seed) { pick in
                        actions.chooseTimePlain(field.id, pick)
                    }
                }
            }
        }
    }

    /// 칩 하나. 선택 표시는 색뿐이다(채움 반전 + 글자색 반전, 낭독은 .isSelected) — 폭을
    /// 바꾸는 신호(글리프·굵기)를 붙이는 순간 칩 폭이 선택 상태를 따라가고 그 칩이 속한 줄이
    /// 다시 짜이므로, 운영자가 2026-10-10에 글리프·굵기 신호를 모두 철회했다. 덕분에 칩 폭은
    /// 어느 상태에서나 미선택 폭 그대로다. 직접입력 칩도 같은 실선이다(2026-09-24 사용자
    /// 요청으로 통일 — 칩마다 테두리가 다르면 버튼 문법이 흔들린다).
    private func chip(_ label: String, selected: Bool, detail: String? = nil, name: String? = nil,
                      action: @escaping () -> Void) -> some View {
        named(Button(action: action) {
            HStack(spacing: 4) {
                Text(label).font(.callout)
                // 칩 안의 작은 근거 글(소요시간). 한 단계 작게, 미선택일 때는 색도 흐리게 둬
                // 값과 근거가 한 덩어리로 읽히지 않게 한다. 별도 접근성 문구는 붙이지 않는다 —
                // 칩의 Text들이 이미 합쳐 읽히기 때문이다("자동차 32분").
                if let detail {
                    Text(detail).font(.caption)
                        .foregroundStyle(selected ? Theme.bg : Theme.muted)
                }
            }
            .foregroundStyle(selected ? Theme.bg : Theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: chipHeight)
            .background(selected ? Theme.travel : Theme.bg, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton), name)
    }

    /// The VoiceOver name of one chip, applied only when there is one: an empty label would silence every unnamed chip.
    @ViewBuilder
    private func named<Chip: View>(_ chip: Chip, _ name: String?) -> some View {
        if let name { chip.accessibilityLabel(name) } else { chip }
    }

    // MARK: 제목 줄 — 입력칸 하나(REQ-001, S1)

    /// 제목 줄의 몸통 — 칩도 '직접입력' 칩도 확인 단추도 없는 입력칸 하나. 매 입력이 곧 확정이라
    /// 다른 조작 없이 저장하면 칸에 보이는 글자가 저장된다(REQ-002 — 칩 문법은 확인을 빼먹으면
    /// 옛 제목이 조용히 저장됐다). 문법은 장소 검색창과 같은 roundedBorder 계열이다(REQ-007 —
    /// 한 카드에서 두 텍스트 칸이 다르게 보이면 줄마다 입력 법을 따로 배우게 된다).
    private func titleLine(_ field: EditField) -> some View {
        TextField(placeholder(for: field), text: titleBinding(field))
            .textFieldStyle(.roundedBorder)
            .focused($titleFocus, equals: field.id)
            // Return이 포커스를 저절로 놓지 않는 경우에도 마침이 포커스 변화 한 길로 오게 한다 — 이미 놓였으면
            // nil→nil이라 변화가 없어 해석이 두 번 불리지 않는다.
            .onSubmit { titleFocus = nil }
            // TextField가 탭을 삼켜 카드 전체의 onTapGesture가 안 울린다 — 제목 칸을 눌러도 열린 장소
            // 목록·다이얼이 그대로 남던 결함(SIM t82-13, REQ-005 0.2.7). simultaneousGesture는
            // 칸의 포커스 처리와 함께 돌고, 닫는 길은 빈 곳 탭과 같은 collapseOtherEditors 하나다.
            // 포커스 변화(onChange)로 하지 않은 까닭: 이미 포커스가 있는 칸을 다시 누르면 변화가
            // 없어 안 울린다(칩으로 다이얼을 연 뒤 제목 칸을 다시 누르는 길).
            .simultaneousGesture(TapGesture().onEnded { collapseOtherEditorsAfterTap(except: field.id) })
    }

    /// 입력 칸(제목·숫자) 탭의 닫기 — 다음 메인 턴으로 미룬 collapseOtherEditors다(닫는 길은 그대로 하나).
    /// 같은 탭 안에서 닫으면 열린 장소 목록의 초점 칸이 계층에서 빠지고 placeFocus가 nil이 되는 일이
    /// 시스템이 새 초점을 탭한 칸으로 옮기는 중에 겹쳐, 새 초점까지 풀려 바로 친 글자가 사라졌다
    /// (SIM t82-13 재확인 기대 5). 미루면 그 차례엔 초점이 이미 새 칸에 있어 closePlaceList의
    /// 가드가 내릴 초점이 없다. 늦게 울려도 안전하다 — 닫을 대상은 열림 집합(customOpen·placeOpen)에
    /// 든 줄뿐이고, 한 번 더 불려도 이미 닫힌 줄은 건너뛰므로 멱등이다.
    private func collapseOtherEditorsAfterTap(except id: UUID) {
        Task { @MainActor in collapseOtherEditors(except: id) }
    }

    /// 제목 칸의 바인딩 — set이 매 입력을 확정 통로로 보낸다. get이 draft를 먼저 읽는 이유:
    /// 확정값은 트림된 값이라 칸 글자를 chosen에서 그리면 입력 중인 앞뒤 공백이 튀어 올라온다.
    private func titleBinding(_ field: EditField) -> Binding<String> {
        Binding(
            get: { draft[field.id] ?? field.chosen ?? "" },
            set: { text in
                draft[field.id] = text
                if let setTitleText = actions.setTitleText {
                    setTitleText(field.id, text)
                } else {
                    // 옛 단독 이동 편집 화면의 어댑터는 이 통로가 없다(O-B1 — 대상 밖) — 옛 확정
                    // 경로로 흘려 그 화면의 제목 입력이 끊기지 않게 한다(빈 칸은 옛 문법대로 값을
                    // 바꾸지 않는다).
                    _ = actions.submitCustom(field.id, text)
                }
            }
        )
    }

    // MARK: 직접입력

    /// 텍스트 에디터의 안내문 — .datetime은 여기 안 온다(시각 줄의 에디터는 DatePicker다).
    /// 장소 줄은 예시를 붙이지 않는다 — 입력하면 목록이 뜬다는 걸 화면이 스스로 보여주므로 예시는
    /// 부연 설명이 된다(REQ-011 G2).
    private func placeholder(for field: EditField) -> String {
        if let custom = field.placeholder { return custom }
        // '반복' 줄은 제목 줄과 같은 .title 칸이라 Kind로는 갈리지 않는다 — 열쇠로 먼저 가른다(새 Kind 없음, L-33).
        if field.key == RecurrenceLine.key { return RecurrenceLine.placeholder }
        switch field.kind {
        case .place: return "Search places"
        case .title: return "Title"
        case .datetime: return "Date and time"
        case .mode, .buffer, .notify: return "Numbers only"
        // 토글·읽기 전용 줄은 allowsCustom이 false라 에디터가 열리지 않아 실행 중 도달하지
        // 않는다 — "숫자만"과 묶으면 뜻도 없는 안내문이 붙으므로 따로 둔다(전수 switch 유지).
        case .toggle, .readonly: return ""
        }
    }

    // MARK: 장소 줄 — 검색창 하나와 목록(REQ-003~005)

    /// 장소 줄의 몸통 — 닫힌 줄은 누름 글자 하나, 열린 줄은 검색창과 목록이다(REQ-003 A). 목록
    /// 구성(특수 행 → 즐겨찾기 묶음 → 검색 후보, 순서·걸러짐)은 PlaceLine.rows가 단일 출처고
    /// 여기는 그린 것만 담는다. 목록이 늘 펼쳐 있던 모양에서 누른 동안에만 열리도록 바뀐 이유:
    /// 고르지 않을 줄이 카드를 밀어 올리고, 검색한 적 없는 줄에 빈 상태 문구까지 떠 있다(F3).
    /// 스크롤은 바깥 ScrollView가 담당한다. 자유 텍스트를 그대로 확정하는 길은 여전히 없다:
    /// 좌표가 없어 실행부가 같은 검색으로 다시 실패하고, 그 실패는 카드를 다 채운 뒤에 온다(결함 P).
    @ViewBuilder
    private func placeLine(_ field: EditField) -> some View {
        if placeOpen.contains(field.id) {
            let query = draft[field.id] ?? ""
            // 후보 뽑기를 도우미로 뺀 이유: @ViewBuilder 안의 if case 대입문은 뷰 표현식으로
            // 읽혀 빌드가 깨진다 — 계산은 문 밖(? 옛 함수 몸통)에서만 문장일 수 있다.
            let candidates = Self.lookupCandidates(field.lookup)
            let rows = PlaceLine.rows(query: query, specials: field.placeSpecials,
                                      favorites: field.options, candidates: candidates)
            let indexed = Array(rows.enumerated())
            VStack(alignment: .leading, spacing: 6) {
                TextField(placeholder(for: field), text: placeQueryBinding(field))
                    .textFieldStyle(.roundedBorder)
                    .focused($placeFocus, equals: field.id)
                    #if os(iOS)
                    .submitLabel(.search)
                    #endif
                ForEach(indexed, id: \.offset) { i, row in
                    // 묶음 머리글은 앞 행과 종류가 달라지는 지점에만 붙는다 — 순서 판정은 rows가 이미
                    // 냈으므로 뷰가 다시 세지 않는다(계약 5).
                    if let header = Self.placeSectionHeader(for: row,
                                                            after: i > 0 ? indexed[i - 1].element : nil) {
                        Text(header)
                            .font(.caption)
                            .foregroundStyle(Theme.faint)
                    }
                    placeRowBody(field, row)
                }
                if rows.contains(where: { $0.isCandidate }) {
                    GoogleMapsAttribution()
                }
                switch field.lookup {
                case .idle:
                    EmptyView()
                case .searching:
                    // 검색이 도는 동안에도 맞는 즐겨찾기는 위에 남고, 카드를 막지 않는다.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Searching…").font(.caption).foregroundStyle(Theme.muted)
                    }
                case .empty:
                    // 빈 상태 문구는 목록이 통째로 빌 때만 보인다(REQ-004 F2) — 맞는 즐겨찾기가
                    // 하나라도 남으면 검색이 빈 것이 아니라 아직 고르지 않은 것이다. 판정은
                    // PlaceLine.showsNoResultNote가 혼자 한다(계약 5). 0건과 검색 실패(오프라인)를
                    // PlaceSearch가 같은 빈 배열로 돌려줘 앱이 구분하지 못한다 — 구분 못 하는 것을
                    // 구분한 척하지 않고 양쪽을 함께 말한다.
                    // A row the partner resolves has no favorites and tells empty from failed: its own note is chosen by
                    // PlaceLine.partnerNote.
                    if let note = PlaceLine.partnerNote(partnerLookup: field.partnerLookup, lookup: field.lookup) {
                        partnerNoteText(note)
                    } else if PlaceLine.showsNoResultNote(query: query, lookup: field.lookup,
                                                          favorites: field.options) {
                        Text(PlaceLine.noResultNote)
                            .font(.caption).foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .results:
                    EmptyView()
                case .failed:
                    if let note = PlaceLine.partnerNote(partnerLookup: field.partnerLookup, lookup: field.lookup) {
                        partnerNoteText(note)
                    }
                }
            }
        } else {
            closedPlaceRow(field)
        }
    }

    /// 닫힌 장소 줄 — 검색창과 같은 모양의 누름 글자 하나(REQ-003 A). 골라 둔 값을 이 글자가
    /// 대신 말한다(옛 '현재 선택' 안내 줄이 하던 일, REQ-008 D). 글자는 모델의 단일 출처
    /// (closedSearchText)에서 온다 — 후보 카드가 얹은 검색 낱말을 그대로 보일지까지 값의 주인이
    /// 정하는 일이라 뷰가 따로 판단하지 않는다(계약 5).
    private func closedPlaceRow(_ field: EditField) -> some View {
        // 폴백 사슬은 합의된 순서다 — 화면 소유자가 내려준 글자, 골라 둔 값의 라벨, 없음.
        let text = actions.closedSearchText?(field.id) ?? field.chosenLabel ?? ""
        let shown = text.isEmpty ? placeholder(for: field) : text
        return Button {
            openPlaceList(field)
        } label: {
            HStack {
                Text(shown)
                    .font(.callout)
                    .foregroundStyle(text.isEmpty ? Theme.muted : Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: chipHeight)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
        }
        .buttonStyle(.plain)
        // 닫힌 누름 글자가 열릴 검색창과 같은 대상임이 읽히게 줄 이름과 값을 함께 말한다 —
        // 글자만 읽히면 어떤 줄의 값인지 알 수 없다(접힌 값 칸 valueCell과 같은 문제).
        .accessibilityLabel("\(field.label), \(shown)")
    }

    /// 장소 목록 열기 — 다른 줄의 에디터를 먼저 정리하고(한 카드에서 열린 에디터는 하나),
    /// 검색창에 씨앗 낱말을 얹는다. 다시 검색하지 않는다: 닫을 때 lookup을 지우지 않았으므로
    /// 후보 카드가 미리 얹은 후보가 다시 열어도 살아 있다(R-1, O-S1-1 (나)).
    private func openPlaceList(_ field: EditField) {
        collapseOtherEditors(except: field.id)
        draft[field.id] = field.searchSeed ?? ""
        placeOpen.insert(field.id)
        placeFocus = field.id
        // A text the model stated for a row the partner resolves starts one lookup the first time the row is opened; the search
        // spends the seed in the model, so a reopened row does not search it again.
        if let seed = PlaceLine.seedToSearchOnOpen(seed: field.searchSeed, lookup: field.lookup) {
            actions.searchPlaces(field.id, seed)
        }
    }

    /// The note of a partner row whose lookup found nothing or failed, in the warning style of the place search's own note.
    private func partnerNoteText(_ note: String) -> some View {
        Text(note)
            .font(.caption).foregroundStyle(Theme.warn)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 장소 목록 닫기 — 고르지 않고 닫으면 입력하던 글자를 지우고 확정값 이름의 누름 글자로
    /// 돌아간다(O-S1-2: 줄 값과 다른 글자가 닫힌 줄에 남지 않게). lookup은 지우지 않는다.
    private func closePlaceList(_ field: EditField) {
        placeOpen.remove(field.id)
        draft[field.id] = nil
        if placeFocus == field.id { placeFocus = nil }
    }

    /// lookup이 실어 온 후보 — .results일 때만 있고 나머지 상태는 빈 배열이다(빈 상태 문구는
    /// showsNoResultNote가 따로 판정한다).
    private static func lookupCandidates(_ lookup: EditField.Lookup) -> [Place] {
        if case .results(let places) = lookup { return places }
        return []
    }

    /// 묶음 머리글 — 시안(t82-5)이 즐겨찾기와 검색 결과를 머리글로 가르는 모양이다. 검색 후보는
    /// 검색어가 있을 때만 목록에 오므로 "검색 결과" 머리글도 자연히 그 상태에만 붙는다.
    private static func placeSectionHeader(for row: PlaceLine.Row,
                                           after previous: PlaceLine.Row?) -> String? {
        switch row {
        case .special: return nil
        case .favorite: return previous?.isFavorite == true ? nil : "Favorites"
        case .candidate: return previous?.isCandidate == true ? nil : "Search results"
        }
    }

    /// 목록의 행 — 특수 행은 토큰을 값으로, 즐겨찾기·후보는 Place를 직접 실어 확정한다(REQ-005:
    /// 같은 라벨 즐겨찾기 둘의 좌표가 줄 신원으로 갈라진다). 좌표 없는 즐겨찾기 옵션(옛 생성부)
    /// 만 라벨 값으로 고르는 옛 길로 간다. 행을 누른 순간 목록이 닫히는 것은 구조적 방어다 —
    /// 검색 글자와 빨간 빈 상태 문구가 닫힌 줄에 남지 않게 한다(F3).
    @ViewBuilder
    private func placeRowBody(_ field: EditField, _ row: PlaceLine.Row) -> some View {
        switch row {
        case .special(let token):
            placeTextRow(label: PlaceTokens.displayText(token), detail: nil) {
                actions.chooseValue(field.id, token)
                collapseOtherEditors()
            }
        case .favorite(let label, let place):
            if let place {
                placeTextRow(label: label, detail: place.address) {
                    actions.choosePlace(field.id, place)
                    collapseOtherEditors()
                }
            } else {
                placeTextRow(label: label, detail: nil) {
                    actions.chooseValue(field.id, label)
                    collapseOtherEditors()
                }
            }
        case .candidate(let place):
            suggestionRow(field, place)
        }
    }

    /// 특수 행·즐겨찾기 행의 껍데기 — 후보 행(suggestionRow)과 같은 머리글·주소 문법이다. 한
    /// 목록 안에서 두 모양이면 고르는 법이 둘로 읽힌다. 즐겨찾기에 주소를 붙이는 이유: 라벨이
    /// 같은 즐겨찾기 둘을 가르는 건 주소뿐이다(후보 행과 같은 사정).
    private func placeTextRow(label: String, detail: String?,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout).foregroundStyle(Theme.ink)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: chipHeight)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail.map { "\(label), \($0)" } ?? label)
    }

    /// 후보 한 줄. 탭하면 그 순간 좌표까지 확정된다 — 확인 뒤에 실패할 자리가 사라진다.
    private func suggestionRow(_ field: EditField, _ place: Place) -> some View {
        Button {
            (actions.chooseCandidate ?? actions.choosePlace)(field.id, place)
            // 특수·즐겨찾기 행과 같은 정리 폭으로 맞춘다 — 행 종류에 따라 닫히는 폭이 다르면
            // 같은 목록 안에서 두 가지 닫기 법이 생긴다.
            collapseOtherEditors()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.callout).foregroundStyle(Theme.ink)
                // 같은 이름의 다른 지점을 가르는 건 주소뿐이다 — 이름만 보여주면 고르는 의미가 없다.
                if !place.address.isEmpty {
                    Text(place.address).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: chipHeight)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(place.address.isEmpty ? place.name : "\(place.name), \(place.address)")
    }

    /// 숫자 줄(여유·알림·반복)의 입력칸. 여기는 값을 그대로 확정하는 것이 맞다 — 확인 뒤에
    /// 실패할 외부 조회가 없다. 제목·장소 줄은 각자 항상 열려 있는 칸이라(S1) 이 에디터로
    /// 오지 않는다.
    @ViewBuilder
    private func textCustomEditor(_ field: EditField) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder(for: field), text: draftBinding(field))
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                // 숫자 줄은 숫자판이 편하지만 숫자판엔 완료 키가 없다 — 그래서 확인 버튼이 있다.
                .keyboardType(.numberPad)
                #endif
                .onSubmit { submitCustom(field) }
                // 제목 칸과 같은 까닭 — TextField가 탭을 삼켜 카드 전체 탭이 안 울리므로 같은 닫기 길로 보낸다.
                .simultaneousGesture(TapGesture().onEnded { collapseOtherEditorsAfterTap(except: field.id) })
            Button("OK") { submitCustom(field) }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.travelInk)
                .padding(.horizontal, 10)
                .frame(minHeight: chipHeight)
                .background(Theme.travelFill, in: Capsule())
        }
    }

    /// 장소 줄의 입력 바인딩. 묶음(디바운스)은 assistant가 한다 — 뷰가 타이머를 들면 카드가 다시
    /// 그려질 때마다 흩어져 글자마다 호출이 나간다(카카오 일일 할당량).
    private func placeQueryBinding(_ field: EditField) -> Binding<String> {
        Binding(
            get: { draft[field.id] ?? "" },
            set: { text in
                draft[field.id] = text
                rejected.remove(field.id)
                actions.searchPlaces(field.id, text)
            }
        )
    }

    private func draftBinding(_ field: EditField) -> Binding<String> {
        Binding(
            get: { draft[field.id] ?? "" },
            set: { text in
                draft[field.id] = text
                // 고쳐 쓰기 시작하면 거절 표시는 지운다 — 남아 있으면 지금 값이 거절된 것처럼 보인다.
                rejected.remove(field.id)
            }
        )
    }

    private func openCustom(_ field: EditField) {
        // 다른 줄의 에디터를 열면 펼쳐 있던 것들을 정리한다 — 시안: 다른 줄을 누르면 다시
        // 값 글자로 접힌다. 텍스트 직접입력 칩은 줄끼리 독립이라 여러 개가 함께 열려도 각자 자기
        // 일을 하지만, 다이얼 둘이 함께 서면 카드가 값을 두 곳에서 한꺼번에 바꾸는 것으로 읽힌다.
        collapseOtherEditors(except: field.id)
        draft[field.id] = typedLabel(field) == nil ? "" : (field.chosen ?? "")
        customOpen.insert(field.id)
        let now = Date()
        if field.kind == .datetime { dialOpenedAt[field.id] = now }
        // Commit the seed the wheel is about to show, so the card holds it without a turn; the wheel stays open.
        if card.commitsSeedWhenOpened(field) {
            actions.closeDial?(field.id, currentBasis(field), now)
        }
    }

    /// 다이얼이 서 있는 동안의 now — 열린 순간 잡은 값이 없으면(열림 길이 둘뿐이라 드문 폴백) 지금.
    private func dialNow(_ field: EditField) -> Date { dialOpenedAt[field.id] ?? Date() }

    /// 다른 줄의 에디터를 전부(또는 한 줄만 빼고) 정리한다 — 칩 탭·검색창 열기·장소 행 탭·카드의
    /// 빈 곳 탭이 모두 이 한 길로 온다. 시각 다이얼은 closeDial에 씨앗 확정을 맡긴 뒤 접는다
    /// (REQ-006 F1: 다이얼을 닫아도 씨앗이 확정된다 — 접는 것은 값을 버리는 게 아니라 보인
    /// 씨앗을 그대로 확정하는 일이다), 장소 목록은 closePlaceList로 닫는다(고르지 않고 닫으면
    /// 이전 값의 이름으로 돌아간다).
    private func collapseOtherEditors(except: UUID? = nil) {
        // 텍스트 칸의 포커스도 같이 놓는다 — 빈 곳·칩을 눌러도 키보드가 남으면 '반복' 칸이 끝나지 않아 해석이 안
        // 불리고 확인이 잠긴 채 남는다(바깥 탭이 곧 마침, REQ-004). 이미 비어 있으면 건드리지 않는다.
        if let focused = titleFocus, focused != except { titleFocus = nil }
        for f in card.fields where f.id != except {
            if f.kind == .datetime, customOpen.contains(f.id) {
                actions.closeDial?(f.id, currentBasis(f), dialNow(f))
                dialOpenedAt[f.id] = nil
                customOpen.remove(f.id)
            }
            if placeOpen.contains(f.id) {
                closePlaceList(f)
            }
        }
    }

    private func closeCustom(_ field: EditField) {
        customOpen.remove(field.id)
        rejected.remove(field.id)
    }

    /// 거절되면 입력창을 열어둔 채 표시만 남긴다 — 닫아버리면 무엇이 안 받아들여졌는지 사라진다.
    private func submitCustom(_ field: EditField) {
        if actions.submitCustom(field.id, draft[field.id] ?? "") {
            draft[field.id] = ""
            closeCustom(field)
        } else {
            rejected.insert(field.id)
        }
    }

    // MARK: 확인

    // 확인 문구가 nil이면 아예 그리지 않는다 — 소유 화면이 자기 제출 버튼을 갖고 있을 때
    // 둘이면 제출이 두 군데서 일어나는 것처럼 읽히기 때문이다.
    @ViewBuilder
    private var confirmButton: some View {
        if let confirmTitle = chrome.confirmTitle {
            VStack(alignment: .leading, spacing: 6) {
                Button { Task { await actions.confirm() } } label: {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        if busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(confirmTitle).font(.callout.weight(.semibold))
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(canConfirm ? Theme.bg : Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: chipHeight)
                    .background(canConfirm ? Theme.travel : Theme.bg,
                                in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius)
                            .stroke(canConfirm ? Color.clear : Theme.line)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canConfirm)
                // 해석 전만 남은 카드는 이미 누를 수 있어 "고르면 누를 수 있어요"가 거짓이 된다 — 그때는 힌트를 비운다.
                .accessibilityHint(card.isReady || card.isReadyAfterRecurrenceCommit
                                   ? "" : "Available once every missing value is chosen")

                // 남은 것 한 줄(SPEC-UIKIT-015) — 남은 줄이 없어도 "다 골랐어요"로 자리를 지킨다.
                // 줄이 생겼다 사라지면 확인 버튼이 상태마다 움직여 보인다(REQ-006). ViewThatFits이
                // 앞에서부터 폭에 맞는 변형을 고르므로 순서는 덜 줄인 것부터이다. 남은 변형 수는
                // remainingVariants의 길이뿐이라 첨자는 안전하다(최소 한 변형은 드라이버 T63-1·2가 단언).
                ViewThatFits(in: .horizontal) {
                    Text(card.remainingVariants[0])
                        .font(.caption).lineLimit(1)
                    // 빈 Text로 슬롯을 메우지 않는다 — 빈 문자열은 어떤 폭에도 맞아 아무것도 안
                    // 그리는 변형이 먼저 선택될 수 있다.
                    if card.remainingVariants.count > 1 {
                        Text(card.remainingVariants[1])
                            .font(.caption).lineLimit(1)
                    }
                    if card.remainingVariants.count > 2 {
                        Text(card.remainingVariants[2])
                            .font(.caption).lineLimit(1)
                    }
                }
                .foregroundStyle(card.isReady ? Theme.muted : Theme.ink)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(card.remainingVariants.first ?? "All set")
            }
        }
    }
}

// MARK: - Repeatable row groups (SPEC-GROUPFIELD-001)

/// One draw run of the card: a single field that belongs to no row group, or all adjacent fields that share one row of one.
/// The run's id is its first field's id, so a row keeps its view state while its fields keep their ids.
private struct FieldRun: Identifiable {
    let id: UUID
    let rowID: UUID?
    var fields: [EditField]

    /// Splits the card's fields into runs: a field with no rowID is a run of its own; adjacent fields with the same rowID one.
    static func of(_ fields: [EditField]) -> [FieldRun] {
        var runs: [FieldRun] = []
        for field in fields {
            if let rowID = field.rowID, let last = runs.indices.last, runs[last].rowID == rowID {
                runs[last].fields.append(field)
            } else {
                runs.append(FieldRun(id: field.id, rowID: field.rowID, fields: [field]))
            }
        }
        return runs
    }
}

/// The swipe-to-delete container of one row of a repeatable group: the row follows a leftwards drag only while the drag is
/// mostly horizontal (the horizontal distance more than twice the vertical); 80 points leftwards is the release threshold and
/// the offset clamp, never the follow gate. A trash symbol shows behind the row; VoiceOver deletes through the named action.
private struct SwipeRow<Content: View>: View {
    let rowID: UUID
    let actions: EditCardActions
    private let content: Content
    @State private var offset: CGFloat = 0

    init(rowID: UUID, actions: EditCardActions, @ViewBuilder content: () -> Content) {
        self.rowID = rowID
        self.actions = actions
        self.content = content()
    }

    var body: some View {
        ZStack {
            Image(systemName: "trash")
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            content
                .offset(x: offset)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 20)
            .onChanged { drag in offset = follows(drag) ? max(drag.translation.width, -80) : 0 }
            .onEnded { drag in
                if follows(drag), drag.translation.width <= -80 { actions.deleteRow?(rowID) }
                offset = 0
            })
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Delete row") { actions.deleteRow?(rowID) }
    }

    /// The dominance test of the swipe: a leftwards drag whose horizontal distance is more than twice its vertical distance.
    private func follows(_ drag: DragGesture.Value) -> Bool {
        drag.translation.width < 0 && abs(drag.translation.width) > 2 * abs(drag.translation.height)
    }
}

// MARK: - 시각 다이얼 부품(SPEC-UIKIT-016 S1, REQ-006·007)

/// 시각 줄의 다이얼 — 네이티브 DatePicker(.wheel). 확인 단추 없이 돌리는 즉시 값이다(O-A1):
/// selection의 set이 곧 확정 경로 호출이고, 거절된 위치는 get이 카드의 확정값을 계속 돌려주므로
/// 다음 렌더에서 저절로 직전 값으로 되돌아간다. 범위(in:)을 걸지 않는 이유: 거절은 확정 경로가
/// 담당하는데 범위를 걸면 돌리다 걸리는 위치가 생겨 '날짜 열은 하루씩 돌아가'(REQ-006)가 깨진다.
/// 이틀 넘는 종료도 달력 페이스 없이 날짜 열이 하루씩 돌아 담당한다(시안 "달력 없음"). 옛
/// EndTimeWheel(48행 시 열·달력 페이스·큰 글씨 단추 넷)을 지운 이유: 접근성 크기·VoiceOver를
/// 네이티브 다이얼이 시스템 차원에서 관리하고, 날짜 열을 일부러 안 쓰던 옛 결정을 이번에 뒤집었기
/// 때문이다(spec.md §1.5). 날짜 열 표기는 네이티브가 주는 것을 그대로 쓴다(O-A10 관측 지점).
private struct ValueDial: View {
    /// 반복 끝 시각 줄(REQ-007)은 날짜 열 없이 시각만 보인다 — 구분은 EndWheelSpec.capsAt24Hours,
    /// 그 깃발이 곧 '반복 카드의 끝 줄' 표지다(endSideRows가 만드는 세 줄만 true).
    let timeOnly: Bool
    /// 낭독 이름 — 줄 이름("시작"/"종료")을 따른다(P2). 한 카드에 다이얼이 둘 서도 VoiceOver가
    /// 어느 줄의 다이얼인지 가르도록 모든 줄에 같은 "날짜·시각"을 달지 않는다.
    let label: String
    /// 다이얼이 서는 자리 — 카드의 확정값(없으면 씨앗, EditCard.dialSeed). 초안 상태를 따로 들지
    /// 않는다: get이 확정값을 계속 돌려주는 것 자체가 '거절 위치는 받지 않는다'의 구현이다.
    let seed: Date
    /// 즉시 확정 경로 — 뷰는 부르기만 하고 거부 판정·직전 값 유지는 이 경로의 몫이다.
    let commit: (Date) -> Bool

    private var selection: Binding<Date> {
        Binding(
            get: { seed },
            set: { _ = commit($0) })
    }

    var body: some View {
        // 분 열의 1분 간격(REQ-006 '1분단위')은 인자가 아니라 기본값이 이미 담당한다 — iOS
        // SwiftUI의 DatePicker에는 minuteInterval을 받는 이니셜라이저가 없어(맥에만 있다) 그
        // 인자를 넘기면 빌드가 깨진다. 남은 플랫폼 차이는 휠 스타일 하나뿐이다.
        DatePicker(label, selection: selection,
                   displayedComponents: timeOnly ? .hourAndMinute : [.date, .hourAndMinute])
        #if os(iOS)
            .datePickerStyle(.wheel)
        #endif
            .labelsHidden()
    }
}

/// 묶음 머리글을 붙일지 묻는 뷰쪽 판정 보조 — 행 종류의 경계만 보고, 순서 자체는 PlaceLine.rows가
/// 이미 정했다(계약 5).
private extension PlaceLine.Row {
    var isFavorite: Bool { if case .favorite = self { return true }; return false }
    var isCandidate: Bool { if case .candidate = self { return true }; return false }
}

/// 흐려진 여유 줄에만 접근성 값을 붙이는 조건부 수정자 — 조건을 수정자 인자가 아니라 구조체로
/// 싼 이유는 오버로드 판정이다. 맨 글자 삼항(nil)은 LocalizedStringKey·Text 비선택 판정으로
/// 빌드가 깨져, "붙이거나 안 붙이거나"를 뷰 수준에서 갈라야 한다.
private struct BufferDimValue: ViewModifier {
    let dimmed: Bool
    func body(content: Content) -> some View {
        if dimmed {
            content.accessibilityValue(Text("This buffer isn't used for a departure-based event"))
        } else {
            content
        }
    }
}

/// 칩을 줄바꿈으로 흘려 넣는 배치.
///
/// 가로 스크롤을 쓰지 않는 이유: 화면 밖으로 밀린 칩은 **고를 수 없는 값**이고, 이 카드에서
/// 못 고른 값은 그대로 조용한 기본값이 된다. 반복 일정이면 줄이 다섯을 넘지만 카드는 길어져도
/// 되고, 스크롤은 채팅 쪽 ScrollView가 이미 맡고 있다.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// 배치와 크기 계산이 같은 함수를 쓴다 — 따로 세면 높이와 실제 줄 수가 어긋난다.
    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            // 칩 하나가 한 줄보다 넓어도 줄을 새로 열지 않는다 — 빈 줄만 생긴다.
            if !row.items.isEmpty, row.width + spacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width += row.items.isEmpty ? size.width : spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
