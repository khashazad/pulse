// PulseTests/FoodSearchDTODecodingTests.swift
import XCTest
@testable import Pulse

/// Verifies the food-search wire DTOs decode the server fixtures, including
/// snake_case mapping and the all-null memory row that points at a custom food.
final class FoodSearchDTODecodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    func test_decodeUSDASearch() throws {
        let resp = try JSONDecoder.pulseDefault().decode(USDASearchResponse.self, from: fixture("usda_search"))
        XCTAssertEqual(resp.results.count, 3)
        XCTAssertEqual(resp.results[0].fdcId, 171077)
        XCTAssertEqual(resp.results[0].proteinG, 22.5)
        XCTAssertEqual(resp.results[0].dataType, "Foundation")
        XCTAssertNil(resp.results[0].brandOwner)
        XCTAssertNil(resp.results[1].servingSize)
        XCTAssertNil(resp.results[1].dataType)
        XCTAssertEqual(resp.results[2].dataType, "Branded")
        XCTAssertEqual(resp.results[2].brandOwner, "Tyson Foods Inc.")
    }

    func test_decodeCustomFoods() throws {
        let list = try JSONDecoder.pulseDefault().decode(CustomFoodList.self, from: fixture("custom_foods"))
        XCTAssertEqual(list.customFoods.count, 1)
        XCTAssertEqual(list.customFoods[0].basis, .perServing)
        XCTAssertEqual(list.customFoods[0].calories, 130)
    }

    func test_decodeFoodMemory_usdaAndCustomPointers() throws {
        let list = try JSONDecoder.pulseDefault().decode(FoodMemoryList.self, from: fixture("food_memory"))
        XCTAssertEqual(list.entries.count, 2)
        XCTAssertEqual(list.entries[0].usdaFdcId, 169756)
        XCTAssertEqual(list.entries[0].basis, .per100g)
        XCTAssertEqual(list.entries[0].aliases, ["rice"])
        XCTAssertNil(list.entries[1].basis)
        XCTAssertNil(list.entries[1].calories)
        XCTAssertEqual(list.entries[1].customFoodId,
                       UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    }
}
