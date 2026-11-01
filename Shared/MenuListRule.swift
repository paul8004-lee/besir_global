import Foundation

/// SPEC-MENULIST-001 (card t106): the words of one line of a menu list and the arithmetic of its total. Foundation only:
/// no view, no card model, and no partner, partner id or field key. This is the M1 skeleton: every body is inert until M3
/// gives it the real one, so the priced test stubs keep the existing delivery tests green while the new tests fail by
/// assertion.
enum MenuListText {
    /// The VoiceOver name of a line's round plus button.
    static func add(_ name: String) -> String { "" }

    /// The name of a line with, when it carries one, its price, as one accessibility element reads them.
    static func described(name: String, price: String?) -> String { "" }
}

/// The total of an order: the sum over the ordered lines of price times quantity, plus the group's fee while at least one
/// line is ordered. The sum saturates at the largest Int and never traps (a price is at most a million cents and a quantity
/// at most 999,999,999, so one line is at most 10^15 and only an absurd partner of many thousands of options can reach it).
enum MenuListTotal {
    static func cents(lines: [(priceCents: Int, quantity: Int)], feeCents: Int?) -> Int { 0 }
}
