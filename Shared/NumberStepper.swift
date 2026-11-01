import SwiftUI

/// SPEC-NUMSTEPPER-001 (card t107): the minus/plus box and its row. Every decision (what is dimmed, what a tap writes) is the
/// rule's, and every word is `NumberStepperText`'s; this file only draws. It names no partner, no partner id and no field key.

/// The box alone: a minus button, the number and a plus button inside one rounded border.
struct NumberStepper: View {
    let name: String
    let value: Int?
    let rule: NumberStepperRule
    let onChange: (Int?) -> Void

    #if os(iOS)
    @ScaledMetric(relativeTo: .callout) private var height: CGFloat = 44
    #else
    @ScaledMetric(relativeTo: .callout) private var height: CGFloat = 28
    #endif

    init(name: String, value: Int?, rule: NumberStepperRule, onChange: @escaping (Int?) -> Void) {
        self.name = name
        self.value = value
        self.rule = rule
        self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", on: rule.canDecrease(from: value)) { onChange(rule.decreased(from: value)) }
                .disabled(!rule.canDecrease(from: value))
                .accessibilityLabel(NumberStepperText.decrease(name))
            Text(NumberStepperText.shown(value))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.ink)
                .frame(minWidth: height)
                .accessibilityLabel(name)
                .accessibilityValue(NumberStepperText.spoken(value))
            stepButton("plus", on: rule.canIncrease(from: value)) { onChange(rule.increased(from: value)) }
                .disabled(!rule.canIncrease(from: value))
                .accessibilityLabel(NumberStepperText.increase(name))
        }
        .frame(height: height)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
        .accessibilityElement(children: .contain)
    }

    /// One symbol button; a button the rule does not allow is drawn in the faint ink.
    private func stepButton(_ symbol: String, on enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(enabled ? Theme.ink : Theme.faint)
                .frame(width: height, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The box with the field's label on the left. A long label wraps and the row grows; the box keeps its size.
struct NumberStepperRow: View {
    let label: String
    let value: Int?
    let rule: NumberStepperRule
    let onChange: (Int?) -> Void

    init(label: String, value: Int?, rule: NumberStepperRule, onChange: @escaping (Int?) -> Void) {
        self.label = label
        self.value = value
        self.rule = rule
        self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            NumberStepper(name: label, value: value, rule: rule, onChange: onChange)
                .fixedSize()
        }
    }
}
