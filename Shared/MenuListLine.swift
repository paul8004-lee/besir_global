import SwiftUI

/// SPEC-MENULIST-001 (card t106): one line of a menu list — the item's name and, when priced, its price on the left, and on
/// the right a round plus button while the line's count is blank or the stepper of SPEC-NUMSTEPPER-001 once it holds one.
/// Every word is `MenuListText`'s and every decision is the rule's; this file only draws, and the name and the price are the
/// model's data, drawn verbatim.
struct MenuListLine: View {
    let name: String
    let price: String?
    let value: Int?
    let rule: NumberStepperRule
    let canAdd: Bool
    let onChange: (Int?) -> Void

    #if os(iOS)
    @ScaledMetric(relativeTo: .callout) private var height: CGFloat = 44
    #else
    @ScaledMetric(relativeTo: .callout) private var height: CGFloat = 28
    #endif

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.callout)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let price {
                    Text(verbatim: price)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MenuListText.described(name: name, price: price))
            Spacer(minLength: 8)
            control
                .fixedSize()
        }
    }

    /// The line's control: the stepper once the line holds a count, a round plus button while it is blank. Both sit in a
    /// frame of the stepper's own height, so the line does not move when one turns into the other (REQ-006).
    @ViewBuilder
    private var control: some View {
        if let value {
            NumberStepper(name: name, value: value, rule: rule, onChange: onChange)
        } else {
            Button {
                onChange(rule.increased(from: nil))
            } label: {
                ZStack {
                    Circle().stroke(Theme.line)
                    Image(systemName: "plus")
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                }
                .frame(width: height, height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel(MenuListText.add(name))
        }
    }
}
