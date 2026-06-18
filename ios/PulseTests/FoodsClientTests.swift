// PulseTests/FoodsClientTests.swift
import XCTest
@testable import Pulse

/// Unit tests for the grouped-foods client endpoints.
final class FoodsClientTests: XCTestCase {
    private var activeStubs: [StubURLProtocol.Registration] = []

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

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// Decodes a captured registration body into a JSON object dictionary.
    /// Inputs:
    ///   - stub: the registration whose last request body should be read.
    /// Outputs: the body parsed as `[String: Any]`.
    /// Exceptions: if no body was captured or it is not a JSON object.
    private func bodyObject(_ stub: StubURLProtocol.Registration) throws -> [String: Any] {
        let data = try XCTUnwrap(stub.lastRequestBody, "no request body captured")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let foodJSON = #"""
    { "id": "11111111-1111-1111-1111-111111111111", "user_key": "khash",
      "name": "Apple", "normalized_name": "apple", "notes": null,
      "default_portion_id": "33333333-3333-3333-3333-333333333333",
      "aliases": [], "portions": [], "created_at": "2026-06-16T00:00:00Z",
      "updated_at": "2026-06-16T00:00:00Z" }
    """#

    func test_listFoods_getsAndDecodes() async throws {
        var captured: URLRequest?
        let body = try fixture("foods")
        let (client, _) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let list = try await client.listFoods()
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.url?.path, "/foods")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
        XCTAssertEqual(list.foods.count, 1)
        XCTAssertEqual(list.standalones.count, 1)
    }

    func test_createFood_postsGroupingBody() async throws {
        var captured: URLRequest?
        let (client, stub) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data(Self.foodJSON.utf8))
        }
        let p1 = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let food = try await client.createFood(
            name: "Apple", portionIds: [p1], defaultPortionId: p1,
            portionLabels: [p1: "medium"], aliases: ["apples"])
        XCTAssertEqual(food.name, "Apple")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/foods")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
        let body = try bodyObject(stub)
        XCTAssertEqual(body["name"] as? String, "Apple")
        XCTAssertEqual((body["portion_ids"] as? [String])?.count, 1)
        XCTAssertEqual((body["portion_labels"] as? [String: String])?[p1.uuidString.lowercased()], "medium")
    }

    func test_ungroupFood_sendsDELETE() async throws {
        var captured: URLRequest?
        let (client, _) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        try await client.ungroupFood(id: id)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/foods/11111111-1111-1111-1111-111111111111")
    }

    func test_removePortion_sendsDELETEAndDecodes() async throws {
        var captured: URLRequest?
        let (client, _) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(Self.foodJSON.utf8))
        }
        let fid = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let cfid = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let food = try await client.removePortion(foodId: fid, customFoodId: cfid)
        XCTAssertEqual(food.name, "Apple")
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/foods/11111111-1111-1111-1111-111111111111/portions/33333333-3333-3333-3333-333333333333")
    }
}
