import SwiftUI

/// The be rich sir screen (SPEC-RICHHAND-001): the week's budget standing, an amount field with a record control, and the
/// week's entries. The model is built from the store's config when the screen appears, and an inner view observes it.
struct BeRichSirView: View {
    /// The icon of the record control.
    static let recordSymbol = "plus.circle.fill"

    @EnvironmentObject var store: Store

    let onBack: () -> Void

    @State private var model: BeRichSirModel?

    init(onBack: @escaping () -> Void) {
        self.onBack = onBack
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(AgentBudget.partnerLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.faint)
                    if let model {
                        BeRichSirContent(model: model)
                    }
                }
                .padding(20)
                // Room for the round besir AI button at the bottom right, so it does not cover the last row.
                .padding(.bottom, 56)
            }
            .background(Theme.bg)
            .navigationTitle("be rich sir")
            #if os(iOS)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { onBack() } label: { Label("Home", systemImage: "chevron.left") }
                }
            }
            .task {
                let current: BeRichSirModel
                if let model {
                    current = model
                } else {
                    current = BeRichSirModel(desk: BudgetDesk.live(config: store.config))
                    model = current
                }
                await current.appear()
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 640)
        #endif
    }
}

/// The figure, the amount row, the problem line and the list, drawn from the model it observes.
private struct BeRichSirContent: View {
    @ObservedObject var model: BeRichSirModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            standingRow
            amountRow
            if let problem = model.problem {
                Text(problem.line)
                    .foregroundStyle(Theme.warn)
            }
            ForEach(model.rows, id: \.requestID) { entry in
                Text(AgentBudget.entryText(entry))
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    @ViewBuilder
    private var standingRow: some View {
        if let standing = model.standing {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AgentBudget.standingWords(standing))
                    .font(.title2)
                    .foregroundStyle(Theme.ink)
                if standing.includesEstimate {
                    Text("Estimate")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
        } else if model.isBusy {
            ProgressView()
        }
    }

    private var amountRow: some View {
        HStack(spacing: 12) {
            TextField("Amount", text: $model.amountText)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await model.record() }
            } label: {
                Image(systemName: BeRichSirView.recordSymbol)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
            .accessibilityLabel("Record spend")
            .disabled(model.isBusy || model.amountText.isEmpty)
        }
    }
}
