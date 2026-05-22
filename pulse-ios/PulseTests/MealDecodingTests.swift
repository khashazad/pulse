/// Unit tests for `MealsListResponse` and `Meal` decoding.
/// Confirms aliases decode from the dedicated array, and that missing
/// `aliases` keys default to an empty list rather than failing decode.
/// Part of the iOS app's decoding test suite.
import XCTest
@testable import Pulse

final class MealDecodingTests: XCTestCase {
    /// Loads a JSON fixture from the test bundle.
    /// Inputs:
    ///   - name: fixture file base name.
    /// Outputs: raw bytes of `<name>.json`.
    /// Exceptions: throws if the fixture is missing or unreadable.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found in test bundle")
            throw NSError(domain: "fixture", code: 0)
        }
        return try Data(contentsOf: url)
    }

    /// Verifies a `meals` payload with aliases decodes them in order.
    func testMealSummaryDecodesAliases() throws {
        let data = try loadFixture("meals_with_aliases")
        let decoded = try JSONDecoder.pulseDefault().decode(MealsListResponse.self, from: data)
        XCTAssertEqual(decoded.meals.first?.aliases, ["the wrap", "lunch wrap"])
    }

    /// Verifies a meals-list payload missing the `aliases` field decodes
    /// with `aliases == []`.
    func testMealSummaryDecodesWithoutAliasesField() throws {
        let json = """
        {"meals": [{"id":"11111111-1111-1111-1111-111111111111","name":"Wrap","normalized_name":"wrap","notes":null,"item_count":0,"total_calories":0,"total_protein_g":0,"total_carbs_g":0,"total_fat_g":0}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder.pulseDefault().decode(MealsListResponse.self, from: json)
        XCTAssertEqual(decoded.meals.first?.aliases, [])
    }

    /// Verifies a single `Meal` payload missing the `aliases` field decodes
    /// with `aliases == []`.
    func testMealDecodesWithoutAliasesField() throws {
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "user_key": "khash",
            "name": "Wrap",
            "normalized_name": "wrap",
            "notes": null,
            "created_at": "2026-05-10T12:00:00Z",
            "updated_at": "2026-05-10T12:00:00Z",
            "items": []
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder.pulseDefault().decode(Meal.self, from: json)
        XCTAssertEqual(decoded.aliases, [])
    }
}
