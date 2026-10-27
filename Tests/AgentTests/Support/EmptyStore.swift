import Foundation
@testable import besir

/// Test helper: a Store that starts empty. It clears the throwaway data directory first and
/// refuses to touch any directory that is not inside the process temporary directory.
@MainActor
enum EmptyStore {
    static func make() -> Store {
        let dir = AppConfig.supportDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var tmp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        if !tmp.hasSuffix("/") { tmp += "/" }
        if dir.path.hasPrefix(tmp) {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return Store(notifications: NotificationManager())
    }
}
