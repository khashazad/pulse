// PulseTests/FoodDuplicateGrouperTests.swift
import XCTest
@testable import Pulse

final class FoodDuplicateGrouperTests: XCTestCase {
    private func food(_ name: String, _ id: String) -> CustomFood {
        CustomFood(id: UUID(uuidString: id)!, name: name, basis: .perUnit,
                   servingSize: 1, servingSizeUnit: "x", calories: 1,
                   proteinG: 0, carbsG: 0, fatG: 0, foodId: nil, portionLabel: nil)
    }

    func test_clustersBySharedStem() {
        let foods = [
            food("small apple", "00000000-0000-0000-0000-000000000001"),
            food("medium apple", "00000000-0000-0000-0000-000000000002"),
            food("apple per 100g", "00000000-0000-0000-0000-000000000003"),
            food("banana", "00000000-0000-0000-0000-000000000004"),
        ]
        let clusters = FoodDuplicateGrouper.clusters(from: foods)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters.first?.count, 3)
    }

    func test_singletonsAreNotClusters() {
        let clusters = FoodDuplicateGrouper.clusters(from: [
            food("apple", "00000000-0000-0000-0000-000000000001"),
            food("banana", "00000000-0000-0000-0000-000000000002"),
        ])
        XCTAssertTrue(clusters.isEmpty)
    }

    func test_suggestedName_sharedStemTitleCased() {
        let name = FoodDuplicateGrouper.suggestedName(for: [
            food("small apple", "00000000-0000-0000-0000-000000000001"),
            food("medium apple", "00000000-0000-0000-0000-000000000002"),
        ])
        XCTAssertEqual(name, "Apple")
    }

    func test_suggestedName_mixedFallsBackToFirstName() {
        let name = FoodDuplicateGrouper.suggestedName(for: [
            food("apple", "00000000-0000-0000-0000-000000000001"),
            food("banana", "00000000-0000-0000-0000-000000000002"),
        ])
        XCTAssertEqual(name, "apple")
    }

    func test_suggestedName_emptyReturnsEmpty() {
        XCTAssertEqual(FoodDuplicateGrouper.suggestedName(for: []), "")
    }
}
