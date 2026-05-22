/// Unit tests for `DietTrackerClient` weight + daily-calories endpoints.
/// Covers `/weight` list-with-range, `/weight/<date>` upsert in both lb and
/// kg units, delete, `/calories/daily`, and the 404 → notFound mapping for
/// missing single-day weight reads.
/// Part of the iOS app's networking test suite.
import XCTest
@testable import DietTracker

final class WeightClientTests: XCTestCase {
    private var activeStubs: [StubURLProtocol.Registration] = []

    /// Builds an ephemeral `URLSession` wired to a scoped `StubURLProtocol` responder.
    /// Inputs:
    ///   - responder: closure that returns a stubbed HTTP response.
    /// Outputs: a fresh `URLSession` for stubbed HTTP traffic.
    private func makeSession(responder: @escaping StubURLProtocol.Responder) -> URLSession {
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        return stub.session
    }

    /// Loads a JSON fixture from the test bundle.
    /// Inputs:
    ///   - name: fixture file base name.
    /// Outputs: raw bytes, or empty `Data` if the fixture is missing.
    /// Exceptions: throws if reading the fixture's bytes fails.
    private func loadFixture(_ name: String) throws -> Data {
        Bundle(for: Self.self).url(forResource: name, withExtension: "json").flatMap {
            try? Data(contentsOf: $0)
        } ?? Data()
    }

    /// Builds a `DietTrackerClient` against the stub URL with a fixed bearer.
    /// Inputs:
    ///   - responder: closure that returns a stubbed HTTP response.
    /// Outputs: a `DietTrackerClient`.
    private func makeClient(responder: @escaping StubURLProtocol.Responder) -> DietTrackerClient {
        DietTrackerClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-k",
            session: makeSession(responder: responder)
        )
    }

    /// Clears scoped `StubURLProtocol` registrations between tests.
    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        super.tearDown()
    }

    /// Verifies `listWeightEntries(from:to:)` hits `/weight` with both range
    /// parameters and the bearer header.
    func testListWeightSendsRange() async throws {
        let json = try loadFixture("weight_entries")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let from = DateOnly.formatter.date(from: "2026-05-01")!
        let to = DateOnly.formatter.date(from: "2026-05-13")!
        let entries = try await client.listWeightEntries(from: from, to: to)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(captured?.url?.path, "/weight")
        let query = captured?.url?.query ?? ""
        XCTAssertTrue(query.contains("from=2026-05-01"))
        XCTAssertTrue(query.contains("to=2026-05-13"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
    }

    /// Verifies `upsertWeight` PUTs to `/weight/<date>` with `unit=lb` and
    /// the weight value in the body.
    func testUpsertWeightPostsLbBody() async throws {
        let json = try loadFixture("weight_entry")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        _ = try await client.upsertWeight(date: date, weight: 180.5, unit: .lb)
        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.path, "/weight/2026-05-13")
        let parsed = try JSONSerialization.jsonObject(with: activeStubs.last?.lastRequestBody ?? Data()) as? [String: Any]
        XCTAssertEqual(parsed?["unit"] as? String, "lb")
        XCTAssertEqual(parsed?["weight"] as? Double, 180.5)
    }

    /// Verifies `upsertWeight` sends `unit=kg` when the caller selects kg.
    func testUpsertWeightPostsKgBody() async throws {
        let json = try loadFixture("weight_entry")
        let client = makeClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        _ = try await client.upsertWeight(date: date, weight: 82, unit: .kg)
        let parsed = try JSONSerialization.jsonObject(with: activeStubs.last?.lastRequestBody ?? Data()) as? [String: Any]
        XCTAssertEqual(parsed?["unit"] as? String, "kg")
    }

    /// Verifies `deleteWeight` sends DELETE against `/weight/<date>`.
    func testDeleteWeightSendsDelete() async throws {
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        try await client.deleteWeight(date: date)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/weight/2026-05-13")
    }

    /// Verifies `fetchCaloriesDaily(from:to:)` decodes the per-day rows.
    func testFetchCaloriesDaily() async throws {
        let json = try loadFixture("calories_daily")
        let client = makeClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let from = DateOnly.formatter.date(from: "2026-05-01")!
        let to = DateOnly.formatter.date(from: "2026-05-13")!
        let rows = try await client.fetchCaloriesDaily(from: from, to: to)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].calories, 2100)
    }

    /// Verifies a 404 from `getWeight(date:)` maps to
    /// `DietTrackerError.notFound`.
    func testGetWeight404MapsToNotFound() async throws {
        let client = makeClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        do {
            _ = try await client.getWeight(date: date)
            XCTFail("expected throw")
        } catch DietTrackerError.notFound {
            // expected
        }
    }
}
