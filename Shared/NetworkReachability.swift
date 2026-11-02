import Foundation
import Network

/// SPEC-PARTNEROFFLINE-001 (card t110): whether the device has a network path, behind a protocol so a test can replace it.

protocol NetworkReachability: AnyObject {
    /// True only while the device is known to have no network path.
    var isOffline: Bool { get }
}

/// The real probe: one path monitor, started once for the app, whose latest status is kept under a lock.
final class PathReachability: NetworkReachability, @unchecked Sendable {
    static let shared = PathReachability()

    private let lock = NSLock()
    private var status: NWPath.Status?
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path.status) }
        monitor.start(queue: DispatchQueue(label: "besir.path-reachability"))
    }

    var isOffline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.isOffline(status)
    }

    private func update(_ newStatus: NWPath.Status) {
        lock.lock()
        status = newStatus
        lock.unlock()
    }

    /// The rule: only `unsatisfied` is offline. Not reported yet (nil) and every other status are not.
    static func isOffline(_ status: NWPath.Status?) -> Bool {
        status == .unsatisfied
    }
}
