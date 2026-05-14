import XCTest
@testable import DietTracker

final class WeightClientTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func loadFixture(_ name: String) throws -> Data {
        Bundle(for: Self.self).url(forResource: name, withExtension: "json").flatMap {
            try? Data(contentsOf: $0)
        } ?? Data()
    }

    private func makeClient() -> DietTrackerClient {
        DietTrackerClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-k",
            session: makeSession()
        )
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func testListWeightSendsRange() async throws {
        let json = try loadFixture("weight_entries")
        var captured: URLRequest?
        StubURLProtocol.responder = { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let from = DateOnly.formatter.date(from: "2026-05-01")!
        let to = DateOnly.formatter.date(from: "2026-05-13")!
        let entries = try await makeClient().listWeightEntries(from: from, to: to)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(captured?.url?.path, "/weight")
        let query = captured?.url?.query ?? ""
        XCTAssertTrue(query.contains("from=2026-05-01"))
        XCTAssertTrue(query.contains("to=2026-05-13"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
    }

    func testUpsertWeightPostsLbBody() async throws {
        let json = try loadFixture("weight_entry")
        var captured: URLRequest?
        var body: Data?
        StubURLProtocol.responder = { req in
            captured = req
            body = req.bodyStreamData()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        _ = try await makeClient().upsertWeight(date: date, weight: 180.5, unit: .lb)
        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.path, "/weight/2026-05-13")
        let parsed = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        XCTAssertEqual(parsed?["unit"] as? String, "lb")
        XCTAssertEqual(parsed?["weight"] as? Double, 180.5)
    }

    func testUpsertWeightPostsKgBody() async throws {
        let json = try loadFixture("weight_entry")
        var body: Data?
        StubURLProtocol.responder = { req in
            body = req.bodyStreamData()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        _ = try await makeClient().upsertWeight(date: date, weight: 82, unit: .kg)
        let parsed = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        XCTAssertEqual(parsed?["unit"] as? String, "kg")
    }

    func testDeleteWeightSendsDelete() async throws {
        var captured: URLRequest?
        StubURLProtocol.responder = { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        try await makeClient().deleteWeight(date: date)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/weight/2026-05-13")
    }

    func testFetchCaloriesDaily() async throws {
        let json = try loadFixture("calories_daily")
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let from = DateOnly.formatter.date(from: "2026-05-01")!
        let to = DateOnly.formatter.date(from: "2026-05-13")!
        let rows = try await makeClient().fetchCaloriesDaily(from: from, to: to)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].calories, 2100)
    }

    func testGetWeight404MapsToNotFound() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        do {
            _ = try await makeClient().getWeight(date: date)
            XCTFail("expected throw")
        } catch DietTrackerError.notFound {
            // expected
        }
    }
}
