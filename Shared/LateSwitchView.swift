import SwiftUI

/// SPEC-LATESWITCH-001 (card t72): the part of the departure card that offers to switch a late booking to a delivery and then
/// shows what the switch did. It holds no rule: `LateSwitchCenter` reads, judges and runs the steps, and this view draws the state
/// the center keeps for the leg's entry and forwards the two calls, `check` and `confirm`.
struct LateSwitchSection: View {
    let event: ScheduledEvent
    /// The late result the departure card is drawing lines for; nil when it draws none or a result of another kind.
    let lateOutcome: ReplanOutcome?
    @EnvironmentObject private var store: Store
    @ObservedObject private var center = LateSwitchCenter.shared

    /// Changes with the entry or with the late result, which starts the read again.
    private struct ReadKey: Hashable {
        let activityID: UUID?
        let checkedAt: Date?
    }

    var body: some View {
        let activityID = event.linkedActivityId
        let state = activityID.flatMap { center.state(for: $0) }
        VStack(alignment: .leading, spacing: 10) {
            if let activityID, let state, LateSwitchCenter.shows(state: state, lateLines: lateOutcome != nil) {
                Divider()
                switch state {
                case .checking:
                    EmptyView()
                case .offer(let offer):
                    LateSwitchOffer(offer: offer, card: offer.card, center: center, activityID: activityID,
                                    showsOwnMark: LateSwitch.ownMark(mode: event.mode))
                case .running:
                    ProgressView()
                case .note(let text):
                    Text(verbatim: text)
                        .font(.callout).foregroundStyle(Theme.muted)
                case .finished(let result):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(.callout).foregroundStyle(Theme.ink)
                        }
                    }
                }
            }
        }
        .task(id: ReadKey(activityID: activityID, checkedAt: lateOutcome?.checkedAt)) {
            if let lateOutcome { await center.check(event: event, outcome: lateOutcome, store: store) }
        }
    }
}

/// The offer: the card the center built, the two lines under it recomputed from the card as it is now, and the button. The card is
/// observed here so that every change of a row redraws the lines and the button.
private struct LateSwitchOffer: View {
    let offer: LateSwitchCenter.Offer
    @ObservedObject var card: AgentFieldCard
    @ObservedObject var center: LateSwitchCenter
    let activityID: UUID
    let showsOwnMark: Bool

    init(offer: LateSwitchCenter.Offer, card: AgentFieldCard, center: LateSwitchCenter, activityID: UUID, showsOwnMark: Bool) {
        self.offer = offer
        self.card = card
        self.center = center
        self.activityID = activityID
        self.showsOwnMark = showsOwnMark
    }

    var body: some View {
        let evaluation = offer.evaluation
        VStack(alignment: .leading, spacing: 10) {
            EditCardView(card: card.card, busy: false, actions: card.actions,
                         chrome: EditCardChrome(header: card.header, confirmTitle: nil))
            if showsOwnMark {
                GoogleMapsAttribution()
            }
            if let estimates = evaluation.estimateLine, let standing = evaluation.standingLine {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: estimates)
                        .font(.callout).foregroundStyle(Theme.ink)
                    Text(verbatim: standing)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle((evaluation.leftAfterCents ?? 0) < 0 ? Theme.warn : Theme.ink)
                }
            }
            Button(LateSwitch.buttonTitle) { center.confirm(activityID: activityID) }
                .buttonStyle(.borderedProminent)
                .disabled(!center.canConfirm(activityID: activityID))
        }
    }
}
