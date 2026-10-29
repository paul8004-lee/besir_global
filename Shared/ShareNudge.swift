import Foundation
import UserNotifications

/// The share extension cannot open besir (Apple: "App extensions are not allowed to open URLs directly"), so after a share it
/// rings one fixed doorbell: a local notification whose tap brings besir to the front, where the queue is imported as always.
// @MX:NOTE A notification and not an open: Apple allows an extension to open its app only from Today and iMessage, and names a local notification as the way to get the user's attention.
enum ShareNudge {
    static let identifier = "besir.share.nudge"
    static let title = "besir"
    static let body = "Tap to review what you shared."

    enum Outcome: Equatable { case posted, skipped, failed }

    /// Takes nothing from the share, on purpose: the banner can appear on a lock screen.
    static func request() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    static func post(stored: Bool, center: NudgeCenter) async -> Outcome {
        guard stored else { return .skipped }
        do { try await center.add(request()); return .posted } catch { return .failed }
    }

    static func clear(center: NudgeCenter) {
        center.removeDelivered(withIdentifiers: [identifier])
    }
}

protocol NudgeCenter {
    func add(_ request: UNNotificationRequest) async throws
    func removeDelivered(withIdentifiers identifiers: [String])
}

/// The real center. Without a bundle identifier (a bare test runner) `UNUserNotificationCenter.current()` crashes, as the guard in
/// `NotificationManager.center` notes, so each method does nothing in that case.
struct SystemNudgeCenter: NudgeCenter {
    func add(_ request: UNNotificationRequest) async throws {
        guard Bundle.main.bundleIdentifier != nil else { return }
        try await UNUserNotificationCenter.current().add(request)
    }

    func removeDelivered(withIdentifiers identifiers: [String]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
