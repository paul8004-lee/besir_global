import Foundation

/// SPEC-PARTNEROFFLINE-001 (card t110): the rules of the partner buttons of be full sir. What is shown, when the directory is
/// asked, what a tap does. It holds no client and sends nothing: the load comes in as a closure, the network probe as a
/// protocol, the file as a `PartnerKeep`.
@MainActor
final class PartnerShelf: ObservableObject {
    /// The error line of one tapped row. `serial` tells two notices of the same row apart.
    struct Notice: Equatable {
        let rowID: String
        let text: String
        let serial: Int
    }

    static let noticeSeconds = 4
    static let offlineLine = BeRichSirModel.Problem.offline.line

    @Published private(set) var specs: [PartnerSpec] = []
    @Published private(set) var notice: Notice?

    init(keep: PartnerKeep = .shared, reachability: NetworkReachability = PathReachability.shared) {
    }

    /// Starts the load for an opened row when the rules allow one; nil when it started none.
    @discardableResult
    func rowOpened(load: @escaping @MainActor () async -> PartnerLoad) -> Task<Void, Never>? {
        nil
    }

    /// True: the caller opens the card. False: the error line was set instead.
    func tapped(_ spec: PartnerSpec, row: String) -> Bool {
        true
    }

    func rowClosed(_ rowID: String) {
    }

    func searchReplaced() {
    }

    func expire(_ notice: Notice) {
    }
}
