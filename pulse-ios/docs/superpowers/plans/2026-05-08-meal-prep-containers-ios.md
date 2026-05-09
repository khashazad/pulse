# Meal-Prep Containers — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-05-08-meal-prep-containers-design.md`.

**Goal:** Add a Prep tab to DietTracker that picks a container, subtracts its tare weight from a scale reading, and divides into N portions. Add full container CRUD with camera/library photo, against the new backend endpoints.

**Architecture:** Models mirror the backend's JSON shapes. `DietTrackerClient` gains write methods for the first time (was read-only). New `@Observable` view-models per screen reuse the existing `LoadState<T>` pattern. A small `AuthorizedAsyncImage` view wraps a `URLSession` task to inject the API key header into thumbnail/full-photo fetches and lets `URLCache` handle caching. Math lives in `PrepModel`, isolated from UI for testability.

**Tech Stack:** SwiftUI (iOS 17+), `@Observable`, `NavigationStack`, `PhotosPicker`, `UIImagePickerController` (camera), URLSession multipart upload.

**Repo:** `diet-tracker-ios` (this plan operates in this repo only).

**Sequencing:** Backend plan (`../dietracker-server/docs/superpowers/plans/2026-05-08-meal-prep-containers-backend.md`) must be deployed before manual smoke testing in Task 11. Tests run independently.

---

## File Map

Creates:
- `DietTracker/Models/Container.swift` — DTOs.
- `DietTracker/State/PrepModel.swift` — calculator state + math.
- `DietTracker/State/ContainersListModel.swift` — load/delete state.
- `DietTracker/State/ContainerEditModel.swift` — form state + save flow.
- `DietTracker/Views/Prep/PrepView.swift`
- `DietTracker/Views/Prep/ContainersListView.swift`
- `DietTracker/Views/Prep/ContainerEditView.swift`
- `DietTracker/Views/Prep/ContainerPickerSheet.swift`
- `DietTracker/Views/Components/AuthorizedAsyncImage.swift`
- `DietTrackerTests/Fixtures/containers.json`
- `DietTrackerTests/Fixtures/container.json`
- `DietTrackerTests/PrepModelTests.swift`
- `DietTrackerTests/ContainerDecodingTests.swift`
- `DietTrackerTests/ContainerClientTests.swift`

Modifies:
- `DietTracker/Networking/DietTrackerError.swift` — add `payloadTooLarge`.
- `DietTracker/Networking/DietTrackerClient.swift` — container CRUD + photo upload/serve.
- `DietTracker/Views/FloatingDock.swift` — add Prep button.
- `DietTracker/Views/RootView.swift` — handle `.prep` tab.
- `DietTracker/Info.plist` — add `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`.
- `project.yml` — mirror Info.plist additions so XcodeGen stays in sync.

---

## Task 1: Container DTOs + decoding tests

**Files:**
- Create: `DietTracker/Models/Container.swift`
- Create: `DietTrackerTests/Fixtures/containers.json`
- Create: `DietTrackerTests/Fixtures/container.json`
- Create: `DietTrackerTests/ContainerDecodingTests.swift`

- [ ] **Step 1: Write fixture `containers.json`**

```json
{
  "containers": [
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "user_key": "khash",
      "name": "Big Pyrex",
      "normalized_name": "big pyrex",
      "tare_weight_g": 412.0,
      "has_photo": true,
      "created_at": "2026-05-08T10:00:00Z",
      "updated_at": "2026-05-08T10:00:00Z"
    },
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "user_key": "khash",
      "name": "Glass meal-prep box",
      "normalized_name": "glass meal-prep box",
      "tare_weight_g": 187.5,
      "has_photo": false,
      "created_at": "2026-05-08T10:00:00Z",
      "updated_at": "2026-05-08T10:00:00Z"
    }
  ]
}
```

- [ ] **Step 2: Write fixture `container.json`**

```json
{
  "id": "11111111-1111-1111-1111-111111111111",
  "user_key": "khash",
  "name": "Big Pyrex",
  "normalized_name": "big pyrex",
  "tare_weight_g": 412.0,
  "has_photo": true,
  "created_at": "2026-05-08T10:00:00Z",
  "updated_at": "2026-05-08T10:00:00Z"
}
```

- [ ] **Step 3: Write `Container.swift`**

```swift
import Foundation

struct Container: Codable, Equatable, Identifiable {
    let id: UUID
    let userKey: String
    let name: String
    let normalizedName: String
    let tareWeightG: Double
    let hasPhoto: Bool
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userKey = "user_key"
        case name
        case normalizedName = "normalized_name"
        case tareWeightG = "tare_weight_g"
        case hasPhoto = "has_photo"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ContainersList: Codable, Equatable {
    let containers: [Container]
}

struct ContainerPhotoStatus: Codable, Equatable {
    let hasPhoto: Bool

    enum CodingKeys: String, CodingKey {
        case hasPhoto = "has_photo"
    }
}

enum ContainerPhotoSize: String {
    case thumb
    case full
}
```

- [ ] **Step 4: Write `ContainerDecodingTests.swift`**

```swift
import XCTest
@testable import DietTracker

final class ContainerDecodingTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found in test bundle")
            throw NSError(domain: "fixture", code: 0)
        }
        return try Data(contentsOf: url)
    }

    func testDecodeContainersList() throws {
        let data = try loadFixture("containers")
        let list = try JSONDecoder.dietTrackerDefault().decode(ContainersList.self, from: data)
        XCTAssertEqual(list.containers.count, 2)
        XCTAssertEqual(list.containers[0].name, "Big Pyrex")
        XCTAssertEqual(list.containers[0].tareWeightG, 412.0)
        XCTAssertTrue(list.containers[0].hasPhoto)
        XCTAssertFalse(list.containers[1].hasPhoto)
    }

    func testDecodeSingleContainer() throws {
        let data = try loadFixture("container")
        let c = try JSONDecoder.dietTrackerDefault().decode(Container.self, from: data)
        XCTAssertEqual(c.id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(c.normalizedName, "big pyrex")
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild test -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" -only-testing:DietTrackerTests/ContainerDecodingTests 2>&1 | tail -25`
Expected: 2 tests pass.

If the project hasn't been regenerated since adding files, run: `xcodegen` first.

- [ ] **Step 6: Commit**

```bash
git add DietTracker/Models/Container.swift \
        DietTrackerTests/Fixtures/containers.json \
        DietTrackerTests/Fixtures/container.json \
        DietTrackerTests/ContainerDecodingTests.swift
git commit -m "feat(models): container DTOs + decoding tests"
```

---

## Task 2: Add `payloadTooLarge` error case

**Files:**
- Modify: `DietTracker/Networking/DietTrackerError.swift`

- [ ] **Step 1: Edit the enum and helpers**

Edit `DietTracker/Networking/DietTrackerError.swift`:

```swift
import Foundation

enum DietTrackerError: Error, Equatable {
    case notConfigured
    case unauthorized
    case notFound
    case payloadTooLarge
    case network(URLError)
    case decoding(String)
    case server(status: Int)

    static func == (lhs: DietTrackerError, rhs: DietTrackerError) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured),
             (.unauthorized, .unauthorized),
             (.notFound, .notFound),
             (.payloadTooLarge, .payloadTooLarge):
            return true
        case let (.network(a), .network(b)):
            return a.code == b.code
        case let (.decoding(a), .decoding(b)):
            return a == b
        case let (.server(a), .server(b)):
            return a == b
        default:
            return false
        }
    }

    var userMessage: String {
        switch self {
        case .notConfigured:    return "Set the server URL and API key in Settings."
        case .unauthorized:     return "API key rejected. Check Settings."
        case .notFound:         return "No data for this date."
        case .payloadTooLarge:  return "That image is too large. Try a smaller photo."
        case .network:          return "Network error. Check your connection."
        case .decoding:         return "Couldn't read the server response."
        case .server(let s):    return "Server error (\(s)). Try again."
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add DietTracker/Networking/DietTrackerError.swift
git commit -m "feat(error): add payloadTooLarge case for photo upload"
```

---

## Task 3: Failing client tests for container methods

**Files:**
- Create: `DietTrackerTests/ContainerClientTests.swift`

- [ ] **Step 1: Write the tests**

Re-uses the `StubURLProtocol` from `DietTrackerClientTests.swift` (it lives in the test target so we can reference it).

```swift
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
            apiKey: "k",
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
        XCTAssertEqual(captured?.url?.query, "user_key=khash")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "X-API-Key"), "k")
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
        let s = String(data: body ?? Data(), encoding: .utf8) ?? ""
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
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-API-Key"), "k")
        XCTAssertTrue(req.url?.path.hasSuffix("/photo") ?? false)
        XCTAssertTrue(req.url?.query?.contains("size=thumb") ?? false)
        XCTAssertTrue(req.url?.query?.contains("user_key=khash") ?? false)
    }
}

// Helper: read multipart bodies from stubbed URLRequests (URLSession streams them).
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
```

- [ ] **Step 2: Run, expect failure**

Run: `xcodebuild test -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" -only-testing:DietTrackerTests/ContainerClientTests 2>&1 | tail -30`
Expected: compile error — methods on `DietTrackerClient` don't exist yet.

- [ ] **Step 3: Commit**

```bash
git add DietTrackerTests/ContainerClientTests.swift
git commit -m "test: failing client tests for container endpoints"
```

---

## Task 4: Extend `DietTrackerClient` with container methods

**Files:**
- Modify: `DietTracker/Networking/DietTrackerClient.swift`

- [ ] **Step 1: Replace the file with the extended client**

```swift
import Foundation

actor DietTrackerClient {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.decoder = JSONDecoder.dietTrackerDefault()
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = enc
    }

    // MARK: - existing read endpoints

    func summary(date: Date) async throws -> DailySummary {
        let path = "/summary/\(DateOnly.string(from: date))"
        let url = try makeURL(path: path, query: [URLQueryItem(name: "user_key", value: Constants.userKey)])
        return try await fetch(url: url)
    }

    func logs(from: Date, to: Date) async throws -> LogsList {
        let url = try makeURL(
            path: "/logs",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to)),
                URLQueryItem(name: "user_key", value: Constants.userKey),
            ]
        )
        return try await fetch(url: url)
    }

    // MARK: - containers

    func listContainers() async throws -> [Container] {
        let url = try makeURL(path: "/containers", query: [URLQueryItem(name: "user_key", value: Constants.userKey)])
        let list: ContainersList = try await fetch(url: url)
        return list.containers
    }

    func getContainer(id: UUID) async throws -> Container {
        let url = try makeURL(
            path: "/containers/\(id.uuidString.lowercased())",
            query: [URLQueryItem(name: "user_key", value: Constants.userKey)]
        )
        return try await fetch(url: url)
    }

    func createContainer(name: String, tareWeightG: Double) async throws -> Container {
        struct Body: Encodable {
            let name: String
            let tareWeightG: Double
            enum CodingKeys: String, CodingKey {
                case name
                case tareWeightG = "tare_weight_g"
            }
        }
        let url = try makeURL(path: "/containers", query: [URLQueryItem(name: "user_key", value: Constants.userKey)])
        let body = try JSONEncoder().encode(Body(name: name, tareWeightG: tareWeightG))
        return try await sendJSON(url: url, method: "POST", body: body)
    }

    func updateContainer(id: UUID, name: String?, tareWeightG: Double?) async throws -> Container {
        var fields: [String: Any] = [:]
        if let name { fields["name"] = name }
        if let tareWeightG { fields["tare_weight_g"] = tareWeightG }
        let url = try makeURL(
            path: "/containers/\(id.uuidString.lowercased())",
            query: [URLQueryItem(name: "user_key", value: Constants.userKey)]
        )
        let body = try JSONSerialization.data(withJSONObject: fields, options: [])
        return try await sendJSON(url: url, method: "PATCH", body: body)
    }

    func deleteContainer(id: UUID) async throws {
        let url = try makeURL(
            path: "/containers/\(id.uuidString.lowercased())",
            query: [URLQueryItem(name: "user_key", value: Constants.userKey)]
        )
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        try await sendNoBody(request: req)
    }

    func uploadContainerPhoto(id: UUID, jpegData: Data) async throws {
        let url = try makeURL(
            path: "/containers/\(id.uuidString.lowercased())/photo",
            query: [URLQueryItem(name: "user_key", value: Constants.userKey)]
        )
        let boundary = "----DietTrackerBoundary\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(boundary: boundary, fieldName: "file", filename: "photo.jpg", mimeType: "image/jpeg", data: jpegData)
        _ = try await send(request: req, expectStatus: 200..<300)
    }

    func deleteContainerPhoto(id: UUID) async throws {
        let url = try makeURL(
            path: "/containers/\(id.uuidString.lowercased())/photo",
            query: [URLQueryItem(name: "user_key", value: Constants.userKey)]
        )
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        try await sendNoBody(request: req)
    }

    /// Builds an authorized `URLRequest` for the photo endpoint. Used by views
    /// that fetch image bytes directly through `URLSession`.
    nonisolated func containerPhotoRequest(id: UUID, size: ContainerPhotoSize) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/containers/\(id.uuidString.lowercased())/photo"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "size", value: size.rawValue),
            URLQueryItem(name: "user_key", value: Constants.userKey),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        return req
    }

    // MARK: - private helpers

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw DietTrackerError.notConfigured
        }
        comps.queryItems = query
        guard let url = comps.url else { throw DietTrackerError.notConfigured }
        return url
    }

    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request: req, expectStatus: 200..<300)
    }

    private func sendJSON<T: Decodable>(url: URL, method: String, body: Data) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        return try await send(request: req, expectStatus: 200..<300)
    }

    private func sendNoBody(request: URLRequest) async throws {
        _ = try await send(request: request, expectStatus: 200..<300, decodeBody: false) as Empty
    }

    private struct Empty: Decodable {}

    private func send<T: Decodable>(request: URLRequest, expectStatus: Range<Int>, decodeBody: Bool = true) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw DietTrackerError.network(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DietTrackerError.server(status: -1)
        }
        switch http.statusCode {
        case 200..<300:
            if !decodeBody {
                return try decoder.decode(T.self, from: "{}".data(using: .utf8) ?? Data())
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch let decodingError {
                throw DietTrackerError.decoding(String(describing: decodingError))
            }
        case 401, 403: throw DietTrackerError.unauthorized
        case 404:      throw DietTrackerError.notFound
        case 413:      throw DietTrackerError.payloadTooLarge
        default:       throw DietTrackerError.server(status: http.statusCode)
        }
    }

    private static func multipartBody(boundary: String, fieldName: String, filename: String, mimeType: String, data: Data) -> Data {
        var body = Data()
        let lineBreak = "\r\n"
        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(data)
        body.append("\(lineBreak)--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }
}
```

- [ ] **Step 2: Run new client tests**

Run: `xcodegen && xcodebuild test -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" -only-testing:DietTrackerTests/ContainerClientTests 2>&1 | tail -30`
Expected: 7 tests pass.

- [ ] **Step 3: Run the full test suite as a regression check**

Run: `xcodebuild test -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" 2>&1 | tail -25`
Expected: all tests pass; existing `DietTrackerClientTests` and `DecodingTests` unchanged.

- [ ] **Step 4: Commit**

```bash
git add DietTracker/Networking/DietTrackerClient.swift
git commit -m "feat(client): containers CRUD + multipart photo upload"
```

---

## Task 5: PrepModel with math test

**Files:**
- Create: `DietTracker/State/PrepModel.swift`
- Create: `DietTrackerTests/PrepModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import DietTracker

final class PrepModelTests: XCTestCase {

    func testNetEqualsTotalMinusTare() {
        let m = PrepModel()
        m.tareWeightG = 412
        m.totalGrams = 1450
        m.portions = 1
        XCTAssertEqual(m.netGrams, 1038, accuracy: 0.001)
        XCTAssertEqual(m.perPortionGrams, 1038, accuracy: 0.001)
    }

    func testPortionsDivision() {
        let m = PrepModel()
        m.tareWeightG = 412
        m.totalGrams = 1450
        m.portions = 5
        XCTAssertEqual(m.netGrams, 1038, accuracy: 0.001)
        XCTAssertEqual(m.perPortionGrams, 207.6, accuracy: 0.001)
    }

    func testNegativeNetClampsToZero() {
        let m = PrepModel()
        m.tareWeightG = 1000
        m.totalGrams = 500
        m.portions = 2
        XCTAssertEqual(m.netGrams, 0)
        XCTAssertEqual(m.perPortionGrams, 0)
    }

    func testNoTotalReturnsNil() {
        let m = PrepModel()
        m.tareWeightG = 412
        m.totalGrams = nil
        XCTAssertNil(m.netGrams)
        XCTAssertNil(m.perPortionGrams)
    }

    func testPortionsAtLeastOne() {
        let m = PrepModel()
        m.tareWeightG = 100
        m.totalGrams = 300
        m.portions = 0   // floored to 1
        XCTAssertEqual(m.perPortionGrams, 200)
    }
}
```

- [ ] **Step 2: Write `PrepModel.swift`**

```swift
import Foundation
import Observation

@Observable
final class PrepModel {
    var selectedContainerId: UUID?
    var tareWeightG: Double = 0       // mirror of selected container; updated when selection changes
    var totalGrams: Double?
    var portions: Int = 1

    var netGrams: Double? {
        guard let total = totalGrams else { return nil }
        return max(0, total - tareWeightG)
    }

    var perPortionGrams: Double? {
        guard let net = netGrams else { return nil }
        let p = max(1, portions)
        return net / Double(p)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `xcodegen && xcodebuild test -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" -only-testing:DietTrackerTests/PrepModelTests 2>&1 | tail -20`
Expected: 5 tests pass.

- [ ] **Step 4: Commit**

```bash
git add DietTracker/State/PrepModel.swift DietTrackerTests/PrepModelTests.swift
git commit -m "feat(state): PrepModel with tare-deduction + portion math"
```

---

## Task 6: ContainersListModel + ContainerEditModel (no UI yet)

**Files:**
- Create: `DietTracker/State/ContainersListModel.swift`
- Create: `DietTracker/State/ContainerEditModel.swift`

- [ ] **Step 1: Write `ContainersListModel.swift`**

```swift
import Foundation
import Observation

@Observable
final class ContainersListModel {
    private(set) var state: LoadState<[Container]> = .idle
    private weak var settings: AppSettings?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func load() async {
        guard let client = settings?.makeClient() else {
            state = .failed(.notConfigured)
            return
        }
        state = .loading
        do {
            let containers = try await client.listContainers()
            state = .loaded(containers)
        } catch let error as DietTrackerError {
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    func delete(id: UUID) async {
        guard let client = settings?.makeClient() else { return }
        do {
            try await client.deleteContainer(id: id)
        } catch {
            // Best-effort: fall through to reload to surface the real state.
        }
        await load()
    }
}
```

- [ ] **Step 2: Write `ContainerEditModel.swift`**

```swift
import Foundation
import Observation
import UIKit

@Observable
final class ContainerEditModel {
    var name: String
    var tareWeightText: String
    /// New JPEG bytes the user picked (camera or library). Nil = leave existing.
    var newPhotoJPEG: Data?
    /// True when the user explicitly removed the existing photo.
    var photoCleared: Bool = false

    private(set) var saving: Bool = false
    private(set) var error: DietTrackerError?
    private(set) var savedContainerId: UUID?

    private let existing: Container?
    private weak var settings: AppSettings?

    init(existing: Container? = nil, settings: AppSettings) {
        self.existing = existing
        self.settings = settings
        self.name = existing?.name ?? ""
        if let g = existing?.tareWeightG {
            self.tareWeightText = String(format: "%g", g)
        } else {
            self.tareWeightText = ""
        }
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            (Double(tareWeightText) ?? 0) > 0
    }

    var isExisting: Bool { existing != nil }

    var existingPhotoId: UUID? {
        guard let existing, existing.hasPhoto, !photoCleared else { return nil }
        return existing.id
    }

    func save() async {
        guard let client = settings?.makeClient(), let weight = Double(tareWeightText) else {
            error = .notConfigured
            return
        }
        saving = true; defer { saving = false }
        do {
            let saved: Container
            if let existing {
                saved = try await client.updateContainer(id: existing.id, name: name, tareWeightG: weight)
            } else {
                saved = try await client.createContainer(name: name, tareWeightG: weight)
            }
            if let jpeg = newPhotoJPEG {
                try await client.uploadContainerPhoto(id: saved.id, jpegData: jpeg)
            } else if photoCleared, existing != nil {
                try await client.deleteContainerPhoto(id: saved.id)
            }
            savedContainerId = saved.id
            error = nil
        } catch let e as DietTrackerError {
            error = e
        } catch {
            self.error = .server(status: -1)
        }
    }

    func setNewPhoto(uiImage: UIImage) {
        newPhotoJPEG = uiImage.jpegData(compressionQuality: 0.85)
        photoCleared = false
    }

    func clearPhoto() {
        newPhotoJPEG = nil
        photoCleared = true
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `xcodegen && xcodebuild build -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add DietTracker/State/ContainersListModel.swift DietTracker/State/ContainerEditModel.swift
git commit -m "feat(state): containers list + edit view-models"
```

---

## Task 7: AuthorizedAsyncImage view

**Files:**
- Create: `DietTracker/Views/Components/AuthorizedAsyncImage.swift`

- [ ] **Step 1: Write the view**

Provides `AsyncImage`-style declarative loading but supports adding our `X-API-Key` header to the request. Caches via the shared `URLCache.shared`.

```swift
import SwiftUI

struct AuthorizedAsyncImage<Content: View, Placeholder: View>: View {
    let request: URLRequest
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let img = loadedImage {
                content(Image(uiImage: img))
            } else {
                placeholder()
            }
        }
        .task(id: request.url) {
            await load()
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let img = UIImage(data: data) {
                self.loadedImage = img
            }
        } catch {
            // leave placeholder
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodegen && xcodebuild build -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add DietTracker/Views/Components/AuthorizedAsyncImage.swift
git commit -m "feat(view): AuthorizedAsyncImage for API-key-gated photos"
```

---

## Task 8: ContainersListView + ContainerPickerSheet

**Files:**
- Create: `DietTracker/Views/Prep/ContainersListView.swift`
- Create: `DietTracker/Views/Prep/ContainerPickerSheet.swift`

- [ ] **Step 1: Write `ContainersListView.swift`**

```swift
import SwiftUI

struct ContainersListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var model: ContainersListModel?
    @State private var showAdd = false
    @State private var editing: Container?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Containers")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
                .sheet(isPresented: $showAdd) {
                    ContainerEditView(existing: nil) { _ in
                        Task { await model?.load() }
                    }
                    .environment(settings)
                }
                .sheet(item: $editing) { container in
                    ContainerEditView(existing: container) { _ in
                        Task { await model?.load() }
                    }
                    .environment(settings)
                }
        }
        .task { await ensureModel(); await model?.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model?.state ?? .idle {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let e):
            ContentUnavailableView {
                Label("Couldn't load containers", systemImage: "exclamationmark.triangle")
            } description: {
                Text(e.userMessage)
            } actions: {
                Button("Retry") { Task { await model?.load() } }
            }
        case .loaded(let list) where list.isEmpty:
            ContentUnavailableView {
                Label("No containers yet", systemImage: "cube.box")
            } description: {
                Text("Add your first pot or meal-prep box.")
            } actions: {
                Button("Add a container") { showAdd = true }
            }
        case .loaded(let list):
            List {
                ForEach(list) { c in
                    Button {
                        editing = c
                    } label: {
                        ContainerRow(container: c)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { idx in
                    Task {
                        for i in idx { await model?.delete(id: list[i].id) }
                    }
                }
            }
        }
    }

    private func ensureModel() async {
        if model == nil { model = ContainersListModel(settings: settings) }
    }
}

struct ContainerRow: View {
    @Environment(AppSettings.self) private var settings
    let container: Container

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading) {
                Text(container.name).font(.body)
                Text("\(Int(container.tareWeightG.rounded())) g")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if container.hasPhoto, let client = settings.makeClient() {
            AuthorizedAsyncImage(
                request: client.containerPhotoRequest(id: container.id, size: .thumb),
                content: { $0.resizable().scaledToFill() },
                placeholder: { Color.gray.opacity(0.2) }
            )
        } else {
            ZStack {
                Color.gray.opacity(0.15)
                Image(systemName: "cube.box").foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Write `ContainerPickerSheet.swift`**

```swift
import SwiftUI

struct ContainerPickerSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var model: ContainersListModel?
    let onPick: (Container) -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model?.state ?? .idle {
                case .idle, .loading:
                    ProgressView()
                case .failed(let e):
                    ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(e.userMessage))
                case .loaded(let list) where list.isEmpty:
                    ContentUnavailableView("No containers yet", systemImage: "cube.box", description: Text("Add a container first."))
                case .loaded(let list):
                    List(list) { c in
                        Button {
                            onPick(c)
                            dismiss()
                        } label: {
                            ContainerRow(container: c)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Pick a container")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            if model == nil { model = ContainersListModel(settings: settings) }
            await model?.load()
        }
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `xcodegen && xcodebuild build -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

> **Note:** `ContainerEditView` is referenced but not yet created — will be in Task 9. Compilation may fail with "cannot find ContainerEditView" until then. If so, defer the build verification step to Task 9.

- [ ] **Step 4: Commit**

```bash
git add DietTracker/Views/Prep/ContainersListView.swift DietTracker/Views/Prep/ContainerPickerSheet.swift
git commit -m "feat(view): containers list + picker sheet"
```

---

## Task 9: ContainerEditView (camera + library + form)

**Files:**
- Create: `DietTracker/Views/Prep/ContainerEditView.swift`

- [ ] **Step 1: Write `ContainerEditView.swift`**

```swift
import PhotosUI
import SwiftUI
import UIKit

struct ContainerEditView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let existing: Container?
    let onSaved: (UUID) -> Void

    @State private var model: ContainerEditModel?
    @State private var showSourceSheet = false
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    photoSection
                }
                Section("Details") {
                    TextField("Name", text: Binding(
                        get: { model?.name ?? "" },
                        set: { model?.name = $0 }
                    ))
                    HStack {
                        TextField("Tare weight", text: Binding(
                            get: { model?.tareWeightText ?? "" },
                            set: { model?.tareWeightText = $0 }
                        ))
                        .keyboardType(.decimalPad)
                        Text("g").foregroundStyle(.secondary)
                    }
                }
                if let err = model?.error {
                    Section { Text(err.userMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "New container" : "Edit container")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model?.saving == true ? "Saving…" : "Save") {
                        Task {
                            await model?.save()
                            if let id = model?.savedContainerId {
                                onSaved(id)
                                dismiss()
                            }
                        }
                    }
                    .disabled(model?.isValid != true || model?.saving == true)
                }
            }
            .confirmationDialog("Photo", isPresented: $showSourceSheet, titleVisibility: .visible) {
                Button("Take Photo") { showCamera = true }
                // PhotosPicker is rendered inline below; this just toggles state
                if model?.existingPhotoId != nil || previewImage != nil {
                    Button("Remove", role: .destructive) {
                        previewImage = nil
                        model?.clearPhoto()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: .constant(false), selection: $pickerItem, matching: .images)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    previewImage = image
                    model?.setNewPhoto(uiImage: image)
                }
            }
            .onChange(of: pickerItem) { _, newValue in
                Task { await loadPicked(newValue) }
            }
        }
        .task {
            if model == nil { model = ContainerEditModel(existing: existing, settings: settings) }
        }
    }

    @ViewBuilder
    private var photoSection: some View {
        ZStack {
            if let img = previewImage {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let id = model?.existingPhotoId, let client = settings.makeClient() {
                AuthorizedAsyncImage(
                    request: client.containerPhotoRequest(id: id, size: .full),
                    content: { $0.resizable().scaledToFill() },
                    placeholder: { Color.gray.opacity(0.15) }
                )
            } else {
                ZStack {
                    Color.gray.opacity(0.15)
                    Image(systemName: "camera").font(.title).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                Button { showCamera = true } label: {
                    Label("Camera", systemImage: "camera").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Library", systemImage: "photo").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                if model?.existingPhotoId != nil || previewImage != nil {
                    Button(role: .destructive) {
                        previewImage = nil
                        model?.clearPhoto()
                    } label: {
                        Label("Remove", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(8)
        }
    }

    private func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let img = UIImage(data: data) {
            previewImage = img
            model?.setNewPhoto(uiImage: img)
        }
    }
}

// UIKit camera bridge.
private struct CameraPicker: UIViewControllerRepresentable {
    let onCaptured: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCaptured: onCaptured) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCaptured: (UIImage) -> Void
        init(onCaptured: @escaping (UIImage) -> Void) { self.onCaptured = onCaptured }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { onCaptured(img) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodegen && xcodebuild build -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add DietTracker/Views/Prep/ContainerEditView.swift
git commit -m "feat(view): container edit with camera + library + form"
```

---

## Task 10: PrepView + dock + RootView wiring + Info.plist

**Files:**
- Create: `DietTracker/Views/Prep/PrepView.swift`
- Modify: `DietTracker/Views/FloatingDock.swift`
- Modify: `DietTracker/Views/RootView.swift`
- Modify: `DietTracker/Info.plist`
- Modify: `project.yml`

- [ ] **Step 1: Write `PrepView.swift`**

```swift
import SwiftUI

struct PrepView: View {
    @Environment(AppSettings.self) private var settings
    @State private var model = PrepModel()
    @State private var listModel: ContainersListModel?
    @State private var showPicker = false
    @State private var showManager = false

    var body: some View {
        Form {
            Section("Container") {
                Button {
                    showPicker = true
                } label: {
                    HStack {
                        if let c = selected {
                            Text(c.name)
                            Spacer()
                            Text("\(Int(c.tareWeightG.rounded())) g")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Pick a container").foregroundStyle(.tint)
                            Spacer()
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Total weight on scale") {
                HStack {
                    TextField("0", value: $model.totalGrams, format: .number)
                        .keyboardType(.decimalPad)
                    Text("g").foregroundStyle(.secondary)
                }
            }

            Section("Portions") {
                Stepper(value: $model.portions, in: 1...50) {
                    Text("\(model.portions)")
                }
            }

            Section("Result") {
                row("Net food", value: model.netGrams)
                row("Per portion", value: model.perPortionGrams)
            }
        }
        .navigationTitle("Prep")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showManager = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            ContainerPickerSheet { picked in
                applyPick(picked)
            }
            .environment(settings)
        }
        .sheet(isPresented: $showManager) {
            ContainersListView()
                .environment(settings)
                .onDisappear { Task { await listModel?.load() } }
        }
        .task {
            if listModel == nil { listModel = ContainersListModel(settings: settings) }
            await listModel?.load()
            applyLastUsedIfNeeded()
        }
    }

    private var selected: Container? {
        guard let id = model.selectedContainerId,
              case .loaded(let list) = listModel?.state ?? .idle else { return nil }
        return list.first(where: { $0.id == id })
    }

    private func applyPick(_ c: Container) {
        model.selectedContainerId = c.id
        model.tareWeightG = c.tareWeightG
        UserDefaults.standard.set(c.id.uuidString, forKey: "prep.lastContainerId")
    }

    private func applyLastUsedIfNeeded() {
        guard model.selectedContainerId == nil,
              let raw = UserDefaults.standard.string(forKey: "prep.lastContainerId"),
              let id = UUID(uuidString: raw),
              case .loaded(let list) = listModel?.state ?? .idle,
              let match = list.first(where: { $0.id == id })
        else { return }
        applyPick(match)
    }

    @ViewBuilder
    private func row(_ label: String, value: Double?) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let v = value {
                Text("\(Int(v.rounded())) g").monospacedDigit()
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Update `FloatingDock.swift` to add the Prep button**

Replace the file with:

```swift
import SwiftUI

enum DockTab {
    case today, week, prep
}

struct FloatingDock: View {
    @Binding var tab: DockTab
    let onPickDate: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            button(label: "Today", system: "circle.fill", active: tab == .today) {
                tab = .today
            }
            button(label: "Week", system: "chart.bar.fill", active: tab == .week) {
                tab = .week
            }
            button(label: "Prep", system: "cube.box.fill", active: tab == .prep) {
                tab = .prep
            }
            button(label: "Date", system: "calendar", active: false, action: onPickDate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .padding(.bottom, 12)
    }

    private func button(label: String, system: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: system).font(.system(size: 14))
                Text(label).font(.caption2)
            }
            .foregroundStyle(active ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var tab: DockTab = .today
    return ZStack(alignment: .bottom) {
        Color.gray.opacity(0.1).ignoresSafeArea()
        FloatingDock(tab: $tab, onPickDate: {})
    }
}
```

- [ ] **Step 3: Update `RootView.swift` to handle `.prep`**

Edit the `content` switch:

```swift
@ViewBuilder
private var content: some View {
    switch tab {
    case .today: DayMacroView(date: Date())
    case .week:  WeekView()
    case .prep:  PrepView()
    }
}
```

- [ ] **Step 4: Add Info.plist permission keys**

Edit `DietTracker/Info.plist` and add (before `</dict>` at the bottom):

```xml
<key>NSCameraUsageDescription</key>
<string>To take photos of meal-prep containers.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>To pick photos of meal-prep containers from your library.</string>
```

- [ ] **Step 5: Mirror in `project.yml` so XcodeGen stays in sync**

In `project.yml`, under `targets.DietTracker.info.properties`, append:

```yaml
NSCameraUsageDescription: "To take photos of meal-prep containers."
NSPhotoLibraryUsageDescription: "To pick photos of meal-prep containers from your library."
```

- [ ] **Step 6: Regenerate project + build**

Run: `xcodegen && xcodebuild build -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Run all tests as a regression check**

Run: `xcodebuild test -project DietTracker.xcodeproj -scheme DietTracker -destination "platform=iOS Simulator,name=iPhone 15" 2>&1 | tail -25`
Expected: all existing + new tests pass.

- [ ] **Step 8: Commit**

```bash
git add DietTracker/Views/Prep/PrepView.swift \
        DietTracker/Views/FloatingDock.swift \
        DietTracker/Views/RootView.swift \
        DietTracker/Info.plist \
        project.yml
git commit -m "feat(prep): Prep tab with calculator + dock entry + plist permissions"
```

---

## Task 11: Manual smoke test against deployed backend

Requires the backend plan to be deployed.

- [ ] **Step 1: Ensure Settings has the right URL + key**

Open the simulator, open the app, tap gear icon. Confirm `Base URL` and `API key` are set.

- [ ] **Step 2: Add a container with photo**

- Tap **Prep** in the dock.
- Tap the gear (slider icon) to open the containers manager.
- Tap `+`. Take or pick a photo, name it "Test pot", weight `412`. Save.
- Expected: row appears with the photo thumbnail.

- [ ] **Step 3: Use the calculator**

- Back on Prep, tap "Pick a container" → choose "Test pot".
- Type `1450` for total. Set portions to `5`.
- Expected: Net food `1038 g`, Per portion `208 g`.

- [ ] **Step 4: Edit and remove photo**

- Re-open the manager. Tap the row. Remove the photo. Save.
- Expected: thumbnail falls back to the placeholder; backend `has_photo` becomes `false`.

- [ ] **Step 5: Delete container**

- Swipe-to-delete the row. Confirm.
- Expected: row disappears.

- [ ] **Step 6: Last-used persistence**

- Add a container, pick it on Prep, kill the app, relaunch.
- Expected: Prep shows that container pre-selected.

---

## Task 12: PR

- [ ] **Step 1: Push and open PR**

```bash
git push -u origin feat/meal-prep-containers
gh pr create --title "feat: meal-prep containers (Prep tab + container CRUD)" --body "$(cat <<'EOF'
## Summary
- New Prep tab: pick container, subtract tare weight, divide into portions
- Container CRUD with camera + photo library; photos served from backend with API key
- Last-used container persisted in UserDefaults

## Test plan
- [ ] `xcodebuild test ... -only-testing:DietTrackerTests`
- [ ] Manual: Task 11 smoke test against the deployed backend
- [ ] Verify `Info.plist` has camera + photo library descriptions before TestFlight
EOF
)"
```

---

## Self-Review (run before declaring done)

**Spec coverage:**
- `Container` DTO + decoding → Task 1.
- `payloadTooLarge` error → Task 2.
- Client write methods (CRUD, multipart upload, delete photo, photo request builder) → Tasks 3–4.
- `PrepModel` math (net + per-portion + clamp negative + portions floor) → Task 5.
- List + edit view-models → Task 6.
- `AuthorizedAsyncImage` for API-key-gated photo fetches → Task 7.
- Containers list + picker UI → Task 8.
- Edit form with camera + library + clear photo → Task 9.
- Prep tab + dock entry + RootView wiring → Task 10.
- Info.plist permissions (Camera + Photo Library) → Task 10.
- Last-used container persisted → Task 10 (`prep.lastContainerId`).
- Manual smoke test → Task 11.

**Placeholder scan:** None present.

**Type consistency:** `Container.tareWeightG: Double` everywhere. `ContainerPhotoSize.thumb / .full` consistent across model + client + view. `PrepModel` properties match between view-model and `PrepView` bindings. `containerPhotoRequest(id:size:)` is `nonisolated` on the actor (callable from views). `setNewPhoto(uiImage:)` and `clearPhoto()` referenced from edit view exist on the model.

**Open issues:** none blocking.
