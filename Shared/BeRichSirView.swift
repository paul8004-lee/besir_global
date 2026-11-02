import SwiftUI

/// The be rich sir screen (SPEC-RICHHAND-001, SPEC-RICHSTATS-001): the week's standing, an amount field with a record control and
/// the latest entries on the first tab, and three read-only tabs drawn from the ledger. The model is built from the store's config
/// when the screen appears, and an inner view observes it.
struct BeRichSirView: View {
    /// The icon of the record control.
    static let recordSymbol = "plus.circle.fill"

    /// The four tabs, in order. `where` is a Swift keyword, hence `spending`.
    enum Tab: CaseIterable {
        case thisWeek, spending, trends, entries
    }

    @EnvironmentObject var store: Store

    let onBack: () -> Void

    @State private var model: BeRichSirModel?
    /// The selected tab lives in memory only while the screen is shown.
    @State private var tab: Tab = .thisWeek

    init(onBack: @escaping () -> Void) {
        self.onBack = onBack
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("This week").tag(Tab.thisWeek)
                    Text("Where").tag(Tab.spending)
                    Text("Trends").tag(Tab.trends)
                    Text("Entries").tag(Tab.entries)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let model {
                            BeRichSirContent(model: model, tab: tab)
                        }
                    }
                    .padding(20)
                    // Room for the round besir AI button at the bottom right, so it does not cover the last row.
                    .padding(.bottom, 56)
                }
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
                ToolbarItem(placement: .primaryAction) {
                    Text("Simulated")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
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

/// The selected tab, drawn from the model it observes. The first tab holds the figure and the controls; the others take the stats.
private struct BeRichSirContent: View {
    @ObservedObject var model: BeRichSirModel
    let tab: BeRichSirView.Tab

    var body: some View {
        switch tab {
        case .thisWeek: thisWeek
        case .spending: RichWhereTab(stats: model.stats)
        case .trends: RichTrendsTab(stats: model.stats)
        case .entries: RichEntriesTab(stats: model.stats)
        }
    }

    // MARK: This week

    private var thisWeek: some View {
        VStack(alignment: .leading, spacing: 20) {
            heroSection
            tiles
            amountRow
            if let problem = model.problem {
                Text(problem.line)
                    .foregroundStyle(Theme.warn)
            }
            latest
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var heroSection: some View {
        let stats = model.stats
        let hero = RichStats.hero(standing: model.standing, isBusy: model.isBusy)
        VStack(alignment: .leading, spacing: 10) {
            Text(stats.weekTitle)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            switch hero {
            case .figure(let amountText, let word, let spentLine, let isOver):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(amountText)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.ink)
                    Text(word)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isOver ? Theme.warn : Theme.travel)
                }
                .accessibilityElement(children: .combine)
                Text(spentLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                BudgetBar(statedCents: stats.statedCents, estimateCents: stats.estimateCents,
                          budgetCents: stats.budgetCents, isFull: isOver)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { legendItems(stats) }
                    VStack(alignment: .leading, spacing: 6) { legendItems(stats) }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
            case .busy:
                ProgressView()
            case .none:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func legendItems(_ stats: RichStats) -> some View {
        RichLegendItem(color: Theme.travel, text: "Stated " + RichStats.money(stats.statedCents))
        RichLegendItem(color: RichPalette.light, text: "Estimate " + RichStats.money(stats.estimateCents))
    }

    private var tiles: some View {
        let stats = model.stats
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            if let versus = stats.versus {
                RichTile(title: "vs last week", value: RichStats.money(versus.differenceCents),
                         detail: "Last week " + RichStats.money(versus.lastWeekCents),
                         valueColor: versus.direction == .down ? Theme.travel : Theme.ink,
                         arrow: arrow(versus.direction))
            }
            RichTile(title: "Records", value: "\(stats.recordCount)", detail: stats.estimatesText)
        }
    }

    private func arrow(_ direction: RichStats.Direction) -> (name: String, label: String)? {
        switch direction {
        case .down: return ("arrow.down", "Down")
        case .up: return ("arrow.up", "Up")
        case .same: return nil
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

    @ViewBuilder
    private var latest: some View {
        if !model.stats.latest.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                RichRowList(rows: model.stats.latest)
            }
        }
    }
}

/// The week's stated and estimated amounts against the budget; full to the end while the week is over it.
private struct BudgetBar: View {
    let statedCents: Int
    let estimateCents: Int
    let budgetCents: Int
    let isFull: Bool

    /// The stated and estimate shares of the bar's width.
    private var shares: (stated: Double, estimate: Double) {
        let sum = statedCents + estimateCents
        if isFull {
            return sum > 0 ? (Double(statedCents) / Double(sum), Double(estimateCents) / Double(sum)) : (1, 0)
        }
        let stated = min(1, Double(statedCents) / Double(max(budgetCents, 1)))
        let estimate = min(1 - stated, Double(estimateCents) / Double(max(budgetCents, 1)))
        return (stated, estimate)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.travel).frame(width: geometry.size.width * shares.stated)
                    Rectangle().fill(RichPalette.light).frame(width: geometry.size.width * shares.estimate)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(Capsule())
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}
