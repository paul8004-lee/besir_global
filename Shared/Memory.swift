import Foundation

/// One `key=value` field of a memory line.
struct MemoryField: Equatable {
    let key: String
    let value: String
}

/// One line of `memory.md` (SPEC-MEMORY-001). Skeleton: no behavior yet.
struct MemoryLine: Equatable {
    static let maxRawLines = 200
    static let maxTextScalars = 60
    static let maxFields = 4
    static let maxLineScalars = 460

    let date: String
    let weekday: String
    let time: String
    let kind: String
    let place: String
    let fields: [MemoryField]

    static func make(kind: String, at date: Date, zone: TimeZone, place: String?, fields: [(String, String)]) -> MemoryLine? {
        nil
    }

    var text: String { "" }

    init?(text: String) {
        return nil
    }

    static func clean(_ text: String) -> String? {
        nil
    }

    static func display(_ line: String) -> String {
        ""
    }
}

/// The file `memory.md` in the app's support folder. Skeleton: no behavior yet.
struct MemoryBook {
    static let fileName = "memory.md"

    let fileURL: URL
    private let write: @Sendable (Data, URL) throws -> Void

    init(fileURL: URL, write: @escaping @Sendable (Data, URL) throws -> Void = ConnectionLog.defaultWrite) {
        self.fileURL = fileURL
        self.write = write
    }

    static func app() -> MemoryBook {
        MemoryBook(fileURL: AppConfig.supportDirectory.appendingPathComponent(fileName))
    }

    func lines() -> [String] { [] }

    func appending(_ line: MemoryLine) -> [String]? { nil }

    func removing(at index: Int) -> [String]? { nil }

    func removingAll() -> [String]? { nil }
}
