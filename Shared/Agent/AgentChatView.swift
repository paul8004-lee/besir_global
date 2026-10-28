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
            cardView(card)
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
            ForEach(Array(card.lines.enumerated()), id: \.offset) { index, line in
                Text(verbatim: line)
                    .font(index == 0 ? .headline : .body)
                    .foregroundStyle(Theme.ink)
            }
            if card.showsGoogleMark {
                GoogleMapsAttribution()
            }
            if pending {
                HStack(spacing: 12) {
                    Button("Confirm") { Task { await session.confirmCard() } }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { Task { await session.cancelCard() } }
                        .buttonStyle(.bordered)
                }
                .disabled(session.isResolving)
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
