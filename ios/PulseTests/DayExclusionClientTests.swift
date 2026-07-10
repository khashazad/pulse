// PulseTests/DayExclusionClientTests.swift
import XCTest
@testable import Pulse

/// Unit tests for the day-exclusion endpoint (`PUT /logs/{date}/excluded`):
/// request shape (method, path, bearer auth, JSON body) and response decoding
/// into `DailySummary` with the `excluded` flag populated.
final class DayExclusionClientTests: XCTestCase {
    private var activeStubs: [StubURLProtocol.Registration] = []

    /// Builds a client together with its stub registration so a test can read
    /// the captured outgoing request body.
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

    /// A day at local noon for the given `YYYY-MM-DD`, avoiding day rollover.
    /// - Parameters:
    ///   - ymd: the calendar day in `YYYY-MM-DD` form.
    /// - Returns: a `Date` at noon of that local day.
    private func noon(_ ymd: String) -> Date {
        let midnight = DateOnly.formatter.date(from: ymd)!
        return Calendar.current.date(byAdding: .hour, value: 12, to: midnight)!
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        super.tearDown()
    }

    /// A minimal `DailySummary` JSON body with the day marked excluded.
    private func summaryJSON(excluded: Bool) -> Data {
        """
        {
          "date": "2026-05-06",
          "target": {"calories": 2200, "protein_g": 150.0, "carbs_g": 250.0, "fat_g": 70.0},
          "consumed": {"calories": 0, "protein_g": 0.0, "carbs_g": 0.0, "fat_g": 0.0},
          "remaining": {"calories": 2200, "protein_g": 150.0, "carbs_g": 250.0, "fat_g": 70.0},
          "entries": [],
          "excluded": \(excluded)
        }
        """.data(using: .utf8)!
    }

    func test_setDayExcluded_putsFlagAndDecodesSummary() async throws {
        var captured: URLRequest?
        let (client, stub) = makeClient { req in
            captured = req
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                self.summaryJSON(excluded: true)
            )
        }

        let summary = try await client.setDayExcluded(date: noon("2026-05-06"), excluded: true)

        // Request shape: PUT /logs/{date}/excluded with bearer auth.
        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.path, "/logs/2026-05-06/excluded")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")

        // Body: {"excluded": true}.
        let data = try XCTUnwrap(stub.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["excluded"] as? Bool, true)

        // Response decodes with the flag set.
        XCTAssertTrue(summary.excluded)
    }

    func test_setDayExcluded_encodesFalseToClear() async throws {
        let (client, stub) = makeClient { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                self.summaryJSON(excluded: false)
            )
        }

        let summary = try await client.setDayExcluded(date: noon("2026-05-06"), excluded: false)

        let data = try XCTUnwrap(stub.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["excluded"] as? Bool, false)
        XCTAssertFalse(summary.excluded)
    }
}
