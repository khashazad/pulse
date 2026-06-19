// PulseTests/NewMealItemTests.swift
import XCTest
@testable import Pulse

/// Tests the pure `NewMealItem` factories: a logged `FoodEntry` maps 1:1, and a
/// `BatchFoodItem` derives its quantity text/normalized value from typed vs
/// weighed quantities (weighed nets out the container tare).
final class NewMealItemTests: XCTestCase {
    func test_fromEntry_passesFieldsThrough() {
        let cfid = UUID()
        let entry = FoodEntry(
            id: UUID(), dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
            displayName: "Chicken", quantityText: "150 g",
            normalizedQuantityValue: 150, normalizedQuantityUnit: "g",
            usdaFdcId: nil, usdaDescription: nil, customFoodId: cfid,
            calories: 250, proteinG: 40, carbsG: 0, fatG: 9,
            mealId: nil, mealName: nil, consumedAt: Date(), createdAt: Date())

        let item = NewMealItem.from(entry: entry)

        XCTAssertEqual(item.displayName, "Chicken")
        XCTAssertEqual(item.quantityText, "150 g")
        XCTAssertEqual(item.normalizedQuantityValue, 150)
        XCTAssertEqual(item.normalizedQuantityUnit, "g")
        XCTAssertEqual(item.customFoodId, cfid)
        XCTAssertNil(item.usdaFdcId)
        XCTAssertEqual(item.calories, 250)
        XCTAssertEqual(item.proteinG, 40)
    }

    func test_fromBatch_typedServings_buildsQuantity() {
        let cfid = UUID()
        let nutrition = FoodNutrition(basis: .perServing, servingSize: 1, servingSizeUnit: "scoop",
                                      caloriesPerBasis: 120, proteinGPerBasis: 24,
                                      carbsGPerBasis: 3, fatGPerBasis: 1)
        let batch = BatchFoodItem(
            id: UUID(), displayName: "Whey", usdaFdcId: nil, usdaDescription: nil,
            customFoodId: cfid, nutrition: nutrition,
            quantity: .typed(value: 2, unit: .servings), containerId: nil,
            macros: MacroTotals(calories: 240, proteinG: 48, carbsG: 6, fatG: 2))

        let item = NewMealItem.from(batchItem: batch, containers: [])

        XCTAssertEqual(item.displayName, "Whey")
        XCTAssertEqual(item.quantityText, "2 servings")
        XCTAssertEqual(item.normalizedQuantityValue, 2)
        XCTAssertEqual(item.normalizedQuantityUnit, "serving")
        XCTAssertEqual(item.customFoodId, cfid)
        XCTAssertEqual(item.calories, 240)
        XCTAssertEqual(item.proteinG, 48)
    }

    func test_fromBatch_weighed_netsOutTare() {
        let cfid = UUID()
        let container = Container(id: UUID(), userKey: "khash", name: "Bowl",
                                  normalizedName: "bowl", tareWeightG: 50, hasPhoto: false,
                                  createdAt: Date(), updatedAt: Date())
        let nutrition = FoodNutrition(basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                                      caloriesPerBasis: 100, proteinGPerBasis: 10,
                                      carbsGPerBasis: 5, fatGPerBasis: 2)
        let batch = BatchFoodItem(
            id: UUID(), displayName: "Rice", usdaFdcId: nil, usdaDescription: nil,
            customFoodId: cfid, nutrition: nutrition,
            quantity: .weighed(grossG: 250), containerId: container.id,
            macros: MacroTotals(calories: 200, proteinG: 20, carbsG: 10, fatG: 4))

        let item = NewMealItem.from(batchItem: batch, containers: [container])

        XCTAssertEqual(item.quantityText, "200 g")
        XCTAssertEqual(item.normalizedQuantityValue, 200)
        XCTAssertEqual(item.normalizedQuantityUnit, "g")
    }
}
