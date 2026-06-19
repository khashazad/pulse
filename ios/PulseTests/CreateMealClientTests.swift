// PulseTests/CreateMealClientTests.swift
import XCTest
@testable import Pulse

/// Tests `PulseClient.createMeal`: it POSTs to `/meals` with the items mapped to
/// the server's snake_case contract and decodes the returned `MealResponse`.
final class CreateMealClientTests: XCTestCase {
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
      "name": "Lunch", "normalized_name": "lunch", "notes": null, "aliases": [],
      "created_at": "2026-06-18T00:00:00Z", "updated_at": "2026-06-18T00:00:00Z",
      "items": [
        { "id": "66666666-6666-6666-6666-666666666666",
          "meal_id": "55555555-5555-5555-5555-555555555555", "position": 0,
          "display_name": "Chicken", "quantity_text": "150 g",
          "normalized_quantity_value": 150, "normalized_quantity_unit": "g",
          "usda_fdc_id": null, "usda_description": null,
          "custom_food_id": "77777777-7777-7777-7777-777777777777",
          "calories": 250, "protein_g": 40, "carbs_g": 0, "fat_g": 9,
          "created_at": "2026-06-18T00:00:00Z" }
      ] }
    """#

    func test_createMeal_postsMappedBodyAndDecodes() async throws {
        var captured: URLRequest?
        let (client, stub) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data(Self.mealJSON.utf8))
        }
        let cfid = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let item = NewMealItem(
            id: UUID(), displayName: "Chicken", quantityText: "150 g",
            normalizedQuantityValue: 150, normalizedQuantityUnit: "g",
            usdaFdcId: nil, usdaDescription: nil, customFoodId: cfid,
            calories: 250, proteinG: 40, carbsG: 0, fatG: 9)

        let meal = try await client.createMeal(name: "Lunch", items: [item])

        XCTAssertEqual(meal.name, "Lunch")
        XCTAssertEqual(meal.items.count, 1)
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/meals")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")

        let body = try XCTUnwrap(stub.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "Lunch")
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["display_name"] as? String, "Chicken")
        XCTAssertEqual(items[0]["quantity_text"] as? String, "150 g")
        XCTAssertEqual(items[0]["custom_food_id"] as? String, cfid.uuidString.lowercased())
        XCTAssertEqual(items[0]["calories"] as? Int, 250)
        XCTAssertNil(items[0]["id"])   // local id must not leak into the body
    }
}
