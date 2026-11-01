import SwiftUI

/// The be rich sir screen (SPEC-RICHHAND-001). Skeleton of card t103 M1: it draws nothing until M4.
struct BeRichSirView: View {
    /// The icon of the record control.
    static let recordSymbol = "plus.circle.fill"

    let onBack: () -> Void

    init(onBack: @escaping () -> Void) {
        self.onBack = onBack
    }

    var body: some View {
        EmptyView()
    }
}
