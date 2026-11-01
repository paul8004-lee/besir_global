import Foundation

/// SPEC-NUMSTEPPER-001 (card t107): the rule of the minus/plus stepper. Foundation only: no view, no card model, and no
/// partner, partner id or field key. The stepper moves by one.

/// The values a number field may hold. `highest` nil means the field has no limit of its own; plus then stops at
/// `writableCeiling`, the largest number the card model can hold.
struct NumberBounds: Equatable {
    /// The largest number the card holds (`AgentFieldCard.maxNumberDigits` digits).
    static let writableCeiling = 999_999_999

    let lowest: Int
    let highest: Int?

    init(lowest: Int, highest: Int? = nil) {
        self.lowest = lowest
        self.highest = highest
    }

    init(_ range: ClosedRange<Int>) {
        self.init(lowest: range.lowerBound, highest: range.upperBound)
    }

    /// The highest number a stepper can reach: the field's own end, never above the ceiling.
    var top: Int { 0 }

    func contains(_ number: Int) -> Bool { false }
}

struct NumberStepperRule: Equatable {
    let bounds: NumberBounds
    /// True when the field is optional: minus at the lowest value returns it to blank.
    let allowsBlank: Bool

    init(bounds: NumberBounds, allowsBlank: Bool = false) {
        self.bounds = bounds
        self.allowsBlank = allowsBlank
    }

    /// The value when it lies inside the bounds, else nil: a value outside the bounds reads as blank in every decision below.
    func normalized(_ value: Int?) -> Int? { value }

    func canIncrease(from value: Int?) -> Bool { false }

    func canDecrease(from value: Int?) -> Bool { false }

    func increased(from value: Int?) -> Int? { value }

    func decreased(from value: Int?) -> Int? { value }
}

/// The words of the stepper. The view writes none of its own.
enum NumberStepperText {
    static let blank = String()
    static let blankSpoken = String()

    static func decrease(_ label: String) -> String { String() }

    static func increase(_ label: String) -> String { String() }

    static func shown(_ value: Int?) -> String { String() }

    static func spoken(_ value: Int?) -> String { String() }
}
