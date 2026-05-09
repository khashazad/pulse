import XCTest
@testable import DietTracker

final class ContainerClientTests: XCTestCase {

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

    private func makeClient() -> DietTrackerClient {
        DietTrackerClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-k",
            session: makeSession()
        )
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func testListContainersSendsApiKeyAndUserKey() async throws {
        let json = try loadFixture("containers")
        var captured: URLRequest?
        StubURLProtocol.responder = { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let summaries = try await makeClient().listContainers()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(captured?.url?.path, "/containers")
        XCTAssertNil(captured?.url?.query)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
    }

    func testCreateContainerPostsJSON() async throws {
        let json = try loadFixture("container")
        var captured: URLRequest?
        var body: Data?
        StubURLProtocol.responder = { req in
            captured = req
            body = req.bodyStreamData()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let created = try await makeClient().createContainer(name: "Big Pyrex", tareWeightG: 412.0)
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(created.name, "Big Pyrex")
        let parsed = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        XCTAssertEqual(parsed?["name"] as? String, "Big Pyrex")
        XCTAssertEqual(parsed?["tare_weight_g"] as? Double, 412.0)
    }

    func testUpdateContainerPatchesPartialJSON() async throws {
        let json = try loadFixture("container")
        var captured: URLRequest?
        var body: Data?
        StubURLProtocol.responder = { req in
            captured = req
            body = req.bodyStreamData()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        _ = try await makeClient().updateContainer(id: id, name: "Renamed", tareWeightG: nil)
        XCTAssertEqual(captured?.httpMethod, "PATCH")
        let parsed = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        XCTAssertEqual(parsed?["name"] as? String, "Renamed")
        XCTAssertNil(parsed?["tare_weight_g"], "tare_weight_g must be omitted when nil")
    }

    func testDeleteContainerSends204() async throws {
        var captured: URLRequest?
        StubURLProtocol.responder = { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let id = UUID()
        try await makeClient().deleteContainer(id: id)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertTrue(captured?.url?.path.contains(id.uuidString.lowercased()) ?? false)
    }

    func testUploadContainerPhotoSendsMultipart() async throws {
        var captured: URLRequest?
        var body: Data?
        StubURLProtocol.responder = { req in
            captured = req
            body = req.bodyStreamData()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"has_photo\":true}".data(using: .utf8)!)
        }
        let id = UUID()
        try await makeClient().uploadContainerPhoto(id: id, jpegData: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        XCTAssertEqual(captured?.httpMethod, "PUT")
        let ct = captured?.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(ct.contains("multipart/form-data"), "got \(ct)")
        XCTAssertTrue(ct.contains("boundary="), "missing boundary in \(ct)")
        // Multipart body contains binary JPEG bytes (0xFF, 0xD8, ...) that aren't
        // valid UTF-8. ISO Latin 1 maps every byte 1:1 so the textual headers stay
        // searchable.
        let s = String(data: body ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(s.contains("name=\"file\""))
        XCTAssertTrue(s.contains("filename="))
        XCTAssertTrue(s.contains("Content-Type: image/jpeg"))
    }

    func test413MapsToPayloadTooLarge() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 413, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        do {
            try await makeClient().uploadContainerPhoto(id: UUID(), jpegData: Data([0xFF]))
            XCTFail("Expected payloadTooLarge")
        } catch let err as DietTrackerError {
            XCTAssertEqual(err, .payloadTooLarge)
        }
    }

    func testContainerPhotoRequestIncludesApiKey() {
        let id = UUID()
        let req = makeClient().containerPhotoRequest(id: id, size: .thumb)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
        XCTAssertTrue(req.url?.path.hasSuffix("/photo") ?? false)
        XCTAssertTrue(req.url?.query?.contains("size=") ?? false)
        XCTAssertFalse(req.url?.query?.contains("user_key") ?? true)
    }
}

extension URLRequest {
    func bodyStreamData() -> Data? {
        if let data = httpBody { return data }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
