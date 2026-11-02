import SwiftUI

/// Which sheets are open right now, so the automatic share pass can wait while any of them is (SPEC-SHAREHOLD-001).
/// Every sheet's content carries holdsSharePass. Skeleton (M1): it records nothing yet.
@MainActor
final class SheetHold: ObservableObject {
    static let shared = SheetHold()
    /// The chat sheet's fixed id: its owner releases it after the chat's dismissal has been handled.
    static let chatKey = UUID()

    @Published private(set) var isAnyOpen = false

    init() {}

    func opened(_ id: UUID) {}

    @discardableResult
    func closed(_ id: UUID) -> Bool { false }
}

extension View {
    /// Reports this sheet content to the shared tracker. Skeleton (M1): it returns the view unchanged.
    func holdsSharePass(key: UUID? = nil) -> some View { self }
}
