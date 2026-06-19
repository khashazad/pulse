// PulseTests/MealEditClientTests.swift
import XCTest
@testable import Pulse

/// Tests the meal-edit client methods: rename, delete, add item, update item,
/// delete item. Mirrors CreateMealClientTests' StubURLProtocol setup.
final class MealEditClientTests: XCTestCase {
    private var activeStubs: [StubURLProtocol.Registration] = []

    private func makeClient(
        responder: @escaping StubURLProtocol.Responder
    ) -> (PulseClient, StubURLProtocol.Registration) {
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        let client = PulseClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-k",
            session: stub.session)
        return (client, stub)
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        super.tearDown()
    }

    private static let mealJSON = #"""
    { "id": "55555555-5555-5555-5555-555555555555", "user_key": "khash",
      "name": "Renamed", "normalized_name": "renamed", "notes": null, "aliases": [],
      "created_at": "2026-06-18T00:00:00Z", "updated_at": "2026-06-18T00:00:00Z",
      "items": [] }
    """#

    private static let itemJSON = #"""
    { "id": "66666666-6666-6666-6666-666666666666",
      "meal_id": "55555555-5555-5555-5555-555555555555", "position": 0,
      "display_name": "Chicken", "quantity_text": "120 g",
      "normalized_quantity_value": 120, "normalized_quantity_unit": "g",
      "usda_fdc_id": null, "usda_description": null,
      "custom_food_id": "77777777-7777-7777-7777-777777777777",
      "calories": 200, "protein_g": 32, "carbs_g": 0, "fat_g": 7,
      "created_at": "2026-06-18T00:00:00Z" }
    """#

    private static let mealId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private static let itemId = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    func test_updateMeal_patchesNameAndDecodes() async throws {
        var captured: URLRequest?
        let (client, stub) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(Self.mealJSON.utf8))
        }
        let meal = try await client.updateMeal(id: Self.mealId, name: "Renamed")
        XCTAssertEqual(meal.name, "Renamed")
        XCTAssertEqual(captured?.httpMethod, "PATCH")
        XCTAssertEqual(captured?.url?.path, "/meals/55555555-5555-5555-5555-555555555555")
        let body = try XCTUnwrap(stub.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "Renamed")
    }

    func test_deleteMeal_sendsDelete() async throws {
        var captured: URLRequest?
        let (client, _) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await client.deleteMeal(id: Self.mealId)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/meals/55555555-5555-5555-5555-555555555555")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
    }

    func test_addMealItem_postsBodyAndDecodes() async throws {
        var captured: URLRequest?
        let (client, stub) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data(Self.itemJSON.utf8))
        }
        let cfid = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let item = NewMealItem(
            id: UUID(), displayName: "Chicken", quantityText: "120 g",
            normalizedQuantityValue: 120, normalizedQuantityUnit: "g",
            usdaFdcId: nil, usdaDescription: nil, customFoodId: cfid,
            calories: 200, proteinG: 32, carbsG: 0, fatG: 7)
        let created = try await client.addMealItem(mealId: Self.mealId, item: item)
        XCTAssertEqual(created.displayName, "Chicken")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/meals/55555555-5555-5555-5555-555555555555/items")
        let body = try XCTUnwrap(stub.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["custom_food_id"] as? String, cfid.uuidString.lowercased())
        XCTAssertNil(obj["id"])
    }

    func test_updateMealItem_patchesMutableFieldsOnly() async throws {
        var captured: URLRequest?
        let (client, stub) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(Self.itemJSON.utf8))
        }
        let item = NewMealItem(
            id: UUID(), displayName: "Chicken", quantityText: "120 g",
            normalizedQuantityValue: 120, normalizedQuantityUnit: "g",
            usdaFdcId: nil, usdaDescription: nil,
            customFoodId: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            calories: 200, proteinG: 32, carbsG: 0, fatG: 7)
        let updated = try await client.updateMealItem(mealId: Self.mealId, itemId: Self.itemId, item: item)
        XCTAssertEqual(updated.quantityText, "120 g")
        XCTAssertEqual(captured?.httpMethod, "PATCH")
        XCTAssertEqual(captured?.url?.path,
                       "/meals/55555555-5555-5555-5555-555555555555/items/66666666-6666-6666-6666-666666666666")
        let body = try XCTUnwrap(stub.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["quantity_text"] as? String, "120 g")
        XCTAssertEqual(obj["calories"] as? Int, 200)
        // Immutable food-source fields must NOT be in the update body.
        XCTAssertNil(obj["custom_food_id"])
        XCTAssertNil(obj["usda_fdc_id"])
    }

    func test_deleteMealItem_sendsDelete() async throws {
        var captured: URLRequest?
        let (client, _) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await client.deleteMealItem(mealId: Self.mealId, itemId: Self.itemId)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path,
                       "/meals/55555555-5555-5555-5555-555555555555/items/66666666-6666-6666-6666-666666666666")
    }
}
