// PulseTests/ViewModelLoadTests.swift
/// Integration-style success-path tests for the app's @Observable view-models.
/// Each builds an `AuthSession` backed by a `StubURLProtocol` session that routes
/// responses to fixtures by path, then drives the model's load/mutate methods and
/// asserts the resulting `LoadState`. Complements `ModelUnauthorizedTests` (failure path).
import XCTest
import UIKit
@testable import Pulse

final class ViewModelLoadTests: XCTestCase {
    /// A tiny valid PNG so photo-download stubs decode to a real image (exercises
    /// the image-decode + cache-write success branches rather than just nil).
    static let samplePNG: Data = {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return r.pngData { ctx in UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
    }()

    private let testService = "com.pulseapp.pulse.session.test"
    private var testAccount = ""
    private var activeStubs: [StubURLProtocol.Registration] = []
    /// Retains AuthSessions for the test's lifetime: view-models hold `weak var auth`,
    /// so without a strong reference here the session deallocates and `makeClient()`
    /// returns nil (surfacing as `.notSignedIn`).
    private var retainedAuths: [AuthSession] = []

    private let mealJSON = #"{"id":"22222222-2222-2222-2222-222222222222","user_key":"khash","name":"Wrap","normalized_name":"wrap","notes":null,"created_at":"2026-05-10T12:00:00Z","updated_at":"2026-05-10T12:00:00Z","items":[]}"#
    private let targetsJSON = #"{"calories":2000,"protein_g":150,"carbs_g":200,"fat_g":60,"target_weight_lb":175}"#

    override func setUp() {
        super.setUp()
        testAccount = "vm-\(UUID().uuidString)"
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        retainedAuths = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    /// Loads a JSON fixture from the test bundle.
    private func fixture(_ name: String) -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
    }

    /// Builds a signed-in `AuthSession` whose client routes every request to a
    /// fixture (or inline JSON) keyed by URL path + method.
    private func makeAuth() -> AuthSession {
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: testService, account: testAccount)
        let stub = StubURLProtocol.makeSession { req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            func resp(_ code: Int) -> HTTPURLResponse {
                HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            }
            func ok(_ data: Data) -> (HTTPURLResponse, Data) { (resp(200), data) }

            if path.hasPrefix("/summary/") { return ok(self.fixture("summary")) }
            if path == "/logs" { return ok(self.fixture("logs")) }
            if path == "/calories_daily" { return ok(self.fixture("calories_daily")) }
            if path == "/targets" { return ok(self.targetsJSON.data(using: .utf8)!) }
            if path == "/meals" { return ok(self.fixture("meals_with_aliases")) }
            if path.hasPrefix("/meals/") { return ok(self.mealJSON.data(using: .utf8)!) }
            if path == "/custom-foods" { return ok(self.fixture("custom_foods")) }
            if path == "/food-memory" { return ok(self.fixture("food_memory")) }
            if path == "/usda/search" { return ok(self.fixture("usda_search")) }
            if path == "/weight" { return ok(self.fixture("weight_entries")) }
            if path.hasPrefix("/weight/") {
                return method == "DELETE" ? (resp(204), Data()) : ok(self.fixture("weight_entry"))
            }
            if path == "/containers" {
                return method == "POST" ? ok(self.fixture("container")) : ok(self.fixture("containers"))
            }
            if path.hasPrefix("/containers/") {
                if method == "DELETE" { return (resp(204), Data()) }
                if path.hasSuffix("/photo") { return (resp(200), Data()) }
                return ok(self.fixture("container"))
            }
            if path == "/auth/whoami" { return ok(self.fixture("whoami")) }
            if path == "/measures/photos" {
                return method == "POST"
                    ? ok(#"{"id":"a1a1a1a1-1111-1111-1111-111111111111","date":"2026-05-20","tag_id":"b2b2b2b2-2222-2222-2222-222222222222","mime":"image/jpeg","bytes":1234,"sha256":"x","updated_at":"2026-05-20T10:00:00Z"}"#.data(using: .utf8)!)
                    : ok(self.fixture("progress_photos"))
            }
            if path.hasPrefix("/measures/photos/") { return method == "DELETE" ? (resp(204), Data()) : ok(Self.samplePNG) }
            if path == "/measures/photo-tags" {
                return method == "POST"
                    ? ok(#"{"id":"c3c3c3c3-3333-3333-3333-333333333333","name":"Side","normalized_name":"side","sort_order":1,"created_at":"2026-05-01T00:00:00Z","updated_at":"2026-05-01T00:00:00Z"}"#.data(using: .utf8)!)
                    : ok(self.fixture("photo_tags"))
            }
            if path.hasPrefix("/measures/photo-tags/") {
                return ok(#"{"id":"b2b2b2b2-2222-2222-2222-222222222222","name":"Back","normalized_name":"back","sort_order":0,"created_at":"2026-05-01T00:00:00Z","updated_at":"2026-05-01T00:00:00Z"}"#.data(using: .utf8)!)
            }
            return (resp(404), Data())
        }
        activeStubs.append(stub)
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: stub.session
        )
        retainedAuths.append(auth)
        return auth
    }

    private func container() -> Container {
        Container(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                  userKey: "khash", name: "Box", normalizedName: "box", tareWeightG: 100,
                  hasPhoto: false, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - macro / period models

    func test_dayMacroModel_loads() async {
        let m = DayMacroModel(date: Date(), auth: makeAuth())
        await m.load()
        guard case .loaded = m.state else { return XCTFail("expected loaded, got \(m.state)") }
    }

    func test_weekModel_loads() async {
        let m = PeriodIntakeModel(range: .week, auth: makeAuth())
        await m.load()
        guard case .loaded = m.state else { return XCTFail("got \(m.state)") }
        XCTAssertNotNil(m.targets)
    }

    func test_monthModel_loads() async {
        let m = PeriodIntakeModel(range: .month, auth: makeAuth())
        await m.load()
        guard case .loaded = m.state else { return XCTFail("got \(m.state)") }
    }

    func test_yearModel_loads() async {
        let m = PeriodIntakeModel(range: .year, auth: makeAuth())
        await m.load()
        guard case .loaded = m.state else { return XCTFail("got \(m.state)") }
    }

    // MARK: - meals

    func test_mealsModel_loads() async {
        let m = MealsModel(auth: makeAuth())
        await m.load()
        guard case .loaded(let meals) = m.state else { return XCTFail("got \(m.state)") }
        XCTAssertEqual(meals.count, 1)
    }

    func test_mealDetailModel_loads() async {
        let m = MealDetailModel(mealId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, auth: makeAuth())
        await m.load()
        guard case .loaded(let meal) = m.state else { return XCTFail("got \(m.state)") }
        XCTAssertEqual(meal.name, "Wrap")
    }

    // MARK: - weight

    func test_weightLogModel_loadUpsertDelete() async {
        let m = WeightLogModel(auth: makeAuth())
        await m.load()
        guard case .loaded = m.state else { return XCTFail("load: \(m.state)") }
        await m.upsert(date: Date(), weight: 180, unit: .lb)
        guard case .loaded(let afterUpsert) = m.state else { return XCTFail("upsert: \(m.state)") }
        XCTAssertFalse(afterUpsert.isEmpty)
        await m.delete(date: Date(timeIntervalSince1970: 0))
        guard case .loaded = m.state else { return XCTFail("delete: \(m.state)") }
    }

    func test_weightTrendsModel_loads() async {
        let store = UserTargetsStore()
        let m = WeightTrendsModel(auth: makeAuth(), targetsStore: store)
        m.range = .d30
        await m.load()
        guard case .loaded = m.analytics else { return XCTFail("got \(m.analytics)") }
        m.recomputeAnalytics()
        guard case .loaded = m.analytics else { return XCTFail("recompute: \(m.analytics)") }
    }

    // MARK: - targets store

    func test_userTargetsStore_updateClearRefresh() async {
        let store = UserTargetsStore()
        XCTAssertNil(store.targets)
        store.update(MacroTargets(calories: 1, proteinG: 1, carbsG: 1, fatG: 1, targetWeightLb: nil))
        XCTAssertNotNil(store.targets)
        store.clear()
        XCTAssertNil(store.targets)
        let auth = makeAuth()
        if let client = auth.makeClient() {
            await store.refresh(client: client)
            XCTAssertEqual(store.targets?.calories, 2000)
        } else {
            XCTFail("no client")
        }
    }

    // MARK: - containers

    func test_containersListModel_loadAndDelete() async {
        let m = ContainersListModel(auth: makeAuth())
        await m.load()
        guard case .loaded(let list) = m.state else { return XCTFail("got \(m.state)") }
        XCTAssertEqual(list.count, 2)
        await m.delete(id: list[0].id)
        guard case .loaded = m.state else { return XCTFail("after delete: \(m.state)") }
    }

    func test_containerEditModel_create() async {
        let m = ContainerEditModel(existing: nil, auth: makeAuth())
        m.name = "New Box"
        m.tareWeightText = "150"
        XCTAssertTrue(m.isValid)
        XCTAssertFalse(m.isExisting)
        await m.save()
        XCTAssertNotNil(m.savedContainerId)
        XCTAssertNil(m.error)
    }

    func test_containerEditModel_updateWithPhoto() async {
        let m = ContainerEditModel(existing: container(), auth: makeAuth())
        XCTAssertTrue(m.isExisting)
        m.name = "Renamed"
        m.tareWeightText = "120"
        m.newPhotoJPEG = Data([0xFF, 0xD8, 0xFF])
        await m.save()
        XCTAssertNotNil(m.savedContainerId)
        XCTAssertNil(m.error)
    }

    func test_containerEditModel_clearPhoto() {
        let m = ContainerEditModel(existing: container(), auth: makeAuth())
        m.clearPhoto()
        XCTAssertTrue(m.photoCleared)
        XCTAssertNil(m.newPhotoJPEG)
    }

    // MARK: - food search

    @MainActor
    func test_foodSearchModel_emptyQueryBrowsesMyFoods() async {
        let m = FoodSearchModel(auth: makeAuth(), debounce: .milliseconds(1))
        await m.loadMyFoods()
        guard case .loaded(let results) = m.state else { return XCTFail("got \(m.state)") }
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.source == .myFood })

        // Typing then clearing the query returns to the browse list.
        m.query = "chicken"
        try? await Task.sleep(for: .milliseconds(120))
        m.query = ""
        try? await Task.sleep(for: .milliseconds(120))
        guard case .loaded(let restored) = m.state else { return XCTFail("got \(m.state)") }
        XCTAssertTrue(restored.allSatisfy { $0.source == .myFood })
    }

    /// A failed my-foods load in browse mode must surface `.failed` (with a
    /// working Retry path) rather than stranding the sheet on a spinner or a
    /// misleading "No foods yet" empty state.
    @MainActor
    func test_foodSearchModel_failedLoadSurfacesFailedState() async {
        let m = FoodSearchModel(auth: makeFailingAuth(), debounce: .milliseconds(1))
        await m.loadMyFoods()
        guard case .failed = m.state else { return XCTFail("got \(m.state)") }
    }

    /// Clearing an active search after a failed my-foods load must resurface
    /// `.failed` (Retry available), not a misleading empty browse list.
    @MainActor
    func test_foodSearchModel_clearedQueryResurfacesFailedLoad() async {
        let m = FoodSearchModel(auth: makeFailingAuth(), debounce: .milliseconds(1))
        m.query = "chicken"
        try? await Task.sleep(for: .milliseconds(120))
        m.query = ""
        try? await Task.sleep(for: .milliseconds(120))
        guard case .failed = m.state else { return XCTFail("got \(m.state)") }
    }

    /// A successful my-foods load is cached: re-presenting the sheet (which
    /// re-fires `loadMyFoods`) must not repeat the network requests.
    @MainActor
    func test_foodSearchModel_successfulLoadIsCachedAcrossCalls() async {
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: testService, account: testAccount)
        var hits = 0
        let stub = StubURLProtocol.makeSession { req in
            hits += 1
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let path = req.url?.path ?? ""
            if path.hasPrefix("/custom-foods") { return (resp, self.fixture("custom_foods")) }
            return (resp, self.fixture("food_memory"))
        }
        activeStubs.append(stub)
        let auth = AuthSession(baseURL: URL(string: "https://example.test")!,
                               keychainService: testService, keychainAccount: testAccount, urlSession: stub.session)
        retainedAuths.append(auth)

        let m = FoodSearchModel(auth: auth, debounce: .milliseconds(1))
        await m.loadMyFoods()
        guard case .loaded = m.state else { return XCTFail("got \(m.state)") }
        let firstLoadHits = hits
        await m.loadMyFoods()
        XCTAssertEqual(hits, firstLoadHits, "second load must reuse the cached my-foods set")
    }

    @MainActor
    func test_foodSearchModel_loadMyFoodsAndSearch() async {
        let m = FoodSearchModel(auth: makeAuth(), debounce: .milliseconds(1))
        await m.loadMyFoods()
        m.query = "chicken"
        try? await Task.sleep(for: .milliseconds(120))
        guard case .loaded(let results) = m.state else { return XCTFail("got \(m.state)") }
        XCTAssertFalse(results.isEmpty)
    }

    // MARK: - error paths

    /// Builds a signed-in AuthSession whose client returns HTTP 500 for everything,
    /// driving the view-models' catch/`.failed` branches.
    private func makeFailingAuth() -> AuthSession {
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: testService, account: testAccount)
        let stub = StubURLProtocol.makeSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        activeStubs.append(stub)
        let auth = AuthSession(baseURL: URL(string: "https://example.test")!,
                               keychainService: testService, keychainAccount: testAccount, urlSession: stub.session)
        retainedAuths.append(auth)
        return auth
    }

    func test_models_serverErrorFailStates() async {
        let auth = makeFailingAuth()

        let day = DayMacroModel(date: Date(), auth: auth); await day.load()
        if case .failed = day.state {} else { XCTFail("day: \(day.state)") }

        let week = PeriodIntakeModel(range: .week, auth: auth); await week.load()
        if case .failed = week.state {} else { XCTFail("week: \(week.state)") }

        let month = PeriodIntakeModel(range: .month, auth: auth); await month.load()
        if case .failed = month.state {} else { XCTFail("month: \(month.state)") }

        let year = PeriodIntakeModel(range: .year, auth: auth); await year.load()
        if case .failed = year.state {} else { XCTFail("year: \(year.state)") }

        let meals = MealsModel(auth: auth); await meals.load()
        if case .failed = meals.state {} else { XCTFail("meals: \(meals.state)") }

        let containers = ContainersListModel(auth: auth); await containers.load()
        if case .failed = containers.state {} else { XCTFail("containers: \(containers.state)") }
    }

    func test_weightLogModel_errorPaths() async {
        let auth = makeFailingAuth()
        let m = WeightLogModel(auth: auth)
        await m.load()
        if case .failed = m.state {} else { XCTFail("load: \(m.state)") }
        await m.upsert(date: Date(), weight: 180, unit: .lb)
        if case .failed = m.state {} else { XCTFail("upsert: \(m.state)") }
        await m.delete(date: Date())
        if case .failed = m.state {} else { XCTFail("delete: \(m.state)") }
    }

    func test_weightTrendsAndDetail_errorPaths() async {
        let auth = makeFailingAuth()
        let trends = WeightTrendsModel(auth: auth, targetsStore: UserTargetsStore())
        await trends.load()
        if case .failed = trends.analytics {} else { XCTFail("trends: \(trends.analytics)") }

        let detail = MealDetailModel(mealId: UUID(), auth: auth)
        await detail.load()
        if case .failed = detail.state {} else { XCTFail("detail: \(detail.state)") }
    }

    func test_containerEditModel_errorPath() async {
        let m = ContainerEditModel(existing: nil, auth: makeFailingAuth())
        m.name = "X"; m.tareWeightText = "100"
        await m.save()
        XCTAssertNotNil(m.error)
        XCTAssertNil(m.savedContainerId)
    }

    // MARK: - progress photo stores

    @MainActor
    func test_progressPhotoStore_reconcileThumbFullDelete() async {
        let store = ProgressPhotoStore(auth: makeAuth())
        await store.reconcile(from: Date(timeIntervalSince1970: 1_747_000_000), to: Date())
        _ = store.photos(on: Date())
        let meta = ProgressPhotoMetadata(
            id: UUID(uuidString: "a1a1a1a1-1111-1111-1111-111111111111")!, date: Date(),
            tagId: UUID(uuidString: "b2b2b2b2-2222-2222-2222-222222222222")!, mime: "image/jpeg",
            bytes: 1234, sha256: "x", updatedAt: Date())
        _ = await store.thumb(meta)
        _ = await store.full(meta)
        await store.delete(meta)
    }

    @MainActor
    func test_progressPhotoTagStore_reloadCreateRename() async {
        let store = ProgressPhotoTagStore(auth: makeAuth())
        await store.reload()
        XCTAssertFalse(store.tags.isEmpty)
        if let first = store.tags.first {
            _ = store.tag(id: first.id)
            _ = await store.rename(id: first.id, name: "Back")
        }
        _ = await store.create(name: "Side")
    }

    @MainActor
    func test_progressPhotoStore_upload() async {
        let store = ProgressPhotoStore(auth: makeAuth())
        await store.upload(date: Date(),
                           tagId: UUID(uuidString: "b2b2b2b2-2222-2222-2222-222222222222")!,
                           imageData: Data([0x01, 0x02, 0x03, 0x04]))
        // Let the fire-and-forget upload worker drain.
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: - auth session

    func test_authSession_signOutClearsState() async {
        let auth = makeAuth()
        XCTAssertTrue(auth.isSignedIn)
        await auth.signOut()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
    }

    func test_authSession_bootstrapKeepsValidSession() async {
        let auth = makeAuth()
        await auth.bootstrap()
        XCTAssertTrue(auth.isSignedIn)
    }

    func test_authSession_completeSignInWithBadURLErrors() async {
        let auth = makeAuth()
        await auth.completeSignIn(url: URL(string: "https://example.test/callback")!, codeVerifier: "verifier")
        XCTAssertFalse(auth.isSignedIn)
    }

    func test_authSession_signInURLBuilders() {
        let auth = makeAuth()
        XCTAssertFalse(auth.startSignInURL().absoluteString.isEmpty)
        XCTAssertNotNil(auth.signInURL(codeChallenge: "challenge"))
    }
}
