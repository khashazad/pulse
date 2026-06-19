// PulseTests/SaveFoodsAsMealFlowTests.swift
import XCTest
@testable import Pulse

/// Tests the `SaveFoodsAsMealFlow` coordinator: it advances through foods as
/// quantities are added, reports completion, and maps the collected batch items
/// to meal items.
@MainActor
final class SaveFoodsAsMealFlowTests: XCTestCase {
    private func food(_ name: String, _ id: String) -> CustomFood {
        CustomFood(id: UUID(uuidString: id)!, name: name, basis: .perServing,
                   servingSize: 1, servingSizeUnit: "serving", calories: 100,
                   proteinG: 5, carbsG: 10, fatG: 2, foodId: nil, portionLabel: nil)
    }

    private func batch(for food: CustomFood, value: Double) -> BatchFoodItem {
        BatchFoodItem(
            id: UUID(), displayName: food.name, usdaFdcId: nil, usdaDescription: nil,
            customFoodId: food.id,
            nutrition: FoodNutrition(basis: .perServing, servingSize: 1, servingSizeUnit: "serving",
                                     caloriesPerBasis: 100, proteinGPerBasis: 5,
                                     carbsGPerBasis: 10, fatGPerBasis: 2),
            quantity: .typed(value: value, unit: .servings), containerId: nil,
            macros: MacroTotals(calories: Int(100 * value), proteinG: 5 * value,
                                carbsG: 10 * value, fatG: 2 * value))
    }

    func test_advancesAndCompletes() {
        let a = food("Chicken", "aaaa1111-0000-0000-0000-000000000001")
        let b = food("Rice", "aaaa1111-0000-0000-0000-000000000002")
        let flow = SaveFoodsAsMealFlow(foods: [a, b], auth: nil)

        XCTAssertEqual(flow.currentFood?.id, a.id)
        XCTAssertFalse(flow.isComplete)

        flow.add(batch(for: a, value: 1))
        XCTAssertEqual(flow.currentFood?.id, b.id)
        XCTAssertFalse(flow.isComplete)

        flow.add(batch(for: b, value: 2))
        XCTAssertNil(flow.currentFood)
        XCTAssertTrue(flow.isComplete)

        let items = flow.mealItems
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].displayName, "Chicken")
        XCTAssertEqual(items[1].quantityText, "2 servings")
        XCTAssertEqual(items[1].calories, 200)
    }
}
