/// Unit tests for the top-level `DietTrackerClient` HTTP surface plus the
/// shared `StubURLProtocol` used across the networking test files.
/// `StubURLProtocol` lets tests register a closure that synthesizes
/// `(HTTPURLResponse, Data)` for any request; the test cases here exercise
/// the summary / logs / whoami / logout endpoints, including 401 → unauthorized
/// and 404 → notFound error mappings.
/// Part of the iOS app's networking test suite.
import XCTest
@testable import DietTracker

/// In-process `URLProtocol` that satisfies every request using a static
/// `responder` closure. Tests register a responder and any request made
/// through the configured `URLSession` is intercepted.
final class StubURLProtocol: URLProtocol {
    static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    /// Always claims every request so the protocol is always selected.
    /// Inputs:
    ///   - request: the request to evaluate.
    /// Outputs: true.
    override class func canInit(with request: URLRequest) -> Bool { true }
    /// Returns the request unchanged.
    /// Inputs:
    ///   - request: the request to canonicalize.
    /// Outputs: the same request.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Invokes the registered responder and pipes the synthesized response
    /// and data back through the URL loading system. Fails the request with
    /// `URLError(.badServerResponse)` if no responder is registered.
    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// No-op cancellation hook; the stub completes synchronously.
    override func stopLoading() {}
}

final class DietTrackerClientTests: XCTestCase {

    /// Builds an ephemeral `URLSession` wired to `StubURLProtocol`.
    /// Outputs: a fresh `URLSession` for stubbed HTTP traffic.
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Loads a JSON fixture from the test bundle.
    /// Inputs:
    ///   - name: fixture file base name.
    /// Outputs: raw bytes of `<name>.json`.
    /// Exceptions: throws if the fixture cannot be read.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    /// Builds a `DietTrackerClient` against the stub URL with a fixed bearer.
    /// Outputs: a `DietTrackerClient`.
    private func makeClient() -> DietTrackerClient {
        DietTrackerClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-abc",
            session: makeSession()
        )
    }

    /// Clears the shared `StubURLProtocol` responder between tests.
    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    /// Verifies `summary(date:)` hits `/summary/<date>` with a bearer header,
    /// no `X-API-Key`, and no query string, and decodes the fixture.
    func testSummaryRequestSendsBearerAndNoUserKey() async throws {
        let summaryJSON = try loadFixture("summary")
        var capturedRequest: URLRequest?
        StubURLProtocol.responder = { req in
            capturedRequest = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, summaryJSON)
        }

        let date = DateOnly.formatter.date(from: "2026-05-06")!
        let summary = try await makeClient().summary(date: date)

        XCTAssertEqual(summary.target.calories, 2200)
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer session-abc")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertEqual(capturedRequest?.url?.path, "/summary/2026-05-06")
        XCTAssertNil(capturedRequest?.url?.query)
    }

    /// Verifies `logs(from:to:)` sends `from` and `to` query parameters in
    /// `YYYY-MM-DD` form and omits `user_key`.
    func testLogsRequestUsesFromAndToParamsWithoutUserKey() async throws {
        let logsJSON = try loadFixture("logs")
        var capturedURL: URL?
        StubURLProtocol.responder = { req in
            capturedURL = req.url
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, logsJSON)
        }
        let from = DateOnly.formatter.date(from: "2026-04-30")!
        let to = DateOnly.formatter.date(from: "2026-05-06")!
        let list = try await makeClient().logs(from: from, to: to)

        XCTAssertEqual(list.logs.count, 7)
        XCTAssertEqual(capturedURL?.path, "/logs")
        let q = capturedURL?.query ?? ""
        XCTAssertTrue(q.contains("from=2026-04-30"))
        XCTAssertTrue(q.contains("to=2026-05-06"))
        XCTAssertFalse(q.contains("user_key"))
    }

    /// Verifies a 401 status maps to `DietTrackerError.unauthorized`.
    func test401MapsToUnauthorized() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-06")!
        do {
            _ = try await makeClient().summary(date: date)
            XCTFail("Expected unauthorized error")
        } catch let error as DietTrackerError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    /// Verifies a 404 status maps to `DietTrackerError.notFound`.
    func test404MapsToNotFound() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-06")!
        do {
            _ = try await makeClient().summary(date: date)
            XCTFail("Expected notFound error")
        } catch let error as DietTrackerError {
            XCTAssertEqual(error, .notFound)
        }
    }

    /// Verifies `whoami()` calls `/auth/whoami` with the bearer header and
    /// decodes the response email.
    func testWhoAmIDecodes() async throws {
        let whoami = try loadFixture("whoami")
        var capturedURL: URL?
        var capturedAuth: String?
        StubURLProtocol.responder = { req in
            capturedURL = req.url
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, whoami)
        }
        let result = try await makeClient().whoami()
        XCTAssertEqual(result.email, "khashzd@gmail.com")
        XCTAssertEqual(capturedURL?.path, "/auth/whoami")
        XCTAssertEqual(capturedAuth, "Bearer session-abc")
    }

    /// Verifies `logout()` POSTs to `/auth/logout` with the bearer header.
    func testLogoutSendsPostWithBearer() async throws {
        var captured: URLRequest?
        StubURLProtocol.responder = { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        try await makeClient().logout()
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/auth/logout")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-abc")
    }
}
