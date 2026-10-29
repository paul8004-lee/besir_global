import SwiftUI
#if os(iOS)
import UIKit
#endif

// SPEC-AGENT-002 (M4a): the chat sheet. Text is drawn with Text(verbatim:) so nothing the model or a title says is
// read as markup or turned into a link. The only fixed texts are the control labels and the field's placeholder.

/// Holds the chat session by reference. The sheet closures of RootView are built from a copy of that view, and a plain
/// @State optional read there came out nil, which showed a blank sheet; the holder is one object in every copy.
@MainActor
final class AgentChatHolder {
    var session: AgentSession?
}

struct AgentChatView: View {
    @ObservedObject var session: AgentSession
    @State private var draft = ""

    private static let bottomID = "chat-bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            messages
            Divider().overlay(Theme.line)
            composer
        }
        .background(Theme.bg)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Button("New chat") {
                Task { await session.newChat() }
            }
            Spacer()
            #if DEBUG
            debugTranscriptButton
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.chatEntries) { entry in
                        row(entry)
                    }
                    if session.isWaiting || session.isResolving {
                        ProgressView()
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(16)
            }
            // Scroll without animation: with an animated scrollTo, sending a multi-line message into a conversation
            // that already overflows left the main thread in one layout pass that never ended (card t34).
            .onChange(of: session.entries.count) { _, _ in
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: session.isWaiting) { _, _ in
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: AgentLogEntry) -> some View {
        switch entry.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(verbatim: text)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
            }
        case .assistant(let text):
            HStack {
                Text(verbatim: text)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                Spacer(minLength: 40)
            }
        case .card(let card):
            if let fieldCard = card.fieldCard {
                AgentFieldCardContent(session: session, card: card, fieldCard: fieldCard, pending: session.pendingCard === card)
            } else {
                cardView(card)
            }
        case .notice(let line):
            Text(verbatim: line)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        case .error(let line):
            Text(verbatim: line)
                .font(.footnote)
                .foregroundStyle(Theme.warn)
        case .tool, .result:
            EmptyView()
        case .attribution:
            GoogleMapsAttribution()
        }
    }

    private func cardView(_ card: AgentCard) -> some View {
        let pending = session.pendingCard === card
        return VStack(alignment: .leading, spacing: 6) {
            AgentCardRows(card: card, editors: card.editors, pending: pending, locked: session.isResolving)
            if card.showsGoogleMark {
                GoogleMapsAttribution()
            }
            if pending {
                AgentCardActions(session: session, card: card, editors: card.editors)
            } else if let mark = card.mark {
                Text(verbatim: mark.rawValue)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .disabled(!session.canSend)
            Button("Send", action: sendDraft)
                .disabled(!session.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sendDraft() {
        guard session.canSend, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.send(draft)
        draft = ""
    }
}

/// The rows of a card. While the card waits, the rows of its editable values are controls bound to the card's editors (SPEC-DELIVERY-001);
/// the labels are the fixed words of `AgentDelivery`. It observes the editors because `cardView(_:)` observes only the session.
private struct AgentCardRows: View {
    let card: AgentCard
    @ObservedObject var editors: AgentCardEditors
    let pending: Bool
    /// True while the session applies the card: no control takes an edit then.
    let locked: Bool

    var body: some View {
        ForEach(Array(card.rows.enumerated()), id: \.offset) { index, row in
            switch row {
            case .text(let line):
                lineView(line, index)
            case .delivery(let line, let mark):
                if pending, let delivery = editors.delivery {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(AgentDelivery.deliveryPlaceLabel, text: binding(delivery))
                            .textFieldStyle(.roundedBorder)
                        markView(mark)
                    }
                    .disabled(locked)
                } else {
                    lineView(line, index)
                }
            case .meal(let line, let mark):
                if pending, let on = editors.mealOn {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: Binding(get: { on.isOn }, set: { on.isOn = $0 })) {
                            Text(verbatim: AgentDelivery.mealSwitchLabel)
                        }
                        if on.isOn, let title = editors.mealTitle, let start = editors.mealStart {
                            TextField(AgentDelivery.mealTitleLabel, text: binding(title))
                                .textFieldStyle(.roundedBorder)
                            DatePicker(AgentDelivery.mealStartLabel, selection: Binding(get: { start.start }, set: { start.start = $0 }),
                                       displayedComponents: .hourAndMinute)
                                .environment(\.calendar, start.calendar)
                                .environment(\.timeZone, start.calendar.timeZone)
                            markView(mark)
                        }
                    }
                    .disabled(locked)
                } else if let line {
                    lineView(line, index)
                }
            }
        }
    }

    private func binding(_ field: AgentCardText) -> Binding<String> {
        Binding(get: { field.text }, set: { field.text = $0 })
    }

    private func lineView(_ line: String, _ index: Int) -> some View {
        Text(verbatim: line)
            .font(index == 0 ? .headline : .body)
            .foregroundStyle(Theme.ink)
    }

    /// The mark a line holds (`(suggested ...)`), drawn beside its control.
    @ViewBuilder
    private func markView(_ mark: String) -> some View {
        let text = mark.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
    }
}

/// SPEC-CHOICECARD-001: a card drawn from a partner's field list. While it waits, the edit card draws it (its own background and
/// border, built once by the model and never rebuilt here, as `AddActivityView` rules for its card); the chat's Confirm and Cancel
/// sit below it. Once resolved, the lines the model holds are drawn as plain text inside the chat's own border. It observes the
/// model because `row(_:)` observes only the session.
private struct AgentFieldCardContent: View {
    @ObservedObject var session: AgentSession
    let card: AgentCard
    @ObservedObject var fieldCard: AgentFieldCard
    let pending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if pending {
                EditCardView(card: fieldCard.card, busy: session.isResolving, actions: fieldCard.actions,
                             chrome: EditCardChrome(header: fieldCard.header, confirmTitle: nil))
            } else {
                ForEach(Array(fieldCard.lines.enumerated()), id: \.offset) { index, line in
                    Text(verbatim: line)
                        .font(index == 0 ? .headline : .body)
                        .foregroundStyle(Theme.ink)
                }
            }
            if card.showsGoogleMark {
                GoogleMapsAttribution()
            }
            if pending {
                AgentCardActions(session: session, card: card, editors: card.editors, fieldReady: fieldCard.isReady)
            } else if let mark = card.mark {
                Text(verbatim: mark.rawValue)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(pending ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(pending ? Color.clear : Theme.line))
    }
}

/// Confirm and Cancel of a pending card. Confirm is disabled while an edited value is blank; both are disabled while the session
/// applies the card.
private struct AgentCardActions: View {
    @ObservedObject var session: AgentSession
    let card: AgentCard
    @ObservedObject var editors: AgentCardEditors
    /// The readiness of a field card, passed as a value so that a change redraws the buttons; the other forms leave it true.
    var fieldReady = true

    var body: some View {
        HStack(spacing: 12) {
            Button("Confirm") { Task { await session.confirmCard() } }
                .buttonStyle(.borderedProminent)
                .disabled(!(fieldReady && card.canConfirm))
            Button("Cancel") { Task { await session.cancelCard() } }
                .buttonStyle(.bordered)
        }
        .disabled(session.isResolving)
    }
}

#if DEBUG
extension AgentChatView {
    /// Debug builds only. The identifier keeps the string in the Debug product and lets the Release scan prove it absent there.
    static let transcriptMarker = "BESIR_DEBUG_TRANSCRIPT_MARKER"

    var debugTranscriptButton: some View {
        Button("Copy transcript") {
            #if os(iOS)
            UIPasteboard.general.string = session.transcript()
            #endif
        }
        .accessibilityIdentifier(Self.transcriptMarker)
    }
}
#endif
