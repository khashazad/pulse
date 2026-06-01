// PulseTests/EntryWriteClientTests.swift
import XCTest
@testable import Pulse

/// Unit tests for the food-entry write endpoints: batch entry creation
/// (`POST /entries`) and saved-meal logging (`POST /meals/{id}/log`). Covers
/// backdated `consumed_at` encoding (naive wall-clock, no timezone) and
/// response decoding into `EntryWriteResponse`.
final class EntryWriteClientTests: XCTestCase {
    private var activeStubs: [StubURLProtocol.Registration] = []

    /// Builds a client together with its stub registration so a test can read
    /// the captured outgoing request body via `Registration.lastRequestBody`.
    /// - Parameters:
    ///   - responder: closure that synthesizes the stubbed HTTP response.
    /// - Returns: the `PulseClient` and the owning `StubURLProtocol.Registration`.
    private func makeClient(
        responder: @escaping StubURLProtocol.Responder
    ) -> (PulseClient, StubURLProtocol.Registration) {
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        let client = PulseClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-k",
            session: stub.session
        )
        return (client, stub)
    }

    /// Loads a JSON fixture from the test bundle.
    /// - Parameters:
    ///   - name: fixture file base name (without extension).
    /// - Returns: the raw bytes of `<name>.json`.
    /// - Throws: if the fixture is missing or unreadable.
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle(for: Self.self).url(forResource: name, withExtension: "json")!)
    }

    /// Builds a `Date` at local noon for the given `YYYY-MM-DD`. Noon avoids
    /// day rollover when the value is formatted as a naive wall-clock datetime,
    /// regardless of the device timezone.
    /// - Parameters:
    ///   - ymd: the calendar day in `YYYY-MM-DD` form.
    /// - Returns: a `Date` at noon of that local day.
    private func noon(_ ymd: String) -> Date {
        let midnight = DateOnly.formatter.date(from: ymd)!
        return Calendar.current.date(byAdding: .hour, value: 12, to: midnight)!
    }

    /// Decodes a captured request body into a JSON object dictionary.
    /// - Parameters:
    ///   - stub: the registration whose last request body should be read.
    /// - Returns: the body parsed as `[String: Any]`.
    /// - Throws: if no body was captured or it is not a JSON object.
    private func bodyObject(_ stub: StubURLProtocol.Registration) throws -> [String: Any] {
        let data = try XCTUnwrap(stub.lastRequestBody, "no request body captured")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        super.tearDown()
    }

    func test_createEntries_postsBatchWithNaiveConsumedAt() async throws {
        let json = try fixture("entries_create")
        var captured: URLRequest?
        let (client, stub) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, json)
        }

        let item = FoodEntryCreate.usda(
            displayName: "white rice",
            quantityText: "1 cup",
            fdcId: 169756,
            usdaDescription: "Rice, white, cooked",
            calories: 205,
            proteinG: 4.3,
            carbsG: 44.5,
            fatG: 0.4,
            consumedAt: noon("2026-05-30")
        )
        let resp = try await client.createEntries([item])

        // Response decodes into the shared write envelope.
        XCTAssertEqual(resp.entries.count, 1)
        XCTAssertEqual(resp.entries[0].displayName, "white rice")
        XCTAssertEqual(resp.dailyTotals.calories, 205)

        // Request shape: POST /entries with bearer auth.
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/entries")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")

        // Body: batch envelope, naive wall-clock consumed_at, USDA source only.
        let obj = try bodyObject(stub)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let consumed = try XCTUnwrap(items[0]["consumed_at"] as? String)
        XCTAssertEqual(consumed, "2026-05-30T12:00:00")
        XCTAssertFalse(consumed.contains("Z"), "consumed_at must be naive wall-clock, got \(consumed)")
        XCTAssertEqual(items[0]["usda_fdc_id"] as? Int, 169756)
        XCTAssertEqual(items[0]["display_name"] as? String, "white rice")
        XCTAssertNil(items[0]["custom_food_id"], "USDA-sourced entry must omit custom_food_id")
    }

    func test_createEntries_customSourceOmitsUsdaFields() async throws {
        let json = try fixture("entries_create")
        let (client, stub) = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, json)
        }
        let customId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let item = FoodEntryCreate.custom(
            displayName: "Protein Shake",
            quantityText: "1 scoop",
            customFoodId: customId,
            calories: 130,
            proteinG: 25.0,
            carbsG: 3.0,
            fatG: 1.5
        )
        _ = try await client.createEntries([item])

        let obj = try bodyObject(stub)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["custom_food_id"] as? String, customId.uuidString.uppercased())
        XCTAssertNil(items[0]["usda_fdc_id"], "custom-sourced entry must omit usda_fdc_id")
        XCTAssertNil(items[0]["usda_description"])
        XCTAssertNil(items[0]["consumed_at"], "nil consumedAt must omit the key")
    }

    func test_logMeal_postsConsumedAtAndDecodes() async throws {
        let json = try fixture("meal_log")
        var captured: URLRequest?
        let (client, stub) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let mealId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let resp = try await client.logMeal(id: mealId, consumedAt: noon("2026-05-29"))

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/meals/11111111-1111-1111-1111-111111111111/log")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
        XCTAssertEqual(resp.entries.count, 2)
        XCTAssertEqual(resp.dailyTotals.calories, 234)

        let obj = try bodyObject(stub)
        XCTAssertEqual(obj["consumed_at"] as? String, "2026-05-29T12:00:00")
    }

    func test_logMeal_nilConsumedAtOmitsKey() async throws {
        let json = try fixture("meal_log")
        let (client, stub) = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let mealId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        _ = try await client.logMeal(id: mealId, consumedAt: nil)

        let obj = try bodyObject(stub)
        XCTAssertNil(obj["consumed_at"], "nil consumedAt must omit the key from the body")
    }
}
