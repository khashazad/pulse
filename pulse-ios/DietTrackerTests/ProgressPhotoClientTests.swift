/// Unit tests for `ProgressPhotoClient`, the dedicated HTTP client for the
/// `/progress-photos` endpoints.
/// Covers metadata listing with range parameters, raw byte download,
/// multipart upload (single + batch), and the 204 delete path.
/// Part of the iOS app's progress-photo test suite.
import XCTest
@testable import DietTracker

final class ProgressPhotoClientTests: XCTestCase {

    /// Builds an ephemeral `URLSession` wired to `StubURLProtocol`.
    /// Outputs: a fresh `URLSession` for stubbed HTTP traffic.
    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// Builds a `ProgressPhotoClient` against the stub URL with a fixed bearer.
    /// Outputs: a `ProgressPhotoClient`.
    private func makeClient() -> ProgressPhotoClient {
        ProgressPhotoClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "tok",
            session: makeSession()
        )
    }

    /// Clears the shared `StubURLProtocol` responder between tests.
    override func tearDown() {
        super.tearDown()
        StubURLProtocol.responder = nil
    }

    /// Verifies `listMetadata(from:to:)` sends `from=` and `to=` parameters
    /// and decodes the metadata array.
    func testListMetadataSendsRangeAndDecodes() async throws {
        let json = """
        [{"date":"2026-05-17","slot":"front","mime":"image/jpeg","bytes":100,"sha256":"abc","updated_at":"2026-05-17T00:00:00Z"}]
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
        XCTAssertEqual(result[0].slot, .front)
        XCTAssertEqual(result[0].sha256, "abc")
        XCTAssertTrue(capturedURL?.absoluteString.contains("from=2026-05-01") ?? false)
        XCTAssertTrue(capturedURL?.absoluteString.contains("to=2026-05-31") ?? false)
    }

    /// Verifies `download(date:slot:size:)` returns the raw response bytes.
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
        let d = DateOnly.formatter.date(from: "2026-05-17")!
        let data = try await makeClient().download(date: d, slot: .front, size: .thumb)
        XCTAssertEqual(data, bytes)
    }

    /// Verifies a single-slot upload sends a multipart body and decodes the
    /// returned metadata.
    func testUploadSingleSendsMultipart() async throws {
        var capturedContentType: String?
        var capturedBodyEmpty = true
        StubURLProtocol.responder = { req in
            capturedContentType = req.value(forHTTPHeaderField: "Content-Type")
            if let body = req.httpBody, !body.isEmpty {
                capturedBodyEmpty = false
            } else if let stream = req.httpBodyStream {
                stream.open()
                defer { stream.close() }
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 1024)
                    if n <= 0 { break }
                    if n > 0 { capturedBodyEmpty = false }
                }
            }
            let json = """
            {"date":"2026-05-17","slot":"front","mime":"image/jpeg","bytes":3,"sha256":"sha","updated_at":"2026-05-17T00:00:00Z"}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let d = DateOnly.formatter.date(from: "2026-05-17")!
        let meta = try await makeClient().upload(date: d, slot: .front, jpeg: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(meta.slot, .front)
        XCTAssertTrue(capturedContentType?.contains("multipart/form-data") ?? false)
        XCTAssertFalse(capturedBodyEmpty)
    }

    /// Verifies a batch upload of multiple slots returns one metadata entry
    /// per slot.
    func testUploadBatchSendsAllSlots() async throws {
        StubURLProtocol.responder = { req in
            let json = """
            [
              {"date":"2026-05-17","slot":"front","mime":"image/jpeg","bytes":3,"sha256":"f","updated_at":"2026-05-17T00:00:00Z"},
              {"date":"2026-05-17","slot":"back","mime":"image/jpeg","bytes":3,"sha256":"b","updated_at":"2026-05-17T00:00:00Z"}
            ]
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let d = DateOnly.formatter.date(from: "2026-05-17")!
        let result = try await makeClient().uploadBatch(
            date: d,
            assignments: [.front: Data([1]), .back: Data([2])]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.slot)), Set([.front, .back]))
    }

    /// Verifies `delete(date:slot:)` succeeds on HTTP 204.
    func testDeleteSucceedsOn204() async throws {
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let d = DateOnly.formatter.date(from: "2026-05-17")!
        try await makeClient().delete(date: d, slot: .front)
    }
}
