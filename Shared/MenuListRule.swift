import Foundation

/// SPEC-MENULIST-001 (card t106): the words of one line of a menu list and the arithmetic of its total. Foundation only:
/// no view, no card model, and no partner, partner id or field key.
enum MenuListText {
    /// The VoiceOver name of a line's round plus button.
    static func add(_ name: String) -> String { "Add \(name)" }

    /// The name of a line with, when it carries one, its price, as one accessibility element reads them.
    static func described(name: String, price: String?) -> String {
        price.map { "\(name), \($0)" } ?? name
    }
}

/// The total of an order: the sum over the ordered lines of price times count, plus the group's fee while at least one
/// line is ordered. The sum saturates at the largest Int and never traps (a price is at most a million cents and a count
/// of at most 999,999,999, so one line is at most 10^15 and only an absurd partner of many thousands of options can reach it).
enum MenuListTotal {
    static func cents(lines: [(priceCents: Int, count: Int)], feeCents: Int?) -> Int {
        guard !lines.isEmpty else { return 0 }
        var total = 0
        for line in lines {
            // One product is at most 10^15, so it cannot overflow; only the sum can.
            let (summed, overflow) = total.addingReportingOverflow(line.priceCents * line.count)
            if overflow { return Int.max }
            total = summed
        }
        if let feeCents {
            let (withFee, overflow) = total.addingReportingOverflow(feeCents)
            if overflow { return Int.max }
            total = withFee
        }
        return total
    }
}
