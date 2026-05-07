import XCTest
@testable import Nutrition

final class StubURLProtocol: URLProtocol {
    static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

    override func stopLoading() {}
}

final class NutritionClientTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func testSummaryRequestSendsApiKeyAndUserKey() async throws {
        let summaryJSON = try loadFixture("summary")
        var capturedRequest: URLRequest?
        StubURLProtocol.responder = { req in
            capturedRequest = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, summaryJSON)
        }

        let client = NutritionClient(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "secret-key",
            session: makeSession()
        )

        let date = DateOnly.formatter.date(from: "2026-05-06")!
        let summary = try await client.summary(date: date)

        XCTAssertEqual(summary.target.calories, 2200)
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-API-Key"), "secret-key")
        XCTAssertEqual(capturedRequest?.url?.path, "/summary/2026-05-06")
        XCTAssertEqual(capturedRequest?.url?.query, "user_key=khash")
    }

    func testLogsRequestUsesFromAndToParams() async throws {
        let logsJSON = try loadFixture("logs")
        var capturedURL: URL?
        StubURLProtocol.responder = { req in
            capturedURL = req.url
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, logsJSON)
        }

        let client = NutritionClient(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "k",
            session: makeSession()
        )
        let from = DateOnly.formatter.date(from: "2026-04-30")!
        let to = DateOnly.formatter.date(from: "2026-05-06")!
        let list = try await client.logs(from: from, to: to)

        XCTAssertEqual(list.logs.count, 7)
        XCTAssertEqual(capturedURL?.path, "/logs")
        let q = capturedURL?.query ?? ""
        XCTAssertTrue(q.contains("from=2026-04-30"))
        XCTAssertTrue(q.contains("to=2026-05-06"))
        XCTAssertTrue(q.contains("user_key=khash"))
    }

    func test401MapsToUnauthorized() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = NutritionClient(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "k",
            session: makeSession()
        )
        let date = DateOnly.formatter.date(from: "2026-05-06")!
        do {
            _ = try await client.summary(date: date)
            XCTFail("Expected unauthorized error")
        } catch let error as NutritionError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func test404MapsToNotFound() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = NutritionClient(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "k",
            session: makeSession()
        )
        let date = DateOnly.formatter.date(from: "2026-05-06")!
        do {
            _ = try await client.summary(date: date)
            XCTFail("Expected notFound error")
        } catch let error as NutritionError {
            XCTAssertEqual(error, .notFound)
        }
    }
}
