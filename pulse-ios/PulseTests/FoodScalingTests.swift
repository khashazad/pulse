// PulseTests/FoodScalingTests.swift
import XCTest
@testable import Pulse

/// Unit tests for `FoodNutrition` basis-aware scaling and weigh-mode gating.
final class FoodScalingTests: XCTestCase {
    /// per_100g: typing grams scales linearly off /100, and weighing uses net grams directly.
    func test_per100g_gramsAndWeighing() {
        let n = FoodNutrition(basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                              caloriesPerBasis: 200, proteinGPerBasis: 20, carbsGPerBasis: 10, fatGPerBasis: 8)
        XCTAssertTrue(n.allowsWeighing)
        XCTAssertEqual(n.typeUnit, .grams)
        let typed = n.macros(typedValue: 250, unit: .grams)
        XCTAssertEqual(typed, MacroTotals(calories: 500, proteinG: 50, carbsG: 25, fatG: 20))
        let weighed = n.macros(netGrams: 250)
        XCTAssertEqual(weighed, typed)
    }

    /// per_serving with gram serving size: weighing converts grams→servings; typing uses serving count.
    func test_perServing_gramServing_allowsWeighing() {
        let n = FoodNutrition(basis: .perServing, servingSize: 50, servingSizeUnit: "g",
                              caloriesPerBasis: 100, proteinGPerBasis: 5, carbsGPerBasis: 12, fatGPerBasis: 3)
        XCTAssertTrue(n.allowsWeighing)
        XCTAssertEqual(n.typeUnit, .servings)
        XCTAssertEqual(n.macros(typedValue: 2, unit: .servings),
                       MacroTotals(calories: 200, proteinG: 10, carbsG: 24, fatG: 6))
        // 100 g ÷ 50 g/serving = 2 servings
        XCTAssertEqual(n.macros(netGrams: 100),
                       MacroTotals(calories: 200, proteinG: 10, carbsG: 24, fatG: 6))
    }

    /// per_serving with a non-gram serving unit: weighing is disabled and returns nil.
    func test_perServing_nonGramServing_disablesWeighing() {
        let n = FoodNutrition(basis: .perServing, servingSize: 1, servingSizeUnit: "cup",
                              caloriesPerBasis: 100, proteinGPerBasis: 5, carbsGPerBasis: 12, fatGPerBasis: 3)
        XCTAssertFalse(n.allowsWeighing)
        XCTAssertNil(n.macros(netGrams: 100))
        XCTAssertEqual(n.macros(typedValue: 3, unit: .servings),
                       MacroTotals(calories: 300, proteinG: 15, carbsG: 36, fatG: 9))
    }

    /// per_unit: weighing disabled; typing counts units.
    func test_perUnit_unitsOnly() {
        let n = FoodNutrition(basis: .perUnit, servingSize: nil, servingSizeUnit: nil,
                              caloriesPerBasis: 70, proteinGPerBasis: 6, carbsGPerBasis: 0, fatGPerBasis: 5)
        XCTAssertFalse(n.allowsWeighing)
        XCTAssertEqual(n.typeUnit, .units)
        XCTAssertNil(n.macros(netGrams: 120))
        XCTAssertEqual(n.macros(typedValue: 3, unit: .units),
                       MacroTotals(calories: 210, proteinG: 18, carbsG: 0, fatG: 15))
    }

    /// A typed unit that doesn't match the basis is rejected.
    func test_mismatchedUnitReturnsNil() {
        let n = FoodNutrition(basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                              caloriesPerBasis: 200, proteinGPerBasis: 20, carbsGPerBasis: 10, fatGPerBasis: 8)
        XCTAssertNil(n.macros(typedValue: 2, unit: .servings))
    }
}
