/// Unit tests for `DietTrackerClient` container-related endpoints.
/// Verifies list/create/update/delete requests against `/containers`, the
/// multipart photo upload, the `payloadTooLarge` mapping for HTTP 413, and
/// the photo-fetch `URLRequest` builder.
/// Part of the iOS app's networking test suite.
import XCTest
@testable import DietTracker

final class ContainerClientTests: XCTestCase {
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
    ///   - name: fixture file base name (no extension).
    /// Outputs: raw bytes of `<name>.json` from the bundle.
    /// Exceptions: rethrows `Data(contentsOf:)` errors.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    /// Builds a `DietTrackerClient` pointed at the stub URL with a fixed bearer.
    /// Inputs:
    ///   - responder: closure that returns a stubbed HTTP response.
    /// Outputs: a `DietTrackerClient` ready to make stubbed requests.
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

    /// Verifies `listContainers()` hits `/containers` with the bearer header
    /// and no legacy `user_key` query parameter, and decodes the fixture.
    func testListContainersSendsBearerAndNoUserKey() async throws {
        let json = try loadFixture("containers")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let summaries = try await client.listContainers()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(captured?.url?.path, "/containers")
        XCTAssertNil(captured?.url?.query)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
    }

    /// Verifies `createContainer` sends a POST with JSON content-type and
    /// the expected name/tare fields in the body.
    func testCreateContainerPostsJSON() async throws {
        let json = try loadFixture("container")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let created = try await client.createContainer(name: "Big Pyrex", tareWeightG: 412.0)
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(created.name, "Big Pyrex")
        let parsed = try JSONSerialization.jsonObject(with: activeStubs.last?.lastRequestBody ?? Data()) as? [String: Any]
        XCTAssertEqual(parsed?["name"] as? String, "Big Pyrex")
        XCTAssertEqual(parsed?["tare_weight_g"] as? Double, 412.0)
    }

    /// Verifies `updateContainer` sends PATCH and omits keys whose value is
    /// nil (so `tare_weight_g` is not present when only the name changes).
    func testUpdateContainerPatchesPartialJSON() async throws {
        let json = try loadFixture("container")
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        _ = try await client.updateContainer(id: id, name: "Renamed", tareWeightG: nil)
        XCTAssertEqual(captured?.httpMethod, "PATCH")
        let parsed = try JSONSerialization.jsonObject(with: activeStubs.last?.lastRequestBody ?? Data()) as? [String: Any]
        XCTAssertEqual(parsed?["name"] as? String, "Renamed")
        XCTAssertNil(parsed?["tare_weight_g"], "tare_weight_g must be omitted when nil")
    }

    /// Verifies `deleteContainer` issues DELETE against the container's id
    /// path.
    func testDeleteContainerSends204() async throws {
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let id = UUID()
        try await client.deleteContainer(id: id)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertTrue(captured?.url?.path.contains(id.uuidString.lowercased()) ?? false)
    }

    /// Verifies `uploadContainerPhoto` sends a PUT with a multipart body
    /// that includes a file part named `file` typed as `image/jpeg`.
    func testUploadContainerPhotoSendsMultipart() async throws {
        var captured: URLRequest?
        let client = makeClient { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"has_photo\":true}".data(using: .utf8)!)
        }
        let id = UUID()
        try await client.uploadContainerPhoto(id: id, jpegData: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        XCTAssertEqual(captured?.httpMethod, "PUT")
        let ct = captured?.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(ct.contains("multipart/form-data"), "got \(ct)")
        XCTAssertTrue(ct.contains("boundary="), "missing boundary in \(ct)")
        // Multipart body contains binary JPEG bytes (0xFF, 0xD8, ...) that aren't
        // valid UTF-8. ISO Latin 1 maps every byte 1:1 so the textual headers stay
        // searchable.
        let s = String(data: activeStubs.last?.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(s.contains("name=\"file\""))
        XCTAssertTrue(s.contains("filename="))
        XCTAssertTrue(s.contains("Content-Type: image/jpeg"))
    }

    /// Verifies an HTTP 413 response maps to `DietTrackerError.payloadTooLarge`.
    func test413MapsToPayloadTooLarge() async throws {
        let client = makeClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 413, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        do {
            try await client.uploadContainerPhoto(id: UUID(), jpegData: Data([0xFF]))
            XCTFail("Expected payloadTooLarge")
        } catch let err as DietTrackerError {
            XCTAssertEqual(err, .payloadTooLarge)
        }
    }

    /// Verifies the container-photo `URLRequest` builder embeds the bearer
    /// token, targets the `/photo` path, includes a `size=` query item, and
    /// omits the legacy `user_key` parameter.
    func testContainerPhotoRequestIncludesBearer() {
        let id = UUID()
        let client = DietTrackerClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-k",
            session: URLSession(configuration: .ephemeral)
        )
        let req = client.containerPhotoRequest(id: id, size: .thumb)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
        XCTAssertTrue(req.url?.path.hasSuffix("/photo") ?? false)
        XCTAssertTrue(req.url?.query?.contains("size=") ?? false)
        XCTAssertFalse(req.url?.query?.contains("user_key") ?? true)
    }
}
