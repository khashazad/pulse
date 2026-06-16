// PulseTests/CustomFoodClientTests.swift
import XCTest
@testable import Pulse

/// Unit tests for the custom-food mutation endpoints: rename (PATCH) and delete.
final class CustomFoodClientTests: XCTestCase {
    private var activeStubs: [StubURLProtocol.Registration] = []

    /// Builds a stubbed client and its registration so tests can read the captured
    /// outgoing request body via `Registration.lastRequestBody`.
    /// Inputs:
    ///   - responder: closure returning the response + body for a request.
    /// Outputs: a `PulseClient` and the owning `StubURLProtocol.Registration`.
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

    /// Decodes a captured registration body into a JSON object dictionary.
    /// Inputs:
    ///   - stub: the registration whose last request body should be read.
    /// Outputs: the body parsed as `[String: Any]`.
    /// Exceptions: if no body was captured or it is not a JSON object.
    private func bodyObject(_ stub: StubURLProtocol.Registration) throws -> [String: Any] {
        let data = try XCTUnwrap(stub.lastRequestBody, "no request body captured")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        super.tearDown()
    }

    private static let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private static let updatedJSON = #"""
    { "id": "22222222-2222-2222-2222-222222222222", "name": "New Name", "basis": "per_serving", "serving_size": 1.0, "serving_size_unit": "scoop", "calories": 130, "protein_g": 25.0, "carbs_g": 3.0, "fat_g": 1.5 }
    """#

    func test_updateCustomFood_sendsPATCHAndDecodes() async throws {
        var captured: URLRequest?
        let (client, stub) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(Self.updatedJSON.utf8))
        }

        let food = try await client.updateCustomFood(id: Self.id, name: "New Name")

        XCTAssertEqual(food.name, "New Name")
        XCTAssertEqual(captured?.httpMethod, "PATCH")
        XCTAssertEqual(captured?.url?.path, "/custom-foods/22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
        let obj = try bodyObject(stub)
        XCTAssertEqual(obj["name"] as? String, "New Name")
    }

    func test_updateCustomFood_409MapsToServerConflict() async {
        let (client, _) = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await client.updateCustomFood(id: Self.id, name: "Dup")
            XCTFail("expected error")
        } catch let e as PulseError {
            XCTAssertEqual(e, .server(status: 409))
        } catch { XCTFail("unexpected: \(error)") }
    }

    func test_deleteCustomFood_sendsDELETEAndAccepts204() async throws {
        var captured: URLRequest?
        let (client, _) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await client.deleteCustomFood(id: Self.id)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/custom-foods/22222222-2222-2222-2222-222222222222")
    }

    func test_deleteCustomFood_409MapsToServerConflict() async {
        let (client, _) = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            try await client.deleteCustomFood(id: Self.id)
            XCTFail("expected error")
        } catch let e as PulseError {
            XCTAssertEqual(e, .server(status: 409))
        } catch { XCTFail("unexpected: \(error)") }
    }

    func test_deleteCustomFood_404MapsToNotFound() async {
        let (client, _) = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            try await client.deleteCustomFood(id: Self.id)
            XCTFail("expected error")
        } catch let e as PulseError {
            XCTAssertEqual(e, .notFound)
        } catch { XCTFail("unexpected: \(error)") }
    }
}
