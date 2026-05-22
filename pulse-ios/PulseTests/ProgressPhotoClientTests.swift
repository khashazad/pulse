/// Unit tests for `ProgressPhotoClient`, the dedicated HTTP client for the
/// `/measures/photos` and `/measures/photo-tags` endpoints.
/// Covers metadata listing with range parameters, raw byte download, tagged
/// upload, the 204 delete path, and tag CRUD.
/// Part of the iOS app's progress-photo test suite.
import XCTest
@testable import Pulse

final class ProgressPhotoClientTests: XCTestCase {
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

    /// Builds a `ProgressPhotoClient` against the stub URL with a fixed bearer.
    /// Inputs:
    ///   - responder: closure that returns a stubbed HTTP response.
    /// Outputs: a `ProgressPhotoClient`.
    private func makeClient(responder: @escaping StubURLProtocol.Responder) -> ProgressPhotoClient {
        ProgressPhotoClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "tok",
            session: makeSession(responder: responder)
        )
    }

    /// Clears scoped `StubURLProtocol` registrations between tests.
    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        super.tearDown()
    }

    func testListMetadataSendsRangeAndDecodes() async throws {
        let tagId = UUID()
        let photoId = UUID()
        let json = """
        [{
          "id":"\(photoId.uuidString.lowercased())",
          "date":"2026-05-17",
          "tag_id":"\(tagId.uuidString.lowercased())",
          "mime":"image/jpeg",
          "bytes":100,
          "sha256":"abc",
          "updated_at":"2026-05-17T00:00:00Z"
        }]
        """.data(using: .utf8)!
        var capturedRequest: URLRequest?
        let client = makeClient { req in
            capturedRequest = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let frm = DateOnly.formatter.date(from: "2026-05-01")!
        let to  = DateOnly.formatter.date(from: "2026-05-31")!
        let result = try await client.listMetadata(from: frm, to: to)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].tagId, tagId)
        XCTAssertEqual(result[0].id, photoId)
        XCTAssertEqual(result[0].sha256, "abc")
        XCTAssertTrue(capturedRequest?.url?.absoluteString.contains("from=2026-05-01") ?? false)
        XCTAssertTrue(capturedRequest?.url?.absoluteString.contains("to=2026-05-31") ?? false)
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testDownloadReturnsBytes() async throws {
        let bytes = Data(repeating: 0xAB, count: 16)
        let client = makeClient { req in
            (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["ETag": "\"sha\""]
                )!,
                bytes
            )
        }
        let data = try await client.download(photoId: UUID(), size: .thumb)
        XCTAssertEqual(data, bytes)
    }

    func testUploadSendsMultipartWithTagAndDate() async throws {
        let tagId = UUID()
        let photoId = UUID()
        var capturedContentType: String?
        var capturedAuthorization: String?
        let client = makeClient { req in
            capturedContentType = req.value(forHTTPHeaderField: "Content-Type")
            capturedAuthorization = req.value(forHTTPHeaderField: "Authorization")
            let json = """
            {
              "id":"\(photoId.uuidString.lowercased())",
              "date":"2026-05-17",
              "tag_id":"\(tagId.uuidString.lowercased())",
              "mime":"image/jpeg",
              "bytes":3,
              "sha256":"sha",
              "updated_at":"2026-05-17T00:00:00Z"
            }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, json)
        }
        let d = DateOnly.formatter.date(from: "2026-05-17")!
        let meta = try await client.upload(date: d, tagId: tagId, jpeg: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(meta.tagId, tagId)
        XCTAssertEqual(meta.id, photoId)
        XCTAssertTrue(capturedContentType?.contains("multipart/form-data") ?? false)
        XCTAssertEqual(capturedAuthorization, "Bearer tok")
        let bodyStr = String(data: activeStubs.last?.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(bodyStr.contains("name=\"log_date\""))
        XCTAssertTrue(bodyStr.contains("2026-05-17"))
        XCTAssertTrue(bodyStr.contains("name=\"tag_id\""))
        XCTAssertTrue(bodyStr.contains(tagId.uuidString.lowercased()))
        XCTAssertFalse(
            bodyStr.contains("name=\"idempotency_key\""),
            "absent when caller doesn't pass one"
        )
    }

    func testUploadIncludesIdempotencyKeyWhenProvided() async throws {
        let tagId = UUID()
        let photoId = UUID()
        let idem = UUID()
        let client = makeClient { req in
            let json = """
            {
              "id":"\(photoId.uuidString.lowercased())",
              "date":"2026-05-17",
              "tag_id":"\(tagId.uuidString.lowercased())",
              "mime":"image/jpeg",
              "bytes":3,
              "sha256":"sha",
              "updated_at":"2026-05-17T00:00:00Z"
            }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, json)
        }
        let d = DateOnly.formatter.date(from: "2026-05-17")!
        _ = try await client.upload(
            date: d, tagId: tagId, jpeg: Data([0xFF]), idempotencyKey: idem
        )
        let bodyStr = String(data: activeStubs.last?.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(bodyStr.contains("name=\"idempotency_key\""))
        XCTAssertTrue(bodyStr.contains(idem.uuidString.lowercased()))
    }

    func testDeleteSucceedsOn204() async throws {
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await client.delete(photoId: UUID())
    }

    func testListTagsDecodes() async throws {
        let tagId = UUID()
        let json = """
        [{
          "id":"\(tagId.uuidString.lowercased())",
          "name":"front",
          "normalized_name":"front",
          "sort_order":0,
          "created_at":"2026-05-17T00:00:00Z",
          "updated_at":"2026-05-17T00:00:00Z"
        }]
        """.data(using: .utf8)!
        let client = makeClient { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let tags = try await client.listTags()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].id, tagId)
        XCTAssertEqual(tags[0].name, "front")
    }

    func testCreateTagSendsName() async throws {
        let tagId = UUID()
        let client = makeClient { req in
            let json = """
            {
              "id":"\(tagId.uuidString.lowercased())",
              "name":"morning",
              "normalized_name":"morning",
              "sort_order":4,
              "created_at":"2026-05-17T00:00:00Z",
              "updated_at":"2026-05-17T00:00:00Z"
            }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, json)
        }
        let tag = try await client.createTag(name: "morning")
        XCTAssertEqual(tag.id, tagId)
        let bodyStr = String(data: activeStubs.last?.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(bodyStr.contains("\"morning\""))
    }

    func testUpdateTagRenames() async throws {
        let tagId = UUID()
        let client = makeClient { req in
            let json = """
            {
              "id":"\(tagId.uuidString.lowercased())",
              "name":"AM",
              "normalized_name":"am",
              "sort_order":0,
              "created_at":"2026-05-17T00:00:00Z",
              "updated_at":"2026-05-17T00:00:00Z"
            }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let tag = try await client.updateTag(id: tagId, name: "AM")
        XCTAssertEqual(tag.normalizedName, "am")
    }
}
