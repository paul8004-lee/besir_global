import Foundation

/// SPEC-PARTNEROFFLINE-001 (card t110): the last successful load of the partner directory, kept on the device. Foundation only.
/// The file holds the raw answers the partners sent, never a description of a partner, so `PartnerEntry.list` and
/// `PartnerSpec.form` stay the one grammar: a kept answer is checked again by the app version that reads it.

/// The answers a load accepted, as bytes: the directory and each good form by its entry id. This is also the file's content.
struct PartnerRaw: Codable, Equatable {
    var directory: Data
    var forms: [String: Data]
}

/// What one load of the directory and its forms came to.
struct PartnerLoad {
    enum Outcome: Equatable {
        /// The directory answered and passed its reader, no request failed offline, and at least one form is good.
        case loaded
        /// Any request of the load failed with the offline transport error.
        case offline
        /// Every other load.
        case failed
    }

    let outcome: Outcome
    /// The partners whose form was good in this load, whatever the outcome, in the directory's order.
    let specs: [PartnerSpec]
    let raw: PartnerRaw
}

/// The file in the support folder. It never throws: a failed write is swallowed and a file that does not read is "never loaded".
struct PartnerKeep {
    static let fileName = "partner-directory.json"

    private let fileURL: URL
    private let write: @Sendable (Data, URL) throws -> Void

    init(fileURL: URL, write: @escaping @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite) {
        self.fileURL = fileURL
        self.write = write
    }

    static var defaultURL: URL { AppConfig.supportDirectory.appendingPathComponent(fileName) }

    /// The keep the app uses. Under tests `AppConfig.supportDirectory` is a throw-away folder.
    static let shared = PartnerKeep(fileURL: PartnerKeep.defaultURL)

    /// The kept partners, or nil for "never loaded".
    func read() -> [PartnerSpec]? {
        nil
    }

    /// Replaces the file with `raw`.
    func save(_ raw: PartnerRaw) {
    }
}
