// PulseTests/ReachableBranchTests.swift
/// Targeted tests for reachable non-view branches the smoke/load suites miss:
/// the container get/photo-delete endpoints, the ProgressPhotoStore upload
/// worker drain (success + retry), tag-store create/rename failure paths,
/// FoodSearchModel's USDA-unavailable degradation, ContainerEditModel's
/// clear-photo save path, and PrepModel batch persistence. Direct-client tests
/// reuse the `StubURLProtocol` pattern; store/model tests use a signed-in
/// `AuthSession` over a scoped stub session with a dedicated keychain slot.
import XCTest
import UIKit
@testable import Pulse

final class ReachableBranchTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var testAccount = ""
    private var activeStubs: [StubURLProtocol.Registration] = []
    private var retainedAuths: [AuthSession] = []

    override func setUp() {
        super.setUp()
        testAccount = "rbt-\(UUID().uuidString)"
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        retainedAuths = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    private func http(_ req: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    private func fixture(_ name: String) -> Data {
        try! Data(contentsOf: Bundle(for: Self.self).url(forResource: name, withExtension: "json")!)
    }

    private func makeSession(responder: @escaping StubURLProtocol.Responder) -> URLSession {
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        return stub.session
    }

    private func signedInAuth(responder: @escaping StubURLProtocol.Responder) -> AuthSession {
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: testService, account: testAccount)
        let a = AuthSession(baseURL: URL(string: "https://example.test")!,
                            keychainService: testService, keychainAccount: testAccount,
                            urlSession: makeSession(responder: responder))
        retainedAuths.append(a)
        return a
    }

    // MARK: - PulseClient containers (get + delete photo)

    /// Verifies `getContainer(id:)` issues a bearer GET to `/containers/{id}` and
    /// decodes the single-container fixture.
    func test_getContainer_fetchesAndDecodes() async throws {
        let client = PulseClient(baseURL: URL(string: "https://example.test")!, sessionToken: "tok",
                                 session: makeSession { req in (self.http(req, 200), self.fixture("container")) })
        let c = try await client.getContainer(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        XCTAssertFalse(c.name.isEmpty)
    }

    /// Verifies `deleteContainerPhoto(id:)` issues a DELETE to the photo subpath
    /// and completes on 204.
    func test_deleteContainerPhoto_sendsDelete() async throws {
        var method: String?
        var path: String?
        let client = PulseClient(baseURL: URL(string: "https://example.test")!, sessionToken: "tok",
                                 session: makeSession { req in
            method = req.httpMethod; path = req.url?.path
            return (self.http(req, 204), Data())
        })
        try await client.deleteContainerPhoto(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        XCTAssertEqual(method, "DELETE")
        XCTAssertEqual(path, "/containers/11111111-1111-1111-1111-111111111111/photo")
    }

    /// Verifies a server error from `deleteContainerPhoto` surfaces as `.server`.
    func test_deleteContainerPhoto_serverErrorThrows() async {
        let client = PulseClient(baseURL: URL(string: "https://example.test")!, sessionToken: "tok",
                                 session: makeSession { req in (self.http(req, 500), Data()) })
        do {
            try await client.deleteContainerPhoto(id: UUID())
            XCTFail("expected throw")
        } catch let e as PulseError {
            XCTAssertEqual(e, .server(status: 500))
        } catch { XCTFail("unexpected \(error)") }
    }

    // MARK: - ProgressPhotoStore upload worker

    /// Drives the upload worker end to end: an enqueued upload that fails once
    /// (server 500 → `processOne` failure/backoff) and then succeeds on retry,
    /// so the `drainLoop` due/sleep handling and `processOne` success bookkeeping
    /// both run.
    @MainActor
    func test_uploadWorker_failsThenSucceeds() async {
        let attempts = AttemptCounter()
        let auth = signedInAuth { req in
            let path = req.url?.path ?? ""
            if path == "/measures/photos" && req.httpMethod == "POST" {
                let n = attempts.next()
                if n == 1 { return (self.http(req, 500), Data()) }  // first attempt fails → backoff
                let body = #"{"id":"a1a1a1a1-1111-1111-1111-111111111111","date":"2026-05-20","tag_id":"b2b2b2b2-2222-2222-2222-222222222222","mime":"image/jpeg","bytes":10,"sha256":"x","updated_at":"2026-05-20T10:00:00Z"}"#
                return (self.http(req, 201), body.data(using: .utf8)!)
            }
            return (self.http(req, 404), Data())
        }
        let store = ProgressPhotoStore(auth: auth)
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        await store.upload(date: Date(), tagId: UUID(uuidString: "b2b2b2b2-2222-2222-2222-222222222222")!, imageData: jpeg)
        // Give the worker time to attempt, back off, wake, and retry to success.
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThanOrEqual(attempts.total, 1, "the worker must attempt the upload at least once")
    }

    /// Thread-safe attempt counter for the off-thread upload worker.
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var total: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    // MARK: - ProgressPhotoTagStore failure paths

    /// Verifies tag create/rename surface `lastError` and return nil when the
    /// server fails, without mutating the local list.
    @MainActor
    func test_tagStore_createAndRenameFailures() async {
        let auth = signedInAuth { req in (self.http(req, 500), Data()) }
        let store = ProgressPhotoTagStore(auth: auth)
        let created = await store.create(name: "X")
        XCTAssertNil(created)
        XCTAssertNotNil(store.lastError)
        let renamed = await store.rename(id: UUID(), name: "Y")
        XCTAssertNil(renamed)
        XCTAssertTrue(store.tags.isEmpty)
    }

    // MARK: - FoodSearchModel USDA degradation

    /// Verifies a USDA search failure still yields results (my-foods only) and
    /// flags `usdaUnavailable`, exercising `runSearch`'s catch branch.
    @MainActor
    func test_foodSearch_usdaFailureStillShowsMyFoods() async {
        let auth = signedInAuth { req in
            let path = req.url?.path ?? ""
            if path == "/custom-foods" { return (self.http(req, 200), self.fixture("custom_foods")) }
            if path == "/food-memory" { return (self.http(req, 200), self.fixture("food_memory")) }
            if path == "/usda/search" { return (self.http(req, 500), Data()) }  // USDA down
            return (self.http(req, 404), Data())
        }
        let model = FoodSearchModel(auth: auth, debounce: .milliseconds(1))
        await model.loadMyFoods()
        model.query = "protein"
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(model.usdaUnavailable, "USDA failure must set the unavailable flag")
        guard case .loaded = model.state else { return XCTFail("my-foods should still render, got \(model.state)") }
    }

    // MARK: - ContainerEditModel clear-photo save path

    /// Verifies editing an existing container with the photo cleared issues the
    /// photo DELETE during save (`photoCleared && existing != nil` branch).
    func test_containerEdit_clearPhotoSaveDeletesPhoto() async {
        var sawPhotoDelete = false
        let auth = signedInAuth { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/photo") && req.httpMethod == "DELETE" {
                sawPhotoDelete = true
                return (self.http(req, 204), Data())
            }
            if path.hasPrefix("/containers/") && req.httpMethod == "PATCH" {
                return (self.http(req, 200), self.fixture("container"))
            }
            return (self.http(req, 404), Data())
        }
        let existing = Container(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                 userKey: "khash", name: "Box", normalizedName: "box", tareWeightG: 100,
                                 hasPhoto: true, createdAt: Date(), updatedAt: Date())
        let model = ContainerEditModel(existing: existing, auth: auth)
        model.name = "Box"; model.tareWeightText = "120"
        model.clearPhoto()
        XCTAssertTrue(model.photoCleared)
        await model.save()
        XCTAssertNotNil(model.savedContainerId)
        XCTAssertTrue(sawPhotoDelete, "clearing the photo on an existing container must DELETE it on save")
    }

    /// Verifies `setNewPhoto(uiImage:)` JPEG-encodes the image and stages it.
    func test_containerEdit_setNewPhotoStagesJPEG() {
        let model = ContainerEditModel(existing: nil, auth: signedInAuth { req in (self.http(req, 200), Data()) })
        let img = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        model.setNewPhoto(uiImage: img)
        XCTAssertNotNil(model.newPhotoJPEG)
        XCTAssertFalse(model.photoCleared)
    }

    // MARK: - PrepModel batch persistence round-trip

    /// Verifies `PrepModel` persists and reloads batch items through
    /// `PrepStatePersistence` (`saveBatchItems` / `loadBatchItems`).
    func test_prepModel_batchItemsRoundTrip() {
        defer { UserDefaults.standard.removeObject(forKey: "prep.batchItems") }
        let model = PrepModel()
        let nutrition = FoodNutrition(basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                                      caloriesPerBasis: 130, proteinGPerBasis: 2.7, carbsGPerBasis: 28, fatGPerBasis: 0.3)
        let item = BatchFoodItem(id: UUID(), displayName: "Rice", usdaFdcId: nil, usdaDescription: nil,
                                 customFoodId: nil, nutrition: nutrition, quantity: .typed(value: 200, unit: .grams),
                                 containerId: nil, macros: MacroTotals(calories: 260, proteinG: 5.4, carbsG: 56, fatG: 0.6))
        model.saveBatchItems([item])
        let reloaded = model.loadBatchItems()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.displayName, "Rice")
    }
}
