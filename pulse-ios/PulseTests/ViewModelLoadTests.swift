// PulseTests/ViewModelLoadTests.swift
/// Integration-style success-path tests for the app's @Observable view-models.
/// Each builds an `AuthSession` backed by a `StubURLProtocol` session that routes
/// responses to fixtures by path, then drives the model's load/mutate methods and
/// asserts the resulting `LoadState`. Complements `ModelUnauthorizedTests` (failure path).
import XCTest
@testable import Pulse

final class ViewModelLoadTests: XCTestCase {
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
        let m = WeekModel(auth: makeAuth())
        await m.loadLast7Days()
        guard case .loaded = m.state else { return XCTFail("got \(m.state)") }
        XCTAssertNotNil(m.targets)
    }

    func test_monthModel_loads() async {
        let m = MonthModel(auth: makeAuth())
        await m.loadCurrentMonth()
        guard case .loaded = m.state else { return XCTFail("got \(m.state)") }
    }

    func test_yearModel_loads() async {
        let m = YearModel(auth: makeAuth())
        await m.loadCurrentYear()
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

    func test_foodSearchModel_loadMyFoodsAndSearch() async {
        let m = FoodSearchModel(auth: makeAuth(), debounce: .milliseconds(1))
        await m.loadMyFoods()
        m.query = "chicken"
        try? await Task.sleep(for: .milliseconds(120))
        guard case .loaded(let results) = m.state else { return XCTFail("got \(m.state)") }
        XCTAssertFalse(results.isEmpty)
    }
}
