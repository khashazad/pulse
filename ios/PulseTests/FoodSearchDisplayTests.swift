// PulseTests/FoodSearchDisplayTests.swift
import XCTest
@testable import Pulse

/// Unit tests for the search-row display helpers: per-basis caption lines,
/// USDA disambiguation badges, and the quantity sheet's basis-context line.
final class FoodSearchDisplayTests: XCTestCase {
    /// Builds a USDA-sourced result with controllable disambiguation fields.
    private func usdaResult(dataType: String?, brandOwner: String?) -> FoodSearchResult {
        FoodSearchResult(usda: USDAFoodResult(
            fdcId: 1, description: "Chicken breast, raw", calories: 120,
            proteinG: 22.5, carbsG: 0.4, fatG: 2.6,
            servingSize: nil, servingSizeUnit: nil,
            dataType: dataType, brandOwner: brandOwner))
    }

    /// Builds a custom-food result with controllable serving fields.
    private func customResult(servingSize: Double?, unit: String?) -> FoodSearchResult {
        FoodSearchResult(customFood: CustomFood(
            id: UUID(), name: "Protein Shake", basis: .perServing,
            servingSize: servingSize, servingSizeUnit: unit,
            calories: 130, proteinG: 25, carbsG: 3, fatG: 1.5))
    }

    func test_usdaCaption_per100g() {
        XCTAssertEqual(usdaResult(dataType: "Foundation", brandOwner: nil).caption,
                       "120 kcal · P 23 · C 0 · F 3 / 100g")
    }

    func test_customCaption_servingWithSize() {
        XCTAssertEqual(customResult(servingSize: 1, unit: "scoop").caption,
                       "130 kcal · P 25 · C 3 · F 2 / serving (1 scoop)")
    }

    func test_customCaption_servingSizeMissing() {
        XCTAssertEqual(customResult(servingSize: nil, unit: nil).caption,
                       "130 kcal · P 25 · C 3 · F 2 / serving — size not set")
    }

    func test_badge_foundationAndSurveyMapping() {
        XCTAssertEqual(usdaResult(dataType: "Foundation", brandOwner: nil).badge, "Foundation")
        XCTAssertEqual(usdaResult(dataType: "Survey (FNDDS)", brandOwner: nil).badge, "Survey")
        XCTAssertEqual(usdaResult(dataType: "SR Legacy", brandOwner: nil).badge, "SR Legacy")
    }

    func test_badge_brandedPrefersBrandOwner() {
        XCTAssertEqual(usdaResult(dataType: "Branded", brandOwner: "Tyson Foods Inc.").badge,
                       "Tyson Foods Inc.")
        XCTAssertEqual(usdaResult(dataType: "Branded", brandOwner: nil).badge, "Branded")
    }

    func test_badge_nilForMyFoodsAndUnknownDataType() {
        XCTAssertNil(customResult(servingSize: 1, unit: "scoop").badge)
        XCTAssertNil(usdaResult(dataType: nil, brandOwner: nil).badge)
    }

    func test_basisContextLine() {
        XCTAssertEqual(customResult(servingSize: 250, unit: "g").nutrition.basisContextLine,
                       "1 serving = 250 g")
        XCTAssertEqual(customResult(servingSize: nil, unit: nil).nutrition.basisContextLine,
                       "1 serving — size not set")
        XCTAssertEqual(usdaResult(dataType: nil, brandOwner: nil).nutrition.basisContextLine,
                       "Macros are per 100 g")
    }
}
