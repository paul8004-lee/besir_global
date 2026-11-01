import Foundation
import Network

/// SPEC-PARTNEROFFLINE-001 (card t110): whether the device has a network path, behind a protocol so a test can replace it.

protocol NetworkReachability: AnyObject {
    /// True only while the device is known to have no network path.
    var isOffline: Bool { get }
}

/// The real probe.
final class PathReachability: NetworkReachability, @unchecked Sendable {
    static let shared = PathReachability()

    var isOffline: Bool { false }

    /// The rule: only `unsatisfied` is offline. Not reported yet (nil) and every other status are not.
    static func isOffline(_ status: NWPath.Status?) -> Bool {
        false
    }
}
