import XCTest
@testable import besir

/// SPEC-NUMSTEPPER-001 (card t107) T01 to T06: the pure rule of the minus/plus stepper and its texts. No view, no card model.
@MainActor
final class NumberStepperTests: XCTestCase {
    private let open = NumberStepperRule(bounds: NumberBounds(lowest: 1))

    func testNUMSTEP_T01_TheRuleStopsAtTheLowestAndNeverDimsAbove() {
        XCTAssertEqual(open.increased(from: 5), 6)
        XCTAssertEqual(open.decreased(from: 5), 4)
        XCTAssertFalse(open.canDecrease(from: 1))
        XCTAssertEqual(open.decreased(from: 1), 1)
        XCTAssertTrue(open.canIncrease(from: 5))
        XCTAssertTrue(open.canIncrease(from: 100_000))
        XCTAssertEqual(open.increased(from: 100_000), 100_001)
        XCTAssertTrue(open.canDecrease(from: 2))
    }

    func testNUMSTEP_T02_AClosedHighestAndTheCeilingStopThePlus() {
        let closed = NumberStepperRule(bounds: NumberBounds(1...9))
        XCTAssertFalse(closed.canIncrease(from: 9))
        XCTAssertEqual(closed.increased(from: 9), 9)
        XCTAssertEqual(closed.increased(from: 8), 9)
        XCTAssertTrue(closed.canIncrease(from: 8))
        XCTAssertTrue(open.canIncrease(from: 999_999_998))
        XCTAssertEqual(open.increased(from: 999_999_998), 999_999_999)
        XCTAssertFalse(open.canIncrease(from: 999_999_999))
        XCTAssertEqual(open.increased(from: 999_999_999), 999_999_999)
    }

    func testNUMSTEP_T03_ABlankValueGoesUpOnlyAndLandsOnTheLowest() {
        XCTAssertFalse(open.canDecrease(from: nil))
        XCTAssertTrue(open.canIncrease(from: nil))
        XCTAssertEqual(open.increased(from: nil), 1)
        XCTAssertNil(open.decreased(from: nil))
        let from4 = NumberStepperRule(bounds: NumberBounds(4...20))
        XCTAssertEqual(from4.increased(from: nil), 4, "the lowest value of the field, not 1")
    }

    func testNUMSTEP_T04_OnlyAnOptionalFieldReturnsToBlankAndOnlyFromTheLowest() {
        let optional = NumberStepperRule(bounds: NumberBounds(lowest: 1), allowsBlank: true)
        XCTAssertTrue(optional.canDecrease(from: 1))
        XCTAssertNil(optional.decreased(from: 1))
        XCTAssertEqual(optional.decreased(from: 2), 1)
        XCTAssertTrue(optional.canDecrease(from: 2))
        XCTAssertFalse(open.allowsBlank)
        XCTAssertFalse(open.canDecrease(from: 1))
        XCTAssertEqual(open.decreased(from: 1), 1)
    }

    func testNUMSTEP_T05_AValueOutsideTheBoundsIsTreatedAsBlank() {
        XCTAssertNil(open.normalized(0))
        XCTAssertNil(open.normalized(-3))
        XCTAssertNil(open.normalized(1_000_000_000))
        XCTAssertEqual(open.normalized(1), 1)
        XCTAssertEqual(open.normalized(999_999_999), 999_999_999)
        XCTAssertNil(open.normalized(nil))
        XCTAssertEqual(open.increased(from: 0), 1)
        XCTAssertFalse(open.canDecrease(from: 0))
        let closed = NumberStepperRule(bounds: NumberBounds(1...9))
        XCTAssertNil(closed.normalized(10))
        XCTAssertEqual(String(NumberBounds.writableCeiling).count, AgentFieldCard.maxNumberDigits)
    }

    func testNUMSTEP_T06_TheTextsAreTheOnesTheSpecNames() {
        XCTAssertEqual(NumberStepperText.decrease("Party size"), "Decrease Party size")
        XCTAssertEqual(NumberStepperText.increase("Quantity"), "Increase Quantity")
        XCTAssertEqual(NumberStepperText.shown(nil), "\u{2013}")
        XCTAssertEqual(NumberStepperText.blank, "\u{2013}")
        XCTAssertEqual(NumberStepperText.shown(7), "7")
        XCTAssertEqual(NumberStepperText.blankSpoken, "No value")
        XCTAssertEqual(NumberStepperText.spoken(nil), "No value")
        XCTAssertEqual(NumberStepperText.spoken(7), "7")

        // The surface that card t106 relies on: these initialisers are constructed, not rendered, so a rename breaks the build.
        let rule = NumberStepperRule(bounds: NumberBounds(lowest: 1, highest: nil), allowsBlank: false)
        let box = NumberStepper(name: "Party size", value: 4, rule: rule, onChange: { _ in })
        let row = NumberStepperRow(label: "Quantity", value: nil, rule: rule, onChange: { _ in })
        XCTAssertEqual(box.name, "Party size")
        XCTAssertEqual(row.label, "Quantity")
    }
}
