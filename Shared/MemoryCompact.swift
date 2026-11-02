import Foundation

// @MX:NOTE: [AUTO] The one reader of the count-line grammar that MemoryCounts writes (SPEC-MEMORY-004); it holds no list of kinds, keys or values.
extension MemoryCountLine {
    /// Reads one count line, or nil.
    init?(text: String) {
        return nil
    }
}

// @MX:NOTE: [AUTO] Pure: the item lines in, the item lines out. It reads no clock but `now`, touches no file and never reopens a count line.
/// The compaction of the item lines of `memory.md` that one append makes (SPEC-MEMORY-004).
struct MemoryCompaction {
    static let keepRaw = 30
    static let maxRaw = 60
    static let maxCounts = 40

    let now: Date
    let zone: TimeZone

    func compact(_ lines: [String]) -> [String] {
        lines
    }
}
