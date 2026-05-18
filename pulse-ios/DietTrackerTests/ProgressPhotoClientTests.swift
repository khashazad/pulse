/// Unit tests for `ProgressPhotoClient`, the dedicated HTTP client for the
/// `/measures/photos` and `/measures/photo-tags` endpoints.
/// Covers metadata listing with range parameters, raw byte download, tagged
/// upload, the 204 delete path, and tag CRUD.
/// Part of the iOS app's progress-photo test suite.
import XCTest
@testable import DietTracker

final class ProgressPhotoClientTests: XCTestCase {

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeClient() -> ProgressPhotoClient {
        ProgressPhotoClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "tok",
            session: makeSession()
        )
    }

    override func tearDown() {
        super.tearDown()
        StubURLProtocol.responder = nil
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
        var capturedURL: URL?
        StubURLProtocol.responder = { req in
            capturedURL = req.url
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let frm = DateOnly.formatter.date(from: "2026-05-01")!
        let to  = DateOnly.formatter.date(from: "2026-05-31")!
        let result = try await makeClient().listMetadata(from: frm, to: to)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].tagId, tagId)
        XCTAssertEqual(result[0].id, photoId)
        XCTAssertEqual(result[0].sha256, "abc")
        XCTAssertTrue(capturedURL?.absoluteString.contains("from=2026-05-01") ?? false)
        XCTAssertTrue(capturedURL?.absoluteString.contains("to=2026-05-31") ?? false)
    }

    func testDownloadReturnsBytes() async throws {
        let bytes = Data(repeating: 0xAB, count: 16)
        StubURLProtocol.responder = { req in
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
        let data = try await makeClient().download(photoId: UUID(), size: .thumb)
        XCTAssertEqual(data, bytes)
    }

    func testUploadSendsMultipartWithTagAndDate() async throws {
        let tagId = UUID()
        let photoId = UUID()
        var capturedContentType: String?
        StubURLProtocol.responder = { req in
            capturedContentType = req.value(forHTTPHeaderField: "Content-Type")
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
        let meta = try await makeClient().upload(date: d, tagId: tagId, jpeg: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(meta.tagId, tagId)
        XCTAssertEqual(meta.id, photoId)
        XCTAssertTrue(capturedContentType?.contains("multipart/form-data") ?? false)
        let bodyStr = String(data: StubURLProtocol.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
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
        StubURLProtocol.responder = { req in
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
        _ = try await makeClient().upload(
            date: d, tagId: tagId, jpeg: Data([0xFF]), idempotencyKey: idem
        )
        let bodyStr = String(data: StubURLProtocol.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(bodyStr.contains("name=\"idempotency_key\""))
        XCTAssertTrue(bodyStr.contains(idem.uuidString.lowercased()))
    }

    func testDeleteSucceedsOn204() async throws {
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await makeClient().delete(photoId: UUID())
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
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let tags = try await makeClient().listTags()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].id, tagId)
        XCTAssertEqual(tags[0].name, "front")
    }

    func testCreateTagSendsName() async throws {
        let tagId = UUID()
        StubURLProtocol.responder = { req in
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
        let tag = try await makeClient().createTag(name: "morning")
        XCTAssertEqual(tag.id, tagId)
        let bodyStr = String(data: StubURLProtocol.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(bodyStr.contains("\"morning\""))
    }

    func testUpdateTagRenames() async throws {
        let tagId = UUID()
        StubURLProtocol.responder = { req in
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
        let tag = try await makeClient().updateTag(id: tagId, name: "AM")
        XCTAssertEqual(tag.normalizedName, "am")
    }
}
