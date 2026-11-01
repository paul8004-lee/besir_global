import SwiftUI

/// SPEC-NUMSTEPPER-001 (card t107): the minus/plus box and its row. The skeleton draws nothing yet.

/// The box alone: a minus button, the number and a plus button.
struct NumberStepper: View {
    let name: String
    let value: Int?
    let rule: NumberStepperRule
    let onChange: (Int?) -> Void

    var body: some View { EmptyView() }
}

/// The box with the field's label on the left.
struct NumberStepperRow: View {
    let label: String
    let value: Int?
    let rule: NumberStepperRule
    let onChange: (Int?) -> Void

    var body: some View { EmptyView() }
}
