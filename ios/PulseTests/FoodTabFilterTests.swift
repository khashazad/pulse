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
}
