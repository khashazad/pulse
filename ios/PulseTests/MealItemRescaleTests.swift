// PulseTests/MealItemRescaleTests.swift
import XCTest
@testable import Pulse

/// Tests `FoodSearchResult(mealItem:)`: it synthesizes per-basis nutrition from
/// a meal item's stored macros so QuantityEntryView can rescale it linearly.
final class MealItemRescaleTests: XCTestCase {
    private func item(
        value: Double?, unit: String?, calories: Int = 110,
        protein: Double = 8, carbs: Double = 2, fat: Double = 6,
        fdc: Int? = 123, customFood: UUID? = nil
    ) -> MealItem {
        MealItem(
            id: UUID(), mealId: UUID(), position: 0, displayName: "Tuna",
            quantityText: "80 g", normalizedQuantityValue: value, normalizedQuantityUnit: unit,
            usdaFdcId: fdc, usdaDescription: fdc == nil ? nil : "Tuna, canned",
            customFoodId: customFood, calories: calories, proteinG: protein,
            carbsG: carbs, fatG: fat, createdAt: Date())
    }

    func test_nilNormalizedValue_returnsNil() {
        XCTAssertNil(FoodSearchResult(mealItem: item(value: nil, unit: "handful")))
    }

    func test_zeroNormalizedValue_returnsNil() {
        XCTAssertNil(FoodSearchResult(mealItem: item(value: 0, unit: "g")))
    }

    func test_grams_roundTripsAtOriginalQuantity() throws {
        let r = try XCTUnwrap(FoodSearchResult(mealItem: item(value: 80, unit: "g")))
        XCTAssertEqual(r.nutrition.basis, .per100g)
        XCTAssertEqual(r.usdaFdcId, 123)
        let m = try XCTUnwrap(r.nutrition.macros(typedValue: 80, unit: .grams))
        XCTAssertEqual(m.calories, 110, accuracy: 1)
        XCTAssertEqual(m.proteinG, 8, accuracy: 0.1)
    }

    func test_grams_scalesLinearly() throws {
        let r = try XCTUnwrap(FoodSearchResult(mealItem: item(value: 80, unit: "g")))
        let m = try XCTUnwrap(r.nutrition.macros(typedValue: 160, unit: .grams))
        XCTAssertEqual(m.calories, 220, accuracy: 2)
        XCTAssertEqual(m.proteinG, 16, accuracy: 0.2)
    }

    func test_serving_usesPerServingBasis() throws {
        let r = try XCTUnwrap(FoodSearchResult(mealItem: item(value: 2, unit: "serving")))
        XCTAssertEqual(r.nutrition.basis, .perServing)
        let m = try XCTUnwrap(r.nutrition.macros(typedValue: 2, unit: .servings))
        XCTAssertEqual(m.calories, 110, accuracy: 1)
        XCTAssertEqual(m.proteinG, 8, accuracy: 0.1)
    }

    func test_customFoodPointerPreserved() throws {
        let cf = UUID()
        let r = try XCTUnwrap(FoodSearchResult(mealItem: item(value: 1, unit: "unit", fdc: nil, customFood: cf)))
        XCTAssertEqual(r.nutrition.basis, .perUnit)
        XCTAssertEqual(r.customFoodId, cf)
        XCTAssertNil(r.usdaFdcId)
        // perUnit round-trips the stored macros at the original quantity.
        let m = try XCTUnwrap(r.nutrition.macros(typedValue: 1, unit: .units))
        XCTAssertEqual(m.calories, 110, accuracy: 1)
        XCTAssertEqual(m.proteinG, 8, accuracy: 0.1)
    }
}
