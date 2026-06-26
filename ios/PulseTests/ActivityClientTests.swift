import XCTest
@testable import Pulse

final class ActivityClientTests: XCTestCase {
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

    /// Loads a JSON fixture from the test bundle by name.
    /// Inputs:
    ///   - name: fixture file base name (without extension).
    /// Outputs: raw `Data` bytes of the fixture file.
    /// Exceptions: throws via `XCTUnwrap` if the fixture is not found, or if reading the file fails.
    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// Builds a `PulseClient` against the stub URL with a fixed bearer token.
    /// Inputs:
    ///   - responder: closure that returns a stubbed HTTP response.
    /// Outputs: a `PulseClient` configured for stubbed network traffic.
    private func makeClient(responder: @escaping StubURLProtocol.Responder) -> PulseClient {
        PulseClient(baseURL: URL(string: "https://example.test")!, sessionToken: "session-k",
                    session: makeSession(responder: responder))
    }

    /// Clears scoped `StubURLProtocol` registrations between tests.
    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        super.tearDown()
    }

    /// Verifies `activityWorkouts(before:beforeId:type:limit:)` encodes the cursor, type, and limit in the query string and sends the bearer header.
    func testWorkoutsSendsCursorAndType() async throws {
        let json = try loadFixture("activity_feed_page")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let page = try await client.activityWorkouts(
            before: "2026-06-23T12:00:00+00:00",
            beforeId: "aaaaaaaa-0000-0000-0000-000000000002",
            type: "Running", limit: 50)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(captured?.url?.path, "/activity/workouts")
        let query = captured?.url?.query ?? ""
        XCTAssertTrue(query.contains("before=2026-06-23T12"))
        XCTAssertTrue(query.contains("before_id=aaaaaaaa-0000-0000-0000-000000000002"))
        XCTAssertTrue(query.contains("type=Running"))
        XCTAssertTrue(query.contains("limit=50"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
    }

    /// Verifies `activityWorkouts(before:beforeId:type:)` omits nil cursor and type parameters from the query string.
    func testWorkoutsOmitsNilParams() async throws {
        let json = try loadFixture("activity_feed_page")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        _ = try await client.activityWorkouts(before: nil, beforeId: nil, type: nil)
        let query = captured?.url?.query ?? ""
        XCTAssertFalse(query.contains("before="))
        XCTAssertFalse(query.contains("type="))
        XCTAssertTrue(query.contains("limit=50"))
    }

    /// Verifies `activityWorkoutDetail(id:)` requests the correct `/activity/workouts/<id>` path and decodes the response.
    func testWorkoutDetailPath() async throws {
        let json = try loadFixture("activity_workout_detail")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let id = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
        let detail = try await client.activityWorkoutDetail(id: id)
        XCTAssertEqual(detail.exercises.count, 1)
        XCTAssertEqual(captured?.url?.path, "/activity/workouts/aaaaaaaa-0000-0000-0000-000000000001")
    }

    /// Verifies `activitySummary(period:anchor:)` sends `period` and `anchor` as query parameters on `/activity/summary` and decodes the response.
    func testSummarySendsPeriodAndAnchor() async throws {
        let json = try loadFixture("activity_summary")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let anchor = DateOnly.formatter.date(from: "2026-06-25")!
        let summary = try await client.activitySummary(period: .week, anchor: anchor)
        XCTAssertEqual(summary.totals.workoutCount, 48)
        XCTAssertEqual(captured?.url?.path, "/activity/summary")
        let query = captured?.url?.query ?? ""
        XCTAssertTrue(query.contains("period=week"))
        XCTAssertTrue(query.contains("anchor=2026-06-25"))
    }

    /// Verifies a 404 response from `activityWorkoutDetail(id:)` maps to `PulseError.notFound`.
    func testDetail404MapsToNotFound() async throws {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await client.activityWorkoutDetail(id: UUID())
            XCTFail("expected notFound")
        } catch let error as PulseError {
            XCTAssertEqual(error, .notFound)
        }
    }

    /// Verifies `activityTypes()` sends a GET to `/activity/types` with the
    /// bearer header and decodes the `ActivityTypesResponse` correctly.
    func testActivityTypesSendsGetAndDecodes() async throws {
        let json = try loadFixture("activity_types")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let response = try await client.activityTypes()
        XCTAssertEqual(captured?.url?.path, "/activity/types")
        XCTAssertEqual(captured?.httpMethod ?? "GET", "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
        XCTAssertEqual(response.types.count, 2)
        XCTAssertEqual(response.types[0].activityType, "Running")
        XCTAssertTrue(response.types[0].isCardio)
        XCTAssertEqual(response.types[1].activityType, "TraditionalStrengthTraining")
        XCTAssertFalse(response.types[1].isCardio)
    }

    /// Verifies `setActivityTypeCardio(_:isCardio:)` sends a PUT to
    /// `/activity/types/<type>`, encodes `{"is_cardio": false}` in the body,
    /// and decodes the returned `ActivityTypeSetting`.
    func testSetActivityTypeCardioSendsPutWithBody() async throws {
        let settingJSON = Data("""
        {
          "activity_type": "TraditionalStrengthTraining",
          "display_name": "Traditional Strength Training",
          "count": 34,
          "is_cardio": false
        }
        """.utf8)
        var captured: URLRequest?
        let stub = StubURLProtocol.makeSession { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, settingJSON)
        }
        activeStubs.append(stub)
        let client = PulseClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-k",
            session: stub.session
        )
        let result = try await client.setActivityTypeCardio("TraditionalStrengthTraining", isCardio: false)
        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.path, "/activity/types/TraditionalStrengthTraining")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
        let bodyData = try XCTUnwrap(stub.lastRequestBody)
        let bodyJSON = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        XCTAssertEqual(bodyJSON?["is_cardio"] as? Bool, false)
        XCTAssertEqual(result.activityType, "TraditionalStrengthTraining")
        XCTAssertFalse(result.isCardio)
        XCTAssertEqual(result.count, 34)
    }

    /// Verifies `activityWeek(anchor:)` sends `GET /activity/week` with the
    /// `anchor` query parameter, attaches the bearer header, and decodes the
    /// response into a `WeekDetail` with the correct number of day groups.
    func testActivityWeekSendsAnchorAndDecodesWeekDetail() async throws {
        let json = try loadFixture("week_detail")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let anchor = DateOnly.formatter.date(from: "2026-06-24")!
        let detail = try await client.activityWeek(anchor: anchor)
        XCTAssertEqual(detail.dayGroups.count, 2)
        XCTAssertEqual(captured?.url?.path, "/activity/week")
        XCTAssertEqual(captured?.httpMethod ?? "GET", "GET")
        let query = captured?.url?.query ?? ""
        XCTAssertTrue(query.contains("anchor=2026-06-24"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
    }

    /// Verifies `setActivityTypeCardio(_:isCardio:)` returns `PulseError.notFound`
    /// when the server responds with 404 for an unknown activity type.
    func testSetActivityTypeCardio404MapsToNotFound() async throws {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await client.setActivityTypeCardio("Unknown", isCardio: true)
            XCTFail("expected notFound")
        } catch let error as PulseError {
            XCTAssertEqual(error, .notFound)
        }
    }
}
