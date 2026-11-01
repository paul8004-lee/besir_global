import SwiftUI

/// SPEC-MENULIST-001 (card t106): one line of a menu list — the item's name and, when priced, its price on the left, and on
/// the right a round plus button while the quantity is blank or the stepper of SPEC-NUMSTEPPER-001 once it holds one. Every
/// word is `MenuListText`'s and every decision is the rule's; this file only draws. This is the M1 skeleton: the body is
/// empty until M4 fills it, so the surface this struct pins stays stable while the model is built.
struct MenuListLine: View {
    let name: String
    let price: String?
    let value: Int?
    let rule: NumberStepperRule
    let canAdd: Bool
    let onChange: (Int?) -> Void

    var body: some View { EmptyView() }
}
