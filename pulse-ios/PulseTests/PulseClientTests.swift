/// Unit tests for the top-level `PulseClient` HTTP surface plus the
/// shared `StubURLProtocol` used across the networking test files.
/// `StubURLProtocol` lets tests register a closure that synthesizes
/// `(HTTPURLResponse, Data)` for any request; the test cases here exercise
/// the summary / logs / whoami / logout endpoints, including 401 → unauthorized
/// and 404 → notFound error mappings.
/// Part of the iOS app's networking test suite.
import XCTest
@testable import Pulse

/// In-process `URLProtocol` that satisfies every request using a scoped
/// responder closure. Tests register a responder per `URLSession` so async
/// networking tests do not share mutable response state.
final class StubURLProtocol: URLProtocol {
    typealias Responder = (URLRequest) -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static let stubHeader = "X-StubURLProtocol-ID"
    private static var scopedResponders: [String: Responder] = [:]
    private static var scopedRequestBodies: [String: Data] = [:]

    /// Test-owned registration for one stubbed `URLSession`.
    final class Registration {
        let session: URLSession
        private let id: String
        private var didInvalidate = false

        /// Creates a registration for one stubbed session id.
        /// - Parameters:
        ///   - id: `String` identifier attached to requests from the session.
        ///   - session: `URLSession` configured to use `StubURLProtocol`.
        /// - Returns: Nothing; initializes the registration.
        /// - Throws: None.
        fileprivate init(id: String, session: URLSession) {
            self.id = id
            self.session = session
        }

        /// Reads the most recent body sent through this registration.
        /// - Parameters: None.
        /// - Returns: `Data?` containing the last request body, or nil when no body was sent.
        /// - Throws: None.
        var lastRequestBody: Data? {
            StubURLProtocol.lastRequestBody(for: id)
        }

        /// Removes this registration's responder and invalidates its session.
        /// - Parameters: None.
        /// - Returns: Nothing.
        /// - Throws: None.
        func invalidate() {
            guard !didInvalidate else { return }
            didInvalidate = true
            session.invalidateAndCancel()
            StubURLProtocol.removeRegistration(id)
        }

        /// Cleans up the registration if the owning test did not invalidate it.
        /// - Parameters: None.
        /// - Returns: Nothing.
        /// - Throws: None.
        deinit {
            invalidate()
        }
    }

    /// Builds an ephemeral session with its own responder and body capture.
    /// - Parameters:
    ///   - responder: `Responder` closure that synthesizes an HTTP response for the session's requests.
    /// - Returns: `Registration` containing the configured session and scoped body access.
    /// - Throws: None.
    static func makeSession(responder: @escaping Responder) -> Registration {
        let id = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = [stubHeader: id]
        withLock {
            scopedResponders[id] = responder
            scopedRequestBodies.removeValue(forKey: id)
        }
        return Registration(id: id, session: URLSession(configuration: config))
    }

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

    /// Invokes this session's registered responder and pipes the synthesized
    /// response through the URL loading system.
    /// - Parameters: None.
    /// - Returns: Nothing.
    /// - Throws: None.
    override func startLoading() {
        let body = Self.drainBody(request)
        let (responder, responderRequest) = Self.responder(for: request, body: body)
        guard let responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(responderRequest)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Handles cancellation for a request that normally completes synchronously.
    /// - Parameters: None.
    /// - Returns: Nothing.
    /// - Throws: None.
    override func stopLoading() {}

    /// Drains a request's body into `Data`, handling both the direct
    /// `httpBody` path and the more common `httpBodyStream` path that
    /// `URLSession` produces for outgoing uploads.
    /// - Parameters:
    ///   - request: `URLRequest` whose body should be captured.
    /// - Returns: `Data?` containing request body bytes, or nil when the request has no body.
    /// - Throws: None.
    private static func drainBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buf.deallocate() }
        while true {
            let read = stream.read(buf, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data.isEmpty ? nil : data
    }

    /// Runs a closure while holding the protocol's shared lock.
    /// - Parameters:
    ///   - body: `() -> T` closure to execute under mutual exclusion.
    /// - Returns: `T` value returned by `body`.
    /// - Throws: None.
    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Finds the scoped responder for a request and records its body.
    /// - Parameters:
    ///   - request: `URLRequest` received by the protocol.
    ///   - body: `Data?` body captured from the request before routing.
    /// - Returns: Tuple containing the matched `Responder?` and a request with stub routing headers removed.
    /// - Throws: None.
    private static func responder(for request: URLRequest, body: Data?) -> (Responder?, URLRequest) {
        guard let id = request.value(forHTTPHeaderField: stubHeader) else {
            return (nil, request)
        }
        var responderRequest = request
        responderRequest.setValue(nil, forHTTPHeaderField: stubHeader)
        let responder = withLock { () -> Responder? in
            if let body {
                scopedRequestBodies[id] = body
            } else {
                scopedRequestBodies.removeValue(forKey: id)
            }
            return scopedResponders[id]
        }
        return (responder, responderRequest)
    }

    /// Reads the last body captured for a scoped registration id.
    /// - Parameters:
    ///   - id: `String` registration identifier.
    /// - Returns: `Data?` containing the last body for the registration, or nil.
    /// - Throws: None.
    private static func lastRequestBody(for id: String) -> Data? {
        withLock { scopedRequestBodies[id] }
    }

    /// Removes all state associated with a scoped registration id.
    /// - Parameters:
    ///   - id: `String` registration identifier to remove.
    /// - Returns: Nothing.
    /// - Throws: None.
    private static func removeRegistration(_ id: String) {
        withLock {
            scopedResponders.removeValue(forKey: id)
            scopedRequestBodies.removeValue(forKey: id)
        }
    }
}

final class PulseClientTests: XCTestCase {
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
    /// Outputs: raw bytes of `<name>.json`.
    /// Exceptions: throws if the fixture cannot be read.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    /// Builds a `PulseClient` against the stub URL with a fixed bearer.
    /// Inputs:
    ///   - responder: closure that returns a stubbed HTTP response.
    /// Outputs: a `PulseClient`.
    private func makeClient(responder: @escaping StubURLProtocol.Responder) -> PulseClient {
        PulseClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-abc",
            session: makeSession(responder: responder)
        )
    }

    /// Clears scoped `StubURLProtocol` registrations between tests.
    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        super.tearDown()
    }

    /// Verifies `summary(date:)` hits `/summary/<date>` with a bearer header,
    /// no `X-API-Key`, and no query string, and decodes the fixture.
    func testSummaryRequestSendsBearerAndNoUserKey() async throws {
        let summaryJSON = try loadFixture("summary")
        var capturedRequest: URLRequest?
        let client = makeClient { req in
            capturedRequest = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, summaryJSON)
        }

        let date = DateOnly.formatter.date(from: "2026-05-06")!
        let summary = try await client.summary(date: date)

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
        let client = makeClient { req in
            capturedURL = req.url
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, logsJSON)
        }
        let from = DateOnly.formatter.date(from: "2026-04-30")!
        let to = DateOnly.formatter.date(from: "2026-05-06")!
        let list = try await client.logs(from: from, to: to)

        XCTAssertEqual(list.logs.count, 7)
        XCTAssertEqual(capturedURL?.path, "/logs")
        let q = capturedURL?.query ?? ""
        XCTAssertTrue(q.contains("from=2026-04-30"))
        XCTAssertTrue(q.contains("to=2026-05-06"))
        XCTAssertFalse(q.contains("user_key"))
    }

    /// Verifies a 401 status maps to `PulseError.unauthorized`.
    func test401MapsToUnauthorized() async throws {
        let client = makeClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-06")!
        do {
            _ = try await client.summary(date: date)
            XCTFail("Expected unauthorized error")
        } catch let error as PulseError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    /// Verifies a 404 status maps to `PulseError.notFound`.
    func test404MapsToNotFound() async throws {
        let client = makeClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-06")!
        do {
            _ = try await client.summary(date: date)
            XCTFail("Expected notFound error")
        } catch let error as PulseError {
            XCTAssertEqual(error, .notFound)
        }
    }

    /// Verifies `whoami()` calls `/auth/whoami` with the bearer header and
    /// decodes the response email.
    func testWhoAmIDecodes() async throws {
        let whoami = try loadFixture("whoami")
        var capturedURL: URL?
        var capturedAuth: String?
        let client = makeClient { req in
            capturedURL = req.url
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, whoami)
        }
        let result = try await client.whoami()
        XCTAssertEqual(result.email, "khashzd@gmail.com")
        XCTAssertEqual(capturedURL?.path, "/auth/whoami")
        XCTAssertEqual(capturedAuth, "Bearer session-abc")
    }

    /// Verifies `logout()` POSTs to `/auth/logout` with the bearer header.
    func testLogoutSendsPostWithBearer() async throws {
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        try await client.logout()
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/auth/logout")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-abc")
    }

    /// Verifies concurrently active stubbed sessions route requests to their
    /// own responders instead of sharing one static response source.
    func testScopedStubSessionsDoNotShareRespondersWhenConcurrent() async throws {
        let summaryJSON = try loadFixture("summary")
        let whoamiJSON = try loadFixture("whoami")
        let summaryStub = StubURLProtocol.makeSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, summaryJSON)
        }
        let whoamiStub = StubURLProtocol.makeSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, whoamiJSON)
        }
        defer {
            summaryStub.invalidate()
            whoamiStub.invalidate()
        }

        let summaryClient = PulseClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "summary-token",
            session: summaryStub.session
        )
        let whoamiClient = PulseClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "whoami-token",
            session: whoamiStub.session
        )
        let date = DateOnly.formatter.date(from: "2026-05-06")!

        async let summary = summaryClient.summary(date: date)
        async let whoami = whoamiClient.whoami()

        let (summaryResult, whoamiResult) = try await (summary, whoami)
        XCTAssertEqual(summaryResult.target.calories, 2200)
        XCTAssertEqual(whoamiResult.email, "khashzd@gmail.com")
    }
}
