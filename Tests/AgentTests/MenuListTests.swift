import XCTest
@testable import besir

/// SPEC-MENULIST-001 (card t106): the words of a menu line, the arithmetic of the total, and the compile pin of the line
/// view's surface. The card model's own tests are in `AgentFieldCardTests` and the end-to-end ones in `AgentPartnerToolTests`.
@MainActor
final class MenuListTests: XCTestCase {
    func testMENULIST_T04_TheLineTextsAreTheOnesTheSpecNamesAndTheViewSurfaceCompiles() {
        XCTAssertEqual(MenuListText.add("Ramen"), "Add Ramen")
        XCTAssertEqual(MenuListText.add("Cheese pizza"), "Add Cheese pizza")
        XCTAssertEqual(MenuListText.described(name: "Ramen", price: "$14.00"), "Ramen, $14.00")
        XCTAssertEqual(MenuListText.described(name: "Ramen", price: nil), "Ramen")
        // A compile pin of the view's surface (green by design; the text assertions above are the red part on the skeleton):
        // a rename of the surface breaks the build before any walk can.
        _ = MenuListLine(name: "Ramen", price: "$14.00", value: nil,
                         rule: NumberStepperRule(bounds: NumberBounds(lowest: 1), allowsBlank: true), canAdd: true) { _ in }
        _ = MenuListLine(name: "Ramen", price: "$14.00", value: 3,
                         rule: NumberStepperRule(bounds: NumberBounds(lowest: 1), allowsBlank: true), canAdd: false) { _ in }
    }

    func testMENULIST_T05_TheTotalIsPriceTimesQuantityPlusTheFeeAndNeverTraps() {
        XCTAssertEqual(MenuListTotal.cents(lines: [], feeCents: 500), 0, "no line gives 0 even with a fee")
        XCTAssertEqual(MenuListTotal.cents(lines: [(1400, 2), (700, 1)], feeCents: 500), 4000)
        XCTAssertEqual(MenuListTotal.cents(lines: [(1400, 2), (700, 1)], feeCents: nil), 3500)
        XCTAssertEqual(AgentBudget.dollars(cents: 4000), "$40.00")
        XCTAssertEqual(MenuListTotal.cents(lines: [(1_000_000, 999_999_999)], feeCents: nil), 999_999_999_000_000)
        XCTAssertEqual(MenuListTotal.cents(lines: [(1_000_000, 999_999_999)], feeCents: 500), 999_999_999_000_500)
        // 20,000 such lines overflow Int; the sum stops at the largest Int and never traps.
        let absurd = Array(repeating: (1_000_000, 999_999_999), count: 20_000)
        XCTAssertEqual(MenuListTotal.cents(lines: absurd, feeCents: nil), Int.max)
        XCTAssertEqual(MenuListTotal.cents(lines: absurd, feeCents: 500), Int.max)
        // A sum of Int.max - 1 plus a fee of 500 stops at Int.max.
        XCTAssertEqual(MenuListTotal.cents(lines: [(1, Int.max - 1)], feeCents: nil), Int.max - 1)
        XCTAssertEqual(MenuListTotal.cents(lines: [(1, Int.max - 1)], feeCents: 500), Int.max)
    }
}
