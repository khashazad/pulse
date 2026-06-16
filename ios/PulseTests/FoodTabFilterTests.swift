// PulseTests/FoodTabFilterTests.swift
import XCTest
@testable import Pulse

/// Tests the pure name-filter helpers backing the Food tab's search field.
final class FoodTabFilterTests: XCTestCase {
    private func food(_ name: String) -> CustomFood {
        CustomFood(id: UUID(), name: name, basis: .perServing, servingSize: 1, servingSizeUnit: "scoop",
                   calories: 100, proteinG: 10, carbsG: 5, fatG: 2)
    }

    func test_filter_blankQueryReturnsAllSortedByName() {
        let foods = [food("Zucchini"), food("apple"), food("Banana")]
        let out = FoodTabFilter.foods(foods, query: "   ")
        XCTAssertEqual(out.map(\.name), ["apple", "Banana", "Zucchini"])
    }

    func test_filter_matchesCaseInsensitiveSubstring() {
        let foods = [food("Greek Yogurt"), food("Granola"), food("Egg")]
        let out = FoodTabFilter.foods(foods, query: "gr")
        XCTAssertEqual(Set(out.map(\.name)), ["Greek Yogurt", "Granola"])
    }

    func test_filter_noMatchReturnsEmpty() {
        XCTAssertTrue(FoodTabFilter.foods([food("Egg")], query: "zzz").isEmpty)
    }

    // MARK: - MealSummary helpers

    /// Builds a minimal `MealSummary` by decoding from JSON. `MealSummary` only
    /// exposes `init(from:)`, so this is the canonical construction path in tests.
    /// Inputs:
    ///   - name: the meal's display name.
    /// Outputs: a `MealSummary` with all macro fields zeroed and `itemCount` of 0.
    private func meal(_ name: String) -> MealSummary {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "\(name)",
          "normalized_name": "\(name.lowercased())",
          "notes": null,
          "aliases": [],
          "item_count": 0,
          "total_calories": 0,
          "total_protein_g": 0.0,
          "total_carbs_g": 0.0,
          "total_fat_g": 0.0
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(MealSummary.self, from: json)
    }

    func test_mealsFilter_matchesByNameCaseInsensitive() {
        let meals = [meal("Wrap"), meal("Salad")]
        let out = FoodTabFilter.meals(meals, query: "wr")
        XCTAssertEqual(out.map(\.name), ["Wrap"])
    }
}
