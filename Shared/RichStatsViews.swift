import SwiftUI

// SPEC-RICHSTATS-001 (card t116): the Where, Trends and Entries tabs of the be rich sir screen, and the small parts the This week tab
// shares with them. Each tab takes a `RichStats` value and nothing else: money and dates arrive as ready-made text, the shapes are
// hand drawn from Theme tokens, and no part of this file is a control or starts a request.

/// The colours the stats screens share. Named ring slices take their colour by position, never by what they are called.
enum RichPalette {
    /// The colours of named ring slices, first to fourth.
    static let named: [Color] = [Theme.travel, Theme.activity, Theme.travelInk, Theme.activityInk]
    /// The lighter shade of the This week colour: estimates, under-budget weeks and the days that are not today.
    static let light = Theme.travel.opacity(0.5)

    /// The colour of the slice at `position` among the slices; the `Other` slice (flagged, always last) is always the faint grey.
    static func color(at position: Int, isOther: Bool) -> Color {
        isOther ? Theme.faint : named[position % named.count]
    }
}

// MARK: Shared parts

/// The tag of a row, `Stated` or `Estimate`, in its own pair of colours.
struct RichTag: View {
    let text: String

    var body: some View {
        let isEstimate = text == "Estimate"
        Text(text)
            .font(.caption)
            .foregroundStyle(isEstimate ? Theme.activityInk : Theme.travelInk)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isEstimate ? Theme.activityFill : Theme.travelFill)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Entries as rows, one amount and its tag each, with thin lines between.
struct RichRowList: View {
    let rows: [RichStats.Row]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.id) { row in
                HStack(alignment: .center, spacing: 12) {
                    Text(row.amountText)
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 12)
                    RichTag(text: row.tag)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
        }
        .overlay(alignment: .bottom) {
            if !rows.isEmpty { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

/// One tile: a small heading, a value and a line under it. The value may carry an arrow in front.
struct RichTile: View {
    let title: String
    let value: String
    let detail: String
    var valueColor: Color = Theme.ink
    var arrow: (name: String, label: String)?

    init(title: String, value: String, detail: String, valueColor: Color = Theme.ink, arrow: (name: String, label: String)? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
        self.valueColor = valueColor
        self.arrow = arrow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let arrow {
                    Image(systemName: arrow.name)
                        .font(.subheadline.weight(.bold))
                        .accessibilityLabel(arrow.label)
                }
                Text(value)
                    .font(.title2.weight(.bold))
            }
            .foregroundStyle(valueColor)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// A small square swatch and a word, the legend item of a bar or a chart.
struct RichLegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A horizontal line through the middle of its frame, for a dashed stroke.
private struct RichDashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// The two columns of tiles; a single tile takes the first column.
private let richTileColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

// MARK: Where

/// The Where tab: the week's amounts by kind as a ring, the days of the week as bars, and the top partners of eight weeks.
struct RichWhereTab: View {
    let stats: RichStats

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !stats.slices.isEmpty { ringSection }
            if let days = stats.days { daySection(days) }
            if !stats.partners.isEmpty { partnerSection }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The ring and its legend

    private var ringSection: some View {
        let total = stats.slices.reduce(0) { $0 + $1.cents }
        return HStack(alignment: .center, spacing: 20) {
            ZStack {
                RichRing(slices: stats.slices)
                VStack(spacing: 0) {
                    Text(RichStats.money(total))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("this week")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 24)
            }
            .frame(width: 136, height: 136)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stats.slices.map { $0.label + " " + RichStats.money($0.cents) }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(stats.slices.enumerated()), id: \.offset) { position, slice in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(RichPalette.color(at: position, isOther: slice.isOther))
                            .frame(width: 10, height: 10)
                        Text(slice.label)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        Text(RichStats.money(slice.cents))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // By day

    private func daySection(_ days: [RichStats.Day]) -> some View {
        let top = max(days.map(\.cents).max() ?? 0, 1)
        let spoken = days.indices.map { Self.weekdays[$0] + " " + RichStats.money(days[$0].cents) }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 10) {
            Text("By day")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            VStack(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(days.indices, id: \.self) { index in
                        let day = days[index]
                        if day.cents == 0 {
                            Rectangle().fill(Theme.line).frame(height: 2)
                        } else {
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                .fill(day.isToday ? Theme.travel : RichPalette.light)
                                .frame(height: max(2, 80 * Double(day.cents) / Double(top)))
                        }
                    }
                }
                .frame(height: 84, alignment: .bottom)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                HStack(spacing: 10) {
                    ForEach(days.indices, id: \.self) { index in
                        Text(days[index].letter)
                            .font(.caption2)
                            .fontWeight(days[index].isToday ? .semibold : .regular)
                            .foregroundStyle(days[index].isToday ? Theme.ink : Theme.muted)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
        }
    }

    // Top partners

    private var partnerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Top partners")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text("8 weeks")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(stats.partners, id: \.name) { partner in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(partner.name)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 8)
                            Text(RichStats.money(partner.cents))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.line)
                                Capsule()
                                    .fill(Theme.travel)
                                    .frame(width: geometry.size.width * partner.fraction)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .accessibilityElement(children: .combine)
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

/// The ring of the Where tab: each slice a trimmed circle stroke, from twelve o'clock, in the order of the slices.
private struct RichRing: View {
    let slices: [RichStats.Slice]

    var body: some View {
        let total = Double(max(slices.reduce(0) { $0 + $1.cents }, 1))
        ZStack {
            ForEach(Array(slices.enumerated()), id: \.offset) { position, slice in
                let before = Double(slices.prefix(position).reduce(0) { $0 + $1.cents })
                Circle()
                    .trim(from: before / total, to: (before + Double(slice.cents)) / total)
                    .stroke(RichPalette.color(at: position, isOther: slice.isOther), style: StrokeStyle(lineWidth: 18))
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(9)
    }
}

// MARK: Trends

/// The Trends tab: eight weekly bars against the budget, a legend, and a few plain statistics of the completed weeks.
struct RichTrendsTab: View {
    let stats: RichStats

    /// The height of the bars' area, and the room above it for the highest bar's total.
    private let barArea: CGFloat = 180
    private let labelRoom: CGFloat = 18

    /// The top of the scale: the larger of one and a quarter budgets and the highest week.
    private var scaleTop: Double {
        max(1.25 * Double(stats.budgetCents), Double(stats.weeks.map(\.cents).max() ?? 0), 1)
    }

    private func height(of cents: Int) -> CGFloat { barArea * CGFloat(Double(cents) / scaleTop) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let summary = stats.summary { headline(summary) }
            if !stats.weeks.isEmpty {
                chart
                legend
            }
            if let summary = stats.summary { tiles(summary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headline(_ summary: RichStats.Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 8 weeks")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(RichStats.money(summary.averageCents))
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.ink)
                Text("a week")
                    .font(.body)
                    .foregroundStyle(Theme.muted)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // The chart

    private var chart: some View {
        let spoken = stats.weeks.filter(\.hasBar).map { $0.label + " " + RichStats.money($0.cents) }.joined(separator: ", ")
        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: gutterSpacing) {
                gutterSizer
                    .frame(height: barArea + labelRoom, alignment: .bottom)
                    .overlay(alignment: .bottomTrailing) {
                        Text("Budget " + stats.budgetText)
                            .font(.caption2)
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(y: -height(of: stats.budgetCents) - 2)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text(stats.halfBudgetText)
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(y: -height(of: (stats.budgetCents + 1) / 2) - 2)
                    }
                Color.clear
                    .frame(height: barArea + labelRoom)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.line).frame(height: 1).offset(y: -height(of: (stats.budgetCents + 1) / 2))
                    }
                    .overlay(alignment: .bottom) {
                        RichDashedLine()
                            .stroke(Theme.muted, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .frame(height: 1.5)
                            .offset(y: -height(of: stats.budgetCents))
                    }
                    .overlay(alignment: .bottom) {
                        HStack(alignment: .bottom, spacing: 8) {
                            ForEach(stats.weeks, id: \.weekStart) { week in column(week) }
                        }
                    }
            }
            HStack(spacing: gutterSpacing) {
                gutterSizer
                HStack(spacing: 8) {
                    ForEach(stats.weeks, id: \.weekStart) { week in
                        Text(week.label)
                            .font(.caption2)
                            .fontWeight(week.isCurrent ? .semibold : .regular)
                            .foregroundStyle(week.isCurrent ? Theme.ink : Theme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// The gap between the label gutter and the plot.
    private let gutterSpacing: CGFloat = 4

    /// An invisible column as wide as the widest of the three label words at the current text size. It is the leading element of
    /// the plot row (the labels sit on it) and of the week-label row (so the weeks stay under their bars), so both rows get the
    /// same width without a fixed number of points.
    private var gutterSizer: some View {
        ZStack {
            Text("Budget")
            Text(stats.budgetText)
            Text(stats.halfBudgetText)
        }
        .font(.caption2)
        .lineLimit(1)
        .fixedSize()
        .hidden()
    }

    /// One week's column: its bar on the baseline, with the total above it for the current week and for a completed week over.
    @ViewBuilder
    private func column(_ week: RichStats.Week) -> some View {
        if week.hasBar {
            let showsTotal = week.isCurrent || week.isOver
            VStack(spacing: 2) {
                if showsTotal {
                    Text(RichStats.money(week.cents))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(week.isCurrent ? Theme.travelInk : Theme.warn)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                if week.cents == 0 {
                    Rectangle().fill(Theme.line).frame(height: 2)
                } else {
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                        .fill(week.isCurrent ? Theme.travel : (week.isOver ? Theme.warn : RichPalette.light))
                        .frame(height: height(of: week.cents))
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { legendItems }
            VStack(alignment: .leading, spacing: 6) { legendItems }
        }
        .font(.caption)
        .foregroundStyle(Theme.ink)
    }

    @ViewBuilder
    private var legendItems: some View {
        RichLegendItem(color: RichPalette.light, text: "Under")
        RichLegendItem(color: Theme.warn, text: "Over")
        RichLegendItem(color: Theme.travel, text: "This week")
    }

    // The tiles

    private func tiles(_ summary: RichStats.Summary) -> some View {
        LazyVGrid(columns: richTileColumns, spacing: 10) {
            RichTile(title: "Under budget", value: "\(summary.underCount) of \(summary.countedWeeks)", detail: "weeks")
            if let percent = summary.estimatePercent {
                RichTile(title: "Estimates", value: "\(percent)%", detail: "of spend")
            }
            RichTile(title: "Lowest week", value: RichStats.money(summary.lowest.cents), detail: summary.lowest.label,
                     valueColor: Theme.travelInk)
            RichTile(title: "Highest week", value: RichStats.money(summary.highest.cents), detail: summary.highest.label,
                     valueColor: summary.highest.cents > stats.budgetCents ? Theme.warn : Theme.ink)
        }
    }
}

// MARK: Entries

/// The Entries tab: every entry, grouped by week, newest week first; nothing at all for an empty ledger.
struct RichEntriesTab: View {
    let stats: RichStats

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(stats.groups, id: \.weekStart) { group in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(group.title)
                            .textCase(.uppercase)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        Text(group.totalText)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.vertical, 8)
                    RichRowList(rows: group.rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
