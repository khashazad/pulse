// PulseTests/FoodClientTests.swift
import XCTest
@testable import Pulse

/// Unit tests for the food-search client endpoints: USDA proxy search,
/// custom-foods list, food-memory list, and food-entry deletion.
final class FoodClientTests: XCTestCase {
    private var activeStubs: [StubURLProtocol.Registration] = []

    private func makeClient(responder: @escaping StubURLProtocol.Responder) -> PulseClient {
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        return PulseClient(baseURL: URL(string: "https://example.test")!, sessionToken: "session-k", session: stub.session)
    }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle(for: Self.self).url(forResource: name, withExtension: "json")!)
    }
    override func tearDown() { activeStubs.forEach { $0.invalidate() }; activeStubs = []; super.tearDown() }

    func test_searchUSDA_buildsQueryAndDecodes() async throws {
        let json = try fixture("usda_search")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let results = try await client.searchUSDA(query: "chicken breast", limit: 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(captured?.url?.path, "/usda/search")
        let q = captured?.url?.query ?? ""
        XCTAssertTrue(q.contains("q=chicken%20breast") || q.contains("q=chicken+breast"), "got \(q)")
        XCTAssertTrue(q.contains("limit=5"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
    }

    func test_listCustomFoods_decodesEnvelope() async throws {
        let json = try fixture("custom_foods")
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let foods = try await client.listCustomFoods()
        XCTAssertEqual(foods.count, 1)
        XCTAssertEqual(foods[0].name, "Protein Shake")
    }

    func test_listFoodMemory_decodesEnvelope() async throws {
        let json = try fixture("food_memory")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let entries = try await client.listFoodMemory()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(captured?.url?.path, "/food-memory")
    }

    func test_searchUSDA_429MapsToServer() async throws {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await client.searchUSDA(query: "x", limit: 5)
            XCTFail("expected error")
        } catch let e as PulseError {
            XCTAssertEqual(e, .server(status: 429))
        }
    }

    // MARK: - deleteEntry

    func test_deleteEntry_sendsDELETEAndAccepts204() async throws {
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        try await client.deleteEntry(id: id)

        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/entries/11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
    }

    func test_deleteEntry_404MapsToNotFound() async {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            try await client.deleteEntry(id: UUID())
            XCTFail("expected PulseError.notFound")
        } catch let error as PulseError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_deleteEntry_500MapsToServer() async {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            try await client.deleteEntry(id: UUID())
            XCTFail("expected PulseError.server")
        } catch let error as PulseError {
            XCTAssertEqual(error, .server(status: 500))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
