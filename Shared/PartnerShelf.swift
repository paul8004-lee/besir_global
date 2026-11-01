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

    /// The list shown: the kept list until a load succeeds, then that load's partners.
    @Published private(set) var specs: [PartnerSpec]
    @Published private(set) var notice: Notice?

    private let keep: PartnerKeep
    private let reachability: NetworkReachability
    /// A load is running. Set before the load starts, so two row opens in quick succession start one.
    private var inFlight = false
    /// A load on this screen ended successful or failed; only an offline load leaves the screen free to ask again.
    private var settled = false
    private var serial = 0

    init(keep: PartnerKeep = .shared, reachability: NetworkReachability = PathReachability.shared) {
        self.keep = keep
        self.reachability = reachability
        self.specs = keep.read() ?? []
    }

    /// Starts the load for an opened row when the rules allow one; nil when it started none.
    @discardableResult
    func rowOpened(load: @escaping @MainActor () async -> PartnerLoad) -> Task<Void, Never>? {
        guard !inFlight, !settled else { return nil }
        inFlight = true
        return Task { [weak self] in
            let result = await load()
            self?.finished(result)
        }
    }

    /// True: the caller opens the card. False: the device is offline, no card opens and the error line is set instead.
    func tapped(_ spec: PartnerSpec, row: String) -> Bool {
        guard reachability.isOffline else {
            notice = nil
            return true
        }
        serial += 1
        notice = Notice(rowID: row, text: Self.offlineLine, serial: serial)
        return false
    }

    func rowClosed(_ rowID: String) {
        if notice?.rowID == rowID { notice = nil }
    }

    func searchReplaced() {
        notice = nil
    }

    /// Removes `notice` if it is still the one shown; a newer notice of the same row stays.
    func expire(_ notice: Notice) {
        if self.notice == notice { self.notice = nil }
    }

    /// Only a successful load replaces the list shown and the file; an offline or failed load changes neither.
    private func finished(_ result: PartnerLoad) {
        inFlight = false
        switch result.outcome {
        case .loaded:
            settled = true
            specs = result.specs
            keep.save(result.raw)
        case .failed:
            settled = true
        case .offline:
            break
        }
    }
}
