import XCTest
@testable import Pulse

final class ActivityClientTests: XCTestCase {
    private var activeStubs: [StubURLProtocol.Registration] = []

    private func makeSession(responder: @escaping StubURLProtocol.Responder) -> URLSession {
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        return stub.session
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func makeClient(responder: @escaping StubURLProtocol.Responder) -> PulseClient {
        PulseClient(baseURL: URL(string: "https://example.test")!, sessionToken: "session-k",
                    session: makeSession(responder: responder))
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        super.tearDown()
    }

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

    func testSummarySendsPeriodAndAnchor() async throws {
        let json = try loadFixture("activity_summary")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let anchor = DateOnly.formatter.date(from: "2026-06-25")!
        let summary = try await client.activitySummary(period: .week, anchor: anchor)
        XCTAssertEqual(summary.totals.workoutCount, 4)
        XCTAssertEqual(captured?.url?.path, "/activity/summary")
        let query = captured?.url?.query ?? ""
        XCTAssertTrue(query.contains("period=week"))
        XCTAssertTrue(query.contains("anchor=2026-06-25"))
    }

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
}
