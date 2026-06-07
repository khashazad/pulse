// PulseTests/FoodSearchMergeTests.swift
import XCTest
@testable import Pulse

/// Tests for building the "my foods" set and merging/ranking against a query.
final class FoodSearchMergeTests: XCTestCase {
    private func customFood(_ id: String, _ name: String) -> CustomFood {
        CustomFood(id: UUID(uuidString: id)!, name: name, basis: .perServing,
                   servingSize: 1, servingSizeUnit: "scoop",
                   calories: 130, proteinG: 25, carbsG: 3, fatG: 1.5)
    }
    private func memoryUSDA(_ id: String, _ name: String, fdc: Int, aliases: [String]) -> FoodMemoryEntry {
        FoodMemoryEntry(id: UUID(uuidString: id)!, name: name, usdaFdcId: fdc, usdaDescription: "d",
                        customFoodId: nil, basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                        calories: 130, proteinG: 2.7, carbsG: 28, fatG: 0.3, aliases: aliases)
    }
    private func memoryCustom(_ id: String, _ name: String, customId: String) -> FoodMemoryEntry {
        FoodMemoryEntry(id: UUID(uuidString: id)!, name: name, usdaFdcId: nil, usdaDescription: nil,
                        customFoodId: UUID(uuidString: customId)!, basis: nil, servingSize: nil,
                        servingSizeUnit: nil, calories: nil, proteinG: nil, carbsG: nil, fatG: nil, aliases: [])
    }
    private func usda(_ fdc: Int, _ desc: String) -> USDAFoodResult {
        USDAFoodResult(fdcId: fdc, description: desc, calories: 165, proteinG: 31, carbsG: 0, fatG: 3.6,
                       servingSize: nil, servingSizeUnit: nil, dataType: nil, brandOwner: nil)
    }

    func test_myFoods_dropsCustomPointerMemory() {
        let my = FoodSearchMerge.myFoods(
            customFoods: [customFood("22222222-2222-2222-2222-222222222222", "Protein Shake")],
            memory: [
                memoryUSDA("33333333-3333-3333-3333-333333333333", "white rice", fdc: 169756, aliases: ["rice"]),
                memoryCustom("44444444-4444-4444-4444-444444444444", "Protein Shake",
                             customId: "22222222-2222-2222-2222-222222222222")
            ]
        )
        XCTAssertEqual(my.count, 2)
        XCTAssertTrue(my.contains { $0.customFoodId != nil && $0.displayName == "Protein Shake" })
        XCTAssertTrue(my.contains { $0.usdaFdcId == 169756 })
    }

    func test_emptyQueryReturnsNothing() {
        let my = FoodSearchMerge.myFoods(customFoods: [customFood("22222222-2222-2222-2222-222222222222", "Protein Shake")], memory: [])
        XCTAssertTrue(FoodSearchMerge.results(query: "   ", myFoods: my, usda: []).isEmpty)
    }

    func test_results_ranking_myFoodsFirst_prefixFirst() {
        let my = FoodSearchMerge.myFoods(
            customFoods: [],
            memory: [
                memoryUSDA("33333333-3333-3333-3333-333333333333", "white rice", fdc: 169756, aliases: ["rice"]),
                memoryUSDA("55555555-5555-5555-5555-555555555555", "fried rice", fdc: 111, aliases: [])
            ]
        )
        let out = FoodSearchMerge.results(query: "rice", myFoods: my,
                                          usda: [usda(999, "rice pilaf")])
        XCTAssertEqual(out.last?.source, .usda)
        XCTAssertTrue(out.dropLast().allSatisfy { $0.source == .myFood })
        let names = out.filter { $0.source == .myFood }.map { $0.displayName }
        XCTAssertEqual(names.first, "white rice")
    }

    func test_results_dedupesUSDAAgainstMyFoods() {
        let my = FoodSearchMerge.myFoods(customFoods: [],
            memory: [memoryUSDA("33333333-3333-3333-3333-333333333333", "white rice", fdc: 169756, aliases: [])])
        let out = FoodSearchMerge.results(query: "rice", myFoods: my, usda: [usda(169756, "Rice, white")])
        XCTAssertEqual(out.filter { $0.usdaFdcId == 169756 }.count, 1)
    }
}
