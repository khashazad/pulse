import XCTest
@testable import Pulse

/// Tests for `MacroTotals.scaled(count:portions:)`, the single scaling helper
/// behind the per-portion preview line and apply-to-days payload math.
final class MacroScalingTests: XCTestCase {

    /// One portion of a 5-portion batch is exactly total/5, with calories
    /// rounded to Int and gram macros rounded to 0.1.
    func test_onePortionOfFive() {
        let total = MacroTotals(calories: 2603, proteinG: 212.3, carbsG: 188.7, fatG: 96.1)
        let p = total.scaled(count: 1, portions: 5)
        XCTAssertEqual(p, MacroTotals(calories: 521, proteinG: 42.5, carbsG: 37.7, fatG: 19.2))
    }

    /// Two portions scale linearly from one.
    func test_twoPortionsDoubleOne() {
        let total = MacroTotals(calories: 1000, proteinG: 80, carbsG: 100, fatG: 40)
        let p = total.scaled(count: 2, portions: 5)
        XCTAssertEqual(p, MacroTotals(calories: 400, proteinG: 32, carbsG: 40, fatG: 16))
    }

    /// Degenerate inputs are clamped: portions < 1 acts as 1, negative count as 0.
    func test_degenerateInputsClamp() {
        let total = MacroTotals(calories: 500, proteinG: 50, carbsG: 50, fatG: 10)
        XCTAssertEqual(total.scaled(count: 1, portions: 0), total)
        XCTAssertEqual(total.scaled(count: -2, portions: 5),
                       MacroTotals(calories: 0, proteinG: 0, carbsG: 0, fatG: 0))
    }

    /// Calories use .rounded() (0.5 rounds away from zero).
    func test_calorieRounding() {
        let total = MacroTotals(calories: 1001, proteinG: 0, carbsG: 0, fatG: 0)
        XCTAssertEqual(total.scaled(count: 1, portions: 2).calories, 501)
    }
}
