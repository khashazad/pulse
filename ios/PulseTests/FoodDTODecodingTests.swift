// PulseTests/FoodDTODecodingTests.swift
import XCTest
@testable import Pulse

/// Decoding tests for the `/foods` browse DTOs and the new CustomFood portion fields.
final class FoodDTODecodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func test_decodesFoodListWithNestedPortions() throws {
        let list = try JSONDecoder.pulseDefault().decode(FoodList.self, from: fixture("foods"))
        XCTAssertEqual(list.foods.count, 1)
        let apple = try XCTUnwrap(list.foods.first)
        XCTAssertEqual(apple.name, "Apple")
        XCTAssertEqual(apple.aliases, ["apple", "apples"])
        XCTAssertEqual(apple.portions.count, 2)
        XCTAssertEqual(apple.portions.first?.label, "medium")
        XCTAssertEqual(apple.defaultPortionId, apple.portions.first?.customFoodId)
        XCTAssertEqual(list.standalones.count, 1)
        XCTAssertNil(list.standalones.first?.foodId)
    }

    func test_customFoodDecodesPortionLinkage() throws {
        let json = #"""
        { "id": "33333333-3333-3333-3333-333333333333", "name": "medium apple",
          "basis": "per_unit", "serving_size": 1.0, "serving_size_unit": "apple",
          "calories": 95, "protein_g": 0.5, "carbs_g": 25.0, "fat_g": 0.3,
          "food_id": "11111111-1111-1111-1111-111111111111", "portion_label": "medium" }
        """#
        let food = try JSONDecoder.pulseDefault().decode(CustomFood.self, from: Data(json.utf8))
        XCTAssertEqual(food.portionLabel, "medium")
        XCTAssertEqual(food.foodId?.uuidString, "11111111-1111-1111-1111-111111111111")
    }
}
