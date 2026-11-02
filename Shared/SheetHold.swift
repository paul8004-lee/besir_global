import SwiftUI

/// Which sheets are open right now, so the automatic share pass waits while any of them is (SPEC-SHAREHOLD-001).
/// Every sheet's content carries holdsSharePass; a sheet without it is not waited for. The tracker keeps a set of ids,
/// not a count, so a content that appears twice under one id is still one open sheet.
@MainActor
final class SheetHold: ObservableObject {
    static let shared = SheetHold()
    /// The chat sheet's fixed id. Its content registers it on appear and never releases it on disappear: the chat sheet's
    /// dismissal handler releases it once the session has handled the dismissal.
    static let chatKey = UUID()

    @Published private(set) var isAnyOpen = false
    private var open: Set<UUID> = []

    init() {}

    func opened(_ id: UUID) {
        open.insert(id)
        if !isAnyOpen { isAnyOpen = true }
    }

    /// Answers true only when this close leaves no sheet open, which is the moment the pass may run again.
    @discardableResult
    func closed(_ id: UUID) -> Bool {
        guard open.remove(id) != nil, open.isEmpty else { return false }
        isAnyOpen = false
        return true
    }
}

extension View {
    /// Reports this sheet content to the shared tracker. With no key the content is open from appear to disappear;
    /// with a key it is open from appear until the key's owner releases it.
    func holdsSharePass(key: UUID? = nil) -> some View {
        modifier(HoldsSharePass(key: key))
    }
}

private struct HoldsSharePass: ViewModifier {
    let key: UUID?
    @State private var id = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if let key {
            content.onAppear { SheetHold.shared.opened(key) }
        } else {
            content
                .onAppear { SheetHold.shared.opened(id) }
                .onDisappear { SheetHold.shared.closed(id) }
        }
    }
}
